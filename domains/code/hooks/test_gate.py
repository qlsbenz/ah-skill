#!/usr/bin/env python3
"""Track changed test files and successful test runs for each Codex turn."""

import hashlib
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile

IGNORED = {".git", ".codex", ".agents", "node_modules", ".venv", "venv", "vendor", "target", "dist", "build", "__pycache__"}
SUFFIXES = ("_test.go", "_test.py", ".test.js", ".test.jsx", ".test.ts", ".test.tsx", ".spec.js", ".spec.jsx", ".spec.ts", ".spec.tsx", "Test.java", "Tests.java", ".test.cs")
TEST_EXTENSIONS = {".py", ".go", ".js", ".jsx", ".ts", ".tsx", ".java", ".cs", ".gd", ".sh", ".rb", ".php"}


def block(reason):
    print(json.dumps({"decision": "block", "reason": reason}))


def project_root(cwd):
    for directory in (cwd, *cwd.parents):
        if (directory / ".codex" / "hooks.json").exists():
            return directory
    return cwd


def test_file(path):
    return (path.name.startswith("test_") and path.suffix in TEST_EXTENSIONS) or path.name.endswith(SUFFIXES) or ("tests" in path.parts and path.suffix in TEST_EXTENSIONS)


def snapshot(root):
    files = {}
    for directory, dirs, names in os.walk(root):
        dirs[:] = [name for name in dirs if name not in IGNORED]
        for name in names:
            path = Path(directory) / name
            relative = path.relative_to(root)
            if test_file(relative):
                try:
                    files[str(relative)] = hashlib.sha256(path.read_bytes()).hexdigest()
                except OSError:
                    pass
    return files


def state_path(root, event):
    session, turn = event.get("session_id"), event.get("turn_id")
    if not isinstance(session, str) or not session or not isinstance(turn, str) or not turn:
        raise ValueError("missing session_id or turn_id")
    key = hashlib.sha256((str(root) + "\0" + session + "\0" + turn).encode()).hexdigest()
    directory = Path(tempfile.gettempdir()) / "ah-skills-test-gate"
    directory.mkdir(mode=0o700, exist_ok=True)
    return directory / (key + ".json")


def load(path, current):
    if not path.exists():
        return {"files": current, "changed": [], "verified": False}
    state = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(state, dict) or not isinstance(state.get("files"), dict):
        raise ValueError("invalid test gate state")
    return state


def save(path, state):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent,
            prefix=path.stem + ".", suffix=".tmp", delete=False,
        ) as handle:
            temporary = Path(handle.name)
            json.dump(state, handle, sort_keys=True)
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def refresh(state, current):
    previous = state["files"]
    changed = {name for name in previous.keys() | current.keys() if previous.get(name) != current.get(name)}
    if changed:
        state["changed"] = sorted(set(state["changed"]) | changed)
        state["verified"] = False
    state["files"] = current
    return changed


def success(response):
    if isinstance(response, dict):
        for key in ("exit_code", "exitCode"):
            if type(response.get(key)) is int:
                return response[key] == 0
        for value in response.values():
            result = success(value)
            if result is not None:
                return result
    elif isinstance(response, list):
        for value in response:
            result = success(value)
            if result is not None:
                return result
    elif isinstance(response, str):
        match = re.search(r"(?:Process exited with code|exit[_ ]code\s*[:=])\s*(\d+)", response, re.I)
        if match:
            return int(match.group(1)) == 0
    return None


def full_test_run(command, root):
    if not isinstance(command, str) or any(operator in command for operator in ("|", ";", "&&", "||", "`", "$(")):
        return False
    try:
        parts = shlex.split(command)
    except ValueError:
        return False
    while parts and (parts[0] == "env" or re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*=.*", parts[0])):
        parts.pop(0)
    if not parts:
        return False
    config = root / ".codex" / "test_gate.json"
    if config.exists():
        settings = json.loads(config.read_text(encoding="utf-8"))
        expected = settings.get("command") if isinstance(settings, dict) else None
        if not isinstance(expected, list) or not expected or not all(isinstance(item, str) and item for item in expected):
            raise ValueError("test_gate.json command must be a nonempty string array")
        if parts == expected:
            return True
    executable, args = Path(parts[0]).name, parts[1:]
    if executable == "go":
        return args == ["test", "./..."]
    if executable in {"pytest", "py.test"} or (executable.startswith("python") and args[:2] == ["-m", "pytest"]):
        options = args if executable in {"pytest", "py.test"} else args[2:]
        return not options
    if executable in {"npm", "pnpm", "yarn", "bun"}:
        return args in (["test"], ["run", "test"])
    if executable == "cargo":
        return args == ["test"]
    if executable in {"mvn", "mvnw", "gradle", "gradlew", "dotnet"}:
        return args == ["test"]
    return False


def main():
    try:
        event = json.load(sys.stdin)
        root = project_root(Path(event.get("cwd") or os.getcwd()).resolve())
        path = state_path(root, event)
        with path.with_suffix(".lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            current = snapshot(root)
            state = load(path, current)
            kind = event.get("hook_event_name")
            if kind in {"UserPromptSubmit", "SubagentStart", "PreToolUse"}:
                refresh(state, current)
                save(path, state)
            elif kind == "PostToolUse":
                changed = refresh(state, current)
                tool_input = event.get("tool_input")
                if not isinstance(tool_input, dict):
                    tool_input = {}
                if not changed and state["changed"] and event.get("tool_name") == "Bash":
                    if full_test_run(tool_input.get("command"), root) and success(event.get("tool_response")) is True:
                        state["verified"] = True
                save(path, state)
            elif kind in {"Stop", "SubagentStop"}:
                refresh(state, current)
                if state["changed"] and not state["verified"]:
                    block("Changed tests lack a successful full test run after the last edit: " + ", ".join(state["changed"][:12]))
                else:
                    path.unlink(missing_ok=True)
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as exc:
        block(f"Test gate could not verify test execution: {exc}")


if __name__ == "__main__":
    main()
