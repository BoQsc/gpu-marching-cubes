extends CanvasLayer
class_name PlayerHUDV2
## PlayerHUDV2 - Main HUD for world_player_v2
## Displays mode, hotbar, health, stamina, crosshair, interaction prompts

# References
@onready var mode_label: Label = $ModeIndicator
@onready var crosshair: TextureRect = $Crosshair
@onready var interaction_prompt: Label = $InteractionPrompt
@onready var health_bar: ProgressBar = $StatusBars/HealthBar
@onready var stamina_bar: ProgressBar = $StatusBars/StaminaBar
@onready var hotbar_container: HBoxContainer = $HotbarContainer
@onready var selected_item_label: Label = $SelectedItemLabel
@onready var durability_bar: ProgressBar = $DurabilityBar
@onready var target_material_label: Label = $TargetMaterialLabel
@onready var underwater_overlay: ColorRect = $UnderwaterOverlay

# Durability tracking
var durability_memory: Dictionary = {}
var last_hit_target_key: String = ""
const DURABILITY_PERSIST_MS: int = 6000

func _ready() -> void:
	# Connect to signals
	PlayerSignalsV2.mode_changed.connect(_on_mode_changed)
	PlayerSignalsV2.item_changed.connect(_on_item_changed)
	PlayerSignalsV2.hotbar_slot_selected.connect(_on_hotbar_slot_selected)
	PlayerSignalsV2.interaction_available.connect(_on_interaction_available)
	PlayerSignalsV2.interaction_unavailable.connect(_on_interaction_unavailable)
	PlayerSignalsV2.durability_hit.connect(_on_durability_hit)
	PlayerSignalsV2.durability_cleared.connect(_on_durability_cleared)
	PlayerSignalsV2.target_material_changed.connect(_on_target_material_changed)
	PlayerSignalsV2.camera_underwater_toggled.connect(_on_camera_underwater_toggled)
	PlayerSignalsV2.inventory_changed.connect(_on_inventory_changed)
	
	# Initial state
	if mode_label:
		mode_label.text = "PLAY"
	if interaction_prompt:
		interaction_prompt.visible = false
	if durability_bar:
		durability_bar.visible = false
	if underwater_overlay:
		underwater_overlay.visible = false
		underwater_overlay.color = Color(0.05, 0.2, 0.12, 0.4)
	
	_setup_hotbar()
	DebugSettings.log_player("PlayerHUDV2: Initialized")

func _process(_delta: float) -> void:
	_update_status_bars()
	_update_durability_visibility()

## Setup hotbar display
func _setup_hotbar() -> void:
	if not hotbar_container:
		return
	
	# Create 10 slot visuals
	for i in 10:
		var slot = Panel.new()
		slot.custom_minimum_size = Vector2(50, 50)
		slot.name = "Slot%d" % i
		
		var label = Label.new()
		label.name = "ItemLabel"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.anchors_preset = Control.PRESET_FULL_RECT
		slot.add_child(label)
		
		hotbar_container.add_child(slot)
	
	_refresh_hotbar_display()

## Refresh hotbar display
func _refresh_hotbar_display() -> void:
	if not hotbar_container:
		return
	
	var inventory = _get_inventory()
	if not inventory:
		return
	
	var selected = inventory.get_selected_index()
	
	for i in hotbar_container.get_child_count():
		var slot = hotbar_container.get_child(i)
		var item = inventory.get_item_at(i)
		
		var label = slot.get_node_or_null("ItemLabel")
		if label:
			var name = item.get("name", "")
			if name == "Fists" or name.is_empty():
				label.text = ""
			else:
				var count = item.get("count", 1)
				label.text = "%s\nx%d" % [name, count] if count > 1 else name
		
		# Highlight selected
		if i == selected:
			slot.modulate = Color.YELLOW
		else:
			slot.modulate = Color.WHITE

## Update status bars
func _update_status_bars() -> void:
	if health_bar:
		health_bar.value = PlayerStatsV2.health
		health_bar.max_value = PlayerStatsV2.max_health
	if stamina_bar:
		stamina_bar.value = PlayerStatsV2.stamina
		stamina_bar.max_value = PlayerStatsV2.max_stamina

## Update durability visibility
func _update_durability_visibility() -> void:
	if not durability_bar:
		return
	
	var now = Time.get_ticks_msec()
	var any_visible = false
	
	for key in durability_memory:
		var entry = durability_memory[key]
		if now - entry["hit_time"] < DURABILITY_PERSIST_MS:
			any_visible = true
			durability_bar.value = entry["hp_percent"] * 100.0
			break
	
	durability_bar.visible = any_visible

## Get inventory feature
func _get_inventory() -> Node:
	var player = get_tree().get_first_node_in_group("player")
	if player and player.has_method("get_feature"):
		return player.get_feature("inventory")
	return null

## Signal handlers
func _on_mode_changed(_old_mode: String, new_mode: String) -> void:
	if mode_label:
		mode_label.text = new_mode
		match new_mode:
			"PLAY": mode_label.modulate = Color.WHITE
			"BUILD": mode_label.modulate = Color.CYAN
			"EDITOR": mode_label.modulate = Color.YELLOW

func _on_item_changed(_slot: int, item: Dictionary) -> void:
	if selected_item_label:
		selected_item_label.text = item.get("name", "Fists")
	_refresh_hotbar_display()

func _on_hotbar_slot_selected(_slot: int) -> void:
	_refresh_hotbar_display()

func _on_interaction_available(_target: Node, prompt: String) -> void:
	if interaction_prompt:
		interaction_prompt.text = prompt
		interaction_prompt.visible = true

func _on_interaction_unavailable() -> void:
	if interaction_prompt:
		interaction_prompt.visible = false

func _on_durability_hit(current_hp: int, max_hp: int, target_name: String, target_ref: Variant) -> void:
	var key = str(target_ref)
	durability_memory[key] = {
		"target_ref": target_ref,
		"hit_time": Time.get_ticks_msec(),
		"hp_percent": float(current_hp) / float(max_hp)
	}
	last_hit_target_key = key

func _on_durability_cleared() -> void:
	if not last_hit_target_key.is_empty():
		durability_memory.erase(last_hit_target_key)
		last_hit_target_key = ""

func _on_target_material_changed(material_name: String) -> void:
	if target_material_label:
		target_material_label.text = material_name
		target_material_label.visible = not material_name.is_empty()

func _on_camera_underwater_toggled(is_underwater: bool) -> void:
	if underwater_overlay:
		underwater_overlay.visible = is_underwater

func _on_inventory_changed() -> void:
	_refresh_hotbar_display()
