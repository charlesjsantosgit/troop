class_name BackpackInventoryUI
extends Control
## Small Minecraft-style slot grid shared by the ordinary and space packs.
## It refuses to appear without a backpack, mirroring LunarInventory's storage
## contract instead of merely hiding otherwise usable slots.

signal inventory_closed
signal slot_selected(index: int)

const COLUMNS := 6
const SLOT_SIZE := Vector2(64.0, 64.0)

var inventory: LunarInventory
var _panel: PanelContainer
var _grid: GridContainer
var _title: Label
var _buttons: Array[Button] = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build_ui()


func bind_inventory(source: LunarInventory) -> void:
	if inventory and inventory.changed.is_connected(_refresh):
		inventory.changed.disconnect(_refresh)
	if inventory and inventory.backpack_changed.is_connected(_on_backpack_changed):
		inventory.backpack_changed.disconnect(_on_backpack_changed)
	inventory = source
	if inventory:
		inventory.changed.connect(_refresh)
		inventory.backpack_changed.connect(_on_backpack_changed)
	_refresh()


func open_inventory() -> bool:
	if not inventory or not inventory.has_backpack():
		visible = false
		return false
	visible = true
	_refresh()
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	return true


func close_inventory() -> void:
	if not visible:
		return
	visible = false
	inventory_closed.emit()
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func displayed_slot_count() -> int:
	return _buttons.size()


func _build_ui() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0.015, 0.025, 0.055, 0.66)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_panel = PanelContainer.new()
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.055, 0.075, 0.12, 0.98)
	panel_style.border_color = Color(0.38, 0.72, 1.0, 0.9)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(18)
	panel_style.set_content_margin_all(20)
	_panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	_panel.add_child(column)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 20)
	_title.add_theme_color_override("font_color", Color(0.76, 0.9, 1.0))
	column.add_child(_title)
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 7)
	_grid.add_theme_constant_override("v_separation", 7)
	column.add_child(_grid)
	var hint := Label.new()
	hint.text = "Click a slot to select  ·  ESC to close"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.58, 0.67, 0.78))
	column.add_child(hint)


func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed \
			and (event.keycode == KEY_ESCAPE \
				or event.physical_keycode == KEY_ESCAPE):
		close_inventory()
		get_viewport().set_input_as_handled()


func _on_backpack_changed(_kind: int, _slot_count: int) -> void:
	if not inventory or not inventory.has_backpack():
		close_inventory()
	_refresh()


func _refresh() -> void:
	if not _grid:
		return
	var desired := inventory.slot_count() if inventory else 0
	while _buttons.size() < desired:
		var index := _buttons.size()
		var button := Button.new()
		button.custom_minimum_size = SLOT_SIZE
		button.add_theme_font_size_override("font_size", 12)
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var slot_style := StyleBoxFlat.new()
		slot_style.bg_color = Color(0.085, 0.11, 0.17)
		slot_style.border_color = Color(0.25, 0.34, 0.46)
		slot_style.set_border_width_all(2)
		slot_style.set_corner_radius_all(8)
		button.add_theme_stylebox_override("normal", slot_style)
		var hover := slot_style.duplicate()
		hover.bg_color = Color(0.13, 0.19, 0.28)
		hover.border_color = Color(0.55, 0.84, 1.0)
		button.add_theme_stylebox_override("hover", hover)
		button.pressed.connect(func() -> void: slot_selected.emit(index))
		_grid.add_child(button)
		_buttons.append(button)
	while _buttons.size() > desired:
		var button: Button = _buttons.pop_back()
		button.queue_free()
	if not inventory:
		_title.text = "NO BACKPACK"
		return
	_title.text = "SPACE BACKPACK  ·  %d SLOTS" % desired \
		if inventory.backpack_kind == LunarInventory.Backpack.SPACE \
		else "BACKPACK  ·  %d SLOTS" % desired
	var slots := inventory.slots_snapshot()
	for index in range(_buttons.size()):
		var item_id := StringName(slots[index].id)
		if item_id == &"":
			_buttons[index].text = ""
			_buttons[index].tooltip_text = "Empty slot"
			continue
		var item_count := int(slots[index].count)
		_buttons[index].text = "%s\n×%d" % [_item_icon(item_id), item_count]
		_buttons[index].tooltip_text = _item_label(item_id)


static func _item_icon(item_id: StringName) -> String:
	match item_id:
		LunarInventory.ITEM_BANANA:
			return "🍌"
		LunarInventory.ITEM_MOON_CHEESE:
			return "🧀"
	return "◆"


static func _item_label(item_id: StringName) -> String:
	return str(item_id).replace("_", " ").capitalize()
