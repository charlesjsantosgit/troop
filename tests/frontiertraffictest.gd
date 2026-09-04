extends Node
## Actual headless rigid-body traffic test, isolated from careers and servers.
var _passed := 0
var _total := 0
var _simulation: FrontierSim
var _traffic: FrontierTraffic
var _site: FrontierSite
var _fixture: Node3D
var _elapsed := 0.0
var _peak_speed := 0.0
var _max_step := 0.0
var _last_position := Vector3.ZERO


func run(_main: Node) -> void:
	_fixture = Node3D.new()
	_fixture.name = "IsolatedTrafficPhysics"
	add_child(_fixture)
	_site = FrontierSite.new()
	_fixture.add_child(_site)
	# Far from actual game actors; the same local coordinates feed all towns.
	_site.position = Vector3(24000,0,18000)
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(420,2,420)
	shape.shape = box
	floor_body.add_child(shape)
	_site.add_child(floor_body)
	floor_body.position = Vector3(40,Gen.FRONTIER_TOWN_HEIGHT-1.0,0)
	# Exact local test grade, independent from ordinary far-away procedural land.
	_site.set_script(load("res://tests/frontier_traffic_test_site.gd"))
	if "trafficpose" in OS.get_cmdline_user_args():
		await _test_citizen_pose()
		_fixture.queue_free()
		await get_tree().physics_frame
		print("FRONTIERTRAFFICPOSETEST %d/%d PASS"%[_passed,_total])
		get_tree().quit(0 if _passed==_total else 1)
		return
	if "trafficcareer" in OS.get_cmdline_user_args():
		await _test_profession_transition()
		_fixture.queue_free()
		await get_tree().physics_frame
		print("FRONTIERTRAFFICCAREERTEST %d/%d PASS"%[_passed,_total])
		get_tree().quit(0 if _passed==_total else 1)
		return
	_simulation = FrontierSim.new()
	_simulation.new_game(2026)
	var worker: Dictionary = _simulation.state.citizens.diesel.duplicate(true)
	_simulation.state.citizens = {"diesel":worker}
	worker.position = [95.0,12.0]
	worker.destination = [60.0,35.0]
	worker.target = "gas_station"
	worker.carrying = {"from":"refinery","to":"gas_station","item":"gasoline","quantity":12,"packaging":0}
	worker._job = {"op":"unload","target":"gas_station","label":"Delivering gasoline","payload":{}}
	worker.motion_epoch = 1
	worker.work_remaining = 4.0
	worker.route = [[95,35],[60,35]]

	_traffic = FrontierTraffic.new()
	_traffic.configure(_simulation,_site,true,"test_town")
	_fixture.add_child(_traffic)
	_traffic.build()
	var car: Vehicle = _traffic.vehicle_for("diesel")
	_check(car is RigidBody3D and car.wheels.size()==4 and car.driver!=null,
		"authoritative NPC drives the actual four-wheel rigid body")
	_check(not car.can_enter(null) and car.npc_controlled,
		"NPC body cannot be claimed by a player")
	_last_position = car.global_position
	for frame in range(30): await _frame(car)
	_check(car.global_position.distance_to(_last_position) < 0.1,
		"physics samples remain finite")
	_check(int(_simulation.state.metrics.fuel_delivered)==0,
		"cargo is not credited while the vehicle is still approaching")
	_traffic.set_obstacles([_site.surface_point(93.35,24.0,0.8)])
	var yielded_to_person := false
	for frame in range(240):
		await _frame(car)
		yielded_to_person = yielded_to_person or "pedestrian" in str(_traffic.drivers.diesel.blocker)
	_check(yielded_to_person and car.speed()<0.6 and int(_simulation.state.metrics.fuel_delivered)==0,
		"a real-position pedestrian makes the approaching car yield without delivering")
	_traffic.set_obstacles([])
	# Place a real wall across the approach, then require physical braking.
	var wall := StaticBody3D.new()
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(10,3,1)
	wall_shape.shape = wall_box
	wall.add_child(wall_shape)
	_site.add_child(wall)
	wall.position = Vector3(95,Gen.FRONTIER_TOWN_HEIGHT+1.5,27)
	var waited := false
	for frame in range(900):
		await _frame(car)
		if "obstruction" in str(_traffic.drivers.diesel.blocker) or "lane" in str(_traffic.drivers.diesel.blocker): waited=true
	_check(waited and int(_simulation.state.metrics.fuel_delivered)==0,
		"a constructed wall blocks delivery and preserves the cargo ledger",str(_traffic.drivers.diesel.blocker))
	_check(car.speed()<0.6,"driver brakes to rest before a blocked lane", "speed=%.3f position=%s"%[car.speed(), _site.to_local(car.global_position)])
	wall.queue_free()
	await get_tree().physics_frame
	var delivered := false
	for frame in range(6600):
		await _frame(car)
		if int(_simulation.state.metrics.fuel_delivered)>=12:
			delivered=true
			break
		if frame%1200==1199:
			print("TRAFFIC_PROGRESS position=",_site.to_local(car.global_position)," speed=",car.speed()," driver=",_traffic.drivers.diesel)
	_check(delivered,"removing the real wall allows a physical drive, stop and cargo delivery",
		"local=%s speed=%.2f time=%.1f blocker=%s"%[_site.to_local(car.global_position),car.speed(),_elapsed,_traffic.drivers.diesel.blocker])
	_check(car.speed()<0.5 and _site.to_local(car.global_position).distance_to(Vector3(60,Gen.FRONTIER_TOWN_HEIGHT+0.6,35))<12,
		"delivery commits only at a stopped, nearby physical receiver")
	_check(_peak_speed>2.0 and _peak_speed<10.0 and _max_step<0.5,
		"road motion accelerates smoothly at town speeds with no pose jumps", "peak=%.2f step=%.4f"%[_peak_speed,_max_step])
	_check(_traffic.drivers.diesel.traveled>40.0,"the cargo actually travels the service-road distance")
	# A second delivery leaves the same loading bay in the opposite direction.
	# It must turn with tires, brake for a pedestrian, then complete normally.
	worker.carrying = {"from":"gas_station","to":"refinery","item":"gasoline","quantity":8,"packaging":0}
	_simulation._set_job(worker,"unload","refinery","Returning service load",{},4.0)
	var start_return := car.global_position
	_traffic.set_obstacles([{ "position": start_return + car.global_basis.z*5.0, "radius":1.0}])
	for frame in range(60): await _frame(car)
	_traffic.set_obstacles([])
	var reversed := false
	var returned := false
	for frame in range(7200):
		await _frame(car)
		reversed = reversed or car.engine.gear < 0
		if int(_simulation.state.metrics.fuel_delivered)>=20:
			returned=true
			break
	_check(reversed and returned,"a return delivery executes a real three-point turn and reaches the next receiver",
		"position=%s speed=%.3f context=%s worker=%s"%[_site.to_local(car.global_position), car.speed(),_traffic.drivers.diesel, worker])
	# Low fuel is a physical detour with a finite employer-funded purchase.
	_simulation._set_job(worker,"inspect","oil_rig","Inspecting the next receiver",{},4.0)
	_simulation.state.vehicle_fuel[car.vid].fuel_l=5.5
	var credits_before := _simulation.balance("transport")
	var refueled := false
	for frame in range(7200):
		await _frame(car)
		if float(_simulation.state.vehicle_fuel[car.vid].fuel_l)>10.0:
			refueled=true
			break
	_check(refueled and _simulation.balance("transport")<credits_before and car.speed()<0.5 		and _site.to_local(car.global_position).distance_to(Vector3(60,Gen.FRONTIER_TOWN_HEIGHT,35))<12.0 		and not bool(_simulation.state.traffic.diesel.arrived),
		"a low-fuel crew physically stops at the station and pays before resuming its job")
	var pose: Dictionary = _simulation.state.traffic.diesel.pose
	_check(pose.position.size()==3 and pose.velocity.size()==3,"physical pose and velocity persist with the town economy")
	var replica := FrontierTraffic.new()
	replica.configure(_simulation,_site,false,"test_town")
	_fixture.add_child(replica)
	replica.build()
	var reports: Dictionary = _simulation.state.traffic.diesel.duplicate(true)
	replica.apply_snapshot(_traffic.snapshot())
	var puppet: Vehicle = replica.vehicle_for("diesel")
	_check(puppet!=null and puppet.remote_controlled and puppet.freeze,
		"late join creates a frozen server-pose vehicle puppet")
	_check(_simulation.state.traffic.diesel==reports,
		"replica creation never reports motion or mutates cargo authority")
	_check(puppet.global_position.distance_to(car.global_position)<0.01,
		"server chassis pose reaches client without seat-offset drift")
	var ordinary := SafariJeep.new()
	_check(not ordinary.npc_controlled and ordinary.can_enter(null),
		"ordinary vehicles preserve normal player entry and controls")
	ordinary.free()
	await _test_citizen_pose()
	await _test_town_traffic()
	await _test_profession_transition()
	_fixture.queue_free()
	await get_tree().physics_frame
	print("FRONTIERTRAFFICTEST %d/%d PASS"%[_passed,_total])
	get_tree().quit(0 if _passed==_total else 1)


func _test_profession_transition() -> void:
	# Fresh finite inventories make both checkpoint validation and the deferred
	# cargo/job boundary observable rather than a synthetic empty worker switch.
	var frame := FrontierSite.new()
	frame.set_script(load("res://tests/frontier_traffic_test_site.gd"))
	_fixture.add_child(frame)
	frame.position=Vector3(28000,0,22000)
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size=Vector3(420,2,420)
	shape.shape=box
	floor_body.add_child(shape)
	frame.add_child(floor_body)
	floor_body.position=Vector3(40,Gen.FRONTIER_TOWN_HEIGHT-1.0,0)
	var model := FrontierSim.new()
	model.new_game(2026)
	var worker: Dictionary=model.state.citizens.diesel
	model.state.citizens={"diesel":worker}
	worker.position=[60.0,41.0]
	worker.shift=[0,24]
	var loaded: Dictionary=model._load_worker(worker,{"from":"gas_station","to":"refinery","item":"gasoline","quantity":4},false)
	model._set_job(worker,"unload","refinery","Completing the committed fuel delivery",{},4.0)
	var plot: Dictionary={}
	for candidate: Dictionary in model.state.plots.values():
		if candidate.owner=="player" and candidate.planet=="earth":
			plot=candidate
			break
	plot.automatic=true
	plot.growth=1.0
	var traffic := FrontierTraffic.new()
	traffic.configure(model,frame,true,"career_test")
	_fixture.add_child(traffic)
	traffic.build()
	var car: Vehicle=traffic.vehicles.diesel
	var resident := FrontierCitizen.new()
	resident.configure("diesel",model,frame,"earth")
	frame.add_child(resident)
	resident.build()
	_check(resident._body_shape.disabled,"seated driver disables only its pedestrian capsule")
	var changed: Dictionary=model.action("assign_job",{"citizen":"diesel","job":"grower"})
	_check(loaded.ok and changed.ok and worker.job=="tanker_driver" and worker.pending_job=="grower" and not worker.carrying.is_empty(),
		"a loaded driver defers the new profession until the committed delivery finishes",str(loaded))
	for tick in range(9000):
		await get_tree().physics_frame
		model.tick(1.0/60.0)
		if traffic.drivers.diesel.mode=="walking": break
	var parked_pose := car.global_transform
	_check(traffic.drivers.diesel.mode=="walking" and worker.job=="grower" and not worker.physical_transport and worker.carrying.is_empty() and model.state.metrics.fuel_delivered==4 and car.driver==null and car.freeze and traffic.vehicle_for("diesel")==null,
		"the delivery completes once, then its driver disembarks and parks the same supported car",str(traffic.drivers.diesel.mode))
	resident.update_citizen(0.0,Vector3.INF)
	_check(not resident._body_shape.disabled and resident._vehicle==null and resident.position.distance_to(Vector3(worker.position[0],Gen.FRONTIER_TOWN_HEIGHT,worker.position[1]))<0.01,
		"disembarking enables the real capsule at the authority-cleared doorway")
	resident.queue_free()
	var packet: Array=FrontierNetwork.pack_traffic(traffic.snapshot())
	var unpacked: Array=FrontierNetwork.unpack_traffic("career_test",packet)
	_check(unpacked.size()==1 and unpacked[0].mode=="walking" and var_to_bytes(packet).size()<1100,
		"compact multiplayer traffic preserves disembark mode within the packet budget")
	var fuel_before := float(model.state.vehicle_fuel[car.vid].fuel_l)
	var pedestrian_start := FrontierTraffic.Routes._vector(worker.position)
	for tick in range(120):
		await get_tree().physics_frame
		model.tick(1.0/60.0)
	_check(FrontierTraffic.Routes._vector(worker.position).distance_to(pedestrian_start)>2.0 and car.global_transform==parked_pose and not model.report_physical_transport("diesel",[0,0],0.0,true,"stale car",int(worker.motion_epoch)),
		"the new grower walks to actual field work while old vehicle receipts stay disabled")
	var checkpoint := "user://isolated_tests/traffic_career_%d.json"%Time.get_ticks_usec()
	var saved := model.save_game(checkpoint)
	var restored := FrontierSim.new()
	var reloaded := restored.load_game(checkpoint) if saved else false
	_check(saved and reloaded,"a parked owned car and walking worker survive the validated career checkpoint")
	if not reloaded:
		print("TRANSITION_INVALID worker=",worker," traffic=",model.state.traffic.diesel)
		traffic.queue_free()
		frame.queue_free()
		return
	traffic.queue_free()
	await get_tree().physics_frame
	model=restored
	worker=model.state.citizens.diesel
	traffic=FrontierTraffic.new()
	traffic.configure(model,frame,true,"career_test")
	_fixture.add_child(traffic)
	traffic.build()
	car=traffic.vehicles.diesel
	_check(car.global_position.distance_to(parked_pose.origin)<0.001 and car.freeze and car.driver==null and traffic.vehicle_for("diesel")==null and is_equal_approx(float(model.state.vehicle_fuel[car.vid].fuel_l),fuel_before),
		"loading restores the exact parked body without gifting another starter fuel tank")
	var work_before := int(worker.completed)
	for tick in range(9000):
		await get_tree().physics_frame
		model.tick(1.0/60.0)
		if int(worker.completed)>work_before: break
	_check(int(worker.completed)>work_before and int(model.state.metrics.harvested)>0,
		"the former driver reaches a real plot and completes paid farm work on foot")
	# No second farm task is committed between the completion tick and hiring.
	var hired: Dictionary=model.action("assign_job",{"citizen":"diesel","job":"tanker_driver"})
	resident=FrontierCitizen.new()
	resident.configure("diesel",model,frame,"earth")
	frame.add_child(resident)
	resident.build()
	var completed_before := int(worker.completed)
	var wage_before := model.balance("diesel")
	var same_car := car.get_instance_id()
	var saw_boarding := false
	var checked_wall := false
	var maximum_walk_step := 0.0
	var boarding_capsule_active := true
	var previous := FrontierTraffic.Routes._vector(worker.position)
	for tick in range(9000):
		await get_tree().physics_frame
		model.tick(1.0/60.0)
		var mode := str(traffic.drivers.diesel.mode)
		if mode=="boarding":
			resident.update_citizen(1.0/60.0,Vector3(100000,0,0))
			boarding_capsule_active=boarding_capsule_active and not resident._body_shape.disabled
			saw_boarding=true
			var walk_route: Array=traffic.drivers.diesel.boarding_route
			var current := FrontierTraffic.Routes._vector(worker.position)
			if not checked_wall and not walk_route.is_empty() and current.distance_to(FrontierTraffic.Routes._vector(walk_route[0]))>4.0:
				var direction := (FrontierTraffic.Routes._vector(walk_route[0])-current).normalized()
				var wall := StaticBody3D.new()
				var collider := CollisionShape3D.new()
				var wall_box := BoxShape3D.new()
				wall_box.size=Vector3(6,3,0.5)
				collider.shape=wall_box
				wall.add_child(collider)
				frame.add_child(wall)
				wall.position=Vector3(current.x+direction.x*2.0,Gen.FRONTIER_TOWN_HEIGHT+1.5,current.y+direction.y*2.0)
				wall.rotation.y=atan2(direction.x,direction.y)
				for wait_tick in range(90):
					await get_tree().physics_frame
					model.tick(1.0/60.0)
				var stopped := FrontierTraffic.Routes._vector(worker.position)
				for wait_tick in range(30):
					await get_tree().physics_frame
					model.tick(1.0/60.0)
				_check(stopped.distance_to(FrontierTraffic.Routes._vector(worker.position))<0.01 and "clear walk" in str(traffic.drivers.diesel.blocker) and not model.state.traffic.diesel.arrived,
					"a real wall stops the return walk without authorizing cargo work")
				wall.queue_free()
				await get_tree().physics_frame
				previous=FrontierTraffic.Routes._vector(worker.position)
				checked_wall=true
			maximum_walk_step=maxf(maximum_walk_step,previous.distance_to(FrontierTraffic.Routes._vector(worker.position)))
			if car.global_position.distance_to(parked_pose.origin)>0.01: break
		previous=FrontierTraffic.Routes._vector(worker.position)
		if saw_boarding and mode=="driving": break
	resident.update_citizen(0.0,Vector3.INF)
	_check(boarding_capsule_active and resident._body_shape.disabled and resident._vehicle==car,
		"boarding keeps the capsule active until the worker actually occupies its seat")
	_check(hired.ok and saw_boarding and checked_wall and traffic.drivers.diesel.mode=="driving" and worker.physical_transport and car.driver!=null and traffic.vehicle_for("diesel")==car and car.get_instance_id()==same_car and maximum_walk_step<0.12,
		"rehiring walks the worker back to the existing car before reattaching its seated rig", "mode=%s walk_step=%.4f"%[traffic.drivers.diesel.mode,maximum_walk_step])
	_check(int(worker.completed)==completed_before and model.balance("diesel")==wage_before and int(model.state.metrics.fuel_delivered)==4 and float(model.state.vehicle_fuel[car.vid].fuel_l)<=fuel_before+0.001,
		"parking and reboarding create no duplicate wages, cargo payout or fuel")
	for suffix in ["",".bak",".tmp"]:
		if FileAccess.file_exists(checkpoint+suffix): DirAccess.remove_absolute(ProjectSettings.globalize_path(checkpoint+suffix))
	traffic.queue_free()
	frame.queue_free()


func _frame(car: Vehicle) -> void:
	await get_tree().physics_frame
	var dt := 1.0/float(Engine.physics_ticks_per_second)
	_elapsed+=dt
	_simulation.tick(dt)
	_peak_speed=maxf(_peak_speed,car.speed())
	_max_step=maxf(_max_step,car.global_position.distance_to(_last_position))
	_last_position=car.global_position


func _check(condition: bool, message: String, detail := "") -> void:
	_total+=1
	if condition: _passed+=1
	print("%s %s%s"%["PASS" if condition else "FAIL",message," :: "+detail if detail!="" else ""])


func _test_town_traffic() -> void:
	# One full settlement uses the exact same static footprints as production,
	# with five real crews instead of a single scripted fixture driver.
	_traffic.queue_free()
	for child in _fixture.get_children():
		if child is FrontierTraffic: child.queue_free()
	await get_tree().physics_frame
	var model := FrontierSim.new()
	model.new_game(2026)
	var settlement := FrontierSettlement.new()
	settlement.configure(_site,model,"earth")
	_site.add_child(settlement)
	settlement.build_collision_only()
	var traffic := FrontierTraffic.new()
	traffic.configure(model,_site,true,"populated_test")
	_fixture.add_child(traffic)
	traffic.build()
	var separated := true
	for a in traffic.vehicles:
		for b in traffic.vehicles:
			if a!=b and traffic.vehicles[a].global_position.distance_to(traffic.vehicles[b].global_position)<5.0: separated=false
	_check(traffic.vehicles.size()==5 and separated,
		"five diverse road crews spawn in separate real forecourt spaces")
	var initial_positions := {}
	for id in traffic.vehicles: initial_positions[id]=traffic.vehicles[id].global_position
	for frame in range(36000):
		await get_tree().physics_frame
		model.tick(1.0/float(Engine.physics_ticks_per_second))
	var moved := 0
	var finite := true
	for id in traffic.vehicles:
		var car: Vehicle=traffic.vehicles[id]
		if float(traffic.drivers[id].traveled)>15.0: moved+=1
		finite=finite and car.global_position.is_finite() and car.speed()<10.0
		print("TOWN_DRIVER ",id," pos=",_site.to_local(car.global_position)," distance=",traffic.drivers[id].traveled," completed=",model.state.citizens[id].completed," context=",traffic.drivers[id]," job=",model.state.citizens[id]._job)
	_check(finite and moved>=4,"town cars share real collision geometry without overlap recovery or invalid physics", "moving=%d"%moved)
	_check(int(model.state.metrics.fuel_delivered)>0,
		"the populated town's physical traffic completes an autonomous fuel delivery", str(model.state.metrics))
	_check(int(model.state.metrics.crude_refined)>40 and model.state.citizens.jet.completed>=2 and model.state.citizens.diesel.completed>=3, "both physical tankers complete the petroleum supply chain",str(model.state.metrics))


func _test_citizen_pose() -> void:
	var model := FrontierSim.new()
	model.new_game()
	var worker: Dictionary=model.state.citizens.mango
	worker.position=[0,4]
	worker._job={"op":"plant","label":"Planting the nursery"}
	worker.work_remaining=20.0
	worker.activity="Waiting for a clear route"
	worker.route=[[10,4]]
	var actor := FrontierCitizen.new()
	actor.configure("mango",model,_site,"earth")
	_site.add_child(actor)
	actor.build()
	for frame in range(60): actor.update_citizen(1.0/60.0,Vector3.INF)
	var foot := actor.rig.foot_l.global_position
	var pitch := 0.0
	var foot_drift := 0.0
	for frame in range(1200):
		actor.update_citizen(1.0/60.0,Vector3.INF)
		pitch=maxf(pitch,absf(actor.rig.torso_p.rotation.x))
		foot_drift=maxf(foot_drift,foot.distance_to(actor.rig.foot_l.global_position))
	_check(pitch<0.15 and foot_drift<0.01 and not actor._work_active and not actor._work_tool.visible,
		"planned-but-blocked workers remain upright and planted without fake work", "pitch=%.4f foot_drift=%.5f"%[pitch,foot_drift])
	worker.activity="Planting the nursery"
	worker.route=[]
	var hand := actor.rig.paw_r.global_position
	var stroke := 0.0
	var forward_reach := 0.0
	for frame in range(180):
		actor.update_citizen(1.0/60.0,Vector3.INF)
		stroke=maxf(stroke,hand.distance_to(actor.rig.paw_r.global_position))
		forward_reach=maxf(forward_reach,(-actor.rig.yaw_node.global_basis.z.normalized()).dot(actor.rig.paw_r.global_position-actor.rig.torso_p.global_position))
	_check(actor._work_active and actor._work_tool.visible and stroke>0.04,
		"active planting shows a real tool and bounded work strokes")
	_check(forward_reach>0.25,"grower strokes and their tool reach visibly in front of the body", "forward_reach=%.3f m"%forward_reach)
	worker.job="oil_rigger"
	worker._job={"op":"extract","label":"Operating rig equipment"}
	worker.activity="Operating rig equipment"
	forward_reach=0.0
	for frame in range(180):
		actor.update_citizen(1.0/60.0,Vector3.INF)
		forward_reach=maxf(forward_reach,(-actor.rig.yaw_node.global_basis.z.normalized()).dot(actor.rig.paw_r.global_position-actor.rig.torso_p.global_position))
	_check(actor._work_active and actor._work_tool.visible and forward_reach>0.25,
		"rigger equipment strokes keep the wrench in front of the worker", "forward_reach=%.3f m"%forward_reach)
	worker.activity="Waiting for supplies"
	actor.update_citizen(1.0/60.0,Vector3.INF)
	_check(not actor._work_active and not actor._work_tool.visible,
		"work animation stops as soon as the authoritative task is blocked")
	actor.queue_free()
