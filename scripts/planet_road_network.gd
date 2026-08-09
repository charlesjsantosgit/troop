class_name PlanetRoadNetwork
extends RefCounted
## Constant-time, planet-wide road lattice.
##
## The network is analytic rather than stored as millions of nodes. Streaming,
## terrain, the minimap and multiplayer can query the same road at any point,
## while `segments_in_rect` materialises only the few lines crossing one local
## streamed rectangle. Spacings divide the planet circumference and its 180°
## pole shift exactly, so roads join at longitude seams and pole reflections.

const PlanetTerrainScript = preload("res://scripts/planet_terrain.gd")

const HIGHWAY_SPACING := 3072.0
const REGIONAL_SPACING := 768.0
const HIGHWAY_HALF_WIDTH := 7.2
const REGIONAL_HALF_WIDTH := 4.8
const SHOULDER := 14.0
const MAX_SEGMENTS_PER_QUERY := 128

var seed := 1337
var _profile := FastNoiseLite.new()


func setup(seed_value: int) -> void:
	seed = seed_value
	_profile.seed = seed_value + 90121
	_profile.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_profile.frequency = 0.000032
	_profile.fractal_type = FastNoiseLite.FRACTAL_FBM
	_profile.fractal_octaves = 3
	_profile.fractal_lacunarity = 2.0
	_profile.fractal_gain = 0.46


## Geometry-only closest road. Gen applies the continuous land/lake/mountain
## eligibility mask, avoiding recursion when the road grades the height field.
func surface_sample(world_xz: Vector2) -> Dictionary:
	# Inline the four axis probes. This is called once per streamed terrain
	# vertex, and the old helper allocated four throwaway dictionaries.
	var regional_x_index := roundi(world_xz.x / REGIONAL_SPACING)
	var regional_z_index := roundi(world_xz.y / REGIONAL_SPACING)
	var regional_x_distance := absf(world_xz.x
		- float(regional_x_index) * REGIONAL_SPACING)
	var regional_z_distance := absf(world_xz.y
		- float(regional_z_index) * REGIONAL_SPACING)
	var axis := "longitude"
	var distance := regional_x_distance
	var line_index := regional_x_index
	if regional_z_distance < distance:
		axis = "latitude"
		distance = regional_z_distance
		line_index = regional_z_index
	var highway_x_index := roundi(world_xz.x / HIGHWAY_SPACING)
	var highway_z_index := roundi(world_xz.y / HIGHWAY_SPACING)
	var highway_x_distance := absf(world_xz.x
		- float(highway_x_index) * HIGHWAY_SPACING)
	var highway_z_distance := absf(world_xz.y
		- float(highway_z_index) * HIGHWAY_SPACING)
	var highway_axis := "longitude"
	var highway_distance := highway_x_distance
	var highway_index := highway_x_index
	if highway_z_distance < highway_distance:
		highway_axis = "latitude"
		highway_distance = highway_z_distance
		highway_index = highway_z_index
	var tier := "regional"
	var half_width := REGIONAL_HALF_WIDTH
	if highway_distance - HIGHWAY_HALF_WIDTH < distance - REGIONAL_HALF_WIDTH:
		tier = "highway"
		axis = highway_axis
		distance = highway_distance
		line_index = highway_index
		half_width = HIGHWAY_HALF_WIDTH
	var road_id := "%s:%s:%d" % [tier, axis, line_index]
	var spacing := HIGHWAY_SPACING if tier == "highway" \
		else REGIONAL_SPACING
	var center_point := Vector2(float(line_index) * spacing, world_xz.y) \
		if axis == "longitude" else Vector2(world_xz.x,
			float(line_index) * spacing)
	return {
		"distance": distance,
		"half_width": half_width,
		"grade": 1.0 - smoothstep(half_width, half_width + SHOULDER,
			distance),
		"route_id": road_id,
		"tier": tier,
		"axis": axis,
		"line_index": line_index,
		"center_point": center_point,
		# Geometry queries sit in the terrain vertex hot path. Gen supplies the
		# locally terrain-following, grade-audited elevation only when the point is
		# actually close enough to a road, so do not spend a three-octave spherical
		# noise sample for the overwhelming majority of off-road vertices.
		"elevation": 0.0,
	}


## One shared very-low-frequency profile makes intersecting roads meet at the
## exact same elevation. Its measured grade remains far below the 8.5% cap.
func profile_elevation(world_xz: Vector2) -> float:
	var radius := PlanetTerrainScript.RADIUS
	var longitude := world_xz.x / radius
	var latitude := world_xz.y / radius
	var latitude_cosine := cos(latitude)
	var point := Vector3(latitude_cosine * cos(longitude), sin(latitude),
		latitude_cosine * sin(longitude)) * radius
	var profile_noise := _profile.get_noise_3d(point.x, point.y, point.z)
	return 54.0 + profile_noise * 125.0


## Bounded local representation for road meshes, map overlays or navigation.
## Rectangles larger than the budget simply return the nearest first 128 lines;
## callers can split a large world-map request into tiles.
func segments_in_rect(rect: Rect2, max_segments := MAX_SEGMENTS_PER_QUERY) -> Array:
	var budget := clampi(max_segments, 0, MAX_SEGMENTS_PER_QUERY)
	var segments: Array = []
	if budget == 0 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return segments
	for tier_data in [
		{"tier": "highway", "spacing": HIGHWAY_SPACING,
			"width": HIGHWAY_HALF_WIDTH},
		{"tier": "regional", "spacing": REGIONAL_SPACING,
			"width": REGIONAL_HALF_WIDTH},
	]:
		var spacing := float(tier_data.spacing)
		var first_x := ceili(rect.position.x / spacing)
		var last_x := floori(rect.end.x / spacing)
		for index in range(first_x, last_x + 1):
			if segments.size() >= budget:
				return segments
			segments.append({
				"id": "%s:longitude:%d" % [tier_data.tier, index],
				"tier": tier_data.tier,
				"half_width": tier_data.width,
				"a": Vector2(float(index) * spacing, rect.position.y),
				"b": Vector2(float(index) * spacing, rect.end.y),
			})
		var first_z := ceili(rect.position.y / spacing)
		var last_z := floori(rect.end.y / spacing)
		for index in range(first_z, last_z + 1):
			if segments.size() >= budget:
				return segments
			segments.append({
				"id": "%s:latitude:%d" % [tier_data.tier, index],
				"tier": tier_data.tier,
				"half_width": tier_data.width,
				"a": Vector2(rect.position.x, float(index) * spacing),
				"b": Vector2(rect.end.x, float(index) * spacing),
			})
	return segments
