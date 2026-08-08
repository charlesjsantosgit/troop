class_name SafariJeep
extends Vehicle
## Expedition 4x4 tuned like a classic straight-six safari truck: live axles
## on long-travel coils, permanent four-wheel drive with a driver-selectable
## low-range transfer case (SHIFT), front-biased brakes, and a body built from
## code — tub, roll cage, snorkel, winch, spare, jerry cans, and a steering
## wheel that actually steers. ~1650 kg, ~190 hp, about 100 mph flat out.

const TRACK := 0.725
const WHEELBASE_FRONT := 1.40
const WHEELBASE_REAR := -1.39
const WHEEL_RADIUS := 0.38
const LOW_RANGE_MULTIPLIER := 2.72
const LOW_RANGE_MAX_SPEED := 0.8

var low_range := false
var _aux_was_down := false
var _steering_wheel: Node3D
var _front_axle: Node3D
var _rear_axle: Node3D
var _headlights: Array[SpotLight3D] = []
var _taillights: Array[MeshInstance3D] = []


func _init() -> void:
	kind = Kind.JEEP
	mass = 1650.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.05, 0.04)
	drag_area = 1.9
	max_steer_angle = 0.58
	steer_speed = 2.6
	seat_offset = Vector3(-0.36, 0.78, 0.30)
	# Rig origin chosen from the actual front cushion top (y=0.58), rather
	# than the motorcycle's old universal sink, which left the driver hovering.
	rider_root_offset = Vector3(-0.36, 0.16, 0.22)
	fp_camera_offset = Vector3(-0.36, 1.34, 0.30)
	exit_offsets = [Vector3(-1.6, 0.4, 0.3), Vector3(1.6, 0.4, 0.3),
		Vector3(0, 0.6, -3.0)]
	camera_distance = 6.4
	camera_height = 2.25
	speed_for_max_fov = 34.0
	engine_stream = "engine_i6"
	engine_pitch_base = 0.5
	engine_pitch_span = 1.45

	engine.configure({
		"torque_curve": [[750, 165.0], [1600, 240.0], [2400, 285.0],
			[3300, 305.0], [4200, 290.0], [4900, 258.0], [5400, 222.0]],
		"idle_rpm": 750.0,
		"redline_rpm": 5100.0,
		"limiter_rpm": 5400.0,
		"inertia": 0.9,
		"gear_ratios": [4.0, 2.32, 1.54, 1.0, 0.73],
		"reverse_ratio": 3.52,
		"final_drive": 4.10,
		"driveline_efficiency": 0.85,
		"auto_shift": true,
		"shift_time": 0.32,
		"engine_brake_coefficient": 1.6,
		"clutch_engage_rpm": 1500.0,
	})

	for corner in [[-TRACK, WHEELBASE_FRONT, true], [TRACK, WHEELBASE_FRONT, true],
			[-TRACK, WHEELBASE_REAR, false], [TRACK, WHEELBASE_REAR, false]]:
		var wheel := VehicleWheel.new()
		wheel.configure({
			"local_pos": Vector3(corner[0], -0.16, corner[1]),
			"radius": WHEEL_RADIUS,
			"travel": 0.24,
			"spring_rate": 34000.0,
			"damp_bump": 2600.0,
			"damp_rebound": 4500.0,
			"steerable": corner[2],
			"driven": true,   # permanent 4WD
			"brake_share": 0.30 if corner[2] else 0.20,
			"wheel_mass": 26.0,
			"mu_long": 1.0,
			"mu_lat": 0.92,
			"pacejka_b_long": 10.0,
			"pacejka_b_lat": 7.8,
			"rolling_resistance": 0.02,
		})
		wheels.append(wheel)
	anti_roll = [[0, 1, 15000.0], [2, 3, 10500.0]]


func _ready() -> void:
	super()
	var chassis_shape := CollisionShape3D.new()
	var chassis_box := BoxShape3D.new()
	chassis_box.size = Vector3(1.62, 0.85, 3.85)
	chassis_shape.shape = chassis_box
	chassis_shape.position = Vector3(0, 0.42, 0)
	add_child(chassis_shape)
	var cage_shape := CollisionShape3D.new()
	var cage_box := BoxShape3D.new()
	cage_box.size = Vector3(1.4, 0.75, 1.9)
	cage_shape.shape = cage_box
	cage_shape.position = Vector3(0, 1.18, -0.15)
	add_child(cage_shape)
	_build_body()
	# Outlet sits at the lower/aft cap of the modeled tailpipe, not at the
	# vehicle origin, so puffs cannot appear through the spare tire or tub.
	add_exhaust(Vector3(0.55, -0.285, -1.786),
		Vector3(0, -0.939, -0.343), VehicleExhaust.Profile.JEEP)


func mount_verb() -> String:
	return "DRIVE"


func _total_brake_torque() -> float:
	return 5600.0


func low_range_shift_available() -> bool:
	return driver != null and speed() < LOW_RANGE_MAX_SPEED \
		and input_throttle < 0.1 and input_brake < 0.1


## SHIFT toggles the low-range transfer case on a rising edge, only while truly
## stopped with both pedals released so the ratio cannot jump under forward or
## reverse driveline load (S becomes reverse throttle once reverse is engaged).
func _simulate(dt: float) -> void:
	if input_aux and not _aux_was_down and low_range_shift_available():
		low_range = not low_range
		engine.final_drive = 4.10 * (LOW_RANGE_MULTIPLIER if low_range else 1.0)
		Sfx.play_at("gear_clunk", global_position, -6.0,
			0.8 if low_range else 1.1)
	_aux_was_down = input_aux
	super(dt)


func _build_body() -> void:
	var body := Node3D.new()
	body.name = "Body"
	add_child(body)
	var paint := paint_material(Color(0.45, 0.44, 0.30), 0.25, 0.6)
	var trim := dark_metal_material()
	var frame_mat := paint_material(Color(0.10, 0.10, 0.11), 0.55, 0.5)

	# Ladder frame rails + cross members.
	for side in [-0.55, 0.55]:
		add_box(body, Vector3(0.09, 0.10, 3.7), Vector3(side, -0.16, 0), frame_mat)
	for zc in [-1.5, -0.5, 0.5, 1.5]:
		add_box(body, Vector3(1.2, 0.08, 0.09), Vector3(0, -0.16, zc), frame_mat)

	# Tub, hood, cowl, grille.
	add_box(body, Vector3(1.62, 0.42, 2.45), Vector3(0, 0.28, -0.55), paint)
	add_box(body, Vector3(1.44, 0.30, 1.28), Vector3(0, 0.36, 1.28), paint)
	add_box(body, Vector3(1.44, 0.06, 1.30), Vector3(0, 0.53, 1.28), paint)
	add_box(body, Vector3(1.30, 0.34, 0.08), Vector3(0, 0.30, 1.94), trim)
	for i in range(7):
		add_box(body, Vector3(0.028, 0.26, 0.03),
			Vector3(-0.45 + 0.15 * float(i), 0.30, 1.99), chrome_material())
	# Round headlights + turn markers.
	for side in [-0.52, 0.52]:
		add_cylinder(body, 0.09, 0.09, 0.05, Vector3(side, 0.34, 1.985),
			paint_material(Color(0.95, 0.93, 0.78), 0.1, 0.2),
			Vector3(PI / 2.0, 0, 0))
	# Front fenders and flares.
	for side in [-0.86, 0.86]:
		add_box(body, Vector3(0.30, 0.07, 1.10),
			Vector3(side, 0.44, WHEELBASE_FRONT), paint)
		add_box(body, Vector3(0.30, 0.07, 1.10),
			Vector3(side, 0.40, WHEELBASE_REAR), paint)

	# Windshield frame + glass.
	add_box(body, Vector3(1.40, 0.07, 0.06), Vector3(0, 1.22, 0.66), paint)
	for side in [-0.68, 0.68]:
		add_box(body, Vector3(0.06, 0.62, 0.06), Vector3(side, 0.92, 0.66),
			paint, Vector3(-0.16, 0, 0))
	add_box(body, Vector3(1.30, 0.52, 0.02), Vector3(0, 0.93, 0.645),
		glass_material(), Vector3(-0.16, 0, 0))

	# Roll cage: uprights, top rails, rear cross.
	var cage := chrome_material()
	for corner in [Vector3(-0.62, 0, 0.55), Vector3(0.62, 0, 0.55),
			Vector3(-0.62, 0, -1.55), Vector3(0.62, 0, -1.55)]:
		add_cylinder(body, 0.035, 0.035, 0.95,
			Vector3(corner.x, 0.95, corner.z), cage)
	for side in [-0.62, 0.62]:
		add_cylinder(body, 0.035, 0.035, 2.16, Vector3(side, 1.42, -0.50),
			cage, Vector3(PI / 2.0, 0, 0))
	add_cylinder(body, 0.035, 0.035, 1.24, Vector3(0, 1.42, -1.55), cage,
		Vector3(0, 0, PI / 2.0))
	add_cylinder(body, 0.035, 0.035, 1.24, Vector3(0, 1.42, 0.55), cage,
		Vector3(0, 0, PI / 2.0))

	# Bench seats, dash, steering column + wheel.
	var seat_mat := paint_material(Color(0.25, 0.20, 0.14), 0.0, 0.9)
	for seat_x in [-0.36, 0.38]:
		add_box(body, Vector3(0.62, 0.12, 0.55), Vector3(seat_x, 0.52, 0.22),
			seat_mat)
		add_box(body, Vector3(0.62, 0.5, 0.10), Vector3(seat_x, 0.80, -0.06),
			seat_mat)
	add_box(body, Vector3(0.62, 0.12, 0.55), Vector3(0, 0.52, -1.05), seat_mat)
	add_box(body, Vector3(0.62, 0.44, 0.10), Vector3(0, 0.76, -1.33), seat_mat)
	add_box(body, Vector3(1.40, 0.24, 0.24), Vector3(0, 0.62, 0.52), trim)
	add_cylinder(body, 0.025, 0.025, 0.34, Vector3(-0.36, 0.78, 0.44), trim,
		Vector3(1.05, 0, 0))
	# A real open rim, hub, and three spokes make steering rotation readable. The
	# paw markers live on the same pivot, so the driver visibly feeds the wheel
	# through a turn instead of holding two fixed points while a solid disc spins.
	_steering_wheel = Node3D.new()
	_steering_wheel.name = "SteeringWheel"
	_steering_wheel.position = Vector3(-0.36, 0.885, 0.36)
	_steering_wheel.rotation = Vector3(1.05, 0, 0)
	body.add_child(_steering_wheel)
	var wheel_mat := paint_material(Color(0.08, 0.08, 0.08), 0.1, 0.7)
	var rim_mesh := TorusMesh.new()
	rim_mesh.inner_radius = 0.142
	rim_mesh.outer_radius = 0.18
	rim_mesh.rings = 18
	rim_mesh.ring_segments = 8
	var rim := MeshInstance3D.new()
	rim.name = "SteeringRim"
	rim.mesh = rim_mesh
	rim.material_override = wheel_mat
	_steering_wheel.add_child(rim)
	add_cylinder(_steering_wheel, 0.045, 0.045, 0.035,
		Vector3.ZERO, trim, Vector3.ZERO, 12)
	for spoke_angle in [0.0, TAU / 3.0, TAU * 2.0 / 3.0]:
		var spoke_root := Node3D.new()
		spoke_root.rotation.y = spoke_angle
		_steering_wheel.add_child(spoke_root)
		add_box(spoke_root, Vector3(0.024, 0.022, 0.145),
			Vector3(0, 0, -0.078), trim)
	# Anatomical left is positive vehicle X. Contacts sit just inside the rim so
	# paw spheres wrap it without hovering beyond the rubber.
	add_rider_target(_steering_wheel, &"hand_left", Vector3(0.145, 0.018, 0))
	add_rider_target(_steering_wheel, &"hand_right", Vector3(-0.145, 0.018, 0))
	add_rider_target(body, &"foot_left", Vector3(-0.22, 0.27, 0.62))
	add_rider_target(body, &"foot_right", Vector3(-0.49, 0.27, 0.62))

	# Bull bar + winch.
	for side in [-0.55, 0.55]:
		add_cylinder(body, 0.04, 0.04, 0.42, Vector3(side, 0.28, 2.12), cage)
	add_cylinder(body, 0.04, 0.04, 1.18, Vector3(0, 0.44, 2.12), cage,
		Vector3(0, 0, PI / 2.0))
	add_cylinder(body, 0.07, 0.07, 0.5, Vector3(0, 0.20, 2.06), trim,
		Vector3(0, 0, PI / 2.0))

	# Snorkel up the right A-pillar.
	add_cylinder(body, 0.05, 0.05, 0.8, Vector3(0.74, 0.62, 1.35), trim,
		Vector3(0.25, 0, 0))
	add_cylinder(body, 0.05, 0.05, 0.62, Vector3(0.72, 1.18, 0.80), trim,
		Vector3(0.9, 0, 0))
	add_cylinder(body, 0.065, 0.05, 0.20, Vector3(0.71, 1.44, 0.62), trim,
		Vector3(0.2, 0, 0))

	# Spare tire + jerry cans on the tailgate.
	var spare := build_knobby_wheel(WHEEL_RADIUS * 0.92, 0.24)
	spare.position = Vector3(0.0, 0.62, -1.92)
	spare.rotation = Vector3(0, PI / 2.0, 0)
	body.add_child(spare)
	for can_x in [-0.52, -0.24]:
		add_box(body, Vector3(0.22, 0.42, 0.14), Vector3(can_x, 0.52, -1.86),
			paint_material(Color(0.55, 0.14, 0.10), 0.2, 0.6))

	# Mirrors + taillights + exhaust.
	for side in [-0.80, 0.80]:
		add_box(body, Vector3(0.05, 0.14, 0.10), Vector3(side, 1.06, 0.62), trim)
	for side in [-0.62, 0.62]:
		_taillights.append(add_box(body, Vector3(0.10, 0.10, 0.04),
			Vector3(side, 0.42, -1.79),
			paint_material(Color(0.6, 0.05, 0.05), 0.1, 0.4)))
	add_cylinder(body, 0.045, 0.045, 0.5, Vector3(0.55, -0.05, -1.7), trim,
		Vector3(0.35, 0, 0))

	# Live axle tubes, differentials, driveshafts, coil springs.
	_front_axle = Node3D.new()
	_front_axle.position = Vector3(0, -0.32, WHEELBASE_FRONT)
	body.add_child(_front_axle)
	_rear_axle = Node3D.new()
	_rear_axle.position = Vector3(0, -0.32, WHEELBASE_REAR)
	body.add_child(_rear_axle)
	for axle in [_front_axle, _rear_axle]:
		var tube := add_cylinder(axle, 0.055, 0.055, TRACK * 2.0 - 0.15,
			Vector3.ZERO, frame_mat, Vector3(0, 0, PI / 2.0))
		tube.name = "Tube"
		add_sphere(axle, 0.14, Vector3(0, 0, 0), frame_mat, 0.9)
	add_cylinder(body, 0.035, 0.035, 1.15, Vector3(0, -0.26, 0.72), trim,
		Vector3(PI / 2.0 - 0.08, 0, 0))
	add_cylinder(body, 0.035, 0.035, 1.12, Vector3(0, -0.26, -0.70), trim,
		Vector3(PI / 2.0 + 0.08, 0, 0))
	for corner in [Vector3(-0.62, -0.10, WHEELBASE_FRONT),
			Vector3(0.62, -0.10, WHEELBASE_FRONT),
			Vector3(-0.62, -0.10, WHEELBASE_REAR),
			Vector3(0.62, -0.10, WHEELBASE_REAR)]:
		add_cylinder(body, 0.075, 0.075, 0.26, corner,
			paint_material(Color(0.72, 0.60, 0.12), 0.4, 0.5), Vector3.ZERO, 8)

	# Headlight cones (auto-on at night).
	for side in [-0.52, 0.52]:
		var lamp := SpotLight3D.new()
		lamp.position = Vector3(side, 0.36, 2.0)
		lamp.rotation_degrees = Vector3(-3, 180, 0)
		lamp.spot_range = 42.0
		lamp.spot_angle = 32.0
		lamp.light_energy = 0.0
		lamp.light_color = Color(1.0, 0.95, 0.82)
		body.add_child(lamp)
		_headlights.append(lamp)

	# Wheels last so their visuals overlay the axle tubes.
	for wheel in wheels:
		var visual := build_knobby_wheel(WHEEL_RADIUS, 0.30)
		body.add_child(visual)
		wheel.visual = visual


func _update_extra_visuals(_dt: float) -> void:
	if _steering_wheel:
		_steering_wheel.rotation = Vector3(1.05, 0, 0)
		# Roughly eighty degrees lock-to-lock keeps both paws attached without an
		# unmodelled hand-over-hand swap while still reading clearly from outside.
		_steering_wheel.rotate_object_local(Vector3.UP, _steer_current * 2.4)
	# Live axles: the tube follows each wheel pair's compression so the
	# suspension articulates visibly over rough ground.
	if _front_axle and wheels.size() >= 4:
		_pose_axle(_front_axle, wheels[0], wheels[1], WHEELBASE_FRONT)
		_pose_axle(_rear_axle, wheels[2], wheels[3], WHEELBASE_REAR)
	var night := false
	if world and world.get("time_of_day_hours") != null:
		var hour: float = world.time_of_day_hours
		night = hour < 6.2 or hour > 18.8
	for lamp in _headlights:
		lamp.light_energy = lerpf(lamp.light_energy,
			5.5 if night and (driver != null or remote_controlled) else 0.0,
			0.2)
	for lamp in _taillights:
		var lit := input_brake > 0.15 and (driver != null or remote_controlled)
		var mat := lamp.material_override as StandardMaterial3D
		if mat:
			mat.emission_enabled = lit
			if lit:
				mat.emission = Color(0.9, 0.06, 0.05)
				mat.emission_energy_multiplier = 2.2


func _pose_axle(axle: Node3D, left: VehicleWheel, right: VehicleWheel,
		z_pos: float) -> void:
	var left_y := -0.16 - (left.travel - left.compression)
	var right_y := -0.16 - (right.travel - right.compression)
	axle.position = Vector3(0, (left_y + right_y) * 0.5, z_pos)
	axle.rotation = Vector3(0, 0, atan2(right_y - left_y, TRACK * 2.0))
