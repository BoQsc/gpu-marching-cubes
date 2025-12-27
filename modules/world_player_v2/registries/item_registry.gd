extends Node
## ItemRegistry - Single Source of Truth for all item definitions
## Items are stored by ID and retrieved when needed, avoiding dictionary duplication

const ItemDataScript = preload("res://modules/world_player_v2/data/items/item_data.gd")

var _items: Dictionary = {}  # String -> ItemDataV2

## Fists item (always available, returned for empty slots)
var fists_item: Resource = null

func _ready() -> void:
	_create_fists_item()
	_register_default_items()
	DebugSettings.log_player("ItemRegistry: Initialized with %d items" % _items.size())

## Create the default fists item
func _create_fists_item() -> void:
	fists_item = ItemDataScript.new()
	fists_item.id = "fists"
	fists_item.display_name = "Fists"
	fists_item.category = ItemDataScript.ItemCategory.NONE
	fists_item.damage = 1
	fists_item.mining_strength = 0.3
	fists_item.max_stack = 1
	_items["fists"] = fists_item

## Register an item
func register(item: Resource) -> void:
	if not item or item.id.is_empty():
		push_error("ItemRegistry: Cannot register item with empty ID")
		return
	_items[item.id] = item
	DebugSettings.log_player("ItemRegistry: Registered '%s'" % item.id)

## Get item by ID (returns fists if not found)
func get_item(id: String) -> Resource:
	if id.is_empty():
		return fists_item
	return _items.get(id, fists_item)

## Check if item exists
func has_item(id: String) -> bool:
	return _items.has(id)

## Get all item IDs
func get_all_ids() -> Array[String]:
	var ids: Array[String] = []
	for key in _items.keys():
		ids.append(key)
	return ids

## Get item as dictionary (legacy compatibility)
func get_item_dict(id: String) -> Dictionary:
	var item = get_item(id)
	if item and item.has_method("to_dict"):
		return item.to_dict()
	return {"id": "fists", "name": "Fists", "damage": 1, "mining_strength": 0.3}

## Register all default items
func _register_default_items() -> void:
	# Create items programmatically (can be replaced with .tres files later)
	_register_tools()
	_register_weapons()
	_register_resources()

func _register_tools() -> void:
	# Stone Pickaxe
	var pickaxe = ItemDataScript.new()
	pickaxe.id = "stone_pickaxe"
	pickaxe.display_name = "Stone Pickaxe"
	pickaxe.category = ItemDataScript.ItemCategory.TOOL
	pickaxe.damage = 5
	pickaxe.mining_strength = 1.5
	pickaxe.max_stack = 1
	register(pickaxe)
	
	# Stone Axe
	var axe = ItemDataScript.new()
	axe.id = "stone_axe"
	axe.display_name = "Stone Axe"
	axe.category = ItemDataScript.ItemCategory.TOOL
	axe.damage = 3
	axe.mining_strength = 1.0
	axe.max_stack = 1
	axe.first_person_scene = "res://game/assets/player_axe/1/animated_fps_axe.glb"
	register(axe)

func _register_weapons() -> void:
	# Heavy Pistol
	var pistol = ItemDataScript.new()
	pistol.id = "heavy_pistol"
	pistol.display_name = "Heavy Pistol"
	pistol.category = ItemDataScript.ItemCategory.PROP
	pistol.damage = 5
	pistol.is_firearm = true
	pistol.max_stack = 1
	pistol.world_scene = "res://models/pistol/heavy_pistol_physics.tscn"
	pistol.first_person_scene = "res://models/pistol/heavy_pistol_animated.glb"
	register(pistol)

func _register_resources() -> void:
	# Dirt
	var dirt = ItemDataScript.new()
	dirt.id = "dirt"
	dirt.display_name = "Dirt"
	dirt.category = ItemDataScript.ItemCategory.RESOURCE
	dirt.max_stack = 64
	dirt.material_id = 100  # Grass material
	register(dirt)
	
	# Stone
	var stone = ItemDataScript.new()
	stone.id = "stone"
	stone.display_name = "Stone"
	stone.category = ItemDataScript.ItemCategory.RESOURCE
	stone.max_stack = 64
	stone.material_id = 101  # Stone material
	register(stone)
	
	# Sand
	var sand = ItemDataScript.new()
	sand.id = "sand"
	sand.display_name = "Sand"
	sand.category = ItemDataScript.ItemCategory.RESOURCE
	sand.max_stack = 64
	sand.material_id = 102  # Sand material
	register(sand)
	
	# Snow
	var snow = ItemDataScript.new()
	snow.id = "snow"
	snow.display_name = "Snow"
	snow.category = ItemDataScript.ItemCategory.RESOURCE
	snow.max_stack = 64
	snow.material_id = 103  # Snow material
	register(snow)
	
	# Wood
	var wood = ItemDataScript.new()
	wood.id = "veg_wood"
	wood.display_name = "Wood"
	wood.category = ItemDataScript.ItemCategory.RESOURCE
	wood.max_stack = 64
	register(wood)
	
	# Fiber
	var fiber = ItemDataScript.new()
	fiber.id = "veg_fiber"
	fiber.display_name = "Fiber"
	fiber.category = ItemDataScript.ItemCategory.RESOURCE
	fiber.max_stack = 64
	register(fiber)
	
	# Rock
	var rock = ItemDataScript.new()
	rock.id = "veg_rock"
	rock.display_name = "Rock"
	rock.category = ItemDataScript.ItemCategory.RESOURCE
	rock.max_stack = 64
	register(rock)
