extends Node
## Real-engine society regression. Main starts a disposable offline Frontier.
## Explicitly isolates persistence and exercises physical sites, UI callbacks,
## expedition realm transitions, exact lunar contact and the actual pause menu.

class ErrorRecorder extends Logger:
	var _messages: Array[String] = []
	var _mutex := Mutex.new()

	func _log_error(_function: String, file: String, line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			_script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == Logger.ERROR_TYPE_WARNING:
			return
		_mutex.lock()
		_messages.append("%s:%d %s %s" % [file, line, code, rationale])
		_mutex.unlock()

	func messages() -> Array[String]:
		_mutex.lock()
		var result: Array[String] = _messages.duplicate()
		_mutex.unlock()
		return result

var passed := 0
var total := 0
var _recorder: ErrorRecorder
var _production_digest := ""
var _test_save := ""
var _main: Node
var _controller: FrontierController


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_recorder = ErrorRecorder.new()
	OS.add_logger(_recorder)


func run(main: Node) -> void:
	_main = main
	_controller = main.frontier_controller as FrontierController
	var ready := is_instance_valid(_controller) and _controller.simulation != null \
		and is_instance_valid(_controller.earth_settlement) \
		and is_instance_valid(_controller.moon_settlement) \
		and is_instance_valid(_controller.ui) \
		and is_instance_valid(main.world.local_player)
	_check(ready, "Frontier starts a real player, finite simulation and both physical settlements")
	if not ready:
		await _finish()
		return
	var simulation = _controller.simulation
	var player: MonkeyPlayer = main.world.local_player
	var expedition: ExpeditionManager = main.expedition_manager
	var production_path := ProjectSettings.globalize_path(FrontierController.SAVE_PATH)
	_production_digest = _file_digest(production_path)
	_check(not _controller.persistence_enabled and not main._frontier_load_saved,
		"the integration entry point disables production-career loading and autosaving")
	_test_save = "user://frontier/tests/frontierplay-%d.json" % OS.get_process_id()
	_controller.save_path = _test_save
	_controller.persistence_enabled = false
	_controller.simulation_enabled = false
	player.test_mode = true
	player._invulnerable_t = 1000.0
	player.ti.dir = Vector2.ZERO
	await _physics_frames(50)
	_check(not Net.active and Gen.frontier_world and main.world.frontier == _controller,
		"the town is an offline career integrated into the current procedural world")
	_check(Net.player_realm() == Net.PlayerRealm.EARTH \
		and _controller.current_planet() == "earth" and simulation.state.planet == "earth" \
		and _controller.earth_site.visible and not _controller.moon_site.visible,
		"Earth starts with the authoritative realm, ledger and visible worksite in agreement")
	_check(player.is_on_floor() and absf(player.global_position.y - Gen.height(
		player.global_position.x, player.global_position.z)) < 0.25,
		"the actual player capsule lands on the town terrain", "y=%.3f" % player.global_position.y)
	_check(_citizens_match("earth") and _citizens_match("moon"),
		"every simulated citizen has one physical counterpart on the correct world")
	var interactions: Array = _controller.interactions()
	var interaction_ids: Array[String] = []
	for item: Dictionary in interactions:
		interaction_ids.append(str(item.id))
	_check(interaction_ids.has("earth_market") and interaction_ids.has("oil_rig") \
		and interaction_ids.has("refinery") and interaction_ids.has("gas_station") \
		and interaction_ids.has("airfield") and interaction_ids.has("carrier"),
		"finite trading, oil production and three fuel customers have physical interaction points")
	await _verify_tutorial(player)
	await _verify_earth_grounding()
	await _verify_pages("earth")
	await _verify_refinery_market(player)
	await _verify_citizen_conversation(player)
	await _verify_harvest(player)
	await _verify_vehicle_fuel(player)
	await _verify_constructed_obstruction()
	await _verify_pause()
	_controller.simulation_enabled = false
	var earth_pack: Dictionary = simulation.state.inventories.player_earth.duplicate(true)
	var moon_pack: Dictionary = simulation.state.inventories.player_moon.duplicate(true)
	# Use the production expedition entry used by the existing Moon tests. This
	# changes realm/physics through Net's authoritative travel path, not a ledger edit.
	Net.rocket_state.phase = Net.RocketMissionPhase.MOON_READY
	expedition._apply_authoritative_state(Net.expedition_state_snapshot())
	var travelled := expedition.admin_travel(Net.PlayerRealm.MOON)
	_controller._sync_realm()
	await _physics_frames(120)
	_check(travelled and Net.player_realm() == Net.PlayerRealm.MOON \
		and simulation.state.planet == "moon" and _controller.current_planet() == "moon" \
		and _controller.moon_site.visible and not _controller.earth_site.visible,
		"existing expedition travel switches realm, society ledger and visible settlement together")
	var moon := expedition.moon_world
	_check(player.lunar_world == moon and player.is_on_floor() \
		and player.up_direction.dot(moon.radial_up_at(player.global_position)) > 0.999 \
		and absf(moon.altitude_at(player.global_position)) < 0.25,
		"arrival preserves spherical lunar gravity and real player contact",
		"altitude=%.4f" % moon.altitude_at(player.global_position))
	_check(simulation.state.inventories.player_earth == earth_pack \
		and simulation.state.inventories.player_moon == moon_pack,
		"travel leaves Earth and Moon cargo in their recorded locations")
	await _verify_moon_grounding(moon)
	await _verify_pages("moon")
	_verify_solar_and_sky(moon)
	_controller.set_observation(true)
	_check(moon.lunar_sky.observation_mode and is_equal_approx(float(
		moon.lunar_sky.material.get_shader_parameter("observation_strength")), 1.0),
		"the live observatory control enables photographic exposure and constellation guides")
	var earth_direction := Vector3.ZERO
	for target: Dictionary in _controller.sky_targets():
		if str(target.name) == "Earth":
			earth_direction = target.direction
	_controller.look_at_sky(earth_direction)
	await _physics_frames(12)
	_check(earth_direction.length_squared() > 0.9 \
		and (-player.cam.cam_basis().z).dot(earth_direction) > 0.995 \
		and not _controller.ui.visible,
		"the observatory Earth target aims the real radial player camera at Earth")
	_controller.set_observation(false)
	var remote_before := JSON.stringify(simulation.state)
	var wrong_world: Dictionary = _controller.request_action("harvest", {"plot": "earth_1"})
	_check(not bool(wrong_world.get("ok", false)) and JSON.stringify(simulation.state) == remote_before,
		"manual work cannot reach an Earth plot while the player stands on the Moon")
	await _verify_test_save(simulation)
	_controller.ui.close()
	var returned := expedition.admin_travel(Net.PlayerRealm.EARTH)
	_controller._sync_realm()
	await _physics_frames(3)
	_check(returned and player.lunar_world == null and player.up_direction == Vector3.UP \
		and _controller.earth_site.visible and not _controller.moon_site.visible \
		and simulation.state.planet == "earth",
		"returning to Earth restores ordinary gravity and the Earth society")
	await _finish()


func _citizens_match(planet: String) -> bool:
	var settlement: Node3D = _controller.moon_settlement if planet == "moon" else _controller.earth_settlement
	var expected := 0
	for id in _controller.simulation.state.citizens:
		var citizen: Dictionary = _controller.simulation.state.citizens[id]
		if str(citizen.planet) != planet:
			continue
		expected += 1
		if not settlement.citizens.has(id) or not is_instance_valid(settlement.citizens[id]):
			return false
	return expected > 0 and settlement.citizens.size() == expected


func _verify_earth_grounding() -> void:
	# Terrain collision intentionally sleeps outside the actor's3x3 safety
	# window. Visit the whole farm instead of demanding distant sleeping bodies.
	var player: MonkeyPlayer = _main.world.local_player
	var previous := player.global_position
	player.admin_teleport(Vector3(-39,Gen.height(-39,-30)+0.2,-30))
	await _physics_frames(20)
	var max_error := 0.0
	var hits := 0
	var count := 0
	var exclusions: Array[RID] = []
	_collect_bodies(_controller.earth_settlement, exclusions)
	for root: Node3D in _controller.earth_settlement.plot_roots.values():
		count += 1
		var point := root.global_position
		max_error = maxf(max_error, absf(point.y - Gen.height(point.x, point.z)))
		var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 2.0,
			point - Vector3.UP * 2.0, 1, exclusions)
		var hit := get_world_3d_space().intersect_ray(query)
		if not hit.is_empty() and absf((hit.position as Vector3).y - point.y) < 0.08:
			hits += 1
	_check(count > 0 and max_error < 0.03 and hits == count,
		"visiting the farm activates exact rendered-and-collidable ground beneath all Earth beds",
		"grounded=%d/%d max_height_error=%.4f" % [hits, count, max_error])
	player.admin_teleport(previous)
	await _physics_frames(3)


func _verify_tutorial(player: MonkeyPlayer) -> void:
	var guide: Node = _controller.tutorial
	_check(is_instance_valid(guide) and bool(guide.active) and guide.chapter=="basics" \
		and int(guide.step)==0 and _controller.waypoint.get("id")=="nana" \
		and _controller._waypoint_marker.is_visible_in_tree() and guide._panel.is_visible_in_tree(),
		"the optional first-day guide and its real Nana marker survive initial realm setup")
	if not is_instance_valid(guide): return
	player.admin_teleport(_controller._interaction_position("nana"))
	var opened := _controller.try_interact(player)
	await get_tree().process_frame
	_check(opened and _controller.ui.context.get("id")=="nana" \
		and _controller.ui._heading.text=="Nana" and int(guide.step)==1,
		"meeting the real market keeper through E advances the first tutorial lesson")
	guide.pause()
	_controller.ui.close()
	await get_tree().process_frame


func _verify_pages(planet: String) -> void:
	for page: String in FrontierUI.PAGES:
		var errors_before := _recorder.messages().size()
		_controller.ui.open({})
		_controller.ui.select_page(page)
		await get_tree().process_frame
		await get_tree().process_frame
		var ui := _controller.ui as FrontierUI
		var panel := ui._panel.get_global_rect()
		var viewport := get_viewport().get_visible_rect()
		_check(ui.visible and ui.page == page and ui.context.is_empty() and ui._heading.text == ("TRAVEL JOURNAL" if page == "Journal" else page.to_upper()) \
			and ui._body.get_child_count() > 0 and ui._nav[page].disabled \
			and viewport.grow(1.0).encloses(panel) \
			and _recorder.messages().size() == errors_before,
			"%s %s page fits the viewport and refreshes without engine errors" % [planet.capitalize(), page])
	_controller.ui.close()
	await get_tree().process_frame


func _verify_citizen_conversation(player: MonkeyPlayer) -> void:
	var citizen_position := _controller._interaction_position("ookbar")
	player.admin_teleport(citizen_position)
	var opened := _controller.try_interact(player)
	await get_tree().process_frame
	var conversation_text := _control_text(_controller.ui._body)
	_check(opened and _controller.ui.page == "Interaction" \
		and str(_controller.selected_interaction.get("id", "")) == "ookbar" \
		and _controller.ui._heading.text == "Ookbar" \
		and not conversation_text.contains("Petra") \
		and conversation_text.contains("Right now:") \
		and conversation_text.contains("Hunger") \
		and conversation_text.contains("A welcome for the neighborhood"),
		"E at Ookbar opens his live work, needs and personal quest conversation")
	var accept := _button_with_text(_controller.ui._body, "Accept request")
	var state: Dictionary = _controller.simulation.state
	var treasury_before := int(state.accounts.treasury)
	var reward := int(state.quests.first_harvest.reward)
	var had_accept := accept != null
	if accept:
		accept.pressed.emit()
	await get_tree().process_frame
	_check(had_accept and str(state.quests.first_harvest.status) == "active" \
		and int(state.accounts.treasury) == treasury_before - reward \
		and int(state.accounts.escrow_first_harvest) == reward,
		"Ookbar's actual Accept request button funds the correct contract escrow")
	_controller.ui.close()


func _verify_refinery_market(player: MonkeyPlayer) -> void:
	player.admin_teleport(_controller._interaction_position("refinery"))
	var opened := _controller.try_interact(player)
	await get_tree().process_frame
	_check(opened and _controller.ui.context.get("id") == "refinery" \
		and _controller.ui.page == "Interaction" \
		and _control_text(_controller.ui._body).contains("Crude Oil"),
		"the refinery desk exposes real petroleum stock needed for fuel contracts")
	var simulation = _controller.simulation
	var amount := 5
	_controller.ui._quantity = amount
	var source_before := int(simulation.state.inventories.refinery.crude_oil)
	var pack_before := int(simulation.state.inventories.player_earth.get("crude_oil", 0))
	var cash_before := int(simulation.state.accounts.player)
	var quote: int = simulation.quote("refinery", "crude_oil", amount, true)
	var buy := _button_for_label(_controller.ui._body, "Crude Oil", "Buy")
	if buy: buy.pressed.emit()
	_check(buy != null and int(simulation.state.inventories.refinery.crude_oil) == source_before - amount \
		and int(simulation.state.inventories.player_earth.get("crude_oil", 0)) == pack_before + amount \
		and int(simulation.state.accounts.player) == cash_before - quote,
		"a nearby refinery purchase button moves finite crude and charges the quoted price")
	_controller.ui.close()


func _control_text(node: Node) -> String:
	var result := str(node.get("text")) if node is Label or node is Button else ""
	for child: Node in node.get_children():
		result += "\n" + _control_text(child)
	return result


func _button_with_text(node: Node, caption: String) -> Button:
	if node is Button and (node as Button).text == caption:
		return node as Button
	for child: Node in node.get_children():
		var found := _button_with_text(child, caption)
		if found:
			return found
	return null


func _button_for_label(node: Node, label: String, caption: String) -> Button:
	# Find the item's own panel, so alphabetic stock changes never buy a
	# different commodity while accidentally preserving total cash assertions.
	for child: Node in node.get_children():
		var found := _button_for_label(child, label, caption)
		if found: return found
	if node is PanelContainer and _has_label(node,label):
		return _button_with_text(node,caption)
	return null


func _has_label(node: Node, caption: String) -> bool:
	if node is Label and node.text == caption: return true
	for child: Node in node.get_children():
		if _has_label(child,caption): return true
	return false


func _verify_harvest(player: MonkeyPlayer) -> void:
	var simulation = _controller.simulation
	var plot_id := "earth_1"
	var plot: Dictionary = simulation.state.plots[plot_id]
	# A ripe fixture isolates the physical command path from growth timing,
	# which is covered by frontiertest's conservation/production tests.
	plot.crop = "banana"
	plot.growth = 1.0
	plot.health = 1.0
	var stock_before := int(simulation.state.inventories.player_earth.get("banana", 0))
	player.admin_teleport(Vector3(0, Gen.height(0, 0) + 0.2, 0))
	var before := JSON.stringify(simulation.state)
	var denied: Dictionary = _controller.request_action("harvest", {"plot": plot_id})
	_check(not bool(denied.get("ok", false)) and JSON.stringify(simulation.state) == before,
		"out-of-range harvesting is rejected without changing any goods or plot state")
	var interaction: Dictionary = {}
	for item: Dictionary in _controller.interactions():
		if str(item.id) == plot_id:
			interaction = item
	if interaction.is_empty():
		_check(false, "the ready crop has a physical service point")
		return
	player.admin_teleport(interaction.position)
	var opened := _controller.try_interact(player)
	_check(opened and _controller.ui.visible and _controller.ui.page == "Interaction" \
		and _controller.ui.context.get("id") == plot_id \
		and str(_controller.selected_interaction.get("id", "")) == plot_id,
		"E at an actual crop bed opens its farming controls")
	var harvest_button := _button_with_text(_controller.ui._body, "Harvest")
	var had_harvest := harvest_button != null
	if harvest_button: harvest_button.pressed.emit()
	var stock_after := int(simulation.state.inventories.player_earth.get("banana", 0))
	_controller.earth_settlement._refresh_state()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(had_harvest and stock_after > stock_before \
		and str(simulation.state.plots[plot_id].crop).is_empty() \
		and (_controller.earth_settlement.plot_roots[plot_id] as Node3D).get_child_count() == 0,
		"nearby harvesting transfers produce to the ledger and visibly empties the crop bed")
	var duplicate: Dictionary = _controller.request_action("harvest", {"plot": plot_id})
	_check(not bool(duplicate.get("ok", false)) \
		and int(simulation.state.inventories.player_earth.get("banana", 0)) == stock_after,
		"repeated input cannot duplicate the harvested crop")
	_controller.ui.close()
	await get_tree().process_frame


func _verify_vehicle_fuel(player: MonkeyPlayer) -> void:
	var simulation = _controller.simulation
	var station := _controller._interaction_position("gas_station")
	var apron := station + Vector3(7, 0, 5)
	var jeep: Vehicle = _main.world.spawn_vehicle(Vehicle.Kind.JEEP,
		"v:debug#frontier_fuel_jeep", apron, 0.0)
	# Let the production controller discover the vehicle on its normal refresh.
	player.admin_teleport(apron + Vector3(2.0, 0.2, 0.0))
	await _physics_frames(35)
	_check(jeep.frontier_simulation == simulation \
		and simulation.state.vehicle_fuel.has(jeep.vid) \
		and _controller.nearby_fuel_vehicles().has(jeep),
		"new world vehicles automatically receive a persistent tank and appear at nearby depots")
	if jeep.frontier_simulation == null or not simulation.state.vehicle_fuel.has(jeep.vid):
		_remove_test_vehicle(jeep)
		return
	var tank: Dictionary = simulation.state.vehicle_fuel[jeep.vid]
	var provisioned := float(tank.fuel_l)
	jeep.configure_frontier_fuel(simulation)
	_check(provisioned > 0.0 and float(tank.fuel_l) == provisioned \
		and jeep.fuel_readout().begins_with("FUEL "),
		"reconnecting a vehicle preserves its finite fuel instead of granting another starter tank")
	simulation.consume_vehicle_fuel(jeep.vid, float(tank.capacity_l))
	player.enter_vehicle(jeep)
	await _physics_frames(5)
	_check(player.vehicle == jeep and jeep.driver == player \
		and _main.hud.vehicle_extra_label.text.contains("REFUEL AT A DEPOT"),
		"mounting an empty jeep uses the real vehicle controls and displays the fuel warning")
	player.ti.dir = Vector2(0, -1)
	var empty_start := jeep.global_position
	await _physics_frames(60)
	var max_torque := 0.0
	for wheel: VehicleWheel in jeep.wheels:
		max_torque = maxf(max_torque, absf(wheel.drive_torque))
	var empty_distance := Vector2(jeep.global_position.x - empty_start.x,
		jeep.global_position.z - empty_start.z).length()
	_check(not jeep.has_drive_fuel() and max_torque < 0.000001 \
		and empty_distance < 0.35 and absf(jeep.forward_speed()) < 0.35,
		"holding drive in an empty jeep delivers no wheel torque or powered movement",
		"distance=%.3f speed=%.3f torque=%.3f" % [empty_distance,jeep.forward_speed(),max_torque])
	player.ti.dir = Vector2.ZERO
	player.exit_vehicle()
	jeep.settle_at(apron, 0.0)
	await _physics_frames(3)
	var request := {"vehicle":jeep.vid,"facility":"gas_station","quantity":5}
	player.admin_teleport(station + Vector3(50, 0.2, 0))
	var before := JSON.stringify(simulation.state)
	var denied: Dictionary = _controller.request_action("refuel", request)
	_check(not bool(denied.get("ok", false)) and JSON.stringify(simulation.state) == before,
		"depot refueling rejects a distant player without changing stock, money or fuel")
	player.admin_teleport(apron + Vector3(2, 0.2, 0))
	jeep.global_position += Vector3(50, 0, 0)
	before = JSON.stringify(simulation.state)
	denied = _controller.request_action("refuel", request)
	_check(not bool(denied.get("ok", false)) and JSON.stringify(simulation.state) == before,
		"depot refueling rejects a vehicle outside its loading bay")
	jeep.settle_at(apron, 0.0)
	jeep.linear_velocity = Vector3(0, 0, 2)
	before = JSON.stringify(simulation.state)
	denied = _controller.request_action("refuel", request)
	_check(not bool(denied.get("ok", false)) and JSON.stringify(simulation.state) == before,
		"a moving vehicle cannot purchase a fuel delivery")
	jeep.linear_velocity = Vector3.ZERO
	jeep.angular_velocity = Vector3.ZERO
	var stock_before := int(simulation.stock("gas_station", "gasoline"))
	var cash_before := int(simulation.state.accounts.player)
	var owner: String = simulation.state.locations.gas_station.owner
	var owner_before := int(simulation.state.accounts[owner])
	var cost := int(simulation.quote("gas_station", "gasoline", 5, true))
	var purchased: Dictionary = _controller.request_action("refuel", request)
	_check(bool(purchased.get("ok", false)) and is_equal_approx(float(tank.fuel_l), 5.0) \
		and int(simulation.stock("gas_station", "gasoline")) == stock_before - 5 \
		and int(simulation.state.accounts.player) == cash_before - cost \
		and int(simulation.state.accounts[owner]) == owner_before + cost,
		"a parked depot purchase transfers real gasoline into the tank and exact credits to its owner")
	player.enter_vehicle(jeep)
	player.ti.dir = Vector2(0, -1)
	var drive_start := jeep.global_position
	var fuel_before := float(tank.fuel_l)
	await _physics_frames(60)
	var drive_distance := Vector2(jeep.global_position.x - drive_start.x,
		jeep.global_position.z - drive_start.z).length()
	_check(player.vehicle == jeep and drive_distance > 0.5 and jeep.forward_speed() > 0.5 \
		and float(tank.fuel_l) < fuel_before and float(tank.fuel_l) > 0.0 \
		and _main.hud.vehicle_extra_label.text.contains("FUEL "),
		"paid fuel restores actual jeep propulsion and burns down while driving",
		"distance=%.3f speed=%.3f used=%.4fL" % [drive_distance,jeep.forward_speed(),fuel_before-float(tank.fuel_l)])
	player.ti.dir = Vector2.ZERO
	jeep.linear_velocity = Vector3.ZERO
	jeep.angular_velocity = Vector3.ZERO
	player.exit_vehicle()
	_remove_test_vehicle(jeep)
	# Subclass engines apply their own forces, so verify their actual rigid-body
	# response too. Suspend gravity and ground contact to isolate propulsion from
	# lift, waves and rolling resistance; keep the real physics callbacks active.
	await _verify_propulsion_cutoff(Vehicle.Kind.BOAT, "airboat")
	await _verify_propulsion_cutoff(Vehicle.Kind.JET, "jet")
	player.admin_teleport(Vector3(0, Gen.height(0, 0) + 0.2, 0))
	await _physics_frames(5)


func _verify_propulsion_cutoff(kind: int, label: String) -> void:
	var vehicle: Vehicle = _main.world.spawn_vehicle(kind,
		"v:debug#frontier_fuel_" + label, Vector3(-85, 3.25, 70), 0.0)
	vehicle.configure_frontier_fuel(_controller.simulation)
	vehicle.global_position = Vector3(-85, 70, 70)
	vehicle.global_basis = Basis.IDENTITY
	vehicle.gravity_scale = 0.0
	vehicle.lock_rotation = true
	vehicle.collision_layer = 0
	vehicle.collision_mask = 0
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	var operator := Node3D.new()
	add_child(operator)
	vehicle.driver = operator
	vehicle.sleeping = false
	vehicle.set_inputs(1.0, 0.0, 0.0, false, true)
	vehicle.set("spool", 1.0)
	if kind == Vehicle.Kind.JET:
		vehicle.set("throttle_setpoint", 1.0)
	var tank: Dictionary = _controller.simulation.state.vehicle_fuel[vehicle.vid]
	var fuel_before := float(tank.fuel_l)
	await _physics_frames(20)
	_check(vehicle.forward_speed() > 0.35 and float(tank.fuel_l) < fuel_before,
		"%s propulsion produces physical acceleration and consumes its connected tank" % label,
		"speed=%.3f used=%.4fL" % [vehicle.forward_speed(),fuel_before-float(tank.fuel_l)])
	_controller.simulation.consume_vehicle_fuel(vehicle.vid, float(tank.capacity_l))
	# Flush any force queued in the preceding fueled physics frame before
	# comparing motion from a known rest state with the empty tank.
	await _physics_frames(2)
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	vehicle._prev_velocity = Vector3.ZERO
	vehicle.set("spool", 1.0)
	await _physics_frames(20)
	var burner_off := kind != Vehicle.Kind.JET or not bool(vehicle.get("afterburner"))
	_check(not vehicle.has_drive_fuel() and absf(vehicle.forward_speed()) < 0.05 and burner_off,
		"%s loses physical thrust immediately with empty fuel despite residual turbine spin" % label,
		"speed=%.5f spool=%.3f" % [vehicle.forward_speed(),float(vehicle.get("spool"))])
	vehicle.driver = null
	operator.queue_free()
	_remove_test_vehicle(vehicle)
	await _physics_frames(2)


func _remove_test_vehicle(vehicle: Vehicle) -> void:
	_main.world.vehicles.erase(vehicle.vid)
	vehicle.queue_free()


func _verify_constructed_obstruction() -> void:
	var simulation = _controller.simulation
	var original: Dictionary = simulation.state.duplicate(true)
	var accumulator := float(simulation._accumulator)
	var site: FrontierSite = _controller.earth_site
	var traffic: FrontierTraffic = site.get_meta("frontier_traffic") if site.has_meta("frontier_traffic") else null
	_check(is_instance_valid(traffic) and traffic.authority and traffic.vehicle_for("diesel") != null,
		"the offline town owns a real authoritative delivery vehicle")
	if not is_instance_valid(traffic) or traffic.vehicle_for("diesel") == null:
		return
	var contexts: Dictionary = traffic.drivers.duplicate(true)
	var obstacles: Array = traffic._external_obstacles.duplicate(true)
	var saved := {}
	for id in traffic.vehicles:
		var body: Vehicle = traffic.vehicles[id]
		saved[id] = {"transform":body.global_transform,"velocity":body.linear_velocity,
			"angular":body.angular_velocity,"freeze":body.freeze,"layer":body.collision_layer,
			"mask":body.collision_mask,"gear":body.engine.gear}
		if id != "diesel":
			body.freeze=true
			body.collision_layer=0
			body.collision_mask=0
	for citizen: Dictionary in simulation.state.citizens.values():
		citizen.enabled=false
		citizen._job={}
	var worker: Dictionary = simulation.state.citizens.diesel
	worker.enabled=true
	worker.cooldown=0.0
	worker.carrying={}
	var loaded: Dictionary = simulation._load_worker(worker,{
		"from":"gas_station","to":"refinery","item":"gasoline","quantity":3},false)
	simulation._set_job(worker,"unload","refinery","Unloading a finite physical delivery",{},2.0)
	var car: Vehicle = traffic.vehicle_for("diesel")
	car.freeze=false
	car.settle_at(site.surface_point(60,41),PI*0.5)
	car.engine.gear=1
	traffic.drivers.diesel.epoch=-1
	traffic.drivers.diesel.stopped=0.0
	traffic.drivers.diesel.fuel_stop=false
	traffic.drivers.diesel.previous=car.global_position
	traffic._obstacle_cache.clear()
	traffic.set_obstacles([])
	var obstacle := StaticBody3D.new()
	obstacle.name="ConstructedRoadBarrierTest"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size=Vector3(0.7,3.0,14.0)
	shape.shape=box
	obstacle.add_child(shape)
	_main.world.add_child(obstacle)
	obstacle.global_position=site.surface_point(78,35,1.5)
	var cargo_before: Dictionary = worker.carrying.duplicate(true)
	var work_before := float(worker.work_remaining)
	var stock_before: int = simulation.stock("refinery","gasoline")
	var completed_before := int(worker.completed)
	for frame in range(600):
		await get_tree().physics_frame
		simulation.tick(1.0/float(Engine.physics_ticks_per_second))
	var held := car.global_position
	for frame in range(120):
		await get_tree().physics_frame
		simulation.tick(1.0/float(Engine.physics_ticks_per_second))
	_check(bool(loaded.get("ok",false)) and car.speed()<0.5 and car.global_position.distance_to(held)<0.15 \
		and worker.carrying==cargo_before and float(worker.work_remaining)==work_before \
		and int(worker.completed)==completed_before and simulation.stock("refinery","gasoline")==stock_before,
		"a real constructed wall stops the physical tanker and preserves its cargo, work timer and delivery ledger",
		"position=%s speed=%.3f blocker=%s"%[site.to_local(car.global_position),car.speed(),traffic.drivers.diesel.blocker])
	obstacle.queue_free()
	await _physics_frames(2)
	traffic._obstacle_cache.clear()
	var resumed := false
	for frame in range(3000):
		await get_tree().physics_frame
		simulation.tick(1.0/float(Engine.physics_ticks_per_second))
		resumed=resumed or car.global_position.distance_to(held)>1.0
		if int(worker.completed)>completed_before: break
	_check(resumed and int(worker.completed)==completed_before+1 and worker.carrying.is_empty() \
		and simulation.stock("refinery","gasoline")==stock_before+3 and car.speed()<0.5,
		"removing the wall lets the same vehicle drive, stop and complete its finite delivery",
		"position=%s speed=%.3f remaining=%.2f blocker=%s"%[site.to_local(car.global_position),car.speed(),worker.work_remaining,traffic.drivers.diesel.blocker])
	simulation.state=original
	simulation._accumulator=accumulator
	traffic.drivers=contexts
	traffic.set_obstacles(obstacles)
	traffic._obstacle_cache.clear()
	for id in saved:
		var body: Vehicle=traffic.vehicles[id]
		body.global_transform=saved[id].transform
		body.linear_velocity=saved[id].velocity
		body.angular_velocity=saved[id].angular
		body.freeze=saved[id].freeze
		body.collision_layer=saved[id].layer
		body.collision_mask=saved[id].mask
		body.engine.gear=saved[id].gear
		body.reset_physics_interpolation()
	_controller.earth_settlement._refresh_state()
	_controller.moon_settlement._refresh_state()
	await _physics_frames(2)

func _verify_pause() -> void:
	_controller.simulation_enabled = true
	var before := float(_controller.simulation.state.time)
	await get_tree().create_timer(1.25, true, false, true).timeout
	_check(float(_controller.simulation.state.time) > before,
		"the live controller advances civilian time during active play")
	_main._open_pause_menu()
	var paused_time := float(_controller.simulation.state.time)
	var paused_state := JSON.stringify(_controller.simulation.state)
	await get_tree().create_timer(1.25, true, false, true).timeout
	_check(get_tree().paused and _controller.process_mode == Node.PROCESS_MODE_PAUSABLE \
		and JSON.stringify(_controller.simulation.state) == paused_state,
		"the real solo pause menu freezes production, travel, wages and civilian time")
	_main._close_pause_menu(false)
	await get_tree().create_timer(1.25, true, false, true).timeout
	var advanced := float(_controller.simulation.state.time) - paused_time
	_check(not get_tree().paused and advanced >= 1.0 and advanced <= 2.0,
		"resuming continues normal work without simulating paused wall-clock time",
		"advanced=%.1fs" % advanced)


func _verify_moon_grounding(moon: MoonWorld) -> void:
	var exclusions: Array[RID] = []
	_collect_bodies(moon, exclusions, moon.terrain_body)
	var points: Array[Vector2] = [Vector2.ZERO, Vector2(-20,-20), Vector2(28,-20),
		Vector2(-55,-35), Vector2(28,20), Vector2(-15,15)]
	var max_error := 0.0
	var grounded := 0
	for coordinates in points:
		var point := _controller.moon_site.surface_point(coordinates.x, coordinates.y)
		var up := moon.radial_up_at(point)
		var query := PhysicsRayQueryParameters3D.create(point+up*5.0, point-up*5.0, 1, exclusions)
		var hit := get_world_3d_space().intersect_ray(query)
		if hit.is_empty() or hit.collider != moon.terrain_body or int(hit.shape) != 0:
			continue
		var error := point.distance_to(hit.position)
		max_error = maxf(max_error, error)
		if error < 0.12:
			grounded += 1
	_check(grounded == points.size(),
		"lunar worksite foundations match the exact production sphere collider",
		"grounded=%d/%d max_contact_error=%.4fm" % [grounded, points.size(), max_error])
	var crop_error := 0.0
	var cropped := 0
	for root: Node3D in _controller.moon_settlement.plot_roots.values():
		crop_error = maxf(crop_error, absf(moon.altitude_at(root.global_position)))
		cropped += 1
	_check(cropped > 0 and crop_error < 0.12,
		"lunar crop roots follow the actual curved ground rather than a flat pad",
		"plots=%d max_altitude_error=%.4fm" % [cropped, crop_error])


func _verify_solar_and_sky(moon: MoonWorld) -> void:
	_controller._update_sun()
	_controller.moon_settlement._refresh_state()
	var state: Dictionary = _controller.simulation.state
	var phase := float(state.lunar_phase)*TAU
	var horizontal := Vector2(0.67, 0.74).normalized()
	var expected := _controller.moon_site.global_basis * Vector3(-cos(phase)*horizontal.x, sin(phase), -cos(phase)*horizontal.y)
	var sunlight := moon.get_node("HarshLunarSunlight") as DirectionalLight3D
	var material := moon.terrain_mesh.material_override as ShaderMaterial
	_check(absf(float(state.solar_illumination)-maxf(0.0,sin(phase))) < 0.001 \
		and absf(expected.dot(_controller.moon_site.global_basis.y)-sin(phase)) < 0.00001 \
		and moon.lunar_sun_direction().is_equal_approx(expected) \
		and sunlight.basis.z.is_equal_approx(expected) \
		and (material.get_shader_parameter("lunar_sun_direction") as Vector3).is_equal_approx(expected) \
		and (moon.lunar_sky.material.get_shader_parameter("sun_direction") as Vector3).is_equal_approx(expected),
		"solar economy, visible Sun, terrain shading and Earth phase share the live lunar clock")
	var visible_panels := 0
	for panel: Node3D in _controller.moon_settlement._solar_panels:
		if panel.visible:
			visible_panels += 1
	_check(visible_panels == int(state.facilities.solar_array.panels) \
		and float(state.facilities.solar_array.power_kw) > 0.0 \
		and not _controller.moon_settlement._solar_label.text.is_empty(),
		"physical solar panels and their live utility label match operating generation")


func _verify_test_save(simulation: RefCounted) -> void:
	_controller.persistence_enabled = true
	var saved := _controller.save_progress()
	_controller.persistence_enabled = false
	var path := ProjectSettings.globalize_path(_test_save)
	_check(saved and FileAccess.file_exists(path) \
		and _controller.save_path != FrontierController.SAVE_PATH,
		"controller persistence writes only to this run's isolated test career")
	var loaded = load("res://scripts/frontier_sim.gd").new()
	var restored: bool = loaded.load_game(_test_save)
	# JSON parses numeric values as floats, while fresh inventory counts are
	# ints. Dictionary equality distinguishes these types even when 1 == 1.0.
	var same_goods := restored and _same_json_values(loaded.state.inventories, simulation.state.inventories)
	var same_accounts := restored and _same_json_values(loaded.state.accounts, simulation.state.accounts)
	_check(restored and loaded.state.planet == simulation.state.planet \
		and same_goods and same_accounts,
		"saved controller state restores the exact realm, goods and account balances",
		"loaded=%s goods=%s accounts=%s" % [restored, same_goods, same_accounts])
	await get_tree().process_frame


func _same_json_values(a: Variant, b: Variant) -> bool:
	return JSON.parse_string(JSON.stringify(a)) == JSON.parse_string(JSON.stringify(b))


func get_world_3d_space() -> PhysicsDirectSpaceState3D:
	return _main.world.get_world_3d().direct_space_state


func _collect_bodies(node: Node, exclusions: Array[RID], keep: CollisionObject3D = null) -> void:
	if node is CollisionObject3D and node != keep:
		exclusions.append((node as CollisionObject3D).get_rid())
	for child in node.get_children():
		_collect_bodies(child, exclusions, keep)


func _physics_frames(count: int) -> void:
	for frame in range(count):
		await get_tree().physics_frame


func _file_digest(path: String) -> String:
	return FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "absent"


func _finish() -> void:
	if is_instance_valid(_controller):
		_controller.persistence_enabled = false
	if get_tree().paused:
		_main._close_pause_menu(false)
	if is_instance_valid(_main) and is_instance_valid(_main.world):
		_main._return_to_main_menu()
	for frame in range(5):
		await get_tree().process_frame
	if not _production_digest.is_empty():
		_check(_file_digest(ProjectSettings.globalize_path(FrontierController.SAVE_PATH)) == _production_digest,
			"the existing production career remains byte-for-byte untouched")
	if not _test_save.is_empty():
		for suffix in ["", ".tmp", ".bak"]:
			var path := ProjectSettings.globalize_path(_test_save + suffix)
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
	var errors := _recorder.messages()
	_check(errors.is_empty(), "the complete gameplay/UI/realm lifecycle logs no engine or script errors",
		" | ".join(errors.slice(0,5)))
	print("FRONTIERPLAYTEST %d/%d %s" % [passed,total,"PASS" if passed==total else "FAIL"])
	OS.remove_logger(_recorder)
	get_tree().quit(0 if passed==total else 1)


func _check(ok: bool, label: String, detail := "") -> void:
	total += 1
	if ok:
		passed += 1
	print("[%s] %s %s" % ["PASS" if ok else "FAIL",label,detail])
