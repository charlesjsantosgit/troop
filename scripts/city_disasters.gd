extends Node3D
## Visual/physical disaster projection. Persistent records live in the city save;
## online creation is arbitrated by the authenticated claimed-aircraft authority.
const Plan=preload("res://scripts/city_plan.gd")
const State=preload("res://scripts/city_incident_state.gd")
const Shell=preload("res://scripts/city_damage_shell.gd")
var city:Node
var _scenes:Dictionary={}
var _previous:Dictionary={}
var _cooldowns:Dictionary={}
var _sync_clock:=0.0
func configure(owner_city:Node)->void:
	city=owner_city
	if Net.active and is_instance_valid(Net.city_incidents):
		Net.city_incidents.changed.connect(_sync_records)
		Net.city_incidents.request_snapshot()
	_sync_records(_records())
func _records()->Array:
	if Net.active and is_instance_valid(Net.city_incidents):return Net.city_incidents.snapshot()
	return city.frontier.simulation.state.get("city",{}).get("incidents",{}).values().duplicate(true)
func simulation_time()->float:
	if Net.active and is_instance_valid(city._network):
		var view:Dictionary=city._network.cached_view
		return float(view.get("time",0))+maxf(0,float(Time.get_ticks_msec()-city._view_clock_msec)/1000.0) if city._view_clock_msec>0 else float(view.get("time",0))
	return float(city.frontier.simulation.state.time)
func report_vehicle_impact(vehicle:Vehicle,at:Vector3,normal:Vector3,closing_speed:float)->void:
	if not is_instance_valid(vehicle) or vehicle.kind!=Vehicle.Kind.JET or closing_speed<40:return
	if not at.is_finite() or not normal.is_finite() or not is_finite(closing_speed):return
	var now:=simulation_time()
	if now<float(_cooldowns.get(vehicle.vid,-1)):return
	_cooldowns[vehicle.vid]=now+20
	var direction:Vector3=vehicle.global_basis.z.normalized()
	if absf(direction.dot(normal))<.1:direction=-normal.normalized()
	var hit:=State.find_hit(at+normal*8,at-normal*8,1.0)
	if hit.is_empty():return
	if Net.active:
		if is_instance_valid(Net.city_incidents):Net.city_incidents.report(vehicle.vid,hit.point,direction,closing_speed)
		return
	var sim=city.frontier.simulation
	var model=sim._city()
	if model==null:return
	var records:Dictionary=model.state.incidents
	if records.has(hit.building) or records.size()>=State.MAX_INCIDENTS:return
	var checkpoint:Dictionary=sim.state.duplicate(true)
	model.advance(now)
	records[hit.building]=State.record(hit.building,hit.point,direction,now)
	sim.state.city=model.state
	if city.frontier.persistence_enabled and not city.frontier.save_progress():
		sim.state=checkpoint;return
	_sync_records(records.values())
func _physics_process(dt:float)->void:
	if not is_instance_valid(city):return
	visible=city.frontier.current_planet()=="earth"
	_sync_clock-=dt
	if _sync_clock<=0:
		_sync_clock=1.0;_sync_records(_records())
	var now:=simulation_time()
	for id in _scenes:
		var entry:Dictionary=_scenes[id]
		entry.shell.update_incident(now)
		if is_instance_valid(entry.get("response")):
			entry.response.update_phase(State.phase(entry.record,now),State.progress(entry.record,now),now-float(entry.record.created))
	# Continuous aircraft sweep catches a facade crossed between physics frames,
	# including far blocks whose ordinary detailed collider is not streamed yet.
	for id in city.world.vehicles:
		var v:Vehicle=city.world.vehicles[id]
		if not is_instance_valid(v) or v.kind!=Vehicle.Kind.JET or v.remote_controlled or not is_instance_valid(v.driver):continue
		var current:Vector3=v.global_position
		var previous:Vector3=_previous.get(id,current)
		_previous[id]=current
		var speed:=v.linear_velocity.length()
		if speed<40 or current.distance_to(previous)>80 or current.distance_to(previous)<.01 or now<float(_cooldowns.get(id,-1)):continue
		var hit:Dictionary={}
		for offset in [Vector3.ZERO,v.global_basis.x*4.4,-v.global_basis.x*4.4,v.global_basis.z*7.2,-v.global_basis.z*6.8]:
			var candidate:=State.find_hit(previous+offset,current+offset,.4)
			if not candidate.is_empty() and (hit.is_empty() or candidate.distance<hit.distance):hit=candidate
		if hit.is_empty() or _scenes.has(hit.building):continue
		var closing:=maxf(0.0,-v.linear_velocity.dot(hit.normal))
		if closing<40:continue
		v.global_position=previous.lerp(current,clampf(float(hit.distance)/maxf(previous.distance_to(current),.01),0,1))+hit.normal*.5
		if v.has_method("report_collision_impact"):v.report_collision_impact(hit.point,hit.normal,closing)
		else:report_vehicle_impact(v,hit.point,hit.normal,closing)
	for id in _previous.keys():
		if not city.world.vehicles.has(id):_previous.erase(id)
func _sync_records(rows:Array)->void:
	if not is_instance_valid(city) or not is_instance_valid(city.city_world):return
	var incoming:Dictionary={}
	var traffic_rows:Array=[]
	for item in rows:
		if not item is Dictionary:continue
		var id:=str(item.get("building",""))
		if id.is_empty():continue
		incoming[id]=true
		var traffic:Dictionary=item.duplicate(true);traffic["point"]=State.vector(item.position);traffic["active"]=true;traffic_rows.append(traffic)
		if _scenes.has(id):continue
		city.city_world.set_building_damaged(id,true)
		var shell:=Shell.new();shell.name="Incident_"+id;add_child(shell);shell.configure(item,city.city_world)
		var response:Node3D=null
		if ResourceLoader.exists("res://scripts/city_emergency_response.gd"):
			response=load("res://scripts/city_emergency_response.gd").new();add_child(response);response.configure(city.world,item)
		_scenes[id]={"record":item.duplicate(true),"shell":shell,"response":response}
		if city.interior_id==id:
			city._leave_room()
			var building:=Plan.building(id)
			city._teleport(building.door+Vector3(0,.3,4))
		city.last_message="Emergency crews dispatched. This building will reopen tomorrow morning."
	for id in _scenes.keys():
		if incoming.has(id):continue
		var entry:Dictionary=_scenes[id];entry.shell.queue_free()
		if is_instance_valid(entry.get("response")):entry.response.queue_free()
		_scenes.erase(id);city.city_world.set_building_damaged(id,false)
	if is_instance_valid(city.crowd) and city.crowd.has_method("set_incidents"):city.crowd.set_incidents(traffic_rows)
func building_closed(id:String)->bool:return _scenes.has(id)
func stats()->Dictionary:
	var rows:Dictionary={}
	for id in _scenes:rows[id]=_scenes[id].shell.stats()
	return {"active":_scenes.size(),"buildings":rows}
