// scroll.gdshader — slide a texture's UVs (parallax backgrounds, conveyor belts, waterfalls,
//                    lava, starfields). Wraps seamlessly and can be driven by time or by a value.
//
// Goes on:   any textured CanvasItem (`material`) — Sprite2D, TextureRect, ParallaxLayer child,
//            or a full-rect TextureRect with `stretch_mode = 1` (tile).
//            The texture must tile: use a seamless image (draw_image `tile_check` proves it).
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   scroll_speed  vec2  default (0.1, 0)  UV units per second while `use_time` is on.
//   scroll_offset vec2  default (0, 0)    a fixed offset added on top — drive this from a script
//                 (camera position / conveyor distance) for deterministic, frame-rate-free motion.
//   tiling        vec2  default (1, 1)    repeats of the texture across the node.
//   use_time      bool  default true      false freezes time and leaves scroll_offset in charge.
//                 Turn it off in tests: TIME is wall-clock and makes screenshots non-deterministic.
//   fade_edges    float 0..0.5 default 0  fades the top/bottom edge, for a horizon or a fog band.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/scroll.gdshader $PROJECT/shaders/scroll.gdshader
//   dispatch resource_batch '{"resource_path":"materials/scroll_clouds.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/scroll.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/scroll_speed":{"__type":"Vector2","x":0.05,"y":0},"shader_parameter/scroll_offset":{"__type":"Vector2","x":0,"y":0},"shader_parameter/tiling":{"__type":"Vector2","x":2,"y":1},"shader_parameter/use_time":true,"shader_parameter/fade_edges":0.0}}]}'
//   dispatch configure_node '{"scene_path":"scenes/level.tscn","node_path":"root/Background","properties":{"material":{"__resource":"res://materials/scroll_clouds.tres"}}}'
//
// Drive it:
//   GDScript:  mat.set_shader_parameter("scroll_offset", Vector2(camera.global_position.x * 0.001, 0.0))
//   Tween:     rarely needed — leave use_time on for endless motion.
//   Animation: a linear-looping value track on "Background:material:shader_parameter/scroll_offset"
//              from (0,0) to (1,0) scrolls exactly one full tile per loop (fract() makes it seamless).
//
// Sharing: parallax layers each want their own speed, so build one .tres per layer. For many
//   identical belts with different phases, `instance uniform vec2 scroll_offset;` +
//   node.set_instance_shader_parameter("scroll_offset", Vector2(...)) keeps it to one material.

shader_type canvas_item;

uniform vec2 scroll_speed = vec2(0.1, 0.0);
uniform vec2 scroll_offset = vec2(0.0, 0.0);
uniform vec2 tiling = vec2(1.0, 1.0);
uniform bool use_time = true;
uniform float fade_edges : hint_range(0.0, 0.5, 0.01) = 0.0;

// Captures the node's modulate * self_modulate before the engine multiplies the texture in.
// Every tap below reads the raw texture, so the tint has to be re-applied by hand at the end.
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	vec2 moved = UV * tiling + scroll_offset + scroll_speed * (use_time ? TIME : 0.0);
	// fract() wraps without relying on the node's texture_repeat setting, so a shifted offset of
	// exactly 1.0 lands back on the original image.
	vec4 base = texture(TEXTURE, fract(moved));

	if (fade_edges > 0.0) {
		float top = smoothstep(0.0, fade_edges, UV.y);
		float bottom = smoothstep(0.0, fade_edges, 1.0 - UV.y);
		base.a *= top * bottom;
	}

	// `tint` carries the node's modulate/self_modulate, which a texture() tap cannot see.
	COLOR = base * tint;
}
