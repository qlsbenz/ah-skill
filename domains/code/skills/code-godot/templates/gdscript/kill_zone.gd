# kill_zone.gd — the pit, the spikes, the lava. An Area2D that, when a target
# touches it, optionally damages it, optionally costs a life, and teleports it
# back to the active checkpoint.
#
# Expected scene tree (node name : type) — create it before attaching:
#   KillZone : Area2D                 <- attach this script here
#     CollisionShape2D : CollisionShape2D   (a wide, flat RectangleShape2D under
#                                            the level works as a fall-out plane)
#   Set collision_mask to the player's layer. monitoring is forced on in _ready().
#   unique_name_in_owner: not needed on any node.
#
# Autoload: none required. `GameManager` (lose_life) and `AudioManager` (sound)
# are used only when registered.
#
# Input actions: none.
#
# Works with: checkpoint.gd (asks the `checkpoint` group for the active one) and
# health.gd (found by name under the body, called through has_method — neither
# is a hard dependency).
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/level_1.tscn","actions":[
#     {"type":"attach_script","node_path":"root/KillZone","script_path":"scripts/kill_zone.gd",
#      "script_properties":{"damage":1,"costs_a_life":true}}]}'
extends Area2D

signal body_killed(body: Node2D)
signal body_respawned(body: Node2D, at: Vector2)

## Only bodies in this group are killed. Empty kills every body that touches it.
@export var target_group: StringName = &"player"
## 0 = no damage. Above 0, a child of the body named `health_child` is damaged
## through apply_damage() when it has that method.
@export var damage: int = 0
@export var health_child: StringName = &"Health"
## Call GameManager.lose_life() when that autoload exists.
@export var costs_a_life: bool = true
## false leaves the body where it is (for a hazard that only hurts).
@export var respawns: bool = true
## Used when no checkpoint is active. Empty falls back to where the body stood
## on the first frame of the level.
@export var fallback_marker_path: NodePath = ^""
## Played through AudioManager when that autoload exists.
@export var sound: AudioStream = null

var _start_positions: Dictionary[int, Vector2] = {}


func _ready() -> void:
	monitoring = true
	body_entered.connect(_on_body_entered)
	# One frame later: every level node is in the tree and every group set in
	# the .tscn is registered, so this sees the real spawn positions.
	_record_start_positions.call_deferred()


func _record_start_positions() -> void:
	for node in get_tree().get_nodes_in_group(target_group):
		var body := node as Node2D
		if body != null:
			_start_positions[body.get_instance_id()] = body.global_position


## Where `body` would come back. Checkpoint first, then the marker, then where
## it started. Returns the body's current position when nothing else is known.
func respawn_position_for(body: Node2D) -> Vector2:
	for node in get_tree().get_nodes_in_group(&"checkpoint"):
		var checkpoint := node as Node
		if checkpoint == null or not checkpoint.has_method(&"respawn_position"):
			continue
		if bool(checkpoint.get(&"active")):
			var from_checkpoint: Vector2 = checkpoint.call(&"respawn_position")
			return from_checkpoint
	var marker := get_node_or_null(fallback_marker_path) as Node2D
	if marker != null:
		return marker.global_position
	var key: int = body.get_instance_id()
	if _start_positions.has(key):
		return _start_positions[key]
	return body.global_position


func _on_body_entered(body: Node2D) -> void:
	if target_group != &"" and not body.is_in_group(target_group):
		return
	body_killed.emit(body)
	_play_sound()
	_apply_damage(body)
	_lose_life()
	if respawns:
		# body_entered fires inside the physics step; move the body after it.
		_respawn.call_deferred(body)


func _respawn(body: Node2D) -> void:
	if not is_instance_valid(body):
		return
	var target: Vector2 = respawn_position_for(body)
	body.global_position = target
	var character := body as CharacterBody2D
	if character != null:
		character.velocity = Vector2.ZERO
	body_respawned.emit(body, target)


func _apply_damage(body: Node2D) -> void:
	if damage <= 0:
		return
	var health: Node = body.get_node_or_null(NodePath(health_child))
	if health != null and health.has_method(&"apply_damage"):
		health.call(&"apply_damage", damage)


func _lose_life() -> void:
	if not costs_a_life:
		return
	var manager: Node = get_node_or_null(^"/root/GameManager")
	if manager != null and manager.has_method(&"lose_life"):
		manager.call(&"lose_life")


func _play_sound() -> void:
	if sound == null:
		return
	var audio: Node = get_node_or_null(^"/root/AudioManager")
	if audio != null and audio.has_method(&"play_sfx"):
		audio.call(&"play_sfx", sound)
