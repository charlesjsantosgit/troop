class_name BackpackInventoryUI
extends Control
## Readable personal storage shared by ordinary and space backpacks.
## It refuses to appear without a backpack, mirroring LunarInventory's storage
## contract instead of merely hiding otherwise usable slots.

signal inventory_closed
signal slot_selected(index: int)

const COLUMNS := 6
const SLOT_SIZE := Vector2(108.0, 80.0)
const MenuTheme := preload("res://scripts/menu_theme.gd")

var inventory: LunarInventory
var _panel: PanelContainer
var _grid: GridContainer
var _title: Label
var _buttons: Array[Button] = []
var _capacity: Label
var _detail_title: Label
var _detail_body: Label
var _selected_slot := -1


func _ready() -> void:
	theme = MenuTheme.build()
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
	scrim.color = Color(0.025, 0.045, 0.04, 0.16)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	_panel = PanelContainer.new()
	_panel.minimum_size_changed.connect(_resize_panel, CONNECT_DEFERRED)
	_panel.add_theme_stylebox_override("panel", MenuTheme.panel())
	add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	_panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	titles.add_child(MenuTheme.label("PERSONAL STORAGE", 12, MenuTheme.ACCENT))
	_title = MenuTheme.label("Backpack", 30)
	titles.add_child(_title)
	_capacity = MenuTheme.label("", 15, MenuTheme.MUTED)
	titles.add_child(_capacity)
	var close_button := Button.new()
	close_button.text = "Close · Esc"
	close_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	MenuTheme.style_button(close_button)
	close_button.pressed.connect(close_inventory)
	header.add_child(close_button)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	column.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	scroll.add_child(_grid)
	var detail := PanelContainer.new()
	detail.add_theme_stylebox_override("panel", MenuTheme.panel(MenuTheme.INK))
	column.add_child(detail)
	var description := VBoxContainer.new()
	description.add_theme_constant_override("separation", 6)
	detail.add_child(description)
	_detail_title = MenuTheme.label("Select an item", 18, MenuTheme.ACCENT)
	description.add_child(_detail_title)
	_detail_body = MenuTheme.label("Choose a slot to see its contents and stack capacity.", 15, MenuTheme.MUTED)
	description.add_child(_detail_body)
	column.add_child(MenuTheme.label("Personal items travel with you. Colony harvests are stored separately in colony cargo.", 13, MenuTheme.MUTED))
	get_viewport().size_changed.connect(_resize_panel)
	_resize_panel()


func _resize_panel() -> void:
	if not _panel:
		return
	var screen := get_viewport_rect().size
	var wanted := Vector2(minf(580, screen.x - 80), minf(540, screen.y - 80))
	_panel.size = wanted
	_panel.position = (screen - wanted) * 0.5
	_grid.columns = 6 if wanted.x >= 730 else 4 if wanted.x >= 500 else 3


func _select_slot(index: int) -> void:
	_selected_slot = index
	_refresh()
	slot_selected.emit(index)


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
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		MenuTheme.style_button(button)
		button.add_theme_font_size_override("font_size", 14)
		button.pressed.connect(func() -> void: _select_slot(index))
		_grid.add_child(button)
		_buttons.append(button)
	while _buttons.size() > desired:
		var button: Button = _buttons.pop_back()
		button.queue_free()
	if not inventory:
		_title.text = "No backpack"
		_capacity.text = "Equip a backpack to carry personal items."
		return
	_title.text = "Space backpack" if inventory.backpack_kind == LunarInventory.Backpack.SPACE else "Backpack"
	var slots := inventory.slots_snapshot()
	var used := 0
	var item_total := 0
	for index in range(_buttons.size()):
		var item_id := StringName(slots[index].id)
		var button := _buttons[index]
		button.add_theme_stylebox_override("normal", MenuTheme.panel(MenuTheme.INSET,
			MenuTheme.ACCENT if index == _selected_slot else MenuTheme.BORDER, 8, 8))
		if item_id == &"":
			button.text = "Empty\nSlot %d" % (index + 1)
			button.tooltip_text = "Empty slot %d" % (index + 1)
			button.add_theme_color_override("font_color", MenuTheme.MUTED)
			continue
		used += 1
		var item_count := int(slots[index].count)
		item_total += item_count
		button.text = "%s\n×%d" % [_item_label(item_id), item_count]
		button.tooltip_text = "%s · %d / %d in this stack" % [_item_label(item_id), item_count, int(slots[index].max_stack)]
		button.add_theme_color_override("font_color", MenuTheme.TEXT)
	_capacity.text = "%d of %d slots used  ·  %d items  ·  %d slots free" % [used, desired, item_total, desired - used]
	if _selected_slot >= 0 and _selected_slot < slots.size():
		var selected: Dictionary = slots[_selected_slot]
		var item_id := StringName(selected.id)
		_detail_title.text = "Slot %d · %s" % [_selected_slot + 1, "Empty" if item_id == &"" else _item_label(item_id)]
		_detail_body.text = "Ready for the next item you collect." if item_id == &"" else "%d in this stack · Stack capacity %d\n%s" % [int(selected.count), int(selected.max_stack), _item_description(item_id)]
	else:
		_selected_slot = -1
		_detail_title.text = "Select an item"
		_detail_body.text = "Choose a slot to see its contents and stack capacity."


static func _item_description(item_id: StringName) -> String:
	match item_id:
		LunarInventory.ITEM_BANANA:
			return "A personal supply of bananas carried in your backpack."
		LunarInventory.ITEM_MOON_CHEESE:
			return "Cheese from the lunar supply counter. Personal backpack cheese is separate from colony harvest cargo."
	return "Stored in your personal backpack."


static func _item_icon(item_id: StringName) -> String:
	match item_id:
		LunarInventory.ITEM_BANANA:
			return "🍌"
		LunarInventory.ITEM_MOON_CHEESE:
			return "🧀"
	return "◆"


static func _item_label(item_id: StringName) -> String:
	return str(item_id).replace("_", " ").capitalize()
