// triplanar.gdshader — texture a mesh that has no usable UVs by projecting from the three world
//                       axes. The fix for CSG output, primitive meshes, terrain, procedural
//                       geometry and anything where a tiling texture stretches.
//
// Goes on:   a MeshInstance3D (`material_override` / `surface_material_override/0`) or a CSG node's
//            `material`. Works on a GridMap mesh library item too.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   albedo          vec4 source_color default (1,1,1,1)  multiplied over the texture.
//   albedo_texture  sampler2D (hint_default_white, repeat_enable) the tiling texture.
//   normal_texture  sampler2D (hint_normal, repeat_enable) optional normal map; blended the same way.
//   normal_strength float 0..4 default 0.0  0 = ignore the normal map entirely.
//   texture_scale   float 0.01..8 default 1.0  tiles per world unit (world space) or per model unit.
//   blend_sharpness float 1..32 default 4.0  higher = crisper seams between the three projections.
//   world_space     bool default true  true = the texture stays put when the object moves (terrain,
//                   walls); false = it travels with the object (a moving rock keeps its pattern).
//   metallic        float 0..1 default 0.0
//   roughness       float 0..1 default 0.85
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/triplanar.gdshader $PROJECT/shaders/triplanar.gdshader
//   dispatch resource_batch '{"resource_path":"materials/rock.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/triplanar.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/albedo":{"__type":"Color","r":1,"g":1,"b":1,"a":1},"shader_parameter/albedo_texture":{"__resource":"res://art/rock.png"},"shader_parameter/normal_strength":0.0,"shader_parameter/texture_scale":0.5,"shader_parameter/blend_sharpness":4.0,"shader_parameter/world_space":true,"shader_parameter/metallic":0.0,"shader_parameter/roughness":0.85}}]}'
//   dispatch configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Terrain","properties":{"material_override":{"__resource":"res://materials/rock.tres"}}}'
//   The texture must tile seamlessly or every seam shows: draw_image '{"tile_check":true}' reports it.
//   A freshly written PNG needs one `godot --headless --path $PROJECT --import` before it can load.
//
// Drive it:
//   GDScript:  (mesh.material_override as ShaderMaterial).set_shader_parameter("texture_scale", 0.25)
//   Tween/Animation: rarely animated; this is a look, not an effect.
//
// Sharing: exactly what you want here — one rock material across the whole level, one draw batch.
//
// Note: three texture taps per pixel (six with a normal map). Cheaper than authoring UVs, more
//   expensive than having them: use it for terrain and props, not for a full screen of characters.

shader_type spatial;

uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_strength : hint_range(0.0, 4.0, 0.01) = 0.0;
uniform float texture_scale : hint_range(0.01, 8.0, 0.01) = 1.0;
uniform float blend_sharpness : hint_range(1.0, 32.0, 0.1) = 4.0;
uniform bool world_space = true;
uniform float metallic : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.85;

varying vec3 projection_position;
varying vec3 projection_normal;

void vertex() {
	if (world_space) {
		projection_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		projection_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	} else {
		projection_position = VERTEX;
		projection_normal = normalize(NORMAL);
	}
}

vec4 triplanar_sample(sampler2D tex, vec3 position, vec3 weights) {
	// One tap per axis, each reading the two coordinates that are NOT the projection axis.
	return texture(tex, position.zy) * weights.x
			+ texture(tex, position.xz) * weights.y
			+ texture(tex, position.xy) * weights.z;
}

void fragment() {
	vec3 blend = pow(abs(normalize(projection_normal)), vec3(blend_sharpness));
	// Normalise so the three weights always sum to 1, whatever the sharpness.
	blend /= max(blend.x + blend.y + blend.z, 0.0001);
	vec3 position = projection_position * texture_scale;

	vec4 base = triplanar_sample(albedo_texture, position, blend) * albedo;
	ALBEDO = base.rgb;
	ALPHA = base.a;
	METALLIC = metallic;
	ROUGHNESS = roughness;

	if (normal_strength > 0.0) {
		NORMAL_MAP = triplanar_sample(normal_texture, position, blend).rgb;
		NORMAL_MAP_DEPTH = normal_strength;
	}
}
