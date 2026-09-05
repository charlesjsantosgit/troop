extends Node
const Law = preload("res://scripts/civil_law.gd")
const Routes = preload("res://scripts/civil_police_routes.gd")
const Sim = preload("res://scripts/frontier_sim.gd")
var checks:=0
var failures:=0

func check(ok: bool, label: String) -> void:
	checks+=1
	if not ok: failures+=1;push_error("CIVILLAW FAIL: "+label)

func step(law,sim,at: Vector3,seconds: float,extra: Dictionary = {}) -> Dictionary:
	var events:Dictionary={}
	for i in range(ceili(seconds/.2)):
		sim.state.time+=.2
		var observation:Dictionary={"position":at,"speed":0,"on_foot":true,"inside":false,"reserved_payroll":0,"peer":1}
		observation.merge(extra,true)
		events.merge(law.advance(.2,float(sim.state.time),{"player":observation},sim),true)
	return events

func run() -> void:
	var sim=Sim.new();sim.new_game(2026)
	var law=Law.new();law.state=Law.new_state()
	var sites:Dictionary=Routes.site_positions()
	var security:=Law.vector(sites.bank_security)
	var vault:=Law.vector(sites.vault)
	var initial:int=sim.total_money()
	check(Law.valid(law.state),"fresh civil state validates")
	var remote:Dictionary=law.action("player","civil_rob",{"id":"bank"},sim,security+Vector3(100,0,0),sim.state.time)
	check(not remote.ok and sim.total_money()==initial,"remote robbery rejected without moving money")
	var before:int=sim.balance("treasury")
	check(law.action("player","civil_rob",{"id":"bank"},sim,security,sim.state.time).ok,"bank security stage begins at actual terminal")
	step(law,sim,security,2)
	check(law.state.residents.player.phase=="clear","alarm has a reporting delay and no instant wanted level")
	step(law,sim,security,6.4)
	check(law.state.residents.player.robbery.stage=="vault_ready","security stage finishes before cash can be collected")
	step(law,sim,security,1)
	check(law.state.residents.player.robbery.stage=="vault_ready","player has room to walk from terminal to vault")
	check(sim.balance("treasury")==before and law.state.residents.player.cash==0,"security progress creates no money")
	check(not law.action("player","civil_vault",{},sim,security,sim.state.time).ok,"cash must be collected at physical vault")
	check(law.action("player","civil_vault",{},sim,vault,sim.state.time).ok,"vault collection is separate second stage")
	step(law,sim,vault,18.2)
	check(law.state.residents.player.cash==420 and sim.balance(Law.ESCROW)==420,"completed bank robbery places real cash in held escrow")
	check(sim.total_money()==initial and sim.balance("treasury")==before-420,"robbery conserves total money")
	check(not law.action("player","civil_rob",{"id":"bank"},sim,security,sim.state.time).ok,"carried cash and recovery cooldown prevent robbery farming")
	check(not law.action("player","civil_fence",{},sim,vault,sim.state.time).ok,"selling cash remotely is rejected")
	check(Law.valid(law.state),"active robbery outcome is valid persistent state")
	var private_view:Dictionary=law.view("another_resident",sim.state.time)
	check(private_view.personal.is_empty() and not private_view.has("residents"),"public patrol snapshot does not disclose other players' private cases")
	check(not law.action("player","civil_surrender",{},sim,Vector3(0,8,0),sim.state.time).ok,"surrender requires officer or station proximity")
	var arrested:Dictionary=law.action("player","civil_surrender",{},sim,Law.vector(sites.station),sim.state.time)
	check(arrested.ok and law.state.residents.player.phase=="custody" and arrested.has("destination"),"station surrender gives a physical custody destination")
	check(sim.balance(Law.ESCROW)==0 and law.state.residents.player.cash==0 and sim.total_money()==initial,"arrest confiscates stolen cash without destroying legitimate money")
	check(not law.action("player","civil_service",{},sim,security,sim.state.time).ok,"community service cannot be completed from outside custody")
	check(law.action("player","civil_service",{},sim,Law.vector(sites.community_service),sim.state.time).ok,"community-service activity starts at sorting table")
	var released:Dictionary=step(law,sim,Law.vector(sites.community_service),12.2)
	check(law.state.residents.player.phase=="clear" and released.has("player"),"community service awards early physical release")
	# A second resident's robbery cannot simultaneously reserve the same counter.
	law.state.targets.clear()
	check(law.action("player","civil_rob",{"id":"bank"},sim,security,sim.state.time).ok,"recovered bank can begin another attempt")
	check(not law.action("other","civil_rob",{"id":"bank"},sim,security,sim.state.time).ok,"one counter cannot be robbed by two independent sessions")
	step(law,sim,security+Vector3(25,0,0),.2)
	check(law.state.residents.player.robbery.is_empty(),"leaving the counter interrupts collection")
	# Unknown/no line-of-sight offenses are not invented from speed alone.
	var traffic=Law.new();traffic.state=Law.new_state()
	traffic.ensure("player")
	var street:=Vector3(Law.Plan.MIN_X-55,Law.Plan.GROUND_Y,0)
	traffic.initialize_units()
	traffic._tick_traffic(traffic.state.residents.player,{"position":street,"speed":20,"speed_limit":11.176,"on_foot":false},[],.5,500)
	check(traffic.state.residents.player.phase=="clear","unobserved speeding does not trigger remote police")
	for i in range(8):traffic._tick_traffic(traffic.state.residents.player,{"position":street,"speed":20,"speed_limit":11.176,"on_foot":false},[0],.5,501+i*.5)
	check(traffic.state.residents.player.phase=="traffic_stop","sustained observed speeding requests a traffic stop")
	for i in range(8):traffic._tick_traffic(traffic.state.residents.player,{"position":street,"speed":0,"speed_limit":11.176,"on_foot":false},[0],.5,510+i*.5)
	check(traffic.state.residents.player.phase=="clear" and traffic.state.residents.player.warnings==1 and traffic.state.residents.player.fine==0,"cooperative first stop results in warning, no gunfire or fine")
	for i in range(8):traffic._tick_traffic(traffic.state.residents.player,{"position":street,"speed":20,"speed_limit":11.176,"on_foot":false},[0],.5,700+i*.5)
	traffic._tick_traffic(traffic.state.residents.player,{"position":street,"speed":20,"speed_limit":11.176,"on_foot":false},[],.5,740)
	check(traffic.state.residents.player.phase=="citation" and traffic.state.residents.player.fine==35,"minor traffic flight ends in citation instead of dangerous endless pursuit")
	var wallet:int=sim.balance("player")
	check(traffic.action("player","civil_pay",{},sim,Law.vector(sites.station),sim.state.time).ok and sim.balance("player")==wallet-35,"citation payment debits actual wallet once")
	check(not traffic.action("player","civil_pay",{},sim,Law.vector(sites.station),sim.state.time).ok,"paid citation cannot charge twice")
	# Persistence cross-validates evidence-held money against private cash bags.
	var city=sim._city()
	law.state.residents.erase("other")
	city.state.civil_law=law.state;city.advance(sim.state.time);sim.state.city=city.state
	var reload=Sim.new()
	check(reload.validate_state(sim.state),"integrated society validates civil state and exact money conservation")
	var invalid:Dictionary=law.state.duplicate(true);invalid.residents.player.cash=-1
	check(not Law.valid(invalid),"negative evidence cash is rejected")
	invalid=law.state.duplicate(true);invalid.residents.player.last_seen=[NAN,0,0]
	check(not Law.valid(invalid),"nonfinite suspect coordinates rejected")
	print("CIVILLAWTEST result=%d/%d %s"%[checks-failures,checks,"PASS" if failures==0 else "FAIL"])
	get_tree().quit(0 if failures==0 else 1)
