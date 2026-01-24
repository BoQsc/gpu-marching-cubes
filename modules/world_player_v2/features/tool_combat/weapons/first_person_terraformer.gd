extends Node
class_name FirstPersonShovelV2
## FirstPersonShovel - Handles grid-snapped terrain dig/fill with material selection
## Refactored to use VoxelBrush and TerrainModifier

# Material definitions (id matches gen_density.glsl material IDs)
const MATERIALS = [
	{"id": 0, "name": "Grass", "key": KEY_1},
	{"id": 1, "name": "Stone", "key": KEY_2},
	{"id": 2, "name": "Ore", "key": KEY_3},
	{"id": 3, "name": "Sand", "key": KEY_4},
	{"id": 4, "name": "Gravel", "key": KEY_5},
	{"id": 5, "name": "Snow", "key": KEY_6},
	{"id": 9, "name": "Granite", "key": KEY_7}
]

# Current state
var material_index: int = 0  # Default to Grass
var is_active: bool = false  # Whether terraformer is equipped
var dig_mode: bool = false   # false = Place mode (default), true = Dig mode

# References
var player: CharacterBody3D = null

# Components
var modifier: TerrainModifier
var brush: VoxelBrush

# Selection box visualization
var selection_box: MeshInstance3D = null
var has_target: bool = false

# Constants
const RAYCAST_DISTANCE: float = 10.0

# Colors
const COLOR_DIG = Color(0.8, 0.2, 0.2, 0.5)   # Red for dig mode
const COLOR_PLACE = Color(0.2, 0.8, 0.4, 0.5) # Green for place mode

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	if not player:
		push_error("FirstPersonShovel: Must be child of Player/Components node")
		return
	
	# Initialize Components
	modifier = TerrainModifier.new()
	add_child(modifier)
	
	brush = VoxelBrush.new()
	brush.shape_type = VoxelBrush.ShapeType.BOX
	brush.radius = 0.5
	brush.strength = 10.0
	brush.snap_to_grid = true
	
	call_deferred("_create_selection_box")
	
	# Connect to item changes
	if has_node("/root/PlayerSignals"):
		PlayerSignals.item_changed.connect(_on_item_changed)
	
	print("SHOVEL: Initialized, mode = %s, material = %s" % [_get_mode_name(), MATERIALS[material_index].name])

func _create_selection_box() -> void:
	selection_box = MeshInstance3D.new()
	selection_box.mesh = _create_diamond_mesh()
	
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = COLOR_PLACE  # Default to place mode color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	selection_box.material_override = material
	selection_box.visible = false
	
	get_tree().root.add_child.call_deferred(selection_box)

func _create_diamond_mesh() -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Octahedron vertices (Diamond shape)
	var s = 0.51
	
	var top = Vector3(0, s, 0)
	var bot = Vector3(0, -s, 0)
	var p1 = Vector3(s, 0, 0)  # Right
	var p2 = Vector3(0, 0, s)  # Back
	var p3 = Vector3(-s, 0, 0) # Left
	var p4 = Vector3(0, 0, -s) # Front
	
	# Top Pyramid
	st.add_vertex(p1); st.add_vertex(top); st.add_vertex(p2)
	st.add_vertex(p2); st.add_vertex(top); st.add_vertex(p3)
	st.add_vertex(p3); st.add_vertex(top); st.add_vertex(p4)
	st.add_vertex(p4); st.add_vertex(top); st.add_vertex(p1)
	
	# Bottom Pyramid
	st.add_vertex(p2); st.add_vertex(bot); st.add_vertex(p1)
	st.add_vertex(p3); st.add_vertex(bot); st.add_vertex(p2)
	st.add_vertex(p4); st.add_vertex(bot); st.add_vertex(p3)
	st.add_vertex(p1); st.add_vertex(bot); st.add_vertex(p4)
	
	st.generate_normals()
	return st.commit()

func _get_mode_name() -> String:
	return "DIG" if dig_mode else "PLACE"

func _update_cursor_color() -> void:
	if selection_box and selection_box.material_override:
		selection_box.material_override.albedo_color = COLOR_DIG if dig_mode else COLOR_PLACE

# ============================================================================
# INPUT HANDLING
# ============================================================================

func _process(_delta: float) -> void:
	if not is_active or not player:
		if selection_box:
			selection_box.visible = false
		return
	
	_update_targeting()

func _input(event: InputEvent) -> void:
	if not is_active:
		return
	
	if event is InputEventKey and event.pressed and not event.echo:
		# P key toggles dig/place mode
		if event.keycode == KEY_P:
			dig_mode = not dig_mode
			_update_cursor_color()
			print("SHOVEL: Mode = %s" % _get_mode_name())
			# Emit mode change for HUD
			if has_node("/root/PlayerSignals") and PlayerSignals.has_signal("terraformer_mode_changed"):
				PlayerSignals.terraformer_mode_changed.emit(_get_mode_name())
			get_viewport().set_input_as_handled()
			return
		
		# CTRL + 1-7 for material selection
		if event.ctrl_pressed:
			for i in range(MATERIALS.size()):
				if event.keycode == MATERIALS[i].key:
					_set_material(i)
					get_viewport().set_input_as_handled()
					return

func _on_item_changed(_slot: int, item: Dictionary) -> void:
	var item_id = item.get("id", "")
	var was_active = is_active
	is_active = (item_id == "shovel")
	
	if is_active:
		print("SHOVEL: Equipped - P to toggle mode, CTRL+1-7 for material. Mode=%s Material=%s" % [_get_mode_name(), MATERIALS[material_index].name])
		# Emit current state for HUD
		if has_node("/root/PlayerSignals"):
			if PlayerSignals.has_signal("terraformer_material_changed"):
				PlayerSignals.terraformer_material_changed.emit(MATERIALS[material_index].name)
			if PlayerSignals.has_signal("terraformer_mode_changed"):
				PlayerSignals.terraformer_mode_changed.emit(_get_mode_name())
		_update_cursor_color()
	elif was_active:
		# Was equipped, now unequipped - clear HUD
		if has_node("/root/PlayerSignals"):
			if PlayerSignals.has_signal("terraformer_material_changed"):
				PlayerSignals.terraformer_material_changed.emit("")
			if PlayerSignals.has_signal("terraformer_mode_changed"):
				PlayerSignals.terraformer_mode_changed.emit("")
		if selection_box:
			selection_box.visible = false

func _set_material(index: int) -> void:
	if index < 0 or index >= MATERIALS.size():
		return
	
	material_index = index
	var mat = MATERIALS[material_index]
	print("SHOVEL: Material = %s (id=%d)" % [mat.name, mat.id])
	
	# Emit signal for HUD update
	if has_node("/root/PlayerSignals") and PlayerSignals.has_signal("terraformer_material_changed"):
		PlayerSignals.terraformer_material_changed.emit(mat.name)

# ============================================================================
# TARGETING
# ============================================================================

func _update_targeting() -> void:
	if not player or not selection_box:
		return
	
	var hit = _raycast(RAYCAST_DISTANCE)
	if hit.is_empty():
		selection_box.visible = false
		has_target = false
		return
	
	has_target = true
	
	# Update brush config for targeting calculation
	brush.mode = VoxelBrush.Mode.ADD if dig_mode else VoxelBrush.Mode.SUBTRACT
	brush.use_raycast_normal = not dig_mode # Place uses normal offset
	
	# Get target from modifier helper
	var target_pos = modifier.get_target_position(brush, hit.position, hit.normal)
	
	selection_box.global_position = target_pos
	selection_box.visible = true

# ============================================================================
# ACTIONS
# ============================================================================

## Call this from combat_system for left-click (primary action)
func do_primary_action() -> void:
	if not is_active or not has_target:
		return
	
	if has_node("/root/PlayerSignals"):
		PlayerSignals.axe_fired.emit()
	
	_apply_action(dig_mode)

## Call this from combat_system for right-click (secondary = opposite action)
func do_secondary_action() -> void:
	if not is_active or not has_target:
		return
	
	if has_node("/root/PlayerSignals"):
		PlayerSignals.axe_fired.emit()
	
	_apply_action(not dig_mode)

func _apply_action(is_dig: bool) -> void:
	# Configure brush
	brush.mode = VoxelBrush.Mode.ADD if is_dig else VoxelBrush.Mode.SUBTRACT
	brush.use_raycast_normal = not is_dig
	
	if not is_dig:
		# Place mode: set material (+100 for player placed)
		brush.material_id = MATERIALS[material_index].id + 100
	else:
		brush.material_id = -1
	
	# Re-raycast to get fresh hit normal for application
	var hit = _raycast(RAYCAST_DISTANCE)
	if not hit.is_empty():
		modifier.apply_brush(brush, hit.position, hit.normal)
		var action = "DIG" if is_dig else "PLACE"
		print("SHOVEL: %s at %s" % [action, selection_box.global_position])

# ============================================================================
# RAYCAST
# ============================================================================

func _raycast(distance: float) -> Dictionary:
	if not player:
		return {}
	
	var camera = player.get_node_or_null("Head/Camera3D")
	if not camera:
		camera = player.get_node_or_null("Camera3D")  # Fallback
	if not camera:
		return {}
	
	var space_state = player.get_world_3d().direct_space_state
	if not space_state:
		return {}
	
	var from = camera.global_position
	var to = from + (-camera.global_transform.basis.z) * distance
	
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player.get_rid()]
	query.collision_mask = 1 | 512  # Terrain layers
	
	return space_state.intersect_ray(query)

# ============================================================================
# PUBLIC API
# ============================================================================

## Get current material name (for HUD)
func get_current_material_name() -> String:
	return MATERIALS[material_index].name

## Get current material ID
func get_current_material_id() -> int:
	return MATERIALS[material_index].id

## Get current mode name (for HUD)
func get_current_mode() -> String:
	return _get_mode_name()

## Check if in dig mode
func is_dig_mode() -> bool:
	return dig_mode
