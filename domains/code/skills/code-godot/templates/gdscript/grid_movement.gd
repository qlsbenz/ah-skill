# grid_movement.gd — tile-by-tile movement with a tween: one key press moves
# exactly one cell, walls block, crates are pushed. The rules live in
# `resolve_step()`, a **static pure function** with no nodes in it, so a unit
# test can check "a crate cannot be pushed into a wall" without a scene:
#
#   const Grid = preload("res://scripts/grid_movement.gd")
#   var outcome: Dictionary = Grid.resolve_step(Vector2i(1, 1), Vector2i.RIGHT,
#       {Vector2i(3, 1): true}, {Vector2i(2, 1): true})
#   assert_false(outcome["moved"])
#   assert_eq(outcome["reason"], "crate_into_wall")
#
# Expected scene tree (node name : type) — create it before attaching:
#   Player : Node2D                   <- attach this script here
#     Sprite2D : Sprite2D
#   Walls are any Node2D in `wall_group`, crates any Node2D in `crate_group`.
#   Neither needs a collider: this is a grid, not a physics world.
#   unique_name_in_owner: mark it unique (`%Player`) so the level can reach it.
#
# Autoload: no. Declares `class_name GridMovement`; run
#   godot --headless --path /absolute/path/to/project --import
# after copying it, before any script annotates a variable as `GridMovement`.
#
# Input actions required: move_left, move_right, move_up, move_down (the names
# are exported, so rename them there rather than here). It polls with
# `is_action_just_pressed`, so both scenario `key` steps and `action` steps
# drive it.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/puzzle.tscn","actions":[
#     {"type":"attach_script","node_path":"root/Player","script_path":"scripts/grid_movement.gd",
#      "script_properties":{"cell_size":{"__type":"Vector2i","x":16,"y":16},"step_time":0.12}}]}'
class_name GridMovement
extends Node2D

## Emitted when a step is accepted, before the tween runs. `outcome` is exactly
## what resolve_step() returned.
signal stepped(outcome: Dictionary)
## Emitted when the step was refused. `reason` is "wall", "crate_into_wall",
## "crate_into_crate" or "no_direction".
signal step_blocked(reason: String)
## Emitted when the tween has finished and the token is on `cell`.
signal step_finished(cell: Vector2i)

@export var cell_size: Vector2i = Vector2i(16, 16)
## World position of the top-left corner of cell (0, 0).
@export var origin: Vector2 = Vector2.ZERO
## true places a token at the centre of its cell (what centred Sprite2Ds want).
@export var centered: bool = true
## Seconds per step. 0 teleports.
@export var step_time: float = 0.12
@export var wall_group: StringName = &"wall"
@export var crate_group: StringName = &"crate"
@export var action_left: StringName = &"move_left"
@export var action_right: StringName = &"move_right"
@export var action_up: StringName = &"move_up"
@export var action_down: StringName = &"move_down"
## Keep stepping while a direction stays held.
@export var move_while_held: bool = true
## Set false while a menu is open, or to drive the token from a script only.
@export var accept_input: bool = true

## The cell the token occupies. Assign through set_cell(), not directly.
var cell: Vector2i = Vector2i.ZERO
## True while the step tween is running; input is ignored until it lands. It is
## a plain variable as well as a method so a scenario `wait_until` can watch it.
var moving: bool = false

var _tween: Tween = null


# --- pure rules (no nodes, no tree — unit-test these) ------------------------

## What one step does. `walls` and `crates` are Dictionaries keyed by Vector2i
## (the values are never read), so lookups are O(1) and a test can build them
## as literals. Never touches the scene, never mutates its arguments.
static func resolve_step(from: Vector2i, direction: Vector2i, walls: Dictionary, crates: Dictionary) -> Dictionary:
	var outcome: Dictionary = {
		"moved": false,
		"reason": "",
		"from": from,
		"to": from,
		"pushed": false,
		"crate_from": from,
		"crate_to": from,
	}
	if direction == Vector2i.ZERO:
		outcome["reason"] = "no_direction"
		return outcome

	var target: Vector2i = from + direction
	if walls.has(target):
		outcome["reason"] = "wall"
		return outcome

	if crates.has(target):
		var beyond: Vector2i = target + direction
		if walls.has(beyond):
			outcome["reason"] = "crate_into_wall"
			return outcome
		if crates.has(beyond):
			outcome["reason"] = "crate_into_crate"
			return outcome
		outcome["pushed"] = true
		outcome["crate_from"] = target
		outcome["crate_to"] = beyond

	outcome["moved"] = true
	outcome["to"] = target
	return outcome


## True when every cell of `targets` holds a crate. The win condition of a
## sokoban level, and pure for the same reason.
static func all_targets_covered(targets: Dictionary, crates: Dictionary) -> bool:
	if targets.is_empty():
		return false
	for target_cell in targets.keys():
		if not crates.has(target_cell):
			return false
	return true


## How many of `targets` currently hold a crate.
static func covered_count(targets: Dictionary, crates: Dictionary) -> int:
	var count: int = 0
	for target_cell in targets.keys():
		if crates.has(target_cell):
			count += 1
	return count


# --- grid geometry -----------------------------------------------------------

func cell_to_world(grid_cell: Vector2i) -> Vector2:
	var corner: Vector2 = origin + Vector2(grid_cell * cell_size)
	if centered:
		return corner + Vector2(cell_size) * 0.5
	return corner


func world_to_cell(point: Vector2) -> Vector2i:
	var local: Vector2 = point - origin
	return Vector2i(floori(local.x / float(cell_size.x)), floori(local.y / float(cell_size.y)))


# --- node behaviour ----------------------------------------------------------

func _ready() -> void:
	cell = world_to_cell(position)
	position = cell_to_world(cell)


func is_moving() -> bool:
	return moving


## Teleport (or glide) the token to a cell without any rule check.
func set_cell(new_cell: Vector2i, animate: bool = false) -> void:
	cell = new_cell
	var destination: Vector2 = cell_to_world(new_cell)
	if animate and step_time > 0.0 and is_inside_tree():
		_glide(self, destination)
		return
	_kill_tween()
	moving = false
	position = destination


## Try to move one cell. Returns the same Dictionary resolve_step() produced, so
## a caller can record it for undo.
func try_step(direction: Vector2i) -> Dictionary:
	var walls: Dictionary = cells_in_group(wall_group)
	var crates: Dictionary = cells_in_group(crate_group)
	var outcome: Dictionary = resolve_step(cell, direction, walls, crates)
	if not outcome["moved"]:
		step_blocked.emit(str(outcome["reason"]))
		return outcome

	if bool(outcome["pushed"]):
		var crate := crates[outcome["crate_from"]] as Node2D
		if crate != null:
			_glide(crate, crate_world_position(outcome["crate_to"]))

	cell = outcome["to"]
	stepped.emit(outcome)
	_glide(self, cell_to_world(cell))
	return outcome


## Where a crate node sits for a given cell. Same grid, separate function so a
## project whose crates are anchored differently can override it.
func crate_world_position(crate_cell: Vector2i) -> Vector2:
	return cell_to_world(crate_cell)


## Every Node2D of `group`, keyed by the cell it stands on. It reads `position`,
## not `global_position`, so the token, the walls and the crates must all be
## children of the same node — which is what sokoban_level.gd builds.
func cells_in_group(group: StringName) -> Dictionary:
	var cells: Dictionary = {}
	if not is_inside_tree():
		return cells
	for node in get_tree().get_nodes_in_group(group):
		var node_2d := node as Node2D
		if node_2d == null:
			continue
		cells[world_to_cell(node_2d.position)] = node_2d
	return cells


func _process(_delta: float) -> void:
	if not accept_input or moving:
		return
	var direction: Vector2i = _pressed_direction()
	if direction != Vector2i.ZERO:
		try_step(direction)


func _pressed_direction() -> Vector2i:
	if _just_pressed(action_left):
		return Vector2i.LEFT
	if _just_pressed(action_right):
		return Vector2i.RIGHT
	if _just_pressed(action_up):
		return Vector2i.UP
	if _just_pressed(action_down):
		return Vector2i.DOWN
	if not move_while_held:
		return Vector2i.ZERO
	if _held(action_left):
		return Vector2i.LEFT
	if _held(action_right):
		return Vector2i.RIGHT
	if _held(action_up):
		return Vector2i.UP
	if _held(action_down):
		return Vector2i.DOWN
	return Vector2i.ZERO


# InputMap.has_action first: a missing action would otherwise print
# `The InputMap action "move_left" doesn't exist` sixty times a second.
func _just_pressed(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_just_pressed(action)


func _held(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


func _glide(node: Node2D, destination: Vector2) -> void:
	if step_time <= 0.0 or not is_inside_tree():
		node.position = destination
		if node == self:
			_finish_step()
		return
	var tween: Tween = create_tween()
	tween.tween_property(node, "position", destination, step_time)
	if node == self:
		_kill_tween()
		_tween = tween
		moving = true
		tween.finished.connect(_finish_step)


func _finish_step() -> void:
	moving = false
	step_finished.emit(cell)


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
