package installer

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"ah-skills/tools/internal/lockfile"
	"ah-skills/tools/internal/registry"
)

func TestUninstallOneRemovesOnlyTrackedEntriesMatchingRecordedMode(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	if err := os.WriteFile(src, []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}

	linked := filepath.Join(dir, "linked")
	if err := os.Symlink(src, linked); err != nil {
		t.Fatal(err)
	}

	copied := filepath.Join(dir, "copied")
	if err := os.WriteFile(copied, []byte("copied content"), 0o644); err != nil {
		t.Fatal(err)
	}

	foreign := filepath.Join(dir, "foreign")
	if err := os.WriteFile(foreign, []byte("keep me"), 0o644); err != nil {
		t.Fatal(err)
	}

	lock := &lockfile.Lockfile{}
	lock.Record(lockfile.Entry{Domain: "d", Kind: "skill", Name: "linked", Mode: "link", Path: linked, Source: src})
	lock.Record(lockfile.Entry{Domain: "d", Kind: "skill", Name: "copied", Mode: "copy", Path: copied, Source: src})

	in := &Installer{ProjectRoot: dir, Lock: lock}
	in.uninstallOne("d", "skill", "linked", linked)
	in.uninstallOne("d", "skill", "copied", copied)
	in.uninstallOne("d", "skill", "foreign", foreign)

	if _, err := os.Lstat(linked); !os.IsNotExist(err) {
		t.Fatalf("expected tracked symlink to be removed, Lstat err = %v", err)
	}
	if _, ok := lock.Owns(linked); ok {
		t.Fatal("expected lockfile entry for the removed symlink to be dropped")
	}

	if _, err := os.Lstat(copied); !os.IsNotExist(err) {
		t.Fatalf("expected tracked copy-mode file to be removed, Lstat err = %v", err)
	}
	if _, ok := lock.Owns(copied); ok {
		t.Fatal("expected lockfile entry for the removed copy-mode file to be dropped")
	}

	if data, err := os.ReadFile(foreign); err != nil || string(data) != "keep me" {
		t.Fatalf("foreign file should survive uninstall untouched, err=%v data=%q", err, data)
	}
}

func TestUninstallOneCopyModeRemovesRealTree(t *testing.T) {
	dir := t.TempDir()
	copiedDir := filepath.Join(dir, "copied-skill")
	if err := os.MkdirAll(filepath.Join(copiedDir, "nested"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(copiedDir, "nested", "SKILL.md"), []byte("content"), 0o644); err != nil {
		t.Fatal(err)
	}

	lock := &lockfile.Lockfile{}
	lock.Record(lockfile.Entry{Domain: "d", Kind: "skill", Name: "copied-skill", Mode: "copy", Path: copiedDir, Source: "/wherever"})

	in := &Installer{ProjectRoot: dir, Lock: lock}
	in.uninstallOne("d", "skill", "copied-skill", copiedDir)

	if _, err := os.Lstat(copiedDir); !os.IsNotExist(err) {
		t.Fatalf("expected copied tree to be fully removed, Lstat err = %v", err)
	}
	if _, ok := lock.Owns(copiedDir); ok {
		t.Fatal("expected lockfile entry for the removed copy-mode tree to be dropped")
	}
}

func TestUninstallDomainCopyModeRemovesOnlyThisDomainsItems(t *testing.T) {
	harnessRoot := t.TempDir()
	for _, dom := range []string{"alpha", "beta"} {
		skillDir := filepath.Join(harnessRoot, "domains", dom, "skills", dom+"-skill")
		if err := os.MkdirAll(skillDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(skillDir, "SKILL.md"), []byte("content"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(harnessRoot, "domains", dom, "manifest.yaml"), []byte("name: "+dom+"\ndescription: d\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	reg, err := registry.LoadRegistry(harnessRoot)
	if err != nil {
		t.Fatalf("LoadRegistry: %v", err)
	}

	projectRoot := t.TempDir()
	lock := &lockfile.Lockfile{}
	in := &Installer{HarnessRoot: harnessRoot, ProjectRoot: projectRoot, Mode: "copy", Lock: lock}

	if err := in.InstallDomain(reg, "alpha", true); err != nil {
		t.Fatalf("InstallDomain alpha: %v", err)
	}
	if err := in.InstallDomain(reg, "beta", true); err != nil {
		t.Fatalf("InstallDomain beta: %v", err)
	}

	sharedDir := filepath.Join(projectRoot, ".agents", "skills")
	alphaItem := filepath.Join(sharedDir, "alpha-skill")
	betaItem := filepath.Join(sharedDir, "beta-skill")
	for _, p := range []string{alphaItem, betaItem} {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("precondition: %s should have been copy-installed: %v", p, err)
		}
	}

	if err := in.UninstallDomain(reg, "alpha"); err != nil {
		t.Fatalf("UninstallDomain alpha: %v", err)
	}

	if _, err := os.Lstat(alphaItem); !os.IsNotExist(err) {
		t.Fatalf("expected alpha's copy-mode item to be removed, Lstat err = %v", err)
	}
	if _, err := os.Stat(betaItem); err != nil {
		t.Fatalf("beta's item in the shared directory must survive alpha's uninstall: %v", err)
	}
	if _, ok := lock.Find("alpha", "skills", ""); ok {
		t.Fatal("expected alpha's whole-directory lockfile entry to be dropped")
	}
	if _, ok := lock.Find("beta", "skills", ""); !ok {
		t.Fatal("expected beta's whole-directory lockfile entry to remain")
	}
}

func TestRequiresBinGating(t *testing.T) {
	const missingBin = "as-skill-test-definitely-nonexistent-binary-xyz"
	if _, err := exec.LookPath(missingBin); err == nil {
		t.Skipf("test binary %q unexpectedly found on $PATH", missingBin)
	}

	m := &registry.Manifest{Name: "testdomain", RequiresBin: []string{missingBin}, Targets: map[string]string{}}
	reg := &registry.Registry{Domains: map[string]*registry.Manifest{"testdomain": m}, Order: []string{"testdomain"}}

	dir := t.TempDir()

	t.Run("strict explicit domain hard-errors", func(t *testing.T) {
		in := &Installer{HarnessRoot: dir, ProjectRoot: dir, Mode: "copy", Lock: &lockfile.Lockfile{}}
		if err := in.InstallDomain(reg, "testdomain", true); err == nil {
			t.Fatal("expected strict install to fail when the required binary is missing")
		}
	})

	t.Run("warn-and-skip in all mode returns nil", func(t *testing.T) {
		in := &Installer{HarnessRoot: dir, ProjectRoot: dir, Mode: "copy", Lock: &lockfile.Lockfile{}}
		if err := in.InstallDomain(reg, "testdomain", false); err != nil {
			t.Fatalf("expected warn-and-skip install to return nil, got %v", err)
		}
		if len(in.Lock.Entries) != 0 {
			t.Fatalf("expected nothing to be installed/recorded, got %d lockfile entries", len(in.Lock.Entries))
		}
	})
}

func TestRequiresBinGatingSkillOwnerDomainAlwaysStrict(t *testing.T) {
	const missingBin = "as-skill-test-definitely-nonexistent-binary-xyz"
	if _, err := exec.LookPath(missingBin); err == nil {
		t.Skipf("test binary %q unexpectedly found on $PATH", missingBin)
	}

	harnessRoot := t.TempDir()
	skillDir := filepath.Join(harnessRoot, "domains", "testdomain", "skills", "myskill")
	if err := os.MkdirAll(skillDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(skillDir, "SKILL.md"), []byte("---\nname: myskill\n---\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	m := &registry.Manifest{Name: "testdomain", RequiresBin: []string{missingBin}, Targets: map[string]string{}}
	reg := &registry.Registry{Domains: map[string]*registry.Manifest{"testdomain": m}, Order: []string{"testdomain"}}

	projectRoot := t.TempDir()
	in := &Installer{HarnessRoot: harnessRoot, ProjectRoot: projectRoot, Mode: "copy", Lock: &lockfile.Lockfile{}}

	if err := in.InstallSkill(reg, "myskill"); err == nil {
		t.Fatal("expected InstallSkill to hard-error when the owner domain's required binary is missing")
	}
}
