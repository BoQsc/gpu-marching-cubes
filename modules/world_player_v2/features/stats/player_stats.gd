extends Node
## PlayerStatsV2 - Global player state that persists across scenes
## This autoload stores health, stamina, and other persistent player data.
## Preserves all functionality from v1.

# Health
var health: int = 10
var max_health: int = 10

# Stamina
var stamina: float = 100.0
var max_stamina: float = 100.0
var stamina_regen_rate: float = 10.0  # Per second

# State flags
var is_dead: bool = false

func _ready() -> void:
	DebugSettings.log_player("PlayerStatsV2: Autoload initialized")

func take_damage(amount: int, source: Node = null) -> void:
	if is_dead:
		return
	
	health -= amount
	health = max(0, health)
	DebugSettings.log_player("PlayerStatsV2: Took %d damage. Health: %d/%d" % [amount, health, max_health])
	
	PlayerSignalsV2.damage_received.emit(amount, source)
	
	if health <= 0:
		die()

func heal(amount: int) -> void:
	if is_dead:
		return
	
	health += amount
	health = min(health, max_health)
	DebugSettings.log_player("PlayerStatsV2: Healed %d. Health: %d/%d" % [amount, health, max_health])

func die() -> void:
	is_dead = true
	DebugSettings.log_player("PlayerStatsV2: Player died!")
	PlayerSignalsV2.player_died.emit()

func reset() -> void:
	health = max_health
	stamina = max_stamina
	is_dead = false
	DebugSettings.log_player("PlayerStatsV2: Reset to full")

func use_stamina(amount: float) -> bool:
	if stamina >= amount:
		stamina -= amount
		return true
	return false

func regen_stamina(delta: float) -> void:
	if stamina < max_stamina:
		stamina = min(stamina + stamina_regen_rate * delta, max_stamina)

func get_health_percent() -> float:
	return float(health) / float(max_health)

func get_stamina_percent() -> float:
	return stamina / max_stamina

## Save/Load support
func get_save_data() -> Dictionary:
	return {
		"health": health,
		"max_health": max_health,
		"stamina": stamina,
		"max_stamina": max_stamina,
		"is_dead": is_dead
	}

func load_save_data(data: Dictionary) -> void:
	health = data.get("health", max_health)
	max_health = data.get("max_health", 10)
	stamina = data.get("stamina", max_stamina)
	max_stamina = data.get("max_stamina", 100.0)
	is_dead = data.get("is_dead", false)
