extends Node
const Traffic = preload("res://scripts/city_traffic.gd")
const Crowd = preload("res://scripts/city_crowd.gd")
const Fleet = preload("res://scripts/city_vehicle_models.gd")
const Ambient = preload("res://scripts/city_ambient_life.gd")
const Monkeys = preload("res://scripts/city_monkey_models.gd")
const Catalog = preload("res://scripts/vehicle_catalog_panel.gd")
const Signals = preload("res://scripts/city_traffic_signals.gd")
const Plan = preload("res://scripts/city_plan.gd")
var checks := 0
var passed := 0
var _physical_finished := false

class TestVehicle extends RefCounted:
	var car := true
	var serial := 1
	var road_from := Vector2i.ZERO
	var road_to := Vector2i.ZERO
	var road_next := Vector2i.ZERO
	var speed := 0.0
	var at := Vector2.ZERO
	var waiting_to_cross := false
	var crossing_key := Vector2i(-1,-1)
	func position_2d() -> Vector2: return at

func _check(ok: bool, label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("CITYTRAFFIC %s %s" % ["PASS" if ok else "FAIL", label])

func _vehicle(key: Vector2i, incoming: Vector2i, outgoing: Vector2i, serial := 1) -> TestVehicle:
	var result := TestVehicle.new()
	result.serial = serial
	result.road_from = key - incoming
	result.road_to = key
	result.road_next = key + outgoing
	result.at = Traffic.stop_point(key, incoming)
	return result

func run() -> void:
	_geometry()
	_rules()
	_fleet_population()
	_controlled_drivers()
	_catalog()
	_incidents()
	await _physical()
	_check(_physical_finished, "physical scenarios completed without an early script failure")
	print("CITYTRAFFICTEST result=%d/%d %s" % [passed, checks, "PASS" if passed == checks else "FAIL"])
	get_tree().quit(0 if passed == checks else 1)

func _geometry() -> void:
	var checked := 0
	var legal := true
	var buildings_clear := true
	for x in range(30, 35):
		for z in range(30, 35):
			var key := Vector2i(x,z)
			for incoming in Traffic.approaches(key):
				var lane := Traffic.stop_point(key, incoming) - Traffic.point(key)
				legal = legal and lane.dot(Traffic.right(incoming)) > 0.0
				legal = legal and lane.dot(Traffic.right(incoming)) + Traffic.CAR_WIDTH * .5 < Traffic.road_half(Traffic.road_index(key, incoming))
				var front := Traffic.stop_point(key,incoming) + Vector2(incoming) * Traffic.CAR_LENGTH * .5
				var bar := Traffic.point(key) - Vector2(incoming) * (Traffic.cross_half(key,incoming) + Traffic.STOP_BAR_OFFSET) + Traffic.right(incoming) * Traffic.lane_offset(key,incoming)
				legal = legal and (bar-front).dot(Vector2(incoming)) >= .34
				for outgoing in Traffic.DIRECTIONS:
					if outgoing == -incoming or not Traffic.edge_allowed(key,key+outgoing): continue
					var route := Traffic.turn_path(key-incoming,key,key+outgoing)
					for point in route:
						for block in Plan.blocks_near(Vector3(point.x,Plan.GROUND_Y,point.y),1):
							for building: Dictionary in Plan.block_buildings(block):
								var offset := point - Vector2(building.position.x,building.position.z)
								buildings_clear = buildings_clear and (absf(offset.x) >= building.size.x*.5 + 1.05 or absf(offset.y) >= building.size.z*.5 + 1.05)
					checked += 1
	_check(legal, "right-hand lanes fit both road widths and whole vehicle stops before its painted bar")
	_check(buildings_clear and checked > 100, "sampled straight/left/right connectors clear actual nearby building parcels")
	var park_key := Traffic.grid(Plan.PARK_CENTER)
	_check(not Traffic.edge_exists(park_key,park_key+Vector2i.RIGHT), "park internal roads are absent from vehicle graph")
	var plaza_key := Traffic.grid(Plan.CENTER)
	_check(not Traffic.edge_exists(plaza_key,plaza_key+Vector2i.RIGHT), "plaza pedestrian space has no traffic edge")
	var one := Vector2i(35,30)
	var direction := Traffic.one_way_direction(one,0)
	_check(direction != Vector2i.ZERO and Traffic.edge_allowed(one,one+direction) and not Traffic.edge_allowed(one+direction,one), "posted one-way corridor rejects wrong-way edges")
	_check(is_equal_approx(Traffic.speed_limit(Vector2i(32,30),Vector2i.UP),25*.44704) and is_equal_approx(Traffic.speed_limit(Vector2i(34,30),Vector2i.UP),15*.44704), "avenue/local speed caps match their 25/15 mph signs")
	_check(Traffic.clearance_seconds(Vector2i(32,32)) >= 26.4 and Traffic.WALK >= 7 and Traffic.PED_BUFFER >= 2, "wide avenue crossing gets full slow-walker clearance and steady-hand buffer")

func _rules() -> void:
	var model := Traffic.new()
	var key := Vector2i(32,30)
	var north := _vehicle(key,Vector2i.UP,Vector2i.UP)
	var east := _vehicle(key,Vector2i.RIGHT,Vector2i.RIGHT,2)
	var right := _vehicle(key,Vector2i.RIGHT,Vector2i.DOWN,3)
	_check(model.may_enter(north,[north]) and not model.may_enter(east,[east]), "north/south green never authorizes perpendicular east/west traffic")
	var curb_waiter := TestVehicle.new()
	curb_waiter.car = false
	curb_waiter.waiting_to_cross = true
	curb_waiter.crossing_key = key
	_check(model.may_enter(north,[north,curb_waiter]), "pedestrian waiting behind the curb on DON'T WALK does not cancel a clear vehicle green")
	_check(not model.may_enter(right,[right]), "right turn is refused on red even with an empty intersection")
	model.ensure(key).stage = 1
	north.at = Traffic.stop_point(key,Vector2i.UP) - Vector2(Vector2i.UP)*10
	north.speed = 3.0
	_check(not model.may_enter(north,[north]), "yellow stops a vehicle with comfortable braking distance")
	north.at = Traffic.stop_point(key,Vector2i.UP) - Vector2(Vector2i.UP)*0.5
	north.speed = 5.0
	_check(model.may_enter(north,[north]), "yellow lets a committed close approach clear rather than forcing unsafe braking")
	north.speed = 0.0
	north.at = Traffic.stop_point(key,Vector2i.UP)
	_check(not model.may_enter(north,[north]), "stationary vehicle never starts on yellow")
	model.reserve_car(north)
	model.ensure(key).stage = 2
	model.ensure(key).elapsed = 2.0
	model.advance(.1)
	_check(model.display(key).north_south == "red" and model.display(key).east_west == "red" and model.display(key).stage == 2, "occupied box extends all-red before conflicting traffic is released")
	model.release_car(key,north.serial)
	model.advance(.1)
	_check(model.display(key).east_west == "green", "clear box releases the next green phase")
	model.ensure(key).stage = 6
	model.ensure(key).elapsed = 0.0
	_check(model.pedestrian_may_enter(key,40,[]) and not model.may_enter(east,[east]), "WALK grants crossing reservation and protects it from vehicles")
	model.ensure(key).stage = 7
	_check(not model.pedestrian_may_enter(key,41,[]) and model.ensure(key).pedestrians.has(40), "flashing hand blocks new starts while existing pedestrian keeps right of way")
	model.ensure(key).stage = 8
	model.ensure(key).elapsed = 3.0
	model.advance(.1)
	_check(model.display(key).stage == 8 and model.display(key).pedestrian == "stop", "slow or obstructed crossing holds steady hand and all-red")
	model.release_pedestrian(key,40)
	model.advance(.1)
	_check(model.display(key).north_south == "green", "vehicles resume after the last crossing clears")
	var left := _vehicle(key,Vector2i.UP,Vector2i.LEFT,5)
	var opposite := _vehicle(key,Vector2i.DOWN,Vector2i.DOWN,6)
	_check(not model.may_enter(left,[left,opposite]), "permissive left turn yields to oncoming through traffic")
	_check(model.may_enter(left,[left]), "left turn proceeds during green after opposing traffic clears")
	var receiving := _vehicle(key+Vector2i.UP,Vector2i.UP,Vector2i.UP,7)
	receiving.at = Traffic.exit_point(key,Vector2i.UP) + Vector2.UP * 1.0
	north.at = Traffic.stop_point(key,Vector2i.UP)
	_check(not model.may_enter(north,[north,receiving]), "blocked receiving lane prevents entering and blocking the box")
	var local := Vector2i(34,30)
	var a := _vehicle(local,Vector2i.UP,Vector2i.UP,10)
	var b := _vehicle(local,Vector2i.LEFT,Vector2i.LEFT,11)
	_check(not model.may_enter(a,[a,b]), "STOP requires a full stationary dwell before entry")
	model.may_enter(b,[a,b])
	model.advance(1.1)
	_check(not model.may_enter(a,[a,b]) and model.may_enter(b,[a,b]), "simultaneous all-way stop arrivals yield to the driver on their right")
	var four_model := Traffic.new()
	var four: Array = []
	for direction in Traffic.DIRECTIONS: four.append(_vehicle(local,direction,direction,100+four.size()))
	for vehicle in four: four_model.may_enter(vehicle,four)
	four_model.advance(3.1)
	var admitted := 0
	for vehicle in four:
		if four_model.may_enter(vehicle,four): admitted += 1
	_check(admitted == 1, "four simultaneous stop arrivals resolve a courteous single-car release without deadlock")
	var follower := _vehicle(local,Vector2i.UP,Vector2i.UP,12)
	follower.at = a.at + Vector2.DOWN * 6.0
	_check(Traffic.following_speed(follower,[follower,a],Vector2.UP,8.0) == 0.0, "queue follower preserves a real bumper gap instead of overlapping")
	var district := Plan.district_for_block(Plan.world_to_block(Traffic.point(key)))
	model.set_district_services([{"id":district,"infrastructure":{"power_ratio":0.0,"mobility_ratio":0.0}}])
	north.speed = 0.0
	_check(model.display(key).north_south == "flash_red" and model.display(key).pedestrian == "dark" and not model.may_enter(north,[north]), "power loss uses flashing red, blank pedestrian heads and mandatory stop")
	model.advance(1.1)
	_check(model.may_enter(north,[north]) and model.mobility_factor(key) < .5, "outage all-way-stop and degraded-road speed policy both affect traffic")
	model.set_district_services([{"id":district,"infrastructure":{"power_ratio":1.0,"mobility_ratio":1.0}}])
	_check(model.display(key).stage == 8 and not model.may_enter(north,[north]), "power restoration waits in all-red before releasing traffic")
	model.advance(3.1)
	_check(model.display(key).north_south == "green", "normal signals recover only after their full buffer")
	var signs := Signals.new()
	add_child(signs)
	signs.controller = model
	signs.rebuild(key)
	var exact := true
	var optical := true
	for stage in range(9):
		model.ensure(key).stage = stage
		model.ensure(key).elapsed = .75
		signs.update_displays()
		exact = exact and signs.displayed_state(key) == model.display(key)
		var ns_lens := 2 if stage == 0 else 1 if stage == 1 else 0
		var ew_lens := 2 if stage == 3 else 1 if stage == 4 else 0
		optical = optical and signs.emitted_lenses(key,Vector2i.UP) == [ns_lens,ns_lens] and signs.emitted_lenses(key,Vector2i.RIGHT) == [ew_lens,ew_lens]
		var pedestrian_output := signs.emitted_pedestrian(key)
		optical = optical and (pedestrian_output.walk > 0 if stage == 6 else pedestrian_output.walk == 0) and (pedestrian_output.hand == 0 if stage in [6,7] else pedestrian_output.hand > 0)
	_check(exact, "rendered lens/walk/countdown data matches actor controller in every phase")
	_check(optical, "actual emitted lamp commands illuminate only the permitted lens on both heads and the correct pedestrian symbol")
	_check(signs.stats().junctions <= Traffic.MAX_JUNCTIONS and signs.stats().draw_batches <= 13, "signals/signs remain bounded to 81 nearby junctions and 13 instanced draws")
	signs.free()


func _fleet_population() -> void:
	var monkey := Monkeys.pose("walk",0,0)
	print("CANONICAL_MONKEY "+JSON.stringify(Monkeys.report("walk",0)))
	_check(monkey.get_meta("canonical_model")=="MonkeyRig" and monkey.get_meta("source_meshes")>40,"canonical population mesh bakes the original player monkey anatomical surfaces")
	var provenance: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/generated/city_monkey_walk.json"))
	_check(provenance.source_sha256==FileAccess.get_sha256("res://scripts/monkey_rig.gd") and provenance.pose_sha256==FileAccess.get_sha256("res://scripts/city_monkey_models.gd") and provenance.atlas_sha256==FileAccess.get_sha256("res://assets/generated/city_monkey_walk.png"),"cached distant atlas verifies provenance against the exact current player rig and canonical pose source")
	var distinct := {}
	var cabin_fit := true
	var solid_bounds := true
	var stop_fit := true
	var wheels_fit := true
	var turn_clear := true
	for index in range(Fleet.CATALOG.size()):
		var s := Fleet.spec(index)
		distinct[Vector3(s.width,s.height,s.length)] = true
		for height in [MonkeyRig.NPC_MIN_HEIGHT,MonkeyRig.PLAYER_HEIGHT,MonkeyRig.NPC_MAX_HEIGHT]:
			var driver := Fleet.driver_model(index,height)
			var fits := Fleet.cabin_bounds(index).encloses(driver.report.bounds)
			if not fits: print("DRIVER_FIT_FAIL "+str(index)+" "+str(height)+" "+str(driver.report))
			cabin_fit = cabin_fit and fits and driver.report.source_meshes==55
			var windows := Fleet.window_bounds(index)
			var through_glass := false
			for surface in range(driver.mesh.get_surface_count()):
				var arrays: Array = driver.mesh.surface_get_arrays(surface)
				for vertex: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
					vertex += Vector3(driver.report.offset)
					if vertex.y<=windows.position.y: continue
					var progress := clampf((vertex.y-windows.position.y)/windows.size.y,0,1)
					if absf(vertex.x)>lerpf(windows.size.x*.5+.06,windows.size.x*.5,progress)-.01 or vertex.z<windows.position.z+.30*progress or vertex.z>windows.end.z-.25*progress: through_glass = true
			if through_glass: print("DRIVER_GLASS_FAIL "+str(index)+" "+str(height))
			cabin_fit = cabin_fit and not through_glass
			for limb in [&"hand_left",&"hand_right",&"foot_left",&"foot_right"]:
				var error := Vector3(driver.points[limb]).distance_to(driver.report.targets[limb])
				if error>=.09: print("DRIVER_REACH_FAIL "+str(index)+" "+str(height)+" "+str(limb)+" "+str(error))
				cabin_fit = cabin_fit and error<.09
		var mesh := Fleet.mesh(index)
		var bounds := mesh.get_aabb()
		solid_bounds = solid_bounds and bounds.size.x <= float(s.width)+.25 and bounds.size.z <= float(s.length)+.10 and bounds.size.y <= float(s.height)+.30
		wheels_fit = wheels_fit and float(s.wheelbase)*.5+Fleet.wheel_radius(index) < float(s.length)*.5
		var key := Vector2i(32,30)
		var front := Traffic.stop_point(key,Vector2i.UP,float(s.length))+Vector2.UP*float(s.length)*.5
		var bar := Traffic.point(key)+Vector2.DOWN*(Traffic.cross_half(key,Vector2i.UP)+Traffic.STOP_BAR_OFFSET)+Traffic.right(Vector2i.UP)*Traffic.lane_offset(key,Vector2i.UP)
		stop_fit = stop_fit and (bar-front).dot(Vector2.UP) >= .349
		for outgoing in [Vector2i.LEFT,Vector2i.RIGHT]:
			var route := Traffic.turn_path(key-Vector2i.UP,key,key+outgoing,float(s.length))
			var parcels: Array = []
			for block in Plan.blocks_near(Vector3(Traffic.point(key).x,Plan.GROUND_Y,Traffic.point(key).y),1): parcels.append_array(Plan.block_buildings(block))
			for step in range(route.size()-1):
				var forward := (route[step+1]-route[step]).normalized()
				var side := Vector2(-forward.y,forward.x)
				for x in [-1.0,1.0]:
					for z in [-1.0,1.0]:
						var corner: Vector2 = route[step]+forward*float(s.length)*.5*z+side*float(s.width)*.5*x
						for building in parcels:
							var offset := corner-Vector2(building.position.x,building.position.z)
							turn_clear = turn_clear and (absf(offset.x)>=float(building.size.x)*.5+.10 or absf(offset.y)>=float(building.size.z)*.5+.10)
	_check(Ambient._pedestrian_mesh().get_meta("canonical_model") == "MonkeyRig","distant and near residents derive from the identical original player monkey model")
	_check(distinct.size() == 10,"ten distinct metre-scale car, SUV, pickup, cargo, taxi and shuttle proportions")
	_check(cabin_fit,"every seated driver fits completely below the roof and inside the transparent cabin")
	_check(solid_bounds and wheels_fit,"fleet body details and actual wheelbase remain within measured vehicle envelopes")
	_check(stop_fit,"all ten lengths place their front bumper before the same painted stop bar")
	_check(turn_clear,"rotated corners of every vehicle class clear real building parcels on left and right turns")
	var showroom := Node3D.new()
	add_child(showroom)
	Fleet.build(showroom,7,Color.WHITE,true,false)
	_check(showroom.get_child_count() <= 11 and showroom.get_meta("vehicle_class") == "delivery_van","shared fleet builder supports bounded empty-cabin dealership and owned-car models")
	showroom.free()
	var manager := Crowd.new()
	add_child(manager)
	manager.set_process(false)
	manager.set_physics_process(false)
	manager.update_focus(Vector3(Plan.CENTER.x+Plan.STREET_SPACING.x*6,Plan.GROUND_Y+1,Plan.CENTER.y))
	var population: Node3D = manager.ambient
	while not population.ready_city: population.stage(128)
	var initial: Dictionary = population.stats()
	_check(initial.cars >= 4000 and initial.pedestrians >= 20000 and initial.draw_batches <= 170 and initial.walker_spatial_batches > 100,"whole city population contains thousands of cars and over twenty thousand sidewalk residents in bounded spatial batches")
	var districts := {}
	var outside_park := true
	for state in population.vehicles:
		districts[Plan.district_for_block(Plan.world_to_block(state.at))] = true
		outside_park = outside_park and not Plan.is_park(state.at) and Traffic.edge_allowed(state.road_from,state.road_to)
	_check(districts.size() == 12 and outside_park,"moving traffic reaches every district and stays on legal roads outside the park")
	var lane_members: Dictionary = {}
	var spacing_safe := true
	var busy_lanes := 0
	for state in population.vehicles:
		var lane := str(state.road_from)+":"+str(state.road_to)
		if not lane_members.has(lane): lane_members[lane] = []
		for previous in lane_members[lane]:
			spacing_safe = spacing_safe and state.at.distance_to(previous.at) >= (state.vehicle_length+previous.vehicle_length)*.5+Traffic.GAP
		lane_members[lane].append(state)
	for members in lane_members.values():
		if members.size()>1: busy_lanes += 1
	_check(spacing_safe and busy_lanes>100 and population.vehicles.size()<=Ambient.MAX_VEHICLES,"downtown receives distinct safely spaced persistent drivers without growing the citywide budget")
	var before: Vector2 = population.vehicles[0].at
	for frame in range(50):
		manager.traffic.advance(.1)
		population.advance(.1)
	_check(population.vehicles[0].at.distance_to(before)>0.01 and population.stats().moving_cars>1000,"citywide cars actually advance through the shared controller instead of being static roof-view props")
	manager.update_focus(Vector3(manager.focus.x,2000,manager.focus.z))
	population.advance(.1)
	_check(population.visible and population.stats().cars == initial.cars and population.stats().pedestrians == initial.pedestrians,"rooftop and aircraft altitude preserves the full moving population")
	manager.update_focus(Vector3(manager.focus.x,Plan.GROUND_Y+1,manager.focus.z))
	manager._promote_cars()
	var promoted := 0
	var duplicate := false
	for actor in manager.actors:
		if not actor.car: continue
		promoted += 1
		duplicate = duplicate or actor.ambient_state.physical != actor or actor.serial != actor.ambient_state.serial
	_check(promoted > 0 and promoted <= Crowd.MAX_CARS and not duplicate,"nearby promotion preserves persistent car identity and route without a duplicate visible actor")
	manager.update_focus(Vector3(manager.focus.x,2000,manager.focus.z))
	manager._promote_cars()
	_check(population.stats().physical_cars == 0 and population.stats().cars == initial.cars,"distant demotion returns the same cars to instancing rather than deleting traffic")
	manager.update_focus(Vector3(Plan.MAX_X+500,1700,Plan.CENTER.y))
	population.advance(.1)
	_check(population.visible and population.stats().cars==initial.cars and manager.actors.is_empty(),"aircraft outside the municipal edge keeps regional moving traffic visible without spawning off-road physical actors")
	manager.update_focus(Vector3(Plan.MAX_X+13000,1700,Plan.CENTER.y))
	_check(not population.visible,"population outside the regional skyline margin releases its rendering work")
	manager.free()

func _controlled_drivers() -> void:
	var cars := load("res://scripts/city_car.gd")
	var valid := true
	for index in range(Fleet.CATALOG.size()):
		var car: Vehicle = cars.new()
		car.configure_model(index)
		car.freeze = true
		add_child(car)
		car.set_physics_process(false)
		var rig := MonkeyRig.new()
		car.add_child(rig)
		rig.setup("Player fit",false)
		rig.set_standing_height(MonkeyRig.PLAYER_HEIGHT)
		rig.position = car.rider_root_offset
		rig.rotation.y = PI
		rig.set_vehicle_pose(car.rider_render_pose())
		for frame in range(40): rig.update_motion(.05,MonkeyRig.Anim.RIDE,Vector3.ZERO,true,Vector3.ZERO)
		var mesh := Monkeys.bake(rig)
		var model_transform := Transform3D(Basis(Vector3.UP,PI),Vector3(0,-.35,0))
		var to_model := model_transform.affine_inverse()*rig.transform
		var cabin := Fleet.cabin_bounds(index)
		var windows := Fleet.window_bounds(index)
		var this_fits := true
		for surface in range(mesh.get_surface_count()):
			var arrays: Array = mesh.surface_get_arrays(surface)
			for vertex: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
				vertex = to_model*vertex
				if not cabin.has_point(vertex): this_fits = false
				if vertex.y<=windows.position.y: continue
				var progress := clampf((vertex.y-windows.position.y)/windows.size.y,0,1)
				if absf(vertex.x)>lerpf(windows.size.x*.5+.06,windows.size.x*.5,progress)-.01 or vertex.z<windows.position.z+.30*progress or vertex.z>windows.end.z-.25*progress: this_fits = false
		for entry in [[&"hand_left",rig.paw_l],[&"hand_right",rig.paw_r],[&"foot_left",rig.foot_l],[&"foot_right",rig.foot_r]]:
			this_fits = this_fits and entry[1].global_position.distance_to(car.rider_target_global(entry[0]))<.09
		if not this_fits: print("CONTROLLED_DRIVER_FAIL "+str(index))
		valid = valid and this_fits
		car.free()
	_check(valid,"all ten actual CityCar player rigs fit their sloped cabins with four seated control contacts through the render adapter")

func _catalog() -> void:
	var entries := Catalog.catalog_entries()
	var sorted := true
	for i in range(1,entries.size()): sorted = sorted and str(entries[i-1].label).naturalnocasecmp_to(str(entries[i].label)) <= 0
	_check(entries.size()==15 and sorted,"vehicle delivery catalog includes all fifteen machines sorted A–Z")
	_check(Catalog.matching_entries("sedan").size()==1 and Catalog.matching_entries("boat").size()==2 and Catalog.matching_entries("does not exist").is_empty(),"catalog search matches real names/types and handles empty results")
	var panel := Catalog.new()
	add_child(panel)
	panel._filter("van")
	_check(panel.test_report().visible_ids == ["delivery_van"],"catalog filtering controls actual tile visibility")
	panel.free()

func _incidents() -> void:
	var model := Traffic.new()
	var key := Vector2i(32,30)
	var center := (Traffic.point(key)+Traffic.point(key+Vector2i.UP))*.5
	model.set_incidents([{"point":Vector3(center.x,Plan.GROUND_Y,center.y),"active":true}])
	_check(not model.edge_open(key,key+Vector2i.UP) and model.choose_open_next(key+Vector2i.DOWN,key,17) != key+Vector2i.UP,"active incidents close affected street edges and reroute new traffic")
	var car := _vehicle(key,Vector2i.UP,Vector2i.UP)
	car.at = center+Vector2.DOWN*44
	_check(model.incident_speed_limit(car,Vector2.UP,8.0)<4 and model.incident_speed_limit(car,Vector2.DOWN,8.0)==8.0,"cars brake before the forty-metre response zone while traffic moving away can clear")
	model.set_incidents([])
	_check(model.edge_open(key,key+Vector2i.UP),"resolved incidents restore the legal road graph")

func _physical() -> void:
	var saved_tick_rate := Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = 240
	var manager := Crowd.new()
	manager.set_process(false)
	manager.set_physics_process(false)
	add_child(manager)
	var key := Vector2i(36,34)
	var actor := Crowd.StreetActor.new()
	actor.manager = manager
	actor.car = true
	actor.serial = 700
	actor.road_from = key - Vector2i.UP
	actor.road_to = key
	actor.road_next = key + Vector2i.UP
	var p := Traffic.stop_point(key,Vector2i.UP) + Vector2.DOWN*10
	actor.position = Vector3(p.x,Plan.GROUND_Y-.03,p.y)
	manager.add_child(actor)
	manager.actors.append(actor)
	actor.build()
	actor.set_physics_process(false)
	manager.traffic.ensure(key).stage = 3
	var follower := Crowd.StreetActor.new()
	follower.manager = manager
	follower.car = true
	follower.serial = 701
	follower.road_from = actor.road_from
	follower.road_to = key
	follower.road_next = actor.road_next
	follower.position = actor.position + Vector3(0,0,7.2)
	manager.add_child(follower)
	manager.actors.append(follower)
	follower.build()
	follower.set_physics_process(false)
	await get_tree().physics_frame
	for frame in range(600):
		actor._drive(1.0/60.0)
		follower._drive(1.0/60.0)
		await get_tree().physics_frame
	_check(not actor.committed and actor.position_2d().distance_to(Traffic.stop_point(key,Vector2i.UP,actor.vehicle_length)) < .05 and actor.speed < .05, "actual CharacterBody brakes to the red stop line and stays outside the crosswalk")
	_check(follower.position.z - actor.position.z >= (actor.vehicle_length+follower.vehicle_length)*.5 + Traffic.GAP - .05 and follower.speed < .05, "two actual physics cars queue with a safe bumper gap at red")
	manager.traffic.ensure(key).stage = 0
	for frame in range(1200):
		actor._physics_process(1.0/60.0)
		follower._physics_process(1.0/60.0)
		await get_tree().physics_frame
	_check(actor.trips >= 1 and actor.position_2d().distance_to(p) > 20, "actual vehicle clears a green junction and continues onto the next graph edge")
	_check(follower.trips >= 1, "queued physical follower is released after its leader clears the intersection")
	manager.traffic.release_car(follower.road_to,follower.serial)
	manager.actors.erase(follower)
	follower.free()
	# Put an actual physics obstacle ahead of an independent car; no actor-list shortcut.
	actor.committed = false
	actor.road_from = key - Vector2i.UP
	actor.road_to = key
	actor.road_next = key + Vector2i.UP
	actor.position = Vector3(p.x,Plan.GROUND_Y-.03,p.y)
	actor.speed = 0
	actor.rotation.y = 0
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3,3,1)
	shape.shape = box
	wall.add_child(shape)
	wall.position = actor.position + Vector3(0,1.0,-5.0)
	add_child(wall)
	await get_tree().physics_frame
	for frame in range(600): actor._drive(1.0/60.0)
	_check(actor.position.z > wall.position.z + 2.5 and actor.speed < .05, "physical sweep brakes for a real obstacle without phasing or snapping around it")
	wall.free()
	manager.actors.erase(actor)
	actor.free()
	for outgoing in [Vector2i.RIGHT,Vector2i.LEFT]:
		manager.traffic.junctions.clear()
		var turning := Crowd.StreetActor.new()
		turning.manager = manager
		turning.car = true
		turning.serial = 800
		turning.road_from = key - Vector2i.UP
		turning.road_to = key
		turning.road_next = key + outgoing
		var start := Traffic.stop_point(key,Vector2i.UP,float(Fleet.spec(0).length))
		turning.position = Vector3(start.x,Plan.GROUND_Y-.03,start.y + (20.0 if outgoing.x > 0 else 0.0))
		turning.speed = 7.5 if outgoing.x > 0 else 0.0
		manager.add_child(turning)
		manager.actors.append(turning)
		turning.build()
		turning.set_physics_process(false)
		await get_tree().physics_frame
		var peak_turn_speed := 0.0
		for frame in range(1200):
			turning._physics_process(1.0/60.0)
			if turning.committed: peak_turn_speed = maxf(peak_turn_speed,turning.speed)
			if turning.trips > 0: break
		_check(turning.trips == 1 and turning.position_2d().distance_to(Traffic.exit_point(key,outgoing,turning.vehicle_length)) < .10 and peak_turn_speed <= 3.50, "physical %s turn follows its curve into the correct outgoing lane at turning speed" % ("right" if outgoing.x > 0 else "left"))
		manager.actors.erase(turning)
		turning.free()
	manager.traffic.junctions.clear()
	var pedestrian := Crowd.StreetActor.new()
	pedestrian.manager = manager
	pedestrian.serial = 900
	pedestrian.is_crosser = true
	pedestrian.crossing_key = key
	var crossing := Traffic.crossing(key,Vector2i.DOWN)
	for location in [crossing[0]+Vector2.DOWN*9,crossing[0],crossing[1],crossing[1]+Vector2.DOWN*9]: pedestrian.path.append(Vector3(location.x,Plan.GROUND_Y+.03,location.y))
	pedestrian.position = pedestrian.path[1]
	pedestrian.target = 1
	manager.add_child(pedestrian)
	manager.actors.append(pedestrian)
	pedestrian.build()
	pedestrian.set_physics_process(false)
	manager.traffic.ensure(key).stage = 6
	manager.traffic.ensure(key).elapsed = 0.0
	await get_tree().physics_frame
	var continued_clearance := false
	for frame in range(1800):
		manager.traffic.advance(1.0/60.0)
		pedestrian._walk(1.0/60.0)
		if manager.traffic.display(key).pedestrian == "clearance" and pedestrian.crossing_active: continued_clearance = true
	_check(continued_clearance and not pedestrian.crossing_active and manager.traffic.ensure(key).pedestrians.is_empty(), "physical pedestrian starts on WALK, continues through flashing hand, and releases only after reaching the far curb")
	manager.free()
	Engine.physics_ticks_per_second = saved_tick_rate
	_physical_finished = true
