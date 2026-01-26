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

@onready var vbox_container = $MarginContainer/VBoxContainer
var opt_material: OptionButton

func _ready():
	# Populate options (safe to do before finding nodes)
	# Wait for children to be ready
	await get_tree().process_frame
	
	_setup_options()
	_inject_material_ui() # Programmatically add Material Row
	
	if DebugManager.brush_runtime_config:
		config = DebugManager.brush_runtime_config
		config.settings_changed.connect(_on_config_changed)
		_update_ui_from_config()
	
	_connect_signals()

func _inject_material_ui():
	# Check if already added
	if vbox_container.has_node("MaterialRow"):
		return
		
	var h_box = HBoxContainer.new()
	h_box.name = "MaterialRow"
	
	var label = Label.new()
	label.text = "Material"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h_box.add_child(label)
	
	opt_material = OptionButton.new()
	opt_material.name = "OptionButton"
	opt_material.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	opt_material.add_item("Don't Change (-1)", 0)
	opt_material.set_item_metadata(0, -1)
	
	opt_material.add_item("Grass (0)", 1)
	opt_material.set_item_metadata(1, 0)
	
	opt_material.add_item("Rock (1)", 2)
	opt_material.set_item_metadata(2, 1)
	
	opt_material.add_item("Stone (2)", 3)
	opt_material.set_item_metadata(3, 2)
	
	opt_material.add_item("Sand (3)", 4)
	opt_material.set_item_metadata(4, 3)
	
	opt_material.add_item("Snow (5)", 5)
	opt_material.set_item_metadata(5, 5)
	
	opt_material.add_item("Road (6)", 6)
	opt_material.set_item_metadata(6, 6)
	
	h_box.add_child(opt_material)
	vbox_container.add_child(h_box)
	
	# Connect signal
	opt_material.item_selected.connect(_on_material_selected)

func _on_material_selected(idx):
	var mat_id = opt_material.get_item_metadata(idx)
	if config: config.set_material_id(mat_id)

func _setup_options():
	if opt_shape.item_count == 0:
		opt_shape.add_item("Sphere", 0)
		opt_shape.add_item("Box", 1)
		opt_shape.add_item("Column", 2)
	
	if opt_mode.item_count == 0:
		opt_mode.add_item("Add (Dig)", 0)
		opt_mode.add_item("Subtract (Place)", 1)
		opt_mode.add_item("Paint", 2)
		opt_mode.add_item("Flatten", 3)
		opt_mode.add_item("Flatten (Fill)", 5)

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
	opt_mode.selected = opt_mode.get_item_index(config.mode)
	opt_mode.set_block_signals(false)
	
	if opt_material:
		opt_material.set_block_signals(true)
		# Find index for value
		var target_idx = 0
		for i in range(opt_material.item_count):
			if opt_material.get_item_metadata(i) == config.material_id:
				target_idx = i
				break
		opt_material.selected = target_idx
		opt_material.set_block_signals(false)

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
	var id = opt_mode.get_item_id(idx)
	if config: config.set_mode(id)

func _on_config_changed():
	_update_ui_from_config()
