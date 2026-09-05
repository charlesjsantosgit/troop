extends Node
const Plan = preload("res://scripts/city_plan.gd")
const Economy = preload("res://scripts/city_economy.gd")
const Commerce = preload("res://scripts/city_commerce.gd")
const Fleet = preload("res://scripts/city_vehicle_models.gd")
const Sim = preload("res://scripts/frontier_sim.gd")
var checks:=0
var passed:=0
func check(ok: bool,label: String) -> void:
	checks+=1
	if ok: passed+=1
	else: push_error("CITYLIFE FAIL "+label)
func run() -> void:
	for path in ["city_disasters","city_damage_shell","city_incident_network","vehicle_catalog_panel"]:
		var script=load("res://scripts/"+path+".gd")
		check(script!=null and script.can_instantiate(),"runtime module compiles "+path)
	check(absf(Plan.SQUARE_MILES-30.0)<.2,"city retains approximately thirty square miles")
	check((Plan.BLOCK_EXTENTS-Vector2.ONE*24).is_equal_approx(Vector2(264,900)*.3048),"physical blocks match requested feet at metre scale")
	var total:=0
	var ids: Dictionary={}
	var categories: Dictionary={}
	var clear:=true
	for z in range(Plan.GRID_DEPTH):
		for x in range(Plan.GRID_WIDTH):
			var key:=Vector2i(x,z)
			total+=Plan.block_population(key)
			var rows:=Plan.block_buildings(key)
			if Plan.is_park_block(key): check(rows.is_empty() and Plan.block_population(key)==0,"park contains no buildings/resident allocation "+str(key))
			for b in rows:
				check(not ids.has(b.id),"unique physical address "+str(b.id))
				ids[b.id]=b
				categories[b.retail_type]=true
				var delta: Vector2 = (Vector2(b.position.x,b.position.z)-Plan.block_center(key)).abs()
				clear = clear and delta.x+b.size.x*.5 <= Plan.BLOCK_EXTENTS.x*.5-15 and delta.y+b.size.z*.5 <= Plan.BLOCK_EXTENTS.y*.5-15
	check(clear,"all physical buildings leave sidewalk and street clearance")
	check(total==100000,"exactly 100k residents, no counted residents inside park")
	check(ids.size()==Plan.ESTIMATED_BUILDING_COUNT,"physical renderer count matches canonical plan")
	var old_preserved:=true
	for z in range(48):
		for x in range(48):
			for lot in range(16):
				if Plan._is_reserved_square_lot(Vector2i(x,z),lot): continue
				old_preserved=old_preserved and ids.has("crownreach-b%02d-%02d-l%02d"%[x,z,lot])
	check(old_preserved,"all existing property IDs survive park relocation")
	for category in Commerce.SHOPS: check(categories.has(category),"purchaseable store category "+category)
	check(Plan.dealerships().size()==12,"one physical car dealership per district")
	var park_area:=Plan.PARK_HALF_EXTENTS.x*Plan.PARK_HALF_EXTENTS.y*4
	check(park_area>3000000 and park_area<3500000,"Central Park inspired landscape is over three square kilometres")
	check(absf(Plan.pond_depth(Plan.pond_shore(.6))-(Plan.GROUND_Y-Plan.POND_SURFACE_Y))<.001,"lake shoreline matches exact terrain-water intersection")
	var econ:=Economy.new()
	econ.new_game()
	check(econ._valid_state(econ.state),"new commercial state validates")
	var legacy:=econ.state.duplicate(true)
	legacy.population=400000
	for key in ["owned_vehicles","vehicle_stock","next_vehicle_id","retail_revision"]: legacy.erase(key)
	check(econ.import_state(legacy) and econ.state.population==100000,"old 400k saves migrate census and garage")
	var sim:=Sim.new()
	sim.new_game(2026)
	var dealer:=Plan.dealerships()[0]
	sim._transfer("treasury","player",150000,"test funded purchasing power")
	var money:int=sim.total_money()
	var wallet:int=sim.balance("player")
	var result:Dictionary=sim.city_action("buy_vehicle",{"building":dealer.id,"model":"sedan"},dealer.door)
	check(result.ok,"dealership purchase succeeds with actual credits")
	check(sim.total_money()==money and sim.balance("player")==wallet-int(Fleet.spec(1).price),"purchase conserves money and exact price")
	if result.ok:
		var id:=str(result.vehicle.id)
		check(sim.state.city.owned_vehicles.has(id) and sim.state.city.vehicle_stock.sedan==23,"saved vehicle ownership and finite dealer stock")
		var copy:=Economy.new()
		check(copy.import_state(sim.state.city) and copy.owned_vehicles("player").size()==1,"garage persists through reload")
		check(not copy.action("other", "recall_vehicle",{"building":dealer.id,"vehicle":id},sim,dealer.door,sim.state.time).ok,"another resident cannot collect purchased car")
		check(sim.city_action("recall_vehicle",{"building":dealer.id,"vehicle":id},dealer.door).ok,"owner can collect parked car")
	var before:=var_to_bytes(sim.state)
	check(not sim.city_action("buy_vehicle",{"building":dealer.id,"model":"fake"},dealer.door).ok and var_to_bytes(sim.state)==before,"invalid model cannot charge or mutate save")
	for category in Commerce.SHOPS:
		var fixture:Dictionary={}
		for building in ids.values():
			if building.retail_type==category: fixture=building;break
		var offers:=Commerce.offers(fixture)
		for offer in offers:
			var price_before:int=sim.balance("player")
			var bought:Dictionary=sim.city_action("buy_store_item",{"building":fixture.id,"item":offer.item,"quantity":1},fixture.door)
			check(bought.ok and sim.balance("player")==price_before-int(offer.price),"functional "+category+" sale "+str(offer.item))
	for index in range(Fleet.CATALOG.size()):
		var car=load("res://scripts/city_car.gd").new()
		car.configure_model(index)
		add_child(car)
		check(car.wheels.size()==4 and car.mass>1000 and car.rider_root_offset.is_finite(),"drivable model setup "+str(index))
		car.queue_free()
	await get_tree().process_frame
	print("CITYLIFE result=%d/%d %s"%[passed,checks,"PASS" if checks==passed else "FAIL"])
	get_tree().quit(0 if checks==passed else 1)
