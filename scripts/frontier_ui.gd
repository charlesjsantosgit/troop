class_name FrontierUI
extends Control
## Every work control belongs to the physical subject that opened this panel.
## The pocket journal provides information and waypoints, never remote orders.

const PAGES := ["Journal", "Tutorial", "Places", "Contracts", "Sky"]
const INK := Color("edf0df")
const MUTED := Color("b6c6b4")
const GOLD := Color("efd395")
const GREEN := Color("addb99")
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
var _live_labels: Array = []
var _refresh := 0.0
var _quantity := 5
var _selected_crop: Dictionary = {}
var _freight_item := "tomato"
var _structure := ""


func configure(owner_controller: Node) -> void:
	controller = owner_controller


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0.015, 0.03, 0.025, 0.72)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", _style(Color("17281f"), Color("657453"), 18))
	add_child(_panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	_panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 12)
	margin.add_child(stack)
	var top := _row(stack)
	_heading = _line(top, "TRAVEL JOURNAL", 25, GOLD)
	_heading.custom_minimum_size.x = 300
	_journal_button = _button(top, "My journal", func(): open({}))
	_button(top, "Close · B / Esc", close)
	_balance = _line(stack, "", 15, GREEN)
	_journal_nav = _row(stack)
	for label: String in PAGES:
		_nav[label] = _button(_journal_nav, label, func(): select_page(label))
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 12)
	_scroll.add_child(_body)
	_notice = _line(stack, "", 15, GOLD)
	_notice.custom_minimum_size.y = 38
	get_viewport().size_changed.connect(_resize)
	_resize()


func _resize() -> void:
	if _panel == null:
		return
	var window := get_viewport_rect().size
	var dimensions := Vector2(minf(1060, window.x - 32), minf(790, window.y - 32))
	_panel.position = (window - dimensions) * 0.5
	_panel.size = dimensions


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


func close() -> void:
	visible = false
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode in [KEY_ESCAPE, KEY_B]:
		close()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not visible:
		return
	_refresh -= delta
	if _refresh > 0:
		return
	_refresh = 0.5
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
	_balance.text = "%s · %s · %d credits" % [str(town.get("name", "Crater Gardens" if controller.current_planet() == "moon" else "Canopy Commons")),
		controller.current_planet().capitalize(), int(_state().get("accounts", {}).get("player", 0))]
	_notice.text = str(controller.last_message)
	for item: Dictionary in _live_labels:
		if is_instance_valid(item.label):
			item.label.text = str(item.read.call())


func _structure_key() -> String:
	var result: Array = [context.get("id", ""), _manage(), _town().get("claimed", false), _town().get("id",""), controller.current_planet()]
	var subject: Dictionary = _state().get("plots", {}).get(str(context.get("id", "")), {})
	result.append([subject.get("crop", ""), float(subject.get("health", 1)) <= 0])
	var citizen: Dictionary = _state().get("citizens", {}).get(str(context.get("id", "")), {})
	result.append([citizen.get("job", ""),citizen.get("employer", ""),citizen.get("can_manage", false)])
	if str(context.get("kind", "")) in ["market", "shop"]:
		result.append(_inventory(str(context.get("id", ""))).keys())
	for quest: Dictionary in _state().get("quests", {}).values():
		result.append([quest.get("id", ""), quest.get("status", "")])
	if page=="Tutorial" and "tutorial" in controller and is_instance_valid(controller.tutorial):
		result.append(controller.tutorial.summary())
	return JSON.stringify(result)


func select_page(next_page: String) -> void:
	context.clear()
	page = next_page if next_page in PAGES else "Places" if next_page in ["Farms", "Crew", "Market", "Industry", "Freight"] else "Contracts" if next_page == "Quests" else "Journal"
	_rebuild()


func _rebuild(preserve_scroll := false) -> void:
	var old_scroll := _scroll.scroll_vertical if preserve_scroll else 0
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_live_labels.clear()
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
	_structure = _structure_key()
	_refresh_live()
	_scroll.set_deferred("scroll_vertical", old_scroll)
	_resize.call_deferred()


func _journal() -> void:
	_line(_body, "Good places. Useful work. People to meet.", 22, GOLD)
	_line(_body, "Walk up to a neighbor, crop bed or workplace and press E to interact. Your journal keeps track of your cargo, contracts and places to visit.")
	var card := _card(_body)
	_line(card, "Your cargo", 19, GOLD)
	_live(card, func(): return _inventory_text(_inventory(_pack())))
	var row := _row(_body)
	_button(row, "Find a workplace", func(): select_page("Places"))
	_button(row, "My contracts", func(): select_page("Contracts"))
	_button(row, "Find rocket", controller.locate_rocket)
	for town: Dictionary in (controller.known_towns() if controller.has_method("known_towns") else _state().get("towns", [])):
		var place := _card(_body)
		_line(place, str(town.get("name", "Town")), 19, GOLD)
		_line(place, "%s · %s" % [str(town.get("planet", "earth")).capitalize(), "Managed by " + str(town.get("owner_name", "a neighbor")) if town.get("claimed", false) else "Open for a new town steward"], 15, MUTED)
		_button(place, "Locate town board", func(): controller.locate("town:"+str(town.id)))


func _places() -> void:
	if controller.has_method("known_towns"):
		for town: Dictionary in controller.known_towns():
			var town_card := _card(_body)
			_line(town_card,str(town.get("name","Town")),19,GOLD)
			_line(town_card,str(town.get("planet","earth")).capitalize()+" · "+("Claimed" if town.get("claimed",false) else "Available to claim"),15,MUTED)
			_button(town_card,"Find town board",func(): controller.locate("town:"+str(town.id)))
	_line(_body, "Choose a waypoint, then visit the person or worksite. Orders are placed in person.")
	var entries: Array = controller.interactions()
	for item: Dictionary in entries:
		var card := _card(_body)
		var row := _row(card)
		_line(row, str(item.get("label", item.get("id", "Place"))), 18, GOLD)
		_button(row, "Locate", func(): controller.locate(str(item.id)))
		var citizen: Dictionary = _state().get("citizens", {}).get(str(item.id), {})
		if not citizen.is_empty():
			_line(card, str(citizen.get("activity", "Enjoying the town")), 14, MUTED)


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
	_line(_body, str(citizen.get("job", "citizen")).replace("_", " ").capitalize(), 21, GREEN)
	var card := _card(_body)
	_live(card, func():
		var person: Dictionary = _state().get("citizens", {}).get(id, {})
		return "Right now: %s%s\nSkill %.1f · %d jobs completed · Wage %d cr per task" % [person.get("activity", "Resting"),
			"\nI need help: " + str(person.blocker) if not str(person.get("blocker", "")).is_empty() else "",
			float(person.get("skill", 1)), int(person.get("completed", 0)), int(person.get("wage", 0))])
	_live(card, func():
		var person: Dictionary = _state().get("citizens", {}).get(id, {})
		var needs: Dictionary = person.get("needs", {})
		var observations: Array = person.get("observations", [])
		return "Hunger %d%% · Fatigue %d%%%s" % [roundi(float(needs.get("hunger", 0)) * 100), roundi(float(needs.get("fatigue", 0)) * 100),
			"\n" + str(observations.back().get("fact", "")) if not observations.is_empty() else ""])
	_contracts(id, true)
	var trade := str(citizen.get("trade_location", ""))
	if trade.is_empty() and not _state().has("permissions"):
		trade = ("moon_market" if controller.current_planet() == "moon" else "earth_market") if citizen.get("job") == "merchant" else "refinery" if citizen.get("job") == "refinery_operator" else ""
	if not trade.is_empty():
		_line(_body, "My trading desk", 20, GOLD)
		if _near(trade):
			_market(trade, false)
		else:
			_line(_body, "Meet me at the trading desk to exchange goods.", 15, MUTED)
			_button(_body, "Locate trading desk", func(): controller.locate(trade))
	# Workplaces have machinery, fuel service and maintenance beyond a person's
	# trading inventory. Keep these reachable when the resident shares its desk.
	var person_position: Vector3 = controller._interaction_position(id)
	for workplace: Dictionary in controller.interactions():
		if str(workplace.get("kind", "")) not in ["facility", "board"]:
			continue
		if person_position.distance_to(workplace.position) <= 2.0 and _near(id) and _near(str(workplace.id)):
			_button(_body, "Use " + str(workplace.get("label", "workplace")),
				func(): controller.open_workplace(str(workplace.id)))
	if bool(citizen.get("can_manage", _manage())):
		_line(_body, "Work together", 20, GOLD)
		var jobs: Variant = controller.simulation.job_catalog()
		var ids: Array = jobs.keys() if jobs is Dictionary else jobs
		if controller.current_planet() == "moon":
			ids = ids.filter(func(job): return job in ["grower", "agronomist", "greenhouse_technician", "water_operator", "solar_technician", "merchant", "farm_manager", "citizen"])
		var row := _row(_body)
		var choose := _options(row, ids, str(citizen.get("job", "citizen")))
		_button(row, "Assign work" if citizen.get("employer") == "player" else "Hire for this job", func(): _act("assign_job", {"citizen": id, "job": ids[choose.selected]}))
		_action(row, "Pause / resume work", "toggle_worker", {"citizen": id})
	else:
		_line(_body, "The town steward arranges my work and wages.", 15, MUTED)


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


func _market(id: String, heading := true) -> void:
	if heading:
		_heading.text = str(_state().get("locations", {}).get(id, {}).get("label", context.get("label", "Trading desk")))
	_line(_body, "Local stock and funded demand set the price. Your complete order is quoted again when the trade is accepted.", 15, MUTED)
	var tools := _row(_body)
	_line(tools, "Order quantity", 16)
	_quantity_control(tools)
	var stock := _inventory(id)
	var ids: Array = _items().keys()
	ids.sort()
	for item: String in ids:
		if id == "refinery" and item not in ["crude_oil", "gasoline", "diesel", "jet_fuel", "bitumen", "water", "spare_parts"]:
			continue
		if int(stock.get(item, 0)) <= 0 and int(_inventory(_pack()).get(item, 0)) <= 0:
			continue
		var card := _card(_body)
		_line(card, _title(item), 18, GOLD)
		_live(card, func(): return "In stock %d · In your cargo %d\nBuy %d: %d cr · Sell %d: %d cr" % [int(_inventory(id).get(item, 0)), int(_inventory(_pack()).get(item, 0)),
			_quantity, controller.simulation.quote(id, item, _quantity, true), _quantity, controller.simulation.quote(id, item, _quantity, false)])
		var row := _row(card)
		_button(row, "Buy", func(): _act("buy", {"market": id, "item": item, "quantity": _quantity}))
		_button(row, "Sell", func(): _act("sell", {"market": id, "item": item, "quantity": _quantity}))
	if heading:
		_contracts("", true, id)


func _facility(id: String) -> void:
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
		_market(id, false)
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


func _quantity_control(parent: Node) -> void:
	var quantity := SpinBox.new()
	quantity.min_value = 1
	quantity.max_value = 100
	quantity.step = 1
	quantity.value = _quantity
	quantity.custom_minimum_size = Vector2(100, 38)
	quantity.value_changed.connect(func(value: float):
		_quantity = int(value)
		_refresh_live())
	parent.add_child(quantity)


func _options(parent: Node, ids: Array, selected: String) -> OptionButton:
	var select := OptionButton.new()
	select.custom_minimum_size = Vector2(220, 38)
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


func _row(parent: Node) -> HFlowContainer:
	var row := HFlowContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("h_separation", 8)
	row.add_theme_constant_override("v_separation", 8)
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
	button.custom_minimum_size.y = 38
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", INK)
	button.add_theme_stylebox_override("normal", _style(Color("37523a"), Color("698157"), 7))
	button.add_theme_stylebox_override("hover", _style(Color("4c6a46"), GOLD, 7))
	button.add_theme_stylebox_override("focus", _style(Color("3d5940"), GOLD, 7))
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _action(parent: Node, text: String, kind: String, payload: Dictionary) -> void:
	var button := _button(parent, text, func(): _act(kind, payload))
	button.set_meta("frontier_action", kind)
	button.set_meta("frontier_payload", payload.duplicate(true))


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
