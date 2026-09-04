extends Node
## Deterministic real-resource, market, autonomy and crash-safe persistence gates.
const SimScript = preload("res://scripts/frontier_sim.gd")
var passed := 0
var checks := 0

func _check(value: bool, label: String) -> void:
	checks+=1
	if value: passed+=1
	else: push_error("FRONTIERTEST FAIL: "+label)

func _world():
	var sim = SimScript.new()
	sim.new_game(2026)
	return sim

func _freeze(sim) -> void:
	for id in sim.state.citizens:
		sim.state.citizens[id].enabled=false

func _advance(sim, seconds: int) -> void:
	for _i in range(seconds): sim.tick(1.0)

func _worker_completion_budget(worker: Dictionary) -> int:
	var cursor := Vector2(float(worker.position[0]),float(worker.position[1]))
	var distance := 0.0
	for waypoint in worker.get("route",[]):
		var next := Vector2(float(waypoint[0]),float(waypoint[1]))
		distance+=cursor.distance_to(next)
		cursor=next
	# Each route point gets one arrival/pop tick and one bounded passing tick.
	# Work time is authoritative model state, so this deadline scales with the
	# actual route and task instead of assuming the former walking speed.
	return ceili(distance/float(SimScript.WALK_SPEED) \
		+float(worker.get("work_remaining",0.0))+float(worker.get("route",[]).size()*2)+2.0)

func _advance_until_reserve_changes(sim, reserve: int, deadline: int) -> int:
	for elapsed in range(1,deadline+1):
		sim.tick(1.0)
		if int(sim.state.facilities.oil_rig.reserve)<reserve:
			return elapsed
	return -1

func run(_main = null) -> void:
	run_checks()
	print("FRONTIERTEST result=%d/%d %s"%[passed,checks,"PASS" if passed==checks else "FAIL"])
	get_tree().quit(0 if passed==checks else 1)

func run_checks() -> bool:
	var sim = _world()
	_check(sim.crop_catalog().size()==24,"24 usable crop definitions")
	_check(sim.job_catalog().size()==19,"19 practical job roles")
	_check(sim.recipe_catalog().size()==11,"11 input-backed processing recipes")
	_check(sim.state.citizens.size()==24,"persistent citizens")
	_check(sim.validate_state(sim.state),"new game state validates")
	var initial_money: int = sim.total_money()
	var banana_before: int = sim.total_goods("banana")
	var player_before: int = sim.state.accounts.player
	_check(sim.action("buy",{"item":"banana","quantity":2}).ok,"buy actual stock")
	_check(sim.total_goods("banana")==banana_before and sim.total_money()==initial_money,"trade conserves goods and cash")
	_check(int(sim.state.accounts.player)<player_before and sim.stock("player_earth","banana")==10,"buyer pays and receives")
	var before: String = JSON.stringify(sim.state)
	_check(not sim.action("buy",{"item":"banana","quantity":1.5}).ok,"fractional quantity rejected")
	_check(JSON.stringify(sim.state)==before,"failed quantity leaves entire state unchanged")
	_check(not sim.action("buy",{"item":"banana","quantity":-4}).ok,"negative trade rejected")
	_check(not sim.action("buy",{"item":"banana","quantity":1001}).ok,"unbounded order rejected")
	_check(not sim.action("buy",{"market":"moon_market","item":"water","quantity":1}).ok,"remote inventory cannot teleport")
	var cheap: int = sim.quote("earth_market","banana",1,false)
	sim.state.inventories.earth_market.banana=100
	_check(sim.quote("earth_market","banana",1,false)<cheap,"surplus lowers next bid")
	_check(sim.quote("earth_market","banana",100,false)<=sim.quote("earth_market","banana",1,false)*100,"bulk sale consumes market depth")
	sim = _world()
	sim.state.accounts.earth_market=0
	sim.state.accounts.treasury+=30000
	before=JSON.stringify(sim.state)
	_check(not sim.action("sell",{"item":"banana","quantity":1}).ok and JSON.stringify(sim.state)==before,"unfunded buyer rejects atomically")
	sim.state.inventories.player_earth.water=350
	before=JSON.stringify(sim.state)
	_check(not sim.action("buy",{"item":"banana","quantity":1}).ok and JSON.stringify(sim.state)==before,"full storage rejects without charge")

	sim=_world()
	_freeze(sim)
	var seed_count: int = sim.stock("player_earth","lettuce_seed")
	_check(sim.action("plant",{"plot":"earth_4","crop":"lettuce"}).ok,"plant empty owned bed")
	_check(sim.stock("player_earth","lettuce_seed")==seed_count-1,"plant consumes correct planting stock")
	before=JSON.stringify(sim.state)
	_check(not sim.action("plant",{"plot":"earth_4","crop":"lettuce"}).ok and JSON.stringify(sim.state)==before,"double planting rejects atomically")
	_check(not sim.action("harvest",{"plot":"coop_1"}).ok,"cannot harvest another owner's crop")
	_check(not sim.action("harvest",{"plot":"earth_4"}).ok,"cannot harvest immature crop")
	_advance(sim,140)
	_check(float(sim.state.plots.earth_4.growth)>=1.0,"well supplied crop matures")
	var harvest_stock: int = sim.stock("player_earth","lettuce")
	_check(sim.action("harvest",{"plot":"earth_4"}).ok and sim.stock("player_earth","lettuce")>harvest_stock,"harvest produces finite food")
	before=JSON.stringify(sim.state)
	_check(not sim.action("harvest",{"plot":"earth_4"}).ok and JSON.stringify(sim.state)==before,"harvest cannot replay")
	sim.state.plots.earth_4.moisture=0.0
	sim.action("plant",{"plot":"earth_4","crop":"lettuce"})
	var growth: float = sim.state.plots.earth_4.growth
	_advance(sim,10)
	_check(float(sim.state.plots.earth_4.growth)==growth,"dry soil blocks growth")
	var water_before: int = sim.stock("player_earth","water")
	_check(sim.action("water",{"plot":"earth_4"}).ok and sim.stock("player_earth","water")==water_before-5,"watering consumes measured water")
	_advance(sim,10)
	_check(float(sim.state.plots.earth_4.growth)>growth,"water restores growth")
	sim.state.plots.earth_4.nutrients=0.0
	growth=sim.state.plots.earth_4.growth
	_advance(sim,5)
	_check(float(sim.state.plots.earth_4.growth)==growth,"missing nutrients block growth")
	_check(sim.action("fertilize",{"plot":"earth_4"}).ok,"fertilization consumes fertilizer")
	_advance(sim,5)
	_check(float(sim.state.plots.earth_4.growth)>growth,"fertilizer restores growth")

	sim=_world()
	_freeze(sim)
	sim.action("travel",{"planet":"moon"})
	sim.state.facilities.solar_array.panels=0
	sim.state.facilities.lunar_greenhouse.battery_kwh=0.0
	growth=sim.state.plots.moon_1.growth
	_advance(sim,5)
	_check(not sim.state.facilities.lunar_greenhouse.powered and float(sim.state.plots.moon_1.growth)==growth,"Moon crops stop without solar or battery")
	var credits: int = sim.state.accounts.player
	_check(sim.action("build_solar").ok,"player installs real solar kit")
	_check(sim.stock("player_moon","solar_kit")==0 and int(sim.state.accounts.player)==credits-150,"solar consumes equipment and pays installers")
	sim.state.facilities.lunar_greenhouse.battery_kwh=30.0
	_advance(sim,5)
	_check(sim.state.facilities.lunar_greenhouse.powered and float(sim.state.plots.moon_1.growth)>growth,"solar plus battery restore lunar crop growth")
	sim.state.facilities.lunar_greenhouse.pump_condition=0.0
	var parts: int = sim.stock("player_moon","spare_parts")
	_check(sim.action("repair",{"facility":"lunar_greenhouse"}).ok and float(sim.state.facilities.lunar_greenhouse.pump_condition)==1.0 and sim.stock("player_moon","spare_parts")==parts-1,"repair consumes compatible spare and restores pump")
	sim.state.time=3600.0
	_advance(sim,1)
	_check(float(sim.state.facilities.solar_array.power_kw)==0.0,"panels cannot generate during lunar darkness")

	sim=_world()
	_freeze(sim)
	var goods: int = sim.total_goods("banana")
	var packaging: int = sim.total_goods("packaging")
	var arrival_stock: int = sim.stock("player_moon","banana")
	_check(sim.action("ship",{"item":"banana","quantity":5}).ok,"freight accepts finite owned cargo")
	_check(sim.stock("player_earth","banana")==3 and sim.stock("player_moon","banana")==arrival_stock and sim.state.shipments.size()==1,"cargo occupies transit until ETA")
	_check(sim.total_goods("banana")==goods and sim.total_goods("packaging")==packaging,"in-transit cargo and packaging remain in ledger")
	_advance(sim,89)
	_check(sim.stock("player_moon","banana")==arrival_stock,"cannot receive before arrival")
	_advance(sim,1)
	_check(sim.state.shipments.is_empty() and sim.stock("player_moon","banana")==arrival_stock+5,"cargo arrives once at destination")
	_advance(sim,3)
	_check(sim.stock("player_moon","banana")==arrival_stock+5,"arrival cannot replay")
	_check(sim.total_money()==int(sim.state.initial_money),"carrier fee conserves money")

	sim=_world()
	_freeze(sim)
	var starting_cash: int = sim.state.accounts.player
	_check(sim.action("accept_quest",{"id":"first_harvest"}).ok,"contract reserves funded escrow")
	_check(sim.state.accounts.escrow_first_harvest==120 and sim.state.accounts.player==starting_cash,"accepting quest alone grants no credits")
	_check(sim.action("deliver_quest",{"id":"first_harvest"}).ok,"actual cargo completes contract")
	_check(sim.stock("player_earth","banana")==0 and sim.state.accounts.player==starting_cash+120 and sim.state.accounts.escrow_first_harvest==0,"quest transfers goods then pays escrow")
	before=JSON.stringify(sim.state)
	_check(not sim.action("deliver_quest",{"id":"first_harvest"}).ok and JSON.stringify(sim.state)==before,"quest cannot replay payout")
	sim.action("accept_quest",{"id":"repair_stock"})
	_check(not sim.action("deliver_quest",{"id":"repair_stock"}).ok,"contract delivery requires correct realm")
	_check(sim.action("cancel_quest",{"id":"repair_stock"}).ok and sim.state.accounts.escrow_repair_stock==0,"cancel refunds escrow")
	_check(sim.total_money()==int(sim.state.initial_money),"contracts preserve finite money")

	sim=_world()
	_freeze(sim)
	sim.state.inventories.player_earth.crude_oil=10
	_check(sim.action("process",{"recipe":"refine"}).ok,"refining starts with real crude and water")
	_check(sim.stock("player_earth","crude_oil")==0 and sim.stock("player_earth","jet_fuel")==0,"refining consumes input before timed output")
	_advance(sim,12)
	_check(sim.stock("player_earth","gasoline")==4 and sim.stock("player_earth","diesel")==3 and sim.stock("player_earth","jet_fuel")==2 and sim.stock("player_earth","bitumen")==1,"distillation produces proper distinct fuel fractions")
	before=JSON.stringify(sim.state)
	_check(not sim.action("process",{"recipe":"refine"}).ok and JSON.stringify(sim.state)==before,"refining cannot create fuel without crude")

	sim=_world()
	_freeze(sim)
	sim.state.citizens.derrick.enabled=true
	sim.state.citizens.derrick.position=[0,4]
	var reserve: int = sim.state.facilities.oil_rig.reserve
	_advance(sim,5)
	_check(int(sim.state.facilities.oil_rig.reserve)==reserve,"distant rigger cannot produce before arrival")
	var extraction_target := Vector2(float(sim.state.citizens.derrick.destination[0]),float(sim.state.citizens.derrick.destination[1]))
	var extraction_budget := _worker_completion_budget(sim.state.citizens.derrick)
	var extraction_seconds := _advance_until_reserve_changes(sim,reserve,extraction_budget)
	var extraction_position := Vector2(float(sim.state.citizens.derrick.position[0]),float(sim.state.citizens.derrick.position[1]))
	_check(extraction_seconds>0 and extraction_seconds<=extraction_budget \
		and extraction_position.distance_to(extraction_target)<=0.1 \
		and sim._pedestrian_segment_clear(sim.state.citizens.derrick,extraction_position,extraction_position) \
		and int(sim.state.metrics.crude_extracted)>0,"rigger reaches its clear work position then extracts within route and work budget")
	sim.state.inventories.oil_rig.diesel=0
	sim.state.citizens.derrick._job={}
	sim.state.citizens.derrick.cooldown=0.0
	reserve=sim.state.facilities.oil_rig.reserve
	_advance(sim,20)
	_check(int(sim.state.facilities.oil_rig.reserve)==reserve and str(sim.state.citizens.derrick.blocker).contains("diesel"),"missing machinery fuel creates concrete blocker")
	sim=_world()
	_advance(sim,1600)
	_check(int(sim.state.metrics.harvested)>30,"autonomous farming repeatedly harvests actual crops")
	_check(int(sim.state.metrics.crude_extracted)>100 and int(sim.state.metrics.crude_refined)>50,"autonomous oil production and refinement")
	_check(int(sim.state.metrics.fuel_delivered)>12 and int(sim.state.metrics.deliveries)>10,"workers physically deliver fuels and food")
	_check(int(sim.state.metrics.food_consumed)>0,"citizens buy and eat finite meals")
	_check(int(sim.state.citizens.mango.completed)>0 and int(sim.state.accounts.mango)>0,"productive workers gain skills and finite wages")
	_check(sim.total_money()==int(sim.state.initial_money),"1600-second economy conserves all credits")
	_check(sim.validate_state(sim.state),"long-running state remains valid")
	print("FRONTIERTEST autonomous_metrics="+JSON.stringify(sim.summary()))
	# Reconcile every good against production/consumption, including held cargo.
	var causal = _world()
	var baseline := {}
	for item in causal.item_catalog(): baseline[item]=causal.total_goods(item)
	_advance(causal,900)
	var reconciled := true
	for item in baseline:
		var expected: int = int(baseline[item])+int(causal.state.resource_ledger.produced.get(item,0))-int(causal.state.resource_ledger.consumed.get(item,0))
		if causal.total_goods(item)!=expected:
			reconciled=false
			print("FRONTIERTEST ledger mismatch ",item," expected=",expected," actual=",causal.total_goods(item))
	_check(reconciled,"900-second entire commodity ledger reconciles")
	# Save with both in-transit freight and active worker jobs; resumed results
	# must equal uninterrupted state, with no free startup grants.
	var save_path := "user://frontiertest-isolated.json"
	causal.action("ship",{"item":"water","quantity":5})
	_check(causal.save_game(save_path),"atomic save accepts live state and cargo")
	var loaded = _world()
	_check(loaded.load_game(save_path),"load validates and restores checkpoint")
	_check(_equivalent(loaded.state,causal.state),"roundtrip preserves complete state")
	_advance(causal,120)
	_advance(loaded,120)
	_check(_equivalent(loaded.state,causal.state),"reload resumes deterministically without duplicated delivery")
	_check(loaded.save_game(save_path) and FileAccess.file_exists(save_path+".bak"),"second checkpoint preserves valid backup")
	var corrupt: Dictionary = loaded.state.duplicate(true)
	corrupt.accounts.player=-1
	var file := FileAccess.open(save_path,FileAccess.WRITE)
	file.store_string(JSON.stringify(corrupt))
	file.close()
	before=JSON.stringify(loaded.state)
	_check(not loaded.load_game(save_path) and JSON.stringify(loaded.state)==before,"corrupt save rejected transactionally")
	corrupt=loaded.state.duplicate(true)
	corrupt.citizens.derrick._job={"op":"harvest","target":"cooperative","label":"bad","payload":{"plot":"absent","source":"cooperative"}}
	_check(not loaded.validate_state(corrupt),"invalid saved task references rejected")
	corrupt=loaded.state.duplicate(true)
	corrupt.locations.player_moon.capacity=1
	_check(not loaded.validate_state(corrupt),"over-capacity save rejected")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path+".bak"))
	sim=_world()
	var first: Dictionary = sim.action("buy",{"item":"banana","quantity":1,"request_id":"one"})
	before=JSON.stringify(sim.state)
	_check(sim.action("buy",{"item":"banana","quantity":1,"request_id":"one"})==first and JSON.stringify(sim.state)==before,"retry id replays result without settlement duplication")
	_advance(sim,1)
	var start_time: float = sim.state.time
	sim.tick(100000.0)
	_check(float(sim.state.time)-start_time<=8.0,"large frame catch-up remains bounded")
	sim=_world()
	var tank: Dictionary = sim.register_vehicle("fixture-jeep",1)
	_check(float(tank.capacity_l)==65.0 and float(tank.fuel_l)==32.5,"stable vehicle receives finite starter tank")
	_check(sim.consume_vehicle_fuel("fixture-jeep",2.5)==2.5 and float(tank.fuel_l)==30.0,"engine consumes exact fractional fuel")
	sim.register_vehicle("fixture-jeep",1)
	_check(float(tank.fuel_l)==30.0,"registering same vehicle cannot refill it")
	var fuel_before: int = sim.stock("gas_station","gasoline")
	var money_before: int = sim.total_money()
	_check(sim.action("refuel",{"vehicle":"fixture-jeep","facility":"gas_station","quantity":5}).ok,"vehicle buys real station fuel")
	_check(sim.stock("gas_station","gasoline")==fuel_before-5 and float(tank.fuel_l)==35.0 and sim.total_money()==money_before,"refueling transfers actual stock and conserves money")
	before=JSON.stringify(sim.state)
	_check(not sim.action("refuel",{"vehicle":"fixture-jeep","facility":"gas_station","quantity":50}).ok and JSON.stringify(sim.state)==before,"overfilled tank rejects transaction atomically")
	_check(sim.consume_vehicle_fuel("fixture-jeep",9999.0)==35.0 and float(tank.fuel_l)==0.0,"empty tank cannot consume nonexistent fuel")
	_check(sim.validate_state(sim.state),"vehicle tank state validates")
	sim.action("travel",{"planet":"moon"})
	sim.state.inventories.player_moon.battery_kit=1
	var battery_before: float = sim.state.facilities.lunar_greenhouse.battery_kwh
	_check(sim.action("upgrade_battery").ok and float(sim.state.facilities.lunar_greenhouse.battery_capacity_kwh)==200.0,"battery kit expands capacity")
	_check(float(sim.state.facilities.lunar_greenhouse.battery_kwh)==battery_before and sim.stock("player_moon","battery_kit")==0,"battery expansion does not create stored energy")
	var night = _world()
	var saw_dark := false
	var lost_power := false
	var recovered := false
	for _i in range(5200):
		night.tick(1.0)
		saw_dark=saw_dark or float(night.state.solar_illumination)==0.0
		lost_power=lost_power or not night.state.facilities.lunar_greenhouse.powered
		if lost_power and float(night.state.solar_illumination)>0.5 and night.state.facilities.lunar_greenhouse.powered: recovered=true
	_check(saw_dark and lost_power and recovered,"full lunar night drains undersized battery and sunrise restores power")
	_check(night.validate_state(night.state) and night.total_money()==int(night.state.initial_money),"5200-second day/night economy stays valid and conserves credits")
	sim=_world()
	_freeze(sim)
	var blocked_worker: Dictionary = sim.state.citizens.derrick
	blocked_worker.enabled=true
	blocked_worker.position=[0,4]
	blocked_worker.route_blocked="Road blocked by construction"
	_advance(sim,1)
	var blocked_position: Array = blocked_worker.position.duplicate()
	var neighbor: Dictionary = sim.state.citizens.momo
	var starts_clear := Vector2(float(blocked_position[0]),float(blocked_position[1])).distance_to( \
		Vector2(float(neighbor.position[0]),float(neighbor.position[1])))>=float(SimScript.PEDESTRIAN_SPACING)-0.001
	var remaining_before: float = blocked_worker.work_remaining
	var reserve_before: int = sim.state.facilities.oil_rig.reserve
	var recovery_target := Vector2(float(blocked_worker.destination[0]),float(blocked_worker.destination[1]))
	_advance(sim,10)
	_check(starts_clear and blocked_worker.position==blocked_position and float(blocked_worker.work_remaining)==remaining_before and int(sim.state.facilities.oil_rig.reserve)==reserve_before,"physical obstruction stops a safely separated worker and task commits without losing cargo")
	blocked_worker.route_blocked=""
	var recovery_budget := _worker_completion_budget(blocked_worker)
	var recovery_seconds := _advance_until_reserve_changes(sim,reserve_before,recovery_budget)
	var recovery_position := Vector2(float(blocked_worker.position[0]),float(blocked_worker.position[1]))
	_check(recovery_seconds>0 and recovery_seconds<=recovery_budget \
		and recovery_position.distance_to(recovery_target)<=0.1 \
		and sim._pedestrian_segment_clear(blocked_worker,recovery_position,recovery_position),"clearing route resumes arrival and actual production from a clear work position within budget")
	var electrical = _world()
	electrical.state.facilities.solar_array.panels=12
	var electrical_room: Dictionary = electrical.state.facilities.lunar_greenhouse
	electrical_room.battery_capacity_kwh=800.0
	electrical_room.battery_kwh=600.0
	for id in electrical.state.plots:
		if electrical.state.plots[id].planet=="moon": electrical.state.plots[id].crop="lettuce"
	var uninterrupted := true
	var charged := false
	var within_capacity := true
	var lowest_charge := 800.0
	var charging_hours := 0
	for _i in range(4800):
		var prior_charge: float = electrical_room.battery_kwh
		electrical.state.time+=1.0
		electrical._update_habitat(1.0)
		uninterrupted=uninterrupted and bool(electrical_room.powered)
		within_capacity=within_capacity and float(electrical_room.battery_kwh)>=0.0 and float(electrical_room.battery_kwh)<=800.0
		if float(electrical_room.battery_kwh)>prior_charge:
			charged=true
			charging_hours+=1
		lowest_charge=minf(lowest_charge,float(electrical_room.battery_kwh))
	_check(uninterrupted and charged and lowest_charge>0.0 and is_equal_approx(float(electrical_room.demand_kw),12.2),"twelve panels and 800kWh battery sustain all six beds across a full lunar day with normal degradation")
	_check(within_capacity and float(electrical.state.facilities.solar_array.condition)<0.98,"full-cycle solar charging respects battery capacity and panel wear")
	print("FRONTIERTEST full_farm_energy demand_kw=",electrical_room.demand_kw," minimum_kwh=",lowest_charge," final_kwh=",electrical_room.battery_kwh," charging_seconds=",charging_hours," final_panel_condition=",electrical.state.facilities.solar_array.condition)
	return passed==checks

func _equivalent(a: Variant, b: Variant) -> bool:
	if typeof(a) in [TYPE_INT,TYPE_FLOAT] and typeof(b) in [TYPE_INT,TYPE_FLOAT]:
		return absf(float(a)-float(b))<=0.000000001
	if a is Dictionary:
		if not b is Dictionary or a.size()!=b.size(): return false
		for key in a:
			if not b.has(key) or not _equivalent(a[key],b[key]): return false
		return true
	if a is Array:
		if not b is Array or a.size()!=b.size(): return false
		for i in range(a.size()):
			if not _equivalent(a[i],b[i]): return false
		return true
	return a==b
