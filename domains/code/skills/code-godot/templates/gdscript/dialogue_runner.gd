# dialogue_runner.gd — walks a branching dialogue graph. It owns the story state
# (which node, which flags) and owns no UI: it emits `line_shown` /
# `choices_shown`, and dialog_box.gd + choice_list.gd draw them.
#
# Graph shape (a Dictionary, usually a .json file next to the scene):
#   {"start": "intro",
#    "nodes": {
#      "intro":  {"speaker": "Marrow", "text": "You again.", "next": "ask"},
#      "ask":    {"speaker": "Marrow", "text": "Will you carry the lantern?",
#                 "choices": [
#                   {"text": "I will.",     "next": "thanks", "set_flag": "promised"},
#                   {"text": "Not today.",  "next": "shrug"},
#                   {"text": "About last night...", "next": "gossip",
#                    "require_flag": "heard_rumour"}]},
#      "thanks": {"speaker": "Marrow", "text": "Then the road is yours.", "end": true}}}
#   Node keys : speaker, text, next, end (bool), choices, branch, set_flag.
#   Choice keys: text, next, set_flag, require_flag.
#   `branch` routes on a flag before `next` is considered:
#     {"branch": [{"require_flag": "promised", "next": "kept"}], "next": "broke"}
#
# Expected scene tree (node name : type) — playbook 16 builds exactly this:
#   Talk : Node2D                      (talk.gd wires the two together)
#     Dialogue : Node                  <- attach this script here
#                                         unique_name_in_owner = true (%Dialogue)
#     DialogueBox : CanvasLayer        (dialog_box.gd, with choice_list.gd inside)
#   unique_name_in_owner on Dialogue, so an NPC can reach the runner from
#   anywhere in the level.
#
# Autoload: no. Declares `class_name DialogueRunner`; run
#   godot --headless --path /absolute/path/to/project --import
# after copying it, before any script that annotates a variable as
# `DialogueRunner`.
#
# Input actions: none of its own — ui_accept advances dialog_box.gd, and the
# choice buttons take ui_accept while they hold focus.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/talk.tscn","actions":[
#     {"type":"add_node","parent_node_path":"root","node_type":"Node","node_name":"Dialogue"},
#     {"type":"configure_node","node_path":"root/Dialogue","unique_name_in_owner":true},
#     {"type":"attach_script","node_path":"root/Dialogue","script_path":"scripts/dialogue_runner.gd",
#      "script_properties":{"graph_path":"res://dialogue/marrow.json","autostart":false}}]}'
class_name DialogueRunner
extends Node

signal line_shown(text: String, speaker: String, node_id: String)
signal choices_shown(choices: Array[Dictionary])
signal flag_changed(flag: String, value: bool)
signal finished

## Loaded in _ready() when set. Leave empty and call load_graph() yourself.
@export_file("*.json") var graph_path: String = ""
@export var autostart: bool = false

## Story flags. Persist them with the rest of the save: they are plain bools.
var flags: Dictionary = {}

var _nodes: Dictionary = {}
var _start_id: String = ""
var _current_id: String = ""
var _running: bool = false
var _choices: Array[Dictionary] = []


func _ready() -> void:
	if graph_path.is_empty():
		return
	if load_graph_file(graph_path) and autostart:
		start()


## Reads a .json graph off disk. Returns false (and says why) on a parse error,
## a missing file, or a graph that does not validate.
func load_graph_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_error("DialogueRunner: no dialogue graph at %s" % path)
		return false
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("DialogueRunner: %s is not a JSON object" % path)
		return false
	return load_graph(parsed)


## Validates first and loads nothing when the graph is broken, so a dangling
## `next` is a startup error instead of a conversation that dead-ends at 3am.
func load_graph(graph: Dictionary) -> bool:
	var problems: PackedStringArray = validate_graph(graph)
	if not problems.is_empty():
		for problem in problems:
			push_error("DialogueRunner: " + problem)
		return false

	var raw_nodes: Variant = graph.get("nodes", {})
	_nodes = raw_nodes
	_start_id = str(graph.get("start", "start"))
	_current_id = ""
	_running = false
	_choices = []
	return true


## Every problem with the graph, one line each; empty means it is playable.
## Static, so a unit test can check a graph without building a node.
static func validate_graph(graph: Dictionary) -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	var raw_nodes: Variant = graph.get("nodes", null)
	if not (raw_nodes is Dictionary):
		problems.append("graph has no 'nodes' object")
		return problems

	var nodes: Dictionary = raw_nodes
	if nodes.is_empty():
		problems.append("graph 'nodes' is empty")
		return problems

	var start_id: String = str(graph.get("start", "start"))
	if not nodes.has(start_id):
		problems.append("start node '%s' does not exist (nodes: %s)" % [start_id, ", ".join(_ids_of(nodes))])

	for key in nodes.keys():
		var node_id: String = str(key)
		var raw_node: Variant = nodes[key]
		if not (raw_node is Dictionary):
			problems.append("node '%s' is not an object" % node_id)
			continue
		var node: Dictionary = raw_node

		var next_id: String = str(node.get("next", ""))
		if not next_id.is_empty() and not nodes.has(next_id):
			problems.append("node '%s': next -> '%s' does not exist" % [node_id, next_id])

		var raw_branch: Variant = node.get("branch", [])
		if raw_branch is Array:
			var branch: Array = raw_branch
			for index in branch.size():
				var raw_arm: Variant = branch[index]
				if not (raw_arm is Dictionary):
					problems.append("node '%s' branch %d is not an object" % [node_id, index])
					continue
				var arm: Dictionary = raw_arm
				var arm_next: String = str(arm.get("next", ""))
				if arm_next.is_empty():
					problems.append("node '%s' branch %d has no 'next'" % [node_id, index])
				elif not nodes.has(arm_next):
					problems.append("node '%s' branch %d: next -> '%s' does not exist" % [node_id, index, arm_next])

		var raw_choices: Variant = node.get("choices", [])
		if not (raw_choices is Array):
			problems.append("node '%s': 'choices' is not an array" % node_id)
			continue
		var choices: Array = raw_choices
		for index in choices.size():
			var raw_choice: Variant = choices[index]
			if not (raw_choice is Dictionary):
				problems.append("node '%s' choice %d is not an object" % [node_id, index])
				continue
			var choice: Dictionary = raw_choice
			var label: String = str(choice.get("text", ""))
			if label.is_empty():
				problems.append("node '%s' choice %d has no 'text'" % [node_id, index])
			var choice_next: String = str(choice.get("next", ""))
			if choice_next.is_empty():
				if not bool(choice.get("end", false)):
					problems.append("node '%s' choice %d ('%s') has neither 'next' nor 'end'" % [node_id, index, label])
			elif not nodes.has(choice_next):
				problems.append("node '%s' choice %d ('%s'): next -> '%s' does not exist" % [node_id, index, label, choice_next])
	return problems


## Enters `node_id` (default: the graph's start). Returns false when the id is
## unknown, listing the ids that do exist.
func start(node_id: String = "") -> bool:
	if _nodes.is_empty():
		push_error("DialogueRunner: no graph loaded — call load_graph() first")
		return false
	var target: String = node_id if not node_id.is_empty() else _start_id
	if not _nodes.has(target):
		push_error("DialogueRunner: no node '%s' (nodes: %s)" % [target, ", ".join(_ids_of(_nodes))])
		return false
	_running = true
	_enter(target)
	return true


## Call this when the presenter is done with the current line (dialog_box.gd's
## `finished` signal). Ignored while choices are on screen — a choice is
## answered with choose(), not by pressing accept again.
func advance() -> void:
	if not _running or not _choices.is_empty():
		return
	var node: Dictionary = _nodes.get(_current_id, {})
	if bool(node.get("end", false)):
		_finish()
		return
	var next_id: String = _resolve_next(node)
	if next_id.is_empty():
		_finish()
		return
	_enter(next_id)


## Picks a choice by its index in the array `choices_shown` handed out — not by
## its index in the graph, which may contain choices hidden by require_flag.
func choose(index: int) -> void:
	if _choices.is_empty():
		return
	if index < 0 or index >= _choices.size():
		push_error("DialogueRunner: choice %d out of range (%d shown)" % [index, _choices.size()])
		return
	var choice: Dictionary = _choices[index]
	_choices = []
	var flag: String = str(choice.get("set_flag", ""))
	if not flag.is_empty():
		set_flag(flag, true)
	var next_id: String = str(choice.get("next", ""))
	if next_id.is_empty():
		_finish()
		return
	_enter(next_id)


func set_flag(flag: String, value: bool = true) -> void:
	if flag.is_empty():
		return
	if bool(flags.get(flag, false)) == value:
		return
	flags[flag] = value
	flag_changed.emit(flag, value)


func has_flag(flag: String) -> bool:
	return bool(flags.get(flag, false))


func is_running() -> bool:
	return _running


func is_awaiting_choice() -> bool:
	return not _choices.is_empty()


func current_node_id() -> String:
	return _current_id


## The choices currently on screen, in the order they were emitted.
func visible_choices() -> Array[Dictionary]:
	return _choices.duplicate()


func _enter(node_id: String) -> void:
	_current_id = node_id
	var node: Dictionary = _nodes.get(node_id, {})

	var flag: String = str(node.get("set_flag", ""))
	if not flag.is_empty():
		set_flag(flag, true)

	line_shown.emit(str(node.get("text", "")), str(node.get("speaker", "")), node_id)

	_choices = _collect_choices(node)
	if not _choices.is_empty():
		choices_shown.emit(_choices.duplicate())


## Drops every choice whose require_flag is not set, so the same node reads
## differently once the player has done something.
func _collect_choices(node: Dictionary) -> Array[Dictionary]:
	var visible: Array[Dictionary] = []
	var raw_choices: Variant = node.get("choices", [])
	if not (raw_choices is Array):
		return visible
	var choices: Array = raw_choices
	for entry in choices:
		if not (entry is Dictionary):
			continue
		var choice: Dictionary = entry
		var required: String = str(choice.get("require_flag", ""))
		if not required.is_empty() and not has_flag(required):
			continue
		visible.append(choice)
	return visible


func _resolve_next(node: Dictionary) -> String:
	var raw_branch: Variant = node.get("branch", [])
	if raw_branch is Array:
		var branch: Array = raw_branch
		for entry in branch:
			if not (entry is Dictionary):
				continue
			var arm: Dictionary = entry
			var required: String = str(arm.get("require_flag", ""))
			if required.is_empty() or has_flag(required):
				return str(arm.get("next", ""))
	return str(node.get("next", ""))


func _finish() -> void:
	_running = false
	_choices = []
	_current_id = ""
	finished.emit()


static func _ids_of(nodes: Dictionary) -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray()
	for key in nodes.keys():
		ids.append(str(key))
	return ids
