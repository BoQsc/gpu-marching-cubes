extends Node3D

signal chunk_generated(coord: Vector3i, chunk_node: Node3D)
signal chunk_modified(coord: Vector3i, chunk_node: Node3D) # For terrain edits - vegetation stays
signal chunk_unloaded(coord: Vector3i) # Emitted when chunk is removed from world
signal spawn_zones_ready(positions: Array) # Emitted when all requested spawn zones have loaded

# 32 Voxels wide
const CHUNK_SIZE = 32
# Overlap chunks by 1 unit to prevent gaps (seams)
const CHUNK_STRIDE = CHUNK_SIZE - 1
const DENSITY_GRID_SIZE = 33 # 0..32

# Y-layer limits for vertical chunk stacking
const MIN_Y_LAYER = -20 # How deep you can dig (in chunk layers)
const MAX_Y_LAYER = 40 # How high you can build (in chunk layers)

# Max triangles estimation
const MAX_TRIANGLES = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 5

@export var viewer: Node3D
@export var render_distance: int = 5 # Visual range
@export var terrain_height: float = 10.0
@export var water_level: float = 13.0 # Lowered to keep roads dry
@export var noise_frequency: float = 0.1
## World generation seed - same seed = same world
## Change this for different world generation
@export var world_seed: int = 12345

## Procedural Road Network (generated with terrain)
@export var procedural_roads_enabled: bool = true # Toggle to disable procedural roads
@export var procedural_road_spacing: float = 100.0 # Distance between roads
@export var procedural_road_width: float = 8.0 # Width of roads
@export var debug_show_road_zones: bool = false # Debug: show road alignment (Yellow=correct, Red=spillover, Green=crack)

# GPU Threading (single thread for compute shaders)
var voxel_engine: VoxelEngine
var chunk_loader: ChunkLoader
var terrain_view: TerrainView

# Task Queue (GPU tasks)
var modification_batch_id: int = 0
var pending_batches: Dictionary = {}

# Shaders (SPIR-V Data)
var material_terrain: Material
var material_water: Material

# Preload required for class_name visibility until editor restart
const ChunkData = preload("res://world_marching_cubes/chunk_data.gd")

var active_chunks: Dictionary = {}

# Collision distance - only enable collision within this range (cheaper than render_distance)
@export var collision_distance: int = 3 # Chunks within this get collision

# Time-budgeted node creation - prevents stutters from multiple chunks completing at once
var pending_nodes: Array[Dictionary] = [] # Queue of completed chunks waiting for node creation
var pending_nodes_mutex: Mutex

# Time-distributed finalization - spreads chunk appearances evenly over time
var last_finalization_time_ms: int = 0
## Minimum time between chunk finalizations (ms). Lower = faster loading, Higher = smoother appearance.
## 100ms = max 10 chunks/second for very smooth visual spread.
@export_range(0, 5000, 10) var min_finalization_interval_ms: int = 100

# Two-phase loading system
# Phase 1 (Initial Load): Fast/aggressive at game start for loading screen
# Phase 2 (Exploration): Slower/throttled when player explores
var initial_load_phase: bool = true
var initial_load_target_chunks: int = 0 # Calculated at startup based on render_distance
var chunks_loaded_initial: int = 0
var underground_load_triggered: bool = false # Track if Y=-1 burst load has been done

## Delay between chunk generation during initial game load (ms). 
## Initial load ends after ~π×render_distance² chunks (e.g., ~78 chunks for render_distance=5).
## Set to 0 for fastest loading. Higher values = slower but smoother loading.
@export_range(0, 100, 1) var initial_load_delay_ms: int = 0

## Delay between chunk generation when player is exploring (ms).
## Higher values reduce FPS drops but make terrain load slower as you move.
## Recommended: 100-200ms for smooth exploration.
@export_range(0, 6000, 10) var exploration_delay_ms: int = 300

# Adaptive loading - throttles based on current FPS
var target_fps: float = 75.0
var min_acceptable_fps: float = 45.0
var current_fps: float = 60.0
var fps_samples: Array[float] = []
var adaptive_frame_budget_ms: float = 1.0 # Dynamically adjusted (reduced for smoother FPS)
var chunks_per_frame_limit: int = 2 # Dynamically adjusted
var loading_paused: bool = false
var terrain_grid = null


# Persistent modification storage - survives chunk unloading
# Format: coord (Vector2i) -> Array of { brush_pos: Vector3, radius: float, value: float, shape: int, layer: int }
var stored_modifications: Dictionary = {}

# Spawn zone tracking - positions waiting for terrain to load
# Format: Array of { "position": Vector3, "radius": int, "pending_coords": Array[Vector3i] }
var pending_spawn_zones: Array = []

func _ready():
	pending_nodes_mutex = Mutex.new()
	
	if not viewer:
		viewer = get_tree().get_first_node_in_group("player")
		if not viewer:
			viewer = get_node_or_null("../CharacterBody3D")
	
	if viewer:
		DebugManager.log_chunk("Viewer found: %s" % viewer.name)
	else:
		push_warning("Viewer NOT found! Terrain generation will not start.")

	# Check for GDExtension
	if ClassDB.class_exists("MeshBuilder"):
		DebugManager.log_chunk("GDExtension MeshBuilder active")
	else:
		push_warning("[GDExtension] MeshBuilder NOT found. Using slow GDScript fallback.")

	# Check for TerrainGrid
	if ClassDB.class_exists("TerrainGrid"):
		terrain_grid = ClassDB.instantiate("TerrainGrid")
		DebugManager.log_chunk("GDExtension TerrainGrid active")


	# Setup Terrain Shader Material
	var shader = load("res://world_marching_cubes/terrain.gdshader")
	material_terrain = ShaderMaterial.new()
	material_terrain.shader = shader
	
	material_terrain.set_shader_parameter("texture_grass", load("res://world_marching_cubes/green-grass-texture.jpg"))
	material_terrain.set_shader_parameter("texture_rock", load("res://world_marching_cubes/rocky-texture.jpg"))
	material_terrain.set_shader_parameter("texture_stone", load("res://world_marching_cubes/stone_material.png")) # Underground/gravel
	material_terrain.set_shader_parameter("texture_sand", load("res://world_marching_cubes/sand-texture.jpg"))
	material_terrain.set_shader_parameter("texture_snow", load("res://world_marching_cubes/snow-texture.jpg") if FileAccess.file_exists("res://world_marching_cubes/snow-texture.jpg") else load("res://world_marching_cubes/rocky-texture.jpg"))
	material_terrain.set_shader_parameter("texture_road", load("res://world_marching_cubes/asphalt-texture.png"))
	material_terrain.set_shader_parameter("uv_scale", 0.5)
	material_terrain.set_shader_parameter("global_snow_amount", 0.0)
	# Procedural road texture settings (sync with density shader)
	material_terrain.set_shader_parameter("procedural_road_enabled", procedural_roads_enabled)
	material_terrain.set_shader_parameter("procedural_road_spacing", procedural_road_spacing if procedural_roads_enabled else 0.0)
	material_terrain.set_shader_parameter("procedural_road_width", procedural_road_width)
	# Terrain parameters for per-pixel material calculation (sync with gen_density.glsl)
	material_terrain.set_shader_parameter("terrain_height", terrain_height)
	material_terrain.set_shader_parameter("noise_frequency", noise_frequency)
	# Debug visualization
	material_terrain.set_shader_parameter("debug_show_road_zones", debug_show_road_zones)
	# Road mask will be set by road_manager
	
	# Setup Water Material
	material_water = ShaderMaterial.new()
	material_water.shader = load("res://world_marching_cubes/water.gdshader")
	# Dark green water colors
	material_water.set_shader_parameter("albedo", Color(0.05, 0.18, 0.12))
	material_water.set_shader_parameter("albedo_deep", Color(0.01, 0.06, 0.04))
	material_water.set_shader_parameter("albedo_shallow", Color(0.1, 0.3, 0.2))
	material_water.set_shader_parameter("beer_factor", 0.25)
	# Water normal texture for detailed ripples
	var water_normal = load("res://world_marching_cubes/water_texture.png")
	if water_normal:
		material_water.set_shader_parameter("water_normal_texture", water_normal)
	
	# Initialize Voxel Engine
	voxel_engine = VoxelEngine.new(material_terrain, material_water)
	voxel_engine.generation_completed.connect(_on_generation_completed)
	voxel_engine.modification_completed.connect(complete_modification)
	voxel_engine.start()
	
	# Initialize View and Loader
	terrain_view = TerrainView.new(self, material_terrain, material_water, active_chunks)
	terrain_view.chunk_node_created.connect(func(coord, node): chunk_generated.emit(coord, node))
	
	chunk_loader = ChunkLoader.new(voxel_engine, active_chunks, stored_modifications)
	chunk_loader.viewer = viewer
	chunk_loader.render_distance = render_distance
	
	# Calculate initial load target (all chunks within render distance)
	# For ground-level players, we only load Y=0, same chunk count as before
	initial_load_target_chunks = int(PI * render_distance * render_distance)
	DebugManager.log_chunk("Two-phase loading: target=%d chunks, initial=%dms, explore=%dms" % [initial_load_target_chunks, initial_load_delay_ms, exploration_delay_ms])


## Gets the effective viewer position for chunk loading.
## Returns vehicle position when player is driving a vehicle,
## otherwise returns the player's position.
func get_viewer_position() -> Vector3:
	if not viewer:
		return Vector3.ZERO
	
	# Check if player is in a vehicle
	var vm = get_tree().get_first_node_in_group("vehicle_manager")
	if vm and "current_player_vehicle" in vm and vm.current_player_vehicle:
		return vm.current_player_vehicle.global_position
	
	# Default: player's position
	return viewer.global_position


func _process(delta):
	if not viewer:
		return
	
	# Track FPS
	_update_fps_tracking(delta)
	
	# Adjust loading based on FPS
	_adjust_adaptive_loading()
	
	# Sync settings to loader/view
	chunk_loader.chunks_per_frame_limit = chunks_per_frame_limit
	chunk_loader.loading_paused = loading_paused
	chunk_loader.initial_load_phase = initial_load_phase
	terrain_view.loading_paused = loading_paused
	terrain_view.initial_load_phase = initial_load_phase
	
	PerformanceMonitor.start_measure("Chunk Update")
	chunk_loader.update(get_viewer_position())
	PerformanceMonitor.end_measure("Chunk Update", PerformanceMonitor.thresholds.get("chunk_gen", 3.0)) # Should be fast (< 2ms)
	
	PerformanceMonitor.start_measure("Node Finalization")
	terrain_view.process_pending_nodes(get_viewer_position())
	PerformanceMonitor.end_measure("Node Finalization", 2.0)
	
	update_collision_proximity() # Enable/disable collision based on player distance
	
	# HOTFIX: Ensure all existing chunks have layer 512 (Layer 10) for pickups
	if active_chunks.size() > 0 and not get_meta("collision_fixed", false):
		for coord in active_chunks:
			var data = active_chunks[coord]
			if data:
				if data.body_rid_terrain.is_valid():
					PhysicsServer3D.body_set_collision_layer(data.body_rid_terrain, 1 | 512)
				if data.node_terrain is StaticBody3D:
					data.node_terrain.collision_layer = 1 | 512
		set_meta("collision_fixed", true)
		DebugManager.log_chunk("HOTFIX: Updated existing chunks to layer 1|512")

var debug_chunk_bounds: bool = false

func _unhandled_input(event):
	# F9 toggles chunk boundary visualization
	if event is InputEventKey and event.pressed and event.keycode == KEY_F9:
		debug_chunk_bounds = !debug_chunk_bounds
		DebugManager.log_chunk("Chunk bounds visualization: %s" % ("ON" if debug_chunk_bounds else "OFF"))
		# Update all chunk materials
		for coord in active_chunks:
			var data = active_chunks[coord]
			if data and data.chunk_material:
				data.chunk_material.set_shader_parameter("debug_show_chunk_bounds", debug_chunk_bounds)
		material_terrain.set_shader_parameter("debug_show_chunk_bounds", debug_chunk_bounds)
	
	# F10 toggles road zone visualization (Yellow=correct, Red=spillover, Green=crack)
	if event is InputEventKey and event.pressed and event.keycode == KEY_F10:
		debug_show_road_zones = !debug_show_road_zones
		DebugManager.log_chunk("Road zones visualization: %s" % ("ON" if debug_show_road_zones else "OFF"))
		# Update all chunk materials
		for coord in active_chunks:
			var data = active_chunks[coord]
			if data and data.chunk_material:
				data.chunk_material.set_shader_parameter("debug_show_road_zones", debug_show_road_zones)
		material_terrain.set_shader_parameter("debug_show_road_zones", debug_show_road_zones)

func _update_fps_tracking(delta: float):
	var instant_fps = 1.0 / delta if delta > 0 else 60.0
	fps_samples.append(instant_fps)
	
	# Keep last 30 samples (0.5 seconds at 60fps)
	while fps_samples.size() > 30:
		fps_samples.pop_front()
	
	# Calculate average FPS
	var total = 0.0
	for fps in fps_samples:
		total += fps
	current_fps = total / fps_samples.size()

func _adjust_adaptive_loading():
	if current_fps < min_acceptable_fps:
		# FPS is too low - pause loading completely
		loading_paused = true
		adaptive_frame_budget_ms = 0.0 # Zero work when FPS critical
		chunks_per_frame_limit = 0
	elif current_fps < target_fps:
		# FPS is below target - reduce loading with tighter budget
		loading_paused = false
		var fps_ratio = current_fps / target_fps
		adaptive_frame_budget_ms = lerp(0.25, 1.0, fps_ratio) # Tighter range
		chunks_per_frame_limit = 1
	else:
		# FPS is good - still limit to prevent stutters
		loading_paused = false
		adaptive_frame_budget_ms = 1.5 # Max 1.5ms (reduced from 3ms)
		chunks_per_frame_limit = 1

# Bridge function: VoxelEngine Signal -> TerrainView Queue
func _on_generation_completed(coord: Vector3i, result_t: Dictionary, dens_t: RID, result_w: Dictionary, dens_w: RID, cpu_dens_w: PackedFloat32Array, cpu_dens_t: PackedFloat32Array, mat_t: RID = RID(), cpu_mat_t: PackedByteArray = PackedByteArray()):
	if not active_chunks.has(coord):
		# Cleanup logic handled in engine via free_resources or garbage collection
		# Here we just notify engine to free these new RIDs
		var rids = []
		if dens_t.is_valid(): rids.append(dens_t)
		if dens_w.is_valid(): rids.append(dens_w)
		if mat_t.is_valid(): rids.append(mat_t)
		if not rids.is_empty():
			voxel_engine.free_resources(rids)
		return
	
	pending_nodes_mutex.lock()
	
	# Split into two separate tasks to spread main-thread load
	# Task 1: Terrain (Heavier - ~4ms)
	# Optimize: Create Physics Body ON THREAD to avoid Main Thread spike
	var body_rid = RID()
	var shape_rid = RID()
	
	if result_t.shape:
		# 1. Create Body
		body_rid = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
		
		# 2. Create and Add Shape
		shape_rid = result_t.shape.get_rid()
		
		PhysicsServer3D.body_add_shape(body_rid, shape_rid)
		
		# 3. Set Layer/Mask (Layer 1 = Terrain)
		PhysicsServer3D.body_set_collision_layer(body_rid, 1 | 512)
		PhysicsServer3D.body_set_collision_mask(body_rid, 1)
		
		# 4. Add to Space (The heavy part - Done on Thread!)
		var space = get_world_3d().space
		PhysicsServer3D.body_set_space(body_rid, space)
		
		# 5. Set Position (Chunk Origin)
		var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
		var transform = Transform3D(Basis(), chunk_pos)
		PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, transform)

	var task_t = {
		"type": "final_terrain",
		"coord": coord,
		"result": result_t,
		"dens": dens_t,
		"mat_buf": mat_t,
		"cpu_dens": cpu_dens_t,
		"cpu_mat": cpu_mat_t,
		"body_rid": body_rid
	}
	
	# Task 2: Water (Lighter - ~2ms)
	var task_w = {
		"type": "final_water",
		"coord": coord,
		"result": result_w,
		"dens": dens_w,
		"cpu_dens": cpu_dens_w
	}
	
	pending_nodes_mutex.unlock()
	
	# Queue to view
	terrain_view.queue_chunk_finalization(task_t)
	terrain_view.queue_chunk_finalization(task_w)
	
	_check_spawn_zone_readiness(coord)
	
	if initial_load_phase:
		chunks_loaded_initial += 1
		if chunks_loaded_initial >= initial_load_target_chunks:
			initial_load_phase = false
			DebugManager.log_chunk("Initial load complete (View confirmed)")

func complete_modification(coord: Vector3i, result: Dictionary, layer: int, batch_id: int = -1, batch_count: int = 1, cpu_dens: PackedFloat32Array = PackedFloat32Array(), cpu_mat: PackedByteArray = PackedByteArray(), start_mod_version: int = 0):
	# For non-batched updates, do stale check here
	if batch_id == -1:
		# STALE CHECK for non-batched updates
		if active_chunks.has(coord):
			var chunk_data = active_chunks[coord]
			if chunk_data != null and start_mod_version > 0 and start_mod_version < chunk_data.mod_version:
				DebugManager.log_chunk("STALE: Skipping non-batched update for %s (v%d < v%d)" % [coord, start_mod_version, chunk_data.mod_version])
				return
		_apply_chunk_update(coord, result, layer, cpu_dens, cpu_mat, start_mod_version)
		return
	
	# BATCHED UPDATES: Must track batch counter even for stale updates
	if not pending_batches.has(batch_id):
		pending_batches[batch_id] = {"received": 0, "expected": batch_count, "updates": []}
	
	var batch = pending_batches[batch_id]
	batch.received += 1  # Always increment, even if stale (to complete the batch)
	
	# Only add to updates list if not stale
	var is_stale = false
	if active_chunks.has(coord):
		var chunk_data = active_chunks[coord]
		if chunk_data != null and start_mod_version > 0 and start_mod_version < chunk_data.mod_version:
			DebugManager.log_chunk("STALE: Skipping batched update for %s (v%d < v%d)" % [coord, start_mod_version, chunk_data.mod_version])
			is_stale = true
	
	if not is_stale and active_chunks.has(coord):
		batch.updates.append({"coord": coord, "result": result, "layer": layer, "cpu_dens": cpu_dens, "cpu_mat": cpu_mat, "start_mod_version": start_mod_version})
		
	if batch.received >= batch.expected:
		for update in batch.updates:
			_apply_chunk_update(update.coord, update.result, update.layer, update.cpu_dens, update.get("cpu_mat", PackedByteArray()), update.get("start_mod_version", 0))
		pending_batches.erase(batch_id)

func _apply_chunk_update(coord: Vector3i, result: Dictionary, layer: int, cpu_dens: PackedFloat32Array, cpu_mat: PackedByteArray = PackedByteArray(), start_mod_version: int = 0):
	if not active_chunks.has(coord):
		return
	var data = active_chunks[coord]
	
	# STALE CHECK: Secondary check at application time (for batched updates)
	if data != null and start_mod_version > 0 and start_mod_version < data.mod_version:
		DebugManager.log_chunk("STALE APPLY: Skipping update for %s (v%d < v%d)" % [coord, start_mod_version, data.mod_version])
		return
	
	var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
	
	if layer == 0: # Terrain
		# CRITICAL: Free the PhysicsServer body RID first (contains stale collision)
		if data.body_rid_terrain.is_valid():
			PhysicsServer3D.free_rid(data.body_rid_terrain)
			data.body_rid_terrain = RID() # Clear to prevent double-free
		if data.node_terrain: data.node_terrain.queue_free()
		
		# Recreate chunk material with updated 3D texture
		# Note: This duplicates logic from TerrainView, ideally we move this to View too
		var chunk_material = terrain_view._create_chunk_material(chunk_pos, cpu_mat)
		
		var result_node = terrain_view.create_chunk_node(result.mesh, result.shape, chunk_pos, false, chunk_material)
		data.node_terrain = result_node.node if not result_node.is_empty() else null
		data.collision_shape_terrain = result_node.collision_shape if not result_node.is_empty() else null
		data.chunk_material = chunk_material
		if not cpu_dens.is_empty():
			data.cpu_density_terrain = cpu_dens
		if not cpu_mat.is_empty():
			data.cpu_material_terrain = cpu_mat
		# Signal vegetation manager that chunk node changed (update references, don't regenerate)
		chunk_modified.emit(coord, data.node_terrain)
	else: # Water
		DebugManager.log_chunk("Applying water update to %s, has_mesh=%s" % [coord, result.mesh != null])
		if data.node_water: data.node_water.queue_free()
		var result_node = terrain_view.create_chunk_node(result.mesh, result.shape, chunk_pos, true)
		data.node_water = result_node.node if not result_node.is_empty() else null
		if not cpu_dens.is_empty():
			data.cpu_density_water = cpu_dens

var collision_update_counter: int = 0
func update_collision_proximity():
	# Only update every 30 frames to reduce overhead
	collision_update_counter += 1
	if collision_update_counter < 30:
		return
	collision_update_counter = 0
	
	var p_pos = get_viewer_position()
	var p_chunk_x = int(floor(p_pos.x / CHUNK_STRIDE))
	var p_chunk_y = int(floor(p_pos.y / CHUNK_STRIDE))
	var p_chunk_z = int(floor(p_pos.z / CHUNK_STRIDE))
	var center_chunk = Vector3i(p_chunk_x, p_chunk_y, p_chunk_z)
	
	for coord in active_chunks:
		var data = active_chunks[coord]
		if data == null:
			continue
		
		# 3D distance for collision check
		var dx = coord.x - center_chunk.x
		var dy = coord.y - center_chunk.y
		var dz = coord.z - center_chunk.z
		var dist_xz = sqrt(dx * dx + dz * dz)
		# Enable collision if close horizontally AND within 2 Y layers
		var should_have_collision = dist_xz <= collision_distance and abs(dy) <= 2
		
		# Enable/disable collision shape
		if data.collision_shape_terrain:
			data.collision_shape_terrain.disabled = not should_have_collision

# ============ SPAWN ZONE API ============
# These methods enable save/load to wait for terrain before spawning players/entities

## Request priority loading of chunks around a spawn position
## The spawn_zones_ready signal will be emitted when all chunks are loaded
func request_spawn_zone(position: Vector3, radius: int = 2):
	var chunk_x = int(floor(position.x / CHUNK_STRIDE))
	var chunk_y = int(floor(position.y / CHUNK_STRIDE))
	var chunk_z = int(floor(position.z / CHUNK_STRIDE))
	
	var pending_coords: Array[Vector3i] = []
	
	# Collect chunks in radius and request generation for any not loaded
	for dx in range(-radius, radius + 1):
		for dy in range(-1, 2): # Only check Y layers -1, 0, +1 around spawn
			for dz in range(-radius, radius + 1):
				var coord = Vector3i(chunk_x + dx, chunk_y + dy, chunk_z + dz)
				
				# Skip if already loaded with data
				if active_chunks.has(coord) and active_chunks[coord] != null:
					continue
				
				# Mark as pending
				if not active_chunks.has(coord):
					active_chunks[coord] = null
					var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
					voxel_engine.queue_generation(coord, chunk_pos)
				
				pending_coords.append(coord)
	
	if pending_coords.is_empty():
		# All chunks already loaded - emit immediately
		call_deferred("emit_signal", "spawn_zones_ready", [position])
	else:
		# Track this spawn zone
		pending_spawn_zones.append({
			"position": position,
			"radius": radius,
			"pending_coords": pending_coords
		})
		DebugManager.log_chunk("SpawnZone requested %d chunks at %s" % [pending_coords.size(), position])

## Check if chunks around a position are ready (loaded with data)
func are_chunks_ready_around(position: Vector3, radius: int = 2) -> bool:
	var chunk_x = int(floor(position.x / CHUNK_STRIDE))
	var chunk_y = int(floor(position.y / CHUNK_STRIDE))
	var chunk_z = int(floor(position.z / CHUNK_STRIDE))
	
	for dx in range(-radius, radius + 1):
		for dy in range(-1, 2):
			for dz in range(-radius, radius + 1):
				var coord = Vector3i(chunk_x + dx, chunk_y + dy, chunk_z + dz)
				# Not loaded or still pending (null)
				if not active_chunks.has(coord) or active_chunks[coord] == null:
					return false
	return true

## Called when a chunk completes generation - checks if any spawn zones are now ready
func _check_spawn_zone_readiness(completed_coord: Vector3i):
	if pending_spawn_zones.is_empty():
		return
	
	var zones_to_remove: Array[int] = []
	var ready_positions: Array[Vector3] = []
	
	for i in range(pending_spawn_zones.size()):
		var zone = pending_spawn_zones[i]
		zone.pending_coords.erase(completed_coord)
		
		if zone.pending_coords.is_empty():
			zones_to_remove.append(i)
			ready_positions.append(zone.position)
	
	# Remove completed zones (reverse order to preserve indices)
	for i in range(zones_to_remove.size() - 1, -1, -1):
		pending_spawn_zones.remove_at(zones_to_remove[i])
	
	# Emit signal if any zones completed
	if not ready_positions.is_empty():
		DebugManager.log_chunk("SpawnZone %d zones ready" % ready_positions.size())
		spawn_zones_ready.emit(ready_positions)

## Request multiple spawn zones at once (for batch loading player + entities)
func request_spawn_zones(positions: Array[Vector3], radius: int = 2):
	for pos in positions:
		request_spawn_zone(pos, radius)

# Removing legacy threading functions (moved to VoxelEngine)
# _interruptible_delay, _thread_function, _dispatch_chunk_generation, 
# _complete_chunk_readback, run_gpu_meshing_dispatch, run_gpu_meshing_readback,
# run_gpu_meshing, _cpu_thread_function, _apply_modification_to_buffer, 
# process_modify, build_mesh, run_meshing

# ============================================================================
# PUBLIC API DELEGATES
# ============================================================================

## Returns true when initial terrain chunks are visually ready (meshes created)
func is_initial_load_complete() -> bool:
	return terrain_view.get_pending_count() == 0 and not initial_load_phase

## Progress: 0.0-1.0 based on chunks loaded during initial phase
func get_loading_progress() -> float:
	if initial_load_target_chunks <= 0:
		return 1.0
	return clamp(float(chunks_loaded_initial) / initial_load_target_chunks, 0.0, 1.0)

## Get count of pending nodes waiting to be finalized (for loading screen)
func get_pending_nodes_count() -> int:
	return terrain_view.get_pending_count()

## Get material ID at world position (reads from CPU-cached chunk data)
func get_material_at(global_pos: Vector3) -> int:
	return chunk_loader.get_material_at(global_pos)

## Get terrain density at world position (reads from CPU-cached chunk data)
func get_terrain_density(global_pos: Vector3) -> float:
	return chunk_loader.get_terrain_density(global_pos)

## Get water density at world position
func get_water_density(global_pos: Vector3) -> float:
	return chunk_loader.get_water_density(global_pos)

## Get chunk surface height (optimized for vegetation)
func get_chunk_surface_height(coord: Vector3i, local_x: int, local_z: int) -> float:
	return chunk_loader.get_chunk_surface_height(coord, local_x, local_z)

## Get terrain height at any world position
func get_terrain_height(global_x: float, global_z: float) -> float:
	return chunk_loader.get_terrain_height(global_x, global_z)

## Check if any Y layer at this X,Z has stored modifications (player-built terrain)
func has_modifications_at_xz(x: int, z: int) -> bool:
	return chunk_loader.has_modifications_at_xz(x, z)

# ============================================================================
# TERRAIN MODIFICATION API
# ============================================================================

# Updated to accept layer (0=Terrain, 1=Water) and optional material_id
# Rate limiting to prevent GPU overload from rapid-fire calls
var _last_modify_time_ms: int = 0
const MODIFY_COOLDOWN_MS: int = 100  # Max 10 modifications per second

func modify_terrain(pos: Vector3, radius: float, value: float, shape: int = 0, layer: int = 0, material_id: int = -1):
	# RATE LIMITING: Skip if called too quickly (prevents 60 GPU ops/sec when holding mouse)
	var now_ms = Time.get_ticks_msec()
	if now_ms - _last_modify_time_ms < MODIFY_COOLDOWN_MS:
		return  # Skip this call, too soon after last one
	_last_modify_time_ms = now_ms
	
	# Calculate bounds of the modification sphere/box
	# Add extra margin (1.0) to account for material radius extension and shader sampling
	var extra_margin = 1.0 if material_id >= 0 else 0.0
	var min_pos = pos - Vector3(radius + extra_margin, radius + extra_margin, radius + extra_margin)
	var max_pos = pos + Vector3(radius + extra_margin, radius + extra_margin, radius + extra_margin)
	
	var min_chunk_x = int(floor(min_pos.x / CHUNK_STRIDE))
	var max_chunk_x = int(floor(max_pos.x / CHUNK_STRIDE))
	var min_chunk_y = int(floor(min_pos.y / CHUNK_STRIDE))
	var max_chunk_y = int(floor(max_pos.y / CHUNK_STRIDE))
	var min_chunk_z = int(floor(min_pos.z / CHUNK_STRIDE))
	var max_chunk_z = int(floor(max_pos.z / CHUNK_STRIDE))
	
	var tasks_to_add = []
	var chunks_to_generate = [] # Track unloaded chunks that need immediate loading
	
	# Store modification for persistence (all affected chunks)
	for x in range(min_chunk_x, max_chunk_x + 1):
		for y in range(min_chunk_y, max_chunk_y + 1):
			for z in range(min_chunk_z, max_chunk_z + 1):
				var coord = Vector3i(x, y, z)
				
				# Store the modification for this chunk (persists across unloads)
				if not stored_modifications.has(coord):
					stored_modifications[coord] = []
				stored_modifications[coord].append({
					"brush_pos": pos,
					"radius": radius,
					"value": value,
					"shape": shape,
					"layer": layer,
					"material_id": material_id
				})
				
				# Only dispatch GPU task if chunk is currently loaded
				if active_chunks.has(coord):
					var data = active_chunks[coord]
					if data != null:
						var target_buffer = data.density_buffer_terrain if layer == 0 else data.density_buffer_water
						
						if target_buffer.is_valid():
							var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
							
							# Increment chunk's modification version and capture for stale detection
							data.mod_version += 1
							var start_mod_version = data.mod_version
							
							var task = {
								"type": "modify",
								"coord": coord,
								"rid": target_buffer,
								"material_rid": data.material_buffer_terrain, # Pass material buffer
								"pos": chunk_pos,
								"brush_pos": pos,
								"radius": radius,
								"value": value,
								"shape": shape,
								"layer": layer,
								"material_id": material_id,
								"start_mod_version": start_mod_version  # For stale detection
							}
							tasks_to_add.append(task)
				else:
					# Chunk not loaded - trigger immediate generation
					if not active_chunks.has(coord): # Not already queued
						active_chunks[coord] = null # Mark as pending
						var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
						if DebugManager.LOG_CHUNK: DebugManager.log_chunk("modify_terrain triggering Y=%d at (%d, %d)" % [coord.y, coord.x, coord.z])
						chunks_to_generate.append({
							"type": "generate",
							"coord": coord,
							"pos": chunk_pos
						})
	
	# Queue chunk generations with high priority
	if chunks_to_generate.size() > 0:
		for gen_task in chunks_to_generate:
			voxel_engine.queue_generation(gen_task.coord, gen_task.pos)
	
	if tasks_to_add.size() > 0:
		modification_batch_id += 1
		var batch_count = tasks_to_add.size()
		
		# PRIORITY: Insert modifications at FRONT of queue
		# Reverse order to maintain sequence when pushing to front
		for i in range(tasks_to_add.size() - 1, -1, -1):
			var t = tasks_to_add[i]
			t["batch_id"] = modification_batch_id
			t["batch_count"] = batch_count
			voxel_engine.queue_modification(t)

## Fill a 1x1 vertical column of terrain from y_from to y_to
## Uses Column shape (type=2) for precise vertical fills
func fill_column(x: float, z: float, y_from: float, y_to: float, value: float, layer: int = 0):
	# Calculate center position (mid-point of column)
	var pos = Vector3(x, (y_from + y_to) / 2.0, z)
	
	# Add margin for Marching Cubes boundary overlap (1.0 is sufficient)
	var margin = 1.0
	var min_chunk_x = int(floor((x - margin) / CHUNK_STRIDE))
	var max_chunk_x = int(floor((x + margin) / CHUNK_STRIDE))
	var min_chunk_y = int(floor(y_from / CHUNK_STRIDE))
	var max_chunk_y = int(floor(y_to / CHUNK_STRIDE))
	var min_chunk_z = int(floor((z - margin) / CHUNK_STRIDE))
	var max_chunk_z = int(floor((z + margin) / CHUNK_STRIDE))
	
	var tasks_to_add = []
	
	for chunk_x in range(min_chunk_x, max_chunk_x + 1):
		for chunk_y in range(min_chunk_y, max_chunk_y + 1):
			for chunk_z in range(min_chunk_z, max_chunk_z + 1):
				var coord = Vector3i(chunk_x, chunk_y, chunk_z)
				
				# Store modification for persistence
				if not stored_modifications.has(coord):
					stored_modifications[coord] = []
				stored_modifications[coord].append({
					"brush_pos": pos,
					"radius": 0.6,
					"value": value,
					"shape": 2, # Column shape
					"layer": layer,
					"y_min": y_from,
					"y_max": y_to,
					"material_id": - 1
				})
				
				if active_chunks.has(coord):
					var data = active_chunks[coord]
					if data != null:
						var target_buffer = data.density_buffer_terrain if layer == 0 else data.density_buffer_water
						if target_buffer.is_valid():
							var chunk_pos = Vector3(coord.x * CHUNK_STRIDE, coord.y * CHUNK_STRIDE, coord.z * CHUNK_STRIDE)
							tasks_to_add.append({
								"type": "modify",
								"coord": coord,
								"rid": target_buffer,
								"material_rid": data.material_buffer_terrain,
								"pos": chunk_pos,
								"brush_pos": pos,
								"radius": 0.6,
								"value": value,
								"shape": 2, # Column shape
								"layer": layer,
								"y_min": y_from,
								"y_max": y_to,
								"material_id": - 1
							})
	
	if tasks_to_add.size() > 0:
		modification_batch_id += 1
		var batch_count = tasks_to_add.size()
		
		for i in range(tasks_to_add.size() - 1, -1, -1):
			var t = tasks_to_add[i]
			t["batch_id"] = modification_batch_id
			t["batch_count"] = batch_count
			voxel_engine.queue_modification(t)
