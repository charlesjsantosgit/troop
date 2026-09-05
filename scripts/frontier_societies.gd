class_name FrontierSocieties
extends RefCounted
## Server-owned registry. Network authentication/proximity belongs to Net;
## accounts, ownership, finite transfers and durable state belong here.
const SimScript = preload("res://scripts/frontier_sim.gd")
const CityScript = preload("res://scripts/city_economy.gd")
const Layout = preload("res://scripts/frontier_town_layout.gd")
const VERSION := 1
const MAX_PLAYERS := 64
const MAX_SAVE_BYTES := 8 * 1024 * 1024
const CLAIM_PRICE := 750
const STIPEND := 1800
const STARTING_MONEY := 738600
const SOCIETIES := ["canopy", "harbor", "ridge"]
const NAMES := {"canopy":["Canopy Commons","First Landing"],
	"harbor":["Palm Harbor","Tranquility Gardens"],"ridge":["Bamboo Ridge","Farpoint"]}
const MANAGEMENT := ["plant","harvest","water","fertilize","clear_plot","toggle_plot",
	"assign_job","toggle_worker","repair","refill_habitat","build_solar","upgrade_battery"]
const PUBLIC_ACTIONS := ["buy","sell","ship","accept_quest","deliver_quest","cancel_quest","process","refuel","inspect"]
var state: Dictionary = {}
var simulations: Dictionary = {}
var last_error := ""
var _city_model = null

func new_game(seed: int = 2026) -> void:
	state={"schema_version":VERSION,"seed":seed,"time":400.0,"players":{},"claims":{},
		"vehicle_fuel":{},"initial_money":STARTING_MONEY,"tick_remainder":0.0}
	_city_model=CityScript.new()
	_city_model.new_game(seed,float(state.time))
	state.city=_city_model.state
	simulations={}
	for id in SOCIETIES:
		var sim = SimScript.new()
		sim.new_game(seed)
		# Offline starter property is municipal property until a paid claim.
		sim._transfer("player","treasury",sim.balance("player"),"Unclaimed municipal estate")
		sim.state.accounts["estate_earth"]=0
		sim.state.accounts["estate_moon"]=0
		sim.state.inventories.player_earth={}
		sim.state.inventories.player_moon={}
		for plot: Dictionary in sim.state.plots.values():
			if plot.owner=="player": plot.owner="estate_"+str(plot.planet)
		sim.configure_shared_players(state.players)
		sim.state.vehicle_fuel=state.vehicle_fuel
		simulations[id]=sim
	last_error=""

func ensure_player(identity: String, player_name: String) -> Dictionary:
	if state.is_empty(): return _result(false,"Societies have not been initialized.")
	if not _valid_identity(identity): return _result(false,"An authenticated installation identity is required.")
	var actor := _actor(identity)
	if state.players.has(actor):
		state.players[actor].name=_clean_name(player_name)
		return _result(true,"Welcome back, "+str(state.players[actor].name)+".")
	if state.players.size()>=MAX_PLAYERS: return _result(false,"This server's resident registry is full.")
	var sponsor = null
	for id in SOCIETIES:
		if simulations[id].balance("treasury")>=STIPEND:
			sponsor=simulations[id]
			break
	if sponsor==null: return _result(false,"The municipal citizenship fund is depleted.")
	state.players[actor]={"id":actor,"name":_clean_name(player_name),"credits":0,
		"claimed_town":"","inventories":{"earth":{},"moon":{}},
		"reserved":{"earth":0,"moon":0},"created_at":state.time}
	for sim in simulations.values(): sim.attach_shared_player(actor)
	sponsor._transfer("treasury",actor,STIPEND,"One-time resident settlement allowance")
	# Starter goods move from real market stock; reconnecting never grants them again.
	for realm in ["earth","moon"]:
		var starter := {"banana":8,"water":20,"nutrients":2,"packaging":4,
			("lettuce_seed" if realm=="moon" else "banana_start"):1}
		for item in starter:
			var quantity := mini(int(starter[item]),sponsor.stock(realm+"_market",item))
			if quantity>0: sponsor._move_goods(realm+"_market",sponsor.inventory_location(actor,realm),item,quantity)
	return _result(true,"Registered once with 1800 credits from the municipal fund. Town claims cost 750 credits.")

func towns(identity: String = "") -> Array:
	var result: Array=[]
	for id in SOCIETIES:
		for realm in ["earth","moon"]: result.append(town_info(identity,id+"_"+realm))
	return result

func town_info(identity: String, town_id: String) -> Dictionary:
	var parts := _town_parts(town_id)
	if parts.is_empty(): return {}
	var actor := _actor(identity)
	var owner := str(state.get("claims",{}).get(town_id,""))
	var origin: Vector2=Layout.EARTH_ORIGINS[parts.society]
	var normal: Vector3=Layout.MOON_DIRECTIONS[parts.society]
	return {"id":town_id,"society_id":parts.society,"planet":parts.planet,
		"name":NAMES[parts.society][0 if parts.planet=="earth" else 1],
		"origin":[origin.x,origin.y],"moon_direction":[normal.x,normal.y,normal.z],
		"claimed":not owner.is_empty(),"is_owner":not owner.is_empty() and owner==actor,
		"owner_name":str(state.players[owner].name) if state.get("players",{}).has(owner) else "Unclaimed",
		"claim_price":CLAIM_PRICE}

func action(identity: String, town_id: String, kind: String, payload: Dictionary = {}) -> Dictionary:
	var actor := _actor(identity)
	if not _valid_identity(identity) or not state.get("players",{}).has(actor): return _result(false,"Register an authenticated resident first.")
	var town := town_info(identity,town_id)
	if town.is_empty(): return _result(false,"Unknown settlement.")
	var sim = simulations[town.society_id]
	if kind=="claim_town":
		if town.claimed: return _result(false,"This town has already been claimed.")
		if not str(state.players[actor].claimed_town).is_empty(): return _result(false,"Each resident may claim one town.")
		if sim.balance(actor)<CLAIM_PRICE: return _result(false,"A town claim costs 750 trade credits.")
		sim._transfer(actor,"treasury",CLAIM_PRICE,"Claim "+str(town.name))
		state.claims[town_id]=actor
		state.players[actor].claimed_town=town_id
		for plot: Dictionary in sim.state.plots.values():
			if plot.planet==town.planet and plot.owner=="estate_"+str(town.planet): plot.owner=actor
		return _result(true,"You claimed "+str(town.name)+". Other residents can still visit its shops and contracts.")
	if kind in MANAGEMENT:
		if not town.is_owner: return _result(false,"Only this town's owner can manage its plots, workers and utilities.")
		var target := str(payload.get("plot",payload.get("citizen",payload.get("facility",""))))
		var record: Dictionary=sim.state.plots.get(target,sim.state.citizens.get(target,sim.state.facilities.get(target,{})))
		if not record.is_empty() and record.planet!=town.planet: return _result(false,"That workplace belongs to the other world.")
	elif kind not in PUBLIC_ACTIONS:
		return _result(false,"This action is not available in shared societies.")
	return sim.action_for(actor,str(town.planet),kind,payload)

func view(identity: String, town_id: String) -> Dictionary:
	var actor := _actor(identity)
	if not state.get("players",{}).has(actor): return {}
	var town := town_info(identity,town_id)
	if town.is_empty(): return {}
	var sim = simulations[town.society_id]
	var snapshot: Dictionary=sim.state.duplicate(true)
	var member: Dictionary=state.players[actor]
	for other in state.players:
		for realm in ["earth","moon"]:
			snapshot.locations.erase(sim.inventory_location(other,realm))
			snapshot.inventories.erase(sim.inventory_location(other,realm))
	for realm in ["earth","moon"]:
		snapshot.inventories["player_"+realm]=member.inventories[realm].duplicate(true)
		snapshot.locations["player_"+realm].owner="player"
	snapshot.accounts.player=int(member.credits)
	for key in snapshot.accounts.keys():
		if str(key).begins_with("escrow_member_"): snapshot.accounts.erase(key)
	var quests := {}
	for id in sim.state.quests:
		var quest: Dictionary=sim.state.quests[id]
		if quest.has("actor"): continue
		var personal: Dictionary=sim.state.quests.get(actor+"__"+id,quest).duplicate(true)
		personal.id=id
		personal.erase("actor")
		personal.erase("template")
		quests[id]=personal
		snapshot.accounts["escrow_"+id]=int(personal.reward) if personal.status=="active" else 0
	snapshot.quests=quests
	snapshot.planet=town.planet
	snapshot.ledger=[]
	snapshot.events=[]
	snapshot.recent_requests={}
	# Published snapshots contain aliases, never other residents' identifiers,
	# wallets, bags or quest records. Their real cargo remains visible in transit.
	snapshot=_public_aliases(snapshot,actor)
	for worker: Dictionary in snapshot.citizens.values():
		worker["can_manage"]=bool(town.is_owner) and worker.planet==town.planet
		worker["trade_location"]=(str(worker.planet)+"_market") if worker.job=="merchant" else ("refinery" if worker.job=="refinery_operator" else "")
	for plot: Dictionary in snapshot.plots.values(): plot["can_manage"]=town.is_owner and plot.planet==town.planet and plot.owner=="player"
	snapshot.town=town
	snapshot.town_info=town.duplicate(true)
	snapshot.towns=towns(identity)
	snapshot.permissions={"manage":town.is_owner,"trade":true,"quests":true,
		"claim":not town.claimed and str(member.claimed_town).is_empty()}
	snapshot.claimed_town=member.claimed_town
	return snapshot

func city_view(identity: String, property_context: String = "") -> Dictionary:
	var actor:=_actor(identity)
	if not _valid_identity(identity) or not state.get("players",{}).has(actor): return {}
	var city=_city()
	if city==null: return {}
	var result: Dictionary=city.view(actor,simulations.canopy,property_context)
	var member: Dictionary=state.players[actor]
	result.credits=int(member.credits)
	result.backpack_counts=member.inventories.earth.duplicate(true)
	result.backpack_capacity=350
	result.time=float(state.time)
	result.now=float(state.time)
	return result

func city_action(identity: String, kind: String, payload: Dictionary,
		position: Vector3, time: float = -1.0, context: Dictionary = {}) -> Dictionary:
	var actor:=_actor(identity)
	if not _valid_identity(identity) or not state.get("players",{}).has(actor):
		return _result(false,"Register an authenticated resident first.")
	var city=_city()
	if city==null or not simulations.has("canopy"):
		return _result(false,"Crownreach is unavailable.")
	var authority_time:=float(state.time) if time<0.0 else time
	var result: Dictionary=city.action(actor,kind,payload,simulations.canopy,position,authority_time,context)
	state.city=city.state
	return result

func tick(dt: float) -> void:
	if state.is_empty() or not is_finite(dt) or dt<=0.0: return
	var before := int(float(state.time)/180.0)
	for sim in simulations.values(): sim.tick(dt)
	state.time=simulations.canopy.state.time
	state.tick_remainder=simulations.canopy._accumulator
	_advance_city(float(state.time))
	# A shared bag ages once, regardless of how many societies expose it.
	if int(float(state.time)/180.0)>before:
		for actor in state.players:
			for realm in ["earth","moon"]:
				var location: String=simulations.canopy.inventory_location(actor,realm)
				for item in ["banana","tomato","lettuce","spinach","strawberry","fish"]:
					if simulations.canopy.stock(location,item)>=12:
						simulations.canopy._consume(location,item,1,"Personal perishable storage loss")
						simulations.canopy._produce(location,"compost",1,"Recover spoiled organic material")

func register_vehicle(id: String, kind: int) -> Dictionary:
	return simulations.canopy.register_vehicle(id,kind) if simulations.has("canopy") else {}

func consume_vehicle_fuel(id: String, litres: float) -> float:
	return simulations.canopy.consume_vehicle_fuel(id,litres) if simulations.has("canopy") else 0.0

func total_money() -> int:
	var total := 0
	for member: Dictionary in state.get("players",{}).values(): total+=int(member.credits)
	for sim in simulations.values(): total+=sim.total_money()
	return total

func export_state() -> Dictionary:
	var result: Dictionary=state.duplicate(true)
	result.simulations={}
	for id in simulations:
		var sim = simulations[id]
		var data: Dictionary=sim.state.duplicate(true)
		for actor in state.players:
			for realm in ["earth","moon"]:
				data.locations.erase(sim.inventory_location(actor,realm))
				data.inventories.erase(sim.inventory_location(actor,realm))
		data.vehicle_fuel={}
		result.simulations[id]=data
	return result

func import_state(candidate: Variant) -> bool:
	var checked := _validated(candidate)
	if checked.is_empty(): return false
	var next: Dictionary=checked.state
	# Keep model objects stable for server vehicle controllers holding references.
	for id in SOCIETIES:
		if not simulations.has(id): simulations[id]=SimScript.new()
		simulations[id].state=checked.simulations[id].state
		for motion: Dictionary in simulations[id].state.get("traffic",{}).values():
			motion.arrived=false
			motion.reported_at=-100.0
		simulations[id]._accumulator=float(next.get("tick_remainder",0.0))
		simulations[id].configure_shared_players(next.players)
		simulations[id].state.vehicle_fuel=next.vehicle_fuel
	state=next
	_city_model=null
	last_error=""
	return true

func save_game(path: String) -> bool:
	var data := export_state()
	if _validated(data).is_empty():
		last_error="Society state failed validation."
		return false
	var encoded := JSON.stringify(data,"",false,true)
	if encoded.to_utf8_buffer().size()>MAX_SAVE_BYTES: return false
	var actual := ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(actual.get_base_dir())!=OK: return false
	var file := FileAccess.open(actual+".tmp",FileAccess.WRITE)
	if file==null: return false
	file.store_string(encoded)
	file.flush()
	var error := file.get_error()
	file.close()
	if error!=OK: return false
	if not _read_file(actual).is_empty():
		if DirAccess.copy_absolute(actual,actual+".bak")!=OK: return false
	return DirAccess.rename_absolute(actual+".tmp",actual)==OK

func load_game(path: String) -> bool:
	var actual := ProjectSettings.globalize_path(path)
	var data := _read_file(actual)
	if data.is_empty():
		data=_read_file(actual+".bak")
		if data.is_empty(): return false
		if FileAccess.file_exists(actual):
			if DirAccess.copy_absolute(actual,actual+".unreadable-"+str(Time.get_ticks_usec()))!=OK: return false
	return import_state(data)

func _read_file(path: String) -> Dictionary:
	var file := FileAccess.open(path,FileAccess.READ)
	if file==null: return {}
	if file.get_length()>MAX_SAVE_BYTES:
		file.close()
		return {}
	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	file.close()
	if error!=OK or _validated(json.data).is_empty(): return {}
	return json.data

func _validated(candidate: Variant) -> Dictionary:
	if not candidate is Dictionary or not _bounded(candidate): return {}
	var data: Dictionary=candidate.duplicate(true)
	if data.get("schema_version")!=VERSION or not _integer(data.get("seed"),0,1000000000000) or not _number(data.get("time"),0,1000000000) or data.get("initial_money")!=STARTING_MONEY: return {}
	if not data.has("city"):
		var migrated=CityScript.new()
		migrated.new_game(int(data.seed),float(data.time))
		data.city=migrated.state
	var city_check=CityScript.new()
	if not city_check.import_state(data.city) or int(city_check.state.seed)!=int(data.seed) \
			or float(city_check.state.last_time)>float(data.time)+0.0001: return {}
	for key in ["players","claims","vehicle_fuel","simulations"]:
		if not data.get(key) is Dictionary: return {}
	if not _number(data.get("tick_remainder",0.0),0,16): return {}
	if data.players.size()>MAX_PLAYERS or data.claims.size()>6 or data.simulations.size()!=3: return {}
	var money := 0
	for actor in data.players:
		var member: Variant=data.players[actor]
		if not actor is String or not _valid_identity(str(actor).trim_prefix("member_")) or actor!=_actor(str(actor).trim_prefix("member_")) or not member is Dictionary: return {}
		if member.get("id")!=actor or not member.get("name") is String or member.name.length()>32 or not _integer(member.get("credits"),0,1000000000) or not _number(member.get("created_at"),0,data.time): return {}
		if not member.get("inventories") is Dictionary or not member.get("reserved") is Dictionary or member.inventories.size()!=2 or member.reserved.size()!=2: return {}
		for realm in ["earth","moon"]:
			if not member.inventories.get(realm) is Dictionary or not _integer(member.reserved.get(realm),0,350): return {}
		var claim: Variant=member.get("claimed_town")
		if not claim is String or (claim!="" and (not data.claims.has(claim) or data.claims[claim]!=actor)): return {}
		money+=int(member.credits)
	for property: Dictionary in city_check.state.properties.values():
		if not data.players.has(str(property.owner)): return {}
	for actor in city_check.state.homes:
		if not data.players.has(actor): return {}
	for actor in city_check.state.active_jobs:
		if not data.players.has(actor): return {}
	for actor in city_check.state.resident_life:
		if not data.players.has(actor): return {}
	for actor in city_check.state.civil_law.residents:
		if not data.players.has(actor): return {}
	for town_id in data.claims:
		var actor: Variant=data.claims[town_id]
		if _town_parts(str(town_id)).is_empty() or not actor is String or not data.players.has(actor) or data.players[actor].claimed_town!=town_id: return {}
	var tested := {}
	var reserved := {}
	for actor in data.players: reserved[actor]={"earth":0,"moon":0}
	for id in SOCIETIES:
		if not data.simulations.get(id) is Dictionary: return {}
		if not data.simulations[id].get("locations") is Dictionary or not data.simulations[id].get("inventories") is Dictionary or data.simulations[id].get("online")!=true: return {}
		var sim = SimScript.new()
		sim.state=data.simulations[id]
		sim.configure_shared_players(data.players)
		sim.state.vehicle_fuel=data.vehicle_fuel
		if sim.state.get("seed")!=data.seed or sim.state.get("time")!=data.time or not sim.validate_state(sim.state): return {}
		money+=sim.total_money()
		for plot: Dictionary in sim.state.plots.values():
			if str(plot.owner).begins_with("member_") and data.claims.get(id+"_"+str(plot.planet),"")!=plot.owner: return {}
		for worker: Dictionary in sim.state.citizens.values():
			for key in ["employer","pending_employer"]:
				var employer := str(worker.get(key,""))
				if employer.begins_with("member_") and data.claims.get(id+"_"+str(worker.planet),"")!=employer: return {}
			var cargo: Dictionary=worker.carrying
			if not cargo.is_empty(): _count_reservation(cargo.to,int(cargo.quantity)+int(cargo.get("packaging",0)),sim,reserved)
		for cargo: Dictionary in sim.state.shipments: _count_reservation(cargo.to,int(cargo.quantity)+int(cargo.packaging),sim,reserved)
		for batch: Dictionary in sim.state.batches:
			for item in SimScript.RECIPES[batch.recipe].outputs: _count_reservation(batch.location,int(SimScript.RECIPES[batch.recipe].outputs[item]),sim,reserved)
		for quest: Dictionary in sim.state.quests.values():
			if quest.has("actor") and (not data.players.has(quest.actor) or not sim.state.quests.has(quest.get("template",""))): return {}
		tested[id]=sim
	if money!=STARTING_MONEY: return {}
	if int(tested.canopy.state.accounts.get("civil_evidence",0))!=preload("res://scripts/civil_law.gd").escrow_total(city_check.state.civil_law): return {}
	for actor in data.players:
		for realm in ["earth","moon"]:
			if int(data.players[actor].reserved[realm])!=int(reserved[actor][realm]): return {}
			var quantity := int(reserved[actor][realm])
			for item in data.players[actor].inventories[realm]: quantity+=int(data.players[actor].inventories[realm][item])
			if quantity>350: return {}
	data.erase("simulations")
	return {"state":data,"simulations":tested}

func _city():
	if not state.get("city") is Dictionary: return null
	if _city_model==null or _city_model.state!=state.city:
		var candidate=CityScript.new()
		if not candidate.import_state(state.city): return null
		_city_model=candidate
	return _city_model

func _advance_city(to_time: float) -> void:
	var city=_city()
	if city==null: return
	if city.advance(to_time): state.city=city.state

func _count_reservation(location: String, quantity: int, sim, totals: Dictionary) -> void:
	var record: Dictionary=sim.state.locations[location]
	if totals.has(record.owner): totals[record.owner][record.planet]+=quantity

func _public_aliases(value: Variant, actor: String) -> Variant:
	if value is String:
		if value==actor: return "player"
		if value==actor+"_earth": return "player_earth"
		if value==actor+"_moon": return "player_moon"
		if value.begins_with("member_") or value.begins_with("estate_"): return "town"
		return value
	if value is Dictionary:
		for key in value.keys(): value[key]=_public_aliases(value[key],actor)
	elif value is Array:
		for index in range(value.size()): value[index]=_public_aliases(value[index],actor)
	return value

func _town_parts(town_id: String) -> Dictionary:
	for id in SOCIETIES:
		for realm in ["earth","moon"]:
			if town_id==id+"_"+realm: return {"society":id,"planet":realm}
	return {}

func _actor(identity: String) -> String:
	return "member_"+identity

func _valid_identity(identity: String) -> bool:
	if identity.length()!=64: return false
	for c in identity:
		if c not in "0123456789abcdef": return false
	return true

func _clean_name(value: String) -> String:
	var result := ""
	for c in value:
		if c.unicode_at(0)>=32 and c.unicode_at(0)!=127: result+=c
	return result.strip_edges().left(32) if not result.strip_edges().is_empty() else "Resident"

func _number(value: Variant, minimum: float, maximum: float) -> bool:
	return typeof(value) in [TYPE_INT,TYPE_FLOAT] and is_finite(float(value)) and float(value)>=minimum and float(value)<=maximum

func _integer(value: Variant, minimum: float, maximum: float) -> bool:
	return _number(value,minimum,maximum) and float(value)==floor(float(value))

func _bounded(value: Variant, depth: int = 0) -> bool:
	if depth>16: return false
	if value is String: return value.length()<=4096
	if value is Dictionary:
		if value.size()>2048: return false
		for key in value:
			if typeof(key) not in [TYPE_STRING,TYPE_STRING_NAME] or str(key).length()>200 or not _bounded(value[key],depth+1): return false
	elif value is Array:
		if value.size()>2048: return false
		for entry in value:
			if not _bounded(entry,depth+1): return false
	elif typeof(value)==TYPE_FLOAT: return is_finite(value)
	elif typeof(value) not in [TYPE_INT,TYPE_BOOL,TYPE_NIL]: return false
	return true

func _result(ok: bool, message: String) -> Dictionary:
	return {"ok":ok,"message":message}
