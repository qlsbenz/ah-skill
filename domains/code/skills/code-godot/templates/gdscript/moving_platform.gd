# moving_platform.gd — an AnimatableBody2D that walks a list of offsets and
# carries whatever stands on it. AnimatableBody2D (not StaticBody2D, not
# CharacterBody2D) is the node that moves under physics control, and
# `sync_to_physics` is what makes a CharacterBody2D riding it move with it
# instead of sliding off or jittering.
#
# Expected scene tree (node name : type) — create it before attaching:
#   Platform : AnimatableBody2D       <- attach this script here
#     CollisionShape2D : CollisionShape2D   (shape = RectangleShape2D)
#     Sprite2D : Sprite2D             (optional)
#   collision_layer must contain the layer the player's collision_mask scans
#   (layer 1 "world" in the playbooks), or the player falls straight through.
#   unique_name_in_owner: not needed on any node.
#
# Autoload: no.
#
# Input actions: none.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/level_1.tscn","actions":[
#     {"type":"attach_script","node_path":"root/Platform","script_path":"scripts/moving_platform.gd",
#      "script_properties":{"speed":40.0,"wait_time":0.5,
#        "points":[{"__type":"Vector2","x":0,"y":0},{"__type":"Vector2","x":96,"y":0}]}}]}'
extends AnimatableBody2D

signal arrived(index: int)

## Stops, **relative to where the platform starts**. The first entry is normally
## (0, 0). Fewer than two points disables the movement and says so.
@export var points: Array[Vector2] = [Vector2.ZERO, Vector2(96.0, 0.0)]
@export var speed: float = 40.0
## Seconds paused at each stop.
@export var wait_time: float = 0.5
## true walks back along the list, false jumps back to the first point.
@export var ping_pong: bool = true
@export var moving: bool = true

var _origin: Vector2 = Vector2.ZERO
var _index: int = 1
var _step: int = 1
var _wait_left: float = 0.0


func _ready() -> void:
	# The default is already true in 4.7; setting it here means a platform built
	# by a script that forgot the property still carries its rider.
	sync_to_physics = true
	_origin = position
	if points.size() < 2:
		push_warning("moving_platform '%s': needs at least two points — it will not move." % name)
		set_physics_process(false)
		return
	_index = 1


## Where the platform is heading right now, in world space.
func target_position() -> Vector2:
	if points.size() < 2:
		return global_position
	var local_target: Vector2 = _origin + points[_index]
	return global_position + (local_target - position)


func _physics_process(delta: float) -> void:
	if not moving:
		return
	if _wait_left > 0.0:
		_wait_left -= delta
		return

	var target: Vector2 = _origin + points[_index]
	# sync_to_physics moves the body through the physics server, so the write
	# has to happen in _physics_process — never in _process, never in a Tween.
	position = position.move_toward(target, speed * delta)
	if position.distance_squared_to(target) > 0.0001:
		return

	position = target
	arrived.emit(_index)
	_wait_left = wait_time
	_advance()


func _advance() -> void:
	var count: int = points.size()
	if count < 2:
		return
	if ping_pong:
		if _index + _step < 0 or _index + _step >= count:
			_step = -_step
		_index += _step
	else:
		_index = (_index + 1) % count
	_index = clampi(_index, 0, count - 1)
