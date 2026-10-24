package health

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"ah-skills/tools/internal/lockfile"
	"ah-skills/tools/internal/registry"
)

const (
	HealthOK         = "OK"
	HealthMissing    = "MISSING"
	HealthBroken     = "BROKEN"
	HealthSourceGone = "SOURCE-GONE"
	HealthDrifted    = "DRIFTED"
	HealthUntracked  = "UNTRACKED"
)

func EntryHealth(e lockfile.Entry) string {
	fi, err := os.Lstat(e.Path)
	if err != nil {
		return HealthMissing
	}
	if e.Mode == "link" {
		if fi.Mode()&os.ModeSymlink == 0 {
			return HealthBroken
		}
		target, err := os.Readlink(e.Path)
		if err != nil || target != e.Source {
			return HealthBroken
		}
	}
	return HealthOK
}

func SortedEntries(lock *lockfile.Lockfile) []lockfile.Entry {
	entries := append([]lockfile.Entry(nil), lock.Entries...)
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Domain != entries[j].Domain {
			return entries[i].Domain < entries[j].Domain
		}
		if entries[i].Kind != entries[j].Kind {
			return entries[i].Kind < entries[j].Kind
		}
		return entries[i].Name < entries[j].Name
	})
	return entries
}

func PrintEntryTable(entries []lockfile.Entry, healthOf func(lockfile.Entry) string) {
	if len(entries) == 0 {
		fmt.Println("no entries tracked in skills-lock.json")
		return
	}
	fmt.Printf("%-10s %-8s %-24s %-6s %-11s %s\n", "DOMAIN", "KIND", "NAME", "MODE", "HEALTH", "PATH")
	for _, e := range entries {
		fmt.Printf("%-10s %-8s %-24s %-6s %-11s %s\n", e.Domain, e.Kind, e.Name, e.Mode, healthOf(e), e.Path)
	}
}

func FindUntracked(projectRoot string, lock *lockfile.Lockfile, target ...string) ([]string, error) {
	tracked := map[string]bool{}
	for _, e := range lock.Entries {
		tracked[filepath.Clean(e.Path)] = true
	}
	var untracked []string
	for _, kind := range registry.DomainKinds {
		dir := filepath.Join(projectRoot, lockfile.Home(target...), kind)
		entries, err := os.ReadDir(dir)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, err
		}
		for _, e := range entries {
			p := filepath.Join(dir, e.Name())
			if !tracked[filepath.Clean(p)] {
				untracked = append(untracked, p)
			}
		}
	}
	sort.Strings(untracked)
	return untracked, nil
}
