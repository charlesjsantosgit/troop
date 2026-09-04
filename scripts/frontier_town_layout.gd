class_name FrontierTownLayout
extends RefCounted
## Shared geography for terrain, authoritative proximity and visible towns.

const EARTH_ORIGINS := {
	"canopy": Vector2(0, 0), "harbor": Vector2(650, 0),
	"ridge": Vector2(-600, -400),
}
const MOON_DIRECTIONS := {
	"canopy": Vector3(-85, 450, 105), "harbor": Vector3(0.8, 0.45, -0.5),
	"ridge": Vector3(-0.7, -0.35, -0.6),
}
const TOWN_RADIUS := 200.0
const TOWN_BLEND_RADIUS := 280.0
const GROUND_HEIGHT := 3.25
const ROAD_HALF_WIDTH := 4.2
const ROAD_SHOULDER := 20.0
const CONNECTING_ROADS := [
	[Vector2(120, 10), Vector2(230, 10), Vector2(320, 45),
		Vector2(420, 45), Vector2(520, 4), Vector2(650, 4)],
	[Vector2(-58, -15), Vector2(-200, -45), Vector2(-310, -160),
		Vector2(-405, -270), Vector2(-485, -350), Vector2(-600, -396)],
]


static func nearest_earth_center(point: Vector2) -> Vector2:
	var nearest := Vector2.ZERO
	var best := INF
	for origin: Vector2 in EARTH_ORIGINS.values():
		var distance := point.distance_squared_to(origin)
		if distance < best:
			best = distance
			nearest = origin
	return nearest


static func road_distance(point: Vector2) -> float:
	if point.x < -850 or point.x > 930 or point.y < -680 or point.y > 280:
		return INF
	var best := INF
	for road: Array in CONNECTING_ROADS:
		for index in range(road.size() - 1):
			var a: Vector2 = road[index]
			var segment: Vector2 = road[index + 1] - a
			var fraction := clampf((point - a).dot(segment) / segment.length_squared(), 0.0, 1.0)
			best = minf(best, point.distance_to(a + segment * fraction))
	return best


static func terrain_weight(point: Vector2) -> float:
	var town := 1.0 - smoothstep(TOWN_RADIUS, TOWN_BLEND_RADIUS,
		point.distance_to(nearest_earth_center(point)))
	if town >= 1.0 or point.x < -850 or point.x > 930 or point.y < -680 or point.y > 280:
		return town
	var road := 1.0 - smoothstep(ROAD_SHOULDER, ROAD_SHOULDER + 34.0, road_distance(point))
	return maxf(town, road)


static func touches_town(cx: int, cz: int, chunk_size: float) -> bool:
	for center: Vector2 in EARTH_ORIGINS.values():
		var nearest := Vector2(clampf(center.x, cx * chunk_size, (cx + 1) * chunk_size),
			clampf(center.y, cz * chunk_size, (cz + 1) * chunk_size))
		if nearest.distance_squared_to(center) < TOWN_RADIUS * TOWN_RADIUS:
			return true
	return false


static func world_frame(town: Dictionary, moon: Node3D = null) -> Transform3D:
	if str(town.get("planet", "earth")) == "moon" and is_instance_valid(moon):
		var raw: Array = town.get("moon_direction", [-85, 450, 105])
		var up := Vector3(float(raw[0]), float(raw[1]), float(raw[2])).normalized()
		var right := Vector3.FORWARD.cross(up).normalized()
		var local := Transform3D(Basis(right, up, right.cross(up)).orthonormalized(),
			moon.call("surface_position", up, 0.02))
		return moon.global_transform * local
	var origin: Array = town.get("origin", [0, 0])
	return Transform3D(Basis.IDENTITY, Vector3(float(origin[0]), 0, float(origin[1])))
