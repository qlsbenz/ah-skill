package registry

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var DomainKinds = []string{"rules", "skills", "agents", "hooks"}

func dirExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

type Manifest struct {
	Name        string
	Description string
	RequiresEnv []string
	RequiresBin []string
	Targets     map[string]string
}

func ParseManifest(path string) (*Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	m := &Manifest{Targets: map[string]string{}}
	lines := strings.Split(string(data), "\n")

	i := 0
	for i < len(lines) {
		trimmed := strings.TrimSpace(lines[i])
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			i++
			continue
		}
		switch {
		case strings.HasPrefix(trimmed, "name:"):
			m.Name = strings.TrimSpace(strings.TrimPrefix(trimmed, "name:"))
			i++
		case strings.HasPrefix(trimmed, "description:"):
			m.Description = strings.TrimSpace(strings.TrimPrefix(trimmed, "description:"))
			i++
		case strings.HasPrefix(trimmed, "requires_env:"):
			rest := strings.TrimSpace(strings.TrimPrefix(trimmed, "requires_env:"))
			i++
			if rest != "" {
				continue
			}
			for i < len(lines) {
				t := strings.TrimSpace(lines[i])
				if !strings.HasPrefix(t, "- ") {
					break
				}
				m.RequiresEnv = append(m.RequiresEnv, strings.TrimSpace(strings.TrimPrefix(t, "- ")))
				i++
			}
		case strings.HasPrefix(trimmed, "requires_bin:"):
			rest := strings.TrimSpace(strings.TrimPrefix(trimmed, "requires_bin:"))
			i++
			if rest != "" {
				continue
			}
			for i < len(lines) {
				t := strings.TrimSpace(lines[i])
				if !strings.HasPrefix(t, "- ") {
					break
				}
				m.RequiresBin = append(m.RequiresBin, strings.TrimSpace(strings.TrimPrefix(t, "- ")))
				i++
			}
		case strings.HasPrefix(trimmed, "targets:"):
			i++
			for i < len(lines) {
				raw := lines[i]
				t := strings.TrimSpace(raw)
				if t == "" {
					i++
					continue
				}
				if !strings.HasPrefix(raw, " ") && !strings.HasPrefix(raw, "\t") {
					break
				}
				key, val, ok := strings.Cut(t, ":")
				if ok {
					m.Targets[strings.TrimSpace(key)] = strings.TrimSpace(val)
				}
				i++
			}
		default:
			i++
		}
	}
	if m.Name == "" {
		return nil, fmt.Errorf("%s: missing top-level \"name:\"", path)
	}
	return m, nil
}

func ParseSkillFrontmatter(path string) (name string, hasName bool, hasDescription bool, err error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false, false, err
	}
	lines := strings.Split(string(data), "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return "", false, false, fmt.Errorf("missing frontmatter (file does not start with \"---\")")
	}
	i := 1
	for i < len(lines) && strings.TrimSpace(lines[i]) != "---" {
		trimmed := strings.TrimSpace(lines[i])
		switch {
		case strings.HasPrefix(trimmed, "name:"):
			name = strings.TrimSpace(strings.TrimPrefix(trimmed, "name:"))
			hasName = name != ""
		case strings.HasPrefix(trimmed, "description:"):
			rest := strings.TrimSpace(strings.TrimPrefix(trimmed, "description:"))
			hasDescription = rest != ""
		}
		i++
	}
	if i >= len(lines) {
		return name, hasName, hasDescription, fmt.Errorf("frontmatter not terminated with a closing \"---\"")
	}
	return name, hasName, hasDescription, nil
}

type Registry struct {
	Domains map[string]*Manifest
	Order   []string
}

func (r *Registry) DomainNames() []string { return r.Order }

func LoadRegistry(harnessRoot string) (*Registry, error) {
	reg := &Registry{Domains: map[string]*Manifest{}}

	domainsDir := filepath.Join(harnessRoot, "domains")
	entries, err := os.ReadDir(domainsDir)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", domainsDir, err)
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		manifestPath := filepath.Join(domainsDir, e.Name(), "manifest.yaml")
		if !fileExists(manifestPath) {
			continue
		}
		m, err := ParseManifest(manifestPath)
		if err != nil {
			return nil, fmt.Errorf("parsing %s: %w", manifestPath, err)
		}
		reg.Domains[e.Name()] = m
		reg.Order = append(reg.Order, e.Name())
	}
	sort.Strings(reg.Order)
	if len(reg.Domains) == 0 {
		return nil, fmt.Errorf("no domains with manifest.yaml found under %s", domainsDir)
	}

	return reg, nil
}

func ResolveHarnessRoot(start string) (string, error) {
	abs, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	dir := abs
	for {
		if dirExists(filepath.Join(dir, "domains")) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no ah-skills checkout found at or above %q (looked for domains/) — pass --harness-root", abs)
		}
		dir = parent
	}
}
