class_name FrontierRoutes
extends RefCounted
## Shared walkable service-road graph. Pure model data: headless economies use
## exactly the paths drawn by FrontierSettlement, without loading visual rigs.
## Crop access takes a side aisle first so sealed cells are never shortcuts.

const EARTH_POINTS := [
	[0,4], [0,-15], [-32,4], [-32,25], [-35,-15], [-58,-15],
	[-35,-23], [-39,-23], [-58,-23], [-18,-15], [-18,-18],
	[18,-15], [18,-18], [30,-15], [30,-18], [30,-35],
	[40,-15], [40,4], [40,15], [60,4], [60,35], [95,35],
	[95,10], [120,10], [120,-35], [145,-80], [100,65], [135,-35],
]
const EARTH_EDGES := [
	[0,1], [0,2], [2,3], [1,9], [9,4], [4,5], [4,6],
	[6,7], [5,8], [9,10], [1,11], [11,12], [11,13],
	[13,14], [14,15], [13,16], [16,17], [0,17], [17,18],
	[17,19], [19,20], [20,21], [21,22], [22,23], [23,24],
	[24,27], [27,25], [21,26],
]
const MOON_POINTS := [
	[0,4], [0,-12], [-23,-10], [-34,-10], [-40,-10], [-40,-35],
	[-55,-35], [28,-12], [28,-20], [-15,15], [28,20],
]
const MOON_EDGES := [[0,1],[1,2],[2,3],[3,4],[4,5],[5,6],[1,7],[7,8],[0,9],[0,10]]


static func path(from: Array, to: Array, planet: String, plot := false) -> Array:
	if from.size() < 2 or to.size() < 2:
		return []
	var start := Vector2(float(from[0]), float(from[1]))
	var finish := Vector2(float(to[0]), float(to[1]))
	if start.distance_squared_to(finish) < 0.01:
		return []
	var points: Array = MOON_POINTS if planet == "moon" else EARTH_POINTS
	var edges: Array = MOON_EDGES if planet == "moon" else EARTH_EDGES
	var departure := _plot_access(start, planet, false)
	var arrival := _plot_access(finish, planet, plot)
	var route: Array = []
	var road_start := start
	if not departure.is_empty():
		for point in departure:
			_append(route, point)
		road_start = _vector(departure.back())
	var road_finish := _vector(arrival.back()) if not arrival.is_empty() else finish
	var first := _nearest(road_start, points)
	var last := _nearest(road_finish, points)
	var distances: Array[float] = []
	var previous: Array[int] = []
	var visited: Array[bool] = []
	for index in range(points.size()):
		distances.append(INF)
		previous.append(-1)
		visited.append(false)
	distances[first] = 0.0
	for iteration in range(points.size()):
		var node := -1
		var best := INF
		for index in range(points.size()):
			if not visited[index] and distances[index] < best:
				node = index
				best = distances[index]
		if node < 0 or node == last:
			break
		visited[node] = true
		for edge in edges:
			var neighbor := int(edge[1]) if int(edge[0]) == node else int(edge[0]) if int(edge[1]) == node else -1
			if neighbor < 0 or visited[neighbor]:
				continue
			var length := distances[node] + _vector(points[node]).distance_to(_vector(points[neighbor]))
			if length < distances[neighbor]:
				distances[neighbor] = length
				previous[neighbor] = node
	var chain: Array = []
	var cursor := last
	while cursor >= 0:
		chain.push_front(points[cursor])
		cursor = previous[cursor]
	for point in chain:
		_append(route, point)
	if not arrival.is_empty():
		arrival.reverse()
		for point in arrival:
			_append(route, point)
	_append(route, [finish.x, finish.y])
	while not route.is_empty() and _vector(route.front()).distance_squared_to(start) < 0.01:
		route.pop_front()
	return route


static func _plot_access(point: Vector2, planet: String, forced: bool) -> Array:
	if planet == "moon":
		if forced or (point.x >= -34.1 and point.x <= -12.0 and point.y >= -25.0 and point.y <= -12.0):
			return [[-34.0, point.y], [-34.0, -10.0]]
	elif forced or (point.x >= -58.0 and point.x <= -19.0 and point.y >= -39.0 and point.y <= -24.0):
		var aisle := -58.0 if point.x < -40.0 else -39.0
		return [[aisle, point.y], [aisle, -23.0]]
	return []


static func _nearest(point: Vector2, points: Array) -> int:
	var result := 0
	var closest := INF
	for index in range(points.size()):
		var distance := point.distance_squared_to(_vector(points[index]))
		if distance < closest:
			closest = distance
			result = index
	return result


static func _vector(point: Array) -> Vector2:
	return Vector2(float(point[0]), float(point[1]))


static func _append(route: Array, point: Array) -> void:
	if route.is_empty() or _vector(route.back()).distance_squared_to(_vector(point)) > 0.01:
		route.append([float(point[0]), float(point[1])])


# Cars use only service streets. Crop aisles and the well's short footpath stay
# pedestrian-only. These segments are also the settlement renderer's source.
const ROAD_WIDTH := 8.0
const LANE_OFFSET := 1.65
const DRIVE_EDGES := [[0,1],[0,2],[2,3],[1,9],[9,4],[4,5],
	[1,11],[11,13],[13,14],[14,15],[13,16],[16,17],[0,17],
	[17,18],[17,19],[19,20],[20,21],[21,22],[22,23],[23,24],
	[24,27],[27,25],[21,26]]


static func road_segments() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for edge in DRIVE_EDGES:
		result.append({"from": _vector(EARTH_POINTS[edge[0]]),
			"to": _vector(EARTH_POINTS[edge[1]]), "width": ROAD_WIDTH})
	return result


static func loading_bays() -> Dictionary:
	return {"earth_market":Vector2(0,-15), "cooperative":Vector2(-35,-15),
		"water":Vector2(-18,-15), "kitchen":Vector2(18,-15),
		"warehouse":Vector2(30,-29), "workshop":Vector2(44,12),
		"oil_rig":Vector2(120,-29), "refinery":Vector2(95,16),
		"gas_station":Vector2(60,41), "airfield":Vector2(100,65),
		"carrier":Vector2(145,-74), "housing":Vector2(-32,19),
		"town_square":Vector2(0,4), "player_earth":Vector2(0,4)}


static func junctions() -> Array[Vector2]:
	var counts := {}
	for edge in DRIVE_EDGES:
		for index in edge:
			counts[index] = int(counts.get(index, 0)) + 1
	var result: Array[Vector2] = []
	for index in counts:
		if counts[index] >= 3:
			result.append(_vector(EARTH_POINTS[index]))
	return result


## A right-hand lane path with bounded quadratic corner rounding. No route
## point is a body position assignment: the driver follows it through tires.
static func driving_path(from: Vector2, destination: Vector2) -> Array[Vector2]:
	var nodes: Array = []
	var indices: Array[int] = []
	for edge in DRIVE_EDGES:
		for index: int in edge:
			if index not in indices:
				indices.append(index)
	for index in indices:
		nodes.append(EARTH_POINTS[index])
	var first := indices[_nearest(from, nodes)]
	var last := indices[_nearest(destination, nodes)]
	var distances := {first:0.0}
	var previous := {}
	var visited := {}
	for iteration in indices:
		var node := -1
		var best := INF
		for index in indices:
			if not visited.has(index) and float(distances.get(index, INF)) < best:
				node = index
				best = float(distances[index])
		if node < 0 or node == last:
			break
		visited[node] = true
		for edge in DRIVE_EDGES:
			var next := int(edge[1]) if edge[0] == node else int(edge[0]) if edge[1] == node else -1
			if next < 0 or visited.has(next):
				continue
			var cost := best + _vector(EARTH_POINTS[node]).distance_to(_vector(EARTH_POINTS[next]))
			if cost < float(distances.get(next, INF)):
				distances[next] = cost
				previous[next] = node
	var center: Array[Vector2] = []
	var cursor := last
	while cursor >= 0:
		center.push_front(_vector(EARTH_POINTS[cursor]))
		cursor = int(previous.get(cursor, -1))
	# Stops are in the clear loading apron before walls and standing workers.
	if center.back().distance_to(destination) <= 12.0:
		if center.size()==1 or Geometry2D.get_closest_point_to_segment(destination,center[center.size()-2],center.back()).distance_to(destination)<0.1:
			center[center.size()-1] = destination
		elif center.back().distance_to(destination)>0.1:
			# Leave the through lane only at the receiving junction; shifting
			# the whole last road edge toward a bay would cut the opposing lane.
			center.append(destination)
	# A collinear subdivision is not an intersection turn.
	var index := 1
	while index < center.size() - 1:
		if (center[index] - center[index-1]).normalized().dot((center[index+1] - center[index]).normalized()) > 0.995:
			center.remove_at(index)
		else:
			index += 1
	if center.size() < 2:
		# Existing stationary forecourt spaces can service a dock without
		# squeezing every queued vehicle onto its exact center point.
		var parked: Array[Vector2] = [from]
		if from.distance_to(center[0]) > 6.1: parked.append(center[0])
		return parked
	var lane: Array[Vector2] = []
	for i in range(center.size()):
		var before := (center[i] - center[maxi(i-1, 0)]).normalized()
		var after := (center[mini(i+1, center.size()-1)] - center[i]).normalized()
		if i == 0: before = after
		if i == center.size()-1: after = before
		var right_before := Vector2(-before.y, before.x)
		var right_after := Vector2(-after.y, after.x)
		var bisector := (right_before + right_after).normalized()
		lane.append(center[i] + bisector * minf(2.6, LANE_OFFSET / maxf(0.4, bisector.dot(right_before))))
	var rounded: Array[Vector2] = [from]
	# Include a remote source junction in the rounded geometry too; otherwise
	# a depot departure would enter that first ninety-degree bend squarely.
	if from.distance_to(lane[0]) > 8.0:
		lane.push_front(from)
	for i in range(1, lane.size()-1):
		var radius := minf(6.0, minf(lane[i].distance_to(lane[i-1]), lane[i].distance_to(lane[i+1])) * 0.4)
		var enter := lane[i].move_toward(lane[i-1], radius)
		var leave := lane[i].move_toward(lane[i+1], radius)
		rounded.append(enter)
		for step in range(1, 9):
			var t := float(step) / 8.0
			rounded.append(enter.lerp(lane[i], t).lerp(lane[i].lerp(leave, t), t))
	rounded.append(lane.back())
	return rounded


## Long inspections and social visits park beside the receiving lane; they must
## never monopolize a loading bay while a tanker waits to transfer its cargo.
static func service_parking_bays() -> Dictionary:
	return {"oil_rig":Vector2(127,-30),"refinery":Vector2(88,9),
		"housing":Vector2(-38,21),"town_square":Vector2(-6,10),
		"earth_market":Vector2(-7,-12)}
