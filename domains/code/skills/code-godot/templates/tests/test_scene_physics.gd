# test_scene_physics.gd — sample: testing a node in a live tree, with real
# physics frames and real input.
#
# This is the test that catches "the player falls through the floor": it puts a
# CharacterBody2D above a StaticBody2D, steps the physics clock, and asserts
# is_on_floor(). Headless Godot runs physics normally, so it needs no window
# and no screenshot.
#
# The nodes are built in code so the sample runs on any project. In a real suite
# you would instead instantiate the scene you actually ship:
#
#   var player := add_scene("res://scenes/player.tscn")
#   await wait_physics_frames(30)
#   assert_true(player.is_on_floor())
#
# add_scene() / add_child_autofree() put the node under this test node (which is
# in the tree) and free it again after the test, so nothing leaks into the next.
extends "res://tests/test_case.gd"

const FLOOR_Y := 200.0
const STEP := 1.0 / 60.0


func _make_floor() -> StaticBody2D:
	var body := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(400, 20)
	shape.shape = rectangle
	body.add_child(shape)
	body.position = Vector2(0, FLOOR_Y)
	return body


func _make_actor() -> CharacterBody2D:
	var body := CharacterBody2D.new()
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(16, 32)
	shape.shape = rectangle
	body.add_child(shape)
	return body


## One physics step of "gravity + move_and_slide", the way a player script does
## it inside _physics_process. Driving it from the test keeps the sample free of
## an extra script file.
func _step(body: CharacterBody2D, gravity: float) -> void:
	body.velocity.y += gravity * STEP
	body.move_and_slide()
	await wait_physics_frames(1)


func test_a_body_falls_and_lands_on_static_collision() -> void:
	add_child_autofree(_make_floor())
	var actor := _make_actor() as CharacterBody2D
	actor.position = Vector2(0, 0)
	add_child_autofree(actor)
	var gravity := float(ProjectSettings.get_setting("physics/2d/default_gravity", 980.0))

	var steps := 0
	while steps < 120 and not actor.is_on_floor():
		await _step(actor, gravity)
		steps += 1

	assert_true(actor.is_on_floor(), "the body never reached the floor after %d physics frames" % steps)
	assert_between(actor.position.y, FLOOR_Y - 40.0, FLOOR_Y, "it should rest on top of the floor, not inside it")


## The failure this catches: a shape-less body. Godot reports nothing at all —
## the body simply passes through everything.
func test_a_body_without_a_shape_falls_through_the_floor() -> void:
	add_child_autofree(_make_floor())
	var ghost := CharacterBody2D.new()  # deliberately no CollisionShape2D child
	ghost.position = Vector2(0, 0)
	add_child_autofree(ghost)
	var gravity := float(ProjectSettings.get_setting("physics/2d/default_gravity", 980.0))

	for _step_index in range(40):
		await _step(ghost, gravity)

	assert_false(ghost.is_on_floor(), "a body with no CollisionShape2D cannot collide")
	assert_gt(ghost.position.y, FLOOR_Y, "it fell straight through — this is what check_project's body_without_shape warns about")


## Real input: press_action() feeds the InputMap action through
## Input.parse_input_event, so polled checks (Input.is_action_pressed) AND
## _input()/_unhandled_input() callbacks both see it. The runner releases
## anything still held when the test ends.
func test_pressing_an_action_is_visible_to_polled_code() -> void:
	if not InputMap.has_action(&"ui_accept"):
		skip("project has no ui_accept action")
		return
	assert_false(Input.is_action_pressed(&"ui_accept"), "nothing is held at the start of a test")
	press_action(&"ui_accept")
	assert_true(Input.is_action_pressed(&"ui_accept"))
	release_action(&"ui_accept")
	assert_false(Input.is_action_pressed(&"ui_accept"))
