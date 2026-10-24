package cli

import (
	"os"
	"path/filepath"
	"testing"

	"ah-skills/tools/internal/lockfile"
)

func fakeHarnessWithSkill(t *testing.T) (harnessRoot, skillDir string) {
	t.Helper()
	harnessRoot = t.TempDir()
	skillDir = filepath.Join(harnessRoot, "domains", "testdomain", "skills", "myskill")
	if err := os.MkdirAll(skillDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(skillDir, "SKILL.md"), []byte("---\nname: myskill\ndescription: test\n---\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(harnessRoot, "domains", "testdomain", "manifest.yaml"), []byte("name: testdomain\ndescription: test domain\n"), 0644); err != nil {
		t.Fatal(err)
	}
	return harnessRoot, skillDir
}

func TestDefaultInstallIsCodexSnapshot(t *testing.T) {
	harness, skill := fakeHarnessWithSkill(t)
	project := t.TempDir()
	if err := Run([]string{"install", "skill", "myskill", "--project", project, "--harness-root", harness}); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(project, ".agents", "skills", "myskill")
	fi, err := os.Lstat(dst)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		t.Fatal("Codex skill must be a snapshot")
	}
	if _, err := os.Stat(filepath.Join(dst, "SKILL.md")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(project, ".claude")); !os.IsNotExist(err) {
		t.Fatal("default install wrote .claude")
	}
	lock, err := lockfile.Load(project, "codex")
	if err != nil {
		t.Fatal(err)
	}
	entry, ok := lock.Owns(dst)
	if !ok || entry.Mode != "copy" || entry.Source != skill {
		t.Fatalf("unexpected lock entry: %+v", entry)
	}
	if err := Run([]string{"uninstall", "skill", "myskill", "--project", project, "--harness-root", harness}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(dst); !os.IsNotExist(err) {
		t.Fatal("uninstall left skill on disk")
	}
}

func TestClaudeTargetRejected(t *testing.T) {
	for _, command := range []string{"install", "uninstall", "status", "doctor"} {
		args := []string{command}
		if command == "install" || command == "uninstall" {
			args = append(args, "all")
		}
		if err := Run(append(args, "--target=claude")); err == nil {
			t.Fatalf("%s accepted Claude target", command)
		}
	}
}
