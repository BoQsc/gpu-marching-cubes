extends Node
class_name BuildingAPIV2
## BuildingAPIV2 - High-level API for building operations in BUILD mode

var building_manager: Node = null
var terrain_manager: Node = null
var player: Node = null

# Building settings
var preview_enabled: bool = false
var preview_object_id: int = -1
var preview_rotation: int = 0
var preview_instance: Node = null
var preview_position: Vector3 = Vector3.ZERO
var can_place: bool = false

# Block mode
var block_material: int = 1

func _ready() -> void:
	building_manager = get_tree().get_first_node_in_group("building_manager")
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")

## Set player reference
func set_player(p: Node) -> void:
	player = p

## Enable preview for object
func enable_preview(object_id: int) -> void:
	if not building_manager:
		return
	
	preview_enabled = true
	preview_object_id = object_id
	preview_rotation = 0
	
	# Create preview instance
	_create_preview()

## Disable preview
func disable_preview() -> void:
	preview_enabled = false
	preview_object_id = -1
	if preview_instance and is_instance_valid(preview_instance):
		preview_instance.queue_free()
		preview_instance = null

## Create preview mesh
func _create_preview() -> void:
	if preview_instance and is_instance_valid(preview_instance):
		preview_instance.queue_free()
	
	if preview_object_id < 0:
		return
	
	var obj_def = ObjectRegistry.get_object(preview_object_id) if ObjectRegistry else null
	if not obj_def or not obj_def.has("scene"):
		return
	
	var scene = load(obj_def["scene"])
	if scene:
		preview_instance = scene.instantiate()
		get_tree().root.add_child(preview_instance)
		
		# Make transparent
		_set_preview_transparency(preview_instance, 0.5)
		
		# Disable collisions
		_disable_collisions(preview_instance)

## Update preview position
func update_preview() -> void:
	if not preview_enabled or not preview_instance or not player:
		return
	
	# Raycast to find placement position
	var hit = player.raycast(10.0, 0xFFFFFFFF, false, true)
	
	if hit:
		preview_position = hit.get("position", Vector3.ZERO) + hit.get("normal", Vector3.UP) * 0.1
		preview_instance.global_position = preview_position
		preview_instance.rotation.y = preview_rotation * TAU / 4.0
		
		can_place = _check_can_place(preview_position)
		
		# Color based on placement validity
		if can_place:
			_set_preview_color(preview_instance, Color(0.5, 1.0, 0.5, 0.5))
		else:
			_set_preview_color(preview_instance, Color(1.0, 0.5, 0.5, 0.5))
	else:
		can_place = false

## Rotate preview
func rotate_preview() -> void:
	preview_rotation = (preview_rotation + 1) % 4
	if preview_instance:
		preview_instance.rotation.y = preview_rotation * TAU / 4.0

## Place object at preview position
func place_object() -> bool:
	if not can_place or not building_manager or preview_object_id < 0:
		return false
	
	if building_manager.has_method("place_object"):
		building_manager.place_object(preview_object_id, preview_position, preview_rotation)
		DebugSettings.log_player("BuildingAPIV2: Placed object %d at %s" % [preview_object_id, preview_position])
		return true
	
	return false

## Place block at position
func place_block(position: Vector3, material: int = -1) -> bool:
	if not building_manager:
		return false
	
	var mat = material if material >= 0 else block_material
	var block_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
	
	if building_manager.has_method("set_voxel"):
		building_manager.set_voxel(block_pos, mat)
		return true
	
	return false

## Remove block at position
func remove_block(position: Vector3) -> bool:
	if not building_manager:
		return false
	
	var block_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
	
	if building_manager.has_method("set_voxel"):
		building_manager.set_voxel(block_pos, 0)
		return true
	
	return false

## Check if placement is valid
func _check_can_place(pos: Vector3) -> bool:
	# Basic check - not inside terrain
	if terrain_manager and terrain_manager.has_method("get_density"):
		if terrain_manager.get_density(pos) > 0:
			return false
	return true

## Set transparency on node and children
func _set_preview_transparency(node: Node, alpha: float) -> void:
	if node is MeshInstance3D:
		var mat = StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1, 1, 1, alpha)
		node.material_override = mat
	for child in node.get_children():
		_set_preview_transparency(child, alpha)

## Set preview color
func _set_preview_color(node: Node, color: Color) -> void:
	if node is MeshInstance3D and node.material_override:
		node.material_override.albedo_color = color
	for child in node.get_children():
		_set_preview_color(child, color)

## Disable collisions on node tree
func _disable_collisions(node: Node) -> void:
	for child in node.get_children():
		if child is CollisionShape3D:
			child.disabled = true
		elif child is CollisionPolygon3D:
			child.disabled = true
		_disable_collisions(child)

## Set block material
func set_block_material(material_id: int) -> void:
	block_material = material_id
