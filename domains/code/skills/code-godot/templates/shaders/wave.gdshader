// wave.gdshader — sway a sprite sideways in a sine wave, anchored at one edge (grass, flags,
//                  banners, trees, underwater plants, a wobbling "hurt" sprite).
//
// Goes on:   any textured CanvasItem (`material`) — Sprite2D, AnimatedSprite2D, TextureRect.
//            This displaces UVs in the fragment stage, so it works on a plain 4-vertex sprite
//            quad; a `vertex()` version would only move the four corners.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   amplitude   float 0..64 default 3.0   maximum sideways travel in TEXTURE pixels.
//   frequency   float 0..8  default 1.0   sine periods along the sprite's height.
//   speed       float 0..20 default 2.0   radians per second.
//   phase       float 0..6.2832 default 0 per-instance offset so neighbouring plants desync.
//   anchor      float 0..1  default 1.0   the UV.y that does not move (1 = rooted at the bottom,
//               0 = hanging from the top, 0.5 = pinned in the middle).
//   bend_power  float 0.1..4 default 1.5  how sharply the sway ramps away from the anchor.
//   horizontal  bool default true  false sways up/down instead of left/right.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/wave.gdshader $PROJECT/shaders/wave.gdshader
//   dispatch resource_batch '{"resource_path":"materials/grass_sway.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/wave.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/amplitude":3.0,"shader_parameter/frequency":1.0,"shader_parameter/speed":2.0,"shader_parameter/phase":0.0,"shader_parameter/anchor":1.0,"shader_parameter/bend_power":1.5,"shader_parameter/horizontal":true}}]}'
//   dispatch configure_node '{"scene_path":"scenes/level.tscn","node_path":"root/Grass","properties":{"material":{"__resource":"res://materials/grass_sway.tres"}}}'
//
// Drive it:
//   GDScript:  mat.set_shader_parameter("amplitude", 3.0 + wind_strength * 6.0)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("amplitude", v), 0.0, 8.0, 1.0)
//   Animation: value track on "Grass:material:shader_parameter/amplitude" for a gust.
//
// Sharing: a field of grass on one material sways in lockstep, which looks wrong. Fix it with
//   `instance uniform float phase;` and grass.set_instance_shader_parameter("phase", randf() * TAU) —
//   one material, one draw batch, every blade out of step.
//
// PADDING: the sway samples outside the texture rect, and there is nothing there. Give the art
//   `amplitude` transparent pixels of margin on both sides:
//   dispatch process_image '{"input_path":"art/grass.png","output_path":"art/grass.png","operations":[{"type":"pad","padding":4}]}'

shader_type canvas_item;

uniform float amplitude : hint_range(0.0, 64.0, 0.5) = 3.0;
uniform float frequency : hint_range(0.0, 8.0, 0.1) = 1.0;
uniform float speed : hint_range(0.0, 20.0, 0.1) = 2.0;
uniform float phase : hint_range(0.0, 6.2832, 0.01) = 0.0;
uniform float anchor : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float bend_power : hint_range(0.1, 4.0, 0.1) = 1.5;
uniform bool horizontal = true;

// Captures the node's modulate * self_modulate before the engine multiplies the texture in.
// Every tap below reads the raw texture, so the tint has to be re-applied by hand at the end.
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	// Distance from the anchored edge, 0 at the anchor and 1 at the far end.
	float along = horizontal ? UV.y : UV.x;
	float reach = pow(clamp(abs(along - anchor), 0.0, 1.0), bend_power);
	float wave = sin(TIME * speed + along * frequency * TAU + phase) * reach;
	vec2 offset = (horizontal ? vec2(1.0, 0.0) : vec2(0.0, 1.0))
			* wave * amplitude * TEXTURE_PIXEL_SIZE;

	vec2 uv = UV + offset;
	vec4 base = vec4(0.0);
	// Nothing exists outside the sprite's own rect; sampling there would smear the edge texel.
	if (uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0) {
		base = texture(TEXTURE, uv);
	}

	// `tint` carries the node's modulate/self_modulate, which a texture() tap cannot see.
	COLOR = base * tint;
}
