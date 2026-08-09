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

	var atlas: WorldMap = main.hud.world_map
	_check(atlas != null and not atlas.is_open(),
		"HUD owns an initially closed planetary atlas")

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
	var moon_projection := WorldMap.moon_marker_projection(
		realm_actors[1].global_position, realm_actors[1]._yaw,
		Vector2(500.0, 400.0), 300.0, Vector2.ZERO)
	var moon_direction: Vector2 = moon_projection.direction
	var moon_screen_position: Vector2 = moon_projection.position
	var expected_moon_direction := WorldMap.marker_forward(realm_actors[1]._yaw)
	_check(bool(moon_projection.visible) \
			and moon_screen_position.distance_to(Vector2(500.0, 400.0)) < 300.0 \
			and moon_direction.dot(expected_moon_direction) > 0.96,
		"Moon marker projection preserves the monkey's facing direction",
		str(moon_projection))
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

	var sample_started := Time.get_ticks_usec()
	for sample_index in range(64):
		atlas._map_sample(Vector2(sample_index * 71.0, sample_index * -43.0), 8.0)
	var sample_elapsed := Time.get_ticks_usec() - sample_started
	print("  MAP_SAMPLE_BENCHMARK count=64 total_us=%d each_us=%.1f" % [
		sample_elapsed, float(sample_elapsed) / 64.0])
	var coarse_road_visible := false
	for along in [180.0, 320.0, 480.0, 640.0, 920.0]:
		for offset in [18.0, 24.0, 30.0]:
			var fine_road := float(atlas._map_sample(Vector2(along, offset),
				1.0).road)
			var coarse_road := float(atlas._map_sample(Vector2(along, offset),
				64.0).road)
			if fine_road <= 0.12 and coarse_road > 0.12:
				coarse_road_visible = true
				break
		if coarse_road_visible:
			break
	_check(coarse_road_visible,
		"coarse atlas pixels retain narrow roads without widening terrain")
	_check(InputMap.has_action("world_map"), "X world-map input is registered")
	atlas.open_map()
	var camera_mode_before := int(main.world.local_player.cam.view_mode)
	var camera_event := InputEventAction.new()
	camera_event.action = "camera_mode"
	camera_event.pressed = true
	main._unhandled_input(camera_event)
	_check(int(main.world.local_player.cam.view_mode) == camera_mode_before,
		"open atlas consumes gameplay shortcuts")
	atlas._target_span_m = 8000.0
	atlas._view_span_m = 8000.0
	await get_tree().process_frame
	await get_tree().process_frame
	var local_diag := atlas.cache_diagnostics()
	_check(int(local_diag.last_local_samples) <=
		WorldMap.LOCAL_BAKE_SAMPLES_PER_FRAME,
		"local terrain bake work is frame bounded", str(local_diag))
	_check(int(local_diag.tiles) <= maxi(WorldMap.CACHE_TILE_LIMIT,
		int(local_diag.required)), "local tile cache is globally bounded",
		str(local_diag))
	_check(int(local_diag.required) > 0,
		"open local atlas requests visible terrain tiles", str(local_diag))
	var snapshots := atlas.marker_snapshot()
	_check(not snapshots.is_empty() and bool(snapshots[0].local)
		and not str(snapshots[0].name).is_empty(),
		"local player marker includes name and facing metadata", str(snapshots))

	atlas._target_span_m = WorldMap.planet_circumference_m() * 0.24
	atlas._view_span_m = atlas._target_span_m
	await get_tree().process_frame
	await get_tree().process_frame
	var globe_diag := atlas.cache_diagnostics()
	_check(int(globe_diag.last_atlas_samples) <=
		WorldMap.GLOBE_BAKE_SAMPLES_PER_FRAME,
		"equirectangular globe atlas bake is frame bounded", str(globe_diag))
	_check(int(globe_diag.atlas_pixels) == 192 * 96,
		"global atlas stays deliberately small", str(globe_diag))
	_check(atlas.globe_blend() >= 0.99,
		"zooming out switches to whole-Earth globe view")
	atlas.focus_moon()
	_check(atlas.selected_body == WorldMap.CelestialBody.MOON,
		"moon globe is selectable as a destination")
	var moon_preview_diag := atlas.cache_diagnostics()
	_check(int(moon_preview_diag.moon_atlas_pixels) \
			== WorldMap.MOON_ATLAS_SIZE.x * WorldMap.MOON_ATLAS_SIZE.y \
			and int(moon_preview_diag.moon_crater_stamps) \
				>= WorldMap.MOON_HERO_CRATERS.size() \
			and int(moon_preview_diag.moon_crater_stamps) \
				<= WorldMap.MOON_HERO_CRATERS.size() \
					+ WorldMap.MOON_CRATERS_PER_FRAME \
			and int(moon_preview_diag.moon_base_cursor) \
				<= WorldMap.MOON_BASE_SAMPLES_PER_FRAME,
		"lunar globe presents a bounded detailed preview on its first frame",
		str(moon_preview_diag))
	_check(int(moon_preview_diag.moon_atlas_build_usec) > 0 \
			and int(moon_preview_diag.moon_atlas_build_usec) <= 250_000,
		"one-time lunar preview build stays below the hitch guard",
		str(moon_preview_diag))
	var cached_moon_texture_id := atlas._moon_texture.get_instance_id()
	var cached_crater_texture_id := atlas._moon_crater_texture.get_instance_id()
	var max_moon_base_samples := 0
	var max_moon_crater_stamps := 0
	var moon_pixel_count := WorldMap.MOON_ATLAS_SIZE.x \
		* WorldMap.MOON_ATLAS_SIZE.y
	for frame_index in range(320):
		await get_tree().process_frame
		var frame_diag := atlas.cache_diagnostics()
		max_moon_base_samples = maxi(max_moon_base_samples,
			int(frame_diag.last_moon_base_samples))
		max_moon_crater_stamps = maxi(max_moon_crater_stamps,
			int(frame_diag.last_moon_crater_stamps))
		if int(frame_diag.moon_base_cursor) >= moon_pixel_count \
				and int(frame_diag.moon_crater_stamps) \
					>= WorldMap.MOON_RANDOM_CRATER_COUNT \
						+ WorldMap.MOON_HERO_CRATERS.size():
			break
	var moon_diag := atlas.cache_diagnostics()
	print("  MOON_ATLAS_BENCHMARK pixels=%d craters=%d build_us=%d" % [
		int(moon_diag.moon_atlas_pixels), int(moon_diag.moon_crater_stamps),
		int(moon_diag.moon_atlas_build_usec)])
	_check(int(moon_diag.moon_atlas_pixels) == WorldMap.MOON_ATLAS_SIZE.x \
			* WorldMap.MOON_ATLAS_SIZE.y \
			and int(moon_diag.moon_crater_stamps) \
				== WorldMap.MOON_RANDOM_CRATER_COUNT \
					+ WorldMap.MOON_HERO_CRATERS.size(),
		"lunar globe uses one bounded dense procedural atlas", str(moon_diag))
	_check(max_moon_base_samples <= WorldMap.MOON_BASE_SAMPLES_PER_FRAME \
			and max_moon_crater_stamps <= WorldMap.MOON_CRATERS_PER_FRAME,
		"dense lunar relief refines under strict per-frame work caps",
		"base=%d craters=%d" % [max_moon_base_samples,
			max_moon_crater_stamps])
	atlas.focus_moon()
	var reused_moon_diag := atlas.cache_diagnostics()
	_check(atlas._moon_texture.get_instance_id() == cached_moon_texture_id \
			and atlas._moon_crater_texture.get_instance_id() \
				== cached_crater_texture_id \
			and int(reused_moon_diag.moon_atlas_build_usec) \
				== int(moon_preview_diag.moon_atlas_build_usec),
		"reselecting Moon reuses texture and build work", str(reused_moon_diag))
	atlas.focus_earth()
	_check(atlas.selected_body == WorldMap.CelestialBody.EARTH,
		"Earth globe can be restored after lunar inspection")
	atlas.close_map()
	_check(not atlas.is_open() and not atlas.visible,
		"closing atlas restores gameplay presentation")

	print("WORLDMAPTEST %d/%d %s" % [_total - _fails, _total,
		"PASS" if _fails == 0 else "FAIL"])
	get_tree().quit(0 if _fails == 0 else 1)
