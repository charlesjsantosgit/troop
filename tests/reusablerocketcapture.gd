extends "res://tests/rocketsmoothcapture.gd"
## Real-renderer complete round trip, cabin inspection, Moon first person and
## explicit hatch exit. Diagnostic CLI keeps the player's saved colony isolated.

var _timings: Array[float] = []
var _capture_frames := 0


func _draw() -> void:
	await get_tree().process_frame
	_last_stage = "reusable_wait_draw"
	_last_stage_usec = Time.get_ticks_usec()
	await RenderingServer.frame_post_draw
	_last_stage = "reusable_presented"
	_last_stage_usec = Time.get_ticks_usec()
	_capture_frames += 1


func _shot(label: String) -> void:
	var result := get_viewport().get_texture().get_image().save_png(_output.path_join(label + ".png"))
	_screenshots[label] = result == OK
	_ok = _ok and result == OK
	print("REUSABLESHOT %s %s" % [label, "OK" if result == OK else "FAIL"])


func _cabin_shot(label: String, yaw := 0.0, pitch := 0.0) -> void:
	_manager._cabin_yaw = yaw
	_manager._cabin_pitch = pitch
	_manager.set_cabin_view(true)
	await _draw()
	await _draw()
	await _shot(label)
	_manager.set_cabin_view(false)


func _flight(outbound: bool, moments: Array) -> void:
	var duration := LunarRocket.OUTBOUND_DURATION_SECONDS if outbound else LunarRocket.RETURN_DURATION_SECONDS
	_manager.set_cabin_view(false)
	var started_mission := Net._host_start_rocket(1)
	_ok = _ok and started_mission
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for _warm in range(30):
		await _draw()
	for tick in range(int(duration * 60.0) + 1):
		var elapsed := minf(tick / 60.0, duration)
		var started := Time.get_ticks_usec()
		var sample := _rocket.render_sample(elapsed)
		_rocket.present_render_sample(sample)
		_manager._update_transit_world_visibility()
		_manager._update_voyage_camera(0.0, elapsed / duration, Net.rocket_state, false, sample)
		await _draw()
		_timings.append((Time.get_ticks_usec() - started) / 1000.0)
		for moment in moments:
			if absf(elapsed - float(moment)) < 0.005:
				await _shot(("outbound-" if outbound else "return-") + "%05.2fs" % elapsed)
		if tick in ([720, 1800, 3240] if outbound else [720, 1800, 2520]):
			await _cabin_shot(("outbound-cabin-" if outbound else "return-cabin-") + "%05.2fs" % elapsed)
	Net._complete_rocket_voyage(Net.RocketMissionPhase.OUTBOUND if outbound else Net.RocketMissionPhase.RETURN)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await _draw()


func _manifest_on_surface(realm: int) -> void:
	var player: MonkeyPlayer = _main.world.local_player
	player.admin_teleport(_rocket.boarding_global_position())
	Net.player_realms[1] = realm
	Net.rocket_state.crew = [1, 2, 3, 4]
	for peer in [2, 3, 4]:
		Net.player_realms[peer] = realm
	_manager._apply_authoritative_state(Net.expedition_state_snapshot())
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func run(main: Node) -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Reusable rocket review requires a real renderer")
		get_tree().quit(1)
		return
	_main = main
	_manager = main.expedition_manager
	_rocket = _manager.rocket
	_output = ProjectSettings.globalize_path("res://artifacts/reusable-rocket")
	DirAccess.make_dir_recursive_absolute(_output)
	AudioServer.set_bus_mute(0, true)
	_probe = load("res://tests/rocketsmoothtest.gd").new()
	add_child(_probe)
	_probe.configure(main)
	get_viewport().scaling_3d_scale = 1.0
	main.world.set_expensive_effects(true)
	main.world.set_time_of_day_override(10.25)
	main.hud.visible = false
	main._session_ui_layer.visible = false
	_manager._ui_layer.visible = false
	for peer in [2, 3, 4]:
		Net.names[peer] = ["Pilot", "Navigator", "Engineer"][peer - 2]
		Net.scores[peer] = 0
		main.world.spawn_puppet(peer, Net.names[peer])
	_manifest_on_surface(Net.PlayerRealm.EARTH)
	# Use the actual input dispatch once, with Main and ExpeditionManager both
	# listening, so C cannot silently change the on-foot camera behind the cabin.
	for expected_cabin in [false, true]:
		var camera_key := InputEventKey.new()
		camera_key.physical_keycode = KEY_C
		camera_key.keycode = KEY_C
		camera_key.pressed = true
		Input.parse_input_event(camera_key)
		await _draw()
		await _draw()
		print("REUSABLE_CAMERA_INPUT expected=%s actual=%s modal=%s aboard=%s" % [
			expected_cabin, _manager.cabin_view_active(), _manager._other_modal_open(), _manager._local_aboard])
		_ok = _ok and _manager.cabin_view_active() == expected_cabin
		var released_key := camera_key.duplicate() as InputEventKey
		released_key.pressed = false
		Input.parse_input_event(released_key)
		await _draw()
	if OS.get_cmdline_user_args().has("--input-only"):
		print("REUSABLE_INPUT_TEST %s" % _ok)
		get_tree().quit(0 if _ok else 1)
		return
	# Warm the actual pad before starting a timed ascent; return uses the
	# production bounded preparation path while still travelling from the Moon.
	main.world.set_expedition_stream_focus(Gen.rocket_launch_position() + Vector3.UP)
	for _warm in range(240):
		await _draw()
	await _cabin_shot("cabin-forward")
	await _cabin_shot("cabin-rear", PI)
	await _cabin_shot("cabin-left", PI * 0.5, 0.15)
	await _cabin_shot("cabin-ceiling", 0.0, 1.15)
	await _flight(true, [0.0, 2.0, 8.0, 14.0, 18.0, 30.0, 44.0, 50.0, 54.0, 58.0, 59.8, 60.0])
	var player: MonkeyPlayer = main.world.local_player
	player.set_physics_process(true)
	player.cam.set_first_person(true)
	player.cam.pitch = 0.05
	main.hud.visible = true
	for _settle in range(90):
		await _draw()
	await _shot("moon-first-person-grounded")
	main.hud.visible = false
	_manifest_on_surface(Net.PlayerRealm.MOON)
	await _cabin_shot("moon-cabin-windows", -PI * 0.5)
	await _cabin_shot("moon-cabin-forward", 0.0, -0.15)
	await _cabin_shot("moon-cabin-near-window", PI * 0.5, -0.15)
	await _flight(false, [0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 14.0, 18.0, 22.0, 26.0, 28.0, 30.0, 32.0, 34.0, 36.0, 38.0, 40.0, 42.0, 43.0, 44.0, 44.8, 45.0])
	var touchdown_pose := _rocket.global_transform
	for tick in range(181):
		_rocket.present_landing_recovery(tick / 60.0)
		await _draw()
	Net._complete_splashdown_recovery()
	_ok = _ok and _rocket.global_transform.is_equal_approx(touchdown_pose) \
		and player.expedition_locked and _manager.is_local_player_aboard()
	await _cabin_shot("earth-landed-cabin")
	var exited := _manager.request_disembark()
	_ok = _ok and exited
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.cam.set_first_person(false)
	player.cam.yaw = PI
	player.cam.pitch = -0.16
	main.hud.visible = true
	for _settle in range(90):
		await _draw()
	await _shot("earth-hatch-exit")
	_ok = _ok and not player.expedition_locked \
		and Vector2(player.global_position.x, player.global_position.z).distance_to(
			Vector2(_rocket.global_position.x, _rocket.global_position.z)) < 12.0
	_timings.sort()
	var total_ms := 0.0
	for duration in _timings:
		total_ms += duration
	var animation_fps := _timings.size() * 1000.0 / maxf(total_ms, 0.001)
	var animation_p95 := _timings[int(_timings.size() * 0.95)]
	var pacing_pass := animation_fps >= 55.0 and animation_p95 <= 25.0 and _timings[-1] < 100.0
	var report := {"passed": _ok and pacing_pass, "functional_pass": _ok,
		"pacing_pass": pacing_pass, "frames": _capture_frames,
		"native_render": not _forced_background_draw,
		"animation_fps": animation_fps,
		"animation_p95_ms": animation_p95, "animation_worst_ms": _timings[-1],
		"screenshots": _screenshots,
		"viewport": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y],
		"exit_position": [player.global_position.x, player.global_position.y, player.global_position.z]}
	var file := FileAccess.open(_output.path_join("render-report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("REUSABLEROCKETCAPTURE " + JSON.stringify(report))
	get_tree().quit(0 if _ok else 1)
