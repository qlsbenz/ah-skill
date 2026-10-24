package cli

import (
	"fmt"
	"path/filepath"
	"strings"

	"ah-skills/tools/internal/health"
	"ah-skills/tools/internal/lockfile"
)

type statusOpts struct {
	target      string
	project     string
	harnessRoot string
}

func parseStatusArgs(args []string) (statusOpts, error) {
	opts := statusOpts{target: "codex", project: ".", harnessRoot: "."}
	for i := 0; i < len(args); i++ {
		a := args[i]
		key, val, hasVal := a, "", false
		if strings.HasPrefix(a, "--") {
			if before, after, found := strings.Cut(a, "="); found {
				key, val, hasVal = before, after, true
			}
		}
		takeValue := func() (string, error) {
			if hasVal {
				return val, nil
			}
			i++
			if i >= len(args) {
				return "", fmt.Errorf("%s needs a value", key)
			}
			return args[i], nil
		}
		switch key {
		case "--project", "-p":
			v, err := takeValue()
			if err != nil {
				return opts, err
			}
			opts.project = v
		case "--target":
			v, err := takeValue()
			if err != nil {
				return opts, err
			}
			if v != "codex" {
				return opts, fmt.Errorf("unknown target %q (want codex)", v)
			}
			opts.target = v
		case "--harness-root":
			v, err := takeValue()
			if err != nil {
				return opts, err
			}
			opts.harnessRoot = v
		default:
			return opts, fmt.Errorf("unknown flag %q", a)
		}
	}
	return opts, nil
}

func runStatus(args []string) error {
	opts, err := parseStatusArgs(args)
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
	health.PrintEntryTable(health.SortedEntries(lock), health.EntryHealth)
	return nil
}
