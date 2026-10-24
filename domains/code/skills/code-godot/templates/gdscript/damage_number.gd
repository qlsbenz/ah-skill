# damage_number.gd — the little number that floats off a hit and disappears. A
# Label that tweens itself and then frees itself, so the caller is one line:
#   var number := DAMAGE_NUMBER.instantiate() as DamageNumber
#   add_child(number)
#   number.popup(3, enemy.global_position)
#
# Expected scene tree (node name : type) — create it before attaching:
#   DamageNumber : Label              <- attach this script here
#   Nothing else. A Label is a Control, and a Control may live under a Node2D:
#   it draws in the same canvas, so world coordinates line up.
#   unique_name_in_owner: not needed.
#
# Autoload: no. Declares `class_name DamageNumber`; run
#   godot --headless --path /absolute/path/to/project --import
# after copying it, before any script annotates a variable as `DamageNumber`.
#
# Input actions: none.
#
# popup() must be called **after** the node is in the tree — create_tween() on a
# node outside the tree fails with `Tween can't be created on a Node that is not
# inside the SceneTree`.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/damage_number.tscn","create_if_missing":true,
#     "root_node_type":"Label","root_node_name":"DamageNumber",
#     "actions":[{"type":"attach_script","node_path":"root","script_path":"scripts/damage_number.gd"}]}'
class_name DamageNumber
extends Label

signal finished

## Pixels travelled upward over the whole animation.
@export var rise_distance: float = 24.0
@export var duration: float = 0.6
## Horizontal scatter, so two hits in the same frame do not overlap exactly.
@export var scatter: float = 6.0
@export var normal_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var critical_color: Color = Color(1.0, 0.72, 0.18, 1.0)
@export var critical_scale: float = 1.4
## Free the node when the tween ends. false leaves it for a pool to reclaim.
@export var free_when_done: bool = true

var _tween: Tween = null


func _ready() -> void:
	# Numbers are decoration: they must never eat a click meant for the game.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 100


## Show `amount` at a world position and start the animation. `at` defaults to
## wherever the node already is, so a spawner can place it first.
func popup(amount: int, at: Vector2 = Vector2.INF, critical: bool = false) -> void:
	text = str(amount)
	# reset_size() makes size the text's minimum size right now; without it the
	# centering below reads size (0, 0) until the next layout pass.
	reset_size()
	modulate = critical_color if critical else normal_color
	scale = Vector2.ONE * (critical_scale if critical else 1.0)

	var anchor: Vector2 = global_position if at == Vector2.INF else at
	var offset: Vector2 = Vector2(randf_range(-scatter, scatter), 0.0)
	global_position = anchor + offset - Vector2(size.x * 0.5, size.y)

	if not is_inside_tree():
		push_error("damage_number: call popup() after add_child(), not before.")
		return

	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	var rise: PropertyTweener = _tween.tween_property(self, "position:y", position.y - rise_distance, duration)
	rise.set_trans(Tween.TRANS_QUAD)
	rise.set_ease(Tween.EASE_OUT)
	var fade: PropertyTweener = _tween.tween_property(self, "modulate:a", 0.0, duration)
	fade.set_ease(Tween.EASE_IN)
	_tween.chain().tween_callback(_on_tween_finished)


func _on_tween_finished() -> void:
	finished.emit()
	if free_when_done:
		queue_free()
