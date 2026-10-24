// pixelate.gdshader — snap a sprite's sampling to a coarse grid (retro transition, "corrupted"
//                      effect, turning smooth art into blocks).
//
// Goes on:   any textured CanvasItem (`material`) — Sprite2D, TextureRect, AnimatedSprite2D.
//            For the whole screen, put crt.gdshader's screen-read pattern around this maths, or
//            lower the viewport resolution instead (cheaper: Window > stretch mode `viewport`).
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   block_size float 1..64 default 4.0  edge of one block, in TEXTURE pixels. 1 = no change.
//   grid_lines float 0..1  default 0.0  darkens the last row/column of each block (LCD look).
//   snap_uv    bool default true  true samples the block centre (hard blocks); false samples the
//              block corner, which keeps linear filtering visible inside a block.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/pixelate.gdshader $PROJECT/shaders/pixelate.gdshader
//   dispatch resource_batch '{"resource_path":"materials/pixelate.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/pixelate.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/block_size":4.0,"shader_parameter/grid_lines":0.0,"shader_parameter/snap_uv":true}}]}'
//   dispatch configure_node '{"scene_path":"scenes/main.tscn","node_path":"root/Sprite2D","properties":{"material":{"__resource":"res://materials/pixelate.tres"}}}'
//
// Drive it:
//   GDScript:  (sprite.material as ShaderMaterial).set_shader_parameter("block_size", 8.0)
//   Tween:     create_tween().tween_method(func(v: float) -> void: mat.set_shader_parameter("block_size", v), 1.0, 32.0, 0.5)
//   Animation: dispatch build_animation '{"animation_name":"pixel_out","length":0.5,"tracks":[{"type":"value","path":"Sprite2D:material:shader_parameter/block_size","keys":[{"time":0.0,"value":1.0},{"time":0.5,"value":32.0}]}],"scene_path":"scenes/main.tscn","player_node_path":"root/AnimationPlayer"}'
//
// Sharing: `instance uniform float block_size;` + sprite.set_instance_shader_parameter() for
//   per-node values, otherwise every node on this material pixelates together.
//
// Note: to bake the effect into a file instead of paying for it every frame, use
//   process_image '{"operations":[{"type":"pixelate","cell_size":4},{"type":"quantize","max_colors":16}]}'.

shader_type canvas_item;

uniform float block_size : hint_range(1.0, 64.0, 1.0) = 4.0;
uniform float grid_lines : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform bool snap_uv = true;

// Captures the node's modulate * self_modulate before the engine multiplies the texture in.
// Every tap below reads the raw texture, so the tint has to be re-applied by hand at the end.
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	vec2 grid = TEXTURE_PIXEL_SIZE * block_size;
	vec2 cell = floor(UV / grid);
	vec2 uv = snap_uv ? (cell + 0.5) * grid : cell * grid;
	vec4 base = texture(TEXTURE, uv);

	if (grid_lines > 0.0) {
		vec2 inside_cell = fract(UV / grid);
		float edge = max(step(1.0 - TEXTURE_PIXEL_SIZE.x / grid.x, inside_cell.x),
				step(1.0 - TEXTURE_PIXEL_SIZE.y / grid.y, inside_cell.y));
		base.rgb *= mix(1.0, 0.65, edge * grid_lines);
	}

	// `tint` carries the node's modulate/self_modulate, which a texture() tap cannot see.
	COLOR = base * tint;
}
