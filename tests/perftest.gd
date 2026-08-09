extends Node
## Real rendered benchmark. Run windowed (not headless):
##   godot --path . res://scenes/main.tscn -- perftest
##   godot --path . res://scenes/main.tscn -- perftest spring
##   godot --path . --disable-vsync --max-fps 0 res://scenes/main.tscn -- perftest highspeed

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
const HIGHSPEED_METERS_PER_SECOND := 447.04 # exactly 1000 mph
const HIGHSPEED_ALTITUDE := 120.0
const HIGHSPEED_CRUISE_Y := Gen.PLANET_SUMMIT_ELEVATION + HIGHSPEED_ALTITUDE
const HIGHSPEED_PREFLIGHT_SETTLE_SECONDS := 12.0
const HIGHSPEED_WARMUP_SECONDS := 8.0
const HIGHSPEED_SAMPLE_SECONDS := 20.0
## Sustained 1000 mph streaming must remain inside the requested 70-90 FPS
## envelope on hardware whose refresh/cap can expose it. Seventy is the hard
## gate; ninety is reported as a stretch result rather than making 75 Hz panels
## incapable of producing a valid proof.
const HIGHSPEED_TARGET_FPS := 70.0
const HIGHSPEED_STRETCH_FPS := 90.0
const HIGHSPEED_MAX_P95_MS := 14.5
const HIGHSPEED_STRETCH_P95_MS := 12.0
const HIGHSPEED_MAX_P99_MS := 20.0
const HIGHSPEED_MAX_FRAME_MS := 50.0
const HIGHSPEED_MIN_PREDICTION_LEAD := Gen.CHUNK * 4.0
const HIGHSPEED_MAX_NEAR_QUEUE := 64
const HIGHSPEED_MAX_SHELL_AGE_MS := 1800.0
const HIGHSPEED_MAX_TREE_AGE_MS := 5000.0
## The circular predictor deliberately keeps up to one 3-wide eight-chunk lane
## plus a few incoming stratos sectors queued. This remains bounded by age and
## near-queue gates; allow that fixed 28-ish working set independent of a lucky
## near-zero snapshot at the exact start of sampling.
const HIGHSPEED_MAX_PENDING_GROWTH := 32
const HIGHSPEED_COLLISION_LEG_SECONDS := 5.0
const HIGHSPEED_PARKED_VEHICLE_PROBE_SECONDS := 2.5
const HIGHSPEED_PARKED_SHELL_SETTLE_SECONDS := 0.75
const HIGHSPEED_COLLISION_LEG_SPEED := 80.0
const HIGHSPEED_DESCENT_SPEED := 22.0
const HIGHSPEED_MAX_STREAMED_VEHICLES := 16
const HIGHSPEED_MAX_SPAWNED_VEHICLE_IDS := 32
const HIGHSPEED_MAX_VEHICLE_NODES := 32


func run(main, variant := "") -> void:
	if str(variant).to_lower() == "highspeed":
		await _run_highspeed(main)
		return
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


func _highspeed_direction(elapsed: float) -> Vector2:
	# Straight, diagonal, and hard-turn legs exercise axis and diagonal chunk
	# crossings without changing the exact 447.04 m/s synthetic ground speed.
	var phase := fmod(elapsed, 20.0)
	if phase < 7.0:
		return Vector2(1.0, 0.0)
	if phase < 14.0:
		return Vector2(1.0, 1.0).normalized()
	return Vector2(0.0, -1.0)


func _advance_highspeed_player(player: MonkeyPlayer, elapsed: float,
		dt: float) -> void:
	var direction := _highspeed_direction(elapsed)
	var velocity_2d := direction * HIGHSPEED_METERS_PER_SECOND
	player.velocity = Vector3(velocity_2d.x, 0.0, velocity_2d.y)
	player.global_position += player.velocity * dt
	# Keep the synthetic stratos cruise on one stable flight level 120 m above the
	# planet's exact 6,000 m summit. Following the terrain vertically at 1000 mph
	# would add an unrealistic teleport axis; the separate descent leg below still
	# proves that terrain and collision wake before an actual approach.
	player.global_position.y = HIGHSPEED_CRUISE_Y


func _advance_collision_probe(player: MonkeyPlayer, elapsed: float,
		dt: float) -> void:
	var direction := _highspeed_direction(elapsed)
	var horizontal_speed := HIGHSPEED_COLLISION_LEG_SPEED \
		if elapsed < HIGHSPEED_COLLISION_LEG_SECONDS - 1.25 else 0.0
	var ground_before := Gen.height(player.global_position.x,
		player.global_position.z)
	var descending := player.global_position.y - ground_before > 8.0
	player.velocity = Vector3(direction.x * horizontal_speed,
		-HIGHSPEED_DESCENT_SPEED if descending else 0.0,
		direction.y * horizontal_speed)
	player.global_position += player.velocity * dt
	var ground_after := Gen.height(player.global_position.x,
		player.global_position.z)
	player.global_position.y = maxf(player.global_position.y, ground_after + 7.5)


func _run_highspeed(main) -> void:
	var world: World = main.world
	var player: MonkeyPlayer = world.local_player
	world.set_season_override(SeasonalCycle.Season.SUMMER)
	world.set_time_of_day_override(12.0)
	world.current_view_distance = Gen.VIEW_PEAK_DISTANCE
	player.set_fly_mode(true)
	player.admin_teleport(Vector3(0.0, HIGHSPEED_CRUISE_Y, 0.0))
	player.test_mode = true
	# The benchmark owns a synthetic transform/velocity. Disabling player physics
	# prevents movement caps or input fixtures from contaminating the stream rate.
	player.set_physics_process(false)
	player.velocity = Vector3(HIGHSPEED_METERS_PER_SECOND, 0.0, 0.0)
	player.reset_physics_interpolation()

	# An actual jet climbs through the lower LOD tiers before reaching its cruise
	# flight level. The synthetic fixture teleports there instantly, so give the
	# bounded scheduler a stationary preflight phase to establish that initial
	# 15-mile ring. The measured moving warmup and 20-second cruise below still
	# prove sustained generation at exactly 1000 mph.
	player.velocity = Vector3.ZERO
	var preflight_time := 0.0
	var preflight_ready := false
	while preflight_time < HIGHSPEED_PREFLIGHT_SETTLE_SECONDS:
		await get_tree().process_frame
		preflight_time += maxf(get_process_delta_time(), 1.0 / 240.0)
		var preflight_snapshot := world.streaming_snapshot()
		preflight_ready = int(preflight_snapshot.near_current_missing) == 0 \
			and int(preflight_snapshot.horizon_inner_missing) == 0 \
			and int(preflight_snapshot.skyline_inner_missing) == 0 \
			and int(preflight_snapshot.stratos_required_missing) == 0
		if preflight_ready:
			break
	player.velocity = Vector3(HIGHSPEED_METERS_PER_SECOND, 0.0, 0.0)

	var elapsed := 0.0
	while elapsed < HIGHSPEED_WARMUP_SECONDS:
		await get_tree().process_frame
		var step_dt := maxf(get_process_delta_time(), 1.0 / 240.0)
		elapsed += step_dt
		# process_frame is emitted before node _process callbacks. Move now so the
		# World processes this position later in the same frame; the next signal is
		# therefore a stable post-stream point for sampling the previous move.
		_advance_highspeed_player(player, elapsed, step_dt)

	world.reset_streaming_metrics()
	var initial_snapshot := world.streaming_snapshot()
	var initial_pending := int(initial_snapshot.total_pending)
	var frame_times: Array[float] = []
	var sample_time := 0.0
	var center_hole_frames := 0
	var max_near_missing := 0
	var max_near_visible_missing := 0
	var max_near_detail_missing := 0
	var max_horizon_missing := 0
	var max_skyline_missing := 0
	var max_stratos_missing := 0
	var max_cruise_collision_missing := 0
	var min_stratos_coverage_margin := INF
	var max_canopy_sector_missing := 0
	var max_near_queue := 0
	var max_total_pending := 0
	var max_shell_age := 0.0
	var max_tree_age := 0.0
	var min_prediction_lead := INF
	var max_shell_usec := 0
	var max_safety_usec := 0
	var max_decoration_usec := 0
	var max_canopy_vertices := 0
	var max_streamed_vehicles := 0
	var max_spawned_vehicle_ids := 0
	var max_vehicle_nodes := 0
	var max_stratos_required := 0
	var max_stratos_square_capacity := 0
	var circular_culling_seen := false
	var literal_suppression_seen := false
	var stratos_canopy_handoff_seen := false
	var max_active_near_detail := 0
	var over_100 := 0
	var snapshot_usec_total := 0
	var snapshot_usec_max := 0
	while sample_time < HIGHSPEED_SAMPLE_SECONDS:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		frame_times.append(dt)
		sample_time += dt
		over_100 += 1 if dt > 0.100 else 0
		# Sample before advancing: World streamed the current transform during the
		# frame that just completed, eliminating a false one-frame boundary hole.
		var snapshot_started := Time.get_ticks_usec()
		var snapshot := world.streaming_snapshot()
		var snapshot_usec := Time.get_ticks_usec() - snapshot_started
		snapshot_usec_total += snapshot_usec
		snapshot_usec_max = maxi(snapshot_usec_max, snapshot_usec)
		var near_missing := int(snapshot.near_path_missing)
		var near_visible_missing := int(snapshot.near_current_missing)
		center_hole_frames += 1 if near_missing > 0 else 0
		max_near_missing = maxi(max_near_missing, near_missing)
		max_near_visible_missing = maxi(max_near_visible_missing,
			near_visible_missing)
		max_near_detail_missing = maxi(max_near_detail_missing,
			int(snapshot.near_detail_missing))
		max_horizon_missing = maxi(max_horizon_missing,
			int(snapshot.horizon_inner_missing))
		max_skyline_missing = maxi(max_skyline_missing,
			int(snapshot.skyline_inner_missing))
		max_stratos_missing = maxi(max_stratos_missing,
			int(snapshot.stratos_required_missing))
		max_cruise_collision_missing = maxi(max_cruise_collision_missing,
			int(snapshot.collision_corridor_missing))
		min_stratos_coverage_margin = minf(min_stratos_coverage_margin,
			minf(float(snapshot.stratos_cardinal_coverage_m),
				float(snapshot.stratos_radial_coverage_m)) \
				- world.current_view_distance)
		max_canopy_sector_missing = maxi(max_canopy_sector_missing,
			int(snapshot.stratos_required_loaded) \
				- int(snapshot.stratos_canopy_sectors))
		max_near_queue = maxi(max_near_queue, int(snapshot.near_queue))
		max_total_pending = maxi(max_total_pending, int(snapshot.total_pending))
		max_shell_age = maxf(max_shell_age, float(snapshot.shell_oldest_ms))
		max_tree_age = maxf(max_tree_age, float(snapshot.far_tree_oldest_ms))
		min_prediction_lead = minf(min_prediction_lead,
			float(snapshot.prediction_lead_m))
		max_shell_usec = maxi(max_shell_usec, int(snapshot.shell_usec))
		max_safety_usec = maxi(max_safety_usec, int(snapshot.safety_usec))
		max_decoration_usec = maxi(max_decoration_usec,
			int(snapshot.decoration_usec))
		max_canopy_vertices = maxi(max_canopy_vertices,
			int(snapshot.stratos_canopy_vertices))
		max_streamed_vehicles = maxi(max_streamed_vehicles,
			int(snapshot.streamed_unprotected_vehicles))
		max_spawned_vehicle_ids = maxi(max_spawned_vehicle_ids,
			int(snapshot.spawned_vehicle_ids))
		max_vehicle_nodes = maxi(max_vehicle_nodes, int(snapshot.vehicle_nodes))
		max_stratos_required = maxi(max_stratos_required,
			int(snapshot.stratos_required))
		max_stratos_square_capacity = maxi(max_stratos_square_capacity,
			int(snapshot.stratos_square_capacity))
		circular_culling_seen = circular_culling_seen \
			or int(snapshot.stratos_culled_corner_targets) > 0
		literal_suppression_seen = literal_suppression_seen \
			or bool(snapshot.literal_detail_suppressed)
		stratos_canopy_handoff_seen = stratos_canopy_handoff_seen \
			or str(snapshot.canopy_signal_tier) == "stratos_tint"
		max_active_near_detail = maxi(max_active_near_detail,
			int(snapshot.near_detail_queue))
		elapsed += dt
		_advance_highspeed_player(player, elapsed, dt)

	var cruise_final_snapshot := world.streaming_snapshot()
	var cruise_final_pending := int(cruise_final_snapshot.total_pending)
	# Put a real unoccupied rigid-body Jeep three chunks from a stationary
	# high-altitude player. This is deliberately outside the ordinary 5x5 near
	# window: the machine's bounded actor patch must enqueue its missing terrain
	# shell before collision can finish.
	var parked_source := world.center_chunk() + Vector2i(3, 0)
	var parked_x := (float(parked_source.x) + 0.5) * Gen.CHUNK
	var parked_z := (float(parked_source.y) + 0.5) * Gen.CHUNK
	var probe_ground := Gen.height(player.global_position.x,
		player.global_position.z)
	var parked_ground := Gen.height(parked_x, parked_z)
	player.global_position.y = probe_ground + 80.0
	player.velocity = Vector3.ZERO
	var parked_vehicle: Vehicle = world.spawn_vehicle(Vehicle.Kind.JEEP,
		"v:perftest#parked-floor", Vector3(parked_x, parked_ground, parked_z), 0.0)
	parked_vehicle.sleeping = true
	var parked_probe_time := 0.0
	var parked_vehicle_tracking_seen := false
	var parked_vehicle_shell_target_seen := false
	var parked_vehicle_actor_bound_held := true
	var parked_vehicle_ready_frames := 0
	var parked_vehicle_visible_missing := 0
	while parked_probe_time < HIGHSPEED_PARKED_VEHICLE_PROBE_SECONDS:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		var snapshot := world.streaming_snapshot()
		var vehicle_only_requirement := not bool(snapshot.local_collision_required) \
			and bool(snapshot.ground_collision_required) \
			and int(snapshot.tracked_ground_vehicles) >= 1 \
			and int(snapshot.collision_targets) >= 9
		parked_vehicle_tracking_seen = parked_vehicle_tracking_seen \
			or vehicle_only_requirement
		parked_vehicle_shell_target_seen = parked_vehicle_shell_target_seen \
			or world._near_targets.has(parked_source)
		parked_vehicle_actor_bound_held = parked_vehicle_actor_bound_held \
			and int(snapshot.actor_collision_targets) \
				<= int(snapshot.actor_collision_target_limit)
		if vehicle_only_requirement \
				and int(snapshot.collision_corridor_missing) == 0:
			parked_vehicle_ready_frames += 1
		max_near_queue = maxi(max_near_queue, int(snapshot.near_queue))
		# This fixture teleports vertically from 6.1 km to 80 m AGL, unlike a real
		# descent that wakes detail/shells three seconds ahead. Give the newly
		# expanded 5x5 one bounded settle window, then require every sampled frame
		# to remain complete for the rest of the parked-vehicle probe.
		if parked_probe_time >= HIGHSPEED_PARKED_SHELL_SETTLE_SECONDS:
			parked_vehicle_visible_missing = maxi(parked_vehicle_visible_missing,
				int(snapshot.near_current_missing))
		parked_probe_time += dt
	# Non-vacuous collision proof: descend from 60 m AGL while moving at 80 m/s,
	# then hold still near the terrain. The world must request collision before
	# impact and finish the full local safety corridor (terrain, trees, structures).
	player.global_position.y = probe_ground + 60.0
	player.velocity.y = -HIGHSPEED_DESCENT_SPEED
	var collision_time := 0.0
	var collision_requirement_seen := false
	var collision_target_peak := 0
	var collision_peak_missing := 0
	var collision_final_missing := 0x3fffffff
	var collision_ready_frames := 0
	var collision_visible_missing := 0
	while collision_time < HIGHSPEED_COLLISION_LEG_SECONDS:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		var snapshot := world.streaming_snapshot()
		collision_requirement_seen = collision_requirement_seen \
			or bool(snapshot.local_collision_required)
		collision_target_peak = maxi(collision_target_peak,
			int(snapshot.collision_targets))
		collision_peak_missing = maxi(collision_peak_missing,
			int(snapshot.collision_corridor_missing))
		collision_final_missing = int(snapshot.collision_corridor_missing)
		collision_ready_frames += 1 \
			if bool(snapshot.local_collision_required) \
				and int(snapshot.collision_targets) >= 9 \
				and collision_final_missing == 0 else 0
		collision_visible_missing = maxi(collision_visible_missing,
			int(snapshot.near_current_missing))
		collision_time += dt
		_advance_collision_probe(player, collision_time, dt)

	var final_snapshot := world.streaming_snapshot()
	var final_pending := int(final_snapshot.total_pending)
	frame_times.sort()
	var total := 0.0
	for dt in frame_times:
		total += dt
	var average_fps := float(frame_times.size()) / maxf(total, 0.001)
	var p95_index := clampi(floori(float(frame_times.size() - 1) * 0.95), 0,
		maxi(frame_times.size() - 1, 0))
	var p99_index := clampi(floori(float(frame_times.size() - 1) * 0.99), 0,
		maxi(frame_times.size() - 1, 0))
	var p95_ms := frame_times[p95_index] * 1000.0 if not frame_times.is_empty() else 0.0
	var p99_ms := frame_times[p99_index] * 1000.0 if not frame_times.is_empty() else 0.0
	var max_ms := frame_times[-1] * 1000.0 if not frame_times.is_empty() else 0.0
	var refresh := DisplayServer.screen_get_refresh_rate()
	var rendered := DisplayServer.get_name() != "headless"
	var cap_allows_target := Engine.max_fps == 0 \
		or Engine.max_fps >= int(HIGHSPEED_TARGET_FPS)
	# Some macOS compositors report a stale/unknown refresh rate even when an
	# uncapped rendered process is demonstrably running above it. Accept that as
	# proof only when measured throughput clears the reported rate by 25%.
	var measured_above_refresh := refresh > 1.0 \
		and average_fps > refresh * 1.25
	var can_measure_target := rendered and cap_allows_target \
		and (refresh >= HIGHSPEED_TARGET_FPS - 1.0 or measured_above_refresh)
	var performance_pass := average_fps >= HIGHSPEED_TARGET_FPS \
		and p95_ms <= HIGHSPEED_MAX_P95_MS \
		and p99_ms <= HIGHSPEED_MAX_P99_MS \
		and max_ms < HIGHSPEED_MAX_FRAME_MS and over_100 == 0
	var stretch_capable := rendered and (Engine.max_fps == 0 \
		or Engine.max_fps >= int(HIGHSPEED_STRETCH_FPS)) \
		and (refresh >= HIGHSPEED_STRETCH_FPS - 1.0 or measured_above_refresh)
	var stretch_pass := average_fps >= HIGHSPEED_STRETCH_FPS \
		and p95_ms <= HIGHSPEED_STRETCH_P95_MS
	var coverage_pass := center_hole_frames == 0 and max_near_missing == 0 \
		and max_near_visible_missing == 0 \
		and max_horizon_missing == 0 and max_skyline_missing == 0 \
		and max_stratos_missing == 0 and max_cruise_collision_missing == 0 \
		and parked_vehicle_visible_missing == 0 and collision_visible_missing == 0
	var queue_pass := max_near_queue <= HIGHSPEED_MAX_NEAR_QUEUE \
		and max_shell_age <= HIGHSPEED_MAX_SHELL_AGE_MS \
		and max_tree_age <= HIGHSPEED_MAX_TREE_AGE_MS \
		and cruise_final_pending <= initial_pending + HIGHSPEED_MAX_PENDING_GROWTH
	var prediction_pass := min_prediction_lead >= HIGHSPEED_MIN_PREDICTION_LEAD
	var canopy_pass := max_stratos_missing == 0 \
		and min_stratos_coverage_margin >= 0.0 \
		and max_canopy_sector_missing == 0 and max_canopy_vertices > 0 \
		and circular_culling_seen and literal_suppression_seen \
		and stratos_canopy_handoff_seen \
		and max_active_near_detail == 0
	var collision_pass := collision_requirement_seen \
		and collision_target_peak >= 9 and collision_final_missing == 0 \
		and collision_ready_frames > 0 and parked_vehicle_tracking_seen \
		and parked_vehicle_shell_target_seen and parked_vehicle_actor_bound_held \
		and parked_vehicle_ready_frames > 0
	var vehicle_pass := max_streamed_vehicles \
		<= HIGHSPEED_MAX_STREAMED_VEHICLES \
		and max_spawned_vehicle_ids <= HIGHSPEED_MAX_SPAWNED_VEHICLE_IDS \
		and max_vehicle_nodes <= HIGHSPEED_MAX_VEHICLE_NODES \
		and int(final_snapshot.streamed_unprotected_vehicles) \
		<= HIGHSPEED_MAX_STREAMED_VEHICLES \
		and int(final_snapshot.spawned_vehicle_ids) \
		<= HIGHSPEED_MAX_SPAWNED_VEHICLE_IDS \
		and int(final_snapshot.vehicle_nodes) <= HIGHSPEED_MAX_VEHICLE_NODES
	var correctness_pass := preflight_ready and coverage_pass and queue_pass \
		and prediction_pass and canopy_pass and collision_pass and vehicle_pass
	var performance_status := "PASS" if performance_pass else "FAIL"
	if not can_measure_target:
		performance_status = "UNVERIFIED_REFRESH"
	var overall_status := "PASS"
	var exit_code := 0
	if not correctness_pass:
		overall_status = "FAIL"
		exit_code = 1
	elif not can_measure_target:
		overall_status = "UNVERIFIED"
		exit_code = 2
	elif not performance_pass:
		overall_status = "FAIL"
		exit_code = 1

	print(("HIGHSPEED_RESULT speed_mps=%.2f mph=1000 duration=%.2f " \
		+ "adapter=\"%s\" rendered=%s refresh=%.0f vsync=%d cap=%d " \
		+ "proof_capable=%s avg_fps=%.1f p95_ms=%.2f " \
		+ "p99_ms=%.2f max_ms=%.2f over100=%d") % [
		HIGHSPEED_METERS_PER_SECOND, sample_time,
		RenderingServer.get_video_adapter_name(), str(rendered), refresh,
		int(DisplayServer.window_get_vsync_mode()), Engine.max_fps,
		str(can_measure_target), average_fps, p95_ms, p99_ms, max_ms, over_100,
	])
	print(("HIGHSPEED_STREAM path_missing=%d visible_edge_missing=%d " \
		+ "near_detail_handoff=%d " \
		+ "hole_frames=%d horizon_missing=%d " \
		+ "skyline_missing=%d stratos_missing=%d stratos_margin_m=%.0f " \
		+ "canopy_sector_missing=%d cruise_collision_missing=%d " \
		+ "lead_m=%.0f near_q=%d pending_initial=%d pending_max=%d " \
		+ "pending_cruise_final=%d pending_probe_final=%d " \
		+ "shell_age_ms=%.0f tree_age_ms=%.0f canopy_vertices=%d " \
		+ "stratos_targets=%d/%d circular=%s detail_q=%d " \
		+ "lane_max_usec=%d/%d/%d diagnostic_usec=%d/%d " \
		+ "shells=%d cancelled=%d") % [
		max_near_missing, max_near_visible_missing, max_near_detail_missing,
		center_hole_frames,
		max_horizon_missing,
		max_skyline_missing, max_stratos_missing, min_stratos_coverage_margin,
		max_canopy_sector_missing, max_cruise_collision_missing,
		min_prediction_lead, max_near_queue, initial_pending, max_total_pending,
		cruise_final_pending, final_pending, max_shell_age, max_tree_age,
		max_canopy_vertices, max_stratos_required, max_stratos_square_capacity,
		str(circular_culling_seen), max_active_near_detail,
		max_shell_usec, max_safety_usec, max_decoration_usec,
		int(snapshot_usec_total / maxi(frame_times.size(), 1)), snapshot_usec_max,
		int(final_snapshot.shells_built), int(final_snapshot.cancelled_jobs),
	])
	print(("HIGHSPEED_COLLISION requirement_seen=%s target_peak=%d " \
		+ "peak_missing=%d final_missing=%d ready_frames=%d " \
		+ "visible_missing=%d parked_tracking=%s parked_shell=%s " \
		+ "parked_bound=%s parked_ready_frames=%d " \
		+ "parked_visible_missing=%d") % [
		str(collision_requirement_seen), collision_target_peak,
		collision_peak_missing, collision_final_missing,
		collision_ready_frames, collision_visible_missing,
		str(parked_vehicle_tracking_seen), str(parked_vehicle_shell_target_seen),
		str(parked_vehicle_actor_bound_held), parked_vehicle_ready_frames,
		parked_vehicle_visible_missing,
	])
	print(("HIGHSPEED_VEHICLES max_streamed=%d max_spawned_ids=%d " \
		+ "max_nodes=%d final_streamed=%d final_spawned_ids=%d final_nodes=%d") % [
		max_streamed_vehicles, max_spawned_vehicle_ids, max_vehicle_nodes,
		int(final_snapshot.streamed_unprotected_vehicles),
		int(final_snapshot.spawned_vehicle_ids), int(final_snapshot.vehicle_nodes),
	])
	print(("HIGHSPEED_CORRECTNESS_GATE %s preflight=%s coverage=%s queues=%s " \
		+ "prediction=%s canopy=%s collision=%s vehicles=%s thresholds=" \
		+ "speed=447.04 lead>=%.0fm near_q<=%d shell_age<=%.0fms " \
		+ "tree_age<=%.0fms streamed<=%d spawned_ids<=%d nodes<=%d") % [
		"PASS" if correctness_pass else "FAIL",
		"PASS" if preflight_ready else "FAIL",
		"PASS" if coverage_pass else "FAIL",
		"PASS" if queue_pass else "FAIL",
		"PASS" if prediction_pass else "FAIL",
		"PASS" if canopy_pass else "FAIL",
		"PASS" if collision_pass else "FAIL",
		"PASS" if vehicle_pass else "FAIL",
		HIGHSPEED_MIN_PREDICTION_LEAD, HIGHSPEED_MAX_NEAR_QUEUE,
		HIGHSPEED_MAX_SHELL_AGE_MS, HIGHSPEED_MAX_TREE_AGE_MS,
		HIGHSPEED_MAX_STREAMED_VEHICLES,
		HIGHSPEED_MAX_SPAWNED_VEHICLE_IDS, HIGHSPEED_MAX_VEHICLE_NODES,
	])
	print(("HIGHSPEED_PERFORMANCE_GATE %s proof_capable=%s " \
		+ "stretch=%s stretch_capable=%s thresholds=avg_fps>=%.0f " \
		+ "p95<=%.1fms p99<=%.0fms max<%.0fms stretch_fps>=%.0f") % [
		performance_status, str(can_measure_target),
		"PASS" if stretch_pass else "MISS", str(stretch_capable),
		HIGHSPEED_TARGET_FPS, HIGHSPEED_MAX_P95_MS, HIGHSPEED_MAX_P99_MS,
		HIGHSPEED_MAX_FRAME_MS, HIGHSPEED_STRETCH_FPS,
	])
	print("HIGHSPEED_GATE %s correctness=%s performance=%s" % [
		overall_status, "PASS" if correctness_pass else "FAIL",
		performance_status,
	])
	get_tree().quit(exit_code)
