# shooter.gd — the trigger. Put it on a player, a turret or an enemy: it counts
# down a fire rate, takes a bullet out of an object_pool.gd (or instantiates one)
# and launches it from a muzzle Marker2D toward the mouse or the owner's facing.
#
# Expected scene tree (node name : type) — create it before attaching:
#   Player : CharacterBody2D
#     Shooter : Node2D                <- attach this script here
#       Muzzle : Marker2D             (where the bullet appears)
#   The bullets are added to `projectile_parent_path` (default: the current
#   scene root), never under the shooter — a bullet parented to the player
#   would fly along with the player.
#   unique_name_in_owner: mark the pool unique (`%BulletPool`) and point
#   `pool_path` at it, or leave it empty to instantiate one bullet per shot.
#
# Autoload: none required. `AudioManager` is used only when registered.
#
# Input actions required: the action named by `fire_action` (default `shoot`):
#   project_batch '{"actions":[
#     {"type":"add_input_action","action_name":"shoot","replace":true},
#     {"type":"add_input_event","action_name":"shoot","event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":74}}}]}'
#
# Requires projectile.gd in the project (it annotates `class_name Projectile`),
# so run `godot --headless --path /absolute/path/to/project --import` after
# copying both.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/player.tscn","actions":[
#     {"type":"attach_script","node_path":"root/Shooter","script_path":"scripts/shooter.gd",
#      "script_properties":{"projectile_scene":{"__resource":"res://scenes/bullet.tscn"},
#                           "fire_rate":6.0,"aim_mode":1}}]}'
extends Node2D

signal fired(projectile: Projectile)
## Emitted when the trigger was pulled but nothing came out (empty pool).
signal misfired

enum AimMode {
	## Toward the mouse cursor. The usual twin-stick / tower-defence aim.
	MOUSE,
	## The owner's facing — asks the parent for facing() (player_topdown_2d.gd
	## has one) and falls back to `aim_direction`.
	FACING,
	## Always `aim_direction`, rotated by this node's own rotation.
	FIXED,
}

@export var projectile_scene: PackedScene
## An object_pool.gd node. Empty instantiates a fresh bullet per shot.
@export var pool_path: NodePath = ^""
## Marker2D the bullet starts from. Empty = this node's own position.
@export var muzzle_path: NodePath = ^"Muzzle"
## Where the bullet is added. Empty = the current scene root.
@export var projectile_parent_path: NodePath = ^""
## Shots per second.
@export var fire_rate: float = 6.0
@export var aim_mode: AimMode = AimMode.MOUSE
@export var fire_action: StringName = &"shoot"
## Fire without any input — turrets, hazards, the tutorial dummy.
@export var auto_fire: bool = false
@export var aim_direction: Vector2 = Vector2.RIGHT
## Played through AudioManager when that autoload exists.
@export var sound: AudioStream = null

var _cooldown: float = 0.0
var _has_action: bool = false


func _ready() -> void:
	_has_action = InputMap.has_action(fire_action)
	if not _has_action and not auto_fire:
		# Silence here would look exactly like a broken gun.
		push_warning("shooter '%s': no input action '%s' — add it with project_batch add_input_action, or set auto_fire." % [name, fire_action])


func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	if _cooldown > 0.0:
		return
	var wants_to_fire: bool = auto_fire or (_has_action and Input.is_action_pressed(fire_action))
	if wants_to_fire:
		fire()


func can_fire() -> bool:
	return _cooldown <= 0.0


## Where the next bullet comes out, in world space.
func muzzle_position() -> Vector2:
	var muzzle := get_node_or_null(muzzle_path) as Node2D
	return muzzle.global_position if muzzle != null else global_position


## The unit vector the next bullet takes.
func aim() -> Vector2:
	var direction: Vector2 = aim_direction
	match aim_mode:
		AimMode.MOUSE:
			direction = get_global_mouse_position() - muzzle_position()
		AimMode.FACING:
			var source: Node = get_parent()
			if source != null and source.has_method(&"facing"):
				var facing: Vector2 = source.call(&"facing")
				direction = facing
		AimMode.FIXED:
			direction = aim_direction.rotated(global_rotation)
	if direction.length_squared() <= 0.0:
		return Vector2.RIGHT
	return direction.normalized()


## Fires now, ignoring the cooldown check (it still resets it). Returns the
## bullet, or null when the pool was empty or no scene is configured.
func fire() -> Projectile:
	_cooldown = 1.0 / maxf(fire_rate, 0.001)
	var bullet: Projectile = _take_projectile()
	if bullet == null:
		misfired.emit()
		return null
	var parent: Node = _projectile_parent()
	if bullet.get_parent() != parent:
		parent.add_child(bullet)
	bullet.launch(muzzle_position(), aim(), _pool())
	_play_sound()
	fired.emit(bullet)
	return bullet


func _pool() -> Node:
	return get_node_or_null(pool_path)


func _projectile_parent() -> Node:
	var explicit: Node = get_node_or_null(projectile_parent_path)
	if explicit != null:
		return explicit
	var current: Node = get_tree().current_scene
	return current if current != null else get_parent()


func _take_projectile() -> Projectile:
	var pool: Node = _pool()
	if pool != null and pool.has_method(&"acquire"):
		var pooled: Variant = pool.call(&"acquire")
		var from_pool := pooled as Projectile
		if from_pool == null and pooled != null:
			# A pool full of something else is silence with a full magazine.
			push_error("shooter '%s': the pool at '%s' does not hold projectile.gd scenes." % [name, pool_path])
		return from_pool
	if projectile_scene == null:
		push_error("shooter '%s': set `projectile_scene` (or `pool_path`) before firing." % name)
		return null
	return projectile_scene.instantiate() as Projectile


func _play_sound() -> void:
	if sound == null:
		return
	var audio: Node = get_node_or_null(^"/root/AudioManager")
	if audio != null and audio.has_method(&"play_sfx"):
		audio.call(&"play_sfx", sound)
