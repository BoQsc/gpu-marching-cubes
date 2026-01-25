extends PanelContainer

@onready var check_enable = $MarginContainer/VBoxContainer/EnableRow/CheckButton
@onready var slider_radius = $MarginContainer/VBoxContainer/RadiusRow/HSlider
@onready var label_radius_val = $MarginContainer/VBoxContainer/RadiusRow/ValueLabel
@onready var slider_strength = $MarginContainer/VBoxContainer/StrengthRow/HSlider
@onready var label_strength_val = $MarginContainer/VBoxContainer/StrengthRow/ValueLabel
@onready var opt_shape = $MarginContainer/VBoxContainer/ShapeRow/OptionButton
@onready var opt_mode = $MarginContainer/VBoxContainer/ModeRow/OptionButton
@onready var check_snap = $MarginContainer/VBoxContainer/SnapRow/CheckButton
@onready var check_show_grid = $MarginContainer/VBoxContainer/ShowGridRow/CheckButton

var config: BrushRuntimeConfig

func _ready():
	# Populate options (safe to do before finding nodes)
	# Wait for children to be ready
	await get_tree().process_frame
	
	_setup_options()
	
	if DebugManager.brush_runtime_config:
		config = DebugManager.brush_runtime_config
		config.settings_changed.connect(_on_config_changed)
		_update_ui_from_config()
	
	_connect_signals()

func _setup_options():
	if opt_shape.item_count == 0:
		opt_shape.add_item("Sphere", 0)
		opt_shape.add_item("Box", 1)
		opt_shape.add_item("Column", 2)
	
	if opt_mode.item_count == 0:
		opt_mode.add_item("Add (Dig)", 0)
		opt_mode.add_item("Subtract (Place)", 1)
		opt_mode.add_item("Paint", 2)

func _connect_signals():
	check_enable.toggled.connect(_on_enable_toggled)
	check_snap.toggled.connect(_on_snap_toggled)
	check_show_grid.toggled.connect(_on_show_grid_toggled)
	
	slider_radius.value_changed.connect(_on_radius_changed)
	slider_radius.drag_ended.connect(_on_radius_drag_ended)
	
	slider_strength.value_changed.connect(_on_strength_changed)
	opt_shape.item_selected.connect(_on_shape_selected)
	opt_mode.item_selected.connect(_on_mode_selected)

func _update_ui_from_config():
	if not config: return
	
	# Block signals during update to prevent loop
	check_enable.set_block_signals(true)
	check_enable.button_pressed = config.override_enabled
	check_enable.set_block_signals(false)
	
	check_snap.set_block_signals(true)
	check_snap.button_pressed = config.snap_to_grid
	check_snap.set_block_signals(false)
	
	slider_radius.set_block_signals(true)
	slider_radius.value = config.radius
	slider_radius.set_block_signals(false)
	label_radius_val.text = "%.2f" % config.radius
	
	slider_strength.set_block_signals(true)
	slider_strength.value = config.strength
	slider_strength.set_block_signals(false)
	label_strength_val.text = "%.1f" % config.strength
	
	opt_shape.set_block_signals(true)
	opt_shape.selected = config.shape_type
	opt_shape.set_block_signals(false)
	
	opt_mode.set_block_signals(true)
	opt_mode.selected = config.mode
	opt_mode.set_block_signals(false)

func _on_enable_toggled(pressed):
	if config: config.override_enabled = pressed

func _on_snap_toggled(pressed):
	if config: config.set_snap(pressed)

func _on_show_grid_toggled(pressed):
	if DebugManager.grid_visualizer:
		DebugManager.grid_visualizer.set_enabled(pressed)

func _on_radius_changed(val):
	label_radius_val.text = "%.2f" % val
	# Update live
	if config: config.set_radius(val)

func _on_radius_drag_ended(_val_changed):
	# ensure final value is set
	if config: config.set_radius(slider_radius.value)

func _on_strength_changed(val):
	label_strength_val.text = "%.1f" % val
	if config: config.set_strength(val)

func _on_shape_selected(idx):
	if config: config.set_shape(idx)

func _on_mode_selected(idx):
	if config: config.set_mode(idx)

func _on_config_changed():
	_update_ui_from_config()
