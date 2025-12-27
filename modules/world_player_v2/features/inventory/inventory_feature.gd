extends "res://modules/world_player_v2/features/feature_base.gd"
class_name InventoryFeatureV2
## InventoryFeature - Unified inventory management (hotbar + main inventory)
## Uses item IDs only, looking up full data from ItemRegistry when needed

const SlotData = preload("res://modules/world_player_v2/features/inventory/slot_data.gd")

# Constants (preserved from v1)
const HOTBAR_SIZE: int = 10
const MAIN_SIZE: int = 27  # 3 rows of 9
const MAX_STACK_SIZE: int = 3

# Slots
var hotbar_slots: Array = []  # Array of SlotDataV2
var main_slots: Array = []    # Array of SlotDataV2
var selected_hotbar: int = 0

# Signals
signal slot_changed(slot_type: String, index: int)
signal selection_changed(index: int)

func _on_initialize() -> void:
	_initialize_slots()

func _ready() -> void:
	add_to_group("inventory")

func _input(event: InputEvent) -> void:
	# Hotbar selection with number keys
	if event is InputEventKey and event.pressed:
		var key = event.keycode
		if key >= KEY_1 and key <= KEY_9:
			select_hotbar(key - KEY_1)
		elif key == KEY_0:
			select_hotbar(9)

## Initialize all slots
func _initialize_slots() -> void:
	hotbar_slots.clear()
	main_slots.clear()
	
	for i in HOTBAR_SIZE:
		hotbar_slots.append(SlotData.new())
	for i in MAIN_SIZE:
		main_slots.append(SlotData.new())

## Select a hotbar slot
func select_hotbar(index: int) -> void:
	if index < 0 or index >= HOTBAR_SIZE:
		return
	
	selected_hotbar = index
	selection_changed.emit(index)
	PlayerSignalsV2.hotbar_slot_selected.emit(index)
	
	var item_dict = get_selected_item_dict()
	PlayerSignalsV2.item_changed.emit(index, item_dict)

## Get currently selected hotbar slot index
func get_selected_index() -> int:
	return selected_hotbar

## Get item at hotbar slot as ItemDataV2
func get_hotbar_item(index: int) -> Resource:
	if index < 0 or index >= hotbar_slots.size():
		return ItemRegistryV2.fists_item
	var slot = hotbar_slots[index]
	if slot.is_empty():
		return ItemRegistryV2.fists_item
	return ItemRegistryV2.get_item(slot.item_id)

## Get currently selected item as ItemDataV2
func get_selected_item() -> Resource:
	return get_hotbar_item(selected_hotbar)

## Get currently selected item as dictionary (legacy compatibility)
func get_selected_item_dict() -> Dictionary:
	var slot = hotbar_slots[selected_hotbar] if selected_hotbar < hotbar_slots.size() else null
	if not slot or slot.is_empty():
		return {"id": "fists", "name": "Fists", "damage": 1, "mining_strength": 0.3}
	return ItemRegistryV2.get_item_dict(slot.item_id)

## Get item at slot as dictionary (legacy compatibility)
func get_item_at(index: int) -> Dictionary:
	if index < 0 or index >= hotbar_slots.size():
		return {"id": "fists", "name": "Fists", "damage": 1, "mining_strength": 0.3}
	var slot = hotbar_slots[index]
	if slot.is_empty():
		return {"id": "fists", "name": "Fists", "damage": 1, "mining_strength": 0.3}
	var item_dict = ItemRegistryV2.get_item_dict(slot.item_id)
	item_dict["count"] = slot.count
	return item_dict

## Add item to inventory (hotbar first, then main)
## Returns number of items that couldn't fit (overflow)
func add_item(item_id: String, count: int = 1) -> int:
	var item = ItemRegistryV2.get_item(item_id)
	var max_stack = item.max_stack if item else MAX_STACK_SIZE
	max_stack = min(max_stack, MAX_STACK_SIZE)
	
	var remaining = count
	
	# Try stacking in hotbar
	remaining = _try_stack(hotbar_slots, item_id, remaining, max_stack, "hotbar")
	if remaining <= 0:
		return 0
	
	# Try stacking in main
	remaining = _try_stack(main_slots, item_id, remaining, max_stack, "main")
	if remaining <= 0:
		return 0
	
	# Try empty slots in hotbar
	remaining = _try_empty(hotbar_slots, item_id, remaining, max_stack, "hotbar")
	if remaining <= 0:
		return 0
	
	# Try empty slots in main
	remaining = _try_empty(main_slots, item_id, remaining, max_stack, "main")
	
	PlayerSignalsV2.inventory_changed.emit()
	return remaining

## Try to stack items into existing slots
func _try_stack(slots: Array, item_id: String, count: int, max_stack: int, slot_type: String) -> int:
	var remaining = count
	for i in slots.size():
		if remaining <= 0:
			break
		if slots[i].can_stack(item_id, max_stack):
			remaining = slots[i].add(remaining, max_stack)
			slot_changed.emit(slot_type, i)
	return remaining

## Try to put items into empty slots
func _try_empty(slots: Array, item_id: String, count: int, max_stack: int, slot_type: String) -> int:
	var remaining = count
	for i in slots.size():
		if remaining <= 0:
			break
		if slots[i].is_empty():
			slots[i].item_id = item_id
			remaining = slots[i].add(remaining, max_stack)
			slot_changed.emit(slot_type, i)
	return remaining

## Remove item from selected hotbar slot
func consume_selected(amount: int = 1) -> bool:
	return consume_hotbar(selected_hotbar, amount)

## Remove item from hotbar slot
func consume_hotbar(index: int, amount: int = 1) -> bool:
	if index < 0 or index >= hotbar_slots.size():
		return false
	
	var slot = hotbar_slots[index]
	if slot.is_empty():
		return false
	
	slot.remove(amount)
	slot_changed.emit("hotbar", index)
	PlayerSignalsV2.inventory_changed.emit()
	
	if index == selected_hotbar:
		PlayerSignalsV2.item_changed.emit(index, get_selected_item_dict())
	
	return true

## Clear a hotbar slot
func clear_slot(index: int) -> void:
	if index < 0 or index >= hotbar_slots.size():
		return
	hotbar_slots[index].clear()
	slot_changed.emit("hotbar", index)
	PlayerSignalsV2.inventory_changed.emit()

## Get all hotbar slots as array of dictionaries
func get_all_slots() -> Array:
	var result = []
	for i in hotbar_slots.size():
		result.append(get_item_at(i))
	return result

## Set slot contents directly
func set_slot(index: int, item_id: String, count: int) -> void:
	if index < 0 or index >= hotbar_slots.size():
		return
	hotbar_slots[index].set_contents(item_id, count)
	slot_changed.emit("hotbar", index)
	PlayerSignalsV2.inventory_changed.emit()

## Save/Load
func get_save_data() -> Dictionary:
	var hotbar_save = []
	for slot in hotbar_slots:
		hotbar_save.append(slot.to_dict())
	
	var main_save = []
	for slot in main_slots:
		main_save.append(slot.to_dict())
	
	return {
		"hotbar": hotbar_save,
		"main": main_save,
		"selected": selected_hotbar
	}

func load_save_data(data: Dictionary) -> void:
	if data.has("hotbar"):
		for i in min(data["hotbar"].size(), hotbar_slots.size()):
			hotbar_slots[i].from_dict(data["hotbar"][i])
	
	if data.has("main"):
		for i in min(data["main"].size(), main_slots.size()):
			main_slots[i].from_dict(data["main"][i])
	
	if data.has("selected"):
		selected_hotbar = data["selected"]
	
	PlayerSignalsV2.inventory_changed.emit()

## Get selected slot count
func get_selected_count() -> int:
	if selected_hotbar < 0 or selected_hotbar >= hotbar_slots.size():
		return 0
	return hotbar_slots[selected_hotbar].count

## Decrement count at slot, returns true if item remains, false if slot emptied  
func decrement_slot(index: int, amount: int = 1) -> bool:
	if index < 0 or index >= hotbar_slots.size():
		return false
	
	var slot = hotbar_slots[index]
	if slot.is_empty():
		return false
	
	slot.remove(amount)
	slot_changed.emit("hotbar", index)
	PlayerSignalsV2.inventory_changed.emit()
	
	if index == selected_hotbar:
		PlayerSignalsV2.item_changed.emit(index, get_selected_item_dict())
	
	return not slot.is_empty()

## Get slot data (legacy compatibility)
func get_slot(index: int) -> Dictionary:
	if index < 0 or index >= hotbar_slots.size():
		return {"item": {"id": "empty"}, "count": 0}
	var slot = hotbar_slots[index]
	return {
		"item": ItemRegistryV2.get_item_dict(slot.item_id) if not slot.is_empty() else {"id": "empty"},
		"count": slot.count
	}

## Find slot that can stack with given item id
func find_stack_slot(item_id: String) -> int:
	for i in hotbar_slots.size():
		var slot = hotbar_slots[i]
		if slot.item_id == item_id and slot.count < MAX_STACK_SIZE:
			return i
	return -1

## Find first empty slot
func find_empty_slot() -> int:
	for i in hotbar_slots.size():
		if hotbar_slots[i].is_empty():
			return i
	return -1

## Drop selected item as 3D pickup
func drop_selected_item() -> void:
	var item = get_selected_item_dict()
	var count = get_selected_count()
	
	if item.get("id", "empty") == "empty" or item.get("id") == "fists" or count <= 0:
		DebugSettings.log_player("InventoryV2: Nothing to drop")
		return
	
	# Get player position for drop
	if not player:
		return
	
	var drop_pos = player.global_position + Vector3.UP * 1.0 - player.global_transform.basis.z * 1.5
	var drop_velocity = -player.global_transform.basis.z * 3.0 + Vector3.UP * 2.0
	
	# Check if item has its own physics scene (like pistol)
	var scene_path = item.get("scene", "")
	var spawned_directly = false
	
	if scene_path != "":
		var item_scene = load(scene_path)
		if item_scene:
			var temp_instance = item_scene.instantiate()
			if temp_instance is RigidBody3D:
				player.get_tree().root.add_child(temp_instance)
				temp_instance.global_position = drop_pos
				
				# Add to interactable group and store item data
				temp_instance.add_to_group("interactable")
				temp_instance.set_meta("item_data", item.duplicate())
				temp_instance.linear_velocity = drop_velocity
				
				spawned_directly = true
			else:
				temp_instance.queue_free()
	
	# Fallback: use PickupItem wrapper
	if not spawned_directly:
		var pickup_scene = load("res://modules/world_player_v2/pickups/pickup_item.tscn")
		if pickup_scene:
			var pickup = pickup_scene.instantiate()
			player.get_tree().root.add_child(pickup)
			pickup.global_position = drop_pos
			
			if pickup.has_method("set_item"):
				pickup.set_item(item, count)
			
			pickup.linear_velocity = drop_velocity
	
	# Clear the slot
	clear_slot(selected_hotbar)
	DebugSettings.log_player("InventoryV2: Dropped %s x%d" % [item.get("name", "item"), count])

## Set item at slot (legacy compatibility)
func set_item_at(index: int, item: Dictionary, count: int) -> void:
	if index < 0 or index >= hotbar_slots.size():
		return
	
	var item_id = item.get("id", "empty")
	if item_id == "empty" or count <= 0:
		hotbar_slots[index].clear()
	else:
		hotbar_slots[index].set_contents(item_id, count)
	
	slot_changed.emit("hotbar", index)
	PlayerSignalsV2.inventory_changed.emit()
	
	if index == selected_hotbar:
		PlayerSignalsV2.item_changed.emit(index, get_selected_item_dict())

