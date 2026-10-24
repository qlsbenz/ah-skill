// outline_3d.gdshader — inverted-hull outline: a second pass that draws the mesh slightly larger,
//                        inside-out, in a flat colour. The standard cartoon/selection outline.
//
// Goes on:   NOT the material slot — the `next_pass` of the material that is already on the mesh:
//              MeshInstance3D.material_override.next_pass         (whole mesh)
//              MeshInstance3D.surface_material_override/0.next_pass
//              or on a StandardMaterial3D's next_pass just the same.
//            Pair it with toon.gdshader for a full cel-shaded look.
// Renderers: Forward+, Mobile, Compatibility (no screen or depth reads).
//
// Uniforms:
//   outline_color   vec4 source_color default (0,0,0,1)
//   outline_width   float 0..0.5 default 0.02  grow distance in MODEL units (the mesh's own scale
//                   multiplies it — a 0.5 m prop and a 5 m boss need different values).
//   screen_constant bool default false  true keeps the outline a constant thickness on screen no
//                   matter how far away the object is; false lets it shrink with distance.
//   max_distance    float 0..500 default 0.0  drop the outline entirely beyond this many metres
//                   (outline LOD). 0 = always draw it.
//   The pass is fully opaque on purpose: writing to ALPHA would move it into Godot's transparent
//   queue, where it would sort per object and flicker against the mesh it outlines. Hiding is done
//   with `discard`, which keeps it in the opaque pass.
//
// WHEN IT DOES NOT WORK: the hull is grown along the vertex normals, so
//   - a mesh with SPLIT (hard-edge) normals tears at the seams — a cube shows three separated
//     slabs. Re-import the mesh with smoothing, or use a mesh whose normals are averaged.
//   - a flat plane has nothing to grow outwards, so it just gets bigger.
//   - the outline is drawn by BACK faces (cull_front), so a mesh with flipped/one-sided geometry
//     shows nothing.
//   The screen-space alternative (sobel on the depth buffer) needs a full-screen pass and a depth
//   read; this inverted hull needs neither and works on every renderer.
//
// Attach (substitute the two absolute paths, then paste the blocks in order):
//   SKILL=/absolute/path/to/godot; PROJECT=/absolute/path/to/project
//   dispatch() { godot --headless --path "$PROJECT" --script "$SKILL/scripts/core/dispatcher.gd" "$@"; }
//   cp $SKILL/templates/shaders/outline_3d.gdshader $PROJECT/shaders/outline_3d.gdshader
//   dispatch resource_batch '{"resource_path":"materials/outline_3d.tres","create_if_missing":true,"resource_type":"ShaderMaterial","actions":[{"type":"set_properties","properties":{"shader":{"__resource":"res://shaders/outline_3d.gdshader"}}},{"type":"set_indexed_properties","properties":{"shader_parameter/outline_color":{"__type":"Color","r":0,"g":0,"b":0,"a":1},"shader_parameter/outline_width":0.02,"shader_parameter/screen_constant":false,"shader_parameter/max_distance":0.0}}]}'
//   dispatch configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Character","properties":{"material_override":{"__resource":"res://materials/toon.tres"}}}'
//   dispatch configure_node '{"scene_path":"scenes/world.tscn","node_path":"root/Character","indexed_properties":{"material_override:next_pass":{"__resource":"res://materials/outline_3d.tres"}}}'
//   next_pass is a property of the MATERIAL, not of the node, so it is reached with an
//   indexed_properties path. Assign the base material first — setting next_pass on a null
//   material_override fails.
//
// Drive it:
//   GDScript:  var outline := (mesh.material_override.next_pass as ShaderMaterial)
//              outline.set_shader_parameter("outline_width", 0.04)
//              Hide the outline with 0.0 rather than clearing next_pass — cheaper, no re-compile.
//   Tween:     create_tween().tween_method(func(v: float) -> void: outline.set_shader_parameter("outline_width", v), 0.0, 0.03, 0.15)
//   Animation: value track on "Character:material_override:next_pass:shader_parameter/outline_width".
//
// Sharing: one outline material for the whole game is normal. Per-mesh width:
//   `instance uniform float outline_width;` + mesh.set_instance_shader_parameter(...).

shader_type spatial;
render_mode unshaded, cull_front, shadows_disabled, depth_draw_opaque;

uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float outline_width : hint_range(0.0, 0.5, 0.001) = 0.02;
uniform bool screen_constant = false;
uniform float max_distance : hint_range(0.0, 500.0, 0.5) = 0.0;

varying float visible_here;

void vertex() {
	// Distance from the camera in view space (view space looks down -Z).
	float view_distance = max(-(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z, 0.0);

	float width = outline_width;
	if (screen_constant) {
		// Growing the hull in proportion to the distance cancels the perspective divide, so the
		// outline stays the same number of pixels wide at any range.
		width *= view_distance;
	}
	VERTEX += normalize(NORMAL) * width;

	visible_here = (max_distance > 0.0 && view_distance > max_distance) ? 0.0 : 1.0;
}

void fragment() {
	// width 0 would put the hull exactly on the mesh surface and z-fight with it, so drop it.
	if (outline_width <= 0.0 || visible_here < 0.5) {
		discard;
	}
	ALBEDO = outline_color.rgb;
}
