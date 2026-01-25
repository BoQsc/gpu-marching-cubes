extends Node
class_name BrushRuntimeConfig

## Global runtime configuration for the Brush Editor
## Allows overriding tool behaviors with custom debug values

signal settings_changed

var override_enabled: bool = false
var radius: float = 2.0
var strength: float = 10.0
var shape_type: int = 0 # 0=Sphere, 1=Box, 2=Column
var mode: int = 0 # 0=Add(Dig), 1=Subtract(Place), 2=Paint
var snap_to_grid: bool = false
var material_id: int = -1

func set_radius(val: float) -> void:
	radius = val
	settings_changed.emit()

func set_strength(val: float) -> void:
	strength = val
	settings_changed.emit()

func set_shape(val: int) -> void:
	shape_type = val
	settings_changed.emit()

func set_mode(val: int) -> void:
	mode = val
	settings_changed.emit()

func set_snap(val: bool) -> void:
	snap_to_grid = val
	settings_changed.emit()

func set_material_id(val: int) -> void:
	material_id = val
	settings_changed.emit()
