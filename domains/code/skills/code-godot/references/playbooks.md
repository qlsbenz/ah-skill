# Playbooks — Follow The Numbered Steps Literally

Every playbook below is a finished recipe: copy each numbered block in order,
substituting only `/absolute/path/to/godot` (this skill's root) and
`/absolute/path/to/project` (the Godot project). Do not reorder the steps, do
not merge them, and do not paraphrase the JSON — the dispatcher rejects an
unknown key with the nearest valid name, so an invented field fails loudly and
writes nothing.

Every playbook starts with a **Requires.** line naming the earlier playbooks it
builds on (`§1`, `§1, §2`, or `Nothing`). Replay those first, in the order they
are numbered, into the same project — a section is only guaranteed to work in a
project where exactly that chain has been run.

Every playbook ends with a **Verify** block. A playbook is not done until that
block runs clean. Verified on `godot 4.7.stable`: `tests/test_playbooks_replay.py`
extracts the `bash` blocks from this file, substitutes the two placeholders and
runs every section end to end, so a block that does not work here is a test
failure, not a documentation bug.

## Route By Task

| Task | Playbook | Verification command |
| --- | --- | --- |
| Start a new 2D pixel-art game | [1. 2D pixel-art bootstrap](#1-2d-pixel-art-project-bootstrap) | `validate_project.py --pretty` → `"ok": true` |
| Player that runs and jumps | [2. 2D platformer player](#2-2d-platformer-player) | `run_scenario.py` → `"ok": true` |
| Player that walks in 8 directions | [3. Top-down player](#3-top-down-player) | `run_scenario.py` → `"ok": true` |
| Enemy that patrols and can be killed | [4. Enemy, damage, pooled bullets](#4-enemy-with-patrol-hitbox-hurtbox-and-health) | `run_scenario.py` → `"ok": true` |
| Build a level out of tiles | [5. Tile level from ASCII](#5-tile-level-from-ascii) | `inspect_tilemap` `"format":"text"` → rows match the ASCII |
| Title screen that is not gray | [6. Main menu with a theme](#6-main-menu-with-a-theme) | `run_scenario.py` → `ui_report` `findings=0` |
| Score / lives / health on screen | [7. HUD bound to GameManager](#7-hud-bound-to-gamemanager) | `run_scenario.py` → `ui_report` `findings=0` |
| Esc opens a pause menu | [8. Pause menu](#8-pause-menu) | `run_scenario.py` → `paused` assertion passes |
| Characters that talk | [9. Dialog box](#9-dialog-box) | `run_scenario.py` → `dump_tree` shows the typed text |
| Persist progress between runs | [10. Save and load](#10-save-and-load) | `run_project.py` → log shows `save ok` / `load ok` |
| Fade between scenes, music and SFX | [11. Scene transitions and audio](#11-scene-transitions-and-audio-manager) | `run_project.py` → `counts.errors == 0` |
| First-person 3D starter | [12. 3D FPS starter](#12-3d-fps-starter) | `run_scenario.py` → `"ok": true` |
| Sound effects and music from nothing | [13. Sound and music](#13-sound-and-music-from-nothing) | `inspect_audio` `expect` → exit 0 |
| Sprites, tiles and UI art with no image generator | [14. Pixel art from ASCII](#14-pixel-art-from-ascii) | `inspect_image` `expect` + `inspect_tilemap` rows |
| Items the player picks up, carries and saves | [15. Inventory, items and loot](#15-inventory-items-and-loot) | `run_tests.py` → `"ok": true`; `ui_report` `findings=0` |
| An NPC conversation that branches on a flag | [16. Branching dialogue](#16-branching-dialogue) | `run_tests.py` + `run_scenario.py` → `"ok": true` |
| Volume, fullscreen and key rebinding that persist | [17. Settings menu](#17-settings-menu-volume-fullscreen-remap) | `ui_report` `findings=0` at two sizes; `settings.cfg` reread in a second run |
| A whole small game, empty folder to winnable level | [18. Collectathon platformer](#18-collectathon-platformer-a-complete-loop) | `run_scenario.py` → scripted run reaches the goal; `spatial_report` `findings=0` |
| Coins, checkpoints, moving platforms, a kill zone, a goal | [18. Collectathon platformer](#18-collectathon-platformer-a-complete-loop) | `validate_project.py --warnings-as-errors` → `"ok": true` |
| Waves of enemies that path around walls and shoot back | [19. Top-down wave shooter](#19-top-down-wave-shooter) | `run_scenario.py` → wave counter advances; no `mask_targets_empty_layer` |
| Pooled projectiles, damage numbers, a baked 2D navmesh | [19. Top-down wave shooter](#19-top-down-wave-shooter) | `check_project` `physics_layers.findings` → no `mask_targets_empty_layer` |
| Tile-step movement, crate pushing, undo | [20. Grid puzzle (Sokoban)](#20-grid-puzzle-sokoban) | `run_tests.py` → 11 passed; `run_scenario.py` solves it in two `key` steps |
| Third-person 3D character with an orbit camera | [21. 3D third-person starter](#21-3d-third-person-starter) | `run_scenario.py` → `spatial_report` `fail_on` `no_camera_3d`/`no_light_3d` clean |
| Is this project actually finished | [22. Before you call it done](#22-before-you-call-it-done) | the five commands, each exiting 0 |
| Any script you just wrote | every playbook's Verify block | `lint_project.py` → `counts.errors == 0` |
| An op whose parameters you forgot | — | `help '{"op":"add_node"}'` |
| A UI that might be stacked at (0,0) | 6, 7, 8, 9, 15, 16, 17 | `run_scenario.py` `ui_report` `"fail_on":["any"]` |

## Driving Input In A Scenario

The two input step types are not interchangeable, and picking the wrong one is
why a scenario "does nothing" while the game works when a human plays it.

| Step | What it does | Reaches |
| --- | --- | --- |
| `{"type":"action","action_name":"jump","pressed":true}` | Calls `Input.action_press` / `action_release` — flips the action's polled state only | `Input.is_action_pressed` / `is_action_just_pressed` in `_process` / `_physics_process` |
| `{"type":"key","keycode":4194305,"pressed":true}` | Builds a real `InputEventKey` and feeds it through `Input.parse_input_event` | `_input`, `_unhandled_input`, `_gui_input`, **and** the polled state |

- Player controllers poll, so `action` steps drive them (Playbooks 2, 3, 12).
- Menus, pause toggles, dialog advance and `interact` prompts live in
  `_unhandled_input`, so they need `key` steps (Playbooks 8, 9). An `action`
  step there silently changes nothing.
- `key` has no `release_after`: send an explicit `"pressed": false` step, or the
  key stays held for the rest of the run.
- **Never time physics with `wait_frames` in a headless run.** `wait_frames`
  counts *process* frames, and headless spins those far faster than the fixed
  60 Hz physics tick — `wait_frames: 60` is a small fraction of a second of
  simulated falling. Use `wait_seconds` (a real timer) or `wait_until` whenever
  the thing being waited for is gravity, a `move_and_slide`, or a Tween.
- Match the field the action was bound with. Godot's built-in `ui_*` actions are
  bound by **`keycode`** (`ui_cancel` 4194305, `ui_accept` 4194309, `ui_down`
  4194322); actions this skill creates use `physical_keycode`, so drive those
  with `"physical_keycode"`. Setting the wrong one produces an event that
  matches no action at all.

## Template Index

`templates/gdscript/` holds GDScript that already compiles with zero warnings
under `check_project --debug --ignore-error-breaks`. **Copy a template instead
of writing a controller from memory.** Each file starts with a comment header
giving the exact scene tree it expects, the autoloads it needs, the input
actions to create, and a runnable `attach_script` call.

| Template | What it is | Playbook |
| --- | --- | --- |
| `templates/gdscript/player_platformer_2d.gd` | CharacterBody2D: gravity, coyote time, jump buffer, short hop | 2 |
| `templates/gdscript/player_topdown_2d.gd` | CharacterBody2D: 8-way movement, remembered facing | 3 |
| `templates/gdscript/player_fps_3d.gd` | CharacterBody3D: mouse look, sprint, jump, Esc releases the mouse | 12 |
| `templates/gdscript/state.gd` | `class_name State` — enter/exit/update/physics_update + transition signal | 4 |
| `templates/gdscript/state_machine.gd` | `class_name StateMachine` — children keyed by node name | 4 |
| `templates/gdscript/enemy_patrol_2d.gd` | Waypoint or raycast patrol with edge and wall checks | 4 |
| `templates/gdscript/health.gd` | `class_name Health` — max/current, damaged/died, invulnerability window | 4, 7 |
| `templates/gdscript/hitbox.gd` | `class_name Hitbox` — Area2D that deals damage, team-filtered | 4 |
| `templates/gdscript/hurtbox.gd` | `class_name Hurtbox` — Area2D that receives it and feeds Health | 4 |
| `templates/gdscript/object_pool.gd` | `class_name ObjectPool` — reuse PackedScene instances | 4 |
| `templates/gdscript/main_menu.gd` | Title screen: New Game / Continue / Settings / Quit, gamepad focus | 6 |
| `templates/gdscript/hud.gd` | Binds score, lives and a health bar to signals | 7 |
| `templates/gdscript/pause_menu.gd` | `ui_cancel` toggles `get_tree().paused`, process mode ALWAYS | 8 |
| `templates/gdscript/dialog_box.gd` | Typewriter over `Array[String]`, `ui_accept` advances | 9 |
| `templates/gdscript/interactable.gd` | `class_name Interactable` — Area2D prompt + `interact()` to override | 9 |
| `templates/gdscript/game_manager.gd` | Autoload `GameManager`: score, lives, `reset()` | 7, 10 |
| `templates/gdscript/save_manager.gd` | Autoload `SaveManager`: versioned JSON under `user://` | 10 |
| `templates/gdscript/scene_transition.gd` | Autoload `SceneTransition`: fade + `change_scene()` | 11 |
| `templates/gdscript/audio_manager.gd` | Autoload `AudioManager`: SFX pool + music crossfade | 11 |
| `templates/gdscript/camera_shake_2d.gd` | Camera2D trauma shake with decay | 2 |
| `templates/gdscript/item_data.gd` | `class_name ItemData extends Resource` — one .tres per item: id, icon, stack size, value, tags | 15 |
| `templates/gdscript/inventory.gd` | `class_name Inventory` — slots, stacking rules, `to_dict()`/`from_dict()` for the save file | 15 |
| `templates/gdscript/loot_table.gd` | `class_name LootTable extends Resource` — weighted drops, seeded so a test can assert on them | 15 |
| `templates/gdscript/inventory_ui.gd` | Grid of focusable slot buttons bound to an `Inventory` | 15 |
| `templates/gdscript/dialogue_runner.gd` | `class_name DialogueRunner` — branching graph, flags, graph validation on load | 16 |
| `templates/gdscript/choice_list.gd` | `class_name ChoiceList` — the answer buttons under a dialog line | 16 |
| `templates/gdscript/settings.gd` | Autoload `Settings`: volumes, fullscreen, vsync and rebinds in `user://settings.cfg` | 17 |
| `templates/gdscript/settings_menu.gd` | Sliders and switches bound to `Settings`, for a screen or a pause panel | 17 |
| `templates/gdscript/input_remap.gd` | Press-a-key rebinding with conflict handling, persisted through `Settings` | 17 |
| `templates/gdscript/collectible.gd` | Area2D pickup: value, group filter, `collected`, optional score and SFX | 18 |
| `templates/gdscript/checkpoint.gd` | Area2D that becomes the one active respawn point in the level | 18 |
| `templates/gdscript/kill_zone.gd` | Pit or spikes: damage, lose a life, teleport back to the checkpoint | 18 |
| `templates/gdscript/goal.gd` | Level exit that stays locked until a group is empty, then changes scene | 18 |
| `templates/gdscript/moving_platform.gd` | `AnimatableBody2D` walking a point list, `sync_to_physics` carries the rider | 18 |
| `templates/gdscript/projectile.gd` | `class_name Projectile` — travels, expires, returns itself to an `ObjectPool` | 19 |
| `templates/gdscript/shooter.gd` | Fire rate, muzzle, aim at the mouse or the owner facing, pools its bullets | 19 |
| `templates/gdscript/wave_spawner.gd` | Waves, spawn points, `wave_started` / `wave_cleared` / `all_waves_cleared` | 19 |
| `templates/gdscript/enemy_chase_nav_2d.gd` | `NavigationAgent2D` chaser with a re-path timer and a straight-line fallback | 19 |
| `templates/gdscript/damage_number.gd` | `class_name DamageNumber` — floating tweened Label that frees itself | 19 |
| `templates/gdscript/grid_movement.gd` | `class_name GridMovement` — tile-step tween, walls, crate pushing; static pure rules | 20 |
| `templates/gdscript/sokoban_level.gd` | ASCII level, crates on targets, `solved`, undo and restart | 20 |
| `templates/gdscript/player_third_person_3d.gd` | CharacterBody3D + SpringArm3D orbit camera, camera-relative movement | 21 |

Rules that apply to every template:

- Copy the file, then read its header. The header lists node names and types
  that must exist before the script runs; `$Sprite2D` on a scene with no
  `Sprite2D` is a null at runtime, not a compile error.
- Never rewrite a template's `@onready var x: Type = $Path` as `var x := $Path`.
  `$` is statically typed `Node`, so `:=` silently widens the type and every
  later member access goes unchecked (`references/gdscript_conventions.md`).
- After copying any template with a `class_name` (`state.gd`,
  `state_machine.gd`, `health.gd`, `hitbox.gd`, `hurtbox.gd`,
  `object_pool.gd`, `interactable.gd`, `projectile.gd`, `damage_number.gd`,
  `grid_movement.gd`), run
  `godot --headless --path /absolute/path/to/project --import` before
  validating, or every reference to that class reads as undeclared.

---

## 1. 2D Pixel-Art Project Bootstrap

**Goal.** A project that renders pixel art crisply, has a window size and
stretch mode chosen on purpose, a main scene, and the input actions the other
playbooks assume.

**Requires.** Nothing — this playbook starts from an empty folder.

### Step 1 — Create the folders and the project file

```bash
mkdir -p /absolute/path/to/project/scenes \
         /absolute/path/to/project/scripts \
         /absolute/path/to/project/art \
         /absolute/path/to/project/theme \
         /absolute/path/to/project/tilesets
test -f /absolute/path/to/project/project.godot || cat > /absolute/path/to/project/project.godot <<'GODOT'
config_version=5

[application]

config/name="Game"
GODOT
```

`config_version=5` plus an `[application]` section is the whole minimum for a
Godot 4 project. The `test -f` guard matters: on an existing project this block
must change nothing, because from here on `ProjectSettings.save()` owns that
file and rewrites it whole.

### Step 2 — Window, stretch, and pixel filtering

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "backup_path": "project.godot.bak",
    "actions": [
      {"type":"set_setting","name":"display/window/size/viewport_width","value":640},
      {"type":"set_setting","name":"display/window/size/viewport_height","value":360},
      {"type":"set_setting","name":"display/window/size/window_width_override","value":1280},
      {"type":"set_setting","name":"display/window/size/window_height_override","value":720},
      {"type":"set_setting","name":"display/window/stretch/mode","value":"canvas_items"},
      {"type":"set_setting","name":"display/window/stretch/aspect","value":"keep"},
      {"type":"set_setting","name":"rendering/textures/canvas_textures/default_texture_filter","value":0},
      {"type":"set_setting","name":"gui/theme/default_font_antialiasing","value":0},
      {"type":"set_setting","name":"gui/theme/default_font_hinting","value":0},
      {"type":"set_setting","name":"gui/theme/default_font_subpixel_positioning","value":0}
    ]
  }'
```

`stretch/mode` is `canvas_items` here so UI text stays smooth at any window
size. Use `"viewport"` plus `"scale_mode":"integer"` only when the UI is itself
drawn as pixel art — mixing the two makes text mush.

Do not hand-edit `project.godot` to add these. `ProjectSettings.save()`
rewrites the whole file, so a manual edit made in the same session is dropped.

### Step 3 — Input actions

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"add_input_action","action_name":"move_left","replace":true},
      {"type":"add_input_event","action_name":"move_left","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":65}}},
      {"type":"add_input_action","action_name":"move_right","replace":true},
      {"type":"add_input_event","action_name":"move_right","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":68}}},
      {"type":"add_input_action","action_name":"move_up","replace":true},
      {"type":"add_input_event","action_name":"move_up","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":87}}},
      {"type":"add_input_action","action_name":"move_down","replace":true},
      {"type":"add_input_event","action_name":"move_down","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":83}}},
      {"type":"add_input_action","action_name":"jump","replace":true},
      {"type":"add_input_event","action_name":"jump","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":32}}},
      {"type":"add_input_action","action_name":"interact","replace":true},
      {"type":"add_input_event","action_name":"interact","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":69}}}
    ]
  }'
```

Physical keycodes: `A` 65, `D` 68, `W` 87, `S` 83, `E` 69, Space 32, Shift
4194325, Esc 4194305. Use `physical_keycode` (layout-independent), not
`keycode`, or the game is unplayable on AZERTY.

### Step 4 — Main scene and layers

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/main.tscn",
    "create_if_missing": true,
    "root_node_type": "Node2D",
    "root_node_name": "Main",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"Node2D","node_name":"World"},
      {"type":"add_node","parent_node_path":"root","node_type":"CanvasLayer","node_name":"UI"}
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"set_main_scene","scene_path":"res://scenes/main.tscn"},
      {"type":"set_layer_name","layer_type":"2d_physics","layer":1,"layer_name":"world"},
      {"type":"set_layer_name","layer_type":"2d_physics","layer":2,"layer_name":"player"},
      {"type":"set_layer_name","layer_type":"2d_physics","layer":3,"layer_name":"enemy"},
      {"type":"set_layer_name","layer_type":"2d_physics","layer":4,"layer_name":"hitbox"}
    ]
  }'
```

### Step 5 — Register the shared autoloads

Do this now, before any UI playbook. `main_menu.gd`, `pause_menu.gd` and
`hud.gd` name `GameManager`, `SaveManager` and `SceneTransition` directly, and a
script that names an unregistered autoload does not merely misbehave — it fails
to parse, so `attach_script` aborts with
`Property does not exist at attach_script.script_properties: …`.

```bash
cp /absolute/path/to/godot/templates/gdscript/game_manager.gd \
   /absolute/path/to/godot/templates/gdscript/save_manager.gd \
   /absolute/path/to/godot/templates/gdscript/scene_transition.gd \
   /absolute/path/to/project/scripts/
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"add_autoload","autoload_name":"GameManager","path":"res://scripts/game_manager.gd","singleton":true},
      {"type":"add_autoload","autoload_name":"SaveManager","path":"res://scripts/save_manager.gd","singleton":true},
      {"type":"add_autoload","autoload_name":"SceneTransition","path":"res://scripts/scene_transition.gd","singleton":true}
    ]
  }'
```

`AudioManager` is deliberately not here: it must be registered *after* the audio
buses exist (Playbook 11), or every player it builds falls back to Master and
the validation run carries a warning.

### Verify

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project --quit-after 60 --timeout 60 --pretty
```

Expected: `lint_project.py` reports `"ok": true` with `counts.errors == 0`;
`validate_project.py` reports `"ok": true`, `counts.errors == 0`,
`counts.warnings == 0`, `static.failed_count == 0`; `run_project.py` reports
`"ok": true` and `"timed_out": false`.

---

## 2. 2D Platformer Player

**Goal.** A player scene that runs, jumps with coyote time and a jump buffer,
and is followed by a camera that can shake.

**Requires.** §1 — `move_left`, `move_right` and `jump` come from its input map.

### Step 1 — Copy the templates

```bash
cp /absolute/path/to/godot/templates/gdscript/player_platformer_2d.gd \
   /absolute/path/to/project/scripts/player_platformer_2d.gd
cp /absolute/path/to/godot/templates/gdscript/camera_shake_2d.gd \
   /absolute/path/to/project/scripts/camera_shake_2d.gd
```

### Step 2 — Build the player scene

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/player.tscn",
    "create_if_missing": true,
    "root_node_type": "CharacterBody2D",
    "root_node_name": "Player",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":2,"collision_mask":1},"groups_add":["player"]},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CapsuleShape2D","properties":{"radius":6.0,"height":20.0}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Sprite2D","node_name":"Sprite2D"},
      {"type":"add_node","parent_node_path":"root","node_type":"Camera2D","node_name":"Camera2D",
       "properties":{"position_smoothing_enabled":true,"position_smoothing_speed":6.0}},
      {"type":"configure_node","node_path":"root/Camera2D","unique_name_in_owner":true},
      {"type":"attach_script","node_path":"root","script_path":"scripts/player_platformer_2d.gd",
       "script_properties":{"speed":220.0,"jump_velocity":-380.0,"coyote_time":0.12,"jump_buffer_time":0.12}},
      {"type":"attach_script","node_path":"root/Camera2D","script_path":"scripts/camera_shake_2d.gd",
       "script_properties":{"decay":4.0}}
    ]
  }'
```

The node names `Sprite2D` and `Camera2D` are not decoration: the template reads
`$Sprite2D`. Rename them and the script finds nothing.

`Camera2D` is marked unique **inside `player.tscn`**, so a script on the Player
root reaches the shake as `%Camera2D.add_trauma(0.5)`. A level script cannot —
unique names resolve only within their own scene, so from the level the path is
`$Player/Camera2D`.

### Step 3 — Ground to stand on and a spawn point

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level_1.tscn",
    "create_if_missing": true,
    "root_node_type": "Node2D",
    "root_node_name": "Level",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"StaticBody2D","node_name":"Ground",
       "properties":{"position":{"__type":"Vector2","x":0,"y":200},"collision_layer":1}},
      {"type":"add_node","parent_node_path":"root/Ground","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":1200,"y":32}}}}},
      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/player.tscn","node_name":"Player",
       "properties":{"position":{"__type":"Vector2","x":0,"y":100}}}
    ]
  }'
```

### Step 4 — Point the project at the level

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{"actions":[{"type":"set_main_scene","scene_path":"res://scenes/level_1.tscn"}]}'
```

### Verify

Write the scenario, then run the four checks.

```bash
cat > /absolute/path/to/project/scenario_player.json <<'JSON'
{
  "scene_path": "res://scenes/level_1.tscn",
  "viewport_size": {"width": 640, "height": 360},
  "settle_frames": 4,
  "steps": [
    {"type": "wait_seconds", "seconds": 1.0},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "position:y",
     "expected": 190.0, "operator": "less_or_equal"},
    {"type": "log_marker", "message": "gravity-ok"},
    {"type": "action", "action_name": "move_right", "pressed": true},
    {"type": "wait_seconds", "seconds": 0.4},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "position:x",
     "expected": 5.0, "operator": "greater_than"},
    {"type": "action", "action_name": "move_right", "pressed": false},
    {"type": "action", "action_name": "jump", "pressed": true, "release_after": true},
    {"type": "wait_seconds", "seconds": 0.1},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "velocity:y",
     "expected": 0.0, "operator": "less_than"},
    {"type": "dump_tree", "node_path": "/root", "properties": ["position", "velocity"], "max_depth": 4, "label": "after-jump"}
  ],
  "assertions": [
    {"assertion": "node_exists", "node_path": "Player/Camera2D"}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project --quit-after 120 --timeout 60 --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_player.json --pretty
```

Expected: `lint_project.py` `counts.errors == 0`; `validate_project.py`
`"ok": true` with `counts.errors == 0` and `counts.warnings == 0`;
`run_project.py` `"ok": true`; `run_scenario.py` `"ok": true` with every
assertion passing and the `after-jump` `dump_tree` showing a negative
`velocity:y` on `Player`.

---

## 3. Top-Down Player

**Goal.** A player that walks in eight directions at a constant speed, with the
diagonal not faster than the cardinals.

**Requires.** §1 — `move_left`, `move_right`, `move_up` and `move_down`.

### Step 1 — Copy the template

```bash
cp /absolute/path/to/godot/templates/gdscript/player_topdown_2d.gd \
   /absolute/path/to/project/scripts/player_topdown_2d.gd
```

### Step 2 — Build the player scene

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/player.tscn",
    "create_if_missing": true,
    "root_node_type": "CharacterBody2D",
    "root_node_name": "Player",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":2,"collision_mask":1},"groups_add":["player"]},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CircleShape2D","properties":{"radius":7.0}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Sprite2D","node_name":"Sprite2D"},
      {"type":"add_node","parent_node_path":"root","node_type":"Camera2D","node_name":"Camera2D",
       "properties":{"position_smoothing_enabled":true,"position_smoothing_speed":8.0}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/player_topdown_2d.gd",
       "script_properties":{"speed":180.0,"acceleration":1400.0,"friction":1600.0}}
    ]
  }'
```

Do not build eight-direction movement by adding the four axes yourself; the
template uses `Input.get_vector`, which normalises the diagonal for you.

### Step 3 — A room with walls

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/room.tscn",
    "create_if_missing": true,
    "root_node_type": "Node2D",
    "root_node_name": "Room",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"StaticBody2D","node_name":"Walls","properties":{"collision_layer":1}},
      {"type":"add_node","parent_node_path":"root/Walls","node_type":"CollisionShape2D","node_name":"North",
       "properties":{"position":{"__type":"Vector2","x":0,"y":-160},
        "shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":640,"y":16}}}}},
      {"type":"add_node","parent_node_path":"root/Walls","node_type":"CollisionShape2D","node_name":"South",
       "properties":{"position":{"__type":"Vector2","x":0,"y":160},
        "shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":640,"y":16}}}}},
      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/player.tscn","node_name":"Player"}
    ]
  }'
```

### Verify

```bash
cat > /absolute/path/to/project/scenario_topdown.json <<'JSON'
{
  "scene_path": "res://scenes/room.tscn",
  "viewport_size": {"width": 640, "height": 360},
  "settle_frames": 4,
  "steps": [
    {"type": "action", "action_name": "move_right", "pressed": true},
    {"type": "action", "action_name": "move_down", "pressed": true},
    {"type": "wait_seconds", "seconds": 0.5},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "position:x",
     "expected": 5.0, "operator": "greater_than"},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "position:y",
     "expected": 5.0, "operator": "greater_than"},
    {"type": "action", "action_name": "move_right", "pressed": false},
    {"type": "action", "action_name": "move_down", "pressed": false},
    {"type": "wait_seconds", "seconds": 0.5},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "velocity:x",
     "expected": 0.0, "operator": "approx", "tolerance": 1.0},
    {"type": "dump_tree", "node_path": "/root", "properties": ["position"], "max_depth": 4, "label": "settled"}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project res://scenes/room.tscn --quit-after 120 --timeout 60 --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_topdown.json --pretty
```

Expected: all four report `"ok": true`, with `counts.errors == 0` and
`counts.warnings == 0` from `validate_project.py`.

---

## 4. Enemy With Patrol, Hitbox, Hurtbox And Health

**Goal.** An enemy that walks a platform and turns at edges, takes damage from
the player's attack, dies at zero health, and a pooled bullet that carries the
hitbox.

**Requires.** §1, §2 — the enemy and the pool go into Playbook 2's `level_1.tscn`.

### Step 1 — Copy the templates

```bash
cp /absolute/path/to/godot/templates/gdscript/health.gd \
   /absolute/path/to/godot/templates/gdscript/hitbox.gd \
   /absolute/path/to/godot/templates/gdscript/hurtbox.gd \
   /absolute/path/to/godot/templates/gdscript/enemy_patrol_2d.gd \
   /absolute/path/to/godot/templates/gdscript/object_pool.gd \
   /absolute/path/to/godot/templates/gdscript/state.gd \
   /absolute/path/to/godot/templates/gdscript/state_machine.gd \
   /absolute/path/to/project/scripts/
```

### Step 2 — Rebuild the class-name cache

```bash
godot --headless --path /absolute/path/to/project --import
```

Run this now, not later. `health.gd`, `hitbox.gd`, `hurtbox.gd`,
`object_pool.gd`, `state.gd` and `state_machine.gd` all declare a `class_name`,
and a `--script` dispatcher run never rebuilds
`.godot/global_script_class_cache.cfg`. Skip it and the next step fails with
`Parse Error: Identifier "Health" not declared in the current scope`.

### Step 3 — Build the enemy scene

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/enemy.tscn",
    "create_if_missing": true,
    "root_node_type": "CharacterBody2D",
    "root_node_name": "Enemy",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":4,"collision_mask":1},"groups_add":["enemy"]},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CapsuleShape2D","properties":{"radius":6.0,"height":18.0}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Sprite2D","node_name":"Sprite2D"},

      {"type":"add_node","parent_node_path":"root","node_type":"RayCast2D","node_name":"EdgeCheck",
       "properties":{"enabled":true,"position":{"__type":"Vector2","x":10,"y":0},"target_position":{"__type":"Vector2","x":0,"y":20},"collision_mask":1}},
      {"type":"add_node","parent_node_path":"root","node_type":"RayCast2D","node_name":"WallCheck",
       "properties":{"enabled":true,"target_position":{"__type":"Vector2","x":14,"y":0},"collision_mask":1}},

      {"type":"add_node","parent_node_path":"root","node_type":"Node","node_name":"Health"},
      {"type":"attach_script","node_path":"root/Health","script_path":"scripts/health.gd",
       "script_properties":{"max_health":3,"invulnerability_time":0.3}},

      {"type":"add_node","parent_node_path":"root","node_type":"Area2D","node_name":"Hurtbox",
       "properties":{"collision_layer":8,"collision_mask":8}},
      {"type":"add_node","parent_node_path":"root/Hurtbox","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CapsuleShape2D","properties":{"radius":7.0,"height":20.0}}}},
      {"type":"attach_script","node_path":"root/Hurtbox","script_path":"scripts/hurtbox.gd",
       "script_properties":{"team":"enemy","health_path":{"__type":"NodePath","value":"../Health"}}},

      {"type":"attach_script","node_path":"root","script_path":"scripts/enemy_patrol_2d.gd",
       "script_properties":{"speed":60.0,"ping_pong":true}}
    ]
  }'
```

`health_path` is a `NodePath`, so it is written with the typed value
`{"__type":"NodePath","value":"../Health"}`. Do not try to hand the hurtbox the
Health *node* — a headless batch has no live tree to resolve a node reference
against, and the dispatcher rejects it with
`expected Health but got NodePath`.

### Step 4 — The bullet that carries the hitbox

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/bullet.tscn",
    "create_if_missing": true,
    "root_node_type": "Area2D",
    "root_node_name": "Bullet",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":8,"collision_mask":8}},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CircleShape2D","properties":{"radius":3.0}}}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/hitbox.gd",
       "script_properties":{"damage":1,"team":"player","one_shot":true}}
    ]
  }'
```

### Step 5 — Pool the bullets in the level

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level_1.tscn",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"Node","node_name":"BulletPool"},
      {"type":"configure_node","node_path":"root/BulletPool","unique_name_in_owner":true},
      {"type":"attach_script","node_path":"root/BulletPool","script_path":"scripts/object_pool.gd",
       "script_properties":{"scene":{"__resource":"res://scenes/bullet.tscn"},"initial_size":24,"grow":true}},
      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/enemy.tscn","node_name":"Enemy",
       "properties":{"position":{"__type":"Vector2","x":220,"y":150}}}
    ]
  }'
```

### Step 6 (optional) — Give the enemy states

The machine keys states by **node name**, so `request_transition(&"Chase")`
needs a child literally named `Chase` whose script `extends State`. A
`StateMachine` whose children have no `State` script pushes
`has no State children` on the first frame — write the state scripts first.

```bash
mkdir -p /absolute/path/to/project/scripts/states
cat > /absolute/path/to/project/scripts/states/patrol_state.gd <<'GDSCRIPT'
extends State

@export var chase_range: float = 120.0

func physics_update(_delta: float) -> void:
	var body := agent as Node2D
	if body == null:
		return
	var players: Array[Node] = get_tree().get_nodes_in_group(&"player")
	if players.is_empty():
		return
	var player := players[0] as Node2D
	if player != null and body.global_position.distance_to(player.global_position) < chase_range:
		request_transition(&"Chase")
GDSCRIPT
cat > /absolute/path/to/project/scripts/states/chase_state.gd <<'GDSCRIPT'
extends State

@export var give_up_range: float = 200.0

func physics_update(_delta: float) -> void:
	var body := agent as Node2D
	if body == null:
		return
	var players: Array[Node] = get_tree().get_nodes_in_group(&"player")
	if players.is_empty():
		request_transition(&"Patrol")
		return
	var player := players[0] as Node2D
	if player == null or body.global_position.distance_to(player.global_position) > give_up_range:
		request_transition(&"Patrol")
GDSCRIPT
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/enemy.tscn",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"Node","node_name":"StateMachine"},
      {"type":"add_node","parent_node_path":"root/StateMachine","node_type":"Node","node_name":"Patrol"},
      {"type":"add_node","parent_node_path":"root/StateMachine","node_type":"Node","node_name":"Chase"},
      {"type":"attach_script","node_path":"root/StateMachine/Patrol","script_path":"scripts/states/patrol_state.gd"},
      {"type":"attach_script","node_path":"root/StateMachine/Chase","script_path":"scripts/states/chase_state.gd"},
      {"type":"attach_script","node_path":"root/StateMachine","script_path":"scripts/state_machine.gd"}
    ]
  }'
```

### Verify

```bash
cat > /absolute/path/to/project/scenario_enemy.json <<'JSON'
{
  "scene_path": "res://scenes/level_1.tscn",
  "viewport_size": {"width": 640, "height": 360},
  "settle_frames": 4,
  "steps": [
    {"type": "assert", "assertion": "property", "node_path": "Enemy/Health", "property": "current_health", "expected": 3},
    {"type": "log_marker", "message": "before-damage"},
    {"type": "wait_seconds", "seconds": 0.5},
    {"type": "assert", "assertion": "property", "node_path": "Enemy", "property": "velocity:x",
     "expected": 0.0, "operator": "not_equals"},
    {"type": "dump_tree", "node_path": "Enemy", "properties": ["position", "velocity"], "max_depth": 3, "label": "patrolling"}
  ],
  "assertions": [
    {"assertion": "node_exists", "node_path": "Enemy/Hurtbox"},
    {"assertion": "node_exists", "node_path": "BulletPool"}
  ]
}
JSON
```

```bash
godot --headless --path /absolute/path/to/project --import
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project --quit-after 120 --timeout 60 --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_enemy.json --pretty
```

Expected: `lint_project.py` reports zero `node_ref` and zero `unique_name`
diagnostics; `validate_project.py` `"ok": true` with `counts.errors == 0` and
`counts.warnings == 0`; the scenario `"ok": true`, and the `patrolling`
`dump_tree` shows a non-zero `velocity:x` on `Enemy`.

---

## 5. Tile Level From ASCII

**Goal.** A solid, collidable tile level painted from an ASCII map, and read
back as text to prove the cells landed where the map said.

**Requires.** §1.

### Step 1 — Draw the tile sheet, then import it

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/tiles.png",
    "width": 16, "height": 16,
    "tile_check": true,
    "read_back": false,
    "frames": [
      {"name": "grass", "shapes": [
        {"type": "rect", "color": "#3e8948"},
        {"type": "noise", "colors": ["#63c74d", "#265c42"], "seed": 7, "density": 0.3}]},
      {"name": "dirt", "shapes": [
        {"type": "rect", "color": "#8f563b"},
        {"type": "noise", "colors": ["#663931", "#d9a066"], "seed": 11, "density": 0.25}]},
      {"name": "stone", "shapes": [
        {"type": "rect", "color": "#8b9bb4"},
        {"type": "checker", "colors": ["#8b9bb4", "#5a6988"], "cell": 8}]}
    ]
  }'
python3 /absolute/path/to/godot/scripts/import/import_project.py /absolute/path/to/project --pretty
```

That writes a 48x16 atlas: three 16x16 cells whose atlas coordinates are the
frame order — grass `(0,0)`, dirt `(1,0)`, stone `(2,0)`. Already have art? Drop
your sheet at `art/tiles.png` and run only the import command.

The import is not optional. Without it `build_tileset` still succeeds — it reads
the PNG as a raw image and prints a `[WARN] … has no .import sidecar yet` line —
but the `.tres` it saves references the PNG by path, and a fresh process has no
loader for a PNG that was never imported: the next step fails with `No loader
found for resource: res://art/tiles.png`.

### Step 2 — Build the TileSet with real collision

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  build_tileset '{
    "resource_path": "tilesets/world.tres",
    "tile_size": {"x": 16, "y": 16},
    "physics_layers": [{"collision_layer": 1, "collision_mask": 1}],
    "custom_data_layers": [{"name": "kind", "type": "string"}],
    "sources": [
      {"source_id": 0, "texture": "art/tiles.png", "tiles": "all",
       "tile_defaults": {"collision": "full_cell", "custom_data": {"kind": "solid"}}}
    ]
  }'
```

Without `"collision": "full_cell"` the tiles are decorative and the player falls
straight through them. That is the single most common tilemap mistake.

### Step 3 — Add the TileMapLayer node

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/tile_level.tscn",
    "create_if_missing": true,
    "root_node_type": "Node2D",
    "root_node_name": "TileLevel",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"TileMapLayer","node_name":"Ground","index":0}
    ]
  }'
```

Use `TileMapLayer`, never the `TileMap` node — it has been deprecated since
Godot 4.3 and its editor tooling is gone.

The tiles get their own scene on purpose. Playbook 2 puts a `Ground`
**StaticBody2D** in `level_1.tscn`, and painting a `Ground` TileMapLayer into
that same scene collides with it (`Node is not a TileMapLayer`). To tile a level
that already has a floor, delete the StaticBody2D first, or give the layer a
name of its own and use that name in the two blocks below.

### Step 4 — Paint the level from ASCII

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  paint_tilemap '{
    "scene_path": "scenes/tile_level.tscn",
    "node_path": "root/Ground",
    "tile_set": "tilesets/world.tres",
    "clear": true,
    "ascii_map": {
      "origin": {"x": 0, "y": 0},
      "legend": {
        "#": {"source_id": 0, "atlas_coords": {"x": 0, "y": 0}},
        "=": {"source_id": 0, "atlas_coords": {"x": 1, "y": 0}},
        ".": null
      },
      "rows": [
        "................",
        "................",
        ".....===........",
        "................",
        "..===...........",
        "................",
        "################"
      ]
    }
  }'
```

One character per cell, every row the same length. `null` in the legend means
"leave this cell empty" — do not use a space for a solid tile, and do not pad
rows with tabs.

### Verify

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_tilemap '{"scene_path":"scenes/tile_level.tscn","node_path":"root/Ground","format":"text"}'

python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project \
  res://scenes/tile_level.tscn --quit-after 120 --timeout 60 --pretty
```

Expected, for the map above:

```
.....###........
................
..###...........
................
@@@@@@@@@@@@@@@@
```

`inspect_tilemap` reports what is **painted**, not what was typed, so read it
this way:

- `bounds` covers only painted cells — here `{"x":0,"y":2,"w":16,"h":5}`, because
  the two all-empty top rows of the input hold no cells. Add `2` to a printed
  row index to get the map row it came from.
- The glyphs are re-derived, not your legend: the returned `legend` maps each
  printed character back to `{source_id, atlas_coords}`. Compare shapes and the
  `counts` map (`{"@": 16, "#": 6}` here), not the characters.
- `cell_count` is the total painted (22 = 16 ground + 6 platform).

Also expected: `validate_project.py` `"ok": true`; `run_project.py`
`counts.errors == 0`. If the printed rows are all dots, the atlas coordinates
were never exposed — go back to `build_tileset` and check `"tiles": "all"`. If
`paint_tilemap` fails with `must resolve to a TileSet resource`, Step 1 was
skipped: an unimported texture makes the whole `.tres` fail to load.

---

## 6. Main Menu With A Theme

**Goal.** A title screen built out of containers, wearing a project-wide theme
with a visible focus state, navigable with a gamepad.

**Requires.** §1 **including its Step 5** — `main_menu.gd` names `GameManager`,
`SaveManager` and `SceneTransition`, and will not parse until all three are
registered autoloads.

### Step 1 — Author the theme

Use the complete game theme in `references/game_ui.md` ("Theme Doctrine")
verbatim, or start from this reduced version and grow it:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  build_theme '{
    "resource_path": "theme/game.tres",
    "default_font_size": 12,
    "types": {
      "Button": {
        "styleboxes": {
          "normal":   {"bg_color":"#222d42","border_width":2,"border_color":"#3a4a68","corner_radius":4,"content_margin":8},
          "hover":    {"bg_color":"#2e3c58","border_width":2,"border_color":"#5c76a3","corner_radius":4,"content_margin":8},
          "pressed":  {"bg_color":"#161d2b","border_width":2,"border_color":"#ffb02e","corner_radius":4,"content_margin":8},
          "disabled": {"bg_color":"#161b26","border_width":2,"border_color":"#262f40","corner_radius":4,"content_margin":8},
          "focus":    {"draw_center":false,"border_width":2,"border_color":"#ffd479","corner_radius":4,"expand_margin":3}
        },
        "colors": {"font_color":"#e9eff8","font_hover_color":"#ffffff","font_pressed_color":"#ffb02e","font_disabled_color":"#5b6478"},
        "font_sizes": {"font_size":14}
      },
      "Label": {"colors": {"font_color":"#e9eff8"}, "font_sizes": {"font_size":14}},
      "PanelContainer": {
        "styleboxes": {"panel": {"bg_color":"#182031ee","border_width":2,"border_color":"#3a4a68","corner_radius":6,"content_margin":14}}
      }
    },
    "variations": {
      "TitleLabel":   {"base":"Label","colors":{"font_color":"#ffb02e"},"font_sizes":{"font_size":32}},
      "CaptionLabel": {"base":"Label","colors":{"font_color":"#8a9bb5"},"font_sizes":{"font_size":10}}
    }
  }'
```

The font sizes here are chosen for the 640x360 base viewport Playbook 1 set. A
`56px` title plus `18px` buttons overflows 360 pixels of height, and the
overflow shows up as an `offscreen` finding on the footer — size the type to the
**base viewport**, not to the window.

Never set `"focus": "empty"`. A menu whose focus state is invisible cannot be
navigated with a gamepad or keyboard, which is most players of a game menu.

### Step 2 — Wire the theme project-wide

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{"actions":[{"type":"set_setting","name":"gui/theme/custom","value":"res://theme/game.tres"}]}'
```

### Step 3 — Build the menu, containers first

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/main_menu.tscn",
    "create_if_missing": true,
    "root_node_type": "Control",
    "root_node_name": "MainMenu",
    "actions": [
      {"type":"configure_control","node_path":"root","layout_preset":"FULL_RECT"},
      {"type":"add_node","parent_node_path":"root","node_type":"ColorRect","node_name":"Background",
       "properties":{"color":{"__type":"Color","r":0.05,"g":0.063,"b":0.09,"a":1},"mouse_filter":2}},
      {"type":"configure_control","node_path":"root/Background","layout_preset":"FULL_RECT"},

      {"type":"add_node","parent_node_path":"root","node_type":"MarginContainer","node_name":"Frame"},
      {"type":"configure_control","node_path":"root/Frame","layout_preset":"FULL_RECT",
       "theme_overrides":{"constants":{"margin_left":24,"margin_right":24,"margin_top":20,"margin_bottom":20}}},

      {"type":"add_node","parent_node_path":"root/Frame","node_type":"VBoxContainer","node_name":"Column"},
      {"type":"configure_control","node_path":"root/Frame/Column","theme_overrides":{"constants":{"separation":16}}},

      {"type":"add_node","parent_node_path":"root/Frame/Column","node_type":"Label","node_name":"Title",
       "properties":{"text":"EMBER HOLLOW","horizontal_alignment":1,"theme_type_variation":"TitleLabel"}},

      {"type":"add_node","parent_node_path":"root/Frame/Column","node_type":"CenterContainer","node_name":"MenuSlot"},
      {"type":"configure_control","node_path":"root/Frame/Column/MenuSlot","size_flags_vertical":"EXPAND_FILL"},
      {"type":"add_node","parent_node_path":"root/Frame/Column/MenuSlot","node_type":"VBoxContainer","node_name":"Menu"},
      {"type":"configure_control","node_path":"root/Frame/Column/MenuSlot/Menu",
       "custom_minimum_size":{"__type":"Vector2","x":240,"y":0},
       "theme_overrides":{"constants":{"separation":8}}},

      {"type":"add_node","parent_node_path":"root/Frame/Column/MenuSlot/Menu","node_type":"Button","node_name":"NewGameButton","properties":{"text":"New Game"}},
      {"type":"add_node","parent_node_path":"root/Frame/Column/MenuSlot/Menu","node_type":"Button","node_name":"ContinueButton","properties":{"text":"Continue"}},
      {"type":"add_node","parent_node_path":"root/Frame/Column/MenuSlot/Menu","node_type":"Button","node_name":"SettingsButton","properties":{"text":"Settings"}},
      {"type":"add_node","parent_node_path":"root/Frame/Column/MenuSlot/Menu","node_type":"Button","node_name":"QuitButton","properties":{"text":"Quit"}},

      {"type":"configure_node","node_path":"root/Frame/Column/MenuSlot/Menu/NewGameButton","unique_name_in_owner":true},
      {"type":"configure_node","node_path":"root/Frame/Column/MenuSlot/Menu/ContinueButton","unique_name_in_owner":true},
      {"type":"configure_node","node_path":"root/Frame/Column/MenuSlot/Menu/SettingsButton","unique_name_in_owner":true},
      {"type":"configure_node","node_path":"root/Frame/Column/MenuSlot/Menu/QuitButton","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/Frame/Column","node_type":"Label","node_name":"Footer",
       "properties":{"text":"v0.1.0","horizontal_alignment":1,"theme_type_variation":"CaptionLabel"}}
    ]
  }'
```

Set `layout_preset` only on the root and the full-rect background. Never set
`position`, `size` or `offset_*` on a child of a `Container` — the container
overwrites them on the next sort, which is exactly how every control ends up
stacked at (0, 0).

### Step 4 — Attach the controller

```bash
cp /absolute/path/to/godot/templates/gdscript/main_menu.gd \
   /absolute/path/to/project/scripts/main_menu.gd
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/main_menu.tscn",
    "actions": [
      {"type":"attach_script","node_path":"root","script_path":"scripts/main_menu.gd",
       "script_properties":{"new_game_scene":"res://scenes/level_1.tscn","save_slot":0}}
    ]
  }'
```

### Verify

```bash
cat > /absolute/path/to/project/scenario_menu.json <<'JSON'
{
  "scene_path": "res://scenes/main_menu.tscn",
  "viewport_size": {"width": 640, "height": 360},
  "settle_frames": 4,
  "steps": [
    {"type": "ui_report", "label": "menu-base", "ascii": true,
     "fail_on": ["overlap", "zero_size", "offscreen"]},
    {"type": "assert", "assertion": "property",
     "node_path": "Frame/Column/MenuSlot/Menu/NewGameButton", "property": "size:x",
     "expected": 240.0, "operator": "approx", "tolerance": 1.0},
    {"type": "key", "keycode": 4194322, "pressed": true},
    {"type": "key", "keycode": 4194322, "pressed": false},
    {"type": "wait_frames", "frames": 2},
    {"type": "dump_tree", "node_path": ".", "properties": ["visible", "disabled"], "max_depth": 6, "label": "menu-tree"}
  ],
  "assertions": [
    {"assertion": "node_exists", "node_path": "Frame/Column/MenuSlot/Menu/QuitButton"}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_menu.json --pretty
```

Expected: `validate_project.py` `"ok": true`; `run_scenario.py` `"ok": true`
with the `menu-base` report showing `findings=0`, `zero_size=0`, `offscreen=0`,
`overlap=0`, and its `ascii` art placing the title above the button column.

A second `viewport_size` is **not** a second layout here. Playbook 1 set
`display/window/stretch/mode` to `canvas_items`, so the UI always lays out
against the project's base viewport (640x360) whatever the window size is; the
scenario's `viewport_size` only resizes the window. Re-run at a second size only
in a project whose stretch mode is `disabled`.

---

## 7. HUD Bound To GameManager

**Goal.** Score, lives and a health bar that update from signals, never from a
`_process` poll.

**Requires.** §1 **including its Step 5**, §2 (a player and `level_1.tscn`), §4
(`health.gd`, which `hud.gd` annotates).

### Step 1 — Copy and register the autoload

Playbook 1 Step 5 already copied and registered `GameManager`; re-running these
two blocks is harmless (`add_autoload` overwrites the same key).

```bash
cp /absolute/path/to/godot/templates/gdscript/game_manager.gd \
   /absolute/path/to/project/scripts/game_manager.gd
cp /absolute/path/to/godot/templates/gdscript/hud.gd \
   /absolute/path/to/project/scripts/hud.gd
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"add_autoload","autoload_name":"GameManager","path":"res://scripts/game_manager.gd","singleton":true}
    ]
  }'
```

Never add `class_name GameManager` to that file. A `class_name` matching an
autoload fails with `Class "GameManager" hides an autoload singleton`.

### Step 2 — Build the HUD scene

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/hud.tscn",
    "create_if_missing": true,
    "root_node_type": "CanvasLayer",
    "root_node_name": "HUD",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"layer":1}},

      {"type":"add_node","parent_node_path":"root","node_type":"MarginContainer","node_name":"TopLeft","properties":{"mouse_filter":2}},
      {"type":"configure_control","node_path":"root/TopLeft","layout_preset":"TOP_LEFT",
       "theme_overrides":{"constants":{"margin_left":24,"margin_top":20,"margin_right":0,"margin_bottom":0}}},
      {"type":"add_node","parent_node_path":"root/TopLeft","node_type":"VBoxContainer","node_name":"Vitals","properties":{"mouse_filter":2}},
      {"type":"add_node","parent_node_path":"root/TopLeft/Vitals","node_type":"ProgressBar","node_name":"HealthBar",
       "properties":{"max_value":3,"value":3,"show_percentage":false}},
      {"type":"configure_control","node_path":"root/TopLeft/Vitals/HealthBar","custom_minimum_size":{"__type":"Vector2","x":220,"y":16}},
      {"type":"add_node","parent_node_path":"root/TopLeft/Vitals","node_type":"Label","node_name":"LivesLabel","properties":{"text":"LIVES 3"}},

      {"type":"add_node","parent_node_path":"root","node_type":"MarginContainer","node_name":"TopRight",
       "properties":{"mouse_filter":2,"grow_horizontal":0,"grow_vertical":1}},
      {"type":"configure_control","node_path":"root/TopRight","layout_preset":"TOP_RIGHT",
       "theme_overrides":{"constants":{"margin_right":24,"margin_top":20,"margin_left":0,"margin_bottom":0}}},
      {"type":"add_node","parent_node_path":"root/TopRight","node_type":"Label","node_name":"ScoreLabel","properties":{"text":"SCORE 000000"}},

      {"type":"configure_node","node_path":"root/TopLeft/Vitals/HealthBar","unique_name_in_owner":true},
      {"type":"configure_node","node_path":"root/TopLeft/Vitals/LivesLabel","unique_name_in_owner":true},
      {"type":"configure_node","node_path":"root/TopRight/ScoreLabel","unique_name_in_owner":true},

      {"type":"attach_script","node_path":"root","script_path":"scripts/hud.gd"}
    ]
  }'
```

A HUD cluster anchored to a far edge must grow inward: `grow_horizontal: 0`
(BEGIN) on the `TOP_RIGHT` cluster, or it grows off-screen to the right.

### Step 3 — Put the HUD in the level and bind the health bar

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level_1.tscn",
    "actions": [
      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/hud.tscn","node_name":"HUD"},
      {"type":"configure_node","node_path":"root/HUD","unique_name_in_owner":true}
    ]
  }'
```

Bind the bar from the level script (`%HUD.bind_health($Player/Health)`), or from
the player's own `_ready`. `hud.gd` does not search for a Health node — a HUD
that reaches into the level by path breaks the first time the level changes.

### Verify

```bash
cat > /absolute/path/to/project/scenario_hud.json <<'JSON'
{
  "scene_path": "res://scenes/level_1.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "settle_frames": 4,
  "steps": [
    {"type": "ui_report", "label": "hud", "node_path": "HUD", "ascii": true, "fail_on": ["any"]},
    {"type": "assert", "assertion": "property", "node_path": "HUD/TopRight/ScoreLabel",
     "property": "text", "expected": "SCORE 000000"},
    {"type": "log_marker", "message": "hud-initial"},
    {"type": "dump_tree", "node_path": "HUD", "properties": ["text", "value", "max_value"], "max_depth": 5, "label": "hud-values"}
  ],
  "assertions": [
    {"assertion": "node_exists", "node_path": "HUD/TopLeft/Vitals/HealthBar"}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project --quit-after 120 --timeout 60 --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_hud.json --pretty
```

Expected: `lint_project.py` zero `unique_name` diagnostics; the `hud` report
`findings=0`; the `hud-values` `dump_tree` shows `ScoreLabel.text` =
`SCORE 000000` and `HealthBar.max_value` = `3`.

---

## 8. Pause Menu

**Goal.** `Esc` pauses the game and opens an overlay whose buttons still work
while the tree is paused.

**Requires.** §1 **including its Step 5** (`pause_menu.gd` names
`SceneTransition`), §2 (the `level_1.tscn` the overlay goes into), §6 (the theme
and the `main_menu.tscn` its Quit button returns to).

### Step 1 — Copy the template

```bash
cp /absolute/path/to/godot/templates/gdscript/pause_menu.gd \
   /absolute/path/to/project/scripts/pause_menu.gd
```

### Step 2 — Build the overlay

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/pause_menu.tscn",
    "create_if_missing": true,
    "root_node_type": "CanvasLayer",
    "root_node_name": "PauseMenu",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"layer":10,"process_mode":3}},

      {"type":"add_node","parent_node_path":"root","node_type":"Control","node_name":"PauseRoot"},
      {"type":"configure_control","node_path":"root/PauseRoot","layout_preset":"FULL_RECT"},
      {"type":"configure_node","node_path":"root/PauseRoot","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/PauseRoot","node_type":"ColorRect","node_name":"Dim",
       "properties":{"color":{"__type":"Color","r":0,"g":0,"b":0,"a":0.66},"mouse_filter":2}},
      {"type":"configure_control","node_path":"root/PauseRoot/Dim","layout_preset":"FULL_RECT"},

      {"type":"add_node","parent_node_path":"root/PauseRoot","node_type":"CenterContainer","node_name":"Center"},
      {"type":"configure_control","node_path":"root/PauseRoot/Center","layout_preset":"FULL_RECT"},
      {"type":"add_node","parent_node_path":"root/PauseRoot/Center","node_type":"PanelContainer","node_name":"Dialog"},
      {"type":"configure_control","node_path":"root/PauseRoot/Center/Dialog","custom_minimum_size":{"__type":"Vector2","x":420,"y":0}},
      {"type":"add_node","parent_node_path":"root/PauseRoot/Center/Dialog","node_type":"VBoxContainer","node_name":"Body"},
      {"type":"configure_control","node_path":"root/PauseRoot/Center/Dialog/Body","theme_overrides":{"constants":{"separation":18}}},

      {"type":"add_node","parent_node_path":"root/PauseRoot/Center/Dialog/Body","node_type":"Label","node_name":"Heading",
       "properties":{"text":"PAUSED","horizontal_alignment":1}},
      {"type":"add_node","parent_node_path":"root/PauseRoot/Center/Dialog/Body","node_type":"Button","node_name":"ResumeButton","properties":{"text":"Resume"}},
      {"type":"add_node","parent_node_path":"root/PauseRoot/Center/Dialog/Body","node_type":"Button","node_name":"QuitButton","properties":{"text":"Quit To Title"}},
      {"type":"configure_node","node_path":"root/PauseRoot/Center/Dialog/Body/ResumeButton","unique_name_in_owner":true},
      {"type":"configure_node","node_path":"root/PauseRoot/Center/Dialog/Body/QuitButton","unique_name_in_owner":true},

      {"type":"attach_script","node_path":"root","script_path":"scripts/pause_menu.gd",
       "script_properties":{"title_scene":"res://scenes/main_menu.tscn"}}
    ]
  }'
```

`process_mode: 3` is `PROCESS_MODE_ALWAYS`. Set it on the `CanvasLayer` root, in
the scene, as well as in the script — a pause menu that inherits the default
process mode freezes with the rest of the tree the instant it pauses it.

### Step 3 — Add it to the level

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level_1.tscn",
    "actions": [
      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/pause_menu.tscn","node_name":"PauseMenu"}
    ]
  }'
```

### Verify

```bash
cat > /absolute/path/to/project/scenario_pause.json <<'JSON'
{
  "scene_path": "res://scenes/level_1.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "settle_frames": 4,
  "steps": [
    {"type": "assert", "assertion": "property", "node_path": "PauseMenu/PauseRoot", "property": "visible", "expected": false},
    {"type": "key", "keycode": 4194305, "pressed": true},
    {"type": "key", "keycode": 4194305, "pressed": false},
    {"type": "wait_until", "node_path": "PauseMenu/PauseRoot", "property": "visible", "expected": true, "timeout_seconds": 2},
    {"type": "ui_report", "label": "paused", "node_path": "PauseMenu", "ascii": true, "fail_on": ["any"]},
    {"type": "key", "keycode": 4194305, "pressed": true},
    {"type": "key", "keycode": 4194305, "pressed": false},
    {"type": "wait_until", "node_path": "PauseMenu/PauseRoot", "property": "visible", "expected": false, "timeout_seconds": 2},
    {"type": "log_marker", "message": "unpaused"}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_pause.json --log-file /absolute/path/to/project/pause.log --pretty
```

Expected: `run_scenario.py` `"ok": true`; both `wait_until` steps resolve inside
the timeout (that is the proof the menu still responds while paused); the
`paused` report `findings=0`.

`ui_cancel` is driven with `key` steps, not an `action` step. See
[Driving input in a scenario](#driving-input-in-a-scenario) — an `action` step
would leave `_unhandled_input` untouched and the menu would never open.

---

## 9. Dialog Box

**Goal.** An NPC the player walks up to and talks to, with typewriter text
advanced by `ui_accept`.

**Requires.** §1 (the `interact` action), §2 (a player in the group `player`,
and `level_1.tscn`), §6 (a theme, so the box is not grey on grey).

### Step 1 — Copy the templates

```bash
cp /absolute/path/to/godot/templates/gdscript/dialog_box.gd \
   /absolute/path/to/godot/templates/gdscript/interactable.gd \
   /absolute/path/to/project/scripts/
godot --headless --path /absolute/path/to/project --import
```

### Step 2 — Build the dialog box

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/dialog_box.tscn",
    "create_if_missing": true,
    "root_node_type": "CanvasLayer",
    "root_node_name": "DialogBox",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"layer":5}},

      {"type":"add_node","parent_node_path":"root","node_type":"Control","node_name":"DialogRoot"},
      {"type":"configure_control","node_path":"root/DialogRoot","layout_preset":"FULL_RECT"},
      {"type":"configure_node","node_path":"root/DialogRoot","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/DialogRoot","node_type":"MarginContainer","node_name":"Anchor",
       "properties":{"grow_vertical":0,"mouse_filter":2}},
      {"type":"configure_control","node_path":"root/DialogRoot/Anchor","layout_preset":"BOTTOM_WIDE",
       "theme_overrides":{"constants":{"margin_left":40,"margin_right":40,"margin_top":0,"margin_bottom":32}}},

      {"type":"add_node","parent_node_path":"root/DialogRoot/Anchor","node_type":"PanelContainer","node_name":"Box"},
      {"type":"add_node","parent_node_path":"root/DialogRoot/Anchor/Box","node_type":"VBoxContainer","node_name":"Body"},
      {"type":"configure_control","node_path":"root/DialogRoot/Anchor/Box/Body","theme_overrides":{"constants":{"separation":10}}},

      {"type":"add_node","parent_node_path":"root/DialogRoot/Anchor/Box/Body","node_type":"Label","node_name":"SpeakerLabel",
       "properties":{"text":"NPC"}},
      {"type":"add_node","parent_node_path":"root/DialogRoot/Anchor/Box/Body","node_type":"RichTextLabel","node_name":"BodyLabel",
       "properties":{"bbcode_enabled":true,"fit_content":true,"scroll_active":false,"autowrap_mode":3,"text":"..."}},
      {"type":"configure_control","node_path":"root/DialogRoot/Anchor/Box/Body/BodyLabel",
       "custom_minimum_size":{"__type":"Vector2","x":0,"y":96},"size_flags_horizontal":"EXPAND_FILL"},

      {"type":"configure_node","node_path":"root/DialogRoot/Anchor/Box/Body/SpeakerLabel","unique_name_in_owner":true},
      {"type":"configure_node","node_path":"root/DialogRoot/Anchor/Box/Body/BodyLabel","unique_name_in_owner":true},

      {"type":"attach_script","node_path":"root","script_path":"scripts/dialog_box.gd",
       "script_properties":{"characters_per_second":40.0}}
    ]
  }'
```

Reserve the text height with `custom_minimum_size.y`, not by measuring the
English string. A translated line 40% longer must not resize the panel between
lines.

### Step 3 — Build the NPC that opens it

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/npc.tscn",
    "create_if_missing": true,
    "root_node_type": "Area2D",
    "root_node_name": "Npc",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":1,"collision_mask":2,"monitoring":true}},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CircleShape2D","properties":{"radius":48.0}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Sprite2D","node_name":"Sprite2D"},
      {"type":"add_node","parent_node_path":"root","node_type":"Label","node_name":"Prompt",
       "properties":{"text":"Talk","position":{"__type":"Vector2","x":-16,"y":-40}}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/interactable.gd",
       "script_properties":{"prompt_text":"Talk","one_shot":false}}
    ]
  }'
```

The player body must be in the group `player` (`groups_add: ["player"]` in
Playbook 2 / 3) — `interactable.gd` ignores every other body on purpose.

### Step 4 — Write the level script that answers the signal

`connect_signal` verifies that the target node really has the method and aborts
the batch otherwise (`Target node does not have method: _on_npc_interacted`), so
the script has to exist and be attached **before** the connection is made.

```bash
cat > /absolute/path/to/project/scripts/level_1.gd <<'GDSCRIPT'
extends Node2D

@onready var _dialog: Node = %DialogBox

var _lines: Array[String] = ["Hello.", "Mind the lanterns."]

func _on_npc_interacted(_by: Node2D) -> void:
	_dialog.call(&"show_lines", _lines, "Marrow")
GDSCRIPT
```

`_lines` is annotated `Array[String]` because `show_lines` takes one; passing a
bare `[...]` literal raises a runtime type error at the call.

### Step 5 — Instantiate both scenes and connect the NPC

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level_1.tscn",
    "actions": [
      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/dialog_box.tscn","node_name":"DialogBox"},
      {"type":"configure_node","node_path":"root/DialogBox","unique_name_in_owner":true},
      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/npc.tscn","node_name":"Npc",
       "properties":{"position":{"__type":"Vector2","x":0,"y":170}}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/level_1.gd"},
      {"type":"connect_signal","node_path":"root/Npc","signal_name":"interacted",
       "target_node_path":"root","method_name":"_on_npc_interacted"}
    ]
  }'
```

### Verify

```bash
cat > /absolute/path/to/project/scenario_dialog.json <<'JSON'
{
  "scene_path": "res://scenes/level_1.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "settle_frames": 4,
  "steps": [
    {"type": "assert", "assertion": "property", "node_path": "DialogBox/DialogRoot", "property": "visible", "expected": false},
    {"type": "wait_seconds", "seconds": 1.0},
    {"type": "key", "physical_keycode": 69, "pressed": true},
    {"type": "key", "physical_keycode": 69, "pressed": false},
    {"type": "wait_until", "node_path": "DialogBox/DialogRoot", "property": "visible", "expected": true, "timeout_seconds": 2},
    {"type": "ui_report", "label": "dialog-open", "node_path": "DialogBox", "ascii": true, "fail_on": ["any"]},
    {"type": "wait_seconds", "seconds": 1.0},
    {"type": "dump_tree", "node_path": "DialogBox", "properties": ["text", "visible_characters", "visible"], "max_depth": 6, "label": "typed"},
    {"type": "key", "keycode": 4194309, "pressed": true},
    {"type": "key", "keycode": 4194309, "pressed": false},
    {"type": "wait_frames", "frames": 4}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_dialog.json --pretty
```

Expected: `run_scenario.py` `"ok": true`; the `dialog-open` report
`findings=0`; the `typed` `dump_tree` shows `BodyLabel.text` holding the first
line and `visible_characters` greater than 0.

The `wait_seconds 1.0` before the first key press is not padding: the player has
to fall and settle inside the NPC's Area2D before `interact` can do anything,
and gravity is physics time — `wait_frames` would race it. `interact` was created with
`physical_keycode`, so the `key` step uses `physical_keycode`; `ui_accept` is a
built-in bound by `keycode`, so it uses `keycode`.

---

## 10. Save And Load

**Goal.** Progress that survives quitting the game, stored as versioned JSON
that cannot crash the next launch when it is missing or corrupt.

**Requires.** §1 **including its Step 5**, §2, §4 and §7 — the save probe below
reads `GameManager` and rides along in Playbook 7's `level_1.tscn`.

### Step 1 — Copy and register the autoload

```bash
cp /absolute/path/to/godot/templates/gdscript/save_manager.gd \
   /absolute/path/to/project/scripts/save_manager.gd
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"add_autoload","autoload_name":"SaveManager","path":"res://scripts/save_manager.gd","singleton":true}
    ]
  }'
```

### Step 2 — Save and load from game code

```bash
cat > /absolute/path/to/project/scripts/save_probe.gd <<'GDSCRIPT'
extends Node


func save_progress() -> void:
	var payload: Dictionary = GameManager.to_save_data()
	# current_scene is null whenever something other than the engine loaded the
	# scene — the scenario runner, a unit test, mid scene change. Reading
	# .scene_file_path off that null aborts the function and writes nothing.
	var current: Node = get_tree().current_scene
	if current != null:
		payload["scene_path"] = current.scene_file_path
	if SaveManager.save_game(payload, 0):
		print("[SAVE] save ok slot=0")


func load_progress() -> void:
	if not SaveManager.has_save(0):
		print("[SAVE] no save")
		return
	var data: Dictionary = SaveManager.load_game(0)
	if data.is_empty():
		print("[SAVE] slot unreadable, starting fresh")
		return
	GameManager.from_save_data(data)
	print("[SAVE] load ok score=%d" % GameManager.score)


func _ready() -> void:
	load_progress()
	GameManager.add_score(120)
	save_progress()
	load_progress()
GDSCRIPT
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level_1.tscn",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"Node","node_name":"SaveProbe"},
      {"type":"attach_script","node_path":"root/SaveProbe","script_path":"scripts/save_probe.gd"}
    ]
  }'
```

In a real game the two functions hang off whatever owns the moment — a
checkpoint, a pause-menu button, the level script. They are driven from `_ready`
here so that one headless boot walks the whole round trip and leaves the proof
in the log.

`load_game` returns an **empty Dictionary** for every failure — missing file,
truncated file, garbage. That is why `load_progress` checks `is_empty()` before
touching `GameManager`: without it a corrupt slot silently "loads" as a fresh
game and the player's progress is gone with no message.

Never write `var data := SaveManager.load_game(0)` when the value comes back
from `JSON.parse_string` inside — always annotate. `references/gdscript_conventions.md`
explains why `:=` from a `Variant` is a boot-blocking parse error, not a nag.

### Step 3 — Break the save on purpose

A save path that has never been corrupted has never been tested. Fill the slot
with garbage:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"code":"DirAccess.make_dir_recursive_absolute(\"user://saves\")\nvar file: FileAccess = FileAccess.open(\"user://saves/slot_0.json\", FileAccess.WRITE)\nfile.store_string(\"not json at all\")\nfile.close()\nreturn ProjectSettings.globalize_path(\"user://saves/slot_0.json\")"}'
```

`run_gdscript` writes through `user://`, so this hits the same file the game
reads on every platform, and the returned `result` is the real location
(`~/Library/Application Support/Godot/app_userdata/<config/name>/saves/slot_0.json`
on macOS, `~/.local/share/godot/app_userdata/<config/name>/` on Linux). Do not
hand-build that path — the project name and the platform both change it.

```bash
cat > /absolute/path/to/project/scenario_save.json <<'JSON'
{
  "scene_path": "res://scenes/level_1.tscn",
  "viewport_size": {"width": 640, "height": 360},
  "settle_frames": 4,
  "steps": [
    {"type": "wait_frames", "frames": 4},
    {"type": "assert", "assertion": "property", "node_path": "/root/GameManager", "property": "score",
     "expected": 120, "operator": "greater_or_equal"},
    {"type": "log_marker", "message": "survived-the-corrupt-slot"}
  ],
  "log_assertions": [
    {"regex": "is not a JSON object", "min_count": 1},
    {"contains": "[SAVE] slot unreadable, starting fresh", "min_count": 1},
    {"contains": "[SAVE] save ok slot=0", "min_count": 1},
    {"contains": "[SAVE] load ok score=120", "min_count": 1}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_save.json --pretty
```

Expected: `"ok": true` with all four `log_assertions` matched. That is the whole
point of the step — the boot reported the bad slot, refused to load it, started
fresh, saved over it, and the *next* load came back with the score. A save that
fails must never take the launch with it.

### Verify

The slot is valid again (the run above saved over it), so this is the clean-path
run and it must be error-free:

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project \
  --quit-after 180 --timeout 60 --log-file /absolute/path/to/project/save.log --pretty
python3 /absolute/path/to/godot/scripts/debug/godot_log_parser.py /absolute/path/to/project/save.log --pretty
grep '\[SAVE\]' /absolute/path/to/project/save.log
```

Expected: `validate_project.py` `"ok": true` with `counts.warnings == 0`;
`run_project.py` `"ok": true` and `counts.errors == 0`; the parser reports zero
diagnostics; `grep` prints

```
[SAVE] load ok score=120
[SAVE] save ok slot=0
[SAVE] load ok score=240
```

The score climbing by 120 between one run and the next *is* the persistence —
boot it again and it reads 240, then 360. A second `no save` line instead means
the write never happened; read the `SaveManager:` error above it.

---

## 11. Scene Transitions And Audio Manager

**Goal.** Scene changes that fade instead of cutting, music that crossfades, and
SFX that never cut each other off — all reachable from any scene.

**Requires.** §1.

### Step 1 — Create the audio buses first

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  setup_audio_buses '{
    "buses": [
      {"name": "Master", "volume_db": 0.0},
      {"name": "Music", "send": "Master", "volume_db": -6.0},
      {"name": "SFX", "send": "Master", "volume_db": -3.0},
      {"name": "UI", "send": "SFX", "volume_db": -4.0}
    ],
    "save_path": "audio/default_bus_layout.tres",
    "set_project_setting": true
  }'
```

Do this **before** registering `AudioManager`. Assigning a player to a bus that
does not exist silently routes it to Master; the template warns about it, and
the warning is what a clean validation run must not contain.

### Step 2 — Copy and register both autoloads

```bash
cp /absolute/path/to/godot/templates/gdscript/scene_transition.gd \
   /absolute/path/to/godot/templates/gdscript/audio_manager.gd \
   /absolute/path/to/project/scripts/
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"add_autoload","autoload_name":"SceneTransition","path":"res://scripts/scene_transition.gd","singleton":true},
      {"type":"add_autoload","autoload_name":"AudioManager","path":"res://scripts/audio_manager.gd","singleton":true}
    ]
  }'
```

### Step 3 — Call them

```gdscript
func _on_start_pressed() -> void:
	AudioManager.play_sfx(preload("res://audio/ui_confirm.wav"))
	await SceneTransition.change_scene("res://scenes/level_1.tscn")
```

`change_scene` is a coroutine — call it with `await`, from a function that is
allowed to await. Calling `get_tree().change_scene_to_file()` directly instead
skips the fade and leaves the overlay half-drawn.

That `preload` needs the file to exist *at parse time* — `ui_confirm.wav` is one
of the sounds [Playbook 13](#13-sound-and-music-from-nothing) synthesizes. Until
it does, drop the `play_sfx` line, or the script will not compile.

### Verify

```bash
cat > /absolute/path/to/project/scenario_audio.json <<'JSON'
{
  "scene_path": "res://scenes/main.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "settle_frames": 4,
  "steps": [
    {"type": "assert", "assertion": "node_exists", "node_path": "/root/SceneTransition"},
    {"type": "assert", "assertion": "node_exists", "node_path": "/root/AudioManager"},
    {"type": "dump_tree", "node_path": "/root/AudioManager", "properties": ["bus", "volume_db"], "max_depth": 2, "label": "audio-pool"},
    {"type": "log_marker", "message": "autoloads-ok"}
  ],
  "log_assertions": [
    {"regex": "no .SFX. audio bus", "min_count": 0, "max_count": 0}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project --quit-after 120 --timeout 60 --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_audio.json --pretty
```

Expected: `validate_project.py` `"ok": true`, `counts.errors == 0`,
`counts.warnings == 0` (a `no 'SFX' audio bus` warning here means Step 1 was
skipped or its `set_project_setting` did not stick); the `audio-pool`
`dump_tree` lists ten `AudioStreamPlayer` children — eight `Sfx*` on the `SFX`
bus plus `MusicA`/`MusicB` on `Music`.

---

## 12. 3D FPS Starter

**Goal.** A first-person player standing on a floor with baked collision, mouse
look captured on start and released with Esc.

**Requires.** §1 for the shared move actions; this playbook adds
`move_forward`, `move_back` and `sprint`.

### Step 1 — Input actions and 3D gravity

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"add_input_action","action_name":"move_forward","replace":true},
      {"type":"add_input_event","action_name":"move_forward","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":87}}},
      {"type":"add_input_action","action_name":"move_back","replace":true},
      {"type":"add_input_event","action_name":"move_back","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":83}}},
      {"type":"add_input_action","action_name":"sprint","replace":true},
      {"type":"add_input_event","action_name":"sprint","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":4194325}}},
      {"type":"set_setting","name":"physics/3d/default_gravity","value":9.8}
    ]
  }'
```

### Step 2 — Copy the template

```bash
cp /absolute/path/to/godot/templates/gdscript/player_fps_3d.gd \
   /absolute/path/to/project/scripts/player_fps_3d.gd
```

### Step 3 — Build the player

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/player_3d.tscn",
    "create_if_missing": true,
    "root_node_type": "CharacterBody3D",
    "root_node_name": "Player",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":2,"collision_mask":1},"groups_add":["player"]},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape3D","node_name":"CollisionShape3D",
       "properties":{"position":{"__type":"Vector3","x":0,"y":0.9,"z":0},
        "shape":{"__resource_type":"CapsuleShape3D","properties":{"radius":0.4,"height":1.8}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Node3D","node_name":"CameraPivot",
       "properties":{"position":{"__type":"Vector3","x":0,"y":1.6,"z":0}}},
      {"type":"add_node","parent_node_path":"root/CameraPivot","node_type":"Camera3D","node_name":"Camera3D"},
      {"type":"attach_script","node_path":"root","script_path":"scripts/player_fps_3d.gd",
       "script_properties":{"speed":5.0,"sprint_speed":8.0,"jump_velocity":4.5,"mouse_sensitivity":0.0025}}
    ]
  }'
```

The pivot is what carries the pitch. Rotating the `CharacterBody3D` itself on X
tips the collision capsule over and the player falls through the floor.

### Step 4 — Floor with baked collision

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level_3d.tscn",
    "create_if_missing": true,
    "root_node_type": "Node3D",
    "root_node_name": "Level3D",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"MeshInstance3D","node_name":"Floor",
       "properties":{"mesh":{"__resource_type":"BoxMesh","properties":{"size":{"__type":"Vector3","x":40,"y":1,"z":40}}},
        "position":{"__type":"Vector3","x":0,"y":-0.5,"z":0}}},
      {"type":"add_node","parent_node_path":"root","node_type":"DirectionalLight3D","node_name":"Sun",
       "properties":{"rotation":{"__type":"Vector3","x":-0.9,"y":-0.6,"z":0},"shadow_enabled":true}},
      {"type":"add_node","parent_node_path":"root","node_type":"WorldEnvironment","node_name":"WorldEnvironment",
       "properties":{"environment":{"__resource_type":"Environment","properties":{"background_mode":1,"ambient_light_source":2,"ambient_light_energy":0.4}}}},
      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/player_3d.tscn","node_name":"Player",
       "properties":{"position":{"__type":"Vector3","x":0,"y":2,"z":0}}}
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  bake_collision '{"scene_path":"scenes/level_3d.tscn","node_path":"root/Floor","mode":"trimesh"}'
```

A `MeshInstance3D` has no collider of its own. Skip `bake_collision` and the
player falls forever — that, not a broken controller, is the usual cause of
"my 3D player drops through the ground".

For imported art, drop the `.glb` into the project, run
`import_project.py`, `instantiate_scene` it, then run `bake_collision` on its
`MeshInstance3D` exactly the same way.

### Verify

```bash
cat > /absolute/path/to/project/scenario_fps.json <<'JSON'
{
  "scene_path": "res://scenes/level_3d.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "settle_frames": 4,
  "steps": [
    {"type": "wait_seconds", "seconds": 2.0},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "position:y",
     "expected": -0.1, "operator": "greater_than"},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "velocity:y",
     "expected": 0.0, "operator": "approx", "tolerance": 0.5},
    {"type": "action", "action_name": "move_forward", "pressed": true},
    {"type": "wait_seconds", "seconds": 0.6},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "position:z",
     "expected": -0.5, "operator": "less_than"},
    {"type": "action", "action_name": "move_forward", "pressed": false},
    {"type": "dump_tree", "node_path": "/root", "properties": ["position", "velocity"], "max_depth": 4, "label": "fps-settled"}
  ],
  "assertions": [
    {"assertion": "node_exists", "node_path": "Player/CameraPivot/Camera3D"},
    {"assertion": "node_exists", "node_path": "Floor/Floor_col"}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project res://scenes/level_3d.tscn --quit-after 180 --timeout 60 --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_fps.json --pretty
```

Expected: `validate_project.py` `"ok": true` with `counts.errors == 0` and
`counts.warnings == 0`; `run_scenario.py` `"ok": true`, which means the player
came to rest on the floor (`velocity:y ≈ 0` and `position:y` still above
`-0.1`, i.e. the capsule is standing on the box rather than sinking through it)
and the baked body exists.

`bake_collision` names the body after Godot's own helper: a `MeshInstance3D`
called `Floor` gets a `StaticBody3D` child called `Floor_col`, not
`StaticBody3D`. Read the real name out of `inspect_scene` before asserting on
it.

---

<!-- WP10A-BEGIN: playbooks 13-17 -->
## 13. Sound And Music From Nothing

**Goal.** A game that makes noise: five effects, a looping music bed, mixing
buses, and `AudioManager` playing them — with every file proved by a gate
instead of by an ear.

**Requires.** §1. Nothing else: the synthesizers are stdlib Python and need no
sample library, no network and no audio device.

### Step 1 — Synthesize the effects

```bash
mkdir -p /absolute/path/to/project/audio
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset jump --seed 7 --out /absolute/path/to/project/audio/
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset coin --seed 7 --out /absolute/path/to/project/audio/
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset hit --seed 7 --variations 3 --out /absolute/path/to/project/audio/
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset confirm --seed 7 --out /absolute/path/to/project/audio/ui_confirm.wav
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset cancel --seed 7 --out /absolute/path/to/project/audio/ui_cancel.wav
```

Each run prints one JSON report whose `files[0].expect` block is the gate for
that file — keep it, Step 3 uses it. `--variations 3` writes `hit_1.wav` …
`hit_3.wav`: three siblings of the same sound, which is what stops a repeated
impact sounding like a machine gun. `--seed` makes every render byte-identical,
so a re-run is a no-op rather than a diff. `--list-presets` prints all twenty
presets with their full parameter sets; `references/audio.md` maps game events
to presets.

### Step 2 — Synthesize the music loop

```bash
python3 /absolute/path/to/godot/scripts/assets/make_music.py --preset overworld --bars 4 --out /absolute/path/to/project/audio/
```

The report says `"loop_safe": true` and `"loop_seam_delta": 0.0`: the release
tails are written back into the start of the buffer, so the last sample flows
into the first and the loop has no click. Save a preset with
`--list-presets`, edit the note rows, and re-render to make it your own.

### Step 3 — Gate every file *before* wiring it up

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_audio '{"audio_paths":["audio"],"format":"text","envelope_columns":32,
    "expect":{"not_silent":true,"no_clipping":true,"max_duration":16.0,"max_leading_silence_ms":25}}'
```

Exit 0 means every file in `audio/` is audible, unclipped, and starts
immediately. A silent WAV is a perfectly valid file — `not_silent` is the check
that catches the most common failure, and no other tool in the loop can. The
`envelope:` line is the sound as one row of ASCII: `@@@%%%###***++==--::.` is a
decay, `+**###%%%@@@%%%###**+` a whoosh.

### Step 4 — Import, then make the music actually loop

```bash
godot --headless --path /absolute/path/to/project --import
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  set_import_options '{"file_path":"audio/overworld.wav","options":{"edit/loop_mode":2}}'
godot --headless --path /absolute/path/to/project --import
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_audio '{"audio_path":"audio/overworld.wav","envelope":false,"format":"text","expect":{"loopable":true,"min_duration":7.0}}'
```

`edit/loop_mode: 2` is **Forward**, not Ping-Pong: the WAV importer's enum is
offset by one from `AudioStreamWAV.LoopMode` (the table is in
`references/audio.md`). The read-back line to look for is
`import_loop: {"edit/loop_mode":2,…,"loop_mode_name":"forward"}` — a file with
no `.import` sidecar reports `import_loop: none` and will not loop in game no
matter what the WAV contains.

### Step 5 — Buses, before the autoload

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  setup_audio_buses '{
    "buses": [
      {"name": "Master", "volume_db": 0.0},
      {"name": "Music", "send": "Master", "volume_db": -6.0},
      {"name": "SFX", "send": "Master", "volume_db": -3.0},
      {"name": "UI", "send": "SFX", "volume_db": -4.0}
    ],
    "save_path": "audio/default_bus_layout.tres",
    "set_project_setting": true
  }'
```

### Step 6 — Register AudioManager and play something

```bash
cp /absolute/path/to/godot/templates/gdscript/audio_manager.gd \
   /absolute/path/to/project/scripts/
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"add_autoload","autoload_name":"AudioManager","path":"res://scripts/audio_manager.gd","singleton":true}
    ]
  }'
```

```bash
cat > /absolute/path/to/project/scripts/jukebox.gd <<'GDSCRIPT'
extends Node2D

const MUSIC: AudioStream = preload("res://audio/overworld.wav")
const JUMP: AudioStream = preload("res://audio/jump.wav")
const COIN: AudioStream = preload("res://audio/coin.wav")

var _frames: int = 0


func _ready() -> void:
	AudioManager.play_music(MUSIC, 0.5)
	AudioManager.play_sfx(COIN)
	print("[AUDIO] music=%s sfx_voices=%d" % [MUSIC.resource_path, AudioManager.sfx_voices])


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 10:
		AudioManager.play_sfx(JUMP, -3.0, 1.1)
		print("[AUDIO] jump played")
	# A stream still playing when the engine quits leaks its playback object;
	# run_project.py lists that as an `info` exit_leak note, not an error.
	# Releasing the music before the smoke run ends keeps the log empty.
	if _frames == 30:
		AudioManager.stop_music(0.0)
		print("[AUDIO] music released")
GDSCRIPT
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/main.tscn",
    "actions": [
      {"type":"attach_script","node_path":"root","script_path":"scripts/jukebox.gd"}
    ]
  }'
```

`preload` needs the `.import` from Step 4 — that is why the copy happens after
the import, not before.

### Verify

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_audio '{"audio_paths":["audio"],"expect":{"not_silent":true,"no_clipping":true}}'
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project \
  --quit-after 120 --timeout 60 --log-file /absolute/path/to/project/run.log --pretty
grep '\[AUDIO\]' /absolute/path/to/project/run.log
```

Expected: `inspect_audio` exits 0; `validate_project.py` `"ok": true` with
`counts.warnings == 0` (a `no 'SFX' audio bus` warning means Step 5 was skipped
or ran after the autoload); `run_project.py` `"ok": true` with
`counts.errors == 0`; `grep` shows `music=res://audio/overworld.wav
sfx_voices=8`, `jump played` and `music released`.

---

## 14. Pixel Art From ASCII

**Goal.** A hero sheet, a tileset, a painted level and a themed panel — all
authored as text, all read back as text.

**Requires.** §1.

### Step 1 — The hero, one character per pixel

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/hero.png",
    "palette": {"h": "#ab5236", "s": "#ffccaa", "e": "#000000", "b": "#29adff", "g": "#1d2b53"},
    "layout": "horizontal",
    "outline": "#1a1c2c",
    "frames": [
      {"name": "idle_0", "rows": [
        "................", "....hhhhhhhh....", "...hhhhhhhhhh...", "...hssssssssh...",
        "...hssessessh...", "...hssssssssh...", "....ssssssss....", "....bbbbbbbb....",
        "...bbbbbbbbbb...", "..sbbbbbbbbbbs..", "...bbbbbbbbbb...", "....gggggggg....",
        "....bb....bb....", "....bb....bb....", "...ggg....ggg...", "................"]},
      {"name": "idle_1", "rows": [
        "................", "................", "....hhhhhhhh....", "...hhhhhhhhhh...",
        "...hssessessh...", "...hssssssssh...", "....ssssssss....", "....bbbbbbbb....",
        "...bbbbbbbbbb...", "..sbbbbbbbbbbs..", "...bbbbbbbbbb...", "....gggggggg....",
        "....bb....bb....", "....bb....bb....", "...ggg....ggg...", "................"]},
      {"name": "walk_0", "rows": [
        "................", "....hhhhhhhh....", "...hhhhhhhhhh...", "...hssssssssh...",
        "...hssessessh...", "...hssssssssh...", "....ssssssss....", "....bbbbbbbb....",
        "...bbbbbbbbbb...", "..sbbbbbbbbbbs..", "...bbbbbbbbbb...", "....gggggggg....",
        "....bb....bb....", "...bb......bb...", "..ggg......ggg..", "................"]},
      {"name": "walk_1", "rows": [
        "................", "....hhhhhhhh....", "...hhhhhhhhhh...", "...hssssssssh...",
        "...hssessessh...", "...hssssssssh...", "....ssssssss....", "....bbbbbbbb....",
        "...bbbbbbbbbb...", "..sbbbbbbbbbbs..", "...bbbbbbbbbb...", "....gggggggg....",
        "....bb....bb....", "....bb....bb....", "....gg....gg....", "................"]}
    ]
  }'
```

The payload answers with the written PNG read back one character per pixel, so
the sprite is verified without looking at it. Frame 0 comes back as:

```
...AAAAAAAAAA...
..AAhhhhhhhhAA..
..AhhhhhhhhhhA..
..AhsssssssshA..
..AhssessesshA..
..AhsssssssshA..
..AAssssssssAA..
..AAbbbbbbbbAA..
.AAbbbbbbbbbbAA.
.AsbbbbbbbbbbsA.
.AAbbbbbbbbbbAA.
..AAggggggggAA..
...AbbAAAAbbA...
..AAbbA..AbbAA..
..AgggA..AgggA..
..AAAAA..AAAAA..
```

`A` is the outline colour the `outline` key added around every opaque pixel —
which is why the artwork stops one pixel short of every edge. Fill the last row
and the outline has nowhere to go; the payload then says `"outline_clipped": true`.
Also in the payload: `"width": 64, "height": 16, "frames": 4` and
`"grid": {"cell_width": 16, "cell_height": 16, …}` — paste that grid into
`build_sprite_frames` in Step 4.

Legs are drawn asymmetrically here, so `mirror_x` is deliberately not used:
mirroring is for symmetric poses (see `references/pixel_art.md`), and a mirrored
walk cycle moves both legs the same way.

### Step 2 — Tiles and a UI panel from shapes

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/tiles.png",
    "width": 16, "height": 16,
    "tile_check": true,
    "read_back": false,
    "frames": [
      {"name": "grass", "shapes": [
        {"type": "rect", "color": "#3e8948"},
        {"type": "noise", "colors": ["#63c74d", "#265c42"], "seed": 7, "density": 0.3}]},
      {"name": "dirt", "shapes": [
        {"type": "rect", "color": "#8f563b"},
        {"type": "noise", "colors": ["#663931", "#d9a066"], "seed": 11, "density": 0.25}]},
      {"name": "stone", "shapes": [
        {"type": "rect", "color": "#8b9bb4"},
        {"type": "checker", "colors": ["#8b9bb4", "#5a6988"], "cell": 8},
        {"type": "noise", "colors": ["#c0cbdc"], "seed": 3, "density": 0.08}]}
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/panel.png",
    "width": 24, "height": 24,
    "read_back": false,
    "shapes": [
      {"type": "rect", "color": "#262b44"},
      {"type": "rect_outline", "x": 0, "y": 0, "width": 24, "height": 24, "color": "#5a6988", "thickness": 2},
      {"type": "rect_outline", "x": 2, "y": 2, "width": 20, "height": 20, "color": "#3a4466", "thickness": 1}
    ]
  }'
```

Each tile reports `"seamless": true` from `tile_check`, and the atlas is 48×16:
three 16×16 cells whose atlas coordinates are the frame order — grass `(0,0)`,
dirt `(1,0)`, stone `(2,0)`.

### Step 3 — Measure the panel instead of guessing its margins

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  process_image '{"input_path": "art/panel.png", "output_path": "art/panel.png",
                  "operations": [{"type": "nine_patch_margins"}], "describe": false}'
```

Answer: `"margins": {"left": 3, "top": 3, "right": 3, "bottom": 3}` plus the
`stylebox_texture` and `nine_patch_rect` blocks ready to paste.

### Step 4 — Import, then turn the sheet into SpriteFrames

```bash
python3 /absolute/path/to/godot/scripts/import/import_project.py /absolute/path/to/project
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/hero.tscn",
    "create_if_missing": true,
    "root_node_type": "CharacterBody2D",
    "root_node_name": "Hero",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"AnimatedSprite2D","node_name":"Sprite"},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":10,"y":14}}}}},
      {"type":"build_sprite_frames","node_path":"root/Sprite","spritesheet":"art/hero.png",
       "grid":{"cell_width":16,"cell_height":16},
       "animations":[
         {"name":"idle","fps":4,"loop":true,"frames":[{"row":0,"cols":[0,1]}]},
         {"name":"walk","fps":8,"loop":true,"frames":[{"row":0,"cols":[2,3]}]}],
       "resource_save_path":"art/hero_frames.tres"},
      {"type":"configure_node","node_path":"root/Sprite","properties":{"animation":"idle","autoplay":"idle"}}
    ]
  }'
```

The `shape` inline resource puts its fields under `properties` — a property
written next to `__resource_type` is an error, not a silent drop.

### Step 5 — Tileset, then paint the level from ASCII

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  build_tileset '{
    "resource_path": "tilesets/world.tres",
    "tile_size": {"x": 16, "y": 16},
    "physics_layers": [{"collision_layer": 1, "collision_mask": 1}],
    "sources": [{"source_id": 0, "texture": "art/tiles.png", "tiles": "all",
                 "tile_defaults": {"collision": "full_cell"}}]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level_1.tscn",
    "create_if_missing": true,
    "root_node_type": "Node2D",
    "root_node_name": "Level",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"TileMapLayer","node_name":"Ground"},
      {"type":"paint_tilemap","node_path":"root/Ground","tile_set":"tilesets/world.tres",
       "ascii_map":{
         "legend":{"g":{"source_id":0,"atlas_coords":{"x":0,"y":0}},
                   "d":{"source_id":0,"atlas_coords":{"x":1,"y":0}},
                   "s":{"source_id":0,"atlas_coords":{"x":2,"y":0}}},
         "rows":["ssssssssssss","s..gg......s","s..........s","s..........s","s..........s","dddddddddddd"]}}
    ]
  }'
```

Rows 2–4 are left empty on purpose: `"collision": "full_cell"` gives every
painted tile a collider, so a decorative tile in the walking lane is a wall.

### Step 6 — The panel becomes the theme

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  build_theme '{
    "resource_path": "theme/main.tres",
    "default_font_size": 16,
    "types": {
      "PanelContainer": {
        "styleboxes": {
          "panel": {
            "__resource_type": "StyleBoxTexture",
            "properties": {
              "texture": {"__resource": "res://art/panel.png"},
              "texture_margin_left": 3, "texture_margin_top": 3,
              "texture_margin_right": 3, "texture_margin_bottom": 3,
              "content_margin_left": 12, "content_margin_top": 10,
              "content_margin_right": 12, "content_margin_bottom": 10
            }
          }
        }
      },
      "Label": {"colors": {"font_color": "#e8f1f2"}},
      "Button": {
        "colors": {"font_color": "#e8f1f2", "font_focus_color": "#ffe66d", "font_hover_color": "#ffe66d"},
        "styleboxes": {
          "normal": {"bg_color": "#3a4466", "corner_radius": 4, "content_margin": 8},
          "hover": {"bg_color": "#5a6988", "corner_radius": 4, "content_margin": 8},
          "pressed": {"bg_color": "#262b44", "corner_radius": 4, "content_margin": 8},
          "focus": {"bg_color": "#3a4466", "corner_radius": 4, "border_width": 2, "border_color": "#ffe66d", "content_margin": 8}
        }
      }
    }
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{"actions":[{"type":"set_setting","name":"gui/theme/custom","value":"res://theme/main.tres"}]}'
```

### Verify

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_image '{"image_path":"art/hero.png","expect":{"not_blank":true,"width":64,"height":16,"max_unique_colors":8,"has_alpha":true}}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_tilemap '{"scene_path":"scenes/level_1.tscn","node_path":"root/Ground","format":"text"}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_resource '{"resource_path":"theme/main.tres"}'
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
```

Expected: `inspect_image` exits 0 with every `expect_results` entry
`"passed": true`; `inspect_tilemap` prints the level back as

```
############
#..@@......#
#..........#
#..........#
#..........#
%%%%%%%%%%%%
```

`inspect_resource` shows `PanelContainer/styles/panel` holding
`"texture": {"__resource": "res://art/panel.png"}` and the four margins — a
`null` texture there means the PNG was not imported before `build_theme` ran;
`validate_project.py` reports `"ok": true` with zero warnings.

---

## 15. Inventory, Items And Loot

**Goal.** Items as data resources, a bag on the player, pickups and a loot
chest that fill it, a grid UI that shows it, and a save file that survives it.

**Requires.** §1, §13 (`AudioManager` and `audio/coin.wav`) and §14
(`scenes/hero.tscn`, `scenes/level_1.tscn`).

### Step 1 — Copy the templates and rebuild the class cache

```bash
cp /absolute/path/to/godot/templates/gdscript/item_data.gd \
   /absolute/path/to/godot/templates/gdscript/inventory.gd \
   /absolute/path/to/godot/templates/gdscript/loot_table.gd \
   /absolute/path/to/godot/templates/gdscript/inventory_ui.gd \
   /absolute/path/to/project/scripts/
godot --headless --path /absolute/path/to/project --import
```

`ItemData`, `Inventory` and `LootTable` are `class_name` scripts: without this
`--import` every later `@export var item: ItemData` fails to parse.

### Step 2 — Two icons

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/icon_coin.png",
    "palette": {"y": "#ffcd75", "o": "#ef7d57", "d": "#b13e53"},
    "read_back": false,
    "rows": ["..yyyy..", ".yoooyy.", "yoyyoyoy", "yoyooyoy", "yoyooyoy", "yoyyoyoy", ".ydddyy.", "..dddd.."]
  }'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/icon_potion.png",
    "palette": {"g": "#38b764", "l": "#a7f070", "c": "#94b0c2", "k": "#566c86"},
    "read_back": false,
    "rows": ["..kcck..", "...cc...", "..cccc..", ".cggggc.", "cglggggc", "cggggggc", "cggggggc", ".cccccc."]
  }'
python3 /absolute/path/to/godot/scripts/import/import_project.py /absolute/path/to/project
```

### Step 3 — One .tres per item

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  resource_batch '{
    "resource_path": "items/coin.tres",
    "create_if_missing": true,
    "script": "res://scripts/item_data.gd",
    "actions": [
      {"type":"set_properties","properties":{
        "id":"coin","display_name":"Coin","max_stack":99,"value":1,
        "icon":{"__resource":"res://art/icon_coin.png"},
        "tags":["currency"],"description":"Shiny. Stacks to 99."}}
    ]
  }'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  resource_batch '{
    "resource_path": "items/potion.tres",
    "create_if_missing": true,
    "script": "res://scripts/item_data.gd",
    "actions": [
      {"type":"set_properties","properties":{
        "id":"potion","display_name":"Potion","max_stack":5,"value":25,
        "icon":{"__resource":"res://art/icon_potion.png"},
        "tags":["consumable","heal"],"description":"Heals 2 hearts."}}
    ]
  }'
```

`script` (not `resource_type`) is what makes these instances of the project's
own class: the saved file starts
`[gd_resource type="Resource" script_class="ItemData" format=3]` and the typed
export round-trips as `tags = Array[String](["currency"])`.

### Step 4 — A weighted loot table

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  resource_batch '{
    "resource_path": "loot/chest.tres",
    "create_if_missing": true,
    "script": "res://scripts/loot_table.gd",
    "actions": [
      {"type":"set_properties","properties":{
        "rng_seed":1234,
        "rolls":3,
        "entries":[
          {"item":{"__resource":"res://items/coin.tres"},"weight":6.0,"min":1,"max":5},
          {"item":{"__resource":"res://items/potion.tres"},"weight":3.0,"min":1,"max":1},
          {"item":null,"weight":1.0}
        ]}}
    ]
  }'
```

`"item": null` is the miss slot — an empty draw is a real outcome, not an error.
`rng_seed` fixes the sequence, which is the only reason a unit test can assert
on loot at all; ship `-1` when you want a different chest every run.

### Step 5 — The bag on the player, and something to pick up

```bash
cat > /absolute/path/to/project/scripts/hero.gd <<'GDSCRIPT'
extends CharacterBody2D

@export var speed: float = 120.0

@onready var _sprite: AnimatedSprite2D = $Sprite


func _physics_process(_delta: float) -> void:
	var direction: Vector2 = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = direction * speed
	move_and_slide()
	var wanted: StringName = &"walk" if direction != Vector2.ZERO else &"idle"
	if _sprite.animation != wanted:
		_sprite.play(wanted)
GDSCRIPT
```

```bash
cat > /absolute/path/to/project/scripts/item_pickup.gd <<'GDSCRIPT'
extends Area2D

## Either a single item...
@export var item: ItemData
@export var amount: int = 1
## ...or a table rolled when the player touches it. `loot` wins when both are set.
@export var loot: LootTable
@export var pickup_sound: AudioStream


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group(&"player"):
		return
	var bag: Inventory = body.get_node_or_null("Inventory") as Inventory
	if bag == null:
		return
	if not _grant(bag):
		# A full bag leaves the pickup on the ground instead of eating it.
		print("[PICKUP] bag full, %s stays" % name)
		return
	if pickup_sound != null:
		AudioManager.play_sfx(pickup_sound)
	queue_free()


func _grant(bag: Inventory) -> bool:
	if loot != null:
		var granted: int = 0
		for drop in loot.roll():
			var drop_item: ItemData = drop["item"]
			var taken: int = bag.add(drop_item, int(drop["count"]))
			granted += taken
			print("[PICKUP] loot %s x%d" % [drop_item.id, taken])
		return granted > 0
	if item == null:
		return false
	var taken_one: int = bag.add(item, amount)
	if taken_one <= 0:
		return false
	print("[PICKUP] %s x%d -> %d in bag" % [item.id, taken_one, bag.count(item)])
	return true
GDSCRIPT
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/hero.tscn",
    "actions": [
      {"type":"configure_node","node_path":"root","groups_add":["player"],"properties":{"collision_layer":2,"collision_mask":1}},
      {"type":"add_node","parent_node_path":"root","node_type":"Node","node_name":"Inventory"},
      {"type":"attach_script","node_path":"root/Inventory","script_path":"scripts/inventory.gd",
       "script_properties":{"slot_count":8}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/hero.gd","script_properties":{"speed":120.0}}
    ]
  }'
```

The pickup looks the player up by group and the bag up by node name, so nothing
in the level has to hold a reference to either.

### Step 6 — The grid UI

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/inventory_ui.tscn",
    "create_if_missing": true,
    "root_node_type": "CanvasLayer",
    "root_node_name": "InventoryUI",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"layer":4}},

      {"type":"add_node","parent_node_path":"root","node_type":"Control","node_name":"Root"},
      {"type":"configure_control","node_path":"root/Root","layout_preset":"FULL_RECT"},
      {"type":"configure_node","node_path":"root/Root","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/Root","node_type":"CenterContainer","node_name":"Center"},
      {"type":"configure_control","node_path":"root/Root/Center","layout_preset":"FULL_RECT"},

      {"type":"add_node","parent_node_path":"root/Root/Center","node_type":"PanelContainer","node_name":"Panel"},
      {"type":"add_node","parent_node_path":"root/Root/Center/Panel","node_type":"MarginContainer","node_name":"Margin"},
      {"type":"configure_control","node_path":"root/Root/Center/Panel/Margin",
       "theme_overrides":{"constants":{"margin_left":16,"margin_right":16,"margin_top":12,"margin_bottom":12}}},

      {"type":"add_node","parent_node_path":"root/Root/Center/Panel/Margin","node_type":"VBoxContainer","node_name":"Body"},
      {"type":"configure_control","node_path":"root/Root/Center/Panel/Margin/Body","theme_overrides":{"constants":{"separation":10}}},

      {"type":"add_node","parent_node_path":"root/Root/Center/Panel/Margin/Body","node_type":"Label","node_name":"Title",
       "properties":{"text":"BAG","horizontal_alignment":1}},
      {"type":"add_node","parent_node_path":"root/Root/Center/Panel/Margin/Body","node_type":"GridContainer","node_name":"Grid",
       "properties":{"columns":4}},
      {"type":"configure_control","node_path":"root/Root/Center/Panel/Margin/Body/Grid",
       "theme_overrides":{"constants":{"h_separation":8,"v_separation":8}}},
      {"type":"configure_node","node_path":"root/Root/Center/Panel/Margin/Body/Grid","unique_name_in_owner":true},

      {"type":"attach_script","node_path":"root","script_path":"scripts/inventory_ui.gd",
       "script_properties":{"columns":4,"slot_min_size":{"__type":"Vector2","x":120,"y":36}}}
    ]
  }'
```

### Step 7 — Put it in the level

```bash
cat > /absolute/path/to/project/scripts/level_bag.gd <<'GDSCRIPT'
extends Node2D

@onready var _bag: Inventory = $Hero/Inventory
@onready var _ui: CanvasLayer = %InventoryUI


func _ready() -> void:
	_ui.call(&"bind", _bag)
	_bag.changed.connect(_on_bag_changed)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("inventory"):
		return
	get_viewport().set_input_as_handled()
	_ui.call(&"toggle")


## Everything the save file needs, in one dictionary.
func save_progress() -> bool:
	var payload: Dictionary = GameManager.to_save_data()
	payload["inventory"] = _bag.to_dict()
	var saved: bool = SaveManager.save_game(payload, 0)
	if saved:
		print("[BAG] saved slots_used=%d" % _bag.used_slots())
	return saved


func load_progress() -> void:
	var data: Dictionary = SaveManager.load_game(0)
	GameManager.from_save_data(data)
	var raw: Variant = data.get("inventory", {})
	if raw is Dictionary:
		_bag.from_dict(raw)
	print("[BAG] loaded slots_used=%d" % _bag.used_slots())


func _on_bag_changed() -> void:
	print("[BAG] slots_used=%d" % _bag.used_slots())
GDSCRIPT
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"add_input_action","action_name":"inventory","replace":true},
      {"type":"add_input_event","action_name":"inventory","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":73}}}
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level_1.tscn",
    "actions": [
      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/hero.tscn","node_name":"Hero",
       "properties":{"position":{"__type":"Vector2","x":40,"y":56}}},

      {"type":"add_node","parent_node_path":"root","node_type":"Area2D","node_name":"CoinPickup",
       "properties":{"position":{"__type":"Vector2","x":96,"y":56},"collision_layer":1,"collision_mask":2}},
      {"type":"add_node","parent_node_path":"root/CoinPickup","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CircleShape2D","properties":{"radius":10.0}}}},
      {"type":"add_node","parent_node_path":"root/CoinPickup","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/icon_coin.png"}}},
      {"type":"attach_script","node_path":"root/CoinPickup","script_path":"scripts/item_pickup.gd",
       "script_properties":{"item":{"__resource":"res://items/coin.tres"},"amount":5,
        "pickup_sound":{"__resource":"res://audio/coin.wav"}}},

      {"type":"add_node","parent_node_path":"root","node_type":"Area2D","node_name":"PotionPickup",
       "properties":{"position":{"__type":"Vector2","x":128,"y":56},"collision_layer":1,"collision_mask":2}},
      {"type":"add_node","parent_node_path":"root/PotionPickup","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CircleShape2D","properties":{"radius":10.0}}}},
      {"type":"add_node","parent_node_path":"root/PotionPickup","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/icon_potion.png"}}},
      {"type":"attach_script","node_path":"root/PotionPickup","script_path":"scripts/item_pickup.gd",
       "script_properties":{"item":{"__resource":"res://items/potion.tres"},"amount":2,
        "pickup_sound":{"__resource":"res://audio/coin.wav"}}},

      {"type":"add_node","parent_node_path":"root","node_type":"Area2D","node_name":"Chest",
       "properties":{"position":{"__type":"Vector2","x":160,"y":56},"collision_layer":1,"collision_mask":2}},
      {"type":"add_node","parent_node_path":"root/Chest","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":16,"y":16}}}}},
      {"type":"attach_script","node_path":"root/Chest","script_path":"scripts/item_pickup.gd",
       "script_properties":{"loot":{"__resource":"res://loot/chest.tres"},
        "pickup_sound":{"__resource":"res://audio/coin.wav"}}},

      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/inventory_ui.tscn","node_name":"InventoryUI"},
      {"type":"configure_node","node_path":"root/InventoryUI","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root","node_type":"Camera2D","node_name":"Camera2D",
       "properties":{"position":{"__type":"Vector2","x":96,"y":48},"zoom":{"__type":"Vector2","x":4,"y":4}}},

      {"type":"attach_script","node_path":"root","script_path":"scripts/level_bag.gd"}
    ]
  }'
```

### Step 8 — Unit-test the rules

```bash
test -f /absolute/path/to/project/tests/test_case.gd || \
  python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --init-mini
rm -f /absolute/path/to/project/tests/test_example.gd
```

```bash
cat > /absolute/path/to/project/tests/test_inventory.gd <<'GDSCRIPT'
extends "res://tests/test_case.gd"

var bag: Inventory


func before_each() -> void:
	bag = add_child_autofree(Inventory.new())
	bag.slot_count = 3


func _item(id: String, max_stack: int) -> ItemData:
	var item := ItemData.new()
	item.id = id
	item.display_name = id.capitalize()
	item.max_stack = max_stack
	return item


func test_a_stack_tops_up_before_a_second_slot_is_used() -> void:
	var coin: ItemData = _item("coin", 99)
	assert_eq(bag.add(coin, 3), 3)
	assert_eq(bag.add(coin, 4), 4)
	assert_eq(bag.count(coin), 7)
	assert_eq(bag.used_slots(), 1, "7 coins of a 99 stack must not take two slots")


func test_add_returns_only_what_fit() -> void:
	var potion: ItemData = _item("potion", 5)
	# 3 slots x 5 per stack = 15 is everything this bag can hold.
	assert_eq(bag.add(potion, 20), 15)
	assert_eq(bag.count(potion), 15)
	assert_true(bag.is_full())
	assert_eq(bag.space_for(potion), 0)


func test_remove_reports_what_was_actually_taken() -> void:
	var potion: ItemData = _item("potion", 5)
	bag.add(potion, 7)
	assert_eq(bag.remove(potion, 3), 3)
	assert_eq(bag.count(potion), 4)
	assert_eq(bag.remove(potion, 99), 4, "removing more than you own takes what is there")
	assert_true(bag.is_empty())


func test_items_match_by_id_not_by_instance() -> void:
	var loaded_once: ItemData = _item("coin", 99)
	var loaded_twice: ItemData = _item("coin", 99)
	bag.add(loaded_once, 2)
	assert_eq(bag.count(loaded_twice), 2, "the same .tres loaded twice is still one item")
	assert_true(bag.has(loaded_twice, 2))


func test_signals_fire_once_per_mutation() -> void:
	var coin: ItemData = _item("coin", 99)
	watch_signals(bag)
	bag.add(coin, 2)
	assert_signal_emit_count(bag, "item_added", 1)
	assert_signal_emit_count(bag, "changed", 1)
	bag.add(coin, 0)
	assert_signal_emit_count(bag, "changed", 1, "a no-op must not repaint the UI")
	bag.remove(coin, 1)
	assert_signal_emitted(bag, "item_removed")


func test_a_saved_bag_comes_back_with_the_same_stacks() -> void:
	var coin: ItemData = load("res://items/coin.tres")
	var potion: ItemData = load("res://items/potion.tres")
	bag.add(coin, 12)
	bag.add(potion, 2)
	var payload: Dictionary = bag.to_dict()

	var restored: Inventory = add_child_autofree(Inventory.new())
	restored.from_dict(payload)
	assert_eq(restored.count(coin), 12)
	assert_eq(restored.count(potion), 2)
	assert_eq(restored.used_slots(), 2)


func test_a_seeded_loot_table_rolls_the_same_drops_every_time() -> void:
	var table: LootTable = load("res://loot/chest.tres")
	table.reset_rng(1234)
	var first: Array[Dictionary] = table.roll()
	table.reset_rng(1234)
	var second: Array[Dictionary] = table.roll()
	assert_eq(_summary(first), _summary(second))
	assert_eq(_summary(first), "coin x8, potion x1", "playbook 15 documents this exact drop")


func test_loot_validate_catches_a_table_that_can_never_drop() -> void:
	var broken := LootTable.new()
	broken.add_entry(_item("coin", 99), 0.0)
	var problems: PackedStringArray = broken.validate()
	assert_eq(problems.size(), 1)
	assert_string_contains(problems[0], "every weight is 0")
	assert_eq(broken.roll_once()["item"], null)


func _summary(drops: Array[Dictionary]) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for drop in drops:
		var item: ItemData = drop["item"]
		parts.append("%s x%d" % [item.id, int(drop["count"])])
	return ", ".join(parts)
GDSCRIPT
```

### Verify

```bash
mkdir -p /absolute/path/to/project/scenarios
cat > /absolute/path/to/project/scenarios/bag.json <<'JSON'
{
  "scene_path": "res://scenes/level_1.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "settle_frames": 4,
  "steps": [
    {"type": "action", "action_name": "move_right", "pressed": true},
    {"type": "wait_seconds", "seconds": 1.5},
    {"type": "action", "action_name": "move_right", "pressed": false},
    {"type": "wait_frames", "frames": 4},
    {"type": "key", "physical_keycode": 73, "pressed": true},
    {"type": "key", "physical_keycode": 73, "pressed": false},
    {"type": "wait_until", "node_path": "InventoryUI/Root", "property": "visible", "expected": true, "timeout_seconds": 2},
    {"type": "ui_report", "label": "bag-open", "node_path": "InventoryUI", "ascii": true, "fail_on": ["any"]},
    {"type": "dump_tree", "node_path": "InventoryUI/Root/Center/Panel/Margin/Body/Grid", "properties": ["text"], "max_depth": 3, "label": "slots"}
  ],
  "log_assertions": [
    {"regex": "\\[PICKUP\\] coin x5", "min_count": 1},
    {"regex": "\\[PICKUP\\] potion x2", "min_count": 1},
    {"regex": "\\[PICKUP\\] loot coin", "min_count": 1}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenarios/bag.json --pretty
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{
    "scene_path": "scenes/level_1.tscn",
    "code": "var bag: Inventory = scene.get_node(\"Hero/Inventory\")\nvar coin: ItemData = load(\"res://items/coin.tres\")\nbag.add(coin, 7)\nscene.call(&\"save_progress\")\nbag.clear()\nvar emptied: int = bag.count(coin)\nscene.call(&\"load_progress\")\nreturn {\"after_clear\": emptied, \"after_load\": bag.count(coin), \"slot_file\": FileAccess.file_exists(\"user://saves/slot_0.json\")}"
  }'
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
```

Expected: `run_tests.py` `"ok": true` with 8 passed; the scenario `"ok": true`
with the `bag-open` `ui_report` at `findings=0` and the `slots` dump showing

```
Grid (GridContainer)
  Slot0 (Button) text="Coin x13"
  Slot1 (Button) text="Potion x3"
  Slot2 (Button) text="-"
```

(5 coins from the pickup plus the 8 the seeded chest rolled, 2 potions plus 1);
`run_gdscript` returns `{"after_clear": 0, "after_load": 7, "slot_file": true}`,
which is the whole save round trip in one line; `validate_project.py` `"ok": true`
with zero warnings.

---

## 16. Branching Dialogue

**Goal.** An NPC conversation that asks a question, remembers the answer, and
says something different later because of it.

**Requires.** §1.

This playbook builds its own dialog box, so it does not need Playbook 9 — that
playbook is the same box without choices.

### Step 1 — Copy the three templates

```bash
cp /absolute/path/to/godot/templates/gdscript/dialogue_runner.gd \
   /absolute/path/to/godot/templates/gdscript/choice_list.gd \
   /absolute/path/to/godot/templates/gdscript/dialog_box.gd \
   /absolute/path/to/project/scripts/
godot --headless --path /absolute/path/to/project --import
```

### Step 2 — Write the graph

```bash
mkdir -p /absolute/path/to/project/dialogue
cat > /absolute/path/to/project/dialogue/marrow.json <<'JSON'
{
  "start": "intro",
  "nodes": {
    "intro": {"speaker": "Marrow", "text": "You came back.", "next": "ask"},
    "ask": {"speaker": "Marrow", "text": "Will you carry the lantern tonight?",
      "choices": [
        {"text": "I will.", "next": "promise", "set_flag": "promised"},
        {"text": "Not tonight.", "next": "refuse"},
        {"text": "What lantern?", "next": "explain"},
        {"text": "About that rumour...", "next": "rumour", "require_flag": "heard_rumour"}
      ]},
    "explain": {"speaker": "Marrow", "text": "The one on the north road. It keeps the dark honest.", "next": "ask"},
    "rumour": {"speaker": "Marrow", "text": "Do not believe everything the miller says.", "next": "ask"},
    "promise": {"speaker": "Marrow", "text": "Then the road is yours.", "next": "farewell"},
    "refuse": {"speaker": "Marrow", "text": "The dark will keep, I suppose.", "next": "farewell"},
    "farewell": {"speaker": "Marrow", "text": "One more thing, before you go.",
      "branch": [{"require_flag": "promised", "next": "bye_warm"}], "next": "bye_cold"},
    "bye_warm": {"speaker": "Marrow", "text": "Walk safe, lantern-bearer.", "end": true},
    "bye_cold": {"speaker": "Marrow", "text": "Walk safe. Stay in the light.", "end": true}
  }
}
JSON
```

Three things to read in that file: `set_flag` on a choice records the answer,
`require_flag` hides a choice until something happened (the rumour line is not
offered yet), and `branch` picks a different `next` once a flag is set — that is
how the same farewell node says two different things.

### Step 3 — Glue the runner to the box

```bash
cat > /absolute/path/to/project/scripts/talk.gd <<'GDSCRIPT'
extends Node2D

@onready var _runner: DialogueRunner = %Dialogue
@onready var _box: CanvasLayer = %DialogueBox
@onready var _choices: ChoiceList = %Choices


func _ready() -> void:
	# The runner talks to the UI only through signals, so the box never has to
	# know what a dialogue graph is.
	_runner.line_shown.connect(_on_line_shown)
	_runner.choices_shown.connect(_on_choices_shown)
	_runner.finished.connect(_on_dialogue_finished)
	_choices.choice_selected.connect(_runner.choose)
	# dialog_box.gd is reached by name: it has no class_name, so connect() and
	# call() keep this script free of unsafe member access.
	_box.connect(&"finished", _runner.advance)
	_runner.start()


func _on_line_shown(text: String, speaker: String, node_id: String) -> void:
	var lines: Array[String] = [text]
	_box.call(&"show_lines", lines, speaker)
	print("[TALK] line %s: %s" % [node_id, text])


func _on_choices_shown(choices: Array[Dictionary]) -> void:
	_choices.show_choices(choices)
	print("[TALK] choices=%d" % choices.size())


func _on_dialogue_finished() -> void:
	print("[TALK] finished promised=%s" % _runner.has_flag("promised"))
GDSCRIPT
```

### Step 4 — Build the scene

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/talk.tscn",
    "create_if_missing": true,
    "root_node_type": "Node2D",
    "root_node_name": "Talk",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"Node","node_name":"Dialogue"},
      {"type":"configure_node","node_path":"root/Dialogue","unique_name_in_owner":true},
      {"type":"attach_script","node_path":"root/Dialogue","script_path":"scripts/dialogue_runner.gd",
       "script_properties":{"graph_path":"res://dialogue/marrow.json","autostart":false}},

      {"type":"add_node","parent_node_path":"root","node_type":"CanvasLayer","node_name":"DialogueBox",
       "properties":{"layer":5}},
      {"type":"configure_node","node_path":"root/DialogueBox","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/DialogueBox","node_type":"Control","node_name":"DialogRoot"},
      {"type":"configure_control","node_path":"root/DialogueBox/DialogRoot","layout_preset":"FULL_RECT"},
      {"type":"configure_node","node_path":"root/DialogueBox/DialogRoot","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/DialogueBox/DialogRoot","node_type":"MarginContainer","node_name":"Anchor",
       "properties":{"grow_vertical":0,"mouse_filter":2}},
      {"type":"configure_control","node_path":"root/DialogueBox/DialogRoot/Anchor","layout_preset":"BOTTOM_WIDE",
       "theme_overrides":{"constants":{"margin_left":40,"margin_right":40,"margin_top":0,"margin_bottom":32}}},

      {"type":"add_node","parent_node_path":"root/DialogueBox/DialogRoot/Anchor","node_type":"PanelContainer","node_name":"Box"},
      {"type":"add_node","parent_node_path":"root/DialogueBox/DialogRoot/Anchor/Box","node_type":"VBoxContainer","node_name":"Body"},
      {"type":"configure_control","node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body","theme_overrides":{"constants":{"separation":10}}},

      {"type":"add_node","parent_node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body","node_type":"Label","node_name":"SpeakerLabel",
       "properties":{"text":"NPC"}},
      {"type":"configure_node","node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body/SpeakerLabel","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body","node_type":"RichTextLabel","node_name":"BodyLabel",
       "properties":{"bbcode_enabled":true,"fit_content":true,"scroll_active":false,"autowrap_mode":3,"text":"..."}},
      {"type":"configure_control","node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body/BodyLabel",
       "custom_minimum_size":{"__type":"Vector2","x":0,"y":72},"size_flags_horizontal":"EXPAND_FILL"},
      {"type":"configure_node","node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body/BodyLabel","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body","node_type":"VBoxContainer","node_name":"Choices"},
      {"type":"configure_control","node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body/Choices","theme_overrides":{"constants":{"separation":6}}},
      {"type":"configure_node","node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body/Choices","unique_name_in_owner":true},
      {"type":"attach_script","node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body/Choices","script_path":"scripts/choice_list.gd"},

      {"type":"attach_script","node_path":"root/DialogueBox","script_path":"scripts/dialog_box.gd",
       "script_properties":{"characters_per_second":240.0}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/talk.gd"}
    ]
  }'
```

Every node is owned by `talk.tscn`, which is why `%DialogRoot` resolves for
`dialog_box.gd` *and* `%Choices` resolves for `talk.gd`: unique names are
registered per owner scene, so they do not cross an `instantiate_scene`
boundary.

### Step 5 — Unit-test the runner

```bash
test -f /absolute/path/to/project/tests/test_case.gd || \
  python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --init-mini
rm -f /absolute/path/to/project/tests/test_example.gd
```

```bash
cat > /absolute/path/to/project/tests/test_dialogue.gd <<'GDSCRIPT'
extends "res://tests/test_case.gd"

var runner: DialogueRunner


func before_each() -> void:
	runner = add_child_autofree(DialogueRunner.new())
	assert_true(runner.load_graph_file("res://dialogue/marrow.json"), "the shipped graph must load")


func test_the_shipped_graph_has_no_dangling_targets() -> void:
	var graph: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://dialogue/marrow.json"))
	assert_eq(DialogueRunner.validate_graph(graph), PackedStringArray())


func test_a_line_with_next_walks_to_the_following_node() -> void:
	watch_signals(runner)
	runner.start()
	assert_signal_emitted_with(runner, "line_shown", ["You came back.", "Marrow", "intro"])
	runner.advance()
	assert_eq(runner.current_node_id(), "ask")
	assert_true(runner.is_awaiting_choice())


func test_a_choice_behind_an_unset_flag_is_not_offered() -> void:
	runner.start()
	runner.advance()
	assert_eq(runner.visible_choices().size(), 3, "the rumour choice needs the heard_rumour flag")

	runner.set_flag("heard_rumour", true)
	runner.start()
	runner.advance()
	assert_eq(runner.visible_choices().size(), 4)


func test_advance_does_nothing_while_a_choice_is_open() -> void:
	runner.start()
	runner.advance()
	assert_eq(runner.current_node_id(), "ask")
	runner.advance()
	runner.advance()
	assert_eq(runner.current_node_id(), "ask", "only choose() answers a question")


func test_a_flag_set_by_a_choice_changes_a_later_line() -> void:
	runner.start()
	runner.advance()
	runner.choose(0)                                   # "I will." sets promised
	assert_true(runner.has_flag("promised"))
	assert_eq(runner.current_node_id(), "promise")
	runner.advance()                                   # "One more thing..."
	assert_eq(runner.current_node_id(), "farewell")
	runner.advance()                                   # branch reads the flag
	assert_eq(runner.current_node_id(), "bye_warm")

	# The same walk without the flag ends on the other line.
	runner.flags.clear()
	runner.start()
	runner.advance()
	runner.choose(1)                                   # "Not tonight."
	runner.advance()
	runner.advance()
	assert_eq(runner.current_node_id(), "bye_cold")


func test_the_last_node_finishes_the_conversation() -> void:
	watch_signals(runner)
	runner.start()
	runner.advance()
	runner.choose(1)
	runner.advance()
	runner.advance()
	runner.advance()
	assert_signal_emitted(runner, "finished")
	assert_false(runner.is_running())


func test_a_dangling_next_target_is_named_with_its_id() -> void:
	var broken: Dictionary = {
		"start": "intro",
		"nodes": {
			"intro": {"text": "Hello.", "next": "midle"},
			"middle": {"text": "Bye.", "choices": [{"text": "wave", "next": "nowhere"}]},
		},
	}
	var problems: PackedStringArray = DialogueRunner.validate_graph(broken)
	assert_eq(problems.size(), 2)
	assert_string_contains(problems[0], "node 'intro': next -> 'midle' does not exist")
	assert_string_contains(problems[1], "choice 0 ('wave'): next -> 'nowhere' does not exist")


func test_load_graph_refuses_a_broken_graph_instead_of_half_loading_it() -> void:
	allow_errors()
	var broken: Dictionary = {"start": "nope", "nodes": {"intro": {"text": "Hello.", "end": true}}}
	var fresh: DialogueRunner = add_child_autofree(DialogueRunner.new())
	assert_false(fresh.load_graph(broken))
	assert_false(fresh.start(), "a runner with no graph must not pretend to run")
GDSCRIPT
```

### Verify

```bash
mkdir -p /absolute/path/to/project/scenarios
cat > /absolute/path/to/project/scenarios/talk.json <<'JSON'
{
  "scene_path": "res://scenes/talk.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "settle_frames": 4,
  "steps": [
    {"type": "wait_seconds", "seconds": 0.4},
    {"type": "assert", "assertion": "property", "node_path": "DialogueBox/DialogRoot/Anchor/Box/Body/BodyLabel",
     "property": "text", "expected": "You came back."},
    {"type": "key", "keycode": 4194309, "pressed": true},
    {"type": "key", "keycode": 4194309, "pressed": false},
    {"type": "wait_seconds", "seconds": 0.4},
    {"type": "dump_tree", "node_path": "DialogueBox/DialogRoot/Anchor/Box/Body/Choices",
     "properties": ["text"], "max_depth": 3, "label": "choices"},
    {"type": "ui_report", "label": "question", "node_path": "DialogueBox", "ascii": true, "fail_on": ["any"]},
    {"type": "key", "keycode": 4194322, "pressed": true},
    {"type": "key", "keycode": 4194322, "pressed": false},
    {"type": "wait_frames", "frames": 4},
    {"type": "key", "keycode": 4194309, "pressed": true},
    {"type": "key", "keycode": 4194309, "pressed": false},
    {"type": "wait_seconds", "seconds": 0.4},
    {"type": "assert", "assertion": "property", "node_path": "DialogueBox/DialogRoot/Anchor/Box/Body/BodyLabel",
     "property": "text", "expected": "The dark will keep, I suppose."},
    {"type": "key", "keycode": 4194309, "pressed": true},
    {"type": "key", "keycode": 4194309, "pressed": false},
    {"type": "wait_seconds", "seconds": 0.4},
    {"type": "assert", "assertion": "property", "node_path": "DialogueBox/DialogRoot/Anchor/Box/Body/BodyLabel",
     "property": "text", "expected": "One more thing, before you go."},
    {"type": "key", "keycode": 4194309, "pressed": true},
    {"type": "key", "keycode": 4194309, "pressed": false},
    {"type": "wait_seconds", "seconds": 0.4},
    {"type": "assert", "assertion": "property", "node_path": "DialogueBox/DialogRoot/Anchor/Box/Body/BodyLabel",
     "property": "text", "expected": "Walk safe. Stay in the light."},
    {"type": "key", "keycode": 4194309, "pressed": true},
    {"type": "key", "keycode": 4194309, "pressed": false},
    {"type": "wait_seconds", "seconds": 0.3},
    {"type": "assert", "assertion": "property", "node_path": "DialogueBox/DialogRoot", "property": "visible", "expected": false}
  ],
  "log_assertions": [
    {"regex": "\\[TALK\\] choices=3", "min_count": 1},
    {"regex": "\\[TALK\\] finished promised=false", "min_count": 1}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenarios/talk.json --pretty
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
```

Expected: `run_tests.py` `"ok": true` (8 dialogue tests, plus playbook 15's if
it ran); the scenario `"ok": true`, which means the second choice was taken with
the keyboard and the conversation ended on the *cold* farewell, and the
`choices` dump lists exactly three buttons:

```
Choices (VBoxContainer)
  Choice0 (Button) text="I will."
  Choice1 (Button) text="Not tonight."
  Choice2 (Button) text="What lantern?"
```

The fourth choice is missing because `heard_rumour` is not set — that is
`require_flag` working, not a bug.

Two facts the scenario depends on, both verified on 4.7: the built-in `ui_*`
actions are matched by **`keycode`** (`ui_accept` 4194309, `ui_down` 4194322),
and a focused `Button` does **not** consume the `ui_accept` key press — it
reaches `_unhandled_input`, where `dialog_box.gd` would advance the line behind
the question. `choice_list.gd` therefore takes `ui_accept` in `_input` and
activates the focused choice itself. Delete that handler and the box skips the
question while the choices are still on screen.

---

## 17. Settings Menu (Volume, Fullscreen, Remap)

**Goal.** Options that survive a restart: three volumes mapped onto the audio
buses, fullscreen and vsync, and a key the player rebound — all in
`user://settings.cfg`, all applied on boot.

**Requires.** §1.

### Step 1 — Buses first, always

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  setup_audio_buses '{
    "buses": [
      {"name": "Master", "volume_db": 0.0},
      {"name": "Music", "send": "Master", "volume_db": -6.0},
      {"name": "SFX", "send": "Master", "volume_db": -3.0},
      {"name": "UI", "send": "SFX", "volume_db": -4.0}
    ],
    "save_path": "audio/default_bus_layout.tres",
    "set_project_setting": true
  }'
```

Skip this and `Settings` writes volumes to buses that do not exist: the slider
moves, nothing gets quieter, and the run carries a
`Settings: no 'Music' audio bus` warning. (Playbook 13 Step 5 is the same call —
running it twice is harmless.)

### Step 2 — Register the autoload

```bash
cp /absolute/path/to/godot/templates/gdscript/settings.gd \
   /absolute/path/to/godot/templates/gdscript/settings_menu.gd \
   /absolute/path/to/godot/templates/gdscript/input_remap.gd \
   /absolute/path/to/project/scripts/
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"add_autoload","autoload_name":"Settings","path":"res://scripts/settings.gd","singleton":true}
    ]
  }'
```

`Settings._ready()` reads the file and applies it, so every scene — including
the first one — boots with the player's choices already on.

### Step 3 — The options screen, containers first

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/settings_menu.tscn",
    "create_if_missing": true,
    "root_node_type": "Control",
    "root_node_name": "SettingsMenu",
    "actions": [
      {"type":"configure_control","node_path":"root","layout_preset":"FULL_RECT"},

      {"type":"add_node","parent_node_path":"root","node_type":"MarginContainer","node_name":"Frame"},
      {"type":"configure_control","node_path":"root/Frame","layout_preset":"FULL_RECT",
       "theme_overrides":{"constants":{"margin_left":64,"margin_right":64,"margin_top":48,"margin_bottom":48}}},

      {"type":"add_node","parent_node_path":"root/Frame","node_type":"VBoxContainer","node_name":"Column"},
      {"type":"configure_control","node_path":"root/Frame/Column","theme_overrides":{"constants":{"separation":18}}},

      {"type":"add_node","parent_node_path":"root/Frame/Column","node_type":"Label","node_name":"Title",
       "properties":{"text":"OPTIONS","horizontal_alignment":1}},
      {"type":"add_node","parent_node_path":"root/Frame/Column","node_type":"HSeparator","node_name":"Rule"},

      {"type":"add_node","parent_node_path":"root/Frame/Column","node_type":"GridContainer","node_name":"Grid",
       "properties":{"columns":2}},
      {"type":"configure_control","node_path":"root/Frame/Column/Grid","size_flags_vertical":"EXPAND_FILL",
       "theme_overrides":{"constants":{"h_separation":24,"v_separation":14}}},

      {"type":"add_node","parent_node_path":"root/Frame/Column/Grid","node_type":"Label","node_name":"MasterLabel","properties":{"text":"Master Volume"}},
      {"type":"add_node","parent_node_path":"root/Frame/Column/Grid","node_type":"HSlider","node_name":"MasterSlider",
       "properties":{"min_value":0,"max_value":100,"step":1,"value":100}},
      {"type":"configure_control","node_path":"root/Frame/Column/Grid/MasterSlider","size_flags_horizontal":"EXPAND_FILL","size_flags_vertical":"SHRINK_CENTER"},
      {"type":"configure_node","node_path":"root/Frame/Column/Grid/MasterSlider","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/Frame/Column/Grid","node_type":"Label","node_name":"MusicLabel","properties":{"text":"Music"}},
      {"type":"add_node","parent_node_path":"root/Frame/Column/Grid","node_type":"HSlider","node_name":"MusicSlider",
       "properties":{"min_value":0,"max_value":100,"step":1,"value":80}},
      {"type":"configure_control","node_path":"root/Frame/Column/Grid/MusicSlider","size_flags_horizontal":"EXPAND_FILL","size_flags_vertical":"SHRINK_CENTER"},
      {"type":"configure_node","node_path":"root/Frame/Column/Grid/MusicSlider","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/Frame/Column/Grid","node_type":"Label","node_name":"SfxLabel","properties":{"text":"Effects"}},
      {"type":"add_node","parent_node_path":"root/Frame/Column/Grid","node_type":"HSlider","node_name":"SfxSlider",
       "properties":{"min_value":0,"max_value":100,"step":1,"value":80}},
      {"type":"configure_control","node_path":"root/Frame/Column/Grid/SfxSlider","size_flags_horizontal":"EXPAND_FILL","size_flags_vertical":"SHRINK_CENTER"},
      {"type":"configure_node","node_path":"root/Frame/Column/Grid/SfxSlider","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/Frame/Column/Grid","node_type":"Label","node_name":"FullscreenLabel","properties":{"text":"Fullscreen"}},
      {"type":"add_node","parent_node_path":"root/Frame/Column/Grid","node_type":"CheckButton","node_name":"FullscreenCheck",
       "properties":{"text":"OFF"}},
      {"type":"configure_control","node_path":"root/Frame/Column/Grid/FullscreenCheck","size_flags_horizontal":"SHRINK_BEGIN"},
      {"type":"configure_node","node_path":"root/Frame/Column/Grid/FullscreenCheck","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/Frame/Column/Grid","node_type":"Label","node_name":"VsyncLabel","properties":{"text":"V-Sync"}},
      {"type":"add_node","parent_node_path":"root/Frame/Column/Grid","node_type":"CheckButton","node_name":"VsyncCheck",
       "properties":{"button_pressed":true,"text":"ON"}},
      {"type":"configure_control","node_path":"root/Frame/Column/Grid/VsyncCheck","size_flags_horizontal":"SHRINK_BEGIN"},
      {"type":"configure_node","node_path":"root/Frame/Column/Grid/VsyncCheck","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/Frame/Column","node_type":"HBoxContainer","node_name":"Actions"},
      {"type":"configure_control","node_path":"root/Frame/Column/Actions","theme_overrides":{"constants":{"separation":12}}},
      {"type":"add_node","parent_node_path":"root/Frame/Column/Actions","node_type":"Button","node_name":"BackButton",
       "properties":{"text":"Back"}},
      {"type":"configure_control","node_path":"root/Frame/Column/Actions/BackButton","size_flags_horizontal":"EXPAND_FILL"},
      {"type":"configure_node","node_path":"root/Frame/Column/Actions/BackButton","unique_name_in_owner":true},

      {"type":"attach_script","node_path":"root","script_path":"scripts/settings_menu.gd",
       "script_properties":{"return_scene":"","save_on_change":true}}
    ]
  }'
```

The two switches carry `ON`/`OFF` text that the script keeps in sync. A
`CheckButton` with an empty label is invisible to `dump_tree` and `ui_report`,
and `check_project` reports it as a `label_without_text` hint.

`return_scene` empty means Back hides the panel and emits `closed` — the pause
menu shape. Point it at `res://scenes/main_menu.tscn` (and set `settings_scene`
on `main_menu.gd`, playbook 6) to make it a screen of its own.

### Step 4 — The rebinding screen

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/input_remap.tscn",
    "create_if_missing": true,
    "root_node_type": "Control",
    "root_node_name": "InputRemap",
    "actions": [
      {"type":"configure_control","node_path":"root","layout_preset":"FULL_RECT"},

      {"type":"add_node","parent_node_path":"root","node_type":"MarginContainer","node_name":"Frame"},
      {"type":"configure_control","node_path":"root/Frame","layout_preset":"FULL_RECT",
       "theme_overrides":{"constants":{"margin_left":64,"margin_right":64,"margin_top":48,"margin_bottom":48}}},

      {"type":"add_node","parent_node_path":"root/Frame","node_type":"VBoxContainer","node_name":"Column"},
      {"type":"configure_control","node_path":"root/Frame/Column","theme_overrides":{"constants":{"separation":14}}},

      {"type":"add_node","parent_node_path":"root/Frame/Column","node_type":"Label","node_name":"Title",
       "properties":{"text":"CONTROLS","horizontal_alignment":1}},
      {"type":"add_node","parent_node_path":"root/Frame/Column","node_type":"Label","node_name":"StatusLabel",
       "properties":{"text":"Pick a row, then press the key you want.","horizontal_alignment":1}},
      {"type":"configure_node","node_path":"root/Frame/Column/StatusLabel","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/Frame/Column","node_type":"VBoxContainer","node_name":"ActionList"},
      {"type":"configure_control","node_path":"root/Frame/Column/ActionList","size_flags_vertical":"EXPAND_FILL",
       "theme_overrides":{"constants":{"separation":8}}},
      {"type":"configure_node","node_path":"root/Frame/Column/ActionList","unique_name_in_owner":true},

      {"type":"add_node","parent_node_path":"root/Frame/Column","node_type":"HBoxContainer","node_name":"Actions"},
      {"type":"configure_control","node_path":"root/Frame/Column/Actions","theme_overrides":{"constants":{"separation":12}}},
      {"type":"add_node","parent_node_path":"root/Frame/Column/Actions","node_type":"Button","node_name":"ResetButton",
       "properties":{"text":"Reset To Defaults"}},
      {"type":"configure_control","node_path":"root/Frame/Column/Actions/ResetButton","size_flags_horizontal":"EXPAND_FILL"},
      {"type":"configure_node","node_path":"root/Frame/Column/Actions/ResetButton","unique_name_in_owner":true},
      {"type":"add_node","parent_node_path":"root/Frame/Column/Actions","node_type":"Button","node_name":"BackButton",
       "properties":{"text":"Back"}},
      {"type":"configure_control","node_path":"root/Frame/Column/Actions/BackButton","size_flags_horizontal":"EXPAND_FILL"},
      {"type":"configure_node","node_path":"root/Frame/Column/Actions/BackButton","unique_name_in_owner":true},

      {"type":"attach_script","node_path":"root","script_path":"scripts/input_remap.gd",
       "script_properties":{"actions":["move_left","move_right","jump","interact"],"steal_on_conflict":true}}
    ]
  }'
```

One `Row_<action>` per listed action is built at runtime, each holding
`Name_<action>` and `Bind_<action>` — those are the node paths a scenario
asserts on.

### Verify

Write the settings from one process, then read them back in another. Step 1 of
the check resets first, so the numbers below are reproducible on a project that
already has a `settings.cfg`:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"code":"Settings.reset_to_defaults()\nSettings.set_music_volume(0.25)\nvar ok: bool = Settings.save()\nreturn {\"saved\": ok, \"file\": ProjectSettings.globalize_path(\"user://settings.cfg\")}"}'
```

```bash
mkdir -p /absolute/path/to/project/scenarios
cat > /absolute/path/to/project/scenarios/settings_720.json <<'JSON'
{
  "scene_path": "res://scenes/settings_menu.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "settle_frames": 4,
  "steps": [
    {"type": "assert", "assertion": "property", "node_path": "Frame/Column/Grid/MusicSlider", "property": "value", "expected": 25.0},
    {"type": "key", "keycode": 4194319, "pressed": true},
    {"type": "key", "keycode": 4194319, "pressed": false},
    {"type": "key", "keycode": 4194319, "pressed": true},
    {"type": "key", "keycode": 4194319, "pressed": false},
    {"type": "wait_frames", "frames": 2},
    {"type": "key", "keycode": 4194322, "pressed": true},
    {"type": "key", "keycode": 4194322, "pressed": false},
    {"type": "key", "keycode": 4194322, "pressed": true},
    {"type": "key", "keycode": 4194322, "pressed": false},
    {"type": "key", "keycode": 4194322, "pressed": true},
    {"type": "key", "keycode": 4194322, "pressed": false},
    {"type": "wait_frames", "frames": 2},
    {"type": "key", "keycode": 4194309, "pressed": true},
    {"type": "key", "keycode": 4194309, "pressed": false},
    {"type": "wait_frames", "frames": 4},
    {"type": "assert", "assertion": "property", "node_path": "Frame/Column/Grid/MasterSlider", "property": "value", "expected": 98.0},
    {"type": "assert", "assertion": "property", "node_path": "Frame/Column/Grid/FullscreenCheck", "property": "button_pressed", "expected": true},
    {"type": "dump_tree", "node_path": "Frame/Column/Grid", "properties": ["value", "button_pressed"], "max_depth": 3, "label": "widgets"},
    {"type": "ui_report", "label": "options-720", "ascii": true, "fail_on": ["any"]}
  ]
}
JSON
cat > /absolute/path/to/project/scenarios/settings_360.json <<'JSON'
{
  "scene_path": "res://scenes/settings_menu.tscn",
  "viewport_size": {"width": 640, "height": 360},
  "settle_frames": 4,
  "steps": [
    {"type": "ui_report", "label": "options-360", "ascii": true, "fail_on": ["any"]}
  ]
}
JSON
cat > /absolute/path/to/project/scenarios/remap.json <<'JSON'
{
  "scene_path": "res://scenes/input_remap.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "settle_frames": 4,
  "steps": [
    {"type": "dump_tree", "node_path": "Frame/Column/ActionList", "properties": ["text"], "max_depth": 4, "label": "bindings-before"},
    {"type": "key", "keycode": 4194322, "pressed": true},
    {"type": "key", "keycode": 4194322, "pressed": false},
    {"type": "key", "keycode": 4194322, "pressed": true},
    {"type": "key", "keycode": 4194322, "pressed": false},
    {"type": "wait_frames", "frames": 2},
    {"type": "key", "keycode": 4194309, "pressed": true},
    {"type": "key", "keycode": 4194309, "pressed": false},
    {"type": "wait_frames", "frames": 2},
    {"type": "key", "keycode": 75, "pressed": true},
    {"type": "key", "keycode": 75, "pressed": false},
    {"type": "wait_frames", "frames": 4},
    {"type": "assert", "assertion": "property", "node_path": "Frame/Column/ActionList/Row_jump/Bind_jump",
     "property": "text", "expected": "K"},
    {"type": "key", "keycode": 4194322, "pressed": true},
    {"type": "key", "keycode": 4194322, "pressed": false},
    {"type": "wait_frames", "frames": 2},
    {"type": "key", "keycode": 4194309, "pressed": true},
    {"type": "key", "keycode": 4194309, "pressed": false},
    {"type": "wait_frames", "frames": 2},
    {"type": "key", "keycode": 75, "pressed": true},
    {"type": "key", "keycode": 75, "pressed": false},
    {"type": "wait_frames", "frames": 4},
    {"type": "assert", "assertion": "property", "node_path": "Frame/Column/ActionList/Row_interact/Bind_interact",
     "property": "text", "expected": "K"},
    {"type": "assert", "assertion": "property", "node_path": "Frame/Column/ActionList/Row_jump/Bind_jump",
     "property": "text", "expected": "unbound"},
    {"type": "assert", "assertion": "property", "node_path": "Frame/Column/StatusLabel",
     "property": "text", "expected": "interact -> K (taken from jump)"},
    {"type": "dump_tree", "node_path": "Frame/Column/ActionList", "properties": ["text"], "max_depth": 4, "label": "bindings-after"},
    {"type": "ui_report", "label": "remap", "fail_on": ["any"]}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenarios/settings_720.json --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenarios/settings_360.json --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenarios/remap.json --pretty
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"code":"var m: int = AudioServer.get_bus_index(\"Master\")\nvar u: int = AudioServer.get_bus_index(\"Music\")\nvar e: Array[InputEvent] = InputMap.action_get_events(\"interact\")\nreturn {\"master\": Settings.master_volume, \"music\": Settings.music_volume, \"fullscreen\": Settings.fullscreen, \"master_db\": snappedf(AudioServer.get_bus_volume_db(m), 0.001), \"music_db\": snappedf(AudioServer.get_bus_volume_db(u), 0.001), \"interact\": e[0].as_text() if e.size() > 0 else \"unbound\", \"jump_events\": InputMap.action_get_events(\"jump\").size()}"}'
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
```

Expected, in order:

- the first `run_gdscript` prints `"saved": true` and the absolute path of
  `settings.cfg`;
- `settings_720.json` `"ok": true`: the Music slider **boots at 25**, which only
  happens if `Settings` read the file at startup; two `ui_left` presses move
  Master to 98 and `ui_down` ×3 then `ui_accept` flips Fullscreen on;
  `options-720` `findings=0`;
- `settings_360.json` `findings=0` as well — the same screen at 640×360;
- `remap.json` `"ok": true`: `jump` becomes `K`, then binding `interact` to `K`
  steals it, leaving `Bind_jump` reading `unbound` and the status line reading
  `interact -> K (taken from jump)`;
- the last `run_gdscript`, a **separate process**, answers

```json
{"master": 0.98, "music": 0.25, "fullscreen": true,
 "master_db": -0.175, "music_db": -12.041,
 "interact": "K", "jump_events": 0}
```

  which is the whole point: the menu wrote the file, the next launch read it,
  and the *bus volume actually moved* (`linear_to_db(0.25)` is −12.04 dB).
  `validate_project.py` reports `"ok": true` with zero warnings and zero
  configuration warnings.

`DisplayServer` is a no-op under `--headless`, so `window_get_mode()` cannot
confirm fullscreen there — check `Settings.fullscreen` and the `.cfg`, as above.
A volume of 0 mutes its bus instead of writing `-inf` dB, which is what
`linear_to_db(0.0)` returns and what would otherwise end up in the file.

---

<!-- WP10A-END -->

<!-- WP10B-BEGIN: playbooks 18-22 -->

## 18. Collectathon Platformer (A Complete Loop)

**Goal.** One command at a time, from an empty folder to a level that can be
*won*: drawn art, a synthesized coin and jump sound, a looping music track, a
painted tile level, a player, three coins, a checkpoint, a moving platform that
carries the player across a pit, a kill zone that respawns, a goal that only
opens once the coins are gone, and a HUD that shows the score.

**Requires.** Nothing — this playbook creates its own project.

It does not depend on Playbook 1: it *is* Playbook 1 plus a game. Every block
below was run in this order on `godot 4.7.stable`.

### Step 1 — Create the project

```bash
mkdir -p /absolute/path/to/project/scenes \
         /absolute/path/to/project/scripts \
         /absolute/path/to/project/art \
         /absolute/path/to/project/audio \
         /absolute/path/to/project/tilesets
cat > /absolute/path/to/project/project.godot <<'GODOT'
config_version=5

[application]

config/name="Collectathon"
GODOT
```

`config_version=5` and an `[application]` section are the whole minimum. Never
hand-edit this file again after this point: `ProjectSettings.save()` rewrites it
and drops anything the engine did not put there.

### Step 2 — Settings, physics layers and input actions

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"set_setting","name":"display/window/size/viewport_width","value":320},
      {"type":"set_setting","name":"display/window/size/viewport_height","value":180},
      {"type":"set_setting","name":"display/window/size/window_width_override","value":1280},
      {"type":"set_setting","name":"display/window/size/window_height_override","value":720},
      {"type":"set_setting","name":"display/window/stretch/mode","value":"canvas_items"},
      {"type":"set_setting","name":"rendering/textures/canvas_textures/default_texture_filter","value":0},
      {"type":"set_layer_name","layer_type":"2d_physics","layer":1,"layer_name":"world"},
      {"type":"set_layer_name","layer_type":"2d_physics","layer":2,"layer_name":"player"},
      {"type":"set_layer_name","layer_type":"2d_physics","layer":3,"layer_name":"pickup"},
      {"type":"add_input_action","action_name":"move_left","replace":true},
      {"type":"add_input_event","action_name":"move_left","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":65}}},
      {"type":"add_input_action","action_name":"move_right","replace":true},
      {"type":"add_input_event","action_name":"move_right","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":68}}},
      {"type":"add_input_action","action_name":"jump","replace":true},
      {"type":"add_input_event","action_name":"jump","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":32}}}
    ]
  }'
```

Naming the layers costs three lines and makes the physics-layer survey in the
Verify block readable (`world` / `player` / `pickup` instead of bits 1/2/3).

### Step 3 — Draw the art

Five files, all as text. `references/pixel_art.md` has the authoring rules; the
point here is that `frame_reports[*].rows` comes back as the PNG read one
character per pixel, so you can check the sprite without seeing it.

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/hero.png",
    "palette": {"g":"#2e6e4e","s":"#ffccaa","o":"#0a0a12","t":"#3e8948","p":"#3b5dc9","b":"#663931"},
    "mirror_x": true,
    "outline": "#0a0a12",
    "rows": [
      "........",
      "....gggg",
      "...ggggg",
      "...sssss",
      "..sossss",
      "...sssss",
      "....ssss",
      "...ttttt",
      "..tttttt",
      ".ttttttt",
      "...ttttt",
      "...ppppp",
      "...ppppp",
      "...pp...",
      "..bbb...",
      "........"
    ]
  }'
```

Eight authored columns, `mirror_x` makes it 16 wide, `outline` wraps it. The
read-back is exactly:

```
...oooooooooo...
..ooggggggggoo..
..oggggggggggo..
.oossssssssssoo.
.osossssssssoso.
.oossssssssssoo.
..oossssssssoo..
.oottttttttttoo.
oottttttttttttoo
otttttttttttttto
ooottttttttttooo
..oppppppppppo..
..oppppppppppo..
.ooppooooooppoo.
.obbbo....obbbo.
.ooooo....ooooo.
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/coin.png",
    "palette": {"c":"#ffb02e","h":"#ffe478"},
    "outline": "#2b1700",
    "rows": [
      "........",
      "..cccc..",
      ".cchhcc.",
      ".chhhhc.",
      ".chhhhc.",
      ".cchhcc.",
      "..cccc..",
      "........"
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/tiles.png",
    "width": 16, "height": 16,
    "tile_check": true,
    "read_back": false,
    "frames": [
      {"name":"grass","shapes":[
        {"type":"rect","color":"#3e8948"},
        {"type":"rect","y":0,"height":4,"color":"#63c74d"},
        {"type":"noise","colors":["#265c42"],"seed":5,"density":0.18}]},
      {"name":"dirt","shapes":[
        {"type":"rect","color":"#8f563b"},
        {"type":"noise","colors":["#663931","#d9a066"],"seed":11,"density":0.22}]},
      {"name":"stone","shapes":[
        {"type":"rect","color":"#8b9bb4"},
        {"type":"checker","colors":["#8b9bb4","#5a6988"],"cell":8},
        {"type":"noise","colors":["#c0cbdc"],"seed":3,"density":0.08}]}
    ]
  }'
```

Three frames become one 48x16 atlas, so the atlas coordinates a `build_tileset`
needs are the frame order: grass `{"x":0,"y":0}`, dirt `{"x":1,"y":0}`, stone
`{"x":2,"y":0}`. `tile_check` answers `"seamless": true` for all three.

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/platform.png",
    "width": 32, "height": 8,
    "shapes": [
      {"type":"rect","color":"#8b9bb4"},
      {"type":"rect","y":0,"height":2,"color":"#c0cbdc"},
      {"type":"rect_outline","color":"#3a4466","thickness":1}
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/flag.png",
    "palette": {"p":"#c0cbdc","f":"#e43b44","h":"#ff8a4c"},
    "outline": "#2b1700",
    "rows": [
      "................",
      "..p.............",
      "..pffffffff.....",
      "..pffhhhhff.....",
      "..pffhhhhff.....",
      "..pffffffff.....",
      "..p.............",
      "..p.............",
      "..p.............",
      "..p.............",
      "..p.............",
      "..p.............",
      "..p.............",
      "..ppp...........",
      "................",
      "................"
    ]
  }'
```

One flag texture serves both the checkpoint (tinted blue with `modulate`) and
the goal.

### Step 4 — Synthesize the sound

```bash
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset jump --seed 3 --out /absolute/path/to/project/audio/
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset coin --seed 5 --out /absolute/path/to/project/audio/
python3 /absolute/path/to/godot/scripts/assets/make_music.py --preset overworld --bars 4 --out /absolute/path/to/project/audio/
```

Then read the three files back before anything points at them. They have no
`.import` sidecar yet; `inspect_audio` reads the raw bytes anyway:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_audio '{"audio_paths":["audio"],"format":"text","envelope_columns":32,
                  "expect":{"not_silent":true,"no_clipping":true}}'
```

Expected: `jump.wav` 0.17 s rising, `coin.wav` 0.41 s, `overworld.wav` 7.74 s
with `loop_seam_delta: 0.0`, and every `expect.*` line `PASS`.

### Step 5 — Import, and make the music loop

```bash
python3 /absolute/path/to/godot/scripts/import/import_project.py /absolute/path/to/project --pretty
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  set_import_options '{"file_path":"audio/overworld.wav","options":{"edit/loop_mode":2}}'
godot --headless --path /absolute/path/to/project --import
```

`edit/loop_mode` 2 is *Forward* — the importer enum is offset by one from
`AudioStreamWAV.LoopMode` (`references/audio.md` has the table). Without this the
track plays once and the level goes silent.

### Step 6 — Copy the templates, create the buses, register the autoloads

```bash
cp /absolute/path/to/godot/templates/gdscript/game_manager.gd \
   /absolute/path/to/godot/templates/gdscript/audio_manager.gd \
   /absolute/path/to/godot/templates/gdscript/health.gd \
   /absolute/path/to/godot/templates/gdscript/hud.gd \
   /absolute/path/to/godot/templates/gdscript/player_platformer_2d.gd \
   /absolute/path/to/godot/templates/gdscript/camera_shake_2d.gd \
   /absolute/path/to/godot/templates/gdscript/collectible.gd \
   /absolute/path/to/godot/templates/gdscript/checkpoint.gd \
   /absolute/path/to/godot/templates/gdscript/kill_zone.gd \
   /absolute/path/to/godot/templates/gdscript/goal.gd \
   /absolute/path/to/godot/templates/gdscript/moving_platform.gd \
   /absolute/path/to/project/scripts/
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  setup_audio_buses '{
    "buses":[{"name":"Master","volume_db":0.0},
             {"name":"Music","send":"Master","volume_db":-6.0},
             {"name":"SFX","send":"Master","volume_db":-3.0}],
    "save_path":"audio/default_bus_layout.tres","set_project_setting":true}'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"add_autoload","autoload_name":"GameManager","path":"res://scripts/game_manager.gd","singleton":true},
      {"type":"add_autoload","autoload_name":"AudioManager","path":"res://scripts/audio_manager.gd","singleton":true}
    ]}'
godot --headless --path /absolute/path/to/project --import
```

Buses **before** the `AudioManager` autoload, or every player it builds falls
back to Master and pushes a warning. The `--import` at the end rebuilds the
global class cache so `health.gd`s `class_name Health` resolves in the next step.

### Step 7 — Tileset and player

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  build_tileset '{
    "resource_path": "tilesets/world.tres",
    "tile_size": {"x": 16, "y": 16},
    "physics_layers": [{"collision_layer": 1, "collision_mask": 0}],
    "sources": [
      {"source_id": 0, "texture": "art/tiles.png", "tiles": "all",
       "tile_defaults": {"collision": "full_cell"}}
    ]
  }'
```

`"collision_mask": 0` on the tileset physics layer is deliberate: a tile floor
occupies layer 1, it never *scans* for anything.

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/player.tscn",
    "create_if_missing": true,
    "root_node_type": "CharacterBody2D",
    "root_node_name": "Player",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":2,"collision_mask":1},"groups_add":["player"]},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CapsuleShape2D","properties":{"radius":5.0,"height":16.0}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/hero.png"}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Camera2D","node_name":"Camera2D",
       "properties":{"position_smoothing_enabled":true,"position_smoothing_speed":8.0}},
      {"type":"add_node","parent_node_path":"root","node_type":"Node","node_name":"Health"},
      {"type":"attach_script","node_path":"root/Health","script_path":"scripts/health.gd",
       "script_properties":{"max_health":3,"invulnerability_time":0.6}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/player_platformer_2d.gd",
       "script_properties":{"speed":110.0,"jump_velocity":-260.0,"coyote_time":0.12,"jump_buffer_time":0.12}},
      {"type":"attach_script","node_path":"root/Camera2D","script_path":"scripts/camera_shake_2d.gd",
       "script_properties":{"decay":4.0,"max_offset":{"__type":"Vector2","x":6,"y":4}}}
    ]
  }'
```

### Step 8 — The coin, and the HUD

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/coin.tscn",
    "create_if_missing": true,
    "root_node_type": "Area2D",
    "root_node_name": "Coin",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":4,"collision_mask":2}},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CircleShape2D","properties":{"radius":5.0}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/coin.png"}}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/collectible.gd",
       "script_properties":{"value":10,"collector_group":{"__type":"StringName","value":"player"},
                            "sound":{"__resource":"res://audio/coin.wav"}}}
    ]
  }'
```

A pickup sits on its own layer (3, `pickup`) and **scans** the player layer (2).
Get that pair backwards and `body_entered` never fires, with no error anywhere.

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/hud.tscn",
    "create_if_missing": true,
    "root_node_type": "CanvasLayer",
    "root_node_name": "HUD",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"layer":1}},
      {"type":"add_node","parent_node_path":"root","node_type":"MarginContainer","node_name":"TopLeft","properties":{"mouse_filter":2}},
      {"type":"configure_control","node_path":"root/TopLeft","layout_preset":"TOP_LEFT",
       "theme_overrides":{"constants":{"margin_left":8,"margin_top":6,"margin_right":0,"margin_bottom":0}}},
      {"type":"add_node","parent_node_path":"root/TopLeft","node_type":"VBoxContainer","node_name":"Vitals","properties":{"mouse_filter":2}},
      {"type":"add_node","parent_node_path":"root/TopLeft/Vitals","node_type":"ProgressBar","node_name":"HealthBar",
       "properties":{"max_value":3,"value":3,"show_percentage":false}},
      {"type":"configure_control","node_path":"root/TopLeft/Vitals/HealthBar","custom_minimum_size":{"__type":"Vector2","x":96,"y":8}},
      {"type":"add_node","parent_node_path":"root/TopLeft/Vitals","node_type":"Label","node_name":"LivesLabel","properties":{"text":"LIVES 3"}},
      {"type":"add_node","parent_node_path":"root","node_type":"MarginContainer","node_name":"TopRight",
       "properties":{"mouse_filter":2,"grow_horizontal":0,"grow_vertical":1}},
      {"type":"configure_control","node_path":"root/TopRight","layout_preset":"TOP_RIGHT",
       "theme_overrides":{"constants":{"margin_right":8,"margin_top":6,"margin_left":0,"margin_bottom":0}}},
      {"type":"add_node","parent_node_path":"root/TopRight","node_type":"Label","node_name":"ScoreLabel","properties":{"text":"SCORE 000000"}},
      {"type":"configure_node","node_path":"root/TopLeft/Vitals/HealthBar","unique_name_in_owner":true},
      {"type":"configure_node","node_path":"root/TopLeft/Vitals/LivesLabel","unique_name_in_owner":true},
      {"type":"configure_node","node_path":"root/TopRight/ScoreLabel","unique_name_in_owner":true},
      {"type":"attach_script","node_path":"root","script_path":"scripts/hud.gd"}
    ]
  }'
```

### Step 9 — The level script

```bash
cat > /absolute/path/to/project/scripts/level_1.gd <<'GDSCRIPT'
extends Node2D

const MUSIC: AudioStream = preload("res://audio/overworld.wav")

@onready var _player: CharacterBody2D = $Player
@onready var _hud: CanvasLayer = $HUD
@onready var _goal: Area2D = $Goal


func _ready() -> void:
	var health := _player.get_node_or_null(^"Health") as Health
	if health != null:
		_hud.call(&"bind_health", health)
	GameManager.score_changed.connect(_on_score_changed)
	_goal.connect(&"reached", _on_goal_reached)
	_goal.connect(&"locked", _on_goal_locked)
	AudioManager.play_music(MUSIC)
	print("[LEVEL] ready coins=%d" % get_tree().get_nodes_in_group(&"collectible").size())


func _on_score_changed(score: int) -> void:
	print("[LEVEL] score=%d" % score)


func _on_goal_reached(_by: Node2D) -> void:
	print("[LEVEL] level-complete score=%d" % GameManager.score)


func _on_goal_locked(remaining: int) -> void:
	print("[LEVEL] goal locked, %d coins left" % remaining)
GDSCRIPT
```

`hud.gd` never searches for a Health node, so the level hands it one. Everything
else is a `print` per decision that matters — that is what turns the run log into
something `log_assertions` can gate on.

### Step 10 — Assemble the level

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level_1.tscn",
    "create_if_missing": true,
    "root_node_type": "Node2D",
    "root_node_name": "Level",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"TileMapLayer","node_name":"Ground",
       "properties":{"tile_set":{"__resource":"res://tilesets/world.tres"}}},

      {"type":"add_node","parent_node_path":"root","node_type":"AnimatableBody2D","node_name":"Platform",
       "properties":{"position":{"__type":"Vector2","x":128,"y":132},"collision_layer":1,"collision_mask":0}},
      {"type":"add_node","parent_node_path":"root/Platform","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":32,"y":8}}}}},
      {"type":"add_node","parent_node_path":"root/Platform","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/platform.png"}}},
      {"type":"attach_script","node_path":"root/Platform","script_path":"scripts/moving_platform.gd",
       "script_properties":{"speed":24.0,"wait_time":1.5,"ping_pong":true,
         "points":[{"__type":"Vector2","x":0,"y":0},{"__type":"Vector2","x":32,"y":0}]}},

      {"type":"add_node","parent_node_path":"root","node_type":"Area2D","node_name":"KillZone",
       "properties":{"position":{"__type":"Vector2","x":192,"y":216},"collision_layer":0,"collision_mask":2}},
      {"type":"add_node","parent_node_path":"root/KillZone","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":480,"y":32}}}}},
      {"type":"attach_script","node_path":"root/KillZone","script_path":"scripts/kill_zone.gd",
       "script_properties":{"damage":1,"costs_a_life":true,"respawns":true}},

      {"type":"add_node","parent_node_path":"root","node_type":"Area2D","node_name":"Checkpoint",
       "properties":{"position":{"__type":"Vector2","x":232,"y":120},"collision_layer":0,"collision_mask":2}},
      {"type":"add_node","parent_node_path":"root/Checkpoint","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":12,"y":16}}}}},
      {"type":"add_node","parent_node_path":"root/Checkpoint","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/flag.png"},"modulate":{"__type":"Color","r":0.55,"g":0.8,"b":1.0,"a":1.0}}},
      {"type":"add_node","parent_node_path":"root/Checkpoint","node_type":"Marker2D","node_name":"Respawn",
       "properties":{"position":{"__type":"Vector2","x":0,"y":-8}}},
      {"type":"attach_script","node_path":"root/Checkpoint","script_path":"scripts/checkpoint.gd",
       "script_properties":{"marker_path":{"__type":"NodePath","value":"Respawn"}}},

      {"type":"add_node","parent_node_path":"root","node_type":"Area2D","node_name":"Goal",
       "properties":{"position":{"__type":"Vector2","x":360,"y":120},"collision_layer":0,"collision_mask":2}},
      {"type":"add_node","parent_node_path":"root/Goal","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":12,"y":16}}}}},
      {"type":"add_node","parent_node_path":"root/Goal","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/flag.png"}}},
      {"type":"attach_script","node_path":"root/Goal","script_path":"scripts/goal.gd",
       "script_properties":{"required_group":{"__type":"StringName","value":"collectible"},"next_scene_path":""}},

      {"type":"add_node","parent_node_path":"root","node_type":"Node2D","node_name":"Coins"},
      {"type":"instantiate_scene","parent_node_path":"root/Coins","instance_scene_path":"scenes/coin.tscn","node_name":"Coin1",
       "properties":{"position":{"__type":"Vector2","x":72,"y":120}}},
      {"type":"instantiate_scene","parent_node_path":"root/Coins","instance_scene_path":"scenes/coin.tscn","node_name":"Coin2",
       "properties":{"position":{"__type":"Vector2","x":200,"y":120}}},
      {"type":"instantiate_scene","parent_node_path":"root/Coins","instance_scene_path":"scenes/coin.tscn","node_name":"Coin3",
       "properties":{"position":{"__type":"Vector2","x":272,"y":120}}},

      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/player.tscn","node_name":"Player",
       "properties":{"position":{"__type":"Vector2","x":40,"y":100}}},
      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/hud.tscn","node_name":"HUD"},
      {"type":"attach_script","node_path":"root","script_path":"scripts/level_1.gd"}
    ]
  }'
```

The platform is the bridge, not decoration: the pit is four cells (64 px) wide
and the player jumps 67 px, which is less than the 72 px it would need to clear
it. Make the gap two cells and the platform becomes optional; make it five and
the level is unwinnable. The platform sits at `y = 132` with a 8 px tall shape,
so its top edge is exactly the tile floor height (128) and the player walks on
and off without a step.

### Step 11 — Paint the level and point the project at it

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  paint_tilemap '{
    "scene_path": "scenes/level_1.tscn",
    "node_path": "root/Ground",
    "tile_set": "tilesets/world.tres",
    "clear": true,
    "ascii_map": {
      "origin": {"x": 0, "y": 0},
      "legend": {
        "g": {"source_id": 0, "atlas_coords": {"x": 0, "y": 0}},
        "d": {"source_id": 0, "atlas_coords": {"x": 1, "y": 0}},
        ".": null
      },
      "rows": [
        "........................",
        "........................",
        "........................",
        "........................",
        "........................",
        "........................",
        "........................",
        "........................",
        "ggggggg....ggggggggggggg",
        "ddddddd....ddddddddddddd",
        "ddddddd....ddddddddddddd"
      ]
    }
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{"actions":[{"type":"set_main_scene","scene_path":"res://scenes/level_1.tscn"}]}'
```

### Verify

Write the scenario. It plays the level the way a player would: walk, take a
coin, wait for the platform, ride it across the pit, take the rest, fall in the
pit on purpose to prove the kill zone and the checkpoint, then reach the goal.

```bash
cat > /absolute/path/to/project/scenario_collectathon.json <<'JSON'
{
  "scene_path": "res://scenes/level_1.tscn",
  "viewport_size": {"width": 320, "height": 180},
  "settle_frames": 4,
  "steps": [
    {"type": "wait_seconds", "seconds": 0.5},
    {"type": "spatial_report", "label": "boot", "ascii": true, "ascii_size": {"cols": 56, "rows": 14},
     "expect_on_screen": ["Player", "Coins/Coin1"],
     "fail_on": ["not_on_screen", "embedded_in_static"]},

    {"type": "action", "action_name": "move_right", "pressed": true},
    {"type": "wait_until", "node_path": "/root/GameManager", "property": "score", "expected": 10,
     "operator": "greater_or_equal", "timeout_seconds": 5},
    {"type": "assert", "assertion": "property", "node_path": "/root/GameManager", "property": "score", "expected": 10},
    {"type": "log_marker", "message": "coin-1-taken"},

    {"type": "wait_until", "node_path": "Player", "property": "position:x", "expected": 100.0,
     "operator": "greater_than", "timeout_seconds": 5},
    {"type": "action", "action_name": "move_right", "pressed": false},
    {"type": "wait_until", "node_path": "Platform", "property": "position:x", "expected": 130.0,
     "operator": "less_or_equal", "timeout_seconds": 8},
    {"type": "action", "action_name": "move_right", "pressed": true},
    {"type": "wait_until", "node_path": "Player", "property": "position:x", "expected": 124.0,
     "operator": "greater_than", "timeout_seconds": 5},
    {"type": "action", "action_name": "move_right", "pressed": false},
    {"type": "log_marker", "message": "aboard"},

    {"type": "wait_until", "node_path": "Platform", "property": "position:x", "expected": 158.0,
     "operator": "greater_or_equal", "timeout_seconds": 8},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "position:x",
     "expected": 148.0, "operator": "greater_than"},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "position:y",
     "expected": 122.0, "operator": "less_or_equal"},
    {"type": "log_marker", "message": "carried-across"},

    {"type": "action", "action_name": "move_right", "pressed": true},
    {"type": "wait_until", "node_path": "/root/GameManager", "property": "score", "expected": 30,
     "operator": "greater_or_equal", "timeout_seconds": 8},
    {"type": "action", "action_name": "move_right", "pressed": false},
    {"type": "assert", "assertion": "property", "node_path": "HUD/TopRight/ScoreLabel", "property": "text",
     "expected": "SCORE 000030"},
    {"type": "assert", "assertion": "property", "node_path": "Checkpoint", "property": "active", "expected": true},
    {"type": "log_marker", "message": "all-coins"},

    {"type": "set_property", "node_path": "Player", "property": "position", "value": {"__type": "Vector2", "x": 144, "y": 185}},
    {"type": "wait_seconds", "seconds": 2.0},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "position:x",
     "expected": 232.0, "operator": "approx", "tolerance": 6.0},
    {"type": "assert", "assertion": "property", "node_path": "/root/GameManager", "property": "lives", "expected": 2},
    {"type": "log_marker", "message": "respawned-at-checkpoint"},

    {"type": "action", "action_name": "move_right", "pressed": true},
    {"type": "wait_until", "node_path": "Player", "property": "position:x", "expected": 356.0,
     "operator": "greater_than", "timeout_seconds": 8},
    {"type": "action", "action_name": "move_right", "pressed": false},
    {"type": "wait_seconds", "seconds": 0.4},

    {"type": "spatial_report", "label": "goal", "ascii": true, "ascii_size": {"cols": 56, "rows": 14},
     "expect_on_screen": ["Player", "Goal"],
     "fail_on": ["not_on_screen", "embedded_in_static"]}
  ],
  "assertions": [
    {"assertion": "node_exists", "node_path": "Goal"},
    {"assertion": "node_exists", "node_path": "HUD/TopLeft/Vitals/HealthBar"}
  ],
  "log_assertions": [
    {"contains": "[LEVEL] ready coins=3", "min_count": 1},
    {"contains": "level-complete", "min_count": 1}
  ]
}
JSON
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_tilemap '{"scene_path":"scenes/level_1.tscn","node_path":"root/Ground","format":"text"}'

python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --warnings-as-errors --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_collectathon.json --log-file /tmp/collectathon.log --pretty
```

Expected:

- `inspect_tilemap` prints the level back, the gap in the same place the ASCII
  put it:

  ```
  #######....#############
  @@@@@@@....@@@@@@@@@@@@@
  @@@@@@@....@@@@@@@@@@@@@
  ```

- `lint_project.py` `"ok": true`, `counts.errors == 0`.
- `validate_project.py` `"ok": true` with `counts.errors == 0` **and**
  `counts.warnings == 0` under `--warnings-as-errors`; `check_project` reports
  `config_warning_count: 0`. The physics-layer survey carries one
  `layer_never_scanned` hint for the `pickup` layer — nothing scans it because
  the coins are the detectors, which is information, not a defect.
- `run_scenario.py` `"ok": true`, 9 assertions passed, both `spatial_report`s
  `findings=0`, and both `log_assertions` matched. The log reads:

  ```
  [LEVEL] ready coins=3
  [LEVEL] score=10
  [SCENARIO] coin-1-taken
  [SCENARIO] aboard
  [SCENARIO] carried-across
  [LEVEL] score=20
  [LEVEL] score=30
  [SCENARIO] all-coins
  [SCENARIO] respawned-at-checkpoint
  [LEVEL] level-complete score=30
  ```

  `carried-across` is the moving-platform proof: between `aboard` and that
  marker the scenario presses nothing, and the player still moves 30 px to the
  right, because `sync_to_physics` on the `AnimatableBody2D` carries it.

Two things worth knowing before you extend this level:

- **A looping music track that is still playing when the engine quits** makes
  Godot print `1 resources still in use at exit` on the way out. That is engine
  exit bookkeeping, not a bug in the scene: `run_project.py` and
  `smoke_scenes.py` list it as severity `info`, category `exit_leak`, and it
  never counts as an error or flips `ok` (`references/audio.md` explains it and
  how to silence it).
- **`expect_on_screen` needs a node that draws something.** A bare `Node2D`
  parent has no rect of its own; name the `Sprite2D`, the `CollisionShape2D` or
  the body, the way the block above names `Coins/Coin1`.

---

## 19. Top-Down Wave Shooter

**Goal.** An arena with a baked navigation mesh, a player that shoots pooled
bullets, chasers that walk *around* the pillar instead of into it, waves that
advance when the last enemy dies, floating damage numbers and a camera that
shakes on a kill.

**Requires.** Nothing — this playbook creates its own project. Every block was
run in this order on `godot 4.7.stable`.

### Step 1 — Project, layers, input

```bash
mkdir -p /absolute/path/to/project/scenes \
         /absolute/path/to/project/scripts \
         /absolute/path/to/project/art \
         /absolute/path/to/project/audio \
         /absolute/path/to/project/nav
cat > /absolute/path/to/project/project.godot <<'GODOT'
config_version=5

[application]

config/name="WaveShooter"
GODOT
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"set_setting","name":"display/window/size/viewport_width","value":320},
      {"type":"set_setting","name":"display/window/size/viewport_height","value":180},
      {"type":"set_setting","name":"display/window/stretch/mode","value":"canvas_items"},
      {"type":"set_setting","name":"rendering/textures/canvas_textures/default_texture_filter","value":0},
      {"type":"set_layer_name","layer_type":"2d_physics","layer":1,"layer_name":"world"},
      {"type":"set_layer_name","layer_type":"2d_physics","layer":2,"layer_name":"player"},
      {"type":"set_layer_name","layer_type":"2d_physics","layer":3,"layer_name":"enemy"},
      {"type":"set_layer_name","layer_type":"2d_physics","layer":4,"layer_name":"damage"},
      {"type":"add_input_action","action_name":"move_left","replace":true},
      {"type":"add_input_event","action_name":"move_left","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":65}}},
      {"type":"add_input_action","action_name":"move_right","replace":true},
      {"type":"add_input_event","action_name":"move_right","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":68}}},
      {"type":"add_input_action","action_name":"move_up","replace":true},
      {"type":"add_input_event","action_name":"move_up","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":87}}},
      {"type":"add_input_action","action_name":"move_down","replace":true},
      {"type":"add_input_event","action_name":"move_down","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":83}}},
      {"type":"add_input_action","action_name":"shoot","replace":true},
      {"type":"add_input_event","action_name":"shoot","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":74}}}
    ]
  }'
```

Four layers, and every one of them is both occupied and scanned by the end of
this playbook: `world` by the walls, `player` by the player, `enemy` by the
chasers, `damage` by hitboxes and hurtboxes. That is what keeps the physics-layer
survey free of `mask_targets_empty_layer`.

### Step 2 — Art

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/hero_top.png",
    "palette": {"s":"#ffccaa","t":"#3e8948","d":"#2e6e4e","o":"#0a0a12"},
    "outline": "#0a0a12",
    "rows": [
      "................",
      "................",
      "....dddddd......",
      "...dddddddd.....",
      "...dssssssd.....",
      "...dssssssd.....",
      "...dssssssd.....",
      "...dddddddd.....",
      "..tttttttttt....",
      ".tttttttttttt...",
      ".tttttttttttt...",
      "..tttttttttt....",
      "...tttttttt.....",
      "....tt..tt......",
      "................",
      "................"
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/enemy.png",
    "palette": {"r":"#e43b44","k":"#a22633","e":"#ffe478"},
    "outline": "#2b0a0a",
    "rows": [
      "................",
      "................",
      "....rrrrrrrr....",
      "...rrrrrrrrrr...",
      "..rrrrrrrrrrrr..",
      "..rrekrrrrkerr..",
      "..rrrrrrrrrrrr..",
      "..rrrkkkkkkrrr..",
      "..rrrrrrrrrrrr..",
      "...rrrrrrrrrr...",
      "....rrrrrrrr....",
      "....kk....kk....",
      "................",
      "................",
      "................",
      "................"
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/bullet.png",
    "width": 8, "height": 8,
    "shapes": [
      {"type":"circle","x":4,"y":4,"radius":3,"color":"#ffb02e"},
      {"type":"circle","x":4,"y":4,"radius":2,"color":"#ffe478"}
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/wall.png",
    "width": 16, "height": 16,
    "shapes": [
      {"type":"rect","color":"#3a4466"},
      {"type":"checker","colors":["#3a4466","#262b44"],"cell":8},
      {"type":"rect_outline","color":"#5a6988","thickness":1}
    ]
  }'
```

### Step 3 — Sound

```bash
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset shoot --seed 2 --out /absolute/path/to/project/audio/
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset hit --seed 4 --out /absolute/path/to/project/audio/
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset explosion --seed 6 --variations 2 --out /absolute/path/to/project/audio/
```

`--variations 2` writes `explosion_1.wav` and `explosion_2.wav`, siblings of the
same boom, so repeated kills do not sound mechanical.

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_audio '{"audio_paths":["audio"],"format":"json","envelope":false,
                  "expect":{"not_silent":true,"no_clipping":true}}'
```

### Step 4 — Templates, buses, autoloads, import

```bash
cp /absolute/path/to/godot/templates/gdscript/game_manager.gd \
   /absolute/path/to/godot/templates/gdscript/audio_manager.gd \
   /absolute/path/to/godot/templates/gdscript/health.gd \
   /absolute/path/to/godot/templates/gdscript/hitbox.gd \
   /absolute/path/to/godot/templates/gdscript/hurtbox.gd \
   /absolute/path/to/godot/templates/gdscript/object_pool.gd \
   /absolute/path/to/godot/templates/gdscript/projectile.gd \
   /absolute/path/to/godot/templates/gdscript/shooter.gd \
   /absolute/path/to/godot/templates/gdscript/wave_spawner.gd \
   /absolute/path/to/godot/templates/gdscript/enemy_chase_nav_2d.gd \
   /absolute/path/to/godot/templates/gdscript/damage_number.gd \
   /absolute/path/to/godot/templates/gdscript/player_topdown_2d.gd \
   /absolute/path/to/godot/templates/gdscript/camera_shake_2d.gd \
   /absolute/path/to/project/scripts/
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  setup_audio_buses '{
    "buses":[{"name":"Master","volume_db":0.0},
             {"name":"Music","send":"Master","volume_db":-6.0},
             {"name":"SFX","send":"Master","volume_db":-3.0}],
    "save_path":"audio/default_bus_layout.tres","set_project_setting":true}'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"add_autoload","autoload_name":"GameManager","path":"res://scripts/game_manager.gd","singleton":true},
      {"type":"add_autoload","autoload_name":"AudioManager","path":"res://scripts/audio_manager.gd","singleton":true}
    ]}'
godot --headless --path /absolute/path/to/project --import
```

Five of those templates declare a `class_name` (`Health`, `Hitbox`, `Hurtbox`,
`ObjectPool`, `Projectile`, `DamageNumber`), and `shooter.gd` annotates
`Projectile`. The `--import` is what makes them resolve; skip it and the next
`attach_script` fails with `Identifier "Projectile" not declared in the current
scope`.

### Step 5 — The bullet

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/bullet.tscn",
    "create_if_missing": true,
    "root_node_type": "Area2D",
    "root_node_name": "Bullet",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":0,"collision_mask":1}},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CircleShape2D","properties":{"radius":3.0}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/bullet.png"}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Area2D","node_name":"Hitbox",
       "properties":{"collision_layer":8,"collision_mask":8}},
      {"type":"add_node","parent_node_path":"root/Hitbox","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CircleShape2D","properties":{"radius":4.0}}}},
      {"type":"attach_script","node_path":"root/Hitbox","script_path":"scripts/hitbox.gd",
       "script_properties":{"damage":1,"team":"player","one_shot":true}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/projectile.gd",
       "script_properties":{"speed":420.0,"lifetime":1.2,"hitbox_path":{"__type":"NodePath","value":"Hitbox"}}}
    ]
  }'
```

Two areas, two jobs. The root scans layer 1 so the bullet dies on a wall; the
`Hitbox` child lives on the damage layer (4, value 8) and only talks to
hurtboxes. `projectile.gd` rearms the hitbox on every `launch()`, which is the
detail that makes a pooled `one_shot` bullet work more than once.

### Step 6 — The chaser

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/enemy.tscn",
    "create_if_missing": true,
    "root_node_type": "CharacterBody2D",
    "root_node_name": "Enemy",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":4,"collision_mask":1},"groups_add":["enemy"]},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CircleShape2D","properties":{"radius":6.0}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/enemy.png"}}},
      {"type":"add_node","parent_node_path":"root","node_type":"NavigationAgent2D","node_name":"NavigationAgent2D",
       "properties":{"radius":6.0,"path_desired_distance":6.0,"target_desired_distance":10.0,"avoidance_enabled":false}},
      {"type":"add_node","parent_node_path":"root","node_type":"Node","node_name":"Health"},
      {"type":"attach_script","node_path":"root/Health","script_path":"scripts/health.gd",
       "script_properties":{"max_health":1,"invulnerability_time":0.0}},
      {"type":"add_node","parent_node_path":"root","node_type":"Area2D","node_name":"Hurtbox",
       "properties":{"collision_layer":8,"collision_mask":8}},
      {"type":"add_node","parent_node_path":"root/Hurtbox","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CircleShape2D","properties":{"radius":8.0}}}},
      {"type":"attach_script","node_path":"root/Hurtbox","script_path":"scripts/hurtbox.gd",
       "script_properties":{"team":"enemy","health_path":{"__type":"NodePath","value":"../Health"}}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/enemy_chase_nav_2d.gd",
       "script_properties":{"speed":60.0,"repath_interval":0.25,"stop_distance":12.0}}
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/damage_number.tscn",
    "create_if_missing": true,
    "root_node_type": "Label",
    "root_node_name": "DamageNumber",
    "actions": [
      {"type":"attach_script","node_path":"root","script_path":"scripts/damage_number.gd",
       "script_properties":{"rise_distance":20.0,"duration":0.5}}
    ]
  }'
```

### Step 7 — Player with a shooter

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/player.tscn",
    "create_if_missing": true,
    "root_node_type": "CharacterBody2D",
    "root_node_name": "Player",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":2,"collision_mask":1},"groups_add":["player"]},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"CircleShape2D","properties":{"radius":6.0}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/hero_top.png"}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Camera2D","node_name":"Camera2D",
       "properties":{"position_smoothing_enabled":true,"position_smoothing_speed":8.0}},
      {"type":"attach_script","node_path":"root/Camera2D","script_path":"scripts/camera_shake_2d.gd",
       "script_properties":{"decay":4.0,"max_offset":{"__type":"Vector2","x":5,"y":4}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Node2D","node_name":"Shooter"},
      {"type":"add_node","parent_node_path":"root/Shooter","node_type":"Marker2D","node_name":"Muzzle",
       "properties":{"position":{"__type":"Vector2","x":10,"y":0}}},
      {"type":"attach_script","node_path":"root/Shooter","script_path":"scripts/shooter.gd",
       "script_properties":{"projectile_scene":{"__resource":"res://scenes/bullet.tscn"},
                            "fire_rate":5.0,"aim_mode":1,
                            "sound":{"__resource":"res://audio/shoot.wav"},
                            "pool_path":{"__type":"NodePath","value":"../../BulletPool"},
                            "projectile_parent_path":{"__type":"NodePath","value":"../../Bullets"}}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/player_topdown_2d.gd",
       "script_properties":{"speed":90.0}}
    ]
  }'
```

`aim_mode` 1 is `FACING`: the shooter asks its parent for `facing()`, which
`player_topdown_2d.gd` provides, so the gun points where the player last walked.
`aim_mode` 0 aims at the mouse instead. The `../../` paths look out of the player
scene into the arena that instantiates it — inside `player.tscn` alone they
resolve to nothing and the shooter falls back to instantiating a bullet into the
current scene, which is exactly what you want when smoke-running the player
scene on its own.

### Step 8 — Bake the navigation polygon

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  resource_batch '{
    "resource_path": "nav/arena.tres",
    "create_if_missing": true,
    "resource_type": "NavigationPolygon",
    "actions": [
      {"type":"set_properties","properties":{"agent_radius":8.0,"cell_size":1.0}},
      {"type":"bake_navmesh",
       "traversable_outlines": [[[8,8],[312,8],[312,172],[8,172]]],
       "obstruction_outlines": [[[136,24],[184,24],[184,56],[136,56]]]}
    ]
  }'
```

The bake is synchronous and takes the geometry as plain outlines — the headless
dummy renderer cannot read a visual mesh back off the GPU, so never expect a
bake from `MeshInstance` geometry here. `agent_radius` must be at least the
enemy radius or the chasers clip the corners.

### Step 9 — The arena script

```bash
cat > /absolute/path/to/project/scripts/arena.gd <<'GDSCRIPT'
extends Node2D

const DAMAGE_NUMBER: PackedScene = preload("res://scenes/damage_number.tscn")
const HIT_SOUND: AudioStream = preload("res://audio/hit.wav")
const DEATH_SOUND: AudioStream = preload("res://audio/explosion_1.wav")

@onready var _spawner: Node2D = $WaveSpawner
@onready var _camera: Camera2D = $Player/Camera2D


func _ready() -> void:
	_spawner.connect(&"wave_started", _on_wave_started)
	_spawner.connect(&"wave_cleared", _on_wave_cleared)
	_spawner.connect(&"all_waves_cleared", _on_all_waves_cleared)
	_spawner.connect(&"enemy_spawned", _on_enemy_spawned)
	# The spawner has auto_start off: a spawner that starts itself emits
	# wave_started from its own _ready(), which runs BEFORE the _ready() of
	# this parent, so the first wave would never reach these handlers.
	_spawner.call(&"start")


func _on_wave_started(index: int, count: int) -> void:
	print("[ARENA] wave %d started with %d enemies" % [index, count])


func _on_wave_cleared(index: int) -> void:
	print("[ARENA] wave %d cleared" % index)


func _on_all_waves_cleared() -> void:
	print("[ARENA] all waves cleared score=%d" % GameManager.score)


func _on_enemy_spawned(enemy: Node) -> void:
	var hurtbox := enemy.get_node_or_null(^"Hurtbox") as Hurtbox
	if hurtbox != null:
		hurtbox.hurt.connect(_on_enemy_hurt.bind(enemy))
	var health := enemy.get_node_or_null(^"Health") as Health
	if health != null:
		health.died.connect(_on_enemy_died.bind(enemy))
	if enemy.has_signal(&"navigation_mode_changed"):
		enemy.connect(&"navigation_mode_changed", _on_navigation_mode_changed)


func _on_navigation_mode_changed(using_navigation: bool) -> void:
	print("[ARENA] chaser navigation=%s" % using_navigation)


func _on_enemy_hurt(amount: int, enemy: Node) -> void:
	var body := enemy as Node2D
	if body == null:
		return
	var number := DAMAGE_NUMBER.instantiate() as DamageNumber
	if number == null:
		return
	add_child(number)
	number.popup(amount, body.global_position)
	AudioManager.play_sfx(HIT_SOUND)


func _on_enemy_died(enemy: Node) -> void:
	GameManager.add_score(100)
	_camera.call(&"add_trauma", 0.5)
	AudioManager.play_sfx(DEATH_SOUND)
	print("[ARENA] enemy-died score=%d" % GameManager.score)
	enemy.queue_free()
GDSCRIPT
```

`popup()` must be called **after** `add_child()`: `create_tween()` on a node
outside the tree fails. And note the order — `add_child` first, then `popup`,
which reads the world position and centres the label under it.

### Step 10 — Assemble the arena

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/arena.tscn",
    "create_if_missing": true,
    "root_node_type": "Node2D",
    "root_node_name": "Arena",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"NavigationRegion2D","node_name":"NavRegion",
       "properties":{"navigation_polygon":{"__resource":"res://nav/arena.tres"}}},

      {"type":"add_node","parent_node_path":"root","node_type":"StaticBody2D","node_name":"Walls",
       "properties":{"collision_layer":1,"collision_mask":0}},
      {"type":"add_node","parent_node_path":"root/Walls","node_type":"CollisionShape2D","node_name":"Top",
       "properties":{"position":{"__type":"Vector2","x":160,"y":4},
        "shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":320,"y":8}}}}},
      {"type":"add_node","parent_node_path":"root/Walls","node_type":"CollisionShape2D","node_name":"Bottom",
       "properties":{"position":{"__type":"Vector2","x":160,"y":176},
        "shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":320,"y":8}}}}},
      {"type":"add_node","parent_node_path":"root/Walls","node_type":"CollisionShape2D","node_name":"Left",
       "properties":{"position":{"__type":"Vector2","x":4,"y":90},
        "shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":8,"y":180}}}}},
      {"type":"add_node","parent_node_path":"root/Walls","node_type":"CollisionShape2D","node_name":"Right",
       "properties":{"position":{"__type":"Vector2","x":316,"y":90},
        "shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":8,"y":180}}}}},
      {"type":"add_node","parent_node_path":"root/Walls","node_type":"CollisionShape2D","node_name":"Block",
       "properties":{"position":{"__type":"Vector2","x":160,"y":40},
        "shape":{"__resource_type":"RectangleShape2D","properties":{"size":{"__type":"Vector2","x":48,"y":32}}}}},
      {"type":"add_node","parent_node_path":"root/Walls","node_type":"Sprite2D","node_name":"BlockSprite",
       "properties":{"position":{"__type":"Vector2","x":160,"y":40},"texture":{"__resource":"res://art/wall.png"},
        "region_enabled":true,"region_rect":{"__type":"Rect2","x":0,"y":0,"width":48,"height":32},"texture_repeat":2}},

      {"type":"add_node","parent_node_path":"root","node_type":"Node2D","node_name":"Bullets"},
      {"type":"add_node","parent_node_path":"root","node_type":"Node","node_name":"BulletPool"},
      {"type":"attach_script","node_path":"root/BulletPool","script_path":"scripts/object_pool.gd",
       "script_properties":{"scene":{"__resource":"res://scenes/bullet.tscn"},"initial_size":16,"grow":true}},

      {"type":"add_node","parent_node_path":"root","node_type":"Node2D","node_name":"WaveSpawner"},
      {"type":"add_node","parent_node_path":"root/WaveSpawner","node_type":"Node2D","node_name":"SpawnPoints"},
      {"type":"add_node","parent_node_path":"root/WaveSpawner/SpawnPoints","node_type":"Marker2D","node_name":"Spawn0",
       "properties":{"position":{"__type":"Vector2","x":280,"y":90}}},
      {"type":"add_node","parent_node_path":"root/WaveSpawner/SpawnPoints","node_type":"Marker2D","node_name":"Spawn1",
       "properties":{"position":{"__type":"Vector2","x":280,"y":140}}},
      {"type":"attach_script","node_path":"root/WaveSpawner","script_path":"scripts/wave_spawner.gd",
       "script_properties":{"enemy_scene":{"__resource":"res://scenes/enemy.tscn"},
                            "waves":[1,2],"spawn_interval":0.4,"wave_delay":1.0,"auto_start":false,
                            "enemy_parent_path":{"__type":"NodePath","value":".."}}},

      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/player.tscn","node_name":"Player",
       "properties":{"position":{"__type":"Vector2","x":60,"y":90}}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/arena.gd"}
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{"actions":[{"type":"set_main_scene","scene_path":"res://scenes/arena.tscn"}]}'
```

One `Sprite2D` textures the pillar: `region_enabled` plus a `region_rect` the
size of the block plus `texture_repeat: 2` (`TEXTURE_REPEAT_ENABLED`) tiles the
16x16 stone over 48x32 without a second PNG.

### Verify

```bash
cat > /absolute/path/to/project/scenario_arena.json <<'JSON'
{
  "scene_path": "res://scenes/arena.tscn",
  "viewport_size": {"width": 320, "height": 180},
  "settle_frames": 4,
  "steps": [
    {"type": "wait_seconds", "seconds": 0.6},
    {"type": "spatial_report", "label": "boot", "ascii": true, "ascii_size": {"cols": 56, "rows": 16},
     "expect_on_screen": ["Player"],
     "fail_on": ["not_on_screen", "embedded_in_static", "no_camera_2d"]},
    {"type": "assert", "assertion": "property", "node_path": "WaveSpawner", "property": "wave_index", "expected": 1},
    {"type": "wait_until", "node_path": "WaveSpawner", "property": "alive_count", "expected": 1,
     "operator": "greater_or_equal", "timeout_seconds": 5},

    {"type": "action", "action_name": "move_right", "pressed": true},
    {"type": "wait_seconds", "seconds": 0.25},
    {"type": "action", "action_name": "move_right", "pressed": false},
    {"type": "log_marker", "message": "facing-right"},

    {"type": "action", "action_name": "shoot", "pressed": true},
    {"type": "wait_until", "node_path": "/root/GameManager", "property": "score", "expected": 100,
     "operator": "greater_or_equal", "timeout_seconds": 12},
    {"type": "log_marker", "message": "first-kill"},
    {"type": "wait_until", "node_path": "WaveSpawner", "property": "wave_index", "expected": 2,
     "operator": "greater_or_equal", "timeout_seconds": 8},
    {"type": "action", "action_name": "shoot", "pressed": false},
    {"type": "assert", "assertion": "property", "node_path": "WaveSpawner", "property": "wave_index", "expected": 2},
    {"type": "assert", "assertion": "property", "node_path": "/root/GameManager", "property": "score",
     "expected": 100, "operator": "greater_or_equal"},
    {"type": "spatial_report", "label": "wave-2", "ascii": true, "ascii_size": {"cols": 56, "rows": 16},
     "expect_on_screen": ["Player"],
     "fail_on": ["not_on_screen", "embedded_in_static"]}
  ],
  "assertions": [
    {"assertion": "node_exists", "node_path": "NavRegion"},
    {"assertion": "node_exists", "node_path": "BulletPool"}
  ],
  "log_assertions": [
    {"contains": "wave 1 started with 1 enemies", "min_count": 1},
    {"contains": "enemy-died", "min_count": 1},
    {"contains": "wave 1 cleared", "min_count": 1},
    {"contains": "chaser navigation=true", "min_count": 1}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --warnings-as-errors --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_arena.json --log-file /tmp/arena.log --pretty
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  check_project '{"config_warnings":true,"physics_layers":true}'
```

Expected:

- `lint_project.py` and `validate_project.py` both `"ok": true`, zero errors,
  zero warnings, `config_warning_count: 0`.
- `run_scenario.py` `"ok": true`, 5 assertions passed, both `spatial_report`s
  `findings=0`, all four `log_assertions` matched:

  ```
  [ARENA] chaser navigation=true
  [ARENA] wave 1 started with 1 enemies
  [SCENARIO] facing-right
  [ARENA] enemy-died score=100
  [ARENA] wave 1 cleared
  [SCENARIO] first-kill
  [ARENA] wave 2 started with 2 enemies
  ```

  `chaser navigation=true` is the navmesh proof — `enemy_chase_nav_2d.gd` only
  reports that when the agent is on a map that actually has regions. Delete
  `nav/arena.tres` and it prints `false` and walks in a straight line instead of
  standing still, which is the point of the fallback.
- `check_project` `physics_layers.findings` holds **no**
  `mask_targets_empty_layer`: every mask bit in the project (1 for the world, 8
  for the damage channel) is occupied by something. The two
  `layer_never_scanned` hints on `player` and `enemy` are information — nothing
  hunts the player yet.

If the bullets never hit anything, check the two hitbox layers before anything
else: `hitbox.gd` finds a `Hurtbox` through `area_entered`, so the bullet hitbox
and the enemy hurtbox must both sit on the same bit *and* scan it.

---

## 20. Grid Puzzle (Sokoban)

**Goal.** A crate-pushing puzzle built from an ASCII map, with the movement
rules in pure static functions so they are unit-tested without a scene, plus
undo, restart and a win condition.

**Requires.** Nothing — this playbook creates its own project.

### Step 1 — Project and input

```bash
mkdir -p /absolute/path/to/project/scenes \
         /absolute/path/to/project/scripts \
         /absolute/path/to/project/art
cat > /absolute/path/to/project/project.godot <<'GODOT'
config_version=5

[application]

config/name="CratePush"
GODOT
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"set_setting","name":"display/window/size/viewport_width","value":320},
      {"type":"set_setting","name":"display/window/size/viewport_height","value":180},
      {"type":"set_setting","name":"display/window/stretch/mode","value":"canvas_items"},
      {"type":"set_setting","name":"rendering/textures/canvas_textures/default_texture_filter","value":0},
      {"type":"add_input_action","action_name":"move_left","replace":true},
      {"type":"add_input_event","action_name":"move_left","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":65}}},
      {"type":"add_input_action","action_name":"move_right","replace":true},
      {"type":"add_input_event","action_name":"move_right","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":68}}},
      {"type":"add_input_action","action_name":"move_up","replace":true},
      {"type":"add_input_event","action_name":"move_up","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":87}}},
      {"type":"add_input_action","action_name":"move_down","replace":true},
      {"type":"add_input_event","action_name":"move_down","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":83}}},
      {"type":"add_input_action","action_name":"undo","replace":true},
      {"type":"add_input_event","action_name":"undo","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":90}}},
      {"type":"add_input_action","action_name":"restart","replace":true},
      {"type":"add_input_event","action_name":"restart","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":82}}}
    ]
  }'
```

### Step 2 — Four 16x16 tiles

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/wall.png", "width": 16, "height": 16,
    "shapes": [{"type":"rect","color":"#3a4466"},
               {"type":"checker","colors":["#3a4466","#262b44"],"cell":8},
               {"type":"rect_outline","color":"#5a6988","thickness":1}]}'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/crate.png", "width": 16, "height": 16,
    "shapes": [{"type":"rect","x":1,"y":1,"width":14,"height":14,"color":"#8f563b"},
               {"type":"rect_outline","x":1,"y":1,"width":14,"height":14,"color":"#663931","thickness":1},
               {"type":"line","from":[2,2],"to":[13,13],"color":"#d9a066"},
               {"type":"line","from":[13,2],"to":[2,13],"color":"#d9a066"}]}'
```

`line` takes `from` and `to` points, not `x`/`y`/`x2`/`y2` — the op says so and
writes nothing when you guess.

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/target.png", "width": 16, "height": 16,
    "shapes": [{"type":"circle","x":8,"y":8,"radius":5,"color":"#e43b44"},
               {"type":"circle","x":8,"y":8,"radius":3,"color":null}]}'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/player.png", "width": 16, "height": 16,
    "shapes": [{"type":"circle","x":8,"y":6,"radius":4,"color":"#ffccaa"},
               {"type":"rect","x":5,"y":9,"width":6,"height":6,"color":"#3e8948"},
               {"type":"pixels","color":"#0a0a12","points":[[6,5],[10,5]]}]}'
```

`"color": null` is transparent, so the second circle punches the ring out of the
first one.

### Step 3 — Copy the two templates and rebuild the class cache

```bash
cp /absolute/path/to/godot/templates/gdscript/grid_movement.gd \
   /absolute/path/to/godot/templates/gdscript/sokoban_level.gd \
   /absolute/path/to/project/scripts/
godot --headless --path /absolute/path/to/project --import
```

`grid_movement.gd` declares `class_name GridMovement`, and `sokoban_level.gd`
annotates it, so the import has to happen before the `attach_script` below.

### Step 4 — The puzzle scene

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/puzzle.tscn",
    "create_if_missing": true,
    "root_node_type": "Node2D",
    "root_node_name": "Puzzle",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"Node2D","node_name":"Player"},
      {"type":"add_node","parent_node_path":"root/Player","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/player.png"}}},
      {"type":"attach_script","node_path":"root/Player","script_path":"scripts/grid_movement.gd",
       "script_properties":{"cell_size":{"__type":"Vector2i","x":16,"y":16},
                            "origin":{"__type":"Vector2","x":96,"y":64},
                            "step_time":0.1,"move_while_held":false}},
      {"type":"attach_script","node_path":"root","script_path":"scripts/sokoban_level.gd",
       "script_properties":{"ascii_level":"######\n#@.$o#\n######",
                            "player_path":{"__type":"NodePath","value":"Player"},
                            "wall_texture":{"__resource":"res://art/wall.png"},
                            "crate_texture":{"__resource":"res://art/crate.png"},
                            "target_texture":{"__resource":"res://art/target.png"}}}
    ]
  }'
```

The map characters are the skill convention: `#` wall, `@` player, `$` crate,
`o` target, `*` crate already on a target, `+` player on a target, `.` floor.
`origin` is where cell (0, 0) starts in world space, so the 6x3 level lands
centred in the 320x180 viewport. `move_while_held: false` makes it one step per
key press, which is what a puzzle wants.

### Step 5 — A status line

```bash
cat > /absolute/path/to/project/scripts/puzzle_hud.gd <<'GDSCRIPT'
extends Label

# The sokoban_level.gd node. Default: two levels up (HUD/Status -> Puzzle).
@export var level_path: NodePath = ^"../.."


func _ready() -> void:
	# The _ready() of this Label runs before the one on the level root, so the
	# connections exist by the time load_level() emits its first progress_changed.
	var level: Node = get_node_or_null(level_path)
	if level == null:
		push_error("puzzle_hud: level_path does not resolve.")
		return
	level.connect(&"progress_changed", _on_progress_changed)
	level.connect(&"solved", _on_solved)
	level.connect(&"move_undone", _on_move_undone)


func _on_progress_changed(on_target: int, total: int) -> void:
	text = "CRATES %d/%d" % [on_target, total]


func _on_solved(moves: int, pushes: int) -> void:
	text = "SOLVED %d moves %d pushes" % [moves, pushes]
	print("[PUZZLE] solved moves=%d pushes=%d" % [moves, pushes])


func _on_move_undone(moves: int) -> void:
	print("[PUZZLE] undo moves=%d" % moves)
GDSCRIPT
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/puzzle.tscn",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"CanvasLayer","node_name":"HUD"},
      {"type":"add_node","parent_node_path":"root/HUD","node_type":"MarginContainer","node_name":"Frame","properties":{"mouse_filter":2}},
      {"type":"configure_control","node_path":"root/HUD/Frame","layout_preset":"TOP_LEFT",
       "theme_overrides":{"constants":{"margin_left":8,"margin_top":6,"margin_right":0,"margin_bottom":0}}},
      {"type":"add_node","parent_node_path":"root/HUD/Frame","node_type":"Label","node_name":"Status","properties":{"text":"CRATES 0/1"}},
      {"type":"attach_script","node_path":"root/HUD/Frame/Status","script_path":"scripts/puzzle_hud.gd",
       "script_properties":{"level_path":{"__type":"NodePath","value":"../../.."}}}
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{"actions":[{"type":"set_main_scene","scene_path":"res://scenes/puzzle.tscn"}]}'
```

### Step 6 — Unit-test the rules

```bash
python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --init-mini
rm /absolute/path/to/project/tests/test_example.gd
```

```bash
cat > /absolute/path/to/project/tests/test_push_rules.gd <<'GDSCRIPT'
extends "res://tests/test_case.gd"

# The rules are static and take plain Dictionaries, so they are testable with no
# scene, no nodes and no frames. preload() needs no class cache.
const Grid = preload("res://scripts/grid_movement.gd")

const START := Vector2i(1, 1)


func _cells(list: Array) -> Dictionary:
	var cells: Dictionary = {}
	for cell in list:
		cells[cell] = true
	return cells


func test_a_step_onto_open_floor_moves_one_cell() -> void:
	var outcome: Dictionary = Grid.resolve_step(START, Vector2i.RIGHT, {}, {})
	assert_true(outcome["moved"])
	assert_eq(outcome["to"], Vector2i(2, 1))
	assert_false(outcome["pushed"])


func test_a_wall_blocks_the_step() -> void:
	var walls: Dictionary = _cells([Vector2i(2, 1)])
	var outcome: Dictionary = Grid.resolve_step(START, Vector2i.RIGHT, walls, {})
	assert_false(outcome["moved"], "a wall must stop the step")
	assert_eq(outcome["reason"], "wall")
	assert_eq(outcome["to"], START, "a blocked step never moves the token")


func test_a_crate_with_free_floor_behind_it_is_pushed() -> void:
	var crates: Dictionary = _cells([Vector2i(2, 1)])
	var outcome: Dictionary = Grid.resolve_step(START, Vector2i.RIGHT, {}, crates)
	assert_true(outcome["moved"])
	assert_true(outcome["pushed"])
	assert_eq(outcome["crate_from"], Vector2i(2, 1))
	assert_eq(outcome["crate_to"], Vector2i(3, 1))


func test_a_crate_against_a_wall_blocks_the_step() -> void:
	var walls: Dictionary = _cells([Vector2i(3, 1)])
	var crates: Dictionary = _cells([Vector2i(2, 1)])
	var outcome: Dictionary = Grid.resolve_step(START, Vector2i.RIGHT, walls, crates)
	assert_false(outcome["moved"])
	assert_eq(outcome["reason"], "crate_into_wall")


func test_a_crate_against_another_crate_blocks_the_step() -> void:
	var crates: Dictionary = _cells([Vector2i(2, 1), Vector2i(3, 1)])
	var outcome: Dictionary = Grid.resolve_step(START, Vector2i.RIGHT, {}, crates)
	assert_false(outcome["moved"])
	assert_eq(outcome["reason"], "crate_into_crate")


func test_target_detection_needs_every_target_covered() -> void:
	var targets: Dictionary = _cells([Vector2i(4, 1), Vector2i(5, 1)])
	assert_false(Grid.all_targets_covered(targets, _cells([Vector2i(4, 1)])))
	assert_eq(Grid.covered_count(targets, _cells([Vector2i(4, 1)])), 1)
	assert_true(Grid.all_targets_covered(targets, _cells([Vector2i(4, 1), Vector2i(5, 1)])))
	assert_eq(Grid.covered_count(targets, _cells([Vector2i(4, 1), Vector2i(5, 1)])), 2)


func test_a_level_with_no_targets_is_never_solved() -> void:
	assert_false(Grid.all_targets_covered({}, _cells([Vector2i(2, 1)])))
GDSCRIPT
```

```bash
cat > /absolute/path/to/project/tests/test_puzzle_scene.gd <<'GDSCRIPT'
extends "res://tests/test_case.gd"

var level: Node2D = null
var player: GridMovement = null


func before_each() -> void:
	level = add_scene("res://scenes/puzzle.tscn")
	player = level.get_node("Player") as GridMovement
	await wait_frames(1)


func test_the_level_loads_the_ascii_map() -> void:
	assert_not_null(player)
	assert_eq(player.cell, Vector2i(1, 1), "the @ in the map is at column 1, row 1")
	assert_eq(level.target_count(), 1)
	assert_false(level.is_complete)


func test_two_steps_push_the_crate_onto_the_target() -> void:
	player.try_step(Vector2i.RIGHT)
	await wait_seconds(0.2)
	player.try_step(Vector2i.RIGHT)
	await wait_seconds(0.2)
	assert_eq(player.cell, Vector2i(3, 1))
	assert_true(level.is_complete, "the crate should be on the target")
	assert_eq(level.moves, 2)
	assert_eq(level.pushes, 1)


func test_undo_puts_the_crate_and_the_player_back() -> void:
	player.try_step(Vector2i.RIGHT)
	await wait_seconds(0.2)
	player.try_step(Vector2i.RIGHT)
	await wait_seconds(0.2)
	assert_true(level.is_complete, "precondition: solved")
	assert_true(level.undo())
	await wait_frames(1)
	assert_eq(player.cell, Vector2i(2, 1))
	assert_eq(level.moves, 1)
	assert_eq(level.covered(), 0, "the crate is off the target again")
	assert_false(level.is_complete)


func test_a_wall_refuses_the_step_and_costs_no_move() -> void:
	player.try_step(Vector2i.UP)
	await wait_seconds(0.2)
	assert_eq(player.cell, Vector2i(1, 1), "row 0 is all wall")
	assert_eq(level.moves, 0)
GDSCRIPT
```

The first suite is the reason `resolve_step()` is static and takes Dictionaries:
no scene, no frames, no engine state, seven cases in a fifth of a second. The
second one needs the tree, so it uses `add_scene()` and waits out the step tween
with `wait_seconds(0.2)` (`step_time` is 0.1).

### Verify

```bash
cat > /absolute/path/to/project/scenario_puzzle.json <<'JSON'
{
  "scene_path": "res://scenes/puzzle.tscn",
  "viewport_size": {"width": 320, "height": 180},
  "settle_frames": 4,
  "steps": [
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "cell",
     "expected": {"__type": "Vector2i", "x": 1, "y": 1}},
    {"type": "assert", "assertion": "property", "node_path": ".", "property": "is_complete", "expected": false},
    {"type": "ui_report", "label": "hud", "node_path": "HUD", "fail_on": ["overlap", "zero_size", "offscreen"]},

    {"type": "key", "physical_keycode": 68, "pressed": true},
    {"type": "key", "physical_keycode": 68, "pressed": false},
    {"type": "wait_until", "node_path": "Player", "property": "moving", "expected": false, "timeout_seconds": 3},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "cell",
     "expected": {"__type": "Vector2i", "x": 2, "y": 1}},
    {"type": "key", "physical_keycode": 68, "pressed": true},
    {"type": "key", "physical_keycode": 68, "pressed": false},
    {"type": "wait_until", "node_path": ".", "property": "is_complete", "expected": true, "timeout_seconds": 3},
    {"type": "log_marker", "message": "solved-in-two"},

    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "cell",
     "expected": {"__type": "Vector2i", "x": 3, "y": 1}},
    {"type": "assert", "assertion": "property", "node_path": ".", "property": "moves", "expected": 2},
    {"type": "assert", "assertion": "property", "node_path": ".", "property": "pushes", "expected": 1},
    {"type": "assert", "assertion": "property", "node_path": "HUD/Frame/Status", "property": "text",
     "expected": "SOLVED 2 moves 1 pushes"},

    {"type": "key", "physical_keycode": 90, "pressed": true},
    {"type": "key", "physical_keycode": 90, "pressed": false},
    {"type": "wait_until", "node_path": ".", "property": "is_complete", "expected": false, "timeout_seconds": 3},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "cell",
     "expected": {"__type": "Vector2i", "x": 2, "y": 1}},
    {"type": "assert", "assertion": "property", "node_path": ".", "property": "moves", "expected": 1},
    {"type": "log_marker", "message": "undo-works"},
    {"type": "dump_tree", "node_path": ".", "properties": ["position", "text"], "max_depth": 3, "label": "after-undo"}
  ],
  "assertions": [
    {"assertion": "node_exists", "node_path": "HUD/Frame/Status"}
  ],
  "log_assertions": [
    {"contains": "[PUZZLE] solved moves=2 pushes=1", "min_count": 1},
    {"contains": "[PUZZLE] undo moves=1", "min_count": 1}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --warnings-as-errors --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_puzzle.json --log-file /tmp/puzzle.log --pretty
```

Expected:

- `run_tests.py` `"ok": true`, `"framework": "mini"`, `counts` =
  `{"scripts": 2, "tests": 11, "passed": 11, "failed": 0, "errors": 0, …}`, in
  about 1.4 s.
- `lint_project.py` and `validate_project.py` both clean under
  `--warnings-as-errors`.
- `run_scenario.py` `"ok": true` with 10 assertions passed, the `hud` report
  `findings=0`, and the log holding
  `[PUZZLE] solved moves=2 pushes=1` then `[PUZZLE] undo moves=1`.

Two facts the scenario depends on:

- **`key` steps, not `action` steps.** `grid_movement.gd` polls
  `is_action_just_pressed`, so either would work here, but the undo and restart
  keys go through `_unhandled_input` on the level, which only a real event
  reaches. Godot binds these actions by `physical_keycode`, so drive them with
  `physical_keycode` (D = 68, Z = 90) and not `keycode`.
- **Wait for the tween, not for a frame count.** `cell` changes the instant the
  step is accepted, while the token is still sliding and further input is
  ignored. `{"type": "wait_until", "node_path": "Player", "property": "moving",
  "expected": false}` is the reliable gate; a second key press before that is
  silently dropped.

---

## 21. 3D Third-Person Starter

**Goal.** A floor with baked collision, an obstacle with a primitive collider, a
light and an environment, and a character with a SpringArm3D camera that orbits
it — verified as text, because a 3D scene that renders black produces no error
at all.

**Requires.** Nothing — this playbook creates its own project.

### Step 1 — Project, gravity, input

```bash
mkdir -p /absolute/path/to/project/scenes /absolute/path/to/project/scripts
cat > /absolute/path/to/project/project.godot <<'GODOT'
config_version=5

[application]

config/name="ThirdPerson3D"
GODOT
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{
    "actions": [
      {"type":"set_setting","name":"display/window/size/viewport_width","value":1280},
      {"type":"set_setting","name":"display/window/size/viewport_height","value":720},
      {"type":"set_setting","name":"physics/3d/default_gravity","value":9.8},
      {"type":"set_layer_name","layer_type":"3d_physics","layer":1,"layer_name":"world"},
      {"type":"set_layer_name","layer_type":"3d_physics","layer":2,"layer_name":"player"},
      {"type":"add_input_action","action_name":"move_left","replace":true},
      {"type":"add_input_event","action_name":"move_left","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":65}}},
      {"type":"add_input_action","action_name":"move_right","replace":true},
      {"type":"add_input_event","action_name":"move_right","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":68}}},
      {"type":"add_input_action","action_name":"move_forward","replace":true},
      {"type":"add_input_event","action_name":"move_forward","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":87}}},
      {"type":"add_input_action","action_name":"move_back","replace":true},
      {"type":"add_input_event","action_name":"move_back","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":83}}},
      {"type":"add_input_action","action_name":"jump","replace":true},
      {"type":"add_input_event","action_name":"jump","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":32}}},
      {"type":"add_input_action","action_name":"sprint","replace":true},
      {"type":"add_input_event","action_name":"sprint","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":4194325}}},
      {"type":"add_input_action","action_name":"look_left","replace":true},
      {"type":"add_input_event","action_name":"look_left","event":{"__resource_type":"InputEventJoypadMotion","properties":{"axis":2,"axis_value":-1.0}}},
      {"type":"add_input_action","action_name":"look_right","replace":true},
      {"type":"add_input_event","action_name":"look_right","event":{"__resource_type":"InputEventJoypadMotion","properties":{"axis":2,"axis_value":1.0}}},
      {"type":"add_input_action","action_name":"look_up","replace":true},
      {"type":"add_input_event","action_name":"look_up","event":{"__resource_type":"InputEventJoypadMotion","properties":{"axis":3,"axis_value":-1.0}}},
      {"type":"add_input_action","action_name":"look_down","replace":true},
      {"type":"add_input_event","action_name":"look_down","event":{"__resource_type":"InputEventJoypadMotion","properties":{"axis":3,"axis_value":1.0}}}
    ]
  }'
```

Axes 2 and 3 are the right stick. The four `look_*` actions are optional —
`player_third_person_3d.gd` checks `InputMap.has_action` and simply skips
gamepad look when they are missing, instead of printing
`The InputMap action "look_left" does not exist` sixty times a second.

### Step 2 — The character

```bash
cp /absolute/path/to/godot/templates/gdscript/player_third_person_3d.gd \
   /absolute/path/to/project/scripts/player_third_person_3d.gd
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/player_3d.tscn",
    "create_if_missing": true,
    "root_node_type": "CharacterBody3D",
    "root_node_name": "Player",
    "actions": [
      {"type":"configure_node","node_path":"root","properties":{"collision_layer":2,"collision_mask":1},"groups_add":["player"]},
      {"type":"add_node","parent_node_path":"root","node_type":"CollisionShape3D","node_name":"CollisionShape3D",
       "properties":{"position":{"__type":"Vector3","x":0,"y":0.9,"z":0},
        "shape":{"__resource_type":"CapsuleShape3D","properties":{"radius":0.4,"height":1.8}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Node3D","node_name":"Body"},
      {"type":"add_node","parent_node_path":"root/Body","node_type":"MeshInstance3D","node_name":"MeshInstance3D",
       "properties":{"position":{"__type":"Vector3","x":0,"y":0.9,"z":0},
        "mesh":{"__resource_type":"CapsuleMesh","properties":{"radius":0.4,"height":1.8}},
        "material_override":{"__resource_type":"StandardMaterial3D","properties":{"albedo_color":"#3e8948"}}}},
      {"type":"add_node","parent_node_path":"root","node_type":"Node3D","node_name":"CameraPivot",
       "properties":{"position":{"__type":"Vector3","x":0,"y":1.2,"z":0}}},
      {"type":"add_node","parent_node_path":"root/CameraPivot","node_type":"SpringArm3D","node_name":"SpringArm3D",
       "properties":{"spring_length":4.0,"collision_mask":1,"margin":0.2}},
      {"type":"add_node","parent_node_path":"root/CameraPivot/SpringArm3D","node_type":"Camera3D","node_name":"Camera3D"},
      {"type":"attach_script","node_path":"root","script_path":"scripts/player_third_person_3d.gd",
       "script_properties":{"speed":5.0,"sprint_speed":8.0,"jump_velocity":4.5,"camera_distance":4.0,
                            "capture_mouse_on_ready":false}}
    ]
  }'
```

Three things in that tree are load-bearing:

- The **`CameraPivot`** carries yaw *and* pitch. Rotating the `CharacterBody3D`
  on X tips its capsule over and it falls through the floor.
- The **`SpringArm3D`** pushes its children along its local +Z, so a `Camera3D`
  at the arm origin ends up `spring_length` behind the pivot, looking forward.
  The script calls `add_excluded_object(get_rid())` on it, without which the arm
  collides with the player it is attached to and the camera snaps into the head.
- **`Body`** is a separate `Node3D` so the visual can turn toward the direction
  of travel while the collision capsule stays upright.

`capture_mouse_on_ready` is false here only so a headless verification run does
not grab the pointer; leave it `true` in a real build, and remember `Esc`
releases it.

### Step 3 — Floor, obstacle, light, environment

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level_3d.tscn",
    "create_if_missing": true,
    "root_node_type": "Node3D",
    "root_node_name": "Level3D",
    "actions": [
      {"type":"add_node","parent_node_path":"root","node_type":"MeshInstance3D","node_name":"Floor",
       "properties":{"position":{"__type":"Vector3","x":0,"y":-0.5,"z":0},
        "mesh":{"__resource_type":"BoxMesh","properties":{"size":{"__type":"Vector3","x":40,"y":1,"z":40}}},
        "material_override":{"__resource_type":"StandardMaterial3D","properties":{"albedo_color":"#4a5a3a"}}}},

      {"type":"add_node","parent_node_path":"root","node_type":"StaticBody3D","node_name":"Pillar",
       "properties":{"position":{"__type":"Vector3","x":3,"y":1,"z":-4},"collision_layer":1,"collision_mask":0}},
      {"type":"add_node","parent_node_path":"root/Pillar","node_type":"CollisionShape3D","node_name":"CollisionShape3D",
       "properties":{"shape":{"__resource_type":"BoxShape3D","properties":{"size":{"__type":"Vector3","x":2,"y":2,"z":2}}}}},
      {"type":"add_node","parent_node_path":"root/Pillar","node_type":"MeshInstance3D","node_name":"MeshInstance3D",
       "properties":{"mesh":{"__resource_type":"BoxMesh","properties":{"size":{"__type":"Vector3","x":2,"y":2,"z":2}}},
        "material_override":{"__resource_type":"StandardMaterial3D","properties":{"albedo_color":"#8b9bb4"}}}},

      {"type":"add_node","parent_node_path":"root","node_type":"DirectionalLight3D","node_name":"Sun",
       "properties":{"rotation":{"__type":"Vector3","x":-0.9,"y":-0.6,"z":0},"shadow_enabled":true}},
      {"type":"add_node","parent_node_path":"root","node_type":"WorldEnvironment","node_name":"WorldEnvironment",
       "properties":{"environment":{"__resource_type":"Environment","properties":{"background_mode":1,"ambient_light_source":2,"ambient_light_energy":0.4}}}},

      {"type":"instantiate_scene","parent_node_path":"root","instance_scene_path":"scenes/player_3d.tscn","node_name":"Player",
       "properties":{"position":{"__type":"Vector3","x":0,"y":2,"z":0}}}
    ]
  }'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  bake_collision '{"scene_path":"scenes/level_3d.tscn","node_path":"root/Floor","mode":"trimesh"}'
```

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  project_batch '{"actions":[{"type":"set_main_scene","scene_path":"res://scenes/level_3d.tscn"}]}'
```

Two ways to get a collider, both shown here on purpose: `bake_collision` turns
the floor mesh into `Floor/Floor_col` (a `StaticBody3D` named after Godot own
helper, not `StaticBody3D`), and the pillar uses a hand-made `StaticBody3D` plus
a `BoxShape3D`, which is cheaper and exact for a box. A `MeshInstance3D` on its
own has no collider at all, and the player falls forever with no error.

### Verify

```bash
cat > /absolute/path/to/project/scenario_thirdperson.json <<'JSON'
{
  "scene_path": "res://scenes/level_3d.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "settle_frames": 4,
  "steps": [
    {"type": "wait_seconds", "seconds": 1.2},
    {"type": "spatial_report", "label": "render-check", "ascii": true, "ascii_size": {"cols": 56, "rows": 16},
     "expect_on_screen": ["Player", "Pillar"],
     "fail_on": ["no_camera_3d", "no_light_3d", "not_in_frustum", "behind_camera", "embedded_in_static"]},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "position:y",
     "expected": -0.05, "operator": "greater_than"},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "velocity:y",
     "expected": 0.0, "operator": "approx", "tolerance": 0.5},
    {"type": "log_marker", "message": "standing"},

    {"type": "action", "action_name": "move_forward", "pressed": true},
    {"type": "wait_seconds", "seconds": 0.8},
    {"type": "action", "action_name": "move_forward", "pressed": false},
    {"type": "assert", "assertion": "property", "node_path": "Player", "property": "position:z",
     "expected": -1.0, "operator": "less_than"},
    {"type": "log_marker", "message": "walked-forward"},

    {"type": "spatial_report", "label": "after-walk", "ascii": true, "ascii_size": {"cols": 56, "rows": 16},
     "expect_on_screen": ["Player"],
     "fail_on": ["no_camera_3d", "no_light_3d", "not_in_frustum", "embedded_in_static"]}
  ],
  "assertions": [
    {"assertion": "node_exists", "node_path": "Player/CameraPivot/SpringArm3D/Camera3D"},
    {"assertion": "node_exists", "node_path": "Floor/Floor_col"}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --warnings-as-errors --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_thirdperson.json --log-file /tmp/thirdperson.log --pretty
```

Expected: both static checks clean, and `run_scenario.py` `"ok": true` with all
five assertions passing and both `spatial_report`s at `findings=0`. The first
report is the one that matters — it is the only check that tells you the scene
will not render black:

```
[SCENARIO] spatial_report render-check dim=3d nodes=11 on_screen=10 off_screen=0 screen_space=0 findings=0 camera=Player/CameraPivot/SpringArm3D/Camera3D
```

and in the payload:

```json
{"camera": {"path": "Player/CameraPivot/SpringArm3D/Camera3D", "position": [0, 1.2, 4],
            "forward": [0, 0, -1], "projection": "perspective", "fov": 75},
 "lighting": {"lit": true, "lights": ["DirectionalLight3D"], "environment_light": true,
              "detail": "Lights found: 1. Environment present (ambient_light_source 2, background_mode 1, sky no)."}}
```

The camera reports its **global** position, so `[0, 1.2, 4]` after the fall means
the player is standing at y = 0 and the arm is holding the camera 4 units behind
it. `position:z` below `-1.0` after 0.8 s of `move_forward` is the camera-relative
movement working: with yaw 0 the forward axis is -Z.

Delete the `Sun` node and re-run to see the check earn its place — the scenario
fails with `no_light_3d` and the message names what to add, where a screenshot
would just be dark.

---

## 22. Before You Call It Done

**Goal.** The five commands that decide whether a project is finished, in the
order that finds problems cheapest first. Nothing here is specific to a genre:
point it at whatever you just built.

**Requires.** §20 — every command and every number below was run against the
project **[Playbook 20](#20-grid-puzzle-sokoban)** builds, because that one
already has unit tests and a `puzzle.tscn` to point the scenario at. Point it at
your own project instead and substitute your scene, node paths and
expectations.

### 1. Lint — no Godot needed, under a second

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
```

Wants `"ok": true` with `counts.errors == 0`. This is the only check that runs
without the engine, so run it after every edit, not just at the end. It catches
Godot 3 names, un-inferable `:=`, dead `$Path` / `%Name` / signal targets, input
actions that are not in the input map, group names nothing ever joins, and
`res://` literals pointing at files that do not exist.

### 2. Validate — the engine loading every file, warnings included

```bash
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --warnings-as-errors --pretty
```

Wants `"ok": true`, `counts.errors == 0`, `counts.warnings == 0`,
`static.failed_count == 0`. `--warnings-as-errors` is what makes a GDScript
warning and a node configuration warning (`node_config:body_without_shape` and
friends) fail the command instead of scrolling past. This is also where the
physics-layer survey lives: read `physics_layers.findings` and fix any
`mask_targets_empty_layer` — a mask bit nothing occupies is a query that can
never return a hit.

### 3. Unit tests

```bash
python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --pretty
```

Wants `"ok": true` and `counts.failed == 0`, `counts.errors == 0`. If the answer
is *no test framework found*, that is the finding: run
`run_tests.py /absolute/path/to/project --init-mini` and write the first suite
(`references/testing.md`). Add `--strict` in CI so a test that asserts nothing
counts as `risky` and fails.

### 4. One scenario that looks at the running game

`lint` and `validate` never start the game. This is the step that does, and it
is where the three text read-backs go: the UI layout, the world layout, and the
frame itself.

```bash
cat > /absolute/path/to/project/scenario_final.json <<'JSON'
{
  "scene_path": "res://scenes/puzzle.tscn",
  "viewport_size": {"width": 320, "height": 180},
  "settle_frames": 4,
  "steps": [
    {"type": "ui_report", "label": "hud", "node_path": "HUD", "ascii": true, "fail_on": ["any"]},
    {"type": "spatial_report", "label": "world", "ascii": true, "ascii_size": {"cols": 48, "rows": 12},
     "expect_on_screen": ["Player/Sprite2D"], "fail_on": ["not_on_screen", "zero_scale"]},
    {"type": "dump_tree", "node_path": ".", "properties": ["position", "text"], "max_depth": 3, "label": "tree"},
    {"type": "screenshot", "path": "user://final.png",
     "expect": {"not_blank": true, "min_opaque_ratio": 0.05},
     "describe": {"ascii": true, "ascii_width": 48}}
  ],
  "assertions": [
    {"assertion": "node_exists", "node_path": "Player"}
  ]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_final.json --log-file /tmp/final.log --pretty
```

Wants `"ok": true`, every report `passed`, and the screenshot line reading
`blank=false`:

```
[SCENARIO] screenshot /…/final.png blank=false opaque=1 bbox=8,12,184,100 dominant=#444444
```

- `ui_report` with `"fail_on": ["any"]` is the only thing that catches a UI
  where every control landed on top of the others at (0, 0).
- `spatial_report` is the only thing that catches a player off camera or sunk
  into the floor. Name a node that **draws** something — a bare `Node2D` parent
  has no rect of its own and the step fails with *it has no measurable rect*.
- `screenshot` with `expect.not_blank` is the last line of defence: it is the
  one check that fails when the frame is a single flat colour. Write it to
  `user://` so the PNG never lands in the project and asks to be imported.

### 5. Boot every scene, with the input fuzzed

```bash
python3 /absolute/path/to/godot/scripts/debug/smoke_scenes.py /absolute/path/to/project --all --fuzz --pretty
```

Wants `"ok": true` with `counts.failed == 0`. It runs every `.tscn` in its own
process with the debugger attached and fires the project real InputMap actions
pseudo-randomly, which is how you find the errors no scripted scenario thought
to trigger. It found two in Playbook 19 while this was being written:

```
Function blocked during in/out signal. Use set_deferred("monitoring", true/false)
Removing a CollisionObject node during a physics callback is not allowed
```

both from a pooled bullet retiring inside the `area_entered` callback that hit
it — fixed in `templates/gdscript/projectile.gd` by deferring the two calls.
Per-scene it also reports `perf` (`node_count_start`/`node_count_end`,
`orphan_nodes`), so a scene that leaks nodes while idling shows up as growth.

A **sound still playing when the engine quits** makes Godot print `1 resources
still in use at exit`. That is engine exit bookkeeping, not a defect in the
scene — it shows up on any project with looping music — so this step and
`run_project.py` file it as severity `info`, category `exit_leak`: listed under
`diagnostics`, never an error, never a failed scene.

A **machine with no GPU and no sound card** — a Linux CI runner, a container, a
remote box you SSH into — makes the engine print its failed driver probes as
errors before it falls back, on every run that opens a window (any scenario with
a `screenshot` step):

```text
ERROR: Required Vulkan instance extension VK_KHR_surface not found.
ERROR: Condition "err != OK" is true. Returning: err
WARNING: Your video card drivers seem not to support the required Vulkan version, switching to OpenGL 3.
ERROR: Condition "status < 0" is true. Returning: ERR_CANT_OPEN
WARNING: All audio drivers failed, falling back to the dummy driver.
```

Nothing in the project causes them and nothing in the project can fix them, so
they are filed as severity `info`, category `host_capability` — the two
`WARNING` lines stay warnings, because which renderer you actually got matters.
It matters for more than tidiness: **that fallback swaps the renderer under
you.** A project that asks for Forward+ runs on Compatibility there, so any
shader with a renderer-dependent branch needs the other setting — `water_3d`'s
`compatibility_depth` is the worked example, and setting it from
`ProjectSettings.get_setting("rendering/renderer/rendering_method")` is wrong on
such a host, because the setting still says `forward_plus`. Read the warning, or
compare a screenshot from both settings.

### Two more, for while you are still writing

Neither of these is a gate, but both are cheaper than a failed run:

```bash
python3 /absolute/path/to/godot/scripts/docs/api_lookup.py AnimatableBody2D.sync_to_physics NavigationServer2D.map_get_regions
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"expression":"Vector2(3, 4).length()"}'
```

`api_lookup.py` reads the *installed* engine, so a property that does not exist
comes back as an error with the nearest real names instead of as a silent no-op
three steps later — every property name in Playbooks 18-21 was checked that way
before it was written. `run_gdscript` runs one expression or a snippet with the
project autoloads live, which is the fastest way to settle a formula or read a
value back out of a resource.

### The whole checklist, copy-paste

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --warnings-as-errors --pretty
python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --pretty
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario_final.json --pretty
python3 /absolute/path/to/godot/scripts/debug/smoke_scenes.py /absolute/path/to/project --all --fuzz --pretty
```

Every one of those exits non-zero when it fails, so in CI they chain with `&&`
and need no output parsing at all.

---

<!-- WP10B-END -->

## When A Playbook Fails

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Unknown parameter for <op>: <key> (did you mean …)` | An invented or misremembered field name | Run `help '{"op":"<op>"}'` and copy the parameter list it prints |
| `Parse Error: Identifier "Health" not declared in the current scope` | A `class_name` script added since the last import | `godot --headless --path /absolute/path/to/project --import`, then re-validate |
| `ui_report` finds `overlap` on siblings that should stack in a row | A bare `Control` parent instead of a `Box`/`Grid` container | Insert the container; never fix it by assigning `position` per child |
| `ui_report` finds everything at `[0, 0, …]` | `layout_preset` set on a container's child, or the scene was hand-written as `.tscn` text | Rebuild through `scene_batch`; read `references/tscn_format.md` |
| `%Name` is null at runtime | The node has no `unique_name_in_owner` | Add a `configure_node` action with `"unique_name_in_owner": true` |
| Player falls through the level | Tiles have no collision polygons, or a 3D mesh was never baked | `"collision": "full_cell"` in `build_tileset`, or `bake_collision` on the `MeshInstance3D` |
| Validation reports zero warnings on a project the editor complains about | The debugger is not attached | Keep `--debug --ignore-error-breaks` on the command; do not pass `--no-debugger` |
