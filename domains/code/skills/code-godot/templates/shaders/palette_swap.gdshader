// palette_swap.gdshader — map up to 8 source colours to 8 targets (team colours, damage
//                          palettes, day/night recolours) without a second sprite sheet.
//
// Goes on:   any textured CanvasItem (`material`) — Sprite2D, AnimatedSprite2D, TextureRect.
//            Best on pixel art with a small, exact palette and nearest filtering.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   source_colors vec4[8] source_color  the colours to look for (index 0..color_count-1).
//   target_colors vec4[8] source_color  what each one becomes; alpha multiplies the pixel's alpha.
//   color_count   int 0..8  default 0   how many array slots are in use. 0 = shader does nothing.
//   tolerance     float 0..1 default 0.02  per-channel match distance; raise it for filtered/AA art.
//   swap_alpha    bool default false     true also replaces the pixel's alpha with the target's.
//
// Array uniforms have no default value in Godot's shading language, so an unset slot is
// transparent black — always set color_count and fill exactly that many slots.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/palette_swap.gdshader $PROJECT/shaders/palette_swap.gdshader
//   dispatch resource_batch '{"resource_path":"materials/team_blue.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/palette_swap.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/color_count":2,"shader_parameter/tolerance":0.02,"shader_parameter/source_colors":{"__type":"PackedColorArray","values":[{"__type":"Color","r":1,"g":0,"b":0,"a":1},{"__type":"Color","r":0.5,"g":0,"b":0,"a":1}]},"shader_parameter/target_colors":{"__type":"PackedColorArray","values":[{"__type":"Color","r":0,"g":0.4,"b":1,"a":1},{"__type":"Color","r":0,"g":0.2,"b":0.5,"a":1}]}}}]}'
//   dispatch configure_node '{"scene_path":"scenes/enemy.tscn","node_path":"root/Sprite2D","properties":{"material":{"__resource":"res://materials/team_blue.tres"}}}'
//   A vec4[] uniform takes a PackedColorArray; a shorter array leaves the remaining slots at zero.
//   Read the sprite's real palette first: inspect_image '{"image_path":"art/enemy.png","max_unique":64}'
//   lists dominant_colors as hex, which is exactly what goes into source_colors.
//
// Drive it:
//   GDScript:  mat.set_shader_parameter("target_colors", PackedColorArray([Color.RED, Color.DARK_RED]))
//   Tween:     swap palettes on a step, not continuously — a colour match is binary, so tweening
//              tolerance or color_count looks like popping. Tween `tint` in hsv_shift.gdshader instead.
//   Animation: discrete value track on "Sprite2D:material:shader_parameter/color_count" to blink a swap.
//
// Sharing: build one .tres per palette and assign the right one per node — that is cheaper than
//   per-instance arrays (instance uniforms cannot be arrays). resource_local_to_scene = true or
//   material.duplicate() when a single node must diverge at runtime.

shader_type canvas_item;

const int MAX_COLORS = 8;

uniform vec4 source_colors[MAX_COLORS] : source_color;
uniform vec4 target_colors[MAX_COLORS] : source_color;
uniform int color_count : hint_range(0, 8) = 0;
uniform float tolerance : hint_range(0.0, 1.0, 0.005) = 0.02;
uniform bool swap_alpha = false;

void fragment() {
	// COLOR carries texture * modulate; compare the un-modulated art by dividing it back out only
	// if you need that — for the usual modulate = white case this compares the texture itself.
	vec4 base = COLOR;
	for (int i = 0; i < MAX_COLORS; i++) {
		if (i >= color_count) {
			break;
		}
		vec3 delta = abs(base.rgb - source_colors[i].rgb);
		if (max(max(delta.r, delta.g), delta.b) <= tolerance) {
			COLOR.rgb = target_colors[i].rgb;
			COLOR.a = swap_alpha ? target_colors[i].a : base.a * target_colors[i].a;
			break;
		}
	}
}
