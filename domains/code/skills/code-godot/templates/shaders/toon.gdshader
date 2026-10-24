// toon.gdshader — banded (cel) lighting with a toon specular and an optional rim, written in
//                  light() so it reacts to every real Light3D in the scene.
//
// Goes on:   a MeshInstance3D. Either `material_override` (replaces every surface) or
//            `surface_material_override/0` (just surface 0 — the right slot when the mesh has
//            several materials and you only want to restyle one).
// Renderers: Forward+, Mobile, Compatibility. A custom light() function runs on all three; the
//            only 3D features this file avoids are screen/depth/normal-roughness reads.
//
// Uniforms:
//   albedo          vec4 source_color default (0.85, 0.85, 0.9, 1)
//   albedo_texture  sampler2D (hint_default_white) optional base texture.
//   bands           int 1..8 default 3      number of light steps. 2 is the classic "two-tone".
//   band_softness   float 0..0.5 default 0.02  anti-aliases the band edges. 0 = razor sharp.
//   specular_color  vec4 source_color default (1,1,1,1)
//   specular_size   float 0..1 default 0.25  bigger = wider highlight blob. 0 disables it.
//   specular_strength float 0..2 default 0.6
//   rim_color       vec4 source_color default (1,1,1,1)
//   rim_amount      float 0..1 default 0.0   0 = no rim. A rim at 0.5 reads as backlight.
//   ambient         float 0..1 default 0.15  floor brightness so the dark side is not pure black.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/toon.gdshader $PROJECT/shaders/toon.gdshader
//   dispatch resource_batch '{"resource_path":"materials/toon.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/toon.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/albedo":{"__type":"Color","r":0.85,"g":0.85,"b":0.9,"a":1},"shader_parameter/bands":3,"shader_parameter/band_softness":0.02,"shader_parameter/specular_color":{"__type":"Color","r":1,"g":1,"b":1,"a":1},"shader_parameter/specular_size":0.25,"shader_parameter/specular_strength":0.6,"shader_parameter/rim_color":{"__type":"Color","r":1,"g":1,"b":1,"a":1},"shader_parameter/rim_amount":0.0,"shader_parameter/ambient":0.15}}]}'
//   dispatch configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Character","properties":{"material_override":{"__resource":"res://materials/toon.tres"}}}'
//   Per-surface instead of the whole mesh:
//   dispatch configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Character","indexed_properties":{"surface_material_override/0":{"__resource":"res://materials/toon.tres"}}}'
//   The scene needs a light: add_node DirectionalLight3D — with no Light3D and no WorldEnvironment
//   this material renders at `ambient` only (spatial_report's no_light_3d finding catches that).
//
// Drive it:
//   GDScript:  (mesh.material_override as ShaderMaterial).set_shader_parameter("bands", 2)
//   Tween:     tween `rim_amount` 0 -> 1 to flare a character on a hit.
//   Animation: value track on "Character:material_override:shader_parameter/rim_amount".
//
// Sharing: one .tres per look; every mesh that uses it is restyled together, which is the point.
//   For per-mesh variation use `instance uniform vec4 albedo;` +
//   mesh.set_instance_shader_parameter("albedo", Color(...)) — instance uniforms work on
//   GeometryInstance3D (and, on 4.7, on CanvasItem too); hint_range and defaults are fine, but an
//   instance uniform can be neither an array nor a sampler.

shader_type spatial;
// No diffuse_*/specular_* render mode: the light() function below replaces Godot's
// shading model outright, so those modes would only be misleading.

uniform vec4 albedo : source_color = vec4(0.85, 0.85, 0.9, 1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap;
uniform int bands : hint_range(1, 8) = 3;
uniform float band_softness : hint_range(0.0, 0.5, 0.005) = 0.02;
uniform vec4 specular_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float specular_size : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform float specular_strength : hint_range(0.0, 2.0, 0.01) = 0.6;
uniform vec4 rim_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float rim_amount : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float ambient : hint_range(0.0, 1.0, 0.01) = 0.15;

void fragment() {
	vec4 base = albedo * texture(albedo_texture, UV);
	ALBEDO = base.rgb;
	ALPHA = base.a;
	// The banding below replaces Godot's shading model completely, so the PBR inputs are
	// neutralised to keep the result predictable across renderers.
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float ndotl = dot(normalize(NORMAL), normalize(LIGHT));
	float lit = clamp(ndotl, 0.0, 1.0);

	// Quantise into `bands` steps. smoothstep across one step width gives a soft, still-flat edge.
	float steps = float(bands);
	float scaled = lit * steps;
	float lower = floor(scaled);
	float band = (lower + smoothstep(0.5 - band_softness * steps, 0.5 + band_softness * steps,
			fract(scaled))) / steps;
	band = clamp(max(band, ambient), 0.0, 1.0);

	// LIGHT_COLOR arrives multiplied by PI (Godot divides by PI inside its own shading model),
	// so dividing it back out here keeps a toon surface the same brightness as a lambert one.
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * band / PI;

	if (specular_size > 0.0) {
		vec3 half_vector = normalize(normalize(VIEW) + normalize(LIGHT));
		float ndoth = clamp(dot(normalize(NORMAL), half_vector), 0.0, 1.0);
		// specular_size 0..1 maps to a wide..tight blob through an exponent.
		float blob = pow(ndoth, mix(256.0, 4.0, specular_size));
		float toon_blob = smoothstep(0.25 - band_softness, 0.25 + band_softness, blob);
		SPECULAR_LIGHT += specular_color.rgb * LIGHT_COLOR * ATTENUATION
				* toon_blob * specular_strength / PI;
	}

	if (rim_amount > 0.0) {
		float rim = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
		float toon_rim = smoothstep(1.0 - rim_amount - band_softness, 1.0 - rim_amount + band_softness, rim);
		DIFFUSE_LIGHT += rim_color.rgb * LIGHT_COLOR * ATTENUATION * toon_rim * lit / PI;
	}
}
