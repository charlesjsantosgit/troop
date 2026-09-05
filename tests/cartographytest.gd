extends Node
const Source = preload("res://scripts/cartography_source.gd")
const Plan = preload("res://scripts/city_plan.gd")
const OUTPUT := "res://artifacts/cartography"
var checks := 0
var failures := 0
var report: Dictionary = {}

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("CARTOGRAPHY %s %s" % ["PASS" if ok else "FAIL", label])

func run(main: Node, capture := false) -> void:
	var map: WorldMap = main.hud.world_map
	var source := Source.new()
	map._sync_seed()
	source.configure(map._source_options())
	check(source.earth != Gen and source.earth.world_seed == Gen.world_seed,
		"worker owns independent generator caches with the actual session seed")
	var points: Array[Vector2] = [Vector2.ZERO, Vector2(650, 0), Vector2(-600, -400),
		Plan.CENTER, Plan.POND_CENTER, Plan.POND_CENTER + Vector2(20, 0),
		Gen.airstrip_center, Vector2(2500, -900), Vector2(180000, 110000),
		Vector2(Gen.PLANET_HALF_CIRCUMFERENCE + 23, 12), Vector2(73, Gen.PLANET_POLE_DISTANCE + 31)]
	for p in points:
		var value := source.sample(0, p)
		check(absf(float(value.elevation) - Gen.height(p.x, p.y)) < .002,
			"map elevation matches Earth terrain at " + str(p))
	check(source.sample(0, Plan.POND_CENTER).water and not source.sample(0, Plan.PARK_CENTER+Vector2(0,-900)).water,
		"pond water belongs to the actual basin and the dry garden stays dry")
	var a := source.sample(0, Vector2(180000, 110000))
	var other := map._source_options().duplicate()
	other.seed = int(other.seed) + 17
	source.configure(other)
	var b := source.sample(0, Vector2(180000, 110000))
	check(absf(float(a.elevation) - float(b.elevation)) > .01 or a.color != b.color,
		"terrain content responds to the world seed rather than an imported continent image")
	source.configure(map._source_options())
	var moon := map.source_moon()
	for d: Vector3 in [Vector3.UP, Vector3.DOWN, Vector3.RIGHT, Vector3.LEFT,
		Vector3.FORWARD, Vector3.BACK, Vector3(.4, -.7, .3).normalized()]:
		var coordinate := Source.lunar_coordinate(d)
		check(Source.lunar_direction(coordinate).distance_to(d) < .00001,
			"lunar coordinate roundtrip preserves hemisphere " + str(d))
		var measured := source.sample(1, coordinate)
		var exact := moon.surface_position(d).distance_to(MoonWorld.PLAYABLE_CENTER) - MoonWorld.PLAYABLE_RADIUS_METERS
		check(absf(float(measured.elevation) - exact) < .002,
			"Moon relief uses actual welded collision triangles " + str(d))
	var circumference := map.planet_circumference_m()
	for reference: Vector2 in [Vector2(0, 0), Vector2(circumference * 2.2, 0), Vector2(0, circumference * .7)]:
		var p := Vector2(-circumference * .49, circumference * .2)
		check(map.nearest_equivalent_xz(p, reference, circumference).distance_to(Gen.nearest_world_image(p, reference)) < 2,
			"map wrap agrees with gameplay nearest image at " + str(reference))
	var park:=Rect2(Plan.PARK_CENTER-Plan.PARK_HALF_EXTENTS,Plan.PARK_HALF_EXTENTS*2)
	var footprints:=map.city_footprints(park.grow(120))
	check(footprints.size()>100,"large park overlay includes its actual surrounding city parcels")
	var clear:=true
	for footprint in footprints:
		clear=clear and not park.intersects(footprint.rect)
		var actual:=Plan.building(str(footprint.id))
		clear=clear and is_equal_approx(footprint.rect.size.x,actual.size.x) and is_equal_approx(footprint.rect.size.y,actual.size.z)
	check(map.city_minor_roads(park).is_empty(),"no internal road crosses the actual car-free park")
	check(clear,"all surrounding footprint outlines match full physical parcel sizes and leave the entire expanded park clear")
	for key:Vector2i in [Vector2i(0,0),Vector2i(Plan.GRID_WIDTH-1,0),Vector2i(0,Plan.GRID_DEPTH-1),Vector2i(Plan.GRID_WIDTH-1,Plan.GRID_DEPTH-1)]:
		var corner:=Vector2(Plan.MIN_X if key.x==0 else Plan.MAX_X,Plan.MIN_Z if key.y==0 else Plan.MAX_Z)
		var edge_bounds:=Rect2(corner-Vector2.ONE*250,Vector2.ONE*500)
		var outlines:=map.city_footprints(edge_bounds)
		var ids:Dictionary={}
		for outline in outlines:ids[outline.id]=true
		var expected:=0;var complete:=true
		for building in Plan.block_buildings(key):
			var rect:=Rect2(Vector2(building.position.x-building.size.x*.5,building.position.z-building.size.z*.5),Vector2(building.size.x,building.size.z))
			if not rect.intersects(edge_bounds):continue
			expected+=1;complete=complete and ids.has(building.id)
		check(expected>0 and complete,"close map view crossing municipal corner "+str(key)+" retains every intersecting real parcel")
	main.frontier_controller.city.navigate_to(Vector3(Plan.PARK_CENTER.x, 8, Plan.PARK_CENTER.y), "Garden target")
	map.focus_earth()
	var landmarks := map.landmark_snapshot()
	check(landmarks.any(func(m): return m.id == "waypoint" and m.coordinate.distance_to(Plan.PARK_CENTER) < .01),
		"city waypoint appears at its actual coordinate")
	check(landmarks.filter(func(m): return m.kind == "transit").size() == Plan.stops().size(),
		"every real transit stop is available to the atlas")
	check(landmarks.any(func(m): return m.id == "spaceport" and m.coordinate == Gen.airstrip_center),
		"spaceport uses the seeded runway location")
	var hangars := map.airfield_footprints()
	var actual_hangars := Gen.airstrip_hangar_layout()
	var aligned := hangars.size() == actual_hangars.size() and hangars.size() == Gen.AIRSTRIP_HANGAR_COUNT
	for i in range(hangars.size()):
		var center := Vector2.ZERO
		for corner: Vector2 in hangars[i].polygon: center += corner * .25
		var p: Vector3 = actual_hangars[i].pos
		aligned = aligned and center.distance_to(Vector2(p.x, p.z)) < .002
		var axis := Basis(Vector3.UP, float(actual_hangars[i].yaw)).x
		var edge: Vector2 = hangars[i].polygon[1] - hangars[i].polygon[0]
		aligned = aligned and edge.normalized().dot(Vector2(axis.x, axis.z)) > .9999 \
			and absf(edge.length() - float(actual_hangars[i].size.x)) < .002
	check(aligned, "all six hangar footprints share the real seeded positions and orientation")
	map._view_span_m = 850
	var east_edge:=Plan.PARK_CENTER+Vector2(Plan.PARK_HALF_EXTENTS.x+80,0)
	map._center = east_edge + Vector2(circumference, circumference)
	var wrapped_bounds := map.feature_query_bounds()
	check(wrapped_bounds.has_point(east_edge) and not map.city_footprints(wrapped_bounds).is_empty(),
		"city geometry remains present after unfolded longitude and meridian wraps")
	map._center = Plan.PARK_CENTER
	var zooms_correct := true
	for span in [120.0, 850.0, 8000.0, 100000.0, circumference * .2]:
		map._view_span_m = span
		var p := Plan.PARK_CENTER + Vector2(37, -23)
		zooms_correct = zooms_correct and map.screen_to_world(map.world_to_screen(p)).distance_to(p) < maxf(.003, span * .00000015)
		var tier := WorldMap.bounded_tier_for_view(map._center, Vector2(3792, 2040), span)
		zooms_correct = zooms_correct and WorldMap.required_tile_keys(map._center, Vector2(3792, 2040), span, tier).size() <= WorldMap.CACHE_TILE_LIMIT
	check(zooms_correct, "street through continental zoom preserves point projection and the 4K tile budget")

	map.focus_moon()
	check(map.landmark_snapshot().any(func(m): return m.id == "farm" and Source.lunar_direction(m.coordinate).distance_to(MoonColony.facility_direction("farm").normalized()) < .00001),
		"lunar colony marker uses its actual radial facility direction")
	map.open_map()
	map.focus_moon()
	map._center = Vector2(300, -100)
	map._target_center = map._center
	map._target_span_m = 600
	map._view_span_m = 600
	var cursor := map.map_rect().get_center() + Vector2(80, -30)
	var old_world := map.screen_to_world(cursor)
	map.zoom_at(cursor, .72)
	map._center = map._target_center
	map._view_span_m = map._target_span_m
	check(map.screen_to_world(cursor).distance_to(old_world) < .001,
		"Moon zoom preserves the terrain point beneath the cursor")
	check(map._target_span_m < 600, "Moon supports detailed local zoom instead of a forced globe")
	map._center = Vector2.ZERO
	map._target_center = Vector2.ZERO
	map._target_span_m = 600
	map._view_span_m = 600
	var refinement_started := Time.get_ticks_msec()
	await _wait_refinement(map, 2, 30)
	report["initial_local_refinement_ms"] = Time.get_ticks_msec() - refinement_started
	var refined := not map._required_keys.is_empty()
	for key in map._required_keys:
		refined = refined and int(map._tiles[key].stage) >= 2 and map._tiles[key].texture.get_image().has_mipmaps()
	check(refined, "worker publishes real progressively refined mipmapped terrain images")
	check(int(map._source_cache_stats.get("macro_entries", 999999)) <= Source.MACRO_CACHE_LIMIT + 4
		and int(map._source_cache_stats.get("lunar_vertices", 0)) > 0
		and int(map._source_cache_stats.get("lunar_vertices", 999999)) <= 24578,
		"worker retains bounded macro fields and only queried welded lunar vertices")
	check(map._tiles.size() <= WorldMap.CACHE_TILE_LIMIT,
		"progressive tiles remain inside the global cache budget")
	check(map.cache_diagnostics().last_local_samples == 0 and map.cache_diagnostics().last_local_texture_uploads <= 1,
		"terrain work stays off the UI thread with at most one texture publication per frame")
	check(WorldMap.LOCAL_PREVIEW_GRIDS[-1] == WorldMap.TILE_PX and map.texture_filter != CanvasItem.TEXTURE_FILTER_NEAREST,
		"tiles refine to native sample resolution with filtered mipmaps")
	var edge_region := WorldMap.tile_texture_region(Rect2(0, 0, 128, 128), Rect2(0, 0, 128, 128), Vector2(129, 129))
	check(edge_region.position == Vector2(.5, .5) and edge_region.end == Vector2(128.5, 128.5),
		"shared world edges map to exact texture sample centers at every refinement stage")

	var frozen := map._tiles.size()
	map.close_map()
	for i in range(6): await get_tree().process_frame
	check(map._tiles.size() == frozen and not map.is_processing(), "closed map stops tile requests and publications")
	if capture and DisplayServer.get_name() != "headless":
		await _captures(main, map)
	report["checks"] = checks
	report["failures"] = failures
	report["cache"] = map.cache_diagnostics()
	report["viewport"] = str(main.get_viewport().get_visible_rect().size)
	report["adapter"] = RenderingServer.get_video_adapter_name()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var file := FileAccess.open(OUTPUT + "/validation.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	source.dispose()
	print("CARTOGRAPHYTEST %d/%d %s" % [checks - failures, checks, "PASS" if failures == 0 else "FAIL"])
	get_tree().quit(0 if failures == 0 else 1)

func _wait_refinement(map: WorldMap, stage: int, seconds: float) -> bool:
	# Same-body camera changes do not clear last frame's tile keys. Request the
	# current rectangle before observing completion, or a finished previous view
	# can falsely satisfy this wait before the canvas receives its process tick.
	if map.globe_blend() < .995: map._request_visible_tiles()
	var until := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
		if map.globe_blend() > .99:
			if map._atlas_levels[map.selected_body] >= stage: return true
		else:
			var ready := not map._required_keys.is_empty()
			for key in map._required_keys:
				ready = ready and map._tiles.has(key) and int(map._tiles[key].stage) >= stage
			if ready: return true
	return false

func _captures(main: Node, map: WorldMap) -> void:
	map.open_map()
	for spec in [
		{"name": "earth-city", "body": 0, "center": Plan.CENTER, "span": 18500.0, "stage": 3},
		{"name": "earth-park-streets", "body": 0, "center": Plan.PARK_CENTER, "span": 850.0, "stage": 6},
		{"name": "earth-spaceport", "body": 0, "center": Gen.airstrip_center, "span": 3000.0, "stage": 6},
		{"name": "earth-globe", "body": 0, "center": Vector2.ZERO, "span": Gen.PLANET_CIRCUMFERENCE * .7, "stage": 6},
		{"name": "moon-colony", "body": 1, "center": Vector2.ZERO, "span": 700.0, "stage": 6},
		{"name": "moon-globe", "body": 1, "center": Vector2.ZERO, "span": TAU * 450 * .7, "stage": 6},
		{"name": "moon-far-side", "body": 1, "center": Vector2(PI * 450, 0), "span": 600.0, "stage": 6}]:
		map._select_body(int(spec.body))
		map._center = spec.center
		map._target_center = spec.center
		map._view_span_m = spec.span
		map._target_span_m = spec.span
		check(await _wait_refinement(map, int(spec.stage), 50), str(spec.name) + " reaches its requested terrain resolution")
		var updates: Array[int] = []
		var draws: Array[int] = []
		for i in range(90):
			await get_tree().process_frame
			updates.append(map._last_update_usec)
			draws.append(map._last_draw_usec)
		updates.sort()
		draws.sort()
		report[str(spec.name)] = {"update_p95_us": updates[85], "draw_p95_us": draws[85], "cache": map.cache_diagnostics()}
		await RenderingServer.frame_post_draw
		var image := main.get_viewport().get_texture().get_image()
		var filename := OUTPUT + "/" + str(spec.name) + ".png"
		check(image.save_png(filename) == OK, "saved native " + str(spec.name))
		print("CARTOGRAPHY_CAPTURE " + ProjectSettings.globalize_path(filename))
	map.close_map()
