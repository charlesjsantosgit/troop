class_name MoonColonyUI
extends Control
## One keyboard-friendly field journal and market, refreshed from authority data.

signal closed
signal action_requested(action: String, target: int)
signal purchase_requested(quantity: int)
signal waypoint_requested(action: String, target: int, title: String)

const INK := Color(0.045, 0.064, 0.10)
const CREAM := Color(0.94, 0.94, 0.85)
const GOLD := Color(1.0, 0.80, 0.31)
const MUTED := Color(0.64, 0.75, 0.79)
var at_market := false
var balance_label: Label
var _panel: PanelContainer
var _tabs: TabContainer
var _location: Label
var _cargo: Label
var _objective: Label
var _farm_status: Label
var _aging: Label
var _sell_fresh: Button
var _sell_aged: Button
var _upgrade_buttons: Array[Button] = []
var _order_buttons: Array[Button] = []
var _plot_labels: Array[Label] = []
var _landmark_labels: Array[Label] = []
var _buy_buttons: Array[Button] = []
var _snapshot: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()
	get_viewport().size_changed.connect(_resize_panel)
	_resize_panel()


func present(market: bool) -> void:
	at_market = market
	visible = true
	_tabs.current_tab = 0 if market else 1
	refresh(_snapshot)
	_tabs.get_tab_bar().grab_focus()


func refresh(snapshot: Dictionary) -> void:
	_snapshot = snapshot
	if not balance_label:
		return
	var balance := int(snapshot.get("balance", 0))
	balance_label.text = "%d BANANAS" % balance
	_location.text = "MUENSTER'S SUPPLY COUNTER" if at_market else "FIELD JOURNAL  /  J TO CLOSE"
	var cargo: Dictionary = snapshot.get("cargo", {})
	var fresh := int(cargo.get("fresh", 0))
	var aged := int(cargo.get("aged", 0))
	_cargo.text = "COLONY CARGO     %d fresh cheese   /   %d aged cheese" % [fresh, aged]
	_sell_fresh.text = "SELL FRESH  /  +%d bananas" % (fresh * 2)
	_sell_aged.text = "SELL AGED  /  +%d bananas" % (aged * 6)
	_sell_fresh.disabled = not at_market or fresh == 0
	_sell_aged.disabled = not at_market or aged == 0
	_sell_fresh.tooltip_text = "Muenster pays 2 bananas per fresh wedge. Visit the counter to trade."
	_sell_aged.tooltip_text = "Muenster pays 6 bananas per aged wedge. Visit the counter to trade."
	for i in range(_buy_buttons.size()):
		_buy_buttons[i].disabled = not at_market or balance < ([1, 4][i] * 3)
	var offers: Array = snapshot.get("upgrade_offers", [])
	for i in range(_upgrade_buttons.size()):
		var button := _upgrade_buttons[i]
		if i >= offers.size():
			button.disabled = true
			continue
		var offer: Dictionary = offers[i]
		var maxed := int(offer.get("level", 0)) >= int(offer.get("max_level", 1))
		button.text = "%s  /  %s" % [str(offer.get("name", "Upgrade")),
			"COMPLETE" if maxed else "%d bananas" % int(offer.get("cost", 0))]
		button.disabled = not at_market or maxed or balance < int(offer.get("cost", 0))
	var contracts: Array = snapshot.get("contracts", [])
	var completed := 0
	var prior_orders_done := true
	for i in range(_order_buttons.size()):
		var button := _order_buttons[i]
		if i >= contracts.size():
			button.disabled = true
			continue
		var order: Dictionary = contracts[i]
		var done := bool(order.get("done", false))
		completed += int(done)
		var need_fresh := int(order.get("fresh", 0))
		var need_aged := int(order.get("aged", 0))
		button.text = "%s  /  %s" % [str(order.get("name", "Delivery %d" % (i + 1))),
			"DELIVERED" if done else "%d fresh + %d aged  >  %d bananas" % [need_fresh, need_aged, int(order.get("reward", 0))]]
		button.disabled = not at_market or done or not prior_orders_done or fresh < need_fresh or aged < need_aged
		prior_orders_done = prior_orders_done and done
		button.tooltip_text = "Deliver from colony cargo. Each order can be completed once."
	var plots: Array = snapshot.get("plots", [])
	var ready := 0
	var growing := 0
	for i in range(_plot_labels.size()):
		var plot: Dictionary = plots[i] if i < plots.size() else {}
		var status := "LOCKED / EXPAND FARM"
		if bool(plot.get("unlocked", false)):
			status = "EMPTY / E TO PLANT"
			if bool(plot.get("ready", false)):
				ready += 1
				status = "RIPE / E TO HARVEST"
			elif bool(plot.get("planted", false)):
				growing += 1
				status = "%ds / %s" % [ceili(float(plot.get("remaining", 0))),
					"TENDED" if bool(plot.get("tended", false)) else "E TO TEND"]
		_plot_labels[i].text = "BED %02d\n%s" % [i + 1, status]
		_plot_labels[i].modulate = GOLD if bool(plot.get("ready", false)) else CREAM
	var upgrades: Dictionary = snapshot.get("upgrades", {})
	_farm_status.text = "%d ripe beds  /  %d growing  /  %s\nFree cultures. Growth advances during active play. Harvests go into sealed colony cargo." % [ready, growing,
		"helper tending the farm" if int(upgrades.get("helper", 0)) > 0 else "helper available at the counter"]
	var aging: Dictionary = snapshot.get("aging", {})
	var batch_value: Variant = aging.get("batches", [])
	var batches: int = batch_value.size() if batch_value is Array else int(batch_value)
	var remaining: float = float(batch_value[0]) if batch_value is Array and not batch_value.is_empty() else float(aging.get("remaining", 0))
	_aging.text = "AGING CELLAR  /  %s\n3 fresh cheese become 2 aged cheese. Use E at the cellar to start a batch." % [
		"%d batch / %ds remaining" % [batches, ceili(remaining)] if batches > 0 else "READY FOR A BATCH"]
	var landmarks: Array = snapshot.get("landmarks", [])
	var discoveries := 0
	for i in range(_landmark_labels.size()):
		var landmark: Dictionary = landmarks[i] if i < landmarks.size() else {}
		var discovered := bool(landmark.get("discovered", false))
		discoveries += int(discovered)
		_landmark_labels[i].text = "%s  /  %s" % [str(landmark.get("name", ["Observatory", "Solar relay", "Crystal garden"][i])),
			"SURVEY COMPLETE" if discovered else "UNEXPLORED"]
		_landmark_labels[i].modulate = GOLD if discovered else CREAM
	if fresh > 0:
		_objective.text = "NEXT: Bring your harvest to Muenster. Sell it, fill an order, or keep three wedges for the aging cellar."
	elif ready > 0:
		_objective.text = "NEXT: Your first cheese is ripe! Follow the farm marker and press E beside a yellow bed."
	elif growing > 0 and discoveries < 3:
		_objective.text = "NEXT: Explore while your cheese grows. Survey three landmarks to improve the entire farm."
	elif completed < 3:
		_objective.text = "NEXT: Plant empty beds, age your harvest, and complete Muenster's delivery orders."
	else:
		_objective.text = "ALL ORDERS DELIVERED. Keep building your cheese business and exploring the Moon."


func _build() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0.01, 0.018, 0.035, 0.78)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", _style(INK, Color(0.33, 0.47, 0.52), 18))
	add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	_panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var brand := VBoxContainer.new()
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(brand)
	_label(brand, "CRATER & CURD", 30, GOLD)
	_location = _label(brand, "LUNAR CO-OP", 13, MUTED)
	balance_label = _label(header, "0 BANANAS", 23, GOLD)
	balance_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cargo = _label(column, "COLONY CARGO", 17, CREAM)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_font_size_override("font_size", 17)
	column.add_child(_tabs)
	var market := _page("Market")
	_label(market, "Your farm's sealed cargo is ready for trading here.\nPurchased snacks go into your personal backpack instead.", 15, MUTED)
	var sell_row := HBoxContainer.new()
	market.add_child(sell_row)
	_sell_fresh = _action(sell_row, "SELL FRESH", "sell_fresh", 0)
	_sell_aged = _action(sell_row, "SELL AGED", "sell_aged", 0)
	_label(market, "FARM IMPROVEMENTS", 17, GOLD)
	_label(market, "Bigger harvests / faster cultures / two extra beds / a monkey farmhand", 14, MUTED)
	var upgrades := GridContainer.new()
	upgrades.columns = 2
	upgrades.add_theme_constant_override("h_separation", 8)
	upgrades.add_theme_constant_override("v_separation", 8)
	market.add_child(upgrades)
	for i in range(4):
		_upgrade_buttons.append(_action(upgrades, "Upgrade", "upgrade", i))
	_label(market, "MUENSTER'S DELIVERY BOARD", 17, GOLD)
	for i in range(3):
		_order_buttons.append(_action(market, "Delivery", "contract", i))
	_label(market, "BACKPACK SNACKS  /  3 BANANAS EACH", 14, MUTED)
	var snacks := HBoxContainer.new()
	market.add_child(snacks)
	for amount in [1, 4]:
		var button := _button(snacks, "BUY %d CHEESE  /  %d bananas" % [amount, amount * 3])
		button.pressed.connect(func() -> void: purchase_requested.emit(amount))
		_buy_buttons.append(button)
	var farm := _page("Your farm")
	_objective = _label(farm, "Connecting to the colony...", 19, GOLD)
	_objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_farm_status = _label(farm, "", 15, MUTED)
	_farm_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var beds := GridContainer.new()
	beds.columns = 3
	beds.add_theme_constant_override("h_separation", 10)
	beds.add_theme_constant_override("v_separation", 10)
	farm.add_child(beds)
	for i in range(6):
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("panel", _style(Color(0.08, 0.12, 0.16), Color(0.20, 0.31, 0.35), 8))
		beds.add_child(card)
		_plot_labels.append(_label(card, "BED %02d" % (i + 1), 14, CREAM))
	_waypoint(farm, "GUIDE ME TO THE CHEESE FARM", "farm", 0, "CHEESE FARM")
	_aging = _label(farm, "", 16, CREAM)
	_aging.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_waypoint(farm, "GUIDE ME TO THE AGING CELLAR", "age", 0, "AGING CELLAR")
	_waypoint(farm, "GUIDE ME TO MUENSTER", "market", 0, "CRATER & CURD")
	var explore := _page("Field guide")
	_label(explore, "A SMALL MOON. A GROWING COLONY.", 21, GOLD)
	var intro := _label(explore, "Survey the landmarks with E to earn bananas. Complete all three surveys for a permanent growth bonus. Follow your selected bearing across the curved surface; the lander bearing remains available for your return.", 16, CREAM)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var descriptions := ["A lonely telescope listening to Earth. Finish its survey and fund the next harvest.",
		"Sunlight becomes life support. The relay can refill your oxygen for the next leg of your journey.",
		"Mineral spires grow out of an ancient crater. Record the formation to complete your survey route."]
	for i in range(3):
		_landmark_labels.append(_label(explore, "LANDMARK", 18, GOLD))
		var lore := _label(explore, descriptions[i], 15, MUTED)
		lore.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_waypoint(explore, "SET BEARING", "discover", i, ["OBSERVATORY", "SOLAR RELAY", "CRYSTAL GARDEN"][i])
	var footer := HBoxContainer.new()
	column.add_child(footer)
	var hint := _label(footer, "E interact   /   J journal   /   I backpack", 13, MUTED)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var leave := _button(footer, "RETURN TO MOON  /  ESC")
	leave.size_flags_horizontal = Control.SIZE_SHRINK_END
	leave.pressed.connect(func() -> void: closed.emit())


func _page(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	_tabs.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	scroll.add_child(body)
	return body


func _label(parent: Node, value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func _button(parent: Node, value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 42
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_color_override("font_disabled_color", Color(0.44, 0.52, 0.55))
	button.add_theme_stylebox_override("normal", _style(Color(0.12, 0.20, 0.24), Color(0.26, 0.39, 0.42), 7))
	button.add_theme_stylebox_override("hover", _style(Color(0.20, 0.31, 0.33), GOLD, 7))
	button.add_theme_stylebox_override("focus", _style(Color(0, 0, 0, 0), GOLD, 7))
	button.add_theme_stylebox_override("disabled", _style(Color(0.075, 0.10, 0.14), Color(0.15, 0.21, 0.25), 7))
	parent.add_child(button)
	return button


func _action(parent: Node, value: String, action: String, target: int) -> Button:
	var button := _button(parent, value)
	button.pressed.connect(func() -> void: action_requested.emit(action, target))
	return button


func _waypoint(parent: Node, value: String, action: String, target: int, title: String) -> void:
	var button := _button(parent, value)
	button.pressed.connect(func() -> void: waypoint_requested.emit(action, target, title))


func _resize_panel() -> void:
	if not _panel:
		return
	var screen := get_viewport_rect().size
	var desired := Vector2(minf(900, screen.x - 32), minf(710, screen.y - 48))
	_panel.size = desired
	_panel.position = (screen - desired) * 0.5


static func _style(fill: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(13)
	return style
