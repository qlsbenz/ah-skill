// dissolve_3d.gdshader — the 3D twin of dissolve_2d: burn a mesh away along a noise threshold with
//                         a glowing edge. Deaths, teleport-ins, materialising loot.
//
// Goes on:   a MeshInstance3D, in `material_override` (whole mesh) or `surface_material_override/0`.
// Renderers: Forward+, Mobile, Compatibility. Uses `discard`, so the material is treated as
//            alpha-scissor geometry: it writes depth but breaks early-Z on tiled mobile GPUs.
//
// Uniforms:
//   albedo        vec4 source_color default (0.8, 0.8, 0.85, 1)
//   albedo_texture sampler2D (hint_default_white) optional base texture.
//   noise         sampler2D REQUIRED for a good pattern — NoiseTexture2D or a PNG. Unassigned it
//                 reads white, so nothing dissolves until progress reaches 1.
//   progress      float 0..1 default 0.0  0 = solid, 1 = fully gone.
//   edge_width    float 0..0.5 default 0.06  width of the glowing rim in noise units.
//   edge_color    vec4 source_color default (1, 0.5, 0.1, 1)
//   edge_energy   float 0..16 default 4.0   EMISSION multiplier on the rim; > 1 blooms with glow.
//   triplanar     bool default false  sample the noise from world position instead of UV — the fix
//                 for a mesh with no useful UVs (CSG output, primitives, imported props).
//   noise_scale   float 0.01..8 default 1.0  tiling of the noise (UV) / world units per tile (triplanar).
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/dissolve_3d.gdshader $PROJECT/shaders/dissolve_3d.gdshader
//   dispatch resource_batch '{"resource_path":"art/dissolve_noise.tres","create_if_missing":true,"resource_type":"NoiseTexture2D","actions":[{"type":"set_properties","properties":{"width":128,"height":128,"seamless":true,"noise":{"__resource_type":"FastNoiseLite","properties":{"noise_type":1,"frequency":0.035}}}}]}'
//   dispatch resource_batch '{"resource_path":"materials/dissolve_3d.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/dissolve_3d.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/albedo":{"__type":"Color","r":0.8,"g":0.8,"b":0.85,"a":1},"shader_parameter/noise":{"__resource":"res://art/dissolve_noise.tres"},"shader_parameter/progress":0.0,"shader_parameter/edge_width":0.06,"shader_parameter/edge_color":{"__type":"Color","r":1,"g":0.5,"b":0.1,"a":1},"shader_parameter/edge_energy":4.0,"shader_parameter/triplanar":false,"shader_parameter/noise_scale":1.0}}]}'
//   dispatch configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Enemy","properties":{"material_override":{"__resource":"res://materials/dissolve_3d.tres"}}}'
//
// Drive it:
//   GDScript:  (mesh.material_override as ShaderMaterial).set_shader_parameter("progress", t)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("progress", v), 0.0, 1.0, 0.8)
//   Animation: dispatch build_animation '{"animation_name":"vanish","length":0.8,"tracks":[{"type":"value","path":"Enemy:material_override:shader_parameter/progress","keys":[{"time":0.0,"value":0.0},{"time":0.8,"value":1.0}]}],"scene_path":"scenes/world.tscn","player_node_path":"root/AnimationPlayer"}'
//
// Sharing: enemies on one shared material dissolve together. Use
//   `instance uniform float progress;` + mesh.set_instance_shader_parameter("progress", v), or
//   resource_local_to_scene = true on the material inside the enemy scene.

shader_type spatial;

uniform vec4 albedo : source_color = vec4(0.8, 0.8, 0.85, 1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap;
uniform sampler2D noise : filter_linear, repeat_enable;
uniform float progress : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float edge_width : hint_range(0.0, 0.5, 0.005) = 0.06;
uniform vec4 edge_color : source_color = vec4(1.0, 0.5, 0.1, 1.0);
uniform float edge_energy : hint_range(0.0, 16.0, 0.1) = 4.0;
uniform bool triplanar = false;
uniform float noise_scale : hint_range(0.01, 8.0, 0.01) = 1.0;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float noise_value(sampler2D tex, vec2 uv, vec3 world, bool use_world, float scale) {
	if (!use_world) {
		return texture(tex, uv * scale).r;
	}
	// Cheap two-plane blend: enough for a dissolve mask, and it needs no UVs at all.
	vec3 p = world * scale * 0.25;
	return mix(texture(tex, p.xz).r, texture(tex, p.xy).r, 0.5);
}

void fragment() {
	float n = noise_value(noise, UV, world_position, triplanar, noise_scale);
	// cut reaches 1 + edge_width at progress 1, so every possible noise value is discarded there.
	float cut = progress * (1.0 + edge_width);
	if (n <= cut - edge_width) {
		discard;
	}

	vec4 base = albedo * texture(albedo_texture, UV);
	ALBEDO = base.rgb;
	ALPHA = base.a;
	ROUGHNESS = 0.7;

	if (n < cut) {
		ALBEDO = edge_color.rgb;
		EMISSION = edge_color.rgb * edge_energy;
	}
}
