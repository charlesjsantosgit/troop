class_name FrontierSim
extends RefCounted
## Local authoritative Roots & Rockets simulation, independent of score pickups.
## Whole game units (kg produce / litres fluids), integer credits, accelerated
## 20-minute civilian days and 80-minute lunar days. No wall-clock catch-up.
## Public state/crop_catalog/item_catalog/job_catalog/recipe_catalog/quote/action.
## Citizens physically reach positions before timed jobs commit resources.
## Saves are validated fully then atomically replace current state.
const RoutesScript = preload("res://scripts/frontier_routes.gd")
const VERSION := 1
const PEDESTRIAN_RADIUS := 0.34
const PEDESTRIAN_SPACING := 0.86
const OCCUPIED_WAYPOINT_CAPTURE_RADIUS := 1.0
const WALK_SPEED := 2.0
const DAY_SECONDS := 1200.0
const LUNAR_DAY_SECONDS := 4800.0
const CROP_ROWS := {
	"banana": ["Banana",360,12,0.055,0.023,18,38,false,"banana_start"],
	"plantain": ["Plantain",390,13,0.055,0.025,18,38,false,"plantain_start"],
	"cassava": ["Cassava",340,14,0.026,0.015,18,38,false,"cassava_cutting"],
	"sweet_potato": ["Sweet potato",230,11,0.034,0.020,15,35,false,"sweet_potato_slip"],
	"rice": ["Rice",270,14,0.075,0.025,15,38,false,"rice_seed"],
	"taro": ["Taro",300,12,0.066,0.023,18,35,false,"taro_corm"],
	"maize": ["Maize",260,13,0.042,0.027,12,36,false,"maize_seed"],
	"soybean": ["Soybean",250,10,0.037,0.014,15,34,true,"soybean_seed"],
	"bean": ["Common bean",190,9,0.032,0.014,12,32,true,"bean_seed"],
	"peanut": ["Peanut",290,10,0.032,0.016,18,35,true,"peanut_seed"],
	"tomato": ["Tomato",230,10,0.043,0.022,15,32,false,"tomato_seed"],
	"cucumber": ["Cucumber",190,12,0.047,0.021,16,34,false,"cucumber_seed"],
	"pepper": ["Pepper",260,8,0.037,0.021,16,33,false,"pepper_seed"],
	"lettuce": ["Lettuce",130,8,0.027,0.012,5,29,false,"lettuce_seed"],
	"spinach": ["Spinach",140,8,0.026,0.014,3,28,false,"spinach_seed"],
	"radish": ["Radish",110,7,0.023,0.012,5,30,false,"radish_seed"],
	"carrot": ["Carrot",210,10,0.028,0.016,5,31,false,"carrot_seed"],
	"strawberry": ["Strawberry",220,7,0.034,0.019,6,29,false,"strawberry_start"],
	"cocoa": ["Cocoa",500,7,0.047,0.026,19,35,false,"cocoa_start"],
	"coffee": ["Coffee",470,7,0.035,0.023,14,29,false,"coffee_start"],
	"tea": ["Tea",430,8,0.039,0.021,10,29,false,"tea_start"],
	"cotton": ["Cotton",320,9,0.039,0.023,16,37,false,"cotton_seed"],
	"flax": ["Flax",230,9,0.029,0.018,8,30,false,"flax_seed"],
	"bamboo": ["Bamboo",380,14,0.048,0.024,12,38,false,"bamboo_start"],
}
const JOBS := ["grower","agronomist","greenhouse_technician","water_operator",
	"packer","warehouse_keeper","mechanic","merchant","hauler","farm_manager",
	"oil_rigger","refinery_operator","tanker_driver","solar_technician","cook",
	"fisher","beekeeper","carpenter","citizen"]
const RECIPES := {
	"dry_banana": {"label":"Dry bananas","inputs":{"banana":5},"outputs":{"dried_food":2,"compost":1},"energy":0.2},
	"mill_rice": {"label":"Mill rice","inputs":{"rice":5},"outputs":{"flour":4,"compost":1},"energy":0.1},
	"mill_maize": {"label":"Mill maize","inputs":{"maize":5},"outputs":{"flour":4,"compost":1},"energy":0.1},
	"press_oil": {"label":"Press soybean oil","inputs":{"soybean":5},"outputs":{"cooking_oil":1,"meal":3,"compost":1},"energy":0.2},
	"weave_cloth": {"label":"Weave cotton cloth","inputs":{"cotton":4},"outputs":{"cloth":3,"compost":1},"energy":0.1},
	"make_rope": {"label":"Twist flax rope","inputs":{"flax":4},"outputs":{"rope":3,"compost":1},"energy":0.1},
	"make_crates": {"label":"Make bamboo crates","inputs":{"bamboo":4},"outputs":{"packaging":3,"compost":1},"energy":0.1},
	"compost": {"label":"Treat crop residues","inputs":{"compost":4,"water":1},"outputs":{"nutrients":2},"energy":0.1},
	"cook": {"label":"Cook wholesome meals","inputs":{"banana":2,"bean":1,"water":1},"outputs":{"meal":3,"compost":1},"energy":0.2},
	"cook_fish": {"label":"Cook fish stew","inputs":{"fish":2,"water":1},"outputs":{"meal":3},"energy":0.2},
	"refine": {"label":"Refine crude petroleum","inputs":{"crude_oil":10,"water":1},"outputs":{"gasoline":4,"diesel":3,"jet_fuel":2,"bitumen":1},"energy":0.4},
}
const BASE_PRICES := {"water":1,"nutrients":8,"compost":2,"packaging":3,
	"spare_parts":18,"solar_kit":90,"crude_oil":6,"gasoline":13,"diesel":12,
	"jet_fuel":18,"bitumen":4,"meal":8,"flour":6,"dried_food":12,
	"cooking_oil":14,"cloth":10,"rope":8,"fish":8,"honey":15,"lumber":4,"battery_kit":120}
const EARTH_LOCATIONS := {
	"player_earth":["Your Earth satchel",[0,4],350,"player"],
	"earth_market":["Canopy market",[0,-15],18000,"earth_market"],
	"cooperative":["Cooperative gardens",[-35,-23],10000,"cooperative"],
	"water":["Waterworks",[-18,-18],6000,"cooperative"],
	"kitchen":["Community kitchen",[18,-18],1200,"cooperative"],
	"warehouse":["Packing warehouse",[30,-35],6000,"cooperative"],
	"workshop":["Repair workshop",[40,15],3000,"cooperative"],
	"oil_rig":["Palm Coast oil platform",[120,-35],6000,"oil_company"],
	"refinery":["Coastal refinery",[95,10],6000,"refinery_company"],
	"gas_station":["Village fuel station",[60,35],1800,"gas_station"],
	"airfield":["Cargo airfield",[100,65],1800,"airfield"],
	"carrier":["Marine supply carrier",[145,-80],1800,"carrier"],
	"housing":["Hut neighborhood",[-32,25],1000,"cooperative"],
	"town_square":["Cooperative square",[0,4],1000,"cooperative"],
}
const MOON_LOCATIONS := {
	"player_moon":["Your Moon locker",[0,4],350,"player"],
	"moon_market":["First Landing market",[0,-12],14000,"moon_market"],
	"lunar_greenhouse":["Crater Gardens greenhouse",[-23,-10],6000,"lunar_cooperative"],
	"solar_array":["First Landing solar field",[28,-20],1000,"lunar_cooperative"],
	"habitat":["First Landing habitat",[-15,15],1600,"lunar_cooperative"],
	"cargo":["Lunar cargo pad",[28,20],3000,"transport"],
	"ice_mine":["Surveyed polar ice works",[-55,-35],4000,"lunar_cooperative"],
}
var state: Dictionary = {}
var crops: Dictionary = {}
var _accumulator := 0.0
# Server domain supplies one shared player book; offline games keep it empty.
var shared_players: Dictionary = {}
var multiplayer_mode := false
var _pedestrian_obstacles: Array = []
var _pedestrian_layout_ready := false

func _init() -> void:
	for id in CROP_ROWS:
		var r: Array = CROP_ROWS[id]
		crops[id] = {"id":id,"label":r[0],"duration":float(r[1]),"yield":int(r[2]),
			"water_rate":float(r[3]),"nutrient_rate":float(r[4]),"min_temp":float(r[5]),
			"max_temp":float(r[6]),"legume":bool(r[7]),"planting_item":r[8],
			"base_price":5 + int(r[1]) / 100}

func crop_catalog() -> Dictionary:
	return crops.duplicate(true)

func item_catalog() -> Dictionary:
	var items := {}
	for item in BASE_PRICES:
		items[item] = {"id":item,"label":str(item).replace("_"," ").capitalize(),"base_price":BASE_PRICES[item]}
	for id in crops:
		items[id] = {"id":id,"label":crops[id].label,"base_price":crops[id].base_price}
		var item: String = crops[id].planting_item
		items[item] = {"id":item,"label":item.replace("_"," ").capitalize(),"base_price":4}
	return items

func job_catalog() -> Array:
	return JOBS.duplicate()

func recipe_catalog() -> Dictionary:
	return RECIPES.duplicate(true)

func new_game(world_seed: int = 2026) -> void:
	_pedestrian_layout_ready = false
	_accumulator = 0.0
	state = {"schema_version":VERSION,"seed":world_seed,"time":400.0,"planet":"earth",
		"solar_illumination":0.5,"lunar_phase":1.0/12.0,
		"accounts":{"player":1800,"cooperative":20000,"earth_market":30000,"moon_market":22000,
			"oil_company":18000,"refinery_company":16000,"transport":10000,
			"gas_station":12000,"airfield":20000,"carrier":24000,"treasury":50000,"lunar_cooperative":20000},
		"inventories":{},"locations":{},"plots":{},"facilities":{},"citizens":{},
		"shipments":[],"batches":[],"vehicle_fuel":{},"quests":{},"ledger":[],"events":[],"recent_requests":{},"next_id":1,
		"climate":{"temperature":24.0,"rain":0.0},"initial_money":0,
		"resource_ledger":{"produced":{},"consumed":{}},
		"metrics":{"trades":0,"harvested":0,"deliveries":0,"work_completed":0,
			"crude_extracted":0,"crude_refined":0,"fuel_delivered":0,"fuel_used":0,
			"food_consumed":0,"crop_losses":0,"spoilage":0}}
	for id in EARTH_LOCATIONS:
		_add_location(id,"earth",EARTH_LOCATIONS[id])
	for id in MOON_LOCATIONS:
		_add_location(id,"moon",MOON_LOCATIONS[id])
	state.inventories.player_earth = {"banana":8,"water":40,"nutrients":8,"banana_start":3,
		"sweet_potato_slip":3,"bean_seed":3,"lettuce_seed":3,"tomato_seed":3,"rice_seed":3,
		"packaging":10,"spare_parts":3}
	state.inventories.player_moon = {"water":30,"nutrients":8,"lettuce_seed":3,
		"radish_seed":3,"tomato_seed":3,"solar_kit":1,"spare_parts":2,"packaging":8}
	for loc in ["earth_market","moon_market","cooperative","lunar_greenhouse"]:
		var inv: Dictionary = state.inventories[loc]
		inv.merge({"water":600,"nutrients":100,"packaging":100,"spare_parts":20,
			"solar_kit":4,"battery_kit":4,"meal":40,"banana":35,"bean":25})
		for id in crops:
			inv[crops[id].planting_item] = 12
			if not inv.has(id):
				inv[id] = 20
	state.inventories.oil_rig = {"diesel":100,"water":120,"spare_parts":10}
	state.inventories.refinery = {"crude_oil":40,"water":150,"spare_parts":10}
	state.inventories.gas_station = {"gasoline":12}
	state.inventories.airfield = {"jet_fuel":10}
	state.inventories.carrier = {"diesel":10,"bean":20,"packaging":20}
	state.inventories.kitchen = {"banana":30,"bean":20,"water":100,"meal":20}
	state.inventories.workshop = {"bamboo":40,"spare_parts":20,"packaging":15}
	state.inventories.water = {"water":500}
	state.inventories.ice_mine = {"water":200,"spare_parts":10}
	_add_facility("oil_rig","oil_rig",{"reserve":24000,"condition":0.94,"pressure":1.0})
	_add_facility("refinery","refinery",{"condition":0.92,"energy_kwh":250.0})
	_add_facility("workshop","workshop",{"condition":1.0,"energy_kwh":150.0})
	_add_facility("kitchen","kitchen",{"condition":1.0,"energy_kwh":150.0})
	_add_facility("water","waterworks",{"condition":1.0,"reservoir_l":20000.0})
	_add_facility("solar_array","solar",{"panels":6,"power_kw":11.172,"condition":0.98})
	_add_facility("ice_mine","ice_mine",{"reserve":12000,"condition":1.0})
	_add_facility("lunar_greenhouse","greenhouse",{"condition":0.91,"water_l":140.0,
		"battery_kwh":65.0,"battery_capacity_kwh":100.0,"power_kw":8.6,"demand_kw":8.6,
		"pressure":1.0,"cooling":1.0,"pump_condition":0.9,"temperature":23.0,"powered":true})
	var starter := ["banana","sweet_potato","bean","lettuce","tomato","rice"]
	for i in range(6):
		_add_plot("earth_%d"%(i+1),"earth",[-35+(i%3)*6,-35+(i/3)*6],"player",starter[i] if i<3 else "",0.78 if i<3 else 0.0)
		_add_plot("coop_%d"%(i+1),"earth",[-55+(i%3)*6,-35+(i/3)*6],"cooperative",starter[i],0.38+float(i)*0.06)
	for i in range(4):
		_add_plot("moon_%d"%(i+1),"moon",[-20+(i%2)*5,-20+(i/2)*5],"player","lettuce" if i==0 else "",0.64 if i==0 else 0.0)
	for i in range(2):
		_add_plot("lunar_coop_%d"%(i+1),"moon",[-30,-20+i*5],"lunar_cooperative","radish" if i==0 else "lettuce",0.4)
	for row in [
		["ookbar","Ookbar","farm_manager","cooperative","cooperative"],
		["mango","Mango","grower","cooperative","cooperative"],
		["fern","Fern","grower","cooperative","cooperative"],
		["root","Root","agronomist","cooperative","cooperative"],
		["willow","Willow","water_operator","water","cooperative"],
		["pip","Pip","packer","warehouse","cooperative"],
		["crate","Crate","warehouse_keeper","warehouse","cooperative"],
		["nana","Nana","merchant","earth_market","cooperative"],
		["tug","Tug","hauler","cooperative","transport"],
		["wrench","Wrench","mechanic","workshop","oil_company"],
		["derrick","Derrick","oil_rigger","oil_rig","oil_company"],
		["petra","Petra","refinery_operator","refinery","refinery_company"],
		["diesel","Diesel","tanker_driver","refinery","transport"],
		["jet","Jet","tanker_driver","refinery","transport"],
		["coco","Coco","cook","kitchen","cooperative"],
		["reed","Reed","fisher","carrier","cooperative"],
		["buzz","Buzz","beekeeper","cooperative","cooperative"],
		["bark","Bark","carpenter","workshop","cooperative"],
		["momo","Momo","citizen","town_square","cooperative"],
		["luna","Luna","grower","lunar_greenhouse","lunar_cooperative"],
		["seal","Seal","greenhouse_technician","lunar_greenhouse","lunar_cooperative"],
		["ray","Ray","solar_technician","solar_array","lunar_cooperative"],
		["ice","Ice","water_operator","ice_mine","lunar_cooperative"],
		["orbit","Orbit","merchant","moon_market","lunar_cooperative"]]:
		_add_citizen(row)
	_add_quest("first_harvest","A welcome for the neighborhood","Ookbar needs 8 kg of bananas for the village market.","banana",8,"earth_market",120,"ookbar")
	_add_quest("repair_stock","The missing seals","Deliver two spare parts to the lunar greenhouse.","spare_parts",2,"lunar_greenhouse",160,"seal")
	_add_quest("lunar_salad","First Lunar Feast","Supply 12 kg of fresh lettuce to First Landing.","lettuce",12,"moon_market",180,"luna")
	_add_quest("fuel_station","Keep the village moving","Deliver 12 litres of refined gasoline.","gasoline",12,"gas_station",230,"diesel")
	_add_quest("aircraft_fuel","Cargo flight departure","Deliver 10 litres of refined jet fuel.","jet_fuel",10,"airfield",260,"jet")
	_add_quest("solar_delivery","A brighter lunar morning","Supply one solar kit to the power crew.","solar_kit",1,"solar_array",160,"ray")
	state.initial_money = total_money()
	_event("Welcome to Roots & Rockets. Your Earth crops are nearly ready; Ookbar has a funded harvest contract.")

func _add_location(id: String, planet: String, row: Array) -> void:
	state.locations[id] = {"id":id,"label":row[0],"planet":planet,"position":row[1].duplicate(),"capacity":row[2],"owner":row[3]}
	state.inventories[id] = {}

func _add_facility(id: String, kind: String, properties: Dictionary) -> void:
	var location: Dictionary = state.locations[id]
	var facility := {"id":id,"label":location.label,"planet":location.planet,"position":location.position.duplicate(),"kind":kind,"status":"Operational"}
	facility.merge(properties)
	state.facilities[id] = facility

func _add_plot(id: String, planet: String, position: Array, owner: String, crop: String, growth: float) -> void:
	state.plots[id] = {"id":id,"planet":planet,"position":position,"owner":owner,
		"crop":crop,"growth":growth,"health":1.0,"moisture":75.0,"nutrients":70.0,
		"drainage":0.75,"disease":0.0,"last_crop":"","cycles":0,"automatic":owner!="player",
		"status":"Growing" if crop!="" else "Ready for planting"}

func _add_citizen(row: Array) -> void:
	var id: String = row[0]
	var loc: Dictionary = state.locations[row[3]]
	state.accounts[id] = 100
	state.citizens[id] = {"id":id,"name":row[1],"job":row[2],"planet":loc.planet,
		"employer":row[4],"target":row[3],"position":loc.position.duplicate(),"destination":loc.position.duplicate(),
		"activity":"Starting shift","task":"Starting shift","blocker":"","carrying":{},
		"shift":[5,22],"skill":0.55+float(id.length()%4)*0.08,"needs":{"hunger":0.12,"fatigue":0.06},
		"wage":2,"enabled":true,"completed":0,"work_remaining":0.0,"cooldown":0.0,
		"memories":[],"observations":[],"route":[],"_job":{}}
	var worker: Dictionary = state.citizens[id]
	worker.position = _free_work_position(worker, worker.position, false)
	worker.destination = worker.position.duplicate()

func _add_quest(id: String, title: String, description: String, item: String, quantity: int, destination: String, reward: int, giver: String) -> void:
	state.accounts["escrow_"+id] = 0
	state.quests[id] = {"id":id,"title":title,"description":description,"item":item,"quantity":quantity,
		"destination":destination,"planet":state.locations[destination].planet,"reward":reward,
		"status":"available","giver":giver,"deadline":0.0}

func tick(dt: float) -> void:
	if state.is_empty() or not is_finite(dt) or dt<=0.0:
		return
	_accumulator = minf(_accumulator+minf(dt,8.0),16.0)
	var count := 0
	while _accumulator>=1.0 and count<8:
		_accumulator -= 1.0
		_step(1.0)
		count += 1

func _step(dt: float) -> void:
	if not _pedestrian_layout_ready:
		for id in _ids(state.citizens):
			var person: Dictionary = state.citizens[id]
			if not bool(person.get("physical_transport", false)):
				person.position = _free_work_position(person, person.position, false)
		_pedestrian_layout_ready = true
	state.time += dt
	_update_habitat(dt)
	for id in _ids(state.plots):
		_grow_plot(state.plots[id],dt)
	for id in _ids(state.citizens):
		_update_citizen(state.citizens[id],dt)
	_update_shipments(dt)
	_update_batches(dt)
	if int(state.time)%20==0:
		_consume_fuel()
	if int(state.time)%180==0:
		_spoil_food()
	for id in state.quests:
		var q: Dictionary = state.quests[id]
		if q.status=="active" and float(state.time)>float(q.deadline):
			_transfer("escrow_"+id,"treasury",int(q.reward),"Contract expired")
			q.status="available"
			_event("Contract expired: "+q.title+". Escrow returned to town.")

func _update_habitat(dt: float) -> void:
	state.lunar_phase = fmod(float(state.time),LUNAR_DAY_SECONDS)/LUNAR_DAY_SECONDS
	state.solar_illumination = maxf(0.0,sin(TAU*float(state.lunar_phase)))
	var solar: Dictionary = state.facilities.solar_array
	var room: Dictionary = state.facilities.lunar_greenhouse
	solar.condition = maxf(0.2,float(solar.condition)-dt*0.000012)
	solar.power_kw = int(solar.panels)*3.8*float(state.solar_illumination)*float(solar.condition)
	var beds := 0
	for id in _ids(state.plots):
		if state.plots[id].planet=="moon" and state.plots[id].crop!="":
			beds += 1
	room.demand_kw = 5.0+float(beds)*1.2
	var hours := dt/50.0
	var available := float(solar.power_kw)+float(room.battery_kwh)/hours
	room.powered = available+0.0001>=float(room.demand_kw)
	room.power_kw = minf(available,float(room.demand_kw))
	room.battery_kwh = clampf(float(room.battery_kwh)+(float(solar.power_kw)-float(room.demand_kw))*hours,0.0,float(room.battery_capacity_kwh))
	room.pump_condition = maxf(0.0,float(room.pump_condition)-dt*0.000025)
	room.pressure = maxf(0.0,float(room.pressure)-dt*(0.000006 if float(room.condition)>0.3 else 0.0004))
	room.temperature = move_toward(float(room.temperature),23.0 if room.powered and float(room.cooling)>0.3 else 40.0,dt*0.015)
	room.status = "Operational"
	if not room.powered: room.status="Power deficit: expand solar generation or conserve battery"
	elif float(room.water_l)<10.0: room.status="Water reserve low: deliver water"
	elif float(room.pump_condition)<0.3: room.status="Irrigation pump needs a spare part"
	elif float(room.pressure)<0.7: room.status="Pressure leak: technician repair required"
	elif float(room.cooling)<0.3: room.status="Cooling loop requires service"
	for id in ["workshop","kitchen","refinery"]:
		var facility: Dictionary = state.facilities[id]
		var hour := fmod(float(state.time),DAY_SECONDS)/50.0
		facility.energy_kwh = minf(300.0,float(facility.energy_kwh)+maxf(0.0,sin((hour-6.0)*PI/12.0))*dt*0.04)

func _grow_plot(plot: Dictionary, dt: float) -> void:
	if plot.crop=="":
		plot.status="Ready for planting"
		return
	if float(plot.health)<=0.0:
		plot.status="Crop lost; clear and replant"
		return
	var crop: Dictionary = crops[plot.crop]
	var temperature := float(state.climate.temperature)
	var service_factor := 1.0
	if plot.planet=="moon":
		var room: Dictionary = state.facilities.lunar_greenhouse
		temperature=float(room.temperature)
		if not room.powered or float(room.pressure)<0.7 or float(room.cooling)<0.3: service_factor=0.0
		if room.powered and float(room.pump_condition)>=0.3 and float(room.water_l)>=0.05 and float(plot.moisture)<78.0:
			var used := minf(dt*0.12,float(room.water_l))
			room.water_l-=used
			plot.moisture=minf(100.0,float(plot.moisture)+used*1.4)
	else:
		plot.moisture=minf(100.0,float(plot.moisture)+float(state.climate.rain)*dt*0.06)
	if float(plot.growth)>=1.0:
		# Ripe plants still respire and require functioning life support. A full
		# growth bar must not make an unpressurized lunar crop immortal.
		plot.moisture=maxf(0.0,float(plot.moisture)-float(crop.water_rate)*dt*0.5)
		var stressed := service_factor==0.0 or float(plot.moisture)<=0.0
		plot.health=maxf(0.0,float(plot.health)-dt*(0.0008 if stressed else 0.00002))
		plot.status="Harvest urgently: crop stressed" if stressed else "Ready to harvest"
		if float(plot.health)<=0.0:
			plot.status="Crop lost; clear and replant"
			state.metrics.crop_losses+=1
		return
	plot.moisture=maxf(0.0,float(plot.moisture)-float(crop.water_rate)*dt)
	var moisture := clampf(float(plot.moisture)/20.0,0.0,1.0)
	if float(plot.moisture)>92.0 and plot.crop not in ["rice","taro"]: moisture=0.35
	var nutrition := clampf(float(plot.nutrients)/15.0,0.0,1.0)
	var climate := 1.0 if temperature>=float(crop.min_temp) and temperature<=float(crop.max_temp) else 0.15
	var factor := moisture*nutrition*climate*service_factor*(1.0-float(plot.disease)*0.6)
	plot.growth=minf(1.0,float(plot.growth)+dt/float(crop.duration)*factor*float(plot.health))
	plot.nutrients=maxf(0.0,float(plot.nutrients)-float(crop.nutrient_rate)*dt*factor)
	var was_alive := float(plot.health)>0.0
	plot.health=clampf(float(plot.health)+dt*(0.0006 if factor>=0.5 else -0.0008),0.0,1.0)
	if was_alive and float(plot.health)<=0.0: state.metrics.crop_losses+=1
	plot.status="Growing"
	if service_factor==0.0: plot.status="Habitat utilities unavailable"
	elif moisture<0.9: plot.status="Waterlogged roots" if float(plot.moisture)>92.0 else "Needs water"
	elif nutrition<0.9: plot.status="Needs nutrients"
	elif climate<1.0: plot.status="Temperature outside crop range"
	if float(plot.health)<=0.0: plot.status="Crop lost; clear and replant"
	elif float(plot.growth)>=1.0: plot.status="Ready to harvest"

func action(kind: String, payload: Dictionary = {}) -> Dictionary:
	if state.is_empty(): return _result(false,"Start a Frontier world first.")
	var request_id := str(payload.get("request_id",""))
	if request_id!="" and state.recent_requests.has(request_id):
		return state.recent_requests[request_id].duplicate(true)
	var result: Dictionary = _action(kind,payload)
	if result.ok and kind!="inspect": _event(result.message)
	if request_id!="":
		if state.recent_requests.size()>=64: state.recent_requests.erase(state.recent_requests.keys()[0])
		state.recent_requests[request_id]=result.duplicate(true)
	return result

func action_for(actor: String, planet: String, kind: String, payload: Dictionary = {}) -> Dictionary:
	if not multiplayer_mode or not shared_players.has(actor) or planet not in ["earth","moon"]:
		return _result(false,"Unknown society member or world.")
	if kind=="travel": return _result(false,"Travel belongs to the expedition authority.")
	var result := _action(kind,payload,actor,planet)
	if result.ok and kind!="inspect": _event(result.message)
	return result

func _action(kind: String, payload: Dictionary, actor: String = "player", realm: String = "") -> Dictionary:
	if realm.is_empty(): realm=str(state.planet)
	var player_location := inventory_location(actor,realm)
	match kind:
		"travel":
			var planet := str(payload.get("planet",""))
			if planet not in ["earth","moon"]: return _result(false,"Unknown destination.")
			state.planet=planet
			return _result(true,"Welcome to "+("First Landing. Goods remain at their recorded location." if planet=="moon" else "the Canopy Cooperative."))
		"plant","harvest","water","fertilize","clear_plot","toggle_plot":
			var id := str(payload.get("plot",""))
			if not state.plots.has(id): return _result(false,"Choose a valid plot.")
			var plot: Dictionary = state.plots[id]
			if plot.owner!=actor or plot.planet!=realm: return _result(false,"Use a plot you own on your current world.")
			match kind:
				"plant": return _plant(plot,str(payload.get("crop","")),player_location)
				"harvest": return _harvest(plot,player_location)
				"water": return _water_plot(plot,player_location)
				"fertilize": return _fertilize_plot(plot,player_location)
				"toggle_plot":
					plot.automatic=not bool(plot.automatic)
					return _result(true,"Crew care "+("enabled" if plot.automatic else "paused")+" for "+id+". Hired growers use your local supplies.")
			plot.crop=""
			plot.growth=0.0
			plot.health=1.0
			return _result(true,"Plot cleared for a new planting.")
		"buy","sell":
			var market := str(payload.get("market",realm+"_market"))
			var item := str(payload.get("item",""))
			var quantity := _quantity(payload.get("quantity",1))
			if market not in ["earth_market","moon_market","refinery"] or not _same_planet(market,player_location):
				return _result(false,"Trade at a market on your current world.")
			if market=="refinery" and item not in ["crude_oil","gasoline","diesel","jet_fuel","bitumen","water","spare_parts"]:
				return _result(false,"The refinery trades petroleum products, process water and maintenance parts.")
			return _trade(market if kind=="buy" else player_location,player_location if kind=="buy" else market,item,quantity,kind=="buy")
		"ship": return _ship(payload,actor,realm)
		"accept_quest","deliver_quest","cancel_quest": return _quest_action(kind,str(payload.get("id","")),actor,realm)
		"assign_job":
			var id := str(payload.get("citizen",""))
			var job := str(payload.get("job",""))
			if not state.citizens.has(id) or job not in JOBS: return _result(false,"Choose a citizen and a listed practical job.")
			var worker: Dictionary = state.citizens[id]
			if worker.planet=="moon" and job not in ["grower","agronomist","greenhouse_technician","water_operator","solar_technician","merchant","farm_manager","citizen"]:
				return _result(false,"This job needs Earth facilities.")
			if not worker.carrying.is_empty() or not worker._job.is_empty():
				worker["pending_job"]=job
				worker["pending_employer"]=actor
				return _result(true,worker.name+" will join your crew as "+job.replace("_"," ")+" after completing the committed task or delivery.")
			worker.job=job
			worker.employer=actor
			worker.enabled=true
			worker.cooldown=0.0
			return _result(true,worker.name+" hired as "+job.replace("_"," ")+"; wage "+str(worker.wage)+" credits per completed task.")
		"toggle_worker":
			var id := str(payload.get("citizen",""))
			if not state.citizens.has(id): return _result(false,"Unknown citizen.")
			var worker: Dictionary = state.citizens[id]
			worker.enabled=not bool(worker.enabled)
			return _result(true,worker.name+(" resumed work." if worker.enabled else " will pause after completing the committed task."))
		"repair":
			var id := str(payload.get("facility","lunar_greenhouse"))
			if not state.facilities.has(id) or state.facilities[id].planet!=realm: return _result(false,"Visit the facility's world to repair it.")
			return _repair(id,player_location)
		"refill_habitat":
			if realm!="moon": return _result(false,"Visit the lunar greenhouse first.")
			var quantity := _quantity(payload.get("quantity",20))
			if quantity==0 or stock(player_location,"water")<quantity: return _result(false,"Not enough water in your Moon locker.")
			if float(state.facilities.lunar_greenhouse.water_l)+quantity>500.0: return _result(false,"The greenhouse reservoir holds 500 litres.")
			_consume(player_location,"water",quantity,"Fill greenhouse irrigation reservoir")
			state.facilities.lunar_greenhouse.water_l+=quantity
			return _result(true,"Transferred %d litres to the greenhouse reservoir."%quantity)
		"build_solar":
			if realm!="moon": return _result(false,"Build the solar array at First Landing.")
			if int(state.facilities.solar_array.panels)>=12: return _result(false,"The prepared solar field has twelve mounting positions.")
			if stock(player_location,"solar_kit")<1 or balance(actor)<150: return _result(false,"Installation requires one solar kit and 150 trade credits.")
			_consume(player_location,"solar_kit",1,"Installed solar equipment")
			_transfer(actor,"lunar_cooperative",150,"Solar installation labor")
			state.facilities.solar_array.panels+=1
			return _result(true,"Installed a 3.8 kW peak solar panel. Generation follows sunlight and condition.")
		"upgrade_battery":
			if realm!="moon": return _result(false,"Upgrade storage at the lunar solar field.")
			var room: Dictionary = state.facilities.lunar_greenhouse
			if float(room.battery_capacity_kwh)>=1200.0: return _result(false,"Battery housing is at its 1200 kWh limit.")
			if stock(player_location,"battery_kit")<1 or balance(actor)<120: return _result(false,"Battery expansion needs one battery kit and 120 credits.")
			_consume(player_location,"battery_kit",1,"Installed battery storage")
			_transfer(actor,"lunar_cooperative",120,"Battery installation labor")
			room.battery_capacity_kwh=minf(1200.0,float(room.battery_capacity_kwh)+100.0)
			return _result(true,"Added 100 kWh of empty battery storage. Solar surplus will charge it.")
		"refuel":
			return _refuel(payload,actor,realm)
		"process":
			var recipe := str(payload.get("recipe",""))
			if realm!="earth": return _result(false,"Use the Earth processing workshop.")
			return _start_processing(recipe,player_location,"refinery" if recipe=="refine" else "workshop")
		"inspect":
			var target := str(payload.get("target",""))
			if state.citizens.has(target):
				var worker: Dictionary = state.citizens[target]
				return _result(true,worker.name+": "+worker.activity+(" — "+worker.blocker if worker.blocker!="" else "")+". Completed tasks: "+str(worker.completed))
			if state.plots.has(target):
				var plot: Dictionary = state.plots[target]
				return _result(true,"%s: %s. Water %.0f%%; nutrients %.0f%%; health %.0f%%; growth %.0f%%."%[target,plot.status,plot.moisture,plot.nutrients,float(plot.health)*100.0,float(plot.growth)*100.0])
			if state.facilities.has(target): return _result(true,state.facilities[target].label+": "+state.facilities[target].status)
			return _result(false,"Choose a citizen, plot or facility to inspect.")
	return _result(false,"Unknown Frontier action: "+kind)

func _plant(plot: Dictionary, crop_id: String, location: String) -> Dictionary:
	if not crops.has(crop_id): return _result(false,"Select a crop from the 24-crop catalogue.")
	if plot.crop!="": return _result(false,"This plot is already planted.")
	var crop: Dictionary = crops[crop_id]
	if stock(location,crop.planting_item)<1: return _result(false,"Need one "+str(crop.planting_item).replace("_"," ")+".")
	if plot.planet=="moon" and not state.facilities.lunar_greenhouse.powered: return _result(false,"Restore greenhouse power before planting.")
	_consume(location,crop.planting_item,1,"Plant "+crop.label)
	plot.crop=crop_id
	plot.growth=0.0
	plot.health=1.0
	plot.disease=minf(0.8,float(plot.disease)+0.10) if plot.last_crop==crop_id else maxf(0.0,float(plot.disease)-0.12)
	if bool(crop.legume) and plot.last_crop!=crop_id: plot.nutrients=minf(100.0,float(plot.nutrients)+4.0)
	plot.status="Establishing roots"
	return _result(true,"Planted "+crop.label+" in "+plot.id+".")

func _harvest(plot: Dictionary, location: String) -> Dictionary:
	if plot.crop=="" or float(plot.growth)<1.0 or float(plot.health)<=0.0: return _result(false,"This crop is not ready to harvest.")
	var quantity := maxi(1,int(round(float(crops[plot.crop]["yield"])*float(plot.health))))
	if not _has_room(location,quantity+1): return _result(false,"Storage is full; sell or ship some goods first.")
	var label: String = crops[plot.crop].label
	_produce(location,plot.crop,quantity,"Harvest from "+str(plot.id))
	_produce(location,"compost",1,"Crop residues")
	plot.last_crop=plot.crop
	plot.crop=""
	plot.growth=0.0
	plot.cycles+=1
	plot.status="Ready for planting"
	state.metrics.harvested+=quantity
	return _result(true,"Harvested %d kg of %s into %s."%[quantity,label,state.locations[location].label])

func _water_plot(plot: Dictionary, location: String) -> Dictionary:
	if float(plot.moisture)>=85.0: return _result(false,"The soil is already wet enough.")
	if stock(location,"water")<5: return _result(false,"Watering requires five litres of water.")
	_consume(location,"water",5,"Irrigate "+str(plot.id))
	plot.moisture=minf(100.0,float(plot.moisture)+35.0)
	return _result(true,"Irrigated "+str(plot.id)+" with five litres.")

func _fertilize_plot(plot: Dictionary, location: String) -> Dictionary:
	if float(plot.nutrients)>=90.0: return _result(false,"This bed already has sufficient nutrients.")
	if stock(location,"nutrients")<1: return _result(false,"Need one unit of nutrients.")
	_consume(location,"nutrients",1,"Feed "+str(plot.id))
	plot.nutrients=minf(100.0,float(plot.nutrients)+25.0)
	return _result(true,"Applied nutrients to "+str(plot.id)+".")

func _trade(source: String, destination: String, item: String, quantity: int, buying: bool) -> Dictionary:
	if quantity<=0 or not _known_item(item) or not state.locations.has(source) or not state.locations.has(destination): return _result(false,"Choose a known item and a whole quantity from 1 to 1000.")
	if stock(source,item)<quantity: return _result(false,"Seller has only %d units of %s."%[stock(source,item),item.replace("_"," ")])
	if not _has_room(destination,quantity): return _result(false,"Buyer storage has no room for this order.")
	var market := source if buying else destination
	var price := quote(market,item,quantity,buying)
	var buyer: String = state.locations[destination].owner
	var seller: String = state.locations[source].owner
	if balance(buyer)<price: return _result(false,"Buyer cannot fund this order; no goods or credits moved.")
	_move_goods(source,destination,item,quantity)
	_transfer(buyer,seller,price,"Trade %d %s"%[quantity,item])
	state.metrics.trades+=1
	return _result(true,"%s %d %s for %d trade credits."%["Bought" if buying else "Sold",quantity,item.replace("_"," "),price])

func quote(market: String, item: String, quantity: int = 1, buy: bool = false) -> int:
	if quantity<1 or quantity>1000 or not state.inventories.has(market) or not _known_item(item): return 0
	var base := _base_price(item)
	var available := stock(market,item)
	var target := 50.0 if item in crops else 30.0
	var cost := 0
	# Each unit consumes depth. A bulk sale never reuses its first scarcity price.
	for unit in range(quantity):
		var projected := maxi(1,available+(-unit if buy else unit))
		var scarcity := clampf(pow(target/float(projected),0.6),0.5,2.0)
		var freight := 1.2 if str(state.locations[market].planet)=="moon" else 1.0
		cost+=maxi(1,int(ceil(base*scarcity*freight*(1.12 if buy else 0.82))))
	return cost

func _ship(payload: Dictionary, actor: String = "player", realm: String = "") -> Dictionary:
	if realm.is_empty(): realm=str(state.planet)
	var source := str(payload.get("from",inventory_location(actor,realm)))
	var destination := str(payload.get("to",inventory_location(actor,"moon" if realm=="earth" else "earth")))
	# UI aliases name the caller's own lockers, never another player's storage.
	if source in ["player_earth","player_moon"]: source=inventory_location(actor,source.trim_prefix("player_"))
	if destination in ["player_earth","player_moon"]: destination=inventory_location(actor,destination.trim_prefix("player_"))
	var item := str(payload.get("item",""))
	var quantity := _quantity(payload.get("quantity",1))
	if source not in [inventory_location(actor,"earth"),inventory_location(actor,"moon")] or destination not in [inventory_location(actor,"earth"),inventory_location(actor,"moon")] or source==destination or state.locations[source].planet!=realm: return _result(false,"Ship from your current locker to your locker on the other world.")
	if quantity<1 or not _known_item(item) or stock(source,item)<quantity: return _result(false,"Cargo must exist in your origin locker.")
	var packages := maxi(1,int(ceil(float(quantity)/10.0)))
	var needed := packages+(quantity if item=="packaging" else 0)
	var cost := 20+quantity*2+packages
	if stock(source,"packaging")<needed or balance(actor)<cost: return _result(false,"Freight needs %d packaging and %d credits, including gross cargo mass."%[packages,cost])
	if not _has_room(destination,quantity+packages): return _result(false,"Destination capacity is occupied or reserved by incoming cargo.")
	if state.shipments.size()>=24: return _result(false,"All freight manifests are occupied; wait for arrival.")
	_remove_goods(source,item,quantity)
	_remove_goods(source,"packaging",packages)
	_transfer(actor,"transport",cost,"Earth–Moon freight")
	_reserve_location(destination,quantity+packages)
	var id := _next_id("freight")
	state.shipments.append({"id":id,"from":source,"to":destination,"item":item,
		"quantity":quantity,"packaging":packages,"owner":actor,"remaining":90.0,
		"duration":90.0,"status":"In transit","cost":cost})
	return _result(true,"Manifest %s departed with %d %s; arrival in 90 seconds."%[id,quantity,item.replace("_"," ")])

func _update_shipments(dt: float) -> void:
	for i in range(state.shipments.size()-1,-1,-1):
		var shipment: Dictionary = state.shipments[i]
		shipment.remaining=maxf(0.0,float(shipment.remaining)-dt)
		if float(shipment.remaining)>0.0: continue
		_reserve_location(shipment.to,-int(shipment.quantity)-int(shipment.packaging))
		_add_goods(shipment.to,shipment.item,int(shipment.quantity))
		_add_goods(shipment.to,"packaging",int(shipment.packaging))
		state.metrics.deliveries+=1
		_event("Freight arrived: %d %s in %s."%[shipment.quantity,shipment.item,state.locations[shipment.to].label])
		state.shipments.remove_at(i)

func _quest_action(kind: String, id: String, actor: String = "player", realm: String = "") -> Dictionary:
	if realm.is_empty(): realm=str(state.planet)
	if not state.quests.has(id) or state.quests[id].has("actor"): return _result(false,"Unknown contract.")
	if actor!="player" and state.quests[id].planet!=realm: return _result(false,"Visit this contract's world.")
	var original_id := id
	if actor!="player":
		id=actor+"__"+id
		if not state.quests.has(id):
			if kind!="accept_quest": return _result(false,"Accept this contract before delivering goods.")
			if balance("treasury")<int(state.quests[original_id].reward): return _result(false,"The town cannot fund this contract.")
			var personal: Dictionary=state.quests[original_id].duplicate(true)
			personal.id=id
			personal.actor=actor
			personal.template=original_id
			state.quests[id]=personal
			state.accounts["escrow_"+id]=0
	var quest: Dictionary = state.quests[id]
	var escrow := "escrow_"+id
	if kind=="accept_quest":
		if quest.status!="available": return _result(false,"This contract is already active or completed.")
		if int(state.accounts.treasury)<int(quest.reward): return _result(false,"The town cannot fund this contract.")
		_transfer("treasury",escrow,int(quest.reward),"Fund contract "+id)
		quest.status="active"
		quest.deadline=float(state.time)+1800.0
		return _result(true,quest.title+" accepted. Payment is held in escrow for 30 minutes.")
	if quest.status!="active": return _result(false,"Accept this contract before delivering goods.")
	if kind=="cancel_quest":
		_transfer(escrow,"treasury",int(quest.reward),"Cancel contract "+id)
		quest.status="available"
		return _result(true,"Contract canceled; escrow returned to town.")
	var origin := inventory_location(actor,realm)
	if quest.planet!=realm or stock(origin,quest.item)<int(quest.quantity): return _result(false,"Deliver %d %s from your %s inventory."%[quest.quantity,quest.item.replace("_"," "),quest.planet])
	if not _has_room(quest.destination,int(quest.quantity)) or balance(escrow)<int(quest.reward): return _result(false,"Destination capacity or escrow unavailable; no goods moved.")
	_move_goods(origin,quest.destination,quest.item,int(quest.quantity))
	_transfer(escrow,actor,int(quest.reward),"Complete contract "+original_id)
	quest.status="complete"
	state.metrics.deliveries+=1
	return _result(true,"Completed "+quest.title+": "+str(quest.reward)+" trade credits received.")

func _repair(id: String, source: String) -> Dictionary:
	if stock(source,"spare_parts")<1: return _result(false,"Repair requires a spare part from "+str(state.locations[source].label)+".")
	var facility: Dictionary = state.facilities[id]
	_consume(source,"spare_parts",1,"Repair "+id)
	facility.condition=1.0
	if id=="lunar_greenhouse":
		facility.pressure=1.0
		facility.cooling=1.0
		facility.pump_condition=1.0
	facility.status="Operational"
	return _result(true,"Repaired "+str(facility.label)+"; replacement part installed.")

func _process_recipe(id: String, location: String, facility_id: String) -> Dictionary:
	if not RECIPES.has(id): return _result(false,"Choose a listed processing recipe.")
	var recipe: Dictionary = RECIPES[id]
	var facility: Dictionary = state.facilities[facility_id]
	if float(facility.get("condition",1.0))<0.3 or float(facility.get("energy_kwh",0.0))<float(recipe.energy): return _result(false,"Processing facility needs repair or energy.")
	var inputs := 0
	var outputs := 0
	for item in recipe.inputs:
		if stock(location,item)<int(recipe.inputs[item]): return _result(false,"Need %d %s for %s."%[recipe.inputs[item],item.replace("_"," "),recipe.label])
		inputs+=int(recipe.inputs[item])
	for item in recipe.outputs: outputs+=int(recipe.outputs[item])
	if not _has_room(location,maxi(0,outputs-inputs)): return _result(false,"Storage has no room for finished goods.")
	for item in recipe.inputs: _consume(location,item,int(recipe.inputs[item]),recipe.label)
	for item in recipe.outputs: _produce(location,item,int(recipe.outputs[item]),recipe.label)
	facility.energy_kwh-=float(recipe.energy)
	if id=="refine": state.metrics.crude_refined+=10
	return _result(true,"Completed "+recipe.label+"; inputs consumed and outputs stored.")

func _update_citizen(worker: Dictionary, dt: float) -> void:
	worker.needs.hunger=minf(1.0,float(worker.needs.hunger)+dt*0.00038)
	worker.cooldown=maxf(0.0,float(worker.cooldown)-dt)
	if worker._job.is_empty():
		if worker.carrying.is_empty() and worker.has("pending_job"):
			worker.job=str(worker.pending_job)
			worker.employer=str(worker.get("pending_employer","player"))
			worker.erase("pending_employer")
			worker.enabled=true
			worker.cooldown=0.0
			worker.erase("pending_job")
		if not worker.enabled:
			worker.activity="Off duty by standing order"
			worker.task=worker.activity
			return
		if float(worker.cooldown)>0.0: return
		_plan_job(worker)
		if worker._job.is_empty(): return
	var job: Dictionary = worker._job
	if not worker.has("route"): _route_to(worker,job.op in ["plant","harvest","water","fertilize","treat_crop","clear_crop"])
	var position := Vector2(float(worker.position[0]),float(worker.position[1]))
	var waypoint: Array = worker.route[0] if not worker.route.is_empty() else worker.destination
	var destination := Vector2(float(waypoint[0]),float(waypoint[1]))
	# Road junctions and service centers are shared navigation points, not work
	# positions. If another body occupies an intermediate waypoint, capture it
	# from just outside personal space so the route can continue around them.
	# The final work/cargo destination remains strict and collision-reserved.
	var arrival_radius := 0.1
	var waypoint_distance := position.distance_to(destination)
	if not bool(worker.get("physical_transport",false)) and worker.route.size()>1 \
			and waypoint_distance<=OCCUPIED_WAYPOINT_CAPTURE_RADIUS \
			and not _pedestrian_segment_clear(worker,destination,destination):
		arrival_radius=OCCUPIED_WAYPOINT_CAPTURE_RADIUS
	if bool(worker.get("physical_transport",false)):
		var motion: Dictionary=state.get("traffic",{}).get(worker.id,{})
		var ready := int(motion.get("epoch",-1))==int(worker.get("motion_epoch",0)) \
			and float(state.time)-float(motion.get("reported_at",-100.0))<=3.0 \
			and bool(motion.get("arrived",false)) and float(motion.get("speed",1.0))<=0.35
		if not ready:
			worker.blocker=str(motion.get("blocker","Waiting for the delivery vehicle"))
			worker.activity="Driving: "+str(job.label) if worker.blocker.is_empty() else "Waiting: "+worker.blocker
			worker.task=worker.activity
			return
		worker.route.clear()
		worker.blocker=""
	elif waypoint_distance>arrival_radius:
		var obstruction := str(worker.get("route_blocked",""))
		if not obstruction.is_empty():
			worker.blocker=obstruction
			worker.activity="Waiting for a clear route"
			worker.task=worker.activity
			return
		worker.blocker=""
		var previous_position := position
		position = pedestrian_step(worker, position, destination, dt)
		worker["walking_speed"] = position.distance_to(previous_position) / maxf(dt, 0.001)
		worker.position=[position.x,position.y]
		worker.activity="Traveling: "+str(job.label)
		worker.task=worker.activity
		worker.needs.fatigue=minf(1.0,float(worker.needs.fatigue)+dt*0.00025)
		return
	if not worker.route.is_empty():
		worker.route.pop_front()
		return
	worker.activity=str(job.label)
	worker.task=worker.activity
	worker.work_remaining=maxf(0.0,float(worker.work_remaining)-dt)
	if float(worker.work_remaining)>0.0: return
	var result: Dictionary = _execute_job(worker,job)
	worker._job={}
	worker.cooldown=3.0 if result.ok else 12.0
	worker.blocker="" if result.ok else str(result.message)
	worker.activity=str(result.message)
	worker.task=worker.activity
	if result.ok and job.op not in ["rest","eat","leisure","inspect"]:
		worker.completed+=1
		worker.skill=minf(1.0,float(worker.skill)+0.001)
		worker.needs.fatigue=minf(1.0,float(worker.needs.fatigue)+0.002)
		state.metrics.work_completed+=1
		var wage := mini(int(worker.wage),balance(worker.employer))
		if wage>0: _transfer(worker.employer,worker.id,wage,"Wage: "+str(worker.job))
		_remember(worker,str(result.message))

func _plan_job(worker: Dictionary) -> void:
	if not worker.carrying.is_empty():
		_set_job(worker,"unload",str(worker.carrying.to),"Delivering "+str(worker.carrying.item).replace("_"," "),{},4.0)
		return
	var hour := fmod(float(state.time),DAY_SECONDS)/50.0
	if hour<float(worker.shift[0]) or hour>=float(worker.shift[1]) or float(worker.needs.fatigue)>0.8:
		_set_job(worker,"rest","habitat" if worker.planet=="moon" else "housing","Resting at home",{},30.0)
		return
	if float(worker.needs.hunger)>0.6:
		_set_job(worker,"eat","moon_market" if worker.planet=="moon" else "kitchen","Buying a meal and eating",{},8.0)
		return
	if balance(worker.employer)<int(worker.wage):
		_block(worker,"Employer cannot fund the next wage")
		return
	var store := "lunar_greenhouse" if worker.planet=="moon" else "cooperative"
	if worker.employer=="player" or shared_players.has(worker.employer): store=inventory_location(str(worker.employer),str(worker.planet))
	match str(worker.job):
		"grower":
			for id in _ids(state.plots):
				var plot: Dictionary = state.plots[id]
				if plot.planet!=worker.planet or not plot.automatic or plot.owner!=worker.employer: continue
				var op := ""
				if plot.crop!="" and float(plot.health)<=0.0: op="clear_crop"
				elif plot.crop!="" and float(plot.growth)>=1.0: op="harvest"
				elif float(plot.moisture)<45.0 and stock(store,"water")>=5: op="water"
				elif float(plot.nutrients)<35.0 and stock(store,"nutrients")>0: op="fertilize"
				elif plot.crop=="": op="plant"
				if op!="":
					_set_job(worker,op,"lunar_greenhouse" if worker.planet=="moon" else "cooperative",op.capitalize()+" "+id,{"plot":id,"source":store},7.0)
					worker.destination=_free_work_position(worker,[plot.position[0],float(plot.position[1])+2.5],true)
					_route_to(worker,true)
					return
			_block(worker,"Crops are growing; no care is currently needed")
		"oil_rigger":
			_set_job(worker,"extract","oil_rig","Operating derrick and separating crude",{},10.0)
		"refinery_operator":
			_set_job(worker,"refine","refinery","Distilling and refining petroleum",{},12.0)
		"tanker_driver":
			_plan_tanker(worker)
		"merchant":
			var market := str(worker.planet)+"_market"
			for item in crops:
				if stock(store,item)>10 and stock(market,item)<80:
					_set_job(worker,"load_trade",store,"Collecting surplus "+str(item),{"from":store,"to":market,"item":item,"quantity":mini(12,stock(store,item)-10)},5.0)
					return
			for item in ["water","nutrients","spare_parts"]:
				if stock(store,item)<15 and stock(market,item)>=10:
					_set_job(worker,"load_trade",market,"Purchasing farm inputs",{"from":market,"to":store,"item":item,"quantity":10},5.0)
					return
			for id in crops:
				var item: String = crops[id].planting_item
				if stock(store,item)<2 and stock(market,item)>=4:
					_set_job(worker,"load_trade",market,"Purchasing planting stock",{"from":market,"to":store,"item":item,"quantity":4},5.0)
					return
			_block(worker,"Stores have adequate cover; waiting for a funded opportunity")
		"hauler","packer","warehouse_keeper":
			for item in ["banana","bean","water"]:
				if stock("kitchen",item)<20 and stock("cooperative",item)>=8:
					_set_job(worker,"load_move","cooperative","Loading kitchen supply crates",{"from":"cooperative","to":"kitchen","item":item,"quantity":8},5.0)
					return
			if worker.job=="packer" and stock("workshop","bamboo")>=4:
				_set_job(worker,"crate","workshop","Building returnable bamboo crates",{},12.0)
			else:
				_set_job(worker,"inspect","warehouse","Inspecting storage and inventory records",{},10.0)
		"greenhouse_technician":
			var room: Dictionary = state.facilities.lunar_greenhouse
			if float(room.pump_condition)<0.65 or float(room.pressure)<0.9 or float(room.cooling)<0.6:
				_set_job(worker,"repair","lunar_greenhouse","Replacing seals and verifying pressure",{"facility":"lunar_greenhouse","source":"lunar_greenhouse"},12.0)
			else:
				_set_job(worker,"inspect","lunar_greenhouse","Checking greenhouse pressure and pump instruments",{},18.0)
		"mechanic":
			for id in ["oil_rig","refinery"]:
				if float(state.facilities[id].condition)<0.75:
					_set_job(worker,"repair",id,"Servicing "+id.replace("_"," "),{"facility":id,"source":id},12.0)
					return
			_set_job(worker,"inspect","oil_rig","Inspecting pressure gauges and rig machinery",{},20.0)
		"solar_technician":
			if float(state.facilities.solar_array.condition)<0.8:
				_set_job(worker,"clean_solar","solar_array","Removing lunar dust from solar panels",{},12.0)
			else:
				_set_job(worker,"inspect","solar_array","Measuring solar output and battery reserve",{},20.0)
		"water_operator":
			if worker.planet=="moon":
				if float(state.facilities.lunar_greenhouse.water_l)<110.0:
					if stock("lunar_greenhouse","water")>=20:
						_set_job(worker,"refill","lunar_greenhouse","Treating and transferring irrigation water",{},9.0)
					else:
						_set_job(worker,"mine_water","ice_mine","Extracting surveyed ice and purifying meltwater",{},15.0)
				else:
					_set_job(worker,"inspect","lunar_greenhouse","Checking protected irrigation reserves",{},20.0)
			else:
				_set_job(worker,"pump_water","water","Filtering reservoir water into irrigation tanks",{},18.0)
		"cook":
			if stock("kitchen","meal")<90: _set_job(worker,"cook","kitchen","Cooking meals for the neighborhood",{},10.0)
			else: _block(worker,"Meal storage is sufficient; avoiding food waste")
		"carpenter":
			if stock("workshop","bamboo")<4 and stock("cooperative","bamboo")>=8:
				_set_job(worker,"load_move","cooperative","Collecting bamboo for the workshop",{"from":"cooperative","to":"workshop","item":"bamboo","quantity":8},5.0)
			elif stock("workshop","packaging")>=12 and stock("cooperative","packaging")<80:
				_set_job(worker,"load_move","workshop","Delivering finished cargo crates",{"from":"workshop","to":"cooperative","item":"packaging","quantity":8},5.0)
			else:
				_set_job(worker,"crate","workshop","Cutting bamboo and assembling cargo crates",{},15.0)
		"fisher":
			if stock("carrier","fish")>=6:
				_set_job(worker,"load_trade","carrier","Delivering the fresh catch to the kitchen",{"from":"carrier","to":"kitchen","item":"fish","quantity":6},5.0)
			elif stock("carrier","bean")<1 and stock("cooperative","bean")>=4:
				_set_job(worker,"load_trade","cooperative","Collecting bait for the fishing landing",{"from":"cooperative","to":"carrier","item":"bean","quantity":4},5.0)
			else:
				_set_job(worker,"fish","carrier","Working the community fishing landing",{},25.0)
		"beekeeper":
			_set_job(worker,"honey","cooperative","Inspecting orchard hives and collecting honey",{},35.0)
		"agronomist":
			for id in _ids(state.plots):
				var plot: Dictionary = state.plots[id]
				if plot.planet==worker.planet and plot.owner==worker.employer and float(plot.disease)>=0.1:
					_set_job(worker,"treat_crop","lunar_greenhouse" if worker.planet=="moon" else "cooperative","Diagnosing and treating crop stress",{"plot":id,"source":store},14.0)
					worker.destination=_free_work_position(worker,[plot.position[0],float(plot.position[1])+2.5],true)
					_route_to(worker,true)
					return
			_set_job(worker,"inspect","lunar_greenhouse" if worker.planet=="moon" else "cooperative","Inspecting crop health and recording recommendations",{},15.0)
		"farm_manager":
			_set_job(worker,"manage","lunar_greenhouse" if worker.planet=="moon" else "cooperative","Comparing market cover and coordinating the next planting",{},20.0)
		_:
			_set_job(worker,"leisure","habitat" if worker.planet=="moon" else ("town_square" if int(state.time)%100<50 else "housing"),"Chatting with neighbors and relaxing",{},18.0)

func _plan_tanker(worker: Dictionary) -> void:
	for target in ["oil_rig","refinery"]:
		if stock(target,"water")<20 and stock("cooperative","water")>=20:
			_set_job(worker,"load_trade","cooperative","Loading process water tanker",{"from":"cooperative","to":target,"item":"water","quantity":20},6.0)
			return
	if stock("refinery","crude_oil")<50 and stock("oil_rig","crude_oil")>=10:
		_set_job(worker,"load_trade","oil_rig","Loading crude tanker for the refinery",{"from":"oil_rig","to":"refinery","item":"crude_oil","quantity":mini(24,stock("oil_rig","crude_oil"))},6.0)
		return
	var destinations := [["gas_station","gasoline"],["airfield","jet_fuel"],["carrier","diesel"],["oil_rig","diesel"]]
	var offset := 1 if worker.id=="jet" else 0
	for index in range(destinations.size()):
		var entry: Array = destinations[(index+offset)%destinations.size()]
		var target: String = entry[0]
		var item: String = entry[1]
		if stock(target,item)<40 and stock("refinery",item)>=4:
			_set_job(worker,"load_trade","refinery","Loading certified "+item.replace("_"," "),{"from":"refinery","to":target,"item":item,"quantity":mini(12,stock("refinery",item))},6.0)
			return
	_block(worker,"No funded fuel route with available stock; waiting for refinery output")

func _set_job(worker: Dictionary, op: String, target: String, label: String, payload: Dictionary, duration: float) -> void:
	worker["motion_epoch"]=int(worker.get("motion_epoch",0))+1
	worker.target=target
	worker.destination=state.locations[target].position.duplicate()
	# Refinery staff work at the control-side apron, clear of the service lanes.
	# The facility/service address remains unchanged for drivers and trading.
	if target=="refinery" and not bool(worker.get("physical_transport",false)):
		worker.destination=[91.0,7.0]
	if not bool(worker.get("physical_transport",false)):
		worker.destination=_free_work_position(worker,worker.destination,true)
	worker.work_remaining=duration/(0.7+float(worker.skill)*0.5)
	worker._job={"op":op,"target":target,"label":label,"payload":payload}
	_route_to(worker,false)
	worker.blocker=""

func _execute_job(worker: Dictionary, job: Dictionary) -> Dictionary:
	var data: Dictionary = job.payload
	match str(job.op):
		"rest":
			worker.needs.fatigue=maxf(0.0,float(worker.needs.fatigue)-0.4)
			return _result(true,"Rested at home")
		"leisure":
			worker.needs.fatigue=maxf(0.0,float(worker.needs.fatigue)-0.08)
			return _result(true,"Enjoying the neighborhood")
		"eat":
			var store: String = job.target
			if stock(store,"meal")<1 or balance(worker.id)<8: return _result(false,"No affordable prepared meal; kitchen needs supplies")
			_consume(store,"meal",1,"Citizen meal")
			_transfer(worker.id,state.locations[store].owner,8,"Meal purchase")
			worker.needs.hunger=maxf(0.0,float(worker.needs.hunger)-0.6)
			state.metrics.food_consumed+=1
			return _result(true,"Bought and ate a meal")
		"plant","harvest","water","fertilize","clear_crop":
			var plot: Dictionary = state.plots[data.plot]
			if plot.owner!=worker.employer or not plot.automatic: return _result(false,"Plot permission changed; work canceled")
			if job.op=="clear_crop":
				if float(plot.health)>0.0: return _result(false,"This crop is still alive; clearing canceled")
				plot.crop=""
				plot.growth=0.0
				plot.health=1.0
				return _result(true,"Cleared failed crop for a fresh planting")
			if job.op=="harvest": return _harvest(plot,data.source)
			if job.op=="water": return _water_plot(plot,data.source)
			if job.op=="fertilize": return _fertilize_plot(plot,data.source)
			var preferred: Array = ["lettuce","radish","tomato","bean"] if worker.planet=="moon" else ["banana","bean","sweet_potato","rice","tomato","lettuce"]
			var planned := str(plot.get("preferred_crop",""))
			if planned in preferred and stock(data.source,crops[planned].planting_item)>0:
				return _plant(plot,planned,data.source)
			for offset in range(preferred.size()):
				var id: String = preferred[(int(plot.cycles)+offset)%preferred.size()]
				if stock(data.source,crops[id].planting_item)>0: return _plant(plot,id,data.source)
			return _result(false,"Planting stock exhausted; merchant needs a nursery delivery")
		"extract":
			var rig: Dictionary = state.facilities.oil_rig
			if float(rig.condition)<0.3 or int(rig.reserve)<8: return _result(false,"Rig requires service or surveyed reserve is exhausted")
			if stock("oil_rig","diesel")<1 or stock("oil_rig","water")<1 or not _has_room("oil_rig",8): return _result(false,"Rig needs diesel, process water or free tank capacity")
			_consume("oil_rig","diesel",1,"Rig machinery fuel")
			_consume("oil_rig","water",1,"Oil separation process")
			rig.reserve-=8
			rig.condition=maxf(0.0,float(rig.condition)-0.006)
			_produce("oil_rig","crude_oil",8,"Extracted surveyed petroleum reserve")
			state.metrics.crude_extracted+=8
			return _result(true,"Extracted eight litres of crude; separated and stored safely")
		"refine":
			var result: Dictionary = _process_recipe("refine","refinery","refinery")
			if result.ok: state.facilities.refinery.condition=maxf(0.0,float(state.facilities.refinery.condition)-0.004)
			return result
		"load_trade","load_move": return _load_worker(worker,data,job.op=="load_trade")
		"unload":
			var cargo: Dictionary = worker.carrying
			if cargo.is_empty(): return _result(false,"No cargo to unload")
			_reserve_location(cargo.to,-int(cargo.quantity)-int(cargo.get("packaging",0)))
			_add_goods(cargo.to,cargo.item,int(cargo.quantity))
			_add_goods(cargo.to,"packaging",int(cargo.get("packaging",0)))
			state.metrics.deliveries+=1
			if cargo.item in ["gasoline","diesel","jet_fuel"]: state.metrics.fuel_delivered+=int(cargo.quantity)
			var message := "Delivered %d %s to %s"%[cargo.quantity,str(cargo.item).replace("_"," "),state.locations[cargo.to].label]
			worker.carrying={}
			return _result(true,message)
		"repair": return _repair(data.facility,data.source)
		"clean_solar":
			state.facilities.solar_array.condition=1.0
			return _result(true,"Cleaned solar panels; generation efficiency restored")
		"refill":
			if stock("lunar_greenhouse","water")<20: return _result(false,"No water stock available for treatment")
			_consume("lunar_greenhouse","water",20,"Treat and transfer greenhouse water")
			state.facilities.lunar_greenhouse.water_l=minf(500.0,float(state.facilities.lunar_greenhouse.water_l)+18.0)
			return _result(true,"Treated 20 litres; recovered 18 litres for irrigation")
		"mine_water":
			var mine: Dictionary = state.facilities.ice_mine
			var room: Dictionary = state.facilities.lunar_greenhouse
			if int(mine.reserve)<20 or float(room.battery_kwh)<2.0 or not _has_room("lunar_greenhouse",20): return _result(false,"Ice extraction needs surveyed reserve, energy and destination storage")
			mine.reserve-=20
			room.battery_kwh-=2.0
			_record_resource("produced","water",20)
			worker.carrying={"from":"ice_mine","to":"lunar_greenhouse","item":"water","quantity":20,"packaging":0}
			return _result(true,"Extracted twenty litres; returning with the water tank")
		"pump_water":
			var works: Dictionary = state.facilities.water
			if float(works.reservoir_l)<20.0 or not _has_room("cooperative",20): return _result(false,"Water reservoir empty or farm storage full")
			works.reservoir_l-=20.0
			_record_resource("produced","water",20)
			worker.carrying={"from":"water","to":"cooperative","item":"water","quantity":20,"packaging":0}
			return _result(true,"Filtered twenty litres; transporting irrigation water")
		"cook": return _process_recipe("cook_fish" if stock("kitchen","fish")>=2 else "cook","kitchen","kitchen")
		"crate": return _process_recipe("make_crates","workshop","workshop")
		"fish":
			if stock("carrier","bean")<1 or not _has_room("carrier",2): return _result(false,"Fishing needs bait and landing storage")
			_consume("carrier","bean",1,"Fish bait")
			_produce("carrier","fish",2,"Community fishing catch")
			return _result(true,"Landed two kilograms of fish")
		"honey":
			var blooms := 0
			for id in _ids(state.plots):
				var plot: Dictionary = state.plots[id]
				if plot.planet=="earth" and plot.crop!="" and float(plot.growth)>0.45: blooms+=1
			if blooms<2 or stock("cooperative","packaging")<1 or not _has_room("cooperative",2): return _result(false,"Hives need flowering crops and a clean container")
			_consume("cooperative","packaging",1,"Honey container")
			_produce("cooperative","honey",2,"Orchard apiary collection")
			return _result(true,"Collected two kilograms of orchard honey")
		"manage":
			var market := str(worker.planet)+"_market"
			var choices: Array = ["radish","lettuce","tomato","bean"] if worker.planet=="moon" else ["banana","bean","sweet_potato","rice","tomato","lettuce"]
			var chosen: String = choices[0]
			for crop_id in choices:
				if stock(market,crop_id)<stock(market,chosen): chosen=crop_id
			var count := 0
			for plot_id in _ids(state.plots):
				var plot: Dictionary = state.plots[plot_id]
				if plot.planet==worker.planet and plot.owner==worker.employer and plot.automatic:
					plot["preferred_crop"]=chosen
					plot["plan_source"]="Manager inspected "+market+" stock at "+str(int(state.time))
					count+=1
			worker.observations.append({"time":state.time,"source":"Authorized market inventory and plot records","confidence":1.0,"fact":"Lowest crop stock: "+chosen})
			if worker.observations.size()>8: worker.observations.pop_front()
			return _result(true,"Scheduled "+chosen+" for "+str(count)+" beds based on actual market demand")
		"treat_crop":
			var plot: Dictionary = state.plots[data.plot]
			if plot.owner!=worker.employer: return _result(false,"Plot authorization changed")
			if stock(data.source,"nutrients")<1: return _result(false,"Treatment needs a measured nutrient dose")
			_consume(data.source,"nutrients",1,"Agronomist crop recovery")
			plot.disease=maxf(0.0,float(plot.disease)-0.2)
			plot.nutrients=minf(100.0,float(plot.nutrients)+12.0)
			return _result(true,"Inspected and treated "+str(plot.id)+"; recorded reduced crop stress")
		"inspect":
			var observation := {"time":state.time,"source":"On-site inspection at "+str(job.target),"confidence":0.9,"fact":"Inspection complete"}
			if state.facilities.has(job.target): observation.fact=state.facilities[job.target].status
			elif job.target=="cooperative":
				var ready := 0
				for id in _ids(state.plots):
					if state.plots[id].planet==worker.planet and float(state.plots[id].growth)>=1.0: ready+=1
				observation.fact="%d crops ready; farm water stock %d litres"%[ready,stock("cooperative","water")]
			worker.observations.append(observation)
			if worker.observations.size()>8: worker.observations.pop_front()
			return _result(true,"Observed: "+str(observation.fact))
	return _result(false,"Task is no longer available")

func _load_worker(worker: Dictionary, data: Dictionary, traded: bool) -> Dictionary:
	var source: String = data.from
	var destination: String = data.to
	var item: String = data.item
	var quantity := int(data.quantity)
	var packages := 0 if item in ["crude_oil","diesel","gasoline","jet_fuel","water","packaging"] else 1
	if stock(source,item)<quantity or stock(source,"packaging")<packages: return _result(false,"Loading stock or packaging is no longer available")
	if not _has_room(destination,quantity+packages): return _result(false,"Destination storage is full or reserved")
	var buyer: String = state.locations[destination].owner
	var seller: String = state.locations[source].owner
	var price := quote(destination,item,quantity,false) if traded else 0
	var freight := maxi(1,int(ceil(float(quantity)*0.2))) if traded else 0
	if balance(buyer)<price+freight: return _result(false,"Buyer cannot fund cargo and transport")
	if traded:
		_transfer(buyer,seller,price,"Purchase loaded cargo "+item)
		_transfer(buyer,"transport",freight,"Local freight fee")
		state.metrics.trades+=1
	_remove_goods(source,item,quantity)
	_remove_goods(source,"packaging",packages)
	_reserve_location(destination,quantity+packages)
	worker.carrying={"from":source,"to":destination,"item":item,"quantity":quantity,"packaging":packages,"owner":buyer}
	return _result(true,"Loaded %d %s; destination capacity reserved"%[quantity,item.replace("_"," ")])

func _consume_fuel() -> void:
	for entry in [["gas_station","gasoline"],["airfield","jet_fuel"],["carrier","diesel"]]:
		var location: String = entry[0]
		var item: String = entry[1]
		var price := int(_base_price(item))
		if stock(location,item)>0 and int(state.accounts.treasury)>=price:
			_transfer("treasury",location,price,"Funded municipal fleet fuel purchase")
			_consume(location,item,1,"Vehicle / aircraft / marine engine operation")
			state.metrics.fuel_used+=1

func _spoil_food() -> void:
	for location in state.inventories:
		if _external_location(str(location)): continue
		for item in ["banana","tomato","lettuce","spinach","strawberry","fish"]:
			if stock(location,item)>=12:
				_consume(location,item,1,"Perishable storage loss")
				_produce(location,"compost",1,"Recover spoiled organic material")
				state.metrics.spoilage+=1

func _block(worker: Dictionary, reason: String) -> void:
	worker.blocker=reason
	worker.activity="Waiting: "+reason
	worker.task=worker.activity
	worker.cooldown=10.0

func _remember(worker: Dictionary, fact: String) -> void:
	worker.memories.append({"time":state.time,"fact":fact})
	if worker.memories.size()>8: worker.memories.pop_front()

func stock(location: String, item: String) -> int:
	return int(state.inventories.get(location,{}).get(item,0))

func _quantity(value: Variant) -> int:
	if typeof(value) not in [TYPE_INT,TYPE_FLOAT] or not is_finite(float(value)) or float(value)!=floor(float(value)) or float(value)<1 or float(value)>1000: return 0
	return int(value)

func _known_item(item: String) -> bool:
	if BASE_PRICES.has(item) or crops.has(item): return true
	for id in crops:
		if crops[id].planting_item==item: return true
	return false

func _base_price(item: String) -> float:
	if BASE_PRICES.has(item): return float(BASE_PRICES[item])
	if crops.has(item): return float(crops[item].base_price)
	return 4.0

func _same_planet(a: String, b: String) -> bool:
	return state.locations.has(a) and state.locations.has(b) and state.locations[a].planet==state.locations[b].planet

func _has_room(location: String, additional: int) -> bool:
	var occupied := 0
	for item in state.inventories[location]: occupied+=int(state.inventories[location][item])
	if _external_location(location):
		var loc: Dictionary=state.locations[location]
		return occupied+int(shared_players[loc.owner].reserved[loc.planet])+additional<=int(loc.capacity)
	for shipment in state.shipments:
		if shipment.to==location: occupied+=int(shipment.quantity)+int(shipment.packaging)
	for id in _ids(state.citizens):
		var cargo: Dictionary = state.citizens[id].carrying
		if not cargo.is_empty() and cargo.to==location: occupied+=int(cargo.quantity)+int(cargo.get("packaging",0))
	for batch in state.get("batches",[]):
		if batch.location==location:
			for item in RECIPES[batch.recipe].outputs: occupied+=int(RECIPES[batch.recipe].outputs[item])
	return occupied+additional<=int(state.locations[location].capacity)

func _add_goods(location: String, item: String, quantity: int) -> void:
	if quantity>0: state.inventories[location][item]=stock(location,item)+quantity

func _remove_goods(location: String, item: String, quantity: int) -> void:
	if quantity>0: state.inventories[location][item]=stock(location,item)-quantity

func _move_goods(source: String, destination: String, item: String, quantity: int) -> void:
	_remove_goods(source,item,quantity)
	_add_goods(destination,item,quantity)
	_record("goods",{"from":source,"to":destination,"item":item,"quantity":quantity})

func _produce(location: String, item: String, quantity: int, reason: String) -> void:
	_add_goods(location,item,quantity)
	_record_resource("produced",item,quantity)
	_record("production",{"location":location,"item":item,"quantity":quantity,"reason":reason})

func _consume(location: String, item: String, quantity: int, reason: String) -> void:
	_remove_goods(location,item,quantity)
	_record_resource("consumed",item,quantity)
	_record("consumption",{"location":location,"item":item,"quantity":quantity,"reason":reason})

func _record_resource(kind: String, item: String, quantity: int) -> void:
	state.resource_ledger[kind][item]=int(state.resource_ledger[kind].get(item,0))+quantity

func _transfer(source: String, destination: String, amount: int, reason: String) -> void:
	if amount<=0 or source==destination: return
	_set_balance(source,balance(source)-amount)
	_set_balance(destination,balance(destination)+amount)
	_record("money",{"from":source,"to":destination,"amount":amount,"reason":reason})

func _record(kind: String, payload: Dictionary) -> void:
	var entry: Dictionary = payload.duplicate()
	entry.kind=kind
	entry.time=state.time
	state.ledger.append(entry)
	if state.ledger.size()>160: state.ledger.pop_front()

func _event(message: String) -> void:
	state.events.append({"time":state.time,"message":message})
	if state.events.size()>24: state.events.pop_front()

func _next_id(prefix: String) -> String:
	var id := prefix+"_"+str(state.next_id)
	state.next_id+=1
	return id

func _result(ok: bool, message: String) -> Dictionary:
	return {"ok":ok,"message":message}

func total_money() -> int:
	var total := 0
	for account in state.accounts: total+=int(state.accounts[account])
	return total

func total_goods(item: String) -> int:
	var total := 0
	for location in state.inventories: total+=stock(location,item)
	for shipment in state.shipments:
		if shipment.item==item: total+=int(shipment.quantity)
		if item=="packaging": total+=int(shipment.packaging)
	for id in _ids(state.citizens):
		var cargo: Dictionary = state.citizens[id].carrying
		if cargo.is_empty(): continue
		if cargo.item==item: total+=int(cargo.quantity)
		if item=="packaging": total+=int(cargo.get("packaging",0))
	return total

func summary() -> Dictionary:
	var active := 0
	var blocked := 0
	for id in _ids(state.citizens):
		if not state.citizens[id]._job.is_empty(): active+=1
		if state.citizens[id].blocker!="": blocked+=1
	return {"time":state.time,"planet":state.planet,"credits":state.accounts.player,
		"money":total_money(),"initial_money":state.initial_money,"citizens":state.citizens.size(),
		"working":active,"blocked":blocked,"crops":crops.size(),"plots":state.plots.size(),
		"shipments":state.shipments.size(),"metrics":state.metrics.duplicate(),
		"greenhouse":state.facilities.lunar_greenhouse.duplicate()}

func save_game(path: String) -> bool:
	if not validate_state(state): return false
	var actual := ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(actual.get_base_dir())!=OK: return false
	var temporary := actual+".tmp"
	var file := FileAccess.open(temporary,FileAccess.WRITE)
	if file==null: return false
	file.store_string(JSON.stringify(state,"",false,true))
	file.flush()
	var error := file.get_error()
	file.close()
	if error!=OK: return false
	# Preserve the preceding valid checkpoint before the atomic rename. A broken
	# temporary file cannot replace the committed save.
	if FileAccess.file_exists(actual):
		var previous := JSON.new()
		if previous.parse(FileAccess.get_file_as_string(actual))==OK and validate_state(previous.data):
			if DirAccess.copy_absolute(actual,actual+".bak")!=OK: return false
	return DirAccess.rename_absolute(temporary,actual)==OK

func load_game(path: String) -> bool:
	if not FileAccess.file_exists(path): return false
	var file := FileAccess.open(path,FileAccess.READ)
	if file==null or file.get_length()>4*1024*1024: return false
	var json := JSON.new()
	var parsed := json.parse(file.get_as_text())
	file.close()
	if parsed!=OK or not validate_state(json.data): return false
	state=json.data
	_pedestrian_layout_ready=false
	_accumulator=0.0
	return true

func validate_state(candidate: Variant) -> bool:
	if not candidate is Dictionary: return false
	var data: Dictionary = candidate
	for key in ["accounts","inventories","locations","plots","facilities","citizens","quests","metrics","resource_ledger","recent_requests","climate","vehicle_fuel"]:
		if not data.get(key) is Dictionary: return false
	for key in ["shipments","ledger","events","batches"]:
		if not data.get(key) is Array: return false
	if not _valid_integer(data.get("schema_version"),VERSION,VERSION) or data.get("planet") not in ["earth","moon"] or not _valid_number(data.get("time"),0,1000000000): return false
	if bool(data.get("online",false))!=multiplayer_mode: return false
	var location_count := EARTH_LOCATIONS.size()+MOON_LOCATIONS.size()+(shared_players.size()*2 if multiplayer_mode else 0)
	if data.locations.size()!=location_count or data.citizens.size()>64 or data.plots.size()>64 or data.shipments.size()>24 or data.batches.size()>8 or data.ledger.size()>160 or data.events.size()>24 or data.recent_requests.size()>64: return false
	for key in ["initial_money","next_id","seed"]:
		if not _valid_integer(data.get(key),0,1000000000000): return false
	for key in ["solar_illumination","lunar_phase"]:
		if not _valid_number(data.get(key),0,1): return false
	var money := 0
	for id in data.accounts:
		if not id is String or not _valid_integer(data.accounts[id],0,1000000000): return false
		money+=int(data.accounts[id])
	if not multiplayer_mode and money!=int(data.initial_money): return false
	for id in ["player","cooperative","lunar_cooperative","earth_market","moon_market","oil_company","refinery_company","transport","treasury","gas_station","airfield","carrier"]:
		if not data.accounts.has(id): return false
	for id in EARTH_LOCATIONS:
		if not data.locations.has(id): return false
	for id in MOON_LOCATIONS:
		if not data.locations.has(id): return false
	if data.inventories.size()!=data.locations.size() or data.facilities.size()!=8: return false
	for entry in data.events:
		if not entry is Dictionary or not _valid_number(entry.get("time"),0,1000000000) or not entry.get("message") is String: return false
	for entry in data.ledger:
		if not entry is Dictionary or not _valid_number(entry.get("time"),0,1000000000) or not entry.get("kind") is String: return false
	var reserved := {}
	for id in data.locations:
		var location: Variant = data.locations[id]
		if not location is Dictionary or not _valid_position(location.get("position")) or location.get("planet") not in ["earth","moon"] or not _account_exists(str(location.get("owner","")),data) or not _valid_integer(location.get("capacity"),1,100000) or not location.get("label") is String: return false
		if not data.inventories.get(id) is Dictionary: return false
		var occupied := 0
		for item in data.inventories[id]:
			if not _known_item(str(item)) or not _valid_integer(data.inventories[id][item],0,100000): return false
			occupied+=int(data.inventories[id][item])
		reserved[id]=occupied
	for id in data.plots:
		var plot: Variant = data.plots[id]
		if not plot is Dictionary or not _valid_position(plot.get("position")) or plot.get("planet") not in ["earth","moon"] or not _account_exists(str(plot.get("owner","")),data): return false
		if plot.get("crop","missing")!="" and not crops.has(plot.get("crop","")): return false
		for key in ["growth","health","drainage","disease"]:
			if not _valid_number(plot.get(key),0,1): return false
		for key in ["moisture","nutrients"]:
			if not _valid_number(plot.get(key),0,100): return false
		if not _valid_integer(plot.get("cycles"),0,100000) or typeof(plot.get("automatic"))!=TYPE_BOOL or not plot.get("last_crop") is String or plot.get("id")!=id or not plot.get("status") is String: return false
	for id in ["oil_rig","refinery","workshop","kitchen","water","solar_array","ice_mine","lunar_greenhouse"]:
		if not data.facilities.get(id) is Dictionary: return false
		var f: Dictionary = data.facilities[id]
		if not _valid_number(f.get("condition"),0,1) or not _valid_position(f.get("position")) or not f.get("label") is String or not f.get("status") is String or f.get("planet") not in ["earth","moon"]: return false
	for id in ["oil_rig","ice_mine"]:
		if not _valid_integer(data.facilities[id].get("reserve"),0,100000): return false
	for id in ["refinery","workshop","kitchen"]:
		if not _valid_number(data.facilities[id].get("energy_kwh"),0,10000): return false
	if not _valid_number(data.facilities.water.get("reservoir_l"),0,100000) or not _valid_integer(data.facilities.solar_array.get("panels"),0,12) or not _valid_number(data.facilities.solar_array.get("power_kw"),0,1000): return false
	var room: Dictionary = data.facilities.lunar_greenhouse
	for key in ["pressure","cooling","pump_condition"]:
		if not _valid_number(room.get(key),0,1): return false
	for key in ["water_l","battery_kwh","battery_capacity_kwh","power_kw","demand_kw","temperature"]:
		if not _valid_number(room.get(key),0,1200): return false
	if float(room.battery_kwh)>float(room.battery_capacity_kwh) or typeof(room.get("powered"))!=TYPE_BOOL: return false
	for id in data.citizens:
		var worker: Variant = data.citizens[id]
		if not worker is Dictionary or worker.get("id")!=id or worker.get("job") not in JOBS or worker.get("planet") not in ["earth","moon"] or not data.accounts.has(id) or not _account_exists(str(worker.get("employer","")),data) or not data.locations.has(worker.get("target","")): return false
		for key in ["position","destination"]:
			if not _valid_position(worker.get(key)): return false
		if not worker.get("route",[]) is Array or worker.get("route",[]).size()>80: return false
		for point in worker.get("route",[]):
			if not _valid_position(point): return false
		if not worker.get("needs") is Dictionary or not worker.get("_job") is Dictionary or not worker.get("carrying") is Dictionary: return false
		for key in ["hunger","fatigue"]:
			if not _valid_number(worker.needs.get(key),0,1): return false
		for key in ["work_remaining","cooldown","skill","wage","completed"]:
			if not _valid_number(worker.get(key),0,1000000): return false
		for key in ["name","activity","task","blocker"]:
			if not worker.get(key) is String: return false
		if not worker.get("memories") is Array or not worker.get("observations") is Array or worker.memories.size()>8 or worker.observations.size()>8 or not _valid_position(worker.get("shift")) or typeof(worker.get("enabled"))!=TYPE_BOOL: return false
		if worker.has("physical_transport") and typeof(worker.physical_transport)!=TYPE_BOOL: return false
		if worker.has("motion_epoch") and not _valid_integer(worker.motion_epoch,0,1000000000): return false
		if bool(worker.get("physical_transport",false)) and not data.get("traffic",{}).has(id): return false
		if worker.has("pending_job") and worker.pending_job not in JOBS: return false
		if worker.has("pending_employer") and not _account_exists(str(worker.pending_employer),data): return false
		if not worker._job.is_empty() and not _valid_job(worker._job,data): return false
		if not worker.carrying.is_empty():
			if not _valid_cargo(worker.carrying,data): return false
			reserved[worker.carrying.to]+=int(worker.carrying.quantity)+int(worker.carrying.get("packaging",0))
	var shipment_ids := {}
	for cargo in data.shipments:
		if not cargo is Dictionary or not _valid_cargo(cargo,data) or not _valid_number(cargo.get("remaining"),0,100000) or not _valid_number(cargo.get("duration"),1,100000): return false
		if not cargo.get("id") is String or shipment_ids.has(cargo.id): return false
		shipment_ids[cargo.id]=true
		reserved[cargo.to]+=int(cargo.quantity)+int(cargo.packaging)
	for batch in data.batches:
		if not batch is Dictionary or not RECIPES.has(batch.get("recipe","")) or not data.locations.has(batch.get("location","")) or not data.facilities.has(batch.get("facility","")) or not _valid_number(batch.get("remaining"),0,100000) or not _valid_number(batch.get("duration"),1,100000): return false
		if not batch.get("id") is String or shipment_ids.has(batch.id): return false
		shipment_ids[batch.id]=true
		for item in RECIPES[batch.recipe].outputs: reserved[batch.location]+=int(RECIPES[batch.recipe].outputs[item])
	for id in reserved:
		if int(reserved[id])>int(data.locations[id].capacity): return false
	for id in data.quests:
		var quest: Variant = data.quests[id]
		if not quest is Dictionary or not data.locations.has(quest.get("destination","")) or not _known_item(str(quest.get("item",""))) or not _valid_integer(quest.get("quantity"),1,1000) or not _valid_integer(quest.get("reward"),1,100000) or not _valid_number(quest.get("deadline"),0,1000000000) or quest.get("status") not in ["available","active","complete"] or quest.get("planet") not in ["earth","moon"]: return false
		for key in ["title","description","giver"]:
			if not quest.get(key) is String: return false
		if not data.accounts.has("escrow_"+id) or int(data.accounts["escrow_"+id])!=(int(quest.reward) if quest.status=="active" else 0): return false
	for key in ["produced","consumed"]:
		if not data.resource_ledger.get(key) is Dictionary: return false
		for item in data.resource_ledger[key]:
			if not _known_item(str(item)) or not _valid_integer(data.resource_ledger[key][item],0,1000000000): return false
	for key in ["trades","harvested","deliveries","work_completed","crude_extracted","crude_refined","fuel_delivered","fuel_used","food_consumed","crop_losses","spoilage"]:
		if not _valid_integer(data.metrics.get(key),0,1000000000): return false
	if data.vehicle_fuel.size()>256: return false
	for id in data.vehicle_fuel:
		var tank: Variant = data.vehicle_fuel[id]
		if not id is String or id.is_empty() or id.length()>120 or not tank is Dictionary or not _valid_integer(tank.get("kind"),0,3): return false
		var capacity: float = [12.0,65.0,45.0,900.0][int(tank.kind)]
		if not _valid_number(tank.get("fuel_l"),0,capacity) or not _valid_number(tank.get("capacity_l"),capacity,capacity) or tank.get("item")!=("jet_fuel" if int(tank.kind)==3 else "gasoline") or not _valid_number(tank.get("used_l",0),0,1000000000): return false
	if data.has("traffic"):
		if not data.traffic is Dictionary or data.traffic.size()>64: return false
		for id in data.traffic:
			var motion: Variant=data.traffic[id]
			if not data.citizens.has(id) or not motion is Dictionary or not motion.get("vehicle_id") is String or motion.vehicle_id.is_empty() or motion.vehicle_id.length()>160 or not _valid_position(motion.get("position")): return false
			var mode: Variant=motion.get("mode","driving")
			if mode not in ["driving","walking","boarding"]: return false
			if mode=="walking":
				if bool(data.citizens[id].get("physical_transport",false)) or not motion.has("pose") or not data.vehicle_fuel.has(motion.vehicle_id) or motion.get("arrived",true)!=false or not _valid_number(motion.get("speed"),0,0.35): return false
			elif not bool(data.citizens[id].get("physical_transport",false)): return false
			if not _valid_number(motion.get("speed"),0,150) or typeof(motion.get("arrived"))!=TYPE_BOOL or not _valid_integer(motion.get("epoch"),-1,1000000000) or not _valid_number(motion.get("reported_at"),-100,float(data.time)) or not motion.get("blocker") is String: return false
			if motion.has("pose"):
				if not motion.pose is Dictionary: return false
				for field in ["position","rotation","velocity"]:
					var vector: Variant=motion.pose.get(field)
					if not vector is Array or vector.size()!=3: return false
					for component in vector:
						if not _valid_number(component,-100000,100000): return false
	for id in data.recent_requests:
		if not data.recent_requests[id] is Dictionary or typeof(data.recent_requests[id].get("ok"))!=TYPE_BOOL or not data.recent_requests[id].get("message") is String: return false
	return _valid_number(data.climate.get("temperature"),-100,100) and _valid_number(data.climate.get("rain"),0,1)

func _valid_job(job: Dictionary, data: Dictionary) -> bool:
	if not job.get("payload") is Dictionary or not data.locations.has(job.get("target","")) or not job.get("label") is String: return false
	var op := str(job.get("op",""))
	var payload: Dictionary = job.payload
	if op in ["plant","harvest","water","fertilize","treat_crop","clear_crop"]:
		return data.plots.has(payload.get("plot","")) and data.locations.has(payload.get("source",""))
	if op in ["load_trade","load_move"]:
		return _valid_cargo(payload,data)
	if op=="repair":
		return data.facilities.has(payload.get("facility","")) and data.locations.has(payload.get("source",""))
	return op in ["rest","leisure","eat","extract","refine","unload","clean_solar","refill","mine_water","pump_water","cook","crate","fish","honey","inspect","manage"]

func _valid_cargo(cargo: Dictionary, data: Dictionary) -> bool:
	return data.locations.has(cargo.get("from","")) and data.locations.has(cargo.get("to","")) and _known_item(str(cargo.get("item",""))) and _valid_integer(cargo.get("quantity"),1,1000) and _valid_integer(cargo.get("packaging",0),0,1000)

func _valid_position(value: Variant) -> bool:
	return value is Array and value.size()==2 and _valid_number(value[0],-100000,100000) and _valid_number(value[1],-100000,100000)

func _valid_integer(value: Variant, minimum: float, maximum: float) -> bool:
	return _valid_number(value,minimum,maximum) and float(value)==floor(float(value))

func _valid_number(value: Variant, minimum: float, maximum: float) -> bool:
	return typeof(value) in [TYPE_INT,TYPE_FLOAT] and is_finite(float(value)) and float(value)>=minimum and float(value)<=maximum

func _start_processing(id: String, location: String, facility_id: String) -> Dictionary:
	if not RECIPES.has(id): return _result(false,"Choose a listed processing recipe.")
	if state.batches.size()>=8: return _result(false,"All eight processing benches are occupied.")
	var recipe: Dictionary = RECIPES[id]
	var facility: Dictionary = state.facilities[facility_id]
	if float(facility.condition)<0.3 or float(facility.energy_kwh)<float(recipe.energy): return _result(false,"Facility requires repair or energy.")
	var input_count := 0
	var output_count := 0
	for item in recipe.inputs:
		if stock(location,item)<int(recipe.inputs[item]): return _result(false,"Need %d %s for %s."%[recipe.inputs[item],item.replace("_"," "),recipe.label])
		input_count+=int(recipe.inputs[item])
	for item in recipe.outputs: output_count+=int(recipe.outputs[item])
	if not _has_room(location,maxi(0,output_count-input_count)): return _result(false,"No capacity for the finished batch.")
	for item in recipe.inputs: _consume(location,item,int(recipe.inputs[item]),"Processing batch: "+id)
	facility.energy_kwh-=float(recipe.energy)
	_reserve_location(location,output_count)
	state.batches.append({"id":_next_id("batch"),"recipe":id,"location":location,"facility":facility_id,"remaining":12.0,"duration":12.0})
	return _result(true,"Started "+str(recipe.label)+". Inputs loaded; output ready in 12 seconds.")

func _update_batches(dt: float) -> void:
	for index in range(state.batches.size()-1,-1,-1):
		var batch: Dictionary = state.batches[index]
		if float(state.facilities[batch.facility].condition)<0.3: continue
		batch.remaining=maxf(0.0,float(batch.remaining)-dt)
		if float(batch.remaining)>0.0: continue
		var recipe: Dictionary = RECIPES[batch.recipe]
		for item in recipe.outputs:
			_reserve_location(batch.location,-int(recipe.outputs[item]))
			_produce(batch.location,item,int(recipe.outputs[item]),"Completed batch "+str(batch.recipe))
		if batch.recipe=="refine": state.metrics.crude_refined+=10
		_event("Batch ready: "+str(recipe.label)+". Finished goods are in "+str(state.locations[batch.location].label)+".")
		state.batches.remove_at(index)

func register_vehicle(id: String, kind: int) -> Dictionary:
	if state.is_empty() or id.is_empty() or id.length()>120 or kind<0 or kind>3:
		return {}
	if state.vehicle_fuel.has(id):
		return state.vehicle_fuel[id]
	if state.vehicle_fuel.size()>=256:
		return {}
	var capacity: float = [12.0,65.0,45.0,900.0][kind]
	var item := "jet_fuel" if kind==3 else "gasoline"
	# One finite starter tank per stable vehicle identity, recorded as explicit
	# initial vehicle provisioning. Re-registering an identity cannot top it up.
	var tank := {"kind":kind,"fuel_l":capacity*0.5,"capacity_l":capacity,"item":item}
	state.vehicle_fuel[id]=tank
	_record("vehicle_provision",{"vehicle":id,"item":item,"litres":capacity*0.5})
	return tank

func consume_vehicle_fuel(id: String, litres: float) -> float:
	if not state.get("vehicle_fuel",{}).has(id) or not is_finite(litres) or litres<=0.0:
		return 0.0
	var tank: Dictionary = state.vehicle_fuel[id]
	var used := minf(float(tank.fuel_l),litres)
	tank.fuel_l=maxf(0.0,float(tank.fuel_l)-used)
	# Tanks use fractional litres; separate meter retains that precision rather
	# than pretending to consume an integer stock unit per rendered frame.
	tank["used_l"]=float(tank.get("used_l",0.0))+used
	return used

func _refuel(payload: Dictionary, actor: String = "player", realm: String = "") -> Dictionary:
	if realm.is_empty(): realm=str(state.planet)
	var id := str(payload.get("vehicle",""))
	var facility := str(payload.get("facility",""))
	var quantity := _quantity(payload.get("quantity",1))
	if not state.vehicle_fuel.has(id) or facility not in ["gas_station","airfield","carrier","refinery"]:
		return _result(false,"Choose a registered vehicle and a fuel facility.")
	var tank: Dictionary = state.vehicle_fuel[id]
	if realm!="earth" or quantity<=0:
		return _result(false,"Refuel vehicles at an Earth fuel facility.")
	var item: String = tank.item
	if stock(facility,item)<quantity:
		return _result(false,"Facility has insufficient "+item.replace("_"," ")+".")
	if float(tank.fuel_l)+quantity>float(tank.capacity_l)+0.000001:
		return _result(false,"That delivery exceeds the vehicle tank capacity.")
	var cost := quote(facility,item,quantity,true)
	var owner: String = state.locations[facility].owner
	if balance(actor)<cost:
		return _result(false,"Not enough trade credits; no fuel transferred.")
	_consume(facility,item,quantity,"Dispensed into vehicle "+id)
	_transfer(actor,owner,cost,"Vehicle refueling")
	tank.fuel_l+=quantity
	return _result(true,"Pumped %d litres of %s into the vehicle for %d credits."%[quantity,item.replace("_"," "),cost])

func _ids(dictionary: Dictionary) -> Array:
	var ids := dictionary.keys()
	ids.sort()
	return ids

## Trusted authority inputs only. Clients consume the resulting model positions.
func set_pedestrian_obstacles(rows: Array) -> void:
	_pedestrian_obstacles = rows.slice(0, 128)


func is_pedestrian(worker: Dictionary) -> bool:
	return not bool(worker.get("physical_transport",false)) or str(state.get("traffic",{}).get(worker.id,{}).get("mode","driving")) == "boarding"


func _free_work_position(worker: Dictionary, nominal: Array, reserve: bool) -> Array:
	var center := Vector2(float(nominal[0]), float(nominal[1]))
	for index in range(49):
		var candidate := center
		if index > 0:
			var ring := 1 + (index - 1) / 12
			var angle := float((index - 1) % 12) * TAU / 12.0
			candidate += Vector2(cos(angle), sin(angle)) * float(ring) * PEDESTRIAN_SPACING * 1.15
		var available := true
		for id in state.citizens:
			var other: Dictionary = state.citizens[id]
			if id == worker.id or other.planet != worker.planet or not is_pedestrian(other):
				continue
			var point: Array = other.get("destination", other.position) if reserve and not other.get("_job", {}).is_empty() else other.position
			if candidate.distance_to(Vector2(float(point[0]), float(point[1]))) < PEDESTRIAN_SPACING:
				available = false
				break
		if available:
			return [candidate.x, candidate.y]
	return nominal.duplicate()


## Small swept steps prevent opposite walkers tunnelling through each other
## between the one-second economy ticks. Keep right when passing, then return
## to the route; a stopped worker never acquires a permanent queue reservation.
func pedestrian_step(worker: Dictionary, from: Vector2, target: Vector2, dt: float) -> Vector2:
	var position := from
	var remaining := minf(maxf(dt, 0.0), 2.0) * WALK_SPEED
	var direct := from.move_toward(target,remaining)
	# Every candidate in this call stays inside the remaining-travel disc. Cull
	# the authority's current people/player positions once, then reuse the same
	# numeric points for the fine steering sweeps. This keeps collision behavior
	# exact without repeatedly walking the citizen dictionaries at every angle.
	var nearby := _nearby_pedestrian_obstacles(worker, from, remaining)
	# Most routes are empty. One complete sweep proves that straight segment
	# safe; reserve fine steering steps for actual close encounters.
	if _pedestrian_segment_clear_against(from,direct,nearby): return direct
	while remaining > 0.0001 and position.distance_to(target) > 0.05:
		var stride := minf(remaining, minf(0.14, position.distance_to(target)))
		var forward := (target-position).normalized()
		var best := position
		var best_score := -INF
		var retreated := false
		for angle in [0.0, 0.52, -0.52, 1.05, -1.05, 1.57, -1.57]:
			var step := forward.rotated(angle) * stride
			var candidate := position + step
			if not _pedestrian_segment_clear_against(position, candidate, nearby):
				continue
			var score := step.dot(forward) + (0.001 if angle > 0.0 else 0.0)
			if score > best_score:
				best = candidate
				best_score = score
			if angle == 0.0: break # An unobstructed forward stride is always best.
		# A worker leaving a tightly occupied service bay may need one step away
		# from the destination before a safe passing lane opens. Evaluate rearward
		# arcs only when every forward/side option is blocked.
		if best == position:
			for angle in [2.09, -2.09, 2.62, -2.62, PI]:
				var step := forward.rotated(angle) * stride
				var candidate := position + step
				if not _pedestrian_segment_clear_against(position, candidate, nearby):
					continue
				# Angles are ordered by forward progress, keeping right on ties.
				best = candidate
				retreated = true
				break
		if best == position:
			break
		position = best
		remaining -= stride
		# Replan after one deliberate retreat instead of spending the rest of this
		# tick oscillating around the same packed group.
		if retreated:
			return position
	return position


func _pedestrian_segment_clear(worker: Dictionary, start: Vector2, finish: Vector2) -> bool:
	var nearby := _nearby_pedestrian_obstacles(worker, start, start.distance_to(finish))
	return _pedestrian_segment_clear_against(start, finish, nearby)


func _nearby_pedestrian_obstacles(worker: Dictionary, origin: Vector2,
		reach: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	var planet := str(worker.planet)
	var people_limit := reach + PEDESTRIAN_SPACING
	var people_limit_squared := people_limit * people_limit
	for id in state.citizens:
		var other: Dictionary = state.citizens[id]
		if id == worker.id or str(other.planet) != planet or not is_pedestrian(other):
			continue
		var point := Vector2(float(other.position[0]), float(other.position[1]))
		if origin.distance_squared_to(point) <= people_limit_squared:
			result.append(Vector3(point.x, point.y, PEDESTRIAN_SPACING))
	for obstacle: Dictionary in _pedestrian_obstacles:
		if str(obstacle.get("planet", "earth")) != planet:
			continue
		var point: Vector2 = obstacle.get("position", Vector2.INF)
		var radius := PEDESTRIAN_RADIUS + float(obstacle.get("radius", 0.42)) + 0.12
		var limit := reach + radius
		if point.is_finite() and origin.distance_squared_to(point) <= limit * limit:
			result.append(Vector3(point.x, point.y, radius))
	return result


static func _pedestrian_segment_clear_against(start: Vector2, finish: Vector2,
		obstacles: PackedVector3Array) -> bool:
	for obstacle in obstacles:
		if not _clear_person_segment(start, finish,
			Vector2(obstacle.x, obstacle.y), obstacle.z):
			return false
	return true


static func _clear_person_segment(start: Vector2, finish: Vector2, point: Vector2, radius: float) -> bool:
	var nearest := Geometry2D.get_closest_point_to_segment(point, start, finish)
	if nearest.distance_to(point) >= radius - 0.0001:
		return true
	# A loaded save or a player can begin inside personal space. Allow only
	# motion which increases separation, never deeper penetration.
	return start.distance_to(point) < radius and finish.distance_to(point) > start.distance_to(point) + 0.0001


func _route_to(worker: Dictionary, plot: bool) -> void:
	worker["route"]=RoutesScript.path(worker.position,worker.destination,str(worker.planet),plot)


func configure_shared_players(book: Dictionary) -> void:
	multiplayer_mode=true
	shared_players=book
	state["online"]=true
	for actor in shared_players:
		attach_shared_player(str(actor))

func attach_shared_player(actor: String) -> void:
	if not shared_players.has(actor): return
	for realm in ["earth","moon"]:
		var id := inventory_location(actor,realm)
		state.locations[id]={"id":id,"label":"Member "+realm+" inventory","planet":realm,"position":[0,4],"capacity":350,"owner":actor}
		state.inventories[id]=shared_players[actor].inventories[realm]

func inventory_location(actor: String, realm: String) -> String:
	return actor+"_"+realm

func balance(account: String) -> int:
	return int(shared_players[account].credits) if shared_players.has(account) else int(state.accounts.get(account,0))

func _set_balance(account: String, amount: int) -> void:
	if shared_players.has(account): shared_players[account].credits=amount
	else: state.accounts[account]=amount

func _account_exists(account: String, data: Dictionary) -> bool:
	return data.accounts.has(account) or shared_players.has(account)

func _external_location(location: String) -> bool:
	return state.locations.has(location) and shared_players.has(state.locations[location].owner)

func _reserve_location(location: String, quantity: int) -> void:
	if not _external_location(location): return
	var loc: Dictionary=state.locations[location]
	shared_players[loc.owner].reserved[loc.planet]=int(shared_players[loc.owner].reserved[loc.planet])+quantity


func enable_physical_transport(worker_id: String, vehicle_id: String) -> bool:
	if not state.get("citizens",{}).has(worker_id) or vehicle_id.is_empty() or vehicle_id.length()>160: return false
	if not state.has("traffic"): state.traffic={}
	var worker: Dictionary=state.citizens[worker_id]
	if state.traffic.has(worker_id) and state.traffic[worker_id].vehicle_id!=vehicle_id: return false
	worker["physical_transport"]=true
	if not worker.has("motion_epoch"): worker.motion_epoch=0
	if not state.traffic.has(worker_id):
		state.traffic[worker_id]={"vehicle_id":vehicle_id,"position":worker.position.duplicate(),"speed":0.0,"arrived":false,"epoch":-1,"reported_at":-100.0,"blocker":"Waiting for delivery vehicle"}
	state.traffic[worker_id]["mode"]="driving"
	state.traffic[worker_id].arrived=false
	state.traffic[worker_id].epoch=-1
	if worker._job.is_empty() and bool(worker.enabled) and float(worker.cooldown)<=0.0:
		_plan_job(worker)
	return true

func disable_physical_transport(worker_id: String, exit_position: Array) -> bool:
	if not state.get("citizens",{}).has(worker_id) or not _valid_position(exit_position): return false
	var worker: Dictionary=state.citizens[worker_id]
	if not worker.carrying.is_empty(): return false
	var record: Dictionary=state.get("traffic",{}).get(worker_id,{})
	if record.is_empty() or float(record.get("speed",100.0))>0.35 or float(state.time)-float(record.get("reported_at",-100.0))>3.0: return false
	worker.physical_transport=false
	worker.position=exit_position.duplicate()
	record.arrived=false
	record.epoch=-1
	record["mode"]="walking"
	if not worker._job.is_empty(): _route_to(worker,worker._job.op in ["plant","harvest","water","fertilize","treat_crop","clear_crop"])
	return true


func report_physical_transport(worker_id: String, position: Array, speed: float, arrived: bool, blocker: String, motion_epoch: int) -> bool:
	if not state.get("traffic",{}).has(worker_id) or not _valid_position(position) or not is_finite(speed) or speed<0.0 or speed>150.0: return false
	var worker: Dictionary=state.citizens[worker_id]
	if not bool(worker.get("physical_transport",false)) or motion_epoch!=int(worker.get("motion_epoch",0)): return false
	var target := Vector2(float(worker.destination[0]),float(worker.destination[1]))
	var actual := Vector2(float(position[0]),float(position[1]))
	var record: Dictionary=state.traffic[worker_id]
	record.position=position.duplicate()
	record.speed=speed
	record.arrived=arrived and speed<=0.35 and actual.distance_to(target)<=12.0
	record.epoch=motion_epoch
	record.reported_at=state.time
	record.blocker=blocker.left(180)
	worker.position=position.duplicate()
	return true


func refuel_transport(worker_id: String, facility: String, quantity: int) -> Dictionary:
	# Server traffic only: this entry point is deliberately absent from action().
	if not state.get("traffic",{}).has(worker_id) or not state.locations.has(facility):
		return _result(false,"Unknown physical crew vehicle or fuel depot.")
	var worker: Dictionary=state.citizens[worker_id]
	var motion: Dictionary=state.traffic[worker_id]
	if not bool(worker.get("physical_transport",false)) or float(state.time)-float(motion.reported_at)>3.0 or float(motion.speed)>0.35:
		return _result(false,"Stop the actual crew vehicle at a fuel depot first.")
	var actual := Vector2(float(motion.position[0]),float(motion.position[1]))
	var depot: Array=state.locations[facility].position
	if actual.distance_to(Vector2(float(depot[0]),float(depot[1])))>12.0:
		return _result(false,"The crew vehicle is outside the depot loading bay.")
	return _refuel({"vehicle":motion.vehicle_id,"facility":facility,"quantity":quantity},str(worker.employer),str(worker.planet))
