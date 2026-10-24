package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"ah-skills/tools/internal/fsutil"
	"ah-skills/tools/internal/registry"
)

func runCheck(args []string) error {
	if len(args) != 0 {
		return fmt.Errorf("check takes no arguments (got %s)", strings.Join(args, " "))
	}
	harnessRoot, err := registry.ResolveHarnessRoot(".")
	if err != nil {
		return err
	}

	var failures []string

	domainsDir := filepath.Join(harnessRoot, "domains")
	domainEntries, err := os.ReadDir(domainsDir)
	if err != nil {
		return fmt.Errorf("reading %s: %w", domainsDir, err)
	}
	var domainNames []string
	for _, de := range domainEntries {
		if !de.IsDir() {
			continue
		}
		domainNames = append(domainNames, de.Name())
		manifestPath := filepath.Join(domainsDir, de.Name(), "manifest.yaml")
		if !fsutil.FileExists(manifestPath) {
			failures = append(failures, fmt.Sprintf("%s: missing manifest.yaml", manifestPath))
			continue
		}
		m, err := registry.ParseManifest(manifestPath)
		if err != nil {
			failures = append(failures, err.Error())
			continue
		}
		if strings.TrimSpace(m.Description) == "" {
			failures = append(failures, fmt.Sprintf("%s: missing top-level \"description:\"", manifestPath))
		}
	}
	sort.Strings(domainNames)

	var skillMDs []string
	for _, name := range domainNames {
		matches, _ := filepath.Glob(filepath.Join(domainsDir, name, "skills", "*", "SKILL.md"))
		skillMDs = append(skillMDs, matches...)
	}
	sort.Strings(skillMDs)

	for _, path := range skillMDs {
		dirName := filepath.Base(filepath.Dir(path))
		name, hasName, hasDescription, err := registry.ParseSkillFrontmatter(path)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", path, err))
			continue
		}
		if !hasName {
			failures = append(failures, fmt.Sprintf("%s: frontmatter missing \"name:\"", path))
		} else if name != dirName {
			failures = append(failures, fmt.Sprintf("%s: frontmatter name %q does not match directory name %q", path, name, dirName))
		}
		if !hasDescription {
			failures = append(failures, fmt.Sprintf("%s: frontmatter missing \"description:\"", path))
		}
	}

	if len(failures) > 0 {
		for _, f := range failures {
			fmt.Fprintln(os.Stderr, "ah-skills: check:", f)
		}
		return fmt.Errorf("check: %d failure(s)", len(failures))
	}
	fmt.Printf("check: OK — %d manifest(s), %d SKILL.md(s)\n", len(domainNames), len(skillMDs))
	return nil
}
