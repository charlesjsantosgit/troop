extends Node
const Crowd = preload("res://scripts/city_crowd.gd")
const Traffic = preload("res://scripts/city_traffic.gd")
const Ambient = preload("res://scripts/city_ambient_life.gd")
const Plan = preload("res://scripts/city_plan.gd")
const Fleet = preload("res://scripts/city_vehicle_models.gd")
var checks := 0
var passed := 0

class ContactMachine extends Vehicle:
	func _ready() -> void:
		mass = 1500
		gravity_scale = 0
		super()
		var collider := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(1.8,1.2,4.4)
		collider.shape = box
		add_child(collider)
	func _simulate(_dt: float) -> void: pass
	func _apply_parked_hold(_dt: float) -> void: pass
	func _try_sleep_parked() -> void: pass
	func _sanity_clamp() -> bool: return false

func check(ok: bool,label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("CITYTRAFFICIMPACT "+("PASS " if ok else "FAIL ")+label)

func run() -> void:
	var manager := Crowd.new()
	add_child(manager)
	manager.set_process(false)
	manager.set_physics_process(false)
	var key := Vector2i(32,30)
	var actor := Crowd.StreetActor.new()
	actor.manager = manager
	actor.car = true
	actor.serial = 7001
	actor.model = 1
	actor.road_from = key+Vector2i.DOWN
	actor.road_to = key
	actor.road_next = key+Vector2i.UP
	var at := Traffic.stop_point(key,Vector2i.UP,4.63)+Vector2(0,70)
	actor.position = Vector3(at.x,1000,at.y)
	manager.add_child(actor)
	manager.actors.append(actor)
	actor.build()
	actor.set_physics_process(false)
	var original_driver: Mesh = actor.find_child("CanonicalMonkeyDriver",true,false).mesh
	var car := ContactMachine.new()
	car.position = actor.position+Vector3(0,.60,10)
	add_child(car)
	car.linear_velocity = Vector3(0,0,-22)
	car._prev_velocity = car.linear_velocity
	var previous_ticks := Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = 240
	for frame in range(110): await get_tree().physics_frame
	check(car.collision_count==1 and actor.impact_count==1,"actual rigid-body contact reaches the collided traffic car exactly once")
	check(actor.impact_speed>15 and actor.disabled_until>8 and actor.crash_damage>0,"physical normal closing speed determines traffic damage and recovery interval")
	check(actor.impact_local_point.z>1 and actor.impact_local_normal.z<-.9,"contact point and opposite surface normal are transferred in the correct space")
	check(actor._deformed_meshes>0 and actor.find_child("CanonicalMonkeyDriver",true,false).mesh==original_driver,"traffic body dents locally while canonical driver geometry is preserved")
	check(actor._turn_materials.size()==2 and actor._turn_materials[0].emission_energy_multiplier==actor._turn_materials[1].emission_energy_multiplier,"damaged traffic shows both hazard indicators on the shared clock")
	var damage := actor.crash_damage
	actor.receive_vehicle_impact(Vector3.INF,Vector3.UP,90)
	actor.receive_vehicle_impact(actor.position,Vector3.UP,NAN)
	actor.receive_vehicle_impact(actor.position,Vector3.UP,22)
	check(actor.impact_count==1 and actor.crash_damage==damage,"invalid and repeated same-contact notifications cannot spam damage")
	car.queue_free()
	await get_tree().physics_frame
	var held := actor.position
	for frame in range(60):
		manager.traffic.advance(.016)
		actor._drive(.016)
	check(actor.position.is_equal_approx(held) and actor.speed==0,"damaged physical traffic remains stationary throughout its recovery hold")
	var state := Ambient.VehicleState.new()
	state.serial = actor.serial
	state.model = actor.model
	state.capture(actor)
	state.physical = actor
	actor.ambient_state = state
	var deadline: float = state.disabled_until
	var identity: int = actor.serial
	manager._retire(actor)
	manager.actors.erase(actor)
	await get_tree().process_frame
	var stopped := state.at
	for frame in range(30):
		manager.traffic.advance(.05)
		state.advance(.05,manager.traffic,[state])
	check(state.at.is_equal_approx(stopped) and state.speed==0 and state.velocity==Vector2.ZERO and state.disabled_until==deadline,"demotion retains the same stopped position and recovery deadline")
	var follower := Ambient.VehicleState.new()
	follower.serial = identity+1
	follower.road_from = state.road_from
	follower.road_to = state.road_to
	follower.road_next = state.road_next
	follower.at = state.at+Vector2(0,15)
	follower.speed = 4
	for frame in range(160): follower.advance(.05,manager.traffic,[state,follower])
	var gap := follower.at.distance_to(state.at)-(follower.vehicle_length+state.vehicle_length)*.5
	check(gap>=Traffic.GAP-.03 and follower.speed<.25,"distant following car brakes into a real bumper-gap queue behind the disabled car")
	var promoted := Crowd.StreetActor.new()
	promoted.manager = manager
	promoted.car = true
	promoted.ambient_state = state
	state.restore(promoted)
	manager.add_child(promoted)
	manager.actors.append(promoted)
	promoted.build()
	promoted.set_physics_process(false)
	state.physical = promoted
	check(promoted.serial==identity and promoted.disabled_until==deadline and promoted.impact_count==1 and promoted._deformed_meshes>0,"promotion restores the exact identity, hold, hazard state and damaged shell")
	var ambient := Ambient.new()
	ambient.manager = manager
	manager.add_child(ambient)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = Fleet.mesh(1,false,false)
	mm.instance_count = 1
	var batch := MultiMeshInstance3D.new()
	batch.multimesh = mm
	ambient.add_child(batch)
	ambient.batches.assign([batch,batch])
	state.instance_slot = 0
	ambient._render_vehicle(state)
	var packet := Ambient.vehicle_render_state(state,manager.traffic.time)
	check(packet.custom.a==1 and packet.transform.basis.x.length()==0,"far render carries hazards while hiding the promoted duplicate")
	var lenses := 0
	for uv: Vector2 in mm.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]:
		if uv.y>.5: lenses += 1
	check(lenses==24,"all four distant hazard lenses are part of the existing bounded class mesh")
	manager.traffic.time = deadline+.01
	promoted._drive(.1)
	check(promoted.disabled_until==0 and promoted.crash_damage==0 and promoted._deformed_meshes==0 and promoted.speed>0,"bounded recovery restores the original shell and resumes legal acceleration")
	state.physical = null
	state.advance(.1,manager.traffic,[state])
	check(state.disabled_until==0 and state.speed>0,"distant recovery also resumes without waiting for physical promotion")
	var route := Crowd._sidewalk_path(Traffic.point(key))
	var nearby := 0
	var sidewalk_clear := true
	var local_focus := Vector3(Traffic.point(key).x+15,Plan.GROUND_Y,Traffic.point(key).y+15)
	for i in range(21):
		var spawn := Crowd._sidewalk_spawn(route,local_focus,i*9)
		if spawn.position.distance_to(local_focus)<100: nearby += 1
		var closest := INF
		for segment in range(route.size()): closest = minf(closest,Geometry3D.get_closest_point_to_segment(spawn.position,route[segment],route[(segment+1)%route.size()]).distance_to(spawn.position))
		sidewalk_clear = sidewalk_clear and closest<.001
	check(nearby>=20 and sidewalk_clear,"local cohort fills the closest real sidewalk without cutting through parcels")
	var sign_clear := true
	for arm in Traffic.DIRECTIONS:
		var cross := Traffic.crossing(key,arm)
		var approach := [cross[0]+Vector2(arm)*9,cross[0],cross[1],cross[1]+Vector2(arm)*9]
		for endpoint in range(2):
			var pole := preload("res://scripts/city_traffic_signals.gd").pedestrian_pole(key,arm,endpoint)
			for segment in range(3):
				sign_clear = sign_clear and Geometry2D.get_closest_point_to_segment(pole,approach[segment],approach[segment+1]).distance_to(pole)>.9
	check(sign_clear,"pedestrian signal poles clear both actual approach paths and crossings")
	manager.queue_free()
	var effects := get_node_or_null("VehicleImpactEffects")
	if is_instance_valid(effects): effects.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	Engine.physics_ticks_per_second = previous_ticks
	print("CITYTRAFFICIMPACTTEST result=%d/%d %s"%[passed,checks,"PASS" if passed==checks else "FAIL"])
	get_tree().quit(0 if passed==checks else 1)
