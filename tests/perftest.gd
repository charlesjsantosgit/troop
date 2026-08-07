extends Node
## Real rendered benchmark. Run windowed (not headless):
##   godot --path . res://scenes/main.tscn -- perftest
##   godot --path . res://scenes/main.tscn -- perftest spring

const WARMUP_SECONDS := 8.0
const SAMPLE_SECONDS := 8.0
const TRANSITION_SETTLE_SECONDS := 0.75
const TRANSITION_SAMPLE_SECONDS := 2.0
const MIN_AVERAGE_FPS := 60.0
# A compositor-capped 60 Hz run reports just below 60.0 because process deltas
# include timer quantization. This tiny tolerance accepts a true refresh-rate
# lock without weakening the 25 ms p95 or 100 ms hard-stall requirements.
const AVERAGE_FPS_EPSILON := 0.10
const MAX_P95_MS := 25.0
const HARD_FRAME_LIMIT_MS := 100.0


func run(main) -> void:
	var player = main.world.local_player
	# Benchmark the actual solo-combat load, including the outlined AI rival.
	main.world.spawn_solo_ai()
	player.test_mode = true
	player.ti.dir = Vector2(0, -1)
	player.ti.sprint = true
	var benchmark_season: int = main.world.season

	# Prime both sides of the measured transition before the official warmup. The
	# transition sample therefore measures live shader-parameter/particle changes,
	# not one-time shader compilation, while still exercising the real public API.
	main.world.set_season_override(SeasonalCycle.Season.SUMMER)
	await get_tree().process_frame
	main.world.set_season_override(SeasonalCycle.Season.SPRING)
	await get_tree().process_frame
	main.world.set_season_override(benchmark_season)

	# Let shaders compile, chunks settle, and the adaptive renderer leave its
	# grace period before using frame times for the result.
	var warmup := 0.0
	while warmup < WARMUP_SECONDS:
		await get_tree().process_frame
		warmup += get_process_delta_time()

	var frame_times: Array[float] = []
	var draw_calls := 0.0
	var objects := 0.0
	var sample_time := 0.0
	var over_16 := 0
	var over_33 := 0
	var over_100 := 0
	var max_near_queue := 0
	var max_horizon_queue := 0
	while sample_time < SAMPLE_SECONDS:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		# Keep every frame. Filtering dt >100 ms hid exactly the streaming stalls
		# this benchmark is meant to catch.
		frame_times.append(dt)
		sample_time += dt
		draw_calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		objects += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		over_16 += 1 if dt > 0.0167 else 0
		over_33 += 1 if dt > 0.0333 else 0
		over_100 += 1 if dt > 0.100 else 0
		max_near_queue = maxi(max_near_queue, main.world._queue.size())
		max_horizon_queue = maxi(max_horizon_queue,
			main.world._horizon_queue.size())

	frame_times.sort()
	var total := 0.0
	for dt in frame_times:
		total += dt
	var count := maxi(frame_times.size(), 1)
	var average_fps := float(frame_times.size()) / maxf(total, 0.001)
	var p95_index := clampi(floori(float(frame_times.size() - 1) * 0.95), 0,
		maxi(frame_times.size() - 1, 0))
	var p95_ms := frame_times[p95_index] * 1000.0 if not frame_times.is_empty() else 0.0
	var p99_index := clampi(floori(float(frame_times.size() - 1) * 0.99), 0,
		maxi(frame_times.size() - 1, 0))
	var p99_ms := frame_times[p99_index] * 1000.0 if not frame_times.is_empty() else 0.0
	var max_ms := frame_times[-1] * 1000.0 if not frame_times.is_empty() else 0.0
	var stutter_frames := 0
	for dt in frame_times:
		if dt > 0.020:
			stutter_frames += 1
	print(("PERF_RESULT season=%s weather=%s adapter=\"%s\" window=%s refresh=%.0f avg_fps=%.1f " \
		+ "p95_ms=%.2f p99_ms=%.2f max_ms=%.2f stutters=%d " \
		+ "over16=%d over33=%d over100=%d scale=%.2f chunks=%d " \
		+ "horizon=%d horizon_m=%.0f near_q=%d horizon_q=%d " \
		+ "draw_calls=%.0f objects=%.0f") % [
		SeasonalCycle.season_name(main.world.season),
		SeasonalCycle.weather_name(main.world.weather),
		RenderingServer.get_video_adapter_name(),
		DisplayServer.window_get_size(),
		DisplayServer.screen_get_refresh_rate(),
		average_fps,
		p95_ms,
		p99_ms,
		max_ms,
		stutter_frames,
		over_16,
		over_33,
		over_100,
		main._render_scale,
		main.world.chunks.size(),
		main.world.horizon_chunks.size(),
		Gen.HORIZON_DISTANCE,
		max_near_queue,
		max_horizon_queue,
		draw_calls / count,
		objects / count,
	])

	# Exercise an in-session weather change after the renderer and both seasonal
	# resource sets are warm. Keep normal sprinting/streaming active so this catches
	# a transition that would visibly hitch during real play.
	main.world.set_season_override(SeasonalCycle.Season.SUMMER)
	var transition_settle := 0.0
	while transition_settle < TRANSITION_SETTLE_SECONDS:
		await get_tree().process_frame
		transition_settle += get_process_delta_time()
	var transition_call_start := Time.get_ticks_usec()
	main.world.set_season_override(SeasonalCycle.Season.SPRING)
	var transition_call_ms := float(Time.get_ticks_usec() - transition_call_start) / 1000.0
	var transition_frames: Array[float] = []
	var transition_time := 0.0
	var transition_over_100 := 0
	while transition_time < TRANSITION_SAMPLE_SECONDS:
		await get_tree().process_frame
		var transition_dt := get_process_delta_time()
		transition_frames.append(transition_dt)
		transition_time += transition_dt
		transition_over_100 += 1 if transition_dt > 0.100 else 0
	transition_frames.sort()
	var transition_total := 0.0
	for dt in transition_frames:
		transition_total += dt
	var transition_count := maxi(transition_frames.size(), 1)
	var transition_average_fps := float(transition_frames.size()) \
		/ maxf(transition_total, 0.001)
	var transition_p95_index := clampi(
		floori(float(transition_frames.size() - 1) * 0.95), 0,
		maxi(transition_frames.size() - 1, 0))
	var transition_p95_ms := transition_frames[transition_p95_index] * 1000.0 \
		if not transition_frames.is_empty() else 0.0
	var transition_max_ms := transition_frames[-1] * 1000.0 \
		if not transition_frames.is_empty() else 0.0
	print(("PERF_TRANSITION from=Summer to=Spring duration=%.2f call_ms=%.2f " \
		+ "avg_fps=%.1f p95_ms=%.2f max_ms=%.2f over100=%d frames=%d") % [
		transition_time,
		transition_call_ms,
		transition_average_fps,
		transition_p95_ms,
		transition_max_ms,
		transition_over_100,
		transition_count,
	])
	main.world.set_season_override(benchmark_season)

	var primary_pass := average_fps + AVERAGE_FPS_EPSILON >= MIN_AVERAGE_FPS \
		and p95_ms <= MAX_P95_MS \
		and max_ms < HARD_FRAME_LIMIT_MS \
		and over_100 == 0
	var transition_pass := transition_call_ms < HARD_FRAME_LIMIT_MS \
		and transition_average_fps + AVERAGE_FPS_EPSILON >= MIN_AVERAGE_FPS \
		and transition_p95_ms <= MAX_P95_MS \
		and transition_max_ms < HARD_FRAME_LIMIT_MS \
		and transition_over_100 == 0
	var gate_pass := primary_pass and transition_pass
	print(("PERF_GATE %s primary=%s transition=%s thresholds=" \
		+ "avg_fps>=%.0f p95_ms<=%.0f max_ms<%.0f over100=0") % [
		"PASS" if gate_pass else "FAIL",
		"PASS" if primary_pass else "FAIL",
		"PASS" if transition_pass else "FAIL",
		MIN_AVERAGE_FPS,
		MAX_P95_MS,
		HARD_FRAME_LIMIT_MS,
	])
	get_tree().quit(0 if gate_pass else 1)
