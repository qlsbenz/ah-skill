#!/usr/bin/env python3
"""Look the Godot API up instead of remembering it.

The installed engine is asked for its own class reference
(``godot --headless --doctool <dir>``), the XML is cached per engine version,
and this tool answers three kinds of question against it:

* ``CharacterBody2D``            -> the class card (chain, properties, methods,
  signals, enums, theme items, one line per ancestor)
* ``CharacterBody2D.position``   -> one member, resolved through the inheritance
  chain, saying which ancestor declares it
* ``--search slide``             -> ranked name matches across every class and
  member

Variant types (``String``, ``Array``, ``Vector2`` ...), ``@GlobalScope`` and
``@GDScript`` are ordinary classes here, so ``String.begins_with``, ``KEY_SPACE``
and a bare ``lerp`` resolve too. ``--project`` adds the project's own
``class_name`` scripts.

The doctool XML carries full signatures but **no prose descriptions**, so this is
an anti-hallucination check ("does this method exist, and what exactly does it
take"), not a replacement for the online manual.

Exit codes: 0 every query answered, 1 something was not found, 2 usage error or
the engine could not be run.

stdlib only, Python 3.9+.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

SECTIONS: Tuple[Tuple[str, str], ...] = (
    ("methods", "method"),
    ("members", "member"),
    ("signals", "signal"),
    ("constants", "constant"),
    ("theme_items", "theme_item"),
    ("operators", "operator"),
    ("constructors", "constructor"),
    ("annotations", "annotation"),
)

# What a caller may write after --kind. "properties" is the GDScript word for
# what the XML calls "members"; "enums" is a view over the constants that carry
# an enum= attribute, and "constants" then means the ones that do not.
KIND_ALIASES: Dict[str, str] = {
    "method": "methods", "methods": "methods", "function": "methods", "functions": "methods",
    "property": "members", "properties": "members", "member": "members", "members": "members",
    "signal": "signals", "signals": "signals",
    "constant": "constants", "constants": "constants",
    "enum": "enums", "enums": "enums",
    "theme_item": "theme_items", "theme_items": "theme_items", "theme": "theme_items",
    "operator": "operators", "operators": "operators",
    "constructor": "constructors", "constructors": "constructors",
    "annotation": "annotations", "annotations": "annotations",
}
KIND_ORDER: Tuple[str, ...] = (
    "members", "methods", "signals", "enums", "constants",
    "theme_items", "constructors", "operators", "annotations",
)
KIND_LABEL: Dict[str, str] = {
    "members": "properties", "methods": "methods", "signals": "signals",
    "enums": "enums", "constants": "constants", "theme_items": "theme items",
    "constructors": "constructors", "operators": "operators", "annotations": "annotations",
}
# Singular noun used when one member is printed.
KIND_SINGULAR: Dict[str, str] = {
    "members": "property", "methods": "method", "signals": "signal", "enums": "enum",
    "constants": "constant", "theme_items": "theme item",
    "constructors": "constructor", "operators": "operator", "annotations": "annotation",
}

THEME_OVERRIDE_METHOD: Dict[str, str] = {
    "color": "add_theme_color_override",
    "constant": "add_theme_constant_override",
    "font": "add_theme_font_override",
    "font_size": "add_theme_font_size_override",
    "icon": "add_theme_icon_override",
    "style": "add_theme_stylebox_override",
}

# Used only when scripts/debug/lint_project.py cannot be imported (it owns the
# full Godot 3 -> 4 rename table; this is the "never silently lose the hint" set).
FALLBACK_GODOT3: Dict[str, str] = {
    "KinematicBody2D": "CharacterBody2D",
    "KinematicBody": "CharacterBody3D",
    "Spatial": "Node3D",
    "Sprite": "Sprite2D",
    "AnimatedSprite": "AnimatedSprite2D",
    "Position2D": "Marker2D",
    "Position3D": "Marker3D",
    "Area": "Area3D",
    "RigidBody": "RigidBody3D",
    "StaticBody": "StaticBody3D",
    "CollisionShape": "CollisionShape3D",
    "MeshInstance": "MeshInstance3D",
    "Camera": "Camera3D",
    "Light": "Light3D",
    "OmniLight": "OmniLight3D",
    "SpotLight": "SpotLight3D",
    "DirectionalLight": "DirectionalLight3D",
    "Particles": "GPUParticles3D",
    "Particles2D": "GPUParticles2D",
    "Reference": "RefCounted",
    "Directory": "DirAccess",
    "File": "FileAccess",
    "YSort": "Node2D with y_sort_enabled = true",
    "Navigation2D": "NavigationRegion2D",
    "rect_position": "position",
    "rect_size": "size",
    "rect_min_size": "custom_minimum_size",
    "instance": "instantiate",
    "empty": "is_empty",
    "deg2rad": "deg_to_rad",
    "rad2deg": "rad_to_deg",
    "stepify": "snapped",
    "linear_interpolate": "lerp",
}


# --------------------------------------------------------------------------- #
# engine + cache
# --------------------------------------------------------------------------- #

class LookupError_(Exception):
    """Usage / environment failure: printed as an error, exit code 2."""


def resolve_binary(explicit: Optional[str]) -> Optional[str]:
    candidate = explicit or os.environ.get("GODOT_BIN") or "godot"
    found = shutil.which(candidate)
    if found:
        return found
    path = Path(candidate).expanduser()
    if path.is_file() and os.access(str(path), os.X_OK):
        return str(path.resolve())
    return None


def engine_version(binary: str) -> str:
    try:
        result = subprocess.run([binary, "--version"], capture_output=True, text=True,
                                check=False, timeout=60)
    except OSError as error:
        raise LookupError_("could not run %s --version: %s" % (binary, error))
    for line in (result.stdout or "").splitlines():
        line = line.strip()
        if line:
            return line
    raise LookupError_(
        "%s --version printed nothing (exit %d). Point --godot at a Godot 4.x binary."
        % (binary, result.returncode))


def version_slug(version: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", version).strip("_") or "unknown"


def cache_base(explicit: Optional[str]) -> Path:
    if explicit:
        return Path(explicit).expanduser()
    env = os.environ.get("GODOT_SKILL_CACHE")
    if env:
        return Path(env).expanduser()
    return Path.home() / ".cache" / "godot-skill"


def _writable(directory: Path) -> bool:
    try:
        directory.mkdir(parents=True, exist_ok=True)
    except OSError:
        return False
    try:
        probe = directory / ".write-probe"
        probe.write_text("x", encoding="utf-8")
        probe.unlink()
        return True
    except OSError:
        return False


# --------------------------------------------------------------------------- #
# index building
# --------------------------------------------------------------------------- #

def build_index(xml_root: Path, version: str, binary: Optional[str]) -> dict:
    classes: Dict[str, dict] = {}
    for path in sorted(xml_root.rglob("*.xml")):
        entry = _index_one(path, xml_root)
        if entry is not None:
            classes[entry[0]] = entry[1]
    return {"version": version, "godot_binary": binary or "", "classes": classes}


def _index_one(path: Path, xml_root: Path) -> Optional[Tuple[str, dict]]:
    try:
        root = ET.parse(str(path)).getroot()
    except ET.ParseError:
        return None
    if root.tag != "class":
        return None
    name = root.get("name") or ""
    if not name:
        return None
    entry: Dict[str, object] = {
        "file": path.relative_to(xml_root).as_posix(),
        "inherits": root.get("inherits", "") or "",
    }
    api = root.get("api_type") or ""
    if api:
        entry["api"] = api
    for section, tag in SECTIONS:
        container = root.find(section)
        if container is None:
            continue
        names = [element.get("name", "") for element in container.findall(tag)]
        names = [value for value in names if value]
        if names:
            # Operators repeat the same name once per overload; the index only
            # needs the distinct names for searching.
            entry[section] = sorted(set(names)) if section == "operators" else names
    return name, entry


def run_doctool(binary: str, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    command = [binary, "--headless", "--doctool", str(target.resolve()), "--quit"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False,
                                timeout=300, cwd=str(target.resolve()))
    except OSError as error:
        raise LookupError_("could not run %s: %s" % (" ".join(command), error))
    produced = any(target.rglob("*.xml"))
    if not produced:
        raise LookupError_(
            "%s produced no XML (exit %d).\n%s\nRun it by hand to see why; --godot must point at a Godot 4.x binary."
            % (" ".join(command), result.returncode, (result.stderr or result.stdout or "").strip()[:2000]))


def project_docs(binary: str, project: Path) -> Tuple[Dict[str, dict], Path, List[str]]:
    """Index the project's own `class_name` scripts via --gdscript-docs.

    Returns (classes, xml_root, notes). The XML tree lives in a temp directory
    owned by the caller's process; it is regenerated on every run because
    project scripts change far more often than the engine does.
    """
    notes: List[str] = []
    if not (project / "project.godot").is_file():
        raise LookupError_("--project %s has no project.godot" % project)
    target = Path(tempfile.mkdtemp(prefix="godot-skill-api-project-"))
    command = [binary, "--headless", "--path", str(project.resolve()),
               "--doctool", str(target), "--gdscript-docs", "res://", "--quit"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=300)
    except OSError as error:
        raise LookupError_("could not run %s: %s" % (" ".join(command), error))
    broken = [line.strip() for line in (result.stderr or "").splitlines()
              if "SCRIPT ERROR" in line or "Failed to load script" in line]
    if broken:
        notes.append("project scripts did not all compile, so some class_name types are missing: "
                     + "; ".join(broken[:4]))
    classes: Dict[str, dict] = {}
    for path in sorted(target.rglob("*.xml")):
        entry = _index_one(path, target)
        if entry is None:
            continue
        # A script with `class_name X` is documented as X; one without is
        # documented as "scripts/player.gd" — quotes included — so it is indexed
        # under its res:// path instead and stays addressable.
        name = entry[0].strip('"')
        data = entry[1]
        data["source"] = "project"
        if name.endswith(".gd") or "/" in name:
            name = name if name.startswith("res://") else "res://" + name.lstrip("/")
            data["script_path"] = name
        classes[name] = data
    if not classes:
        notes.append("no scripts were documented in %s. Every .gd file that compiles should "
                     "appear; run `godot --headless --path %s --import` once if the scripts "
                     "were just written." % (project, project))
    return classes, target, notes


# --------------------------------------------------------------------------- #
# the database
# --------------------------------------------------------------------------- #

class ApiDb:
    def __init__(self, index: dict, xml_root: Path) -> None:
        self.version: str = str(index.get("version", ""))
        self.classes: Dict[str, dict] = dict(index.get("classes", {}))
        self.roots: Dict[str, Path] = {name: xml_root for name in self.classes}
        self._lower = {name.lower(): name for name in self.classes}
        self._detail_cache: Dict[str, dict] = {}
        self.notes: List[str] = []

    def add_project(self, classes: Dict[str, dict], xml_root: Path) -> None:
        for name, entry in classes.items():
            if name in self.classes:
                self.notes.append(
                    "project class %s shadows an engine class of the same name; the engine one is shown"
                    % name)
                continue
            self.classes[name] = entry
            self.roots[name] = xml_root
            self._lower[name.lower()] = name
            # A script indexed by path answers to every spelling of that path.
            if name.startswith("res://"):
                relative = name[len("res://"):]
                self._lower.setdefault(relative.lower(), name)
                self._lower.setdefault(relative.rsplit("/", 1)[-1].lower(), name)

    # -- names ------------------------------------------------------------- #

    def resolve_class(self, name: str) -> Optional[str]:
        if name in self.classes:
            return name
        return self._lower.get(name.lower())

    def chain(self, name: str) -> List[str]:
        chain: List[str] = []
        current: Optional[str] = name
        seen = set()
        while current and current in self.classes and current not in seen:
            seen.add(current)
            chain.append(current)
            current = str(self.classes[current].get("inherits", "")) or None
        return chain

    def detail(self, name: str) -> dict:
        cached = self._detail_cache.get(name)
        if cached is not None:
            return cached
        entry = self.classes[name]
        path = self.roots[name] / str(entry["file"])
        try:
            detail = parse_class_xml(path)
        except (OSError, ET.ParseError):
            # The index survived but its XML did not (a half-deleted cache).
            self.notes.append("%s is missing from the cache at %s; re-run with --refresh" % (name, path))
            detail = {"name": name, "inherits": str(entry.get("inherits", "")), "api": "",
                      "enums": {}, "enum_bitfields": {}, "all_constants": []}
            for section, _tag in SECTIONS:
                detail[section] = []
        self._detail_cache[name] = detail
        return detail

    # -- members ------------------------------------------------------------ #

    def find_member(self, class_name: str, member: str) -> Optional[dict]:
        """Walk the inheritance chain for `member`, returning the declaration.

        A subclass that only re-defaults an inherited property (the XML's
        `overrides` attribute) is recorded but is not the declaration.
        """
        override: Optional[dict] = None
        for owner in self.chain(class_name):
            detail = self.detail(owner)
            for kind in ("members", "methods", "signals", "constants",
                         "theme_items", "annotations", "constructors"):
                # "constants" in the parsed detail holds only the enum-less ones;
                # a lookup has to see every constant, enum member or not.
                bucket = "all_constants" if kind == "constants" else kind
                for item in detail.get(bucket, []):
                    if item.get("name") != member:
                        continue
                    if kind == "members" and item.get("overrides"):
                        if override is None:
                            override = {"class": owner, "default": item.get("default")}
                        continue
                    return {"kind": kind, "declared_in": owner, "item": item, "override": override}
            for item in detail.get("operators", []):
                if item.get("name") == member:
                    return {"kind": "operators", "declared_in": owner, "item": item, "override": None}
        # An enum name is not a constant, but `Control.SizeFlags` should answer.
        for owner in self.chain(class_name):
            enums = self.detail(owner).get("enums", {})
            if member in enums:
                return {"kind": "enums", "declared_in": owner,
                        "item": {"name": member, "values": enums[member]}, "override": None}
        return None

    def member_names(self, class_name: str) -> List[str]:
        names: List[str] = []
        for owner in self.chain(class_name):
            entry = self.classes[owner]
            for section, _tag in SECTIONS:
                names.extend(str(value) for value in entry.get(section, []))
        return names

    def classes_declaring(self, member: str) -> List[Tuple[str, str]]:
        """[(class, section)] for every class whose index lists `member`."""
        hits: List[Tuple[str, str]] = []
        for name, entry in self.classes.items():
            for section, _tag in SECTIONS:
                values = entry.get(section)
                if values and member in values:
                    hits.append((name, section))
                    break
        hits.sort()
        return hits


def parse_class_xml(path: Path) -> dict:
    root = ET.parse(str(path)).getroot()
    detail: Dict[str, object] = {
        "name": root.get("name", ""),
        "inherits": root.get("inherits", "") or "",
        "api": root.get("api_type", "") or "",
    }
    for section, tag in SECTIONS:
        container = root.find(section)
        items: List[dict] = []
        if container is not None:
            for element in container.findall(tag):
                items.append(_element_to_dict(element, tag))
        detail[section] = items
    # Group enum constants; the leftovers stay in "constants". `all_constants`
    # keeps every one of them, because `Control.SIZE_EXPAND_FILL` must resolve
    # even though it only appears inside the SizeFlags enum.
    enums: Dict[str, List[dict]] = {}
    plain: List[dict] = []
    bitfields: Dict[str, bool] = {}
    for constant in detail["constants"]:  # type: ignore[index]
        enum_name = constant.get("enum")
        if enum_name:
            enums.setdefault(enum_name, []).append(constant)
            if constant.get("is_bitfield"):
                bitfields[enum_name] = True
        else:
            plain.append(constant)
    detail["all_constants"] = list(detail["constants"])  # type: ignore[arg-type]
    detail["enums"] = enums
    detail["enum_bitfields"] = bitfields
    detail["constants"] = plain
    return detail


def _element_to_dict(element: ET.Element, tag: str) -> dict:
    item: Dict[str, object] = {"name": element.get("name", "")}
    for attribute in ("type", "default", "setter", "getter", "enum", "data_type",
                      "qualifiers", "overrides", "value"):
        value = element.get(attribute)
        if value is not None:
            item[attribute] = value
    if element.get("is_bitfield") == "true":
        item["is_bitfield"] = True
    params: List[dict] = []
    for param in element.findall("param"):
        params.append({
            "name": param.get("name", ""),
            "type": param.get("enum") or param.get("type", ""),
            "enum": param.get("enum"),
            "default": param.get("default"),
        })
    if tag in ("method", "signal", "operator", "constructor", "annotation"):
        item["params"] = params
        returns = element.find("return")
        if returns is not None:
            item["return"] = returns.get("enum") or returns.get("type", "void")
        else:
            item["return"] = "void" if tag != "signal" else ""
    return item


# --------------------------------------------------------------------------- #
# rendering
# --------------------------------------------------------------------------- #

def enum_constant_name(db: Optional["ApiDb"], owner: str, enum_ref: Optional[str],
                       value: Optional[str]) -> str:
    """`0` -> `MOTION_MODE_GROUNDED`, when the XML says which enum the value is in."""
    if db is None or not enum_ref or value is None:
        return ""
    holder, short = (enum_ref.split(".", 1) if "." in enum_ref else (owner, enum_ref))
    for candidate in (holder, owner, "@GlobalScope"):
        resolved = db.resolve_class(candidate) if candidate else None
        if not resolved:
            continue
        constants = db.detail(resolved).get("enums", {}).get(short)
        if not constants:
            continue
        for constant in constants:
            if str(constant.get("value")) == str(value):
                return str(constant.get("name", ""))
        return ""
    return ""


def render_signature(item: dict, kind: str, db: Optional["ApiDb"] = None, owner: str = "") -> str:
    name = str(item.get("name", ""))
    if kind in ("methods", "signals", "operators", "constructors", "annotations"):
        qualifiers = [part for part in str(item.get("qualifiers", "")).split() if part]
        parts = []
        for param in item.get("params", []):
            text = "%s: %s" % (param["name"], param["type"])
            if param.get("default") is not None:
                text += " = %s" % param["default"]
                label = enum_constant_name(db, owner, param.get("enum"), param.get("default"))
                if label:
                    text += " (%s)" % label
            parts.append(text)
        if "vararg" in qualifiers:
            parts.append("...")
        signature = "%s(%s)" % (name, ", ".join(parts))
        return_type = str(item.get("return", ""))
        if kind != "signals" and return_type:
            signature += " -> %s" % return_type
        tags = [part for part in qualifiers if part != "vararg"]
        if "vararg" in qualifiers:
            tags.append("vararg")
        if tags:
            signature += " [%s]" % " ".join(tags)
        return signature
    if kind == "members":
        type_name = item.get("enum") or item.get("type", "Variant")
        signature = "%s: %s" % (name, type_name)
        if item.get("default") is not None:
            signature += " = %s" % item["default"]
            label = enum_constant_name(db, owner, item.get("enum"), item.get("default"))
            if label:
                signature += " (%s)" % label
        if item.get("overrides"):
            signature += "  [default overridden here; declared on %s]" % item["overrides"]
        return signature
    if kind == "constants":
        signature = "%s = %s" % (name, item.get("value", "?"))
        if item.get("enum"):
            signature += "  [enum %s%s]" % (item["enum"], ", bitfield" if item.get("is_bitfield") else "")
        return signature
    if kind == "theme_items":
        signature = "%s: %s [%s]" % (name, item.get("type", "?"), item.get("data_type", "?"))
        if item.get("default") is not None:
            signature += " = %s" % item["default"]
        return signature
    return name


# Key has ~200 members; printing it inline would swamp every lookup that
# happens to touch it. A direct query for the enum itself (api_lookup.py
# @GlobalScope.Key) passes limit=None and gets the whole list.
ENUM_INLINE_LIMIT = 12


def render_enum(enum_name: str, constants: Sequence[dict], bitfield: bool,
                limit: Optional[int] = None, more: str = "") -> str:
    shown = list(constants) if limit is None else list(constants)[:limit]
    values = ", ".join("%s = %s" % (constant["name"], constant.get("value", "?"))
                       for constant in shown)
    if len(shown) < len(constants):
        values += ", ... +%d more%s" % (len(constants) - len(shown), (" (%s)" % more) if more else "")
    return "%s%s: %s" % (enum_name, " (bitfield)" if bitfield else "", values)


def class_card_text(db: ApiDb, class_name: str, kinds: Optional[Sequence[str]],
                    inherited: bool) -> List[str]:
    chain = db.chain(class_name)
    lines: List[str] = [" < ".join(chain)]
    entry = db.classes[class_name]
    if entry.get("source") == "project":
        lines[0] += "   [project script]" if entry.get("script_path") else "   [project class_name]"
    lines.extend(_sections_text(db, class_name, kinds, indent="  "))
    ancestors = chain[1:]
    if not ancestors:
        return lines
    if inherited:
        for ancestor in ancestors:
            body = _sections_text(db, ancestor, kinds, indent="  ")
            if not body:
                continue
            lines.append("--- inherited from %s" % ancestor)
            lines.extend(body)
        return lines
    summary: List[str] = []
    for ancestor in ancestors:
        counts = _counts(db, ancestor, kinds)
        if not counts:
            continue
        summary.append("  %-22s %-46s api_lookup.py %s" % (ancestor, counts, ancestor))
    if summary:
        lines.append("inherited (add --inherited to expand, or look one member up directly):")
        lines.extend(summary)
    return lines


def _counts(db: ApiDb, class_name: str, kinds: Optional[Sequence[str]]) -> str:
    detail = db.detail(class_name)
    parts: List[str] = []
    for kind in KIND_ORDER:
        if kinds and kind not in kinds:
            continue
        if kind == "enums":
            count = len(detail.get("enums", {}))
        else:
            count = len(detail.get(kind, []))
        if count:
            label = KIND_LABEL[kind] if count != 1 else KIND_SINGULAR.get(kind, KIND_LABEL[kind])
            parts.append("%d %s" % (count, label))
    return ", ".join(parts)


def _sections_text(db: ApiDb, class_name: str, kinds: Optional[Sequence[str]],
                   indent: str) -> List[str]:
    detail = db.detail(class_name)
    lines: List[str] = []
    for kind in KIND_ORDER:
        if kinds and kind not in kinds:
            continue
        if kind == "enums":
            enums = detail.get("enums", {})
            if not enums:
                continue
            lines.append("enums (%d)" % len(enums))
            for enum_name in sorted(enums):
                lines.append(indent + render_enum(
                    enum_name, enums[enum_name],
                    bool(detail.get("enum_bitfields", {}).get(enum_name)),
                    ENUM_INLINE_LIMIT, "api_lookup.py %s.%s" % (class_name, enum_name)))
            continue
        items = detail.get(kind, [])
        if not items:
            continue
        lines.append("%s (%d)" % (KIND_LABEL[kind], len(items)))
        for item in items:
            lines.append(indent + render_signature(item, kind, db, class_name))
    return lines


def member_card_text(db: ApiDb, query_class: str, found: dict) -> List[str]:
    kind = found["kind"]
    owner = found["declared_in"]
    item = found["item"]
    if kind == "enums":
        detail = db.detail(owner)
        bitfield = bool(detail.get("enum_bitfields", {}).get(item["name"]))
        lines = ["%s.%s  (enum)" % (owner, item["name"]),
                 "  " + render_enum(item["name"], item["values"], bitfield)]
    else:
        lines = ["%s.%s  (%s)" % (owner, item.get("name", ""), KIND_SINGULAR.get(kind, kind)),
                 "  " + render_signature(item, kind, db, owner)]
    if owner != query_class:
        lines.append("  inherited: %s" % " < ".join(db.chain(query_class)[:db.chain(query_class).index(owner) + 1]))
    if found.get("override"):
        lines.append("  %s overrides the default to %s" % (found["override"]["class"],
                                                           found["override"]["default"]))
    lines.extend(_usage_hints(db, query_class, owner, kind, item))
    return lines


def _usage_hints(db: ApiDb, query_class: str, owner: str, kind: str, item: dict) -> List[str]:
    hints: List[str] = []
    if kind == "members":
        setter = item.get("setter")
        getter = item.get("getter")
        if setter or getter:
            hints.append("  setter %s / getter %s" % (setter or "-", getter or "-"))
        enum_name = item.get("enum")
        if enum_name:
            hints.extend(_enum_value_lines(db, owner, str(enum_name)))
    elif kind == "signals":
        handler = "_on_" + str(item.get("name", "signal"))
        params = ", ".join("%s: %s" % (param["name"], param["type"]) for param in item.get("params", []))
        hints.append("  connect: node.%s.connect(%s)" % (item.get("name"), handler))
        hints.append("  handler: func %s(%s) -> void:" % (handler, params))
    elif kind == "constants":
        enum_name = item.get("enum")
        if enum_name:
            hints.extend(_enum_value_lines(db, owner, str(enum_name)))
    elif kind == "theme_items":
        method = THEME_OVERRIDE_METHOD.get(str(item.get("data_type", "")))
        if method:
            hints.append("  per-node override: node.%s(\"%s\", <%s>)"
                         % (method, item.get("name"), item.get("type")))
            hints.append("  project-wide: build_theme with {\"type\":\"%s\",\"%s\":{\"%s\":...}}"
                         % (query_class, item.get("data_type"), item.get("name")))
    return hints


def _enum_value_lines(db: ApiDb, owner: str, enum_name: str) -> List[str]:
    """`Node.ProcessMode` may be declared on `owner` or on @GlobalScope."""
    holder, short = (enum_name.split(".", 1) if "." in enum_name else (owner, enum_name))
    for candidate in (holder, owner, "@GlobalScope"):
        resolved = db.resolve_class(candidate)
        if not resolved:
            continue
        enums = db.detail(resolved).get("enums", {})
        if short in enums:
            bitfield = bool(db.detail(resolved).get("enum_bitfields", {}).get(short))
            return ["  values: " + render_enum(short, enums[short], bitfield, ENUM_INLINE_LIMIT,
                                               "api_lookup.py %s.%s" % (resolved, short))]
    return []


# --------------------------------------------------------------------------- #
# search + suggestions
# --------------------------------------------------------------------------- #

def rank(text: str, needle: str) -> Optional[int]:
    """0 exact, 1 whole word, 2 prefix, 3 substring, None no match.

    The whole-word tier is what makes `--search slide` answer with
    `move_and_slide` before the 30 `SLIDER_JOINT_*` constants, which are only
    prefix matches of a longer word.
    """
    lowered = text.lower()
    if lowered == needle:
        return 0
    if needle not in lowered:
        return None
    if needle in [part for part in re.split(r"[^a-z0-9]+", lowered) if part]:
        return 1
    if lowered.startswith(needle):
        return 2
    return 3


def search(db: ApiDb, needle: str, limit: int) -> Tuple[List[dict], int]:
    needle = needle.lower()
    hits: List[Tuple[int, int, str, str, dict]] = []
    for class_name, entry in db.classes.items():
        score = rank(class_name, needle)
        if score is not None:
            hits.append((score, len(class_name), class_name, class_name,
                         {"kind": "class", "class": class_name, "name": class_name}))
        for section, _tag in SECTIONS:
            for member in entry.get(section, []):
                member_score = rank(str(member), needle)
                if member_score is None:
                    continue
                hits.append((member_score, len(str(member)), str(member),
                             "%s.%s" % (class_name, member),
                             {"kind": section, "class": class_name, "name": str(member)}))
    hits.sort(key=lambda row: (row[0], row[1], row[3]))
    total = len(hits)
    results = []
    for row in hits[:limit]:
        results.append(_describe_hit(db, row[4]))
    return results, total


def _describe_hit(db: ApiDb, payload: dict) -> dict:
    class_name = payload["class"]
    if payload["kind"] == "class":
        chain = db.chain(class_name)
        return {"kind": "class", "class": class_name, "name": class_name,
                "signature": " < ".join(chain)}
    detail = db.detail(class_name)
    bucket = "all_constants" if payload["kind"] == "constants" else payload["kind"]
    for item in detail.get(bucket, []):
        if item.get("name") == payload["name"]:
            return {"kind": payload["kind"], "class": class_name, "name": payload["name"],
                    "signature": "%s.%s" % (class_name,
                                            render_signature(item, payload["kind"], db, class_name))}
    return {"kind": payload["kind"], "class": class_name, "name": payload["name"],
            "signature": "%s.%s" % (class_name, payload["name"])}


def nearest(name: str, candidates: Sequence[str], limit: int = 5) -> List[str]:
    exact = difflib.get_close_matches(name, list(candidates), n=limit, cutoff=0.7)
    if exact:
        return exact
    return difflib.get_close_matches(name, list(candidates), n=limit, cutoff=0.5)


def godot3_replacements() -> Dict[str, str]:
    """The Godot 3 -> 4 rename table, borrowed from the linter when readable.

    lint_project.py is owned by another work package and may be mid-edit, so the
    import is guarded and falls back to a built-in subset rather than losing the
    hint entirely.
    """
    table = dict(FALLBACK_GODOT3)
    try:
        import contextlib
        import importlib.util
        import io
        source = Path(__file__).resolve().parents[1] / "debug" / "lint_project.py"
        spec = importlib.util.spec_from_file_location("_godot_skill_lint_for_api", str(source))
        if spec is None or spec.loader is None:
            return table
        module = importlib.util.module_from_spec(spec)
        # Importing runs the linter's module-level code; whatever it decides to
        # print must not land in the middle of a lookup's output.
        with contextlib.redirect_stdout(io.StringIO()):
            spec.loader.exec_module(module)
        for rule in getattr(module, "GODOT3_RULES", []):
            replacement = str(rule.get("replacement", "")).strip()
            if not replacement:
                continue
            identifier = rule.get("identifier")
            if identifier:
                table[str(identifier)] = replacement
                continue
            token = str(rule.get("token", "")).strip()
            bare = token.strip(".()").strip()
            if re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", bare):
                table.setdefault(bare, replacement.strip(".()"))
    except (Exception, SystemExit):  # noqa: BLE001 - a broken linter must never break lookups
        pass
    return table


# --------------------------------------------------------------------------- #
# query handling
# --------------------------------------------------------------------------- #

SCRIPT_QUERY = re.compile(r"^((?:res://)?[A-Za-z0-9_./\- ]+\.gd)(?:\.([A-Za-z_][A-Za-z_0-9]*))?$")


def split_query(raw: str) -> Tuple[Optional[str], str]:
    text = raw.strip()
    if text.endswith("()"):
        text = text[:-2]
    text = text.replace("::", ".")
    # A project script with no class_name is addressed by path, which is full of
    # dots and slashes: res://scripts/player.gd, or res://scripts/player.gd.jump.
    script = SCRIPT_QUERY.match(text)
    if script:
        return (script.group(1), script.group(2)) if script.group(2) else (None, script.group(1))
    if "." in text:
        head, tail = text.split(".", 1)
        return head, tail
    return None, text


def answer(db: ApiDb, raw: str, kinds: Optional[Sequence[str]], inherited: bool,
           renames: Dict[str, str]) -> dict:
    head, tail = split_query(raw)
    if head is None:
        return _answer_bare(db, raw, tail, kinds, inherited, renames)
    class_name = db.resolve_class(head)
    if class_name is None:
        return _not_found_class(db, raw, head, renames)
    if "." in tail:
        # Control.SizeFlags.SIZE_FILL -> the constant, not the enum.
        tail = tail.rsplit(".", 1)[-1]
    found = db.find_member(class_name, tail)
    if found is None:
        return _not_found_member(db, raw, class_name, tail, renames)
    return {"query": raw, "found": True, "type": "member", "class": class_name,
            "declared_in": found["declared_in"], "kind": found["kind"],
            "inherited": found["declared_in"] != class_name,
            "text": member_card_text(db, class_name, found),
            "member": _member_json(db, found)}


def _member_json(db: ApiDb, found: dict) -> dict:
    kind = found["kind"]
    item = dict(found["item"])
    if kind == "enums":
        return {"name": item["name"], "kind": "enum",
                "values": [{"name": constant["name"], "value": constant.get("value")}
                           for constant in item["values"]],
                "signature": render_enum(item["name"], item["values"], False)}
    item["signature"] = render_signature(found["item"], kind, db, found["declared_in"])
    return item


def _answer_bare(db: ApiDb, raw: str, name: str, kinds: Optional[Sequence[str]],
                 inherited: bool, renames: Dict[str, str]) -> dict:
    class_name = db.resolve_class(name)
    if class_name is not None:
        return {"query": raw, "found": True, "type": "class", "class": class_name,
                "inherits": db.chain(class_name)[1:],
                "text": class_card_text(db, class_name, kinds, inherited),
                "sections": _class_json(db, class_name, kinds)}
    for global_class in ("@GlobalScope", "@GDScript"):
        if db.resolve_class(global_class) is None:
            continue
        found = db.find_member(global_class, name)
        if found is not None:
            return {"query": raw, "found": True, "type": "member", "class": global_class,
                    "declared_in": found["declared_in"], "kind": found["kind"],
                    "inherited": False,
                    "text": member_card_text(db, global_class, found),
                    "member": _member_json(db, found)}
    hits = db.classes_declaring(name)
    if hits:
        lines = ["%s is not a class or a global; %d class%s declare it:"
                 % (name, len(hits), "" if len(hits) == 1 else "es")]
        for class_name_hit, section in hits[:10]:
            detail = db.detail(class_name_hit)
            signature = name
            bucket = "all_constants" if section == "constants" else section
            for item in detail.get(bucket, []):
                if item.get("name") == name:
                    signature = render_signature(item, section, db, class_name_hit)
                    break
            lines.append("  %s.%s" % (class_name_hit, signature))
        if len(hits) > 10:
            lines.append("  ... %d more; run: api_lookup.py --search %s" % (len(hits) - 10, name))
        return {"query": raw, "found": True, "type": "candidates",
                "candidates": ["%s.%s" % (class_name_hit, name) for class_name_hit, _ in hits],
                "text": lines}
    return _not_found_class(db, raw, name, renames)


def _class_json(db: ApiDb, class_name: str, kinds: Optional[Sequence[str]]) -> dict:
    detail = db.detail(class_name)
    payload: Dict[str, object] = {}
    for kind in KIND_ORDER:
        if kinds and kind not in kinds:
            continue
        if kind == "enums":
            enums = detail.get("enums", {})
            if enums:
                payload["enums"] = {
                    enum_name: [{"name": constant["name"], "value": constant.get("value")}
                                for constant in constants]
                    for enum_name, constants in enums.items()}
            continue
        items = detail.get(kind, [])
        if not items:
            continue
        payload[kind] = [dict(item, signature=render_signature(item, kind, db, class_name))
                         for item in items]
    return payload


def _rename_hint(name: str, renames: Dict[str, str], db: ApiDb) -> List[str]:
    replacement = renames.get(name)
    if not replacement:
        return []
    lines = ["  `%s` is a Godot 3 name. In Godot 4.x use `%s`." % (name, replacement)]
    target = replacement.split()[0]
    if db.resolve_class(target):
        lines.append("  run: api_lookup.py %s" % target)
    return lines


def _not_found_class(db: ApiDb, raw: str, name: str, renames: Dict[str, str]) -> dict:
    lines = ["%s: no such class in Godot %s." % (name, db.version)]
    hint = _rename_hint(name, renames, db)
    suggestions = nearest(name, list(db.classes))
    if hint:
        # The rename IS the answer; "nearest names" behind it is noise.
        lines.extend(hint)
    elif suggestions:
        lines.append("  nearest class names: " + ", ".join(suggestions))
    if not hint and not suggestions:
        lines.append("  run: api_lookup.py --search %s" % name)
    return {"query": raw, "found": False, "type": "class", "name": name,
            "suggestions": suggestions,
            "godot3_replacement": renames.get(name, ""), "text": lines}


def _not_found_member(db: ApiDb, raw: str, class_name: str, member: str,
                      renames: Dict[str, str]) -> dict:
    candidates = db.member_names(class_name)
    suggestions = nearest(member, candidates)
    lines = ["%s.%s: %s has no member `%s` (chain: %s)."
             % (class_name, member, class_name, member, " < ".join(db.chain(class_name)))]
    lines.extend(_rename_hint(member, renames, db))
    if suggestions:
        lines.append("  nearest members on that chain: " + ", ".join(suggestions))
    else:
        lines.append("  run: api_lookup.py %s   (to list what it does have)" % class_name)
    return {"query": raw, "found": False, "type": "member", "class": class_name,
            "name": member, "suggestions": suggestions,
            "godot3_replacement": renames.get(member, ""), "text": lines}


# --------------------------------------------------------------------------- #
# cache orchestration
# --------------------------------------------------------------------------- #

def load_db(args: argparse.Namespace) -> Tuple[ApiDb, List[str], List[Path]]:
    notes: List[str] = []
    temporaries: List[Path] = []
    binary = resolve_binary(args.godot)
    base = cache_base(args.cache_dir)
    api_root = base / "api"

    named = args.godot or os.environ.get("GODOT_BIN")
    if binary is None and named:
        # An explicitly named binary that cannot be run is a mistake to report,
        # not a reason to quietly answer from some other version's cache.
        raise LookupError_(
            "%s is not an executable Godot binary (%s). Fix the path, or drop it to use "
            "`godot` from PATH." % (named, "--godot" if args.godot else "$GODOT_BIN"))

    if binary is None:
        cached = sorted((path for path in api_root.glob("*/index.json")),
                        key=lambda path: path.stat().st_mtime, reverse=True) \
            if api_root.is_dir() else []
        if not cached:
            raise LookupError_(
                "no Godot binary (%s) and no cached API under %s.\n"
                "Install Godot 4.x, or pass --godot /path/to/godot (or set GODOT_BIN); the "
                "reference is generated from the engine itself."
                % (args.godot or os.environ.get("GODOT_BIN") or "godot", api_root))
        index_path = cached[0]
        notes.append("godot was not found on PATH; answering from the cached API in %s"
                     % index_path.parent)
        index = json.loads(index_path.read_text(encoding="utf-8"))
        return _finish_db(index, index_path.parent / "xml", args, None, notes, temporaries)

    version = engine_version(binary)
    version_dir = api_root / version_slug(version)
    index_path = version_dir / "index.json"
    xml_dir = version_dir / "xml"

    if index_path.is_file() and not args.refresh:
        try:
            index = json.loads(index_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            index = None
        if index is not None and index.get("classes"):
            return _finish_db(index, xml_dir, args, binary, notes, temporaries)

    if not _writable(version_dir):
        fallback = Path(tempfile.gettempdir()) / "godot-skill-api" / version_slug(version)
        if fallback != version_dir and _writable(fallback):
            notes.append("%s is not writable; caching in %s instead" % (version_dir, fallback))
            version_dir, index_path, xml_dir = fallback, fallback / "index.json", fallback / "xml"
            if index_path.is_file() and not args.refresh:
                try:
                    index = json.loads(index_path.read_text(encoding="utf-8"))
                    if index.get("classes"):
                        return _finish_db(index, xml_dir, args, binary, notes, temporaries)
                except (OSError, ValueError):
                    pass
        else:
            scratch = Path(tempfile.mkdtemp(prefix="godot-skill-api-"))
            temporaries.append(scratch)
            notes.append("no writable cache directory; built a throwaway copy in %s "
                         "(set GODOT_SKILL_CACHE to keep it)" % scratch)
            version_dir, index_path, xml_dir = scratch, scratch / "index.json", scratch / "xml"

    run_doctool(binary, xml_dir)
    index = build_index(xml_dir, version, binary)
    try:
        index_path.write_text(json.dumps(index, separators=(",", ":")), encoding="utf-8")
    except OSError as error:
        notes.append("could not write %s (%s); the XML is still usable this run" % (index_path, error))
    return _finish_db(index, xml_dir, args, binary, notes, temporaries)


def _finish_db(index: dict, xml_dir: Path, args: argparse.Namespace, binary: Optional[str],
               notes: List[str], temporaries: List[Path]) -> Tuple[ApiDb, List[str], List[Path]]:
    db = ApiDb(index, xml_dir)
    if not db.classes:
        raise LookupError_("the cached API index at %s is empty; re-run with --refresh" % xml_dir)
    if args.project:
        if binary is None:
            raise LookupError_("--project needs a Godot binary to read the project's class_name "
                               "scripts; pass --godot /path/to/godot")
        project_classes, project_root, project_notes = project_docs(binary, Path(args.project).expanduser())
        temporaries.append(project_root)
        db.add_project(project_classes, project_root)
        notes.extend(project_notes)
    notes.extend(db.notes)
    # Share the list, so a note raised later (a class whose XML has gone missing)
    # still reaches the caller instead of disappearing into the object.
    db.notes = notes
    return db, notes, temporaries


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="api_lookup.py",
        description="Look up the installed Godot engine's own API (classes, methods, "
                    "properties, signals, constants, theme items).",
        epilog="examples:\n"
               "  api_lookup.py CharacterBody2D\n"
               "  api_lookup.py CharacterBody2D.move_and_slide Area2D.body_entered\n"
               "  api_lookup.py String.begins_with lerp KEY_SPACE Control.SIZE_EXPAND_FILL\n"
               "  api_lookup.py --search tween_ --limit 15\n"
               "  api_lookup.py --project /abs/project MyPlayerClass\n",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("queries", nargs="*", metavar="QUERY",
                        help="Class, Class.member, or a bare global name (lerp, KEY_SPACE).")
    parser.add_argument("--search", metavar="TEXT",
                        help="ranked name matches across every class and member")
    parser.add_argument("--limit", type=int, default=25,
                        help="maximum --search results (default: 25)")
    parser.add_argument("--kind", metavar="LIST",
                        help="comma-separated section filter: "
                             + ",".join(sorted(set(KIND_ALIASES.values()))))
    parser.add_argument("--inherited", action="store_true",
                        help="expand every ancestor's members inline instead of summarising them")
    parser.add_argument("--project", metavar="DIR",
                        help="also index this project's own class_name scripts")
    parser.add_argument("--json", action="store_true", help="print one JSON document")
    parser.add_argument("--pretty", action="store_true", help="indent the --json output")
    parser.add_argument("--refresh", action="store_true", help="rebuild the cached API")
    parser.add_argument("--godot", metavar="BIN",
                        help="Godot binary (default: $GODOT_BIN, else `godot`)")
    parser.add_argument("--cache-dir", metavar="DIR",
                        help="cache base directory (default: $GODOT_SKILL_CACHE, "
                             "else ~/.cache/godot-skill)")
    return parser


def parse_kinds(raw: Optional[str]) -> Optional[List[str]]:
    if not raw:
        return None
    kinds: List[str] = []
    for part in raw.split(","):
        key = part.strip().lower()
        if not key:
            continue
        mapped = KIND_ALIASES.get(key)
        if mapped is None:
            raise LookupError_("unknown --kind %r. Use one or more of: %s"
                               % (part.strip(), ", ".join(sorted(set(KIND_ALIASES.values())))))
        if mapped not in kinds:
            kinds.append(mapped)
    return kinds or None


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    temporaries: List[Path] = []
    try:
        kinds = parse_kinds(args.kind)
        if not args.queries and not args.search:
            parser.print_help(sys.stderr)
            print("\nNothing to look up. Pass a class name, Class.member, or --search TEXT.",
                  file=sys.stderr)
            return 2
        if args.limit < 1:
            raise LookupError_("--limit must be 1 or more")
        db, notes, temporaries = load_db(args)
        renames = godot3_replacements()

        results: List[dict] = []
        if args.search:
            hits, total = search(db, args.search, args.limit)
            lines = ["%d match%s for %r%s:" % (total, "" if total == 1 else "es", args.search,
                                               "" if total <= len(hits)
                                               else " (showing %d, raise --limit)" % len(hits))]
            for hit in hits:
                lines.append("  %-12s %s" % (hit["kind"], hit["signature"]))
            if not hits:
                lines.append("  nothing matched. Try a shorter fragment, or "
                             "api_lookup.py <Class> to list a class.")
            results.append({"query": args.search, "found": bool(hits), "type": "search",
                            "total": total, "matches": hits, "text": lines})
        for raw in args.queries:
            results.append(answer(db, raw, kinds, args.inherited, renames))

        ok = all(result["found"] for result in results)
        if args.json:
            payload = {
                "ok": ok,
                "godot_version": db.version,
                "counts": {"found": sum(1 for result in results if result["found"]),
                           "not_found": sum(1 for result in results if not result["found"])},
                "notes": notes,
                "results": [{key: value for key, value in result.items() if key != "text"}
                            for result in results],
            }
            print(json.dumps(payload, indent=2 if args.pretty else None,
                             separators=None if args.pretty else (",", ":")))
        else:
            for note in notes:
                print("note: " + note, file=sys.stderr)
            blocks = []
            for result in results:
                blocks.append("\n".join(result["text"]))
            text = "\n\n".join(blocks)
            if ok:
                print(text)
            else:
                failing = "\n\n".join("\n".join(result["text"])
                                      for result in results if not result["found"])
                passing = "\n\n".join("\n".join(result["text"])
                                      for result in results if result["found"])
                if passing:
                    print(passing)
                print(failing, file=sys.stderr)
        return 0 if ok else 1
    except LookupError_ as error:
        print("api_lookup: %s" % error, file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 2
    finally:
        for path in temporaries:
            shutil.rmtree(str(path), ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
