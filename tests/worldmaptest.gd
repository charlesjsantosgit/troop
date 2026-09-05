extends Node
## Focused spherical-map projection, interaction, and bounded-cache gate.
## Run with:
##   godot --headless --path . res://scenes/main.tscn -- worldmaptest

var _total := 0
var _fails := 0


class MarkerActor:
	extends Node3D
	var peer_id := 0
	var display_name := ""
	var _yaw := 0.0
	var rig: Node


func _check(condition: bool, label: String, detail := "") -> void:
	_total += 1
	if condition:
		print("  [ok] " + label)
	else:
		_fails += 1
		print("  [FAIL] " + label + ((" :: " + detail) if not detail.is_empty()
			else ""))


func _marker_for_id(markers: Array[Dictionary], peer_id: int) -> Dictionary:
	for marker in markers:
		if int(marker.id) == peer_id:
			return marker
	return {}


func _check_minimap_visibility(main) -> void:
	var hud: HUD = main.hud
	var minimap: Minimap = hud.minimap
	var saved_hud_visible := hud.visible
	var saved_map_visible := minimap.visible
	var saved_mode := minimap.mode
	var saved_speed_text := hud.speed_label.text
	var saved_tiles := minimap._tiles
	var saved_queue := minimap._bake_queue
	var saved_seed := minimap._baked_seed
	var saved_rows := minimap._last_baked_rows
	var saved_pixels := minimap._last_baked_pixels
	var saved_tier := minimap._last_required_tier
	var saved_keys := minimap._last_required_keys
	var local_id := Net.local_id()
	var had_realm := Net.player_realms.has(local_id)
	var saved_realm := Net.player_realm(local_id)
	# An untouched cache proves no hidden tile allocation or generator sampling
	# occurred, even if this Control's own visibility flag remains true.
	minimap._tiles = [{}, {}, {}]
	minimap._bake_queue = []
	minimap._baked_seed = -2147483647
	minimap._last_baked_rows = 99
	minimap.mode = 0
	minimap.visible = true
	Net.player_realms[local_id] = Net.PlayerRealm.EARTH
	hud.visible = false
	hud.speed_label.text = "Hidden HUD must remain idle"
	hud._process(1.0 / 60.0)
	minimap._process(1.0 / 60.0)
	_check(hud.speed_label.text == "Hidden HUD must remain idle" \
			and minimap._baked_seed == -2147483647 \
			and minimap._bake_queue.is_empty() \
			and minimap._last_baked_rows == 0 and minimap._last_baked_pixels == 0,
		"hidden HUD CanvasLayer performs no HUD refresh or minimap terrain generation")
	hud.visible = true
	Net.player_realms[local_id] = Net.PlayerRealm.TRANSIT
	hud._process(1.0 / 60.0)
	var transit_hidden := not minimap.visible
	# Also cover a realm packet arriving before HUD updates its visibility.
	minimap.visible = true
	minimap._process(1.0 / 60.0)
	_check(transit_hidden and minimap._baked_seed == -2147483647 \
			and minimap._bake_queue.is_empty() and minimap._last_baked_pixels == 0,
		"transit hides the Earth minimap and rejects terrain generation before HUD catches up")
	Net.player_realms[local_id] = Net.PlayerRealm.EARTH
	hud._process(1.0 / 60.0)
	minimap._process(1.0 / 60.0)
	_check(minimap.visible and minimap._baked_seed == Gen.world_seed \
			and minimap._last_baked_pixels > 0 \
			and minimap._last_baked_rows <= Minimap.ROWS_PER_FRAME,
		"restoring the visible Earth HUD resumes bounded minimap refinement")
	minimap._tiles = saved_tiles
	minimap._bake_queue = saved_queue
	minimap._baked_seed = saved_seed
	minimap._last_baked_rows = saved_rows
	minimap._last_baked_pixels = saved_pixels
	minimap._last_required_tier = saved_tier
	minimap._last_required_keys = saved_keys
	minimap.mode = saved_mode
	minimap.visible = saved_map_visible
	hud.visible = saved_hud_visible
	hud.speed_label.text = saved_speed_text
	if had_realm:
		Net.player_realms[local_id] = saved_realm
	else:
		Net.player_realms.erase(local_id)


func _check_lunar_minimap(main) -> void:
	var hud: HUD = main.hud
	var minimap: Minimap = hud.minimap
	var moon: MoonWorld = main.expedition_manager.moon_world
	var player: MonkeyPlayer = main.world.local_player
	var local_id := Net.local_id()
	var had_realm := Net.player_realms.has(local_id)
	var saved_realm := Net.player_realm(local_id)
	var saved_transform := player.global_transform
	var saved_rig_transform := player.rig.yaw_node.transform
	var saved_hud_visible := hud.visible
	var saved_map_visible := minimap.visible
	var saved_mode := minimap.mode
	var saved_zoom := minimap.zoom_multiplier
	# Run synchronously so these diagnostic teleports cannot advance gameplay,
	# survival, the camera or network movement before the saved state is restored.
	hud.visible = true
	minimap.mode = 0
	minimap.zoom_multiplier = 1.0
	Net.player_realms[local_id] = Net.PlayerRealm.EARTH
	minimap._sync_map_context()
	var earth_cache_key := minimap.map_cache_key()
	minimap._request_visible_tiles()
	var old_texture: ImageTexture = minimap._tiles[minimap._last_required_tier][
		minimap._last_required_keys.keys()[0]].texture
	Net.player_realms[local_id] = Net.PlayerRealm.MOON
	player.global_position = moon.to_global(moon.actor_landing_position())
	hud._process(1.0 / 60.0)
	minimap._process(1.0 / 60.0)
	_check(minimap.visible and minimap.map_realm() == Net.PlayerRealm.MOON
		and minimap._baked_seed == moon.moon_seed
		and minimap.map_cache_key() != earth_cache_key,
		"Moon realm selects a visible lunar minimap with its own seeded cache")
	var lunar_textures_new := true
	for tier_cache in minimap._tiles:
		for tile in tier_cache.values():
			lunar_textures_new = lunar_textures_new and tile.texture != old_texture
	_check(lunar_textures_new and minimap._last_baked_pixels > 0
		and minimap._last_baked_rows <= Minimap.MOON_ROWS_PER_FRAME,
		"realm change discards Earth terrain and starts bounded lunar refinement",
		"rows=%d elapsed_us=%d" % [minimap._last_baked_rows, minimap._last_bake_usec])
	_check(minimap.window_meters() >= 240.0 and minimap.window_meters() < 245.0,
		"Moon zoom uses radial ground altitude instead of the realm's 48 km world height",
		"window=%.3f" % minimap.window_meters())
	minimap.zoom_multiplier = 0.4
	var close_window := minimap.window_meters()
	minimap.zoom_multiplier = 2.6
	var wide_window := minimap.window_meters()
	_check(close_window >= 96.0 and close_window < 100.0
		and wide_window > 600.0 and wide_window <= 720.0,
		"Moon manual zoom spans useful nearby beds through distant exploration sites")
	minimap.zoom_multiplier = 1.0
	var walking_chart_key := minimap.map_cache_key()
	var target_coordinate := Vector2(20.0, -15.0)
	var target_point := moon.to_global(moon.surface_position(minimap.moon_direction_at(target_coordinate)))
	var all_walking_stable := true
	var max_walking_error := 0.0
	var max_bake_usec := minimap._last_bake_usec
	var max_bake_rows := minimap._last_baked_rows
	for distance in [0.0, 0.05, 0.10, 0.20, 0.40, 0.80, 2.0, 4.0, 8.0]:
		player.global_position = moon.to_global(moon.surface_position(
			minimap.moon_direction_at(Vector2(distance, 0.0)), 0.8))
		minimap._process(1.0 / 60.0)
		var screen_center := Vector2.ONE * minimap.map_px() * 0.5
		var scale_px := minimap.map_px() / 240.0
		var expected_target := screen_center + (target_coordinate - Vector2(distance, 0.0)) * scale_px
		var actual_target := minimap._world_to_map(target_point, player.global_position, 240.0)
		max_walking_error = maxf(max_walking_error, actual_target.distance_to(expected_target) / scale_px)
		all_walking_stable = all_walking_stable and minimap.map_cache_key() == walking_chart_key
		all_walking_stable = all_walking_stable and minimap._world_to_map(
			player.global_position, player.global_position, 240.0).distance_to(screen_center) < 0.0001
		max_bake_usec = maxi(max_bake_usec, minimap._last_bake_usec)
		max_bake_rows = maxi(max_bake_rows, minimap._last_baked_rows)
	_check(all_walking_stable and max_walking_error < 0.03
		and max_bake_rows <= Minimap.MOON_ROWS_PER_FRAME,
		"small lunar steps keep the player centered and landmarks continuous without rebuilding the chart",
		"max_marker_error_m=%.6f max_rows=%d" % [max_walking_error, max_bake_rows])

	var directions: Array[Vector3] = [Vector3.UP, Vector3.RIGHT, Vector3.DOWN,
		Vector3.LEFT, Vector3.FORWARD, Vector3.BACK,
		Vector3(0.001, -1, 0.001).normalized(), Vector3(1, 1, 1).normalized()]
	var all_charts_valid := true
	var max_round_trip := 0.0
	var max_center_error := 0.0
	var all_headings_valid := true
	var first_chart_key := minimap.map_cache_key()
	for direction in directions:
		player.global_transform = Transform3D(MoonWorld.surface_basis(direction),
			moon.to_global(moon.surface_position(direction, 0.8)))
		minimap._sync_map_context()
		var center_distance := minimap.moon_map_coordinates(player.global_position).length()
		var expected_distance := minimap._moon_chart_up.angle_to(direction) * MoonWorld.PLAYABLE_RADIUS_METERS
		max_center_error = maxf(max_center_error, absf(center_distance - expected_distance))
		all_charts_valid = all_charts_valid and center_distance \
			<= Minimap.MOON_CHART_REANCHOR_ANGLE * MoonWorld.PLAYABLE_RADIUS_METERS + 0.03
		var chart_basis := Basis(minimap._moon_chart_east, minimap._moon_chart_up,
			minimap._moon_chart_south)
		all_charts_valid = all_charts_valid and chart_basis.is_finite()
		all_charts_valid = all_charts_valid and absf(chart_basis.determinant() - 1.0) < 0.0001
		for coordinate in [Vector2(17, -23), Vector2(-45, 32), Vector2(120, 90)]:
			var point := moon.to_global(moon.surface_position(
				minimap.moon_direction_at(coordinate)))
			max_round_trip = maxf(max_round_trip,
				minimap.moon_map_coordinates(point).distance_to(coordinate))
		player.rig.yaw_node.global_basis = chart_basis
		all_headings_valid = all_headings_valid and minimap.local_arrow_forward().dot(Vector2.UP) > 0.995
		player.rig.yaw_node.global_basis = Basis(minimap._moon_chart_up, PI * 0.5) * chart_basis
		all_headings_valid = all_headings_valid and minimap.local_arrow_forward().dot(Vector2.LEFT) > 0.995
	_check(all_charts_valid and max_center_error < 0.03,
		"lunar chart follows both poles, the far side and cube-face seams without singularities",
		"center_error=%.5f" % max_center_error)
	_check(max_round_trip < 0.04,
		"lunar map coordinates round-trip nearby ground across the complete sphere",
		"max_error_m=%.5f" % max_round_trip)
	_check(all_headings_valid,
		"local map arrow follows the monkey's actual tangent facing at every hemisphere")
	_check(minimap.map_cache_key() != first_chart_key and minimap._bake_queue.is_empty()
		and minimap._tiles[0].is_empty() and minimap._tiles[1].is_empty() and minimap._tiles[2].is_empty(),
		"crossing hemispheres retires old chart tiles before requesting new local terrain")

	# Independent geometry evidence: sample the visible terrain mesh vertices,
	# not a second call to the minimap's radial sampling implementation.
	var mesh_arrays := moon.terrain_mesh.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
	var max_ground_error := 0.0
	var minimum_height := INF
	var maximum_height := -INF
	for vertex_index in range(0, vertices.size(), 127):
		var vertex := vertices[vertex_index]
		var direction := (vertex - MoonWorld.PLAYABLE_CENTER).normalized()
		player.global_position = moon.to_global(moon.surface_position(direction, 0.8))
		minimap._sync_map_context()
		var map_coordinate := minimap.moon_map_coordinates(moon.to_global(vertex))
		var expected_height := vertex.distance_to(MoonWorld.PLAYABLE_CENTER) - MoonWorld.PLAYABLE_RADIUS_METERS
		max_ground_error = maxf(max_ground_error, absf(minimap.map_height_at(map_coordinate) - expected_height))
		minimum_height = minf(minimum_height, expected_height)
		maximum_height = maxf(maximum_height, expected_height)
	_check(max_ground_error < 0.04 and maximum_height - minimum_height > 2.0,
		"Moon minimap relief matches the rendered crater mesh across the whole globe",
		"max_error_m=%.5f relief_m=%.3f" % [max_ground_error, maximum_height - minimum_height])
	print("  MOON_MINIMAP_BENCHMARK max_bake_rows=%d max_bake_us=%d walking_error_m=%.6f round_trip_error_m=%.6f terrain_error_m=%.6f" % [
		max_bake_rows, max_bake_usec, max_walking_error, max_round_trip, max_ground_error])
	var crater_color := minimap._moon_ground_color(minimum_height)
	_check(crater_color.r > crater_color.b * 0.80 and crater_color.g > crater_color.b * 0.85,
		"negative lunar crater elevations render as regolith rather than Earth water")

	player.global_position = moon.to_global(moon.actor_landing_position())
	minimap._sync_map_context()
	var landmarks := minimap.marker_snapshot()
	var landmark_ids: Dictionary = {}
	var landmarks_grounded := true
	for marker in landmarks:
		if str(marker.kind) != "landmark":
			continue
		landmark_ids[str(marker.id)] = true
		if str(marker.id) != "rocket":
			landmarks_grounded = landmarks_grounded and absf(moon.altitude_at(marker.position)) < 0.03
	_check(landmark_ids.size() == 7 and landmark_ids.has("farm") and landmark_ids.has("market")
		and landmark_ids.has("aging") and landmark_ids.has("observatory")
		and landmark_ids.has("relay") and landmark_ids.has("crystal_garden") and landmark_ids.has("rocket")
		and landmarks_grounded,
		"lunar minimap marks the grounded farm, market, cellar, three discoveries and return pad")
	var peers: Array[MarkerActor] = []
	for realm in [Net.PlayerRealm.EARTH, Net.PlayerRealm.MOON, Net.PlayerRealm.TRANSIT]:
		var actor := MarkerActor.new()
		actor.peer_id = 920_001 + realm
		actor.display_name = "Realm Scout %d" % realm
		main.world.add_child(actor)
		actor.global_position = player.global_position + Vector3.RIGHT * 5.0
		main.world.puppets[actor.peer_id] = actor
		Net.names[actor.peer_id] = actor.display_name
		Net.player_realms[actor.peer_id] = realm
		peers.append(actor)
	var lunar_peers: Array[int] = []
	for marker in minimap.marker_snapshot():
		if str(marker.kind) == "player":
			lunar_peers.append(int(marker.id))
	_check(lunar_peers.has(920_001 + Net.PlayerRealm.MOON)
		and not lunar_peers.has(920_001 + Net.PlayerRealm.EARTH)
		and not lunar_peers.has(920_001 + Net.PlayerRealm.TRANSIT),
		"lunar minimap shows Moon peers and excludes Earth and cabin occupants")
	minimap._process(1.0 / 60.0)
	var rows_before_hide := 0
	for tier_cache in minimap._tiles:
		for tile in tier_cache.values():
			rows_before_hide += int(tile.rows)
	hud.visible = false
	minimap._process(1.0 / 60.0)
	var rows_after_hide := 0
	for tier_cache in minimap._tiles:
		for tile in tier_cache.values():
			rows_after_hide += int(tile.rows)
	_check(minimap._last_baked_pixels == 0 and rows_before_hide == rows_after_hide,
		"hidden Moon HUD performs no terrain refinement")
	hud.visible = true
	var lunar_cache_key := minimap.map_cache_key()
	Net.player_realms[local_id] = Net.PlayerRealm.TRANSIT
	hud._process(1.0 / 60.0)
	minimap._process(1.0 / 60.0)
	_check(not minimap.visible and minimap._last_baked_pixels == 0
		and minimap.map_cache_key() == lunar_cache_key,
		"return transit hides lunar map and leaves its cache idle")
	Net.player_realms[local_id] = Net.PlayerRealm.EARTH
	player.global_transform = saved_transform
	hud._process(1.0 / 60.0)
	minimap._process(1.0 / 60.0)
	var earth_peers: Array[int] = []
	var earth_landmarks := 0
	for marker in minimap.marker_snapshot():
		if str(marker.kind) == "player":
			earth_peers.append(int(marker.id))
		else:
			earth_landmarks += 1
	_check(minimap.map_realm() == Net.PlayerRealm.EARTH
		and minimap.map_cache_key() == earth_cache_key and minimap._moon == null
		and earth_peers.has(920_001 + Net.PlayerRealm.EARTH)
		and not earth_peers.has(920_001 + Net.PlayerRealm.MOON)
		and not earth_peers.has(920_001 + Net.PlayerRealm.TRANSIT) and earth_landmarks == 0,
		"Earth return restores native map scale, Earth peers and a fresh Earth-only cache")
	for actor in peers:
		main.world.puppets.erase(actor.peer_id)
		Net.player_realms.erase(actor.peer_id)
		Net.names.erase(actor.peer_id)
		actor.free()
	player.global_transform = saved_transform
	player.rig.yaw_node.transform = saved_rig_transform
	minimap.mode = saved_mode
	minimap.zoom_multiplier = saved_zoom
	minimap.visible = saved_map_visible
	hud.visible = saved_hud_visible
	if had_realm:
		Net.player_realms[local_id] = saved_realm
	else:
		Net.player_realms.erase(local_id)
	minimap._sync_map_context()


func _check_minimap_bake_budget(main) -> void:
	var minimap: Minimap = main.hud.minimap
	minimap._reset_tiles()
	# This unvisited region has cold terrain caches and a multi-tile Earth view,
	# matching the return-to-Earth hitch exposed by the native capture.
	minimap._request_tiles_for_view(Vector2(-18423.0, 11781.0), 745.0, 0.0, 300.0)
	var max_usec := 0
	var max_chunk_usec := 0
	var max_pixels := 0
	var preview_frame := -1
	var work_bounded := true
	var previews_before_exact := true
	var uploads_batched := true
	for frame in range(120):
		minimap._bake_rows()
		max_usec = maxi(max_usec, minimap._last_bake_usec)
		max_chunk_usec = maxi(max_chunk_usec, minimap._last_bake_chunk_usec)
		max_pixels = maxi(max_pixels, minimap._last_baked_pixels)
		work_bounded = work_bounded and minimap._last_baked_pixels > 0
		work_bounded = work_bounded and minimap._last_bake_usec \
			<= Minimap.BAKE_TIME_BUDGET_USEC + minimap._last_bake_chunk_usec + 1500
		uploads_batched = uploads_batched and minimap._last_texture_uploads \
			<= minimap._last_required_keys.size()
		if not minimap.preview_ready():
			for key in minimap._last_required_keys:
				previews_before_exact = previews_before_exact \
					and int(minimap._tiles[minimap._last_required_tier][key].cursor) == 0
		elif preview_frame < 0:
			preview_frame = frame + 1
		if preview_frame > 0 and frame >= 20:
			break
	_check(work_bounded and uploads_batched and max_usec < 8000
		and max_pixels < Minimap.ROWS_PER_FRAME * Minimap.TILE_PX
		and Minimap.BAKE_CHUNK_PIXELS <= 8,
		"cold Earth minimap yields between pixel chunks and batches texture uploads",
		"max_us=%d chunk_us=%d pixels=%d" % [max_usec, max_chunk_usec, max_pixels])
	_check(preview_frame > 0 and previews_before_exact and not minimap._bake_queue.is_empty(),
		"every visible Earth tile gets a coarse terrain preview before exact refinement",
		"preview_frames=%d" % preview_frame)
	# Interrupt on both sides of row boundaries; the north/west hillshade state
	# must survive every yield and produce precisely the same final pixels.
	var continuous := {"image": Image.create(Minimap.TILE_PX, Minimap.TILE_PX, false, Image.FORMAT_RGB8),
		"cursor": 0, "rows": 0, "prev_heights": PackedFloat32Array()}
	var interrupted := {"image": Image.create(Minimap.TILE_PX, Minimap.TILE_PX, false, Image.FORMAT_RGB8),
		"cursor": 0, "rows": 0, "prev_heights": PackedFloat32Array()}
	var key := Vector2i(-48, 30)
	minimap._bake_tile_pixels(0, key, continuous, Minimap.TILE_PX * 2 + 9)
	for count in [7, 8, 80, 3, 94, 9]:
		minimap._bake_tile_pixels(0, key, interrupted, count)
	_check(interrupted.cursor == continuous.cursor and interrupted.rows == continuous.rows
		and interrupted.image.get_data() == continuous.image.get_data(),
		"resuming partial Earth rows preserves exact terrain colors and hillshade")
	print("  EARTH_MINIMAP_BENCHMARK max_bake_us=%d max_chunk_us=%d max_samples=%d preview_frames=%d required_tiles=%d" % [
		max_usec, max_chunk_usec, max_pixels, preview_frame, minimap._last_required_keys.size()])
	minimap._reset_tiles()


func run(main) -> void:
	print("WORLDMAPTEST begin")
	var c := 1000.0
	var north := WorldMap.canonical_planet_xz(Vector2(25.0, 260.0), c)
	_check(north.is_equal_approx(Vector2(-475.0, 240.0)),
		"north-pole crossing reflects latitude and shifts longitude",
		str(north))
	var south := WorldMap.canonical_planet_xz(Vector2(25.0, -260.0), c)
	_check(south.is_equal_approx(Vector2(-475.0, -240.0)),
		"south-pole crossing reflects latitude and shifts longitude",
		str(south))
	var full_meridian := WorldMap.canonical_planet_xz(Vector2(25.0, 760.0), c)
	_check(full_meridian.is_equal_approx(Vector2(25.0, -240.0)),
		"full meridian traversal returns to original longitude", str(full_meridian))
	var near_seam := WorldMap.nearest_equivalent_xz(Vector2(-490.0, 0.0),
		Vector2(490.0, 0.0), c)
	_check(near_seam.is_equal_approx(Vector2(510.0, 0.0)),
		"date-line neighbour uses nearest seamless copy", str(near_seam))
	var near_pole := WorldMap.nearest_equivalent_xz(north,
		Vector2(25.0, 260.0), c)
	_check(near_pole.is_equal_approx(Vector2(25.0, 260.0)),
		"pole-reflected neighbour remains locally continuous", str(near_pole))

	var geographic := Vector2(deg_to_rad(123.4), deg_to_rad(-42.5))
	var world_xz := WorldMap.lon_lat_to_world_xz(geographic, c)
	var round_trip := WorldMap.world_xz_to_lon_lat(world_xz, c)
	_check(round_trip.distance_to(geographic) < 0.00001,
		"longitude/latitude conversion round-trips", str(round_trip))
	var front := WorldMap.globe_projection(geographic, geographic,
		Vector2(500, 400), 300.0)
	_check(bool(front.visible) and front.position.distance_to(Vector2(500, 400))
		< 0.001 and absf(float(front.depth) - 1.0) < 0.0001,
		"globe centre projects to front of sphere", str(front))
	var back := WorldMap.globe_projection(
		Vector2(geographic.x + PI, -geographic.y), geographic,
		Vector2(500, 400), 300.0)
	_check(not bool(back.visible) and float(back.depth) < -0.99,
		"antipode is hidden behind globe", str(back))

	var anchored := WorldMap.zoom_anchored_center(Vector2.ZERO,
		Vector2(1000, 250), Rect2(0, 0, 1000, 500), 1000.0, 500.0)
	_check(anchored.is_equal_approx(Vector2(250, 0)),
		"cursor-anchored zoom preserves pointed world location", str(anchored))
	_check(WorldMap.marker_forward(0.0).distance_to(Vector2(0, -1)) < 0.0001,
		"marker arrow exposes actor facing direction")

	var hd_size := Vector2(1872, 960)
	var bounded_tier := WorldMap.bounded_tier_for_view(Vector2.ZERO, hd_size,
		8000.0)
	var requested := WorldMap.required_tile_keys(Vector2.ZERO, hd_size, 8000.0,
		bounded_tier)
	_check(requested.size() <= WorldMap.CACHE_TILE_LIMIT,
		"fullscreen tile request fits global cache cap",
		"tier=%d keys=%d" % [bounded_tier, requested.size()])
	var uhd_tier := WorldMap.bounded_tier_for_view(Vector2.ZERO,
		Vector2(3792, 2040), 8000.0)
	var uhd_requested := WorldMap.required_tile_keys(Vector2.ZERO,
		Vector2(3792, 2040), 8000.0, uhd_tier)
	_check(uhd_requested.size() <= WorldMap.CACHE_TILE_LIMIT,
		"4K view coarsens instead of allocating unbounded tiles",
		"tier=%d keys=%d" % [uhd_tier, uhd_requested.size()])
	_check(WorldMap.LOCAL_PREVIEW_GRIDS[-1] == WorldMap.TILE_PX,
		"terrain tiles refine to their real sample resolution")

	var atlas: WorldMap = main.hud.world_map
	_check(atlas != null and not atlas.is_open(),
		"HUD owns an initially closed planetary atlas")
	_check_minimap_visibility(main)
	_check_lunar_minimap(main)
	_check_minimap_bake_budget(main)

	# Realm membership comes from Net's replicated authority state, never the
	# actor's height or whichever celestial body happens to be selected. Exercise
	# local and remote entries without advancing a frame or triggering Moon baking.
	var original_body := atlas.selected_body
	var local_id := Net.local_id()
	var had_local_realm := Net.player_realms.has(local_id)
	var original_local_realm := Net.player_realm(local_id)
	Net.player_realms[local_id] = Net.PlayerRealm.EARTH
	var earth_id := 910_001
	var moon_id := 910_002
	var transit_id := 910_003
	var realm_actors: Array[MarkerActor] = []
	for definition in [
			[earth_id, "Earth Scout", Net.PlayerRealm.EARTH,
				Vector3(180.0, 3.0, -70.0), 0.6],
			[moon_id, "Moon Scout", Net.PlayerRealm.MOON,
				Vector3(64.0, Net.MOON_WORLD_ORIGIN_Y + 3.0, -32.0), 0.3],
			[transit_id, "Cabin Scout", Net.PlayerRealm.TRANSIT,
				Vector3.ZERO, -0.4],
		]:
		var actor := MarkerActor.new()
		actor.peer_id = int(definition[0])
		actor.display_name = str(definition[1])
		actor.position = definition[3]
		actor._yaw = float(definition[4])
		main.world.add_child(actor)
		main.world.puppets[actor.peer_id] = actor
		Net.names[actor.peer_id] = actor.display_name
		Net.player_realms[actor.peer_id] = int(definition[2])
		realm_actors.append(actor)
	var authoritative_markers := atlas.marker_snapshot()
	var earth_marker := _marker_for_id(authoritative_markers, earth_id)
	var moon_marker := _marker_for_id(authoritative_markers, moon_id)
	var transit_marker := _marker_for_id(authoritative_markers, transit_id)
	_check(int(earth_marker.get("realm", -1)) == Net.PlayerRealm.EARTH \
			and int(moon_marker.get("realm", -1)) == Net.PlayerRealm.MOON \
			and int(transit_marker.get("realm", -1)) == Net.PlayerRealm.TRANSIT,
		"marker snapshots carry each peer's authoritative realm",
		str(authoritative_markers))
	var earth_markers := atlas.markers_for_body(WorldMap.CelestialBody.EARTH)
	var moon_markers := atlas.markers_for_body(WorldMap.CelestialBody.MOON)
	_check(not _marker_for_id(earth_markers, local_id).is_empty() \
			and not _marker_for_id(earth_markers, earth_id).is_empty() \
			and _marker_for_id(earth_markers, moon_id).is_empty() \
			and _marker_for_id(earth_markers, transit_id).is_empty(),
		"Earth atlas and globe expose only authoritative Earth markers",
		str(earth_markers))
	_check(not _marker_for_id(moon_markers, moon_id).is_empty() \
			and _marker_for_id(moon_markers, local_id).is_empty() \
			and _marker_for_id(moon_markers, earth_id).is_empty() \
			and _marker_for_id(moon_markers, transit_id).is_empty(),
		"selected Moon exposes Moon markers and hides Earth/transit peers",
		str(moon_markers))
	_check(not WorldMap.realm_visible_on_body(Net.PlayerRealm.TRANSIT,
			WorldMap.CelestialBody.EARTH) \
			and not WorldMap.realm_visible_on_body(Net.PlayerRealm.TRANSIT,
				WorldMap.CelestialBody.MOON),
		"transit has no surface-map representation")

	for actor in realm_actors:
		main.world.puppets.erase(actor.peer_id)
		Net.player_realms.erase(actor.peer_id)
		Net.names.erase(actor.peer_id)
		actor.queue_free()
	if had_local_realm:
		Net.player_realms[local_id] = original_local_realm
	else:
		Net.player_realms.erase(local_id)
	atlas.selected_body = original_body

	_check(InputMap.has_action("world_map"), "X world-map input is registered")
	atlas.open_map()
	_check(atlas.is_open() and atlas.size.x <= 1380 and atlas.size.y <= 920,
		"atlas opens as a responsive bounded panel")
	var camera_before := int(main.world.local_player.cam.view_mode)
	var event := InputEventAction.new()
	event.action = "camera_mode"
	event.pressed = true
	main._unhandled_input(event)
	_check(int(main.world.local_player.cam.view_mode) == camera_before,
		"open atlas consumes gameplay shortcuts")
	atlas.focus_moon()
	var span := atlas._target_span_m
	atlas.zoom_at(atlas.map_rect().get_center(), .72)
	_check(atlas._target_span_m < span, "Moon terrain supports local cartographic zoom")
	atlas.close_map()
	_check(not atlas.is_open() and not atlas.visible, "closing atlas restores gameplay presentation")
	print("WORLDMAPTEST %d/%d %s" % [_total - _fails, _total, "PASS" if _fails == 0 else "FAIL"])
	get_tree().quit(0 if _fails == 0 else 1)
