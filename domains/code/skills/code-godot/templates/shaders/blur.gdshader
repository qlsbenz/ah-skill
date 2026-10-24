// blur.gdshader — single-pass gaussian blur of whatever is behind the node (pause menu backdrop,
//                  frosted-glass panel, depth-of-field cheat). Reads the screen.
//
// Goes on:   a ColorRect or Panel over the area to blur — full-screen inside a CanvasLayer for a
//            pause backdrop, or a small rect for a frosted panel. `material` slot,
//            mouse_filter = 2 (IGNORE) on a decorative full-screen rect.
// Renderers: Forward+, Mobile, Compatibility (`hint_screen_texture` works on all three; the engine
//            inserts the back-buffer copy itself — no BackBufferCopy node needed on 4.x).
//
// Uniforms:
//   screen_texture sampler2D (hint_screen_texture) filled by the engine — never set it
//                 yourself. Declaring it is what makes Godot copy the framebuffer for this node.
//   blur_radius float 0..16 default 3.0  spread in screen pixels. 0 = passthrough.
//   samples     int 1..4    default 2    ring count: 1 = 9 taps, 2 = 25, 3 = 49, 4 = 81. Cost grows
//               with the square, so raise blur_radius before raising samples.
//   tint        vec4 source_color default (1,1,1,1)  multiplied over the blur (darken a pause menu
//               with (0.6, 0.6, 0.7, 1)).
//   mix_amount  float 0..1 default 1.0   blends between the sharp screen and the blur.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/blur.gdshader $PROJECT/shaders/blur.gdshader
//   dispatch add_node '{"scene_path":"scenes/pause_menu.tscn","parent_node_path":"root","node_type":"ColorRect","node_name":"Backdrop","properties":{"mouse_filter":2,"material":{"__resource_type":"ShaderMaterial","properties":{"shader":{"__resource":"res://shaders/blur.gdshader"},"shader_parameter/blur_radius":3.0,"shader_parameter/samples":2,"shader_parameter/tint":{"__type":"Color","r":0.6,"g":0.6,"b":0.7,"a":1},"shader_parameter/mix_amount":1.0}}}}'
//   dispatch configure_control '{"scene_path":"scenes/pause_menu.tscn","node_path":"root/Backdrop","anchors_preset":15}'
//   dispatch reorder_node '{"scene_path":"scenes/pause_menu.tscn","node_path":"root/Backdrop","index":0}'
//   The backdrop must be the FIRST child so the menu draws on top of it (and is not blurred).
//
// Drive it:
//   GDScript:  (backdrop.material as ShaderMaterial).set_shader_parameter("blur_radius", 3.0)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("blur_radius", v), 0.0, 3.0, 0.2)
//   Animation: value track on "Backdrop:material:shader_parameter/blur_radius" from 0 to 3.
//
// Sharing: one backdrop per menu; keep the material inline in the scene.
//
// Cost: (2*samples+1)^2 texture taps per pixel, full screen. On mobile keep samples = 1 and
//   blur_radius <= 4, or blur a half-resolution SubViewport instead. A real gaussian is two
//   1-D passes (two stacked rects, one horizontal, one vertical) — cheaper at large radii.

shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float blur_radius : hint_range(0.0, 16.0, 0.1) = 3.0;
uniform int samples : hint_range(1, 4) = 2;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float mix_amount : hint_range(0.0, 1.0, 0.01) = 1.0;

void fragment() {
	vec4 sharp = texture(screen_texture, SCREEN_UV);
	vec4 sum = vec4(0.0);
	float weight_sum = 0.0;
	float sigma = max(blur_radius * 0.5, 0.0001);

	for (int y = -4; y <= 4; y++) {
		for (int x = -4; x <= 4; x++) {
			if (abs(x) > samples || abs(y) > samples) {
				continue;
			}
			vec2 step_px = vec2(float(x), float(y)) * blur_radius / float(samples);
			float weight = exp(-dot(step_px, step_px) / (2.0 * sigma * sigma));
			vec2 uv = clamp(SCREEN_UV + step_px * SCREEN_PIXEL_SIZE, vec2(0.0), vec2(1.0));
			sum += texture(screen_texture, uv) * weight;
			weight_sum += weight;
		}
	}

	vec4 blurred = sum / max(weight_sum, 0.0001);
	COLOR = vec4(mix(sharp.rgb, blurred.rgb, mix_amount) * tint.rgb, tint.a * COLOR.a);
}
