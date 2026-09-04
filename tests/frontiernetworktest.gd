extends SceneTree
## Three actual ENet processes, then a server restart with the same proven key.
## This fixture only accepts localhost and isolated, runner-created directories.
var net: Node
var service: Node
var role := ""
var directory := ""
var port := 0
var results: Dictionary = {}
var passed := 0
var checks := 0
var finished := false

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("FRONTIERNET %s %s" % ["OK" if ok else "FAIL", label])

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 3:
		quit(2)
		return
	role = args[0]
	port = int(args[1])
	directory = args[2]
	if role not in ["server", "owner", "visitor", "resume"] or not directory.is_absolute_path() \
			or not directory.get_file().begins_with("troop-frontier-network-") or not DirAccess.dir_exists_absolute(directory):
		quit(2)
		return
	var identity_role := "owner" if role == "resume" else role
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", directory.get_file() + "-" + identity_role)
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	print("FRONTIERNET_USERDIR " + OS.get_user_data_dir())
	for variable in ["TROOP_ADMIN_KEY", "TROOP_ADMIN_TOKEN", "TROOP_STATE_DIR"]:
		OS.unset_environment(variable)
	net = root.get_node("Net")
	create_timer(100).timeout.connect(func(): check(false, "deadline"); _finish())
	if role == "server":
		OS.set_environment("TROOP_STATE_DIR", directory.path_join("state"))
		check(net.start_dedicated(2026, port, "127.0.0.1") == OK, "dedicated shared server starts")
		service = net.frontier_network
		print("FRONTIERNET_SERVER_READY")
		var moved := false
		while not FileAccess.file_exists(directory.path_join("stop")):
			if not moved and FileAccess.file_exists(directory.path_join("visit-moon")):
				for peer_id in net.names:
					if net.names[peer_id] == "Frontier-visitor":
						net.player_realms[peer_id] = net.PlayerRealm.MOON
						net._clear_peer_realm_position(peer_id)
						net._broadcast_expedition_state()
						var site = service.sites.canopy_moon
						var point: Vector3 = site.surface_point(4, 2.5, 0.8)
						_write("moon-arrival", {"position": [point.x, point.y, point.z]})
						moved = true
			await process_frame
		check(service.societies.total_money() == 738600, "server conserves all money")
		net.shutdown()
		_finish()
		return
	check(net.join("127.0.0.1", "Frontier-" + role, port) == OK, "ENet connection starts")
	service = net.frontier_network
	service.action_finished.connect(func(serial, _kind, result): results[serial] = result)
	var deadline := Time.get_ticks_msec() + 15000
	while service.views.size() < 6 and Time.get_ticks_msec() < deadline:
		await process_frame
	check(service.views.size() == 6 and service.catalog.size() == 6, "all six personalized towns bootstrap")
	if service.views.size() < 6:
		_finish()
		return
	if role == "owner": await _owner()
	elif role == "visitor": await _visitor()
	else: await _resume()
	net.shutdown()
	await create_timer(0.2).timeout
	_finish()

func _owner() -> void:
	await _position(Vector3(3.8, 4.05, -0.3))
	check((await _action("canopy_earth", "claim_town", {"source":"town_square"})).ok, "owner pays for actual town claim")
	await _view("canopy_earth")
	check(_state().town.is_owner and _state().accounts.player == 1050, "authoritative view has exclusive claim and exact debit")
	var serial: int = service._serial
	service.rpc_id(1, "sv_action", serial, "canopy_earth", "claim_town", {"source":"town_square"})
	await create_timer(0.3).timeout
	check(_state().accounts.player == 1050, "replayed request cannot charge twice")
	await _position(Vector3(0, 4.05, -15))
	check((await _action("canopy_earth", "buy", {"market":"earth_market","item":"banana","quantity":1,"source":"earth_market"})).ok, "buy exchanges real shared stock")
	await _view("canopy_earth")
	check(_state().inventories.player_earth.banana == 9, "purchase increments only buyer bag")
	var money: int = _state().accounts.player
	check(not (await _action("canopy_earth", "buy", {"market":"earth_market","item":"banana","quantity":NAN})).ok, "NaN quantity rejected over network")
	check(not (await _action("canopy_earth", "buy", {"market":"earth_market","item":"banana","quantity":-1})).ok, "negative quantity rejected")
	await _position(Vector3(180, 4.05, 160))
	check(not (await _action("canopy_earth", "buy", {"market":"earth_market","item":"banana","quantity":1})).ok, "remote trade rejected using accepted player position")
	await _position(Vector3(-35, 4.05, -29))
	check((await _action("canopy_earth", "plant", {"plot":"earth_4","crop":"banana","source":"earth_4"})).ok, "owner plants at actual bed")
	check((await _action("canopy_earth", "water", {"plot":"earth_4","source":"earth_4"})).ok, "watering consumes owner supply")
	await _position(Vector3(3.8, 4.05, -0.3))
	check((await _action("canopy_earth", "accept_quest", {"id":"first_harvest","source":"town_square"})).ok, "community board accepts private funded request")
	await _position(Vector3(0, 4.05, -15))
	check((await _action("canopy_earth", "deliver_quest", {"id":"first_harvest","source":"earth_market"})).ok, "actual delivery transfers goods and pays escrow")
	await _view("canopy_earth")
	check(_state().quests.first_harvest.status == "complete" and _state().inventories.player_earth.banana == 1 \
		and _state().accounts.player == money + 120, "completed request and payment are consistent")
	_write("owner-ready", {"credits":_state().accounts.player,"bag":_state().inventories.player_earth,"claim":"canopy_earth"})
	await _wait_file("visitor-ready")
	await _position(Vector3(653.8, 4.05, -0.3))
	check(not (await _action("harbor_earth", "claim_town", {"source":"town_square"})).ok, "one resident cannot acquire a second town")
	await _view("harbor_earth")
	check(service.views.harbor_earth.accounts.player == _read("owner-ready").credits, "wallet follows owner across societies")
	check(not JSON.stringify(service.views.harbor_earth).contains("member_"), "wire views hide private resident identifiers")
	await _position(Vector3(3.8, 4.05, -0.3))
	service.watch_town("canopy_earth")
	await create_timer(1.2).timeout
	check(service.traffic_views.get("canopy_earth", []).size() == 5, "late joined client receives five authoritative delivery vehicles")

func _visitor() -> void:
	await _wait_file("owner-ready")
	await _position(Vector3(3.8, 4.05, -0.3))
	await _view("canopy_earth")
	check(_state().town.claimed and not _state().town.is_owner, "another client sees same town owner")
	check(_state().accounts.player == 1800 and _state().inventories.player_earth.banana == 8 \
		and _state().quests.first_harvest.status == "available", "visitor wallet bag and request stay independent")
	check(not (await _action("canopy_earth", "claim_town", {"source":"town_square"})).ok, "claim collision rejects second buyer")
	await _position(Vector3(-35, 4.05, -29))
	check(not (await _action("canopy_earth", "clear_plot", {"plot":"earth_4"})).ok, "visitor cannot erase owner crop")
	await _position(Vector3(0, 4.05, -15))
	check((await _action("canopy_earth", "buy", {"market":"earth_market","item":"water","quantity":1})).ok, "claimed town still welcomes public trade")
	check(not (await _action("canopy_moon", "claim_town", {"source":"town_square"})).ok, "Earth position cannot claim Moon town")
	_write("visit-moon", {})
	await _wait_file("moon-arrival")
	var values: Array = _read("moon-arrival").position
	await _position(Vector3(values[0], values[1], values[2]))
	check(net.player_realm() == net.PlayerRealm.MOON, "authoritative realm transition reaches other client")
	check((await _action("canopy_moon", "claim_town", {"source":"town_square"})).ok, "Moon board accepts its own nearby claim")
	await _view("canopy_moon")
	check(service.views.canopy_moon.town.is_owner, "Moon owner gets management permissions")
	_write("visitor-ready", {})

func _resume() -> void:
	await _position(Vector3(3.8, 4.05, -0.3))
	await _view("canopy_earth")
	var expected := _read("owner-ready")
	check(_state().town.is_owner and _state().accounts.player == expected.credits, "same authenticated installation retains claim and wallet after server restart")
	check(_state().inventories.player_earth == expected.bag, "restart cannot duplicate starter goods or delivered cargo")
	check(_state().quests.first_harvest.status == "complete" and _state().plots.earth_4.crop == "banana", "private request and planted crop survive restart")
	check(not (await _action("canopy_earth", "claim_town", {})).ok, "reconnect cannot buy an already owned town")

func _state() -> Dictionary:
	return service.views.canopy_earth

func _action(town: String, kind: String, payload: Dictionary) -> Dictionary:
	var reply: Dictionary = service.request_action(town, kind, payload)
	if not reply.get("pending", false): return reply
	var serial := int(reply.request)
	var deadline := Time.get_ticks_msec() + 6000
	while not results.has(serial) and Time.get_ticks_msec() < deadline:
		await process_frame
	var result: Dictionary = results.get(serial, {"ok":false,"message":"request timeout"})
	if not results.has(serial): check(false, "server acknowledged " + kind)
	await create_timer(0.2).timeout
	return result

func _position(point: Vector3) -> void:
	for _index in range(5):
		net.send_state(point, 0.0, Vector3.ZERO, 0, false, Vector3.ZERO, 0.0,
			PackedVector3Array(), net.WEAPON_REVOLVER, false, true, 6, false, 0.0)
		await create_timer(0.06).timeout

func _view(town: String) -> void:
	var before: int = service._view_sequence
	service.watch_town(town)
	var deadline := Time.get_ticks_msec() + 4000
	while service._view_sequence == before and Time.get_ticks_msec() < deadline:
		await process_frame

func _wait_file(name: String) -> void:
	while not FileAccess.file_exists(directory.path_join(name)):
		await create_timer(0.05).timeout

func _write(name: String, data: Dictionary) -> void:
	var file := FileAccess.open(directory.path_join(name), FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func _read(name: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(directory.path_join(name)))

func _finish() -> void:
	if finished: return
	finished = true
	print("FRONTIERNET_%s %d/%d %s" % [role.to_upper(),passed,checks,"PASS" if passed==checks else "FAIL"])
	quit(0 if passed==checks else 1)
