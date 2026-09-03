extends SceneTree
## Focused, renderer-independent contracts for altitude LOD policy.
## Run:
##   godot --headless --path . --script res://tests/streaminglodtest.gd

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Loading World after autoload initialization mirrors the project's other
	# standalone suites and makes Net/Voice symbols available to its compiler.
	var world_script: GDScript = load("res://scripts/world.gd")
	var world_compiled := world_script != null and world_script.can_instantiate()
	_expect(world_compiled, "world streaming policy must compile")
	if not world_compiled:
		_finish()
		return
	_test_altitude_curve(world_script)
	_test_circular_stratos_targets(world_script)
	_test_loaded_stratos_edge_coverage(world_script)
	_test_detail_hysteresis(world_script)
	_test_geometric_suppression_thresholds(world_script)
	_test_high_altitude_near_tier(world_script)
	_test_resident_altitude_handoffs(world_script)
	_test_level_flight_mountain_lookahead(world_script)
	_test_incremental_stratos_build()
	_test_complementary_material_handoffs()
	_test_water_chunk_boundary_coverage()
	_test_full_sphere_nadir_palette()
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("STREAMINGLODTEST PASS %d/%d" % [checks, checks])
		quit(0)
		return
	for failure in failures:
		push_error("STREAMINGLODTEST: %s" % failure)
	print("STREAMINGLODTEST FAIL %d issue(s), %d checks" % [
		failures.size(), checks])
	quit(1)


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _test_altitude_curve(world_script: GDScript) -> void:
	var base: float = world_script.stream_view_distance_for_altitude(10.0)
	var ordinary_hill: float = world_script.stream_view_distance_for_altitude(115.0)
	var mountain: float = world_script.stream_view_distance_for_altitude(1200.0)
	var summit: float = world_script.stream_view_distance_for_altitude(
		Gen.PLANET_SUMMIT_ELEVATION)
	var sector_size := Gen.CHUNK * Gen.STRATOS_SECTOR_CHUNKS
	_expect(is_equal_approx(base, Gen.VIEW_BASE_DISTANCE),
		"ground altitude must preserve the 2.2 km base view")
	_expect(base < ordinary_hill and ordinary_hill < mountain \
		and mountain < summit, "altitude view curve must be monotonic")
	_expect(ceili(ordinary_hill / sector_size) == 1,
		"an ordinary 115 m hill must remain in stratos ring one")
	_expect(is_equal_approx(summit, Gen.VIEW_PEAK_DISTANCE),
		"only the 6 km summit should reach the complete 15-mile view")


func _test_circular_stratos_targets(world_script: GDScript) -> void:
	var sector_size := Gen.CHUNK * Gen.STRATOS_SECTOR_CHUNKS
	var focus := Vector2(sector_size * 0.5, sector_size * 0.5)
	var radius := Gen.VIEW_PEAK_DISTANCE
	var targets: Dictionary = world_script.circular_stratos_targets(focus, radius)
	var ring := ceili(radius / sector_size)
	var square_capacity := (ring * 2 + 1) * (ring * 2 + 1)
	_expect(targets.size() < square_capacity,
		"peak stratos targets must cull square-ring corners")
	_expect(targets.has(Vector2i.ZERO),
		"the stratos circle must contain the focus sector")
	for target in targets:
		_expect(world_script.stratos_sector_intersects_circle(target, focus, radius),
			"every circular target must intersect the requested radius")
	for direction_value in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		var direction: Vector2 = direction_value
		var edge: Vector2 = focus + direction * (radius - 1.0)
		var edge_key := Vector2i(floori(edge.x / sector_size),
			floori(edge.y / sector_size))
		_expect(targets.has(edge_key),
			"all four radial horizon directions must remain targeted")


func _test_loaded_stratos_edge_coverage(world_script: GDScript) -> void:
	var radius := Gen.VIEW_PEAK_DISTANCE
	var focus := Vector2(800.0, -1200.0)
	var loaded: Dictionary = world_script.circular_stratos_targets(focus, radius)
	_expect(is_equal_approx(float(world_script.loaded_stratos_edge_coverage(
		loaded, focus, radius, 16)), radius),
		"loaded stratos sectors must prove the live radial shader edge")
	var sector_size := Gen.CHUNK * Gen.STRATOS_SECTOR_CHUNKS
	var edge := focus + Vector2.RIGHT * (radius - 1.0)
	loaded.erase(Vector2i(floori(edge.x / sector_size),
		floori(edge.y / sector_size)))
	_expect(float(world_script.loaded_stratos_edge_coverage(loaded, focus,
		radius, 16)) < radius,
		"the coverage diagnostic must fail when a live edge sector is absent")


func _test_detail_hysteresis(world_script: GDScript) -> void:
	_expect(not world_script.literal_detail_should_be_suppressed(250.0, false),
		"literal detail should remain awake below the ascent threshold")
	_expect(world_script.literal_detail_should_be_suppressed(270.0, false),
		"literal detail should suspend above the ascent threshold")
	_expect(world_script.literal_detail_should_be_suppressed(230.0, true),
		"literal detail should stay suspended inside the hysteresis band")
	_expect(not world_script.literal_detail_should_be_suppressed(200.0, true),
		"literal detail should wake before landing")


func _test_geometric_suppression_thresholds(world_script: GDScript) -> void:
	var constants: Dictionary = world_script.get_script_constant_map()
	var horizon_end := Gen.HORIZON_DISTANCE \
		+ Gen.CHUNK * Gen.HORIZON_SECTOR_CHUNKS
	var horizon_clearance := float(constants.HORIZON_FOLIAGE_SUSPEND_CLEARANCE)
	var horizon_horizontal := sqrt(maxf(horizon_end * horizon_end
		- horizon_clearance * horizon_clearance, 0.0))
	_expect(horizon_horizontal >= Gen.SKYLINE_NEAR_FADE + 96.0,
		"horizon must hand off before 3D culling can expose its outer fade")
	var skyline_end := Gen.SKYLINE_DISTANCE \
		+ Gen.CHUNK * Gen.SKYLINE_SECTOR_CHUNKS
	var skyline_clearance := float(constants.SKYLINE_FOLIAGE_SUSPEND_CLEARANCE)
	var skyline_horizontal := sqrt(maxf(skyline_end * skyline_end
		- skyline_clearance * skyline_clearance, 0.0))
	_expect(skyline_horizontal >= Gen.STRATOS_NEAR_FADE + 220.0,
		"skyline must hand off before 3D culling can expose its outer fade")
	_expect(float(constants.STRATOS_TARGET_REFRESH_DISTANCE) <= Gen.CHUNK * 2.0,
		"stratos targets must refresh within two moving shader-focus chunks")


func _test_high_altitude_near_tier(world_script: GDScript) -> void:
	var world = world_script.new()
	world.set("_horizon_foliage_suppressed", true)
	world.set("_ground_collision_required", false)
	_expect(int(world.call("_near_guard_radius")) == -1,
		"high aircraft must suspend redundant local fine terrain")
	world.set("_ground_collision_required", true)
	_expect(int(world.call("_near_guard_radius")) == Gen.VIEW_R,
		"collision demand must immediately restore the complete near shell")
	world.free()


func _fill_square(target: Dictionary, radius: int) -> void:
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			target[Vector2i(dx, dz)] = true


func _test_resident_altitude_handoffs(world_script: GDScript) -> void:
	var world = world_script.new()
	world.set("_horizon_foliage_suppressed", false)
	world.set("_skyline_foliage_suppressed", false)
	world.call("_update_altitude_lod_handoffs")
	_expect(not bool(world.get("_horizon_handoff_ready"))
		and not bool(world.get("_skyline_handoff_ready")),
		"descent must retain successor coverage while lower tiers rebuild")
	_expect(is_equal_approx(float(Visuals.stratos_ground_material()
		.get_shader_parameter("near_fade")), 0.0),
		"stratos must keep full center ownership during a missing skyline shell")
	_fill_square(world.horizon_chunks, Gen.HORIZON_VIEW_R)
	_fill_square(world.skyline_chunks, Gen.SKYLINE_VIEW_R)
	world.call("_update_altitude_lod_handoffs")
	_expect(bool(world.get("_horizon_handoff_ready"))
		and bool(world.get("_skyline_handoff_ready")),
		"complete resident lower shells may restore normal complementary fades")
	_expect(is_equal_approx(float(Visuals.stratos_ground_material()
		.get_shader_parameter("near_fade")), Gen.STRATOS_NEAR_FADE),
		"stratos must retract only after the complete skyline shell is resident")
	world.free()
	Visuals.set_altitude_lod_handoffs(Gen.SKYLINE_NEAR_FADE,
		Gen.STRATOS_NEAR_FADE)


func _test_level_flight_mountain_lookahead(world_script: GDScript) -> void:
	var world = world_script.new()
	var generator = root.get_node("Gen")
	var summit: Vector2 = generator.call("planet_summit_position")
	var start := summit - Vector2(1200.0, 0.0)
	var start_ground := float(generator.call("height", start.x, start.y))
	var position := Vector3(start.x, maxf(start_ground + 80.0, 5000.0),
		start.y)
	world.call("_refresh_terrain_clearance_probe", position,
		Vector3(400.0, 0.0, 0.0))
	_expect(float(world.get("_terrain_probe_collision_clearance")) <= 18.0,
		"level aircraft must see a rising 6 km mountain within its forward probe")
	world.set("_terrain_probe_position", Vector3(INF, INF, INF))
	world.set("_terrain_probe_usec", 0)
	world.call("_refresh_terrain_clearance_probe",
		Vector3(start.x, 6120.0, start.y),
		Vector3(400.0, 0.0, 0.0))
	_expect(float(world.get("_terrain_probe_collision_clearance")) > 18.0,
		"flight above the global summit must retain the conservative fast path")
	world.free()


func _test_incremental_stratos_build() -> void:
	var sector_script: GDScript = load("res://scripts/stratos_chunk.gd")
	var sector = sector_script.new()
	sector.setup(Vector2i.ZERO, 8, true)
	_expect(not bool(sector.is_build_complete())
		and sector.get_node_or_null("StratosTerrain") == null,
		"deferred stratos setup must publish no partial terrain mesh")
	_expect(not bool(sector.build_terrain_step(1)),
		"one bounded row must not synchronously finish a complete sector")
	var steps := 1
	while not sector.is_build_complete() and steps < 16:
		sector.build_terrain_step(1)
		steps += 1
	_expect(bool(sector.is_build_complete()) and steps == 9,
		"an 8-cell stratos lattice must finish after exactly nine sampled rows")
	_expect(sector.terrain_vertex_count == 81
		and sector.get_node_or_null("StratosTerrain") != null,
		"the final staged commit must preserve every lattice vertex")
	sector.free()


func _test_complementary_material_handoffs() -> void:
	Visuals.set_altitude_lod_handoffs(Gen.SKYLINE_NEAR_FADE,
		Gen.STRATOS_NEAR_FADE)
	_expect(is_equal_approx(float(Visuals.far_ground_material()
		.get_shader_parameter("far_fade")), float(Visuals.skyline_ground_material()
		.get_shader_parameter("near_fade"))),
		"horizon and skyline ground must share one complementary boundary")
	_expect(is_equal_approx(float(Visuals.skyline_ground_material()
		.get_shader_parameter("far_fade")), float(Visuals.stratos_ground_material()
		.get_shader_parameter("near_fade"))),
		"skyline and stratos ground must share one complementary boundary")
	_expect(is_equal_approx(float(Visuals.far_water_material()
		.get_shader_parameter("far_fade")), float(Visuals.skyline_water_material()
		.get_shader_parameter("near_fade"))),
		"horizon and skyline water must share one complementary boundary")
	Visuals.set_altitude_lod_handoffs(0.0, 0.0)
	_expect(is_equal_approx(float(Visuals.stratos_ground_material()
		.get_shader_parameter("near_fade")), 0.0),
		"stratos canopy terrain must fully own the under-aircraft view")
	_expect(Visuals.STRATOS_GROUND_SHADER.contains(
		"near_fade <= 0.0 ? 1.0"),
		"a zero stratos handoff must render full center coverage")
	# Restore runtime defaults for any subsequent in-process suite.
	Visuals.set_altitude_lod_handoffs(Gen.SKYLINE_NEAR_FADE,
		Gen.STRATOS_NEAR_FADE)


func _test_water_chunk_boundary_coverage() -> void:
	var gen: Node = root.get_node("Gen")
	gen.call("setup", 2026)
	var lake: Vector2 = gen.call("planet_home_lake_center")
	var chunk_script: GDScript = load("res://scripts/chunk.gd")
	var chunk: Node3D = chunk_script.new()
	root.add_child(chunk)
	var lake_key := Vector2i(floori(lake.x / Gen.CHUNK), floori(lake.y / Gen.CHUNK))
	chunk.call("setup", lake_key, {}, false, true, false)
	var water: MeshInstance3D = chunk.get("_water_instance")
	_expect(is_instance_valid(water), "water coverage fixture must build the actual wet near-tile mesh")
	if not is_instance_valid(water):
		chunk.free()
		return
	var plane := water.mesh as PlaneMesh
	_expect(plane != null and plane.size.is_equal_approx(Vector2.ONE * Gen.CHUNK),
		"fine-water tile geometry must cover its complete streamed chunk")
	_expect(water.visibility_range_end <= 0.0 \
		and water.visibility_range_fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED,
		"fine water must not disappear by camera-to-mesh-center distance before a fragment handoff")
	var material := Visuals.far_water_material()
	var near_fade := float(material.get_shader_parameter("near_fade"))
	var band := float(material.get_shader_parameter("fade_band"))
	_expect(near_fade + band <= Gen.CHUNK * Gen.VIEW_R,
		"coarse water must become complete inside the minimum 5x5 grid boundary")
	var uncovered := 0
	var sampled := 0
	var first_gap := ""
	# Sweep both signs of the world grid, nearly exact chunk edges, the center,
	# and elevated/off-center cameras. Tile membership comes from the actual
	# PlaneMesh size; opacity comes from the shipped material/node properties.
	for base in [Vector2i.ZERO, Vector2i(-7, -5)]:
		for fx in [0.001, 24.0, 47.999]:
			for fz in [0.001, 24.0, 47.999]:
				var focus := Vector2(base) * Gen.CHUNK + Vector2(fx, fz)
				for camera_offset in [Vector3.ZERO, Vector3(17, 7, 23),
						Vector3(40, 120, -40), Vector3(0, 300, 0), Vector3(0, 479, 0)]:
					var camera: Vector3 = Vector3(focus.x, Gen.WATER_Y, focus.y) + camera_offset
					for spoke in range(64):
						var direction := Vector2.from_angle(TAU * float(spoke) / 64.0)
						for distance in [0.0, 64.0, 79.0, 80.0, 90.0, 95.999,
								96.0, 96.001, 108.0, 123.999, 124.0, 128.0, 160.0]:
							var point: Vector2 = focus + direction * distance
							var key := Vector2i(floori(point.x / plane.size.x),
								floori(point.y / plane.size.y))
							var tile_delta: Vector2i = key - base
							var near_present := maxi(absi(tile_delta.x), absi(tile_delta.y)) <= Gen.VIEW_R
							if near_present and water.visibility_range_end > 0.0:
								var tile_center := Vector3((key.x + 0.5) * plane.size.x,
									Gen.WATER_Y, (key.y + 0.5) * plane.size.y)
								near_present = camera.distance_to(tile_center) \
									< water.visibility_range_end - water.visibility_range_end_margin
							var far_complete := near_fade <= 0.0 or smoothstep(
								near_fade - band, near_fade + band, point.distance_to(focus)) >= 0.999999
							sampled += 1
							if not near_present and not far_complete:
								uncovered += 1
								if first_gap.is_empty():
									first_gap = "focus=%s point=%s camera=%s" % [focus, point, camera]
	_expect(uncovered == 0, "normal near tiles and coarse water must cover every boundary/camera sample: " + first_gap)
	print("WATER_COVERAGE_BENCHMARK samples=%d gaps=%d far_complete_m=%.3f near_camera_cull_m=%.3f" \
		% [sampled, uncovered, near_fade + band, water.visibility_range_end])
	for handoff in [Vector2(0, Gen.STRATOS_NEAR_FADE), Vector2.ZERO,
			Vector2(Gen.SKYLINE_NEAR_FADE, Gen.STRATOS_NEAR_FADE)]:
		Visuals.set_altitude_lod_handoffs(handoff.x, handoff.y)
		_expect(is_equal_approx(float(material.get_shader_parameter("near_fade")), near_fade) \
			and is_equal_approx(float(material.get_shader_parameter("fade_band")), band) \
			and is_equal_approx(float(material.get_shader_parameter("far_fade")), handoff.x) \
			and is_equal_approx(float(Visuals.skyline_water_material().get_shader_parameter("near_fade")), handoff.x),
			"altitude handoff must preserve near-water coverage and the complementary far-water boundary")
	_expect(is_equal_approx(float(Visuals.far_ground_material().get_shader_parameter("near_fade")), Gen.HORIZON_NEAR_FADE) \
		and is_equal_approx(float(Visuals.far_jungle_material().get_shader_parameter("near_fade")), Gen.HORIZON_NEAR_FADE),
		"water repair must preserve terrain and canopy fade distances")
	chunk.free()


func _test_full_sphere_nadir_palette() -> void:
	var sky_top := Color(0.075, 0.29, 0.64)
	var sky_horizon := Color(0.58, 0.77, 0.89)
	var low := Visuals.full_sphere_nadir_palette(sky_top, sky_horizon,
		1.0, 0.0)
	var high := Visuals.full_sphere_nadir_palette(sky_top, sky_horizon,
		1.0, 3000.0)
	var low_bottom: Color = low.bottom
	var high_bottom: Color = high.bottom
	var horizon_rgb := Vector3(sky_horizon.r, sky_horizon.g, sky_horizon.b)
	var low_rgb := Vector3(low_bottom.r, low_bottom.g, low_bottom.b)
	var high_rgb := Vector3(high_bottom.r, high_bottom.g, high_bottom.b)
	_expect(high_bottom.get_luminance() > 0.12,
		"aircraft nadir palette must never collapse to a black spot")
	_expect(high_rgb.distance_to(horizon_rgb) < low_rgb.distance_to(horizon_rgb),
		"lower sky must blend toward atmospheric color with clearance")
