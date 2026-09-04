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
			and _text(controller.ui._body).contains("My trading desk"),
			"Nana's panel exposes their trading desk without a competing journal shortcut")
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
	await _finish()

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
