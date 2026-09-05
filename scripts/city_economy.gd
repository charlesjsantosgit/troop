class_name CityEconomy
extends RefCounted

## Durable, bounded economy for Crownreach. The 400,000-resident census is
## represented by twelve aggregate district rows; player property, storage and
## job records remain finite and are backed by FrontierSim's real wallet/bag.
const Plan = preload("res://scripts/city_plan.gd")

const VERSION := 1
const POPULATION := 400000
const AREA_SQ_MI := 204.96
const ACTION_RANGE := 18.0
const MAX_PROPERTIES := 512
const MAX_PROPERTIES_PER_ACTOR := 8
const MAX_ACTIVE_JOBS := 64
const MAX_LEDGER := 128
const MAX_ADVANCE_INTERVALS := 60
const AGGREGATE_INTERVAL := 60.0
const PROPERTY_ACCOUNT := "treasury"

const HOUSING := {
	"cottage": {"id":"cottage","label":"Village cottage","price":450,
		"storage_capacity":80,"luxury":1,"residential":true},
	"town_apartment": {"id":"town_apartment","label":"Town apartment","price":700,
		"storage_capacity":120,"luxury":2,"residential":true},
	"suburban_home": {"id":"suburban_home","label":"Suburban home","price":1200,
		"storage_capacity":220,"luxury":3,"residential":true},
	"city_apartment": {"id":"city_apartment","label":"City apartment","price":1600,
		"storage_capacity":180,"luxury":3,"residential":true},
	"penthouse": {"id":"penthouse","label":"Penthouse","price":4800,
		"storage_capacity":300,"luxury":6,"residential":true},
	"warehouse": {"id":"warehouse","label":"Warehouse","price":2600,
		"storage_capacity":1000,"luxury":1,"residential":false},
}

const CROP_ITEMS := [
	"banana","plantain","cassava","sweet_potato","rice","taro","maize","soybean",
	"bean","peanut","tomato","cucumber","pepper","lettuce","spinach","radish",
	"carrot","strawberry","cocoa","coffee","tea","cotton","flax","bamboo",
]
const BASE_ITEMS := [
	"water","nutrients","compost","packaging","spare_parts","solar_kit","crude_oil",
	"gasoline","diesel","jet_fuel","bitumen","meal","flour","dried_food",
	"cooking_oil","cloth","rope","fish","honey","lumber","battery_kit",
]
const PLANTING_ITEMS := [
	"banana_start","plantain_start","cassava_cutting","sweet_potato_slip","rice_seed",
	"taro_corm","maize_seed","soybean_seed","bean_seed","peanut_seed","tomato_seed",
	"cucumber_seed","pepper_seed","lettuce_seed","spinach_seed","radish_seed",
	"carrot_seed","strawberry_start","cocoa_start","coffee_start","tea_start",
	"cotton_seed","flax_seed","bamboo_start",
]

const SERVICE_IDS := [
	"courier_depot","courier_delivery_lantern","courier_delivery_clinic",
	"courier_delivery_rail","maintenance_depot","maintenance_site_lantern",
	"maintenance_site_north","maintenance_site_east","produce_exchange",
	"produce_market","home_office",
]
const SERVICE_CAPACITY := {
	"courier_depot":5000,"courier_delivery_lantern":3000,
	"courier_delivery_clinic":3000,"courier_delivery_rail":3000,
	"maintenance_depot":1000,"maintenance_site_lantern":1000,
	"maintenance_site_north":1000,"maintenance_site_east":1000,
	"produce_exchange":3000,"produce_market":5000,"home_office":400,
}

const JOBS := {
	"courier_lantern": {
		"id":"courier_lantern","kind":"courier","label":"Lantern Square courier",
		"description":"Carry a funded food parcel from Westgate to Lantern House.",
		"start_service":"courier_depot","destination_service":"courier_delivery_lantern",
		"duration":45.0,"reward":72,"requires":{},"cargo":{"meal":2}},
	"courier_clinic": {
		"id":"courier_clinic","kind":"courier","label":"Clinic parts courier",
		"description":"Deliver a real spare part from Westgate to Northlight Clinic.",
		"start_service":"courier_depot","destination_service":"courier_delivery_clinic",
		"duration":60.0,"reward":90,"requires":{},"cargo":{"spare_parts":1}},
	"courier_rail": {
		"id":"courier_rail","kind":"courier","label":"Railworks freight courier",
		"description":"Move a packed freight bundle to the Railworks loading door.",
		"start_service":"courier_depot","destination_service":"courier_delivery_rail",
		"duration":75.0,"reward":120,"requires":{},"cargo":{"packaging":3}},
	"maintenance_lantern": {
		"id":"maintenance_lantern","kind":"maintenance","label":"Lantern light repair",
		"description":"Bring one spare part and repair the Lantern lightworks.",
		"start_service":"maintenance_depot","destination_service":"maintenance_site_lantern",
		"duration":60.0,"reward":105,"requires":{"spare_parts":1},"cargo":{"spare_parts":1}},
	"maintenance_north": {
		"id":"maintenance_north","kind":"maintenance","label":"Northlight heating repair",
		"description":"Bring one spare part to service Northlight's heating plant.",
		"start_service":"maintenance_depot","destination_service":"maintenance_site_north",
		"duration":70.0,"reward":115,"requires":{"spare_parts":1},"cargo":{"spare_parts":1}},
	"maintenance_east": {
		"id":"maintenance_east","kind":"maintenance","label":"East Market water repair",
		"description":"Bring one spare part to the East Market waterworks.",
		"start_service":"maintenance_depot","destination_service":"maintenance_site_east",
		"duration":70.0,"reward":115,"requires":{"spare_parts":1},"cargo":{"spare_parts":1}},
	"produce_provisioning": {
		"id":"produce_provisioning","kind":"produce_provisioning","label":"Produce provisioning",
		"description":"Supply four kilograms of your own fresh produce to Garden Row.",
		"start_service":"produce_exchange","destination_service":"produce_market",
		"duration":55.0,"reward":85,"requires":{},"cargo":{}},
	"restock_depot_meals": {
		"id":"restock_depot_meals","kind":"depot_restock","label":"Restock courier meals",
		"description":"Move four prepared meals from your Earth backpack into the courier depot.",
		"start_service":"courier_depot","destination_service":"courier_depot",
		"duration":20.0,"reward":60,"requires":{"meal":4},"cargo":{"meal":4}},
	"restock_depot_parts": {
		"id":"restock_depot_parts","kind":"depot_restock","label":"Restock courier parts",
		"description":"Move two workshop spare parts from your Earth backpack into the courier depot.",
		"start_service":"courier_depot","destination_service":"courier_depot",
		"duration":24.0,"reward":64,"requires":{"spare_parts":2},"cargo":{"spare_parts":2}},
	"restock_depot_packaging": {
		"id":"restock_depot_packaging","kind":"depot_restock","label":"Restock freight packaging",
		"description":"Move six packing units from your Earth backpack into the courier depot.",
		"start_service":"courier_depot","destination_service":"courier_depot",
		"duration":20.0,"reward":40,"requires":{"packaging":6},"cargo":{"packaging":6}},
}

var state: Dictionary = {}
static var _service_records: Dictionary={}
static var _housing_rows: Array=[]
static var _job_rows: Array=[]


func new_game(world_seed: int = 2026, start_time: float = 400.0) -> void:
	var districts: Array = _new_districts()
	state = {
		"schema_version":VERSION,
		"seed":world_seed,
		"last_time":maxf(0.0,start_time),
		"population":POPULATION,
		"properties":{},
		"homes":{},
		"active_jobs":{},
		"service_inventories":{},
		"next_job_id":1,
		"districts":districts,
		"metrics":{"aggregate_intervals":0,"production_units":0,
			"consumption_units":0,"service_goods_consumed":0,
			"jobs_started":0,"jobs_completed":0,"property_sales":0,
			"storage_moves":0,"skipped_intervals":0},
		"ledger":[],
	}
	for id in SERVICE_IDS:
		state.service_inventories[id] = {}
	# These are finite opening municipal stocks. Work moves or consumes them;
	# aggregate census counters never create tradeable player goods.
	state.service_inventories.courier_depot = {
		"meal":600,"spare_parts":240,"packaging":900,
	}


func import_state(candidate: Variant) -> bool:
	if not _valid_state(candidate):
		return false
	state = (candidate as Dictionary).duplicate(true)
	return true


func view(actor: String, sim=null, property_context: String = "") -> Dictionary:
	if state.is_empty() or not _valid_actor(actor):
		return {}
	var storage_context:=""
	if property_context.length()<=80 and state.properties.has(property_context) \
			and state.properties[property_context].owner==actor:
		storage_context=property_context
	var owned: Array = []
	var owned_ids: Array = []
	var unavailable: Array = []
	for building_id in _sorted_keys(state.properties):
		var property: Dictionary = state.properties[building_id]
		if property.owner == actor:
			var row := _public_property(building_id,property,actor,building_id==storage_context)
			owned.append(row)
			owned_ids.append(building_id)
		else:
			unavailable.append(building_id)
	var home_id := str(state.homes.get(actor,""))
	var home_spawn: Array = []
	if not home_id.is_empty():
		var home_record := Plan.building(home_id)
		if not home_record.is_empty():
			home_spawn = _point_array(home_record.door)
	var active: Dictionary = state.active_jobs.get(actor,{}).duplicate(true)
	active.erase("owner")
	active.erase("source_service")
	active.erase("destination_service")
	active.erase("job")
	var service_view := {}
	for id in SERVICE_IDS:
		var service := _service(id)
		if service.is_empty():
			continue
		service_view[id] = {
			"id":id,"label":service.name,"kind":service.kind,
			"building":service.building_id,"door":_point_array(service.position),
			"district":int(service.district),
			"stock":state.service_inventories[id].duplicate(true),
		}
	var jobs: Array = _base_job_catalog()
	var public_metrics: Dictionary=state.metrics.duplicate(true)
	var food_stock:=0
	var workforce:=0
	var shortages:=0
	var service_total:=0.0
	for district: Dictionary in state.districts:
		food_stock+=int(district.food_stock)
		workforce+=int(district.workforce)
		shortages+=int(district.shortages)
		service_total+=float(district.service_condition)
	public_metrics["food_stock"]=food_stock
	public_metrics["workforce"]=workforce
	public_metrics["shortages"]=shortages
	public_metrics["service_reliability"]=service_total/float(state.districts.size())
	var result: Dictionary={
		"city":{"name":"Crownreach","area_sq_mi":AREA_SQ_MI,
			"population":POPULATION,"center":[Plan.CENTER.x,Plan.CENTER.y],
			"bounds":[Plan.MIN_X,Plan.MIN_Z,Plan.MAX_X,Plan.MAX_Z]},
		"credits":0,
		"backpack_counts":{},
		"backpack_capacity":350,
		"time":float(state.last_time),
		"now":float(state.last_time),
		"housing_catalog":housing_catalog(),
		"owned_properties":owned,
		"owned_buildings":owned_ids,
		"unavailable_buildings":unavailable,
		"home":home_id,
		"home_spawn":home_spawn,
		"job_catalog":jobs,
		"active_job":active,
		"services":service_view,
		"districts":state.districts.duplicate(true),
		"metrics":public_metrics,
	}
	if sim!=null:
		_apply_actor_resources(result,actor,sim)
	return result


func action(actor: String, kind: String, payload: Dictionary, sim,
		position: Vector3, time: float) -> Dictionary:
	if state.is_empty():
		return _result(false,"Crownreach has not been initialized.")
	if not _valid_actor(actor) or not _valid_position(position):
		return _result(false,"A valid resident and physical city position are required.")
	if sim == null or not sim.state is Dictionary:
		return _result(false,"The town economy is unavailable.")
	if not _valid_time(time,sim):
		return _result(false,"This city action used an invalid authority time.")
	if time+0.0001 < float(state.last_time):
		return _result(false,"This city action arrived older than the city record.")
	var player_location := str(sim.inventory_location(actor,"earth"))
	if not sim.state.inventories.has(player_location):
		return _result(false,"The resident's Earth backpack is unavailable.")
	# Failed actions leave the entire city state byte-for-byte unchanged, including
	# its aggregate clock. Resource/wallet mutations occur only in successful
	# branches after their final validation.
	var before: Dictionary=state.duplicate(true)
	if not advance(time):
		return _result(false,"The city clock could not advance.")
	var result: Dictionary
	match kind:
		"buy_home":
			result=_buy_home(actor,payload,sim,position,time)
		"store_item":
			result=_store_item(actor,payload,sim,position,time,true)
		"take_item":
			result=_store_item(actor,payload,sim,position,time,false)
		"set_home":
			result=_set_home(actor,payload,position,time)
		"start_job":
			result=_start_job(actor,payload,sim,position,time)
		"finish_job":
			result=_finish_job(actor,sim,position,time)
		_:
			result=_result(false,"That Crownreach action is not available.")
	if not result.ok:
		state=before
	return result


func advance(to_time: float) -> bool:
	if state.is_empty() or not is_finite(to_time) or to_time < float(state.last_time):
		return false
	var previous_interval := floori(float(state.last_time) / AGGREGATE_INTERVAL)
	var requested := maxi(0,floori(to_time / AGGREGATE_INTERVAL)-previous_interval)
	var intervals := mini(requested,MAX_ADVANCE_INTERVALS)
	if intervals > 0:
		_consume_service_goods(intervals)
		for district: Dictionary in state.districts:
			var kind:=str(district.kind)
			var production_rate:=6 if kind in ["produce","food"] else (2 if kind=="residential" else 1)
			var demand_rate:=maxi(1,ceili(float(district.population)/10000.0))
			var production:=production_rate*intervals
			var requested_food:=demand_rate*intervals
			var available:=int(district.food_stock)+production
			var consumption:=mini(available,requested_food)
			var missed:=requested_food-consumption
			district.food_stock=clampi(available-consumption,0,400)
			district.food_demand=demand_rate
			district.shortages=_bounded_counter(int(district.shortages)+missed)
			var condition_loss:=float(intervals)*0.0008+float(missed)*0.002
			district.service_condition=clampf(float(district.service_condition)-condition_loss,0.25,1.0)
			var employment_factor:=(0.90 if missed>0 else 1.0)*(0.75+0.25*float(district.service_condition))
			district.workforce=roundi(float(district.workforce_capacity)*employment_factor)
			district.production_units = _bounded_counter(int(district.production_units)+production)
			district.consumption_units = _bounded_counter(int(district.consumption_units)+consumption)
			district.job_minutes = _bounded_counter(int(district.job_minutes)+int(district.workforce)*intervals)
			state.metrics.production_units = _bounded_counter(int(state.metrics.production_units)+production)
			state.metrics.consumption_units = _bounded_counter(int(state.metrics.consumption_units)+consumption)
		state.metrics.aggregate_intervals = _bounded_counter(int(state.metrics.aggregate_intervals)+intervals)
	if requested > intervals:
		state.metrics.skipped_intervals = _bounded_counter(int(state.metrics.skipped_intervals)+requested-intervals)
	state.last_time = to_time
	return true


func total_goods(item: String) -> int:
	var total := 0
	for inventory: Dictionary in state.get("service_inventories",{}).values():
		total += int(inventory.get(item,0))
	for property: Dictionary in state.get("properties",{}).values():
		total += int(property.storage.get(item,0))
	for job: Dictionary in state.get("active_jobs",{}).values():
		total += int(job.cargo.get(item,0))
	return total


static func housing_catalog() -> Array:
	if not _housing_rows.is_empty(): return _housing_rows.duplicate(true)
	var examples := {}
	for row in Plan.housing_catalog():
		examples[str(row.tier)] = str(row.building_id)
	var result: Array = []
	for tier in ["cottage","town_apartment","suburban_home","city_apartment","penthouse","warehouse"]:
		var row: Dictionary = HOUSING[tier].duplicate(true)
		var building_id := str(examples.get(tier,""))
		var building := Plan.building(building_id)
		row["example_building"] = building_id
		row["door"] = _point_array(building.get("door",Vector3.ZERO))
		result.append(row)
	_housing_rows=result
	return _housing_rows.duplicate(true)


static func _base_job_catalog() -> Array:
	if not _job_rows.is_empty(): return _job_rows.duplicate(true)
	var result: Array=[]
	for id in JOBS:
		var template: Dictionary=JOBS[id]
		var start:=_service(template.start_service)
		var destination:=_service(template.destination_service)
		result.append({"id":id,"kind":template.kind,"label":template.label,
			"description":template.description,"start_building":start.building_id,
			"destination_building":destination.building_id,"duration":template.duration,
			"reward":template.reward,"requires":template.requires.duplicate(true),
			"available":true,"availability":"Ready"})
	_job_rows=result
	return _job_rows.duplicate(true)


static func _service(id: String) -> Dictionary:
	if _service_records.is_empty():
		for row in Plan.services():
			_service_records[str(row.id)]=row.duplicate(true)
	return _service_records.get(id,{})


static func property_spec(building_id: String) -> Dictionary:
	if building_id.is_empty() or building_id.length() > 80:
		return {}
	var building := Plan.building(building_id)
	if building.is_empty():
		return {}
	var tier := _housing_tier(str(building.get("housing","")))
	if tier.is_empty() or not HOUSING.has(tier):
		return {}
	var result: Dictionary = HOUSING[tier].duplicate(true)
	result["building"] = building_id
	result["name"] = str(building.name)
	result["tier"] = tier
	result["door"] = _point_array(building.door)
	result["district"] = _district_name(int(building.district))
	return result


func _buy_home(actor: String, payload: Dictionary, sim, position: Vector3, time: float) -> Dictionary:
	var building_id := _payload_building(payload)
	var spec := property_spec(building_id)
	if spec.is_empty():
		return _result(false,"Choose a real Crownreach home or warehouse.")
	if not _near(position,_array_point(spec.door)):
		return _result(false,"Visit this property's front door before buying it.")
	if state.properties.has(building_id):
		return _result(false,"This property already belongs to a resident.")
	if state.properties.size() >= MAX_PROPERTIES or _owned_count(actor) >= MAX_PROPERTIES_PER_ACTOR:
		return _result(false,"The resident property register is full for this account.")
	var price := int(spec.price)
	if payload.has("price") and (not _valid_integer(payload.price,0,1000000000) or int(payload.price) != price):
		return _result(false,"The property price is set by the city register.")
	if int(sim.balance(actor)) < price:
		return _result(false,"This property costs %d credits." % price)
	var record := {
		"owner":actor,"tier":spec.tier,"price_paid":price,"purchased_at":time,
		"storage_capacity":int(spec.storage_capacity),"storage":{},
	}
	# All checks are complete before either authoritative model is changed.
	sim._transfer(actor,PROPERTY_ACCOUNT,price,"Purchase Crownreach property "+building_id)
	state.properties[building_id] = record
	state.metrics.property_sales = int(state.metrics.property_sales)+1
	_record("property_purchase",{"actor":actor,"building":building_id,"credits":price,"time":time})
	return _result(true,"You bought %s for %d credits." % [str(spec.name),price])


func _store_item(actor: String, payload: Dictionary, sim, position: Vector3,
		time: float, depositing: bool) -> Dictionary:
	var building_id := _payload_building(payload)
	if not state.properties.has(building_id) or state.properties[building_id].owner != actor:
		return _result(false,"Use storage in a property you own.")
	var building := Plan.building(building_id)
	if building.is_empty() or not _near(position,building.door):
		return _result(false,"Use this property's cupboard or loading area in person.")
	var item := str(payload.get("item",""))
	var quantity := _quantity(payload.get("quantity",0))
	if quantity == 0 or not sim._known_item(item) or not _known_item(item):
		return _result(false,"Choose a known item and a whole quantity from 1 to 1000.")
	var property: Dictionary = state.properties[building_id]
	var player_location := str(sim.inventory_location(actor,"earth"))
	if depositing:
		if int(sim.stock(player_location,item)) < quantity:
			return _result(false,"Your Earth backpack does not hold that many.")
		if _storage_used(property.storage)+quantity > int(property.storage_capacity):
			return _result(false,"This property does not have enough storage space.")
	else:
		if int(property.storage.get(item,0)) < quantity:
			return _result(false,"This property does not hold that many.")
		if not sim._has_room(player_location,quantity):
			return _result(false,"Your Earth backpack is full.")
	if depositing:
		sim._remove_goods(player_location,item,quantity)
		property.storage[item] = int(property.storage.get(item,0))+quantity
	else:
		property.storage[item] = int(property.storage.get(item,0))-quantity
		sim._add_goods(player_location,item,quantity)
	sim._record("goods",{"from":player_location if depositing else "city_property:"+building_id,
		"to":"city_property:"+building_id if depositing else player_location,
		"item":item,"quantity":quantity})
	state.metrics.storage_moves = int(state.metrics.storage_moves)+1
	_record("storage",{"actor":actor,"building":building_id,"item":item,
		"quantity":quantity,"direction":"in" if depositing else "out","time":time})
	return _result(true,("Stored " if depositing else "Took ")+str(quantity)+" "+item.replace("_"," ")+
		("." if depositing else " from storage."))


func _set_home(actor: String, payload: Dictionary, position: Vector3, time: float) -> Dictionary:
	var building_id := _payload_building(payload)
	if not state.properties.has(building_id) or state.properties[building_id].owner != actor:
		return _result(false,"Choose a property you own.")
	var spec := property_spec(building_id)
	if spec.is_empty() or not bool(spec.residential):
		return _result(false,"A warehouse is a business base, not a home spawn.")
	if not _near(position,_array_point(spec.door)):
		return _result(false,"Use the bed inside this property to set your home.")
	state.homes[actor] = building_id
	_record("set_home",{"actor":actor,"building":building_id,"time":time})
	return _result(true,str(spec.name)+" is now your home address.")


func _start_job(actor: String, payload: Dictionary, sim, position: Vector3, time: float) -> Dictionary:
	if state.active_jobs.has(actor):
		return _result(false,"Finish your current city job first.")
	if state.active_jobs.size() >= MAX_ACTIVE_JOBS:
		return _result(false,"All funded city work slots are currently assigned.")
	var job_id := str(payload.get("job",payload.get("id","")))
	if not JOBS.has(job_id):
		return _result(false,"Choose a listed Crownreach job.")
	var template: Dictionary = JOBS[job_id]
	var source := _service(template.start_service)
	var destination := _service(template.destination_service)
	if source.is_empty() or destination.is_empty() or not _near(position,source.position):
		return _result(false,"Start this job at its marked workplace.")
	var promised := 0
	for active: Dictionary in state.active_jobs.values():
		promised += int(active.reward)
	if int(sim.balance(PROPERTY_ACCOUNT)) < promised+int(template.reward):
		return _result(false,"The city payroll needs more funded property revenue.")
	var cargo: Dictionary = template.cargo.duplicate(true)
	var player_location := str(sim.inventory_location(actor,"earth"))
	if template.kind == "courier":
		if not _inventory_has(state.service_inventories[template.start_service],cargo):
			return _result(false,"The courier depot is out of this parcel stock.")
		if not _service_has_room(str(template.destination_service),_storage_used(cargo)):
			return _result(false,"The delivery destination cannot receive this parcel yet.")
	elif template.kind == "maintenance":
		if int(sim.stock(player_location,"spare_parts")) < 1:
			return _result(false,"Maintenance work requires one spare part from your Earth backpack.")
	elif template.kind == "produce_provisioning":
		var produce := _choose_produce(sim,player_location,4)
		if produce.is_empty():
			return _result(false,"Bring four kilograms of one fresh crop to the produce exchange.")
		cargo = {produce:4}
		if not _service_has_room(str(template.destination_service),4):
			return _result(false,"Garden Row cannot receive more produce yet.")
	elif template.kind == "depot_restock":
		if not _inventory_has(sim.state.inventories[player_location],cargo):
			return _result(false,"Bring the listed goods in your Earth backpack before restocking.")
		if not _service_has_room(str(template.destination_service),_storage_used(cargo)):
			return _result(false,"The courier depot does not have room for this restock crate.")
	# Remove the finite cargo only after every validation and capacity check.
	if template.kind == "courier":
		_remove_inventory(state.service_inventories[template.start_service],cargo)
	else:
		_remove_sim_cargo(sim,player_location,cargo)
	var serial := int(state.next_job_id)
	state.next_job_id = serial+1
	state.active_jobs[actor] = {
		"id":"city_job_%d"%serial,"job":job_id,"owner":actor,"kind":template.kind,
		"label":template.label,"start_building":source.building_id,
		"destination_building":destination.building_id,
		"source_service":template.start_service,"destination_service":template.destination_service,
		"started_at":time,"ready_at":time+float(template.duration),
		"reward":int(template.reward),"cargo":cargo,"status":"active",
		"carry_mode":"sealed_job_cargo",
	}
	state.metrics.jobs_started = int(state.metrics.jobs_started)+1
	_record("job_started",{"actor":actor,"job":job_id,"cargo":cargo.duplicate(true),"time":time})
	return _result(true,"Job accepted. Take the marked cargo to "+str(destination.name)+".")


func _finish_job(actor: String, sim, position: Vector3, time: float) -> Dictionary:
	if not state.active_jobs.has(actor):
		return _result(false,"You do not have an active city job.")
	var active: Dictionary = state.active_jobs[actor]
	var destination := _service(str(active.destination_service))
	if destination.is_empty() or not _near(position,destination.position):
		return _result(false,"Finish this job at its marked destination.")
	if time+0.0001 < float(active.ready_at):
		return _result(false,"The work time has not finished yet.")
	if int(sim.balance(PROPERTY_ACCOUNT)) < int(active.reward):
		return _result(false,"The city payroll is temporarily underfunded.")
	if active.kind != "maintenance" and not _service_has_room(str(active.destination_service),_storage_used(active.cargo),actor):
		return _result(false,"The destination does not have room for this delivery.")
	if active.kind == "maintenance":
		for item in active.cargo:
			sim._record_resource("consumed",str(item),int(active.cargo[item]))
	else:
		_add_inventory(state.service_inventories[active.destination_service],active.cargo)
	sim._transfer(PROPERTY_ACCOUNT,actor,int(active.reward),"Complete Crownreach job "+str(active.job))
	var district_id := int(destination.district)
	if district_id >= 0 and district_id < state.districts.size():
		state.districts[district_id].completed_jobs = int(state.districts[district_id].completed_jobs)+1
		if active.kind=="maintenance":
			state.districts[district_id].service_condition=minf(1.0,float(state.districts[district_id].service_condition)+0.12)
		elif active.kind=="courier":
			state.districts[district_id].service_condition=minf(1.0,float(state.districts[district_id].service_condition)+0.015)
	state.metrics.jobs_completed = int(state.metrics.jobs_completed)+1
	_record("job_completed",{"actor":actor,"job":active.job,"credits":active.reward,
		"cargo":active.cargo.duplicate(true),"time":time})
	state.active_jobs.erase(actor)
	return _result(true,"Work complete. The city paid %d credits."%int(active.reward))


func _valid_state(candidate: Variant) -> bool:
	if not candidate is Dictionary:
		return false
	var data: Dictionary = candidate
	for key in ["properties","homes","active_jobs","service_inventories","metrics"]:
		if not data.get(key) is Dictionary:
			return false
	for key in ["districts","ledger"]:
		if not data.get(key) is Array:
			return false
	if not _valid_integer(data.get("schema_version"),VERSION,VERSION) \
			or not _valid_integer(data.get("seed"),0,1000000000000) \
			or not _valid_number(data.get("last_time"),0,1000000000) \
			or not _valid_integer(data.get("population"),POPULATION,POPULATION) \
			or not _valid_integer(data.get("next_job_id"),1,1000000000):
		return false
	if data.properties.size()>MAX_PROPERTIES or data.homes.size()>64 \
			or data.active_jobs.size()>MAX_ACTIVE_JOBS or data.ledger.size()>MAX_LEDGER:
		return false
	if data.service_inventories.size()!=SERVICE_IDS.size():
		return false
	for id in SERVICE_IDS:
		if not data.service_inventories.get(id) is Dictionary \
				or not _valid_inventory(data.service_inventories[id],int(SERVICE_CAPACITY[id])):
			return false
	var owner_counts := {}
	for building_id in data.properties:
		if not building_id is String:
			return false
		var spec := property_spec(str(building_id))
		var property: Variant = data.properties[building_id]
		if spec.is_empty() or not property is Dictionary:
			return false
		var owner := str(property.get("owner",""))
		if not _valid_actor(owner) or property.get("tier")!=spec.tier \
				or property.get("price_paid")!=spec.price \
				or not _valid_number(property.get("purchased_at"),0,data.last_time) \
				or property.get("storage_capacity")!=spec.storage_capacity \
				or not property.get("storage") is Dictionary \
				or not _valid_inventory(property.storage,int(spec.storage_capacity)):
			return false
		owner_counts[owner]=int(owner_counts.get(owner,0))+1
		if int(owner_counts[owner])>MAX_PROPERTIES_PER_ACTOR:
			return false
	for actor in data.homes:
		var building_id := str(data.homes[actor])
		if not actor is String or not _valid_actor(str(actor)) or not data.properties.has(building_id) \
				or data.properties[building_id].owner!=actor or not bool(property_spec(building_id).residential):
			return false
	for actor in data.active_jobs:
		if not actor is String or not _valid_actor(str(actor)) or not _valid_active_job(data.active_jobs[actor],str(actor),data):
			return false
	if data.districts.size()!=12 or not _valid_districts(data.districts):
		return false
	for key in ["aggregate_intervals","production_units","consumption_units",
			"service_goods_consumed","jobs_started","jobs_completed","property_sales",
			"storage_moves","skipped_intervals"]:
		if not _valid_integer(data.metrics.get(key),0,1000000000000000):
			return false
	for entry in data.ledger:
		if not entry is Dictionary or not entry.get("kind") is String \
				or str(entry.kind).length()>40 or not _valid_number(entry.get("time"),0,data.last_time):
			return false
	return true


func _valid_active_job(value: Variant, actor: String, data: Dictionary) -> bool:
	if not value is Dictionary:
		return false
	var job: Dictionary = value
	var template_id := str(job.get("job",""))
	if not JOBS.has(template_id) or job.get("owner")!=actor or job.get("status")!="active":
		return false
	var template: Dictionary = JOBS[template_id]
	var source := _service(template.start_service)
	var destination := _service(template.destination_service)
	if job.get("kind")!=template.kind or job.get("start_building")!=source.building_id \
			or job.get("destination_building")!=destination.building_id \
			or job.get("source_service")!=template.start_service \
			or job.get("destination_service")!=template.destination_service \
			or job.get("reward")!=template.reward or job.get("carry_mode")!="sealed_job_cargo" or not job.get("id") is String \
			or str(job.id).length()>40 or not _valid_number(job.get("started_at"),0,data.last_time) \
			or not _valid_number(job.get("ready_at"),job.started_at,data.last_time+1000) \
			or not job.get("cargo") is Dictionary or not _valid_inventory(job.cargo,1000) \
			or job.cargo.is_empty():
		return false
	if not is_equal_approx(float(job.ready_at)-float(job.started_at),float(template.duration)):
		return false
	if template.kind == "courier" and job.cargo != template.cargo:
		return false
	if template.kind == "maintenance" and job.cargo != {"spare_parts":1}:
		return false
	if template.kind == "depot_restock" and job.cargo != template.cargo:
		return false
	if template.kind == "produce_provisioning":
		if job.cargo.size()!=1 or int(job.cargo.values()[0])!=4 or str(job.cargo.keys()[0]) not in CROP_ITEMS:
			return false
	return true


func _valid_districts(rows: Array) -> bool:
	var catalog := Plan.district_catalog()
	var population := 0
	for index in range(rows.size()):
		var row: Variant = rows[index]
		if not row is Dictionary or row.get("id")!=index or row.get("name")!=catalog[index].name \
				or row.get("kind")!=catalog[index].kind \
				or not _valid_integer(row.get("population"),0,POPULATION) \
				or not _valid_integer(row.get("workforce_capacity"),0,POPULATION) \
				or not _valid_integer(row.get("workforce"),0,POPULATION) \
				or not _valid_integer(row.get("food_stock"),0,400) \
				or not _valid_integer(row.get("food_demand"),1,1000) \
				or not _valid_number(row.get("service_condition"),0.25,1.0) \
				or not _valid_integer(row.get("shortages"),0,1000000000000000) \
				or not _valid_integer(row.get("production_units"),0,1000000000000000) \
				or not _valid_integer(row.get("consumption_units"),0,1000000000000000) \
				or not _valid_integer(row.get("job_minutes"),0,1000000000000000) \
				or not _valid_integer(row.get("completed_jobs"),0,1000000000):
			return false
		population += int(row.population)
	return population == POPULATION


func _new_districts() -> Array:
	var populations: Array[int] = []
	populations.resize(12)
	populations.fill(0)
	for y in range(Plan.GRID_SIZE):
		for x in range(Plan.GRID_SIZE):
			var key := Vector2i(x,y)
			populations[Plan.district_for_block(key)] += Plan.block_population(key)
	var result: Array = []
	for row in Plan.district_catalog():
		var population := populations[int(row.id)]
		var capacity:=roundi(float(population)*0.58)
		result.append({"id":int(row.id),"name":str(row.name),"kind":str(row.kind),
			"population":population,"workforce_capacity":capacity,"workforce":capacity,
			"food_stock":72+int(row.id)*3,"food_demand":maxi(1,ceili(float(population)/10000.0)),
			"service_condition":0.92-float(int(row.id)%4)*0.01,"shortages":0,
			"production_units":0,"consumption_units":0,"job_minutes":0,"completed_jobs":0})
	return result


func _public_property(building_id: String, property: Dictionary, actor: String,
		include_storage: bool) -> Dictionary:
	var spec := property_spec(building_id)
	return {"building":building_id,"name":spec.name,"tier":property.tier,
		"district":spec.district,"door":spec.door.duplicate(),
		"price_paid":int(property.price_paid),"purchased_at":float(property.purchased_at),
		"storage_capacity":int(property.storage_capacity),
		"storage_used":_storage_used(property.storage),
		"storage":property.storage.duplicate(true) if include_storage else {},
		"storage_included":include_storage,
		"is_home":str(state.homes.get(actor,""))==building_id}


func _consume_service_goods(intervals: int) -> void:
	var consumed := 0
	for id in ["courier_delivery_lantern","courier_delivery_clinic","courier_delivery_rail","produce_market"]:
		var inventory: Dictionary = state.service_inventories[id]
		for item in inventory.keys():
			var quantity := mini(int(inventory[item]),intervals)
			if quantity>0:
				inventory[item]=int(inventory[item])-quantity
				consumed+=quantity
				var service:=_service(id)
				var district_id:=int(service.get("district",-1))
				if district_id>=0 and district_id<state.districts.size():
					var district: Dictionary=state.districts[district_id]
					if str(item)=="meal" or str(item) in CROP_ITEMS:
						district.food_stock=clampi(int(district.food_stock)+quantity*2,0,400)
					else:
						district.service_condition=minf(1.0,float(district.service_condition)+float(quantity)*0.002)
	state.metrics.service_goods_consumed = _bounded_counter(int(state.metrics.service_goods_consumed)+consumed)


func _service_has_room(service_id: String, additional: int, excluding_actor: String = "") -> bool:
	var used := _storage_used(state.service_inventories.get(service_id,{}))
	for actor in state.active_jobs:
		if actor == excluding_actor:
			continue
		var job: Dictionary = state.active_jobs[actor]
		if job.kind != "maintenance" and job.destination_service == service_id:
			used += _storage_used(job.cargo)
	return used+additional <= int(SERVICE_CAPACITY.get(service_id,0))


func _choose_produce(sim, location: String, quantity: int) -> String:
	for item in CROP_ITEMS:
		if int(sim.stock(location,item))>=quantity:
			return item
	return ""


func _apply_actor_resources(snapshot: Dictionary, actor: String, sim) -> void:
	var location:=str(sim.inventory_location(actor,"earth"))
	if not sim.state.inventories.has(location): return
	var bag: Dictionary=sim.state.inventories[location]
	snapshot.credits=int(sim.balance(actor))
	snapshot.backpack_counts=bag.duplicate(true)
	snapshot.backpack_capacity=int(sim.state.locations.get(location,{}).get("capacity",350))
	var promised:=0
	for active: Dictionary in state.active_jobs.values(): promised+=int(active.reward)
	var payroll:=maxi(0,int(sim.balance(PROPERTY_ACCOUNT))-promised)
	for row: Dictionary in snapshot.job_catalog:
		var template: Dictionary=JOBS[row.id]
		var available:=payroll>=int(template.reward)
		var reason:="Ready"
		if not available: reason="City payroll is currently reserved"
		elif template.kind=="courier" and not _inventory_has(state.service_inventories[template.start_service],template.cargo):
			available=false
			reason="Depot cargo is out of stock"
		elif template.kind in ["maintenance","depot_restock"] and not _inventory_has(bag,template.cargo):
			available=false
			reason="Bring "+_items_text(template.cargo)
		elif template.kind=="produce_provisioning" and _choose_produce(sim,location,4).is_empty():
			available=false
			reason="Bring four kilograms of one fresh crop"
		elif template.kind!="maintenance" and not _service_has_room(str(template.destination_service),
				_storage_used(template.cargo) if template.kind!="produce_provisioning" else 4,actor):
			available=false
			reason="The destination is at capacity"
		row.available=available
		row.availability=reason


func _remove_sim_cargo(sim, location: String, cargo: Dictionary) -> void:
	for item in cargo:
		sim._remove_goods(location,str(item),int(cargo[item]))
		sim._record("goods",{"from":location,"to":"city_job","item":str(item),"quantity":int(cargo[item])})


func _record(kind: String, payload: Dictionary) -> void:
	var entry := payload.duplicate(true)
	entry["kind"] = kind
	state.ledger.append(entry)
	if state.ledger.size()>MAX_LEDGER:
		state.ledger.pop_front()


func _owned_count(actor: String) -> int:
	var count := 0
	for property: Dictionary in state.properties.values():
		if property.owner == actor:
			count += 1
	return count


static func _housing_tier(value: String) -> String:
	match value:
		"work_live","staff_residence": return "city_apartment"
		"town_house": return "suburban_home"
		"cottage","town_apartment","suburban_home","city_apartment","penthouse","warehouse": return value
	return ""


static func _district_name(id: int) -> String:
	var district := Plan.district(id)
	return str(district.get("name","Origin Villages"))


static func _payload_building(payload: Dictionary) -> String:
	return str(payload.get("building",payload.get("property",payload.get("id",""))))


static func _point_array(point: Variant) -> Array:
	if point is Vector3:
		return [float(point.x),float(point.y),float(point.z)]
	return []


static func _array_point(value: Variant) -> Vector3:
	if value is Array and value.size()==3:
		return Vector3(float(value[0]),float(value[1]),float(value[2]))
	return Vector3.INF


static func _near(position: Vector3, target: Vector3) -> bool:
	return target.is_finite() and position.distance_to(target)<=ACTION_RANGE


static func _valid_position(value: Vector3) -> bool:
	return value.is_finite() and absf(value.x)<=1000000 and absf(value.y)<=1000000 and absf(value.z)<=1000000


static func _valid_time(time: float, sim) -> bool:
	return is_finite(time) and time>=0.0 and time+0.0001>=float(sim.state.get("time",0.0))-2.0 \
		and time<=float(sim.state.get("time",0.0))+2.0


static func _valid_actor(actor: String) -> bool:
	if actor == "player":
		return true
	if not actor.begins_with("member_") or actor.length()!=71:
		return false
	for c in actor.trim_prefix("member_"):
		if c not in "0123456789abcdef":
			return false
	return true


static func _quantity(value: Variant) -> int:
	if typeof(value) not in [TYPE_INT,TYPE_FLOAT] or not is_finite(float(value)) \
			or float(value)!=floor(float(value)) or float(value)<1 or float(value)>1000:
		return 0
	return int(value)


static func _known_item(item: String) -> bool:
	return item in BASE_ITEMS or item in CROP_ITEMS or item in PLANTING_ITEMS


static func _valid_inventory(value: Dictionary, capacity: int) -> bool:
	if value.size()>64:
		return false
	var used := 0
	for item in value:
		if not item is String or not _known_item(str(item)) \
				or not _valid_integer(value[item],0,100000):
			return false
		used += int(value[item])
	return used<=capacity


static func _inventory_has(inventory: Dictionary, cargo: Dictionary) -> bool:
	for item in cargo:
		if int(inventory.get(item,0))<int(cargo[item]):
			return false
	return true


static func _remove_inventory(inventory: Dictionary, cargo: Dictionary) -> void:
	for item in cargo:
		inventory[item]=int(inventory.get(item,0))-int(cargo[item])


static func _add_inventory(inventory: Dictionary, cargo: Dictionary) -> void:
	for item in cargo:
		inventory[item]=int(inventory.get(item,0))+int(cargo[item])


static func _storage_used(inventory: Dictionary) -> int:
	var result := 0
	for quantity in inventory.values():
		result += int(quantity)
	return result


static func _items_text(items: Dictionary) -> String:
	var parts: PackedStringArray=[]
	for item in items:
		parts.append("%d %s"%[int(items[item]),str(item).replace("_"," ")])
	return ", ".join(parts)


static func _sorted_keys(value: Dictionary) -> Array:
	var result: Array = value.keys()
	result.sort()
	return result


static func _bounded_counter(value: int) -> int:
	return mini(value,1000000000000000)


static func _valid_number(value: Variant, minimum: float, maximum: float) -> bool:
	return typeof(value) in [TYPE_INT,TYPE_FLOAT] and is_finite(float(value)) \
		and float(value)>=minimum and float(value)<=maximum


static func _valid_integer(value: Variant, minimum: float, maximum: float) -> bool:
	return _valid_number(value,minimum,maximum) and float(value)==floor(float(value))


static func _result(ok: bool, message: String) -> Dictionary:
	return {"ok":ok,"message":message}
