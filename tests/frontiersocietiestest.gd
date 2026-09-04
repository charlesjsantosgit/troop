extends SceneTree
const Domain = preload("res://scripts/frontier_societies.gd")
const Sim = preload("res://scripts/frontier_sim.gd")
var checks := 0
var passed := 0
var alice := "a".repeat(64)
var bob := "b".repeat(64)

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks+=1
	if ok: passed+=1
	print(("[PASS] " if ok else "[FAIL] ")+label)

func _run() -> void:
	var domain=Domain.new()
	domain.new_game(2026)
	check(domain.towns().size()==6 and domain.simulations.size()==3,"three independent societies expose six claimable towns")
	check(domain.total_money()==Domain.STARTING_MONEY,"initial municipal money is finite")
	check(not domain.ensure_player("bad","Nobody").ok and domain.state.players.is_empty(),"unauthenticated identities cannot receive grants")
	check(domain.ensure_player(alice,"Alice").ok and domain.ensure_player(bob,"Bob").ok,"distinct authenticated residents register")
	var a := "member_"+alice
	var b := "member_"+bob
	var before: Dictionary=domain.export_state()
	domain.ensure_player(alice,"Alice")
	check(domain.export_state()==before,"reconnecting cannot reroll credits or supplies")
	check(domain.total_money()==Domain.STARTING_MONEY,"registration grants debit finite town funds")
	check(domain.action(alice,"canopy_earth","claim_town").ok and domain.state.players[a].credits==1050,"claim atomically charges 750 credits")
	before=domain.export_state()
	check(not domain.action(bob,"canopy_earth","claim_town").ok and domain.export_state()==before,"second resident cannot overwrite a paid claim")
	check(not domain.action(alice,"harbor_earth","claim_town").ok,"one resident cannot claim a second town")
	check(domain.action(bob,"canopy_moon","claim_town").ok,"the paired lunar town can have a different owner")
	check(not domain.action(bob,"canopy_earth","toggle_worker",{"citizen":"mango"}).ok,"visitors cannot manage another town's citizens")
	check(not domain.action(alice,"canopy_earth","assign_job",{"citizen":"luna","job":"grower"}).ok,"Earth ownership does not authorize lunar workers")
	check(not domain.action(alice,"canopy_moon","build_solar").ok,"Earth ownership does not authorize lunar utilities")
	var amount := int(domain.state.players[a].credits)
	check(domain.action(alice,"harbor_earth","buy",{"market":"earth_market","item":"water","quantity":2}).ok,"visitors can buy from other towns")
	check(domain.state.players[a].credits<amount and domain.view(alice,"ridge_moon").accounts.player==domain.state.players[a].credits,"all towns use the same resident wallet")
	check(domain.simulations.canopy.state.inventories[a+"_earth"]==domain.simulations.harbor.state.inventories[a+"_earth"],"all town models share the same personal bag")
	before=domain.export_state()
	check(not domain.action(alice,"harbor_earth","buy",{"market":"earth_market","item":"water","quantity":1000}).ok and domain.export_state()==before,"unfunded or oversized trades leave every ledger unchanged")
	check(not domain.action(alice,"canopy_earth","ship",{"from":b+"_earth","item":"water","quantity":1}).ok,"payload cannot select another resident's stock")
	check(domain.action(alice,"canopy_earth","accept_quest",{"id":"first_harvest"}).ok and domain.action(bob,"canopy_earth","accept_quest",{"id":"first_harvest"}).ok,"each resident has separately funded quest progress")
	check(domain.action(alice,"canopy_earth","deliver_quest",{"id":"first_harvest"}).ok,"actual private goods complete the resident's contract")
	check(domain.view(alice,"canopy_earth").quests.first_harvest.status=="complete" and domain.view(bob,"canopy_earth").quests.first_harvest.status=="active","one delivery cannot complete another resident's quest")
	check(domain.action(alice,"canopy_earth","assign_job",{"citizen":"mango","job":"grower"}).ok,"owner can assign their practical crew")
	check(domain.simulations.canopy.state.citizens.mango.employer==a,"worker wages and supplies bind to authenticated employer")
	var public_view: Dictionary=domain.view(alice,"canopy_earth")
	var serialized := JSON.stringify(public_view)
	check(not serialized.contains(alice) and not serialized.contains(bob) and public_view.plots.earth_1.owner=="player" and public_view.plots.moon_1.owner=="town","snapshot aliases ownership without leaking identity or other private accounts")
	check(serialized.to_utf8_buffer().size()<256*1024,"personalized snapshot fits the 256 KiB transport budget")
	public_view.accounts.player=999999
	public_view.inventories.player_earth.water=999999
	check(domain.state.players[a].credits!=999999 and domain.state.players[a].inventories.earth.water!=999999,"client view is detached from authoritative state")
	check(domain.action(alice,"canopy_earth","ship",{"item":"water","quantity":5}).ok,"interplanetary freight reserves the shared destination")
	check(domain.state.players[a].reserved.moon==6,"incoming quantity and packaging reserve central capacity")
	check(domain.action(alice,"harbor_earth","ship",{"item":"water","quantity":5}).ok and domain.state.players[a].reserved.moon==12,"reservations combine freight from separate societies")
	for i in range(95): domain.tick(1.0)
	check(domain.state.players[a].reserved.moon==0,"deliveries release global reservations exactly once")
	check(domain.total_money()==Domain.STARTING_MONEY,"trade, wages, contracts and freight conserve total credits")
	domain.tick(0.4)
	var saved: Dictionary=domain.export_state()
	var resumed=Domain.new()
	var imported: bool=resumed.import_state(saved)
	check(imported,"validated domain snapshot restores all resident books and societies")
	if not imported:
		quit(1)
		return
	check(resumed.view(alice,"canopy_earth").accounts.player==domain.view(alice,"canopy_earth").accounts.player and resumed.state.claims==domain.state.claims,"wallets and ownership survive reconnect and reload")
	for i in range(120):
		domain.tick(1.0)
		resumed.tick(1.0)
	check(domain.export_state()==resumed.export_state(),"save/resume preserves deterministic NPC work and economic progression")
	var invalid: Dictionary=domain.export_state()
	invalid.players[a].credits+=1
	before=resumed.export_state()
	check(not resumed.import_state(invalid) and resumed.export_state()==before,"minted-money save is rejected without partial replacement")
	invalid=domain.export_state()
	invalid.simulations.canopy={}
	check(not resumed.import_state(invalid),"malformed nested society is rejected safely")
	invalid=domain.export_state()
	invalid.players[a].reserved.moon=349
	check(not resumed.import_state(invalid),"invented cargo reservations are rejected")
	var path := "user://frontier_societies_test_%d.json"%OS.get_process_id()
	check(domain.save_game(path),"atomic server save writes a validated checkpoint")
	domain.tick(1.0)
	check(domain.save_game(path),"second checkpoint preserves a valid backup")
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string("{corrupt")
	file.close()
	check(resumed.load_game(path),"corrupt primary recovers the preceding valid backup")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path+".bak"))
	_test_shared_edges()
	_test_physical()
	print("FRONTIERSOCIETIESTEST %d/%d %s"%[passed,checks,"PASS" if passed==checks else "FAIL"])
	quit(0 if passed==checks else 1)

func _test_physical() -> void:
	var sim=Sim.new()
	sim.new_game(2026)
	var driver: Dictionary=sim.state.citizens.diesel
	check(sim.enable_physical_transport("diesel","npc:canopy_earth:diesel"),"driver binds to an authoritative physical vehicle")
	sim._set_job(driver,"load_trade","oil_rig","Collect crude",{"from":"oil_rig","to":"refinery","item":"crude_oil","quantity":8},1.0)
	var position: Array=driver.position.duplicate()
	var stock := sim.stock("refinery","crude_oil")
	for i in range(20): sim._update_citizen(driver,1.0)
	check(driver.position==position and driver.carrying.is_empty() and sim.stock("refinery","crude_oil")==stock,"physical worker cannot ghost-walk or commit cargo without a real arrival")
	check(not sim.report_physical_transport("diesel",driver.destination,0.0,true,"",int(driver.motion_epoch)-1),"stale vehicle arrival cannot satisfy a new job")
	sim.report_physical_transport("diesel",driver.destination,2.0,true,"",int(driver.motion_epoch))
	sim._update_citizen(driver,1.0)
	check(driver.carrying.is_empty(),"moving vehicle cannot load or unload")
	# Use an inspection task to prove stationary arrival unlocks timed work.
	sim._set_job(driver,"inspect","refinery","Inspect depot",{},1.0)
	sim.report_physical_transport("diesel",driver.destination,0.0,true,"",int(driver.motion_epoch))
	for i in range(3): sim._update_citizen(driver,1.0)
	check(not driver.observations.is_empty(),"fresh stopped arrival enables actual on-site work")
	sim.register_vehicle("npc:canopy_earth:diesel",1)
	var money: int=sim.balance(driver.employer)
	var fuel: int=sim.stock("gas_station","gasoline")
	sim.report_physical_transport("diesel",sim.state.locations.gas_station.position,2.0,false,"",int(driver.motion_epoch))
	check(not sim.refuel_transport("diesel","gas_station",2).ok,"moving crew vehicle cannot draw employer fuel credit")
	sim.report_physical_transport("diesel",[0,0],0.0,false,"",int(driver.motion_epoch))
	check(not sim.refuel_transport("diesel","gas_station",2).ok,"crew fuel cannot teleport from a distant depot")
	sim.report_physical_transport("diesel",sim.state.locations.gas_station.position,0.0,false,"",int(driver.motion_epoch))
	check(sim.refuel_transport("diesel","gas_station",2).ok and sim.stock("gas_station","gasoline")==fuel-2 and sim.balance(driver.employer)<money,"physical depot fuel purchase debits actual stock and employer funds")
	sim.state.time+=4.0
	check(not sim.refuel_transport("diesel","gas_station",1).ok,"stale vehicle reports cannot authorize refueling")
	check(not sim.action("refuel_transport",{"citizen":"diesel","facility":"gas_station","quantity":1}).ok,"player actions cannot invoke employer-funded traffic refueling")

func _test_shared_edges() -> void:
	var domain=Domain.new()
	domain.new_game(2026)
	domain.ensure_player(alice,"Alice")
	domain.ensure_player(bob,"Bob")
	domain.action(alice,"canopy_earth","claim_town")
	var actor := "member_"+alice
	var other := "member_"+bob
	# A bounded fixture at the shared storage limit: six incoming units fill it.
	domain.state.players[actor].inventories.moon.clear()
	domain.state.players[actor].inventories.moon["water"]=344
	check(domain.action(alice,"canopy_earth","ship",{"item":"water","quantity":5}).ok,"first society reserves the last six shared storage units")
	var before: Dictionary=domain.export_state()
	check(not domain.action(alice,"harbor_earth","ship",{"item":"water","quantity":1}).ok and domain.export_state()==before,"another town cannot overbook cargo capacity or charge for rejected freight")
	var restored=Domain.new()
	check(restored.import_state(before),"in-flight capacity reservations survive authoritative reload")
	var sim=domain.simulations.canopy
	var worker: Dictionary=sim.state.citizens.diesel
	sim.enable_physical_transport("diesel","npc:canopy_earth:diesel")
	# Cargo begins in the refinery's finite initial stock and must reach the rig.
	sim._set_job(worker,"load_trade","refinery","Load process water",{"from":"refinery","to":"oil_rig","item":"water","quantity":8},1.0)
	sim.report_physical_transport("diesel",worker.destination,0.0,true,"",int(worker.motion_epoch))
	for i in range(2): sim._update_citizen(worker,1.0)
	check(not worker.carrying.is_empty(),"a stopped vehicle loads real refinery stock")
	var old_employer: String=worker.employer
	var member_cash := int(domain.state.players[actor].credits)
	var other_cash := int(domain.state.players[other].credits)
	var npc_cash: int=sim.balance("diesel")
	check(domain.action(alice,"canopy_earth","assign_job",{"citizen":"diesel","job":"grower"}).ok and worker.employer==old_employer and worker.pending_employer==actor,"hiring a loaded driver queues the authenticated employer behind the cargo commitment")
	worker.cooldown=0.0
	sim._update_citizen(worker,1.0)
	var at_destination: int=sim.stock("oil_rig","water")
	for i in range(8): sim._update_citizen(worker,1.0)
	check(sim.stock("oil_rig","water")==at_destination and not worker.carrying.is_empty(),"destination stock remains unchanged until the physical truck arrives")
	sim.report_physical_transport("diesel",worker.destination,0.0,true,"",int(worker.motion_epoch))
	for i in range(5): sim._update_citizen(worker,1.0)
	check(sim.stock("oil_rig","water")==at_destination+8 and worker.carrying.is_empty(),"a stopped truck unloads its exact eight-unit manifest")
	check(int(domain.state.players[actor].credits)==member_cash and sim.balance("diesel")==npc_cash+int(worker.wage),"old employer pays committed delivery wages before the hire takes effect")
	sim._update_citizen(worker,1.0)
	check(worker.employer==actor and worker.job=="grower" and not worker.has("pending_employer"),"completed delivery activates the queued employer exactly once")
	worker._job={}
	sim._set_job(worker,"water","cooperative","Water owned plot",{"plot":"earth_1","source":actor+"_earth"},1.0)
	worker.destination=sim.state.plots.earth_1.position.duplicate()
	sim.state.plots.earth_1.automatic=true
	sim.state.plots.earth_1.moisture=10.0
	sim.report_physical_transport("diesel",worker.destination,0.0,true,"",int(worker.motion_epoch))
	for i in range(2): sim._update_citizen(worker,1.0)
	check(int(domain.state.players[actor].credits)==member_cash-int(worker.wage) and int(domain.state.players[other].credits)==other_cash,"new work charges only its authenticated employer's wallet")
	check(domain.total_money()==Domain.STARTING_MONEY,"queued hires preserve aggregate money conservation")
	sim.state.traffic.diesel["pose"]={"position":[1,2,3],"rotation":[0,1,0],"velocity":[0,0,0]}
	var persisted: Dictionary=domain.export_state()
	check(restored.import_state(persisted) and restored.simulations.canopy.state.traffic.diesel.pose==sim.state.traffic.diesel.pose and not restored.simulations.canopy.state.traffic.diesel.arrived,"reload preserves vehicle pose but requires a new physical arrival receipt")
	var invalid: Dictionary=persisted.duplicate(true)
	invalid.simulations.canopy.traffic.diesel.pose.velocity=[0,INF,0]
	check(not restored.import_state(invalid),"nonfinite physical vehicle save data is rejected")
