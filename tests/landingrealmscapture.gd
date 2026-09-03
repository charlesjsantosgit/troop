extends "res://tests/rocketsmoothcapture.gd"
## Native rendered review of shared landing animation and dimension minimaps.
## Reuses the existing capture watchdog; no window focus or input capture.

var _review_camera: Camera3D
var _review_frames := 0
var _review_timings: Array[float] = []


func _draw_frame() -> void:
	await get_tree().process_frame
	_last_stage = "landing_wait_draw"
	_last_stage_usec = Time.get_ticks_usec()
	await RenderingServer.frame_post_draw
	_last_stage = "landing_presented"
	_last_stage_usec = Time.get_ticks_usec()
	_review_frames += 1


func _shot(name: String) -> void:
	var error := get_viewport().get_texture().get_image().save_png(_output.path_join(name + ".png"))
	_screenshots[name] = error == OK
	_ok = _ok and error == OK
	print("LANDINGREALMSSHOT %s %s" % [name, "OK" if error == OK else "FAIL"])


func _observer_pose(outbound: bool) -> void:
	var frame := _rocket.moon_landing_transform.basis if outbound else Basis.IDENTITY
	_review_camera.global_position = _rocket.global_position + frame * Vector3(17.0, 7.0, 23.0)
	_review_camera.look_at(_rocket.global_position + frame.y * 0.2, frame.y)
	_review_camera.current = true


func _observe_flight(outbound: bool, from: float, to: float, moments: Array) -> void:
	var duration := LunarRocket.OUTBOUND_DURATION_SECONDS if outbound else LunarRocket.RETURN_DURATION_SECONDS
	var phase := Net.RocketMissionPhase.OUTBOUND if outbound else Net.RocketMissionPhase.RETURN
	Net.player_realms[2] = Net.PlayerRealm.TRANSIT
	Net.rocket_state = {"phase": phase, "crew": [2], "elapsed": from,
		"duration": duration, "serial": 1 if outbound else 2}
	_manager._apply_authoritative_state(Net.rocket_state)
	_rocket.apply_authoritative_clock(LunarRocket.state_for_elapsed(outbound, from), outbound, from)
	_observer_pose(outbound)
	for _warm in range(45):
		await _draw_frame()
	for tick in range(int(round((to - from) * 60.0)) + 1):
		var elapsed := minf(from + tick / 60.0, to)
		var started := Time.get_ticks_usec()
		_rocket.present_render_sample(_rocket.render_sample(elapsed))
		_observer_pose(outbound)
		await _draw_frame()
		_review_timings.append((Time.get_ticks_usec() - started) / 1000.0)
		_ok = _ok and not _rocket.voyage_visuals.visible
		for moment in moments:
			if absf(elapsed - float(moment)) < 0.005:
				await _shot(("moon-observer-" if outbound else "ocean-observer-") + "%04.1fs" % elapsed)


func _capture_map(name: String, position: Vector3, moon: bool) -> void:
	_stage("map_bake_begin", {"view": name})
	var player: MonkeyPlayer = _main.world.local_player
	player.admin_teleport(position)
	player.set_physics_process(true)
	if not moon:
		_main.world.warm(2)
	var up := _manager.moon_world.radial_up_at(position) if moon else Vector3.UP
	var frame := _manager.moon_world.surface_basis(up) if moon else Basis.IDENTITY
	_review_camera.global_position = position + frame * Vector3(8.0, 6.0, 11.0)
	_review_camera.look_at(position + up, up)
	_review_camera.environment = _manager.moon_world.lunar_environment if moon else null
	_review_camera.current = true
	_main.hud.visible = true
	_main.hud.minimap.mode = 1
	_main.hud.minimap.zoom_multiplier = 1.0
	_main.hud.minimap._apply_size()
	var max_bake_usec := 0
	var deadline := Time.get_ticks_msec() + 60_000
	for warm in range(9000):
		await _draw_frame()
		max_bake_usec = maxi(max_bake_usec, _main.hud.minimap._last_bake_usec)
		if warm >= 60 and _main.hud.minimap._bake_queue.is_empty():
			break
		if Time.get_ticks_msec() >= deadline:
			break
	_ok = _ok and _main.hud.minimap.visible \
		and _main.hud.minimap.map_realm() == (Net.PlayerRealm.MOON if moon else Net.PlayerRealm.EARTH) \
		and _main.hud.minimap._bake_queue.is_empty()
	await _shot(name)
	_summaries.append({"view": name, "realm": _main.hud.minimap.map_realm(),
		"map_cache_key": _main.hud.minimap.map_cache_key(),
		"window_meters": _main.hud.minimap.window_meters(),
		"max_bake_usec": max_bake_usec,
		"markers": _main.hud.minimap.marker_snapshot()})
	_main.hud.visible = false


func run(main: Node) -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Landing visual review requires a rendered window")
		get_tree().quit(1)
		return
	_main = main
	AudioServer.set_bus_mute(0, true)
	_manager = main.expedition_manager
	_rocket = _manager.rocket
	_output = ProjectSettings.globalize_path("res://artifacts/landing-realms")
	DirAccess.make_dir_recursive_absolute(_output)
	_probe = load("res://tests/rocketsmoothtest.gd").new()
	add_child(_probe)
	_probe.configure(main)
	get_viewport().scaling_3d_scale = 1.0
	main.world.set_expensive_effects(true)
	main.hud.visible = false
	main._session_ui_layer.visible = false
	_manager._ui_layer.visible = false
	_review_camera = Camera3D.new()
	_review_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_review_camera.far = 14000.0
	_review_camera.fov = 54.0
	main.world.add_child(_review_camera)
	Net.names[2] = "Landing Crew"
	Net.scores[2] = 0
	main.world.spawn_puppet(2, "Landing Crew")
	Net.player_realms[1] = Net.PlayerRealm.MOON
	_manager._apply_local_realm(Net.PlayerRealm.MOON)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Let the actual spectator settle on collision. Freezing the arrival spawn
	# clearance would leave a diagnostic-only floating monkey beside touchdown.
	main.world.local_player.set_physics_process(true)
	_review_camera.environment = _manager.moon_world.lunar_environment
	await _observe_flight(true, 50.0, 60.0, [52.0, 54.0, 56.0, 58.8, 59.6, 60.0])
	Net.player_realms[2] = Net.PlayerRealm.MOON
	Net.rocket_state = {"phase": Net.RocketMissionPhase.MOON_READY, "crew": [],
		"elapsed": 0.0, "duration": 0.0, "serial": 1}
	_manager._apply_authoritative_state(Net.rocket_state)
	await _capture_map("moon-minimap-colony", _manager.moon_world.colony_world.interaction_position("farm"), true)
	var antipode := _manager.moon_world.to_global(_manager.moon_world.surface_position(Vector3.DOWN, 1.2))
	await _capture_map("moon-minimap-far-side", antipode, true)
	Net.player_realms[1] = Net.PlayerRealm.EARTH
	_manager._apply_local_realm(Net.PlayerRealm.EARTH)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	main.world.local_player.admin_teleport(_rocket.ocean_splashdown_transform.origin + Vector3(8, 1.2, 8))
	# The frozen observer fixture must include the same complete near-water
	# window as normal streaming before the 108 m horizon handoff.
	main.world.warm(Gen.VIEW_R)
	main.world.set_earth_streaming_enabled(false)
	main.world.local_player.set_physics_process(true)
	main.world.set_time_of_day_override(10.25)
	_review_camera.environment = null
	await _observe_flight(false, 40.0, 45.0, [41.0, 43.0, 44.5, 45.0])
	# The corrected destination also changes the passenger's final terrain view.
	# Sample the shipped camera/planet handoff at that same real landing site.
	_manager._update_voyage_camera(0.0, 44.5 / LunarRocket.RETURN_DURATION_SECONDS, {}, true)
	await _draw_frame()
	await _draw_frame()
	await _shot("passenger-water-approach-44.5s")
	_rocket.voyage_visuals.set_local_viewer_enabled(false)
	Net.player_realms[2] = Net.PlayerRealm.EARTH
	Net.rocket_state = {"phase": Net.RocketMissionPhase.SPLASHDOWN_RECOVERY,
		"crew": [2], "elapsed": 0.0, "duration": Net.ROCKET_RECOVERY_SECONDS, "serial": 2}
	_manager._apply_authoritative_state(Net.rocket_state)
	for tick in range(301):
		_rocket.present_landing_recovery(tick / 60.0)
		_observer_pose(false)
		await _draw_frame()
		if tick in [15, 60, 180, 300]:
			await _shot("ocean-recovery-%04.2fs" % (tick / 60.0))
	_manager._reset_rocket_to_launchpad()
	await _capture_map("earth-minimap", _rocket.earth_launch_transform.origin + Vector3(8, 1.2, 8), false)
	_review_timings.sort()
	var sum_ms := 0.0
	for value in _review_timings:
		sum_ms += value
	var report := {"passed": _ok, "frames": _review_frames,
		"viewport": _vector_array(Vector3(get_viewport().get_visible_rect().size.x,
			get_viewport().get_visible_rect().size.y, 0)).slice(0, 2),
		"render_delivery": "forced_offscreen" if _forced_background_draw else "native_window",
		"animation_fps": _review_timings.size() * 1000.0 / maxf(sum_ms, 0.001),
		"animation_p95_ms": _review_timings[int(_review_timings.size() * 0.95)],
		"screenshots": _screenshots, "maps": _summaries}
	var file := FileAccess.open(_output.path_join("render-report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("LANDINGREALMSCAPTURE " + JSON.stringify(report))
	get_tree().quit(0 if _ok else 1)
