# test_example.gd — the file `run_tests.py --init-mini` drops next to
# test_case.gd. It is self-contained (it passes on an empty project) and exists
# to be edited: delete the inner Counter class, preload your own script instead,
# and rewrite the tests around it.
#
#   const Inventory = preload("res://scripts/inventory.gd")
#
#   func test_adding_an_item_raises_the_count() -> void:
#       var inventory := Inventory.new()
#       inventory.add("potion", 2)
#       assert_eq(inventory.count("potion"), 2)
#
# Run it:
#   python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/project --pretty
extends "res://tests/test_case.gd"


## Stand-in for the script under test. Replace it with a preload of your own.
class Counter extends RefCounted:
	signal changed(value: int)

	var value: int = 0

	func add(amount: int) -> void:
		value += amount
		changed.emit(value)

	func reset() -> void:
		value = 0
		changed.emit(value)


var counter: Counter


## Runs before every test_* method: build fresh state so tests cannot leak into
## each other. before_all / after_each / after_all exist too.
func before_each() -> void:
	counter = Counter.new()


func test_a_new_counter_starts_at_zero() -> void:
	assert_eq(counter.value, 0)


func test_add_accumulates() -> void:
	counter.add(3)
	counter.add(4)
	assert_eq(counter.value, 7, "3 + 4 should accumulate into value")


## watch_signals() must be called before the code that emits. Signals with
## arguments are recorded with their arguments.
func test_add_emits_changed_with_the_new_value() -> void:
	watch_signals(counter)
	counter.add(5)
	assert_signal_emitted(counter, "changed")
	assert_signal_emit_count(counter, "changed", 1)
	assert_eq(get_signal_args(counter, "changed"), [5])


## Tests may be coroutines: `await` anything, the runner waits (up to
## --test-timeout seconds) and then moves on to the next test.
func test_a_deferred_call_lands_next_frame() -> void:
	counter.add.call_deferred(2)
	assert_eq(counter.value, 0, "call_deferred has not run yet")
	await wait_frames(1)
	assert_eq(counter.value, 2, "call_deferred has run by the next frame")
