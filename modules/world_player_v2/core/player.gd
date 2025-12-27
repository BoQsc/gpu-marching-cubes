extends CharacterBody3D
class_name WorldPlayerV2
## WorldPlayerV2 - Main player coordinator script
## Thin coordinator that wires features together and provides external interface.
## Features handle their own logic; this script provides the glue.

# Component references (populated in _ready)
var camera_component: Node = null

# Feature references (populated by features during their _ready)
var features: Dictionary = {}  # id -> FeatureBase

# Manager references (found via groups)
var terrain_manager: Node = null
var building_manager: Node = null
var vegetation_manager: Node = null

func _ready() -> void:
	add_to_group("player")
	
	# Find camera component
	if has_node("Components/Camera"):
		camera_component = $Components/Camera
	
	# Find managers via groups
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	building_manager = get_tree().get_first_node_in_group("building_manager")
	vegetation_manager = get_tree().get_first_node_in_group("vegetation_manager")
	
	# Initialize all features
	_initialize_features()
	
	# Log initialization status
	DebugSettings.log_player("WorldPlayerV2: Initialized")
	DebugSettings.log_player("  - Camera: %s" % ("OK" if camera_component else "MISSING"))
	DebugSettings.log_player("  - TerrainManager: %s" % ("OK" if terrain_manager else "NOT FOUND"))
	DebugSettings.log_player("  - BuildingManager: %s" % ("OK" if building_manager else "NOT FOUND"))
	DebugSettings.log_player("  - VegetationManager: %s" % ("OK" if vegetation_manager else "NOT FOUND"))
	DebugSettings.log_player("  - Features: %d registered" % features.size())

## Initialize all features in the Features node
func _initialize_features() -> void:
	if not has_node("Features"):
		return
	
	for child in $Features.get_children():
		if child.has_method("initialize"):
			child.initialize(self)
		# Register with global FeatureRegistry
		var feature_id = child.name.to_lower()
		if FeatureRegistryV2:
			FeatureRegistryV2.register(child, feature_id)
		features[feature_id] = child

## Register a feature (called by features during their initialization)
func register_feature(id: String, feature: Node) -> void:
	features[id] = feature
	DebugSettings.log_player("WorldPlayerV2: Registered feature '%s'" % id)

## Get look direction from camera component
func get_look_direction() -> Vector3:
	if camera_component and camera_component.has_method("get_look_direction"):
		return camera_component.get_look_direction()
	return Vector3.FORWARD

## Get camera position from camera component
func get_camera_position() -> Vector3:
	if camera_component and camera_component.has_method("get_camera_position"):
		return camera_component.get_camera_position()
	return global_position + Vector3(0, 1.6, 0)

## Perform raycast from camera
func raycast(distance: float = 10.0, mask: int = 0xFFFFFFFF, collide_with_areas: bool = false, exclude_water: bool = false) -> Dictionary:
	if camera_component and camera_component.has_method("raycast"):
		return camera_component.raycast(distance, mask, collide_with_areas, exclude_water)
	return {}

## Take damage (delegates to PlayerStatsV2 autoload)
func take_damage(amount: int, source: Node = null) -> void:
	PlayerStatsV2.take_damage(amount, source)

## Heal (delegates to PlayerStatsV2 autoload)
func heal(amount: int) -> void:
	PlayerStatsV2.heal(amount)

## Get feature by ID
func get_feature(id: String) -> Node:
	return features.get(id)

## Save player state
func get_save_data() -> Dictionary:
	var data = {
		"position": global_position,
		"rotation": rotation,
		"stats": PlayerStatsV2.get_save_data()
	}
	
	# Collect from all features
	for id in features:
		var feature = features[id]
		if feature.has_method("get_save_data"):
			data[id] = feature.get_save_data()
	
	return data

## Load player state
func load_save_data(data: Dictionary) -> void:
	if data.has("position"):
		global_position = data["position"]
	if data.has("rotation"):
		rotation = data["rotation"]
	if data.has("stats"):
		PlayerStatsV2.load_save_data(data["stats"])
	
	# Distribute to all features
	for id in features:
		if data.has(id):
			var feature = features[id]
			if feature.has_method("load_save_data"):
				feature.load_save_data(data[id])
