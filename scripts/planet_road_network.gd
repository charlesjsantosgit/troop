class_name PlanetRoadNetwork
extends RefCounted
## Deterministic, constant-time, planet-wide curved road network.
##
## Two non-orthogonal road families are drawn in one shared analytic domain
## warp. In warped space every route is a straight numbered contour, which
## makes intersections exact and route IDs stable; in world space the same
## contours become long, gently curving arterials instead of a visible square
## grid. Point queries inspect exactly four candidates (two tiers x two route
## families), while rectangle queries have a hard segment budget.
##
## All point samples canonicalise through the same spherical chart convention
## as PlanetTerrain. The harmonic warp repeats after half a circumference in
## longitude, and every spacing divides that half-circumference exactly. Routes
## therefore retain their IDs at the longitude seam and after pole reflection.

const PlanetTerrainScript = preload("res://scripts/planet_terrain.gd")

const HIGHWAY_SPACING := 3072.0
const REGIONAL_SPACING := 768.0
const HIGHWAY_HALF_WIDTH := 7.2
const REGIONAL_HALF_WIDTH := 4.8
const SHOULDER := 14.0
const MAX_SEGMENTS_PER_QUERY := 128

const _FAMILY_LONGITUDE := 0
const _FAMILY_CROSS_COUNTRY := 1
const _TIER_HIGHWAY := 0
const _TIER_REGIONAL := 1

# Integer harmonics make the warp bit-for-bit periodic at the planet seam.
# Every longitude harmonic is even, so the field also repeats after the 180
# degree longitude shift used by a pole reflection. Long waves establish broad
# route shape; the lower-amplitude short waves keep neighbouring corridors from
# reading as parallel ruler lines without producing bumpy steering.
const _WARP_X_LONG_Z_CYCLES := 2088.0
const _WARP_X_SHORT_X_CYCLES := 6524.0
const _WARP_X_SHORT_Z_CYCLES := 3262.0
const _WARP_Z_LONG_X_CYCLES := 1876.0
const _WARP_Z_SHORT_X_CYCLES := 5218.0
const _WARP_Z_SHORT_Z_CYCLES := 6524.0
const _WARP_X_LONG_AMPLITUDE := 180.0
const _WARP_X_SHORT_AMPLITUDE := 58.0
const _WARP_Z_LONG_AMPLITUDE := 150.0
const _WARP_Z_SHORT_AMPLITUDE := 52.0
const _MAX_DOMAIN_WARP := 255.0
const _CURVE_CHORD_LENGTH := 384.0
const _FAMILY_A_ALONG_SCALE := 0.8944271909999159 # 1 / sqrt(1.25)
const _FAMILY_B_ALONG_SCALE := 0.7071067811865475 # 1 / sqrt(2)

var seed := 1337
var _profile := FastNoiseLite.new()
var _warp_phase_a := 0.0
var _warp_phase_b := 0.0
var _warp_phase_c := 0.0
var _warp_phase_d := 0.0


func setup(seed_value: int) -> void:
	seed = seed_value
	_profile.seed = seed_value + 90121
	_profile.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_profile.frequency = 0.000032
	_profile.fractal_type = FastNoiseLite.FRACTAL_FBM
	_profile.fractal_octaves = 3
	_profile.fractal_lacunarity = 2.0
	_profile.fractal_gain = 0.46
	_warp_phase_a = _seed_phase(11)
	_warp_phase_b = _seed_phase(23)
	_warp_phase_c = _seed_phase(37)
	_warp_phase_d = _seed_phase(53)


## Geometry-only closest road. Gen owns terrain/coast eligibility and the
## engineered elevation audit, avoiding recursion when a road grades terrain.
## Compatibility fields from the original lattice remain present; `axis` now
## names the dominant route family, while `tangent` is authoritative.
func surface_sample(world_xz: Vector2) -> Dictionary:
	var point: Vector2 = _canonical_xz(world_xz)
	var phase_x: float = TAU * point.x / PlanetTerrainScript.CIRCUMFERENCE
	var phase_z: float = TAU * point.y / PlanetTerrainScript.CIRCUMFERENCE
	var angle_a: float = _WARP_X_LONG_Z_CYCLES * phase_z + _warp_phase_a
	var angle_b: float = _WARP_X_SHORT_X_CYCLES * phase_x \
		+ _WARP_X_SHORT_Z_CYCLES * phase_z + _warp_phase_b
	var angle_c: float = _WARP_Z_LONG_X_CYCLES * phase_x + _warp_phase_c
	var angle_d: float = _WARP_Z_SHORT_X_CYCLES * phase_x \
		- _WARP_Z_SHORT_Z_CYCLES * phase_z + _warp_phase_d
	var frequency_scale: float = TAU / PlanetTerrainScript.CIRCUMFERENCE
	var warp_x: float = _WARP_X_LONG_AMPLITUDE * sin(angle_a) \
		+ _WARP_X_SHORT_AMPLITUDE * sin(angle_b)
	var warp_z: float = _WARP_Z_LONG_AMPLITUDE * sin(angle_c) \
		+ _WARP_Z_SHORT_AMPLITUDE * sin(angle_d)
	var warped_x: float = point.x + warp_x
	var warped_z: float = point.y + warp_z
	# Jacobian of warped coordinates with respect to the local world chart.
	var dxx: float = 1.0 + _WARP_X_SHORT_AMPLITUDE * cos(angle_b) \
		* _WARP_X_SHORT_X_CYCLES * frequency_scale
	var dxz: float = _WARP_X_LONG_AMPLITUDE * cos(angle_a) \
		* _WARP_X_LONG_Z_CYCLES * frequency_scale \
		+ _WARP_X_SHORT_AMPLITUDE * cos(angle_b) \
		* _WARP_X_SHORT_Z_CYCLES * frequency_scale
	var dzx: float = _WARP_Z_LONG_AMPLITUDE * cos(angle_c) \
		* _WARP_Z_LONG_X_CYCLES * frequency_scale \
		+ _WARP_Z_SHORT_AMPLITUDE * cos(angle_d) \
		* _WARP_Z_SHORT_X_CYCLES * frequency_scale
	var dzz: float = 1.0 - _WARP_Z_SHORT_AMPLITUDE * cos(angle_d) \
		* _WARP_Z_SHORT_Z_CYCLES * frequency_scale

	var best_edge_distance: float = INF
	var best_distance: float = INF
	var best_half_width: float = REGIONAL_HALF_WIDTH
	var best_delta: float = 0.0
	var best_gradient := Vector2.RIGHT
	var best_family: int = _FAMILY_LONGITUDE
	var best_tier_code: int = _TIER_REGIONAL
	var best_raw_index: int = 0
	var best_stable_index: int = 0
	var best_spacing: float = REGIONAL_SPACING
	var family_a_edge: float = INF
	var family_a_distance: float = INF
	var family_a_half_width: float = REGIONAL_HALF_WIDTH
	var family_a_route_id := ""
	var family_b_edge: float = INF
	var family_b_distance: float = INF
	var family_b_half_width: float = REGIONAL_HALF_WIDTH
	var family_b_route_id := ""

	# Fixed four-candidate search: highways win exact ties over their coincident
	# regional contour, so one physical centreline always has one visible tier.
	for candidate in range(4):
		var tier_code: int = _TIER_HIGHWAY if candidate < 2 \
			else _TIER_REGIONAL
		var family: int = candidate & 1
		var spacing: float = HIGHWAY_SPACING if tier_code == _TIER_HIGHWAY \
			else REGIONAL_SPACING
		var half_width: float = HIGHWAY_HALF_WIDTH \
			if tier_code == _TIER_HIGHWAY else REGIONAL_HALF_WIDTH
		var coordinate: float
		var gradient: Vector2
		if family == _FAMILY_LONGITUDE:
			# Dominantly north/south, but tilted about 27 degrees before warping.
			coordinate = warped_x + warped_z * 0.5
			gradient = Vector2(dxx + dzx * 0.5, dxz + dzz * 0.5)
		else:
			# A 45 degree cross-country family intersects the first at ~72
			# degrees, avoiding an orthogonal city-block silhouette.
			coordinate = warped_z - warped_x
			gradient = Vector2(dzx - dxx, dzz - dxz)
		var raw_index: int = roundi(coordinate / spacing)
		var delta: float = coordinate - float(raw_index) * spacing
		var gradient_length: float = maxf(gradient.length(), 0.001)
		var distance: float = absf(delta) / gradient_length
		var edge_distance: float = distance - half_width
		var stable_index: int = _stable_line_index(raw_index, spacing)
		var route_id: String = _route_id(tier_code, family, stable_index)
		if family == _FAMILY_LONGITUDE and edge_distance < family_a_edge:
			family_a_edge = edge_distance
			family_a_distance = distance
			family_a_half_width = half_width
			family_a_route_id = route_id
		elif family == _FAMILY_CROSS_COUNTRY and edge_distance < family_b_edge:
			family_b_edge = edge_distance
			family_b_distance = distance
			family_b_half_width = half_width
			family_b_route_id = route_id
		if edge_distance < best_edge_distance:
			best_edge_distance = edge_distance
			best_distance = distance
			best_half_width = half_width
			best_delta = delta
			best_gradient = gradient
			best_family = family
			best_tier_code = tier_code
			best_raw_index = raw_index
			best_stable_index = stable_index
			best_spacing = spacing

	# One Newton projection is sub-millimetre accurate over a 14 m shoulder
	# because the warp turns over across kilometres, not metres.
	var correction: Vector2 = -best_gradient * (best_delta \
		/ maxf(best_gradient.length_squared(), 0.000001))
	var center_point: Vector2 = point + correction
	var center_warped_x: float = warped_x + dxx * correction.x \
		+ dxz * correction.y
	var center_warped_z: float = warped_z + dzx * correction.x \
		+ dzz * correction.y
	var tangent := Vector2(-best_gradient.y, best_gradient.x).normalized()
	var along: float
	var axis: String
	var curve_offset: float
	if best_family == _FAMILY_LONGITUDE:
		if tangent.dot(Vector2(-0.5, 1.0)) < 0.0:
			tangent = -tangent
		along = (-0.5 * center_warped_x + center_warped_z) \
			* _FAMILY_A_ALONG_SCALE
		axis = "longitude"
		curve_offset = Vector2(warp_x, warp_z).dot(
			Vector2(1.0, 0.5).normalized())
	else:
		if tangent.dot(Vector2(1.0, 1.0)) < 0.0:
			tangent = -tangent
		along = (center_warped_x + center_warped_z) \
			* _FAMILY_B_ALONG_SCALE
		axis = "latitude"
		curve_offset = Vector2(warp_x, warp_z).dot(
			Vector2(-1.0, 1.0).normalized())

	var tier: String = "highway" if best_tier_code == _TIER_HIGHWAY \
		else "regional"
	var route_id: String = _route_id(best_tier_code, best_family,
		best_stable_index)
	var bridge_spacing: float = 6144.0 \
		if best_tier_code == _TIER_HIGHWAY else 3072.0
	var bridge_phase: float = _route_unit(best_tier_code, best_family,
		best_stable_index, 79)
	var bridge_slot: int = roundi(along / bridge_spacing - bridge_phase)
	var bridge_coordinate: float = (float(bridge_slot) + bridge_phase) \
		* bridge_spacing
	var bridge_score := 0.0
	var bridge_id := ""
	if best_distance <= best_half_width + SHOULDER:
		var bridge_distance: float = absf(along - bridge_coordinate)
		bridge_score = 1.0 - smoothstep(180.0, 430.0, bridge_distance)
		if bridge_score > 0.0:
			bridge_id = "%s:bridge:%d" % [route_id, bridge_slot]

	# Both contours use the same invertible domain warp, so this soft overlap is
	# a deterministic geometric intersection rather than a proximity guess
	# between independently jittered polylines.
	var family_a_grade: float = 1.0 - smoothstep(family_a_half_width,
		family_a_half_width + SHOULDER, family_a_distance)
	var family_b_grade: float = 1.0 - smoothstep(family_b_half_width,
		family_b_half_width + SHOULDER, family_b_distance)
	var intersection_score: float = family_a_grade * family_b_grade
	var intersection_id := ""
	if intersection_score > 0.0:
		intersection_id = "%s|%s" % [family_a_route_id, family_b_route_id] \
			if family_a_route_id < family_b_route_id \
			else "%s|%s" % [family_b_route_id, family_a_route_id]

	return {
		"distance": best_distance,
		"half_width": best_half_width,
		"grade": 1.0 - smoothstep(best_half_width,
			best_half_width + SHOULDER, best_distance),
		"route_id": route_id,
		"tier": tier,
		"axis": axis,
		"line_index": best_stable_index,
		"center_point": center_point,
		"tangent": tangent,
		"route_coordinate": along,
		"along": along,
		"curve_offset": curve_offset,
		"bridge_candidate": bridge_score > 0.0,
		"bridge_candidate_score": bridge_score,
		"bridge_slot": bridge_slot,
		"bridge_coordinate": bridge_coordinate,
		"bridge_id": bridge_id,
		"intersection_score": intersection_score,
		"intersection_id": intersection_id,
		"family": _family_name(best_family),
		"raw_line_index": best_raw_index,
		"spacing": best_spacing,
		# Geometry queries sit in the terrain vertex hot path. Gen supplies the
		# audited terrain-following profile only for a nearby eligible road.
		"elevation": 0.0,
	}


## One shared spherical profile lets intersecting routes meet at exactly the
## same height. Gen may later replace a local interval with a bridge/tunnel
## profile selected by route_id + route_coordinate.
func profile_elevation(world_xz: Vector2) -> float:
	var canonical: Vector2 = _canonical_xz(world_xz)
	var longitude: float = canonical.x / PlanetTerrainScript.RADIUS
	var latitude: float = canonical.y / PlanetTerrainScript.RADIUS
	var latitude_cosine: float = cos(latitude)
	var point := Vector3(latitude_cosine * cos(longitude), sin(latitude),
		latitude_cosine * sin(longitude)) * PlanetTerrainScript.RADIUS
	var profile_noise: float = _profile.get_noise_3d(point.x, point.y, point.z)
	return 54.0 + profile_noise * 125.0


## Bounded local polyline representation for streamed meshes, map overlays and
## navigation. Curves are emitted as <=384 m chords when budget allows. Huge
## rectangles remain fixed-cost: candidates are selected nearest the rectangle
## centre and the hard 128-segment cap is never exceeded.
func segments_in_rect(rect: Rect2,
		max_segments := MAX_SEGMENTS_PER_QUERY) -> Array:
	var budget: int = clampi(max_segments, 0, MAX_SEGMENTS_PER_QUERY)
	var segments: Array = []
	if budget == 0 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return segments
	var corners := PackedVector2Array([
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	])
	var route_candidates: Array[Dictionary] = []
	var center: Vector2 = rect.get_center()
	for candidate in range(4):
		var tier_code: int = _TIER_HIGHWAY if candidate < 2 \
			else _TIER_REGIONAL
		var family: int = candidate & 1
		var spacing: float = HIGHWAY_SPACING if tier_code == _TIER_HIGHWAY \
			else REGIONAL_SPACING
		var minimum_u := INF
		var maximum_u := -INF
		var minimum_v := INF
		var maximum_v := -INF
		for corner in corners:
			var uv: Vector2 = _family_uv_unwrapped(corner, family)
			minimum_u = minf(minimum_u, uv.x)
			maximum_u = maxf(maximum_u, uv.x)
			minimum_v = minf(minimum_v, uv.y)
			maximum_v = maxf(maximum_v, uv.y)
		# Corner extrema can miss a harmonic crest inside a very large rect.
		# The analytic amplitude bound catches it without sampling an area grid.
		minimum_u -= _MAX_DOMAIN_WARP * 2.0
		maximum_u += _MAX_DOMAIN_WARP * 2.0
		minimum_v -= _MAX_DOMAIN_WARP * 2.0
		maximum_v += _MAX_DOMAIN_WARP * 2.0
		var first_index: int = ceili(minimum_u / spacing)
		var last_index: int = floori(maximum_u / spacing)
		if first_index > last_index:
			continue
		var center_uv: Vector2 = _family_uv_unwrapped(center, family)
		var center_index: int = clampi(roundi(center_uv.x / spacing),
			first_index, last_index)
		var indices: PackedInt32Array = _bounded_line_indices(first_index,
			last_index, center_index, budget)
		for raw_index in indices:
			# The highway contour owns every fourth regional centreline.
			if tier_code == _TIER_REGIONAL and posmod(raw_index, 4) == 0:
				continue
			var stable_index: int = _stable_line_index(raw_index, spacing)
			route_candidates.append({
				"tier_code": tier_code,
				"family": family,
				"spacing": spacing,
				"raw_index": raw_index,
				"stable_index": stable_index,
				"u": float(raw_index) * spacing,
				"minimum_v": minimum_v,
				"maximum_v": maximum_v,
				"priority": absf(center_uv.x - float(raw_index) * spacing),
			})
	# Sorting at most 4*budget tiny descriptors keeps large-map queries centred
	# without ever walking every route across an Earth-sized rectangle.
	route_candidates.sort_custom(func(a: Dictionary, b: Dictionary):
		return float(a.priority) < float(b.priority))
	var route_count: int = mini(route_candidates.size(), budget)
	if route_count == 0:
		return segments
	var pieces_per_route: int = maxi(budget / route_count, 1)
	var extra_pieces: int = budget % route_count
	for route_number in range(route_count):
		if segments.size() >= budget:
			break
		var route: Dictionary = route_candidates[route_number]
		var tier_code: int = int(route.tier_code)
		var family: int = int(route.family)
		var raw_index: int = int(route.raw_index)
		var stable_index: int = int(route.stable_index)
		var u: float = float(route.u)
		var minimum_v: float = float(route.minimum_v)
		var maximum_v: float = float(route.maximum_v)
		var v_span: float = maxf(maximum_v - minimum_v, 1.0)
		var route_budget: int = pieces_per_route \
			+ (1 if route_number < extra_pieces else 0)
		var desired_pieces: int = maxi(ceili(v_span / _CURVE_CHORD_LENGTH), 1)
		var piece_count: int = mini(desired_pieces, route_budget)
		var half_width: float = HIGHWAY_HALF_WIDTH \
			if tier_code == _TIER_HIGHWAY else REGIONAL_HALF_WIDTH
		var route_id: String = _route_id(tier_code, family, stable_index)
		var along_scale: float = _FAMILY_A_ALONG_SCALE \
			if family == _FAMILY_LONGITUDE else _FAMILY_B_ALONG_SCALE
		for piece in range(piece_count):
			if segments.size() >= budget:
				break
			var v_a: float = lerpf(minimum_v, maximum_v,
				float(piece) / float(piece_count))
			var v_b: float = lerpf(minimum_v, maximum_v,
				float(piece + 1) / float(piece_count))
			var raw_a: Vector2 = _curve_point(family, u, v_a)
			var raw_b: Vector2 = _curve_point(family, u, v_b)
			var clipped: PackedVector2Array = _clip_segment_to_rect(raw_a,
				raw_b, rect.grow(half_width))
			if clipped.size() != 2:
				continue
			var a: Vector2 = clipped[0]
			var b: Vector2 = clipped[1]
			if a.distance_squared_to(b) < 0.0001:
				continue
			var tangent: Vector2 = (b - a).normalized()
			var expected_tangent := Vector2(-0.5, 1.0) \
				if family == _FAMILY_LONGITUDE else Vector2(1.0, 1.0)
			if tangent.dot(expected_tangent) < 0.0:
				var swap := a
				a = b
				b = swap
				tangent = -tangent
			var route_coordinate: float = (v_a + v_b) * 0.5 * along_scale
			var bridge_spacing: float = 6144.0 \
				if tier_code == _TIER_HIGHWAY else 3072.0
			var bridge_phase: float = _route_unit(tier_code, family,
				stable_index, 79)
			var bridge_slot: int = roundi(route_coordinate / bridge_spacing \
				- bridge_phase)
			var bridge_center: float = (float(bridge_slot) + bridge_phase) \
				* bridge_spacing
			var bridge_score: float = 1.0 - smoothstep(180.0, 430.0,
				absf(route_coordinate - bridge_center))
			var midpoint: Vector2 = (a + b) * 0.5
			var unwarped_uv: Vector2 = _family_uv_without_warp(midpoint,
				family)
			segments.append({
				"id": route_id,
				"tier": "highway" if tier_code == _TIER_HIGHWAY \
					else "regional",
				"half_width": half_width,
				"a": a,
				"b": b,
				"axis": "longitude" if family == _FAMILY_LONGITUDE \
					else "latitude",
				"family": _family_name(family),
				"line_index": stable_index,
				"tangent": tangent,
				"route_coordinate": route_coordinate,
				"along": route_coordinate,
				"curve_offset": (u - unwarped_uv.x) \
					/ (1.11803398875 if family == _FAMILY_LONGITUDE \
					else 1.41421356237),
				"bridge_candidate": bridge_score > 0.0,
				"bridge_candidate_score": bridge_score,
				"bridge_slot": bridge_slot,
				"bridge_coordinate": bridge_center,
				"bridge_id": "%s:bridge:%d" % [route_id, bridge_slot] \
					if bridge_score > 0.0 else "",
			})
	return segments


func _canonical_xz(world_xz: Vector2) -> Vector2:
	var longitude: float = world_xz.x / PlanetTerrainScript.RADIUS
	var latitude: float = world_xz.y / PlanetTerrainScript.RADIUS
	while latitude > PI * 0.5:
		latitude = PI - latitude
		longitude += PI
	while latitude < -PI * 0.5:
		latitude = -PI - latitude
		longitude += PI
	return Vector2(wrapf(longitude, -PI, PI) * PlanetTerrainScript.RADIUS,
		latitude * PlanetTerrainScript.RADIUS)


func _domain_warp_offset(point: Vector2) -> Vector2:
	var phase_x: float = TAU * point.x / PlanetTerrainScript.CIRCUMFERENCE
	var phase_z: float = TAU * point.y / PlanetTerrainScript.CIRCUMFERENCE
	return Vector2(
		_WARP_X_LONG_AMPLITUDE * sin(_WARP_X_LONG_Z_CYCLES * phase_z
			+ _warp_phase_a)
			+ _WARP_X_SHORT_AMPLITUDE * sin(
				_WARP_X_SHORT_X_CYCLES * phase_x
				+ _WARP_X_SHORT_Z_CYCLES * phase_z + _warp_phase_b),
		_WARP_Z_LONG_AMPLITUDE * sin(_WARP_Z_LONG_X_CYCLES * phase_x
			+ _warp_phase_c)
			+ _WARP_Z_SHORT_AMPLITUDE * sin(
				_WARP_Z_SHORT_X_CYCLES * phase_x
				- _WARP_Z_SHORT_Z_CYCLES * phase_z + _warp_phase_d))


func _family_uv_unwrapped(point: Vector2, family: int) -> Vector2:
	var warped: Vector2 = point + _domain_warp_offset(point)
	if family == _FAMILY_LONGITUDE:
		return Vector2(warped.x + warped.y * 0.5,
			-warped.x * 0.5 + warped.y)
	return Vector2(warped.y - warped.x, warped.x + warped.y)


func _family_uv_without_warp(point: Vector2, family: int) -> Vector2:
	if family == _FAMILY_LONGITUDE:
		return Vector2(point.x + point.y * 0.5, -point.x * 0.5 + point.y)
	return Vector2(point.y - point.x, point.x + point.y)


## Invert a warped-space route coordinate with three bounded fixed-point
## iterations. The warp Jacobian stays near identity, so residual error is well
## below a centimetre while map/chunk queries remain deterministic.
func _curve_point(family: int, u: float, v: float) -> Vector2:
	var warped_point: Vector2
	if family == _FAMILY_LONGITUDE:
		warped_point = Vector2((u - 0.5 * v) / 1.25,
			(0.5 * u + v) / 1.25)
	else:
		warped_point = Vector2((v - u) * 0.5, (v + u) * 0.5)
	var point := warped_point
	for iteration in range(3):
		point = warped_point - _domain_warp_offset(point)
	return point


func _bounded_line_indices(first_index: int, last_index: int,
		center_index: int, limit: int) -> PackedInt32Array:
	var indices := PackedInt32Array()
	var radius := 0
	var maximum_radius: int = last_index - first_index + 1
	while indices.size() < limit and radius <= maximum_radius:
		if radius == 0:
			if center_index >= first_index and center_index <= last_index:
				indices.append(center_index)
		else:
			var positive := center_index + radius
			if positive <= last_index:
				indices.append(positive)
				if indices.size() >= limit:
					break
			var negative := center_index - radius
			if negative >= first_index:
				indices.append(negative)
		radius += 1
	return indices


func _clip_segment_to_rect(a: Vector2, b: Vector2,
		rect: Rect2) -> PackedVector2Array:
	var delta := b - a
	var t_min := 0.0
	var t_max := 1.0
	for axis in range(2):
		var start: float = a.x if axis == 0 else a.y
		var direction: float = delta.x if axis == 0 else delta.y
		var lower: float = rect.position.x if axis == 0 else rect.position.y
		var upper: float = rect.end.x if axis == 0 else rect.end.y
		if absf(direction) < 0.000001:
			if start < lower or start > upper:
				return PackedVector2Array()
			continue
		var enter: float = (lower - start) / direction
		var leave: float = (upper - start) / direction
		if enter > leave:
			var swap := enter
			enter = leave
			leave = swap
		t_min = maxf(t_min, enter)
		t_max = minf(t_max, leave)
		if t_min > t_max:
			return PackedVector2Array()
	return PackedVector2Array([a + delta * t_min, a + delta * t_max])


func _stable_line_index(raw_index: int, spacing: float) -> int:
	# Half a circumference is the longitude shift applied at a pole. Because
	# both public spacings divide it exactly, this modulo identifies the same
	# physical route on either chart image without merging neighbouring roads.
	var period: int = maxi(roundi(PlanetTerrainScript.HALF_CIRCUMFERENCE
		/ spacing), 1)
	return posmod(raw_index, period)


func _route_id(tier_code: int, family: int, line_index: int) -> String:
	return "%s:%s:%d" % [
		"highway" if tier_code == _TIER_HIGHWAY else "regional",
		_family_name(family), line_index]


func _family_name(family: int) -> String:
	return "sweeping_meridian" if family == _FAMILY_LONGITUDE \
		else "cross_country"


func _seed_phase(salt: int) -> float:
	var mixed: int = posmod(seed * 1103515245 + salt * 19349663,
		2147483629)
	return TAU * float(mixed) / 2147483629.0


func _route_unit(tier_code: int, family: int, line_index: int,
		salt: int) -> float:
	var mixed: int = posmod(seed * 73856093 + line_index * 19349663
		+ family * 83492791 + tier_code * 26544357 + salt * 7919,
		2147483629)
	return float(mixed) / 2147483629.0
