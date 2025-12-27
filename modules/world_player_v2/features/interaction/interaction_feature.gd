extends "res://modules/world_player_v2/features/feature_base.gd"
class_name InteractionFeatureV2
## InteractionFeature - Handles E key interactions (pickup, doors, vehicles)
## Extracts interaction logic from player_interaction.gd

const BARRICADE_HOLD_TIME: float = 1.0

# State
var current_target: Node = null
var current_prompt: String = ""
var barricade_hold_timer: float = 0.0

# References
var building_manager: Node = null
var vehicle_manager: Node = null
var entity_manager: Node = null

func _on_initialize() -> void:
	building_manager = player.building_manager
	vehicle_manager = player.get_tree().get_first_node_in_group("vehicle_manager")
	entity_manager = player.get_tree().get_first_node_in_group("entity_manager")

func _input(event: InputEvent) -> void:
	if not player:
		return
	
	# E key for interaction
	if event is InputEventKey and event.keycode == KEY_E:
		if event.pressed:
			_on_interact_pressed()
		else:
			_on_interact_released()

func _physics_process(_delta: float) -> void:
	_update_target()
	_update_barricade_hold(_delta)

## Update interaction target
func _update_target() -> void:
	var hit = player.raycast(5.0, 0xFFFFFFFF, true, true)
	
	var new_target: Node = null
	var new_prompt: String = ""
	
	if hit:
		var collider = hit.get("collider")
		if collider:
			# Check for door meta
			if collider.has_meta("door"):
				var door = collider.get_meta("door")
				if door and door.is_in_group("interactable"):
					new_target = door
					new_prompt = "[E] Open/Close"
			
			# Check various interactable types
			if not new_target:
				new_target = _find_interactable(collider)
				if new_target:
					new_prompt = _get_prompt_for_target(new_target)
	
	# Update state
	if new_target != current_target:
		current_target = new_target
		current_prompt = new_prompt
		
		if current_target:
			PlayerSignalsV2.interaction_available.emit(current_target, current_prompt)
		else:
			PlayerSignalsV2.interaction_unavailable.emit()

## Find interactable in hierarchy
func _find_interactable(node: Node) -> Node:
	if node.is_in_group("interactable") or node.is_in_group("vehicle"):
		return node
	
	var parent = node.get_parent()
	for i in 3:
		if not parent:
			break
		if parent.is_in_group("interactable") or parent.is_in_group("vehicle"):
			return parent
		parent = parent.get_parent()
	
	return null

## Get prompt for target type
func _get_prompt_for_target(target: Node) -> String:
	if target.is_in_group("vehicle"):
		return "[E] Enter Vehicle"
	if target.is_in_group("doors"):
		return "[E] Open/Close"
	if target.is_in_group("windows"):
		return "[E] Open/Close"
	if target.is_in_group("pickups") or target.is_in_group("pickup_items") or target.has_meta("item_data"):
		return "[E] Pick Up"
	if target is RigidBody3D and target.is_in_group("interactable"):
		return "[E] Pick Up"
	return "[E] Interact"

## Handle E press
func _on_interact_pressed() -> void:
	if not current_target:
		return
	
	# Vehicle
	if current_target.is_in_group("vehicle"):
		_enter_vehicle(current_target)
		return
	
	# Pickup
	if _is_pickup(current_target):
		_pickup_item(current_target)
		return
	
	# Door
	if current_target.is_in_group("doors"):
		_toggle_door(current_target)
		return
	
	# Window
	if current_target.is_in_group("windows"):
		_toggle_window(current_target)
		return
	
	# Generic interact
	if current_target.has_method("interact"):
		current_target.interact()
		PlayerSignalsV2.interaction_performed.emit(current_target, "interact")

## Handle E release
func _on_interact_released() -> void:
	barricade_hold_timer = 0.0

## Update barricade hold
func _update_barricade_hold(delta: float) -> void:
	if Input.is_action_pressed("interact") if InputMap.has_action("interact") else Input.is_key_pressed(KEY_E):
		if current_target and current_target.is_in_group("windows"):
			barricade_hold_timer += delta
			if barricade_hold_timer >= BARRICADE_HOLD_TIME:
				_barricade_window(current_target)
				barricade_hold_timer = 0.0

## Check if target is a pickup
func _is_pickup(target: Node) -> bool:
	if target.is_in_group("pickups"):
		return true
	if target.is_in_group("pickup_items"):
		return true
	if target.has_meta("item_data"):
		return true
	if target is RigidBody3D and target.is_in_group("interactable") and not target.is_in_group("vehicle"):
		return true
	return false

## Pickup an item
func _pickup_item(target: Node) -> void:
	var item_data = _get_item_data(target)
	if item_data.is_empty():
		return
	
	var inventory = player.get_feature("inventory")
	if not inventory:
		return
	
	var item_id = item_data.get("id", "")
	var count = item_data.get("count", 1)
	
	# Check for preferred slot
	var preferred_slot = -1
	if target.has_meta("preferred_slot"):
		preferred_slot = target.get_meta("preferred_slot")
	
	# Add to inventory
	var overflow = inventory.add_item(item_id, count)
	
	if overflow < count:
		# At least some was picked up
		target.queue_free()
		PlayerSignalsV2.interaction_performed.emit(target, "pickup")
		DebugSettings.log_player("InteractionV2: Picked up %s x%d" % [item_id, count - overflow])

## Get item data from target
func _get_item_data(target: Node) -> Dictionary:
	# PickupItem class
	if target.has_method("get_item_data"):
		return target.get_item_data()
	
	# Meta data
	if target.has_meta("item_data"):
		return target.get_meta("item_data")
	
	return {}

## Enter a vehicle
func _enter_vehicle(vehicle: Node) -> void:
	if not vehicle_manager:
		return
	
	# TODO: Implement vehicle entry
	PlayerSignalsV2.interaction_performed.emit(vehicle, "enter_vehicle")

## Toggle a door
func _toggle_door(door: Node) -> void:
	if door.has_method("toggle"):
		door.toggle()
	elif door.has_method("interact"):
		door.interact()

## Toggle a window
func _toggle_window(window: Node) -> void:
	if window.has_method("toggle"):
		window.toggle()

## Barricade a window
func _barricade_window(window: Node) -> void:
	if window.has_method("barricade"):
		window.barricade()
		PlayerSignalsV2.interaction_performed.emit(window, "barricade")
