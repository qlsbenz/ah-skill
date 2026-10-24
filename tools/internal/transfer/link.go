package transfer

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"ah-skills/tools/internal/lockfile"
)

func LinkOne(src, dst string, dryRun, force bool, lock *lockfile.Lockfile) error {
	if _, err := os.Lstat(dst); err == nil {
		entry, tracked := lock.Owns(dst)
		if !tracked && !force {
			return fmt.Errorf("%s exists, not tracked by ah-skills, use --force", dst)
		}
		if tracked && entry.Mode != "link" {
			fmt.Fprintf(os.Stderr, "ah-skills: warning: %s was installed via %q, replacing with a link — mixed channels may cause confusion\n", dst, entry.Mode)
		}
		if !dryRun {
			if err := os.RemoveAll(dst); err != nil {
				return fmt.Errorf("removing %s: %w", dst, err)
			}
		}
	} else if !os.IsNotExist(err) {
		return err
	}

	if dryRun {
		return nil
	}
	if err := os.Symlink(src, dst); err != nil {
		return fmt.Errorf("linking %s -> %s: %w", src, dst, err)
	}
	return nil
}

func LinkTree(domain, kind, src, dstDir string, dryRun, force bool, lock *lockfile.Lockfile) (int, error) {
	entries, err := os.ReadDir(src)
	if err != nil {
		return 0, err
	}
	if !dryRun {
		if err := os.MkdirAll(dstDir, 0o755); err != nil {
			return 0, err
		}
	}
	count := 0
	for _, e := range entries {
		name := e.Name()
		srcPath := filepath.Join(src, name)
		dstPath := filepath.Join(dstDir, name)
		if err := LinkOne(srcPath, dstPath, dryRun, force, lock); err != nil {
			return count, err
		}
		count++
		if !dryRun {
			lock.Record(lockfile.Entry{
				Domain:      domain,
				Kind:        kind,
				Name:        name,
				Mode:        "link",
				Path:        dstPath,
				Source:      srcPath,
				InstalledAt: time.Now(),
			})
		}
	}
	return count, nil
}
