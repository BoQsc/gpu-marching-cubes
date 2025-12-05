extends MeshInstance3D

@export var player: Node3D

func _ready():
	if not player:
		player = get_tree().get_first_node_in_group("player")

func _process(_delta):
	if player:
		# Snap position to a grid to prevent vertex swimming artifacts
		# Although shader now uses world coords, snapping helps keep the mesh aligned
		var snap_size = 1.0 
		var target_x = snapped(player.global_position.x, snap_size)
		var target_z = snapped(player.global_position.z, snap_size)
		
		global_position.x = target_x
		global_position.z = target_z
		# Keep Y constant (at 11.0 or wherever it was placed)
