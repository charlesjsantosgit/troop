extends Node
## Real lunar collision at 60 Hz, composed at independently driven render rates.

var _passed := 0
var _total := 0


func _check(ok: bool, label: String, detail := "") -> void:
	_total += 1
	if ok:
		_passed += 1
	print("  [%s] %s%s" % ["ok" if ok else "FAIL", label, " :: " + detail if not detail.is_empty() else ""])


func _settle(player: MonkeyPlayer, moon: MoonWorld, direction: Vector3) -> void:
	player.ti.dir = Vector2.ZERO
	player.ti.jump_just = false
	player.ti.jump_held = false
	player.fly_mode = false
	player.global_basis = MoonWorld.surface_basis(direction)
	player.admin_teleport(moon.to_global(moon.surface_position(direction, 0.8)))
	for tick in range(150):
		player._physics_process(1.0 / 60.0)
	player.cam.yaw = 0.0
	player.cam.pitch = 0.0
	player.cam._trauma = 0.0
	player.cam._hit_trauma = 0.0
	player.cam._recoil_shake = 0.0
	player.cam._reset_movement_camera()
	player.cam.snap_to_target()
	player.cam.render_frame(1.0 / 60.0, 1.0)


func _drive(player: MonkeyPlayer, rate: int, seconds: float, walking: bool) -> Dictionary:
	var cam := player.cam
	var physics_tick := 0
	var min_position := Vector3(INF, INF, INF)
	var max_position := Vector3(-INF, -INF, -INF)
	var maximum_motion := 0.0
	var maximum_angular_motion := 0.0
	var maximum_frame_error := 0.0
	var maximum_height_error := 0.0
	var saw_air := false
	player.ti.dir = Vector2(0, -1) if walking else Vector2.ZERO
	for frame in range(1, roundi(seconds * rate) + 1):
		var seconds_now := float(frame) / rate
		var required_tick := floori(seconds_now * 60.0 + 0.000001)
		while physics_tick < required_tick:
			player._physics_process(1.0 / 60.0)
			physics_tick += 1
		var fraction := clampf(seconds_now * 60.0 - required_tick, 0.0, 1.0)
		cam.render_frame(1.0 / rate, fraction)
		var sample := player.lunar_camera_sample(fraction)
		var sample_frame: Transform3D = sample.local_frame
		var wanted_eye := sample_frame.origin + sample_frame.basis.y * CameraRig.FIRST_PERSON_HEIGHT
		maximum_height_error = maxf(maximum_height_error, cam._lunar_follow_origin.distance_to(wanted_eye))
		maximum_frame_error = maxf(maximum_frame_error,
			cam.global_basis.y.angle_to((sample.frame as Transform3D).basis.y))
		if frame > rate / 2:
			var position := cam.cam_pos()
			min_position = min_position.min(position)
			max_position = max_position.max(position)
			maximum_motion = maxf(maximum_motion, cam._applied_motion_position.length())
			maximum_angular_motion = maxf(maximum_angular_motion, cam._applied_motion_rotation.length())
			saw_air = saw_air or not player.is_on_floor()
	return {"position_span": (max_position - min_position).length(), "motion": maximum_motion,
		"angular_motion": maximum_angular_motion, "frame_error": maximum_frame_error,
		"height_error": maximum_height_error, "saw_air": saw_air,
		"eye": cam._lunar_follow_origin, "basis": cam.global_basis,
		"motion_position": cam._applied_motion_position}


func run(main: Node) -> void:
	print("LUNARFIRSTPERSONTEST begin")
	var player: MonkeyPlayer = main.world.local_player
	var moon: MoonWorld = main.expedition_manager.moon_world
	var cam := player.cam
	main.hud.visible = false
	player.test_mode = true
	player._invulnerable_t = 10000.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	player.set_physics_process(false)
	player.set_process(false)
	cam.set_process(false)
	cam.set_first_person(true)
	_check(player.lunar_world == moon and not player.expedition_locked,
		"fixture exercises the real unlocked Moon character")
	cam._camera_mount.position = Vector3(0.003, -0.002, 0.004)
	var authored_mount := cam._camera_mount.transform
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(cam._camera_mount.transform.is_equal_approx(authored_mount),
		"physics spring arm cannot overwrite the render-owned first-person mount")
	var maximum_idle_span := 0.0
	var maximum_idle_angle := 0.0
	var maximum_phase_error := 0.0
	var maximum_follow_error := 0.0
	var maximum_rate_error := 0.0
	var maximum_stride_difference := 0.0
	for direction in [Vector3.UP, Vector3.DOWN, Vector3.RIGHT, Vector3.FORWARD]:
		var reference_eye := Vector3.ZERO
		var reference_motion := Vector3.ZERO
		for rate in [30, 60, 144]:
			_settle(player, moon, direction)
			var idle := _drive(player, rate, 2.0, false)
			maximum_idle_span = maxf(maximum_idle_span, float(idle.position_span))
			maximum_idle_angle = maxf(maximum_idle_angle, float(idle.angular_motion))
			_check(not idle.saw_air and float(idle.position_span) < 0.012
				and float(idle.motion) < 0.0005 and float(idle.angular_motion) < 0.0002,
				"stationary lunar first person rests quietly at %s / %d Hz" % [direction, rate],
				"span_m=%.6f motion_m=%.6f angle_rad=%.6f" % [idle.position_span, idle.motion, idle.angular_motion])
			_settle(player, moon, direction)
			var motion := _drive(player, rate, 3.0, true)
			maximum_phase_error = maxf(maximum_phase_error, float(motion.frame_error))
			maximum_follow_error = maxf(maximum_follow_error, float(motion.height_error))
			_check(float(motion.frame_error) < 0.00001 and float(motion.height_error) < 0.00001
				and (motion.eye as Vector3).is_finite() and float(motion.motion) < 0.06,
				"walking lunar eye and up share one interpolation phase at %s / %d Hz" % [direction, rate],
				"up_error_rad=%.7f follow_error_m=%.7f" % [motion.frame_error, motion.height_error])
			if rate == 30:
				reference_eye = motion.eye
				reference_motion = motion.motion_position
			else:
				maximum_rate_error = maxf(maximum_rate_error, reference_eye.distance_to(motion.eye))
				maximum_stride_difference = maxf(maximum_stride_difference,
					reference_motion.distance_to(motion.motion_position))
	_check(maximum_rate_error < 0.004 and maximum_stride_difference < 0.006,
		"30/60/144 Hz first-person framing agrees without an extra chase lag",
		"eye_difference_m=%.6f stride_difference_m=%.6f" % [maximum_rate_error, maximum_stride_difference])
	_settle(player, moon, Vector3.DOWN)
	var before_look := Vector2(cam.yaw, cam.pitch)
	cam.apply_look(Vector2(12.0, -8.0))
	var after_look := Vector2(cam.yaw, cam.pitch)
	_check(after_look.distance_to(before_look + Vector2(-12.0, 8.0) * cam.effective_sensitivity()) < 0.000001,
		"lunar look input remains immediate and unfiltered")
	cam.add_weapon_recoil(1.0)
	cam.render_frame(1.0 / 144.0, 0.5)
	_check(absf(cam._recoil_pitch) > 0.001 and cam._recoil_back > 0.005,
		"quiet lunar idle preserves deliberate firearm recoil")
	cam.on_land(16.0)
	for frame in range(15):
		cam.render_frame(1.0 / 60.0, 1.0)
	_check(cam._landing_offset < -0.003 and cam._landing_pitch > 0.001,
		"real landing retains its bounded weight response")
	var boarding_heading := 1.13
	player.rig.set_yaw(boarding_heading)
	player.set_expedition_locked(true)
	_check(absf(player.rig.yaw_angle()) < 0.000001,
		"boarding immediately faces the local monkey along the seat")
	player.set_rocket_cabin_view(true)
	var saved_mouse := Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var mouse := InputEventMouseMotion.new()
	mouse.relative = Vector2(70.0, -35.0)
	var locked_look := Vector2(cam.yaw, cam.pitch)
	cam._input(mouse)
	Input.mouse_mode = saved_mouse
	_check(Vector2(cam.yaw, cam.pitch) == locked_look and not player.rig.visible
		and not player.gun.visible and not player.shotgun.visible and not player.smg.visible
		and not player.sniper.visible and not cam._view_arms.visible,
		"cabin hook hides local body and weapons while manager owns look input")
	player.rig.set_yaw(-2.4)
	player.melee_mode = true
	player._process(1.0 / 60.0)
	var seated_forward := player.rig.yaw_node.global_basis * Vector3.FORWARD
	var seat_forward := player.global_basis * Vector3.FORWARD
	_check(absf(player.rig.yaw_angle()) < 0.000001
		and seated_forward.normalized().dot(seat_forward.normalized()) > 0.99999,
		"cabin render holds seat-forward facing despite stale body aim")
	player.melee_mode = false
	player.set_expedition_locked(true)
	player.set_rocket_cabin_view(false)
	player.set_expedition_locked(false)
	_check(player.rig.visible and player.gun.visible
		and absf(angle_difference(player.rig.yaw_angle(), boarding_heading)) < 0.000001,
		"leaving the cabin restores body, weapon and the preboarding heading")
	player.rig.set_yaw(-1.2)
	player.set_expedition_locked(false)
	player.set_expedition_locked(true)
	player.set_expedition_locked(true)
	player._process(1.0 / 60.0)
	player.set_expedition_locked(false)
	_check(absf(angle_difference(player.rig.yaw_angle(), -1.2)) < 0.000001,
		"reboarding captures a fresh heading without repeated-lock overwrites")
	print("  LUNAR_FIRST_PERSON_METRICS idle_span_m=%.6f idle_angle_rad=%.6f phase_error_rad=%.8f eye_error_m=%.8f render_rate_error_m=%.6f" % [
		maximum_idle_span, maximum_idle_angle, maximum_phase_error, maximum_follow_error, maximum_rate_error])
	print("LUNARFIRSTPERSONTEST %d/%d %s" % [_passed, _total, "PASS" if _passed == _total else "FAIL"])
	get_tree().quit(0 if _passed == _total else 1)
