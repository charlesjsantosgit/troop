class_name FrontierUI
extends Control
## Every work control belongs to the physical subject that opened this panel.
## The pocket journal provides information and waypoints, never remote orders.

const MenuTheme = preload("res://scripts/menu_theme.gd")
const InventoryTile = preload("res://scripts/inventory_tile.gd")
const PAGES := ["Journal", "Tutorial", "Places", "Contracts", "Sky"]
const INK := MenuTheme.TEXT
const MUTED := MenuTheme.MUTED
const GOLD := MenuTheme.ACCENT
const GREEN := MenuTheme.SECONDARY
const PANEL := MenuTheme.PANEL
const INSET := MenuTheme.INSET
const BORDER := MenuTheme.BORDER
var controller: Node
var page := "Journal"
var context: Dictionary = {}
var _panel: PanelContainer
var _body: VBoxContainer
var _heading: Label
var _balance: Label
var _notice: Label
var _scroll: ScrollContainer
var _nav: Dictionary = {}
var _journal_nav: HFlowContainer
var _journal_button: Button
var _main_stack: VBoxContainer
var _workspace: HBoxContainer
var _context_line: Label
var _live_labels: Array = []
var _live_trade_buttons: Array = []
var _refresh := 0.0
var _quantity := 5
var _selected_crop: Dictionary = {}
var _freight_item := "tomato"
var _structure := ""
var _market_search := ""
var _market_category := "All"
var _market_id := ""
var _details_open: Dictionary = {}
var _merchant_workspace: VBoxContainer
var _merchant_mode := false
var _trade_selected_item := ""
var _trade_selected_side := "market"
var _trade_tiles: Dictionary = {}
var _trade_grids: Array[GridContainer] = []
var _trade_scrolls: Array[ScrollContainer] = []
var _trade_footer: PanelContainer
var _trade_title: Label
var _trade_detail: Label
var _trade_buy: Button
var _trade_sell: Button
var _trade_capacity: Label
var _trade_search: LineEdit
var _trade_category: OptionButton
var _panel_motion: Tween
var _closing := false


func configure(owner_controller: Node) -> void:
	controller = owner_controller


func _ready() -> void:
	theme = MenuTheme.build(true)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.025, 0.03, 0.14)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", MenuTheme.panel(PANEL, BORDER, 18, 12))
	add_child(_panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 0)
	_panel.add_child(margin)
	_main_stack = VBoxContainer.new()
	_main_stack.add_theme_constant_override("separation", 8)
	margin.add_child(_main_stack)
	var top := _row(_main_stack)
	_heading = _line(top, "TRAVEL JOURNAL", 26, GOLD)
	_heading.custom_minimum_size.x = 300
	_journal_button = _button(top, "My journal", func(): open({}))
	_button(top, "Close · B / Esc", _dismiss)
	_balance = _line(_main_stack, "", 15, GREEN)
	_context_line = _line(_main_stack, "", 14, MUTED)
	_journal_nav = _row(_main_stack)
	for label: String in PAGES:
		_nav[label] = _button(_journal_nav, "Overview" if label=="Journal" else label, func(): select_page(label))
		_nav[label].custom_minimum_size.x = 148
	_workspace = HBoxContainer.new()
	_workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_workspace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_workspace.add_theme_constant_override("separation", 12)
	_main_stack.add_child(_workspace)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_workspace.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 8)
	_scroll.add_child(_body)
	_merchant_workspace = VBoxContainer.new()
	_merchant_workspace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_merchant_workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_merchant_workspace.add_theme_constant_override("separation", 8)
	_merchant_workspace.visible = false
	_workspace.add_child(_merchant_workspace)
	_notice = _line(_main_stack, "", 15, GOLD)
	_notice.custom_minimum_size.y = 22
	get_viewport().size_changed.connect(_resize)
	_resize()


func _resize() -> void:
	if _panel == null:
		return
	var window := get_viewport_rect().size
	var desired := Vector2(920,640) if _merchant_mode else Vector2(760,600) if context.is_empty() else Vector2(620,560)
	var margin := Vector2(40,40) if window.x>=580 and window.y>=500 else Vector2(16,16)
	var available := window-margin*2.0
	var dimensions := Vector2(minf(desired.x,available.x),minf(desired.y,available.y))
	var max_size := Vector2(maxf(160,window.x-16),maxf(160,window.y-16))
	dimensions.x = clampf(dimensions.x,minf(320,max_size.x),max_size.x)
	dimensions.y = clampf(dimensions.y,minf(300,max_size.y),max_size.y)
	_panel.position = (window - dimensions) * 0.5
	_panel.size = dimensions
	# Body content can report a new minimum during the same layout pass. Apply
	# the cap once more afterward so the ScrollContainer absorbs that height.
	_panel.set_deferred("size",dimensions)
	_set_navigation_layout(_sidebar_navigation(dimensions.x))
	for grid in _trade_grids:
		if is_instance_valid(grid):
			grid.columns = 3 if dimensions.x >= 800 else 2


static func _sidebar_navigation(panel_width: float) -> bool:
	return panel_width >= 700.0


func _set_navigation_layout(sidebar: bool) -> void:
	if sidebar and _journal_nav.get_parent() != _workspace:
		_journal_nav.reparent(_workspace)
		_workspace.move_child(_journal_nav,0)
	elif not sidebar and _journal_nav.get_parent() != _main_stack:
		_journal_nav.reparent(_main_stack)
		_main_stack.move_child(_journal_nav,_workspace.get_index())
	_journal_nav.custom_minimum_size = Vector2(170,0) if sidebar else Vector2.ZERO
	_journal_nav.size_flags_vertical = Control.SIZE_EXPAND_FILL if sidebar else Control.SIZE_SHRINK_BEGIN
	_journal_nav.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN if sidebar else Control.SIZE_EXPAND_FILL


func open(subject: Variant = {}) -> void:
	context = subject.duplicate(true) if subject is Dictionary else controller.selected_interaction.duplicate(true)
	if context.is_empty():
		page = str(subject) if subject is String and subject in PAGES else "Journal"
	else:
		page = "Interaction"
		if not context.has("town_id"):
			context.town_id = str(_town().get("id", ""))
	visible = true
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if is_instance_valid(controller.world) and is_instance_valid(controller.world.local_player) \
			and controller.world.local_player.cam:
		controller.world.local_player.cam.set_aiming(false)
	_rebuild()
	_animate_open.call_deferred()


func close() -> void:
	if _panel_motion and _panel_motion.is_valid():
		_panel_motion.kill()
	_closing = false
	_panel.scale = Vector2.ONE
	visible = false
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _animate_open() -> void:
	_closing = false
	if _panel_motion and _panel_motion.is_valid():
		_panel_motion.kill()
	_resize()
	if DisplayServer.get_name() == "headless":
		return
	var target := _panel.position
	_panel.pivot_offset = _panel.size * 0.5
	_panel.scale = Vector2.ONE * 0.98
	_panel.position = target + Vector2(0, 10)
	_panel_motion = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_panel_motion.tween_property(_panel, "scale", Vector2.ONE, 0.18)
	_panel_motion.tween_property(_panel, "position", target, 0.18)


func _dismiss() -> void:
	if _closing:
		return
	if DisplayServer.get_name() == "headless":
		close()
		return
	_closing = true
	if _panel_motion and _panel_motion.is_valid():
		_panel_motion.kill()
	_panel_motion = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_panel_motion.tween_property(_panel, "scale", Vector2.ONE * 0.985, 0.09)
	_panel_motion.tween_callback(close)


func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode in [KEY_ESCAPE, KEY_B]:
		_dismiss()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not visible:
		return
	_refresh -= delta
	if _refresh > 0:
		return
	_refresh = 0.5
	refresh_from_state()


## Apply received authority state immediately; the periodic refresh is only a fallback.
func refresh_from_state() -> void:
	if not visible or _body == null:
		return
	var town_id := str(_town().get("id", ""))
	if not context.is_empty() and not str(context.get("town_id", "")).is_empty() \
			and not town_id.is_empty() and str(context.town_id) != town_id:
		close()
		return
	if _structure_key() != _structure:
		_rebuild(true)
	else:
		_refresh_live()


func _state() -> Dictionary:
	return controller.simulation.state


func _town() -> Dictionary:
	return controller.current_town() if controller.has_method("current_town") else _state().get("town", {})


func _manage() -> bool:
	return bool(_state().get("permissions", {}).get("manage", _town().get("is_owner", not _state().has("town"))))


func _inventory(location: String) -> Dictionary:
	return _state().get("inventories", {}).get(location, {})


func _pack() -> String:
	return "player_" + controller.current_planet()


func _items() -> Dictionary:
	return controller.simulation.item_catalog()


func _title(id: String) -> String:
	var definition: Dictionary = _items().get(id, {})
	return str(definition.get("name", definition.get("label", id.replace("_", " ").capitalize())))


func _refresh_live() -> void:
	var town := _town()
	_balance.text = "%s  /  %s  /  %d credits" % [str(town.get("name", "Crater Gardens" if controller.current_planet() == "moon" else "Canopy Commons")),
		controller.current_planet().capitalize(), int(_state().get("accounts", {}).get("player", 0))]
	var role := "TOWN STEWARD" if _manage() else "LOCAL VISITOR"
	var permission := "Crew, plots and equipment available in person" if _manage() \
		else "Trade and requests available; the steward manages this town"
	if not context.is_empty():
		_context_line.text = "%s  ·  HERE: %s  ·  %s" % [role, str(context.get("label", _heading.text)), permission]
	else:
		_context_line.text = "%s  ·  %s" % [role, permission]
	_notice.text = str(controller.last_message) if not str(controller.last_message).is_empty() else "Actions and prices update from this town in real time."
	if controller.has_method("action_pending") and bool(controller.action_pending()):
		var elapsed: int = int(controller.action_elapsed_ms()) if controller.has_method("action_elapsed_ms") else 0
		_notice.text = "Sending request…" if elapsed < 1000 else "Waiting for server · %.1f s" % (float(elapsed) / 1000.0)
	if _merchant_mode:
		_refresh_merchant()
	for entry: Dictionary in _live_trade_buttons:
		if is_instance_valid(entry.button):
			_refresh_trade_button(entry.button, str(entry.market), str(entry.item), bool(entry.buying))
	for item: Dictionary in _live_labels:
		if is_instance_valid(item.label):
			item.label.text = str(item.read.call())


func _structure_key() -> String:
	var result: Array = [context.get("id", ""), _manage(), _town().get("claimed", false), _town().get("id",""), controller.current_planet(), _details_open]
	var subject: Dictionary = _state().get("plots", {}).get(str(context.get("id", "")), {})
	result.append([subject.get("crop", ""), float(subject.get("health", 1)) <= 0])
	var citizen: Dictionary = _state().get("citizens", {}).get(str(context.get("id", "")), {})
	result.append([citizen.get("job", ""),citizen.get("employer", ""),citizen.get("can_manage", false)])
	if str(context.get("kind", "")) in ["market", "shop"]:
		result.append(_inventory(str(context.get("id", ""))).keys())
	for quest: Dictionary in _state().get("quests", {}).values():
		result.append([quest.get("id", ""), quest.get("status", "")])
	if _merchant_mode:
		for location: String in [_market_id, _pack()]:
			var nonempty: Array[String] = []
			for item: String in _inventory(location):
				if int(_inventory(location)[item]) > 0:
					nonempty.append(item)
			nonempty.sort()
			result.append(nonempty)
	if page=="Tutorial" and "tutorial" in controller and is_instance_valid(controller.tutorial):
		result.append(controller.tutorial.summary())
	return JSON.stringify(result)


func select_page(next_page: String) -> void:
	context.clear()
	page = next_page if next_page in PAGES else "Places" if next_page in ["Farms", "Crew", "Market", "Industry", "Freight"] else "Contracts" if next_page == "Quests" else "Journal"
	_rebuild()


func _rebuild(preserve_scroll := false) -> void:
	var old_scroll := _scroll.scroll_vertical if preserve_scroll else 0
	var focused := _focus_key() if preserve_scroll else {}
	var trade_scrolls: Array[int] = []
	for scroll in _trade_scrolls:
		trade_scrolls.append(scroll.scroll_vertical if preserve_scroll else 0)
	for child in _merchant_workspace.get_children():
		_merchant_workspace.remove_child(child)
		child.queue_free()
	_merchant_mode = false
	_trade_tiles.clear()
	_trade_grids.clear()
	_trade_scrolls.clear()
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_live_labels.clear()
	_live_trade_buttons.clear()
	_journal_nav.visible = context.is_empty()
	_journal_button.visible = context.is_empty()
	for key in _nav:
		_nav[key].disabled = key == page
	if context.is_empty():
		_heading.text = "TRAVEL JOURNAL" if page == "Journal" else page.to_upper()
		match page:
			"Places": _places()
			"Tutorial": _tutorial()
			"Contracts": _contracts("", false)
			"Sky": _sky()
			_: _journal()
	else:
		var id := str(context.get("id", ""))
		_heading.text = str(context.get("label", "Your neighbor"))
		match str(context.get("kind", "")):
			"citizen", "npc", "worker": _citizen(id)
			"plot", "farm": _plot(id)
			"board", "quest_board", "quest": _board()
			"market", "shop": _market(id)
			_: _facility(id)
	_scroll.visible = not _merchant_mode
	_merchant_workspace.visible = _merchant_mode
	_context_line.visible = not _merchant_mode
	for index in range(mini(trade_scrolls.size(), _trade_scrolls.size())):
		_trade_scrolls[index].set_deferred("scroll_vertical", trade_scrolls[index])
	_structure = _structure_key()
	_refresh_live()
	_scroll.set_deferred("scroll_vertical", old_scroll)
	if not focused.is_empty():
		_restore_focus.call_deferred(focused, old_scroll)
	_resize.call_deferred()


func _focus_key() -> Dictionary:
	var focused := get_viewport().gui_get_focus_owner()
	if focused == null or (not _body.is_ancestor_of(focused) and not _merchant_workspace.is_ancestor_of(focused)):
		return {}
	if focused.has_meta("merchant_side"):
		return {"item": focused.item_id, "side": focused.get_meta("merchant_side")}
	if focused is Button:
		return {"button": focused.text, "action": focused.get_meta("frontier_action", ""),
			"payload": focused.get_meta("frontier_payload", {})}
	if focused is LineEdit:
		return {"input": focused.placeholder_text, "quantity": focused.get_parent() is SpinBox}
	return {}


func _restore_focus(key: Dictionary, old_scroll: int) -> void:
	if not visible:
		return
	var pending: Array[Node] = [_body, _merchant_workspace]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		var matches := false
		if key.has("item") and node.has_meta("merchant_side"):
			matches = node.get_meta("inventory_item", "") == key.item and node.get_meta("merchant_side") == key.side
		elif node is Button and key.has("button"):
			matches = (not str(key.action).is_empty() or node.text == key.button) \
				and node.get_meta("frontier_action", "") == key.action \
				and node.get_meta("frontier_payload", {}) == key.payload
		elif node is LineEdit and key.has("input"):
			matches = node.placeholder_text == key.input and (node.get_parent() is SpinBox) == bool(key.quantity)
		if matches:
			node.grab_focus()
			_scroll.set_deferred("scroll_vertical", old_scroll)
			return
		pending.append_array(node.get_children())


func _journal() -> void:
	_section("What should I do next?", "One useful step, based on your current progress.")
	var next_card := _card(_body, true)
	var guide: Variant = controller.get("tutorial") if "tutorial" in controller else null
	var showed_next := false
	if is_instance_valid(guide):
		var summary: Dictionary = guide.summary()
		if bool(summary.get("active", false)) and not bool(summary.get("complete", false)):
			_line(next_card, str(summary.get("title", "Continue your guide")), 20, GOLD)
			_line(next_card, str(summary.get("text", "Follow the marked place and try the next step.")), 16)
			_line(next_card, "Tutorial step %d of %d" % [int(summary.get("step", 1)), int(summary.get("total", 1))], 14, MUTED)
			var guide_row := _row(next_card)
			_button(guide_row, "Show me where", guide.show_target, true)
			_button(guide_row, "Open tutorial", func(): select_page("Tutorial"))
			showed_next = true
	if not showed_next:
		var active_quests: Array[Dictionary] = []
		for quest: Dictionary in _state().get("quests", {}).values():
			if str(quest.get("status", "available")) == "active": active_quests.append(quest)
		if not active_quests.is_empty():
			var quest: Dictionary = active_quests[0]
			_line(next_card, str(quest.get("title", "Finish your request")), 20, GOLD)
			_line(next_card, "%d × %s for %d credits" % [int(quest.get("quantity", 0)), _title(str(quest.get("item", "goods"))), int(quest.get("reward", 0))], 16)
			var contract_row := _row(next_card)
			_button(contract_row, "Locate delivery", func(): controller.locate(str(quest.get("destination", "earth_market"))), true)
			_button(contract_row, "View contracts", func(): select_page("Contracts"))
		else:
			_line(next_card, "Meet the neighborhood", 20, GOLD)
			_line(next_card, "Talk to a resident or visit the community board to find a funded request.", 16)
			var first_board := _first_interaction(["board", "quest_board", "quest"])
			if not first_board.is_empty(): _button(next_card, "Find community board", func(): controller.locate(first_board), true)
			else: _button(next_card, "Browse places", func(): select_page("Places"), true)

	_section("At a glance", "What you carry and what you can manage in this town.")
	var cargo := _card(_body)
	_line(cargo, "Your cargo", 18, GOLD)
	_live(cargo, func(): return _inventory_text(_inventory(_pack())))
	var town := _town()
	var town_card := _card(_body)
	_line(town_card, str(town.get("name", "Local town")), 18, GOLD)
	_line(town_card, "%s · %s" % [controller.current_planet().capitalize(), "You can manage crew, plots and equipment" if _manage() else "Visit, trade and accept requests"], 15, MUTED)
	var active_count := 0
	for quest: Dictionary in _state().get("quests", {}).values():
		if str(quest.get("status", "")) == "active": active_count += 1
	_line(town_card, "%d active request%s" % [active_count, "" if active_count == 1 else "s"], 15)
	var quick := _row(_body)
	_button(quick, "Browse places", func(): select_page("Places"))
	_button(quick, "View contracts", func(): select_page("Contracts"))
	_button(quick, "Find rocket", controller.locate_rocket)


func _places() -> void:
	_section("Towns", "Find a community board to visit or claim a settlement.")
	if controller.has_method("known_towns"):
		for town: Dictionary in controller.known_towns():
			var town_card := _card(_body)
			var town_row := _row(town_card)
			_line(town_row,str(town.get("name","Town")),18,GOLD)
			_button(town_row,"Find town board",func(): controller.locate("town:"+str(town.id)))
			_line(town_card,str(town.get("planet","earth")).capitalize()+" · "+("Managed by "+str(town.get("owner_name","a neighbor")) if town.get("claimed",false) else "Available to claim"),14,MUTED)
	_section("Nearby", "Choose a waypoint, walk there, then press E. Work stays tied to the place you visit.")
	var entries: Array = controller.interactions()
	var groups := {"People":[], "Farms":[], "Trade & services":[], "Industry":[], "Community":[]}
	for item: Dictionary in entries: groups[_place_group(item)].append(item)
	for group: String in ["People", "Farms", "Trade & services", "Industry", "Community"]:
		if groups[group].is_empty(): continue
		_line(_body, group, 18, GREEN)
		for item: Dictionary in groups[group]:
			var card := _card(_body)
			var row := _row(card)
			_line(row, str(item.get("label", item.get("id", "Place"))), 17, GOLD)
			_button(row, "Locate", func(): controller.locate(str(item.id)))
			var citizen: Dictionary = _state().get("citizens", {}).get(str(item.id), {})
			if not citizen.is_empty(): _line(card, str(citizen.get("activity", "Enjoying the town")), 14, MUTED)


func _board() -> void:
	var town := _town()
	_heading.text = str(town.get("name", "Community board"))
	_line(_body, "COMMUNITY BOARD", 14, GREEN)
	_line(_body, "%d residents · %d growing beds" % [_state().get("citizens", {}).values().filter(func(person): return person.get("planet")==controller.current_planet()).size(), _state().get("plots", {}).values().filter(func(bed): return bed.get("planet")==controller.current_planet()).size()], 20, GOLD)
	if town.get("claimed", false):
		_line(_body, "Your town" if town.get("is_owner", false) else "Town steward: " + str(town.get("owner_name", "another player")))
	else:
		_line(_body, "Become the steward of this town to manage its growers, work crews and equipment. Trade and neighbor contracts are open to visitors.")
		if bool(_state().get("permissions", {}).get("claim", true)):
			_action(_body, "Claim this town · %d credits" % int(town.get("claim_price", 750)), "claim_town", {})
		else:
			_line(_body, "You already steward another town.", 15, MUTED)
	_line(_body, "Neighbors' requests", 21, GOLD)
	_contracts("", true)


func _citizen(id: String) -> void:
	var citizen: Dictionary = _state().get("citizens", {}).get(id, {})
	if citizen.is_empty():
		_line(_body, "Your neighbor has moved on. Close this conversation and meet them again.")
		return
	_heading.text = str(citizen.get("name", id))
	var trade := str(citizen.get("trade_location", ""))
	if trade.is_empty() and not _state().has("permissions"):
		trade = ("moon_market" if controller.current_planet() == "moon" else "earth_market") if citizen.get("job") == "merchant" else "refinery" if citizen.get("job") == "refinery_operator" else ""
	var about := bool(_details_open.get("about:" + id, false))
	if not trade.is_empty() and _near(trade) and not about:
		_market(trade, false, true)
		return
	_live(_body, func():
		var person: Dictionary = _state().get("citizens", {}).get(id, {})
		return "%s · %s%s" % [str(person.get("job", "citizen")).replace("_", " ").capitalize(),
			person.get("activity", "Resting"),
			"\nI need help: " + str(person.blocker) if not str(person.get("blocker", "")).is_empty() else ""])
	if not trade.is_empty():
		if _near(trade):
			_button(_body, "Back to trading", func(): _details_open["about:" + id] = false; _rebuild(), true)
		else:
			_section("My trading desk")
			_line(_body, "Meet me at the trading desk to exchange goods.", 15, MUTED)
			_button(_body, "Locate trading desk", func(): controller.locate(trade))
	if _has_quest(id):
		_section("A request for you", "Accept it here; deliver at the named workplace.")
		_contracts(id, true)
	# Workplaces have machinery, fuel service and maintenance beyond a person's
	# trading inventory. Keep these reachable when the resident shares its desk.
	var person_position: Vector3 = controller._interaction_position(id)
	for workplace: Dictionary in controller.interactions():
		if str(workplace.get("kind", "")) not in ["facility", "board", "market"]:
			continue
		# Merchants already embed their own desk above. Other workers can stand
		# here while delivering goods and must still offer the physical market.
		if workplace.get("kind") == "market" and str(workplace.id) == trade:
			continue
		if person_position.distance_to(workplace.position) <= 2.0 and _near(id) and _near(str(workplace.id)):
			_button(_body, "Use " + str(workplace.get("label", "workplace")),
				func(): _open_workplace_details(str(workplace.id)), true)
	if bool(citizen.get("can_manage", _manage())):
		_section("Work together", "Choose a real job. Pay is charged after completed work.")
		_line(_body, "Current wage: %d credits per completed task" % int(citizen.get("wage", 0)), 14, MUTED)
		var jobs: Variant = controller.simulation.job_catalog()
		var ids: Array = jobs.keys() if jobs is Dictionary else jobs
		if controller.current_planet() == "moon":
			ids = ids.filter(func(job): return job in ["grower", "agronomist", "greenhouse_technician", "water_operator", "solar_technician", "merchant", "farm_manager", "citizen"])
		var row := _row(_body)
		var choose := _options(row, ids, str(citizen.get("job", "citizen")))
		_button(row, "Assign work" if citizen.get("employer") == "player" else "Hire for this job", func(): _act("assign_job", {"citizen": id, "job": ids[choose.selected]}), true)
		_action(row, "Pause / resume work", "toggle_worker", {"citizen": id})
	else:
		_line(_body, "The town steward arranges my work and wages.", 15, MUTED)
	var details_key := id+":details"
	_button(_body, "Hide details" if bool(_details_open.get(details_key, false)) else "Show details", func():
		_details_open[details_key] = not bool(_details_open.get(details_key, false))
		_rebuild(true))
	if bool(_details_open.get(details_key, false)):
		var details := _card(_body)
		_line(details, "Resident details", 18, GOLD)
		_live(details, func():
			var person: Dictionary = _state().get("citizens", {}).get(id, {})
			var needs: Dictionary = person.get("needs", {})
			var observations: Array = person.get("observations", [])
			return "Skill %.1f · %d jobs completed · Hunger %d%% · Fatigue %d%%%s" % [float(person.get("skill", 1)), int(person.get("completed", 0)),
				roundi(float(needs.get("hunger", 0)) * 100), roundi(float(needs.get("fatigue", 0)) * 100), "\nLast observation: "+str(observations.back().get("fact", "")) if not observations.is_empty() else ""])


func _open_workplace_details(id: String) -> void:
	if controller.open_workplace(id) and id == "refinery":
		_details_open["about:" + id] = true
		_rebuild()


func _plot(id: String) -> void:
	var plot: Dictionary = _state().get("plots", {}).get(id, {})
	if plot.is_empty():
		_line(_body, "This growing bed is no longer available.")
		return
	_heading.text = str(plot.get("name", id.replace("_", " ").capitalize()))
	_live(_body, func():
		var bed: Dictionary = _state().get("plots", {}).get(id, {})
		return "%s · Growth %d%% · Health %d%%\nWater %d%% · Nutrients %d%% · %s" % [_title(str(bed.get("crop", "empty bed"))),
			roundi(float(bed.get("growth", 0)) * 100), roundi(float(bed.get("health", 1)) * 100),
			roundi(float(bed.get("moisture", 0))), roundi(float(bed.get("nutrients", 0))), str(bed.get("status", "Growing"))])
	if not _manage() or plot.get("owner", "") != "player":
		_line(_body, "This bed is tended by the town's growers. Speak to its steward about the farm.")
		return
	var crops: Dictionary = controller.simulation.crop_catalog()
	var ids: Array = crops.keys()
	var row := _row(_body)
	var select := _options(row, ids, str(_selected_crop.get(id, plot.get("crop", "lettuce"))))
	_selected_crop[id] = ids[select.selected]
	select.item_selected.connect(func(index): _selected_crop[id] = ids[index])
	_button(row, "Plant", func(): _act("plant", {"plot": id, "crop": _selected_crop[id]}))
	var work := _row(_body)
	_action(work, "Water", "water", {"plot": id})
	_action(work, "Feed nutrients", "fertilize", {"plot": id})
	_action(work, "Harvest", "harvest", {"plot": id})
	_action(work, "Inspect bed", "inspect", {"target": id})
	_action(_body, "Pause / resume grower care", "toggle_plot", {"plot": id})
	if not str(plot.get("crop", "")).is_empty() and float(plot.get("health", 1)) <= 0:
		_action(_body, "Clear failed crop", "clear_plot", {"plot": id})
	var definition: Dictionary = crops.get(str(_selected_crop[id]), {})
	_line(_body, "Planting stock: %s · Suitable temperature %.0f–%.0f °C" % [_title(str(definition.get("planting_item", "seed"))), float(definition.get("min_temp", 0)), float(definition.get("max_temp", 40))], 15, MUTED)


func _market(id: String, heading := true, compact := false) -> void:
	if heading:
		_heading.text = str(_state().get("locations", {}).get(id, {}).get("label", context.get("label", "Trading desk")))
	if _market_id != id:
		_market_id = id
		_market_search = ""
		_market_category = "All"
		_trade_selected_item = ""
		_trade_selected_side = "market"
	if heading and bool(_details_open.get("about:" + str(context.get("id", id)), false)):
		_button(_body, "Back to trading", func(): _details_open["about:" + str(context.get("id", id))] = false; _rebuild(), true)
		_contracts("", true, id)
		return
	_merchant_mode = true
	var toolbar := HBoxContainer.new()
	_merchant_workspace.add_child(toolbar)
	_trade_search = LineEdit.new()
	_trade_search.placeholder_text = "Find an item"
	_trade_search.text = _market_search
	_trade_search.clear_button_enabled = true
	_trade_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trade_search.custom_minimum_size = Vector2(180, 34)
	_trade_search.text_changed.connect(func(value: String): _market_search = value; _filter_merchant_tiles())
	toolbar.add_child(_trade_search)
	_trade_category = OptionButton.new()
	var categories := ["All", "Crops", "Planting", "Food", "Fuel", "Materials"]
	for group: String in categories: _trade_category.add_item(group)
	_trade_category.select(maxi(0, categories.find(_market_category)))
	_trade_category.custom_minimum_size = Vector2(118, 34)
	_trade_category.item_selected.connect(func(index: int): _market_category = categories[index]; _filter_merchant_tiles())
	toolbar.add_child(_trade_category)
	_button(toolbar, "About " + _heading.text if compact else "Requests & details", func():
		_details_open["about:" + str(context.get("id", id))] = true
		_rebuild())
	var panes := HBoxContainer.new()
	panes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panes.add_theme_constant_override("separation", 12)
	_merchant_workspace.add_child(panes)
	_build_inventory_pane(panes, "market", "Merchant stock", _inventory(id))
	_build_inventory_pane(panes, "backpack", "Your backpack", _inventory(_pack()))
	_trade_footer = PanelContainer.new()
	_trade_footer.add_theme_stylebox_override("panel", MenuTheme.panel(MenuTheme.INK, BORDER, 10, 10))
	_merchant_workspace.add_child(_trade_footer)
	var footer := VBoxContainer.new()
	footer.add_theme_constant_override("separation", 6)
	_trade_footer.add_child(footer)
	var description := HBoxContainer.new()
	footer.add_child(description)
	_trade_title = MenuTheme.label("Select an item", 17, GOLD)
	_trade_title.custom_minimum_size.x = 180
	description.add_child(_trade_title)
	_trade_detail = MenuTheme.label("Choose a tile to buy or sell.", 13, MUTED)
	_trade_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	description.add_child(_trade_detail)
	var actions := HBoxContainer.new()
	footer.add_child(actions)
	var amount_label := MenuTheme.label("Quantity", 13, MUTED)
	amount_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	amount_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	actions.add_child(amount_label)
	var quantity := SpinBox.new()
	quantity.min_value = 1
	quantity.max_value = 100
	quantity.step = 1
	quantity.value = _quantity
	quantity.custom_minimum_size = Vector2(88, 36)
	quantity.value_changed.connect(func(value: float): _quantity = int(value); _refresh_merchant())
	actions.add_child(quantity)
	var spring := Control.new()
	spring.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spring)
	_trade_buy = _button(actions, "Buy", func(): _act("buy", {"market":id, "item":_trade_selected_item, "quantity":_quantity}), true)
	_trade_buy.custom_minimum_size = Vector2(146, 36)
	_trade_buy.set_meta("frontier_action", "buy")
	_trade_sell = _button(actions, "Sell", func(): _act("sell", {"market":id, "item":_trade_selected_item, "quantity":_quantity}))
	_trade_sell.custom_minimum_size = Vector2(146, 36)
	_trade_sell.set_meta("frontier_action", "sell")
	if _trade_selected_item.is_empty():
		var preferred := "crude_oil" if id == "refinery" else "lettuce" if id == "moon_market" else "banana"
		if _trade_tiles.has("market:" + preferred):
			_trade_selected_item = preferred
	_filter_merchant_tiles()


func _build_inventory_pane(parent: Node, side: String, title: String, inventory: Dictionary) -> void:
	var pane := PanelContainer.new()
	pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pane.add_theme_stylebox_override("panel", MenuTheme.panel(MenuTheme.INK, BORDER, 10, 10))
	parent.add_child(pane)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	pane.add_child(column)
	var top := HBoxContainer.new()
	column.add_child(top)
	top.add_child(MenuTheme.label(title, 15, GOLD if side == "market" else GREEN))
	if side == "backpack":
		_trade_capacity = MenuTheme.label("", 12, MUTED)
		_trade_capacity.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		top.add_child(_trade_capacity)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.follow_focus = true
	column.add_child(scroll)
	_trade_scrolls.append(scroll)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(grid)
	_trade_grids.append(grid)
	var items: Array = inventory.keys()
	items.sort()
	for item: String in items:
		if int(inventory[item]) <= 0 or not _items().has(item):
			continue
		if side == "market" and not _merchant_accepts(item):
			continue
		var tile := InventoryTile.new()
		tile.configure(item, _title(item), int(inventory[item]), _item_category(item))
		tile.set_meta("merchant_side", side)
		tile.pressed.connect(func(): _select_merchant_item(item, side))
		grid.add_child(tile)
		_trade_tiles[side + ":" + item] = tile
	var empty := MenuTheme.label("No goods here yet.", 13, MUTED)
	empty.name = "EmptyInventory"
	empty.visible = grid.get_child_count() == 0
	column.add_child(empty)


func _merchant_accepts(item: String) -> bool:
	return _market_id != "refinery" or item in ["crude_oil", "gasoline", "diesel", "jet_fuel", "bitumen", "water", "spare_parts"]


func _filter_merchant_tiles() -> void:
	if not _merchant_mode:
		return
	var first: String = ""
	var first_side := "market"
	var selection_visible := false
	var counterpart_side := ""
	for key: String in _trade_tiles:
		var tile: Button = _trade_tiles[key]
		var item: String = tile.get_meta("inventory_item")
		var show := (_market_category == "All" or _item_category(item) == _market_category) \
			and (_market_search.strip_edges().is_empty() or _title(item).to_lower().contains(_market_search.strip_edges().to_lower()))
		tile.visible = show
		if show:
			if first.is_empty():
				first = item
				first_side = str(tile.get_meta("merchant_side"))
			if item == _trade_selected_item:
				counterpart_side = str(tile.get_meta("merchant_side"))
				selection_visible = selection_visible or counterpart_side == _trade_selected_side
	if not selection_visible:
		if not counterpart_side.is_empty():
			_trade_selected_side = counterpart_side
		else:
			_trade_selected_item = first
			_trade_selected_side = first_side
	for index in range(_trade_grids.size()):
		var any_visible := false
		for tile in _trade_grids[index].get_children():
			any_visible = any_visible or tile.visible
		var empty: Label = _trade_scrolls[index].get_parent().get_node("EmptyInventory")
		empty.text = "No matching items. Clear the search or choose All." if not _market_search.is_empty() or _market_category != "All" else "No goods here yet."
		empty.visible = not any_visible
	_refresh_merchant()


func _select_merchant_item(item: String, side: String) -> void:
	_trade_selected_item = item
	_trade_selected_side = side
	_refresh_merchant()
	if DisplayServer.get_name() != "headless":
		var motion := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_trade_title.modulate = Color(1.2, 1.1, 0.9)
		motion.tween_property(_trade_title, "modulate", Color.WHITE, 0.18)


func _refresh_merchant() -> void:
	if not _merchant_mode or not is_instance_valid(_trade_buy):
		return
	var carried := 0
	for count in _inventory(_pack()).values():
		carried += int(count)
	var capacity := int(controller.backpack_capacity()) if controller.has_method("backpack_capacity") else 0
	if controller.has_method("backpack_used"):
		carried = int(controller.backpack_used())
	_trade_capacity.text = "%d / %d" % [carried, capacity] if capacity > 0 else "%d items" % carried
	for key: String in _trade_tiles:
		var tile = _trade_tiles[key]
		var inventory := _inventory(_market_id if tile.get_meta("merchant_side") == "market" else _pack())
		tile.set_item_count(int(inventory.get(tile.item_id, 0)))
		tile.set_selected(tile.item_id == _trade_selected_item and tile.get_meta("merchant_side") == _trade_selected_side)
	if _trade_selected_item.is_empty():
		_trade_title.text = "Select an item"
		_trade_detail.text = "Choose a tile to buy or sell."
		_trade_buy.text = "Buy"
		_trade_sell.text = "Sell"
		_trade_buy.disabled = true
		_trade_sell.disabled = true
		return
	_trade_title.text = _title(_trade_selected_item)
	_trade_detail.text = "%s · %d in stock · %d in your backpack" % [_item_category(_trade_selected_item),
		int(_inventory(_market_id).get(_trade_selected_item, 0)), int(_inventory(_pack()).get(_trade_selected_item, 0))]
	for button in [_trade_buy, _trade_sell]:
		button.set_meta("frontier_payload", {"market":_market_id, "item":_trade_selected_item})
	var buy_price: int = controller.simulation.quote(_market_id, _trade_selected_item, _quantity, true)
	var sell_price: int = controller.simulation.quote(_market_id, _trade_selected_item, _quantity, false)
	_trade_buy.text = "Buy · %d cr" % buy_price
	_trade_sell.text = "Sell · %d cr" % sell_price
	_refresh_trade_button(_trade_buy, _market_id, _trade_selected_item, true)
	_refresh_trade_button(_trade_sell, _market_id, _trade_selected_item, false)
	if not _merchant_accepts(_trade_selected_item):
		_trade_buy.disabled = true
		_trade_sell.disabled = true
		_trade_buy.tooltip_text = "This workplace does not trade that item."
		_trade_sell.tooltip_text = _trade_buy.tooltip_text
	elif capacity > 0 and carried + _quantity > capacity:
		_trade_buy.disabled = true
		_trade_buy.tooltip_text = "Your backpack needs %d more spaces." % (carried + _quantity - capacity)
	if not bool(_state().get("permissions", {}).get("trade", true)):
		_trade_detail.text = "Trading is unavailable for your current role."
	if controller.has_method("action_pending") and bool(controller.action_pending()):
		_trade_buy.disabled = true
		_trade_sell.disabled = true
		_trade_buy.tooltip_text = "Waiting for the town to finish your request."
		_trade_sell.tooltip_text = _trade_buy.tooltip_text


func _facility(id: String) -> void:
	if id == "refinery":
		if not bool(_details_open.get("about:" + str(context.get("id", id)), false)):
			_market(id, true)
			return
		_button(_body, "Back to trading", func(): _details_open["about:" + str(context.get("id", id))] = false; _rebuild(), true)
	var facility: Dictionary = _state().get("facilities", {}).get(id, {})
	_heading.text = str(_state().get("locations", {}).get(id, {}).get("label", context.get("label", "Workplace")))
	_live(_body, func():
		var data: Dictionary = _state().get("facilities", {}).get(id, {})
		var lines: Array[String] = [str(data.get("status", "Community workplace"))]
		for key: String in ["power_kw", "demand_kw", "battery_kwh", "battery_capacity_kwh", "water_l", "condition", "pressure", "panels", "reserve"]:
			if data.has(key): lines.append("%s: %s" % [key.replace("_", " ").capitalize(), str(snappedf(float(data[key]), 0.01))])
		return " · ".join(lines))
	if not _inventory(id).is_empty():
		_live(_body, func(): return "Stored here: " + _inventory_text(_inventory(id)))
	if _manage() and not facility.is_empty():
		_action(_body, "Maintain equipment", "repair", {"facility": id})
		if id == "solar_array":
			_action(_body, "Install panel · solar kit + 150 cr", "build_solar", {})
			_action(_body, "Add 100 kWh capacity · battery kit + 120 cr", "upgrade_battery", {})
		if id == "lunar_greenhouse":
			_action(_body, "Refill reservoir · 20 L", "refill_habitat", {"quantity": 20})
	if id == "refinery":
		_line(_body, "Refinery services", 18, GOLD)
	if id in ["gas_station", "airfield", "refinery"]:
		_line(_body, "Parked vehicle fuel service", 20, GOLD)
		for vehicle: Vehicle in controller.nearby_fuel_vehicles():
			var card := _card(_body)
			_line(card, vehicle.display_name(), 18, GOLD)
			_live(card, func(): return vehicle.fuel_readout() if is_instance_valid(vehicle) else "Vehicle departed")
			_action(card, "Buy 5 L from this depot", "refuel", {"vehicle": vehicle.vid, "facility": id, "quantity": 5})
	if id in ["warehouse", "cargo"]:
		_freight()
	_recipes(id)
	_contracts("", true, id)
	if id in ["cooperative", "lunar_greenhouse", "housing", "habitat", "oil_rig", "workshop"]:
		_line(_body, "People at this workplace", 20, GOLD)
		for person: Dictionary in _state().get("citizens", {}).values():
			if str(person.get("target", "")) != id:
				continue
			_button(_body, "Find " + str(person.name), func(): controller.locate(str(person.id)))


func _recipes(facility: String) -> void:
	var recipes: Dictionary = controller.simulation.recipe_catalog()
	for id: String in recipes:
		var recipe: Dictionary = recipes[id]
		var worksite := str(recipe.get("facility", "refinery" if id == "refine" else "workshop"))
		if worksite != facility:
			continue
		var card := _card(_body)
		_line(card, str(recipe.get("label", id)), 19, GOLD)
		_line(card, "Uses: %s\nMakes: %s" % [_inventory_text(recipe.get("inputs", {})), _inventory_text(recipe.get("outputs", {}))], 15, MUTED)
		_action(card, "Start processing batch", "process", {"recipe": id})
	_live(_body, func():
		var lines: Array[String] = []
		for batch: Dictionary in _state().get("batches", []):
			if str(batch.get("facility", "")) == facility:
				lines.append("%s · %d seconds remaining" % [str(batch.get("recipe", "Batch")).replace("_", " "), ceili(float(batch.get("remaining", 0)))])
		return "\n".join(lines))


func _freight() -> void:
	_line(_body, "Dispatch cargo to the other world", 20, GOLD)
	_line(_body, "Packaging, freight fees and travel time apply. Goods arrive in your locker; your rocket journey is separate.", 15, MUTED)
	var row := _row(_body)
	var ids: Array = _items().keys()
	var choose := _options(row, ids, _freight_item)
	_freight_item = str(ids[choose.selected])
	choose.item_selected.connect(func(index): _freight_item = str(ids[index]))
	_quantity_control(row)
	_button(row, "Dispatch shipment", func(): _act("ship", {"from": _pack(), "to": "player_earth" if controller.current_planet() == "moon" else "player_moon", "item": _freight_item, "quantity": _quantity}))
	_live(_body, func():
		var lines: Array[String] = []
		for shipment: Dictionary in _state().get("shipments", []):
			lines.append("%d %s · %s · %ds" % [int(shipment.get("quantity", 0)), _title(str(shipment.get("item", "cargo"))), str(shipment.get("status", "in transit")), ceili(float(shipment.get("remaining", 0)))])
		return "\n".join(lines) if not lines.is_empty() else "No shipments in transit.")


func _contracts(giver: String, work_controls: bool, destination := "") -> void:
	var shown := 0
	for id: String in _state().get("quests", {}):
		var quest: Dictionary = _state().quests[id]
		if work_controls and str(_state().get("locations", {}).get(str(quest.get("destination", "")), {}).get("planet", controller.current_planet())) != controller.current_planet():
			continue
		if not giver.is_empty() and str(quest.get("giver", "")) != giver:
			continue
		if not destination.is_empty() and str(quest.get("destination", "")) != destination:
			continue
		if not work_controls and str(quest.get("status", "available")) == "available":
			continue
		shown += 1
		var card := _card(_body)
		_line(card, str(quest.get("title", id)), 19, GOLD)
		_line(card, str(quest.get("description", "")), 15, MUTED)
		_live(card, func():
			var current: Dictionary = _state().get("quests", {}).get(id, {})
			return "%s · Reward %d credits · %d × %s" % [str(current.get("status", "available")).capitalize(), int(current.get("reward", 0)), int(current.get("quantity", 0)), _title(str(current.get("item", "goods")))])
		var row := _row(card)
		if work_controls:
			if str(quest.get("status", "available")) == "available":
				_action(row, "Accept request", "accept_quest", {"id": id})
			elif str(quest.get("status")) == "active":
				if not destination.is_empty():
					_action(row, "Give goods", "deliver_quest", {"id": id})
				_action(row, "Cancel request", "cancel_quest", {"id": id})
		_button(row, "Locate customer", func(): controller.locate(str(quest.get("destination", "earth_market"))))
	if shown == 0:
		_line(_body,"No active requests yet. Visit the community board or talk to a neighbor to find a job." if not work_controls else "No requests here right now.",15,MUTED)


func _sky() -> void:
	_line(_body, "A personal guide to the lunar sky", 22, GOLD)
	_line(_body, "Photographs show faint structures through long exposure. Planet positions use an approximate reference epoch. ESO / S. Brunier; NASA / GSFC.", 15, MUTED)
	if controller.current_planet() != "moon":
		_button(_body, "Find rocket", controller.locate_rocket)
		return
	var toggle := CheckButton.new()
	toggle.text = "Observation exposure and constellation guides"
	toggle.button_pressed = controller._observation
	toggle.toggled.connect(controller.set_observation)
	_body.add_child(toggle)
	for target: Dictionary in controller.sky_targets():
		var card := _card(_body)
		_line(card, str(target.get("name", "Sky target")), 19, GOLD)
		_line(card, str(target.get("detail", "")), 15, MUTED)
		if target.get("direction") is Vector3:
			_button(card, "Look toward " + str(target.get("name", "target")), func(): controller.look_at_sky(target.direction))


func _near(id: String) -> bool:
	return bool(controller.call("_target_in_range", id)) if controller.has_method("_target_in_range") else false


func _act(kind: String, payload: Dictionary) -> void:
	if context.is_empty():
		return
	var scoped := payload.duplicate(true)
	if not str(context.get("town_id", "")).is_empty():
		scoped.town_id = str(context.town_id)
	controller.request_action(kind, scoped)
	_rebuild(true)


func _refresh_trade_button(button: Button, market: String, item: String, buying: bool) -> void:
	var can_trade := bool(_state().get("permissions", {}).get("trade", true))
	var price: int = int(controller.simulation.quote(market, item, _quantity, buying))
	var accounts: Dictionary = _state().get("accounts", {})
	if buying:
		button.disabled = not can_trade or int(_inventory(market).get(item, 0)) < _quantity \
			or int(accounts.get("player", 0)) < price
	else:
		var owner := str(_state().get("locations", {}).get(market, {}).get("owner", market))
		button.disabled = not can_trade or int(_inventory(_pack()).get(item, 0)) < _quantity \
			or (accounts.has(owner) and int(accounts.get(owner, 0)) < price)
	button.tooltip_text = "Trading is unavailable for your current role." if not can_trade \
		else ("Market stock or your credits are too low." if buying else "Your cargo or the buyer's funds are too low.") if button.disabled \
		else "%s %d for %d credits." % ["Buy" if buying else "Sell", _quantity, price]


func _quantity_control(parent: Node) -> void:
	var quantity := SpinBox.new()
	quantity.min_value = 1
	quantity.max_value = 100
	quantity.step = 1
	quantity.value = _quantity
	quantity.custom_minimum_size = Vector2(84, 34)
	quantity.value_changed.connect(func(value: float):
		_quantity = int(value)
		_rebuild.call_deferred(true))
	parent.add_child(quantity)


func _options(parent: Node, ids: Array, selected: String) -> OptionButton:
	var select := OptionButton.new()
	select.custom_minimum_size = Vector2(190, 34)
	for id in ids:
		select.add_item(_title(str(id)))
	select.select(maxi(0, ids.find(selected)))
	parent.add_child(select)
	return select


func _inventory_text(inventory: Dictionary) -> String:
	var lines: Array[String] = []
	var keys: Array = inventory.keys()
	keys.sort()
	for item: String in keys:
		if int(inventory[item]) > 0:
			lines.append("%s × %d" % [_title(item), int(inventory[item])])
	return "  ·  ".join(lines) if not lines.is_empty() else "Empty"


func _section(title: String, kicker := "") -> void:
	_line(_body, title, 21, GOLD)
	if not kicker.is_empty(): _line(_body, kicker, 14, MUTED)


func _first_interaction(kinds: Array) -> String:
	for item: Dictionary in controller.interactions():
		if str(item.get("kind", "")) in kinds: return str(item.get("id", ""))
	return ""


func _place_group(item: Dictionary) -> String:
	var kind := str(item.get("kind", ""))
	var id := str(item.get("id", ""))
	if kind in ["citizen", "npc", "worker"]: return "People"
	if kind in ["plot", "farm"] or id in ["cooperative", "lunar_greenhouse"]: return "Farms"
	if kind in ["market", "shop"] or id in ["water", "kitchen", "warehouse", "cargo", "gas_station", "airfield"]: return "Trade & services"
	if id in ["oil_rig", "refinery", "workshop", "solar_array", "ice_mine", "carrier"]: return "Industry"
	return "Community"


func _has_quest(giver: String) -> bool:
	for quest: Dictionary in _state().get("quests", {}).values():
		if str(quest.get("giver", "")) == giver and str(quest.get("status", "available")) != "complete": return true
	return false


func _item_category(id: String) -> String:
	if controller.simulation.crop_catalog().has(id): return "Crops"
	for crop: Dictionary in controller.simulation.crop_catalog().values():
		if str(crop.get("planting_item", "")) == id: return "Planting"
	if id in ["crude_oil", "gasoline", "diesel", "jet_fuel", "bitumen"]: return "Fuel"
	if id in ["meal", "flour", "dried_food", "cooking_oil", "fish", "honey", "water"]: return "Food"
	return "Materials"


func _row(parent: Node) -> HFlowContainer:
	var row := HFlowContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	parent.add_child(row)
	return row


func _card(parent: Node, featured := false) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuTheme.panel(INSET, GOLD if featured else BORDER, 10, 8))
	parent.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)
	return column


func _line(parent: Node, text: String, size := 16, color := INK) -> Label:
	var label := MenuTheme.label(text, MenuTheme.content_font_size(size), color)
	parent.add_child(label)
	return label


func _live(parent: Node, read: Callable) -> Label:
	var label := _line(parent, str(read.call()), 15, MUTED)
	_live_labels.append({"label": label, "read": read})
	return label


func _button(parent: Node, text: String, action: Callable, primary := false) -> Button:
	var button := Button.new()
	button.text = text
	MenuTheme.style_button(button, primary, true)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _action(parent: Node, text: String, kind: String, payload: Dictionary, primary := false) -> Button:
	var button := _button(parent, text, func(): _act(kind, payload), primary)
	button.set_meta("frontier_action", kind)
	button.set_meta("frontier_payload", payload.duplicate(true))
	return button


static func _style(fill: Color, border: Color, radius: int) -> StyleBoxFlat:
	return MenuTheme.panel(fill, border, 10, radius)


func _tutorial() -> void:
	var guide: Variant = controller.get("tutorial") if "tutorial" in controller else null
	if not is_instance_valid(guide):
		_line(_body,"Walk up to a person or place and press E. Your journal can show a waypoint to any nearby job or town.",20,GOLD)
		_button(_body,"Find places",func(): select_page("Places"))
		return
	var chapters := _row(_body)
	for chapter: String in ["basics","farming","industry","moon"]:
		_button(chapters,{"basics":"First day","farming":"Grow food","industry":"Make & deliver","moon":"Moon life"}[chapter],func(): guide.start(chapter); _rebuild())
	var summary: Dictionary = guide.summary()
	_line(_body,"Learn one thing at a time",22,GOLD)
	var card := _card(_body)
	_line(card,str(summary.get("title","Your first day")),20,GREEN)
	_line(card,str(summary.get("text","Meet your neighbors and try a simple job.")),18)
	_line(card,"Step %d of %d"%[int(summary.get("step",1)),int(summary.get("total",1))],15,MUTED)
	var row := _row(_body)
	if bool(summary.get("active",false)):
		_button(row,"Show me where",guide.show_target)
		_button(row,"Pause guide",func(): guide.pause(); _rebuild())
	else:
		_button(row,"Start guide" if not bool(summary.get("complete",false)) else "Practice again",func(): guide.start(); _rebuild())
	_button(row,"Restart tutorial",func(): guide.restart(); _rebuild())
