extends Node
## Small, authenticated city requests use the existing reliable action lane.
signal updated
signal finished(serial: int, kind: String, result: Dictionary)
const Plan = preload("res://scripts/city_plan.gd")
const Rooms = preload("res://scripts/city_interior.gd")
const MAX_PACKET := 49152
const BUS_FARE := 6
var frontier: Node
var cached_view: Dictionary = {}
var _serial := 0
var _requests: Dictionary = {}
var _interiors: Dictionary = {}
var _highest: Dictionary = {}
var _received: Dictionary = {}
var _revision := -1

func _ready() -> void:
	frontier = get_parent()
	process_mode = Node.PROCESS_MODE_ALWAYS

func reset() -> void:
	cached_view.clear()
	_requests.clear()
	_interiors.clear()
	_highest.clear()
	_received.clear()
	_revision = -1

func unregister_peer(peer: int) -> void:
	_requests.erase(peer)
	_interiors.erase(peer)
	_highest.erase(peer)

func request(kind: String, payload: Dictionary = {}) -> Dictionary:
	_serial += 1
	if frontier.authoritative:
		var result := _handle(frontier.net.local_id(), _serial, kind, payload)
		_receive(_serial, kind, result)
		return result
	rpc_id(1, "sv_request", _serial, kind, payload)
	return {"ok": true, "pending": true, "request": _serial}

@rpc("any_peer", "call_remote", "reliable", 2)
func sv_request(serial: int, kind: String, payload: Dictionary) -> void:
	if not frontier.authoritative or not frontier.society_ready: return
	var peer := multiplayer.get_remote_sender_id()
	if not frontier.net.names.has(peer) or not frontier.net._allow_rate(peer, "city", 5): return
	var result := _handle(peer, serial, kind, payload)
	rpc_id(peer, "cl_result", serial, kind.left(32), bounded_reply(result))

func _handle(peer: int, serial: int, kind: String, payload: Dictionary) -> Dictionary:
	if not frontier.society_ready or not frontier.storage_error.is_empty():
		return _failure("City services are not ready. Please try again shortly.")
	if serial <= 0 or serial > 2147483647 or kind.length() > 32 \
			or payload.size() > 6 or not _payload_valid(payload):
		return _failure("Invalid city request.")
	var identity: String = frontier._identity(peer)
	if identity.is_empty(): return _failure("An authenticated resident is required.")
	var signature := var_to_bytes([kind, payload]).hex_encode()
	var records: Dictionary = _requests.get(peer, {})
	if records.has(serial):
		return records[serial].result if records[serial].signature == signature \
			else _failure("This request number has already been used.")
	if serial <= int(_highest.get(peer, 0)): return _failure("This request has expired. Please open the service again.")
	_highest[peer] = serial
	var result: Dictionary
	if kind == "inspect":
		result = {"ok": true, "message": ""}
	else:
		result = _apply(peer, identity, kind, payload)
	result["view"] = frontier.societies.city_view(identity, str(_interiors.get(peer, "")))
	var member: Dictionary = frontier.societies.state.players.get("member_" + identity, {})
	if not member.is_empty():
		frontier._sequence += 1
		result["revision"] = frontier._sequence
		result["player_patch"] = {"accounts": {"player": int(member.credits)},
			"inventories": {"player_earth": member.inventories.earth.duplicate(true),
				"player_moon": member.inventories.moon.duplicate(true)}}
	# Cache only bounded action results. Views refresh when a request is retried;
	# the immutable mutation outcome and transition remain exactly once.
	records[serial] = {"signature": signature, "result": result.duplicate(true)}
	while records.size() > 24: records.erase(records.keys()[0])
	_requests[peer] = records
	return result

func _apply(peer: int, identity: String, kind: String, payload: Dictionary) -> Dictionary:
	var net: Node = frontier.net
	if not net._peer_on_foot_position_in_realm(peer, net.PlayerRealm.EARTH) \
			or net._peer_has_vehicle_claim(peer):
		return _failure("Step out of your vehicle on Earth to use this service.")
	var position: Vector3 = net._peer_on_foot_positions[peer]
	var mutates := kind not in ["enter", "exit"]
	var checkpoint: Dictionary = frontier.societies.export_state() if mutates else {}
	var previous_room: String = str(_interiors.get(peer, ""))
	var result: Dictionary
	if kind in ["enter", "exit", "transit"]:
		result = _transition(peer, identity, kind, payload, position)
	else:
		var inside := false
		if not previous_room.is_empty():
			var room: Dictionary = Plan.building(previous_room)
			if not room.is_empty() and (kind in ["start_job", "finish_job"] \
					or str(payload.get("building", payload.get("property", payload.get("id", "")))) == previous_room):
				var translated := room_action_position(room, position, kind)
				inside = translated != Vector3.INF
				if inside: position = translated
		if kind in ["store_item", "take_item", "set_home"] and not inside:
			return _failure("Enter your home and use its cupboard or bed.")
		result = frontier.societies.city_action(identity, kind, payload, position)
	if result.get("ok", false) and mutates and frontier.persistence_enabled \
			and not frontier.societies.save_game(frontier.storage_path):
		frontier.societies.import_state(checkpoint)
		if previous_room.is_empty(): _interiors.erase(peer)
		else: _interiors[peer] = previous_room
		return _failure("The city could not save this change. Nothing was charged or moved.")
	return result

func _transition(peer: int, identity: String, kind: String, payload: Dictionary,
		position: Vector3) -> Dictionary:
	if kind == "enter":
		var b: Dictionary = Plan.building(str(payload.get("id", "")))
		if b.is_empty() or position.distance_to(b.door) > 7.5:
			return _failure("Walk to this building's entrance first.")
		_interiors[peer] = b.id
		return {"ok": true, "message": "Welcome to " + str(b.name), "enter": b.id}
	if kind == "exit":
		var b: Dictionary = Plan.building(str(_interiors.get(peer, "")))
		if b.is_empty() or position.distance_to(interior_origin(b)) > 50.0:
			return _failure("Use the exit inside your current building.")
		_interiors.erase(peer)
		return {"ok": true, "message": "Back outside.", "destination": b.door + Vector3(0, 1.2, 2)}
	var origin: Dictionary = {}
	var destination: Dictionary = {}
	for stop: Dictionary in Plan.stops():
		if position.distance_to(stop.position) <= 7.5: origin = stop
		if stop.id == str(payload.get("id", "")): destination = stop
	if origin.is_empty() or destination.is_empty() or origin.id == destination.id:
		return _failure("Visit a transit stop and choose another destination.")
	var sim = frontier.societies.simulations.canopy
	var actor := "member_" + identity
	if sim.balance(actor) < BUS_FARE: return _failure("A city transit ticket costs 6 credits.")
	sim._transfer(actor, "treasury", BUS_FARE, "Crownreach transit ticket")
	_interiors.erase(peer)
	return {"ok": true, "message": "Arrived at " + str(destination.name),
		"destination": destination.position + Vector3(0, 1.2, 0)}

static func interior_origin(building: Dictionary) -> Vector3:
	var door: Vector3 = building.door
	return Vector3(door.x, -500.0, door.z)

static func room_action_position(building: Dictionary, position: Vector3, kind: String) -> Vector3:
	var service_kind := "storage" if kind in ["store_item", "take_item"] else "bed" \
		if kind == "set_home" else "interior" if kind in ["start_job", "finish_job"] else ""
	if service_kind.is_empty(): return Vector3.INF
	for point: Dictionary in Rooms.service_layout(building).values():
		if point.kind == service_kind and position.distance_to(interior_origin(building) + point.position) <= Rooms.INTERACTION_RANGE:
			return building.door
	return Vector3.INF

static func _payload_valid(payload: Dictionary) -> bool:
	for key in payload:
		if not key is String or key not in ["id", "building", "property", "item", "quantity", "job", "target"]: return false
		var value: Variant = payload[key]
		if value is String:
			if value.length() > 96: return false
		elif value is int:
			if value < 0 or value > 100000: return false
		else: return false
	return true

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "message": message}

static func bounded_reply(result: Dictionary) -> Dictionary:
	if var_to_bytes(result).size() <= MAX_PACKET: return result
	# Never hide a committed transaction behind a dropped oversized snapshot.
	# The accepted action/teleport and real wallet patch still reach the caller.
	var compact := result.duplicate(true)
	compact.erase("view")
	compact["refresh_required"] = true
	compact["message"] = str(result.get("message", "")) + " City details could not refresh. Reopen this menu."
	return compact

@rpc("authority", "call_remote", "reliable", 2)
func cl_result(serial: int, kind: String, result: Dictionary) -> void:
	if var_to_bytes(result).size() <= MAX_PACKET: _receive(serial, kind, result)

func _receive(serial: int, kind: String, result: Dictionary) -> void:
	if _received.has(serial): return
	_received[serial] = true
	while _received.size() > 64: _received.erase(_received.keys()[0])
	if result.get("player_patch") is Dictionary and int(result.get("revision", -1)) >= 0:
		frontier._remember_shared_player(result.player_patch, int(result.revision))
		frontier._refresh_cached_player("")
	if result.get("view") is Dictionary and int(result.get("revision", -1)) >= _revision:
		_revision = int(result.get("revision", -1))
		cached_view = result.view.duplicate(true)
		updated.emit()
	finished.emit(serial, kind, result)
