extends "res://modules/world_player_v2/features/feature_base.gd"
class_name BuildFeatureV2
## BuildFeature - Handles BUILD mode behaviors (ported from mode_build.gd)
## Block, object, and prop placement/removal

# Item categories (matches V1)
const CATEGORY_BLOCK = 4
const CATEGORY_OBJECT = 5
const CATEGORY_PROP = 6

# Build state
var current_rotation: int = 0
var grid_snap_props: bool = false  # Toggle for prop placement

# Selection box for targeting
var selection_box: MeshInstance3D = null
var current_voxel_pos: Vector3i = Vector3i.ZERO
var has_target: bool = false

# Object preview
var preview_instance: Node3D = null
var current_object_id: int = 1
var current_block_id: int = 1

# Placement modes
enum PlacementMode { SURFACE, FILL, FLOATING }
var placement_mode: PlacementMode = PlacementMode.SURFACE
var y_offset: int = 0

# Options
var is_freestyle: bool = false
var smart_surface_align: bool = true
var object_show_grid: bool = false

func _ready() -> void:
	super._ready()
	_create_selection_box()

func _input(event: InputEvent) -> void:
	if not player:
		return
	
	var modes = player.get_feature("modes")
	if not modes or modes.current_mode != modes.Mode.BUILD:
		return
	
	# E key: Hold for freestyle placement
	if event is InputEventKey and event.keycode == KEY_E:
		if event.pressed and not event.is_echo():
			is_freestyle = true
			DebugSettings.log_player("BuildV2: Freestyle ON (E)")
		elif not event.pressed:
			is_freestyle = false
			DebugSettings.log_player("BuildV2: Freestyle OFF (E)")
	
	if event is InputEventKey and event.pressed and not event.is_echo():
		match event.keycode:
			KEY_R:
				# Rotate placement
				current_rotation = (current_rotation + 1) % 4
				DebugSettings.log_player("BuildV2: Rotation -> %d (%.0f°)" % [current_rotation, current_rotation * 90.0])
			KEY_G:
				# Toggle grid visibility
				var item = _get_current_item()
				if item.get("category", 0) == CATEGORY_OBJECT:
					object_show_grid = not object_show_grid
					DebugSettings.log_player("BuildV2: Object grid -> %s" % ("ON" if object_show_grid else "OFF"))
				else:
					grid_snap_props = not grid_snap_props
					DebugSettings.log_player("BuildV2: Grid snap -> %s" % ("ON" if grid_snap_props else "OFF"))
			KEY_V:
				# Cycle placement mode
				placement_mode = (placement_mode + 1) % 3 as PlacementMode
				var mode_names = ["SURFACE", "FILL", "FLOATING"]
				DebugSettings.log_player("BuildV2: Mode -> %s" % mode_names[placement_mode])
			KEY_Z:
				# Toggle smart surface align
				smart_surface_align = not smart_surface_align
				DebugSettings.log_player("BuildV2: Smart align -> %s" % ("ON" if smart_surface_align else "OFF"))
	
	# Scroll to rotate (Ctrl+Scroll) or adjust Y offset (Shift+Scroll)
	if event is InputEventMouseButton and event.pressed:
		if event.ctrl_pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				current_rotation = (current_rotation + 1) % 4
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				current_rotation = (current_rotation - 1 + 4) % 4
		elif event.shift_pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				y_offset += 1
				DebugSettings.log_player("BuildV2: Y offset -> %d" % y_offset)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				y_offset -= 1
				DebugSettings.log_player("BuildV2: Y offset -> %d" % y_offset)
	
	# MMB for freestyle toggle (continuous)
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			is_freestyle = event.pressed

func _physics_process(_delta: float) -> void:
	if not player:
		return
	
	var modes = player.get_feature("modes")
	if not modes or modes.current_mode != modes.Mode.BUILD:
		_hide_visuals()
		return
	
	_update_targeting()
	_update_preview()

## Create selection box mesh
func _create_selection_box() -> void:
	if selection_box:
		return
	
	selection_box = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.02, 1.02, 1.02)
	selection_box.mesh = box_mesh
	
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 0.8, 0.2, 0.3)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	selection_box.material_override = material
	
	selection_box.visible = false
	player.get_tree().root.add_child.call_deferred(selection_box)

## Update targeting based on raycast
func _update_targeting() -> void:
	var hit = player.raycast(10.0, 0xFFFFFFFF, false, true)
	
	if hit.is_empty():
		has_target = false
		if selection_box:
			selection_box.visible = false
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var normal = hit.get("normal", Vector3.UP)
	
	# Calculate voxel position based on placement mode
	match placement_mode:
		PlacementMode.SURFACE:
			var place_pos = position + normal * 0.5
			current_voxel_pos = Vector3i(floor(place_pos.x), floor(place_pos.y), floor(place_pos.z))
		PlacementMode.FILL:
			current_voxel_pos = Vector3i(floor(position.x - normal.x * 0.1), floor(position.y - normal.y * 0.1), floor(position.z - normal.z * 0.1))
		PlacementMode.FLOATING:
			var place_pos = position + normal * 0.5
			current_voxel_pos = Vector3i(floor(place_pos.x), floor(place_pos.y), floor(place_pos.z))
	
	# Apply Y offset
	current_voxel_pos.y += y_offset
	
	# Update selection box
	if selection_box:
		selection_box.global_position = Vector3(current_voxel_pos) + Vector3(0.5, 0.5, 0.5)
		selection_box.visible = true
	
	has_target = true

## Update preview for objects
func _update_preview() -> void:
	var item = _get_current_item()
	var category = item.get("category", 0)
	
	if category == CATEGORY_OBJECT:
		if not object_show_grid and selection_box:
			selection_box.visible = false
		current_object_id = item.get("object_id", 1)
		# TODO: Create/update preview mesh
	else:
		# For blocks/props, destroy preview
		if preview_instance and is_instance_valid(preview_instance):
			preview_instance.queue_free()
			preview_instance = null

## Hide visuals when not in build mode
func _hide_visuals() -> void:
	if selection_box:
		selection_box.visible = false
	if preview_instance and is_instance_valid(preview_instance):
		preview_instance.visible = false

## Handle primary action (left click) - Remove
func handle_primary(item: Dictionary) -> void:
	var category = item.get("category", 0)
	
	match category:
		CATEGORY_BLOCK:
			_do_block_remove()
		CATEGORY_OBJECT:
			_do_object_remove()
		CATEGORY_PROP:
			_do_prop_remove()

## Handle secondary action (right click) - Place
func handle_secondary(item: Dictionary) -> void:
	var category = item.get("category", 0)
	DebugSettings.log_player("BuildV2: handle_secondary category=%d item=%s" % [category, item.get("name", "?")])
	
	match category:
		CATEGORY_BLOCK:
			_do_block_place(item)
		CATEGORY_OBJECT:
			_do_object_place(item)
		CATEGORY_PROP:
			_do_prop_place(item)

## Get current item from inventory
func _get_current_item() -> Dictionary:
	var inventory = player.get_feature("inventory")
	if inventory:
		return inventory.get_selected_item_dict()
	return {}

## Remove block at target
func _do_block_remove() -> void:
	if not player or not player.building_manager:
		DebugSettings.log_player("BuildV2: Remove failed - no player or building_manager")
		return
	
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var target = hit.get("collider")
	if not target:
		return
	
	# Check if this is a building block
	var node = target
	var is_building_block: bool = false
	for i in 6:
		if not node:
			break
		if node == player.building_manager or "BuildingManager" in str(node):
			is_building_block = true
			break
		if node.is_in_group("building_chunks"):
			is_building_block = true
			break
		node = node.get_parent()
	
	if is_building_block:
		var position = hit.get("position", Vector3.ZERO) - hit.get("normal", Vector3.ZERO) * 0.1
		var voxel_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
		
		if player.building_manager.has_method("set_voxel"):
			player.building_manager.set_voxel(voxel_pos, 0)
			DebugSettings.log_player("BuildV2: Removed block at %s" % voxel_pos)
			PlayerSignalsV2.block_removed.emit(Vector3(voxel_pos))

## Place block at target
func _do_block_place(item: Dictionary) -> void:
	if not player or not player.building_manager:
		return
	
	if not has_target:
		return
	
	var block_id = item.get("block_id", 1)
	
	if player.building_manager.has_method("set_voxel"):
		player.building_manager.set_voxel(current_voxel_pos, block_id, current_rotation)
		DebugSettings.log_player("BuildV2: Placed %s at %s (rot: %d)" % [item.get("name", "block"), current_voxel_pos, current_rotation])
		PlayerSignalsV2.block_placed.emit(Vector3(current_voxel_pos), block_id, current_rotation)
		_consume_held_item()

## Remove object at target
func _do_object_remove() -> void:
	if not player or not player.building_manager:
		return
	
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var target = hit.get("collider")
	
	if target and target.is_in_group("placed_objects"):
		if target.has_meta("anchor") and target.has_meta("chunk"):
			var anchor = target.get_meta("anchor")
			var chunk = target.get_meta("chunk")
			if chunk and chunk.has_method("remove_object"):
				chunk.remove_object(anchor)
				DebugSettings.log_player("BuildV2: Removed object at %s" % anchor)
				return
	
	# Fallback: position-based removal
	if player.building_manager.has_method("remove_object_at"):
		var position = hit.get("position", Vector3.ZERO) - hit.get("normal", Vector3.ZERO) * 0.1
		var success = player.building_manager.remove_object_at(position)
		if success:
			DebugSettings.log_player("BuildV2: Removed object at %s" % position)

## Place object at target
func _do_object_place(item: Dictionary) -> void:
	if not player or not player.building_manager:
		return
	
	if not has_target:
		return
	
	var object_id = item.get("object_id", 1)
	
	# Calculate fractional Y position for proper terrain sitting
	var hit = player.raycast(10.0, 0xFFFFFFFF, false, true)
	var fractional_y = 0.0
	if not hit.is_empty():
		fractional_y = hit.get("position", Vector3.ZERO).y - floor(hit.get("position", Vector3.ZERO).y)
	
	var place_pos = Vector3(current_voxel_pos) + Vector3(0.5, fractional_y, 0.5)
	
	if player.building_manager.has_method("place_object"):
		var success = player.building_manager.place_object(place_pos, object_id, current_rotation)
		if success:
			DebugSettings.log_player("BuildV2: Placed %s (rot: %d)" % [item.get("name", "object"), current_rotation])
			PlayerSignalsV2.object_placed.emit(place_pos, object_id, current_rotation)
			_consume_held_item()
		else:
			DebugSettings.log_player("BuildV2: Cannot place object - cells occupied")

## Remove prop (same as object)
func _do_prop_remove() -> void:
	_do_object_remove()

## Place prop at target
func _do_prop_place(item: Dictionary) -> void:
	if not player or not player.building_manager:
		return
	
	var object_id = item.get("object_id", 1)
	
	# Use grid-aligned position when grid snap is on
	if grid_snap_props and has_target:
		var grid_pos = Vector3(current_voxel_pos) + Vector3(0.5, 0.0, 0.5)
		if player.building_manager.has_method("place_object"):
			var success = player.building_manager.place_object(grid_pos, object_id, current_rotation)
			if success:
				DebugSettings.log_player("BuildV2: Placed prop %s at %s (grid snap)" % [item.get("name", "prop"), grid_pos])
				_consume_held_item()
		return
	
	# Free placement: use raw raycast position
	var hit = player.raycast(10.0)
	if hit.is_empty():
		return
	
	var free_pos = hit.get("position", Vector3.ZERO)
	if player.building_manager.has_method("place_object"):
		var success = player.building_manager.place_object(free_pos, object_id, current_rotation)
		if success:
			DebugSettings.log_player("BuildV2: Placed prop %s at %s (free)" % [item.get("name", "prop"), free_pos])
			_consume_held_item()

## Get current rotation
func get_rotation() -> int:
	return current_rotation

## Set rotation
func set_rotation(rot: int) -> void:
	current_rotation = rot % 4

## Adjust Y offset
func adjust_y_offset(delta: int) -> void:
	y_offset += delta
	DebugSettings.log_player("BuildV2: Y offset -> %d" % y_offset)

## Cycle placement mode
func cycle_placement_mode() -> void:
	placement_mode = (placement_mode + 1) % 3 as PlacementMode
	var mode_names = ["SURFACE", "FILL", "FLOATING"]
	DebugSettings.log_player("BuildV2: Mode -> %s" % mode_names[placement_mode])

## Set freestyle mode
func set_freestyle(enabled: bool) -> void:
	is_freestyle = enabled

## Consume one item from hotbar
func _consume_held_item() -> void:
	var inventory = player.get_feature("inventory")
	if inventory:
		inventory.consume_selected(1)

## Save/Load
func get_save_data() -> Dictionary:
	return {
		"rotation": current_rotation,
		"placement_mode": placement_mode,
		"y_offset": y_offset,
		"grid_snap_props": grid_snap_props
	}

func load_save_data(data: Dictionary) -> void:
	current_rotation = data.get("rotation", 0)
	placement_mode = data.get("placement_mode", 0)
	y_offset = data.get("y_offset", 0)
	grid_snap_props = data.get("grid_snap_props", false)
