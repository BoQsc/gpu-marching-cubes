extends Resource
class_name VoxelMaterial

@export var id: int = -1
@export var display_name: String = "Unnamed Material"
@export var color: Color = Color.WHITE ## Used for debug/minimap
@export var icon: Texture2D
@export var physics_material: PhysicsMaterial
@export var input_key: Key = KEY_NONE ## Shortcut key for Shovel (e.g. KEY_1)
