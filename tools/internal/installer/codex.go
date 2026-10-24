package installer

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"ah-skills/tools/internal/lockfile"
	"ah-skills/tools/internal/registry"
	"ah-skills/tools/internal/transfer"
)

const codexInstructions = `
## Codex runtime

Paths below are relative to the target project root. Read referenced rules explicitly;
.agents/rules and .agents/agents contain supporting instructions, not auto-loaded
Codex rules or registered agent types. Resolve missing dependencies before proceeding.
Use Codex's available delegation tools for Task/subagent instructions, passing the
referenced agent file in the prompt. If delegation is unavailable, perform the roles sequentially and disclose
that no independent subagent review occurred. Preserve each role's read/write scope.
After code edits, run the project's relevant tests and report actual results before
declaring completion. The code domain's test gate requires a successful full
test run after test files change before Stop or SubagentStop when the hook is trusted.

`

var invocation = regexp.MustCompile("(^|[\\s`\"(])/(code-[a-z-]+|git-[a-z-]+|caveman|memory-bank(?:-defrag)?)\\b")

func codexMarkdown(data []byte, name string) []byte {
	s := string(data)
	// Slash commands are invocation examples only, never directory components.
	s = invocation.ReplaceAllStringFunc(s, func(match string) string {
		i := strings.LastIndex(match, "/")
		name := match[i+1:]
		if name == "content-zavod" {
			name = "content-factory"
		}
		return match[:i] + "$" + name
	})
	if strings.HasPrefix(s, "---\n") {
		if end := strings.Index(s[4:], "\n---"); end >= 0 {
			end += 8
			s = s[:end] + "\n" + codexInstructions + s[end:]
		}
	}
	return []byte(s)
}

func (in *Installer) placeCodex(domain, kind, name, src, dst string) (int, error) {
	if kind != "skill" && name == "" {
		entries, err := os.ReadDir(src)
		if err != nil {
			return 0, err
		}
		n := 0
		for _, e := range entries {
			if kind == "skills" {
				if err := validateCodexSkill(filepath.Join(src, e.Name()), e.Name()); err != nil {
					fmt.Fprintf(os.Stderr, "ah-skills: skipping Codex skill %s: %v\n", e.Name(), err)
					continue
				}
			}
			if e.Type()&os.ModeSymlink != 0 {
				return n, fmt.Errorf("Codex export does not accept source symlink %s", e.Name())
			}
			count, err := in.placeCodex(domain, kind, e.Name(), filepath.Join(src, e.Name()), filepath.Join(dst, e.Name()))
			if err != nil {
				return n, err
			}
			n += count
		}
		return n, nil
	}
	if kind == "skill" {
		kind = "skills"
	}
	// Never follow a destination symlink, including a symlinked parent directory.
	for p := dst; ; p = filepath.Dir(p) {
		fi, err := os.Lstat(p)
		if err == nil && fi.Mode()&os.ModeSymlink != 0 {
			return 0, fmt.Errorf("refusing symlink destination %s", p)
		}
		if err != nil && !os.IsNotExist(err) {
			return 0, err
		}
		if p == in.ProjectRoot || p == filepath.Dir(p) {
			break
		}
	}
	if _, err := os.Lstat(dst); err == nil {
		entry, owned := in.Lock.Owns(dst)
		if !owned && !in.Force {
			return 0, fmt.Errorf("refusing untracked destination %s (use --force to replace)", dst)
		}
		if owned && !in.Force {
			hash, err := transfer.HashTree(dst)
			if err != nil {
				return 0, err
			}
			if entry.SHA256 != hash {
				return 0, fmt.Errorf("refusing modified destination %s (use --force to replace)", dst)
			}
		}
	}
	if in.DryRun {
		return 1, nil
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return 0, err
	}
	stage, err := os.MkdirTemp(filepath.Dir(dst), ".ah-skills-")
	if err != nil {
		return 0, err
	}
	defer os.RemoveAll(stage)
	output := filepath.Join(stage, "output")
	info, err := os.Stat(src)
	if err != nil {
		return 0, err
	}
	if info.IsDir() {
		if _, err := transfer.CopyTree(src, output, false); err != nil {
			return 0, err
		}
	} else {
		data, err := os.ReadFile(src)
		if err != nil {
			return 0, err
		}
		if kind == "hooks" && name == "hooks.json" {
			script := filepath.Join(in.ProjectRoot, ".codex", "hooks", "test_gate.py")
			command := "python3 '" + strings.ReplaceAll(script, "'", "'\"'\"'") + "'"
			data = bytes.ReplaceAll(data, []byte(`"__TEST_GATE_COMMAND__"`), []byte(strconv.Quote(command)))
		}
		if err := os.WriteFile(output, data, info.Mode().Perm()); err != nil {
			return 0, err
		}
	}
	err = filepath.WalkDir(output, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(p, ".md") && p != output {
			return nil
		}
		if !d.IsDir() && (strings.HasSuffix(p, ".md") || strings.HasSuffix(src, ".md")) {
			data, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			return os.WriteFile(p, codexMarkdown(data, name), 0644)
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	hash, err := transfer.HashTree(output)
	if err != nil {
		return 0, err
	}
	// Keep the old item until the new export is fully prepared; restore on failure.
	backup := filepath.Join(stage, "previous")
	existed := false
	if _, err := os.Lstat(dst); err == nil {
		if err := os.Rename(dst, backup); err != nil {
			return 0, err
		}
		existed = true
	}
	if err := os.Rename(output, dst); err != nil {
		if existed {
			if restoreErr := os.Rename(backup, dst); restoreErr != nil {
				return 0, fmt.Errorf("install: %v; restore: %v", err, restoreErr)
			}
		}
		return 0, err
	}
	in.Lock.Record(lockfile.Entry{Domain: domain, Kind: kind, Name: name, Mode: "copy", Path: dst, Source: src, SHA256: hash, InstalledAt: time.Now()})
	if err := in.Lock.Save(in.ProjectRoot, "codex"); err != nil {
		return 0, err
	}
	return 1, nil
}

func validateCodexSkill(src, name string) error {
	parsed, hasName, hasDescription, err := registry.ParseSkillFrontmatter(filepath.Join(src, "SKILL.md"))
	if err != nil {
		return err
	}
	if !hasName || !hasDescription || parsed != name {
		return fmt.Errorf("invalid skill metadata for %s", name)
	}
	return nil
}
