// crt.gdshader — full-screen CRT post-process: barrel curvature, scanlines, aperture grille,
//                 chromatic aberration and edge vignette. Reads the screen.
//
// Goes on:   a ColorRect that covers the whole viewport, inside a CanvasLayer that sits ABOVE
//            everything it should affect:
//            CanvasLayer (layer = 100) > ColorRect (anchors preset 15 "full rect",
//            mouse_filter = 2 IGNORE), `material` slot.
//            A screen-reading shader sees whatever has already been drawn this frame, so
//            anything on a HIGHER CanvasLayer stays sharp (put the HUD above it on purpose).
// Renderers: Forward+, Mobile, Compatibility. `hint_screen_texture` works on all three; the
//            engine inserts the back-buffer copy itself, so no BackBufferCopy node is needed
//            (that is a Godot 3 habit). Verified on 4.7 in all three renderers.
//
// Uniforms:
//   screen_texture sampler2D (hint_screen_texture) filled by the engine — never set it
//                 yourself. Declaring it is what makes Godot copy the framebuffer for this node.
//   curvature          float 0..1    default 0.12  barrel distortion; 0 = flat.
//   scanline_strength  float 0..1    default 0.25  darkening of every other line.
//   scanline_count     float 0..2000 default 240   lines down the screen; match the vertical
//                      resolution the art was drawn at for a stable, non-moiré pattern.
//   aberration         float 0..5    default 0.6   red/blue separation in screen pixels.
//   grille_strength    float 0..1    default 0.0   vertical RGB stripe (aperture grille).
//   vignette_strength  float 0..1    default 0.25  corner darkening.
//   brightness         float 0..2    default 1.1   scanlines eat light; push it back.
//   border_color       vec4 source_color default (0,0,0,1)  drawn outside the curved screen.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/crt.gdshader $PROJECT/shaders/crt.gdshader
//   dispatch add_node '{"scene_path":"scenes/main.tscn","parent_node_path":"root","node_type":"CanvasLayer","node_name":"PostProcess","properties":{"layer":100}}'
//   dispatch add_node '{"scene_path":"scenes/main.tscn","parent_node_path":"root/PostProcess","node_type":"ColorRect","node_name":"CRT","properties":{"mouse_filter":2,"material":{"__resource_type":"ShaderMaterial","properties":{"shader":{"__resource":"res://shaders/crt.gdshader"},"shader_parameter/curvature":0.12,"shader_parameter/scanline_strength":0.25,"shader_parameter/scanline_count":240.0,"shader_parameter/aberration":0.6,"shader_parameter/grille_strength":0.0,"shader_parameter/vignette_strength":0.25,"shader_parameter/brightness":1.1,"shader_parameter/border_color":{"__type":"Color","r":0,"g":0,"b":0,"a":1}}}}}'
//   dispatch configure_control '{"scene_path":"scenes/main.tscn","node_path":"root/PostProcess/CRT","anchors_preset":15}'
//   Verify it with a screenshot rather than by eye:
//   run_scenario.py $PROJECT scenario.json   # steps: [{"type":"screenshot","path":"/tmp/crt.png","expect":{"not_blank":true}}]
//
// Drive it:
//   GDScript:  (crt_rect.material as ShaderMaterial).set_shader_parameter("aberration", 2.0)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("aberration", v), 4.0, 0.6, 0.4)  # glitch burst
//   Animation: value track on "PostProcess/CRT:material:shader_parameter/curvature".
//
// Sharing: one instance per game. Keep the material inline in the scene.
//
// Cost: a screen read breaks 2D batching at this node and copies the framebuffer once. That is one
//   copy for the whole screen — cheap — but do not put screen-reading materials on many sprites.

shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float curvature : hint_range(0.0, 1.0, 0.01) = 0.12;
uniform float scanline_strength : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform float scanline_count : hint_range(0.0, 2000.0, 1.0) = 240.0;
uniform float aberration : hint_range(0.0, 5.0, 0.05) = 0.6;
uniform float grille_strength : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float vignette_strength : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform float brightness : hint_range(0.0, 2.0, 0.01) = 1.1;
uniform vec4 border_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

vec2 curve(vec2 uv, float amount) {
	// Classic barrel warp: push each axis outwards by the square of the other one.
	vec2 centered = uv * 2.0 - 1.0;
	vec2 bulge = abs(centered.yx) * amount;
	centered += centered * bulge * bulge;
	return centered * 0.5 + 0.5;
}

void fragment() {
	vec2 uv = curve(SCREEN_UV, curvature);

	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		COLOR = border_color;
	} else {
		vec2 shift = vec2(aberration, 0.0) * SCREEN_PIXEL_SIZE;
		vec3 tube = vec3(
			texture(screen_texture, clamp(uv + shift, vec2(0.0), vec2(1.0))).r,
			texture(screen_texture, uv).g,
			texture(screen_texture, clamp(uv - shift, vec2(0.0), vec2(1.0))).b);

		// Scanlines: a raised cosine so the dark line is thinner than the bright one.
		float scan = 1.0 - scanline_strength * (0.5 - 0.5 * cos(uv.y * scanline_count * TAU));
		tube *= scan;

		if (grille_strength > 0.0) {
			// One RGB triad every 3 screen pixels.
			float column = mod(FRAGCOORD.x, 3.0);
			vec3 grille = vec3(step(column, 1.0), step(1.0, column) * step(column, 2.0), step(2.0, column));
			tube *= mix(vec3(1.0), grille * 1.5 + 0.25, grille_strength);
		}

		float edge = length(uv - vec2(0.5)) * 1.414;
		tube *= mix(1.0, 1.0 - smoothstep(0.55, 1.0, edge), vignette_strength);

		COLOR = vec4(tube * brightness, 1.0);
	}
}
