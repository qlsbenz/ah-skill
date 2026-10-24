package transfer

import (
	"os"
	"path/filepath"
	"testing"

	"ah-skills/tools/internal/lockfile"
)

func TestLinkOneCreatesAbsoluteTargetSymlink(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	if err := os.WriteFile(src, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(dir, "dst")
	lock := &lockfile.Lockfile{}

	if err := LinkOne(src, dst, false, false, lock); err != nil {
		t.Fatalf("LinkOne: %v", err)
	}

	fi, err := os.Lstat(dst)
	if err != nil {
		t.Fatalf("Lstat(dst): %v", err)
	}
	if fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("dst is not a symlink: mode=%v", fi.Mode())
	}
	target, err := os.Readlink(dst)
	if err != nil {
		t.Fatalf("Readlink: %v", err)
	}
	if target != src {
		t.Fatalf("symlink target = %q, want %q", target, src)
	}
	if !filepath.IsAbs(target) {
		t.Fatalf("symlink target %q is not absolute", target)
	}
}

func TestLinkOneReplacesPreExistingContent(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, dst string)
	}{
		{
			name: "file",
			setup: func(t *testing.T, dst string) {
				if err := os.WriteFile(dst, []byte("old file"), 0o644); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "dir",
			setup: func(t *testing.T, dst string) {
				if err := os.MkdirAll(filepath.Join(dst, "nested"), 0o755); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "symlink",
			setup: func(t *testing.T, dst string) {
				elsewhere := filepath.Join(filepath.Dir(dst), "elsewhere")
				if err := os.WriteFile(elsewhere, []byte("x"), 0o644); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(elsewhere, dst); err != nil {
					t.Fatal(err)
				}
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			src := filepath.Join(dir, "src")
			if err := os.WriteFile(src, []byte("new content"), 0o644); err != nil {
				t.Fatal(err)
			}
			dst := filepath.Join(dir, "dst")
			tc.setup(t, dst)

			lock := &lockfile.Lockfile{}

			if err := LinkOne(src, dst, false, true, lock); err != nil {
				t.Fatalf("LinkOne with force: %v", err)
			}

			fi, err := os.Lstat(dst)
			if err != nil {
				t.Fatalf("Lstat(dst): %v", err)
			}
			if fi.Mode()&os.ModeSymlink == 0 {
				t.Fatalf("dst was not replaced with a symlink: mode=%v", fi.Mode())
			}
			target, err := os.Readlink(dst)
			if err != nil {
				t.Fatal(err)
			}
			if target != src {
				t.Fatalf("target = %q, want %q", target, src)
			}
		})
	}
}

func TestLinkOneDryRunLeavesNothing(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	if err := os.WriteFile(src, []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(dir, "dst")
	lock := &lockfile.Lockfile{}

	if err := LinkOne(src, dst, true, false, lock); err != nil {
		t.Fatalf("LinkOne dry-run: %v", err)
	}
	if _, err := os.Lstat(dst); !os.IsNotExist(err) {
		t.Fatalf("expected dst to not exist after dry-run, Lstat err = %v", err)
	}
}

func TestLinkOneRefusesUntrackedExistingContentWithoutForce(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	if err := os.WriteFile(src, []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(dir, "dst")
	if err := os.WriteFile(dst, []byte("pre-existing, not tracked"), 0o644); err != nil {
		t.Fatal(err)
	}
	lock := &lockfile.Lockfile{}

	err := LinkOne(src, dst, false, false, lock)
	if err == nil {
		t.Fatal("expected error refusing untracked existing content without --force")
	}

	got, readErr := os.ReadFile(dst)
	if readErr != nil {
		t.Fatalf("dst should still exist: %v", readErr)
	}
	if string(got) != "pre-existing, not tracked" {
		t.Fatalf("dst content changed despite refusal: %q", got)
	}
}
