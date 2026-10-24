// force_field.gdshader — energy shield / barrier: fresnel rim, hex or scanline pattern, and a
//                         bright glow exactly where the field intersects other geometry.
//
// Goes on:   a MeshInstance3D (a SphereMesh dome, a BoxMesh wall, a CylinderMesh pillar),
//            `material_override` or `surface_material_override/0`.
// Renderers: Forward+ and Mobile out of the box. Compatibility reconstructs depth differently —
//            set `compatibility_depth` to true there. With intersection_distance at 0 the depth
//            read is skipped entirely and the shield still works on every renderer.
//
// Uniforms:
//   depth_texture  sampler2D (hint_depth_texture) filled by the engine — never set it yourself.
//   field_color    vec4 source_color default (0.25, 0.7, 1, 1)
//   base_alpha     float 0..1 default 0.12   opacity of the flat body.
//   fresnel_power  float 0.5..16 default 3.0 higher = thinner rim.
//   fresnel_boost  float 0..8 default 2.5
//   pattern_scale  float 0..80 default 18.0  cells per metre of the moving grid. 0 = no pattern.
//   pattern_speed  float -8..8 default 0.4
//   pattern_amount float 0..1 default 0.35
//   intersection_distance float 0..4 default 0.35  metres over which the contact glow fades out.
//                  0 disables the depth read.
//   intersection_boost float 0..16 default 4.0  brightness of the contact glow.
//   hit_position   vec3 default (0,0,0)   world position of the last impact (a ripple spreads from it).
//   hit_time       float 0..1 default 1.0 0 = the impact just happened, 1 = finished. Tween 0 -> 1.
//   hit_radius     float 0..20 default 3.0 how far the ripple travels.
//   compatibility_depth bool default false  true when the project runs the Compatibility renderer
//                  (its depth buffer needs ndc.z = raw * 2 - 1; Forward+/Mobile use ndc.z = raw).
//                  Ask the renderer that is actually running, not the project setting: a machine
//                  with no GPU falls back to Compatibility while the setting still says forward_plus.
//                  mat.set_shader_parameter("compatibility_depth",
//                      RenderingServer.get_current_rendering_method() == "gl_compatibility")
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/force_field.gdshader $PROJECT/shaders/force_field.gdshader
//   dispatch resource_batch '{"resource_path":"materials/shield.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/force_field.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/field_color":{"__type":"Color","r":0.25,"g":0.7,"b":1,"a":1},"shader_parameter/base_alpha":0.12,"shader_parameter/fresnel_power":3.0,"shader_parameter/fresnel_boost":2.5,"shader_parameter/pattern_scale":18.0,"shader_parameter/pattern_speed":0.4,"shader_parameter/pattern_amount":0.35,"shader_parameter/intersection_distance":0.35,"shader_parameter/intersection_boost":4.0,"shader_parameter/hit_position":{"__type":"Vector3","x":0,"y":0,"z":0},"shader_parameter/hit_time":1.0,"shader_parameter/hit_radius":3.0,"shader_parameter/compatibility_depth":false}}]}'
//   dispatch add_node '{"scene_path":"scenes/world.tscn","parent_node_path":"root","node_type":"MeshInstance3D","node_name":"Shield","properties":{"mesh":{"__resource_type":"SphereMesh","properties":{"radius":3.0,"height":6.0}},"material_override":{"__resource":"res://materials/shield.tres"}}}'
//
// Drive it:
//   GDScript:  func on_hit(world_point: Vector3) -> void:
//                  var mat := shield.material_override as ShaderMaterial
//                  mat.set_shader_parameter("hit_position", world_point)
//                  create_tween().tween_method(
//                      func(v: float) -> void: mat.set_shader_parameter("hit_time", v), 0.0, 1.0, 0.6)
//   Animation: value track on "Shield:material_override:shader_parameter/hit_time".
//
// Sharing: one shield material is fine until two shields are hit at once — hit_position/hit_time
//   are per-shield state, so give each shield its own copy (resource_local_to_scene = true on the
//   shield scene's material, or material_override.duplicate() in _ready).

shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 field_color : source_color = vec4(0.25, 0.7, 1.0, 1.0);
uniform float base_alpha : hint_range(0.0, 1.0, 0.01) = 0.12;
uniform float fresnel_power : hint_range(0.5, 16.0, 0.1) = 3.0;
uniform float fresnel_boost : hint_range(0.0, 8.0, 0.05) = 2.5;
uniform float pattern_scale : hint_range(0.0, 80.0, 0.5) = 18.0;
uniform float pattern_speed : hint_range(-8.0, 8.0, 0.05) = 0.4;
uniform float pattern_amount : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float intersection_distance : hint_range(0.0, 4.0, 0.01) = 0.35;
uniform float intersection_boost : hint_range(0.0, 16.0, 0.1) = 4.0;
uniform vec3 hit_position = vec3(0.0, 0.0, 0.0);
uniform float hit_time : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float hit_radius : hint_range(0.0, 20.0, 0.1) = 3.0;
uniform bool compatibility_depth = false;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, fresnel_power) * fresnel_boost;

	// A moving grid in world space, so the pattern does not stretch with the mesh's UVs.
	float pattern = 0.0;
	if (pattern_scale > 0.0) {
		vec2 cell = fract(world_position.xy * pattern_scale * 0.1
				+ vec2(0.0, TIME * pattern_speed)) - 0.5;
		pattern = smoothstep(0.42, 0.5, max(abs(cell.x), abs(cell.y))) * pattern_amount;
	}

	// Contact glow: how close is the geometry behind this pixel?
	float contact = 0.0;
	if (intersection_distance > 0.0) {
		float raw = texture(depth_texture, SCREEN_UV).r;
		vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, compatibility_depth ? raw * 2.0 - 1.0 : raw);
		vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		view.xyz /= view.w;
		float gap = abs(-view.z - (-VERTEX.z));
		contact = (1.0 - smoothstep(0.0, intersection_distance, gap)) * intersection_boost;
	}

	// Impact ripple: a ring expanding from hit_position, fading as hit_time reaches 1.
	float ripple = 0.0;
	if (hit_time < 1.0) {
		float travelled = hit_time * hit_radius;
		float distance_to_hit = distance(world_position, hit_position);
		ripple = (1.0 - smoothstep(0.0, hit_radius * 0.25, abs(distance_to_hit - travelled)))
				* (1.0 - hit_time) * 2.0;
	}

	float energy = base_alpha + fresnel + pattern + contact + ripple;
	ALBEDO = field_color.rgb * energy;
	ALPHA = clamp(energy, 0.0, 1.0) * field_color.a;
}
