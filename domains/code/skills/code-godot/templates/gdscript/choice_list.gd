# choice_list.gd — the buttons under a dialogue line. It is the other half of
# dialogue_runner.gd: feed it the `choices_shown` payload, and it emits
# `choice_selected(index)` with the index that `runner.choose()` expects.
#
# It lives *inside* the dialog box from playbook 9 rather than replacing it:
# dialog_box.gd still types the line, this node draws the answers.
#
# Verified on 4.7: a focused Button does NOT consume the `ui_accept` key press.
# The press reaches `_unhandled_input`, so dialog_box.gd would advance the line
# *behind* the choices and hide the box mid-question. This script therefore
# takes `ui_accept` in `_input` (which runs before both) and activates the
# focused choice itself.
#
# Expected scene tree (node name : type) — playbook 16 builds exactly this:
#   DialogueBox : CanvasLayer         (dialog_box.gd, layer 5)
#     DialogRoot : Control
#       Anchor : MarginContainer
#         Box : PanelContainer
#           Body : VBoxContainer
#             SpeakerLabel : Label
#             BodyLabel : RichTextLabel
#             Choices : VBoxContainer   <- attach this script here
#                                          unique_name_in_owner = true (%Choices)
#   The buttons are created at runtime, one per visible choice.
#
# Autoload: no. Declares `class_name ChoiceList`; run
#   godot --headless --path /absolute/path/to/project --import
# after copying it, before any script that annotates a variable as `ChoiceList`.
#
# Input actions: none. ui_accept / ui_down / ui_up are the built-in focus set.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/talk.tscn","actions":[
#     {"type":"add_node","parent_node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body",
#      "node_type":"VBoxContainer","node_name":"Choices"},
#     {"type":"configure_node","node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body/Choices","unique_name_in_owner":true},
#     {"type":"attach_script","node_path":"root/DialogueBox/DialogRoot/Anchor/Box/Body/Choices",
#      "script_path":"scripts/choice_list.gd"}]}'
class_name ChoiceList
extends VBoxContainer

signal choice_selected(index: int)

## Theme type variation applied to every generated Button, so choices can be
## styled without touching this script.
@export var button_variation: String = ""
## Grab focus on the first choice, so a gamepad can answer without a mouse.
@export var focus_first: bool = true


func _ready() -> void:
	# A container must never take focus itself, or the first ui_down lands here
	# instead of on a choice.
	focus_mode = Control.FOCUS_NONE
	visible = false


## `choices` is the array dialogue_runner.gd emits: one Dictionary per visible
## choice, with at least a "text" key. Index 0 is the first button.
func show_choices(choices: Array) -> void:
	clear_choices()
	if choices.is_empty():
		return

	visible = true
	for index in choices.size():
		var choice: Dictionary = choices[index] if choices[index] is Dictionary else {}
		var button := Button.new()
		button.name = "Choice%d" % index
		button.text = str(choice.get("text", "..."))
		button.focus_mode = Control.FOCUS_ALL
		if not button_variation.is_empty():
			button.theme_type_variation = button_variation
		button.pressed.connect(_on_choice_pressed.bind(index))
		add_child(button)

	if focus_first:
		var first: Button = get_child(0) as Button
		if first != null:
			first.grab_focus()


## Removes the buttons immediately (not with queue_free), so a ui_report or a
## dump_tree taken on the next frame shows the real state.
func clear_choices() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	visible = false


func choice_count() -> int:
	return get_child_count()


## ui_accept is taken here rather than in the Button, because Godot's Button
## does not mark the key press as handled: left alone it would also reach
## dialog_box.gd's _unhandled_input and skip the question. Mouse clicks still
## arrive through the `pressed` signal.
func _input(event: InputEvent) -> void:
	if not visible or get_child_count() == 0:
		return
	if not event.is_action_pressed("ui_accept") or event.is_echo():
		return
	var focused: Control = get_viewport().gui_get_focus_owner()
	if focused == null or focused.get_parent() != self:
		return
	get_viewport().set_input_as_handled()
	_on_choice_pressed(focused.get_index())


func _on_choice_pressed(index: int) -> void:
	clear_choices()
	choice_selected.emit(index)
