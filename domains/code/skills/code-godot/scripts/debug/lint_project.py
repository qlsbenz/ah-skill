#!/usr/bin/env python3
"""Static lint for a Godot 4.x project. No Godot binary, no import step, stdlib only.

``check_project`` is the authoritative validator, but it needs a working Godot
CLI, takes seconds, and reports engine-worded messages. This linter is the fast
pass that runs first and answers the two questions that break generated projects
most often:

1. **Is this Godot 3 code in a Godot 4 project?** ``onready var``, ``yield()``,
   ``.instance()``, ``KinematicBody2D``, ``rect_min_size`` — every one of these
   is a parse or load failure in 4.x, and the engine's own message ("Identifier
   not declared", "Cannot find type") never names the 4.x replacement.
2. **Does this NodePath actually exist?** ``$Panel/Missing``, ``%Ghost``, a
   ``[connection]`` pointing at a method nobody wrote, an ``[ext_resource]``
   whose file was never created. Godot is quiet about all four: a scene with a
   missing ``ext_resource`` still loads and instantiates, a wrong
   ``[connection]`` path is silently dropped, and ``$Panel/Missing`` only
   explodes when the line finally runs.

Output is the same JSON shape ``godot_log_parser.py`` produces
(``{ok, counts, diagnostics:[{severity, category, message, file, line,
suggested_fix}]}``), so ``validate_project.py`` merges the two reports without
translation. Exit code is 1 when any error-level diagnostic exists.

Categories: ``godot3_api``, ``godot3_shader``, ``inference``, ``node_ref``,
``unique_name``, ``signal_target``, ``missing_resource``, ``input_action``,
``group_ref``, ``res_path``, ``animation_ref``.

The last four are *cross-reference* checks: they take a name out of a script and
look for whatever is supposed to provide it somewhere else in the project — an
action in ``project.godot``'s ``[input]``, a ``groups=[…]`` on some node, a file
on disk, an animation inside a ``SpriteFrames``/``AnimationLibrary``. Each one
only speaks when the answer is knowable statically; a name built at runtime, an
action added with ``InputMap.add_action()``, a group added in code, a node whose
type cannot be resolved — all silent.

Two same-file indirections *are* certain and are followed. A ``const`` holding a
string literal cannot be reassigned, so ``Input.is_action_pressed(FIRE)`` with
``const FIRE: StringName = &"fire"`` is exactly as definite as the literal. And
``@onready var anim: AnimatedSprite2D = $Sprite`` followed by
``anim.play("walk")`` — what every bundled template does — resolves, provided the
name is declared once, bound to one node lookup, and never reassigned, shadowed
or re-declared. A ``static var``, a plain ``var``, a const in another file, an
enum, and a binding built from an expression are all left alone.

**Suppressing a finding.** ``# lint:ignore <category>[,<category>…]`` on the
offending line or on the line directly above it drops every diagnostic of those
categories there; bare ``# lint:ignore`` drops all of them. ``;`` works in
``.tscn``/``.tres``/``project.godot`` and ``//`` in ``.gdshader``. Use it for the
rare case the linter cannot know about — a file that must *name* a deprecated
class to reason about it, a path created by the build. Suppressions that matched
nothing are listed under ``suppressions.unused`` in the report and never change
the exit code.

**``.gdignore``.** A directory holding a ``.gdignore`` file is invisible to
Godot, so the linter skips it too — its files are neither scanned nor indexed.

**Severity means one thing here.** ``error`` = Godot refuses to parse or load the
file, so the project does not run; ``warning`` = it compiles and runs, but the
code is risky (a variable typed as bare ``Node``, a deprecated-but-working
alias, a ``get_node_or_null`` path that is not in the scene). Every severity was
checked against ``godot 4.7.stable``: ``var a := $Child``, ``:= %Unique``,
``:= get_node(...)`` and ``:= scene.instantiate()`` all compile — they infer
``Node`` — so they are warnings, while ``:= data.get("k")``, ``:= arr[0]`` on an
untyped collection, ``:= JSON.parse_string(...)``, ``:= null`` and a call into a
function with no ``-> Type`` are hard parse errors. ``load()``/``preload()`` are
not reported at all: the analyzer types them.

Known limitations (deliberate — a false positive is worse than a miss here):

- GDScript is scanned line by line after stripping ``#`` comments and blanking
  string *contents*. A triple-quoted string spanning several lines is not
  tracked, so its inner lines are scanned as code.
- The ``inference`` check classifies the **outermost** expression of the
  right-hand side, not every token on the line:
  ``var p := _to_path(params.get("p", ""))`` is fine because ``_to_path()``
  declares ``-> String``, and the ``.get()`` inside it is somebody else's
  argument. A right-hand side that continues on the next line, or whose
  outermost call is a method on another object, is left alone — Godot's own
  analyzer catches a real Variant there, and a false alarm costs a weak model
  more than a miss.
- Node paths built at runtime (``str()``, ``+``, ``%s`` formatting, a variable)
  are skipped, never guessed. Same for anything under ``/root/`` and any
  ``res://`` path.
- A node that comes from ``instance=ExtResource(...)`` is resolved by reading
  that child ``.tscn``; when the file is not on disk the whole path is skipped.
- Nodes created at runtime with ``add_child()`` are not in any ``.tscn``, so a
  ``$Path`` to one is reported. Give it a real node, or build the path
  dynamically (which is skipped).
- A rename rule is suppressed when the project declares that name itself with
  ``class_name`` — Godot 4 freed ``File``, ``Path``, ``Sprite`` and friends, so
  a project is allowed to take them.
- ``node_ref`` / ``unique_name`` only run for a script a ``.tscn`` attaches to a
  node. A script no scene references, or one only ever ``load()``-ed and added
  in code, is checked for the other four categories only.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
from pathlib import Path
from typing import Iterable, Optional

CATEGORIES = (
    "godot3_api",
    "godot3_shader",
    "inference",
    "node_ref",
    "unique_name",
    "signal_target",
    "missing_resource",
    "input_action",
    "group_ref",
    "res_path",
    "animation_ref",
)


# ---------------------------------------------------------------------------
# The Godot 3 -> Godot 4.7 rule table. Single source of truth, shared with
# references/godot3_to_4.md (regenerate that doc with --list-rules).
# ---------------------------------------------------------------------------
# Every rule is {id, token, replacement, group, severity, scope, pattern,
# scene_pattern, message, fix}:
#   pattern        regex matched against .gd lines with comments removed and
#                  string contents blanked out
#   scene_pattern  regex matched against raw .tscn/.tres lines (None = reuse
#                  `pattern`)
#   scope          "gd" | "scene" | "both" | "shader"
#   severity       "error"   guaranteed to fail to parse/load/run on 4.x
#                  "warning" deprecated alias that still works
#   category       "godot3_api" (default) or "godot3_shader"
#   fix            the exact 4.7 replacement, spelled out

GROUP_SYNTAX = "Syntax and keywords"
GROUP_SIGNALS = "Signals"
GROUP_2D = "Nodes (2D)"
GROUP_3D = "Nodes (3D)"
GROUP_RES = "Resources and types"
GROUP_MATH = "Math and utility functions"
GROUP_CONTROL = "Control properties"
GROUP_OS = "File, OS, and engine"
GROUP_SHADERS = "Shaders"

GROUP_ORDER = (
    GROUP_SYNTAX,
    GROUP_SIGNALS,
    GROUP_2D,
    GROUP_3D,
    GROUP_RES,
    GROUP_MATH,
    GROUP_CONTROL,
    GROUP_OS,
    GROUP_SHADERS,
)


def _rule(rid: str, token: str, replacement: str, group: str, severity: str,
          pattern: str, message: str, fix: str, scope: str = "gd",
          scene_pattern: Optional[str] = None, identifier: Optional[str] = None,
          guard: Optional[str] = None, suppress_if_func: Optional[str] = None,
          category: str = "godot3_api") -> dict:
    return {
        "id": rid,
        "category": category,
        "token": token,
        # Name in GUARDS: an extra check run on the matched line (see GUARDS).
        "guard": guard,
        # A project that defines `func <name>(` owns that name; the rule is then
        # not about the removed engine method at all. `LegacySystem.empty()` in a
        # real project is a static helper, not `Array.empty()`.
        "suppress_if_func": suppress_if_func,
        # Engine class this rule is about, when it is one. A project is allowed to
        # define `class_name File` (Godot 4 has no File class), so a rule whose
        # identifier is a project class_name is suppressed.
        "identifier": identifier,
        # Shader rules only: the identifier the shader may legitimately declare
        # itself. The engine's own migration advice for SCREEN_TEXTURE is
        # `uniform sampler2D SCREEN_TEXTURE : hint_screen_texture;`, so a shader
        # that declares the name is already migrated and must not be reported.
        "suppress_if_declared": None,
        "replacement": replacement,
        "group": group,
        "severity": severity,
        "scope": scope,
        "pattern": pattern,
        "scene_pattern": scene_pattern,
        "message": message,
        "fix": fix,
    }


def _class_rule(name: str, replacement: str, group: str, note: str = "",
                severity: str = "error", strict: bool = False,
                scene: bool = True) -> dict:
    """A renamed/removed engine class.

    `strict` restricts the .gd match to positions where an identifier can only
    be a type (`extends X`, `as X`, `is X`, `: X`, `-> X`, `Array[X]`,
    `X.new()`). Use it for names that are ordinary English words (Path, Light,
    Camera, Area, Sprite, Reference, ...) so a variable or a member never
    trips the rule.
    """
    if strict:
        pattern = (r"(?:\b(?:extends|as|is)\s+|->\s*|:\s*|\bArray\[)" + name + r"\b"
                   + r"|\b" + name + r"\s*\.\s*new\s*\(")
    else:
        pattern = r"\b" + name + r"\b"
    if severity == "warning":
        message = (f"`{name}` still exists in Godot 4.7 but is deprecated; "
                   f"new code should use `{replacement}`.")
    else:
        message = f"`{name}` is a Godot 3 class and does not exist in Godot 4.x."
    fix = f"`{name}` -> `{replacement}`." + (f" {note}" if note else "")
    return _rule(name.lower() + "_class", name, replacement, group, severity, pattern,  # noqa: E501
                 message, fix, scope="both" if scene else "gd",
                 scene_pattern=(r'type\s*=\s*"' + name + r'"') if scene else None,
                 identifier=name)


GODOT3_RULES: list[dict] = [
    # --- syntax and keywords ------------------------------------------------
    _rule("onready_var", "onready var", "@onready var", GROUP_SYNTAX, "error",
          r"(?<!@)\bonready\s+var\b",
          "Godot 3 `onready var`: in 4.x `onready` is an annotation, so the bare keyword "
          "is a parse error (`Unexpected \"Identifier\" in class body`).",
          "Write `@onready var name: Type = $Node`. Keep the type annotation — `$Node` is "
          "statically typed `Node`, so `:=` there silently widens the variable."),
    _rule("export_var", "export var", "@export var", GROUP_SYNTAX, "error",
          r"(?<!@)\bexport\s+var\b",
          "Godot 3 `export var`: in 4.x `export` is an annotation.",
          "Write `@export var speed: float = 200.0`. A bare `@export` with no type and no "
          "initializer does not compile either."),
    _rule("export_hint", "export(Type) var", "@export / @export_range", GROUP_SYNTAX, "error",
          # Anchored: the Godot 3 form is a declaration prefix. A project is free to
          # define `static func export(...)` and call `Exporter.export(...)`.
          r"^\s*(?:onready\s+)?export\s*\(.*\)\s*(?:var|onready)\b",
          "Godot 3 `export(Type)` hint syntax was replaced by typed annotations in 4.x.",
          "`export(int) var hp` -> `@export var hp: int = 0`; `export(int, 0, 100) var armor` -> "
          "`@export_range(0, 100) var armor: int = 0`; `export(String, \"a\", \"b\")` -> "
          "`@export_enum(\"a\", \"b\") var mode: String = \"a\"`."),
    _rule("tool_keyword", "tool", "@tool", GROUP_SYNTAX, "error",
          r"^\s*tool\s*$",
          "Godot 3 `tool` keyword: in 4.x it is the `@tool` annotation.",
          "Replace the first line with `@tool`."),
    _rule("yield_call", "yield(", "await", GROUP_SYNTAX, "error",
          r"\byield\s*\(",
          "`yield()` was removed in Godot 4.x; coroutines use `await`.",
          "`yield(get_tree().create_timer(1.0), \"timeout\")` -> "
          "`await get_tree().create_timer(1.0).timeout`; `yield(obj, \"sig\")` -> `await obj.sig`."),
    _rule("setget", "setget", "set:/get: blocks", GROUP_SYNTAX, "error",
          r"\bsetget\b",
          "`setget` was removed in Godot 4.x.",
          "Use the 4.x property block — `var hp: int = 10:` followed by an indented "
          "`set(value):` / `get:` pair — or the short form "
          "`var hp: int = 10: set = _set_hp, get = _get_hp`."),
    _rule("instance_call", ".instance(", ".instantiate()", GROUP_SYNTAX, "error",
          r"\.instance\s*\(",
          "`PackedScene.instance()` was renamed in Godot 4.x.",
          "`scene.instance()` -> `scene.instantiate()`. Annotate the result: "
          "`var enemy := scene.instantiate() as Enemy` (plus a null guard).",
          guard="lowercase_receiver", suppress_if_func="instance"),
    _rule("empty_call", ".empty()", ".is_empty()", GROUP_SYNTAX, "error",
          r"\.empty\s*\(\s*\)",
          "`Array.empty()` / `Dictionary.empty()` / `String.empty()` were renamed in Godot 4.x.",
          "`items.empty()` -> `items.is_empty()`.",
          guard="lowercase_receiver", suppress_if_func="empty"),
    _rule("move_and_slide_args", "move_and_slide(velocity)", "velocity + move_and_slide()",
          GROUP_SYNTAX, "error",
          r"\bmove_and_slide\s*\(\s*[^)\s]",
          "In Godot 4.x `CharacterBody2D/3D.move_and_slide()` takes no arguments; it reads and "
          "writes the node's own `velocity` property.",
          "Set `velocity` first, then call it bare: `velocity = dir * speed` then "
          "`move_and_slide()`. `move_and_slide(vel, Vector2.UP)` -> `velocity = vel` + "
          "`up_direction = Vector2.UP` (a property) + `move_and_slide()`."),
    _rule("move_and_slide_with_snap", "move_and_slide_with_snap(", "move_and_slide() + floor snap",
          GROUP_SYNTAX, "error",
          r"\bmove_and_slide_with_snap\s*\(",
          "`move_and_slide_with_snap()` was removed in Godot 4.x.",
          "Set `floor_snap_length` (and `floor_stop_on_slope`) on the CharacterBody, then call "
          "`move_and_slide()` with no arguments."),
    _rule("change_scene", "get_tree().change_scene(", "change_scene_to_file(",
          GROUP_SYNTAX, "error",
          r"\bget_tree\s*\(\s*\)\s*\.\s*change_scene(?:_to)?\s*\(",
          "`SceneTree.change_scene()` was renamed in Godot 4.x.",
          "`get_tree().change_scene(\"res://x.tscn\")` -> "
          "`get_tree().change_scene_to_file(\"res://x.tscn\")`; for a loaded PackedScene use "
          "`change_scene_to_packed(packed)`. (A project's own `func change_scene()` on an "
          "autoload is not this rule and is not reported.)"),
    _rule("tween_interpolate_property", "interpolate_property(", "create_tween().tween_property()",
          GROUP_SYNTAX, "error",
          r"\binterpolate_property\s*\(",
          "The Godot 3 `Tween` node API (`interpolate_property` + `start()`) was replaced by "
          "scene-tree tweens in 4.x.",
          "`var t := create_tween()` then "
          "`t.tween_property(node, \"position\", target, 0.4).set_trans(Tween.TRANS_SINE)`. "
          "Tweens are created in code and run themselves — no Tween node, no `start()`.",
          suppress_if_func="interpolate_property"),
    _rule("tween_node", "Tween (node)", "create_tween()", GROUP_SYNTAX, "error",
          r'type\s*=\s*"Tween"',
          "`Tween` is not a Node in Godot 4.x (it is a RefCounted created by "
          "`create_tween()`), so a `Tween` node in a scene fails to load.",
          "Delete the Tween node and call `create_tween()` in the script that animates. "
          "See references/tween.md.",
          scope="scene"),

    # --- signals ------------------------------------------------------------
    _rule("connect_string", 'connect("sig", obj, "method")', "sig.connect(obj.method)",
          GROUP_SIGNALS, "error",
          r"\bconnect\s*\(\s*\"[^\"]*\"\s*,\s*[^,()]+,\s*\"",
          "Godot 3 string-form connect. In 4.x `Object.connect()` takes a Callable as its "
          "second argument, so passing (object, \"method_name\") fails at runtime with "
          "`Invalid type in function 'connect'`.",
          "`button.connect(\"pressed\", self, \"_on_pressed\")` -> "
          "`button.pressed.connect(_on_pressed)`. With binds: "
          "`button.pressed.connect(_on_pressed.bind(\"arg\"))`."),
    _rule("is_connected_string", 'is_connected("sig", obj, "m")', "sig.is_connected(obj.m)",
          GROUP_SIGNALS, "error",
          r"\bis_connected\s*\(\s*\"[^\"]*\"\s*,\s*[^,()]+,\s*\"",
          "Godot 3 string-form `is_connected`. 4.x expects a Callable.",
          "`obj.is_connected(\"sig\", self, \"_on\")` -> `obj.sig.is_connected(_on)`."),
    _rule("disconnect_string", 'disconnect("sig", obj, "m")', "sig.disconnect(obj.m)",
          GROUP_SIGNALS, "error",
          r"\bdisconnect\s*\(\s*\"[^\"]*\"\s*,\s*[^,()]+,\s*\"",
          "Godot 3 string-form `disconnect`. 4.x expects a Callable.",
          "`obj.disconnect(\"sig\", self, \"_on\")` -> `obj.sig.disconnect(_on)`."),
    _rule("emit_signal_string", 'emit_signal("x")', "x.emit()", GROUP_SIGNALS, "warning",
          r"\bemit_signal\s*\(",
          "`emit_signal(\"name\", ...)` still works in 4.7 but the signal-object form is the "
          "current API and is checked at parse time instead of by string lookup.",
          "`emit_signal(\"died\", score)` -> `died.emit(score)`."),

    # --- 2D nodes -----------------------------------------------------------
    _class_rule("KinematicBody2D", "CharacterBody2D", GROUP_2D,
                "Set the `velocity` property, then call `move_and_slide()` with no arguments."),
    _class_rule("Sprite", "Sprite2D", GROUP_2D, strict=True),
    _class_rule("AnimatedSprite", "AnimatedSprite2D", GROUP_2D),
    _class_rule("Particles2D", "GPUParticles2D", GROUP_2D,
                "`CPUParticles2D` is the no-GPU alternative."),
    _class_rule("Position2D", "Marker2D", GROUP_2D),
    _class_rule("TextureProgress", "TextureProgressBar", GROUP_2D),
    _class_rule("VisibilityNotifier2D", "VisibleOnScreenNotifier2D", GROUP_2D),
    _class_rule("VisibilityEnabler2D", "VisibleOnScreenEnabler2D", GROUP_2D),
    _class_rule("Navigation2D", "NavigationRegion2D", GROUP_2D,
                "Pathfinding queries moved to the `NavigationServer2D` singleton."),
    _class_rule("YSort", "Node2D with y_sort_enabled = true", GROUP_2D,
                "`y_sort_enabled` is a CanvasItem property in 4.x; the node type was removed."),
    _class_rule("ParallaxBackground", "Parallax2D", GROUP_2D,
                "`Parallax2D` replaces the ParallaxBackground/ParallaxLayer pair (4.3+).",
                severity="warning"),
    _class_rule("TileMap", "TileMapLayer", GROUP_2D,
                "One TileMapLayer node per layer; `paint_tilemap` targets TileMapLayer.",
                severity="warning"),

    # --- 3D nodes -----------------------------------------------------------
    _class_rule("KinematicBody", "CharacterBody3D", GROUP_3D,
                "Set `velocity`, then call `move_and_slide()` with no arguments."),
    _class_rule("Spatial", "Node3D", GROUP_3D),
    _class_rule("Area", "Area3D", GROUP_3D, strict=True),
    _class_rule("RigidBody", "RigidBody3D", GROUP_3D),
    _class_rule("StaticBody", "StaticBody3D", GROUP_3D),
    _class_rule("CollisionShape", "CollisionShape3D", GROUP_3D),
    _class_rule("CollisionPolygon", "CollisionPolygon3D", GROUP_3D),
    _class_rule("Particles", "GPUParticles3D", GROUP_3D, strict=True),
    _class_rule("Position3D", "Marker3D", GROUP_3D),
    _class_rule("Navigation", "NavigationRegion3D", GROUP_3D, strict=True,
                note="Pathfinding queries moved to the `NavigationServer3D` singleton."),
    _class_rule("RayCast", "RayCast3D", GROUP_3D),
    _class_rule("Camera", "Camera3D", GROUP_3D, strict=True),
    _class_rule("Light", "Light3D", GROUP_3D, strict=True,
                note="Light3D is abstract — use OmniLight3D / SpotLight3D / DirectionalLight3D."),
    _class_rule("OmniLight", "OmniLight3D", GROUP_3D),
    _class_rule("SpotLight", "SpotLight3D", GROUP_3D),
    _class_rule("DirectionalLight", "DirectionalLight3D", GROUP_3D),
    _class_rule("MeshInstance", "MeshInstance3D", GROUP_3D),
    _class_rule("Listener", "AudioListener3D", GROUP_3D, strict=True),
    _class_rule("Path", "Path3D", GROUP_3D, strict=True, note="2D curves use `Path2D`."),
    _class_rule("PathFollow", "PathFollow3D", GROUP_3D),
    _class_rule("Skeleton", "Skeleton3D", GROUP_3D, strict=True),
    _class_rule("BoneAttachment", "BoneAttachment3D", GROUP_3D),
    _class_rule("ImmediateGeometry", "MeshInstance3D + ImmediateMesh", GROUP_3D,
                "Build the geometry into an `ImmediateMesh` resource and assign it to a "
                "MeshInstance3D."),
    _class_rule("ClippedCamera", "SpringArm3D", GROUP_3D,
                "SpringArm3D (or a ShapeCast3D) does the collision-clipping the node used to do."),
    _class_rule("InterpolatedCamera", "Camera3D + a Tween", GROUP_3D,
                "Tween `global_transform` on a plain Camera3D."),
    _class_rule("GIProbe", "VoxelGI", GROUP_3D),
    _class_rule("BakedLightmap", "LightmapGI", GROUP_3D,
                "Baking LightmapGI is editor-only; it cannot be done headlessly."),
    _rule("arvr_classes", "ARVR*", "XR*", GROUP_3D, "error",
          r"\bARVR[A-Za-z]\w*\b",
          "The whole `ARVR*` family was renamed `XR*` in Godot 4.x.",
          "`ARVRCamera` -> `XRCamera3D`, `ARVRController` -> `XRController3D`, `ARVROrigin` -> "
          "`XROrigin3D`, `ARVRAnchor` -> `XRAnchor3D`, `ARVRServer` -> `XRServer`, "
          "`ARVRInterface` -> `XRInterface`.",
          scope="both", scene_pattern=r'type\s*=\s*"ARVR[A-Za-z]\w*"'),

    # --- resources and types ------------------------------------------------
    _class_rule("Reference", "RefCounted", GROUP_RES, strict=True,
                note="`extends Reference` -> `extends RefCounted`."),
    _class_rule("PoolStringArray", "PackedStringArray", GROUP_RES),
    _class_rule("PoolIntArray", "PackedInt32Array", GROUP_RES),
    _class_rule("PoolRealArray", "PackedFloat32Array", GROUP_RES),
    _class_rule("PoolVector2Array", "PackedVector2Array", GROUP_RES),
    _class_rule("PoolVector3Array", "PackedVector3Array", GROUP_RES),
    _class_rule("PoolColorArray", "PackedColorArray", GROUP_RES),
    _class_rule("PoolByteArray", "PackedByteArray", GROUP_RES),
    _class_rule("StreamTexture", "CompressedTexture2D", GROUP_RES),
    _class_rule("DynamicFont", "FontFile", GROUP_RES,
                "Set `Label`'s `theme_override_fonts/font` to the FontFile; size is "
                "`theme_override_font_sizes/font_size`."),
    _class_rule("BitmapFont", "FontFile", GROUP_RES),
    _class_rule("PanoramaSky", "PanoramaSkyMaterial", GROUP_RES,
                "Assign it to `Sky.sky_material` on the Environment."),
    _class_rule("ProceduralSky", "ProceduralSkyMaterial", GROUP_RES,
                "Assign it to `Sky.sky_material` on the Environment."),
    _class_rule("CubeMesh", "BoxMesh", GROUP_RES),

    # --- math and utility functions ----------------------------------------
    _rule("rand_range", "rand_range(", "randf_range(", GROUP_MATH, "error",
          r"\brand_range\s*\(",
          "`rand_range()` was removed in Godot 4.x.",
          "`rand_range(a, b)` -> `randf_range(a, b)` for floats, `randi_range(a, b)` for ints."),
    _rule("deg2rad", "deg2rad(", "deg_to_rad(", GROUP_MATH, "error",
          r"\bdeg2rad\s*\(",
          "`deg2rad()` was renamed in Godot 4.x.",
          "`deg2rad(x)` -> `deg_to_rad(x)`."),
    _rule("rad2deg", "rad2deg(", "rad_to_deg(", GROUP_MATH, "error",
          r"\brad2deg\s*\(",
          "`rad2deg()` was renamed in Godot 4.x.",
          "`rad2deg(x)` -> `rad_to_deg(x)`."),
    _rule("stepify", "stepify(", "snappedf(", GROUP_MATH, "error",
          r"\bstepify\s*\(",
          "`stepify()` was renamed in Godot 4.x.",
          "`stepify(x, 0.5)` -> `snappedf(x, 0.5)` (`snapped()` for Vector2/Vector3)."),
    _rule("linear_interpolate", ".linear_interpolate(", ".lerp(", GROUP_MATH, "error",
          r"\.linear_interpolate\s*\(",
          "`Vector2/Vector3/Color.linear_interpolate()` was renamed in Godot 4.x.",
          "`a.linear_interpolate(b, t)` -> `a.lerp(b, t)`.",
          suppress_if_func="linear_interpolate"),
    _rule("xform", ".xform(", "transform * value", GROUP_MATH, "error",
          r"\.xform(?:_inv)?\s*\(",
          "`Transform.xform()` / `xform_inv()` were removed in Godot 4.x in favour of the "
          "multiplication operator.",
          "`t.xform(v)` -> `t * v`; `t.xform_inv(v)` -> `v * t` (or `t.affine_inverse() * v`).",
          suppress_if_func="xform"),
    _rule("type_real", "TYPE_REAL", "TYPE_FLOAT", GROUP_MATH, "error",
          r"\bTYPE_REAL\b",
          "The `TYPE_REAL` Variant type constant was renamed in Godot 4.x.",
          "`TYPE_REAL` -> `TYPE_FLOAT`."),
    _rule("color_lowercase", "Color.white", "Color.WHITE", GROUP_MATH, "error",
          r"\bColor\.[a-z][a-z0-9_]*\b(?!\s*\()",
          "Godot 4.x named colours are UPPER_CASE constants; the Godot 3 lowercase names were "
          "removed, so this is a parse error (`Cannot find constant ... on base Color`).",
          "`Color.white` -> `Color.WHITE`, `Color.red` -> `Color.RED`, `Color.dodger_blue` -> "
          "`Color.DODGER_BLUE`."),

    # --- Control properties -------------------------------------------------
    _rule("rect_position", "rect_position", "position", GROUP_CONTROL, "error",
          r"(?<![\w/])rect_position\b",
          "`Control.rect_position` was renamed in Godot 4.x.",
          "`rect_position` -> `position`.", scope="both"),
    _rule("rect_size", "rect_size", "size", GROUP_CONTROL, "error",
          r"(?<![\w/])rect_size\b",
          "`Control.rect_size` was renamed in Godot 4.x.",
          "`rect_size` -> `size`.", scope="both"),
    _rule("rect_min_size", "rect_min_size", "custom_minimum_size", GROUP_CONTROL, "error",
          r"(?<![\w/])rect_min_size\b",
          "`Control.rect_min_size` was renamed in Godot 4.x.",
          "`rect_min_size` -> `custom_minimum_size` (a Vector2; `configure_control` sets it "
          "directly).", scope="both"),
    _rule("rect_global_position", "rect_global_position", "global_position", GROUP_CONTROL, "error",
          r"(?<![\w/])rect_global_position\b",
          "`Control.rect_global_position` was renamed in Godot 4.x.",
          "`rect_global_position` -> `global_position`.", scope="both"),
    _rule("rect_scale", "rect_scale", "scale", GROUP_CONTROL, "error",
          r"(?<![\w/])rect_scale\b",
          "`Control.rect_scale` was renamed in Godot 4.x.",
          "`rect_scale` -> `scale`.", scope="both"),
    _rule("rect_rotation", "rect_rotation", "rotation", GROUP_CONTROL, "error",
          r"(?<![\w/])rect_rotation\b",
          "`Control.rect_rotation` was renamed in Godot 4.x.",
          "`rect_rotation` -> `rotation` (radians; `rotation_degrees` for degrees).", scope="both"),
    _rule("rect_pivot_offset", "rect_pivot_offset", "pivot_offset", GROUP_CONTROL, "error",
          r"(?<![\w/])rect_pivot_offset\b",
          "`Control.rect_pivot_offset` was renamed in Godot 4.x.",
          "`rect_pivot_offset` -> `pivot_offset`.", scope="both"),
    _rule("margin_sides", "margin_left / margin_top / margin_right / margin_bottom",
          "offset_left / offset_top / offset_right / offset_bottom", GROUP_CONTROL, "error",
          r"(?<![\w/])margin_(?:left|top|right|bottom)\b",
          "`Control.margin_*` was renamed `offset_*` in Godot 4.x. (The MarginContainer theme "
          "constants `theme_override_constants/margin_left` keep the old name and are not "
          "matched.)",
          "`margin_left` -> `offset_left`, `margin_top` -> `offset_top`, `margin_right` -> "
          "`offset_right`, `margin_bottom` -> `offset_bottom`. Prefer containers plus "
          "`configure_control` presets over hand-set offsets.", scope="both"),
    _rule("hint_tooltip", "hint_tooltip", "tooltip_text", GROUP_CONTROL, "error",
          r"(?<![\w/])hint_tooltip\b",
          "`Control.hint_tooltip` was renamed in Godot 4.x.",
          "`hint_tooltip` -> `tooltip_text`.", scope="both"),
    _rule("percent_visible", "percent_visible", "visible_ratio", GROUP_CONTROL, "error",
          r"(?<![\w/])percent_visible\b",
          "`Label.percent_visible` / `RichTextLabel.percent_visible` were renamed in Godot 4.x.",
          "`percent_visible` -> `visible_ratio` (`visible_characters` still exists).",
          scope="both"),

    # --- file, OS, engine ---------------------------------------------------
    _rule("file_new", "File.new()", "FileAccess.open()", GROUP_OS, "error",
          r"\bFile\.new\s*\(",
          "The `File` class was replaced by `FileAccess` in Godot 4.x.",
          "`var f := File.new(); f.open(path, File.READ)` -> "
          "`var f := FileAccess.open(path, FileAccess.READ)` (returns null on failure; check "
          "`FileAccess.get_open_error()`). Files close themselves when the reference is freed.",
          identifier="File"),
    _rule("directory_new", "Directory.new()", "DirAccess.open()", GROUP_OS, "error",
          r"\bDirectory\.new\s*\(",
          "The `Directory` class was replaced by `DirAccess` in Godot 4.x.",
          "`var d := Directory.new(); d.open(path)` -> `var d := DirAccess.open(path)`; "
          "listing is `DirAccess.get_files_at(path)` / `get_directories_at(path)`.",
          identifier="Directory"),
    _rule("os_get_ticks", "OS.get_ticks_msec()", "Time.get_ticks_msec()", GROUP_OS, "error",
          r"\bOS\.get_ticks_[mu]sec\b",
          "Time functions moved from `OS` to the `Time` singleton in Godot 4.x.",
          "`OS.get_ticks_msec()` -> `Time.get_ticks_msec()`; `OS.get_ticks_usec()` -> "
          "`Time.get_ticks_usec()`; `OS.get_datetime()` -> "
          "`Time.get_datetime_dict_from_system()`."),
    _rule("os_window_size", "OS.window_size", "DisplayServer.window_get_size()", GROUP_OS, "error",
          r"\bOS\.window_(?:size|fullscreen|position)\b",
          "Window properties moved off `OS` in Godot 4.x.",
          "`OS.window_size` -> `get_window().size` (or "
          "`DisplayServer.window_get_size()`); `OS.window_fullscreen = true` -> "
          "`get_window().mode = Window.MODE_FULLSCREEN`."),
    _rule("engine_editor_hint", "Engine.editor_hint", "Engine.is_editor_hint()", GROUP_OS, "error",
          r"\bEngine\.editor_hint\b",
          "`Engine.editor_hint` became a method in Godot 4.x.",
          "`if Engine.editor_hint:` -> `if Engine.is_editor_hint():`."),
]


# ---------------------------------------------------------------------------
# Shader rules (category `godot3_shader`, scope `.gdshader`/`.gdshaderinc` and
# the `code = "…"` of a Shader sub-resource inside a .tscn/.tres).
#
# Every row below was verified by compiling the Godot 3 form AND its
# replacement on godot 4.7.stable through `check_project` (which hands the code
# to a ShaderMaterial — load() alone never compiles a shader). The Godot 3 form
# had to fail and the replacement had to compile; rules whose "before" turned out
# to still compile on 4.7 were deleted rather than shipped, which is why
# `hint_normal`, `OUTPUT_IS_SRGB`, `AT_LIGHT_PASS`, `ATTENUATION`,
# `hint_roughness_gray`, `render_mode specular_toon` and `specular_disabled` are
# NOT in this table: 4.7 accepts all of them.
# ---------------------------------------------------------------------------

def _shader_rule(rid: str, token: str, replacement: str, pattern: str,
                 message: str, fix: str, severity: str = "error",
                 suppress_if_declared: Optional[str] = None) -> dict:
    rule = _rule(rid, token, replacement, GROUP_SHADERS, severity, pattern, message, fix,
                 scope="shader", category="godot3_shader")
    rule["suppress_if_declared"] = suppress_if_declared
    return rule


_SHADER_REMOVED = (
    " Verified on godot 4.7: the shader fails to compile, and a shader that does not compile "
    "renders as the plain default material with no runtime error — nothing in the log says why."
)

SHADER_RULES: list[dict] = [
    _shader_rule("shader_hint_color", "hint_color", "source_color",
                 r"\bhint_color\b",
                 "`hint_color` was renamed in Godot 4.x (`Expected valid type hint after ':'`)."
                 + _SHADER_REMOVED,
                 "`uniform vec4 tint : hint_color;` -> `uniform vec4 tint : source_color;`."),
    _shader_rule("shader_hint_albedo", "hint_albedo", "source_color",
                 r"\bhint_albedo\b",
                 "`hint_albedo` was replaced by `source_color` in Godot 4.x." + _SHADER_REMOVED,
                 "`uniform vec4 albedo : hint_albedo;` -> `uniform vec4 albedo : source_color;` "
                 "(same hint for a sampler2D albedo texture)."),
    _shader_rule("shader_hint_black", "hint_black", "hint_default_black",
                 r"\bhint_black(?:_albedo)?\b",
                 "`hint_black` / `hint_black_albedo` were renamed in Godot 4.x." + _SHADER_REMOVED,
                 "`uniform sampler2D tex : hint_black;` -> `: hint_default_black;`. "
                 "`hint_black_albedo` -> `hint_default_black, source_color`."),
    _shader_rule("shader_hint_white", "hint_white", "hint_default_white",
                 r"\bhint_white\b",
                 "`hint_white` was renamed in Godot 4.x." + _SHADER_REMOVED,
                 "`uniform sampler2D tex : hint_white;` -> `: hint_default_white;`. "
                 "(`hint_default_transparent` is the third one and is spelled the same in 4.x.)"),
    _shader_rule("shader_hint_aniso", "hint_aniso", "hint_anisotropy",
                 r"\bhint_aniso\b",
                 "`hint_aniso` was renamed in Godot 4.x." + _SHADER_REMOVED,
                 "`uniform sampler2D flow : hint_aniso;` -> `: hint_anisotropy;`."),
    _shader_rule("shader_screen_texture", "SCREEN_TEXTURE", "hint_screen_texture uniform",
                 r"\bSCREEN_TEXTURE\b",
                 "The `SCREEN_TEXTURE` built-in was removed in Godot 4.x; the screen is read "
                 "through a uniform with a hint." + _SHADER_REMOVED,
                 "Add `uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, "
                 "filter_linear_mipmap;` near the top of the shader and leave the "
                 "`texture(SCREEN_TEXTURE, SCREEN_UV)` calls alone — that is the engine's own "
                 "minimal-change migration. A fresh shader should name the uniform "
                 "`screen_tex` instead. The node must be under a BackBufferCopy (2D) for the "
                 "read to see anything.",
                 suppress_if_declared="SCREEN_TEXTURE"),
    _shader_rule("shader_depth_texture", "DEPTH_TEXTURE", "hint_depth_texture uniform",
                 r"\bDEPTH_TEXTURE\b",
                 "The `DEPTH_TEXTURE` built-in was removed in Godot 4.x." + _SHADER_REMOVED,
                 "Add `uniform sampler2D DEPTH_TEXTURE : hint_depth_texture;` (or name it "
                 "`depth_tex` and update the reads).",
                 suppress_if_declared="DEPTH_TEXTURE"),
    _shader_rule("shader_normal_roughness_texture", "NORMAL_ROUGHNESS_TEXTURE",
                 "hint_normal_roughness_texture uniform",
                 r"\bNORMAL_ROUGHNESS_TEXTURE\b",
                 "The `NORMAL_ROUGHNESS_TEXTURE` built-in was removed in Godot 4.x."
                 + _SHADER_REMOVED,
                 "Add `uniform sampler2D NORMAL_ROUGHNESS_TEXTURE : "
                 "hint_normal_roughness_texture;` (Forward+ only).",
                 suppress_if_declared="NORMAL_ROUGHNESS_TEXTURE"),
    _shader_rule("shader_world_matrix", "WORLD_MATRIX", "MODEL_MATRIX",
                 r"\bWORLD_MATRIX\b",
                 "`WORLD_MATRIX` was renamed in Godot 4.x (`Unknown identifier in expression: "
                 "'WORLD_MATRIX'`), in both spatial and canvas_item shaders." + _SHADER_REMOVED,
                 "`WORLD_MATRIX` -> `MODEL_MATRIX`."),
    _shader_rule("shader_extra_matrix", "EXTRA_MATRIX", "MODEL_MATRIX",
                 r"\bEXTRA_MATRIX\b",
                 "`EXTRA_MATRIX` (canvas_item) was removed in Godot 4.x." + _SHADER_REMOVED,
                 "`EXTRA_MATRIX` -> `MODEL_MATRIX` (the item transform). The canvas transform "
                 "is `CANVAS_MATRIX` and the view transform `SCREEN_MATRIX`."),
    _shader_rule("shader_camera_matrix", "CAMERA_MATRIX", "INV_VIEW_MATRIX",
                 r"\bCAMERA_MATRIX\b",
                 "`CAMERA_MATRIX` was renamed in Godot 4.x." + _SHADER_REMOVED,
                 "`CAMERA_MATRIX` -> `INV_VIEW_MATRIX` (camera-to-world). Careful: the "
                 "*other* one flipped too — Godot 3's `INV_CAMERA_MATRIX` is 4.x's "
                 "`VIEW_MATRIX`."),
    _shader_rule("shader_inv_camera_matrix", "INV_CAMERA_MATRIX", "VIEW_MATRIX",
                 r"\bINV_CAMERA_MATRIX\b",
                 "`INV_CAMERA_MATRIX` was renamed in Godot 4.x." + _SHADER_REMOVED,
                 "`INV_CAMERA_MATRIX` -> `VIEW_MATRIX` (world-to-camera). "
                 "`PROJECTION_MATRIX`, `INV_PROJECTION_MATRIX` and `MODELVIEW_MATRIX` keep "
                 "their names and are not reported."),
    _shader_rule("shader_transmission", "TRANSMISSION", "BACKLIGHT",
                 r"\bTRANSMISSION\b",
                 "The spatial output `TRANSMISSION` was renamed in Godot 4.x." + _SHADER_REMOVED,
                 "`TRANSMISSION = vec3(…)` -> `BACKLIGHT = vec3(…)`."),
    _shader_rule("shader_alpha_scissor", "ALPHA_SCISSOR", "ALPHA_SCISSOR_THRESHOLD",
                 r"\bALPHA_SCISSOR\b",
                 "`ALPHA_SCISSOR` was renamed in Godot 4.x." + _SHADER_REMOVED,
                 "`ALPHA_SCISSOR = 0.5;` -> `ALPHA_SCISSOR_THRESHOLD = 0.5;`."),
    _shader_rule("shader_normalmap", "NORMALMAP", "NORMAL_MAP",
                 r"\bNORMALMAP\b",
                 "`NORMALMAP` was renamed in Godot 4.x, in both spatial and canvas_item "
                 "shaders." + _SHADER_REMOVED,
                 "`NORMALMAP` -> `NORMAL_MAP`."),
    _shader_rule("shader_normalmap_depth", "NORMALMAP_DEPTH", "NORMAL_MAP_DEPTH",
                 r"\bNORMALMAP_DEPTH\b",
                 "`NORMALMAP_DEPTH` was renamed in Godot 4.x." + _SHADER_REMOVED,
                 "`NORMALMAP_DEPTH` -> `NORMAL_MAP_DEPTH`."),
    _shader_rule("shader_side", "SIDE", "FRONT_FACING",
                 r"\bSIDE\b",
                 "The spatial built-in `SIDE` was renamed in Godot 4.x." + _SHADER_REMOVED,
                 "`SIDE` -> `FRONT_FACING` (still a bool: true on front faces).",
                 suppress_if_declared="SIDE"),
    _shader_rule("shader_clearcoat_gloss", "CLEARCOAT_GLOSS", "CLEARCOAT_ROUGHNESS",
                 r"\bCLEARCOAT_GLOSS\b",
                 "`CLEARCOAT_GLOSS` was renamed *and inverted* in Godot 4.x." + _SHADER_REMOVED,
                 "`CLEARCOAT_GLOSS = g;` -> `CLEARCOAT_ROUGHNESS = 1.0 - g;` — it is roughness "
                 "now, so the value has to be flipped, not just renamed."),
    _shader_rule("shader_shadow_attenuation", "SHADOW_ATTENUATION", "ATTENUATION",
                 r"\bSHADOW_ATTENUATION\b",
                 "`SHADOW_ATTENUATION` was removed from `light()` in Godot 4.x."
                 + _SHADER_REMOVED,
                 "`SHADOW_ATTENUATION` -> `ATTENUATION`, which in 4.x already has the shadow "
                 "factor folded in. (`ATTENUATION` itself is still valid 4.7 and is not "
                 "reported.)"),
    _shader_rule("shader_light_height", "LIGHT_HEIGHT", "LIGHT_VERTEX.z",
                 r"\bLIGHT_HEIGHT\b",
                 "The canvas_item `LIGHT_HEIGHT` built-in was removed in Godot 4.x."
                 + _SHADER_REMOVED,
                 "Set `LIGHT_VERTEX.z` in `fragment()` instead (`LIGHT_VERTEX.z = 8.0;`) — the "
                 "2D light height is the z of LIGHT_VERTEX now."),
    _shader_rule("shader_modulate", "MODULATE", "uniform vec4 : source_color",
                 r"\bMODULATE\b",
                 "`MODULATE` does not exist in a Godot 4.7 canvas_item shader — verified in "
                 "`vertex()`, `fragment()` and `light()`, all three report `Unknown identifier "
                 "in expression: 'MODULATE'`. (It reads like current API because other engines "
                 "and some 4.x docs mention it; 4.7 does not have it.)" + _SHADER_REMOVED,
                 "Pass the colour in yourself: `uniform vec4 modulate_color : source_color = "
                 "vec4(1.0);` plus `COLOR *= modulate_color;`, and set it from GDScript with "
                 "`material.set_shader_parameter(\"modulate_color\", c)`. The node's own "
                 "`modulate` is already multiplied into the canvas_item `COLOR` you get in "
                 "`fragment()`.",
                 suppress_if_declared="MODULATE"),
    _shader_rule("shader_depth_draw_alpha_prepass", "render_mode depth_draw_alpha_prepass",
                 "depth_prepass_alpha",
                 r"\bdepth_draw_alpha_prepass\b",
                 "The `depth_draw_alpha_prepass` render mode was renamed in Godot 4.x "
                 "(`Invalid render mode`)." + _SHADER_REMOVED,
                 "`render_mode depth_draw_alpha_prepass;` -> `render_mode depth_prepass_alpha;`. "
                 "`depth_draw_opaque` and `depth_draw_never` keep their names."),
    _shader_rule("shader_depth_test_disable", "render_mode depth_test_disable",
                 "depth_test_disabled",
                 r"\bdepth_test_disable\b(?!d)",
                 "The `depth_test_disable` render mode gained a `d` in Godot 4.x "
                 "(`Invalid render mode: 'depth_test_disable'`)." + _SHADER_REMOVED,
                 "`render_mode depth_test_disable;` -> `render_mode depth_test_disabled;`."),
    _shader_rule("shader_async_render_mode", "render_mode async_visible", "(delete it)",
                 r"\basync_(?:visible|hidden)\b",
                 "The `async_visible` / `async_hidden` render modes were removed in Godot 4.x."
                 + _SHADER_REMOVED,
                 "Delete the render mode. Shader compilation is handled by the engine in 4.x "
                 "(`rendering/shader_compiler/shader_cache`)."),
]

# Not a text pattern — the file *name*. Godot 4 has no importer for `.shader`, so
# the file is inert: `load("res://x.shader")` returns null and the material stays
# empty. Reported from the file walk; listed here so it reaches the rule table.
SHADER_EXTENSION_RULE = _rule(
    "shader_file_extension", ".shader (file extension)", ".gdshader", GROUP_SHADERS, "error",
    r"\.shader$",
    "`.shader` is the Godot 3 shader file extension. Godot 4 only imports `.gdshader` "
    "(and `.gdshaderinc`), so this file is never loaded as a shader at all.",
    "Rename the file to `.gdshader` and update every `res://…` reference to it "
    "(scripts/project/move_resource.py does both in one step).",
    scope="filename", category="godot3_shader")
SHADER_RULES.append(SHADER_EXTENSION_RULE)

GODOT3_RULES += SHADER_RULES

for _rule_entry in GODOT3_RULES:
    _rule_entry["gd_regex"] = (
        re.compile(_rule_entry["pattern"]) if _rule_entry["scope"] in ("gd", "both") else None
    )
    _rule_entry["scene_regex"] = (
        re.compile(_rule_entry["scene_pattern"] or _rule_entry["pattern"])
        if _rule_entry["scope"] in ("scene", "both") else None
    )
    _rule_entry["shader_regex"] = (
        re.compile(_rule_entry["pattern"]) if _rule_entry["scope"] == "shader" else None
    )

# Fast reject. Nearly every line matches no rule at all, so before running ~90
# regexes we test one alternation of the literal words those patterns require
# (`onready`, `KinematicBody2D`, `margin_`, `Color`, ...). Literal alternation is
# ~8x faster than the same alternation built from the real patterns, whose
# lookbehinds and character classes backtrack: on a 30k-line project the real
# patterns cost 1.0s as a prefilter, the literals 0.12s.
#
# Correctness rests on every pattern containing at least one literal run of four
# or more word characters that it *requires* (checked below); a rule that has
# none is simply always evaluated.
_CORE = re.compile(r"[A-Za-z_][A-Za-z_0-9]{3,}")
# Escape sequences must go first: in the pattern *source* `\bemit_signal` the `b`
# of `\b` is a word character, so a naive scan reads the core as "bemit_signal"
# and the prefilter then rejects every line that really does contain
# `emit_signal`. (Caught by the equivalence check in tests/test_lint_project.py,
# which runs every rule with and without the prefilter and diffs the results.)
_ESCAPE = re.compile(r"\\.")


def _prefilter(rules: list[dict], key: str) -> tuple[Optional["re.Pattern[str]"], list[dict]]:
    cores: set[str] = set()
    always: list[dict] = []
    for rule in rules:
        found = set(_CORE.findall(_ESCAPE.sub(" ", rule[key] or rule["pattern"])))
        if found:
            cores |= found
        else:
            always.append(rule)
    if not cores:
        return None, rules
    return re.compile("|".join(sorted(cores, key=len, reverse=True))), always


_GD_ANY, _GD_ALWAYS = _prefilter(
    [rule for rule in GODOT3_RULES if rule["gd_regex"] is not None], "pattern")
_SCENE_ANY, _SCENE_ALWAYS = _prefilter(
    [rule for rule in GODOT3_RULES if rule["scene_regex"] is not None], "scene_pattern")
_SHADER_RULES_ACTIVE = [rule for rule in GODOT3_RULES if rule["shader_regex"] is not None]
_SHADER_ANY, _SHADER_ALWAYS = _prefilter(_SHADER_RULES_ACTIVE, "pattern")

# `:=` right-hand sides that Godot cannot statically type. Same table shape.
# `:=` right-hand sides Godot cannot statically type. Keyed by rule id; the
# match is not a regex — `classify_rhs()` below parses the *outermost* expression
# of the right-hand side and returns one of these ids (or None).
#
# Outermost is the whole point. `var save_path := _normalize_res_path(params.get("p", ""))`
# is perfectly typed: the value that lands in the variable is whatever
# `_normalize_res_path()` declares (`-> String`), and the `.get()` inside it is
# somebody else's argument. A rule that matched `.get(` anywhere on the line
# reported 143 failures on this skill's own scripts, which Godot compiles clean.
PARSE_ERROR_TAIL = (
    "Godot refuses to parse this — `Parse Error: Cannot infer the type of \"x\" variable because "
    "the value doesn't have a set type.` (`inference_on_variant` ships set to error) — so the "
    "script never loads and every scene using it comes up broken."
)
WIDE_TYPE_TAIL = (
    " In a project that raises `unsafe_property_access` / `unsafe_method_access` it becomes a "
    "parse error as well."
)

INFERENCE_RULES: dict[str, dict] = {
    # --- error: Godot refuses to parse the file ----------------------------
    "infer_get": {
        "severity": "error",
        "message": "`:=` from `.get()`, which is declared to return Variant. " + PARSE_ERROR_TAIL,
        "fix": "Annotate and convert: `var hp: int = int(data.get(\"hp\", 0))`, "
               "`var name: String = str(data.get(\"name\", \"\"))`.",
    },
    "infer_subscript": {
        "severity": "error",
        "message": "`:=` from a `[...]` read on an untyped `Array`/`Dictionary`, whose elements "
                   "are Variant. " + PARSE_ERROR_TAIL,
        "fix": "Annotate and convert: `var hp: int = int(data[\"hp\"])`. Or give the collection an "
               "element type at its declaration (`var items: Array[Enemy] = []`), after which "
               "`:=` on a read from it works. A typed packed array "
               "(`PackedFloat32Array`/`PackedByteArray`/...), an `Array[T]`, a "
               "`Dictionary[K, V]` and a `String` all carry an element type already and are not "
               "reported.",
    },
    "infer_json": {
        "severity": "error",
        "message": "`:=` from `JSON.parse_string()`, which is declared to return Variant. "
                   + PARSE_ERROR_TAIL,
        "fix": "`var raw: Variant = JSON.parse_string(text)` then narrow it: "
               "`var data: Dictionary = raw if raw is Dictionary else {}`.",
    },
    "infer_null": {
        "severity": "error",
        "message": "`:=` from `null`, which has no type at all. Godot refuses to parse this — "
                   "`Parse Error: Cannot infer the type of \"x\" variable because the value is "
                   "\"null\".` (In a ternary, `something_typed() if c else null` is fine — an "
                   "object type absorbs null — and is not reported.)",
        "fix": "Name the type: `var target: Node2D = null`, `var tween: Tween = null`.",
    },
    "infer_call": {
        "severity": "error",
        "message": "`:=` from `Callable.call()`, which is declared to return Variant. "
                   + PARSE_ERROR_TAIL,
        "fix": "Annotate the variable with the type the callable actually returns, or call the "
               "method directly instead of through a Callable.",
    },
    "infer_untyped_call": {
        "severity": "error",
        "message": "`:=` from a function in this file that declares no return type, so it returns "
                   "Variant. " + PARSE_ERROR_TAIL,
        "fix": "Add the return type to that function (`func helper() -> int:`) — the better fix, "
               "since it types every other call site too — or annotate here: "
               "`var value: int = helper()`.",
    },
    # --- warning: compiles, but the static type is uselessly wide ----------
    # Verified on godot 4.7: `var a := $Child` / `%Unique` / `get_node(...)` /
    # `scene.instantiate()` all COMPILE with no diagnostic. They infer `Node`,
    # which is the problem — not a parse failure.
    "infer_dollar": {
        "severity": "warning",
        "message": "`:=` from `$NodePath` compiles, but infers the bare type `Node`. Every later "
                   "member access on the variable (`.text`, `.play()`, `.disabled`) is then "
                   "unchecked at compile time and only fails at runtime — a typo'd method name "
                   "reports nothing until that line executes." + WIDE_TYPE_TAIL,
        "fix": "Annotate with the node's real class: `var label: Label = $Panel/Label`, "
               "`@onready var body: CharacterBody2D = $Body`.",
    },
    "infer_unique": {
        "severity": "warning",
        "message": "`:=` from `%UniqueName` compiles, but infers the bare type `Node`, so every "
                   "later member access on the variable is unchecked and only fails at runtime."
                   + WIDE_TYPE_TAIL,
        "fix": "Annotate with the node's real class: `@onready var hud: Control = %Hud`.",
    },
    "infer_get_node": {
        "severity": "warning",
        "message": "`:=` from `get_node()` / `get_node_or_null()` compiles, but infers the bare "
                   "type `Node`, so every later member access on the variable is unchecked and "
                   "only fails at runtime." + WIDE_TYPE_TAIL,
        "fix": "Annotate with the node's real class: `var timer: Timer = get_node(\"Timer\")`.",
    },
    "infer_instantiate": {
        "severity": "warning",
        "message": "`:=` from `PackedScene.instantiate()` compiles, but infers the bare type "
                   "`Node`, so every later member access on the variable is unchecked and only "
                   "fails at runtime." + WIDE_TYPE_TAIL,
        "fix": "Cast to the scene root's class and guard: "
               "`var enemy := ENEMY_SCENE.instantiate() as Enemy` then `if enemy == null: return`.",
    },
}

# Global functions whose return type is concrete, so `:=` on them is fine. Calls
# to anything else that is not defined in the same file are left alone: Godot's
# own analyzer catches a real Variant, and a false alarm costs a weak model more
# than a miss.
TYPED_WRAPPERS = frozenset("""
str int float bool StringName NodePath Vector2 Vector2i Vector3 Vector3i Vector4 Vector4i
Color Rect2 Rect2i Transform2D Transform3D Basis Quaternion AABB Plane Array Dictionary
PackedByteArray PackedInt32Array PackedInt64Array PackedFloat32Array PackedFloat64Array
PackedStringArray PackedVector2Array PackedVector3Array PackedColorArray
clampi clampf maxi mini maxf minf absi absf roundi floori ceili snappedi snappedf
len typeof sign signi signf snapped lerp lerpf is_instance_valid
""".split())

def _guard_lowercase_receiver(line: str, match: "re.Match[str]") -> bool:
    """False when the matched `.method()` hangs off a Capitalised identifier.

    `LegacySystem.empty()` and `Exporter.instance()` are static calls on a
    project's own type, not the removed engine methods of the same name.
    """
    prefix = line[:match.start()].rstrip()
    name = re.search(r"([A-Za-z_]\w*)$", prefix)
    return not (name and name.group(1)[0].isupper())


GUARDS = {"lowercase_receiver": _guard_lowercase_receiver}


# ---------------------------------------------------------------------------
# Cross-reference tables (input actions, groups, res:// paths, animations)
# ---------------------------------------------------------------------------

# The actions a *stock* 4.7 project already has, with no [input] section at all.
# Not guessed: printed from the engine with
#   godot --headless --path <empty project> --script print_actions.gd
# where the script does `for a in InputMap.get_actions(): print(a)`. That run
# returned 91 names on macOS, 72 of them distinct once the platform-tagged
# variants (`ui_close_dialog.macos`, `ui_text_caret_word_left.macos`, ...) are
# folded into their base name. Only the base names are stored: the `.macos`
# spellings exist only on macOS, while every base exists everywhere, so a lint
# built on the bases gives the same answer on every host.
BUILTIN_INPUT_ACTIONS = frozenset("""
ui_accept ui_accessibility_drag_and_drop ui_cancel ui_close_dialog
ui_colorpicker_delete_preset ui_copy ui_cut ui_down ui_end ui_filedialog_delete
ui_filedialog_find ui_filedialog_focus_path ui_filedialog_refresh ui_filedialog_show_hidden
ui_filedialog_up_one_level ui_focus_mode ui_focus_next ui_focus_prev ui_graph_delete
ui_graph_duplicate ui_graph_follow_left ui_graph_follow_right ui_home ui_left ui_menu
ui_page_down ui_page_up ui_paste ui_redo ui_right ui_select ui_swap_input_direction
ui_text_add_selection_for_next_occurrence ui_text_backspace ui_text_backspace_all_to_left
ui_text_backspace_word ui_text_caret_add_above ui_text_caret_add_below
ui_text_caret_document_end ui_text_caret_document_start ui_text_caret_down
ui_text_caret_left ui_text_caret_line_end ui_text_caret_line_start ui_text_caret_page_down
ui_text_caret_page_up ui_text_caret_right ui_text_caret_up ui_text_caret_word_left
ui_text_caret_word_right ui_text_clear_carets_and_selection ui_text_completion_accept
ui_text_completion_query ui_text_completion_replace ui_text_dedent ui_text_delete
ui_text_delete_all_to_right ui_text_delete_word ui_text_indent ui_text_newline
ui_text_newline_above ui_text_newline_blank ui_text_scroll_down ui_text_scroll_up
ui_text_select_all ui_text_select_word_under_caret
ui_text_skip_selection_for_next_occurrence ui_text_submit ui_text_toggle_insert_mode ui_undo
ui_unicode_start ui_up
""".split())

# method name -> indices of the arguments that are action names. Methods only
# reachable through the `Input` / `InputMap` singletons are listed separately so
# a project's own `get_axis(a, b)` helper never trips the check.
_INPUT_SINGLETON_ACTION_ARGS = {
    "is_action_pressed": (0,), "is_action_just_pressed": (0,),
    "is_action_just_released": (0,), "is_action_released": (0,),
    "get_action_strength": (0,), "get_action_raw_strength": (0,),
    "action_press": (0,), "action_release": (0,),
    "get_axis": (0, 1), "get_vector": (0, 1, 2, 3),
}
_INPUTMAP_ACTION_ARGS = {
    "erase_action": (0,), "action_erase_events": (0,),
    "action_add_event": (0,), "action_erase_event": (0,), "action_has_event": (0,),
    "action_set_deadzone": (0,), "action_get_deadzone": (0,), "action_get_events": (0,),
}
# `InputMap.has_action("look_left")` is a *probe*: the code is written to cope
# with the action being absent (templates/gdscript/player_third_person_3d.gd
# gates its whole gamepad-look block on four of them). Once a project probes an
# action, every use of that action anywhere goes unreported.
_INPUTMAP_PROBES = ("has_action",)
# Reachable on any object (`event.is_action_pressed("jump")`). A project that
# defines a method of the same name owns it and is not checked.
_ANY_RECEIVER_ACTION_ARGS = {
    "is_action": (0,), "is_action_pressed": (0,), "is_action_released": (0,),
    "is_action_just_pressed": (0,), "is_action_just_released": (0,),
}

# method name -> index of the group-name argument. The `_flags` variants take the
# flags first, so the name is argument 1, not 0.
_GROUP_ARG = {
    "get_nodes_in_group": 0, "get_first_node_in_group": 0, "is_in_group": 0,
    "call_group": 0, "notify_group": 0, "set_group": 0,
    "call_group_flags": 1, "notify_group_flags": 1, "set_group_flags": 1,
}
_GROUP_PROVIDERS = {"add_to_group": 0}

_METHOD_CALL = re.compile(r"(?:(?P<recv>[A-Za-z_]\w*)\s*\.\s*)?(?P<name>[A-Za-z_]\w*)\s*\(")
# Same prefilter idea as _GD_ANY: almost no line calls one of these, and testing
# one literal alternation is far cheaper than scanning every call on every line.
_CALL_NAMES_ANY = re.compile("|".join(sorted(
    set(_INPUT_SINGLETON_ACTION_ARGS) | set(_INPUTMAP_ACTION_ARGS)
    | set(_ANY_RECEIVER_ACTION_ARGS) | set(_GROUP_ARG) | set(_GROUP_PROVIDERS)
    | {"add_action", "has_action"}, key=len, reverse=True)))
# And likewise for the probe/write forms `collect_res_literals` looks for on a
# line that carries no string at all.
_PATH_CONTEXT_ANY = re.compile(
    r"exists|resource_path|take_over_path|remove_absolute|ResourceUID|res://")
# `FileAccess.open(path, FileAccess.WRITE)` and friends create the file, so the
# path not existing yet is the normal case, never a finding.
_WRITE_MODE = re.compile(r"\b(?:WRITE|WRITE_READ|READ_WRITE)\b")
_WRITE_CALL = re.compile(
    r"(?:ResourceSaver\s*\.\s*save|DirAccess\s*\.\s*(?:make_dir\w*|copy_absolute"
    r"|rename_absolute)|\.\s*save)\s*\(")
# Asking whether a path exists is not a claim that it does. Neither is giving an
# in-memory resource a name (`script.resource_path = "res://__snippet.gd"`).
_PROBE_CALL = re.compile(
    r"(?:file_exists|dir_exists\w*|\bResourceLoader\s*\.\s*exists|remove_absolute"
    r"|\bResourceUID\b)\s*\(|\b(?:resource_path|take_over_path)\b")
# A res:// literal handed to a String method is text being sliced, not a path
# being opened: `path.begins_with("res://addons/")`.
_STRING_METHOD_ARG = re.compile(
    r"\.\s*(?:begins_with|ends_with|trim_prefix|trim_suffix|contains|containsn|replace|replacen"
    r"|split|rsplit|count|countn|find|findn|rfind|similarity|match|matchn|is_subsequence_of"
    r"|is_subsequence_ofn|path_join|erase|lstrip|rstrip|substr|insert|format)\s*\(\s*$")
# A res:// literal holding a placeholder is a template, not a path.
_FORMAT_MARKER = re.compile(r"%[sdxfvc0-9]|\{\d*\}|\{[A-Za-z_]|<[A-Za-z_]")
_NODE_EXPR = r"(?:\$%?[A-Za-z_][\w/]*|%[A-Za-z_]\w*)"
# `$Sprite.play("walk")` and `anim.play("walk")` — the second only resolves when
# `anim` is an @onready binding (see ScriptInfo.binding_target).
_ANIM_SUBJECT = r"(?P<node>" + _NODE_EXPR + r"|(?<![\w.$%])[A-Za-z_]\w*)"
_ANIM_METHODS = "play|play_backwards|queue"
_ANIM_PROPERTIES = "animation|autoplay|current_animation"
_ANIM_PLAY = re.compile(
    _ANIM_SUBJECT + r"\s*\.\s*(?P<method>" + _ANIM_METHODS + r")\s*\(\s*&?(?P<quote>\")")
_ANIM_ASSIGN = re.compile(
    _ANIM_SUBJECT + r"\s*\.\s*(?P<method>" + _ANIM_PROPERTIES + r")\s*=\s*&?(?P<quote>\")")
_ANIMATED_SPRITE_TYPES = ("AnimatedSprite2D", "AnimatedSprite3D")
# Same prefilter idea as _GD_ANY. The subject of an animation call can now be a
# bare identifier, so these two patterns would otherwise be tried at every word
# of every line; `play|queue|animation|autoplay` rejects nearly all of them
# first (`play_backwards` contains `play`, `current_animation` contains
# `animation`).
_ANIM_ANY = re.compile(r"play|queue|animation|autoplay")
# A plain `name = value` statement (not `==`, not a declaration, not `a.b = c`).
_ASSIGNMENT = re.compile(r"^\s*(?P<name>[A-Za-z_]\w*)\s*(?:[-+*/%|&^]|\*\*|<<|>>)?=(?!=)")
_FOR_VAR = re.compile(r"^\s*for\s+([A-Za-z_]\w*)\b")
# The right-hand side of an @onready binding: one node lookup and nothing else.
_BINDING_DOLLAR = re.compile(r"^(?P<path>" + _NODE_EXPR + r")\s*$")
_BINDING_GET_NODE = re.compile(
    r"^get_node(?:_or_null)?\s*\(\s*(?:NodePath\s*\(\s*)?(?P<quote>\")")


def node_expression(offset: int, rhs: str, strings: dict[int, str]) -> Optional[str]:
    """`$Path` / `%Name` / `get_node("Path")` as a `$`-style path, else None.

    `offset` is where `rhs` starts inside the scrubbed line, so a `get_node()`
    literal can be recovered from `strings`. A trailing `as Type` is fine — it
    narrows the static type and changes nothing about which node this is.
    """
    text = rhs.strip()
    start = offset + (len(rhs) - len(rhs.lstrip()))
    cast = re.search(r"\s+as\s+[\w.]+\s*$", text)
    if cast:
        text = text[:cast.start()]
    direct = _BINDING_DOLLAR.match(text)
    if direct:
        return direct.group("path")
    call = _BINDING_GET_NODE.match(text)
    if call and text.rstrip().endswith(")"):
        literal = strings.get(start + call.start("quote"))
        if literal and not literal.startswith("/") and not any(
                token in literal for token in _DYNAMIC):
            return "$" + literal
    return None

# `# lint:ignore node_ref,inference` — on the offending line or the line above.
# `#` is GDScript, `;` is .tscn/.tres/project.godot, `//` is .gdshader.
_SUPPRESS = re.compile(r"(?:#|;|//)\s*lint:ignore\b(?P<cats>[\w,\s]*)")

# A shader may legitimately declare an identifier a rule is about — the engine's
# own SCREEN_TEXTURE migration note tells you to write
# `uniform sampler2D SCREEN_TEXTURE : hint_screen_texture;`.
_SHADER_DECL = re.compile(
    r"\b(?:uniform|varying|const|#define)\s+(?:\w+\s+)*?(?P<name>[A-Za-z_]\w*)\s*(?=[:=;,\[])")
_SHADER_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)


def strip_shader_comments(text: str) -> str:
    """Blank `//` and `/* */` comments, keeping line count and column offsets."""
    text = _SHADER_BLOCK_COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)
    out: list[str] = []
    for line in text.split("\n"):
        position = line.find("//")
        out.append(line[:position] + " " * (len(line) - position) if position >= 0 else line)
    return "\n".join(out)


def split_call_args(text: str, open_paren: int) -> list[tuple[int, str]]:
    """Top-level arguments of the call whose `(` is at `open_paren`.

    Returns [(index of the argument's first character, argument text)]. An
    unbalanced line yields [] — the call continues on the next physical line and
    this analysis is line-based.
    """
    args: list[tuple[int, str]] = []
    depth = 0
    quote = ""
    start = open_paren + 1
    index = open_paren
    while index < len(text):
        char = text[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in "\"'":
            quote = char
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                args.append((start, text[start:index]))
                return args
        elif char == "," and depth == 1:
            args.append((start, text[start:index]))
            start = index + 1
        index += 1
    return []


def literal_argument(arg_start: int, arg_text: str, strings: dict[int, str]) -> Optional[str]:
    """The string literal an argument consists of, or None when it is anything else.

    `&"jump"` (a StringName literal) counts; `name`, `NAMES[0]` and — the one
    that bites — `"pre" + "fix"` do not. The last is why the length is checked
    instead of just the first and last characters: that expression also starts
    and ends with a quote, and reading its first literal would report the action
    `pre`.
    """
    stripped = arg_text.lstrip()
    offset = arg_start + (len(arg_text) - len(stripped))
    if stripped.startswith("&"):
        offset += 1
        stripped = stripped[1:]
    stripped = stripped.rstrip()
    if len(stripped) < 2 or not stripped.startswith('"') or not stripped.endswith('"'):
        return None
    content = strings.get(offset)
    # `scrub_line` blanks the content to spaces of the same length, so a single
    # literal is exactly quote + content + quote and nothing more.
    if content is None or len(stripped) != len(content) + 2:
        return None
    return content


def nearest_names(name: str, candidates: Iterable[str], limit: int = 3) -> list[str]:
    """The closest known names, for the fix text. Prefix matches count as close."""
    pool = sorted(set(candidates))
    close = difflib.get_close_matches(name, pool, n=limit, cutoff=0.6)
    lowered = name.lower()
    for candidate in pool:
        if len(close) >= limit:
            break
        if candidate not in close and (candidate.lower().startswith(lowered)
                                       or lowered.startswith(candidate.lower())):
            close.append(candidate)
    return close


def listed(names: Iterable[str], limit: int = 20) -> str:
    items = sorted(set(names))
    if not items:
        return "(none)"
    shown = ", ".join(items[:limit])
    return shown + (f", ... (+{len(items) - limit} more)" if len(items) > limit else "")


_IDENT = re.compile(r"[A-Za-z_]\w*")
# Binary operators whose result type comes from the operands.
_ARITH = "+-*/%"
# Operators whose result is a bool, whatever the operands are.
_BOOL_OPS = (" and ", " or ", " in ", " is ", "==", "!=", "<=", ">=", "<", ">")


def _scan(text: str) -> Optional[tuple[list[int], list[bool]]]:
    """Per-character bracket depth and in-string flag.

    Returns None when brackets or quotes do not balance — which usually means the
    statement continues on the next line. The caller then gives up rather than
    guessing, because this analysis is line-based.
    """
    depths: list[int] = []
    strings: list[bool] = []
    depth = 0
    quote = ""
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if quote:
            depths.append(depth)
            strings.append(True)
            if char == "\\" and index + 1 < length:
                depths.append(depth)
                strings.append(True)
                index += 2
                continue
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in "\"'":
            quote = char
            depths.append(depth)
            strings.append(True)
            index += 1
            continue
        if char in "([{":
            depths.append(depth)
            strings.append(False)
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth < 0:
                return None
            depths.append(depth)
            strings.append(False)
        else:
            depths.append(depth)
            strings.append(False)
        index += 1
    if depth != 0 or quote:
        return None
    return depths, strings


def _find_top(text: str, depths: list[int], strings: list[bool], needle: str) -> int:
    start = 0
    while True:
        found = text.find(needle, start)
        if found < 0:
            return -1
        if depths[found] == 0 and not strings[found]:
            return found
        start = found + 1


def _match_bracket(text: str, depths: list[int], strings: list[bool], start: int) -> int:
    closer = {"(": ")", "[": "]", "{": "}"}[text[start]]
    for index in range(start + 1, len(text)):
        if text[index] == closer and not strings[index] and depths[index] == depths[start]:
            return index
    return -1


def _first_top_arith(text: str, depths: list[int], strings: list[bool]) -> Optional[int]:
    """Position of the first top-level arithmetic/concatenation operator, if any.

    Index 0 never counts: a leading `-`/`+` is a sign and a leading `%` is a
    unique-name reference, not modulo.
    """
    for index in range(1, len(text)):
        if strings[index] or depths[index] != 0 or text[index] not in _ARITH:
            continue
        before = text[:index].rstrip()
        if not before or before[-1] in "+-*/%=<>!,([{":
            continue          # unary sign, or the operator of an operator pair
        return index
    return None


def _parse_chain(text: str, depths: list[int], strings: list[bool]
                 ) -> Optional[tuple[str, list[tuple[str, str]]]]:
    """Split `a.b(c)[d]` into ("a", [("attr","b"), ("call","c"), ("index","d")]).

    Returns None when the text is not a plain postfix chain on an identifier.
    """
    head = _IDENT.match(text)
    if not head or head.start() != 0:
        return None
    position = head.end()
    suffixes: list[tuple[str, str]] = []
    while position < len(text):
        char = text[position]
        if char == ".":
            name = _IDENT.match(text, position + 1)
            if not name:
                return None
            suffixes.append(("attr", name.group(0)))
            position = name.end()
            continue
        if char in "([":
            close = _match_bracket(text, depths, strings, position)
            if close < 0:
                return None
            kind = "call" if char == "(" else "index"
            suffixes.append((kind, text[position + 1:close]))
            position = close + 1
            continue
        if char == " ":
            position += 1
            continue
        return None
    return head.group(0), suffixes


def _join_header(scrubbed: list[tuple[str, dict]], index: int, limit: int = 12) -> str:
    """The logical line at `index`, joining a wrapped parameter list.

    A signature such as

        func _label(text_value: String, font_size: int,
                alignment := HORIZONTAL_ALIGNMENT_LEFT) -> Label:

    carries its `-> Label` on the *second* physical line. Reading only the first
    one says "no declared return type" and makes every `var x := _label(...)`
    a false parse error.
    """
    line = scrubbed[index][0]
    if _bracket_delta(line) <= 0:
        return line
    parts = [line]
    depth = _bracket_delta(line)
    for offset in range(1, limit + 1):
        if index + offset >= len(scrubbed):
            break
        nxt = scrubbed[index + offset][0]
        parts.append(nxt.strip())
        depth += _bracket_delta(nxt)
        if depth <= 0:
            break
    return " ".join(parts)


def _bracket_delta(line: str) -> int:
    """Net `([{` minus `)]}` at depth 0, ignoring string contents."""
    delta = 0
    quote = ""
    for char in line:
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in "\"'":
            quote = char
        elif char in "([{":
            delta += 1
        elif char in ")]}":
            delta -= 1
    return delta


def _split_params(text: str) -> list[str]:
    """Parameter list out of a `func f(a: int, b = [1, 2]) -> void:` header.

    `text` is everything after the opening paren, so the scan stops at the first
    unmatched `)`.
    """
    params: list[str] = []
    current: list[str] = []
    depth = 0
    quote = ""
    for char in text:
        if quote:
            current.append(char)
            if char == quote:
                quote = ""
            continue
        if char in "\"'":
            quote = char
            current.append(char)
            continue
        if char in "([{":
            depth += 1
            current.append(char)
            continue
        if char in ")]}":
            if char == ")" and depth == 0:
                break
            depth -= 1
            current.append(char)
            continue
        if char == "," and depth == 0:
            params.append("".join(current))
            current = []
            continue
        current.append(char)
    params.append("".join(current))
    return [param for param in (item.strip() for item in params) if param]


def _classify_method(method: str, receiver: Optional[str]) -> Optional[str]:
    if method == "new":
        return None                                   # a constructor is concrete
    if method == "instantiate":
        return "infer_instantiate"
    if method in ("get_node", "get_node_or_null"):
        return "infer_get_node"
    if method == "parse_string" and receiver == "JSON":
        return "infer_json"
    if method == "get":
        return "infer_get"
    if method == "call":
        return "infer_call"
    return None


def classify_rhs(expr: str, script: "ScriptInfo", depth: int = 0) -> Optional[str]:
    """Rule id for the type of the *outermost* expression of `expr`, or None.

    None means "this has a concrete static type, or we cannot prove that it does
    not" — the second half is deliberate. Only the constructs listed in
    INFERENCE_RULES are reported.
    """
    expr = expr.strip()
    if not expr or depth > 8:
        return None
    scan = _scan(expr)
    if scan is None:
        return None
    depths, strings = scan

    if expr.startswith("await ") and not strings[0]:
        return classify_rhs(expr[6:], script, depth + 1)

    ternary = _find_top(expr, depths, strings, " if ")
    otherwise = _find_top(expr, depths, strings, " else ")
    if ternary > 0 and otherwise > ternary:
        left = classify_rhs(expr[:ternary], script, depth + 1)
        right = classify_rhs(expr[otherwise + 6:], script, depth + 1)
        # `var n := world.general(id) if id != "" else null` compiles: Node2D and
        # null unify to Node2D. (`var c := 1 if flag else null` really is a parse
        # error — int does not — but telling those apart needs the other branch's
        # type, which this analysis does not have. Both verified on godot 4.7;
        # the silent case is the common one, so a null branch beside a typed
        # branch is not reported.)
        if left == "infer_null" and right is None:
            return None
        if right == "infer_null" and left is None:
            return None
        return left or right

    if expr[0] == "(" and not strings[0] and _match_bracket(expr, depths, strings, 0) == len(expr) - 1:
        return classify_rhs(expr[1:-1], script, depth + 1)

    if _find_top(expr, depths, strings, " as ") > 0:
        return None                                   # `x as T` narrows exactly
    for token in _BOOL_OPS:
        if _find_top(expr, depths, strings, token) > 0:
            return None                               # comparison / logic -> bool
    if expr.startswith("not "):
        return None

    operator = _first_top_arith(expr, depths, strings)
    if operator is not None:
        # Concatenation and arithmetic take their type from the operands; the
        # first one decides ("PREFIX_" + str(x) is a String).
        return classify_rhs(expr[:operator], script, depth + 1)

    if strings[0]:
        return None                                   # string literal
    first = expr[0]
    if first == "$":
        return "infer_dollar"
    if first == "%":
        return "infer_unique"
    if first in "[{":
        return None                                   # Array / Dictionary literal
    if first in "-+~":
        return classify_rhs(expr[1:], script, depth + 1)
    if first.isdigit() or (first == "." and expr[1:2].isdigit()):
        return None
    if expr in ("true", "false"):
        return None
    if expr == "null":
        return "infer_null"

    chain = _parse_chain(expr, depths, strings)
    if chain is None:
        return None
    base, suffixes = chain
    if not suffixes:
        return None                                   # a bare identifier or constant
    kind, _value = suffixes[-1]
    if kind == "attr":
        return None                                   # property read
    if kind == "index":
        # Only a bare `name[...]` whose declaration in this file is provably
        # untyped: `var x = ...`, `var x: Array`, `var x: Dictionary`, or an
        # unannotated parameter. `corners: Array[Color]` and PackedVector2Array
        # both carry an element type and infer fine.
        if (len(suffixes) == 1 and base in script.untyped_names
                and base not in script.typed_names):
            return "infer_subscript"
        return None
    if len(suffixes) >= 2 and suffixes[-2][0] == "attr":
        receiver = base if len(suffixes) == 2 else None
        return _classify_method(suffixes[-2][1], receiver)
    if base in ("get_node", "get_node_or_null"):
        return "infer_get_node"
    if base in TYPED_WRAPPERS or base[0].isupper():
        return None                                   # Vector2(...), Color(...), Foo(...)
    if base in script.func_returns and not script.func_returns[base]:
        return "infer_untyped_call"
    return None


# ---------------------------------------------------------------------------
# GDScript line scrubbing
# ---------------------------------------------------------------------------

def scrub_line(line: str) -> tuple[str, dict[int, str]]:
    """Return (line with `#` comments removed and string contents blanked,
    {index of opening quote: original string content}).

    Quotes are kept in place and inner characters replaced with spaces, so
    column offsets survive and a lookbehind can still tell `"%s" % x` (modulo)
    from `= %Label` (a unique-name node reference). Multi-line (triple-quoted)
    strings are not tracked — an unterminated string simply blanks the rest of
    its own line.
    """
    out: list[str] = []
    strings: dict[int, str] = {}
    index = 0
    length = len(line)
    while index < length:
        char = line[index]
        if char == "#":
            break
        if char in "\"'":
            quote = char
            start = index
            index += 1
            content: list[str] = []
            while index < length:
                if line[index] == "\\" and index + 1 < length:
                    content.append(line[index:index + 2])
                    index += 2
                    continue
                if line[index] == quote:
                    break
                content.append(line[index])
                index += 1
            text = "".join(content)
            strings[start] = text
            out.append(quote + " " * len(text))
            if index < length:
                out.append(quote)
                index += 1
            continue
        out.append(char)
        index += 1
    return "".join(out), strings


_KEYWORDS_BEFORE_NODE_REF = {
    "return", "await", "if", "elif", "while", "and", "or", "not", "in", "else",
    "assert", "yield", "var", "as", "is", "pass", "emit",
}
_TRAILING_WORD = re.compile(r"([A-Za-z_]\w*)\s*$")


def looks_like_modulo(text: str, position: int) -> bool:
    """True when the `%` at `position` is the modulo operator, not `%UniqueName`."""
    prefix = text[:position].rstrip()
    if not prefix:
        return False
    if prefix[-1] in ")]}\"'":
        return True
    match = _TRAILING_WORD.search(prefix)
    if match:
        return match.group(1) not in _KEYWORDS_BEFORE_NODE_REF
    return False


# ---------------------------------------------------------------------------
# .tscn / .tres parsing
# ---------------------------------------------------------------------------

# Greedy up to the LAST ']' on the line: attribute values legitimately contain
# one, as in `groups=["hurt", "player"]`. A non-greedy [^\]]* stopped at the
# inner bracket, the whole [node] line failed to parse, and every property line
# under it — `script = ExtResource(...)`, `unique_name_in_owner = true` — was
# then charged to the previous node.
_SECTION = re.compile(r"^\[(?P<kind>[a-z_]+)(?P<attrs>.*)\]\s*$")
_ATTR = re.compile(r"(\w+)\s*=\s*(?:\"((?:[^\"\\]|\\.)*)\"|(\w+\(\s*\"[^\"]*\"\s*\))|([^\s\]]+))")
_EXT_REF = re.compile(r"ExtResource\(\s*\"([^\"]*)\"\s*\)")
_PROPERTY = re.compile(r"^(?P<key>[\w/]+)\s*=\s*(?P<value>.*)$")
# `groups=["hurt", "player"]` in a [node] header, and the PackedStringArray form.
_GROUPS_ATTR = re.compile(r"groups\s*=\s*(?:\[|PackedStringArray\()(?P<items>[^\]\)]*)")
_QUOTED = re.compile(r"&?\"((?:[^\"\\]|\\.)*)\"")
_SUB_REF = re.compile(r"SubResource\(\s*\"([^\"]*)\"\s*\)")
# Node properties worth remembering. Everything else is dropped so a 5000-line
# scene does not turn into a 5000-entry dictionary.
_KEPT_NODE_PROPS = frozenset({
    "sprite_frames", "animation", "autoplay", "frames", "libraries",
    "current_animation", "assigned_animation",
})
# Sub-resource / [resource] types whose body the cross-reference checks read.
_KEPT_RESOURCE_TYPES = frozenset({"SpriteFrames", "AnimationLibrary", "Shader"})
# `"name": &"idle"` inside a SpriteFrames `animations = [...]` array.
_SPRITE_FRAME_NAME = re.compile(r"\"name\"\s*:\s*&?\"((?:[^\"\\]|\\.)*)\"")
# `&"walk": SubResource("Animation_x")` inside an AnimationLibrary `_data = {...}`.
_LIBRARY_ENTRY = re.compile(r"&?\"((?:[^\"\\]|\\.)*)\"\s*:")


class SceneNode:
    __slots__ = ("name", "type", "parent", "path", "script_id", "instance_id", "unique",
                 "line", "props", "groups")

    def __init__(self, name: str, ntype: str, parent: Optional[str], path: str, line: int) -> None:
        self.name = name
        self.type = ntype
        self.parent = parent
        self.path = path
        self.line = line
        self.script_id: Optional[str] = None
        self.instance_id: Optional[str] = None
        self.unique = False
        # Only the keys in _KEPT_NODE_PROPS (plus `libraries/<name>`), as
        # {key: (raw value text, line number)}.
        self.props: dict[str, tuple[str, int]] = {}
        self.groups: list[str] = []


class SceneDoc:
    def __init__(self, res_path: str) -> None:
        self.res_path = res_path
        self.nodes: dict[str, SceneNode] = {}
        self.children: dict[str, list[str]] = {}
        self.ext: dict[str, dict] = {}
        self.connections: list[dict] = []
        self.unique_names: dict[str, str] = {}
        self.root_name = ""
        # id -> {"type", "props": {key: (value, line)}, "line"}
        self.sub: dict[str, dict] = {}
        self.resource_type = ""
        self.resource_props: dict[str, tuple[str, int]] = {}
        self.groups: set[str] = set()
        # (line, shader source) for every `code = "…"` of a Shader resource.
        self.shader_code: list[tuple[int, str]] = []
        # The file as read, so the callers that need raw lines (the Godot 3 scan,
        # the suppression scan) do not open it again.
        self.text = ""

    def child(self, parent_path: str, name: str) -> Optional[SceneNode]:
        key = (parent_path + "/" + name) if parent_path else name
        return self.nodes.get(key)

    def child_names(self, parent_path: str) -> list[str]:
        return self.children.get(parent_path, [])


def _attrs(text: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for match in _ATTR.finditer(text):
        key = match.group(1)
        found[key] = match.group(2) if match.group(2) is not None else (
            match.group(3) or match.group(4) or "")
    return found


def _unescape(value: str) -> str:
    """Undo the .tscn string escaping (`\\n`, `\\"`, `\\\\`) of a quoted value."""
    return (value.replace("\\\\", "\x00").replace("\\n", "\n").replace("\\t", "\t")
            .replace('\\"', '"').replace("\x00", "\\"))


def _value_delta(value: str) -> int:
    """Net `([{` minus `)]}` outside strings. Unlike `_bracket_delta` this one
    honours backslash escapes, which a .tscn value (an embedded shader's
    `code = "…\\"…"`) really does contain."""
    delta = 0
    quote = ""
    index = 0
    length = len(value)
    while index < length:
        char = value[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = ""
        elif char in "\"'":
            quote = char
        elif char in "([{":
            delta += 1
        elif char in ")]}":
            delta -= 1
        index += 1
    return delta


def parse_scene_text(text: str, res_path: str) -> SceneDoc:
    doc = SceneDoc(res_path)
    doc.text = text
    current: Optional[SceneNode] = None
    # The sink for property lines of the section we are inside, and whether it
    # keeps every key (a sub_resource we care about) or only _KEPT_NODE_PROPS.
    sink: Optional[dict[str, tuple[str, int]]] = None
    keep_all = False
    # A `_data = {` / `animations = [{` value runs over many lines; accumulate
    # until the brackets balance again.
    pending_key = ""
    pending_line = 0
    pending: list[str] = []
    depth = 0

    def flush_pending() -> None:
        nonlocal pending_key, pending, depth
        if pending_key and sink is not None:
            sink[pending_key] = ("\n".join(pending), pending_line)
        pending_key = ""
        pending = []
        depth = 0

    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if pending_key:
            pending.append(line)
            depth += _value_delta(line)
            if depth <= 0:
                flush_pending()
            continue
        if not line or line.startswith(";"):
            continue
        section = _SECTION.match(line)
        if section:
            current = None
            sink = None
            keep_all = False
            kind = section.group("kind")
            attrs = _attrs(section.group("attrs"))
            if kind == "sub_resource":
                entry = {"type": attrs.get("type", ""), "props": {}, "line": number}
                doc.sub[attrs.get("id", "")] = entry
                if entry["type"] in _KEPT_RESOURCE_TYPES:
                    sink = entry["props"]
                    keep_all = True
                continue
            if kind == "resource":
                sink = doc.resource_props
                keep_all = True
                continue
            if kind in ("gd_resource", "gd_scene"):
                doc.resource_type = attrs.get("type", "")
                continue
            if kind == "ext_resource":
                doc.ext[attrs.get("id", "")] = {
                    "type": attrs.get("type", ""),
                    "path": attrs.get("path", ""),
                    "line": number,
                }
            elif kind == "node":
                name = attrs.get("name", "")
                parent = attrs.get("parent")
                if parent is None:
                    path = ""
                    doc.root_name = name
                elif parent == ".":
                    path = name
                else:
                    path = parent.rstrip("/") + "/" + name
                node = SceneNode(name, attrs.get("type", ""), parent, path, number)
                instance = _EXT_REF.search(attrs.get("instance", ""))
                if instance:
                    node.instance_id = instance.group(1)
                doc.nodes[path] = node
                parent_path = "" if parent in (None, ".") else parent.rstrip("/")
                if parent is not None:
                    doc.children.setdefault(parent_path, []).append(name)
                groups = _GROUPS_ATTR.search(section.group("attrs"))
                if groups:
                    node.groups = [_unescape(item)
                                   for item in _QUOTED.findall(groups.group("items"))]
                    doc.groups.update(node.groups)
                current = node
                sink = node.props
            elif kind == "connection":
                doc.connections.append({
                    "signal": attrs.get("signal", ""),
                    "from": attrs.get("from", ""),
                    "to": attrs.get("to", ""),
                    "method": attrs.get("method", ""),
                    "line": number,
                })
            continue
        prop = _PROPERTY.match(line)
        if not prop:
            continue
        key = prop.group("key")
        value = prop.group("value")
        if current is not None:
            if key == "script":
                ref = _EXT_REF.search(value)
                if ref:
                    current.script_id = ref.group(1)
            elif key == "unique_name_in_owner" and value.strip().lower().startswith("true"):
                current.unique = True
                doc.unique_names[current.name] = current.path
        if sink is None:
            continue
        if not keep_all and key not in _KEPT_NODE_PROPS and not key.startswith("libraries/"):
            continue
        delta = _value_delta(value)
        if delta > 0:
            pending_key = key
            pending_line = number
            pending = [value]
            depth = delta
            continue
        sink[key] = (value, number)
        if keep_all and key == "code":
            literal = _QUOTED.match(value.strip())
            if literal:
                doc.shader_code.append((number, _unescape(literal.group(1))))
    flush_pending()
    return doc


# ---------------------------------------------------------------------------
# GDScript scanning
# ---------------------------------------------------------------------------

_FUNC = re.compile(r"^\s*(?:static\s+)?func\s+(\w+)\s*\((?P<params>.*)$")
# `var name: Type` / `var name =` / `const name` — the annotation decides whether a
# `name[...]` read has an element type. Bare `Array` / `Dictionary` do not.
_DECL = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?P<kw>var|const)\s+(?P<name>\w+)\s*(?::\s*(?P<type>[\w\[\], ]+?)\s*)?(?P<op>:=|=|$)")
_UNTYPED_CONTAINERS = frozenset({"Array", "Dictionary", "Variant"})
# A `:=` right-hand side that provably produces a container with no element
# type: an array/dictionary literal, or the bare Array()/Dictionary() constructor.
_UNTYPED_LITERAL_RHS = re.compile(r"^\s*(?:\[|\{|Array\s*\(|Dictionary\s*\()")
_CLASS_NAME = re.compile(r"^\s*class_name\s+(\w+)")
_EXTENDS = re.compile(r"^\s*extends\s+(.+?)\s*$")
_DOLLAR = re.compile(r"\$(/?[%A-Za-z_][\w/]*)")
_DOLLAR_QUOTED = re.compile(r"\$(\"|')")
_UNIQUE = re.compile(r"%([A-Za-z_]\w*)")
# Only a bare `get_node(...)` (or `self.get_node(...)`) is relative to the node
# the script is attached to. `slot.get_node("Icon")` / `_dialogue.get_node("Body")`
# are calls on some other node and cannot be resolved from here.
_GET_NODE = re.compile(
    r"(?:(?<![\w.])|(?<=\bself\.))get_node(?P<safe>_or_null)?\s*\(\s*"
    r"(?:NodePath\s*\(\s*)?(?P<quote>\")")
# Global load()/preload() only. `config.load(path)`, `image.load(path)` and any
# other `.load()` are method calls on an object, not resource loads.
_LOAD_CALL = re.compile(r"(?<![\w.])(?P<kind>preload|load)\s*\(\s*(?P<quote>\")")
_DYNAMIC = ("%s", "%d", "+", "str(")


class ScriptInfo:
    __slots__ = ("res_path", "funcs", "refs", "extends", "class_name", "exists",
                 "func_returns", "typed_names", "untyped_names", "anim_refs",
                 "const_strings", "bindings", "shadowed", "declared")

    def __init__(self, res_path: str) -> None:
        self.res_path = res_path
        self.funcs: set[str] = set()
        self.refs: list[dict] = []
        self.anim_refs: list[dict] = []
        # `const FIRE: StringName = &"fire"` -> {"FIRE": "fire"}. A const cannot
        # be reassigned, so `Input.is_action_pressed(FIRE)` is exactly as certain
        # as the literal. Same-file only: no enums, no other files, no static var.
        self.const_strings: dict[str, str] = {}
        # `@onready var anim: AnimatedSprite2D = $Sprite` -> {"anim": "$Sprite"}.
        # Only entries whose name is in neither `shadowed` nor declared twice are
        # used; see `binding_target()`.
        self.bindings: dict[str, str] = {}
        # Names that are reassigned, shadowed by a parameter or a `for` variable,
        # or declared more than once — anything that makes a binding uncertain.
        self.shadowed: set[str] = set()
        self.declared: set[str] = set()
        self.extends: Optional[str] = None
        self.class_name: Optional[str] = None
        self.exists = True
        # func name -> whether it declares `-> Type`. A function without one
        # returns Variant, so `var x := that()` cannot be inferred.
        self.func_returns: dict[str, bool] = {}
        # Names whose `x[...]` read is *provably* Variant, and names where it is
        # not (typed, or not provable). A name in both is treated as typed: the
        # analysis is per-file, not per-scope, and a miss beats a false alarm.
        self.typed_names: set[str] = set()
        self.untyped_names: set[str] = set()

    def note_declaration(self, name: str, annotation: Optional[str],
                         operator: str = "", rhs: str = "", keyword: str = "var") -> None:
        """Record whether `name[...]` is provably a Variant read.

        Measured on godot 4.7 by compiling one script per case (`var x :=
        base[0]`, thirty-odd declaration forms). What actually decides it:

        - an annotation of exactly `Array` / `Dictionary` / `Variant` -> Variant;
          any other annotation (`Array[int]`, `PackedFloat32Array`,
          `Dictionary[String, int]`) carries an element type and infers fine;
        - `var x = <anything>` (plain `=`, no annotation) -> Variant. Even
          `var packed = PackedByteArray([1])` fails: only `:=` infers;
        - `var x` with nothing at all -> Variant;
        - `var x := []` / `{}` / `Array()` / `Dictionary()` -> an untyped
          container, so the read is Variant;
        - every other `:=` right-hand side -> whatever that expression is, which
          this analysis does not track. `var packed := PackedByteArray([1])`,
          `var files := DirAccess.get_files_at(p)`, `var row := grid[0]` (grid
          being `Array[PackedInt32Array]`), `var text := "abc"` and
          `var b := make()` with `make() -> PackedByteArray` all compile, so they
          are NOT reported;
        - `const` never: constants are folded, and `const NAMES := ["a"]` gives
          `NAMES[0]` a concrete type.
        """
        if keyword == "const":
            self.typed_names.add(name)
            return
        if annotation:
            if annotation.strip() in _UNTYPED_CONTAINERS:
                self.untyped_names.add(name)
            else:
                self.typed_names.add(name)
            return
        if operator == ":=" and (not _UNTYPED_LITERAL_RHS.match(rhs)
                                 or " as " in rhs or " if " in rhs):
            self.typed_names.add(name)
            return
        self.untyped_names.add(name)

    def binding_target(self, name: str) -> Optional[str]:
        """The `$Path` / `%Name` / `get_node()` path `name` is bound to, if certain.

        Certain means: declared exactly once, as an `@onready var` whose whole
        right-hand side is one node lookup, and never assigned, shadowed by a
        parameter or a `for` variable, or re-declared anywhere in the file. A
        plain `var anim = $Sprite` inside `_ready()` does not qualify — it is a
        local whose name may mean something else three functions down.
        """
        if name in self.shadowed:
            return None
        return self.bindings.get(name)


# ---------------------------------------------------------------------------
# Linter
# ---------------------------------------------------------------------------

class Linter:
    def __init__(self, project: Path, only: Optional[set[str]] = None,
                 include_addons: bool = False, subpath: str = "") -> None:
        self.project = project
        self.only = only or set(CATEGORIES)
        self.include_addons = include_addons
        self.subpath = subpath.strip("/")
        self.diagnostics: list[dict] = []
        self.scan_summary = {
            "gd": 0, "tscn": 0, "tres": 0, "shader": 0, "project_godot": 0,
            "scene_script_pairs": 0, "node_paths_checked": 0, "skipped_dynamic_paths": 0,
            "skipped_gdignore_dirs": 0,
        }
        self._scenes: dict[str, Optional[SceneDoc]] = {}
        self._scripts: dict[str, ScriptInfo] = {}
        self._seen: set[tuple] = set()
        self._pending_godot3: list[tuple] = []
        self.autoloads: dict[str, str] = {}
        self.class_index: dict[str, str] = {}
        # --- suppressions: (file, line) -> set of categories, "*" = all -------
        self._suppress: dict[str, dict[int, set[str]]] = {}
        self._suppress_used: set[tuple[str, int]] = set()
        self._suppress_sites: list[dict] = []
        # --- cross-reference indexes -----------------------------------------
        # Emission is deferred: `add_to_group("boss")` in the last script of the
        # walk still defines the group for the first one.
        self.defined_actions: dict[str, str] = {}      # action -> where it comes from
        self.probed_actions: set[str] = set()          # asked about with InputMap.has_action()
        self.defined_groups: dict[str, str] = {}       # group -> where it comes from
        self.written_paths: set[str] = set()           # res:// paths the project creates
        self._pending_actions: list[dict] = []
        self._pending_groups: list[dict] = []
        self._pending_res: list[dict] = []
        self._reported_load: set[tuple[str, int, str]] = set()
        self._project_funcs: set[str] = set()
        self._dir_cache: dict[Path, dict] = {}
        self._excused_names: set[tuple[str, str]] = set()

    # -- helpers ----------------------------------------------------------
    def res(self, path: Path) -> str:
        return "res://" + path.relative_to(self.project).as_posix()

    def abs_of(self, res_path: str) -> Optional[Path]:
        if not res_path.startswith("res://"):
            return None
        return self.project / res_path[len("res://"):]

    def emit(self, severity: str, category: str, message: str, file: str,
             line: Optional[int], fix: str, rule: str = "") -> None:
        if category not in self.only:
            return
        if self.suppressed(file, line, category):
            return
        key = (category, rule, file, line, message)
        if key in self._seen:
            return
        self._seen.add(key)
        self.diagnostics.append({
            "severity": severity,
            "category": category,
            "rule": rule,
            "message": message,
            "file": file,
            "line": line,
            "suggested_fix": fix,
        })

    # -- suppression comments ---------------------------------------------
    def collect_suppressions(self, res_path: str, text: str) -> None:
        """Index every `lint:ignore` comment in a file.

        A comment on line N covers line N (it is trailing the offending code) and
        line N+1 (it sits on the line above). Three comment markers, so the same
        spelling works in `.gd` (`#`), `.tscn`/`.tres`/`project.godot` (`;`) and
        `.gdshader` (`//`).
        """
        if "lint:ignore" not in text:
            return
        table = self._suppress.setdefault(res_path, {})
        for number, raw in enumerate(text.splitlines(), start=1):
            match = _SUPPRESS.search(raw)
            if match is None:
                continue
            names = {name for name in re.split(r"[,\s]+", match.group("cats").strip()) if name}
            categories = names or {"*"}
            for target in (number, number + 1):
                table.setdefault(target, set()).update(categories)
            self._suppress_sites.append({
                "file": res_path, "line": number,
                "categories": sorted(categories),
                "unknown": sorted(name for name in names if name not in CATEGORIES),
            })

    def suppressed(self, file: str, line: Optional[int], category: str) -> bool:
        table = self._suppress.get(file)
        if not table or line is None:
            return False
        categories = table.get(line)
        if not categories or not ({"*", category} & categories):
            return False
        # Mark the comment that covers this line (it is either on it or above it).
        for source in (line, line - 1):
            entry = table.get(source)
            if entry and ({"*", category} & entry):
                self._suppress_used.add((file, source))
        return True

    def suppression_report(self) -> dict:
        """`{total, used, unused[]}` — never diagnostics, so never an exit code.

        Under `--only`, a suppression for a category that was filtered out counts
        as unused: it genuinely matched nothing *in this run*. Judge unused
        suppressions from a full run.
        """
        unused = []
        for site in self._suppress_sites:
            if (site["file"], site["line"]) in self._suppress_used:
                continue
            reason = "no diagnostic of that category on this line or the next"
            if site["unknown"]:
                reason = (f"unknown categor{'y' if len(site['unknown']) == 1 else 'ies'} "
                          f"{', '.join(site['unknown'])}; valid: {', '.join(CATEGORIES)}")
            unused.append({"file": site["file"], "line": site["line"],
                           "categories": site["categories"], "reason": reason})
        return {
            "total": len(self._suppress_sites),
            "used": len(self._suppress_sites) - len(unused),
            "unused": unused,
        }

    # -- file walk --------------------------------------------------------
    def iter_files(self) -> Iterable[Path]:
        root = self.project / self.subpath if self.subpath else self.project
        if not root.exists():
            raise SystemExit(
                f"--path {self.subpath!r} does not exist under {self.project}. Pass a directory "
                f"that exists inside the project (for example --path scripts), or drop --path to "
                f"lint the whole project.")
        for dirpath, dirnames, filenames in os.walk(root):
            keep: list[str] = []
            for name in sorted(dirnames):
                if name.startswith(".") or (not self.include_addons and name == "addons"):
                    continue
                # A directory holding a `.gdignore` file is invisible to Godot —
                # it is never imported, never scanned, and nothing in it can be
                # loaded. Linting it would report on code the engine never sees
                # and, worse, index its `add_to_group` / `InputMap.add_action`
                # calls as if they ran.
                if (Path(dirpath) / name / ".gdignore").is_file():
                    self.scan_summary["skipped_gdignore_dirs"] += 1
                    continue
                keep.append(name)
            dirnames[:] = keep
            for name in sorted(filenames):
                if name.startswith(".") or name.endswith(".import"):
                    continue
                yield Path(dirpath) / name

    # -- project.godot ----------------------------------------------------
    def load_project_settings(self) -> None:
        path = self.project / "project.godot"
        if not path.is_file():
            return
        self.scan_summary["project_godot"] = 1
        text = path.read_text(encoding="utf-8", errors="replace")
        self.collect_suppressions("res://project.godot", text)
        section = ""
        for number, raw in enumerate(text.splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith(";"):
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"')
            if section == "autoload":
                self.autoloads[key] = value
                self.check_project_resource(value.lstrip("*"), number, f"autoload `{key}`")
            elif section == "input":
                # `jump.macos=...` is the same action with a platform override.
                self.defined_actions.setdefault(
                    key.split(".")[0], "project.godot [input]")
            elif section == "global_group":
                self.defined_groups.setdefault(key, "project.godot [global_group]")
            elif key == "run/main_scene":
                self.check_project_resource(value, number, "run/main_scene")

    def check_project_resource(self, res_path: str, line: int, label: str) -> None:
        if not res_path.startswith("res://"):
            return
        target = self.abs_of(res_path)
        if target is not None and target.exists():
            return
        self.emit(
            "error", "missing_resource",
            f"project.godot {label} points at `{res_path}`, which does not exist on disk.",
            "res://project.godot", line,
            f"Create `{res_path}` or fix the path. A missing autoload script makes Godot print "
            f"`Failed to instantiate an autoload` on every run; a missing main scene makes the "
            f"project boot to an empty window.",
            rule="project_resource",
        )

    # -- scripts ----------------------------------------------------------
    def script_info(self, res_path: str) -> Optional[ScriptInfo]:
        if res_path in self._scripts:
            return self._scripts[res_path]
        target = self.abs_of(res_path)
        if target is None or not target.is_file():
            return None
        info = self.scan_script(target, record=False)
        return info

    def scan_script(self, path: Path, record: bool = True) -> ScriptInfo:
        res_path = self.res(path)
        cached = self._scripts.get(res_path)
        if cached is not None:
            return cached
        info = ScriptInfo(res_path)
        self._scripts[res_path] = info
        text = path.read_text(encoding="utf-8", errors="replace")
        self.collect_suppressions(res_path, text)
        scrubbed = [scrub_line(raw) for raw in text.splitlines()]

        # Pass one builds the file's symbol table. The inference analysis needs it
        # up front: whether `foo()` has a declared return type, and whether the
        # `x` in `x[0]` was declared with an element type, decide whether `:=` on
        # them is a parse error or perfectly fine.
        for index, (blank, strings) in enumerate(scrubbed):
            self.collect_symbols(info, res_path, _join_header(scrubbed, index), strings)

        for number, (blank, strings) in enumerate(scrubbed, start=1):
            if record:
                self.check_godot3_line(res_path, number, blank)
                self.check_inference_line(res_path, number, blank, info)
                self.check_load_calls(res_path, number, blank, strings)
                self.collect_calls(info, res_path, number, blank, strings)
                self.collect_res_literals(res_path, number, blank, strings)
            self.collect_node_refs(info, number, blank, strings)
        if record:
            self.scan_summary["gd"] += 1
        return info

    def collect_symbols(self, info: ScriptInfo, res_path: str, blank: str,
                        strings: dict[int, str]) -> None:
        # Anything that makes a member name mean something else later: a plain
        # assignment, a `for` variable, a parameter, a second declaration.
        rebind = _ASSIGNMENT.match(blank)
        if rebind:
            info.shadowed.add(rebind.group("name"))
        loop = _FOR_VAR.match(blank)
        if loop:
            info.shadowed.add(loop.group(1))
        func = _FUNC.match(blank)
        if func:
            info.funcs.add(func.group(1))
            info.func_returns[func.group(1)] = "->" in func.group("params")
            for param in _split_params(func.group("params")):
                # `a := PackedByteArray()` infers; `a = PackedByteArray()` does
                # NOT (verified on 4.7) — a plain `=` default leaves the
                # parameter Variant. The two forms have to be told apart.
                if ":=" in param:
                    head, operator, rhs = param.partition(":=")
                else:
                    head, operator, rhs = param.partition("=")
                name, _, annotation = head.partition(":")
                name = name.strip()
                if name:
                    info.note_declaration(name, annotation.strip() or None, operator, rhs)
                    info.shadowed.add(name)
            return
        cname = _CLASS_NAME.match(blank)
        if cname:
            info.class_name = cname.group(1)
            self.class_index[cname.group(1)] = res_path
            return
        if info.extends is None:
            extends = _EXTENDS.match(blank)
            if extends:
                literal = strings.get(blank.index('"')) if '"' in blank else None
                info.extends = literal or extends.group(1).strip()
                return
        decl = _DECL.match(blank)
        if decl:
            name = decl.group("name")
            rhs = blank[decl.end():]
            info.note_declaration(name, decl.group("type"), decl.group("op"), rhs,
                                  decl.group("kw"))
            if name in info.declared:
                info.shadowed.add(name)       # two declarations: which one wins?
            info.declared.add(name)
            if decl.group("kw") == "const":
                literal = literal_argument(decl.end(), rhs, strings)
                if literal is not None:
                    info.const_strings[name] = literal
            elif blank.lstrip().startswith("@onready"):
                target = node_expression(decl.end(), rhs, strings)
                if target is not None:
                    info.bindings[name] = target
                else:
                    info.shadowed.add(name)   # bound to something we cannot follow

    def collect_node_refs(self, info: ScriptInfo, number: int, blank: str,
                          strings: dict[int, str]) -> None:
        for match in _DOLLAR_QUOTED.finditer(blank):
            literal = strings.get(match.start(1))
            if literal is not None:
                info.refs.append({"kind": "$", "path": literal, "line": number,
                                  "raw": f'$"{literal}"'})
        for match in _DOLLAR.finditer(blank):
            path = match.group(1)
            info.refs.append({"kind": "$", "path": path, "line": number, "raw": "$" + path})
        for match in _UNIQUE.finditer(blank):
            if looks_like_modulo(blank, match.start()):
                continue
            info.refs.append({"kind": "%", "path": "%" + match.group(1), "line": number,
                              "raw": "%" + match.group(1)})
        for match in _GET_NODE.finditer(blank):
            literal = strings.get(match.start("quote"))
            if literal is None:
                continue
            kind = "get_node_or_null" if match.group("safe") else "get_node"
            info.refs.append({"kind": kind, "path": literal, "line": number,
                              "raw": f'{kind}("{literal}")'})
        if not _ANIM_ANY.search(blank):
            return
        for regex, template in ((_ANIM_PLAY, '{s}.{m}("{a}")'),
                                (_ANIM_ASSIGN, '{s}.{m} = "{a}"')):
            for match in regex.finditer(blank):
                literal = strings.get(match.start("quote"))
                if not literal:
                    continue
                subject = match.group("node")
                info.anim_refs.append({
                    "node": subject, "member": match.group("method"),
                    # A bare identifier only resolves through an @onready
                    # binding; `$Path` / `%Name` resolve directly.
                    "binding": subject[0] not in "$%",
                    "animation": literal, "line": number,
                    "raw": template.format(s=subject, m=match.group("method"), a=literal),
                })

    # -- cross-reference collectors ---------------------------------------
    def collect_calls(self, info: ScriptInfo, res_path: str, number: int, blank: str,
                      strings: dict[int, str]) -> None:
        """Queue input-action and group names used or defined on this line.

        An argument counts when it is a string literal, a `&"name"` StringName
        literal, or an identifier this file declares as a `const` holding one —
        `const FIRE: StringName = &"fire"` cannot be reassigned, so
        `Input.is_action_pressed(FIRE)` is exactly as certain as the literal.
        Anything else (a variable, an expression, a const from another file, an
        enum) is never guessed at.
        """
        want_actions = "input_action" in self.only
        want_groups = "group_ref" in self.only
        if not (want_actions or want_groups) or not _CALL_NAMES_ANY.search(blank):
            return
        for match in _METHOD_CALL.finditer(blank):
            name = match.group("name")
            receiver = match.group("recv")
            args: Optional[list[tuple[int, str]]] = None

            def literal_at(index: int) -> Optional[str]:
                nonlocal args
                if args is None:
                    args = split_call_args(blank, match.end() - 1)
                if index >= len(args):
                    return None
                start, text = args[index]
                found = literal_argument(start, text, strings)
                if found is not None:
                    return found
                return info.const_strings.get(text.strip())

            if want_actions:
                indexes: tuple[int, ...] = ()
                if receiver == "InputMap" and name == "add_action":
                    literal = literal_at(0)
                    if literal:
                        self.defined_actions.setdefault(
                            literal, f"InputMap.add_action() in {res_path}")
                    continue
                if receiver == "InputMap" and name in _INPUTMAP_PROBES:
                    literal = literal_at(0)
                    if literal:
                        self.probed_actions.add(literal)
                    continue
                if receiver in ("Input", "InputMap"):
                    indexes = (_INPUT_SINGLETON_ACTION_ARGS if receiver == "Input"
                               else _INPUTMAP_ACTION_ARGS).get(name, ())
                elif receiver is not None:
                    indexes = _ANY_RECEIVER_ACTION_ARGS.get(name, ())
                for index in indexes:
                    literal = literal_at(index)
                    if literal:
                        self._pending_actions.append({
                            "action": literal, "file": res_path, "line": number,
                            "call": f"{receiver}.{name}()", "engine_call": receiver in
                            ("Input", "InputMap"), "method": name})
            if want_groups:
                if name in _GROUP_PROVIDERS:
                    literal = literal_at(_GROUP_PROVIDERS[name])
                    if literal:
                        self.defined_groups.setdefault(literal, f"add_to_group() in {res_path}")
                elif name in _GROUP_ARG:
                    literal = literal_at(_GROUP_ARG[name])
                    if literal:
                        self._pending_groups.append({
                            "group": literal, "file": res_path, "line": number,
                            "call": f"{name}()"})

    def collect_res_literals(self, res_path: str, number: int, blank: str,
                             strings: dict[int, str]) -> None:
        """Queue every `res://…` literal on the line, and note the ones written.

        The literals come from `strings`, not from `blank`: `scrub_line` blanks
        string *contents* out of the code view, so `res://` is simply not there.
        """
        if "res_path" not in self.only:
            return
        if not strings and not _PATH_CONTEXT_ANY.search(blank):
            return
        if _PROBE_CALL.search(blank):
            # `FileAccess.file_exists("res://save.cfg")`. The path usually lives
            # in a const a few lines up, so excuse both the literals and the
            # names on this line — a `const CONFIG := "res://export_presets.cfg"`
            # that is only ever probed is not a missing file.
            for literal in strings.values():
                if literal.startswith("res://"):
                    self.written_paths.add(literal)
            self._excused_names.update((res_path, name) for name in _IDENT.findall(blank))
            return
        if not strings:
            return
        if blank.lstrip().startswith("@export"):
            # `@export var next_scene: String = "res://scenes/level_1.tscn"` is a
            # placeholder: the real value is set per instance in the inspector or
            # through `attach_script` `script_properties`. templates/gdscript
            # ships two of these and both are correct as written.
            return
        writes = bool(_WRITE_MODE.search(blank)) or bool(_WRITE_CALL.search(blank))
        for offset, literal in strings.items():
            if not literal.startswith("res://"):
                continue
            if _FORMAT_MARKER.search(literal):
                continue                      # a template, not a path
            # Glued to a neighbour: this literal is a prefix or a suffix.
            before = blank[:offset].rstrip()
            after = blank[offset + len(literal) + 2:].lstrip()
            if before.endswith("+") or after.startswith(("+", "%", ".path_join", ".format")):
                continue
            if _STRING_METHOD_ARG.search(before):
                continue                      # `path.begins_with("res://addons/")`
            if writes:
                self.written_paths.add(literal)
                continue
            declared = _DECL.match(blank)
            self._pending_res.append({
                "path": literal, "file": res_path, "line": number,
                # The const may be probed further down the file, so the excuse
                # can only be applied once the whole project has been read.
                "name": declared.group("name") if declared else None,
                # `extends "res://x.gd"` of a missing file is a parse error, the
                # same class as `preload()`, so it is an error not a warning.
                "extends": blank.lstrip().startswith("extends"),
            })

    def check_godot3_line(self, res_path: str, number: int, blank: str) -> None:
        if "godot3_api" not in self.only:
            return
        candidates = GODOT3_RULES if _GD_ANY.search(blank) else _GD_ALWAYS
        for rule in candidates:
            regex = rule["gd_regex"]
            if regex is None:
                continue
            match = regex.search(blank)
            if match is None:
                continue
            guard = GUARDS.get(rule["guard"] or "")
            if guard is not None and not guard(blank, match):
                continue
            self._pending_godot3.append((rule, res_path, number))

    def check_scene_line(self, res_path: str, number: int, raw: str) -> None:
        if "godot3_api" not in self.only:
            return
        candidates = GODOT3_RULES if _SCENE_ANY.search(raw) else _SCENE_ALWAYS
        for rule in candidates:
            regex = rule["scene_regex"]
            if regex is not None and regex.search(raw):
                self._pending_godot3.append((rule, res_path, number))

    def flush_godot3(self) -> None:
        """Emit the queued Godot 3 hits, minus the ones a project class_name owns.

        `class_name File`, `class_name Path`, `class_name Sprite` are all legal in
        Godot 4 (those names are free), so a project that declares one is using its
        own type, not the removed engine class. The same goes for a method name the
        project defines itself (`static func empty()` -> `LegacySystem.empty()`).
        """
        project_funcs: set[str] = set()
        for script in self._scripts.values():
            project_funcs |= script.funcs
        for rule, res_path, number in self._pending_godot3:
            if rule["identifier"] and rule["identifier"] in self.class_index:
                continue
            if rule["suppress_if_func"] and rule["suppress_if_func"] in project_funcs:
                continue
            self.emit(rule["severity"], rule["category"], rule["message"], res_path, number,
                      rule["fix"], rule=rule["id"])

    def check_inference_line(self, res_path: str, number: int, blank: str,
                             info: ScriptInfo) -> None:
        if "inference" not in self.only:
            return
        position = blank.find(":=")
        if position < 0 or not _DECL.match(blank):
            return
        rhs = blank[position + 2:]
        if not rhs.strip():
            return
        rule_id = classify_rhs(rhs, info)
        if rule_id is None:
            return
        rule = INFERENCE_RULES[rule_id]
        self.emit(
            rule["severity"], "inference", rule["message"], res_path, number,
            rule["fix"] + " See references/gdscript_conventions.md.",
            rule=rule_id,
        )

    def check_load_calls(self, res_path: str, number: int, blank: str,
                         strings: dict[int, str]) -> None:
        if "missing_resource" not in self.only:
            return
        for match in _LOAD_CALL.finditer(blank):
            literal = strings.get(match.start("quote"))
            if literal is None or not literal.startswith("res://"):
                continue
            target = self.abs_of(literal)
            if target is not None and target.exists():
                continue
            kind = match.group("kind")
            # Claimed by `missing_resource`; `res_path` must not say it again.
            self._reported_load.add((res_path, number, literal))
            self.emit(
                "error", "missing_resource",
                f"`{kind}(\"{literal}\")` refers to a file that does not exist on disk.",
                res_path, number,
                f"Create `{literal}` (or fix the path). `preload()` fails at parse time and takes "
                f"the whole script down; `load()` returns null and the failure surfaces later, "
                f"far from here.",
                rule="missing_load",
            )

    # -- deferred cross-reference reports ---------------------------------
    def flush_input_actions(self) -> None:
        if "input_action" not in self.only:
            return
        known = set(self.defined_actions) | BUILTIN_INPUT_ACTIONS
        project_actions = sorted(self.defined_actions)
        for entry in self._pending_actions:
            action = entry["action"]
            if action in known or action.split(".")[0] in known:
                continue
            if action in self.probed_actions:
                continue
            # `event.is_action_pressed(...)` on some object the project itself
            # implements is that project's method, not the engine's.
            if not entry["engine_call"] and entry["method"] in self._project_funcs:
                continue
            close = nearest_names(action, known)
            hint = f" Did you mean {' or '.join('`' + n + '`' for n in close)}?" if close else ""
            self.emit(
                "error", "input_action",
                f"`{entry['call']}` uses the action `{action}`, which nothing defines: it is not "
                f"in project.godot's `[input]` section, it is not one of the engine's built-in "
                f"`ui_*` actions, and no script calls "
                f"`InputMap.add_action(\"{action}\")`. At runtime Godot prints "
                f"`ERROR: The InputMap action \"{action}\" doesn't exist` (or silently answers "
                f"false, depending on the call) and the input never fires.{hint} "
                f"Actions this project defines: {listed(project_actions)}.",
                entry["file"], entry["line"],
                (f"Fix the spelling to `{close[0]}`, " if close else "")
                + f"or create the action and bind a key (32 = Space; pick your own keycode):\n"
                f"  godot --headless --path /absolute/project --script "
                f"/absolute/path/to/godot/scripts/core/dispatcher.gd project_batch "
                f"'{{\"actions\":["
                f"{{\"type\":\"add_input_action\",\"action_name\":\"{action}\"}},"
                f"{{\"type\":\"add_input_event\",\"action_name\":\"{action}\",\"event\":"
                f"{{\"__resource_type\":\"InputEventKey\",\"properties\":"
                f"{{\"physical_keycode\":32}}}}}}]}}'\n"
                f"If the action is instead created at runtime, call "
                f"`InputMap.add_action(\"{action}\")` before the first use, or guard the use "
                f"with `InputMap.has_action(\"{action}\")` — the linter finds either and goes "
                f"quiet.",
                rule="undefined_input_action",
            )

    def flush_groups(self) -> None:
        if "group_ref" not in self.only:
            return
        known = set(self.defined_groups)
        for entry in self._pending_groups:
            group = entry["group"]
            if group in known:
                continue
            close = nearest_names(group, known)
            hint = f" Did you mean {' or '.join('`' + n + '`' for n in close)}?" if close else ""
            self.emit(
                "warning", "group_ref",
                f"`{entry['call']}` uses the group `{group}`, which nothing in this project ever "
                f"joins: no `.tscn` node carries it in `groups=[…]`, no script calls "
                f"`add_to_group(\"{group}\")`, and project.godot has no `[global_group]` entry "
                f"for it. The call succeeds and returns nothing, so the feature just never "
                f"happens.{hint} Groups this project provides: {listed(known)}.",
                entry["file"], entry["line"],
                f"Put the nodes in the group — `configure_node` with "
                f"`{{\"groups\": [\"{group}\"]}}`, the line `groups=[\"{group}\"]` on the [node] "
                f"header, or `add_to_group(\"{group}\")` in `_ready()` — or fix the spelling. A "
                f"group that only ever exists at runtime can also be declared under "
                f"`[global_group]` in project.godot.",
                rule="unknown_group",
            )

    def flush_res_paths(self) -> None:
        if "res_path" not in self.only:
            return
        for entry in self._pending_res:
            path = entry["path"]
            if (entry["file"], entry["line"], path) in self._reported_load:
                continue                      # already reported as missing_resource
            if path in self.written_paths:
                continue
            if entry["name"] and (entry["file"], entry["name"]) in self._excused_names:
                continue
            if not path.startswith("res://"):
                continue
            exact, actual = self.resolve_on_disk(path[len("res://"):])
            if exact:
                continue
            if actual is not None:
                self.emit(
                    "warning", "res_path",
                    f"`{path}` differs from the file on disk only in case — the real name is "
                    f"`{actual}`. It loads on macOS and Windows and fails on Linux and in every "
                    f"exported .pck, which are case-sensitive.",
                    entry["file"], entry["line"],
                    f"Use the on-disk spelling: `{actual}`.",
                    rule="res_path_case",
                )
                continue
            if entry["extends"]:
                self.emit(
                    "error", "res_path",
                    f"`extends \"{path}\"` names a script that does not exist on disk. That is a "
                    f"parse error — this file never loads, and neither does any scene using it.",
                    entry["file"], entry["line"],
                    f"Create `{path}`, or fix the path. A path-extends is resolved at parse time, "
                    f"exactly like `preload()`.",
                    rule="res_path_extends",
                )
                continue
            self.emit(
                "warning", "res_path",
                f"The literal `{path}` does not exist on disk (no file and no directory). "
                f"Nothing here proves it is loaded, so this is a warning — but a `res://` string "
                f"in a script is almost always a path that is about to be opened, and the load "
                f"will return null.",
                entry["file"], entry["line"],
                f"Create `{path}`, fix the path, or — if the file is produced at runtime — write "
                f"it through `FileAccess.open(…, FileAccess.WRITE)` / `ResourceSaver.save()`, "
                f"which the linter recognises and stops reporting. "
                f"`# lint:ignore res_path` on the line silences it for good.",
                rule="res_path_missing",
            )

    def resolve_on_disk(self, relative: str) -> tuple[bool, Optional[str]]:
        """(exists with exactly this spelling, the real `res://` path if only the
        case differs).

        Deliberately case-sensitive on every host. macOS and Windows filesystems
        are not, so `Path.exists()` there happily answers True for
        `res://art/HERO.png` when the file is `hero.png` — and then the Linux CI
        box and every exported .pck fail to load it. Doing the comparison by
        listing the directory gives the same answer everywhere.
        """
        current = self.project
        parts = [part for part in relative.split("/") if part not in ("", ".")]
        if not parts:
            return True, None
        renamed: list[str] = []
        exact = True
        for index, part in enumerate(parts):
            entries = self._dir_index(current)
            if entries is None:
                return False, None
            if part in entries:
                renamed.append(part)
            else:
                match = entries.get(part.lower())
                if match is None or index < len(parts) - 1 and not (current / match).is_dir():
                    return False, None
                exact = False
                renamed.append(match)
            current = current / renamed[-1]
        if exact:
            return True, None
        return False, "res://" + "/".join(renamed)

    def _dir_index(self, directory: Path) -> Optional[dict]:
        """{exact name: True} plus {lowercase name: exact name}, cached per dir."""
        cached = self._dir_cache.get(directory)
        if cached is None:
            if not directory.is_dir():
                self._dir_cache[directory] = {}
                return None
            cached = {}
            for entry in directory.iterdir():
                cached[entry.name] = entry.name
                cached.setdefault(entry.name.lower(), entry.name)
            self._dir_cache[directory] = cached
        return cached or None

    # -- shaders ----------------------------------------------------------
    def scan_shader_file(self, path: Path) -> None:
        res_path = self.res(path)
        text = path.read_text(encoding="utf-8", errors="replace")
        self.collect_suppressions(res_path, text)
        self.scan_summary["shader"] += 1
        self.check_shader_source(res_path, text, 0)

    def check_shader_source(self, res_path: str, source: str, line_offset: int,
                            where: str = "") -> None:
        """Run the `godot3_shader` rules over one shader body.

        `line_offset` is 0 for a `.gdshader` file (the diagnostic line is the
        shader's own line) and the `.tscn` line of the `code = "…"` property for
        embedded code, whose inner line number then goes in the message.
        """
        if "godot3_shader" not in self.only:
            return
        stripped = strip_shader_comments(source)
        declared = set(_SHADER_DECL.findall(stripped))
        for index, line in enumerate(stripped.split("\n"), start=1):
            candidates = _SHADER_RULES_ACTIVE if _SHADER_ANY.search(line) else _SHADER_ALWAYS
            for rule in candidates:
                if not rule["shader_regex"].search(line):
                    continue
                if rule["suppress_if_declared"] and rule["suppress_if_declared"] in declared:
                    continue
                inside = f" ({where} line {index})" if line_offset else ""
                self.emit(rule["severity"], "godot3_shader",
                          rule["message"] + inside,
                          res_path, line_offset or index, rule["fix"], rule=rule["id"])

    def check_embedded_shaders(self, res_path: str, doc: SceneDoc) -> None:
        for number, code in doc.shader_code:
            self.check_shader_source(res_path, code, number, "embedded shader")

    # -- scenes -----------------------------------------------------------
    def scene_doc(self, res_path: str) -> Optional[SceneDoc]:
        if res_path in self._scenes:
            return self._scenes[res_path]
        target = self.abs_of(res_path)
        doc: Optional[SceneDoc] = None
        if target is not None and target.is_file():
            doc = parse_scene_text(target.read_text(encoding="utf-8", errors="replace"), res_path)
        self._scenes[res_path] = doc
        return doc

    def index_scene(self, path: Path) -> Optional[SceneDoc]:
        """Parse a scene and register everything other files may depend on.

        Runs over every scene before any of them is checked, so a group joined in
        the last scene of the walk is already known when the first one is linted.
        """
        res_path = self.res(path)
        doc = self.scene_doc(res_path)
        if doc is None:
            return None
        self.collect_suppressions(res_path, doc.text)
        for group in doc.groups:
            self.defined_groups.setdefault(group, f"groups=[…] in {res_path}")
        return doc

    def scan_scene(self, path: Path) -> None:
        res_path = self.res(path)
        doc = self.scene_doc(res_path)
        if doc is None:
            return
        text = doc.text
        self.scan_summary["tscn"] += 1
        for number, raw in enumerate(text.splitlines(), start=1):
            if raw.lstrip().startswith(";"):
                continue
            self.check_scene_line(res_path, number, raw)
        self.check_ext_resources(res_path, doc)
        self.check_scene_scripts(doc)
        self.check_connections(doc)
        self.check_scene_animations(doc)
        self.check_embedded_shaders(res_path, doc)

    def scan_resource(self, path: Path) -> None:
        res_path = self.res(path)
        doc = self.scene_doc(res_path)
        if doc is None:
            return
        text = doc.text
        self.collect_suppressions(res_path, text)
        self.scan_summary["tres"] += 1
        for number, raw in enumerate(text.splitlines(), start=1):
            if raw.lstrip().startswith(";"):
                continue
            self.check_scene_line(res_path, number, raw)
        self.check_ext_resources(res_path, doc)
        self.check_embedded_shaders(res_path, doc)

    def check_ext_resources(self, res_path: str, doc: SceneDoc) -> None:
        for ref in doc.ext.values():
            path = ref["path"]
            if not path.startswith("res://"):
                continue
            target = self.abs_of(path)
            if target is not None and target.exists():
                continue
            self.emit(
                "error", "missing_resource",
                f"`[ext_resource path=\"{path}\"]` points at a file that does not exist. Godot "
                f"loads and instantiates a scene with a missing ext_resource anyway — it only "
                f"prints `Parse Error: [ext_resource] referenced non-existent resource` and "
                f"leaves the property null — so nothing fails until the game uses it.",
                res_path, ref["line"],
                f"Create `{path}`, fix the path, or delete the [ext_resource] line and every "
                f"`ExtResource(\"{ref.get('id', '')}\")` use of it.",
                rule="missing_ext_resource",
            )

    def node_script(self, doc: SceneDoc, node: SceneNode) -> tuple[Optional[str], bool]:
        """Return (script res path, exists). Follows an instanced scene's root script."""
        if node.script_id:
            ref = doc.ext.get(node.script_id)
            if ref and ref["path"]:
                target = self.abs_of(ref["path"])
                return ref["path"], bool(target and target.is_file())
        if node.instance_id:
            sub = self.instanced_scene(doc, node)
            if sub is not None:
                root = sub.nodes.get("")
                if root is not None:
                    return self.node_script(sub, root)
        return None, False

    def instanced_scene(self, doc: SceneDoc, node: SceneNode) -> Optional[SceneDoc]:
        if not node.instance_id:
            return None
        ref = doc.ext.get(node.instance_id)
        if not ref or not ref["path"].endswith((".tscn", ".scn")):
            return None
        return self.scene_doc(ref["path"])

    # -- node path resolution --------------------------------------------
    def resolve(self, doc: SceneDoc, base: str, path: str) -> tuple[str, dict]:
        """Resolve `path` from node `base` of `doc`.

        Returns ("ok" | "missing" | "skip", info). On "ok" the info carries the
        `scene` the walk ended in and the `node` it landed on (which is what the
        animation check needs to know the node's type and properties).
        """
        frames: list[list] = [[doc, base]]
        for segment in [part for part in path.split("/") if part != ""]:
            scene, current = frames[-1]
            if segment == ".":
                continue
            if segment == "..":
                if current:
                    frames[-1][1] = current.rsplit("/", 1)[0] if "/" in current else ""
                elif len(frames) > 1:
                    frames.pop()
                    scene, current = frames[-1]
                    frames[-1][1] = current.rsplit("/", 1)[0] if "/" in current else ""
                else:
                    return "skip", {"reason": "path walks above the scene root"}
                continue
            child = scene.child(current, segment)
            if child is not None:
                frames[-1][1] = (current + "/" + segment) if current else segment
                continue
            node = scene.nodes.get(current)
            if node is not None and node.instance_id:
                sub = self.instanced_scene(scene, node)
                if sub is None:
                    return "skip", {"reason": "instanced scene is not on disk"}
                frames.append([sub, ""])
                if sub.child("", segment) is None:
                    return "missing", self._missing_info(frames, segment)
                frames[-1][1] = segment
                continue
            return "missing", self._missing_info(frames, segment)
        scene, current = frames[-1]
        return "ok", {"scene": scene, "node": scene.nodes.get(current)}

    def _missing_info(self, frames: list[list], segment: str) -> dict:
        scene, current = frames[-1]
        names = scene.child_names(current)
        where = current or (scene.root_name or "the scene root")
        if len(frames) > 1:
            where = f"{where} (inside {scene.res_path})"
        return {
            "segment": segment,
            "ancestor": where,
            "children": names,
            "scene": scene.res_path,
        }

    @staticmethod
    def _node_display(doc: SceneDoc, node: SceneNode) -> str:
        if node.path:
            return f"node `{node.path}`"
        return f"the scene root `{doc.root_name or node.name}`"

    @staticmethod
    def _children_sentence(info: dict) -> str:
        names = info["children"]
        if not names:
            return f"{info['ancestor']} has no children in the scene file."
        listed = ", ".join(names[:12]) + (", ..." if len(names) > 12 else "")
        return f"{info['ancestor']} has children: {listed}."

    def check_scene_scripts(self, doc: SceneDoc) -> None:
        if not ({"node_ref", "unique_name", "animation_ref"} & self.only):
            return
        for node in doc.nodes.values():
            if not node.script_id:
                continue
            ref = doc.ext.get(node.script_id)
            if ref is None or not ref["path"].endswith(".gd"):
                continue
            # A node that *is* an instanced sub-scene (or lives inside one) is not
            # this scene's to check. Its script's `$Path` and `%Name` resolve
            # against the sub-scene's own tree and its own owner — and that .tscn
            # is linted on its own pass, with the right tree. Checking it here
            # walks the parent's tree instead and invents failures.
            if self.inside_instance(doc, node):
                continue
            info = self.script_info(ref["path"])
            if info is None:
                continue
            self.scan_summary["scene_script_pairs"] += 1
            for entry in info.refs:
                self.check_ref(doc, node, info, entry)
            for entry in info.anim_refs:
                self.check_anim_ref(doc, node, info, entry)

    # -- animations -------------------------------------------------------
    def locate_node(self, doc: SceneDoc, base: str, path: str
                    ) -> Optional[tuple[SceneDoc, SceneNode]]:
        """The node a `$Path` / `%Name` expression names, or None when unsure."""
        if path.startswith("$"):
            path = path[1:]
        if path.startswith("%"):
            name = path[1:].split("/", 1)[0]
            if name not in doc.unique_names:
                return None
            rest = path[1:].split("/", 1)
            base = doc.unique_names[name]
            path = rest[1] if len(rest) > 1 else ""
        if path.startswith("/") or path.split("/", 1)[0] in self.autoloads:
            return None
        status, detail = self.resolve(doc, base, path)
        if status != "ok":
            return None
        scene = detail.get("scene")
        node = detail.get("node")
        if scene is None or node is None:
            return None
        return scene, node

    def animation_names(self, doc: SceneDoc, node: SceneNode) -> Optional[tuple[set[str], str]]:
        """(animation names, what provided them), or None when not resolvable.

        Silence is the default: an AnimatedSprite2D whose `sprite_frames` comes
        from an instanced scene, an AnimationPlayer with no `libraries`, a
        resource that is not on disk — every one of those returns None rather
        than guessing.
        """
        if node.type in _ANIMATED_SPRITE_TYPES:
            value = node.props.get("sprite_frames")
            if value is None:
                return None
            frames = self.resource_body(doc, value[0], "SpriteFrames")
            if frames is None:
                return None
            body, origin = frames
            animations = body.get("animations")
            if animations is None:
                return None
            return set(_SPRITE_FRAME_NAME.findall(animations[0])), origin
        if node.type == "AnimationPlayer":
            libraries: dict[str, str] = {}
            for key, (value, _line) in node.props.items():
                if key.startswith("libraries/"):
                    libraries[key[len("libraries/"):]] = value
                elif key == "libraries":
                    for entry in re.finditer(
                            r"&?\"((?:[^\"\\]|\\.)*)\"\s*:\s*((?:Sub|Ext)Resource\([^)]*\))",
                            value):
                        libraries[_unescape(entry.group(1))] = entry.group(2)
            if not libraries:
                return None
            names: set[str] = set()
            origins: list[str] = []
            for library, value in libraries.items():
                found = self.resource_body(doc, value, "AnimationLibrary")
                if found is None:
                    return None               # one unreadable library -> stay silent
                body, origin = found
                data = body.get("_data")
                if data is None:
                    return None
                origins.append(origin)
                prefix = f"{library}/" if library else ""
                for entry in _LIBRARY_ENTRY.finditer(data[0]):
                    names.add(prefix + _unescape(entry.group(1)))
            return names, ", ".join(sorted(set(origins)))
        return None

    def resource_body(self, doc: SceneDoc, value: str, expected: str
                      ) -> Optional[tuple[dict[str, tuple[str, int]], str]]:
        """The property table of the SubResource/ExtResource `value` refers to."""
        sub = _SUB_REF.search(value)
        if sub:
            entry = doc.sub.get(sub.group(1))
            if entry is None or entry["type"] != expected:
                return None
            return entry["props"], f"the inline {expected} in {doc.res_path}"
        ext = _EXT_REF.search(value)
        if ext:
            ref = doc.ext.get(ext.group(1))
            if ref is None or not ref["path"].endswith(".tres"):
                return None
            other = self.scene_doc(ref["path"])
            if other is None or other.resource_type != expected:
                return None
            return other.resource_props, ref["path"]
        return None

    def check_anim_ref(self, doc: SceneDoc, node: SceneNode, info: ScriptInfo,
                       entry: dict) -> None:
        if "animation_ref" not in self.only:
            return
        expression = entry["node"]
        if entry["binding"]:
            # `anim.play("walk")` — the house style everywhere in
            # templates/gdscript. Only an @onready member bound to exactly one
            # node lookup, never reassigned, resolves; anything else is silent.
            expression = info.binding_target(expression)
            if expression is None:
                return
        located = self.locate_node(doc, node.path, expression)
        if located is None:
            return
        scene, target = located
        if target.type == "AnimationPlayer" and entry["member"] == "animation":
            return                            # AnimationPlayer has no `animation` property
        if target.type != "AnimationPlayer" and entry["member"] in ("queue",
                                                                    "current_animation"):
            return                            # AnimationPlayer-only API
        if target.type in _ANIMATED_SPRITE_TYPES and entry["member"] == "current_animation":
            return
        found = self.animation_names(scene, target)
        if found is None:
            return
        names, origin = found
        if not names or entry["animation"] in names:
            return
        close = nearest_names(entry["animation"], names)
        hint = f" Did you mean {' or '.join('`' + n + '`' for n in close)}?" if close else ""
        self.emit(
            "warning", "animation_ref",
            f"`{entry['raw']}` names an animation that does not exist. "
            + (f"`{entry['node']}` is bound to `{expression}` by an `@onready var`, and "
               if entry["binding"] else "")
            + f"{doc.res_path} resolves `{expression}` to the {target.type} "
            f"`{target.path or target.name}`, whose animations come from {origin} and are: "
            f"{listed(names)}.{hint} "
            + ("An AnimatedSprite2D silently keeps playing the old animation when the name is "
               "unknown." if target.type in _ANIMATED_SPRITE_TYPES else
               "AnimationPlayer.play() with an unknown name prints "
               "`Animation not found` and plays nothing."),
            info.res_path, entry["line"],
            f"Use one of {listed(names)}, or add `{entry['animation']}` to {origin} "
            f"(`build_sprite_frames` for a SpriteFrames, `build_animation` for an "
            f"AnimationPlayer library).",
            rule="unknown_animation",
        )

    def check_scene_animations(self, doc: SceneDoc) -> None:
        """`animation = &"walk"` / `autoplay = "walk"` written straight into the scene."""
        if "animation_ref" not in self.only:
            return
        for node in doc.nodes.values():
            if node.instance_id or self.inside_instance(doc, node):
                continue
            for key in ("animation", "autoplay", "current_animation"):
                prop = node.props.get(key)
                if prop is None:
                    continue
                literal = _QUOTED.match(prop[0].strip())
                if literal is None:
                    continue
                wanted = _unescape(literal.group(1))
                if not wanted or wanted == "[stop]":
                    continue
                found = self.animation_names(doc, node)
                if found is None:
                    continue
                names, origin = found
                if not names or wanted in names:
                    continue
                close = nearest_names(wanted, names)
                hint = (f" Did you mean {' or '.join('`' + n + '`' for n in close)}?"
                        if close else "")
                self.emit(
                    "warning", "animation_ref",
                    f"`{key} = \"{wanted}\"` on the {node.type} "
                    f"`{node.path or node.name}` names an animation that does not exist. Its "
                    f"animations come from {origin} and are: {listed(names)}.{hint}",
                    doc.res_path, prop[1],
                    f"Use one of {listed(names)}, or add `{wanted}` to {origin}.",
                    rule="unknown_animation",
                )

    def inside_instance(self, doc: SceneDoc, node: SceneNode) -> bool:
        """True when `node` is an instanced sub-scene root, or sits under one.

        `[node name="Player" parent="." instance=ExtResource("…")]` is the root of
        player.tscn, and `[node name="Sprite" parent="Player"]` under it is a
        property override on a node that belongs to player.tscn.
        """
        if node.instance_id:
            return True
        path = node.path
        while path:
            path = path.rsplit("/", 1)[0] if "/" in path else ""
            ancestor = doc.nodes.get(path)
            if ancestor is not None and ancestor.instance_id:
                return True
            if not path:
                break
        return False

    def check_ref(self, doc: SceneDoc, node: SceneNode, info: ScriptInfo, entry: dict) -> None:
        path = entry["path"]
        if not path or path.startswith("res://") or path.startswith("/"):
            return
        if any(token in entry["raw"] for token in _DYNAMIC):
            self.scan_summary["skipped_dynamic_paths"] += 1
            return
        first = path.split("/", 1)[0].lstrip("%")
        if first in self.autoloads:
            return
        attached = self._node_display(doc, node)
        if path.startswith("%"):
            name = path[1:].split("/", 1)[0]
            if name not in doc.unique_names:
                if "unique_name" in self.only:
                    known = ", ".join(sorted(doc.unique_names)) or "(none)"
                    self.emit(
                        "error", "unique_name",
                        f"`%{name}` is used by {info.res_path}, which {doc.res_path} attaches to "
                        f"{attached}, but no node in that scene sets "
                        f"`unique_name_in_owner = true` with the name `{name}`, so the lookup "
                        f"returns null at runtime. Unique names declared in that scene: {known}.",
                        info.res_path, entry["line"],
                        f"Set `unique_name_in_owner = true` on the node named `{name}` in "
                        f"{doc.res_path} (configure_node with "
                        f"`\"unique_name_in_owner\": true`, or the line "
                        f"`unique_name_in_owner = true` under that [node] block), or address it "
                        f"with a relative path such as `$Panel/{name}` instead of `%{name}`. "
                        f"If the node does not exist yet, add it first with add_node.",
                        rule="unique_name_missing",
                    )
                return
            base = doc.unique_names[name]
            rest = path[1:].split("/", 1)
            remainder = rest[1] if len(rest) > 1 else ""
            if not remainder:
                return
            status, detail = self.resolve(doc, base, remainder)
        else:
            status, detail = self.resolve(doc, node.path, path)
        self.scan_summary["node_paths_checked"] += 1
        if status == "ok" or status == "skip":
            return
        if "node_ref" not in self.only:
            return
        severity = "warning" if entry["kind"] == "get_node_or_null" else "error"
        self.emit(
            severity, "node_ref",
            f"`{entry['raw']}` does not resolve. {doc.res_path} attaches this script to "
            f"{attached}, and there is no node `{detail['segment']}` at that point in the tree.",
            info.res_path, entry["line"],
            f"In {doc.res_path} the script is on {attached}, and the path `{path}` breaks at "
            f"`{detail['segment']}`. {self._children_sentence(detail)} Point the path at one of "
            f"those children, or add a node named `{detail['segment']}` there with add_node. "
            f"A path in a script is relative to the node the script is attached to, not to the "
            f"scene root — use `%UniqueName` or an `@export var target: NodePath` when the node "
            f"lives elsewhere.",
            rule="node_path_missing",
        )

    def check_connections(self, doc: SceneDoc) -> None:
        if "signal_target" not in self.only and "missing_resource" not in self.only:
            return
        for connection in doc.connections:
            line = connection["line"]
            for role in ("from", "to"):
                path = connection[role]
                if path in (".", ""):
                    continue
                status, detail = self.resolve(doc, "", path)
                if status == "missing":
                    self.emit(
                        "error", "signal_target",
                        f"`[connection signal=\"{connection['signal']}\" ...]` has "
                        f"{role}=\"{path}\", but no such node exists in {doc.res_path}. Godot "
                        f"drops a connection with a bad path silently — the file keeps the line "
                        f"and nothing is ever connected.",
                        doc.res_path, line,
                        f"{self._children_sentence(detail)} Use a path from the scene root with "
                        f"the root's own name left out (`.` is the root), matching the node names "
                        f"exactly.",
                        rule="connection_path",
                    )
                    break
            else:
                self.check_connection_method(doc, connection)

    def check_connection_method(self, doc: SceneDoc, connection: dict) -> None:
        target_path = "" if connection["to"] in (".", "") else connection["to"]
        node = doc.nodes.get(target_path)
        if node is None:
            return
        method = connection["method"]
        script_path, exists = self.node_script(doc, node)
        display = self._node_display(doc, node)
        if script_path is not None and not script_path.endswith((".gd", ".cs")):
            return                      # another language's script: cannot be read here
        if script_path is None:
            self.emit(
                "error", "signal_target",
                f"`[connection signal=\"{connection['signal']}\"]` targets {display} with "
                f"method `{method}`, but that node has no script, so the method cannot exist.",
                doc.res_path, connection["line"],
                f"Attach a script that defines `func {method}(...)` to {display} "
                f"(attach_script), or point the connection at the node that has the handler.",
                rule="connection_no_script",
            )
            return
        if not exists:
            self.emit(
                "error", "missing_resource",
                f"`[connection signal=\"{connection['signal']}\"]` targets {display}, whose "
                f"script `{script_path}` does not exist on disk.",
                doc.res_path, connection["line"],
                f"Create `{script_path}` with `func {method}(...)`, or re-attach an existing "
                f"script to {display}.",
                rule="connection_script_missing",
            )
            return
        if "signal_target" not in self.only:
            return
        if self.method_defined(script_path, method):
            return
        info = self.script_info(script_path)
        known = ", ".join(sorted(info.funcs)[:12]) if info and info.funcs else "(none)"
        self.emit(
            "error", "signal_target",
            f"`[connection signal=\"{connection['signal']}\" to=\"{connection['to']}\" "
            f"method=\"{method}\"]` names a method `{script_path}` does not define. The connection "
            f"is made anyway and only fails when the signal fires.",
            doc.res_path, connection["line"],
            f"Add `func {method}(...) -> void:` to {script_path}, or change the connection's "
            f"method. Functions defined there: {known}.",
            rule="connection_method_missing",
        )

    # `\bOnPressed\s*\(` — good enough for "does this C# file define that
    # method", without pretending to parse C#.
    def method_defined(self, script_path: str, method: str, depth: int = 0) -> bool:
        if depth > 8:
            return True
        if not script_path.endswith(".gd"):
            if script_path.endswith(".cs"):
                target = self.abs_of(script_path)
                if target is None or not target.is_file():
                    return True
                text = target.read_text(encoding="utf-8", errors="replace")
                return re.search(r"\b" + re.escape(method) + r"\s*\(", text) is not None
            # .gdns, a GDExtension-backed script, anything else: not ours to read.
            return True
        info = self.script_info(script_path)
        if info is None:
            return True
        if method in info.funcs:
            return True
        parent = info.extends
        if not parent:
            return False
        if parent.startswith("res://"):
            return self.method_defined(parent, method, depth + 1)
        base = self.class_index.get(parent.split(".")[0])
        if base:
            return self.method_defined(base, method, depth + 1)
        # extends a built-in engine class: the method may be an engine callback.
        return False

    # -- entry point ------------------------------------------------------
    def run(self) -> dict:
        self.load_project_settings()
        files = list(self.iter_files())
        for path in files:
            if path.suffix == ".gd":
                self.scan_script(path)
        for script in self._scripts.values():
            self._project_funcs |= script.funcs
        for path in files:
            if path.suffix in (".tscn", ".scn"):
                self.index_scene(path)
        for path in files:
            if path.suffix in (".tscn", ".scn"):
                self.scan_scene(path)
            elif path.suffix == ".tres":
                self.scan_resource(path)
            elif path.suffix in (".gdshader", ".gdshaderinc"):
                self.scan_shader_file(path)
            elif path.suffix == ".shader":
                self.emit("error", "godot3_shader", SHADER_EXTENSION_RULE["message"],
                          self.res(path), 1, SHADER_EXTENSION_RULE["fix"],
                          rule=SHADER_EXTENSION_RULE["id"])
        self.flush_godot3()
        self.flush_input_actions()
        self.flush_groups()
        self.flush_res_paths()
        order = {"error": 0, "warning": 1}
        self.diagnostics.sort(key=lambda item: (
            order.get(item["severity"], 2), item["file"] or "", item["line"] or 0, item["category"]))
        counts = {
            "total": len(self.diagnostics),
            "errors": sum(1 for item in self.diagnostics if item["severity"] == "error"),
            "warnings": sum(1 for item in self.diagnostics if item["severity"] == "warning"),
            "parse_errors": 0,
        }
        by_category = {name: 0 for name in CATEGORIES}
        for item in self.diagnostics:
            by_category[item["category"]] = by_category.get(item["category"], 0) + 1
        return {
            "ok": counts["errors"] == 0,
            "project_path": str(self.project),
            "counts": counts,
            "categories": by_category,
            "scan_summary": self.scan_summary,
            "suppressions": self.suppression_report(),
            "diagnostics": self.diagnostics,
        }


def lint_project(project_path: str | Path, only: Optional[Iterable[str]] = None,
                 include_addons: bool = False, subpath: str = "",
                 warnings_as_errors: bool = False) -> dict:
    """Lint a project directory and return the report dict."""
    project = Path(project_path).expanduser().resolve()
    if not (project / "project.godot").is_file():
        raise SystemExit(
            f"Missing Godot project file: {project / 'project.godot'}. Pass the directory that "
            f"contains project.godot (the Godot project root), not a subdirectory of it and not "
            f"the skill folder.")
    selected = set(only) if only else set(CATEGORIES)
    unknown = selected - set(CATEGORIES)
    if unknown:
        raise SystemExit(
            f"Unknown --only category: {', '.join(sorted(unknown))}. "
            f"Valid categories: {', '.join(CATEGORIES)}.")
    report = Linter(project, selected, include_addons, subpath).run()
    if warnings_as_errors and report["counts"]["warnings"]:
        report["ok"] = False
    return report


def rules_markdown() -> str:
    """The Godot 3 -> 4.7 rename table as markdown, grouped. Source for
    references/godot3_to_4.md."""
    lines: list[str] = []
    for group in GROUP_ORDER:
        entries = [rule for rule in GODOT3_RULES if rule["group"] == group]
        if not entries:
            continue
        lines.append(f"### {group}")
        lines.append("")
        lines.append("| Godot 3 | Godot 4.7 | Level | Rule id | Fix |")
        lines.append("| --- | --- | --- | --- | --- |")
        for rule in entries:
            fix = rule["fix"].replace("|", "\\|").replace("\n", " ")
            lines.append(
                f"| `{rule['token']}` | `{rule['replacement']}` | {rule['severity']} | "
                f"`{rule['id']}` | {fix} |")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


SUPPRESSION_HELP = """
Suppressing one finding
-----------------------
  var layer := $Parallax  # lint:ignore node_ref
  # lint:ignore godot3_api,inference
  var legacy := old_api()

`# lint:ignore <category>[,<category>…]` covers the line it sits on and the line
directly below it. A bare `# lint:ignore` covers every category there. The
comment marker follows the file type: `#` in .gd, `;` in .tscn/.tres and
project.godot, `//` in .gdshader. Suppressions that matched nothing are listed
under `suppressions.unused` in the JSON and never change the exit code.

A directory containing a `.gdignore` file is skipped entirely — Godot does not
import it, so the linter does not read it either.
"""


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Static Godot 4.x project linter (no Godot binary required).",
        epilog=SUPPRESSION_HELP, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("project_path", nargs="?", help="Godot project directory.")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print the JSON output.")
    parser.add_argument("--json", action="store_true",
                        help="Emit JSON (the default; accepted for symmetry).")
    parser.add_argument("--warnings-as-errors", action="store_true",
                        help="Fail the run when any warning is reported.")
    parser.add_argument("--only", default="",
                        help=f"Comma-separated categories to report: {', '.join(CATEGORIES)}.")
    parser.add_argument("--path", default="",
                        help="Restrict the walk to this subdirectory (relative to the project).")
    parser.add_argument("--include-addons", action="store_true",
                        help="Lint addons/ too (skipped by default).")
    parser.add_argument("--list-rules", action="store_true",
                        help="Print the Godot 3 -> 4.7 rule table as markdown and exit.")
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    if args.list_rules:
        sys.stdout.write(rules_markdown())
        return 0
    if not args.project_path:
        parser.error("project_path is required (or use --list-rules)")

    only = [name.strip() for name in args.only.split(",") if name.strip()] or None
    report = lint_project(args.project_path, only=only, include_addons=args.include_addons,
                          subpath=args.path, warnings_as_errors=args.warnings_as_errors)
    print(json.dumps(report, indent=2 if args.pretty else None))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
