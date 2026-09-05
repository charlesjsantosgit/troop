class_name CityParkLayout
extends RefCounted
## Shared, deterministic park routes and facilities. Renderer, activities,
## navigation and boat authority consume the same world-space geometry.
const Plan = preload("res://scripts/city_plan.gd")
const BOAT_IDS := ["v:park-rowboat-01", "v:park-rowboat-02", "v:park-rowboat-03", "v:park-rowboat-04"]
const DOCK_TOP := Plan.GROUND_Y + 0.12
const WALK_WIDTH := 4.2
const CYCLE_WIDTH := 7.0
static var _walk_cache: Array[PackedVector2Array] = []
static var _cycle_cache := PackedVector2Array()
static var _near_path_cache: Dictionary = {}

static func world(local: Vector2, y := Plan.GROUND_Y) -> Vector3:
	return Vector3(Plan.PARK_CENTER.x + local.x, y, Plan.PARK_CENTER.y + local.y)

static func boat_definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var shore := Plan.pond_shore(0.0, .77)
	for index in range(BOAT_IDS.size()):
		var p := shore + Vector2(0, (float(index) - 1.5) * 9.0)
		result.append({"id": BOAT_IDS[index], "kind": 2,
			"pos": Vector3(p.x, Plan.POND_SURFACE_Y + .10, p.y), "yaw": -PI * .5,
			"exit": Vector3(p.x, DOCK_TOP + .04, p.y + 2.9)})
	return result

static func boat_definition(id: String) -> Dictionary:
	for item in boat_definitions():
		if item.id == id: return item
	return {}

static func boathouse_position() -> Vector3:
	var p := Plan.pond_shore(0, 1.17)
	return Vector3(p.x + 7.0, Plan.GROUND_Y, p.y - 31.0)

static func cycle_path_world() -> PackedVector2Array:
	if not _cycle_cache.is_empty(): return _cycle_cache
	# A long oval stays inside the perimeter avenue and clear of the lake.
	var extent := Plan.PARK_HALF_EXTENTS - Vector2(38, 44)
	for i in range(161):
		var a := float(i) * TAU / 160.0
		var c := cos(a)
		var s := sin(a)
		var p := Vector2(signf(c) * pow(absf(c), .40) * extent.x,
			signf(s) * pow(absf(s), .40) * extent.y)
		_cycle_cache.append(Plan.PARK_CENTER + p)
	return _cycle_cache

static func walking_paths_world() -> Array[PackedVector2Array]:
	if not _walk_cache.is_empty(): return _walk_cache
	# Lake promenade follows the same natural shoreline at a dry-bank offset.
	var lake := PackedVector2Array()
	for i in range(161): lake.append(Plan.pond_shore(float(i) * TAU / 160, 1.10))
	_walk_cache.append(lake)
	# Main woodland walk on the west side, continuous from south to north gate.
	var spine := PackedVector2Array()
	for i in range(101):
		var z := lerpf(-Plan.PARK_HALF_EXTENTS.y+1, Plan.PARK_HALF_EXTENTS.y-1, float(i) / 100)
		spine.append(Plan.PARK_CENTER + Vector2(-240 + sin(z / 370) * 38, z))
	_walk_cache.append(spine)
	# Great Lawn circuit and activity clearings.
	_walk_cache.append(_oval(Vector2(5, -900), Vector2(247, 490), 112))
	_walk_cache.append(_oval(Vector2(-95, 1300), Vector2(210, 370), 96))
	# Cross-park gate approaches stay outside the basin, with one dock spur.
	for z in [-1550.0, -500.0, 920.0, 1710.0]:
		var points := PackedVector2Array()
		for i in range(33):
			var x := lerpf(-Plan.PARK_HALF_EXTENTS.x+1, Plan.PARK_HALF_EXTENTS.x-1, float(i) / 32)
			points.append(Plan.PARK_CENTER + Vector2(x, z + sin(float(i) * PI / 32) * 28))
		_walk_cache.append(points)
	var dock := boathouse_position()
	_walk_cache.append(PackedVector2Array([Vector2(dock.x, dock.z), Vector2(Plan.PARK_CENTER.x + Plan.PARK_HALF_EXTENTS.x-1, dock.z)]))
	return _walk_cache

static func dog_path_world() -> PackedVector2Array:
	return _oval(Vector2(-155,-1260),Vector2(32,38),64)

static func _oval(center: Vector2, radii: Vector2, segments: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(segments + 1):
		var a := float(i) * TAU / segments
		points.append(Plan.PARK_CENTER + center + Vector2(cos(a), sin(a)) * radii)
	return points

static func route_length(route: PackedVector2Array) -> float:
	var length := 0.0
	for i in range(1, route.size()): length += route[i - 1].distance_to(route[i])
	return length

static func route_point(route: PackedVector2Array, distance: float) -> Dictionary:
	var total := route_length(route)
	if route.size() < 2 or total <= .001: return {"point": Plan.PARK_CENTER, "direction": Vector2.RIGHT}
	var remaining := fposmod(distance, total)
	for i in range(1, route.size()):
		var segment := route[i - 1].distance_to(route[i])
		if remaining <= segment or i == route.size() - 1:
			return {"point": route[i - 1].lerp(route[i], remaining / maxf(segment, .001)),
				"direction": (route[i] - route[i - 1]).normalized()}
		remaining -= segment
	return {"point": route[0], "direction": Vector2.RIGHT}

static func path_distance(point: Vector2, cycling := false) -> float:
	var closest := INF
	var routes: Array = [cycle_path_world()] if cycling else walking_paths_world()
	for route in routes:
		for i in range(1, route.size()):
			closest = minf(closest, point.distance_to(Geometry2D.get_closest_point_to_segment(point, route[i - 1], route[i])))
	return closest

static func near_path(point: Vector2, distance: float, cycling := false) -> bool:
	var kind := 1 if cycling else 0
	if not _near_path_cache.has(kind):
		var buckets: Dictionary = {}
		var routes: Array = [cycle_path_world()] if cycling else walking_paths_world()
		for route in routes:
			for i in range(1,route.size()):
				var bounds := Rect2(route[i-1],route[i]-route[i-1]).abs().grow(16)
				var lo := Vector2i(floori(bounds.position.x/64),floori(bounds.position.y/64))
				var hi := Vector2i(floori(bounds.end.x/64),floori(bounds.end.y/64))
				for x in range(lo.x,hi.x+1):
					for y in range(lo.y,hi.y+1):
						var key := Vector2i(x,y)
						if not buckets.has(key): buckets[key] = []
						buckets[key].append([route[i-1],route[i]])
		_near_path_cache[kind] = buckets
	var key := Vector2i(floori(point.x/64),floori(point.y/64))
	for edge in _near_path_cache[kind].get(key,[]):
		if point.distance_to(Geometry2D.get_closest_point_to_segment(point,edge[0],edge[1])) < distance: return true
	return false

static func activities() -> Array[Dictionary]:
	return [
		{"id": "yoga", "label": "Great Lawn · group yoga", "position": world(Vector2(-80,-910)), "kind": "park_yoga"},
		{"id": "dogs", "label": "Dog meadow · walkers and play", "position": world(Vector2(-155,-1260)), "kind": "park_dogs"},
		{"id": "social", "label": "Garden terrace · meet the neighbors", "position": world(Vector2(110,-625)), "kind": "park_social"},
		{"id": "cycle", "label": "Scenic cycle loop", "position": world(Vector2(Plan.PARK_HALF_EXTENTS.x - 38,-500)), "kind": "park_cycle"},
		{"id": "boathouse", "label": "Lantern Lake · rowboat landing", "position": boathouse_position(), "kind": "park_boathouse"}]

static func clear_resources() -> void:
	_walk_cache.clear()
	_cycle_cache.clear()
	_near_path_cache.clear()
