extends "res://modules/world_player_v2/features/feature_base.gd"
class_name MiningFeatureV2
## MiningFeature - Handles terrain/block/object damage and durability
## Extracts mining logic from mode_play.gd

# HP Constants (preserved from v1)
const BLOCK_HP: int = 10
const OBJECT_HP: int = 5
const TREE_HP: int = 8
const TERRAIN_HP: int = 5

# Material names for UI
const MATERIAL_NAMES = {
	0: "Grass", 1: "Stone", 2: "Sand", 3: "Snow",
	100: "Grass", 101: "Stone", 102: "Sand", 103: "Snow"
}

# Damage tracking
var terrain_damage: Dictionary = {}  # Vector3i -> int
var block_damage: Dictionary = {}    # Vector3i -> int
var object_damage: Dictionary = {}   # RID -> int
var tree_damage: Dictionary = {}     # RID -> int

# Current target
var durability_target: Variant = null

func _physics_process(_delta: float) -> void:
	_check_durability_target()

## Handle damage to a target (called by CombatFeature)
func handle_damage(target: Node, position: Vector3, damage: int, item: Dictionary) -> void:
	if not target:
		return
	
	var item_id = item.get("id", "")
	
	# Trees
	if target.is_in_group("trees"):
		_damage_tree(target, damage, item_id)
		return
	
	# Grass
	if target.is_in_group("grass"):
		_harvest_grass(target)
		return
	
	# Rocks
	if target.is_in_group("rocks"):
		_harvest_rock(target)
		return
	
	# Placed objects
	if target.is_in_group("placed_objects") and player.building_manager:
		_damage_placed_object(target, damage, item_id)
		return
	
	# Building blocks
	var chunk = _find_building_chunk(target)
	if chunk:
		_damage_building_block(position, damage, item_id)
		return
	
	# Terrain
	if player.terrain_manager and player.terrain_manager.has_method("modify_terrain"):
		_damage_terrain(position, damage, item)

## Damage a tree
func _damage_tree(target: Node, damage: int, item_id: String) -> void:
	var tree_dmg = damage
	if "axe" in item_id:
		tree_dmg = 3  # Axe does 3 damage per hit
	
	var tree_rid = target.get_rid()
	tree_damage[tree_rid] = tree_damage.get(tree_rid, 0) + tree_dmg
	
	durability_target = tree_rid
	var current_hp = TREE_HP - tree_damage[tree_rid]
	current_hp = max(0, current_hp)
	PlayerSignalsV2.durability_hit.emit(current_hp, TREE_HP, "Tree", durability_target)
	
	if tree_damage[tree_rid] >= TREE_HP:
		# Destroy tree
		if player.vegetation_manager and player.vegetation_manager.has_method("chop_tree_by_collider"):
			player.vegetation_manager.chop_tree_by_collider(target)
		_collect_resource("veg_wood")
		tree_damage.erase(tree_rid)
		PlayerSignalsV2.durability_cleared.emit()

## Harvest grass
func _harvest_grass(target: Node) -> void:
	if player.vegetation_manager and player.vegetation_manager.has_method("harvest_grass_by_collider"):
		player.vegetation_manager.harvest_grass_by_collider(target)
	_collect_resource("veg_fiber")

## Harvest rock
func _harvest_rock(target: Node) -> void:
	if player.vegetation_manager and player.vegetation_manager.has_method("harvest_rock_by_collider"):
		player.vegetation_manager.harvest_rock_by_collider(target)
	_collect_resource("veg_rock")

## Damage a placed object
func _damage_placed_object(target: Node, damage: int, item_id: String) -> void:
	var obj_dmg = damage
	if "pickaxe" in item_id:
		obj_dmg = 5  # Pickaxe one-shots objects
	
	var obj_rid = target.get_rid()
	object_damage[obj_rid] = object_damage.get(obj_rid, 0) + obj_dmg
	
	durability_target = obj_rid
	var current_hp = OBJECT_HP - object_damage[obj_rid]
	current_hp = max(0, current_hp)
	PlayerSignalsV2.durability_hit.emit(current_hp, OBJECT_HP, target.name, durability_target)
	
	if object_damage[obj_rid] >= OBJECT_HP:
		# Destroy object
		if target.has_meta("anchor") and target.has_meta("chunk"):
			var anchor = target.get_meta("anchor")
			var chunk = target.get_meta("chunk")
			if chunk and chunk.has_method("remove_object"):
				chunk.remove_object(anchor)
		object_damage.erase(obj_rid)
		PlayerSignalsV2.durability_cleared.emit()

## Damage a building block
func _damage_building_block(position: Vector3, damage: int, item_id: String) -> void:
	var blk_dmg = damage
	if "pickaxe" in item_id:
		blk_dmg = 5
	
	var block_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
	block_damage[block_pos] = block_damage.get(block_pos, 0) + blk_dmg
	
	durability_target = block_pos
	var current_hp = BLOCK_HP - block_damage[block_pos]
	current_hp = max(0, current_hp)
	PlayerSignalsV2.durability_hit.emit(current_hp, BLOCK_HP, "Block", durability_target)
	
	if block_damage[block_pos] >= BLOCK_HP:
		# Destroy block
		if player.building_manager and player.building_manager.has_method("set_voxel"):
			player.building_manager.set_voxel(block_pos, 0)
		block_damage.erase(block_pos)
		PlayerSignalsV2.durability_cleared.emit()

## Damage terrain
func _damage_terrain(position: Vector3, damage: int, item: Dictionary) -> void:
	var terrain_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
	var punch_dmg = item.get("damage", 1)
	
	terrain_damage[terrain_pos] = terrain_damage.get(terrain_pos, 0) + punch_dmg
	
	durability_target = terrain_pos
	var current_hp = TERRAIN_HP - terrain_damage[terrain_pos]
	current_hp = max(0, current_hp)
	PlayerSignalsV2.durability_hit.emit(current_hp, TERRAIN_HP, "Terrain", durability_target)
	
	if terrain_damage[terrain_pos] >= TERRAIN_HP:
		# Get material before destroying
		var mat_id = -1
		if player.terrain_manager.has_method("get_material_at"):
			mat_id = player.terrain_manager.get_material_at(position)
		
		# Destroy terrain
		var mining_strength = item.get("mining_strength", 0.5)
		player.terrain_manager.modify_terrain(position, mining_strength, 1.0, 0, 0, -1)
		
		# Collect resource based on material
		if mat_id >= 0:
			_collect_terrain_resource(mat_id)
		
		terrain_damage.erase(terrain_pos)
		PlayerSignalsV2.durability_cleared.emit()

## Collect a resource by item ID
func _collect_resource(item_id: String) -> void:
	var inventory = player.get_feature("inventory")
	if inventory and inventory.has_method("add_item"):
		inventory.add_item(item_id, 1)

## Collect terrain resource based on material ID
func _collect_terrain_resource(mat_id: int) -> void:
	var item_id = ""
	match mat_id:
		0, 100: item_id = "dirt"
		1, 101: item_id = "stone"
		2, 102: item_id = "sand"
		3, 103: item_id = "snow"
	
	if not item_id.is_empty():
		_collect_resource(item_id)

## Find building chunk from collider
func _find_building_chunk(collider: Node) -> Node:
	if not collider:
		return null
	
	if collider.is_in_group("building_chunks"):
		return collider
	
	var parent = collider.get_parent()
	for i in 5:
		if not parent:
			break
		if parent.is_in_group("building_chunks"):
			return parent
		parent = parent.get_parent()
	
	return null

## Check if still looking at durability target
func _check_durability_target() -> void:
	if durability_target == null:
		return
	
	var hit = player.raycast(5.0, 0xFFFFFFFF, false, true)
	if hit.is_empty():
		durability_target = null
		return
	
	var position = hit.get("position", Vector3.ZERO)
	var block_pos = Vector3i(floor(position.x), floor(position.y), floor(position.z))
	
	if durability_target is Vector3i:
		if block_pos == durability_target:
			return
	
	durability_target = null

## Save/Load
func get_save_data() -> Dictionary:
	var data = {}
	
	# Save terrain damage
	var terrain_save = {}
	for pos in terrain_damage:
		terrain_save["%d,%d,%d" % [pos.x, pos.y, pos.z]] = terrain_damage[pos]
	data["terrain_damage"] = terrain_save
	
	# Save block damage
	var block_save = {}
	for pos in block_damage:
		block_save["%d,%d,%d" % [pos.x, pos.y, pos.z]] = block_damage[pos]
	data["block_damage"] = block_save
	
	return data

func load_save_data(data: Dictionary) -> void:
	terrain_damage.clear()
	block_damage.clear()
	
	if data.has("terrain_damage"):
		for key in data["terrain_damage"]:
			var parts = key.split(",")
			var pos = Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
			terrain_damage[pos] = data["terrain_damage"][key]
	
	if data.has("block_damage"):
		for key in data["block_damage"]:
			var parts = key.split(",")
			var pos = Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
			block_damage[pos] = data["block_damage"][key]
