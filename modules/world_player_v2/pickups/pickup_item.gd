extends RigidBody3D
class_name PickupItemV2
## PickupItemV2 - Physics-based pickup that can be collected
## Replaces v1's pickup_item.gd with cleaner implementation

signal collected(item_data: Dictionary, count: int)

# Item data
var item_data: Dictionary = {}
var item_count: int = 1

# Visual
var mesh_instance: MeshInstance3D = null

# Collection
var can_collect: bool = false
var collect_delay: float = 0.5

func _ready() -> void:
	add_to_group("pickup_items")
	add_to_group("interactable")
	
	# Delay collection to prevent instant pickup
	await get_tree().create_timer(collect_delay).timeout
	can_collect = true

## Set the item this pickup represents
func set_item(data: Dictionary, count: int = 1) -> void:
	item_data = data.duplicate()
	item_count = count
	
	# Create visual representation
	_create_visual()

## Create visual for the item
func _create_visual() -> void:
	if mesh_instance:
		mesh_instance.queue_free()
	
	# Check for custom scene
	var scene_path = item_data.get("scene", "")
	if not scene_path.is_empty():
		var scene = load(scene_path)
		if scene:
			var instance = scene.instantiate()
			add_child(instance)
			if instance is RigidBody3D:
				# It's a physics prop - we need to extract the mesh
				for child in instance.get_children():
					if child is MeshInstance3D:
						var mesh_copy = child.duplicate()
						instance.remove_child(mesh_copy)
						add_child(mesh_copy)
						mesh_instance = mesh_copy
						break
				instance.queue_free()
			return
	
	# Create default cube mesh
	mesh_instance = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(0.3, 0.3, 0.3)
	mesh_instance.mesh = box
	
	# Color based on item
	var material = StandardMaterial3D.new()
	material.albedo_color = _get_color_for_item()
	mesh_instance.material_override = material
	
	add_child(mesh_instance)

## Get color for item type
func _get_color_for_item() -> Color:
	var id = item_data.get("id", "")
	match id:
		"dirt": return Color(0.4, 0.3, 0.2)
		"stone": return Color(0.5, 0.5, 0.5)
		"sand": return Color(0.9, 0.8, 0.6)
		"snow": return Color(0.95, 0.95, 1.0)
		"veg_wood": return Color(0.6, 0.4, 0.2)
		"veg_fiber": return Color(0.3, 0.6, 0.3)
		"veg_rock": return Color(0.4, 0.4, 0.4)
	return Color(0.7, 0.7, 0.7)

## Get item data
func get_item_data() -> Dictionary:
	var data = item_data.duplicate()
	data["count"] = item_count
	return data

## Collect this item (called by interaction feature)
func collect(collector: Node) -> bool:
	if not can_collect:
		return false
	
	collected.emit(item_data, item_count)
	
	DebugSettings.log_player("PickupV2: Collected %s x%d" % [item_data.get("id", "unknown"), item_count])
	
	queue_free()
	return true
