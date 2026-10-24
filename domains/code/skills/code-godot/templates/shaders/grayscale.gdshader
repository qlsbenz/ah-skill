// grayscale.gdshader — desaturate a sprite (death, disabled UI, pause overlay).
//
// Goes on:   any textured CanvasItem (`material`), or a full-rect ColorRect on a CanvasLayer
//            together with a screen read — see references/shaders.md "Full-screen post-process".
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   amount    float 0..1  default 1.0  0 = original colour, 1 = fully grey.
//   tint      vec4 source_color default (1,1,1,1)  multiplied after desaturation (sepia: (1, 0.85, 0.6, 1)).
//   weights   vec3        default (0.2126, 0.7152, 0.0722)  luminance weights (Rec.709). Use
//             (0.3333, 0.3333, 0.3334) for a flat average.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/grayscale.gdshader $PROJECT/shaders/grayscale.gdshader
//   dispatch resource_batch '{"resource_path":"materials/grayscale.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/grayscale.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/amount":1.0,"shader_parameter/tint":{"__type":"Color","r":1,"g":1,"b":1,"a":1}}}]}'
//   dispatch configure_node '{"scene_path":"scenes/player.tscn","node_path":"root/Sprite2D","properties":{"material":{"__resource":"res://materials/grayscale.tres"}}}'
//   Colour values: {"__type":"Color",...} or a "#rrggbb"/"#rrggbbaa" string; anything that is not a colour is refused, never stored as null.
//
// Drive it:
//   GDScript:  (sprite.material as ShaderMaterial).set_shader_parameter("amount", 1.0)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("amount", v), 0.0, 1.0, 0.5)
//   Animation: dispatch build_animation '{"animation_name":"fade_grey","length":0.5,"tracks":[{"type":"value","path":"Sprite2D:material:shader_parameter/amount","keys":[{"time":0.0,"value":0.0},{"time":0.5,"value":1.0}]}],"scene_path":"scenes/player.tscn","player_node_path":"root/AnimationPlayer"}'
//
// Sharing: the material is shared between every node that references it. Per-node values need
//   `instance uniform float amount;` + sprite.set_instance_shader_parameter("amount", 1.0), or
//   resource_local_to_scene = true, or material.duplicate(). See references/shaders.md.

shader_type canvas_item;

uniform float amount : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec3 weights = vec3(0.2126, 0.7152, 0.0722);

void fragment() {
	// COLOR arrives as texture * modulate * self_modulate, so nothing is lost here.
	float grey = dot(COLOR.rgb, weights);
	COLOR.rgb = mix(COLOR.rgb, vec3(grey), amount) * tint.rgb;
	COLOR.a *= tint.a;
}
