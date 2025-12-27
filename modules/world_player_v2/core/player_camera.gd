extends Node
class_name PlayerCameraV2
## PlayerCameraV2 - Handles camera control, mouse look, and raycasting

const MOUSE_SENSITIVITY: float = 0.002
const PITCH_LIMIT: float = 89.0  # Degrees

var player: CharacterBody3D = null
var camera: Camera3D = null
var pitch: float = 0.0
var yaw: float = 0.0

# Underwater state
var is_camera_underwater: bool = false

func _ready() -> void:
	player = get_parent().get_parent() as CharacterBody3D
	
	# Find camera
	if player and player.has_node("Camera3D"):
		camera = player.get_node("Camera3D")
	
	# Capture mouse
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_handle_mouse_look(event.relative)

func _physics_process(_delta: float) -> void:
	_check_underwater()

## Handle mouse look
func _handle_mouse_look(relative: Vector2) -> void:
	if not player:
		return
	
	yaw -= relative.x * MOUSE_SENSITIVITY
	pitch -= relative.y * MOUSE_SENSITIVITY
	pitch = clamp(pitch, deg_to_rad(-PITCH_LIMIT), deg_to_rad(PITCH_LIMIT))
	
	player.rotation.y = yaw
	if camera:
		camera.rotation.x = pitch

## Check if camera is underwater
func _check_underwater() -> void:
	if not camera or not player:
		return
	
	var terrain_manager = player.terrain_manager
	if not terrain_manager or not terrain_manager.has_method("get_water_density"):
		return
	
	var cam_pos = camera.global_position
	var water_density = terrain_manager.get_water_density(cam_pos)
	var new_underwater = water_density > 0.0
	
	if new_underwater != is_camera_underwater:
		is_camera_underwater = new_underwater
		PlayerSignalsV2.camera_underwater_toggled.emit(is_camera_underwater)

## Get look direction
func get_look_direction() -> Vector3:
	if camera:
		return -camera.global_transform.basis.z
	return Vector3.FORWARD

## Get camera position
func get_camera_position() -> Vector3:
	if camera:
		return camera.global_position
	if player:
		return player.global_position + Vector3(0, 1.6, 0)
	return Vector3.ZERO

## Perform raycast from camera
func raycast(distance: float = 10.0, mask: int = 0xFFFFFFFF, collide_with_areas: bool = false, exclude_water: bool = false) -> Dictionary:
	if not camera:
		return {}
	
	var space_state = camera.get_world_3d().direct_space_state
	var origin = camera.global_position
	var direction = -camera.global_transform.basis.z
	var end = origin + direction * distance
	
	var query = PhysicsRayQueryParameters3D.create(origin, end, mask)
	query.collide_with_areas = collide_with_areas
	if player:
		query.exclude = [player.get_rid()]
	
	var result = space_state.intersect_ray(query)
	
	# Skip water hits if requested
	if exclude_water and result:
		while result and result.collider and result.collider.is_in_group("water"):
			var new_origin = result.position + direction * 0.01
			query = PhysicsRayQueryParameters3D.create(new_origin, end, mask)
			query.collide_with_areas = collide_with_areas
			if player:
				query.exclude = [player.get_rid()]
			result = space_state.intersect_ray(query)
	
	return result
