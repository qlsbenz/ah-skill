// vignette.gdshader — darken (or tint) the edges of the screen. Pure overlay: it draws its own
//                      colour with a radial alpha ramp, so it needs no screen read and costs almost
//                      nothing. Also good as a damage flash (red) or a focus mask.
//
// Goes on:   a ColorRect that covers the whole viewport, inside a CanvasLayer so it is unaffected
//            by the camera:
//            CanvasLayer (layer = 100) > ColorRect (anchors preset 15 "full rect",
//            mouse_filter = 2 IGNORE so it never eats clicks), `material` slot.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   vignette_color vec4 source_color default (0,0,0,1)  colour painted at the edges.
//   inner_radius   float 0..1.5 default 0.45  distance from `center` where the fade starts.
//   outer_radius   float 0..1.5 default 0.85  distance where it reaches full strength.
//   strength       float 0..1   default 1.0   master opacity — tween this.
//   center         vec2 default (0.5, 0.5)    in UV space; move it to frame the player.
//   aspect         float 0.1..4 default 1.0   viewport width / height; keeps the ring circular.
//                  1.0 leaves it elliptical (matching the rect), which is usually what you want.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/vignette.gdshader $PROJECT/shaders/vignette.gdshader
//   dispatch add_node '{"scene_path":"scenes/main.tscn","parent_node_path":"root","node_type":"CanvasLayer","node_name":"Overlay","properties":{"layer":100}}'
//   dispatch add_node '{"scene_path":"scenes/main.tscn","parent_node_path":"root/Overlay","node_type":"ColorRect","node_name":"Vignette","properties":{"mouse_filter":2,"color":{"__type":"Color","r":1,"g":1,"b":1,"a":1},"material":{"__resource_type":"ShaderMaterial","properties":{"shader":{"__resource":"res://shaders/vignette.gdshader"},"shader_parameter/vignette_color":{"__type":"Color","r":0,"g":0,"b":0,"a":1},"shader_parameter/inner_radius":0.45,"shader_parameter/outer_radius":0.85,"shader_parameter/strength":1.0,"shader_parameter/center":{"__type":"Vector2","x":0.5,"y":0.5},"shader_parameter/aspect":1.0}}}}'
//   dispatch configure_control '{"scene_path":"scenes/main.tscn","node_path":"root/Overlay/Vignette","anchors_preset":15}'
//   In an inline material the `shader` key must come FIRST — a shader_parameter/* key before it is
//   rejected with "Property does not exist" because the uniform list comes from the shader.
//
// Drive it:
//   GDScript:  (%Vignette.material as ShaderMaterial).set_shader_parameter("strength", 0.8)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("strength", v), 0.0, 1.0, 0.3)
//   Animation: dispatch build_animation '{"animation_name":"low_health","length":1.0,"loop_mode":"pingpong","tracks":[{"type":"value","path":"Overlay/Vignette:material:shader_parameter/strength","keys":[{"time":0.0,"value":0.2},{"time":1.0,"value":0.8}]}],"scene_path":"scenes/main.tscn","player_node_path":"root/AnimationPlayer"}'
//
// Sharing: there is normally one vignette in a game, so an inline (sub-resource) material is the
//   right choice — it is saved inside the scene and needs no separate .tres.

shader_type canvas_item;

uniform vec4 vignette_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float inner_radius : hint_range(0.0, 1.5, 0.01) = 0.45;
uniform float outer_radius : hint_range(0.0, 1.5, 0.01) = 0.85;
uniform float strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform vec2 center = vec2(0.5, 0.5);
uniform float aspect : hint_range(0.1, 4.0, 0.01) = 1.0;

void fragment() {
	vec2 offset = (UV - center) * vec2(aspect, 1.0);
	// max() keeps the ramp sane if the two radii are set the wrong way round.
	float fade = smoothstep(inner_radius, max(outer_radius, inner_radius + 0.001), length(offset));
	COLOR = vec4(vignette_color.rgb, vignette_color.a * fade * strength * COLOR.a);
}
