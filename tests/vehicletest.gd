extends Node
## Headless vehicle physics + integration verification on the flat debug
## plane. Every vehicle is driven through the real player input path
## (test-injected ti), so mounting, driving, suspension, drivetrain, lean,
## flight, and dismounting are all exercised end-to-end. Run with:
##   godot --headless --path . res://scenes/main.tscn --quit-after 90000 -- vehicletest

var fails := 0
var total := 0
const MONKEY_STANDING_VISUAL_HEIGHT := 1.35


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
	# Vehicle.settle_at intentionally follows Gen.height for the streaming game
	# world. This suite drives on a separate, real flat debug collider, so author
	# the identical static-sag placement against that plane instead of dropping
	# the bike from an unrelated analytic terrain height at far test distances.
	var lowest := 0.0
	var per_wheel_load: float = bike.mass * 9.8 \
		/ maxf(float(bike.wheels.size()), 1.0)
	for wheel in bike.wheels:
		var sag: float = clampf(per_wheel_load / wheel.spring_rate,
			0.0, wheel.travel * 0.8)
		wheel.compression = sag
		lowest = minf(lowest, wheel.local_pos.y \
			- (wheel.travel - sag) - wheel.radius)
	bike.global_basis = Basis(Vector3.UP, 0.0)
	bike.global_position = Vector3(pos.x,
		DebugWorldBuilder.GROUND_Y - lowest + 0.01, pos.z + 12.0)
	bike.linear_velocity = Vector3.ZERO
	bike.angular_velocity = Vector3.ZERO
	bike._last_safe_position = bike.global_position
	bike._last_safe_yaw = 0.0
	bike.reset_physics_interpolation()
	bike._prev_velocity = Vector3.ZERO
	bike.sleeping = false
	bike.input_throttle = 0.0
	bike.input_brake = 0.0
	bike.input_steer = 0.0
	bike.input_handbrake = false
	bike.input_aux = false
	bike._steer_target = 0.0
	bike._steer_current = 0.0
	bike.lean_target = 0.0
	bike._lean_integral = 0.0
	bike.wheelie_remaining = 0.0
	bike._wheelie_elapsed = 0.0
	bike._wheelie_cooldown = 0.0
	bike._wheelie_crash_emitted = false
	bike._wheelie_overpower = 0.0
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
	var vehicle_yard_ok: bool = bike != null and jeep != null \
		and boat != null and jet != null
	check("vehicle yard spawns all four kinds", vehicle_yard_ok)
	if not vehicle_yard_ok:
		print("VEHICLETEST %d/%d FAIL" % [total - fails, total])
		main.get_tree().quit(1)
		return
	# Five dedicated outlets cover the four machines (the airboat has twin
	# headers). Keep this registry separate from unrelated jet wingtip trails.
	var exhaust_counts_ok: bool = bike.exhaust_emitters.size() == 1 \
		and jeep.exhaust_emitters.size() == 1 \
		and boat.exhaust_emitters.size() == 2 \
		and jet.exhaust_emitters.size() == 1
	check("every vehicle has its exact modeled exhaust outlet count",
		exhaust_counts_ok)
	if not exhaust_counts_ok:
		print("VEHICLETEST %d/%d FAIL" % [total - fails, total])
		main.get_tree().quit(1)
		return
	var exhaust_profiles_ok: bool = bike.exhaust_emitters[0].profile \
		== VehicleExhaust.Profile.BIKE \
		and jeep.exhaust_emitters[0].profile == VehicleExhaust.Profile.JEEP \
		and boat.exhaust_emitters[0].profile == VehicleExhaust.Profile.AIRBOAT \
		and boat.exhaust_emitters[1].profile == VehicleExhaust.Profile.AIRBOAT \
		and jet.exhaust_emitters[0].profile == VehicleExhaust.Profile.JET
	check("exhaust outlets use machine-specific vapor and turbine profiles",
		exhaust_profiles_ok)
	var exhaust_setup_ok := true
	var exhaust_parked_off := true
	var normal_exhaust_capacity := 0
	var exhaust_vehicles: Array[Vehicle] = [bike, jeep, boat, jet]
	for exhaust_vehicle: Vehicle in exhaust_vehicles:
		for emitter: VehicleExhaust in exhaust_vehicle.exhaust_emitters:
			var gpu := emitter.particles
			var process := gpu.process_material as ParticleProcessMaterial
			var quad := gpu.draw_pass_1 as QuadMesh
			var draw_material: StandardMaterial3D = quad.material \
				as StandardMaterial3D if quad else null
			var alignment_ok := false
			if emitter.profile == VehicleExhaust.Profile.JET:
				alignment_ok = draw_material != null \
					and draw_material.billboard_mode \
						== BaseMaterial3D.BILLBOARD_DISABLED \
					and gpu.transform_align \
						== GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
			else:
				alignment_ok = draw_material != null \
					and draw_material.billboard_mode \
						== BaseMaterial3D.BILLBOARD_PARTICLES
			normal_exhaust_capacity += gpu.amount
			exhaust_setup_ok = exhaust_setup_ok and process != null \
				and quad != null and draw_material != null \
				and draw_material.transparency \
					== BaseMaterial3D.TRANSPARENCY_ALPHA \
				and alignment_ok \
				and draw_material.albedo_texture != null \
				and draw_material.vertex_color_use_as_albedo \
				and process.color_ramp != null and process.scale_curve != null \
				and process.direction.normalized().distance_to(
					emitter.outlet_direction) < 0.001 \
				and not gpu.local_coords and gpu.fixed_fps == 20 \
				and is_equal_approx(gpu.speed_scale, 1.0) \
				and gpu.cast_shadow \
					== GeometryInstance3D.SHADOW_CASTING_SETTING_OFF \
				and gpu.visibility_aabb.position.is_finite() \
				and gpu.visibility_aabb.size.is_finite() \
				and gpu.visibility_aabb.size.length() > 0.1 \
				and gpu.visibility_range_end > 0.0 \
				and is_equal_approx(process.inherit_velocity_ratio, 1.0) \
				and gpu.amount > 0 and gpu.amount <= 40
			exhaust_parked_off = exhaust_parked_off \
				and emitter.target_intensity < 0.001 \
				and emitter.intensity < 0.001 and not gpu.emitting
	check("exhaust uses bounded world-space GPU particles with no shadows",
		exhaust_setup_ok and normal_exhaust_capacity <= 160,
		"capacity=%d" % normal_exhaust_capacity)
	check("parked unoccupied engines emit no exhaust", exhaust_parked_off)
	var bike_outlet: VehicleExhaust = bike.exhaust_emitters[0]
	var jeep_outlet: VehicleExhaust = jeep.exhaust_emitters[0]
	var jet_outlet: VehicleExhaust = jet.exhaust_emitters[0]
	var airboat_left: VehicleExhaust = boat.exhaust_emitters[0]
	var airboat_right: VehicleExhaust = boat.exhaust_emitters[1]
	check("outlets sit on the visible bike pipe, Jeep tailpipe, and jet nozzle",
		bike_outlet.position.distance_to(
			Vector3(0.14, 0.604, -0.91) * Motorcycle.MODEL_SCALE) < 0.002 \
		and bike_outlet.outlet_direction.dot(Vector3(0, 0, -1)) > 0.99 \
		and jeep_outlet.position.distance_to(
			Vector3(0.55, -0.285, -1.786)) < 0.002 \
		and jeep_outlet.outlet_direction.y < -0.85 \
		and jeep_outlet.outlet_direction.z < -0.30 \
		and jet_outlet.position.distance_to(
			Vector3(0, 0, FighterJet.NOZZLE_LIP_Z)) < 0.002 \
		and jet_outlet.outlet_direction.dot(Vector3(0, 0, -1)) > 0.99)
	check("airboat twin headers are mirrored and share only immutable mesh data",
		airboat_left.position.distance_to(Vector3(-0.96, 0.60, -1.41)) < 0.002 \
		and airboat_right.position.distance_to(
			Vector3(0.96, 0.60, -1.41)) < 0.002 \
		and absf(airboat_left.position.x + airboat_right.position.x) < 0.001 \
		and airboat_left.outlet_direction.x < -0.40 \
		and airboat_right.outlet_direction.x > 0.40 \
		and airboat_left.outlet_direction.z < -0.80 \
		and airboat_right.outlet_direction.z < -0.80 \
		and airboat_left.particles.draw_pass_1 \
			== airboat_right.particles.draw_pass_1 \
		and airboat_left.particles.process_material \
			!= airboat_right.particles.process_material)
	var exhaust_response_ok := true
	for profile_kind in range(VehicleExhaust.Profile.JET + 1):
		var off := VehicleExhaust.sampled_intensity(
			profile_kind, false, 1.0, 1.0, 1.0)
		var idle := VehicleExhaust.sampled_intensity(
			profile_kind, true, 0.18, 0.0)
		var high_unloaded := VehicleExhaust.sampled_intensity(
			profile_kind, true, 0.82, 0.0)
		var loaded := VehicleExhaust.sampled_intensity(
			profile_kind, true, 0.82, 0.78)
		exhaust_response_ok = exhaust_response_ok and off == 0.0 \
			and idle > 0.0 and high_unloaded > idle \
			and loaded > high_unloaded and loaded <= 1.0
	check("every exhaust profile responds monotonically to RPM and load",
		exhaust_response_ok)
	# High quality remains bounded, fullscreen mode reduces every emitter, and
	# leaving both modes restores the exact normal capacity.
	w.set_expensive_effects(true)
	var high_budgets_ok := true
	var high_exhaust_capacity := 0
	for exhaust_vehicle: Vehicle in exhaust_vehicles:
		for emitter: VehicleExhaust in exhaust_vehicle.exhaust_emitters:
			high_exhaust_capacity += emitter.particles.amount
			high_budgets_ok = high_budgets_ok \
				and emitter.particles.amount \
					== VehicleExhaust.particle_budget(emitter.profile, true, false)
	check("high-quality exhaust budget stays bounded",
		high_budgets_ok and high_exhaust_capacity > normal_exhaust_capacity \
		and high_exhaust_capacity <= 160,
		"normal=%d high=%d" % [normal_exhaust_capacity,
			high_exhaust_capacity])
	w.set_fullscreen_performance(true)
	var performance_budgets_ok := true
	var performance_exhaust_capacity := 0
	for exhaust_vehicle: Vehicle in exhaust_vehicles:
		for emitter: VehicleExhaust in exhaust_vehicle.exhaust_emitters:
			performance_exhaust_capacity += emitter.particles.amount
			performance_budgets_ok = performance_budgets_ok \
				and emitter.particles.amount \
					== VehicleExhaust.particle_budget(emitter.profile, true, true) \
				and emitter.particles.amount > 0
	check("fullscreen performance lowers the complete exhaust budget",
		performance_budgets_ok \
		and performance_exhaust_capacity < normal_exhaust_capacity,
		"normal=%d performance=%d" % [normal_exhaust_capacity,
			performance_exhaust_capacity])
	w.set_fullscreen_performance(false)
	w.set_expensive_effects(false)
	var restored_normal_capacity := 0
	var normal_restored_ok := true
	for exhaust_vehicle: Vehicle in exhaust_vehicles:
		for emitter: VehicleExhaust in exhaust_vehicle.exhaust_emitters:
			restored_normal_capacity += emitter.particles.amount
			normal_restored_ok = normal_restored_ok \
				and emitter.particles.amount \
					== VehicleExhaust.particle_budget(emitter.profile, false, false)
	check("exhaust budget restores after adaptive quality exits",
		normal_restored_ok \
		and restored_normal_capacity == normal_exhaust_capacity)
	# Multiplayer uses replicated RPM even though local throttle is untouched.
	jeep.set_remote_controlled(true, 77)
	jeep._remote_rpm = 0.72
	jeep._update_exhaust(0.25)
	check("remote vehicle exhaust follows replicated engine RPM",
		jeep_outlet.target_intensity > 0.45 \
		and jeep_outlet.particles.emitting)
	jeep.set_remote_controlled(false)
	jeep._update_exhaust(0.25)
	# Jet packets encode the independent burner bit alongside normalized spool;
	# decode it through the real remote-state method, not a local-only shortcut.
	jet.spool = 1.0
	jet.afterburner = true
	var encoded_jet_aux: Vector3 = jet.state_aux()
	jet.spool = 0.0
	jet.afterburner = false
	jet.set_remote_controlled(true, 78)
	jet.apply_remote_state(jet.seat_global(), jet.yaw_angle(),
		encoded_jet_aux, Vector3.ZERO)
	jet._update_exhaust(0.25)
	jet._update_extra_visuals(0.0)
	check("remote jet replicates spool, afterburner, core, and plume boost",
		encoded_jet_aux.z > FighterJet.REMOTE_AFTERBURNER_OFFSET \
		and jet.spool > 0.99 and jet.afterburner \
		and jet._remote_rpm > 0.99 and jet_outlet.boost > 0.70 \
		and jet_outlet.target_intensity > 0.90 \
		and jet._nozzle_glow.albedo_color.a > 0.07,
		"encoded=%.2f spool=%.2f ab=%s rpm=%.2f boost=%.2f target=%.2f alpha=%.3f" % [
			encoded_jet_aux.z, jet.spool, jet.afterburner, jet._remote_rpm,
			jet_outlet.boost, jet_outlet.target_intensity,
			jet._nozzle_glow.albedo_color.a])
	# The same remotely controlled node must remain a visible/audible contact at
	# ten miles without retaining its detailed close mesh or particle budget.
	jet._update_distance_lod(FighterJet.TEN_MILES_METERS)
	var jet_detail_body := jet.get_node_or_null("Body") as Node3D
	var far_silhouette: MeshInstance3D = jet._far_silhouette
	check("remote jet switches to one cheap ten-mile aircraft silhouette",
		jet.remote_controlled and jet_detail_body != null \
			and not jet_detail_body.visible \
			and far_silhouette != null and far_silhouette.visible \
			and far_silhouette.get_parent() == jet \
			and far_silhouette.mesh.get_surface_count() == 1 \
			and far_silhouette.scale.x > 1.7 \
			and far_silhouette.cast_shadow \
				== GeometryInstance3D.SHADOW_CASTING_SETTING_OFF \
			and far_silhouette.ignore_occlusion_culling,
		"body=%s far=%s scale=%.2f surfaces=%d" % [
			jet_detail_body.visible if jet_detail_body else true,
			far_silhouette.visible if far_silhouette else false,
			far_silhouette.scale.x if far_silhouette else 0.0,
			far_silhouette.mesh.get_surface_count() if far_silhouette else 0])
	var ten_mile_spl := FighterJet.turbine_spl_at_distance(
		FighterJet.TEN_MILES_METERS)
	var ten_mile_game_db := FighterJet.turbine_game_volume_db(
		FighterJet.SAFE_AUDIO_MAX_DB, FighterJet.TEN_MILES_METERS)
	check("130 dB jet source remains faint and safely clamped at ten miles",
		absf(ten_mile_spl - 45.87) < 0.25 \
			and ten_mile_game_db > -44.0 and ten_mile_game_db < -39.0 \
			and jet._engine_player.max_distance \
				> FighterJet.TEN_MILES_METERS \
			and jet._burner_player.max_distance \
				> FighterJet.TEN_MILES_METERS \
			and jet._engine_player.max_db <= FighterJet.SAFE_AUDIO_MAX_DB \
			and jet._burner_player.max_db <= FighterJet.SAFE_AUDIO_MAX_DB \
			and jet._engine_player.attenuation_model \
				== AudioStreamPlayer3D.ATTENUATION_DISABLED \
			and jet._burner_player.attenuation_model \
				== AudioStreamPlayer3D.ATTENUATION_DISABLED,
		"spl=%.2f game=%.2f engine_range=%.0f burner_range=%.0f" % [
			ten_mile_spl, ten_mile_game_db, jet._engine_player.max_distance,
			jet._burner_player.max_distance])
	var offline_camera_far := World.gameplay_camera_far_distance(
		Gen.VIEW_BASE_DISTANCE, false)
	var online_camera_far := World.gameplay_camera_far_distance(
		Gen.VIEW_BASE_DISTANCE, true)
	check("multiplayer camera sees ten-mile jets without expanding terrain",
		offline_camera_far < FighterJet.TEN_MILES_METERS \
			and online_camera_far >= FighterJet.LONG_RANGE_CAMERA_FAR \
			and online_camera_far <= 30000.0 \
			and is_equal_approx(Gen.VIEW_BASE_DISTANCE, 2200.0),
		"offline=%.0f online=%.0f stream=%.0f" % [offline_camera_far,
			online_camera_far, Gen.VIEW_BASE_DISTANCE])
	# Exercise World's on-demand multiplayer path too: a client that never
	# streamed this aircraft's origin still creates the remote jet from its first
	# state packet, at the packet position, with the same far presentation.
	const FAR_REMOTE_JET_ID := "v:far#3"
	var far_remote_seat: Vector3 = p.cam.cam_pos() \
		+ Vector3(0.0, 950.0, -FighterJet.TEN_MILES_METERS)
	w.apply_remote_vehicle_state(79, Vehicle.Kind.JET, FAR_REMOTE_JET_ID,
		far_remote_seat, 0.0, Vector3(0.0, 0.0, 0.88),
		Vector3(0.0, 0.0, -180.0))
	var spawned_far_jet: FighterJet = w.vehicle_by_id(
		FAR_REMOTE_JET_ID) as FighterJet
	var spawned_far_distance: float = spawned_far_jet.global_position.distance_to(
		p.cam.cam_pos()) if spawned_far_jet else 0.0
	if spawned_far_jet:
		spawned_far_jet._update_distance_lod(spawned_far_distance)
	check("first remote state spawns a ten-mile jet as a visible contact",
		spawned_far_jet != null and spawned_far_jet.remote_controlled \
			and spawned_far_jet.occupied_by_peer == 79 \
			and spawned_far_distance > FighterJet.TEN_MILES_METERS \
			and spawned_far_jet._far_silhouette.visible \
			and not spawned_far_jet._detail_body.visible,
		"spawned=%s remote=%s peer=%d distance=%.0f far=%s" % [
			spawned_far_jet != null,
			spawned_far_jet.remote_controlled if spawned_far_jet else false,
			spawned_far_jet.occupied_by_peer if spawned_far_jet else 0,
			spawned_far_distance,
			spawned_far_jet._far_silhouette.visible \
				if spawned_far_jet else false])
	if spawned_far_jet:
		w.vehicles.erase(FAR_REMOTE_JET_ID)
		spawned_far_jet.queue_free()
	jet._update_distance_lod(10.0)
	check("near jet restores its detailed model and hides the far marker",
		jet_detail_body.visible and not far_silhouette.visible)
	jet.set_remote_controlled(false)
	jet.spool = 0.0
	jet.afterburner = false
	jet.engine.rpm = 62.0
	jet._update_exhaust(0.25)
	jet._update_extra_visuals(0.0)
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
	var burner_mesh := jet._nozzle_flame.mesh as CylinderMesh
	var burner_anchor_ok := burner_mesh != null
	for burner_sample in [[0.18, false], [1.0, false], [1.0, true]]:
		jet.spool = float(burner_sample[0])
		jet.afterburner = bool(burner_sample[1])
		jet._update_extra_visuals(0.0)
		var burner_length: float = burner_mesh.height \
			* jet._nozzle_flame.scale.y if burner_mesh else 0.0
		var burner_forward_edge: float = jet._nozzle_flame.position.z \
			+ burner_length * 0.5
		burner_anchor_ok = burner_anchor_ok \
			and absf(burner_forward_edge - FighterJet.NOZZLE_LIP_Z) < 0.002 \
			and jet._nozzle_glow.albedo_color.a <= 0.10
	jet.spool = 0.0
	jet.afterburner = false
	jet._update_extra_visuals(0.0)
	check("jet burner core stays translucent and anchored at every power",
		burner_anchor_ok)

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
	var jeep_idle_exhaust := jeep_outlet.intensity
	check("occupied Jeep settles into a light idle vapor",
		jeep_idle_exhaust > 0.08 and jeep_outlet.particles.emitting,
		"intensity=%.3f" % jeep_idle_exhaust)
	check("jeep rider is planted on authored seat and controls",
		rider_contract_ok(p, jeep))
	check("American Jeep uses the vehicle-left driver seat and steering wheel",
		jeep.seat_offset.x > 0.30 and jeep.rider_root_offset.x > 0.30 \
			and jeep.fp_camera_offset.x > 0.30 \
			and jeep._steering_wheel.position.x > 0.30,
		"seat=%s root=%s wheel=%s" % [jeep.seat_offset,
			jeep.rider_root_offset, jeep._steering_wheel.position])
	main.hud._update_vehicle_cluster()
	check("jeep has an accurate analog automatic-transmission cluster",
		jeep.engine.auto_shift and main.hud.vehicle_tachometer.visible \
		and is_equal_approx(main.hud.vehicle_tachometer.rpm, jeep.engine.rpm) \
		and is_equal_approx(main.hud.vehicle_tachometer.scale_max_rpm, 6000.0) \
		and is_equal_approx(main.hud.vehicle_tachometer.needle_fraction,
			jeep.engine.rpm / 6000.0) \
		and is_equal_approx(main.hud.vehicle_tachometer.redline_fraction,
			5100.0 / 6000.0))
	main.hud._update_aircraft_aim_reticle(false)
	check("aircraft aim reticle stays hidden in ground vehicles",
		not main.hud.aircraft_aim_reticle.visible)
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
	p.cam._process(1.0 / 60.0)
	var jeep_chase_offset: Vector3 = p.cam.cam_pos() - jeep.seat_render_global()
	check("vehicle chase camera is centered directly behind the machine",
		absf(p.cam._arm.position.x) < 0.01 \
			and jeep_chase_offset.normalized().dot(-jeep.global_basis.z) > 0.70,
		"arm=%s offset=%s" % [p.cam._arm.position, jeep_chase_offset])
	p.cam._apply_view_mode(CameraRig.ViewMode.FRONT)
	var vehicle_front_blocked: bool = \
		p.cam.view_mode == CameraRig.ViewMode.SHOULDER
	var first_vehicle_cycle: int = p.cam.toggle_view()
	# Camera following is intentionally smoothed; advance one representative
	# render hitch window so this checks the final authored anchor, not the first
	# interpolation sample after switching modes.
	p.cam._process(0.25)
	var expected_head: Vector3 = jeep.get_global_transform_interpolated() \
		* jeep.fp_camera_offset
	var head_camera_error: float = p.cam.cam_pos().distance_to(expected_head)
	var second_vehicle_cycle: int = p.cam.toggle_view()
	check("vehicle camera cycles only between centered chase and monkey head",
		vehicle_front_blocked \
			and first_vehicle_cycle == CameraRig.ViewMode.FIRST_PERSON \
			and second_vehicle_cycle == CameraRig.ViewMode.SHOULDER \
			and head_camera_error < 0.18 and not p.cam.front_view,
		"blocked=%s cycles=%d/%d head_error=%.3f" % [
			str(vehicle_front_blocked), first_vehicle_cycle, second_vehicle_cycle,
			head_camera_error])
	main.hud._process(0.0)
	check("vehicle HUD names the centered chase/head camera pair",
		main.hud.camera_badge.text.contains("CENTERED CHASE") \
			and main.hud._vehicle_hint(jeep).contains("chase/head"))
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
	check("Jeep exhaust thickens smoothly under real drivetrain load",
		jeep_outlet.target_intensity > jeep_idle_exhaust + 0.25 \
		and jeep_outlet.intensity > jeep_idle_exhaust + 0.20 \
		and jeep_outlet.particles.amount_ratio > 0.35 \
		and (jeep_outlet.particles.process_material \
			as ParticleProcessMaterial).initial_velocity_max > 1.40 \
		and is_equal_approx(jeep_outlet.particles.speed_scale, 1.0),
		"idle=%.3f target=%.3f live=%.3f" % [jeep_idle_exhaust,
			jeep_outlet.target_intensity, jeep_outlet.intensity])
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
	var jeep_park_position: Vector3 = jeep.global_position
	var jeep_park_basis: Basis = jeep.global_basis
	await sim(45)
	check("E dismounts and restores the monkey",
		p.vehicle == null and not p._collision_shape.disabled
		and p.collision_layer == 1)
	check("released jeep parks with its brakes on",
		jeep.driver == null and jeep.input_brake > 0.99
		and jeep.input_handbrake
		and jeep.freeze and jeep.sleeping \
		and jeep.global_position.distance_to(jeep_park_position) < 0.015 \
		and jeep.global_basis.y.dot(jeep_park_basis.y) > 0.999 \
		and jeep.linear_velocity.length() < 0.01 \
		and jeep.angular_velocity.length() < 0.01,
		"brake=%.2f handbrake=%s velocity=%s" % [jeep.input_brake,
			str(jeep.input_handbrake), jeep.linear_velocity])
	var replicated_jeep_rest := [jeep.global_position, jeep.yaw_angle(),
		jeep.state_aux().x, jeep.state_aux().y]
	jeep.apply_rest_state(replicated_jeep_rest[0], replicated_jeep_rest[1],
		replicated_jeep_rest[2], replicated_jeep_rest[3])
	await sim(8)
	check("replicated Jeep rest state rebuilds the same no-pop parking lock",
		jeep.freeze and jeep.sleeping \
			and jeep.global_position.distance_to(replicated_jeep_rest[0]) < 0.005 \
			and jeep.linear_velocity.length() < 0.001 \
			and jeep.angular_velocity.length() < 0.001)
	check("parked Jeep stops spawning vapor after its plume clears",
		jeep_outlet.target_intensity < 0.001 \
		and jeep_outlet.intensity < 0.012 \
		and not jeep_outlet.particles.emitting,
		"target=%.4f live=%.4f" % [jeep_outlet.target_intensity,
			jeep_outlet.intensity])

	# --- motorcycle ----------------------------------------------------------
	mounted = await mount(p, w, bike)
	check("monkey saddles the dual-sport", mounted)
	await sim(18)
	check("bike rider is planted on authored saddle and controls",
		rider_contract_ok(p, bike))
	var bike_idle_exhaust := bike_outlet.intensity
	check("bike thumper has a subtle pulsing idle exhaust",
		bike_idle_exhaust > 0.08 and bike_outlet.particles.emitting,
		"intensity=%.3f" % bike_idle_exhaust)
	var bike_front: VehicleWheel = bike.wheels[0]
	var bike_rear: VehicleWheel = bike.wheels[1]
	var bike_wheelbase := absf(bike_front.local_pos.z - bike_rear.local_pos.z)
	var bike_wheelbase_ratio := bike_wheelbase / MONKEY_STANDING_VISUAL_HEIGHT
	var bike_tire_ratio := 2.0 * maxf(bike_front.radius, bike_rear.radius) \
		/ MONKEY_STANDING_VISUAL_HEIGHT
	var bike_model := bike.get_node_or_null("Body") as Node3D
	check("bike is proportioned to the full-size monkey rider",
		bike_wheelbase_ratio >= 0.88 and bike_wheelbase_ratio <= 1.02 \
		and bike_tire_ratio >= 0.38 and bike_tire_ratio <= 0.46 \
		and bike_model != null \
		and bike_model.scale.distance_to(Vector3.ONE * Motorcycle.MODEL_SCALE) \
			< 0.001,
		"wheelbase=%.3f rider ratio=%.3f tire ratio=%.3f" % [
			bike_wheelbase, bike_wheelbase_ratio, bike_tire_ratio])
	# Let the added 38 kg rider payload settle before measuring the loaded ride
	# height and sag. These values guard the visible lowering without allowing a
	# cosmetic-only scale or a suspension that sits on its bumpstops.
	await sim(72)
	var bike_ground: float = bike.terrain_height_at(
		bike.global_position.x, bike.global_position.z)
	var bike_chassis_height: float = bike.global_position.y - bike_ground
	var saddle_top := bike.get_node_or_null("Body/SaddleTop") as Node3D
	var saddle_height := -INF
	if saddle_top:
		saddle_height = saddle_top.global_position.y - bike_ground
	check("loaded bike has a visibly lower saddle and chassis",
		bike_chassis_height >= 0.42 and bike_chassis_height <= 0.54 \
		and saddle_height / MONKEY_STANDING_VISUAL_HEIGHT >= 0.68 \
		and saddle_height / MONKEY_STANDING_VISUAL_HEIGHT <= 0.82,
		"chassis=%.3f saddle=%.3f rider ratio=%.3f" % [bike_chassis_height,
			saddle_height, saddle_height / MONKEY_STANDING_VISUAL_HEIGHT])
	var suspension_healthy := bike_front.in_contact and bike_rear.in_contact
	for bike_wheel: VehicleWheel in [bike_front, bike_rear]:
		var sag_ratio := bike_wheel.compression / bike_wheel.travel
		suspension_healthy = suspension_healthy \
			and bike_wheel.travel >= 0.18 and bike_wheel.travel <= 0.23 \
			and sag_ratio >= 0.22 and sag_ratio <= 0.65 \
			and bike_wheel.compression < bike_wheel.travel * 0.80
	check("lower bike retains useful loaded suspension travel", suspension_healthy,
		"front %.3f/%.3f rear %.3f/%.3f" % [bike_front.compression,
			bike_front.travel, bike_rear.compression, bike_rear.travel])
	var expected_front_hub := bike_front.local_pos \
		- Vector3.UP * (bike_front.travel - bike_front.compression)
	var expected_rear_hub := bike_rear.local_pos \
		- Vector3.UP * (bike_rear.travel - bike_rear.compression)
	var front_hub_error: float = bike.to_local(
		bike._front_wheel_visual.global_position).distance_to(expected_front_hub)
	var rear_hub_error: float = bike.to_local(
		bike._rear_wheel_visual.global_position).distance_to(expected_rear_hub)
	var front_patch_error := absf(bike._front_wheel_visual.global_position.distance_to(
		bike_front.contact_point) - bike_front.radius)
	var rear_patch_error := absf(bike._rear_wheel_visual.global_position.distance_to(
		bike_rear.contact_point) - bike_rear.radius)
	check("resized wheel meshes remain on physical suspension hubs",
		front_hub_error < 0.01 and rear_hub_error < 0.01 \
		and front_patch_error < 0.02 and rear_patch_error < 0.02,
		"hub %.3f/%.3f patch %.3f/%.3f" % [front_hub_error,
			rear_hub_error, front_patch_error, rear_patch_error])
	var bike_collision: CollisionShape3D
	for child in bike.get_children():
		if child is CollisionShape3D \
				and (child as CollisionShape3D).shape is BoxShape3D:
			bike_collision = child as CollisionShape3D
			break
	var collision_matches := false
	var collision_ratio := 0.0
	if bike_collision:
		var collision_box := bike_collision.shape as BoxShape3D
		collision_ratio = collision_box.size.z / bike_wheelbase
		var collision_bottom := bike_collision.position.y - collision_box.size.y * 0.5
		var skid_plate_bottom := 0.075 * Motorcycle.MODEL_SCALE
		collision_matches = collision_ratio >= 1.10 and collision_ratio <= 1.25 \
			and absf(collision_bottom - skid_plate_bottom) <= 0.04
	check("bike collision hull follows the resized frame", collision_matches,
		"length/wheelbase=%.3f" % collision_ratio)
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
		and main.hud._vehicle_hint(bike).contains(Settings.binding_text(&"crouch")) \
		and main.hud._vehicle_hint(bike).contains("CHASE/HEAD"))
	check("keyboard W holds a safe wheelie before sustained over-power loops it",
		bike.wheelie_target_nose_angle(0.72) \
			> bike.wheelie_target_nose_angle(0.35) + 0.20 \
			and bike.wheelie_target_nose_angle(1.0, 0.0) < PI * 0.5 \
			and bike.wheelie_target_nose_angle(1.0,
				Motorcycle.WHEELIE_OVERPOWER_GRACE - 0.05) < PI * 0.5 \
			and bike.wheelie_target_nose_angle(1.0,
				Motorcycle.WHEELIE_OVERPOWER_FULL + 0.05) > PI * 0.5 \
			and not bike.anti_loop_active())
	var hill_normal := Vector3(0.0, 0.94, -0.342).normalized()
	var hill_stand_basis: Basis = bike.kickstand_basis(
		Vector3.FORWARD, hill_normal)
	check("bike kickstand preserves supported hill pitch without a level snap",
		hill_stand_basis.determinant() > 0.99 \
			and hill_stand_basis.y.dot(hill_normal) > cos(0.13) \
			and absf(hill_stand_basis.z.dot(hill_normal)) < 0.001 \
			and absf(hill_stand_basis.get_euler(EULER_ORDER_YXZ).x) > 0.20,
		"up=%.3f forward=%.4f pose=%s" % [
			hill_stand_basis.y.dot(hill_normal),
			hill_stand_basis.z.dot(hill_normal),
			hill_stand_basis.get_euler(EULER_ORDER_YXZ)])
	p.ti.dir = Vector2(0, -1)
	await sim(120)
	check("bike exhaust responds to real throttle and RPM",
		bike_outlet.target_intensity > bike_idle_exhaust + 0.30 \
		and bike_outlet.particles.amount_ratio > 0.40 \
		and (bike_outlet.particles.process_material \
			as ParticleProcessMaterial).initial_velocity_max > 1.10 \
		and is_equal_approx(bike_outlet.particles.speed_scale, 1.0),
		"idle=%.3f target=%.3f" % [bike_idle_exhaust,
			bike_outlet.target_intensity])
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
	# Steering and rider lean must remain live on momentum alone. Accelerate to a
	# normal trail speed, completely release W, then hold D through the real input
	# path and assert that the coasting machine still banks and changes heading.
	neutral(p)
	reset_bike_control_fixture(bike)
	await sim(24)
	for i in range(360):
		if bike.forward_speed() >= 12.0:
			break
		p.ti.dir = Vector2(0, -1)
		await sim(1)
	var coast_origin: Vector3 = bike.global_position
	var coast_right: Vector3 = -bike.global_basis.x.normalized()
	var coast_start_speed: float = bike.forward_speed()
	p.ti.dir = Vector2(1, 0)
	await sim(55)
	var coast_lean: float = bike.global_basis.get_euler(EULER_ORDER_YXZ).z
	var coast_heading: float = bike.global_basis.z.normalized().dot(coast_right)
	var coast_side: float = (bike.global_position - coast_origin).dot(coast_right)
	check("bike keeps its steering and lean mechanics after W is released",
		coast_start_speed > 9.0 and bike.input_throttle < 0.01 \
			and bike.forward_speed() > 5.0 and coast_lean > 0.05 \
			and coast_heading > 0.055 and coast_side > 0.15,
		"speed %.1f→%.1f lean=%.2f heading=%.2f side=%.2f" % [
			coast_start_speed, bike.forward_speed(), coast_lean, coast_heading,
			coast_side])
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
	# key is released. Hold A through the raised phase to prove the chassis barely
	# changes heading while the front contact patch is airborne.
	# Begin on the real binary W value. After the full-throttle grace sample, add
	# a real normalized W+A diagonal to exercise restricted wheelie steering.
	p.ti.dir = Vector2(0, -1)
	p.ti.crouch_just = true
	p.ti.crouch_held = true
	await sim(1)
	p.ti.crouch_held = false
	var wheelie_triggered: bool = bike.wheelie_active()
	var peak_nose_up := 0.0
	var peak_front_clearance := 0.0
	var lifted_frames := 0
	var rear_supported_lifted_frames := 0
	var current_sustained_lift := 0
	var longest_sustained_lift := 0
	var maximum_wheelie_steer := 0.0
	var wheelie_start_yaw: float = bike.yaw_angle()
	var maximum_wheelie_yaw_change := 0.0
	for i in range(150):
		if i == 20:
			p.ti.dir = Vector2(-0.70710678, -0.70710678)
		# Straighten before the settle phase so this fixture measures the wheelie,
		# not a deliberate post-landing lowside after the assist releases.
		if i == 85:
			p.ti.dir = Vector2.ZERO
		await sim(1)
		var nose_up: float = -bike.global_basis.get_euler(EULER_ORDER_YXZ).x
		peak_nose_up = maxf(peak_nose_up, nose_up)
		var front_center_local: Vector3 = bike.wheels[0].local_pos \
			- Vector3.UP * (bike.wheels[0].travel - bike.wheels[0].compression)
		var front_center_world: Vector3 = bike.to_global(front_center_local)
		var front_clearance: float = front_center_world.y \
			- bike.wheels[0].radius - DebugWorldBuilder.GROUND_Y
		peak_front_clearance = maxf(peak_front_clearance, front_clearance)
		if not bike.wheels[0].in_contact and front_clearance > 0.12:
			lifted_frames += 1
			current_sustained_lift += 1
			longest_sustained_lift = maxi(longest_sustained_lift,
				current_sustained_lift)
			if bike.wheels[1].in_contact:
				rear_supported_lifted_frames += 1
		else:
			current_sustained_lift = 0
		if bike.wheelie_active():
			maximum_wheelie_steer = maxf(maximum_wheelie_steer,
				absf(bike._steer_target))
			maximum_wheelie_yaw_change = maxf(maximum_wheelie_yaw_change,
				absf(angle_difference(wheelie_start_yaw, bike.yaw_angle())))
	var rear_support_ratio := float(rear_supported_lifted_frames) \
		/ maxf(float(lifted_frames), 1.0)
	check("Ctrl raises and sustains a real motorcycle wheelie",
		wheelie_triggered and peak_nose_up >= 0.52 and peak_nose_up < 0.92 \
			and peak_front_clearance >= 0.25 \
			and longest_sustained_lift >= 45 and rear_support_ratio >= 0.80 \
			and bike.driver == p,
		"peak=%.2f clearance=%.2f sustained=%d support=%.0f%%" % [
			peak_nose_up, peak_front_clearance, longest_sustained_lift,
			rear_support_ratio * 100.0])
	check("wheelie sharply limits turning while the front is raised",
		maximum_wheelie_steer <= bike.max_steer_angle * 0.12 \
			and maximum_wheelie_yaw_change < 0.10,
		"steer=%.3f max=%.3f yaw=%.3f" % [maximum_wheelie_steer,
			bike.max_steer_angle * 0.12, maximum_wheelie_yaw_change])
	neutral(p)
	await sim(90)
	check("wheelie timer ends and returns steering authority",
		not bike.wheelie_active())
	var landed_pose: Vector3 = bike.global_basis.get_euler(EULER_ORDER_YXZ)
	check("lower suspension lands a wheelie without bottoming or bouncing",
		bike_front.in_contact and bike_rear.in_contact \
		and absf(landed_pose.x) < 0.15 and absf(landed_pose.z) < 0.30 \
		and bike_front.compression < bike_front.travel * 0.80 \
		and bike_rear.compression < bike_rear.travel * 0.80,
		"pitch=%.3f roll=%.3f compression=%.3f/%.3f" % [landed_pose.x,
			landed_pose.z, bike_front.compression, bike_rear.compression])

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
	# Isolate stand placement from the completed high-speed corner. A lowside is
	# allowed when that manoeuvre is overcooked; parking specifically begins from
	# the real two-wheel, walking-pace state in which E is accepted.
	neutral(p)
	reset_bike_control_fixture(bike)
	await sim(30)
	# Hold neutral for the same settle window as the ordinary dismount helper,
	# then capture the exact pre-E state so the test cannot pass by snapping a
	# side-laid bike back upright inside Motorcycle.end_drive().
	neutral(p)
	await sim(30)
	var pre_dismount_bike_pose: Vector3 = bike.global_basis.get_euler(
		EULER_ORDER_YXZ)
	var pre_dismount_near_ground: bool = bike._both_wheels_near_ground()
	var pre_dismount_speed: float = bike.speed()
	var pre_dismount_up: float = bike.global_basis.y.y
	var pre_dismount_upright: bool = pre_dismount_up > 0.72 \
		and absf(pre_dismount_bike_pose.x) < 0.28 \
		and absf(pre_dismount_bike_pose.z) < 0.60
	p.ti.interact_just = true
	await sim(3)
	p.ti.interact_just = false
	await sim(10)
	check("bike drops to its stand only from a grounded upright park",
		bike.driver == null and pre_dismount_near_ground \
			and pre_dismount_upright and pre_dismount_speed < 1.0,
		"driver=%s pre_pose=%s up=%.3f speed=%.3f near=%s" % [
			str(bike.driver), pre_dismount_bike_pose,
			pre_dismount_up, pre_dismount_speed,
			str(pre_dismount_near_ground)])
	await sim(90)
	var parked_bike_pose: Vector3 = bike.global_basis.get_euler(
		EULER_ORDER_YXZ)
	var parked_bike_supported: bool = bike._has_parked_support()
	check("parked bike sleeps without a numerical physics runaway",
		bike.sleeping and bike.freeze and bike._kickstand_engaged \
			and bike.global_position.is_finite() \
			and bike.linear_velocity.is_finite() \
			and bike.angular_velocity.is_finite() \
			and bike.linear_velocity.length() < 0.2 \
			and parked_bike_supported \
			and absf(parked_bike_pose.x) < 0.25 \
			and absf(angle_difference(parked_bike_pose.z, -0.12)) < 0.25 \
			and bike.physics_recovery_count == 0,
		("sleep=%s support=%s pose=%s recoveries=%d pos=%s linear=%s "
		+ "angular=%s pre_pose=%s pre_near=%s") % [
			str(bike.sleeping), str(parked_bike_supported), parked_bike_pose,
			bike.physics_recovery_count, bike.global_position,
			bike.linear_velocity, bike.angular_velocity, pre_dismount_bike_pose,
			str(pre_dismount_near_ground)])
	var bike_park_position: Vector3 = bike.global_position
	var bike_park_aux: Vector3 = bike.state_aux()
	bike.apply_rest_state(bike_park_position, bike.yaw_angle(),
		bike_park_aux.x, bike_park_aux.y)
	await sim(8)
	check("replicated bike rest state keeps the stand planted without a pop",
		bike.freeze and bike.sleeping and bike._kickstand_engaged \
			and bike.global_position.distance_to(bike_park_position) < 0.015 \
			and bike.linear_velocity.length() < 0.001 \
			and bike.angular_velocity.length() < 0.001)
	var remounted_from_stand: bool = await mount(p, w, bike)
	check("mounting retracts the bike stand before controls resume",
		remounted_from_stand and not bike.freeze \
			and not bike._kickstand_engaged and bike.driver == p)
	await dismount(p)

	# --- airboat over grass ---------------------------------------------------
	mounted = await mount(p, w, boat)
	check("monkey boards the airboat", mounted)
	await sim(18)
	check("airboat rider is planted on authored bench and controls",
		rider_contract_ok(p, boat))
	var airboat_idle_exhaust := airboat_left.intensity
	check("airboat twin headers both idle with the prop engine",
		airboat_idle_exhaust > 0.06 and airboat_left.particles.emitting \
		and airboat_right.particles.emitting \
		and absf(airboat_left.intensity - airboat_right.intensity) < 0.001,
		"left=%.3f right=%.3f" % [airboat_left.intensity,
			airboat_right.intensity])
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
	check("airboat exhaust stretches with fan spool on both headers",
		airboat_left.target_intensity > airboat_idle_exhaust + 0.50 \
		and airboat_right.target_intensity > airboat_idle_exhaust + 0.50 \
		and (airboat_left.particles.process_material \
			as ParticleProcessMaterial).initial_velocity_max > 2.65 \
		and (airboat_right.particles.process_material \
			as ParticleProcessMaterial).initial_velocity_max > 2.65 \
		and is_equal_approx(airboat_left.particles.speed_scale, 1.0) \
		and is_equal_approx(airboat_right.particles.speed_scale, 1.0),
		"idle=%.3f target=%.3f speed=%.2f" % [airboat_idle_exhaust,
			airboat_left.target_intensity,
			(airboat_left.particles.process_material \
				as ParticleProcessMaterial).initial_velocity_max])
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
	var jet_idle_exhaust := jet_outlet.intensity
	check("fighter turbine shows only a thin idle heat plume",
		jet_idle_exhaust > 0.06 and jet_idle_exhaust < 0.30 \
		and jet_outlet.particles.emitting,
		"intensity=%.3f" % jet_idle_exhaust)
	main.hud._process(0.0)
	var flight_reticle: AircraftAimReticle = main.hud.aircraft_aim_reticle
	check("fighter jet shows a centered dot inside its flight-limit circle",
		flight_reticle.visible and not main.hud.crosshair.visible \
		and flight_reticle.normalized_aim.length() < 0.001 \
		and flight_reticle.dot_offset.length() < 0.1 \
		and AircraftAimReticle.DOT_TRAVEL_RADIUS \
			+ AircraftAimReticle.DOT_RADIUS < AircraftAimReticle.RING_RADIUS,
		"visible=%s combat=%s aim=%s dot=%s geometry=%.1f<%.1f" % [
			flight_reticle.visible, main.hud.crosshair.visible,
			flight_reticle.normalized_aim, flight_reticle.dot_offset,
			AircraftAimReticle.DOT_TRAVEL_RADIUS + AircraftAimReticle.DOT_RADIUS,
			AircraftAimReticle.RING_RADIUS])
	# Exercise the real captured-mouse path: screen-right and screen-up move the
	# dot into the matching quadrant while the exact same normalized command is
	# converted into the jet's pursuit direction.
	p.cam.apply_look(Vector2(105.0, -62.0))
	await sim(2)
	main.hud._process(0.0)
	var moderate_flight_aim: Vector2 = p.cam.aircraft_aim_normalized()
	var moderate_control_dot: float = jet._aim.dot(
		p.cam.vehicle_aim_direction())
	check("flight dot follows the real mouse command and jet control aim",
		moderate_flight_aim.x > 0.05 and moderate_flight_aim.y < -0.03 \
		and moderate_flight_aim.length() < 1.0 \
		and flight_reticle.normalized_aim.distance_to(moderate_flight_aim) < 0.001 \
		and flight_reticle.dot_offset.distance_to(moderate_flight_aim \
			* AircraftAimReticle.DOT_TRAVEL_RADIUS) < 0.01 \
		and moderate_control_dot > 0.9999,
		"camera=%s hud=%s dot_error=%.4f control_dot=%.6f" % [
			moderate_flight_aim, flight_reticle.normalized_aim,
			flight_reticle.dot_offset.distance_to(moderate_flight_aim \
				* AircraftAimReticle.DOT_TRAVEL_RADIUS), moderate_control_dot])
	p.cam.apply_look(Vector2(100000.0, -100000.0))
	await sim(2)
	main.hud._process(0.0)
	var maximum_flight_aim: Vector2 = p.cam.aircraft_aim_normalized()
	var requested_aim_angle: float = jet.global_basis.z.angle_to(
		p.cam.vehicle_aim_direction())
	check("flight dot and physical pursuit aim share one circular maximum",
		maximum_flight_aim.length() >= 0.998 \
		and maximum_flight_aim.length() <= 1.001 \
		and flight_reticle.normalized_aim.distance_to(maximum_flight_aim) < 0.001 \
		and flight_reticle.dot_offset.length() \
			+ AircraftAimReticle.DOT_RADIUS < AircraftAimReticle.RING_RADIUS \
		and requested_aim_angle <= p.cam.aircraft_aim_limit_radians() + 0.01 \
		and jet._aim.dot(p.cam.vehicle_aim_direction()) > 0.9999,
		"cursor=%.3f angle=%.1f°" % [maximum_flight_aim.length(),
			rad_to_deg(requested_aim_angle)])
	p.cam.center_aircraft_aim()
	await sim(2)
	main.hud._process(0.0)
	check("centering the flight dot restores straight-ahead pursuit",
		flight_reticle.normalized_aim.length() < 0.03 \
		and p.cam.vehicle_aim_direction().dot(jet.global_basis.z) > 0.999)
	# Request exactly 4% of the ring regardless of the persisted mouse sensitivity:
	# small enough for fine aim, but deterministically above the 1.8% caught-dot
	# snap band.
	var small_dot_pixels: float = 0.04 * p.cam.aircraft_aim_limit_radians() \
		/ p.cam.effective_sensitivity()
	p.cam.apply_look(Vector2(small_dot_pixels, 0.0))
	var requested_small_dot: Vector2 = p.cam.aircraft_aim_normalized()
	await sim(1)
	var small_dot: Vector2 = p.cam.aircraft_aim_normalized()
	var small_local_aim: Vector3 = jet.global_basis.inverse() \
		* p.cam.vehicle_aim_direction()
	check("small visible jet dots stay outside hands-off stabilization",
		requested_small_dot.length() > 0.035 \
			and requested_small_dot.length() < 0.045 \
			and small_dot.length() > 0.018 and small_dot.length() < 0.08 \
			and not jet._hands_off_flight(small_local_aim, false) \
			and absf(jet._pursuit_roll_error(small_local_aim,
				atan2(small_local_aim.y, maxf(small_local_aim.z, 0.05)))) > 0.005,
		"requested=%.4f live=%.4f local=%.4f deadzone=%.4f roll=%.4f" % [
			requested_small_dot.length(), small_dot.length(),
			Vector2(small_local_aim.x, small_local_aim.y).length(),
			FighterJet.HANDS_OFF_AIM_DEADZONE,
			jet._pursuit_roll_error(small_local_aim,
				atan2(small_local_aim.y, maxf(small_local_aim.z, 0.05)))])
	p.cam.center_aircraft_aim()
	check("jet HUD teaches the arrow pitch controls",
		main.hud._vehicle_hint(jet).contains("NOSE UP") \
		and main.hud._vehicle_hint(jet).contains("NOSE DOWN") \
		and main.hud._vehicle_hint(jet).contains(
			Settings.binding_text(&"vehicle_pitch_up")) \
		and main.hud._vehicle_hint(jet).contains(
			Settings.binding_text(&"vehicle_pitch_down")))
	p.ti.vehicle_pitch = 1.0
	p.cam.apply_look(Vector2(300.0, -300.0))
	await sim(1)
	var gathered_up: bool = jet._pitch_input > 0.99
	var arrow_mouse_aim: Vector2 = p.cam.aircraft_aim_normalized()
	p.cam.center_aircraft_aim()
	p.ti.vehicle_pitch = -1.0
	await sim(1)
	var gathered_down: bool = jet._pitch_input < -0.99
	neutral(p)
	await sim(1)
	check("arrow pitch preserves horizontal mouse aim and clears stale vertical aim",
		gathered_up and gathered_down and absf(jet._pitch_input) < 0.001 \
		and arrow_mouse_aim.x > 0.05 and absf(arrow_mouse_aim.y) < 0.03 \
		and p.cam.aircraft_aim_normalized().length() < 0.03)
	var flight_aim: Vector3 = p.cam.vehicle_aim_direction()
	var flight_cursor_before_front: Vector2 = p.cam.aircraft_aim_normalized()
	p.cam._apply_view_mode(CameraRig.ViewMode.FRONT)
	main.hud._process(0.0)
	check("fighter rejects the front camera and keeps the visible flight cursor",
		p.cam.vehicle_aim_direction().dot(flight_aim) > 0.999 \
		and p.cam.aircraft_aim_normalized().distance_to(
			flight_cursor_before_front) < 0.001 \
		and p.cam.view_mode == CameraRig.ViewMode.SHOULDER \
		and not p.cam.front_view and flight_reticle.visible)
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
	p.cam.center_aircraft_aim()
	p.cam.apply_look(Vector2(300.0, 0.0))
	main.hud._process(0.0)
	var rolled_cockpit_aim: Vector3 = p.cam.vehicle_aim_direction()
	var cockpit_screen_right: float = p.cam.cam_basis().x.dot(rolled_cockpit_aim)
	var cockpit_screen_up: float = p.cam.cam_basis().y.dot(rolled_cockpit_aim)
	check("rolled cockpit dot and physical aim use the same screen axes",
		flight_reticle.normalized_aim.x > 0.05 \
		and absf(flight_reticle.normalized_aim.y) < 0.001 \
		and cockpit_screen_right > 0.03 \
		and absf(cockpit_screen_up) < cockpit_screen_right * 0.05,
		"dot=%s screen=(%.3f, %.3f)" % [flight_reticle.normalized_aim,
			cockpit_screen_right, cockpit_screen_up])
	jet.global_basis = parked_jet_basis
	jet.reset_physics_interpolation()
	p.cam.center_aircraft_aim()
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
	check("jet heat plume follows real turbine spool",
		jet_outlet.target_intensity > jet_idle_exhaust + 0.55 \
		and jet_outlet.particles.amount_ratio > 0.60,
		"idle=%.3f target=%.3f ratio=%.3f" % [jet_idle_exhaust,
			jet_outlet.target_intensity, jet_outlet.particles.amount_ratio])
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
		"alt=%.1f v=%.1f run=%.0fm heading=%.3f lateral=%.1fm up=%.2f spool=%.2f driver=%s player_vehicle=%s recoveries=%d pos=%s" % [
			jet.global_position.y, jet.forward_speed(), takeoff_distance,
			rotation_heading_dot, rotation_lateral,
			jet.global_basis.y.y, jet.spool, str(jet.driver != null),
			str(p.vehicle == jet), jet.physics_recovery_count,
			jet.global_position])
	if not stable_rotation_run:
		print("VEHICLETEST %d/%d FAIL" % [total - fails, total])
		main.get_tree().quit(1)
		return
	p.ti.sprint = true   # afterburner
	await sim(480)
	var jet_particle_material := jet_outlet.particles.process_material \
		as ParticleProcessMaterial
	check("afterburner accelerates a translucent blue-white exhaust plume",
		jet_outlet.boost > 0.95 \
		and jet_particle_material.initial_velocity_max > 45.0 \
		and is_equal_approx(jet_outlet.particles.speed_scale, 1.0) \
		and jet_outlet.particles.transform_align \
			== GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY \
		and jet_particle_material.color.b > jet_particle_material.color.r \
		and jet_particle_material.color.a < 0.35,
		"boost=%.2f speed=%.2f color=%s" % [jet_outlet.boost,
			jet_particle_material.initial_velocity_max,
			jet_particle_material.color])
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
	# Perturb a clean, fast jet into a noticeable bank, then let go of every
	# steering channel. Neutral fly-by-wire should remove the bank rather than
	# preserving a tiny roll rate until the aircraft flips itself.
	p.ti.vehicle_pitch = 0.0
	p.ti.dir = Vector2.ZERO
	p.cam.center_aircraft_aim()
	jet.global_basis = jet.global_basis.rotated(
		jet.global_basis.z.normalized(), 0.38)
	jet.angular_velocity = jet.global_basis.z * 0.22
	jet.reset_physics_interpolation()
	p.cam.center_aircraft_aim()
	var hands_off_forward: Vector3 = jet.global_basis.z.normalized()
	var hands_off_bank_before: float = absf(
		jet.global_basis.get_euler(EULER_ORDER_YXZ).z)
	await sim(150)
	var hands_off_bank_after: float = absf(
		jet.global_basis.get_euler(EULER_ORDER_YXZ).z)
	check("neutral jet controls level the wings without a self-induced flip",
		hands_off_bank_before > 0.25 \
			and hands_off_bank_after < hands_off_bank_before * 0.50 \
			and jet.global_basis.y.dot(Vector3.UP) > 0.88 \
			and jet.global_basis.z.dot(hands_off_forward) > 0.80 \
			and absf(jet._pitch_input) < 0.01 \
			and absf(jet.input_steer) < 0.01,
		"bank %.3f→%.3f up=%.3f heading=%.3f" % [hands_off_bank_before,
			hands_off_bank_after, jet.global_basis.y.dot(Vector3.UP),
			jet.global_basis.z.dot(hands_off_forward)])
	# Release arrow assistance, place the mouse dot at the right edge, and prove
	# this is a pursuit target rather than a cosmetic cursor or endless roll
	# stick: the nose closes on its fixed world direction and the dot recentres.
	p.ti.vehicle_pitch = 0.0
	p.cam.center_aircraft_aim()
	await sim(2)
	var right_turn_start_forward: Vector3 = jet.global_basis.z.normalized()
	var right_turn_screen_right: Vector3 = right_turn_start_forward \
		.cross(Vector3.UP).normalized()
	p.cam.apply_look(Vector2(100000.0, 0.0))
	await sim(1)
	var right_turn_target: Vector3 = p.cam.vehicle_aim_direction()
	var right_target_lateral: float = (right_turn_target \
		- right_turn_start_forward * right_turn_target.dot(
			right_turn_start_forward)).dot(right_turn_screen_right)
	var right_turn_alignment_before: float = jet.global_basis.z.dot(
		right_turn_target)
	var right_cursor_before: float = p.cam.aircraft_aim_normalized().length()
	await sim(120)
	var right_turn_alignment_after: float = jet.global_basis.z.dot(
		right_turn_target)
	var right_cursor_after: float = p.cam.aircraft_aim_normalized().length()
	check("jet turns toward the bounded mouse dot and brings it toward centre",
		right_cursor_before > 0.99 \
		and right_target_lateral > 0.1 \
		and right_turn_alignment_after > right_turn_alignment_before + 0.03 \
		and right_cursor_after < right_cursor_before - 0.08 \
		and jet.global_basis.z.dot(right_turn_screen_right) > 0.02,
		"lateral=%.2f dot %.2f→%.2f alignment %.3f→%.3f" % [
			right_target_lateral, right_cursor_before,
			right_cursor_after, right_turn_alignment_before,
			right_turn_alignment_after])
	p.cam.center_aircraft_aim()
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
	main.hud._update_aircraft_aim_reticle(false)
	check("aircraft aim reticle hides after leaving the jet",
		not flight_reticle.visible)
	neutral(p)
	# Finish with the intentionally destructive motorcycle case so the defeated
	# local player is not needed by later fixtures. Full throttle after Ctrl asks
	# for an attitude beyond vertical; only a physically completed backward loop
	# may trigger the lethal impact/ejection path.
	var loop_mounted := await mount(p, w, bike)
	if loop_mounted:
		reset_bike_control_fixture(bike)
		await sim(24)
		for i in range(360):
			if bike.forward_speed() >= 10.0:
				break
			p.ti.dir = Vector2(0, -1)
			await sim(1)
		p.health = MonkeyPlayer.MAX_HEALTH
		# Deliberately leave revive/spawn protection active. The dedicated fatal-loop
		# event must bypass it without weakening protection for ordinary collisions.
		p._invulnerable_t = 30.0
		p.ti.dir = Vector2(0, -1)
		p.ti.crouch_just = true
		p.ti.crouch_held = true
		await sim(1)
		p.ti.crouch_just = false
		p.ti.crouch_held = false
	var loop_peak_angle := 0.0
	var loop_grace_survived := false
	for i in range(360):
		if p.defeated or p.vehicle == null:
			break
		p.ti.dir = Vector2(0, -1)
		await sim(1)
		loop_peak_angle = maxf(loop_peak_angle, atan2(
			bike.global_basis.z.dot(Vector3.UP),
			bike.global_basis.y.dot(Vector3.UP)))
		if i == 75:
			loop_grace_survived = p.vehicle == bike and not p.defeated \
				and loop_peak_angle < PI * 0.5
	check("over-accelerating a wheelie loops the bike and lethally ejects the monkey",
		loop_mounted and loop_grace_survived \
			and loop_peak_angle > deg_to_rad(92.0) \
			and p.vehicle == null and bike.driver == null \
			and p.defeated and p.health <= 0.0,
		"mounted=%s grace=%s peak=%.1f° vehicle=%s driver=%s defeated=%s health=%.1f" % [
			str(loop_mounted), str(loop_grace_survived),
			rad_to_deg(loop_peak_angle), str(p.vehicle), str(bike.driver),
			str(p.defeated), p.health])
	check("all vehicle physics stayed finite without emergency recovery",
		bike.physics_recovery_count == 0 and jeep.physics_recovery_count == 0 \
			and boat.physics_recovery_count == 0 \
			and jet.physics_recovery_count == 0,
		"bike=%d jeep=%d boat=%d jet=%d" % [bike.physics_recovery_count,
			jeep.physics_recovery_count, boat.physics_recovery_count,
			jet.physics_recovery_count])

	print("VEHICLETEST %d/%d %s" % [total - fails, total,
		"PASS" if fails == 0 else "FAIL"])
	main.get_tree().quit(1 if fails > 0 else 0)
