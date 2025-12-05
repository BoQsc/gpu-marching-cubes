extends RefCounted
class_name WaterCompute

const DENSITY_GRID_SIZE = 33

var _shader_spirv: RDShaderSPIRV
var _pipeline: RID
var _shader_rid: RID
var _config: Resource # WaterGeneratorConfig

func _init(config: Resource):
	_config = config

func initialize(rd: RenderingDevice):
	_shader_spirv = _config.get_water_shader_spirv()
	_shader_rid = rd.shader_create_from_spirv(_shader_spirv)
	_pipeline = rd.compute_pipeline_create(_shader_rid)

func cleanup(rd: RenderingDevice):
	if _pipeline.is_valid():
		rd.free_rid(_pipeline)
	if _shader_rid.is_valid():
		rd.free_rid(_shader_rid)

func generate_density(rd: RenderingDevice, terrain_density_buffer: RID, chunk_pos: Vector3) -> RID:
	var density_bytes = DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * DENSITY_GRID_SIZE * 4
	var water_density_buffer = rd.storage_buffer_create(density_bytes)
	
	var u_density = RDUniform.new()
	u_density.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_density.binding = 0
	u_density.add_id(terrain_density_buffer)
	
	var u_water_out = RDUniform.new()
	u_water_out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_water_out.binding = 1
	u_water_out.add_id(water_density_buffer)
	
	var uniform_set = rd.uniform_set_create([u_density, u_water_out], _shader_rid, 0)
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	var push_constants = PackedFloat32Array([
		chunk_pos.x, chunk_pos.y, chunk_pos.z, 0.0,
		_config.water_level, 0.0, 0.0, 0.0
	])
	
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
	
	# Dispatch 9x9x9 groups of 4x4x4 threads = 36x36x36 (covers 33x33x33)
	rd.compute_list_dispatch(compute_list, 9, 9, 9)
	rd.compute_list_end()
	rd.submit()
	rd.sync() # Sync to ensure data is ready for meshing
	
	# Cleanup set
	if uniform_set.is_valid():
		rd.free_rid(uniform_set)
		
	return water_density_buffer
