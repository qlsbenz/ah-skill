# Automation API

Read this reference when invoking the bundled inspection, resource/project editing, import, validation, scenario, or export-preflight tools.

## Contents

- Dispatcher invocation
- Discovering operations (`help`)
- Inspection operations: project, scene, resource, image, audio, tilemap
- Resource transactions
- Project settings transactions
- Content authoring: tilesets, tilemaps, sprite atlases, animations, audio buses, themes, gridmaps, 3D collision/CSG, glTF export, navmesh baking, replication config
- Pixel art: drawing PNGs from ASCII (`draw_image`) and cleaning up / packing images (`process_image`)
- Unit tests (bundled `mini`, GUT, GdUnit4)
- Static lint (no Godot needed): Godot 3 API and shader renames, `:=` inference, dead node/signal targets, undefined input actions, unknown groups, missing `res://` paths, unknown animations, `# lint:ignore`
- Import and validation
- Moving or renaming files safely (`move_resource.py`)
- Node configuration warnings and the physics layer survey (`config_warnings`, `physics_layers`)
- Smoke-run every scene in its own process (`smoke_scenes.py`, `--fuzz`, `--profile`)
- Scenario runner: input and timing facts, screenshot, ui_report, dump_tree, spatial_report, verification without vision
- Engine API lookup and ad-hoc code (`api_lookup.py`, `run_gdscript`)
- Typed JSON values
- Creating a project from nothing (`scaffold_project.py`)
- Creating an export preset headlessly (`add_export_preset`), export preflight and patches (`export_project.py`), serving a web build (`serve_web.py`)

## Dispatcher Invocation

Invoke Godot-side operations with one JSON object:

```bash
godot --headless --path /absolute/project \
  --script /absolute/godot/scripts/core/dispatcher.gd \
  inspect_project '{"include_files":false}'
```

Use project-relative paths with or without `res://`; outputs normalize them to `res://`.

Parameters are checked before anything runs, in two stages, and a rejected call writes nothing:

1. **Unknown key** — a key no code path of the operation reads: `Unknown parameter for add_node: parent_path (did you mean parent_node_path?)`. The accepted set is derived from the operation's own sources, so it cannot go stale.
2. **Misplaced key** — a key the sources do read, but for a *different* operation or batch action. The scene operations share one implementation, so the derived set alone accepted `script_properties` on `configure_node`, ignored it, and reported the scene as saved. The curated catalog behind `help` settles it: `Misplaced parameter for scene_batch action "configure_node": actions[0].script_properties is not read by it (it belongs to: attach_script); did you mean properties, indexed_properties?`. A key that no catalog entry documents is left to stage 1, so an undocumented-but-valid key is never refused here; `scene_path`/`save_path` repeated inside a batch action stay harmless.

`--skip-param-check` after the JSON disables both.

## Discover Operations (`help`)

`help` answers "what can this dispatcher do, and what does that operation take" without reading this file. Nothing in it is hand-maintained: the operation list is read out of `dispatcher.gd`'s own `match` arms and the accepted parameter keys are re-derived from each operation's sources by the same function that backs the unknown-parameter check, so it cannot describe an operation the dispatcher cannot run.

```bash
godot --headless --path /absolute/project \
  --script /absolute/godot/scripts/core/dispatcher.gd \
  help '{"op":"add_node"}'
```

```json
{
  "op": "add_node",
  "summary": "Add one new node of a class under an existing node and save the scene.",
  "params": {
    "scene_path": "(required) scene to edit, project-relative or res:// — \"scenes/main.tscn\"",
    "node_type": "(required) class to instantiate: any instantiable engine class or project class_name — \"Sprite2D\", \"CharacterBody2D\", \"VBoxContainer\"",
    "node_name": "(required) name of the new node, and its path segment afterwards — \"Player\"",
    "parent_node_path": "(default: \"root\") path from the scene root, which is always addressed as \"root\" — \"root/Panel\"",
    "index": "(default: -1 = last) sibling position to insert at; for Control/CanvasItem siblings this is also draw order",
    "properties": "(default: {}) node properties by name, typed JSON — {\"position\": {\"__type\": \"Vector2\", \"x\": 160, \"y\": 96}, \"text\": \"Start\"}",
    "…": "…"
  },
  "example": {"scene_path": "scenes/main.tscn", "parent_node_path": "root", "node_type": "Sprite2D", "node_name": "Player",
              "properties": {"position": {"__type": "Vector2", "x": 160, "y": 96}}},
  "notes": ["Node paths start at the scene root, which is always addressed as \"root\" (or \".\"): \"root/Panel/Start\".", "…"],
  "see": "SKILL.md#scene-editing-surface",
  "command": "godot --headless --path /absolute/project --script /absolute/godot/scripts/core/dispatcher.gd add_node '{\"scene_path\":\"scenes/main.tscn\",…}'"
}
```

- `help '{}'` lists every operation with a one-line summary plus `count` and a `usage` line. This is the cheapest way to find the right operation name — cheaper than grepping this file, and it can never be out of date.
- `help '{"op":"<name>"}'` returns that operation's `summary`, its `params` schema, a runnable `example`, `notes` (the gotchas that cost a rerun), a `see` pointer into the docs, and `command` — the complete shell line with the example already inlined, absolute dispatcher path and all. Paste it, then edit it.
- `params` is a curated `{key: meaning}` object holding only the keys that operation uses, required keys first, each one saying `(required)` or `(default: X)` and the value shape it accepts. Read it instead of guessing: `"parent_node_path": "(default: \"root\") path from the scene root, which is always addressed as \"root\" — \"root/Panel\""`.
- Batch operations add `action_types`, one schema per `actions[*].type`. A `scene_batch` action takes its operation's own keys minus `scene_path`/`save_path`, which the batch owns, and that is exactly what the op prints.
- `"verbose": true` adds `accepted_keys`: the full derived key set the unknown-parameter check allows, which includes the shared scene/codec helper keys. It is the audit view, not the documentation — reach for it only when a key was rejected and you want to know what the check actually sees.
- `"format": "text"` renders the same information as plain lines (one operation per line for the listing, a `key — meaning` line per parameter for one operation) instead of JSON.
- An unknown operation name is an error, not an empty result: it names the three nearest real operations and exits `1`. The dispatcher's own `Unknown operation:` error does the same and ends with `Run: help '{}' to list operations`, and an unknown parameter ends with `Run: help '{"op":"add_node"}' for the accepted keys and an example`.
- `help '{"check_examples":true}'` re-derives every operation's accepted keys and validates every curated `params` key, every `action_types` key and every example key (including each `actions[*]` entry) against them, printing `{"checked", "operations", "skipped", "failures":[{"op","key","suggestions"}]}` and exiting `1` on any failure. Run it after renaming a parameter: it is what stops the schema from documenting a key the operation would reject.
- The prose lives in `scripts/core/op_examples.json`, one entry per operation (`{"summary", "params", "example", "notes", "see"}`, plus `action_types` for a batch operation, where a value of `"@<operation>"` reuses that operation's schema). Adding an operation means adding a `match` arm **and** an entry — `check_examples` reports an operation with no entry, or an entry with no `params` schema, as a failure.
- Every example is written against **one** small project, described in the catalog's `_example_world` entry (`scenes/main.tscn` with `root/Player`, `scenes/menu.tscn` with `root/Panel/StartButton`, `scenes/level.tscn` with `root/Ground`, the 3D `scenes/kit.tscn` and `scenes/dungeon.tscn`, `art/player.png`, `audio/jump.wav`, …). Read that entry before copying a chain of examples: they are meant to be run in sequence against the same layout. Adapt the paths to your project; the shapes are what the examples teach.
- `check_examples` only proves the *keys* are real. `tests/test_help_examples.py` builds the `_example_world` project for real and runs all 46 printed `command` lines against it, plus one action of every documented `action_types` entry, asserting a postcondition per operation — so an example whose *shape* stopped working fails the suite instead of failing the next caller.

`help '{}'` also lists the skill's python entry points under `tools` (text format: a second block after the operations) — the linter, the runners, `api_lookup.py`, the asset generators, `move_resource.py`, `scaffold_project.py`, the export wrapper — each with a one-line summary and a runnable command that already carries this skill's absolute path and the current project. They are run directly, not through the dispatcher, and each prints its flags with `--help`. The list lives in the catalog's `_tools` array; `tests/test_help_op.py` fails when a `scripts/**/*.py` file is missing from it.

## Inspection Operations

`inspect_project` accepts:

- `include_files` (default `false`): include every project path; counts are always returned.
- Returns engine/host capabilities, selected settings, explicit InputMap actions, autoloads, global classes, plugins, export presets, and extension counts.

`inspect_scene` accepts:

- `scene_path` (required).
- `include_properties` (default `true`).
- `max_resource_depth` (default `2`).
- `config_warnings` (default `false`): also return this scene's node configuration warnings and hints as `config_warnings[]`, `config_warning_count`, `config_hint_count` — see [Node Configuration Warnings](#node-configuration-warnings-config_warnings-physics_layers). This is the one option that makes the operation **instantiate** the scene (root `_init()` and stored-property setters run); it exits 1 with an actionable message when the scene cannot be instantiated.
- Reads `SceneState` without instantiating the scene and returns nodes, stored properties, connections, dependencies, base scene, and UID.

`inspect_resource` accepts:

- `resource_path` (required).
- `include_non_storage` (default `false`).
- `include_schema` (default `false`): enable only when property type/usage metadata is needed.
- `max_resource_depth` (default `2`).
- Returns stored values, dependencies, UID, and script method/signal/property metadata when the resource is a Script.
- For a script-backed `.tres`, `resource_type` is the engine base (usually `Resource`); the identifying fields are `script_path` (the `res://….gd`), `script_class` (the script's `class_name`, empty when it declares none), and `script_properties` (its exported property names, in declaration order). The exported values themselves appear in the ordinary `properties` map.

### inspect_image

Reads an image file as numbers and ASCII, so "did the sprite render", "where is it", "is the palette pixel-art sized", "did the frame change" are text questions. It loads the file directly (`Image.load_from_file`), never through the import pipeline, so freshly generated art works before `--import` has ever run and screenshots outside the project work by absolute path.

```json
{
  "image_path": "art/player.png",
  "ascii": true,
  "ascii_width": 64,
  "ascii_color": false,
  "compare_to": "art/player_reference.png",
  "max_unique": 4096,
  "background_tolerance": 0.12,
  "expect": {"not_blank": true, "min_opaque_ratio": 0.1, "max_unique_colors": 32,
             "has_alpha": true, "width": 32, "height": 32, "max_diff_ratio": 0.01},
  "format": "json"
}
```

```json
{
  "image_path": "res://art/player.png",
  "width": 64, "height": 64, "has_alpha": true, "blank": false, "opaque_ratio": 0.0625,
  "content_bbox": {"x": 32, "y": 8, "w": 16, "h": 16},
  "content_bbox_normalized": {"x": 0.5, "y": 0.125, "w": 0.25, "h": 0.25},
  "mean_color": "#ff0000",
  "dominant_colors": [{"hex": "#ff0000", "ratio": 1.0}],
  "unique_colors": 1,
  "quadrants": {"top_left": 0.0, "top_right": 1.0, "bottom_left": 0.0, "bottom_right": 0.0},
  "background_color": "#000000", "background_transparent": true, "background_tolerance": 0.0,
  "sample_size": {"width": 64, "height": 64}, "sampled": false,
  "ascii": ["                        ", "…"],
  "diff_ratio": 0.0,
  "expect_results": [{"check": "not_blank", "expected": true, "actual": true, "passed": true}],
  "expect_passed": true
}
```

- `image_path` accepts `res://`, `user://`, an absolute host path, or a bare project-relative path; `.png`, `.jpg`, `.jpeg`, `.webp`, `.bmp`, `.tga`, `.svg`, `.exr`, `.hdr`.
- **Background** is the colour the four corner pixels agree on (ties go to the top-left corner), and a fully transparent pixel is always background. **Content** is every other pixel: that is what `content_bbox` bounds and what `quadrants` splits — the four shares are of the content, so `{"top_right": 1.0}` means everything drawn sits in the top-right quarter.
- **Lossy files ring.** JPEG paints near-background pixels around every edge, and an exact match stretches `content_bbox` over the whole chroma-bleed block (a 16 px sprite at y=8 reported as 32 rows from y=0). `background_tolerance` is the per-channel distance (0-1) under which a pixel still counts as background; it defaults to `0.12` for `.jpg`/`.jpeg` and `0` for everything else, and the result reports the value that applied. With it the JPEG box lands within a pixel of the true one. Pass it explicitly for lossy WebP or a noisy capture, or `0` to force exact matching.
- `blank` is `true` when every pixel is identical or nothing is opaque anywhere — the "nothing rendered" case. `opaque_ratio` is the share of pixels with any alpha at all (`1.0` for an opaque image, `0.0` for an empty canvas).
- `dominant_colors` are the top 8 buckets quantised to 4 bits per channel with their share of the *drawn* pixels; `unique_colors` counts exact RGBA values among drawn pixels, capped at `max_unique` (default 4096, reported as the cap when exceeded). `mean_color` averages the drawn pixels only, so a sprite on a transparent canvas reports its own colour rather than a wash toward black.
- `ascii` (with `ascii_width`, default 64) renders the image with the ramp `" .:-=+*#%@"`, halving the row count because character cells are about twice as tall as they are wide (`ascii_width` is clamped to 4-240, and a very tall image loses columns rather than producing hundreds of rows). Cells are area-averaged, transparent cells are spaces, and the ramp is stretched across the luminance actually present so a dark scene still shows its shapes. `ascii_color` renders the same grid as the nearest of `K W R G B Y C M` per cell. Both are printed after the key facts by `"format": "text"`.
- `compare_to` adds `diff_ratio`: the share of pixels where some channel differs by more than 8/255. Byte-identical images answer exactly `0.0`. Different sizes are a mistake, not a measurement — the result carries `diff_error` and the op exits 1.
- `expect` gates the exit code: every violated key logs an error, so `echo $?` is the whole check. Keys: `not_blank`, `min_opaque_ratio`, `max_unique_colors`, `has_alpha`, `width`, `height`, `max_diff_ratio` (needs `compare_to`), and `frames_consistent`. Each is also reported in `expect_results` with its expected and actual value. An invented key is rejected with the list.
- `image_paths` describes a list of files, a directory, or a mix of both in one call (directories expand in natural order, so `frame_2` precedes `frame_10`). The result is `{count, frames_consistent, frame_size, images[], expect_results, expect_passed}`, and `expect.frames_consistent` turns a frame sequence that changed canvas size mid-way into a failed run.
- Cost: colour statistics are measured on a nearest-neighbour downscale capped at 256 px on the long side (`sampled` / `sample_size` say when that happened), so a 1080p screenshot describes in about 0.2 s. `width`, `height`, `has_alpha`, `blank` and `content_bbox` are always measured on the full image — a one-pixel change is still located exactly. No rendering device is needed.

### inspect_audio

The hearing twin of `inspect_image`: an audio file read as numbers and one line of ASCII, so "did anything get synthesized", "how long is it", "does it clip", "does the loop click" and "does the pitch slide the right way" are text questions. It reads the file directly — the RIFF container is parsed in `core/audio_describe.gd`, `.ogg`/`.mp3` go through `AudioStreamOggVorbis`/`AudioStreamMP3.load_from_file` plus `AudioStreamPlayback.mix_audio` — never through `load()`, so freshly generated audio works before `--import` has ever run and files outside the project work by absolute path. No audio device is needed; it runs under the headless Dummy driver.

```json
{
  "audio_path": "audio/jump.wav",
  "envelope": true,
  "envelope_columns": 48,
  "silence_threshold_db": -60,
  "expect": {"not_silent": true, "no_clipping": true, "min_duration": 0.08, "max_duration": 0.4,
             "max_peak_db": -0.5, "min_rms_db": -20, "sample_rate": 44100, "channels": 1,
             "max_leading_silence_ms": 5, "max_trailing_silence_ms": 50,
             "loopable": true, "pitch_direction": "rising"},
  "format": "json"
}
```

```json
{
  "audio_path": "res://audio/jump.wav", "path": "res://audio/jump.wav",
  "format": "wav", "codec": "pcm", "bit_depth": 16,
  "pcm_analysis": true, "duration_s": 0.168277, "sample_rate": 44100, "channels": 1, "frames": 7421,
  "peak_db": -1.0, "rms_db": -5.07, "silent": false, "clipping_ratio": 0.0, "dc_offset": -0.002104,
  "silence_threshold_db": -60.0, "leading_silence_ms": 0.068, "trailing_silence_ms": 0.136,
  "loop_seam_delta": 0.000092,
  "dominant_frequency_hz": 339.78, "pitch_start_hz": 238.38, "pitch_end_hz": 480.85,
  "pitch_direction": "rising", "tonality": 0.902,
  "envelope": "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@%%%%%%%%####**+",
  "loop": {"mode": "none", "begin": 0, "end": 0, "source": "none"},
  "import_loop": {"edit/loop_mode": 2, "import_path": "res://audio/jump.wav.import", "loop_mode_name": "forward"},
  "expect_results": [{"check": "not_silent", "expected": true, "actual": true, "passed": true}],
  "expect_failures": [], "expect_passed": true, "ok": true
}
```

- `audio_path` accepts `res://`, `user://`, an absolute host path, or a bare project-relative path; `.wav`, `.ogg`, `.mp3`. Passing an import artefact (`.godot/imported/*.sample`) is an error that names the source file to pass instead.
- **WAV** is read from the RIFF itself: 8-, 16-, 24- and 32-bit PCM, 32/64-bit IEEE float, up to 8 channels, plus `smpl` loop points. That is deliberate — `AudioStreamWAV.load_from_file` refuses 24-bit WAV (`Format not supported for WAVE file (not PCM)`) and silently narrows 32-bit float to 16-bit. A compressed WAV (IMA ADPCM, A-law…) is an error naming the codec, not a guess.
- **Ogg/MP3** are decoded for real, so every number above is measured rather than estimated (`pcm_analysis: true`, `decoded_via` says how). `sample_rate` and `channels` come from the codec's own header (the Vorbis identification packet / the first MP3 frame header); `duration_s` comes from `AudioStream.get_length()`. Decoding happens at `AudioServer.get_mix_rate()`, reported as `analysis_sample_rate` when it differs from the file's rate.
- `silent` is the "nothing was synthesized" case — the audio equivalent of `inspect_image`'s `blank`, and the single most common generator failure. `clipping_ratio` is the share of samples pinned at full scale.
- `envelope` (with `envelope_columns`, default 48, clamped 8-240) is one line whose height is the per-slice peak in dB over a 60 dB range, using the same ramp as `inspect_image`: `" .:-=+*#%@"`. A decay reads `@@@%%%###***++==--::. `.
- `dominant_frequency_hz` / `pitch_start_hz` / `pitch_end_hz` / `pitch_direction` are the pitch contour, measured on windows at 15%, 50% and 85% of the sounding part. `tonality` is 0 (noise) to 1 (perfectly periodic); under 0.6 the frequencies are `null` and `pitch_direction` is `"none"` rather than a number nobody can defend. Sounds under ~25 ms carry no estimate.
- `loop_seam_delta` is the step between the last sample and the first — what a gapless loop plays at the wrap point. `loop` is the file's own loop metadata; `import_loop` is the `.import` sidecar's, i.e. what the game will actually hear (`null` before the first import).
- `expect` gates the exit code: every violated key logs an error, so `echo $?` is the whole check. Keys: `not_silent`, `min_duration`, `max_duration`, `max_peak_db`, `min_rms_db`, `no_clipping`, `sample_rate`, `channels`, `max_leading_silence_ms`, `max_trailing_silence_ms`, `loopable` (pass a number instead of `true` to set your own seam threshold, default `0.02`) and `pitch_direction` (`rising`/`falling`/`flat`/`none`). Each lands in `expect_results`, the violated ones also in `expect_failures[]`. An invented key is rejected with the list.
- `audio_paths` describes a list of files, a directory, or a mix of both in one call (directories expand in natural order, so `step_2` precedes `step_10`). The result is `{audio_paths, count, files[], expect_failures, expect_passed, ok}`.
- `scripts/assets/make_sfx.py` and `scripts/assets/make_music.py` print a ready-made `expect` block for every file they write — paste it in and the verification loop closes itself. Full guide: `references/audio.md`.

### inspect_tilemap

`inspect_tilemap` accepts:

- `scene_path` (required).
- `node_path` (optional): defaults to the first `TileMapLayer` or `GridMap` found under the root, and the chosen path is logged and returned in `node_path`.
- `legend` (optional): the same char → tile map `paint_tilemap.ascii_map.legend` takes. Tiles it does not name get characters auto-assigned from `#@%&*+=oxABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789` in first-seen order. Terrain entries are rejected here — a painted terrain is stored as concrete atlas tiles, so map those.
- `bounds` (optional): `{"x", "y", "w", "h"}` (`{"x", "z", "w", "h"}` for a `GridMap`) crops the window. Without it the window is the bounding box of the used cells, so empty edge rows/columns are trimmed.
- `format`: `json` (default) or `text` — `text` prints only the rows, plus a `y=<n>` header per layer for a `GridMap`.

```json
{"scene_path": "scenes/level.tscn", "node_path": "root/Ground", "format": "text"}
```

- A `TileMapLayer` returns `{node_path, node_type, tileset_path, bounds, cell_count, legend, counts, rows}`; a `GridMap` returns `{..., mesh_library_path, layers: [{"y": 0, "rows": [...]}]}` for every used `y`.
- Empty cells are always `.`, and the returned `legend` is exactly what `paint_tilemap`/`paint_gridmap` accept — inspect one scene, paste `legend` + `rows` into a paint call, and the level reproduces.
- When the scene holds no `TileMapLayer` or `GridMap` the op lists every node path and type it did find, so the next call can name a real one.

## Resource Transactions

`resource_batch` loads an existing resource, creates one with `create_if_missing` plus either `resource_type` (an engine class) or `script` (a project `class_name X extends Resource`), or deep-duplicates `duplicate_from`. It saves to `resource_path` only after every action succeeds.

```json
{
  "resource_path": "theme/generated.tres",
  "create_if_missing": true,
  "resource_type": "StyleBoxFlat",
  "actions": [
    {"type": "set_properties", "properties": {"corner_radius_top_left": 6}},
    {"type": "set_indexed_properties", "properties": {"content_margin/left": 12}},
    {"type": "set_metadata", "metadata": {"source": "generated"}},
    {"type": "remove_metadata", "names": ["obsolete"]},
    {"type": "set_resource_name", "resource_name": "Generated"}
  ]
}
```

Prefer property-based writes because they stay inspectable through `inspect_resource`. Use `call_method` only for builder APIs that have no property equivalent — for example `Curve2D.add_point`, `Gradient.add_point`, `Theme.set_color`, `Animation.add_track`, `TileSet.add_source`, or `SpriteFrames.add_animation`:

```json
{
  "resource_path": "paths/patrol.tres",
  "create_if_missing": true,
  "resource_type": "Curve2D",
  "actions": [
    {"type": "call_method", "method": "add_point", "args": [{"__type": "Vector2", "x": 0, "y": 0}]},
    {"type": "call_method", "method": "add_point", "args": [{"__type": "Vector2", "x": 200, "y": 0}]}
  ]
}
```

- `call_method`: `method` (must exist on the resource), typed `args` array, optional `expect_ok` to fail the transaction when an `Error`-returning method does not return `OK`.
- Arguments accept the full typed JSON surface, including `{"__resource": ...}` references and inline `{"__resource_type": ...}` construction, so a `call_method` can attach sub-resources.
- Inline `{"__resource_type": ...}` construction also accepts an ordered `method_calls` array (same shape as `call_method`), so a builder-only sub-resource can be created in a single property write. It also accepts `__curve` and `__gradient` sugar — see [Typed JSON Values](#typed-json-values).

Name a `script` instead of a `resource_type` to author an instance of a project's own resource class:

```json
{
  "resource_path": "items/sword.tres",
  "create_if_missing": true,
  "script": "res://items/item_data.gd",
  "actions": [
    {"type": "set_properties", "properties": {
      "display_name": "Sword",
      "price": 100,
      "tags": ["melee", "sharp"],
      "stats": {"material": {"__resource_type": "StandardMaterial3D"}}
    }}
  ]
}
```

- `script`: a `res://….gd` whose base class is `Resource` (or a Resource subclass) — the way to author the data resources a data-driven game is built from. `resource_type` is ignored when `script` is set; a contradicting `resource_type` is reported as `[INFO] resource_batch ignored resource_type=Gradient: … extends Resource`.
- The saved `.tres` is what the editor writes: `[gd_resource type="Resource" script_class="ItemData" format=3]`, an `[ext_resource type="Script" path="res://items/item_data.gd" …]` line, and `script = ExtResource("…")` in the `[resource]` block. Typed exports round-trip as `tags = Array[String](["melee", "sharp"])`.
- `duplicate_from` keeps the source's script, so duplicating a script-backed `.tres` yields another instance of the same custom class; `script` is ignored (and reported) in that case, and when the target file already exists.
- Run `godot --headless --path PROJECT --import` once after adding a new `class_name` script so the global class cache knows it — otherwise other scripts that annotate `@export var item: ItemData` fail to compile.
- `bake_navmesh`: bakes the target resource (a `NavigationPolygon` or a `NavigationMesh`) from procedural geometry using the synchronous `NavigationServer2D/3D.bake_from_source_geometry_data`. Set agent/cell parameters with a preceding `set_properties` action, then supply geometry:
  - 2D (`NavigationPolygon`): `traversable_outlines` (required, an array of `[[x,y], …]` outlines) and optional `obstruction_outlines`.
  - 3D (`NavigationMesh`): `faces` (a flat list of `[x,y,z]` triangle vertices, a multiple of 3) and/or `source_meshes` (`[{"mesh": "res://…", }]`).
  - Feed collision/procedural geometry, not visual meshes — the headless dummy renderer cannot read visual-mesh geometry back from the GPU. The bake is synchronous; never the `_async` variant in a one-shot run.

```json
{
  "resource_path": "nav/level.tres",
  "create_if_missing": true,
  "resource_type": "NavigationPolygon",
  "actions": [
    {"type": "set_properties", "properties": {"agent_radius": 8.0, "cell_size": 1.0}},
    {"type": "bake_navmesh",
     "traversable_outlines": [[[0,0],[512,0],[512,512],[0,512]]],
     "obstruction_outlines": [[[200,200],[300,200],[300,300],[200,300]]]}
  ]
}
```

Two cross-cutting notes for all resource-writing ops:

- Headless-saved `.tres`/`.tscn` files carry no `uid=` header. If the project cross-references resources by UID, run `resave_resources` after bulk creation and verify the created/missing counts.
- Every dispatcher operation exits `1` when it logged an error and `0` on success, so shell callers can gate on the exit code instead of parsing stderr.

## Project Settings Transactions

`project_batch` applies every action in memory, then calls `ProjectSettings.save()` once. **`save()` rewrites `project.godot` wholesale — comments are dropped and keys re-sorted.** Rely on version control for safety, or pass `"backup_path": "project.godot.bak"` to snapshot the original before saving. Supported actions:

- `set_setting`: `name`, typed `value`.
- `clear_setting`: `name`.
- `add_input_action`: `action_name`, optional `deadzone`, optional `replace`.
- `remove_input_action`: `action_name`.
- `add_input_event`: existing `action_name`, typed Resource `event`.
- `remove_input_event`: existing `action_name`, zero-based `event_index`.
- `add_autoload`: `autoload_name`, `path`, optional `singleton` (default `true`).
- `remove_autoload`: `autoload_name`.
- `set_layer_name`: `layer_type`, `layer` from 1 to 32, `layer_name`. Types are `2d_physics`, `3d_physics`, `2d_render`, `3d_render`, `2d_navigation`, `3d_navigation`. `layer_name` is required; pass `""` to clear a name (a missing key used to clear it silently).
- `set_main_scene`: existing `scene_path`.
- `add_translation` / `remove_translation`: translation `path`.
- `set_shader_global`: `name`, `global_type` (a shader-globals type string such as `color`, `vec3`, `float`, `sampler2D`), and typed `value`. Persists to the `[shader_globals]` section as a `{type, value}` dictionary shared by all shaders that declare `global uniform`.
- `clear_shader_global`: `name` (idempotent).

Example InputMap event:

```json
{
  "type": "add_input_event",
  "action_name": "jump",
  "event": {
    "__resource_type": "InputEventKey",
    "properties": {"physical_keycode": 32}
  }
}
```

## Content Authoring

### draw_image

Writes a PNG from ASCII rows (one character = one pixel) and/or ordered drawing primitives. It is the inverse of
`inspect_image`: the payload reads the file it just wrote back as the same characters, so a model with no image
generator and no vision can author art and prove what landed on disk. Deep guide with worked examples:
`references/pixel_art.md`.

```json
{
  "output_path": "art/hero.png",
  "palette": {"o": "#000000", "s": "#ffccaa", "h": "#ab5236", "b": "#29adff"},
  "rows": ["........", "....hhhh", "..hhhhhh", ".hhhhhhh", ".hssssss", ".hsossss",
           "..ssssss", "...sssss", "..bbbbbb", ".bbbbbbb", ".bsbbbbb", "..bbbbbb",
           "...bbbbb", "...bb...", "..ooo...", "........"],
  "mirror_x": true,
  "outline": "#000000"
}
```

```json
{
  "ok": true, "output_path": "res://art/hero.png", "written": true, "needs_import": true,
  "width": 16, "height": 16, "frames": 1, "frame_size": {"width": 16, "height": 16},
  "frame_names": ["frame_0"], "unique_colors": 4,
  "colors": [{"hex": "#000000", "pixels": 82}, {"hex": "#29adff", "pixels": 64}],
  "frame_reports": [{"index": 0, "name": "frame_0", "region": {"x": 0, "y": 0, "width": 16, "height": 16},
                     "legend": {"o": "#000000", "s": "#ffccaa", "h": "#ab5236", "b": "#29adff", ".": null},
                     "rows": ["...oooooooooo...", ".ooohhhhhhhhooo.", "…"]}],
  "summary": {"…image_describe…"}, "ascii": ["…"]
}
```

- `rows`: an array of strings or one `\n`-separated string. Every row must be the same length — unlike
  `paint_tilemap`, ragged rows are an **error** (an image is a rectangle), and so is a character that no palette
  entry names (the message gives the row, the column and the legal characters). `.` and space are always
  transparent and cannot be remapped.
- `palette_name` binds the characters `0-9` then `a-v` to a named palette (`pico8`, `sweetie16`, `db16`, `db32`,
  `endesga32`, `c64`, `cga`, `gameboy`, `grayscale4`, `nes`); an explicit `palette` is applied on top and wins,
  including in the read-back.
- `frames` (`[{"name", "rows", "shapes"}]`) packs a spritesheet with `layout` (`horizontal`/`vertical`/`grid`),
  `columns` and `separation`, and returns `grid` — exactly the `grid` object `build_sprite_frames` takes —
  plus one `frame_reports` entry per frame with its `region`. Frames of different sizes are an error.
- Shape mode: `width` + `height` (+ `background`) and `shapes`, an ordered list of `rect`, `rect_outline`,
  `circle`, `ellipse`, `line`, `polygon`, `pixel`, `pixels`, `gradient_rect`, `checker`, `noise` (seeded, so it
  is reproducible), `text` (built-in 3x5 font). `help '{"op":"draw_image"}'` prints every shape's keys. A shape
  that is entirely off-canvas is an error, not a silent no-op.
- `mirror_x`/`mirror_y`: `true`/`"append"` doubles the size from the authored half, `"append_odd"` shares the
  centre line (`2n-1`), `"fold"` keeps the size. Then `outline` (+ `outline_corners`), then `shadow`, then
  `scale` (integer, nearest).
- `tile_check` adds a per-frame seam measurement (`left_right_match`, `wrap_delta_*` vs `interior_*`,
  `seamless`). `read_back` forces or suppresses the character grid (automatic below 4096 px per frame).
- Errors never write a partial file: every frame is built and validated in memory first. `overwrite: false`
  refuses to replace an existing file.
- The written PNG has no `.import` sidecar yet (`"needs_import": true`) — run `scripts/import/import_project.py`
  before a `.tscn`/`.tres` references it.

### process_image

Runs an ordered pipeline of pixel operations over one image, a list of images, or a directory. Use it to clean
up generated art (soft edges, baked background, thousands of colours, off-grid pixels) and to pack or slice
frame sheets.

```json
{
  "input_path": "art/raw_hero.png",
  "output_path": "art/hero.png",
  "operations": [
    {"type": "remove_background", "tolerance": 0.1},
    {"type": "trim", "padding": 1},
    {"type": "pixelate", "target_width": 32, "mode": "average", "palette_name": "pico8", "alpha_threshold": 0.5}
  ]
}
```

```json
{
  "ok": true, "input_count": 1, "output_count": 1, "output_path": "res://art/hero.png", "needs_import": true,
  "outputs": [{"path": "res://art/hero.png", "width": 32, "height": 45, "unique_colors": 7}],
  "steps": [{"index": 0, "type": "remove_background", "images": 1, "width": 256, "height": 256,
             "unique_colors": 457, "detail": {"cleared_pixels": 39992, "cleared_ratio": 0.61}},
            {"index": 2, "type": "pixelate", "images": 1, "width": 32, "height": 45, "unique_colors": 7,
             "detail": {"grid": {"columns": 32, "rows": 45}, "quantize": {"colors_after": 8, "palette_size": 16}}}],
  "summary": {"…image_describe…"}, "ascii": ["…"]
}
```

- The pipeline is a **list of images**: most operations map over every one, `pack_frames` folds them into a
  single sheet (and reports the `build_sprite_frames` `grid` plus each frame's region), `split_sheet` expands one
  sheet into many frames. One image out → `output_path`; several → `output_dir` (+ optional `suffix`), named
  after their inputs. A directory in `input_paths` contributes its images in natural filename order.
- Operation types: `trim`, `crop`, `resize`, `pad`, `flip_h`, `flip_v`, `rotate90`, `alpha_threshold`,
  `replace_color`, `remove_background`, `quantize`, `pixelate`, `outline`, `pack_frames`, `split_sheet`, `tile`,
  `nine_patch_margins`. `help '{"op":"process_image"}'` prints each one's keys.
- `pixelate` is the fake-pixel-art fix: `target_width` (or `cell_size`) sets the grid, `mode` is
  `average`/`mode`/`nearest`, and `palette_name`/`palette`/`max_colors` and `alpha_threshold` run in the same
  step, so a 512×512 soft blob becomes a 32×32 grid with a fixed palette and hard alpha in one operation.
- `quantize` reports `colors_used`, so "did it really end up inside the palette" is a string comparison, not a
  guess. `max_colors` uses a deterministic median cut.
- `nine_patch_margins` does not change the image; it reports `margins`, `center`, `stylebox_texture` and
  `nine_patch_rect` for `build_theme`/`NinePatchRect`, with a `note` when the image does not look like a panel.
- Reads png, jpg, webp, bmp, tga, svg, exr, hdr; writes png (or webp). Nothing is written until every operation
  of every image has succeeded, and with `"overwrite": false` every target is checked before the first write, so
  a batch is never half-written.

### build_tileset

Authors or updates a `TileSet` `.tres`. TileSet construction is method-driven, so use this instead of `resource_batch`:

```json
{
  "resource_path": "tilesets/world.tres",
  "tile_size": {"x": 16, "y": 16},
  "physics_layers": [{"collision_layer": 1, "collision_mask": 1}],
  "custom_data_layers": [{"name": "kind", "type": "string"}],
  "sources": [{"source_id": 0, "texture": "art/tiles.png", "tiles": "all"}]
}
```

- `sources[*].tiles`: `"all"` exposes every full grid cell of the texture; or pass explicit `[{"atlas_coords":{"x":0,"y":0},"size":{"x":1,"y":1}}]`.
- `texture_region_size` defaults to `tile_size`; `margins`/`separation` are optional Vector2i dictionaries.
- Custom data layer types: `bool`, `int`, `float`, `string`, `vector2`, `vector2i`, `color`.
- Per-tile configuration — on each tile entry, or on `sources[*].tile_defaults` to apply to every tile of that source:
  - `collision`: `"full_cell"` (rectangle sized to the tile's texture region, centered) or an explicit array of 3+ `{x,y}` points relative to the tile center. Requires at least one `physics_layers` entry; `collision_layer_index` selects which (default 0). Without collision polygons a TileSet is decorative only — characters fall through.
  - `custom_data`: `{"layer_name": value}` map writing declared custom-data layers.
  - `terrain_set` / `terrain` / `peering`: terrain membership plus peering bits, e.g. `"peering": {"left_side": 0, "right_side": 0}` (side names resolve to `TileSet.CELL_NEIGHBOR_*`).
- `terrain_sets`: `[{"mode": "match_corners_and_sides"|"match_corners"|"match_sides", "terrains": [{"name": "grass", "color": {...}}]}]`.
- Run the importer first (`import_project.py`) when the texture is a fresh, unimported image so the saved `.tres` reloads in later sessions.

### paint_tilemap

Paints cells on an existing `TileMapLayer` node (the monolithic `TileMap` node is deprecated since Godot 4.3 — add `TileMapLayer` nodes instead). Available standalone and as a `scene_batch` action:

```json
{
  "scene_path": "scenes/level.tscn",
  "node_path": "root/Ground",
  "tile_set": "tilesets/world.tres",
  "ascii_map": {
    "legend": {
      "#": {"source_id": 0, "atlas_coords": {"x": 0, "y": 0}, "alternative": 0},
      "o": {"source_id": 0, "atlas_coords": {"x": 1, "y": 0}},
      "G": {"terrain_set": 0, "terrain": 1},
      ".": null
    },
    "rows": ["#####", "#ooo#", "#GGG#", "#####"],
    "origin": {"x": 0, "y": 0},
    "erase_unlisted": false
  },
  "cells": [{"coords": {"x": 9, "y": 0}, "source_id": 0, "atlas_coords": {"x": 0, "y": 0}}],
  "fills": [{"from": {"x": 0, "y": 9}, "to": {"x": 9, "y": 9}, "source_id": 0, "atlas_coords": {"x": 1, "y": 0}}],
  "erase": [{"x": 5, "y": 5}],
  "clear": false
}
```

- Order per call: optional `tile_set` assignment → `clear` → `erase` → `cells` → `fills` (inclusive rectangles) → `ascii_map` → `terrain_fills`. `ascii_map` therefore wins wherever it overlaps `cells`/`fills`.
- **`ascii_map` is the readable way to author a level, and the only one a model without vision can verify** — `inspect_tilemap` reads the same rows back. Prefer it over long `cells` lists.
- `ascii_map.rows`: an array of strings, or one `\n`-separated string (`"#####\n#...#"`). Leading/trailing empty lines are dropped. Row 0 is `origin.y` and y increases downward; character column 0 is `origin.x`. `origin` defaults to `{"x": 0, "y": 0}`.
- `ascii_map.legend`: one character → one tile. `{"source_id", "atlas_coords", "alternative"}` paints a tile directly; `{"terrain_set", "terrain", "ignore_empty_terrains"}` is collected across the whole map and painted with `set_cells_terrain_connect` after the plain cells (mixing the two in one entry is an error). Mapping a character to `null` leaves those cells untouched — `.` and space mean that even with no legend entry.
- `erase_unlisted: true` makes every "untouched" character (`.`, space, and any legend entry mapped to `null`) *erase* the cell instead, which is how you cut a hole in an existing map.
- A character that is neither in the legend nor `.`/space is an **error**: the op names the unknown characters and the legend keys, paints nothing, and does not save the scene. Rows of unequal length are only a `[WARN]` — the short row simply stops early.
- `terrain_fills`: `[{"cells": [{x,y}, ...], "terrain_set": 0, "terrain": 0}]` runs `set_cells_terrain_connect` for autotiling — the TileSet's tiles need terrain membership and peering bits (see `build_tileset`). When the TileSet has no tile matching the requested neighbourhood the engine paints **nothing**; both this and the `ascii_map` terrain path emit `[WARN] ... left N of M cells empty` instead of reporting a clean save over an empty map.
- Painting fails fast if the atlas source has not exposed the requested `atlas_coords` — expose tiles with `build_tileset` first.
- Read the result back as text with `inspect_tilemap`.

### build_sprite_frames (atlas mode)

The legacy `animation_name` + `frames_dir`/`frame_paths` form still works. The `animations` form adds spritesheet slicing, multiple animations per call, and per-frame duration:

```json
{
  "scene_path": "scenes/mob.tscn",
  "node_path": "root/Sprite",
  "spritesheet": "art/sheet.png",
  "grid": {"cell_width": 8, "cell_height": 8},
  "animations": [
    {"name": "idle", "fps": 6, "loop": true, "frames": [{"row": 0, "cols": [0, 1, 2, 3]}]},
    {"name": "attack", "fps": 12, "frames": [
      {"index": 4, "duration": 2.0},
      {"region": {"x": 8, "y": 8, "width": 8, "height": 8}},
      {"path": "art/extra_frame.png"}
    ]}
  ],
  "resource_save_path": "anims/mob_frames.tres"
}
```

- Frame specs: `{"row", "col"}` or `{"row", "cols": [...]}` or `{"index"}` (row-major) slice the grid into `AtlasTexture`s; `{"region"}` cuts an arbitrary rect; `{"path"}` loads a standalone image.
- `duration` is SpriteFrames' relative per-frame duration (default `1.0`).
- `grid` supports `margin_x`/`margin_y`/`separation_x`/`separation_y`.

### build_animation

Builds an `Animation` from declarative tracks, then saves it standalone (`resource_save_path`) and/or registers it on an `AnimationPlayer` through an `AnimationLibrary` (`scene_path` + `player_node_path`, created when missing):

```json
{
  "animation_name": "blink",
  "length": 0.8,
  "loop_mode": "linear",
  "tracks": [
    {"type": "value", "path": "Sprite2D:modulate", "update_mode": "continuous",
     "keys": [{"time": 0.0, "value": {"__type": "Color", "r": 1, "g": 1, "b": 1, "a": 1}},
              {"time": 0.4, "value": {"__type": "Color", "r": 1, "g": 1, "b": 1, "a": 0.2}}]},
    {"type": "method", "path": ".",
     "keys": [{"time": 0.8, "method": "on_blink_done", "args": []}]},
    {"type": "bezier", "path": "Sprite2D:scale:x",
     "keys": [{"time": 0.0, "value": 1.0, "in_handle": [0, 0], "out_handle": [0.2, 0.1]}]}
  ],
  "resource_save_path": "anims/blink.tres",
  "scene_path": "scenes/player.tscn",
  "player_node_path": "root/AnimationPlayer",
  "library": ""
}
```

- Track paths follow Godot's `"NodePath:property"` form relative to the AnimationPlayer's `root_node` (its parent by default).
- `loop_mode`: `none`/`linear`/`pingpong`. Value tracks accept `update_mode` (`continuous`/`discrete`/`capture`) and `interpolation` (`nearest`/`linear`/`cubic`); value keys accept `transition`.
- The default library is `""`, so animations play by bare name (`player.play("blink")`).

### build_animation_tree

Builds an `AnimationNodeStateMachine` on an `AnimationTree` node (created when missing) from clips that already exist on the linked AnimationPlayer:

```json
{
  "scene_path": "scenes/enemy.tscn",
  "tree_node_path": "root/AnimationTree",
  "anim_player": "../AnimationPlayer",
  "states": [
    {"name": "idle", "animation": "idle"},
    {"name": "run", "animation": "run"}
  ],
  "transitions": [
    {"from": "idle", "to": "run", "advance_mode": "auto", "advance_condition": "moving", "xfade_time": 0.15},
    {"from": "run", "to": "idle", "advance_mode": "auto", "advance_expression": "not moving"}
  ]
}
```

- `anim_player` is a NodePath relative to the AnimationTree node (default `../AnimationPlayer`).
- Transition fields: `xfade_time`, `advance_mode` (`disabled`/`enabled`/`auto`), `advance_condition` (a bool the game sets via `tree.set("parameters/conditions/<name>", true)`), `advance_expression`, `switch_mode` (`immediate`/`sync`/`at_end`).
- A `Start → first state` transition is added automatically unless one exists (`auto_start: false` disables) — without it the machine never enters a state.
- Drive it at runtime with `tree.get("parameters/playback").travel("run")`.
- For blend trees or 1D/2D blend spaces, assemble the `tree_root` with `resource_batch` `call_method` instead.

### set_import_options

Patches the `[params]` section of an asset's `.import` sidecar, then invalidates the imported artifact so the next import pass actually re-runs:

```json
{"file_path": "audio/bgm.ogg", "options": {"loop": true, "loop_offset": 0.0}}
```

- Follow with `python3 scripts/import/import_project.py <project>` (or `godot --headless --import`) — the op reports `reimport_required: true`.
- WAV loop uses `edit/loop_mode`, and the importer enum is offset from the resource enum: `0` Detect From WAV, `1` Disabled, `2` Forward, `3` Ping-Pong, `4` Backward. Ogg/MP3 use the simpler `loop` bool + `loop_offset` seconds.
- Whole-number values are written as ints (JSON numbers arrive as floats; importer params are typed).

### setup_audio_buses

`AudioServer` is a singleton, not a Resource, so bus routing has its own op. Buses are created or updated by name, then the layout snapshot is saved and registered:

```json
{
  "buses": [
    {"name": "Master", "volume_db": 0.0},
    {"name": "Music", "send": "Master", "volume_db": -6.0},
    {"name": "SFX", "send": "Master",
     "effects": [{"type": "AudioEffectLowPassFilter", "enabled": true, "properties": {"cutoff_hz": 4000.0}}]}
  ],
  "save_path": "default_bus_layout.tres",
  "set_project_setting": true
}
```

- Order buses before the buses that `send` to them. The Master bus cannot have a send.
- Providing `effects` replaces that bus's whole effect chain (idempotent reruns).
- `set_project_setting` writes `audio/buses/default_bus_layout`; values equal to the engine default are omitted from `project.godot` by design.
- Route players to a bus with `configure_node`: `{"properties": {"bus": "Music"}}` on an `AudioStreamPlayer`.
- There is nothing to route until sounds exist: `scripts/assets/make_sfx.py` synthesizes the effects and `scripts/assets/make_music.py` renders a seamlessly looping chiptune WAV, both stdlib-only. See `references/audio.md`, and verify what they wrote with `inspect_audio`.

### build_theme

Authors a `Theme` `.tres` grouped by control type. Every Theme item setter is a positional `(name, theme_type, value)` call with no property equivalent, so `resource_batch` needs dozens of unlabeled `call_method` entries; this op groups them. Colors accept hex strings (`"#2a2a2a"`) or typed `{"__type": "Color"}`. Styleboxes accept a flat `StyleBoxFlat` shorthand (with `corner_radius` / `border_width` / `content_margin` / `expand_margin` convenience keys that call the `*_all` setters), an inline `{"__resource_type": "StyleBox…"}`, a `{"__resource": "res://…"}` reference, or the string `"empty"` for a `StyleBoxEmpty`.

```json
{
  "resource_path": "theme/main.tres",
  "default_font": {"__resource": "res://fonts/inter.ttf"},
  "default_font_size": 16,
  "types": {
    "Button": {
      "styleboxes": {
        "normal": {"bg_color": "#2a2a2a", "corner_radius": 6, "border_width": 1, "border_color": "#111111", "content_margin": 8},
        "hover": {"bg_color": "#3a3a3a", "corner_radius": 6},
        "focus": "empty"
      },
      "colors": {"font_color": "#ffffff", "font_hover_color": "#eeeeee"},
      "constants": {"h_separation": 8},
      "font_sizes": {"font_size": 16}
    }
  },
  "variations": {"HeaderLabel": {"base": "Label", "colors": {"font_color": "#88ccff"}, "font_sizes": {"font_size": 28}}}
}
```

- Item names are not validated by the engine — a typo silently falls back to the default theme. Match the control's documented item names.
- Wire the finished theme project-wide with `project_batch` `set_setting` on `gui/theme/custom`, or per-control with `configure_node` (`theme`) / `theme_type_variation`.

### paint_gridmap

The 3D parallel to `paint_tilemap`. `GridMap` cells exist only through `set_cell_item`, so there is no bulk property for `configure_node` to set. Assign a `mesh_library` (build it with `export_mesh_library`), then paint.

```json
{
  "scene_path": "scenes/level.tscn",
  "node_path": "root/GridMap",
  "mesh_library": "meshlib/tiles.meshlib",
  "cell_size": {"__type": "Vector3", "x": 2, "y": 2, "z": 2},
  "legend": {"A": {"item": 0, "orientation": 0}, "B": {"item": 1}, ".": null},
  "ascii_layers": [
    {"y": 0, "rows": ["AAAA", "A..A", "AAAA"]},
    {"y": 1, "rows": ["B..B", "....", "B..B"], "origin": {"x": 0, "z": 0}}
  ],
  "clear": false,
  "fills": [{"from": [0, 0, 0], "to": [7, 0, 7], "item": 0, "orient": 0}],
  "cells": [{"pos": [3, 1, 4], "item": 2, "orient": 22}],
  "erase": [[0, 0, 0]]
}
```

- Order per call: `mesh_library` → `cell_size` → `clear` → `erase` → `cells` → `fills` → `ascii_layers`.
- `pos`/`from`/`to`/`erase` accept `[x,y,z]` or `{x,y,z}`. `item` must exist in the mesh library; `orient` is a `0`–`23` orthogonal index. Also runs inside `scene_batch`.
- `ascii_layers` is the ASCII form, one entry per horizontal slab: rows map to **z** increasing, characters to **x**, and `y` names the slab. Per-layer `origin` is `{"x": 0, "z": 0}`.
- The `legend` is shared by every layer and takes `{"item": 0, "orientation": 0}` (`orient` is accepted too); `null`, `.` and space leave the cell untouched, and `erase_unlisted: true` makes them erase. The same rules as `paint_tilemap.ascii_map` apply: unknown character → error naming it and the legend keys, nothing painted, scene not saved; ragged rows → `[WARN]`. Every layer is validated before any cell is written.
- Read it back with `inspect_tilemap`, which handles `GridMap` as well as `TileMapLayer`.

### bake_collision

Generates a `StaticBody3D` + `CollisionShape3D` child from a `MeshInstance3D` via the engine's `create_*_collision` helpers. `mode` is `trimesh` (concave, static only), `convex` (accepts `clean`/`simplify`), or `multi_convex` (convex decomposition). The op sets the mesh's `owner` to the scene root before baking so the generated subtree serializes.

```json
{"scene_path": "props/crate.tscn", "node_path": "root/Mesh", "mode": "trimesh"}
```

### collision_from_sprite

Traces a sprite's alpha silhouette into `CollisionPolygon2D` children with `BitMap.opaque_to_polygons`. Adds one collider per opaque island.

```json
{"scene_path": "actors/enemy.tscn", "node_path": "root/Sprite2D", "texture": "art/enemy.png", "alpha_threshold": 0.1, "epsilon": 2.0, "one_way": false}
```

- `texture` defaults to the target `Sprite2D`'s texture. Points are centered automatically when the sprite is `centered`; add an extra `offset` if needed. Lower `epsilon` = more vertices (higher physics cost).

### bake_csg

Freezes a `CSGShape3D` tree into a static `ArrayMesh` (+ optional collision). CSG geometry updates are deferred one frame, so this op runs inside the live SceneTree and awaits frames before baking. Point `node_path` at the CSG root (`is_root_shape`).

```json
{
  "scene_path": "proto/level.tscn",
  "node_path": "root/CSGCombiner3D",
  "out_mesh": "meshes/level.res",
  "bake_collision": true,
  "replace_with_meshinstance": true,
  "save_path": "proto/level_baked.tscn"
}
```

- `out_mesh` saves the baked mesh. `replace_with_meshinstance` swaps the CSG node for a `MeshInstance3D` (plus a `StaticBody3D`/`CollisionShape3D` when `bake_collision` is set) and rewrites the scene to `save_path` (or in place). Without `replace_with_meshinstance` the scene is untouched.

### gltf_export

Exports an edited scene (or a subtree via `node_path`) to `.glb`/`.gltf` through `GLTFDocument`. Import stays with the standard `--import` pipeline.

```json
{"scene_path": "scenes/level.tscn", "node_path": "root", "out": "export/level.glb"}
```

- `out` may be `res://`, `user://`, an absolute build path, or a bare project-relative path. The extension (`.glb` binary vs `.gltf` text) selects the format.

- glTF carries 3D geometry only. A scene (or `node_path` subtree) that contributes no meshes is an error and nothing is written — it used to exit 0 with a mesh-less file whose empty buffer then broke every later `--import`. The payload reports `mesh_count` and `node_count`.

### build_replication_config

Authors a `SceneReplicationConfig` `.tres` for a `MultiplayerSynchronizer`. Property paths are relative to the synchronizer's `root_path` (default its parent). `replication_mode` is `never`, `always`, or `on_change`.

```json
{
  "resource_path": "net/player_repl.tres",
  "properties": [
    {"path": ".:position", "spawn": true, "replication_mode": "on_change"},
    {"path": ".:velocity", "replication_mode": "always"}
  ]
}
```

- Assign the result with `configure_node` (`replication_config`) on the synchronizer. `resource_batch` can also build this via `call_method`; this op just labels the ordering and avoids the deprecated `property_set_sync`/`property_set_watch`.

## Unit Tests (Bundled `mini`, GUT, GdUnit4)

Godot has no built-in project test runner. `scripts/test/run_tests.py` covers three and normalizes their exit codes. GUT and GdUnit4 are addons that must be downloaded; **`mini` is bundled with this skill and needs nothing** — two files copied into the project. Full guide: `references/testing.md`.

Install the bundled framework. It writes `res://tests/test_case.gd` (the base class) and `res://tests/test_example.gd` (a worked suite that passes as-is), and refuses to overwrite either:

```bash
python3 /absolute/godot/scripts/test/run_tests.py /absolute/project --init-mini
```

Detect the framework and run every suite:

```bash
python3 /absolute/godot/scripts/test/run_tests.py /absolute/project --pretty
```

Run only the scripts and tests whose name contains a substring:

```bash
python3 /absolute/godot/scripts/test/run_tests.py /absolute/project --select example
```

Name a framework explicitly, with its own tests directory and JUnit report:

<!-- replay: skip — external-tool:gut (GUT must be installed under addons/gut/ first) -->
```bash
python3 /absolute/godot/scripts/test/run_tests.py /absolute/project --framework gut --tests-dir test --junit-xml /absolute/output/report.xml
```

- Detection order: `addons/gut/gut_cmdln.gd` → GUT; `addons/gdUnit4/bin/GdUnitCmdTool.gd` → GdUnit4; `res://tests/test_case.gd` or any script extending it → `mini`. Default tests dir: `test/` then `tests/`. `--framework mini|gut|gdunit4` overrides.
- Exit mapping: GUT `0` pass / `1` failures; GdUnit4 `0` pass, `100` failures, `101` warnings (treated as pass); mini `0` when `ok`. GdUnit4 writes HTML+JUnit reports under `res://reports/`.
- `--dry-run` prints the detection result and exact command without running — use it to verify wiring before a long suite.
- mini payload: `counts{scripts,tests,passed,failed,errors,skipped,pending,risky,timed_out,non_test_failures}`, `failures[{script,test,line,message,status}]`, `results[]`, `notes[]`, `duration_s`. A test killed by a GDScript runtime error is `error`, not a pass; a test with no assertion is `risky` (`--strict` fails on it); a hung test is `timeout` after `--test-timeout` (default 10 s) and the run continues.
- Running zero tests is never a pass: an empty tests directory, or a `--select` that matches nothing, exits 1 unless `--allow-empty`.
- Minimal mini test: `extends "res://tests/test_case.gd"` + `func test_x(): assert_eq(2 + 2, 4)`. Minimal GUT test: `extends GutTest` + `func test_x(): assert_eq(2 + 2, 4)`. Minimal GdUnit4 test: `extends GdUnitTestSuite` + `func test_x(): assert_int(4).is_equal(2 + 2)`.

## Import And Validation

### Static Lint (No Godot Needed)

```bash
python3 /absolute/godot/scripts/debug/lint_project.py /absolute/project --pretty
```

The same walk, restricted to some of the eleven categories:

```bash
python3 /absolute/godot/scripts/debug/lint_project.py /absolute/project --only godot3_api,node_ref
python3 /absolute/godot/scripts/debug/lint_project.py /absolute/project --only input_action,group_ref,res_path
python3 /absolute/godot/scripts/debug/lint_project.py /absolute/project --only godot3_api,godot3_shader
```

Runs without a Godot binary, without an import step, in well under a second, and prints the same JSON shape as `godot_log_parser.py`: `ok`, `counts`, and a `diagnostics` array of `severity`, `category`, `message`, `file`, `line`, `suggested_fix` (plus `rule`, a `scan_summary` of files scanned per kind, and a `suppressions` summary). Exit code is 1 when any error-level diagnostic exists.

- Severity has one meaning: **error** = Godot refuses to parse or load the file, so the project does not run; **warning** = it compiles and runs but is risky. Every severity was checked against `godot 4.7.stable` rather than assumed.
- Eleven categories, all fixed names: `godot3_api`, `godot3_shader`, `inference`, `node_ref`, `unique_name`, `signal_target`, `missing_resource`, `input_action`, `group_ref`, `res_path`, `animation_ref`. `--only cat1,cat2` filters; `--path <subdir>` restricts the walk; `--warnings-as-errors` fails on warnings; `--include-addons` opts `addons/` back in (`.godot/`, hidden directories, `.import` files and any directory holding a `.gdignore` are always skipped).
- `godot3_api` catches Godot 3 API in a 4.x project — `onready var`, `export var`, `yield(`, `.instance()`, `setget`, string-form `connect("sig", obj, "method")`, `move_and_slide(velocity)`, `rand_range`, `deg2rad`, `File.new()`, `rect_min_size`, `margin_left`, `Color.white`, and the renamed classes (`KinematicBody2D`, `Spatial`, `Sprite`, `Camera`, `Pool*Array`, `StreamTexture`, …) both in `.gd` and as `type="…"` in `.tscn`/`.tres`. Every rule's fix names the exact 4.7 replacement. `references/godot3_to_4.md` is the same table as a rename doc; `--list-rules` regenerates it.
- `inference` checks the type `:=` actually produces, classifying the **outermost** expression of the right-hand side — so `var p := _to_path(params.get("p", ""))` is silent when `_to_path()` declares `-> String`. Error (Godot refuses to parse): `.get()`, a `[...]` read from an untyped `Array`/`Dictionary`, `JSON.parse_string()`, `null`, `.call()`, a call into a same-file function with no `-> Type`. Warning (compiles, but the variable is typed bare `Node` and every later `.text`/`.play()` is unchecked): `$Node`, `%Unique`, `get_node()`, `.instantiate()`. `load()`/`preload()` are not reported — the analyzer types them. See `references/gdscript_conventions.md`.
- `node_ref` / `unique_name` resolve every `$Path`, `%Name`, and bare `get_node("…")` in a script against the tree of each `.tscn` that attaches it — following `..`, and descending into an `instance=ExtResource(…)` child scene when a path reaches into one. A script attached to a sub-scene root is checked against that sub-scene, not the level that instances it. The fix names the scene, the node the script is attached to, and the children that *do* exist (`Panel has children: Title, Icon`).
- `signal_target` checks every `[connection]`: `from`/`to` must be real nodes and the target's script must define the handler — `func <method>(` in GDScript, `<method>(` in a `.cs` file, and any other scripting language is skipped rather than guessed. A wrong path is dropped silently by Godot, and a missing method only fails when the signal fires.
- `missing_resource` checks `[ext_resource]` paths, `preload()`/`load()` literals, and `project.godot`'s `run/main_scene` and `[autoload]` entries. A scene with a missing `ext_resource` still loads and instantiates, so nothing else reports it.
- `godot3_shader` runs the Godot 3 → 4.x shader renames over `.gdshader`/`.gdshaderinc` and over the `code = "…"` of a Shader sub-resource inside a `.tscn`/`.tres` (the diagnostic sits on the `code =` line and the message names the line inside the embedded source). `hint_color`/`hint_albedo` → `source_color`, `hint_black`/`hint_white` → `hint_default_black`/`hint_default_white`, `hint_aniso` → `hint_anisotropy`, `SCREEN_TEXTURE`/`DEPTH_TEXTURE`/`NORMAL_ROUGHNESS_TEXTURE` → a `uniform sampler2D … : hint_screen_texture` (and friends), `WORLD_MATRIX`/`EXTRA_MATRIX` → `MODEL_MATRIX`, `CAMERA_MATRIX` → `INV_VIEW_MATRIX`, `INV_CAMERA_MATRIX` → `VIEW_MATRIX`, `TRANSMISSION` → `BACKLIGHT`, `ALPHA_SCISSOR` → `ALPHA_SCISSOR_THRESHOLD`, `NORMALMAP(_DEPTH)` → `NORMAL_MAP(_DEPTH)`, `SIDE` → `FRONT_FACING`, `CLEARCOAT_GLOSS` → `1.0 - CLEARCOAT_ROUGHNESS`, `SHADOW_ATTENUATION` → `ATTENUATION`, `LIGHT_HEIGHT` → `LIGHT_VERTEX.z`, `MODULATE` → your own `uniform vec4 : source_color` (4.7 has no `MODULATE`), `depth_draw_alpha_prepass` → `depth_prepass_alpha`, `depth_test_disable` → `depth_test_disabled`, `async_visible`/`async_hidden` → delete, and a `.shader` file → `.gdshader`. Every row was verified by compiling the Godot 3 form *and* its replacement on 4.7; `hint_normal`, `OUTPUT_IS_SRGB`, `AT_LIGHT_PASS`, `ATTENUATION`, `hint_roughness_gray`, `specular_toon` and `specular_disabled` still compile on 4.7 and are deliberately not rules. A shader that declares the name itself (`uniform sampler2D SCREEN_TEXTURE : hint_screen_texture;`, the engine's own migration advice) is not reported. A shader that fails to compile renders as the plain default material with no runtime error, which is why this is worth a static pass.
  One diagnostic, wrapped (the tool prints JSON; `message` and `suggested_fix` verbatim):
  ```
  error godot3_shader/shader_screen_texture res://shaders/legacy.gdshader:11
   message: The `SCREEN_TEXTURE` built-in was removed in Godot 4.x; the screen is read through
     a uniform with a hint. Verified on godot 4.7: the shader fails to compile, and a shader
     that does not compile renders as the plain default material with no runtime error —
     nothing in the log says why.
   suggested_fix: Add `uniform sampler2D SCREEN_TEXTURE : hint_screen_texture,
     filter_linear_mipmap;` near the top of the shader and leave the
     `texture(SCREEN_TEXTURE, SCREEN_UV)` calls alone — that is the engine's own
     minimal-change migration. A fresh shader should name the uniform `screen_tex` instead.
     The node must be under a BackBufferCopy (2D) for the read to see anything.
  ```
- `input_action` (**error**) takes every action-name *literal* — or an identifier the same file declares as a `const` holding one, since a const cannot be reassigned (`const FIRE: StringName = &"fire"` then `Input.is_action_pressed(FIRE)`) — passed to `Input.is_action_pressed/just_pressed/just_released/released`, `get_action_strength`, `get_action_raw_strength`, `get_axis`, `get_vector`, `action_press/release`, `InputMap.action_*`/`erase_action`, and `<event>.is_action*`, and requires something to define it: `project.godot`'s `[input]`, one of the engine's 72 built-in `ui_*` actions (read out of the running engine with `InputMap.get_actions()`, not guessed), or an `InputMap.add_action("…")` anywhere in the project. `&"jump"` counts; a plain `var`, a `static var`, a const from another file, an enum and a built expression (`"pre" + "fix"`) are never guessed at. An action the project probes with `InputMap.has_action("…")` is deliberately optional and is never reported, and a method the project defines itself (`func is_action_pressed(...)`) is not the engine's. Message lists the defined actions plus the nearest name; the fix is the `project_batch` call.
  ```
  error input_action/undefined_input_action res://scripts/player_platformer_2d.gd:52
   message: `Input.is_action_just_pressed()` uses the action `Jump`, which nothing defines: it
     is not in project.godot's `[input]` section, it is not one of the engine's built-in `ui_*`
     actions, and no script calls `InputMap.add_action("Jump")`. At runtime Godot prints
     `ERROR: The InputMap action "Jump" doesn't exist` (or silently answers false, depending on
     the call) and the input never fires. Did you mean `jump`? Actions this project defines:
     jump, move_left, move_right.
   suggested_fix: Fix the spelling to `jump`, or create the action and bind a key (32 = Space;
     pick your own keycode):
       godot --headless --path /absolute/project --script
         /absolute/path/to/godot/scripts/core/dispatcher.gd project_batch
         '{"actions":[{"type":"add_input_action","action_name":"Jump"},
           {"type":"add_input_event","action_name":"Jump","event":{"__resource_type":
           "InputEventKey","properties":{"physical_keycode":32}}}]}'
     If the action is instead created at runtime, call `InputMap.add_action("Jump")` before the
     first use, or guard the use with `InputMap.has_action("Jump")` — the linter finds either
     and goes quiet.
  ```
- `group_ref` (**warning**) does the same — literals, `&"name"` and same-file `const`s alike — for `get_nodes_in_group` / `get_first_node_in_group` / `is_in_group` / `call_group(_flags)` / `notify_group(_flags)` / `set_group(_flags)`: something must provide the group — a `groups=[…]` on a `.tscn` node, an `add_to_group("…")` in any script (order does not matter), or a `[global_group]` entry in `project.godot`. The call succeeds and returns nothing, so the feature simply never happens.
- `res_path` (**warning**, **error** for `extends "res://…"`) checks every `res://` string literal in a `.gd` against the filesystem, case-sensitively on every host — `res://art/Hero.png` loads on macOS and Windows and fails on Linux and in every exported `.pck`, and that mismatch gets its own message naming the real spelling. Silent for: a literal with a `%s`/`{}`/`<…>` placeholder, a concatenation fragment, a `String` method argument (`path.begins_with("res://addons/")`), `user://`, `uid://`, a path the project writes (`FileAccess.open(…, WRITE)`, `ResourceSaver.save`, `DirAccess.make_dir*`), a path it only probes (`FileAccess.file_exists`, `DirAccess.dir_exists*`, `ResourceLoader.exists`, `resource_path =`) — including through the constant holding it — and an `@export var … = "res://…"` default, which exists to be overridden. `preload()`/`load()` stay with `missing_resource`; `res_path` never repeats a line that category already reported.
- `animation_ref` (**warning**) resolves `$Node.play("name")`, `%Node.play(&"name")`, `play_backwards`/`queue`, the same calls through an `@onready` binding (`@onready var anim: AnimatedSprite2D = $Sprite` then `anim.play("walk")` — the style every bundled template uses), and a `.tscn`'s own `animation`/`autoplay`/`current_animation`, against the node's real animations — an `AnimatedSprite2D`/`AnimatedSprite3D`'s `SpriteFrames` or an `AnimationPlayer`'s `libraries/…`, inline as a sub-resource or on disk as a `.tres`. It speaks only when that resource is readable; a node it cannot resolve, a frames resource that comes from an instanced scene, or an unreadable library all mean silence. A binding counts only when it is certain: declared exactly once as an `@onready var` whose whole right-hand side is one `$Path` / `%Name` / `get_node("Path")` (an `as Type` cast is fine), and never reassigned, re-declared, or shadowed by a parameter or a `for` variable — a plain `var anim = $Sprite` inside `_ready()` does not qualify. Like `node_ref`, a script attached to several scenes is checked against each of them and reports per scene. The message lists the animations that do exist.
  ```
  warning animation_ref/unknown_animation res://scripts/anim.gd:4
   message: `$Sprite.play("wlak")` names an animation that does not exist. res://scenes/anim.tscn
     resolves `$Sprite` to the AnimatedSprite2D `Sprite`, whose animations come from the inline
     SpriteFrames in res://scenes/anim.tscn and are: idle, walk. Did you mean `walk`? An
     AnimatedSprite2D silently keeps playing the old animation when the name is unknown.
   suggested_fix: Use one of idle, walk, or add `wlak` to the inline SpriteFrames in
     res://scenes/anim.tscn (`build_sprite_frames` for a SpriteFrames, `build_animation` for an
     AnimationPlayer library).
  ```
- **Suppressing one finding.** `# lint:ignore <category>[,<category>…]` on the offending line or on the line directly above it drops those categories there; a bare `# lint:ignore` drops all of them. The comment marker follows the file type — `#` in `.gd`, `;` in `.tscn`/`.tres`/`project.godot`, `//` in `.gdshader`. Use it for the case the linter cannot know about: `scripts/core/node_config_rules.gd` has to *name* `ParallaxBackground` (deprecated but real in 4.7) to re-implement the editor's own "ParallaxLayer only works under a ParallaxBackground" warning, so that line carries `# lint:ignore godot3_api`. Suppressions are summarised in the report under `suppressions: {total, used, unused[{file, line, categories, reason}]}`; one that matched nothing — including one naming a category that does not exist — is listed there and **never** becomes a diagnostic or changes the exit code. (Read `unused` from a full run: under `--only` a suppression for a filtered-out category correctly counts as unused.)
  ```gdscript
  if not (node.get_parent() is ParallaxBackground):  # lint:ignore godot3_api
  # lint:ignore res_path,input_action
  var generated := "res://build/atlas.png"
  ```
- **`.gdignore`.** A directory holding a `.gdignore` file is invisible to Godot — never imported, never scanned, nothing in it loadable — so the linter skips it too, for both scanning and the cross-reference indexes (an `add_to_group()` in there does not define a group). `scan_summary.skipped_gdignore_dirs` counts them.
- It is text-only and errs toward silence: node paths built at runtime (`str()`, `+`, `%s`) are skipped rather than guessed, only a bare (or `self.`) `get_node()`/`$`/`%` is resolved (`slot.get_node("Icon")` belongs to another node), and a name the project itself defines — `class_name File`, `static func empty()` — suppresses the matching rename rule. A node that comes from `instance=ExtResource(...)` is another scene's root: its script is checked against that `.tscn`, never the level that instances it. Nodes added with `add_child()` are reported, because they are not in any `.tscn`. Multi-line `"""` strings are scanned as code.
- `validate_project.py` runs this pass first and merges the result: lint entries appear at the top of `diagnostics` with `"source": "lint"`, their counts fold into `counts`, the raw report is under `lint`, and lint errors alone make `ok` false. `--no-lint` opts out.

Audit existing import state:

```bash
godot --headless --path /absolute/project \
  --script /absolute/godot/scripts/core/dispatcher.gd \
  audit_imports '{"project_path":"res://","include_entries":true}'
```

Run Godot's importer first, then audit:

```bash
python3 /absolute/godot/scripts/import/import_project.py /absolute/project --pretty
```

Use `--audit-only` to skip reimport. Statuses are `ok`, `missing`, `invalid`, `stale`, and `orphaned`.

Probe the engine and host toolchain, then run the comprehensive validator:

```bash
python3 /absolute/godot/scripts/debug/probe_environment.py /absolute/project --pretty
python3 /absolute/godot/scripts/debug/validate_project.py /absolute/project --pretty
```

`validate_project.py` loads GDScript, scenes, shaders, resources, GDExtensions, and editor plugins. When a root `.csproj` exists, it also runs Godot's `--build-solutions`; override with `--csharp always|never`.

It runs Godot with `-d --ignore-error-breaks`, so its report includes the GDScript warnings the editor shows — which a plain headless run never prints — for **every** script in the project, not just the ones a boot happens to load. Output carries `counts` and `diagnostics` (same shape as `run_project.py`) alongside the file-level `static` summary, and `ok` is false whenever an error-level diagnostic appears even if every file technically loaded. Flags: `--warnings-as-errors` to fail on warnings, `--no-warnings` to drop them from the report, `--no-debugger` to reproduce the old warning-free behaviour, `--no-instantiate` to skip the scene-instantiation pass below.

### check_project And The Instantiate Pass

`validate_project.py` is a wrapper around the `check_project` operation, which can also be called directly:

```bash
godot --headless --debug --ignore-error-breaks --path /absolute/project \
  --script /absolute/godot/scripts/core/dispatcher.gd \
  check_project '{}' 2>&1 \
  | python3 /absolute/godot/scripts/debug/godot_log_parser.py -
```

Parameters: `project_path` (default `res://`, restricts the walk to a subtree), `instantiate` (bool, **default `true`**), `config_warnings` (bool, **default `true`**) and `physics_layers` (bool, **default `true`**). The JSON summary reports `checked`, `failed_count`, `failed` (path / kind / reason), `counts` per kind, plus `instantiate` and `scenes_instantiated`, and — from the two options below — `config_warnings[]`, `config_warning_count`, `config_hint_count`, `config_warnings_enabled` and `physics_layers`.

Every `.tscn`/`.scn` that loads is also passed through `PackedScene.instantiate()`. This matters because `load()` accepts every broken node hierarchy — a directory of scenes containing every hierarchy mistake in `references/tscn_format.md` used to report `"failed_count": 0`. What the pass adds:

| Mistake in the `.tscn` | What instantiating produces | Reported as |
| --- | --- | --- |
| Root `[node]` carries `parent="."` | `ERROR: Invalid scene: root node X cannot specify a parent node.`; `instantiate()` returns `null` | **Failure** in `failed[]` + an error diagnostic |
| Non-root `[node]` has no `parent=` | `ERROR: Invalid scene: node X does not specify its parent node.`; `instantiate()` returns `null` | **Failure** in `failed[]` + an error diagnostic |
| `parent=` names a node that does not exist | `WARNING: Parent path './VBox' for node 'Label' has vanished when instantiating: 'res://…tscn'.`; the node is reparented to the root as `VBox#Label` | **Warning** only — the scene still instantiates. `--warnings-as-errors` makes it fail |
| Every node carries `parent="."` (fully flat tree) | Nothing at all — a flat tree is valid | **Not caught.** Only `inspect_scene` reveals it |

The two `Invalid scene:` errors name the offending *node*, never the scene, so read the scene path from the `failed[]` entry (the log parser files them under category `scene_hierarchy`; the vanished-parent warning does name its scene and is attributed to it). A failed instantiate also makes the engine leak the half-built nodes, so a run that reports one ends with a harmless `WARNING: N ObjectDB instances were leaked at exit`.

**What instantiating executes.** The scene root script's `_init()`, and every script setter for a property stored in the `.tscn` (an `@export` with a custom setter runs with the stored value). `_enter_tree()` / `_ready()` do **not** run — nothing is added to a tree — and `get_tree()` is `null` inside `_init()` and inside those setters. That is byte-for-byte what the running game does when it instantiates the same scene, so an error raised here is an error the game would raise too. Autoload singletons **are** available (the dispatcher defers the operation until the `SceneTree` has registered them), so a scene script that reads one is not a false failure. Pass `{"instantiate": false}` (or `--no-instantiate`) for a pure load-only pass that runs no project code — the right choice only when a scene's `_init()` has side effects you do not want, since it re-opens the hierarchy blind spot.

### Node Configuration Warnings (`config_warnings`, `physics_layers`)

`Node::get_configuration_warnings()` — the editor's yellow triangles — is not bound outside the editor in 4.7, so `check_project` re-derives the high-signal subset over each instantiated scene instead. Both options ride along on the instantiate pass and are silently off without it.

```bash
godot --headless --path /absolute/project \
  --script /absolute/godot/scripts/core/dispatcher.gd \
  check_project '{"config_warnings": true, "physics_layers": true}'
```

- `config_warnings` (default `true`): adds `config_warnings[]` — `{scene, node_path, node_type, rule, severity, message, fix}` — plus `config_warning_count` (warnings only) and `config_hint_count`. `severity` is `warning` for editor parity (the engine's own wording) or `hint` for this skill's heuristics. `node_path` uses the `root/...` convention; `fix` is a **runnable dispatcher call**.
- Every `warning` is also printed as `WARNING: [node_config:<rule>] <res://scene.tscn>::<node_path>: <message>` with an indented `fix: …` continuation, so `godot_log_parser.py` reports it with category `node_config`, `file` = the scene, and `suggested_fix` = the fix. Hints never reach the log and never fail a run.
- `physics_layers` (default `true`): adds `physics_layers: {"2d": {"layers": [...]}, "3d": {...}, "findings": [...]}` — per layer bit the project's `layer_names/<dim>_physics/layer_N` name, `occupied_by`/`scanned_by` (≤5 `scene::node_path` samples) and full counts, over collision objects, TileSet physics layers, `GridMap`, `CSGShape3D` with `use_collision`, rays and shape casts. Findings (all `hint`): `mask_targets_empty_layer`, `layer_never_scanned`, `body_mask_zero`, `body_layer_zero`.

`validate_project.py` surfaces the same data under `node_config` (`ran`, `counts`, `hints[]`, `physics_layers`) and accepts `--no-config-warnings` / `--no-physics-layers`. The full rule table, the instanced/inherited de-duplication rules and the limits are in **`references/node_config.md`**.

`inspect_scene` takes the same `config_warnings` flag (default `false`) for a single scene; it is the one option that makes `inspect_scene` instantiate the scene instead of only reading its `SceneState`.

### Smoke-Run Every Scene (`smoke_scenes.py`)

`run_project.py` boots the *main* scene, and `check_project` instantiates scenes without ever running `_ready`/`_process`. Neither reaches the pause menu's `_ready`, level 3, the game-over screen, or a branch that only runs while a key is held. `smoke_scenes.py` does: it boots **every** scene, one Godot process per scene, for a bounded amount of *game* time.

```bash
python3 /absolute/godot/scripts/debug/smoke_scenes.py /absolute/project --seconds 2 --pretty
```

One process per scene is the point: a crash or hang cannot take the other scenes down, every scene starts with clean autoload state, and every log line belongs to exactly one scene. Each process runs with `--headless -d --ignore-error-breaks --fixed-fps 60`, stdin on `/dev/null`, in its own process group so a timeout kills the whole group.

| Flag | Meaning |
| --- | --- |
| *(nothing)* / `--all` | Every `.tscn` in the project except `addons/`, hidden directories (`.godot/`) and any folder holding a `.gdignore`. **`--all` is the default.** |
| `--scenes res://a.tscn …` | Exactly these scenes. A path that does not exist is a usage error (exit 2) that lists the scenes that do. |
| `--include GLOB` / `--exclude GLOB` | Filter the discovered list; repeatable; matched against the `res://` path and the project-relative path. |
| `--seconds 1.0` | Game time per scene. Under `--fixed-fps` this costs almost no wall time: 20 game-seconds of a physics platformer ran in 0.24 s. |
| `--fuzz`, `--fuzz-seed N`, `--fuzz-mouse` | Fire the project's real input actions / mouse at the scene (below). |
| `--profile` | Sample `Performance` monitors and report avg/p95/max plus start/end. |
| `--jobs N` | Run N scenes at once. Output order stays sorted by scene path, so `--jobs 4` and `--jobs 1` produce the same report. |
| `--timeout S` | Wall-clock kill per scene (default `max(30, seconds*3 + 20)`). |
| `--real-time` | Drop `--fixed-fps 60` and run at wall-clock pace (see the timing note below). |
| `--warnings-as-errors`, `--no-warnings` | Same meaning as in `run_project.py`. |
| `--log-dir DIR` | Keep each scene's raw combined log as `DIR/<scene path with / as __>.log`. |
| `--dry-run` | Print the selected scenes and the command for the first one, run nothing. |

Output: one JSON document — `{ok, project, godot_version, wall_seconds, seconds_per_scene, counts{scenes, passed, failed, errors, warnings, findings}, scenes[]}` — where each scene carries `{scene, ok, returncode, duration_s, timed_out, frames, seconds_simulated, ended, counts, findings[], diagnostics[], perf{…}, fuzz{seed, events, event_count}?, destination?, notes[]?}`. `diagnostics[]` is exactly the `godot_log_parser.py` shape used by `run_project.py`. **Exit 0 only when every scene passed**; 1 when one failed; 2 for a usage error or an unusable `--godot-bin`.

A scene fails on an error-level diagnostic (script error, parse error, engine error), a crash, a timeout, or an error-level finding. Warnings fail only under `--warnings-as-errors`.

| Finding `type` | Severity | What it means |
| --- | --- | --- |
| `node_growth` | warning | Node count was still climbing at the end (compared 40 % into the run against the last sample, so startup spawning never trips it). Bullets/particles/damage numbers that are never `queue_free()`d. |
| `orphan_nodes` | warning | Nodes still alive outside the tree after the scene was freed — `Node.new()` never added, or `remove_child()` without a free. Only checked when the run ends normally. |
| `static_memory_growth` | warning | `MEMORY_STATIC` grew ≥ 8 MB and ≥ 25 % and was still growing: `load()` in `_process`, an array only ever appended to. |
| `timed_out` | error | The process group was killed (infinite loop or a blocking call). The partial log is still parsed and reported. |
| `crashed` | error | Non-zero or signal exit with no result line; the signal name is in the message. |
| `instantiate_failed` / `load_failed` / `scene_missing` | error | The scene never got as far as running. The engine's own message is in `diagnostics[]`. |
| `scene_changed` | info | The scene called `change_scene_to_*` or freed itself; `destination` names where it went. Not a failure — the destination is its own entry under `--all`. |
| `quit_called` | info | The scene called `get_tree().quit()`, so the rest of the run never happened. Not a failure. |

**Fuzzing.** `--fuzz` reads the project's own `InputMap`, picks an action (project actions 80 % of the time, a curated 15 `ui_*` built-ins 20 % — the engine registers ~95 `ui_*` actions and the rest are text-editing verbs), duplicates one of that action's bound events and feeds it through `Input.parse_input_event`, so `_input`/`_unhandled_input`/`_gui_input` **and** `Input.is_action_pressed` polling both see it. Hold lengths vary from 1 to 12 frames, the exact event that was pressed is the one released, and everything is released before the run ends. `--fuzz-mouse` adds motion and clicks inside the viewport and clicks on the centres of visible `BaseButton`s. Every event is printed live as `[SMOKE_INPUT] f42 +jump` (so a hard crash still shows what was pressed) and collected in `fuzz.events`. The same `--fuzz-seed` replays byte-for-byte:

```bash
python3 /absolute/godot/scripts/debug/smoke_scenes.py /absolute/project \
  --seconds 4 --jobs 4 --fuzz --fuzz-mouse --fuzz-seed 7 --profile
```

**Profiling and the timing note.** `--profile` adds `perf.monitors` with avg/p95/max/min/start/end for `fps`, `process_ms`, `physics_process_ms`, `object_count`, `node_count`, `orphan_node_count`, `static_memory_mb` and 2D/3D active objects + collision pairs, plus the flat `fps_avg`, `process_ms_p95`, `physics_ms_p95`. `--fixed-fps 60` decouples game time from wall time — timers, tweens and `_physics_process` all advance exactly 1/60 s per iteration — but the engine refreshes its **timing** monitors once per *real* second, so a fast run leaves them at `fps 1.0` / `0.0 ms`. Those three flat keys are reported as `null` in that case (never as a fake number) and the always-valid `perf.frame_ms` — wall time per frame, measured by the runner, which is pure CPU cost because nothing throttles a headless run — is what to read instead. For engine-reported frame times, re-run the one slow scene with `--real-time --seconds 3`. Node, object, orphan and memory monitors are exact in both modes; the dummy renderer makes draw calls / primitives / video memory meaningless, so they are not reported at all.

```bash
python3 /absolute/godot/scripts/debug/smoke_scenes.py /absolute/project \
  --scenes res://scenes/main.tscn --profile --pretty
```

**Limits.** A scene is booted in isolation, so one that expects to be a child of a level (a pause menu reading `get_parent().player`) reports errors the running game would not — read the diagnostic before "fixing" it, or `--exclude` those scenes. Fuzzing is random, not exhaustive: it proves a code path crashes, never that one is safe. `--fuzz` reproducibility holds under the default `--fixed-fps`; `--real-time` does not run a fixed number of frames, so the event stream only matches approximately.

### Move Or Rename Files Safely (`move_resource.py`)

**Never `mv` a file inside a Godot project.** Dragging a file in the editor's FileSystem dock rewrites every reference to it; a shell `mv` rewrites nothing, and the damage is often *silent*. Verified on 4.7: an `[ext_resource]` carrying both `uid=` and `path=` resolves through the **uid**, so moving a texture together with its `.import` leaves the project importing, loading and running with **zero diagnostics** while the recorded path is wrong — the static `missing_resource` lint is the only thing that notices. Move the same file without its `.import` and it breaks loudly instead. Use the tool for both cases.

```bash
python3 /absolute/godot/scripts/project/move_resource.py /absolute/project scripts/main.gd actors/main.gd --dry-run --pretty
```

Drop the `--dry-run` to apply it. A destination that is an existing folder, or ends in `/`, moves *into* it and keeps the basename:

```bash
python3 /absolute/godot/scripts/project/move_resource.py /absolute/project art/enemy.png art/sprites/
```

A whole reorganisation is one atomic plan in a JSON file:

```bash
cat > /absolute/moves.json <<'JSON'
[
  {"from": "scripts/main.gd",        "to": "actors/main.gd"},
  {"from": "scenes/mob.tscn",        "to": "levels/mob.tscn"},
  {"from": "props",                  "to": "assets/props"},
  {"from": "theme/panel_style.tres", "to": "ui/panel_style.tres"}
]
JSON
python3 /absolute/godot/scripts/project/move_resource.py /absolute/project --map /absolute/moves.json
```

Stdlib Python; Godot is only needed for the final re-import. `SRC`/`DST` are project-relative or `res://`. `SRC` may be a **file or a folder**; `DST` follows `mv` semantics — an existing folder or a trailing `/` moves *into* it keeping the basename, anything else is the new path. Destination folders are created, emptied source folders are removed.

| Flag | Effect |
| --- | --- |
| `--map FILE.json` | `[{"from": "...", "to": "..."}, …]` applied as **one atomic plan** — the "reorganise everything into folders" case. Conflicts, nesting and cycles are detected before anything moves. |
| `--dry-run` | Prints the identical plan (`moved`/`edits`/`mentions`/`warnings`/`counts`) and touches nothing. |
| `--no-import` | Skips the final `godot --headless --path PROJECT --import`. The payload then carries a `note`: the uid cache is stale until you run it (see below). |
| `--extra-ext .json,.md` | Extra extensions to scan for `res://` references beyond the built-in set. |
| `--include-addons` | Also rewrite references inside `addons/` (skipped by default). |
| `--pretty` | Indent the JSON. |

**What gets rewritten.** Every text file of the project: `.tscn`/`.tres` (`[ext_resource] path=`), `.gd`, `.gdshader`/`.gdshaderinc` (including relative `#include` paths, recomputed when either end moves), `.import` (`source_file=`), `project.godot` (`run/main_scene`, `[autoload]` values with their `*` prefix, `config/icon`, bus layout, translations, theme/font — anything holding a `res://` path), `export_presets.cfg` (paths and `include_filter`/`exclude_filter` entries), `override.cfg`, `.gdextension`, `.cs`, plus `--extra-ext`. In `.gd` only **inside string literals** — single, double, triple-quoted, `r"…"`, `&"…"` StringName and `^"…"` NodePath. A `res://` path inside a `#` comment is reported under `mentions[]` and left exactly as written, so you can decide; every other file type is rewritten wholesale (they have no comment syntax that could hold a path you would want stale). A `res://scene.tscn::SubResource_1` suffix is preserved. `.godot/`, `addons/`, hidden folders, folders holding a `.gdignore`, and binary files are never touched.

**Sidecars travel with the file**: `<name>.import` and `<name>.uid` (4.4+ script/shader UIDs), and everything inside a moved folder. **`uid://` references stay valid** because the uid lives in the sidecar (or in a `.tscn`/`.tres` header), and those move too — verified on 4.7 with `uid=`-bearing `[ext_resource]` lines. Case-only renames work on case-folding filesystems (macOS: a two-step rename), and a `SRC` whose capitalisation does not match the disk is refused rather than guessed.

**Refusals (exit `2`, nothing touched):** `SRC` missing (with the nearest real names), `DST` already exists, a destination outside the project, `project.godot` or anything under `.godot/`, a folder moved into itself, a `DST` whose parent is a file, and any `--map` that lists a path twice, targets one destination twice, nests one moved path inside another, or forms a cycle. Anything that fails **mid-apply** is rolled back from a temp-dir backup and also exits `2`.

**Then it proves the move.** `scripts/debug/lint_project.py --only missing_resource` runs before *and* after, and the report carries `verify: {ran, missing_before, missing_after, new_missing[]}`. `ok` is `false` (exit `1`) only when the move **introduced** a broken reference; breakage that was already there is not blamed on the move. Output shape:

```json
{"ok": true, "counts": {"files_moved": 8, "files_edited": 5, "references_rewritten": 6},
 "import": {"ran": true, "returncode": 0},
 "verify": {"ran": true, "missing_before": 0, "missing_after": 0, "new_missing": []}}
```

plus `moved[{from, to, kind, sidecars[], files, case_only_rename}]`, `edits[{file, line, before, after}]`, `mentions[{file, line, text}]` and `warnings[]`. Two blind spots are named there rather than missed: a **binary** `.scn`/`.res` (its reference table is not text — re-save it as `.tscn`/`.tres`) and any scanned file that is not valid UTF-8.

**Re-import is not optional.** Until the importer runs, `.godot/uid_cache.bin` still maps the moved uid to its *old* path, and a uid-bearing `[ext_resource]` resolves through that cache **before** its already-corrected text path — verified on 4.7: the scene fails with `Resource file not found: res://<old path>` even though the `.tscn` is right. The default `--import` rewrites the cache (old path gone, new path present) and regenerates `.godot/imported/<name>-<hash>.ctex` under the new hash; the previous `.ctex` is left behind as harmless cache garbage.

**Out of scope.** A move never changes a `class_name` — the class name lives in the script text, not in its path, so nothing needs renaming and nothing breaks. Renaming a *class* or a *node* is a different job: rename it in the source/scene and then check the fallout with `lint_project.py --only node_ref,unique_name,signal_target`.

## Scenario Runner

Create a scenario JSON and run it with `scripts/debug/run_scenario.py PROJECT SCENARIO`. The wrapper uses a rendered window when a screenshot step exists and headless mode otherwise. Force the choice with `--headless` or `--no-headless`.

```json
{
  "scene_path": "scenes/menu.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "settle_frames": 2,
  "steps": [
    {"type": "action", "action_name": "ui_accept", "pressed": true, "release_after": true},
    {"type": "mouse_button", "button_index": 1, "position": {"x": 640, "y": 360}, "pressed": true},
    {"type": "wait_frames", "frames": 2},
    {"type": "assert", "assertion": "property", "node_path": "Status", "property": "text", "expected": "Ready"},
    {"type": "screenshot", "path": "/absolute/output/menu.png"}
  ],
  "assertions": [
    {"assertion": "node_exists", "node_path": "StartButton"},
    {"assertion": "visible", "node_path": "Status", "expected": true}
  ],
  "performance_frames": 30,
  "log_assertions": [{"contains": "Level loaded", "min_count": 1}],
  "performance_assertions": [
    {"monitor": "process_time", "statistic": "maximum", "operator": "less_or_equal", "value": 0.02}
  ]
}
```

Step types are `wait_frames`, `wait_seconds`, `action`, `key`, `mouse_button`, `mouse_motion`, `joypad_button`, `joypad_motion`, `assert`, `wait_until`, `set_property`, `screenshot`, `ui_report`, `dump_tree`, `spatial_report`, and `log_marker`. An unsupported type is rejected with the full list.

- `wait_until`: polls a property assertion every frame until it passes or `timeout_seconds` (default 5) elapses — prefer it over guessing `wait_frames` counts. Fields match `assert` (`node_path`, `property`, `expected`, `operator`, `tolerance`).
- `set_property`: writes a typed value to a node's (sub)property and waits one frame — useful for arranging state before an interaction.
- `ui_report`: dumps the laid-out UI as text and machine-checks the layout — see below.
- `dump_tree`: prints the live node tree with the properties you name, and returns it as data — see below.
- `spatial_report`: the world-space sibling of `ui_report` — where every 2D/3D node sits, whether the camera can see it, whether a body is buried in the floor — see below.

**The run's log is part of the verdict.** The captured stdout and stderr are parsed exactly as `run_project.py` parses them and returned as `diagnostics` and `counts`. Any error-level line — a `SCRIPT ERROR`, a parse error, an engine `ERROR:`, a shader error — fails the scenario (`"ok": false`, exit 1, `errors[]` gains `Log error during the scenario: <message> (<file>:<line>)`), even when every assertion passed: a HUD script that dies every frame used to pass any scenario that asserted something else. Two ways to say the error is the point of the scenario: require it with a `log_assertions` entry whose `min_count` is at least 1 (the matching diagnostic is then expected, e.g. a corrupt-save test that asserts its own `push_error`), or set the top-level `"log_errors": "allow"` (diagnostics are still reported). Warnings and `info`-level notes never fail a scenario — `exit_leak` (shutdown bookkeeping) or `host_capability` (a display/audio driver probe that failed because the *host* has no GPU or no sound card, which is why a windowed scenario still passes on a CI runner; the `switching to OpenGL 3` warning beside it means the renderer actually in use is not the one `ProjectSettings` reports, so read `RenderingServer.get_current_rendering_method()`). The top-level keys are `scene_path`, `viewport_size`, `settle_frames`, `steps`, `assertions`, `log_assertions`, `log_errors`, `performance_frames`, `performance_assertions`, plus free-form `name`/`description`/`comment`/`notes` and anything starting with `_`; any other key fails the run and names these.

Property assertion operators are `equals`, `not_equals`, `greater_than`, `greater_or_equal`, `less_than`, `less_or_equal`, `contains`, and `approx`. Performance monitors are `fps`, `process_time`, `physics_process_time`, `static_memory`, `node_count`, `resource_count`, `draw_calls`, `primitives`, and `video_memory`; statistics are `average`, `minimum`, and `maximum`.

The root viewport is always sized before the scene is added: to `viewport_size` when given, otherwise to the project's own `display/window/size/viewport_width`/`viewport_height`. A headless display server opens a 64x64 window, so without this every anchor, container layout and viewport-space input coordinate would resolve against a viewport no player ever sees.

### Input And Timing Facts

- An `action` step calls `Input.action_press`/`action_release`, so it moves the polled state only and `_input` / `_unhandled_input` / `_gui_input` never run. Player controllers poll and work with it; pause menus, dialog advance and interact prompts need a `key` step, which feeds a real `InputEventKey` through `Input.parse_input_event`.
- Godot's built-in `ui_*` actions are bound by `keycode` (`ui_cancel` 4194305, `ui_accept` 4194309, `ui_down` 4194322); actions this skill creates use `physical_keycode`. Setting the wrong field produces an event matching no action at all.
- `wait_frames` counts *process* frames, and a headless run spins those far faster than the fixed 60 Hz physics tick, so `wait_frames: 60` is a fraction of a second of simulated falling. Use `wait_seconds` or `wait_until` for anything driven by gravity, `move_and_slide`, or a Tween.
- With `display/window/stretch/mode` set to `canvas_items`, a scenario's `viewport_size` resizes the window but the UI still lays out against the project's base viewport, so verifying a menu at "two resolutions" is one layout there. Size the type to the base viewport instead.

### screenshot

Captures the root viewport to a PNG **and** describes it as numbers, so a caller that cannot look at the image still learns whether anything was drawn, where, and in what colour. A screenshot step is the only thing that forces a rendered (non-headless) window.

```json
{"type": "screenshot", "path": "/absolute/output/menu.png",
 "expect": {"not_blank": true, "min_opaque_ratio": 0.1, "max_diff_ratio": 0.02, "compare_to": "res://tests/reference/menu.png"},
 "describe": {"ascii": true, "ascii_width": 80, "ascii_color": true}}
```

- `path` (required): `res://`, `user://`, or absolute. Parent directories are created.
- `describe` (optional): options handed to `image_describe.describe`. `ascii` adds a luminance-ramp rendering of the capture to the summary and prints it; `ascii_width` (default 64) sets its column count; `ascii_color` adds the `K W R G B Y C M` colour grid.
- `expect` (optional): each key that is violated fails the scenario the way a failed assertion does — the run continues, `ok` becomes false, and the message names the number that was actually measured.
  - `not_blank`: fails when every pixel is identical or everything is transparent. The message reports the unique-colour count, `opaque_ratio` and `mean_color`.
  - `min_opaque_ratio`: fails when the share of pixels with alpha > 0 is below the value.
  - `compare_to` + `max_diff_ratio`: loads that PNG and fails when more than `max_diff_ratio` of the pixels differ from it. A size mismatch is reported as its own failure — capture the reference at the same `viewport_size`.

An unknown key in either object is rejected with the accepted list rather than silently checking nothing.

Every capture appends to `screenshots` on the result JSON:

```json
{"path": "/absolute/output/menu.png", "width": 640, "height": 320, "passed": true,
 "summary": {"width": 640, "height": 320, "has_alpha": false, "blank": false, "opaque_ratio": 1.0,
             "content_bbox": {"x": 24, "y": 16, "w": 576, "h": 284},
             "content_bbox_normalized": {"x": 0.04, "y": 0.05, "w": 0.9, "h": 0.89},
             "mean_color": "#1a1a26", "dominant_colors": [{"hex": "#111122", "ratio": 0.82}],
             "unique_colors": 37, "quadrants": {"top_left": 0.31, "top_right": 0.2, "bottom_left": 0.29, "bottom_right": 0.2},
             "ascii": ["....====#####...", "..."]}}
```

and prints one grep-able line (plus the ASCII rows when asked for):

```
[SCENARIO] screenshot /absolute/output/menu.png blank=false opaque=1 bbox=24,16,576,284 dominant=#111122
```

`blank=true` on a scene you believe draws something is the single most useful signal here: it means the capture is one flat colour, so the node is hidden, outside the viewport, or was never added to the tree.

### ui_report

Walks the scene tree and reports every visible Control's post-layout global rect, then machine-checks the layout. It is how to see the UI without looking at an image, and it is what catches the failure mode where controls authored with `layout_mode = 0` and no offsets all land on each other at (0, 0) — a screenshot shows that instantly, no other text check shows it at all. Rects resolve identically headless, and `ui_report` alone never forces a rendered window.

- `node_path` (default `"."`): subtree to walk. Report paths stay relative to the **scene root** either way, so they paste straight into a later `node_path`.
- `include_hidden` (default `false`): also list controls that are not visible in tree. Hidden controls are described but never produce findings.
- `path` (optional): also write the report to a JSON file (`res://`, `user://`, or absolute).
- `label` (optional): names the report in the result; defaults to `steps[<index>]`.
- `ascii` (default `false`): also render the layout as a character map (see below).
- `ascii_width` (default `80`, clamped to 8–400): column count for that map.
- `fail_on` (optional): array of finding kinds that fail the scenario the way a failed assertion does, or `["any"]`. An unknown kind is rejected instead of silently gating on nothing.
- `min_overlap_ratio` (default `0.1`): the share of the smaller rect two siblings must share before the overlap is reported. Keeps 1px seams quiet.
- `strict_overlap` (default `false`): set to also report the backdrop case below.
- `settle_frames` (default `2`, minimum 1): frames awaited before sampling. Containers place their children through a deferred sort, so rects read in the same frame the tree changed still say (0, 0) and every child would look stacked. The step waits so callers never have to.

Reports arrive in `ui_reports` on the result JSON, in step order, and are written verbatim to `path`:

```json
{
  "label": "boot",
  "node_path": ".",
  "passed": false,
  "rect_format": "[x, y, width, height]",
  "viewport": {"width": 1280, "height": 720},
  "counts": {"controls": 4, "visible": 4, "hidden": 0, "findings": 1},
  "controls": [
    {"path": ".", "class": "Control", "rect": [0, 0, 1280, 720]},
    {"path": "Backdrop", "class": "ColorRect", "rect": [0, 0, 1280, 720]},
    {"path": "Panel/Title", "class": "Label", "rect": [0, 0, 160, 30], "text": "Inventory"},
    {"path": "Panel/Close", "class": "Button", "rect": [0, 0, 160, 31], "text": "Close"}
  ],
  "findings": [
    {"kind": "overlap", "nodes": ["Panel/Title", "Panel/Close"],
     "rects": [[0, 0, 160, 30], [0, 0, 160, 31]], "parent": "Panel",
     "overlap_rect": [0, 0, 160, 30], "ratio": 1,
     "message": "Panel/Title (Label) [0, 0, 160, 30] and Panel/Close (Button) [0, 0, 160, 31] cover 100% of the smaller rect, but their parent Panel (Control) leaves placement to the author"}
  ],
  "file": "/absolute/output/boot_ui.json"
}
```

Control entries carry `text` when the node has a non-empty text property (trimmed to 60 characters), `top_level: true` when the node opts out of its parent's transform, and — only when `include_hidden` is set — `visible` plus `self_hidden` for the node that actually holds the `visible = false`. Findings always carry `kind`, `nodes`, `rects`, and a one-line `message`:

- `zero_size`: a visible Control whose width or height is zero. Godot clamps a negative size to zero, so this covers inverted offsets too.
- `offscreen`: a visible Control whose rect lies **entirely** outside its viewport (partially clipped controls are not reported).
- `overlap`: two visible sibling Controls sharing at least `min_overlap_ratio` of the smaller rect under a parent that was not supposed to stack them. Also carries `parent`, `overlap_rect`, and `ratio`.

The overlap rule, precisely. A pair is reported when the parent is **not** a `Container` (placement came from the author's anchors and offsets) or is one of the containers documented to lay children out side by side — `BoxContainer` (`HBoxContainer`/`VBoxContainer`), `GridContainer`, `FlowContainer`, `SplitContainer` — where an overlap really is a defect. Every other `Container` is skipped: `MarginContainer`, `PanelContainer`, `CenterContainer`, `AspectRatioContainer`, `ScrollContainer`, `SubViewportContainer` and `TabContainer` hand every child the same slot, so overlap there is the engine doing its job, and a custom `Container`'s sort rule is unknown so it is not second-guessed. Two further exemptions: a `top_level` control places itself in screen space and is left out of sibling pairing, and a `ColorRect`, `Panel`, `TextureRect`, `NinePatchRect` or `ReferenceRect` whose rect fully covers a sibling is treated as a background layer rather than an overlap — that last one is the only heuristic in the rule, and `strict_overlap: true` turns it off.

There is deliberately no `text_clipped` finding: Godot clamps `Control.size` up to `get_combined_minimum_size()`, so a Label or Button rect is never smaller than its own text unless `clip_text`/`text_overrun_behavior` asked for truncation. Any check would have reported only deliberate elisions.

With `"ascii": true` the report carries an extra `ascii` array of equal-length rows, printed after the summary line. Every visible Control's global rect is drawn as a box — `+` corners, `-` and `|` edges — with the node's name written into its top edge, truncated to the box width. The walk is pre-order, so parents are drawn first and children overwrite them: two controls that landed on each other visibly collide instead of hiding behind two similar-looking rect arrays. The row count is `ascii_width × viewport_height / viewport_width × 0.5`, because character cells are about twice as tall as they are wide, so the map keeps the screen's proportions.

```
[SCENARIO] ui_report boot ascii 72x18
+B+Title---------------------+-----------------------------------------+
| |                          |                                         |
| +--------------------------+                                         |
| +Slot1-+-------------------------+                                   |
| |      |                         |                                   |
| +------+                         |                                   |
| |                                |                                   |
| +--------------------------------+                  +Close-------+   |
|                                                     |            |   |
|                                                     +------------+   |
+----------------------------------------------------------------------+
```

Nothing else about `ui_report` changes: the same rects, counts and findings are produced with or without `ascii`, and it still never forces a rendered window.

A UI regression scenario, gated end to end:

```json
{
  "scene_path": "scenes/hud.tscn",
  "viewport_size": {"width": 1280, "height": 720},
  "steps": [
    {"type": "ui_report", "label": "boot", "path": "/absolute/output/boot_ui.json",
     "fail_on": ["overlap", "zero_size", "offscreen"]},
    {"type": "action", "action_name": "ui_accept", "pressed": true, "release_after": true},
    {"type": "wait_until", "node_path": "Panels/Inventory", "property": "visible", "expected": true},
    {"type": "ui_report", "label": "inventory-open", "node_path": "Panels/Inventory", "fail_on": ["any"]},
    {"type": "log_marker", "message": "inventory-verified"}
  ],
  "assertions": [
    {"assertion": "property", "node_path": "Panels/Inventory/Grid", "property": "columns", "expected": 4}
  ],
  "log_assertions": [{"regex": "ui_report inventory-open .* overlap=0"}]
}
```

### dump_tree

Prints the live node tree, indented, with only the properties you asked for — and returns the same thing as data. It is the discovery step: dump once, read the real node paths and values, then write precise `assert` steps against them.

```json
{"type": "dump_tree", "node_path": "/root/Main", "label": "after_click",
 "properties": ["visible", "position", "global_position", "text", "modulate", "scale"],
 "max_depth": 6, "include_internal": false}
```

- `node_path` (default: the current scene root, falling back to `/root`): `"."`, a path relative to the scene root, or an absolute `/root/...` path. A path that resolves to nothing is an error naming all three forms.
- `properties` (default `["visible", "position", "text"]`): only the ones a node actually has are read — a `Sprite2D` asked for `text` simply omits it, never errors. Works for script `@export` vars too.
- `max_depth` (default `6`): `0` dumps only the starting node, `1` adds its direct children, and so on.
- `include_internal` (default `false`): include the internal children engine nodes add for themselves (a `ScrollContainer`'s scrollbars, a `LineEdit`'s caret timer).
- `label` (optional): names the dump in the result; defaults to `steps[<index>]`.

Values are formatted compactly: `Vector2` as `(x, y)`, `Color` as `#rrggbb` (`#rrggbbaa` when translucent), `String` quoted and trimmed to 40 characters, a `Resource` as its `resource_path` or `<ClassName>`, arrays and dictionaries as `[n items]` / `{n keys}`.

```
[SCENARIO] dump_tree boot node_path=. nodes=6 max_depth=6
Hud (Control) visible=true position=(0, 0) size=(640, 320) modulate=#ffffff
  Backdrop (ColorRect) visible=true position=(0, 0) size=(640, 320) modulate=#ffffff
  Title (Label) visible=true position=(24, 16) size=(236, 32) text="Inventory" modulate=#ffffff
  Grid (GridContainer) visible=true position=(24, 64) size=(296, 196) modulate=#ffffff
    Slot1 (Button) visible=true position=(0, 0) size=(57, 31) text="Sword" modulate=#ffffff
  Close (Button) visible=true position=(480, 260) size=(120, 40) text="Close" modulate=#ffffff
```

Each dump appends to a `tree_dumps` array on the result JSON. `lines` is the text above; `nodes` is the machine-readable form, with `path` relative to the dumped root (so it pastes straight into a later `node_path`) and `props` encoded through the shared typed-JSON codec:

```json
{"label": "boot", "node_path": ".", "node_count": 6,
 "lines": ["Hud (Control) visible=true position=(0, 0)", "  Title (Label) ..."],
 "nodes": [{"path": ".", "type": "Control", "props": {"visible": true, "position": {"__type": "Vector2", "x": 0, "y": 0}}},
           {"path": "Title", "type": "Label", "props": {"visible": true, "text": "Inventory"}}]}
```

### spatial_report

`ui_report` is the UI's layout in text; `spatial_report` is the **game world's** layout in text. It answers the questions that otherwise need a screenshot of the running game: is the player inside the camera view, is it standing on the floor or buried in it, does the 3D scene have a camera and a light at all, is the mesh behind the camera, did the level end up where it was painted. Everything is derived from transforms, resource metadata and the physics space state, so it is exact under `--headless` and never forces a rendered window. Long-form recipes live in `references/spatial_verification.md`.

```json
{"type": "spatial_report", "label": "boot", "node_path": ".", "dimension": "auto",
 "ascii": true, "ascii_size": {"cols": 64, "rows": 24}, "ascii_bounds": "content",
 "classes": ["Sprite2D", "CharacterBody2D"], "max_nodes": 200, "include_hidden": false,
 "expect_on_screen": ["Player"], "expect_visible": ["HUD/Score"],
 "fail_on": ["not_on_screen", "embedded_in_static"],
 "path": "/absolute/output/boot_spatial.json"}
```

- `node_path` (default `"."`): subtree to walk. Report paths stay relative to the **scene root** either way, so they paste straight into a later `node_path`.
- `dimension` (default `"auto"`): `"auto"` picks `3d` when the subtree holds any `Node3D` and `2d` otherwise. Force it with `"2d"`/`"3d"`; a 3D scene forced to `2d` simply reports no nodes rather than guessing.
- `classes` (optional): only nodes passing `is_class` for one of these names are listed.
- `include_hidden` (default `false`): also list nodes that are not visible in tree (they get `"visible": false`).
- `max_nodes` (default `200`): cap on listed nodes. When it bites, `truncated: true`, `total_nodes` and a `truncation_note` say so.
- `expect_on_screen` / `expect_visible` (optional): node paths that must be inside the active camera's view (2D) or frustum (3D), and visible in tree. A path that resolves to nothing is a step **error**, not a silent pass.
- `fail_on` (optional): finding ids that fail the scenario the way a failed assertion does, or `["any"]`. Like `ui_report`, findings alone never fail a run — `expect_*` produces the finding, `fail_on` gates on it. An unknown id is rejected with the full list.
- `ascii` (default `false`) + `ascii_size` (default `{"cols": 64, "rows": 24}`, clamped to 8–200 × 4–100) + `ascii_bounds` (`"content"` default, or `"camera"`): the top-down character map below.
- `settle_frames` (default `1`): process frames awaited before sampling. One physics frame is always awaited afterwards, because the direct space state only agrees with a transform written by an earlier step once physics has stepped.
- `embed_margin` (optional, default `-1.0` in 2D and `-0.01` in 3D): how far the query shape is shrunk before asking the space state for overlaps. Negative; a zero margin makes a body that merely *rests* on the floor read as embedded in it.
- `check_occlusion` (default `false`): for each `expect_on_screen` node already in the frustum, cast a physics ray from the camera and report `occluded` when something else is hit first. Best effort — a target with no collider of its own is judged against whatever blocks the line.
- `path` (optional): also write the report to a JSON file (`res://`, `user://`, or absolute).

Reports arrive in `spatial_reports` on the result JSON, in step order. 2D nodes carry the world `rect`, the `screen_rect` that rect lands on, `on_screen`, `z_index`, `space` (`"world"`, or `"screen"` for anything under a `CanvasLayer` — those are never compared with the world view rect) and `kind` (`texture`, `shape`, `shapes`, `tiles`, `polygon`, `light`, `control`, `point`, `camera`):

```json
{"label": "boot", "node_path": ".", "dimension": "2d", "passed": true,
 "rect_format": "[x, y, width, height]", "viewport": {"width": 640, "height": 360},
 "view_rect": [40, 40, 320, 180],
 "camera": {"path": "Camera2D", "class": "Camera2D", "position": [200, 150], "center": [200, 130],
            "zoom": [2, 2], "offset": [0, -20], "rotation_degrees": 0, "view_rect": [40, 40, 320, 180]},
 "counts": {"nodes": 7, "on_screen": 6, "off_screen": 0, "screen_space": 1, "findings": 0},
 "truncated": false, "total_nodes": 7,
 "nodes": [
   {"path": "Player", "class": "CharacterBody2D", "space": "world", "kind": "shapes",
    "rect": [188, 156, 24, 40], "z_index": 0, "screen_rect": [296, 232, 48, 80], "on_screen": true},
   {"path": "Player/Sprite2D", "class": "Sprite2D", "space": "world", "kind": "texture",
    "rect": [184, 152, 32, 48], "z_index": 0, "screen_rect": [288, 224, 64, 96], "on_screen": true},
   {"path": "HUD/Banner", "class": "Sprite2D", "space": "screen", "kind": "texture",
    "rect": [28, 16, 64, 16], "z_index": 0, "screen_rect": [28, 16, 64, 16], "on_screen": true}],
 "findings": []}
```

3D nodes carry the world `aabb` (`[x, y, z, size_x, size_y, size_z]`), `position`, `in_frustum`/`on_screen`, `behind_camera`, `distance_to_camera` and `screen_pos` (omitted when the node is behind the camera, where `unproject_position` returns a mirrored point). The report adds `camera` (`position`, `forward`, `projection`, `fov`, `size`, `near`, `far`) and `lighting`:

```json
{"dimension": "3d", "aabb_format": "[x, y, z, size_x, size_y, size_z]",
 "camera": {"path": "Camera3D", "class": "Camera3D", "position": [0, 2, 6], "forward": [0, 0, -1],
            "projection": "perspective", "fov": 75, "size": 1, "near": 0.05, "far": 4000},
 "lighting": {"lit": true, "lights": ["DirectionalLight3D"], "environment_light": false,
              "detail": "Lights found: 1. No Environment on the camera, the World3D or the project's fallback."},
 "nodes": [{"path": "Crate", "class": "MeshInstance3D", "kind": "visual",
            "aabb": [-0.5, 0, -0.5, 1, 2, 1], "position": [0, 1, 0], "in_frustum": true,
            "on_screen": true, "distance_to_camera": 6.08, "behind_camera": false,
            "screen_pos": [320, 219.1]}]}
```

Findings are `{"type", "path", "message"}`, and the message always names the numbers a caller cannot see:

| id | when |
| --- | --- |
| `no_camera_2d` | no active `Camera2D` **and** the world content reaches past the raw viewport |
| `no_camera_3d` | no active `Camera3D` in a scene that has something to render |
| `no_light_3d` | no visible `Light3D` with energy above 0 **and** no `Environment` ambient/sky light — a lit material renders black. A shader or material with `unshaded` needs no light, so this stays a hint-level report, never an automatic failure |
| `not_on_screen` | a 2D `expect_on_screen` node whose screen rect is entirely outside the viewport |
| `not_in_frustum` | a 3D `expect_on_screen` node whose world AABB is outside the frustum |
| `behind_camera` | a 3D `expect_on_screen` node behind the camera plane |
| `occluded` | only with `check_occlusion`: something blocks the camera→node line |
| `embedded_in_static` | a `CharacterBody2D/3D` or `RigidBody2D/3D` whose own shapes overlap a `StaticBody`, `TileMapLayer` or `GridMap` right now |
| `far_from_origin` | a node more than 100000 units from the origin on any axis |
| `zero_scale` | a node whose global scale is zero on any axis |
| `invisible_expected` | an `expect_visible` node that is not visible in tree; the message names the ancestor holding the `visible = false` |

With `"ascii": true` the report gains `ascii` (equal-length rows), `ascii_legend`, `ascii_bounds_rect`, `ascii_cell_size` and `ascii_axes`, and prints all of it. The map is top-down: XY in 2D, **XZ with +Z down the page** in 3D. Letters are handed out in walk order (`a`, `b`, … `Z`, `0`… then `*`), the active camera is `@`, a 3D camera also gets a facing arrow (`^ v < > / \`), and the camera view rect / frustum footprint is outlined with `:` in whatever cells nothing else claimed. Bigger rects are drawn first so a small node on top of a big one keeps its cell, a `TileMapLayer`/`GridMap` is drawn **cell by cell** so the map has the shape of the level rather than of its bounding box, and a symbol whose every cell was covered is dropped from the legend. `ascii_bounds: "content"` frames what is actually there (plus the camera); `"camera"` frames the view.

```
[SCENARIO] spatial_report level dim=2d nodes=5 on_screen=5 off_screen=0 screen_space=0 findings=0 camera=Camera2D
[SCENARIO] spatial_report level ascii 40x16 bounds=[-3.2, -18.56, 166.4, 133.12] x right, y down (top-down XY)
 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
 aaaa                              aaaa
 aaaa       aaaaaaaaaaaa           aaaa
 aaaa               @              aaaa
 aaaa       cddd                   aaaa
 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  a = Ground (TileMapLayer)
  c = Hero/Sprite2D (Sprite2D)
  d = Hero/CollisionShape2D (CollisionShape2D)
  @ = Camera2D (Camera2D)
```

Each step prints one grep-able summary line plus one line per finding, so `log_assertions` can gate on either:

```
[SCENARIO] spatial_report boot dim=3d nodes=6 on_screen=5 off_screen=1 screen_space=0 findings=1 (no_light_3d:1) camera=Camera3D
[SCENARIO] spatial_report boot finding no_light_3d: No visible Light3D with energy above zero and no Environment ambient/sky light — ...
```

### Verification Without Vision

Everything the runner produces is text, including the screenshots. A model that cannot look at an image loses nothing by running this loop:

1. **Instrument the gameplay path.** Print one line per decision that matters (`print("[HUD] wave=%d hp=%d" % [wave, hp])`), and separate phases with `log_marker` steps so the log has section boundaries to search between.
2. **Script the session**: `python3 scripts/debug/run_scenario.py PROJECT SCENARIO --log-file /tmp/run.log --pretty`. Input steps drive it deterministically and `wait_until` waits on state instead of guessed frame counts, so one run reaches the state worth checking.
3. **Find out what is actually there with `dump_tree`.** One dump after boot gives the real node paths, classes and property values; every later `assert`, `set_property` and `ui_report` `node_path` can then be written against names that exist instead of guessed ones. Dump again after an interaction and diff the `lines` to see exactly what the click changed.
4. **Read the UI with `ui_report`** at every moment worth checking — after boot, after a panel opens, after a resolution change. Gate it with `fail_on` so a stacked, zero-sized or offscreen layout fails the run instead of waiting to be noticed, and add `"ascii": true` when the rect list alone is not telling you where things sit. Scope big screens with `node_path`, and pass `path` when the report should outlive the run.
5. **Read the world with `spatial_report`.** `ui_report` stops at the edge of the UI: it cannot tell you the player is 5000 px off camera, sunk into the floor, or that the 3D scene has no light and will render black. `{"type": "spatial_report", "ascii": true, "expect_on_screen": ["Player"], "fail_on": ["not_on_screen", "embedded_in_static", "no_camera_3d", "no_light_3d"]}` gates all of that, headless, without a screenshot.
6. **Assert the properties that carry the meaning**: `{"assertion": "property", "node_path": "HUD/Score", "property": "text", "expected": "1200"}`, plus `visible` and `node_exists` for the nodes a state change is supposed to add or reveal. Report and dump paths are already in the right form to paste into `node_path`.
7. **Make the screenshot itself a text check.** `{"type": "screenshot", "path": "…", "expect": {"not_blank": true, "min_opaque_ratio": 0.1}}` catches the render that produced nothing — the case `ui_report` cannot see, because a correctly laid-out Control still draws nothing when its texture, material or camera is wrong. Add `"compare_to"` plus `"max_diff_ratio"` once a good capture exists to gate visual regressions, and `"describe": {"ascii": true}` when you want to see the frame.
8. **Parse the captured log**: `python3 scripts/debug/godot_log_parser.py /tmp/run.log --pretty` turns it into structured errors and warnings. The wrapper keeps `-d --ignore-error-breaks` on by default, so GDScript warnings the editor would show actually reach the log; `log_assertions` gate on the prints from step 1.
9. **Read the exit code**: `0` only when every assertion, log assertion, performance assertion, gated `ui_report` / `spatial_report` finding and screenshot `expect` passed.
10. **Read levels back as text.** After any `paint_tilemap` / `paint_gridmap`, run `inspect_tilemap '{"scene_path": "scenes/level.tscn", "format": "text"}'` and compare the rows with what you meant to paint. This is the only check that catches an off-by-one `origin`, a legend character mapped to the wrong atlas tile, or a terrain fill that matched no tile — the scene still saves and still reports `ok` in all three cases.

Each step also prints one grep-able line, so step 8 can gate on the layout, the world and the render without parsing the payload:

```
[SCENARIO] ui_report inventory-open controls=12 visible=12 hidden=0 findings=0 zero_size=0 offscreen=0 overlap=0
[SCENARIO] dump_tree after_click node_path=. nodes=41 max_depth=6
[SCENARIO] spatial_report boot dim=2d nodes=18 on_screen=17 off_screen=1 screen_space=3 findings=0 camera=Camera2D
[SCENARIO] screenshot /tmp/out/inventory.png blank=false opaque=1 bbox=24,16,576,284 dominant=#111122
```

Files are checkable too. `inspect_image` answers, for any PNG on disk, the questions a look would answer:

```bash
godot --headless --path /absolute/project \
  --script /absolute/godot/scripts/core/dispatcher.gd \
  inspect_image '{"image_path":"art/player.png","format":"text","ascii":true,
                  "expect":{"not_blank":true,"has_alpha":true,"max_unique_colors":32}}'
```

- **Did the sprite render at all?** `blank: false` plus `opaque_ratio` above zero. Gate it with `{"not_blank": true, "min_opaque_ratio": 0.1}`; a file that is one flat colour is an empty capture or a failed generation, whatever its size.
- **Did the cutout work?** `has_alpha: true` and `opaque_ratio` below `1.0`. A chroma-key pass that silently did nothing reports `has_alpha: false`, `opaque_ratio: 1.0` and a `dominant_colors` entry at `#00ff00`.
- **Is it centred / where is it?** `content_bbox_normalized`: centred means `x + w/2` and `y + h/2` are both near `0.5`. `quadrants` says the same thing coarsely — one quadrant at `1.0` is content stuck in a corner, four near `0.25` is content spread over the frame. `content_bbox` at `{0,0,1,1}` of the normalized frame means the art fills its canvas with no margin, which is what makes a sprite clip against its collision box.
- **Is the art pixel-art sized?** `unique_colors` — a limited palette is tens of colours, an anti-aliased or resampled export is thousands. Gate with `{"max_unique_colors": 32}`.
- **Are all the frames the same size?** `{"image_paths": ["art/hero_idle"], "expect": {"frames_consistent": true}}` before `build_sprite_frames`; frames that changed canvas size mid-run animate as a jitter no assertion downstream will explain.
- **Did it change?** `compare_to` plus `{"max_diff_ratio": 0.01}` against a known-good capture. `0.0` means byte-identical; print the `ascii` of both when the number says something moved.
- **What does it look like?** `"ascii": true` (add `"ascii_color": true` for hue letters). It is a low-resolution read, not a preview: use it to confirm a shape is where the numbers say it is.

## Engine API Lookup And Ad-hoc Code

Full guide with worked output: `references/api_lookup.md`.

### Engine API Lookup (`api_lookup.py`)

Asks the *installed* engine for its own class reference
(`godot --headless --doctool`) and answers signature questions from it, so a
method name never has to be remembered. Needs no project.

```bash
python3 /absolute/godot/scripts/docs/api_lookup.py CharacterBody2D.move_and_slide Area2D.body_entered
```

```
CharacterBody2D.move_and_slide  (method)
  move_and_slide() -> bool

Area2D.body_entered  (signal)
  body_entered(body: Node2D)
  connect: node.body_entered.connect(_on_body_entered)
  handler: func _on_body_entered(body: Node2D) -> void:
```

- `QUERY` is `Class`, `Class.member`, or a bare global (`lerp`, `KEY_SPACE`,
  `preload`). Several per call. Variant types (`String.begins_with`,
  `Array.map`), `@GlobalScope`, `@GDScript` and theme items all resolve;
  `Class.member` walks the inheritance chain and names the declaring class.
- `--search TEXT [--limit N]` ranks name matches (exact > whole word > prefix >
  substring). `--kind methods,properties,signals,constants,enums,theme_items,operators,constructors,annotations`
  filters a class card; `--inherited` expands the ancestors it otherwise
  summarises one line each.
- `--project /abs/project` adds the project's own scripts: a `class_name` one
  under that name, one without under its path (`res://scripts/player.gd`,
  `scripts/player.gd`, `player.gd`).
- `--json` / `--pretty` for structured output; `--refresh` rebuilds the cache;
  `--godot BIN` / `$GODOT_BIN` picks the engine; `--cache-dir` / `$GODOT_SKILL_CACHE`
  moves the cache (default `~/.cache/godot-skill/api/<engine version>/`).
- Exit `0` found, `1` not found (with the nearest real names, and the 4.x
  replacement when the query is a Godot 3 name such as `KinematicBody2D`),
  `2` usage error or the engine could not be run.
- First call ≈ 0.6 s (it builds the cache), later calls ≈ 0.08 s. The dump has
  signatures but **no descriptions**.

### run_gdscript

Runs a GDScript snippet, one `Expression`, or a function of a project script
inside the live SceneTree with the project's autoloads registered, and returns
the value through `variant_codec.encode`.

```bash
godot --headless --path /absolute/project \
  --script /absolute/godot/scripts/core/dispatcher.gd \
  run_gdscript '{"code":"var body := CharacterBody2D.new()\nbody.velocity = Vector2(120, 0)\nvar report := {\"speed\": body.velocity.length(), \"on_floor\": body.is_on_floor()}\nbody.free()\nreturn report"}'
```

```json
{"completed":true,"elapsed_ms":1,"mode":"code","ok":true,"result":{"on_floor":false,"speed":120.0},"result_type":"Dictionary"}
```

| Param | Meaning |
| --- | --- |
| `code` | statements forming the body of `func run(tree: SceneTree) -> Variant`; may `await`, may `return` |
| `expression` | one `Expression` string; engine singletons, the project's autoloads, `tree` and `scene` are named inputs |
| `script_path` + `method` | call a function of a project script |
| `args` | typed-JSON arguments for `method` |
| `instantiate` | default auto: static call for a `static func`, otherwise `script.new()` |
| `scene_path` | instantiate this scene under the root first and expose it as `scene` |
| `timeout_seconds` | default `10`; exit 1 with `"timed_out": true` |
| `max_depth` | default `4`; encoding depth of the returned value |

Exactly one of `code` / `expression` / `script_path` is allowed.

Gotchas:

- A GDScript runtime error aborts only its own function and returns `null`, so
  this op watches the engine's error stream with an `OS.add_logger()` Logger:
  any error means exit `1` and `run() did not complete`, never a quiet
  `"result": null`.
- A parse error in `code` is reported as `code:<line>: <message>` against your
  own snippet, not against the generated wrapper.
- `script.new()` on a Node script gives an orphan node: no `_ready()`, `@onready`
  vars still `null`. Use `scene_path` + `code` when the node must be alive.
- Side effects are real (files, autoload state, `OS`). It is not a sandbox, and
  it records nothing — prefer a dedicated op whenever one exists.

## Typed JSON Values

The shared codec accepts plain JSON plus:

- Resource reference: `{"__resource":"res://theme/main.tres"}`.
- Resource construction: `{"__resource_type":"Gradient","properties":{...}}`, optionally with an ordered `"method_calls":[{"method":"add_point","args":[...],"expect_ok":false}]` for builder-only state.
- Custom resource construction: `{"__script":"res://items/item_data.gd","properties":{...}}` instantiates a project-defined `class_name ItemData extends Resource`, which `__resource_type` cannot reach because ClassDB only knows engine classes. It accepts the same `resource_name`, `properties`, and ordered `method_calls` keys as `__resource_type`, and nests to any depth. The script must resolve to a `Resource` subclass — a `Node` script is refused by name (`… extends Node2D, which is not a Resource`). Passing both `__script` and `__resource_type` in one value is an error; keep `__script`.
- `StringName`, `NodePath`, `Vector2`, `Vector2i`, `Rect2`, `Rect2i`, `Vector3`, `Vector3i`, `Transform2D`, `Vector4`, `Vector4i`, `Plane`, `Quaternion`, `AABB`, `Basis`, `Transform3D`, `Projection`, and `Color` through `{"__type":"TypeName",...}`.
- Packed byte/int/float/string/vector/color arrays through `{"__type":"Packed...Array","values":[...]}`.
- Curve sugar: `{"__curve":{"min_value":0,"max_value":1,"points":[{"x":0,"y":0},{"x":1,"y":1,"left_tangent":0,"right_tangent":0}]}}` builds a `Curve` (its points are otherwise builder-only, so this is the ergonomic way to inline scale/alpha/velocity ramps).
- Gradient sugar: `{"__gradient":{"points":[{"offset":0,"color":"..."},{"offset":1,"color":"..."}]}}` (or `{"offsets":[...],"colors":[...]}`) builds a clean `Gradient` with exactly those stops — unlike `add_point`, which appends to the two default stops.

`Rect2`/`Rect2i` accept either typed `position` plus `size` dictionaries or the compatibility form `x`, `y`, `width`, `height`.

Property writes are type-checked against the target's script variables before they are applied. `Object.set()` drops a mismatched write without raising, so an untyped JSON array is converted into the property's declared `Array[T]` / `Dictionary[K, V]` type, and anything genuinely incompatible fails the operation with the expected type named (`expected Vector2 but got a plain dictionary; tag the value as {"__type": "Vector2", ...}`). A misspelled property lists the script's exported names: `Property does not exist at set_properties.properties: displayname (did you mean display_name?). ItemData script properties: display_name, price, icon, tags, stats`.

Three rules the codec enforces, each of which used to be a silent wrong result:

- An inline resource's own properties go under `"properties"`. `{"__resource_type": "RectangleShape2D", "size": {...}}` is an error naming the fix (`{"__resource_type": "RectangleShape2D", "properties": {"size": {...}}}`); it used to build a default-sized shape and report success. Only `__resource_type`/`__script`, `resource_name`, `properties` and `method_calls` are structural keys.
- A colour string (`"#rrggbb"`, `"#rrggbbaa"`, a named colour) is converted wherever the target property is declared `Color` — including dynamic ones such as a `ShaderMaterial`'s `shader_parameter/<uniform>`, which used to store `null`. A string that is not a colour fails the operation. For a shader uniform the `shader` must be assigned first, or there is no declared type to read.
- An indexed path is walked before anything is written. Sub-paths use `:` (`"shadow_offset:x"`, `"material:shader_parameter/tint"`); a `/` is only ever part of a property *name* (`shader_parameter/tint`, `theme_override_colors/font_color`). A hop that does not exist is an error with the likely spelling — `"content_margin/left"` → `did you mean "content_margin_left"? it is a plain property`, `"offset/x"` → `did you mean "offset:x"?`, `"position:w"` → `"w" is not a member of Vector2` — and a path through a null object says which part is null. `Object.set_indexed()` itself reports nothing, so these used to be accepted, change nothing, and count as applied.
- An indexed path that passes through another saved resource file edits that file: `"material:shader_parameter/flash_amount"` on a node whose material is `res://materials/flash.tres` saves the scene **and** the `.tres` (`[INFO] Also saved res://materials/flash.tres …`), which is what the editor does. It used to save only the scene and drop the edit. A path that reaches into an imported file (`"texture:resource_name"` on a `.png`) is refused, because nothing could save it.

## Create A Project From Nothing (`scaffold_project.py`)

`godot --headless` cannot create a project — the Project Manager is the only supported author. This runs `references/playbooks.md` section 1 end to end through the dispatcher, so Godot itself writes every setting, and then proves the result.

```bash
python3 /absolute/godot/scripts/project/scaffold_project.py /absolute/dest --preset pixel2d \
  --name "Cave Diver" --autoloads game_manager,save_manager,scene_transition --with-tests --pretty
```

| Flag | Meaning |
| --- | --- |
| `--preset` | **required** — `pixel2d` (320×180, `viewport` stretch, `keep` aspect, integer scale, nearest filtering, pixel snap), `hd2d` (1920×1080, `canvas_items`, `expand`), `3d` (Camera3D + DirectionalLight3D + WorldEnvironment + ground already in the main scene, MSAA 4×), `ui` (resizable, `canvas_items`, low-processor mode, a PanelContainer/VBox starter screen). |
| `--name NAME` | `application/config/name`; defaults to the destination folder name. |
| `--size WxH` | Override the base viewport size. Refused unless it looks like `320x180`. |
| `--autoloads a,b,c` | Template stems from `templates/gdscript` to copy into `scripts/` and register. Default `game_manager,save_manager,scene_transition` (none for `--preset ui`). A template is eligible when its header line reads `# Autoload: YES, as <Name>` (the name in backticks), so templates other work packages add are picked up automatically; an unknown name is refused with the full list. Asking for `audio_manager` also creates the Master/Music/SFX buses first, because registering it before they exist makes every player fall back to Master. |
| `--no-autoloads` | Register none. |
| `--with-tests` | Also runs `scripts/test/run_tests.py DEST --init-mini`. |
| `--skip-validate` | Skip the closing `validate_project.py` pass. |

What lands on disk: the folder layout (`scenes scripts art audio ui levels resources theme` plus `tilesets` for 2D or `models` for 3D), `project.godot`, `icon.svg`, `.gitignore`, `.gitattributes`, `scenarios/boot_check.json`, `scenes/main.tscn`, the autoload scripts. The input map binds `move_left/right/up/down`, `jump`, `attack`, `interact`, `pause` to **physical** keycodes *and* gamepad buttons *and* the left analog stick; `layer_names/<2d|3d>_physics/layer_1..6` are named `world player enemies pickups hitboxes hurtboxes`, and the render layers `world background foreground` (2D) / `world props vfx` (3D).

Then it runs `godot --headless --path DEST --import` and `validate_project.py DEST --warnings-as-errors`, and prints `{ok, preset, project_path, name, created[], settings_applied{}, input_actions[], autoloads[], autoload_scripts{}, audio_buses[], main_scene, tests{}, validate{ok, counts, diagnostics}, next[]}` where `next[]` are copy-paste commands (run, run the boot scenario, validate, add a web export preset).

Exit codes: `0` done, `1` a step failed (the JSON names the step, the command and its stderr), `2` refused before touching anything — the destination already holds a `project.godot`, `--size` is malformed, an autoload template does not exist, or `godot` is not on PATH.

A freshly scaffolded project of every preset validates with **zero errors and zero warnings**, boots clean through `run_project.py`, and passes its own `scenarios/boot_check.json` (the `3d` one gates on `spatial_report` `fail_on: ["no_camera_3d", "no_light_3d"]`, the `ui` one on `ui_report` `fail_on: ["any"]`).

## Export Preflight And Patches

An export needs three things in place: a preset in `export_presets.cfg`, the matching export templates for this exact Godot version, and an output folder. The three tools below cover them in that order.

### add_export_preset

Creates or updates one entry in `export_presets.cfg` so a build can be exported without ever opening the editor. Full parameter table, the verified per-platform option blocks and the facts behind them are in `references/export_targets.md`.

```bash
godot --headless --path /absolute/project \
  --script /absolute/godot/scripts/core/dispatcher.gd \
  add_export_preset '{"platform": "web"}'
```

- `platform` (required): `web` | `windows` | `linux` | `macos` | `android` | `ios`, mapped to Godot's exact platform string (`Linux`, not the Godot 3 `Linux/X11`).
- `name` (default: the platform's conventional preset name), `export_path` (default `../build/<platform>/<artifact>`, beside the project), `runnable` (default true for the first preset of a platform), `export_filter` / `include_filter` / `exclude_filter`, `custom_features`.
- `options` (default: the verified block): free-form export options merged over it, **never key-checked**.
- `overwrite` (default false): an existing preset of that name is an error naming it and listing the rest. With `true`, every key you did not name keeps its current value.
- `dedicated_server` (linux only): adds the feature tag *and* the `export_filter: "customized"` + per-file `"strip"` map that actually removes the textures.

Payload: `{ok, preset_index, name, platform, export_path, export_path_absolute, created, updated, verified, prerequisites[], notes[], dedicated_server, stripped_files, options{}, project_settings_changed[], presets[], next[]}`. `verified` is `true` only for the four platforms whose default block was proven by a real export while building this skill (web, windows, linux, macos); for `android`/`ios` it is `false` and `prerequisites[]` names exactly what is missing.

The file is rewritten as **text**: every other preset, its index, its order and any key this op does not know keep their exact bytes, so a preset authored in the editor — signing identity, provisioning profile, per-file customisation map — survives untouched.

### export_project.py

Preflight the preset `add_export_preset` just wrote, without exporting anything. **Only a `--mode pack` preflight is template-free** — a `.pck` is project data, with no engine binary in it — so this is the form that passes on a CI runner with no templates installed:

```bash
python3 /absolute/godot/scripts/export/export_project.py /absolute/project Web \
  /absolute/build/web/base.pck --mode pack --preflight-only
```

A release-mode preflight is the stricter question — *would a real export work here* — so it checks the export templates for this exact engine build and exits 1 when they are missing (`Matching Godot export templates were not found`). Run it where the templates are, not in a bare CI image:

<!-- replay: skip — export-templates (a release preflight checks the installed templates) -->
```bash
python3 /absolute/godot/scripts/export/export_project.py /absolute/project Web \
  /absolute/build/web/index.html --preflight-only
```

The export itself, same arguments without `--preflight-only`:

<!-- replay: skip — export-templates (builds a real web export) -->
```bash
python3 /absolute/godot/scripts/export/export_project.py /absolute/project Web \
  /absolute/build/web/index.html
```

`--mode pack` writes only the data `.pck`, which is what a patch is measured against:

```bash
python3 /absolute/godot/scripts/export/export_project.py /absolute/project Web \
  /absolute/build/web/base.pck --mode pack
```

A patch build ships only what changed since those base `.pck`s, so something has to have changed — against an unchanged project it fails with `Save PCK: No files or changes to export.` and exit 1:

<!-- replay: skip — export-templates (a patch export, verified only where the templates are installed) -->
```bash
godot --headless --path /absolute/project \
  --script /absolute/godot/scripts/core/dispatcher.gd \
  draw_image '{"output_path":"art/patch_marker.png","palette":{"w":"#ffffff"},"rows":["ww","ww"]}'
godot --headless --path /absolute/project --import
python3 /absolute/godot/scripts/export/export_project.py /absolute/project Web \
  /absolute/build/web/update.pck --mode patch --patches /absolute/build/web/base.pck
```

Preflight checks the exact preset, matching export-template directory, Godot executable, platform tools, patch inputs, and common output extensions. Dry runs report preflight findings without failing unless `--strict-preflight` is set. Real exports fail on preflight errors unless `--skip-preflight` is explicitly supplied.

Every blocker names its fix. The payload carries `errors[]` and a parallel `fixes[]` of runnable commands, and both are mirrored on stderr as `export preflight: …` / `export preflight fix: …`. A preset that does not exist lists every preset in the file plus the `add_export_preset` call for the closest platform; missing export templates say where to install them; macOS/Android/iOS with `rendering/textures/vram_compression/import_etc2_astc` disabled print the `project_batch` call; iOS with no `application/app_store_team_id` prints the `add_export_preset … "overwrite": true` call.

`export_presets.cfg` is parsed with a Godot-aware reader, not `configparser`: Godot writes dictionary values across several unindented lines (`customized_files={⏎"res://icon.svg": "strip"⏎}`), which `configparser` rejects — and a rejected file used to read as "this project has no export presets at all".

### serve_web.py

<!-- replay: skip — export-templates (needs a real web export under /absolute/build/web) -->
```bash
python3 /absolute/godot/scripts/export/serve_web.py /absolute/build/web --check --pretty
```

<!-- replay: skip — interactive (serves until the reader presses Ctrl+C) -->
```bash
python3 /absolute/godot/scripts/export/serve_web.py /absolute/build/web
```

`python3 -m http.server` is not enough for a Godot web build: it has no MIME type for `.wasm` on most hosts (the browser then refuses the streaming compile) and no cross-origin isolation headers (so a threaded build has no `SharedArrayBuffer`). This sends `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp`, `Cross-Origin-Resource-Policy: cross-origin`, `Cache-Control: no-store…`, `application/wasm` and `application/octet-stream`, and binds `127.0.0.1`.

`--check` is the headless-agent mode: it starts the server, requests `index.html`, the `.wasm` and the `.pck` over loopback, asserts status codes, content types, the isolation headers and a 404 for a missing file, then prints `{ok, url, port, isolation, cross_origin_isolated, threaded_build, files{}, checks[], failed[]}` and exits 0/1. `--port 0` picks a free port, `--bind` changes the interface, `--no-isolation` reproduces a plain static host. A directory that is not a web export exits 2 and prints the two commands that make one.
