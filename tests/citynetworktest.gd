extends SceneTree
var Plan:Script
var Rooms:Script
var CityNetworkScript:Script
var Fleet:Script
var Commerce:Script
var role = ""
var directory = ""
var net: Node
var service: Node
var city: Node
var replies: Dictionary = {}
var checks = 0
var passed = 0
var done = false

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("CITYNET %s %s" % ["PASS" if ok else "FAIL", label])

func _run() -> void:
	# Standalone SceneTree scripts load before project autoload symbols. Resolve
	# the canonical MonkeyRig/Vehicle-dependent modules only after initialization.
	Plan=load("res://scripts/city_plan.gd")
	Rooms=load("res://scripts/city_interior.gd")
	CityNetworkScript=load("res://scripts/city_network.gd")
	Fleet=load("res://scripts/city_vehicle_models.gd")
	Commerce=load("res://scripts/city_commerce.gd")
	var args = OS.get_cmdline_user_args()
	if args.size() != 3: quit(2); return
	role = args[0]
	var port = int(args[1])
	directory = args[2]
	if role not in ["server", "buyer", "visitor", "resume"] or not directory.is_absolute_path() \
			or not directory.get_file().begins_with("troop-city-network-"): quit(2); return
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", directory.get_file() + "-" + ("buyer" if role == "resume" else role))
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	for key in ["TROOP_ADMIN_KEY", "TROOP_ADMIN_TOKEN", "TROOP_STATE_DIR"]: OS.unset_environment(key)
	net = root.get_node("Net")
	var compact = CityNetworkScript.bounded_reply({"ok": true, "message": "Purchased.",
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
		while not FileAccess.file_exists(directory.path_join("stop")):
			if FileAccess.file_exists(directory.path_join("fund-car")) and not FileAccess.file_exists(directory.path_join("funded-car")):
				for actor in service.societies.state.players:
					if service.societies.state.players[actor].name=="City-buyer":
						service.societies.simulations.canopy._transfer("treasury",actor,30000,"Isolated dealership fixture funds")
						_write("funded-car",{})
			var positions = {}
			for peer in net._peer_on_foot_positions:
				var point: Vector3 = net._peer_on_foot_positions[peer]
				positions[str(peer)] = [point.x, point.y, point.z]
			_write("observed-positions", positions)
			await create_timer(0.1).timeout
		check(service.societies.total_money() == 738600, "server conserves all credits after city transactions")
		check(service.societies.save_game(service.storage_path), "server checkpoints city ownership and inventory")
		net.shutdown()
		_finish()
		return
	check(net.join("127.0.0.1", "City-" + role, port) == OK, "authenticated connection starts")
	service = net.frontier_network
	city = service.city
	city.finished.connect(func(serial, _kind, result): replies[serial] = result)
	var deadline = Time.get_ticks_msec() + 16000
	while service.views.size() < 6 and Time.get_ticks_msec() < deadline: await process_frame
	check(service.views.size() == 6, "existing six societies still bootstrap")
	if service.views.size() < 6: _finish(); return
	check((await _action("inspect")).ok, "private city view arrives on action lane")
	var cottage = Plan.building("village-cottage")
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
		var market = Plan.building("crownreach-b24-24-l00")
		await _position(market.door)
		var old_bananas = int(city.cached_view.backpack_counts.get("banana", 0))
		var old_stock = int(city.cached_view.retail_catalog[0].stock)
		var purchase = {"building": market.id, "item": "banana", "quantity": 2}
		check((await _action("buy_store_item", purchase)).ok and city.cached_view.credits == 1410
			and int(city.cached_view.backpack_counts.get("banana", 0)) == old_bananas + 2
			and int(city.cached_view.retail_catalog[0].stock) == old_stock - 2,
			"physical store purchase transfers exact credits, finite stock and backpack goods over ENet")
		var purchase_serial: int = city._serial
		city.rpc_id(1, "sv_request", purchase_serial, "buy_store_item", purchase)
		await create_timer(0.3).timeout
		check((await _action("inspect")).ok and city.cached_view.credits == 1410
			and int(city.cached_view.backpack_counts.get("banana", 0)) == old_bananas + 2,
			"replayed store purchase does not duplicate goods or charge twice")
		_write("fund-car",{})
		var funding_deadline=Time.get_ticks_msec()+4000
		while not FileAccess.file_exists(directory.path_join("funded-car")) and Time.get_ticks_msec()<funding_deadline:await process_frame
		var dealer=_dealer()
		await _position(dealer.door)
		await _action("inspect")
		var funded_balance:int=city.cached_view.credits
		var car_offer=Fleet.spec(1)
		var car_result=await _action("buy_vehicle",{"building":dealer.id,"model":car_offer.id})
		print("CITYNET CAR ok=%s message=%s vehicle=%s wallet=%s funded=%s"%[car_result.get("ok"),car_result.get("message"),car_result.get("vehicle",{}),city.cached_view.credits,funded_balance])
		var car_id=str(car_result.get("vehicle",{}).get("id",""))
		check(car_result.ok and city.cached_view.credits==funded_balance-int(car_offer.price) and city.cached_view.owned_vehicles.size()==1,"dealer purchase commits exact price and persistent ownership over ENet")
		check(net.vehicle_spawn_definitions.has(car_id) and Commerce.model_from_vehicle_id(car_id)==1,"purchased model is registered and delivered on the vehicle authority lane")
		var car_serial:int=city._serial
		city.rpc_id(1,"sv_request",car_serial,"buy_vehicle",{"building":dealer.id,"model":car_offer.id})
		await create_timer(.3).timeout
		await _action("inspect")
		check(city.cached_view.owned_vehicles.size()==1 and city.cached_view.credits==funded_balance-int(car_offer.price),"replayed vehicle purchase neither charges twice nor creates a second car")
		check((await _action("recall_vehicle",{"building":dealer.id,"vehicle":car_id})).ok,"owner collects purchased vehicle from a real dealership")
		_write("buyer", {"credits": city.cached_view.credits, "bag": city.cached_view.backpack_counts,"vehicle":car_id,"dealer":dealer.id})
	elif role == "visitor":
		await _position(cottage.door)
		check(not (await _action("buy_home", {"building": cottage.id})).ok, "second resident cannot take an owned home")
		check(city.cached_view.owned_properties.is_empty() and city.cached_view.credits == 1800, "other resident receives no private storage or wallet")
		check(not JSON.stringify(city.cached_view).contains("member_"), "city snapshots omit private authenticated identifiers")
		check((await _action("enter", {"id": cottage.id})).ok, "a visitor can enter without taking ownership")
		await _position(city.interior_origin(cottage) + Rooms.service_layout(cottage).storage.position)
		check(not (await _action("take_item", {"building": cottage.id, "item": "banana", "quantity": 1})).ok \
			and city.cached_view.owned_properties.is_empty(), "room presence grants neither another resident's stock nor withdrawal")
		check(not (await _action("buy_store_item", {"building": "crownreach-b24-24-l00", "item": "banana", "quantity": 1})).ok
			and city.cached_view.credits == 1800,
			"an active underground room cannot authorize an outdoor store purchase")
		await _action("exit")
		var buyer:Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("buyer")))
		await _position(Plan.building(buyer.dealer).door)
		check(not (await _action("recall_vehicle",{"building":buyer.dealer,"vehicle":buyer.vehicle})).ok and city.cached_view.owned_vehicles.is_empty(),"another resident cannot recall or see a private garage")
		await _position(net.vehicle_spawn_definitions[buyer.vehicle].pos)
		net.request_vehicle(buyer.vehicle,702)
		await create_timer(.4).timeout
		check(not net.claimed_vehicles.has(buyer.vehicle),"another resident cannot claim the purchased car even when standing beside it")
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
		await _position(city.interior_origin(cottage))
		check((await _action("exit")).ok,"restored owner physically leaves the saved room")
		await _position(Plan.building(expected.dealer).door)
		check(city.cached_view.owned_vehicles.size()==1 and city.cached_view.owned_vehicles[0].id==expected.vehicle,"same authenticated identity retains its exact vehicle after restart")
		var collected=await _action("recall_vehicle",{"building":expected.dealer,"vehicle":expected.vehicle})
		print("CITYNET COLLECT ok=%s message=%s vehicle=%s registered=%s"%[collected.get("ok"),collected.get("message"),collected.get("vehicle",{}),net.vehicle_spawn_definitions.has(expected.vehicle)])
		check(collected.ok and net.vehicle_spawn_definitions.has(expected.vehicle),"saved car can be delivered again after restarting the authority")
	net.shutdown()
	await create_timer(0.15).timeout
	_finish()

func _action(kind: String, payload: Dictionary = {}) -> Dictionary:
	var requested: Dictionary = city.request(kind, payload)
	if not requested.get("pending", false): return requested
	var deadline = Time.get_ticks_msec() + 7000
	while not replies.has(requested.request) and Time.get_ticks_msec() < deadline: await process_frame
	if not replies.has(requested.request): check(false, "reply for " + kind)
	await create_timer(0.22).timeout
	return replies.get(requested.request, {"ok": false, "message": "Timed out"})

func _dealer()->Dictionary:
	for record in Plan.block_buildings(Vector2i(10,8)):
		if Commerce.category(record)=="dealership":return record
	return {}

func _position(point: Vector3) -> void:
	# State uses an unreliable lane, independently of reliable action replies.
	# Observe the server fixture's received position before requesting a service;
	# a fixed 300 ms sleep could race restart/bootstrap traffic on this machine.
	var deadline = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		net.send_state(point, 0.0, Vector3.ZERO, 0, false, Vector3.ZERO, 0.0,
			PackedVector3Array(), net.WEAPON_REVOLVER, false, true, 6, false, 0.0)
		await create_timer(0.06).timeout
		var observed: Variant = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("observed-positions")))
		if observed is Dictionary:
			var actual: Array = observed.get(str(net.local_id()), [])
			if actual.size() == 3 and Vector3(actual[0], actual[1], actual[2]).distance_to(point) < 0.02:
				return
	check(false, "server receives physical position %s before service request" % str(point))

func _write(name: String, data: Dictionary) -> void:
	var file = FileAccess.open(directory.path_join(name), FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func _finish() -> void:
	if done: return
	done = true
	print("CITYNETWORK_%s %d/%d %s" % [role.to_upper(), passed, checks, "PASS" if checks == passed else "FAIL"])
	quit(0 if checks == passed else 1)
