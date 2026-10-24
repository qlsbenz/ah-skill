// rim_fresnel.gdshader — fresnel rim light: a glow that follows the silhouette of a mesh.
//                         Selection highlight, "interactable" hint, energy shield, backlight.
//                         Keeps normal PBR shading underneath — this only adds EMISSION.
//
// Goes on:   a MeshInstance3D, in `material_override` (whole mesh) or
//            `surface_material_override/0` (one surface). Also useful as a `next_pass` on a
//            StandardMaterial3D when you want the rim on top of an existing material.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   albedo       vec4 source_color default (0.7, 0.7, 0.75, 1)  the surface colour.
//   albedo_texture sampler2D (hint_default_white) optional base texture.
//   metallic     float 0..1 default 0.0
//   roughness    float 0..1 default 0.6
//   rim_color    vec4 source_color default (0.4, 0.8, 1, 1)
//   rim_power    float 0.5..16 default 3.0  higher = thinner, tighter rim.
//   rim_strength float 0..8 default 1.5     emission multiplier; > 1 blooms with glow enabled.
//   rim_only     bool default false  true drops ALBEDO to black so only the rim is visible
//                (ghosts, holograms, a "hidden but outlined" object).
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/rim_fresnel.gdshader $PROJECT/shaders/rim_fresnel.gdshader
//   dispatch resource_batch '{"resource_path":"materials/rim.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/rim_fresnel.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/albedo":{"__type":"Color","r":0.7,"g":0.7,"b":0.75,"a":1},"shader_parameter/metallic":0.0,"shader_parameter/roughness":0.6,"shader_parameter/rim_color":{"__type":"Color","r":0.4,"g":0.8,"b":1,"a":1},"shader_parameter/rim_power":3.0,"shader_parameter/rim_strength":1.5,"shader_parameter/rim_only":false}}]}'
//   dispatch configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Chest","properties":{"material_override":{"__resource":"res://materials/rim.tres"}}}'
//   As a second pass over an existing StandardMaterial3D (rim_only = true so the base shows through):
//   dispatch configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Chest","indexed_properties":{"material_override:next_pass":{"__resource":"res://materials/rim.tres"}}}'
//
// Drive it:
//   GDScript:  (mesh.material_override as ShaderMaterial).set_shader_parameter("rim_strength", 3.0)
//   Tween:     create_tween().set_loops().tween_method(func(v: float) -> void: mat.set_shader_parameter("rim_strength", v), 0.5, 3.0, 0.6)
//   Animation: value track on "Chest:material_override:shader_parameter/rim_strength".
//
// Sharing: one "highlight" material for every interactable is the usual setup. Per-mesh values:
//   `instance uniform float rim_strength;` + mesh.set_instance_shader_parameter("rim_strength", 3.0).
//
// Note: the rim is brightest where the surface faces away from the camera, so it needs curvature.
//   A flat quad or a cube face shows almost no rim — that is the maths, not a bug.

shader_type spatial;

uniform vec4 albedo : source_color = vec4(0.7, 0.7, 0.75, 1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap;
uniform float metallic : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.6;
uniform vec4 rim_color : source_color = vec4(0.4, 0.8, 1.0, 1.0);
uniform float rim_power : hint_range(0.5, 16.0, 0.1) = 3.0;
uniform float rim_strength : hint_range(0.0, 8.0, 0.05) = 1.5;
uniform bool rim_only = false;

void fragment() {
	vec4 base = albedo * texture(albedo_texture, UV);
	ALBEDO = rim_only ? vec3(0.0) : base.rgb;
	ALPHA = base.a;
	METALLIC = metallic;
	ROUGHNESS = roughness;

	// NORMAL and VIEW are both in view space here, so no matrices are needed.
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, rim_power);
	EMISSION = rim_color.rgb * fresnel * rim_strength;
}
