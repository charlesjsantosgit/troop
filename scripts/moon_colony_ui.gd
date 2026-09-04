class_name MoonColonyUI
extends Control
## One keyboard-friendly field journal and market, refreshed from authority data.

signal closed
signal action_requested(action: String, target: int)
signal purchase_requested(quantity: int)
signal waypoint_requested(action: String, target: int, title: String)

const MenuTheme := preload("res://scripts/menu_theme.gd")
const INK := MenuTheme.INK
const CREAM := MenuTheme.TEXT
const GOLD := MenuTheme.ACCENT
const MUTED := MenuTheme.MUTED
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
var _market_notice: Label
var _order_details: Array[Label] = []


func _ready() -> void:
	theme = MenuTheme.build()
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
	balance_label.text = "%d bananas" % balance
	_location.text = "Muenster · Lunar supply counter" if at_market else "Colony journal · Plan your next stop"
	_market_notice.text = "You are at the counter. Buy supplies, sell colony cargo and deliver completed orders." if at_market else "Visit Muenster to trade or buy improvements. Your journal shows the colony from anywhere; work happens at each site."
	var cargo: Dictionary = snapshot.get("cargo", {})
	var fresh := int(cargo.get("fresh", 0))
	var aged := int(cargo.get("aged", 0))
	_cargo.text = "Colony cargo   ·   %d fresh cheese   ·   %d aged cheese" % [fresh, aged]
	_sell_fresh.text = "Sell all fresh · +%d bananas" % (fresh * 2)
	_sell_aged.text = "Sell all aged · +%d bananas" % (aged * 6)
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
			"Complete" if maxed else "%d bananas" % int(offer.get("cost", 0))]
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
			"Delivered" if done else "Deliver · Earn %d bananas" % [int(order.get("reward", 0))]]
		button.disabled = not at_market or done or not prior_orders_done or fresh < need_fresh or aged < need_aged
		var reason := "Delivered. Thank you for supplying the colony." if done else "Bring %d fresh and %d aged cheese from colony cargo." % [need_fresh, need_aged]
		if not done:
			if not prior_orders_done:
				reason += " Complete the previous order first."
			elif fresh < need_fresh or aged < need_aged:
				reason += " Still needed: %d fresh, %d aged." % [maxi(need_fresh - fresh, 0), maxi(need_aged - aged, 0)]
			elif not at_market:
				reason += " Ready to deliver at Muenster's counter."
			else:
				reason += " Ready to deliver."
		_order_details[i].text = reason
		button.tooltip_text = reason
		prior_orders_done = prior_orders_done and done
	var plots: Array = snapshot.get("plots", [])
	var ready := 0
	var growing := 0
	for i in range(_plot_labels.size()):
		var plot: Dictionary = plots[i] if i < plots.size() else {}
		var status := "Locked · Expand farm"
		if bool(plot.get("unlocked", false)):
			status = "Empty · E to plant"
			if bool(plot.get("ready", false)):
				ready += 1
				status = "Ripe · E to harvest"
			elif bool(plot.get("planted", false)):
				growing += 1
				status = "%ds / %s" % [ceili(float(plot.get("remaining", 0))),
					"Tended" if bool(plot.get("tended", false)) else "E to tend"]
		_plot_labels[i].text = "Bed %02d\n%s" % [i + 1, status]
		_plot_labels[i].modulate = GOLD if bool(plot.get("ready", false)) else CREAM
	var upgrades: Dictionary = snapshot.get("upgrades", {})
	_farm_status.text = "%d ripe beds  /  %d growing  /  %s\nFree cultures. Growth advances during active play. Harvests go into sealed colony cargo." % [ready, growing,
		"helper tending the farm" if int(upgrades.get("helper", 0)) > 0 else "helper available at the counter"]
	var aging: Dictionary = snapshot.get("aging", {})
	var batch_value: Variant = aging.get("batches", [])
	var batches: int = batch_value.size() if batch_value is Array else int(batch_value)
	var remaining: float = float(batch_value[0]) if batch_value is Array and not batch_value.is_empty() else float(aging.get("remaining", 0))
	_aging.text = "Aging cellar · %s\n3 fresh cheese become 2 aged cheese. Use E at the cellar to start a batch." % [
		"%d batch / %ds remaining" % [batches, ceili(remaining)] if batches > 0 else "Ready for a batch"]
	var landmarks: Array = snapshot.get("landmarks", [])
	var discoveries := 0
	for i in range(_landmark_labels.size()):
		var landmark: Dictionary = landmarks[i] if i < landmarks.size() else {}
		var discovered := bool(landmark.get("discovered", false))
		discoveries += int(discovered)
		_landmark_labels[i].text = "%s  /  %s" % [str(landmark.get("name", ["Observatory", "Solar relay", "Crystal garden"][i])),
			"Survey complete" if discovered else "Unexplored"]
		_landmark_labels[i].modulate = GOLD if discovered else CREAM
	if fresh > 0:
		_objective.text = "Next: Bring your harvest to Muenster. Sell it, fill an order, or keep three wedges for the aging cellar."
	elif ready > 0:
		_objective.text = "Next: Your first cheese is ripe! Follow the farm marker and press E beside a yellow bed."
	elif growing > 0 and discoveries < 3:
		_objective.text = "Next: Explore while your cheese grows. Survey three landmarks to improve the entire farm."
	elif completed < 3:
		_objective.text = "Next: Plant empty beds, age your harvest, and complete Muenster's delivery orders."
	else:
		_objective.text = "All orders delivered. Keep building your cheese business and exploring the Moon."


func _build() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0.025, 0.045, 0.04, 0.16)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	_panel = PanelContainer.new()
	_panel.minimum_size_changed.connect(_resize_panel, CONNECT_DEFERRED)
	_panel.add_theme_stylebox_override("panel", MenuTheme.panel())
	add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	_panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var brand := VBoxContainer.new()
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brand.add_theme_constant_override("separation", 4)
	header.add_child(brand)
	_label(brand, "TROOP / LUNAR CO-OP", 12, GOLD)
	_label(brand, "Crater & Curd", 30, CREAM)
	_location = _label(brand, "Lunar colony", 15, MUTED)
	balance_label = _label(header, "0 bananas", 22, GOLD)
	balance_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	balance_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	balance_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cargo = _label(column, "Colony cargo", 16, CREAM)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_font_size_override("font_size", 16)
	column.add_child(_tabs)
	var market := _page("Market")
	_market_notice = _label(market, "Visit Muenster to trade.", 16, GOLD)
	_waypoint(market, "Find Muenster", "market", 0, "CRATER & CURD")
	_label(market, "Sell your harvest", 22, CREAM)
	_label(market, "Colony cargo stays separate from your personal backpack. Fresh cheese sells for 2 bananas each; aged cheese sells for 6.", 15, MUTED)
	var sell_row := HBoxContainer.new()
	market.add_child(sell_row)
	_sell_fresh = _action(sell_row, "Sell fresh", "sell_fresh", 0)
	_sell_aged = _action(sell_row, "Sell aged", "sell_aged", 0)
	_label(market, "Supplies for your backpack", 22, CREAM)
	_label(market, "Personal cheese costs 3 bananas each. You need room in your backpack to carry it.", 15, MUTED)
	var snacks := HBoxContainer.new()
	market.add_child(snacks)
	for amount in [1, 4]:
		var button := _button(snacks, "Buy %d cheese · %d bananas" % [amount, amount * 3])
		button.pressed.connect(func() -> void: purchase_requested.emit(amount))
		_buy_buttons.append(button)
	var farm := _page("Colony")
	_objective = _label(farm, "Connecting to the colony…", 19, GOLD)
	_farm_status = _label(farm, "", 15, MUTED)
	var beds := GridContainer.new()
	beds.columns = 3
	farm.add_child(beds)
	for i in range(6):
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("panel", MenuTheme.panel(MenuTheme.INSET, MenuTheme.BORDER, 12, 8))
		beds.add_child(card)
		_plot_labels.append(_label(card, "Bed %02d" % (i + 1), 14, CREAM))
	_waypoint(farm, "Find the cheese farm", "farm", 0, "CHEESE FARM")
	_aging = _label(farm, "", 16, CREAM)
	_waypoint(farm, "Find the aging cellar", "age", 0, "AGING CELLAR")
	_label(farm, "Farm improvements", 22, CREAM)
	_label(farm, "Buy improvements at Muenster's counter: bigger harvests, faster cultures, more beds or a farmhand.", 15, MUTED)
	var upgrades := GridContainer.new()
	upgrades.columns = 2
	farm.add_child(upgrades)
	for i in range(4):
		_upgrade_buttons.append(_action(upgrades, "Upgrade", "upgrade", i))
	var contracts := _page("Contracts")
	_label(contracts, "Supply the colony", 22, CREAM)
	_label(contracts, "Grow and age your cheese, then visit Muenster to deliver these orders in sequence. Rewards go into your banana balance.", 15, MUTED)
	for i in range(3):
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", MenuTheme.panel(MenuTheme.INSET, MenuTheme.BORDER, 16, 8))
		contracts.add_child(card)
		var order := VBoxContainer.new()
		card.add_child(order)
		_label(order, "ORDER %02d" % (i + 1), 12, GOLD)
		_order_details.append(_label(order, "Loading order…", 15, MUTED))
		_order_buttons.append(_action(order, "Deliver", "contract", i))
	_waypoint(contracts, "Find Muenster to deliver", "market", 0, "CRATER & CURD")
	var explore := _page("Explore")
	_label(explore, "Three landmarks. A stronger colony.", 22, CREAM)
	_label(explore, "Visit each landmark and press E to survey it. Earn bananas at every stop; completing all three adds a permanent growth bonus to the farm.", 16, MUTED)
	var descriptions := ["Survey the telescope and fund your next harvest.",
		"Refill your oxygen at the solar relay before continuing.",
		"Record the mineral formations in this ancient crater."]
	for i in range(3):
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", MenuTheme.panel(MenuTheme.INSET, MenuTheme.BORDER, 16, 8))
		explore.add_child(card)
		var landmark := VBoxContainer.new()
		card.add_child(landmark)
		_landmark_labels.append(_label(landmark, "Landmark", 18, GOLD))
		_label(landmark, descriptions[i], 15, MUTED)
		_waypoint(landmark, "Set waypoint", "discover", i, ["OBSERVATORY", "SOLAR RELAY", "CRYSTAL GARDEN"][i])
	var footer := HBoxContainer.new()
	column.add_child(footer)
	var hint := _label(footer, "E · Interact   /   J · Colony   /   I · Backpack", 13, MUTED)
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var leave := _button(footer, "Back to Moon · Esc")
	leave.autowrap_mode = TextServer.AUTOWRAP_OFF
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
	var label := MenuTheme.label(value, size, color)
	parent.add_child(label)
	return label


func _button(parent: Node, value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	MenuTheme.style_button(button)
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
	var desired := Vector2(minf(760, screen.x - 80), minf(580, screen.y - 80))
	_panel.size = desired
	_panel.position = (screen - desired) * 0.5
