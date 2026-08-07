class_name Motorcycle
extends Vehicle
## 650-class dual-sport thumper: long-travel telescopic forks and a rear
## monoshock swingarm (both visually stroke with the suspension), a real lean
## model — the rider banks the machine to atan(v²/Rg) exactly like physical
## counter-steering resolves, camber thrust carves the corner, and pushing
## past the grip circle lowsides and throws the monkey off — plus wheelies
## under power, stoppies under the front brake, and a genuine 110 mph flat
## out in a tuck. One big single cylinder barks underneath it all.

const WHEELBASE_FRONT := 0.76
const WHEELBASE_REAR := -0.73
const FRONT_RADIUS := 0.34
const REAR_RADIUS := 0.315
const RAKE := 0.45                    # steering-head angle, rad (~26 deg)
const MAX_LEAN := 0.83                # ~48 deg on knobbies
const LOWSIDE_LEAN_ERROR := 0.55

var lean_target := 0.0
var _lean_integral := 0.0
var _tuck := 0.0                      # 0 upright .. 1 full tuck (SHIFT)
var _steer_head: Node3D
var _front_sliders: Array[MeshInstance3D] = []
var _front_wheel_visual: Node3D
var _front_fender: Node3D
var _swingarm: Node3D
var _rear_wheel_visual: Node3D
var _handlebar: Node3D
var _headlight: SpotLight3D
var _shock_spring: MeshInstance3D


func _init() -> void:
	kind = Kind.BIKE
	mass = 170.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.02, 0.02)
	drag_area = 0.55
	max_steer_angle = 0.62
	steer_speed = 4.2
	seat_offset = Vector3(0, 0.62, -0.18)
	fp_camera_offset = Vector3(0, 1.06, -0.10)
	exit_offsets = [Vector3(-1.1, 0.3, 0), Vector3(1.1, 0.3, 0),
		Vector3(0, 0.5, -1.8)]
	camera_distance = 4.6
	camera_height = 1.7
	camera_bank_factor = 0.42
	speed_for_max_fov = 44.0
	driver_mass = 38.0
	engine_stream = "engine_single"
	engine_pitch_base = 0.5
	engine_pitch_span = 1.6

	engine.configure({
		"torque_curve": [[1300, 36.0], [2500, 45.0], [3800, 50.0],
			[5000, 54.0], [6500, 50.0], [7600, 43.0]],
		"idle_rpm": 1300.0,
		"redline_rpm": 7600.0,
		"limiter_rpm": 7900.0,
		"inertia": 0.14,
		"gear_ratios": [2.47, 1.78, 1.38, 1.09, 0.87],
		"reverse_ratio": 0.0,
		"final_drive": 5.86,
		"driveline_efficiency": 0.90,
		"shift_time": 0.16,
		"engine_brake_coefficient": 1.1,
		"clutch_engage_rpm": 2200.0,
	})

	var front := VehicleWheel.new()
	front.configure({
		"local_pos": Vector3(0, -0.05, WHEELBASE_FRONT),
		"radius": FRONT_RADIUS,
		"travel": 0.26,
		"spring_rate": 11500.0,
		"damp_bump": 780.0,
		"damp_rebound": 1250.0,
		"steerable": true,
		"driven": false,
		"brake_share": 0.65,
		"wheel_mass": 11.0,
		"mu_long": 1.02,
		"mu_lat": 0.98,
		"pacejka_b_long": 11.0,
		"pacejka_b_lat": 9.5,
		"rolling_resistance": 0.016,
	})
	wheels.append(front)
	var rear := VehicleWheel.new()
	rear.configure({
		"local_pos": Vector3(0, -0.05, WHEELBASE_REAR),
		"radius": REAR_RADIUS,
		"travel": 0.26,
		"spring_rate": 13800.0,
		"damp_bump": 950.0,
		"damp_rebound": 1650.0,
		"steerable": false,
		"driven": true,
		"brake_share": 0.35,
		"wheel_mass": 13.0,
		"mu_long": 1.05,
		"mu_lat": 0.98,
		"pacejka_b_long": 11.5,
		"pacejka_b_lat": 9.0,
		"rolling_resistance": 0.016,
	})
	wheels.append(rear)


func _ready() -> void:
	super()
	var body_shape := CollisionShape3D.new()
	var body_box := BoxShape3D.new()
	body_box.size = Vector3(0.42, 0.72, 1.85)
	body_shape.shape = body_box
	body_shape.position = Vector3(0, 0.42, 0)
	add_child(body_shape)
	_build_body()


func mount_verb() -> String:
	return "RIDE"


func ejects_rider_on_crash() -> bool:
	return true


func _total_brake_torque() -> float:
	return 1350.0


func _simulate(dt: float) -> void:
	_tuck = move_toward(_tuck, 1.0 if input_aux else 0.0, 3.0 * dt)
	drag_area = lerpf(0.55, 0.40, _tuck)
	# Paddle backward at a stop: no reverse gear on a bike, just monkey feet.
	if driver and input_brake > 0.4 and speed() < 0.9 \
			and _wheels_grounded() == 2:
		apply_central_force(-global_basis.z * 620.0)
	super(dt)
	_advance_lean(dt)
	_check_lowside()


func _wheels_grounded() -> int:
	var n := 0
	for wheel in wheels:
		if wheel.in_contact:
			n += 1
	return n


## The rider's balance. A bike stays up because steering places the contact
## line back under the mass; we model the OUTCOME of that loop: a PD roll
## torque toward the physically correct lean for the current corner, plus an
## upright "feet down" stabilizer at walking pace. Pitch gets rider damping so
## power wheelies rise and settle instead of looping.
func _advance_lean(dt: float) -> void:
	var v := forward_speed()
	var grounded := _wheels_grounded() > 0
	var roll := global_basis.get_euler(EULER_ORDER_YXZ).z
	if driver == null:
		# Sidestand: a parked bike settles into a slight lean and stays.
		if grounded and speed() < 1.0:
			var park_error := -0.12 - roll
			var park_rate := angular_velocity.dot(global_basis.z)
			apply_torque(global_basis.z
				* (park_error * 8.0 - park_rate * 4.0) * mass)
		return
	# Kinematic corner radius from the front wheel's steer angle.
	var effective_steer := _steer_current
	var curvature := tan(effective_steer) / (WHEELBASE_FRONT - WHEELBASE_REAR)
	lean_target = clampf(atan(v * v * curvature / 9.8), -MAX_LEAN, MAX_LEAN) \
		if absf(v) > 0.5 else 0.0
	# At walking pace the rider simply holds it upright with their feet.
	var authority := lerpf(26.0, 15.0, clampf(absf(v) / 14.0, 0.0, 1.0))
	if absf(v) < 2.5:
		lean_target = 0.0
		authority = 34.0
	if not grounded:
		authority = 4.0   # airborne body English only
	var error := lean_target - roll
	var roll_rate := angular_velocity.dot(global_basis.z)
	apply_torque(global_basis.z * (error * authority - roll_rate * authority
		* 0.32) * mass * 0.62)
	# Camber thrust: leaned motorcycle tires push the bike around the corner
	# even before slip angles build. Both contacts, proportional to load.
	if grounded:
		for wheel in wheels:
			if not wheel.in_contact:
				continue
			var side := global_basis.x
			apply_force(side * -sin(roll) * wheel.load * 0.88,
				wheel.contact_point - global_position)
	# Rider pitch damping: soften wheelie/stoppie rotation like a real body
	# hanging off the pegs, and close the throttle past the balance point.
	var pitch_rate := angular_velocity.dot(global_basis.x)
	apply_torque(-global_basis.x * pitch_rate * mass * 0.85)
	var pitch := global_basis.get_euler(EULER_ORDER_YXZ).x
	if pitch > 0.55 and input_throttle > 0.0:
		input_throttle = 0.0   # anti-loop instinct


## Sliding out both contact patches while leaned past recovery is a lowside:
## the machine goes down and the rider tumbles off (Vehicle.driver_impact →
## the player ejects and ragdolls the damage).
func _check_lowside() -> void:
	if driver == null or _wheels_grounded() == 0 or speed() < 6.0:
		return
	var roll := global_basis.get_euler(EULER_ORDER_YXZ).z
	var sliding := true
	for wheel in wheels:
		if wheel.in_contact and absf(wheel.slip_angle) < 0.34:
			sliding = false
	if sliding and absf(roll - lean_target) > LOWSIDE_LEAN_ERROR:
		driver_impact.emit(16.0)
		linear_velocity *= 0.82


func _build_body() -> void:
	var body := Node3D.new()
	body.name = "Body"
	add_child(body)
	var paint := paint_material(Color(0.78, 0.30, 0.06), 0.3, 0.5)
	var frame_mat := paint_material(Color(0.13, 0.13, 0.14), 0.6, 0.42)
	var alloy := chrome_material()

	# Frame spine, downtube, cradle, subframe.
	add_cylinder(body, 0.035, 0.035, 0.72, Vector3(0, 0.52, 0.18), frame_mat,
		Vector3(1.25, 0, 0))
	add_cylinder(body, 0.032, 0.032, 0.58, Vector3(0, 0.33, 0.42), frame_mat,
		Vector3(0.35, 0, 0))
	add_cylinder(body, 0.028, 0.028, 0.55, Vector3(0, 0.44, -0.42), frame_mat,
		Vector3(1.95, 0, 0))
	add_box(body, Vector3(0.16, 0.30, 0.44), Vector3(0, 0.26, 0.08), frame_mat)

	# Engine: cylinder + head + cases + exhaust header sweeping up-right.
	add_box(body, Vector3(0.24, 0.26, 0.30), Vector3(0, 0.22, 0.06),
		dark_metal_material())
	add_cylinder(body, 0.10, 0.11, 0.20, Vector3(0, 0.42, 0.10), alloy,
		Vector3(0.2, 0, 0), 12)
	for i in range(4):
		add_box(body, Vector3(0.26, 0.012, 0.30),
			Vector3(0, 0.34 + 0.045 * float(i), 0.08), dark_metal_material())
	add_cylinder(body, 0.030, 0.030, 0.5, Vector3(0.06, 0.30, 0.32), alloy,
		Vector3(1.05, 0, 0.25))
	add_cylinder(body, 0.045, 0.045, 0.58, Vector3(0.14, 0.56, -0.52), alloy,
		Vector3(1.62, 0, 0))
	add_cylinder(body, 0.055, 0.045, 0.16, Vector3(0.14, 0.60, -0.82), alloy,
		Vector3(1.62, 0, 0))

	# Tank, seat, tail, side number plates, skid plate.
	var tank := add_sphere(body, 0.17, Vector3(0, 0.70, 0.16), paint, 0.72)
	tank.scale = Vector3(0.85, 1.0, 1.5)
	add_box(body, Vector3(0.24, 0.07, 0.62), Vector3(0, 0.655, -0.30),
		paint_material(Color(0.09, 0.09, 0.09), 0.1, 0.85))
	add_box(body, Vector3(0.20, 0.05, 0.30), Vector3(0, 0.67, -0.68), paint,
		Vector3(-0.18, 0, 0))
	for side in [-0.13, 0.13]:
		add_box(body, Vector3(0.015, 0.16, 0.24), Vector3(side, 0.42, -0.42),
			paint_material(Color(0.92, 0.90, 0.84), 0.0, 0.7))
	add_box(body, Vector3(0.26, 0.02, 0.42), Vector3(0, 0.085, 0.10), alloy)
	# Taillight + rear fender.
	add_box(body, Vector3(0.14, 0.05, 0.16), Vector3(0, 0.72, -0.86), paint,
		Vector3(-0.3, 0, 0))
	add_box(body, Vector3(0.05, 0.03, 0.05), Vector3(0, 0.69, -0.94),
		paint_material(Color(0.6, 0.05, 0.05), 0.1, 0.4))

	# Steering head: forks, triple clamps, handlebar, front fender, light.
	_steer_head = Node3D.new()
	_steer_head.position = Vector3(0, 0.72, 0.55)
	_steer_head.rotation = Vector3(-RAKE, 0, 0)
	body.add_child(_steer_head)
	for side in [-0.095, 0.095]:
		add_cylinder(_steer_head, 0.022, 0.022, 0.46,
			Vector3(side, -0.10, 0), alloy)
		var slider := add_cylinder(_steer_head, 0.028, 0.028, 0.42,
			Vector3(side, -0.48, 0), frame_mat)
		_front_sliders.append(slider)
	for clamp_y in [0.04, -0.12]:
		add_box(_steer_head, Vector3(0.26, 0.04, 0.09),
			Vector3(0, clamp_y, 0), frame_mat)
	_handlebar = Node3D.new()
	_handlebar.position = Vector3(0, 0.10, 0)
	_steer_head.add_child(_handlebar)
	add_cylinder(_handlebar, 0.016, 0.016, 0.62, Vector3(0, 0.03, -0.02),
		alloy, Vector3(0, 0, PI / 2.0))
	for side in [-0.30, 0.30]:
		add_cylinder(_handlebar, 0.022, 0.022, 0.11,
			Vector3(side, 0.03, -0.02),
			paint_material(Color(0.08, 0.08, 0.08), 0.0, 0.9),
			Vector3(0, 0, PI / 2.0))
		add_box(_handlebar, Vector3(0.015, 0.015, 0.12),
			Vector3(side * 0.72, 0.05, 0.02), alloy)
	add_box(_steer_head, Vector3(0.17, 0.20, 0.05), Vector3(0, 0.02, 0.09),
		paint)
	var lamp_mesh := add_cylinder(_steer_head, 0.065, 0.065, 0.04,
		Vector3(0, -0.03, 0.10),
		paint_material(Color(0.95, 0.93, 0.78), 0.1, 0.2),
		Vector3(RAKE + PI / 2.0, 0, 0))
	lamp_mesh.name = "Headlamp"
	_headlight = SpotLight3D.new()
	_headlight.position = Vector3(0, -0.03, 0.14)
	_headlight.rotation = Vector3(RAKE - 0.06, PI, 0)
	_headlight.spot_range = 38.0
	_headlight.spot_angle = 26.0
	_headlight.light_energy = 0.0
	_headlight.light_color = Color(1.0, 0.95, 0.82)
	_steer_head.add_child(_headlight)
	_front_fender = Node3D.new()
	_steer_head.add_child(_front_fender)
	add_box(_front_fender, Vector3(0.22, 0.03, 0.55), Vector3.ZERO, paint,
		Vector3(0.1, 0, 0))
	_front_wheel_visual = build_knobby_wheel(FRONT_RADIUS, 0.115, 16,
		Color(0.2, 0.2, 0.22))
	_steer_head.add_child(_front_wheel_visual)
	wheels[0].visual = null   # posed manually along the fork axis

	# Swingarm, monoshock, chain run, rear wheel.
	_swingarm = Node3D.new()
	_swingarm.position = Vector3(0, 0.30, -0.16)
	body.add_child(_swingarm)
	for side in [-0.10, 0.10]:
		add_box(_swingarm, Vector3(0.035, 0.05, 0.62),
			Vector3(side, 0, -0.28), frame_mat)
	_rear_wheel_visual = build_knobby_wheel(REAR_RADIUS, 0.13, 16,
		Color(0.2, 0.2, 0.22))
	_swingarm.add_child(_rear_wheel_visual)
	_rear_wheel_visual.position = Vector3(0, 0, -0.57)
	add_cylinder(_swingarm, 0.055, 0.055, 0.03,
		Vector3(0.085, 0, -0.57), alloy, Vector3(0, 0, PI / 2.0))
	_shock_spring = add_cylinder(body, 0.045, 0.045, 0.26,
		Vector3(0, 0.50, -0.26), paint_material(Color(0.85, 0.15, 0.12), 0.3, 0.5),
		Vector3(0.35, 0, 0), 8)
	wheels[1].visual = null   # posed by the swingarm

	# Mirrors.
	for side in [-0.26, 0.26]:
		add_cylinder(body, 0.008, 0.008, 0.12,
			Vector3(side, 0.92, 0.44), frame_mat, Vector3(0.5, 0, side * 1.2))
		add_box(body, Vector3(0.07, 0.05, 0.01),
			Vector3(side * 1.25, 0.98, 0.42), alloy)


## Forks compress along their raked axis, the swingarm rotates to follow the
## rear wheel, and the bar assembly steers around the head tube.
func _update_extra_visuals(_dt: float) -> void:
	if _steer_head == null:
		return
	_steer_head.rotation = Vector3(-RAKE, 0, 0)
	_steer_head.rotate_object_local(Vector3.UP, _steer_current)
	var front := wheels[0]
	# Wheel center along the fork axis: attach - remaining extension.
	var fork_extension := (front.travel - front.compression)
	_front_wheel_visual.position = Vector3(0, -0.67 - fork_extension * 0.92,
		0.02)
	_front_wheel_visual.rotation = Vector3.ZERO
	_front_wheel_visual.rotate_object_local(Vector3.RIGHT, front.spin_angle)
	_front_fender.position = _front_wheel_visual.position \
		+ Vector3(0, FRONT_RADIUS + 0.06, 0)
	for slider in _front_sliders:
		slider.position.y = -0.48 - fork_extension * 0.5
	var rear := wheels[1]
	# Swingarm angle from the rear wheel's vertical travel about its pivot.
	var rear_drop := 0.35 + (rear.travel - rear.compression)
	var arm_angle := asin(clampf((rear_drop - 0.35) / 0.62, -0.6, 0.6))
	_swingarm.rotation = Vector3(arm_angle, 0, 0)
	_rear_wheel_visual.rotation = Vector3.ZERO
	_rear_wheel_visual.rotate_object_local(Vector3.RIGHT, rear.spin_angle)
	if _shock_spring:
		_shock_spring.scale.y = clampf(
			1.0 - rear.compression / maxf(rear.travel, 0.01) * 0.35, 0.6, 1.0)
	var night := false
	if world and world.get("time_of_day_hours") != null:
		var hour: float = world.time_of_day_hours
		night = hour < 6.2 or hour > 18.8
	if _headlight:
		_headlight.light_energy = lerpf(_headlight.light_energy,
			4.5 if (driver != null or remote_controlled) and night else 0.0,
			0.2)
