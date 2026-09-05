class_name CrownreachTerrain
extends RefCounted
## A single terrain contract for all visual LODs, wheels and physical chunks.
const Plan = preload("res://scripts/city_plan.gd")
const Highways = preload("res://scripts/highway_plan.gd")
const BLEND := 480.0

static func weight(point: Vector2) -> float:
	var outside := Vector2(maxf(Plan.MIN_X - point.x, maxf(0.0, point.x - Plan.MAX_X)),
		maxf(Plan.MIN_Z - point.y, maxf(0.0, point.y - Plan.MAX_Z)))
	return 1.0 - smoothstep(0.0, BLEND, outside.length())

static func access_weight(point: Vector2) -> float:
	if point.x < 880.0 or point.x > Plan.MIN_X: return 0.0
	return (1.0 - smoothstep(14.0, 40.0, absf(point.y))) \
		* smoothstep(880.0, 980.0, point.x)

static func grade(point: Vector2, original: float) -> float:
	var access := access_weight(point)
	var h := lerpf(original, lerpf(3.25, Plan.GROUND_Y,
		clampf((point.x - 930.0) / (Plan.MIN_X - 930.0), 0.0, 1.0)), access)
	h = lerpf(h, Plan.GROUND_Y, weight(point)) - Plan.pond_depth(point)
	var highway := Highways.ground_sample(point)
	return lerpf(h,float(highway.height),float(highway.weight))

static func road_distance(point: Vector2, spacing: Vector2 = Plan.STREET_SPACING) -> float:
	var p := point - Vector2(Plan.MIN_X, Plan.MIN_Z)
	var x := fposmod(p.x + spacing.x * .5, spacing.x) - spacing.x * .5
	var z := fposmod(p.y + spacing.y * .5, spacing.y) - spacing.y * .5
	return minf(absf(x),absf(z))

static func color(point: Vector2, original: Color) -> Color:
	if Plan.contains(point):
		if Plan.is_park(point):
			return Color("807b60") if Plan.pond_depth(point)>0.0 else Color("577d43")
		var square := point - Plan.CENTER
		if absf(square.x)<Plan.PLAZA_HALF_EXTENT and absf(square.y)<Plan.PLAZA_HALF_EXTENT:
			return Color("b6afa0")
		var road := road_distance(point)
		if road < Plan.MAJOR_ROAD_HALF_WIDTH: return Color("343c43")
		if road < Plan.MAJOR_ROAD_HALF_WIDTH+Plan.SIDEWALK_WIDTH: return Color("b1ada0")
		return Color("92928a")
	var road_color := original.lerp(Color("343c43"),access_weight(point))
	var highway := Highways.ground_sample(point)
	return road_color.lerp(Color("71805e"),float(highway.weight)*.6)

static func reserved(point: Vector2, margin := 0.0) -> bool:
	return (point.x >= Plan.MIN_X - margin and point.x <= Plan.MAX_X + margin \
		and point.y >= Plan.MIN_Z - margin and point.y <= Plan.MAX_Z + margin) \
		or Highways.reserved(point,margin)

static func reserved_chunk(cx: int, cz: int, size: float) -> bool:
	return reserved(Vector2((cx + 0.5) * size, (cz + 0.5) * size), size * 0.5) \
		or access_weight(Vector2((cx + 0.5) * size, (cz + 0.5) * size)) > 0.0
