class_name FrontierTraffic
extends Node3D
## Server-owned road traffic. Only tire forces move an authoritative body.
## Interpolated client bodies never feed position or arrival into the economy.
const Routes = preload("res://scripts/frontier_routes.gd")
const Car = preload("res://scripts/frontier_vehicle.gd")
const MAX_CARS := 5
const STOP_SPEED := 0.35
const SERVICE_STOP_RADIUS := 1.7
const CRUISE_SPEED := 6.0
const WHEELBASE := 2.79

var simulation: RefCounted
var site: Node3D
var authority := true
var town_id := "canopy"
var vehicles: Dictionary = {}
var drivers: Dictionary = {}
var _external_obstacles: Array = []
var _clock := 0.0
var _report_clock := 0.0
var _sync_clock := 0.0
var _junction_owners: Dictionary = {}
var _obstacle_shape: BoxShape3D
var _built := false
var _junction_points: Array[Vector2] = []
var _queries: Dictionary = {}
var _obstacle_cache: Dictionary = {}
var _boarding_queries: Dictionary = {}


func configure(model: RefCounted, frame: Node3D, authoritative := true, society_id := "canopy") -> void:
	simulation = model
	site = frame
	authority = authoritative
	town_id = society_id
	if is_instance_valid(site): site.set_meta("frontier_traffic", self)
	# Drivers choose inputs before their child bodies step tire forces.
	process_physics_priority = -5


func build() -> void:
	if _built:
		return
	_built = true
	_obstacle_shape = BoxShape3D.new()
	_obstacle_shape.size = Vector3(1.95, 1.2, 3.4)
	_junction_points = Routes.junctions()
	if authority:
		# Parked cars remain owned assets after their owner changes profession.
		# Restore those bodies before assigning any newly available fleet slots.
		for id in simulation.state.get("traffic",{}):
			if vehicles.size()>=MAX_CARS: break
			if simulation.state.citizens.has(id) and simulation.state.citizens[id].planet=="earth":
				_spawn(str(id),simulation.state.citizens[id])
		_sync_workers()
	set_physics_process(true)


## Remote players on the dedicated server have no character bodies. Their
## authenticated last positions enter the same braking envelope as collisions.
## rows: world Vector3, or {position:Vector3, radius:float}; bounded to 128.
func set_obstacles(points: Array) -> void:
	_external_obstacles = points.slice(0, 128)


func vehicle_for(citizen_id: String) -> Vehicle:
	return vehicles.get(citizen_id) as Vehicle if str(drivers.get(citizen_id,{}).get("mode","driving")) not in ["walking","boarding"] else null


func _sync_workers() -> void:
	if simulation == null or not authority:
		return
	var citizens: Dictionary = simulation.state.get("citizens", {})
	var ids: Array = citizens.keys()
	ids.sort()
	# Professional road crews first, then practical/ordinary commuting workers.
	ids.sort_custom(func(a, b): return _priority(citizens[a]) < _priority(citizens[b]) if _priority(citizens[a]) != _priority(citizens[b]) else str(a) < str(b))
	for id in ids:
		var worker: Dictionary = citizens[id]
		if str(worker.get("planet","earth")) != "earth" or _priority(worker) >= 10:
			continue
		if vehicles.has(id):
			continue
		if vehicles.size() >= MAX_CARS:
			break
		_spawn(str(id), worker)


func _priority(worker: Dictionary) -> int:
	match str(worker.get("job", "")):
		"tanker_driver": return 0
		"hauler", "freight_hauler": return 1
		"mechanic": return 2
		"citizen": return 3
		_: return 10


func _bay(worker: Dictionary, fallback: Vector2) -> Vector2:
	var target := str(worker.get("target",""))
	if str(worker.get("job","")) in ["mechanic","citizen"] and Routes.service_parking_bays().has(target):
		return Routes.service_parking_bays()[target]
	return Routes.loading_bays().get(target,fallback)


func _point(xz: Vector2) -> Vector3:
	if site.has_method("surface_point"):
		return site.surface_point(xz.x, xz.y)
	return site.to_global(Vector3(xz.x, site.surface_height(xz.x, xz.y), xz.y))


func _local(world_point: Vector3) -> Vector2:
	var point := site.to_local(world_point)
	return Vector2(point.x, point.z)


func _spawn(id: String, worker: Dictionary, initial: Dictionary = {}) -> void:
	var saved: Dictionary=simulation.state.get("traffic",{}).get(id,{}) if authority else initial
	var saved_mode := str(saved.get("mode","driving"))
	if authority and saved_mode!="walking":
		simulation.enable_physical_transport(id, "npc:%s:%s" % [town_id,id])
	var car := Car.new()
	car.site = site
	car.worker_id = id
	car.profession = str(worker.get("job", "citizen"))
	car.setup("npc:%s:%s" % [town_id,id], null)
	add_child(car)
	vehicles[id] = car
	var local := Routes._vector(worker.get("position", [0,4]))
	if authority and not simulation.state.get("traffic", {}).get(id, {}).has("pose"):
		var nearest_bay := local
		var nearest_distance := INF
		for bay: Vector2 in Routes.loading_bays().values():
			if local.distance_squared_to(bay) < nearest_distance:
				nearest_distance = local.distance_squared_to(bay)
				nearest_bay = bay
		if nearest_distance < 144.0:
			local = nearest_bay
		# Shift only initial spawns into separate forecourt spaces. Once a body
		# exists, collisions/braking own it and this code is never revisited.
		for attempt in range(MAX_CARS):
			var occupied := false
			for other_id in vehicles:
				if other_id != id and _local(vehicles[other_id].global_position).distance_to(local) < 5.8:
					occupied = true
			if not occupied: break
			local += Vector2(0, 5.8)
	var goal := _bay(worker,local)
	var route := Routes.driving_path(local, goal)
	var heading := Vector2(0,1)
	var longest := 0.0
	for segment: Dictionary in Routes.road_segments():
		var a: Vector2 = segment["from"]
		var b: Vector2 = segment.to
		var length := a.distance_to(b)
		if length > longest and minf(local.distance_to(a),local.distance_to(b)) < 8.0:
			heading = (b-a).normalized() if local.distance_to(a)<local.distance_to(b) else (a-b).normalized()
			longest = length
	if route.size() >= 2 and route[1].distance_to(local) > 0.1:
		heading = (route[1] - local).normalized()
	# Spawn on the departure lane, separated from workers standing at a dock's
	# centerline. Restored vehicles retain their exact persisted transform.
	if authority and not simulation.state.get("traffic", {}).get(id, {}).has("pose"):
		local += Vector2(-heading.y,heading.x)*Routes.LANE_OFFSET
	# A one-time initial placement is a spawn, never a blocked-route recovery.
	var pose: Dictionary = initial
	if authority:
		pose = simulation.state.get("traffic", {}).get(id, {}).get("pose", {})
	if pose.has("position") and _valid_vector(pose.position):
		car.global_position = Vector3(pose.position[0], pose.position[1], pose.position[2])
		if _valid_vector(pose.get("rotation", [])):
			car.global_rotation = Vector3(pose.rotation[0], pose.rotation[1], pose.rotation[2])
		if _valid_vector(pose.get("velocity", [])):
			car.linear_velocity = Vector3(pose.velocity[0], pose.velocity[1], pose.velocity[2])
	else:
		car.settle_at(_point(local), atan2(heading.x, heading.y) + site.global_rotation.y)
	var context := {"mode":"walking" if saved_mode in ["walking","boarding"] else "driving", "boarding_route":[], "route":[], "index":0, "epoch":-1, "stopped":0.0,
		"stop_junction":-1, "stop_timer":0.0, "cleared":{}, "blocker":"",
		"reverse_time":0.0, "reverse_sign":1.0, "recovery_cooldown":0.0, "turnaround_epoch":-1, "blocked_turn_time":0.0,
		"desired_speed":0.0, "fuel_stop":false, "fuel_retry":0.0, "traveled":0.0, "previous":car.global_position}
	drivers[id] = context
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _obstacle_shape
	query.collision_mask = 1
	query.exclude = [car.get_rid()]
	_queries[car.get_instance_id()] = query
	var boarding_query := PhysicsRayQueryParameters3D.new()
	boarding_query.collision_mask=1
	boarding_query.exclude=[car.get_rid()]
	_boarding_queries[id]=boarding_query
	if authority:
		car.configure_frontier_fuel(simulation)
		if context.mode=="driving":
			var driver := Node3D.new()
			driver.name = "AuthoritativeDriver"
			car.add_child(driver)
			car.begin_drive(driver)
			simulation.enable_physical_transport(id, car.vid)
		else:
			car.set_inputs(0,1,0,true,false)
			car.freeze=true
			car.linear_velocity=Vector3.ZERO
			car.angular_velocity=Vector3.ZERO
	else:
		car.set_remote_controlled(true)
		car.collision_layer = 1
		car.collision_mask = 1


func _physics_process(dt: float) -> void:
	if not _built or simulation == null or not is_instance_valid(site):
		return
	_clock += dt
	if not authority:
		return
	_sync_clock += dt
	if _sync_clock >= 1.0:
		_sync_clock = 0.0
		_sync_workers()
	_report_clock += dt
	var report := _report_clock >= 0.2
	if report: _report_clock = 0.0
	for id in vehicles:
		if not simulation.state.citizens.has(id):
			continue
		var worker: Dictionary = simulation.state.citizens[id]
		var car: Vehicle = vehicles[id]
		var context: Dictionary = drivers[id]
		if _priority(worker)>=10 and worker.get("carrying",{}).is_empty():
			if str(context.mode)!="walking": _park_worker(id,car,worker,context)
			car.update_manifest({})
			if simulation.state.get("traffic",{}).has(id):
				simulation.state.traffic[id].pose=_pose(car)
			continue
		if str(context.mode)=="walking": _start_boarding(id,car,worker,context)
		if str(context.mode)=="boarding":
			_walk_to_car(id,car,worker,context,dt)
			if str(context.mode)=="boarding": continue
		_drive(id, car, worker, context, dt)
		car.update_manifest(worker.get("carrying", {}))
		if report:
			var xz := _local(car.global_position)
			simulation.report_physical_transport(id, [xz.x,xz.y], car.speed(),
				float(context.stopped) >= 0.5 and not bool(context.fuel_stop), str(context.blocker), int(context.epoch))
			if simulation.state.get("traffic", {}).has(id):
				simulation.state.traffic[id].pose = _pose(car)


func _park_worker(id: String, car: Vehicle, worker: Dictionary, context: Dictionary) -> void:
	car.set_inputs(0,1,0,true,false)
	var boarding := str(context.mode)=="boarding"
	var local := Routes._vector(worker.position) if boarding else _local(car.global_position)
	simulation.report_physical_transport(id,[local.x,local.y],0.0 if boarding else car.speed(),false,"Parking before changing profession",int(worker.get("motion_epoch",0)))
	if car.speed()>=STOP_SPEED: return
	# Cancelling a return walk leaves the person where they actually walked.
	var exit_point := local if boarding else _local(car._pick_exit_position())
	if not simulation.disable_physical_transport(id,[exit_point.x,exit_point.y]): return
	if car.driver!=null: car.end_drive()
	context.mode="walking"
	context.stopped=0.0
	context.epoch=-1
	context.fuel_stop=false
	context.blocker="Parked while its owner works on foot"


func _start_boarding(id: String, car: Vehicle, worker: Dictionary, context: Dictionary) -> void:
	var entry := _local(car._pick_exit_position())
	context.mode="boarding"
	context.boarding_route=Routes.path(worker.position,[entry.x,entry.y],"earth")
	if context.boarding_route.is_empty(): context.boarding_route=[[entry.x,entry.y]]
	simulation.enable_physical_transport(id,car.vid)
	worker.route=context.boarding_route.duplicate(true)
	context.blocker="Walking back to the parked vehicle"
	if simulation.state.get("traffic",{}).has(id):
		simulation.state.traffic[id]["mode"]="boarding"
		simulation.state.traffic[id].arrived=false
		simulation.state.traffic[id].epoch=-1


func _walk_to_car(id: String, car: Vehicle, worker: Dictionary, context: Dictionary, dt: float) -> void:
	var position := Routes._vector(worker.position)
	var previous := position
	var route: Array=context.boarding_route
	if not route.is_empty():
		var target := Routes._vector(route[0])
		context.blocker="Walking back to the parked vehicle"
		if position.distance_to(target)>0.15:
			# A boarding worker is a pedestrian even if their new job is tanker
			# driver. Test the real server physics, excluding only their own car
			# so its doorway cannot be mistaken for a road-width obstruction.
			var query: PhysicsRayQueryParameters3D=_boarding_queries[id]
			var sideways := Vector2(-(target-position).y,(target-position).x).normalized()*0.28
			var blocked := false
			for offset: float in [-1.0,0.0,1.0]:
				var start := position+sideways*offset
				var finish := position.move_toward(target,0.9)+sideways*offset
				query.from=_point(start)+Vector3.UP*0.95
				query.to=_point(finish)+Vector3.UP*0.95
				if not car.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
					blocked=true
					break
			if blocked: context.blocker="Waiting for a clear walk to the parked vehicle"
			else: position=position.move_toward(target,2.6*dt)
		else:
			route.pop_front()
		worker.route=route.duplicate(true)
		simulation.report_physical_transport(id,[position.x,position.y],position.distance_to(previous)/maxf(dt,0.001),false,str(context.blocker),int(worker.get("motion_epoch",0)))
		return
	if car.speed()>=STOP_SPEED: return
	var driver: Node3D=car.get_node_or_null("AuthoritativeDriver")
	if driver==null:
		driver=Node3D.new()
		driver.name="AuthoritativeDriver"
		car.add_child(driver)
	car.begin_drive(driver)
	context.mode="driving"
	context.epoch=-1
	context.previous=car.global_position
	context.stopped=0.0
	context.blocker=""
	simulation.state.traffic[id]["mode"]="driving"


func _drive(id: String, car: Vehicle, worker: Dictionary, context: Dictionary, dt: float) -> void:
	var position := _local(car.global_position)
	context.traveled += car.global_position.distance_to(context.previous)
	context.previous = car.global_position
	context.recovery_cooldown = maxf(0.0, float(context.recovery_cooldown)-dt)
	var epoch := int(worker.get("motion_epoch",0))
	var fuel: Dictionary = simulation.state.get("vehicle_fuel",{}).get(car.vid,{})
	var start_fueling: bool = not bool(context.fuel_stop) and float(fuel.get("fuel_l",100.0)) < 6.0 and not worker.get("_job",{}).is_empty()
	if start_fueling: context.fuel_stop = true
	if epoch != int(context.epoch) or start_fueling:
		var destination := Routes._vector(worker.get("destination",worker.position))
		var bay: Vector2 = Routes.loading_bays().get("gas_station") if bool(context.fuel_stop) else _bay(worker,destination)
		context.route = Routes.driving_path(position, bay)
		context.index = 1 if context.route.size() > 1 else 0
		context.epoch = epoch
		context.stopped = 0.0
		context.cleared = {}
		context.stop_junction = -1
		context.stop_timer = 0.0
		context.reverse_time = 0.0
	var route: Array = context.route
	if route.is_empty() or worker.get("_job", {}).is_empty():
		car.set_inputs(0, 1, 0, true, false)
		context.blocker = "Parked between assignments"
		return
	# Tire slip/turn radius can put the body beside a later curve segment. Find
	# its nearest upcoming segment instead of steering back into a past corner.
	# Only route progress changes here; chassis motion remains physical.
	var best_distance := INF
	var nearest_segment := int(context.index)
	for index in range(maxi(1,int(context.index)),mini(route.size(),int(context.index)+9)):
		var projected := Geometry2D.get_closest_point_to_segment(position,route[index-1],route[index])
		var distance := position.distance_squared_to(projected)
		if distance+0.02 < best_distance:
			best_distance=distance
			nearest_segment=index
	if best_distance<25.0:
		context.index=maxi(int(context.index),nearest_segment)
	# Advance waypoints only by real proximity/projection. The look-ahead target
	# can skip curve samples, but never advances the authoritative rigid body.
	while int(context.index) < route.size()-1:
		var index: int = context.index
		var segment: Vector2 = route[index] - route[maxi(index-1,0)]
		if position.distance_to(route[index]) < 1.7 or (position-route[index]).dot(segment) > 0.0:
			context.index += 1
		else:
			break
	var remaining := position.distance_to(route[int(context.index)])
	for index in range(int(context.index), route.size()-1):
		remaining += (route[index] as Vector2).distance_to(route[index+1])
	var endpoint: Vector2 = route.back()
	context["remaining"] = remaining
	context["endpoint_gap"] = position.distance_to(endpoint)
	var arrived := position.distance_to(endpoint) <= SERVICE_STOP_RADIUS and int(context.index) >= route.size()-1
	context.stopped = float(context.stopped) + dt if arrived and car.speed() < STOP_SPEED else 0.0
	if arrived:
		car.set_inputs(0, 1, 0, true, false)
		context.blocker = ""
		context.desired_speed = 0.0
		if bool(context.fuel_stop):
			context.blocker = "Refueling at the village station"
			context.fuel_retry = maxf(0.0,float(context.fuel_retry)-dt)
			if float(context.stopped)>=0.5 and float(context.fuel_retry)<=0.0:
				context.fuel_retry=5.0
				simulation.report_physical_transport(id,[position.x,position.y],car.speed(),false,"Refueling",epoch)
				var quantity := mini(12,mini(simulation.stock("gas_station","gasoline"), int(floor(float(fuel.get("capacity_l",65.0))-float(fuel.get("fuel_l",0.0))))))
				var result: Dictionary = simulation.refuel_transport(id,"gas_station",quantity)
				if bool(result.get("ok",false)):
					context.fuel_stop=false
					context.epoch=-1
					context.stopped=0.0
				else:
					context.blocker=str(result.get("message","Fuel service unavailable"))
		return
	var look_distance := clampf(3.5 + car.speed()*0.8, 3.5, 8.0)
	var target: Vector2 = route[int(context.index)]
	var closest := Geometry2D.get_closest_point_to_segment(position, route[maxi(int(context.index)-1,0)], target)
	var accumulated := closest.distance_to(target)
	if accumulated > look_distance:
		target = closest.move_toward(target,look_distance)
	for index in range(int(context.index), route.size()-1):
		if accumulated >= look_distance: break
		var length: float = (route[index] as Vector2).distance_to(route[index+1])
		if accumulated+length >= look_distance:
			target = (route[index] as Vector2).lerp(route[index+1], (look_distance-accumulated)/maxf(length,0.001))
			break
		accumulated += length
		target = route[index+1]
	var local_target := car.global_basis.inverse() * (_point(target)-car.global_position)
	var planar_distance := maxf(Vector2(local_target.x,local_target.z).length(), 1.0)
	var curvature := 2.0 * local_target.x / (planar_distance*planar_distance)
	var steer := clampf(atan(WHEELBASE*curvature)/car.max_steer_angle, -1.0, 1.0)
	var desired := minf(CRUISE_SPEED, sqrt(2.2/maxf(absf(curvature), 0.02)))
	desired = minf(desired, sqrt(2.0*2.2*maxf(remaining-0.75, 0.0)))
	var heading_error := atan2(local_target.x, local_target.z)
	context["heading_error"]=heading_error
	context["look_target"]=target
	if absf(heading_error) > 1.1:
		desired = minf(desired, 1.7)
	if absf(heading_error) > 1.85:
		desired = 0.0
	# A terminal loading bay requires a real three-point turn. Reverse uses an
	# explicit gear selection and rear collision probes, never a pose reset.
	if absf(heading_error) > 1.85 and car.speed() < 0.45 and float(context.recovery_cooldown) <= 0.0 and float(context.reverse_time) <= 0.0:
		# A queued vehicle behind us makes backing unsafe. Use the clear forward
		# apron for a turning circle instead, so two depot crews cannot deadlock
		# nose-to-tail while waiting to leave in opposite directions.
		if int(context.turnaround_epoch) != epoch and not str(_obstruction(car,true).reason).is_empty() and str(_obstruction(car,false).reason).is_empty():
			var forward3 := site.global_basis.inverse()*car.global_basis.z
			var forward := Vector2(forward3.x,forward3.z).normalized()
			var right := Vector2(forward.y,-forward.x)
			var radius := 4.8
			var start := position + forward*2.5
			var center := start + right*radius
			var turn: Array[Vector2] = [position,start]
			for sample in range(1,25):
				var angle := float(sample)/24.0*PI
				turn.append(center-right*cos(angle)*radius+forward*sin(angle)*radius)
			for index in range(int(context.index),route.size()): turn.append(route[index])
			context.route=turn
			context.index=1
			context.turnaround_epoch=epoch
			car.engine.gear=1
			car.set_inputs(0,1,0,false,false)
			return
		context.reverse_time = 3.0
		context.reverse_sign = -signf(heading_error)
	if float(context.reverse_time) > 0.0:
		if car.forward_speed() > 0.35:
			car.set_inputs(0,1,0,false,false)
			return
		car.engine.gear = -1
		context.reverse_time -= dt
		desired = 1.35
		steer = float(context.reverse_sign)
		if context.reverse_time <= 0.0:
			context.recovery_cooldown = 2.0
			car.set_inputs(0,1,0,false,false)
			return
	elif car.engine.gear < 1:
		if car.speed() > 0.35:
			car.set_inputs(0,1,0,false,false)
			return
		car.engine.gear = 1
	var reverse := car.engine.gear < 0
	var obstacle := _obstruction(car, reverse)
	var blocked := not str(obstacle.reason).is_empty()
	if blocked:
		desired = minf(desired, sqrt(2.0*2.5*maxf(float(obstacle.distance)-(0.75 if reverse else 2.4),0.0)))
		if float(obstacle.distance) < (1.2 if reverse else 4.0):
			desired = 0.0
		context.blocker = str(obstacle.reason)
	else:
		context.blocker = ""
	if not reverse:
		desired = minf(desired, _junction_speed(id, car, position, context, dt))
	if not car.has_drive_fuel():
		desired = 0.0
		context.blocker = "Waiting for fuel service"
	# If a turn has run out of front clearance, back out slowly into verified
	# rear clearance and retry the same route. A straight blocked road still
	# waits; this is not a teleport or a bypass through an obstacle.
	if blocked and not reverse and desired<0.05 and car.speed()<STOP_SPEED and absf(heading_error)>0.35:
		context.blocked_turn_time+=dt
		if float(context.blocked_turn_time)>2.0 and float(context.recovery_cooldown)<=0.0 and float(_obstruction(car,true).distance)>1.8:
			context.reverse_time=1.5
			context.reverse_sign=-signf(heading_error)
			context.blocked_turn_time=0.0
	else:
		context.blocked_turn_time=0.0
	var speed := absf(car.forward_speed())
	var throttle := clampf((desired-speed)*0.35+0.13, 0.0, 0.6) if desired > 0.05 else 0.0
	var brake := clampf((speed-desired)*0.6,0.0,1.0)
	if desired < 0.05: brake = 1.0
	car.set_inputs(throttle, brake, steer, desired < 0.05 and speed < 0.3, false)
	context.desired_speed = desired


func _obstruction(car: Vehicle, reverse: bool) -> Dictionary:
	var direction := car.global_basis.z * (-1.0 if reverse else 1.0)
	var distance := 5.0 + car.speed()*0.9 + car.speed()*car.speed()/5.0
	var nearest := distance
	var reason := ""
	var cache_key := str(car.get_instance_id())+("r" if reverse else "f")
	var cached: Dictionary = _obstacle_cache.get(cache_key,{})
	if not cached.is_empty() and _clock-float(cached.time)<0.10 and absf(car._steer_current-float(cached.steer))<0.12:
		var reused: Dictionary = cached.result.duplicate()
		reused.distance=maxf(0.0,float(reused.distance)-car.global_position.distance_to(cached.position))
		return reused
	var query: PhysicsShapeQueryParameters3D = _queries[car.get_instance_id()]
	var physics := car.get_world_3d().direct_space_state
	var sign_direction := -1.0 if reverse else 1.0
	var curvature := tan(car._steer_current)/WHEELBASE
	var steps := clampi(int(ceil(distance/1.7)),3,12)
	var step_length := distance/float(steps)
	var origin := car.global_position
	var yaw := 0.0
	var traveled := 0.0
	# Sweep along the current tire turning circle. A straight ray would leave
	# a turning car stopped forever beside a wall it was steering away from.
	for step in range(steps):
		var turn := curvature*step_length*sign_direction
		var frame := Basis(Vector3.UP,yaw+turn*0.5)*car.global_basis
		var motion := frame.z*step_length*sign_direction
		query.transform=Transform3D(frame,origin+Vector3.UP*0.7)
		query.motion=motion
		var touching := physics.intersect_shape(query,1)
		var fractions := physics.cast_motion(query)
		if not touching.is_empty() or (fractions.size()==2 and fractions[0]<1.0):
			nearest=traveled+(float(fractions[0])*step_length if touching.is_empty() else 0.0)
			reason="Yielding to traffic or an obstruction"
			break
		origin+=motion
		yaw+=turn
		traveled+=step_length
	var obstacles: Array = _external_obstacles.duplicate()
	# Walking townspeople have inexpensive model positions rather than server
	# render rigs. Treat their same live capsules as pedestrian right of way.
	for id in simulation.state.get("citizens", {}):
		var pedestrian: Dictionary = simulation.state.citizens[id]
		if vehicle_for(str(id))!=null or str(pedestrian.get("planet", "earth")) != "earth": continue
		var xz := Routes._vector(pedestrian.position)
		if _local(car.global_position).distance_squared_to(xz) < distance*distance:
			obstacles.append({"position":_point(xz)+Vector3.UP*0.8,"radius":0.4,"id":str(id)})
	for entry in obstacles:
		var point: Vector3 = entry if entry is Vector3 else entry.get("position", Vector3.INF)
		if not point.is_finite() or absf(point.y-car.global_position.y) > 3.0:
			continue
		var offset := point-car.global_position
		var ahead := offset.dot(direction)
		var side := absf(offset.dot(car.global_basis.x))
		var radius := 0.5 if entry is Vector3 else float(entry.get("radius",0.5))
		if ahead > -0.5 and ahead < nearest+2.0 and side < 0.9+radius:
			nearest = maxf(0.0,ahead-2.0-radius)
			reason = "Yielding to a pedestrian" + (" ("+str(entry.get("id","player"))+")" if entry is Dictionary else "")
	var result := {"distance":nearest,"reason":reason}
	_obstacle_cache[cache_key]={"time":_clock,"steer":car._steer_current,"position":car.global_position,"result":result}
	return result


func _junction_speed(id: String, car: Vehicle, position: Vector2, context: Dictionary, dt: float) -> float:
	var junctions := _junction_points
	for index in range(junctions.size()):
		var junction: Vector2 = junctions[index]
		var distance := position.distance_to(junction)
		var owner := str(_junction_owners.get(index,""))
		if owner != "" and (not vehicles.has(owner) or _local(vehicles[owner].global_position).distance_to(junction) > 9.0):
			_junction_owners.erase(index)
			owner = ""
		if distance > 11.0 or context.cleared.has(index): continue
		# Do not stop a vehicle which is already leaving this junction.
		var relative := car.global_basis.inverse()*(_point(junction)-car.global_position)
		if relative.z < 0.0 and owner != id: continue
		if owner == id:
			if relative.z < -3.0: context.cleared[index] = true
			return 3.0
		if distance < 7.5:
			if car.speed() < STOP_SPEED:
				context.stop_timer += dt
			if float(context.stop_timer) >= 0.6 and owner == "":
				_junction_owners[index] = id
				context.stop_timer = 0.0
				return 3.0
			context.blocker = "Yielding at the stop line"
			return 0.0
		return minf(3.0, sqrt(2.0*2.0*maxf(distance-7.0,0.0)))
	return CRUISE_SPEED


func _pose(car: Vehicle) -> Dictionary:
	var p := car.global_position
	var r := car.global_rotation
	var v := car.linear_velocity
	return {"position":[p.x,p.y,p.z],"rotation":[r.x,r.y,r.z],
		"velocity":[v.x,v.y,v.z],"rpm":car.engine.rpm_fraction(),"steer":car._steer_current}


func snapshot() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for id in vehicles:
		var row := _pose(vehicles[id])
		row.worker = id
		row.town = town_id
		row.blocker = drivers[id].blocker
		row.mode = str(drivers[id].get("mode","driving"))
		rows.append(row)
	return rows


func apply_snapshot(rows: Array) -> void:
	if authority or not _built:
		return
	for row in rows.slice(0,MAX_CARS):
		if not row is Dictionary or str(row.get("town",town_id)) != town_id or not _valid_vector(row.get("position",[])) or not _valid_vector(row.get("rotation",[])) or not _valid_vector(row.get("velocity",[])):
			continue
		var id := str(row.get("worker",""))
		if not simulation.state.get("citizens",{}).has(id): continue
		if not vehicles.has(id): _spawn(id,simulation.state.citizens[id],row)
		var car: Vehicle = vehicles[id]
		drivers[id].mode = str(row.get("mode","driving")) if str(row.get("mode","driving")) in ["driving","walking","boarding"] else "driving"
		var rotation: Array = row.rotation
		var basis := Basis.from_euler(Vector3(rotation[0],rotation[1],rotation[2]))
		var position := Vector3(row.position[0],row.position[1],row.position[2])
		car.apply_remote_state(position+basis*car.seat_offset,float(rotation[1]),
			Vector3(rotation[0],rotation[2],row.get("rpm",0.0)),Vector3(row.velocity[0],row.velocity[1],row.velocity[2]))
		car._steer_current = clampf(float(row.get("steer",0.0)),-car.max_steer_angle,car.max_steer_angle)
		for wheel in car.wheels: wheel.steer_angle = car._steer_current if wheel.steerable else 0.0
		car.update_manifest(simulation.state.citizens[id].get("carrying",{}))


static func _valid_vector(value: Variant) -> bool:
	return value is Array and value.size() == 3 and is_finite(float(value[0])) and is_finite(float(value[1])) and is_finite(float(value[2]))
