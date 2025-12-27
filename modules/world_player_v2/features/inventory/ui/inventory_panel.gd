extends PanelContainer
class_name InventoryPanelV2
## InventoryPanelV2 - Main inventory panel UI
## Displays 27-slot (3x9) inventory grid with drag-drop support

signal item_dropped_outside(item_data: Dictionary, count: int, drop_pos: Vector2)

const InventorySlotScene = preload("res://modules/world_player_v2/features/inventory/ui/inventory_slot.tscn")

const SLOT_COUNT: int = 27
const COLUMNS: int = 9

@onready var grid_container: GridContainer = $MarginContainer/GridContainer
@onready var title_label: Label = $TitleLabel

var slots: Array = []
var inventory_feature: Node = null

func _ready() -> void:
	PlayerSignalsV2.inventory_toggled.connect(_on_inventory_toggled)
	PlayerSignalsV2.inventory_changed.connect(refresh_display)
	
	_create_slots()
	visible = false
	
	DebugSettings.log_player("InventoryPanelV2: Initialized with %d slots" % SLOT_COUNT)

## Create inventory slots
func _create_slots() -> void:
	if not grid_container:
		return
	
	grid_container.columns = COLUMNS
	
	for i in SLOT_COUNT:
		var slot: Node
		if InventorySlotScene:
			slot = InventorySlotScene.instantiate()
		else:
			slot = _create_default_slot()
		
		slot.name = "Slot%d" % i
		slot.slot_index = i
		slot.item_dropped_outside.connect(_on_slot_item_dropped_outside.bind(slot))
		grid_container.add_child(slot)
		slots.append(slot)

## Create default slot if scene not available
func _create_default_slot() -> PanelContainer:
	var slot = PanelContainer.new()
	slot.custom_minimum_size = Vector2(48, 48)
	
	var label = Label.new()
	label.name = "ItemLabel"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	slot.add_child(label)
	
	var count = Label.new()
	count.name = "CountLabel"
	slot.add_child(count)
	
	return slot

## Refresh display from inventory feature
func refresh_display() -> void:
	if not inventory_feature:
		_find_inventory_feature()
	
	if not inventory_feature:
		return
	
	for i in slots.size():
		var slot = slots[i]
		var slot_data = inventory_feature.main_slots[i] if i < inventory_feature.main_slots.size() else null
		
		if slot_data:
			var item_dict = ItemRegistryV2.get_item_dict(slot_data.item_id) if not slot_data.is_empty() else {}
			slot.set_slot_data({
				"item": item_dict,
				"count": slot_data.count
			}, i)
		else:
			slot.set_slot_data({}, i)

## Find inventory feature
func _find_inventory_feature() -> void:
	var player = get_tree().get_first_node_in_group("player")
	if player and player.has_method("get_feature"):
		inventory_feature = player.get_feature("inventory")

## Handle slot drop
func handle_slot_drop(source_index: int, target_index: int) -> void:
	if not inventory_feature:
		return
	
	# Swap slots
	if source_index >= 0 and source_index < inventory_feature.main_slots.size():
		if target_index >= 0 and target_index < inventory_feature.main_slots.size():
			var temp = inventory_feature.main_slots[source_index].duplicate()
			inventory_feature.main_slots[source_index] = inventory_feature.main_slots[target_index].duplicate()
			inventory_feature.main_slots[target_index] = temp
			
			PlayerSignalsV2.inventory_changed.emit()

## Handle item dropped outside panel
func _on_slot_item_dropped_outside(item: Dictionary, count: int, slot: Node) -> void:
	var drop_pos = get_global_mouse_position()
	item_dropped_outside.emit(item, count, drop_pos)
	
	# Spawn in world
	_spawn_dropped_item(item, count)
	
	# Clear slot
	var slot_idx = slots.find(slot)
	if slot_idx >= 0 and inventory_feature:
		var SlotData = preload("res://modules/world_player_v2/features/inventory/slot_data.gd")
		inventory_feature.main_slots[slot_idx] = SlotData.new()
		PlayerSignalsV2.inventory_changed.emit()

## Spawn dropped item in world
func _spawn_dropped_item(item: Dictionary, count: int) -> void:
	var player = get_tree().get_first_node_in_group("player")
	if not player:
		return
	
	var drop_pos = player.global_position + player.get_look_direction() * 1.5 + Vector3.UP * 0.5
	
	# Check for physics scene
	var scene_path = item.get("scene", "")
	if not scene_path.is_empty():
		var scene = load(scene_path)
		if scene:
			var instance = scene.instantiate()
			if instance is RigidBody3D:
				get_tree().root.add_child(instance)
				instance.global_position = drop_pos
				instance.set_meta("item_data", item.duplicate())
				if not instance.is_in_group("interactable"):
					instance.add_to_group("interactable")
				instance.linear_velocity = player.get_look_direction() * 3.0 + Vector3.UP * 2.0
				return
			else:
				instance.queue_free()
	
	# Use pickup scene
	var pickup_scene = load("res://modules/world_player_v2/pickups/pickup_item.tscn")
	if pickup_scene:
		var pickup = pickup_scene.instantiate()
		get_tree().root.add_child(pickup)
		pickup.global_position = drop_pos
		if pickup.has_method("set_item"):
			pickup.set_item(item, count)
		pickup.linear_velocity = player.get_look_direction() * 3.0 + Vector3.UP * 2.0

## Toggle visibility
func _on_inventory_toggled(is_open: bool) -> void:
	visible = is_open
	if is_open:
		refresh_display()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
