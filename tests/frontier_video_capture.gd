extends Node
## Reproducible narrated-showcase footage. A fresh, non-persistent career is
## prepared for each shot. All demonstrated transactions use production UI.

var main: Node
var controller: FrontierController
var sim: RefCounted
var camera: Camera3D
var scene_id := "welcome"
var duration := 15.0
var elapsed := 0.0
var shot: Dictionary
var events: Dictionary = {}
var caption: Label
var detail: Label
var title: Label
var highlight: Panel
var jeep: Vehicle
var production_hash := ""
var from := Vector3.ZERO
var to := Vector3.ZERO
var aim := Vector3.ZERO
var lunar := false
var live_sim := true
var _scroll_goal := -1
var _pending_scroll: Control
var _scroll_wait := 0

func run(host: Node, args: PackedStringArray) -> void:
	main = host
	controller = main.frontier_controller
	sim = controller.simulation
	production_hash = _digest()
	controller.persistence_enabled = false
	controller.simulation_enabled = false
	controller.set_process(false)
	controller.save_path = ""
	var rows: Array = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	scene_id = str(args[1]) if args.size() > 1 else "welcome"
	for row: Dictionary in rows:
		if row.id == scene_id:
			shot = row
			break
	if shot.is_empty():
		push_error("Unknown showcase scene " + scene_id)
		get_tree().quit(2)
		return
	duration = float(args[2]) if args.size() > 2 else float(shot.get("duration", 15.0))
	_prepare()
	await _setup_shot()
	_build_overlay(rows.find(shot) + 1, rows.size())
	_camera(0.0)
	for frame in range(45):
		await get_tree().process_frame
	print("SHOWCASE_START id=%s frame=%d viewport=%s" % [scene_id, Engine.get_frames_drawn(), get_viewport().get_visible_rect().size])
	for frame in range(roundi(duration * 30.0)):
		elapsed = float(frame) / 30.0
		if live_sim:
			sim.tick(1.0 / 30.0)
		controller._update_sun()
		main.world.set_time_of_day_override(fmod(float(sim.state.time), 1200.0) / 50.0)
		_update_shot(elapsed / duration)
		_camera(elapsed / duration)
		if is_instance_valid(_pending_scroll):
			if _scroll_wait > 0:
				_scroll_wait -= 1
			else:
				_scroll_to(_pending_scroll)
				_pending_scroll = null
		if _scroll_goal >= 0:
			controller.ui._scroll.scroll_vertical = roundi(lerpf(float(controller.ui._scroll.scroll_vertical), float(_scroll_goal), 0.18))
		await get_tree().process_frame
	print("SHOWCASE_END id=%s frames=%d save_unchanged=%s" % [scene_id, roundi(duration * 30.0), _digest() == production_hash])
	get_tree().quit(0 if _digest() == production_hash else 3)

func _digest() -> String:
	var path := ProjectSettings.globalize_path(FrontierController.SAVE_PATH)
	return FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "missing"

func _prepare() -> void:
	main.set_process(false)
	main.set_process_unhandled_input(false)
	main.world.local_player.test_mode = true
	main.world.local_player.set_process(false)
	main.world.local_player.set_physics_process(false)
	main.world.local_player.visible = false
	main.world.local_player.cam.process_mode = Node.PROCESS_MODE_DISABLED
	if main.hud: main.hud.visible = false
	if main.chat_box: main.chat_box.visible = false
	if main._session_ui_layer: main._session_ui_layer.visible = false
	main.expedition_manager._ui_layer.visible = false
	controller._status.visible = false
	controller._prompt.visible = false
	controller._waypoint_label.visible = false
	controller._waypoint_marker.visible = false
	controller._sky_credit.visible = false
	get_viewport().scaling_3d_scale = 1.0
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	camera = Camera3D.new()
	main.world.add_child(camera)
	camera.far = 20000.0
	camera.fov = 64.0
	camera.current = true
	sim.state.climate = {"temperature":24.0, "rain":0.0}

func _setup_shot() -> void:
	lunar = scene_id in ["moon", "greenhouse", "solar", "night", "craters", "space", "observatory"]
	if lunar:
		Net.rocket_state.phase = Net.RocketMissionPhase.MOON_READY
		main.expedition_manager._apply_authoritative_state(Net.expedition_state_snapshot())
		main.expedition_manager.admin_travel(Net.PlayerRealm.MOON)
		controller._sync_realm()
		camera.environment = main.expedition_manager.moon_world.lunar_environment
		main.world.local_player.set_physics_process(false)
		main.world.local_player.visible = false
		main.world.local_player.cam.process_mode = Node.PROCESS_MODE_DISABLED
		camera.current = true
		controller._waypoint_marker.visible = false
		controller._sky_credit.visible = false
		sim.state.time = 2016.0
		sim._update_habitat(0.0)
		controller._update_sun()
	var advance := 90
	if scene_id in ["citizen", "market", "crew", "freight", "processing", "solar"]: advance = 0
	if scene_id == "oil": advance = 3
	if scene_id == "delivery": advance = 27
	for second in range(advance): sim.tick(1.0)
	from = Vector3(100, 58, 105)
	to = Vector3(82, 48, 106)
	aim = Vector3(-3, 5, -12)
	match scene_id:
		"town":
			from = Vector3(-10, 6, 18); to = Vector3(-17, 5.3, 22); aim = Vector3(-37, 5, 30)
		"citizen":
			_place("ookbar")
			controller.selected_interaction = {"id":"ookbar"}
			_open("Crew")
		"crew":
			_open("Crew")
		"crops", "farming":
			from = Vector3(-12, 14, -16); to = Vector3(-16, 11, -19); aim = Vector3(-35, 4.3, -33)
			_place("earth_1")
			if scene_id == "farming": _open("Farms")
		"market":
			_place("earth_market")
			_open("Market")
		"processing":
			_place("workshop")
			_open("Industry")
			await get_tree().process_frame
			await get_tree().process_frame
			_scroll_to(_button("Start batch"))
		"oil":
			from = Vector3(137, 14, -55); to = Vector3(130, 11, -56); aim = Vector3(120, 7, -35)
		"delivery":
			from = Vector3(115, 21, 28); to = Vector3(111, 18, 32); aim = Vector3(92, 5, 25)
		"refuel":
			_place("gas_station")
			var depot: Vector3 = controller._interaction_position("gas_station")
			jeep = main.world.spawn_vehicle(Vehicle.Kind.JEEP, "v:debug#showcase", depot + Vector3(7, 0.25, 5), 0.0)
			jeep.configure_frontier_fuel(sim)
			sim.consume_vehicle_fuel(jeep.vid, 25.0)
			from = depot + Vector3(19, 8, 18); to = depot + Vector3(15, 7, 20); aim = depot + Vector3(5, 1, 4)
		"freight":
			_place("warehouse")
			controller.ui._freight_item = "spare_parts"
			controller.ui._quantity = 2
			_open("Freight")
		"moon":
			from = Vector3(55, 32, 65); to = Vector3(43, 25, 62); aim = Vector3(-3, 1, -7)
		"greenhouse":
			from = Vector3(-8, 6, -5); to = Vector3(-7, 4, -12); aim = Vector3(-25, 1, -17)
			_place("lunar_greenhouse")
		"solar":
			_place("moon_market")
			_action("buy", {"market":"moon_market","item":"battery_kit","quantity":1})
			_place("solar_array")
			from = Vector3(44, 14, -2); to = Vector3(40, 11, -1); aim = Vector3(28, 1, -20)
		"night":
			live_sim = false
			from = Vector3(42, 18, 27); to = Vector3(40, 16, 25); aim = Vector3(-6, 2, -13)
			sim.state.time = 2200.0
			sim._update_habitat(0.0)
		"craters":
			from = Vector3(70, 18, 75); to = Vector3(60, 18, 85); aim = Vector3(180, 7, -180)
		"space", "observatory":
			live_sim = false
			controller.set_observation(true)
			sim.state.time = 2016.0
			sim._update_habitat(0.0)
			controller._update_sun()
			from = Vector3(0, 3, 0); to = from
			if scene_id == "observatory": _open("Sky")
		"finish":
			_open("Overview")
	controller.earth_settlement._refresh_state()
	controller.moon_settlement._refresh_state()

func _open(page: String) -> void:
	controller.ui.open(page)
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

func _place(id: String) -> void:
	var p := controller._interaction_position(id)
	if p == Vector3.INF:
		push_error("Showcase workplace not found: " + id)
		return
	main.world.local_player.global_position = p
	main.world.local_player.velocity = Vector3.ZERO

func _camera(progress: float) -> void:
	var smooth := smoothstep(0.0, 1.0, progress)
	var point := from.lerp(to, smooth)
	var target := aim
	if scene_id == "delivery":
		var worker: Dictionary = sim.state.citizens.diesel
		target = Vector3(float(worker.position[0]), 5.3, float(worker.position[1]))
		point = target + Vector3(14, 10, 18)
	if lunar:
		var site := controller.moon_site
		camera.global_position = site.to_global(point)
		if scene_id == "craters":
			var moon: MoonWorld = main.expedition_manager.moon_world
			var offset := Vector3(-1.2, 1.3, 2.0).lerp(Vector3(-1.0, 1.45, 1.85), smooth) * 450.0
			camera.global_position = moon.center_world_position() + offset
			camera.look_at(moon.center_world_position(), Vector3.UP)
			camera.fov = 52.0
		elif scene_id in ["space", "observatory"]:
			var direction := LunarSky.EARTH_DIRECTION
			var target_name := "Earth"
			if scene_id == "space" and progress > 0.34: target_name = "Sun"
			if scene_id == "space" and progress > 0.54: target_name = "Milky Way centre"
			if target_name != "Earth":
				for item: Dictionary in controller.sky_targets():
					if str(item.name) == target_name:
						direction = item.direction
			camera.fov = 12.0 if target_name in ["Earth", "Sun"] else 85.0
			camera.global_position = main.expedition_manager.moon_world.center_world_position() + direction * 700.0
			camera.look_at(camera.global_position + direction * 1000.0, Vector3.UP)
		else:
			camera.look_at(site.to_global(target), site.global_basis.y)
	else:
		camera.global_position = point
		camera.look_at(target)

func _once(key: String, progress: float, at: float) -> bool:
	if progress < at or events.has(key): return false
	events[key] = true
	return true

func _update_shot(p: float) -> void:
	match scene_id:
		"citizen":
			if _once("accept", p, 0.22): _click(_button("Accept request"))
			if _once("deliver", p, 0.62):
				_place("earth_market")
				_click(_button("Complete delivery"))
		"crew":
			if _once("profession", p, 0.12):
				for option: OptionButton in controller.ui.find_children("*", "OptionButton", true, false):
					for index in range(option.item_count):
						if option.get_item_text(index) == "Grower":
							option.select(index)
							break
					break
			if _once("assign", p, 0.25): _click(_button("Assign profession"))
			if _once("scroll", p, 0.65): _scroll_goal = 590
		"crops":
			if _once("harvest", p, 0.55):
				_action("harvest", {"plot":"earth_1"})
				controller.earth_settlement._refresh_state()
		"farming":
			if _once("harvest", p, 0.2): _click(_button("Harvest"))
			if _once("plant", p, 0.43): _click(_button("Plant"))
			if _once("feed", p, 0.66): _click(_button("Feed"))
			if _once("care", p, 0.82): _click(_button("Enable / pause crew care"))
		"market":
			if _once("banana", p, 0.08): _scroll_to(_button_in_card("Banana", "Sell"))
			if _once("sell", p, 0.30): _click(_button_in_card("Banana", "Sell"))
			if _once("buy", p, 0.65): _click(_button_in_card("Banana", "Buy"))
		"processing":
			if _once("process", p, 0.1): _click(_button("Start batch"))
			if _once("orders", p, 0.45): _scroll_to(_label("Batches in progress"))
		"oil":
			detail.text = "Crude extracted: %d L    |    Refined: %d L    |    Machinery consumes diesel + water" % [sim.state.metrics.crude_extracted, sim.state.metrics.crude_refined]
		"delivery":
			var driver: Dictionary = sim.state.citizens.diesel
			detail.text = "Diesel: %s    |    Gas-station gasoline: %d L" % [driver.activity, sim.stock("gas_station", "gasoline")]
		"refuel":
			if _once("board", p, 0.22):
				_open("Industry")
				_queue_scroll(_button("Buy 5 L · gas station"))
			if _once("fuel", p, 0.6): _click(_button("Buy 5 L · gas station"))
			if _once("close", p, 0.85): controller.ui.close()
		"freight":
			if _once("dispatch", p, 0.30): _click(_button("Dispatch"))
		"greenhouse":
			if _once("board", p, 0.33):
				_open("Industry")
				_queue_scroll(_button("Refill reservoir · 20 L from your locker"))
			if _once("refill", p, 0.65): _click(_button("Refill reservoir · 20 L from your locker"))
		"solar":
			if _once("board", p, 0.20):
				_open("Industry")
				_queue_scroll(_button("Install solar panel · solar kit + 150 cr"))
			if _once("panel", p, 0.42): _click(_button("Install solar panel · solar kit + 150 cr"))
			if _once("battery", p, 0.66): _click(_button("Add 100 kWh storage · battery kit + 120 cr"))
			if _once("close", p, 0.82): controller.ui.close()
		"night":
			sim.state.time += 3600.0 / (duration * 30.0)
			sim._update_habitat(3600.0 / (duration * 30.0))
			controller._update_sun()
			var room: Dictionary = sim.state.facilities.lunar_greenhouse
			detail.text = "UTILITY TIME-LAPSE  |  Solar %.1f kW  ·  Battery %.1f / %.0f kWh  ·  %s" % [sim.state.facilities.solar_array.power_kw, room.battery_kwh, room.battery_capacity_kwh, "POWERED" if room.powered else "POWER DEFICIT"]
		"observatory":
			if _once("scroll", p, 0.33): _scroll_goal = 480
			if _once("target", p, 0.62): _queue_scroll(_button("Look toward Earth"))
			if _once("earth", p, 0.80):
				_scroll_goal = -1
				_click(_button("Look toward Earth"))
		"finish":
			if _once("end", p, 0.68): controller.ui.close()
	if highlight.visible:
		highlight.modulate.a = maxf(0.0, highlight.modulate.a - 0.014)
		if highlight.modulate.a <= 0.0: highlight.visible = false

func _action(kind: String, payload: Dictionary) -> void:
	var result: Dictionary = controller.request_action(kind, payload)
	print("SHOWCASE_ACTION %s %s %s" % [scene_id, kind, result])
	if not bool(result.get("ok", false)): push_error("Showcase action rejected: " + str(result))

func _button(text: String) -> Button:
	for node in controller.ui.find_children("*", "Button", true, false):
		if node.text == text: return node
	return null

func _label(text: String) -> Label:
	for node in controller.ui.find_children("*", "Label", true, false):
		if node.text == text: return node
	return null

func _button_in_card(text: String, button_text: String) -> Button:
	var label := _label(text)
	if label:
		for node in label.get_parent().find_children("*", "Button", true, false):
			if node.text == button_text: return node
	return null

func _click(button: Button) -> void:
	if not is_instance_valid(button):
		push_error("Showcase could not find requested button in " + scene_id)
		return
	var shown := button.get_global_rect().intersection(controller.ui._scroll.get_global_rect())
	var visible_fraction := shown.get_area() / maxf(1.0, button.get_global_rect().get_area())
	print("SHOWCASE_BUTTON_VISIBLE %s %s fraction=%.3f" % [scene_id, button.text, visible_fraction])
	if visible_fraction < 0.95:
		push_error("Showcase button is outside the visible scroll area: " + button.text)
	highlight.position = button.global_position - Vector2(4, 4)
	highlight.size = button.size + Vector2(8, 8)
	highlight.modulate.a = 1.0
	highlight.visible = true
	button.pressed.emit()
	print("SHOWCASE_CLICK %s %s notice=%s" % [scene_id, button.text, controller.last_message])

func _scroll_to(node: Control) -> void:
	if is_instance_valid(node):
		var scroll: ScrollContainer = controller.ui._scroll
		_scroll_goal = maxi(0, roundi(node.global_position.y - scroll.global_position.y + scroll.scroll_vertical - 70.0))

func _queue_scroll(node: Control) -> void:
	# New pages need layout passes before their global positions are meaningful.
	_pending_scroll = node
	_scroll_wait = 4

func _build_overlay(index: int, count: int) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 120
	add_child(layer)
	var top := ColorRect.new()
	top.color = Color(0.025, 0.06, 0.05, 0.95)
	top.position = Vector2.ZERO
	top.size = Vector2(1600, 40)
	layer.add_child(top)
	title = _text(layer, "%02d / %02d    %s" % [index, count, str(shot.title).to_upper()], Vector2(24, 4), 23, Color("f2d592"))
	var brand := _text(layer, "TROOP  /  ROOTS & ROCKETS", Vector2(1160, 8), 17, Color("b1c9bb"))
	brand.size.x = 416
	brand.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var bottom := ColorRect.new()
	bottom.color = Color(0.025, 0.06, 0.05, 0.95)
	bottom.position = Vector2(0, 858)
	bottom.size = Vector2(1600, 42)
	layer.add_child(bottom)
	caption = _text(layer, str(shot.controls), Vector2(24, 864), 20, Color("e3eddd"))
	caption.size.x = 1535
	detail = _text(layer, str(shot.kicker), Vector2(26, 800), 23, Color("f5e3b5"))
	detail.add_theme_constant_override("outline_size", 7)
	detail.add_theme_color_override("font_outline_color", Color(0.01, 0.03, 0.02, 0.98))
	highlight = Panel.new()
	var outline := StyleBoxFlat.new()
	outline.bg_color = Color(0.98, 0.8, 0.3, 0.12)
	outline.border_color = Color("ffe18a")
	outline.set_border_width_all(3)
	outline.set_corner_radius_all(6)
	highlight.add_theme_stylebox_override("panel", outline)
	highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	highlight.visible = false
	layer.add_child(highlight)
	# UI pages already explain each action. Avoid covering their live notices.
	controller.ui.visibility_changed.connect(func(): detail.visible = not controller.ui.visible)
	detail.visible = not controller.ui.visible
	if scene_id in ["space", "observatory"]:
		detail.text = "ESO / S. Brunier · NASA / GSFC  |  Observation exposure · Telescope camera"

func _text(layer: Node, value: String, at: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.position = at
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	layer.add_child(label)
	return label
