extends RefCounted
class_name TerrainView

# Signals
signal chunk_node_created(coord: Vector3i, node: Node3D)

# Dependencies
var material_terrain: Material
var material_water: Material
var parent_node: Node3D

# Settings
var min_finalization_interval_ms: int = 100
var initial_load_phase: bool = true

# State
var last_finalization_time_ms: int = 0
var pending_nodes: Array[Dictionary] = []
var pending_nodes_mutex: Mutex
var loading_paused: bool = false # Controlled by Loader

# Constants
const CHUNK_STRIDE = 31
const DENSITY_GRID_SIZE = 33

# State for TerrainGrid
var active_chunks: Dictionary # Reference to manager's dictionary

func _init(p_parent: Node3D, p_mat_terrain: Material, p_mat_water: Material, p_chunks: Dictionary):
	parent_node = p_parent
	material_terrain = p_mat_terrain
	material_water = p_mat_water
	active_chunks = p_chunks
	pending_nodes_mutex = Mutex.new()

# ============================================================================
# PUBLIC API
# ============================================================================

func queue_chunk_finalization(item: Dictionary):
	pending_nodes_mutex.lock()
	pending_nodes.append(item)
	pending_nodes_mutex.unlock()

func process_pending_nodes(viewer_pos: Vector3):
	if pending_nodes.is_empty():
		return
	
	if loading_paused:
		return
	
	# Time-distributed
	var current_time = Time.get_ticks_msec()
	var time_since_last = current_time - last_finalization_time_ms
	
	var effective_interval = 50 if initial_load_phase else min_finalization_interval_ms
	
	if time_since_last < effective_interval:
		return
	
	pending_nodes_mutex.lock()
	if pending_nodes.is_empty():
		pending_nodes_mutex.unlock()
		return
	
	# Sort by distance
	if pending_nodes.size() > 1:
		var viewer_chunk = Vector3i(
			int(floor(viewer_pos.x / CHUNK_STRIDE)),
			int(floor(viewer_pos.y / CHUNK_STRIDE)),
			int(floor(viewer_pos.z / CHUNK_STRIDE))
		)
		pending_nodes.sort_custom(func(a, b):
			var dist_a = (a.coord - viewer_chunk).length_squared()
			var dist_b = (b.coord - viewer_chunk).length_squared()
			return dist_a < dist_b
		)
	
	var item = pending_nodes.pop_front()
	pending_nodes_mutex.unlock()
	
	_finalize_chunk_creation(item)
	last_finalization_time_ms = current_time

func get_pending_count() -> int:
	pending_nodes_mutex.lock()
	var c = pending_nodes.size()
	pending_nodes_mutex.unlock()
	return c

# ============================================================================
# INTERNAL LOGIC
# ============================================================================

func _finalize_chunk_creation(item: Dictionary):
	if item.type == "final_terrain":
		var coord = item.coord
		
		# Check if chunk was unloaded while waiting
		if not active_chunks.has(coord):
			if item.get("body_rid", RID()).is_valid():
				PhysicsServer3D.free_rid(item.body_rid)
			return
			
		var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
		
		# Create Material
		var chunk_material = _create_chunk_material(chunk_pos, item.get("cpu_mat", PackedByteArray()))
		
		# Create Node (VISUALS ONLY)
		var result = create_chunk_node(item.result.mesh, null, chunk_pos, false, chunk_material, true)
		
		# Update Data
		var data = active_chunks[coord]
		if data == null:
			# Should ideally be created by Loader, but safety check
			data = ChunkData.new()
			active_chunks[coord] = data
			
		data.node_terrain = result.node if not result.is_empty() else null
		
		# Link Physics
		var body_rid = item.get("body_rid", RID())
		if body_rid.is_valid() and data.node_terrain:
			PhysicsServer3D.body_attach_object_instance_id(body_rid, data.node_terrain.get_instance_id())
			data.body_rid_terrain = body_rid
		
		if item.result.get("shape"):
			data.terrain_shape = item.result.shape
			
		data.density_buffer_terrain = item.dens
		data.material_buffer_terrain = item.get("mat_buf", RID())
		data.cpu_density_terrain = item.cpu_dens
		data.chunk_material = chunk_material
		data.cpu_material_terrain = item.get("cpu_mat", PackedByteArray())
		
		chunk_node_created.emit(coord, data.node_terrain)
		
	elif item.type == "final_water":
		var coord = item.coord
		if not active_chunks.has(coord): return
		
		var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
		var result = create_chunk_node(item.result.mesh, item.result.shape, chunk_pos, true)
		
		var data = active_chunks[coord]
		if data == null:
			data = ChunkData.new()
			active_chunks[coord] = data
			
		data.node_water = result.node if not result.is_empty() else null
		data.density_buffer_water = item.dens
		data.cpu_density_water = item.cpu_dens

func create_chunk_node(mesh: ArrayMesh, shape: Shape3D, position: Vector3, is_water: bool = false, custom_material: Material = null, defer_collision: bool = false) -> Dictionary:
	if mesh == null:
		return {}
		
	var node: CollisionObject3D
	
	if is_water:
		node = Area3D.new()
		node.add_to_group("water")
		node.monitorable = true
		node.monitoring = false
	else:
		node = StaticBody3D.new()
		node.collision_layer = 1 | 512
		node.add_to_group("terrain")
		
	node.position = position
	
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = mesh
	
	if custom_material:
		mesh_instance.material_override = custom_material
	
	if is_water:
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		
	node.add_child(mesh_instance)
	
	var collision_shape = CollisionShape3D.new()
	if shape:
		collision_shape.shape = shape
	
	if not defer_collision:
		node.add_child(collision_shape)
	
	parent_node.add_child(node)
	
	return {"node": node, "collision_shape": collision_shape}

func _create_chunk_material(chunk_pos: Vector3, cpu_mat: PackedByteArray) -> ShaderMaterial:
	var mat = material_terrain.duplicate() as ShaderMaterial
	mat.set_shader_parameter("chunk_origin", chunk_pos)
	
	if cpu_mat.size() > 0:
		var tex3d = _create_material_texture_3d(cpu_mat)
		if tex3d:
			mat.set_shader_parameter("material_map", tex3d)
			mat.set_shader_parameter("has_material_map", true)
	
	return mat

func _create_material_texture_3d(cpu_mat: PackedByteArray) -> ImageTexture3D:
	if cpu_mat.size() < DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4:
		return null
	
	# GDExtension Path
	if ClassDB.class_exists("MeshBuilder"):
		var builder = ClassDB.instantiate("MeshBuilder")
		return builder.create_material_texture(cpu_mat, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE)

	# Slow Fallback
	var images: Array[Image] = []
	for z in range(DENSITY_GRID_SIZE):
		var img = Image.create(DENSITY_GRID_SIZE, DENSITY_GRID_SIZE, false, Image.FORMAT_R8)
		for y in range(DENSITY_GRID_SIZE):
			for x in range(DENSITY_GRID_SIZE):
				var index = x + (y * DENSITY_GRID_SIZE) + (z * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
				var byte_offset = index * 4
				var mat_id = cpu_mat[byte_offset] if byte_offset < cpu_mat.size() else 0
				img.set_pixel(x, y, Color(float(mat_id) / 255.0, 0, 0))
		images.append(img)
	
	var tex3d = ImageTexture3D.new()
	tex3d.create(Image.FORMAT_R8, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE, DENSITY_GRID_SIZE, false, images)
	return tex3d
