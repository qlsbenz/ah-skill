# item_data.gd — the data behind one kind of item. A custom Resource, so every
# item in the game is a .tres file you can author, diff and load by path instead
# of a Dictionary buried in a script.
#
# Expected scene tree: none. This is a Resource, not a node — it is saved as a
#   .tres and referenced by inventory.gd, loot_table.gd and pickup scenes.
#
# Autoload: no. Declares `class_name ItemData`; run
#   godot --headless --path /absolute/path/to/project --import
# after copying it, before any script that annotates a variable as `ItemData`.
#
# Input actions: none.
#
# Attach with: nothing to attach. Author one instance per item with
#   resource_batch '{"resource_path":"items/coin.tres","create_if_missing":true,
#     "script":"res://scripts/item_data.gd","actions":[
#       {"type":"set_properties","properties":{"id":"coin","display_name":"Coin",
#        "icon":{"__resource":"res://art/icon_coin.png"},"max_stack":99,"value":1,
#        "tags":["currency"]}}]}'
class_name ItemData
extends Resource

## Stable key. Saves and loot tables match on this, never on the file name.
@export var id: String = ""
@export var display_name: String = ""
@export var icon: Texture2D = null
## 1 = one item per slot. Anything higher stacks up to this many.
@export var max_stack: int = 1
## Shop price, score value — whatever "how much is it worth" means here.
@export var value: int = 0
@export var tags: Array[String] = []
@export_multiline var description: String = ""


func is_stackable() -> bool:
	return max_stack > 1


## Never trust max_stack to be sane: a 0 or negative value authored by hand
## would make every add() a no-op, which reads as "the item vanished".
func stack_limit() -> int:
	return maxi(max_stack, 1)


func has_tag(tag: String) -> bool:
	return tags.has(tag)


## What to show when the resource has no display_name yet.
func label() -> String:
	if not display_name.is_empty():
		return display_name
	return id if not id.is_empty() else "item"


## True when two resources describe the same item. Compare with this instead of
## `==`: a .tres loaded twice can be two instances, and a save file only carries
## the id.
func matches(other: ItemData) -> bool:
	if other == null:
		return false
	if other == self:
		return true
	return not id.is_empty() and id == other.id
