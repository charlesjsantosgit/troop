extends Node
## Small, authenticated city requests use the existing reliable action lane.
signal updated
signal finished(serial: int, kind: String, result: Dictionary)
const Plan = preload("res://scripts/city_plan.gd")
const Rooms = preload("res://scripts/city_interior.gd")
const Furniture = preload("res://scripts/city_furniture.gd")
const Motion=preload("res://scripts/city_furniture_motion.gd")
const MAX_PACKET := 65536
const BUS_FARE := 6
const ACTIONS := ["life_consume", "life_rest", "life_clinic", "inspect", "enter", "exit", "transit", "buy_home", "store_item", "take_item", "set_home", "start_job", "finish_job", "buy_store_item", "buy_vehicle", "recall_vehicle", "use_furniture", "leave_furniture", "cancel_furniture"]
var frontier: Node
var cached_view: Dictionary = {}
var _serial := 0
var _requests: Dictionary = {}
var _interiors: Dictionary = {}
var _furniture: Dictionary = {}
var _remote_furniture:Dictionary = {}
var _remote_rooms:Dictionary = {}
var _geometry_guard:Node
var _highest: Dictionary = {}
var _received: Dictionary = {}
var _revision := -1

func _ready() -> void:
	frontier = get_parent()
	process_mode = Node.PROCESS_MODE_ALWAYS
	_geometry_guard=preload("res://scripts/city_furniture_authority.gd").new()
	add_child(_geometry_guard)

func reset() -> void:
	cached_view.clear()
	_requests.clear()
	_interiors.clear()
	_furniture.clear()
	_remote_furniture.clear()
	_remote_rooms.clear()
	_highest.clear()
	_received.clear()
	_revision = -1

func unregister_peer(peer: int) -> void:
	_publish_room(peer,"")
	_requests.erase(peer)
	_interiors.erase(peer)
	_furniture.erase(peer)
	_publish_motion(peer,{})
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
	if serial <= 0 or serial > 2147483647 or kind not in ACTIONS \
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
		if is_instance_valid(frontier) and frontier.authoritative and multiplayer.has_multiplayer_peer() and peer!=frontier.net.local_id():
			for occupant in _furniture:rpc_id(peer,"cl_furniture_motion",int(occupant),_furniture[occupant])
			for occupant in _interiors:rpc_id(peer,"cl_furniture_room",int(occupant),str(_interiors[occupant]))
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
	if kind in ["use_furniture", "leave_furniture", "cancel_furniture"]:
		var previous:Dictionary=_furniture.get(peer,{}).duplicate(true)
		var outcome:=_furniture_action(peer,kind,payload,position,false)
		if outcome.get("ok",false) and kind in ["use_furniture","leave_furniture"]:
			var room:=Plan.building(str(_interiors.get(peer,"")))
			if not is_instance_valid(_geometry_guard) or not _geometry_guard.check_path(room,_furniture[peer].motion_path,interior_origin(room)):
				if previous.is_empty():_furniture.erase(peer)
				else:_furniture[peer]=previous
				_publish_motion(peer,previous)
				return _failure(_geometry_guard.last_error if is_instance_valid(_geometry_guard) else "Furniture collision is not ready.")
		if outcome.get("ok",false):_publish_motion(peer,_furniture.get(peer,{}))
		return outcome
	if kind=="recall_vehicle" and net.claimed_vehicles.has(str(payload.get("vehicle",""))):
		return _failure("Park the vehicle and step out before recalling it.")
	var mutates := kind not in ["enter", "exit"]
	var checkpoint: Dictionary = frontier.societies.export_state() if mutates else {}
	var previous_room: String = str(_interiors.get(peer, ""))
	if kind in ["buy_store_item","buy_vehicle","recall_vehicle"] and not previous_room.is_empty():
		return _failure("Head outside to this shop's storefront before buying.")
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
		var life_context:Dictionary=frontier.civil.life_context(peer,"member_"+identity,str(payload.get("building",""))) if kind.begins_with("life_") else {}
		result = frontier.societies.city_action(identity, kind, payload, position,-1.0,life_context)
	if result.get("ok", false) and mutates and frontier.persistence_enabled \
			and not frontier.societies.save_game(frontier.storage_path):
		frontier.societies.import_state(checkpoint)
		if previous_room.is_empty(): _interiors.erase(peer)
		else: _interiors[peer] = previous_room
		return _failure("The city could not save this change. Nothing was charged or moved.")
	if result.get("ok",false) and kind in ["buy_vehicle","recall_vehicle"] and result.get("vehicle") is Dictionary:
		net.register_city_vehicle(peer,result.vehicle)
	return result

func _transition(peer: int, identity: String, kind: String, payload: Dictionary,
		position: Vector3) -> Dictionary:
	if kind == "enter":
		var b: Dictionary = Plan.building(str(payload.get("id", "")))
		if b.is_empty() or position.distance_to(b.door) > 7.5:
			return _failure("Walk to this building's entrance first.")
		if frontier.societies._city().state.get("incidents",{}).has(b.id):
			return _failure("This building is under reconstruction. Return after repairs are complete.")
		if is_instance_valid(_geometry_guard):_geometry_guard.prepare(b)
		_interiors[peer] = b.id
		_publish_room(peer,b.id)
		_furniture.erase(peer)
		_publish_motion(peer,{})
		return {"ok": true, "message": "Welcome to " + str(b.name), "enter": b.id}
	if kind == "exit":
		var b: Dictionary = Plan.building(str(_interiors.get(peer, "")))
		if b.is_empty() or position.distance_to(interior_origin(b)) > 50.0:
			return _failure("Use the exit inside your current building.")
		_interiors.erase(peer)
		_publish_room(peer,"")
		_furniture.erase(peer)
		_publish_motion(peer,{})
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
	_publish_room(peer,"")
	_furniture.erase(peer)
	_publish_motion(peer,{})
	return {"ok": true, "message": "Arrived at " + str(destination.name),
		"destination": destination.position + Vector3(0, 1.2, 0)}

static func interior_origin(building: Dictionary) -> Vector3:
	if Rooms.housing_type(building) == "penthouse":
		var at: Vector3 = building.position
		return Vector3(at.x,Plan.GROUND_Y+float(building.size.y)-Rooms.room_dimensions(building).y,at.z)
	var door: Vector3 = building.door
	return Vector3(door.x, -500.0, door.z)

func _furniture_action(peer:int,kind:String,payload:Dictionary,position:Vector3,publish:bool=true)->Dictionary:
	var room:=Plan.building(str(_interiors.get(peer,"")))
	if room.is_empty():return _failure("Enter the room before using its furniture.")
	if kind=="cancel_furniture":
		if not _furniture.has(peer):return {"ok":true,"message":""}
		var active:Dictionary=_furniture[peer]
		if float(active.motion_progress)>0.10 and position.distance_to(active.motion_path[0].root)>0.20:return _failure("Return along the clear furniture approach first.")
		_furniture.erase(peer)
		if publish:_publish_motion(peer,{})
		return {"ok":true,"message":""}
	if kind=="leave_furniture":
		if not _furniture.has(peer):return _failure("You are already standing.")
		var active:Dictionary=_furniture[peer]
		if active.property!=room.id:return _failure("Use the furniture inside your current room.")
		var index:Variant=payload.get("target",0)
		if not index is int or index<0 or index>=active.exits.size():return _failure("Choose a clear place beside the furniture.")
		var nearest:=Motion.nearest_baked(active.baked,position,float(active.motion_progress))
		if nearest.distance>0.15:return _failure("Stay on the furniture approach while getting up.")
		var path:=Motion.reverse(active.motion_path,float(nearest.time),active.exits[index])
		active.rising=true
		active.motion_path=path
		active.baked=Motion.bake(path)
		active.motion_progress=0.0
		active.packet_msec=Time.get_ticks_msec()
		active.entered_msec=Time.get_ticks_msec()
		if publish:_publish_motion(peer,active)
		return {"ok":true,"message":"Standing up.","furniture_exit":active.exits[index],"motion_path":path}
	var id:=str(payload.get("id",""))
	var layout:=Rooms.furniture_layout(room)
	if not layout.has(id):return _failure("This furniture is unavailable.")
	var item:=Furniture.world_item(layout[id],interior_origin(room))
	if position.distance_to(item.position)>Furniture.REACH:return _failure("Walk beside the chair, sofa or bed first.")
	if _furniture.has(peer):return _failure("Stand up before using another seat.")
	for other:Dictionary in _furniture.values():
		if other.get("property","")==room.id and other.id==id:return _failure("Someone is already using this furniture.")
	var heading:Variant=payload.get("heading",roundi(fposmod(float(item.yaw),TAU)*1000.0))
	if not heading is int or heading<0 or heading>6284:return _failure("Invalid furniture approach heading.")
	item.motion_path=Motion.entry(item,position,float(heading)/1000.0)
	item.root=Motion.sample(item.motion_path,Motion.duration(item.motion_path)).root
	item.baked=Motion.bake(item.motion_path)
	item.property=room.id
	item.rising=false
	item.entered_msec=Time.get_ticks_msec()
	item.packet_msec=Time.get_ticks_msec()
	item.motion_progress=0.0
	_furniture[peer]=item
	if publish:_publish_motion(peer,item)
	return {"ok":true,"message":"E or movement to stand up.","furniture":item.duplicate(true)}

func validate_furniture_state(peer:int,position:Vector3,animation:int,yaw:float=NAN)->bool:
	if not Furniture.is_furniture_animation(animation):
		if _furniture.has(peer):
			var active:Dictionary=_furniture[peer]
			if not active.get("rising",false):
				return float(active.motion_progress)<0.10 and position.distance_to(active.motion_path[0].root)<0.20
			var end:Vector3=active.motion_path[-1].root
			if position.distance_to(end)>0.25:return false
			var total:=Motion.duration(active.motion_path)
			if float(active.motion_progress)<total-0.20 or float(Time.get_ticks_msec()-int(active.entered_msec))/1000.0<total*0.70:return false
			_furniture.erase(peer)
			_publish_motion(peer,{})
		return true
	if not _furniture.has(peer):return false
	var item:Dictionary=_furniture[peer]
	if str(_interiors.get(peer,""))!=str(item.property):return false
	var now:=Time.get_ticks_msec()
	var elapsed:=float(now-int(item.packet_msec))/1000.0
	var nearest:=Motion.nearest_baked(item.baked,position,float(item.motion_progress)+elapsed)
	if nearest.distance>0.13:return false
	var progress:=float(nearest.time)
	if progress>float(item.motion_progress)+maxf(0.80,elapsed*1.35+0.08):return false
	if progress>float(now-int(item.entered_msec))/1000.0*1.25+0.80:return false
	var total:=Motion.duration(item.motion_path)
	var expected:=Motion.sample(item.motion_path,progress)
	if animation in [Furniture.SIT,Furniture.RECLINE,Furniture.SLEEP] and not is_nan(yaw) and absf(wrapf(yaw-float(expected.yaw),-PI,PI))>0.22:return false
	if animation==Furniture.RISE:
		if not bool(item.rising):return false
	elif animation==Furniture.ENTER_SEAT:
		if bool(item.rising):return false
	else:
		if bool(item.rising) or animation!=Furniture.resting_animation(item.mode) \
			or position.distance_to(item.root)>0.04 or progress<total-0.16:return false
	item.motion_progress=maxf(float(item.motion_progress),progress)
	item.packet_msec=now
	return true

func _publish_room(peer:int,id:String)->void:
	cl_furniture_room(peer,id)
	if is_instance_valid(frontier) and frontier.authoritative and multiplayer.has_multiplayer_peer():rpc("cl_furniture_room",peer,id)

@rpc("authority","call_remote","reliable",2)
func cl_furniture_room(peer:int,id:String)->void:
	if id.is_empty():_remote_rooms.erase(peer);return
	var building:=Plan.building(id)
	if not building.is_empty():_remote_rooms[peer]=interior_origin(building)

func peer_in_furnished_room(peer:int,position:Vector3)->bool:
	return _remote_rooms.has(peer) and position.distance_to(_remote_rooms[peer])<60.0

func _publish_motion(peer:int,item:Dictionary)->void:
	if item.is_empty():_remote_furniture.erase(peer)
	else:_remote_furniture[peer]=item.duplicate(true)
	if is_instance_valid(frontier) and frontier.authoritative and multiplayer.has_multiplayer_peer():
		rpc("cl_furniture_motion",peer,item)

@rpc("authority","call_remote","reliable",2)
func cl_furniture_motion(peer:int,item:Dictionary)->void:
	if var_to_bytes(item).size()>MAX_PACKET:return
	if item.is_empty():_remote_furniture.erase(peer)
	elif item.has("motion_path") and item.has("baked"):_remote_furniture[peer]=item.duplicate(true)

func furniture_sample(peer:int,position:Vector3)->Dictionary:
	var item:Dictionary=_remote_furniture.get(peer,{})
	if item.is_empty():return {}
	var nearest:=Motion.nearest_baked(item.baked,position)
	if nearest.distance>0.40:return {}
	var frame:=Motion.sample(item.motion_path,float(nearest.time))
	return frame

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
		if not key is String or key not in ["id", "building", "property", "item", "quantity", "job", "target", "vehicle", "model", "heading"]: return false
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
