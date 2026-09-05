extends SceneTree
const Plan = preload("res://scripts/city_plan.gd")
const Rooms = preload("res://scripts/city_interior.gd")
const CityNetworkScript = preload("res://scripts/city_network.gd")
var role := ""
var directory := ""
var net: Node
var service: Node
var city: Node
var replies: Dictionary = {}
var checks := 0
var passed := 0
var done := false

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("CITYNET %s %s" % ["PASS" if ok else "FAIL", label])

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 3: quit(2); return
	role = args[0]
	var port := int(args[1])
	directory = args[2]
	if role not in ["server", "buyer", "visitor", "resume"] or not directory.is_absolute_path() \
			or not directory.get_file().begins_with("troop-city-network-"): quit(2); return
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", directory.get_file() + "-" + ("buyer" if role == "resume" else role))
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	for key in ["TROOP_ADMIN_KEY", "TROOP_ADMIN_TOKEN", "TROOP_STATE_DIR"]: OS.unset_environment(key)
	net = root.get_node("Net")
	var compact := CityNetworkScript.bounded_reply({"ok": true, "message": "Purchased.",
		"destination": Vector3(4, 8, 9), "player_patch": {"accounts": {"player": 1350}},
		"view": {"oversized": "x".repeat(CityNetworkScript.MAX_PACKET)}})
	check(compact.ok and compact.destination == Vector3(4, 8, 9) and compact.has("player_patch") \
		and not compact.has("view") and var_to_bytes(compact).size() <= CityNetworkScript.MAX_PACKET,
		"oversize fallback preserves committed outcome and terminates pending")
	create_timer(90).timeout.connect(func(): check(false, "deadline"); _finish())
	if role == "server":
		OS.set_environment("TROOP_STATE_DIR", directory.path_join("state"))
		check(net.start_dedicated(2026, port, "127.0.0.1") == OK, "isolated dedicated server starts")
		service = net.frontier_network
		_write("ready", {})
		while not FileAccess.file_exists(directory.path_join("stop")): await create_timer(0.1).timeout
		check(service.societies.total_money() == 738600, "server conserves all credits after city transactions")
		check(service.societies.save_game(service.storage_path), "server checkpoints city ownership and inventory")
		net.shutdown()
		_finish()
		return
	check(net.join("127.0.0.1", "City-" + role, port) == OK, "authenticated connection starts")
	service = net.frontier_network
	city = service.city
	city.finished.connect(func(serial, _kind, result): replies[serial] = result)
	var deadline := Time.get_ticks_msec() + 16000
	while service.views.size() < 6 and Time.get_ticks_msec() < deadline: await process_frame
	check(service.views.size() == 6, "existing six societies still bootstrap")
	if service.views.size() < 6: _finish(); return
	check((await _action("inspect")).ok, "private city view arrives on action lane")
	var cottage := Plan.building("village-cottage")
	if role == "buyer":
		await _position(cottage.door)
		check((await _action("buy_home", {"building": cottage.id})).ok, "buyer purchases cottage over ENet")
		check(city.cached_view.credits == 1350, "authoritative city wallet reflects exact price")
		var serial: int = city._serial
		city.rpc_id(1, "sv_request", serial, "buy_home", {"building": cottage.id})
		await create_timer(0.3).timeout
		check((await _action("inspect")).view.credits == 1350, "duplicate RPC cannot charge twice")
		check(service.views.canopy_earth.accounts.player == 1350, "city wallet patch updates existing town UI")
		check(not city.cached_view.owned_properties[0].storage_included \
			and city.cached_view.owned_properties[0].get("storage", {}).is_empty(), "outside view contains only property summaries")
		check((await _action("enter", {"id": cottage.id})).ok, "physical door authorizes room entry")
		check(city.cached_view.owned_properties[0].storage_included, "authorized room scopes its private cupboard into the reply")
		var origin: Vector3 = city.interior_origin(cottage)
		await _position(origin + Rooms.service_layout(cottage).storage.position)
		check((await _action("store_item", {"building": cottage.id, "item": "banana", "quantity": 2})).ok, "cupboard transfers real bag goods over ENet")
		check(service.views.harbor_earth.inventories.player_earth.banana == 6, "all cached town backpacks reconcile immediately")
		await _position(origin + Rooms.service_layout(cottage).bed.position)
		check((await _action("set_home", {"building": cottage.id})).ok, "bed saves selected home")
		check((await _action("exit")).ok, "room exit is authorized")
		await _position(cottage.door)
		check(not (await _action("take_item", {"building": cottage.id, "item": "banana", "quantity": 1})).ok, "outdoor storage requests rejected on server")
		await _position(Vector3(3000, 8, 500))
		check(not (await _action("buy_home", {"building": "suburban-home"})).ok, "remote house purchase rejected")
		await _position(Plan.service("courier_depot").position)
		check((await _action("start_job", {"job": "courier_lantern"})).ok \
			and city.cached_view.active_job.cargo.get("meal", 0) == 2,
			"real courier workplace issues a finite sealed parcel")
		await _position(Plan.service("courier_delivery_lantern").position)
		check(not (await _action("finish_job")).ok, "early delivery cannot skip the authoritative work timer")
		var remaining: float = city.cached_view.active_job.ready_at - city.cached_view.time
		await create_timer(maxf(0.1, remaining + 0.6)).timeout
		check((await _action("finish_job")).ok and city.cached_view.active_job.is_empty() \
			and city.cached_view.credits == 1422, "completed delivery transfers its 72-credit wage exactly once")
		check(not (await _action("finish_job")).ok and city.cached_view.credits == 1422,
			"repeated completion cannot collect another wage")
		_write("buyer", {"credits": city.cached_view.credits, "bag": city.cached_view.backpack_counts})
	elif role == "visitor":
		await _position(cottage.door)
		check(not (await _action("buy_home", {"building": cottage.id})).ok, "second resident cannot take an owned home")
		check(city.cached_view.owned_properties.is_empty() and city.cached_view.credits == 1800, "other resident receives no private storage or wallet")
		check(not JSON.stringify(city.cached_view).contains("member_"), "city snapshots omit private authenticated identifiers")
		check((await _action("enter", {"id": cottage.id})).ok, "a visitor can enter without taking ownership")
		await _position(city.interior_origin(cottage) + Rooms.service_layout(cottage).storage.position)
		check(not (await _action("take_item", {"building": cottage.id, "item": "banana", "quantity": 1})).ok \
			and city.cached_view.owned_properties.is_empty(), "room presence grants neither another resident's stock nor withdrawal")
	else:
		var expected: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("buyer")))
		check(city.cached_view.home == cottage.id and city.cached_view.owned_properties.size() == 1, "same identity retains home after server restart")
		check(city.cached_view.credits == expected.credits and city.cached_view.backpack_counts == expected.bag, "restart preserves credits and stored goods without duplicate starter grants")
		await _position(cottage.door)
		var entry: Dictionary = await _action("enter", {"id": cottage.id})
		print("CITYNET RESUME_ENTRY ok=%s message=%s scoped=%s banana=%s" % [entry.ok,
			entry.get("message", ""), city.cached_view.owned_properties[0].storage_included,
			city.cached_view.owned_properties[0].storage.get("banana", -1)])
		check(entry.ok \
			and city.cached_view.owned_properties[0].storage.get("banana", 0) == 2,
			"saved cupboard contains the exact deposited goods after restart")
	net.shutdown()
	await create_timer(0.15).timeout
	_finish()

func _action(kind: String, payload: Dictionary = {}) -> Dictionary:
	var requested: Dictionary = city.request(kind, payload)
	if not requested.get("pending", false): return requested
	var deadline := Time.get_ticks_msec() + 7000
	while not replies.has(requested.request) and Time.get_ticks_msec() < deadline: await process_frame
	if not replies.has(requested.request): check(false, "reply for " + kind)
	await create_timer(0.22).timeout
	return replies.get(requested.request, {"ok": false, "message": "Timed out"})

func _position(point: Vector3) -> void:
	for index in range(5):
		net.send_state(point, 0.0, Vector3.ZERO, 0, false, Vector3.ZERO, 0.0,
			PackedVector3Array(), net.WEAPON_REVOLVER, false, true, 6, false, 0.0)
		await create_timer(0.06).timeout

func _write(name: String, data: Dictionary) -> void:
	var file := FileAccess.open(directory.path_join(name), FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func _finish() -> void:
	if done: return
	done = true
	print("CITYNETWORK_%s %d/%d %s" % [role.to_upper(), passed, checks, "PASS" if checks == passed else "FAIL"])
	quit(0 if checks == passed else 1)
