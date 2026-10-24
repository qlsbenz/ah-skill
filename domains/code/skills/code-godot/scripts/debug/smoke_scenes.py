#!/usr/bin/env python3
"""Boot every scene of a Godot 4.7 project, one scene per process, and report.

``run_project.py`` boots the *main* scene for a bounded number of frames, so a
runtime error in the pause menu's ``_ready``, in level 3, or in the game-over
screen stays invisible until a player reaches it. ``check_project`` instantiates
every scene but never runs ``_ready``/``_process``. This tool closes that gap: it
runs **each** scene in its own Godot process for a bounded amount of *game* time,
optionally firing the project's real input actions at it, and reports per scene
what the debugger printed plus a handful of runtime findings (leaked nodes,
orphans, memory growth, hangs, crashes, scene changes, ``quit()``).

One process per scene is deliberate:

- a scene that crashes or hangs cannot take the other scenes down with it;
- autoload state starts clean for every scene, so scene N never inherits a
  singleton the previous scene left dirty;
- every log line, and therefore every diagnostic, belongs to exactly one scene.

Speed comes from ``--fixed-fps 60``: the engine decouples game time from wall
time, so ten game-seconds of physics, timers and tweens cost a few milliseconds
of wall time headless. ``--real-time`` opts out (see ``--profile``).

Examples::

    python3 smoke_scenes.py /abs/project --pretty
    python3 smoke_scenes.py /abs/project --seconds 3 --fuzz --fuzz-seed 7 --jobs 4
    python3 smoke_scenes.py /abs/project --scenes res://ui/pause_menu.tscn --profile
"""
from __future__ import annotations

import argparse
import concurrent.futures
import fnmatch
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from godot_log_parser import parse_log  # noqa: E402

RESULT_MARKER = "[SMOKE_RESULT] "

# Third-party plugin scenes are not the project's own and are usually editor
# tooling that cannot run at all outside the editor.
SKIP_DIRS = {"addons"}


# --------------------------------------------------------------------------- CLI


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="smoke_scenes.py",
        description=(
            "Boot every scene of a Godot project in its own process, run it for a bounded amount of "
            "game time, and report runtime errors, warnings and findings per scene. With neither --all "
            "nor --scenes the default is --all: every .tscn in the project except addons/, hidden "
            "directories and folders holding a .gdignore file."
        ),
        epilog=(
            "Exit codes: 0 every scene passed, 1 at least one scene failed, 2 usage error or the Godot "
            "binary could not be run."
        ),
    )
    parser.add_argument("project_path", help="Path to the Godot project directory (the one with project.godot).")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument(
        "--all",
        action="store_true",
        help="Smoke every scene in the project (the default when --scenes is not given).",
    )
    selection.add_argument(
        "--scenes",
        nargs="+",
        metavar="SCENE",
        default=None,
        help="Smoke exactly these scenes (res:// or project-relative). A path that does not exist is a usage error.",
    )
    parser.add_argument(
        "--include",
        action="append",
        default=[],
        metavar="GLOB",
        help="Keep only scenes whose res:// path matches this glob (repeatable, e.g. --include 'res://levels/*').",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        metavar="GLOB",
        help="Drop scenes whose res:// path matches this glob (repeatable, applied after --include).",
    )
    parser.add_argument(
        "--seconds",
        type=float,
        default=1.0,
        help="Game time to run each scene for (default: 1.0). With --fixed-fps this costs almost no wall time.",
    )
    parser.add_argument("--fuzz", action="store_true", help="Fire the project's real InputMap actions pseudo-randomly.")
    parser.add_argument("--fuzz-seed", type=int, default=0, help="Seed for --fuzz (default: 0). Same seed, same events.")
    parser.add_argument(
        "--fuzz-mouse",
        action="store_true",
        help="Also fuzz mouse motion and clicks, including clicks on the centres of visible Buttons. Implies --fuzz.",
    )
    parser.add_argument("--jobs", type=int, default=1, help="Run up to N scenes in parallel (default: 1).")
    parser.add_argument(
        "--profile",
        action="store_true",
        help="Sample Performance monitors during the run and report avg/p95/max plus start/end values.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        help="Wall-clock seconds before a scene's process is killed (default: max(30, seconds*3 + 20)).",
    )
    parser.add_argument(
        "--real-time",
        action="store_true",
        help=(
            "Run at wall-clock pace instead of --fixed-fps 60. Slower, but the engine's own fps/process-time "
            "monitors become meaningful and --seconds is wall time. Fuzz event timing stays seeded but the "
            "frame count is no longer fixed, so runs are only approximately reproducible."
        ),
    )
    parser.add_argument("--warnings-as-errors", action="store_true", help="Fail a scene that only produced warnings.")
    parser.add_argument("--no-warnings", action="store_true", help="Drop warnings from the diagnostics report.")
    parser.add_argument(
        "--no-debugger",
        dest="debugger",
        action="store_false",
        help="Do not attach the local stdout debugger (-d --ignore-error-breaks); GDScript warnings then vanish.",
    )
    parser.add_argument("--log-dir", default=None, help="Write each scene's raw combined log into this directory.")
    parser.add_argument(
        "--godot-bin",
        default=os.environ.get("GODOT_BIN", "godot"),
        help="Godot executable to invoke (default: GODOT_BIN or godot).",
    )
    parser.add_argument("--runner", default=None, help="Override the path to smoke_runner.gd.")
    parser.add_argument("--settle-frames", type=int, default=2, help="Frames to let the scene settle before the clock starts (default: 2).")
    parser.add_argument("--dry-run", action="store_true", help="Print the selected scenes and the command for the first one, then stop.")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print the JSON output.")
    return parser.parse_args(argv)


def usage_error(message: str) -> int:
    print(json.dumps({"ok": False, "error": message}))
    return 2


# ------------------------------------------------------------------- discovery


def discover_scenes(project: Path) -> list[str]:
    """Every .tscn under the project, as res:// paths, sorted."""
    found: list[str] = []
    for dirpath, dirnames, filenames in os.walk(project):
        here = Path(dirpath)
        if (here / ".gdignore").is_file() and here != project:
            dirnames[:] = []
            continue
        dirnames[:] = sorted(
            name for name in dirnames if not name.startswith(".") and name not in SKIP_DIRS
        )
        for name in sorted(filenames):
            if name.endswith(".tscn"):
                found.append("res://" + (here / name).relative_to(project).as_posix())
    return sorted(found)


def normalize_scene(value: str) -> str:
    text = value.strip().replace("\\", "/")
    if text.startswith("res://"):
        return text
    return "res://" + text.lstrip("/")


def matches_any(scene: str, globs: list[str]) -> bool:
    bare = scene[len("res://"):]
    for pattern in globs:
        candidate = pattern.strip()
        if fnmatch.fnmatch(scene, candidate) or fnmatch.fnmatch(bare, candidate):
            return True
        # A bare directory name ("levels") is the glob people reach for first.
        if fnmatch.fnmatch(bare, candidate.rstrip("/") + "/*"):
            return True
    return False


def select_scenes(project: Path, args: argparse.Namespace) -> tuple[list[str], Optional[str]]:
    available = discover_scenes(project)
    if args.scenes:
        selected: list[str] = []
        missing: list[str] = []
        for raw in args.scenes:
            scene = normalize_scene(raw)
            if not (project / scene[len("res://"):]).is_file():
                missing.append(scene)
            elif scene not in selected:
                selected.append(scene)
        if missing:
            hint = ""
            if available:
                hint = " Scenes in this project: " + ", ".join(available[:20])
                if len(available) > 20:
                    hint += f", … ({len(available)} total)"
            return [], (
                "--scenes names "
                + str(len(missing))
                + " path(s) that do not exist: "
                + ", ".join(missing)
                + "."
                + hint
            )
        return sorted(selected), None

    selected = list(available)
    if args.include:
        selected = [scene for scene in selected if matches_any(scene, args.include)]
    if args.exclude:
        selected = [scene for scene in selected if not matches_any(scene, args.exclude)]
    if not selected:
        if not available:
            return [], (
                f"No .tscn scenes found under {project}. Create one with the create_scene operation, or point "
                "smoke_scenes.py at the directory that holds project.godot."
            )
        return [], (
            "No scene matched --include/--exclude. "
            + f"{len(available)} scene(s) exist, for example: "
            + ", ".join(available[:10])
        )
    return selected, None


# --------------------------------------------------------------------- running


def godot_version(godot_bin: str) -> str:
    completed = subprocess.run(
        [godot_bin, "--version"], capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL
    )
    for line in (completed.stdout or "").splitlines() + (completed.stderr or "").splitlines():
        text = line.strip()
        if text and text[0].isdigit():
            return text
    return (completed.stdout or completed.stderr or "").strip()


def build_command(args: argparse.Namespace, project: Path, runner: Path, scene: str, budget_ms: int) -> list[str]:
    config = {
        "scene": scene,
        "seconds": args.seconds,
        "fps": 60.0,
        "profile": bool(args.profile),
        "fuzz": bool(args.fuzz or args.fuzz_mouse),
        "fuzz_seed": int(args.fuzz_seed),
        "fuzz_mouse": bool(args.fuzz_mouse),
        "settle_frames": max(int(args.settle_frames), 0),
        "budget_ms": budget_ms,
        "mode": "real_time" if args.real_time else "fixed_fps",
    }
    command = [args.godot_bin, "--headless"]
    if args.debugger:
        # -d routes GDScript warnings to stdout; --ignore-error-breaks keeps the
        # local debugger from breaking (and ending the run) on the first error.
        command += ["--debug", "--ignore-error-breaks"]
    if not args.real_time:
        command += ["--fixed-fps", "60"]
    command += ["--path", str(project), "--script", str(runner), "--", json.dumps(config, separators=(",", ":"))]
    return command


def kill_group(proc: subprocess.Popen) -> None:
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        try:
            proc.kill()
        except ProcessLookupError:
            pass


def run_one(command: list[str], timeout: float) -> tuple[str, int, bool, float]:
    start = time.monotonic()
    proc = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    timed_out = False
    try:
        output, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        # The whole process group goes, so a Godot that spawned helpers leaves
        # nothing running behind it.
        kill_group(proc)
        try:
            output, _ = proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            output = ""
    elapsed = time.monotonic() - start
    code = proc.returncode if proc.returncode is not None else -1
    return output or "", code, timed_out, elapsed


def extract_payload(output: str) -> Optional[dict]:
    for line in reversed(output.splitlines()):
        text = line.strip()
        if text.startswith(RESULT_MARKER):
            try:
                return json.loads(text[len(RESULT_MARKER):])
            except json.JSONDecodeError:
                return None
    return None


def signal_name(code: int) -> str:
    try:
        return signal.Signals(-code).name
    except (ValueError, TypeError):
        return f"signal {-code}"


def smoke_scene(args: argparse.Namespace, project: Path, runner: Path, scene: str, timeout: float) -> dict:
    budget_ms = max(int((timeout - 5.0) * 1000), 2000)
    command = build_command(args, project, runner, scene, budget_ms)
    output, returncode, timed_out, elapsed = run_one(command, timeout)

    if args.log_dir:
        log_dir = Path(args.log_dir).expanduser()
        log_dir.mkdir(parents=True, exist_ok=True)
        safe = scene[len("res://"):].replace("/", "__")
        (log_dir / f"{safe}.log").write_text(output, encoding="utf-8")

    payload = extract_payload(output)
    report = parse_log(output, include_warnings=not args.no_warnings)
    diagnostics = report["diagnostics"]
    counts = dict(report["counts"])

    findings: list[dict] = list(payload.get("findings", [])) if payload else []

    if timed_out:
        findings.insert(0, {
            "type": "timed_out",
            "severity": "error",
            "message": (
                f"The scene did not finish within {timeout:g}s of wall time and its process group was killed. "
                "Almost always an infinite/very long loop inside _ready, _process or _physics_process, or a "
                "blocking call (a while loop with no await, OS.delay_msec, a synchronous download). Anything "
                "logged before the kill is below."
            ),
        })
    elif returncode < 0:
        findings.insert(0, {
            "type": "crashed",
            "severity": "error",
            "message": (
                f"The engine died on {signal_name(returncode)} (return code {returncode}) while running this "
                "scene. That is an engine-level crash, not a GDScript error: look for infinite recursion "
                "(stack overflow), a freed object used after free, or a GDExtension. The last lines of the log "
                "are the best clue."
            ),
        })
    elif payload is None and returncode != 0:
        findings.insert(0, {
            "type": "crashed",
            "severity": "error",
            "message": (
                f"The Godot process exited with code {returncode} before the scene finished and printed no "
                "result. Read the diagnostics below: a boot-time parse error in an autoload or in this scene's "
                "script stops the run before anything else happens."
            ),
        })
    elif payload is None:
        findings.insert(0, {
            "type": "no_result",
            "severity": "error",
            "message": (
                "The run exited 0 but printed no [SMOKE_RESULT] line, so nothing could be measured. Re-run this "
                "one scene with --log-dir to keep the raw log."
            ),
        })

    error_findings = [f for f in findings if f.get("severity") == "error"]
    warning_findings = [f for f in findings if f.get("severity") == "warning"]
    counts["findings"] = len(findings)

    has_errors = counts["errors"] > 0 or counts["parse_errors"] > 0 or bool(error_findings)
    has_warnings = counts["warnings"] > 0 or bool(warning_findings)
    ok = not has_errors and not (args.warnings_as_errors and has_warnings)

    result = {
        "scene": scene,
        "ok": ok,
        "returncode": returncode,
        "duration_s": round(elapsed, 2),
        "timed_out": timed_out,
        "counts": counts,
        "findings": findings,
        "diagnostics": diagnostics,
    }
    if payload:
        result["frames"] = payload.get("frames")
        result["seconds_simulated"] = payload.get("seconds_simulated")
        result["ended"] = payload.get("ended")
        if payload.get("destination"):
            result["destination"] = payload["destination"]
        if payload.get("notes"):
            result["notes"] = payload["notes"]
        if payload.get("fuzz"):
            result["fuzz"] = payload["fuzz"]
        if payload.get("perf"):
            perf = dict(payload["perf"])
            perf["mode"] = "real_time" if args.real_time else "fixed_fps"
            if args.profile and not args.real_time:
                perf["fps_note"] = (
                    "--fixed-fps 60 decouples game time from wall time: 1 game second is 60 iterations run as "
                    "fast as the machine manages. Node, object, orphan and memory monitors are exact; frame_ms "
                    "is measured per frame by the runner and is exact. The engine's own fps/process/physics "
                    "timing monitors refresh once per REAL second, so on a short run they read 1.0/0.0 and are "
                    "reported as null. Re-run that one scene with --real-time --seconds 3 to get them."
                )
            result["perf"] = perf
    else:
        result["ended"] = "timed_out" if timed_out else ("crashed" if returncode != 0 else "no_result")
    return result


# ------------------------------------------------------------------------ main


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv or sys.argv[1:])

    project = Path(args.project_path).expanduser().resolve()
    if not (project / "project.godot").is_file():
        return usage_error(
            f"Missing Godot project file: {project / 'project.godot'}. Pass the directory that contains "
            "project.godot (the Godot project root)."
        )
    if args.seconds <= 0:
        return usage_error("--seconds must be greater than 0.")
    if args.jobs < 1:
        return usage_error("--jobs must be at least 1.")

    runner = Path(args.runner).expanduser().resolve() if args.runner else Path(__file__).resolve().with_name("smoke_runner.gd")
    if not runner.is_file():
        return usage_error(f"Runner script not found: {runner}")

    scenes, error = select_scenes(project, args)
    if error:
        return usage_error(error)

    timeout = args.timeout if args.timeout else max(30.0, args.seconds * 3.0 + 20.0)
    if timeout <= 0:
        return usage_error("--timeout must be greater than 0.")

    if args.dry_run:
        print(json.dumps({
            "project": str(project),
            "scenes": scenes,
            "timeout": timeout,
            "command": build_command(args, project, runner, scenes[0], max(int((timeout - 5.0) * 1000), 2000)),
        }, indent=2 if args.pretty else None))
        return 0

    try:
        version = godot_version(args.godot_bin)
    except FileNotFoundError as exc:
        return usage_error(
            f"Godot executable not found: {args.godot_bin} ({exc}). Install Godot 4.7, put it on PATH, or pass "
            "--godot-bin /abs/path/to/godot (GODOT_BIN also works)."
        )
    except OSError as exc:
        return usage_error(f"Could not run the Godot executable {args.godot_bin}: {exc}")
    if not version:
        return usage_error(
            f"`{args.godot_bin} --version` printed nothing, so the binary is not a working Godot. Pass "
            "--godot-bin /abs/path/to/godot."
        )

    start = time.monotonic()
    results: list[dict] = []
    pending = list(scenes)

    # A project with no import cache yet would have every parallel process
    # writing .godot/ at once, so the first scene always runs alone to build it.
    if args.jobs > 1 and pending and not (project / ".godot").is_dir():
        results.append(smoke_scene(args, project, runner, pending.pop(0), timeout))

    if args.jobs > 1 and pending:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = {pool.submit(smoke_scene, args, project, runner, scene, timeout): scene for scene in pending}
            for future in concurrent.futures.as_completed(futures):
                results.append(future.result())
    else:
        for scene in pending:
            results.append(smoke_scene(args, project, runner, scene, timeout))

    # Parallel runs finish out of order; the report never does.
    results.sort(key=lambda item: item["scene"])

    counts = {
        "scenes": len(results),
        "passed": sum(1 for item in results if item["ok"]),
        "failed": sum(1 for item in results if not item["ok"]),
        "errors": sum(item["counts"]["errors"] + item["counts"]["parse_errors"] for item in results),
        "warnings": sum(item["counts"]["warnings"] for item in results),
        "findings": sum(item["counts"]["findings"] for item in results),
    }
    payload = {
        "ok": counts["failed"] == 0,
        "project": str(project),
        "godot_version": version,
        "wall_seconds": round(time.monotonic() - start, 2),
        "seconds_per_scene": args.seconds,
        "counts": counts,
        "scenes": results,
    }
    print(json.dumps(payload, indent=2 if args.pretty else None))
    return 0 if payload["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
