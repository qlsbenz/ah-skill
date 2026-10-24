package lockfile

import (
	"path/filepath"
	"testing"
	"time"
)

func TestLockfileRoundTrip(t *testing.T) {
	projectRoot := t.TempDir()

	lock := &Lockfile{}
	entry := Entry{
		Domain:      "git",
		Kind:        "skill",
		Name:        "git-conventional-commits",
		Mode:        "link",
		Path:        filepath.Join(projectRoot, ".agents", "skills", "git-conventional-commits"),
		Source:      "/harness/domains/git/skills/git-conventional-commits",
		InstalledAt: time.Now(),
	}
	lock.Record(entry)

	if err := lock.Save(projectRoot); err != nil {
		t.Fatalf("save: %v", err)
	}

	loaded, err := Load(projectRoot)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(loaded.Entries) != 1 {
		t.Fatalf("got %d entries, want 1", len(loaded.Entries))
	}

	got, ok := loaded.Owns(entry.Path)
	if !ok {
		t.Fatalf("Owns(%q) = false, want true", entry.Path)
	}
	if got.Domain != entry.Domain || got.Kind != entry.Kind || got.Name != entry.Name || got.Source != entry.Source {
		t.Fatalf("round-tripped entry = %+v, want %+v", got, entry)
	}

	if _, ok := loaded.Owns(filepath.Join(projectRoot, "nope")); ok {
		t.Fatal("Owns() found an entry for a path that was never recorded")
	}
}
