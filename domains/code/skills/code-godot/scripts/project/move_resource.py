#!/usr/bin/env python3
"""Move or rename files and folders in a Godot project the way the editor does.

Inside the editor, dragging a file in the FileSystem dock rewrites every
reference to it. From a shell there is no such safety net: a plain ``mv`` leaves
`[ext_resource path="res://…"]`, ``preload("res://…")``, ``project.godot``'s
``run/main_scene`` / `[autoload]`, `.import` ``source_file=`` and the shader
`#include` lines pointing at a file that is no longer there.

The damage is often **silent**. Verified on 4.7: an `[ext_resource]` that carries
both ``uid=`` and ``path=`` resolves through the uid, so after a bare ``mv`` of a
texture *and* its `.import` the project imports, loads and runs with **zero
diagnostics** while the recorded path is wrong — until someone opens the file in
a text editor, exports without the uid cache, or the uid sidecar is lost. The
same move of a `.gd` file breaks `preload()` loudly but leaves `[autoload]`
half-working. This tool removes that whole class of failure:

1. plan every move and every edit **first** (``--dry-run`` prints the plan and
   touches nothing),
2. move the file plus its sidecars (`.import`, `.uid`) and everything inside a
   moved directory,
3. rewrite every reference in every text file of the project,
4. re-import, and
5. prove the project is no worse than before by running
   ``scripts/debug/lint_project.py --only missing_resource`` before *and* after.

Output is one JSON document (``--pretty`` to indent):
``{ok, dry_run, moved[], edits[], mentions[], warnings[], counts{}, import{},
verify{}}``.

Exit codes: ``0`` success · ``1`` applied but a reference broke (or an I/O
failure forced a rollback) · ``2`` refused, nothing touched.

Out of scope, on purpose: renaming a ``class_name`` (a move never changes it —
the class name lives in the script text, not in its path) and renaming a *node*
(use the scene ops and check the result with
``lint_project.py --only node_ref``).
"""
from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable, Optional

SCRIPT_DIR = Path(__file__).resolve().parent
LINT_SCRIPT = SCRIPT_DIR.parent / "debug" / "lint_project.py"

# Text files whose contents are scanned for references. Everything else is left
# alone, which is also how binaries stay safe: they are never opened.
SCAN_EXTENSIONS = {
    ".tscn", ".escn", ".tres", ".gd", ".gdshader", ".gdshaderinc",
    ".import", ".cfg", ".godot", ".gdextension", ".remap", ".cs",
}
SCAN_NAMES = {"project.godot", "export_presets.cfg", "override.cfg"}

GDSCRIPT_EXTENSIONS = {".gd"}
SHADER_EXTENSIONS = {".gdshader", ".gdshaderinc"}

# Binary equivalents of `.tscn`/`.tres`. Their `[ext_resource]` table is not
# text, so nothing here can rewrite it — say so instead of missing it quietly.
OPAQUE_EXTENSIONS = {".scn", ".res", ".ctex", ".mesh", ".material", ".font"}

# Directory names that are never walked. `.godot` is the engine's own cache and
# anything starting with a dot is invisible to Godot too.
ALWAYS_SKIP_DIRS = {".godot", ".git", ".svn", ".hg", "__pycache__", "node_modules"}

# A res:// token: everything up to the first character that cannot appear in a
# path reference in practice. Quotes, brackets, commas and whitespace end it.
RES_TOKEN_RE = re.compile(r"res://[^\s\"'`,;()\[\]{}<>|]*")
# Trailing sentence punctuation is not part of the path (matters in comments).
TRAILING_PUNCT = ".,;:!?"

QUOTED_RE = re.compile(r"\"([^\"\n]*)\"|'([^'\n]*)'")
INCLUDE_RE = re.compile(r"(#\s*include\s+\")([^\"\n]+)(\")")
FILTER_RE = re.compile(r"^(\s*(?:include_filter|exclude_filter)\s*=\s*\")([^\"\n]*)(\")", re.MULTILINE)


class MoveError(Exception):
    """A refusal: printed as JSON, exit code 2, nothing on disk was touched."""


# --------------------------------------------------------------------------
# path helpers
# --------------------------------------------------------------------------

def normalize_project_path(project: Path, raw: str, *, label: str) -> str:
    """Accept ``res://a/b.png``, ``a/b.png``, ``./a/b.png`` or an absolute path
    inside the project; return the project-relative POSIX form."""
    if raw is None or str(raw).strip() == "":
        raise MoveError(f"{label} is empty. Pass a project-relative path such as art/player.png.")
    text = str(raw).strip().replace("\\", "/")
    trailing_slash = text.endswith("/")
    if text.startswith("res://"):
        text = text[len("res://"):]
        candidate = (project / text).resolve() if text else project.resolve()
    elif text.startswith("user://"):
        raise MoveError(
            f"{label} is a user:// path ({raw}). Only files inside the project (res://) can be moved.")
    elif os.path.isabs(text):
        candidate = Path(text).resolve()
    else:
        candidate = (project / text).resolve()

    root = project.resolve()
    try:
        relative = candidate.relative_to(root)
    except ValueError:
        raise MoveError(
            f"{label} resolves to {candidate}, which is outside the project {root}. "
            f"Move destinations must stay inside the project.") from None
    rel = relative.as_posix()
    if rel in ("", "."):
        raise MoveError(f"{label} is the project root itself. Name a file or a folder inside it.")
    return rel + "/" if trailing_slash else rel


def res_path(rel: str) -> str:
    return "res://" + rel.rstrip("/")


def is_case_insensitive_same(a: Path, b: Path) -> bool:
    """True when `b` "exists" only because the filesystem folds case (macOS)."""
    try:
        return a.exists() and b.exists() and os.path.samefile(a, b)
    except OSError:
        return False


def inside(child: str, parent: str) -> bool:
    return child == parent or child.startswith(parent + "/")


def on_disk_spelling(project: Path, rel: str) -> Optional[str]:
    """The real, case-exact project-relative spelling of `rel`, or None.

    macOS and Windows fold case, so ``Path("art/Player.png").exists()`` is true
    for ``art/player.png``. Moving the wrong spelling would rewrite references
    to a name that does not exist on a case-sensitive filesystem (every Linux CI
    box), so the spelling is checked instead of trusted.
    """
    current = project
    parts: list[str] = []
    for part in rel.split("/"):
        try:
            entries = {entry.name for entry in os.scandir(current)}
        except OSError:
            return None
        if part in entries:
            real = part
        else:
            matches = [name for name in entries if name.lower() == part.lower()]
            if len(matches) != 1:
                return None
            real = matches[0]
        parts.append(real)
        current = current / real
    return "/".join(parts)


# --------------------------------------------------------------------------
# the plan
# --------------------------------------------------------------------------

class Move:
    def __init__(self, src_rel: str, dst_rel: str, kind: str) -> None:
        self.src_rel = src_rel
        self.dst_rel = dst_rel
        self.kind = kind  # "file" | "dir"
        self.sidecars: list[tuple[str, str]] = []  # (src_rel, dst_rel)
        self.file_pairs: list[tuple[str, str]] = []  # every file physically relocated
        self.case_only = False

    def report(self) -> dict:
        return {
            "from": res_path(self.src_rel),
            "to": res_path(self.dst_rel),
            "kind": self.kind,
            "sidecars": [res_path(s) for s, _ in self.sidecars],
            "files": len(self.file_pairs),
            "case_only_rename": self.case_only,
        }


class Plan:
    def __init__(self, project: Path) -> None:
        self.project = project
        self.moves: list[Move] = []
        self.exact: dict[str, str] = {}      # res://old -> res://new (per file)
        self.prefixes: list[tuple[str, str]] = []  # ("res://old/", "res://new/")
        self.rel_exact: dict[str, str] = {}  # project-relative old -> new (filters)

    def has_space_paths(self) -> bool:
        return any(" " in key for key in self.exact)

    def remap_token(self, token: str) -> Optional[str]:
        """Map one res:// token, or None when nothing changes."""
        direct = self.exact.get(token)
        if direct is not None:
            return direct
        stripped = token.rstrip("/")
        if stripped != token:
            direct = self.exact.get(stripped)
            if direct is not None:
                return direct + "/"
        for old, new in self.prefixes:
            if token.startswith(old):
                return new + token[len(old):]
        return None

    def remap_rel_file(self, rel: str) -> str:
        """Where a project file lives after the plan is applied."""
        mapped = self.exact.get(res_path(rel))
        if mapped is not None:
            return mapped[len("res://"):]
        for old, new in self.prefixes:
            token = res_path(rel)
            if token.startswith(old):
                return (new + token[len(old):])[len("res://"):]
        return rel


def collect_sidecars(project: Path, src_rel: str, dst_rel: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for suffix in (".import", ".uid"):
        if (project / (src_rel + suffix)).is_file():
            out.append((src_rel + suffix, dst_rel + suffix))
    return out


def resolve_destination(project: Path, src_rel: str, dst_raw: str) -> str:
    """`mv` semantics: an existing directory or a trailing slash means "into"."""
    dst_rel = normalize_project_path(project, dst_raw, label="DST")
    into_dir = dst_rel.endswith("/")
    dst_rel = dst_rel.rstrip("/")
    if into_dir or (project / dst_rel).is_dir():
        # Moving `a/b` into the directory `a` would be a no-op; catch it early.
        dst_rel = posixpath.join(dst_rel, posixpath.basename(src_rel))
    return dst_rel


def build_plan(project: Path, pairs: list[tuple[str, str]]) -> Plan:
    plan = Plan(project)
    seen_src: dict[str, str] = {}
    seen_dst: dict[str, str] = {}

    for raw_src, raw_dst in pairs:
        src_rel = normalize_project_path(project, raw_src, label="SRC").rstrip("/")
        src_abs = project / src_rel
        if not src_abs.exists():
            near = nearest_names(project, src_rel)
            hint = f" Did you mean: {', '.join(near)}?" if near else ""
            raise MoveError(f"SRC does not exist: {res_path(src_rel)}.{hint}")
        real_src = on_disk_spelling(project, src_rel)
        if real_src is not None and real_src != src_rel:
            raise MoveError(
                f"SRC does not exist: {res_path(src_rel)}. The file on disk is {res_path(real_src)} — "
                f"only the capitalisation differs, and this filesystem folds case. "
                f"Use the exact spelling, or references would be rewritten to a name that does not "
                f"exist on a case-sensitive filesystem.")
        if src_rel == "project.godot":
            raise MoveError(
                "Refusing to move project.godot: it is the project root marker and Godot locates "
                "the project by it. Edit its contents instead (scripts/project/project_batch.gd).")
        if src_rel == ".godot" or inside(src_rel, ".godot"):
            raise MoveError(
                "Refusing to touch .godot/: it is the engine's regenerated cache. "
                "Delete it and re-run `godot --headless --path <project> --import` if it is stale.")

        dst_rel = resolve_destination(project, src_rel, raw_dst)
        dst_abs = project / dst_rel
        if dst_rel == "project.godot" or inside(dst_rel, ".godot"):
            raise MoveError(f"Refusing to write into {res_path(dst_rel)}.")
        if dst_rel == src_rel:
            raise MoveError(f"SRC and DST are the same path: {res_path(src_rel)}. Nothing to do.")

        case_only = is_case_insensitive_same(src_abs, dst_abs)
        if dst_abs.exists() and not case_only:
            raise MoveError(
                f"DST already exists: {res_path(dst_rel)}. "
                f"Delete it first, or pass a destination that does not exist.")
        if src_abs.is_dir() and inside(dst_rel, src_rel):
            raise MoveError(
                f"DST {res_path(dst_rel)} is inside SRC {res_path(src_rel)}: "
                f"a directory cannot be moved into itself.")
        parent = dst_abs.parent
        if parent.exists() and not parent.is_dir():
            raise MoveError(
                f"The parent of DST is a file, not a folder: {res_path(parent.relative_to(project).as_posix())}.")

        if src_rel in seen_src:
            raise MoveError(f"{res_path(src_rel)} is listed twice in the move map.")
        if dst_rel in seen_dst:
            raise MoveError(
                f"Two moves target the same destination {res_path(dst_rel)} "
                f"({res_path(seen_dst[dst_rel])} and {res_path(src_rel)}).")
        seen_src[src_rel] = dst_rel
        seen_dst[dst_rel] = src_rel

        move = Move(src_rel, dst_rel, "dir" if src_abs.is_dir() else "file")
        move.case_only = case_only
        plan.moves.append(move)

    # --- cross-move conflicts ------------------------------------------------
    for a in plan.moves:
        for b in plan.moves:
            if a is b:
                continue
            if a.dst_rel == b.src_rel:
                raise MoveError(
                    f"Cyclic plan: {res_path(a.src_rel)} -> {res_path(a.dst_rel)} collides with "
                    f"{res_path(b.src_rel)} -> {res_path(b.dst_rel)}. Use a temporary name and two calls.")
            if inside(a.src_rel, b.src_rel):
                raise MoveError(
                    f"Ambiguous plan: {res_path(a.src_rel)} is inside {res_path(b.src_rel)} and both are "
                    f"being moved. Move the parent folder alone, then the file in a second call.")
            if inside(a.dst_rel, b.src_rel):
                raise MoveError(
                    f"Ambiguous plan: {res_path(a.src_rel)} is moved into {res_path(a.dst_rel)}, which is "
                    f"inside {res_path(b.src_rel)} — itself being moved to {res_path(b.dst_rel)}.")

    # --- expand into per-file mappings --------------------------------------
    for move in plan.moves:
        src_abs = project / move.src_rel
        if move.kind == "dir":
            plan.prefixes.append((res_path(move.src_rel) + "/", res_path(move.dst_rel) + "/"))
            plan.exact[res_path(move.src_rel)] = res_path(move.dst_rel)
            plan.rel_exact[move.src_rel] = move.dst_rel
            for path in sorted(src_abs.rglob("*")):
                if not path.is_file():
                    continue
                rel = path.relative_to(project).as_posix()
                tail = rel[len(move.src_rel) + 1:]
                new_rel = posixpath.join(move.dst_rel, tail)
                move.file_pairs.append((rel, new_rel))
                plan.exact[res_path(rel)] = res_path(new_rel)
                plan.rel_exact[rel] = new_rel
        else:
            move.sidecars = collect_sidecars(project, move.src_rel, move.dst_rel)
            move.file_pairs.append((move.src_rel, move.dst_rel))
            move.file_pairs.extend(move.sidecars)
            plan.exact[res_path(move.src_rel)] = res_path(move.dst_rel)
            plan.rel_exact[move.src_rel] = move.dst_rel
            for src_side, dst_side in move.sidecars:
                plan.exact[res_path(src_side)] = res_path(dst_side)
                plan.rel_exact[src_side] = dst_side

    # Longest prefix wins, so a nested folder move is applied before its parent.
    plan.prefixes.sort(key=lambda item: len(item[0]), reverse=True)
    return plan


def nearest_names(project: Path, missing_rel: str, limit: int = 3) -> list[str]:
    """Cheap "did you mean" over the basenames present in the project."""
    import difflib

    target = posixpath.basename(missing_rel)
    candidates: list[str] = []
    for root, dirs, files in os.walk(project):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ALWAYS_SKIP_DIRS]
        for name in files:
            rel = (Path(root) / name).relative_to(project).as_posix()
            candidates.append(rel)
        if len(candidates) > 4000:
            break
    by_base = [rel for rel in candidates if posixpath.basename(rel) == target]
    if by_base:
        return [res_path(rel) for rel in sorted(by_base)[:limit]]
    close = difflib.get_close_matches(missing_rel, candidates, n=limit, cutoff=0.6)
    return [res_path(rel) for rel in close]


# --------------------------------------------------------------------------
# scanning text files
# --------------------------------------------------------------------------

def iter_scan_files(project: Path, *, extra_ext: set[str], include_addons: bool,
                    opaque: Optional[list[Path]] = None) -> Iterable[Path]:
    wanted = SCAN_EXTENSIONS | extra_ext
    for root, dirs, files in os.walk(project):
        root_path = Path(root)
        if (root_path / ".gdignore").exists():
            dirs[:] = []
            continue
        pruned = []
        for name in dirs:
            if name.startswith(".") or name in ALWAYS_SKIP_DIRS:
                continue
            if name == "addons" and root_path == project and not include_addons:
                continue
            pruned.append(name)
        dirs[:] = sorted(pruned)
        for name in sorted(files):
            path = root_path / name
            suffix = path.suffix.lower()
            if name in SCAN_NAMES or suffix in wanted:
                yield path
            elif opaque is not None and suffix in OPAQUE_EXTENSIONS:
                opaque.append(path)


def read_text(path: Path) -> Optional[str]:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if b"\x00" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


# --- GDScript / shader span scanners ---------------------------------------

def gdscript_spans(text: str) -> list[tuple[str, int, int]]:
    """Return ``(kind, start, end)`` spans for GDScript strings and comments.

    ``start``/``end`` delimit the *contents* of a string (quotes excluded) and
    the whole ``# …`` run for a comment. Triple-quoted strings, raw strings
    (``r"…"``), StringName (``&"…"``) and NodePath (``^"…"``) literals are all
    recognised — the prefix characters sit before the quote, so only ``r``
    changes anything (it disables escape processing).
    """
    spans: list[tuple[str, int, int]] = []
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if char == "#":
            end = text.find("\n", index)
            end = length if end == -1 else end
            spans.append(("comment", index, end))
            index = end
            continue
        if char in "\"'":
            raw = index > 0 and text[index - 1] in "rR"
            triple = text.startswith(char * 3, index)
            quote = char * 3 if triple else char
            start = index + len(quote)
            cursor = start
            while cursor < length:
                if not raw and text[cursor] == "\\":
                    cursor += 2
                    continue
                if not triple and text[cursor] == "\n":
                    break
                if text.startswith(quote, cursor):
                    break
                cursor += 1
            spans.append(("string", start, min(cursor, length)))
            index = min(cursor + len(quote), length) if cursor < length else length
            continue
        index += 1
    return spans


def shader_spans(text: str) -> list[tuple[str, int, int]]:
    spans: list[tuple[str, int, int]] = []
    index = 0
    length = len(text)
    while index < length:
        if text.startswith("//", index):
            end = text.find("\n", index)
            end = length if end == -1 else end
            spans.append(("comment", index, end))
            index = end
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = length if end == -1 else end + 2
            spans.append(("comment", index, end))
            index = end
            continue
        if text[index] == '"':
            cursor = index + 1
            while cursor < length and text[cursor] not in "\"\n":
                cursor += 1
            spans.append(("string", index + 1, cursor))
            index = cursor + 1
            continue
        index += 1
    return spans


def generic_spans(text: str) -> list[tuple[str, int, int]]:
    """Everything outside GDScript/shaders is scanned wholesale: `.tscn`,
    `.tres`, `.import` and `.cfg` have no comment syntax that could hold a
    reference we must not touch, and a `res://` token there is always a path."""
    return [("string", 0, len(text))]


# --- rewriting --------------------------------------------------------------

def rewrite_token_run(plan: Plan, text: str) -> tuple[str, int]:
    """Replace every res:// token in `text`. Returns (new_text, replacements)."""
    count = 0

    def repl(match: re.Match) -> str:
        nonlocal count
        token = match.group(0)
        tail = ""
        # `res://level.tscn::SubResource_1` addresses a sub-resource inside the
        # file: only the file part is a path.
        marker = token.find("::")
        if marker != -1:
            tail = token[marker:]
            token = token[:marker]
        while token and token[-1] in TRAILING_PUNCT and plan.remap_token(token) is None:
            tail = token[-1] + tail
            token = token[:-1]
        mapped = plan.remap_token(token)
        if mapped is None:
            return match.group(0)
        count += 1
        return mapped + tail

    return RES_TOKEN_RE.sub(repl, text), count


def rewrite_spaced_quoted(plan: Plan, text: str) -> tuple[str, int]:
    """Whole-quoted-string replacement, the only way to catch a path with a
    space in it (the token scanner stops at whitespace)."""
    if not plan.has_space_paths():
        return text, 0
    count = 0

    def repl(match: re.Match) -> str:
        nonlocal count
        content = match.group(1) if match.group(1) is not None else match.group(2)
        quote = '"' if match.group(1) is not None else "'"
        star = ""
        body = content
        if body.startswith("*"):
            star, body = "*", body[1:]
        mapped = plan.exact.get(body)
        if mapped is None or " " not in body:
            return match.group(0)
        count += 1
        return f"{quote}{star}{mapped}{quote}"

    return QUOTED_RE.sub(repl, text), count


def rewrite_spans(plan: Plan, text: str, spans: list[tuple[str, int, int]],
                  ) -> tuple[str, int, list[int]]:
    """Rewrite only inside `string` spans; note the offsets of comment spans
    that mention a path the plan moves."""
    pieces: list[str] = []
    cursor = 0
    total = 0
    mention_offsets: list[int] = []
    for kind, start, end in spans:
        if start < cursor:
            continue
        pieces.append(text[cursor:start])
        chunk = text[start:end]
        if kind == "string":
            chunk, spaced = rewrite_spaced_quoted(plan, chunk)
            chunk, tokens = rewrite_token_run(plan, chunk)
            total += spaced + tokens
        else:
            for match in RES_TOKEN_RE.finditer(chunk):
                token = match.group(0).rstrip(TRAILING_PUNCT)
                if plan.remap_token(token) is not None:
                    mention_offsets.append(start + match.start())
        pieces.append(chunk)
        cursor = end
    pieces.append(text[cursor:])
    return "".join(pieces), total, mention_offsets


def rewrite_shader_includes(plan: Plan, text: str, old_rel: str, new_rel: str) -> tuple[str, int]:
    """`#include "relative.gdshaderinc"` is resolved against the *including*
    file's folder, so it has to be recomputed whenever either end moves."""
    old_dir = posixpath.dirname(old_rel)
    new_dir = posixpath.dirname(new_rel)
    count = 0

    def repl(match: re.Match) -> str:
        nonlocal count
        head, target, tail = match.group(1), match.group(2), match.group(3)
        if target.startswith("res://"):
            return match.group(0)  # absolute form: the token scanner handled it
        old_target = posixpath.normpath(posixpath.join(old_dir, target))
        new_target = plan.rel_exact.get(old_target, old_target)
        if new_target == old_target and new_dir == old_dir:
            return match.group(0)
        relative = posixpath.relpath(new_target, new_dir or ".")
        # `..` in a shader include resolves relative to the including file in
        # 4.7, but the absolute form is unambiguous and survives another move.
        replacement = relative if not relative.startswith("..") else res_path(new_target)
        if replacement == target:
            return match.group(0)
        count += 1
        return head + replacement + tail

    return INCLUDE_RE.sub(repl, text), count


def rewrite_export_filters(plan: Plan, text: str) -> tuple[str, int]:
    """`include_filter`/`exclude_filter` hold a comma-separated list of globs
    and plain project-relative paths (no `res://` prefix)."""
    count = 0

    def repl(match: re.Match) -> str:
        nonlocal count
        head, body, tail = match.group(1), match.group(2), match.group(3)
        parts = body.split(",")
        changed = False
        out = []
        for part in parts:
            stripped = part.strip()
            mapped = plan.rel_exact.get(stripped)
            if mapped is None:
                out.append(part)
                continue
            changed = True
            count += 1
            out.append(part.replace(stripped, mapped))
        if not changed:
            return match.group(0)
        return head + ",".join(out) + tail

    return FILTER_RE.sub(repl, text), count


def plan_edits(plan: Plan, *, extra_ext: set[str], include_addons: bool,
               ) -> tuple[list[dict], list[dict], dict[str, tuple[str, str]], int, list[str]]:
    """Compute every file edit without writing anything.

    Returns ``(edits, mentions, new_contents, references, warnings)`` where
    ``new_contents`` maps the file's **post-move** project-relative path to
    ``(pre-move path, rewritten text)`` — the pre-move path is what gets backed
    up, because that is where the file still is when the apply phase starts.
    """
    project = plan.project
    edits: list[dict] = []
    mentions: list[dict] = []
    new_contents: dict[str, tuple[str, str]] = {}
    warnings: list[str] = []
    opaque: list[Path] = []
    references = 0

    for path in iter_scan_files(project, extra_ext=extra_ext, include_addons=include_addons,
                                opaque=opaque):
        old_rel = path.relative_to(project).as_posix()
        text = read_text(path)
        if text is None:
            warnings.append(
                f"{res_path(old_rel)} is not readable as UTF-8 text and was not scanned for "
                f"references — check it by hand.")
            continue
        new_rel = plan.remap_rel_file(old_rel)
        suffix = path.suffix.lower()
        if suffix in GDSCRIPT_EXTENSIONS:
            spans = gdscript_spans(text)
        elif suffix in SHADER_EXTENSIONS:
            spans = shader_spans(text)
        else:
            spans = generic_spans(text)

        updated, count, mention_offsets = rewrite_spans(plan, text, spans)
        if suffix in SHADER_EXTENSIONS:
            updated, include_count = rewrite_shader_includes(plan, updated, old_rel, new_rel)
            count += include_count
        if path.name == "export_presets.cfg":
            updated, filter_count = rewrite_export_filters(plan, updated)
            count += filter_count

        before_lines = text.split("\n")
        for offset in mention_offsets:
            line_no = text.count("\n", 0, offset) + 1
            line = before_lines[line_no - 1].rstrip("\r")
            mentions.append({"file": res_path(new_rel), "line": line_no, "text": line.strip()})

        if updated == text:
            continue
        references += count
        new_contents[new_rel] = (old_rel, updated)
        after_lines = updated.split("\n")
        for index, (before, after) in enumerate(zip(before_lines, after_lines), start=1):
            if before != after:
                edits.append({
                    "file": res_path(new_rel),
                    "line": index,
                    "before": before.rstrip("\r"),
                    "after": after.rstrip("\r"),
                })

    if opaque:
        names = ", ".join(res_path(path.relative_to(project).as_posix()) for path in opaque[:5])
        warnings.append(
            f"{len(opaque)} binary resource file(s) were not scanned ({names}"
            f"{', …' if len(opaque) > 5 else ''}): their reference table is not text. Re-save them "
            f"as .tscn/.tres, or check them with `resave_resources` after the move.")

    edits.sort(key=lambda item: (item["file"], item["line"]))
    mentions.sort(key=lambda item: (item["file"], item["line"]))
    return edits, mentions, new_contents, references, warnings


# --------------------------------------------------------------------------
# applying
# --------------------------------------------------------------------------

class Journal:
    """Everything needed to put the project back exactly as it was."""

    def __init__(self, project: Path) -> None:
        self.project = project
        self.backup_dir = Path(tempfile.mkdtemp(prefix="godot-move-backup-"))
        self.moves_done: list[tuple[Path, Path]] = []
        self.dirs_made: list[Path] = []
        self.dirs_removed: list[Path] = []
        self.files_backed_up: list[tuple[Path, Path]] = []

    def backup(self, path: Path) -> None:
        target = self.backup_dir / path.relative_to(self.project)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        self.files_backed_up.append((path, target))

    def makedirs(self, directory: Path) -> None:
        missing = []
        probe = directory
        while not probe.exists():
            missing.append(probe)
            probe = probe.parent
        for made in reversed(missing):
            made.mkdir()
            self.dirs_made.append(made)

    def move(self, src: Path, dst: Path) -> None:
        shutil.move(str(src), str(dst))
        self.moves_done.append((src, dst))

    def prune_empty(self, directory: Path) -> None:
        """Remove a source folder the move emptied, and its emptied parents."""
        probe = directory
        while probe != self.project and probe.is_dir():
            try:
                next(probe.iterdir())
                return
            except StopIteration:
                pass
            except OSError:
                return
            probe.rmdir()
            self.dirs_removed.append(probe)
            probe = probe.parent

    def rollback(self) -> None:
        # Order matters: put the folders back, then the files (a reversed move
        # would otherwise overwrite a restored backup), then the backups on top
        # of whatever the half-finished apply wrote, then drop new folders.
        for removed in reversed(self.dirs_removed):
            try:
                removed.mkdir(parents=True, exist_ok=True)
            except OSError:
                pass
        for src, dst in reversed(self.moves_done):
            try:
                if dst.exists():
                    src.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(dst), str(src))
            except OSError:
                pass
        for original, backup in reversed(self.files_backed_up):
            try:
                original.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(backup, original)
            except OSError:
                pass
        for made in reversed(self.dirs_made):
            try:
                made.rmdir()
            except OSError:
                pass

    def discard(self) -> None:
        shutil.rmtree(self.backup_dir, ignore_errors=True)


def apply_plan(plan: Plan, new_contents: dict[str, tuple[str, str]]) -> None:
    project = plan.project
    journal = Journal(project)
    try:
        for _new_rel, (old_rel, _text) in sorted(new_contents.items()):
            existing = project / old_rel
            if existing.is_file():
                journal.backup(existing)
        emptied: list[Path] = []
        # Shallower destinations first. Moving `tiles/x.tres` -> `art/x.tres`
        # before `textures/` -> `art/` would create `art/` as a directory, and
        # `shutil.move` then puts the *folder* inside it (`art/textures/`).
        for move in sorted(plan.moves, key=lambda m: (m.dst_rel.count("/"), m.dst_rel)):
            pairs = move.file_pairs if move.kind == "file" else [(move.src_rel, move.dst_rel)]
            for src_rel, dst_rel in pairs:
                src = project / src_rel
                dst = project / dst_rel
                journal.makedirs(dst.parent)
                if dst.exists() and not move.case_only:
                    raise OSError(
                        f"{res_path(dst_rel)} appeared while the plan was being applied; "
                        f"refusing to overwrite it")
                if move.case_only:
                    # macOS folds case: rename through a unique temporary name.
                    staging = dst.parent / (dst.name + ".godot-move-tmp")
                    journal.move(src, staging)
                    journal.move(staging, dst)
                else:
                    journal.move(src, dst)
                emptied.append(src.parent)
        for rel, (_old_rel, text) in sorted(new_contents.items()):
            target = project / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, "w", encoding="utf-8", newline="") as handle:
                handle.write(text)
        for directory in emptied:
            journal.prune_empty(directory)
    except Exception as error:  # noqa: BLE001 - any I/O failure must roll back
        journal.rollback()
        journal.discard()
        raise MoveError(
            f"I/O failure while applying the move ({error}). "
            f"Everything was rolled back; the project is unchanged.") from error
    journal.discard()


# --------------------------------------------------------------------------
# verification
# --------------------------------------------------------------------------

def run_missing_resource_lint(project: Path) -> dict:
    """`lint_project.py --only missing_resource` as a subprocess: it is another
    tool's file, so only its CLI and JSON shape are relied on."""
    if not LINT_SCRIPT.is_file():
        return {"ran": False, "reason": f"{LINT_SCRIPT} not found", "diagnostics": []}
    try:
        result = subprocess.run(
            [sys.executable, str(LINT_SCRIPT), str(project), "--only", "missing_resource"],
            capture_output=True, text=True, check=False, timeout=180)
    except (OSError, subprocess.SubprocessError) as error:
        return {"ran": False, "reason": str(error), "diagnostics": []}
    try:
        payload = json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"ran": False, "reason": "lint_project.py produced no JSON",
                "stderr": result.stderr.strip()[-400:], "diagnostics": []}
    return {"ran": True, "diagnostics": payload.get("diagnostics", [])}


def diagnostic_key(entry: dict, plan: Optional[Plan] = None) -> tuple[str, str]:
    """`(file, message)`, with the file mapped through the plan so a diagnostic
    that merely followed its file to a new folder is not counted as new."""
    where = entry.get("file") or ""
    if plan is not None and where.startswith("res://"):
        where = res_path(plan.remap_rel_file(where[len("res://"):]))
    return where, entry.get("message", "")


def verify(before: dict, after: dict, plan: Optional[Plan] = None) -> dict:
    if not before.get("ran") or not after.get("ran"):
        reason = before.get("reason") or after.get("reason") or "unknown"
        return {"ran": False, "reason": reason, "missing_before": None,
                "missing_after": None, "new_missing": []}
    seen = {diagnostic_key(entry, plan) for entry in before["diagnostics"]}
    new = [entry for entry in after["diagnostics"] if diagnostic_key(entry) not in seen]
    return {
        "ran": True,
        "missing_before": len(before["diagnostics"]),
        "missing_after": len(after["diagnostics"]),
        "new_missing": [
            {"file": entry.get("file"), "line": entry.get("line"), "message": entry.get("message")}
            for entry in new
        ],
    }


# Verified on 4.7: `.godot/uid_cache.bin` still maps the moved uid to its old
# path until the importer runs, and an `[ext_resource]` that carries `uid=`
# resolves through that cache *before* its (already corrected) text path, so the
# scene fails with `Resource file not found: res://<old path>`. The re-import
# rewrites the cache and the failure disappears.
NO_IMPORT_NOTE = (
    "Run `godot --headless --path {project} --import` before running or exporting: "
    ".godot/uid_cache.bin still maps the moved uid to its old path, and an [ext_resource] "
    "with a uid= resolves through the cache first (4.7: 'Resource file not found: res://<old>')."
)


def find_godot() -> Optional[str]:
    candidate = os.environ.get("GODOT_BIN") or "godot"
    return shutil.which(candidate)


def run_import(project: Path, timeout: int = 300) -> dict:
    note = NO_IMPORT_NOTE.format(project=project)
    binary = find_godot()
    if binary is None:
        return {"ran": False, "returncode": None,
                "reason": "godot is not on PATH (set GODOT_BIN); run "
                          f"`godot --headless --path {project} --import` yourself.",
                "note": note}
    try:
        result = subprocess.run(
            [binary, "--headless", "--path", str(project), "--import"],
            capture_output=True, text=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"ran": False, "returncode": None,
                "reason": f"--import timed out after {timeout}s", "note": note}
    except OSError as error:
        return {"ran": False, "returncode": None, "reason": str(error), "note": note}
    return {"ran": True, "returncode": result.returncode}


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def load_map(path: str) -> list[tuple[str, str]]:
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise MoveError(f"--map file cannot be read: {error}") from None
    try:
        data = json.loads(raw)
    except ValueError as error:
        raise MoveError(f"--map file is not valid JSON: {error}") from None
    if not isinstance(data, list) or not data:
        raise MoveError('--map must be a non-empty JSON array of {"from": …, "to": …} objects.')
    pairs: list[tuple[str, str]] = []
    for index, entry in enumerate(data):
        if not isinstance(entry, dict) or "from" not in entry or "to" not in entry:
            raise MoveError(
                f'--map entry {index} must be an object with "from" and "to" keys; got {entry!r}.')
        pairs.append((entry["from"], entry["to"]))
    return pairs


def parse_extra_ext(raw: str) -> set[str]:
    out: set[str] = set()
    for item in raw.split(","):
        item = item.strip().lower()
        if not item:
            continue
        out.add(item if item.startswith(".") else "." + item)
    return out


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="move_resource.py",
        description="Move or rename Godot project files and rewrite every reference to them.")
    parser.add_argument("project_path", help="Godot project directory (the folder with project.godot).")
    parser.add_argument("src", nargs="?", help="File or folder to move (project-relative or res://).")
    parser.add_argument("dst", nargs="?",
                        help="New path, or an existing folder / trailing slash to move into.")
    parser.add_argument("--map", dest="map_file", default="",
                        help='JSON file: [{"from": "...", "to": "..."}, ...] applied as one atomic plan.')
    parser.add_argument("--dry-run", action="store_true",
                        help="Print the identical plan and touch nothing.")
    parser.add_argument("--no-import", action="store_true",
                        help="Skip the final `godot --headless --path PROJECT --import`.")
    parser.add_argument("--extra-ext", default="",
                        help="Extra file extensions to scan for references, e.g. .json,.md")
    parser.add_argument("--include-addons", action="store_true",
                        help="Also rewrite references inside addons/ (skipped by default).")
    parser.add_argument("--pretty", action="store_true", help="Indent the JSON output.")
    return parser


def run(argv: list[str]) -> tuple[dict, int]:
    args = build_parser().parse_args(argv)
    project = Path(args.project_path).expanduser()
    if not project.is_dir():
        return {"ok": False, "error": f"Project directory does not exist: {project}"}, 2
    if not (project / "project.godot").is_file():
        return {"ok": False,
                "error": f"{project} has no project.godot — that is not a Godot project root."}, 2
    project = project.resolve()

    if args.map_file:
        if args.src or args.dst:
            return {"ok": False,
                    "error": "Pass either SRC DST or --map FILE.json, not both."}, 2
        pairs = load_map(args.map_file)
    else:
        if not args.src or not args.dst:
            return {"ok": False,
                    "error": "SRC and DST are required (or use --map FILE.json). "
                             "Example: move_resource.py /abs/project art/player.png art/actors/"}, 2
        pairs = [(args.src, args.dst)]

    extra_ext = parse_extra_ext(args.extra_ext)
    plan = build_plan(project, pairs)
    edits, mentions, new_contents, references, warnings = plan_edits(
        plan, extra_ext=extra_ext, include_addons=args.include_addons)

    files_moved = sum(len(move.file_pairs) for move in plan.moves)
    payload = {
        "ok": True,
        "dry_run": bool(args.dry_run),
        "project": str(project),
        "moved": [move.report() for move in plan.moves],
        "edits": edits,
        "mentions": mentions,
        "warnings": warnings,
        "counts": {
            "files_moved": files_moved,
            "files_edited": len(new_contents),
            "references_rewritten": references,
        },
        "import": {"ran": False, "returncode": None},
        "verify": {"ran": False, "reason": "not run", "missing_before": None,
                   "missing_after": None, "new_missing": []},
    }

    if args.dry_run:
        payload["import"]["reason"] = "dry run"
        payload["verify"]["reason"] = "dry run"
        return payload, 0

    before = run_missing_resource_lint(project)
    apply_plan(plan, new_contents)

    if args.no_import:
        payload["import"] = {"ran": False, "returncode": None, "reason": "--no-import",
                             "note": NO_IMPORT_NOTE.format(project=project)}
    else:
        payload["import"] = run_import(project)

    after = run_missing_resource_lint(project)
    payload["verify"] = verify(before, after, plan)
    if payload["verify"]["new_missing"]:
        payload["ok"] = False
        payload["error"] = (
            f"{len(payload['verify']['new_missing'])} reference(s) broke. "
            f"The move was applied; fix them or move the files back.")
    return payload, 0 if payload["ok"] else 1


def main(argv: Optional[list[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    pretty = "--pretty" in argv
    try:
        payload, code = run(argv)
    except MoveError as error:
        payload, code = {"ok": False, "error": str(error)}, 2
    print(json.dumps(payload, indent=2 if pretty else None))
    if not payload.get("ok"):
        sys.stderr.write(str(payload.get("error", "move_resource failed")) + "\n")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
