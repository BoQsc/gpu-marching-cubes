extends "res://modules/world_player_v2/features/feature_base.gd"
class_name MovementFeatureV2
## MovementFeature - Handles player movement, jumping, sprinting, and swimming

# Movement constants (preserved from v1)
const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 8.5
const SWIM_SPEED: float = 4.0
const JUMP_VELOCITY: float = 4.5
const FOOTSTEP_INTERVAL: float = 0.5
const FOOTSTEP_INTERVAL_SPRINT: float = 0.3

# Sounds
const FOOTSTEP_SOUNDS = [
	preload("res://sound/st1-footstep-sfx-323053.mp3"),
	preload("res://sound/st2-footstep-sfx-323055.mp3"),
	preload("res://sound/st3-footstep-sfx-323056.mp3")
]

# State
var is_sprinting: bool = false
var is_swimming: bool = false
var was_on_floor: bool = true
var footstep_timer: float = 0.0
var footstep_player: AudioStreamPlayer3D = null

# Gravity
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

func _on_initialize() -> void:
	# Create footstep audio player
	footstep_player = AudioStreamPlayer3D.new()
	footstep_player.name = "FootstepPlayer"
	add_child(footstep_player)

func _physics_process(delta: float) -> void:
	if not player:
		return
	
	_handle_gravity(delta)
	_handle_swimming(delta)
	_handle_movement(delta)
	_handle_jump()
	_handle_footsteps(delta)
	_check_landing()
	
	player.move_and_slide()

## Apply gravity
func _handle_gravity(delta: float) -> void:
	if not player.is_on_floor() and not is_swimming:
		player.velocity.y -= gravity * delta

## Handle swimming state
func _handle_swimming(delta: float) -> void:
	if not player.terrain_manager:
		return
	
	if not player.terrain_manager.has_method("get_water_density"):
		return
	
	var water_density = player.terrain_manager.get_water_density(player.global_position)
	var new_swimming = water_density > 0.5
	
	if new_swimming != is_swimming:
		is_swimming = new_swimming
		PlayerSignalsV2.underwater_toggled.emit(is_swimming)
	
	if is_swimming:
		# Apply water resistance
		player.velocity.y = move_toward(player.velocity.y, 0, 5.0 * delta)
		
		# Swim controls
		if Input.is_action_pressed("ui_accept"):
			player.velocity.y = 3.0
		elif Input.is_action_pressed("crouch") if InputMap.has_action("crouch") else false:
			player.velocity.y = -3.0

## Handle horizontal movement
func _handle_movement(delta: float) -> void:
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction = (player.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	# Sprint logic - preserve momentum in air
	if player.is_on_floor():
		if Input.is_action_pressed("sprint") and direction != Vector3.ZERO:
			is_sprinting = true
		else:
			is_sprinting = false
	else:
		# In air - only update if we started in air without sprint
		if not is_sprinting and Input.is_action_pressed("sprint"):
			pass  # Don't start sprinting mid-air
	
	# Determine speed
	var current_speed = WALK_SPEED
	if is_swimming:
		current_speed = SWIM_SPEED
	elif is_sprinting:
		current_speed = SPRINT_SPEED
	
	# Apply movement
	if direction:
		player.velocity.x = direction.x * current_speed
		player.velocity.z = direction.z * current_speed
	else:
		player.velocity.x = move_toward(player.velocity.x, 0, current_speed)
		player.velocity.z = move_toward(player.velocity.z, 0, current_speed)

## Handle jumping
func _handle_jump() -> void:
	if Input.is_action_just_pressed("ui_accept") and player.is_on_floor() and not is_swimming:
		player.velocity.y = JUMP_VELOCITY
		PlayerSignalsV2.player_jumped.emit()

## Handle footstep sounds
func _handle_footsteps(delta: float) -> void:
	if not player.is_on_floor() or is_swimming:
		return
	
	var horizontal_vel = Vector2(player.velocity.x, player.velocity.z)
	if horizontal_vel.length() < 0.5:
		return
	
	var interval = FOOTSTEP_INTERVAL_SPRINT if is_sprinting else FOOTSTEP_INTERVAL
	footstep_timer += delta
	
	if footstep_timer >= interval:
		footstep_timer = 0.0
		_play_footstep()

func _play_footstep() -> void:
	if not footstep_player or FOOTSTEP_SOUNDS.is_empty():
		return
	
	var sound = FOOTSTEP_SOUNDS[randi() % FOOTSTEP_SOUNDS.size()]
	footstep_player.stream = sound
	footstep_player.play()

## Check for landing
func _check_landing() -> void:
	var on_floor = player.is_on_floor()
	if on_floor and not was_on_floor:
		PlayerSignalsV2.player_landed.emit()
	was_on_floor = on_floor

## Save/Load
func get_save_data() -> Dictionary:
	return {
		"position": player.global_position,
		"rotation": player.rotation
	}

func load_save_data(data: Dictionary) -> void:
	if data.has("position"):
		player.global_position = data["position"]
	if data.has("rotation"):
		player.rotation = data["rotation"]
