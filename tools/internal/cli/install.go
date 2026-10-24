package cli

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"ah-skills/tools/internal/installer"
	"ah-skills/tools/internal/lockfile"
	"ah-skills/tools/internal/registry"
)

type installOpts struct {
	target      string
	project     string
	harnessRoot string
	dryRun      bool
	force       bool
	copy        bool
}

func parseInstallArgs(args []string) ([]string, installOpts, error) {
	opts := installOpts{target: "codex", project: ".", harnessRoot: "."}
	var positionals []string

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
				return nil, opts, err
			}
			opts.project = v
		case "--target":
			v, err := takeValue()
			if err != nil {
				return nil, opts, err
			}
			if v != "codex" {
				return nil, opts, fmt.Errorf("unknown target %q (want codex)", v)
			}
			opts.target = v
		case "--harness-root":
			v, err := takeValue()
			if err != nil {
				return nil, opts, err
			}
			opts.harnessRoot = v
		case "--dry-run":
			opts.dryRun = true
		case "--force":
			opts.force = true
		case "--copy":
			opts.copy = true
		default:
			if strings.HasPrefix(a, "-") {
				return nil, opts, fmt.Errorf("unknown flag %q", a)
			}
			positionals = append(positionals, a)
		}
	}
	return positionals, opts, nil
}

func runInstall(args []string) error {
	if len(args) == 0 {
		return errors.New("install needs a verb: domain|domains|all|skill")
	}
	verb := args[0]
	positionals, opts, err := parseInstallArgs(args[1:])
	if err != nil {
		return err
	}
	if opts.target == "codex" {
		fmt.Println("Codex: installing project-local skills and hooks (reinstall to refresh snapshots)")
	}
	mode := "link"
	if opts.copy {
		mode = "copy"
	}

	harnessRoot, err := registry.ResolveHarnessRoot(opts.harnessRoot)
	if err != nil {
		return err
	}
	projectRoot, err := filepath.Abs(opts.project)
	if err != nil {
		return err
	}
	reg, err := registry.LoadRegistry(harnessRoot)
	if err != nil {
		return err
	}
	lock, err := lockfile.Load(projectRoot, opts.target)
	if err != nil {
		return err
	}
	in := &installer.Installer{
		HarnessRoot: harnessRoot, ProjectRoot: projectRoot, Target: opts.target,
		DryRun: opts.dryRun, Force: opts.force, Mode: mode, Lock: lock,
	}

	switch verb {
	case "domain":
		if len(positionals) != 1 {
			return errors.New("install domain needs exactly one domain name")
		}
		if err := in.InstallDomain(reg, positionals[0], true); err != nil {
			return err
		}
	case "domains":
		if len(positionals) == 0 {
			return errors.New("install domains needs at least one domain name")
		}
		for _, name := range positionals {
			if err := in.InstallDomain(reg, name, true); err != nil {
				return err
			}
		}
	case "all":
		if len(positionals) != 0 {
			return fmt.Errorf("install all takes no domain names (got %s)", strings.Join(positionals, ", "))
		}
		for _, name := range reg.DomainNames() {
			if err := in.InstallDomain(reg, name, false); err != nil {
				return err
			}
		}
	case "skill":
		if len(positionals) != 1 {
			return errors.New("install skill needs exactly one skill name")
		}
		if err := in.InstallSkill(reg, positionals[0]); err != nil {
			return err
		}
	default:
		return fmt.Errorf("unknown install verb %q (want domain|domains|all|skill)", verb)
	}

	fmt.Printf("done -> %s\n", filepath.Join(projectRoot, lockfile.Home(opts.target)))
	if !opts.dryRun {
		if err := lock.Save(projectRoot, opts.target); err != nil {
			return fmt.Errorf("saving lockfile: %w", err)
		}
	}
	return nil
}
