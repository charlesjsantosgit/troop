extends Node
## Real-renderer counterpart to rocketsmoothtest. Writes frame-by-frame screen
## traces, representative PNGs and measured wall-clock delivery statistics.
## Default covers all 105 seconds; --rocket-capture-windows limits the run to
## transition windows. --rocket-capture-fps=30/60/120/144 changes sampled cadence.

var _probe: Node
var _main: Node
var _manager: ExpeditionManager
var _rocket: LunarRocket
var _fps := 60
var _output := ""
var _trace: FileAccess
var _summaries: Array[Dictionary] = []
var _screenshots: Dictionary = {}
var _ok := true
var _warmup_frames := 45
var _extra_monitor_ids: Dictionary = {}
var _last_stage := "created"
var _last_stage_usec := 0
var _watchdog_notice_usec := 0
var _forced_background_draw := false
var _saved_render_loop_enabled := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_stage_usec = Time.get_ticks_usec()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var idle_seconds := float(now - _last_stage_usec) / 1_000_000.0
	if idle_seconds > 45.0:
		push_error("Rocket capture stalled at %s; stopping the diagnostic" % _last_stage)
		if _forced_background_draw:
			RenderingServer.render_loop_enabled = _saved_render_loop_enabled
		get_tree().quit(1)
		return
	if _last_stage.ends_with("wait_draw") and (idle_seconds >= 0.5 or _forced_background_draw):
		if not _forced_background_draw:
			_forced_background_draw = true
			_saved_render_loop_enabled = RenderingServer.render_loop_enabled
			# A fully occluded macOS window may stop receiving native draws. Render
			# exactly once on demand, without swapping/focusing its window. Disabling
			# the automatic loop prevents a second render if occlusion later ends.
			RenderingServer.render_loop_enabled = false
			print("ROCKETCAPTURE_RENDER_DELIVERY forced_offscreen (native draw stalled)")
		RenderingServer.force_draw(false, 1.0 / float(_fps))
		return
	if idle_seconds >= 5.0 and now - _watchdog_notice_usec >= 5_000_000:
		_watchdog_notice_usec = now
		print("ROCKETCAPTURE_WATCHDOG stage=%s wall_seconds=%.2f frames=%d paused=%s" % [
			_last_stage, idle_seconds, Engine.get_process_frames(), get_tree().paused])


func _stage(label: String, data: Dictionary = {}) -> void:
	_last_stage = label
	_last_stage_usec = Time.get_ticks_usec()
	print("ROCKETCAPTURE_STAGE %s %s" % [label, JSON.stringify(data)])


func run(main: Node) -> void:
	if DisplayServer.get_name() == "headless":
		print("ROCKETSMOOTHCAPTURE requires a rendered window; no visual or FPS claim made.")
		get_tree().quit(1)
		return
	_main = main
	_manager = main.expedition_manager
	_rocket = _manager.rocket
	_probe = load("res://tests/rocketsmoothtest.gd").new()
	add_child(_probe)
	_stage("configure_begin")
	_probe.configure(main)
	_stage("configure_end")
	var windows_only := false
	var launch_only := false
	for argument in OS.get_cmdline_user_args():
		if argument == "--rocket-capture-windows":
			windows_only = true
		elif argument == "--rocket-capture-launch":
			launch_only = true
			windows_only = true
			_warmup_frames = 180
		elif argument.begins_with("--rocket-capture-fps="):
			var requested := argument.get_slice("=", 1).to_int()
			if requested in [30, 60, 120, 144]:
				_fps = requested
	_output = ProjectSettings.globalize_path("res://artifacts/rocket-smooth")
	if launch_only:
		_output = _output.path_join("launch")
	# Discover optional counters instead of assuming an engine version's enum
	# layout. In particular, pipeline compilation distinguishes shader warm-up
	# from sustained terrain or rendering cost without another profiler process.
	for constant in ClassDB.class_get_integer_constant_list("Performance"):
		if "PIPELINE" in constant or constant in ["RENDER_VIDEO_MEM_USED",
				"RENDER_TEXTURE_MEM_USED", "RENDER_BUFFER_MEM_USED"]:
			_extra_monitor_ids[constant] = ClassDB.class_get_integer_constant("Performance", constant)
	DirAccess.make_dir_recursive_absolute(_output)
	_trace = FileAccess.open(_output.path_join("screen-trace-%dfps.jsonl" % _fps), FileAccess.WRITE)
	if not _trace:
		push_error("Rocket capture could not open its diagnostic trace")
		get_tree().quit(1)
		return
	_stage("trace_opened", {"output": _output})
	get_viewport().scaling_3d_scale = 1.0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	main.world.set_time_of_day_override(10.25)
	_stage("terrain_warm_begin")
	main.world.warm(2)
	_stage("terrain_warm_end", _streaming_counts())
	main.hud.visible = false
	main._session_ui_layer.visible = false
	_manager._ui_layer.visible = false
	_manager.voyage_camera.current = true
	var player: MonkeyPlayer = main.world.local_player
	for weapon in [player.gun, player.shotgun, player.smg, player.sniper]:
		if weapon:
			weapon.visible = false
	_rocket.board_crew(Net.local_id(), player, _manager.local_suit,
		_manager.local_inventory, true)
	var legs: Array = [true] if launch_only else [true, false]
	for outbound in legs:
		var windows: Array = [Vector2(0.0, 60.0 if outbound else 45.0)]
		if windows_only:
			windows = [Vector2(0.0, 1.5), Vector2(13.0, 15.0), Vector2(17.0, 22.0),
				Vector2(25.5, 27.5),
				Vector2(39.0, 51.0), Vector2(58.5, 60.0)] if outbound else [
				Vector2(0.0, 1.5), Vector2(5.0, 7.0), Vector2(17.0, 25.0),
				Vector2(27.0, 45.0)]
		if launch_only:
			windows = [Vector2(0.0, 4.0)]
		for window in windows:
			await _capture_window(outbound, window)
	_trace.close()
	var report := {"sample_fps": _fps, "full_voyages": not windows_only,
		"warmup_frames": _warmup_frames,
		"render_delivery": "forced_offscreen" if _forced_background_draw else "native_window",
		"viewport": [get_viewport().get_visible_rect().size.x,
			get_viewport().get_visible_rect().size.y],
		"physics_hz": Engine.physics_ticks_per_second,
		"windows": _summaries, "screenshots": _screenshots.keys(), "passed": _ok}
	var report_file := FileAccess.open(_output.path_join("report-%dfps.json" % _fps), FileAccess.WRITE)
	if report_file:
		report_file.store_string(JSON.stringify(report, "\t"))
		report_file.close()
	else:
		_ok = false
	print("ROCKETSMOOTHCAPTURE %s sample_fps=%d full=%s screenshots=%d" % [
		"PASS" if _ok else "FAIL", _fps, not windows_only, _screenshots.size()])
	if _forced_background_draw:
		RenderingServer.render_loop_enabled = _saved_render_loop_enabled
	_main._return_to_main_menu()
	for _frame in range(4):
		await get_tree().process_frame
	get_tree().quit(0 if _ok else 1)


func _capture_window(outbound: bool, window: Vector2) -> void:
	var label := "outbound" if outbound else "return"
	_stage("window_setup", {"leg": label, "from": window.x, "to": window.y})
	_probe._new_mission(outbound, window.x)
	_rocket.voyage_visuals.set_cinematic_terrain_enabled(true)
	Net.player_realms[Net.local_id()] = Net.PlayerRealm.TRANSIT
	Net.rocket_state = {"phase": Net.RocketMissionPhase.OUTBOUND if outbound
		else Net.RocketMissionPhase.RETURN, "crew": [Net.local_id()],
		"elapsed": window.x, "duration": 60.0 if outbound else 45.0, "serial": 1}
	_stage("first_present_begin")
	_present()
	_stage("first_present_end", _streaming_counts())
	# Hold the requested pose while new materials warm. Warm-up and PNG readback
	# cost are excluded from frame delivery metrics, never from screen traces.
	for _frame in range(_warmup_frames):
		_last_stage = "warmup_wait_process"
		_last_stage_usec = Time.get_ticks_usec()
		await get_tree().process_frame
		_last_stage = "warmup_wait_draw"
		_last_stage_usec = Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		if _frame % 30 == 0 or _frame == _warmup_frames - 1:
			_stage("warmup_progress", {"frame": _frame + 1, "target": _warmup_frames,
				"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				"streaming": _streaming_counts()})
	_stage("capture_begin")
	var previous_screen := PackedVector2Array()
	var deltas: Array[float] = []
	var max_screen_speed := 0.0
	var max_interpolation_error := 0.0
	var max_camera_error := 0.0
	var max_pose_error := 0.0
	var visible := true
	var cpu := 0.0
	var gpu := 0.0
	var worst_time := window.x
	var frame_count := int(round((window.y - window.x) * _fps))
	var previous_usec := Time.get_ticks_usec()
	for frame in range(frame_count + 1):
		var presentation_begin := Time.get_ticks_usec()
		if frame > 0:
			_rocket.advance_render_clock(1.0 / float(_fps))
		# Repeated fractional clock steps can end a few trillionths before the
		# requested endpoint. Present its exact sample so the contact screenshot
		# records the terminal state rather than one last exhaust frame.
		var expected := _present(window.y if frame == frame_count else -1.0)
		var presentation_ms := float(Time.get_ticks_usec() - presentation_begin) / 1000.0
		_last_stage = "capture_wait_process"
		_last_stage_usec = Time.get_ticks_usec()
		await get_tree().process_frame
		_last_stage = "capture_wait_draw"
		_last_stage_usec = Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		_last_stage = "capture_running"
		_last_stage_usec = Time.get_ticks_usec()
		var now_usec := Time.get_ticks_usec()
		var delta_ms := float(now_usec - previous_usec) / 1000.0
		if frame > 0:
			deltas.append(delta_ms)
		var displayed_rocket := _rocket.get_global_transform_interpolated()
		var displayed_camera := _manager.voyage_camera.get_global_transform_interpolated()
		var screen: PackedVector2Array = _probe.project_markers(displayed_rocket,
			displayed_camera, _manager.voyage_camera.fov)
		var expected_screen: PackedVector2Array = expected.screen
		var screen_error := _max_pixel_distance(screen, expected_screen)
		max_interpolation_error = maxf(max_interpolation_error, screen_error)
		max_camera_error = maxf(max_camera_error,
			displayed_camera.origin.distance_to(expected.camera.origin))
		max_pose_error = maxf(max_pose_error,
			displayed_rocket.origin.distance_to(expected.rocket.origin))
		var speed := 0.0
		if not previous_screen.is_empty():
			speed = _max_pixel_distance(previous_screen, screen) * _fps
			if speed > max_screen_speed:
				max_screen_speed = speed
				worst_time = float(expected.elapsed)
		previous_screen = screen
		var pixels: Array = []
		for point in screen:
			visible = visible and point.is_finite() and point.x >= -1.0 \
				and point.y >= -1.0 and point.x <= _probe.viewport_size.x + 1.0 \
				and point.y <= _probe.viewport_size.y + 1.0
			pixels.append([point.x, point.y])
		var render_cpu := RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid())
		var render_gpu := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
		cpu += render_cpu
		gpu += render_gpu
		var extra_monitors: Dictionary = {}
		for monitor_name in _extra_monitor_ids:
			extra_monitors[monitor_name] = Performance.get_monitor(int(_extra_monitor_ids[monitor_name]))
		_trace.store_line(JSON.stringify({"leg": label, "elapsed": expected.elapsed,
			"sample_fps": _fps, "wall_frame_ms": delta_ms, "screen": pixels,
			"viewport": [_probe.viewport_size.x, _probe.viewport_size.y],
			"presentation_cpu_ms": presentation_ms, "render_cpu_ms": render_cpu,
			"render_gpu_ms": render_gpu,
			"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			"rendered_objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
			"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			"orphan_nodes": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
			"extra_monitors": extra_monitors,
			"streaming": _streaming_counts(),
			"marker_speed_px_s": speed, "interpolation_error_px": screen_error,
			"fov": _manager.voyage_camera.fov,
			"rocket_position": _vector_array(displayed_rocket.origin),
			"camera_position": _vector_array(displayed_camera.origin),
			"camera_up": _vector_array(displayed_camera.basis.y)}))
		var readback_begin := Time.get_ticks_usec()
		await _maybe_screenshot(label, float(expected.elapsed))
		# Preserve real frame-to-frame delivery time, subtracting only the
		# diagnostic PNG readback rather than the whole trace-processing tail.
		previous_usec = now_usec + (Time.get_ticks_usec() - readback_begin)
	deltas.sort()
	var elapsed_ms := 0.0
	for delta in deltas:
		elapsed_ms += delta
	var fps := float(deltas.size()) * 1000.0 / maxf(elapsed_ms, 0.001)
	var p95 := deltas[mini(int(deltas.size() * 0.95), deltas.size() - 1)]
	var worst := deltas[-1]
	var motion_ok := visible and max_screen_speed < 750.0 \
		and max_interpolation_error < 0.5 and max_camera_error < 0.05 and max_pose_error < 0.05
	# Report hardware pacing separately from deterministic authored motion. A
	# trace can prove smooth transforms while still exposing a slow rendered run.
	var pacing_ok := fps >= 55.0 and p95 <= 25.0 and worst < 100.0
	_ok = _ok and motion_ok and pacing_ok
	var summary := {"leg": label, "from": window.x, "to": window.y,
		"frames": deltas.size(), "fps": fps, "p95_ms": p95, "worst_ms": worst,
		"max_marker_speed_px_s": max_screen_speed, "worst_motion_at": worst_time,
		"max_interpolation_error_px": max_interpolation_error,
		"max_camera_error_m": max_camera_error, "max_hull_error_m": max_pose_error,
		"all_hull_markers_visible": visible, "render_cpu_ms": cpu / (frame_count + 1),
		"render_gpu_ms": gpu / (frame_count + 1), "motion_pass": motion_ok,
		"pacing_pass": pacing_ok}
	_summaries.append(summary)
	print("ROCKETSMOOTHWINDOW " + JSON.stringify(summary))


func _present(elapsed_override := -1.0) -> Dictionary:
	# macOS can resize a background window during creation. Use its actual live
	# viewport for projection and report it, without moving/focusing the window.
	_probe.viewport_size = get_viewport().get_visible_rect().size
	var sample := _rocket.render_sample(elapsed_override)
	_rocket.present_render_sample(sample)
	_manager._update_transit_world_visibility()
	_manager._update_voyage_camera(0.0, -1.0, Net.rocket_state, false, sample)
	var pose := _manager.sample_voyage_camera_pose(float(sample.elapsed), sample.transform,
		bool(sample.outbound))
	var camera := Transform3D(Basis.IDENTITY, pose.position).looking_at(pose.focus, pose.up)
	return {"elapsed": sample.elapsed, "rocket": sample.transform, "camera": camera,
		"screen": _probe.project_markers(sample.transform, camera, float(pose.fov))}


func _max_pixel_distance(first: PackedVector2Array, second: PackedVector2Array) -> float:
	var maximum := 0.0
	for index in range(first.size()):
		if not first[index].is_finite() or not second[index].is_finite():
			return INF
		maximum = maxf(maximum, first[index].distance_to(second[index]))
	return maximum


func _vector_array(vector: Vector3) -> Array:
	return [vector.x, vector.y, vector.z]


func _streaming_counts() -> Dictionary:
	var world: Node = _main.world
	var active: bool = world.earth_streaming_enabled()
	# O(1) queue sizes keep this diagnostic from doing the expensive full-world
	# coverage scan that the interactive streaming metrics panel can request.
	return {"active": active, "near_chunks": world.chunks.size(), "horizon_chunks": world.horizon_chunks.size(),
		"shell_cpu_ms": float(world._stream_shell_usec_last) / 1000.0 if active else 0.0,
		"safety_cpu_ms": float(world._stream_safety_usec_last) / 1000.0 if active else 0.0,
		"decoration_cpu_ms": float(world._stream_decoration_usec_last) / 1000.0 if active else 0.0,
		"shell_ops": world._stream_shell_ops_last if active else 0,
		"safety_ops": world._stream_safety_ops_last if active else 0,
		"decoration_ops": world._stream_decoration_ops_last if active else 0,
		"skyline_chunks": world.skyline_chunks.size(), "stratos_chunks": world.stratos_chunks.size(),
		"near_pending": world._queue.size(), "horizon_pending": world._horizon_queue.size(),
		"skyline_pending": world._skyline_queue.size(), "stratos_pending": world._stratos_queue.size(),
		"collision_pending": world._collision_queue.size(),
		"near_details_pending": world._chunk_detail_queue.size(),
		"horizon_details_pending": world._horizon_detail_queue.size(),
		"skyline_details_pending": world._skyline_detail_queue.size()}


func _maybe_screenshot(label: String, elapsed: float) -> void:
	var moments: Array = [0.0, 14.0, 18.0, 40.0, 44.0, 46.0, 48.0, 50.0, 60.0] \
		if label == "outbound" else [0.0, 6.0, 18.0, 21.0, 24.0, 28.0,
			32.0, 36.0, 38.0, 40.0, 45.0]
	for moment in moments:
		if absf(elapsed - float(moment)) > 0.45 / float(_fps):
			continue
		var name := "%s-%04.1fs-%dfps.png" % [label, moment, _fps]
		if _screenshots.has(name):
			return
		var result := get_viewport().get_texture().get_image().save_png(_output.path_join(name))
		_screenshots[name] = result == OK
		_ok = _ok and result == OK
		print("ROCKETSMOOTHSHOT %s %s" % [name, "OK" if result == OK else "FAIL"])
		return
