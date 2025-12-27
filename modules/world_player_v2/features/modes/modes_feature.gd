extends "res://modules/world_player_v2/features/feature_base.gd"
class_name ModesFeatureV2
## ModesFeature - Thin layer for mode switching and routing
## Routes input to appropriate features based on current mode

enum Mode { PLAY, BUILD, EDITOR }

var current_mode: Mode = Mode.PLAY
var editor_submode: int = 0

const EDITOR_SUBMODE_NAMES = ["Terrain", "Water", "Road", "Prefab", "Fly", "OldDirt"]

# Selection box for resource/bucket targeting
var selection_box: MeshInstance3D = null
var current_target_pos: Vector3i = Vector3i.ZERO

func _input(event: InputEvent) -> void:
	if not player:
		return
	
	# Mode switching with Tab
	if event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		_cycle_mode()
	
	# Editor submode with Q
	if event is InputEventKey and event.pressed and event.keycode == KEY_Q:
		if current_mode == Mode.EDITOR:
			_cycle_editor_submode()
	
	# Route input to current mode
	_route_input(event)

func _physics_process(delta: float) -> void:
	_route_process(delta)

## Cycle through modes
func _cycle_mode() -> void:
	var old_mode = current_mode
	current_mode = (current_mode + 1) % 3 as Mode
	
	var old_name = _get_mode_name(old_mode)
	var new_name = _get_mode_name(current_mode)
	
	PlayerSignalsV2.mode_changed.emit(old_name, new_name)
	DebugSettings.log_player("ModesV2: Changed from %s to %s" % [old_name, new_name])

## Cycle editor submodes
func _cycle_editor_submode() -> void:
	editor_submode = (editor_submode + 1) % EDITOR_SUBMODE_NAMES.size()
	PlayerSignalsV2.editor_submode_changed.emit(editor_submode, EDITOR_SUBMODE_NAMES[editor_submode])

## Get mode name
func _get_mode_name(mode: Mode) -> String:
	match mode:
		Mode.PLAY: return "PLAY"
		Mode.BUILD: return "BUILD"
		Mode.EDITOR: return "EDITOR"
	return "UNKNOWN"

## Get current mode name
func get_mode_name() -> String:
	return _get_mode_name(current_mode)

## Route input to appropriate handlers
func _route_input(event: InputEvent) -> void:
	match current_mode:
		Mode.PLAY:
			_handle_play_input(event)
		Mode.BUILD:
			_handle_build_input(event)
		Mode.EDITOR:
			_handle_editor_input(event)

## Route physics process
func _route_process(delta: float) -> void:
	match current_mode:
		Mode.PLAY:
			_update_terrain_targeting()
			_update_target_material()
		Mode.BUILD:
			pass
		Mode.EDITOR:
			pass

## Create selection box mesh
func _create_selection_box() -> void:
	if selection_box:
		return
	
	selection_box = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(1.01, 1.01, 1.01)
	selection_box.mesh = box_mesh
	
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(1, 1, 1, 0.3)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	selection_box.material_override = material
	
	selection_box.visible = false
	player.get_tree().root.add_child(selection_box)

## Update terrain targeting for resource/bucket items
func _update_terrain_targeting() -> void:
	if not player:
		return
	
	var inventory = player.get_feature("inventory")
	if not inventory:
		if selection_box:
			selection_box.visible = false
		return
	
	# Only show when in PLAY mode with RESOURCE or BUCKET selected
	var item = inventory.get_selected_item_dict()
	var category = item.get("category", 0)
	
	# Categories: 2=BUCKET, 3=RESOURCE
	if category != 2 and category != 3:
		if selection_box:
			selection_box.visible = false
		return
	
	# Create selection box if needed
	if not selection_box:
		_create_selection_box()
	
	# Raycast to find target
	var hit = player.raycast(5.0, 0xFFFFFFFF, false, true)
	if hit.is_empty():
		selection_box.visible = false
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var normal = hit.get("normal", Vector3.UP)
	
	# Calculate block position based on action
	if category == 3:  # RESOURCE - place on surface
		current_target_pos = Vector3i(floor(position.x + normal.x * 0.5), floor(position.y + normal.y * 0.5), floor(position.z + normal.z * 0.5))
	else:  # BUCKET - target existing block
		current_target_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
	
	# Update selection box position
	selection_box.global_position = Vector3(current_target_pos) + Vector3(0.5, 0.5, 0.5)
	selection_box.visible = true

## Handle PLAY mode input
func _handle_play_input(event: InputEvent) -> void:
	# LMB - Primary action (attack/use)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var inventory = player.get_feature("inventory")
		var combat = player.get_feature("combat")
		
		if inventory and combat:
			var item = inventory.get_selected_item_dict()
			combat.handle_primary_action(item)
	
	# RMB - Secondary action (place/alt use)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var inventory = player.get_feature("inventory")
		if inventory:
			var item = inventory.get_selected_item_dict()
			_handle_secondary_action(item)
	
	# G - Drop item
	if event is InputEventKey and event.pressed and event.keycode == KEY_G:
		_drop_selected_item()

## Handle secondary action (RMB)
func _handle_secondary_action(item: Dictionary) -> void:
	var category = item.get("category", 0)
	
	# Resource placement
	if category == 3:  # RESOURCE
		_do_resource_place(item)

## Place resource (terrain material) - paints voxel with resource's material ID
## Also handles vegetation resource placement (fiber -> grass, rock -> rock)
func _do_resource_place(item: Dictionary) -> void:
	if not player:
		return
	
	var item_id = item.get("id", "")
	
	# Check if this is a vegetation resource
	if item_id == "veg_fiber":
		_do_vegetation_place("grass")
		return
	elif item_id == "veg_rock":
		_do_vegetation_place("rock")
		return
	
	# Otherwise it's a terrain resource - need terrain_manager
	if not player.terrain_manager:
		return
	
	# Get material ID from resource item (legacy: 100=Grass, 101=Stone, 102=Sand, 103=Snow)
	# Item definitions use mat_id field (0=Grass, 1=Sand, etc) - need to check both formats
	var mat_id = item.get("mat_id", -1)
	DebugSettings.log_player("ModesV2: _do_resource_place item=%s mat_id_raw=%d" % [item, mat_id])
	if mat_id < 0:
		# Fallback: check if it has a material_id field
		mat_id = item.get("material_id", 0)
		DebugSettings.log_player("ModesV2: Fallback to material_id field, mat_id=%d" % mat_id)
	
	# CRITICAL: Add 100 offset for player-placed materials!
	# The terrain shader only skips biome blending for mat_id >= 100
	if mat_id < 100:
		mat_id += 100
		DebugSettings.log_player("ModesV2: Converted to player-placed mat_id=%d" % mat_id)
	
	# Use grid-aligned position if targeting is active
	if selection_box and selection_box.visible:
		var center = Vector3(current_target_pos) + Vector3(0.5, 0.5, 0.5)
		# Fixed 0.6 brush size, box shape (1), terrain layer (0), with mat_id
		player.terrain_manager.modify_terrain(center, 0.6, -0.5, 1, 0, mat_id)
		_consume_selected_item()
		DebugSettings.log_player("ModesV2: Placed %s (mat:%d) at %s" % [item.get("name", "resource"), mat_id, current_target_pos])
	else:
		var hit = player.raycast(5.0)
		if hit.is_empty():
			return
		# Target voxel outside terrain
		var p = hit.get("position", Vector3.ZERO) + hit.get("normal", Vector3.UP) * 0.1
		var target_pos = Vector3(floor(p.x), floor(p.y), floor(p.z)) + Vector3(0.5, 0.5, 0.5)
		player.terrain_manager.modify_terrain(target_pos, 0.6, -0.5, 1, 0, mat_id)
		_consume_selected_item()
		DebugSettings.log_player("ModesV2: Placed %s (mat:%d) at %s" % [item.get("name", "resource"), mat_id, target_pos])

## Consume selected item
func _consume_selected_item() -> void:
	var inventory = player.get_feature("inventory")
	if inventory:
		inventory.consume_selected(1)

## Drop selected item
func _drop_selected_item() -> void:
	var inventory = player.get_feature("inventory")
	if not inventory:
		return
	
	var item = inventory.get_selected_item_dict()
	if item.get("id", "fists") == "fists":
		return
	
	var slot = inventory.get_selected_index()
	var count = item.get("count", 1)
	
	# Clear slot
	inventory.clear_slot(slot)
	
	# Spawn pickup
	var drop_pos = player.global_position + player.get_look_direction() * 1.5 + Vector3.UP * 0.5
	_spawn_pickup(item, count, drop_pos)

## Spawn a pickup in the world
func _spawn_pickup(item: Dictionary, count: int, pos: Vector3) -> void:
	# Check for physics scene
	var scene_path = item.get("scene", "")
	if not scene_path.is_empty():
		var scene = load(scene_path)
		if scene:
			var instance = scene.instantiate()
			if instance is RigidBody3D:
				player.get_tree().root.add_child(instance)
				instance.global_position = pos
				instance.set_meta("item_data", item.duplicate())
				if not instance.is_in_group("interactable"):
					instance.add_to_group("interactable")
				instance.linear_velocity = player.get_look_direction() * 3.0 + Vector3.UP * 2.0
				return
			else:
				instance.queue_free()
	
	# Use PickupItem wrapper
	var pickup_scene = load("res://modules/world_player_v2/pickups/pickup_item.tscn")
	if pickup_scene:
		var pickup = pickup_scene.instantiate()
		player.get_tree().root.add_child(pickup)
		pickup.global_position = pos
		if pickup.has_method("set_item"):
			pickup.set_item(item, count)
		pickup.linear_velocity = player.get_look_direction() * 3.0 + Vector3.UP * 2.0

## Handle BUILD mode input
func _handle_build_input(event: InputEvent) -> void:
	# TODO: Building placement
	pass

## Handle EDITOR mode input
func _handle_editor_input(event: InputEvent) -> void:
	# TODO: Terrain editing
	pass

# Material names for display
const MATERIAL_NAMES = {
	0: "Grass", 1: "Stone", 2: "Sand", 3: "Snow",
	6: "Road", 9: "Granite",
	100: "[P] Grass", 101: "[P] Stone", 102: "[P] Sand", 103: "[P] Snow"
}
var last_target_material: String = ""
var material_target_marker: MeshInstance3D = null
var mat_debug_on_click: bool = false

## Create debug marker for material target visualization
func _create_material_target_marker() -> void:
	material_target_marker = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.15
	sphere.height = 0.3
	material_target_marker.mesh = sphere
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 0.3, 0.1, 1.0)  # Orange-red
	material_target_marker.material_override = mat
	material_target_marker.visible = false
	
	player.get_tree().root.add_child.call_deferred(material_target_marker)

## Update target material display in HUD
func _update_target_material() -> void:
	if not player:
		return
	
	var hit = player.raycast(10.0, 0xFFFFFFFF, false, true)  # Long range, exclude water
	if hit.is_empty():
		if material_target_marker:
			material_target_marker.visible = false
		if last_target_material != "":
			last_target_material = ""
			PlayerSignalsV2.target_material_changed.emit("")
		return
	
	var target = hit.get("collider")
	var hit_pos = hit.get("position", Vector3.ZERO)
	var hit_normal = hit.get("normal", Vector3.UP)
	var material_name = ""
	
	# Update marker position
	if material_target_marker:
		material_target_marker.global_position = hit_pos
		material_target_marker.visible = true
	
	# Check if we hit terrain (StaticBody3D in 'terrain' group)
	if target and target.is_in_group("terrain"):
		# Try to get material from mesh vertex color (most accurate)
		var mat_id = _get_material_from_mesh(target, hit_pos)
		
		# Fallback to buffer sampling if mesh reading failed
		if mat_id < 0:
			var sample_pos = hit_pos - hit_normal * 0.1
			mat_id = _get_material_at(sample_pos)
		
		material_name = MATERIAL_NAMES.get(mat_id, "Unknown (%d)" % mat_id)
		
		# Debug logging (only when digging/clicking)
		if mat_debug_on_click:
			DebugSettings.log_player("[MAT_DEBUG] hit_pos=%.1f,%.1f,%.1f mat_id=%d (%s)" % [
				hit_pos.x, hit_pos.y, hit_pos.z, mat_id, material_name
			])
			mat_debug_on_click = false
	elif target and target.is_in_group("building_chunks"):
		material_name = "Building Block"
	elif target and target.is_in_group("trees"):
		material_name = "Tree"
	elif target and target.is_in_group("placed_objects"):
		material_name = "Object"
	
	if material_name != last_target_material:
		last_target_material = material_name
		PlayerSignalsV2.target_material_changed.emit(material_name)

## Get material ID from mesh vertex color at hit point (100% accurate)
## Finds the exact triangle containing the hit point and interpolates vertex colors
## Returns -1 if unable to read from mesh
func _get_material_from_mesh(terrain_node: Node, hit_pos: Vector3) -> int:
	# Find the MeshInstance3D child of the terrain node
	var mesh_instance: MeshInstance3D = null
	for child in terrain_node.get_children():
		if child is MeshInstance3D:
			mesh_instance = child
			break
	
	if not mesh_instance or not mesh_instance.mesh:
		return -1
	
	var mesh = mesh_instance.mesh
	if not mesh is ArrayMesh:
		return -1
	
	# Get mesh data
	var arrays = mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return -1
	
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	var colors = arrays[Mesh.ARRAY_COLOR]
	
	if vertices.is_empty() or colors.is_empty():
		return -1
	
	# Convert hit position to local mesh space
	var local_pos = mesh_instance.global_transform.affine_inverse() * hit_pos
	
	# Find the triangle containing the hit point
	# Mesh is triangle list, so every 3 vertices form a triangle
	var best_mat_id = -1
	var best_dist = INF
	
	for i in range(0, vertices.size(), 3):
		if i + 2 >= vertices.size():
			break
		
		var v0 = vertices[i]
		var v1 = vertices[i + 1]
		var v2 = vertices[i + 2]
		
		# Check distance from point to triangle plane first (quick rejection)
		var tri_center = (v0 + v1 + v2) / 3.0
		var dist_to_center = local_pos.distance_squared_to(tri_center)
		
		# Only check triangles within reasonable distance
		if dist_to_center > 4.0:  # Skip triangles > 2 units away
			continue
		
		# Compute closest point on triangle to local_pos
		var closest_on_tri = _closest_point_on_triangle(local_pos, v0, v1, v2)
		var dist = local_pos.distance_squared_to(closest_on_tri)
		
		if dist < best_dist:
			best_dist = dist
			# Get barycentric coordinates for interpolation
			var bary = _barycentric(closest_on_tri, v0, v1, v2)
			var c0 = colors[i]
			var c1 = colors[i + 1]
			var c2 = colors[i + 2]
			# Interpolate color using barycentric weights
			var interp_color = c0 * bary.x + c1 * bary.y + c2 * bary.z
			best_mat_id = int(round(interp_color.r * 255.0))
	
	return best_mat_id

## Compute barycentric coordinates of point P in triangle (A, B, C)
func _barycentric(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 = b - a
	var v1 = c - a
	var v2 = p - a
	
	var d00 = v0.dot(v0)
	var d01 = v0.dot(v1)
	var d11 = v1.dot(v1)
	var d20 = v2.dot(v0)
	var d21 = v2.dot(v1)
	
	var denom = d00 * d11 - d01 * d01
	if abs(denom) < 0.00001:
		return Vector3(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)  # Degenerate - equal weights
	
	var v = (d11 * d20 - d01 * d21) / denom
	var w = (d00 * d21 - d01 * d20) / denom
	var u = 1.0 - v - w
	
	return Vector3(u, v, w)

## Find the closest point on a triangle to a given point
func _closest_point_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	# Check if P projects inside the triangle
	var ab = b - a
	var ac = c - a
	var ap = p - a
	
	var d1 = ab.dot(ap)
	var d2 = ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a  # Closest to vertex A
	
	var bp = p - b
	var d3 = ab.dot(bp)
	var d4 = ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b  # Closest to vertex B
	
	var vc = d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		var v = d1 / (d1 - d3)
		return a + ab * v  # Closest to edge AB
	
	var cp = p - c
	var d5 = ab.dot(cp)
	var d6 = ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c  # Closest to vertex C
	
	var vb = d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		var w = d2 / (d2 - d6)
		return a + ac * w  # Closest to edge AC
	
	var va = d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		var w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w  # Closest to edge BC
	
	# P projects inside the triangle
	var denom = 1.0 / (va + vb + vc)
	var v = vb * denom
	var w = vc * denom
	return a + ab * v + ac * w

## Get material ID at a given world position (fallback - uses terrain_manager's buffer lookup)
func _get_material_at(pos: Vector3) -> int:
	if player.terrain_manager and player.terrain_manager.has_method("get_material_at"):
		return player.terrain_manager.get_material_at(pos)
	return -1  # Unknown

## Collect water with bucket
func _do_bucket_collect(_item: Dictionary) -> void:
	if not player or not player.terrain_manager:
		return
	
	# Use EXACT same position calculation as placement
	if not selection_box or not selection_box.visible:
		return
	
	var center = Vector3(current_target_pos) + Vector3(0.5, 0.5, 0.5)
	player.terrain_manager.modify_terrain(center, 0.6, 0.5, 1, 1)  # Same as placement but positive value
	DebugSettings.log_player("ModesV2: Collected water at %s" % current_target_pos)
	# TODO: Switch bucket from empty to full

## Place water from bucket
func _do_bucket_place(_item: Dictionary) -> void:
	if not player or not player.terrain_manager:
		return
	
	# Use grid-aligned position if targeting is active
	if selection_box and selection_box.visible:
		var center = Vector3(current_target_pos) + Vector3(0.5, 0.5, 0.5)
		player.terrain_manager.modify_terrain(center, 0.6, -0.5, 1, 1)  # Box shape, fill, water layer
		DebugSettings.log_player("ModesV2: Placed water at %s" % current_target_pos)
	else:
		var hit = player.raycast(5.0)
		if hit.is_empty():
			return
		var pos = hit.get("position", Vector3.ZERO) + hit.get("normal", Vector3.UP) * 0.5
		player.terrain_manager.modify_terrain(pos, 0.6, -0.5, 1, 1)
		DebugSettings.log_player("ModesV2: Placed water at %s" % pos)
	# TODO: Switch bucket from full to empty

## Place vegetation (grass or rock)
func _do_vegetation_place(veg_type: String) -> void:
	if not player or not player.vegetation_manager:
		return
	
	var hit = player.raycast(5.0, 0xFFFFFFFF, false, true)
	if hit.is_empty():
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var normal = hit.get("normal", Vector3.UP)
	
	# Calculate spawn position on surface
	var spawn_pos = position + normal * 0.1
	
	if veg_type == "grass" and player.vegetation_manager.has_method("spawn_grass"):
		player.vegetation_manager.spawn_grass(spawn_pos)
		var inventory = player.get_feature("inventory")
		if inventory:
			inventory.consume_selected(1)
	elif veg_type == "rock" and player.vegetation_manager.has_method("spawn_rock"):
		player.vegetation_manager.spawn_rock(spawn_pos)
		var inventory = player.get_feature("inventory")
		if inventory:
			inventory.consume_selected(1)

## Get item data dictionary from a pickup target
func _get_item_data_from_pickup(target: Node) -> Dictionary:
	var name_lower = target.name.to_lower()
	
	# Pistol variants
	if "pistol" in name_lower:
		return ItemRegistryV2.get_item_dict("heavy_pistol")
	
	# Add more pickupable items here as needed
	# Example: if "shotgun" in name_lower: ...
	
	return {}
