extends Node3D
class_name GridVisualizer

## GridVisualizer V2 (Target Cursor)
## Draws a single wireframe box at the specific target voxel position.

@export var color: Color = Color(1.0, 0.8, 0.0, 0.8) # Bright yellow/orange
@export var line_width: float = 2.0

var _mesh_instance: MeshInstance3D
var _immediate_mesh: ImmediateMesh
var _material: StandardMaterial3D

func _ready():
	_setup_visuals()
	set_process(false) 

func _setup_visuals():
	_mesh_instance = MeshInstance3D.new()
	_immediate_mesh = ImmediateMesh.new()
	_material = StandardMaterial3D.new()
	
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.vertex_color_use_as_albedo = true
	_material.albedo_color = color
	
	_mesh_instance.mesh = _immediate_mesh
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
	
	# Draw single unit box at origin once
	_draw_box()

func set_enabled(enabled: bool):
	visible = enabled
	set_process(enabled)

func update_grid(center_pos: Vector3):
	# Snap to nearest actual integer coordinate
	var snapped = Vector3(
		floor(center_pos.x) + 0.5,
		floor(center_pos.y) + 0.5,
		floor(center_pos.z) + 0.5
	)
	global_position = snapped

func _draw_box():
	_immediate_mesh.clear_surfaces()
	_immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	# Draw a 1x1x1 unit box centered at (0,0,0)
	var s = 0.5 # half size
	
	var cur_color = color
	
	# Bottom face
	_add_line(Vector3(-s, -s, -s), Vector3(s, -s, -s), cur_color)
	_add_line(Vector3(s, -s, -s), Vector3(s, -s, s), cur_color)
	_add_line(Vector3(s, -s, s), Vector3(-s, -s, s), cur_color)
	_add_line(Vector3(-s, -s, s), Vector3(-s, -s, -s), cur_color)
	
	# Top face
	_add_line(Vector3(-s, s, -s), Vector3(s, s, -s), cur_color)
	_add_line(Vector3(s, s, -s), Vector3(s, s, s), cur_color)
	_add_line(Vector3(s, s, s), Vector3(-s, s, s), cur_color)
	_add_line(Vector3(-s, s, s), Vector3(-s, s, -s), cur_color)
	
	# Vertical pillars
	_add_line(Vector3(-s, -s, -s), Vector3(-s, s, -s), cur_color)
	_add_line(Vector3(s, -s, -s), Vector3(s, s, -s), cur_color)
	_add_line(Vector3(s, -s, s), Vector3(s, s, s), cur_color)
	_add_line(Vector3(-s, -s, s), Vector3(-s, s, s), cur_color)

	_immediate_mesh.surface_end()

func _add_line(p1: Vector3, p2: Vector3, c: Color):
	_immediate_mesh.surface_set_color(c)
	_immediate_mesh.surface_add_vertex(p1)
	_immediate_mesh.surface_add_vertex(p2)
