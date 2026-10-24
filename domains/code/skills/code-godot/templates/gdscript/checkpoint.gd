# checkpoint.gd — the flag that decides where the player comes back. Touching it
# makes this the only active checkpoint in the level; kill_zone.gd (or any other
# script) asks the `checkpoint` group for the one that is active.
#
# Expected scene tree (node name : type) — create it before attaching:
#   Checkpoint : Area2D               <- attach this script here
#     CollisionShape2D : CollisionShape2D
#     Sprite2D : Sprite2D             (optional flag art)
#     Respawn : Marker2D              (optional — where the player reappears)
#   Set the Area2D's collision_mask to the player's layer or nothing triggers.
#   unique_name_in_owner: not needed on any node.
#
# Autoload: none required. `AudioManager` is used only when registered.
#
# Input actions: none.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/checkpoint.tscn","actions":[
#     {"type":"attach_script","node_path":"root","script_path":"scripts/checkpoint.gd",
#      "script_properties":{"marker_path":{"__type":"NodePath","value":"Respawn"}}}]}'
extends Area2D

signal activated(respawn_position: Vector2)
signal deactivated

## Optional Marker2D inside this scene. Empty means "respawn at my own origin".
@export var marker_path: NodePath = ^""
## Only a body in this group arms the checkpoint.
@export var activator_group: StringName = &"player"
## Played through AudioManager when that autoload exists.
@export var sound: AudioStream = null
## Arm this one at level start (put it on the first checkpoint of the level).
@export var active_on_ready: bool = false

## True on exactly one checkpoint at a time. Read it, do not assign it —
## activate() keeps the group consistent.
var active: bool = false


func _ready() -> void:
	monitoring = true
	add_to_group(&"checkpoint")
	body_entered.connect(_on_body_entered)
	if active_on_ready:
		activate()


## Where a respawning body should be placed. Always safe to call.
func respawn_position() -> Vector2:
	var marker := get_node_or_null(marker_path) as Node2D
	if marker != null:
		return marker.global_position
	return global_position


func activate() -> void:
	if active:
		return
	for node in get_tree().get_nodes_in_group(&"checkpoint"):
		var other := node as Node
		if other == null or other == self:
			continue
		if other.has_method(&"deactivate"):
			other.call(&"deactivate")
	active = true
	activated.emit(respawn_position())
	_play_sound()


func deactivate() -> void:
	if not active:
		return
	active = false
	deactivated.emit()


func _on_body_entered(body: Node2D) -> void:
	if activator_group != &"" and not body.is_in_group(activator_group):
		return
	activate()


func _play_sound() -> void:
	if sound == null:
		return
	var audio: Node = get_node_or_null(^"/root/AudioManager")
	if audio != null and audio.has_method(&"play_sfx"):
		audio.call(&"play_sfx", sound)
