# test_health_signals.gd — sample: asserting that a component emits the right
# signals, with the right arguments, the right number of times.
#
# Signals are how Godot components talk to each other, and a missing or
# double-fired signal is invisible until the HUD stops updating. watch_signals()
# records every signal of an object — including signals with parameters, at any
# arity — from the moment it is called.
#
# The subject here mirrors templates/gdscript/health.gd. Replace it with:
#   const Health = preload("res://scripts/health.gd")
extends "res://tests/test_case.gd"


## Replace with a preload of your own component.
class Health extends Node:
	signal damaged(amount: int, current: int)
	signal healed(amount: int, current: int)
	signal died

	var max_health: int = 3
	var current: int = 3

	func take_damage(amount: int) -> void:
		if amount <= 0 or current <= 0:
			return
		current = maxi(current - amount, 0)
		damaged.emit(amount, current)
		if current == 0:
			died.emit()

	func heal(amount: int) -> void:
		if amount <= 0 or current <= 0:
			return
		var before := current
		current = mini(current + amount, max_health)
		if current != before:
			healed.emit(current - before, current)


var health: Health


func before_each() -> void:
	health = Health.new()
	add_child_autofree(health)
	# Watch BEFORE the code that emits — a recorder cannot record the past.
	watch_signals(health)


func test_damage_emits_damaged_with_amount_and_remainder() -> void:
	health.take_damage(1)
	assert_signal_emitted(health, "damaged")
	assert_signal_emit_count(health, "damaged", 1)
	# Two-argument signal: both arguments are recorded, in order.
	assert_eq(get_signal_args(health, "damaged"), [1, 2])


func test_lethal_damage_emits_died_exactly_once() -> void:
	health.take_damage(3)
	assert_signal_emitted(health, "died")
	assert_signal_emit_count(health, "died", 1)
	# And hitting a corpse again must stay quiet.
	health.take_damage(1)
	assert_signal_emit_count(health, "damaged", 1, "damage after death must be ignored")
	assert_signal_emit_count(health, "died", 1)


func test_healing_to_full_clamps_and_reports_the_delta() -> void:
	health.take_damage(2)
	health.heal(5)
	assert_eq(health.current, health.max_health)
	assert_signal_emitted_with(health, "healed", [2, 3], "only the 2 points that were actually restored")


func test_a_no_op_heal_emits_nothing() -> void:
	health.heal(1)
	assert_signal_not_emitted(health, "healed", "already at full health")
	assert_eq(get_signal_emit_count(health, "healed"), 0)


## Signals fired from a deferred call or a later frame are recorded too — await
## the frame first, then assert.
func test_a_deferred_emission_is_recorded_after_a_frame() -> void:
	health.take_damage.call_deferred(1)
	assert_signal_not_emitted(health, "damaged", "not emitted yet, the call is deferred")
	await wait_frames(1)
	assert_signal_emitted(health, "damaged")
