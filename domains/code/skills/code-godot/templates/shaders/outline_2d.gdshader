// outline_2d.gdshader — alpha-neighbour outline around a sprite (selection, hover, enemy
//                        highlight). Outer or inner, 4- or 8-neighbour.
//
// Goes on:   any textured CanvasItem (`material`) — Sprite2D, AnimatedSprite2D, TextureRect.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   outline_color vec4 source_color default (1,1,1,1)  the ring colour.
//   outline_width float 0..16 default 1.0  thickness in TEXTURE pixels (not screen pixels — the
//                 sprite's scale multiplies it on screen).
//   inside        bool default false  false = ring grows outwards, true = ring eats into the sprite.
//   diagonal      bool default true   8 neighbours (round corners) instead of 4 (cross-shaped).
//   alpha_cutoff  float 0..1 default 0.1  a neighbour counts as solid above this alpha.
//
// PADDING — the one thing that goes wrong: a sprite's quad is exactly its texture rect, so an
//   outer outline has nowhere to draw where the art touches the texture edge. Give the art at
//   least `outline_width` transparent pixels of margin:
//     dispatch process_image '{"input_path":"art/hero.png","output_path":"art/hero.png","operations":[{"type":"pad","padding":2}]}'
//   For a sprite sheet / AtlasTexture / region_enabled Sprite2D the neighbour taps read whatever
//   sits next to the frame in the atlas, so pad every frame (draw_image `separation`) or give the
//   outlined sprite its own texture.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/outline_2d.gdshader $PROJECT/shaders/outline_2d.gdshader
//   dispatch resource_batch '{"resource_path":"materials/outline.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/outline_2d.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/outline_color":{"__type":"Color","r":1,"g":1,"b":1,"a":1},"shader_parameter/outline_width":1.0,"shader_parameter/inside":false,"shader_parameter/diagonal":true,"shader_parameter/alpha_cutoff":0.1}}]}'
//   dispatch configure_node '{"scene_path":"scenes/enemy.tscn","node_path":"root/Sprite2D","properties":{"material":{"__resource":"res://materials/outline.tres"}}}'
//   Colour values: {"__type":"Color",...} or a "#rrggbb"/"#rrggbbaa" string; anything that is not a colour is refused, never stored as null.
//
// Drive it:
//   GDScript:  (sprite.material as ShaderMaterial).set_shader_parameter("outline_width", 2.0)
//              Turn it off with 0.0 rather than swapping materials — that keeps batching stable.
//   Tween:     create_tween().set_loops().tween_method(func(v: float) -> void: mat.set_shader_parameter("outline_width", v), 1.0, 3.0, 0.4)
//   Animation: dispatch build_animation '{"animation_name":"highlight","length":0.8,"loop_mode":"pingpong","tracks":[{"type":"value","path":"Sprite2D:material:shader_parameter/outline_width","keys":[{"time":0.0,"value":1.0},{"time":0.8,"value":3.0}]}],"scene_path":"scenes/enemy.tscn","player_node_path":"root/AnimationPlayer"}'
//
// Sharing: one material outlines every node that uses it. Per-node highlighting is the common case,
//   so either declare `instance uniform float outline_width;` and call
//   sprite.set_instance_shader_parameter("outline_width", 2.0), or set resource_local_to_scene = true.
//
// Cost: 4 or 8 extra texture taps per pixel. Fine for a few dozen sprites; for a whole screen of
//   outlined tiles, bake the outline into the art with draw_image's `outline` option instead.

shader_type canvas_item;

uniform vec4 outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float outline_width : hint_range(0.0, 16.0, 0.5) = 1.0;
uniform bool inside = false;
uniform bool diagonal = true;
uniform float alpha_cutoff : hint_range(0.0, 1.0, 0.01) = 0.1;

// The first four are the cross, the last four the diagonals.
const vec2 NEIGHBOURS[8] = {
	vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0),
	vec2(1.0, 1.0), vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0)
};

// Captures the node's modulate * self_modulate before the engine multiplies the texture in.
// Every tap below reads the raw texture, so the tint has to be re-applied by hand at the end.
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	vec2 step_uv = TEXTURE_PIXEL_SIZE * outline_width;
	vec4 base = texture(TEXTURE, UV);
	float here = base.a;

	float most = 0.0;
	float least = 1.0;
	int taps = diagonal ? 8 : 4;
	// The taps stay inline: handing the TEXTURE built-in to a user function makes the 4.7 shader
	// compiler log `Condition "!actions.custom_samplers.has(...)" is true` (a uniform sampler is
	// fine as an argument, TEXTURE is not).
	for (int i = 0; i < 8; i++) {
		if (i >= taps) {
			break;
		}
		vec2 uv = UV + NEIGHBOURS[i] * step_uv;
		// Outside the sprite's own UV rect there is nothing to sample: Godot clamps to the edge
		// texel (or repeats), which would smear the border pixel's alpha out into a fake outline.
		float a = (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0)
				? 0.0
				: texture(TEXTURE, uv).a;
		most = max(most, a);
		least = min(least, a);
	}

	float solid = step(alpha_cutoff, here);
	// Outer: an empty pixel next to a solid one. Inner: a solid pixel next to an empty one.
	// outline_width 0 makes every tap land on this pixel, so both terms collapse to zero.
	float ring = inside
		? solid * (1.0 - step(alpha_cutoff, least))
		: (1.0 - solid) * step(alpha_cutoff, most);
	// `tint` carries the node's modulate/self_modulate, which the neighbour taps above cannot see
	// (a texture() tap is raw art). MODULATE does not exist in 4.7 — see references/shaders.md.
	COLOR = mix(base, outline_color, ring) * tint;
}
