# Shaders — Copy A Template, Attach It, Prove It Runs

Coding agents write Godot shaders from memory and get Godot 3 (`hint_color`, `SCREEN_TEXTURE`,
`WORLD_MATRIX`) or plain GLSL, and **Godot 4.7 does not complain at draw time**: a shader that fails
to compile is silently replaced by the default material and the sprite keeps rendering. The frame
looks plausible, the effect is missing, and nothing in the log says why unless you go looking.

So: do not write a shader from memory. Copy one of the 24 verified files in
`templates/shaders/`, attach it with the commands in its header, and run the verification loop at
the bottom of this page. Every file here compiles with zero diagnostics on `godot 4.7.stable` and
is covered by a pixel-level test in `tests/test_shader_templates.py`.

## Contents

- [Pick a shader](#pick-a-shader)
- [Attach it](#attach-it)
- [Set and animate uniforms](#set-and-animate-uniforms)
- [One material, many nodes](#one-material-many-nodes)
- [Godot 4.7 shading-language facts](#godot-47-shading-language-facts)
- [Godot 3 to 4 renames](#godot-3-to-4-renames)
- [Performance](#performance)
- [Verify it without looking](#verify-it-without-looking)

## Pick A Shader

2D (`shader_type canvas_item`) — the `material` slot of a CanvasItem:

| I want | Template | Key uniforms |
| --- | --- | --- |
| A hit flash when something takes damage | `templates/shaders/flash.gdshader` | `flash_amount` 0..1, `flash_color` |
| An outline around a sprite (selection, hover) | `templates/shaders/outline_2d.gdshader` | `outline_width`, `outline_color`, `inside` |
| Something burns away / materialises | `templates/shaders/dissolve_2d.gdshader` | `progress` 0..1, `noise`, `edge_color` |
| Team colours from one sprite sheet (exact colours) | `templates/shaders/palette_swap.gdshader` | `source_colors[]`, `target_colors[]`, `color_count` |
| Team colours by hue rotation (any art) | `templates/shaders/hsv_shift.gdshader` | `hue_shift`, `saturation`, `value` |
| Death / disabled / paused look | `templates/shaders/grayscale.gdshader` | `amount`, `tint` |
| Parallax background, conveyor, waterfall | `templates/shaders/scroll.gdshader` | `scroll_speed`, `scroll_offset`, `tiling` |
| Grass, flags, banners swaying | `templates/shaders/wave.gdshader` | `amplitude`, `speed`, `phase`, `anchor` |
| Retro block-down transition | `templates/shaders/pixelate.gdshader` | `block_size` |
| Darken the screen edges, damage flash | `templates/shaders/vignette.gdshader` | `strength`, `inner_radius`, `outline_radius` |
| Whole game looks like an old TV | `templates/shaders/crt.gdshader` | `curvature`, `scanline_count`, `aberration` |
| Water / lava / heat haze strip | `templates/shaders/water_2d.gdshader` | `distortion`, `water_color`, `foam_height` |
| Explosion ring that warps the screen | `templates/shaders/shockwave.gdshader` | `center`, `radius`, `strength` |
| Frosted pause backdrop | `templates/shaders/blur.gdshader` | `blur_radius`, `samples`, `tint` |
| Player behind a wall, drop shadow, ghost | `templates/shaders/silhouette.gdshader` | `silhouette_color`, `amount` |
| Ability cooldown pie on an icon | `templates/shaders/progress_radial.gdshader` | `progress`, `cut_out` |

3D (`shader_type spatial`) — `material_override`, `surface_material_override/0`, or `next_pass`:

| I want | Template | Key uniforms |
| --- | --- | --- |
| Cel / toon shading that reacts to real lights | `templates/shaders/toon.gdshader` | `bands`, `band_softness`, `ambient` |
| A glowing silhouette (interactable, shield) | `templates/shaders/rim_fresnel.gdshader` | `rim_color`, `rim_power`, `rim_strength` |
| A mesh burns away | `templates/shaders/dissolve_3d.gdshader` | `progress`, `noise`, `triplanar` |
| Texture a mesh that has no usable UVs | `templates/shaders/triplanar.gdshader` | `albedo_texture`, `texture_scale` |
| Sci-fi projection / placement ghost | `templates/shaders/hologram.gdshader` | `base_alpha`, `scanline_count`, `glitch_amount` |
| A black outline around a character | `templates/shaders/outline_3d.gdshader` | `outline_width`, `outline_color` (goes in `next_pass`) |
| A water surface with depth tint and foam | `templates/shaders/water_3d.gdshader` | `depth_fade_distance`, `wave_strength`, `compatibility_depth` |
| An energy shield that glows where things touch it | `templates/shaders/force_field.gdshader` | `intersection_distance`, `hit_position`, `hit_time` |

Every file's own header block is the authoritative reference for it: what it goes on, which
renderers it works on, each uniform with its range and default, the literal attach commands, how to
drive it from GDScript / Tween / `AnimationPlayer`, and its sharing behaviour. Read the header
before the table.

## Attach It

Two absolute paths appear in every command below: `/absolute/path/to/godot` is the skill root (the folder
holding `SKILL.md`) and `/absolute/path/to/project` the Godot project (the folder holding `project.godot`).
Substitute both throughout. The shaders and their materials need somewhere to live:

```bash
mkdir -p /absolute/path/to/project/shaders /absolute/path/to/project/materials
```

A `.gdshader` is a native text resource: **no `.import` step, no import sidecar**. Copying the file
into the project is the whole installation.

### A sprite, with a material other nodes can share

```bash
cp /absolute/path/to/godot/templates/shaders/flash.gdshader /absolute/path/to/project/shaders/flash.gdshader
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  resource_batch '{"resource_path":"materials/flash.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/flash.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/flash_color":{"__type":"Color","r":1,"g":1,"b":1,"a":1},"shader_parameter/flash_amount":0.0}}]}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  configure_node '{"scene_path":"scenes/player.tscn","node_path":"root/Sprite2D","properties":{"material":{"__resource":"res://materials/flash.tres"}}}'
```

Order matters and the errors are loud: `shader` goes in a `set_properties` action, the uniforms in a
`set_indexed_properties` action **after** it. A `ShaderMaterial` only knows the names
`shader_parameter/*` once it has a shader.

To change a uniform on a saved `.tres` later, edit the `.tres` again — not the node:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  resource_batch '{"resource_path":"materials/flash.tres","actions":[{"type":"set_indexed_properties","properties":{"shader_parameter/flash_amount":0.5}}]}'
```

> `configure_node '{"indexed_properties":{"material:shader_parameter/flash_amount":0.5}}'` on a node
> whose material is an **external** `.tres` edits that *file*: the op saves the scene and then the
> `.tres` too (it logs `Also saved res://materials/flash.tres …`), exactly as the editor does — so
> every node sharing the material changes with it. The same call on an **inline** material (below)
> touches only that scene. A path that reaches into an imported file (`texture:…`) is refused,
> because nothing could save it.

### A sprite, with its own material stored inside the scene

One node, one effect, nothing shared — the usual case for a post-process rect or a one-off:

```bash
cp /absolute/path/to/godot/templates/shaders/silhouette.gdshader /absolute/path/to/project/shaders/silhouette.gdshader
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  add_node '{"scene_path":"scenes/main.tscn","parent_node_path":"root","node_type":"Sprite2D","node_name":"Ghost","properties":{"material":{"__resource_type":"ShaderMaterial","properties":{"shader":{"__resource":"res://shaders/silhouette.gdshader"},"shader_parameter/silhouette_color":{"__type":"Color","r":0.1,"g":0.1,"b":0.15,"a":0.6},"shader_parameter/amount":1.0}}}}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  configure_node '{"scene_path":"scenes/main.tscn","node_path":"root/Ghost","indexed_properties":{"material:shader_parameter/amount":0.75}}'
```

In the inline form the `shader` key must be **first** in `properties`; a `shader_parameter/*` key
before it is rejected with `Property does not exist at properties.material.properties`.

### Full-screen post-process (CRT, blur, vignette, shockwave)

A screen-reading shader sees what has already been drawn this frame, so the rect has to be on a
`CanvasLayer` above the content. Anything on a **higher** layer stays untouched — that is how you
keep the HUD sharp under a CRT.

```bash
cp /absolute/path/to/godot/templates/shaders/crt.gdshader /absolute/path/to/project/shaders/crt.gdshader
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  add_node '{"scene_path":"scenes/main.tscn","parent_node_path":"root","node_type":"CanvasLayer","node_name":"PostProcess","properties":{"layer":100}}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  add_node '{"scene_path":"scenes/main.tscn","parent_node_path":"root/PostProcess","node_type":"ColorRect","node_name":"CRT","properties":{"mouse_filter":2,"material":{"__resource_type":"ShaderMaterial","properties":{"shader":{"__resource":"res://shaders/crt.gdshader"},"shader_parameter/curvature":0.08,"shader_parameter/scanline_count":180.0,"shader_parameter/aberration":1.0}}}}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  configure_control '{"scene_path":"scenes/main.tscn","node_path":"root/PostProcess/CRT","anchors_preset":15}'
```

- `anchors_preset: 15` is "full rect" — without it the `ColorRect` is 0x0 at the top-left corner and
  the effect is invisible. `ui_report` reports that as a `zero_size` finding.
- `mouse_filter: 2` (IGNORE) keeps the rect from swallowing every click.
- **No `BackBufferCopy` node.** That is a Godot 3 habit. In 4.x, declaring
  `uniform sampler2D screen_texture : hint_screen_texture;` is what makes the engine copy the
  framebuffer for that item. (A `BackBufferCopy` is still the tool for copying a *sub-rect* for
  many small overlapping readers.)

### A 3D mesh

A mesh to hang it on, if the project has none yet — `scenes/world.tscn` with a `Character` mesh under the root:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  scene_batch '{"scene_path":"scenes/world.tscn","create_if_missing":true,"root_node_type":"Node3D","root_node_name":"World","actions":[{"type":"add_node","node_type":"MeshInstance3D","node_name":"Character","properties":{"mesh":{"__resource_type":"CapsuleMesh"}}},{"type":"add_node","node_type":"DirectionalLight3D","node_name":"Sun"},{"type":"add_node","node_type":"Camera3D","node_name":"Camera3D","properties":{"position":{"__type":"Vector3","x":0,"y":1,"z":4}}}]}'
```

```bash
cp /absolute/path/to/godot/templates/shaders/toon.gdshader /absolute/path/to/project/shaders/toon.gdshader
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  resource_batch '{"resource_path":"materials/toon.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/toon.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/albedo":{"__type":"Color","r":0.9,"g":0.75,"b":0.6,"a":1},"shader_parameter/bands":3,"shader_parameter/ambient":0.15}}]}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Character","properties":{"material_override":{"__resource":"res://materials/toon.tres"}}}'
```

| Slot | Property path | Use it when |
| --- | --- | --- |
| Whole mesh | `material_override` | one look for every surface (the usual choice) |
| One surface | `surface_material_override/0` | the mesh has several materials and only one changes — **indexed**, so pass it in `indexed_properties` |
| Second pass | `<the material>:next_pass` | outlines, rim passes drawn on top of an existing material |

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Character","indexed_properties":{"surface_material_override/0":{"__resource":"res://materials/toon.tres"}}}'
```

### A 3D outline (`next_pass`)

`next_pass` belongs to the **material**, not to the node, so it is reached through an indexed path.
Assign the base material first — setting `next_pass` on a null `material_override` fails.

```bash
cp /absolute/path/to/godot/templates/shaders/outline_3d.gdshader /absolute/path/to/project/shaders/outline_3d.gdshader
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  resource_batch '{"resource_path":"materials/outline_3d.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/outline_3d.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/outline_color":{"__type":"Color","r":0,"g":0,"b":0,"a":1},"shader_parameter/outline_width":0.02}}]}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Character","indexed_properties":{"material_override:next_pass":{"__resource":"res://materials/outline_3d.tres"}}}'
```

### Texture uniforms

A `sampler2D` uniform takes a resource reference like any other property:

```bash
cp /absolute/path/to/godot/templates/shaders/dissolve_2d.gdshader /absolute/path/to/project/shaders/dissolve_2d.gdshader
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  resource_batch '{"resource_path":"art/dissolve_noise.tres","create_if_missing":true,"resource_type":"NoiseTexture2D","actions":[{"type":"set_properties","properties":{"width":128,"height":128,"seamless":true,"noise":{"__resource_type":"FastNoiseLite","properties":{"noise_type":1,"frequency":0.035}}}}]}'
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  resource_batch '{"resource_path":"materials/dissolve.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/dissolve_2d.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/noise":{"__resource":"res://art/dissolve_noise.tres"},"shader_parameter/progress":0.0}}]}'
```

A PNG written by `draw_image` (or by hand) has **no `.import` sidecar yet**, so
`{"__resource": "res://art/noise.png"}` fails until `godot --headless --path /absolute/path/to/project --import` has
run once. A `.tres` (like the `NoiseTexture2D` above) needs no import.

### Typed values for uniforms — the one trap

`set_indexed_properties` does not coerce. A colour must be typed JSON:

| Uniform type | JSON |
| --- | --- |
| `float` / `int` / `bool` | `0.5` / `3` / `true` |
| `vec2` / `vec3` / `vec4` (plain) | `{"__type":"Vector2","x":1,"y":0}`, `{"__type":"Vector3",…}`, `{"__type":"Vector4",…}` |
| `vec4 : source_color` | `{"__type":"Color","r":1,"g":0,"b":0,"a":1}` |
| `vec4[] : source_color` | `{"__type":"PackedColorArray","values":[{"__type":"Color","r":1,"g":0,"b":0,"a":1}]}` |
| `sampler2D` | `{"__resource":"res://art/noise.png"}` |

A `"#rrggbb"` / `"#rrggbbaa"` string (or a named colour) also works wherever the uniform is declared
`source_color`: the codec reads the parameter's declared type off the `ShaderMaterial` and converts
it, and a string that is not a colour fails the op instead of being stored. That needs the `shader`
to be assigned first — before it, the material has no `shader_parameter/*` entries to read a type from.

## Set And Animate Uniforms

```gdscript
var material := sprite.material as ShaderMaterial
material.set_shader_parameter("flash_amount", 1.0)
var current: float = material.get_shader_parameter("flash_amount")
```

A **Tween** is the usual driver for a one-shot effect:

```gdscript
func flash() -> void:
    var material := (sprite.material as ShaderMaterial)
    var tween := create_tween()
    tween.tween_method(
        func(value: float) -> void: material.set_shader_parameter("flash_amount", value),
        1.0, 0.0, 0.12)
```

An **AnimationPlayer** value track drives a uniform through the node's property path
(`<node>:material:shader_parameter/<name>`), verified working on 4.7:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  build_animation '{"animation_name":"hit_flash","length":0.2,"loop_mode":"none","tracks":[{"type":"value","path":"Sprite2D:material:shader_parameter/flash_amount","update_mode":"continuous","keys":[{"time":0.0,"value":1.0},{"time":0.2,"value":0.0}]}],"scene_path":"scenes/player.tscn","player_node_path":"root/AnimationPlayer","resource_save_path":"anims/hit_flash.tres"}'
```

For a 3D mesh the path is `Character:material_override:shader_parameter/<name>`, and for an outline
`Character:material_override:next_pass:shader_parameter/<name>`.

In a **scenario**, the `set_property` step uses the same path, which is how a test sweeps a uniform
and screenshots each value without writing a script:

```json
{
  "scene_path": "scenes/player.tscn",
  "viewport_size": {"width": 128, "height": 128},
  "steps": [
    {"type": "screenshot", "path": "/tmp/flash_off.png"},
    {"type": "set_property", "node_path": "Sprite2D", "property": "material:shader_parameter/flash_amount", "value": 1.0},
    {"type": "screenshot", "path": "/tmp/flash_on.png", "expect": {"not_blank": true}}
  ],
  "assertions": []
}
```

## One Material, Many Nodes

A `ShaderMaterial` is a resource, so **every node that references it shares one set of uniform
values**. `set_shader_parameter` on a shared material flashes every enemy at once. Three ways out,
cheapest first:

1. **Per-instance uniforms** — declare the uniform `instance uniform` and set it per node. One
   material, one batch, independent values. Verified on 4.7 for **both** `canvas_item`
   (`CanvasItem.set_instance_shader_parameter`) and `spatial`
   (`GeometryInstance3D.set_instance_shader_parameter`):

   ```glsl
   instance uniform float flash_amount : hint_range(0.0, 1.0, 0.01) = 0.0;
   ```
   ```gdscript
   sprite.set_instance_shader_parameter("flash_amount", 1.0)
   mesh.set_instance_shader_parameter("albedo", Color.RED)
   ```
   Limits (both verified on 4.7 — the compiler says `The 'SCOPE_INSTANCE' qualifier is not
   supported for …`): an instance uniform can be neither a **uniform array** nor a **sampler**.
   `hint_range` and a default value are fine. The templates ship ordinary uniforms, so switching
   one over is a one-word edit.

2. **`resource_local_to_scene = true`** on the material — every *instance of the owning scene* gets
   its own copy, made when the scene is instantiated. Right for "each enemy scene owns its material".

   ```bash
   godot --headless --path /absolute/path/to/project \
     --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
     configure_node '{"scene_path":"scenes/enemy.tscn","node_path":"root/Sprite2D","properties":{"material":{"__resource_type":"ShaderMaterial","properties":{"shader":{"__resource":"res://shaders/flash.gdshader"}}}}}'
   godot --headless --path /absolute/path/to/project \
     --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
     configure_node '{"scene_path":"scenes/enemy.tscn","node_path":"root/Sprite2D","indexed_properties":{"material:resource_local_to_scene":true}}'
   ```
   (Only meaningful for a material stored **inside** that scene; a shared external `.tres` is
   duplicated per scene instance too, which is usually not what you want.)

3. **`duplicate()` at runtime** — `sprite.material = sprite.material.duplicate()` in `_ready`. One
   extra material (and one extra draw batch) per node; simplest, least efficient.

## Godot 4.7 Shading-Language Facts

Each of these was measured on `4.7.stable`, not remembered.

- **A failed shader compile is silent at draw time.** The item renders with the default material and
  nothing appears in the log. `check_project` is what surfaces it: it assigns every `.gdshader` to a
  `ShaderMaterial`, which forces the compile, and prints `SHADER ERROR` with a line number.
  Run it after every shader edit.
- **No shader warnings outside the editor.** Godot's shader warning checker (unused uniform, unused
  varying, …) is editor-only, so a headless run reports errors and nothing else. "Zero warnings"
  from a headless pass means "none were looked for".
- **`COLOR` in `fragment()` already holds `texture(TEXTURE, UV) * modulate * self_modulate`.**
  A shader that writes `COLOR = texture(TEXTURE, UV)` therefore throws the node's modulate away, and
  every `modulate` fade, tint and `AnimationPlayer` track on that node stops working. Read and write
  `COLOR` when you can.
- **`MODULATE` does not exist.** It is documented, but on 4.7 it fails to compile in `vertex()`,
  `fragment()` and `light()` alike (`Unknown identifier in expression: 'MODULATE'`) — and because of
  the silent fallback above, a shader using it *renders as if nothing was wrong*. When a shader has
  to sample `TEXTURE` at other UVs (outline, pixelate, scroll, wave), capture the tint in
  `vertex()` instead, where `COLOR` is the vertex colour = `modulate * self_modulate` with no
  texture in it:

  ```glsl
  varying vec4 tint;
  void vertex() { tint = COLOR; }
  void fragment() { COLOR = texture(TEXTURE, some_other_uv) * tint; }
  ```
- **Stage built-ins are not visible inside user functions.** `TEXTURE`, `UV`, `SCREEN_UV`… exist only
  inside `vertex`/`fragment`/`light`; a helper function has to take them as parameters. A *uniform*
  sampler can be passed as an argument, but passing the `TEXTURE` built-in makes the compiler log
  `Condition "!actions.custom_samplers.has(...)" is true` — keep those taps inline.
- **Depth reads differ by renderer.** Reconstructing view-space depth from `hint_depth_texture`
  needs `ndc.z = raw` on Forward+ and Mobile, and `ndc.z = raw * 2.0 - 1.0` on Compatibility.
  Using the wrong one does not error; it saturates, and the effect reads as "always at maximum
  depth". `water_3d.gdshader` and `force_field.gdshader` expose this as a `compatibility_depth`
  uniform, and what decides it is the renderer the engine **actually ended up running**, not the one
  the project asked for:

  ```gdscript
  material.set_shader_parameter("compatibility_depth",
      RenderingServer.get_current_rendering_method() == "gl_compatibility")
  ```

  `ProjectSettings.get_setting("rendering/renderer/rendering_method")` is the wrong source and fails on
  exactly the machines that need this flag: on a GPU-less Linux box (Ubuntu 24.04 under Xvfb, Godot 4.7,
  windowed) the engine silently falls back to OpenGL — `RenderingServer.get_current_rendering_method()`
  returns `gl_compatibility` and `get_current_rendering_driver_name()` returns `opengl3` — while the
  project setting still reads `forward_plus`. Trust the runtime method.
- **`hint_normal_roughness_texture` compiles on all three renderers but is documented as Forward+
  only** — what it returns on Mobile and Compatibility was *not* measured here, so treat it as
  unavailable there. No template uses it.
- **`hint_screen_texture` works on all three renderers** and the engine inserts the framebuffer copy
  itself; no `BackBufferCopy` node is required. Measured, not assumed: the CRT pass over a
  128x128 noise field changes 99.9 % of the frame under `forward_plus`, `mobile` and
  `gl_compatibility` alike. The whole 2D effect gate (flash, grayscale, palette swap, outline bbox,
  dissolve, pixelate blocks, scroll wrap) also produces identical pixels under all three.
- **Uniform arrays have no default value**, so an unfilled slot is zero. Always set the companion
  "how many are in use" uniform (`palette_swap.gdshader` calls it `color_count`).
- `PI`, `TAU`, `E` are built-in constants; `discard`, `const` arrays, `?:`, `for`/`break` and `out`
  parameters all work.

## Godot 3 To 4 Renames

`scripts/debug/lint_project.py` flags these in `.gdshader` files and in `.tscn`/`.tres` embedded
shader code under the category `godot3_shader` — none of the templates produce a finding. Run the
linter over the project (add `--only godot3_shader` to see just the shader rules, and
`--list-rules` to confirm the category is present in your copy of the skill):

```bash
python3 /absolute/path/to/godot/scripts/debug/lint_project.py /absolute/path/to/project --pretty
```

| Godot 3 | Godot 4 |
| --- | --- |
| `hint_color`, `hint_albedo` | `source_color` |
| `hint_black`, `hint_white` | `hint_default_black`, `hint_default_white` |
| `hint_aniso` | `hint_anisotropy` |
| `SCREEN_TEXTURE` | `uniform sampler2D screen_texture : hint_screen_texture;` |
| `DEPTH_TEXTURE` | `uniform sampler2D depth_texture : hint_depth_texture;` |
| `NORMAL_ROUGHNESS_TEXTURE` | `uniform sampler2D … : hint_normal_roughness_texture;` (Forward+ only) |
| `WORLD_MATRIX` | `MODEL_MATRIX` |
| `CAMERA_MATRIX` | `INV_VIEW_MATRIX` |
| `INV_CAMERA_MATRIX` | `VIEW_MATRIX` |
| `TRANSMISSION` | `BACKLIGHT` |
| `ALPHA_SCISSOR` | `ALPHA_SCISSOR_THRESHOLD` |
| `.shader` file extension | `.gdshader` |

Full table with every render-mode change: `references/godot3_to_4.md`.

## Performance

- **A screen read breaks batching.** Every item using `hint_screen_texture` forces a framebuffer copy
  and ends the current 2D batch. One full-screen post-process is cheap; one screen-reading material
  on fifty sprites is not.
- **`discard` disables early-Z**, which costs real time on tiled mobile GPUs. `dissolve_2d`,
  `dissolve_3d`, `outline_3d` and `progress_radial` (with `cut_out`) use it. Fine for a handful of
  objects, not for a screen full.
- **Transparency sorts per object, not per pixel.** `hologram`, `force_field` and `water_3d` blend,
  so two overlapping ones can pop as the camera moves. Splitting the mesh or accepting it are the
  only options.
- **Multi-tap shaders cost taps.** `outline_2d` is 4 or 8 extra taps per pixel, `blur` is
  `(2*samples+1)^2`, `triplanar` is 3 (6 with a normal map). For static art, bake instead:
  `draw_image`'s `outline` option and `process_image`'s `pixelate`/`quantize` operations produce the
  same look with zero runtime cost.
- **Turning an effect off**: set its amount uniform to 0 rather than clearing `material`. Swapping
  materials re-batches; a uniform write does not.

## Verify It Without Looking

Three checks, in the order they catch things. **1. Does it compile?** — the only way to find out, because
draw time will not tell you:

```bash
godot --headless --debug --ignore-error-breaks --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd check_project '{"project_path":"res://shaders"}' \
  2>&1 | python3 /absolute/path/to/godot/scripts/debug/godot_log_parser.py - --pretty
```

**2. Is the project still sane with the material attached?**

```bash
python3 /absolute/path/to/godot/scripts/debug/validate_project.py /absolute/path/to/project --pretty
```

`check_project` prints `[INFO] Compiling shader: res://…` before each file, and
`godot_log_parser.py` uses that marker to attribute an otherwise pathless `SHADER ERROR` to the
right file — so capture **stdout and stderr into one stream** (`2>&1`), not separately, or every
error is blamed on the last shader compiled.

**3. Does it actually change the picture?** The scenario below renders the effect off and on and
gates the result on numbers rather than on a look. The sprite needs a texture for there to be
anything to flash:

```bash
godot --headless --path /absolute/path/to/project \
  --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  configure_node '{"scene_path":"scenes/player.tscn","node_path":"root/Sprite2D","properties":{"texture":{"__resource":"res://art/player.png"}}}'
cat > /absolute/path/to/project/scenario.json <<'JSON'
{
  "scene_path": "scenes/player.tscn",
  "viewport_size": {"width": 256, "height": 144},
  "steps": [
    {"type": "wait_frames", "frames": 4},
    {"type": "screenshot", "path": "before.png", "expect": {"not_blank": true}},
    {"type": "set_property", "node_path": "Sprite2D", "property": "material:shader_parameter/flash_amount", "value": 1.0},
    {"type": "wait_frames", "frames": 2},
    {"type": "screenshot", "path": "after.png", "expect": {"not_blank": true, "max_diff_ratio": 0.999, "compare_to": "before.png"}}
  ],
  "assertions": []
}
JSON
```

```bash
python3 /absolute/path/to/godot/scripts/debug/run_scenario.py /absolute/path/to/project \
  /absolute/path/to/project/scenario.json --pretty
```

Then read the numbers back rather than the pixels:

<!-- replay: display -->
```bash
godot --headless --path /absolute/path/to/project --script /absolute/path/to/godot/scripts/core/dispatcher.gd \
  inspect_image '{"image_path":"after.png","ascii":true,"ascii_width":48,"expect":{"not_blank":true}}'
```

The screenshot `summary` (and `inspect_image`) gives `dominant_colors`, `mean_color`,
`unique_colors`, `content_bbox` and `opaque_ratio` — enough to prove most effects numerically:

| Effect | The number that proves it |
| --- | --- |
| `flash` at 1.0 | `dominant_colors[0].hex` is the flash colour, `content_bbox` unchanged |
| `grayscale` at 1.0 | every `dominant_colors` hex has R == G == B |
| `outline_2d` | `content_bbox` grows by `outline_width` on each side |
| `dissolve_2d` at 1.0 | `blank: true` / `opaque_ratio` 0 |
| `palette_swap` | the source colour is gone from `dominant_colors`, the target is present |
| `pixelate` | `unique_colors` drops sharply |
| `vignette` | `quadrants` shift towards the centre; corner samples darken |
| `scroll` | two captures differ, and `scroll_offset` 1.0 matches `scroll_offset` 0 exactly |
| `toon` | `unique_colors` collapses to roughly `bands` + background |
| `outline_3d` | `content_bbox` grows |
| any screen reader | the frame differs from the same scene without the rect |

`tests/test_shader_templates.py` is that loop written out in full: it builds a 16-cell scene, renders
one frame and asserts each of those numbers exactly. Copy its shape when you add a shader of your own.
