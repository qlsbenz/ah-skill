// dissolve_2d.gdshader — noise-threshold dissolve with a glowing burn edge (deaths, teleports,
//                         pickups). progress 0 = untouched, progress 1 = gone.
//
// Goes on:   any textured CanvasItem (`material`) — Sprite2D, AnimatedSprite2D, TextureRect.
// Renderers: Forward+, Mobile, Compatibility. Uses `discard`, which disables early-Z on mobile
//            GPUs — fine for a handful of sprites, avoid it on a full screen of them.
//
// Uniforms:
//   noise      sampler2D  REQUIRED. A greyscale noise texture — a NoiseTexture2D .tres for smooth
//              blobs, or a deterministic PNG from draw_image (see below). With no texture assigned
//              the sampler reads white, so nothing dissolves until progress hits 1.
//   progress   float 0..1 default 0.0  dissolve amount.
//   edge_width float 0..0.5 default 0.08  width of the burning rim in noise units.
//   edge_color vec4 source_color default (1, 0.55, 0.1, 1)  rim colour; alpha scales the rim's opacity.
//   noise_scale vec2 default (1,1)  tiles the noise across the sprite; raise it for a finer burn.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/dissolve_2d.gdshader $PROJECT/shaders/dissolve_2d.gdshader
//   dispatch resource_batch '{"resource_path":"art/dissolve_noise.tres","create_if_missing":true,"resource_type":"NoiseTexture2D","actions":[{"type":"set_properties","properties":{"width":128,"height":128,"seamless":true,"noise":{"__resource_type":"FastNoiseLite","properties":{"noise_type":1,"frequency":0.035}}}}]}'
//   dispatch resource_batch '{"resource_path":"materials/dissolve.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/dissolve_2d.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/noise":{"__resource":"res://art/dissolve_noise.tres"},"shader_parameter/progress":0.0,"shader_parameter/edge_width":0.08,"shader_parameter/edge_color":{"__type":"Color","r":1,"g":0.55,"b":0.1,"a":1},"shader_parameter/noise_scale":{"__type":"Vector2","x":1,"y":1}}}]}'
//   dispatch configure_node '{"scene_path":"scenes/enemy.tscn","node_path":"root/Sprite2D","properties":{"material":{"__resource":"res://materials/dissolve.tres"}}}'
//   A texture uniform is set like any other resource reference: {"__resource": "res://..."}.
//   Deterministic alternative (no procedural generation, reproducible byte-for-byte):
//   dispatch draw_image '{"output_path":"art/dissolve_noise.png","width":64,"height":64,"shapes":[{"type":"noise","seed":7,"x":0,"y":0,"w":64,"h":64,"colors":["#000000","#404040","#808080","#c0c0c0","#ffffff"]}]}'
//   godot --headless --path $PROJECT --import   # a freshly written PNG has no .import sidecar yet
//
// Drive it:
//   GDScript:  (sprite.material as ShaderMaterial).set_shader_parameter("progress", t)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("progress", v), 0.0, 1.0, 0.6)
//   Animation: dispatch build_animation '{"animation_name":"die","length":0.6,"tracks":[{"type":"value","path":"Sprite2D:material:shader_parameter/progress","keys":[{"time":0.0,"value":0.0},{"time":0.6,"value":1.0}]}],"scene_path":"scenes/enemy.tscn","player_node_path":"root/AnimationPlayer"}'
//
// Sharing: every enemy that references this .tres dissolves together. Use
//   `instance uniform float progress;` + sprite.set_instance_shader_parameter("progress", v) for
//   per-enemy timing, or resource_local_to_scene = true on the enemy scene's material.

shader_type canvas_item;

uniform sampler2D noise : filter_linear, repeat_enable;
uniform float progress : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float edge_width : hint_range(0.0, 0.5, 0.005) = 0.08;
uniform vec4 edge_color : source_color = vec4(1.0, 0.55, 0.1, 1.0);
uniform vec2 noise_scale = vec2(1.0, 1.0);

void fragment() {
	float n = texture(noise, UV * noise_scale).r;
	// cut reaches 1 + edge_width at progress 1, so the burnt-away test (n <= cut - edge_width)
	// is true for every possible noise value — progress 1 always clears the sprite completely.
	float cut = progress * (1.0 + edge_width);
	if (n <= cut - edge_width) {
		discard;
	}
	if (n < cut) {
		COLOR = vec4(edge_color.rgb, COLOR.a * edge_color.a);
	}
}
