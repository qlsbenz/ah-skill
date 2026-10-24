package installer

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"ah-skills/tools/internal/fsutil"
	"ah-skills/tools/internal/lockfile"
	"ah-skills/tools/internal/registry"
	"ah-skills/tools/internal/transfer"
)

type Installer struct {
	Target      string
	HarnessRoot string
	ProjectRoot string
	DryRun      bool
	Force       bool
	Mode        string
	Lock        *lockfile.Lockfile
}

func (in *Installer) place(domain, kind, name, src, dst string) (int, error) {
	if in.Target == "codex" {
		return in.placeCodex(domain, kind, name, src, dst)
	}
	if in.Mode == "link" {
		if kind == "skill" {
			if !in.DryRun {
				if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
					return 0, err
				}
			}
			if err := transfer.LinkOne(src, dst, in.DryRun, in.Force, in.Lock); err != nil {
				return 0, err
			}
			if !in.DryRun {
				in.Lock.Record(lockfile.Entry{
					Domain: domain, Kind: kind, Name: name,
					Mode: "link", Path: dst, Source: src,
					InstalledAt: time.Now(),
				})
			}
			return 1, nil
		}
		return transfer.LinkTree(domain, kind, src, dst, in.DryRun, in.Force, in.Lock)
	}

	if entry, ok := in.Lock.Owns(dst); ok && entry.Mode != "copy" {
		fmt.Fprintf(os.Stderr, "ah-skills: warning: %s was installed via %q, replacing with a copy — mixed channels may cause confusion\n", dst, entry.Mode)
	}
	n, err := transfer.CopyTree(src, dst, in.DryRun)
	if err != nil {
		return n, err
	}
	if !in.DryRun {
		hash, err := transfer.HashTree(dst)
		if err != nil {
			return n, fmt.Errorf("hashing %s: %w", dst, err)
		}
		in.Lock.Record(lockfile.Entry{
			Domain: domain, Kind: kind, Name: name,
			Mode: "copy", Path: dst, Source: src, SHA256: hash,
			InstalledAt: time.Now(),
		})
	}
	return n, nil
}

func (in *Installer) InstallDomain(reg *registry.Registry, name string, strict bool) error {
	m, ok := reg.Domains[name]
	if !ok {
		return fmt.Errorf("unknown domain %q (available: %s)", name, strings.Join(reg.DomainNames(), ", "))
	}
	for _, envVar := range m.RequiresEnv {
		if os.Getenv(envVar) != "" {
			continue
		}
		msg := fmt.Sprintf("domain %q requires $%s, which is not set", name, envVar)
		if strict {
			return errors.New(msg)
		}
		fmt.Fprintf(os.Stderr, "ah-skills: skipping — %s\n", msg)
		return nil
	}
	for _, bin := range m.RequiresBin {
		if fsutil.HasBin(bin) {
			continue
		}
		msg := fmt.Sprintf("domain %q requires the %q binary, which is not on $PATH", name, bin)
		if strict {
			return errors.New(msg)
		}
		fmt.Fprintf(os.Stderr, "ah-skills: skipping — %s\n", msg)
		return nil
	}
	for _, kind := range registry.DomainKinds {
		srcDir := filepath.Join(in.HarnessRoot, "domains", name, kind)
		if !fsutil.DirExists(srcDir) {
			continue
		}
		if in.Target == "codex" && kind == "hooks" {
			n, err := in.installCodexHooks(name, srcDir)
			if err != nil {
				return fmt.Errorf("domain %q: installing hooks: %w", name, err)
			}
			in.report(name, kind, filepath.Join(in.ProjectRoot, ".codex"), n)
			continue
		}
		destPath, err := in.resolveTarget(m, kind)
		if err != nil {
			return fmt.Errorf("domain %q: %w", name, err)
		}
		n, err := in.place(name, kind, "", srcDir, destPath)
		if err != nil {
			return fmt.Errorf("domain %q: copying %s: %w", name, kind, err)
		}
		in.report(name, kind, destPath, n)
		if kind == "hooks" && !in.DryRun {
			if in.Mode == "copy" {
				if err := transfer.MakeShellScriptsExecutable(destPath); err != nil {
					return fmt.Errorf("domain %q: chmod hooks: %w", name, err)
				}
			} else {
				transfer.WarnHooksNotExecutable(srcDir)
			}
		}
	}
	return nil
}

func (in *Installer) InstallSkill(reg *registry.Registry, name string) error {
	owner := ""
	for _, dname := range reg.DomainNames() {
		if fsutil.DirExists(filepath.Join(in.HarnessRoot, "domains", dname, "skills", name)) {
			owner = dname
			break
		}
	}
	if owner == "" {
		return fmt.Errorf("unknown skill %q (see `ah-skills list skills`)", name)
	}
	m := reg.Domains[owner]
	for _, envVar := range m.RequiresEnv {
		if os.Getenv(envVar) == "" {
			return fmt.Errorf("skill %q belongs to domain %q, which requires $%s (not set)", name, owner, envVar)
		}
	}
	for _, bin := range m.RequiresBin {
		if !fsutil.HasBin(bin) {
			return fmt.Errorf("skill %q belongs to domain %q, which requires the %q binary (not found on $PATH)", name, owner, bin)
		}
	}
	if in.Target == "codex" {
		if err := validateCodexSkill(filepath.Join(in.HarnessRoot, "domains", owner, "skills", name), name); err != nil {
			return err
		}
		for _, kind := range []string{"rules", "agents", "hooks"} {
			src := filepath.Join(in.HarnessRoot, "domains", owner, kind)
			if !fsutil.DirExists(src) {
				continue
			}
			if kind == "hooks" {
				if _, err := in.installCodexHooks(owner, src); err != nil {
					return err
				}
				continue
			}
			dst, err := in.resolveTarget(m, kind)
			if err != nil {
				return err
			}
			if _, err := in.placeCodex(owner, kind, "", src, dst); err != nil {
				return err
			}
		}
	}
	destBase, err := in.resolveTarget(m, "skills")
	if err != nil {
		return fmt.Errorf("skill %q: %w", name, err)
	}
	dest := filepath.Join(destBase, name)
	src := filepath.Join(in.HarnessRoot, "domains", owner, "skills", name)
	n, err := in.place(owner, "skill", name, src, dest)
	if err != nil {
		return fmt.Errorf("skill %q: %w", name, err)
	}
	in.report(owner, "skill", dest, n)
	return nil
}

func (in *Installer) UninstallDomain(reg *registry.Registry, name string) error {
	m, ok := reg.Domains[name]
	if !ok {
		return fmt.Errorf("unknown domain %q (available: %s)", name, strings.Join(reg.DomainNames(), ", "))
	}
	for _, kind := range registry.DomainKinds {
		srcDir := filepath.Join(in.HarnessRoot, "domains", name, kind)
		if !fsutil.DirExists(srcDir) {
			continue
		}
		if in.Target == "codex" && kind == "hooks" {
			if err := in.uninstallCodexHooks(name, srcDir); err != nil {
				return err
			}
			continue
		}
		destPath, err := in.resolveTarget(m, kind)
		if err != nil {
			return fmt.Errorf("domain %q: %w", name, err)
		}
		entries, err := os.ReadDir(srcDir)
		if err != nil {
			return fmt.Errorf("domain %q: %w", name, err)
		}
		for _, e := range entries {
			itemName := e.Name()
			dst := filepath.Join(destPath, itemName)
			in.uninstallOne(name, kind, itemName, dst)
		}

		if _, tracked := in.Lock.Find(name, kind, ""); tracked {
			in.Lock.Remove(name, kind, "")
		}
	}
	return nil
}

func (in *Installer) UninstallSkill(reg *registry.Registry, name string) error {
	owner := ""
	for _, dname := range reg.DomainNames() {
		if fsutil.DirExists(filepath.Join(in.HarnessRoot, "domains", dname, "skills", name)) {
			owner = dname
			break
		}
	}
	if owner == "" {
		return fmt.Errorf("unknown skill %q (see `ah-skills list skills`)", name)
	}
	m := reg.Domains[owner]
	destBase, err := in.resolveTarget(m, "skills")
	if err != nil {
		return fmt.Errorf("skill %q: %w", name, err)
	}
	dest := filepath.Join(destBase, name)
	kind := "skill"
	if in.Target == "codex" {
		kind = "skills"
	}
	in.uninstallOne(owner, kind, name, dest)
	return nil
}

func (in *Installer) uninstallOne(domain, kind, name, dst string) {
	entry, tracked := in.Lock.Owns(dst)
	if !tracked {
		if parent, ok := in.Lock.Find(domain, kind, ""); ok {
			entry, tracked = parent, true
		}
	}
	if !tracked {
		fmt.Fprintf(os.Stderr, "ah-skills: warning: skipping %s — not tracked by ah-skills\n", dst)
		return
	}
	fi, err := os.Lstat(dst)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ah-skills: warning: skipping %s — tracked but nothing on disk\n", dst)
		return
	}
	isSymlink := fi.Mode()&os.ModeSymlink != 0
	switch entry.Mode {
	case "link":
		if !isSymlink {
			fmt.Fprintf(os.Stderr, "ah-skills: warning: skipping %s — tracked as a link but not a symlink on disk\n", dst)
			return
		}
	case "copy":
		if isSymlink {
			fmt.Fprintf(os.Stderr, "ah-skills: warning: skipping %s — tracked as a copy but is a symlink on disk\n", dst)
			return
		}
	default:
		fmt.Fprintf(os.Stderr, "ah-skills: warning: skipping %s — unrecognized tracked mode %q\n", dst, entry.Mode)
		return
	}
	if in.DryRun {
		fmt.Printf("would uninstall %s\n", dst)
		return
	}
	var removeErr error
	if entry.Mode == "link" {
		removeErr = os.Remove(dst)
	} else {
		removeErr = os.RemoveAll(dst)
	}
	if removeErr != nil {
		fmt.Fprintf(os.Stderr, "ah-skills: warning: failed removing %s: %v\n", dst, removeErr)
		return
	}
	in.Lock.Remove(domain, kind, name)
	fmt.Printf("uninstalled    %s\n", dst)
}

func (in *Installer) report(scope, kind, dest string, n int) {
	verb := "installed"
	if in.DryRun {
		verb = "would install"
	}
	plural := "s"
	if n == 1 {
		plural = ""
	}
	fmt.Printf("%-13s %-8s %-7s -> %s (%d file%s)\n", verb, scope, kind, dest, n, plural)
}
