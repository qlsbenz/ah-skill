package cli

import (
	"fmt"
	"path/filepath"

	"ah-skills/tools/internal/fsutil"
	"ah-skills/tools/internal/health"
	"ah-skills/tools/internal/lockfile"
	"ah-skills/tools/internal/registry"
	"ah-skills/tools/internal/transfer"
)

func runDoctor(args []string) error {
	opts, err := parseStatusArgs(args)
	if err != nil {
		return err
	}
	harnessRoot, err := registry.ResolveHarnessRoot(opts.harnessRoot)
	if err != nil {
		return err
	}
	projectRoot, err := filepath.Abs(opts.project)
	if err != nil {
		return err
	}
	lock, err := lockfile.Load(projectRoot, opts.target)
	if err != nil {
		return err
	}

	entries := health.SortedEntries(lock)
	problems := 0
	if len(entries) == 0 {
		fmt.Println("no entries tracked in skills-lock.json")
	} else {
		fmt.Printf("%-10s %-8s %-24s %-6s %-11s %s\n", "DOMAIN", "KIND", "NAME", "MODE", "HEALTH", "PATH")
	}
	for _, e := range entries {
		h := health.EntryHealth(e)
		fmt.Printf("%-10s %-8s %-24s %-6s %-11s %s\n", e.Domain, e.Kind, e.Name, e.Mode, h, e.Path)
		if h == health.HealthMissing || h == health.HealthBroken {
			problems++
		}

		switch e.Mode {
		case "link":
			if !fsutil.PathExists(e.Source) {
				fmt.Printf("ah-skills: doctor: %-11s %s/%s/%s — source %s no longer exists under harness root %s\n",
					health.HealthSourceGone, e.Domain, e.Kind, e.Name, e.Source, harnessRoot)
				problems++
			}
		case "copy":
			if h == health.HealthMissing {
				continue
			}
			hash, herr := transfer.HashTree(e.Path)
			if herr != nil {
				fmt.Printf("ah-skills: doctor: warning: %s/%s/%s — could not hash %s: %v\n", e.Domain, e.Kind, e.Name, e.Path, herr)
				continue
			}
			if e.SHA256 != "" && hash != e.SHA256 {
				fmt.Printf("ah-skills: doctor: %-11s %s/%s/%s — recomputed hash differs from the recorded SHA256 (ambiguous: the target may have been hand-edited, or the source in domains/ may have moved on since install — not disambiguated)\n",
					health.HealthDrifted, e.Domain, e.Kind, e.Name)
				problems++
			}
		}
	}

	untracked, err := health.FindUntracked(projectRoot, lock, opts.target)
	if err != nil {
		return err
	}
	for _, p := range untracked {
		fmt.Printf("ah-skills: doctor: %-11s %s — present on disk, no lockfile entry\n", health.HealthUntracked, p)
		problems++
	}
	if _, tracked := lock.Owns(filepath.Join(projectRoot, ".codex", "hooks.json")); tracked {
		fmt.Println("ah-skills: doctor: check /hooks in Codex to review and trust the project hook")
	}

	if problems > 0 {
		return fmt.Errorf("doctor: %d finding(s)", problems)
	}
	return nil
}
