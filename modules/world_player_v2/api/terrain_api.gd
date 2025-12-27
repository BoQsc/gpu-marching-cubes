extends Node
class_name TerrainAPIV2
## TerrainAPIV2 - High-level API for terrain operations in EDITOR mode

var terrain_manager: Node = null
var player: Node = null

# Editor settings
var brush_radius: float = 1.0
var brush_strength: float = 0.5
var paint_material: int = 0

func _ready() -> void:
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")

## Set player reference
func set_player(p: Node) -> void:
	player = p

## Dig terrain at position
func dig(position: Vector3, radius: float = -1.0, strength: float = -1.0) -> void:
	if not terrain_manager or not terrain_manager.has_method("modify_terrain"):
		return
	
	var r = radius if radius > 0 else brush_radius
	var s = strength if strength > 0 else brush_strength
	
	terrain_manager.modify_terrain(position, r, s, 0, 0, -1)

## Build terrain at position
func build(position: Vector3, radius: float = -1.0, strength: float = -1.0, material: int = -1) -> void:
	if not terrain_manager or not terrain_manager.has_method("modify_terrain"):
		return
	
	var r = radius if radius > 0 else brush_radius
	var s = strength if strength > 0 else brush_strength
	var m = material if material >= 0 else paint_material
	
	# Negate strength to add terrain
	terrain_manager.modify_terrain(position, r, -s, 1, 0, m)

## Paint material at position
func paint(position: Vector3, radius: float = -1.0, material: int = -1) -> void:
	if not terrain_manager or not terrain_manager.has_method("modify_terrain"):
		return
	
	var r = radius if radius > 0 else brush_radius
	var m = material if material >= 0 else paint_material
	
	terrain_manager.modify_terrain(position, r, 0.0, 0, 1, m)

## Get material at position
func get_material_at(position: Vector3) -> int:
	if terrain_manager and terrain_manager.has_method("get_material_at"):
		return terrain_manager.get_material_at(position)
	return -1

## Get water density at position
func get_water_at(position: Vector3) -> float:
	if terrain_manager and terrain_manager.has_method("get_water_density"):
		return terrain_manager.get_water_density(position)
	return 0.0

## Set brush settings
func set_brush(radius: float, strength: float) -> void:
	brush_radius = radius
	brush_strength = strength

## Set paint material
func set_material(material_id: int) -> void:
	paint_material = material_id

## Flatten terrain at position
func flatten(position: Vector3, radius: float = -1.0, target_height: float = -999.0) -> void:
	if not terrain_manager:
		return
	
	var r = radius if radius > 0 else brush_radius
	var height = target_height if target_height > -999.0 else position.y
	
	# TODO: Implement proper flatten in terrain manager
	# For now, just smooth slightly
	if terrain_manager.has_method("modify_terrain"):
		terrain_manager.modify_terrain(position, r, 0.1, 0, 0, -1)

## Smooth terrain at position
func smooth(position: Vector3, radius: float = -1.0, strength: float = -1.0) -> void:
	# TODO: Implement proper smooth operation
	pass
