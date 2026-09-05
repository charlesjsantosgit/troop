extends Node
## Main-scene fixture: real dedicated authority, two simultaneous clients,
## ordinary position/RPC lanes, authenticated reconnect and persisted restart.
const Law = preload("res://scripts/civil_law.gd")
const Plan = preload("res://scripts/city_plan.gd")
const Commerce = preload("res://scripts/city_commerce.gd")
var role := ""
var directory := ""
var net: Node
var service: Node
var civil: Node
var replies: Array = []
var checks := 0
var passed := 0
var done := false
var target: Dictionary = {}


func run(_main = null) -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 4: get_tree().quit(2); return
	role = args[1]
	directory = args[3]
	if role not in ["server", "robber", "observer", "resume", "restart"] or not directory.is_absolute_path() \
			or not directory.get_file().begins_with("troop-civil-network-"):
		get_tree().quit(2); return
	var identity_role := "robber" if role in ["resume", "restart"] else role
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", directory.get_file() + "-" + identity_role)
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	for key in ["TROOP_ADMIN_KEY", "TROOP_ADMIN_TOKEN", "TROOP_STATE_DIR"]: OS.unset_environment(key)
	net = get_tree().root.get_node("Net")
	get_tree().create_timer(160).timeout.connect(func(): _check(false,"fixture deadline"); _finish())
	if role == "server": await _server(int(args[2])); return
	_check(net.join("127.0.0.1", "Civil-" + identity_role, int(args[2])) == OK, "authenticated connection starts")
	service = net.frontier_network
	civil = service.civil
	civil.finished.connect(func(kind, outcome): replies.append({"kind":kind,"outcome":outcome.duplicate(true)}))
	var deadline := Time.get_ticks_msec() + 20000
	while (service.views.size() < 6 or not net.names.has(net.local_id())) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(service.views.size() == 6 and net.names.has(net.local_id()), "ordinary six-society bootstrap and registered peer complete")
	if service.views.size() < 6: await _finish(); return
	target = _read("target")
	if role == "robber": await _robber()
	elif role == "observer": await _observer()
	else: await _resume()
	await _finish()


func _server(port: int) -> void:
	OS.set_environment("TROOP_STATE_DIR", directory.path_join("state"))
	_check(net.start_dedicated(2026, port, "127.0.0.1") == OK, "isolated dedicated authority starts")
	service = net.frontier_network
	civil = service.civil
	target = _choose_target()
	_check(not target.is_empty(), "deterministic remote shop has a real robbery counter")
	_write("target", target)
	var restarting := FileAccess.file_exists(directory.path_join("restarting"))
	if restarting:
		civil.set_process(false)
		_verify_authority_cash("authority restart reload")
	_write("ready", {})
	while not FileAccess.file_exists(directory.path_join("stop")):
		var positions := {}
		for peer in net._peer_on_foot_positions:
			positions[str(peer)] = Law.point(net._peer_on_foot_positions[peer])
		_write("observed-positions", positions)
		if not restarting and FileAccess.file_exists(directory.path_join("freeze-request")) \
				and not FileAccess.file_exists(directory.path_join("frozen")):
			_check(net.names.size() >= 2, "robber and observer are concurrently registered")
			_verify_authority_cash("completed robbery")
			# Pause only after genuine completion, to compare identical snapshots
			# without time/patrol motion races. No reward or law record is manufactured.
			civil.set_process(false)
			var expected := {}
			for peer in net.names:
				var actor := "member_" + str(service._identity(int(peer)))
				if not service.societies.state.players.has(actor): continue
				var view: Dictionary = civil._view(actor)
				expected[str(net.names[peer])] = view
				civil.rpc_id(int(peer), "cl_view", view)
			_write("frozen", expected)
		for resumed in ["resume", "restart"]:
			if FileAccess.file_exists(directory.path_join(resumed + "-ready")) \
					and not FileAccess.file_exists(directory.path_join(resumed + "-published")):
				_verify_authority_cash(resumed + " reconnect")
				var peer := _peer_named("Civil-robber")
				_check(peer > 0, "returning authenticated identity is registered")
				if peer > 0:
					var actor := "member_" + str(service._identity(peer))
					var view: Dictionary = civil._view(actor)
					civil.rpc_id(peer, "cl_view", view)
					_write(resumed + "-published", view)
		await get_tree().create_timer(0.05).timeout
	_verify_authority_cash("shutdown checkpoint")
	_check(service.societies.save_game(service.storage_path), "authority saves law records and evidence escrow through ordinary persistence")
	await _finish()


func _verify_authority_cash(label: String) -> void:
	var actor := _actor_named("Civil-robber")
	var observer := _actor_named("Civil-observer")
	var city = service.societies._city()
	var sim = service.societies.simulations.canopy
	_check(not actor.is_empty() and int(city.state.civil_law.residents.get(actor,{}).get("cash",0)) == int(target.reward),
		label + " preserves the exact stolen bag")
	_check(int(sim.balance(Law.ESCROW)) == int(target.reward) and Law.escrow_total(city.state.civil_law) == int(target.reward),
		label + " evidence account equals resident cash liability")
	_check(service.societies.total_money() == service.societies.STARTING_MONEY,
		label + " conserves all society money")
	_check(not observer.is_empty() and int(city.state.civil_law.residents.get(observer,{}).get("cash",0)) == 0,
		label + " never assigns the observer someone else's cash")
	_check(not service.societies.export_state().is_empty() and Law.valid(city.state.civil_law),
		label + " law state remains bounded and valid")


func _robber() -> void:
	await _position(Law.vector(target.position))
	_write("robber-ready", {"peer":net.local_id()})
	await _wait_file("observer-tested")
	var result: Dictionary = await _action("civil_rob", {"id":target.id})
	_check(result.get("ok",false), "physical shop counter starts a real timed robbery over ENet")
	var serial: int = civil._serial
	await get_tree().create_timer(0.8).timeout
	result = await _raw_action(serial, "civil_rob", {"id":target.id})
	_check(result.get("ok",false), "duplicate robbery RPC returns its receipt without another action")
	var deadline := Time.get_ticks_msec() + 19000
	while int(civil.cached_view.get("personal",{}).get("cash",0)) == 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(int(civil.cached_view.get("personal",{}).get("cash",0)) == int(target.reward),
		"authority completion sends the exact stolen cash amount to the robber")
	_check(civil.cached_view.get("personal",{}).get("phase","") in ["reported","pursuit","search"],
		"the robbery creates a visible police consequence")
	_check(int(civil.cached_view.get("credits",0)) == 1800, "stolen escrow is separate from the ordinary spendable wallet")
	_write("freeze-request", {})
	await _wait_file("frozen")
	await _check_frozen_view("Civil-robber")
	_write("robber-done", {"cash":civil.cached_view.personal.cash,"credits":civil.cached_view.credits})
	await _wait_file("observer-done")


func _observer() -> void:
	await _position(Law.vector(target.position) + Vector3(250,0,250))
	await _wait_file("robber-ready")
	var result: Dictionary = await _action("civil_rob", {"id":target.id})
	_check(not result.get("ok",true), "remote robbery RPC is rejected by physical authority position")
	result = await _raw_action(civil._serial + 1, "civil_rob", {"id":target.id,"reward":999999})
	_check(not result.get("ok",true), "forged reward field is rejected on the real RPC lane")
	result = await _raw_action(civil._serial + 1, "civil_fence", {"actor":"member_" + "f".repeat(64)})
	_check(not result.get("ok",true), "forged actor field cannot select another resident's wallet")
	_check(int(civil.cached_view.get("personal",{}).get("cash",0)) == 0 and int(civil.cached_view.get("credits",0)) == 1800,
		"rejected requests leave observer cash and legitimate wallet intact")
	_write("observer-tested", {})
	var deadline := Time.get_ticks_msec() + 6000
	while civil.cached_view.get("robberies",[]).is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(not civil.cached_view.get("robberies",[]).is_empty(), "the second client observes the first client's live robbery")
	await _wait_file("frozen")
	await _check_frozen_view("Civil-observer")
	_check(not JSON.stringify(civil.cached_view).contains("member_"), "observer snapshot omits private authenticated resident identifiers")
	_write("observer-done", {})


func _resume() -> void:
	await _position(Law.vector(target.position) + Vector3(600,0,600))
	_write(role + "-ready", {"peer":net.local_id()})
	await _wait_file(role + "-published")
	var expected := _read(role + "-published")
	await _await_view_time(float(expected.time))
	_check(int(civil.cached_view.get("personal",{}).get("cash",0)) == int(target.reward),
		"same authenticated identity retains its exact escrow bag after " + role)
	_check(int(civil.cached_view.get("credits",0)) == 1800, "returning identity receives no duplicate starter grant")
	_check(civil.cached_view.get("personal",{}).get("phase","") == expected.personal.phase,
		"reconnect does not clear the saved criminal phase")
	_check(civil.cached_view.get("units",[]) == expected.units, "returning client receives the saved shared patrol state")


func _check_frozen_view(name: String) -> void:
	var expected: Dictionary = _read("frozen")[name]
	await _await_view_time(float(expected.time))
	# JSON normalizes numeric types; compare encoded values to the authority's
	# corresponding JSON snapshot rather than Array int/float variants.
	_check(JSON.stringify(civil.cached_view.get("units",[])) == JSON.stringify(expected.units),
		"client patrol IDs, positions, sirens and targets match one exact authority snapshot")
	_check(JSON.stringify(civil.cached_view.get("robberies",[])) == JSON.stringify(expected.robberies),
		"client incident state matches the same authority snapshot")
	_check(int(civil.cached_view.get("personal",{}).get("cash",0)) == int(expected.personal.get("cash",0)),
		"personal cash view matches its own authority record")


func _await_view_time(time: float) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while float(civil.cached_view.get("time",0)) < time - 0.001 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(float(civil.cached_view.get("time",0)) >= time - 0.001, "published authority view arrives")


func _action(kind: String, payload: Dictionary = {}) -> Dictionary:
	var previous := replies.size()
	var requested: Dictionary = civil.request(kind, payload)
	if not requested.get("pending",false): return requested
	return await _await_reply(previous, kind)


func _raw_action(serial: int, kind: String, payload: Dictionary) -> Dictionary:
	var previous := replies.size()
	civil._serial = maxi(civil._serial, serial)
	civil.rpc_id(1, "sv_action", serial, kind, payload)
	return await _await_reply(previous, kind)


func _await_reply(previous: int, kind: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 6000
	while replies.size() <= previous and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	_check(replies.size() > previous, "authority reply arrives for " + kind)
	await get_tree().create_timer(0.3).timeout
	return replies[previous].outcome if replies.size() > previous else {"ok":false,"message":"Timed out"}


func _position(point: Vector3) -> void:
	var deadline := Time.get_ticks_msec() + 7000
	while Time.get_ticks_msec() < deadline:
		net.send_state(point, 0.0, Vector3.ZERO, 0, false, Vector3.ZERO, 0.0,
			PackedVector3Array(), 0, true, false, 0, false, 0.0)
		await get_tree().create_timer(0.06).timeout
		var observed := _read("observed-positions")
		var actual: Array = observed.get(str(net.local_id()), [])
		if actual.size() == 3 and Law.vector(actual).distance_to(point) < 0.02: return
	_check(false, "authority receives ordinary position before a physical service request")


func _choose_target() -> Dictionary:
	var law = Law.new()
	law.state = Law.new_state()
	for record: Dictionary in Plan.block_buildings(Vector2i(40,40)):
		if not Commerce.offers(record).is_empty():
			return law.target_for(str(record.id))
	return {}


func _peer_named(name: String) -> int:
	for peer in net.names:
		if net.names[peer] == name: return int(peer)
	return 0


func _actor_named(name: String) -> String:
	for actor in service.societies.state.players:
		if service.societies.state.players[actor].name == name: return actor
	return ""


func _wait_file(name: String) -> void:
	var deadline := Time.get_ticks_msec() + 30000
	while not FileAccess.file_exists(directory.path_join(name)) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.04).timeout
	_check(FileAccess.file_exists(directory.path_join(name)), "synchronized " + name)


func _read(name: String) -> Dictionary:
	var path := directory.path_join(name)
	if not FileAccess.file_exists(path): return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else {}


func _write(name: String, data: Dictionary) -> void:
	var path := directory.path_join(name)
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()
	DirAccess.rename_absolute(path + ".tmp", path)


func _check(ok: bool, label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("CIVILNET ", role, " ", "PASS " if ok else "FAIL ", label)


func _finish() -> void:
	if done: return
	done = true
	net.shutdown()
	for frame in range(4): await get_tree().process_frame
	print("CIVILNETWORK_", role.to_upper(), " ", passed, "/", checks, " ", "PASS" if passed == checks else "FAIL")
	get_tree().quit(0 if passed == checks else 1)
