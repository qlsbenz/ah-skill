// water_3d.gdshader — a water surface: procedural wave normals (no textures needed), depth-based
//                      shallow/deep tint, a shore foam line and fresnel transparency.
//
// Goes on:   a MeshInstance3D holding a PlaneMesh (give it subdivision only if you want real
//            displacement later — the waves here are normals, so 1 quad is enough),
//            `material_override` or `surface_material_override/0`.
// Renderers: Forward+ and Mobile out of the box. Compatibility reconstructs depth differently —
//            set `compatibility_depth` to true there (see below). Without the depth read the
//            surface still works: set depth_fade_distance to 0 and it becomes a flat tinted sheet.
//
// Uniforms:
//   depth_texture  sampler2D (hint_depth_texture) filled by the engine — never set it yourself.
//   shallow_color  vec4 source_color default (0.25, 0.65, 0.8, 0.45)  colour over shallow ground.
//   deep_color     vec4 source_color default (0.02, 0.12, 0.28, 0.92) colour over deep ground.
//   depth_fade_distance float 0..40 default 3.0  metres of water depth that reach deep_color.
//                  0 disables the depth read entirely (and with it the foam line).
//   foam_distance  float 0..4 default 0.25  width of the white line where the water meets geometry.
//   foam_color     vec4 source_color default (1,1,1,0.9)
//   wave_scale     float 0.05..20 default 2.5  waves per metre.
//   wave_speed     float 0..8 default 0.6
//   wave_strength  float 0..2 default 0.35  how much the normals tilt.
//   water_roughness float 0..1 default 0.06  low = mirror-like highlights.
//   compatibility_depth bool default false  MUST be true when the project runs the Compatibility
//                  renderer: its depth buffer needs ndc.z = raw * 2 - 1, while Forward+/Mobile use
//                  ndc.z = raw. Verified both ways on 4.7; get it wrong and the water reads as
//                  uniformly deep. Set it from code, from the renderer that is actually running —
//                  NOT from the project setting, which still says forward_plus on a machine that
//                  had to fall back (no GPU: a container, a CI runner, a box you SSH into):
//                  mat.set_shader_parameter("compatibility_depth",
//                      RenderingServer.get_current_rendering_method() == "gl_compatibility")
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/water_3d.gdshader $PROJECT/shaders/water_3d.gdshader
//   dispatch resource_batch '{"resource_path":"materials/water.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/water_3d.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/shallow_color":{"__type":"Color","r":0.25,"g":0.65,"b":0.8,"a":0.45},"shader_parameter/deep_color":{"__type":"Color","r":0.02,"g":0.12,"b":0.28,"a":0.92},"shader_parameter/depth_fade_distance":3.0,"shader_parameter/foam_distance":0.25,"shader_parameter/foam_color":{"__type":"Color","r":1,"g":1,"b":1,"a":0.9},"shader_parameter/wave_scale":2.5,"shader_parameter/wave_speed":0.6,"shader_parameter/wave_strength":0.35,"shader_parameter/water_roughness":0.06,"shader_parameter/compatibility_depth":false}}]}'
//   dispatch add_node '{"scene_path":"scenes/world.tscn","parent_node_path":"root","node_type":"MeshInstance3D","node_name":"Water","properties":{"mesh":{"__resource_type":"PlaneMesh","properties":{"size":{"__type":"Vector2","x":40,"y":40}}},"material_override":{"__resource":"res://materials/water.tres"}}}'
//
// Drive it:
//   GDScript:  (water.material_override as ShaderMaterial).set_shader_parameter("wave_strength", 0.8)
//   Tween:     tween wave_strength up during a storm.
//   Animation: value track on "Water:material_override:shader_parameter/wave_strength".
//
// Sharing: one water material per lake/ocean; they all animate off TIME.
//
// Limits (on purpose): no real reflections and no refraction of what is under the surface. Both
//   need a second camera (a planar reflection SubViewport) or a screen read that fights with
//   transparency sorting. For a stylised game the depth tint plus fresnel is usually enough.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform vec4 shallow_color : source_color = vec4(0.25, 0.65, 0.8, 0.45);
uniform vec4 deep_color : source_color = vec4(0.02, 0.12, 0.28, 0.92);
uniform float depth_fade_distance : hint_range(0.0, 40.0, 0.05) = 3.0;
uniform float foam_distance : hint_range(0.0, 4.0, 0.01) = 0.25;
uniform vec4 foam_color : source_color = vec4(1.0, 1.0, 1.0, 0.9);
uniform float wave_scale : hint_range(0.05, 20.0, 0.05) = 2.5;
uniform float wave_speed : hint_range(0.0, 8.0, 0.05) = 0.6;
uniform float wave_strength : hint_range(0.0, 2.0, 0.01) = 0.35;
uniform float water_roughness : hint_range(0.0, 1.0, 0.005) = 0.06;
uniform bool compatibility_depth = false;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// Height field of two crossing wave trains; the analytic gradient becomes the normal.
vec3 wave_normal(vec2 position, float time, float scale, float strength) {
	vec2 a = position * scale + vec2(time, time * 0.7);
	vec2 b = position * scale * 1.7 + vec2(-time * 0.6, time * 1.3);
	float dx = cos(a.x) * 0.6 + cos(b.x + b.y) * 0.4;
	float dy = cos(a.y * 0.8) * 0.6 + cos(b.x + b.y) * 0.4;
	// Tangent-space normal: +Z is "straight out of the surface".
	return normalize(vec3(-dx * strength, -dy * strength, 1.0));
}

void fragment() {
	NORMAL_MAP = wave_normal(world_position.xz, TIME * wave_speed, wave_scale, wave_strength)
			* 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;

	float water_depth = 0.0;
	if (depth_fade_distance > 0.0) {
		float raw = texture(depth_texture, SCREEN_UV).r;
		// Compatibility's depth buffer is OpenGL-style ([-1, 1] after the NDC remap); Forward+ and
		// Mobile hand back a [0, 1] value that goes into the NDC vector unchanged.
		vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, compatibility_depth ? raw * 2.0 - 1.0 : raw);
		vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		view.xyz /= view.w;
		// Both distances are along the camera's -Z, so their difference is the water's thickness.
		water_depth = max(-view.z - (-VERTEX.z), 0.0);
	}

	float deepness = depth_fade_distance > 0.0
			? clamp(water_depth / depth_fade_distance, 0.0, 1.0)
			: 1.0;
	vec3 body = mix(shallow_color.rgb, deep_color.rgb, deepness);
	float body_alpha = mix(shallow_color.a, deep_color.a, deepness);

	// Foam where the surface nearly touches the ground behind it.
	float foam = 0.0;
	if (depth_fade_distance > 0.0 && foam_distance > 0.0) {
		foam = 1.0 - smoothstep(0.0, foam_distance, water_depth);
		// Ride the waves so the shoreline is not a clean geometric line.
		foam *= 0.6 + 0.4 * sin(world_position.x * wave_scale * 2.0 + TIME * wave_speed * 2.0);
		foam = clamp(foam, 0.0, 1.0);
	}

	// Grazing angles are more reflective, so the surface reads as more solid at the horizon.
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, 4.0);

	ALBEDO = mix(body, foam_color.rgb, foam * foam_color.a);
	ALPHA = clamp(mix(body_alpha, 1.0, max(fresnel, foam * foam_color.a)), 0.0, 1.0);
	ROUGHNESS = water_roughness;
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
