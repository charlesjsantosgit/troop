extends Node3D
## A bounded local road simulation. Census and economy remain authoritative.
const Plan = preload("res://scripts/city_plan.gd")
const Traffic = preload("res://scripts/city_traffic.gd")
const Signals = preload("res://scripts/city_traffic_signals.gd")
const Fleet = preload("res://scripts/city_vehicle_models.gd")
const ImpactEffects = preload("res://scripts/vehicle_impact_effects.gd")
const Monkeys = preload("res://scripts/city_monkey_models.gd")
const Ambient = preload("res://scripts/city_ambient_life.gd")
const MAX_PEDESTRIANS := 64
const MAX_CARS := 24
const RETIRE_DISTANCE := 260.0
const REGIONAL_VIEW_MARGIN := 12000.0
var civil_danger: Array[Vector3] = []
var focus := Vector3.INF
var _cohort := Vector2i(99999, 99999)
var _queue: Array = []
var actors: Array[CharacterBody3D] = []
var traffic := Traffic.new()
var signals: Node3D
var ambient: Node3D
var _promotion_clock := 0.0
var _spawn_clock := 0.0
var _refill_clock := 0.0
var _serial := 0

func update_focus(point: Vector3) -> void:
	focus = point
	var regional := point.is_finite() and point.y>=0.0
	if regional:
		var horizontal := Vector2(point.x,point.z)
		var nearest := horizontal.clamp(Vector2(Plan.MIN_X,Plan.MIN_Z),Vector2(Plan.MAX_X,Plan.MAX_Z))
		regional = horizontal.distance_to(nearest)<=REGIONAL_VIEW_MARGIN
	if regional and not is_instance_valid(ambient):
		ambient = Ambient.new()
		ambient.manager = self
		add_child(ambient)
	if is_instance_valid(ambient): ambient.visible = regional
	if not point.is_finite() or not Plan.contains(Vector2(point.x, point.z)) or point.y < 0.0:
		_queue.clear()
		for actor in actors: _retire(actor)
		actors.clear()
		if is_instance_valid(signals): signals.visible = false
		_cohort = Vector2i(99999, 99999)
		return
	var cell := Traffic.grid(Vector2(point.x, point.z))
	if cell == _cohort: return
	_cohort = cell
	for actor in actors.duplicate():
		if actor.position_2d().distance_to(Vector2(point.x,point.z)) > RETIRE_DISTANCE:
			_retire(actor)
			actors.erase(actor)
	if not is_instance_valid(ambient): traffic.prune(cell)
	if not is_instance_valid(signals):
		signals = Signals.new()
		add_child(signals)
		signals.controller = traffic
	signals.visible = true
	signals.rebuild(cell)
	_queue_spawns()

func _retire(actor: CharacterBody3D) -> void:
	actor.visible = false
	actor.set_physics_process(false)
	actor.collision_layer = 0
	actor.collision_mask = 0
	if actor.car and actor.ambient_state != null:
		actor.ambient_state.capture(actor)
		actor.ambient_state.physical = null
		if is_instance_valid(ambient) and ambient.ready_city: ambient._render_vehicle(actor.ambient_state)
	else:
		traffic.release_car(actor.road_to,actor.serial)
	traffic.release_pedestrian(actor.crossing_key,actor.serial)
	actor.queue_free()

func _queue_spawns() -> void:
	_queue.clear()
	for index in range(MAX_PEDESTRIANS * 3):
		var offset := Vector2i(posmod(index,3)-1,posmod(index/3,3)-1)
		_queue.append({"key":_cohort+offset,"car":false,"index":index})

func traffic_vehicles(actor: Variant) -> Array:
	return ambient.neighbors(actor.position_2d()) if is_instance_valid(ambient) and ambient.ready_city else actors

func _promote_cars() -> void:
	if not is_instance_valid(ambient) or not ambient.ready_city: return
	var near_ground := focus.y < Plan.GROUND_Y+75.0
	for actor in actors.duplicate():
		if not near_ground or (actor.car and actor.position_2d().distance_to(Vector2(focus.x,focus.z)) > RETIRE_DISTANCE):
			_retire(actor)
			actors.erase(actor)
	if not near_ground: return
	var car_count := 0
	for actor in actors:
		if actor.car: car_count += 1
	for state in ambient.candidates(focus,RETIRE_DISTANCE-25.0):
		if car_count >= MAX_CARS: break
		if is_instance_valid(state.physical) or state.finished: continue
		var actor := StreetActor.new()
		actor.manager = self
		actor.car = true
		actor.ambient_state = state
		state.restore(actor)
		add_child(actor)
		actors.append(actor)
		actor.build()
		state.physical = actor
		ambient._render_vehicle(state)
		car_count += 1

func _process(delta: float) -> void:
	if not focus.is_finite() or focus.y < 0.0 or not Plan.contains(Vector2(focus.x, focus.z)): return
	if is_instance_valid(ambient): ambient.stage()
	_promotion_clock -= delta
	if _promotion_clock <= 0.0:
		_promotion_clock = 1.0
		_promote_cars()
	if focus.y > Plan.GROUND_Y+75.0: return
	_refill_clock -= delta
	if _refill_clock <= 0.0:
		_refill_clock = 3.0
		for actor in actors.duplicate():
			if actor.position_2d().distance_to(Vector2(focus.x,focus.z)) > RETIRE_DISTANCE or actor.finished:
				_retire(actor)
				actors.erase(actor)
		if not is_instance_valid(ambient): traffic.prune(_cohort)
		if _queue.is_empty(): _queue_spawns()
	_spawn_clock -= delta
	if _spawn_clock > 0.0 or _queue.is_empty(): return
	_spawn_clock = 0.035
	var entry: Dictionary = _queue.pop_front()
	if not Plan.contains(Traffic.point(entry.key) + Plan.STREET_SPACING * .5): return
	var count := 0
	for actor in actors:
		if actor.car == entry.car: count += 1
	if count >= (MAX_CARS if entry.car else MAX_PEDESTRIANS): return
	var actor := StreetActor.new()
	actor.car = entry.car
	_serial += 1
	actor.serial = _serial
	actor.manager = self
	var key: Vector2i = entry.key
	if actor.car:
		var incoming := Traffic.approaches(key)
		if incoming.is_empty():
			actor.free()
			return
		var direction: Vector2i = incoming[posmod(_serial, incoming.size())]
		actor.road_from = key - direction
		actor.road_to = key
		actor.road_next = Traffic.choose_next(actor.road_from, key, _serial)
		if actor.road_next.x < 0:
			actor.free()
			return
		var location := Traffic.stop_point(key, direction) - Vector2(direction) * 1.0
		actor.position = Vector3(location.x, Plan.GROUND_Y - 0.03, location.y)
		actor.rotation.y = atan2(-float(direction.x), -float(direction.y))
	else:
		var origin := Traffic.point(key)
		if Plan.is_park_block(Plan.world_to_block(origin + Plan.STREET_SPACING * 0.5)):
			actor.free()
			return
		if (int(entry.index)/9) % 3 != 0:
			actor.path = _sidewalk_path(origin)
		else:
			var available: Array[Vector2i] = []
			for arm in Traffic.DIRECTIONS:
				if Traffic.edge_exists(key, key + arm): available.append(arm)
			if available.is_empty():
				actor.free()
				return
			var arm: Vector2i = Vector2i.DOWN if int(entry.index) == 12 and Vector2i.DOWN in available else available[posmod(_serial, available.size())]
			var crossing := Traffic.crossing(key, arm)
			actor.crossing_key = key
			actor.is_crosser = true
			for location in [crossing[0] + Vector2(arm) * 9.0, crossing[0], crossing[1], crossing[1] + Vector2(arm) * 9.0]:
				actor.path.append(Vector3(location.x, Plan.GROUND_Y + 0.03, location.y))
		if actor.path.is_empty():
			actor.free()
			return
		actor.position = actor.path[0]
		actor.target = 1
		if not actor.is_crosser:
			var spawn := _sidewalk_spawn(actor.path,focus,int(entry.index))
			actor.position = spawn.position
			actor.target = spawn.target
		if actor.position_2d().distance_to(Vector2(focus.x,focus.z)) > RETIRE_DISTANCE:
			actor.free()
			return
	for existing in actors:
		if existing.position.distance_to(actor.position) < (7.0 if actor.car else 1.2):
			actor.free()
			return
	add_child(actor)
	actors.append(actor)
	actor.build()

func set_incidents(records: Array) -> void:
	traffic.set_incidents(records)

func set_district_services(rows: Array) -> void:
	traffic.set_district_services(rows)
	if is_instance_valid(signals): signals.update_displays()

func _physics_process(delta: float) -> void:
	traffic.advance(delta)
	if is_instance_valid(ambient) and ambient.visible: ambient.advance(delta)
	# Displays are updated from the same state immediately after its transition.
	if is_instance_valid(signals) and signals.visible: signals.update_displays()

static func _sidewalk_path(origin: Vector2) -> PackedVector3Array:
	var result := PackedVector3Array()
	if Plan.is_park_block(Plan.world_to_block(origin + Plan.STREET_SPACING*.5)): return result
	var radius := 0.6
	var cell := Traffic.grid(origin)
	var a := origin + Vector2(_walk_inset(cell.x), _walk_inset(cell.y))
	var b := origin + Plan.STREET_SPACING - Vector2(_walk_inset(cell.x + 1), _walk_inset(cell.y + 1))
	var centers := [Vector2(a.x + radius, a.y + radius), Vector2(b.x - radius, a.y + radius),
		Vector2(b.x - radius, b.y - radius), Vector2(a.x + radius, b.y - radius)]
	for corner in range(4):
		for step in range(7):
			var angle := PI + corner * PI * 0.5 + (step / 6.0) * PI * 0.5
			var p: Vector2 = centers[corner] + Vector2(cos(angle), sin(angle)) * radius
			result.append(Vector3(p.x, Plan.GROUND_Y + 0.03, p.y))
	return result

static func _sidewalk_spawn(path: PackedVector3Array, near: Vector3, index: int) -> Dictionary:
	# Long blocks need local distribution along the nearest real sidewalk, not
	# a uniformly random point hundreds of metres away on the whole perimeter.
	var closest := INF
	var start_distance := 0.0
	var perimeter := 0.0
	var lengths: Array[float] = []
	for segment in range(path.size()):
		var a := path[segment]
		var b := path[(segment+1)%path.size()]
		var length := a.distance_to(b)
		lengths.append(length)
		var point := Geometry3D.get_closest_point_to_segment(near,a,b)
		var distance := point.distance_squared_to(near)
		if distance<closest:
			closest = distance
			start_distance = perimeter+a.distance_to(point)
		perimeter += length
	var along := fposmod(start_distance+float(index/9)*7.5-75.0,perimeter)
	for segment in range(path.size()):
		if along<=lengths[segment]:
			return {"position":path[segment].lerp(path[(segment+1)%path.size()],along/maxf(lengths[segment],.001)),"target":(segment+1)%path.size()}
		along -= lengths[segment]
	return {"position":path[0],"target":1}

static func _walk_inset(index: int) -> float:
	return Traffic.road_half(index) + 1.4

class StreetActor extends CharacterBody3D:
	var manager: Node3D
	var car := false
	var serial := 0
	var model := -1
	var vehicle_length := Traffic.CAR_LENGTH
	var vehicle_width := Traffic.CAR_WIDTH
	var ambient_state: RefCounted
	var path := PackedVector3Array()
	var target := 0
	var pedestrian_visual: MeshInstance3D
	var _walk_time := 0.0
	var _walk_phase := -1
	var _walking := false
	var speed := 0.0
	var disabled_until := 0.0
	var crash_damage := 0.0
	var impact_local_point := Vector3.ZERO
	var impact_local_normal := Vector3.ZERO
	var impact_speed := 0.0
	var impact_count := 0
	var _last_impact_time := -1.0
	var _deformed_meshes := 0
	var finished := false
	var road_from := Vector2i.ZERO
	var road_to := Vector2i.ZERO
	var road_next := Vector2i.ZERO
	var road_curve := PackedVector2Array()
	var curve_index := 1
	var committed := false
	var trips := 0
	var crossing_key := Vector2i(-1, -1)
	var is_crosser := false
	var crossing_active := false
	var waiting_to_cross := false
	var _wheels: Array[Node3D] = []
	var _brake_material: StandardMaterial3D
	var _turn_materials: Array[StandardMaterial3D] = []

	func position_2d() -> Vector2:
		return Vector2(position.x, position.z)

	func build() -> void:
		collision_layer = 1
		collision_mask = 1
		safe_margin = 0.005
		var shape := CollisionShape3D.new()
		if car:
			if model < 0: model = posmod(serial,Fleet.CATALOG.size())
			var dimensions := Fleet.spec(model)
			vehicle_length = dimensions.length
			vehicle_width = dimensions.width
			var box := BoxShape3D.new()
			box.size = Vector3(vehicle_width,float(dimensions.height),vehicle_length)
			shape.shape = box
			shape.position.y = float(dimensions.height)*.5
			_build_car()
		else:
			var capsule := CapsuleShape3D.new()
			capsule.radius = 0.34
			capsule.height = MonkeyRig.npc_height(str(serial))
			shape.shape = capsule
			shape.position.y = capsule.height * 0.5
		add_child(shape)
		if car: return
		# This is the same complete canonical anatomy as the player, merged by
		# material in cached articulated poses. Physical sidewalk/crossing logic
		# stays per person without 55 scene nodes and joint updates per frame.
		pedestrian_visual = MeshInstance3D.new()
		pedestrian_visual.name = "CanonicalMonkeyResident"
		pedestrian_visual.mesh = Monkeys.pose("talk")
		pedestrian_visual.scale = Vector3.ONE*Monkeys.height_for(serial)/Monkeys.BASE_HEIGHT
		pedestrian_visual.set_meta("canonical_model","MonkeyRig")
		pedestrian_visual.set_meta("standing_height",Monkeys.height_for(serial))
		add_child(pedestrian_visual)


	func _physics_process(delta: float) -> void:
		if finished or (not car and pedestrian_visual == null) or not is_instance_valid(manager): return
		var before := position
		if car: _drive(delta)
		else: _walk(delta)
		var actual := (position - before) / maxf(delta, 0.001)
		if actual.length_squared() > 0.0001:
			var heading := atan2(-actual.x, -actual.z)
			rotation.y = lerp_angle(rotation.y, heading, minf(7.0 * delta, 1.0))
		if not car:
			var walking := actual.length_squared()>.05
			_walk_time += delta*clampf(actual.length()/1.35,0,2)
			var phase := posmod(floori(_walk_time*5.0),4)
			if phase!=_walk_phase or walking!=_walking:
				pedestrian_visual.mesh = Monkeys.pose("walk" if walking else "talk",0,phase if walking else 0)
				_walk_phase = phase
				_walking = walking
		for wheel in _wheels: wheel.rotate_x(actual.length() * delta / Fleet.wheel_radius(model))

	func receive_vehicle_impact(point: Vector3, normal: Vector3, closing_speed: float) -> void:
		if not car or not is_instance_valid(manager) or not point.is_finite() or not normal.is_finite() or not is_finite(closing_speed) or normal.length_squared()<.1 or closing_speed<3: return
		var now: float = manager.traffic.time
		if now-_last_impact_time<.35: return
		_last_impact_time = now
		impact_count += 1
		impact_local_point = to_local(point)
		impact_local_normal = global_basis.inverse()*normal.normalized()
		impact_speed = closing_speed
		crash_damage = clampf(crash_damage+pow(closing_speed/32.0,2)*.65,0,1)
		# A stopped driver waits for recovery/tow. The same persistent record owns
		# this deadline outside the physical pool, including its road reservation.
		disabled_until = maxf(disabled_until,now+clampf(6+closing_speed*.8,8,45))
		speed = 0.0
		velocity = Vector3.ZERO
		_apply_damage()
		_hazard_lights()
		if ambient_state != null: ambient_state.capture(self)

	func _apply_damage() -> void:
		if impact_speed>=6:
			_deformed_meshes = ImpactEffects.dent(self,to_global(impact_local_point),global_basis*impact_local_normal,impact_speed)

	func _hazard_lights() -> void:
		if _brake_material != null: _brake_material.emission_energy_multiplier = 2.6
		for material in _turn_materials:
			material.emission_energy_multiplier = 2.2 if fposmod(manager.traffic.time,.8)<.4 else .02

	func _recover_traffic_car() -> void:
		# Recovery replaces the damaged shell using the shared original asset.
		# Keep position and route; there is no despawn/teleport through a queue.
		for mesh_node: Node in find_children("*","MeshInstance3D",true,false):
			if mesh_node.has_meta("undamaged_mesh"):
				mesh_node.mesh = mesh_node.get_meta("undamaged_mesh")
				mesh_node.remove_meta("undamaged_mesh")
		disabled_until = 0.0
		crash_damage = 0.0
		impact_speed = 0.0
		_deformed_meshes = 0

	func _drive(delta: float) -> void:
		if manager.traffic.time<disabled_until:
			speed = 0.0
			velocity = Vector3.ZERO
			_hazard_lights()
			return
		if disabled_until>0.0: _recover_traffic_car()
		var target_2d: Vector2
		var incoming := road_to - road_from
		if not committed and (road_next.x<0 or not manager.traffic.edge_open(road_to,road_next)):
			road_next = manager.traffic.choose_open_next(road_from,road_to,serial*17+trips*13)
		var limit: float = Traffic.speed_limit(road_from, incoming) * manager.traffic.mobility_factor(road_to)
		var allowed := committed
		if committed:
			target_2d = road_curve[curve_index]
			limit = minf(limit, 3.4 if road_next - road_to != incoming else 7.5)
		else:
			target_2d = Traffic.stop_point(road_to, incoming,vehicle_length)
			allowed = manager.traffic.may_enter(self, manager.traffic_vehicles(self))
		var remaining := target_2d.distance_to(position_2d())
		var direction := (target_2d - position_2d()).normalized()
		if remaining <= 0.025:
			if committed:
				if curve_index < road_curve.size() - 1: curve_index += 1
				else:
					manager.traffic.release_car(road_to, serial)
					committed = false
					road_from = road_to
					road_to = road_next
					trips += 1
					road_next = manager.traffic.choose_open_next(road_from,road_to,serial*17+trips*13)

			elif allowed:
				manager.traffic.reserve_car(self)
				committed = true
				road_curve = Traffic.turn_path(road_from, road_to, road_next,vehicle_length)
				curve_index = 1
			else: speed = move_toward(speed, 0.0, Traffic.BRAKE * delta)
			return
		if not committed and road_next - road_to != incoming:
			# Brake along the approach, before curvature begins, rather than
			# arriving at a green turn at the straight-road cruising speed.
			limit = minf(limit, sqrt(3.4 * 3.4 + 2.0 * Traffic.BRAKE * remaining))
		if not allowed: limit = minf(limit, sqrt(2.0 * Traffic.BRAKE * maxf(remaining - 0.02, 0.0)))
		limit = Traffic.following_speed(self,manager.traffic_vehicles(self),direction,limit)
		limit = manager.traffic.incident_speed_limit(self,direction,limit)
		var sweep := Vector3(direction.x, 0, direction.y) * (0.55 + speed * speed / (2.0 * Traffic.BRAKE))
		if test_move(global_transform, sweep): limit = 0.0
		var braking: bool = limit < speed - 0.2 or (not allowed and remaining < 0.2)
		speed = move_toward(speed, limit, (Traffic.BRAKE if limit < speed else Traffic.ACCELERATION) * delta)
		if _brake_material != null:
			_brake_material.emission_energy_multiplier = 2.6 if braking else 0.35
		var turn := Vector2(incoming).cross(Vector2(road_next-road_to))
		for side in range(_turn_materials.size()):
			var active := (turn < 0.0 if side == 0 else turn > 0.0) and fposmod(manager.traffic.time, 0.8) < 0.4
			_turn_materials[side].emission_energy_multiplier = 2.2 if active else 0.02
		var motion := Vector3(direction.x, 0, direction.y) * minf(speed * delta, remaining)
		if move_and_collide(motion) != null: speed = 0.0

	func _walk(delta: float) -> void:
		for danger:Vector3 in manager.civil_danger:
			var away:Vector3=position-danger;away.y=0
			if away.length()<32 and away.length()>.1:
				if crossing_active: manager.traffic.release_pedestrian(crossing_key,serial);crossing_active=false
				speed=3.2
				move_and_collide(away.normalized()*speed*delta)
				return
		if path.is_empty(): return
		var to := path[target] - position
		to.y = 0.0
		if to.length() < 0.035:
			if is_crosser and target == 1:
				waiting_to_cross = true
				if not manager.traffic.pedestrian_may_enter(crossing_key, serial, manager.traffic_vehicles(self)):
					speed = 0.0
					return
				crossing_active = true
				waiting_to_cross = false
			if is_crosser and target == 2:
				manager.traffic.release_pedestrian(crossing_key, serial)
				crossing_active = false
			if is_crosser and target == path.size() - 1:
				path.reverse()
				target = 1
			else: target = (target + 1) % path.size()
			to = path[target] - position
			to.y = 0.0
		speed = move_toward(speed, 1.25 + float(posmod(serial, 5)) * 0.10, 2.5 * delta)
		var motion := to.normalized() * minf(speed * delta, to.length())
		var hit := move_and_collide(motion)
		if hit != null:
			speed = 0.0
			if not is_crosser: move_and_collide(hit.get_remainder().slide(hit.get_normal()))

	func _build_car() -> void:
		var visual := Fleet.build(self,model,Fleet.paint_for(serial,model))
		_wheels.assign(visual.wheels)
		_brake_material = visual.brake_material
		_turn_materials.assign(visual.turn_materials)
		if is_instance_valid(manager) and manager.traffic.time<disabled_until:
			_apply_damage()
			_hazard_lights()

func set_civil_incidents(rows: Array) -> void:
	civil_danger.clear()
	for row in rows.slice(0,16):
		if row is Dictionary and row.get("position") is Array and row.position.size()==3:
			civil_danger.append(Vector3(row.position[0],row.position[1],row.position[2]))
