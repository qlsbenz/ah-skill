# input_remap.gd — "press a key to rebind" for a list of actions. It writes the
# new event into the live InputMap and hands it to the `Settings` autoload, so
# the binding is back after a restart.
#
# Expected scene tree (node name : type):
#   InputRemap : Control              <- attach this script here
#     Frame : MarginContainer         layout_preset FULL_RECT
#       Column : VBoxContainer
#         Title : Label
#         StatusLabel : Label         unique_name_in_owner = true  (%StatusLabel)
#         ActionList : VBoxContainer  unique_name_in_owner = true  (%ActionList)
#         Actions : HBoxContainer
#           ResetButton : Button      unique_name_in_owner = true  (%ResetButton)
#           BackButton : Button       unique_name_in_owner = true  (%BackButton)
#   One row per action is built under ActionList at runtime:
#     Row_<action> : HBoxContainer
#       Name_<action> : Label     Bind_<action> : Button
#   The four %-nodes MUST have unique_name_in_owner set, or `%Name` is null.
#
# Autoload: needs `Settings` registered (it owns settings.cfg).
#
# Input actions: the ones listed in `actions` must already exist —
#   project_batch '{"actions":[{"type":"add_input_action","action_name":"jump","replace":true},
#     {"type":"add_input_event","action_name":"jump",
#      "event":{"__resource_type":"InputEventKey","properties":{"physical_keycode":32}}}]}'
#   ui_cancel (built in) aborts a capture.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/input_remap.tscn","actions":[
#     {"type":"configure_node","node_path":"root/Frame/Column/ActionList","unique_name_in_owner":true},
#     {"type":"attach_script","node_path":"root","script_path":"scripts/input_remap.gd",
#      "script_properties":{"actions":["move_left","move_right","jump","interact"]}}]}'
extends Control

signal binding_changed(action: String, event_text: String)
signal closed

## The actions to list, in order. Every one must exist in the InputMap.
@export var actions: Array[String] = ["move_left", "move_right", "jump", "interact"]
## true: the new key is taken away from whichever listed action had it.
## false: the rebind is refused and the status line names the owner.
@export var steal_on_conflict: bool = true
@export var prompt_text: String = "Press a key or a gamepad button..."
## Shown when nothing is being captured. Never leave it empty: an empty Label
## is invisible in a ui_report and in a dump_tree.
@export var idle_text: String = "Pick a row, then press the key you want."
## Focus the first row on open, so a gamepad can reach the list at all.
@export var focus_first: bool = true

@onready var _status_label: Label = %StatusLabel
@onready var _action_list: VBoxContainer = %ActionList
@onready var _reset_button: Button = %ResetButton
@onready var _back_button: Button = %BackButton

## Empty when nothing is being captured; otherwise the action being rebound.
var _capturing: String = ""


func _ready() -> void:
	_reset_button.pressed.connect(_on_reset_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	rebuild()


## Rebuilds one row per action from the live InputMap.
func rebuild() -> void:
	for child in _action_list.get_children():
		_action_list.remove_child(child)
		child.queue_free()

	for action in actions:
		if not InputMap.has_action(action):
			push_warning("input_remap: no action '%s' in the InputMap — row skipped." % action)
			continue
		var row := HBoxContainer.new()
		row.name = "Row_%s" % action
		var label := Label.new()
		label.name = "Name_%s" % action
		label.text = action
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var button := Button.new()
		button.name = "Bind_%s" % action
		button.text = binding_text(action)
		button.focus_mode = Control.FOCUS_ALL
		button.custom_minimum_size = Vector2(220, 0)
		button.pressed.connect(_on_bind_pressed.bind(action))
		row.add_child(button)
		_action_list.add_child(row)

	_status_label.text = idle_text if _capturing.is_empty() else prompt_text
	if focus_first and _action_list.get_child_count() > 0:
		var first: Button = _button_for(actions[0])
		if first != null:
			first.grab_focus()


## The first event bound to `action`, as readable text ("Space (Physical)").
## "unbound" when the action has no event at all — never an empty label, so a
## missing binding is visible in a ui_report instead of being a blank cell.
func binding_text(action: String) -> String:
	var events: Array[InputEvent] = InputMap.action_get_events(action)
	for event in events:
		if event is InputEventKey or event is InputEventJoypadButton or event is InputEventMouseButton:
			return event.as_text()
	return "unbound"


## Starts listening for the next key / button. ui_cancel aborts.
func begin_capture(action: String) -> void:
	_capturing = action
	_status_label.text = "%s: %s" % [action, prompt_text]
	var button: Button = _button_for(action)
	if button != null:
		button.text = "..."


func cancel_capture() -> void:
	if _capturing.is_empty():
		return
	var action: String = _capturing
	_capturing = ""
	_status_label.text = "%s unchanged." % action
	var button: Button = _button_for(action)
	if button != null:
		button.text = binding_text(action)


# _input, not _unhandled_input: the focused Button would otherwise swallow
# ui_accept before the capture ever sees it.
func _input(event: InputEvent) -> void:
	if _capturing.is_empty():
		return
	if event.is_echo() or not event.is_pressed():
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		cancel_capture()
		return
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventMouseButton):
		return
	get_viewport().set_input_as_handled()
	_apply_capture(event)


func _apply_capture(event: InputEvent) -> void:
	var action: String = _capturing
	_capturing = ""

	var owner_action: String = _action_using(event, action)
	if not owner_action.is_empty() and not steal_on_conflict:
		_status_label.text = "%s is already bound to %s." % [event.as_text(), owner_action]
		var refused: Button = _button_for(action)
		if refused != null:
			refused.text = binding_text(action)
		return

	if not owner_action.is_empty():
		var unbound: Array[InputEvent] = []
		Settings.set_action_events(owner_action, unbound)
		var stolen: Button = _button_for(owner_action)
		if stolen != null:
			stolen.text = binding_text(owner_action)

	var events: Array[InputEvent] = [event]
	Settings.set_action_events(action, events)
	Settings.save()

	var button: Button = _button_for(action)
	if button != null:
		button.text = binding_text(action)
	if owner_action.is_empty():
		_status_label.text = "%s -> %s" % [action, binding_text(action)]
	else:
		_status_label.text = "%s -> %s (taken from %s)" % [action, binding_text(action), owner_action]
	binding_changed.emit(action, binding_text(action))


## Which *listed* action already uses this event, "" when none does.
func _action_using(event: InputEvent, except_action: String) -> String:
	for action in actions:
		if action == except_action or not InputMap.has_action(action):
			continue
		if InputMap.action_has_event(action, event):
			return action
	return ""


func _button_for(action: String) -> Button:
	return _action_list.get_node_or_null("Row_%s/Bind_%s" % [action, action]) as Button


func _on_bind_pressed(action: String) -> void:
	begin_capture(action)


func _on_reset_pressed() -> void:
	cancel_capture()
	Settings.reset_to_defaults()
	rebuild()
	_status_label.text = "Bindings reset to the project defaults."


func _on_back_pressed() -> void:
	cancel_capture()
	Settings.save()
	closed.emit()
