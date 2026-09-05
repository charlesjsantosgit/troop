extends Node
## Authenticated civil actions and shared patrol snapshots on the existing
## dedicated server. High-frequency motion never shares the economy reply lane.
signal updated(view: Dictionary)
signal finished(kind: String, outcome: Dictionary)
const Law = preload("res://scripts/civil_law.gd")
const Plan = preload("res://scripts/city_plan.gd")
const Traffic = preload("res://scripts/city_traffic.gd")
var frontier: Node
var cached_view: Dictionary = {}
var _serial := 0
var _highest: Dictionary = {}
var _receipts: Dictionary = {}
var _motion: Dictionary = {}
var _accumulator := 0.0
var _broadcast_clock := 0.0
var _pending: Dictionary = {}
var _retry := 0.0

func _ready() -> void:
	frontier=get_parent()
	process_mode=Node.PROCESS_MODE_ALWAYS

func reset() -> void:
	cached_view.clear();_highest.clear();_receipts.clear();_motion.clear();_pending.clear()
	_accumulator=0;_broadcast_clock=0

func request(kind: String, payload: Dictionary = {}) -> Dictionary:
	if not _pending.is_empty(): return {"ok":false,"message":"Wait for the previous civil action to be confirmed."}
	_serial+=1
	if frontier.authoritative:
		var outcome: Dictionary = _handle(frontier.net.local_id(),_serial,kind,payload)
		_accept(kind,outcome)
		return outcome
	_pending={"serial":_serial,"kind":kind,"payload":payload.duplicate(true)}
	_retry=2
	rpc_id(1,"sv_action",_serial,kind,payload)
	return {"ok":true,"pending":true}

@rpc("any_peer","call_remote","reliable",2)
func sv_action(serial: int, kind: String, payload: Dictionary) -> void:
	var peer: int = multiplayer.get_remote_sender_id()
	if not frontier.authoritative or not frontier.net.names.has(peer) or not frontier.net._allow_rate(peer,"civil_action",4): return
	rpc_id(peer,"cl_result",serial,kind,_handle(peer,serial,kind,payload))

func _handle(peer: int, serial: int, kind: String, payload: Dictionary) -> Dictionary:
	if not frontier.society_ready or not frontier.storage_error.is_empty(): return _failure("Civil services are not ready.")
	if serial<=0 or serial>2147483647 or kind not in Law.ACTIONS or payload.size()>1: return _failure("Invalid civil request.")
	for key in payload:
		if key!="id" or not payload[key] is String or payload[key].length()>80: return _failure("Invalid civil target.")
	var signature: String = var_to_bytes([kind,payload]).hex_encode()
	var receipts: Dictionary = _receipts.get(peer,{})
	if receipts.has(serial): return receipts[serial].outcome if receipts[serial].signature==signature else _failure("Request number already used.")
	if serial<=int(_highest.get(peer,0)): return _failure("This civil request has expired.")
	var identity: String = frontier._identity(peer)
	var actor: String = "member_"+identity
	if identity.is_empty() or not frontier.societies.state.players.has(actor): return _failure("A registered resident is required.")
	var observations: Dictionary = _observations(0.0)
	if not observations.has(actor): return _failure("Civil services are available on Earth.")
	var observation: Dictionary = observations[actor]
	var checkpoint: Dictionary = frontier.societies.export_state()
	var city = frontier.societies._city()
	var law = Law.new();law.state=city.state.civil_law
	var outcome: Dictionary = law.action(actor,kind,payload,frontier.societies.simulations.canopy,observation.position,float(frontier.societies.state.time),observation)
	if outcome.get("ok",false):
		city.state.civil_law=law.state;frontier.societies.state.city=city.state
		if frontier.persistence_enabled and not frontier.societies.save_game(frontier.storage_path):
			frontier.societies.import_state(checkpoint)
			outcome=_failure("Could not save this action. Nothing was moved or charged.")
	_highest[peer]=serial
	outcome["view"]=_view(actor)
	receipts[serial]={"signature":signature,"outcome":outcome.duplicate(true)}
	while receipts.size()>16: receipts.erase(receipts.keys()[0])
	_receipts[peer]=receipts
	return outcome

func _observations(dt: float) -> Dictionary:
	var observations: Dictionary = {}
	var net: Node = frontier.net
	var city=frontier.societies._city()
	var reserved: int = 0
	for job: Dictionary in city.state.active_jobs.values(): reserved+=int(job.reward)
	for peer in net.names:
		if net.player_realm(int(peer))!=net.PlayerRealm.EARTH: continue
		var identity: String = frontier._identity(int(peer))
		var actor: String = "member_"+identity
		if identity.is_empty() or not frontier.societies.state.players.has(actor): continue
		var at: Vector3 = net._peer_on_foot_positions.get(peer,Vector3.INF)
		var vehicle_id: String = ""
		for id in net.claimed_vehicles:
			if int(net.claimed_vehicles[id])==int(peer):
				vehicle_id=str(id);at=net._vehicle_positions.get(id,at);break
		if not at.is_finite(): continue
		var speed: float = 0.0
		var sample: Dictionary = _motion.get(peer,{})
		if dt>0:
			if not sample.is_empty(): speed=minf(200,at.distance_to(sample.position)/dt)
			_motion[peer]={"position":at,"speed":speed}
		else: speed=float(sample.get("speed",0))
		var limit: float = road_limit(at)
		observations[actor]={"peer":int(peer),"position":at,"speed":speed,"on_foot":vehicle_id.is_empty(),"inside":not str(frontier.city._interiors.get(peer,"")).is_empty(),"speed_limit":limit,"reserved_payroll":reserved}
	return observations

static func road_limit(at: Vector3) -> float:
	var highway = load("res://scripts/highway_plan.gd")
	if highway!=null:
		var limit: float = highway.posted_speed(at)
		if limit>0: return limit
	if not Plan.contains(Vector2(at.x,at.z)): return 0
	var grid: Vector2i = Traffic.grid(Vector2(at.x,at.z))
	var road: Vector2 = Traffic.point(grid)
	if minf(absf(at.x-road.x),absf(at.z-road.y))>11: return 0
	return 11.176 # Crownreach's posted 25 mph city profile.

func _process(delta: float) -> void:
	if not frontier.authoritative:
		if not _pending.is_empty() and frontier.net.active:
			_retry-=delta
			if _retry<=0:
				_retry=2;rpc_id(1,"sv_action",int(_pending.serial),str(_pending.kind),_pending.payload)
		return
	if not frontier.society_ready or not frontier.net.active or not frontier.storage_error.is_empty(): return
	_accumulator+=delta
	if _accumulator<.2: return
	var dt: float = minf(.5,_accumulator);_accumulator=0
	var observations: Dictionary = _observations(dt)
	var city=frontier.societies._city()
	var law=Law.new();law.state=city.state.civil_law
	var sim=frontier.societies.simulations.canopy
	var checkpoint: Dictionary = frontier.societies.export_state()
	var old_cash: int = Law.escrow_total(law.state)
	var events: Dictionary = law.advance(dt,float(frontier.societies.state.time),observations,sim)
	city.state.civil_law=law.state
	var life=preload("res://scripts/resident_life.gd").new();life.state=city.state.resident_life
	for actor: String in observations:
		var context: Dictionary = life_context(int(observations[actor].peer),actor)
		life.advance(actor,dt,observations[actor].position,float(frontier.societies.state.time),context)
	city.state.resident_life=life.state
	frontier.societies.state.city=city.state
	if (not events.is_empty() or old_cash!=Law.escrow_total(law.state)) and frontier.persistence_enabled and not frontier.societies.save_game(frontier.storage_path):
		frontier.societies.import_state(checkpoint)
		return
	for actor: String in events:
		var peer: int = int(observations[actor].peer)
		var outcome: Dictionary = events[actor];outcome["view"]=_view(actor)
		if peer==frontier.net.local_id(): _accept("civil_update",outcome)
		else: rpc_id(peer,"cl_result",0,"civil_update",outcome)
	_broadcast_clock+=dt
	for actor: String in observations:
		var peer: int = int(observations[actor].peer)
		var view: Dictionary = _view(actor)
		if peer==frontier.net.local_id(): _apply_view(view)
		elif multiplayer.has_multiplayer_peer(): rpc_id(peer,"cl_view",view)

func life_context(peer: int, actor: String, building_id: String = "") -> Dictionary:
	var context: Dictionary = {}
	var room_id: String = str(frontier.city._interiors.get(peer,""))
	var city=frontier.societies._city()
	if not room_id.is_empty():
		var room: Dictionary = Plan.building(room_id)
		var ownership: Dictionary = city.state.properties.get(room_id,{})
		# The actual service-point layout is the same one used for setting home.
		var points: Dictionary = preload("res://scripts/city_interior.gd").service_layout(room)
		if points.has("bed"):
			context.bed={"building":room_id,"position":frontier.city.interior_origin(room)+Vector3(points.bed.position),"owner":str(ownership.get("owner","")),"residential":true}
	if room_id.is_empty() and not city.state.incidents.has(building_id):
		var clinic:Dictionary=Plan.building(building_id)
		if clinic.get("kind","")=="clinic":context.clinic={"building":building_id,"position":clinic.door,"kind":"clinic"}
	return context

func _view(actor: String) -> Dictionary:
	var city=frontier.societies._city()
	var law=Law.new();law.state=city.state.civil_law
	var view: Dictionary = law.view(actor,float(frontier.societies.state.time))
	var life=preload("res://scripts/resident_life.gd").new();life.state=city.state.resident_life
	view.resident_life=life.view(actor)
	var sim=frontier.societies.simulations.canopy
	view.credits=sim.balance(actor)
	return view

@rpc("authority","call_remote","unreliable_ordered",1)
func cl_view(view: Dictionary) -> void:
	if not frontier.authoritative and var_to_bytes(view).size()<20000: _apply_view(view)

@rpc("authority","call_remote","reliable",2)
func cl_result(serial: int, kind: String, outcome: Dictionary) -> void:
	if frontier.authoritative or var_to_bytes(outcome).size()>24000: return
	if serial==int(_pending.get("serial",-1)): _pending.clear()
	_accept(kind,outcome)

func _apply_view(view: Dictionary) -> void:
	if float(view.get("time",0))<float(cached_view.get("time",0)): return
	cached_view=view.duplicate(true)
	updated.emit(cached_view)

func _accept(kind: String, outcome: Dictionary) -> void:
	if outcome.get("view") is Dictionary: _apply_view(outcome.view)
	finished.emit(kind,outcome)

static func _failure(message: String) -> Dictionary: return {"ok":false,"message":message}

func observe_shot(peer: int, origin: Vector3) -> void:
	if not frontier.authoritative or not frontier.society_ready or not Plan.contains(Vector2(origin.x,origin.z)):return
	var identity:String=frontier._identity(peer)
	var actor:String="member_"+identity
	if identity.is_empty() or not frontier.societies.state.players.has(actor):return
	var city=frontier.societies._city()
	var law=Law.new();law.state=city.state.civil_law
	for unit:Dictionary in law.state.units:
		var officer:Vector3=Law.vector(unit.get("officer_position",unit.position))
		if officer.distance_to(origin)<125 and Law._visible(officer,origin):
			law.report(actor,"armed_threat",origin,float(frontier.societies.state.time));break
	city.state.civil_law=law.state;frontier.societies.state.city=city.state
