package transfer

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

func CopyTree(src, dst string, dryRun bool) (int, error) {
	info, err := os.Stat(src)
	if err != nil {
		return 0, err
	}
	if !info.IsDir() {
		return 0, fmt.Errorf("%s is not a directory", src)
	}
	count := 0
	err = filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			if dryRun {
				return nil
			}
			return os.MkdirAll(target, 0o755)
		}
		if d.Type()&fs.ModeSymlink != 0 {
			fmt.Fprintf(os.Stderr, "ah-skills: warning: skipping symlink %s\n", path)
			return nil
		}
		count++
		if dryRun {
			return nil
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		return copyFile(path, target)
	})
	return count, err
}

func copyFile(src, dst string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Chmod(info.Mode().Perm())
}

func MakeShellScriptsExecutable(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sh") {
			continue
		}
		p := filepath.Join(dir, e.Name())
		info, err := os.Stat(p)
		if err != nil {
			return err
		}
		if err := os.Chmod(p, info.Mode().Perm()|0o111); err != nil {
			return err
		}
	}
	return nil
}

func WarnHooksNotExecutable(srcDir string) {
	entries, err := os.ReadDir(srcDir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sh") {
			continue
		}
		info, err := e.Info()
		if err != nil || info.Mode().Perm()&0o111 != 0 {
			continue
		}
		fmt.Fprintf(os.Stderr, "ah-skills: warning: %s is not executable; the symlinked hook won't be either (fix it in domains/)\n", filepath.Join(srcDir, e.Name()))
	}
}
