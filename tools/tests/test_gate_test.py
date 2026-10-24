from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid


HOOK = Path(__file__).resolve().parents[2] / "domains" / "code" / "hooks" / "test_gate.py"


class TestGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / ".codex").mkdir()
        (self.root / ".codex" / "hooks.json").write_text("{}")
        self.event = {"cwd": str(self.root), "session_id": str(uuid.uuid4()), "turn_id": str(uuid.uuid4())}

    def hook(self, kind, **extra):
        payload = {**self.event, "hook_event_name": kind, **extra}
        result = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(payload), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout) if result.stdout else None

    def test_no_test_edits_allow_stop(self):
        self.hook("UserPromptSubmit")
        self.assertIsNone(self.hook("Stop"))

    def test_parallel_hooks_share_state_safely(self):
        with ThreadPoolExecutor(max_workers=32) as executor:
            results = list(executor.map(lambda _: self.hook("PreToolUse"), range(96)))
        self.assertEqual(results, [None] * 96)
        self.assertIsNone(self.hook("Stop"))

    def test_changed_test_requires_successful_run_after_edit(self):
        test = self.root / "test_example.py"
        self.hook("UserPromptSubmit")
        test.write_text("def test_one(): assert True\n")
        self.hook("PostToolUse", tool_name="apply_patch")
        self.assertEqual(self.hook("Stop")["decision"], "block")
        self.hook("PostToolUse", tool_name="Bash", tool_input={"command": "pytest"}, tool_response={"exit_code": 1})
        self.assertEqual(self.hook("Stop")["decision"], "block")
        self.hook("PostToolUse", tool_name="Bash", tool_input={"command": "pytest test_example.py"}, tool_response={"exit_code": 0})
        self.assertEqual(self.hook("Stop")["decision"], "block")
        self.hook("PostToolUse", tool_name="Bash", tool_input={"command": "pytest"}, tool_response={"exit_code": 0})
        self.assertIsNone(self.hook("Stop"))

    def test_edit_after_success_requires_new_run_for_subagent(self):
        test = self.root / "example_test.go"
        self.hook("SubagentStart")
        test.write_text("package example\n")
        self.hook("PostToolUse", tool_name="apply_patch")
        self.hook("PostToolUse", tool_name="Bash", tool_input={"command": "go test ./..."}, tool_response={"exit_code": 0})
        test.write_text("package example\n// changed\n")
        self.hook("PostToolUse", tool_name="apply_patch")
        self.assertEqual(self.hook("SubagentStop")["decision"], "block")

    def test_unconfirmed_result_does_not_count(self):
        self.hook("UserPromptSubmit")
        (self.root / "test_example.py").write_text("pass\n")
        self.hook("PostToolUse", tool_name="apply_patch")
        self.hook("PostToolUse", tool_name="Bash", tool_input={"command": "pytest"}, tool_response={"output": "all good"})
        self.assertEqual(self.hook("Stop")["decision"], "block")

    def test_configured_command_is_observed_but_not_run_by_stop(self):
        (self.root / ".codex" / "test_gate.json").write_text('{"command":["make","check"]}')
        self.hook("UserPromptSubmit")
        (self.root / "test_example.py").write_text("pass\n")
        self.hook("PostToolUse", tool_name="apply_patch")
        self.hook("PostToolUse", tool_name="Bash", tool_input={"command": "make check"}, tool_response={"exit_code": 0})
        self.assertIsNone(self.hook("Stop"))

    def test_filtered_run_does_not_count(self):
        self.hook("UserPromptSubmit")
        (self.root / "test_example.py").write_text("pass\n")
        self.hook("PostToolUse", tool_name="apply_patch")
        self.hook("PostToolUse", tool_name="Bash", tool_input={"command": "go test ./... -run TestOne"}, tool_response={"exit_code": 0})
        self.assertEqual(self.hook("Stop")["decision"], "block")


if __name__ == "__main__":
    unittest.main()
