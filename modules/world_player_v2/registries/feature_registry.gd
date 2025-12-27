extends Node
## FeatureRegistry - Manages all player features
## Provides centralized access to features and handles save/load coordination

var _features: Dictionary = {}  # String -> FeatureBase

func _ready() -> void:
	DebugSettings.log_player("FeatureRegistry: Initialized")

## Register a feature with the registry
func register(feature: Node, id: String) -> void:
	if not feature:
		push_error("FeatureRegistry: Cannot register null feature")
		return
	_features[id] = feature
	if feature.has_method("on_registered"):
		feature.on_registered()
	DebugSettings.log_player("FeatureRegistry: Registered '%s'" % id)

## Unregister a feature
func unregister(id: String) -> void:
	if _features.has(id):
		var feature = _features[id]
		if feature.has_method("on_unregistered"):
			feature.on_unregistered()
		_features.erase(id)
		DebugSettings.log_player("FeatureRegistry: Unregistered '%s'" % id)

## Get a feature by ID
func get_feature(id: String) -> Node:
	return _features.get(id)

## Check if a feature is registered
func has_feature(id: String) -> bool:
	return _features.has(id)

## Get all registered features
func get_all() -> Array:
	return _features.values()

## Get all feature IDs
func get_all_ids() -> Array[String]:
	var ids: Array[String] = []
	for key in _features.keys():
		ids.append(key)
	return ids

## Collect save data from all features
func collect_save_data() -> Dictionary:
	var data = {}
	for id in _features:
		var feature = _features[id]
		if feature.has_method("get_save_data"):
			data[id] = feature.get_save_data()
	return data

## Distribute save data to all features
func apply_save_data(data: Dictionary) -> void:
	for id in _features:
		if data.has(id):
			var feature = _features[id]
			if feature.has_method("load_save_data"):
				feature.load_save_data(data[id])
