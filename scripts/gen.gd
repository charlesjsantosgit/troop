extends Node
## Gen (autoload) — deterministic infinite-jungle generation.
## Pure layout math lives here so movetest can verify determinism and both
## network peers can rebuild the identical world from just a seed.

signal vine_visual_changed(chunk_key: Vector2i)

const PlanetTerrainScript = preload("res://scripts/planet_terrain.gd")
const PlanetRoadNetworkScript = preload("res://scripts/planet_road_network.gd")

const CHUNK := 48.0
const CELLS := 16                # terrain quads per chunk side
const WATER_Y := 0.55
const VIEW_R := 2                # 5x5 visible grid; fog hides the streamed edge
const DROP_R := 2                # base visible radius; World may add a speed guard
const HORIZON_SECTOR_CHUNKS := 4 # 192 m coarse sectors, rendered without physics
const HORIZON_VIEW_R := 3        # 7x7 sectors: about a 672 m visible radius
const HORIZON_DROP_R := 3
const HORIZON_NEAR_FADE := 108.0
const HORIZON_DISTANCE := CHUNK * HORIZON_SECTOR_CHUNKS \
	* (HORIZON_VIEW_R + 0.5)
const SKYLINE_SECTOR_CHUNKS := 16 # 768 m ultra-far sectors for mountain vistas
const SKYLINE_VIEW_R := 2        # 5x5 sectors: about a 1.9 km visible radius
const SKYLINE_DROP_R := 2
const SKYLINE_NEAR_FADE := 600.0 # dithered handoff inside the horizon ring
const SKYLINE_DISTANCE := CHUNK * SKYLINE_SECTOR_CHUNKS \
	* (SKYLINE_VIEW_R + 0.5)
const STRATOS_SECTOR_CHUNKS := 128  # 6144 m ultra tier for altitude vistas
const STRATOS_CELLS := 32           # 192 m cells: 33x33 lattice per sector
const STRATOS_NEAR_FADE := 1700.0   # dithered handoff inside the skyline ring
const STRATOS_CANOPY_RELIEF_MIN := 2.4
const STRATOS_CANOPY_RELIEF_MAX := 7.2
const VIEW_BASE_DISTANCE := 2200.0  # ground-level far plane (m)
const VIEW_PEAK_DISTANCE := 24140.0 # 15 miles from the tallest peaks
const VIEW_ALTITUDE_CURVE := 0.58   # gradual summit-normalized horizon growth
const PLANET_CIRCUMFERENCE := PlanetTerrainScript.CIRCUMFERENCE
const PLANET_RADIUS := PlanetTerrainScript.RADIUS
const PLANET_HALF_CIRCUMFERENCE := PlanetTerrainScript.HALF_CIRCUMFERENCE
const PLANET_POLE_DISTANCE := PlanetTerrainScript.QUARTER_CIRCUMFERENCE
const PLANET_SUMMIT_ELEVATION := PlanetTerrainScript.SUMMIT_ELEVATION
const PLANET_CHUNKS_AROUND := int(PLANET_CIRCUMFERENCE / CHUNK)
const MOUNTAIN_HEIGHT := 1900.0 # natural major ranges; one summit reaches 6 km
const TREE_LINE := 2400.0       # Earth-like alpine timberline
const SNOW_LINE_START := 3000.0 # exposed rock begins retaining permanent snow
const SNOW_LINE_FULL := 4300.0  # full snowpack on the highest slopes
const REACH := 2.2               # blind arm's-reach fallback grab distance
const TARGET_DIST := 3.0         # realistic grab reach from the hand (1-3m)
const TARGET_COS := 0.82         # ~35° aim cone around the crosshair

# Supply loot uses the same integer contract as Net.WEAPON_* without making the
# pure generation autoload depend on the multiplayer autoload. Keeping these
# values beside the deterministic layout also makes future loot generation safe
# to run in headless tests before a session has been created.
const SUPPLY_AMMO_REVOLVER := 0
const SUPPLY_AMMO_SHOTGUN := 1
const SUPPLY_AMMO_SMG := 2
const SUPPLY_AMMO_SNIPER := 3
const SUPPLY_HUT_CLEARANCE := 5.4

# The origin meadow is an authored duel bowl inside the otherwise procedural
# world. Its gameplay data is kept here, beside height and chunk layout math, so
# players, bots, tests and streamed visuals all consume the exact same geometry.
const ARENA_ID := "origin_duel_arena_v2"
const ARENA_RADIUS := 31.5
const ARENA_SOFT_BOUNDARY_RADIUS := 28.0

enum Biome {
	RAINFOREST,
	BAMBOO_GROVE,
	WETLAND,
	HIGHLAND,
	PLAINS,
	GRASSLAND,
	ROCKY_MOUNTAINS,
	DESERT,
	TUNDRA,
	ICE,
	OCEAN,
	LAKE,
}

const BIOME_NAMES := {
	Biome.RAINFOREST: "Emerald Rainforest",
	Biome.BAMBOO_GROVE: "Bamboo Grove",
	Biome.WETLAND: "Flooded Wetland",
	Biome.HIGHLAND: "Cloud Highland",
	Biome.PLAINS: "Temperate Plains",
	Biome.GRASSLAND: "Open Grassland",
	Biome.ROCKY_MOUNTAINS: "Rocky Mountains",
	Biome.DESERT: "Desert",
	Biome.TUNDRA: "Arctic Tundra",
	Biome.ICE: "Polar Ice",
	Biome.OCEAN: "Open Ocean",
	Biome.LAKE: "Freshwater Lake",
}

const AIRSTRIP_ORIGINAL_LENGTH := 420.0
const AIRSTRIP_SCALE := 3.0
const AIRSTRIP_LENGTH := AIRSTRIP_ORIGINAL_LENGTH * AIRSTRIP_SCALE
const AIRSTRIP_WIDTH := 26.0
const AIRSTRIP_APRON_RADIUS := 30.0
const AIRSTRIP_BLEND := 30.0
const AIRSTRIP_HANGAR_COUNT := 6
const AIRSTRIP_HANGAR_WIDTH := 18.0
const AIRSTRIP_HANGAR_DEPTH := 22.0
const AIRSTRIP_HANGAR_HEIGHT := 7.4
const AIRSTRIP_HANGAR_SPACING := 25.0
const AIRSTRIP_HANGAR_CLEARANCE := 15.5
const AIRSTRIP_HANGAR_TAXI_GAP := 8.0
const AIRSTRIP_HANGAR_PAD_MARGIN := 6.0
const ROCKET_PAD_RADIUS := 14.0
const ROCKET_PAD_BLEND := 10.0

# Seeded packed-dirt roads are part of the analytic height/color field rather
# than separate meshes. That keeps collision, every visual LOD, the minimap,
# and all network peers on exactly the same surface without replication.
const ROAD_HALF_WIDTH := PlanetRoadNetworkScript.REGIONAL_HALF_WIDTH
const ROAD_BLEND := PlanetRoadNetworkScript.SHOULDER
const ROAD_POINT_SPACING := 18.0
const ROAD_MAX_GRADE := 0.085
const ROAD_AUDIT_SPACING := 48.0
const COAST_ROAD_INLAND_OFFSET := 180.0
const COAST_ROAD_HALF_WIDTH := 6.8
const FREEWAY_TUNNEL_LENGTH := 58.0
const FREEWAY_TUNNEL_WIDTH := 13.6
const FREEWAY_TUNNEL_HEIGHT := 7.2
const FREEWAY_TUNNEL_APPROACH := 180.0
const ROAD_BRIDGE_MIN_LENGTH := 72.0
const ROAD_BRIDGE_MAX_LENGTH := 180.0
const ROAD_BRIDGE_WIDTH := 14.4
const ROAD_BRIDGE_APPROACH := 36.0
const TRANSPORT_FEATURE_QUERY_MARGIN := 640.0
const BASE_RELIEF_AMPLITUDE := 10.5
const ROLLING_HILL_AMPLITUDE := 8.0

var world_seed: int = 1337
# Deterministic bush airstrip: a per-seed search picks the flattest,
# driest, least mountainous strip corridor near the origin, then the height
# field grades a 1,260 m runway, parking apron, and six-bay hangar row into
# the jungle. Every
# client computes the identical placement from the seed alone.
var airstrip_valid := false
var airstrip_center := Vector2.ZERO
var airstrip_heading := 0.0
var airstrip_elevation := 4.0
var _strip_dir := Vector2.RIGHT
var _strip_perp := Vector2.DOWN
var _strip_bounds := Rect2()
# Deterministic lakeside boat dock nearest the origin.
var boat_dock_valid := false
var boat_dock_pos := Vector3.ZERO
var boat_dock_yaw := 0.0
# Debug playground: a flat plane with no procedural content, used by the
# `debugworld` mode. Layout math short-circuits so streaming stays cheap and
# the authored parkour/range props own the space.
var debug_world := false
var _n_base := FastNoiseLite.new()
var _n_detail := FastNoiseLite.new()
var _n_color := FastNoiseLite.new()
var _n_lake := FastNoiseLite.new()
var _n_lake_warp := FastNoiseLite.new()
var _n_biome := FastNoiseLite.new()
var _n_moisture := FastNoiseLite.new()
var _n_hill := FastNoiseLite.new()
var _n_mountain := FastNoiseLite.new()
var _n_mountain_mask := FastNoiseLite.new()
var _planet := PlanetTerrainScript.new()
var _planet_roads := PlanetRoadNetworkScript.new()
var _last_planet_sample_xz := Vector2(INF, INF)
var _last_planet_sample: Dictionary = {}
const PLANET_LATTICE_CACHE_LIMIT := 32768
var _planet_lattice_cache: Dictionary = {}
var _planet_lattice_cache_order := PackedVector2Array()
var _planet_lattice_cache_cursor := 0
var _road_context_cache: Dictionary = {}
var _road_audit_cache: Dictionary = {}
var _transport_feature_cache: Dictionary = {}
var _transport_chunk_cache: Dictionary = {}
var _last_road_sample_xz := Vector2(INF, INF)
var _last_road_sample: Dictionary = {}
var _stratos_no_road_sample := {"grade": 0.0, "distance": INF,
	"elevation": 0.0, "route_id": ""}
var _road_routes: Array = []
var _roads_ready := false

# vine registry: id -> {anchor, len, chunk, hidden, simulated, points}
# `hidden` means a monkey currently owns the visual. `simulated` means a
# released VinePhysics owns it while the strand is still moving.
var vines: Dictionary = {}
var _vines_by_chunk: Dictionary = {}
var _debug_count := 0


func setup(seed_v: int) -> void:
	world_seed = seed_v
	vines.clear()
	_vines_by_chunk.clear()
	_debug_count = 0
	_roads_ready = false
	_road_routes.clear()
	_planet.setup(seed_v)
	_planet_roads.setup(seed_v)
	_last_planet_sample_xz = Vector2(INF, INF)
	_last_planet_sample.clear()
	_planet_lattice_cache.clear()
	_planet_lattice_cache_order.clear()
	_planet_lattice_cache_cursor = 0
	_road_context_cache.clear()
	_road_audit_cache.clear()
	_transport_feature_cache.clear()
	_transport_chunk_cache.clear()
	_last_road_sample_xz = Vector2(INF, INF)
	_last_road_sample.clear()
	_n_base.seed = seed_v
	_n_base.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_base.frequency = 0.007
	_n_detail.seed = seed_v + 101
	_n_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_detail.frequency = 0.05
	_n_color.seed = seed_v + 202
	_n_color.frequency = 0.11
	# Macro-scale climate fields change over hundreds of metres. Keeping them
	# much lower-frequency than the terrain makes coherent biomes and broad lake
	# basins instead of a different look in every 48 m tile.
	_n_lake.seed = seed_v + 303
	_n_lake.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_lake.frequency = 0.00165
	_n_lake_warp.seed = seed_v + 404
	_n_lake_warp.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_lake_warp.frequency = 0.0042
	_n_biome.seed = seed_v + 505
	_n_biome.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_biome.frequency = 0.0019
	_n_moisture.seed = seed_v + 606
	_n_moisture.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_moisture.frequency = 0.0026
	# Relief fields. Hills roll on a ~350 m wavelength everywhere; mountains are
	# ridged crests gated by an even broader mask so they form distinct ranges
	# with jungle valleys between them instead of uniform roughness.
	_n_hill.seed = seed_v + 707
	_n_hill.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_hill.frequency = 0.0028
	_n_mountain.seed = seed_v + 808
	_n_mountain.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_mountain.frequency = 0.00085
	_n_mountain_mask.seed = seed_v + 909
	_n_mountain_mask.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_mountain_mask.frequency = 0.00042
	_locate_airstrip()
	_locate_boat_dock()
	_build_road_network()


## Public planetary topology contract. World streaming can keep a locally-flat
## tangent chart, then canonicalise only when an actor crosses the longitude
## seam or a pole. A pole reflection returns PI yaw so forward travel remains
## geographically straight.
func canonical_world_sample(world_xz: Vector2) -> Dictionary:
	return _planet.canonical_world_sample(world_xz)


func canonical_planet_xz(world_xz: Vector2) -> Vector2:
	return _planet.canonical_planet_xz(world_xz)


func canonical_world_xz(world_xz: Vector2) -> Vector2:
	return canonical_planet_xz(world_xz)


func nearest_world_image(world_xz: Vector2, reference_xz: Vector2) -> Vector2:
	return _planet.nearest_world_image(world_xz, reference_xz)


func nearest_world_image_sample(world_xz: Vector2,
		reference_xz: Vector2) -> Dictionary:
	return _planet.nearest_world_image_sample(world_xz, reference_xz)


func planet_longitude_latitude(world_xz: Vector2) -> Vector2:
	return _planet.longitude_latitude(world_xz)


func world_xz_to_lon_lat(world_xz: Vector2) -> Vector2:
	return planet_longitude_latitude(world_xz)


func planet_xz_from_longitude_latitude(longitude_degrees: float,
		latitude_degrees: float) -> Vector2:
	return _planet.xz_from_longitude_latitude(longitude_degrees,
		latitude_degrees)


func planet_sphere_direction(world_xz: Vector2) -> Vector3:
	return _planet.sphere_direction(world_xz)


func planet_surface_distance(a: Vector2, b: Vector2) -> float:
	return _planet.great_circle_distance(a, b)


func planet_summit_position() -> Vector2:
	return _planet.summit_position()


func planet_home_lake_center() -> Vector2:
	return _planet.home_lake_center()


func canonical_chunk_key(cx: int, cz: int) -> Vector2i:
	var center := Vector2((float(cx) + 0.5) * CHUNK,
		(float(cz) + 0.5) * CHUNK)
	var canonical := canonical_planet_xz(center)
	return Vector2i(floori(canonical.x / CHUNK),
		floori(canonical.y / CHUNK))


## Score candidate runway corridors around the origin and keep the driest,
## flattest, least mountainous one. Pure noise-field math: every peer lands on
## the same strip for a given seed. airstrip_valid stays false during the
## search so the sampled heights are the raw, ungraded terrain.
func _locate_airstrip() -> void:
	airstrip_valid = false
	if debug_world:
		return
	var best_score := INF
	var best_center := Vector2.ZERO
	var best_heading := 0.0
	var best_height := 4.0
	for angle_index in range(20):
		var angle := TAU * float(angle_index) / 20.0
		for radius_option in [205.0, 245.0, 290.0]:
			var radius := float(radius_option)
			# Search along a tangent to the spawn ring, then push the new centre by
			# half the added length. The original 420 m strip stays accessible near
			# the origin while the longer runway can never cut through the duel arena.
			var original_center := Vector2(cos(angle), sin(angle)) * radius
			var direction := Vector2(-sin(angle), cos(angle))
			var heading := atan2(direction.x, direction.y)
			var center := original_center + direction \
				* ((AIRSTRIP_LENGTH - AIRSTRIP_ORIGINAL_LENGTH) * 0.5)
			var perpendicular := Vector2(direction.y, -direction.x)
			var score := 0.0
			var height_sum := 0.0
			# Sample the full 1,260 m length, including both runway shoulders.
			# Twenty-nine longitudinal stations keep setup bounded while leaving
			# less than one chunk between samples.
			for s in range(-14, 15):
				var along := AIRSTRIP_LENGTH * 0.5 * float(s) / 14.0
				var center_height := 0.0
				for across in [-0.42, 0.0, 0.42]:
					var p := center + direction * along + perpendicular \
						* (AIRSTRIP_WIDTH * float(across))
					var mountain := mountain_influence(p.x, p.y)
					var lake := lake_influence(p.x, p.y)
					var h := height(p.x, p.y)
					score += mountain * 34.0 + lake * 26.0 \
						+ absf(h - 4.2) * 0.30
					if across == 0.0:
						center_height = h
				height_sum += clampf(center_height, WATER_Y + 2.2, 12.0)
			if score < best_score:
				best_score = score
				best_center = center
				best_heading = heading
				best_height = height_sum / 29.0
	airstrip_center = best_center
	airstrip_heading = best_heading
	airstrip_elevation = clampf(best_height, WATER_Y + 2.2, 12.0)
	_strip_dir = Vector2(sin(best_heading), cos(best_heading))
	_strip_perp = Vector2(_strip_dir.y, -_strip_dir.x)
	var reach := AIRSTRIP_LENGTH * 0.5 + AIRSTRIP_APRON_RADIUS \
		+ AIRSTRIP_WIDTH + AIRSTRIP_BLEND + 24.0
	_strip_bounds = Rect2(airstrip_center - Vector2(reach, reach),
		Vector2(reach * 2.0, reach * 2.0))
	airstrip_valid = true


## March outward in rings until a lake wide enough for the airboat appears,
## then park the boat just off the shore, bow pointing across the water.
func _locate_boat_dock() -> void:
	boat_dock_valid = false
	if debug_world:
		return
	for radius in range(4, 24):
		var r := float(radius) * 22.0
		for angle_index in range(28):
			var angle := TAU * float(angle_index) / 28.0
			var p := Vector2(cos(angle), sin(angle)) * r
			if lake_influence(p.x, p.y) < 0.72:
				continue
			if height(p.x, p.y) > WATER_Y - 0.8:
				continue
			# Walk back toward the origin to find the shoreline.
			var toward := -p.normalized()
			var shore := p
			for step in range(40):
				var candidate := shore + toward * 4.0
				if height(candidate.x, candidate.y) > WATER_Y + 0.1:
					break
				shore = candidate
			var float_spot := shore - toward * 7.0
			if height(float_spot.x, float_spot.y) > WATER_Y - 0.5:
				continue
			boat_dock_pos = Vector3(float_spot.x, WATER_Y, float_spot.y)
			boat_dock_yaw = atan2(-toward.x, -toward.y)
			boat_dock_valid = true
			return


## Build a small useful road network after the seed-derived airfield and dock
## have been located. Routes begin at the east arena approach/motor pool, arc
## outside the protected duel bowl, then choose a gently bending outer line
## that avoids lake basins and steep ridges where possible. Only these cached
## points/elevations are consulted by height(), so chunk streaming order and
## multiplayer authority never enter the result.
func _build_road_network() -> void:
	_roads_ready = false
	_road_routes.clear()
	if debug_world:
		return
	var hub := Vector2(43.0, 4.0)
	_append_road_route("arena_motorpool", PackedVector2Array([
		Vector2(34.0, 9.0), Vector2(38.0, 7.0), hub,
	]))
	var hub_elevation := 3.25
	if not _road_routes.is_empty():
		var hub_profile: PackedFloat32Array = _road_routes[0].elevations
		hub_elevation = hub_profile[hub_profile.size() - 1]
	if airstrip_valid:
		_append_road_route("motorpool_airfield",
			_outer_road_points(airstrip_apron_world(), 2101), hub_elevation)
	if boat_dock_valid:
		var dock := Vector2(boat_dock_pos.x, boat_dock_pos.z)
		var toward_land := -dock.normalized()
		var shore_entry := dock + toward_land * 10.0
		# The boat rests several metres offshore. March toward the origin until
		# the road endpoint is on reliably dry ground, leaving a short walk/down-
		# ramp to the water rather than grading a road across the whole lake.
		for step in range(1, 13):
			var candidate := dock + toward_land * float(step * 4)
			shore_entry = candidate
			if height(candidate.x, candidate.y) > WATER_Y + 0.85:
				break
		# Stop the packed shoulder well inland: grading beneath the parked boat
		# would turn its buoyancy probes into land supports. Also retain the duel
		# bowl's protected perimeter if this seed puts its nearest lake close by.
		shore_entry += toward_land * (ROAD_HALF_WIDTH + ROAD_BLEND + 2.0)
		var radial := dock.normalized()
		var dock_delta := wrapf(dock.angle() - hub.angle(), -PI, PI)
		var tangent := Vector2(-radial.y, radial.x) \
			* (-signf(dock_delta) if absf(dock_delta) > 0.001 else 1.0)
		shore_entry += tangent * (ROAD_HALF_WIDTH + ROAD_BLEND + 10.0)
		for dry_step in range(5):
			if height(shore_entry.x, shore_entry.y) > WATER_Y + 0.85:
				break
			shore_entry += toward_land * 4.0
		var minimum_radius := ARENA_RADIUS + 3.0
		if shore_entry.length() < minimum_radius:
			shore_entry = shore_entry.normalized() * minimum_radius
		if shore_entry.distance_to(hub) > 34.0:
			_append_road_route("motorpool_lake",
				_outer_road_points(shore_entry, 2203), hub_elevation)
	_roads_ready = not _road_routes.is_empty()


## Route around the duel arena on a broad 56 m ring, then bend toward the
## destination. Five deterministic bend candidates are scored against the raw
## seed fields; this normally steers the road around water and severe relief
## without any pathfinding or replicated state.
func _outer_road_points(target: Vector2, salt: int) -> PackedVector2Array:
	var hub := Vector2(43.0, 4.0)
	var ring_radius := 56.0
	var start_angle := hub.angle()
	var target_angle := target.angle()
	var angle_delta := wrapf(target_angle - start_angle, -PI, PI)
	# Resolve the exactly-opposite tie from a seed-specific bit so both sides of
	# the arena remain possible across worlds while a given world stays exact.
	if absf(absf(angle_delta) - PI) < 0.0001:
		angle_delta = PI if ((world_seed + salt) & 1) == 0 else -PI
	var arc_steps := maxi(1, ceili(absf(angle_delta) / 0.34))
	var points := PackedVector2Array([hub])
	for step in range(arc_steps + 1):
		var t := float(step) / float(arc_steps)
		points.append(Vector2.from_angle(start_angle + angle_delta * t)
			* ring_radius)
	var outer_start: Vector2 = points[points.size() - 1]
	var direct := target - outer_start
	if direct.length() < 1.0:
		points.append(target)
		return points
	var perpendicular := Vector2(-direct.y, direct.x).normalized()
	var preferred_sign := 1.0 if ((world_seed * 31 + salt) & 1) == 0 else -1.0
	var bend_candidates := PackedFloat32Array([
		0.0, 18.0 * preferred_sign, -18.0 * preferred_sign,
		36.0 * preferred_sign, -36.0 * preferred_sign,
	])
	var best_bend := 0.0
	var best_score := INF
	for bend in bend_candidates:
		var score := 0.0
		var previous := outer_start
		var previous_height := height(previous.x, previous.y)
		for sample_index in range(1, 21):
			var t := float(sample_index) / 20.0
			var candidate := outer_start.lerp(target, t) + perpendicular \
				* float(bend) * sin(t * PI)
			var candidate_height := height(candidate.x, candidate.y)
			var sample_distance := maxf(candidate.distance_to(previous), 0.1)
			var sample_grade := absf(candidate_height - previous_height) \
				/ sample_distance
			score += lake_influence(candidate.x, candidate.y) * 80.0 \
				+ mountain_influence(candidate.x, candidate.y) * 14.0 \
				+ maxf(sample_grade - ROAD_MAX_GRADE, 0.0) * 240.0
			previous = candidate
			previous_height = candidate_height
		if score < best_score:
			best_score = score
			best_bend = float(bend)
	var outer_steps := maxi(2, ceili(direct.length() / ROAD_POINT_SPACING))
	for step in range(1, outer_steps + 1):
		var t := float(step) / float(outer_steps)
		points.append(outer_start.lerp(target, t) + perpendicular \
			* best_bend * sin(t * PI))
	return points


## Cache a smoothed, maximum-grade longitudinal profile and a broadphase box.
## The road is later blended laterally into the natural terrain, producing a
## driveable crown without extra collision bodies or streaming seams.
func _append_road_route(route_id: String, points: PackedVector2Array,
		start_elevation_override := -INF) -> void:
	if points.size() < 2:
		return
	var raw := PackedFloat32Array()
	for point in points:
		raw.append(maxf(height(point.x, point.y), WATER_Y + 0.92))
	if is_finite(start_elevation_override):
		raw[0] = float(start_elevation_override)
	# Two inexpensive low-pass passes remove short noise spikes before the hard
	# longitudinal grade limiter. The shared hub sample stays pinned so branches
	# meet without a terrain step.
	for _smoothing_pass in range(2):
		var source := raw.duplicate()
		for i in range(1, raw.size() - 1):
			raw[i] = float(source[i - 1]) * 0.25 + float(source[i]) * 0.5 \
				+ float(source[i + 1]) * 0.25
	for i in range(1, raw.size()):
		var run := maxf(points[i].distance_to(points[i - 1]), 0.1)
		var maximum_delta := run * ROAD_MAX_GRADE
		raw[i] = clampf(raw[i], raw[i - 1] - maximum_delta,
			raw[i - 1] + maximum_delta)
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	var margin := ROAD_HALF_WIDTH + ROAD_BLEND + SUPPLY_HUT_CLEARANCE + 2.0
	_road_routes.append({
		"id": route_id,
		"points": points,
		"elevations": raw,
		"bounds": Rect2(minimum - Vector2.ONE * margin,
			maximum - minimum + Vector2.ONE * margin * 2.0),
	})


## Public deep copy for tests, navigation hints, and future map legends. No
## caller can mutate the authoritative cached routes used by generation.
func road_routes() -> Array:
	return _road_routes.duplicate(true)


## Closest analytic road sample. `grade` is 1 across the packed core and fades
## through a six-metre shoulder; `distance` lets the color field draw two
## darker wheel ruts while elevation remains evenly crowned.
func road_surface_sample(x: float, z: float) -> Dictionary:
	var canonical := canonical_planet_xz(Vector2(x, z))
	return _road_surface_sample(canonical.x, canonical.y)


func _road_surface_sample(x: float, z: float,
		planet_sample: Dictionary = {}) -> Dictionary:
	if not _roads_ready:
		return {"grade": 0.0, "distance": INF, "elevation": 0.0,
			"route_id": ""}
	var point := Vector2(x, z)
	# height, ground tint and canopy gates consume the exact same road result for
	# every streamed vertex. A one-entry cache removes two duplicate analytic
	# lattice/dictionary queries without retaining any world-sized state.
	if point == _last_road_sample_xz and not _last_road_sample.is_empty():
		return _last_road_sample
	var best_distance := INF
	var best_elevation := 0.0
	var best_route := ""
	var best_half_width := ROAD_HALF_WIDTH
	for route_value in _road_routes:
		var route: Dictionary = route_value
		var bounds: Rect2 = route.bounds
		if not bounds.has_point(point):
			continue
		var points: PackedVector2Array = route.points
		var elevations: PackedFloat32Array = route.elevations
		for i in range(points.size() - 1):
			var segment := points[i + 1] - points[i]
			var length_squared := segment.length_squared()
			if length_squared < 0.0001:
				continue
			var t := clampf((point - points[i]).dot(segment) / length_squared,
				0.0, 1.0)
			var nearest := points[i] + segment * t
			var distance := point.distance_to(nearest)
			if distance < best_distance:
				best_distance = distance
				best_elevation = lerpf(elevations[i], elevations[i + 1], t)
				best_route = str(route.id)
	# One continuous Pangaea coast arterial follows the analytic shoreline's
	# signed-distance contour. It is genuinely curved with the continent rather
	# than another latitude/longitude row, and remains allocation-free in the
	# terrain hot path because the macro sample already carries its tangent.
	var macro_for_roads: Dictionary = planet_sample
	if macro_for_roads.is_empty():
		macro_for_roads = planet_terrain_sample(point.x, point.y)
	var coast_distance := absf(float(macro_for_roads.get("coast_distance", INF))
		- COAST_ROAD_INLAND_OFFSET)
	var coast_edge_distance := coast_distance - COAST_ROAD_HALF_WIDTH
	var best_edge_before_coast := best_distance - best_half_width
	if coast_edge_distance < best_edge_before_coast \
			and coast_distance <= COAST_ROAD_HALF_WIDTH + ROAD_BLEND \
			and float(macro_for_roads.land) > 0.58 \
			and float(macro_for_roads.ocean) < 0.38 \
			and float(macro_for_roads.get("polar_ice", 0.0)) < 0.30:
		var coast_grade := 1.0 - smoothstep(COAST_ROAD_HALF_WIDTH,
			COAST_ROAD_HALF_WIDTH + ROAD_BLEND, coast_distance)
		return _remember_road_sample(point, {
			"grade": coast_grade,
			"distance": coast_distance,
			"elevation": maxf(float(macro_for_roads.elevation), WATER_Y + 0.92),
			"route_id": "coastal:pangaea",
			"tier": "coastal",
			"axis": "coast",
			"tangent": macro_for_roads.get("coast_tangent", Vector2.RIGHT),
			"eligibility": 1.0,
		})
	# Regional and highway lines cover the entire dry, non-alpine landmass. The
	# geometric query is constant-time; a continuous eligibility fade prevents a
	# hard road end where a route meets a coast, lake or severe mountain face.
	var global := _planet_roads.surface_sample(point)
	var global_distance := float(global.distance)
	var global_half_width := float(global.half_width)
	var global_edge_distance := global_distance - global_half_width
	var best_edge_distance := best_distance - best_half_width
	var global_candidate := global_edge_distance < best_edge_distance
	if global_candidate and global_distance <= global_half_width + ROAD_BLEND:
		var context := _global_road_context(point, macro_for_roads, global)
		var eligibility := float(context.eligibility)
		if eligibility > 0.015:
			best_distance = global_distance
			best_half_width = global_half_width
			best_elevation = float(context.elevation)
			best_route = str(global.route_id)
			var lateral := 1.0 - smoothstep(best_half_width,
				best_half_width + ROAD_BLEND, best_distance)
			return _remember_road_sample(point, {
				"grade": lateral * eligibility,
				"distance": best_distance,
				"elevation": best_elevation,
				"route_id": best_route,
				"tier": global.tier,
				"axis": global.axis,
				"family": global.get("family", global.axis),
				"tangent": global.get("tangent", Vector2.RIGHT),
				"center_point": global.get("center_point", point),
				"route_coordinate": global.get("route_coordinate", 0.0),
				"along": global.get("along", 0.0),
				"curve_offset": global.get("curve_offset", 0.0),
				"bridge_candidate": global.get("bridge_candidate", false),
				"bridge_candidate_score": global.get(
					"bridge_candidate_score", 0.0),
				"bridge_slot": global.get("bridge_slot", 0),
				"bridge_id": global.get("bridge_id", ""),
				"bridge_coordinate": global.get("bridge_coordinate", 0.0),
				"intersection_score": global.get("intersection_score", 0.0),
				"intersection_id": global.get("intersection_id", ""),
				"eligibility": eligibility,
			})
	if best_distance > best_half_width + ROAD_BLEND:
		return _remember_road_sample(point, {"grade": 0.0,
			"distance": best_distance, "elevation": best_elevation,
			"route_id": best_route})
	return _remember_road_sample(point, {
		"grade": 1.0 - smoothstep(best_half_width,
			best_half_width + ROAD_BLEND, best_distance),
		"distance": best_distance,
		"elevation": best_elevation,
		"route_id": best_route,
	})


func _remember_road_sample(point: Vector2, sample: Dictionary) -> Dictionary:
	_last_road_sample_xz = point
	_last_road_sample = sample
	return sample


func _global_road_context(point: Vector2, planet_sample: Dictionary,
		global: Dictionary) -> Dictionary:
	var center: Vector2 = global.get("center_point", point)
	var tangent: Vector2 = global.get("tangent", Vector2.RIGHT)
	if tangent.length_squared() < 0.001:
		tangent = Vector2.RIGHT
	tangent = tangent.normalized()
	var across := Vector2(-tangent.y, tangent.x)
	var route_id := str(global.get("route_id", "road"))
	var along := float(global.get("route_coordinate",
		global.get("along", center.dot(tangent))))
	# Three metres is the shared terrain lattice. Quantizing only the cache key
	# keeps repeated shoulder vertices cheap while stable route IDs prevent two
	# curved roads at a junction from borrowing each other's engineering state.
	var context_key := "%s@%d" % [route_id, roundi(along / 3.0)]
	if _road_context_cache.has(context_key):
		return _road_context_cache[context_key]
	var macro: Dictionary = planet_sample if center.distance_squared_to(point) \
		< 0.0001 else {}
	if macro.is_empty():
		macro = planet_terrain_sample(center.x, center.y)
	var eligibility := smoothstep(0.58, 0.76, float(macro.land)) \
		* (1.0 - smoothstep(0.12, 0.48, float(macro.ocean))) \
		* (1.0 - smoothstep(0.16, 0.48, float(macro.lake))) \
		* (1.0 - smoothstep(0.34, 0.64, float(macro.mountain)))
	eligibility *= smoothstep(86.0, 138.0, center.length())
	eligibility *= 1.0 - smoothstep(0.08, 0.52,
		airstrip_grade(center.x, center.y))
	# Audit along the real curved tangent, never world X/Z. This preserves smooth
	# grades through bends and gives the perpendicular cut a true cross-slope.
	var audit_along := snappedf(along, ROAD_AUDIT_SPACING)
	var audit_center := canonical_planet_xz(center
		+ tangent * (audit_along - along))
	var audit_key := "%s@%d" % [route_id,
		roundi(audit_along / ROAD_AUDIT_SPACING)]
	var audit: Dictionary = _road_audit_cache.get(audit_key, {})
	if audit.is_empty():
		var audit_macro := planet_terrain_sample(audit_center.x,
			audit_center.y)
		var audit_here := float(audit_macro.elevation)
		var along_probe := tangent * 96.0
		var before := planet_terrain_sample(audit_center.x - along_probe.x,
			audit_center.y - along_probe.y)
		var after := planet_terrain_sample(audit_center.x + along_probe.x,
			audit_center.y + along_probe.y)
		var natural_longitudinal_grade := maxf(
			absf(audit_here - float(before.elevation)),
			absf(float(after.elevation) - audit_here)) / along_probe.length()
		var across_probe := across * 24.0
		var across_before := planet_terrain_sample(
			audit_center.x - across_probe.x,
			audit_center.y - across_probe.y)
		var across_after := planet_terrain_sample(
			audit_center.x + across_probe.x,
			audit_center.y + across_probe.y)
		var natural_cross_grade := maxf(
			absf(audit_here - float(across_before.elevation)),
			absf(float(across_after.elevation) - audit_here)) \
			/ across_probe.length()
		audit = {
			"slope_factor": (1.0 - smoothstep(ROAD_MAX_GRADE * 0.76,
				ROAD_MAX_GRADE * 1.06, natural_longitudinal_grade)) \
				* (1.0 - smoothstep(0.055, 0.095, natural_cross_grade)),
			"natural_longitudinal_grade": natural_longitudinal_grade,
			"natural_cross_grade": natural_cross_grade,
		}
		if _road_audit_cache.size() >= 4096:
			_road_audit_cache.clear()
		_road_audit_cache[audit_key] = audit
	var broad_here := float(macro.elevation)
	eligibility *= float(audit.slope_factor)
	var engineered_elevation := maxf(broad_here, WATER_Y + 0.92)
	var feature := _transport_feature_for_road(global)
	if not feature.is_empty():
		var feature_delta := along - float(feature.coordinate)
		if str(feature.kind) == "tunnel":
			var tunnel_half := float(feature.length) * 0.5
			var tunnel_extent := tunnel_half + FREEWAY_TUNNEL_APPROACH
			var tunnel_strength := 1.0 - smoothstep(
				tunnel_extent - ROAD_BLEND, tunnel_extent,
				absf(feature_delta))
			if tunnel_strength > 0.0:
				var tunnel_t := clampf((feature_delta + tunnel_extent)
					/ (tunnel_extent * 2.0), 0.0, 1.0)
				var tunnel_floor := lerpf(float(feature.portal_a_elevation),
					float(feature.portal_b_elevation), tunnel_t)
				eligibility = maxf(eligibility, tunnel_strength)
				engineered_elevation = lerpf(engineered_elevation,
					tunnel_floor, tunnel_strength)
		elif str(feature.kind) == "bridge":
			var bridge_half := float(feature.length) * 0.5
			var absolute_delta := absf(feature_delta)
			if absolute_delta < bridge_half:
				# The physical bridge owns this span. Leaving the heightfield low
				# preserves real water/air beneath its deck and collision.
				eligibility = 0.0
			elif absolute_delta < bridge_half + ROAD_BRIDGE_APPROACH:
				var ramp := 1.0 - smoothstep(bridge_half,
					bridge_half + ROAD_BRIDGE_APPROACH, absolute_delta)
				eligibility = maxf(eligibility, ramp)
				engineered_elevation = lerpf(engineered_elevation,
					float(feature.deck_elevation), ramp)
	var context := {
		"eligibility": eligibility,
		"elevation": engineered_elevation,
		"natural_longitudinal_grade": audit.natural_longitudinal_grade,
		"natural_cross_grade": audit.natural_cross_grade,
		"transport_feature": feature,
	}
	# The same centreline point is queried by every terrain vertex across a road
	# shoulder and often by two adjacent LODs. Keep that deterministic audit
	# bounded without turning the complete planet road graph into stored state.
	if _road_context_cache.size() >= 8192:
		_road_context_cache.clear()
	_road_context_cache[context_key] = context
	return context


## Resolve the single deterministic engineering slot carried by a curved route
## into either a narrow-water bridge, a dry mountain tunnel, or no structure.
## The result is keyed by stable route + coordinate, so terrain, chunks, map
## previews and every multiplayer peer make the same bounded decision.
func _transport_feature_for_road(global: Dictionary) -> Dictionary:
	if not bool(global.get("bridge_candidate", false)):
		return {}
	var candidate_id := str(global.get("bridge_id", ""))
	if candidate_id.is_empty() or not global.has("bridge_coordinate"):
		return {}
	if _transport_feature_cache.has(candidate_id):
		return _transport_feature_cache[candidate_id]
	var coordinate := float(global.bridge_coordinate)
	var along := float(global.get("route_coordinate",
		global.get("along", coordinate)))
	var tangent: Vector2 = global.get("tangent", Vector2.RIGHT)
	if tangent.length_squared() < 0.001:
		tangent = Vector2.RIGHT
	tangent = tangent.normalized()
	var center: Vector2 = global.get("center_point", Vector2.ZERO) \
		+ tangent * (coordinate - along)
	# Two cheap projections remove chord/tangent error for a candidate hundreds
	# of metres from the caller while keeping the exact route coordinate.
	var centered: Dictionary = global
	for _projection in range(2):
		var next_centered := _planet_roads.surface_sample(center)
		# A feature can sit close to a junction where the nearest-road selector
		# changes families. Retain the last projection on this stable route instead
		# of deleting a valid tunnel/bridge merely because the crossing route wins
		# the next infinitesimal closest-distance tie.
		if str(next_centered.get("bridge_id", "")) != candidate_id:
			break
		centered = next_centered
		tangent = centered.get("tangent", tangent)
		if tangent.length_squared() < 0.001:
			tangent = Vector2.RIGHT
		tangent = tangent.normalized()
		center = centered.get("center_point", center) + tangent \
			* (coordinate - float(centered.get("route_coordinate", coordinate)))
	center = canonical_planet_xz(center)
	var macro := planet_terrain_sample(center.x, center.y)
	var feature: Dictionary = {}
	var polar := float(macro.get("polar_ice", 0.0))
	var center_wet := float(macro.ocean) > 0.44 \
		or float(macro.lake) > 0.44 \
		or float(macro.elevation) < WATER_Y + 0.18
	if polar < 0.36:
		for length_value in [72.0, 96.0, 120.0, 144.0, 180.0]:
			var bridge_length: float = float(length_value)
			if bridge_length < ROAD_BRIDGE_MIN_LENGTH \
					or bridge_length > ROAD_BRIDGE_MAX_LENGTH:
				continue
			var half_length := bridge_length * 0.5
			var a_point := center - tangent * half_length
			var b_point := center + tangent * half_length
			var a_macro := planet_terrain_sample(a_point.x, a_point.y)
			var b_macro := planet_terrain_sample(b_point.x, b_point.y)
			var a_dry := float(a_macro.land) > 0.58 \
				and float(a_macro.ocean) < 0.34 \
				and float(a_macro.lake) < 0.34 \
				and float(a_macro.elevation) > WATER_Y + 0.28
			var b_dry := float(b_macro.land) > 0.58 \
				and float(b_macro.ocean) < 0.34 \
				and float(b_macro.lake) < 0.34 \
				and float(b_macro.elevation) > WATER_Y + 0.28
			if not a_dry or not b_dry:
				continue
			# Bridges serve both narrow water and genuine ravines. The latter is
			# what lets an organic arterial keep its line across broken foothills
			# instead of becoming a grid or vanishing at every depression.
			var ravine_depth := minf(float(a_macro.elevation),
				float(b_macro.elevation)) - float(macro.elevation)
			if not center_wet and ravine_depth < 5.0:
				continue
			var deck_elevation := maxf(WATER_Y + 1.20,
				maxf(float(a_macro.elevation), float(b_macro.elevation)) + 0.08)
			var obstacle_floor := WATER_Y if center_wet \
				else float(macro.elevation)
			feature = {
				"kind": "bridge", "id": candidate_id,
				"coordinate": coordinate, "length": bridge_length,
				"width": ROAD_BRIDGE_WIDTH,
				"pos": Vector3(center.x, deck_elevation, center.y),
				"yaw": atan2(tangent.x, tangent.y),
				"tangent": tangent, "deck_elevation": deck_elevation,
				"clearance_height": maxf(deck_elevation - obstacle_floor, 1.8),
				"clearance": half_length + ROAD_BRIDGE_APPROACH,
			}
			break
	if feature.is_empty() and str(global.get("tier", "")) == "highway" \
			and polar < 0.36:
		var tunnel_extent := FREEWAY_TUNNEL_LENGTH * 0.5 \
			+ FREEWAY_TUNNEL_APPROACH
		var a_point := center - tangent * tunnel_extent
		var b_point := center + tangent * tunnel_extent
		var a_macro := planet_terrain_sample(a_point.x, a_point.y)
		var b_macro := planet_terrain_sample(b_point.x, b_point.y)
		var dry_mountain := float(macro.land) > 0.62 \
			and float(macro.ocean) < 0.26 and float(macro.lake) < 0.28 \
			and float(macro.mountain) > 0.42 \
			and float(macro.elevation) > WATER_Y + 120.0
		var portal_a := maxf(float(a_macro.elevation), WATER_Y + 0.92)
		var portal_b := maxf(float(b_macro.elevation), WATER_Y + 0.92)
		var natural_grade := absf(portal_b - portal_a) \
			/ (tunnel_extent * 2.0)
		if dry_mountain \
				and float(a_macro.land) > 0.54 and float(b_macro.land) > 0.54 \
				and natural_grade <= ROAD_MAX_GRADE * 1.25:
			feature = {
				"kind": "tunnel",
				"id": candidate_id.replace(":bridge:", ":tunnel:"),
				"coordinate": coordinate, "length": FREEWAY_TUNNEL_LENGTH,
				"width": FREEWAY_TUNNEL_WIDTH,
				"height": FREEWAY_TUNNEL_HEIGHT,
				"pos": Vector3(center.x, (portal_a + portal_b) * 0.5,
					center.y),
				"yaw": atan2(tangent.x, tangent.y), "tangent": tangent,
				"portal_a_elevation": portal_a,
				"portal_b_elevation": portal_b,
				"clearance": tunnel_extent + FREEWAY_TUNNEL_WIDTH * 0.5,
			}
	if _transport_feature_cache.size() >= 4096:
		_transport_feature_cache.clear()
	_transport_feature_cache[candidate_id] = feature
	return feature


## Materialize only transport structures owned by one gameplay chunk. The
## curved road query is bounded to 64 short chords and feature IDs de-duplicate
## overlapping query margins, so high-speed streaming never scans a world graph.
func transport_feature_chunk_layout(cx: int, cz: int) -> Dictionary:
	if debug_world:
		return {"freeway_tunnels": [], "road_bridges": []}
	var cache_key := Vector2i(cx, cz)
	if _transport_chunk_cache.has(cache_key):
		return (_transport_chunk_cache[cache_key] as Dictionary).duplicate(true)
	var x0 := float(cx) * CHUNK
	var z0 := float(cz) * CHUNK
	var rect := Rect2(Vector2(x0, z0), Vector2(CHUNK, CHUNK))
	var query_rect := rect.grow(TRANSPORT_FEATURE_QUERY_MARGIN)
	var segments := _planet_roads.segments_in_rect(query_rect, 64)
	var freeway_tunnels: Array = []
	var road_bridges: Array = []
	var seen: Dictionary = {}
	for segment_value in segments:
		var segment: Dictionary = segment_value
		if not bool(segment.get("bridge_candidate", false)) \
				or not segment.has("bridge_coordinate"):
			continue
		var segment_id := str(segment.get("bridge_id", ""))
		if segment_id.is_empty() or seen.has(segment_id):
			continue
		var a: Vector2 = segment.get("a", rect.get_center())
		var b: Vector2 = segment.get("b", rect.get_center())
		var tangent: Vector2 = segment.get("tangent", (b - a).normalized())
		if tangent.length_squared() < 0.001:
			continue
		tangent = tangent.normalized()
		var midpoint := (a + b) * 0.5
		var coordinate := float(segment.bridge_coordinate)
		var projected := midpoint + tangent * (coordinate
			- float(segment.get("route_coordinate", coordinate)))
		var global := _planet_roads.surface_sample(projected)
		if str(global.get("bridge_id", "")) != segment_id:
			continue
		var feature := _transport_feature_for_road(global)
		if feature.is_empty():
			seen[segment_id] = true
			continue
		var canonical_pos: Vector3 = feature.pos
		var image_xz := nearest_world_image(
			Vector2(canonical_pos.x, canonical_pos.z), rect.get_center())
		var owner := Vector2i(floori(image_xz.x / CHUNK),
			floori(image_xz.y / CHUNK))
		if owner != cache_key:
			continue
		var instance_data: Dictionary = feature.duplicate(true)
		instance_data.pos = Vector3(image_xz.x, canonical_pos.y, image_xz.y)
		if str(instance_data.kind) == "tunnel":
			freeway_tunnels.append(instance_data)
		elif str(instance_data.kind) == "bridge":
			road_bridges.append(instance_data)
		seen[segment_id] = true
	var result := {
		"freeway_tunnels": freeway_tunnels,
		"road_bridges": road_bridges,
	}
	if _transport_chunk_cache.size() >= 1024:
		_transport_chunk_cache.clear()
	_transport_chunk_cache[cache_key] = result
	return result.duplicate(true)


## Bounded streaming/map query. The analytic network never needs to allocate a
## planet-sized graph: only lines crossing this local rectangle are returned.
func road_segments_in_rect(rect: Rect2, max_segments := 128) -> Array:
	return _planet_roads.segments_in_rect(rect, max_segments)


func road_network_summary() -> Dictionary:
	return {
		"kind": "curved_planet_arterials",
		"highway_spacing": PlanetRoadNetworkScript.HIGHWAY_SPACING,
		"regional_spacing": PlanetRoadNetworkScript.REGIONAL_SPACING,
		"maximum_query_segments": PlanetRoadNetworkScript.MAX_SEGMENTS_PER_QUERY,
		"circumference": PLANET_CIRCUMFERENCE,
		"max_grade": ROAD_MAX_GRADE,
		"coast_following": true,
		"bridges": true,
		"lit_mountain_tunnels": true,
	}


func road_grade(x: float, z: float) -> float:
	return float(road_surface_sample(x, z).grade)


func point_on_road(x: float, z: float) -> bool:
	return road_grade(x, z) > 0.16


func point_in_road_clearance(x: float, z: float, extra := 0.0) -> bool:
	var sample := road_surface_sample(x, z)
	return float(sample.distance) <= ROAD_HALF_WIDTH + ROAD_BLEND + extra


## 0..1 membership in the graded runway/apron footprint.
func airstrip_grade(x: float, z: float) -> float:
	if not airstrip_valid:
		return 0.0
	var p := canonical_planet_xz(Vector2(x, z))
	# The runway approach may point toward the origin for some seeds. Keep its
	# soft shoulder out of the authored duel bowl even when the 1,260 m strip's
	# bounding corridor crosses that neighbourhood.
	var arena_exclusion := smoothstep(46.0, 76.0, p.length())
	if arena_exclusion <= 0.0:
		return 0.0
	if not _strip_bounds.has_point(p):
		return 0.0
	var rel := p - airstrip_center
	var u := rel.dot(_strip_dir)
	var v := rel.dot(_strip_perp)
	var du := maxf(absf(u) - AIRSTRIP_LENGTH * 0.5, 0.0)
	var dv := maxf(absf(v) - AIRSTRIP_WIDTH * 0.5, 0.0)
	var d := Vector2(du, dv).length()
	var apron := airstrip_apron_local()
	var apron_d := maxf(Vector2(u, v).distance_to(apron)
		- AIRSTRIP_APRON_RADIUS, 0.0)
	d = minf(d, apron_d)
	# A rectangular hardstand joins all six open hangars to the runway. It is
	# part of the same analytic grade/exclusion footprint, so every terrain LOD,
	# collision chunk, and foliage pass agrees on the concrete-clear interior.
	var hangar_pad := airstrip_hangar_pad_local()
	var hangar_pad_center := hangar_pad.get_center()
	var hangar_du := maxf(absf(u - hangar_pad_center.x)
		- hangar_pad.size.x * 0.5, 0.0)
	var hangar_dv := maxf(absf(v - hangar_pad_center.y)
		- hangar_pad.size.y * 0.5, 0.0)
	d = minf(d, Vector2(hangar_du, hangar_dv).length())
	return (1.0 - smoothstep(0.0, AIRSTRIP_BLEND, d)) * arena_exclusion


func airstrip_apron_local() -> Vector2:
	return Vector2(-AIRSTRIP_LENGTH * 0.5 + 14.0,
		AIRSTRIP_WIDTH * 0.5 + AIRSTRIP_APRON_RADIUS + 4.0)


func airstrip_apron_world() -> Vector2:
	var apron := airstrip_apron_local()
	return airstrip_center + _strip_dir * apron.x + _strip_perp * apron.y


## Dry, level four-seat rocket pad beside the near end of the runway, on the
## side opposite the hangars. It is analytic so all peers, collision LODs and
## future moon-expedition systems agree without replicating a transform.
func rocket_launch_position() -> Vector3:
	if not airstrip_valid:
		return Vector3(96.0, 3.3, -48.0)
	var local := Vector2(-AIRSTRIP_LENGTH * 0.5 + 205.0,
		-(AIRSTRIP_WIDTH * 0.5 + ROCKET_PAD_RADIUS + 12.0))
	var world := airstrip_center + _strip_dir * local.x + _strip_perp * local.y
	return Vector3(world.x, airstrip_elevation + 0.06, world.y)


func rocket_launch_grade(x: float, z: float) -> float:
	if not airstrip_valid:
		return 0.0
	var canonical := canonical_planet_xz(Vector2(x, z))
	var pad := rocket_launch_position()
	var distance := canonical.distance_to(Vector2(pad.x, pad.z))
	return 1.0 - smoothstep(ROCKET_PAD_RADIUS,
		ROCKET_PAD_RADIUS + ROCKET_PAD_BLEND, distance)


func point_in_rocket_launch_clearance(x: float, z: float,
		extra := 0.0) -> bool:
	var pad := rocket_launch_position()
	return canonical_planet_xz(Vector2(x, z)).distance_to(
		Vector2(pad.x, pad.z)) <= ROCKET_PAD_RADIUS + extra


## Six deterministic open-front hangars run parallel to the near end of the
## strip. Local +X follows the runway, local +Z points away from it, and each
## jet faces local -Z through the open door. IDs and transforms depend only on
## the seed-derived airstrip transform, making chunk order irrelevant.
func airstrip_hangar_layout() -> Array:
	if not airstrip_valid:
		return []
	var defs: Array = []
	var first_u := -AIRSTRIP_LENGTH * 0.5 + 84.0
	var hangar_v := AIRSTRIP_WIDTH * 0.5 + AIRSTRIP_HANGAR_TAXI_GAP \
		+ AIRSTRIP_HANGAR_DEPTH * 0.5
	var hangar_yaw := airstrip_heading + PI * 0.5
	var jet_yaw := hangar_yaw + PI
	for i in range(AIRSTRIP_HANGAR_COUNT):
		var local := Vector2(first_u + float(i) * AIRSTRIP_HANGAR_SPACING,
			hangar_v)
		var world := airstrip_center + _strip_dir * local.x \
			+ _strip_perp * local.y
		# Keep the complete aircraft visibly behind the threshold while leaving
		# enough rear clearance for its nozzle and exhaust plume.
		var jet_world := world - _strip_perp * 0.8
		defs.append({
			"kind": "airfield_hangar",
			"id": "h:strip#%d" % i,
			"index": i,
			"pos": Vector3(world.x, airstrip_elevation, world.y),
			"yaw": hangar_yaw,
			"size": Vector3(AIRSTRIP_HANGAR_WIDTH,
				AIRSTRIP_HANGAR_HEIGHT, AIRSTRIP_HANGAR_DEPTH),
			"clearance": AIRSTRIP_HANGAR_CLEARANCE,
			"jet_id": "v:strip#jet-%d" % i,
			"jet_pos": Vector3(jet_world.x, airstrip_elevation, jet_world.y),
			"jet_yaw": jet_yaw,
		})
	return defs


func airstrip_hangar_chunk_layout(cx: int, cz: int) -> Array:
	var defs: Array = []
	for hangar in airstrip_hangar_layout():
		var pos: Vector3 = hangar.pos
		if floori(pos.x / CHUNK) == cx and floori(pos.z / CHUNK) == cz:
			defs.append(hangar)
	return defs


func airstrip_hangar_pad_local() -> Rect2:
	var first_u := -AIRSTRIP_LENGTH * 0.5 + 84.0
	var last_u := first_u + float(AIRSTRIP_HANGAR_COUNT - 1) \
		* AIRSTRIP_HANGAR_SPACING
	var minimum_u := first_u - AIRSTRIP_HANGAR_WIDTH * 0.5 \
		- AIRSTRIP_HANGAR_PAD_MARGIN
	var maximum_u := last_u + AIRSTRIP_HANGAR_WIDTH * 0.5 \
		+ AIRSTRIP_HANGAR_PAD_MARGIN
	var minimum_v := AIRSTRIP_WIDTH * 0.5
	var maximum_v := AIRSTRIP_WIDTH * 0.5 + AIRSTRIP_HANGAR_TAXI_GAP \
		+ AIRSTRIP_HANGAR_DEPTH + AIRSTRIP_HANGAR_PAD_MARGIN
	return Rect2(Vector2(minimum_u, minimum_v),
		Vector2(maximum_u - minimum_u, maximum_v - minimum_v))


func point_on_airstrip(x: float, z: float) -> bool:
	return airstrip_grade(x, z) > 0.22


## Elevation buys horizon: standing on a tall peak (or flying) stretches the
## far plane smoothly from 2.2 km up to a 15-mile view. Pure math so tests and
## the streaming/fog/camera systems all agree on one curve.
func view_distance_for_altitude(altitude: float) -> float:
	var normalized_height := clampf((altitude - 10.0) \
		/ (PLANET_SUMMIT_ELEVATION - 10.0), 0.0, 1.0)
	return lerpf(VIEW_BASE_DISTANCE, VIEW_PEAK_DISTANCE,
		pow(normalized_height, VIEW_ALTITUDE_CURVE))


func height(x: float, z: float) -> float:
	if debug_world:
		return 2.0
	var macro := planet_terrain_sample(x, z)
	var canonical: Vector2 = macro.xz
	return _height_with_planet_sample(canonical.x, canonical.y, macro)


## 0..1 strength of the mountain ranges at a point. Suppressed near the world
## origin so the spawn meadow, hero grove, and duel arena keep their authored
## gentle terrain, and cheap when far from any range (one mask sample).
func mountain_influence(x: float, z: float) -> float:
	if debug_world:
		return 0.0
	return float(planet_terrain_sample(x, z).mountain)


func _height_with_planet_sample(x: float, z: float,
		macro: Dictionary, road_override: Dictionary = {}) -> float:
	var h := float(macro.elevation)
	# The broad home continent may sit hundreds of metres above sea level, but
	# the legacy spawn neighbourhood remains a gently graded, accessible coast.
	var home_distance := Vector2(x, z).length()
	var home_grade := 1.0 - smoothstep(115.0, 265.0, home_distance)
	# Keep the spawn meadow graded, but do not lift the deliberately nearby lake
	# back into dry ground after PlanetTerrain has carved its swim-safe basin.
	home_grade *= 1.0 - smoothstep(0.22, 0.62, float(macro.lake))
	if home_grade > 0.0:
		var home_floor := 3.25 + _n_detail.get_noise_2d(
			x * 0.20, z * 0.20) * 0.16
		h = lerpf(h, home_floor, home_grade)
	# Connected packed-dirt routes flatten only their driveable crown and blend
	# through soft shoulders. Local destination routes and the planet-wide
	# analytic lattice share this exact height/color query.
	var road: Dictionary = road_override
	if road.is_empty():
		road = _road_surface_sample(x, z, macro)
	var road_strength := float(road.grade)
	if road_strength > 0.0:
		var road_floor := float(road.elevation) \
			+ _n_detail.get_noise_2d(x * 0.61, z * 0.61) * 0.018
		h = lerpf(h, road_floor, road_strength)
	# Grade the authored duel bowl and every arena prop footprint onto one gentle
	# fighting surface. Outside 35 m it blends back into the exact procedural
	# terrain over 11 m, so there is no hard rim or visible chunk seam.
	var arena_distance := Vector2(x, z).length()
	var arena_grade := 1.0 - smoothstep(35.0, 46.0, arena_distance)
	if arena_grade > 0.0:
		var arena_floor := 3.25 + _n_detail.get_noise_2d(
			x * 0.62, z * 0.62) * 0.10
		h = lerpf(h, arena_floor, arena_grade)
	# Grade the bush airstrip: a dead-flat packed-dirt runway and apron carved
	# into whatever the corridor search found, blending back into procedural
	# jungle over 30 m. Every LOD tier, the minimap, collision, and the
	# analytic wheel fallback agree because they all pass through here.
	var strip_grade := airstrip_grade(x, z)
	if strip_grade > 0.0:
		var strip_floor := airstrip_elevation \
			+ _n_detail.get_noise_2d(x * 0.44, z * 0.44) * 0.05
		h = lerpf(h, strip_floor, strip_grade)
	var rocket_grade := rocket_launch_grade(x, z)
	if rocket_grade > 0.0:
		var rocket_floor := airstrip_elevation \
			+ _n_detail.get_noise_2d(x * 0.33, z * 0.33) * 0.025
		h = lerpf(h, rocket_floor, rocket_grade)
	# Road slope audits sample four neighbouring points. Restore the caller's
	# macro sample so the immediately following ground-color/biome query for this
	# same terrain vertex remains a one-entry cache hit.
	_last_planet_sample_xz = macro.xz
	_last_planet_sample = macro
	return h


func lake_influence(x: float, z: float) -> float:
	if debug_world:
		return 0.0
	return float(planet_terrain_sample(x, z).lake)


func ocean_influence(x: float, z: float) -> float:
	if debug_world:
		return 0.0
	return float(planet_terrain_sample(x, z).ocean)


func land_influence(x: float, z: float) -> float:
	if debug_world:
		return 1.0
	return float(planet_terrain_sample(x, z).land)


func planet_terrain_sample(x: float, z: float) -> Dictionary:
	if debug_world:
		return {"xz": Vector2(x, z), "elevation": 2.0, "land": 1.0,
			"ocean": 0.0, "lake": 0.0, "upland": 0.0,
			"mountain": 0.0, "temperature": 0.72, "moisture": 0.68,
			"detail": 0.0, "latitude_fraction": 0.0,
			"polar_ice": 0.0,
			"coast_distance": 1000000.0,
			"coast_tangent": Vector2.RIGHT,
			"summit_weight": 0.0}
	var canonical := canonical_planet_xz(Vector2(x, z))
	if canonical == _last_planet_sample_xz and not _last_planet_sample.is_empty():
		return _last_planet_sample
	# All four streamed terrain LODs share a 3 m base lattice. Retain only those
	# exact reusable samples in a bounded FIFO; arbitrary tree/map probes do not
	# pollute it. This lets a horizon/skyline/stratos handoff reuse the same 3D
	# spherical noise work instead of evaluating every shared vertex again.
	var x_mod := fposmod(canonical.x, 3.0)
	var z_mod := fposmod(canonical.y, 3.0)
	var lattice_sample := (x_mod < 0.0001 or x_mod > 2.9999) \
		and (z_mod < 0.0001 or z_mod > 2.9999)
	if lattice_sample and _planet_lattice_cache.has(canonical):
		_last_planet_sample_xz = canonical
		_last_planet_sample = _planet_lattice_cache[canonical]
		return _last_planet_sample
	_last_planet_sample_xz = canonical
	_last_planet_sample = _planet.sample(canonical)
	if lattice_sample:
		if _planet_lattice_cache_order.size() < PLANET_LATTICE_CACHE_LIMIT:
			_planet_lattice_cache_order.append(canonical)
		else:
			var oldest := _planet_lattice_cache_order[
				_planet_lattice_cache_cursor]
			_planet_lattice_cache.erase(oldest)
			_planet_lattice_cache_order[_planet_lattice_cache_cursor] = canonical
			_planet_lattice_cache_cursor = (_planet_lattice_cache_cursor + 1) \
				% PLANET_LATTICE_CACHE_LIMIT
		_planet_lattice_cache[canonical] = _last_planet_sample
	return _last_planet_sample


## Allocation-free-at-the-call-site companions for world-map tile baking and
## quantitative tests that already hold a macro sample.
func planet_height_from_sample(macro: Dictionary) -> float:
	var canonical: Vector2 = macro.get("xz", Vector2.ZERO)
	return _height_with_planet_sample(canonical.x, canonical.y, macro)


func planet_biome_from_sample(macro: Dictionary, elevation: float) -> int:
	var canonical: Vector2 = macro.get("xz", Vector2.ZERO)
	return _biome_from_planet_sample(canonical.x, canonical.y,
		elevation, macro)


func biome_at(x: float, z: float) -> int:
	var macro := planet_terrain_sample(x, z)
	var canonical: Vector2 = macro.xz
	var elevation := _height_with_planet_sample(canonical.x, canonical.y, macro)
	return _biome_from_planet_sample(canonical.x, canonical.y, elevation, macro)


## Terrain and decoration builders already have the exact elevation sample.
## Reusing it avoids a full duplicate terrain/noise evaluation per vertex while
## preserving the same deterministic biome thresholds.
func biome_at_height(x: float, z: float, elevation: float) -> int:
	var macro := planet_terrain_sample(x, z)
	var canonical: Vector2 = macro.xz
	return _biome_from_planet_sample(canonical.x, canonical.y,
		elevation, macro)


func _biome_from_planet_sample(x: float, z: float, elevation: float,
		macro: Dictionary) -> int:
	var ocean := float(macro.ocean)
	var lake := float(macro.lake)
	var mountain := float(macro.mountain)
	var upland := float(macro.upland)
	var temperature := float(macro.temperature)
	var moisture := float(macro.moisture)
	var latitude := float(macro.latitude_fraction)
	var polar_ice := float(macro.get("polar_ice", 0.0))
	if polar_ice > 0.64 or temperature < 0.095 or latitude > 0.94:
		return Biome.ICE
	# The outer polar shelf is windswept tundra before it becomes permanent
	# pack ice. Keep this transition ahead of ocean classification so both caps
	# retain a readable Earth-like tundra ring even where they cover sea.
	if polar_ice > 0.055:
		return Biome.TUNDRA
	if ocean > 0.34 and elevation < WATER_Y + 0.8:
		return Biome.OCEAN
	if lake > 0.34 and elevation < WATER_Y + 0.8:
		return Biome.LAKE
	if temperature < 0.275 or latitude > 0.72:
		return Biome.TUNDRA
	if mountain > 0.34 or elevation > 920.0:
		return Biome.ROCKY_MOUNTAINS
	if lake > 0.07 or (elevation < WATER_Y + 2.2 and moisture > 0.54):
		return Biome.WETLAND
	if moisture < 0.335 and temperature > 0.52:
		return Biome.DESERT
	if upland > 0.47 or elevation > 330.0:
		return Biome.HIGHLAND
	if moisture > 0.69 and temperature > 0.58:
		return Biome.RAINFOREST
	if moisture > 0.59 and temperature > 0.45:
		return Biome.BAMBOO_GROVE
	if moisture > 0.46:
		return Biome.GRASSLAND
	return Biome.PLAINS


func biome_name(biome: int) -> String:
	return BIOME_NAMES.get(biome, "Jungle")


func ground_color(h: float, x: float, z: float) -> Color:
	var macro := planet_terrain_sample(x, z)
	var canonical: Vector2 = macro.xz
	var road := _road_surface_sample(canonical.x, canonical.y, macro)
	return _ground_color_from_sample(h, canonical.x, canonical.y, macro, road)


func _ground_color_from_sample(h: float, x: float, z: float,
		macro: Dictionary, road: Dictionary) -> Color:
	var jit := float(macro.detail) * 0.42
	if h < WATER_Y + 0.4:
		if float(macro.ocean) > float(macro.lake):
			return Color(0.055 + jit * 0.02, 0.105, 0.16)
		return Color(0.31 + jit * 0.03, 0.285, 0.19)
	var t := clampf((h - 5.0) / 850.0, 0.0, 1.0)
	var biome := _biome_from_planet_sample(x, z, h, macro)
	# Deep, sunlight-starved forest-floor greens rather than lawn tones.
	var low := Color(0.085, 0.26, 0.08)
	var high := Color(0.035, 0.155, 0.06)
	match biome:
		Biome.BAMBOO_GROVE:
			low = Color(0.14, 0.30, 0.075)
			high = Color(0.065, 0.19, 0.05)
		Biome.WETLAND:
			low = Color(0.095, 0.225, 0.09)
			high = Color(0.045, 0.14, 0.08)
		Biome.HIGHLAND:
			low = Color(0.075, 0.215, 0.10)
			high = Color(0.035, 0.13, 0.085)
		Biome.PLAINS:
			low = Color(0.34, 0.43, 0.13)
			high = Color(0.21, 0.31, 0.105)
		Biome.GRASSLAND:
			low = Color(0.23, 0.42, 0.10)
			high = Color(0.12, 0.29, 0.075)
		Biome.ROCKY_MOUNTAINS:
			low = Color(0.30, 0.285, 0.25)
			high = Color(0.42, 0.405, 0.38)
		Biome.DESERT:
			low = Color(0.67, 0.46, 0.22)
			high = Color(0.53, 0.34, 0.17)
		Biome.TUNDRA:
			low = Color(0.37, 0.40, 0.29)
			high = Color(0.27, 0.31, 0.27)
		Biome.ICE:
			low = Color(0.73, 0.81, 0.85)
			high = Color(0.88, 0.92, 0.94)
		Biome.OCEAN:
			low = Color(0.065, 0.12, 0.18)
			high = low
		Biome.LAKE:
			low = Color(0.20, 0.25, 0.19)
			high = low
	var c := low.lerp(high, t)
	# The old forced rainforest tint plus perfectly graded duel bowl looked like
	# a stray bright-green plane at spawn. Keep the playable grading, but blend a
	# natural compacted-earth clearing into the surrounding biome instead.
	var arena_surface := 1.0 - smoothstep(34.0, 47.0,
		Vector2(x, z).length())
	if arena_surface > 0.0:
		c = c.lerp(Color(0.30 + jit * 0.025, 0.245, 0.145),
			arena_surface * 0.88)
	# Above the canopy line the soil turns to bare rock, then permanent snow.
	# Shaders add sparkle/roughness on top; the vertex tint carries the bands so
	# every LOD tier (near lattice, horizon, skyline) agrees for free.
	var rock_band := smoothstep(TREE_LINE * 0.7, SNOW_LINE_START, h)
	if rock_band > 0.0:
		c = c.lerp(Color(0.31, 0.28, 0.245), rock_band)
	var snow_band := smoothstep(SNOW_LINE_START, SNOW_LINE_FULL, h)
	if snow_band > 0.0:
		c = c.lerp(Color(0.83, 0.87, 0.91), snow_band)
	if jit > 0.42:
		c = c.darkened(0.22)
	# Warm compacted soil plus twin darker tyre ruts. Because this color is
	# analytic, the same roads remain visible in near terrain, horizon/skyline/
	# stratos tiers, and the CPU-baked minimap without additional draw calls.
	var road_strength := float(road.grade)
	if road_strength > 0.12:
		var dirt := Color(0.39 + jit * 0.025, 0.285, 0.16)
		var rut_distance := absf(float(road.distance) - ROAD_HALF_WIDTH * 0.43)
		var rut := 1.0 - smoothstep(0.18, 0.62, rut_distance)
		dirt = dirt.darkened(rut * 0.16)
		c = c.lerp(dirt, smoothstep(0.12, 0.78, road_strength))
	# Packed-dirt runway/apron surface, baked into every tier and the minimap.
	var strip := airstrip_grade(x, z)
	if strip > 0.3:
		c = c.lerp(Color(0.44 + jit * 0.03, 0.385, 0.265),
			smoothstep(0.3, 0.75, strip))
	var rocket_pad := rocket_launch_grade(x, z)
	if rocket_pad > 0.15:
		c = c.lerp(Color(0.31, 0.325, 0.33),
			smoothstep(0.15, 0.78, rocket_pad))
	return Color(c.r + jit * 0.04, c.g + jit * 0.04, c.b)


## Exact physical terrain vertex plus its matching tint in one call. Streaming
## builders previously re-entered Gen for height and color, repeating cache,
## canonical-coordinate and road dispatch even though both consume the same
## macro and road samples.
func terrain_vertex_sample(x: float, z: float) -> Dictionary:
	# The suspension/debug playground deliberately replaces every terrain query
	# with one flat two-metre plane. Keep this combined fast path on that same
	# contract; bypassing height() here raises the rendered/collision mesh to the
	# planet profile while actors and authored fixtures still spawn at y = 2.
	if debug_world:
		var debug_elevation := height(x, z)
		return {
			"elevation": debug_elevation,
			"color": ground_color(debug_elevation, x, z),
		}
	var macro := planet_terrain_sample(x, z)
	var canonical: Vector2 = macro.xz
	var road := _road_surface_sample(canonical.x, canonical.y, macro)
	var elevation := _height_with_planet_sample(canonical.x, canonical.y,
		macro, road)
	return {
		"elevation": elevation,
		"color": _ground_color_from_sample(elevation, canonical.x,
			canonical.y, macro, road),
	}


## Skyline equivalent with its exact canopy tint folded into the same macro,
## road and biome evaluation. Roads remain physical and visible at this tier.
func skyline_visual_sample(x: float, z: float) -> Dictionary:
	var macro := planet_terrain_sample(x, z)
	var canonical: Vector2 = macro.xz
	var road := _road_surface_sample(canonical.x, canonical.y, macro)
	var elevation := _height_with_planet_sample(canonical.x, canonical.y,
		macro, road)
	var ground := _ground_color_from_sample(elevation, canonical.x,
		canonical.y, macro, road)
	var cover := 0.0
	if float(road.grade) <= 0.16 \
			and not point_on_airstrip(canonical.x, canonical.y) \
			and not point_in_rocket_launch_clearance(canonical.x, canonical.y) \
			and elevation >= WATER_Y + 0.5 and elevation <= TREE_LINE:
		var shore := smoothstep(WATER_Y + 0.5, WATER_Y + 1.6, elevation)
		var tree_line_fade := 1.0 - smoothstep(TREE_LINE - 5.0,
			TREE_LINE, elevation)
		var biome := _biome_from_planet_sample(canonical.x, canonical.y,
			elevation, macro)
		cover = shore * tree_line_fade * _tree_density(biome)
		if cover > 0.0:
			var shade := 0.32 + clampf(_n_color.get_noise_2d(
				canonical.x * 0.5, canonical.y * 0.5) * 0.5 + 0.5,
				0.0, 1.0) * 0.30
			ground = ground.lerp(biome_foliage_color(biome, shade),
				cover * 0.5)
	return {"elevation": elevation, "color": ground, "cover": cover}


## Combined satellite-LOD vertex sample. At 192 metres per lattice cell a
## 10-14 m road is below one pixel; sampling its physical crown aliases almost
## half of the vertices because the road grid and stratos grid share factors,
## and used to trigger hundreds of unnecessary five-point slope audits per
## sector. Near terrain, collision, horizon, skyline and the atlas retain exact
## roads. Stratos deliberately filters that sub-pixel feature while sharing one
## macro/biome/canopy evaluation for everything the vertex actually displays.
func stratos_visual_sample(x: float, z: float) -> Dictionary:
	var macro := planet_terrain_sample(x, z)
	var canonical: Vector2 = macro.xz
	var elevation := _height_with_planet_sample(canonical.x, canonical.y,
		macro, _stratos_no_road_sample)
	if elevation < WATER_Y:
		return {"elevation": elevation, "cover": 0.0, "relief": 0.0,
			"color": Color.BLACK}
	var ground := _ground_color_from_sample(elevation, canonical.x,
		canonical.y, macro, _stratos_no_road_sample)
	var cover := 0.0
	var authored_clear := false
	# All authored flat zones live near the origin. Avoid repeating their
	# coordinate/bounds work for satellite vertices elsewhere on the planet.
	if canonical.length_squared() < 4000000.0:
		authored_clear = point_on_airstrip(canonical.x, canonical.y) \
			or point_in_rocket_launch_clearance(canonical.x, canonical.y)
	if not authored_clear and elevation >= WATER_Y + 0.5 \
			and elevation <= TREE_LINE:
		var shore := smoothstep(WATER_Y + 0.5, WATER_Y + 1.6, elevation)
		var tree_line_fade := 1.0 - smoothstep(TREE_LINE - 5.0,
			TREE_LINE, elevation)
		var biome := _biome_from_planet_sample(canonical.x, canonical.y,
			elevation, macro)
		cover = shore * tree_line_fade * _tree_density(biome)
		if cover > 0.0:
			var shade := 0.32 + clampf(_n_color.get_noise_2d(
				canonical.x * 0.5, canonical.y * 0.5) * 0.5 + 0.5,
				0.0, 1.0) * 0.30
			ground = ground.lerp(biome_foliage_color(biome, shade),
				cover * 0.74)
	var relief := 0.0
	if cover > 0.0:
		var cluster := clampf(_n_color.get_noise_2d(canonical.x * 0.05,
			canonical.y * 0.05) * 0.5 + 0.5, 0.0, 1.0)
		relief = cover * lerpf(STRATOS_CANOPY_RELIEF_MIN,
			STRATOS_CANOPY_RELIEF_MAX, cluster)
	return {"elevation": elevation, "cover": cover, "relief": relief,
		"color": ground}


## Single-pass sample used by the zoomable world map. `meters_per_pixel` widens
## only the color/coverage sample by a capped sub-pixel footprint, keeping roads
## legible at 8-32 m/px while physical terrain and collision widths stay exact.
func map_sample(x: float, z: float, meters_per_pixel := 1.0) -> Dictionary:
	var macro := planet_terrain_sample(x, z)
	var canonical: Vector2 = macro.xz
	var road := _road_surface_sample(canonical.x, canonical.y, macro)
	var elevation := _height_with_planet_sample(canonical.x, canonical.y,
		macro, road)
	var biome := _biome_from_planet_sample(canonical.x, canonical.y,
		elevation, macro)
	var water := elevation < WATER_Y or biome in [Biome.OCEAN, Biome.LAKE]
	var road_strength := float(road.grade)
	var map_road_sample: Dictionary = road.duplicate()
	# A centre-point sample can skip a 9.6 m road completely once one map pixel
	# covers 8-32 m. Expand only the map coverage footprint by a capped fraction
	# of m/px; physical terrain/collision widths remain unchanged.
	var raw_global := _planet_roads.surface_sample(canonical)
	var pixel_dilation := minf(maxf(meters_per_pixel, 0.01) * 0.58, 72.0)
	var global_half_width := float(raw_global.half_width)
	if float(raw_global.distance) <= global_half_width + pixel_dilation \
			+ maxf(meters_per_pixel * 0.28, 1.0):
		var context := _global_road_context(canonical, macro, raw_global)
		var map_global := (1.0 - smoothstep(global_half_width + pixel_dilation,
			global_half_width + pixel_dilation
				+ maxf(meters_per_pixel * 0.28, 1.0),
			float(raw_global.distance))) * float(context.eligibility)
		if map_global > road_strength:
			road_strength = map_global
			map_road_sample = raw_global.duplicate()
			map_road_sample.grade = map_global
	# Preserve the curated motor-pool/dock/airfield links at medium tile zooms.
	if not str(road.get("route_id", "")).begins_with("regional:") \
			and not str(road.get("route_id", "")).begins_with("highway:") \
			and is_finite(float(road.get("distance", INF))):
		var map_curated := 1.0 - smoothstep(ROAD_HALF_WIDTH + pixel_dilation,
			ROAD_HALF_WIDTH + pixel_dilation
				+ maxf(meters_per_pixel * 0.28, 1.0),
			float(road.distance))
		if map_curated > road_strength:
			road_strength = map_curated
			map_road_sample = road.duplicate()
			map_road_sample.grade = map_curated
	var color: Color
	if water:
		var depth := clampf((WATER_Y - elevation) / 360.0, 0.0, 1.0)
		color = Color("247fa8").lerp(Color("082b58"), depth * 0.88)
		if biome == Biome.LAKE:
			color = color.lerp(Color("3191a8"), 0.30)
	else:
		color = _ground_color_from_sample(elevation, canonical.x,
			canonical.y, macro, map_road_sample)
	var tree_cover := 0.0
	if not water and road_strength <= 0.12 \
			and not point_on_airstrip(canonical.x, canonical.y) \
			and not point_in_rocket_launch_clearance(canonical.x, canonical.y) \
			and elevation >= WATER_Y + 0.5 and elevation <= TREE_LINE:
		var shore := smoothstep(WATER_Y + 0.5, WATER_Y + 1.6, elevation)
		var tree_line_fade := 1.0 - smoothstep(TREE_LINE - 5.0,
			TREE_LINE, elevation)
		tree_cover = shore * tree_line_fade * _tree_density(biome)
	return {
		"color": color,
		"water": water,
		"road": road_strength,
		"tree_cover": tree_cover,
		"elevation": elevation,
		"biome": biome,
		"meters_per_pixel": maxf(meters_per_pixel, 0.01),
	}


func _chunk_rng(cx: int, cz: int, salt: int = 0) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	var canonical := canonical_chunk_key(cx, cz)
	r.seed = world_seed * 73856093 + canonical.x * 19349663 \
		+ canonical.y * 83492791 + salt * 7919
	return r


## Fixed "hero grove" ring around world origin so every match spawns somewhere good.
func _hero_positions() -> Array:
	var out: Array = []
	for i in range(6):
		var a := TAU * float(i) / 6.0
		out.append(Vector3(cos(a) * 15.0, 0.0, sin(a) * 15.0))
	return out


## Complete deterministic arena contract. The origin remains open enough for
## high-speed movement, but staggered cover, elevated side decks and a broken
## perimeter create deliberate duel lanes instead of one uninterrupted meadow.
func arena_layout() -> Dictionary:
	var pieces: Array = [
		_arena_piece("north_gate", "palisade", 0.0, 27.5,
			Vector3(8.4, 1.52, 0.62), 0.0, "soft_boundary"),
		_arena_piece("south_gate", "palisade", 0.0, -27.5,
			Vector3(8.4, 1.52, 0.62), 0.0, "soft_boundary"),
		_arena_piece("west_gate", "palisade", -27.5, 0.0,
			Vector3(8.4, 1.52, 0.62), PI * 0.5, "soft_boundary"),
		_arena_piece("east_gate", "palisade", 27.5, 0.0,
			Vector3(8.4, 1.52, 0.62), PI * 0.5, "soft_boundary"),
		_arena_piece("center_west", "barricade", -5.0, -3.0,
			Vector3(4.8, 1.24, 0.72), 0.34, "center_cover"),
		_arena_piece("center_east", "barricade", 5.0, 3.0,
			Vector3(4.8, 1.24, 0.72), 0.34, "center_cover"),
		_arena_piece("west_screen", "barricade", -10.8, 1.2,
			Vector3(4.4, 1.30, 0.74), -0.50, "side_cover"),
		_arena_piece("east_screen", "barricade", 10.8, -1.2,
			Vector3(4.4, 1.30, 0.74), -0.50, "side_cover"),
		_arena_piece("southwest_screen", "barricade", -9.0, -9.0,
			Vector3(4.6, 1.20, 0.70), 0.76, "crossfire_cover"),
		_arena_piece("northeast_screen", "barricade", 9.0, 9.0,
			Vector3(4.6, 1.20, 0.70), 0.76, "crossfire_cover"),
		_arena_piece("west_flank_deck", "platform", -13.0, 5.0,
			Vector3(5.4, 0.72, 3.6), PI * 0.5, "elevated_flank"),
		_arena_piece("east_flank_deck", "platform", 13.0, -5.0,
			Vector3(5.4, 0.72, 3.6), -PI * 0.5, "elevated_flank"),
	]
	var huts: Array = [
		_arena_hut("northwest", -22.0, 20.0, SUPPLY_AMMO_REVOLVER,
			18, 1),
		_arena_hut("northeast", 22.0, 20.0, SUPPLY_AMMO_SHOTGUN,
			10, 1),
		_arena_hut("southwest", -22.0, -20.0, SUPPLY_AMMO_SMG,
			40, 2),
		_arena_hut("southeast", 22.0, -20.0, SUPPLY_AMMO_SNIPER,
			10, 2),
	]
	return {
		"id": ARENA_ID,
		"version": 2,
		"center": _arena_ground_point(0.0, 0.0),
		"radius": ARENA_RADIUS,
		"soft_boundary_radius": ARENA_SOFT_BOUNDARY_RADIUS,
		"gate_count": 4,
		"pieces": pieces,
		"supply_huts": huts,
		"cover_points": arena_cover_points(),
		"flank_points": arena_flank_points(),
		"spawn_points": arena_spawn_points(),
		"lanes": [
			{"id": "direct_duel", "width": 5.5,
				"points": [_arena_ground_point(0.0, 0.0),
					_arena_ground_point(12.0, -14.0)]},
			{"id": "west_flank", "width": 4.0,
				"points": [_arena_ground_point(-4.0, -1.0),
					_arena_ground_point(-15.5, 4.0),
					_arena_ground_point(-17.0, -9.0)]},
			{"id": "east_flank", "width": 4.0,
				"points": [_arena_ground_point(4.0, 1.0),
					_arena_ground_point(15.5, -4.0),
					_arena_ground_point(17.0, 9.0)]},
		],
	}


## Positions immediately beside authored cover. AI uses these as destinations,
## not the prop centres, so it can strafe and peek without walking into a wall.
func arena_cover_points() -> Array[Vector3]:
	var flat := [
		Vector2(-6.2, -5.0), Vector2(-3.4, -0.8),
		Vector2(3.4, 0.8), Vector2(6.2, 5.0),
		Vector2(-12.5, -1.0), Vector2(-8.8, 3.5),
		Vector2(8.8, -3.5), Vector2(12.5, 1.0),
		Vector2(-11.3, -10.6), Vector2(-6.8, -7.4),
		Vector2(6.8, 7.4), Vector2(11.3, 10.6),
	]
	var points: Array[Vector3] = []
	for point in flat:
		points.append(_arena_ground_point(point.x, point.y, 0.12))
	return points


## Longer tactical arcs through the two raised decks and open perimeter gates.
## These are deliberately offset from the origin-to-rival line at (12,-14).
func arena_flank_points() -> Array[Vector3]:
	var flat := [
		Vector2(-13.0, 5.0), Vector2(-17.0, 9.5),
		Vector2(-19.0, -5.5), Vector2(13.0, -5.0),
		Vector2(17.0, -9.5), Vector2(19.0, 5.5),
		Vector2(0.0, 23.0), Vector2(0.0, -23.0),
	]
	var points: Array[Vector3] = []
	for point in flat:
		points.append(_arena_ground_point(point.x, point.y, 0.14))
	return points


func arena_spawn_points() -> Array[Vector3]:
	return [
		_arena_ground_point(0.0, 0.0, 2.5),
		_arena_ground_point(12.0, -14.0, 2.2),
	]


## Chunk-scoped slice consumed by Chunk without putting arena cover in the
## generic `structures` array (which intentionally remains supply-hut-only).
func arena_chunk_layout(cx: int, cz: int) -> Dictionary:
	if not _is_origin_arena_chunk(cx, cz):
		return {"id": "", "pieces": [], "supply_huts": []}
	var blueprint := arena_layout()
	var pieces: Array = []
	var huts: Array = []
	for piece in blueprint.pieces:
		if _world_point_chunk(piece.pos) == Vector2i(cx, cz):
			pieces.append(piece)
	for hut in blueprint.supply_huts:
		if _world_point_chunk(hut.pos) == Vector2i(cx, cz):
			huts.append(hut)
	return {
		"id": ARENA_ID,
		"pieces": pieces,
		"supply_huts": huts,
		"soft_boundary_radius": ARENA_SOFT_BOUNDARY_RADIUS,
	}


func _arena_piece(piece_id: String, kind: String, x: float, z: float,
		size: Vector3, yaw: float, role: String) -> Dictionary:
	return {
		"id": piece_id,
		"kind": kind,
		"role": role,
		"pos": _arena_ground_point(x, z, 0.025),
		"yaw": yaw,
		"size": size,
		"clearance": maxf(size.x, size.z) * 0.5 + 0.65,
	}


func _arena_hut(label: String, x: float, z: float, ammo_kind: int,
		ammo_amount: int, bandages: int) -> Dictionary:
	var sample_radius := 3.15
	var platform_y := height(x, z)
	for offset in [
		Vector2(-sample_radius, -sample_radius),
		Vector2(sample_radius, -sample_radius),
		Vector2(-sample_radius, sample_radius),
		Vector2(sample_radius, sample_radius),
	]:
		platform_y = maxf(platform_y, height(x + offset.x, z + offset.y))
	var toward_center := Vector2(-x, -z).normalized()
	return {
		"kind": "supply_hut",
		"id": "s:arena#%s" % label,
		"pos": Vector3(x, platform_y + 0.04, z),
		# SupplyHut's open front points down its local -Z axis.
		"yaw": atan2(-toward_center.x, -toward_center.y),
		"clearance": SUPPLY_HUT_CLEARANCE,
		"ammo_kind": ammo_kind,
		"ammo_amount": ammo_amount,
		"bandages": bandages,
		# The northwest starter chest guarantees one discoverable normal pack;
		# every other chest remains useful after somebody claims it first.
		"normal_backpack": label == "northwest",
		"biome": Biome.RAINFOREST,
		"arena": true,
	}


func _arena_ground_point(x: float, z: float, lift := 0.0) -> Vector3:
	return Vector3(x, height(x, z) + lift, z)


func _world_point_chunk(point: Vector3) -> Vector2i:
	return Vector2i(floori(point.x / CHUNK), floori(point.z / CHUNK))


func _is_origin_arena_chunk(cx: int, cz: int) -> bool:
	return cx >= -1 and cx <= 0 and cz >= -1 and cz <= 0


func chunk_layout(cx: int, cz: int, include_decorations := true) -> Dictionary:
	var rng := _chunk_rng(cx, cz)
	if debug_world:
		return {"trees": [], "bananas": [], "rocks": [], "foliage": [],
			"structures": [], "arena_pieces": [], "arena_id": "",
			"airfield_hangars": [], "freeway_tunnels": [],
			"road_bridges": [], "biome": Biome.RAINFOREST}
	var trees: Array = []
	var bananas: Array = []
	var rocks: Array = []
	var foliage: Array = []
	var structures: Array = []
	var arena_chunk := arena_chunk_layout(cx, cz)
	var arena_pieces: Array = arena_chunk.get("pieces", [])
	var airfield_hangars: Array = airstrip_hangar_chunk_layout(cx, cz)
	var transport_features := transport_feature_chunk_layout(cx, cz)
	var freeway_tunnels: Array = transport_features.get("freeway_tunnels", [])
	var road_bridges: Array = transport_features.get("road_bridges", [])
	var tree_points: Array[Vector2] = []
	var x0 := cx * CHUNK
	var z0 := cz * CHUNK
	var center_biome := biome_at(x0 + CHUNK * 0.5, z0 + CHUNK * 0.5)
	# Structures use their own salted RNG so adding them does not reshuffle the
	# established tree/banana/rock layout. Compute them before trees even for the
	# horizon-only path: the same empty clearing must exist in canonical far trees
	# or a tree would visibly disappear when the gameplay chunk promotes.
	var supply_hut := _supply_hut_layout(cx, cz)
	if not supply_hut.is_empty():
		structures.append(supply_hut)
	structures.append_array(arena_chunk.get("supply_huts", []))
	var occupied_clearances := structures.duplicate()
	occupied_clearances.append_array(arena_pieces)
	occupied_clearances.append_array(airfield_hangars)
	occupied_clearances.append_array(freeway_tunnels)
	occupied_clearances.append_array(road_bridges)

	# hero grove trees that land inside this chunk
	if cx >= -1 and cx <= 0 and cz >= -1 and cz <= 0:
		var hi := 0
		for hp in _hero_positions():
			if hp.x >= x0 and hp.x < x0 + CHUNK and hp.z >= z0 and hp.z < z0 + CHUNK:
				var hr := _chunk_rng(cx, cz, 500 + hi)
				trees.append(_make_tree(hr, hp,
					19.0 + float(hi % 3) * 2.0, Biome.RAINFOREST,
					include_decorations))
				tree_points.append(Vector2(hp.x, hp.z))
			hi += 1

	# Dart-thrown trunks avoid visible plantation rows while retaining a small
	# minimum spacing. Individual samples use their local biome, so transition
	# zones contain a believable mix rather than changing at chunk seams.
	const TREE_CANDIDATES := 30
	for attempt in range(TREE_CANDIDATES):
		var px := x0 + rng.randf_range(1.1, CHUNK - 1.1)
		var pz := z0 + rng.randf_range(1.1, CHUNK - 1.1)
		var point := Vector2(px, pz)
		var inside_structure := _point_in_structure_clearance(point,
			occupied_clearances)
		var too_close := false
		for existing in tree_points:
			if point.distance_squared_to(existing) < 15.2:
				too_close = true
				break
		if too_close:
			continue
		var local_height := height(px, pz)
		var local_biome := biome_at_height(px, pz, local_height)
		if rng.randf() > _tree_density(local_biome):
			continue
		if point.length() < 26.0:
			continue  # keep the spawn meadow clear (hero grove owns it)
		if local_height < WATER_Y + 0.5:
			continue
		if local_height > TREE_LINE:
			continue  # bare rock and snow above the canopy line
		if point_on_airstrip(px, pz) or point_on_road(px, pz) \
				or point_in_rocket_launch_clearance(px, pz, 1.5):
			continue  # nothing grows through packed runway or road dirt
		tree_points.append(point)
		var generated_tree := _make_tree(rng, Vector3(px, 0, pz), 0.0,
			local_biome, include_decorations)
		if not inside_structure:
			trees.append(generated_tree)

	# The horizon renderer consumes this canonical tree placement too. Returning
	# before pickups/rocks/undergrowth keeps that visual-only generation lean,
	# while the shared tree RNG prevents silhouettes popping at the near handoff.
	if not include_decorations:
		return {"trees": trees, "bananas": [], "rocks": [], "foliage": [],
			"structures": structures, "arena_pieces": arena_pieces,
			"arena_id": str(arena_chunk.get("id", "")),
			"airfield_hangars": airfield_hangars,
			"freeway_tunnels": freeway_tunnels,
			"road_bridges": road_bridges, "biome": center_biome}

	# bananas: canopy-top rewards plus arcs floating between trees to guide swings
	var nb := rng.randi_range(2, 4)
	for i in range(nb):
		if trees.is_empty():
			break
		var t: Dictionary = trees[rng.randi_range(0, trees.size() - 1)]
		if i % 2 == 0 and not t.blobs.is_empty():
			var bl: Dictionary = t.blobs[0]
			bananas.append(t.pos + bl.off + Vector3(0, bl.r * 0.85 + 0.6, 0))
		else:
			var t2: Dictionary = trees[rng.randi_range(0, trees.size() - 1)]
			var mid: Vector3 = (t.pos + t2.pos) * 0.5
			bananas.append(Vector3(mid.x, height(mid.x, mid.z) + rng.randf_range(7.0, 13.0), mid.z))

	var rock_count := rng.randi_range(2, 5) \
		if center_biome in [Biome.HIGHLAND, Biome.ROCKY_MOUNTAINS] \
		else rng.randi_range(0, 2)
	# Slopes above the tree line trade canopy for scree: extra boulders make the
	# bare rock band read as mountainside instead of empty lawn.
	if height(x0 + CHUNK * 0.5, z0 + CHUNK * 0.5) > TREE_LINE * 0.75:
		rock_count += rng.randi_range(3, 6)
	for i in range(rock_count):
		var rx := x0 + rng.randf() * CHUNK
		var rz := z0 + rng.randf() * CHUNK
		if height(rx, rz) > WATER_Y + 0.4 and Vector2(rx, rz).length() > 12.0:
			var rock_radius := rng.randf_range(0.8, 1.9)
			if not _point_in_structure_clearance(Vector2(rx, rz),
					occupied_clearances) and not point_on_airstrip(rx, rz) \
					and not point_on_road(rx, rz) \
					and not point_in_rocket_launch_clearance(rx, rz, rock_radius):
				rocks.append({"pos": Vector3(rx, height(rx, rz), rz), "r": rock_radius})

	# Dense, collision-free understory is cheap to draw as three MultiMeshes.
	# Ferns dominate rainforest/highland floors, bamboo gets broad leaves, and
	# reed clusters continue a short distance into wetland shallows.
	var foliage_rng := _chunk_rng(cx, cz, 733)
	var foliage_goal := 82
	match center_biome:
		Biome.RAINFOREST:
			foliage_goal = 100
		Biome.BAMBOO_GROVE:
			foliage_goal = 88
		Biome.WETLAND:
			foliage_goal = 70
		Biome.HIGHLAND:
			foliage_goal = 82
		Biome.PLAINS:
			foliage_goal = 34
		Biome.GRASSLAND:
			foliage_goal = 68
		Biome.ROCKY_MOUNTAINS:
			foliage_goal = 0
		Biome.DESERT:
			foliage_goal = 3
		Biome.TUNDRA:
			foliage_goal = 4
		Biome.ICE, Biome.OCEAN, Biome.LAKE:
			foliage_goal = 0
	for i in range(foliage_goal):
		var fx := x0 + foliage_rng.randf() * CHUNK
		var fz := z0 + foliage_rng.randf() * CHUNK
		if Vector2(fx, fz).length() < 11.0:
			continue
		var inside_structure := _point_in_structure_clearance(
			Vector2(fx, fz), occupied_clearances)
		var fh := height(fx, fz)
		var fb := biome_at_height(fx, fz, fh)
		if fh < WATER_Y - 0.24 or (fh < WATER_Y + 0.08 \
				and fb != Biome.WETLAND):
			continue
		if fh > TREE_LINE:
			continue  # no undergrowth on the bare rock and snow bands
		if point_on_airstrip(fx, fz) or point_on_road(fx, fz) \
				or point_in_rocket_launch_clearance(fx, fz, 0.8):
			continue
		var kind := 0
		if fb == Biome.WETLAND:
			kind = 2 if foliage_rng.randf() < 0.72 else 0
		elif fb == Biome.BAMBOO_GROVE:
			kind = 1 if foliage_rng.randf() < 0.68 else 0
		elif fb in [Biome.PLAINS, Biome.GRASSLAND, Biome.TUNDRA]:
			kind = 1
		else:
			kind = 0 if foliage_rng.randf() < 0.62 else 1
		var size := foliage_rng.randf_range(0.72, 1.48)
		if kind == 2:
			size *= foliage_rng.randf_range(1.05, 1.55)
		var shade := foliage_rng.randf()
		var yaw := foliage_rng.randf() * TAU
		if not inside_structure:
			foliage.append({
				"pos": Vector3(fx, maxf(fh, WATER_Y - 0.03), fz),
				"kind": kind,
				"scale": size,
				"yaw": yaw,
				"color": biome_foliage_color(fb, shade).lightened(0.04),
			})

	return {"trees": trees, "bananas": bananas, "rocks": rocks,
		"foliage": foliage, "structures": structures,
		"arena_pieces": arena_pieces,
		"airfield_hangars": airfield_hangars,
		"freeway_tunnels": freeway_tunnels,
		"road_bridges": road_bridges,
		"arena_id": str(arena_chunk.get("id", "")), "biome": center_biome}


## Deterministic supply shelter for this chunk, or an empty dictionary. Huts are
## common enough to find while travelling but restricted to dry, buildable
## rainforest, bamboo and highland ground. The broad corner sample prevents a
## platform from bridging a ravine or clipping through a steep ridge.
func _supply_hut_layout(cx: int, cz: int) -> Dictionary:
	# Four authored, mirrored shelters serve the origin duel arena. Only these
	# four chunks opt out of the random roll; biome huts everywhere else retain
	# the exact same probability and salted RNG sequence.
	if _is_origin_arena_chunk(cx, cz):
		return {}
	var rng := _chunk_rng(cx, cz, 1201)
	var x0 := cx * CHUNK
	var z0 := cz * CHUNK
	var px := x0 + rng.randf_range(7.0, CHUNK - 7.0)
	var pz := z0 + rng.randf_range(7.0, CHUNK - 7.0)
	var center_height := height(px, pz)
	var local_biome := biome_at_height(px, pz, center_height)
	var chance := 0.0
	match local_biome:
		Biome.RAINFOREST:
			chance = 0.16
		Biome.BAMBOO_GROVE:
			chance = 0.23
		Biome.HIGHLAND:
			chance = 0.12
		Biome.PLAINS:
			chance = 0.10
		Biome.GRASSLAND:
			chance = 0.12
		Biome.DESERT:
			chance = 0.05
		Biome.TUNDRA:
			chance = 0.035
		_:
			return {}
	if rng.randf() > chance:
		return {}
	# Keep the authored spawn grove uncluttered and make every shelter a small
	# traversal discovery rather than something placed on the starting player.
	if Vector2(px, pz).length() < 34.0:
		return {}
	var sample_radius := 3.15
	var samples := [
		center_height,
		height(px - sample_radius, pz - sample_radius),
		height(px + sample_radius, pz - sample_radius),
		height(px - sample_radius, pz + sample_radius),
		height(px + sample_radius, pz + sample_radius),
	]
	var minimum_height: float = samples[0]
	var maximum_height: float = samples[0]
	for sample in samples:
		minimum_height = minf(minimum_height, float(sample))
		maximum_height = maxf(maximum_height, float(sample))
	if minimum_height < WATER_Y + 0.72 or maximum_height - minimum_height > 1.05:
		return {}
	if point_on_airstrip(px, pz) \
			or point_in_rocket_launch_clearance(px, pz,
				SUPPLY_HUT_CLEARANCE) \
			or point_in_road_clearance(px, pz, SUPPLY_HUT_CLEARANCE):
		return {}

	var ammo_kind := rng.randi_range(SUPPLY_AMMO_REVOLVER, SUPPLY_AMMO_SNIPER)
	var ammo_amount := 6
	match ammo_kind:
		SUPPLY_AMMO_REVOLVER:
			ammo_amount = 6 * rng.randi_range(1, 3)
		SUPPLY_AMMO_SHOTGUN:
			ammo_amount = rng.randi_range(6, 12)
		SUPPLY_AMMO_SMG:
			ammo_amount = 20 * rng.randi_range(1, 2)
		SUPPLY_AMMO_SNIPER:
			ammo_amount = 5 * rng.randi_range(1, 2)
	var bandage_count := 0
	if rng.randf() < 0.38:
		bandage_count = 2 if rng.randf() < 0.16 else 1
	var normal_backpack := rng.randf() < 0.12
	return {
		"kind": "supply_hut",
		"id": "s:%d,%d#0" % [cx, cz],
		"pos": Vector3(px, maximum_height + 0.04, pz),
		"yaw": rng.randf() * TAU,
		"clearance": SUPPLY_HUT_CLEARANCE,
		"ammo_kind": ammo_kind,
		"ammo_amount": ammo_amount,
		"bandages": bandage_count,
		"normal_backpack": normal_backpack,
		"biome": local_biome,
	}


func _point_in_structure_clearance(point: Vector2, structures: Array) -> bool:
	for structure in structures:
		var structure_pos: Vector3 = structure.get("pos", Vector3.ZERO)
		var radius := float(structure.get("clearance", SUPPLY_HUT_CLEARANCE))
		if point.distance_squared_to(Vector2(structure_pos.x, structure_pos.z)) \
				< radius * radius:
			return true
	return false


func _tree_density(biome: int) -> float:
	match biome:
		Biome.RAINFOREST:
			return 0.95
		Biome.BAMBOO_GROVE:
			return 0.90
		Biome.WETLAND:
			return 0.72
		Biome.HIGHLAND:
			return 0.82
		Biome.PLAINS:
			return 0.20
		Biome.GRASSLAND:
			return 0.32
		Biome.ROCKY_MOUNTAINS:
			return 0.0
		Biome.DESERT:
			return 0.025
		Biome.TUNDRA:
			return 0.025
		Biome.ICE, Biome.OCEAN, Biome.LAKE:
			return 0.0
	return 0.8


func biome_foliage_color(biome: int, shade: float) -> Color:
	# Deeper, higher-saturation canopy tones: real broadleaf crowns sit closer
	# to 25-45% value than the old minty 40-70% range.
	match biome:
		Biome.BAMBOO_GROVE:
			return Color.from_hsv(0.20 + shade * 0.055, 0.68,
				0.23 + shade * 0.16)
		Biome.WETLAND:
			return Color.from_hsv(0.30 + shade * 0.055, 0.56,
				0.185 + shade * 0.14)
		Biome.HIGHLAND:
			return Color.from_hsv(0.37 + shade * 0.055, 0.54,
				0.185 + shade * 0.15)
		Biome.PLAINS:
			return Color.from_hsv(0.17 + shade * 0.025, 0.58,
				0.30 + shade * 0.17)
		Biome.GRASSLAND:
			return Color.from_hsv(0.23 + shade * 0.035, 0.68,
				0.26 + shade * 0.18)
		Biome.ROCKY_MOUNTAINS:
			return Color.from_hsv(0.31, 0.26, 0.24 + shade * 0.18)
		Biome.DESERT:
			return Color.from_hsv(0.12, 0.48, 0.40 + shade * 0.15)
		Biome.TUNDRA:
			return Color.from_hsv(0.24, 0.26, 0.29 + shade * 0.14)
		Biome.ICE:
			return Color(0.77, 0.85, 0.88)
	return Color.from_hsv(0.27 + shade * 0.07, 0.70,
		0.205 + shade * 0.175)


## Deterministic vehicle spawn definitions for one chunk. Curated machines sit
## at the origin motor pool, inside the six airfield hangars, and at the nearest lake
## dock; rare wilderness finds use their own RNG salt so adding them never
## reshuffles any existing layout. World retains curated/driven IDs, while an
## untouched wilderness find retires with its streamed area and can respawn at
## this same deterministic definition when the player returns.
## Kind ints match Vehicle.Kind (avoiding a script dependency from Gen).
const VEHICLE_BIKE := 0
const VEHICLE_JEEP := 1
const VEHICLE_BOAT := 2
const VEHICLE_JET := 3
# Network ingress may resolve an infinite-world vehicle lazily from its stable
# chunk id. Keep the lookup inside the same world envelope enforced by Net so a
# hostile id cannot turn one seat request into unbounded noise-field work.
const VEHICLE_MAX_CHUNK_COORDINATE := 20834

func vehicle_layout(cx: int, cz: int) -> Array:
	if debug_world:
		return []
	var defs: Array = []
	# Origin motor pool: a dual-sport and a jeep parked just east of the duel
	# arena's graded rim, noses pointed out into the jungle.
	if cx == 0 and cz == 0:
		defs.append({"kind": VEHICLE_BIKE, "id": "v:pool#bike",
			"pos": Vector3(41.5, height(41.5, 6.0), 6.0),
			"yaw": atan2(1.0, 0.15)})
		defs.append({"kind": VEHICLE_JEEP, "id": "v:pool#jeep",
			"pos": Vector3(44.0, height(44.0, 2.0), 2.0),
			"yaw": atan2(1.0, -0.1)})
	if airstrip_valid:
		for hangar in airstrip_hangar_layout():
			var jet_pos: Vector3 = hangar.jet_pos
			if floori(jet_pos.x / CHUNK) == cx \
					and floori(jet_pos.z / CHUNK) == cz:
				defs.append({"kind": VEHICLE_JET, "id": hangar.jet_id,
					"pos": jet_pos, "yaw": hangar.jet_yaw})
	if boat_dock_valid:
		if floori(boat_dock_pos.x / CHUNK) == cx \
				and floori(boat_dock_pos.z / CHUNK) == cz:
			defs.append({"kind": VEHICLE_BOAT, "id": "v:dock#boat",
				"pos": boat_dock_pos, "yaw": boat_dock_yaw})
	# Wilderness finds: about one machine per twenty jungle chunks, on ground
	# flat and dry enough to have plausibly been ridden there.
	var rng := _chunk_rng(cx, cz, 1601)
	var px := float(cx) * CHUNK + rng.randf_range(6.0, CHUNK - 6.0)
	var pz := float(cz) * CHUNK + rng.randf_range(6.0, CHUNK - 6.0)
	var kind_roll := rng.randf()
	var yaw := rng.randf() * TAU
	if Vector2(px, pz).length() < 150.0 or point_on_airstrip(px, pz) \
			or point_in_rocket_launch_clearance(px, pz, 4.0) \
			or point_on_road(px, pz):
		return defs
	var h := height(px, pz)
	var biome := biome_at_height(px, pz, h)
	if kind_roll < 0.016 and biome != Biome.WETLAND:
		var flat := true
		for offset in [Vector2(-2.4, -2.4), Vector2(2.4, -2.4),
				Vector2(-2.4, 2.4), Vector2(2.4, 2.4)]:
			var sample := height(px + offset.x, pz + offset.y)
			if absf(sample - h) > 1.1 or sample < WATER_Y + 0.7:
				flat = false
		if flat and h > WATER_Y + 0.7:
			var kind := VEHICLE_BIKE if kind_roll < 0.011 else VEHICLE_JEEP
			defs.append({"kind": kind, "id": "v:%d,%d#0" % [cx, cz],
				"pos": Vector3(px, h, pz), "yaw": yaw})
	elif kind_roll < 0.048 and biome == Biome.WETLAND \
			and lake_influence(px, pz) > 0.55 and h < WATER_Y - 0.3:
		defs.append({"kind": VEHICLE_BOAT, "id": "v:%d,%d#0" % [cx, cz],
			"pos": Vector3(px, WATER_Y, pz), "yaw": yaw})
	return defs


## Resolve one stable generated vehicle id back to the authoritative definition
## for the current seed. This is deliberately narrower than `vehicle_layout`:
## curated ids are matched explicitly, while wilderness ids must encode their
## exact canonical owning chunk and must actually win that chunk's seeded roll.
## Admin-delivered and test-only ids are not generated world definitions.
func vehicle_definition_by_id(vehicle_id: String) -> Dictionary:
	if debug_world or vehicle_id.is_empty():
		return {}
	match vehicle_id:
		"v:pool#bike":
			return {"kind": VEHICLE_BIKE, "id": vehicle_id,
				"pos": Vector3(41.5, height(41.5, 6.0), 6.0),
				"yaw": atan2(1.0, 0.15)}
		"v:pool#jeep":
			return {"kind": VEHICLE_JEEP, "id": vehicle_id,
				"pos": Vector3(44.0, height(44.0, 2.0), 2.0),
				"yaw": atan2(1.0, -0.1)}
		"v:dock#boat":
			if boat_dock_valid:
				return {"kind": VEHICLE_BOAT, "id": vehicle_id,
					"pos": boat_dock_pos, "yaw": boat_dock_yaw}
			return {}
	if vehicle_id.begins_with("v:strip#jet-"):
		for hangar in airstrip_hangar_layout():
			if str(hangar.jet_id) == vehicle_id:
				return {"kind": VEHICLE_JET, "id": vehicle_id,
					"pos": hangar.jet_pos, "yaw": hangar.jet_yaw}
		return {}
	if not vehicle_id.begins_with("v:") or not vehicle_id.ends_with("#0"):
		return {}
	var separator := vehicle_id.find("#", 2)
	if separator < 0:
		return {}
	var coordinate_text := vehicle_id.substr(2, separator - 2)
	var coordinates := coordinate_text.split(",", false)
	if coordinates.size() != 2 or not coordinates[0].is_valid_int() \
			or not coordinates[1].is_valid_int():
		return {}
	var cx := int(coordinates[0])
	var cz := int(coordinates[1])
	if coordinate_text != "%d,%d" % [cx, cz] \
			or cx < -VEHICLE_MAX_CHUNK_COORDINATE \
			or cx > VEHICLE_MAX_CHUNK_COORDINATE \
			or cz < -VEHICLE_MAX_CHUNK_COORDINATE \
			or cz > VEHICLE_MAX_CHUNK_COORDINATE:
		return {}
	for definition in vehicle_layout(cx, cz):
		if str(definition.get("id", "")) == vehicle_id:
			return definition.duplicate(true)
	return {}


## Decorative skyline-tier tree crowns for one 48 m chunk: a deliberately
## cheap, independent deterministic draw (its own RNG salt, ~8 noise samples)
## rather than the canonical chunk layout. Beyond the 672 m horizon ring,
## per-tree correspondence with the near jungle is invisible, but enumerating
## 256 canonical layouts per 768 m skyline sector was measurably expensive.
## Every RNG draw below is unconditional so the sequence stays deterministic
## regardless of which candidates the terrain gates reject.
func skyline_tree_layout(cx: int, cz: int) -> Array:
	if debug_world:
		return []
	var rng := _chunk_rng(cx, cz, 1801)
	var trees: Array = []
	var x0 := float(cx) * CHUNK
	var z0 := float(cz) * CHUNK
	for attempt in range(8):
		var px := x0 + rng.randf_range(1.5, CHUNK - 1.5)
		var pz := z0 + rng.randf_range(1.5, CHUNK - 1.5)
		var shade := rng.randf()
		var trunk_h := rng.randf_range(11.0, 24.0)
		var crown_r := rng.randf_range(3.4, 5.6)
		var density_roll := rng.randf()
		var h := height(px, pz)
		if h < WATER_Y + 0.6 or h > TREE_LINE:
			continue
		if point_on_airstrip(px, pz) or point_on_road(px, pz) \
				or point_in_rocket_launch_clearance(px, pz, 1.5):
			continue
		var biome := biome_at_height(px, pz, h)
		if density_roll > _tree_density(biome) * 0.82:
			continue
		trees.append({
			"pos": Vector3(px, h, pz),
			"trunk_h": trunk_h,
			"crown_r": crown_r,
			"color": biome_foliage_color(biome, shade),
		})
	return trees


## How completely the jungle canopy covers the ground at this point (0..1).
## Used by the far LOD tiers to tint terrain toward foliage color where trees
## grow, so forests still read as forests kilometres past the last instanced
## tree silhouette. Purely a function of existing deterministic fields.
func canopy_cover(h: float, x: float, z: float) -> float:
	if debug_world:
		return 0.0
	if point_on_road(x, z) or point_on_airstrip(x, z) \
			or point_in_rocket_launch_clearance(x, z):
		return 0.0
	if h < WATER_Y + 0.5 or h > TREE_LINE:
		return 0.0
	var shore := smoothstep(WATER_Y + 0.5, WATER_Y + 1.6, h)
	var tree_line_fade := 1.0 - smoothstep(TREE_LINE - 5.0, TREE_LINE, h)
	var density := _tree_density(biome_at_height(x, z, h))
	return shore * tree_line_fade * density


## Representative mid-shade canopy color for far-tier ground tinting, with a
## little spatial variation from the shared color-jitter noise field.
func canopy_color(x: float, z: float, h: float) -> Color:
	var shade := 0.32 + clampf(_n_color.get_noise_2d(x * 0.5, z * 0.5)
		* 0.5 + 0.5, 0.0, 1.0) * 0.30
	return biome_foliage_color(biome_at_height(x, z, h), shade)


## Sub-pixel tree crowns should not become millions of literal instances at the
## 6 km stratos tier. Lift the shared terrain lattice by a few deterministic
## metres instead: from aircraft altitude the resulting rough silhouette and
## lighting read as one continuous forest canopy all the way to the far plane.
## `cover` is supplied by canopy_cover() so the expensive terrain gates are not
## evaluated twice for every stratos vertex.
func stratos_canopy_relief(cover: float, x: float, z: float) -> float:
	if cover <= 0.0:
		return 0.0
	# _n_color normally varies tree-to-tree. Sampling it at a much lower input
	# scale produces coherent 150-250 m crown clusters that match the 192 m mesh.
	var cluster := clampf(_n_color.get_noise_2d(x * 0.05, z * 0.05)
		* 0.5 + 0.5, 0.0, 1.0)
	return cover * lerpf(STRATOS_CANOPY_RELIEF_MIN,
		STRATOS_CANOPY_RELIEF_MAX, cluster)


func _make_tree(rng: RandomNumberGenerator, p: Vector3, force_h: float,
		biome_override: int = -1, include_details := true) -> Dictionary:
	var g := height(p.x, p.z)
	var biome := biome_override if biome_override >= 0 else biome_at(p.x, p.z)
	var trunk_h := force_h
	var trunk_r := 0.7
	var blob_count := 3
	var blob_min := 2.8
	var blob_max := 4.6
	var branch_count := 2
	var vine_min := 2
	var vine_max := 4
	if force_h <= 0.0:
		match biome:
			Biome.BAMBOO_GROVE:
				trunk_h = rng.randf_range(13.0, 21.0)
				trunk_r = rng.randf_range(0.20, 0.38)
				blob_count = rng.randi_range(1, 2)
				blob_min = 1.45
				blob_max = 2.55
				branch_count = rng.randi_range(0, 1)
				vine_min = 0
				vine_max = 1
			Biome.WETLAND:
				trunk_h = rng.randf_range(11.0, 19.0)
				trunk_r = rng.randf_range(0.48, 0.86)
				blob_count = rng.randi_range(2, 3)
				blob_min = 2.5
				blob_max = 4.1
				branch_count = rng.randi_range(2, 3)
				vine_min = 3
				vine_max = 5
			Biome.HIGHLAND:
				trunk_h = rng.randf_range(10.0, 18.0)
				trunk_r = rng.randf_range(0.68, 1.18)
				blob_count = rng.randi_range(2, 3)
				blob_min = 2.35
				blob_max = 3.9
				branch_count = rng.randi_range(2, 3)
				vine_min = 1
				vine_max = 3
			Biome.PLAINS, Biome.GRASSLAND:
				trunk_h = rng.randf_range(7.0, 14.0)
				trunk_r = rng.randf_range(0.38, 0.76)
				blob_count = rng.randi_range(2, 3)
				blob_min = 2.1
				blob_max = 3.8
				branch_count = rng.randi_range(1, 3)
				vine_min = 0
				vine_max = 1
			Biome.ROCKY_MOUNTAINS, Biome.TUNDRA:
				trunk_h = rng.randf_range(5.5, 11.0)
				trunk_r = rng.randf_range(0.30, 0.62)
				blob_count = rng.randi_range(1, 2)
				blob_min = 1.3
				blob_max = 2.7
				branch_count = rng.randi_range(1, 2)
				vine_min = 0
				vine_max = 0
			Biome.DESERT:
				trunk_h = rng.randf_range(4.5, 8.0)
				trunk_r = rng.randf_range(0.28, 0.52)
				blob_count = 1
				blob_min = 1.2
				blob_max = 2.1
				branch_count = rng.randi_range(1, 2)
				vine_min = 0
				vine_max = 0
			_:
				trunk_h = rng.randf_range(15.0, 27.0)
				trunk_r = rng.randf_range(0.58, 1.08)
				blob_count = rng.randi_range(3, 4)
				branch_count = rng.randi_range(2, 3)
				vine_min = 3
				vine_max = 5
	else:
		trunk_r = rng.randf_range(0.65, 1.0)
		blob_count = rng.randi_range(3, 4)
		branch_count = rng.randi_range(2, 3)
	var base := Vector3(p.x, g, p.z)

	var blobs: Array = []
	for i in range(blob_count):
		var shade := rng.randf()
		var flower_chance := 0.12 if biome == Biome.RAINFOREST else 0.045
		var flower := rng.randf() < flower_chance
		blobs.append({
			"off": Vector3(rng.randf_range(-1.8, 1.8),
				trunk_h - 1.0 + float(i) * rng.randf_range(1.0, 2.0),
				rng.randf_range(-1.8, 1.8)),
			"r": rng.randf_range(blob_min, blob_max),
			"flower": flower,
			"shade": shade,
			"color": Color(0.74, 0.40, 0.52) if flower \
				else biome_foliage_color(biome, shade),
		})

	var branches: Array = []
	for i in range(branch_count):
		var a := rng.randf() * TAU
		var branch_len := rng.randf_range(2.2, 4.8)
		var branch_h := trunk_h * rng.randf_range(0.45, 0.7)
		var branch_r := rng.randf_range(0.13, 0.27)
		if include_details:
			branches.append({
				"dir": Vector3(cos(a), 0, sin(a)),
				"len": branch_len,
				"h": branch_h,
				"r": branch_r,
			})

	var vlist: Array = []
	var vine_count := rng.randi_range(vine_min, vine_max)
	if not include_details:
		# Preserve every RNG draw that the canonical near tree consumes so later
		# silhouettes remain exact, but skip branch/vine dictionaries and discarded
		# vine-anchor height samples in the visual-only horizon path.
		for i in range(vine_count):
			if i >= branch_count:
				rng.randi_range(0, blobs.size() - 1)
				rng.randf()
			if i == 0:
				rng.randf_range(2.3, 2.9)
			else:
				rng.randf_range(2.3, 5.0)
	else:
		for i in range(vine_count):
			var anchor: Vector3
			if i < branches.size():
				var b: Dictionary = branches[i]
				anchor = base + b.dir * (b.len + trunk_r * 0.6) \
					+ Vector3(0, b.h, 0)
			else:
				var bl: Dictionary = blobs[rng.randi_range(0, blobs.size() - 1)]
				var a2 := rng.randf() * TAU
				anchor = base + bl.off + Vector3(cos(a2) * bl.r * 0.8,
					-bl.r * 0.2, sin(a2) * bl.r * 0.8)
			var lift := rng.randf_range(2.3, 2.9) if i == 0 \
				else rng.randf_range(2.3, 5.0)
			var vlen := anchor.y - (height(anchor.x, anchor.z) + lift)
			if vlen < 3.0:
				continue
			vlist.append({"anchor": anchor, "len": vlen})

	return {"pos": base, "trunk_h": trunk_h, "trunk_r": trunk_r,
		"blobs": blobs, "branches": branches, "vines": vlist,
		"biome": biome}


## Cheap silhouettes for the coarse horizon tier. They deliberately omit
## branches, vines, collectibles and collision data; thousands can therefore
## share two MultiMeshes while retaining the local biome's height and colour.
func distant_tree_layout(cx: int, cz: int) -> Array:
	var trees: Array = []
	for tree in chunk_layout(cx, cz, false).trees:
		var distant_blobs: Array = []
		for blob in tree.blobs:
			distant_blobs.append({
				"pos": tree.pos + blob.off,
				"r": blob.r,
				"color": blob.color,
			})
		trees.append({
			"pos": tree.pos,
			"trunk_h": tree.trunk_h,
			"trunk_r": tree.trunk_r,
			"blobs": distant_blobs,
		})
	return trees


# ---- vine registry ---------------------------------------------------------

func register_chunk_vines(key: Vector2i, layout: Dictionary) -> void:
	var ids: Array = []
	var i := 0
	for t in layout.trees:
		for v in t.vines:
			var id := "%d,%d#%d" % [key.x, key.y, i]
			vines[id] = {"anchor": v.anchor, "len": v.len, "chunk": key,
				"hidden": false, "simulated": false, "points": PackedVector3Array()}
			ids.append(id)
			i += 1
	_vines_by_chunk[key] = ids


func unregister_chunk_vines(key: Vector2i) -> void:
	if _vines_by_chunk.has(key):
		for id in _vines_by_chunk[key]:
			vines.erase(id)
		_vines_by_chunk.erase(key)


func add_debug_vine(anchor: Vector3, vlen: float) -> String:
	_debug_count += 1
	var id := "dbg#%d" % _debug_count
	var key := Vector2i(floori(anchor.x / CHUNK), floori(anchor.z / CHUNK))
	vines[id] = {"anchor": anchor, "len": vlen, "chunk": key,
		"hidden": false, "simulated": false, "points": PackedVector3Array()}
	if not _vines_by_chunk.has(key):
		_vines_by_chunk[key] = []
	_vines_by_chunk[key].append(id)
	return id


func set_vine_hidden(id: String, hidden: bool) -> void:
	if not vines.has(id):
		return
	vines[id].hidden = hidden
	if hidden:
		vines[id].simulated = false
		vines[id].points = PackedVector3Array()
	vine_visual_changed.emit(vines[id].chunk)


func start_vine_simulation(id: String, points: PackedVector3Array) -> void:
	if not vines.has(id):
		return
	vines[id].hidden = false
	vines[id].simulated = true
	vines[id].points = points
	vine_visual_changed.emit(vines[id].chunk)


func update_vine_simulation(id: String, points: PackedVector3Array) -> void:
	if vines.has(id) and bool(vines[id].get("simulated", false)):
		vines[id].points = points


func stop_vine_simulation(id: String) -> void:
	if not vines.has(id):
		return
	vines[id].simulated = false
	vines[id].points = PackedVector3Array()
	vine_visual_changed.emit(vines[id].chunk)


## Best grabbable vine for the crosshair ray (origin + dir), hand at `hand`.
## Primary: the strand sample nearest the crosshair inside the aim cone.
## Fallback: any strand within arm's reach of the hand (blind instinct grab).
## Returns {} or {id, anchor, len, point}.
func best_vine(origin: Vector3, dir: Vector3, hand: Vector3, exclude: Dictionary, now_s: float) -> Dictionary:
	var cc := Vector2i(floori(hand.x / CHUNK), floori(hand.z / CHUNK))
	var best := {}
	var best_score := INF
	var fall := {}
	var fall_d := REACH
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var key := cc + Vector2i(dx, dz)
			if not _vines_by_chunk.has(key):
				continue
			for id in _vines_by_chunk[key]:
				var v: Dictionary = vines[id]
				if v.hidden:
					continue
				if exclude.has(id) and now_s < float(exclude[id]):
					continue
				var anchor: Vector3 = v.anchor
				if anchor.y < hand.y + 0.5:
					continue
				var vl := float(v.len)
				var samples := PackedVector3Array()
				if bool(v.get("simulated", false)) and (v.get("points", PackedVector3Array()) as PackedVector3Array).size() >= 2:
					samples = v.points
				else:
					var ns := clampi(int(vl / 1.2) + 1, 2, 14)
					for si in range(ns + 1):
						samples.append(anchor + Vector3.DOWN * (vl * float(si) / float(ns)))
				for si in range(samples.size()):
					var depth := vl * float(si) / float(samples.size() - 1)
					var p: Vector3 = samples[si]
					var hd := hand.distance_to(p)
					if hd < fall_d:
						fall_d = hd
						fall = {"id": id, "anchor": anchor, "len": vl, "point": p, "depth": depth}
					# reach is measured from the HAND (realistic arm range);
					# aim direction is measured from the crosshair ray
					var reach_d := hand.distance_to(p)
					if reach_d > TARGET_DIST or reach_d < 0.3:
						continue
					var to_p := p - origin
					var d := to_p.length()
					if d < 0.3:
						continue
					var a := dir.dot(to_p / d)
					if a < TARGET_COS:
						continue
					var score := (1.0 - a) * 100.0 + reach_d * 0.05
					if score < best_score:
						best_score = score
						best = {"id": id, "anchor": anchor, "len": vl, "point": p, "depth": depth}
	return best if not best.is_empty() else fall
