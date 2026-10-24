# test_inventory_logic.gd — sample: testing pure game logic (no nodes, no
# frames, no scene). This is the cheapest and most valuable kind of Godot test:
# it runs in microseconds and catches the arithmetic bugs that are invisible in
# a screenshot.
#
# Copy it to res://tests/, delete the inner Inventory class, and point the
# preload at your own script:
#
#   const Inventory = preload("res://scripts/inventory.gd")
#
# Run:  python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/project --pretty
extends "res://tests/test_case.gd"


## The subject under test. Replace with a preload of your real script.
class Inventory extends RefCounted:
	const DEFAULT_STACK_SIZE := 10

	var slots: Dictionary = {}

	func add(item: StringName, amount: int = 1) -> int:
		"""Adds up to the stack limit. Returns the amount that did NOT fit."""
		if amount <= 0:
			return 0
		var current: int = slots.get(item, 0)
		var space := DEFAULT_STACK_SIZE - current
		var stored: int = mini(space, amount)
		if stored > 0:
			slots[item] = current + stored
		return amount - stored

	func remove(item: StringName, amount: int = 1) -> bool:
		var current: int = slots.get(item, 0)
		if current < amount:
			return false
		if current == amount:
			slots.erase(item)
		else:
			slots[item] = current - amount
		return true

	func count(item: StringName) -> int:
		return slots.get(item, 0)

	func is_empty() -> bool:
		return slots.is_empty()


var inventory: Inventory


func before_each() -> void:
	inventory = Inventory.new()


func test_a_new_inventory_is_empty() -> void:
	assert_true(inventory.is_empty())
	assert_eq(inventory.count(&"potion"), 0)


func test_adding_accumulates_into_one_stack() -> void:
	assert_eq(inventory.add(&"potion", 3), 0, "everything fits")
	assert_eq(inventory.add(&"potion", 4), 0)
	assert_eq(inventory.count(&"potion"), 7)


## The interesting case: the boundary. A weak model writes the happy path and
## ships the off-by-one; this is where the test earns its keep.
func test_overflow_is_reported_not_silently_dropped() -> void:
	var left_over := inventory.add(&"potion", 14)
	assert_eq(left_over, 4, "10 fit in the stack, 4 are left over")
	assert_eq(inventory.count(&"potion"), Inventory.DEFAULT_STACK_SIZE)


func test_removing_more_than_you_have_fails_and_changes_nothing() -> void:
	inventory.add(&"potion", 2)
	assert_false(inventory.remove(&"potion", 3))
	assert_eq(inventory.count(&"potion"), 2, "a rejected removal must not consume anything")


func test_removing_the_last_one_clears_the_slot() -> void:
	inventory.add(&"potion", 1)
	assert_true(inventory.remove(&"potion", 1))
	assert_true(inventory.is_empty())
	assert_does_not_have(inventory.slots, &"potion")


func test_zero_and_negative_amounts_are_ignored() -> void:
	assert_eq(inventory.add(&"potion", 0), 0)
	assert_eq(inventory.add(&"potion", -5), 0)
	assert_true(inventory.is_empty(), "a negative add must not create a slot")
