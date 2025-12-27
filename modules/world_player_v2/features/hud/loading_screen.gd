extends CanvasLayer
class_name LoadingScreenV2
## LoadingScreenV2 - Loading screen UI for terrain generation

const FADE_DURATION: float = 0.5

@onready var background: ColorRect = $Background
@onready var progress_bar: ProgressBar = $ProgressBar
@onready var status_label: Label = $StatusLabel

var terrain_manager: Node = null
var is_loading: bool = true

func _ready() -> void:
	terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
	
	if background:
		background.color = Color.BLACK
	if progress_bar:
		progress_bar.value = 0
	if status_label:
		status_label.text = "Loading terrain..."
	
	DebugSettings.log_player("LoadingScreenV2: Initialized")

func _process(_delta: float) -> void:
	if not is_loading:
		return
	
	if not terrain_manager:
		terrain_manager = get_tree().get_first_node_in_group("terrain_manager")
		return
	
	# Get loading progress
	var progress = 0.0
	if terrain_manager.has_method("get_loading_progress"):
		progress = terrain_manager.get_loading_progress()
	
	if progress_bar:
		progress_bar.value = progress * 100.0
	
	if status_label:
		status_label.text = "Loading terrain... %d%%" % int(progress * 100.0)
	
	# Check if done
	if progress >= 1.0:
		_finish_loading()

## Finish loading and fade out
func _finish_loading() -> void:
	is_loading = false
	
	if status_label:
		status_label.text = "Loading complete!"
	
	# Fade out
	var tween = create_tween()
	tween.tween_property(self, "modulate:a", 0.0, FADE_DURATION)
	tween.tween_callback(_on_fade_complete)

func _on_fade_complete() -> void:
	visible = false
	DebugSettings.log_player("LoadingScreenV2: Fade complete")

## Show loading screen
func show_loading() -> void:
	visible = true
	modulate.a = 1.0
	is_loading = true
	if progress_bar:
		progress_bar.value = 0

## Hide loading screen
func hide_loading() -> void:
	_finish_loading()
