class_name CivilLaw
extends RefCounted
## Persistent, server-driven civil incidents. Clients never choose evidence,
## pursuit positions, elapsed work time, fines, or robbery rewards.
const Plan = preload("res://scripts/city_plan.gd")
const Commerce = preload("res://scripts/city_commerce.gd")
const Routes = preload("res://scripts/civil_police_routes.gd")
const ESCROW := "civil_evidence"
const MAX_RESIDENTS := 64
const MAX_TARGETS := 128
const ACTIONS := ["civil_rob", "civil_vault", "civil_cancel", "civil_fence", "civil_surrender", "civil_service", "civil_escape", "civil_pay"]
const PHASES := ["clear", "reported", "pursuit", "search", "traffic_stop", "citation", "custody"]
var state: Dictionary = {}

static func new_state() -> Dictionary:
	return {"version":1,"residents":{},"targets":{},"units":[],"next_id":1,"bank_open_until":0.0}

static func point(v: Vector3) -> Array: return [v.x,v.y,v.z]
static func vector(a: Array) -> Vector3: return Vector3(a[0],a[1],a[2])
static func result(ok: bool, message: String) -> Dictionary: return {"ok":ok,"message":message}

func ensure(actor: String) -> Dictionary:
	if not state.residents.has(actor):
		if state.residents.size() >= MAX_RESIDENTS: return {}
		state.residents[actor] = {"phase":"clear","offense":"","cash":0,"fine":0,"warnings":0,
			"last_seen":[0.0,8.0,0.0],"last_seen_at":0.0,"reported_at":0.0,"search_until":0.0,
			"custody_until":0.0,"traffic_after":0.0,"speed_seconds":0.0,"stopped_seconds":0.0,
			"arrest_seconds":0.0,"service_seconds":0.0,"escape_seconds":0.0,"robbery":{},"notice":"Welcome to Crownreach."}
	return state.residents[actor]

func initialize_units() -> void:
	if not state.units.is_empty(): return
	var positions: Array = [Vector3(Plan.MIN_X-55,Plan.GROUND_Y,0),
		Vector3(Plan.MIN_X+Plan.BLOCK_EXTENTS.x*5,Plan.GROUND_Y,0),
		Vector3(Plan.CENTER.x,Plan.GROUND_Y,Plan.BLOCK_EXTENTS.y*2)]
	for i in range(positions.size()): state.units.append(Routes.make_unit("patrol_%d"%i,positions[i]))

func view(actor: String, now: float) -> Dictionary:
	var personal: Dictionary = state.residents.get(actor,{}).duplicate(true)
	personal.erase("last_seen")
	personal.erase("last_seen_at")
	var units: Array = []
	for unit: Dictionary in state.units:
		var row: Dictionary = {}
		for key in ["id","position","heading","siren","state","target","officer_position","speed","arrived"]:
			if unit.has(key): row[key]=unit[key]
		units.append(row)
	var incidents: Array = []
	for record: Dictionary in state.residents.values():
		var robbery: Dictionary = record.robbery
		if not robbery.is_empty(): incidents.append({"position":robbery.position,"stage":robbery.stage})
	return {"time":now,"personal":personal,"units":units,"sites":Routes.site_positions(),"robberies":incidents,"bank_open":now<maxf(float(state.targets.get("bank",0)),float(state.get("bank_open_until",0)))}

func target_for(id: String) -> Dictionary:
	var sites: Dictionary = Routes.site_positions()
	if id == "bank": return {"id":id,"position":sites.bank_security,"reward":420,"duration":8.0,"stage":"security","label":"Westgate Credit Union"}
	var building: Dictionary = Plan.building(id)
	if building.is_empty() or Commerce.offers(building).is_empty(): return {}
	return {"id":id,"position":point(building.door),"reward":90,"duration":10.0,"stage":"till","label":building.name}

func action(actor: String, kind: String, payload: Dictionary, sim, at: Vector3, now: float, context: Dictionary = {}) -> Dictionary:
	if kind not in ACTIONS or not at.is_finite() or not is_finite(now) or now<0: return result(false,"Invalid civil service request.")
	if actor.is_empty() or actor.length()>96 or sim==null: return result(false,"A registered resident is required.")
	var record: Dictionary = ensure(actor)
	if record.is_empty(): return result(false,"The resident registry is full.")
	var sites: Dictionary = Routes.site_positions()
	if kind == "civil_pay":
		if at.distance_to(vector(sites.station))>6: return result(false,"Visit the police station service desk to settle a citation.")
		var amount: int = record.fine
		if amount<=0: return result(false,"You have no outstanding citation.")
		if sim.balance(actor)<amount: return result(false,"You need %d credits to settle this citation."%amount)
		sim._transfer(actor,"treasury",amount,"Civil traffic citation")
		record.fine=0
		if record.phase=="citation": record.phase="clear"
		return result(true,"Citation paid. You are free to go.")
	if kind == "civil_surrender":
		if record.phase not in ["reported","pursuit","search"]: return result(false,"You are not being sought for an arrest.")
		var officer_near: bool = at.distance_to(vector(sites.station))<=6
		for unit: Dictionary in state.units:
			if at.distance_to(vector(unit.get("officer_position",unit.position)))<12 and _visible(vector(unit.get("officer_position",unit.position)),at): officer_near=true
		if not officer_near: return result(false,"Approach an officer or the station desk to surrender.")
		return _arrest(record,sim,now)
	if kind in ["civil_service","civil_escape"]:
		if record.phase!="custody": return result(false,"You are not in custody.")
		var site: String = "community_service" if kind=="civil_service" else "escape"
		if at.distance_to(vector(sites[site]))>3.5: return result(false,"Walk to the marked %s point."%site.replace("_"," "))
		if kind=="civil_service":
			record.service_seconds=0.01
			return result(true,"Community service started. Stay at the sorting table for 12 seconds to earn release.")
		record.escape_seconds=0.01
		return result(true,"Opening the maintenance gate. Stay here for 18 seconds; escape creates a new search.")
	if record.phase=="custody": return result(false,"Complete your custody period or community service first.")
	if kind=="civil_cancel":
		record.robbery={}
		return result(true,"You stopped taking cash. Any reported incident still needs to be resolved.")
	if kind=="civil_fence":
		if at.distance_to(vector(sites.fence))>5: return result(false,"Bring the cash bag to the Westgate fence.")
		if record.phase in ["reported","pursuit","traffic_stop"]: return result(false,"Lose the active pursuit before bringing a bag here.")
		if record.cash<=0: return result(false,"You are not carrying stolen cash.")
		if sim.balance(ESCROW)<int(record.cash): return result(false,"The evidence ledger is unavailable.")
		var gross: int = record.cash
		var payout: int = floori(gross*.7)
		sim._transfer(ESCROW,actor,payout,"Recovered stolen cash sale")
		sim._transfer(ESCROW,"treasury",gross-payout,"Fence handling fee")
		record.cash=0
		return result(true,"Cash bag sold for %d credits. The fence kept a handling fee."%payout)
	if context.get("inside",false) or not context.get("on_foot",true): return result(false,"Approach this counter on foot outside.")
	if kind=="civil_vault":
		if record.robbery.get("stage","")!="vault_ready": return result(false,"Disable the credit union security terminal first.")
		if at.distance_to(vector(sites.vault))>4.5: return result(false,"Walk to the opened vault counter.")
		record.robbery.stage="vault"
		record.robbery.position=sites.vault
		record.robbery.remaining=18.0
		return result(true,"Collecting the vault cash. Stay at the counter for 18 seconds.")
	if kind=="civil_rob":
		if not record.robbery.is_empty() or record.cash>0: return result(false,"Finish your current robbery or dispose of its cash bag first.")
		var id: String = str(payload.get("id",""))
		var target: Dictionary = target_for(id)
		if target.is_empty() or at.distance_to(vector(target.position))>5: return result(false,"Walk to a shop counter or the credit union security terminal.")
		if now<float(state.targets.get(id,0)): return result(false,"This counter is closed after a robbery. It will reopen after ten minutes.")
		for other: Dictionary in state.residents.values():
			if other.robbery.get("id","")==id: return result(false,"Another resident is already at this counter.")
		if state.targets.size()>=MAX_TARGETS: return result(false,"Too many businesses are awaiting recovery. Try later.")
		var reserved: int = int(context.get("reserved_payroll",0))
		if sim.balance("treasury")-reserved<int(target.reward): return result(false,"There is no available cash in this counter.")
		record.robbery={"id":id,"stage":target.stage,"position":target.position,"remaining":target.duration,
			"reward":target.reward,"started":now,"reported":false}
		record.notice="Alarm reporting in 3 seconds. Leave now to abandon the attempt."
		return result(true,record.notice)
	return result(false,"This action is unavailable.")

func report(actor: String, offense: String, at: Vector3, now: float) -> void:
	var record: Dictionary = ensure(actor)
	if record.is_empty() or record.phase=="custody": return
	if offense not in ["robbery","armed_threat","escape"]: return
	record.phase="reported"
	record.offense=offense
	record.reported_at=now
	record.last_seen=point(at)
	record.last_seen_at=now
	record.search_until=now+95
	record.notice="Reported %s. Officers are responding; you can surrender without a shootout."%offense.replace("_"," ")

func advance(dt: float, now: float, actors: Dictionary, sim) -> Dictionary:
	var events: Dictionary = {}
	if not is_finite(dt) or dt<=0 or sim==null: return events
	dt=minf(dt,.5)
	initialize_units()
	for target in state.targets.keys():
		if now>=float(state.targets[target]): state.targets.erase(target)
	var assigned: Dictionary = {}
	for actor: String in actors:
		var observation: Dictionary = actors[actor]
		var at: Vector3 = observation.position
		if not at.is_finite(): continue
		var record: Dictionary = ensure(actor)
		if record.is_empty(): continue
		_tick_robbery(record,actor,at,dt,now,sim,observation)
		if record.phase=="custody":
			var event: Dictionary = _tick_custody(record,at,dt,now)
			if not event.is_empty(): events[actor]=event
			continue
		var visible_units: Array = []
		for i in range(state.units.size()):
			var officer: Vector3 = vector(state.units[i].get("officer_position",state.units[i].position))
			if officer.distance_to(at)<125 and not observation.get("inside",false) and _visible(officer,at): visible_units.append(i)
		_tick_traffic(record,observation,visible_units,dt,now)
		if record.phase in ["reported","pursuit","search","traffic_stop"]:
			if not visible_units.is_empty():
				record.last_seen=point(at)
				record.last_seen_at=now
				if record.phase!="traffic_stop": record.phase="pursuit"
			elif now-float(record.last_seen_at)>7 and record.phase!="traffic_stop":
				record.phase="search"
			if record.phase=="search" and now-float(record.last_seen_at)>65:
				record.phase="clear"
				record.notice="The immediate search has ended. Keep clear of further trouble."
				continue
			# Allocate one closest free patrol. A small offense never summons an army.
			var nearest: int = -1
			var distance: float = INF
			for i in range(state.units.size()):
				if assigned.has(i): continue
				var d: float = vector(state.units[i].position).distance_squared_to(vector(record.last_seen))
				if d<distance: nearest=i;distance=d
			if nearest>=0:
				assigned[nearest]={"actor":actor,"target":vector(record.last_seen),"mode":"traffic_stop" if record.phase=="traffic_stop" else "search" if record.phase=="search" else "respond","peer":int(observation.get("peer",0))}
				var officer_at: Vector3 = vector(state.units[nearest].get("officer_position",state.units[nearest].position))
				var close: bool = officer_at.distance_to(at)<5 and nearest in visible_units
				if record.phase=="pursuit" and close and observation.get("on_foot",true) and float(observation.get("speed",0))<3:
					record.arrest_seconds+=dt
					record.notice="Officer: Stop and show your hands. You are under arrest."
					if record.arrest_seconds>=3: events[actor]=_arrest(record,sim,now)
				else: record.arrest_seconds=0.0
	for i in range(state.units.size()):
		var unit: Dictionary = state.units[i]
		if assigned.has(i):
			var task: Dictionary = assigned[i]
			unit.target=task.peer
			state.units[i]=Routes.advance_unit(unit,dt,task.target,task.mode)
		else:
			unit.target=0
			var stage: int = (floori(now/45)+i*3)%8
			var destination := Vector3(Plan.MIN_X+(2+stage)*Plan.BLOCK_EXTENTS.x,Plan.GROUND_Y,(-1+i)*Plan.BLOCK_EXTENTS.y)
			state.units[i]=Routes.advance_unit(unit,dt,destination,"patrol")
	return events

func _tick_robbery(record: Dictionary, actor: String, at: Vector3, dt: float, now: float, sim, observation: Dictionary) -> void:
	var robbery: Dictionary = record.robbery
	if robbery.is_empty(): return
	var allowed_radius:float=20.0 if robbery.stage=="vault_ready" else 8.0
	if at.distance_to(vector(robbery.position))>allowed_radius or not observation.get("on_foot",true) or observation.get("inside",false):
		record.robbery={};record.notice="Robbery interrupted: you left the counter."
		return
	if now-float(robbery.started)>=3 and not robbery.reported:
		robbery.reported=true
		report(actor,"robbery",at,now)
	if robbery.stage=="vault_ready": return
	robbery.remaining=maxf(0,float(robbery.remaining)-dt)
	if robbery.remaining>0: return
	if robbery.stage=="security":
		robbery.stage="vault_ready"
		state.bank_open_until=now+90
		# Moving from terminal to vault is an intentional next stage, not escape.
		robbery.position=Routes.site_positions().vault
		record.notice="Security bypassed. Walk to the vault and collect the cash."
		return
	var reserved: int = int(observation.get("reserved_payroll",0))
	var amount: int = mini(int(robbery.reward),maxi(0,sim.balance("treasury")-reserved))
	if amount>0:
		sim._transfer("treasury",ESCROW,amount,"Stolen shop cash held in evidence escrow")
		record.cash+=amount
	state.targets[robbery.id]=now+600
	record.robbery={}
	record.notice="Carrying %d stolen credits. Escape and take the bag to the Westgate fence."%amount

func _tick_traffic(record: Dictionary, observation: Dictionary, visible: Array, dt: float, now: float) -> void:
	var speed: float = float(observation.get("speed",0))
	var limit: float = float(observation.get("speed_limit",0))
	if record.phase=="traffic_stop":
		if speed<.8 and not visible.is_empty(): record.stopped_seconds+=dt
		else: record.stopped_seconds=0.0
		if record.stopped_seconds>=4:
			if int(record.warnings)==0:
				record.warnings=1;record.phase="clear";record.notice="Officer: This is a warning. Please watch the posted speed. Drive safely."
			else:
				record.fine=mini(250,int(record.fine)+25);record.phase="citation";record.notice="Officer: A 25-credit citation has been issued. Pay at the station; you may leave."
			record.traffic_after=now+120;record.speed_seconds=0.0
		elif now-float(record.reported_at)>35:
			record.fine=mini(250,int(record.fine)+35);record.phase="citation";record.traffic_after=now+120
			record.notice="Patrol disengaged from the traffic stop. A 35-credit citation is recorded; there is no armed pursuit."
		return
	if record.phase not in ["clear","citation"] or now<float(record.traffic_after): return
	# Enforcement discretion is a game policy, not an extra legal speed limit.
	if limit>0 and speed>limit+3.57632 and not visible.is_empty() and not observation.get("on_foot",true): record.speed_seconds+=dt
	else: record.speed_seconds=maxf(0,float(record.speed_seconds)-dt*2)
	if record.speed_seconds>=4:
		record.phase="traffic_stop";record.offense="speeding";record.reported_at=now;record.stopped_seconds=0.0
		record.last_seen=point(observation.position)
		record.notice="Police: Sustained speeding observed. Pull over safely and stop. This is a traffic stop."

func _arrest(record: Dictionary, sim, now: float) -> Dictionary:
	var seized: int = mini(int(record.cash),sim.balance(ESCROW))
	if seized>0: sim._transfer(ESCROW,"treasury",seized,"Confiscated robbery proceeds")
	record.cash=0;record.robbery={};record.phase="custody";record.custody_until=now+75
	record.service_seconds=0.0;record.escape_seconds=0.0;record.arrest_seconds=0.0
	record.notice="In custody for %s. Release in 75 seconds, or complete a short community-service task."%str(record.offense).replace("_"," ")
	var outcome: Dictionary = result(true,record.notice)
	outcome.destination=Routes.site_positions().custody
	return outcome

func _tick_custody(record: Dictionary, at: Vector3, dt: float, now: float) -> Dictionary:
	var sites: Dictionary = Routes.site_positions()
	if record.service_seconds>0:
		if at.distance_to(vector(sites.community_service))<3.5: record.service_seconds+=dt
		else: record.service_seconds=0.0
	if record.escape_seconds>0:
		if at.distance_to(vector(sites.escape))<3.5: record.escape_seconds+=dt
		else: record.escape_seconds=0.0
	if record.escape_seconds>=18:
		record.phase="reported";record.offense="escape";record.last_seen=sites.release;record.last_seen_at=now;record.reported_at=now
		record.service_seconds=0.0;record.escape_seconds=0.0
		record.notice="You escaped custody. Officers will search near the station."
		return {"ok":true,"message":record.notice,"destination":sites.release}
	if now>=float(record.custody_until) or record.service_seconds>=12:
		record.phase="clear";record.service_seconds=0.0;record.escape_seconds=0.0
		record.notice="You have been released. Your home, belongings and legitimate earnings are safe."
		return {"ok":true,"message":record.notice,"destination":sites.release}
	if at.distance_to(vector(sites.custody))>35:
		return {"ok":true,"message":"Use the community-service table or maintenance gate to leave custody.","destination":sites.custody}
	return {}

static func _visible(from: Vector3, to: Vector3) -> bool:
	return Routes.line_of_sight(from+Vector3.UP*1.4,to+Vector3.UP*1.1)

static func escrow_total(data: Dictionary) -> int:
	var total: int = 0
	for record: Dictionary in data.get("residents",{}).values(): total+=int(record.get("cash",0))
	return total

static func valid(data: Variant) -> bool:
	if not data is Dictionary or data.get("version")!=1 or not data.get("residents") is Dictionary or data.residents.size()>MAX_RESIDENTS: return false
	if not data.get("targets") is Dictionary or data.targets.size()>MAX_TARGETS or not data.get("units") is Array or data.units.size()>6: return false
	if not _number(data.get("next_id"),1,1000000000): return false
	for actor in data.residents:
		if not actor is String or actor.is_empty() or actor.length()>96: return false
		var r: Variant = data.residents[actor]
		if not r is Dictionary or r.get("phase") not in PHASES or not r.get("offense") is String or r.offense.length()>32 or not r.get("notice") is String or r.notice.length()>400: return false
		if not _point(r.get("last_seen")) or not r.get("robbery") is Dictionary: return false
		for field in ["cash","fine","warnings"]:
			if not _number(r.get(field),0,1000000) or float(r[field])!=floorf(float(r[field])): return false
		for field in ["last_seen_at","reported_at","search_until","custody_until","traffic_after","speed_seconds","stopped_seconds","arrest_seconds","service_seconds","escape_seconds"]:
			if not _number(r.get(field),0,1000000000): return false
		if not r.robbery.is_empty():
			var b: Dictionary = r.robbery
			if not b.get("id") is String or b.id.length()>80 or b.get("stage") not in ["security","vault_ready","vault","till"] or not _point(b.get("position")) or not b.get("reported") is bool: return false
			for field in ["remaining","started","reward"]:
				if not _number(b.get(field),0,1000000000): return false
			if int(b.reward) not in [90,420] or float(b.remaining)>18: return false
	for id in data.targets:
		if not id is String or id.length()>80 or not _number(data.targets[id],0,1000000000): return false
	for unit in data.units:
		if not unit is Dictionary or not unit.get("id") is String or not _point(unit.get("position")) or not _number(unit.get("heading"),-100,100) or not unit.get("siren") is bool: return false
	return true

static func _number(value: Variant, low: float, high: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value)>=low and float(value)<=high
static func _point(value: Variant) -> bool:
	if not value is Array or value.size()!=3: return false
	for coordinate in value:
		if not _number(coordinate,-1000000,1000000): return false
	return true
