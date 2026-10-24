# Asset Pipeline

Load this reference when the task involves art: drawing it here, generating it elsewhere, cutting it out,
cleaning it up, or turning frames into animation assets.

## Which path

| situation | do this |
| --- | --- |
| Pixel art of any kind — sprites, tiles, UI panels, icons, placeholders | `draw_image`. No image generator needed, and the result is verifiable as text. See `references/pixel_art.md`. |
| No image generator available at all | `draw_image` (art) and `make_sfx.py` / `make_music.py` (audio). |
| Art came from an image generator and looks soft / off-grid / has a baked background | `process_image` (`remove_background` → `trim` → `pixelate` + `quantize` + `alpha_threshold`). See `references/pixel_art.md` §6. |
| Painterly or high-resolution art the generator does well | `imagegen`, then the cutout and frame rules below. |
| Frames to pack into a sheet, or a sheet to slice into frames | `process_image` `pack_frames` / `split_sheet` — `pack_frames` returns the `grid` that `build_sprite_frames` takes. |

Everything written by `draw_image`/`process_image` lands as a raw file with **no `.import` sidecar** (the
payload says `"needs_import": true`). Run `python3 /abs/godot/scripts/import/import_project.py /abs/project`
before a `.tscn`/`.tres` references it.

## Default image pipeline (generated art)

1. Use the `imagegen` skill for generated art.
2. Request `png` output with `background=transparent` whenever the subject should become a sprite, prop, UI element, or animation frame.
3. If transparent output is unavailable or edge quality is poor, fall back to a flat chroma-key background and strip it with `process_image` (no dependencies) or `scripts/assets/chroma_key_cutout.py` (needs Pillow/NumPy).

## Best fallback background for a cutout

- Default background: pure green `#00FF00`.
- If the subject already contains strong green regions, switch to pure magenta `#FF00FF`.
- Do not use white, black, gradients, textured scenes, shadows, or contact shadows as the default cutout background.
- Keep the background flat and uniform across every frame in the sequence. For batches, prefer an explicit `00ff00` or `ff00ff` value instead of guessing.

## Prompt constraints for cutout-friendly assets

- Subject centered and fully inside frame.
- Clean silhouette with readable hard edges.
- No text, watermark, motion blur, bloom, or depth-of-field effects.
- No cast shadow on the background unless the user explicitly asks for it.
- For pixel-art defaults: limited palette, crisp edges, no painterly gradients, no soft airbrush rendering. Then
  run the result through `process_image` `pixelate` anyway — a generator's "pixel art" is almost never on a grid.

## Frame animation defaults

- Default delivery format: independent frame files, not a sprite sheet.
- `build_sprite_frames` auto-discovers raster image frames from `frames_dir` with natural filename sorting. If exact order matters or the inputs are texture resources, use explicit `frame_paths` instead.
- Keep the same canvas size, camera distance, viewing angle, and anchor point across frames.
- Change only pose or timing from frame to frame; do not redesign the character or prop mid-sequence.
- Generate or repair frames individually, then build `SpriteFrames` in Godot with `build_sprite_frames`.
- Export a sprite sheet only when the user explicitly asks for one — or when packing one is cheaper than
  shipping 12 files, in which case `process_image` `pack_frames` gives you the sheet *and* its grid.
- Frames that are not all the same size cannot be packed: `{"type": "pad", "multiple": 16}` (or an explicit
  `width`/`height`) first.
- Verify generated frames before building the animation: `inspect_image '{"image_paths":["textures/hero_idle_cutout"],"expect":{"frames_consistent":true,"not_blank":true,"has_alpha":true}}'` fails the run when a frame is empty, lost its transparency in the cutout, or changed canvas size.

## Cutting a flat background out

The commands below work on two throw-away frames — a subject on a flat `#00ff00` field, the shape a generator
hands back:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{"output_path":"source/hero_idle_raw/frame_1.png",
               "palette":{"g":"#00ff00","s":"#ffccaa","b":"#29adff"},
               "rows":["gggggggg","ggssssgg","ggssssgg","ggbbbbgg","ggbbbbgg","ggbbbbgg","gggbbggg","gggggggg"]}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{"output_path":"source/hero_idle_raw/frame_2.png",
               "palette":{"g":"#00ff00","s":"#ffccaa","b":"#29adff"},
               "rows":["gggggggg","gggggggg","ggssssgg","ggssssgg","ggbbbbgg","ggbbbbgg","gggbbggg","gggggggg"]}'
```

`process_image` needs nothing installed and runs through Godot's own image code. It floods inwards from the
corners, so a background colour that also appears *inside* the subject survives:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  process_image '{
    "input_paths": ["source/hero_idle_raw"],
    "output_dir": "textures/hero_idle_cutout",
    "operations": [
      {"type": "remove_background", "color": "#00ff00", "tolerance": 0.08},
      {"type": "trim", "padding": 1},
      {"type": "pad", "multiple": 16}
    ]
  }'
```

`{"type": "replace_color", "from": "#00ff00", "to": null, "tolerance": 0.1}` is the blunter version: it clears
every matching pixel, including the ones the subject encloses.

The older `scripts/assets/chroma_key_cutout.py` does the same job for flat chroma keys and still works, but it
needs `Pillow` and `NumPy` installed; prefer `process_image` unless you already have that environment.

<!-- replay: skip — external-tool:pillow (needs Pillow and NumPy installed) -->
```bash
python3 /absolute/path/to/godot/scripts/assets/chroma_key_cutout.py \
  --input /absolute/path/to/project/source/hero_idle_raw \
  --output-dir /absolute/path/to/project/textures/hero_idle_cutout \
  --bg-color 00ff00
```

Either way the payload says `"needs_import": true`: a PNG written after the last import has no `.import`
sidecar, and nothing can load it by path until the importer has run. Do that before referencing the frames
from a resource:

```bash
godot --headless --path /absolute/path/to/project --import
```

Then build the animation from the project-relative frame directory:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  build_sprite_frames '{
    "scene_path":"scenes/player.tscn",
    "node_path":"root/AnimatedSprite2D",
    "frames_dir":"textures/hero_idle_cutout",
    "animation_name":"idle",
    "fps":12,
    "loop":true,
    "resource_save_path":"animations/hero_idle_frames.tres"
  }'
```

## Dependencies

- Nothing at all for `draw_image` / `process_image` / `inspect_image`: they run inside Godot.
- `imagegen` for generation or edit requests.
- `Pillow` and `NumPy` only for the legacy `scripts/assets/chroma_key_cutout.py`.

Create a virtualenv when the system Python is externally managed:

<!-- replay: skip — external-tool:pip (creates a virtualenv and installs Pillow and NumPy from PyPI) -->
```bash
python3 -m venv .godot-skill-venv
. .godot-skill-venv/bin/activate
python -m pip install pillow numpy
```

If your environment already allows direct installs, `python3 -m pip install pillow numpy` also works.
