extends "res://modules/world_player_v2/features/feature_base.gd"
class_name CombatFeatureV2
## CombatFeature - Handles all combat-related actions (punch, tool attack, pistol fire)
## Extracts combat logic from mode_play.gd

# Constants (preserved from v1)
const ATTACK_COOLDOWN_TIME: float = 0.3
const BASE_ATTACK_COOLDOWN: float = 0.4
const MELEE_RANGE: float = 2.5
const TOOL_RANGE: float = 3.5

# V1 Constants for combo system
const PUNCH_COOLDOWN_TIME: float = 0.3
const ATTACK_COOLDOWN: float = 0.3
const COMBO_WINDOW: float = 0.8  # Time to chain combo
const MAX_COMBO: int = 3

# Cooldown state
var attack_cooldown: float = 0.0
var punch_ready: bool = true
var pistol_ready: bool = true
var axe_ready: bool = true
var combo_count: int = 0
var combo_timer: float = 0.0

# References
var inventory: Node = null

func _on_initialize() -> void:
	# Connect to animation ready signals
	PlayerSignalsV2.punch_ready.connect(_on_punch_ready)
	PlayerSignalsV2.pistol_fire_ready.connect(_on_pistol_fire_ready)
	PlayerSignalsV2.axe_ready.connect(_on_axe_ready)

func _physics_process(delta: float) -> void:
	if attack_cooldown > 0:
		attack_cooldown -= delta

## Handle primary action (LMB)
func handle_primary_action(item: Dictionary) -> void:
	if attack_cooldown > 0:
		return
	
	var category = item.get("category", 0)
	var item_id = item.get("id", "fists")
	
	# Firearm
	if item.get("is_firearm", false):
		_do_pistol_fire(item)
		return
	
	# Tool (axe, pickaxe)
	if category == 1:  # TOOL
		_do_tool_attack(item)
		return
	
	# Fists or other
	_do_punch(item)

## Punch attack
func _do_punch(item: Dictionary) -> void:
	if not punch_ready:
		return
	
	punch_ready = false
	attack_cooldown = ATTACK_COOLDOWN_TIME
	
	# Emit punch trigger for animation
	PlayerSignalsV2.punch_triggered.emit()
	
	# Raycast for target
	var hit = player.raycast(MELEE_RANGE, 0xFFFFFFFF, false, true)
	if hit.is_empty():
		return
	
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	var damage = item.get("damage", 1)
	
	# Find damageable
	var damageable = _find_damageable(target)
	if damageable:
		damageable.take_damage(damage)
		PlayerSignalsV2.damage_dealt.emit(damageable, damage)
		DebugSettings.log_player("CombatV2: Punch hit %s for %d damage" % [damageable.name, damage])
		return
	
	# Let mining feature handle terrain/objects
	var mining = player.get_feature("mining")
	if mining:
		mining.handle_damage(target, position, damage, item)

## Tool attack (axe, pickaxe)
func _do_tool_attack(item: Dictionary) -> void:
	var item_id = item.get("id", "")
	
	# Axe uses synchronized animation
	if "axe" in item_id:
		if not axe_ready:
			return
		axe_ready = false
		PlayerSignalsV2.axe_fired.emit()
	
	attack_cooldown = ATTACK_COOLDOWN_TIME
	
	# Raycast
	var hit = player.raycast(TOOL_RANGE, 0xFFFFFFFF, false, true)
	if hit.is_empty():
		return
	
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	var damage = item.get("damage", 1)
	
	# Axe bonus vs zombies
	var damageable = _find_damageable(target)
	if damageable:
		if "axe" in item_id and damageable.is_in_group("zombies"):
			damage = 10  # One-shot kill
		damageable.take_damage(damage)
		PlayerSignalsV2.damage_dealt.emit(damageable, damage)
		return
	
	# Let mining feature handle terrain/objects
	var mining = player.get_feature("mining")
	if mining:
		mining.handle_damage(target, position, damage, item)

## Pistol fire
func _do_pistol_fire(item: Dictionary) -> void:
	if not pistol_ready:
		return
	
	pistol_ready = false
	
	# Emit pistol trigger for animation
	PlayerSignalsV2.pistol_fired.emit()
	
	# Raycast for target
	var hit = player.raycast(100.0, 0xFFFFFFFF, false, true)
	if hit.is_empty():
		return
	
	var target = hit.get("collider")
	var position = hit.get("position", Vector3.ZERO)
	var damage = item.get("damage", 5)
	
	# Spawn hit effect
	_spawn_hit_effect(position, hit.get("normal", Vector3.UP))
	
	# Check for zombie
	if target and target.is_in_group("zombies") and target.has_method("take_damage"):
		target.take_damage(damage)
		PlayerSignalsV2.damage_dealt.emit(target, damage)
		DebugSettings.log_player("CombatV2: Pistol hit zombie for %d damage" % damage)
		return
	
	# Check for damageable
	var damageable = _find_damageable(target)
	if damageable:
		damageable.take_damage(damage)
		PlayerSignalsV2.damage_dealt.emit(damageable, damage)

## Find damageable node in hierarchy
func _find_damageable(node: Node) -> Node:
	if not node:
		return null
	
	if node.has_method("take_damage"):
		return node
	
	var parent = node.get_parent()
	for i in 5:
		if not parent:
			break
		if parent.has_method("take_damage"):
			return parent
		parent = parent.get_parent()
	
	return null

## Spawn hit effect
func _spawn_hit_effect(position: Vector3, normal: Vector3) -> void:
	# TODO: Particle effect at hit location
	pass

## Animation ready callbacks
func _on_punch_ready() -> void:
	punch_ready = true

func _on_pistol_fire_ready() -> void:
	pistol_ready = true

func _on_axe_ready() -> void:
	axe_ready = true
