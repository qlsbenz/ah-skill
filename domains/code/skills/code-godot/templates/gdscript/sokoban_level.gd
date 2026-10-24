# sokoban_level.gd — builds a crate-pushing puzzle from an ASCII map, keeps the
# win condition, and undoes moves. The movement rules are grid_movement.gd's;
# this script owns the level, the history and the goal.
#
# The map is the same one-character-per-cell format the skill uses everywhere:
#   #  wall        @  player        $  crate
#   .  floor       .  (space also)  *  crate already on a target
#   +  player standing on a target  o  target
#
# Expected scene tree (node name : type) — create it before attaching:
#   Puzzle : Node2D                   <- attach this script here
#     Player : Node2D                 (grid_movement.gd)
#       Sprite2D : Sprite2D
#   Everything else (walls, targets, crates) is created at load time as
#   Sprite2D children of this node, in the groups grid_movement.gd scans.
#   unique_name_in_owner: not needed — `player_path` names the token.
#
# Autoload: no. Uses `class_name GridMovement` from grid_movement.gd, so run
#   godot --headless --path /absolute/path/to/project --import
# after copying both files, before attaching this one.
#
# Input actions required: whatever grid_movement.gd uses, plus the ones named
# by `undo_action` and `restart_action` (default `undo`, `restart`). Missing
# actions are simply inactive — they are checked with InputMap.has_action.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/puzzle.tscn","actions":[
#     {"type":"attach_script","node_path":"root","script_path":"scripts/sokoban_level.gd",
#      "script_properties":{"ascii_level":"#####\n#@$o#\n#####",
#        "wall_texture":{"__resource":"res://art/wall.png"},
#        "crate_texture":{"__resource":"res://art/crate.png"},
#        "target_texture":{"__resource":"res://art/target.png"}}}]}'
extends Node2D

## Emitted once, the moment the last crate lands on the last target.
signal solved(moves: int, pushes: int)
signal progress_changed(on_target: int, total: int)
signal level_loaded(size: Vector2i)
signal move_undone(moves: int)

@export_multiline var ascii_level: String = "#######\n#.o.o.#\n#.$.$.#\n#..@..#\n#######"
@export var player_path: NodePath = ^"Player"
@export var wall_texture: Texture2D = null
@export var crate_texture: Texture2D = null
@export var target_texture: Texture2D = null
@export var undo_action: StringName = &"undo"
@export var restart_action: StringName = &"restart"
## Characters, in case the level came from a generator with other conventions.
@export var wall_char: String = "#"
@export var crate_char: String = "$"
@export var target_char: String = "o"
@export var player_char: String = "@"
@export var crate_on_target_char: String = "*"
@export var player_on_target_char: String = "+"

var moves: int = 0
var pushes: int = 0
var size: Vector2i = Vector2i.ZERO
## True once every target holds a crate. A plain variable as well as a method,
## so a scenario `assert` step can read it without calling anything.
var is_complete: bool = false

var _movement: GridMovement = null
var _targets: Dictionary = {}
var _history: Array[Dictionary] = []
var _spawned: Array[Node] = []


func _ready() -> void:
	_movement = get_node_or_null(player_path) as GridMovement
	if _movement == null:
		push_error("sokoban_level '%s': `player_path` must point at a node with grid_movement.gd." % name)
		return
	_movement.stepped.connect(_on_stepped)
	_movement.step_finished.connect(_on_step_finished)
	load_level(ascii_level)


## Rebuild the level from an ASCII map. Safe to call again at any time.
func load_level(text: String) -> void:
	_clear()
	var rows: PackedStringArray = _rows(text)
	var width: int = 0
	var player_cell: Vector2i = Vector2i.ZERO
	for y in rows.size():
		var row: String = rows[y]
		width = maxi(width, row.length())
		for x in row.length():
			var glyph: String = row[x]
			var here: Vector2i = Vector2i(x, y)
			if glyph == wall_char:
				_spawn(wall_texture, here, &"wall")
			elif glyph == target_char:
				_add_target(here)
			elif glyph == crate_char:
				_spawn(crate_texture, here, &"crate")
			elif glyph == crate_on_target_char:
				_add_target(here)
				_spawn(crate_texture, here, &"crate")
			elif glyph == player_char:
				player_cell = here
			elif glyph == player_on_target_char:
				_add_target(here)
				player_cell = here
	size = Vector2i(width, rows.size())
	moves = 0
	pushes = 0
	is_complete = false
	_history.clear()
	if _movement != null:
		_movement.set_cell(player_cell)
	level_loaded.emit(size)
	_report_progress()


func restart() -> void:
	load_level(ascii_level)


## How many targets currently hold a crate.
func covered() -> int:
	return GridMovement.covered_count(_targets, _crate_cells())


func target_count() -> int:
	return _targets.size()


func is_solved() -> bool:
	return is_complete


## Take back the last accepted step, crate and all. Returns false when the
## history is empty.
func undo() -> bool:
	if _history.is_empty() or _movement == null:
		return false
	var last: Dictionary = _history.pop_back()
	if bool(last["pushed"]):
		var crate_from: Vector2i = last["crate_from"]
		var crate_to: Vector2i = last["crate_to"]
		var crate := _crate_at(crate_to) as Node2D
		if crate != null:
			crate.position = _movement.crate_world_position(crate_from)
		pushes = maxi(pushes - 1, 0)
	var from_cell: Vector2i = last["from"]
	_movement.set_cell(from_cell)
	moves = maxi(moves - 1, 0)
	is_complete = false
	move_undone.emit(moves)
	_report_progress()
	return true


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(undo_action) and event.is_action_pressed(undo_action):
		undo()
		get_viewport().set_input_as_handled()
	elif InputMap.has_action(restart_action) and event.is_action_pressed(restart_action):
		restart()
		get_viewport().set_input_as_handled()


func _on_stepped(outcome: Dictionary) -> void:
	_history.append(outcome)
	moves += 1
	if bool(outcome["pushed"]):
		pushes += 1


func _on_step_finished(_cell: Vector2i) -> void:
	_report_progress()


func _report_progress() -> void:
	var crates: Dictionary = _crate_cells()
	var on_target: int = GridMovement.covered_count(_targets, crates)
	progress_changed.emit(on_target, _targets.size())
	if is_complete or _targets.is_empty():
		return
	if GridMovement.all_targets_covered(_targets, crates):
		is_complete = true
		solved.emit(moves, pushes)


func _crate_cells() -> Dictionary:
	if _movement == null:
		return {}
	return _movement.cells_in_group(&"crate")


func _crate_at(crate_cell: Vector2i) -> Node:
	var crates: Dictionary = _crate_cells()
	if not crates.has(crate_cell):
		return null
	var crate: Node = crates[crate_cell]
	return crate


func _add_target(here: Vector2i) -> void:
	_targets[here] = true
	_spawn(target_texture, here, &"target")


# A target is drawn *under* the crates, so it is added first and the crate's
# z_index lifts it above. Nodes with no texture are still created: the grid
# rules read positions, not pixels, so a level works before the art exists.
func _spawn(texture: Texture2D, here: Vector2i, group: StringName) -> Node2D:
	var sprite := Sprite2D.new()
	sprite.name = "%s_%d_%d" % [String(group).capitalize(), here.x, here.y]
	sprite.texture = texture
	sprite.centered = true
	sprite.z_index = 1 if group == &"crate" else 0
	if group != &"target":
		sprite.add_to_group(group)
	add_child(sprite)
	if _movement != null:
		sprite.position = _movement.cell_to_world(here)
	_spawned.append(sprite)
	return sprite


func _clear() -> void:
	for node in _spawned:
		if is_instance_valid(node):
			node.free()
	_spawned.clear()
	_targets.clear()


func _rows(text: String) -> PackedStringArray:
	var rows: PackedStringArray = PackedStringArray()
	for line in text.replace("\r\n", "\n").split("\n"):
		# A trailing newline in an exported multiline string is normal; an empty
		# row in the middle of a map is not, so only the tail is dropped.
		rows.append(line)
	while rows.size() > 0 and rows[rows.size() - 1].strip_edges() == "":
		rows.remove_at(rows.size() - 1)
	return rows
