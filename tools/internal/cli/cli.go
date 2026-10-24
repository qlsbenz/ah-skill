package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
)

func Run(args []string) error {
	if len(args) == 0 {
		printUsage(os.Stderr)
		return errors.New("no command given")
	}
	switch args[0] {
	case "install":
		return runInstall(args[1:])
	case "uninstall":
		return runUninstall(args[1:])
	case "list":
		return runList(args[1:])
	case "status":
		return runStatus(args[1:])
	case "doctor":
		return runDoctor(args[1:])
	case "check":
		return runCheck(args[1:])
	case "help", "-h", "--help":
		printUsage(os.Stdout)
		return nil
	default:
		printUsage(os.Stderr)
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func printUsage(w io.Writer) {
	fmt.Fprint(w, `ah-skills — install project-local Codex skills

Usage:
  ah-skills install domain <name> [--project PATH]
  ah-skills install domains <name> [name...] [--project PATH]
  ah-skills install all [--project PATH]
  ah-skills install skill <name> [--project PATH]
  ah-skills uninstall domain|domains|all|skill ... [--project PATH]
  ah-skills list [domains|skills]
  ah-skills status [--project PATH]
  ah-skills doctor [--project PATH]
  ah-skills check

Flags:
  --project PATH       target project (default: current directory)
  --harness-root PATH  this harness checkout (auto-detected from cwd)
  --dry-run            show install or uninstall plan without writing
  --force              replace foreign or modified destination on install
  --copy               accepted for compatibility; Codex skills use snapshots
  --target codex       optional; Codex is default

Codex skills install under <project>/.agents/skills/. Invoke as $code-plan,
$code-build, $git-flow, or /skills in the Codex interface. The code domain
also installs .codex/hooks.json and a linked .codex/hooks/test_gate.py.
After test-file edits in a turn, the gate requires a confirmed successful full
test command through Bash after the last edit; it never runs tests itself.
Review project and hook trust with /hooks in Codex; this CLI cannot inspect trust.
`)
}
