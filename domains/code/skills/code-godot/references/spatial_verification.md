# Spatial Verification (2D And 3D, Without Eyes)

Read this when the thing you cannot see is **where something is in the world** — the player, the floor, the level, the
camera, the light — rather than where a Control is on the screen. `ui_report` covers the UI; `inspect_tilemap` covers
the cells you painted; `spatial_report` covers everything else, and it is the only check that catches these:

| The bug | What it looks like when you cannot see | What catches it |
| --- | --- | --- |
| Player spawned outside the camera view | The game "runs fine", screen is empty | `expect_on_screen` → `not_on_screen` |
| Player spawned inside the floor | Falls through, or jitters, or stands on nothing | `embedded_in_static` |
| Level painted at the wrong origin | `inspect_tilemap` rows look right, nothing is on screen | the `TileMapLayer` world `rect` + the ASCII map |
| 3D scene with no camera | Black frame, no error | `no_camera_3d` |
| 3D scene with no light | Black shapes on a grey frame, no error | `no_light_3d` |
| 3D camera pointing the wrong way | Black frame, no error | `not_in_frustum` / `behind_camera` |
| A node scaled to 0, or 100000 units away | Invisible, no error | `zero_scale`, `far_from_origin` |

It is a **scenario step**, so it sees the live, running scene — after `_ready`, after your spawn code, after the input
steps you drove. Run it with `scripts/debug/run_scenario.py`; it never needs a rendered window.

The parameter table and the full result shape are in `automation_api.md` → *spatial_report*. This file is the recipes.

---

## Recipe 1 — "Is the player on screen and standing on the floor?"

The single most useful gate for a 2D game. Put it right after boot, and again after anything that moves the player.

A level to try it on — a bordered tile floor, a small platform, a hero standing on it, a camera. `art/tiles.png` is
any 16 px tile strip (`references/pixel_art.md` draws one) and `art/player.png` any sprite:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  build_tileset '{"resource_path":"tilesets/world.tres","tile_size":{"x":16,"y":16},
                  "physics_layers":[{"collision_layer":1,"collision_mask":1}],
                  "sources":[{"source_id":0,"texture":"art/tiles.png","tiles":"all",
                              "tile_defaults":{"collision":"full_cell"}}]}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level.tscn", "create_if_missing": true,
    "root_node_type": "Node2D", "root_node_name": "Level",
    "actions": [
      {"type":"add_node","node_type":"TileMapLayer","node_name":"Ground",
       "properties":{"tile_set":{"__resource":"res://tilesets/world.tres"}}},
      {"type":"add_node","node_type":"CharacterBody2D","node_name":"Hero",
       "properties":{"position":{"__type":"Vector2","x":72,"y":39}}},
      {"type":"add_node","parent_node_path":"root/Hero","node_type":"Sprite2D","node_name":"Sprite2D",
       "properties":{"texture":{"__resource":"res://art/player.png"}}},
      {"type":"add_node","parent_node_path":"root/Hero","node_type":"CollisionShape2D","node_name":"CollisionShape2D",
       "properties":{"shape":{"__resource_type":"RectangleShape2D",
                              "properties":{"size":{"__type":"Vector2","x":10,"y":18}}}}},
      {"type":"add_node","node_type":"Camera2D","node_name":"Camera2D",
       "properties":{"position":{"__type":"Vector2","x":80,"y":48}}}
    ]}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  paint_tilemap '{"scene_path":"scenes/level.tscn","node_path":"root/Ground","tile_set":"tilesets/world.tres",
                  "ascii_map":{"legend":{"g":{"source_id":0,"atlas_coords":{"x":0,"y":0}},
                                         "d":{"source_id":0,"atlas_coords":{"x":1,"y":0}}},
                               "rows":["dddddddddd","d........d","d........d","d..gggg..d","d........d","dddddddddd"]}}'
```

The gate itself:

```bash
cat > /absolute/path/to/project/scenario.json <<'JSON'
{
  "scene_path": "scenes/level.tscn",
  "viewport_size": {"width": 320, "height": 180},
  "steps": [
    {"type": "spatial_report", "label": "boot", "ascii": true,
     "ascii_size": {"cols": 48, "rows": 18},
     "expect_on_screen": ["Hero"],
     "fail_on": ["not_on_screen", "embedded_in_static", "no_camera_2d"]}
  ],
  "assertions": [],
  "log_assertions": [{"regex": "spatial_report boot .* findings=0"}]
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario.json --log-file /absolute/path/to/project/run.log --pretty
```

Exit `0`, and this in the log and in `spatial_reports[0]` (the map's empty border rows are elided here):

```text
[SCENARIO] spatial_report boot dim=2d nodes=5 on_screen=4 off_screen=0 screen_space=0 findings=0 camera=Camera2D
[SCENARIO] spatial_report boot ascii 48x18 bounds=[-3.2, -14.4, 166.4, 124.8] x right, y down (top-down XY)
 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
 aaaaa                                    aaaaa
 aaaaa                                    aaaaa
 aaaaa             cddddc                 aaaaa
 aaaaa             cddddc                 aaaaa
 aaaaa             cddddc                 aaaaa
 aaaaa         aaaaadddd@aaaaaaaa         aaaaa
 aaaaa         aaaaaaaaaaaaaaaaaa         aaaaa
 aaaaa                                    aaaaa
 aaaaa                                    aaaaa
 aaaaa                                    aaaaa
 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  a = Ground (TileMapLayer)
  c = Hero/Sprite2D (Sprite2D)
  d = Hero/CollisionShape2D (CollisionShape2D)
  @ = Camera2D (Camera2D)
```

What each piece of that tells you:

- `on_screen=4 off_screen=0` — nothing measurable is outside the view. The camera itself is located but never counted.
- The hero is drawn as `d` (collider, 10x18) with `c` (the 16x16 sprite) showing on either side of it: the sprite is
  wider than the collider — exactly the mismatch that makes a character clip into a wall it looks clear of.
- The last `d` row sits directly on the platform's `a` row, so the hero is *on* the floor. If it were *in* it, the
  `d` block would overlap the `a` block and `embedded_in_static` would have fired — which is what the same scene
  reports when the hero's `position.y` is `56` instead of `39`.
- `findings=0` with `fail_on` set means the run is green for the right reason, not because nothing was checked.

**The failure modes, and what they print** — here on a plain `Player` + `Floor` + `Camera2D` scene. Move the player
5000 px away:

```
[SCENARIO] spatial_report far dim=2d nodes=8 on_screen=5 off_screen=3 screen_space=2 findings=1 (not_on_screen:1) camera=Camera2D
[SCENARIO] spatial_report far finding not_on_screen: expect_on_screen: Player (CharacterBody2D) draws at screen
rect [10296, 232, 48, 80], entirely outside the [0, 0, 640, 360] viewport. Its world rect is [5188, 156, 24, 40]
and the camera sees [40, 40, 320, 180].
```

Spawn it 20 px into a 24 px floor:

```
[SCENARIO] spatial_report sunk dim=2d nodes=8 ... findings=1 (embedded_in_static:1) camera=Camera2D
[SCENARIO] spatial_report sunk finding embedded_in_static: Player (CharacterBody2D) overlaps the static collision
of Floor (StaticBody2D) right now — it is inside the wall/floor, not resting on it. Move it out along its up axis,
or shrink its collision shape.
```

`embedded_in_static` is deliberately quiet about *resting*: the query shape is shrunk by `embed_margin`
(default 1 px in 2D, 1 cm in 3D) before the space state is asked, so a body whose collider touches the floor exactly
is standing on it, not inside it. A `TileMapLayer`'s or `GridMap`'s own collision counts as static, so a character
sunk into a painted level is caught too.

---

## Recipe 2 — "Does the 3D scene have a camera and a light, and is the mesh in view?"

Three separate reasons a 3D scene renders an empty frame, none of which produces an error. One step covers all three.

A scene with a floor, a crate, a hero and a camera — and deliberately no light:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{
    "scene_path": "scenes/level3d.tscn", "create_if_missing": true,
    "root_node_type": "Node3D", "root_node_name": "Level3D",
    "actions": [
      {"type":"add_node","node_type":"StaticBody3D","node_name":"Ground"},
      {"type":"add_node","parent_node_path":"root/Ground","node_type":"CollisionShape3D","node_name":"CollisionShape3D",
       "properties":{"shape":{"__resource_type":"BoxShape3D",
                              "properties":{"size":{"__type":"Vector3","x":16,"y":0.5,"z":16}}},
                     "position":{"__type":"Vector3","x":0,"y":-0.25,"z":0}}},
      {"type":"add_node","node_type":"MeshInstance3D","node_name":"Crate",
       "properties":{"mesh":{"__resource_type":"BoxMesh",
                             "properties":{"size":{"__type":"Vector3","x":1,"y":1,"z":1}}},
                     "position":{"__type":"Vector3","x":0,"y":1,"z":0}}},
      {"type":"add_node","node_type":"CharacterBody3D","node_name":"Hero",
       "properties":{"position":{"__type":"Vector3","x":2,"y":1,"z":0}}},
      {"type":"add_node","parent_node_path":"root/Hero","node_type":"CollisionShape3D","node_name":"CollisionShape3D",
       "properties":{"shape":{"__resource_type":"CapsuleShape3D","properties":{"radius":0.4,"height":1.8}}}},
      {"type":"add_node","node_type":"Camera3D","node_name":"Camera3D",
       "properties":{"position":{"__type":"Vector3","x":0,"y":2,"z":6}}}
    ]}'
cat > /absolute/path/to/project/scenario3d.json <<'JSON'
{
  "scene_path": "scenes/level3d.tscn",
  "viewport_size": {"width": 640, "height": 360},
  "steps": [
    {"type": "spatial_report", "label": "render-check", "ascii": true,
     "ascii_size": {"cols": 48, "rows": 16},
     "expect_on_screen": ["Crate"],
     "fail_on": ["no_camera_3d", "no_light_3d", "not_in_frustum", "behind_camera", "embedded_in_static"]}
  ],
  "assertions": []
}
JSON
```

With a camera but no light, that scenario exits `1`:

<!-- replay: fails -->
```bash
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario3d.json --log-file /absolute/path/to/project/run3d.log --pretty
```

```text
[SCENARIO] spatial_report render-check dim=3d nodes=6 on_screen=5 off_screen=0 screen_space=0 findings=1 (no_light_3d:1) camera=Camera3D
[SCENARIO] spatial_report render-check finding no_light_3d: No visible Light3D with energy above zero and no
Environment ambient/sky light — a lit (non-unshaded) material renders black here. Add a DirectionalLight3D, or a
WorldEnvironment whose Environment sets ambient_light_source/background to a sky or colour. Lights found: 0.
No Environment on the camera, the World3D or the project's fallback.
[SCENARIO] spatial_report render-check ascii 48x16 bounds=[-12.48, -8.32, 24.96, 16.64] x right, z down (top-down XZ)
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
::::::::bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb::::::::
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        bbbbbbbbbbbbbbbccbbeebbbbbbbbbbb
        bbbbbbbbbbbbbbbccbbeebbbbbbbbbbb
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        bbbbbbbbbbbbbbbb^bbbbbbbbbbbbbbb
::::::::bbbbbbbbbbbbbbbb@bbbbbbbbbbbbbbb::::::::
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : = camera frustum footprint
  b = Ground/CollisionShape3D (CollisionShape3D)
  c = Crate (MeshInstance3D)
  e = Hero/CollisionShape3D (CollisionShape3D)
  @ = Camera3D (Camera3D)
  ^ = camera facing
```

The map is **XZ seen from above with +Z down the page**, so `@` at the bottom with `^` above it means a camera at
positive Z looking toward the origin — which is what "the camera is behind the scene looking at it" reads like
without a picture. Add the light and the same step exits `0` with `findings=0`:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  add_node '{"scene_path":"scenes/level3d.tscn","parent_node_path":"root","node_type":"DirectionalLight3D",
             "node_name":"Sun","properties":{"rotation_degrees":{"__type":"Vector3","x":-45,"y":-30,"z":0}}}'
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario3d.json --log-file /absolute/path/to/project/run3d.log --pretty
```

The two ways to make it `lit`:

- adding a `DirectionalLight3D` → `"lighting": {"lit": true, "lights": ["DirectionalLight3D"], "environment_light": false}`
- adding a `WorldEnvironment` whose `Environment` has `ambient_light_source = 2` (colour) and
  `ambient_light_energy = 1.0` → `"lighting": {"lit": true, "lights": [], "environment_light": true}`

`no_light_3d` is a *report*, not a verdict: a shader or `StandardMaterial3D` with `shading_mode = unshaded` renders
fine with no light at all. It is loud because the case it catches — a lit material in an unlit scene — is otherwise
completely silent. Leave it out of `fail_on` for an unshaded/2.5D project.

Turn the camera around and the message names the geometry instead of guessing:

```
[SCENARIO] spatial_report looking-away ... findings=2 (no_light_3d:1, behind_camera:1) camera=Camera3D
[SCENARIO] spatial_report looking-away finding behind_camera: expect_on_screen: Crate (MeshInstance3D) at
[0, 1, 0] is behind the camera at [0, 2, 6] looking [0, 0, 1] — turn the camera around or move the node in front of it.
```

A node that is in front of the camera but outside the cone gets `not_in_frustum` with the camera's `fov` and `far`,
so you can tell "aimed wrong" from "too far away" without a screenshot. When the node **is** in the frustum, the
entry carries `screen_pos` — the pixel `Camera3D.unproject_position` puts it at — which is how you check a 3D object
lines up with a 2D HUD marker. `screen_pos` is omitted when the node is behind the camera, because `unproject_position`
returns a mirrored point there.

---

## Recipe 3 — "Did my level end up where I think?"

`inspect_tilemap` proves the *cells* are right. It cannot tell you the layer is offset 200 px from the camera, or
that the player spawn sits outside it. `spatial_report` answers in world units:

```json
{"type": "spatial_report", "label": "level", "classes": ["TileMapLayer", "Camera2D", "CharacterBody2D"],
 "ascii": true, "ascii_bounds": "camera"}
```

```json
{"path": "Ground", "class": "TileMapLayer", "space": "world", "kind": "tiles",
 "rect": [0, 0, 160, 96], "z_index": 0, "screen_rect": [80, 42, 160, 96], "on_screen": true}
```

A 10x6 map of 16 px tiles painted from the origin is `[0, 0, 160, 96]`. If the `rect` is `[160, 0, 160, 96]` the
`origin` in your `paint_tilemap` call was off by ten cells; if it is `[0, 0, 320, 192]` the layer is scaled 2x; if
`on_screen` is `false` the camera is not looking at the level at all.

A tile layer is drawn on the ASCII map **cell by cell**, not as a filled bounding box, so the map has the shape of
the level: compare it with the `ascii_map.rows` you painted and with `inspect_tilemap`'s read-back. The three should
agree, and when they do not, the one that disagrees names the bug.

`ascii_bounds` picks the framing:

- `"content"` (default) frames everything that was measured, plus the camera. Use it to find a node that wandered off.
- `"camera"` frames the camera's view rect (2D) or frustum footprint (3D). Use it to answer "what would the player see".

---

## Reading the numbers

- **`rect` vs `screen_rect` (2D).** `rect` is the world rect — the one that matches the `.tscn` and the one to reason
  about placement with. `screen_rect` is that rect through the viewport's canvas transform, which already contains the
  active `Camera2D`'s zoom, offset, rotation, limits and current smoothing position. `on_screen` is
  `screen_rect` intersecting the viewport, so a partially visible node counts as on screen (same rule as `ui_report`'s
  `offscreen`).
- **Screen space.** Anything under a `CanvasLayer` is placed in screen space, not world space. Those entries get
  `"space": "screen"`, their `rect` equals their `screen_rect`, they are never compared with the world view rect, and
  they are left off the world ASCII map. A HUD lives there; use `ui_report` for its layout.
- **Where a rect comes from** (`kind`): `texture` = `Sprite2D.get_rect()` / the current `SpriteFrames` frame texture;
  `shape` = `Shape2D.get_rect()` or `Shape3D.get_debug_mesh().get_aabb()`; `shapes` = the union of a
  `CollisionObject2D/3D`'s own shape owners, which is why a bare `CharacterBody2D` still has a rect; `tiles` =
  `get_used_rect()` × `TileSet.tile_size` (or a `GridMap`'s used cells × `cell_size`); `polygon`, `light`, `control`,
  `point`, `camera` as named. A node with none of those — a plain `Node2D`, a `MeshInstance3D` with no mesh — is not
  listed, and naming it in `expect_on_screen` says so instead of passing silently.
- **`distance_to_camera`** is measured to the AABB centre, not the node origin.
- **Rotation.** A rotated `Camera2D` makes `view_rect` the axis-aligned bound of the rotated view, and a rotated node's
  `rect` the axis-aligned bound of its rotated rect. Both are therefore slightly generous; `rotation_degrees` on the
  camera entry tells you when that applies.

## How it fits the other text read-backs

| Question | Tool |
| --- | --- |
| Where are the Controls, do they overlap, is one zero-sized? | `ui_report` step |
| What nodes exist and what are their property values? | `dump_tree` step |
| Which cells did I paint? | `inspect_tilemap` op |
| Where is everything in the world, can the camera see it, is it in the floor? | `spatial_report` step |
| Did the frame actually draw anything? | `screenshot` step with `expect.not_blank` |
| What does this PNG contain? | `inspect_image` op |

`spatial_report` and `screenshot` answer different halves of "is it visible": `spatial_report` proves the node is
positioned where the camera can see it and that the scene has a camera and a light; a `screenshot` with
`{"not_blank": true}` proves pixels actually came out. Run the spatial gate on every scenario (it is free and
headless) and the screenshot gate where a framebuffer exists.

## Limits

- Everything is measured **now**, in the frame the step runs. The step awaits `settle_frames` process frames and one
  physics frame first, so a transform written by an earlier `set_property` is already flushed to the physics server.
- `embedded_in_static` only knows about shapes that exist as nodes or shape owners at that moment. A collider a script
  adds later, or a one-way platform's direction, is invisible to it.
- Visibility is geometric. A node inside the frustum can still be hidden by `modulate.a = 0`, a material that discards
  every fragment, `visibility_layer`/`cull_mask` bits, or another object in front of it (`check_occlusion` is a
  best-effort physics ray, off by default, and only sees colliders).
- `no_camera_2d` is only raised when the world content actually reaches past the raw viewport; a small scene that fits
  on screen needs no camera and is not nagged about one.
- The ASCII map samples the world at one point per character cell, so a level much larger than the grid is decimated
  the way a downscaled image is. Raise `ascii_size` or narrow the walk with `node_path`/`classes` when detail matters.
- `dimension: "auto"` picks `3d` as soon as the subtree holds any `Node3D`. A scene with both a 3D world and a 2D HUD
  reports the 3D world; read the HUD with `ui_report`.
