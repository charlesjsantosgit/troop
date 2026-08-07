extends Node
## Headless vehicle physics + integration verification on the flat debug
## plane. Every vehicle is driven through the real player input path
## (test-injected ti), so mounting, driving, suspension, drivetrain, lean,
## flight, and dismounting are all exercised end-to-end. Run with:
##   godot --headless --path . res://scenes/main.tscn --quit-after 90000 -- vehicletest

var fails := 0
var total := 0


func check(cname: String, ok: bool, info := "") -> void:
	total += 1
	if ok:
		print("  [ok] " + cname)
	else:
		fails += 1
		print("  [FAIL] " + cname + (("   :: " + info) if info != "" else ""))


func sim(frames: int) -> void:
	for i in range(frames):
		await get_tree().physics_frame


func neutral(p) -> void:
	p.ti.dir = Vector2.ZERO
	p.ti.sprint = false
	p.ti.jump_held = false
	p.ti.crouch_just = false
	p.ti.crouch_held = false
	p.ti.interact_just = false
	p.ti.grab = false
	p.ti.vehicle_gear_just = false
	p.ti.vehicle_flaps_just = false
	p.ti.vehicle_pitch = 0.0


## Give each motorcycle-control assertion a straight, settled approach. The
## top-speed fixture travels kilometres at accelerated simulation time, while
## a wheelie intentionally leaves the chassis pitched and yawing; carrying
## either state into the next handling assertion makes its direction depend on
## the previous manoeuvre instead of the key being tested.
func reset_bike_control_fixture(bike: Motorcycle) -> void:
	var pos := bike.global_position
	if not (is_finite(pos.x) and is_finite(pos.y) and is_finite(pos.z)):
		pos = Vector3(-6.0, DebugWorldBuilder.GROUND_Y, 120.0)
	bike.settle_at(Vector3(pos.x, DebugWorldBuilder.GROUND_Y, pos.z + 12.0), 0.0)
	bike._prev_velocity = Vector3.ZERO
	bike.sleeping = false
	bike._steer_target = 0.0
	bike._steer_current = 0.0
	bike.lean_target = 0.0
	bike._lean_integral = 0.0
	bike.wheelie_remaining = 0.0
	bike._wheelie_elapsed = 0.0
	bike._wheelie_cooldown = 0.0
	bike.engine.gear = 1
	bike.engine.rpm = bike.engine.idle_rpm
	bike.engine._shift_cooldown = 0.0
	bike.engine._shift_lockout = 0.0
	for wheel in bike.wheels:
		wheel.spin = 0.0
		wheel.spin_angle = 0.0
		wheel.steer_angle = 0.0


func rider_contract_ok(p, v) -> bool:
	if p.rig.global_position.distance_to(v.rider_render_transform().origin) > 0.06:
		return false
	var slots: Array[StringName] = [
		&"hand_left", &"hand_right", &"foot_left", &"foot_right"]
	var contacts: PackedVector3Array = p.rig.limb_contact_points()
	if contacts.size() != slots.size():
		return false
	for i in range(slots.size()):
		var slot := slots[i]
		if not v.has_rider_target(slot):
			return false
		# The IK solves the paw centre exactly; feet have a 3.5 cm authored toe
		# offset. This bound therefore proves real contact without requiring all
		# four extremity meshes to share one pivot convention.
		if contacts[i].distance_to(v.rider_target_render_global(slot)) > 0.09:
			return false
	return true


func collect_array_meshes(root: Node,
		result: Array[MeshInstance3D]) -> void:
	for child in root.get_children():
		if child is MeshInstance3D:
			var mesh_instance := child as MeshInstance3D
			if mesh_instance.mesh is ArrayMesh:
				result.append(mesh_instance)
		collect_array_meshes(child, result)


## Godot renders clockwise triangles. For each closed convex procedural part,
## (c-a)x(b-a) must therefore point away from the mesh centre. This checks the
## committed arrays themselves, not the same helper that authored the model.
func outward_winding_stats(mesh_instance: MeshInstance3D) -> Dictionary:
	var array_mesh := mesh_instance.mesh as ArrayMesh
	var face_count := 0
	var inward_count := 0
	var minimum_alignment := INF
	for surface_index in range(array_mesh.get_surface_count()):
		var arrays: Array = array_mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if vertices.is_empty():
			continue
		var bounds := AABB(vertices[0], Vector3.ZERO)
		for vertex: Vector3 in vertices:
			bounds = bounds.expand(vertex)
		var centre := bounds.get_center()
		var element_count := indices.size() if not indices.is_empty() \
			else vertices.size()
		for offset in range(0, element_count, 3):
			var ia := indices[offset] if not indices.is_empty() else offset
			var ib := indices[offset + 1] if not indices.is_empty() else offset + 1
			var ic := indices[offset + 2] if not indices.is_empty() else offset + 2
			var a: Vector3 = vertices[ia]
			var b: Vector3 = vertices[ib]
			var c: Vector3 = vertices[ic]
			var normal := (c - a).cross(b - a)
			if normal.length_squared() < 0.0000001:
				continue
			var alignment := normal.normalized().dot((a + b + c) / 3.0 - centre)
			minimum_alignment = minf(minimum_alignment, alignment)
			face_count += 1
			if alignment <= 0.0001:
				inward_count += 1
	return {"faces": face_count, "inward": inward_count,
		"minimum": minimum_alignment}


func hierarchy_has_positive_determinants(root: Node) -> bool:
	for child in root.get_children():
		if child is Node3D \
				and (child as Node3D).transform.basis.determinant() <= 0.0:
			return false
		if not hierarchy_has_positive_determinants(child):
			return false
	return true


func mount(p, w, v) -> bool:
	if p.vehicle != null:
		p.exit_vehicle()
		await sim(5)
	neutral(p)
	# A parked rigid body can settle a few centimetres between positioning the
	# player and the next physics tick. Pulse the real contextual-E path up to
	# three times, re-anchoring to the live seat each time, so this integration
	# helper tests the interaction itself instead of a one-frame race.
	for attempt in range(3):
		p.global_position = v.interaction_position() + Vector3(1.2, 0.2, 0)
		p.velocity = Vector3.ZERO
		await sim(3)
		p.ti.interact_just = true
		await sim(1)
		p.ti.interact_just = false
		await sim(4)
		if p.vehicle == v:
			return true
		if p.vehicle != null:
			p.exit_vehicle()
			await sim(5)
	return false


func dismount(p) -> void:
	neutral(p)
	# Brake to a genuine stop first — dismounting a moving machine is
	# correctly refused by Vehicle.allows_exit().
	for i in range(600):
		if p.vehicle == null or p.vehicle.speed() < 1.0:
			break
		p.ti.dir = Vector2(0, 1.0 if p.vehicle.forward_speed() > 0.0 else -1.0)
		await sim(5)
	neutral(p)
	await sim(30)
	if p.vehicle != null:
		p.ti.interact_just = true
		await sim(3)
		p.ti.interact_just = false
	await sim(10)


func run(main) -> void:
	print("VEHICLETEST begin (debug world)")
	var w = main.world
	var p = w.local_player
	p.test_mode = true
	await sim(30)

	# --- spawn + registry ---------------------------------------------------
	var bike = w.vehicle_by_id("v:debug#bike")
	var jeep = w.vehicle_by_id("v:debug#jeep")
	var boat = w.vehicle_by_id("v:debug#boat")
	var jet = w.vehicle_by_id("v:debug#jet")
	check("vehicle yard spawns all four kinds",
		bike != null and jeep != null and boat != null and jet != null)
	check("vehicle id grammar accepted",
		Net._valid_vehicle_id("v:debug#bike")
		and Net._valid_vehicle_id("v:3,-7#0")
		and not Net._valid_vehicle_id("x:debug#bike")
		and not Net._valid_vehicle_id("v:debug")
		and not Net._valid_vehicle_id("v:a#b#c"))
	var automatic_probe := VehicleEngine.new()
	automatic_probe.configure({
		"torque_curve": [[800, 100.0], [5100, 100.0]],
		"idle_rpm": 750.0, "redline_rpm": 5100.0,
		"limiter_rpm": 5400.0, "gear_ratios": [4.0, 2.32, 1.54, 1.0, 0.73],
		"final_drive": 4.10, "clutch_engage_rpm": 1500.0,
		"auto_shift": true,
	})
	automatic_probe.gear = 5
	for i in range(220):
		automatic_probe.step(1.0 / 60.0, 0.0, 0.0, 0.0)
	check("automatic gearbox settles back to first gear while stopped",
		automatic_probe.gear == 1, "gear=%d" % automatic_probe.gear)
	var jet_body: Node3D = jet.get_node_or_null("Body") as Node3D
	var jet_array_meshes: Array[MeshInstance3D] = []
	if jet_body:
		collect_array_meshes(jet_body, jet_array_meshes)
	var jet_faces := 0
	var jet_inward_faces := 0
	var jet_minimum_alignment := INF
	var jet_meshes_cull_back := true
	for mesh_instance: MeshInstance3D in jet_array_meshes:
		var stats := outward_winding_stats(mesh_instance)
		jet_faces += int(stats["faces"])
		jet_inward_faces += int(stats["inward"])
		jet_minimum_alignment = minf(jet_minimum_alignment,
			float(stats["minimum"]))
		var material := mesh_instance.material_override as BaseMaterial3D
		jet_meshes_cull_back = jet_meshes_cull_back and material != null \
			and material.cull_mode == BaseMaterial3D.CULL_BACK
	check("jet procedural shell faces wind outward",
		jet_array_meshes.size() == 10 and jet_faces > 0 \
		and jet_inward_faces == 0,
		"meshes=%d faces=%d inward=%d min=%.4f" % [jet_array_meshes.size(),
			jet_faces, jet_inward_faces, jet_minimum_alignment])
	check("jet opaque generated shells use back-face culling",
		jet_meshes_cull_back)
	check("jet model hierarchy contains no mirrored transforms",
		jet_body != null and hierarchy_has_positive_determinants(jet_body))

	# --- parked settling ----------------------------------------------------
	await sim(150)
	var settled: bool = jeep.global_basis.y.y > 0.95 \
		and jeep.linear_velocity.length() < 0.6
	var contacts := 0
	for wheel in jeep.wheels:
		if wheel.in_contact:
			contacts += 1
	check("jeep settles upright on its suspension",
		settled and contacts == 4,
		"up=%.2f v=%.2f contacts=%d" % [jeep.global_basis.y.y,
			jeep.linear_velocity.length(), contacts])
	var sag_ok := true
	for wheel in jeep.wheels:
		if wheel.compression < 0.02 or wheel.compression > wheel.travel * 0.9:
			sag_ok = false
	check("jeep static sag sits mid-travel", sag_ok)

	# --- mounting through the real E path -----------------------------------
	# Reproduce mounting while ADS has temporarily forced first person. Entry
	# must clear ADS and restore the player's actual shoulder-view preference.
	p.cam.set_view_mode(CameraRig.ViewMode.SHOULDER)
	p.cam.set_aiming(true)
	var mounted: bool = await mount(p, w, jeep)
	check("E mounts the jeep through the interaction ladder", mounted)
	check("mounting while ADS restores the preferred vehicle view",
		not p.cam.aiming and p.cam.view_mode == CameraRig.ViewMode.SHOULDER)
	check("mounting stows the weapon and disables the capsule",
		p.is_weapon_stowed() and p._collision_shape.disabled)
	await sim(18)
	check("jeep rider is planted on authored seat and controls",
		rider_contract_ok(p, jeep))
	main.hud._update_vehicle_cluster()
	check("jeep has an accurate analog automatic-transmission cluster",
		jeep.engine.auto_shift and main.hud.vehicle_tachometer.visible \
		and is_equal_approx(main.hud.vehicle_tachometer.rpm, jeep.engine.rpm) \
		and is_equal_approx(main.hud.vehicle_tachometer.scale_max_rpm, 6000.0) \
		and is_equal_approx(main.hud.vehicle_tachometer.needle_fraction,
			jeep.engine.rpm / 6000.0) \
		and is_equal_approx(main.hud.vehicle_tachometer.redline_fraction,
			5100.0 / 6000.0))
	# Ground and water cockpits use vehicle-relative freelook. Rotate the parked
	# chassis without touching the camera and prove its centered sightline follows.
	var parked_jeep_basis: Basis = jeep.global_basis
	p.cam._apply_view_mode(CameraRig.ViewMode.FIRST_PERSON)
	jeep.global_basis = Basis(Vector3.UP, 0.38) * parked_jeep_basis
	jeep.reset_physics_interpolation()
	p.cam._process(1.0 / 60.0)
	check("ground cockpit view turns with the vehicle chassis",
		p.cam.vehicle_aim_direction().dot(jeep.global_basis.z) > 0.995)
	p.cam._apply_view_mode(CameraRig.ViewMode.SHOULDER)
	check("leaving a vehicle cockpit restores a level chase horizon",
		p.cam.global_basis.y.dot(Vector3.UP) > 0.999)
	jeep.global_basis = parked_jeep_basis
	jeep.reset_physics_interpolation()

	# Low range cannot jump ratios under throttle, but toggles cleanly stopped.
	p.ti.dir = Vector2(0, -1)
	p.ti.sprint = true
	await sim(3)
	check("jeep rejects low range while throttle is loaded", not jeep.low_range)
	p.ti.dir = Vector2.ZERO
	p.ti.sprint = false
	await sim(3)
	p.ti.sprint = true
	await sim(3)
	check("jeep selects low range only stopped and off-throttle",
		jeep.low_range and jeep.engine.final_drive > 10.0)
	p.ti.sprint = false
	await sim(3)
	p.ti.sprint = true
	await sim(3)
	p.ti.sprint = false
	check("jeep can return to high range at rest", not jeep.low_range)

	# --- drive: acceleration, gears, engine ---------------------------------
	p.ti.dir = Vector2(0, -1)
	await sim(360)
	var drive_speed: float = jeep.forward_speed()
	check("jeep accelerates past 14 m/s under power", drive_speed > 14.0,
		"%.1f m/s" % drive_speed)
	check("gearbox upshifted beyond first", jeep.engine.gear >= 2,
		"gear=%d" % jeep.engine.gear)
	main.hud._update_vehicle_cluster()
	check("analog tach needle follows raw engine RPM exactly",
		absf(main.hud.vehicle_tachometer.rpm - jeep.engine.rpm) < 0.01 \
		and absf(main.hud.vehicle_tachometer.needle_angle_radians \
			- (AnalogTachometer.START_ANGLE + AnalogTachometer.SWEEP_ANGLE \
			* jeep.engine.rpm / 6000.0)) < 0.001,
		"hud=%.1f engine=%.1f" % [main.hud.vehicle_tachometer.rpm,
			jeep.engine.rpm])
	check("driven wheels are turning with the ground",
		absf(jeep.wheels[2].spin * jeep.wheels[2].radius - drive_speed) \
		< maxf(3.0, drive_speed * 0.35))

	# --- braking + reverse ---------------------------------------------------
	var high_forward_gear: int = jeep.engine.gear
	var saw_automatic_downshift := false
	p.ti.dir = Vector2(0, 1)
	for i in range(300):
		await sim(1)
		if jeep.engine.gear >= 1 and jeep.engine.gear < high_forward_gear:
			saw_automatic_downshift = true
		if absf(jeep.forward_speed()) < 1.8:
			break
	p.ti.dir = Vector2.ZERO
	await sim(220)
	check("automatic jeep downshifts to first as it slows",
		saw_automatic_downshift and jeep.engine.gear == 1,
		"started=%d ended=%d v=%.1f" % [high_forward_gear,
			jeep.engine.gear, jeep.forward_speed()])
	p.ti.dir = Vector2(0, 1)
	await sim(90)
	var reverse_debug := "gear=%d velocity=%s safe=%s wheels=[" % [
		jeep.engine.gear, jeep.linear_velocity,
		str(jeep._direction_change_is_safe())]
	for wheel in jeep.wheels:
		reverse_debug += " %.2f/%s" % [wheel.spin * wheel.radius,
			str(wheel.in_contact)]
	reverse_debug += " ]"
	check("brakes stop the jeep and holding S reverses",
		jeep.forward_speed() < -1.2,
		"%.1f m/s %s" % [jeep.forward_speed(), reverse_debug])
	# Force a realistic rollback while first is still selected. S must remain a
	# brake until absolute speed is near zero; the old signed check chose reverse.
	jeep.engine.gear = 1
	jeep.linear_velocity = -jeep.global_basis.z * 8.0
	for wheel in jeep.wheels:
		wheel.spin = -8.0 / wheel.radius
	p.ti.dir = Vector2(0, 1)
	await sim(20)
	check("rollback braking cannot select reverse while still moving",
		jeep.engine.gear == 1 and jeep.forward_speed() < -0.7,
		"gear=%d v=%.1f" % [jeep.engine.gear, jeep.forward_speed()])
	# Forward speed is near zero during a sideways skid, but the chassis is not
	# stopped. Holding S must remain braking instead of engaging reverse.
	jeep.engine.gear = 1
	jeep.linear_velocity = jeep.global_basis.x * 8.0
	for wheel in jeep.wheels:
		wheel.spin = 0.0
	p.ti.dir = Vector2(0, 1)
	await sim(20)
	check("sideways skid cannot select reverse",
		jeep.engine.gear == 1 and jeep.speed() > 0.7,
		"gear=%d speed=%.1f" % [jeep.engine.gear, jeep.speed()])
	# Even at zero chassis/wheel speed, an airborne transmission cannot safely
	# swap direction because there is no grounded driven contact.
	jeep.linear_velocity = Vector3.ZERO
	var wheel_contacts: Array[bool] = []
	for wheel in jeep.wheels:
		wheel_contacts.append(wheel.in_contact)
		wheel.in_contact = false
		wheel.spin = 0.0
	check("airborne jeep cannot select reverse",
		not jeep._direction_change_is_safe())
	for i in range(jeep.wheels.size()):
		jeep.wheels[i].in_contact = wheel_contacts[i]
	# Reverse uses the raw brake pedal as throttle. Even below the transfer-case
	# speed threshold, holding S must keep SHIFT from changing ratio under load.
	jeep.engine.gear = -1
	jeep.linear_velocity = -jeep.global_basis.z * 0.25
	for wheel in jeep.wheels:
		wheel.spin = -0.25 / wheel.radius
	p.ti.sprint = false
	await sim(2)
	p.ti.sprint = true
	await sim(3)
	check("jeep rejects low range while reverse pedal is loaded",
		not jeep.low_range and jeep.input_brake > 0.9)
	p.ti.sprint = false
	jeep.linear_velocity = Vector3.ZERO
	for wheel in jeep.wheels:
		wheel.spin = 0.0
	neutral(p)
	await sim(60)

	# --- steering ------------------------------------------------------------
	p.ti.dir = Vector2(0, -1)
	await sim(240)
	p.ti.dir = Vector2(-1, -1)   # steer left at speed
	await sim(90)
	var yaw_rate: float = jeep.angular_velocity.y
	check("steering left yaws the jeep left and keeps it upright",
		yaw_rate > 0.12 and jeep.global_basis.y.y > 0.85,
		"yaw_rate=%.2f up=%.2f" % [yaw_rate, jeep.global_basis.y.y])
	neutral(p)
	p.ti.dir = Vector2(0, 1)
	await sim(200)
	neutral(p)

	# --- dismount ------------------------------------------------------------
	await dismount(p)
	await sim(45)
	check("E dismounts and restores the monkey",
		p.vehicle == null and not p._collision_shape.disabled
		and p.collision_layer == 1)
	check("released jeep parks with its brakes on",
		jeep.driver == null and jeep.input_brake > 0.99
		and jeep.input_handbrake
		and Vector2(jeep.linear_velocity.x, jeep.linear_velocity.z).length() < 0.8
		and absf(jeep.linear_velocity.y) < 3.5,
		"brake=%.2f handbrake=%s velocity=%s" % [jeep.input_brake,
			str(jeep.input_handbrake), jeep.linear_velocity])

	# --- motorcycle ----------------------------------------------------------
	mounted = await mount(p, w, bike)
	check("monkey saddles the dual-sport", mounted)
	await sim(18)
	check("bike rider is planted on authored saddle and controls",
		rider_contract_ok(p, bike))
	p.ti.dir = Vector2(-1, 0)
	await sim(1)
	var gathered_bike_left: bool = bike.input_steer > 0.99
	p.ti.dir = Vector2(1, 0)
	await sim(1)
	var gathered_bike_right: bool = bike.input_steer < -0.99
	neutral(p)
	await sim(1)
	check("bike A and D map to physical left and right steering",
		gathered_bike_left and gathered_bike_right)
	check("bike HUD teaches the Ctrl wheelie",
		main.hud._vehicle_hint(bike).contains("WHEELIE") \
		and main.hud._vehicle_hint(bike).contains(Settings.binding_text(&"crouch")))
	var bike_basis: Basis = bike.global_basis
	bike.global_basis = Basis.from_euler(Vector3(-0.62,
		bike_basis.get_euler(EULER_ORDER_YXZ).y, 0.0), EULER_ORDER_YXZ)
	bike.input_throttle = 1.0
	check("bike anti-loop detects nose-up throttle before drivetrain step",
		bike.anti_loop_active())
	bike.global_basis = bike_basis
	bike.reset_physics_interpolation()
	p.ti.dir = Vector2(0, -1)
	await sim(120)
	check("bike balance keeps it upright while accelerating",
		absf(bike.global_basis.get_euler(EULER_ORDER_YXZ).z) < 0.4,
		"roll=%.2f" % bike.global_basis.get_euler(EULER_ORDER_YXZ).z)
	await sim(480)
	var bike_speed: float = bike.forward_speed()
	check("bike exceeds 25 m/s under power", bike_speed > 25.0,
		"%.1f m/s" % bike_speed)
	# Top speed first, while still pointed straight north across empty plane:
	# tuck (SHIFT) and hold it — accept 44+ m/s (~100 mph and still climbing;
	# the last few mph of 110 need a longer run than a test should take).
	p.ti.sprint = true
	Engine.time_scale = 3.0
	await sim(1400)
	Engine.time_scale = 1.0
	var vmax: float = bike.forward_speed()
	check("tucked dual-sport pulls past 44 m/s toward its 110 mph top",
		vmax > 44.0 and vmax < 52.0, "%.1f m/s (%.0f mph)" % [vmax,
			vmax * 2.23694])
	p.ti.sprint = false
	# Reset the long accelerated top-speed run, then approach each manoeuvre at
	# an ordinary trail-riding speed through the same real W input as gameplay.
	neutral(p)
	reset_bike_control_fixture(bike)
	await sim(24)
	for i in range(360):
		if bike.forward_speed() < 10.0:
			p.ti.dir = Vector2(0, -1)
		elif bike.forward_speed() > 17.0:
			p.ti.dir = Vector2(0, 1)
		else:
			break
		await sim(1)
	# Ctrl is a one-frame trigger; the authored balance assist persists after the
	# key is released. Hold A during it to prove steering is physically reduced.
	p.ti.dir = Vector2(-1, -1)
	p.ti.crouch_just = true
	p.ti.crouch_held = true
	await sim(1)
	p.ti.crouch_held = false
	var wheelie_triggered: bool = bike.wheelie_active()
	var peak_nose_up := 0.0
	var saw_front_lift := false
	var saw_rear_support := false
	var maximum_wheelie_steer := 0.0
	for i in range(90):
		# One brief A sample proves the airborne steering cap; ride the rest of
		# the manoeuvre straight so the fixture measures the wheelie, not a
		# deliberate post-landing lowside after its 1.2-second assist ends.
		if i == 10:
			p.ti.dir = Vector2(0, -1)
		await sim(1)
		peak_nose_up = maxf(peak_nose_up,
			-bike.global_basis.get_euler(EULER_ORDER_YXZ).x)
		saw_front_lift = saw_front_lift or not bike.wheels[0].in_contact
		saw_rear_support = saw_rear_support or bike.wheels[1].in_contact
		if bike.wheelie_active():
			maximum_wheelie_steer = maxf(maximum_wheelie_steer,
				absf(bike._steer_target))
	check("Ctrl pops a brief, protected motorcycle wheelie",
		wheelie_triggered and peak_nose_up > 0.14 and peak_nose_up < 0.55 \
		and saw_front_lift and saw_rear_support,
		"peak=%.2f front_lift=%s rear_support=%s" % [peak_nose_up,
			str(saw_front_lift), str(saw_rear_support)])
	check("wheelie sharply limits turning while the front is raised",
		maximum_wheelie_steer <= bike.max_steer_angle * 0.22,
		"steer=%.3f max=%.3f" % [maximum_wheelie_steer,
			bike.max_steer_angle * 0.22])
	neutral(p)
	await sim(75)
	check("wheelie timer ends and returns steering authority",
		not bike.wheelie_active())

	# Lean into a right-hander and assert actual heading/displacement, not merely
	# an internally consistent target sign. This catches the old inverted bank.
	neutral(p)
	reset_bike_control_fixture(bike)
	await sim(24)
	for i in range(300):
		if bike.forward_speed() < 10.0:
			p.ti.dir = Vector2(0, -1)
		elif bike.forward_speed() > 17.0:
			p.ti.dir = Vector2(0, 1)
		else:
			break
		await sim(1)
	var corner_origin: Vector3 = bike.global_position
	var corner_forward: Vector3 = bike.global_basis.z.normalized()
	var corner_right: Vector3 = -bike.global_basis.x.normalized()
	p.ti.dir = Vector2(1, -1)
	await sim(50)
	var lean: float = bike.global_basis.get_euler(EULER_ORDER_YXZ).z
	var lean_matches: bool = signf(lean) == signf(bike.lean_target) \
		and absf(bike.lean_target) > 0.1 and absf(lean) > 0.08
	var right_heading: float = bike.global_basis.z.normalized().dot(corner_right)
	var right_displacement: float = (bike.global_position - corner_origin).dot(
		corner_right)
	check("D banks and turns the bike right with responsive movement",
		lean_matches and lean > 0.0 and right_heading > 0.10 \
		and right_displacement > 0.35 and bike.driver == p \
		and bike.global_basis.y.y > 0.68,
		"lean=%.2f target=%.2f heading=%.2f side=%.2f forward=%.2f" % [
			lean, bike.lean_target, right_heading, right_displacement,
			bike.global_basis.z.normalized().dot(corner_forward)])
	await dismount(p)
	check("bike drops to its stand when parked", bike.driver == null)

	# --- airboat over grass ---------------------------------------------------
	mounted = await mount(p, w, boat)
	check("monkey boards the airboat", mounted)
	await sim(18)
	check("airboat rider is planted on authored bench and controls",
		rider_contract_ok(p, boat))
	# One wet float point marks the whole boat as in water. That must not turn
	# off analytic support beneath the dry half when its shoreline chunk has
	# streamed out. Probe the fallback without applying forces, then restore the
	# live mounted body before another physics frame can observe the test pose.
	var boat_transform_before_fallback: Transform3D = boat.global_transform
	var boat_linear_before_fallback: Vector3 = boat.linear_velocity
	var boat_angular_before_fallback: Vector3 = boat.angular_velocity
	var boat_space_before_fallback: PhysicsDirectSpaceState3D = boat._space
	var boat_water_before_fallback: bool = boat._in_water
	boat._space = null
	boat.global_basis = Basis.IDENTITY
	boat.global_position.y = Gen.height(
		boat.global_position.x, boat.global_position.z) + 0.12
	boat.linear_velocity = Vector3.ZERO
	boat.angular_velocity = Vector3.ZERO
	boat._in_water = true
	var dry_support_points: int = boat._apply_streaming_safe_land_support(
		1.0 / 60.0, false)
	check("a wet airboat keeps dry support while shoreline terrain streams",
		dry_support_points > 0, "supported=%d" % dry_support_points)
	boat._space = boat_space_before_fallback
	boat.global_transform = boat_transform_before_fallback
	boat.linear_velocity = boat_linear_before_fallback
	boat.angular_velocity = boat_angular_before_fallback
	boat._in_water = boat_water_before_fallback
	boat.reset_physics_interpolation()
	boat.linear_velocity = Vector3(0, 12, 0)
	check("vertical wave motion adds no airboat rudder authority",
		boat._rudder_flow_speed() < 0.01)
	boat.linear_velocity = boat.global_basis.z * 8.0 + Vector3.UP * 12.0
	check("airboat rudder reads only planar forward flow",
		absf(boat._rudder_flow_speed() - 8.0) < 0.05)
	boat.linear_velocity = -boat.global_basis.z * 8.0 + Vector3.UP * 12.0
	check("backward airboat drift reverses hull-flow steering",
		absf(boat._rudder_flow_speed() + 8.0) < 0.05)
	boat.linear_velocity = Vector3.ZERO
	p.ti.dir = Vector2(0, -1)
	await sim(300)
	check("prop thrust slides the airboat over wet grass",
		boat.speed() > 3.5,
		"speed=%.2f spool=%.2f throttle=%.2f brake=%.2f driver=%s pos=%s" % [
			boat.speed(), boat.spool, boat.input_throttle, boat.input_brake,
			str(boat.driver != null), boat.global_position])
	var fan_before_chop: float = boat.spool
	p.ti.dir = Vector2(0, 1)
	await sim(15)
	check("S rapidly chops the fan for a realistic coast-down",
		boat.spool < fan_before_chop - 0.45,
		"before=%.2f after=%.2f" % [fan_before_chop, boat.spool])
	neutral(p)
	await sim(120)
	await dismount(p)

	# --- fighter jet: taxi, takeoff, climb, afterburner, bail-out -------------
	# Deliberately approach with the old camera aimed behind and above the jet.
	p.cam.yaw = 0.0
	p.cam.pitch = 0.35
	mounted = await mount(p, w, jet)
	check("monkey straps into the fighter jet", mounted)
	await sim(18)
	check("jet mount aligns pursuit aim with the aircraft nose",
		p.cam.vehicle_aim_direction().dot(jet.global_basis.z) > 0.995)
	check("jet rider is planted in cockpit and on all controls",
		rider_contract_ok(p, jet))
	check("jet HUD teaches the arrow pitch controls",
		main.hud._vehicle_hint(jet).contains("NOSE UP") \
		and main.hud._vehicle_hint(jet).contains("NOSE DOWN") \
		and main.hud._vehicle_hint(jet).contains(
			Settings.binding_text(&"vehicle_pitch_up")) \
		and main.hud._vehicle_hint(jet).contains(
			Settings.binding_text(&"vehicle_pitch_down")))
	p.ti.vehicle_pitch = 1.0
	await sim(1)
	var gathered_up: bool = jet._pitch_input > 0.99
	p.ti.vehicle_pitch = -1.0
	await sim(1)
	var gathered_down: bool = jet._pitch_input < -0.99
	neutral(p)
	await sim(1)
	check("Up and Down arrows reach the jet as direct pitch commands",
		gathered_up and gathered_down and absf(jet._pitch_input) < 0.001)
	var flight_aim: Vector3 = p.cam.vehicle_aim_direction()
	p.cam._apply_view_mode(CameraRig.ViewMode.FRONT)
	check("front camera never reverses the jet control aim",
		p.cam.vehicle_aim_direction().dot(flight_aim) > 0.999)
	# Cockpit presentation follows the aircraft attitude while the pursuit aim
	# stays in world space. Roll the parked airframe between physics ticks so the
	# assertion is deterministic and cannot disturb the takeoff run below.
	var parked_jet_basis: Basis = jet.global_basis
	p.cam._apply_view_mode(CameraRig.ViewMode.FIRST_PERSON)
	jet.global_basis = parked_jet_basis.rotated(
		parked_jet_basis.z.normalized(), 0.42)
	jet.reset_physics_interpolation()
	p.cam._process(1.0 / 60.0)
	check("cockpit camera follows the jet's rolled horizon",
		p.cam.global_basis.y.dot(jet.global_basis.y) > 0.98)
	jet.global_basis = parked_jet_basis
	jet.reset_physics_interpolation()
	p.cam._apply_view_mode(CameraRig.ViewMode.SHOULDER)
	p.cam._process(1.0 / 60.0)
	check("leaving the rolled jet cockpit clears pitch and roll",
		p.cam.global_basis.y.dot(Vector3.UP) > 0.999)
	# G/F travel through the same gathered just-pressed frame as normal play.
	p.ti.vehicle_gear_just = true
	p.ti.vehicle_flaps_just = true
	await sim(1)
	check("gathered G/F inputs toggle jet gear and flaps once",
		not jet.gear_down and not jet.flaps_down)
	await sim(2)
	check("jet gear/flaps do not retrigger after the press frame",
		not jet.gear_down and not jet.flaps_down)
	p.ti.vehicle_gear_just = true
	p.ti.vehicle_flaps_just = true
	await sim(1)
	check("second gathered G/F press restores takeoff configuration",
		jet.gear_down and jet.flaps_down)
	check("camera cycling preserves straight-ahead jet takeoff aim",
		p.cam.vehicle_aim_direction().dot(jet.global_basis.z) > 0.995)
	var runway_forward: Vector3 = Vector3(
		jet.global_basis.z.x, 0.0, jet.global_basis.z.z).normalized()
	var runway_side: Vector3 = runway_forward.cross(Vector3.UP).normalized()
	var runway_origin: Vector3 = jet.global_position
	# The player-facing takeoff is now the simple combination shown on the HUD:
	# hold W and Up. The mouse aim stays level to prove it is not secretly doing
	# the rotation for this fixture.
	p.cam.pitch = 0.0
	p.ti.dir = Vector2(0, -1)   # W raises the throttle setpoint
	p.ti.vehicle_pitch = 1.0    # Up Arrow commands a protected nose-up rotation
	await sim(240)
	check("turbine spools and the jet rolls out",
		jet.spool > 0.8 and jet.forward_speed() > 16.0,
		"spool=%.2f v=%.1f" % [jet.spool, jet.forward_speed()])
	# Hold the same two keys through rotation; no precisely timed mouse pull is
	# required. Stop as soon as the main gear is clearly airborne.
	for i in range(900):
		if jet.global_position.y > 5.0:
			break
		await sim(1)
	# Compare runway heading in the ground plane. A 14° rotation necessarily
	# reduces a raw 3D dot product even when yaw is perfectly centred.
	var rotation_flat_forward := Vector3(jet.global_basis.z.x, 0.0,
		jet.global_basis.z.z).normalized()
	var rotation_heading_dot: float = rotation_flat_forward.dot(runway_forward)
	var rotation_lateral: float = absf(
		(jet.global_position - runway_origin).dot(runway_side))
	var takeoff_distance: float = (jet.global_position - runway_origin).dot(
		runway_forward)
	# A 400-ish metre roll is both easy in the game and realistic for a light
	# fighter; the 18 m centreline bound still fits a standard 45 m runway with
	# room for its 9.45 m wingspan.
	var stable_rotation_run: bool = jet.global_position.y > 5.0 \
		and jet.forward_speed() > 58.0 and rotation_heading_dot > 0.94 \
		and rotation_lateral < 18.0 and takeoff_distance < 450.0 \
		and jet.global_basis.y.y > 0.80
	check("holding W and Up Arrow produces an easy, straight takeoff",
		stable_rotation_run,
		"alt=%.1f v=%.1f run=%.0fm heading=%.3f lateral=%.1fm up=%.2f spool=%.2f pos=%s" % [
			jet.global_position.y, jet.forward_speed(), takeoff_distance,
			rotation_heading_dot, rotation_lateral,
			jet.global_basis.y.y, jet.spool, jet.global_position])
	if not stable_rotation_run:
		print("VEHICLETEST %d/%d FAIL" % [total - fails, total])
		main.get_tree().quit(1)
		return
	p.ti.sprint = true   # afterburner
	await sim(480)
	var altitude: float = jet.global_position.y - 2.0
	check("Up Arrow keeps the jet in a protected climb", altitude > 25.0,
		"alt=%.0fm v=%.0f" % [altitude, jet.speed()])
	var climb_attitude: float = jet.global_basis.z.y
	p.ti.vehicle_pitch = -1.0
	await sim(90)
	check("Down Arrow lowers the jet's nose",
		jet.global_basis.z.y < climb_attitude - 0.04,
		"before=%.2f after=%.2f" % [climb_attitude, jet.global_basis.z.y])
	# Re-establish the assisted climb and clean up the airframe for the long
	# acceleration run. This is the same simple player flow taught by the HUD:
	# hold Up, tap G/F, and keep Shift held for afterburner.
	p.ti.vehicle_pitch = 1.0
	p.ti.vehicle_gear_just = true
	p.ti.vehicle_flaps_just = true
	await sim(1)
	check("gear and flaps retract for clean accelerated flight",
		not jet.gear_down and not jet.flaps_down)
	p.cam.pitch = 0.05
	Engine.time_scale = 3.0
	await sim(2500)
	Engine.time_scale = 1.0
	var jet_speed: float = jet.speed()
	check("clean jet with afterburner passes 210 m/s", jet_speed > 210.0,
		"%.0f m/s (%.0f mph)" % [jet_speed, jet_speed * 2.23694])
	check("transonic drag caps the jet below 330 m/s", jet_speed < 330.0,
		"%.0f m/s" % jet_speed)
	check("altitude-scaled far plane feeds the pilot's view",
		w.current_view_distance > 4000.0,
		"%.0f m" % w.current_view_distance)
	# Bail out at altitude: monkey leaves, the jet flies on unmanned.
	var bail_pos: Vector3 = p.global_position
	p.ti.interact_just = true
	await sim(3)
	p.ti.interact_just = false
	check("pilot can bail out mid-flight", p.vehicle == null)
	await sim(90)
	check("bailed monkey falls free of the jet",
		p.global_position.distance_to(jet.global_position) > 40.0
		and p.global_position.y < bail_pos.y + 5.0)
	neutral(p)

	print("VEHICLETEST %d/%d %s" % [total - fails, total,
		"PASS" if fails == 0 else "FAIL"])
	main.get_tree().quit(1 if fails > 0 else 0)
