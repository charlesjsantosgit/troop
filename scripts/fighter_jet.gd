class_name FighterJet
extends Vehicle
## Compact single-engine multirole fighter with a genuine aerodynamic model:
## lift and induced drag from angle of attack with a real stall, transonic
## wave drag that caps sea-level speed at ~700 mph, fly-by-wire that banks and
## pulls toward the pilot's camera aim under AoA and G limiters, coordinated
## rudder, retractable tricycle gear on oleo struts, flaps, an airbrake, and
## an afterburner with a spooling turbine. W/S move the throttle setpoint,
## SHIFT lights the burner, A/D roll (nosewheel steering on the ground),
## SPACE is the airbrake, CTRL wheel brakes, G gear, F flaps.

const WING_AREA := 27.9
const WING_SPAN := 9.45
const CHORD := 3.2
const CL_ALPHA := 3.8              # lift slope per radian
const CL0 := 0.06
const ALPHA_STALL := 0.42          # ~24 deg with leading-edge flaps
const ALPHA_LIMIT := 0.38          # FBW limiter
const INDUCED_K := 0.124
const CD0_CLEAN := 0.018
const CD_GEAR := 0.026
const CD_FLAPS := 0.017
const CD_AIRBRAKE := 0.062
const WAVE_DRAG_K := 36.6
const MACH_DRAG_RISE := 0.88
const SOUND_SPEED := 340.0
const G_LIMIT := 9.0
const THRUST_MIL := 76000.0
const THRUST_AB_EXTRA := 52000.0
const THRUST_IDLE := 3800.0

var throttle_setpoint := 0.0       # persistent 0..1 (W raises, S lowers)
var spool := 0.0                   # turbine response toward the setpoint
var afterburner := false
var gear_down := true
var flaps_down := true
var airbrake := 0.0
var alpha := 0.0
var g_load := 1.0
var stalled := false
var _gear_position := 1.0          # 1 = down/locked, 0 = tucked away
var _flap_position := 1.0
var _aim := Vector3.FORWARD
var _wheel_brakes := false
var _roll_override := 0.0
var _stall_beep_t := 0.0
var _was_grounded := true
var _nozzle_flame: MeshInstance3D
var _nozzle_glow: StandardMaterial3D
var _gear_struts: Array[Node3D] = []
var _flap_surfaces: Array[MeshInstance3D] = []
var _airbrake_panel: MeshInstance3D
var _nav_lights: Array[MeshInstance3D] = []
var _nav_blink := 0.0
var _burner_player: AudioStreamPlayer3D
var _wingtip_trails: Array[GPUParticles3D] = []


func _init() -> void:
	kind = Kind.JET
	mass = 9500.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.0, 0.35)
	inertia = Vector3(75674.0, 85552.0, 12875.0)
	drag_area = 0.0                 # aero handled entirely by the flight model
	seat_offset = Vector3(0, 0.72, 3.55)
	fp_camera_offset = Vector3(0, 1.02, 3.9)
	exit_offsets = [Vector3(-2.4, -0.4, 2.0), Vector3(2.4, -0.4, 2.0),
		Vector3(0, -0.4, 6.5)]
	camera_distance = 13.5
	camera_height = 3.4
	camera_bank_factor = 0.34
	speed_for_max_fov = 250.0
	driver_mass = 38.0
	engine_stream = "jet_turbine"
	engine_pitch_base = 0.55
	engine_pitch_span = 1.05
	# The turbine reuses the engine's rpm plumbing as an N1 percentage so the
	# shared audio/HUD paths read sensible values; step() is never called.
	engine.configure({
		"torque_curve": [[0, 0.0], [100, 0.0]],
		"idle_rpm": 62.0, "redline_rpm": 100.0, "limiter_rpm": 104.0,
	})

	# Tricycle gear: nose (steerable) + two mains under the wing roots.
	var nose := VehicleWheel.new()
	nose.configure({
		"local_pos": Vector3(0, -1.05, 4.6),
		"radius": 0.30, "travel": 0.42,
		"spring_rate": 210000.0, "damp_bump": 21000.0, "damp_rebound": 30000.0,
		"steerable": true, "driven": false, "brake_share": 0.0,
		"wheel_mass": 40.0, "mu_long": 0.85, "mu_lat": 0.85,
		"pacejka_b_long": 9.0, "pacejka_b_lat": 8.0,
		"rolling_resistance": 0.009,
	})
	wheels.append(nose)
	for side in [-1.15, 1.15]:
		var main := VehicleWheel.new()
		main.configure({
			"local_pos": Vector3(side, -1.05, -0.55),
			"radius": 0.38, "travel": 0.46,
			"spring_rate": 330000.0, "damp_bump": 34000.0,
			"damp_rebound": 46000.0,
			"steerable": false, "driven": false, "brake_share": 0.5,
			"wheel_mass": 70.0, "mu_long": 0.9, "mu_lat": 0.88,
			"pacejka_b_long": 9.0, "pacejka_b_lat": 8.0,
			"rolling_resistance": 0.009,
		})
		wheels.append(main)
	anti_roll = [[1, 2, 90000.0]]
	max_steer_angle = 0.45
	steer_speed = 2.4


func _ready() -> void:
	super()
	var fuselage_shape := CollisionShape3D.new()
	var fuselage_box := BoxShape3D.new()
	fuselage_box.size = Vector3(1.4, 1.4, 13.6)
	fuselage_shape.shape = fuselage_box
	fuselage_shape.position = Vector3(0, 0.1, 0)
	add_child(fuselage_shape)
	var wing_shape := CollisionShape3D.new()
	var wing_box := BoxShape3D.new()
	wing_box.size = Vector3(WING_SPAN, 0.24, 3.4)
	wing_shape.shape = wing_box
	wing_shape.position = Vector3(0, -0.15, -1.2)
	add_child(wing_shape)
	_build_body()
	_build_burner_audio()


func mount_verb() -> String:
	return "PILOT"


## Ground exits need a stopped jet; airborne the monkey can always bail out.
func allows_exit() -> bool:
	if _wheels_grounded_count() > 0:
		return speed() < 4.5
	return true


func _wheels_grounded_count() -> int:
	var n := 0
	for wheel in wheels:
		if wheel.in_contact:
			n += 1
	return n


func set_driver_view(aim: Vector3, inp: Dictionary) -> void:
	if aim.length_squared() > 0.01:
		_aim = aim.normalized()
	_wheel_brakes = bool(inp.get("crouch_held", false))
	if bool(inp.get("vehicle_gear_just", false)) \
			or (InputMap.has_action("vehicle_gear")
			and Input.is_action_just_pressed("vehicle_gear")):
		_toggle_gear()
	if bool(inp.get("vehicle_flaps_just", false)) \
			or (InputMap.has_action("vehicle_flaps")
			and Input.is_action_just_pressed("vehicle_flaps")):
		_toggle_flaps()


func _toggle_gear() -> void:
	gear_down = not gear_down
	Sfx.play_at("gear_clunk", global_position, -4.0,
		0.7 if gear_down else 0.9)


func _toggle_flaps() -> void:
	flaps_down = not flaps_down
	Sfx.play_at("gear_clunk", global_position, -10.0, 1.3)


func air_density() -> float:
	return 1.225 * exp(-maxf(global_position.y, 0.0) / 8500.0)


func mach() -> float:
	return speed() / SOUND_SPEED


## Full flight-model replacement for the ground-vehicle _simulate.
func _simulate(dt: float) -> void:
	var grounded := _wheels_grounded_count() > 0
	# Throttle setpoint: W raises, S lowers; SHIFT holds the burner lit.
	if driver:
		throttle_setpoint = clampf(throttle_setpoint
			+ (input_throttle - input_brake) * 0.55 * dt, 0.0, 1.0)
		afterburner = input_aux and throttle_setpoint > 0.6
	else:
		throttle_setpoint = 0.0
		afterburner = false
	spool = move_toward(spool, throttle_setpoint, 0.42 * dt)
	engine.rpm = lerpf(62.0, 100.0, spool)
	airbrake = move_toward(airbrake, 1.0 if input_handbrake else 0.0,
		3.2 * dt)
	_gear_position = move_toward(_gear_position, 1.0 if gear_down else 0.0,
		0.7 * dt)
	_flap_position = move_toward(_flap_position, 1.0 if flaps_down else 0.0,
		1.4 * dt)

	var density := air_density()
	var thrust := THRUST_IDLE + THRUST_MIL * spool * pow(density / 1.225, 0.7)
	if afterburner:
		thrust += THRUST_AB_EXTRA * pow(density / 1.225, 0.8)
	apply_central_force(global_basis.z * thrust)

	var v := linear_velocity
	var airspeed := v.length()
	if airspeed > 1.0:
		var local_v := global_basis.inverse() * v
		alpha = atan2(-local_v.y, maxf(local_v.z, 1.0))
		var beta := atan2(local_v.x, maxf(local_v.z, 1.0))
		var q := 0.5 * density * airspeed * airspeed
		# Lift with stall: linear to ALPHA_STALL, then the wing lets go.
		var cl := CL0 + CL_ALPHA * clampf(alpha, -ALPHA_STALL, ALPHA_STALL) \
			+ 0.30 * _flap_position
		stalled = absf(alpha) > ALPHA_STALL and not grounded
		if stalled:
			cl *= clampf(1.0 - (absf(alpha) - ALPHA_STALL) * 2.4, 0.25, 1.0)
		var cd := CD0_CLEAN + CD_GEAR * _gear_position \
			+ CD_FLAPS * _flap_position + CD_AIRBRAKE * airbrake \
			+ INDUCED_K * cl * cl \
			+ WAVE_DRAG_K * pow(maxf(mach() - MACH_DRAG_RISE, 0.0), 2.0)
		var drag_dir := -v.normalized()
		var lift_dir := drag_dir.cross(global_basis.x).normalized()
		if lift_dir.dot(global_basis.y) < 0.0:
			lift_dir = -lift_dir
		var lift := q * WING_AREA * cl
		g_load = lift / (mass * 9.8)
		apply_central_force(lift_dir * lift + drag_dir * q * WING_AREA * cd
			+ global_basis.x * (-1.2 * beta) * q * WING_AREA * 0.35)
		_apply_flight_controls(dt, q, grounded, beta)
	else:
		alpha = 0.0
		g_load = 1.0
		stalled = false

	# Ground handling: gear contact, nosewheel steering, wheel brakes.
	if _gear_position > 0.5:
		_advance_ground_steering(dt, grounded)
		for wheel in wheels:
			wheel.drive_torque = 0.0
			wheel.brake_torque = 24000.0 \
				if (_wheel_brakes or driver == null) else 0.0
			wheel.handbrake = false
		_step_wheels(dt)
		_apply_anti_roll()
	_warn_stall(dt)
	if grounded and not _was_grounded and driver:
		Sfx.play_at("touchdown", global_position, -6.0, 1.0)
	_was_grounded = grounded
	if driver:
		_assist_recovery(dt)


## Fly-by-wire pursuit of the camera aim: roll to put the target in the pull
## plane, then pull AoA toward it — both bounded by the AoA and G limiters
## exactly like a real FBW jet protects itself. A/D add manual roll.
func _apply_flight_controls(dt: float, q: float, grounded: bool,
		beta: float) -> void:
	var authority := clampf(q / 18000.0, 0.0, 1.0)
	if grounded:
		authority *= clampf(speed() / 65.0, 0.0, 1.0)
	var local_aim := global_basis.inverse() * _aim
	_roll_override = move_toward(_roll_override, input_steer, 3.0 * dt)

	var pitch_error := atan2(local_aim.y,
		maxf(local_aim.z, 0.05))
	var roll_error := 0.0
	if not grounded:
		var pull_magnitude := Vector2(local_aim.x, local_aim.y).length()
		if pull_magnitude > 0.04 and absf(pitch_error) < 1.2:
			roll_error = atan2(local_aim.x, maxf(local_aim.y, 0.02)) \
				* clampf(pull_magnitude * 3.0, 0.0, 1.0)
			roll_error = clampf(roll_error, -2.6, 2.6)
	# A/D roll override: positive steer means "left" everywhere else in the
	# game, and roll_error is positive-right, so it enters negated.
	roll_error = clampf(roll_error - _roll_override * 2.2, -3.2, 3.2)

	# Limiters: never command past the AoA limit or the G ceiling.
	var pitch_cmd := clampf(pitch_error * 2.2, -1.0, 1.0)
	if alpha > ALPHA_LIMIT and pitch_cmd > 0.0:
		pitch_cmd = minf(pitch_cmd, (ALPHA_LIMIT - alpha) * 8.0)
	if alpha < -ALPHA_LIMIT * 0.6 and pitch_cmd < 0.0:
		pitch_cmd = maxf(pitch_cmd, (-ALPHA_LIMIT * 0.6 - alpha) * 8.0)
	if g_load > G_LIMIT and pitch_cmd > 0.0:
		pitch_cmd = minf(pitch_cmd, (G_LIMIT - g_load) * 0.5)

	# Torque sign conventions (right-handed, forward = +Z): a rotation about
	# +X drops the nose, +Z rolls left, +Y yaws the nose right. The commands
	# above are in "aim" terms (positive = nose up / bank right), so pitch and
	# roll negate at application; coordination chases beta with +Y.
	var rates := global_basis.inverse() * angular_velocity
	var pitch_torque := (-pitch_cmd * 2.1 - rates.x * 2.9) \
		* q * WING_AREA * CHORD * 0.052 * authority
	var roll_torque := (-clampf(roll_error, -1.0, 1.0) * 2.6 - rates.z * 2.1) \
		* q * WING_AREA * WING_SPAN * 0.012 * authority
	var yaw_torque := (beta * 2.4 - rates.y * 1.8) \
		* q * WING_AREA * WING_SPAN * 0.010 * authority
	apply_torque(global_basis.x * pitch_torque
		+ global_basis.z * roll_torque
		+ global_basis.y * yaw_torque)


func _advance_ground_steering(dt: float, grounded: bool) -> void:
	# Nosewheel authority fades with speed; past ~60 m/s the rudder has it.
	var nose_authority := clampf(1.0 - speed() / 60.0, 0.0, 1.0)
	_steer_target = input_steer * max_steer_angle * nose_authority \
		* (1.0 if grounded else 0.0)
	_steer_current = move_toward(_steer_current, _steer_target,
		steer_speed * max_steer_angle * dt)
	wheels[0].steer_angle = _steer_current


func _warn_stall(dt: float) -> void:
	if stalled and driver:
		_stall_beep_t -= dt
		if _stall_beep_t <= 0.0:
			_stall_beep_t = 0.55
			Sfx.play("stall_beep", -8.0, 1.0)
	else:
		_stall_beep_t = 0.0


func state_aux() -> Vector3:
	var euler := global_basis.get_euler(EULER_ORDER_YXZ)
	return Vector3(euler.x, euler.z, spool)


# ---- construction ----------------------------------------------------------

func _build_body() -> void:
	var body := Node3D.new()
	body.name = "Body"
	add_child(body)
	var skin := paint_material(Color(0.47, 0.50, 0.54), 0.22, 0.62)
	# Thin flight surfaces are visible from both sides; a double-sided copy of
	# the skin keeps every wing, stabilator, and fin solid from any angle.
	var surface_skin := StandardMaterial3D.new()
	surface_skin.albedo_color = Color(0.45, 0.48, 0.52)
	surface_skin.metallic = 0.22
	surface_skin.roughness = 0.62
	surface_skin.cull_mode = BaseMaterial3D.CULL_DISABLED
	var dark := dark_metal_material()

	# Lofted fuselage: elliptical stations nose to nozzle.
	var stations: Array = [
		[7.4, 0.06, 0.06, 0.0], [6.4, 0.22, 0.24, 0.05],
		[5.2, 0.38, 0.42, 0.12], [3.9, 0.52, 0.60, 0.22],
		[2.4, 0.62, 0.72, 0.24], [0.6, 0.70, 0.78, 0.18],
		[-1.4, 0.72, 0.76, 0.12], [-3.4, 0.68, 0.70, 0.08],
		[-5.2, 0.58, 0.58, 0.04], [-6.6, 0.44, 0.44, 0.0],
	]
	var loft := SurfaceTool.new()
	loft.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring_count := 10
	for s in range(stations.size() - 1):
		var a: Array = stations[s]
		var b: Array = stations[s + 1]
		for i in range(ring_count):
			var t0 := TAU * float(i) / ring_count
			var t1 := TAU * float(i + 1) / ring_count
			var a0 := Vector3(cos(t0) * a[1], sin(t0) * a[2] + a[3], a[0])
			var a1 := Vector3(cos(t1) * a[1], sin(t1) * a[2] + a[3], a[0])
			var b0 := Vector3(cos(t0) * b[1], sin(t0) * b[2] + b[3], b[0])
			var b1 := Vector3(cos(t1) * b[1], sin(t1) * b[2] + b[3], b[0])
			for p in [a0, b0, b1, a0, b1, a1]:
				loft.add_vertex(p)
	loft.generate_normals()
	var fuselage := MeshInstance3D.new()
	fuselage.mesh = loft.commit()
	fuselage.material_override = skin
	body.add_child(fuselage)

	# Chin intake.
	add_box(body, Vector3(0.72, 0.5, 1.7), Vector3(0, -0.62, 2.5), dark)
	# Canopy.
	var canopy := add_sphere(body, 0.52, Vector3(0, 0.78, 3.3),
		glass_material(), 0.62)
	canopy.scale = Vector3(0.72, 0.9, 2.1)
	# Cockpit tub + seat + stick so first person has an office.
	add_box(body, Vector3(0.6, 0.30, 1.5), Vector3(0, 0.42, 3.4), dark)
	add_box(body, Vector3(0.42, 0.5, 0.16), Vector3(0, 0.62, 3.05), dark)
	add_cylinder(body, 0.02, 0.02, 0.26, Vector3(0, 0.55, 3.85), dark)
	add_box(body, Vector3(0.5, 0.24, 0.05), Vector3(0, 0.72, 4.15), dark)

	# Main wings: cranked trapezoid panels with thickness.
	for side in [-1.0, 1.0]:
		_add_wing_panel(body, side, Vector3(0.62 * side, -0.12, 0.6),
			Vector3(WING_SPAN * 0.5 * side, -0.12, -1.7), 2.9, 1.15,
			surface_skin)
		# Flaperon surfaces (animate with flaps).
		var flap := add_box(body, Vector3(1.7, 0.07, 0.5),
			Vector3(side * 2.4, -0.14, -2.35), surface_skin)
		_flap_surfaces.append(flap)
		# Wingtip nav lights: red left, green right.
		var nav := add_box(body, Vector3(0.09, 0.06, 0.16),
			Vector3(WING_SPAN * 0.5 * side, -0.10, -1.75),
			paint_material(Color(0.8, 0.1, 0.1) if side < 0
				else Color(0.1, 0.8, 0.2), 0.1, 0.3))
		_nav_lights.append(nav)
		var trail := _make_wingtip_trail()
		trail.position = Vector3(WING_SPAN * 0.5 * side, -0.10, -1.9)
		body.add_child(trail)
		_wingtip_trails.append(trail)

	# Horizontal stabilators + vertical tail + ventral fins.
	for side in [-1.0, 1.0]:
		_add_wing_panel(body, side, Vector3(0.5 * side, 0.02, -4.6),
			Vector3(2.6 * side, 0.02, -6.0), 1.5, 0.7, surface_skin)
		_add_wing_panel(body, side, Vector3(0.3 * side, -0.42, -5.2),
			Vector3(0.9 * side, -1.0, -5.9), 0.9, 0.5, surface_skin)
	var tail := MeshInstance3D.new()
	var tail_loft := SurfaceTool.new()
	tail_loft.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tail_pts := [Vector3(0, 0.5, -3.6), Vector3(0, 2.6, -5.6),
		Vector3(0, 2.6, -6.6), Vector3(0, 0.4, -6.4)]
	for thickness in [-0.05, 0.05]:
		for i in [0, 1, 2, 0, 2, 3]:
			var p: Vector3 = tail_pts[i]
			tail_loft.add_vertex(p + Vector3(thickness, 0, 0))
	tail_loft.generate_normals()
	tail.mesh = tail_loft.commit()
	tail.material_override = surface_skin
	body.add_child(tail)
	# Strobe on the tail tip.
	var strobe := add_box(body, Vector3(0.08, 0.08, 0.08),
		Vector3(0, 2.62, -6.1), paint_material(Color(1, 1, 1), 0.1, 0.2))
	_nav_lights.append(strobe)

	# Nozzle + afterburner flame cone.
	add_cylinder(body, 0.40, 0.50, 0.7, Vector3(0, 0.0, -6.9), dark,
		Vector3(PI / 2.0, 0, 0), 12)
	_nozzle_glow = StandardMaterial3D.new()
	_nozzle_glow.albedo_color = Color(1.0, 0.62, 0.2, 0.85)
	_nozzle_glow.emission_enabled = true
	_nozzle_glow.emission = Color(1.0, 0.55, 0.15)
	_nozzle_glow.emission_energy_multiplier = 0.0
	_nozzle_glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_nozzle_glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var flame_mesh := CylinderMesh.new()
	flame_mesh.top_radius = 0.36
	flame_mesh.bottom_radius = 0.10
	flame_mesh.height = 2.6
	flame_mesh.radial_segments = 10
	_nozzle_flame = MeshInstance3D.new()
	_nozzle_flame.mesh = flame_mesh
	_nozzle_flame.rotation = Vector3(PI / 2.0, 0, 0)
	_nozzle_flame.position = Vector3(0, 0, -8.4)
	_nozzle_flame.material_override = _nozzle_glow
	_nozzle_flame.scale = Vector3(1, 0.05, 1)
	body.add_child(_nozzle_flame)

	# Airbrake panel on the spine.
	_airbrake_panel = add_box(body, Vector3(0.8, 0.05, 1.1),
		Vector3(0, 0.72, -2.6), skin)

	# Landing gear: struts with wheels; whole assemblies fold on retract.
	for i in range(wheels.size()):
		var wheel := wheels[i]
		var strut := Node3D.new()
		strut.position = wheel.local_pos + Vector3(0, 0.5, 0)
		body.add_child(strut)
		add_cylinder(strut, 0.06, 0.05, 1.0, Vector3(0, -0.5, 0), dark)
		add_cylinder(strut, 0.035, 0.035, 0.5, Vector3(0, -1.05, 0),
			chrome_material())
		var wheel_visual := build_knobby_wheel(wheel.radius, 0.20, 10,
			Color(0.35, 0.35, 0.36))
		wheel_visual.position = Vector3(0, -1.3, 0)
		strut.add_child(wheel_visual)
		wheel.visual = null
		_gear_struts.append(strut)


func _add_wing_panel(parent: Node3D, _side: float, root: Vector3,
		tip: Vector3, root_chord: float, tip_chord: float,
		material: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r0 := root + Vector3(0, 0, root_chord * 0.5)
	var r1 := root + Vector3(0, 0, -root_chord * 0.5)
	var t0 := tip + Vector3(0, 0, tip_chord * 0.5)
	var t1 := tip + Vector3(0, 0, -tip_chord * 0.5)
	for dy in [-0.08, 0.08]:
		var off := Vector3(0, dy, 0)
		for p in [r0 + off, t0 + off, t1 + off, r0 + off, t1 + off, r1 + off]:
			st.add_vertex(p)
	# Leading/trailing edge skins.
	for pair in [[r0, t0], [t1, r1]]:
		var a: Vector3 = pair[0]
		var b: Vector3 = pair[1]
		for p in [a + Vector3(0, -0.08, 0), b + Vector3(0, -0.08, 0),
				b + Vector3(0, 0.08, 0), a + Vector3(0, -0.08, 0),
				b + Vector3(0, 0.08, 0), a + Vector3(0, 0.08, 0)]:
			st.add_vertex(p)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = material
	parent.add_child(mi)


func _make_wingtip_trail() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 60
	p.lifetime = 0.9
	p.local_coords = false
	p.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0, -1)
	pm.spread = 2.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.0
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	p.process_material = pm
	var mesh := SphereMesh.new()
	mesh.radius = 0.16
	mesh.height = 0.32
	mesh.radial_segments = 5
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.92, 0.95, 1.0, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	p.draw_pass_1 = mesh
	return p


func _build_burner_audio() -> void:
	_burner_player = AudioStreamPlayer3D.new()
	_burner_player.stream = Sfx.streams.get("jet_burner")
	_burner_player.bus = &"SFX"
	_burner_player.max_distance = 240.0
	_burner_player.unit_size = 12.0
	_burner_player.volume_db = -60.0
	_burner_player.attenuation_model = \
		AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC
	add_child(_burner_player)
	if _burner_player.stream:
		_burner_player.play()


func _update_extra_visuals(dt: float) -> void:
	# Gear fold: struts swing up into the belly as _gear_position drops.
	for strut in _gear_struts:
		strut.rotation = Vector3((1.0 - _gear_position) * 1.9, 0, 0)
		strut.scale = Vector3.ONE * clampf(_gear_position + 0.02, 0.02, 1.0)
	_gear_struts[0].rotation.y = _steer_current
	for flap in _flap_surfaces:
		flap.rotation = Vector3(_flap_position * 0.5, 0, 0)
	if _airbrake_panel:
		_airbrake_panel.rotation = Vector3(-airbrake * 0.9, 0, 0)
	# Nozzle flame length follows spool; blinding in afterburner.
	if _nozzle_flame:
		var flame := clampf(spool * 0.35
			+ (1.2 if afterburner else 0.0), 0.0, 1.4)
		_nozzle_flame.scale = Vector3(1, maxf(flame, 0.03), 1)
		_nozzle_glow.emission_energy_multiplier = flame * 7.0
		_nozzle_glow.albedo_color.a = clampf(flame, 0.0, 0.9)
	# Wingtip vortices condense under hard G or deep AoA.
	var trail_on := speed() > 60.0 and (g_load > 5.0 or absf(alpha) > 0.24)
	for trail in _wingtip_trails:
		trail.emitting = trail_on
	# Nav lights blink; the strobe double-flashes.
	_nav_blink = fmod(_nav_blink + dt, 1.2)
	var lit := _nav_blink < 0.08 or (_nav_blink > 0.18 and _nav_blink < 0.26)
	for i in range(_nav_lights.size()):
		var mat := _nav_lights[i].material_override as StandardMaterial3D
		if mat:
			mat.emission_enabled = lit or i < 2
			mat.emission = mat.albedo_color
			mat.emission_energy_multiplier = 3.0 if lit else 0.8


func _update_audio(dt: float, rpm_frac: float, load: float) -> void:
	super(dt, rpm_frac, load)
	if _burner_player:
		_burner_player.volume_db = lerpf(_burner_player.volume_db,
			-4.0 if afterburner else -60.0, 1.0 - exp(-6.0 * dt))
		_burner_player.pitch_scale = 0.9 + spool * 0.3
