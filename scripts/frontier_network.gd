class_name FrontierNetwork
extends Node
## The server owns ledgers, claims, arrival-gated jobs and durable checkpoints.
## Clients receive a personalized town view and request small, validated actions.

signal state_changed(town_id: String)
signal traffic_changed(town_id: String, rows: Array)
signal action_finished(request: int, kind: String, result: Dictionary)

const STATE_FILE := "frontier_societies.json"
const MAX_VIEW_BYTES := 262144
const MAX_TRAFFIC_BYTES := 32768
const ACTIONS := ["claim_town", "plant", "harvest", "water", "fertilize", "clear_plot",
	"toggle_plot", "buy", "sell", "accept_quest", "deliver_quest", "cancel_quest",
	"assign_job", "toggle_worker", "repair", "refill_habitat", "build_solar",
	"upgrade_battery", "refuel", "process", "ship", "inspect"]
const PAYLOAD_KEYS := ["plot", "crop", "quantity", "item", "market", "id", "citizen",
	"job", "facility", "recipe", "vehicle", "from", "to", "target", "source"]

var net: Node
var societies: RefCounted
var catalog: Array = []
var views: Dictionary = {}
var traffic_views: Dictionary = {}
var authoritative := false
var society_ready := false
var persistence_enabled := false
var storage_path := ""
var storage_error := ""
var _watch: Dictionary = {}
var _requests: Dictionary = {}
var _serial := 0
var _sequence := 0
var _view_sequence := -1
var _traffic_sequence := -1
var _snapshot_remaining := 0.0
var _save_remaining := 5.0
var _traffic_remaining := 0.0
var _physics_root: Node3D
var _physics_viewport: SubViewport
var _moon_sampler: MoonWorld
var sites: Dictionary = {}
var traffic: Dictionary = {}
var _build_queue: Array = []
var _vehicle_motion: Dictionary = {}


func _ready() -> void:
	net = get_parent()
	process_mode = Node.PROCESS_MODE_ALWAYS


func start_authority(seed_value: int, persist := false) -> Error:
	stop()
	authoritative = true
	persistence_enabled = persist
	storage_path = net._state_file_path(STATE_FILE) if persist else ""
	var configured := OS.get_environment("TROOP_STATE_DIR").strip_edges()
	if persist and not configured.is_empty() and storage_path.get_base_dir() != configured.simplify_path():
		storage_error = "The configured persistent town directory is unavailable."
		return ERR_FILE_CANT_WRITE
	societies = load("res://scripts/frontier_societies.gd").new()
	if persist and (FileAccess.file_exists(storage_path) or FileAccess.file_exists(storage_path + ".bak")):
		if not societies.load_game(storage_path):
			storage_error = "The shared society save could not be recovered. Existing files were preserved."
			return ERR_FILE_CORRUPT
	else:
		societies.new_game(seed_value)
	if persist and not societies.save_game(storage_path):
		storage_error = "Shared society storage is not writable."
		return ERR_FILE_CANT_WRITE
	catalog = societies.towns()
	society_ready = true
	# A listen host also renders client town colliders. Authority physics gets
	# its own space so those replicas cannot collide with the server vehicles.
	_physics_viewport = SubViewport.new()
	_physics_viewport.name = "SharedTownAuthoritySpace"
	_physics_viewport.own_world_3d = true
	_physics_viewport.size = Vector2i(2, 2)
	_physics_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_physics_viewport)
	_physics_root = Node3D.new()
	_physics_root.name = "SharedTownPhysics"
	_physics_viewport.add_child(_physics_root)
	# Lazy pure terrain queries without constructing lunar rendering resources.
	_moon_sampler = MoonWorld.new()
	_moon_sampler.begin_setup(seed_value ^ 0x4d4f4f4e)
	_physics_root.add_child(_moon_sampler)
	_moon_sampler.position = Vector3(0, net.MOON_WORLD_ORIGIN_Y, 0)
	for town: Dictionary in catalog:
		# Site's renderer-facing World type loads the complete terrain scene.
		# Only an authority needs these nodes; connection-only clients must not
		# compile that graph synchronously while Net.join wires the RPC endpoint.
		var site: Node3D = load("res://scripts/frontier_site.gd").new()
		site.name = str(town.id)
		site.planet = str(town.planet)
		site.town_id = str(town.id)
		site.moon = _moon_sampler if town.planet == "moon" else null
		_physics_root.add_child(site)
		site.global_transform = FrontierTownLayout.world_frame(town, _moon_sampler)
		sites[town.id] = site
		if town.planet == "earth":
			_build_queue.append(town)
	return OK


func stop() -> void:
	if authoritative and societies and persistence_enabled and society_ready:
		if not societies.save_game(storage_path):
			push_error("Shared society checkpoint could not be saved at shutdown.")
	if is_instance_valid(_physics_viewport):
		remove_child(_physics_viewport)
		_physics_viewport.queue_free()
	_physics_viewport = null
	_physics_root = null
	_moon_sampler = null
	societies = null
	authoritative = false
	society_ready = false
	persistence_enabled = false
	storage_error = ""
	catalog.clear()
	views.clear()
	traffic_views.clear()
	sites.clear()
	traffic.clear()
	_build_queue.clear()
	_watch.clear()
	_requests.clear()
	_vehicle_motion.clear()
	_serial = 0
	_view_sequence = -1
	_traffic_sequence = -1


func register_peer(peer_id: int) -> void:
	if not society_ready or not authoritative:
		return
	var identity := _identity(peer_id)
	if identity.is_empty():
		return
	var checkpoint: Dictionary = societies.export_state() if persistence_enabled else {}
	var registration: Dictionary = societies.ensure_player(identity, str(net.names.get(peer_id, "Monkey")))
	if registration.get("ok", false) and persistence_enabled and not societies.save_game(storage_path):
		societies.import_state(checkpoint)
		registration = _failure("Town storage is unavailable; your registration was not charged.")
	if not registration.get("ok", false):
		if peer_id != net.local_id():
			rpc_id(peer_id, "cl_result", 0, "join", registration)
		return
	_watch[peer_id] = "canopy_earth"
	# Bootstrap every town once for distant scenery and the personal map.
	# Thereafter only the currently visited town gets live economy updates.
	for town: Dictionary in catalog:
		_send_view(peer_id, str(town.id))


func unregister_peer(peer_id: int) -> void:
	_watch.erase(peer_id)
	_requests.erase(peer_id)


func _identity(peer_id: int) -> String:
	return str(net._peer_key_fingerprints.get(peer_id, ""))


func _process(delta: float) -> void:
	if not society_ready or not authoritative or not net.active or not net.is_host:
		return
	if not _build_queue.is_empty():
		_build_physics_town(_build_queue.pop_front())
	societies.tick(minf(delta, 0.25))
	_tick_player_fuel(minf(delta, 0.25))
	_snapshot_remaining -= delta
	_save_remaining -= delta
	_traffic_remaining -= delta
	if _snapshot_remaining <= 0:
		_snapshot_remaining = 1.0
		for peer_id in _watch.keys():
			_send_view(int(peer_id))
	if _traffic_remaining <= 0:
		_traffic_remaining = 0.10
		_update_traffic_obstacles()
		for peer_id in _watch.keys():
			_send_traffic(int(peer_id))
	if _save_remaining <= 0:
		_save_remaining = 5.0
		if persistence_enabled and not societies.save_game(storage_path):
			storage_error = "Town storage is temporarily unavailable. Management is paused."
		elif not storage_error.is_empty():
			storage_error = ""


func _exit_tree() -> void:
	if authoritative and society_ready and persistence_enabled and societies:
		if not societies.save_game(storage_path):
			push_error("Could not persist the shared town on exit.")


func prepare_player_vehicle(vehicle_id: String, kind: int, peer_id: int) -> bool:
	if not authoritative or not society_ready or not storage_error.is_empty():
		return false
	if not societies.state.vehicle_fuel.has(vehicle_id):
		var checkpoint: Dictionary = societies.export_state() if persistence_enabled else {}
		var tank: Dictionary = societies.register_vehicle(vehicle_id, kind)
		if tank.is_empty():
			var result := _failure("This server's vehicle registry is full. Choose a previously used vehicle.")
			if peer_id != net.local_id():
				rpc_id(peer_id, "cl_result", 0, "vehicle", result)
			else:
				action_finished.emit(0, "vehicle", result)
			return false
		if persistence_enabled and not societies.save_game(storage_path):
			societies.import_state(checkpoint)
			storage_error = "Vehicle storage is unavailable. Please try again shortly."
			return false
	_vehicle_motion[vehicle_id] = net._vehicle_positions.get(vehicle_id, Vector3.ZERO)
	_send_view(peer_id)
	return true


func _tick_player_fuel(delta: float) -> void:
	# Meter accepted seat ownership and movement on the authority. The client
	# never supplies fuel levels, prices or quantities consumed.
	for vehicle_id in net.claimed_vehicles:
		if not societies.state.vehicle_fuel.has(vehicle_id):
			continue
		var position: Vector3 = net._vehicle_positions.get(vehicle_id, Vector3.ZERO)
		var previous: Vector3 = _vehicle_motion.get(vehicle_id, position)
		_vehicle_motion[vehicle_id] = position
		var peer_id := int(net.claimed_vehicles[vehicle_id])
		var distance: float = net._realm_distance(position, previous, net.player_realm(peer_id))
		var kind := int(net._vehicle_kinds.get(vehicle_id, 1))
		societies.consume_vehicle_fuel(vehicle_id, metered_fuel(kind, delta, distance))
	for vehicle_id in _vehicle_motion.keys():
		if not net.claimed_vehicles.has(vehicle_id):
			_vehicle_motion.erase(vehicle_id)


static func metered_fuel(kind: int, elapsed: float, distance: float) -> float:
	# Idle burn integrates elapsed time; traction burn integrates accepted
	# distance. Repeated positions between 20 Hz packets cannot reduce either.
	var idle := 0.006
	var per_meter := 0.032 / 22.0
	if kind == Vehicle.Kind.JET:
		idle = 0.12
		per_meter = 0.52 / 150.0
	elif kind == Vehicle.Kind.BOAT:
		idle = 0.015
		per_meter = 0.055 / 18.0
	return idle * maxf(0, elapsed) + per_meter * maxf(0, distance)


func _build_physics_town(town: Dictionary) -> void:
	var site: Node3D = sites[town.id]
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 2, 400)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	site.add_child(floor_body)
	floor_body.position.y = FrontierTownLayout.GROUND_HEIGHT - 1.0
	# Use the same authored solid footprints as the visible client town.
	var settlement = load("res://scripts/frontier_settlement.gd").new()
	settlement.configure(site, societies.simulations[town.society_id], "earth", town)
	site.add_child(settlement)
	settlement.build_collision_only()
	var driver = load("res://scripts/frontier_traffic.gd").new()
	site.add_child(driver)
	driver.configure(societies.simulations[town.society_id], site, true, str(town.id))
	driver.build()
	traffic[town.id] = driver


func _update_traffic_obstacles() -> void:
	var points: Array = []
	for position in net._peer_on_foot_positions.values():
		if position is Vector3:
			points.append(position)
	for position in net._vehicle_positions.values():
		if position is Vector3:
			points.append(position)
	for driver in traffic.values():
		driver.set_obstacles(points)


func town_info(town_id: String) -> Dictionary:
	for town: Dictionary in catalog:
		if str(town.get("id", "")) == town_id:
			return town
	return {}


func nearest_town(position: Vector3, planet: String) -> String:
	var best := INF
	var found := ""
	for town: Dictionary in catalog:
		if town.planet != planet:
			continue
		var origin: Vector3
		if authoritative:
			origin = sites[town.id].global_position
		elif town.planet == "earth":
			origin = Vector3(float(town.origin[0]), FrontierTownLayout.GROUND_HEIGHT, float(town.origin[1]))
		else:
			var raw: Array = town.moon_direction
			var normal := Vector3(float(raw[0]), float(raw[1]), float(raw[2])).normalized()
			origin = Vector3(0, net.MOON_WORLD_ORIGIN_Y, 0) + MoonWorld.PLAYABLE_CENTER \
				+ normal * MoonWorld.PLAYABLE_RADIUS_METERS
		var distance := position.distance_squared_to(origin)
		if distance < best:
			best = distance
			found = str(town.id)
	return found


func watch_town(town_id: String) -> void:
	if not net.active or town_info(town_id).is_empty():
		return
	if authoritative:
		_watch[net.local_id()] = town_id
		_send_view(net.local_id())
	else:
		rpc_id(1, "sv_watch", town_id)


@rpc("any_peer", "call_remote", "reliable", 0)
func sv_watch(town_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not authoritative or not net._registered_peer(sender) \
			or not net._allow_rate(sender, "frontier_watch", 3):
		return
	var town := town_info(town_id)
	if town.is_empty() or not _near_town(sender, town, 650.0, false):
		return
	_watch[sender] = town_id
	_send_view(sender)


func request_action(town_id: String, kind: String, payload: Dictionary) -> Dictionary:
	_serial += 1
	if authoritative:
		var result := _handle_action(net.local_id(), _serial, town_id, kind, payload)
		_send_view(net.local_id())
		return result
	if not society_ready or not net.active:
		return {"ok": false, "message": "Waiting for the shared town to connect."}
	rpc_id(1, "sv_action", _serial, town_id, kind, payload)
	return {"ok": false, "pending": true, "message": "Waiting for the town…", "request": _serial}


@rpc("any_peer", "call_remote", "reliable", 0)
func sv_action(request: int, town_id: String, kind: String, payload: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not authoritative or not net._registered_peer(sender):
		return
	if not net._allow_rate(sender, "frontier_action", 6):
		if net._allow_rate(sender, "frontier_busy", 2):
			rpc_id(sender, "cl_result", request, kind.left(32), _failure("Please wait a moment before another town action."))
		return
	var result := _handle_action(sender, request, town_id, kind, payload)
	rpc_id(sender, "cl_result", request, kind, result)
	_send_view(sender)


func _handle_action(sender: int, request: int, town_id: String,
		kind: String, payload: Dictionary) -> Dictionary:
	if not society_ready or not authoritative or _identity(sender).is_empty():
		return _failure("The town has not authenticated this player.")
	if request < 1 or request > 2147483647 or town_id.length() > 32 or kind not in ACTIONS or not _valid_payload(payload):
		return _failure("Invalid town request.")
	var previous: Dictionary = _requests.get(sender, {})
	if request <= int(previous.get("serial", 0)):
		if request == int(previous.get("serial", 0)) and previous.get("town") == town_id \
				and previous.get("kind") == kind and previous.get("payload") == payload:
			return previous.result.duplicate(true)
		return _failure("That town request has already been processed.")
	var result := _apply_action(sender, town_id, kind, payload)
	_requests[sender] = {"serial": request, "town": town_id, "kind": kind,
		"payload": payload.duplicate(true), "result": result.duplicate(true)}
	return result


func _apply_action(sender: int, town_id: String, kind: String, payload: Dictionary) -> Dictionary:
	if not storage_error.is_empty():
		return _failure(storage_error)
	var town := town_info(town_id)
	if town.is_empty() or not _near_town(sender, town, 220.0):
		return _failure("Visit this town on the correct world first.")
	if not _workplace_in_range(sender, town, kind, payload):
		return _failure("Walk to the relevant person or workplace first.")
	var checkpoint: Dictionary = societies.export_state() if persistence_enabled or kind == "refuel" else {}
	if kind == "refuel":
		societies.register_vehicle(str(payload.vehicle), int(net._vehicle_kinds[payload.vehicle]))
	var action_payload := payload.duplicate(true)
	action_payload.erase("source")
	var result: Dictionary = societies.action(_identity(sender), town_id, kind, action_payload)
	if not result.get("ok", false) and kind == "refuel":
		societies.import_state(checkpoint)
	if bool(result.get("ok", false)) and persistence_enabled:
		if not societies.save_game(storage_path):
			societies.import_state(checkpoint)
			storage_error = "The town could not save this change; nothing was charged or transferred."
			return _failure(storage_error)
	catalog = societies.towns()
	return result


func _near_town(peer_id: int, town: Dictionary, radius: float, on_foot := true) -> bool:
	var realm: int = net.PlayerRealm.MOON if town.planet == "moon" else net.PlayerRealm.EARTH
	if net.player_realm(peer_id) != realm:
		return false
	var position := Vector3.INF
	if net._peer_on_foot_position_in_realm(peer_id, realm) and not net._peer_has_vehicle_claim(peer_id):
		position = net._peer_on_foot_positions[peer_id]
	elif not on_foot:
		for vehicle_id in net.claimed_vehicles:
			if int(net.claimed_vehicles[vehicle_id]) == peer_id:
				position = net._vehicle_positions.get(vehicle_id, Vector3.INF)
	return position != Vector3.INF and position.distance_to(sites[town.id].global_position) <= radius


func _workplace_in_range(peer_id: int, town: Dictionary, kind: String, payload: Dictionary) -> bool:
	var sim: RefCounted = societies.simulations[town.society_id]
	var state: Dictionary = sim.state
	var target := ""
	match kind:
		"claim_town": target = "town_square"
		"plant", "harvest", "water", "fertilize", "clear_plot", "toggle_plot":
			target = str(payload.get("plot", ""))
		"assign_job", "toggle_worker": target = str(payload.get("citizen", ""))
		"buy", "sell": target = str(payload.get("market", ""))
		"accept_quest", "cancel_quest", "deliver_quest":
			var quest: Dictionary = state.quests.get(str(payload.get("id", "")), {})
			target = str(quest.get("destination" if kind == "deliver_quest" else "giver", ""))
		"repair", "refuel": target = str(payload.get("facility", ""))
		"build_solar", "upgrade_battery": target = "solar_array"
		"refill_habitat": target = "lunar_greenhouse"
		"ship": target = "cargo" if town.planet == "moon" else "warehouse"
		"process": target = "refinery" if payload.get("recipe") == "refine" else "workshop"
		"inspect": target = str(payload.get("target", ""))
	if target.is_empty():
		return false
	var source := str(payload.get("source", ""))
	# A merchant can serve a customer at the NPC's real position. The source
	# is checked against the trusted profession; it cannot redirect stock.
	if kind in ["buy", "sell"] and state.citizens.has(source):
		var trader: Dictionary = state.citizens[source]
		var service := str(town.planet) + "_market" if trader.job == "merchant" \
			else "refinery" if trader.job == "refinery_operator" else ""
		if service == target and trader.planet == town.planet:
			target = source
	if kind in ["accept_quest", "cancel_quest"] and source == "town_square":
		target = "town_square"
	var local := Vector2.INF
	local = FrontierServicePoints.service_position(str(town.planet), target)
	var objects: Array = [state.get("plots", {}), state.get("citizens", {}), state.get("locations", {}), state.get("facilities", {})]
	for objects_by_id: Dictionary in objects:
		if local != Vector2.INF:
			break
		if objects_by_id.has(target):
			var item: Dictionary = objects_by_id[target]
			if item.get("planet", "earth") != town.planet:
				return false
			var coordinates: Array = item.get("position", [])
			if coordinates.size() == 2:
				local = Vector2(float(coordinates[0]), float(coordinates[1]))
				break
	if local == Vector2.INF:
		return false
	var site: Node3D = sites[town.id]
	var position: Vector3 = site.surface_point(local.x, local.y, 0.8)
	var range_limit := 18.0 if kind == "refuel" else 7.5
	if net._peer_on_foot_positions[peer_id].distance_to(position) > range_limit:
		return false
	if kind == "refuel":
		var vehicle_id := str(payload.get("vehicle", ""))
		if not net._vehicle_positions.has(vehicle_id) or not net._vehicle_kinds.has(vehicle_id):
			return false
		if net.claimed_vehicles.has(vehicle_id) \
				or net._vehicle_positions[vehicle_id].distance_to(position) > 18.0:
			return false
		var rest: Array = net.vehicle_rests.get(vehicle_id, [])
		if not rest.is_empty() and (not net._valid_vehicle_rest(rest)):
			return false
	return true


static func _valid_payload(payload: Dictionary) -> bool:
	if payload.size() > 10:
		return false
	for key in payload:
		if not key is String or key not in PAYLOAD_KEYS:
			return false
		var value: Variant = payload[key]
		if value is String:
			if value.length() > 96:
				return false
		elif value is float:
			if not is_finite(value) or absf(value) > 1000000:
				return false
		elif value is int:
			if absi(value) > 1000000:
				return false
		elif not value is bool:
			return false
	return true


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "message": message}


func _send_view(peer_id: int, requested_town := "") -> void:
	var identity := _identity(peer_id)
	if identity.is_empty():
		return
	var town_id := requested_town if not requested_town.is_empty() else str(_watch.get(peer_id, "canopy_earth"))
	var view: Dictionary = societies.view(identity, town_id)
	var towns: Array = societies.towns(identity)
	_sequence += 1
	if var_to_bytes(view).size() > MAX_VIEW_BYTES:
		push_error("Shared society view exceeded its bounded packet budget.")
		return
	if peer_id == net.local_id():
		_apply_view(town_id, _sequence, view, towns)
	else:
		rpc_id(peer_id, "cl_state", town_id, _sequence, view, towns)


func _send_traffic(peer_id: int) -> void:
	var town_id := str(_watch.get(peer_id, ""))
	if not traffic.has(town_id):
		return
	var rows: Array = traffic[town_id].snapshot()
	if rows.size() > 32 or var_to_bytes(rows).size() > MAX_TRAFFIC_BYTES:
		return
	_sequence += 1
	if peer_id == net.local_id():
		traffic_views[town_id] = rows
		traffic_changed.emit(town_id, rows)
	else:
		var packet := pack_traffic(rows)
		if var_to_bytes(packet).size() <= 1100:
			rpc_id(peer_id, "cl_traffic", town_id, _sequence, packet)


static func pack_traffic(rows: Array) -> Array:
	var packet: Array = []
	for row: Dictionary in rows.slice(0, 5):
		var values := PackedFloat32Array()
		for field in ["position", "rotation", "velocity"]:
			for value in row[field]:
				values.append(float(value))
		values.append(float(row.get("rpm", 0.0)))
		values.append(float(row.get("steer", 0.0)))
		values.append(float(maxi(0,["driving","walking","boarding"].find(str(row.get("mode","driving"))))))
		packet.append([str(row.worker), values])
	return packet


static func unpack_traffic(town_id: String, packet: Array) -> Array:
	var rows: Array = []
	for record in packet:
		if not record is Array or record.size() != 2 or not record[0] is String \
				or record[0].length() > 32 or not record[1] is PackedFloat32Array or record[1].size() not in [11,12]:
			return []
		var values: PackedFloat32Array = record[1]
		for value in values:
			if not is_finite(value):
				return []
		var mode := 0
		if values.size()==12:
			if values[11]!=floorf(values[11]) or values[11]<0.0 or values[11]>2.0: return []
			mode=int(values[11])
		rows.append({"town": town_id, "worker": record[0], "mode":["driving","walking","boarding"][mode],
			"position": [values[0], values[1], values[2]],
			"rotation": [values[3], values[4], values[5]],
			"velocity": [values[6], values[7], values[8]], "rpm": values[9], "steer": values[10]})
	return rows


@rpc("authority", "call_remote", "reliable", 0)
func cl_state(town_id: String, sequence: int, view: Dictionary, towns: Array) -> void:
	if authoritative or not net.active or multiplayer.get_remote_sender_id() != 1:
		return
	if towns.size() > 6 or var_to_bytes(towns).size() > 16384 \
			or var_to_bytes(view).size() > MAX_VIEW_BYTES:
		return
	_apply_view(town_id, sequence, view, towns)


func _apply_view(town_id: String, sequence: int, view: Dictionary, towns: Array) -> void:
	if sequence <= _view_sequence or town_id.length() > 32 or view.is_empty():
		return
	_view_sequence = sequence
	catalog = towns
	views[town_id] = view
	society_ready = true
	state_changed.emit(town_id)


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func cl_traffic(town_id: String, sequence: int, packet: Array) -> void:
	if authoritative or not net.active or multiplayer.get_remote_sender_id() != 1 \
			or sequence <= _traffic_sequence or packet.size() > 5 \
			or var_to_bytes(packet).size() > 1100 or town_info(town_id).is_empty():
		return
	var rows := unpack_traffic(town_id, packet)
	if rows.size() != packet.size():
		return
	_traffic_sequence = sequence
	traffic_views[town_id] = rows
	traffic_changed.emit(town_id, rows)


@rpc("authority", "call_remote", "reliable", 0)
func cl_result(_request: int, kind: String, result: Dictionary) -> void:
	if authoritative or not net.active or multiplayer.get_remote_sender_id() != 1 \
			or var_to_bytes(result).size() > 4096:
		return
	if kind == "join" and not result.get("ok", false):
		net.net_error.emit(str(result.get("message", "Town registration failed.")))
	action_finished.emit(_request, kind, result)
