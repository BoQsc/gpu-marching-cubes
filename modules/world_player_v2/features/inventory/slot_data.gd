extends RefCounted
class_name SlotDataV2
## SlotData - Represents a single inventory slot
## Stores item_id and count only (not full dictionaries) for Single Source of Truth

var item_id: String = ""
var count: int = 0

func _init(id: String = "", c: int = 0) -> void:
	item_id = id
	count = c

## Check if slot is empty
func is_empty() -> bool:
	return item_id.is_empty() or count <= 0

## Check if this slot can stack with another item
func can_stack(other_id: String, max_stack: int) -> bool:
	if is_empty():
		return false
	return item_id == other_id and count < max_stack

## Add items to this slot, returns overflow
func add(amount: int, max_stack: int) -> int:
	var space = max_stack - count
	var to_add = min(amount, space)
	count += to_add
	return amount - to_add

## Remove items from this slot, returns amount actually removed
func remove(amount: int) -> int:
	var to_remove = min(amount, count)
	count -= to_remove
	if count <= 0:
		clear()
	return to_remove

## Clear the slot
func clear() -> void:
	item_id = ""
	count = 0

## Set slot contents
func set_contents(id: String, c: int) -> void:
	item_id = id
	count = c

## Create a copy
func duplicate() -> SlotDataV2:
	return SlotDataV2.new(item_id, count)

## Convert to dictionary for serialization
func to_dict() -> Dictionary:
	return {"id": item_id, "count": count}

## Load from dictionary
func from_dict(data: Dictionary) -> void:
	item_id = data.get("id", "")
	count = data.get("count", 0)
