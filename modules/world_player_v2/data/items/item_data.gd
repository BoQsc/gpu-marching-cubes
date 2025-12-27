extends Resource
class_name ItemDataV2
## ItemData resource - Single Source of Truth for item definitions
## Items are defined as .tres files and registered with ItemRegistry

## Unique identifier for this item
@export var id: String = ""

## Display name shown in UI
@export var display_name: String = ""

## Item icon texture
@export var icon: Texture2D

## Item category
@export var category: ItemCategory = ItemCategory.NONE

## Maximum stack size (1 for non-stackable)
@export var max_stack: int = 1

## Base damage dealt
@export var damage: int = 1

## Mining strength (terrain modification power)
@export var mining_strength: float = 0.5

## Whether this item is a firearm
@export var is_firearm: bool = false

## Scene path for world representation (dropped item)
@export_file("*.tscn") var world_scene: String = ""

## Scene path for first-person view
@export_file("*.tscn") var first_person_scene: String = ""

## Material ID for resources (terrain materials)
@export var material_id: int = -1

## Item categories
enum ItemCategory {
	NONE = 0,      # Fists / empty
	TOOL = 1,      # Pickaxe, Axe, Shovel
	BUCKET = 2,    # Water bucket
	RESOURCE = 3,  # Dirt, Stone, Sand
	BLOCK = 4,     # Building blocks
	OBJECT = 5,    # Doors, furniture
	PROP = 6       # Physics props, weapons
}

## Convert to dictionary (for legacy compatibility)
func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": display_name,
		"category": category,
		"damage": damage,
		"mining_strength": mining_strength,
		"is_firearm": is_firearm,
		"scene": world_scene,
		"max_stack": max_stack,
		"material_id": material_id
	}
