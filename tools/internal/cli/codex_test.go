package cli

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"ah-skills/tools/internal/lockfile"
	"ah-skills/tools/internal/registry"
)

func TestCodexLifecycle(t *testing.T) {
	harness, skill := fakeHarnessWithSkill(t)
	original := "---\nname: myskill\ndescription: test\n---\nRead `.agents/rules/test.md`. Use `/code-plan`. Read `.agents/agents/code-planner.md`.\n"
	if err := os.WriteFile(filepath.Join(skill, "SKILL.md"), []byte(original), 0644); err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"rules", "agents", "hooks"} {
		dir := filepath.Join(harness, "domains", "testdomain", kind)
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "test.md"), []byte("support"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	project := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		args = append(args, "--project", project, "--harness-root", harness)
		if err := Run(args); err != nil {
			t.Fatal(err)
		}
	}
	run("install", "domain", "testdomain")
	run("install", "domain", "testdomain", "--target", "codex")
	run("doctor", "--target=codex")
	run("status", "--target=codex")
	dst := filepath.Join(project, ".agents", "skills", "myskill")
	data, err := os.ReadFile(filepath.Join(dst, "SKILL.md"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{".agents/rules/test.md", "$code-plan", ".agents/agents/code-planner.md", "Codex runtime"} {
		if !strings.Contains(string(data), want) {
			t.Errorf("missing %q in %s", want, data)
		}
	}
	if _, err := os.Stat(filepath.Join(project, ".agents", "hooks")); !os.IsNotExist(err) {
		t.Fatal("exported Claude hooks")
	}
	source, _ := os.ReadFile(filepath.Join(skill, "SKILL.md"))
	if string(source) != original {
		t.Fatal("changed source")
	}
	run("install", "skill", "myskill", "--target=codex")
	run("uninstall", "skill", "myskill", "--target=codex")
	lock, err := lockfile.Load(project, "codex")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := lock.Owns(dst); ok {
		t.Fatal("stale skill lock entry")
	}
	run("uninstall", "domain", "testdomain", "--target=codex")
	run("doctor", "--target=codex")
}

func TestCodexDryRunAndForeignProtection(t *testing.T) {
	harness, _ := fakeHarnessWithSkill(t)
	project := t.TempDir()
	args := []string{"install", "skill", "myskill", "--target=codex", "--project", project, "--harness-root", harness}
	if err := Run(append(append([]string{}, args...), "--dry-run")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(project, ".agents")); !os.IsNotExist(err) {
		t.Fatal("dry run wrote files")
	}
	dst := filepath.Join(project, ".agents", "skills", "myskill")
	if err := os.MkdirAll(dst, 0755); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(dst, "foreign.txt")
	if err := os.WriteFile(sentinel, []byte("keep"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := Run(args); err == nil {
		t.Fatal("overwrote foreign skill")
	}
	if data, _ := os.ReadFile(sentinel); string(data) != "keep" {
		t.Fatal("foreign content modified")
	}
	if err := Run(append(append([]string{}, args...), "--force")); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dst, "SKILL.md")
	if err := os.WriteFile(path, []byte("user edit"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := Run(args); err == nil {
		t.Fatal("overwrote modified export")
	}
	if err := Run([]string{"doctor", "--target=codex", "--project", project, "--harness-root", harness}); err == nil {
		t.Fatal("doctor missed drift")
	}
}

func TestCodexSingleSkillDependencies(t *testing.T) {
	harness, _ := fakeHarnessWithSkill(t)
	dir := filepath.Join(harness, "domains", "testdomain", "rules")
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "required.md"), []byte("rule"), 0644); err != nil {
		t.Fatal(err)
	}
	hooks := filepath.Join(harness, "domains", "testdomain", "hooks")
	if err := os.MkdirAll(hooks, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(hooks, "test_gate.py"), []byte("print('ok')\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(hooks, "hooks.json"), []byte(`{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"__TEST_GATE_COMMAND__"}]}]}}`), 0644); err != nil {
		t.Fatal(err)
	}
	project := t.TempDir()
	if err := Run([]string{"install", "skill", "myskill", "--target=codex", "--project", project, "--harness-root", harness}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(project, ".agents", "rules", "required.md")); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Lstat(filepath.Join(project, ".codex", "hooks", "test_gate.py")); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("single-skill install did not link hook: %v", err)
	}
}

func TestCodexHooksKeepForeignConfig(t *testing.T) {
	harness, _ := fakeHarnessWithSkill(t)
	hooks := filepath.Join(harness, "domains", "testdomain", "hooks")
	if err := os.MkdirAll(hooks, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(hooks, "hooks.json"), []byte(`{"hooks":{}}`), 0644); err != nil {
		t.Fatal(err)
	}
	project := t.TempDir()
	configDir := filepath.Join(project, ".codex")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(configDir, "hooks.json")
	if err := os.WriteFile(config, []byte(`{"hooks":{"Stop":[]}}`), 0644); err != nil {
		t.Fatal(err)
	}
	if err := Run([]string{"install", "domain", "testdomain", "--project", project, "--harness-root", harness}); err == nil {
		t.Fatal("replaced foreign hook config without --force")
	}
	data, err := os.ReadFile(config)
	if err != nil || string(data) != `{"hooks":{"Stop":[]}}` {
		t.Fatalf("foreign hook config changed: %q, %v", data, err)
	}
}

func TestInvalidTarget(t *testing.T) {
	for _, command := range []string{"install", "uninstall", "status", "doctor"} {
		args := []string{command}
		if command == "install" || command == "uninstall" {
			args = append(args, "all")
		}
		if err := Run(append(args, "--target=unknown")); err == nil {
			t.Fatalf("%s accepted invalid target", command)
		}
	}
}

func TestCodexRepositoryExport(t *testing.T) {
	harness, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	project := filepath.Join(t.TempDir(), "project with spaces")
	if err := os.MkdirAll(project, 0755); err != nil {
		t.Fatal(err)
	}
	if err := Run([]string{"install", "all", "--target=codex", "--harness-root", harness, "--project", project}); err != nil {
		t.Fatal(err)
	}
	lock, err := lockfile.Load(project, "codex")
	if err != nil {
		t.Fatal(err)
	}
	skills := 0
	for _, entry := range lock.Entries {
		if entry.Kind != "skills" {
			continue
		}
		skills++
		path := filepath.Join(entry.Path, "SKILL.md")
		name, hasName, hasDescription, err := registry.ParseSkillFrontmatter(path)
		if err != nil || !hasName || !hasDescription || name != entry.Name {
			t.Fatalf("invalid exported metadata %s: %v", path, err)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, bad := range []string{".claude/rules/", ".claude/agents/", ".claude/skills/", "@AGENTS.md"} {
			if strings.Contains(string(data), bad) {
				t.Errorf("%s contains %s", path, bad)
			}
		}
	}
	if skills == 0 {
		t.Fatal("no skills exported")
	}
	hookPath := filepath.Join(project, ".codex", "hooks", "test_gate.py")
	info, err := os.Lstat(hookPath)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("test gate is not a symlink: %v", err)
	}
	configPath := filepath.Join(project, ".codex", "hooks.json")
	configData, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var hookConfig struct {
		Hooks map[string][]struct {
			Hooks []struct {
				Command string `json:"command"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(configData, &hookConfig); err != nil {
		t.Fatal(err)
	}
	for _, event := range []string{"UserPromptSubmit", "SubagentStart", "PreToolUse", "PostToolUse", "Stop", "SubagentStop"} {
		groups := hookConfig.Hooks[event]
		if len(groups) != 1 || len(groups[0].Hooks) != 1 || !strings.Contains(groups[0].Hooks[0].Command, hookPath) {
			t.Fatalf("%s does not invoke test gate: %+v", event, groups)
		}
	}
	if _, err := exec.LookPath("python3"); err == nil {
		payload := func(event string, extra string) string {
			return `{"cwd":` + string(mustJSON(t, project)) + `,"session_id":"install-test","turn_id":"install-turn","hook_event_name":"` + event + `"` + extra + `}`
		}
		runHook := func(event string, extra string) []byte {
			cmd := exec.Command("sh", "-c", hookConfig.Hooks[event][0].Hooks[0].Command)
			cmd.Stdin = strings.NewReader(payload(event, extra))
			output, err := cmd.Output()
			if err != nil {
				t.Fatal(err)
			}
			return output
		}
		runHook("UserPromptSubmit", "")
		if err := os.WriteFile(filepath.Join(project, "test_example.py"), []byte("def test_example(): assert True\n"), 0644); err != nil {
			t.Fatal(err)
		}
		runHook("PostToolUse", `,"tool_name":"apply_patch"`)
		if output := runHook("Stop", ""); !strings.Contains(string(output), `"block"`) {
			t.Fatalf("missing test run must block stop: %s", output)
		}
		runHook("PostToolUse", `,"tool_name":"Bash","tool_input":{"command":"pytest"},"tool_response":{"exit_code":0}`)
		if output := runHook("Stop", ""); len(output) != 0 {
			t.Fatalf("successful test run must allow stop: %s", output)
		}
	}
	if err := Run([]string{"doctor", "--target=codex", "--harness-root", harness, "--project", project}); err != nil {
		t.Fatal(err)
	}
	if err := Run([]string{"uninstall", "all", "--target=codex", "--harness-root", harness, "--project", project}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(hookPath); !os.IsNotExist(err) {
		t.Fatalf("uninstall left test gate: %v", err)
	}
	if _, err := os.Lstat(configPath); !os.IsNotExist(err) {
		t.Fatalf("uninstall left hook config: %v", err)
	}
	lock, err = lockfile.Load(project, "codex")
	if err != nil || len(lock.Entries) != 0 {
		t.Fatalf("uninstall left entries: %v, %v", lock, err)
	}
}

func mustJSON(t *testing.T, value string) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
