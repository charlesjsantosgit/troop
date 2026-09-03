extends Node
## Motion diagnostics against the production path, render clock and camera pose.
## Projection is computed from real transforms/FOV; it does not depend on the
## placeholder projection/mesh results returned by Godot's headless renderer.

const HULL_MARKERS := [Vector3.ZERO, Vector3(0, 17.0, 0),
	Vector3(0, -10.6, 0), Vector3(3.65, 0, 0), Vector3(-3.65, 0, 0),
	Vector3(0, 0, 4.65), Vector3(0, 0, -3.65)]
const OUTBOUND_KNOTS := [0.0, 1.05, 7.5, 10.0, 13.5, 14.0, 18.0, 21.0,
	24.0, 28.0, 36.0, 40.0, 43.5, 44.0, 46.0, 48.0, 50.0, 60.0]
const RETURN_KNOTS := [0.0, 6.0, 8.0, 10.0, 16.0, 18.0, 21.0, 24.0,
	28.0, 30.0, 36.0, 38.0, 40.0, 45.0]
var passed := 0
var total := 0
var main: Node
var manager: ExpeditionManager
var rocket: LunarRocket
var player: MonkeyPlayer
var viewport_size := Vector2(1600, 900)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _check(ok: bool, label: String, detail := "") -> void:
	total += 1
	passed += int(ok)
	print("[%s] %s%s" % ["PASS" if ok else "FAIL", label,
		" :: " + detail if not detail.is_empty() else ""])


func configure(owner_main: Node) -> void:
	main = owner_main
	manager = main.expedition_manager
	rocket = manager.rocket
	player = main.world.local_player
	viewport_size = get_viewport().get_visible_rect().size
	if viewport_size.x < 1.0 or viewport_size.y < 1.0:
		viewport_size = Vector2(1600, 900)
	main.set_process(false)
	manager.set_process(false)
	Net.set_process(false)
	rocket.set_physics_process(false)
	rocket.set_process(false)
	player.test_mode = true
	player.ti.dir = Vector2.ZERO
	player.velocity = Vector3.ZERO
	player.set_physics_process(false)
	player.set_expedition_locked(true)
	if player.cam:
		player.cam.set_process(false)
		player.cam.set_physics_process(false)
	main.world.set_earth_streaming_enabled(false)
	rocket.voyage_visuals.set_local_viewer_enabled(true)
	rocket.voyage_visuals.set_cinematic_terrain_enabled(true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _duration(outbound: bool) -> float:
	return LunarRocket.OUTBOUND_DURATION_SECONDS if outbound else LunarRocket.RETURN_DURATION_SECONDS


func _new_mission(outbound: bool, elapsed := 0.0) -> void:
	rocket.apply_authoritative_clock(LunarRocket.State.EARTH_BOARDING if outbound \
		else LunarRocket.State.LANDED_MOON, outbound, 0.0)
	rocket.synchronize_authoritative_clock(
		LunarRocket.state_for_elapsed(outbound, elapsed), outbound, elapsed)


func _path(elapsed: float, outbound: bool) -> Transform3D:
	rocket.outbound = outbound
	return rocket._flight_transform(clampf(elapsed / _duration(outbound), 0.0, 1.0))


func project_markers(rocket_transform: Transform3D, camera_transform: Transform3D,
		fov: float) -> PackedVector2Array:
	var projected := PackedVector2Array()
	var aspect := viewport_size.x / viewport_size.y
	var half_height := tan(deg_to_rad(fov) * 0.5)
	var half_width := half_height * aspect
	if manager.voyage_camera.keep_aspect == Camera3D.KEEP_WIDTH:
		half_width = half_height
		half_height /= aspect
	var inverse := camera_transform.affine_inverse()
	for marker in HULL_MARKERS:
		var point: Vector3 = inverse * (rocket_transform * marker)
		if -point.z <= manager.voyage_camera.near:
			projected.append(Vector2(INF, INF))
		else:
			projected.append(Vector2((point.x / (-point.z * half_width) + 1.0) * 0.5,
				(1.0 - point.y / (-point.z * half_height)) * 0.5) * viewport_size)
	return projected


func sample_scene(elapsed: float, outbound: bool) -> Dictionary:
	rocket.voyage_visuals.set_local_viewer_enabled(true)
	rocket.voyage_visuals.set_cinematic_terrain_enabled(true)
	# A previous sampled endpoint can end presentation. Re-arm explicit seeks so
	# the Earth anchor, planets and camera always describe this same instant.
	rocket.apply_authoritative_clock(LunarRocket.state_for_elapsed(outbound, elapsed),
		outbound, elapsed)
	var sample := rocket.render_sample(elapsed)
	rocket.present_render_sample(sample)
	var transform: Transform3D = sample.transform
	var pose := manager.sample_voyage_camera_pose(float(sample.elapsed), transform, outbound)
	var camera_transform := Transform3D(Basis.IDENTITY, pose.position).looking_at(pose.focus, pose.up)
	return {"elapsed": float(sample.elapsed), "rocket": transform, "camera": camera_transform,
		"fov": float(pose.fov), "up": pose.up, "focus": pose.focus,
		"relative_position": camera_transform.origin - transform.origin,
		"screen": project_markers(transform, camera_transform, float(pose.fov))}


func _pixel_distance(a: Dictionary, b: Dictionary) -> float:
	var largest := 0.0
	for index in range(HULL_MARKERS.size()):
		var pa: Vector2 = a.screen[index]
		var pb: Vector2 = b.screen[index]
		if not pa.is_finite() or not pb.is_finite():
			return INF
		largest = maxf(largest, pa.distance_to(pb))
	return largest


func run(owner_main: Node) -> void:
	print("ROCKET SMOOTHNESS TEST")
	configure(owner_main)
	_test_path_continuity()
	_test_camera_continuity()
	_test_moon_arrival_visibility()
	_test_moon_physical_ground()
	_test_moon_departure_continuity()
	_test_earth_return_surface()
	_test_earth_return_lighting()
	_test_render_rates()
	_test_clock_corrections()
	await _test_pause()
	print("ROCKETSMOOTHTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	main._return_to_main_menu()
	for _frame in range(4):
		await get_tree().process_frame
	get_tree().quit(0 if passed == total else 1)


func _test_path_continuity() -> void:
	for outbound in [true, false]:
		var label := "outbound" if outbound else "return"
		var duration := _duration(outbound)
		var start := rocket.earth_launch_transform if outbound else rocket.moon_landing_transform
		var finish := rocket.moon_landing_transform if outbound else rocket.ocean_splashdown_transform
		_check(_path(0.0, outbound).is_equal_approx(start) \
			and _path(duration, outbound).is_equal_approx(finish),
			"%s route lands on exact authored endpoint transforms" % label)
		var finite := true
		var max_spin := 0.0
		var max_nose_rate := 0.0
		var max_half_step_ratio := 0.0
		var spin_at := 0.0
		var previous := _path(0.0, outbound)
		for frame in range(1, int(duration * 20.0) + 1):
			var time := float(frame) / 20.0
			var pose := _path(time, outbound)
			finite = finite and pose.is_finite() and absf(pose.basis.determinant() - 1.0) < 0.001
			var spin := rad_to_deg(previous.basis.get_rotation_quaternion().angle_to(
				pose.basis.get_rotation_quaternion())) * 20.0
			var nose_rate := rad_to_deg(previous.basis.y.angle_to(pose.basis.y)) * 20.0
			max_nose_rate = maxf(max_nose_rate, nose_rate)
			var midpoint := _path(time - 0.025, outbound)
			var first_half := rad_to_deg(previous.basis.get_rotation_quaternion().angle_to(
				midpoint.basis.get_rotation_quaternion())) * 40.0
			var second_half := rad_to_deg(midpoint.basis.get_rotation_quaternion().angle_to(
				pose.basis.get_rotation_quaternion())) * 40.0
			if spin > 10.0:
				max_half_step_ratio = maxf(max_half_step_ratio, maxf(first_half, second_half) / spin)
			if spin > max_spin:
				max_spin = spin
				spin_at = time
			previous = pose
		# A real discontinuity grows toward twice the apparent angular speed when
		# the sampling interval halves; a continuous turn converges instead.
		_check(finite and max_spin < 150.0 and max_half_step_ratio < 1.35,
			"%s attitude stays finite and turns continuously through the entire voyage" % label,
			"max_deg_per_sec=%.3f at=%.3f nose_deg_per_sec=%.3f half_step_ratio=%.3f" \
				% [max_spin, spin_at, max_nose_rate, max_half_step_ratio])
		var physical_knots: Array = [14.0, 50.0] if outbound else [6.0, 40.0]
		for time in physical_knots:
			const STEP := 0.05
			var p0 := _path(float(time), outbound).origin
			var before := _path(float(time) - STEP, outbound).origin
			var before2 := _path(float(time) - STEP * 2.0, outbound).origin
			var after := _path(float(time) + STEP, outbound).origin
			var after2 := _path(float(time) + STEP * 2.0, outbound).origin
			var velocity_before := (p0 - before) / STEP
			var velocity_after := (after - p0) / STEP
			var acceleration_before := (p0 - before * 2.0 + before2) / (STEP * STEP)
			var acceleration_after := (after2 - after * 2.0 + p0) / (STEP * STEP)
			var velocity_jump := velocity_after.distance_to(velocity_before)
			var acceleration_jump := acceleration_after.distance_to(acceleration_before)
			_check(velocity_jump < 40.0 and acceleration_jump < 60.0,
				"%s %.1fs path junction has continuous velocity and acceleration" % [label, time],
				"velocity_delta=%.3f m/s acceleration_delta=%.3f m/s2" % [velocity_jump, acceleration_jump])
		var final_speed := _path(duration - 0.05, outbound).origin.distance_to(finish.origin) / 0.05
		_check(final_speed < 1.0,
			"%s contact approaches rest before the landed pose takes over" % label,
			"last_50ms_speed=%.4f m/s" % final_speed)


func _test_camera_continuity() -> void:
	for outbound in [true, false]:
		var label := "outbound" if outbound else "return"
		var knots: Array = OUTBOUND_KNOTS if outbound else RETURN_KNOTS
		var maximum_pixels := 0.0
		var maximum_fov := 0.0
		var worst_time := 0.0
		for time in knots:
			if float(time) <= 0.0 or float(time) >= _duration(outbound):
				continue
			var before := sample_scene(float(time) - 0.001, outbound)
			var after := sample_scene(float(time) + 0.001, outbound)
			var pixels := _pixel_distance(before, after)
			if pixels > maximum_pixels:
				maximum_pixels = pixels
				worst_time = float(time)
			maximum_fov = maxf(maximum_fov, absf(float(after.fov) - float(before.fov)))
		_check(maximum_pixels < 2.0 and maximum_fov < 0.05,
			"%s camera has no screen-space cut or FOV step at any authored boundary" % label,
			"max_pixels=%.4f at=%.3f max_fov_delta=%.5f" % [maximum_pixels, worst_time, maximum_fov])
		var max_frame_motion := 0.0
		var visible := true
		var previous := sample_scene(0.0, outbound)
		# Every displayed marker is measured throughout the complete voyage, not
		# merely at phase signal callbacks or a few selected screenshots.
		for frame in range(1, int(_duration(outbound) * 30.0) + 1):
			var current := sample_scene(float(frame) / 30.0, outbound)
			for point in current.screen:
				visible = visible and point.is_finite() \
					and point.x >= -1.0 and point.x <= viewport_size.x + 1.0 \
					and point.y >= -1.0 and point.y <= viewport_size.y + 1.0
			max_frame_motion = maxf(max_frame_motion, _pixel_distance(previous, current))
			previous = current
		_check(visible and max_frame_motion < 25.0,
			"%s full 30 FPS camera track keeps the hull visible without one-frame jumps" % label,
			"max_marker_motion=%.3f pixels/frame" % max_frame_motion)
	var high_frequency_acceleration := 0.0
	for index in range(21):
		var time := 29.0 + float(index) * 0.5
		var before := sample_scene(time - 0.05, false)
		var at_time := sample_scene(time, false)
		var after := sample_scene(time + 0.05, false)
		var acceleration: Vector3 = (after.relative_position - at_time.relative_position * 2.0 \
			+ before.relative_position) / (0.05 * 0.05)
		high_frequency_acceleration = maxf(high_frequency_acceleration, acceleration.length())
	_check(high_frequency_acceleration < 25.0,
		"reentry camera contains no high-frequency authored vibration",
		"peak_relative_acceleration=%.3f m/s2" % high_frequency_acceleration)


func _sphere_reaches_view(camera: Transform3D, fov: float,
		center: Vector3, radius: float) -> bool:
	var local := camera.affine_inverse() * center
	var half_height := tan(deg_to_rad(fov) * 0.5)
	var half_width := half_height * viewport_size.x / viewport_size.y
	if manager.voyage_camera.keep_aspect == Camera3D.KEEP_WIDTH:
		half_width = half_height
		half_height *= viewport_size.y / viewport_size.x
	var depth := -local.z
	if depth + radius <= manager.voyage_camera.near or local.length_squared() <= radius * radius:
		return false
	# Aim at the closest point on the actual viewport to the sphere's centre.
	# A ray/sphere hit also proves pixels are present when the centre is below
	# the frame, where a centre-only on-screen assertion would reject a limb.
	var ray := Vector3(clampf(local.x / maxf(depth, 0.001), -half_width, half_width),
		clampf(local.y / maxf(depth, 0.001), -half_height, half_height), -1.0).normalized()
	var along := local.dot(ray)
	var squared_miss := (local - ray * along).length_squared()
	if along < 0.0 or squared_miss > radius * radius:
		return false
	var near_hit := along - sqrt(maxf(radius * radius - squared_miss, 0.0))
	return near_hit <= manager.voyage_camera.far


func _test_moon_arrival_visibility() -> void:
	var moon := manager.moon_world
	var absent_frames := 0
	var first_absent := -1.0
	var minimum_proxy_clearance := INF
	var minimum_ground_clearance := INF
	var hull_markers: Array = HULL_MARKERS
	for frame in range(601):
		var elapsed := 40.0 + float(frame) / 60.0
		var scene := sample_scene(elapsed, true)
		manager._update_transit_world_visibility()
		var proxy_center := rocket.voyage_visuals.moon_visual.global_position
		var proxy_radius := rocket.voyage_visuals.moon_render_radius
		if not rocket.voyage_visuals.moon_visual.visible \
				or rocket.voyage_visuals.moon_visual.transparency > 0.001 \
				or not _sphere_reaches_view(scene.camera, float(scene.fov), proxy_center, proxy_radius):
			absent_frames += 1
			if first_absent < 0.0:
				first_absent = elapsed
		var ground_radius: float = moon._horizon_material.get_shader_parameter("scaled_moon_radius")
		var surface: Vector3 = moon._horizon_material.get_shader_parameter("scaled_surface_local")
		var retraction: float = moon._horizon_material.get_shader_parameter("scaled_cap_retraction")
		var center_local := surface - Vector3.UP * ground_radius
		var ground_center := moon.to_global(center_local)
		var inward_bias := smoothstep(0.8, 1.0, retraction) * maxf(0.015, ground_radius * 0.001)
		var hull_transform: Transform3D = scene.rocket
		for marker in hull_markers:
			var world_point: Vector3 = hull_transform * marker
			minimum_proxy_clearance = minf(minimum_proxy_clearance,
				world_point.distance_to(proxy_center) - proxy_radius)
			var direction := (moon.to_local(world_point) - center_local).normalized()
			var physical_surface := moon.surface_position(direction)
			var relief := physical_surface.distance_to(MoonWorld.PLAYABLE_CENTER) \
				- MoonWorld.PLAYABLE_RADIUS_METERS
			var surface_radius := ground_radius + relief * ground_radius \
				/ MoonWorld.PLAYABLE_RADIUS_METERS - inward_bias
			minimum_ground_clearance = minf(minimum_ground_clearance,
				world_point.distance_to(ground_center) - surface_radius)
	_check(absent_frames == 0,
		"Moon limb remains in the actual camera view for every 60 Hz frame from 40 to 50 seconds",
		"absent_frames=%d first_absent=%.4f" % [absent_frames, first_absent])
	_check(minimum_proxy_clearance > 0.1 and minimum_ground_clearance > 0.1,
		"Moon arrival keeps the hull outside both the opaque globe and the rendered relief",
		"minimum_proxy_clearance=%.3f m minimum_ground_clearance=%.3f m" \
			% [minimum_proxy_clearance, minimum_ground_clearance])


func _rendered_moon_vertex(physical_vertex: Vector3) -> Vector3:
	var moon := manager.moon_world
	var material := moon._horizon_material
	var radius: float = material.get_shader_parameter("scaled_moon_radius")
	var surface: Vector3 = material.get_shader_parameter("scaled_surface_local")
	var retraction: float = material.get_shader_parameter("scaled_cap_retraction")
	var active: float = material.get_shader_parameter("scaled_space_active")
	var physical_offset := physical_vertex - MoonWorld.PLAYABLE_CENTER
	var relief := physical_offset.length() - MoonWorld.PLAYABLE_RADIUS_METERS
	var inward_bias := smoothstep(0.8, 1.0, retraction) * maxf(0.015, radius * 0.001)
	var rendered := surface - Vector3.UP * radius \
		+ physical_offset.normalized() * (radius \
			+ relief * radius / MoonWorld.PLAYABLE_RADIUS_METERS - inward_bias)
	return moon.to_global(physical_vertex.lerp(rendered, active))


func _test_moon_physical_ground() -> void:
	var moon := manager.moon_world
	# Include off-pad points: the north tangent alone cannot detect a wrongly
	# enlarged terrain radius beneath stationary farm/shop props.
	var farm := moon.colony_world.facility_roots["farm"] as Node3D
	var vertices: Array[Vector3] = [moon.surface_position(Vector3.UP),
		moon.to_local(moon.surface_position_at(moon.cheese_shop.global_position)),
		moon.to_local(moon.surface_position_at(farm.global_position))]
	var worst_error := 0.0
	var worst_time := 0.0
	var worst_leg := ""
	for outbound in [true, false]:
		var moments: Array = [50.0, 55.0, 60.0] if outbound else [0.0, 2.0, 4.0, 6.0, 8.0]
		for elapsed in moments:
			sample_scene(elapsed, outbound)
			manager._update_transit_world_visibility()
			for physical_vertex in vertices:
				var error := _rendered_moon_vertex(physical_vertex).distance_to(moon.to_global(physical_vertex))
				if error > worst_error:
					worst_error = error
					worst_time = elapsed
					worst_leg = "outbound" if outbound else "return"
	_check(worst_error < 0.02,
		"actual Moon shader vertices align with landing, shop and farm through arrival 50–60s and departure 0–8s",
		"maximum_ground_displacement=%.5f m leg=%s at=%.3f" % [worst_error, worst_leg, worst_time])


func _surface_clearance(point: Vector3, surface: Vector3, up: Vector3,
		radius: float) -> float:
	# Work near the tangent, not by subtracting two twelve-million-metre vectors.
	# Rationalizing sqrt(r*r + offset) - r preserves sub-metre contact precision.
	var offset := point - surface
	var height := offset.dot(up)
	var lateral := offset - up * height
	var difference := height * (2.0 * radius + height) + lateral.length_squared()
	return difference / (sqrt(maxf(radius * radius + difference, 0.0)) + radius)


func _test_moon_departure_continuity() -> void:
	var visuals := rocket.voyage_visuals
	var up := rocket.moon_landing_transform.basis.y.normalized()
	var physical_center := rocket.moon_landing_transform.origin \
		- up * (LunarRocket.ORIGIN_ABOVE_LANDING_SURFACE + MoonWorld.PLAYABLE_RADIUS_METERS)
	var maximum_center_error := 0.0
	var maximum_radius_error := 0.0
	var opaque := true
	var minimum_clearance := INF
	for frame in range(1350):
		var elapsed := float(frame) / 30.0
		var scene := sample_scene(elapsed, false)
		maximum_center_error = maxf(maximum_center_error,
			visuals.moon_visual.global_position.distance_to(physical_center))
		maximum_radius_error = maxf(maximum_radius_error,
			absf(visuals.moon_render_radius - SpaceVoyageVisuals.MOON_PROXY_PHYSICAL_RADIUS_UNITS))
		opaque = opaque and visuals.moon_visual.is_visible_in_tree() \
			and visuals.moon_visual.transparency < 0.001
		if elapsed >= 8.0:
			var pose: Transform3D = scene.rocket
			for marker in HULL_MARKERS:
				minimum_clearance = minf(minimum_clearance,
					(pose * marker).distance_to(physical_center) - MoonWorld.PLAYABLE_RADIUS_METERS)
	_check(opaque and maximum_center_error < 0.02 and maximum_radius_error < 0.001,
		"the return Moon stays opaque at one physical center and radius without a staged map reappearance",
		"center_error=%.6f m radius_error=%.6f m" % [maximum_center_error, maximum_radius_error])
	_check(minimum_clearance > 30.0,
		"the full returning hull clears the fixed physical Moon as the path descends toward the nearby Earth pad",
		"minimum_after_ascent_clearance=%.3f m" % minimum_clearance)


func _test_earth_return_surface() -> void:
	var visuals := rocket.voyage_visuals
	var absent_frames := 0
	var first_absent := -1.0
	for frame in range(1081):
		var elapsed := 18.0 + float(frame) / 60.0
		var scene := sample_scene(elapsed, false)
		if not visuals.earth_visual.is_visible_in_tree() \
				or visuals.earth_visual.transparency > 0.001 \
				or not _sphere_reaches_view(scene.camera, float(scene.fov),
					visuals.earth_visual.global_position, visuals.earth_render_radius):
			absent_frames += 1
			if first_absent < 0.0:
				first_absent = elapsed
	_check(absent_frames == 0,
		"return Earth remains visible in the actual camera during every 60 Hz frame from 18 to 36 seconds",
		"absent_frames=%d first_absent=%.4f" % [absent_frames, first_absent])
	var earth_up := rocket.earth_launch_transform.basis.y.normalized()
	var physical_surface := rocket.earth_launch_transform.origin \
		- earth_up * LunarRocket.ORIGIN_ABOVE_LANDING_SURFACE
	var real_chunks_visible := true
	var minimum_clearance := INF
	for frame in range(1021):
		var elapsed := 28.0 + float(frame) / 60.0
		var scene := sample_scene(elapsed, false)
		manager._update_transit_world_visibility()
		real_chunks_visible = real_chunks_visible and main.world.earth_transit_surface_visible()
		if elapsed < 38.0:
			real_chunks_visible = real_chunks_visible and Visuals._cinematic_curve_strength > 0.99 \
				and Visuals._cinematic_render_surface.distance_to(visuals.return_terrain_surface_anchor) < 0.01 \
				and is_equal_approx(Visuals._cinematic_render_radius, visuals.return_terrain_render_radius)
		var transform: Transform3D = scene.rocket
		for marker in HULL_MARKERS:
			minimum_clearance = minf(minimum_clearance, _surface_clearance(
				transform * marker, visuals.return_terrain_surface_anchor,
				earth_up, visuals.return_terrain_render_radius))
	_check(real_chunks_visible and not rocket.has_node("ReturnOceanSurface") \
		and not visuals.has_node("ReturnOceanSurface"),
		"the existing launch-site terrain receives the continuous return transform with no private ocean plane")
	_check(minimum_clearance > 0.05,
		"the complete 30 metre returning hull stays above its rendered landing surface through contact",
		"minimum_clearance=%.4f m" % minimum_clearance)
	sample_scene(38.0, false)
	var terrain_center := visuals.return_terrain_surface_anchor - earth_up * visuals.return_terrain_render_radius
	var globe_center := visuals.earth_surface_anchor - earth_up * visuals.earth_render_radius
	_check(rocket.ocean_splashdown_transform.is_equal_approx(rocket.earth_launch_transform) \
		and visuals.return_terrain_surface_anchor.distance_to(physical_surface) < 0.01 \
		and absf(visuals.return_terrain_render_radius - SpaceVoyageVisuals.EARTH_LOCAL_RADIUS_UNITS) < 0.01 \
		and terrain_center.distance_to(globe_center) < 0.01 \
		and visuals.earth_surface_anchor.y < Gen.WATER_Y - 1.9,
		"the return globe and real terrain become concentric at the original launchpad before landing")
	var precision_error := 0.0
	for offset in [Vector3.ZERO, Vector3(12.25, 0.037, 4.75),
		Vector3(-17.125, 0.249, -8.5), Vector3(500.25, -0.125, 240.5)]:
		var source: Vector3 = physical_surface + offset
		var planar_distance := Vector2(offset.x, offset.z).length()
		var sag := 2.0 * pow(sin(planar_distance / SpaceVoyageVisuals.EARTH_LOCAL_RADIUS_UNITS * 0.5), 2.0) \
			* SpaceVoyageVisuals.EARTH_LOCAL_RADIUS_UNITS
		var expected := source - Vector3.UP * sag
		precision_error = maxf(precision_error,
			Visuals.cinematic_earth_surface_point(source).distance_to(expected))
	_check(precision_error < 0.01,
		"the actual shared terrain transform preserves centimetre relief at the twelve-million-metre Earth radius",
		"maximum_error=%.6f m" % precision_error)
	sample_scene(40.0, false)
	var gameplay_point := physical_surface + Vector3(21.25, 0.375, -32.5)
	_check(is_zero_approx(Visuals._cinematic_curve_strength) \
		and Visuals.cinematic_earth_surface_point(gameplay_point).is_equal_approx(gameplay_point),
		"real Earth terrain reaches its unchanged gameplay vertices before the final vertical landing")
	var max_log_radius_step := 0.0
	var max_anchor_seam_error := 0.0
	var max_radius_seam_error := 0.0
	var max_halving_ratio := 0.0
	for elapsed in [20.0, 24.0, 28.0, 30.0, 36.0, 38.0, 40.0]:
		var outer_before := sample_scene(elapsed - 0.002, false)
		var outer_before_transform: Transform3D = outer_before.rocket
		var outer_before_anchor := visuals.return_terrain_surface_anchor - outer_before_transform.origin
		var outer_before_log_radius := log(visuals.earth_render_radius)
		var before := sample_scene(elapsed - 0.001, false)
		var before_log_radius := log(visuals.earth_render_radius)
		var before_transform: Transform3D = before.rocket
		var before_anchor := visuals.return_terrain_surface_anchor - before_transform.origin
		var after := sample_scene(elapsed + 0.001, false)
		var after_transform: Transform3D = after.rocket
		var after_anchor := visuals.return_terrain_surface_anchor - after_transform.origin
		var after_log_radius := log(visuals.earth_render_radius)
		var outer_after := sample_scene(elapsed + 0.002, false)
		var outer_after_transform: Transform3D = outer_after.rocket
		var outer_after_anchor := visuals.return_terrain_surface_anchor - outer_after_transform.origin
		var outer_after_log_radius := log(visuals.earth_render_radius)
		max_log_radius_step = maxf(max_log_radius_step,
			absf(after_log_radius - before_log_radius))
		# Extrapolate both sides back to the same instant. A fast but continuous
		# moving tangent agrees; comparing raw positions 2 ms apart confuses the
		# intended descent velocity with a pop. Float32 route positions need a
		# few centimetres of tolerance even though log-radius math is double.
		max_anchor_seam_error = maxf(max_anchor_seam_error,
			(before_anchor * 2.0 - outer_before_anchor).distance_to(
				after_anchor * 2.0 - outer_after_anchor))
		max_radius_seam_error = maxf(max_radius_seam_error, absf(
			before_log_radius * 2.0 - outer_before_log_radius \
			- after_log_radius * 2.0 + outer_after_log_radius))
		var large_anchor_step := outer_before_anchor.distance_to(outer_after_anchor)
		if large_anchor_step > 0.05:
			max_halving_ratio = maxf(max_halving_ratio,
				before_anchor.distance_to(after_anchor) * 2.0 / large_anchor_step)
		var large_radius_step := absf(outer_after_log_radius - outer_before_log_radius)
		if large_radius_step > 0.000001:
			max_halving_ratio = maxf(max_halving_ratio,
				absf(after_log_radius - before_log_radius) * 2.0 / large_radius_step)
	_check(max_log_radius_step < 0.01 and max_anchor_seam_error < 0.05 \
		and max_radius_seam_error < 0.00001 and max_halving_ratio < 1.35,
		"return globe size and near-surface anchor have no jump at growth, reveal or physical handoff boundaries",
		"log_radius_step=%.6f anchor_seam_error=%.4f m radius_seam_error=%.8f halving_ratio=%.4f" \
			% [max_log_radius_step, max_anchor_seam_error, max_radius_seam_error, max_halving_ratio])

	sample_scene(34.0, false)
	visuals.set_local_viewer_enabled(false)
	rocket.apply_authoritative_clock(LunarRocket.State.OCEAN_APPROACH, false, 43.0)
	rocket.present_render_sample(rocket.render_sample(43.0))
	var spectator_clean := not visuals.is_visible_in_tree() \
		and is_zero_approx(Visuals._cinematic_curve_strength)
	sample_scene(34.0, false)
	manager._reset_rocket_to_launchpad()
	var reset_clean := not visuals.is_visible_in_tree() \
		and is_zero_approx(Visuals._cinematic_curve_strength)
	rocket.apply_authoritative_clock(LunarRocket.State.SPLASHDOWN, false, 45.0)
	_check(spectator_clean and reset_clean and not rocket.has_node("ReturnOceanSurface") \
		and rocket.global_transform.is_equal_approx(rocket.earth_launch_transform),
		"spectators and reset clear private mapping while a terminal late join remains on the real launchpad")


func _earth_light_matches(weight: float) -> bool:
	var world: World = main.world
	return is_equal_approx(world._earth_transit_light_weight, weight) \
		and is_equal_approx(world._sun.light_energy, world._sun_daylight_energy * weight) \
		and is_equal_approx(world._moon.light_energy, world._moon_daylight_energy * weight) \
		and world._sun.visible == (weight > 0.001) \
		and world._moon.visible == (weight > 0.001)


func _test_earth_return_lighting() -> void:
	var world: World = main.world
	var original_season := world.season
	var original_hour := world.time_of_day_hours
	world._apply_season(SeasonalCycle.Season.SUMMER)
	world.set_time_of_day_override(12.0)
	var weights: Array[float] = []
	var fade_matches := true
	for elapsed in [24.0, 32.0, 40.0]:
		sample_scene(elapsed, false)
		manager._update_transit_world_visibility()
		var expected_weight: float = (float(elapsed) - 24.0) / 16.0
		weights.append(world._earth_transit_light_weight)
		fade_matches = fade_matches and _earth_light_matches(expected_weight) \
			and world.earth_transit_surface_visible() \
				== (elapsed >= SpaceVoyageVisuals.RETURN_TERRAIN_REVEAL_START_SECONDS)
	_check(fade_matches and world._sun_daylight_energy > 0.1 \
		and is_zero_approx(rocket.voyage_visuals.celestial_fill_light.light_energy),
		"return sunlight fades independently of terrain from zero at 24s through half at 32s to full at 40s",
		"weights=%s" % [weights])
	world.set_earth_transit_surface_visible(false, 0.5)
	var summer_energy := world._sun.light_energy
	world._apply_season(SeasonalCycle.Season.WINTER)
	var seasonal_fade := _earth_light_matches(0.5) \
		and world._sun.light_energy < summer_energy
	world.set_time_of_day_override(0.0)
	_check(seasonal_fade and _earth_light_matches(0.5) \
		and world._moon.light_energy > 0.01 and is_zero_approx(world._sun.light_energy),
		"seasonal and day/night updates preserve the partial transit fade on the actual Sun and Moon")
	world.set_earth_transit_surface_visible(true)
	var default_restores := _earth_light_matches(1.0) and world.earth_transit_surface_visible()
	world.set_earth_transit_surface_visible(false, 0.25)
	manager._apply_local_realm(Net.PlayerRealm.EARTH)
	_check(default_restores and _earth_light_matches(1.0) \
		and world.earth_transit_surface_visible(),
		"default surface reveal and the actual Earth realm handoff restore full seasonal lighting")
	world._apply_season(original_season)
	world.set_time_of_day_override(original_hour)
	world.set_earth_streaming_enabled(false)
	player.set_expedition_locked(true)


func _test_render_rates() -> void:
	for outbound in [true, false]:
		var label := "outbound" if outbound else "return"
		for fps in [30, 60, 120, 144]:
			_new_mission(outbound)
			var physics_time := 0.0
			var max_clock_error := 0.0
			var max_position_error := 0.0
			var duration := _duration(outbound)
			for frame in range(1, int(duration * fps) + 1):
				var time := float(frame) / float(fps)
				rocket.advance_render_clock(1.0 / float(fps))
				while physics_time + 1.0 / 60.0 <= time + 0.000001:
					rocket._physics_process(1.0 / 60.0)
					physics_time += 1.0 / 60.0
				if frame % fps == 0:
					var sample := rocket.render_sample()
					var transform: Transform3D = sample.transform
					max_clock_error = maxf(max_clock_error, absf(float(sample.elapsed) - time))
					max_position_error = maxf(max_position_error,
						transform.origin.distance_to(_path(time, outbound).origin))
			_check(max_clock_error < 0.0001 and max_position_error < 0.05,
				"%s %d FPS rendering stays on time beside independent 60 Hz physics" % [label, fps],
				"clock_error=%.7f s position_error=%.4f m" % [max_clock_error, max_position_error])


func _test_clock_corrections() -> void:
	for outbound in [true, false]:
		var elapsed := 32.25 if outbound else 24.25
		_new_mission(outbound, elapsed)
		var joined := rocket.render_sample()
		var joined_transform: Transform3D = joined.transform
		_check(absf(float(joined.elapsed) - elapsed) < 0.0001 \
			and joined_transform.origin.distance_to(_path(elapsed, outbound).origin) < 0.01,
			"late join reconstructs the correct mid-flight pose immediately (%s)" % outbound)
		var monotonic := true
		var max_clock_step := 0.0
		var min_clock_step := INF
		var immediate_correction_step := 0.0
		for frame in range(300):
			var before := float(rocket.render_sample().elapsed)
			if frame % 30 == 0:
				var correction := -0.12 if (frame / 30) % 2 == 0 else 0.10
				rocket.synchronize_authoritative_clock(
					LunarRocket.state_for_elapsed(outbound, before + correction), outbound, before + correction)
				immediate_correction_step = maxf(immediate_correction_step,
					absf(float(rocket.render_sample().elapsed) - before))
			rocket.advance_render_clock(1.0 / 60.0)
			var step := float(rocket.render_sample().elapsed) - before
			monotonic = monotonic and step > 0.0
			max_clock_step = maxf(max_clock_step, step)
			min_clock_step = minf(min_clock_step, step)
		_check(monotonic and immediate_correction_step < 0.0001 \
			and min_clock_step >= 0.90 / 60.0 and max_clock_step <= 1.10 / 60.0,
			"live clock corrections slew continuously without rewind or snapshot teleport (%s)" % outbound,
			"dt=%.6f..%.6f immediate_step=%.7f" % [min_clock_step, max_clock_step, immediate_correction_step])
		var before_hitch := float(rocket.render_sample().elapsed)
		rocket.advance_render_clock(1.0)
		var hitch_step := float(rocket.render_sample().elapsed) - before_hitch
		var before_invalid := float(rocket.render_sample().elapsed)
		for invalid in [0.0, -1.0, NAN, INF]:
			rocket.advance_render_clock(invalid)
		_check(hitch_step > 0.0 and hitch_step <= 0.108001 \
			and is_equal_approx(float(rocket.render_sample().elapsed), before_invalid),
			"a one-second render hitch is bounded and invalid deltas cannot corrupt the clock (%s)" % outbound,
			"hitch_step=%.6f s" % hitch_step)


func _test_pause() -> void:
	_new_mission(true, 5.0)
	Net.rocket_state = {"phase": Net.RocketMissionPhase.OUTBOUND,
		"crew": [Net.local_id()], "elapsed": 5.0, "duration": 60.0, "serial": 1}
	Net._rocket_started_msec = 0
	Net.player_realms[Net.local_id()] = Net.PlayerRealm.TRANSIT
	manager._apply_authoritative_state(Net.rocket_state)
	manager.set_process(true)
	var before_running := float(rocket.render_sample().elapsed)
	for _frame in range(6):
		await get_tree().process_frame
	var after_running := float(rocket.render_sample().elapsed)
	main._open_pause_menu()
	var paused_clock := float(rocket.render_sample().elapsed)
	var paused_pose := rocket.global_transform
	for _frame in range(8):
		await get_tree().process_frame
	_check(after_running > before_running and get_tree().paused \
		and is_equal_approx(float(rocket.render_sample().elapsed), paused_clock) \
		and rocket.global_transform.is_equal_approx(paused_pose),
		"real offline pause freezes an actively advancing render clock and its rocket pose")
	main._close_pause_menu(false)
	for _frame in range(6):
		await get_tree().process_frame
	_check(not get_tree().paused and float(rocket.render_sample().elapsed) > paused_clock,
		"resuming continues presentation time without replaying the paused interval")
	manager.set_process(false)
