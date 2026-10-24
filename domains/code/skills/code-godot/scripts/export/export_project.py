#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


MODE_TO_FLAG = {
    "debug": "--export-debug",
    "release": "--export-release",
    "pack": "--export-pack",
    "patch": "--export-patch",
}

PLATFORM_EXTENSIONS = {
    "Android": {".apk", ".aab"},
    "iOS": {".zip", ".ipa"},
    "VisionOS": {".zip"},
    "Web": {".html", ".zip"},
    "Windows Desktop": {".exe", ".zip"},
    "Linux/X11": {".x86_64", ".zip"},
    "Linux": {".x86_64", ".zip"},
    # An .app is a directory; Godot writes it directly, and artifact_is_present
    # below accepts a non-empty directory for exactly that reason.
    "macOS": {".zip", ".dmg", ".app"},
}

# `add_export_preset` platform key -> the Godot platform string it writes.
# Used to turn "that preset does not exist" into the command that creates it.
ADD_PRESET_PLATFORMS = {
    "web": "Web",
    "windows": "Windows Desktop",
    "linux": "Linux",
    "macos": "macOS",
    "android": "Android",
    "ios": "iOS",
}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a Godot export preset through the local godot CLI."
    )
    parser.add_argument("project_path", help="Path to the Godot project directory")
    parser.add_argument("preset_name", help="Exact preset name from export_presets.cfg")
    parser.add_argument("output_path", help="Output file path for the exported artifact")
    parser.add_argument(
        "--mode",
        choices=sorted(MODE_TO_FLAG),
        default="release",
        help="Export mode to use (default: release)",
    )
    parser.add_argument(
        "--godot-bin",
        default=os.environ.get("GODOT_BIN", "godot"),
        help="Godot executable to invoke (default: GODOT_BIN or godot)",
    )
    parser.add_argument(
        "--patches",
        nargs="+",
        default=[],
        help="Base PCK/ZIP patches for --mode patch, passed as a comma-separated --patches value",
    )
    parser.add_argument(
        "--preflight-only",
        action="store_true",
        help="Validate the preset, environment, and output path without exporting",
    )
    parser.add_argument(
        "--skip-preflight",
        action="store_true",
        help="Skip preflight checks before a real export",
    )
    parser.add_argument(
        "--strict-preflight",
        action="store_true",
        help="Fail dry-run when preflight reports errors",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the resolved command without running it",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a JSON payload instead of a shell-style command string",
    )
    return parser.parse_args(argv)


def resolve_paths(project_path_arg: str, output_path_arg: str) -> tuple[Path, Path]:
    project_path = Path(project_path_arg).expanduser().resolve()
    output_path = Path(output_path_arg).expanduser().resolve()
    project_file = project_path / "project.godot"
    if not project_file.is_file():
        raise SystemExit(f"Missing Godot project file: {project_file}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    return project_path, output_path


def build_command(
    godot_bin: str,
    mode: str,
    project_path: Path,
    preset_name: str,
    output_path: Path,
    patches: list[Path] | None = None,
) -> list[str]:
    command = [
        godot_bin,
        "--headless",
        "--path",
        str(project_path),
        MODE_TO_FLAG[mode],
        preset_name,
        str(output_path),
    ]
    if patches:
        command.extend(["--patches", ",".join(str(path) for path in patches)])
    return command


def bracket_delta(text: str) -> int:
    depth = 0
    in_string = False
    for glyph in text:
        if glyph == '"':
            in_string = not in_string
        elif not in_string:
            if glyph in "{[(":
                depth += 1
            elif glyph in "}])":
                depth -= 1
    return depth


def parse_godot_cfg(text: str) -> dict[str, dict[str, str]]:
    """Parse Godot's ConfigFile format into {section: {key: raw value}}.

    ``configparser`` cannot be used here. Godot writes dictionary and array
    values across several *unindented* lines::

        customized_files={
        "res://icon.svg": "strip"
        }

    which configparser reads as a new option ``"res://icon.svg"`` followed by a
    bare ``}`` — a ParsingError that used to make the whole preset file read as
    "this project has no export presets at all" while the presets were sitting
    right there. Continuation lines are collected until the brackets balance.
    """
    sections: dict[str, dict[str, str]] = {}
    current: dict[str, str] | None = None
    pending_key = ""
    pending_value = ""
    depth = 0
    for raw_line in text.splitlines():
        if pending_key:
            pending_value += "\n" + raw_line
            depth += bracket_delta(raw_line)
            if depth <= 0 and current is not None:
                current[pending_key] = pending_value
                pending_key = ""
                pending_value = ""
                depth = 0
            continue
        stripped = raw_line.strip()
        if stripped.startswith("[") and stripped.endswith("]") and len(stripped) > 2:
            current = sections.setdefault(stripped[1:-1], {})
            continue
        if not stripped or stripped.startswith(";") or stripped.startswith("#") or current is None:
            continue
        key, separator, value = raw_line.partition("=")
        if not separator:
            continue
        key = key.strip()
        depth = bracket_delta(value)
        if depth > 0:
            pending_key = key
            pending_value = value
        else:
            current[key] = value
            depth = 0
    if pending_key and current is not None:
        current[pending_key] = pending_value
    return sections


def parse_presets(project_path: Path) -> list[dict[str, str]]:
    preset_file = project_path / "export_presets.cfg"
    if not preset_file.is_file():
        return []
    try:
        sections = parse_godot_cfg(preset_file.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return []

    def unquote(value: str) -> str:
        value = value.strip()
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            return value[1:-1]
        return value

    presets = []
    # EditorExport::load_config() reads preset.0, preset.1, ... and stops at the
    # first missing index, so this walks them in the same order the engine does.
    index = 0
    while f"preset.{index}" in sections:
        section = f"preset.{index}"
        values = {key: unquote(value) for key, value in sections[section].items()}
        values["section"] = section
        # The export *options* live in a second section; a preflight check that
        # needs one (macOS architecture, the iOS team id) would otherwise have
        # to re-read the file.
        values["options"] = {key: unquote(value)
                             for key, value in sections.get(section + ".options", {}).items()}
        presets.append(values)
        index += 1
    return presets


def template_install_dir() -> str:
    if platform.system() == "Darwin":
        return "~/Library/Application Support/Godot/export_templates/<version>"
    if platform.system() == "Windows":
        return "%APPDATA%/Godot/export_templates/<version>"
    return "~/.local/share/godot/export_templates/<version>"


def guess_platform_key(preset_name: str, output_path: Path) -> str:
    """Best guess at which add_export_preset platform the caller meant.

    Matched against the preset name first (an agent that asks for "Web" wants
    the web preset even in a project that has none), then against the output
    extension, so the fix suggested for a missing preset is the right one.
    """
    lowered = preset_name.lower()
    for key, platform in ADD_PRESET_PLATFORMS.items():
        if key in lowered or platform.lower() in lowered:
            return key
    if "html" in lowered or "browser" in lowered:
        return "web"
    if "osx" in lowered or "mac" in lowered:
        return "macos"
    by_suffix = {".html": "web", ".exe": "windows", ".x86_64": "linux", ".app": "macos",
                 ".dmg": "macos", ".apk": "android", ".aab": "android", ".ipa": "ios"}
    return by_suffix.get(output_path.suffix.lower(), "linux")


def add_preset_command(project_path: Path, preset_name: str, output_path: Path) -> str:
    key = guess_platform_key(preset_name, output_path)
    dispatcher = Path(__file__).resolve().parents[1] / "core/dispatcher.gd"
    return (f"godot --headless --path {project_path} --script {dispatcher} "
            f"add_export_preset '{{\"platform\": \"{key}\", \"name\": \"{preset_name}\"}}'")


def missing_preset_error(project_path: Path, preset_name: str, output_path: Path,
                         presets: list[dict]) -> str:
    """Never a bare "preset does not exist": name the presets that do, and the
    exact command that creates the one that was asked for."""
    existing = [item.get("name", "") for item in presets]
    add_command = add_preset_command(project_path, preset_name, output_path)
    if existing:
        have = "Presets in this project: " + ", ".join(f'"{name}"' for name in existing) + "."
    else:
        have = "This project has no export presets at all."
    return (f'Export preset does not exist: "{preset_name}". {have} '
            f"Create it with: {add_command}")


def installed_template_path(godot_bin: str) -> Path | None:
    executable = shutil.which(godot_bin)
    if not executable:
        return None
    completed = subprocess.run([godot_bin, "--version"], capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        return None
    parts = completed.stdout.strip().split(".")
    version = ".".join(parts[:3]) if len(parts) >= 3 else completed.stdout.strip()
    candidates = [
        Path.home() / "Library/Application Support/Godot/export_templates" / version,
        Path.home() / ".local/share/godot/export_templates" / version,
        Path.home() / ".godot/export_templates" / version,
    ]
    if os.environ.get("APPDATA"):
        candidates.append(Path(os.environ["APPDATA"]) / "Godot/export_templates" / version)
    return next((path for path in candidates if path.is_dir()), None)


def preflight(
    project_path: Path,
    preset_name: str,
    output_path: Path,
    mode: str,
    patches: list[Path],
    godot_bin: str,
) -> dict:
    errors: list[str] = []
    warnings: list[str] = []
    fixes: list[str] = []
    presets = parse_presets(project_path)
    preset = next((item for item in presets if item.get("name") == preset_name), None)
    if not (project_path / "export_presets.cfg").is_file():
        errors.append(
            f"export_presets.cfg is missing in {project_path}. "
            + missing_preset_error(project_path, preset_name, output_path, presets))
        fixes.append(add_preset_command(project_path, preset_name, output_path))
    elif preset is None:
        errors.append(missing_preset_error(project_path, preset_name, output_path, presets))
        fixes.append(add_preset_command(project_path, preset_name, output_path))

    platform_name = preset.get("platform", "") if preset else ""
    if not shutil.which(godot_bin):
        errors.append(f"Godot executable was not found: {godot_bin}")
    templates = installed_template_path(godot_bin)
    if templates is None:
        if mode in {"pack", "patch"}:
            warnings.append("Matching Godot export templates were not found (not required for pack/patch data exports)")
        else:
            errors.append("Matching Godot export templates were not found")
            fixes.append(
                "Install the export templates for this exact engine build: in the editor, "
                "Editor > Manage Export Templates > Download and Install, or unpack "
                "Godot_v<version>_export_templates.tpz from https://godotengine.org/download into "
                f"{template_install_dir()}. --mode pack / --mode patch need no templates.")

    if mode == "patch" and not patches:
        errors.append("Patch mode requires at least one --patches base artifact")
    if mode != "patch" and patches:
        errors.append("--patches can only be used with --mode patch")
    for patch_path in patches:
        if not patch_path.is_file():
            errors.append(f"Patch base artifact does not exist: {patch_path}")

    expected_extensions = PLATFORM_EXTENSIONS.get(platform_name)
    if mode in {"pack", "patch"}:
        expected_extensions = {".pck", ".zip"}
    if expected_extensions and output_path.suffix.lower() not in expected_extensions:
        warnings.append(
            f"Output extension {output_path.suffix or '<none>'} is unusual for {platform_name or mode}; "
            f"expected one of {sorted(expected_extensions)}"
        )

    host = platform.system()
    if platform_name in {"iOS", "VisionOS"} and (host != "Darwin" or not shutil.which("xcodebuild")):
        errors.append(f"{platform_name} export requires macOS with Xcode")
    if platform_name == "macOS" and host != "Darwin":
        warnings.append("macOS signing and notarization require a macOS host")
    if platform_name == "Android" and not shutil.which("java"):
        errors.append("Android export requires a configured JDK")
        fixes.append("Install JDK 17 and point the Godot editor setting export/android/java_sdk_path at it, "
                     "plus export/android/android_sdk_path at an Android SDK.")
    options: dict = preset.get("options", {}) if preset else {}
    if platform_name in {"iOS", "VisionOS"} and not options.get("application/app_store_team_id", ""):
        # Verified on 4.7: the export aborts with "App Store Team ID not
        # specified." long before it reaches signing.
        errors.append("iOS/visionOS export needs an Apple Developer team id: "
                      "set the preset option application/app_store_team_id "
                      "(the export fails with 'App Store Team ID not specified.' without it)")
        fixes.append(f"godot --headless --path {project_path} --script "
                     f"{Path(__file__).resolve().parents[1] / 'core/dispatcher.gd'} add_export_preset "
                     f"'{{\"platform\": \"ios\", \"name\": \"{preset_name}\", \"overwrite\": true, "
                     '"options": {"application/app_store_team_id": "YOURTEAMID"}}\'')
    needs_etc2 = platform_name in {"Android", "iOS", "VisionOS"} or (
        platform_name == "macOS" and options.get("binary_format/architecture", "universal") in
        {"universal", "arm64"})
    if needs_etc2 and not etc2_astc_enabled(project_path):
        errors.append(
            "Project setting rendering/textures/vram_compression/import_etc2_astc must be true for "
            f"{platform_name} (Godot refuses with 'Cannot export for universal or arm64 if ETC2 ASTC "
            "texture format is disabled')")
        fixes.append(f"godot --headless --path {project_path} --script "
                     f"{Path(__file__).resolve().parents[1] / 'core/dispatcher.gd'} project_batch "
                     '\'{"actions":[{"type":"set_setting",'
                     '"name":"rendering/textures/vram_compression/import_etc2_astc","value":true}]}\'')
    if platform_name in {"Windows Desktop", "Linux", "Linux/X11"} and "server" in preset_name.lower():
        warnings.append("Dedicated server presets should disable rendering and include the dedicated_server feature tag")
    if output_path.is_relative_to(project_path):
        warnings.append("Export output is inside the project tree; confirm it is excluded from source imports and version control")

    return {
        "ok": not errors,
        "errors": errors,
        "fixes": fixes,
        "warnings": warnings,
        "preset": preset or {},
        "available_presets": [item.get("name", "") for item in presets],
        "platform": platform_name,
        "export_templates": str(templates) if templates else "",
        "host": host,
    }


def etc2_astc_enabled(project_path: Path) -> bool:
    """Godot's own default is false, so an absent key means disabled."""
    project_file = project_path / "project.godot"
    try:
        text = project_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    for line in text.splitlines():
        stripped = line.strip().replace(" ", "")
        if stripped.startswith("textures/vram_compression/import_etc2_astc="):
            return stripped.split("=", 1)[1].lower().startswith("true")
    return False


def artifact_is_present(output_path: Path) -> bool:
    """True when the export actually wrote something at the requested path.

    Some targets write a directory (an unzipped macOS .app, an Android build
    directory), so a directory counts when it is non-empty.
    """
    if output_path.is_file():
        return output_path.stat().st_size > 0
    if output_path.is_dir():
        return any(output_path.iterdir())
    return False


def emit(
    command: list[str],
    project_path: Path,
    preset_name: str,
    output_path: Path,
    mode: str,
    as_json: bool,
    preflight_result: dict,
) -> None:
    if as_json:
        print(
            json.dumps(
                {
                    "command": command,
                    "project_path": str(project_path),
                    "preset_name": preset_name,
                    "output_path": str(output_path),
                    "mode": mode,
                    "preflight": preflight_result,
                }
            )
        )
        return
    print(shlex.join(command))


def report_blockers(preflight_result: dict) -> None:
    """Mirror the blockers on stderr.

    The JSON payload already carries them, but a caller that only reads stderr
    (or a human watching a terminal) would otherwise see an exit code with no
    explanation at all.
    """
    if preflight_result["ok"]:
        return
    for message in preflight_result["errors"]:
        print(f"export preflight: {message}", file=sys.stderr)
    for fix in preflight_result.get("fixes", []):
        print(f"export preflight fix: {fix}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    project_path, output_path = resolve_paths(args.project_path, args.output_path)
    patches = [Path(path).expanduser().resolve() for path in args.patches]
    command = build_command(
        godot_bin=args.godot_bin,
        mode=args.mode,
        project_path=project_path,
        preset_name=args.preset_name,
        output_path=output_path,
        patches=patches,
    )
    preflight_result = preflight(
        project_path,
        args.preset_name,
        output_path,
        args.mode,
        patches,
        args.godot_bin,
    )
    if args.preflight_only:
        emit(command, project_path, args.preset_name, output_path, args.mode, True, preflight_result)
        report_blockers(preflight_result)
        return 0 if preflight_result["ok"] else 1
    if args.dry_run:
        emit(command, project_path, args.preset_name, output_path, args.mode, args.json, preflight_result)
        return 1 if args.strict_preflight and not preflight_result["ok"] else 0
    if not args.skip_preflight and not preflight_result["ok"]:
        emit(command, project_path, args.preset_name, output_path, args.mode, True, preflight_result)
        report_blockers(preflight_result)
        return 1
    completed = subprocess.run(command, check=False)
    # Godot's exporter has exited 0 while producing nothing (missing template
    # variant, a preset that filtered every file out, an unwritable target).
    # Reporting that as a successful build is the failure mode this guards.
    if completed.returncode == 0 and not artifact_is_present(output_path):
        print(
            f"Export reported success but produced no artifact at {output_path}. "
            "Check the export template for this preset and the output path's permissions.",
            file=sys.stderr,
        )
        return 1
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
