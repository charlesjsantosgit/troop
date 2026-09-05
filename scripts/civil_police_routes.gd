extends RefCounted
## Authority-only road movement. Renderers consume positions from these records;
## they never select suspects, invent witnesses, or independently run a pursuit.
const Plan = preload("res://scripts/city_plan.gd")
const Traffic = preload("res://scripts/city_traffic.gd")
const Incident = preload("res://scripts/city_incident_state.gd")
const SURFACE_Y := Plan.GROUND_Y + 0.06
const SITE_Y := Plan.GROUND_Y + 0.62
const CRUISER_LENGTH := 4.63
const REPATH_DISTANCE := 24.0

static func site_positions() -> Dictionary:
	var x := Plan.MIN_X - 38.0
	return {"station": [x, SITE_Y, 29.0], "station_center": [x, SITE_Y, 43.0],
		"custody": [x - 11.0, SITE_Y, 49.0], "release": [x + 11.0, SITE_Y, 28.0],
		"community_service": [x - 11.0, SITE_Y, 56.0], "escape": [x - 22.0, SITE_Y + 2.2, 56.0],
		"bank": [x, SITE_Y, -29.0], "bank_center": [x, SITE_Y, -43.0],
		"bank_security": [x + 7.0, SITE_Y, -40.0], "bank_vault": [x, SITE_Y, -49.0], "vault": [x, SITE_Y, -49.0],
		"fence": [x, SITE_Y, -111.0], "fence_center": [x, SITE_Y, -116.0]}

static func vector(value: Variant, fallback := Vector3.ZERO) -> Vector3:
	if value is Vector3: return value
	if value is Array and value.size() == 3:
		var result := Vector3(float(value[0]), float(value[1]), float(value[2]))
		return result if result.is_finite() else fallback
	return fallback

static func array3(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

static func structural_solids() -> Array:
	# This shared geometry contract drives both physical walls and authority
	# visibility. Police cannot see a robbery through the bank's solid facade.
	var x := Plan.MIN_X - 38.0
	var result: Array = []
	for row in [
		["station_floor", Vector3(0, -.24, 43), Vector3(54, .48, 44)],
		["station_roof", Vector3(7, 4.1, 43), Vector3(21, .35, 25)],
		["station_back", Vector3(7, 2.0, 55), Vector3(20, 4, .4)],
		["station_east", Vector3(17, 2.0, 43), Vector3(.4, 4, 24)],
		["station_west_a", Vector3(-3, 2.0, 36), Vector3(.4, 4, 10)],
		["station_west_b", Vector3(-3, 2.0, 52), Vector3(.4, 4, 6)],
		["station_west_header", Vector3(-3, 3.4, 45), Vector3(.4, 1.2, 8)],
		["station_front_a", Vector3(-2.1, 2.0, 31), Vector3(1.8, 4, .4)],
		["station_front_b", Vector3(10, 2.0, 31), Vector3(14, 4, .4)],
		["station_front_header", Vector3(1, 3.6, 31), Vector3(4.2, .8, .4)],
		["custody_west", Vector3(-23, 1.25, 49.5), Vector3(.3, 2.5, 25)],
		["custody_north", Vector3(-13, 1.25, 37), Vector3(20, 2.5, .3)],
		["custody_south", Vector3(-13, 1.25, 62), Vector3(20, 2.5, .3)],
		["bank_floor", Vector3(0, -.24, -43), Vector3(38, .48, 38)],
		["bank_roof", Vector3(0, 4.8, -43), Vector3(29, .35, 25)],
		["bank_back_a", Vector3(-7.6, 2.35, -55), Vector3(12.8, 4.7, .4)],
		["bank_back_b", Vector3(7.6, 2.35, -55), Vector3(12.8, 4.7, .4)],
		["bank_exit_header", Vector3(0, 3.85, -55), Vector3(2.4, 1.7, .4)],
		["bank_east", Vector3(14, 2.35, -43), Vector3(.4, 4.7, 24)],
		["bank_west", Vector3(-14, 2.35, -43), Vector3(.4, 4.7, 24)],
		["bank_front_a", Vector3(-8.5, 2.35, -31), Vector3(11, 4.7, .4)],
		["bank_front_b", Vector3(8.5, 2.35, -31), Vector3(11, 4.7, .4)],
		["bank_front_header", Vector3(0, 4, -31), Vector3(6, 1.4, .4)],
		["vault_west", Vector3(-6, 1.7, -50), Vector3(.35, 3.4, 10)],
		["vault_east", Vector3(6, 1.7, -50), Vector3(.35, 3.4, 10)],
		["vault_front_a", Vector3(-4.4, 1.7, -45), Vector3(3.2, 3.4, .5)],
		["vault_front_b", Vector3(4.4, 1.7, -45), Vector3(3.2, 3.4, .5)],
		["vault_header", Vector3(0, 3.1, -45), Vector3(5.6, .6, .5)],
		["fence_floor", Vector3(0, -.24, -116), Vector3(24, .48, 18)],
		["fence_back", Vector3(0, 1.5, -123), Vector3(20, 3, .25)],
		["fence_roof", Vector3(0, 3.05, -118), Vector3(22, .2, 11)],
	]:
		result.append({"id": row[0], "position": Vector3(x, SITE_Y, 0) + Vector3(row[1]), "size": row[2]})
	return result

static func line_of_sight(from: Vector3, to: Vector3) -> bool:
	if not from.is_finite() or not to.is_finite(): return false
	if not Incident.find_hit(from, to).is_empty(): return false
	if minf(from.x, to.x) > Plan.MIN_X: return true
	for solid: Dictionary in structural_solids():
		var box := AABB(Vector3(solid.position) - Vector3(solid.size) * .5, solid.size)
		if box.intersects_segment(from, to) is Vector3: return false
	return true

static func public_unit(unit: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for field in ["id", "position", "officer_position", "eye_position", "heading", "speed", "state", "siren", "target", "arrived"]:
		if unit.has(field): result[field] = unit[field]
	return result.duplicate(true)

static func _advance_officer(unit: Dictionary, target: Vector3, dt: float) -> void:
	var car := vector(unit.position)
	var heading := float(unit.get("heading", 0.0))
	var door := car + Vector3(cos(heading), 0, -sin(heading)) * 2.3
	var at := vector(unit.get("officer_position", []), door)
	if not bool(unit.get("arrived", false)) or not str(unit.state) in ["arrest", "respond", "traffic_stop", "search"]:
		unit.officer_position = array3(car)
		unit.eye_position = array3(car + Vector3.UP * 1.35)
		unit.erase("_foot_path")
		return
	if at.distance_squared_to(car) < 1.0: at = door
	var civic := target.x < Plan.MIN_X and target.x > Plan.MIN_X - 80 and target.z > -130 and target.z < 70
	var destination := Vector3(target.x, SITE_Y if civic else SURFACE_Y, target.z)
	# A bank officer parks on the approach street and walks through the real
	# entrance. Ordinary foot approaches stay near the curb; roof suspects
	# remain inaccessible until they descend to a connected walking surface.
	if destination.distance_to(car) < (100.0 if civic else 38.0) and target.y < destination.y + 2.0:
		var foot_path: Array = unit.get("_foot_path", [])
		var foot_goal := vector(unit.get("_foot_goal", []), Vector3.INF)
		if foot_goal.distance_to(destination) > 2.0:
			foot_path = pedestrian_path(at, destination)
			unit._foot_goal = array3(destination)
		if not foot_path.is_empty():
			var next := vector(foot_path[0])
			var delta := next - at
			var stopping := 2.4 if foot_path.size() == 1 else .08
			if delta.length() > stopping:
				var step := at + delta.normalized() * minf(delta.length() - stopping, dt * 2.3)
				if Plan.pond_depth(Vector2(step.x, step.z)) <= .05 and _foot_clear(at, step): at = step
			if at.distance_to(next) <= stopping + .02: foot_path.pop_front()
		unit._foot_path = foot_path
	unit.officer_position = array3(at)
	unit.eye_position = array3(at + Vector3.UP * 1.35)

static func _foot_clear(a: Vector3, b: Vector3) -> bool:
	if not line_of_sight(a + Vector3.UP * .65, b + Vector3.UP * .65): return false
	var x := Plan.MIN_X - 38.0
	for row in [
		[Vector3(x - 8.5,SITE_Y+.55,-37),Vector3(7.4,1.1,1.4)],
		[Vector3(x + 8.5,SITE_Y+.55,-37),Vector3(7.4,1.1,1.4)],
		[Vector3(x + 7,SITE_Y+.70,-40),Vector3(1.2,1.4,1.0)],
		[Vector3(x,SITE_Y+.40,-51),Vector3(3.4,.8,1.6)],
		[Vector3(x+6,SITE_Y+.48,37),Vector3(8.4,.96,1.6)],
	]:
		var box := AABB(Vector3(row[0])-Vector3(row[1])*.5,row[1])
		if box.intersects_segment(a+Vector3.UP*.5,b+Vector3.UP*.5) is Vector3: return false
	return true

static func pedestrian_path(from: Vector3, target: Vector3) -> Array:
	if _foot_clear(from, target): return [array3(target)]
	var x := Plan.MIN_X - 38.0
	var points: Array[Vector3] = [from, target]
	for row in [Vector2(0,-13),Vector2(0,-25),Vector2(0,-29),Vector2(0,-34),Vector2(0,-40),Vector2(0,-43),Vector2(0,-47),
		Vector2(-4,-40),Vector2(4,-40),Vector2(-11,-40),Vector2(11,-40),Vector2(-11,-34),Vector2(11,-34),
		Vector2(0,13),Vector2(0,27),Vector2(0,29),Vector2(0,33),Vector2(0,39),Vector2(12,39)]:
		var at := Vector3(x+row.x,SITE_Y if absf(row.y)>20 else SURFACE_Y,row.y)
		if at.distance_to(from) < 110 and at.distance_to(target) < 110: points.append(at)
	var midpoint := Vector2((from.x+target.x)*.5,(from.z+target.z)*.5)
	var block := Plan.world_to_block(midpoint)
	if Plan.valid_block(block):
		for building in Plan.block_buildings(block):
			var center: Vector3 = building.position
			if center.distance_to(target)>60 and center.distance_to(from)>60: continue
			var half: Vector3 = Vector3(building.size)*.5+Vector3(1.1,0,1.1)
			for corner in [Vector2(-1,-1),Vector2(1,-1),Vector2(1,1),Vector2(-1,1)]:
				points.append(Vector3(center.x+corner.x*half.x,SURFACE_Y,center.z+corner.y*half.z))
			if points.size()>36: break
	var costs: Dictionary = {0:0.0}
	var parents: Dictionary = {}
	var open: Array = [0]
	var closed: Dictionary = {}
	while not open.is_empty():
		var best := 0
		for index in range(1,open.size()):
			if float(costs[open[index]])<float(costs[open[best]]): best=index
		var here: int = open.pop_at(best)
		if here == 1:
			var result: Array = []
			while here != 0:
				result.push_front(array3(points[here]))
				here = int(parents[here])
			return result
		closed[here] = true
		for next in range(1,points.size()):
			if next==here or closed.has(next) or not _foot_clear(points[here],points[next]): continue
			var score := float(costs[here])+points[here].distance_to(points[next])
			if score>=float(costs.get(next,INF)): continue
			costs[next]=score
			parents[next]=here
			if not open.has(next): open.append(next)
	return []

static func _key(value: Variant) -> Vector2i:
	return Vector2i(int(value[0]), int(value[1])) if value is Array and value.size() == 2 else Vector2i(-99, -99)

static func edge_allowed(a: Vector2i, b: Vector2i) -> bool:
	# The long western access road is already physical terrain. Join it to the
	# bounded urban graph so units can leave Westgate without crossing parcels.
	if a.y == 24 and b.y == 24 and mini(a.x, b.x) >= -1 and maxi(a.x, b.x) <= 1:
		return absi(a.x - b.x) == 1
	return Traffic.edge_allowed(a, b)

static func nearest_road(world_position: Vector3) -> Dictionary:
	var point := Vector2(world_position.x, world_position.z)
	var center := Traffic.grid(point)
	center.x = clampi(center.x, 0, Plan.GRID_WIDTH - 1)
	center.y = clampi(center.y, 1, Plan.GRID_DEPTH - 1)
	var best: Dictionary = {}
	var best_distance := INF
	# The park is thirteen blocks deep. This radius finds its true perimeter
	# instead of fabricating a road through the lake or lawn.
	for x in range(maxi(-1, center.x - 8), mini(Plan.GRID_WIDTH, center.x + 9)):
		for z in range(maxi(1, center.y - 8), mini(Plan.GRID_DEPTH, center.y + 9)):
			var a := Vector2i(x, z)
			for direction in Traffic.DIRECTIONS:
				var b := a + direction
				if not edge_allowed(a, b): continue
				var start := Traffic.exit_point(a, direction, CRUISER_LENGTH)
				var finish := Traffic.stop_point(b, direction, CRUISER_LENGTH)
				var on_lane := Geometry2D.get_closest_point_to_segment(point, start, finish)
				var distance := on_lane.distance_squared_to(point)
				if distance >= best_distance: continue
				best_distance = distance
				best = {"from": [a.x, a.y], "to": [b.x, b.y],
					"position": [on_lane.x, SURFACE_Y, on_lane.y], "distance": sqrt(distance)}
	return best

static func make_unit(id: Variant, at: Vector3) -> Dictionary:
	var edge := nearest_road(at)
	if edge.is_empty(): return {}
	var direction := _key(edge.to) - _key(edge.from)
	var pos := vector(edge.position)
	return {"id": id, "position": array3(pos), "officer_position": array3(pos + Vector3.UP * 1.2),
		"heading": atan2(-float(direction.x), -float(direction.y)), "speed": 0.0,
		"state": "patrol", "siren": false, "target": 0, "clock": 0.0,
		"road_from": edge.from, "road_to": edge.to, "_path": [], "_wait": 0.0,
		"_safe_repath": true, "arrived": false}

static func _identity(previous: Vector2i, current: Vector2i) -> String:
	return "%d,%d/%d,%d" % [previous.x, previous.y, current.x, current.y]

static func _junction_path(previous: Vector2i, current: Vector2i, goal_from: Vector2i, goal_to: Vector2i) -> Array:
	# Directed A*: entering direction is part of the state. No mid-road or
	# junction U-turns, no wrong-way local streets, and no park/plaza shortcuts.
	var first := _identity(previous, current)
	var queue: Array = [{"id": first, "previous": previous, "current": current, "g": 0.0, "f": 0.0}]
	var costs := {first: 0.0}
	var parents: Dictionary = {}
	var nodes := {first: current}
	var expanded := 0
	while not queue.is_empty() and expanded < 10000:
		var best := 0
		for index in range(1, queue.size()):
			if float(queue[index].f) < float(queue[best].f): best = index
		var item: Dictionary = queue.pop_at(best)
		var here: Vector2i = item.current
		var prior: Vector2i = item.previous
		var item_id := str(item.id)
		if float(item.g) > float(costs.get(item_id, INF)): continue
		expanded += 1
		var depot_turn := here == Vector2i(-1, 24)
		if here == goal_from and (goal_to != prior or depot_turn):
			var result: Array = [goal_to]
			var cursor := item_id
			while true:
				result.push_front(nodes[cursor])
				if cursor == first: break
				cursor = str(parents[cursor])
			return result
		for direction in Traffic.DIRECTIONS:
			var next := here + direction
			if (next == prior and not depot_turn) or not edge_allowed(here, next): continue
			var next_id := _identity(here, next)
			var cost := float(item.g) + Traffic.point(here).distance_to(Traffic.point(next))
			if cost >= float(costs.get(next_id, INF)): continue
			costs[next_id] = cost
			parents[next_id] = item_id
			nodes[next_id] = next
			var delta := (Traffic.point(next) - Traffic.point(goal_from)).abs()
			queue.append({"id": next_id, "previous": here, "current": next, "g": cost, "f": cost + delta.x + delta.y})
	return []

static func _waypoint(point: Vector2, speed: float, extra: Dictionary = {}) -> Dictionary:
	var result := {"position": [point.x, SURFACE_Y, point.y], "limit": speed}
	result.merge(extra)
	return result

static func _plan(unit: Dictionary, target: Vector3) -> Array:
	var goal := nearest_road(target)
	if goal.is_empty(): return []
	var a := _key(unit.road_from)
	var b := _key(unit.road_to)
	var goal_a := _key(goal.from)
	var goal_b := _key(goal.to)
	var direction := b - a
	var here3 := vector(unit.position)
	var here := Vector2(here3.x, here3.z)
	var finish3 := vector(goal.position)
	var finish := Vector2(finish3.x, finish3.z)
	var path: Array = []
	if a == goal_a and b == goal_b and (finish - here).dot(Vector2(direction)) >= -0.05:
		return [_waypoint(finish, Traffic.speed_limit(a, direction), {"end": true})]
	var junctions := _junction_path(a, b, goal_a, goal_b)
	if junctions.is_empty(): return []
	path.append(_waypoint(Traffic.stop_point(b, direction, CRUISER_LENGTH), Traffic.speed_limit(a, direction),
		{"stop": [b.x, b.y], "approach": [direction.x, direction.y]}))
	var previous := a
	for index in range(junctions.size() - 1):
		var key: Vector2i = junctions[index]
		var next: Vector2i = junctions[index + 1]
		var outgoing := next - key
		var turn := Traffic.turn_path(previous, key, next, CRUISER_LENGTH)
		var turn_speed := minf(5.0, Traffic.speed_limit(key, outgoing))
		for sample in range(1, turn.size()):
			var extra: Dictionary = {"turn": true}
			if sample == turn.size() - 1: extra.merge({"road_from": [key.x, key.y], "road_to": [next.x, next.y]})
			path.append(_waypoint(turn[sample], turn_speed, extra))
		if key == goal_a and next == goal_b:
			path.append(_waypoint(finish, Traffic.speed_limit(key, outgoing), {"end": true}))
		else:
			path.append(_waypoint(Traffic.stop_point(next, outgoing, CRUISER_LENGTH), Traffic.speed_limit(key, outgoing),
				{"stop": [next.x, next.y], "approach": [outgoing.x, outgoing.y]}))
		previous = key
	return path

static func _signal_green(key: Vector2i, approach: Vector2i, clock: float) -> bool:
	if key.x < 1 or not Traffic.signalized(key): return true
	var cycle := 0.0
	for stage in range(9): cycle += Traffic.stage_duration(key, stage)
	var elapsed := fposmod(clock, cycle)
	var phase := 0
	while phase < 8 and elapsed >= Traffic.stage_duration(key, phase):
		elapsed -= Traffic.stage_duration(key, phase)
		phase += 1
	return phase == (0 if approach.x == 0 else 3)

static func advance_unit(source: Dictionary, dt: float, target: Vector3, mode: String) -> Dictionary:
	var unit := source.duplicate(true)
	if not unit.has("road_from"):
		var initialized := make_unit(unit.get("id", 0), vector(unit.get("position", []), target))
		unit.erase("position")
		initialized.merge(unit, true)
		unit = initialized
	if unit.is_empty() or not target.is_finite(): return source.duplicate(true)
	var elapsed := clampf(dt, 0.0, 0.25)
	unit.clock = float(unit.get("clock", 0.0)) + elapsed
	unit.state = mode
	unit.siren = mode in ["respond", "pursuit"]
	var last_goal := vector(unit.get("_goal", []), Vector3.INF)
	var path: Array = unit.get("_path", [])
	var changed := target.distance_squared_to(last_goal) > REPATH_DISTANCE * REPATH_DISTANCE
	if path.is_empty() and not changed and bool(unit.get("arrived", false)):
		unit.speed = 0.0
		_advance_officer(unit, target, elapsed)
		return unit
	if path.is_empty() or (changed and bool(unit.get("_safe_repath", true))):
		path = _plan(unit, target)
		unit._path = path
		unit._goal = array3(target)
		unit.arrived = false
		unit._wait = 0.0
	var pos := vector(unit.position)
	if path.is_empty():
		unit.speed = 0.0
		unit.arrived = true
		return unit
	var waypoint: Dictionary = path[0]
	var next := vector(waypoint.position)
	var delta := next - pos
	var distance := delta.length()
	var speed := float(unit.get("speed", 0.0))
	var limit := float(waypoint.limit)
	if mode == "search": limit = minf(limit, 5.5)
	if mode in ["respond", "pursuit"]: limit *= 1.3
	if waypoint.has("stop") or bool(waypoint.get("end", false)):
		limit = minf(limit, sqrt(maxf(0.0, 2.0 * 4.2 * maxf(0.0, distance - 0.08))))
	if bool(unit.get("blocked", false)): limit = 0.0
	speed = move_toward(speed, limit, (2.4 if limit > speed else 4.2) * elapsed)
	var travel := minf(distance, speed * elapsed)
	if distance > 0.001:
		pos += delta / distance * travel
		unit.heading = atan2(-delta.x, -delta.z)
	unit.position = array3(pos)
	unit.speed = speed
	unit._safe_repath = not waypoint.has("turn") and bool(unit.get("_safe_repath", true))
	if distance - travel < 0.12:
		var may_advance := true
		if waypoint.has("stop"):
			unit._wait = float(unit.get("_wait", 0.0)) + elapsed
			var key := _key(waypoint.stop)
			var approach := _key(waypoint.approach)
			# Emergency responses pause to clear every intersection. A routine
			# patrol additionally waits through the ordinary red-light phase.
			may_advance = float(unit._wait) >= 1.0 and (bool(unit.siren) or _signal_green(key, approach, float(unit.clock)))
			unit.speed = 0.0
			unit._safe_repath = false
		if may_advance:
			unit.position = waypoint.position.duplicate()
			path.pop_front()
			unit._wait = 0.0
			if waypoint.has("road_from"):
				unit.road_from = waypoint.road_from.duplicate()
				unit.road_to = waypoint.road_to.duplicate()
				unit._safe_repath = true
			if bool(waypoint.get("end", false)):
				unit.arrived = true
				unit.speed = 0.0
	unit._path = path
	pos = vector(unit.position)
	var heading := float(unit.get("heading", 0.0))
	var curb := pos + Vector3(cos(heading), 0, -sin(heading)) * 2.3
	unit.officer_position = array3(curb if bool(unit.arrived) or mode in ["arrest", "traffic_stop"] and speed < 0.2 else pos)
	unit.eye_position = array3(vector(unit.officer_position) + Vector3.UP * 1.35)
	if bool(unit.arrived): _advance_officer(unit, target, elapsed)
	return unit
