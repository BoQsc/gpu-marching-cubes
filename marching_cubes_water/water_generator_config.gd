extends Resource

class_name WaterGeneratorConfig

@export var water_level: float = 16.0
@export var noise_frequency: float = 0.05
@export var albedo: Color = Color(0.0, 0.4, 0.6, 1.0)
@export var albedo_fresh: Color = Color(0.0, 0.6, 0.8, 1.0)
@export var metallic: float = 0.1
@export var roughness: float = 0.05
@export var beer_factor: float = 0.15
@export var foam_color: Color = Color(1.0, 1.0, 1.0, 1.0)

var _water_material: ShaderMaterial

func create_water_material() -> Material:
	if _water_material == null:
		var water_shader = load("res://marching_cubes_water/water_shader.gdshader")
		_water_material = ShaderMaterial.new()
		_water_material.shader = water_shader

		# Create a noise texture for water waves
		var noise = FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_PERLIN
		noise.frequency = noise_frequency # Use exported property
		noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		
		var noise_tex = NoiseTexture2D.new()
		noise_tex.noise = noise
		noise_tex.seamless = true
		noise_tex.width = 256
		noise_tex.height = 256
		
		_water_material.set_shader_parameter("albedo", albedo)
		_water_material.set_shader_parameter("albedo_fresh", albedo_fresh)
		_water_material.set_shader_parameter("metallic", metallic)
		_water_material.set_shader_parameter("roughness", roughness)
		_water_material.set_shader_parameter("wave", noise_tex)
		_water_material.set_shader_parameter("beer_factor", beer_factor)
		_water_material.set_shader_parameter("foam_color", foam_color)
		
	return _water_material
