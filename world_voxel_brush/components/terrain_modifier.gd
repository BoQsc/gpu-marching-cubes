extends Node
class_name TerrainModifier
## TerrainModifier - Handles safe application of VoxelBrushes to the terrain

@export var terrain_manager_group: String = "terrain_manager"

var _terrain_manager: Node = null

func _ready() -> void:
	call_deferred("_find_manager")

func _find_manager() -> void:
	_terrain_manager = get_tree().get_first_node_in_group(terrain_manager_group)
	if not _terrain_manager:
		push_warning("TerrainModifier: No terrain manager found in group %s" % terrain_manager_group)

## Apply a brush at a specific hit position/normal
## Returns true if successful
func apply_brush(brush: VoxelBrush, hit_position: Vector3, hit_normal: Vector3) -> bool:
	if not _terrain_manager:
		_find_manager()
		if not _terrain_manager: return false

	# 1. Calculate Target Position
	var target_pos = hit_position
	
	if brush.snap_to_grid:
		var offset = Vector3.ZERO
		# If placing (SUBTRACT) or using normal offset, push out/in
		if brush.use_raycast_normal:
			offset = hit_normal * 0.1
		
		var snapped = target_pos + offset
		# Center on voxel (0.5)
		target_pos = Vector3(floor(snapped.x) + 0.5, floor(snapped.y) + 0.5, floor(snapped.z) + 0.5)

	# 2. Calculate Strength (Density Delta)
	# Default convention: +Density = Air (Dig), -Density = Solid (Place)
	var final_strength = brush.strength
	
	if brush.mode == VoxelBrush.Mode.SUBTRACT: # Place/Solid
		final_strength = -abs(brush.strength)
	elif brush.mode == VoxelBrush.Mode.ADD: # Dig/Air
		final_strength = abs(brush.strength)
	
	# 3. Apply
	# Signature: modify_terrain(pos, radius, value, shape, layer, material_id)
	_terrain_manager.modify_terrain(
		target_pos, 
		brush.radius, 
		final_strength, 
		int(brush.shape_type), 
		brush.target_layer,
		brush.material_id
	)
	
	return true

## Helper to calculate where a brush would apply (useful for UI/Cursor)
func get_target_position(brush: VoxelBrush, hit_position: Vector3, hit_normal: Vector3) -> Vector3:
	var target_pos = hit_position
	
	if brush.snap_to_grid:
		var offset = Vector3.ZERO
		# If placing (SUBTRACT) or using normal offset, push out/in
		if brush.use_raycast_normal:
			offset = hit_normal * 0.1
		
		var snapped = target_pos + offset
		# Center on voxel (0.5)
		target_pos = Vector3(floor(snapped.x) + 0.5, floor(snapped.y) + 0.5, floor(snapped.z) + 0.5)
		
	return target_pos
