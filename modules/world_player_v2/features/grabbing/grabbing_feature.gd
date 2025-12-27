extends "res://modules/world_player_v2/features/feature_base.gd"
class_name GrabbingFeatureV2
## GrabbingFeature - Handles grabbing and moving physics props
## Extracts grabbing logic from mode_play.gd

# State
var held_prop_instance: Node = null
var held_prop_id: int = -1  # -1 means grabbed dropped prop, not building object
var held_prop_rotation: int = 0
var is_grabbing: bool = false

# Config
const HOLD_DISTANCE: float = 2.0

func _input(event: InputEvent) -> void:
	if not player:
		return
	
	# T key toggles grab
	if event is InputEventKey and event.pressed and event.keycode == KEY_T:
		if is_grabbing:
			_drop_prop()
		else:
			_try_grab()

func _physics_process(delta: float) -> void:
	if is_grabbing:
		_update_held_prop(delta)

## Try to grab a prop
func _try_grab() -> void:
	var target = _get_pickup_target()
	if not target:
		return
	
	DebugSettings.log_player("GrabbingV2: Trying to grab %s" % target.name)
	
	# Check if this is a dropped physics prop
	if target is RigidBody3D and target.has_meta("item_data"):
		_grab_dropped_prop(target)
		return
	
	# Check if this is a building_manager placed object
	if target.has_meta("anchor") and target.has_meta("chunk"):
		_grab_building_object(target)

## Grab a dropped physics prop
func _grab_dropped_prop(target: RigidBody3D) -> void:
	held_prop_instance = target
	held_prop_id = -1  # Indicates grabbed dropped prop
	is_grabbing = true
	
	# Store item data
	if target.has_meta("item_data"):
		held_prop_instance.set_meta("grabbed_item_data", target.get_meta("item_data"))
	
	# Freeze physics
	target.freeze = true
	target.collision_layer = 0
	target.collision_mask = 0
	_disable_collisions(target)
	
	DebugSettings.log_player("GrabbingV2: Grabbed dropped prop %s" % target.name)

## Grab a building object
func _grab_building_object(target: Node) -> void:
	var anchor = target.get_meta("anchor")
	var chunk = target.get_meta("chunk")
	
	if not chunk or not chunk.objects.has(anchor):
		return
	
	var data = chunk.objects[anchor]
	held_prop_id = data["object_id"]
	held_prop_rotation = data.get("rotation", 0)
	
	# Remove from world
	chunk.remove_object(anchor)
	
	# Spawn temporary visual
	var obj_def = ObjectRegistry.get_object(held_prop_id) if ObjectRegistry else null
	if obj_def and obj_def.has("scene"):
		var scene = load(obj_def["scene"])
		if scene:
			held_prop_instance = scene.instantiate()
			player.get_tree().root.add_child(held_prop_instance)
			_disable_collisions(held_prop_instance)
			is_grabbing = true
			
			DebugSettings.log_player("GrabbingV2: Grabbed building object ID %d" % held_prop_id)

## Drop the currently held prop
func _drop_prop() -> void:
	if not is_grabbing:
		return
	
	if held_prop_id == -1 and held_prop_instance:
		# Dropped physics prop - re-enable physics
		_drop_physics_prop()
	elif held_prop_id >= 0:
		# Building object - place back in world
		_drop_building_object()
	
	is_grabbing = false
	held_prop_instance = null
	held_prop_id = -1

## Drop a physics prop
func _drop_physics_prop() -> void:
	if not held_prop_instance or not is_instance_valid(held_prop_instance):
		return
	
	# Re-enable collisions
	_enable_collisions(held_prop_instance)
	
	# Restore physics
	held_prop_instance.collision_layer = 1
	held_prop_instance.collision_mask = 1
	held_prop_instance.freeze = false
	
	# Apply small forward velocity
	if held_prop_instance is RigidBody3D:
		held_prop_instance.linear_velocity = player.get_look_direction() * 2.0
	
	DebugSettings.log_player("GrabbingV2: Dropped physics prop")

## Drop a building object (place in world)
func _drop_building_object() -> void:
	if held_prop_instance and is_instance_valid(held_prop_instance):
		held_prop_instance.queue_free()
	
	if held_prop_id < 0 or not player.building_manager:
		return
	
	# Get placement position
	var cam_pos = player.get_camera_position()
	var cam_dir = player.get_look_direction()
	var place_pos = cam_pos + cam_dir * HOLD_DISTANCE
	
	# Place object
	if player.building_manager.has_method("place_object"):
		player.building_manager.place_object(held_prop_id, place_pos, held_prop_rotation)
	
	DebugSettings.log_player("GrabbingV2: Placed building object at %s" % place_pos)

## Update held prop position
func _update_held_prop(_delta: float) -> void:
	if not held_prop_instance or not is_instance_valid(held_prop_instance):
		is_grabbing = false
		return
	
	var cam_pos = player.get_camera_position()
	var cam_dir = player.get_look_direction()
	var target_pos = cam_pos + cam_dir * HOLD_DISTANCE
	
	held_prop_instance.global_position = target_pos

## Find a grabbable target
func _get_pickup_target() -> Node:
	var cam_pos = player.get_camera_position()
	var cam_dir = player.get_look_direction()
	
	# Raycast
	var hit = player.raycast(5.0, 0xFFFFFFFF, false, true)
	if hit:
		var collider = hit.get("collider")
		if collider:
			# Building object
			if collider.is_in_group("placed_objects") and collider.has_meta("anchor"):
				return collider
			# Physics prop
			if collider is RigidBody3D and (collider.has_meta("item_data") or collider.is_in_group("interactable")):
				return collider
	
	# Sphere search for nearby objects
	var space_state = player.get_world_3d().direct_space_state
	var search_origin = cam_pos + cam_dir * 2.0
	
	var params = PhysicsShapeQueryParameters3D.new()
	params.shape = SphereShape3D.new()
	params.shape.radius = 1.0
	params.transform = Transform3D(Basis(), search_origin)
	params.collision_mask = 0xFFFFFFFF
	params.exclude = [player.get_rid()]
	
	var results = space_state.intersect_shape(params, 5)
	var best_target = null
	var best_dist = 999.0
	
	for result in results:
		var col = result.collider
		var is_valid = false
		
		if col.is_in_group("placed_objects") and col.has_meta("anchor"):
			is_valid = true
		elif col is RigidBody3D and (col.has_meta("item_data") or col.is_in_group("interactable")):
			is_valid = true
		
		if is_valid:
			var d = col.global_position.distance_to(search_origin)
			if d < best_dist:
				best_dist = d
				best_target = col
	
	return best_target

## Disable collisions on node tree
func _disable_collisions(node: Node) -> void:
	for child in node.get_children():
		if child is CollisionShape3D:
			child.disabled = true
		elif child is CollisionPolygon3D:
			child.disabled = true
		_disable_collisions(child)

## Enable collisions on node tree
func _enable_collisions(node: Node) -> void:
	for child in node.get_children():
		if child is CollisionShape3D:
			child.disabled = false
		elif child is CollisionPolygon3D:
			child.disabled = false
		_enable_collisions(child)

## Check if currently grabbing
func is_grabbing_prop() -> bool:
	return is_grabbing
