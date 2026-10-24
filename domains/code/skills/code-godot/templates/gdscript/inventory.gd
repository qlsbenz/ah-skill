# inventory.gd — a fixed number of slots holding ItemData stacks. Every rule
# (where a stack goes, how much fits, what a removal takes) lives in a plain
# function with no node and no frame behind it, so it can be unit-tested with
# `scripts/test/run_tests.py --framework mini`.
#
# Expected scene tree (node name : type) — playbook 15 builds exactly this:
#   Hero : CharacterBody2D            (in the group "player")
#     Sprite : AnimatedSprite2D
#     CollisionShape2D : CollisionShape2D
#     Inventory : Node                <- attach this script here
#   unique_name_in_owner: not needed. A pickup finds the bag with
#   `body.get_node_or_null("Inventory")`, so nothing has to hold a reference.
#
# Autoload: no (make it one when a single bag follows the player across scenes).
#   Declares `class_name Inventory`; run
#   godot --headless --path /absolute/path/to/project --import
# after copying it, before any script that annotates a variable as `Inventory`.
#
# Input actions: none.
#
# Attach with:
#   scene_batch '{"scene_path":"scenes/hero.tscn","actions":[
#     {"type":"add_node","parent_node_path":"root","node_type":"Node","node_name":"Inventory"},
#     {"type":"attach_script","node_path":"root/Inventory","script_path":"scripts/inventory.gd",
#      "script_properties":{"slot_count":8}}]}'
class_name Inventory
extends Node

## Emitted once after every mutation, so a UI can just call refresh().
signal changed
signal item_added(item: ItemData, amount: int)
signal item_removed(item: ItemData, amount: int)

@export var slot_count: int = 12

## One entry per slot: {"item": ItemData|null, "count": int}.
var _slots: Array[Dictionary] = []


func _ready() -> void:
	_ensure_slots()


## Adds up to `amount`, topping up existing stacks before taking a free slot.
## Returns how many actually fit — the caller keeps the rest (or drops it).
func add(item: ItemData, amount: int = 1) -> int:
	_ensure_slots()
	if item == null or amount <= 0:
		return 0

	var limit: int = item.stack_limit()
	var left: int = amount
	for index in _slots.size():
		if left <= 0:
			break
		var slot_data: Dictionary = _slots[index]
		var slot_item: ItemData = slot_data["item"]
		if slot_item == null or not slot_item.matches(item):
			continue
		var space: int = limit - int(slot_data["count"])
		if space <= 0:
			continue
		var moved: int = mini(space, left)
		slot_data["count"] = int(slot_data["count"]) + moved
		left -= moved

	for index in _slots.size():
		if left <= 0:
			break
		var slot_data: Dictionary = _slots[index]
		if slot_data["item"] != null:
			continue
		var moved: int = mini(limit, left)
		slot_data["item"] = item
		slot_data["count"] = moved
		left -= moved

	var added: int = amount - left
	if added > 0:
		item_added.emit(item, added)
		changed.emit()
	return added


## Removes up to `amount`, first slot first. Returns how many were removed, so
## `remove(potion) == 1` is the "did the player actually have one" check.
func remove(item: ItemData, amount: int = 1) -> int:
	_ensure_slots()
	if item == null or amount <= 0:
		return 0

	var left: int = amount
	for index in _slots.size():
		if left <= 0:
			break
		var slot_data: Dictionary = _slots[index]
		var slot_item: ItemData = slot_data["item"]
		if slot_item == null or not slot_item.matches(item):
			continue
		var taken: int = mini(int(slot_data["count"]), left)
		slot_data["count"] = int(slot_data["count"]) - taken
		left -= taken
		if int(slot_data["count"]) <= 0:
			slot_data["item"] = null
			slot_data["count"] = 0

	var removed: int = amount - left
	if removed > 0:
		item_removed.emit(item, removed)
		changed.emit()
	return removed


func count(item: ItemData) -> int:
	_ensure_slots()
	if item == null:
		return 0
	var total: int = 0
	for slot_data in _slots:
		var slot_item: ItemData = slot_data["item"]
		if slot_item != null and slot_item.matches(item):
			total += int(slot_data["count"])
	return total


func has(item: ItemData, amount: int = 1) -> bool:
	return count(item) >= maxi(amount, 1)


## How many more of `item` would fit. Check this before a pickup so the player
## does not walk over a coin that silently evaporates.
func space_for(item: ItemData) -> int:
	_ensure_slots()
	if item == null:
		return 0
	var limit: int = item.stack_limit()
	var space: int = 0
	for slot_data in _slots:
		var slot_item: ItemData = slot_data["item"]
		if slot_item == null:
			space += limit
		elif slot_item.matches(item):
			space += maxi(limit - int(slot_data["count"]), 0)
	return space


## True when no slot is empty. A partly filled stack of the same item may still
## have room — ask space_for() before concluding a pickup cannot happen.
func is_full() -> bool:
	_ensure_slots()
	for slot_data in _slots:
		if slot_data["item"] == null:
			return false
	return true


func is_empty() -> bool:
	_ensure_slots()
	for slot_data in _slots:
		if slot_data["item"] != null:
			return false
	return true


func used_slots() -> int:
	_ensure_slots()
	var used: int = 0
	for slot_data in _slots:
		if slot_data["item"] != null:
			used += 1
	return used


## A copy of one slot: {"item": ItemData|null, "count": int}. Mutating the copy
## cannot corrupt the inventory — go through add() / remove().
func slot(index: int) -> Dictionary:
	_ensure_slots()
	if index < 0 or index >= _slots.size():
		return {"item": null, "count": 0}
	var slot_data: Dictionary = _slots[index]
	return slot_data.duplicate()


func slots() -> Array[Dictionary]:
	_ensure_slots()
	var copy: Array[Dictionary] = []
	for slot_data in _slots:
		copy.append(slot_data.duplicate())
	return copy


func clear() -> void:
	_ensure_slots()
	for slot_data in _slots:
		slot_data["item"] = null
		slot_data["count"] = 0
	changed.emit()


## Save payload. Items are stored by path plus id, so a slot survives a renamed
## .tres as long as the id is stable. Feed it straight to
## SaveManager.save_game({"inventory": inventory.to_dict()}, 0).
func to_dict() -> Dictionary:
	_ensure_slots()
	var rows: Array = []
	for index in _slots.size():
		var slot_data: Dictionary = _slots[index]
		var item: ItemData = slot_data["item"]
		if item == null:
			continue
		rows.append({
			"slot": index,
			"id": item.id,
			"path": item.resource_path,
			"count": int(slot_data["count"]),
		})
	return {"slot_count": slot_count, "slots": rows}


## The inverse of to_dict(). A row whose resource is gone is skipped with a
## warning instead of taking the whole load down with it.
func from_dict(data: Dictionary) -> void:
	slot_count = int(data.get("slot_count", slot_count))
	_slots.clear()
	_ensure_slots()
	var raw: Variant = data.get("slots", [])
	if not (raw is Array):
		push_warning("Inventory: save payload has no 'slots' array — starting empty.")
		changed.emit()
		return
	var rows: Array = raw
	for entry in rows:
		if not (entry is Dictionary):
			continue
		var row: Dictionary = entry
		var path: String = str(row.get("path", ""))
		var index: int = int(row.get("slot", -1))
		var amount: int = int(row.get("count", 0))
		if path.is_empty() or amount <= 0:
			continue
		if not ResourceLoader.exists(path):
			push_warning("Inventory: %s is gone — slot %d dropped." % [path, index])
			continue
		var item: ItemData = ResourceLoader.load(path) as ItemData
		if item == null:
			push_warning("Inventory: %s is not an ItemData — slot %d dropped." % [path, index])
			continue
		var slot_data: Dictionary = _slots[index] if index >= 0 and index < _slots.size() else {}
		if not slot_data.is_empty() and slot_data["item"] == null:
			slot_data["item"] = item
			slot_data["count"] = mini(amount, item.stack_limit())
		else:
			add(item, amount)
	changed.emit()


func _ensure_slots() -> void:
	var wanted: int = maxi(slot_count, 1)
	while _slots.size() < wanted:
		_slots.append({"item": null, "count": 0})
	while _slots.size() > wanted:
		_slots.pop_back()
