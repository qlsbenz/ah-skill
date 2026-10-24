class_name GodotSkillNodeConfigRules
extends RefCounted

# Node configuration warnings, re-implemented for headless runs.
#
# The editor's yellow triangles come from Node::get_configuration_warnings(),
# which is NOT bound outside the editor in Godot 4.7 (verified:
# CharacterBody2D.new().has_method("get_configuration_warnings") -> false, and
# ClassDB.class_has_method("Node", "get_configuration_warnings", true) -> false).
# A --script run therefore cannot read a single one of them, which is how an
# agent ships a player that falls through the floor with a clean check_project.
#
# This file re-implements the high-signal subset as rules over the *instantiated*
# tree, using real `is` checks (never class-name strings) and the same trigger
# conditions the engine uses. Two severities:
#
#   "warning" - parity with an editor configuration warning. The `message` is the
#               engine's own wording, taken from the 4.7 binary's string table.
#               Printed as a WARNING line by check_project.
#   "hint"    - a heuristic this skill adds. Never printed as a WARNING line,
#               never fails a run.
#
# Every finding carries a `fix` that is a runnable dispatcher call, not advice.
#
# Facts this file depends on (all verified on 4.7.stable):
# - CollisionShape2D/3D and CollisionPolygon2D/3D register a shape owner on their
#   parent from NOTIFICATION_PARENTED, so get_shape_owners() is already populated
#   on a scene that was instantiated but never added to a tree, and it is empty
#   when the only shape sits one level deeper (inside an instanced sub-scene that
#   is not itself a CollisionShape). That is exactly the engine's own test, so
#   body_without_shape matches the editor for instanced children for free.
# - A shape owner is created even when the CollisionShape's `shape` is null, so
#   the body is silent and the shape node carries the warning (two rules).
# - AnimationTree still exposes the deprecated `anim_player` in 4.7, but it now
#   extends AnimationMixer and the 4.0-era "Path to an AnimationPlayer ..."
#   warnings are gone from the engine; see animation_tree_without_player.
# - ScrollContainer has 5 internal children; get_child_count() excludes them.

const SEVERITY_WARNING := "warning"
const SEVERITY_HINT := "hint"

# Rules whose verdict depends on the node's parent. A scene root has no parent
# inside its own file - whoever instantiates it decides - so these are skipped on
# the root and evaluated wherever the node is actually placed.
const PARENT_RULES := {
    "shape_wrong_parent": true,
    "path_follow_wrong_parent": true,
    "parallax_layer_wrong_parent": true,
    "navigation_agent_wrong_parent": true,
    "vehicle_wheel_wrong_parent": true,
}

# --- entry points -----------------------------------------------------------

static func collect(root: Node, options: Dictionary) -> Array:
    # options (all optional):
    #   scene        String  - res:// path, used to build runnable `fix` calls
    #   local        Dict    - relative path -> bool "is an instanced sub-scene
    #                          placement"; when present, only these nodes are
    #                          reported on (see scene_scope). Without it every
    #                          node in the tree is reported.
    #   hints        bool    - emit severity "hint" findings (default true)
    #   scene_hints  bool    - emit whole-scene hints such as scene_3d_without_camera
    #                          (default true; check_project turns it off for a
    #                          scene that another scene instantiates)
    var findings: Array = []
    if root == null:
        return findings
    var scene_path: String = str(_opt(options, "scene", ""))
    var local: Dictionary = _opt(options, "local", {})
    var want_hints: bool = bool(_opt(options, "hints", true))
    var want_scene_hints: bool = bool(_opt(options, "scene_hints", true))

    var nodes: Array = []
    _flatten(root, nodes)
    var survey := _survey(nodes)

    for node in nodes:
        var relative := _relative_path(root, node)
        var scope := _scope_of(local, relative, root, node)
        if scope == 0:
            continue
        var context := {
            "root": root,
            "node": node,
            "relative": relative,
            "scene": scene_path,
            "path": node_path_of(root, node),
            "instanced": scope == 1,
            "hints": want_hints,
            "survey": survey,
        }
        _rules_for(context, findings)

    if want_scene_hints and want_hints:
        _scene_level_hints(root, scene_path, survey, findings)
    return findings

static func node_path_of(root: Node, node: Node) -> String:
    # The skill's convention: the scene root is always addressed as "root".
    if node == root:
        return "root"
    return "root/" + str(root.get_path_to(node))

static func scene_scope(packed: PackedScene) -> Dictionary:
    # Which nodes of the instantiated tree belong to *this* .tscn, so that a
    # problem inside an instanced or inherited sub-scene is reported once, by the
    # scene that actually stores it.
    #
    # Returns {relative_path: is_instance_placement}. `is_instance_placement` is
    # true for a `[node ... instance=ExtResource(...)]` entry: the node is placed
    # by this scene (so its parent-dependent rules belong here) but its own state
    # lives in the sub-scene (so its self-contained rules belong there).
    var scope: Dictionary = {}
    if packed == null:
        return scope
    var state := packed.get_state()
    if state == null:
        return scope
    var inherited: Dictionary = {}
    var base := state.get_base_scene_state()
    while base != null:
        for index in range(base.get_node_count()):
            inherited[_normalize_state_path(str(base.get_node_path(index)))] = true
        base = base.get_base_scene_state()
    for index in range(state.get_node_count()):
        var path := _normalize_state_path(str(state.get_node_path(index)))
        if inherited.has(path):
            # An inherited node the derived scene only overrides properties on:
            # the base scene is where it is defined, and where it is reported.
            continue
        scope[path] = state.get_node_instance(index) != null
    return scope

# --- physics layer survey ---------------------------------------------------

static func new_physics_layer_accumulator() -> Dictionary:
    return {
        "2d": _new_dimension(),
        "3d": _new_dimension(),
        "scanners": [],
        "truncated": false,
    }

static func collect_physics_layers(root: Node, scene_path: String, local: Dictionary, accumulator: Dictionary) -> void:
    if root == null:
        return
    var nodes: Array = []
    _flatten(root, nodes)
    for node in nodes:
        var relative := _relative_path(root, node)
        if _scope_of(local, relative, root, node) == 0:
            continue
        _physics_layers_for(node, scene_path, node_path_of(root, node), accumulator)

static func finish_physics_layers(accumulator: Dictionary, layer_names: Dictionary) -> Dictionary:
    var report: Dictionary = {}
    var findings: Array = []
    for dimension in ["2d", "3d"]:
        var data: Dictionary = accumulator[dimension]
        var names: Dictionary = layer_names[dimension]
        report[dimension] = _dimension_report(data, names)
    for scanner in accumulator["scanners"]:
        _scanner_findings(scanner, accumulator, layer_names, findings)
    for dimension in ["2d", "3d"]:
        var data: Dictionary = accumulator[dimension]
        var names: Dictionary = layer_names[dimension]
        var scanned: Dictionary = data["scanned"]
        var occupied: Dictionary = data["occupied"]
        for bit in occupied.keys():
            if scanned.has(bit):
                continue
            var entry: Dictionary = occupied[bit]
            var sample: Array = _split_label(entry["samples"][0] if not entry["samples"].is_empty() else "")
            findings.append({
                "rule": "layer_never_scanned",
                "severity": SEVERITY_HINT,
                "dimension": dimension,
                "bit": bit,
                "layer_name": _layer_name(names, bit),
                "scene": sample[0],
                "node_path": sample[1],
                "message": (
                    "%d node(s) sit on %s physics layer %s, but nothing in the project scans it: "
                    + "no collision_mask, ray, shape cast, tile set or grid map has that bit set, "
                    + "so those objects can never be hit or detected."
                ) % [entry["count"], dimension, _bit_label(names, bit)],
                "fix": (
                    "Set the bit on whatever should detect them, e.g. configure_node "
                    + "'{\"scene_path\":\"res://<scene>.tscn\",\"node_path\":\"root/<Detector>\",\"properties\":{\"collision_mask\":%d}}'"
                    + ", or move them to a layer that is scanned."
                ) % (1 << (bit - 1)),
            })
    var capped := _cap_per_rule(findings, 25)
    report["findings"] = capped
    report["finding_count"] = findings.size()
    report["truncated"] = bool(accumulator["truncated"]) or capped.size() < findings.size()
    return report

static func _cap_per_rule(findings: Array, limit: int) -> Array:
    # One dead mask bit shared by 300 enemies is one problem, not 300 payload
    # entries. finding_count keeps the real total.
    var kept: Array = []
    var seen: Dictionary = {}
    for finding in findings:
        var entry: Dictionary = finding
        var rule: String = str(entry["rule"])
        var count: int = int(seen[rule]) if seen.has(rule) else 0
        if count >= limit:
            continue
        seen[rule] = count + 1
        kept.append(entry)
    return kept

static func read_layer_names() -> Dictionary:
    var names := {"2d": {}, "3d": {}}
    for dimension in ["2d", "3d"]:
        for bit in range(1, 33):
            var setting := "layer_names/%s_physics/layer_%d" % [dimension, bit]
            var value := str(ProjectSettings.get_setting(setting, ""))
            if not value.is_empty():
                names[dimension][bit] = value
    return names

# --- rule dispatch ----------------------------------------------------------

static func _rules_for(context: Dictionary, findings: Array) -> void:
    var node: Node = context["node"]
    # Collision objects and their shapes.
    if node is CollisionObject2D:
        _rule_collision_object(context, findings, "2D")
    elif node is CollisionObject3D:
        _rule_collision_object(context, findings, "3D")
    if node is CollisionShape2D:
        _rule_collision_shape_2d(context, findings)
    elif node is CollisionShape3D:
        _rule_collision_shape_3d(context, findings)
    elif node is CollisionPolygon2D:
        _rule_collision_polygon_2d(context, findings)
    elif node is CollisionPolygon3D:
        _rule_collision_polygon_3d(context, findings)
    elif node is ShapeCast2D:
        if (node as ShapeCast2D).shape == null:
            _add(context, findings, "shapecast_without_shape", SEVERITY_WARNING,
                "This node cannot interact with other objects unless a Shape2D is assigned.",
                _shape_property_fix(context, "RectangleShape2D", {"size": _vec2(32, 32)}))
    elif node is ShapeCast3D:
        if (node as ShapeCast3D).shape == null:
            _add(context, findings, "shapecast_without_shape", SEVERITY_WARNING,
                "This node cannot interact with other objects unless a Shape3D is assigned.",
                _shape_property_fix(context, "BoxShape3D", {"size": _vec3(1, 1, 1)}))
    # Visual / gameplay nodes.
    if node is AnimatedSprite2D or node is AnimatedSprite3D:
        _rule_animated_sprite(context, findings)
    elif node is GPUParticles2D:
        if (node as GPUParticles2D).process_material == null:
            _add(context, findings, "particles_without_material", SEVERITY_WARNING,
                "A material to process the particles is not assigned, so no behavior is imprinted.",
                _configure_fix(context, {"process_material": _resource("ParticleProcessMaterial", {})}))
    elif node is GPUParticles3D:
        _rule_gpu_particles_3d(context, findings)
    elif node is CPUParticles3D:
        if (node as CPUParticles3D).mesh == null:
            _add(context, findings, "particles_without_draw_pass", SEVERITY_WARNING,
                "Nothing is visible because no mesh has been assigned.",
                _configure_fix(context, {"mesh": _resource("QuadMesh", {})}))
    elif node is PathFollow2D:
        if not (node.get_parent() is Path2D):
            _add(context, findings, "path_follow_wrong_parent", SEVERITY_WARNING,
                "PathFollow2D only works when set as a child of a Path2D node.",
                _reparent_fix(context, "Path2D"))
    elif node is PathFollow3D:
        if not (node.get_parent() is Path3D):
            _add(context, findings, "path_follow_wrong_parent", SEVERITY_WARNING,
                "PathFollow3D only works when set as a child of a Path3D node.",
                _reparent_fix(context, "Path3D"))
    elif node is ParallaxLayer:
        if not (node.get_parent() is ParallaxBackground):  # lint:ignore godot3_api
            _add(context, findings, "parallax_layer_wrong_parent", SEVERITY_WARNING,
                "ParallaxLayer node only works when set as child of a ParallaxBackground node.",
                _reparent_fix(context, "ParallaxBackground"))
    elif node is NavigationRegion2D:
        if (node as NavigationRegion2D).navigation_polygon == null:
            _add(context, findings, "navigation_region_without_mesh", SEVERITY_WARNING,
                "A NavigationPolygon resource must be set or created for this node to work. Please set a property or draw a polygon.",
                _configure_fix(context, {"navigation_polygon": _resource("NavigationPolygon", {})}))
    elif node is NavigationRegion3D:
        if (node as NavigationRegion3D).navigation_mesh == null:
            _add(context, findings, "navigation_region_without_mesh", SEVERITY_WARNING,
                "A NavigationMesh resource must be set or created for this node to work.",
                _configure_fix(context, {"navigation_mesh": _resource("NavigationMesh", {})}))
    elif node is NavigationAgent2D:
        if not (node.get_parent() is Node2D):
            _add(context, findings, "navigation_agent_wrong_parent", SEVERITY_WARNING,
                "The NavigationAgent2D can be used only under a Node2D inheriting parent node.",
                _reparent_fix(context, "Node2D"))
    elif node is NavigationAgent3D:
        if not (node.get_parent() is Node3D):
            _add(context, findings, "navigation_agent_wrong_parent", SEVERITY_WARNING,
                "The NavigationAgent3D can be used only under a Node3D inheriting parent node.",
                _reparent_fix(context, "Node3D"))
    elif node is AnimationTree:
        _rule_animation_tree(context, findings)
    elif node is WorldEnvironment:
        _rule_world_environment(context, findings)
    elif node is CanvasModulate:
        _rule_canvas_modulate(context, findings)
    elif node is RemoteTransform2D:
        _rule_remote_transform(context, findings, false)
    elif node is RemoteTransform3D:
        _rule_remote_transform(context, findings, true)
    elif node is LightOccluder2D:
        _rule_light_occluder(context, findings)
    elif node is PointLight2D:
        if (node as PointLight2D).texture == null:
            _add(context, findings, "point_light_without_texture", SEVERITY_WARNING,
                "A texture with the shape of the light must be supplied to the \"Texture\" property.",
                _configure_fix(context, {"texture": _resource("GradientTexture2D", {
                "width": 128, "height": 128, "fill": 1,
                "fill_from": _vec2(0.5, 0.5), "fill_to": _vec2(0.5, 0.0),
                "gradient": _resource("Gradient", {}),
            })}))
    elif node is ScrollContainer:
        _rule_scroll_container(context, findings)
    elif node is SubViewportContainer:
        _rule_subviewport_container(context, findings)
    elif node is Joint2D:
        _rule_joint(context, findings, false)
    elif node is Joint3D:
        _rule_joint(context, findings, true)
    elif node is VehicleWheel3D:
        if not (node.get_parent() is VehicleBody3D):
            _add(context, findings, "vehicle_wheel_wrong_parent", SEVERITY_WARNING,
                "VehicleWheel3D serves to provide a wheel system to a VehicleBody3D. Please use it as a child of a VehicleBody3D.",
                _reparent_fix(context, "VehicleBody3D"))
    elif node is MultiplayerSynchronizer:
        _rule_multiplayer_synchronizer(context, findings)
    elif node is MultiplayerSpawner:
        _rule_multiplayer_spawner(context, findings)
    _rule_scaled_physics(context, findings)
    if bool(context["hints"]):
        _hints_for(context, findings)

# --- warning rules ----------------------------------------------------------

static func _rule_collision_object(context: Dictionary, findings: Array, dimension: String) -> void:
    var node: Node = context["node"]
    # get_shape_owners() is the engine's own `shapes` map: a CollisionShape*/
    # CollisionPolygon* child registers itself there from NOTIFICATION_PARENTED,
    # even outside the tree and even with a null shape resource, and a shape one
    # level deeper never does. Using it makes this rule agree with the editor on
    # instanced children for free.
    var owner_count := 0
    if node is CollisionObject2D:
        owner_count = (node as CollisionObject2D).get_shape_owners().size()
    else:
        owner_count = (node as CollisionObject3D).get_shape_owners().size()
    if owner_count > 0:
        return
    var shape_class := "CollisionShape" + dimension
    var polygon_class := "CollisionPolygon" + dimension
    var properties: Dictionary = {}
    if dimension == "2D":
        properties["shape"] = _resource("RectangleShape2D", {"size": _vec2(32, 32)})
    else:
        properties["shape"] = _resource("BoxShape3D", {"size": _vec3(1, 1, 1)})
    _add(context, findings, "body_without_shape", SEVERITY_WARNING,
        "This node has no shape, so it can't collide or interact with other objects.\n"
        + "Consider adding a %s or %s as a child to define its shape." % [shape_class, polygon_class],
        _op("add_node", {
            "scene_path": context["scene"],
            "parent_node_path": context["path"],
            "node_type": shape_class,
            "node_name": shape_class,
            "properties": properties,
        }))

static func _rule_collision_shape_2d(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as CollisionShape2D
    if not (node.get_parent() is CollisionObject2D):
        _add(context, findings, "shape_wrong_parent", SEVERITY_WARNING,
            "CollisionShape2D only serves to provide a collision shape to a CollisionObject2D derived node.\n"
            + "Please only use it as a child of Area2D, StaticBody2D, RigidBody2D, CharacterBody2D, etc. to give them a shape.",
            _reparent_fix(context, "StaticBody2D", "CollisionObject2D"))
    if node.shape == null:
        _add(context, findings, "shape_without_resource", SEVERITY_WARNING,
            "A shape must be provided for CollisionShape2D to function. Please create a shape resource for it!",
            _shape_property_fix(context, "RectangleShape2D", {"size": _vec2(32, 32)}))

static func _rule_collision_shape_3d(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as CollisionShape3D
    if not (node.get_parent() is CollisionObject3D):
        _add(context, findings, "shape_wrong_parent", SEVERITY_WARNING,
            "CollisionShape3D only serves to provide a collision shape to a CollisionObject3D derived node.\n"
            + "Please only use it as a child of Area3D, StaticBody3D, RigidBody3D, CharacterBody3D, etc. to give them a shape.",
            _reparent_fix(context, "StaticBody3D", "CollisionObject3D"))
    if node.shape == null:
        _add(context, findings, "shape_without_resource", SEVERITY_WARNING,
            "A shape must be provided for CollisionShape3D to function. Please create a shape resource for it.",
            _shape_property_fix(context, "BoxShape3D", {"size": _vec3(1, 1, 1)}))

static func _rule_collision_polygon_2d(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as CollisionPolygon2D
    if not (node.get_parent() is CollisionObject2D):
        _add(context, findings, "shape_wrong_parent", SEVERITY_WARNING,
            "CollisionPolygon2D only serves to provide a collision shape to a CollisionObject2D derived node. "
            + "Please only use it as a child of Area2D, StaticBody2D, RigidBody2D, CharacterBody2D, etc. to give them a shape.",
            _reparent_fix(context, "StaticBody2D", "CollisionObject2D"))
    var points := node.polygon
    var polygon_fix := _configure_fix(context, {"polygon": _poly2([[0, 0], [32, 0], [32, 32], [0, 32]])})
    if points.is_empty():
        _add(context, findings, "collision_polygon_empty", SEVERITY_WARNING,
            "An empty CollisionPolygon2D has no effect on collision.", polygon_fix)
    elif node.build_mode == CollisionPolygon2D.BUILD_SOLIDS and points.size() < 3:
        _add(context, findings, "collision_polygon_empty", SEVERITY_WARNING,
            "Invalid polygon. At least 3 points are needed in 'Solids' build mode.", polygon_fix)
    elif node.build_mode == CollisionPolygon2D.BUILD_SEGMENTS and points.size() < 2:
        _add(context, findings, "collision_polygon_empty", SEVERITY_WARNING,
            "Invalid polygon. At least 2 points are needed in 'Segments' build mode.", polygon_fix)

static func _rule_collision_polygon_3d(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as CollisionPolygon3D
    if not (node.get_parent() is CollisionObject3D):
        _add(context, findings, "shape_wrong_parent", SEVERITY_WARNING,
            "CollisionPolygon3D only serves to provide a collision shape to a CollisionObject3D derived node.\n"
            + "Please only use it as a child of Area3D, StaticBody3D, RigidBody3D, CharacterBody3D, etc. to give them a shape.",
            _reparent_fix(context, "StaticBody3D", "CollisionObject3D"))
    if node.polygon.is_empty():
        _add(context, findings, "collision_polygon_empty", SEVERITY_WARNING,
            "An empty CollisionPolygon3D has no effect on collision.",
            _configure_fix(context, {"polygon": _poly2([[0, 0], [1, 0], [1, 1], [0, 1]])}))

static func _rule_animated_sprite(context: Dictionary, findings: Array) -> void:
    var node: Node = context["node"]
    var class_label := "AnimatedSprite2D" if node is AnimatedSprite2D else "AnimatedSprite3D"
    var frames := node.get(&"sprite_frames") as SpriteFrames
    # An inline SpriteFrames clears the warning on its own (a fresh one carries a
    # "default" animation); build_sprite_frames with a real sheet is what makes
    # the node actually draw something - see references/node_config.md.
    var build_fix := _configure_fix(context, {"sprite_frames": _resource("SpriteFrames", {})})
    if frames == null:
        _add(context, findings, "animated_sprite_without_frames", SEVERITY_WARNING,
            "A SpriteFrames resource must be created or set in the \"Sprite Frames\" property "
            + "in order for %s to display frames." % class_label,
            build_fix)
        return
    var wanted := str(node.get(&"animation"))
    if wanted.is_empty() or frames.has_animation(wanted):
        return
    var available := Array(frames.get_animation_names())
    _add(context, findings, "animated_sprite_without_frames", SEVERITY_WARNING,
        "%s.animation is \"%s\", which its SpriteFrames does not contain, so the node draws nothing "
        % [class_label, wanted]
        + "(the engine raises \"Animation '%s' doesn't exist.\" the first time it reads a frame). "
        % wanted
        + "Animations in the resource: %s." % str(available),
        _configure_fix(context, {"animation": available[0] if not available.is_empty() else "default"}))

static func _rule_gpu_particles_3d(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as GPUParticles3D
    if node.process_material == null:
        _add(context, findings, "particles_without_material", SEVERITY_WARNING,
            "A material to process the particles is not assigned, so no behavior is imprinted.",
            _configure_fix(context, {"process_material": _resource("ParticleProcessMaterial", {})}))
    var has_pass := false
    for index in range(1, 5):
        if node.get(StringName("draw_pass_%d" % index)) != null:
            has_pass = true
            break
    if not has_pass:
        _add(context, findings, "particles_without_draw_pass", SEVERITY_WARNING,
            "Nothing is visible because meshes have not been assigned to draw passes.",
            _configure_fix(context, {"draw_pass_1": _resource("QuadMesh", {})}))

static func _rule_animation_tree(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as AnimationTree
    if node.tree_root == null:
        _add(context, findings, "animation_tree_without_root", SEVERITY_WARNING,
            "No root AnimationNode for the graph is set.",
            _op("build_animation_tree", {
                "scene_path": context["scene"],
                "tree_node_path": context["path"],
                "states": [{"name": "idle", "animation": "idle"}],
            }))
    # 4.7 has no editor warning left for the animation source: AnimationTree
    # extends AnimationMixer and reads its own libraries, and the 4.0-era
    # "Path to an AnimationPlayer node ... is not set" strings are gone from the
    # engine binary. A tree with neither libraries nor the deprecated anim_player
    # still cannot resolve a single track, so it ships as a hint.
    if not bool(context["hints"]):
        return
    if not node.get_animation_library_list().is_empty():
        return
    if not str(node.anim_player).is_empty():
        return
    _add(context, findings, "animation_tree_without_player", SEVERITY_HINT,
        "This AnimationTree has no animation library of its own and its (deprecated) anim_player is empty, "
        + "so no track name resolves. In 4.7 an AnimationTree is an AnimationMixer: point anim_player at an "
        + "AnimationPlayer sibling, or add libraries to the tree itself.",
        _configure_fix(context, {"anim_player": {"__type": "NodePath", "value": "../<AnimationPlayer>"}}))

static func _rule_world_environment(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as WorldEnvironment
    var survey: Dictionary = context["survey"]
    if node.environment == null and node.camera_attributes == null:
        _add(context, findings, "world_environment_without_environment", SEVERITY_WARNING,
            "To have any visible effect, WorldEnvironment requires its \"Environment\" property to contain an "
            + "Environment, its \"Camera Attributes\" property to contain a CameraAttributes resource, or both.",
            _configure_fix(context, {"environment": _resource("Environment", {"background_mode": 1})}))
    var all: Array = survey["world_environments"]
    if all.size() > 1:
        # The editor flags every one of them, which is also what keeps this from
        # double-reporting: a sub-scene holding a single WorldEnvironment stays
        # silent on its own, and only the scene that ends up with two complains.
        _add(context, findings, "world_environment_duplicate", SEVERITY_WARNING,
            "Only one WorldEnvironment is allowed per scene (or set of instantiated scenes). "
            + "This scene's instantiated tree has %d." % all.size(),
            _op("remove_node", {"scene_path": context["scene"], "node_path": context["path"]}))

static func _rule_canvas_modulate(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as CanvasModulate
    if not node.visible:
        return
    var survey: Dictionary = context["survey"]
    var all: Array = survey["canvas_modulates"]
    if all.size() > 1:
        _add(context, findings, "canvas_modulate_duplicate", SEVERITY_WARNING,
            "Only one visible CanvasModulate is allowed per canvas.\n"
            + "When there are more than one, only one of them will be active. Which one is undefined. "
            + "This scene's instantiated tree has %d visible." % all.size(),
            _op("configure_node", {
                "scene_path": context["scene"], "node_path": context["path"],
                "properties": {"visible": false},
            }))

static func _rule_remote_transform(context: Dictionary, findings: Array, is_3d: bool) -> void:
    var node: Node = context["node"]
    var remote := str(node.get(&"remote_path"))
    if remote.begins_with("/"):
        # An absolute path into the running tree cannot be resolved from a scene
        # that was only instantiated, so saying nothing beats a false positive.
        return
    if not remote.is_empty():
        var target: Node = node.get_node_or_null(NodePath(remote))
        if is_3d and target is Node3D:
            return
        if not is_3d and target is Node2D:
            return
    var wanted := "Node3D" if is_3d else "Node2D"
    _add(context, findings, "remote_transform_bad_path", SEVERITY_WARNING,
        "Path property must point to a valid %s node to work." % wanted,
        _configure_fix(context, {"remote_path": {"__type": "NodePath", "value": "../<Target>"}}))

static func _rule_light_occluder(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as LightOccluder2D
    if node.occluder == null:
        _add(context, findings, "light_occluder_without_polygon", SEVERITY_WARNING,
            "An occluder polygon must be set (or drawn) for this occluder to take effect.",
            _configure_fix(context, {
                "occluder": _resource("OccluderPolygon2D",
                    {"polygon": _poly2([[0, 0], [32, 0], [32, 32], [0, 32]])}),
            }))
    elif node.occluder.polygon.is_empty():
        _add(context, findings, "light_occluder_without_polygon", SEVERITY_WARNING,
            "The occluder polygon for this occluder is empty. Please draw a polygon.",
            _op("configure_node", {
                "scene_path": context["scene"], "node_path": context["path"],
                "indexed_properties": {"occluder:polygon": _poly2([[0, 0], [32, 0], [32, 32], [0, 32]])},
            }))

static func _rule_scroll_container(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as ScrollContainer
    var root: Node = context["root"]
    var sortable: Array = []
    for child in node.get_children():
        var control := child as Control
        if control == null or control.is_set_as_top_level() or not control.visible:
            continue
        sortable.append(control)
    if sortable.size() == 1:
        return
    # One runnable batch: add the single container the ScrollContainer wants and
    # move every current child into it (an empty ScrollContainer just gets the
    # container, which is also what the editor's warning asks for).
    var actions: Array = [{
        "type": "add_node", "parent_node_path": context["path"],
        "node_type": "VBoxContainer", "node_name": "List",
    }]
    for control in sortable:
        actions.append({
            "type": "reparent_node",
            "node_path": node_path_of(root, control),
            "new_parent_node_path": context["path"] + "/List",
        })
    _add(context, findings, "scroll_container_child_count", SEVERITY_WARNING,
        "ScrollContainer is intended to work with a single child control.\n"
        + "Use a container as child (VBox, HBox, etc.), or a Control and set the custom minimum size manually. "
        + "(sortable child controls: %d)" % sortable.size(),
        _op("scene_batch", {"scene_path": context["scene"], "actions": actions}))

static func _rule_subviewport_container(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as SubViewportContainer
    for child in node.get_children():
        if child is SubViewport:
            return
    _add(context, findings, "subviewport_container_without_viewport", SEVERITY_WARNING,
        "This node doesn't have a SubViewport as child, so it can't display its intended content.\n"
        + "Consider adding a SubViewport as a child to provide something displayable.",
        _op("add_node", {
            "scene_path": context["scene"], "parent_node_path": context["path"],
            "node_type": "SubViewport", "node_name": "SubViewport",
        }))

static func _rule_joint(context: Dictionary, findings: Array, is_3d: bool) -> void:
    var node: Node = context["node"]
    var suffix := "PhysicsBody3D" if is_3d else "PhysicsBody2D"
    var path_a := str(node.get(&"node_a"))
    var path_b := str(node.get(&"node_b"))
    if path_a.begins_with("/") or path_b.begins_with("/"):
        return
    var node_a: Node = node.get_node_or_null(NodePath(path_a)) if not path_a.is_empty() else null
    var node_b: Node = node.get_node_or_null(NodePath(path_b)) if not path_b.is_empty() else null
    var body_a: bool = (node_a is PhysicsBody3D) if is_3d else (node_a is PhysicsBody2D)
    var body_b: bool = (node_b is PhysicsBody3D) if is_3d else (node_b is PhysicsBody2D)
    var message := ""
    if node_a != null and not body_a and node_b != null and not body_b:
        message = "Node A and Node B must be %ss" % suffix
    elif node_a != null and not body_a:
        message = "Node A must be a %s" % suffix
    elif node_b != null and not body_b:
        message = "Node B must be a %s" % suffix
    elif not body_a or not body_b:
        message = "Joint is not connected to any %ss" % suffix if is_3d else "Joint is not connected to two %ss" % suffix
    elif node_a == node_b:
        message = "Node A and Node B must be different %ss" % suffix
    if message.is_empty():
        return
    _add(context, findings, "joint_without_nodes", SEVERITY_WARNING, message,
        _configure_fix(context, {
            "node_a": {"__type": "NodePath", "value": "../<BodyA>"},
            "node_b": {"__type": "NodePath", "value": "../<BodyB>"},
        }))

static func _rule_multiplayer_synchronizer(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as MultiplayerSynchronizer
    var root_path := str(node.root_path)
    var resolved: Node = null
    if not root_path.begins_with("/") and not root_path.is_empty():
        resolved = node.get_node_or_null(NodePath(root_path))
    if root_path.is_empty() or (resolved == null and not root_path.begins_with("/") and node.get_parent() != null):
        _add(context, findings, "multiplayer_synchronizer_without_config", SEVERITY_WARNING,
            "A valid NodePath must be set in the \"Root Path\" property in order for MultiplayerSynchronizer "
            + "to be able to synchronize properties.",
            _configure_fix(context, {"root_path": {"__type": "NodePath", "value": ".."}}))
        return
    if not bool(context["hints"]):
        return
    if node.replication_config == null:
        _add(context, findings, "multiplayer_synchronizer_without_config", SEVERITY_HINT,
            "Root Path resolves, but no SceneReplicationConfig is assigned, so this synchronizer replicates nothing.",
            _op("build_replication_config", {
                "resource_path": "net/player_sync.tres",
                "properties": [{"path": ":position", "spawn": true, "sync": true}],
                "scene_path": context["scene"],
                "node_path": context["path"],
            }))

static func _rule_multiplayer_spawner(context: Dictionary, findings: Array) -> void:
    var node := context["node"] as MultiplayerSpawner
    var spawn_path := str(node.spawn_path)
    if spawn_path.begins_with("/"):
        return
    var resolved: Node = node.get_node_or_null(NodePath(spawn_path)) if not spawn_path.is_empty() else null
    if resolved != null:
        return
    _add(context, findings, "multiplayer_spawner_bad_path", SEVERITY_WARNING,
        "A valid NodePath must be set in the \"Spawn Path\" property in order for MultiplayerSpawner to be able to spawn Nodes.",
        _configure_fix(context, {"spawn_path": {"__type": "NodePath", "value": ".."}}))

static func _rule_scaled_physics(context: Dictionary, findings: Array) -> void:
    var node: Node = context["node"]
    if node is RigidBody2D:
        var scale_2d: Vector2 = (node as Node2D).scale
        if not scale_2d.is_equal_approx(Vector2.ONE):
            _add(context, findings, "physics_body_scaled", SEVERITY_WARNING,
                "Size changes to RigidBody2D will be overridden by the physics engine when running.\n"
                + "Change the size in children collision shapes instead.",
                _configure_fix(context, {"scale": _vec2(1, 1)}))
        return
    if node is RigidBody3D:
        var scale_rigid: Vector3 = (node as Node3D).scale
        if not scale_rigid.is_equal_approx(Vector3.ONE):
            _add(context, findings, "physics_body_scaled", SEVERITY_WARNING,
                "Scale changes to RigidBody3D will be overridden by the physics engine when running.\n"
                + "Change the size in children collision shapes instead.",
                _configure_fix(context, {"scale": _vec3(1, 1, 1)}))
        return
    if node is CollisionObject3D:
        if not _is_uniform((node as Node3D).scale):
            _add(context, findings, "physics_body_scaled", SEVERITY_WARNING,
                "With a non-uniform scale this node will probably not function as expected.\n"
                + "Please make its scale uniform (i.e. the same on all axes), and change the size in children collision shapes instead.",
                _configure_fix(context, {"scale": _vec3(1, 1, 1)}))
        return
    if node is CollisionShape3D:
        if not _is_uniform((node as Node3D).scale):
            _add(context, findings, "physics_body_scaled", SEVERITY_WARNING,
                "A non-uniformly scaled CollisionShape3D node will probably not function as expected.\n"
                + "Please make its scale uniform (i.e. the same on all axes), and change the size of its shape resource instead.",
                _configure_fix(context, {"scale": _vec3(1, 1, 1)}))
        return
    if node is CollisionPolygon3D:
        if not _is_uniform((node as Node3D).scale):
            _add(context, findings, "physics_body_scaled", SEVERITY_WARNING,
                "A non-uniformly scaled CollisionPolygon3D node will probably not function as expected.\n"
                + "Please make its scale uniform (i.e. the same on all axes), and change its polygon's vertices instead.",
                _configure_fix(context, {"scale": _vec3(1, 1, 1)}))

# --- hints ------------------------------------------------------------------

static func _hints_for(context: Dictionary, findings: Array) -> void:
    var node: Node = context["node"]
    if node is Sprite2D or node is Sprite3D:
        if node.get(&"texture") == null:
            _add(context, findings, "sprite_without_texture", SEVERITY_HINT,
                "%s has no texture, so it draws nothing." % node.get_class(),
                _op("load_sprite", {
                    "scene_path": context["scene"], "node_path": context["path"],
                    "texture_path": "art/<your_sprite>.png",
                }))
    elif node is TileMapLayer:
        if (node as TileMapLayer).tile_set == null:
            _add(context, findings, "tilemap_layer_without_tileset", SEVERITY_HINT,
                "TileMapLayer has no TileSet, so every painted cell is ignored and the layer draws nothing.",
                _configure_fix(context, {"tile_set": {"__resource": "res://tilesets/<your_tileset>.tres"}}))
    elif node is GridMap:
        if (node as GridMap).mesh_library == null:
            _add(context, findings, "gridmap_without_mesh_library", SEVERITY_HINT,
                "GridMap has no MeshLibrary, so no cell can be painted and nothing is drawn.",
                _configure_fix(context, {"mesh_library": {"__resource": "res://meshlib/<your_library>.meshlib"}}))
    elif node is MeshInstance3D:
        if (node as MeshInstance3D).mesh == null:
            _add(context, findings, "mesh_instance_without_mesh", SEVERITY_HINT,
                "MeshInstance3D requires a Mesh to render anything. Please add a mesh resource for it!",
                _configure_fix(context, {"mesh": _resource("BoxMesh", {})}))
    elif node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
        if node.get(&"stream") == null:
            _add(context, findings, "audio_player_without_stream", SEVERITY_HINT,
                "%s has no stream, so play() is silent." % node.get_class(),
                _configure_fix(context, {"stream": {"__resource": "res://audio/<your_sound>.wav"}}))
    elif node is Button or node is Label:
        _hint_empty_text(context, findings)

static func _hint_empty_text(context: Dictionary, findings: Array) -> void:
    var node: Node = context["node"]
    if not str(node.get(&"text")).is_empty():
        return
    if node is Button and (node as Button).icon != null:
        return
    _add(context, findings, "label_without_text", SEVERITY_HINT,
        "%s has empty text (fine when a script fills it at runtime, invisible otherwise)." % node.get_class(),
        _configure_fix(context, {"text": "Label"}))

static func _scene_level_hints(root: Node, scene_path: String, survey: Dictionary, findings: Array) -> void:
    if int(survey["visual_3d"]) <= 0:
        return
    var context := {
        "root": root, "node": root, "relative": ".", "scene": scene_path,
        "path": "root", "instanced": false, "hints": true, "survey": survey,
    }
    if not bool(survey["camera_3d"]):
        _add(context, findings, "scene_3d_without_camera", SEVERITY_HINT,
            "%d visible 3D visual instance(s) and no Camera3D: nothing is rendered when this scene runs on its own."
            % int(survey["visual_3d"]),
            _op("add_node", {
                "scene_path": scene_path, "parent_node_path": "root",
                "node_type": "Camera3D", "node_name": "Camera3D",
                "properties": {"position": _vec3(0, 2, 5)},
            }))
    if not bool(survey["light_3d"]) and not bool(survey["ambient_light"]):
        _add(context, findings, "scene_3d_without_light", SEVERITY_HINT,
            "%d visible 3D visual instance(s), no Light3D and no WorldEnvironment providing ambient or sky light: "
            % int(survey["visual_3d"])
            + "the scene renders black.",
            _op("add_node", {
                "scene_path": scene_path, "parent_node_path": "root",
                "node_type": "DirectionalLight3D", "node_name": "DirectionalLight3D",
                "properties": {"rotation": _vec3(-0.9, -0.6, 0)},
            }))

# --- physics layer helpers --------------------------------------------------

static func _physics_layers_for(node: Node, scene: String, path: String, accumulator: Dictionary) -> void:
    var label := "%s::%s" % [scene, path]
    if node is CollisionObject2D:
        _record_collision_object(node, scene, path, label, "2d", accumulator)
    elif node is CollisionObject3D:
        _record_collision_object(node, scene, path, label, "3d", accumulator)
    elif node is TileMapLayer:
        # A TileSet physics layer is a real occupant: the floor a TileMapLayer
        # paints is what a player's collision_mask actually hits.
        var tile_set := (node as TileMapLayer).tile_set
        if tile_set != null:
            for index in range(tile_set.get_physics_layers_count()):
                _occupy(accumulator, "2d", tile_set.get_physics_layer_collision_layer(index), label)
    elif node is GridMap:
        var grid := node as GridMap
        if grid.mesh_library != null:
            _occupy(accumulator, "3d", grid.collision_layer, label)
    elif node is CSGShape3D:
        var csg := node as CSGShape3D
        if csg.use_collision:
            _occupy(accumulator, "3d", csg.collision_layer, label)
    elif node is RayCast2D:
        _scan(accumulator, "2d", (node as RayCast2D).collision_mask, scene, path, label, node, (node as RayCast2D).enabled)
    elif node is RayCast3D:
        _scan(accumulator, "3d", (node as RayCast3D).collision_mask, scene, path, label, node, (node as RayCast3D).enabled)
    elif node is ShapeCast2D:
        _scan(accumulator, "2d", (node as ShapeCast2D).collision_mask, scene, path, label, node, (node as ShapeCast2D).enabled)
    elif node is ShapeCast3D:
        _scan(accumulator, "3d", (node as ShapeCast3D).collision_mask, scene, path, label, node, (node as ShapeCast3D).enabled)

static func _record_collision_object(node: Node, scene: String, path: String, label: String, dimension: String, accumulator: Dictionary) -> void:
    var layer := int(node.get(&"collision_layer"))
    var mask := int(node.get(&"collision_mask"))
    _occupy(accumulator, dimension, layer, label)
    var is_area: bool = node is Area2D or node is Area3D
    var scans: bool = true
    if is_area:
        # An Area with monitoring off never queries its mask.
        scans = bool(node.get(&"monitoring"))
    elif node is StaticBody2D or node is StaticBody3D or node is AnimatableBody2D or node is AnimatableBody3D:
        # A static body never moves itself, so its mask is inert.
        scans = false
    _scan(accumulator, dimension, mask, scene, path, label, node, scans)
    var records: Array = accumulator["scanners"]
    if layer == 0 and not is_area:
        records.append({
            "kind": "layer_zero", "dimension": dimension, "label": label, "scene": scene, "path": path,
            "node_type": node.get_class(), "mask": 0,
        })
    if mask == 0 and scans:
        records.append({
            "kind": "mask_zero", "dimension": dimension, "label": label, "scene": scene, "path": path,
            "node_type": node.get_class(), "mask": 0,
        })

static func _occupy(accumulator: Dictionary, dimension: String, bits: int, label: String) -> void:
    var data: Dictionary = accumulator[dimension]
    _bucket_add(data["occupied"], bits, label)

static func _scan(accumulator: Dictionary, dimension: String, bits: int, scene: String, path: String, label: String, node: Node, active: bool) -> void:
    if not active or bits == 0:
        return
    var data: Dictionary = accumulator[dimension]
    _bucket_add(data["scanned"], bits, label)
    var scanners: Array = accumulator["scanners"]
    if scanners.size() >= 4000:
        accumulator["truncated"] = true
        return
    scanners.append({
        "kind": "scanner", "dimension": dimension, "label": label, "scene": scene, "path": path,
        "node_type": node.get_class(), "mask": bits,
    })

static func _bucket_add(buckets: Dictionary, bits: int, label: String) -> void:
    for bit in range(1, 33):
        if bits & (1 << (bit - 1)) == 0:
            continue
        if not buckets.has(bit):
            buckets[bit] = {"count": 0, "samples": []}
        var entry: Dictionary = buckets[bit]
        entry["count"] = int(entry["count"]) + 1
        var samples: Array = entry["samples"]
        if samples.size() < 5:
            samples.append(label)

static func _dimension_report(data: Dictionary, names: Dictionary) -> Dictionary:
    var layers: Array = []
    var bits: Dictionary = {}
    for bit in data["occupied"].keys():
        bits[bit] = true
    for bit in data["scanned"].keys():
        bits[bit] = true
    for bit in names.keys():
        bits[bit] = true
    var ordered: Array = bits.keys()
    ordered.sort()
    for bit in ordered:
        var occupied: Dictionary = data["occupied"][bit] if data["occupied"].has(bit) else {"count": 0, "samples": []}
        var scanned: Dictionary = data["scanned"][bit] if data["scanned"].has(bit) else {"count": 0, "samples": []}
        layers.append({
            "bit": bit,
            "value": 1 << (bit - 1),
            "name": _layer_name(names, bit),
            "occupied_by": occupied["samples"],
            "occupied_count": occupied["count"],
            "scanned_by": scanned["samples"],
            "scanned_count": scanned["count"],
        })
    return {"layers": layers}

static func _scanner_findings(scanner: Dictionary, accumulator: Dictionary, layer_names: Dictionary, findings: Array) -> void:
    var dimension: String = scanner["dimension"]
    var names: Dictionary = layer_names[dimension]
    var kind: String = scanner["kind"]
    if kind == "layer_zero":
        findings.append({
            "rule": "body_layer_zero", "severity": SEVERITY_HINT, "dimension": dimension,
            "bit": 0, "layer_name": "", "scene": scanner["scene"], "node_path": scanner["path"],
            "message": "%s has collision_layer 0: nothing can collide with it or detect it."
                % scanner["node_type"],
            "fix": _op("configure_node", {
                "scene_path": scanner["scene"], "node_path": scanner["path"],
                "properties": {"collision_layer": 1},
            }),
        })
        return
    if kind == "mask_zero":
        findings.append({
            "rule": "body_mask_zero", "severity": SEVERITY_HINT, "dimension": dimension,
            "bit": 0, "layer_name": "", "scene": scanner["scene"], "node_path": scanner["path"],
            "message": "%s has collision_mask 0: it detects and collides with nothing (a body with mask 0 falls through every floor)."
                % scanner["node_type"],
            "fix": _op("configure_node", {
                "scene_path": scanner["scene"], "node_path": scanner["path"],
                "properties": {"collision_mask": 1},
            }),
        })
        return
    var occupied: Dictionary = accumulator[dimension]["occupied"]
    var missing: Array = []
    for bit in range(1, 33):
        if scanner["mask"] & (1 << (bit - 1)) == 0:
            continue
        if occupied.has(bit):
            continue
        missing.append(bit)
    if missing.is_empty():
        return
    var labels: Array = []
    var remaining := int(scanner["mask"])
    for bit in missing:
        labels.append(_bit_label(names, bit))
        remaining &= ~(1 << (bit - 1))
    findings.append({
        "rule": "mask_targets_empty_layer", "severity": SEVERITY_HINT, "dimension": dimension,
        "bit": missing[0], "layer_name": _layer_name(names, missing[0]),
        "scene": scanner["scene"], "node_path": scanner["path"],
        "message": "%s scans %s physics layer %s, which no object in the project occupies, so it will never report a hit."
            % [scanner["node_type"], dimension, ", ".join(PackedStringArray(labels))],
        "fix": _empty_layer_fix(scanner, remaining),
    })

static func _empty_layer_fix(scanner: Dictionary, remaining: int) -> String:
    if remaining == 0:
        # Dropping the last bit would only trade this hint for body_mask_zero.
        return ("Put whatever this node should detect on one of those layers "
            + "(configure_node … {\"collision_layer\": N} on the target), or point this node's "
            + "collision_mask at a layer something already occupies.")
    return "Put the intended target on that layer, or drop the dead bit(s): " + _op("configure_node", {
        "scene_path": scanner["scene"], "node_path": scanner["path"],
        "properties": {"collision_mask": remaining},
    })

static func _split_label(label: String) -> Array:
    var index := label.find("::")
    if index < 0:
        return ["", label]
    return [label.substr(0, index), label.substr(index + 2)]

static func _layer_name(names: Dictionary, bit: int) -> String:
    return str(names[bit]) if names.has(bit) else ""

static func _bit_label(names: Dictionary, bit: int) -> String:
    var name_value := _layer_name(names, bit)
    if name_value.is_empty():
        return str(bit)
    return "%d (\"%s\")" % [bit, name_value]

static func _new_dimension() -> Dictionary:
    return {"occupied": {}, "scanned": {}}

# --- shared helpers ---------------------------------------------------------

static func _survey(nodes: Array) -> Dictionary:
    var world_environments: Array = []
    var canvas_modulates: Array = []
    var camera_3d := false
    var light_3d := false
    var ambient_light := false
    var visual_3d := 0
    for node in nodes:
        if node is WorldEnvironment:
            world_environments.append(node)
            var environment := (node as WorldEnvironment).environment
            if environment != null and _environment_lights(environment):
                ambient_light = true
        elif node is CanvasModulate:
            if (node as CanvasModulate).visible:
                canvas_modulates.append(node)
        elif node is Camera3D:
            camera_3d = true
        elif node is Light3D:
            if (node as Light3D).visible:
                light_3d = true
        elif node is GeometryInstance3D:
            if (node as GeometryInstance3D).visible:
                visual_3d += 1
    return {
        "world_environments": world_environments,
        "canvas_modulates": canvas_modulates,
        "camera_3d": camera_3d,
        "light_3d": light_3d,
        "ambient_light": ambient_light,
        "visual_3d": visual_3d,
    }

static func _environment_lights(environment: Environment) -> bool:
    var source := environment.ambient_light_source
    if source == Environment.AMBIENT_SOURCE_COLOR or source == Environment.AMBIENT_SOURCE_SKY:
        return true
    if source == Environment.AMBIENT_SOURCE_BG and environment.background_mode == Environment.BG_SKY:
        return true
    return false

static func _flatten(node: Node, into: Array) -> void:
    into.append(node)
    for child in node.get_children():
        _flatten(child, into)

static func _relative_path(root: Node, node: Node) -> String:
    if node == root:
        return "."
    return str(root.get_path_to(node))

static func _scope_of(local: Dictionary, relative: String, root: Node, node: Node) -> int:
    # 0 = not this scene's business, 1 = placed here but defined elsewhere
    # (an instanced sub-scene root), 2 = fully defined here.
    if local.is_empty():
        if node != root and not node.scene_file_path.is_empty():
            return 1
        return 2
    if not local.has(relative):
        return 0
    return 1 if bool(local[relative]) else 2

static func _add(context: Dictionary, findings: Array, rule: String, severity: String, message: String, fix: String) -> void:
    if bool(context["instanced"]) and not PARENT_RULES.has(rule):
        # The node is an instanced sub-scene placement: only the rules that
        # depend on where this scene put it belong here; everything else is
        # reported once, by the sub-scene that defines the node.
        return
    var node: Node = context["node"]
    if PARENT_RULES.has(rule) and node == context["root"]:
        # A scene root has no parent of its own; the scene that instantiates it
        # decides, and that is where the rule is evaluated.
        return
    findings.append({
        "node_path": context["path"],
        "node_type": node.get_class(),
        "rule": rule,
        "severity": severity,
        "message": message,
        "fix": fix,
    })

static func _opt(options: Dictionary, key: String, fallback: Variant) -> Variant:
    if options.has(key):
        return options[key]
    return fallback

static func _normalize_state_path(path: String) -> String:
    if path == "." or path.is_empty():
        return "."
    return path.trim_prefix("./")

static func _is_uniform(value: Vector3) -> bool:
    return is_equal_approx(value.x, value.y) and is_equal_approx(value.y, value.z)

static func _resource(type_name: String, properties: Dictionary) -> Dictionary:
    # The codec's inline-resource form: extra keys must sit under "properties",
    # anything at the top level is silently ignored.
    var value: Dictionary = {"__resource_type": type_name}
    if not properties.is_empty():
        value["properties"] = properties
    return value

static func _poly2(points: Array) -> Dictionary:
    # PackedVector2Array in the codec's typed-JSON form; a flat number array
    # would `set()` into a run of zero vectors instead.
    var values: Array = []
    for point in points:
        values.append({"x": point[0], "y": point[1]})
    return {"__type": "PackedVector2Array", "values": values}

static func _candidate_parent(context: Dictionary, wanted: String) -> String:
    # A concrete reparent target: the first node of the wanted class in this
    # scene that is not the node itself or one of its descendants.
    var root: Node = context["root"]
    var node: Node = context["node"]
    var nodes: Array = []
    _flatten(root, nodes)
    for candidate in nodes:
        var other: Node = candidate
        if other == node or node.is_ancestor_of(other):
            continue
        if other.is_class(wanted):
            return node_path_of(root, other)
    return ""

static func _vec2(x: float, y: float) -> Dictionary:
    return {"__type": "Vector2", "x": x, "y": y}

static func _vec3(x: float, y: float, z: float) -> Dictionary:
    return {"__type": "Vector3", "x": x, "y": y, "z": z}

static func _op(operation: String, params: Dictionary) -> String:
    # sort_keys=false keeps scene_path/node_path first, which is what a reader
    # (and a model copy-pasting the call) expects.
    return "%s '%s'" % [operation, JSON.stringify(params, "", false)]

static func _configure_fix(context: Dictionary, properties: Dictionary) -> String:
    return _op("configure_node", {
        "scene_path": context["scene"],
        "node_path": context["path"],
        "properties": properties,
    })

static func _shape_property_fix(context: Dictionary, shape_type: String, extra: Dictionary) -> String:
    return _configure_fix(context, {"shape": _resource(shape_type, extra)})

static func _reparent_fix(context: Dictionary, parent_type: String, search_class: String = "") -> String:
    # Runnable either way: move the node under a node of that class when the
    # scene already has one, otherwise add the parent and move it in one batch.
    # search_class widens the search when several classes would do (any
    # CollisionObject2D can host a shape, but only one class can be created).
    var existing := _candidate_parent(context, search_class if not search_class.is_empty() else parent_type)
    if not existing.is_empty():
        return _op("reparent_node", {
            "scene_path": context["scene"],
            "node_path": context["path"],
            "new_parent_node_path": existing,
        })
    var node: Node = context["node"]
    var root: Node = context["root"]
    var parent: Node = node.get_parent()
    var host := node_path_of(root, parent) if parent != null else "root"
    var new_parent := ("root/" if host == "root" else host + "/") + parent_type
    return _op("scene_batch", {
        "scene_path": context["scene"],
        "actions": [
            {"type": "add_node", "parent_node_path": host, "node_type": parent_type, "node_name": parent_type},
            {"type": "reparent_node", "node_path": context["path"], "new_parent_node_path": new_parent},
        ],
    })
