extends Node
## Verified key bindings and gameplay dispatch through Player -> World -> FrontierController, with a
## disposable career. Main registers this alongside frontierplaytest.
## godot --headless --path . --fixed-fps 60 --quit-after 1800 -- frontierinteractiontest
var total := 0
var passed := 0
var main: Node
var controller: FrontierController
var player: MonkeyPlayer

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func check(ok: bool, description: String) -> void:
	total += 1
	if ok: passed += 1
	print("FRONTIERINTERACTION %s %s" % ["PASS" if ok else "FAIL", description])

func run(owner: Node) -> void:
	main = owner
	controller = main.frontier_controller
	player = main.world.local_player
	controller.persistence_enabled = false
	controller.simulation_enabled = false
	check(not Net.active and not main._frontier_load_saved and controller.tutorial.path.is_empty(),
		"fixture uses a disposable offline career with no tutorial or economy writes")
	var e := _key(KEY_E, true)
	var b := _key(KEY_B, true)
	check(InputMap.event_is_action(e,"grab") and not InputMap.event_is_action(e,"society")
		and InputMap.event_is_action(b,"society") and not InputMap.event_is_action(b,"grab"),
		"physical E is contextual interaction and physical B is the journal")
	print("FRONTIERINTERACTION_BINDINGS saved_grab=%s canonical_E=%s canonical_B=%s" %
		[Settings.binding_text(&"grab"),InputMap.event_is_action(e,"grab"),InputMap.event_is_action(b,"society")])
	# Headless DisplayServer cannot capture a cursor, so combine the real InputMap
	# assertion above with Player's standard deterministic input seam. This still
	# traverses Player._physics_process -> World -> FrontierController; it never
	# calls UI.open or Controller.try_interact directly.
	player.test_mode = true
	player._invulnerable_t = 1000.0
	player.ti.dir = Vector2.ZERO
	check(player.test_mode and not player.ti.interact_just,
		"fixture uses Player's deterministic key-input seam in the headless DisplayServer")
	await _frames(25)
	var nana: Node3D = controller.earth_settlement.citizens.get("nana")
	check(is_instance_valid(nana),"actual settlement has Nana's physical citizen")
	if not is_instance_valid(nana):
		await _finish()
		return
	var market: Dictionary = {}
	for item: Dictionary in controller.interactions():
		if item.get("id") == "earth_market": market = item
	check(not market.is_empty(),"actual settlement exposes the market desk")
	if market.is_empty():
		await _finish()
		return
	# These are ordinary standing approaches, not the prior test's teleport
	# onto the NPC's elevated interaction anchor (which hid the desk tie).
	var approaches := [Vector2(0,2.5),Vector2(1.6,2.2),Vector2(-1.6,2.2)]
	var initial_bag: Dictionary = controller.simulation.state.inventories.player_earth.duplicate(true)
	var initial_cash: int = controller.simulation.state.accounts.player
	for index in range(approaches.size()):
		controller.ui.close()
		var offset: Vector2 = approaches[index]
		var at := nana.global_position + Vector3(offset.x,0,offset.y)
		at.y = Gen.height(at.x,at.z)+0.15
		player.admin_teleport(at)
		player.cam.set_view_mode(CameraRig.ViewMode.FIRST_PERSON)
		player.cam._set_look_direction((nana.global_position+Vector3.UP*1.2-(at+Vector3.UP*1.16)).normalized())
		player.cam.snap_to_target()
		await _frames(8)
		controller._refresh_overlays()
		var selected: Dictionary = controller.nearest_interaction()
		print("FRONTIERINTERACTION_APPROACH index=%d nearest=%s prompt=%s" %
			[index,str(selected.get("id","")),controller._prompt.text])
		check(selected.get("id","")=="nana" and controller._prompt.text.contains("Talk to Nana"),
			"approach %d offers the person and names Nana in the E prompt" % index)
		check(_visible_citizen_labels()==["nana"],
			"approach %d shows only Nana's focused nameplate" % index)
		await _tap(KEY_E)
		check(controller.ui.visible and controller.ui.page=="Interaction"
			and controller.ui.context.get("id","")=="nana" and controller.ui._heading.text=="Nana",
			"gameplay E action reaches Player, World, and Nana's conversation from approach %d" % index)
		check(_visible_citizen_labels().is_empty(),
			"open conversation hides nearby resident nameplates")
		check(not _visible_button(controller.ui,"My journal")
			and _text(controller.ui._body).contains("My trading desk")
			and not _visible_button(controller.ui,"Use " + str(market.label)),
			"Nana's panel exposes one trading desk without a duplicate market link or journal shortcut")
		await _tap(KEY_E)
		check(controller.ui.visible and controller.ui.context.get("id","")=="nana"
			and controller.ui.page=="Interaction",
			"a repeated gameplay E action cannot replace the open conversation")
		await _tap(KEY_B)
		check(not controller.ui.visible,"physical B closes Nana's menu")
	check(controller.tutorial.step==1,"real Nana interaction advances Meet Nana exactly once")
	controller._refresh_overlays()
	# Explicitly target Nana again to test arrival visibility independently of
	# the tutorial advancing its next objective to the physical market desk.
	controller.waypoint=nana.interaction()
	controller._refresh_overlays()
	check(not controller._waypoint_marker.visible,
		"arrived NPC marker yields to the resident label and interaction prompt")
	check(not nana._name_label.text.contains("\n"),
		"nearby citizen name and job occupy a single compact label")
	await _tap(KEY_B)
	check(controller.ui.visible and controller.ui.page=="Journal"
		and controller.ui.context.is_empty() and controller.ui._heading.text=="TRAVEL JOURNAL",
		"physical B from gameplay opens the distinct personal journal")
	await _tap(KEY_E)
	check(controller.ui.visible and controller.ui.page=="Journal" and controller.ui.context.is_empty(),
		"gameplay E action while the journal is open does not open a background conversation")
	await _tap(KEY_B)
	var remote := nana.global_position+Vector3(0,0,12)
	remote.y=Gen.height(remote.x,remote.z)+0.15
	player.admin_teleport(remote)
	await _frames(5)
	await _tap(KEY_E)
	check(not controller.ui.visible or controller.ui.context.get("id","")!="nana",
		"E cannot talk to Nana beyond interaction range")
	check(controller.simulation.state.inventories.player_earth==initial_bag
		and controller.simulation.state.accounts.player==initial_cash,
		"conversation, tutorial, and journal inputs never transact or reset player funds")
	await _physical_entry_regression(nana)
	await _market_fallback(nana,market)
	await _finish()


func _physical_entry_regression(nana: Node3D) -> void:
	var world: World = main.world
	var manager: ExpeditionManager = world.expedition_manager
	var saved_nana_position := nana.global_position
	var saved_model_position: Array = controller.simulation.state.citizens.nana.position.duplicate()
	var vehicle_names := ["motorcycle", "jeep", "airboat", "jet"]
	for kind in [Vehicle.Kind.BIKE, Vehicle.Kind.JEEP,
			Vehicle.Kind.BOAT, Vehicle.Kind.JET]:
		controller.ui.close()
		var id := "interaction-entry-%s" % vehicle_names[kind]
		var spawn := saved_nana_position + Vector3(0.0, 0.0, -0.7)
		var ride := world.spawn_vehicle(kind, id, spawn, 0.0)
		ride.freeze = true
		await _frames(2)
		var entry := ride.interaction_position()
		var approach := entry + Vector3(1.2, 0.0, 0.0)
		approach.y = Gen.height(approach.x, approach.z) + 0.15
		player.admin_teleport(approach)
		# Put a real social target inside the same interaction radius. The old
		# dispatch order opened Nana and made every advertised vehicle inert.
		nana.global_position = Vector3(approach.x, Gen.height(approach.x,
			approach.z), approach.z + 0.8)
		controller.simulation.state.citizens.nana.position = [
			nana.global_position.x, nana.global_position.z]
		player.supply_notice_remaining = 0.0
		await _frames(3)
		var social := controller.nearest_interaction()
		var physical := world.nearby_physical_interaction(player)
		controller._refresh_overlays()
		manager._update_proximity_prompt()
		main.hud._process(0.0)
		check(social.get("id", "") == "nana"
			and physical.get("kind", "") == "vehicle"
			and physical.get("target") == ride
			and world.nearby_vehicle(player) == ride,
			"%s uses its actual seat entrance even beside an eligible NPC" \
				% vehicle_names[kind])
		check(not controller._prompt.visible and not manager._mission_panel.visible
			and main.hud.hint.text.contains(ride.display_name()),
			"%s HUD and overlays advertise only the physical E target" \
				% vehicle_names[kind])
		await _tap(KEY_E)
		check(player.vehicle == ride and ride.driver == player
			and not controller.ui.visible,
			"one gameplay E tap boards the %s without opening Nana's menu" \
				% vehicle_names[kind])
		player.exit_vehicle(false)
		world.vehicles.erase(id)
		ride.queue_free()
		await _frames(2)

	# Manager presentation, local Player dispatch and server validation all use
	# the same fitted Earth transform, including its terrain-following basis.
	check(manager.rocket.earth_launch_transform.is_equal_approx(
		Net._earth_rocket_transform()),
		"rendered Earth rocket and authoritative hatch share one grounded transform")
	controller.ui.close()
	var hatch := manager.rocket.boarding_global_position()
	var hatch_approach := hatch + manager.rocket.global_basis.x * 1.1
	player.admin_teleport(hatch_approach)
	nana.global_position = hatch + manager.rocket.global_basis.x * 1.6
	controller.simulation.state.citizens.nana.position = [
		nana.global_position.x, nana.global_position.z]
	await _frames(3)
	var rocket_target := world.nearby_physical_interaction(player)
	controller._refresh_overlays()
	manager._update_proximity_prompt()
	check(controller.nearest_interaction().get("id", "") == "nana"
		and rocket_target.get("kind", "") == "rocket"
		and rocket_target.get("position", Vector3.INF).distance_to(
			Net._rocket_boarding_position(Net.PlayerRealm.EARTH)) < 0.001
		and not controller._prompt.visible and manager._mission_panel.visible
		and manager._mission_label.text.contains("E TO BOARD"),
		"rocket hatch prompt and action agree even when an NPC is also in range")
	await _tap(KEY_E)
	manager._update_proximity_prompt()
	check(manager.is_local_player_aboard() and player.expedition_locked
		and not controller.ui.visible and manager._mission_panel.visible
		and manager._mission_label.text.contains("E TO DISEMBARK")
		and manager._mission_label.text.contains("L TO LAUNCH")
		and manager._mission_label.text.contains("C CABIN / EXTERIOR"),
		"one gameplay E tap boards the rocket without a competing social action")
	var left_rocket := manager.request_disembark()
	await _frames(3)
	check(left_rocket and not manager.is_local_player_aboard()
		and not player.expedition_locked,
		"rocket E lifecycle still disembarks without immediately reboarding")

	# Production input deliberately goes neutral while any menu owns the cursor.
	controller.ui.open(nana.interaction())
	player.test_mode = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.action_press("grab")
	var blocked_input: Dictionary = player._gather()
	Input.action_release("grab")
	check(not bool(blocked_input.grab) and not bool(blocked_input.interact_just)
		and player.vehicle == null and not manager.is_local_player_aboard(),
		"an open menu blocks E before vehicle or rocket dispatch")
	player.test_mode = true
	controller.ui.close()
	nana.global_position = saved_nana_position
	controller.simulation.state.citizens.nana.position = saved_model_position

func _market_fallback(nana: Node3D,market: Dictionary) -> void:
	controller.ui.close()
	# A packer servicing the market can be the closest person while the
	# merchant is elsewhere. Keep model and physical presentation together;
	# ordinary E must still select that person before their explicit desk link.
	var packer: Node3D = controller.earth_settlement.citizens.get("pip")
	check(is_instance_valid(packer),"market fallback uses the actual packer resident")
	if not is_instance_valid(packer): return
	var market_xz := Vector2(market.position.x,market.position.z)
	for entry: Array in [[nana,"nana",market_xz+Vector2(16,0)],[packer,"pip",market_xz]]:
		var at: Vector2 = entry[2]
		controller.simulation.state.citizens[entry[1]].position = [at.x,at.y]
		var resident: Node3D = entry[0]
		resident.position = Vector3(at.x,Gen.height(at.x,at.y),at.y)
	var approach := Vector3(market_xz.x,0,market_xz.y+2.5)
	approach.y = Gen.height(approach.x,approach.z)+0.15
	player.admin_teleport(approach)
	await _frames(8)
	check(controller.nearest_interaction().get("id")=="pip",
		"nonmerchant at the desk wins the actual nearest-person selection")
	await _tap(KEY_E)
	var link := _find_button(controller.ui,"Use " + str(market.label))
	check(controller.ui.context.get("id")=="pip" and link!=null
		and not _text(controller.ui._body).contains("My trading desk"),
		"E opens the packer's conversation with a physical Use market link")
	if link==null: return
	link.pressed.emit()
	await _frames(2)
	check(controller.ui.context.get("id")=="earth_market"
		and controller.selected_interaction.get("id")=="earth_market"
		and controller.ui._heading.text==str(controller.simulation.state.locations.earth_market.label),
		"Use market executes the real callback and selects the authoritative physical desk")
	var quantity: SpinBox = controller.ui._body.find_children("*","SpinBox",true,false)[0]
	quantity.value = 1
	var buy: Button
	for label in controller.ui._body.find_children("*","Label",true,false):
		if label.text == "Banana": buy = _find_button(label.get_parent(),"Buy")
	check(buy!=null,"market reached from a nonmerchant has the real banana purchase control")
	if buy==null: return
	var old_bag: int = controller.simulation.stock("player_earth","banana")
	var old_stock: int = controller.simulation.stock("earth_market","banana")
	var old_cash: int = controller.simulation.balance("player")
	var price: int = controller.simulation.quote("earth_market","banana",1,true)
	buy.pressed.emit()
	await _frames(2)
	check(controller.simulation.stock("player_earth","banana")==old_bag+1
		and controller.simulation.stock("earth_market","banana")==old_stock-1
		and controller.simulation.balance("player")==old_cash-price,
		"purchase through the fallback desk transfers one finite banana for the quoted credits")

func _find_button(node: Node,value: String) -> Button:
	if node is Button and node.text==value and node.is_visible_in_tree(): return node
	for child in node.get_children():
		var result := _find_button(child,value)
		if result!=null: return result
	return null

func _tap(code: Key) -> void:
	var event:=_key(code,true)
	if code==KEY_E:
		player.ti.interact_just=true
		await _frames(2)
	else:
		# The UI gets first refusal while visible; Main owns B from gameplay.
		if controller.ui.visible: controller.ui._input(event)
		else: main._unhandled_input(event)
		await _frames(1)

func _key(code: Key, down: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode=code
	event.physical_keycode=code
	event.pressed=down
	return event

func _frames(count: int) -> void:
	for index in range(count): await get_tree().physics_frame
	await get_tree().process_frame

func _visible_button(node: Node, value: String) -> bool:
	if node is Button and node.text==value and node.is_visible_in_tree(): return true
	for child in node.get_children():
		if _visible_button(child,value): return true
	return false

func _visible_citizen_labels() -> Array[String]:
	var visible_ids: Array[String] = []
	for id in controller.earth_settlement.citizens:
		var citizen: Node3D = controller.earth_settlement.citizens[id]
		if citizen._name_label.is_visible_in_tree(): visible_ids.append(str(id))
	return visible_ids

func _text(node: Node) -> String:
	var value := str(node.text)+"\n" if node is Label or node is Button else ""
	for child in node.get_children(): value+=_text(child)
	return value

func _finish() -> void:
	Input.parse_input_event(_key(KEY_E,false))
	Input.parse_input_event(_key(KEY_B,false))
	controller.persistence_enabled=false
	main._return_to_main_menu()
	await _frames(3)
	print("FRONTIERINTERACTIONTEST %d/%d %s" % [passed,total,"PASS" if passed==total else "FAIL"])
	get_tree().quit(0 if passed==total else 1)
