extends Node
const Plan=preload("res://scripts/city_plan.gd")
const State=preload("res://scripts/city_incident_state.gd")
const Shell=preload("res://scripts/city_damage_shell.gd")
const City=preload("res://scripts/city_world.gd")
const Economy=preload("res://scripts/city_economy.gd")
var checks:=0
var passed:=0
func check(ok:bool,label:String)->void:
	checks+=1
	if ok:passed+=1
	else:push_error("CITYDISASTER FAIL "+label)
func run()->void:
	var b:=Plan.building("crownreach-b24-24-l02")
	var start:Vector3=b.position+Vector3(0,80,-60)
	var finish:Vector3=b.position+Vector3(0,80,60)
	var hit:=State.find_hit(start,finish)
	check(not hit.is_empty() and hit.building==b.id,"continuous sweep hits actual tower")
	var miss:=State.find_hit(start+Vector3(50,0,0),finish+Vector3(50,0,0))
	check(miss.is_empty() or miss.building!=b.id,"parallel sweep misses tower outside footprint")
	var record:=State.record(b.id,hit.point,Vector3(0,0,1),900)
	check(State.valid({b.id:record}),"incident record validates physical impact")
	check(record.restore==1500.0,"reopens following day at06:00")
	for row in [[901,"impact"],[925,"fire"],[970,"stabilize"],[1100,"rebuild"],[1500,"restored"]]:
		check(State.phase(record,row[0])==row[1],"phase progression "+str(row[1]))
	var altered:=record.duplicate(true);altered.position=[NAN,1,2]
	check(not State.valid({b.id:altered}),"nonfinite impact rejected")
	altered=record.duplicate(true);altered.restore=999999
	check(not State.valid({b.id:altered}),"unbounded destruction duration rejected")
	var saved:=Economy.new();saved.new_game();saved.advance(900);saved.state.incidents[b.id]=record
	var copy:=Economy.new()
	check(copy.import_state(saved.state) and copy.state.incidents.size()==1,"unfinished damage persists through restart")
	State.advance(copy.state.incidents,1499)
	check(copy.state.incidents.size()==1,"building remains damaged before next morning")
	State.advance(copy.state.incidents,1500)
	check(copy.state.incidents.is_empty(),"next-day reset removes incident entirely")
	check(Shell.plane_opening(0,0,9.45,3.8) and Shell.plane_opening(4,0,9.45,3.8) and Shell.plane_opening(0,2,9.45,3.8),"opening contains fuselage wings and tail")
	check(not Shell.plane_opening(7,0,9.45,3.8) and not Shell.plane_opening(4,2,9.45,3.8),"plane silhouette retains surrounding wall")
	var city:=City.new();add_child(city);city._create_shared_resources()
	var shell:=Shell.new();add_child(shell);shell.configure(record,city);shell.update_incident(905)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var stats:=shell.stats()
	check(stats.removed_hole_cells>20 and stats.wall_colliders<400 and stats.debris==96,"physical hole and rubble remain bounded")
	var ray:=PhysicsRayQueryParameters3D.create(hit.point-Vector3(0,0,2),hit.point+Vector3(0,0,2),1)
	check(get_viewport().world_3d.direct_space_state.intersect_ray(ray).is_empty(),"plane-shaped wall opening is physically open")
	var solid:Vector3=hit.point+Vector3(7,0,0)
	ray=PhysicsRayQueryParameters3D.create(solid-Vector3(0,0,2),solid+Vector3(0,0,2),1)
	check(not get_viewport().world_3d.direct_space_state.intersect_ray(ray).is_empty(),"wall beside opening stays solid")
	var prior:=shell.upper.position
	shell.update_incident(920)
	check(shell.upper.position.y<prior.y,"damaged upper tower visibly collapses")
	shell.update_incident(1350)
	check(shell.scaffold.visible and shell.stats().phase>=0,"reconstruction restores lower floors behind scaffold")
	shell.queue_free();city.queue_free()
	await get_tree().process_frame
	_authority_checks(hit)
	print("CITYDISASTER result=%d/%d %s"%[passed,checks,"PASS" if passed==checks else "FAIL"])
	get_tree().quit(0 if passed==checks else 1)

func _authority_checks(hit:Dictionary)->void:
	var net:=get_tree().root.get_node("Net")
	net._wire()
	var service:Node=net.frontier_network
	var incidents:Node=net.city_incidents
	net.active=false;net.is_host=true;net.names[77]="Fixture pilot"
	service.societies=preload("res://scripts/frontier_societies.gd").new()
	service.societies.new_game(2026);service.society_ready=true;service.authoritative=true;service.persistence_enabled=false
	var id:="v:admin#77-1"
	net._vehicle_kinds[id]=Vehicle.Kind.JET;net._vehicle_positions[id]=hit.point
	net.player_realms[77]=net.PlayerRealm.EARTH
	incidents._motion[id]={"sample_time":Time.get_ticks_msec(),"position":hit.point,"approach":Vector3(0,0,100),"approach_time":Time.get_ticks_msec()}
	net._rate_windows.clear()
	check(not incidents._report(77,id,hit.point,Vector3.BACK,100),"unclaimed aircraft cannot damage a building")
	net.claimed_vehicles[id]=77;net._rate_windows.clear();net.player_realms[77]=net.PlayerRealm.MOON
	check(not incidents._report(77,id,hit.point,Vector3.BACK,100),"Moon aircraft state cannot damage an Earth building")
	net.player_realms[77]=net.PlayerRealm.EARTH;net._rate_windows.clear()
	check(not incidents._report(77,id,hit.point,Vector3.BACK,300),"claimed aircraft cannot invent an impact speed above observed approach")
	net._rate_windows.clear()
	check(not incidents._report(77,id,hit.point+Vector3(0,0,1000),Vector3.BACK,100),"remote fake impact rejected against last accepted aircraft position")
	net._rate_windows.clear()
	check(incidents._report(77,id,hit.point,Vector3.BACK,100),"claimed moving Earth aircraft creates authoritative actual-facade damage")
	check(service.societies.state.city.incidents.size()==1 and not service.societies._validated(service.societies.export_state()).is_empty(),"incident preserves a serializable valid shared world")
	net._rate_windows.clear()
	check(not incidents._report(77,id,hit.point,Vector3.BACK,100) and service.societies.state.city.incidents.size()==1,"repeated impact cannot duplicate demolition or rebuild crews")
	incidents._replica=[service.societies.state.city.incidents.values()[0]]
	incidents.reset()
	check(incidents._replica.is_empty() and incidents._motion.is_empty(),"network lifecycle clears prior-session damage and approach history")
	net.claimed_vehicles.clear();net.names.erase(77);net.is_host=false
