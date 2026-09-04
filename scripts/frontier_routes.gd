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
