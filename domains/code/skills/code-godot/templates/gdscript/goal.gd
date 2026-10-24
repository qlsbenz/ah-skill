# goal.gd — the exit door. An Area2D that fires once when the player reaches it,
# optionally only after a required number of pickups, then loads the next scene.
#
# Expected scene tree (node name : type) — create it before attaching:
#   Goal : Area2D                     <- attach this script here
#     CollisionShape2D : CollisionShape2D
#     Sprite2D : Sprite2D             (optional door art)
#   Set collision_mask to the player's layer. monitoring is forced on in _ready().
#   unique_name_in_owner: not needed on any node.
#
# Autoload: none required. `SceneTransition` (fade + change_scene) and
# `AudioManager` (sound) are used only when they are registered; without them
# the goal calls get_tree().change_scene_to_file directly.
#
# Input actions: none.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/level_1.tscn","actions":[
#     {"type":"attach_script","node_path":"root/Goal","script_path":"scripts/goal.gd",
#      "script_properties":{"required_group":{"__type":"StringName","value":"collectible"},"next_scene_path":""}}]}'
extends Area2D

## Emitted the first time the goal is reached with the requirement satisfied.
signal reached(by: Node2D)
## Emitted when the player arrives too early; `remaining` is how many are left.
signal locked(remaining: int)

@export var target_group: StringName = &"player"
## Every node still in this group blocks the goal. Leave empty for a goal that
## is always open. `collectible` pairs with collectible.gd out of the box.
@export var required_group: StringName = &""
## Scene loaded on success. Empty = stay here and just emit `reached`.
@export_file("*.tscn") var next_scene_path: String = ""
## Seconds between reaching the goal and the scene change.
@export var exit_delay: float = 0.6
## Played through AudioManager when that autoload exists.
@export var sound: AudioStream = null

var _done: bool = false


func _ready() -> void:
	monitoring = true
	body_entered.connect(_on_body_entered)


## How many nodes still block the goal. 0 means it is open.
func remaining() -> int:
	if required_group == &"":
		return 0
	return get_tree().get_nodes_in_group(required_group).size()


func is_open() -> bool:
	return remaining() == 0


func _on_body_entered(body: Node2D) -> void:
	if _done:
		return
	if target_group != &"" and not body.is_in_group(target_group):
		return
	var left: int = remaining()
	if left > 0:
		locked.emit(left)
		return
	_done = true
	reached.emit(body)
	_play_sound()
	if next_scene_path != "":
		_leave.call_deferred()


func _leave() -> void:
	if exit_delay > 0.0:
		await get_tree().create_timer(exit_delay).timeout
	if not is_inside_tree():
		return
	var transition: Node = get_node_or_null(^"/root/SceneTransition")
	if transition != null and transition.has_method(&"change_scene"):
		transition.call(&"change_scene", next_scene_path)
		return
	var error: int = get_tree().change_scene_to_file(next_scene_path)
	if error != OK:
		push_error("goal.gd: could not load '%s' (error %d)." % [next_scene_path, error])


func _play_sound() -> void:
	if sound == null:
		return
	var audio: Node = get_node_or_null(^"/root/AudioManager")
	if audio != null and audio.has_method(&"play_sfx"):
		audio.call(&"play_sfx", sound)
