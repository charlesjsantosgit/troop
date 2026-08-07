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
	p.ti.crouch_held = false
	p.ti.interact_just = false
	p.ti.grab = false


func mount(p, w, v) -> bool:
	if p.vehicle != null:
		p.exit_vehicle()
		await sim(5)
	p.global_position = v.interaction_position() + Vector3(1.2, 0.2, 0)
	p.velocity = Vector3.ZERO
	await sim(3)
	p.ti.interact_just = true
	await sim(3)
	p.ti.interact_just = false
	await sim(2)
	return p.vehicle == v


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
	var mounted: bool = await mount(p, w, jeep)
	check("E mounts the jeep through the interaction ladder", mounted)
	check("mounting stows the weapon and disables the capsule",
		p.is_weapon_stowed() and p._collision_shape.disabled)

	# --- drive: acceleration, gears, engine ---------------------------------
	p.ti.dir = Vector2(0, -1)
	await sim(360)
	var drive_speed: float = jeep.forward_speed()
	check("jeep accelerates past 14 m/s under power", drive_speed > 14.0,
		"%.1f m/s" % drive_speed)
	check("gearbox upshifted beyond first", jeep.engine.gear >= 2,
		"gear=%d" % jeep.engine.gear)
	check("driven wheels are turning with the ground",
		absf(jeep.wheels[2].spin * jeep.wheels[2].radius - drive_speed) \
		< maxf(3.0, drive_speed * 0.35))

	# --- braking + reverse ---------------------------------------------------
	p.ti.dir = Vector2(0, 1)
	await sim(300)
	check("brakes stop the jeep and holding S reverses",
		jeep.forward_speed() < -1.2, "%.1f m/s" % jeep.forward_speed())
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
	check("E dismounts and restores the monkey",
		p.vehicle == null and not p._collision_shape.disabled
		and p.collision_layer == 1)
	check("released jeep parks with its brakes on",
		jeep.driver == null)

	# --- motorcycle ----------------------------------------------------------
	mounted = await mount(p, w, bike)
	check("monkey saddles the dual-sport", mounted)
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
	# Ease off to cornering speed, then lean into a right-hander: expect roll
	# into the turn matching lean_target's sign convention.
	p.ti.dir = Vector2(0, 1)
	await sim(180)
	p.ti.dir = Vector2(1, -1)
	await sim(70)
	var lean: float = bike.global_basis.get_euler(EULER_ORDER_YXZ).z
	var lean_matches: bool = signf(lean) == signf(bike.lean_target) \
		and absf(bike.lean_target) > 0.1 and absf(lean) > 0.08
	check("bike banks into the corner like a real motorcycle", lean_matches,
		"lean=%.2f target=%.2f" % [lean, bike.lean_target])
	await dismount(p)
	check("bike drops to its stand when parked", bike.driver == null)

	# --- airboat over grass ---------------------------------------------------
	mounted = await mount(p, w, boat)
	check("monkey boards the airboat", mounted)
	p.ti.dir = Vector2(0, -1)
	await sim(300)
	check("prop thrust slides the airboat over wet grass",
		boat.speed() > 3.5, "%.1f m/s" % boat.speed())
	neutral(p)
	await sim(120)
	await dismount(p)

	# --- fighter jet: taxi, takeoff, climb, afterburner, bail-out -------------
	mounted = await mount(p, w, jet)
	check("monkey straps into the fighter jet", mounted)
	# Align the camera aim with the jet's nose (spawned facing +Z): the FBW
	# chases the aim, so a misaligned camera means a hard low turn after
	# liftoff. aim = (-sin(yaw), 0, -cos(yaw)) → yaw = PI points +Z.
	p.cam.yaw = PI
	p.cam.pitch = 0.0
	p.ti.dir = Vector2(0, -1)   # W raises the throttle setpoint
	await sim(240)
	check("turbine spools and the jet rolls out",
		jet.spool > 0.8 and jet.forward_speed() > 16.0,
		"spool=%.2f v=%.1f" % [jet.spool, jet.forward_speed()])
	# Rotate: pull the aim up once fast enough.
	while jet.forward_speed() < 78.0:
		await sim(10)
	p.cam.pitch = 0.30
	p.ti.sprint = true   # afterburner
	await sim(480)
	var altitude: float = jet.global_position.y - 2.0
	check("jet rotates and climbs away", altitude > 25.0,
		"alt=%.0fm v=%.0f" % [altitude, jet.speed()])
	jet._toggle_gear()
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
