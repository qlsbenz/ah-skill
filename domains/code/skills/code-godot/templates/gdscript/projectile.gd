# projectile.gd — a bullet that travels, expires and goes back to its pool. It
# moves; a child Hitbox (hitbox.gd) does the damage; object_pool.gd owns the
# instances. Nothing here instantiates or frees during play.
#
# Expected scene tree (node name : type) — create it before attaching:
#   Bullet : Area2D                   <- attach this script here
#     CollisionShape2D : CollisionShape2D   (the "did I hit a wall" shape)
#     Hitbox : Area2D                 (hitbox.gd, its own CollisionShape2D)
#       CollisionShape2D : CollisionShape2D
#   The root Area2D's collision_mask scans the world/enemy layers it should stop
#   on; the Hitbox's layer/mask pair is the damage channel (layer 8 in the
#   playbooks). Leave `hitbox_path` empty for a bullet that only travels.
#   unique_name_in_owner: not needed on any node.
#
# Autoload: no. Declares `class_name Projectile`; run
#   godot --headless --path /absolute/path/to/project --import
# after copying it, before any script annotates a variable as `Projectile`.
#
# Input actions: none.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/bullet.tscn","actions":[
#     {"type":"attach_script","node_path":"root","script_path":"scripts/projectile.gd",
#      "script_properties":{"speed":420.0,"lifetime":1.2}}]}'
class_name Projectile
extends Area2D

## Emitted when the bullet stops, whatever the reason ("hit", "lifetime", "wall").
signal finished(reason: String)
signal hit_taken(hurtbox: Node)

@export var speed: float = 420.0
## Seconds before the bullet gives up. 0 disables the timer.
@export var lifetime: float = 1.2
## A hit through the child hitbox retires the bullet unless this is true.
@export var pierce: bool = false
## Retire on touching anything the root Area2D's mask sees (a wall, a body).
@export var stop_on_body: bool = true
## The hitbox to rearm and listen to. Empty = this bullet deals no damage.
@export var hitbox_path: NodePath = ^"Hitbox"
## Turn the sprite to face the travel direction.
@export var face_direction: bool = true

## Unit vector, world space. launch() sets it; set it directly for a bullet
## placed by hand.
var direction: Vector2 = Vector2.RIGHT

var _life_left: float = 0.0
var _pool: Node = null
var _hitbox: Node = null
var _spent: bool = false


func _ready() -> void:
	monitoring = true
	# A bullet placed in a scene by hand is never launch()ed, so give it its
	# full lifetime here or it retires on its very first physics frame.
	_life_left = lifetime
	add_to_group(&"projectile")
	body_entered.connect(_on_body_entered)
	_hitbox = get_node_or_null(hitbox_path)
	if _hitbox != null and _hitbox.has_signal(&"hit"):
		_hitbox.connect(&"hit", _on_hitbox_hit)


## Point it, place it, start it. `pool` is an object_pool.gd node (or anything
## with a release() method); pass null for a bullet that frees itself instead.
func launch(from: Vector2, travel_direction: Vector2, pool: Node = null) -> void:
	global_position = from
	direction = travel_direction.normalized() if travel_direction.length_squared() > 0.0 else Vector2.RIGHT
	if face_direction:
		rotation = direction.angle()
	_pool = pool
	_life_left = lifetime
	_spent = false
	monitoring = true
	visible = true
	# A pooled bullet keeps the hitbox it spent on its previous flight.
	if _hitbox != null and _hitbox.has_method(&"rearm"):
		_hitbox.call(&"rearm")
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if _spent:
		return
	global_position += direction * speed * delta
	if lifetime > 0.0:
		_life_left -= delta
		if _life_left <= 0.0:
			retire("lifetime")


## Stop and hand the node back. Safe to call twice.
func retire(reason: String) -> void:
	if _spent:
		return
	_spent = true
	set_physics_process(false)
	# retire() is normally called from an area/body signal, which the engine runs
	# inside the physics callback. Flipping `monitoring` there is refused with
	# `Function blocked during in/out signal`, and the pool reparenting the node
	# is refused with `Removing a CollisionObject node during a physics callback
	# is not allowed` — so both are deferred to the end of the frame.
	set_deferred(&"monitoring", false)
	finished.emit(reason)
	if _pool != null and is_instance_valid(_pool) and _pool.has_method(&"release"):
		_pool.call_deferred(&"release", self)
		return
	queue_free()


func _on_body_entered(_body: Node2D) -> void:
	if stop_on_body:
		retire("wall")


func _on_hitbox_hit(hurtbox: Node) -> void:
	hit_taken.emit(hurtbox)
	if not pierce:
		retire("hit")
