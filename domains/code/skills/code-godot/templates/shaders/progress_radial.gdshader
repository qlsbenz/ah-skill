// progress_radial.gdshader — the cooldown "pie" every ability icon needs: sweep a wedge around the
//                             icon, dim (or cut out) the part that has not recharged yet.
//
// Goes on:   the ability icon itself — a TextureRect / TextureButton / Sprite2D, `material` slot.
//            Put it on the icon rather than on an extra overlay node: one node, one draw call, and
//            the wedge can never drift out of alignment with the art.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   progress     float 0..1 default 1.0  1 = ready (no dimming), 0 = fully on cooldown.
//   clockwise    bool default true       direction the wedge fills.
//   start_angle  float 0..360 default 0  degrees; 0 starts at the top and goes clockwise.
//   dim_color    vec4 source_color default (0,0,0,0.65)  painted over the not-yet-recharged wedge.
//   cut_out      bool default false      true discards that wedge instead of dimming it.
//   edge_softness float 0..0.2 default 0.005  anti-aliases the sweeping edge. 0 = hard pixel edge.
//   center       vec2 default (0.5, 0.5) pivot in UV; move it for an off-centre icon.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/progress_radial.gdshader $PROJECT/shaders/progress_radial.gdshader
//   dispatch resource_batch '{"resource_path":"materials/cooldown.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/progress_radial.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/progress":1.0,"shader_parameter/clockwise":true,"shader_parameter/start_angle":0.0,"shader_parameter/dim_color":{"__type":"Color","r":0,"g":0,"b":0,"a":0.65},"shader_parameter/cut_out":false,"shader_parameter/edge_softness":0.005,"shader_parameter/center":{"__type":"Vector2","x":0.5,"y":0.5}}}]}'
//   dispatch configure_node '{"scene_path":"scenes/hud.tscn","node_path":"root/AbilityBar/DashIcon","properties":{"material":{"__resource":"res://materials/cooldown.tres"}}}'
//
// Drive it:
//   GDScript:  func _process(_delta: float) -> void:
//                  (icon.material as ShaderMaterial).set_shader_parameter("progress", 1.0 - timer.time_left / timer.wait_time)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("progress", v), 0.0, 1.0, cooldown_seconds)
//   Animation: a linear value track on "AbilityBar/DashIcon:material:shader_parameter/progress"
//              from 0 to 1 over the cooldown length.
//
// Sharing: several ability icons on one .tres would all share one cooldown. Either give each icon
//   its own material (duplicate the .tres per ability), or declare `instance uniform float progress;`
//   and call icon.set_instance_shader_parameter("progress", v) — one material, independent icons.

shader_type canvas_item;

uniform float progress : hint_range(0.0, 1.0, 0.001) = 1.0;
uniform bool clockwise = true;
uniform float start_angle : hint_range(0.0, 360.0, 1.0) = 0.0;
uniform vec4 dim_color : source_color = vec4(0.0, 0.0, 0.0, 0.65);
uniform bool cut_out = false;
uniform float edge_softness : hint_range(0.0, 0.2, 0.001) = 0.005;
uniform vec2 center = vec2(0.5, 0.5);

void fragment() {
	vec2 delta = UV - center;
	// atan(x, -y) puts 0 at the top of the icon and grows clockwise on screen, because UV.y
	// increases downwards in 2D.
	float angle = atan(delta.x, -delta.y);
	if (angle < 0.0) {
		angle += TAU;
	}
	if (!clockwise) {
		angle = TAU - angle;
	}
	angle = mod(angle - radians(start_angle) + TAU, TAU);

	float swept = angle / TAU;
	// 1 where the ability has recharged, 0 where it has not.
	float ready = 1.0 - smoothstep(progress, progress + max(edge_softness, 0.0001), swept);

	if (cut_out) {
		if (ready < 0.5) {
			discard;
		}
	} else {
		COLOR.rgb = mix(COLOR.rgb, dim_color.rgb, (1.0 - ready) * dim_color.a);
	}
}
