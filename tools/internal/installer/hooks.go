package installer

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"ah-skills/tools/internal/lockfile"
	"ah-skills/tools/internal/transfer"
)

func (in *Installer) codexHookDestination(name string) string {
	if name == "hooks.json" {
		return filepath.Join(in.ProjectRoot, ".codex", name)
	}
	return filepath.Join(in.ProjectRoot, ".codex", "hooks", name)
}

func (in *Installer) installCodexHooks(domain, srcDir string) (int, error) {
	entries, err := os.ReadDir(srcDir)
	if err != nil {
		return 0, err
	}
	count := 0
	for _, entry := range entries {
		if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			return count, fmt.Errorf("hook source %s must be a regular file", entry.Name())
		}
		src := filepath.Join(srcDir, entry.Name())
		dst := in.codexHookDestination(entry.Name())
		if entry.Name() == "hooks.json" {
			if _, err := in.placeCodex(domain, "hooks", entry.Name(), src, dst); err != nil {
				return count, err
			}
			count++
			continue
		}
		for p := filepath.Dir(dst); p != in.ProjectRoot; p = filepath.Dir(p) {
			info, err := os.Lstat(p)
			if err == nil && info.Mode()&os.ModeSymlink != 0 {
				return count, fmt.Errorf("refusing symlink destination %s", p)
			}
			if err != nil && !os.IsNotExist(err) {
				return count, err
			}
		}
		if !in.DryRun {
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return count, err
			}
		}
		if err := transfer.LinkOne(src, dst, in.DryRun, in.Force, in.Lock); err != nil {
			return count, err
		}
		if !in.DryRun {
			in.Lock.Record(lockfile.Entry{
				Domain: domain, Kind: "hooks", Name: entry.Name(), Mode: "link",
				Path: dst, Source: src, InstalledAt: time.Now(),
			})
		}
		count++
	}
	return count, nil
}

func (in *Installer) uninstallCodexHooks(domain, srcDir string) error {
	entries, err := os.ReadDir(srcDir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		in.uninstallOne(domain, "hooks", entry.Name(), in.codexHookDestination(entry.Name()))
	}
	return nil
}
