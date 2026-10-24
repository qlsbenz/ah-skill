package fsutil

import (
	"os"
	"os/exec"
)

func DirExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func FileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

func PathExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func HasBin(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}
