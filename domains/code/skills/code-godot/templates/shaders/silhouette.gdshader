// silhouette.gdshader — flatten a sprite to one colour while keeping its shape: the "player is
//                        behind a wall" ghost, a drop shadow, a stealth blackout, a ghost trail.
//
// Goes on:   any textured CanvasItem (`material`) — Sprite2D, AnimatedSprite2D, TextureRect.
//            Behind-wall outline: duplicate the sprite node, give the copy this material,
//            set its `show_behind_parent = true` (or a lower z_index) and `light_mask = 0`, and
//            toggle its `visible` from the wall's Area2D. The copy draws under the wall, the
//            original over it, so only the hidden part shows through.
//            Drop shadow: same copy, position offset, silhouette_color = (0,0,0,0.4), scale.y ~ 0.5.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   silhouette_color vec4 source_color default (0.1, 0.1, 0.15, 0.6)  the flat colour; its alpha
//                    multiplies the sprite's own alpha.
//   amount           float 0..1 default 1.0  0 = normal sprite, 1 = fully flat. Tween it.
//   alpha_cutoff     float 0..1 default 0.0  discard pixels below this alpha, so soft edges do not
//                    leave a halo when silhouette_color is opaque.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/silhouette.gdshader $PROJECT/shaders/silhouette.gdshader
//   dispatch resource_batch '{"resource_path":"materials/silhouette.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/silhouette.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/silhouette_color":{"__type":"Color","r":0.1,"g":0.1,"b":0.15,"a":0.6},"shader_parameter/amount":1.0,"shader_parameter/alpha_cutoff":0.0}}]}'
//   dispatch configure_node '{"scene_path":"scenes/player.tscn","node_path":"root/Ghost","properties":{"material":{"__resource":"res://materials/silhouette.tres"},"show_behind_parent":true,"light_mask":0}}'
//
// Drive it:
//   GDScript:  (ghost.material as ShaderMaterial).set_shader_parameter("amount", 1.0)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("amount", v), 0.0, 1.0, 0.15)
//   Animation: value track on "Ghost:material:shader_parameter/amount".
//
// Sharing: shadows and ghosts usually all look the same, so sharing one .tres is the right call.
//   Use `instance uniform float amount;` + set_instance_shader_parameter when they must fade
//   independently.

shader_type canvas_item;

uniform vec4 silhouette_color : source_color = vec4(0.1, 0.1, 0.15, 0.6);
uniform float amount : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float alpha_cutoff : hint_range(0.0, 1.0, 0.01) = 0.0;

void fragment() {
	// COLOR arrives as texture * modulate * self_modulate, so the shape (and any fade already
	// applied through modulate) is preserved.
	if (COLOR.a <= alpha_cutoff) {
		discard;
	}
	COLOR = vec4(mix(COLOR.rgb, silhouette_color.rgb, amount),
			COLOR.a * mix(1.0, silhouette_color.a, amount));
}
