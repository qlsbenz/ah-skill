# player_third_person_3d.gd — third-person CharacterBody3D: a SpringArm3D camera
# that orbits the player with the mouse or the right stick, camera-relative
# movement, a body that turns toward where it is going, and a jump. Esc releases
# the mouse; a click takes it back.
#
# Expected scene tree (node name : type) — create it before attaching:
#   Player : CharacterBody3D          <- attach this script here
#     CollisionShape3D : CollisionShape3D   (shape = CapsuleShape3D, height 1.8)
#     Body : Node3D                         (the visual, so it can turn alone)
#       MeshInstance3D : MeshInstance3D
#     CameraPivot : Node3D                  (position.y = 1.2 — shoulder height)
#       SpringArm3D : SpringArm3D           (spring_length 4.0, collision_mask 1)
#         Camera3D : Camera3D
#   The pivot carries yaw AND pitch; the body only ever yaws. Rotating the
#   CharacterBody3D on X tips its capsule over and it falls through the floor.
#   unique_name_in_owner: not needed on any node.
#
# Autoload: no.
#
# Input actions required: move_left, move_right, move_forward, move_back, jump
# (ui_cancel is built in). The four look_* actions are OPTIONAL — with none of
# them defined the script simply skips gamepad look instead of erroring:
#   project_batch '{"actions":[
#     {"type":"add_input_action","action_name":"look_left","replace":true},
#     {"type":"add_input_event","action_name":"look_left","event":{"__resource_type":"InputEventJoypadMotion","properties":{"axis":2,"axis_value":-1.0}}},
#     {"type":"add_input_action","action_name":"look_right","replace":true},
#     {"type":"add_input_event","action_name":"look_right","event":{"__resource_type":"InputEventJoypadMotion","properties":{"axis":2,"axis_value":1.0}}},
#     {"type":"add_input_action","action_name":"look_up","replace":true},
#     {"type":"add_input_event","action_name":"look_up","event":{"__resource_type":"InputEventJoypadMotion","properties":{"axis":3,"axis_value":-1.0}}},
#     {"type":"add_input_action","action_name":"look_down","replace":true},
#     {"type":"add_input_event","action_name":"look_down","event":{"__resource_type":"InputEventJoypadMotion","properties":{"axis":3,"axis_value":1.0}}}]}'
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/player_3d.tscn","actions":[
#     {"type":"attach_script","node_path":"root","script_path":"scripts/player_third_person_3d.gd",
#      "script_properties":{"speed":5.0,"jump_velocity":4.5,"camera_distance":4.0}}]}'
extends CharacterBody3D

signal jumped
signal landed

@export var speed: float = 5.0
@export var sprint_speed: float = 8.0
@export var acceleration: float = 12.0
@export var jump_velocity: float = 4.5
## Radians per pixel of mouse movement.
@export var mouse_sensitivity: float = 0.0035
## Radians per second at full stick deflection.
@export var gamepad_sensitivity: float = 2.5
@export var pitch_min_degrees: float = -60.0
@export var pitch_max_degrees: float = 30.0
## SpringArm3D length. The arm pulls in by itself when a wall is in the way.
@export var camera_distance: float = 4.0
@export var turn_speed: float = 10.0
@export var capture_mouse_on_ready: bool = true
@export var sprint_action: StringName = &"sprint"

@onready var _pivot: Node3D = $CameraPivot
@onready var _spring: SpringArm3D = $CameraPivot/SpringArm3D
@onready var _camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var _body: Node3D = $Body

var _gravity: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
var _yaw: float = 0.0
var _pitch: float = 0.0
var _has_look_actions: bool = false
var _was_on_floor: bool = true


func _ready() -> void:
	_camera.current = true
	_spring.spring_length = camera_distance
	# Without this the arm collides with the player it is attached to and the
	# camera snaps into the character's head on the first frame.
	_spring.add_excluded_object(get_rid())
	_yaw = rotation.y
	_apply_look()
	_has_look_actions = (InputMap.has_action(&"look_left") and InputMap.has_action(&"look_right")
		and InputMap.has_action(&"look_up") and InputMap.has_action(&"look_down"))
	if capture_mouse_on_ready:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= motion.relative.x * mouse_sensitivity
		_pitch -= motion.relative.y * mouse_sensitivity
		_apply_look()
		return

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	if not _has_look_actions:
		return
	var look: Vector2 = Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")
	if look.length_squared() <= 0.0:
		return
	_yaw -= look.x * gamepad_sensitivity * delta
	_pitch -= look.y * gamepad_sensitivity * delta
	_apply_look()


func _apply_look() -> void:
	_pitch = clampf(_pitch, deg_to_rad(pitch_min_degrees), deg_to_rad(pitch_max_degrees))
	_pivot.rotation = Vector3(_pitch, _yaw, 0.0)


## The direction the camera is looking, flattened. Aim attacks with this.
func camera_forward() -> Vector3:
	return Vector3(-sin(_yaw), 0.0, -cos(_yaw))


func _physics_process(delta: float) -> void:
	var on_floor: bool = is_on_floor()
	if not on_floor:
		velocity.y -= _gravity * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity
		jumped.emit()

	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	# Yaw only: using the pivot's full basis would make the player walk into the
	# ground whenever the camera looks down.
	var yaw_basis := Basis(Vector3.UP, _yaw)
	var direction: Vector3 = yaw_basis * Vector3(input_dir.x, 0.0, input_dir.y)
	if direction.length_squared() > 0.0:
		direction = direction.normalized()

	var top_speed: float = sprint_speed if _sprinting() else speed
	var target: Vector3 = direction * top_speed
	velocity.x = move_toward(velocity.x, target.x, acceleration * top_speed * delta)
	velocity.z = move_toward(velocity.z, target.z, acceleration * top_speed * delta)

	if direction.length_squared() > 0.0 and _body != null:
		var wanted: float = atan2(-direction.x, -direction.z)
		_body.rotation.y = lerp_angle(_body.rotation.y, wanted, clampf(turn_speed * delta, 0.0, 1.0))

	move_and_slide()

	var grounded_now: bool = is_on_floor()
	if grounded_now and not _was_on_floor:
		landed.emit()
	_was_on_floor = grounded_now


func _sprinting() -> bool:
	return InputMap.has_action(sprint_action) and Input.is_action_pressed(sprint_action)
