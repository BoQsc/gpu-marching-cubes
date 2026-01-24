extends RefCounted
class_name VoxelEngine

# Signals to notify Coordinator
signal generation_completed(coord: Vector3i, result_terrain: Dictionary, density_buffer_terrain: RID, result_water: Dictionary, density_buffer_water: RID, cpu_density_water: PackedFloat32Array, cpu_density_terrain: PackedFloat32Array, material_buffer_terrain: RID, cpu_material_terrain: PackedByteArray)
signal modification_completed(coord: Vector3i, result: Dictionary, layer: int, batch_id: int, batch_count: int, cpu_density: PackedFloat32Array, cpu_material: PackedByteArray, start_mod_version: int)

# Threading
var compute_thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var exit_thread: bool = false

# CPU Worker Pool
const CPU_WORKER_COUNT = 2
var cpu_threads: Array[Thread] = []
var cpu_task_queue: Array[Dictionary] = []
var cpu_mutex: Mutex
var cpu_semaphore: Semaphore

# Task Queue (GPU tasks)
var task_queue: Array[Dictionary] = []

# Shaders (SPIR-V Data)
var shader_gen_spirv: RDShaderSPIRV
var shader_gen_water_spirv: RDShaderSPIRV
var shader_mod_spirv: RDShaderSPIRV
var shader_mesh_spirv: RDShaderSPIRV

# Materials (needed for mesh building)
var material_terrain: Material
var material_water: Material

# Constants
const CHUNK_SIZE = 32
const DENSITY_GRID_SIZE = 33
const MAX_TRIANGLES = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 5

# State
var _meshbuilder_logged: bool = false

func _init(p_mat_terrain: Material, p_mat_water: Material):
	material_terrain = p_mat_terrain
	material_water = p_mat_water
	
	mutex = Mutex.new()
	semaphore = Semaphore.new()
	cpu_mutex = Mutex.new()
	cpu_semaphore = Semaphore.new()
	
	_load_shaders()

func start():
	# Start GPU thread
	compute_thread = Thread.new()
	compute_thread.start(_thread_function)
	
	# Start CPU worker pool
	for i in range(CPU_WORKER_COUNT):
		var thread = Thread.new()
		thread.start(_cpu_thread_function)
		cpu_threads.append(thread)
	
	print("[VoxelEngine] Started GPU thread and %d CPU workers" % CPU_WORKER_COUNT)

func shutdown():
	mutex.lock()
	exit_thread = true
	mutex.unlock()
	
	# Signal GPU thread to exit
	semaphore.post()
	
	# Signal all CPU workers to exit
	for i in range(CPU_WORKER_COUNT):
		cpu_semaphore.post()
	
	# Wait for GPU thread
	if compute_thread and compute_thread.is_alive():
		compute_thread.wait_to_finish()
	
	# Wait for CPU workers
	for thread in cpu_threads:
		if thread and thread.is_alive():
			thread.wait_to_finish()
	
	print("[VoxelEngine] Shutdown complete")

func _load_shaders():
	# Load shaders (Data only, safe on Main Thread)
	shader_gen_spirv = load("res://world_marching_cubes/gen_density.glsl").get_spirv()
	shader_gen_water_spirv = load("res://world_marching_cubes/gen_water_density.glsl").get_spirv()
	shader_mod_spirv = load("res://world_marching_cubes/modify_density.glsl").get_spirv()
	shader_mesh_spirv = load("res://world_marching_cubes/marching_cubes.glsl").get_spirv()

# ============================================================================
# PUBLIC API - Task Submission
# ============================================================================

func queue_generation(coord: Vector3i, pos: Vector3):
	var task = {
		"type": "generate",
		"coord": coord,
		"pos": pos
	}
	mutex.lock()
	task_queue.append(task)
	mutex.unlock()
	semaphore.post()

func queue_modification(task: Dictionary):
	# Insert at front for priority
	mutex.lock()
	task_queue.push_front(task)
	mutex.unlock()
	semaphore.post()

func free_resources(rids: Array):
	mutex.lock()
	for rid in rids:
		if rid.is_valid():
			task_queue.append({"type": "free", "rid": rid})
	mutex.unlock()
	for _i in rids:
		semaphore.post()

func has_pending_tasks() -> bool:
	mutex.lock()
	var empty = task_queue.is_empty()
	mutex.unlock()
	return not empty

# ============================================================================
# THREAD LOGIC
# ============================================================================

func _thread_function():
	var rd = RenderingServer.create_local_rendering_device()
	if not rd:
		return

	var sid_gen = rd.shader_create_from_spirv(shader_gen_spirv)
	var sid_gen_water = rd.shader_create_from_spirv(shader_gen_water_spirv)
	var sid_mod = rd.shader_create_from_spirv(shader_mod_spirv)
	var sid_mesh = rd.shader_create_from_spirv(shader_mesh_spirv)
	
	var pipe_gen = rd.compute_pipeline_create(sid_gen)
	var pipe_gen_water = rd.compute_pipeline_create(sid_gen_water)
	var pipe_mod = rd.compute_pipeline_create(sid_mod)
	var pipe_mesh = rd.compute_pipeline_create(sid_mesh)
	
	# Create REUSABLE Buffers
	var output_bytes_size = MAX_TRIANGLES * 3 * 9 * 4
	var vertex_buffer_terrain = rd.storage_buffer_create(output_bytes_size)
	var counter_data = PackedByteArray()
	counter_data.resize(4)
	counter_data.encode_u32(0, 0)
	var counter_buffer_terrain = rd.storage_buffer_create(4, counter_data)
	
	var vertex_buffer_water = rd.storage_buffer_create(output_bytes_size)
	var counter_data_w = PackedByteArray()
	counter_data_w.resize(4)
	counter_data_w.encode_u32(0, 0)
	var counter_buffer_water = rd.storage_buffer_create(4, counter_data_w)
	
	var in_flight: Array[Dictionary] = []
	const MAX_IN_FLIGHT = 1
	
	while true:
		semaphore.wait()
		
		mutex.lock()
		if exit_thread:
			mutex.unlock()
			break
			
		if task_queue.is_empty():
			mutex.unlock()
			if in_flight.size() > 0:
				rd.sync()
				for flight_data in in_flight:
					_complete_chunk_readback(rd, flight_data, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, vertex_buffer_water, counter_buffer_water)
				in_flight.clear()
			continue
			
		var task = task_queue.pop_front()
		mutex.unlock()
		
		if task.type == "modify":
			if in_flight.size() > 0:
				rd.sync()
				for fd in in_flight:
					_complete_chunk_readback(rd, fd, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, vertex_buffer_water, counter_buffer_water)
				in_flight.clear()
			process_modify(rd, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain)
			
		elif task.type == "generate":
			if in_flight.size() > 0:
				rd.sync()
				for flight_data in in_flight:
					_complete_chunk_readback(rd, flight_data, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, vertex_buffer_water, counter_buffer_water)
				in_flight.clear()
			
			var flight_data = _dispatch_chunk_generation(rd, task, sid_gen, sid_gen_water, sid_mod, pipe_gen, pipe_gen_water, pipe_mod)
			if flight_data:
				in_flight.append(flight_data)
				rd.submit()
				
				if in_flight.size() >= MAX_IN_FLIGHT:
					rd.sync()
					for fd in in_flight:
						_complete_chunk_readback(rd, fd, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, vertex_buffer_water, counter_buffer_water)
					in_flight.clear()
					
		elif task.type == "free":
			if task.rid.is_valid():
				rd.free_rid(task.rid)
	
	# Cleanup
	rd.free_rid(vertex_buffer_terrain)
	rd.free_rid(counter_buffer_terrain)
	rd.free_rid(vertex_buffer_water)
	rd.free_rid(counter_buffer_water)
	rd.free_rid(pipe_gen)
	rd.free_rid(pipe_gen_water)
	rd.free_rid(pipe_mod)
	rd.free_rid(pipe_mesh)
	rd.free_rid(sid_gen)
	rd.free_rid(sid_gen_water)
	rd.free_rid(sid_mod)
	rd.free_rid(sid_mesh)
	rd.free()

# ============================================================================
# GPU LOGIC - GENERATION
# ============================================================================

func _dispatch_chunk_generation(rd: RenderingDevice, task, sid_gen, sid_gen_water, sid_mod, pipe_gen, pipe_gen_water, pipe_mod) -> Dictionary:
	var chunk_pos = task.pos
	var coord = task.coord
	var density_bytes = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4
	var material_bytes = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4
	
	var dens_buf_terrain = rd.storage_buffer_create(density_bytes)
	var dens_buf_water = rd.storage_buffer_create(density_bytes)
	var mat_buf_terrain = rd.storage_buffer_create(material_bytes)
	
	# Dispatch Terrain
	var u_density_t = RDUniform.new()
	u_density_t.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density_t.binding = 0
	u_density_t.add_id(dens_buf_terrain)
	
	var u_material_t = RDUniform.new()
	u_material_t.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_material_t.binding = 1
	u_material_t.add_id(mat_buf_terrain)
	
	var set_gen_t = rd.uniform_set_create([u_density_t, u_material_t], sid_gen, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_gen)
	rd.compute_list_bind_uniform_set(list, set_gen_t, 0)
	
	# Fetch parameters from Global/Coordinator if needed, for now assume standard
	# Note: We need access to these settings. Best to pass them in task or store in Engine.
	# For strict refactor, we'll hardcode defaults or access Globals if available.
	# Ideally, VoxelEngine should have these as properties.
	var terrain_height = 10.0
	var noise_freq = 0.1
	var road_spacing = 100.0
	var road_width = 8.0
	
	var push_data_t = PackedFloat32Array([chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0, noise_freq, terrain_height, road_spacing, road_width])
	rd.compute_list_set_push_constant(list, push_data_t.to_byte_array(), push_data_t.size() * 4)
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	
	# Dispatch Water
	var u_density_w = RDUniform.new()
	u_density_w.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density_w.binding = 0
	u_density_w.add_id(dens_buf_water)
	
	var set_gen_w = rd.uniform_set_create([u_density_w], sid_gen_water, 0)
	list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_gen_water)
	rd.compute_list_bind_uniform_set(list, set_gen_w, 0)
	
	var water_level = 13.0
	var push_data_w = PackedFloat32Array([chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0, noise_freq, water_level, 0.0, 0.0])
	rd.compute_list_set_push_constant(list, push_data_w.to_byte_array(), push_data_w.size() * 4)
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	
	# Apply Stored Modifications (if any)
	# This requires the Coordinator to pass them in the task, or we query a shared store.
	# For V1 refactor, we'll assume the task contains 'modifications' list
	if task.has("modifications"):
		rd.submit()
		rd.sync()
		for mod in task.modifications:
			var target_buffer = dens_buf_terrain if mod.layer == 0 else dens_buf_water
			_apply_modification_to_buffer(rd, sid_mod, pipe_mod, target_buffer, mat_buf_terrain, chunk_pos, mod)
	
	if set_gen_t.is_valid(): rd.free_rid(set_gen_t)
	if set_gen_w.is_valid(): rd.free_rid(set_gen_w)
	
	return {
		"coord": coord,
		"chunk_pos": chunk_pos,
		"dens_buf_terrain": dens_buf_terrain,
		"dens_buf_water": dens_buf_water,
		"mat_buf_terrain": mat_buf_terrain
	}

func _complete_chunk_readback(rd: RenderingDevice, flight_data: Dictionary, sid_mesh, pipe_mesh, vertex_buffer_terrain, counter_buffer_terrain, vertex_buffer_water, counter_buffer_water):
	var coord = flight_data.coord
	var chunk_pos = flight_data.chunk_pos
	var dens_buf_terrain = flight_data.dens_buf_terrain
	var dens_buf_water = flight_data.dens_buf_water
	var mat_buf_terrain = flight_data.mat_buf_terrain
	
	var set_mesh_t = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, dens_buf_terrain, mat_buf_terrain, chunk_pos, vertex_buffer_terrain, counter_buffer_terrain)
	var set_mesh_w = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, dens_buf_water, mat_buf_terrain, chunk_pos, vertex_buffer_water, counter_buffer_water)
	
	rd.submit()
	rd.sync()
	
	var vert_floats_terrain = run_gpu_meshing_readback(rd, vertex_buffer_terrain, counter_buffer_terrain, set_mesh_t)
	var vert_floats_water = run_gpu_meshing_readback(rd, vertex_buffer_water, counter_buffer_water, set_mesh_w)
	
	var cpu_density_bytes_w = rd.buffer_get_data(dens_buf_water)
	var cpu_density_floats_w = cpu_density_bytes_w.to_float32_array()
	var cpu_density_bytes_t = rd.buffer_get_data(dens_buf_terrain)
	var cpu_density_floats_t = cpu_density_bytes_t.to_float32_array()
	var cpu_material_bytes = rd.buffer_get_data(mat_buf_terrain)
	
	cpu_mutex.lock()
	cpu_task_queue.append({
		"coord": coord,
		"chunk_pos": chunk_pos,
		"vert_floats_terrain": vert_floats_terrain,
		"vert_floats_water": vert_floats_water,
		"cpu_dens_w": cpu_density_floats_w,
		"cpu_dens_t": cpu_density_floats_t,
		"cpu_mat_t": cpu_material_bytes,
		"dens_buf_terrain": dens_buf_terrain,
		"dens_buf_water": dens_buf_water,
		"mat_buf_terrain": mat_buf_terrain
	})
	cpu_mutex.unlock()
	cpu_semaphore.post()

# ============================================================================
# GPU LOGIC - MODIFICATION
# ============================================================================

func process_modify(rd: RenderingDevice, task, sid_mod, sid_mesh, pipe_mod, pipe_mesh, vertex_buffer, counter_buffer):
	var density_buffer = task.rid
	var material_buffer = task.get("material_rid", RID())
	var chunk_pos = task.pos
	var layer = task.get("layer", 0)
	var material_id = task.get("material_id", -1)
	
	_apply_modification_to_buffer(rd, sid_mod, pipe_mod, density_buffer, material_buffer, chunk_pos, task)
	
	# Remesh immediately
	var material = material_terrain if layer == 0 else material_water
	var result = run_meshing(rd, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, material, vertex_buffer, counter_buffer)
	
	# Readback updated density
	var cpu_density_floats = rd.buffer_get_data(density_buffer).to_float32_array()
	var cpu_material_bytes = PackedByteArray()
	if material_buffer.is_valid():
		cpu_material_bytes = rd.buffer_get_data(material_buffer)
	
	var b_id = task.get("batch_id", -1)
	var b_count = task.get("batch_count", 1)
	var start_mod_version = task.get("start_mod_version", 0)
	
	# Emit signal back to main thread
	modification_completed.emit.call_deferred(task.coord, result, layer, b_id, b_count, cpu_density_floats, cpu_material_bytes, start_mod_version)

func _apply_modification_to_buffer(rd: RenderingDevice, sid_mod, pipe_mod, density_buffer: RID, material_buffer: RID, chunk_pos: Vector3, mod: Dictionary):
	var u_density = RDUniform.new()
	u_density.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density.binding = 0
	u_density.add_id(density_buffer)
	
	var u_material = RDUniform.new()
	u_material.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_material.binding = 1
	if material_buffer.is_valid():
		u_material.add_id(material_buffer)
	else:
		u_material.add_id(density_buffer)
	
	var set_mod = rd.uniform_set_create([u_density, u_material], sid_mod, 0)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mod)
	rd.compute_list_bind_uniform_set(list, set_mod, 0)
	
	var push_data = PackedByteArray()
	push_data.resize(48)
	var buffer = StreamPeerBuffer.new()
	buffer.data_array = push_data
	
	var y_min_val = mod.get("y_min", 0.0) if mod.get("shape", 0) == 2 else 0.0
	
	buffer.put_float(chunk_pos.x)
	buffer.put_float(chunk_pos.y)
	buffer.put_float(chunk_pos.z)
	buffer.put_float(y_min_val)
	
	buffer.put_float(mod.brush_pos.x)
	buffer.put_float(mod.brush_pos.y)
	buffer.put_float(mod.brush_pos.z)
	buffer.put_float(mod.radius)
	
	var y_max_val = mod.get("y_max", 0.0) if mod.get("shape", 0) == 2 else 0.0
	
	buffer.put_float(mod.value)
	buffer.put_32(mod.get("shape", 0))
	buffer.put_32(mod.get("material_id", -1))
	buffer.put_float(y_max_val)
	
	rd.compute_list_set_push_constant(list, buffer.data_array, buffer.data_array.size())
	rd.compute_list_dispatch(list, 9, 9, 9)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	if set_mod.is_valid(): rd.free_rid(set_mod)

# ============================================================================
# GPU LOGIC - MESHING HELPERS
# ============================================================================

func run_gpu_meshing_dispatch(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer) -> RID:
	var zero_data = PackedByteArray()
	zero_data.resize(4)
	zero_data.encode_u32(0, 0)
	rd.buffer_update(counter_buffer, 0, 4, zero_data)
	
	var u_vert = RDUniform.new()
	u_vert.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_vert.binding = 0
	u_vert.add_id(vertex_buffer)
	
	var u_count = RDUniform.new()
	u_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_count.binding = 1
	u_count.add_id(counter_buffer)
	
	var u_dens = RDUniform.new()
	u_dens.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_dens.binding = 2
	u_dens.add_id(density_buffer)
	
	var u_mat = RDUniform.new()
	u_mat.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_mat.binding = 3
	u_mat.add_id(material_buffer)
	
	var set_mesh = rd.uniform_set_create([u_vert, u_count, u_dens, u_mat], sid_mesh, 0)
	
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipe_mesh)
	rd.compute_list_bind_uniform_set(list, set_mesh, 0)
	
	# Parameters
	var noise_freq = 0.1
	var terrain_height = 10.0
	
	var push_data = PackedFloat32Array([
		chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0,
		noise_freq, terrain_height, 0.0, 0.0
	])
	rd.compute_list_set_push_constant(list, push_data.to_byte_array(), push_data.size() * 4)
	
	var groups = CHUNK_SIZE / 8
	rd.compute_list_dispatch(list, groups, groups, groups)
	rd.compute_list_end()
	
	return set_mesh

func run_gpu_meshing_readback(rd: RenderingDevice, vertex_buffer, counter_buffer, set_mesh: RID) -> PackedFloat32Array:
	var count_bytes = rd.buffer_get_data(counter_buffer)
	var tri_count = count_bytes.decode_u32(0)
	
	var vert_floats = PackedFloat32Array()
	if tri_count > 0:
		var total_floats = tri_count * 3 * 9
		var vert_bytes = rd.buffer_get_data(vertex_buffer, 0, total_floats * 4)
		vert_floats = vert_bytes.to_float32_array()
		
	if set_mesh.is_valid(): rd.free_rid(set_mesh)
	return vert_floats

func run_meshing(rd: RenderingDevice, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, material_instance, vertex_buffer, counter_buffer) -> Dictionary:
	var set_mesh = run_gpu_meshing_dispatch(rd, sid_mesh, pipe_mesh, density_buffer, material_buffer, chunk_pos, vertex_buffer, counter_buffer)
	rd.submit()
	rd.sync()
	
	var vert_floats = run_gpu_meshing_readback(rd, vertex_buffer, counter_buffer, set_mesh)
	var mesh = build_mesh(vert_floats, material_instance)
	var shape = null
	if mesh:
		shape = mesh.create_trimesh_shape()
		
	return {"mesh": mesh, "shape": shape}

# ============================================================================
# CPU LOGIC - WORKER THREADS
# ============================================================================

func _cpu_thread_function():
	while true:
		cpu_semaphore.wait()
		
		mutex.lock()
		var should_exit = exit_thread
		mutex.unlock()
		
		if should_exit:
			break
		
		cpu_mutex.lock()
		if cpu_task_queue.is_empty():
			cpu_mutex.unlock()
			continue
		var task = cpu_task_queue.pop_front()
		cpu_mutex.unlock()
		
		# Build meshes
		var mesh_terrain = build_mesh(task.vert_floats_terrain, material_terrain)
		var shape_terrain = null
		
		if ClassDB.class_exists("MeshBuilder"):
			var builder = ClassDB.instantiate("MeshBuilder")
			if task.vert_floats_terrain.size() > 0:
				shape_terrain = builder.build_collision_shape(task.vert_floats_terrain, 9)
		elif mesh_terrain:
			shape_terrain = mesh_terrain.create_trimesh_shape()
			
		var mesh_water = build_mesh(task.vert_floats_water, material_water)
		var shape_water = null
		
		if mesh_water:
			shape_water = mesh_water.create_trimesh_shape()
			
		var result_t = {"mesh": mesh_terrain, "shape": shape_terrain}
		var result_w = {"mesh": mesh_water, "shape": shape_water}
		
		generation_completed.emit.call_deferred(task.coord, result_t, task.dens_buf_terrain, result_w, task.dens_buf_water, task.cpu_dens_w, task.cpu_dens_t, task.mat_buf_terrain, task.cpu_mat_t)

func build_mesh(data: PackedFloat32Array, material_instance: Material) -> ArrayMesh:
	if data.size() == 0:
		return null
	
	if ClassDB.class_exists("MeshBuilder"):
		if not _meshbuilder_logged:
			_meshbuilder_logged = true
			print("[VoxelEngine] ✓ MeshBuilder GDExtension active")
		var builder = ClassDB.instantiate("MeshBuilder")
		var mesh = builder.build_mesh_native(data, 9)
		if mesh:
			mesh.surface_set_material(0, material_instance)
			return mesh
	
	# GDScript Fallback
	var vertex_count = data.size() / 9
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var colors = PackedColorArray()
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)
	
	for i in range(vertex_count):
		var idx = i * 9
		vertices[i] = Vector3(data[idx], data[idx + 1], data[idx + 2])
		normals[i] = Vector3(data[idx + 3], data[idx + 4], data[idx + 5])
		colors[i] = Color(data[idx + 6], data[idx + 7], data[idx + 8])
	
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material_instance)
	return mesh
