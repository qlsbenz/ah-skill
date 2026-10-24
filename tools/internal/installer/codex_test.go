package installer

import (
	"strings"
	"testing"
)

func TestCodexMarkdownPreservesPathsAndFrontmatter(t *testing.T) {
	source := "---\nname: code-plan\ndescription: Plan before /code-build\n---\nUse `/code-plan`. Read `.agents/agents/code-planner.md` and `domains/code/skills/code-plan/SKILL.md`."
	result := string(codexMarkdown([]byte(source), "code-plan"))
	for _, want := range []string{"---\nname: code-plan\ndescription: Plan before $code-build\n---\n", "`$code-plan`", ".agents/agents/code-planner.md", "domains/code/skills/code-plan/SKILL.md"} {
		if !strings.Contains(result, want) {
			t.Errorf("missing %q in %s", want, result)
		}
	}
}

func TestCodexInitDoesNotImportItself(t *testing.T) {
	source := "---\nname: code-init\ndescription: Generate AGENTS.md for Codex\n---\nWrite AGENTS.md."
	result := string(codexMarkdown([]byte(source), "code-init"))
	if strings.Contains(result, "@AGENTS.md") || !strings.Contains(result, "Write AGENTS.md") {
		t.Fatal(result)
	}
}
