# test_case.gd — base class for the bundled zero-install unit-test framework.
#
# Copy this file to res://tests/test_case.gd (the runner's --init-mini does it
# for you) and write a suite as:
#
#   extends "res://tests/test_case.gd"
#
#   func test_two_plus_two() -> void:
#       assert_eq(2 + 2, 4)
#
# Then run it:
#   python3 /absolute/path/to/godot/scripts/test/run_tests.py /absolute/project --pretty
#
# Deliberately path-extends and declares NO class_name: nothing has to be in
# .godot/global_script_class_cache.cfg, so no `--import` pass is needed and the
# file can never collide with a class_name the project already uses.
#
# Nothing here needs an addon, a download, or a network connection. It is meant
# to be read and edited: everything is plain GDScript.
#
# Notes that matter when writing tests:
# - A GDScript runtime error (null dereference, bad index, ...) aborts the test
#   function and returns *without* raising. The runner detects that from the
#   engine's SCRIPT ERROR output and reports the test as `error`, never a pass.
# - A test that makes no assertion is reported `risky`, not passed. Use
#   pending("why") for a test you have not written yet.
# - skip()/pending() only mark the result; `return` right after calling them.
# - Every assert takes an optional trailing message and returns true on success,
#   so `if not assert_not_null(node): return` is a valid early-out.
extends Node

## Objects freed after the current test finishes (add_child_autofree/autofree/add_scene).
var _mini_autofree: Array = []
## Objects created in before_all: freed once, after after_all.
var _mini_script_autofree: Array = []
## Input actions pressed with press_action(), released after the current test.
var _mini_pressed_actions: Array[StringName] = []
## Key codes sent with send_key(..., true), released after the current test.
var _mini_pressed_keys: Array[int] = []
## "<instance_id>::<signal>" -> Array of emitted argument arrays.
var _mini_signal_log: Dictionary = {}
## instance_id -> true for every object passed to watch_signals().
var _mini_watched: Dictionary = {}

var _mini_asserts: int = 0
var _mini_failures: Array[Dictionary] = []
var _mini_skipped: bool = false
var _mini_skip_reason: String = ""
var _mini_pending: bool = false
var _mini_pending_reason: String = ""
var _mini_allow_errors: bool = false

# Deepest signal arity the vararg recorder can capture. Signals with more
# parameters than this are still counted; only their arguments are truncated.
const MINI_MAX_SIGNAL_ARGS := 8


# --- assertions ------------------------------------------------------------
# Every public assert records exactly one assertion and, on failure, calls
# _mini_fail() directly, so the reported line is always the caller's line.

func assert_true(value: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	if value is bool and value:
		return true
	if not (value is bool):
		return _mini_fail("assert_true: expected true (bool) but got %s" % _mini_describe(value), message)
	return _mini_fail("assert_true: expected true but got false", message)


func assert_false(value: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	if value is bool and not value:
		return true
	if not (value is bool):
		return _mini_fail("assert_false: expected false (bool) but got %s" % _mini_describe(value), message)
	return _mini_fail("assert_false: expected false but got true", message)


## assert_eq(actual, expected): GUT's argument order — the value you produced first.
func assert_eq(actual: Variant, expected: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	if _mini_equals(actual, expected):
		return true
	return _mini_fail("assert_eq: expected %s but got %s" % [_mini_describe(expected), _mini_describe(actual)], message)


func assert_ne(actual: Variant, other: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	if not _mini_equals(actual, other):
		return true
	return _mini_fail("assert_ne: expected a value different from %s but got %s" % [_mini_describe(other), _mini_describe(actual)], message)


## Float-safe equality. Also compares Vector2/Vector3/Color component-wise.
func assert_almost_eq(actual: Variant, expected: Variant, tolerance: float = 0.00001, message: String = "") -> bool:
	_mini_asserts += 1
	var distance := _mini_distance(actual, expected)
	if distance < 0.0:
		return _mini_fail("assert_almost_eq: cannot compare %s with %s numerically" % [_mini_describe(actual), _mini_describe(expected)], message)
	if distance <= tolerance:
		return true
	return _mini_fail("assert_almost_eq: expected %s +/- %s but got %s (off by %s)" % [
		_mini_describe(expected), str(tolerance), _mini_describe(actual), str(distance)], message)


func assert_null(value: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	if value == null:
		return true
	return _mini_fail("assert_null: expected null but got %s" % _mini_describe(value), message)


func assert_not_null(value: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	if value != null:
		return true
	return _mini_fail("assert_not_null: expected a value but got null", message)


func assert_gt(actual: Variant, other: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	if _mini_comparable(actual, other) and actual > other:
		return true
	if not _mini_comparable(actual, other):
		return _mini_fail("assert_gt: cannot compare %s with %s" % [_mini_describe(actual), _mini_describe(other)], message)
	return _mini_fail("assert_gt: expected a value greater than %s but got %s" % [_mini_describe(other), _mini_describe(actual)], message)


func assert_lt(actual: Variant, other: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	if _mini_comparable(actual, other) and actual < other:
		return true
	if not _mini_comparable(actual, other):
		return _mini_fail("assert_lt: cannot compare %s with %s" % [_mini_describe(actual), _mini_describe(other)], message)
	return _mini_fail("assert_lt: expected a value less than %s but got %s" % [_mini_describe(other), _mini_describe(actual)], message)


## Inclusive on both ends: low <= value <= high.
func assert_between(value: Variant, low: Variant, high: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	if not (_mini_comparable(value, low) and _mini_comparable(value, high)):
		return _mini_fail("assert_between: cannot compare %s with %s..%s" % [
			_mini_describe(value), _mini_describe(low), _mini_describe(high)], message)
	if value >= low and value <= high:
		return true
	return _mini_fail("assert_between: expected %s..%s (inclusive) but got %s" % [
		_mini_describe(low), _mini_describe(high), _mini_describe(value)], message)


## Works on Array, Dictionary (keys), String/StringName (substring) and PackedArrays.
func assert_has(container: Variant, value: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	var outcome := _mini_contains(container, value)
	if outcome == 1:
		return true
	if outcome < 0:
		return _mini_fail("assert_has: %s is not a container that can be searched" % _mini_describe(container), message)
	return _mini_fail("assert_has: expected %s to contain %s" % [_mini_describe(container), _mini_describe(value)], message)


func assert_does_not_have(container: Variant, value: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	var outcome := _mini_contains(container, value)
	if outcome == 0:
		return true
	if outcome < 0:
		return _mini_fail("assert_does_not_have: %s is not a container that can be searched" % _mini_describe(container), message)
	return _mini_fail("assert_does_not_have: expected %s NOT to contain %s" % [_mini_describe(container), _mini_describe(value)], message)


func assert_string_contains(text: Variant, substring: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	if not (text is String or text is StringName):
		return _mini_fail("assert_string_contains: expected a String but got %s" % _mini_describe(text), message)
	if str(text).contains(str(substring)):
		return true
	return _mini_fail("assert_string_contains: expected %s to contain %s" % [_mini_describe(text), _mini_describe(substring)], message)


## type may be a native class (Node2D), a Script/const preload, or a class-name String.
func assert_is(object: Variant, type: Variant, message: String = "") -> bool:
	_mini_asserts += 1
	var type_label := _mini_type_label(type)
	if object == null:
		return _mini_fail("assert_is: expected a %s but got null" % type_label, message)
	if type is String or type is StringName:
		if object is Object and (object as Object).is_class(str(type)):
			return true
		return _mini_fail("assert_is: expected a %s but got %s" % [type_label, _mini_describe(object)], message)
	if is_instance_of(object, type):
		return true
	return _mini_fail("assert_is: expected a %s but got %s" % [type_label, _mini_describe(object)], message)


# --- signals ---------------------------------------------------------------

## Start recording every signal of `object`. Call it BEFORE the code that emits.
## Signals with parameters are recorded with their arguments (see get_signal_args).
func watch_signals(object: Object) -> bool:
	if object == null or not is_instance_valid(object):
		return _mini_fail("watch_signals: object is null or already freed", "")
	if _mini_watched.has(object.get_instance_id()):
		return true
	_mini_watched[object.get_instance_id()] = true
	for entry in object.get_signal_list():
		var signal_name := str(entry["name"])
		var arity: int = mini((entry["args"] as Array).size(), MINI_MAX_SIGNAL_ARGS)
		var key := _mini_signal_key(object, signal_name)
		_mini_signal_log[key] = []
		# One recorder lambda per signal, capturing that signal's key and arity
		# by value. Every parameter is optional, which is what makes a single
		# lambda shape connectable to a signal of ANY arity (verified for 0..8
		# on 4.7): Godot only rejects a callable that needs *more* arguments
		# than the signal supplies, never one that needs fewer.
		var recorder := func(a0 = null, a1 = null, a2 = null, a3 = null, a4 = null, a5 = null, a6 = null, a7 = null) -> void:
			var all: Array = [a0, a1, a2, a3, a4, a5, a6, a7]
			(_mini_signal_log[key] as Array).append(all.slice(0, arity))
		var error: int = (object.get(signal_name) as Signal).connect(recorder)
		if error != OK:
			return _mini_fail("watch_signals: could not connect to signal '%s' of %s (error %d)" % [
				signal_name, _mini_describe(object), error], "")
	return true


func assert_signal_emitted(object: Object, signal_name: String, message: String = "") -> bool:
	_mini_asserts += 1
	var problem := _mini_signal_problem(object, signal_name)
	if not problem.is_empty():
		return _mini_fail("assert_signal_emitted: " + problem, message)
	var emissions: Array = _mini_signal_log[_mini_signal_key(object, signal_name)]
	if not emissions.is_empty():
		return true
	return _mini_fail("assert_signal_emitted: '%s' was never emitted by %s" % [signal_name, _mini_describe(object)], message)


func assert_signal_not_emitted(object: Object, signal_name: String, message: String = "") -> bool:
	_mini_asserts += 1
	var problem := _mini_signal_problem(object, signal_name)
	if not problem.is_empty():
		return _mini_fail("assert_signal_not_emitted: " + problem, message)
	var emissions: Array = _mini_signal_log[_mini_signal_key(object, signal_name)]
	if emissions.is_empty():
		return true
	return _mini_fail("assert_signal_not_emitted: '%s' was emitted %d time(s) by %s, arguments: %s" % [
		signal_name, emissions.size(), _mini_describe(object), str(emissions)], message)


func assert_signal_emit_count(object: Object, signal_name: String, count: int, message: String = "") -> bool:
	_mini_asserts += 1
	var problem := _mini_signal_problem(object, signal_name)
	if not problem.is_empty():
		return _mini_fail("assert_signal_emit_count: " + problem, message)
	var emissions: Array = _mini_signal_log[_mini_signal_key(object, signal_name)]
	if emissions.size() == count:
		return true
	return _mini_fail("assert_signal_emit_count: expected '%s' to be emitted %d time(s) but it was emitted %d time(s) by %s" % [
		signal_name, count, emissions.size(), _mini_describe(object)], message)


## Assert that at least one emission carried exactly these arguments.
func assert_signal_emitted_with(object: Object, signal_name: String, expected_args: Array, message: String = "") -> bool:
	_mini_asserts += 1
	var problem := _mini_signal_problem(object, signal_name)
	if not problem.is_empty():
		return _mini_fail("assert_signal_emitted_with: " + problem, message)
	var emissions: Array = _mini_signal_log[_mini_signal_key(object, signal_name)]
	for emission in emissions:
		if _mini_equals(emission, expected_args):
			return true
	return _mini_fail("assert_signal_emitted_with: no emission of '%s' carried %s (recorded: %s)" % [
		signal_name, str(expected_args), str(emissions)], message)


## Arguments of one emission (index -1 = the most recent). [] when there is none.
func get_signal_args(object: Object, signal_name: String, index: int = -1) -> Array:
	if not _mini_signal_problem(object, signal_name).is_empty():
		return []
	var emissions: Array = _mini_signal_log[_mini_signal_key(object, signal_name)]
	if emissions.is_empty():
		return []
	var resolved := index if index >= 0 else emissions.size() + index
	if resolved < 0 or resolved >= emissions.size():
		return []
	return emissions[resolved]


func get_signal_emit_count(object: Object, signal_name: String) -> int:
	if not _mini_signal_problem(object, signal_name).is_empty():
		return 0
	return (_mini_signal_log[_mini_signal_key(object, signal_name)] as Array).size()


# --- outcomes --------------------------------------------------------------

## Fail the test outright (counts as one assertion).
func fail(message: String) -> bool:
	_mini_asserts += 1
	return _mini_fail(message, "")


## Mark the test skipped (environment missing, platform-specific, ...).
## Marking does not stop execution — `return` right after calling this.
func skip(message: String = "") -> void:
	_mini_skipped = true
	_mini_skip_reason = message


## Mark the test as not-written-yet. Same rule: `return` right after.
func pending(message: String = "") -> void:
	_mini_pending = true
	_mini_pending_reason = message


## Tell the runner that engine errors printed during this test are expected
## (the code under test calls push_error, or you are testing an error path).
## Without this, any ERROR/SCRIPT ERROR line inside a test marks it `error`.
func allow_errors() -> void:
	_mini_allow_errors = true


# --- waiting ---------------------------------------------------------------

func wait_frames(count: int = 1) -> void:
	for _i in range(maxi(count, 1)):
		await get_tree().process_frame


func wait_physics_frames(count: int = 1) -> void:
	for _i in range(maxi(count, 1)):
		await get_tree().physics_frame


func wait_seconds(seconds: float) -> void:
	await get_tree().create_timer(maxf(seconds, 0.0)).timeout


## Poll `condition` every frame until it returns true. Returns whether it did.
func wait_until(condition: Callable, timeout_seconds: float = 2.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(maxf(timeout_seconds, 0.0) * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var outcome: Variant = condition.call()
		if outcome is bool and outcome:
			return true
		await get_tree().process_frame
	var last: Variant = condition.call()
	return last is bool and last


# --- scene / node helpers --------------------------------------------------

## Add a node under this test (which lives in the tree) and free it afterwards.
func add_child_autofree(node: Node) -> Node:
	if node == null:
		_mini_fail("add_child_autofree: node is null", "")
		return null
	add_child(node)
	_mini_autofree.append(node)
	return node


## Instantiate a scene, add it to the tree, and free it after the test.
func add_scene(scene_path: String) -> Node:
	var normalized := scene_path if scene_path.begins_with("res://") else "res://" + scene_path.trim_prefix("/")
	if not ResourceLoader.exists(normalized):
		_mini_fail("add_scene: no such scene: %s" % normalized, "")
		return null
	var packed: Variant = load(normalized)
	if not (packed is PackedScene):
		_mini_fail("add_scene: %s is not a PackedScene" % normalized, "")
		return null
	var instance: Node = (packed as PackedScene).instantiate()
	if instance == null:
		_mini_fail("add_scene: %s failed to instantiate (invalid node hierarchy?)" % normalized, "")
		return null
	return add_child_autofree(instance)


## Free any Object (Node, RefCounted, custom Resource) after the test.
func autofree(object: Object) -> Object:
	if object != null:
		_mini_autofree.append(object)
	return object


# --- input -----------------------------------------------------------------

## Press an InputMap action for real: polled state (Input.is_action_pressed)
## AND the _input/_unhandled_input callbacks, both effective immediately.
## Released automatically after the test if you never call release_action.
func press_action(action: StringName) -> bool:
	if not InputMap.has_action(action):
		return _mini_fail("press_action: no InputMap action named '%s' (defined: %s)" % [
			str(action), str(InputMap.get_actions())], "")
	_mini_send_action(action, true)
	if not _mini_pressed_actions.has(action):
		_mini_pressed_actions.append(action)
	return true


func release_action(action: StringName) -> bool:
	if not InputMap.has_action(action):
		return _mini_fail("release_action: no InputMap action named '%s' (defined: %s)" % [
			str(action), str(InputMap.get_actions())], "")
	_mini_send_action(action, false)
	_mini_pressed_actions.erase(action)
	return true


## Send a real key event (Key enum, e.g. KEY_SPACE) through Input.parse_input_event.
func send_key(keycode: int, pressed: bool = true) -> void:
	var event := InputEventKey.new()
	# `as Key`: assigning a plain int to a typed enum property is a warning.
	event.keycode = keycode as Key
	event.physical_keycode = keycode as Key
	event.pressed = pressed
	Input.parse_input_event(event)
	# Godot buffers parsed events (Input.is_using_accumulated_input() is true by
	# default) and only applies them at the start of the next frame, so without
	# this flush the very next assert still sees the old state.
	Input.flush_buffered_events()
	if pressed:
		if not _mini_pressed_keys.has(keycode):
			_mini_pressed_keys.append(keycode)
	else:
		_mini_pressed_keys.erase(keycode)


func _mini_send_action(action: StringName, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


# --- runner protocol (called by scripts/test/mini_test_runner.gd) ----------

func _mini_reset() -> void:
	_mini_asserts = 0
	_mini_failures = []
	_mini_skipped = false
	_mini_skip_reason = ""
	_mini_pending = false
	_mini_pending_reason = ""
	_mini_allow_errors = false
	_mini_signal_log = {}
	_mini_watched = {}


func _mini_report() -> Dictionary:
	return {
		"asserts": _mini_asserts,
		"failures": _mini_failures,
		"skipped": _mini_skipped,
		"skip_reason": _mini_skip_reason,
		"pending": _mini_pending,
		"pending_reason": _mini_pending_reason,
		"allow_errors": _mini_allow_errors,
	}


## Called by the runner after before_all: whatever that hook created belongs to
## the whole script, not to the first test that happens to run next.
func _mini_scope_to_script() -> void:
	_mini_script_autofree.append_array(_mini_autofree)
	_mini_autofree.clear()


## Called by the runner after after_all.
func _mini_cleanup_script() -> void:
	_mini_autofree.append_array(_mini_script_autofree)
	_mini_script_autofree.clear()
	await _mini_cleanup()


## Release input and free everything the test created. Awaits one frame so a
## queue_free() inside a physics callback has actually happened before the
## runner samples the orphan count.
func _mini_cleanup() -> void:
	for action in _mini_pressed_actions.duplicate():
		_mini_send_action(action, false)
	_mini_pressed_actions.clear()
	for keycode in _mini_pressed_keys.duplicate():
		send_key(keycode, false)
	_mini_pressed_keys.clear()
	for object in _mini_autofree:
		if object == null or not is_instance_valid(object):
			continue
		if object is Node:
			(object as Node).queue_free()
		elif not (object is RefCounted):
			object.free()
	_mini_autofree.clear()
	if is_inside_tree():
		await get_tree().process_frame


# --- internals -------------------------------------------------------------

func _mini_fail(reason: String, message: String) -> bool:
	var text := reason if message.is_empty() else "%s — %s" % [message, reason]
	# get_stack() frames are most-recent-first: [0] is this function, [1] is the
	# assert helper the test called, [2] is the test's own line. It is populated
	# only when the debugger is attached (-d), which run_tests.py always passes;
	# without it the failure is still reported, just without a line number.
	var source := ""
	var line := 0
	var stack: Array = get_stack()
	if stack.size() > 2:
		var frame: Dictionary = stack[2]
		source = str(frame["source"])
		line = int(frame["line"])
	_mini_failures.append({"message": text, "source": source, "line": line})
	return false


func _mini_signal_key(object: Object, signal_name: String) -> String:
	return "%d::%s" % [object.get_instance_id(), signal_name]


## "" when the object/signal pair can be asserted on, otherwise the reason why
## not — never let a forgotten watch_signals() read as "the signal never fired".
func _mini_signal_problem(object: Object, signal_name: String) -> String:
	if object == null or not is_instance_valid(object):
		return "object is null or already freed"
	if not _mini_watched.has(object.get_instance_id()):
		return "%s is not being watched — call watch_signals(object) before the code that emits" % _mini_describe(object)
	if not object.has_signal(signal_name):
		var names: Array[String] = []
		for entry in object.get_signal_list():
			names.append(str(entry["name"]))
		return "%s has no signal named '%s' (it has: %s)" % [_mini_describe(object), signal_name, ", ".join(names)]
	if not _mini_signal_log.has(_mini_signal_key(object, signal_name)):
		return "signal '%s' was not recorded — call watch_signals(object) again after it was added" % signal_name
	return ""


func _mini_describe(value: Variant) -> String:
	if value == null:
		return "<null>"
	if value is String or value is StringName:
		return '"%s" (%s)' % [str(value), type_string(typeof(value))]
	if value is Object:
		var object := value as Object
		if not is_instance_valid(object):
			return "<freed object>"
		var label := object.get_class()
		if object is Node:
			label += " '%s'" % (object as Node).name
		var script_reference: Variant = object.get_script()
		if script_reference is Script and not (script_reference as Script).resource_path.is_empty():
			label += " <" + (script_reference as Script).resource_path.get_file() + ">"
		return "%s (%s)" % [str(object), label]
	return "%s (%s)" % [str(value), type_string(typeof(value))]


func _mini_equals(left: Variant, right: Variant) -> bool:
	# `"3" == 3` is not false in GDScript, it is the *runtime error* "Invalid
	# operands 'String' and 'int' in operator '=='", which would abort the
	# assertion. Compare the types first; int/float stay interchangeable.
	if typeof(left) != typeof(right):
		if (left is int or left is float) and (right is int or right is float):
			return float(left) == float(right)
		return false
	# Godot 4 compares Array and Dictionary by value, so == is already deep.
	return left == right


func _mini_comparable(left: Variant, right: Variant) -> bool:
	var numeric := [TYPE_INT, TYPE_FLOAT]
	if numeric.has(typeof(left)) and numeric.has(typeof(right)):
		return true
	return typeof(left) == typeof(right) and (left is String or left is StringName or left is Vector2 or left is Vector3)


## Distance between two numeric-ish values, or -1.0 when they cannot be compared.
func _mini_distance(left: Variant, right: Variant) -> float:
	if (left is int or left is float) and (right is int or right is float):
		return absf(float(left) - float(right))
	if left is Vector2 and right is Vector2:
		return (left as Vector2).distance_to(right as Vector2)
	if left is Vector3 and right is Vector3:
		return (left as Vector3).distance_to(right as Vector3)
	if left is Color and right is Color:
		var a := left as Color
		var b := right as Color
		return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), maxf(absf(a.b - b.b), absf(a.a - b.a)))
	return -1.0


## 1 = contains, 0 = does not contain, -1 = not a searchable container.
func _mini_contains(container: Variant, value: Variant) -> int:
	if container is String or container is StringName:
		return 1 if str(container).contains(str(value)) else 0
	if container is Dictionary:
		return 1 if (container as Dictionary).has(value) else 0
	if container is Array:
		return 1 if (container as Array).has(value) else 0
	if container is PackedStringArray or container is PackedInt32Array or container is PackedInt64Array \
			or container is PackedFloat32Array or container is PackedFloat64Array \
			or container is PackedVector2Array or container is PackedVector3Array or container is PackedColorArray:
		return 1 if container.has(value) else 0
	return -1


func _mini_type_label(type: Variant) -> String:
	if type is String or type is StringName:
		return str(type)
	if type is Script:
		var script := type as Script
		var global_name := str(script.get_global_name())
		if not global_name.is_empty():
			return global_name
		return script.resource_path.get_file()
	return str(type)
