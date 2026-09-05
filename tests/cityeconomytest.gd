extends Node
## Crownreach property, finite storage/job cargo, aggregate census and atomic
## offline/online persistence regression. Registered by main as cityeconomytest.
const EconomyScript=preload("res://scripts/city_economy.gd")
const SimScript=preload("res://scripts/frontier_sim.gd")
const SocietiesScript=preload("res://scripts/frontier_societies.gd")
const Plan=preload("res://scripts/city_plan.gd")

var passed:=0
var checks:=0


func _check(value: bool, label: String) -> void:
	checks+=1
	if value:
		passed+=1
	else:
		push_error("CITYECONOMYTEST FAIL: "+label)


func run(_main=null) -> void:
	run_checks()
	print("CITYECONOMYTEST result=%d/%d %s"%[passed,checks,"PASS" if passed==checks else "FAIL"])
	get_tree().quit(0 if passed==checks else 1)


func run_checks() -> bool:
	_catalog_and_aggregate_checks()
	_offline_property_checks()
	_retail_checks()
	_job_checks()
	_society_persistence_and_privacy_checks()
	return passed==checks


func _catalog_and_aggregate_checks() -> void:
	var economy=EconomyScript.new()
	economy.new_game(2026,400.0)
	var imported=EconomyScript.new()
	_check(imported.import_state(economy.state),"fresh bounded city state imports")
	var snapshot: Dictionary=economy.view("player")
	var census:=0
	for district: Dictionary in snapshot.districts: census+=int(district.population)
	_check(snapshot.city.population==100000 and census==100000 and snapshot.districts.size()==12,
		"twelve aggregate districts represent exactly 100,000 residents")
	_check(not economy.state.has("residents") and economy.state.size()<24,
		"city census has no per-resident simulation records")
	var catalog: Array=snapshot.housing_catalog
	var tiers:={}
	for row: Dictionary in catalog: tiers[row.id]=row
	_check(catalog.size()==6 and tiers.keys().all(func(id): return id in EconomyScript.HOUSING),
		"six intentional housing tiers are public")
	_check(int(tiers.cottage.price)<int(tiers.town_apartment.price)
		and int(tiers.cottage.price)<=1800,"cheapest cottage is starter-affordable")
	var largest:=0
	for row: Dictionary in catalog: largest=maxi(largest,int(row.storage_capacity))
	_check(int(tiers.warehouse.storage_capacity)==largest
		and int(tiers.warehouse.luxury)<int(tiers.penthouse.luxury)
		and not bool(tiers.warehouse.residential),"warehouse is maximum storage rather than a luxury home")
	var generated:=EconomyScript.property_spec("crownreach-b01-01-l01")
	_check(not generated.is_empty() and generated.id=="city_apartment"
		and generated.building=="crownreach-b01-01-l01",
		"ordinary deterministic housing buildings are purchasable beyond six landmarks")
	_check(snapshot.job_catalog.size()==12 and snapshot.services.size()==11,
		"courier, maintenance, provisioning and restocking jobs use exact physical service doors")
	var before_goods:=economy.total_goods("meal")
	_check(economy.advance(460.0),"aggregate clock advances in one bounded calculation")
	var advanced:=economy.view("player")
	_check(int(advanced.metrics.aggregate_intervals)==1
		and int(advanced.metrics.production_units)>0
		and int(advanced.metrics.consumption_units)>0,
		"district production and consumption respond each city interval")
	_check(int(advanced.metrics.workforce)>0 and float(advanced.metrics.service_reliability)>0.25,
		"finite food and service state drive an aggregate workforce")
	_check(economy.total_goods("meal")==before_goods,
		"census counters do not mint or consume undelivered trade goods")
	_check(economy.advance(1000000000.0) and int(economy.state.metrics.aggregate_intervals)==61
		and int(economy.state.metrics.skipped_intervals)>0,
		"huge time gaps skip bounded aggregate work instead of ticking 100,000 actors")
	_check(imported.import_state(economy.state),"bounded long-horizon aggregate state remains valid")
	_maximum_view_bound_check()


func _maximum_view_bound_check() -> void:
	var economy=EconomyScript.new()
	economy.new_game(2026,400.0)
	var ids: Array=[]
	for y in range(Plan.GRID_DEPTH):
		for x in range(Plan.GRID_WIDTH):
			for building: Dictionary in Plan.block_buildings(Vector2i(x,y)):
				if not str(building.housing).is_empty(): ids.append(str(building.id))
				if ids.size()>=EconomyScript.MAX_PROPERTIES: break
			if ids.size()>=EconomyScript.MAX_PROPERTIES: break
		if ids.size()>=EconomyScript.MAX_PROPERTIES: break
	for index in range(ids.size()):
		var spec: Dictionary=EconomyScript.property_spec(ids[index])
		var actor:="player" if index<EconomyScript.MAX_PROPERTIES_PER_ACTOR else \
			"member_"+str((index-EconomyScript.MAX_PROPERTIES_PER_ACTOR)/EconomyScript.MAX_PROPERTIES_PER_ACTOR+1).pad_zeros(64)
		var storage:={}
		if actor=="player":
			for item in _all_items().slice(0,64): storage[item]=1
		economy.state.properties[ids[index]]={"owner":actor,"tier":spec.tier,
			"price_paid":spec.price,"purchased_at":400.0,
			"storage_capacity":spec.storage_capacity,"storage":storage}
	var started:=Time.get_ticks_usec()
	var valid: bool=EconomyScript.new().import_state(economy.state)
	var validation_elapsed:=Time.get_ticks_usec()-started
	var sim=_world()
	var full_bag:={}
	for item in _all_items(): full_bag[item]=1
	sim.state.inventories.player_earth=full_bag.duplicate(true)
	sim.state.inventories.player_moon=full_bag.duplicate(true)
	started=Time.get_ticks_usec()
	var snapshot: Dictionary=economy.view("player",sim,ids[0])
	var view_elapsed:=Time.get_ticks_usec()-started
	var wrapped:={"ok":true,"message":"Property inventory updated.","revision":2147483647,
		"view":snapshot,"player_patch":{"accounts":{"player":1800},"inventories":{
			"player_earth":full_bag.duplicate(true),"player_moon":full_bag.duplicate(true)}}}
	var bytes:=var_to_bytes(wrapped).size()
	_check(ids.size()==EconomyScript.MAX_PROPERTIES and valid,
		"global property register remains valid at its exact bounded maximum")
	var included:=0
	for property: Dictionary in snapshot.owned_properties:
		if property.storage_included: included+=1
	_check(snapshot.unavailable_buildings.size()==EconomyScript.MAX_PROPERTIES-EconomyScript.MAX_PROPERTIES_PER_ACTOR
		and included==1 and snapshot.owned_properties[0].storage.size()==64,
		"maximum view includes only the trusted property's full inventory")
	_check(bytes<49152,"fully wrapped maximum city response stays below the 49,152-byte network cap")
	sim.state.city=economy.state
	sim._city_model=economy
	var ninth: Dictionary=Plan.building("crownreach-b40-40-l01")
	started=Time.get_ticks_usec()
	var capped: Dictionary=sim.city_action("buy_home",{"building":ninth.id},ninth.door)
	var action_elapsed:=Time.get_ticks_usec()-started
	_check(not capped.ok,"maximum register rejects another transaction without growing")
	print("CITYECONOMYTEST max_properties=%d wrapped_response_bytes=%d validate_ms=%.3f view_ms=%.3f capped_action_ms=%.3f"%
		[ids.size(),bytes,float(validation_elapsed)/1000.0,float(view_elapsed)/1000.0,
		float(action_elapsed)/1000.0])


func _offline_property_checks() -> void:
	var sim=_world()
	var door: Vector3=Plan.building("village-cottage").door
	_check(sim.state.has("city") and sim.validate_state(sim.state),
		"offline new game contains a valid Crownreach state")
	_check(sim.city_view().credits==1800 and sim.city_view().backpack_counts.banana==8,
		"offline city view uses the real wallet and Earth backpack")
	var baseline:=JSON.stringify(sim.state)
	_check(not sim.city_action("buy_home",{"building":"village-cottage","position":door},
		Vector3.ZERO).ok and JSON.stringify(sim.state)==baseline,
		"forged payload position cannot replace trusted physical position")
	_check(not sim.city_action("buy_home",{"building":"village-cottage","price":1},door).ok
		and JSON.stringify(sim.state)==baseline,"forged property price rejects atomically")
	var money: int=sim.total_money()
	var player_money: int=sim.balance("player")
	var treasury: int=sim.balance("treasury")
	_check(sim.city_action("buy_home",{"building":"village-cottage"},door).ok,
		"resident buys cottage at its canonical door")
	_check(sim.balance("player")==player_money-450 and sim.balance("treasury")==treasury+450
		and sim.total_money()==money,"property payment moves finite credits into treasury")
	baseline=JSON.stringify(sim.state)
	_check(not sim.city_action("buy_home",{"building":"village-cottage"},door).ok
		and JSON.stringify(sim.state)==baseline,"exclusive property cannot be charged twice")
	var city_goods_before:=_combined_goods(sim,"banana")
	_check(sim.city_action("store_item",{"building":"village-cottage","item":"banana","quantity":5},door).ok,
		"owned cupboard accepts actual backpack goods")
	var own: Dictionary=sim.city_view("village-cottage").owned_properties[0]
	_check(sim.stock("player_earth","banana")==3 and own.storage.banana==5
		and _combined_goods(sim,"banana")==city_goods_before,"storage move conserves exact item quantity")
	baseline=JSON.stringify(sim.state)
	_check(not sim.city_action("store_item",{"building":"village-cottage","item":"banana","quantity":1.5},door).ok
		and JSON.stringify(sim.state)==baseline,"fractional storage quantity leaves both models unchanged")
	_check(not sim.city_action("store_item",{"building":"village-cottage","item":"not_real","quantity":1},door).ok
		and JSON.stringify(sim.state)==baseline,"unknown storage item rejects without mutation")
	# Fill the cottage from real market stock, then prove capacity rejection does
	# not remove the attempted item from the backpack.
	sim._move_goods("earth_market","player_earth","water",36)
	_check(sim.stock("player_earth","water")>=76,"capacity fixture uses real finite market water")
	baseline=JSON.stringify(sim.state)
	_check(not sim.city_action("store_item",{"building":"village-cottage","item":"water","quantity":76},door).ok
		and JSON.stringify(sim.state)==baseline,"property capacity failure is atomic")
	_check(sim.city_action("take_item",{"building":"village-cottage","item":"banana","quantity":2},door).ok
		and sim.stock("player_earth","banana")==5 and _combined_goods(sim,"banana")==city_goods_before,
		"taking stored goods returns the same real stock")
	var old_capacity:=int(sim.state.locations.player_earth.capacity)
	var occupied:=0
	for quantity in sim.state.inventories.player_earth.values(): occupied+=int(quantity)
	sim.state.locations.player_earth.capacity=occupied
	baseline=JSON.stringify(sim.state)
	_check(not sim.city_action("take_item",{"building":"village-cottage","item":"banana","quantity":1},door).ok
		and JSON.stringify(sim.state)==baseline,"full backpack cannot pull property stock")
	sim.state.locations.player_earth.capacity=old_capacity
	baseline=JSON.stringify(sim.state)
	_check(not sim.city_action("set_home",{"building":"village-cottage"},Vector3.ZERO).ok
		and JSON.stringify(sim.state)==baseline,"home spawn cannot be set remotely")
	_check(sim.city_action("set_home",{"building":"village-cottage"},door).ok
		and sim.city_view().home=="village-cottage"
		and _array_vec3(sim.city_view().home_spawn).is_equal_approx(door),
		"owned bed records the exact canonical home spawn")
	# Warehouse is a practical bulk store, explicitly not a respawn bed.
	sim._transfer("treasury","player",3000,"test funded warehouse purchase")
	var warehouse: Vector3=Plan.building("crownreach-b04-08-l03").door
	_check(sim.city_action("buy_home",{"building":"crownreach-b04-08-l03"},warehouse).ok,
		"resident can buy the featured warehouse with funded credits")
	baseline=JSON.stringify(sim.state)
	_check(not sim.city_action("set_home",{"building":"crownreach-b04-08-l03"},warehouse).ok
		and JSON.stringify(sim.state)==baseline,"warehouse storage cannot masquerade as a luxury home spawn")
	_check(sim.validate_state(sim.state),"purchased homes and stored inventory preserve full sim validation")
	_property_cap_check()
	_save_migration_checks(sim)


func _save_migration_checks(sim) -> void:
	var path:="user://cityeconomytest-save.json"
	for suffix in ["",".bak",".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path+suffix))
	_check(sim.save_game(path),"offline city saves through the existing atomic checkpoint")
	var loaded=_world()
	_check(loaded.load_game(path) and loaded.city_view().home=="village-cottage"
		and loaded.city_view().owned_buildings.has("crownreach-b04-08-l03"),
		"property ownership, storage and home survive offline reload")
	var legacy: Dictionary=sim.state.duplicate(true)
	legacy.erase("city")
	_write_json(path,legacy)
	var migrated=_world()
	_check(migrated.load_game(path) and migrated.state.has("city")
		and migrated.city_view().owned_properties.is_empty(),"older save without city migrates to a valid empty register")
	var corrupt: Dictionary=sim.state.duplicate(true)
	corrupt.city.properties["village-cottage"].storage_capacity=999
	_write_json(path,corrupt)
	var preserved:=JSON.stringify(loaded.state)
	_check(not loaded.load_game(path) and JSON.stringify(loaded.state)==preserved,
		"invalid present city state rejects without replacing a valid offline world")
	corrupt=sim.state.duplicate(true)
	corrupt.city.properties["village-cottage"].owner="member_"+"f".repeat(64)
	_check(not sim.validate_state(corrupt),"offline save rejects an injected multiplayer property owner")
	for suffix in ["",".bak",".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path+suffix))


func _property_cap_check() -> void:
	var sim=_world()
	sim._transfer("treasury","player",20000,"test funded property cap")
	var ids: Array=[]
	for building: Dictionary in Plan.block_buildings(Vector2i(1,1)):
		if not str(building.housing).is_empty(): ids.append(str(building.id))
	_check(ids.size()>EconomyScript.MAX_PROPERTIES_PER_ACTOR,
		"deterministic block exposes enough ordinary homes for ownership cap fixture")
	for index in range(EconomyScript.MAX_PROPERTIES_PER_ACTOR):
		var building: Dictionary=Plan.building(ids[index])
		_check(sim.city_action("buy_home",{"building":ids[index]},building.door).ok,
			"bounded resident property purchase %d"%(index+1))
	var ninth: Dictionary=Plan.building(ids[EconomyScript.MAX_PROPERTIES_PER_ACTOR])
	var baseline:=JSON.stringify(sim.state)
	_check(not sim.city_action("buy_home",{"building":ninth.id},ninth.door).ok
		and JSON.stringify(sim.state)==baseline,"ninth property rejects without charging or registering")


func _job_checks() -> void:
	_courier_job_checks()
	_maintenance_job_checks()
	_produce_job_checks()
	_restock_job_checks()


func _retail_checks() -> void:
	var sim=_world()
	var catalog: Array=sim.city_view().retail_catalog
	var offers: Array[Dictionary]=[
		{"kind":"market","item":"banana","price":6,"service":"produce_market","building":"crownreach-b24-24-l00","stock":240},
		{"kind":"restaurant","item":"meal","price":12,"service":"courier_depot","building":"crownreach-b22-24-l01","stock":600},
		{"kind":"workshop","item":"spare_parts","price":28,"service":"maintenance_depot","building":"crownreach-b00-23-l12","stock":90},
	]
	_check(catalog.size()==3,"bounded retail catalog exposes three practical storefront categories")
	for offer in offers:
		var row: Dictionary={}
		for candidate: Dictionary in catalog:
			if candidate.kind==offer.kind: row=candidate
		_check(not row.is_empty() and row.item==offer.item and row.price==offer.price
			and row.service==offer.service and row.stock==offer.stock,
			"%s publishes its exact price and finite shared stock"%offer.kind)
		var shop: Dictionary=Plan.building(offer.building)
		var wallet: int=sim.balance("player")
		var treasury: int=sim.balance("treasury")
		var money: int=sim.total_money()
		var goods:=_combined_goods(sim,offer.item)
		var bag: int=sim.stock("player_earth",offer.item)
		var stock:=_city_stock(sim,offer.service,offer.item)
		_check(shop.kind==offer.kind and sim.city_action("buy_store_item",
			{"building":shop.id,"item":offer.item,"quantity":2},shop.door).ok,
			"%s storefront sells its listed item at the actual park building door"%offer.kind)
		_check(sim.balance("player")==wallet-int(offer.price)*2
			and sim.balance("treasury")==treasury+int(offer.price)*2 and sim.total_money()==money
			and sim.stock("player_earth",offer.item)==bag+2
			and _city_stock(sim,offer.service,offer.item)==stock-2
			and _combined_goods(sim,offer.item)==goods,
			"%s sale moves exact existing goods and credits without minting"%offer.kind)
	_check(sim.validate_state(sim.state),"all three storefront purchases retain a valid authoritative world")
	_retail_rejection_checks()
	_retail_shared_stock_checks()
	_retail_persistence_checks(sim)
	_retail_online_checks()


func _retail_rejection_checks() -> void:
	var sim=_world()
	var shop: Dictionary=Plan.building("crownreach-b24-24-l00")
	var purchase:={"building":shop.id,"item":"banana","quantity":1}
	for quantity in [0,-1,1.5,101,"1",true,NAN,INF,1000000000]:
		var malformed: Dictionary=purchase.duplicate(true)
		malformed.quantity=quantity
		_retail_reject(sim,malformed,shop.door,"retail rejects invalid quantity %s atomically"%str(quantity))
	for change: Dictionary in [{"building":42},{"item":42},{"item":"meal"},
		{"building":"crownreach-b00-99-l00"},{"building":"crownreach-b01-01-l04"},
		{"price":1},{"service":"courier_depot"}]:
		var malformed: Dictionary=purchase.duplicate(true)
		malformed.merge(change,true)
		_retail_reject(sim,malformed,shop.door,"retail rejects forged or mismatched payload %s"%JSON.stringify(change))
	var missing: Dictionary=purchase.duplicate(true)
	missing.erase("quantity")
	_retail_reject(sim,missing,shop.door,"retail requires an explicit whole quantity")
	_retail_reject(sim,purchase,shop.door+Vector3(18.1,0,0),"retail rejects a shopper beyond the trusted door range")
	_retail_reject(sim,purchase,Vector3(NAN,0,0),"retail rejects a nonfinite trusted position")
	var poor=_world()
	poor._transfer("player","treasury",poor.balance("player"),"retail test empties wallet through a real transfer")
	_retail_reject(poor,purchase,shop.door,"an unfunded shopper cannot remove shop stock")
	var full=_world()
	var occupied:=0
	for quantity in full.state.inventories.player_earth.values(): occupied+=int(quantity)
	full.state.locations.player_earth.capacity=occupied
	_retail_reject(full,purchase,shop.door,"a full backpack cannot be charged or remove shop stock")


func _retail_shared_stock_checks() -> void:
	var sim=_world()
	var first: Dictionary=Plan.building("crownreach-b24-24-l00")
	var second: Dictionary=Plan.building("crownreach-b12-24-l00")
	var goods:=_combined_goods(sim,"banana")
	var money: int=sim.total_money()
	var bag: int=sim.stock("player_earth","banana")
	var all_bought:=true
	var shops:=[first,second,first]
	var quantities:=[100,100,40]
	for index in range(3):
		var shop: Dictionary=shops[index]
		all_bought=all_bought and sim.city_action("buy_store_item",
			{"building":shop.id,"item":"banana","quantity":quantities[index]},shop.door).ok
	_check(first.id!=second.id and first.kind=="market" and second.kind=="market" and all_bought
		and _city_stock(sim,"produce_market","banana")==0
		and sim.stock("player_earth","banana")==bag+240
		and _combined_goods(sim,"banana")==goods and sim.total_money()==money,
		"two markets share and exactly exhaust the same 240 finite bananas with 100-unit boundary orders")
	_retail_reject(sim,{"building":second.id,"item":"banana","quantity":1},second.door,
		"an exhausted shared shop cannot sell one more item despite sufficient bag space and credits")
	var stock_view:=0
	for row: Dictionary in sim.city_view().retail_catalog:
		if row.kind=="market": stock_view=int(row.stock)
	_check(stock_view==0 and sim.validate_state(sim.state),"sold-out stock is visible and the depleted world remains valid")


func _retail_persistence_checks(sim) -> void:
	var path:="user://cityeconomytest-retail-save.json"
	for suffix in ["",".bak",".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path+suffix))
	_check(sim.save_game(path),"retail inventory and wallet save through the real atomic checkpoint")
	var loaded=_world()
	var load_ok: bool=loaded.load_game(path)
	var quantities_match:=true
	# JSON preserves integer quantities as numeric values, not Variant int tags.
	# Compare every known count through the public integer stock accessors.
	for item in _all_items():
		quantities_match=quantities_match and loaded.stock("player_earth",item)==sim.stock("player_earth",item)
		for service in EconomyScript.SERVICE_IDS:
			quantities_match=quantities_match and _city_stock(loaded,service,item)==_city_stock(sim,service,item)
	_check(load_ok and loaded.balance("player")==sim.balance("player") and quantities_match,
		"shop depletion and purchased backpack items survive save and reload exactly")
	var legacy: Dictionary=sim.state.duplicate(true)
	legacy.city.service_inventories.produce_market={}
	legacy.city.service_inventories.maintenance_depot={}
	_write_json(path,legacy)
	var migrated=_world()
	_check(migrated.load_game(path) and int(migrated.state.city.schema_version)==1
		and migrated.state.city.service_inventories.size()==11
		and migrated.state.city.service_inventories.produce_market.is_empty()
		and migrated.state.city.service_inventories.maintenance_depot.is_empty(),
		"existing schema-one saves retain empty retail stock without automatic refills or new service keys")
	var market: Dictionary=Plan.building("crownreach-b24-24-l00")
	_retail_reject(migrated,{"building":market.id,"item":"banana","quantity":1},market.door,
		"loading an older empty shop cannot create opening stock on its first purchase")
	for suffix in ["",".bak",".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path+suffix))


func _retail_reject(sim,payload: Dictionary,position: Vector3,label: String) -> void:
	var before:=JSON.stringify(sim.state)
	_check(not sim.city_action("buy_store_item",payload,position).ok
		and JSON.stringify(sim.state)==before,label)


func _retail_online_checks() -> void:
	var societies=SocietiesScript.new()
	societies.new_game(2026)
	var identities:=["1".repeat(64),"2".repeat(64)]
	var market: Dictionary=Plan.building("crownreach-b24-24-l00")
	for identity in identities:
		_check(societies.ensure_player(identity,"Shopper").ok,"online retail shopper has an authenticated funded account")
	var money: int=societies.total_money()
	var both_bought:=true
	for identity in identities:
		both_bought=both_bought and societies.city_action(identity,"buy_store_item",
			{"building":market.id,"item":"banana","quantity":1},market.door).ok
		var view: Dictionary=societies.city_view(identity)
		both_bought=both_bought and view.credits==1794 and view.backpack_counts.banana==9
	_check(both_bought and int(societies.state.city.service_inventories.produce_market.banana)==238
		and societies.total_money()==money,
		"two online shoppers share one finite shop while charging only their own wallets and crediting their own bags")
	var before:=JSON.stringify(societies.export_state())
	_check(not societies.city_action("f".repeat(64),"buy_store_item",
		{"building":market.id,"item":"banana","quantity":1},market.door).ok
		and JSON.stringify(societies.export_state())==before,
		"an unregistered online identity cannot consume shared retail stock")
	var restored=SocietiesScript.new()
	restored.new_game(99)
	_check(restored.import_state(societies.export_state())
		and restored.city_view(identities[0]).backpack_counts.banana==9
		and restored.city_view(identities[1]).backpack_counts.banana==9
		and int(restored.state.city.service_inventories.produce_market.banana)==238,
		"online retail depletion and both private purchases survive authority restart")


func _courier_job_checks() -> void:
	var sim=_world()
	var source: Vector3=Plan.service("courier_depot").position
	var destination: Vector3=Plan.service("courier_delivery_lantern").position
	var total_before:=_combined_goods(sim,"meal")
	var money_before: int=sim.total_money()
	var depot_before:=_city_stock(sim,"courier_depot","meal")
	var baseline:=JSON.stringify(sim.state)
	_check(not sim.city_action("start_job",{"job":"courier_lantern"},source,NAN).ok
		and JSON.stringify(sim.state)==baseline,"nonfinite authority time cannot mutate city cargo")
	_check(not sim.city_action("start_job",{"job":"courier_lantern","target":"courier_delivery_rail"},
		Vector3.ZERO).ok and JSON.stringify(sim.state)==baseline,"courier cannot start away from its depot or forge a target")
	var unfunded=_world()
	unfunded._transfer("treasury","cooperative",unfunded.balance("treasury"),"test empty city payroll")
	var unfunded_before:=JSON.stringify(unfunded.state)
	_check(not unfunded.city_action("start_job",{"job":"courier_lantern"},source).ok
		and JSON.stringify(unfunded.state)==unfunded_before,
		"unfunded payroll cannot reserve or remove courier cargo")
	_check(sim.city_action("start_job",{"job":"courier_lantern"},source).ok,
		"courier accepts finite depot cargo at the real workplace")
	var active: Dictionary=sim.city_view().active_job
	_check(active.kind=="courier" and active.carry_mode=="sealed_job_cargo"
		and active.cargo.meal==2 and _city_stock(sim,"courier_depot","meal")==depot_before-2
		and _combined_goods(sim,"meal")==total_before,"courier crate is visible, finite and conserved in transit")
	baseline=JSON.stringify(sim.state)
	_check(not sim.city_action("start_job",{"job":"courier_rail"},source).ok
		and JSON.stringify(sim.state)==baseline,"one resident cannot duplicate active job cargo")
	_check(not sim.city_action("finish_job",{},destination).ok
		and JSON.stringify(sim.state)==baseline,"arrival cannot skip authoritative job time")
	sim.state.time=float(active.ready_at)
	baseline=JSON.stringify(sim.state)
	_check(not sim.city_action("finish_job",{},source).ok and JSON.stringify(sim.state)==baseline,
		"elapsed courier cannot finish away from its destination")
	var wallet: int=sim.balance("player")
	_check(sim.city_action("finish_job",{},destination).ok,"courier finishes at the canonical delivery door")
	_check(sim.balance("player")==wallet+72 and sim.total_money()==money_before
		and _city_stock(sim,"courier_delivery_lantern","meal")==2
		and _combined_goods(sim,"meal")==total_before,"courier transfers cargo and funded wage without minting")
	_check(sim.city_view().active_job.is_empty(),"completed courier job cannot replay")


func _maintenance_job_checks() -> void:
	var sim=_world()
	var source: Vector3=Plan.service("maintenance_depot").position
	var destination: Vector3=Plan.service("maintenance_site_lantern").position
	var total_before:=_combined_goods(sim,"spare_parts")
	var consumed_before:=int(sim.state.resource_ledger.consumed.get("spare_parts",0))
	var money_before: int=sim.total_money()
	_check(sim.city_action("start_job",{"job":"maintenance_lantern"},source).ok
		and sim.stock("player_earth","spare_parts")==2
		and _combined_goods(sim,"spare_parts")==total_before,
		"maintenance takes one actual backpack spare into its job crate")
	var active: Dictionary=sim.city_view().active_job
	sim.state.time=float(active.ready_at)
	var condition:=float(sim.state.city.districts[int(Plan.service("maintenance_site_lantern").district)].service_condition)
	_check(sim.city_action("finish_job",{},destination).ok,"maintenance requires its site and elapsed work time")
	_check(_combined_goods(sim,"spare_parts")==total_before-1
		and int(sim.state.resource_ledger.consumed.spare_parts)==consumed_before+1,
		"finished repair consumes exactly one real spare part")
	_check(float(sim.state.city.districts[int(Plan.service("maintenance_site_lantern").district)].service_condition)>condition
		and sim.total_money()==money_before,"maintenance measurably restores district service and conserves credits")


func _produce_job_checks() -> void:
	var sim=_world()
	var source: Vector3=Plan.service("produce_exchange").position
	var destination: Vector3=Plan.service("produce_market").position
	var total_before:=_combined_goods(sim,"banana")
	var money_before: int=sim.total_money()
	var market_before:=_city_stock(sim,"produce_market","banana")
	var initial_time:=float(sim.state.time)
	_check(sim.city_action("start_job",{"job":"produce_provisioning"},source).ok
		and sim.stock("player_earth","banana")==4,"produce provisioning loads four kilograms from real harvest stock")
	var active: Dictionary=sim.city_view().active_job
	_check(active.cargo=={"banana":4} and _combined_goods(sim,"banana")==total_before,
		"produce remains conserved while visibly carried")
	sim.state.time=float(active.ready_at)
	var consumed_intervals:=floori(float(active.ready_at)/EconomyScript.AGGREGATE_INTERVAL)-floori(initial_time/EconomyScript.AGGREGATE_INTERVAL)
	_check(sim.city_action("finish_job",{},destination).ok
		and _city_stock(sim,"produce_market","banana")==market_before+4-consumed_intervals
		and _combined_goods(sim,"banana")==total_before-consumed_intervals and sim.total_money()==money_before,
		"Garden Row receives the exact crop, accounts for scheduled resident consumption and pays funded credits")
	var empty=_world()
	for crop in EconomyScript.CROP_ITEMS: empty.state.inventories.player_earth.erase(crop)
	var baseline:=JSON.stringify(empty.state)
	_check(not empty.city_action("start_job",{"job":"produce_provisioning"},source).ok
		and JSON.stringify(empty.state)==baseline,"produce job cannot create missing player crops")


func _restock_job_checks() -> void:
	var sim=_world()
	var depot: Vector3=Plan.service("courier_depot").position
	var row: Dictionary=_job_row(sim.city_view(),"restock_depot_meals")
	_check(not row.available and str(row.availability).contains("Bring"),
		"depot restock advertises its missing real backpack supplies")
	_check(sim.action("buy",{"market":"earth_market","item":"meal","quantity":4}).ok,
		"restock fixture obtains finite meals from the existing market")
	row=_job_row(sim.city_view(),"restock_depot_meals")
	_check(row.available,"depot restock becomes available when bag and payroll are funded")
	var combined:=_combined_goods(sim,"meal")
	var depot_before:=_city_stock(sim,"courier_depot","meal")
	var money: int=sim.total_money()
	_check(sim.city_action("start_job",{"job":"restock_depot_meals"},depot).ok
		and sim.stock("player_earth","meal")==0,"restock seals four player meals into one job crate")
	var active: Dictionary=sim.city_view().active_job
	sim.state.time=float(active.ready_at)
	_check(sim.city_action("finish_job",{},depot).ok
		and _city_stock(sim,"courier_depot","meal")==depot_before+4,
		"timed restock replenishes the finite courier depot")
	_check(_combined_goods(sim,"meal")==combined and sim.total_money()==money,
		"renewable depot loop conserves goods and pays only funded credits")


func _society_persistence_and_privacy_checks() -> void:
	var societies=SocietiesScript.new()
	societies.new_game(2026)
	var identity_a:="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	var identity_b:="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	_check(societies.ensure_player(identity_a,"Ada").ok and societies.ensure_player(identity_b,"Bo").ok,
		"authenticated residents receive one funded shared wallet each")
	_check(societies.simulations.values().all(func(sim): return not sim.state.has("city")),
		"online authority owns one city model rather than three duplicated censuses")
	var building_a:="crownreach-b01-01-l01"
	var building_b:="crownreach-b01-01-l02"
	var door_a: Vector3=Plan.building(building_a).door
	var door_b: Vector3=Plan.building(building_b).door
	var money:=societies.total_money()
	_check(societies.city_action(identity_a,"buy_home",{"building":building_a},door_a).ok
		and societies.city_action(identity_b,"buy_home",{"building":building_b},door_b).ok,
		"different residents can buy ordinary city housing")
	_check(societies.total_money()==money,"online property sales conserve the shared money supply")
	var preserved:=JSON.stringify(societies.export_state())
	_check(not societies.city_action(identity_b,"buy_home",{"building":building_a},door_a).ok
		and JSON.stringify(societies.export_state())==preserved,"another resident cannot steal or repay an owned building")
	var view_a: Dictionary=societies.city_view(identity_a)
	var view_b: Dictionary=societies.city_view(identity_b)
	_check(view_a.owned_buildings==[building_a] and view_b.owned_buildings==[building_b]
		and building_a in view_b.unavailable_buildings,"each view exposes its own property plus anonymous unavailable IDs")
	_check(not JSON.stringify(view_b).contains("member_"+identity_a),
		"public city view never discloses another resident identity")
	_check(view_a.credits==200 and view_a.backpack_counts.banana==8,
		"online city view reads only the requesting wallet and Earth bag")
	_check(societies.city_action(identity_a,"store_item",{"building":building_a,"item":"banana","quantity":3},door_a).ok
		and societies.city_view(identity_a,building_a).owned_properties[0].storage.banana==3
		and not JSON.stringify(societies.city_view(identity_b)).contains("\"banana\":3"),
		"private home storage moves real shared bag stock without leaking to visitors")
	var exported: Dictionary=societies.export_state()
	var restored=SocietiesScript.new()
	restored.new_game(99)
	_check(restored.import_state(exported) and restored.city_view(identity_a).owned_buildings==[building_a]
		and restored.city_view(identity_a,building_a).owned_properties[0].storage.banana==3,
		"online city properties and private storage survive authority restart")
	var invalid: Dictionary=exported.duplicate(true)
	invalid.city.properties[building_a].owner="member_"+"f".repeat(64)
	preserved=JSON.stringify(restored.export_state())
	_check(not restored.import_state(invalid) and JSON.stringify(restored.export_state())==preserved,
		"city owner absent from player registry rejects atomically")
	invalid=exported.duplicate(true)
	invalid.city.properties[building_a].storage={"banana":"three"}
	_check(not restored.import_state(invalid) and JSON.stringify(restored.export_state())==preserved,
		"malformed nested city inventory cannot corrupt current authority")
	var legacy: Dictionary=exported.duplicate(true)
	legacy.erase("city")
	var migrated=SocietiesScript.new()
	migrated.new_game(1)
	_check(migrated.import_state(legacy) and migrated.city_view(identity_a).owned_properties.is_empty()
		and migrated.state.city.population==100000,"older shared save migrates one empty Crownreach state")
	var intervals:=int(restored.state.city.metrics.aggregate_intervals)
	for _i in range(60): restored.tick(1.0)
	_check(int(restored.state.city.metrics.aggregate_intervals)==intervals+1,
		"online city aggregate advances once per minute, not once per town simulation")
	# Re-importing a different valid register must invalidate any cached model.
	_check(restored.import_state(legacy) and restored.city_view(identity_a).owned_properties.is_empty(),
		"city accessors resynchronize after full authority state replacement")


func _world():
	var sim=SimScript.new()
	sim.new_game(2026)
	for worker: Dictionary in sim.state.citizens.values(): worker.enabled=false
	return sim


func _city_stock(sim,item_location: String,item: String) -> int:
	return int(sim.state.city.service_inventories[item_location].get(item,0))


func _combined_goods(sim,item: String) -> int:
	var economy=EconomyScript.new()
	assert(economy.import_state(sim.state.city))
	return sim.total_goods(item)+economy.total_goods(item)


func _array_vec3(value: Array) -> Vector3:
	return Vector3(float(value[0]),float(value[1]),float(value[2])) if value.size()==3 else Vector3.INF


func _job_row(view: Dictionary,id: String) -> Dictionary:
	for row: Dictionary in view.job_catalog:
		if row.id==id: return row
	return {}


func _all_items() -> Array:
	var result: Array=[]
	result.append_array(EconomyScript.BASE_ITEMS)
	result.append_array(EconomyScript.CROP_ITEMS)
	result.append_array(EconomyScript.PLANTING_ITEMS)
	return result


func _write_json(path: String,data: Dictionary) -> void:
	var file:=FileAccess.open(path,FileAccess.WRITE)
	assert(file!=null)
	file.store_string(JSON.stringify(data))
	file.close()
