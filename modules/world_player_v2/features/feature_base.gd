extends Node
class_name FeatureBase
## Base class for all player features in world_player_v2
## Features are self-contained modules that handle specific player functionality

## Reference to the player (set during initialization)
var player: Node = null

## Called when feature should save its state
func get_save_data() -> Dictionary:
	return {}

## Called when feature should load saved state
func load_save_data(_data: Dictionary) -> void:
	pass

## Called when feature is registered with FeatureRegistry
func on_registered() -> void:
	pass

## Called when feature is unregistered
func on_unregistered() -> void:
	pass

## Called to initialize the feature with player reference
func initialize(p: Node) -> void:
	player = p
	_on_initialize()

## Override this in subclasses for custom initialization
func _on_initialize() -> void:
	pass
