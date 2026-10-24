# wave_spawner.gd — the round structure of an arena game: spawn N enemies, wait
# until they are all gone, pause, spawn the next wave, and say so with signals a
# HUD can bind to. It counts what it spawned, so an enemy that dies to anything
# (a bullet, a pit, a script) still advances the wave.
#
# Expected scene tree (node name : type) — create it before attaching:
#   Level : Node2D
#     WaveSpawner : Node2D            <- attach this script here
#       SpawnPoints : Node2D
#         Spawn0 : Marker2D
#         Spawn1 : Marker2D           (any number; they are used round-robin)
#   With no SpawnPoints child the spawner uses its own position for every enemy.
#   Enemies are added to `enemy_parent_path` (default: the spawner's parent).
#   unique_name_in_owner: mark it unique (`%WaveSpawner`) so the HUD can bind
#   to its signals with one path.
#
# Autoload: no.
#
# Input actions: none.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/arena.tscn","actions":[
#     {"type":"attach_script","node_path":"root/WaveSpawner","script_path":"scripts/wave_spawner.gd",
#      "script_properties":{"enemy_scene":{"__resource":"res://scenes/enemy.tscn"},
#                           "waves":[2,3,5],"spawn_interval":0.35,"wave_delay":1.0}}]}'
extends Node2D

## index is 1-based: the first wave is wave 1, which is what a HUD shows.
signal wave_started(index: int, count: int)
signal wave_cleared(index: int)
signal all_waves_cleared
signal enemy_spawned(enemy: Node)

@export var enemy_scene: PackedScene
## One entry per wave: how many enemies it spawns.
@export var waves: Array[int] = [3, 5, 8]
## Seconds between two spawns inside a wave.
@export var spawn_interval: float = 0.35
## Seconds between a wave being cleared and the next one starting.
@export var wave_delay: float = 1.5
@export var auto_start: bool = true
## Parent of the Marker2D spawn points. Empty = spawn at this node's position.
@export var spawn_points_path: NodePath = ^"SpawnPoints"
## Where the enemies are added. Empty = this node's parent.
@export var enemy_parent_path: NodePath = ^""
## Group every spawned enemy joins, so the level can count or clear them.
@export var enemy_group: StringName = &"enemy"

## 0 before the first wave, then 1-based.
var wave_index: int = 0
var alive_count: int = 0
var running: bool = false

var _to_spawn: int = 0
var _spawn_timer: float = 0.0
var _delay_timer: float = 0.0
var _spawn_points: Array[Node2D] = []
var _next_point: int = 0
var _finished: bool = false


func _ready() -> void:
	_collect_spawn_points()
	set_process(false)
	if auto_start:
		start()


## Begin at wave 1. Call it again after reset() to replay.
func start() -> void:
	if running or _finished:
		return
	if enemy_scene == null:
		push_error("wave_spawner '%s': set `enemy_scene` before starting." % name)
		return
	if waves.is_empty():
		push_warning("wave_spawner '%s': `waves` is empty — nothing to spawn." % name)
		return
	running = true
	set_process(true)
	_begin_wave(1)


func reset() -> void:
	running = false
	_finished = false
	wave_index = 0
	alive_count = 0
	_to_spawn = 0
	_delay_timer = 0.0
	_spawn_timer = 0.0
	set_process(false)


func wave_count() -> int:
	return waves.size()


func _process(delta: float) -> void:
	if not running:
		return
	if _delay_timer > 0.0:
		_delay_timer -= delta
		if _delay_timer <= 0.0:
			_begin_wave(wave_index + 1)
		return
	if _to_spawn <= 0:
		return
	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		_spawn_timer = spawn_interval
		_spawn_one()


func _begin_wave(index: int) -> void:
	if index > waves.size():
		running = false
		_finished = true
		set_process(false)
		all_waves_cleared.emit()
		return
	wave_index = index
	_to_spawn = maxi(waves[index - 1], 0)
	_spawn_timer = 0.0
	wave_started.emit(wave_index, _to_spawn)
	if _to_spawn == 0:
		_check_wave_cleared()


func _spawn_one() -> void:
	if enemy_scene == null:
		return
	var enemy: Node = enemy_scene.instantiate()
	if enemy_group != &"":
		enemy.add_to_group(enemy_group)
	# tree_exited fires for queue_free() and for a plain remove_child(), so a
	# pooled enemy counts as dead the moment it leaves the level.
	enemy.tree_exited.connect(_on_enemy_gone)
	_enemy_parent().add_child(enemy)
	# After add_child: global_position on a node outside the tree is only its
	# local position, so placing it first puts every enemy at the wrong spot
	# whenever the parent is not at the origin.
	var enemy_2d := enemy as Node2D
	if enemy_2d != null:
		enemy_2d.global_position = _next_spawn_position()
	_to_spawn -= 1
	alive_count += 1
	enemy_spawned.emit(enemy)


func _on_enemy_gone() -> void:
	alive_count = maxi(alive_count - 1, 0)
	_check_wave_cleared()


func _check_wave_cleared() -> void:
	# is_inside_tree() guards the teardown case: freeing the level makes every
	# enemy emit tree_exited, which would otherwise "clear" the last wave.
	if not running or not is_inside_tree() or _to_spawn > 0 or alive_count > 0:
		return
	wave_cleared.emit(wave_index)
	if wave_index >= waves.size():
		running = false
		_finished = true
		set_process(false)
		all_waves_cleared.emit()
		return
	_delay_timer = maxf(wave_delay, 0.0001)


func _enemy_parent() -> Node:
	var explicit: Node = get_node_or_null(enemy_parent_path)
	if explicit != null:
		return explicit
	var parent: Node = get_parent()
	return parent if parent != null else self


func _next_spawn_position() -> Vector2:
	if _spawn_points.is_empty():
		return global_position
	var point: Node2D = _spawn_points[_next_point]
	_next_point = (_next_point + 1) % _spawn_points.size()
	return point.global_position


func _collect_spawn_points() -> void:
	_spawn_points.clear()
	var holder: Node = get_node_or_null(spawn_points_path)
	if holder == null:
		return
	for child in holder.get_children():
		var point := child as Node2D
		if point != null:
			_spawn_points.append(point)
