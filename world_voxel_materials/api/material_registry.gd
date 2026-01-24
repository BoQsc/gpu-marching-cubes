extends Node
class_name MaterialRegistry

## Central registry for all voxel materials.
## Replaces hardcoded dictionaries in Shovel/Interaction scripts.

const RESOURCE_PATH = "res://world_voxel_materials/resources/"

# Cache maps
static var _materials_by_id: Dictionary = {}
static var _materials_by_name: Dictionary = {} # Normalized lower-case name
static var _initialized: bool = false

static func _ensure_init() -> void:
	if _initialized: return
	
	# Load all .tres files from the resources folder
	var dir = DirAccess.open(RESOURCE_PATH)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if !dir.current_is_dir() and (file_name.ends_with(".tres") or file_name.ends_with(".res")):
				var mat = load(RESOURCE_PATH + file_name)
				if mat is VoxelMaterial:
					register_material(mat)
			file_name = dir.get_next()
	else:
		push_error("MaterialRegistry: Could not open resource path: " + RESOURCE_PATH)
	
	_initialized = true

static func register_material(mat: VoxelMaterial) -> void:
	_materials_by_id[mat.id] = mat
	_materials_by_name[mat.display_name.to_lower()] = mat

static func get_material(id: int) -> VoxelMaterial:
	_ensure_init()
	return _materials_by_id.get(id, null)

static func get_material_by_name(name: String) -> VoxelMaterial:
	_ensure_init()
	return _materials_by_name.get(name.to_lower(), null)

static func get_all_materials() -> Array[VoxelMaterial]:
	_ensure_init()
	var list: Array[VoxelMaterial] = []
	# Cast strict typed array
	for val in _materials_by_id.values():
		list.append(val)
	
	# Sort by ID
	list.sort_custom(func(a, b): return a.id < b.id)
	return list

static func get_material_name(id: int) -> String:
	var mat = get_material(id)
	if mat: return mat.display_name
	return "Unknown (%d)" % id
