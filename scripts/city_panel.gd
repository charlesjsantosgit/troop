class_name CityPanel
extends Control
## Contextual doors, cupboards and workplaces. Only the physical subject that
## opened this panel gets resource actions; the city guide offers navigation.
signal closed
const MenuTheme = preload("res://scripts/menu_theme.gd")
const InventoryTile = preload("res://scripts/inventory_tile.gd")
const Plan = preload("res://scripts/city_plan.gd")
var controller: Node
var context: Dictionary = {}
var _view: Dictionary = {}
var _panel: PanelContainer
var _body: VBoxContainer
var _heading: Label
var _subtitle: Label
var _wallet: Label
var _notice: Label
var _scroll: ScrollContainer
var _help: VBoxContainer
var _live: Array = []
var _actions: Array = []
var _structure := ""
var _pending := false
var _selected_item := ""
var _selected_side := "backpack"
var _retail_quantity := 1
var _retail_item := ""
var _quantity := 1
var _tiles: Array = []
var _motion: Tween
var _closing := false
var _view_received_msec := 0
var _clock_label: Label
var _clock_accumulator := 0.0
var _selected_district := ""
var _selected_job := ""

class RoomPreview extends Control:
	var warehouse := false
	func _draw() -> void:
		var room := Rect2(Vector2(12, 12), size - Vector2(24, 24))
		draw_style_box(TroopMenuTheme.panel(Color("384247"), Color("718080"), 0, 8), room)
		var inset := room.grow(-14)
		draw_rect(Rect2(inset.position, Vector2(inset.size.x * 0.27, inset.size.y * 0.4)), Color("9aaf99"))
		draw_rect(Rect2(inset.position + Vector2(inset.size.x * 0.72, 0), Vector2(inset.size.x * 0.28, inset.size.y * 0.28)), Color("c2a678"))
		draw_rect(Rect2(inset.position + Vector2(0, inset.size.y * 0.6), Vector2(inset.size.x * 0.18, inset.size.y * 0.28)), Color("b1a58d"))
		draw_rect(Rect2(inset.position + Vector2(inset.size.x * 0.73, inset.size.y * 0.6), Vector2(inset.size.x * 0.25, inset.size.y * 0.2)), Color("a88967"))
		var gap := Rect2(Vector2(room.get_center().x - 13, room.end.y - 4), Vector2(26, 8))
		draw_rect(gap, TroopMenuTheme.PANEL)
		draw_line(gap.get_center() + Vector2(0, 12), gap.get_center() + Vector2(0, -16), TroopMenuTheme.ACCENT, 2)
		if warehouse:
			for offset in [0.22, 0.45, 0.68]:
				draw_rect(Rect2(inset.position + Vector2(0, inset.size.y * offset), Vector2(inset.size.x * 0.27, 6)), Color("d6b678"))
				draw_rect(Rect2(inset.position + Vector2(inset.size.x * 0.72, inset.size.y * offset), Vector2(inset.size.x * 0.28, 6)), Color("d6b678"))

func configure(owner_controller: Node) -> void:
	controller = owner_controller

func _ready() -> void:
	theme = MenuTheme.build(true)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.025, 0.03, 0.14)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	_panel = PanelContainer.new()
	_panel.name = "CityPanel"
	_panel.add_theme_stylebox_override("panel", MenuTheme.panel(MenuTheme.PANEL, MenuTheme.BORDER, 16, 14))
	add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_panel.add_child(column)
	var top := _row(column)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 3)
	top.add_child(titles)
	_heading = MenuTheme.label("Crownreach", 24)
	_heading.autowrap_mode = TextServer.AUTOWRAP_OFF
	_heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	titles.add_child(_heading)
	_subtitle = MenuTheme.label("", 12, MenuTheme.MUTED)
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_OFF
	_subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	titles.add_child(_subtitle)
	_wallet = MenuTheme.label("", 14, MenuTheme.ACCENT)
	_wallet.autowrap_mode = TextServer.AUTOWRAP_OFF
	_wallet.size_flags_horizontal = Control.SIZE_SHRINK_END
	top.add_child(_wallet)
	_button(top, "Close · Esc", close, "close")
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	column.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 10)
	_scroll.add_child(_body)
	_help = VBoxContainer.new()
	_help.add_theme_constant_override("separation", 4)
	_help.visible = false
	column.add_child(_help)
	_help.add_child(MenuTheme.label("Your first home", 14, MenuTheme.ACCENT))
	_help.add_child(MenuTheme.label("1  Follow a marker to a door and press E. Check the price and storage before buying.\n2  Enter your own property. Use its cupboard to move goods, or its bed to set your home.\n3  Visit a job board, accept one job, then follow its destination and finish there to earn credits.", 12, MenuTheme.TEXT))
	var bottom := _row(column)
	_notice = MenuTheme.label("", 12, MenuTheme.MUTED)
	_notice.custom_minimum_size.y = 32
	bottom.add_child(_notice)
	_button(bottom, "How it works", func(): _help.visible = not _help.visible, "help")
	get_viewport().size_changed.connect(_resize_panel)
	_panel.minimum_size_changed.connect(_queue_resize)
	_resize_panel()

func open(subject: Dictionary) -> void:
	get_viewport().gui_release_focus()
	_scroll.scroll_vertical = 0
	context = subject.duplicate(true)
	_structure = ""
	_selected_item = ""
	_selected_side = "backpack"
	_quantity = 1
	_closing = false
	if _motion and _motion.is_valid(): _motion.kill()
	visible = true
	refresh_view()
	_resize_panel()
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_panel.pivot_offset = _panel.size * 0.5
		_panel.scale = Vector2.ONE * 0.97
		_panel.modulate.a = 0.0
		_motion = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_motion.tween_property(_panel, "scale", Vector2.ONE, 0.18)
		_motion.tween_property(_panel, "modulate:a", 1.0, 0.14)
	call_deferred("_focus_first")

func close() -> void:
	if not visible or _closing: return
	_closing = true
	if _motion and _motion.is_valid(): _motion.kill()
	if DisplayServer.get_name() == "headless":
		_finish_close()
		return
	_motion = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_motion.tween_property(_panel, "scale", Vector2.ONE * 0.98, 0.1)
	_motion.tween_property(_panel, "modulate:a", 0.0, 0.1)
	_motion.chain().tween_callback(_finish_close)

func _finish_close() -> void:
	visible = false
	_closing = false
	_panel.scale = Vector2.ONE
	_panel.modulate.a = 1.0
	closed.emit()
	if is_instance_valid(controller) and controller.has_method("close_panel"):
		controller.close_panel()

func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func refresh_view() -> void:
	if not _panel or not is_instance_valid(controller) or not controller.has_method("city_view"): return
	var fresh: Variant = controller.city_view()
	if not fresh is Dictionary: return
	_view = fresh
	_view_received_msec = Time.get_ticks_msec()
	_pending = bool(_view.get("action_pending", false))
	var structure := _structure_key()
	if structure != _structure:
		_structure = structure
		_rebuild()
	_refresh_live()

func _process(dt: float) -> void:
	if not visible or not is_instance_valid(_clock_label): return
	_clock_accumulator += dt
	if _clock_accumulator >= 0.2:
		_clock_accumulator = 0.0
		_clock_label.text = _job_timing()

func _resize_panel() -> void:
	if not _panel: return
	var viewport := get_viewport_rect().size
	_panel.size = Vector2(minf(900, viewport.x - 64), minf(610, viewport.y - 72))
	_panel.position = (viewport - _panel.size) * 0.5

func _queue_resize() -> void:
	# Wrapped text resolves after the containers receive their real width.
	# Refit once their minimum changes so an initial narrow label cannot leave
	# the panel with a stale, oversized height or off-screen position.
	call_deferred("_resize_panel")

func _structure_key() -> String:
	var own := _owned()
	var bag: Array = _bag_counts().keys().filter(func(id): return int(_bag_counts().get(id, 0)) > 0)
	bag.sort()
	var storage: Array = (own.get("storage", {}) as Dictionary).keys().filter(func(id): return int(_storage_counts().get(id, 0)) > 0)
	storage.sort()
	var job: Dictionary = _view.get("active_job", {})
	return JSON.stringify([str(context.get("kind", "info")), _building_id(), not own.is_empty(),
		own.get("is_home", false), own.get("storage_included", true), _is_unavailable(), bag, storage, job.get("id", ""),
		job.get("status", ""), job.get("carry_mode", ""), _view.get("job_catalog", []), _view.get("housing_catalog", []), _view.get("stops", []),
		(_view.get("districts", []) as Array).map(func(d): return [d.get("id"), d.get("name"), d.get("kind")]),
		(_view.get("owned_vehicles",[]) as Array).map(func(row):return [row.get("id"),row.get("model")]),
		(_view.get("retail_catalog", []) as Array).map(func(row): return [row.get("kind"), row.get("item"), row.get("label")])])

func _rebuild() -> void:
	var focus := get_viewport().gui_get_focus_owner()
	var focus_key := str(focus.get_meta("city_focus", "")) if focus else ""
	var scroll_y := _scroll.scroll_vertical
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_live.clear()
	_actions.clear()
	_tiles.clear()
	_clock_label = null
	var kind := str(context.get("kind", "info"))
	_heading.text = str(context.get("name", "Crownreach"))
	_subtitle.text = "CROWNREACH · " + _district_label()
	if kind in ["building", "interior", "info"] and not _retail_offer().is_empty():
		_build_retail()
	if kind in ["building","interior","info"] and preload("res://scripts/city_commerce.gd").category(Plan.building(_building_id()))=="dealership":
		_build_dealership()
	if kind.begins_with("civil_"):
		preload("res://scripts/civil_panel.gd").build(_body,controller,context)
	elif kind == "transit":
		_build_transit()
	elif kind == "storage":
		_build_storage()
	elif kind == "bed":
		_build_bed()
	elif kind == "exit":
		_build_exit()
	elif not str(context.get("housing", "")).is_empty():
		_build_property()
	elif kind in ["building", "interior"]:
		_build_workplace()
	else:
		_build_guide()
	preload("res://scripts/resident_life_panel.gd").build(_body,controller,_view,context)
	if kind=="building" and not _retail_offer().is_empty():
		preload("res://scripts/civil_panel.gd").build(_body,controller,context)
	call_deferred("_restore_focus", focus_key, scroll_y)

func _refresh_live() -> void:
	_wallet.text = "%s credits" % _number(int(_view.get("credits", 0)))
	for entry in _live:
		if is_instance_valid(entry.node): entry.node.text = str(entry.read.call())
	for entry in _actions:
		if not is_instance_valid(entry.node): continue
		entry.node.disabled = _pending or not bool(entry.allowed.call())
		if entry.has("text"): entry.node.text = str(entry.text.call())
	for tile in _tiles:
		if not is_instance_valid(tile.node): continue
		var stock := _bag_counts() if tile.side == "backpack" else _storage_counts()
		tile.node.set_item_count(int(stock.get(tile.id, 0)))
		tile.node.set_selected(tile.id == _selected_item and tile.side == _selected_side)
	var message: Variant = controller.get("last_message") if is_instance_valid(controller) else null
	_notice.text = "Waiting for the town… You can still close this panel." if _pending else str(message) if message != null and not str(message).is_empty() else "Visit a door, cupboard or job board to use its services."

func _build_property() -> void:
	# Delivery and repair work is the immediate purpose of these mixed-use
	# addresses, so keep the relevant action above the housing information.
	if _has_context_job(): _build_workplace(true)
	var tier := _tier()
	var workspace := _row(_body)
	var visual := PanelContainer.new()
	visual.custom_minimum_size = Vector2(220, 190)
	visual.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	visual.add_theme_stylebox_override("panel", MenuTheme.panel(MenuTheme.INK, MenuTheme.BORDER, 10, 10))
	workspace.add_child(visual)
	var preview_column := VBoxContainer.new()
	visual.add_child(preview_column)
	preview_column.add_child(MenuTheme.label(str(tier.get("label", "Property")), 16, MenuTheme.ACCENT))
	var preview := RoomPreview.new()
	preview.warehouse = str(tier.get("id", "")) == "warehouse"
	preview.custom_minimum_size.y = 120
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_column.add_child(preview)
	preview_column.add_child(MenuTheme.label("Furnished interior · walkable doorway", 11, MenuTheme.MUTED))
	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.size_flags_stretch_ratio = 1.45
	workspace.add_child(details)
	_live_label(details, func(): return "Your property" if not _owned().is_empty() else "Owned by another resident" if _is_unavailable() else "%s credits · one-time purchase" % _number(int(_tier().get("price", 0))), 20, MenuTheme.ACCENT)
	_live_label(details, func(): return "%s item storage · comfort %s / 6" % [_number(int(_tier().get("storage_capacity", 0))), int(_tier().get("luxury", 1))], 14)
	details.add_child(MenuTheme.label("Industrial space for bulk goods, shelving and deliveries. This is storage property, not a luxury home." if str(tier.get("id", "")) == "warehouse" else "A furnished home with a bed, cupboard and workbench. Buying gives you secure storage and a home address.", 13, MenuTheme.MUTED))
	_live_label(details, func(): return "%s / %s stored%s" % [_number(int(_owned().get("storage_used", 0))), _number(int(_owned().get("storage_capacity", 0))), " · Your return-home address" if bool(_owned().get("is_home", false)) else ""] if not _owned().is_empty() else "", 13)
	var actions := _row(_body)
	if _physical("interior"):
		_button(actions, "Return outside", func(): _controller_action("exit_building"), "exit")
		_body.add_child(MenuTheme.label("Walk to your cupboard for storage. Use your bed to set this as your home." if not _owned().is_empty() else "The workbench serves this workplace. The cupboard and bed belong to the property owner.", 12, MenuTheme.MUTED))
	elif _owned().is_empty():
		_action(actions, "Buy property", func(): _request("buy_home", {"building": _building_id()}),
			func(): return _physical("building") and not _is_unavailable() and int(_view.get("credits", 0)) >= int(_tier().get("price", 0)), "buy_home", true,
			func(): return "Buy · %s credits" % _number(int(_tier().get("price", 0))))
		_live_label(_body, func(): return "This property belongs to another player." if _is_unavailable() else "You need %s more credits. Visit a workplace to earn the difference." % _number(maxi(int(_tier().get("price", 0)) - int(_view.get("credits", 0)), 0)) if int(_view.get("credits", 0)) < int(_tier().get("price", 0)) else "Check the property type and price, then buy at this door.", 12, MenuTheme.MUTED)
		if _physical("building") and _has_context_job():
			_button(actions, "Visit workplace", func(): _controller_action("enter_building", _building_id()), "enter_workplace")
	elif _physical("building"):
		_button(actions, "Enter property", func(): _controller_action("enter_building", _building_id()), "enter", true)
	else:
		_button(actions, "Return outside", func(): _controller_action("exit_building"), "exit")
		_body.add_child(MenuTheme.label("Walk to your cupboard for storage. Use your bed to set this as your home.", 12, MenuTheme.MUTED))


func _retail_offer() -> Dictionary:
	var building := Plan.building(_building_id())
	if building.is_empty(): return {}
	var offers := preload("res://scripts/city_commerce.gd").offers(building)
	if offers.is_empty(): return {}
	var result: Dictionary = offers[0].duplicate()
	for row in offers:
		if row.item==_retail_item: result = row.duplicate()
	result["stock"] = int(_view.get("services",{}).get(result.service,{}).get("stock",{}).get(result.item,0))
	return result


func _can_buy_retail() -> bool:
	var offer := _retail_offer()
	return _physical("building") and not offer.is_empty() and _retail_quantity >= 1 and _retail_quantity <= 100 \
		and int(offer.get("stock", 0)) >= _retail_quantity \
		and int(_view.get("credits", 0)) >= int(offer.get("price", 0)) * _retail_quantity \
		and _count_all(_bag_counts()) + _retail_quantity <= int(_view.get("backpack_capacity", 350))


func _build_retail() -> void:
	var offer := _retail_offer()
	var card := _card(_body)
	card.add_child(MenuTheme.label(preload("res://scripts/city_commerce.gd").name_for(Plan.building(_building_id())),19,MenuTheme.ACCENT))
	var choices := OptionButton.new()
	choices.set_meta("city_focus","retail_selector")
	choices.custom_minimum_size.y = 38
	var offers := preload("res://scripts/city_commerce.gd").offers(Plan.building(_building_id()))
	for index in range(offers.size()):
		var item:Dictionary=offers[index]
		choices.add_item(str(item.label)+" · "+str(item.price)+" credits")
		if item.item==offer.item:choices.select(index)
	choices.item_selected.connect(func(index): _retail_item = str(offers[index].item); _refresh_live())
	card.add_child(choices)
	_live_label(card, func():
		var current := _retail_offer()
		return "%s · %s credits each · %s available" % [str(current.get("label", "Item")), _number(int(current.get("price", 0))), _number(int(current.get("stock", 0)))], 14)
	var actions := _row(card)
	var less := _button(actions, "−", func(): _retail_quantity = maxi(1, _retail_quantity - 1); _refresh_live(), "retail_minus")
	less.disabled = not _physical("building")
	_live_label(actions, func(): return str(_retail_quantity), 16)
	var more := _button(actions, "+", func(): _retail_quantity = mini(100, _retail_quantity + 1); _refresh_live(), "retail_plus")
	more.disabled = not _physical("building")
	_action(actions, "Buy", func():
		var current := _retail_offer()
		_request("buy_store_item", {"building": _building_id(), "item": str(current.get("item", "")), "quantity": _retail_quantity}),
		_can_buy_retail, "buy_store_item", true,
		func(): return "Buy · %s credits" % _number(int(_retail_offer().get("price", 0)) * _retail_quantity))
	_live_label(card, func():
		if not _physical("building"): return "Visit this shop's front door to buy."
		if int(_retail_offer().get("stock", 0)) == 0: return "Sold out. Nearby shops share the same finite supply."
		return "Purchases go directly into your Earth backpack.", 12, MenuTheme.MUTED)

func _build_dealership() -> void:
	var card := _card(_body)
	card.add_child(MenuTheme.label("CROWN MOTOR GALLERY",20,MenuTheme.ACCENT))
	card.add_child(MenuTheme.label("Browse ten full-size vehicles. Your purchase includes a persistent garage space and delivery in the rear court.",12,MenuTheme.MUTED))
	var fleet := preload("res://scripts/city_vehicle_models.gd").catalog()
	fleet.sort_custom(func(a,b):return str(a.label)<str(b.label))
	for spec in fleet:
		var row := _row(card)
		row.add_child(MenuTheme.label("%s · %.2fm × %.2fm · %s credits" % [spec.label,spec.length,spec.width,_number(int(spec.price))],13))
		_action(row,"Buy",func():_request("buy_vehicle",{"building":_building_id(),"model":str(spec.id)}),
			func():return _physical("building") and int(_view.get("credits",0))>=int(spec.price) and int(_view.get("vehicle_stock",{}).get(spec.id,0))>0 and _view.get("owned_vehicles",[]).size()<3,"buy_"+str(spec.id))
	for owned in _view.get("owned_vehicles",[]):
		var row := _row(card)
		row.add_child(MenuTheme.label("Your "+str(owned.model).replace("_"," "),13,MenuTheme.ACCENT))
		_action(row,"Collect at this dealer",func():_request("recall_vehicle",{"building":_building_id(),"vehicle":str(owned.id)}),func():return _physical("building"),"recall_"+str(owned.id))

func _build_storage() -> void:
	_heading.text = "Your storage"
	if _owned().is_empty():
		_body.add_child(MenuTheme.label("This cupboard belongs to another resident.", 16))
		return
	if not bool(_owned().get("storage_included", true)):
		_body.add_child(MenuTheme.label("Loading this property's cupboard…", 16, MenuTheme.ACCENT))
		_body.add_child(MenuTheme.label("Your property summary is ready. The cupboard's contents will appear when this room is confirmed.", 13, MenuTheme.MUTED))
		return
	_live_label(_body, func(): return "Home %s / %s items    ·    Backpack %s / %s items" % [_number(int(_owned().get("storage_used", 0))), _number(int(_owned().get("storage_capacity", 0))), _number(_count_all(_bag_counts())), _number(int(_view.get("backpack_capacity", 350)))], 13, MenuTheme.MUTED)
	var sides := _row(_body)
	for side in ["backpack", "storage"]:
		var group := VBoxContainer.new()
		group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sides.add_child(group)
		group.add_child(MenuTheme.label("Backpack" if side == "backpack" else "Home cupboard", 15, MenuTheme.ACCENT))
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size.y = 145 if get_viewport_rect().size.y < 600 else 170
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.follow_focus = true
		group.add_child(scroll)
		var grid := GridContainer.new()
		grid.columns = 3
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 6)
		scroll.add_child(grid)
		var stock := _bag_counts() if side == "backpack" else _storage_counts()
		var ids: Array = stock.keys()
		ids.sort()
		for id: String in ids:
			if int(stock[id]) <= 0: continue
			var tile := InventoryTile.new()
			tile.configure(id, _item_label(id), int(stock[id]), "goods")
			tile.custom_minimum_size = Vector2(106, 80)
			tile.set_meta("city_focus", "item_" + side + "_" + id)
			tile.pressed.connect(func(): _selected_item = id; _selected_side = side; _quantity = 1; _refresh_live())
			grid.add_child(tile)
			_tiles.append({"node": tile, "id": id, "side": side})
		if ids.is_empty():
			grid.add_child(MenuTheme.label("No goods here yet.", 13, MenuTheme.MUTED))
	if not _tiles.any(func(tile): return tile.id == _selected_item and tile.side == _selected_side):
		_selected_item = str(_tiles[0].id) if not _tiles.is_empty() else ""
		_selected_side = str(_tiles[0].side) if not _tiles.is_empty() else "backpack"
	var footer := _card(_body)
	_live_label(footer, func(): return _item_label(_selected_item) if not _selected_item.is_empty() else "Choose a carried item", 16, MenuTheme.ACCENT)
	var quantity_row := _row(footer)
	_button(quantity_row, "−", func(): _quantity = maxi(1, _quantity - 1); _refresh_live(), "quantity_minus")
	_live_label(quantity_row, func(): return str(_quantity), 15)
	_button(quantity_row, "+", func(): _quantity = mini(_quantity + 1, 100); _refresh_live(), "quantity_plus")
	_button(quantity_row, "All", func(): _quantity = mini(100, maxi(1, _selected_stock())); _refresh_live(), "quantity_all")
	_action(quantity_row, "Store", func(): _request("store_item" if _selected_side == "backpack" else "take_item", {"building": _building_id(), "item": _selected_item, "quantity": _quantity}),
		func(): return _physical("storage") and _selected_stock() >= _quantity and _transfer_room() >= _quantity, "transfer", true,
		func(): return "%s %s" % ["Store" if _selected_side == "backpack" else "Take", _quantity])
	_live_label(footer, func(): return "%s available · %s spaces at destination" % [_selected_stock(), maxi(0, _transfer_room())], 12, MenuTheme.MUTED)

func _build_bed() -> void:
	_heading.text = "Make yourself at home"
	_body.add_child(MenuTheme.label("Set this property as your home address. Your home marker will point back here.", 15))
	_live_label(_body, func(): return "This is already your home." if bool(_owned().get("is_home", false)) else "Your property · " + str(context.get("name", "Home")), 16, MenuTheme.ACCENT)
	_action(_row(_body), "Set as my home", func(): _request("set_home", {"building": _building_id()}),
		func(): return _physical("bed") and not _owned().is_empty() and not bool(_owned().get("is_home", false)) and bool(_tier().get("residential", true)), "set_home", true)

func _build_exit() -> void:
	_heading.text = "Head outside"
	_body.add_child(MenuTheme.label("Return to this property's front door. Your stored goods stay here.", 15))
	_button(_row(_body), "Return outside", func(): _controller_action("exit_building"), "exit", true)

func _build_workplace(property_context := false) -> void:
	var found := false
	var active: Dictionary = _view.get("active_job", {})
	if not active.is_empty():
		found = true
		var job_card := _card(_body)
		job_card.add_child(MenuTheme.label(str(active.get("label", "Your active job")), 19, MenuTheme.ACCENT))
		_clock_label = _live_label(job_card, _job_timing, 14)
		job_card.add_child(MenuTheme.label("Reward · %s credits" % _number(int(active.get("reward", 0))), 14))
		if str(active.get("destination_building", "")) == _building_id():
			_action(_row(job_card), "Finish job", func(): _request("finish_job", {}),
				func(): return _at_workplace() and _job_ready(), "finish_job", true)
		else:
			job_card.add_child(MenuTheme.label("Finish at the marked destination after the work time has passed.", 13, MenuTheme.MUTED))
			var destination: Variant = _destination_point(str(active.get("destination_building", "")))
			if destination != null: _button(_row(job_card), "Show destination", func(): _navigate(destination), "job_destination")
		if not (active.get("cargo", {}) as Dictionary).is_empty():
			job_card.add_child(MenuTheme.label(("Sealed job crate · " if str(active.get("carry_mode", "")) == "sealed_job_cargo" else "Delivery · ") + _items_text(active.cargo), 12, MenuTheme.MUTED))
			if str(active.get("carry_mode", "")) == "sealed_job_cargo":
				job_card.add_child(MenuTheme.label("Carried for this job, separate from your backpack goods.", 12, MenuTheme.MUTED))
	var jobs: Array = (_view.get("job_catalog", []) as Array).filter(func(job): return str(job.get("start_building", "")) == _building_id())
	if not jobs.is_empty():
		found = true
		if active.is_empty():
			_build_job_chooser(jobs)
		else:
			_body.add_child(MenuTheme.label("Finish your current assignment before taking another job here.", 12, MenuTheme.MUTED))
	if not property_context and _physical("building"):
		_button(_row(_body), "Visit inside", func(): _controller_action("enter_building", _building_id()), "enter_public")
	elif not property_context and str(context.get("kind", "")) == "interior":
		_button(_row(_body), "Return outside", func(): _controller_action("exit_building"), "exit")
	if not found and not property_context:
		_body.add_child(MenuTheme.label("A place in Crownreach", 20, MenuTheme.ACCENT))
		_body.add_child(MenuTheme.label("Use the city guide to find practical work, a home, or your next bus stop.", 14))
		_build_guide(false)

func _build_job_chooser(jobs: Array) -> void:
	if not jobs.any(func(job): return str(job.get("id", "")) == _selected_job):
		_selected_job = str(jobs[0].get("id", ""))
		for job in jobs:
			if bool(job.get("available", true)):
				_selected_job = str(job.id)
				break
	var section := _row(_body)
	var choices := VBoxContainer.new()
	choices.custom_minimum_size.x = 240
	choices.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	choices.size_flags_stretch_ratio = 0.8
	section.add_child(choices)
	choices.add_child(MenuTheme.label("Choose an assignment", 14, MenuTheme.ACCENT))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 208
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	choices.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 5)
	scroll.add_child(list)
	var selected: Dictionary = jobs[0]
	for row in jobs:
		var id := str(row.get("id", ""))
		if id == _selected_job: selected = row
		var button := _button(list, "%s\n%s credits · %ss" % [str(row.get("label", "Job")), _number(int(row.get("reward", 0))), int(row.get("duration", 0))], func():
			_selected_job = id
			_rebuild()
			_refresh_live(), "choose_job_" + id, id == _selected_job)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size.y = 44
	var card := _card(section)
	card.get_parent().size_flags_stretch_ratio = 1.4
	card.add_child(MenuTheme.label(str(selected.get("label", "Local job")), 18, MenuTheme.ACCENT))
	card.add_child(MenuTheme.label(str(selected.get("description", "")), 13, MenuTheme.TEXT))
	card.add_child(MenuTheme.label("%s credits · %s seconds · one job at a time" % [_number(int(selected.get("reward", 0))), int(selected.get("duration", 0))], 13, MenuTheme.MUTED))
	var required: Dictionary = selected.get("requires", {})
	if not required.is_empty(): card.add_child(MenuTheme.label("Bring " + _items_text(required), 12, MenuTheme.MUTED))
	var reason := str(selected.get("availability", ""))
	if not bool(selected.get("available", true)):
		card.add_child(MenuTheme.label(reason if not reason.is_empty() else "This job is waiting for supplies.", 12, MenuTheme.ACCENT))
	_action(_row(card), "Take this job", func(): _request("start_job", {"job": str(selected.get("id", ""))}),
		func(): return _at_workplace() and bool(selected.get("available", true)) and (_view.get("active_job", {}) as Dictionary).is_empty() and _has_items(required), "start_" + str(selected.get("id", "")), true,
		func(): return "Take this job" if bool(selected.get("available", true)) else "Currently unavailable")

func _build_transit() -> void:
	_heading.text = "Where are you heading?"
	_body.add_child(MenuTheme.label("%s credits per journey · choose a destination before boarding." % _number(int(_view.get("bus_fare", 6))), 13, MenuTheme.MUTED))
	for raw in _view.get("stops", []):
		var stop: Dictionary = raw
		if str(stop.get("id", "")) == str(context.get("id", "")): continue
		var card := _card(_body)
		var row := _row(card)
		row.add_child(MenuTheme.label(str(stop.get("name", "Transit stop")), 17, MenuTheme.ACCENT))
		_action(row, "Travel · %s credits" % _number(int(_view.get("bus_fare", 6))), func(): _controller_action("travel_to_stop", str(stop.get("id", ""))), func(): return _physical("transit") and int(_view.get("credits", 0)) >= int(_view.get("bus_fare", 6)), "travel_" + str(stop.get("id", "")), true)
	if (_view.get("stops", []) as Array).is_empty():
		_body.add_child(MenuTheme.label("The route board is loading. Close and check this stop again in a moment.", 14))

func _build_guide(include_heading := true) -> void:
	if include_heading: _heading.text = "Crownreach · Lantern Square"
	var city: Dictionary = _view.get("city", {})
	_body.add_child(MenuTheme.label("%s residents · %.1f square miles" % [_number(int(city.get("population", Plan.RESIDENT_TARGET))), float(city.get("area_sq_mi", Plan.SQUARE_MILES))], 18, MenuTheme.ACCENT))
	_body.add_child(MenuTheme.label("Start small, build a home, and work your way into the city. Property services belong to their doors and interiors.", 13, MenuTheme.MUTED))
	_build_district_conditions()
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(grid)
	for raw in _view.get("housing_catalog", []):
		var tier: Dictionary = raw
		var card := _card(grid)
		card.add_child(MenuTheme.label(str(tier.get("label", "Property")), 15, MenuTheme.ACCENT))
		card.add_child(MenuTheme.label("%s credits · %s storage" % [_number(int(tier.get("price", 0))), _number(int(tier.get("storage_capacity", 0)))], 12))
		card.add_child(MenuTheme.label("Comfort %s / 6%s" % [int(tier.get("luxury", 1)), " · bulk storage" if not bool(tier.get("residential", true)) else ""], 11, MenuTheme.MUTED))
	var services: Dictionary = _view.get("services", {})
	if not services.is_empty():
		var row := HFlowContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_body.add_child(row)
		for id: String in services:
			var service: Dictionary = services[id]
			_button(row, str(service.get("label", id)), func(): _navigate(service.get("door", Vector3.ZERO)), "navigate_" + id)

func _build_district_conditions() -> void:
	var districts: Array = _view.get("districts", [])
	if districts.is_empty(): return
	if not districts.any(func(d): return str(d.get("id", "")) == _selected_district):
		_selected_district = str(districts[0].get("id", ""))
		for district in districts:
			if str(context.get("district", "")) in [str(district.get("id", "")), str(district.get("name", ""))]:
				_selected_district = str(district.get("id", ""))
	var card := _card(_body)
	var header := _row(card)
	header.add_child(MenuTheme.label("District conditions", 16, MenuTheme.ACCENT))
	var choice := OptionButton.new()
	choice.set_meta("city_focus", "district_selector")
	MenuTheme.style_button(choice, false, true)
	for index in range(districts.size()):
		choice.add_item(str(districts[index].get("name", "District")))
		choice.set_item_metadata(index, str(districts[index].get("id", "")))
		if str(districts[index].get("id", "")) == _selected_district: choice.select(index)
	choice.item_selected.connect(func(index): _selected_district = str(choice.get_item_metadata(index)); _refresh_live())
	header.add_child(choice)
	var stats := _row(card)
	_live_label(stats, func(): return "Food reserve\n%s / 400 · %s used/min" % [_number(int(_district().get("food_stock", 0))), _number(int(_district().get("food_demand", 0)))], 13)
	_live_label(stats, func(): return "Working residents\n%s / %s" % [_number(int(_district().get("workforce", 0))), _number(int(_district().get("workforce_capacity", 0)))], 13)
	_live_label(stats, func(): return "Service condition\n%s%% · %s shortages" % [roundi(float(_district().get("service_condition", 0)) * 100), _number(int(_district().get("shortages", 0)))], 13)
	_live_label(card, func(): return "%s residents · %s" % [_number(int(_district().get("population", 0))), str(_district().get("kind", "")).replace("_", " ").capitalize()], 12, MenuTheme.MUTED)
	_live_label(card, func():
		var i: Dictionary = _district().get("infrastructure", {})
		return "Electricity %d%% · Drinking water %d%% · Clinic service %d%% · Transport %d%%" % [roundi(float(i.get("power_ratio",1))*100),roundi(float(i.get("water_ratio",1))*100),roundi(float(i.get("clinic_ratio",1))*100),roundi(float(i.get("mobility_ratio",1))*100)], 13)
	_live_label(card, func():
		var i: Dictionary = _district().get("infrastructure", {})
		return "Water reserve %.0f · Waste waiting %.1f · Recycling %.0f · Municipal fund %.0f" % [float(i.get("water_reserve",0)),float(i.get("waste_backlog",0)),float(i.get("recycled",0)),float(i.get("budget",0))], 12, MenuTheme.MUTED)
	card.add_child(MenuTheme.label("District service units: electricity runs pumps and treatment; collection crews recover recyclable material. Tax receipts fund operations. Repairs restore infrastructure; shortages affect food production, clinics and work.", 12, MenuTheme.MUTED))
	card.add_child(MenuTheme.label("Produce deliveries replenish the district's food. Maintenance work improves its services. Food shortages reduce the available workforce.", 12, MenuTheme.MUTED))

func _district() -> Dictionary:
	for row in _view.get("districts", []):
		if str(row.get("id", "")) == _selected_district: return row
	return {}

func _district_label() -> String:
	var value: Variant = context.get("district", "Lantern Square")
	var text := str(value)
	if value is int or text.is_valid_int():
		var id := int(value)
		if id < 0: return "Town housing"
		for row in _view.get("districts", []):
			if int(row.get("id", -1)) == id: return str(row.get("name", "Crownreach district"))
		return "Crownreach district"
	return text.replace("_", " ").capitalize()

func _request(kind: String, payload: Dictionary) -> void:
	if _pending or not is_instance_valid(controller) or not controller.has_method("request_action"): return
	_pending = true
	_refresh_live()
	var response: Variant = controller.request_action(kind, payload)
	if response is Dictionary:
		_pending = bool(response.get("pending", false))
		if not str(response.get("message", "")).is_empty(): _notice.text = str(response.message)
	else:
		_pending = false
	refresh_view()

func _controller_action(method: String, argument: Variant = null) -> void:
	if not is_instance_valid(controller) or not controller.has_method(method): return
	if argument == null: controller.call(method)
	else: controller.call(method, argument)

func _navigate(value: Variant) -> void:
	var point := Vector3.ZERO
	if value is Vector3: point = value
	elif value is Array and value.size() == 3: point = Vector3(float(value[0]), float(value[1]), float(value[2]))
	_controller_action("navigate_to", point)

func _building_id() -> String:
	return str(context.get("property", context.get("id", "")))

func _owned() -> Dictionary:
	for raw in _view.get("owned_properties", []):
		if raw is Dictionary and str(raw.get("building", "")) == _building_id(): return raw
	return {}

func _tier() -> Dictionary:
	var id := str(_owned().get("tier", context.get("housing", "")))
	if id in ["work_live", "staff_residence"]: id = "city_apartment"
	if id == "town_house": id = "suburban_home"
	for raw in _view.get("housing_catalog", []):
		if str(raw.get("id", "")) == id: return raw
	return {}

func _is_unavailable() -> bool:
	return _building_id() in _view.get("unavailable_buildings", [])

func _physical(kind: String) -> bool:
	return str(context.get("kind", "")) == kind and not _building_id().is_empty()

func _at_workplace() -> bool:
	# Interior contexts come from the room's physical frontdesk/workbench.
	# The authority rechecks that precise service point when processing jobs.
	return str(context.get("kind", "")) in ["building", "interior"] and not _building_id().is_empty()

func _bag_counts() -> Dictionary:
	if _view.get("backpack_counts") is Dictionary: return _view.backpack_counts
	var result := {}
	for row in _view.get("backpack", []): result[str(row.get("id", ""))] = int(row.get("count", row.get("quantity", 0)))
	return result

func _storage_counts() -> Dictionary:
	return _owned().get("storage", {})

func _item_label(id: String) -> String:
	for row in _view.get("backpack", []):
		if str(row.get("id", "")) == id: return str(row.get("label", row.get("name", id)))
	return id.replace("_", " ").capitalize()

func _selected_stock() -> int:
	return int((_bag_counts() if _selected_side == "backpack" else _storage_counts()).get(_selected_item, 0))

func _transfer_room() -> int:
	return int(_owned().get("storage_capacity", 0)) - int(_owned().get("storage_used", 0)) if _selected_side == "backpack" else int(_view.get("backpack_capacity", 350)) - _count_all(_bag_counts())

func _count_all(stock: Dictionary) -> int:
	var count := 0
	for quantity in stock.values(): count += maxi(int(quantity), 0)
	return count

func _has_items(required: Dictionary) -> bool:
	var bag := _bag_counts()
	for id in required:
		if int(bag.get(id, 0)) < int(required[id]): return false
	return true

func _items_text(items: Dictionary) -> String:
	var parts: PackedStringArray = []
	for id: String in items: parts.append("%s × %s" % [items[id], _item_label(id)])
	return ", ".join(parts)

func _has_context_job() -> bool:
	var job: Dictionary = _view.get("active_job", {})
	if str(job.get("destination_building", "")) == _building_id(): return true
	for candidate in _view.get("job_catalog", []):
		if str(candidate.get("start_building", "")) == _building_id(): return true
	return false

func _destination_point(building_id: String) -> Variant:
	for service in (_view.get("services", {}) as Dictionary).values():
		if str(service.get("building", "")) == building_id: return service.get("door")
	return null

func _job_ready() -> bool:
	var job: Dictionary = _view.get("active_job", {})
	return not job.is_empty() and float(_view.get("now", _view.get("time", 0))) >= float(job.get("ready_at", INF))

func _job_timing() -> String:
	var job: Dictionary = _view.get("active_job", {})
	var elapsed := float(Time.get_ticks_msec() - _view_received_msec) / 1000.0
	var remaining := maxi(0, ceili(float(job.get("ready_at", 0)) - float(_view.get("now", _view.get("time", 0))) - elapsed))
	return "Ready to finish at the destination" if remaining == 0 else "Work in progress · %s seconds remaining" % remaining

func _row(parent: Node) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	return row

func _card(parent: Node) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", MenuTheme.panel(MenuTheme.INK, MenuTheme.BORDER, 12, 10))
	parent.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)
	return column

func _live_label(parent: Node, read: Callable, size := 14, color := MenuTheme.TEXT) -> Label:
	var label := MenuTheme.label(str(read.call()), size, color)
	parent.add_child(label)
	_live.append({"node": label, "read": read})
	return label

func _button(parent: Node, text: String, callback: Callable, key: String, primary := false) -> Button:
	var button := Button.new()
	button.text = text
	MenuTheme.style_button(button, primary, true)
	button.set_meta("city_focus", key)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _action(parent: Node, text: String, callback: Callable, allowed: Callable, key: String, primary := false, read_text: Callable = Callable()) -> Button:
	var button := _button(parent, text, func():
		if not _pending and bool(allowed.call()): callback.call(), key, primary)
	var entry := {"node": button, "allowed": allowed}
	if read_text.is_valid(): entry["text"] = read_text
	_actions.append(entry)
	return button

func _focus_first() -> void:
	# New subjects start at their first action after container reflow.
	await get_tree().process_frame
	if not visible: return
	var controls := _body.find_children("*", "Button", true, false)
	for control in controls:
		if not control.disabled:
			control.grab_focus()
			_scroll.scroll_vertical = 0
			return

func _restore_focus(key: String, scroll_y: int) -> void:
	if not visible: return
	_scroll.scroll_vertical = scroll_y
	if key.is_empty(): return
	for node in find_children("*", "Control", true, false):
		if str(node.get_meta("city_focus", "")) == key and node.is_visible_in_tree():
			node.grab_focus()
			return

func _number(value: int) -> String:
	var source := str(value)
	var result := ""
	for index in range(source.length()):
		if index > 0 and (source.length() - index) % 3 == 0: result += ","
		result += source[index]
	return result
