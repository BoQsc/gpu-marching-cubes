extends Node3D

signal tree_chopped(world_position: Vector3)
signal grass_harvested(world_position: Vector3)
signal rock_harvested(world_position: Vector3)

@export var terrain_manager: Node3D
@export var tree_model_path: String = "res://models/tree/1/pine_tree_-_ps1_low_poly.glb"
@export var tree_scale: float = 1.0
@export var tree_y_offset: float = 0.0  # GLB model has Y=11.76 origin built-in
@export var tree_rotation_fix: Vector3 = Vector3.ZERO
@export var collision_radius: float = 0.6
@export var collision_height: float = 8.0
@export var collider_distance: float = 30.0  # Only trees within this distance get colliders

# Grass settings
@export var grass_model_path: String = "res://models/grass/2/grass_lowpoly.glb"
@export var grass_scale: float = 0.5
@export var grass_y_offset: float = 0.0
@export var grass_collision_radius: float = 0.4
@export var grass_collision_height: float = 0.5
## Dense grass mode: even distribution everywhere (GPU intensive)
## Default (false): patchy distribution using noise (better performance)
@export var dense_grass_mode: bool = false

# Rock settings
@export var rock_model_path: String = "res://models/small_rock/simple_rock_-_ps1_low_poly.glb"
@export var rock_scale: float = 0.5
@export var rock_y_offset: float = 0.0
@export var rock_collision_radius: float = 0.5
@export var rock_collision_height: float = 0.4

## PERF: Global toggle for vegetation collisions (Huge physics cost)
@export var enable_vegetation_collisions: bool = true

var tree_mesh: Mesh
var tree_base_transform: Transform3D = Transform3D()  # Orientation fix from GLB
var grass_mesh: Mesh
var grass_base_transform: Transform3D = Transform3D()
var rock_mesh: Mesh
var rock_base_transform: Transform3D = Transform3D()
var forest_noise: FastNoiseLite
var grass_noise: FastNoiseLite
var rock_noise: FastNoiseLite
var player: Node3D

# Queue for deferred vegetation placement
var pending_chunks: Array[Dictionary] = []

# Tree data per chunk coord -> { multimesh, trees[], collision_container }
var chunk_tree_data: Dictionary = {}

# Pool of active colliders (reusable)
var active_colliders: Dictionary = {}  # key -> Node (StaticBody3D or Area3D)

# Resources for shapes (shared)
var shape_res_tree: CylinderShape3D
var shape_res_grass: SphereShape3D
var shape_res_rock: CylinderShape3D

# Constants limits
const MAX_ACTIVE_COLLIDERS = 50  # Limit active colliders for performance
const MAX_ACTIVE_GRASS_COLLIDERS = 30
const MAX_ACTIVE_ROCK_COLLIDERS = 30

# Grass data per chunk coord -> { multimesh, grass_list[] }
var chunk_grass_data: Dictionary = {}

# Rock data per chunk coord -> { multimesh, rock_list[] }
var chunk_rock_data: Dictionary = {}

var shape_res_tree: Shape3D
var shape_res_grass: Shape3D
var shape_res_rock: Shape3D

# Persistence - survives chunk unloading
var removed_grass: Dictionary = {}  # "x_z" position hash -> true
var removed_rocks: Dictionary = {}  # "x_z" position hash -> true
var chopped_trees: Dictionary = {}  # "x_z" position hash -> true (for save/load persistence)
var placed_grass: Array[Dictionary] = []  # { world_pos, scale, rotation }
var placed_rocks: Array[Dictionary] = []  # { world_pos, scale, rotation }

# Pending placements - retry when chunk becomes valid
var pending_rock_placements: Array[Dictionary] = []
var pending_grass_placements: Array[Dictionary] = []

# Incremental Collider Updates
var pending_collider_adds: Array[Dictionary] = [] # {type, key, item}
var pending_collider_removes: Array[Dictionary] = [] # {type, key}
var keys_pending_add: Dictionary = {} # Duplicate check
var keys_pending_remove: Dictionary = {} # Duplicate check
const MAX_COLLIDER_UPDATES_PER_FRAME = 5

func _ready():
	# Load tree mesh from GLB model with its orientation transform
	var glb_result = load_tree_mesh_from_glb(tree_model_path)
	if glb_result.mesh:
		tree_mesh = glb_result.mesh
		tree_base_transform = glb_result.transform
		tree_base_transform.origin = Vector3.ZERO  # Remove position, keep rotation/scale
	else:
		push_warning("Failed to load tree model, falling back to basic mesh")
		tree_mesh = create_basic_tree_mesh()
	
	forest_noise = FastNoiseLite.new()
	forest_noise.frequency = 0.05
	# Derive seed from world seed for reproducibility
	var base_seed = terrain_manager.world_seed if terrain_manager else 12345
	forest_noise.seed = base_seed
	
	# Load grass mesh
	var grass_result = load_tree_mesh_from_glb(grass_model_path)
	if grass_result.mesh:
		grass_mesh = grass_result.mesh
		grass_base_transform = grass_result.transform
		grass_base_transform.origin = Vector3.ZERO
		print("Loaded grass model from GLB")
	else:
		push_warning("Failed to load grass model, using basic mesh")
		grass_mesh = create_basic_grass_mesh()
	
	grass_noise = FastNoiseLite.new()
	grass_noise.frequency = 0.08  # Different pattern from trees
	grass_noise.seed = base_seed + 1  # Offset for different pattern
	
	# Load rock mesh
	var rock_result = load_tree_mesh_from_glb(rock_model_path)
	if rock_result.mesh:
		rock_mesh = rock_result.mesh
		rock_base_transform = rock_result.transform
		rock_base_transform.origin = Vector3.ZERO
		print("Loaded rock model from GLB")
	else:
		push_warning("Failed to load rock model, using basic mesh")
		rock_mesh = create_basic_rock_mesh()
	
	rock_noise = FastNoiseLite.new()
	rock_noise.frequency = 0.2
	rock_noise.fractal_octaves = 2
	
	# Pre-create physics shapes
	_create_physics_shapes()
	
	player = get_node("../Player")
	
	rock_noise.seed = base_seed + 2  # Offset for different pattern
	
	if terrain_manager:
		terrain_manager.chunk_generated.connect(_on_chunk_generated)
		terrain_manager.chunk_modified.connect(_on_chunk_modified)
		if terrain_manager.has_signal("chunk_unloaded"):
			terrain_manager.chunk_unloaded.connect(_on_chunk_unloaded)
	
	# Find player
	player = get_tree().get_first_node_in_group("player")

func _create_physics_shapes():
	# Tree Cylinder
	var cylinder = CylinderShape3D.new()
	cylinder.radius = collision_radius
	cylinder.height = collision_height
	shape_rid_tree = cylinder.get_rid()
	
	# Grass Sphere (Trigger)
	var sphere = SphereShape3D.new()
	sphere.radius = grass_collision_radius
	shape_rid_grass = sphere.get_rid()
	
	# Rock Cylinder (Trigger)
	var rc = CylinderShape3D.new()
	rc.radius = rock_collision_radius
	rc.height = rock_collision_height
	shape_rid_rock = rc.get_rid()
	
	# IMPORTANT: Keep resources alive by assigning them to member vars if needed
	# but Shape3D resource RIDs persist as long as the resource exists.
	# We'll just keep the RIDs and hope the GC doesn't kill the temp objects?
	# Actually, we should store the Resources to be safe.
	shape_res_tree = cylinder
	shape_res_grass = sphere
	shape_res_rock = rc

func _exit_tree():
	# Cleanup RIDs
	for rid in active_collider_rids.values():
		if rid.is_valid(): PhysicsServer3D.free_rid(rid)
	active_collider_rids.clear()
	rid_to_key_map.clear()

# Called when terrain is modified (player edits) - reparent vegetation, don't regenerate
func _on_chunk_modified(coord: Vector3i, chunk_node: Node3D):
	if chunk_node == null:
		return
	
	# Only handle surface chunks (Y=0) - vegetation doesn't exist on underground/sky chunks
	if coord.y != 0:
		return
	
	# Extract surface key (X,Z) - vegetation only exists on surface
	var surface_key = Vector2i(coord.x, coord.z)
	
	# Reparent vegetation MultiMeshInstances to the NEW chunk_node
	# This prevents them from being deleted when old chunk_node is freed
	if chunk_tree_data.has(surface_key):
		var data = chunk_tree_data[surface_key]
		if data.has("multimesh") and is_instance_valid(data.multimesh):
			var mmi = data.multimesh as MultiMeshInstance3D
			if mmi and mmi.get_parent():
				mmi.get_parent().remove_child(mmi)
				chunk_node.add_child(mmi)
		data.chunk_node = chunk_node
	
	if chunk_grass_data.has(surface_key):
		var data = chunk_grass_data[surface_key]
		if data.has("multimesh") and is_instance_valid(data.multimesh):
			var mmi = data.multimesh as MultiMeshInstance3D
			if mmi and mmi.get_parent():
				mmi.get_parent().remove_child(mmi)
				chunk_node.add_child(mmi)
		data.chunk_node = chunk_node
	
	if chunk_rock_data.has(surface_key):
		var data = chunk_rock_data[surface_key]
		if data.has("multimesh") and is_instance_valid(data.multimesh):
			var mmi = data.multimesh as MultiMeshInstance3D
			if mmi and mmi.get_parent():
				mmi.get_parent().remove_child(mmi)
				chunk_node.add_child(mmi)
		data.chunk_node = chunk_node

## Called when a chunk is unloaded - clean up vegetation data and colliders
func _on_chunk_unloaded(coord: Vector3i):
	# Only handle surface chunks (Y=0)
	if coord.y != 0:
		return
	
	var surface_key = Vector2i(coord.x, coord.z)
	print("[VegetationManager] Chunk unloaded: %s -> cleaning surface_key %s" % [coord, surface_key])
	
	# Clean up trees (including MultiMesh and colliders)
	if chunk_tree_data.has(surface_key):
		var data = chunk_tree_data[surface_key]
		var tree_count = data.trees.size() if data.has("trees") else 0
		var colliders_removed = 0
		# Free MultiMesh
		if data.has("multimesh") and is_instance_valid(data.multimesh):
			data.multimesh.queue_free()
		# Return colliders to pool
		for tree in data.trees:
			var key = _tree_key(surface_key, tree.index)
			if active_collider_rids.has(key):
				_free_collider_rid(key)
				colliders_removed += 1
		chunk_tree_data.erase(surface_key)
		print("  -> Trees: %d, colliders removed: %d, active_colliders remaining: %d" % [tree_count, colliders_removed, active_collider_rids.size()])
	else:
		print("  -> No tree data for this chunk")
	
	# Clean up grass
	if chunk_grass_data.has(surface_key):
		var data = chunk_grass_data[surface_key]
		if data.has("multimesh") and is_instance_valid(data.multimesh):
			data.multimesh.queue_free()
		for grass in data.grass_list:
			var key = _grass_key(surface_key, grass.index)
			if active_collider_rids.has(key):
				_free_collider_rid(key)
		chunk_grass_data.erase(surface_key)
	
	# Clean up rocks
	if chunk_rock_data.has(surface_key):
		var data = chunk_rock_data[surface_key]
		if data.has("multimesh") and is_instance_valid(data.multimesh):
			data.multimesh.queue_free()
		for rock in data.rock_list:
			var key = _rock_key(surface_key, rock.index)
			if active_collider_rids.has(key):
				_free_collider_rid(key)
		chunk_rock_data.erase(surface_key)

func _on_chunk_generated(coord: Vector3i, chunk_node: Node3D):
	if chunk_node == null:
		return
	
	# Only spawn vegetation on surface chunks (Y=0)
	# Underground chunks (Y=-1, -2, etc.) and sky chunks (Y=1+) don't need vegetation
	if coord.y != 0:
		return
	
	# Skip vegetation for modified chunks (player-built structures)
	# Check all Y layers at this X,Z for modifications
	if terrain_manager and terrain_manager.has_method("has_modifications_at_xz"):
		if terrain_manager.has_modifications_at_xz(coord.x, coord.z):
			return  # Don't spawn vegetation on player-modified terrain
	
	# Extract surface key (X,Z) - vegetation only exists on surface
	var surface_key = Vector2i(coord.x, coord.z)
	
	if chunk_tree_data.has(surface_key):
		_cleanup_chunk_trees(surface_key)
	if chunk_grass_data.has(surface_key):
		_cleanup_chunk_grass(surface_key)
	if chunk_rock_data.has(surface_key):
		_cleanup_chunk_rocks(surface_key)
	
	pending_chunks.append({
		"coord": surface_key,  # Use surface_key for vegetation
		"chunk_node": chunk_node,
		"frames_waited": 0,
		"stage": 0 # 0=Trees, 1=Grass, 2=Rocks
	})

func _cleanup_chunk_trees(coord: Vector2i):
	if chunk_tree_data.has(coord):
		# Return colliders to pool
		var data = chunk_tree_data[coord]
		for tree in data.trees:
			var key = _tree_key(coord, tree.index)
			if active_collider_rids.has(key):
				_free_collider_rid(key)
		chunk_tree_data.erase(coord)

func _cleanup_chunk_grass(coord: Vector2i):
	if chunk_grass_data.has(coord):
		var data = chunk_grass_data[coord]
		for grass in data.grass_list:
			var key = _grass_key(coord, grass.index)
			if active_collider_rids.has(key):
				_free_collider_rid(key)
		chunk_grass_data.erase(coord)

func _cleanup_chunk_rocks(coord: Vector2i):
	if chunk_rock_data.has(coord):
		var data = chunk_rock_data[coord]
		for rock in data.rock_list:
			var key = _rock_key(coord, rock.index)
			if active_collider_rids.has(key):
				_free_collider_rid(key)
		chunk_rock_data.erase(coord)

func _physics_process(_delta):
	# Process only ONE pending chunk per physics frame (rate limited)
	if not pending_chunks.is_empty():
		var item = pending_chunks[0]
		
		# Wait 5 frames for colliders before starting anything
		if item.frames_waited < 5:
			item.frames_waited += 1
			return # Wait
			
		if is_instance_valid(item.chunk_node):
			# Stage 0: Trees
			if item.stage == 0:
				PerformanceMonitor.start_measure("Veg Spawn: Trees")
				_place_vegetation_for_chunk(item.coord, item.chunk_node)
				PerformanceMonitor.end_measure("Veg Spawn: Trees", 2.0)
				item.stage = 1
				return # Done for this frame
				
			# Stage 1: Grass
			if item.stage == 1:
				PerformanceMonitor.start_measure("Veg Spawn: Grass")
				_place_grass_for_chunk(item.coord, item.chunk_node)
				PerformanceMonitor.end_measure("Veg Spawn: Grass", 2.0)
				item.stage = 2
				return # Done for this frame
				
			# Stage 2: Rocks
			if item.stage == 2:
				PerformanceMonitor.start_measure("Veg Spawn: Rocks")
				_place_rocks_for_chunk(item.coord, item.chunk_node)
				PerformanceMonitor.end_measure("Veg Spawn: Rocks", 2.0)
				
				# All stages done
				pending_chunks.pop_front()
				return # Done for this frame
		else:
			# Invalid chunk, remove
			pending_chunks.pop_front()
			return
	
	# Only update colliders if we didn't just place vegetation (spread work)
	collider_update_counter += 1
	if collider_update_counter >= 15:  # Increased from 10 to reduce work
		collider_update_counter = 0
		
		if enable_vegetation_collisions:
			PerformanceMonitor.start_measure("Veg Collider Update")
			_update_proximity_colliders()
			_update_grass_proximity_colliders()
			_update_rock_proximity_colliders()
			_cleanup_orphan_colliders()  # Clean up any stranded colliders
			PerformanceMonitor.end_measure("Veg Collider Update", 2.0)
	
	# Always process incremental updates (Add/Remove actual nodes)
	PerformanceMonitor.start_measure("Veg: Coll Queue")
	_process_queued_collider_updates()
	PerformanceMonitor.end_measure("Veg: Coll Queue", 0.1)
	
	# Process pending placements (retry when chunk becomes valid)
	PerformanceMonitor.start_measure("Veg: Pending Check")
	_process_pending_placements()
	PerformanceMonitor.end_measure("Veg: Pending Check", 0.1)

func _process_pending_placements():
	if not terrain_manager: return
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	
	# Process pending rock placements
	var completed_rocks = []
	for i in range(pending_rock_placements.size()):
		var placement = pending_rock_placements[i]
		var coord = Vector2i(int(floor(placement.world_pos.x / chunk_stride)), int(floor(placement.world_pos.z / chunk_stride)))
		
		# Check if chunk loaded using new data
		if chunk_rock_data.has(coord):
			var data = chunk_rock_data[coord]
			# Assuming chunk is valid if data exists (simplification)
			if _add_rock_to_chunk(placement.world_pos, placement.scale, placement.rotation, coord):
				completed_rocks.append(i)
				print("Retry: Added pending rock to chunk ", coord)
	
	# Remove completed placements (reverse order)
	for i in range(completed_rocks.size() - 1, -1, -1):
		pending_rock_placements.remove_at(completed_rocks[i])
	
	# Process pending grass placements
	var completed_grass = []
	for i in range(pending_grass_placements.size()):
		var placement = pending_grass_placements[i]
		var coord = Vector2i(int(floor(placement.world_pos.x / chunk_stride)), int(floor(placement.world_pos.z / chunk_stride)))
		
		if chunk_grass_data.has(coord):
			if _add_grass_to_chunk(placement.world_pos, placement.scale, placement.rotation, coord):
				completed_grass.append(i)
				print("Retry: Added pending grass to chunk ", coord)
	
	for i in range(completed_grass.size() - 1, -1, -1):
		pending_grass_placements.remove_at(completed_grass[i])

# ============ RID-BASED COLLIDER MANAGEMENT ============

func _process_queued_collider_updates():
	# Add batch
	var added_count = 0
	while not pending_collider_adds.is_empty() and added_count < MAX_COLLIDER_UPDATES_PER_FRAME:
		var update = pending_collider_adds.pop_front()
		keys_pending_add.erase(update.key)
		
		# Double check it wasn't removed in the meantime or already added
		if not active_collider_rids.has(update.key) and enable_vegetation_collisions:
			if update.type == "tree":
				_spawn_tree_rid(update.key, update.item)
			elif update.type == "grass":
				_spawn_grass_rid(update.key, update.item)
			elif update.type == "rock":
				_spawn_rock_rid(update.key, update.item)
			added_count += 1
	
	# Remove batch
	var removed_count = 0
	while not pending_collider_removes.is_empty() and removed_count < MAX_COLLIDER_UPDATES_PER_FRAME:
		var update = pending_collider_removes.pop_front()
		keys_pending_remove.erase(update.key)
		
		if active_collider_rids.has(update.key):
			_free_collider_rid(update.key)
			removed_count += 1

func _spawn_tree_rid(key: String, item: Dictionary):
	if active_collider_rids.has(key): return
	
	var pos = item.tree.hit_pos
	# Create Body
	var body = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	
	# Add Shape
	PhysicsServer3D.body_add_shape(body, shape_rid_tree)
	
	# Transform
	var xform = Transform3D(Basis(), pos + Vector3(0, collision_height/2.0, 0))
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
	
	# Layer/Mask (Tree Group?)
	# Reverting to Layer 1 (Default) so Player collides with them.
	# Also ensures standard raycasting hits them.
	PhysicsServer3D.body_set_collision_layer(body, 1)
	PhysicsServer3D.body_set_collision_mask(body, 1)
	
	# Space
	PhysicsServer3D.body_set_space(body, get_world_3d().space)
	
	# Store
	active_collider_rids[key] = body
	rid_to_key_map[body] = key

func _spawn_grass_rid(key: String, item: Dictionary):
	if active_collider_rids.has(key): return
	# Grass is usually an Area trigger, but for simplicity let's use Static Body for interaction detection?
	# Or Area? Original code used Area3D.
	# Let's use Area for grass/rocks to match "Trigger" behavior if needed, or Body if we just want raycast hit.
	# Player interaction raycast collides with Areas (collide_with_areas=true).
	
	var area = PhysicsServer3D.area_create()
	PhysicsServer3D.area_add_shape(area, shape_rid_grass)
	
	var xform = Transform3D(Basis(), item.grass.hit_pos + Vector3(0, grass_collision_height/2.0, 0))
	PhysicsServer3D.area_set_transform(area, xform)
	
	PhysicsServer3D.area_set_collision_layer(area, 1) 
	PhysicsServer3D.area_set_collision_mask(area, 1)
	PhysicsServer3D.area_set_space(area, get_world_3d().space)
	
	active_collider_rids[key] = area
	rid_to_key_map[area] = key

func _spawn_rock_rid(key: String, item: Dictionary):
	if active_collider_rids.has(key): return
	
	var area = PhysicsServer3D.area_create() # Rocks as Areas? Or Colliders?
	# Original code uses "active_rock_colliders" -> Area3D (inferred from variable name).
	# Let's stick to Area for now if they are just for harvesting.
	
	PhysicsServer3D.area_add_shape(area, shape_rid_rock)
	
	var xform = Transform3D(Basis(), item.rock.hit_pos + Vector3(0, rock_collision_height/2.0, 0))
	PhysicsServer3D.area_set_transform(area, xform)
	
	PhysicsServer3D.area_set_collision_layer(area, 1)
	PhysicsServer3D.area_set_collision_mask(area, 1)
	PhysicsServer3D.area_set_space(area, get_world_3d().space)
	
	active_collider_rids[key] = area
	rid_to_key_map[area] = key

func _free_collider_rid(key: String):
	if active_collider_rids.has(key):
		var rid = active_collider_rids[key]
		if rid.is_valid():
			# Check if body or area (PhysicsServer3D doesn't distinguish interactively easily, but free_rid works for both)
			PhysicsServer3D.free_rid(rid)
		
		active_collider_rids.erase(key)
		rid_to_key_map.erase(rid)

# Interaction Helper
func get_item_key_from_rid(rid: RID) -> String:
	return rid_to_key_map.get(rid, "")

func _cleanup_orphan_colliders():
	# Simplified cleanup - iterate keys and verify chunk existence
	# (For now, just rely on proximity updates)
	pass

var collider_update_counter: int = 0

func _update_proximity_colliders():
	if not player:
		player = get_tree().get_first_node_in_group("player")
		if not player:
			print("VegetationManager: Player not found in 'player' group!")
			return
	
	var player_pos = player.global_position
	var dist_sq = collider_distance * collider_distance
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var chunk_check_dist = collider_distance + chunk_stride  # Only check nearby chunks
	
	# Collect trees that need colliders (only from nearby chunks)
	var trees_needing_colliders: Array[Dictionary] = []
	
	# Optimized: Check only 3x3 chunks around player instead of iterating all loaded chunks
	var player_chunk_x = int(floor(player_pos.x / chunk_stride))
	var player_chunk_z = int(floor(player_pos.z / chunk_stride))
	
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var coord = Vector2i(player_chunk_x + dx, player_chunk_z + dz)
			
			if not chunk_tree_data.has(coord):
				continue
		
			var data = chunk_tree_data[coord]
			for tree in data.trees:
				if not tree.alive:
					continue
				
				var tree_dist_sq = player_pos.distance_squared_to(tree.world_pos)
				if tree_dist_sq < dist_sq:
					trees_needing_colliders.append({
						"coord": coord,
						"tree": tree,
						"dist_sq": tree_dist_sq
					})
	
	# Sort by distance (closest first)
	trees_needing_colliders.sort_custom(func(a, b): return a.dist_sq < b.dist_sq)
	
	# Limit to MAX_ACTIVE_COLLIDERS
	var wanted_keys: Dictionary = {}
	for i in range(min(trees_needing_colliders.size(), MAX_ACTIVE_COLLIDERS)):
		var item = trees_needing_colliders[i]
		var key = _tree_key(item.coord, item.tree.index)
		wanted_keys[key] = item
	
	# Remove colliders that are no longer needed
	var keys_to_remove = []
	for key in active_collider_rids:
		if not wanted_keys.has(key):
			keys_to_remove.append(key)
	
	for key in keys_to_remove:
		if not keys_pending_remove.has(key):
			pending_collider_removes.append({"type": "tree", "key": key})
			keys_pending_remove[key] = true
	
	# Add colliders for trees that need them
	for key in wanted_keys:
		if not active_collider_rids.has(key) and not keys_pending_add.has(key):
			var item = wanted_keys[key]
			pending_collider_adds.append({"type": "tree", "key": key, "item": item})
			keys_pending_add[key] = true

func _tree_key(coord: Vector2i, index: int) -> String:
	return "%d_%d_%d" % [coord.x, coord.y, index]

@export var debug_collision: bool = false

# ========== GRASS HELPER FUNCTIONS ==========

func _grass_key(coord: Vector2i, index: int) -> String:
	return "g_%d_%d_%d" % [coord.x, coord.y, index]

func _update_grass_proximity_colliders():
	if not player:
		return
	
	var player_pos = player.global_position
	var dist_sq = collider_distance * collider_distance
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var chunk_check_dist = collider_distance + chunk_stride
	
	# Collect grass that needs colliders
	var grass_needing_colliders: Array[Dictionary] = []
	
	# Optimized: Check only 3x3 chunks around player
	var player_chunk_x = int(floor(player_pos.x / chunk_stride))
	var player_chunk_z = int(floor(player_pos.z / chunk_stride))
	
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var coord = Vector2i(player_chunk_x + dx, player_chunk_z + dz)
			
			if not chunk_grass_data.has(coord):
				continue

			# Extra Optimization: Check dist to chunk center to skip iterating thousands of grass blades
			var chunk_center_x = (coord.x + 0.5) * chunk_stride
			var chunk_center_z = (coord.y + 0.5) * chunk_stride
			var center_dist = Vector2(player_pos.x, player_pos.z).distance_to(Vector2(chunk_center_x, chunk_center_z))
			# Safe radius = Stride * 0.71 (approx 23m) + margin
			if center_dist > collider_distance + 25.0:
				continue
		
			var data = chunk_grass_data[coord]
			for grass in data.grass_list:
				if not grass.alive:
					continue
				
				var grass_dist_sq = player_pos.distance_squared_to(grass.world_pos)
				if grass_dist_sq < dist_sq:
					grass_needing_colliders.append({
						"coord": coord,
						"grass": grass,
						"dist_sq": grass_dist_sq
					})
	
	# Sort by distance (closest first)
	grass_needing_colliders.sort_custom(func(a, b): return a.dist_sq < b.dist_sq)
	
	# Limit to MAX_ACTIVE_GRASS_COLLIDERS
	var wanted_keys: Dictionary = {}
	for i in range(min(grass_needing_colliders.size(), MAX_ACTIVE_GRASS_COLLIDERS)):
		var item = grass_needing_colliders[i]
		var key = _grass_key(item.coord, item.grass.index)
		wanted_keys[key] = item
	
	# Remove colliders that are no longer needed
	var keys_to_remove = []
	for key in active_collider_rids: # Check all active RIDs, not just grass
		if key.begins_with("g_") and not wanted_keys.has(key):
			keys_to_remove.append(key)
	
	for key in keys_to_remove:
		if not keys_pending_remove.has(key):
			pending_collider_removes.append({"type": "grass", "key": key})
			keys_pending_remove[key] = true
	
	# Add colliders for grass that needs them
	for key in wanted_keys:
		if not active_collider_rids.has(key) and not keys_pending_add.has(key):
			var item = wanted_keys[key]
			pending_collider_adds.append({"type": "grass", "key": key, "item": item})
			keys_pending_add[key] = true

# ========== ROCK HELPER FUNCTIONS ==========

func _rock_key(coord: Vector2i, index: int) -> String:
	return "r_%d_%d_%d" % [coord.x, coord.y, index]

func _update_rock_proximity_colliders():
	if not player:
		return
	
	var player_pos = player.global_position
	var dist_sq = collider_distance * collider_distance
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var chunk_check_dist = collider_distance + chunk_stride
	
	var rocks_needing_colliders: Array[Dictionary] = []
	
	# Optimized: Check only 3x3 chunks around player
	var player_chunk_x = int(floor(player_pos.x / chunk_stride))
	var player_chunk_z = int(floor(player_pos.z / chunk_stride))
	
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var coord = Vector2i(player_chunk_x + dx, player_chunk_z + dz)
			
			if not chunk_rock_data.has(coord):
				continue
		
			var data = chunk_rock_data[coord]
			for rock in data.rock_list:
				if not rock.alive:
					continue
				
				var rock_dist_sq = player_pos.distance_squared_to(rock.world_pos)
				if rock_dist_sq < dist_sq:
					rocks_needing_colliders.append({
						"coord": coord,
						"rock": rock,
						"dist_sq": rock_dist_sq
					})
	
	rocks_needing_colliders.sort_custom(func(a, b): return a.dist_sq < b.dist_sq)
	
	var wanted_keys: Dictionary = {}
	for i in range(min(rocks_needing_colliders.size(), MAX_ACTIVE_ROCK_COLLIDERS)):
		var item = rocks_needing_colliders[i]
		var key = _rock_key(item.coord, item.rock.index)
		wanted_keys[key] = item
	
	var keys_to_remove = []
	for key in active_collider_rids: # Check all active RIDs, not just rocks
		if key.begins_with("r_") and not wanted_keys.has(key):
			keys_to_remove.append(key)
	
	for key in keys_to_remove:
		if not keys_pending_remove.has(key):
			pending_collider_removes.append({"type": "rock", "key": key})
			keys_pending_remove[key] = true
	
	for key in wanted_keys:
		if not active_collider_rids.has(key) and not keys_pending_add.has(key):
			var item = wanted_keys[key]
			pending_collider_adds.append({"type": "rock", "key": key, "item": item})
			keys_pending_add[key] = true

func _place_vegetation_for_chunk(coord: Vector2i, chunk_node: Node3D):
	var mmi = MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.mesh = tree_mesh
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	
	var tree_list = []
	var valid_transforms = []
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var chunk_origin_x = coord.x * chunk_stride
	var chunk_origin_z = coord.y * chunk_stride
	var chunk_world_pos = chunk_node.global_position
	
	# Use density lookup instead of physics raycasting (much faster)
	# Use density lookup instead of physics raycasting (much faster)
	var step = 4
	
	var batch_heights = PackedFloat32Array()
	var batch_idx = 0
	
	# Try GDExtension batch lookup (Instant)
	if terrain_manager.get("terrain_grid"):
		if terrain_manager.active_chunks.has(Vector3i(coord.x, 0, coord.y)):
			var c_data = terrain_manager.active_chunks[Vector3i(coord.x, 0, coord.y)]
			if c_data and not c_data.cpu_density_terrain.is_empty():
				batch_heights = terrain_manager.terrain_grid.get_chunk_height_map(c_data.cpu_density_terrain, chunk_stride, step)

	for x in range(0, chunk_stride, step):
		for z in range(0, chunk_stride, step):
			var gx = chunk_origin_x + x
			var gz = chunk_origin_z + z
			
			var noise_val = forest_noise.get_noise_2d(gx, gz)
			if noise_val < 0.4:
				# Sync index even if skipping
				if not batch_heights.is_empty(): batch_idx += 1
				continue
			
			# Use optimized chunk density lookup
			var terrain_y = -1000.0
			if not batch_heights.is_empty():
				# Use batch result
				if batch_idx < batch_heights.size():
					terrain_y = batch_heights[batch_idx]
				batch_idx += 1
			else:
				# Slow fallback
				terrain_y = terrain_manager.get_chunk_surface_height(Vector3i(coord.x, 0, coord.y), x, z)
				
			if terrain_y < -100.0:  # No terrain found
				continue
			
			var hit_pos = Vector3(gx, terrain_y, gz)
			
			# Skip if underwater (Optimized: Simple check against water level for Infinite Plane)
			if terrain_y + 1.0 < terrain_manager.water_level:
				continue
			
			var local_pos = hit_pos - chunk_world_pos
			local_pos.y += tree_y_offset
			
			var world_pos = hit_pos
			world_pos.y += tree_y_offset
			
			var random_scale = randf_range(0.8, 1.2)
			var final_scale = tree_scale * random_scale
			var rotation_angle = randf() * TAU
			
			# Start with GLB's base transform (includes orientation fix)
			var t = tree_base_transform
			# Apply manual rotation fix
			t.basis = t.basis * Basis.from_euler(tree_rotation_fix)
			# Apply random Y rotation
			t = t.rotated(Vector3.UP, rotation_angle)
			# Apply scaling
			t = t.scaled(Vector3(final_scale, final_scale, final_scale))
			t.origin = local_pos
			
			valid_transforms.append(t)
			
			var tree_index = valid_transforms.size() - 1
			tree_list.append({
				"world_pos": world_pos,
				"local_pos": local_pos,
				"hit_pos": hit_pos, # Raw ground position (World)
				"rotation_angle": rotation_angle,
				"random_scale_factor": random_scale,
				"index": tree_index,
				"alive": true,
				"scale": final_scale
			})

	
	if valid_transforms.size() > 0:
		mmi.multimesh.instance_count = valid_transforms.size()
		for i in range(valid_transforms.size()):
			mmi.multimesh.set_instance_transform(i, valid_transforms[i])
		chunk_node.add_child(mmi)
	
	chunk_tree_data[coord] = {
		"multimesh": mmi,
		"trees": tree_list,
		"chunk_node": chunk_node
	}
	
	# Apply chopped_trees filter - hide trees that were previously chopped
	for tree in tree_list:
		var persist_key = "%d_%d" % [int(tree.world_pos.x), int(tree.world_pos.z)]
		if chopped_trees.has(persist_key):
			tree.alive = false
			# Hide in MultiMesh
			var t = Transform3D()
			t = t.scaled(Vector3.ZERO)
			t.origin = tree.local_pos
			mmi.multimesh.set_instance_transform(tree.index, t)

func chop_tree_by_collider(rid: RID) -> bool:
	# Check if collider is still valid (not freed)
	if not rid.is_valid():
		return false
	
	var key = get_item_key_from_rid(rid)
	if key.is_empty() or not key.begins_with("t_"): # Assuming tree keys start with "t_"
		return false
	
	var parts = key.split("_")
	if parts.size() != 3: return false
	
	var coord = Vector2i(parts[0].to_int(), parts[1].to_int())
	var tree_index = parts[2].to_int()
	
	if not chunk_tree_data.has(coord):
		return false
	
	var data = chunk_tree_data[coord]
	for tree in data.trees:
		if tree.index == tree_index and tree.alive:
			tree.alive = false
			
			# Add to chopped_trees for persistence across chunk unloads
			var persist_key = "%d_%d" % [int(tree.world_pos.x), int(tree.world_pos.z)]
			chopped_trees[persist_key] = true
			
			# Hide in MultiMesh
			var mmi = data.multimesh as MultiMeshInstance3D
			if mmi and mmi.multimesh:
				var t = Transform3D()
				t = t.scaled(Vector3.ZERO)
				t.origin = tree.local_pos
				mmi.multimesh.set_instance_transform(tree.index, t)
			
			# Remove collider
			_free_collider_rid(key)
			
			tree_chopped.emit(tree.world_pos)
			return true
	
	return false

## Clear all vegetation (trees, grass, rocks) within a radius of a world position
## Used by prefab spawner to ensure buildings don't overlap vegetation
func clear_vegetation_in_area(center: Vector3, radius: float):
	var radius_sq = radius * radius
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	
	# Clear trees
	for coord in chunk_tree_data:
		var data = chunk_tree_data[coord]
		var modified = false
		for tree in data.trees:
			if not tree.alive:
				continue
			var dist_sq = Vector2(tree.world_pos.x, tree.world_pos.z).distance_squared_to(Vector2(center.x, center.z))
			if dist_sq < radius_sq:
				tree.alive = false
				modified = true
				# Hide in MultiMesh
				var mmi = data.multimesh as MultiMeshInstance3D
				if mmi and mmi.multimesh:
					var t = Transform3D()
					t = t.scaled(Vector3.ZERO)
					t.origin = tree.local_pos
					mmi.multimesh.set_instance_transform(tree.index, t)
				# Remove collider
				var key = _tree_key(coord, tree.index)
				if active_collider_rids.has(key):
					_free_collider_rid(key)
	
	# Clear grass
	for coord in chunk_grass_data:
		var data = chunk_grass_data[coord]
		for grass in data.grass_list:
			if not grass.alive:
				continue
			var dist_sq = Vector2(grass.world_pos.x, grass.world_pos.z).distance_squared_to(Vector2(center.x, center.z))
			if dist_sq < radius_sq:
				grass.alive = false
				var mmi = data.multimesh as MultiMeshInstance3D
				if mmi and mmi.multimesh:
					var t = Transform3D()
					t = t.scaled(Vector3.ZERO)
					t.origin = grass.local_pos
					mmi.multimesh.set_instance_transform(grass.index, t)
				var key = _grass_key(coord, grass.index)
				if active_collider_rids.has(key):
					_free_collider_rid(key)
	
	# Clear rocks
	for coord in chunk_rock_data:
		var data = chunk_rock_data[coord]
		for rock in data.rock_list:
			if not rock.alive:
				continue
			var dist_sq = Vector2(rock.world_pos.x, rock.world_pos.z).distance_squared_to(Vector2(center.x, center.z))
			if dist_sq < radius_sq:
				rock.alive = false
				var mmi = data.multimesh as MultiMeshInstance3D
				if mmi and mmi.multimesh:
					var t = Transform3D()
					t = t.scaled(Vector3.ZERO)
					t.origin = rock.local_pos
					mmi.multimesh.set_instance_transform(rock.index, t)
				var key = _rock_key(coord, rock.index)
				if active_collider_rids.has(key):
					_free_collider_rid(key)

# ========== GRASS SPAWNING AND HARVESTING ==========

func _place_grass_for_chunk(coord: Vector2i, chunk_node: Node3D):
	if not grass_mesh:
		return
	
	var mmi = MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.mesh = grass_mesh
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	
	# Fix distance visibility issues
	mmi.extra_cull_margin = 1000.0  # Very large margin
	mmi.ignore_occlusion_culling = true  # Ignore occlusion
	mmi.lod_bias = 100.0  # Prevent LOD from hiding mesh
	mmi.visibility_range_end = 0.0  # 0 = infinite visibility
	
	var grass_list = []
	var valid_transforms = []
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var chunk_origin_x = coord.x * chunk_stride
	var chunk_origin_z = coord.y * chunk_stride
	var chunk_world_pos = chunk_node.global_position
	
	var space_state = get_world_3d().direct_space_state
	
	# Grass placement - mode determines density and distribution
	# Optimized: step 2 reduces checks by 4x (256 vs 1024) - acceptable for grass
	var step = 2 
	if dense_grass_mode: step = 1 # Use stride 1 for dense mode if requested
	
	var batch_heights = PackedFloat32Array()
	var batch_idx = 0
	
	# Try GDExtension batch lookup (Instant)
	if terrain_manager.get("terrain_grid"): # Check if property exists
		if terrain_manager.active_chunks.has(Vector3i(coord.x, 0, coord.y)):
			var c_data = terrain_manager.active_chunks[Vector3i(coord.x, 0, coord.y)]
			if c_data and not c_data.cpu_density_terrain.is_empty():
				# Call C++ method
				batch_heights = terrain_manager.terrain_grid.get_chunk_height_map(c_data.cpu_density_terrain, chunk_stride, step)
	
	for x in range(0, chunk_stride, step):
		for z in range(0, chunk_stride, step):
			var gx = chunk_origin_x + x
			var gz = chunk_origin_z + z
			
			# Default mode: use noise for patchy distribution
			# Dense mode: skip noise check for even distribution everywhere
			if not dense_grass_mode:
				var noise_val = grass_noise.get_noise_2d(gx, gz)
				if noise_val < 0.3:
					# Skip index if using batch (sync index)
					if not batch_heights.is_empty(): batch_idx += 1
					continue
			
			# Use optimized chunk density lookup
			var terrain_y = -1000.0
			if not batch_heights.is_empty():
				if batch_idx < batch_heights.size():
					terrain_y = batch_heights[batch_idx]
				batch_idx += 1
			else:
				# Slow fallback
				terrain_y = terrain_manager.get_chunk_surface_height(Vector3i(coord.x, 0, coord.y), x, z)
				
			if terrain_y < -100.0:  # No terrain found
				continue
			
			var hit_pos = Vector3(gx, terrain_y, gz)
			
			# Skip if this grass was previously removed
			var pos_hash = _position_hash(hit_pos)
			if removed_grass.has(pos_hash):
				continue
			
			# Skip if underwater
			var water_dens = terrain_manager.get_water_density(Vector3(gx, terrain_y + 0.5, gz))
			if water_dens < 0.0:
				continue
			
			var local_pos = hit_pos - chunk_world_pos
			local_pos.y += grass_y_offset
			
			var world_pos = hit_pos
			world_pos.y += grass_y_offset
			
			var random_scale = randf_range(0.8, 1.2)
			var final_scale = grass_scale * random_scale
			var rotation_angle = randf() * TAU
			
			var t = grass_base_transform
			t = t.rotated(Vector3.UP, rotation_angle)
			t = t.scaled(Vector3(final_scale, final_scale, final_scale))
			t.origin = local_pos
			
			valid_transforms.append(t)
			
			var grass_index = valid_transforms.size() - 1
			grass_list.append({
				"world_pos": world_pos,
				"local_pos": local_pos,
				"hit_pos": hit_pos,
				"rotation_angle": rotation_angle,
				"index": grass_index,
				"alive": true,
				"scale": final_scale,
				"placed_by_player": false
			})
	
	# Add player-placed grass for this chunk
	for placed in placed_grass:
		var placed_coord = Vector2i(int(floor(placed.world_pos.x / chunk_stride)), int(floor(placed.world_pos.z / chunk_stride)))
		if placed_coord == coord:
			var local_pos = placed.world_pos - chunk_world_pos
			local_pos.y += grass_y_offset
			
			var t = grass_base_transform
			t = t.rotated(Vector3.UP, placed.rotation)
			t = t.scaled(Vector3(placed.scale, placed.scale, placed.scale))
			t.origin = local_pos
			
			valid_transforms.append(t)
			
			var grass_index = valid_transforms.size() - 1
			grass_list.append({
				"world_pos": placed.world_pos,
				"local_pos": local_pos,
				"hit_pos": placed.world_pos,
				"rotation_angle": placed.rotation,
				"index": grass_index,
				"alive": true,
				"scale": placed.scale,
				"placed_by_player": true
			})
	
	if valid_transforms.size() > 0:
		mmi.multimesh.instance_count = valid_transforms.size()
		for i in range(valid_transforms.size()):
			mmi.multimesh.set_instance_transform(i, valid_transforms[i])
	
	# ALWAYS add to chunk and store data, even if empty (so player can place grass here)
	chunk_node.add_child(mmi)
	
	chunk_grass_data[coord] = {
		"multimesh": mmi,
		"grass_list": grass_list,
		"chunk_node": chunk_node
	}

func harvest_grass_by_collider(rid: RID) -> bool:
	# Check if collider is still valid (not freed)
	if not rid.is_valid():
		return false
	
	var key = get_item_key_from_rid(rid)
	if key.is_empty() or not key.begins_with("g_"):
		return false
		
	var parts = key.split("_")
	if parts.size() != 4: return false
	
	var coord = Vector2i(parts[1].to_int(), parts[2].to_int())
	var grass_index = parts[3].to_int()
	
	if not chunk_grass_data.has(coord):
		return false
	
	var data = chunk_grass_data[coord]
	
	# Validate that data is still valid
	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		# Chunk was freed, but we can still store removal for persistence
		for grass in data.grass_list:
			if grass.index == grass_index and grass.alive:
				grass.alive = false
				var pos_hash = _position_hash(grass.world_pos)
				removed_grass[pos_hash] = true
				grass_harvested.emit(grass.world_pos)
				return true
		return false
	
	for grass in data.grass_list:
		if grass.index == grass_index and grass.alive:
			grass.alive = false
			
			# Store removal for persistence (using position hash)
			var pos_hash = _position_hash(grass.world_pos)
			removed_grass[pos_hash] = true
			
			# Hide in MultiMesh (only if valid)
			if data.has("multimesh") and is_instance_valid(data.multimesh):
				var mmi = data.multimesh as MultiMeshInstance3D
				if mmi and mmi.multimesh:
					var t = Transform3D()
					t = t.scaled(Vector3.ZERO)
					t.origin = grass.local_pos
					mmi.multimesh.set_instance_transform(grass.index, t)
			
			# Remove collider
			# key is already defined at top of function
			if active_collider_rids.has(key):
				_free_collider_rid(key)
			
			grass_harvested.emit(grass.world_pos)
			return true
	
	return false

# Helper to create position hash for persistence
func _position_hash(pos: Vector3) -> String:
	return "%d_%d" % [int(pos.x), int(pos.z)]

func place_grass(world_pos: Vector3) -> bool:
	# Find which chunk this position belongs to
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var coord = Vector2i(floor(world_pos.x / chunk_stride), floor(world_pos.z / chunk_stride))
	
	var random_scale = randf_range(0.8, 1.2)
	var final_scale = grass_scale * random_scale
	var rotation_angle = randf() * TAU
	
	# Always store for persistence first
	placed_grass.append({
		"world_pos": world_pos,
		"scale": final_scale,
		"rotation": rotation_angle
	})
	print("Stored grass placement at ", world_pos, " for persistence")
	
	# Check if we can place immediately
	if not chunk_grass_data.has(coord):
		print("Chunk grass data not ready - queuing for retry")
		pending_grass_placements.append({"world_pos": world_pos, "scale": final_scale, "rotation": rotation_angle})
		return true  # Stored for later
	
	var data = chunk_grass_data[coord]
	
	# Validate chunk_node
	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		print("Chunk node not valid - queuing for retry")
		pending_grass_placements.append({"world_pos": world_pos, "scale": final_scale, "rotation": rotation_angle})
		return true  # Stored for later
	
	var chunk_node = data.chunk_node
	var chunk_world_pos = chunk_node.global_position
	var local_pos = world_pos - chunk_world_pos
	local_pos.y += grass_y_offset
	
	var t = grass_base_transform
	t = t.rotated(Vector3.UP, rotation_angle)
	t = t.scaled(Vector3(final_scale, final_scale, final_scale))
	t.origin = local_pos
	
	# Add to MultiMesh - need to expand instance count
	if not data.has("multimesh") or not is_instance_valid(data.multimesh):
		print("MultiMesh not valid - queuing for retry")
		pending_grass_placements.append({"world_pos": world_pos, "scale": final_scale, "rotation": rotation_angle})
		return true  # Stored for later
	
	var mmi = data.multimesh as MultiMeshInstance3D
	if mmi and mmi.multimesh:
		var old_count = mmi.multimesh.instance_count
		
		# IMPORTANT: Save existing transforms before resizing (Godot resets them)
		var old_transforms = []
		for i in range(old_count):
			old_transforms.append(mmi.multimesh.get_instance_transform(i))
		
		# Resize and restore
		mmi.multimesh.instance_count = old_count + 1
		for i in range(old_count):
			mmi.multimesh.set_instance_transform(i, old_transforms[i])
		
		# Add new instance
		mmi.multimesh.set_instance_transform(old_count, t)
		
		var grass_entry = {
			"world_pos": world_pos + Vector3(0, grass_y_offset, 0),
			"local_pos": local_pos,
			"hit_pos": world_pos,
			"rotation_angle": rotation_angle,
			"index": old_count,
			"alive": true,
			"scale": final_scale,
			"placed_by_player": true
		}
		data.grass_list.append(grass_entry)
		
		print("Placed grass immediately at ", world_pos)
		return true
	
	return true  # Already stored for persistence

func _add_grass_to_chunk(world_pos: Vector3, final_scale: float, rotation_angle: float, coord: Vector2i) -> bool:
	"""Helper to add a grass instance to an existing chunk."""
	if not chunk_grass_data.has(coord):
		return false
	
	var data = chunk_grass_data[coord]
	
	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		return false
	
	if not data.has("multimesh") or not is_instance_valid(data.multimesh):
		return false
	
	var chunk_node = data.chunk_node
	var chunk_world_pos = chunk_node.global_position
	var local_pos = world_pos - chunk_world_pos
	local_pos.y += grass_y_offset
	
	var t = grass_base_transform
	t = t.rotated(Vector3.UP, rotation_angle)
	t = t.scaled(Vector3(final_scale, final_scale, final_scale))
	t.origin = local_pos
	
	var mmi = data.multimesh as MultiMeshInstance3D
	if mmi and mmi.multimesh:
		var old_count = mmi.multimesh.instance_count
		
		# Save existing transforms before resizing (Godot resets them)
		var old_transforms = []
		for i in range(old_count):
			old_transforms.append(mmi.multimesh.get_instance_transform(i))
		
		# Resize and restore
		mmi.multimesh.instance_count = old_count + 1
		for i in range(old_count):
			mmi.multimesh.set_instance_transform(i, old_transforms[i])
		
		# Add new instance
		mmi.multimesh.set_instance_transform(old_count, t)
		
		var grass_entry = {
			"world_pos": world_pos + Vector3(0, grass_y_offset, 0),
			"local_pos": local_pos,
			"hit_pos": world_pos,
			"rotation_angle": rotation_angle,
			"index": old_count,
			"alive": true,
			"scale": final_scale,
			"placed_by_player": true
		}
		data.grass_list.append(grass_entry)
		return true
	
	return false

# ========== ROCK SPAWNING AND HARVESTING ==========

func _place_rocks_for_chunk(coord: Vector2i, chunk_node: Node3D):
	if not rock_mesh:
		return
	
	var mmi = MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.mesh = rock_mesh
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	
	var rock_list = []
	var valid_transforms = []
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var chunk_origin_x = coord.x * chunk_stride
	var chunk_origin_z = coord.y * chunk_stride
	var chunk_world_pos = chunk_node.global_position
	
	# Use density lookup instead of physics raycasting (much faster)
	# Sparse rocks - every 7 meters (less frequent than grass)
	for x in range(0, chunk_stride, 7):
		for z in range(0, chunk_stride, 7):
			var gx = chunk_origin_x + x
			var gz = chunk_origin_z + z
			
			var noise_val = rock_noise.get_noise_2d(gx, gz)
			if noise_val < 0.35:  # Slightly higher threshold than grass
				continue
			
			# Use optimized chunk density lookup
			var terrain_y = terrain_manager.get_chunk_surface_height(Vector3i(coord.x, 0, coord.y), x, z)
			if terrain_y < -100.0:  # No terrain found
				continue
			
			var hit_pos = Vector3(gx, terrain_y, gz)
			
			# Skip if this rock was previously removed
			var pos_hash = _position_hash(hit_pos)
			if removed_rocks.has(pos_hash):
				continue
			
			# Skip if underwater
			var water_dens = terrain_manager.get_water_density(Vector3(gx, terrain_y + 0.5, gz))
			if water_dens < 0.0:
				continue
			
			# Note: Slope check removed since we no longer have normal data
			# Rocks can appear on any terrain now
			
			var local_pos = hit_pos - chunk_world_pos
			local_pos.y += rock_y_offset
			
			var world_pos = hit_pos
			world_pos.y += rock_y_offset
			
			var random_scale = randf_range(0.6, 1.4)
			var final_scale = rock_scale * random_scale
			var rotation_angle = randf() * TAU
			
			var t = rock_base_transform
			t = t.rotated(Vector3.UP, rotation_angle)
			t = t.scaled(Vector3(final_scale, final_scale, final_scale))
			t.origin = local_pos
			
			valid_transforms.append(t)
			
			var rock_index = valid_transforms.size() - 1
			rock_list.append({
				"world_pos": world_pos,
				"local_pos": local_pos,
				"hit_pos": hit_pos,
				"rotation_angle": rotation_angle,
				"index": rock_index,
				"alive": true,
				"scale": final_scale,
				"placed_by_player": false
			})
	
	# Add player-placed rocks for this chunk
	for placed in placed_rocks:
		var placed_coord = Vector2i(int(floor(placed.world_pos.x / chunk_stride)), int(floor(placed.world_pos.z / chunk_stride)))
		if placed_coord == coord:
			print("Restoring player-placed rock at ", placed.world_pos, " to chunk ", coord)
			var local_pos = placed.world_pos - chunk_world_pos
			local_pos.y += rock_y_offset
			
			var t = rock_base_transform
			t = t.rotated(Vector3.UP, placed.rotation)
			t = t.scaled(Vector3(placed.scale, placed.scale, placed.scale))
			t.origin = local_pos
			
			valid_transforms.append(t)
			
			var rock_index = valid_transforms.size() - 1
			rock_list.append({
				"world_pos": placed.world_pos,
				"local_pos": local_pos,
				"hit_pos": placed.world_pos,
				"rotation_angle": placed.rotation,
				"index": rock_index,
				"alive": true,
				"scale": placed.scale,
				"placed_by_player": true
			})
	
	if valid_transforms.size() > 0:
		mmi.multimesh.instance_count = valid_transforms.size()
		for i in range(valid_transforms.size()):
			mmi.multimesh.set_instance_transform(i, valid_transforms[i])
	
	print("Placed ", valid_transforms.size(), " rocks in chunk ", coord, " (", placed_rocks.size(), " total in persistence)")
	
	# ALWAYS add to chunk and store data, even if empty (so player can place rocks here)
	chunk_node.add_child(mmi)
	
	chunk_rock_data[coord] = {
		"multimesh": mmi,
		"rock_list": rock_list,
		"chunk_node": chunk_node
	}

func harvest_rock_by_collider(rid: RID) -> bool:
	if not rid.is_valid():
		return false
	
	var key = get_item_key_from_rid(rid)
	if key.is_empty() or not key.begins_with("r_"):
		return false
		
	var parts = key.split("_")
	if parts.size() != 4: return false
	
	var coord = Vector2i(parts[1].to_int(), parts[2].to_int())
	var rock_index = parts[3].to_int()
	
	if not chunk_rock_data.has(coord):
		return false
	
	var data = chunk_rock_data[coord]
	
	# Validate that data is still valid
	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		# Chunk was freed, but we can still store removal for persistence
		for rock in data.rock_list:
			if rock.index == rock_index and rock.alive:
				rock.alive = false
				var pos_hash = _position_hash(rock.world_pos)
				removed_rocks[pos_hash] = true
				rock_harvested.emit(rock.world_pos)
				return true
		return false
	
	for rock in data.rock_list:
		if rock.index == rock_index and rock.alive:
			rock.alive = false
			
			# Store removal for persistence
			var pos_hash = _position_hash(rock.world_pos)
			removed_rocks[pos_hash] = true
			
			# Hide in MultiMesh (only if valid)
			if data.has("multimesh") and is_instance_valid(data.multimesh):
				var mmi = data.multimesh as MultiMeshInstance3D
				if mmi and mmi.multimesh:
					var t = Transform3D()
					t = t.scaled(Vector3.ZERO)
					t.origin = rock.local_pos
					mmi.multimesh.set_instance_transform(rock.index, t)
			
			# Remove collider
			# key is already defined at top of function
			if active_collider_rids.has(key):
				_free_collider_rid(key)
			
			rock_harvested.emit(rock.world_pos)
			return true
	
	return false

func place_rock(world_pos: Vector3) -> bool:
	var chunk_stride = terrain_manager.CHUNK_STRIDE
	var coord = Vector2i(int(floor(world_pos.x / chunk_stride)), int(floor(world_pos.z / chunk_stride)))
	
	var random_scale = randf_range(0.6, 1.4)
	var final_scale = rock_scale * random_scale
	var rotation_angle = randf() * TAU
	
	# Always store for persistence first
	placed_rocks.append({
		"world_pos": world_pos,
		"scale": final_scale,
		"rotation": rotation_angle
	})
	print("Stored rock placement at ", world_pos, " for persistence (", placed_rocks.size(), " total)")
	
	# Check if we can place immediately
	if not chunk_rock_data.has(coord):
		print("Chunk rock data not ready - queuing for retry")
		pending_rock_placements.append({"world_pos": world_pos, "scale": final_scale, "rotation": rotation_angle})
		return true
	
	var data = chunk_rock_data[coord]
	
	# Validate chunk_node
	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		print("Chunk node not valid - queuing for retry")
		pending_rock_placements.append({"world_pos": world_pos, "scale": final_scale, "rotation": rotation_angle})
		return true
	
	# Validate multimesh
	if not data.has("multimesh") or not is_instance_valid(data.multimesh):
		print("MultiMesh not valid - queuing for retry")
		pending_rock_placements.append({"world_pos": world_pos, "scale": final_scale, "rotation": rotation_angle})
		return true
	
	# Can place immediately
	if _add_rock_to_chunk(world_pos, final_scale, rotation_angle, coord):
		print("Placed rock immediately at ", world_pos)
		return true
	
	return true

func _add_rock_to_chunk(world_pos: Vector3, final_scale: float, rotation_angle: float, coord: Vector2i) -> bool:
	"""Helper to add a rock instance to an existing chunk."""
	if not chunk_rock_data.has(coord):
		return false
	
	var data = chunk_rock_data[coord]
	
	if not data.has("chunk_node") or not is_instance_valid(data.chunk_node):
		return false
	
	if not data.has("multimesh") or not is_instance_valid(data.multimesh):
		return false
	
	var chunk_node = data.chunk_node
	var chunk_world_pos = chunk_node.global_position
	var local_pos = world_pos - chunk_world_pos
	local_pos.y += rock_y_offset
	
	var t = rock_base_transform
	t = t.rotated(Vector3.UP, rotation_angle)
	t = t.scaled(Vector3(final_scale, final_scale, final_scale))
	t.origin = local_pos
	
	var mmi = data.multimesh as MultiMeshInstance3D
	if mmi and mmi.multimesh:
		var old_count = mmi.multimesh.instance_count
		
		# Save existing transforms before resizing (Godot resets them)
		var old_transforms = []
		for i in range(old_count):
			old_transforms.append(mmi.multimesh.get_instance_transform(i))
		
		# Resize and restore
		mmi.multimesh.instance_count = old_count + 1
		for i in range(old_count):
			mmi.multimesh.set_instance_transform(i, old_transforms[i])
		
		# Add new instance
		mmi.multimesh.set_instance_transform(old_count, t)
		
		var rock_entry = {
			"world_pos": world_pos + Vector3(0, rock_y_offset, 0),
			"local_pos": local_pos,
			"hit_pos": world_pos,
			"rotation_angle": rotation_angle,
			"index": old_count,
			"alive": true,
			"scale": final_scale,
			"placed_by_player": true
		}
		data.rock_list.append(rock_entry)
		return true
	
	return false

func load_tree_mesh_from_glb(path: String) -> Dictionary:
	var scene = load(path)
	if scene == null:
		push_error("Could not load GLB: " + path)
		return { "mesh": null, "transform": Transform3D() }
	
	var instance = scene.instantiate()
	# Need to add to tree temporarily to get global_transform
	add_child(instance)
	var result = find_mesh_and_transform_in_node(instance)
	instance.queue_free()
	
	if result.mesh:
		print("Loaded tree mesh from: ", path)
		print("Mesh transform: ", result.transform)
	
	return result

func find_mesh_and_transform_in_node(node: Node) -> Dictionary:
	if node is MeshInstance3D:
		return { "mesh": node.mesh, "transform": node.global_transform }
	
	for child in node.get_children():
		var result = find_mesh_and_transform_in_node(child)
		if result.mesh:
			return result
	
	return { "mesh": null, "transform": Transform3D() }

func create_basic_tree_mesh() -> Mesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var trunk_mat = StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.5, 0.2, 0.0)
	st.set_material(trunk_mat)
	
	var trunk_height = 5.0
	var trunk_radius = 0.5
	
	for i in range(8):
		var angle1 = float(i) / 8.0 * PI * 2.0
		var angle2 = float(i+1) / 8.0 * PI * 2.0
		var p1 = Vector3(cos(angle1) * trunk_radius, 0, sin(angle1) * trunk_radius)
		var p2 = Vector3(cos(angle2) * trunk_radius, 0, sin(angle2) * trunk_radius)
		var p3 = Vector3(cos(angle2) * trunk_radius, trunk_height, sin(angle2) * trunk_radius)
		var p4 = Vector3(cos(angle1) * trunk_radius, trunk_height, sin(angle1) * trunk_radius)
		st.add_vertex(p1)
		st.add_vertex(p2)
		st.add_vertex(p3)
		st.add_vertex(p1)
		st.add_vertex(p3)
		st.add_vertex(p4)
	
	var leaves_mat = StandardMaterial3D.new()
	leaves_mat.albedo_color = Color(0.0, 0.5, 0.1)
	st.set_material(leaves_mat)
	
	var leaves_height = 7.0
	var leaves_radius = 3.0
	var leaves_base_y = trunk_height * 0.8
	
	for i in range(8):
		var angle1 = float(i) / 8.0 * PI * 2.0
		var angle2 = float(i+1) / 8.0 * PI * 2.0
		var p1 = Vector3(cos(angle1) * leaves_radius, leaves_base_y, sin(angle1) * leaves_radius)
		var p2 = Vector3(cos(angle2) * leaves_radius, leaves_base_y, sin(angle2) * leaves_radius)
		var p_top = Vector3(0, leaves_base_y + leaves_height, 0)
		st.add_vertex(p1)
		st.add_vertex(p2)
		st.add_vertex(p_top)
	
	st.index()
	return st.commit()

func create_basic_grass_mesh() -> Mesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var grass_mat = StandardMaterial3D.new()
	grass_mat.albedo_color = Color(0.2, 0.6, 0.1)
	grass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(grass_mat)
	
	var height = 0.5
	var width = 0.2
	
	# Simple quad for grass blade
	st.add_vertex(Vector3(-width/2, 0, 0))
	st.add_vertex(Vector3(width/2, 0, 0))
	st.add_vertex(Vector3(0, height, 0))
	
	st.index()
	return st.commit()

func create_basic_rock_mesh() -> Mesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var rock_mat = StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.4, 0.4, 0.4)
	st.set_material(rock_mat)
	
	# Simple octahedron for rock shape
	var size = 0.3
	var top = Vector3(0, size, 0)
	var bottom = Vector3(0, -size * 0.5, 0)
	var front = Vector3(0, 0, size)
	var back = Vector3(0, 0, -size)
	var left = Vector3(-size, 0, 0)
	var right = Vector3(size, 0, 0)
	
	# Top half
	st.add_vertex(top); st.add_vertex(front); st.add_vertex(right)
	st.add_vertex(top); st.add_vertex(right); st.add_vertex(back)
	st.add_vertex(top); st.add_vertex(back); st.add_vertex(left)
	st.add_vertex(top); st.add_vertex(left); st.add_vertex(front)
	
	# Bottom half
	st.add_vertex(bottom); st.add_vertex(right); st.add_vertex(front)
	st.add_vertex(bottom); st.add_vertex(back); st.add_vertex(right)
	st.add_vertex(bottom); st.add_vertex(left); st.add_vertex(back)
	st.add_vertex(bottom); st.add_vertex(front); st.add_vertex(left)
	
	st.index()
	return st.commit()

## Save/Load persistence for vegetation state
func get_save_data() -> Dictionary:
	# Collect all chopped trees from active chunks
	var all_chopped: Array = []
	for coord in chunk_tree_data:
		var data = chunk_tree_data[coord]
		for tree in data.trees:
			if not tree.alive:
				# Store as position hash
				var key = "%d_%d" % [int(tree.world_pos.x), int(tree.world_pos.z)]
				all_chopped.append(key)
	# Also include previously stored chopped trees (from unloaded chunks)
	for key in chopped_trees:
		if key not in all_chopped:
			all_chopped.append(key)
	
	return {
		"removed_grass": removed_grass.keys(),
		"removed_rocks": removed_rocks.keys(),
		"chopped_trees": all_chopped,
		"placed_grass": _serialize_placed_list(placed_grass),
		"placed_rocks": _serialize_placed_list(placed_rocks)
	}

func load_save_data(data: Dictionary):
	if data.has("removed_grass"):
		removed_grass.clear()
		for key in data.removed_grass:
			removed_grass[key] = true
	
	if data.has("removed_rocks"):
		removed_rocks.clear()
		for key in data.removed_rocks:
			removed_rocks[key] = true
	
	if data.has("chopped_trees"):
		chopped_trees.clear()
		for key in data.chopped_trees:
			chopped_trees[key] = true
		# Apply to currently loaded trees
		_apply_chopped_trees()
	
	if data.has("placed_grass"):
		placed_grass.clear()
		for g in data.placed_grass:
			placed_grass.append({
				"world_pos": Vector3(g.world_pos[0], g.world_pos[1], g.world_pos[2]),
				"scale": g.get("scale", 1.0),
				"rotation": g.get("rotation", 0.0)
			})
	
	if data.has("placed_rocks"):
		placed_rocks.clear()
		for r in data.placed_rocks:
			placed_rocks.append({
				"world_pos": Vector3(r.world_pos[0], r.world_pos[1], r.world_pos[2]),
				"scale": r.get("scale", 1.0),
				"rotation": r.get("rotation", 0.0)
			})
	
	print("VegetationManager: Loaded %d chopped trees, %d removed grass, %d removed rocks" % [
		chopped_trees.size(), removed_grass.size(), removed_rocks.size()
	])

func _apply_chopped_trees():
	# Mark trees as dead based on chopped_trees dictionary
	for coord in chunk_tree_data:
		var data = chunk_tree_data[coord]
		var mmi = data.multimesh as MultiMeshInstance3D
		for tree in data.trees:
			var key = "%d_%d" % [int(tree.world_pos.x), int(tree.world_pos.z)]
			if chopped_trees.has(key) and tree.alive:
				tree.alive = false
				# Hide in MultiMesh
				if mmi and mmi.multimesh:
					var t = Transform3D()
					t = t.scaled(Vector3.ZERO)
					t.origin = tree.local_pos
					mmi.multimesh.set_instance_transform(tree.index, t)

func _serialize_placed_list(list: Array) -> Array:
	var result = []
	for item in list:
		result.append({
			"world_pos": [item.world_pos.x, item.world_pos.y, item.world_pos.z],
			"scale": item.get("scale", 1.0),
			"rotation": item.get("rotation", 0.0)
		})
	return result
