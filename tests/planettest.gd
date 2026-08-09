extends Node
## Focused quantitative gate for the 0.4 spherical terrain foundation.

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
	_test_summit_and_distribution()
	_test_gradual_uplands()
	_test_planet_roads()
	_test_seed_robustness()
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	print("PLANETTEST_STATS assertions=%d elapsed_ms=%d" % [total, elapsed_ms])
	print("PLANETTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)


func _test_spherical_topology() -> void:
	var probe := Vector2(12345.75, 6789.25)
	var longitude_image := probe + Vector2(Gen.PLANET_CIRCUMFERENCE, 0.0)
	var canonical_a := Gen.canonical_planet_xz(probe)
	var canonical_b := Gen.canonical_planet_xz(longitude_image)
	var periodic_height := absf(Gen.height(probe.x, probe.y)
		- Gen.height(longitude_image.x, longitude_image.y)) < 0.001
	_check(canonical_a.distance_to(canonical_b) < 0.001 and periodic_height
		and Gen.biome_at(probe.x, probe.y)
			== Gen.biome_at(longitude_image.x, longitude_image.y),
		"longitude seam is exact for canonical position, height and biome")

	var beyond_north := Vector2(1400.0, Gen.PLANET_POLE_DISTANCE + 730.0)
	var north_sample := Gen.canonical_world_sample(beyond_north)
	var expected_north := Gen.canonical_planet_xz(Vector2(
		1400.0 + Gen.PLANET_HALF_CIRCUMFERENCE,
		Gen.PLANET_POLE_DISTANCE - 730.0))
	var pole_xz: Vector2 = north_sample.xz
	_check(pole_xz.distance_to(expected_north) < 0.001
		and int(north_sample.pole_crossings) == 1
		and absf(float(north_sample.yaw_delta) - PI) < 0.0001
		and absf(Gen.height(beyond_north.x, beyond_north.y)
			- Gen.height(expected_north.x, expected_north.y)) < 0.001
		and Gen.biome_at(beyond_north.x, beyond_north.y)
			== Gen.biome_at(expected_north.x, expected_north.y)
		and Gen.planet_sphere_direction(beyond_north).distance_to(
			Gen.planet_sphere_direction(expected_north)) < 0.0001,
		"pole crossing reflects latitude, advances longitude and returns PI yaw")

	var reference := canonical_a + Vector2(Gen.PLANET_CIRCUMFERENCE - 12.0,
		8.0)
	var nearest := Gen.nearest_world_image(canonical_a, reference)
	_check(nearest.distance_to(reference) < 16.0,
		"nearest world image keeps seam-adjacent remote actors locally adjacent",
		"distance=%.3f" % nearest.distance_to(reference))

	var geographic := Vector2(-73.5, 41.25)
	var round_trip_xz := Gen.planet_xz_from_longitude_latitude(
		geographic.x, geographic.y)
	var round_trip := Gen.planet_longitude_latitude(round_trip_xz)
	_check(round_trip.distance_to(geographic) < 0.0001,
		"longitude/latitude conversion round-trips for world-map coordinates")

	var repeat_before := Gen.map_sample(probe.x, probe.y, 64.0)
	Gen.setup(Gen.world_seed)
	var repeat_after := Gen.map_sample(probe.x, probe.y, 64.0)
	_check(repeat_before == repeat_after,
		"planet, biome, road and map samples repeat exactly from the world seed")


func _test_summit_and_distribution() -> void:
	var summit := Gen.planet_summit_position()
	var summit_height := Gen.height(summit.x, summit.y)
	var shoulder_max := -INF
	for angle_index in range(24):
		var shoulder := summit + Vector2.from_angle(
			TAU * float(angle_index) / 24.0) * 500.0
		shoulder_max = maxf(shoulder_max, Gen.height(shoulder.x, shoulder.y))
	_check(absf(summit_height - 6000.0) <= 0.02
		and shoulder_max < summit_height,
		"seed-derived tallest summit is exactly 6,000 m with descending shoulders",
		"summit=%.3f shoulder_max=%.1f" % [summit_height, shoulder_max])

	var biome_counts := {}
	var ocean_samples := 0
	var land_samples := 0
	var major_mountain_heights := PackedFloat32Array()
	var coast_transitions := 0
	var maximum_ocean_span := 0.0
	const LONGITUDE_SAMPLES := 64
	const LATITUDE_SAMPLES := 31
	var longitude_step := Gen.PLANET_CIRCUMFERENCE / float(LONGITUDE_SAMPLES)
	for latitude_index in range(LATITUDE_SAMPLES):
		var latitude_t := float(latitude_index) / float(LATITUDE_SAMPLES - 1)
		var z := lerpf(-Gen.PLANET_POLE_DISTANCE + 64.0,
			Gen.PLANET_POLE_DISTANCE - 64.0, latitude_t)
		var ocean_row: Array[bool] = []
		var previous_land := false
		for longitude_index in range(LONGITUDE_SAMPLES):
			var x := -Gen.PLANET_HALF_CIRCUMFERENCE \
				+ (float(longitude_index) + 0.5) * longitude_step
			var macro := Gen.planet_terrain_sample(x, z)
			var elevation := Gen.planet_height_from_sample(macro)
			var biome := Gen.planet_biome_from_sample(macro, elevation)
			biome_counts[biome] = int(biome_counts.get(biome, 0)) + 1
			var is_ocean := biome == Gen.Biome.OCEAN
			var is_land := float(macro.land) > 0.64 and not is_ocean
			ocean_row.append(is_ocean)
			ocean_samples += 1 if is_ocean else 0
			land_samples += 1 if is_land else 0
			if longitude_index > 0 and is_land != previous_land:
				coast_transitions += 1
			previous_land = is_land
			if float(macro.mountain) > 0.48 \
					and float(macro.summit_weight) < 0.02 \
					and float(macro.land) > 0.80 and elevation > Gen.WATER_Y:
				major_mountain_heights.append(elevation)
		var longest_row_run := 0
		var current_run := 0
		for doubled_index in range(LONGITUDE_SAMPLES * 2):
			if ocean_row[doubled_index % LONGITUDE_SAMPLES]:
				current_run = mini(current_run + 1, LONGITUDE_SAMPLES)
				longest_row_run = maxi(longest_row_run, current_run)
			else:
				current_run = 0
		maximum_ocean_span = maxf(maximum_ocean_span,
			float(longest_row_run) * longitude_step)
	var sample_count := LONGITUDE_SAMPLES * LATITUDE_SAMPLES
	var ocean_fraction := float(ocean_samples) / float(sample_count)
	var land_fraction := float(land_samples) / float(sample_count)
	_check(biome_counts.size() == Gen.Biome.size(),
		"all twelve named Earth-like biomes occur on the shared planet",
		"found=%s" % [biome_counts.keys()])
	_check(ocean_fraction >= 0.18 and ocean_fraction <= 0.72
		and land_fraction >= 0.22 and coast_transitions >= 24
		and maximum_ocean_span >= 6000.0,
		"continents, islands and multi-kilometre open oceans have useful coverage",
		"ocean=%.1f%% land=%.1f%% coasts=%d max_ocean=%.0fm" % [
			ocean_fraction * 100.0, land_fraction * 100.0,
			coast_transitions, maximum_ocean_span])

	var mountain_total := 0.0
	for mountain_height in major_mountain_heights:
		mountain_total += mountain_height
	var mountain_average := mountain_total \
		/ maxf(float(major_mountain_heights.size()), 1.0)
	_check(major_mountain_heights.size() >= 12
		and mountain_average >= 950.0 and mountain_average <= 1500.0,
		"major mountain samples average near 1,200 m",
		"average=%.1fm samples=%d" % [mountain_average,
			major_mountain_heights.size()])

	# The seeded home lake is sampled more finely than the planet grid so this
	# assertion measures a physical shoreline, not a lucky coarse water pixel.
	var lake_center := Gen.planet_home_lake_center()
	var maximum_lake_span := 0.0
	var lake_samples := 0
	for row in range(-8, 9):
		var run := 0
		for column in range(-12, 13):
			var p := lake_center + Vector2(float(column) * 30.0,
				float(row) * 30.0)
			var macro := Gen.planet_terrain_sample(p.x, p.y)
			if float(macro.lake) > 0.5 and Gen.height(p.x, p.y) < Gen.WATER_Y:
				run += 1
				lake_samples += 1
				maximum_lake_span = maxf(maximum_lake_span, float(run) * 30.0)
			else:
				run = 0
	_check(maximum_lake_span >= 360.0 and lake_samples >= 70,
		"freshwater lakes span hundreds of metres rather than small puddles",
		"span=%.0fm samples=%d" % [maximum_lake_span, lake_samples])
	print(("PLANET_DISTRIBUTION biomes=%d ocean=%.1f%% land=%.1f%% " \
		+ "coasts=%d ocean_span=%.0fm mountain_avg=%.1fm mountains=%d " \
		+ "lake_span=%.0fm") % [biome_counts.size(), ocean_fraction * 100.0,
			land_fraction * 100.0, coast_transitions, maximum_ocean_span,
			mountain_average, major_mountain_heights.size(), maximum_lake_span])


func _test_gradual_uplands() -> void:
	var slopes := PackedFloat32Array()
	var worst_slope := 0.0
	var worst_detail := ""
	for latitude_index in range(-9, 10):
		var z := float(latitude_index) * 1850.0
		for longitude_index in range(-18, 19):
			var x := float(longitude_index) * 2100.0 + 317.0
			var a := Gen.planet_terrain_sample(x, z)
			var b := Gen.planet_terrain_sample(x + 96.0, z)
			if float(a.land) < 0.82 or float(b.land) < 0.82 \
					or float(a.ocean) > 0.015 or float(b.ocean) > 0.015 \
					or float(a.lake) > 0.015 or float(b.lake) > 0.015 \
					or float(a.mountain) > 0.015 or float(b.mountain) > 0.015:
				continue
			# Measure natural terrain, excluding authored road/runway/pad grading.
			var h_a := float(a.elevation)
			var h_b := float(b.elevation)
			var slope := absf(h_b - h_a) / 96.0
			slopes.append(slope)
			if slope > worst_slope:
				worst_slope = slope
				worst_detail = "p=(%.0f,%.0f) h=%.1f->%.1f upland=%.2f->%.2f mountain=%.3f->%.3f" % [
					x, z, h_a, h_b, float(a.upland), float(b.upland),
					float(a.mountain), float(b.mountain)]
	slopes.sort()
	var p95 := slopes[int(floor(float(slopes.size() - 1) * 0.95))] \
		if not slopes.is_empty() else INF
	_check(slopes.size() >= 80 and p95 <= 0.18,
		"ordinary uplands rise gradually instead of repeating sharp bumps",
		"p95_grade=%.3f samples=%d worst=%.3f %s" % [p95, slopes.size(),
			worst_slope, worst_detail])
	print("PLANET_UPLANDS p95_grade=%.4f samples=%d" % [p95, slopes.size()])


func _test_planet_roads() -> void:
	var summary := Gen.road_network_summary()
	var bounded_segments := Gen.road_segments_in_rect(
		Rect2(Vector2(-2400.0, -1800.0), Vector2(4800.0, 3600.0)), 17)
	_check(float(summary.regional_spacing) <= 768.0
		and float(summary.highway_spacing) <= 3072.0
		and int(summary.maximum_query_segments) <= 128
		and not bounded_segments.is_empty() and bounded_segments.size() <= 17,
		"world-spanning road queries are dense, analytic and allocation-bounded",
		"regional=%.0f highway=%.0f cap=%d returned=%d" % [
			float(summary.regional_spacing), float(summary.highway_spacing),
			int(summary.maximum_query_segments), bounded_segments.size()])

	var road_grade_max := 0.0
	var cross_grade_max := 0.0
	var cross_added_grade_max := 0.0
	var core_camber_max := 0.0
	var verified_spans := 0
	var verified_cross_sections := 0
	var periodic_road := false
	for longitude_index in range(-28, 29):
		var x := float(longitude_index) * 768.0
		for latitude_index in range(-14, 15):
			var z := float(latitude_index) * 768.0 + 192.0
			var road_a := Gen.road_surface_sample(x, z)
			var road_b := Gen.road_surface_sample(x, z + 96.0)
			if float(road_a.grade) < 0.999 or float(road_b.grade) < 0.999:
				continue
			var grade := absf(Gen.height(x, z + 96.0) - Gen.height(x, z)) / 96.0
			road_grade_max = maxf(road_grade_max, grade)
			verified_spans += 1
			if verified_cross_sections < 48:
				var perpendicular := Vector2.RIGHT \
					if str(road_a.get("axis", "longitude")) == "longitude" \
					else Vector2.DOWN
				var half_width := 7.2 if str(road_a.get("tier", "regional")) \
					== "highway" else 4.8
				var reach := half_width + Gen.ROAD_BLEND + 4.0
				var section_center_height := Gen.height(x, z)
				for side in [-1.0, 1.0]:
					var previous_p := Vector2(x, z)
					var previous_h := section_center_height
					var previous_macro := Gen.planet_terrain_sample(
						previous_p.x, previous_p.y)
					var previous_natural := float(previous_macro.elevation)
					var steps := ceili(reach / 2.0)
					for step in range(1, steps + 1):
						var p: Vector2 = Vector2(x, z) + perpendicular * side \
							* minf(float(step) * 2.0, reach)
						var actual_h := Gen.height(p.x, p.y)
						if p.distance_to(Vector2(x, z)) <= half_width:
							core_camber_max = maxf(core_camber_max,
								absf(actual_h - section_center_height))
						var natural_macro := Gen.planet_terrain_sample(p.x, p.y)
						var natural_h := float(natural_macro.elevation)
						var run := maxf(p.distance_to(previous_p), 0.01)
						var actual_grade := absf(actual_h - previous_h) / run
						var natural_grade := absf(natural_h - previous_natural) / run
						cross_grade_max = maxf(cross_grade_max, actual_grade)
						cross_added_grade_max = maxf(cross_added_grade_max,
							actual_grade - natural_grade)
						previous_p = p
						previous_h = actual_h
						previous_natural = natural_h
				verified_cross_sections += 1
			var seam_sample := Gen.road_surface_sample(
				x + Gen.PLANET_CIRCUMFERENCE, z)
			periodic_road = periodic_road or (
				absf(float(seam_sample.grade) - float(road_a.grade)) < 0.0001
				and absf(float(seam_sample.elevation)
					- float(road_a.elevation)) < 0.001)
	_check(verified_spans >= 18 and road_grade_max <= Gen.ROAD_MAX_GRADE + 0.002,
		"sampled regional roads stay draped at or below the 8.5 percent grade cap",
		"max_grade=%.4f spans=%d" % [road_grade_max, verified_spans])
	_check(verified_cross_sections >= 24 and core_camber_max <= 0.06
		and cross_grade_max <= 0.15 and cross_added_grade_max <= 0.075,
		"engineered shoulders meet surrounding terrain without cross-road cliffs",
		"core_camber=%.3fm cross_max=%.4f added=%.4f sections=%d" % [
			core_camber_max, cross_grade_max, cross_added_grade_max,
			verified_cross_sections])
	_check(periodic_road,
		"road surfaces and profiles join exactly across the longitude seam")

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
	_check(launch.y > Gen.WATER_Y + 1.0 and launch_max - launch_min < 0.10
		and launch_clear,
		"rocket launch pad is deterministic, dry, level and clear of decorations",
		"range=%.3fm clear=%s" % [launch_max - launch_min, str(launch_clear)])
	print(("PLANET_ROADS max_grade=%.4f cross_grade=%.4f " \
		+ "cross_added=%.4f core_camber=%.3fm verified_spans=%d query_segments=%d " \
		+ "rocket_pad_range=%.3fm") % [road_grade_max, cross_grade_max,
			cross_added_grade_max, core_camber_max, verified_spans,
			bounded_segments.size(), launch_max - launch_min])


func _test_seed_robustness() -> void:
	var original_seed := Gen.world_seed
	var robust := true
	var summaries: Array[String] = []
	for seed_value in [99, 2026, 8675309]:
		Gen.setup(seed_value)
		var seen := {}
		var ocean_count := 0
		for latitude_index in range(25):
			var z := lerpf(-Gen.PLANET_POLE_DISTANCE + 64.0,
				Gen.PLANET_POLE_DISTANCE - 64.0,
				float(latitude_index) / 24.0)
			for longitude_index in range(48):
				var x := -Gen.PLANET_HALF_CIRCUMFERENCE \
					+ (float(longitude_index) + 0.5) \
					* Gen.PLANET_CIRCUMFERENCE / 48.0
				var biome := Gen.biome_at(x, z)
				seen[biome] = true
				ocean_count += 1 if biome == Gen.Biome.OCEAN else 0
		var ocean_fraction := float(ocean_count) / float(48 * 25)
		var summit := Gen.planet_summit_position()
		var seed_ok := seen.size() == Gen.Biome.size() \
			and ocean_fraction >= 0.12 and ocean_fraction <= 0.76 \
			and absf(Gen.height(summit.x, summit.y) - 6000.0) < 0.02 \
			and Gen.rocket_launch_position().y > Gen.WATER_Y + 1.0
		robust = robust and seed_ok
		summaries.append("%d:%d/%.0f%%" % [seed_value, seen.size(),
			ocean_fraction * 100.0])
	Gen.setup(original_seed)
	_check(robust,
		"biome, ocean, summit and launch-pad contracts survive unrelated seeds",
		"seeds=%s" % [summaries])
