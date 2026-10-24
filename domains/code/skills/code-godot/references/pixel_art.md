# Pixel Art Without An Image Generator

Read this when a task needs 2D art — a sprite, an animation, a tileset, a UI panel, a placeholder — or when
art that came out of an image generator has to become real pixel art.

Two operations cover it:

- **`draw_image`** — ASCII rows and drawing primitives → a PNG. Authoring.
- **`process_image`** — an ordered pixel pipeline over one image, a list, or a directory. Cleanup and packing.

Both run on Godot's `Image` class: no GPU, no rendering device, no import pass, no Python dependency.

## The loop

```
author as text  ->  draw_image  ->  read the PNG back as text  ->  gate it  ->  wire it into a resource
```

Every `draw_image` payload carries the round trip: `frame_reports[*].rows` is the written PNG read back one
character per pixel, with `legend` mapping each character to its hex colour. If those rows are not what you
typed, the file is not what you meant — no screenshot needed. `inspect_image` then re-reads the file
independently and can fail the run with `expect`.

**Always: `draw_image` → check `frame_reports[*].rows` → `inspect_image` with `expect` → only then reference the
file from a `.tscn`/`.tres`.** A freshly written PNG has no `.import` sidecar (every payload says
`"needs_import": true`), so run `scripts/import/import_project.py PROJECT` before a scene or resource points at it.

---

## 1. Authoring a sprite as ASCII rows

One character is one pixel. `.` and a space are always transparent and cannot be remapped. Every row must be the
same length — a ragged row is an error, not a warning (an image is a rectangle).

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/hero.png",
    "palette": {"o": "#000000", "s": "#ffccaa", "h": "#ab5236", "b": "#29adff"},
    "rows": ["........", "....hhhh", "..hhhhhh", ".hhhhhhh", ".hssssss", ".hsossss",
             "..ssssss", "...sssss", "..bbbbbb", ".bbbbbbb", ".bsbbbbb", "..bbbbbb",
             "...bbbbb", "...bb...", "..ooo...", "........"],
    "mirror_x": true,
    "outline": "#000000"
  }'
```

Eight authored columns, mirrored, outlined — a 16×16 sprite whose read-back is exactly:

```
...oooooooooo...
.ooohhhhhhhhooo.
oohhhhhhhhhhhhoo
ohhhhhhhhhhhhhho
ohssssssssssssho
ohsossssssssosho
oossssssssssssoo
.oossssssssssoo.
oobbbbbbbbbbbboo
obbbbbbbbbbbbbbo
obsbbbbbbbbbbsbo
oobbbbbbbbbbbboo
.oobbbbbbbbbboo.
.oobboooooobboo.
.ooooo....ooooo.
.ooooo....ooooo.
```

### Rules that make the result look like art

- **Sizes.** 8×8 pickups and tiles, 16×16 characters and icons, 32×32 bosses and detailed props. Bigger costs
  more tokens and buys little: a 16×16 sprite is 16 short strings.
- **Silhouette first.** Draw the shape in one colour and read it back. If the silhouette is not recognisable at
  one character per pixel, no amount of shading will save it.
- **Three tones per material.** A base, one shadow, one highlight — `#3e8948` / `#265c42` / `#63c74d`. Four or
  more tones on a 16px sprite turns to mush. A named palette gives you ramps that already agree with each other.
- **Outline last.** `"outline": "#000000"` puts one pixel around every opaque pixel. An outline never grows the
  canvas, so leave a transparent margin in your rows (a blank first and last row and column) or that side is
  clipped — the payload then carries `"outline_clipped": true` and says so. Same in a `process_image` pipeline:
  `trim` immediately followed by `outline` always clips, so use `{"type": "trim", "padding": 1}`.
- **Mirror to halve the work.** Author the left half and let `mirror_x` build the rest:
  - `true` / `"append"` — output is `2w` wide. Draw the centre line into the *last* authored column.
  - `"append_odd"` — output is `2w-1`; the last authored column becomes the shared centre column.
  - `"fold"` — output keeps `w`; the first half is mirrored over the second, and an odd width keeps its centre
    column untouched.
  - `mirror_y` does the same vertically. Mirroring happens *before* the outline and shadow, so those wrap the
    whole sprite.
- **Animate by editing a few pixels.** A walk cycle is the same body with the legs moved; see §3.

### Named palettes

`"palette_name": "pico8"` binds the characters `0-9` then `a-v` to the palette's colours in order (32
addressable entries). An explicit `"palette"` is laid on top, so you can name the colours you care about and
still reach the rest by index. The read-back prefers the characters you named.

| name | size | what it is |
| --- | --- | --- |
| `pico8` | 16 | PICO-8 system palette |
| `sweetie16` | 16 | Sweetie 16 by GrafxKid |
| `db16` | 16 | DawnBringer 16 |
| `db32` | 32 | DawnBringer 32 |
| `endesga32` | 32 | Endesga 32 (EDG32) |
| `c64` | 16 | Commodore 64 (Pepto rendering) |
| `cga` | 16 | IBM CGA/EGA 16 |
| `gameboy` | 4 | Game Boy DMG green ramp, darkest first |
| `grayscale4` | 4 | 0x00 / 0x55 / 0xaa / 0xff |
| `nes` | 55 | NES 2C02 as the FCEUX/Nintendulator table renders it, duplicate blacks dropped |

An unknown name is an error that lists all of them with their sizes. The exact values live in
`scripts/core/palettes.gd`; a palette whose published values could not be confirmed is deliberately absent
rather than approximated. The NES has no single true RGB palette — every emulator and TV differs — so treat
`nes` as one common rendering, best used for `quantize` rather than as gospel.

---

## 2. Shapes: tiles, panels, placeholders

Without `rows`, `width` + `height` give you a canvas and `shapes` draws on it in order. Shape types:
`rect`, `rect_outline`, `circle`, `ellipse`, `line`, `polygon`, `pixel`, `pixels`, `gradient_rect`, `checker`,
`noise`, `text`. Run `help '{"op":"draw_image"}'` for every shape's keys.

Colours are `"#rrggbb"`, `"#rrggbbaa"`, `"#rgb"`, `null` for transparent, or a single palette character.
`x`/`y` default to 0 and `width`/`height` to the rest of the canvas, so `{"type": "rect", "color": "#3e8948"}`
fills everything. A shape that lands entirely off-canvas is an error, not a silent no-op.

### A seamless 16×16 tileset in one call

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

Three frames, one 48×16 atlas, and per frame:

```json
{"left_right_match": 0.4375, "top_bottom_match": 0.5,
 "wrap_delta_x": 0.0530637, "interior_delta_x": 0.0427859, "interior_max_x": 0.0795955,
 "wrap_delta_y": 0.0466911, "interior_delta_y": 0.0431127, "interior_max_y": 0.0576593,
 "seamless": true}
```

`tile_check` asks "would a copy of this tile next to itself show a seam": it compares the colour step across the
wrap with the steps the tile already contains. A checkerboard passes (its wrap is one more check boundary); a
left-to-right `gradient_rect` fails, because nothing inside it jumps the way its wrap does. It is a heuristic —
the definitive check is to tile it and look at the ASCII:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  process_image '{"input_path": "art/tiles.png", "output_path": "art/tiles_3x3.png",
                  "operations": [{"type": "crop", "x": 0, "y": 0, "width": 16, "height": 16},
                                 {"type": "tile", "columns": 3, "rows": 3}],
                  "ascii_width": 48}'
```

`noise` is seeded: the same `seed` always paints the same pixels, so a tileset is reproducible and a diff
against a previous run means something.

### A 9-patch UI panel

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/panel.png",
    "width": 24, "height": 24,
    "shapes": [
      {"type": "rect", "color": "#262b44"},
      {"type": "rect_outline", "x": 0, "y": 0, "width": 24, "height": 24, "color": "#5a6988", "thickness": 2},
      {"type": "rect_outline", "x": 2, "y": 2, "width": 20, "height": 20, "color": "#3a4466", "thickness": 1}
    ]
  }'
```

Then let `process_image` measure the margins instead of guessing them:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  process_image '{"input_path": "art/panel.png", "output_path": "art/panel.png",
                  "operations": [{"type": "nine_patch_margins"}], "describe": false}'
```

```json
{"margins": {"left": 3, "top": 3, "right": 3, "bottom": 3},
 "center": {"x": 3, "y": 3, "width": 18, "height": 18},
 "stylebox_texture": {"texture_margin_left": 3, "texture_margin_top": 3,
                      "texture_margin_right": 3, "texture_margin_bottom": 3},
 "nine_patch_rect": {"patch_margin_left": 3, "patch_margin_top": 3,
                     "patch_margin_right": 3, "patch_margin_bottom": 3}}
```

The numbers are the longest run of identical neighbouring columns/rows, so they only mean "9-patch" when the
image is one. When the stretchable centre is under half the image the payload adds a `note` saying so — a round
sprite answers this question too.

### text

`{"type": "text", "x": 1, "y": 1, "text": "HP", "color": "#ffffff"}` draws with a built-in 3×5 uppercase font
(A–Z, 0–9, and `. , ! ? - + : / % * = < > ( )` and space), `scale` for integer zoom. It is for placeholders,
tile labels and debug art — real UI text belongs in a `Label` with a real font.

---

## 3. A frame sheet that `build_sprite_frames` can read

`frames` packs every frame into one sheet and returns the grid:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  draw_image '{
    "output_path": "art/hero_walk.png",
    "palette": {"o": "#000000", "s": "#ffccaa", "b": "#29adff"},
    "layout": "horizontal",
    "frames": [
      {"name": "walk_0", "rows": ["..ssss..", ".ssssss.", ".s.ss.s.", "..ssss..", "..bbbb..", ".b.bb.b.", "...bb...", "..o..o.."]},
      {"name": "walk_1", "rows": ["..ssss..", ".ssssss.", ".s.ss.s.", "..ssss..", "..bbbb..", ".b.bb.b.", "..b..b..", ".o....o."]},
      {"name": "walk_2", "rows": ["..ssss..", ".ssssss.", ".s.ss.s.", "..ssss..", "..bbbb..", ".b.bb.b.", "...bb...", "..o..o.."]},
      {"name": "walk_3", "rows": ["..ssss..", ".ssssss.", ".s.ss.s.", "..ssss..", "..bbbb..", ".b.bb.b.", "..bb.b..", "..o...o."]}
    ]
  }'
```

Payload (trimmed): `"width": 32, "height": 8, "frames": 4`,
`"grid": {"cell_width": 8, "cell_height": 8, "separation_x": 0, "separation_y": 0, "margin_x": 0, "margin_y": 0}`,
and one `frame_reports` entry per frame with its `region` and its character rows.

Every frame must be the same size — a mismatch names both frames and writes nothing. `layout` is
`"horizontal"` (default), `"vertical"` or `"grid"` (with `columns`); `separation` adds transparent gutters and
is echoed into the grid.

Feed the grid straight in, after importing:

```bash
python3 /absolute/path/to/godot/scripts/import/import_project.py /absolute/path/to/project

godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  create_scene '{"scene_path": "scenes/hero.tscn", "root_node_type": "CharacterBody2D", "root_node_name": "Hero"}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  add_node '{"scene_path": "scenes/hero.tscn", "node_type": "AnimatedSprite2D", "node_name": "Sprite"}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  build_sprite_frames '{
    "scene_path": "scenes/hero.tscn",
    "node_path": "root/Sprite",
    "spritesheet": "art/hero_walk.png",
    "grid": {"cell_width": 8, "cell_height": 8},
    "animations": [{"name": "walk", "fps": 8, "loop": true, "frames": [{"row": 0, "cols": [0, 1, 2, 3]}]}],
    "resource_save_path": "art/hero_walk_frames.tres"
  }'
```

Separate frame *files* (what an image generator produces) go the other way: `process_image` with
`{"type": "pack_frames"}` over a directory returns the same `grid`, and `{"type": "split_sheet"}` turns a sheet
back into numbered files. The two round-trip byte-for-byte.

---

## 4. Tiles → `build_tileset` → `paint_tilemap`

```bash
python3 /absolute/path/to/godot/scripts/import/import_project.py /absolute/path/to/project

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

`"tiles": "all"` exposes one tile per 16×16 cell of the 48×16 atlas, so the atlas coordinates are the frame
order from `draw_image`: `{"x": 0, "y": 0}` grass, `{"x": 1, "y": 0}` dirt, `{"x": 2, "y": 0}` stone. Then paint
and read the level back:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  create_scene '{"scene_path": "scenes/level.tscn", "root_node_type": "Node2D", "root_node_name": "Level"}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  add_node '{"scene_path": "scenes/level.tscn", "node_type": "TileMapLayer", "node_name": "Ground"}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  paint_tilemap '{
    "scene_path": "scenes/level.tscn",
    "node_path": "root/Ground",
    "tile_set": "tilesets/world.tres",
    "ascii_map": {
      "legend": {"g": {"source_id": 0, "atlas_coords": {"x": 0, "y": 0}},
                 "d": {"source_id": 0, "atlas_coords": {"x": 1, "y": 0}},
                 "s": {"source_id": 0, "atlas_coords": {"x": 2, "y": 0}}},
      "rows": ["ssssssss", "sdddddds", "sdggggds", "sdggggds", "sdddddds", "ssssssss"]
    }
  }'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_tilemap '{"scene_path": "scenes/level.tscn", "node_path": "root/Ground"}'
```

`inspect_tilemap` answers with `"rows": ["########", "#@@@@@@#", "#@%%%%@#", "#@%%%%@#", "#@@@@@@#", "########"]`
and a legend mapping each character back to its atlas coordinates — the level verified as text, end to end.

---

## 5. Panel → `build_theme` StyleBoxTexture

Use the margins `nine_patch_margins` measured. The inline resource form needs its fields under `properties` —
anything else in that object is ignored:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  build_theme '{
    "resource_path": "theme/main.tres",
    "types": {
      "PanelContainer": {
        "styleboxes": {
          "panel": {
            "__resource_type": "StyleBoxTexture",
            "properties": {
              "texture": {"__resource": "res://art/panel.png"},
              "texture_margin_left": 3, "texture_margin_top": 3,
              "texture_margin_right": 3, "texture_margin_bottom": 3
            }
          }
        }
      }
    }
  }'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_resource '{"resource_path": "theme/main.tres"}'
```

`inspect_resource` must show `"texture": {"__resource": "res://art/panel.png"}` and the four margins. If the
texture reads back as `null`, the PNG was not imported yet — run `import_project.py` and build the theme again.
For a `NinePatchRect` node instead of a theme, the same numbers go on the node as `patch_margin_left` … through
`configure_node`.

---

## 6. Cleaning up art that came from an image generator

Generated "pixel art" is almost never pixel art: soft anti-aliased edges, pixels that do not sit on a grid,
thousands of colours, and a baked-in background. `process_image` fixes all four, in this order:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  process_image '{
    "input_path": "art/raw_hero.png",
    "output_path": "art/hero.png",
    "operations": [
      {"type": "remove_background", "tolerance": 0.1},
      {"type": "trim", "padding": 1},
      {"type": "pixelate", "target_width": 32, "mode": "average", "palette_name": "pico8", "alpha_threshold": 0.5}
    ]
  }'
```

Step report from a real 256×256 source:

```
remove_background  256x256  457 colours
trim               154x218  457 colours
pixelate            32x45     7 colours
```

1. **`remove_background`** floods inwards from the four corners with `tolerance`, so a background colour that
   also appears *inside* the subject survives. When the background is a flat chroma key, name it:
   `{"type": "remove_background", "color": "#00ff00", "tolerance": 0.05}` (that clears every matching pixel,
   enclosed or not), or use `replace_color` with `"to": null`. It fails loudly when it would change nothing.
2. **`trim`** crops to the content box; `"padding": 1` leaves room for an outline. `{"type": "trim", "color": "#00ff00"}`
   trims a flat colour instead of transparency.
3. **`pixelate`** is the operation that makes it real art. `target_width` (or `cell_size`) sets the grid;
   `mode` is `average` (premultiplied block mean, best for photos and soft art), `mode` (most common colour in
   the cell, best for art that is already blocky), or `nearest` (one sample). Add `palette_name`/`palette`/
   `max_colors` to fix the palette in the same step, and `alpha_threshold` to make every pixel fully opaque or
   fully transparent — that is what kills the soft halo.
4. Optional: `{"type": "pad", "multiple": 16}` to land on a tile grid, `{"type": "outline"}` to add a border.

Then gate the result instead of trusting it:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_image '{"image_path": "art/hero.png",
                  "expect": {"not_blank": true, "has_alpha": true, "max_unique_colors": 16, "width": 32}}'
```

`max_unique_colors` is the check that catches fake pixel art: a soft 512×512 blob reports hundreds of colours,
the cleaned 32×32 version reports six.

---

## 7. Verifying without eyes

| question | how |
| --- | --- |
| Did the file get what I typed? | `frame_reports[*].rows` + `legend` in the `draw_image` payload |
| Is it the right size / palette / not empty? | `inspect_image` with `expect` (`width`, `height`, `max_unique_colors`, `not_blank`, `has_alpha`) |
| Which colours does it actually use? | `draw_image` `colors[]` (exact, per pixel count) or the `quantize` step's `colors_used` |
| Where is the subject on the canvas? | `summary.content_bbox` (full-resolution, exact) |
| Did this frame change since last time? | `inspect_image` `compare_to` + `expect.max_diff_ratio` |
| Do the frames of a sheet line up? | `inspect_image` `image_paths` + `expect.frames_consistent` |
| Will the tile show a seam? | `draw_image` `tile_check`, then `process_image` `tile` + the ASCII |
| Does it look right in the game? | the scenario runner's `screenshot` step (`references/debugging.md`) |

The ASCII in `summary`/`ascii` is a luminance ramp, aspect-corrected (characters are twice as tall as they are
wide), so it is for shape and composition. For exact pixels use the character read-back, not the ASCII.

---

## 8. Limits

- Output is PNG (or WebP). There is no JPEG output: pixel art needs lossless with alpha.
- `draw_image` has no anti-aliasing and no sub-pixel anything — by design.
- `text` is one small built-in font, uppercase only.
- `quantize` has no dithering; on a photographic source expect banding. Pixel art does not want dithering anyway.
- `remove_background` is a flood fill, not a segmenter. Soft drop shadows and gradient backgrounds need
  `replace_color` with tolerance, or a chroma-key re-export.
- `tile_check` and `nine_patch_margins` are heuristics and say so in their payloads.
- The character read-back is on automatically below 4096 px per frame and capped at 65536 px; above that use
  `inspect_image`.
- Everything written here needs `import_project.py` before a `.tscn`/`.tres` can reference it (gotcha: a fresh
  PNG has no `.import` sidecar, and `load("res://…")` fails on it in a later process).
