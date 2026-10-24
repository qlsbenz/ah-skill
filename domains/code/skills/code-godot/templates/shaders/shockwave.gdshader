// shockwave.gdshader — expanding ring that warps whatever is behind it (explosions, heavy landings,
//                       teleports, a boss's roar). Reads the screen.
//
// Goes on:   a ColorRect covering the area the ring can reach — usually a full-rect ColorRect on a
//            CanvasLayer (mouse_filter = 2 IGNORE), `material` slot. The ring is positioned in
//            SCREEN UV, so the rect only has to be big enough to contain it.
// Renderers: Forward+, Mobile, Compatibility (`hint_screen_texture` works on all three; no
//            BackBufferCopy node needed on 4.x).
//
// Uniforms:
//   screen_texture sampler2D (hint_screen_texture) filled by the engine — never set it
//                 yourself. Declaring it is what makes Godot copy the framebuffer for this node.
//   center     vec2 default (0.5, 0.5)  ring centre in screen UV. Convert a world position with
//              get_viewport().get_canvas_transform() * world_pos, divided by the viewport size.
//   radius     float 0..2   default 0.0  current ring radius in screen-UV units — tween 0 -> 1.
//   thickness  float 0..1   default 0.08 width of the warped band.
//   strength   float 0..0.2 default 0.03 how far pixels are pushed, in screen-UV units.
//   aspect     float 0.1..4 default 1.0  viewport width / height, so the ring stays circular.
//   ring_color vec4 source_color default (1,1,1,0)  optional bright rim; alpha 0 = distortion only.
//   fade_with_radius bool default true   the ring weakens as it grows, so a single tween is enough.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/shockwave.gdshader $PROJECT/shaders/shockwave.gdshader
//   dispatch add_node '{"scene_path":"scenes/main.tscn","parent_node_path":"root","node_type":"CanvasLayer","node_name":"PostProcess","properties":{"layer":90}}'
//   dispatch add_node '{"scene_path":"scenes/main.tscn","parent_node_path":"root/PostProcess","node_type":"ColorRect","node_name":"Shockwave","properties":{"mouse_filter":2,"material":{"__resource_type":"ShaderMaterial","properties":{"shader":{"__resource":"res://shaders/shockwave.gdshader"},"shader_parameter/center":{"__type":"Vector2","x":0.5,"y":0.5},"shader_parameter/radius":0.0,"shader_parameter/thickness":0.08,"shader_parameter/strength":0.03,"shader_parameter/aspect":1.7778,"shader_parameter/ring_color":{"__type":"Color","r":1,"g":1,"b":1,"a":0},"shader_parameter/fade_with_radius":true}}}}'
//   dispatch configure_control '{"scene_path":"scenes/main.tscn","node_path":"root/PostProcess/Shockwave","anchors_preset":15}'
//
// Drive it:
//   GDScript:  var mat := shockwave.material as ShaderMaterial
//              mat.set_shader_parameter("center", get_viewport().get_canvas_transform() * world_pos / Vector2(get_viewport_rect().size))
//              create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("radius", v), 0.0, 1.0, 0.45)
//   Animation: dispatch build_animation '{"animation_name":"boom","length":0.45,"tracks":[{"type":"value","path":"PostProcess/Shockwave:material:shader_parameter/radius","keys":[{"time":0.0,"value":0.0},{"time":0.45,"value":1.0}]}],"scene_path":"scenes/main.tscn","player_node_path":"root/AnimationPlayer"}'
//
// Sharing: for several simultaneous blasts, instance the whole CanvasLayer+ColorRect scene per blast
//   and free it when the tween ends (templates/gdscript/object_pool.gd), or set
//   resource_local_to_scene = true so each instance gets its own material.

shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec2 center = vec2(0.5, 0.5);
uniform float radius : hint_range(0.0, 2.0, 0.005) = 0.0;
uniform float thickness : hint_range(0.0, 1.0, 0.005) = 0.08;
uniform float strength : hint_range(0.0, 0.2, 0.001) = 0.03;
uniform float aspect : hint_range(0.1, 4.0, 0.01) = 1.0;
uniform vec4 ring_color : source_color = vec4(1.0, 1.0, 1.0, 0.0);
uniform bool fade_with_radius = true;

void fragment() {
	vec2 delta = (SCREEN_UV - center) * vec2(aspect, 1.0);
	float dist = length(delta);
	float band = max(thickness, 0.0001);

	// A 0..1..0 ramp across the band, so the displacement eases in and out instead of popping.
	float ring = smoothstep(radius - band, radius, dist) * (1.0 - smoothstep(radius, radius + band, dist));
	if (fade_with_radius) {
		ring *= 1.0 - clamp(radius, 0.0, 1.0);
	}

	// normalize() of a zero vector is undefined; the centre pixel must not be pushed anywhere.
	vec2 direction = dist > 0.0001 ? delta / dist : vec2(0.0);
	vec2 offset = direction * ring * strength / vec2(aspect, 1.0);
	vec2 uv = clamp(SCREEN_UV - offset, vec2(0.0), vec2(1.0));

	vec3 warped = texture(screen_texture, uv).rgb;
	COLOR = vec4(mix(warped, ring_color.rgb, ring * ring_color.a), 1.0);
}
