# inventory_ui.gd — a grid of slot buttons bound to one inventory.gd. It reads
# nothing per frame: every redraw comes from the Inventory's `changed` signal,
# and every slot is a real focusable Button so a gamepad can walk the grid.
#
# Expected scene tree (node name : type):
#   InventoryUI : CanvasLayer         <- attach this script here (layer = 4)
#     Root : Control                  unique_name_in_owner = true  (%Root)
#       Center : CenterContainer      layout_preset FULL_RECT
#         Panel : PanelContainer
#           Margin : MarginContainer
#             Body : VBoxContainer
#               Title : Label
#               Grid : GridContainer  unique_name_in_owner = true  (%Grid)
#   The two %-nodes MUST have unique_name_in_owner set, or `%Name` is null.
#   The slot buttons are created at runtime, one per inventory slot.
#
# Autoload: no. Uses `Inventory` and `ItemData`, so run
#   godot --headless --path /absolute/path/to/project --import
# after copying inventory.gd and item_data.gd.
#
# Input actions: none of its own. Bind a key to `toggle()` from the level, or
# call open() / close() from a chest or a pause menu.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/inventory_ui.tscn","actions":[
#     {"type":"configure_node","node_path":"root/Root","unique_name_in_owner":true},
#     {"type":"attach_script","node_path":"root","script_path":"scripts/inventory_ui.gd",
#      "script_properties":{"columns":4,"slot_min_size":{"__type":"Vector2","x":120,"y":36}}}]}'
# Then, from the level script (this file declares no class_name, so go through
# call() and keep the level free of unsafe member access):
#   @onready var _ui: CanvasLayer = %InventoryUI
#   _ui.call(&"bind", $Hero/Inventory)
extends CanvasLayer

signal slot_activated(index: int, item: ItemData)
signal opened
signal closed

@export var columns: int = 4
@export var slot_min_size: Vector2 = Vector2(112, 40)
## Text a slot shows when it is empty. Keep it non-empty: a zero-width button
## collapses the grid cell and `ui_report` then reports a zero_size finding.
@export var empty_slot_text: String = "-"

@onready var _root: Control = %Root
@onready var _grid: GridContainer = %Grid

var _inventory: Inventory = null


func _ready() -> void:
	_grid.columns = maxi(columns, 1)
	_root.visible = false


## Point the grid at an inventory. Safe to call again after a respawn: the old
## connection is dropped first.
func bind(new_inventory: Inventory) -> void:
	if _inventory == new_inventory:
		return
	if _inventory != null and _inventory.changed.is_connected(refresh):
		_inventory.changed.disconnect(refresh)
	_inventory = new_inventory
	if _inventory != null:
		_inventory.changed.connect(refresh)
	refresh()


## Rebuilds every slot button from the bound inventory.
func refresh() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	if _inventory == null:
		return

	var rows: Array[Dictionary] = _inventory.slots()
	for index in rows.size():
		var slot_data: Dictionary = rows[index]
		var item: ItemData = slot_data["item"]
		var button := Button.new()
		button.name = "Slot%d" % index
		button.custom_minimum_size = slot_min_size
		button.focus_mode = Control.FOCUS_ALL
		button.clip_text = true
		button.text = empty_slot_text if item == null else _slot_label(item, int(slot_data["count"]))
		if item != null and item.icon != null:
			button.icon = item.icon
		button.pressed.connect(_on_slot_pressed.bind(index))
		_grid.add_child(button)


func open() -> void:
	if _root.visible:
		return
	refresh()
	_root.visible = true
	if _grid.get_child_count() > 0:
		var first: Button = _grid.get_child(0) as Button
		if first != null:
			first.grab_focus()
	opened.emit()


func close() -> void:
	if not _root.visible:
		return
	_root.visible = false
	closed.emit()


func toggle() -> void:
	if _root.visible:
		close()
	else:
		open()


func is_open() -> bool:
	return _root.visible


func bound_inventory() -> Inventory:
	return _inventory


func _slot_label(item: ItemData, amount: int) -> String:
	if amount > 1:
		return "%s x%d" % [item.label(), amount]
	return item.label()


func _on_slot_pressed(index: int) -> void:
	if _inventory == null:
		return
	var slot_data: Dictionary = _inventory.slot(index)
	slot_activated.emit(index, slot_data["item"])
