// water_2d.gdshader — a water/heat-haze strip: it distorts and tints what is behind it, adds a
//                      foam line at the surface and can mirror the scene above it. Reads the screen.
//
// Goes on:   a ColorRect sized and placed like the body of water (a lake surface, a lava pool, a
//            heat shimmer over a fire), `material` slot. Draw it AFTER the world it should refract:
//            same CanvasLayer, higher in the tree (or a higher z_index).
// Renderers: Forward+, Mobile, Compatibility (`hint_screen_texture` works on all three; the engine
//            inserts the back-buffer copy itself — no BackBufferCopy node needed on 4.x).
//
// Uniforms:
//   screen_texture sampler2D (hint_screen_texture) filled by the engine — never set it
//                 yourself. Declaring it is what makes Godot copy the framebuffer for this node.
//   water_color    vec4 source_color default (0.15, 0.45, 0.75, 0.45)  tint; alpha = how much of it.
//   distortion     float 0..32 default 6.0   refraction in screen pixels.
//   wave_frequency float 0..40 default 12.0  ripples across the rect.
//   wave_speed     float 0..10 default 1.5   ripple speed.
//   foam_height    float 0..0.5 default 0.06 thickness of the bright surface line, in rect UV.
//   foam_color     vec4 source_color default (1,1,1,0.75)
//   reflection     float 0..1  default 0.0   0 = no mirror. Needs reflection_span (below).
//   reflection_span float 0..1 default 0.0   the rect's height as a fraction of the VIEWPORT height
//                   — rect.size.y / get_viewport_rect().size.y. Without it the mirror has no idea
//                   how far up the screen to look, so reflection does nothing. Set it from a script
//                   on _ready and on resize, or leave reflection at 0.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/water_2d.gdshader $PROJECT/shaders/water_2d.gdshader
//   dispatch add_node '{"scene_path":"scenes/level.tscn","parent_node_path":"root","node_type":"ColorRect","node_name":"Water","properties":{"mouse_filter":2,"offset_left":0,"offset_top":180,"offset_right":320,"offset_bottom":240,"material":{"__resource_type":"ShaderMaterial","properties":{"shader":{"__resource":"res://shaders/water_2d.gdshader"},"shader_parameter/water_color":{"__type":"Color","r":0.15,"g":0.45,"b":0.75,"a":0.45},"shader_parameter/distortion":6.0,"shader_parameter/wave_frequency":12.0,"shader_parameter/wave_speed":1.5,"shader_parameter/foam_height":0.06,"shader_parameter/foam_color":{"__type":"Color","r":1,"g":1,"b":1,"a":0.75},"shader_parameter/reflection":0.0,"shader_parameter/reflection_span":0.0}}}}'
//
// Drive it:
//   GDScript:  var rect := $Water as ColorRect
//              var mat := rect.material as ShaderMaterial
//              mat.set_shader_parameter("reflection_span", rect.size.y / get_viewport_rect().size.y)
//              mat.set_shader_parameter("reflection", 0.35)
//   Tween:     tween `distortion` up for a splash, back down over 0.5 s.
//   Animation: value track on "Water:material:shader_parameter/distortion".
//
// Sharing: one material per body of water is fine; they animate off TIME, not off state.
//
// Cost: one screen read (the engine copies the framebuffer once for this node) plus 1-2 taps per
//   pixel. Keep the rect as small as the water actually is.

shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec4 water_color : source_color = vec4(0.15, 0.45, 0.75, 0.45);
uniform float distortion : hint_range(0.0, 32.0, 0.1) = 6.0;
uniform float wave_frequency : hint_range(0.0, 40.0, 0.1) = 12.0;
uniform float wave_speed : hint_range(0.0, 10.0, 0.05) = 1.5;
uniform float foam_height : hint_range(0.0, 0.5, 0.005) = 0.06;
uniform vec4 foam_color : source_color = vec4(1.0, 1.0, 1.0, 0.75);
uniform float reflection : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float reflection_span : hint_range(0.0, 1.0, 0.001) = 0.0;

void fragment() {
	// Two sines at different rates never repeat visibly, which is what stops water looking like a
	// rolling barcode.
	float ripple = sin(UV.x * wave_frequency + TIME * wave_speed)
			* 0.6 + sin(UV.x * wave_frequency * 2.3 - TIME * wave_speed * 1.7) * 0.4;
	float depth = smoothstep(0.0, 0.35, UV.y);
	vec2 offset = vec2(ripple, ripple * 0.35) * distortion * SCREEN_PIXEL_SIZE * depth;

	vec3 behind = texture(screen_texture, clamp(SCREEN_UV + offset, vec2(0.0), vec2(1.0))).rgb;

	if (reflection > 0.0 && reflection_span > 0.0) {
		// The strip's top edge in screen UV: walk back up by however much of the rect is above us.
		float top = SCREEN_UV.y - UV.y * reflection_span;
		vec2 mirrored = vec2(SCREEN_UV.x, top - UV.y * reflection_span) + offset;
		if (mirrored.y >= 0.0) {
			behind = mix(behind, texture(screen_texture, clamp(mirrored, vec2(0.0), vec2(1.0))).rgb, reflection);
		}
	}

	vec3 tinted = mix(behind, water_color.rgb, water_color.a);

	// Foam sits on the top edge of the rect and rides the same ripple.
	float surface = foam_height * (0.7 + 0.3 * ripple);
	float foam = 1.0 - smoothstep(0.0, max(surface, 0.0001), UV.y);
	tinted = mix(tinted, foam_color.rgb, foam * foam_color.a);

	COLOR = vec4(tinted, 1.0);
}
