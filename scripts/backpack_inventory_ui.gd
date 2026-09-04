class_name BackpackInventoryUI
extends Control
## A view of actual stock: town goods stay in the authority's inventory while
## expedition pockets keep their existing compact, travelling-item contract.
signal inventory_closed
signal slot_selected(index: int)

const COLUMNS := 6
const SLOT_SIZE := Vector2(106, 88)
const MenuTheme := preload("res://scripts/menu_theme.gd")
const InventoryTile := preload("res://scripts/inventory_tile.gd")

var inventory: LunarInventory
var controller: Node
var _panel: PanelContainer
var _grid: GridContainer
var _title: Label
var _buttons: Array[Button] = []
var _capacity: Label
var _meter: ProgressBar
var _detail_title: Label
var _detail_body: Label
var _hint: Label
var _tabs: HBoxContainer
var _goods_button: Button
var _pockets_button: Button
var _selected_slot := -1
var _selected_id := ""
var _pockets := false
var _rows: Array = []
var _motion: Tween
var _closing := false

func _ready() -> void:
	theme = MenuTheme.build(true)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build_ui()
	_refresh()

func bind_inventory(source: LunarInventory) -> void:
	if inventory and inventory.changed.is_connected(_refresh): inventory.changed.disconnect(_refresh)
	if inventory and inventory.backpack_changed.is_connected(_on_backpack_changed): inventory.backpack_changed.disconnect(_on_backpack_changed)
	inventory = source
	if inventory:
		inventory.changed.connect(_refresh)
		inventory.backpack_changed.connect(_on_backpack_changed)
	_refresh()

func bind_frontier(source: Node) -> void:
	if is_instance_valid(controller) and controller.backpack_changed.is_connected(refresh_from_state):
		controller.backpack_changed.disconnect(refresh_from_state)
	controller = source
	if is_instance_valid(controller): controller.backpack_changed.connect(refresh_from_state)
	_refresh()

func refresh_from_state() -> void:
	if visible: _refresh()

func open_inventory() -> bool:
	if not inventory or not inventory.has_backpack():
		visible = false
		return false
	_closing = false
	if _motion and _motion.is_valid(): _motion.kill()
	visible = true
	_refresh()
	_resize_panel()
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_panel.pivot_offset = _panel.size * 0.5
		_panel.scale = Vector2.ONE * 0.95
		_panel.modulate.a = 0.0
		_motion = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_motion.tween_property(_panel, "scale", Vector2.ONE, 0.24)
		_motion.tween_property(_panel, "modulate:a", 1.0, 0.16)
	if not _buttons.is_empty(): _buttons[0].grab_focus()
	return true

func close_inventory() -> void:
	if not visible or _closing: return
	if DisplayServer.get_name() == "headless":
		_finish_close()
		return
	_closing = true
	if _motion and _motion.is_valid(): _motion.kill()
	_motion = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_motion.tween_property(_panel, "scale", Vector2.ONE * 0.97, 0.12)
	_motion.tween_property(_panel, "modulate:a", 0.0, 0.12)
	_motion.chain().tween_callback(_finish_close)

func _finish_close() -> void:
	visible = false
	_closing = false
	_panel.scale = Vector2.ONE
	_panel.modulate.a = 1.0
	inventory_closed.emit()
	if DisplayServer.get_name() != "headless": Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func displayed_slot_count() -> int:
	return _buttons.size()

func _build_ui() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0.02, 0.025, 0.03, 0.16)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	_panel = PanelContainer.new()
	_panel.minimum_size_changed.connect(_resize_panel, CONNECT_DEFERRED)
	_panel.add_theme_stylebox_override("panel", MenuTheme.panel(MenuTheme.PANEL, MenuTheme.BORDER, 16, 16))
	add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	_panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	titles.add_child(MenuTheme.label("ROOTS & ROCKETS / FIELD GEAR", 11, MenuTheme.ACCENT))
	_title = MenuTheme.label("Your backpack", 24)
	titles.add_child(_title)
	_capacity = MenuTheme.label("", 13, MenuTheme.MUTED)
	titles.add_child(_capacity)
	var close_button := Button.new()
	close_button.text = "Close · I / Esc"
	close_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	MenuTheme.style_button(close_button, false, true)
	close_button.pressed.connect(close_inventory)
	header.add_child(close_button)
	_meter = ProgressBar.new()
	_meter.custom_minimum_size.y = 5
	_meter.show_percentage = false
	_meter.add_theme_stylebox_override("background", MenuTheme.panel(MenuTheme.INK, MenuTheme.INK, 0, 3))
	_meter.add_theme_stylebox_override("fill", MenuTheme.panel(MenuTheme.ACCENT, MenuTheme.ACCENT, 0, 3))
	column.add_child(_meter)
	_tabs = HBoxContainer.new()
	column.add_child(_tabs)
	_goods_button = Button.new()
	_goods_button.text = "Town goods"
	_goods_button.pressed.connect(func(): _set_pockets(false))
	_tabs.add_child(_goods_button)
	_pockets_button = Button.new()
	_pockets_button.text = "Personal pockets"
	_pockets_button.pressed.connect(func(): _set_pockets(true))
	_tabs.add_child(_pockets_button)
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
	detail.add_theme_stylebox_override("panel", MenuTheme.panel(MenuTheme.INK, MenuTheme.BORDER, 10, 12))
	column.add_child(detail)
	var description := VBoxContainer.new()
	description.add_theme_constant_override("separation", 4)
	detail.add_child(description)
	_detail_title = MenuTheme.label("Select an item", 16, MenuTheme.ACCENT)
	description.add_child(_detail_title)
	_detail_body = MenuTheme.label("", 13, MenuTheme.MUTED)
	description.add_child(_detail_body)
	_hint = MenuTheme.label("", 12, MenuTheme.MUTED)
	column.add_child(_hint)
	get_viewport().size_changed.connect(_resize_panel)
	_resize_panel()

func _resize_panel() -> void:
	if not _panel: return
	var screen := get_viewport_rect().size
	var wanted := Vector2(minf(740, screen.x - 48), minf(580, screen.y - 48))
	_panel.size = wanted
	_panel.position = (screen - _panel.size) * 0.5
	_grid.columns = clampi(floori((wanted.x - 32 + 8) / (SLOT_SIZE.x + 8)), 2, COLUMNS)

func _set_pockets(value: bool) -> void:
	_pockets = value
	_selected_slot = -1
	_selected_id = ""
	_refresh()

func _select_slot(index: int) -> void:
	_selected_slot = index
	_selected_id = str(_rows[index].id) if index < _rows.size() else ""
	_refresh()
	slot_selected.emit(index)

func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo \
		and (event.keycode == KEY_ESCAPE or event.physical_keycode in [KEY_ESCAPE, KEY_I]):
		close_inventory()
		get_viewport().set_input_as_handled()

func _on_backpack_changed(_kind: int, _slot_count: int) -> void:
	if not inventory or not inventory.has_backpack(): close_inventory()
	_refresh()

func _refresh() -> void:
	if not _grid: return
	var goods_mode := is_instance_valid(controller) and not _pockets
	_tabs.visible = is_instance_valid(controller)
	MenuTheme.style_button(_goods_button, goods_mode, true)
	MenuTheme.style_button(_pockets_button, not goods_mode, true)
	_rows = []
	if goods_mode:
		_rows = controller.backpack_items()
	elif inventory:
		for slot: Dictionary in inventory.slots_snapshot():
			_rows.append({"id": str(slot.id), "name": _item_label(slot.id) if not str(slot.id).is_empty() else "Empty pocket",
				"count": int(slot.count), "category": "Personal", "max_stack": int(slot.max_stack)})
	var desired := maxi(1, _rows.size()) if goods_mode else _rows.size()
	while _buttons.size() > desired:
		var button: Button = _buttons.pop_back()
		_grid.remove_child(button)
		button.queue_free()
	while _buttons.size() < desired:
		var index := _buttons.size()
		var button := InventoryTile.new()
		button.pressed.connect(func(): _select_slot(index))
		_grid.add_child(button)
		_buttons.append(button)
	if goods_mode:
		_selected_slot = -1
		for i in _rows.size():
			if str(_rows[i].id) == _selected_id: _selected_slot = i
	var used := 0
	var count := 0
	for index in _buttons.size():
		var row: Dictionary = _rows[index] if index < _rows.size() else {"id":"", "name":"Empty backpack", "count":0, "category":""}
		_buttons[index].configure(str(row.id), str(row.name), int(row.count), str(row.category))
		_buttons[index].set_selected(index == _selected_slot)
		if int(row.count) > 0: used += 1
		count += int(row.count)
	var capacity := int(controller.backpack_capacity()) if goods_mode else desired
	var occupied := count if goods_mode else used
	_meter.max_value = maxi(1, capacity)
	_meter.value = occupied
	_title.text = ("Earth backpack" if controller.current_planet() == "earth" else "Moon backpack") if goods_mode else "Personal pockets"
	_capacity.text = "%d / %d goods · %d item types" % [count, capacity, used] if goods_mode else "%d / %d pockets · %d items" % [used, desired, count]
	_hint.text = "Visit a merchant and press E to buy or sell. Earth and Moon supplies travel through the cargo terminal." if goods_mode else "These pocket items travel with you. Town goods have their own inventory tab."
	if not is_instance_valid(controller): _hint.text = "Your field pack stays equipped on Earth; the suit supplies a larger pack on the Moon."
	if _selected_slot >= 0 and _selected_slot < _rows.size():
		var selected: Dictionary = _rows[_selected_slot]
		_detail_title.text = str(selected.name)
		_detail_body.text = "%d available · %s. Select this tile at a merchant to sell; work uses these same supplies." % [int(selected.count), str(selected.category)] if goods_mode else _item_description(StringName(selected.id))
	else:
		_detail_title.text = "Your backpack is empty" if goods_mode and _rows.is_empty() else "Select an item"
		_detail_body.text = "Buy supplies at the market or harvest a ripe crop. Capacity is checked before goods enter your backpack." if goods_mode else "Choose a pocket to see its contents. Empty pockets are ready for the next item you collect."

static func _item_description(item_id: StringName) -> String:
	match item_id:
		LunarInventory.ITEM_BANANA: return "Personal banana snacks, separate from your town's trading supplies."
		LunarInventory.ITEM_MOON_CHEESE: return "Moon Cheese from the lunar supply counter. Carried between worlds in your personal pockets."
	return "Ready for the next item you collect." if item_id == &"" else "Stored in your personal pockets."

static func _item_icon(item_id: StringName) -> String:
	return "◆"

static func _item_label(item_id: StringName) -> String:
	return str(item_id).replace("_", " ").capitalize()
