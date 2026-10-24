# enemy_chase_nav_2d.gd — a chaser that walks around walls. It re-paths on a
# timer (not every frame) through a NavigationAgent2D, and falls back to walking
# straight at the target when the project has no baked navigation map, so the
# enemy always moves instead of standing still with no error.
#
# Expected scene tree (node name : type) — create it before attaching:
#   Enemy : CharacterBody2D           <- attach this script here
#     CollisionShape2D : CollisionShape2D
#     Sprite2D : Sprite2D             (optional)
#     NavigationAgent2D : NavigationAgent2D   (must be a direct child)
#     Health : Node                   (health.gd — optional)
#     Hurtbox : Area2D                (hurtbox.gd — optional)
#   NavigationAgent2D's parent must be a Node2D — that is one of the editor
#   configuration warnings check_project re-implements.
#   unique_name_in_owner: not needed on any node.
#
# Autoload: no.
#
# Input actions: none.
#
# The navigation map: bake a NavigationPolygon and put it on a
# NavigationRegion2D in the level, e.g.
#   resource_batch '{"resource_path":"nav/level.tres","create_if_missing":true,
#     "resource_type":"NavigationPolygon",
#     "actions":[{"type":"set_properties","properties":{"agent_radius":8.0}},
#                {"type":"bake_navmesh","traversable_outlines":[[[0,0],[512,0],[512,320],[0,320]]],
#                 "obstruction_outlines":[[[200,120],[280,120],[280,200],[200,200]]]}]}'
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/chaser.tscn","actions":[
#     {"type":"attach_script","node_path":"root","script_path":"scripts/enemy_chase_nav_2d.gd",
#      "script_properties":{"speed":90.0,"repath_interval":0.25}}]}'
extends CharacterBody2D

signal target_changed(target: Node2D)
## Emitted once per change, so a "!" alert or a sound can react to it.
signal navigation_mode_changed(using_navigation: bool)

@export var speed: float = 90.0
@export var acceleration: float = 900.0
## Nearest node of this group is the prey.
@export var target_group: StringName = &"player"
## Seconds between two path queries. Every frame is wasted work.
@export var repath_interval: float = 0.25
## Stop this close, so the chaser does not jitter inside the target.
@export var stop_distance: float = 10.0
## Set false to make a dumb chaser that never uses the navigation map.
@export var use_navigation: bool = true

var target: Node2D = null

@onready var _agent: NavigationAgent2D = $NavigationAgent2D

var _repath_left: float = 0.0
var _navigating: bool = false
var _ready_for_queries: bool = false


func _ready() -> void:
	_agent.path_desired_distance = maxf(_agent.path_desired_distance, 4.0)
	_agent.target_desired_distance = maxf(stop_distance, 4.0)
	# The navigation map is only synchronised at the end of the first physics
	# frame; a query before that returns the agent's own position and the enemy
	# would stand still for as long as the caller kept asking.
	await get_tree().physics_frame
	_ready_for_queries = true


## True when the enemy is following a real path rather than walking straight.
func is_navigating() -> bool:
	return _navigating


func _physics_process(delta: float) -> void:
	var prey: Node2D = _find_target()
	if prey != target:
		target = prey
		target_changed.emit(target)

	var desired: Vector2 = Vector2.ZERO
	if target != null:
		var to_target: Vector2 = target.global_position - global_position
		if to_target.length() > stop_distance:
			desired = _steer_toward(target.global_position, delta) * speed

	velocity = velocity.move_toward(desired, acceleration * delta)
	move_and_slide()


func _steer_toward(goal: Vector2, delta: float) -> Vector2:
	var direct: Vector2 = (goal - global_position).normalized()
	if not use_navigation or not _ready_for_queries:
		_set_navigating(false)
		return direct

	_repath_left -= delta
	if _repath_left <= 0.0:
		_repath_left = maxf(repath_interval, 0.016)
		_agent.target_position = goal

	# An agent on a map with no regions reports "finished" immediately and hands
	# back its own position — that is the silent failure this guard removes.
	if not _map_has_regions() or _agent.is_navigation_finished():
		_set_navigating(false)
		return direct

	var next_point: Vector2 = _agent.get_next_path_position()
	var step: Vector2 = next_point - global_position
	if step.length_squared() <= 0.0001:
		_set_navigating(false)
		return direct
	_set_navigating(true)
	return step.normalized()


func _map_has_regions() -> bool:
	var map: RID = _agent.get_navigation_map()
	if not map.is_valid():
		return false
	return NavigationServer2D.map_get_regions(map).size() > 0


func _set_navigating(value: bool) -> void:
	if value == _navigating:
		return
	_navigating = value
	navigation_mode_changed.emit(value)


func _find_target() -> Node2D:
	var best: Node2D = null
	var best_distance: float = INF
	for node in get_tree().get_nodes_in_group(target_group):
		var candidate := node as Node2D
		if candidate == null:
			continue
		var distance: float = global_position.distance_squared_to(candidate.global_position)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best
