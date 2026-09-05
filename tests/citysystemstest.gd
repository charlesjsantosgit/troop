extends Node
const Plan = preload("res://scripts/city_plan.gd")
const Infrastructure = preload("res://scripts/city_infrastructure.gd")
const Economy = preload("res://scripts/city_economy.gd")
const Sim = preload("res://scripts/frontier_sim.gd")
var checks := 0
var passed := 0
func check(value: bool, label: String) -> void:
	checks += 1
	if value: passed += 1
	else: push_error("CITYSYSTEMS FAIL " + label)
func run() -> void:
	for row in [["day",12.0],["night",22.0],["21:30",21.5],["00:00",0.0],["12.75",12.75],["25",1.0],["dawn",6.0],["25:00",-1.0],["12:90",-1.0],["night extra",-1.0],["nan",-1.0],["",-1.0]]:
		check(is_equal_approx(AdminController.parse_time_value(row[0]),row[1]),"time syntax "+str(row[0]))
	var economy := Economy.new()
	economy.new_game()
	var snapshot: Dictionary = economy.state.duplicate(true)
	for row in snapshot.districts: row.erase("infrastructure")
	check(economy.import_state(snapshot),"old property saves migrate without changing owners or stocks")
	check(economy.state.districts.all(func(d): return Infrastructure.valid(d.infrastructure)),"all twelve migrated infrastructure rows valid")
	var district: Dictionary = economy.state.districts[0]
	var initial: Dictionary = district.infrastructure.duplicate(true)
	Infrastructure.advance(district, 20)
	check(Infrastructure.valid(district.infrastructure),"running services remain bounded")
	check(district.infrastructure.power_ratio > 0.99 and district.infrastructure.water_ratio > 0.99,"funded district supplies water and energy")
	check(district.infrastructure.operating_spend > 0 and district.infrastructure.tax_received > 0,"actual operating costs and fiscal receipts accrue")
	check(absf(float(district.infrastructure.budget) - (float(initial.budget) + float(district.infrastructure.tax_received) - float(district.infrastructure.operating_spend))) < 0.001,"municipal budget balances")
	check(district.infrastructure.recycled > 0 and district.infrastructure.disposed > 0 and district.infrastructure.waste_backlog < 1,"collection separates recovery and residual disposal")
	district.infrastructure.power_health = 0.0
	district.infrastructure.water_reserve = 0.0
	Infrastructure.advance(district, 1)
	check(district.infrastructure.power_ratio < 0.01 and district.infrastructure.water_ratio < 0.01,"grid failure stops water pumps")
	check(district.infrastructure.clinic_ratio < 0.01 and Infrastructure.productive_fraction(district) < 0.01,"outage affects clinics and productive work")
	Infrastructure.repair(district,"maintenance_site_lantern")
	Infrastructure.advance(district, 1)
	check(district.infrastructure.power_ratio > 0.3 and district.infrastructure.water_ratio > 0.3,"repair restores useful supply")
	district.infrastructure.roads_health = 0.2
	Infrastructure.repair(district,"maintenance_site_north","maintenance_roads")
	check(is_equal_approx(district.infrastructure.roads_health,0.48),"street job repairs road capacity")
	district.infrastructure.sanitation_health = 0.2
	Infrastructure.repair(district,"maintenance_site_east","maintenance_sanitation")
	check(district.infrastructure.sanitation_health >= 0.48,"collection job repairs sanitation capacity")
	var malformed: Dictionary = economy.state.duplicate(true)
	malformed.districts[0].infrastructure.power_ratio = NAN
	check(not economy.import_state(malformed),"nonfinite imported service data rejected")
	var sim := Sim.new()
	sim.new_game(2026)
	var model: RefCounted = sim._city()
	var destination := Plan.service("maintenance_site_east")
	var before_parts: int = sim.stock("player_earth","spare_parts")
	var action: Dictionary = sim.city_action("start_job",{"job":"maintenance_sanitation"}, Plan.service("maintenance_depot").position)
	check(action.ok,"collection repair is an actual accessible city job")
	if action.ok:
		var before_health := float(model.state.districts[int(destination.district)].infrastructure.sanitation_health)
		model.state.districts[int(destination.district)].infrastructure.sanitation_health = 0.2
		for tick in range(66): sim.tick(1.0)
		var result: Dictionary = sim.city_action("finish_job",{},destination.position)
		check(result.ok and model.state.districts[int(destination.district)].infrastructure.sanitation_health > 0.48,"completing physical job restores infrastructure")
		check(sim.stock("player_earth","spare_parts") == before_parts-1,"repair consumes an actual spare part")
		check(sim.validate_state(sim.state),"repair preserves full society conservation invariants")
	var low := 0
	var mid := 0
	var tall := 0
	for y in range(Plan.GRID_DEPTH):
		for x in range(Plan.GRID_WIDTH):
			for building in Plan.block_buildings(Vector2i(x,y)):
				if building.size.y < 36: low += 1
				elif building.size.y < 100: mid += 1
				else: tall += 1
	check(low > 24000 and mid > 2000 and tall < 1000,"neighborhood buildings dominate and towers remain exceptional")
	print("CITYSYSTEMS_DISTRIBUTION low=%d mid=%d high=%d"%[low,mid,tall])
	print("CITYSYSTEMSTEST %d/%d PASS"%[passed,checks])
	get_tree().quit(0 if passed==checks else 1)
