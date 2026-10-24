---
name: code-godot
description: Godot 4.x game development (verified on 4.7) - scaffold, inspect and edit projects, scenes, UI, resources headlessly; author tilesets, ASCII-painted levels, themes, animation, audio buses, custom Resources, collision/navmesh bakes, shaders, export presets; draw pixel art from ASCII, clean generated art, synthesize sound effects and looping music; look up the installed engine's exact API; lint GDScript, scenes and shaders without Godot (Godot 3 renames, un-inferable :=, dead node paths, input actions, res:// paths); catch editor-only node warnings; move files safely; unit-test, smoke-run every scene with input fuzzing, debug, export; verify it all as text (node trees, UI layout, 2D/3D placement, level, image, audio read-backs), no vision or hearing needed. Use when Codex needs to build or fix a Godot game, write or repair .gd/.tscn/.tres/.gdshader files, add art, sound, levels or UI, migrate Godot 3 code, reorganize a project, or validate, test and export.
---

# Godot

Use this skill to inspect and modify Godot projects with the bundled workflows, scripts, and any available host-native Godot automation tooling, including gameplay presentation work such as art generation, frame animation integration, and project-native integration of provided or separately generated music and story content.

## Start

### Route By Task

| Task | Read / run | Verify |
| --- | --- | --- |
| New project from nothing | `scripts/project/scaffold_project.py DEST --preset pixel2d\|hd2d\|3d\|ui` (hand-run version: `references/playbooks.md` §1) | its `validate.counts` → `errors` and `warnings` both 0 |
| Any engine class, method, signal or constant you are about to type | `scripts/docs/api_lookup.py CharacterBody2D.move_and_slide` (`references/api_lookup.md`) | exit 0 prints the exact 4.7 signature; a wrong name exits 1 with the nearest real ones |
| Player controller (2D/3D) | `templates/gdscript/player_*.gd`, playbooks §2, §3, §12, §21 | `run_scenario.py` → `"ok": true` |
| Enemy, damage, health, projectiles, waves | `templates/gdscript/{enemy_patrol_2d,enemy_chase_nav_2d,health,hitbox,hurtbox,projectile,shooter,wave_spawner}.gd`, playbooks §4, §19 | `run_scenario.py` → `"ok": true` |
| State machine | `templates/gdscript/{state,state_machine}.gd`, playbook §4 | `run_project.py` → `counts.errors == 0` |
| Tile level | `build_tileset` + `paint_tilemap` `ascii_map`, playbook §5 | `inspect_tilemap` `"format":"text"` rows match |
| Menu / theme | `references/game_ui.md`, playbook §6 | `run_scenario.py` `ui_report` → `findings=0` |
| HUD, pause, dialog, branching dialogue, settings | `templates/gdscript/{hud,pause_menu,dialog_box,dialogue_runner,choice_list,settings,settings_menu,input_remap}.gd`, playbooks §7–§9, §16, §17 | `run_scenario.py` `ui_report` → `findings=0` |
| Items, inventory, loot, save / load | `templates/gdscript/{item_data,inventory,loot_table,inventory_ui,save_manager}.gd`, playbooks §10, §15 | `run_tests.py` → `"ok": true` |
| A whole small game (collectathon, wave shooter, sokoban, 3D third-person) | `references/playbooks.md` §18–§21, finishing checklist §22 | the scripted scenario wins the level; §22's five commands exit 0 |
| Art with no image generator; cleaning generated art | `references/pixel_art.md`, `draw_image`, `process_image`, playbook §14 | payload `frame_reports[*].rows` reads back what you drew; `inspect_image` `expect` |
| Sound effects and music | `references/audio.md`, `scripts/assets/make_sfx.py`, `scripts/assets/make_music.py`, playbook §13 | `inspect_audio` `expect` → exit 0 |
| Shader effect (flash, outline, dissolve, CRT, toon, water…) | `templates/shaders/*.gdshader`, `references/shaders.md` | `check_project` → `failed_count == 0`; screenshot `expect` |
| Scene fades, music, SFX wiring | `templates/gdscript/{scene_transition,audio_manager}.gd`, playbook §11 | `validate_project.py` → `counts.warnings == 0` |
| Writing or editing any `.gd` | `references/gdscript_conventions.md`, then `lint_project.py` | `lint_project.py` → `counts.errors == 0` |
| Project written for Godot 3 | `references/godot3_to_4.md` | `lint_project.py --only godot3_api,godot3_shader` → `counts.errors == 0` |
| Custom data (`class_name X extends Resource`) | `resource_batch` with `script`, typed JSON `__script` | `inspect_resource` → `script_class` |
| Hand-writing `.tscn`/`.tres` text | `references/tscn_format.md` | `inspect_scene` nesting matches intent |
| Moving, renaming or reorganising files | never `mv` — `scripts/project/move_resource.py PROJECT SRC DST` (`--map` for many, `--dry-run` to preview) | its `verify.new_missing == []`, then `validate_project.py` → `"ok": true` |
| Forgot an op's parameters, or what tools exist | dispatcher `help '{}'` / `help '{"op":"add_node"}'` | the printed `command` runs as-is |
| No op fits, or a quick logic check | `run_gdscript '{"code":"return …"}'` (`references/api_lookup.md`) | `"ok": true`; a parse or runtime error exits 1 with `code:<line>` |
| Player falls through the floor, sprite or particles silently do nothing, collisions never fire | `references/node_config.md`, `validate_project.py` | `check_project` → `config_warning_count == 0`, `physics_layers.findings == []` |
| Runtime errors or a project that will not boot | `references/debugging.md` | `run_project.py` → `"ok": true` |
| Errors in scenes and input paths a boot never reaches; leaks, hangs | `scripts/debug/smoke_scenes.py PROJECT --seconds 2 --jobs 4 --fuzz` | exit 0, every `scenes[]` entry `ok` |
| Unit-testing game logic (no addon, no download) | `references/testing.md`, `scripts/test/run_tests.py PROJECT --init-mini` | `"ok": true`, `counts.tests > 0` |
| Verifying anything without vision or hearing | `references/automation_api.md` "Verification Without Vision" | `dump_tree` / `ui_report` / `spatial_report` / `inspect_image` / `inspect_tilemap` / `inspect_audio` |
| Is it on screen, in the floor, lit, in front of the camera (2D/3D) | `references/spatial_verification.md` | `run_scenario.py` `spatial_report` `fail_on` → `findings=0` |
| Packaging a build, from no preset at all | `references/export_targets.md`, `add_export_preset`, `scripts/export/export_project.py` | artifact exists; `scripts/export/serve_web.py DIR --check` → `"ok": true` |

Read only the playbook section or reference the table names; each is self-contained.

- Verify which Godot automation path is available before planning edits. Prefer any native or mapped Godot tools in the host agent. Use the bundled headless dispatcher only for the supported file and scene operations listed below.
- Resolve `project_path` to an absolute project directory when a host tool requires it.
- Normalize scene and resource paths to `res://...` when working directly with the bundled Godot scripts in this skill.
- Inspect unfamiliar projects with any available project-discovery tools, or fall back to reading `project.godot`, scene files, and scripts directly.
- When the task involves art, music, or story, inspect the existing visual style, palette, audio direction, and narrative format before creating new content.
- If the user does not specify a style, preserve any clearly established project direction first. If there is no established direction to follow, default new visual work to a pixel-art style and keep related presentation choices consistent with it.
- Read `references/asset_pipeline.md` only when the task involves generated art, cutouts, or frame animation assets.
- Read `references/architecture_qframework_lite.md` only when the task involves Godot architecture design, modular refactoring, feature boundaries, controller or system or model responsibilities, command and query separation, or QFramework-style structure.
- Read `references/architecture_templates.md` only when you need a ready folder layout or starter skeletons for Godot `GDScript` or `C#` architecture work.
- Read `export_presets.cfg` before planning export work. Reuse the preset names, bundle identifiers, signing settings, and feature tags that already exist instead of inventing replacements.
- Require a local `godot` CLI with shell access before using the bundled dispatcher fallback, runtime runner, or CLI export wrapper. The bundled APIs are designed against the current stable Godot docs and verified on Godot `4.7` (compatible with Godot 4.x).
- Read `references/export_targets.md` only when the task involves packaging, signing, or shipping builds for Android, iOS, Web, Windows, or macOS.
- Copy a template from `templates/gdscript/` instead of writing a player, state machine, HUD, save system, menu, or dialog controller from memory. Each file is Godot 4.7, fully typed, and verified to compile with zero warnings; its header states the scene tree, autoloads, and input actions it needs and gives the `attach_script` call. Templates with a `class_name` need `godot --headless --path /absolute/project --import` once after copying.
- Read `references/playbooks.md` when the task matches a common shape (new project, player, enemy, tile level, menu, HUD, pause, dialog, save/load, transitions, 3D starter, generated sound and art, inventory, branching dialogue, settings, or a whole small game — collectathon platformer, wave shooter, sokoban, third-person 3D). Each playbook is a numbered list of runnable command blocks plus a Verify block with the exact expected result — follow it literally rather than improvising an order. Each opens with a `**Requires.**` line naming the earlier sections to replay first, into the same project; every file a command reads is written by an earlier block (scenarios as heredocs, art by `draw_image`), so never hand-save a fenced block or invent a path. All 22 are replayed, Verify blocks included, by `tests/test_playbooks_replay.py`.
- Run `python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty` before and after touching any `.gd`, `.tscn`, `.tres`, or `.gdshader`. It needs no Godot, finishes in well under a second, and reports what Godot's own messages hide: Godot 3 API, syntax and shader names with the exact 4.x replacement, input actions, groups, `res://` paths and animation names that resolve to nothing, `:=` reads that will not parse, `$Path`/`%Name` references to nodes that do not exist in the scene the script is attached to (with the real children listed), `%Name` without `unique_name_in_owner`, `[connection]` targets whose method is missing, and `ext_resource`/autoload paths that are not on disk. `error` means Godot will refuse to parse or the reference cannot resolve; `warning` means it compiles but is risky.
- Read `references/godot3_to_4.md` when the linter reports `godot3_api`, when a project still carries Godot 3 names, or before writing any API from memory — it is the rename table (nodes, resources, syntax, math, Control properties, signals, file/OS) the linter's rules are generated from.
- Run `help '{}'` through the dispatcher before guessing an operation or parameter name; `help '{"op":"add_node"}'` prints the parameters (`(required)`/`(default: X)` plus value shapes), a runnable example, the gotchas, and a ready-to-paste command. The same listing names every bundled python tool (linter, runners, API lookup, asset generators, file mover, scaffold, export) with a runnable command, so it is the one place to discover what exists.
- Look an engine name up before you type it: `python3 /absolute/path/to/godot/scripts/docs/api_lookup.py CharacterBody2D.move_and_slide Area2D.body_entered String.begins_with KEY_SPACE` prints the installed engine's exact signatures (classes, inherited members, Variant types, globals, theme items via `--kind theme_items`, `--search TEXT` for a half-remembered name). A name that does not exist exits 1 with the nearest real names and, for a Godot 3 name, its 4.x replacement. It has signatures, not prose. Read `references/api_lookup.md` for it and for `run_gdscript`.
- Start a new project with `python3 /absolute/path/to/godot/scripts/project/scaffold_project.py /absolute/new_project --preset pixel2d` (`hd2d`, `3d`, `ui`): settings, input map with keyboard and gamepad, layer names, a main scene (the `3d` one already has a camera, a light and an environment), autoload templates, `.gitignore`, a boot-check scenario — validated with zero errors and zero warnings before it returns.
- Never `mv`, `cp` or rename a file inside a project from the shell: run `python3 /absolute/path/to/godot/scripts/project/move_resource.py /absolute/project art/player.png art/sprites/` (`--map moves.json` for a reorganisation, `--dry-run` to preview). It moves the `.import`/`.uid` sidecars, rewrites every reference, re-imports, and proves with the linter that nothing broke. A bare `mv` can break a project silently: a `uid=` reference keeps loading while its recorded path rots.
- Read `references/node_config.md` when something silently does nothing — a player that falls through the floor, an invisible sprite, particles that never emit, a collision that never fires. `check_project` re-derives the editor's node configuration warnings (the yellow triangles, which no script can read) over every instantiated scene, prints each with a `fix:` that is a runnable dispatcher call, and surveys physics layers and masks across the project.
- Read `references/pixel_art.md` when the task needs sprites, tiles, icons or UI panels and no image generator is available (`draw_image` turns ASCII rows and shapes into a PNG and reads it back character for character), or when generated art has soft edges, off-grid pixels or a baked background (`process_image`: `remove_background`, `trim`, `pixelate`, `quantize`, `pack_frames`, `split_sheet`).
- Read `references/audio.md` when the game needs sound and none was supplied: `scripts/assets/make_sfx.py` (20 sfxr-style presets) and `scripts/assets/make_music.py` (looping chiptune from a preset or a JSON song) write WAVs with nothing but the python standard library, and `inspect_audio` verifies them as numbers, an ASCII envelope and `expect` gates.
- Read `references/shaders.md` and copy from `templates/shaders/` (24 verified `.gdshader` files) instead of writing a shader from memory. A shader that fails to compile renders as the default material with no runtime error, so `check_project` — which compiles every shader and fails the file — is the check, not "it looks fine".
- Read `references/testing.md` when logic is worth a unit test: `scripts/test/run_tests.py PROJECT --init-mini` installs a one-file, zero-download framework; a test killed by a runtime error reads as `error`, never as a pass.
- Read `references/spatial_verification.md` when you need to know where things are in the running game without looking: the scenario step `spatial_report` gives every node's world rect or AABB, what the camera sees, whether a body is embedded in the floor, and whether a 3D scene has a camera and a light at all.
- Read `references/gdscript_conventions.md` before writing or editing any `.gd` file. Generated GDScript must parse and boot first-try: annotate every variable, parameter, and return type, and never use `:=` where the right-hand side has no concrete static type (`$Node`, `%Unique`, `get_node()`, `instantiate()`, `Dictionary`/`Array` reads, `JSON.parse_string()`, `null`, or a call into an untyped function). Godot rejects those at parse time — with `inference_on_variant` shipping set to error — so the project will not start at all.
- Read `references/debugging.md` when the task involves running the project, reading the Godot debugger's errors, and fixing them.
- Read `references/automation_api.md` when using inspection, `resource_batch`, `project_batch`, tileset/tilemap/gridmap/theme/animation/audio-bus authoring, collision/CSG/navmesh baking, glTF export, replication config, unit-test running, import audit, scenario, environment probe, validation, or export preflight APIs.
- Read `references/authoring_recipes.md` when the task involves shaders/ShaderMaterial, particles, environment/sky, fonts, multiplayer replication, 3D import options, GDExtension, or feature tags — it gives the generic-op recipes and lists what is editor-only and must not be attempted headlessly (LightmapGI/occluder/reflection-probe bakes, VisualShader graphs).
- Read `references/vfx_2d.md` when the task involves 2D lighting, particles, parallax, trails, paths, or tile-based levels — it also lists the 4.3+ node deprecations (`TileMap` → `TileMapLayer`, `ParallaxBackground` → `Parallax2D`).
- Read `references/game_ui.md` when the task involves menus, HUDs, dialogs, inventories, or any `Control` work — it gives the container-first layout doctrine (the fix for sibling controls piling up at `(0, 0)`), runnable title/HUD/pause/dialog `scene_batch` skeletons, a complete game `Theme`, and the pixel-art UI rules.
- Read `references/tscn_format.md` whenever a `.tscn` or `.tres` will be written or patched as text — a host without shell access cannot run the bundled dispatcher, or an entire new scene is being authored from scratch. Hand-written node hierarchies fail silently: a tree where every node carries `parent="."` loads with zero errors and stacks every `Control` at (0,0), and `check_project` does not detect it.
- Read `references/tween.md` when adding code-driven juice (punches, fades, shakes); Tweens are runtime-only and ship inside scripts via `attach_script`.
- Read `references/localization.md` when translating game text or wiring translation files (note: POT template generation is editor-only in Godot 4.x).
- Read `references/ci.md` when setting up automated test or export pipelines.
- Install this skill in a folder named `code-godot` so the folder matches its frontmatter name.

## Godot 4.7 Notes

- Verified on `godot 4.7.stable`. The scene and control operations set node properties and instantiate node classes through `ClassDB`, so Godot 4.7 additions work with the existing operations without special-casing: new node types such as `AreaLight3D`, `VirtualJoystick`, and `DrawableTexture2D` can be added with `add_node`/`scene_batch`, and new properties such as the `Control` offset transforms (`offset_transform_enabled`, `offset_transform_position`, `offset_transform_rotation`, `offset_transform_scale`, `offset_transform_pivot` — translate/rotate/scale a control without disturbing container layout) and `CollisionShape2D.one_way_collision_direction` can be set with `configure_node`/`configure_control` using the typed-value format below.
- The runtime runner and log parser key off the stable `SCRIPT ERROR:` / `ERROR:` / `WARNING:` / `Parse Error:` output shapes, so they keep working across Godot 4.x while being verified against 4.7.

## Portable CLI Fallback

Use these paths in shell-capable environments such as Codex when dedicated Godot tools are not exposed.
Replace `/absolute/path/to/godot` with the absolute path to the installed `godot` Skill root.

### Scene Operations Through The Dispatcher

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{"scene_path":"scenes/main.tscn","create_if_missing":true,"root_node_type":"Node2D","actions":[{"type":"add_node","node_type":"Camera2D","node_name":"Camera"}]}'
```

- Replace `scene_batch` with any supported operation: `inspect_project`, `inspect_scene`, `inspect_resource`, `resource_batch`, `project_batch`, `audit_imports`, `set_import_options`, `build_tileset`, `paint_tilemap`, `paint_gridmap`, `build_theme`, `bake_collision`, `collision_from_sprite`, `bake_csg`, `gltf_export`, `build_replication_config`, `build_animation`, `build_animation_tree`, `setup_audio_buses`, `scene_batch`, `create_scene`, `add_node`, `instantiate_scene`, `configure_node`, `configure_control`, `attach_script`, `connect_signal`, `disconnect_signal`, `remove_node`, `reparent_node`, `reorder_node`, `load_sprite`, `build_sprite_frames`, `save_scene`, `export_mesh_library`, `get_uid`, `resave_resources`, `check_project`, `inspect_tilemap`, `inspect_image`, `inspect_audio`, `draw_image`, `process_image`, `run_gdscript`, `add_export_preset`, or `help`. Navigation-mesh baking is a `resource_batch` `bake_navmesh` action; global shader uniforms are `project_batch` `set_shader_global` actions.
- Every `help` example is executed on every test run against one small coherent project (the catalog's `_example_world` note describes it: `scenes/main.tscn` with `root/Player`, `scenes/menu.tscn` with `root/Panel/StartButton`, `scenes/kit.tscn`, `scenes/dungeon.tscn`, …), so the printed `command` runs as written once those files exist. `connect_signal` refuses a method the target's script does not declare — put `attach_script` before it in the same `scene_batch`; `bake_csg` is the one scene operation that is not a `scene_batch` action; `gltf_export` fails on a scene with no 3D meshes.
- Run `help '{}'` to list every operation with a one-line summary, and `help '{"op":"add_node"}'` for one operation's parameters — each with `(required)`/`(default: X)` and its value shape — plus a runnable `example`, `notes`, and `command`, the complete shell line with the example inlined. A batch operation also prints one schema per `actions[*].type`. Add `"format":"text"` for a compact plain-text rendering.
- An unknown operation or parameter name is rejected with the nearest valid names and the `help` command that prints the right ones (`Unknown operation: scene_bacth (did you mean scene_batch, save_scene?). Run: help '{}' to list operations`), so a misspelling never turns into a silent no-op.
- Every dispatcher operation exits `0` on success and `1` after any logged error, so shell callers can gate on the exit code.
- Pass parameters as a single JSON object using the snake_case field names expected by the bundled GDScript. A key the operation does not read is rejected with the nearest valid names suggested (`Unknown parameter for add_node: parent_path (did you mean parent_node_path, ...)`), and nothing is written — an unrecognised key used to be ignored silently, so the operation fell back to its default and still reported success. The same check applies to each entry of a batch `actions` array; the free-form value dictionaries inside a parameter (`properties`, `constants`, `colors`, …) are never checked, since those keys are project data. `--skip-param-check` after the JSON disables the check.
- A key that belongs to a *different* operation or batch action is rejected too (`Misplaced parameter for scene_batch action "configure_node": actions[0].script_properties is not read by it (it belongs to: attach_script); did you mean properties?`). It used to be accepted, ignored, and reported as saved.
- The dispatcher covers file, scene, and static-validation operations. It does not run gameplay or export builds: use the runtime runner (`scripts/debug/run_project.py`) to run and capture debugger errors, and the export wrapper (`scripts/export/export_project.py`) for builds.

### Run And Capture Debugger Errors

```bash
python3 /absolute/path/to/godot/scripts/debug/run_project.py \
  /absolute/path/to/project scenes/main.tscn \
  --quit-after 120 --timeout 60
```

- Runs the project headlessly for a bounded number of frames, captures the exact stdout/stderr the Godot debugger prints, and returns JSON: `ok`, `counts`, and a `diagnostics` array where each entry has `severity`, `category`, `message`, `file`, `line`, `function`, `stack`, and a `suggested_fix`.
- The scene is the optional second positional argument (`scenes/main.tscn` above, or `res://scenes/level.tscn`): it runs and debugs just that scene. Drop it to boot the project's `run/main_scene`, which is what a player's launch does — a project with no main scene then has nothing to run and sits there until `--timeout`. Add `--no-headless` when an error only appears with real rendering, `--log-file <path>` to persist the raw log, and `--no-warnings` to drop warnings.
- Two kinds of engine noise are downgraded to severity `info` and never count as an error or flip `ok`. **`exit_leak`**: shutdown bookkeeping — `N resources still in use at exit`, `ObjectDB instances were leaked at exit` — which looping music still playing when `--quit-after` fires produces on every run. **`host_capability`**: a display or audio driver's own failed probe on a machine with no GPU or no sound card (a container, a CI runner, a box you SSH into) — `Required Vulkan instance extension VK_KHR_surface not found` and the `Condition … is true` assertions that follow it. Nothing in the project causes those and nothing in the project can fix them; the two `switching to OpenGL 3` / `falling back to the dummy driver` lines stay **warnings**, because the fallback swaps the renderer under you: `ProjectSettings.get_setting("rendering/renderer/rendering_method")` still reports `forward_plus` there, and only `RenderingServer.get_current_rendering_method()` tells you what you actually got.
- Runs Godot with `-d --ignore-error-breaks`. GDScript warnings (unused variable, shadowed variable, integer division, standalone expression, …) reach stdout only through the script debugger channel, so a plain headless run reports none of what the editor's Errors panel shows; `--ignore-error-breaks` keeps `-d` from stopping at an interactive `debug>` prompt on the first error. Pass `--no-debugger` to opt out. See `references/debugging.md` for the full run→diagnose→fix→re-run loop and a message→cause→fix table.

### Validate Scripts And Scenes Without Running

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
```

- Run the linter first: it needs no Godot, and its diagnostics carry the fix (`KinematicBody2D → CharacterBody2D; set velocity then call move_and_slide() with no arguments`, `Panel has children: Title, Icon`). Categories: `godot3_api`, `godot3_shader`, `inference`, `node_ref`, `unique_name`, `signal_target`, `missing_resource`, and the cross-reference pass `input_action`, `group_ref`, `res_path`, `animation_ref` — names that resolve to nothing, which Godot never reports: an action no `[input]` entry, built-in `ui_*` or `InputMap.add_action` defines (error, with the defined actions, the nearest name, and the `project_batch` command that creates it), a group nothing ever joins, a `res://` literal that is not on disk (case-sensitively, so a macOS pass means a Linux pass), an animation the node's `SpriteFrames`/`AnimationLibrary` does not hold, and Godot 3 shader names (`hint_color`, `SCREEN_TEXTURE`, `WORLD_MATRIX`, …) with their verified 4.x replacement. Silence one line with `# lint:ignore <category>` on it or on the line above (`;` in `.tscn`, `//` in `.gdshader`); unused suppressions are listed under `suppressions.unused` and never fail the run. A folder holding a `.gdignore` is skipped, as Godot skips it. `--only cat1,cat2` narrows, `--warnings-as-errors` makes warnings fail the run, `--path subdir` scopes it. Output is the same `{ok, counts, diagnostics[]}` shape as the runtime parser. `validate_project.py` runs the same lint pass first and merges its findings (`--no-lint` opts out).

```bash
godot --headless --debug --ignore-error-breaks --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  check_project '{}' 2>&1 \
  | python3 /absolute/path/to/godot/scripts/debug/godot_log_parser.py -
```

- `check_project` statically loads every GDScript, scene, shader, resource, GDExtension, and editor plugin (or just a `{"project_path":"subdir"}` subtree) and prints a JSON summary of failures. Piping its combined output through `godot_log_parser.py` yields line-level diagnostics. Keep `--debug --ignore-error-breaks` on the command: because this loads every file, it is the pass that reports the warnings of every script, and without it Godot emits no warnings at all.
- Scenes are instantiated as well as loaded (`{"instantiate": false}` opts out). `load()` accepts every broken node hierarchy; only `PackedScene.instantiate()` returns null on a root that carries `parent=` or a non-root node with no `parent=` (`ERROR: Invalid scene: …`, reported in `failed[]`), and only instantiating prints the `WARNING: Parent path … has vanished` a mistyped `parent=` produces. A fully flat tree is still valid and silent — only `inspect_scene` catches it. Instantiating runs each scene root script's `_init()` and its stored-property setters, not `_ready`; autoloads are available, so that is not a source of false failures.
- The same pass reports node configuration warnings — the editor's yellow triangles, re-derived because `Node.get_configuration_warnings()` is not callable from a script: a body with no shape, a `CollisionShape2D` with no `shape`, an `AnimatedSprite2D` with no frames, particles with no material, a `PathFollow2D` under the wrong parent, a `ScrollContainer` with two children, a 3D scene with no camera or light (hint). Each line is `WARNING: [node_config:<rule>] <scene>::<node_path>: <message>` followed by `fix:` and a runnable dispatcher call; the payload carries `config_warnings[]`, `config_warning_count`, and a project-wide `physics_layers` survey whose `mask_targets_empty_layer` finding is the usual reason a collision never fires. `{"config_warnings": false}` / `{"physics_layers": false}` opt out; `inspect_scene` takes `"config_warnings": true` for one scene. See `references/node_config.md`.
- A `failed_count` of 0 is not by itself a pass. Godot degrades gracefully where the editor is fatal (a scene with a missing `[ext_resource]` still loads and instantiates), so read the parsed diagnostics too.
- Shaders are compiled, not just loaded: `check_project` assigns each `.gdshader` to a `ShaderMaterial` to force the compile, because `load()` alone accepts a file full of syntax errors. A shader that does not compile is a `failed[]` entry with its line and message, and the op exits 1 — at draw time the engine would silently fall back to the default material. The resulting `SHADER ERROR:` carries no path of its own, so the op prints a `Compiling shader: <path>` marker that `godot_log_parser.py` uses to attribute it — keep the two on the same captured stream.
- Run `python3 scripts/debug/validate_project.py /absolute/project --pretty` for the comprehensive pass: it runs `check_project` with the debugger attached and scene instantiation on, parses the captured log into `counts`/`diagnostics`, refuses to report `ok` while any error-level diagnostic is present, and builds C# solutions when a `.csproj` exists. Add `--warnings-as-errors` to make warnings fail the run (this is what turns a vanished-parent warning into a failure); `--no-instantiate` skips the instantiate pass.
- Use `godot_log_parser.py` on its own to structure any Godot log you already have: `python3 /absolute/path/to/godot/scripts/debug/godot_log_parser.py path/to/run.log`.
- Run every script you generate or edit through this pass before finishing. Parse errors are the most common cause of a project that will not boot, and `references/gdscript_conventions.md` plus the table in `references/debugging.md` map each message Godot emits to its cause and fix.
- After adding any script with a `class_name`, run `godot --headless --path /absolute/path/to/project --import` before validating. Global class names resolve from `.godot/global_script_class_cache.cfg`, which a `--script` run does not rebuild — until then every other script referencing the new class fails with `Parse Error: Identifier "Foo" not declared in the current scope.`

### Probe And Run Deterministic Scenarios

```bash
python3 /absolute/path/to/godot/scripts/debug/probe_environment.py /absolute/path/to/project --pretty
```

A scenario is a JSON file you write next to the project and hand to the runner:

```bash
mkdir -p /absolute/path/to/project/scenarios
cat > /absolute/path/to/project/scenarios/boot_check.json <<'JSON'
{
  "scene_path": "res://scenes/existing_ui.tscn",
  "viewport_size": {"width": 320, "height": 180},
  "settle_frames": 4,
  "steps": [
    {"type": "dump_tree", "properties": ["text"], "label": "tree"},
    {"type": "assert", "assertion": "property", "node_path": "StatusLabel",
     "property": "text", "expected": "Pending"},
    {"type": "ui_report", "ascii": true, "fail_on": ["zero_size", "offscreen"]}
  ]
}
JSON
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenarios/boot_check.json --pretty
```

- Use the environment probe before platform or native-code work to report the Godot version, CLI capabilities, export templates, host tools, and project languages/extensions/plugins.
- Use `run_scenario.py` for action/key/mouse/joypad input, NodePath property assertions, log assertions, `dump_tree` node-tree dumps, `ui_report` text UI dumps, Viewport PNG capture, and performance thresholds. It selects rendered mode automatically when screenshots are present and stays headless otherwise. Screenshot steps also return a text `summary` of the PNG (blank / opaque ratio / content bbox / dominant colours) and accept `expect` gates such as `{"not_blank": true, "min_opaque_ratio": 0.1, "max_diff_ratio": 0.02, "compare_to": "res://ref.png"}`, so a caller that cannot look at images still verifies the render.
- Start any scenario against an unfamiliar scene with a `dump_tree` step — it prints the indented node tree with the properties you name and returns `tree_dumps[]`, which is where the exact `node_path` values for later `assert` steps come from. Pass `"ascii": true` to a `ui_report` step for a character map of the laid-out screen (named boxes, children drawn over parents) when the rect list alone does not show where controls sit.
- An `action` step only moves polled input state (`Input.is_action_pressed`); it never fires `_input`/`_unhandled_input`/`_gui_input`, so pause menus, dialog advance, and interact prompts need a `key` step. Built-in `ui_*` actions match `keycode`; actions this skill creates match `physical_keycode`. `wait_frames` counts process frames, which run far faster than the physics tick headless — use `wait_seconds` or `wait_until` for anything driven by gravity, `move_and_slide`, or a Tween.
- Add a `spatial_report` step to read the game **world** as text: every 2D node's world rect and whether the active camera sees it, every 3D node's AABB, `in_frustum` and `screen_pos`, plus a top-down ASCII map (`"ascii": true`). `{"type": "spatial_report", "expect_on_screen": ["Player"], "fail_on": ["not_on_screen", "embedded_in_static"]}` catches a player spawned outside the view or inside the floor; `"fail_on": ["no_camera_3d", "no_light_3d", "not_in_frustum", "behind_camera"]` covers the four reasons a 3D scene renders an empty frame with no error. Headless, no screenshot. See `references/spatial_verification.md`.
- Add a `ui_report` step to read the laid-out UI as text: every visible Control's path, class, and post-layout global rect, plus `findings` for zero-sized, fully offscreen, and overlapping siblings. `"fail_on": ["overlap", "zero_size", "offscreen"]` turns a broken layout into a failed scenario — the reliable way to catch UI where every control stacks at (0, 0). It resolves headless and never forces a rendered window.
- When you cannot look at images, do not rely on screenshots: instrument with `log_marker` plus targeted prints, run the session with `--log-file`, dump `ui_report` at each moment that matters, assert NodePath properties, and parse the log with `scripts/debug/godot_log_parser.py`. For image files, `inspect_image` reports size, blankness, opaque ratio, content bbox, palette size, and an ASCII rendering, and its `expect` block turns those into a pass/fail exit code. For levels, `inspect_tilemap '{"scene_path":"scenes/level.tscn","format":"text"}'` prints the painted `TileMapLayer` or `GridMap` as rows you can compare with what you meant to paint. See "Verification Without Vision" in `references/automation_api.md`.
- A scenario also fails on any error-level line in its log (`SCRIPT ERROR`, parse error, engine `ERROR:`) even when every assertion passed — the result carries the parsed `diagnostics` and `counts`. When the error is the point of the scenario, require it with a `log_assertions` entry (`min_count` ≥ 1) or set the top-level `"log_errors": "allow"`.
- The scenario's top-level keys are `scene_path`, `viewport_size`, `settle_frames`, `steps`, `assertions`, `log_assertions`, `log_errors`, `performance_frames`, `performance_assertions` (plus free-form `name`/`description`/`comment`/`notes`); any other key — `scene` for `scene_path` — fails the run and names these.
- Read `references/automation_api.md` for the scenario and assertion schema.

### Smoke-Run Every Scene, And Unit Tests

```bash
python3 /absolute/path/to/godot/scripts/debug/smoke_scenes.py /absolute/path/to/project --seconds 2 --jobs 4 --pretty
```

The unit-test runner installs the bundled framework on first use, then runs it:

```bash
python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --init-mini
python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/path/to/project --pretty
```

- `smoke_scenes.py` boots every `.tscn` in its own Godot process for `--seconds` of game time (`--fixed-fps` makes that nearly free: 13 scenes × 3 s in about a second) and reports per scene `{ok, diagnostics[], findings[], perf{}}`. It reaches what `run_project.py` (main scene only) and `check_project` (never runs `_ready`/`_process`) cannot: the pause menu's `_ready`, level 3, the game-over screen.
- `--fuzz --fuzz-mouse --fuzz-seed 7` replays the project's own InputMap actions and clicks visible `Button`s through real input events; the same seed replays the same events. It is what finds `Function blocked during in/out signal`-class bugs no scripted scenario hits. Findings beyond the log: `node_growth` (a spawner that never frees), `orphan_nodes`, `timed_out`, `crashed`, and informational `scene_changed` / `quit_called`.
- `run_tests.py` auto-detects GUT, GdUnit4, then the bundled zero-install runner. `--init-mini` copies `res://tests/test_case.gd` plus an example suite into the project; write suites as `extends "res://tests/test_case.gd"` with `func test_*()` methods (`assert_eq`, `watch_signals` + `assert_signal_emitted`, `add_scene`, `await wait_physics_frames(45)`, `press_action`). A GDScript runtime error aborts a test function without raising, so the runner brackets each test and reports it as `error` with the engine's file:line; a test with no assertion is `risky`, a hung one `timeout`, and running zero tests is never a pass. See `references/testing.md`.

### Make Art And Sound

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{"output_path":"art/coin.png","palette":{"o":"#1a1c2c","y":"#ffcd75","w":"#f4f4f4"},"rows":[".oooo.","oywyyo","oyyyyo","oyyyyo","oyyyyo",".oooo."],"scale":1}'
python3 /absolute/path/to/godot/scripts/assets/make_sfx.py --preset coin --out /absolute/path/to/project/audio/
python3 /absolute/path/to/godot/scripts/assets/make_music.py --preset overworld --out /absolute/path/to/project/audio/
```

- `draw_image` writes a PNG from ASCII rows (one character, one pixel) or ordered `shapes`; `frames` packs a spritesheet and returns the `grid` `build_sprite_frames` takes; `mirror_x`, `outline`, `palette_name` (`pico8`, `sweetie16`, `db16`, `db32`, `endesga32`, `gameboy`, `nes`, …) and `tile_check` do the rest. The payload reads the written file back as the same characters. `process_image` runs an ordered pipeline over one image, a list or a directory — `pixelate` + `quantize` + `alpha_threshold` turns soft generated "pixel art" into a true grid with a fixed palette. Any error writes nothing. See `references/pixel_art.md`.
- `make_sfx.py --list-presets` shows the presets (coin, jump, laser, explosion, hit, powerup, blip, confirm, cancel, footstep, …) and their parameters; `make_music.py --preset menu|overworld|battle|victory` renders a seamlessly looping WAV from a JSON song you can edit. Both print an `expect` block: paste it into `inspect_audio '{"audio_path":"audio/coin.wav","expect":{…}}'` and a silent, clipped or wrong-length sound exits 1. Looping needs `set_import_options` `{"edit/loop_mode": 2}` plus a re-import. See `references/audio.md`.
- Everything written has no `.import` sidecar yet: run `godot --headless --path /absolute/path/to/project --import` before a `.tscn`/`.tres` points at it.

### Project Export Through The Wrapper

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  add_export_preset '{"platform": "windows"}'
```

That writes the preset under the platform's conventional name — `Windows Desktop`, `Web`, `macOS`, `Linux` — which is the name the wrapper takes:

<!-- replay: skip — export-templates (a real export needs the 4.7 Windows template installed) -->
```bash
python3 /absolute/path/to/godot/scripts/export/export_project.py \
  /absolute/path/to/project \
  "Windows Desktop" \
  /absolute/build/windows/game.exe
```

- The wrapper resolves absolute paths, creates the output directory, and shells out to `godot --headless --path ... --export-release ...`.
- After a run that exits `0` it verifies an artifact actually exists at the output path and fails otherwise. Godot's exporter has reported success while writing nothing (a missing template variant, an unwritable target), so the exit code alone is not proof of a build.
- No preset yet? Create one without the editor: `add_export_preset '{"platform":"web"}'` (`web`, `windows`, `linux`, `macos` are verified by real exports; `android`/`ios` are written and come back `"verified": false` with the missing prerequisites). It edits `export_presets.cfg` as text, so presets you did not name keep their exact bytes. Every preflight blocker names its fix on stderr and in `fixes[]`.
- Test a Web build with `python3 /absolute/path/to/godot/scripts/export/serve_web.py /absolute/build/web --check` (cross-origin isolation headers, `application/wasm`); never open one from `file://`. Boot a native artifact to prove it runs: `Game.app/Contents/MacOS/<Name> --headless --quit-after 20` — a build with no `run/main_scene` hangs instead of erroring.
- Run with `--preflight-only` before changing or executing a preset. Real exports preflight by default; use `--skip-preflight` only after independently verifying the environment.
- Pass `--mode debug` for smoke builds, `--mode pack` for a `.pck`/ZIP data export, or `--mode patch --patches base.pck` for a changed-files patch.
- Platform support comes from the preset name already defined in `export_presets.cfg`. Common platforms include Android, iOS, Web, Windows Desktop, Linux, macOS, dedicated server presets, and visionOS.

## Follow The Main Workflows

### Design Or Refactor Architecture

1. Identify the bounded context or feature slice before moving files. Name it by business capability, not by scene title or widget name.
2. Inspect the current scripting language, autoloads, scene tree, and feature directories before proposing a new structure. Adapt to an existing architecture when one is already coherent.
3. In Godot projects, treat scene scripts, input handlers, and UI binding code as `Controller`-edge work; keep domain state in `Model` types or state-owning services; keep reusable workflows in `System`; and keep persistence, HTTP, SDK, serialization, clocks, or platform adapters in `Utility`.
4. For non-trivial features, put writes behind explicit commands or command-like use cases and keep complex reads in queries or read services instead of bloating node scripts.
5. Prefer typed signals, events, or observable state for upward notification after state changes. Do not use global singletons as catch-all mutable state bags.
6. Read `references/architecture_qframework_lite.md` for the responsibility map and review rules, then `references/architecture_templates.md` for Godot-oriented skeletons and folder layouts when you need concrete scaffolding.
7. After refactors, run the project or the deepest available smoke test and confirm scene scripts, autoload wiring, and feature entrypoints still load cleanly.

### Build Or Modify A Scene

1. Prefer `scene_batch` for multi-step work so the scene loads once, actions run in memory, and the scene saves only if every action succeeds.
2. Use `create_scene` when you only need a root scene, then follow with standalone operations if batching is unnecessary.
3. Use `add_node` or `instantiate_scene` to build structure, `configure_node` for general properties and metadata, `configure_control` for `Control` layout and theme overrides, and `attach_script` plus `connect_signal` to finish behavior wiring.
4. For `Control` work, read `references/game_ui.md` and build the layout out of containers before touching anchors. A bare `Control` does not position its children, so absolutely-positioned siblings all resolve to `(0, 0)` and overlap — that single mistake is the most common cause of broken game UI.
5. Keep `load_sprite` for compatibility, but prefer `configure_node` for direct `texture` assignment on sprite-compatible nodes.
6. Run the project after non-trivial edits instead of assuming the scene still loads. If any part of the scene was hand-written as text, also run `inspect_scene` and confirm the reported node `path`s nest as intended — `check_project` and a clean boot both pass on a silently flattened hierarchy (see `references/tscn_format.md`).
7. After any functional change, actively open the game and exercise the changed feature or flow instead of stopping at a successful boot. Check whether the behavior matches the request, whether the UI or gameplay state updates correctly, and whether obvious regressions or bugs appear.
8. After the validation run, inspect the logs for `error` and `warning` output. If the feature misbehaves or either log level appears, treat the task as unfinished, fix the issue, and rerun until the behavior and logs are both clean.

### Add Art, Music, Or Story

1. Reuse the project's existing art pipeline, palette, sprite sizing, font choices, audio buses, dialogue system, localization format, and cutscene structure before inventing new conventions.
2. If the request does not specify a style and the project does not already establish one, default new visual content to pixel art. Keep sprites, tiles, UI embellishments, VFX, and promo-style mockups coherent with that direction.
3. For generated sprite-like art, use the `imagegen` skill first and request transparent `png` output. With no image generator, draw it: `draw_image` takes ASCII rows and shapes and is enough for sprites, frame sheets, tilesets, icons and 9-patch panels (`references/pixel_art.md`). If transparent output is unavailable or unreliable, fall back to a flat chroma-key background and remove it with `process_image` (`remove_background`, then `trim`; `pixelate` + `quantize` when the result is soft or off-grid) — `scripts/assets/chroma_key_cutout.py` is the Pillow/NumPy alternative.
4. Use pure green `#00FF00` as the default chroma-key background so AI-generated assets are easier to cut out locally. If the subject itself contains strong green regions, switch to pure magenta `#FF00FF`. Avoid gradients, shadows, white, or black backgrounds when the next step is Python cutout.
5. After local cutout or repair work, write the final PNG frames back into the Godot project tree and reference them with project-relative paths such as `res://textures/...` before calling `load_sprite` or `build_sprite_frames`.
6. Check every generated or cut-out image with `inspect_image` before wiring it up: `{"image_path": "textures/hero.png", "expect": {"not_blank": true, "has_alpha": true}}` catches an empty generation and a chroma-key pass that did nothing, and `{"image_paths": ["textures/hero_idle"], "expect": {"frames_consistent": true}}` catches a frame sequence that changed canvas size before `build_sprite_frames` bakes it in.
7. For music and SFX, prefer integrating provided or separately generated audio through the project's existing import settings, audio buses, and player nodes instead of inventing a new audio pipeline. When no audio was provided, do not ship a silent game: `scripts/assets/make_sfx.py` and `scripts/assets/make_music.py` synthesize effects and a looping track, and `inspect_audio` with the `expect` block they print is how you confirm a sound you cannot hear (`references/audio.md`).
8. Implement story content through the project's existing dialogue, quest, event, or cutscene data flow when possible. This skill guides integration, not open-ended narrative system generation. If none exists, add only the smallest linear dialogue or event path needed to make the request playable unless the user explicitly asks for a larger system.
9. Default frame animation delivery to independent frame files instead of sprite sheets so frames are easier to cut out, repair, and validate individually.
10. Wire new assets and narrative content into a reachable gameplay path instead of leaving them as unused files in the repository.
11. Run the game and verify that visual assets render at the intended scale, music and SFX trigger correctly, and story content is reachable and readable without runtime errors. When you cannot look at the running game, `inspect_image` on the source art plus a scenario `screenshot` step with `expect` is the substitute.

### Run And Debug

1. Use host-native runtime tools such as `run_project`, `get_debug_output`, or `stop_project` when the host agent exposes them. Otherwise use the bundled runner to capture the debugger's errors as structured diagnostics: `python3 /absolute/path/to/godot/scripts/debug/run_project.py /absolute/path/to/project --quit-after 120 --timeout 60`.
2. Read the returned `diagnostics` and fix in order: parse errors first, then resource/load errors, then runtime script errors, then warnings — a single parse error usually cascades into several later errors. For each entry, open `file` at `line`, use `function`/`stack` for context, and apply the fix indicated by `category`/`suggested_fix` (details and a message→cause→fix table are in `references/debugging.md`).
3. When the host exposes input, browser, window, screenshot, or desktop automation tools, use them to interact with the running game so you can verify the changed feature in a live session instead of relying only on static inspection.
4. Re-run the same command after fixing and confirm `"ok": true` with `counts.errors == 0` and `counts.parse_errors == 0`. Do not assume the fix worked — the runner is the check. A `"timed_out": true` result is itself a finding (a hang or infinite loop).
5. Boot every scene, not only the main one: `python3 /absolute/path/to/godot/scripts/debug/smoke_scenes.py /absolute/path/to/project --seconds 2 --jobs 4 --fuzz` runs each `.tscn` in its own process with seeded input and reports errors, hangs, leaks and crashes per scene.
6. Do not stop at a successful launch. Verify the implemented behavior in the running game, then read the diagnostics from the validation run and fix any reported `error` or `warning` before you finish. For a fast whole-project sanity pass without running gameplay, use the `check_project` operation to load every script and scene and surface parse/load failures; widen coverage for code paths a short boot never reaches by running the specific scene or raising `--quit-after`.
7. Launch Godot with `-d --ignore-error-breaks`, never `-d` on its own: without `-d` the engine reports no GDScript warnings at all, and without `--ignore-error-breaks` the local debugger stops at an interactive `debug>` prompt on the first error (the bundled runners already pass both and redirect stdin from `/dev/null`). If a full interactive test is not possible in the current environment, still launch the project when feasible, perform the deepest smoke test available, and state exactly what you could not verify.

### Prepare And Export Builds

1. Read `export_presets.cfg`, `project.godot`, and any existing CI scripts before editing build settings. Preserve the project's preset names and signing flow whenever possible.
2. Confirm that the local Godot version matches the project's export templates and that the required platform SDKs or certificates are already configured for the target preset.
3. Prefer the bundled wrapper at `scripts/export/export_project.py` for repeatable CLI exports, and use `--mode debug` before `--mode release` when you need a quick device, browser, or desktop smoke test.
4. Keep export outputs outside the project root unless the repository already stores them in a known build directory.
5. When the user asks for Android, iOS, Web, Windows, Linux, macOS, dedicated server, or visionOS builds, read `references/export_targets.md` for the platform-specific checklist before changing presets or signing settings.
6. Do not hand-write `export_presets.cfg`. Patch the existing preset file, or create a preset headlessly with `add_export_preset '{"platform":"web"}'`, whose per-platform option blocks were derived from real exports on 4.7.

### Use The Specialized Operations

- Use `scene_batch` as the default scene editing entrypoint for script and UI work.
- Use `configure_control` when a `Control` node needs presets, anchors, offsets, size flags, minimum size, or theme overrides.
- Use `attach_script`, `connect_signal`, and `disconnect_signal` to wire scene logic without hand-editing `.tscn` files. When a host cannot run the dispatcher at all, follow `references/tscn_format.md` for the text format and its mandatory verification loop.
- Use `remove_node`, `reparent_node`, and `reorder_node` to refactor hierarchy after the scene already exists.
- Use `build_sprite_frames` to turn a frame directory or explicit frame list into a `SpriteFrames` resource on an `AnimatedSprite2D`.
- Use `export_mesh_library` to build a `MeshLibrary` from a 3D scene for `GridMap`.
- Use `get_uid` to inspect a resource UID sidecar and any engine-reported UID metadata when a project uses `.uid` files.
- Use `resave_resources` or the server's equivalent project-wide resave operation to attempt `.uid` sidecar regeneration, then verify the reported created and still-missing counts instead of assuming every resave produced a UID.
- Use `run_project.py` to run the project and capture the debugger's runtime errors as structured diagnostics, and `check_project` to validate that every script, scene, shader, and resource compiles, loads, and — for scenes — instantiates.
- Use `inspect_project`, `inspect_scene`, and `inspect_resource` before editing unfamiliar projects; request full file lists or property schemas only when needed.
- Use `resource_batch` for transactional Resource creation, duplication, property/indexed-property updates, metadata, builder-method calls (`call_method` for APIs like `Gradient.add_point`, `Theme.set_color`, `Animation.add_track`, `TileSet.add_source`), and save. It creates engine resources with `resource_type` and custom ones with `"script": "res://items/item_data.gd"` (a `class_name X extends Resource`); `duplicate_from` keeps the script. `inspect_resource` reports `script_path`, `script_class`, and `script_properties` for script-backed `.tres` files, so a custom resource's real type and accepted properties are verifiable as text.
- Use `project_batch` for structured ProjectSettings, InputMap, autoload, layer-name, main-scene, and translation edits.
- Use `audit_imports` or `scripts/import/import_project.py` to detect missing, invalid, stale, and orphaned import artifacts and optionally reimport first.
- Use `validate_project.py` for GDScript/C#/GDExtension/plugin validation, and `run_scenario.py` for deterministic behavior, text UI-layout (`ui_report`), screenshot, log, and performance checks.
- Use `build_tileset` to author a `TileSet` (atlas sources, exposed tiles, per-tile collision/custom-data/terrains via `tile_defaults`) and `paint_tilemap` to assign it and paint/fill/erase cells or run `terrain_fills` autotiling on a `TileMapLayer`. Tiles without collision polygons are decorative — pass `"collision": "full_cell"` for solid ground.
- Use `paint_gridmap` to paint a `GridMap` (the 3D parallel to `paint_tilemap`) from a `MeshLibrary` built with `export_mesh_library`.
- Design levels as ASCII. `paint_tilemap` takes `"ascii_map": {"legend": {"#": {"source_id": 0, "atlas_coords": {"x": 0, "y": 0}}, ".": null}, "rows": ["#####", "#...#", "#####"], "origin": {"x": 0, "y": 0}}` and `paint_gridmap` takes `"ascii_layers": [{"y": 0, "rows": [...]}]` with the same `legend`. Rows are top-to-bottom (y, or z for GridMap), characters left-to-right (x); `.` and space leave a cell untouched (`"erase_unlisted": true` clears them instead). An unknown legend character aborts the paint and leaves the scene on disk untouched, so a typo can never half-paint a level. Write the map as a picture instead of a coordinate list — a wrong coordinate list looks fine, a wrong picture does not.
- Use `inspect_tilemap` to read a `TileMapLayer` or `GridMap` back as rows (`"format":"text"`) or as JSON with a `legend` you can paste straight back into a paint call; it auto-picks the node when `node_path` is omitted. A terrain fill that matches no tile paints nothing and now warns (`[WARN] ... left N of M cells empty`) — give the tiles peering bits in `build_tileset` or paint `source_id` + `atlas_coords` directly.
- Use `inspect_image` to read any PNG as numbers (size, `blank`, `opaque_ratio`, `content_bbox`, `dominant_colors`, `unique_colors`, quadrant occupancy) and optionally as ASCII, and gate it with `expect` (`not_blank`, `has_alpha`, `max_unique_colors`, `width`/`height`, `compare_to` + `max_diff_ratio`, `frames_consistent` over `image_paths`). JPEG input gets `background_tolerance` 0.12 by default so codec ringing stays out of `content_bbox`; pass it explicitly for lossy WebP.
- Use `build_theme` to author a `Theme` grouped by control type (inline styleboxes, hex or typed colors, type variations); wire it project-wide with `project_batch` `set_setting` on `gui/theme/custom`. Author every interactive state (`normal`/`hover`/`pressed`/`focus`/`disabled`), not just `normal`; see `references/game_ui.md`.
- Use `bake_collision` to generate a `StaticBody3D`/`CollisionShape3D` from a `MeshInstance3D` (trimesh/convex/multi_convex), `collision_from_sprite` to trace `CollisionPolygon2D` shapes from a sprite's alpha, and `bake_csg` to freeze a `CSGShape3D` tree into a static mesh (+ optional collision, optional in-place replacement).
- Use `resource_batch` `bake_navmesh` to bake a `NavigationPolygon` (2D) or `NavigationMesh` (3D) from procedural outlines/faces (sync bake, headless-safe), then assign it to a `NavigationRegion2D/3D` with `configure_node`.
- Use `gltf_export` to write a `.glb`/`.gltf` from an edited scene, `project_batch` `set_shader_global` to author `[shader_globals]` uniforms, and `build_replication_config` to author a `SceneReplicationConfig` for a `MultiplayerSynchronizer`.
- Use `build_animation_tree` for AnimationPlayer-backed state machines (states, transitions, auto Start wiring), and `set_import_options` to patch `.import` params such as audio loop modes before a reimport.
- Use `build_sprite_frames` with `spritesheet` + `grid` + `animations` to slice an atlas into multiple named animations with per-frame durations; the legacy one-file-per-frame form still works.
- Use `build_animation` for AnimationPlayer keyframe clips (value/method/bezier tracks) saved standalone and/or attached through an `AnimationLibrary`.
- Use `setup_audio_buses` to create the Master/Music/SFX routing, save the `AudioBusLayout`, and register it in project settings.
- Use `scripts/test/run_tests.py` to run a project's GUT or GdUnit4 suite headlessly with normalized exit codes; Godot has no built-in project test runner.
- It refuses to run when the resolved tests directory holds no test scripts, and reports `test_script_count`. Both frameworks exit `0` when they collect nothing, so a wrong `--tests-dir` otherwise reads as a full pass. Pass `--allow-empty` when an empty suite is genuinely expected.

- Use `scripts/docs/api_lookup.py` before calling any engine API you have not just read, and `run_gdscript` (`code`, `expression`, or `script_path` + `method` + `args`) when no operation fits or a function is worth one quick call: it runs inside the project with autoloads loaded, maps a parse error back to your snippet's line, and cannot report a crashed snippet as success. It is not a sandbox.
- Use `draw_image` / `process_image` for art, `make_sfx.py` / `make_music.py` for sound, `inspect_image` / `inspect_audio` to verify either as text.
- Use `add_export_preset` to create an export preset without the editor, `scripts/project/scaffold_project.py` to create a project, `scripts/project/move_resource.py` for every move or rename, `scripts/debug/smoke_scenes.py` to boot every scene.
- Use the scenario step `spatial_report` next to `ui_report` and `dump_tree`: `ui_report` is the UI's layout, `spatial_report` the world's.

## Typed JSON Values

- Use plain JSON scalars, arrays, and objects for ordinary values.
- Use `{"__resource":"res://path/to/resource"}` to load a Godot resource before assignment.
- Use `{"__resource_type":"InputEventKey","properties":{"physical_keycode":32}}` to instantiate and configure a Resource value. The resource's own properties go under `"properties"`: a key written next to `__resource_type` (`{"__resource_type":"RectangleShape2D","size":…}`) is an error — it used to build a default-sized shape and report success. Add an ordered `"method_calls":[{"method":"add_point","args":[...]}]` for builder-only sub-resources.
- Use `{"__script":"res://items/item_data.gd","properties":{...}}` to build an instance of a project's own `class_name X extends Resource` — `__resource_type` only reaches engine classes. Same `properties`/`method_calls` keys, nests anywhere a resource value is accepted (including `attach_script.script_properties`). A misspelled or wrongly typed export fails the op and names the script's exported properties; untyped JSON arrays are converted into `Array[T]` exports (a raw `set()` silently drops them).
- Use `{"__curve":{"points":[{"x":0,"y":0},{"x":1,"y":1}]}}` and `{"__gradient":{"points":[{"offset":0,"color":"#fff"},{"offset":1,"color":"#000"}]}}` to inline `Curve`/`Gradient` ramps (e.g. particle scale/color) without separate resource files.
- Use typed wrappers for engine value types when the target property is not plain JSON:
  - `{"__type":"Vector2","x":10,"y":20}`
  - `{"__type":"Color","r":1,"g":0.5,"b":0.25,"a":1}`
  - `{"__type":"NodePath","value":"root/Button"}`
- `configure_node.properties`, `configure_node.indexed_properties`, `attach_script.script_properties`, `configure_control.theme_overrides`, and `scene_batch.actions[*]` all accept the same typed-value format.
- A colour may be `"#rrggbb"`/`"#rrggbbaa"` wherever the target is declared `Color`, including `shader_parameter/*` uniforms (assign `shader` first); a string that is not a colour fails the op instead of being stored as `null`.
- Indexed sub-paths use `:` — `{"shadow_offset:x": 4.0}`, `{"material:shader_parameter/tint": "#ff0000"}` — and are walked before anything is written: a hop that does not exist fails with the likely spelling (`"offset/x"` → `did you mean "offset:x"?`, `"content_margin/left"` → `"content_margin_left"`) instead of silently changing nothing.
- An indexed path that reaches into another saved file — `"material:shader_parameter/tint"` on a node whose material is `res://materials/flash.tres` — edits and saves that file too (`Also saved res://…`), as the editor does; a path into an imported file (`texture:…`) is refused because nothing could save it.
- `configure_control.theme_overrides` takes grouped keys (`{"constants": {"separation": 12}}`) or flat ones (`{"constants/separation": 12}`).
- The shared codec also supports Rect/Transform/Plane/Quaternion/AABB/Basis/Projection and packed array values. Read `references/automation_api.md` for the complete surface.

## Scene Editing Surface

- `scene_batch`: sequential multi-action transaction with `create_if_missing`, `root_node_type`, `root_node_name`, `save_path`, and `actions`.
- `create_scene`: create and save a root scene with optional `root_node_name`, `properties`, and `indexed_properties`. An existing `scene_path` is an error unless `"overwrite": true` — re-running it used to replace the scene with a bare root.
- `add_node`: add a new node under `parent_node_path`, optionally at `index`, with typed `properties` and `indexed_properties`.
- `instantiate_scene`: instance a child scene under `parent_node_path`, optionally rename it, move it to an index, and apply root properties.
- `configure_node`: set regular properties, indexed properties, groups, metadata, and `unique_name_in_owner` on an existing node.
- `configure_control`: configure `Control` presets, anchors, offsets, `position`, `size`, `custom_minimum_size`, size flags, stretch ratio, and theme overrides.
- `attach_script`: assign a script and then write exported properties.
- `connect_signal`: connect a signal to a target node method with persistent connection flags by default and optional `binds`.
- `disconnect_signal`: remove persistent scene connections by source node, signal, target node, and method.
- `load_sprite`: load an existing texture resource into a `Sprite2D`, `Sprite3D`, or `TextureRect`.
- `build_sprite_frames`: build or replace animations on an `AnimatedSprite2D` from `frames_dir`/`frame_paths`, or from a `spritesheet` + `grid` with an `animations` array (multiple named animations, per-frame `duration`), then optionally save the `SpriteFrames` resource to `resource_save_path`.
- `paint_tilemap`: assign a `TileSet` and paint/fill/erase cells — or an `ascii_map` — on a `TileMapLayer` node (also available inside `scene_batch`).
- `paint_gridmap`: assign a `MeshLibrary` and paint/fill/erase cells (with orientation) — or `ascii_layers` — on a `GridMap` node (also available inside `scene_batch`).
- `inspect_tilemap`: dump a `TileMapLayer` or `GridMap` as ASCII rows with a paste-back `legend`, `bounds`, and per-tile `counts`.
- `inspect_image`: describe an image file as numbers and optional ASCII, with `expect` gates and an `image_paths` frame-sequence mode.
- `help`: list every operation, or print one operation's parameter schema, example, notes, and runnable command; `{"check_examples":true}` validates the catalog.
- `bake_collision`: add a `StaticBody3D`/`CollisionShape3D` to a `MeshInstance3D` via trimesh/convex/multi_convex baking (owner-safe serialization; also in `scene_batch`).
- `collision_from_sprite`: trace `CollisionPolygon2D` children from a sprite's alpha silhouette (also in `scene_batch`).
- `bake_csg`: freeze a `CSGShape3D` tree into a static `ArrayMesh` (+ optional collision), optionally replacing the CSG node with a `MeshInstance3D`.
- `build_animation`: build an `Animation` from declarative value/method/bezier tracks, save it standalone, and/or register it on an `AnimationPlayer` via an `AnimationLibrary`.
- `build_tileset`: author a `TileSet` resource with atlas sources, exposed tiles, and physics/custom-data layers.
- `setup_audio_buses`: author the project's `AudioBusLayout` (buses, sends, volumes, effects) and register it in project settings.
- `save_scene`: load an existing scene from `scene_path` and save it back to the same path or an alternate `save_path`; keep `new_path` only as a compatibility alias for older callers.
- `remove_node`, `reparent_node`, `reorder_node`: mutate existing hierarchy without rewriting the scene by hand.
- `get_uid`: inspect `file_path`, returning the `.uid` sidecar path, whether that sidecar exists, and any engine-reported UID text when available.
- `resave_resources`: resave scenes plus `.gd`, `.shader`, and `.gdshader` resources under `project_path`, then report how many `.uid` sidecars were actually created versus still missing.
- `inspect_audio`: describe a `.wav`/`.ogg`/`.mp3` as numbers (duration, peak and RMS dBFS, clipping, silence edges, loop seam, pitch contour) and a one-line ASCII envelope, with `expect` gates and an `audio_paths` directory mode.
- `draw_image`: ASCII rows, named palettes, frames and shape primitives → PNG, read back as the same characters; `process_image`: ordered `operations` (`trim`, `crop`, `resize`, `pad`, `flip_h`, `flip_v`, `rotate90`, `alpha_threshold`, `replace_color`, `remove_background`, `quantize`, `pixelate`, `outline`, `pack_frames`, `split_sheet`, `tile`, `nine_patch_margins`).
- `run_gdscript`: run `code` (the body of `func run(tree: SceneTree) -> Variant`, may `await`), one `expression`, or `script_path` + `method` + `args` inside the project and return the encoded result.
- `add_export_preset`: write or update one `export_presets.cfg` entry for `web`, `windows`, `linux`, `macos`, `android` or `ios`, preserving every other preset byte for byte.
- `check_project`: load every GDScript, scene, shader, resource, GDExtension, and editor plugin under `project_path` (default `res://`) and report failures by path, kind, and reason. It also fails a shader that does not compile, and reports `config_warnings[]` (node configuration warnings with runnable fixes) and a `physics_layers` survey. Scenes are also instantiated, which is what catches an invalid node hierarchy; set `instantiate` to `false` for a load-only pass that runs no project code.

## Respect The Bundled Implementation

- Read `scripts/core/dispatcher.gd` when adding or changing Godot-side operations.
- Add scene operations under `scripts/scene/`, resource operations under `scripts/resource/`, project operations under `scripts/project/`, import helpers under `scripts/import/`, asset helpers under `scripts/assets/`, mesh operations under `scripts/mesh/`, diagnostics/runners under `scripts/debug/`, shared utilities under `scripts/utils/`, and codecs/editing helpers under `scripts/core/`.
- When adding an operation, add its `match` arm in `scripts/core/dispatcher.gd` **and** an entry in `scripts/core/op_examples.json` (`summary`, a `params` schema of only the keys that operation uses, `example`, `notes`, `see`), then run `help '{"check_examples":true}'` — it fails when the schema or the example names a key the operation does not read. Read op parameters only through `params.get("key", default)`/`params.has("key")` literals: the dispatcher derives the accepted-key list from those. The derivation is a regex over raw source, comments included, across everything the op preloads — so never read an output or parsed dictionary with a quoted-literal `get`/`has` (use `dict[&"key"]` or a helper), never write that pattern in a comment, and keep `scripts/core/utils.gd` (preloaded by every op) free of it. The catalog's per-op and per-action `params` are also what the dispatcher uses to reject a key that belongs to another operation, so keep them complete.
- List every new python entry point in the catalog's `_tools` array (`script`, `summary`, `command`); `tests/test_help_op.py` fails when a `scripts/**/*.py` file is missing from it.
- Keep `templates/shaders/*.gdshader` compiling (`tests/test_shader_templates.py` also proves each effect by pixels) and every playbook literally replayable (`tests/test_playbooks_replay.py` extracts the fenced `bash` blocks and runs them in fresh projects). `tests/test_help_examples.py` does the same for every `help` example and for the dispatcher blocks in this file, and `tests/test_reference_examples.py` for every other documented command:
- **Every fenced `bash` block in `SKILL.md` and `references/*.md` is executed by `tests/test_reference_examples.py`** — one `bash -e -o pipefail` subprocess per block, in document order, against a fresh copy of the `_example_world` project. Blocks of one doc share that copy, so a later block may use a file an earlier block wrote; they never share shell variables, because a reader pastes one block at a time. What that asks of the prose:
  - One block is one thing a reader pastes: the whole command, no `…`, no `[--flag]` grammar (put grammar in prose or a non-bash fence), no placeholder the reader is not told to replace. Output examples go in a `json` or `text` fence, never in the bash block.
  - The placeholders are `/absolute/path/to/godot` (this skill's root, also spelled `/absolute/godot`), `/absolute/path/to/project` (the project, also `/absolute/project`), and `/absolute/<word>` for a scratch path beside the project (`/absolute/build`, `/absolute/dest`, `/absolute/moves.json`). Any other `/absolute/…` fails the test, as does a `$VAR` the block does not set itself (`SKILL`, `PROJECT`, `GODOT_SKILL_CACHE`, `HOME` and `PATH` are provided). Write the dispatcher path out in full every time: `godot --script <path that does not resolve>` prints `Can't load script` and **exits 0**, so a block built around an unset variable passes while running nothing — the harness fails any block whose log says that, whatever its exit code.
  - A block that needs the example world to hold something builds it first, in an earlier block of the same doc — a `cat > … <<'JSON'` heredoc, a `draw_image` call, a `create_scene`.
  - Three directives, each an HTML comment on the line before the fence: `<!-- replay: fails -->` when the block exists to show an error message (exit 0 then fails the test), `<!-- replay: display -->` when it needs a real framebuffer, and `<!-- replay: skip — <reason> -->` where `<reason>` starts with `export-templates`, `external-tool:<name>`, `network`, `destructive-outside-project` or `interactive` (a server or watcher that runs until the reader stops it). No other skip reason is accepted: rewrite the block so it runs.
  - `display` and `export-templates` are *conditional*: the harness probes the machine (a real framebuffer; this engine's export templates, with `probe_environment.py`'s own search) and **runs** the block where it can, so a developer's Mac really exports a web, Windows and macOS build while a bare CI runner prints a SKIP line. A skip reason may add a `host:<darwin|linux|win32>` qualifier — `<!-- replay: skip — export-templates host:darwin (runs the exported .app) -->` — and then the block also has to be on that platform.
  - While editing one doc: `python3 tests/test_reference_examples.py --doc automation_api.md --continue --keep`, or `--list` to see every block and directive without running anything.
- Keep `templates/gdscript/*.gd` warning-free under `check_project --debug` (`tests/test_templates.py` enforces it) and reference every template from `references/playbooks.md`.
- Keep Godot-side parameter names in snake_case when editing these scripts, for example `scene_path`, `root_node_type`, `parent_node_path`, `node_type`, and `node_name`.
- Preserve the current relative import pattern inside the GDScript files so the headless dispatcher keeps working.

## Examples

### Menu UI In One Batch

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path":"scenes/menu.tscn",
    "create_if_missing":true,
    "root_node_type":"Control",
    "root_node_name":"Menu",
    "actions":[
      {"type":"add_node","parent_node_path":"root","node_type":"PanelContainer","node_name":"Panel"},
      {"type":"configure_control","node_path":"root/Panel","layout_preset":"FULL_RECT"},
      {"type":"add_node","parent_node_path":"root/Panel","node_type":"Button","node_name":"StartButton","properties":{"text":"Start"}},
      {"type":"configure_control","node_path":"root/Panel/StartButton","size_flags_horizontal":"EXPAND_FILL","custom_minimum_size":{"__type":"Vector2","x":240,"y":64}}
    ]
  }'
```

### Attach Script And Connect Button Signal

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path":"scenes/menu.tscn",
    "actions":[
      {"type":"attach_script","node_path":"root","script_path":"scripts/menu_controller.gd","script_properties":{"menu_title":"Main Menu"}},
      {"type":"connect_signal","node_path":"root/Panel/StartButton","signal_name":"pressed","target_node_path":"root","method_name":"_on_start_pressed","binds":["clicked"]}
    ]
  }'
```

### Export A Debug Android Build

<!-- replay: skip — external-tool:android-sdk (an Android export needs the SDK, a build template and a debug keystore) -->
```bash
python3 /absolute/path/to/godot/scripts/export/export_project.py \
  /absolute/path/to/project \
  "Android" \
  /absolute/build/android/game.apk \
  --mode debug
```

### Run And Read The Debugger Errors

```bash
python3 /absolute/path/to/godot/scripts/debug/run_project.py \
  /absolute/path/to/project scenes/main.tscn \
  --quit-after 120 --timeout 60 --pretty
```

Returns JSON with a `diagnostics` array; each entry has `severity`, `category`, `message`, `file`, `line`, `function`, `stack`, and `suggested_fix`. Open the referenced `file:line`, apply the fix, then re-run until `"ok": true`.

### Build AnimatedSprite2D Frames From A Directory

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  build_sprite_frames '{
    "scene_path":"scenes/player.tscn",
    "node_path":"root/AnimatedSprite2D",
    "frames_dir":"art/player_idle",
    "animation_name":"idle",
    "fps":12,
    "loop":true,
    "resource_save_path":"animations/player_idle_frames.tres"
  }'
```

## Check Before You Finish

- Confirm that every write target is inside the intended Godot project.
- Confirm that the scene still loads and that the project boots after structural edits.
- Confirm `lint_project.py` reports `counts.errors == 0` on the project after your edits, and that any generated controller, manager, or UI script either came from `templates/gdscript/` or passes the same bar: `validate_project.py` reporting `counts.errors == 0` **and** `counts.warnings == 0`.
- Confirm `validate_project.py` reports zero `node_config` diagnostics (`check_project` → `config_warning_count == 0`) and read its `physics_layers.findings`: a body with no shape and a mask that targets an empty layer both run without a single error.
- Confirm every scene boots, not only the main one: `smoke_scenes.py PROJECT --seconds 2 --jobs 4 --fuzz` exits 0. `info`-level `exit_leak` (music still playing at quit) and `host_capability` (no GPU / no sound card on this machine) diagnostics are not failures.
- Confirm that the changed feature was exercised in a live run when the environment allowed it, and that the observed behavior matched the request without obvious regressions.
- Confirm gameplay placement as text when you cannot look: a `spatial_report` step with `expect_on_screen` and `"fail_on": ["not_on_screen", "embedded_in_static"]` (2D) or `["no_camera_3d", "no_light_3d", "not_in_frustum", "behind_camera"]` (3D) passes.
- Confirm logic you wrote has a unit test that ran: `run_tests.py` → `"ok": true` with `counts.tests > 0` and no `risky` test standing in for an assertion.
- Confirm that UI work was verified as laid out, not just saved: run `run_scenario`'s `ui_report` step with `{"fail_on": ["any"]}` at two `viewport_size` values and confirm zero `zero_size`, `offscreen`, and `overlap` findings, and confirm one `screenshot` step with `{"expect": {"not_blank": true}}` passed — a perfectly laid-out Control tree still renders an empty frame when the texture, material, or camera is wrong. Confirm a project `Theme` is wired through `gui/theme/custom` with a visibly distinct `focus` stylebox — an unthemed `Control` tree ships the engine's editor-gray default and reads as a web form, not game UI.
- Confirm that any new art, music, or story content matches the requested direction, or the pixel-art default when no direction was provided and no project style overrode it.
- Confirm that generated sprite-like assets used transparent output first, or a flat pure-green chroma-key background plus local cutout as the fallback.
- Confirm every generated or synthesized sound passed `inspect_audio` with the `expect` block its generator printed (`not_silent`, `no_clipping`, duration bounds; `loopable` for music), and that looping tracks carry the `edit/loop_mode` import option.
- Confirm that frame animation work landed as a validated frame sequence or `SpriteFrames` resource, not an unusable loose asset dump, and that `inspect_image` with `expect` passed on the frames.
- Confirm painted levels by reading them back with `inspect_tilemap` and comparing the rows to what you meant to paint — an off-by-one `origin`, a legend character on the wrong tile, or a terrain fill that matched nothing all save cleanly.
- Confirm that the final validation run logs contain no `error` or `warning` output. If they do, fix the issue and rerun before finishing. Capture the run with `scripts/debug/run_project.py` (or the host runtime tools) so the check is on structured diagnostics, not a glance at the log. A boot-and-quit run only reports the files it loaded, so pair it with `scripts/debug/validate_project.py` for whole-project warning coverage. If a run reports zero warnings on a project the editor complains about, the debugger is not attached — check for a stray `--no-debugger`.
- Confirm that every exported artifact came from the intended preset and that the artifact path matches the target platform's existing convention.
- Smoke test at least one exported build for the requested targets instead of assuming the preset is valid.
- Confirm every file you moved or renamed went through `move_resource.py` and that it reported `verify.new_missing == []`.
- Confirm architecture work did not collapse unrelated responsibilities into a single node script, autoload, or generic manager.
- Prefer incremental scene changes over rewriting `.tscn` files manually. When a `.tscn` was hand-written or hand-edited anyway, confirm `inspect_scene` reports the intended nesting and that every `[connection]` `source`/`target` matches a real node path before finishing — both classes of mistake load and boot cleanly (`references/tscn_format.md`).
