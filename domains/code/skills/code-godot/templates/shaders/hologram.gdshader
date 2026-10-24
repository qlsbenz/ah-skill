// hologram.gdshader — translucent sci-fi projection: fresnel edge glow, travelling scanlines,
//                      flicker and an optional glitch slice. Ghosts, projections, spawn previews,
//                      "place the building here" ghosts in a strategy game.
//
// Goes on:   a MeshInstance3D, in `material_override` (whole mesh) or `surface_material_override/0`.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   hologram_color vec4 source_color default (0.3, 0.8, 1, 1)
//   base_alpha     float 0..1 default 0.25   opacity of the flat body.
//   fresnel_power  float 0.5..16 default 2.5 higher = thinner edge glow.
//   fresnel_boost  float 0..8 default 2.0    how much brighter the silhouette is.
//   scanline_count float 0..400 default 60   lines along the mesh's height, in world units.
//   scanline_speed float -10..10 default 1.5 lines per second; negative scrolls the other way.
//   scanline_depth float 0..1 default 0.5    how dark the gaps between lines get.
//   flicker_speed  float 0..40 default 9.0
//   flicker_amount float 0..1 default 0.12   0 = rock steady.
//   glitch_amount  float 0..0.5 default 0.0  sideways displacement of a moving horizontal slice.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/hologram.gdshader $PROJECT/shaders/hologram.gdshader
//   dispatch resource_batch '{"resource_path":"materials/hologram.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/hologram.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/hologram_color":{"__type":"Color","r":0.3,"g":0.8,"b":1,"a":1},"shader_parameter/base_alpha":0.25,"shader_parameter/fresnel_power":2.5,"shader_parameter/fresnel_boost":2.0,"shader_parameter/scanline_count":60.0,"shader_parameter/scanline_speed":1.5,"shader_parameter/scanline_depth":0.5,"shader_parameter/flicker_speed":9.0,"shader_parameter/flicker_amount":0.12,"shader_parameter/glitch_amount":0.0}}]}'
//   dispatch configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Projection","properties":{"material_override":{"__resource":"res://materials/hologram.tres"}}}'
//
// Drive it:
//   GDScript:  (mesh.material_override as ShaderMaterial).set_shader_parameter("glitch_amount", 0.2)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("base_alpha", v), 0.0, 0.25, 0.4)  # materialise
//   Animation: value track on "Projection:material_override:shader_parameter/glitch_amount".
//
// Sharing: one hologram material for every projection is normal. For independent flicker phases,
//   `instance uniform float scanline_speed;` + mesh.set_instance_shader_parameter(...).
//
// Note: it is transparent and unshaded, so it never casts or receives shadows and it is sorted by
//   object, not per pixel — two overlapping holograms can pop when the camera moves. That is how
//   alpha blending works in Godot; split the mesh or accept it.

shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 hologram_color : source_color = vec4(0.3, 0.8, 1.0, 1.0);
uniform float base_alpha : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform float fresnel_power : hint_range(0.5, 16.0, 0.1) = 2.5;
uniform float fresnel_boost : hint_range(0.0, 8.0, 0.05) = 2.0;
uniform float scanline_count : hint_range(0.0, 400.0, 1.0) = 60.0;
uniform float scanline_speed : hint_range(-10.0, 10.0, 0.05) = 1.5;
uniform float scanline_depth : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float flicker_speed : hint_range(0.0, 40.0, 0.1) = 9.0;
uniform float flicker_amount : hint_range(0.0, 1.0, 0.01) = 0.12;
uniform float glitch_amount : hint_range(0.0, 0.5, 0.005) = 0.0;

varying vec3 model_position;

void vertex() {
	model_position = VERTEX;
	if (glitch_amount > 0.0) {
		// A horizontal slice that sweeps up the mesh and shears sideways as it passes.
		float slice = step(0.92, fract(VERTEX.y * 3.0 - TIME * 1.7));
		VERTEX.x += slice * glitch_amount * sin(TIME * 37.0);
	}
}

void fragment() {
	// Scanlines run along the mesh's own Y so they stay put as the camera orbits.
	float lines = 0.5 + 0.5 * sin(model_position.y * scanline_count - TIME * scanline_speed * TAU);
	float scan = mix(1.0, lines, scanline_depth);

	// Two out-of-phase sines: a flicker that never settles into a visible beat.
	float flicker = 1.0 - flicker_amount
			* (0.5 + 0.5 * sin(TIME * flicker_speed) * sin(TIME * flicker_speed * 0.37 + 1.3));

	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, fresnel_power);

	ALBEDO = hologram_color.rgb * (scan * flicker + fresnel * fresnel_boost);
	ALPHA = clamp((base_alpha * scan + fresnel * fresnel_boost * 0.5) * flicker, 0.0, 1.0)
			* hologram_color.a;
}
