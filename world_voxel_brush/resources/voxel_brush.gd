extends Resource
class_name VoxelBrush

## Shape types matching modify_density.glsl
enum ShapeType {
	SPHERE = 0,
	BOX = 1,
	COLUMN = 2
}

enum Mode {
	ADD = 0,      # Add Density (Dig/Air)
	SUBTRACT = 1, # Subtract Density (Place/Solid)
	PAINT = 2,    # Paint Material Only
	FLATTEN = 3,  # Flatten to target height
	SMOOTH = 4,   # Average with neighbors
	FLATTEN_FILL = 5 # Flatten (Fill Only)
}

@export_group("Tool Settings")
@export var display_name: String = "Brush"
@export var shape_type: ShapeType = ShapeType.SPHERE
@export var mode: Mode = Mode.ADD
@export var radius: float = 1.0
@export var strength: float = 10.0 ## Speed of modification (use 10.0 for instant)

@export_group("Targeting")
@export var snap_to_grid: bool = false
@export var raycast_distance: float = 3.5
@export var use_raycast_normal: bool = false ## If true, offsets target by normal (useful for placing ON faces)
@export var target_layer: int = 0 ## 0 = Terrain, 1 = Water

@export_group("Material")
@export var material_id: int = -1 ## -1 = Don't change material
