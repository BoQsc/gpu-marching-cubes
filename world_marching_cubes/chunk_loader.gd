extends RefCounted
class_name ChunkLoader

# Dependencies
var voxel_engine: VoxelEngine
var viewer: Node3D

# Settings
var render_distance: int = 5
var chunks_per_frame_limit: int = 2
var initial_load_phase: bool = true
var loading_paused: bool = false

# State
var active_chunks: Dictionary # Reference
var stored_modifications: Dictionary # Reference
var pending_unloads: Array[Vector3i] = [] # Track unloads to process

# Native GDExtension Grid
var terrain_grid = null

# Constants
const CHUNK_STRIDE = 31
const MIN_Y_LAYER = -20
const MAX_Y_LAYER = 40

func _init(p_engine: VoxelEngine, p_chunks: Dictionary, p_mods: Dictionary):
	voxel_engine = p_engine
	active_chunks = p_chunks
	stored_modifications = p_mods
	
	if ClassDB.class_exists("TerrainGrid"):
		terrain_grid = ClassDB.instantiate("TerrainGrid")
		print("[ChunkLoader] TerrainGrid GDExtension active")

# ============================================================================
# MAIN LOOP
# ============================================================================

func update(viewer_pos: Vector3):
	if loading_paused:
		return

	if terrain_grid:
		_update_native(viewer_pos)
	else:
		_update_gdscript(viewer_pos)

func _update_native(p_pos: Vector3):
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE))
	var is_above_ground = p_chunk_y >= 0
	
	# Update Grid
	var result = terrain_grid.update(p_pos, render_distance, is_above_ground, CHUNK_STRIDE)
	
	# Process Unloads
	for coord in result["unload"]:
		_unload_chunk(coord)
		terrain_grid.remove_chunk(coord)
		
	# Process Loads
	var chunks_queued = 0
	for coord in result["load"]:
		if chunks_queued >= chunks_per_frame_limit:
			break
		if active_chunks.has(coord):
			continue
			
		_load_chunk(coord)
		terrain_grid.add_chunk(coord)
		chunks_queued += 1
		
	# Stored Modifications (Force Load)
	if chunks_queued < chunks_per_frame_limit and not initial_load_phase:
		for coord in stored_modifications:
			if chunks_queued >= chunks_per_frame_limit: break
			if active_chunks.has(coord): continue
			
			var chunk_origin = Vector3(coord.x * CHUNK_STRIDE, 0, coord.z * CHUNK_STRIDE)
			var dist_xz = Vector2(chunk_origin.x, chunk_origin.z).distance_to(Vector2(p_pos.x, p_pos.z))
			
			if dist_xz <= (render_distance * CHUNK_STRIDE):
				_load_chunk(coord)
				terrain_grid.add_chunk(coord)
				chunks_queued += 1

func _update_gdscript(p_pos: Vector3):
	var p_chunk_x = int(floor(p_pos.x / CHUNK_STRIDE))
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE))
	var p_chunk_z = int(floor(p_pos.z / CHUNK_STRIDE))
	var center_chunk = Vector3i(p_chunk_x, p_chunk_y, p_chunk_z)

	# 1. Unload
	var chunks_to_remove = []
	for coord in active_chunks:
		var is_terrain_layer = coord.y >= MIN_Y_LAYER and coord.y <= 1
		var dx = coord.x - center_chunk.x
		var dy = coord.y - center_chunk.y
		var dz = coord.z - center_chunk.z
		var dist_xz = sqrt(dx * dx + dz * dz)
		
		if dist_xz > render_distance + 2:
			chunks_to_remove.append(coord)
		elif not is_terrain_layer and abs(dy) > 3:
			chunks_to_remove.append(coord)
			
	for coord in chunks_to_remove:
		_unload_chunk(coord)

	# 2. Load
	var chunks_queued = 0
	var is_above_ground = center_chunk.y >= 0
	
	if is_above_ground:
		# Fast path: Y=0 only
		for x in range(center_chunk.x - render_distance, center_chunk.x + render_distance + 1):
			for z in range(center_chunk.z - render_distance, center_chunk.z + render_distance + 1):
				if chunks_queued >= chunks_per_frame_limit: return
				
				var dist_xz = Vector2(x, z).distance_to(Vector2(center_chunk.x, center_chunk.z))
				if dist_xz > render_distance: continue
				
				var coord = Vector3i(x, 0, z)
				if not active_chunks.has(coord):
					_load_chunk(coord)
					chunks_queued += 1
	else:
		# Underground: Load layers
		var y_layers = [center_chunk.y - 1, center_chunk.y, center_chunk.y + 1, 0]
		for x in range(center_chunk.x - render_distance, center_chunk.x + render_distance + 1):
			for z in range(center_chunk.z - render_distance, center_chunk.z + render_distance + 1):
				if chunks_queued >= chunks_per_frame_limit: return
				
				var dist_xz = Vector2(x, z).distance_to(Vector2(center_chunk.x, center_chunk.z))
				if dist_xz > render_distance: continue
				
				for y in y_layers:
					var coord = Vector3i(x, y, z)
					if not active_chunks.has(coord):
						_load_chunk(coord)
						chunks_queued += 1

func _load_chunk(coord: Vector3i):
	active_chunks[coord] = null # Mark pending
	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
	voxel_engine.queue_generation(coord, chunk_pos)

func _unload_chunk(coord: Vector3i):
	var data = active_chunks[coord]
	if data:
		# Free Visuals
		if data.node_terrain: data.node_terrain.queue_free()
		if data.node_water: data.node_water.queue_free()
		
		# Free Physics
		if data.body_rid_terrain.is_valid():
			PhysicsServer3D.free_rid(data.body_rid_terrain)
		
		# Free GPU Resources
		var rids = []
		if data.density_buffer_terrain.is_valid(): rids.append(data.density_buffer_terrain)
		if data.density_buffer_water.is_valid(): rids.append(data.density_buffer_water)
		voxel_engine.free_resources(rids)
	
	active_chunks.erase(coord)
	# Signal handled by Coordinator observing 'active_chunks' changes or explicit signal if needed

# ============================================================================
# DATA ACCESS API (Queries)
# ============================================================================

## Get terrain density at world position (reads from CPU-cached chunk data)
## Returns positive for air, negative for solid. Returns 1.0 if chunk not loaded.
func get_terrain_density(global_pos: Vector3) -> float:
	# Find Chunk (3D coordinates)
	var chunk_x = int(floor(global_pos.x / CHUNK_STRIDE))
	var chunk_y = int(floor(global_pos.y / CHUNK_STRIDE))
	var chunk_z = int(floor(global_pos.z / CHUNK_STRIDE))
	var coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not active_chunks.has(coord):
		return 1.0 # Air (chunk not loaded)
		
	var data = active_chunks[coord]
	if data == null or data.cpu_density_terrain.is_empty():
		return 1.0
		
	# Find local position within chunk
	var chunk_origin = Vector3(chunk_x * CHUNK_STRIDE, chunk_y * CHUNK_STRIDE, chunk_z * CHUNK_STRIDE)
	var local_pos = global_pos - chunk_origin
	
	# Round to nearest grid point
	var ix = int(round(local_pos.x))
	var iy = int(round(local_pos.y))
	var iz = int(round(local_pos.z))
	
	const DENSITY_GRID_SIZE = 33
	if ix < 0 or ix >= DENSITY_GRID_SIZE or iy < 0 or iy >= DENSITY_GRID_SIZE or iz < 0 or iz >= DENSITY_GRID_SIZE:
		return 1.0 # Out of bounds
		
	var index = ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
	
	if index >= 0 and index < data.cpu_density_terrain.size():
		return data.cpu_density_terrain[index]
		
	return 1.0

func get_water_density(global_pos: Vector3) -> float:
	# Find Chunk (3D coordinates)
	var chunk_x = int(floor(global_pos.x / CHUNK_STRIDE))
	var chunk_y = int(floor(global_pos.y / CHUNK_STRIDE))
	var chunk_z = int(floor(global_pos.z / CHUNK_STRIDE))
	var coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not active_chunks.has(coord):
		return 1.0 # Air (Positive is air, Negative is water)
		
	var data = active_chunks[coord]
	if data == null or data.cpu_density_water.is_empty():
		return 1.0
		
	# Find local position within chunk
	var chunk_origin = Vector3(chunk_x * CHUNK_STRIDE, chunk_y * CHUNK_STRIDE, chunk_z * CHUNK_STRIDE)
	var local_pos = global_pos - chunk_origin
	
	# Clamp to grid
	var ix = int(round(local_pos.x))
	var iy = int(round(local_pos.y))
	var iz = int(round(local_pos.z))
	
	const DENSITY_GRID_SIZE = 33
	if ix < 0 or ix >= DENSITY_GRID_SIZE or iy < 0 or iy >= DENSITY_GRID_SIZE or iz < 0 or iz >= DENSITY_GRID_SIZE:
		return 1.0 # Out of bounds
		
	var index = ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
	
	if index >= 0 and index < data.cpu_density_water.size():
		return data.cpu_density_water[index]
		
	return 1.0

## Get material ID at world position (reads from CPU-cached chunk data)
## Returns -1 if position is outside loaded chunks or no material data
func get_material_at(global_pos: Vector3) -> int:
	# Find Chunk (3D coordinates)
	var chunk_x = int(floor(global_pos.x / CHUNK_STRIDE))
	var chunk_y = int(floor(global_pos.y / CHUNK_STRIDE))
	var chunk_z = int(floor(global_pos.z / CHUNK_STRIDE))
	var coord = Vector3i(chunk_x, chunk_y, chunk_z)
	
	if not active_chunks.has(coord):
		return -1 # Chunk not loaded
		
	var data = active_chunks[coord]
	if data == null or data.cpu_material_terrain.is_empty():
		return -1 # No material data
		
	# Find local position within chunk
	var chunk_origin = Vector3(chunk_x * CHUNK_STRIDE, chunk_y * CHUNK_STRIDE, chunk_z * CHUNK_STRIDE)
	var local_pos = global_pos - chunk_origin
	
	# Round to nearest grid point
	var ix = int(round(local_pos.x))
	var iy = int(round(local_pos.y))
	var iz = int(round(local_pos.z))
	
	const DENSITY_GRID_SIZE = 33
	# Clamp to valid range (0-32)
	ix = clampi(ix, 0, DENSITY_GRID_SIZE - 1)
	iy = clampi(iy, 0, DENSITY_GRID_SIZE - 1)
	iz = clampi(iz, 0, DENSITY_GRID_SIZE - 1)
		
	var voxel_index = ix + (iy * DENSITY_GRID_SIZE) + (iz * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
	
	# CRITICAL: Material buffer stores uint32 per voxel (4 bytes each)
	# We need to read the first byte of each uint32 (material ID is 0-255)
	var byte_offset = voxel_index * 4 # 4 bytes per uint
	
	if byte_offset >= 0 and byte_offset < data.cpu_material_terrain.size():
		return data.cpu_material_terrain[byte_offset] # First byte is the mat_id
		
	return -1

# Check if any Y layer at this X,Z has stored modifications (player-built terrain)
func has_modifications_at_xz(x: int, z: int) -> bool:
	for coord in stored_modifications:
		if coord.x == x and coord.z == z:
			return true
	return false

func get_terrain_height(global_x: float, global_z: float) -> float:
	# Find X,Z chunk coordinates
	var chunk_x = int(floor(global_x / CHUNK_STRIDE))
	var chunk_z = int(floor(global_z / CHUNK_STRIDE))
	
	# Calculate local X,Z within chunk
	var chunk_origin_x = chunk_x * CHUNK_STRIDE
	var chunk_origin_z = chunk_z * CHUNK_STRIDE
	var local_x = int(round(global_x - chunk_origin_x))
	var local_z = int(round(global_z - chunk_origin_z))
	
	const DENSITY_GRID_SIZE = 33
	if local_x < 0 or local_x >= DENSITY_GRID_SIZE or local_z < 0 or local_z >= DENSITY_GRID_SIZE:
		return -1000.0
	
	# Scan from highest to lowest Y-layer to find terrain surface
	var best_height = -1000.0
	
	for chunk_y in range(MAX_Y_LAYER, MIN_Y_LAYER - 1, -1):
		var coord = Vector3i(chunk_x, chunk_y, chunk_z)
		
		if not active_chunks.has(coord):
			continue
			
		var data = active_chunks[coord]
		if data == null or data.cpu_density_terrain.is_empty():
			continue
		
		var chunk_base_y = chunk_y * CHUNK_STRIDE
		
		# Scan Y column from top to bottom within this chunk
		var prev_density = 1.0 # Assume air above
		for iy in range(DENSITY_GRID_SIZE - 1, -1, -1):
			var index = local_x + (iy * DENSITY_GRID_SIZE) + (local_z * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
			var density = data.cpu_density_terrain[index]
			
			if density < 0.0:
				# Found ground! Interpolate for accurate isosurface height
				var local_height: float
				if iy < DENSITY_GRID_SIZE - 1:
					var t = prev_density / (prev_density - density)
					local_height = float(iy + 1) - t
				else:
					local_height = float(iy)
				
				var world_height = chunk_base_y + local_height
				if world_height > best_height:
					best_height = world_height
				# Found surface in this chunk, stop searching
				return best_height
			prev_density = density
	
	return best_height # Return -1000.0 if no terrain found

# Optimized height lookup that only checks a specific chunk (much faster for vegetation placement)
func get_chunk_surface_height(coord: Vector3i, local_x: int, local_z: int) -> float:
	if not active_chunks.has(coord):
		return -1000.0
		
	var data = active_chunks[coord]
	if data == null or data.cpu_density_terrain.is_empty():
		return -1000.0
		
	# Scan Y column from top to bottom within this chunk
	var chunk_base_y = coord.y * CHUNK_STRIDE
	var prev_density = 1.0 # Assume air above
	
	const DENSITY_GRID_SIZE = 33
	# Safety check for bounds
	if local_x < 0 or local_x >= DENSITY_GRID_SIZE or local_z < 0 or local_z >= DENSITY_GRID_SIZE:
		return -1000.0
	
	# Pre-calculate index offsets to avoid multiplication in loop
	var col_offset = local_x + (local_z * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE)
	var stride_y = DENSITY_GRID_SIZE
	
	for iy in range(DENSITY_GRID_SIZE - 1, -1, -1):
		var index = col_offset + (iy * stride_y)
		var density = data.cpu_density_terrain[index]
		
		if density < 0.0:
			# Found ground! Interpolate
			var local_height: float
			if iy < DENSITY_GRID_SIZE - 1:
				var t = prev_density / (prev_density - density)
				local_height = float(iy + 1) - t
			else:
				local_height = float(iy)
			
			return chunk_base_y + local_height
		
		prev_density = density
		
	return -1000.0
