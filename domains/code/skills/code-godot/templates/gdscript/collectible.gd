# collectible.gd — a coin, gem, heart or key. An Area2D that fires once when a
# node of the right group touches it, then tells the score keeper and the sound
# player about it if the project happens to have them.
#
# Expected scene tree (node name : type) — create it before attaching:
#   Coin : Area2D                     <- attach this script here
#     CollisionShape2D : CollisionShape2D   (shape = CircleShape2D)
#     Sprite2D : Sprite2D
#   The Area2D needs collision_mask set to the layer the player occupies, or
#   body_entered never fires. monitoring is forced on in _ready().
#   unique_name_in_owner: not needed on any node.
#
# Autoload: none required. `GameManager` (score) and `AudioManager` (sound) are
# used only when they are registered — the script looks them up at /root and
# stays silent when they are not there, so a coin works in a bare project.
#
# Input actions: none.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/coin.tscn","actions":[
#     {"type":"attach_script","node_path":"root","script_path":"scripts/collectible.gd",
#      "script_properties":{"value":10,"collector_group":{"__type":"StringName","value":"player"}}}]}'
extends Area2D

## Emitted once, before the node frees itself.
signal collected(value: int)

## Score (or heal, or ammo) this pickup is worth.
@export var value: int = 1
## Only a body/area in this group can pick it up. Empty accepts anything.
@export var collector_group: StringName = &"player"
## Played through AudioManager when that autoload exists. Leave null for silence.
@export var sound: AudioStream = null
## Call GameManager.add_score(value) when that autoload exists.
@export var scores: bool = true
## false keeps the node alive (hide it yourself) — useful for pooled pickups.
@export var free_on_collect: bool = true

var _spent: bool = false


func _ready() -> void:
	monitoring = true
	add_to_group(&"collectible")
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)


func _on_body_entered(body: Node2D) -> void:
	_collect(body)


func _on_area_entered(area: Area2D) -> void:
	_collect(area)


## Also callable directly, so a "collect all" cheat or a magnet pickup radius
## can use the same path as a physical touch.
func collect(collector: Node) -> bool:
	return _collect(collector)


func _collect(collector: Node) -> bool:
	if _spent:
		return false
	if collector_group != &"" and not collector.is_in_group(collector_group):
		return false
	_spent = true
	# Stop overlapping before the frame ends, or a second body already inside
	# the area collects the same coin again.
	set_deferred(&"monitoring", false)
	collected.emit(value)
	_play_sound()
	_add_score()
	if free_on_collect:
		queue_free()
	return true


# Both helpers are deliberately duck-typed through /root: naming the autoloads
# directly would make this file fail to parse in a project that has not
# registered them, which is a much worse failure than a silent coin.
func _play_sound() -> void:
	if sound == null:
		return
	var audio: Node = get_node_or_null(^"/root/AudioManager")
	if audio != null and audio.has_method(&"play_sfx"):
		audio.call(&"play_sfx", sound)


func _add_score() -> void:
	if not scores:
		return
	var manager: Node = get_node_or_null(^"/root/GameManager")
	if manager != null and manager.has_method(&"add_score"):
		manager.call(&"add_score", value)
