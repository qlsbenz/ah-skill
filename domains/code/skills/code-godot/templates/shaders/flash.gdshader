// flash.gdshader — hit flash: push every visible pixel towards one colour.
//
// Goes on:   any textured CanvasItem — Sprite2D, AnimatedSprite2D, TextureRect,
//            TextureButton, TextureProgressBar — in its `material` slot.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   flash_color  vec4 source_color   default (1,1,1,1)  colour to flash towards; its alpha scales the effect.
//   flash_amount float 0..1          default 0.0        0 = untouched, 1 = every opaque pixel is flash_color.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/flash.gdshader $PROJECT/shaders/flash.gdshader
//   dispatch resource_batch '{"resource_path":"materials/flash.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/flash.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/flash_color":{"__type":"Color","r":1,"g":1,"b":1,"a":1},"shader_parameter/flash_amount":0.0}}]}'
//   dispatch configure_node '{"scene_path":"scenes/player.tscn","node_path":"root/Sprite2D","properties":{"material":{"__resource":"res://materials/flash.tres"}}}'
//   Colour values: {"__type":"Color",...} or a "#rrggbb"/"#rrggbbaa" string; anything that is not a colour is refused, never stored as null.
//
// Drive it:
//   GDScript:  (sprite.material as ShaderMaterial).set_shader_parameter("flash_amount", 1.0)
//   Tween:     var mat := sprite.material as ShaderMaterial
//              create_tween().tween_method(
//                  func(v: float) -> void: mat.set_shader_parameter("flash_amount", v), 1.0, 0.0, 0.12)
//   Animation: dispatch build_animation '{"animation_name":"hit_flash","length":0.2,"tracks":[{"type":"value","path":"Sprite2D:material:shader_parameter/flash_amount","keys":[{"time":0.0,"value":1.0},{"time":0.2,"value":0.0}]}],"scene_path":"scenes/player.tscn","player_node_path":"root/AnimationPlayer"}'
//
// Sharing: one ShaderMaterial resource is shared by every node that references it, so
//   set_shader_parameter flashes all of them at once. Three ways out, cheapest first:
//   (a) declare the uniform `instance uniform float flash_amount;` and call
//       sprite.set_instance_shader_parameter("flash_amount", 1.0) — per-node, one material (works for
//       canvas_item and spatial on 4.7); hint_range and a default value are allowed, but an
//       instance uniform can be neither an array nor a sampler;
//   (b) set resource_local_to_scene = true on the material — every instance of the owning scene gets its own copy;
//   (c) sprite.material = sprite.material.duplicate() at runtime.
//
// Note: COLOR already carries texture * modulate * self_modulate when the fragment
//   function starts, so reading and writing COLOR keeps modulate-based fades working.

shader_type canvas_item;

uniform vec4 flash_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float flash_amount : hint_range(0.0, 1.0, 0.01) = 0.0;

void fragment() {
	// Only the RGB is touched: the sprite keeps its own silhouette.
	COLOR.rgb = mix(COLOR.rgb, flash_color.rgb, flash_amount * flash_color.a);
}
