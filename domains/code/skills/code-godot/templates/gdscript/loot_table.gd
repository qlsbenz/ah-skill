# loot_table.gd — weighted drops as a Resource. One .tres per chest, enemy or
# breakable; `rng_seed` makes a table replay the same sequence every run, which
# is what lets a unit test assert on loot at all.
#
# Expected scene tree: none. This is a Resource, not a node — a spawner holds it
#   as `@export var loot: LootTable` and calls `roll()` when the thing dies.
#
# Autoload: no. Declares `class_name LootTable`; run
#   godot --headless --path /absolute/path/to/project --import
# after copying it, before any script that annotates a variable as `LootTable`.
#
# Input actions: none.
#
# Attach with: nothing to attach. Author the table with
#   resource_batch '{"resource_path":"loot/chest.tres","create_if_missing":true,
#     "script":"res://scripts/loot_table.gd","actions":[
#       {"type":"set_properties","properties":{"rng_seed":1234,"rolls":2,"entries":[
#         {"item":{"__resource":"res://items/coin.tres"},"weight":6.0,"min":1,"max":5},
#         {"item":{"__resource":"res://items/potion.tres"},"weight":3.0},
#         {"item":null,"weight":1.0}]}}]}'
class_name LootTable
extends Resource

## One Dictionary per possible drop:
##   item   : ItemData — or null for "nothing", which is how a miss chance is
##            spelled (an empty draw is a real outcome, not an error).
##   weight : float, relative. 6.0 against 3.0 is twice as likely.
##   min    : int, smallest stack this entry drops (default 1).
##   max    : int, largest stack (default = min).
@export var entries: Array[Dictionary] = []

## How many draws one roll() makes when it is called without an argument.
@export var rolls: int = 1

## -1 randomizes on the first draw. Any other value replays the same sequence
## every run — set it in tests, leave it at -1 in the shipped .tres.
@export var rng_seed: int = -1

var _rng: RandomNumberGenerator = null


## Draws `times` entries (default `rolls`) and returns the non-empty results as
## [{"item": ItemData, "count": int}], stacks of the same item merged.
func roll(times: int = -1) -> Array[Dictionary]:
	var draws: int = maxi(times if times >= 0 else rolls, 0)
	var result: Array[Dictionary] = []
	for _index in draws:
		var drop: Dictionary = roll_once()
		var item: ItemData = drop["item"]
		if item == null:
			continue
		var merged: bool = false
		for row in result:
			var existing: ItemData = row["item"]
			if existing.matches(item):
				row["count"] = int(row["count"]) + int(drop["count"])
				merged = true
				break
		if not merged:
			result.append(drop)
	return result


## One weighted draw. {"item": null, "count": 0} means this draw dropped nothing.
func roll_once() -> Dictionary:
	_ensure_rng()
	var total: float = total_weight()
	if total <= 0.0:
		return {"item": null, "count": 0}

	var ticket: float = _rng.randf() * total
	var running: float = 0.0
	for entry in entries:
		running += _entry_weight(entry)
		if ticket < running:
			return _draw(entry)
	return _draw(entries[entries.size() - 1])


func total_weight() -> float:
	var total: float = 0.0
	for entry in entries:
		total += _entry_weight(entry)
	return total


## Chance of one draw producing this item, 0.0-1.0. Useful in a test that wants
## to assert the table's shape rather than a specific sequence.
func chance_of(item: ItemData) -> float:
	var total: float = total_weight()
	if total <= 0.0 or item == null:
		return 0.0
	var matched: float = 0.0
	for entry in entries:
		var entry_item: ItemData = entry.get("item")
		if entry_item != null and entry_item.matches(item):
			matched += _entry_weight(entry)
	return matched / total


## Re-seed, so two rolls can be compared. reset_rng(rng_seed) restarts the
## documented sequence; reset_rng(-1) goes back to random.
func reset_rng(new_seed: int = -2) -> void:
	if new_seed != -2:
		rng_seed = new_seed
	_rng = null
	_ensure_rng()


func add_entry(item: ItemData, weight: float = 1.0, min_count: int = 1, max_count: int = -1) -> void:
	entries.append({
		"item": item,
		"weight": weight,
		"min": min_count,
		"max": max_count if max_count >= min_count else min_count,
	})


## Everything wrong with the table, as one line each. Empty means it is sane.
## Call it from a unit test — a table whose weights are all 0 drops nothing and
## looks exactly like a table that is simply unlucky.
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if entries.is_empty():
		problems.append("entries is empty — roll() can only return nothing")
	for index in entries.size():
		var entry: Dictionary = entries[index]
		var item: Variant = entry.get("item")
		if item != null and not (item is ItemData):
			problems.append("entry %d: 'item' is %s, expected ItemData or null" % [index, type_string(typeof(item))])
		if _entry_weight(entry) < 0.0:
			problems.append("entry %d: negative weight %f" % [index, _entry_weight(entry)])
		var low: int = int(entry.get("min", 1))
		var high: int = int(entry.get("max", low))
		if high < low:
			problems.append("entry %d: max %d is below min %d" % [index, high, low])
	if total_weight() <= 0.0 and not entries.is_empty():
		problems.append("every weight is 0 — roll() always returns nothing")
	return problems


func _draw(entry: Dictionary) -> Dictionary:
	var item: ItemData = entry.get("item")
	if item == null:
		return {"item": null, "count": 0}
	var low: int = maxi(int(entry.get("min", 1)), 0)
	var high: int = maxi(int(entry.get("max", low)), low)
	var amount: int = low if high == low else _rng.randi_range(low, high)
	return {"item": item, "count": amount}


func _entry_weight(entry: Dictionary) -> float:
	return float(entry.get("weight", 1.0))


# The seed cannot be applied in _init(): exported values are written after the
# resource is constructed, so a .tres seed would be lost. Apply it on first use.
func _ensure_rng() -> void:
	if _rng != null:
		return
	_rng = RandomNumberGenerator.new()
	if rng_seed < 0:
		_rng.randomize()
	else:
		_rng.seed = rng_seed
