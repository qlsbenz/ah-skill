class_name GodotSkillSpatialDescribe
extends RefCounted

# Reads 2D and 3D world placement back as numbers and ASCII, so a caller with no
# vision can answer the questions only a screenshot used to answer: is the player
# inside the camera view, is it standing on the floor or sunk into it, does the 3D
# scene have a camera and a light at all, is the mesh behind the camera, did the
# level end up where it was meant to.
#
# Pure by design, like image_describe.gd: it never logs, never writes a file and
# never needs a rendering device. Every number comes from node transforms,
# resource metadata (texture sizes, SpriteFrames frame textures, Shape2D.get_rect,
# Shape3D.get_debug_mesh, Mesh.get_aabb, TileSet.tile_size) and the physics direct
# space state — all exact under --headless with the dummy renderer. Callers own
# the IO, the gating and the error reporting.
#
# The caller must await a physics frame before calling describe() when
# embedded_in_static matters: the space state only reflects transforms that have
# already been flushed to the physics server.

# Every finding id this module can emit. `fail_on: ["any"]` expands to this list,
# and an unknown id is rejected by the caller against it.
const FINDING_TYPES = [
    "no_camera_2d", "no_camera_3d", "no_light_3d",
    "not_on_screen", "not_in_frustum", "behind_camera", "occluded",
    "embedded_in_static", "far_from_origin", "zero_scale", "invisible_expected"
]

const DEFAULT_MAX_NODES = 200
const DEFAULT_ASCII_COLS = 64
const DEFAULT_ASCII_ROWS = 24
const MIN_ASCII_COLS = 8
const MAX_ASCII_COLS = 200
const MIN_ASCII_ROWS = 4
const MAX_ASCII_ROWS = 100

# Letters are handed out in walk order, so the same scene always produces the
# same legend. Nodes past the end of the alphabet share OVERFLOW_CHAR.
const ASCII_LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
const OVERFLOW_CHAR = "*"
const CAMERA_CHAR = "@"
const VIEW_CHAR = ":"
const EMPTY_CHAR = " "

# A character cell is about twice as tall as it is wide; the ASCII bounds are
# widened so one cell always covers a square patch of the world.
const CELL_ASPECT = 2.0

# Anything this far from the origin is a placement mistake, not a level.
const FAR_FROM_ORIGIN = 100000.0

# intersect_shape reports a body that merely rests on the floor as an overlap,
# so the query shape is shrunk before asking. One pixel in 2D and one centimetre
# in 3D are below any collision an author would call "embedded" and above the
# solver's own resting slop.
const EMBED_MARGIN_2D = -1.0
const EMBED_MARGIN_3D = -0.01
const EMBED_MAX_RESULTS = 8

# A TileMapLayer or GridMap with more cells than this is measured from its used
# rect's corners only, so a huge level cannot make one report take seconds.
const MAX_SCANNED_CELLS = 20000

# --- entry point ------------------------------------------------------------

static func describe(subtree_root: Node, scene_root: Node, options: Dictionary) -> Dictionary:
    var viewport := subtree_root.get_viewport()
    var dimension := str(options.get("dimension", "auto"))
    if dimension == "auto":
        dimension = detect_dimension(subtree_root)

    var class_filter: Array = []
    var raw_classes: Variant = options.get("classes", [])
    if raw_classes is Array:
        for raw_name in raw_classes as Array:
            class_filter.append(str(raw_name))

    var include_hidden := bool(options.get("include_hidden", false))
    var max_nodes: int = maxi(int(options.get("max_nodes", DEFAULT_MAX_NODES)), 1)
    var expect_on_screen: Array = _string_array(options.get("expect_on_screen", []))
    var expect_visible: Array = _string_array(options.get("expect_visible", []))

    var report := {}
    if dimension == "3d":
        report = _describe_3d(subtree_root, scene_root, viewport, options, class_filter, include_hidden, max_nodes, expect_on_screen, expect_visible)
    else:
        report = _describe_2d(subtree_root, scene_root, viewport, options, class_filter, include_hidden, max_nodes, expect_on_screen, expect_visible)
    # `dimension` leads the payload: it decides how every other key reads.
    var out := {"dimension": dimension}
    out.merge(report)
    return out


static func detect_dimension(subtree_root: Node) -> String:
    # A scene holding any Node3D is a 3D scene even when it also carries a 2D
    # HUD; ui_report already covers the HUD, and mixing both in one map would
    # put two unrelated coordinate systems on the same grid.
    return "3d" if _has_node3d(subtree_root) else "2d"


static func _has_node3d(node: Node) -> bool:
    if node is Node3D:
        return true
    for child in node.get_children():
        if _has_node3d(child):
            return true
    return false

# --- 2D ---------------------------------------------------------------------

static func _describe_2d(subtree_root: Node, scene_root: Node, viewport: Viewport, options: Dictionary, class_filter: Array, include_hidden: bool, max_nodes: int, expect_on_screen: Array, expect_visible: Array) -> Dictionary:
    var visible_rect := viewport.get_visible_rect() if viewport != null else Rect2()
    var canvas_transform := viewport.get_canvas_transform() if viewport != null else Transform2D()
    var camera: Camera2D = viewport.get_camera_2d() if viewport != null else null
    # The canvas transform already carries the active camera's zoom, offset,
    # rotation, limits and smoothing state at this exact moment, so inverting it
    # is the only view rect that matches what the frame would have drawn.
    var view_rect := canvas_transform.affine_inverse() * visible_rect

    var collected: Array = []
    _collect_2d(subtree_root, scene_root, include_hidden, class_filter, collected)

    var entries: Array = []
    var drawables: Array = []
    # path -> what expect_on_screen needs to know, kept apart from the report's
    # own entries so the gate never depends on a key the report may drop.
    var verdicts := {}
    var on_screen_count := 0
    var off_screen_count := 0
    var screen_space_count := 0
    var content_rect := Rect2()
    var has_content := false
    var world_content_rect := Rect2()
    var has_world_content := false
    var total := collected.size()
    var truncated := total > max_nodes
    var kept: Array = collected.slice(0, max_nodes) if truncated else collected

    for record in kept:
        var item: CanvasItem = record["node"]
        var local_rect: Rect2 = record["rect"]
        var world_rect: Rect2 = item.get_global_transform() * local_rect
        var screen_rect: Rect2 = item.get_global_transform_with_canvas() * local_rect
        var is_screen_space: bool = record["screen_space"]
        var is_camera: bool = record["kind"] == "camera"
        var on_screen := visible_rect.intersects(screen_rect) or (screen_rect.size == Vector2.ZERO and visible_rect.has_point(screen_rect.position))
        if is_screen_space:
            screen_space_count += 1
        # "Can the camera see the camera" is not a question. A camera is located
        # on the map but never counted as on or off screen.
        if not is_camera:
            if on_screen:
                on_screen_count += 1
            else:
                off_screen_count += 1
        var entry := {
            "path": record["path"],
            "class": item.get_class(),
            "space": "screen" if is_screen_space else "world",
            "kind": record["kind"],
            "rect": _rect_array(world_rect),
            "z_index": int(item.z_index)
        }
        if not is_camera:
            entry["screen_rect"] = _rect_array(screen_rect)
            entry["on_screen"] = on_screen
            verdicts[str(record["path"])] = {
                "on_screen": on_screen, "class": item.get_class(),
                "rect": _rect_array(world_rect), "screen_rect": _rect_array(screen_rect)
            }
        if not item.is_visible_in_tree():
            entry["visible"] = false
        if record["kind"] == "point":
            entry["point"] = true
        entries.append(entry)
        # The map is a world map. A CanvasLayer child is placed in screen space,
        # so its numbers belong in `nodes` (with `space: "screen"`) but never on
        # the same grid as the world — and never in the world's bounds either.
        # The camera has its own marker, so it is not drawn as a lettered rect.
        if not is_screen_space and record["kind"] != "camera":
            var drawable := {"path": record["path"], "class": item.get_class(), "rect": world_rect, "screen": false}
            # A tile layer is drawn cell by cell rather than as one filled
            # block, so the ASCII map has the shape of the level that was
            # painted instead of the shape of its bounding box.
            if item is TileMapLayer:
                drawable["tilemap"] = item
            drawables.append(drawable)
            world_content_rect = world_content_rect.merge(world_rect) if has_world_content else world_rect
            has_world_content = true
            content_rect = content_rect.merge(world_rect) if has_content else world_rect
            has_content = true

    var findings: Array = []

    if camera == null and has_world_content and not visible_rect.encloses(world_content_rect):
        findings.append(_finding("no_camera_2d", ".", "No active Camera2D, so the view is the raw viewport %s, but the scene's content spans %s — everything outside that rect is off screen. Add a Camera2D (add_node Camera2D) or move the content inside the viewport." % [
            str(_rect_array(visible_rect)), str(_rect_array(world_content_rect))
        ]))

    for record in kept:
        var item: CanvasItem = record["node"]
        var node_path: String = record["path"]
        if item is Node2D:
            var node2d := item as Node2D
            var global_scale := node2d.global_scale
            if is_zero_approx(global_scale.x) or is_zero_approx(global_scale.y):
                findings.append(_finding("zero_scale", node_path, "%s (%s) has global scale (%s, %s) — it draws nothing at that size. Check every scale on the path from the scene root." % [
                    node_path, item.get_class(), _round_number(global_scale.x), _round_number(global_scale.y)
                ]))
            var global_position := node2d.global_position
            if absf(global_position.x) > FAR_FROM_ORIGIN or absf(global_position.y) > FAR_FROM_ORIGIN:
                findings.append(_finding("far_from_origin", node_path, "%s (%s) sits at (%s, %s), more than %d units from the origin — usually an accumulated offset or a units mix-up." % [
                    node_path, item.get_class(), _round_number(global_position.x), _round_number(global_position.y), int(FAR_FROM_ORIGIN)
                ]))

    findings.append_array(_embedded_2d(subtree_root, scene_root, float(options.get("embed_margin", EMBED_MARGIN_2D))))
    findings.append_array(_expect_visible_findings(subtree_root, scene_root, expect_visible))

    for raw_path in expect_on_screen:
        var wanted := str(raw_path)
        if not verdicts.has(wanted):
            var node := _resolve(subtree_root, scene_root, wanted)
            var reason := "it has no measurable rect (no texture, shape, tiles or polygon of its own)"
            if node == null:
                reason = "no node exists at that path in the reported subtree"
            elif not (node is CanvasItem):
                reason = "it is a %s, which is not a CanvasItem" % node.get_class()
            elif not (node as CanvasItem).is_visible_in_tree():
                reason = "it is not visible in tree, so it was left out of the report (set include_hidden to list it)"
            elif node is Camera2D:
                reason = "it is the camera; ask about what the camera should see instead"
            findings.append(_finding("not_on_screen", wanted, "expect_on_screen: %s is not in the report — %s." % [wanted, reason]))
            continue
        var verdict: Dictionary = verdicts[wanted]
        if bool(verdict["on_screen"]):
            continue
        findings.append(_finding("not_on_screen", wanted, "expect_on_screen: %s (%s) draws at screen rect %s, entirely outside the %s viewport. Its world rect is %s and the camera sees %s." % [
            wanted, str(verdict["class"]), str(verdict["screen_rect"]),
            str(_rect_array(visible_rect)), str(verdict["rect"]), str(_rect_array(view_rect))
        ]))

    var camera_info: Dictionary = {}
    if camera != null:
        camera_info = {
            "path": _path_of(scene_root, camera),
            "class": camera.get_class(),
            "position": _vector2_array(camera.global_position),
            "center": _vector2_array(camera.get_screen_center_position()),
            "zoom": _vector2_array(camera.zoom),
            "offset": _vector2_array(camera.offset),
            "rotation_degrees": _round_number(rad_to_deg(canvas_transform.affine_inverse().get_rotation())),
            "view_rect": _rect_array(view_rect)
        }
        if camera.limit_left > -10000000 or camera.limit_top > -10000000 or camera.limit_right < 10000000 or camera.limit_bottom < 10000000:
            camera_info["limits"] = {
                "left": camera.limit_left, "top": camera.limit_top,
                "right": camera.limit_right, "bottom": camera.limit_bottom
            }

    var report := {
        "passed": true,
        "rect_format": "[x, y, width, height]",
        "viewport": {"width": _round_number(visible_rect.size.x), "height": _round_number(visible_rect.size.y)},
        "view_rect": _rect_array(view_rect),
        "camera": camera_info,
        "counts": {
            "nodes": entries.size(),
            "on_screen": on_screen_count,
            "off_screen": off_screen_count,
            "screen_space": screen_space_count,
            "findings": findings.size()
        },
        "truncated": truncated,
        "total_nodes": total,
        "nodes": entries,
        "findings": findings
    }
    if truncated:
        report["truncation_note"] = "max_nodes %d of %d nodes listed; raise max_nodes or narrow the walk with node_path/classes." % [max_nodes, total]
    if bool(options.get("ascii", false)):
        var bounds_mode := str(options.get("ascii_bounds", "content"))
        var size_pair := _ascii_size(options)
        var base_bounds := view_rect
        if bounds_mode == "content":
            base_bounds = content_rect.merge(Rect2(camera.global_position, Vector2.ZERO)) if (has_content and camera != null) else (content_rect if has_content else view_rect)
        _apply_ascii(report, _ascii_map(drawables, base_bounds, size_pair[0], size_pair[1], view_rect if camera != null else Rect2(), camera_info, 0.0, false))
    return report


static func _collect_2d(node: Node, scene_root: Node, include_hidden: bool, class_filter: Array, out: Array) -> void:
    if node is CanvasItem:
        var item := node as CanvasItem
        if include_hidden or item.is_visible_in_tree():
            if _passes_class_filter(item, class_filter):
                var measured := _local_rect_2d(item)
                if not measured.is_empty():
                    out.append({
                        "node": item,
                        "path": _path_of(scene_root, item),
                        "rect": measured["rect"],
                        "kind": measured["kind"],
                        "screen_space": item.get_canvas_layer_node() != null
                    })
    for child in node.get_children():
        _collect_2d(child, scene_root, include_hidden, class_filter, out)


static func _local_rect_2d(item: CanvasItem) -> Dictionary:
    # Every branch reads the same metadata the renderer would: a texture's size,
    # a shape's bounding rect, a tileset's tile size. Nothing here needs a GPU.
    if item is Sprite2D:
        var sprite := item as Sprite2D
        if sprite.texture == null:
            return {}
        return {"rect": sprite.get_rect(), "kind": "texture"}
    if item is AnimatedSprite2D:
        var animated := item as AnimatedSprite2D
        var frames := animated.sprite_frames
        if frames == null or not frames.has_animation(animated.animation):
            return {}
        var frame_count := frames.get_frame_count(animated.animation)
        if frame_count <= 0:
            return {}
        var texture := frames.get_frame_texture(animated.animation, clampi(animated.frame, 0, frame_count - 1))
        if texture == null:
            return {}
        var frame_size := texture.get_size()
        var origin := animated.offset
        if animated.centered:
            origin -= frame_size * 0.5
        return {"rect": Rect2(origin, frame_size), "kind": "texture"}
    if item is TileMapLayer:
        return _tilemap_rect(item as TileMapLayer)
    if item is CollisionShape2D:
        var collision := item as CollisionShape2D
        if collision.shape == null or collision.shape is WorldBoundaryShape2D:
            return {}
        return {"rect": collision.shape.get_rect(), "kind": "shape"}
    if item is CollisionPolygon2D:
        var collision_polygon := item as CollisionPolygon2D
        if collision_polygon.polygon.size() < 2:
            return {}
        return {"rect": _points_rect(collision_polygon.polygon), "kind": "polygon"}
    if item is Polygon2D:
        var polygon := item as Polygon2D
        if polygon.polygon.size() < 2:
            return {}
        return {"rect": Rect2(polygon.offset, Vector2.ZERO).merge(_points_rect(polygon.polygon)), "kind": "polygon"}
    if item is Line2D:
        var line := item as Line2D
        if line.points.size() < 2:
            return {}
        return {"rect": _points_rect(line.points).grow(line.width * 0.5), "kind": "polygon"}
    if item is PointLight2D:
        var light := item as PointLight2D
        if light.texture == null:
            return {}
        var light_size := light.texture.get_size() * light.texture_scale
        return {"rect": Rect2(light.offset - light_size * 0.5, light_size), "kind": "light"}
    if item is CollisionObject2D:
        return _collision_object_2d_rect(item as CollisionObject2D)
    if item is Control:
        return {"rect": Rect2(Vector2.ZERO, (item as Control).size), "kind": "control"}
    if item is Camera2D:
        return {"rect": Rect2(Vector2.ZERO, Vector2.ZERO), "kind": "camera"}
    if item is Marker2D:
        return {"rect": Rect2(Vector2.ZERO, Vector2.ZERO), "kind": "point"}
    return {}


static func _tilemap_rect(layer: TileMapLayer) -> Dictionary:
    if layer.tile_set == null:
        return {}
    var used := layer.get_used_rect()
    if used.size.x <= 0 or used.size.y <= 0:
        return {}
    var tile_size := Vector2(layer.tile_set.tile_size)
    # map_to_local places the centre of a cell, and the four corner cells bound
    # every tile shape the engine ships (square, isometric, half-offset), so the
    # rect is right without walking thousands of cells.
    var corners: Array[Vector2i] = [
        Vector2i(used.position.x, used.position.y),
        Vector2i(used.end.x - 1, used.position.y),
        Vector2i(used.position.x, used.end.y - 1),
        Vector2i(used.end.x - 1, used.end.y - 1)
    ]
    var rect := Rect2(layer.map_to_local(corners[0]), Vector2.ZERO)
    for cell in corners:
        rect = rect.expand(layer.map_to_local(cell))
    rect = rect.grow_individual(tile_size.x * 0.5, tile_size.y * 0.5, tile_size.x * 0.5, tile_size.y * 0.5)
    return {"rect": rect, "kind": "tiles"}


static func _collision_object_2d_rect(body: CollisionObject2D) -> Dictionary:
    var rect := Rect2()
    var has := false
    for raw_owner in body.get_shape_owners():
        var owner_id := int(raw_owner)
        var owner_transform: Transform2D = body.shape_owner_get_transform(owner_id)
        for index in range(body.shape_owner_get_shape_count(owner_id)):
            var shape: Shape2D = body.shape_owner_get_shape(owner_id, index)
            if shape == null or shape is WorldBoundaryShape2D:
                continue
            var shape_rect: Rect2 = owner_transform * shape.get_rect()
            rect = rect.merge(shape_rect) if has else shape_rect
            has = true
    if not has:
        return {}
    return {"rect": rect, "kind": "shapes"}


static func _embedded_2d(subtree_root: Node, scene_root: Node, margin: float) -> Array:
    var bodies: Array = []
    _collect_class(subtree_root, "PhysicsBody2D", bodies)
    var findings: Array = []
    for raw_body in bodies:
        var body: PhysicsBody2D = raw_body
        if not (body is CharacterBody2D or body is RigidBody2D):
            continue
        if not body.is_inside_tree():
            continue
        var space := body.get_world_2d().direct_space_state
        if space == null:
            continue
        var query := PhysicsShapeQueryParameters2D.new()
        query.exclude = [body.get_rid()]
        query.collision_mask = body.collision_mask
        query.collide_with_areas = false
        query.collide_with_bodies = true
        query.margin = minf(margin, 0.0)
        for raw_owner in body.get_shape_owners():
            var owner_id := int(raw_owner)
            if body.is_shape_owner_disabled(owner_id):
                continue
            var owner_transform: Transform2D = body.global_transform * body.shape_owner_get_transform(owner_id)
            for index in range(body.shape_owner_get_shape_count(owner_id)):
                var shape: Shape2D = body.shape_owner_get_shape(owner_id, index)
                if shape == null:
                    continue
                query.shape = shape
                query.transform = owner_transform
                for raw_hit in space.intersect_shape(query, EMBED_MAX_RESULTS):
                    var hit: Dictionary = raw_hit
                    var collider_value: Variant = hit["collider"]
                    if not (collider_value is Node):
                        continue
                    var collider: Node = collider_value
                    if not _is_static_collision(collider):
                        continue
                    findings.append(_finding("embedded_in_static", _path_of(scene_root, body), "%s (%s) overlaps the static collision of %s (%s) right now — it is inside the wall/floor, not resting on it. Move it out along its up axis, or shrink its collision shape." % [
                        _path_of(scene_root, body), body.get_class(),
                        _path_of(scene_root, collider), collider.get_class()
                    ]))
                    break
    return findings


static func _is_static_collision(collider: Node) -> bool:
    if collider is StaticBody2D or collider is StaticBody3D:
        return true
    if collider is TileMapLayer or collider is GridMap:
        return true
    return ClassDB.is_parent_class(collider.get_class(), "TileMap")

# --- 3D ---------------------------------------------------------------------

static func _describe_3d(subtree_root: Node, scene_root: Node, viewport: Viewport, options: Dictionary, class_filter: Array, include_hidden: bool, max_nodes: int, expect_on_screen: Array, expect_visible: Array) -> Dictionary:
    var visible_rect := viewport.get_visible_rect() if viewport != null else Rect2()
    var camera: Camera3D = viewport.get_camera_3d() if viewport != null else null
    var planes: Array[Plane] = camera.get_frustum() if camera != null else ([] as Array[Plane])

    var collected: Array = []
    _collect_3d(subtree_root, scene_root, include_hidden, class_filter, collected)

    var entries: Array = []
    var drawables: Array = []
    # path -> what expect_on_screen needs to know (see the 2D walk).
    var verdicts := {}
    var in_frustum_count := 0
    var out_of_frustum_count := 0
    var content_aabb := AABB()
    var has_content := false
    var has_visual := false
    var farthest := 0.0
    var total := collected.size()
    var truncated := total > max_nodes
    var kept: Array = collected.slice(0, max_nodes) if truncated else collected

    for record in kept:
        var node: Node3D = record["node"]
        var world_aabb: AABB = record["aabb"]
        var center := world_aabb.get_center()
        var is_camera: bool = record["kind"] == "camera"
        var behind := camera != null and camera.is_position_behind(center)
        var in_frustum := camera != null and _aabb_in_frustum(planes, world_aabb)
        # A camera is located on the map but never counted as in or out of its
        # own frustum.
        if not is_camera:
            if in_frustum:
                in_frustum_count += 1
            else:
                out_of_frustum_count += 1
        var entry := {
            "path": record["path"],
            "class": node.get_class(),
            "kind": record["kind"],
            "aabb": _aabb_array(world_aabb),
            "position": _vector3_array(node.global_position)
        }
        if not is_camera:
            entry["in_frustum"] = in_frustum
            entry["on_screen"] = in_frustum
        if camera != null and not is_camera:
            var distance := camera.global_position.distance_to(center)
            entry["distance_to_camera"] = _round_number(distance)
            entry["behind_camera"] = behind
            if not behind:
                entry["screen_pos"] = _vector2_array(camera.unproject_position(center))
            farthest = maxf(farthest, distance)
        if not is_camera:
            verdicts[str(record["path"])] = {
                "in_frustum": in_frustum, "behind": behind, "class": node.get_class(),
                "aabb": _aabb_array(world_aabb), "position": _vector3_array(node.global_position)
            }
        if not node.visible or not node.is_visible_in_tree():
            entry["visible"] = node.is_visible_in_tree()
        entries.append(entry)
        # The camera gets its own marker on the map instead of a letter.
        if record["kind"] != "camera":
            var drawable := {
                "path": record["path"], "class": node.get_class(),
                "rect": Rect2(Vector2(world_aabb.position.x, world_aabb.position.z), Vector2(world_aabb.size.x, world_aabb.size.z)),
                "screen": false
            }
            if node is GridMap:
                drawable["gridmap"] = node
            drawables.append(drawable)
        content_aabb = content_aabb.merge(world_aabb) if has_content else world_aabb
        has_content = true
        # "Is there a camera / a light" is only a question when something would
        # actually be rendered: a collision shape or a marker draws nothing.
        if record["kind"] == "visual" or record["kind"] == "tiles":
            has_visual = true

    var findings: Array = []
    if camera == null and has_visual:
        findings.append(_finding("no_camera_3d", ".", "No active Camera3D in the scene, so a running build renders nothing but the clear colour. Add one (add_node Camera3D) and point it at the content, whose bounds are %s." % str(_aabb_array(content_aabb))))

    var light_check := _light_check_3d(subtree_root, viewport, camera)
    if has_visual and not bool(light_check["lit"]):
        findings.append(_finding("no_light_3d", ".", "No visible Light3D with energy above zero and no Environment ambient/sky light — a lit (non-unshaded) material renders black here. Add a DirectionalLight3D, or a WorldEnvironment whose Environment sets ambient_light_source/background to a sky or colour. %s" % str(light_check["detail"])))

    for record in kept:
        var node: Node3D = record["node"]
        var node_path: String = record["path"]
        var node_scale := node.global_basis.get_scale()
        if is_zero_approx(node_scale.x) or is_zero_approx(node_scale.y) or is_zero_approx(node_scale.z):
            findings.append(_finding("zero_scale", node_path, "%s (%s) has global scale (%s, %s, %s) — it draws nothing at that size." % [
                node_path, node.get_class(), _round_number(node_scale.x), _round_number(node_scale.y), _round_number(node_scale.z)
            ]))
        var node_position := node.global_position
        if absf(node_position.x) > FAR_FROM_ORIGIN or absf(node_position.y) > FAR_FROM_ORIGIN or absf(node_position.z) > FAR_FROM_ORIGIN:
            findings.append(_finding("far_from_origin", node_path, "%s (%s) sits at (%s, %s, %s), more than %d units from the origin — usually an accumulated offset or a units mix-up." % [
                node_path, node.get_class(),
                _round_number(node_position.x), _round_number(node_position.y), _round_number(node_position.z), int(FAR_FROM_ORIGIN)
            ]))

    findings.append_array(_embedded_3d(subtree_root, scene_root, float(options.get("embed_margin", EMBED_MARGIN_3D))))
    findings.append_array(_expect_visible_findings(subtree_root, scene_root, expect_visible))

    for raw_path in expect_on_screen:
        var wanted := str(raw_path)
        if not verdicts.has(wanted):
            var node := _resolve(subtree_root, scene_root, wanted)
            var reason := "it has no measurable AABB (no mesh, shape or tiles of its own)"
            if node == null:
                reason = "no node exists at that path in the reported subtree"
            elif not (node is Node3D):
                reason = "it is a %s, which is not a Node3D" % node.get_class()
            elif not (node as Node3D).is_visible_in_tree():
                reason = "it is not visible in tree, so it was left out of the report (set include_hidden to list it)"
            elif node is Camera3D:
                reason = "it is the camera; ask about what the camera should see instead"
            findings.append(_finding("not_in_frustum", wanted, "expect_on_screen: %s is not in the report — %s." % [wanted, reason]))
            continue
        var verdict: Dictionary = verdicts[wanted]
        if bool(verdict["in_frustum"]):
            continue
        if camera == null:
            findings.append(_finding("not_in_frustum", wanted, "expect_on_screen: %s (%s) cannot be in view — the scene has no active Camera3D." % [wanted, str(verdict["class"])]))
            continue
        if bool(verdict["behind"]):
            findings.append(_finding("behind_camera", wanted, "expect_on_screen: %s (%s) at %s is behind the camera at %s looking %s — turn the camera around or move the node in front of it." % [
                wanted, str(verdict["class"]), str(verdict["position"]),
                str(_vector3_array(camera.global_position)), str(_vector3_array(-camera.global_basis.z))
            ]))
            continue
        findings.append(_finding("not_in_frustum", wanted, "expect_on_screen: %s (%s) with world AABB %s is outside the camera frustum (camera at %s looking %s, fov %s, far %s)." % [
            wanted, str(verdict["class"]), str(verdict["aabb"]),
            str(_vector3_array(camera.global_position)), str(_vector3_array(-camera.global_basis.z)),
            _round_number(camera.fov), _round_number(camera.far)
        ]))

    if bool(options.get("check_occlusion", false)) and camera != null:
        findings.append_array(_occlusion_3d(subtree_root, scene_root, camera, expect_on_screen, verdicts, kept))

    var camera_info: Dictionary = {}
    if camera != null:
        camera_info = {
            "path": _path_of(scene_root, camera),
            "class": camera.get_class(),
            "position": _vector3_array(camera.global_position),
            "forward": _vector3_array(-camera.global_basis.z),
            "projection": "orthogonal" if camera.projection == Camera3D.PROJECTION_ORTHOGONAL else ("frustum" if camera.projection == Camera3D.PROJECTION_FRUSTUM else "perspective"),
            "fov": _round_number(camera.fov),
            "size": _round_number(camera.size),
            "near": _round_number(camera.near),
            "far": _round_number(camera.far)
        }

    var report := {
        "passed": true,
        "rect_format": "[x, y, width, height]",
        "aabb_format": "[x, y, z, size_x, size_y, size_z]",
        "viewport": {"width": _round_number(visible_rect.size.x), "height": _round_number(visible_rect.size.y)},
        "camera": camera_info,
        "lighting": light_check,
        "counts": {
            "nodes": entries.size(),
            "on_screen": in_frustum_count,
            "off_screen": out_of_frustum_count,
            "screen_space": 0,
            "findings": findings.size()
        },
        "truncated": truncated,
        "total_nodes": total,
        "nodes": entries,
        "findings": findings
    }
    if truncated:
        report["truncation_note"] = "max_nodes %d of %d nodes listed; raise max_nodes or narrow the walk with node_path/classes." % [max_nodes, total]
    if bool(options.get("ascii", false)):
        var bounds_mode := str(options.get("ascii_bounds", "content"))
        var size_pair := _ascii_size(options)
        var footprint := _frustum_footprint(camera, visible_rect, maxf(farthest, 10.0))
        var content_xz := Rect2()
        if has_content:
            content_xz = Rect2(Vector2(content_aabb.position.x, content_aabb.position.z), Vector2(content_aabb.size.x, content_aabb.size.z))
            if camera != null:
                content_xz = content_xz.expand(Vector2(camera.global_position.x, camera.global_position.z))
        var base_bounds := footprint
        if bounds_mode == "content" and has_content:
            base_bounds = content_xz
        # "camera" bounds with no camera, or "content" bounds with nothing to
        # frame, would otherwise be a zero-size box that maps every node to the
        # same cell. Fall back rather than draw a lie.
        if base_bounds.size == Vector2.ZERO:
            base_bounds = content_xz if content_xz.size != Vector2.ZERO else Rect2(-10, -10, 20, 20)
        var facing := 0.0
        if camera != null:
            var forward := -camera.global_basis.z
            facing = atan2(forward.z, forward.x)
        _apply_ascii(report, _ascii_map(drawables, base_bounds, size_pair[0], size_pair[1], footprint, camera_info, facing, true))
    return report


static func _collect_3d(node: Node, scene_root: Node, include_hidden: bool, class_filter: Array, out: Array) -> void:
    if node is Node3D:
        var spatial := node as Node3D
        if include_hidden or spatial.is_visible_in_tree():
            if _passes_class_filter(spatial, class_filter):
                var measured := _local_aabb_3d(spatial)
                if not measured.is_empty():
                    out.append({
                        "node": spatial,
                        "path": _path_of(scene_root, spatial),
                        "aabb": spatial.global_transform * (measured["aabb"] as AABB),
                        "kind": measured["kind"]
                    })
    for child in node.get_children():
        _collect_3d(child, scene_root, include_hidden, class_filter, out)


static func _local_aabb_3d(spatial: Node3D) -> Dictionary:
    if spatial is Camera3D:
        return {"aabb": AABB(), "kind": "camera"}
    if spatial is Light3D:
        return {"aabb": AABB(), "kind": "light"}
    if spatial is GridMap:
        return _gridmap_aabb(spatial as GridMap)
    if spatial is CollisionShape3D:
        var collision := spatial as CollisionShape3D
        if collision.shape == null or collision.shape is WorldBoundaryShape3D:
            return {}
        return {"aabb": _shape_3d_aabb(collision.shape), "kind": "shape"}
    if spatial is CollisionPolygon3D:
        var collision_polygon := spatial as CollisionPolygon3D
        if collision_polygon.polygon.size() < 2:
            return {}
        var flat := _points_rect(collision_polygon.polygon)
        var depth: float = maxf(collision_polygon.depth, 0.001)
        return {"aabb": AABB(Vector3(flat.position.x, flat.position.y, -depth * 0.5), Vector3(flat.size.x, flat.size.y, depth)), "kind": "polygon"}
    if spatial is VisualInstance3D:
        var visual := spatial as VisualInstance3D
        var aabb := visual.get_aabb()
        if aabb.size == Vector3.ZERO:
            return {}
        return {"aabb": aabb, "kind": "visual"}
    if spatial is CollisionObject3D:
        return _collision_object_3d_aabb(spatial as CollisionObject3D)
    if spatial is Marker3D:
        return {"aabb": AABB(), "kind": "point"}
    return {}


static func _shape_3d_aabb(shape: Shape3D) -> AABB:
    # Every Shape3D can draw itself for the editor's collision gizmo, and that
    # debug mesh's AABB is the shape's bounds — no per-class table to keep right.
    var debug_mesh := shape.get_debug_mesh()
    if debug_mesh == null:
        return AABB()
    return debug_mesh.get_aabb()


static func _collision_object_3d_aabb(body: CollisionObject3D) -> Dictionary:
    var aabb := AABB()
    var has := false
    for raw_owner in body.get_shape_owners():
        var owner_id := int(raw_owner)
        var owner_transform: Transform3D = body.shape_owner_get_transform(owner_id)
        for index in range(body.shape_owner_get_shape_count(owner_id)):
            var shape: Shape3D = body.shape_owner_get_shape(owner_id, index)
            if shape == null or shape is WorldBoundaryShape3D:
                continue
            var shape_aabb: AABB = owner_transform * _shape_3d_aabb(shape)
            aabb = aabb.merge(shape_aabb) if has else shape_aabb
            has = true
    if not has:
        return {}
    return {"aabb": aabb, "kind": "shapes"}


static func _gridmap_aabb(grid: GridMap) -> Dictionary:
    if grid.mesh_library == null:
        return {}
    var cells := grid.get_used_cells()
    if cells.is_empty():
        return {}
    var half := grid.cell_size * 0.5
    var aabb := AABB(grid.map_to_local(cells[0]) - half, grid.cell_size)
    var limit: int = mini(cells.size(), MAX_SCANNED_CELLS)
    for index in range(limit):
        aabb = aabb.merge(AABB(grid.map_to_local(cells[index]) - half, grid.cell_size))
    return {"aabb": aabb, "kind": "tiles"}


static func _aabb_in_frustum(planes: Array[Plane], aabb: AABB) -> bool:
    # Camera3D.get_frustum() hands back planes whose normals point OUT of the
    # frustum (verified on 4.7: the camera itself is at +0.05 from the near
    # plane), so the box is outside as soon as even its most inward corner sits
    # on the positive side of one plane.
    if planes.is_empty():
        return false
    for plane in planes:
        if plane.distance_to(aabb.get_support(-plane.normal)) > 0.0:
            return false
    return true


static func _light_check_3d(subtree_root: Node, viewport: Viewport, camera: Camera3D) -> Dictionary:
    var lights: Array = []
    _collect_class(subtree_root.get_tree().current_scene if subtree_root.get_tree() != null and subtree_root.get_tree().current_scene != null else subtree_root, "Light3D", lights)
    var live_lights: Array = []
    for raw_light in lights:
        var light: Light3D = raw_light
        if light.is_visible_in_tree() and light.light_energy > 0.0:
            live_lights.append(light.get_class())
    var environment: Environment = null
    if camera != null and camera.environment != null:
        environment = camera.environment
    elif viewport != null and viewport.find_world_3d() != null:
        environment = viewport.find_world_3d().environment
        if environment == null:
            environment = viewport.find_world_3d().fallback_environment
    var ambient := false
    var detail := "Lights found: %d." % live_lights.size()
    if environment != null:
        var source := environment.ambient_light_source
        if source == Environment.AMBIENT_SOURCE_SKY:
            ambient = environment.sky != null
        elif source == Environment.AMBIENT_SOURCE_COLOR:
            ambient = environment.ambient_light_energy > 0.0
        elif source == Environment.AMBIENT_SOURCE_BG:
            ambient = environment.background_mode == Environment.BG_SKY and environment.sky != null
        detail += " Environment present (ambient_light_source %d, background_mode %d, sky %s)." % [
            int(source), int(environment.background_mode), "yes" if environment.sky != null else "no"
        ]
    else:
        detail += " No Environment on the camera, the World3D or the project's fallback."
    return {
        "lit": not live_lights.is_empty() or ambient,
        "lights": live_lights,
        "environment_light": ambient,
        "detail": detail
    }


static func _embedded_3d(subtree_root: Node, scene_root: Node, margin: float) -> Array:
    var bodies: Array = []
    _collect_class(subtree_root, "PhysicsBody3D", bodies)
    var findings: Array = []
    for raw_body in bodies:
        var body: PhysicsBody3D = raw_body
        if not (body is CharacterBody3D or body is RigidBody3D):
            continue
        if not body.is_inside_tree():
            continue
        var space := body.get_world_3d().direct_space_state
        if space == null:
            continue
        var query := PhysicsShapeQueryParameters3D.new()
        query.exclude = [body.get_rid()]
        query.collision_mask = body.collision_mask
        query.collide_with_areas = false
        query.collide_with_bodies = true
        query.margin = minf(margin, 0.0)
        for raw_owner in body.get_shape_owners():
            var owner_id := int(raw_owner)
            if body.is_shape_owner_disabled(owner_id):
                continue
            var owner_transform: Transform3D = body.global_transform * body.shape_owner_get_transform(owner_id)
            for index in range(body.shape_owner_get_shape_count(owner_id)):
                var shape: Shape3D = body.shape_owner_get_shape(owner_id, index)
                if shape == null:
                    continue
                query.shape = shape
                query.transform = owner_transform
                for raw_hit in space.intersect_shape(query, EMBED_MAX_RESULTS):
                    var hit: Dictionary = raw_hit
                    var collider_value: Variant = hit["collider"]
                    if not (collider_value is Node):
                        continue
                    var collider: Node = collider_value
                    if not _is_static_collision(collider):
                        continue
                    findings.append(_finding("embedded_in_static", _path_of(scene_root, body), "%s (%s) overlaps the static collision of %s (%s) right now — it is inside the wall/floor, not resting on it. Move it out along its up axis, or shrink its collision shape." % [
                        _path_of(scene_root, body), body.get_class(),
                        _path_of(scene_root, collider), collider.get_class()
                    ]))
                    break
    return findings


static func _occlusion_3d(subtree_root: Node, scene_root: Node, camera: Camera3D, expect_on_screen: Array, verdicts: Dictionary, kept: Array) -> Array:
    # Best effort: a physics ray only sees colliders, so a target with no
    # collision shape of its own is reported against whatever blocks the line.
    var findings: Array = []
    var node_by_path := {}
    for record in kept:
        node_by_path[str(record["path"])] = record["node"]
    var space := subtree_root.get_viewport().find_world_3d().direct_space_state
    if space == null:
        return findings
    for raw_path in expect_on_screen:
        var wanted := str(raw_path)
        if not verdicts.has(wanted):
            continue
        var verdict: Dictionary = verdicts[wanted]
        if not bool(verdict["in_frustum"]):
            continue
        var node_value: Variant = node_by_path.get(wanted)
        if not (node_value is Node3D):
            continue
        var target: Node3D = node_value
        var excluded: Array[RID] = []
        _collect_rids_3d(target, excluded)
        var query := PhysicsRayQueryParameters3D.create(camera.global_position, target.global_position)
        query.exclude = excluded
        var hit := space.intersect_ray(query)
        if hit.is_empty():
            continue
        var collider_value: Variant = hit["collider"]
        if not (collider_value is Node):
            continue
        findings.append(_finding("occluded", wanted, "expect_on_screen: %s is inside the frustum but %s (%s) blocks the straight line from the camera to it." % [
            wanted, _path_of(scene_root, collider_value as Node), (collider_value as Node).get_class()
        ]))
    return findings


static func _collect_rids_3d(node: Node, out: Array[RID]) -> void:
    if node is CollisionObject3D:
        out.append((node as CollisionObject3D).get_rid())
    for child in node.get_children():
        _collect_rids_3d(child, out)

# --- shared -----------------------------------------------------------------

static func _expect_visible_findings(subtree_root: Node, scene_root: Node, expect_visible: Array) -> Array:
    var findings: Array = []
    for raw_path in expect_visible:
        var wanted := str(raw_path)
        var node := _resolve(subtree_root, scene_root, wanted)
        if node == null:
            findings.append(_finding("invisible_expected", wanted, "expect_visible: no node at %s — run a dump_tree step to list the real paths." % wanted))
            continue
        var shown := false
        var hidden_by := ""
        if node is CanvasItem:
            shown = (node as CanvasItem).is_visible_in_tree()
        elif node is Node3D:
            shown = (node as Node3D).is_visible_in_tree()
        else:
            findings.append(_finding("invisible_expected", wanted, "expect_visible: %s is a %s, which has no visibility of its own." % [wanted, node.get_class()]))
            continue
        if shown:
            continue
        var walker := node
        while walker != null:
            var self_hidden := false
            if walker is CanvasItem:
                self_hidden = not (walker as CanvasItem).visible
            elif walker is Node3D:
                self_hidden = not (walker as Node3D).visible
            if self_hidden:
                hidden_by = _path_of(scene_root, walker)
                break
            walker = walker.get_parent()
        findings.append(_finding("invisible_expected", wanted, "expect_visible: %s (%s) is not visible in tree%s." % [
            wanted, node.get_class(),
            "" if hidden_by.is_empty() else " — %s carries the visible = false" % hidden_by
        ]))
    return findings


static func _collect_class(node: Node, class_name_value: String, out: Array) -> void:
    if node.is_class(class_name_value):
        out.append(node)
    for child in node.get_children():
        _collect_class(child, class_name_value, out)


static func _passes_class_filter(node: Node, class_filter: Array) -> bool:
    if class_filter.is_empty():
        return true
    for raw_name in class_filter:
        if node.is_class(str(raw_name)):
            return true
    return false


static func _resolve(subtree_root: Node, scene_root: Node, path_value: String) -> Node:
    var path := path_value.strip_edges()
    if path.is_empty() or path == "." or path == "root":
        return subtree_root
    var base := scene_root if scene_root != null else subtree_root
    if path.begins_with("root/"):
        path = path.trim_prefix("root/")
    var found: Node = base.get_node_or_null(NodePath(path))
    if found == null:
        found = subtree_root.get_node_or_null(NodePath(path))
    return found


static func _path_of(scene_root: Node, node: Node) -> String:
    if scene_root == null or node == scene_root:
        return "."
    if not scene_root.is_ancestor_of(node):
        return str(node.name)
    return str(scene_root.get_path_to(node))


static func _finding(finding_type: String, path: String, message: String) -> Dictionary:
    return {"type": finding_type, "path": path, "message": message}


static func _string_array(value: Variant) -> Array:
    var out: Array = []
    if value is Array:
        for entry in value as Array:
            out.append(str(entry))
    elif value is String or value is StringName:
        out.append(str(value))
    return out


static func _points_rect(points: PackedVector2Array) -> Rect2:
    if points.is_empty():
        return Rect2()
    var rect := Rect2(points[0], Vector2.ZERO)
    for point in points:
        rect = rect.expand(point)
    return rect

# --- ASCII ------------------------------------------------------------------

static func _ascii_size(options: Dictionary) -> Array:
    var cols := DEFAULT_ASCII_COLS
    var rows := DEFAULT_ASCII_ROWS
    var raw_size: Variant = options.get("ascii_size", {})
    if raw_size is Dictionary:
        var size_dict: Dictionary = raw_size
        cols = int(size_dict.get("cols", cols))
        rows = int(size_dict.get("rows", rows))
    return [clampi(cols, MIN_ASCII_COLS, MAX_ASCII_COLS), clampi(rows, MIN_ASCII_ROWS, MAX_ASCII_ROWS)]


static func _apply_ascii(report: Dictionary, ascii: Dictionary) -> void:
    report["ascii"] = ascii["rows"]
    report["ascii_legend"] = ascii["legend"]
    report["ascii_bounds_rect"] = ascii["bounds"]
    report["ascii_cell_size"] = ascii["cell"]
    report["ascii_axes"] = ascii["axes"]


static func _frustum_footprint(camera: Camera3D, visible_rect: Rect2, distance: float) -> Rect2:
    if camera == null:
        return Rect2()
    var aspect: float = visible_rect.size.x / maxf(visible_rect.size.y, 1.0)
    var half_height := camera.size * 0.5
    if camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
        half_height = tan(deg_to_rad(camera.fov) * 0.5) * distance
    var half_width := half_height * aspect
    var basis := camera.global_basis
    var origin := camera.global_position
    var center := origin - basis.z * distance
    var rect := Rect2(Vector2(origin.x, origin.z), Vector2.ZERO)
    for sign_x in [-1.0, 1.0]:
        for sign_y in [-1.0, 1.0]:
            var corner: Vector3 = center + basis.x * (half_width * sign_x) + basis.y * (half_height * sign_y)
            rect = rect.expand(Vector2(corner.x, corner.z))
    return rect


static func _ascii_map(drawables: Array, bounds: Rect2, cols: int, rows: int, view_rect: Rect2, camera_info: Dictionary, facing: float, is_3d: bool) -> Dictionary:
    var fitted := _fit_bounds(bounds, cols, rows)
    var grid: Array = []
    for _row in range(rows):
        var line: Array = []
        for _column in range(cols):
            line.append(EMPTY_CHAR)
        grid.append(line)

    var legend := {}
    if view_rect.size.x > 0.0 and view_rect.size.y > 0.0:
        legend[VIEW_CHAR] = "camera view" if not is_3d else "camera frustum footprint"

    # Letters follow the report's own order so the legend is stable, but the
    # drawing order is largest first, so a small node on top of a big one wins
    # the cell instead of disappearing into it.
    var order: Array = []
    for index in range(drawables.size()):
        var drawable: Dictionary = drawables[index]
        var symbol := OVERFLOW_CHAR
        if index < ASCII_LETTERS.length():
            symbol = ASCII_LETTERS.substr(index, 1)
        var label := "%s (%s)" % [str(drawable["path"]), str(drawable["class"])]
        if bool(drawable["screen"]):
            label += " [screen space]"
        if legend.has(symbol):
            legend[symbol] = str(legend[symbol]) + ", " + label
        else:
            legend[symbol] = label
        var rect: Rect2 = drawable["rect"]
        var entry := {"symbol": symbol, "rect": rect, "area": rect.size.x * rect.size.y}
        if drawable.has("tilemap"):
            entry["tilemap"] = drawable["tilemap"]
        if drawable.has("gridmap"):
            entry["gridmap"] = drawable["gridmap"]
        order.append(entry)
    order.sort_custom(func(a, b): return float(a["area"]) > float(b["area"]))
    for item in order:
        _draw_drawable(grid, cols, rows, fitted, item, str(item["symbol"]))

    # The view outline goes on last but only into cells nothing else claimed, so
    # it never hides a node and never has to compete with one for a cell.
    if view_rect.size.x > 0.0 and view_rect.size.y > 0.0:
        _draw_outline(grid, cols, rows, fitted, view_rect, VIEW_CHAR)

    if not camera_info.is_empty():
        var camera_point := Vector2.ZERO
        if is_3d:
            var position_array: Array = camera_info["position"]
            camera_point = Vector2(float(position_array[0]), float(position_array[2]))
        else:
            var center_array: Array = camera_info["center"]
            camera_point = Vector2(float(center_array[0]), float(center_array[1]))
        var cell := _cell_of(fitted, cols, rows, camera_point)
        _put(grid, cols, rows, int(cell.x), int(cell.y), CAMERA_CHAR)
        legend[CAMERA_CHAR] = "%s (%s)" % [str(camera_info["path"]), str(camera_info["class"])]
        if is_3d:
            var arrow := _facing_char(facing)
            var step := Vector2i(int(round(cos(facing))), int(round(sin(facing))))
            _put(grid, cols, rows, int(cell.x) + step.x, int(cell.y) + step.y, arrow)
            legend[arrow] = "camera facing"

    var lines: Array = []
    var drawn := {}
    for line in grid:
        for symbol in line:
            drawn[str(symbol)] = true
        lines.append("".join(PackedStringArray(line)))
    # A node whose rect was completely covered by a smaller one on top of it
    # (a body and its only collision shape share a rect) would otherwise appear
    # in the legend with no cell to point at.
    var visible_legend := {}
    for symbol in legend:
        if drawn.has(str(symbol)):
            visible_legend[symbol] = legend[symbol]
    return {
        "rows": lines,
        "legend": visible_legend,
        "bounds": _rect_array(fitted),
        "cell": [_round_number(fitted.size.x / float(cols)), _round_number(fitted.size.y / float(rows))],
        "axes": "x right, z down (top-down XZ)" if is_3d else "x right, y down (top-down XY)"
    }


static func _fit_bounds(bounds: Rect2, cols: int, rows: int) -> Rect2:
    # A subtree of nothing but points (markers, lights) has no extent at all, so
    # give it one unit rather than dividing the grid by zero.
    if bounds.size.x <= 0.0 and bounds.size.y <= 0.0:
        bounds = bounds.grow(1.0)
    var width: float = maxf(bounds.size.x, 0.000001)
    var height: float = maxf(bounds.size.y, 0.000001)
    # One column is one world unit `unit` wide; one row is CELL_ASPECT of those
    # tall, so a square in the world stays square on the page.
    var unit: float = maxf(width / float(cols), height / (float(rows) * CELL_ASPECT))
    var fitted_size := Vector2(unit * float(cols), unit * CELL_ASPECT * float(rows)) * 1.04
    return Rect2(bounds.get_center() - fitted_size * 0.5, fitted_size)


static func _cell_of(bounds: Rect2, cols: int, rows: int, point: Vector2) -> Vector2i:
    var x := int(floor((point.x - bounds.position.x) / maxf(bounds.size.x, 0.000001) * float(cols)))
    var y := int(floor((point.y - bounds.position.y) / maxf(bounds.size.y, 0.000001) * float(rows)))
    return Vector2i(x, y)


static func _draw_drawable(grid: Array, cols: int, rows: int, bounds: Rect2, item: Dictionary, symbol: String) -> void:
    var rect: Rect2 = item["rect"]
    var top_left := _cell_of(bounds, cols, rows, rect.position)
    var bottom_right := _cell_of(bounds, cols, rows, rect.position + rect.size)
    var left: int = mini(top_left.x, bottom_right.x)
    var right: int = maxi(top_left.x, bottom_right.x)
    var top: int = mini(top_left.y, bottom_right.y)
    var bottom: int = maxi(top_left.y, bottom_right.y)
    var layer: TileMapLayer = item["tilemap"] if item.has("tilemap") else null
    var grid_map: GridMap = item["gridmap"] if item.has("gridmap") else null
    var occupied_xz := {}
    if grid_map != null:
        for cell in grid_map.get_used_cells():
            occupied_xz[Vector2i(cell.x, cell.z)] = true
    var cell_size := Vector2(bounds.size.x / float(cols), bounds.size.y / float(rows))
    for y in range(top, bottom + 1):
        for x in range(left, right + 1):
            if layer != null or grid_map != null:
                # Sample the world point at this character's centre, the same
                # nearest-neighbour rule image_describe uses for pixels.
                var point := bounds.position + Vector2(float(x) + 0.5, float(y) + 0.5) * cell_size
                if layer != null:
                    if layer.get_cell_source_id(layer.local_to_map(layer.to_local(point))) == -1:
                        continue
                else:
                    var map_cell := grid_map.local_to_map(grid_map.to_local(Vector3(point.x, grid_map.global_position.y, point.y)))
                    if not occupied_xz.has(Vector2i(map_cell.x, map_cell.z)):
                        continue
            _put(grid, cols, rows, x, y, symbol)


static func _draw_outline(grid: Array, cols: int, rows: int, bounds: Rect2, rect: Rect2, symbol: String) -> void:
    var top_left := _cell_of(bounds, cols, rows, rect.position)
    var bottom_right := _cell_of(bounds, cols, rows, rect.position + rect.size)
    var left: int = mini(top_left.x, bottom_right.x)
    var right: int = maxi(top_left.x, bottom_right.x)
    var top: int = mini(top_left.y, bottom_right.y)
    var bottom: int = maxi(top_left.y, bottom_right.y)
    for x in range(left, right + 1):
        _put_if_empty(grid, cols, rows, x, top, symbol)
        _put_if_empty(grid, cols, rows, x, bottom, symbol)
    for y in range(top, bottom + 1):
        _put_if_empty(grid, cols, rows, left, y, symbol)
        _put_if_empty(grid, cols, rows, right, y, symbol)


static func _put_if_empty(grid: Array, cols: int, rows: int, x: int, y: int, symbol: String) -> void:
    if x < 0 or y < 0 or x >= cols or y >= rows:
        return
    var line: Array = grid[y]
    if str(line[x]) == EMPTY_CHAR:
        line[x] = symbol


static func _put(grid: Array, cols: int, rows: int, x: int, y: int, symbol: String) -> void:
    if x < 0 or y < 0 or x >= cols or y >= rows:
        return
    var line: Array = grid[y]
    line[x] = symbol


static func _facing_char(angle: float) -> String:
    # Eight compass directions on an x-right / y-down grid.
    var octant := int(round(angle / (PI / 4.0))) % 8
    if octant < 0:
        octant += 8
    return [">", "\\", "v", "/", "<", "\\", "^", "/"][octant]

# --- formatting -------------------------------------------------------------

static func _rect_array(rect: Rect2) -> Array:
    return [
        _round_number(rect.position.x), _round_number(rect.position.y),
        _round_number(rect.size.x), _round_number(rect.size.y)
    ]


static func _aabb_array(aabb: AABB) -> Array:
    return [
        _round_number(aabb.position.x), _round_number(aabb.position.y), _round_number(aabb.position.z),
        _round_number(aabb.size.x), _round_number(aabb.size.y), _round_number(aabb.size.z)
    ]


static func _vector2_array(value: Vector2) -> Array:
    return [_round_number(value.x), _round_number(value.y)]


static func _vector3_array(value: Vector3) -> Array:
    return [_round_number(value.x), _round_number(value.y), _round_number(value.z)]


static func _round_number(value: float) -> Variant:
    # Same rounding as the scenario runner's rect numbers: two decimals, and a
    # whole number stays an int so the JSON reads like the .tscn did.
    var rounded := snappedf(value, 0.01)
    if is_equal_approx(rounded, round(rounded)):
        return int(round(rounded))
    return rounded
