class_name PlanetTerrain
extends RefCounted
## Deterministic Earth-like macro terrain sampled on a sphere.
##
## Gameplay terrain remains a locally-flat equirectangular chart, but every
## field is evaluated from the matching point on a sphere. Longitude therefore
## joins exactly, and walking through either pole reflects latitude and advances
## longitude by 180 degrees instead of creating a torus or a hard map edge.

const CIRCUMFERENCE := 98304.0 # exactly 2,048 of Gen's 48 m chunks
const HALF_CIRCUMFERENCE := CIRCUMFERENCE * 0.5
const QUARTER_CIRCUMFERENCE := CIRCUMFERENCE * 0.25
const RADIUS := CIRCUMFERENCE / TAU
const SEA_LEVEL := 0.55
const SUMMIT_ELEVATION := 6000.0
const HOME_EFFECT_RADIUS := 6200.0
const SUMMIT_EFFECT_RADIUS := 4200.0
const HOME_EFFECT_DOT_MIN := cos(HOME_EFFECT_RADIUS / RADIUS)
const SUMMIT_EFFECT_DOT_MIN := cos(SUMMIT_EFFECT_RADIUS / RADIUS)
# All macro fields turn over across kilometres. Sampling their shared spherical
# noise on this topology-aligned lattice and interpolating between nodes keeps
# the same continuous planet while amortizing six costly noise evaluations
# across thousands of 3-192 m streaming vertices. 768 divides the longitude
# circumference and 180-degree pole shift exactly, so no seam is introduced.
const MACRO_LATTICE_STEP := 768.0
const MACRO_FIELD_COUNT := 6

var seed := 1337
var _summit_xz := Vector2.ZERO
var _summit_direction := Vector3.RIGHT
var _home_lake_center := Vector2.ZERO

var _continent := FastNoiseLite.new()
var _continent_detail := FastNoiseLite.new()
var _upland := FastNoiseLite.new()
var _range_mask := FastNoiseLite.new()
var _ridge := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _lake := FastNoiseLite.new()
var _macro_lattice_cache: Dictionary = {}


func setup(seed_value: int) -> void:
	seed = seed_value
	_macro_lattice_cache.clear()
	_configure_noise(_continent, 11, 0.000115, 3, 0.52)
	_configure_noise(_continent_detail, 23, 0.00029, 2, 0.48)
	# Continental uplands turn over across many kilometres. This intentionally
	# keeps normal travel on long grades instead of stacking noisy short bumps.
	_configure_noise(_upland, 37, 0.000018, 2, 0.50)
	_configure_noise(_range_mask, 47, 0.00015, 2, 0.50)
	_configure_noise(_ridge, 59, 0.00043, 2, 0.46)
	# Fine relief is under 1.5 m and exists only to break up otherwise broad
	# slopes. One simplex octave preserves that readable surface variation while
	# halving the only spherical noise still evaluated at every terrain vertex.
	_configure_noise(_detail, 83, 0.0048, 1, 0.40)
	_configure_noise(_lake, 97, 0.00031, 2, 0.48)

	# One seed-derived summit is deliberately isolated from the home continent.
	# The exact centre is pinned to 6,000 m after all natural terrain layers.
	var summit_hash := _hash_unit(seed_value, 401)
	var summit_lon := lerpf(-PI, PI, summit_hash.x)
	var summit_lat := deg_to_rad(lerpf(24.0, 52.0, summit_hash.y))
	if ((seed_value >> 3) & 1) != 0:
		summit_lat = -summit_lat
	_summit_xz = Vector2(summit_lon * RADIUS, summit_lat * RADIUS)
	var summit_latitude_cosine := cos(summit_lat)
	_summit_direction = Vector3(summit_latitude_cosine * cos(summit_lon),
		sin(summit_lat), summit_latitude_cosine * sin(summit_lon))

	# A broad home lake makes the existing airboat/dock contract reliable while
	# still letting the macro lake field make much larger inland water systems.
	var lake_hash := _hash_unit(seed_value, 733)
	var lake_angle := TAU * lake_hash.x
	var lake_radius := lerpf(330.0, 430.0, lake_hash.y)
	_home_lake_center = Vector2.from_angle(lake_angle) * lake_radius


func _configure_noise(noise: FastNoiseLite, salt: int, frequency: float,
		octaves: int, gain: float) -> void:
	noise.seed = seed + salt * 7919
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = gain


func _hash_unit(seed_value: int, salt: int) -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 73856093 + salt * 19349663
	return Vector2(rng.randf(), rng.randf())


## Canonical equirectangular sample and the orientation change needed to keep a
## traveller moving geographically straight after a pole reflection.
func canonical_world_sample(world_xz: Vector2) -> Dictionary:
	var longitude := world_xz.x / RADIUS
	var latitude := world_xz.y / RADIUS
	var pole_crossings := 0
	while latitude > PI * 0.5:
		latitude = PI - latitude
		longitude += PI
		pole_crossings += 1
	while latitude < -PI * 0.5:
		latitude = -PI - latitude
		longitude += PI
		pole_crossings += 1
	longitude = wrapf(longitude, -PI, PI)
	return {
		"xz": Vector2(longitude * RADIUS, latitude * RADIUS),
		"longitude_radians": longitude,
		"latitude_radians": latitude,
		"pole_crossings": pole_crossings,
		"yaw_delta": PI if (pole_crossings & 1) != 0 else 0.0,
	}


func canonical_planet_xz(world_xz: Vector2) -> Vector2:
	# Terrain and LOD builders call this for every vertex. Keep the metadata-rich
	# Dictionary version for actual pole crossings, but avoid allocating it for
	# the overwhelmingly common coordinate-only query.
	var longitude := world_xz.x / RADIUS
	var latitude := world_xz.y / RADIUS
	while latitude > PI * 0.5:
		latitude = PI - latitude
		longitude += PI
	while latitude < -PI * 0.5:
		latitude = -PI - latitude
		longitude += PI
	return Vector2(wrapf(longitude, -PI, PI) * RADIUS, latitude * RADIUS)


func planet_angles_radians(world_xz: Vector2) -> Vector2:
	var canonical := canonical_planet_xz(world_xz)
	return canonical / RADIUS


## Returns longitude/latitude in degrees for UI and admin tools.
func longitude_latitude(world_xz: Vector2) -> Vector2:
	var angles := planet_angles_radians(world_xz)
	return Vector2(rad_to_deg(angles.x), rad_to_deg(angles.y))


func xz_from_longitude_latitude(longitude_degrees: float,
		latitude_degrees: float) -> Vector2:
	return canonical_planet_xz(Vector2(deg_to_rad(longitude_degrees) * RADIUS,
		deg_to_rad(latitude_degrees) * RADIUS))


func sphere_direction(world_xz: Vector2) -> Vector3:
	var angles := planet_angles_radians(world_xz)
	var latitude_cosine := cos(angles.y)
	return Vector3(latitude_cosine * cos(angles.x), sin(angles.y),
		latitude_cosine * sin(angles.x))


func sphere_point(world_xz: Vector2) -> Vector3:
	return sphere_direction(world_xz) * RADIUS


## Closest equirectangular image of one canonical point to an unwrapped local
## reference. Direct images repeat every circumference; mirrored images are the
## same physical point seen through a chart reflected across a pole.
func nearest_world_image(world_xz: Vector2, reference_xz: Vector2) -> Vector2:
	return nearest_world_image_sample(world_xz, reference_xz).xz


## As above, with the heading correction required when the closest atlas image
## is mirrored through a pole. Multiplayer replicas use this to remain a few
## metres away across a pole instead of appearing half a planet distant.
func nearest_world_image_sample(world_xz: Vector2,
		reference_xz: Vector2) -> Dictionary:
	var canonical := canonical_planet_xz(world_xz)
	var candidates: Array[Dictionary] = []
	var direct_x_cycle := roundi((reference_xz.x - canonical.x)
		/ CIRCUMFERENCE)
	var direct_z_cycle := roundi((reference_xz.y - canonical.y)
		/ CIRCUMFERENCE)
	for dx in range(direct_x_cycle - 1, direct_x_cycle + 2):
		for dz in range(direct_z_cycle - 1, direct_z_cycle + 2):
			candidates.append({
				"xz": Vector2(canonical.x + float(dx) * CIRCUMFERENCE,
					canonical.y + float(dz) * CIRCUMFERENCE),
				"yaw_delta": 0.0,
			})
	var mirrored_x := canonical.x + HALF_CIRCUMFERENCE
	var mirrored_z := HALF_CIRCUMFERENCE - canonical.y
	var mirror_x_cycle := roundi((reference_xz.x - mirrored_x)
		/ CIRCUMFERENCE)
	var mirror_z_cycle := roundi((reference_xz.y - mirrored_z)
		/ CIRCUMFERENCE)
	for dx in range(mirror_x_cycle - 1, mirror_x_cycle + 2):
		for dz in range(mirror_z_cycle - 1, mirror_z_cycle + 2):
			candidates.append({
				"xz": Vector2(mirrored_x + float(dx) * CIRCUMFERENCE,
					mirrored_z + float(dz) * CIRCUMFERENCE),
				"yaw_delta": PI,
			})
	var closest: Dictionary = candidates[0]
	var closest_xz: Vector2 = closest.xz
	var closest_distance := closest_xz.distance_squared_to(reference_xz)
	for candidate in candidates:
		var candidate_xz: Vector2 = candidate.xz
		var distance := candidate_xz.distance_squared_to(reference_xz)
		if distance < closest_distance:
			closest = candidate
			closest_distance = distance
	return closest


func great_circle_distance(a: Vector2, b: Vector2) -> float:
	var a_direction := sphere_direction(a)
	var b_direction := sphere_direction(b)
	return acos(clampf(a_direction.dot(b_direction), -1.0, 1.0)) * RADIUS


func summit_position() -> Vector2:
	return _summit_xz


func home_lake_center() -> Vector2:
	return _home_lake_center


func _noise_3d(noise: FastNoiseLite, surface_point: Vector3) -> float:
	return noise.get_noise_3d(surface_point.x, surface_point.y, surface_point.z)


func _macro_lattice_node(node_x: int, node_z: int) -> PackedFloat32Array:
	var canonical := canonical_planet_xz(Vector2(float(node_x), float(node_z))
		* MACRO_LATTICE_STEP)
	var key := Vector2i(roundi(canonical.x / MACRO_LATTICE_STEP),
		roundi(canonical.y / MACRO_LATTICE_STEP))
	if _macro_lattice_cache.has(key):
		return _macro_lattice_cache[key]
	var longitude := canonical.x / RADIUS
	var latitude := canonical.y / RADIUS
	var latitude_cosine := cos(latitude)
	var point := Vector3(latitude_cosine * cos(longitude), sin(latitude),
		latitude_cosine * sin(longitude)) * RADIUS
	var fields := PackedFloat32Array()
	fields.resize(MACRO_FIELD_COUNT)
	fields[0] = _noise_3d(_continent, point)
	fields[1] = _noise_3d(_continent_detail, point)
	fields[2] = _noise_3d(_upland, point)
	fields[3] = _noise_3d(_range_mask, point)
	fields[4] = _noise_3d(_ridge, point)
	fields[5] = _noise_3d(_lake, point)
	_macro_lattice_cache[key] = fields
	return fields


func _macro_noise_fields(canonical: Vector2) -> PackedFloat32Array:
	var gx := floori(canonical.x / MACRO_LATTICE_STEP)
	var gz := floori(canonical.y / MACRO_LATTICE_STEP)
	var tx := (canonical.x - float(gx) * MACRO_LATTICE_STEP) \
		/ MACRO_LATTICE_STEP
	var tz := (canonical.y - float(gz) * MACRO_LATTICE_STEP) \
		/ MACRO_LATTICE_STEP
	var n00 := _macro_lattice_node(gx, gz)
	if tx < 0.000001 and tz < 0.000001:
		return n00
	var out := PackedFloat32Array()
	out.resize(MACRO_FIELD_COUNT)
	if tx < 0.000001:
		var n01 := _macro_lattice_node(gx, gz + 1)
		for field_index in range(MACRO_FIELD_COUNT):
			out[field_index] = lerpf(n00[field_index], n01[field_index], tz)
		return out
	var n10 := _macro_lattice_node(gx + 1, gz)
	if tz < 0.000001:
		for field_index in range(MACRO_FIELD_COUNT):
			out[field_index] = lerpf(n00[field_index], n10[field_index], tx)
		return out
	var n01 := _macro_lattice_node(gx, gz + 1)
	var n11 := _macro_lattice_node(gx + 1, gz + 1)
	for field_index in range(MACRO_FIELD_COUNT):
		var lower := lerpf(n00[field_index], n10[field_index], tx)
		var upper := lerpf(n01[field_index], n11[field_index], tx)
		out[field_index] = lerpf(lower, upper, tz)
	return out


## Macro fields are returned together so Gen.height()/biome/minimap callers can
## reuse one coherent definition. The dictionary is deliberately value-only and
## has no streaming or network state.
func sample(world_xz: Vector2) -> Dictionary:
	var canonical := canonical_planet_xz(world_xz)
	var longitude := canonical.x / RADIUS
	var latitude_radians := canonical.y / RADIUS
	var latitude_cosine := cos(latitude_radians)
	var direction := Vector3(latitude_cosine * cos(longitude),
		sin(latitude_radians), latitude_cosine * sin(longitude))
	var point := direction * RADIUS
	var latitude := absf(latitude_radians) / (PI * 0.5)
	# acos() was a major cost in the far-terrain vertex path. Both authored
	# influences are exactly zero outside their finite support, so reject distant
	# points by dot product and evaluate the arc only inside that support.
	var home_dot := direction.x
	var home_distance := HOME_EFFECT_RADIUS + 1.0
	if home_dot > HOME_EFFECT_DOT_MIN:
		home_distance = acos(clampf(home_dot, -1.0, 1.0)) * RADIUS
	var summit_dot := direction.dot(_summit_direction)
	var summit_distance := SUMMIT_EFFECT_RADIUS + 1.0
	if summit_dot > SUMMIT_EFFECT_DOT_MIN:
		summit_distance = acos(clampf(summit_dot, -1.0, 1.0)) * RADIUS
	if canonical.distance_squared_to(_summit_xz) < 0.0001:
		summit_distance = 0.0

	# Seven shared spherical noise evaluations feed all terrain and climate
	# channels. Reusing the broad detail/range values is materially cheaper while
	# keeping their thresholds independent enough to form readable regions.
	var macro_fields := _macro_noise_fields(canonical)
	var continent_value := float(macro_fields[0])
	var continent_detail_value := float(macro_fields[1])
	var continent_raw := continent_value * 0.86 \
		+ continent_detail_value * 0.28
	# Keep a broad, playable home continent and a dry massif beneath the summit.
	continent_raw += (1.0 - smoothstep(1800.0, 6200.0, home_distance)) * 0.72
	continent_raw += (1.0 - smoothstep(1800.0, 4200.0,
		summit_distance)) * 0.68
	# Polar oceans remain possible, but the ice/tundra land caps still get room.
	continent_raw -= smoothstep(0.90, 1.0, latitude) * 0.16
	var land := smoothstep(-0.16, 0.09, continent_raw)
	var ocean := 1.0 - smoothstep(-0.18, 0.02, continent_raw)

	var upland_raw := float(macro_fields[2]) * 0.5 + 0.5
	var upland := smoothstep(0.40, 0.82, upland_raw) * land
	var range_raw := float(macro_fields[3]) * 0.5 + 0.5
	var ridge_raw := 1.0 - absf(float(macro_fields[4]))
	var mountain := smoothstep(0.50, 0.78, range_raw) \
		* smoothstep(0.34, 0.95, ridge_raw) * land
	# Protect the origin's established jungle, runway search and vehicle routes;
	# true continental uplands begin gradually beyond the playable home basin.
	upland *= smoothstep(720.0, 1900.0, home_distance)
	mountain *= smoothstep(1350.0, 2900.0, home_distance)
	# The summit range is broad enough to read as a massif, not a lone spike.
	var summit_range := 1.0 - smoothstep(850.0, 3600.0, summit_distance)
	mountain = maxf(mountain, summit_range * land)

	var lake_raw := float(macro_fields[5]) * 0.80 \
		+ continent_detail_value * 0.20
	var inland := smoothstep(0.63, 0.88, land)
	var lake_strength := smoothstep(0.16, 0.46, lake_raw) * inland
	# 190-260 m home-lake radius, with a broad natural-looking shore blend.
	var home_lake_radius := 220.0 + float((seed & 31)) * 1.35
	var home_lake_distance := canonical.distance_to(_home_lake_center)
	var home_lake := 1.0 - smoothstep(home_lake_radius,
		home_lake_radius + 85.0, home_lake_distance)
	lake_strength = maxf(lake_strength, home_lake)
	# Protect only the authored combat bowl. The home lake's near shore is then
	# reachable within a short walk and restores the diagnostic/swimming contract
	# that expects genuinely deep water inside roughly 150 m of spawn.
	lake_strength *= smoothstep(46.0, 78.0, home_distance)

	var rolling := continent_detail_value
	var fine_detail := _noise_3d(_detail, point)
	var broad_land_height := 18.0 + upland * 470.0 \
		+ rolling * lerpf(16.0, 42.0, upland)
	# Major ranges centre close to 1.2 km while remaining comfortably below the
	# one authored 6 km summit. Local detail is intentionally under two metres.
	var ridge_shape := smoothstep(0.28, 1.0, ridge_raw)
	var mountain_height := mountain * (720.0 + ridge_shape * 1180.0)
	var natural_land_height := broad_land_height + mountain_height \
		+ fine_detail * 1.45
	var ocean_floor := SEA_LEVEL - 65.0 - ocean * 310.0 \
		+ rolling * 18.0
	var elevation := lerpf(natural_land_height, ocean_floor, ocean)
	var lake_floor := SEA_LEVEL - 8.0 - lake_strength * 30.0 \
		+ fine_detail * 0.55
	elevation = lerpf(elevation, lake_floor, lake_strength)

	# Pin the sole summit exactly. The smooth quintic-like shoulder reaches zero
	# well before other generated ranges and cannot overshoot the target.
	var summit_weight := 1.0 - smoothstep(0.0, 1450.0, summit_distance)
	summit_weight *= summit_weight
	elevation = lerpf(elevation, SUMMIT_ELEVATION, summit_weight)
	elevation = minf(elevation, SUMMIT_ELEVATION)

	var latitude_temperature := 1.0 - pow(latitude, 1.35)
	var temperature := clampf(latitude_temperature * 0.82 \
		+ range_raw * 0.28 \
		- maxf(elevation, 0.0) / 7600.0, 0.0, 1.0)
	var moisture := clampf(continent_detail_value * 0.5 + 0.5 \
		+ (1.0 - continent_raw) * 0.12, 0.0, 1.0)
	var home_climate := 1.0 - smoothstep(900.0, 1900.0, home_distance)
	temperature = lerpf(temperature, 0.73, home_climate)
	moisture = lerpf(moisture, 0.76, home_climate)
	return {
		"xz": canonical,
		"elevation": elevation,
		"land": land,
		"ocean": ocean,
		"lake": lake_strength,
		"upland": upland,
		"mountain": mountain,
		"temperature": temperature,
		"moisture": moisture,
		"detail": fine_detail,
		"latitude_fraction": latitude,
		"summit_weight": summit_weight,
	}
