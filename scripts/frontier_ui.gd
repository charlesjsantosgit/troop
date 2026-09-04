class_name FrontierUI
extends Control
## Live, keyboard-accessible management surface. All buttons call the same
## validated simulation actions used by physical worksite interactions.

const PAGES := ["Overview", "Farms", "Market", "Crew", "Industry", "Freight", "Quests", "Sky"]
const INK := Color("eaf0de")
const MUTED := Color("b3c3af")
const GOLD := Color("eccc86")
const GREEN := Color("a8d995")
var controller: Node
var page := "Overview"
var _panel: PanelContainer
var _body: VBoxContainer
var _heading: Label
var _balance: Label
var _notice: Label
var _scroll: ScrollContainer
var _nav: Dictionary = {}
var _live_labels: Array = []
var _refresh := 0.0
var _quantity := 5
var _selected_crop: Dictionary = {}
var _freight_item := "tomato"
var _market_location := "earth_market"


func configure(owner_controller: Node) -> void:
	controller = owner_controller


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0.015, 0.03, 0.025, 0.80)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", _style(Color("17281f"), Color("50634b"), 16))
	add_child(_panel)
	_panel.minimum_size_changed.connect(_resize)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	_panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 12)
	margin.add_child(stack)
	var top := _row(stack)
	var title := _line(top, "ROOTS & ROCKETS", 25, GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(top, "Save", func():
		controller.last_message = "Society saved." if controller.save_progress() else "Save failed. Check available disk space."
		_refresh_live())
	_button(top, "Close · B / Esc", close)
	_balance = _line(stack, "", 16, GREEN)
	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 20)
	stack.add_child(content)
	var nav := VBoxContainer.new()
	nav.custom_minimum_size.x = 128
	nav.add_theme_constant_override("separation", 7)
	content.add_child(nav)
	for label: String in PAGES:
		var b := _button(nav, label, func(): select_page(label))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_nav[label] = b
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	content.add_child(right)
	_heading = _line(right, "", 24, INK)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 12)
	_scroll.add_child(_body)
	_notice = _line(stack, "", 15, GOLD)
	_notice.custom_minimum_size.y = 42
	get_viewport().size_changed.connect(_resize)
	_resize()


func _resize() -> void:
	var window := get_viewport_rect().size
	var dimensions := Vector2(minf(1260, window.x - 32), minf(810, window.y - 32))
	_panel.position = (window - dimensions) * 0.5
	_panel.size = dimensions


func open(next_page := "Overview") -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if controller.world.local_player.cam:
		controller.world.local_player.cam.set_aiming(false)
	select_page(next_page)


func close() -> void:
	visible = false
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and (event.physical_keycode in [KEY_ESCAPE, KEY_B]):
		close()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not visible:
		return
	_refresh -= delta
	if _refresh <= 0.0:
		_refresh = 0.5
		_refresh_live()


func _state() -> Dictionary:
	return controller.simulation.state


func _inventory(location: String) -> Dictionary:
	return _state().get("inventories", {}).get(location, {})


func _pack() -> String:
	return "player_" + controller.current_planet()


func _items() -> Dictionary:
	return controller.simulation.item_catalog()


func _title(id: String) -> String:
	var definition: Variant = _items().get(id, {})
	return str(definition.get("name", definition.get("label", id.replace("_", " ").capitalize()))) if definition is Dictionary else id.replace("_", " ").capitalize()


func _refresh_live() -> void:
	var time := float(_state().get("time", 0))
	var civil_hour := fmod(time, 1200.0) / 50.0
	_balance.text = "%s  ·  %d credits  ·  %d residents  ·  Day %d · %02d:%02d" % [
		"Moon / Crater Gardens" if controller.current_planet() == "moon" else "Earth / Canopy Commons",
		int(_state().get("accounts", {}).get("player", 0)), _state().get("citizens", {}).size(),
		1 + int(time / 1200.0), int(civil_hour), int(fmod(civil_hour, 1.0) * 60.0)]
	_notice.text = controller.last_message
	for item: Dictionary in _live_labels:
		if is_instance_valid(item.label):
			item.label.text = str(item.read.call())


func select_page(next_page: String) -> void:
	page = next_page if next_page in PAGES else "Overview"
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_live_labels.clear()
	_heading.text = page
	_scroll.scroll_vertical = 0
	for key in _nav:
		_nav[key].disabled = key == page
	match page:
		"Overview": _overview()
		"Farms": _farms()
		"Market": _market()
		"Crew": _crew()
		"Industry": _industry()
		"Freight": _freight()
		"Quests": _quests()
		"Sky": _sky()
	_refresh_live()
	_resize.call_deferred()


func _overview() -> void:
	_line(_body, "A society built by working paws", 21, GOLD)
	_line(_body, "Grow food, care for your crew, keep machines running and deliver what your neighbors need. E opens a nearby workplace. B opens this board anywhere.")
	var actions := _row(_body)
	_button(actions, "Find paid work", func(): select_page("Quests"))
	_button(actions, "Visit your farm", func(): select_page("Farms"))
	_button(actions, "Find rocket", controller.locate_rocket)
	_line(_body, "Your cargo · " + controller.current_planet().capitalize(), 19, GOLD)
	_live(_body, func(): return _inventory_text(_inventory(_pack())))
	_line(_body, "Work in progress", 19, GOLD)
	_live(_body, func():
		var lines: Array[String] = []
		for citizen: Dictionary in _state().get("citizens", {}).values():
			if citizen.get("planet", "earth") == controller.current_planet():
				lines.append("%s · %s%s" % [citizen.get("name", "Worker"), citizen.get("activity", "Resting"),
					" · " + str(citizen.blocker) if not str(citizen.get("blocker", "")).is_empty() else ""])
		return "\n".join(lines))
	_line(_body, "Town ledger", 19, GOLD)
	_live(_body, func():
		var events: Array = _state().get("events", [])
		var lines: Array[String] = []
		for index in range(maxi(0, events.size() - 7), events.size()):
			var entry: Variant = events[index]
			lines.append(str(entry.get("message", entry.get("text", entry))) if entry is Dictionary else str(entry))
		return "\n".join(lines) if not lines.is_empty() else "Your crew is beginning its shift.")


func _farms() -> void:
	_line(_body, "Each bed uses real planting stock, water and nutrients. Walk to a bed for hands-on work, or enable its grower on the Crew page.")
	var crops: Dictionary = controller.simulation.crop_catalog()
	var plots: Dictionary = _state().get("plots", {})
	for id: String in plots:
		var plot: Dictionary = plots[id]
		if plot.get("planet", "earth") != controller.current_planet():
			continue
		var card := _card(_body)
		var head := _row(card)
		var label := _line(head, str(plot.get("name", id.replace("_", " ").capitalize())), 19, GOLD)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_button(head, "Locate", func(): controller.locate(id))
		_live(card, func():
			var p: Dictionary = _state().plots[id]
			return "%s · Growth %d%% · Health %d%% · Water %d%% · Nutrients %d%%" % [
				_title(str(p.get("crop", "empty"))), roundi(float(p.get("growth", 0)) * 100),
				roundi(float(p.get("health", 1)) * 100), roundi(float(p.get("moisture", 0))),
				roundi(float(p.get("nutrients", 0)))])
		_live(card, func():
			var p: Dictionary = _state().plots[id]
			return "%s · %s · Crew care %s" % [str(p.get("status", "")), str(p.get("owner", "")).capitalize(), "enabled" if p.get("automatic", false) else "off"])
		if plot.get("owner", "") != "player":
			continue
		var row := _row(card)
		var choose := OptionButton.new()
		choose.custom_minimum_size = Vector2(190, 36)
		choose.add_theme_font_size_override("font_size", 15)
		var crop_ids: Array = crops.keys()
		for crop_id: String in crop_ids:
			choose.add_item(str(crops[crop_id].get("name", crops[crop_id].get("label", crop_id.capitalize()))))
		var selected := str(_selected_crop.get(id, plot.get("crop", "lettuce")))
		choose.select(maxi(0, crop_ids.find(selected)))
		_selected_crop[id] = crop_ids[choose.selected]
		choose.item_selected.connect(func(index: int): _selected_crop[id] = crop_ids[index])
		row.add_child(choose)
		_button(row, "Plant", func(): _act("plant", {"plot": id, "crop": _selected_crop[id]}))
		_action(row, "Harvest", "harvest", {"plot": id})
		_action(row, "Water", "water", {"plot": id})
		_action(row, "Feed", "fertilize", {"plot": id})
		var orders := _row(card)
		_action(orders, "Enable / pause crew care", "toggle_plot", {"plot": id})
		_action(orders, "Inspect", "inspect", {"target": id})
		if not str(plot.get("crop", "")).is_empty() and float(plot.get("health", 1)) <= 0.0:
			_action(orders, "Clear failed crop", "clear_plot", {"plot": id})


func _market() -> void:
	var default_market: String = controller.current_planet() + "_market"
	if not _state().locations.has(_market_location) or _state().locations[_market_location].planet != controller.current_planet():
		_market_location = default_market
	var market := _market_location
	_line(_body, "Prices follow available stock. Both sides need money, goods and capacity; the full quantity is quoted again when you trade.")
	if controller.current_planet() == "earth":
		var desks := _row(_body)
		_button(desks, "Canopy market", func():
			_market_location = "earth_market"
			select_page("Market"))
		_button(desks, "Refinery fuel desk", func():
			_market_location = "refinery"
			select_page("Market"))
	_line(_body, str(_state().locations[market].label), 19, GOLD)
	var tools := _row(_body)
	_button(tools, "Locate market", func(): controller.locate(market))
	_line(tools, "Quantity", 16)
	_quantity_control(tools)
	var stock := _inventory(market)
	var all_items: Array = _items().keys()
	all_items.sort()
	for item: String in all_items:
		if market == "refinery" and item not in ["crude_oil", "gasoline", "diesel", "jet_fuel", "bitumen", "water", "spare_parts"]:
			continue
		if int(stock.get(item, 0)) <= 0 and int(_inventory(_pack()).get(item, 0)) <= 0:
			continue
		var card := _card(_body)
		_line(card, _title(item), 18, GOLD)
		_live(card, func():
			return "Market %d · Your cargo %d · Buy %d: %d cr · Sell %d: %d cr" % [
				int(_inventory(market).get(item, 0)), int(_inventory(_pack()).get(item, 0)),
				_quantity, controller.simulation.quote(market, item, _quantity, true),
				_quantity, controller.simulation.quote(market, item, _quantity, false)])
		var row := _row(card)
		_button(row, "Buy", func(): _act("buy", {"market": market, "item": item, "quantity": _quantity}))
		_button(row, "Sell", func(): _act("sell", {"market": market, "item": item, "quantity": _quantity}))


func _crew() -> void:
	var selected := str(controller.selected_interaction.get("id", ""))
	if _state().get("citizens", {}).has(selected):
		_conversation(selected)
	_line(_body, "Your residents travel to workplaces, use available resources, take breaks and earn wages. Their current task and blocker come from the simulation.")
	var jobs: Variant = controller.simulation.job_catalog()
	var job_ids: Array = jobs.keys() if jobs is Dictionary else jobs
	for id: String in _state().get("citizens", {}):
		var citizen: Dictionary = _state().citizens[id]
		if citizen.get("planet", "earth") != controller.current_planet():
			continue
		var card := _card(_body)
		var row := _row(card)
		var title := _line(row, "%s · %s" % [citizen.get("name", id), str(citizen.get("job", "citizen")).replace("_", " ").capitalize()], 19, GOLD)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_button(row, "Locate", func(): controller.locate(id))
		_live(card, func():
			var c: Dictionary = _state().citizens[id]
			return "%s · %s\n%s\nSkill %.1f · Completed jobs %d · Wage %s cr/task" % [
				str(c.get("job", "citizen")).replace("_", " ").capitalize(),
				str(c.get("activity", "Resting")), str(c.get("blocker", "")) if not str(c.get("blocker", "")).is_empty() else "Work can proceed with available tools and supplies.",
				float(c.get("skill", 1)), int(c.get("completed", 0)), str(c.get("wage", 0))])
		var controls := _row(card)
		var select := OptionButton.new()
		select.custom_minimum_size = Vector2(205, 36)
		for job: String in job_ids:
			select.add_item(job.replace("_", " ").capitalize())
		select.select(maxi(0, job_ids.find(citizen.get("job", "citizen"))))
		controls.add_child(select)
		_button(controls, "Assign profession", func(): _act("assign_job", {"citizen": id, "job": job_ids[select.selected]}))
		_action(controls, "Pause / resume work", "toggle_worker", {"citizen": id})


func _conversation(id: String) -> void:
	var citizen: Dictionary = _state().citizens[id]
	var card := _card(_body)
	_line(card, "Talking with " + str(citizen.name), 23, GOLD)
	_live(card, func():
		var current: Dictionary = _state().citizens[id]
		var text := "I'm %s. Right now: %s." % [str(current.job).replace("_", " "), str(current.activity)]
		if not str(current.blocker).is_empty(): text += "\nI need help: " + str(current.blocker) + "."
		if not str(current.get("pending_job", "")).is_empty(): text += "\nI'll take the new assignment after finishing this task."
		text += "\nHunger %d%% · Fatigue %d%%" % [roundi(float(current.needs.hunger) * 100), roundi(float(current.needs.fatigue) * 100)]
		return text)
	_live(card, func():
		var current: Dictionary = _state().citizens[id]
		var observations: Array = current.get("observations", [])
		var memories: Array = current.get("memories", [])
		var lines: Array[String] = []
		if not observations.is_empty():
			var observation: Dictionary = observations.back()
			lines.append("What I know: %s\nSource: %s · %ds ago" % [str(observation.get("fact", "")), str(observation.get("source", "My work")), maxi(0, int(float(_state().time) - float(observation.get("time", 0))))])
		if not memories.is_empty(): lines.append("My last completed job: " + str(memories.back().get("fact", "")))
		return "\n".join(lines) if not lines.is_empty() else "I'm starting my shift. I'll report what I find at the worksite.")
	for quest_id: String in _state().quests:
		var quest: Dictionary = _state().quests[quest_id]
		if quest.get("giver", "") != id:
			continue
		_line(card, "Could you help? " + str(quest.title), 19, GOLD)
		_line(card, str(quest.description) + " Reward: %d credits." % int(quest.reward))
		var actions := _row(card)
		_action(actions, "Accept request", "accept_quest", {"id": quest_id})
		_button(actions, "Locate delivery", func(): controller.locate(str(quest.destination)))
		_action(actions, "Complete delivery", "deliver_quest", {"id": quest_id})


func _industry() -> void:
	_line(_body, "Crude oil is refined into useful fuels before delivery. Lunar panels feed lights, pumps and batteries; maintenance and supplies limit output.")
	for id: String in _state().get("facilities", {}):
		var facility: Dictionary = _state().facilities[id]
		if facility.get("planet", "earth") != controller.current_planet():
			continue
		var card := _card(_body)
		var row := _row(card)
		var title := _line(row, str(facility.get("name", id.replace("_", " ").capitalize())), 19, GOLD)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_button(row, "Locate", func(): controller.locate(id))
		_live(card, func():
			var f: Dictionary = _state().facilities[id]
			var lines: Array[String] = [str(f.get("status", "Operating"))]
			for key: String in ["power_kw", "demand_kw", "battery_kwh", "battery_capacity_kwh", "water_l", "condition", "pressure", "pump_condition", "panels", "reserve"]:
				if f.has(key):
					lines.append("%s: %s" % [key.replace("_", " ").capitalize(), str(snappedf(float(f[key]), 0.01))])
			var stock := _inventory(id)
			if not stock.is_empty(): lines.append(_inventory_text(stock))
			return " · ".join(lines))
		_action(card, "Maintain / repair", "repair", {"facility": id})
		if id == "lunar_greenhouse":
			_action(card, "Refill reservoir · 20 L from your locker", "refill_habitat", {"quantity": 20})
	if controller.current_planet() == "moon":
		_action(_body, "Install solar panel · solar kit + 150 cr", "build_solar", {})
		_action(_body, "Add 100 kWh storage · battery kit + 120 cr", "upgrade_battery", {})
		_button(_body, "Locate solar and battery worksite", func(): controller.locate("solar_array"))
	else:
		_line(_body, "Vehicle fuel service", 19, GOLD)
		_line(_body, "Park beside a depot, then buy fuel for a nearby vehicle. NPC tankers replenish depot stocks. Driving consumes the fuel saved in each vehicle's tank.")
		var depots := _row(_body)
		for depot: String in ["gas_station", "airfield", "refinery"]:
			_button(depots, "Locate " + depot.replace("_", " "), func(): controller.locate(depot))
		for vehicle: Vehicle in controller.nearby_fuel_vehicles():
			var card := _card(_body)
			_line(card, vehicle.display_name(), 18, GOLD)
			_live(card, func(): return vehicle.fuel_readout() if is_instance_valid(vehicle) else "Vehicle departed")
			var controls := _row(card)
			for depot: String in ["gas_station", "airfield", "refinery"]:
				_action(controls, "Buy 5 L · " + depot.replace("_", " "), "refuel", {"vehicle": vehicle.vid, "facility": depot, "quantity": 5})
	_line(_body, "Processing orders", 19, GOLD)
	var recipes: Dictionary = controller.simulation.recipe_catalog()
	for recipe: String in recipes:
		var definition: Dictionary = recipes[recipe]
		if definition.get("planet", "earth") != controller.current_planet():
			continue
		var recipe_card := _card(_body)
		var location := "refinery" if recipe == "refine" else "workshop"
		_line(recipe_card, "%s · %s" % [str(definition.get("name", definition.get("label", recipe.capitalize()))), location.capitalize()], 18, GOLD)
		_line(recipe_card, "Inputs: %s\nOutputs: %s · Energy %.1f kWh" % [_inventory_text(definition.get("inputs", {})), _inventory_text(definition.get("outputs", {})), float(definition.get("energy", 0))], 14, MUTED)
		var controls := _row(recipe_card)
		_action(controls, "Start batch", "process", {"recipe": recipe})
		_button(controls, "Locate " + location, func(): controller.locate(location))
	_line(_body, "Batches in progress", 19, GOLD)
	_live(_body, func():
		var lines: Array[String] = []
		for batch: Dictionary in _state().get("batches", []):
			lines.append("%s · %s · %ds" % [str(batch.get("recipe", "")).replace("_", " ").capitalize(), str(batch.get("facility", "")), ceili(float(batch.get("remaining", 0)))])
		return "\n".join(lines) if not lines.is_empty() else "No processing orders are running.")


func _freight() -> void:
	_line(_body, "Shipments remove goods at departure and deliver them after transit. Cargo stays in its recorded location while your expedition travels separately.")
	var row := _row(_body)
	_button(row, "Find rocket boarding hatch", controller.locate_rocket)
	_button(row, "Locate cargo office", func(): controller.locate("cargo" if controller.current_planet() == "moon" else "warehouse"))
	_line(_body, "Dispatch your cargo to the other world", 19, GOLD)
	var fields := _row(_body)
	var items := OptionButton.new()
	items.custom_minimum_size = Vector2(220, 36)
	var item_ids: Array = _items().keys()
	for item: String in item_ids:
		items.add_item(_title(item))
	items.select(maxi(0, item_ids.find(_freight_item)))
	_freight_item = str(item_ids[items.selected])
	items.item_selected.connect(func(index: int): _freight_item = str(item_ids[index]))
	fields.add_child(items)
	_quantity_control(fields)
	_button(fields, "Dispatch", func():
		_act("ship", {"from": _pack(), "to": "player_earth" if controller.current_planet() == "moon" else "player_moon",
			"item": _freight_item, "quantity": _quantity}))
	_line(_body, "Manifest and fleet activity", 19, GOLD)
	_live(_body, func():
		var lines: Array[String] = []
		for shipment: Dictionary in _state().get("shipments", []):
			lines.append("%s · %d %s · %s → %s · %s · %ds" % [
				shipment.get("id", "Freight"), int(shipment.get("quantity", 0)), _title(str(shipment.get("item", "cargo"))),
				shipment.get("from", ""), shipment.get("to", ""), shipment.get("status", "In transit"), ceili(float(shipment.get("remaining", 0)))])
		return "\n".join(lines) if not lines.is_empty() else "No cargo is in transit. Your dispatcher will create loads when suppliers and funded customers are ready.")


func _quests() -> void:
	_line(_body, "Neighbors pay for useful work from funded accounts. Delivery rewards require the goods at the destination; completed contracts cannot be claimed again.")
	for id: String in _state().get("quests", {}):
		var quest: Dictionary = _state().quests[id]
		var card := _card(_body)
		_line(card, str(quest.get("title", id.capitalize())), 20, GOLD)
		_line(card, str(quest.get("description", "")))
		_live(card, func():
			var q: Dictionary = _state().quests[id]
			return "%s · %d × %s → %s · Reward %d credits" % [str(q.get("status", "available")).capitalize(),
				int(q.get("quantity", 0)), _title(str(q.get("item", "work"))), str(q.get("destination", "community")), int(q.get("reward", 0))])
		var row := _row(card)
		_action(row, "Accept", "accept_quest", {"id": id})
		_action(row, "Deliver", "deliver_quest", {"id": id})
		_action(row, "Cancel", "cancel_quest", {"id": id})
		_button(row, "Locate customer", func(): controller.locate(str(quest.get("destination", "earth_market"))))


func _sky() -> void:
	_line(_body, "Lunar observatory", 22, GOLD)
	_line(_body, "The photographic panorama records faint structures with long exposure. Observation mode increases their visibility and reveals real constellation guides. Planet locations use an approximate astronomical reference epoch.")
	_line(_body, "Photograph: ESO / S. Brunier · Earth and constellation reference: NASA / GSFC", 14, MUTED)
	if controller.current_planet() != "moon":
		_line(_body, "Travel to the Moon to observe the airless sky.")
		_button(_body, "Find rocket", controller.locate_rocket)
		return
	var toggle := CheckButton.new()
	toggle.text = "Observation exposure and constellation guides"
	toggle.button_pressed = controller._observation
	toggle.toggled.connect(controller.set_observation)
	_body.add_child(toggle)
	for target: Dictionary in controller.sky_targets():
		var card := _card(_body)
		_line(card, str(target.get("name", "Sky target")), 18, GOLD)
		_line(card, str(target.get("detail", "")), 15, MUTED)
		if target.get("direction") is Vector3:
			_button(card, "Look toward " + str(target.get("name", "target")), func(): controller.look_at_sky(target.direction))


func _act(kind: String, payload: Dictionary) -> void:
	controller.request_action(kind, payload)
	_refresh_live()


func _quantity_control(parent: Node) -> void:
	var quantity := SpinBox.new()
	quantity.min_value = 1
	quantity.max_value = 100
	quantity.step = 1
	quantity.value = _quantity
	quantity.custom_minimum_size = Vector2(100, 36)
	quantity.value_changed.connect(func(value: float):
		_quantity = int(value)
		_refresh_live())
	parent.add_child(quantity)


func _inventory_text(inventory: Dictionary) -> String:
	var lines: Array[String] = []
	var keys: Array = inventory.keys()
	keys.sort()
	for item: String in keys:
		if int(inventory[item]) > 0:
			lines.append("%s × %d" % [_title(item), int(inventory[item])])
	return "  ·  ".join(lines) if not lines.is_empty() else "Empty"


func _row(parent: Node) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	return row


func _card(parent: Node) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(Color("213428"), Color("40573e"), 10))
	parent.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)
	return column


func _line(parent: Node, text: String, size := 16, color := INK) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func _live(parent: Node, read: Callable) -> Label:
	var label := _line(parent, str(read.call()), 15, MUTED)
	_live_labels.append({"label": label, "read": read})
	return label


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 36
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", INK)
	button.add_theme_stylebox_override("normal", _style(Color("37523a"), Color("698157"), 7))
	button.add_theme_stylebox_override("hover", _style(Color("4c6a46"), GOLD, 7))
	button.add_theme_stylebox_override("focus", _style(Color("3d5940"), GOLD, 7))
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _action(parent: Node, text: String, kind: String, payload: Dictionary) -> void:
	_button(parent, text, func(): _act(kind, payload))


static func _style(fill: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style
