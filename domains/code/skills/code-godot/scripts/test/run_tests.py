#!/usr/bin/env python3
"""Run a Godot project's unit tests headlessly and report structured JSON.

Godot ships no built-in unit-test framework for project code. This wrapper
covers three runners and normalizes their CLI and exit codes into one result:

- mini    (bundled):        no download, no addon — copy one base class in with
                            ``--init-mini`` and write ``extends
                            "res://tests/test_case.gd"``.
- GUT     (addons/gut):     exit 0 = pass, 1 = failures
- GdUnit4 (addons/gdUnit4): exit 0 = pass, 100 = failures, 101 = warnings

The mini runner needs the extra care: a GDScript runtime error does not raise.
It aborts the running function and returns to the caller, so a test that
dereferences null reports as a pass to any runner that only looks at the return
value. ``mini_test_runner.gd`` therefore brackets every test with
``[MINI_TEST] begin|end`` markers, and this wrapper attributes the engine's
``SCRIPT ERROR:`` lines between those markers to the test that produced them
(through ``godot_log_parser.py``) and downgrades the result to ``error``.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "debug"))
try:  # godot_log_parser is the shared log reader; degrade if it ever moves.
    from godot_log_parser import parse_log as _parse_log
except ImportError:  # pragma: no cover - only when the file is missing
    _parse_log = None


DEFAULT_TEST_DIRS = ["test", "tests"]
SKILL_ROOT = Path(__file__).resolve().parents[2]
MINI_RUNNER = SKILL_ROOT / "scripts/test/mini_test_runner.gd"
MINI_TEMPLATES = SKILL_ROOT / "templates/tests"
MINI_BASE_NAME = "test_case.gd"
MINI_EXAMPLE_NAME = "test_example.gd"
# Marker lines mini_test_runner.gd prints around every script and test.
MARKER = "[MINI_TEST]"
RESULT_MARKER = "[MINI_TEST_RESULT]"
ERROR_SEVERITIES = {"error", "script_error", "parse_error", "shader_error"}
BAD_STATUSES = {"failed", "error", "timeout"}
STATUS_BUCKET = {
    "passed": "passed",
    "failed": "failed",
    "error": "errors",
    "skipped": "skipped",
    "pending": "pending",
    "risky": "risky",
    "timeout": "timed_out",
}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run mini/GUT/GdUnit4 tests headlessly and report structured JSON.")
    parser.add_argument("project_path")
    parser.add_argument("--framework", choices=["auto", "mini", "gut", "gdunit4"], default="auto")
    parser.add_argument("--tests-dir", default="", help="Project-relative tests directory (default: test/ or tests/)")
    parser.add_argument("--godot-bin", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--junit-xml", default="", help="Also write a JUnit XML report to this absolute path (GUT only)")
    parser.add_argument("--timeout", type=float, default=600.0, help="Wall-clock budget for the whole run (seconds)")
    parser.add_argument(
        "--allow-empty",
        action="store_true",
        help="Do not fail when the tests directory contains no test scripts",
    )
    parser.add_argument("--dry-run", action="store_true", help="Report detection and the exact command without running")
    parser.add_argument("--pretty", action="store_true")
    parser.add_argument(
        "--init-mini",
        action="store_true",
        help="Copy the bundled test-case base class and one example test into the project, then exit. Refuses to overwrite.",
    )
    parser.add_argument("--select", default="", help="mini only: run tests whose name or script path contains this text")
    parser.add_argument("--test-timeout", type=float, default=10.0, help="mini only: seconds one test may run (default: 10)")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="mini only: a test that makes no assertion (`risky`) fails the run",
    )
    parser.add_argument("--log-file", default="", help="mini only: write the raw merged Godot log to this path")
    return parser.parse_args(argv)


# --- detection -------------------------------------------------------------

def detect_framework(project_path: Path, tests_dir: str) -> str:
    if (project_path / "addons/gut/gut_cmdln.gd").is_file():
        return "gut"
    if (project_path / "addons/gdUnit4/bin/GdUnitCmdTool.gd").is_file():
        return "gdunit4"
    if detect_mini(project_path, tests_dir):
        return "mini"
    return "none"


def detect_mini(project_path: Path, tests_dir: str) -> bool:
    """True when the project holds the mini base class or a script extending it."""
    candidates = [tests_dir] if tests_dir else DEFAULT_TEST_DIRS
    extends_base = re.compile(r'extends\s+"res://[^"]*test_case\.gd"')
    for candidate in candidates:
        root = project_path / candidate
        if not root.is_dir():
            continue
        if (root / MINI_BASE_NAME).is_file():
            return True
        for path in sorted(root.rglob("*.gd")):
            text = read_text(path)
            if extends_base.search(text) or "func _mini_report(" in text:
                return True
    return False


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def resolve_tests_dir(project_path: Path, requested: str) -> str:
    if requested:
        return requested.removeprefix("res://").strip("/")
    for candidate in DEFAULT_TEST_DIRS:
        if (project_path / candidate).is_dir():
            return candidate
    return ""


def count_test_scripts(project_path: Path, tests_dir: str, framework: str) -> int:
    """Number of test scripts under the tests directory.

    Every runner exits 0 when it finds nothing to run, so a wrong --tests-dir
    (or a directory that was never populated) otherwise reports as a clean pass.
    For mini, the base class is not a test — a directory holding only
    test_case.gd is still empty.
    """
    root = project_path / tests_dir
    if not root.is_dir():
        return 0
    if framework == "mini":
        return sum(
            1
            for path in sorted(root.rglob("test_*.gd"))
            if path.is_file() and "func _mini_report(" not in read_text(path)
        )
    return sum(1 for path in root.rglob("*") if path.suffix in {".gd", ".cs"} and path.is_file())


# --- command construction --------------------------------------------------

def build_command(framework: str, args: argparse.Namespace, project_path: Path, tests_dir: str) -> list[str]:
    command = [args.godot_bin, "--headless"]
    if framework == "mini":
        # -d routes GDScript warnings and get_stack() through the debugger;
        # --ignore-error-breaks keeps the first runtime error from stopping the
        # run at the interactive debug> prompt. Same pair as run_project.py.
        command.extend(["--debug", "--ignore-error-breaks", "--path", str(project_path)])
        config = {
            "tests_dir": tests_dir,
            "select": args.select,
            "test_timeout_seconds": args.test_timeout,
            "strict": args.strict,
        }
        command.extend(["--script", str(MINI_RUNNER), json.dumps(config, separators=(",", ":"))])
        return command
    command.extend(["--path", str(project_path)])
    if framework == "gut":
        command.extend(["-s", "res://addons/gut/gut_cmdln.gd", f"-gdir=res://{tests_dir}", "-ginclude_subdirs", "-gexit"])
        if args.junit_xml:
            command.append(f"-gjunit_xml_file={args.junit_xml}")
    else:
        command.extend(["-s", "res://addons/gdUnit4/bin/GdUnitCmdTool.gd", "--add", f"res://{tests_dir}", "--continue"])
    return command


def interpret(framework: str, returncode: int) -> tuple[bool, str]:
    if framework == "gut":
        return returncode == 0, {0: "passed"}.get(returncode, "failed")
    statuses = {0: "passed", 100: "failed", 101: "passed_with_warnings"}
    return returncode in (0, 101), statuses.get(returncode, f"runner_error_{returncode}")


# --- mini: --init-mini -----------------------------------------------------

def init_mini(project_path: Path, args: argparse.Namespace) -> int:
    tests_dir = (args.tests_dir or "tests").removeprefix("res://").strip("/")
    target = project_path / tests_dir
    base_source = MINI_TEMPLATES / MINI_BASE_NAME
    example_source = MINI_TEMPLATES / MINI_EXAMPLE_NAME
    missing = [str(p) for p in (base_source, example_source) if not p.is_file()]
    if missing:
        return emit({
            "ok": False,
            "framework": "mini",
            "errors": [f"Bundled template missing: {', '.join(missing)}"],
        }, args.pretty, 1)

    existing = [
        f"res://{tests_dir}/{name}"
        for name in (MINI_BASE_NAME, MINI_EXAMPLE_NAME)
        if (target / name).is_file()
    ]
    if existing:
        return emit({
            "ok": False,
            "framework": "mini",
            "tests_dir": f"res://{tests_dir}",
            "errors": [
                "Refusing to overwrite an existing test setup: " + ", ".join(existing)
                + ". Delete those files first, or pass --tests-dir <other-dir> to install alongside them."
            ],
        }, args.pretty, 1)

    target.mkdir(parents=True, exist_ok=True)
    written = []
    for name in (MINI_BASE_NAME, MINI_EXAMPLE_NAME):
        text = read_text(MINI_TEMPLATES / name)
        # The example path-extends the base; keep that pointing at the chosen dir.
        text = text.replace('extends "res://tests/test_case.gd"', f'extends "res://{tests_dir}/test_case.gd"')
        text = text.replace("res://tests/test_case.gd", f"res://{tests_dir}/test_case.gd")
        (target / name).write_text(text, encoding="utf-8")
        written.append(f"res://{tests_dir}/{name}")
    return emit({
        "ok": True,
        "framework": "mini",
        "tests_dir": f"res://{tests_dir}",
        "created": written,
        "next": [
            f"python3 {Path(__file__).resolve()} {project_path} --pretty",
            f"Write suites as: extends \"res://{tests_dir}/test_case.gd\" with func test_*() methods.",
        ],
    }, args.pretty, 0)


# --- mini: log attribution -------------------------------------------------

def split_segments(log_text: str) -> list[tuple[tuple, list[str]]]:
    """Split the merged log on the runner's markers.

    Returns (context, lines) pairs. Context is ("test", script, test),
    ("script", script) or ("global",). Marker lines themselves are dropped, so
    a multi-line diagnostic can never be cut in half by one.
    """
    segments: list[tuple[tuple, list[str]]] = []
    context: tuple = ("global",)
    buffer: list[str] = []

    def flush() -> None:
        if buffer:
            segments.append((context, list(buffer)))
            buffer.clear()

    for line in log_text.splitlines():
        stripped = line.strip()
        if stripped.startswith(MARKER + " "):
            rest = stripped[len(MARKER) + 1:]
            flush()
            if rest.startswith("begin "):
                target = rest[len("begin "):].strip()
                script, _, test = target.partition("::")
                context = ("test", script, test)
            elif rest.startswith("end "):
                target = rest[len("end "):].split(" ", 1)[0]
                script, _, _test = target.partition("::")
                context = ("script", script)
            elif rest.startswith("script_end "):
                context = ("global",)
            elif rest.startswith("script "):
                context = ("script", rest[len("script "):].strip())
            continue
        if stripped.startswith(RESULT_MARKER):
            flush()
            context = ("global",)
            continue
        buffer.append(line)
    flush()
    return segments


def errors_in(lines: list[str]) -> list[dict]:
    text = "\n".join(lines)
    if _parse_log is not None:
        report = _parse_log(text, include_warnings=False)
        return [d for d in report["diagnostics"] if d["severity"] in ERROR_SEVERITIES]
    # Fallback: the parser is the shared component, but never let its absence
    # turn a runtime error back into a silent pass.
    found = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(("SCRIPT ERROR:", "ERROR:", "USER SCRIPT ERROR:", "USER ERROR:")):
            found.append({"severity": "script_error", "message": stripped.split(":", 1)[1].strip(),
                          "file": None, "line": None, "category": "unknown"})
    return found


def attribute_errors(log_text: str) -> tuple[dict, dict, list[dict]]:
    """(per-test errors, per-script errors, global errors) keyed by context."""
    per_test: dict[tuple[str, str], list[dict]] = {}
    per_script: dict[str, list[dict]] = {}
    global_errors: list[dict] = []
    for context, lines in split_segments(log_text):
        found = errors_in(lines)
        if not found:
            continue
        if context[0] == "test":
            per_test.setdefault((context[1], context[2]), []).extend(found)
        elif context[0] == "script":
            per_script.setdefault(context[1], []).extend(found)
        else:
            global_errors.extend(found)
    return per_test, per_script, global_errors


def describe(diagnostic: dict) -> str:
    location = ""
    if diagnostic.get("file"):
        location = f" at {diagnostic['file']}"
        if diagnostic.get("line"):
            location += f":{diagnostic['line']}"
    return f"{diagnostic['message']}{location}"


def apply_error_attribution(payload: dict, log_text: str) -> None:
    """Turn 'the test function died halfway' into an `error` result.

    Nothing in the engine raises for a GDScript runtime error, so this is the
    only place the difference between "ran to the end" and "aborted on line 12"
    can be recovered.
    """
    per_test, per_script, global_errors = attribute_errors(log_text)
    results = payload.get("results", [])
    for entry in results:
        key = (entry.get("script", ""), entry.get("test", ""))
        found = per_test.get(key)
        if not found or entry.get("allow_errors"):
            continue
        first = found[0]
        detail = describe(first)
        if len(found) > 1:
            detail += f" (+{len(found) - 1} more engine error(s))"
        if entry["status"] == "failed":
            detail += f" | assertion failure also recorded: {entry['message']}"
        entry["status"] = "error"
        entry["message"] = detail
        entry["engine_errors"] = [describe(d) for d in found]
        if first.get("file"):
            entry["source"] = first["file"]
        if first.get("line"):
            entry["line"] = first["line"]

    known_scripts = {entry.get("script") for entry in results}
    for script, found in sorted(per_script.items()):
        existing = next((e for e in results if e.get("script") == script and e.get("test") == "<script>"), None)
        detail = "; ".join(describe(d) for d in found)
        if existing is not None:
            existing["message"] = f"{existing['message']}: {detail}"
            existing["engine_errors"] = [describe(d) for d in found]
            continue
        results.append({
            "script": script,
            "test": "<script>",
            "status": "error",
            "asserts": 0,
            "message": f"engine error outside any test (setup, teardown or an abandoned coroutine): {detail}",
            "source": found[0].get("file") or script,
            "line": found[0].get("line") or 0,
            "duration_ms": 0,
            "allow_errors": False,
            "kind": "script",
            "failures": [],
            "engine_errors": [describe(d) for d in found],
        })
        known_scripts.add(script)
    payload["results"] = results
    if global_errors:
        payload["engine_errors"] = [describe(d) for d in global_errors]


def summarize(payload: dict, strict: bool) -> None:
    """Recompute counts/failures from results[] — the same rules the runner uses.

    Every `test_*` method lands in exactly one status bucket. A hook
    (before_all/after_all) or a script that failed to load is only counted when
    it went wrong, in `non_test_failures` plus its status bucket.
    """
    counts = {
        "scripts": len(payload.get("scripts", [])) or len({e.get("script") for e in payload.get("results", [])}),
        "tests": 0, "passed": 0, "failed": 0, "errors": 0, "skipped": 0,
        "pending": 0, "risky": 0, "timed_out": 0, "non_test_failures": 0,
    }
    failures = []
    for entry in payload.get("results", []):
        status = entry.get("status", "passed")
        is_test = entry.get("kind", "test") == "test"
        if not is_test and status not in BAD_STATUSES:
            continue
        if is_test:
            counts["tests"] += 1
        else:
            counts["non_test_failures"] += 1
        counts[STATUS_BUCKET.get(status, "errors")] += 1
        if status in BAD_STATUSES:
            failures.append({
                "script": entry.get("script", ""),
                "test": entry.get("test", ""),
                "line": entry.get("line", 0),
                "message": entry.get("message", ""),
                "status": status,
                "source": entry.get("source", entry.get("script", "")),
            })
    payload["counts"] = counts
    payload["failures"] = failures
    payload["ok"] = not failures and not payload.get("errors") and not (strict and counts["risky"] > 0)


def extract_payload(stdout: str) -> dict | None:
    for line in reversed(stdout.splitlines()):
        stripped = line.strip()
        if stripped.startswith(RESULT_MARKER):
            try:
                return json.loads(stripped[len(RESULT_MARKER):].strip())
            except json.JSONDecodeError:
                return None
    return None


def run_mini(args: argparse.Namespace, project_path: Path, tests_dir: str, command: list[str], base: dict) -> int:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            # One stream: the markers (stdout) and the engine's SCRIPT ERROR
            # lines (stderr) must stay in order for attribution to work.
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            timeout=args.timeout,
            stdin=subprocess.DEVNULL,
        )
        log_text = completed.stdout or ""
        returncode = completed.returncode
    except subprocess.TimeoutExpired as exc:
        raw = exc.stdout or ""
        log_text = raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else raw
        base.update({
            "ok": False,
            "timed_out": True,
            "duration_s": round(time.monotonic() - started, 3),
            "errors": [
                f"Test run exceeded the global --timeout of {args.timeout}s and was killed. "
                "A single hung test is caught by --test-timeout; this usually means the project "
                "itself hangs at startup, or the suite is genuinely longer than the budget."
            ],
            "output_tail": tail(log_text),
        })
        if args.log_file:
            Path(args.log_file).expanduser().write_text(log_text, encoding="utf-8")
        return emit(base, args.pretty, 1)

    if args.log_file:
        Path(args.log_file).expanduser().write_text(log_text, encoding="utf-8")

    payload = extract_payload(log_text)
    if payload is None:
        base.update({
            "ok": False,
            "returncode": returncode,
            "duration_s": round(time.monotonic() - started, 3),
            "errors": [
                "The mini runner printed no result payload. The project or the runner failed to "
                "start — read output_tail, and check that res://" + tests_dir + " exists."
            ],
            "output_tail": tail(log_text),
        })
        return emit(base, args.pretty, 1)

    payload.update(base)
    apply_error_attribution(payload, log_text)
    summarize(payload, args.strict)
    reject_empty_run(payload, args)
    add_hints(payload, project_path)
    payload["returncode"] = returncode
    payload["duration_s"] = round(time.monotonic() - started, 3)
    payload["status"] = "passed" if payload["ok"] else "failed"
    if not payload["ok"]:
        payload["output_tail"] = tail(log_text)
    return emit(payload, args.pretty, 0 if payload["ok"] else 1)


UNDECLARED = re.compile(r'Identifier "(\w+)" not declared in the current scope')


def add_hints(payload: dict, project_path: Path) -> None:
    """Name the one non-obvious prerequisite: the global class cache.

    A project's own `class_name` is invisible to every script until
    `godot --import` has written .godot/global_script_class_cache.cfg, and a
    `--script` run never rebuilds it. The test then fails to load with a bare
    "Identifier X not declared", which reads like a typo.
    """
    names = {
        match
        for failure in payload.get("failures", [])
        for match in UNDECLARED.findall(str(failure.get("message", "")))
    }
    if not names:
        return
    declared = set()
    for path in project_path.rglob("*.gd"):
        if ".godot" in path.parts:
            continue
        for match in re.finditer(r"^class_name\s+(\w+)", read_text(path), re.M):
            declared.add(match.group(1))
    hit = sorted(names & declared)
    if not hit:
        return
    payload.setdefault("hints", []).append(
        f"{', '.join(hit)} is declared with `class_name` in this project but is not in the global "
        "class cache, so no script can see it. Build the cache once, then re-run: "
        f"godot --headless --path {project_path} --import"
    )


def reject_empty_run(payload: dict, args: argparse.Namespace) -> None:
    """Running zero tests is never a pass.

    A typo in --select, or a test_*.gd whose methods are not named test_*,
    would otherwise produce a green report over an empty run.
    """
    if payload["counts"]["tests"] > 0 or args.allow_empty:
        return
    discovered = payload.get("discovered_tests", [])
    if args.select:
        reason = (
            f"--select {args.select!r} matched no test. It is compared against both the test "
            f"name and the script path. {len(discovered)} test(s) exist"
        )
        if discovered:
            reason += ": " + ", ".join(discovered[:10]) + ("…" if len(discovered) > 10 else "")
    else:
        reason = (
            "No test ran. A suite must `extends \"res://<tests dir>/test_case.gd\"` and name its "
            "methods test_*; see notes[] for the files that were skipped and why"
        )
    payload["ok"] = False
    payload.setdefault("errors", []).append(reason + ". Pass --allow-empty if an empty run is expected.")


def tail(text: str, lines: int = 40) -> str:
    return "\n".join(text.strip().splitlines()[-lines:])


def emit(payload: dict, pretty: bool, code: int) -> int:
    print(json.dumps(payload, indent=2 if pretty else None))
    return code


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    project_path = Path(args.project_path).expanduser().resolve()
    if not (project_path / "project.godot").is_file():
        raise SystemExit(f"Missing Godot project file: {project_path / 'project.godot'}")

    if args.init_mini:
        return init_mini(project_path, args)

    requested_dir = args.tests_dir.removeprefix("res://").strip("/") if args.tests_dir else ""
    if requested_dir and not (project_path / requested_dir).is_dir():
        # Otherwise a typo'd --tests-dir falls through to "no framework
        # detected" and sends the caller off installing one they already have.
        existing = sorted(
            f"res://{path.relative_to(project_path).as_posix()}"
            for path in project_path.glob("*")
            if path.is_dir() and not path.name.startswith(".") and any(path.rglob("test_*.gd"))
        )
        return emit({
            "ok": False,
            "framework": "none",
            "errors": [
                f"--tests-dir res://{requested_dir} does not exist in {project_path}."
                + (f" Directories that do hold test_*.gd: {', '.join(existing)}." if existing
                   else " No directory in the project holds a test_*.gd file.")
            ],
        }, args.pretty, 1)

    framework = args.framework if args.framework != "auto" else detect_framework(project_path, requested_dir)
    if framework == "none":
        return emit({
            "ok": False,
            "framework": "none",
            "errors": [
                "No test framework detected. Godot has no built-in project test runner. Run this "
                "command to install the bundled zero-install one (no addon, no download): "
                f"python3 {Path(__file__).resolve()} {project_path} --init-mini . "
                "GUT (addons/gut) and GdUnit4 (addons/gdUnit4) are also detected when present."
            ],
        }, args.pretty, 1)

    tests_dir = resolve_tests_dir(project_path, args.tests_dir)
    if not tests_dir:
        fix = (
            f" Create it with: python3 {Path(__file__).resolve()} {project_path} --init-mini"
            if framework == "mini" else ""
        )
        return emit({
            "ok": False,
            "framework": framework,
            "errors": ["No tests directory found; pass --tests-dir or create test/ or tests/." + fix],
        }, args.pretty, 1)

    test_script_count = count_test_scripts(project_path, tests_dir, framework)
    if test_script_count == 0 and not args.allow_empty:
        hint = (
            " For the mini framework the base class res://%s/%s does not count as a test — add a "
            "test_*.gd beside it." % (tests_dir, MINI_BASE_NAME)
            if framework == "mini" else ""
        )
        return emit({
            "ok": False,
            "framework": framework,
            "tests_dir": f"res://{tests_dir}",
            "test_script_count": 0,
            "errors": [
                f"No test scripts found under res://{tests_dir}. Every runner exits 0 when it "
                "collects nothing, so this would otherwise be reported as a passing run. Point "
                "--tests-dir at the real suite, or pass --allow-empty if an empty suite is expected."
                + hint
            ],
        }, args.pretty, 1)

    command = build_command(framework, args, project_path, tests_dir)
    payload: dict = {
        "framework": framework,
        "tests_dir": f"res://{tests_dir}",
        "test_script_count": test_script_count,
        "command": command,
    }

    if args.dry_run:
        payload["ok"] = True
        payload["dry_run"] = True
        return emit(payload, args.pretty, 0)

    if framework == "mini":
        return run_mini(args, project_path, tests_dir, command, payload)

    try:
        completed = subprocess.run(command, capture_output=True, text=True, check=False, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        payload.update({"ok": False, "timed_out": True, "errors": [f"Test run timed out after {args.timeout}s"]})
        return emit(payload, args.pretty, 1)

    ok, status = interpret(framework, completed.returncode)
    payload.update({
        "ok": ok,
        "status": status,
        "returncode": completed.returncode,
        "output_tail": tail(completed.stdout + "\n" + completed.stderr),
    })
    if framework == "gdunit4":
        reports = project_path / "reports"
        if reports.is_dir():
            payload["reports_dir"] = str(reports)
    if args.junit_xml and Path(args.junit_xml).is_file():
        payload["junit_xml"] = args.junit_xml
    return emit(payload, args.pretty, 0 if ok else 1)


if __name__ == "__main__":
    raise SystemExit(main())
