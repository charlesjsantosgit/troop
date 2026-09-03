class_name PlanetTerrain
extends RefCounted
## Deterministic Earth-like macro terrain sampled on a sphere.
##
## Gameplay terrain remains a locally-flat equirectangular chart, but every
## field is evaluated from the matching point on a sphere. Longitude therefore
## joins exactly, and walking through either pole reflects latitude and advances
## longitude by 180 degrees instead of creating a torus or a hard map edge.

# Within 0.006% of Earth's equatorial circumference while remaining exactly
# divisible by every 48/768/3072/6144 m streaming and road lattice.
const CIRCUMFERENCE := 40_077_312.0
const HALF_CIRCUMFERENCE := CIRCUMFERENCE * 0.5
const QUARTER_CIRCUMFERENCE := CIRCUMFERENCE * 0.25
const RADIUS := CIRCUMFERENCE / TAU
const SEA_LEVEL := 0.55
const SUMMIT_ELEVATION := 6000.0
const HOME_EFFECT_RADIUS := 6200.0
const HOME_LOWLAND_RADIUS := 100_000.0
const SUMMIT_EFFECT_RADIUS := 4200.0
# All macro fields turn over across kilometres. Sampling their shared spherical
# noise on this topology-aligned lattice and interpolating between nodes keeps
# the same continuous planet while amortizing six costly noise evaluations
# across thousands of 3-192 m streaming vertices. 768 divides the longitude
# circumference and 180-degree pole shift exactly, so no seam is introduced.
const MACRO_LATTICE_STEP := 768.0
const MACRO_FIELD_COUNT := 6

var seed := 1337
var _summit_xz := Vector2.ZERO
var _home_lake_center := Vector2.ZERO
var _home_valley_axis := Vector2.RIGHT

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
	# Spherical frequencies are scaled for an Earth-sized globe. The Pangaea
	# silhouette below owns the continent; these fields roughen its coast and
	# create climate regions measured in hundreds to thousands of kilometres.
	_configure_noise(_continent, 11, 0.00000024, 3, 0.52)
	_configure_noise(_continent_detail, 23, 0.00000068, 2, 0.48)
	# Continental uplands turn over across many kilometres. This intentionally
	# keeps normal travel on long grades instead of stacking noisy short bumps.
	_configure_noise(_upland, 37, 0.00000018, 2, 0.50)
	_configure_noise(_range_mask, 47, 0.00000155, 2, 0.50)
	_configure_noise(_ridge, 59, 0.0000041, 2, 0.46)
	# Fine relief stays within a few metres and breaks up otherwise broad
	# slopes. One simplex octave preserves that readable surface variation while
	# halving the only spherical noise still evaluated at every terrain vertex.
	_configure_noise(_detail, 83, 0.0048, 1, 0.40)
	_configure_noise(_lake, 97, 0.0000105, 2, 0.48)

	# One seed-derived summit is deliberately isolated from the home continent.
	# The exact centre is pinned to 6,000 m after all natural terrain layers.
	var summit_hash := _hash_unit(seed_value, 401)
	# Keep the sole 6 km summit on the connected supercontinent instead of
	# manufacturing a mountain island in the global ocean.
	var summit_lon := lerpf(-0.78, 0.78, summit_hash.x)
	var summit_lat := deg_to_rad(lerpf(24.0, 46.0, summit_hash.y))
	if ((seed_value >> 3) & 1) != 0:
		summit_lat = -summit_lat
	_summit_xz = Vector2(summit_lon * RADIUS, summit_lat * RADIUS)

	# A broad home lake makes the existing airboat/dock contract reliable while
	# still letting the macro lake field make much larger inland water systems.
	var lake_hash := _hash_unit(seed_value, 733)
	var lake_angle := TAU * lake_hash.x
	var lake_radius := lerpf(330.0, 430.0, lake_hash.y)
	_home_lake_center = Vector2.from_angle(lake_angle) * lake_radius
	_home_valley_axis = Vector2.from_angle(TAU * _hash_unit(seed_value, 1201).x)


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


## Stable short-range geodesic distance in the equirectangular gameplay chart.
## A unit-vector dot loses all useful precision for kilometre-scale offsets on
## an Earth-radius globe because Godot's Vector3 components are float32. The
## local tangent metric retains sub-metre continuity, wraps longitude, and is
## indistinguishable from the full great-circle arc over these <=6.2 km authored
## influence radii.
static func _local_tangent_distance(a: Vector2, b: Vector2) -> float:
	var longitude_delta := wrapf(a.x - b.x, -HALF_CIRCUMFERENCE,
		HALF_CIRCUMFERENCE)
	var mean_latitude := (a.y + b.y) * 0.5 / RADIUS
	var east_west := longitude_delta * cos(mean_latitude)
	return Vector2(east_west, a.y - b.y).length()


static func _pangaea_lobe(longitude: float, latitude: float,
		center: Vector2, radii: Vector2) -> float:
	var longitude_delta := wrapf(longitude - center.x, -PI, PI)
	var normalized := Vector2(longitude_delta / radii.x,
		(latitude - center.y) / radii.y)
	return 1.0 - normalized.length()


static func _pangaea_lobe_sample(longitude: float, latitude: float,
		center: Vector2, radii: Vector2, field_bias := 0.0) -> Vector3:
	var longitude_delta := wrapf(longitude - center.x, -PI, PI)
	var latitude_delta := latitude - center.y
	var normalized_x := longitude_delta / radii.x
	var normalized_y := latitude_delta / radii.y
	var radial := maxf(Vector2(normalized_x, normalized_y).length(), 0.00001)
	return Vector3(1.0 - radial + field_bias,
		-longitude_delta / (radii.x * radii.x * radial),
		-latitude_delta / (radii.y * radii.y * radial))


## One broad connected supercontinent assembled from overlapping continental
## lobes. The max field avoids fragile polygon seams and stays cheap enough for
## every terrain LOD; spherical noise only erodes and feathers the coastline.
static func _pangaea_field(longitude: float, latitude: float) -> float:
	return _pangaea_sample(longitude, latitude).x


static func _pangaea_sample(longitude: float, latitude: float) -> Vector3:
	var best := _pangaea_lobe_sample(longitude, latitude,
		Vector2(0.0, -0.02), Vector2(1.13, 0.72))
	for candidate in [
		_pangaea_lobe_sample(longitude, latitude,
			Vector2(-0.38, 0.56), Vector2(0.78, 0.52)),
		_pangaea_lobe_sample(longitude, latitude,
			Vector2(0.67, 0.20), Vector2(0.66, 0.49)),
		_pangaea_lobe_sample(longitude, latitude,
			Vector2(0.14, -0.61), Vector2(0.64, 0.50)),
		_pangaea_lobe_sample(longitude, latitude,
			Vector2(-0.66, -0.35), Vector2(0.57, 0.40)),
		# Narrow peninsula, biased slightly inward so it remains connected.
		_pangaea_lobe_sample(longitude, latitude,
			Vector2(0.94, -0.24), Vector2(0.43, 0.24), -0.05),
	]:
		if candidate.x > best.x:
			best = candidate
	return best


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


## A long, gently meandering lowland passes through home. Mountains recover
## across tens of kilometres on either side, leaving open valley exits instead
## of raising every direction into the same circular wall 1-3 km from spawn.
## Canonical coordinates keep this identical for every world image and LOD.
func _home_lowland_weight(canonical: Vector2) -> float:
	if canonical.length_squared() > HOME_LOWLAND_RADIUS * HOME_LOWLAND_RADIUS:
		return 0.0
	var along := canonical.dot(_home_valley_axis)
	var across := canonical.dot(Vector2(-_home_valley_axis.y, _home_valley_axis.x))
	var bend := sin(along / 14_000.0) * 1800.0 \
		+ (cos(along / 23_000.0) - 1.0) * 800.0
	var valley := 1.0 - smoothstep(5000.0, 30_000.0, absf(across - bend))
	return valley * (1.0 - smoothstep(50_000.0, 90_000.0, absf(along)))


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
	# Authored effects occupy only a few kilometres, so a local tangent metric is
	# both cheaper and far more precise than acos(direction.dot(target)) here.
	# Clamping outside support keeps the later smoothstep work unchanged.
	var home_distance := minf(canonical.length(), HOME_EFFECT_RADIUS + 1.0)
	var summit_distance := minf(_local_tangent_distance(canonical, _summit_xz),
		SUMMIT_EFFECT_RADIUS + 1.0)

	# Seven shared spherical noise evaluations feed all terrain and climate
	# channels. Reusing the broad detail/range values is materially cheaper while
	# keeping their thresholds independent enough to form readable regions.
	var macro_fields := _macro_noise_fields(canonical)
	var continent_value := float(macro_fields[0])
	var continent_detail_value := float(macro_fields[1])
	var pangaea_sample := _pangaea_sample(longitude, latitude_radians)
	var pangaea := pangaea_sample.x
	var continent_raw := pangaea + continent_value * 0.018 \
		+ continent_detail_value * 0.012
	# Convert the implicit supercontinent contour into a local signed distance.
	# Gen uses the tangent to lay one truly coastline-following arterial without
	# storing a planet-sized spline or reverting to a straight grid.
	var metric_gradient := Vector2(
		pangaea_sample.y / (RADIUS * maxf(latitude_cosine, 0.08)),
		pangaea_sample.z / RADIUS)
	var metric_gradient_length := maxf(metric_gradient.length(), 0.000000001)
	var coast_distance := continent_raw / metric_gradient_length
	var coast_inward_normal := metric_gradient / metric_gradient_length
	var coast_tangent := Vector2(-coast_inward_normal.y,
		coast_inward_normal.x)
	# Keep a broad, playable home continent and a dry massif beneath the summit.
	continent_raw += (1.0 - smoothstep(1800.0, 6200.0, home_distance)) * 0.72
	continent_raw += (1.0 - smoothstep(1800.0, 4200.0,
		summit_distance)) * 0.68
	var land := smoothstep(-0.08, 0.055, continent_raw)
	var ocean := 1.0 - smoothstep(-0.10, 0.025, continent_raw)
	# Both geographic poles are permanent ice caps, including across ocean. A
	# real terrain shelf sits just above sea level so the visible surface cannot
	# turn back into liquid or bare water at any longitude.
	var polar_ice := smoothstep(0.82, 0.94, latitude)
	land = maxf(land, polar_ice)
	ocean *= 1.0 - polar_ice

	var upland_raw := float(macro_fields[2]) * 0.5 + 0.5
	var upland := smoothstep(0.40, 0.82, upland_raw) * land
	var range_raw := float(macro_fields[3]) * 0.5 + 0.5
	var ridge_raw := 1.0 - absf(float(macro_fields[4]))
	var mountain := smoothstep(0.50, 0.78, range_raw) \
		* smoothstep(0.34, 0.95, ridge_raw) * land
	# The home region is a broad valley with gradual foothills. Recovering the
	# full continental elevation over a short radius made an impassable ring.
	var home_lowland := _home_lowland_weight(canonical)
	upland *= 1.0 - home_lowland
	mountain *= 1.0 - home_lowland
	# The summit range is broad enough to read as a massif, not a lone spike.
	var summit_range := 1.0 - smoothstep(850.0, 3600.0, summit_distance)
	mountain = maxf(mountain, summit_range * land)

	var lake_raw := float(macro_fields[5]) * 0.80 \
		+ continent_detail_value * 0.20
	var inland := smoothstep(0.63, 0.88, land)
	var procedural_lake := smoothstep(0.16, 0.46, lake_raw) * inland
	# The authored home lake owns the spawn region. Suppress a coincident macro
	# basin there so fixing the short-range distance precision cannot flood the
	# entire airfield/motor-pool neighbourhood or erase its road destinations.
	procedural_lake *= smoothstep(900.0, 1800.0, home_distance)
	# 190-260 m home-lake radius, with a broad natural-looking shore blend.
	var home_lake_radius := 220.0 + float((seed & 31)) * 1.35
	var home_lake_distance := canonical.distance_to(_home_lake_center)
	var home_lake := 1.0 - smoothstep(home_lake_radius,
		home_lake_radius + 85.0, home_lake_distance)
	var lake_strength := maxf(procedural_lake, home_lake)
	# Protect only the authored combat bowl. The home lake's near shore is then
	# reachable within a short walk and restores the diagnostic/swimming contract
	# that expects genuinely deep water inside roughly 150 m of spawn.
	lake_strength *= smoothstep(46.0, 78.0, home_distance)

	var rolling := continent_detail_value
	var fine_detail := _noise_3d(_detail, point)
	var broad_land_height := lerpf(18.0, 6.0, home_lowland) + upland * 470.0 \
		+ rolling * lerpf(21.0, 49.0, upland) * (1.0 - home_lowland * 0.80)
	# Major ranges centre close to 1.2 km while remaining comfortably below the
	# one authored 6 km summit. Local detail never scales with their altitude.
	var ridge_shape := smoothstep(0.28, 1.0, ridge_raw)
	# Surface detail adds only a few metres, independent of mountain altitude.
	# Multiplying kilometre-high ranges by fine noise made hundreds of metres of
	# jagged cliffs between neighbouring collision vertices, even on foothills.
	# Extra rock relief starts beyond the foothills so road shoulders stay gentle.
	var crag_strength := smoothstep(0.34, 0.64, mountain)
	var mountain_height := mountain * (700.0 + ridge_shape * 1140.0)
	var surface_detail := fine_detail \
		* (lerpf(1.45, 0.45, home_lowland) + crag_strength * 2.0)
	var natural_land_height := broad_land_height + mountain_height \
		+ surface_detail
	var ocean_floor := SEA_LEVEL - 65.0 - ocean * 310.0 \
		+ rolling * 18.0
	var elevation := lerpf(natural_land_height, ocean_floor, ocean)
	var lake_floor := SEA_LEVEL - 8.0 - lake_strength * 30.0 \
		+ fine_detail * 0.55
	elevation = lerpf(elevation, lake_floor, lake_strength)
	var ice_surface := SEA_LEVEL + 2.6 + rolling * 0.55
	elevation = lerpf(elevation, ice_surface, polar_ice)
	lake_strength *= 1.0 - polar_ice

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
		"polar_ice": polar_ice,
		"coast_distance": coast_distance,
		"coast_tangent": coast_tangent,
		"summit_weight": summit_weight,
	}
