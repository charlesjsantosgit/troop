class_name CityTraffic
extends RefCounted
## One controller state drives both street displays and ambient road users.
## Fictional NYC-inspired urban profile; see docs/design/CITY_TRAFFIC.md.
const Plan = preload("res://scripts/city_plan.gd")
const DIRECTIONS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const CAR_LENGTH := 4.1
const CAR_WIDTH := 1.85
const GAP := 2.2
const ACCELERATION := 1.8
const BRAKE := 3.2
const YELLOW := 3.0
const ALL_RED := 2.0
const WALK := 7.0
const PED_BUFFER := 3.0
const STOP_DWELL := 1.0
const CROSSWALK_OFFSET := 2.5
const CROSSWALK_HALF := 1.25
const STOP_BAR_OFFSET := 5.15
const STOP_CENTER_OFFSET := STOP_BAR_OFFSET + CAR_LENGTH * 0.5 + 0.35
const MAX_JUNCTIONS := 81
var junctions: Dictionary = {}
var time := 0.0
var district_services: Dictionary = {}
var incident_centers: Array[Vector2] = []
const INCIDENT_RADIUS := 40.0

static func grid(point: Vector2) -> Vector2i:
	return Vector2i(roundi((point.x - Plan.MIN_X) / Plan.STREET_SPACING.x), roundi((point.y - Plan.MIN_Z) / Plan.STREET_SPACING.y))

static func point(key: Vector2i) -> Vector2:
	return Vector2(Plan.MIN_X, Plan.MIN_Z) + Vector2(key) * Plan.STREET_SPACING

static func road_half(index: int) -> float:
	return Plan.MAJOR_ROAD_HALF_WIDTH

static func right(direction: Vector2i) -> Vector2:
	return Vector2(-direction.y, direction.x)

static func road_index(key: Vector2i, direction: Vector2i) -> int:
	return key.x if direction.x == 0 else key.y

static func lane_offset(key: Vector2i, direction: Vector2i) -> float:
	return 2.7 if road_half(road_index(key, direction)) > 4.0 else 2.0

static func speed_limit(key: Vector2i, direction: Vector2i) -> float:
	return (25.0 if posmod(road_index(key, direction), 4) == 0 else 15.0) * 0.44704

static func one_way_direction(key: Vector2i, axis: int) -> Vector2i:
	# Sparse alternating local streets. Avenues and park perimeter stay two-way.
	var index := key.x if axis == 0 else key.y
	if posmod(index, 8) != 3: return Vector2i.ZERO
	var positive := 1 if posmod(index / 8, 2) == 0 else -1
	return Vector2i(0, positive) if axis == 0 else Vector2i(positive, 0)

static func edge_exists(a: Vector2i, b: Vector2i) -> bool:
	var direction := b - a
	if absi(direction.x) + absi(direction.y) != 1: return false
	if mini(a.x, b.x) < 1 or mini(a.y, b.y) < 1 or maxi(a.x, b.x) >= Plan.GRID_WIDTH or maxi(a.y, b.y) >= Plan.GRID_DEPTH: return false
	var center := (point(a) + point(b)) * 0.5
	if Plan.is_park(center): return false
	# Remove the four plaza spokes; the plaza has no vehicle carriageway.
	var plaza := Plan.CENTER
	var closest := Geometry2D.get_closest_point_to_segment(plaza, point(a), point(b))
	if closest.distance_to(plaza) < Plan.PLAZA_HALF_EXTENT + 2.0: return false
	return true

static func edge_allowed(a: Vector2i, b: Vector2i) -> bool:
	if not edge_exists(a, b): return false
	var direction := b - a
	var allowed := one_way_direction(a, 0 if direction.x == 0 else 1)
	return allowed == Vector2i.ZERO or direction == allowed

static func approaches(key: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for direction in DIRECTIONS:
		if edge_allowed(key - direction, key): result.append(direction)
	return result

static func signalized(key: Vector2i) -> bool:
	return posmod(key.x, 4) == 0 or posmod(key.y, 4) == 0

static func cross_half(key: Vector2i, direction: Vector2i) -> float:
	return road_half(key.y if direction.x == 0 else key.x)

static func stop_point(key: Vector2i, direction: Vector2i, length := CAR_LENGTH) -> Vector2:
	return point(key) - Vector2(direction) * (cross_half(key, direction) + STOP_BAR_OFFSET + length * 0.5 + 0.35) + right(direction) * lane_offset(key, direction)

static func exit_point(key: Vector2i, direction: Vector2i, length := CAR_LENGTH) -> Vector2:
	return point(key) + Vector2(direction) * (cross_half(key, direction) + STOP_BAR_OFFSET + length * 0.5 + 0.35) + right(direction) * lane_offset(key, direction)

static func choose_next(previous: Vector2i, key: Vector2i, serial: int) -> Vector2i:
	var incoming := key - previous
	var choices: Array[Vector2i] = []
	for direction in DIRECTIONS:
		if direction == -incoming or not edge_allowed(key, key + direction): continue
		choices.append(key + direction)
		if direction == incoming: choices.append(key + direction)
	return choices[posmod(serial, choices.size())] if not choices.is_empty() else Vector2i(-1, -1)

static func turn_path(previous: Vector2i, key: Vector2i, next: Vector2i, length := CAR_LENGTH) -> PackedVector2Array:
	var incoming := key - previous
	var outgoing := next - key
	var start := stop_point(key, incoming, length)
	var finish := exit_point(key, outgoing, length)
	var result := PackedVector2Array()
	if incoming == outgoing:
		result.append(start)
		result.append(finish)
		return result
	# Tangent-continuous cubic turns remain inside the actual road intersection.
	var right_turn := Vector2(incoming).cross(Vector2(outgoing)) > 0.0
	var handle := start.distance_to(finish) * (0.95 if right_turn else 0.53)
	var control_a := start + Vector2(incoming) * handle
	var control_b := finish - Vector2(outgoing) * handle
	for index in range(25):
		var t := float(index) / 24.0
		var u := 1.0 - t
		result.append(u*u*u*start + 3.0*u*u*t*control_a + 3.0*u*t*t*control_b + t*t*t*finish)
	return result

static func crossing(key: Vector2i, arm: Vector2i) -> PackedVector2Array:
	var center := point(key) + Vector2(arm) * (cross_half(key, arm) + CROSSWALK_OFFSET)
	var offset := right(arm) * (road_half(road_index(key, arm)) + 1.2)
	return PackedVector2Array([center - offset, center + offset])

static func clearance_seconds(key: Vector2i) -> float:
	# 1 m/s is slower than MUTCD's usual 3.5 ft/s clearance design speed.
	return ceilf((maxf(road_half(key.x), road_half(key.y)) * 2.0 + 2.4) / 1.0)

func controlled(key: Vector2i) -> bool:
	if not signalized(key): return false
	var district := Plan.district_for_block(Plan.world_to_block(point(key)))
	return float(district_services.get(district, {}).get("power_ratio", 1.0)) > 0.0

func mobility_factor(key: Vector2i) -> float:
	var district := Plan.district_for_block(Plan.world_to_block(point(key)))
	return lerpf(.35, 1.0, float(district_services.get(district, {}).get("mobility_ratio", 1.0)))

func set_district_services(rows: Array) -> void:
	var prior: Dictionary = {}
	for key: Vector2i in junctions: prior[key] = controlled(key)
	district_services.clear()
	for row in rows:
		if not row is Dictionary: continue
		var district := int(row.get("id", -1))
		if district < 0 or district >= 12: continue
		var infrastructure: Dictionary = row.get("infrastructure", {})
		district_services[district] = {"power_ratio": clampf(float(infrastructure.get("power_ratio", 1.0)),0,1), "mobility_ratio": clampf(float(infrastructure.get("mobility_ratio",1.0)),0,1)}
	for key: Vector2i in junctions:
		if bool(prior[key]) != controlled(key):
			junctions[key].waiters.clear()
			# Recovery starts with a full steady-hand/all-red buffer; existing
			# committed road users retain their reservation through the outage.
			junctions[key].stage = 8
			junctions[key].elapsed = 0.0

func ensure(key: Vector2i) -> Dictionary:
	if not junctions.has(key):
		var cycle := 0.0
		for stage in range(9): cycle += stage_duration(key,stage)
		var elapsed := fposmod(time,cycle)
		var phase := 0
		while elapsed >= stage_duration(key,phase) and phase < 8:
			elapsed -= stage_duration(key,phase)
			phase += 1
		junctions[key] = {"stage": phase, "elapsed": elapsed, "cars": {}, "pedestrians": {}, "waiters": {}}
	return junctions[key]

func prune(center: Vector2i, radius := 4) -> void:
	for key: Vector2i in junctions.keys():
		if absi(key.x - center.x) > radius or absi(key.y - center.y) > radius:
			if junctions[key].cars.is_empty() and junctions[key].pedestrians.is_empty(): junctions.erase(key)

func advance(delta: float) -> void:
	time += delta
	for key: Vector2i in junctions:
		if not controlled(key): continue
		var state: Dictionary = junctions[key]
		state.elapsed += delta
		var duration := stage_duration(key, int(state.stage))
		if float(state.elapsed) < duration: continue
		# Keep a red clearance/buffer displayed until actual crossing users clear.
		if int(state.stage) in [2, 5, 8] and (not state.cars.is_empty() or not state.pedestrians.is_empty()):
			state.elapsed = duration
			continue
		state.stage = (int(state.stage) + 1) % 9
		state.elapsed = 0.0

static func stage_duration(key: Vector2i, stage: int) -> float:
	return [14.0, YELLOW, ALL_RED, 14.0, YELLOW, ALL_RED, WALK, clearance_seconds(key), PED_BUFFER][stage]

func display(key: Vector2i) -> Dictionary:
	var state := ensure(key)
	var stage := int(state.stage)
	if signalized(key) and not controlled(key):
		return {"north_south": "flash_red", "east_west": "flash_red", "pedestrian": "dark", "countdown": -1, "flash": fposmod(time,1.0)<.5, "stage": -1}
	return {"north_south": "green" if stage == 0 else "yellow" if stage == 1 else "red",
		"east_west": "green" if stage == 3 else "yellow" if stage == 4 else "red",
		"pedestrian": "walk" if stage == 6 else "clearance" if stage == 7 else "stop",
		"countdown": maxi(0, ceili(clearance_seconds(key) - float(state.elapsed))) if stage == 7 else -1,
		"flash": fposmod(float(state.elapsed), 1.0) < 0.5, "stage": stage}

func lamp(key: Vector2i, direction: Vector2i) -> String:
	var indication := display(key)
	return indication.north_south if direction.x == 0 else indication.east_west

func release_car(key: Vector2i, serial: int) -> void:
	if junctions.has(key):
		junctions[key].cars.erase(serial)
		junctions[key].waiters.erase(serial)

func release_pedestrian(key: Vector2i, serial: int) -> void:
	if junctions.has(key): junctions[key].pedestrians.erase(serial)

func pedestrian_may_enter(key: Vector2i, serial: int, vehicles: Array) -> bool:
	var state := ensure(key)
	if not state.cars.is_empty(): return false
	if controlled(key):
		if int(state.stage) != 6: return false
	else:
		for vehicle in vehicles:
			if not is_instance_valid(vehicle): continue
			if not vehicle.car or vehicle.road_to != key: continue
			if vehicle.speed > 0.1 and vehicle.position_2d().distance_to(stop_point(key, key - vehicle.road_from, vehicle_length(vehicle))) < 12.0: return false
	state.pedestrians[serial] = true
	return true

func may_enter(vehicle: Variant, vehicles: Array) -> bool:
	var key: Vector2i = vehicle.road_to
	var direction: Vector2i = key - vehicle.road_from
	var state := ensure(key)
	if not state.pedestrians.is_empty() or not state.cars.is_empty(): return false
	if vehicle.road_next.x < 0 or not edge_open(key, vehicle.road_next): return false
	var distance: float = vehicle.position_2d().distance_to(stop_point(key, direction, vehicle_length(vehicle)))
	if controlled(key):
		var indication := lamp(key, direction)
		if indication == "red": return false
		if indication == "yellow" and (vehicle.speed < 0.5 or distance > vehicle.speed * vehicle.speed / (2.0 * BRAKE) + 0.35): return false
	else:
		if distance > 0.12 or vehicle.speed > 0.05: return false
		if not state.waiters.has(vehicle.serial): state.waiters[vehicle.serial] = time
		if time - float(state.waiters[vehicle.serial]) < STOP_DWELL: return false
	var courtesy := -1
	if not controlled(key) and state.waiters.size() >= 4:
		var earliest := INF
		var latest := -INF
		for waiting_id in state.waiters:
			earliest = minf(earliest, float(state.waiters[waiting_id]))
			latest = maxf(latest, float(state.waiters[waiting_id]))
		if latest - earliest <= 0.1 and time - latest >= 3.0:
			# Four simultaneous arrivals have cyclic right-hand priority. After
			# a standstill, three drivers explicitly defer to one deterministic car.
			for waiting_id in state.waiters:
				if courtesy < 0 or int(waiting_id) < courtesy: courtesy = int(waiting_id)
	var outgoing: Vector2i = vehicle.road_next - key
	var left_turn := Vector2(direction).cross(Vector2(outgoing)) < 0.0
	for other in vehicles:
		if not is_instance_valid(other): continue
		if other == vehicle: continue
		if not other.car:
			if not controlled(key) and other.waiting_to_cross and other.crossing_key == key: return false
			continue
		# Do not enter a box unless the receiving lane has room for the whole car.
		var ahead: Vector2 = other.position_2d() - point(key)
		var lateral: float = absf(ahead.dot(right(outgoing)) - lane_offset(key, outgoing))
		if ahead.dot(Vector2(outgoing)) > 0.0 and ahead.dot(Vector2(outgoing)) < cross_half(key, outgoing) + STOP_BAR_OFFSET + vehicle_length(vehicle) + vehicle_length(other) * 0.5 + GAP and lateral < (vehicle_width(vehicle) + vehicle_width(other)) * 0.5:
			return false
		if other.road_to != key: continue
		var other_dir: Vector2i = key - other.road_from
		var other_distance: float = other.position_2d().distance_to(stop_point(key, other_dir, vehicle_length(other)))
		if controlled(key):
			# Permissive left turn yields to opposing through/right approaches.
			var other_left := Vector2(other_dir).cross(Vector2(other.road_next - key)) < 0.0
			if left_turn and not other_left and other_dir == -direction and other_distance < maxf(12.0, other.speed * 3.5): return false
		elif state.waiters.has(other.serial):
			if courtesy >= 0:
				if vehicle.serial != courtesy: return false
				continue
			var ours: float = state.waiters[vehicle.serial]
			var theirs: float = state.waiters[other.serial]
			if theirs < ours - 0.1: return false
			if absf(theirs - ours) <= 0.1:
				if Vector2(other_dir) == -right(direction): return false
				if left_turn and other_dir == -direction: return false
				# Identical approach ties are broken by longitudinal queue order.
				if other_dir == direction and other_distance < distance: return false
	return true

func reserve_car(vehicle: Variant) -> void:
	ensure(vehicle.road_to).cars[vehicle.serial] = true

static func following_speed(vehicle: Variant, vehicles: Array, direction: Vector2, limit: float) -> float:
	for other in vehicles:
		if not is_instance_valid(other): continue
		if other == vehicle: continue
		var relative: Vector2 = other.position_2d() - vehicle.position_2d()
		var along := relative.dot(direction)
		var lateral := absf(relative.cross(direction))
		if along <= 0.0 or lateral > (vehicle_width(vehicle) * 0.5 + (vehicle_width(other) * 0.5 if other.car else 0.45)): continue
		var gap := along - ((vehicle_length(vehicle) + vehicle_length(other)) * 0.5 if other.car else vehicle_length(vehicle) * 0.5 + 0.45)
		limit = minf(limit, minf(sqrt(2.0 * BRAKE * maxf(gap - GAP, 0.0)), maxf(gap - GAP, 0.0) / 1.5))
	return limit

static func vehicle_length(vehicle: Variant) -> float:
	return float(vehicle.vehicle_length) if vehicle.get("vehicle_length") != null else CAR_LENGTH

static func vehicle_width(vehicle: Variant) -> float:
	return float(vehicle.vehicle_width) if vehicle.get("vehicle_width") != null else CAR_WIDTH

func set_incidents(records: Array) -> void:
	incident_centers.clear()
	for record in records:
		if not record is Dictionary or not bool(record.get("active",true)): continue
		var point: Variant = record.get("point")
		if point == null:
			var coordinates: Variant = record.get("position")
			if coordinates is Array and coordinates.size()==3: point = Vector3(float(coordinates[0]),float(coordinates[1]),float(coordinates[2]))
		if point is Vector3 and point.is_finite(): incident_centers.append(Vector2(point.x,point.z))
		if incident_centers.size() >= 32: break

func edge_open(a: Vector2i,b: Vector2i) -> bool:
	if not edge_allowed(a,b): return false
	for center in incident_centers:
		if Geometry2D.get_closest_point_to_segment(center,point(a),point(b)).distance_to(center) < INCIDENT_RADIUS: return false
	return true

func choose_open_next(previous:Vector2i,key:Vector2i,serial:int) -> Vector2i:
	var incoming := key-previous
	var choices: Array[Vector2i] = []
	for direction in DIRECTIONS:
		if direction == -incoming or not edge_open(key,key+direction): continue
		choices.append(key+direction)
		if direction == incoming: choices.append(key+direction)
	return choices[posmod(serial,choices.size())] if not choices.is_empty() else Vector2i(-1,-1)

func incident_speed_limit(vehicle:Variant,direction:Vector2,limit:float) -> float:
	for center in incident_centers:
		var relative: Vector2 = center-vehicle.position_2d()
		var along := relative.dot(direction)
		var lateral := absf(relative.cross(direction))
		if along <= 0 or lateral >= INCIDENT_RADIUS: continue
		var boundary := along-sqrt(INCIDENT_RADIUS*INCIDENT_RADIUS-lateral*lateral)-vehicle_length(vehicle)*.5-.35
		limit = minf(limit,sqrt(2.0*BRAKE*maxf(0.0,boundary)))
	return limit
