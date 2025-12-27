extends "res://modules/world_player_v2/features/feature_base.gd"
class_name EditorFeatureV2
## EditorFeature - Handles EDITOR mode behaviors (ported from mode_editor.gd)
## Terrain sculpting, water editing, roads, prefabs, fly mode

# Editor submodes (matches modes_feature.gd EDITOR_SUBMODE_NAMES)
const SUBMODE_TERRAIN = 0
const SUBMODE_WATER = 1
const SUBMODE_ROAD = 2
const SUBMODE_PREFAB = 3
const SUBMODE_FLY = 4
const SUBMODE_OLDDIRT = 5

# Editor state
var brush_size: float = 4.0
var brush_shape: int = 0  # 0=Sphere, 1=Box
var blocky_mode: bool = true

# Selection box for targeting
var selection_box: MeshInstance3D = null
var current_target_pos: Vector3 = Vector3.ZERO
var has_target: bool = false

# Fly mode state
var fly_speed: float = 15.0

# Road state
var is_placing_road: bool = false
var road_start_pos: Vector3 = Vector3.ZERO
var road_type: int = 1  # 1=Flatten, 2=Mask, 3=Normalize

# Prefab state
var available_prefabs: Array[String] = []
var current_prefab_index: int = 0
var prefab_rotation: int = 0

# Manager references
var road_manager: Node = null
var prefab_spawner: Node = null

func _ready() -> void:
	super._ready()
	_create_selection_box()
	_find_managers()
	_load_prefabs()

func _find_managers() -> void:
	await get_tree().process_frame
	road_manager = get_tree().get_first_node_in_group("road_manager")
	prefab_spawner = get_tree().get_first_node_in_group("prefab_spawner")
	if not prefab_spawner:
		prefab_spawner = get_tree().root.find_child("PrefabSpawner", true, false)

func _input(event: InputEvent) -> void:
	if not player:
		return
	
	var modes = player.get_feature("modes")
	if not modes or modes.current_mode != modes.Mode.EDITOR:
		return
	
	var submode = modes.editor_submode
	
	if event is InputEventKey and event.pressed and not event.is_echo():
		match event.keycode:
			KEY_G:
				# Toggle blocky mode (terrain/water)
				blocky_mode = not blocky_mode
				DebugSettings.log_player("EditorV2: Blocky mode -> %s" % ("ON" if blocky_mode else "OFF"))
			KEY_R:
				# Rotate prefab
				if submode == SUBMODE_PREFAB:
					prefab_rotation = (prefab_rotation + 1) % 4
					DebugSettings.log_player("EditorV2: Prefab rotation -> %d°" % (prefab_rotation * 90))
			KEY_BRACKETLEFT:
				# Previous prefab
				if submode == SUBMODE_PREFAB and available_prefabs.size() > 0:
					current_prefab_index = (current_prefab_index - 1 + available_prefabs.size()) % available_prefabs.size()
					DebugSettings.log_player("EditorV2: Prefab -> %s" % _get_current_prefab_name())
			KEY_BRACKETRIGHT:
				# Next prefab
				if submode == SUBMODE_PREFAB and available_prefabs.size() > 0:
					current_prefab_index = (current_prefab_index + 1) % available_prefabs.size()
					DebugSettings.log_player("EditorV2: Prefab -> %s" % _get_current_prefab_name())
	
	# Scroll to change brush size
	if event is InputEventMouseButton and event.pressed:
		if event.shift_pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				brush_size = min(brush_size + 0.5, 20.0)
				DebugSettings.log_player("EditorV2: Brush size -> %.1f" % brush_size)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				brush_size = max(brush_size - 0.5, 0.5)
				DebugSettings.log_player("EditorV2: Brush size -> %.1f" % brush_size)

func _physics_process(delta: float) -> void:
	if not player:
		return
	
	var modes = player.get_feature("modes")
	if not modes or modes.current_mode != modes.Mode.EDITOR:
		_hide_visuals()
		return
	
	var submode = modes.editor_submode
	
	# Update targeting for terrain/water modes
	if submode == SUBMODE_TERRAIN or submode == SUBMODE_WATER or submode == SUBMODE_OLDDIRT:
		_update_targeting()
	else:
		_hide_visuals()
	
	# Handle fly movement
	if submode == SUBMODE_FLY:
		_process_fly_movement(delta)

## Create selection box mesh
func _create_selection_box() -> void:
	if selection_box:
		return
	
	selection_box = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.02, 1.02, 1.02)
	selection_box.mesh = box_mesh
	
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.8, 0.2, 0.2, 0.3)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	selection_box.material_override = material
	
	selection_box.visible = false
	player.get_tree().root.add_child.call_deferred(selection_box)

## Update targeting based on raycast
func _update_targeting() -> void:
	var hit = player.raycast(100.0, 0xFFFFFFFF, false, true)
	
	if hit.is_empty():
		has_target = false
		if selection_box:
			selection_box.visible = false
		return
	
	current_target_pos = hit.get("position", Vector3.ZERO)
	has_target = true
	
	# Update selection box for blocky mode
	if blocky_mode and selection_box:
		var voxel_pos = Vector3(floor(current_target_pos.x) + 0.5, floor(current_target_pos.y) + 0.5, floor(current_target_pos.z) + 0.5)
		selection_box.global_position = voxel_pos
		selection_box.visible = true
	elif selection_box:
		selection_box.visible = false

## Hide visuals
func _hide_visuals() -> void:
	if selection_box:
		selection_box.visible = false

## Handle primary action (left click)
func handle_primary(_item: Dictionary) -> void:
	var modes = player.get_feature("modes")
	if not modes:
		return
	
	var submode = modes.editor_submode
	
	match submode:
		SUBMODE_TERRAIN:
			_do_terrain_dig()
		SUBMODE_WATER:
			_do_water_remove()
		SUBMODE_ROAD:
			_do_road_click()
		SUBMODE_PREFAB:
			pass  # No primary action for prefab
		SUBMODE_OLDDIRT:
			_do_legacy_dirt_dig()

## Handle secondary action (right click)
func handle_secondary(_item: Dictionary) -> void:
	var modes = player.get_feature("modes")
	if not modes:
		return
	
	var submode = modes.editor_submode
	
	match submode:
		SUBMODE_TERRAIN:
			_do_terrain_place()
		SUBMODE_WATER:
			_do_water_add()
		SUBMODE_ROAD:
			_do_road_click()
		SUBMODE_PREFAB:
			_do_prefab_place()
		SUBMODE_OLDDIRT:
			_do_legacy_dirt_place()

## Terrain sculpting - dig
func _do_terrain_dig() -> void:
	if not player or not player.terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var shape = brush_shape
	var size = brush_size if not blocky_mode else 0.6
	
	if blocky_mode:
		# Blocky dig - target voxel inside terrain
		position = position - hit.get("normal", Vector3.ZERO) * 0.1
		position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
		shape = 1  # Box
	
	player.terrain_manager.modify_terrain(position, size, 1.0, shape, 0)
	PlayerSignalsV2.terrain_modified.emit(position, 0)
	DebugSettings.log_player("EditorV2: Dug terrain at %s (size: %.1f, blocky: %s)" % [position, size, blocky_mode])

## Terrain sculpting - place
func _do_terrain_place() -> void:
	if not player or not player.terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var shape = brush_shape
	var size = brush_size if not blocky_mode else 0.6
	
	if blocky_mode:
		# Blocky place - target voxel outside terrain
		position = position + hit.get("normal", Vector3.ZERO) * 0.1
		position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
		shape = 1  # Box
	
	player.terrain_manager.modify_terrain(position, size, -1.0, shape, 0)
	PlayerSignalsV2.terrain_modified.emit(position, 0)
	DebugSettings.log_player("EditorV2: Placed terrain at %s" % position)

## Water editing - remove
func _do_water_remove() -> void:
	if not player or not player.terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	player.terrain_manager.modify_terrain(position, brush_size, 1.0, 0, 1)  # Layer 1 = water
	PlayerSignalsV2.terrain_modified.emit(position, 1)
	DebugSettings.log_player("EditorV2: Removed water at %s" % position)

## Water editing - add
func _do_water_add() -> void:
	if not player or not player.terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	player.terrain_manager.modify_terrain(position, brush_size, -1.0, 0, 1)
	PlayerSignalsV2.terrain_modified.emit(position, 1)
	DebugSettings.log_player("EditorV2: Added water at %s" % position)

## Road placement click
func _do_road_click() -> void:
	if not player or not road_manager:
		DebugSettings.log_player("EditorV2: Road manager not found")
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	
	if not is_placing_road:
		# Start road
		road_start_pos = position
		is_placing_road = true
		if road_manager.has_method("start_road"):
			road_manager.start_road(position, road_type)
		DebugSettings.log_player("EditorV2: Road start at %s (type: %d)" % [position, road_type])
	else:
		# End road
		if road_manager.has_method("end_road"):
			road_manager.end_road(position)
		DebugSettings.log_player("EditorV2: Road end at %s" % position)
		is_placing_road = false

## Prefab placement
func _do_prefab_place() -> void:
	if not player or not prefab_spawner:
		DebugSettings.log_player("EditorV2: Prefab spawner not found")
		return
	
	if available_prefabs.is_empty():
		DebugSettings.log_player("EditorV2: No prefabs available")
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var prefab_path = available_prefabs[current_prefab_index]
	
	if prefab_spawner.has_method("spawn_prefab"):
		prefab_spawner.spawn_prefab(prefab_path, position, prefab_rotation)
		DebugSettings.log_player("EditorV2: Placed prefab %s at %s (rot: %d°)" % [_get_current_prefab_name(), position, prefab_rotation * 90])

## Process fly movement
func _process_fly_movement(_delta: float) -> void:
	if not player:
		return
	
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var camera = player.get_node_or_null("Head/Camera3D")
	
	if not camera:
		camera = player.get_node_or_null("Camera3D")
	if not camera:
		return
	
	var cam_basis = camera.global_transform.basis
	var direction = (cam_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	player.velocity = Vector3.ZERO
	
	if direction:
		player.velocity = direction * fly_speed
	
	# Vertical movement
	if Input.is_action_pressed("ui_accept"):
		player.velocity.y = fly_speed
	if Input.is_key_pressed(KEY_SHIFT):
		player.velocity.y = -fly_speed
	
	player.move_and_slide()

## Load available prefabs from directory
func _load_prefabs() -> void:
	available_prefabs.clear()
	
	var prefab_dir = "res://prefabs/"
	var dir = DirAccess.open(prefab_dir)
	
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(".json"):
				available_prefabs.append(prefab_dir + file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
	
	DebugSettings.log_player("EditorV2: Loaded %d prefabs" % available_prefabs.size())

## Get current prefab filename
func _get_current_prefab_name() -> String:
	if available_prefabs.is_empty():
		return "None"
	return available_prefabs[current_prefab_index].get_file().get_basename()

## Legacy dirt - dig
func _do_legacy_dirt_dig() -> void:
	if not player or not player.terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	# Target voxel inside terrain
	position = position - hit.get("normal", Vector3.ZERO) * 0.1
	position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
	
	player.terrain_manager.modify_terrain(position, 0.6, 0.5, 1, 0)  # Box shape, dig, terrain layer
	PlayerSignalsV2.terrain_modified.emit(position, 0)
	DebugSettings.log_player("EditorV2: [OldDirt] Dug at %s" % position)

## Legacy dirt - place
func _do_legacy_dirt_place() -> void:
	if not player or not player.terrain_manager:
		return
	
	var hit = player.raycast(100.0)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	# Target voxel outside terrain
	position = position + hit.get("normal", Vector3.ZERO) * 0.1
	position = Vector3(floor(position.x) + 0.5, floor(position.y) + 0.5, floor(position.z) + 0.5)
	
	player.terrain_manager.modify_terrain(position, 0.6, -0.5, 1, 0)  # Box shape, fill, terrain layer
	PlayerSignalsV2.terrain_modified.emit(position, 0)
	DebugSettings.log_player("EditorV2: [OldDirt] Placed at %s" % position)

## Save/Load
func get_save_data() -> Dictionary:
	return {
		"brush_size": brush_size,
		"brush_shape": brush_shape,
		"blocky_mode": blocky_mode,
		"fly_speed": fly_speed,
		"prefab_index": current_prefab_index,
		"prefab_rotation": prefab_rotation
	}

func load_save_data(data: Dictionary) -> void:
	brush_size = data.get("brush_size", 4.0)
	brush_shape = data.get("brush_shape", 0)
	blocky_mode = data.get("blocky_mode", true)
	fly_speed = data.get("fly_speed", 15.0)
	current_prefab_index = data.get("prefab_index", 0)
	prefab_rotation = data.get("prefab_rotation", 0)
