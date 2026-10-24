// hsv_shift.gdshader — recolour a sprite by rotating hue / scaling saturation / value, plus a tint.
//                       One sprite sheet, N team colours, no extra art.
//
// Goes on:   any textured CanvasItem (`material`) — Sprite2D, AnimatedSprite2D, TextureRect.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   hue_shift   float -1..1  default 0.0   full turn of the colour wheel at ±1 (0.33 ≈ red -> green).
//   saturation  float 0..2   default 1.0   0 = grey, 1 = unchanged, 2 = double.
//   value       float 0..2   default 1.0   brightness multiplier.
//   tint        vec4 source_color default (1,1,1,1)  multiplied on top (alpha included).
//   preserve_grey float 0..1 default 0.0   1 keeps near-grey pixels (outlines, eyes) out of the hue shift.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/hsv_shift.gdshader $PROJECT/shaders/hsv_shift.gdshader
//   dispatch resource_batch '{"resource_path":"materials/team_red.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/hsv_shift.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/hue_shift":0.33,"shader_parameter/saturation":1.2,"shader_parameter/value":1.0,"shader_parameter/tint":{"__type":"Color","r":1,"g":1,"b":1,"a":1},"shader_parameter/preserve_grey":1.0}}]}'
//   dispatch configure_node '{"scene_path":"scenes/enemy.tscn","node_path":"root/Sprite2D","properties":{"material":{"__resource":"res://materials/team_red.tres"}}}'
//   Colour values: {"__type":"Color",...} or a "#rrggbb"/"#rrggbbaa" string; anything that is not a colour is refused, never stored as null.
//
// Drive it:
//   GDScript:  (sprite.material as ShaderMaterial).set_shader_parameter("hue_shift", 0.5)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("hue_shift", v), 0.0, 1.0, 2.0)
//   Animation: dispatch build_animation '{"animation_name":"rainbow","length":2.0,"loop_mode":"linear","tracks":[{"type":"value","path":"Sprite2D:material:shader_parameter/hue_shift","keys":[{"time":0.0,"value":0.0},{"time":2.0,"value":1.0}]}],"scene_path":"scenes/enemy.tscn","player_node_path":"root/AnimationPlayer"}'
//
// Sharing: one material per team colour is the point here — build several .tres files from this one
//   shader. For per-node variation on a single material use `instance uniform float hue_shift;` +
//   sprite.set_instance_shader_parameter("hue_shift", 0.5). See references/shaders.md.

shader_type canvas_item;

uniform float hue_shift : hint_range(-1.0, 1.0, 0.005) = 0.0;
uniform float saturation : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float value : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float preserve_grey : hint_range(0.0, 1.0, 0.01) = 0.0;

vec3 rgb_to_hsv(vec3 c) {
	vec4 k = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, k.wz), vec4(c.gb, k.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv_to_rgb(vec3 c) {
	vec4 k = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + k.xyz) * 6.0 - k.www);
	return c.z * mix(k.xxx, clamp(p - k.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	vec3 hsv = rgb_to_hsv(COLOR.rgb);
	// A pixel with no saturation has no hue to rotate; keep outlines and highlights neutral.
	float keep = mix(1.0, smoothstep(0.0, 0.15, hsv.y), preserve_grey);
	hsv.x = fract(hsv.x + hue_shift * keep);
	hsv.y = clamp(hsv.y * mix(1.0, saturation, keep), 0.0, 1.0);
	hsv.z = clamp(hsv.z * value, 0.0, 1.0);
	COLOR = vec4(hsv_to_rgb(hsv) * tint.rgb, COLOR.a * tint.a);
}
