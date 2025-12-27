extends "res://modules/world_player_v2/features/feature_base.gd"
class_name FirstPersonFeatureV2
## FirstPersonFeature - Manages first-person visuals (arms, pistol, axe)

# View instances
var arms_view: Node = null
var pistol_view: Node = null
var axe_view: Node = null
var current_view: Node = null

# View holder
var view_holder: Node3D = null

func _on_initialize() -> void:
	# Create view holder under camera
	if player.has_node("Camera3D"):
		var camera = player.get_node("Camera3D")
		view_holder = Node3D.new()
		view_holder.name = "FirstPersonViews"
		camera.add_child(view_holder)
	
	# Connect to item changes
	PlayerSignalsV2.item_changed.connect(_on_item_changed)
	
	# Create default arms view
	_create_arms_view()
	_switch_to_view("fists")

## Create arms view (fists)
func _create_arms_view() -> void:
	if not view_holder:
		return
	
	# Create placeholder arms
	arms_view = Node3D.new()
	arms_view.name = "ArmsView"
	view_holder.add_child(arms_view)
	
	# TODO: Load actual arm mesh
	DebugSettings.log_player("FirstPersonV2: Created arms view")

## Create pistol view
func _create_pistol_view() -> void:
	if not view_holder or pistol_view:
		return
	
	var scene = load("res://models/pistol/heavy_pistol_animated.glb")
	if scene:
		pistol_view = scene.instantiate()
		pistol_view.name = "PistolView"
		pistol_view.visible = false
		view_holder.add_child(pistol_view)
		
		# Position adjustments
		pistol_view.position = Vector3(0.2, -0.2, -0.4)
		pistol_view.rotation_degrees = Vector3(0, 180, 0)
		pistol_view.scale = Vector3(0.6, 0.6, 0.6)
		
		DebugSettings.log_player("FirstPersonV2: Created pistol view")

## Create axe view
func _create_axe_view() -> void:
	if not view_holder or axe_view:
		return
	
	var scene = load("res://game/assets/player_axe/1/animated_fps_axe.glb")
	if scene:
		axe_view = scene.instantiate()
		axe_view.name = "AxeView"
		axe_view.visible = false
		view_holder.add_child(axe_view)
		
		# Position adjustments
		axe_view.position = Vector3(0.3, -0.3, -0.5)
		
		DebugSettings.log_player("FirstPersonV2: Created axe view")

## Handle item change
func _on_item_changed(_slot: int, item: Dictionary) -> void:
	var item_id = item.get("id", "fists")
	_switch_to_view(item_id)

## Switch to appropriate view for item
func _switch_to_view(item_id: String) -> void:
	# Hide current
	if current_view:
		current_view.visible = false
	
	# Determine which view to show
	if item_id == "heavy_pistol":
		if not pistol_view:
			_create_pistol_view()
		current_view = pistol_view
	elif "axe" in item_id:
		if not axe_view:
			_create_axe_view()
		current_view = axe_view
	else:
		current_view = arms_view
	
	# Show new view
	if current_view:
		current_view.visible = true
		DebugSettings.log_player("FirstPersonV2: Switched to %s view" % item_id)
