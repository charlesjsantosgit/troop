extends Node
## Quantitative gate for the Earth-scale Pangaea terrain and curved roads.
##
## Sampling is deliberately globe-relative. Fixed kilometre grids around spawn
## cannot exercise a 40,000 km planet, its climate bands, or its analytic roads.

const PlanetRoadNetworkScript = preload("res://scripts/planet_road_network.gd")

const EARTH_EQUATORIAL_CIRCUMFERENCE_M := 40_075_017.0
const GLOBAL_LONGITUDE_SAMPLES := 96
const GLOBAL_LATITUDE_SAMPLES := 49
const PANGAEA_LONGITUDE_SAMPLES := 81
const PANGAEA_LATITUDE_SAMPLES := 61

var passed := 0
var total := 0


func _check(ok: bool, label: String, detail := "") -> void:
	total += 1
	if ok:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] %s%s" % [label,
			(" :: " + detail) if not detail.is_empty() else ""])


func run() -> void:
	print("PLANETTEST begin seed=%d circumference=%.0fm" % [Gen.world_seed,
		Gen.PLANET_CIRCUMFERENCE])
	var started_ms := Time.get_ticks_msec()
	_test_spherical_topology()
	_test_pangaea_poles_and_distribution()
	_test_summit_and_mountains()
	_test_gradual_uplands()
	_test_planet_roads()
	_test_seed_robustness()
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	print("PLANETTEST_STATS assertions=%d elapsed_ms=%d" % [total, elapsed_ms])
	print("PLANETTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)


func _test_spherical_topology() -> void:
	var earth_error := absf(Gen.PLANET_CIRCUMFERENCE
		- EARTH_EQUATORIAL_CIRCUMFERENCE_M)
	_check(earth_error <= 3000.0
		and absf(Gen.PLANET_RADIUS * TAU - Gen.PLANET_CIRCUMFERENCE) < 0.01,
		"planet circumference and radius are Earth scale",
		"circumference=%.0fm earth_error=%.0fm" % [
			Gen.PLANET_CIRCUMFERENCE, earth_error])

	# Terrain vertices live on a three-metre lattice. A multiple of 48 m is also
	# exactly representable after adding this intentionally lattice-divisible
	# circumference, so this measures topology rather than float32 ULP loss from
	# constructing an arbitrary 40-million-metre Vector2 image.
	var probe := Vector2(12_336.0, 6_768.0)
	var longitude_image := probe + Vector2(Gen.PLANET_CIRCUMFERENCE, 0.0)
	var canonical_a := Gen.canonical_planet_xz(probe)
	var canonical_b := Gen.canonical_planet_xz(longitude_image)
	var height_delta := absf(Gen.height(probe.x, probe.y)
		- Gen.height(longitude_image.x, longitude_image.y))
	_check(canonical_a == canonical_b and height_delta < 0.0001
		and Gen.biome_at(probe.x, probe.y)
			== Gen.biome_at(longitude_image.x, longitude_image.y),
		"longitude seam is exact on the shared terrain lattice",
		"canonical_delta=%.6fm height_delta=%.6fm" % [
			canonical_a.distance_to(canonical_b), height_delta])

	var beyond_north := Vector2(1440.0, Gen.PLANET_POLE_DISTANCE + 720.0)
	var north_sample := Gen.canonical_world_sample(beyond_north)
	var expected_north := Gen.canonical_planet_xz(Vector2(
		1440.0 + Gen.PLANET_HALF_CIRCUMFERENCE,
		Gen.PLANET_POLE_DISTANCE - 720.0))
	var pole_xz: Vector2 = north_sample.xz
	_check(pole_xz == expected_north
		and int(north_sample.pole_crossings) == 1
		and absf(float(north_sample.yaw_delta) - PI) < 0.0001
		and absf(Gen.height(beyond_north.x, beyond_north.y)
			- Gen.height(expected_north.x, expected_north.y)) < 0.0001
		and Gen.biome_at(beyond_north.x, beyond_north.y)
			== Gen.biome_at(expected_north.x, expected_north.y)
		and Gen.planet_sphere_direction(beyond_north).distance_to(
			Gen.planet_sphere_direction(expected_north)) < 0.0001,
		"pole crossing exactly reflects latitude, advances longitude and adds PI yaw")

	var reference := canonical_a + Vector2(Gen.PLANET_CIRCUMFERENCE - 12.0,
		8.0)
	var nearest := Gen.nearest_world_image(canonical_a, reference)
	_check(nearest.distance_to(reference) < 16.0,
		"nearest world image keeps seam-adjacent replicas locally adjacent",
		"distance=%.3f" % nearest.distance_to(reference))

	var geographic := Vector2(-73.5, 41.25)
	var round_trip_xz := Gen.planet_xz_from_longitude_latitude(
		geographic.x, geographic.y)
	var round_trip := Gen.planet_longitude_latitude(round_trip_xz)
	_check(round_trip.distance_to(geographic) < 0.0001,
		"longitude and latitude conversions round-trip for the world map")

	var repeat_before := Gen.map_sample(probe.x, probe.y, 64.0)
	Gen.setup(Gen.world_seed)
	var repeat_after := Gen.map_sample(probe.x, probe.y, 64.0)
	_check(repeat_before == repeat_after,
		"terrain, biome, road and map samples repeat exactly from the seed")


func _test_pangaea_poles_and_distribution() -> void:
	# The authored lobe centres and the corridors back to the central lobe must
	# remain one connected supercontinent. This leaves room for small islands and
	# does not mistake the separate permanent ice shelves for Pangaea.
	var lobe_centres := PackedVector2Array([
		Vector2(0.0, -1.0), Vector2(-21.8, 32.1), Vector2(38.4, 11.5),
		Vector2(8.0, -35.0), Vector2(-37.8, -20.0), Vector2(53.9, -13.8),
	])
	var pangaea_connected := true
	var weakest_corridor_land := 1.0
	for lobe_index in range(lobe_centres.size()):
		var target: Vector2 = lobe_centres[lobe_index]
		for corridor_step in range(25):
			var degrees := lobe_centres[0].lerp(target,
				float(corridor_step) / 24.0)
			var p := Gen.planet_xz_from_longitude_latitude(degrees.x, degrees.y)
			var macro := Gen.planet_terrain_sample(p.x, p.y)
			weakest_corridor_land = minf(weakest_corridor_land,
				float(macro.land))
			pangaea_connected = pangaea_connected \
				and float(macro.land) >= 0.72 \
				and float(macro.ocean) <= 0.30
	_check(pangaea_connected,
		"the major Pangaea lobes remain joined by dry continental corridors",
		"weakest_land=%.3f" % weakest_corridor_land)

	var polar_samples := 0
	var frozen_samples := 0
	var minimum_ice_height := INF
	for latitude in [-88.0, 88.0]:
		for longitude_index in range(24):
			var longitude := -180.0 + float(longitude_index) * 15.0
			var p := Gen.planet_xz_from_longitude_latitude(longitude, latitude)
			var macro := Gen.planet_terrain_sample(p.x, p.y)
			var elevation := Gen.planet_height_from_sample(macro)
			var biome := Gen.planet_biome_from_sample(macro, elevation)
			polar_samples += 1
			minimum_ice_height = minf(minimum_ice_height, elevation)
			if biome == Gen.Biome.ICE \
					and float(macro.polar_ice) >= 0.98 \
					and float(macro.ocean) <= 0.001 \
					and elevation > Gen.WATER_Y + 1.0:
				frozen_samples += 1
	_check(frozen_samples == polar_samples,
		"north and south polar caps are permanent dry ice at every longitude",
		"frozen=%d/%d minimum_height=%.2fm" % [frozen_samples,
			polar_samples, minimum_ice_height])

	var biome_counts := {}
	var ocean_samples := 0
	var continental_land_samples := 0
	var global_samples := 0
	var coast_transitions := 0
	var maximum_ocean_span := 0.0
	var maximum_offshore_distance := 0.0
	var longitude_step := Gen.PLANET_CIRCUMFERENCE \
		/ float(GLOBAL_LONGITUDE_SAMPLES)
	for latitude_index in range(GLOBAL_LATITUDE_SAMPLES):
		var latitude := lerpf(-86.0, 86.0,
			float(latitude_index) / float(GLOBAL_LATITUDE_SAMPLES - 1))
		var ocean_row: Array[bool] = []
		var land_row: Array[bool] = []
		for longitude_index in range(GLOBAL_LONGITUDE_SAMPLES):
			var longitude := -180.0 + (float(longitude_index) + 0.5) \
				* 360.0 / float(GLOBAL_LONGITUDE_SAMPLES)
			var p := Gen.planet_xz_from_longitude_latitude(longitude, latitude)
			var macro := Gen.planet_terrain_sample(p.x, p.y)
			var elevation := Gen.planet_height_from_sample(macro)
			var biome := Gen.planet_biome_from_sample(macro, elevation)
			biome_counts[biome] = int(biome_counts.get(biome, 0)) + 1
			var is_ocean := biome == Gen.Biome.OCEAN
			var is_continental_land := float(macro.land) > 0.64 \
				and float(macro.polar_ice) < 0.05 and not is_ocean
			ocean_row.append(is_ocean)
			land_row.append(is_continental_land)
			ocean_samples += 1 if is_ocean else 0
			continental_land_samples += 1 if is_continental_land else 0
			global_samples += 1
			if is_ocean:
				maximum_offshore_distance = maxf(maximum_offshore_distance,
					-maxf(float(macro.coast_distance), -INF))
		for longitude_index in range(GLOBAL_LONGITUDE_SAMPLES):
			if land_row[longitude_index] != land_row[
					(longitude_index + 1) % GLOBAL_LONGITUDE_SAMPLES]:
				coast_transitions += 1
		var longest_row_run := 0
		var current_run := 0
		for doubled_index in range(GLOBAL_LONGITUDE_SAMPLES * 2):
			if ocean_row[doubled_index % GLOBAL_LONGITUDE_SAMPLES]:
				current_run = mini(current_run + 1, GLOBAL_LONGITUDE_SAMPLES)
				longest_row_run = maxi(longest_row_run, current_run)
			else:
				current_run = 0
		maximum_ocean_span = maxf(maximum_ocean_span,
			float(longest_row_run) * longitude_step)

	# A denser Pangaea climate atlas targets narrower inland biomes. The seeded
	# home lake below adds metre-scale LAKE/WETLAND shore samples that no honest
	# whole-globe raster could resolve.
	for latitude_index in range(PANGAEA_LATITUDE_SAMPLES):
		var latitude := lerpf(-60.0, 60.0,
			float(latitude_index) / float(PANGAEA_LATITUDE_SAMPLES - 1))
		for longitude_index in range(PANGAEA_LONGITUDE_SAMPLES):
			var longitude := lerpf(-80.0, 80.0,
				float(longitude_index) / float(PANGAEA_LONGITUDE_SAMPLES - 1))
			var p := Gen.planet_xz_from_longitude_latitude(longitude, latitude)
			_record_biome_at(p, biome_counts)

	var lake_center := Gen.planet_home_lake_center()
	var lake_center_macro := Gen.planet_terrain_sample(lake_center.x,
		lake_center.y)
	var lake_center_height := Gen.planet_height_from_sample(lake_center_macro)
	var lake_samples := 0
	var maximum_lake_span := 0.0
	const LAKE_STEP := 12.0
	for row in range(-30, 31):
		var run := 0
		for column in range(-30, 31):
			var p := lake_center + Vector2(float(column), float(row)) * LAKE_STEP
			var macro := Gen.planet_terrain_sample(p.x, p.y)
			var elevation := Gen.planet_height_from_sample(macro)
			var biome := Gen.planet_biome_from_sample(macro, elevation)
			biome_counts[biome] = int(biome_counts.get(biome, 0)) + 1
			if biome == Gen.Biome.LAKE and float(macro.lake) > 0.34 \
					and elevation < Gen.WATER_Y:
				run += 1
				lake_samples += 1
				maximum_lake_span = maxf(maximum_lake_span,
					float(run) * LAKE_STEP)
			else:
				run = 0

	var ocean_fraction := float(ocean_samples) / float(global_samples)
	var land_fraction := float(continental_land_samples) / float(global_samples)
	_check(biome_counts.size() == Gen.Biome.size(),
		"dense global, Pangaea and shoreline sampling finds all twelve biomes",
		"counts=%s" % [_biome_counts_string(biome_counts)])
	_check(ocean_fraction >= 0.18 and ocean_fraction <= 0.72
		and land_fraction >= 0.18 and coast_transitions >= 24
		and maximum_ocean_span >= 2_000_000.0
		and maximum_offshore_distance >= 500_000.0,
		"Pangaea has a readable coast and genuinely open planetary oceans",
		("ocean=%.1f%% land=%.1f%% coasts=%d span=%.0fkm "
			+ "offshore=%.0fkm") % [ocean_fraction * 100.0,
			land_fraction * 100.0, coast_transitions,
			maximum_ocean_span / 1000.0, maximum_offshore_distance / 1000.0])
	_check(maximum_lake_span >= 360.0 and lake_samples >= 500,
		"the seeded freshwater lake is hundreds of metres wide with real area",
		("span=%.0fm samples=%d center=(%.1f,%.1f) radius=%.1fm "
			+ "center_lake=%.3f center_height=%.2fm") % [maximum_lake_span,
			lake_samples, lake_center.x, lake_center.y, lake_center.length(),
			float(lake_center_macro.lake), lake_center_height])
	print(("PLANET_DISTRIBUTION biomes=%d ocean=%.1f%% land=%.1f%% "
		+ "coasts=%d ocean_span=%.0fkm offshore=%.0fkm lake_span=%.0fm") % [
		biome_counts.size(), ocean_fraction * 100.0, land_fraction * 100.0,
		coast_transitions, maximum_ocean_span / 1000.0,
		maximum_offshore_distance / 1000.0, maximum_lake_span])


func _test_summit_and_mountains() -> void:
	var summit := Gen.planet_summit_position()
	var summit_height := Gen.height(summit.x, summit.y)
	var radii := PackedFloat32Array([250.0, 500.0, 1000.0])
	var ring_means := PackedFloat32Array()
	var ring_minimum := INF
	var ring_maximum := -INF
	var ring_minimum_point := Vector2.ZERO
	var ring_maximum_point := Vector2.ZERO
	var ring_minimum_radius := 0.0
	var ring_maximum_radius := 0.0
	for radius in radii:
		var ring_total := 0.0
		for angle_index in range(32):
			var shoulder: Vector2 = summit + Vector2.from_angle(
				TAU * float(angle_index) / 32.0) * radius
			var shoulder_height := Gen.height(shoulder.x, shoulder.y)
			ring_total += shoulder_height
			if shoulder_height < ring_minimum:
				ring_minimum = shoulder_height
				ring_minimum_point = shoulder
				ring_minimum_radius = radius
			if shoulder_height > ring_maximum:
				ring_maximum = shoulder_height
				ring_maximum_point = shoulder
				ring_maximum_radius = radius
		ring_means.append(ring_total / 32.0)
	var shoulders_descend := ring_means.size() == 3 \
		and ring_means[0] > ring_means[1] + 150.0 \
		and ring_means[1] > ring_means[2] + 150.0
	_check(absf(summit_height - 6000.0) <= 0.02
		and ring_maximum <= 5900.0 and ring_minimum >= 120.0
		and shoulders_descend,
		"the sole 6,000 m summit has continuous, meaningfully descending shoulders",
		("summit=(%.1f,%.1f):%.2f ring_means=%s range=%.1f@%.0fm(%.1f,%.1f)"
			+ "..%.1f@%.0fm(%.1f,%.1f)") % [summit.x, summit.y,
			summit_height, ring_means, ring_minimum, ring_minimum_radius,
			ring_minimum_point.x, ring_minimum_point.y, ring_maximum,
			ring_maximum_radius, ring_maximum_point.x, ring_maximum_point.y])

	var major_mountain_heights := PackedFloat32Array()
	for latitude_index in range(65):
		var latitude := lerpf(-62.0, 62.0, float(latitude_index) / 64.0)
		for longitude_index in range(97):
			var longitude := lerpf(-85.0, 85.0,
				float(longitude_index) / 96.0)
			var p := Gen.planet_xz_from_longitude_latitude(longitude, latitude)
			var macro := Gen.planet_terrain_sample(p.x, p.y)
			var elevation := float(macro.elevation)
			if float(macro.mountain) > 0.48 \
					and float(macro.summit_weight) < 0.02 \
					and float(macro.land) > 0.80 \
					and elevation > Gen.WATER_Y:
				major_mountain_heights.append(elevation)
	var mountain_total := 0.0
	for mountain_height in major_mountain_heights:
		mountain_total += mountain_height
	var mountain_average := mountain_total \
		/ maxf(float(major_mountain_heights.size()), 1.0)
	_check(major_mountain_heights.size() >= 80
		and mountain_average >= 950.0 and mountain_average <= 1500.0,
		"dense major-range samples average near 1,200 m",
		"average=%.1fm samples=%d" % [mountain_average,
			major_mountain_heights.size()])
	print("PLANET_MOUNTAINS average=%.1fm samples=%d summit_rings=%s" % [
		mountain_average, major_mountain_heights.size(), ring_means])


func _test_gradual_uplands() -> void:
	var local_slopes := PackedFloat32Array()
	var broad_grades := PackedFloat32Array()
	var meaningful_rises := 0
	var worst_detail := ""
	var worst_slope := 0.0
	const LOCAL_RUN := 384.0
	const BROAD_RUN := 120_000.0
	for latitude_index in range(21):
		var latitude := lerpf(-50.0, 50.0, float(latitude_index) / 20.0)
		for longitude_index in range(29):
			var longitude := lerpf(-70.0, 70.0,
				float(longitude_index) / 28.0)
			var p := Gen.planet_xz_from_longitude_latitude(longitude, latitude)
			var macro := Gen.planet_terrain_sample(p.x, p.y)
			if not _ordinary_upland(macro):
				continue
			for direction in [Vector2.RIGHT, Vector2.DOWN]:
				var local_p: Vector2 = p + direction * LOCAL_RUN
				var local_macro := Gen.planet_terrain_sample(local_p.x, local_p.y)
				if _ordinary_upland(local_macro):
					var slope := absf(float(local_macro.elevation)
						- float(macro.elevation)) / LOCAL_RUN
					local_slopes.append(slope)
					if slope > worst_slope:
						worst_slope = slope
						worst_detail = "lon=%.1f lat=%.1f h=%.1f->%.1f" % [
							longitude, latitude, float(macro.elevation),
							float(local_macro.elevation)]
				var broad_p: Vector2 = p + direction * BROAD_RUN
				var broad_macro := Gen.planet_terrain_sample(broad_p.x,
					broad_p.y)
				if _ordinary_upland(broad_macro):
					var rise := absf(float(broad_macro.elevation)
						- float(macro.elevation))
					var broad_grade := rise / BROAD_RUN
					broad_grades.append(broad_grade)
					if rise >= 8.0:
						meaningful_rises += 1
	local_slopes.sort()
	broad_grades.sort()
	var local_p95 := _percentile(local_slopes, 0.95)
	var broad_p95 := _percentile(broad_grades, 0.95)
	_check(local_slopes.size() >= 100 and broad_grades.size() >= 80
		and meaningful_rises >= 12 and local_p95 <= 0.035
		and broad_p95 <= 0.01,
		"ordinary uplands form meaningful long rises without short bumpy grades",
		("local_p95=%.4f local_n=%d broad_p95=%.5f broad_n=%d rises=%d "
			+ "worst=%.4f %s") % [local_p95, local_slopes.size(), broad_p95,
			broad_grades.size(), meaningful_rises, worst_slope, worst_detail])
	print(("PLANET_UPLANDS local_p95=%.4f local_n=%d broad_p95=%.5f "
		+ "broad_n=%d meaningful_rises=%d") % [local_p95,
		local_slopes.size(), broad_p95, broad_grades.size(), meaningful_rises])


func _test_planet_roads() -> void:
	var road_geometry = PlanetRoadNetworkScript.new()
	road_geometry.setup(Gen.world_seed)
	var summary := Gen.road_network_summary()
	var query_center := Gen.planet_xz_from_longitude_latitude(12.0, 8.0)
	var bounded_segments := Gen.road_segments_in_rect(Rect2(
		query_center - Vector2(3600.0, 3000.0), Vector2(7200.0, 6000.0)), 31)
	var huge_bounded_segments := Gen.road_segments_in_rect(Rect2(
		query_center - Vector2(250_000.0, 180_000.0),
		Vector2(500_000.0, 360_000.0)), 19)
	_check(str(summary.kind) == "curved_planet_arterials"
		and float(summary.regional_spacing) <= 768.0
		and float(summary.highway_spacing) <= 3072.0
		and int(summary.maximum_query_segments) <= 128
		and bool(summary.coast_following)
		and not bounded_segments.is_empty() and bounded_segments.size() <= 31
		and huge_bounded_segments.size() <= 19,
		"dense planet-road queries stay curved, feature-aware and allocation-bounded",
		"regional=%.0f highway=%.0f local=%d huge=%d" % [
			float(summary.regional_spacing), float(summary.highway_spacing),
			bounded_segments.size(), huge_bounded_segments.size()])

	var tangent_ranges := {
		"sweeping_meridian": Vector2(INF, -INF),
		"cross_country": Vector2(INF, -INF),
	}
	var maximum_curve_offset := 0.0
	for latitude_index in range(17):
		var latitude := lerpf(-50.0, 50.0, float(latitude_index) / 16.0)
		for longitude_index in range(25):
			var longitude := lerpf(-75.0, 75.0,
				float(longitude_index) / 24.0)
			var p := Gen.planet_xz_from_longitude_latitude(longitude, latitude)
			var road: Dictionary = road_geometry.surface_sample(p)
			var family := str(road.family)
			var tangent: Vector2 = road.tangent
			var baseline := Vector2(-0.5, 1.0).normalized() \
				if family == "sweeping_meridian" \
				else Vector2(1.0, 1.0).normalized()
			var bend := wrapf(tangent.angle() - baseline.angle(), -PI, PI)
			var range_value: Vector2 = tangent_ranges[family]
			range_value.x = minf(range_value.x, bend)
			range_value.y = maxf(range_value.y, bend)
			tangent_ranges[family] = range_value
			maximum_curve_offset = maxf(maximum_curve_offset,
				absf(float(road.curve_offset)))
	var meridian_range: Vector2 = tangent_ranges.sweeping_meridian
	var cross_country_range: Vector2 = tangent_ranges.cross_country
	var meridian_bend := meridian_range.y - meridian_range.x
	var cross_country_bend := cross_country_range.y - cross_country_range.x
	_check(maximum_curve_offset >= 80.0 and meridian_bend >= 0.025
		and cross_country_bend >= 0.025,
		"both road families visibly bend instead of forming a straight square grid",
		"offset=%.1fm bend_a=%.2fdeg bend_b=%.2fdeg" % [
			maximum_curve_offset, rad_to_deg(meridian_bend),
			rad_to_deg(cross_country_bend)])

	var coast_samples := _find_coastal_road_samples(10)
	var coast_alignment_min := 1.0
	for item_value in coast_samples:
		var item: Dictionary = item_value
		coast_alignment_min = minf(coast_alignment_min,
			absf((item.tangent as Vector2).dot(item.coast_tangent as Vector2)))
	_check(coast_samples.size() >= 6 and coast_alignment_min >= 0.985,
		"the Pangaea freeway follows the actual coastline tangent",
		"samples=%d minimum_alignment=%.4f" % [coast_samples.size(),
			coast_alignment_min])

	var road_centres := _collect_driveable_road_centres(road_geometry, 64)
	var road_grade_max := 0.0
	var cross_grade_max := 0.0
	var cross_added_grade_max := 0.0
	var core_camber_max := 0.0
	var verified_spans := 0
	var verified_cross_sections := 0
	var worst_cross_detail := ""
	var worst_added_detail := ""
	for item_value in road_centres:
		var item: Dictionary = item_value
		var center: Vector2 = item.center
		var road: Dictionary = item.road
		var tangent: Vector2 = road.tangent
		if tangent.length_squared() < 0.9:
			continue
		tangent = tangent.normalized()
		var next_geometry: Dictionary = road_geometry.surface_sample(
			center + tangent * 48.0)
		if str(next_geometry.route_id) != str(road.route_id):
			continue
		var next_center: Vector2 = next_geometry.center_point
		var next_road := Gen.road_surface_sample(next_center.x, next_center.y)
		if str(next_road.get("route_id", "")) != str(road.route_id) \
				or float(next_road.grade) < 0.985:
			continue
		var run := maxf(center.distance_to(next_center), 0.01)
		var longitudinal_grade := absf(Gen.height(next_center.x, next_center.y)
			- Gen.height(center.x, center.y)) / run
		road_grade_max = maxf(road_grade_max, longitudinal_grade)
		verified_spans += 1
		if verified_cross_sections >= 40:
			continue
		var across := Vector2(-tangent.y, tangent.x)
		var half_width := 7.2 if str(road.tier) == "highway" else 4.8
		var center_height := Gen.height(center.x, center.y)
		for side in [-1.0, 1.0]:
			var core_p: Vector2 = center + across * side * half_width * 0.72
			core_camber_max = maxf(core_camber_max,
				absf(Gen.height(core_p.x, core_p.y) - center_height))
			var previous_p := center
			var previous_h := center_height
			var previous_macro := Gen.planet_terrain_sample(center.x, center.y)
			var previous_natural := float(previous_macro.elevation)
			var reach := half_width + Gen.ROAD_BLEND + 4.0
			var steps := ceili(reach / 2.0)
			for step in range(1, steps + 1):
				var p: Vector2 = center + across * side \
					* minf(float(step) * 2.0, reach)
				var actual_h := Gen.height(p.x, p.y)
				var natural_macro := Gen.planet_terrain_sample(p.x, p.y)
				var natural_h := float(natural_macro.elevation)
				var section_run := maxf(p.distance_to(previous_p), 0.01)
				var actual_grade := absf(actual_h - previous_h) / section_run
				var natural_grade := absf(natural_h - previous_natural) \
					/ section_run
				if actual_grade > cross_grade_max:
					cross_grade_max = actual_grade
					worst_cross_detail = ("route=%s center=(%.1f,%.1f) "
						+ "p=(%.1f,%.1f) actual=%.3f->%.3f natural=%.3f->%.3f "
						+ "mountain=%.6f->%.6f detail=%.6f->%.6f") % [
						road.route_id, center.x, center.y, p.x, p.y,
						previous_h, actual_h, previous_natural, natural_h,
						float(previous_macro.mountain), float(natural_macro.mountain),
						float(previous_macro.detail), float(natural_macro.detail)]
				var added_grade := actual_grade - natural_grade
				if added_grade > cross_added_grade_max:
					cross_added_grade_max = added_grade
					worst_added_detail = ("route=%s center=(%.1f,%.1f) "
						+ "p=(%.1f,%.1f) actual=%.4f natural=%.4f") % [
						road.route_id, center.x, center.y, p.x, p.y,
						actual_grade, natural_grade]
				previous_p = p
				previous_h = actual_h
				previous_natural = natural_h
		verified_cross_sections += 1
	_check(verified_spans >= 24
		and road_grade_max <= Gen.ROAD_MAX_GRADE + 0.002,
		"tangent-following driveable roads stay below the 8.5 percent grade cap",
		"max_grade=%.4f spans=%d candidates=%d" % [road_grade_max,
			verified_spans, road_centres.size()])
	_check(verified_cross_sections >= 20 and core_camber_max <= 0.06
		and cross_grade_max <= 0.15 and cross_added_grade_max <= 0.075,
		"tangent-normal shoulders meet terrain without cross-road cliffs",
		("core=%.3fm cross=%.4f added=%.4f sections=%d worst_cross={%s} "
			+ "worst_added={%s}") % [
			core_camber_max, cross_grade_max, cross_added_grade_max,
			verified_cross_sections, worst_cross_detail, worst_added_detail])

	var seam_probe := Vector2(12_336.0, 6_768.0)
	var seam_road_a: Dictionary = road_geometry.surface_sample(seam_probe)
	var seam_road_b: Dictionary = road_geometry.surface_sample(seam_probe
		+ Vector2(Gen.PLANET_CIRCUMFERENCE, 0.0))
	_check(str(seam_road_a.route_id) == str(seam_road_b.route_id)
		and absf(float(seam_road_a.distance)
			- float(seam_road_b.distance)) < 0.001
		and (seam_road_a.tangent as Vector2).distance_to(
			seam_road_b.tangent as Vector2) < 0.0001,
		"curved road IDs, distances and tangents join exactly at the seam",
		"ids=%s/%s distance_delta=%.6f" % [seam_road_a.route_id,
			seam_road_b.route_id, absf(float(seam_road_a.distance)
				- float(seam_road_b.distance))])

	_test_rocket_pad()
	print(("PLANET_ROADS curve=%.1fm bends=%.2f/%.2fdeg coast=%d "
		+ "driveable=%d max_grade=%.4f cross=%.4f added=%.4f") % [
		maximum_curve_offset, rad_to_deg(meridian_bend),
		rad_to_deg(cross_country_bend), coast_samples.size(),
		road_centres.size(), road_grade_max, cross_grade_max,
		cross_added_grade_max])


func _test_rocket_pad() -> void:
	var launch := Gen.rocket_launch_position()
	var launch_min := INF
	var launch_max := -INF
	var launch_clear := true
	for dx in range(-12, 13, 4):
		for dz in range(-12, 13, 4):
			if Vector2(float(dx), float(dz)).length() > 12.0:
				continue
			var sample_height := Gen.height(launch.x + float(dx),
				launch.z + float(dz))
			launch_min = minf(launch_min, sample_height)
			launch_max = maxf(launch_max, sample_height)
	var launch_key := Vector2i(floori(launch.x / Gen.CHUNK),
		floori(launch.z / Gen.CHUNK))
	for cx in range(launch_key.x - 1, launch_key.x + 2):
		for cz in range(launch_key.y - 1, launch_key.y + 2):
			var layout := Gen.chunk_layout(cx, cz)
			for collection_name in ["trees", "rocks", "foliage"]:
				for item in layout.get(collection_name, []):
					var pos: Vector3 = item.pos
					launch_clear = launch_clear and Vector2(pos.x, pos.z).distance_to(
						Vector2(launch.x, launch.z)) >= Gen.ROCKET_PAD_RADIUS
	var before_reset := launch
	Gen.setup(Gen.world_seed)
	var after_reset := Gen.rocket_launch_position()
	_check(launch.y > Gen.WATER_Y + 1.0 and launch_max - launch_min < 0.10
		and launch_clear and before_reset == after_reset,
		"rocket launch pad is deterministic, dry, level and clear",
		"range=%.3fm clear=%s reset_delta=%.4fm" % [
			launch_max - launch_min, str(launch_clear),
			before_reset.distance_to(after_reset)])


func _test_seed_robustness() -> void:
	var original_seed := Gen.world_seed
	var robust := true
	var summaries: Array[String] = []
	for seed_value in [99, 2026, 8675309]:
		Gen.setup(seed_value)
		var seen := _seed_biome_coverage()
		var ocean_count := 0
		var sample_count := 0
		for latitude_index in range(25):
			var latitude := lerpf(-84.0, 84.0,
				float(latitude_index) / 24.0)
			for longitude_index in range(48):
				var longitude := -180.0 + (float(longitude_index) + 0.5) * 7.5
				var p := Gen.planet_xz_from_longitude_latitude(longitude, latitude)
				ocean_count += 1 if Gen.biome_at(p.x, p.y) \
					== Gen.Biome.OCEAN else 0
				sample_count += 1
		var ocean_fraction := float(ocean_count) / float(sample_count)
		var summit := Gen.planet_summit_position()
		var shoulder: Vector2 = summit + Vector2(500.0, 0.0)
		var north := Gen.planet_xz_from_longitude_latitude(90.0, 88.0)
		var south := Gen.planet_xz_from_longitude_latitude(-90.0, -88.0)
		var seed_ok := seen.size() == Gen.Biome.size() \
			and ocean_fraction >= 0.12 and ocean_fraction <= 0.76 \
			and absf(Gen.height(summit.x, summit.y) - 6000.0) < 0.02 \
			and Gen.height(shoulder.x, shoulder.y) < 5900.0 \
			and Gen.biome_at(north.x, north.y) == Gen.Biome.ICE \
			and Gen.biome_at(south.x, south.y) == Gen.Biome.ICE \
			and Gen.rocket_launch_position().y > Gen.WATER_Y + 1.0
		robust = robust and seed_ok
		summaries.append("%d:%d/%.0f%%/shoulder%.0f" % [seed_value,
			seen.size(), ocean_fraction * 100.0,
			Gen.height(shoulder.x, shoulder.y)])
	Gen.setup(original_seed)
	_check(robust,
		"biomes, ocean, poles, summit shoulders and launch pad survive multiple seeds",
		"seeds=%s" % [summaries])


func _record_biome_at(p: Vector2, counts: Dictionary) -> void:
	var macro := Gen.planet_terrain_sample(p.x, p.y)
	var elevation := Gen.planet_height_from_sample(macro)
	var biome := Gen.planet_biome_from_sample(macro, elevation)
	counts[biome] = int(counts.get(biome, 0)) + 1


func _biome_counts_string(counts: Dictionary) -> String:
	var parts: Array[String] = []
	for biome in range(Gen.Biome.size()):
		parts.append("%s=%d" % [Gen.biome_name(biome),
			int(counts.get(biome, 0))])
	return ", ".join(parts)


func _ordinary_upland(macro: Dictionary) -> bool:
	return float(macro.land) >= 0.86 \
		and float(macro.ocean) <= 0.02 \
		and float(macro.lake) <= 0.02 \
		and float(macro.mountain) <= 0.20 \
		and float(macro.polar_ice) <= 0.02


func _percentile(values: PackedFloat32Array, fraction: float) -> float:
	if values.is_empty():
		return INF
	var index := clampi(int(floor(float(values.size() - 1) * fraction)),
		0, values.size() - 1)
	return values[index]


func _find_coastal_road_samples(limit: int) -> Array:
	var results: Array = []
	var seen := {}
	for latitude_value in [-48.0, -36.0, -24.0, -12.0, 0.0, 12.0,
			24.0, 36.0, 48.0]:
		var latitude: float = float(latitude_value)
		var previous_longitude := -130.0
		var previous_point := Gen.planet_xz_from_longitude_latitude(
			previous_longitude, latitude)
		var previous_macro := Gen.planet_terrain_sample(previous_point.x,
			previous_point.y)
		var previous_value := float(previous_macro.coast_distance) \
			- Gen.COAST_ROAD_INLAND_OFFSET
		for longitude_step in range(1, 131):
			var longitude := -130.0 + float(longitude_step) * 2.0
			var point := Gen.planet_xz_from_longitude_latitude(longitude, latitude)
			var macro := Gen.planet_terrain_sample(point.x, point.y)
			var value := float(macro.coast_distance) \
				- Gen.COAST_ROAD_INLAND_OFFSET
			if signf(previous_value) != signf(value):
				var low_longitude := previous_longitude
				var high_longitude := longitude
				var low_value := previous_value
				for _iteration in range(24):
					var middle_longitude := (low_longitude + high_longitude) * 0.5
					var middle_point := Gen.planet_xz_from_longitude_latitude(
						middle_longitude, latitude)
					var middle_macro := Gen.planet_terrain_sample(middle_point.x,
						middle_point.y)
					var middle_value := float(middle_macro.coast_distance) \
						- Gen.COAST_ROAD_INLAND_OFFSET
					if signf(middle_value) == signf(low_value):
						low_longitude = middle_longitude
						low_value = middle_value
					else:
						high_longitude = middle_longitude
				var coast_longitude := (low_longitude + high_longitude) * 0.5
				var coast_point := Gen.planet_xz_from_longitude_latitude(
					coast_longitude, latitude)
				var coast_macro := Gen.planet_terrain_sample(coast_point.x,
					coast_point.y)
				var road := Gen.road_surface_sample(coast_point.x, coast_point.y)
				var key := "%d:%d" % [roundi(coast_longitude * 10.0),
					roundi(latitude * 10.0)]
				if str(road.get("route_id", "")) == "coastal:pangaea" \
						and float(road.grade) >= 0.98 and not seen.has(key):
					results.append({
						"point": coast_point,
						"tangent": road.tangent,
						"coast_tangent": coast_macro.coast_tangent,
					})
					seen[key] = true
					if results.size() >= limit:
						return results
			previous_longitude = longitude
			previous_value = value
	return results


func _collect_driveable_road_centres(road_geometry: RefCounted,
		limit: int) -> Array:
	var results: Array = []
	var seen := {}
	for latitude_index in range(19):
		var latitude := lerpf(-50.0, 50.0, float(latitude_index) / 18.0)
		for longitude_index in range(29):
			var longitude := lerpf(-75.0, 75.0,
				float(longitude_index) / 28.0)
			var probe := Gen.planet_xz_from_longitude_latitude(longitude, latitude)
			var geometry: Dictionary = road_geometry.surface_sample(probe)
			var center: Vector2 = geometry.center_point
			var road := Gen.road_surface_sample(center.x, center.y)
			var route_id := str(road.get("route_id", ""))
			if route_id != str(geometry.route_id) or float(road.grade) < 0.985 \
					or not road.has("tangent"):
				continue
			var key := "%s@%d" % [route_id,
				roundi(float(road.get("route_coordinate", 0.0)) / 384.0)]
			if seen.has(key):
				continue
			seen[key] = true
			results.append({"center": center, "road": road})
			if results.size() >= limit:
				return results
	return results


func _seed_biome_coverage() -> Dictionary:
	var seen := {}
	for latitude_index in range(37):
		var latitude := lerpf(-86.0, 86.0, float(latitude_index) / 36.0)
		for longitude_index in range(72):
			var longitude := -180.0 + (float(longitude_index) + 0.5) * 5.0
			var p := Gen.planet_xz_from_longitude_latitude(longitude, latitude)
			_record_biome_at(p, seen)
	for latitude_index in range(31):
		var latitude := lerpf(-58.0, 58.0, float(latitude_index) / 30.0)
		for longitude_index in range(49):
			var longitude := lerpf(-78.0, 78.0,
				float(longitude_index) / 48.0)
			var p := Gen.planet_xz_from_longitude_latitude(longitude, latitude)
			_record_biome_at(p, seen)
	var lake_center := Gen.planet_home_lake_center()
	for row in range(-18, 19):
		for column in range(-18, 19):
			_record_biome_at(lake_center
				+ Vector2(float(column), float(row)) * 18.0, seen)
	return seen
