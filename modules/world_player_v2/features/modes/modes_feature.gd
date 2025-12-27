extends "res://modules/world_player_v2/features/feature_base.gd"
class_name ModesFeatureV2
## ModesFeature - Thin layer for mode switching and routing
## Routes input to appropriate features based on current mode

enum Mode { PLAY, BUILD, EDITOR }

var current_mode: Mode = Mode.PLAY
var editor_submode: int = 0

const EDITOR_SUBMODE_NAMES = ["Terrain", "Water", "Road", "Prefab", "Fly", "OldDirt"]

func _input(event: InputEvent) -> void:
	if not player:
		return
	
	# Mode switching with Tab
	if event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		_cycle_mode()
	
	# Editor submode with Q
	if event is InputEventKey and event.pressed and event.keycode == KEY_Q:
		if current_mode == Mode.EDITOR:
			_cycle_editor_submode()
	
	# Route input to current mode
	_route_input(event)

func _physics_process(delta: float) -> void:
	_route_process(delta)

## Cycle through modes
func _cycle_mode() -> void:
	var old_mode = current_mode
	current_mode = (current_mode + 1) % 3 as Mode
	
	var old_name = _get_mode_name(old_mode)
	var new_name = _get_mode_name(current_mode)
	
	PlayerSignalsV2.mode_changed.emit(old_name, new_name)
	DebugSettings.log_player("ModesV2: Changed from %s to %s" % [old_name, new_name])

## Cycle editor submodes
func _cycle_editor_submode() -> void:
	editor_submode = (editor_submode + 1) % EDITOR_SUBMODE_NAMES.size()
	PlayerSignalsV2.editor_submode_changed.emit(editor_submode, EDITOR_SUBMODE_NAMES[editor_submode])

## Get mode name
func _get_mode_name(mode: Mode) -> String:
	match mode:
		Mode.PLAY: return "PLAY"
		Mode.BUILD: return "BUILD"
		Mode.EDITOR: return "EDITOR"
	return "UNKNOWN"

## Get current mode name
func get_mode_name() -> String:
	return _get_mode_name(current_mode)

## Route input to appropriate handlers
func _route_input(event: InputEvent) -> void:
	match current_mode:
		Mode.PLAY:
			_handle_play_input(event)
		Mode.BUILD:
			_handle_build_input(event)
		Mode.EDITOR:
			_handle_editor_input(event)

## Route physics process
func _route_process(_delta: float) -> void:
	match current_mode:
		Mode.PLAY:
			pass  # Handled by individual features
		Mode.BUILD:
			pass
		Mode.EDITOR:
			pass

## Handle PLAY mode input
func _handle_play_input(event: InputEvent) -> void:
	# LMB - Primary action (attack/use)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var inventory = player.get_feature("inventory")
		var combat = player.get_feature("combat")
		
		if inventory and combat:
			var item = inventory.get_selected_item_dict()
			combat.handle_primary_action(item)
	
	# RMB - Secondary action (place/alt use)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var inventory = player.get_feature("inventory")
		if inventory:
			var item = inventory.get_selected_item_dict()
			_handle_secondary_action(item)
	
	# G - Drop item
	if event is InputEventKey and event.pressed and event.keycode == KEY_G:
		_drop_selected_item()

## Handle secondary action (RMB)
func _handle_secondary_action(item: Dictionary) -> void:
	var category = item.get("category", 0)
	
	# Resource placement
	if category == 3:  # RESOURCE
		_place_resource(item)

## Place a resource
func _place_resource(item: Dictionary) -> void:
	var hit = player.raycast(5.0, 0xFFFFFFFF, false, true)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var mat_id = item.get("material_id", -1)
	
	if mat_id < 0:
		return
	
	if player.terrain_manager and player.terrain_manager.has_method("modify_terrain"):
		var center = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
		player.terrain_manager.modify_terrain(center, 0.6, -0.5, 1, 0, mat_id)
		
		var inventory = player.get_feature("inventory")
		if inventory:
			inventory.consume_selected(1)

## Drop selected item
func _drop_selected_item() -> void:
	var inventory = player.get_feature("inventory")
	if not inventory:
		return
	
	var item = inventory.get_selected_item_dict()
	if item.get("id", "fists") == "fists":
		return
	
	var slot = inventory.get_selected_index()
	var count = item.get("count", 1)
	
	# Clear slot
	inventory.clear_slot(slot)
	
	# Spawn pickup
	var drop_pos = player.global_position + player.get_look_direction() * 1.5 + Vector3.UP * 0.5
	_spawn_pickup(item, count, drop_pos)

## Spawn a pickup in the world
func _spawn_pickup(item: Dictionary, count: int, pos: Vector3) -> void:
	# Check for physics scene
	var scene_path = item.get("scene", "")
	if not scene_path.is_empty():
		var scene = load(scene_path)
		if scene:
			var instance = scene.instantiate()
			if instance is RigidBody3D:
				player.get_tree().root.add_child(instance)
				instance.global_position = pos
				instance.set_meta("item_data", item.duplicate())
				if not instance.is_in_group("interactable"):
					instance.add_to_group("interactable")
				instance.linear_velocity = player.get_look_direction() * 3.0 + Vector3.UP * 2.0
				return
			else:
				instance.queue_free()
	
	# Use PickupItem wrapper
	var pickup_scene = load("res://modules/world_player_v2/pickups/pickup_item.tscn")
	if pickup_scene:
		var pickup = pickup_scene.instantiate()
		player.get_tree().root.add_child(pickup)
		pickup.global_position = pos
		if pickup.has_method("set_item"):
			pickup.set_item(item, count)
		pickup.linear_velocity = player.get_look_direction() * 3.0 + Vector3.UP * 2.0

## Handle BUILD mode input
func _handle_build_input(event: InputEvent) -> void:
	# TODO: Building placement
	pass

## Handle EDITOR mode input
func _handle_editor_input(event: InputEvent) -> void:
	# TODO: Terrain editing
	pass
