class_name FighterJet
extends Vehicle
## Compact single-engine multirole fighter with a genuine aerodynamic model:
## lift and induced drag from angle of attack with a real stall, transonic
## wave drag that caps sea-level speed at ~700 mph, fly-by-wire that banks and
## pulls toward the pilot's camera aim under AoA and G limiters, coordinated
## rudder, retractable tricycle gear on oleo struts, flaps, an airbrake, and
## an afterburner with a spooling turbine. W/S move the throttle setpoint,
## UP/DOWN command nose up/down, SHIFT lights the burner, A/D roll (nosewheel
## steering on the ground), SPACE is the airbrake, CTRL wheel brakes, G gear,
## F flaps. Mouse pursuit remains available for precision flying.

const WING_AREA := 27.9
const WING_SPAN := 9.45
const CHORD := 3.2
const CL_ALPHA := 3.8              # lift slope per radian
const CL0 := 0.06
const CL_FLAPS := 0.40             # takeoff/landing high-lift increment
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
const THRUST_MIL := 84000.0
const THRUST_AB_EXTRA := 44000.0
const THRUST_IDLE := 3800.0
const TAKEOFF_PITCH_LIMIT := 0.24       # ~14° protected rotation
const ASSISTED_CLIMB_PITCH := 0.24      # Up holds a useful, non-stalling climb
const ASSISTED_DESCENT_PITCH := -0.16   # Down lowers the nose without a dive
const CONTROL_AUTHORITY_Q := 3500.0     # Pa for full control-surface response
const NOZZLE_LIP_Z := -7.25
const BURNER_CORE_LENGTH := 2.25
# The replicated aux vector has no spare component. Values 0..1 remain normal
# spool for backwards compatibility; +2 carries the independent burner bit.
const REMOTE_AFTERBURNER_OFFSET := 2.0

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
var _pitch_input := 0.0             # arrows: +1 nose up, -1 nose down
var _wheel_brakes := false
var _roll_override := 0.0
var _stall_beep_t := 0.0
var _was_grounded := true
var _nozzle_flame: MeshInstance3D
var _nozzle_glow: StandardMaterial3D
var _gear_assemblies: Array[Dictionary] = []
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
	# The pilot rig sits low in the ejection seat; its head remains beneath the
	# framed bubble while the 0.50 m seated pelvis rests in the cushion.
	rider_root_offset = Vector3(0, 0.10, 3.34)
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
	# The existing cone is the luminous burner core; this outlet adds only the
	# translucent high-speed heat plume from the real nozzle lip.
	add_exhaust(Vector3(0, 0, NOZZLE_LIP_Z), Vector3(0, 0, -1),
		VehicleExhaust.Profile.JET)


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
	_pitch_input = clampf(float(inp.get("vehicle_pitch", 0.0)), -1.0, 1.0)
	_wheel_brakes = bool(inp.get("crouch_held", false))
	if bool(inp.get("vehicle_gear_just", false)):
		_toggle_gear()
	if bool(inp.get("vehicle_flaps_just", false)):
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


func exhaust_activity(profile_kind: int) -> float:
	if remote_controlled:
		return VehicleExhaust.sampled_intensity(profile_kind, true,
			_remote_rpm, 0.60, exhaust_boost())
	# Let a bailed-out turbine wind down instead of snapping its plume off while
	# the physical spool and existing nozzle flame are still decaying.
	return VehicleExhaust.sampled_intensity(profile_kind,
		driver != null or spool > 0.015, spool, spool, exhaust_boost())


func exhaust_boost() -> float:
	return 1.0 if afterburner else 0.0


## Full flight-model replacement for the ground-vehicle _simulate.
func _simulate(dt: float) -> void:
	# Throttle setpoint: W raises, S lowers; SHIFT holds the burner lit.
	if driver:
		throttle_setpoint = clampf(throttle_setpoint
			+ (input_throttle - input_brake) * 0.55 * dt, 0.0, 1.0)
		afterburner = input_aux and throttle_setpoint > 0.6
	else:
		throttle_setpoint = 0.0
		afterburner = false
		_pitch_input = 0.0
	spool = move_toward(spool, throttle_setpoint, 0.42 * dt)
	engine.rpm = lerpf(62.0, 100.0, spool)
	airbrake = move_toward(airbrake, 1.0 if input_handbrake else 0.0,
		3.2 * dt)
	_gear_position = move_toward(_gear_position, 1.0 if gear_down else 0.0,
		0.7 * dt)
	_flap_position = move_toward(_flap_position, 1.0 if flaps_down else 0.0,
		1.4 * dt)

	# Raycast tires only exist once the oleos are almost down and locked. The old
	# half-travel cut-over left the final grounded state latched forever after a
	# takeoff retraction, so flight controls and exit logic could still believe a
	# clean jet was sitting on the runway.
	var gear_supports_weight := _gear_position > 0.94
	var grounded := gear_supports_weight and _wheels_grounded_count() > 0
	if gear_supports_weight:
		_advance_ground_steering(dt, grounded)
		for wheel in wheels:
			wheel.drive_torque = 0.0
			wheel.brake_torque = 24000.0 \
				if (_wheel_brakes or driver == null) else 0.0
			wheel.handbrake = false
		_step_wheels(dt)
		_apply_anti_roll()
		grounded = _wheels_grounded_count() > 0
	else:
		_clear_gear_contacts()

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
			+ CL_FLAPS * _flap_position
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
	if grounded:
		_apply_ground_run_stability()
	elif driver and absf(_pitch_input) > 0.04:
		# Easy keyboard flight keeps the selected compass heading as well as the
		# requested pitch. Mouse yaw and A/D still deliberately change that heading.
		_apply_heading_hold(10.0, 5.0)

	_warn_stall(dt)
	if grounded and not _was_grounded and driver:
		Sfx.play_at("touchdown", global_position, -6.0, 1.0)
	_was_grounded = grounded
	if driver:
		_assist_recovery(dt)


## A tricycle-gear jet naturally weathercocks down the runway and its wide main
## gear resists rolling over. Raycast contact noise lacks some of that passive
## geometry, so provide the same bounded outcome: follow the pilot's flat aim,
## damp yaw, and keep the wings level until rotation. Manual A/D progressively
## releases heading hold, preserving deliberate taxi steering.
func _apply_ground_run_stability() -> void:
	_apply_heading_hold(18.0, 7.0)
	var forward_axis := global_basis.z.normalized()
	var level_axis := global_basis.y.normalized().cross(Vector3.UP)
	var roll_error := level_axis.dot(forward_axis)
	var roll_rate := angular_velocity.dot(forward_axis)
	apply_torque(forward_axis * mass * (roll_error * 9.8 - roll_rate * 4.0))


func _apply_heading_hold(error_gain: float, damping_gain: float) -> void:
	var flat_forward := Vector3(global_basis.z.x, 0.0, global_basis.z.z)
	var flat_aim := Vector3(_aim.x, 0.0, _aim.z)
	if flat_forward.length_squared() > 0.001 \
			and flat_aim.length_squared() > 0.001:
		flat_forward = flat_forward.normalized()
		flat_aim = flat_aim.normalized()
		var heading_error := flat_forward.signed_angle_to(flat_aim, Vector3.UP)
		var heading_hold := 1.0 - absf(input_steer)
		var yaw_rate := angular_velocity.dot(Vector3.UP)
		apply_torque(Vector3.UP * mass * (heading_error * error_gain * heading_hold
			- yaw_rate * damping_gain))


## Fly-by-wire pursuit of the camera aim: roll to put the target in the pull
## plane, then pull AoA toward it — both bounded by the AoA and G limiters
## exactly like a real FBW jet protects itself. A/D add manual roll.
func _apply_flight_controls(dt: float, q: float, grounded: bool,
		beta: float) -> void:
	# Control-surface moment already scales with q below. A low dynamic-pressure
	# response curve keeps taxi inputs gentle without the old q-squared suppression
	# that made the elevator nearly powerless throughout a normal takeoff roll.
	var authority := clampf(q / CONTROL_AUTHORITY_Q, 0.0, 1.0)
	if grounded:
		authority *= clampf(speed() / 65.0, 0.0, 1.0)
	var local_aim := global_basis.inverse() * _aim
	_roll_override = move_toward(_roll_override, input_steer, 3.0 * dt)

	var pitch_error := atan2(local_aim.y,
		maxf(local_aim.z, 0.05))
	var roll_error := 0.0
	if not grounded and absf(_pitch_input) > 0.04:
		# Arrow-pitch mode is intentionally self-contained: hold the wings level
		# unless A/D is also pressed instead of letting a stale mouse aim bank the
		# aircraft underneath a keyboard-commanded climb.
		roll_error = clampf(
			global_basis.get_euler(EULER_ORDER_YXZ).z * 1.4, -1.0, 1.0)
	elif not grounded:
		var pull_magnitude := Vector2(local_aim.x, local_aim.y).length()
		if pull_magnitude > 0.04 and absf(pitch_error) < 1.2:
			roll_error = atan2(local_aim.x, maxf(local_aim.y, 0.02)) \
				* clampf(pull_magnitude * 3.0, 0.0, 1.0)
			roll_error = clampf(roll_error, -2.6, 2.6)
	# A/D roll override: positive steer means "left" everywhere else in the
	# game, and roll_error is positive-right, so it enters negated.
	roll_error = clampf(roll_error - _roll_override * 2.2, -3.2, 3.2)

	# Limiters: never command past the AoA limit or the G ceiling.
	# Arrow pitch is direct and predictable even when the chase camera is looking
	# elsewhere. Releasing both arrows hands control back to mouse pursuit.
	var pitch_cmd := clampf(pitch_error * 2.2, -1.0, 1.0)
	if absf(_pitch_input) > 0.04:
		if grounded:
			pitch_cmd = _pitch_input
		else:
			# Keyboard pitch is an assisted attitude command. A raw held elevator
			# input kept pulling until the jet exchanged all of its airspeed for a
			# stall; Up/Down now settle at useful climb/descent attitudes and are
			# therefore comfortable to hold. Mouse pursuit remains the unrestricted
			# precision control for aerobatics.
			var aircraft_pitch := asin(clampf(global_basis.z.y, -1.0, 1.0))
			var target_pitch := ASSISTED_CLIMB_PITCH \
				if _pitch_input > 0.0 else ASSISTED_DESCENT_PITCH
			pitch_cmd = clampf((target_pitch - aircraft_pitch) * 5.0,
				-1.0, 1.0) * absf(_pitch_input)
	if grounded and pitch_cmd > 0.0:
		var aircraft_pitch := asin(clampf(global_basis.z.y, -1.0, 1.0))
		pitch_cmd = minf(pitch_cmd,
			clampf((TAKEOFF_PITCH_LIMIT - aircraft_pitch) * 7.0, 0.0, 1.0))
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
	# On the runway the stabilators must rotate the airframe about the main gear,
	# not merely its free-flight centre of mass. Use their realistic high-deflection
	# takeoff authority until the wheels unload, with extra rate damping so holding
	# Up produces one smooth rotation instead of a pitch jerk. Airborne response
	# remains deliberately softer for easy formation and landing control.
	var pitch_gain := 14.0 if grounded else 2.1
	var pitch_damping := 8.0 if grounded else 2.9
	var pitch_torque := (-pitch_cmd * pitch_gain - rates.x * pitch_damping) \
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
	var encoded_spool := spool + (REMOTE_AFTERBURNER_OFFSET if afterburner else 0.0)
	return Vector3(euler.x, euler.z, encoded_spool)


## Decode turbine spool and the independent afterburner bit before the base
## interpolation path stores its normalized remote RPM. This keeps remote
## particle velocity, nozzle core, burner audio, and engine pitch in sync.
func apply_remote_state(pos: Vector3, yaw: float, aux: Vector3,
		vel: Vector3) -> void:
	var remote_afterburner := aux.z >= REMOTE_AFTERBURNER_OFFSET
	var remote_spool := aux.z - REMOTE_AFTERBURNER_OFFSET \
		if remote_afterburner else aux.z
	spool = clampf(remote_spool, 0.0, 1.0)
	afterburner = remote_afterburner
	engine.rpm = lerpf(62.0, 100.0, spool)
	super(pos, yaw, Vector3(aux.x, aux.y, spool), vel)


# ---- construction ----------------------------------------------------------

## SurfaceTool follows Godot's clockwise front-face convention. Return a
## triangle whose generated normal points toward the supplied exterior hint,
## regardless of which side of a mirrored aircraft part produced the points.
func _clockwise_triangle(a: Vector3, b: Vector3, c: Vector3,
		outward: Vector3) -> Array[Vector3]:
	var clockwise_normal := (c - a).cross(b - a)
	if clockwise_normal.dot(outward) >= 0.0:
		return [a, b, c]
	return [a, c, b]


## The four inputs trace a quad perimeter. Both emitted triangles use the same
## outward-aware winding, preventing top/bottom and left/right mirrored panels
## from silently receiving opposite normals.
func _clockwise_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		outward: Vector3) -> Array[Vector3]:
	var clockwise_normal := (c - a).cross(b - a)
	if clockwise_normal.dot(outward) >= 0.0:
		return [a, b, c, a, c, d]
	return [a, d, c, a, c, b]


## The radome is part of the single lofted shell. Vertex tint preserves its
## dark break without laying a second cylinder over the same nose polygons,
## which previously added z-fighting on top of the inverted shell normals.
func _fuselage_tint(z: float) -> Color:
	var radome_tint := Color(0.24 / 0.47, 0.27 / 0.50, 0.29 / 0.54)
	return Color.WHITE.lerp(radome_tint, smoothstep(5.60, 6.48, z))


func _build_body() -> void:
	var body := Node3D.new()
	body.name = "Body"
	add_child(body)
	var skin := paint_material(Color(0.47, 0.50, 0.54), 0.22, 0.62)
	var fuselage_skin := skin.duplicate() as StandardMaterial3D
	fuselage_skin.vertex_color_use_as_albedo = true
	# Every flight surface below is a closed prism. Back-face culling now exposes
	# a winding regression instead of drawing the inward face and lighting it as
	# though the aircraft skin were inside out.
	var surface_skin := StandardMaterial3D.new()
	surface_skin.albedo_color = Color(0.45, 0.48, 0.52)
	surface_skin.metallic = 0.22
	surface_skin.roughness = 0.62
	surface_skin.cull_mode = BaseMaterial3D.CULL_BACK
	var dark := dark_metal_material()
	var cockpit_trim := paint_material(Color(0.075, 0.085, 0.095), 0.35, 0.52)

	# Lofted fuselage: a capped, indexed 18-sided shell. The original ten-sided
	# open loft read as a long triangular needle in profile; the denser stations
	# preserve a crisp radome while blending the cockpit shoulders and tail pipe.
	var stations: Array = [
		[7.6, 0.035, 0.035, 0.02], [7.18, 0.11, 0.12, 0.04],
		[6.48, 0.24, 0.25, 0.07], [5.60, 0.38, 0.40, 0.12],
		[4.72, 0.49, 0.52, 0.18], [3.62, 0.59, 0.66, 0.22],
		[2.28, 0.66, 0.74, 0.21], [0.55, 0.72, 0.80, 0.15],
		[-1.35, 0.74, 0.77, 0.10], [-3.30, 0.68, 0.70, 0.06],
		[-5.05, 0.58, 0.58, 0.03], [-6.45, 0.44, 0.44, 0.0],
		[-6.90, 0.38, 0.38, 0.0],
	]
	var loft := SurfaceTool.new()
	loft.begin(Mesh.PRIMITIVE_TRIANGLES)
	loft.set_smooth_group(0)
	var ring_count := 18
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
			var middle_angle := (t0 + t1) * 0.5
			var outward := Vector3(cos(middle_angle), sin(middle_angle), 0.0)
			for p in _clockwise_quad(a0, b0, b1, a1, outward):
				loft.set_color(_fuselage_tint(p.z))
				loft.add_vertex(p)
	# Close both ends so a low camera never sees through the radome or nozzle.
	loft.set_smooth_group(-1)
	for end_index in [0, stations.size() - 1]:
		var station: Array = stations[end_index]
		var center := Vector3(0, station[3], station[0])
		for i in range(ring_count):
			var t0 := TAU * float(i) / ring_count
			var t1 := TAU * float(i + 1) / ring_count
			var p0 := Vector3(cos(t0) * station[1],
				sin(t0) * station[2] + station[3], station[0])
			var p1 := Vector3(cos(t1) * station[1],
				sin(t1) * station[2] + station[3], station[0])
			var outward := Vector3(0.0, 0.0, 1.0) \
				if end_index == 0 else Vector3(0.0, 0.0, -1.0)
			for p in _clockwise_triangle(center, p0, p1, outward):
				loft.set_color(_fuselage_tint(p.z))
				loft.add_vertex(p)
	loft.index()
	loft.generate_normals()
	var fuselage := MeshInstance3D.new()
	fuselage.name = "FuselageShell"
	fuselage.mesh = loft.commit()
	fuselage.material_override = fuselage_skin
	body.add_child(fuselage)

	# Blended shoulder chines keep the nose readable without turning the whole
	# forward fuselage into one uninterrupted grey spike.
	for side in [-1.0, 1.0]:
		_add_wing_panel(body, side, Vector3(0.48 * side, 0.03, 3.45),
			Vector3(1.36 * side, -0.04, 1.55), 0.72, 0.28, surface_skin)

	# Recessed chin intake with a metal lip and a dark duct, replacing the solid
	# rectangular block that previously hung below the nose.
	add_box(body, Vector3(0.68, 0.30, 1.08), Vector3(0, -0.55, 2.58), dark,
		Vector3(-0.05, 0, 0))
	add_box(body, Vector3(0.78, 0.055, 1.18), Vector3(0, -0.37, 2.58), skin,
		Vector3(-0.05, 0, 0))
	for side in [-1.0, 1.0]:
		add_box(body, Vector3(0.055, 0.34, 1.14),
			Vector3(side * 0.39, -0.52, 2.58), skin,
			Vector3(-0.05, 0, side * 0.035))
	add_box(body, Vector3(0.58, 0.18, 0.12), Vector3(0, -0.54, 2.02),
		paint_material(Color(0.025, 0.03, 0.035), 0.0, 0.95))

	# Cockpit tub, ejection seat, side consoles, stick, throttle, and instrument
	# coaming. These shapes remain visible in cockpit view and give the pilot
	# authored contact landmarks for the rider-pose pass.
	add_box(body, Vector3(0.68, 0.24, 1.56), Vector3(0, 0.43, 3.42), cockpit_trim)
	add_box(body, Vector3(0.40, 0.12, 0.48), Vector3(0, 0.57, 3.35), dark)
	add_box(body, Vector3(0.46, 0.58, 0.15), Vector3(0, 0.78, 2.98), dark,
		Vector3(-0.12, 0, 0))
	add_box(body, Vector3(0.34, 0.13, 0.18), Vector3(0, 1.07, 2.92), dark)
	for side in [-1.0, 1.0]:
		add_box(body, Vector3(0.12, 0.16, 1.12),
			Vector3(side * 0.31, 0.61, 3.42), cockpit_trim)
	add_cylinder(body, 0.022, 0.026, 0.30, Vector3(-0.13, 0.64, 3.63),
		chrome_material(), Vector3(0.16, 0, 0), 10)
	var stick_grip := add_box(body, Vector3(0.10, 0.08, 0.08),
		Vector3(-0.13, 0.80, 3.60), dark)
	add_cylinder(body, 0.018, 0.018, 0.22, Vector3(0.27, 0.68, 3.34),
		chrome_material(), Vector3(0.18, 0, 0), 8)
	var throttle_grip := add_box(body, Vector3(0.09, 0.07, 0.10),
		Vector3(0.27, 0.78, 3.34), dark)
	add_box(body, Vector3(0.56, 0.22, 0.08), Vector3(0, 0.78, 4.13),
		cockpit_trim, Vector3(-0.18, 0, 0))
	# Pedals and exact reachable control contacts for the shared rider IK. Facing
	# +Z makes anatomical left +X, hence throttle/left pedal use positive X.
	for side in [-1.0, 1.0]:
		var pedal := add_box(body, Vector3(0.13, 0.055, 0.16),
			Vector3(side * 0.16, 0.36, 3.72), cockpit_trim,
			Vector3(-0.30, 0, 0))
		add_rider_target(pedal,
			&"foot_left" if side > 0.0 else &"foot_right", Vector3.ZERO)
	add_rider_target(throttle_grip, &"hand_left", Vector3.ZERO)
	add_rider_target(stick_grip, &"hand_right", Vector3.ZERO)

	# A longer, higher bubble with distinct windscreen/bow/rear frames. The glass
	# still uses the shared transparent material, but its silhouette now encloses
	# a believable ejection-seat office instead of reading as a dark shoebox.
	var canopy := add_sphere(body, 0.56, Vector3(0, 0.91, 3.32),
		glass_material(), 0.95)
	canopy.scale = Vector3(0.78, 1.0, 2.18)
	add_box(body, Vector3(0.88, 0.055, 2.26), Vector3(0, 0.48, 3.32),
		cockpit_trim)
	for frame_z in [2.35, 3.02, 4.35]:
		add_cylinder(body, 0.026, 0.026, 0.88,
			Vector3(0, 0.86 if frame_z == 3.02 else 0.72, frame_z),
			cockpit_trim, Vector3(0, 0, PI / 2.0), 8)
	for side in [-1.0, 1.0]:
		add_box(body, Vector3(0.035, 0.055, 2.22),
			Vector3(side * 0.43, 0.67, 3.32), cockpit_trim,
			Vector3(0.03 * side, 0, 0))

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
	tail.name = "VerticalTailShell"
	var tail_loft := SurfaceTool.new()
	tail_loft.begin(Mesh.PRIMITIVE_TRIANGLES)
	tail_loft.set_smooth_group(-1)
	var tail_pts := [Vector3(0, 0.5, -3.6), Vector3(0, 2.6, -5.6),
		Vector3(0, 2.6, -6.6), Vector3(0, 0.4, -6.4)]
	for thickness in [-0.07, 0.07]:
		var outward := Vector3(signf(thickness), 0.0, 0.0)
		for indices in [[0, 1, 2], [0, 2, 3]]:
			var a: Vector3 = tail_pts[indices[0]] + Vector3(thickness, 0, 0)
			var b: Vector3 = tail_pts[indices[1]] + Vector3(thickness, 0, 0)
			var c: Vector3 = tail_pts[indices[2]] + Vector3(thickness, 0, 0)
			for p in _clockwise_triangle(a, b, c, outward):
				tail_loft.add_vertex(p)
	var tail_center := Vector3.ZERO
	for point: Vector3 in tail_pts:
		tail_center += point
	tail_center /= float(tail_pts.size())
	for edge_index in range(tail_pts.size()):
		var edge_next := (edge_index + 1) % tail_pts.size()
		var a: Vector3 = tail_pts[edge_index] + Vector3(-0.07, 0, 0)
		var b: Vector3 = tail_pts[edge_next] + Vector3(-0.07, 0, 0)
		var c: Vector3 = tail_pts[edge_next] + Vector3(0.07, 0, 0)
		var d: Vector3 = tail_pts[edge_index] + Vector3(0.07, 0, 0)
		var outward: Vector3 = (tail_pts[edge_index] + tail_pts[edge_next]) * 0.5 \
			- tail_center
		outward.x = 0.0
		for p in _clockwise_quad(a, b, c, d, outward):
			tail_loft.add_vertex(p)
	tail_loft.index()
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
	# A real turbine plume is brightest at the nozzle but never an opaque orange
	# rod. Additive, uncapped geometry gives a thin blue-white core whose warmer
	# afterburner colour can still be read through the surrounding heat plume.
	_nozzle_glow.albedo_color = Color(0.50, 0.72, 1.0, 0.0)
	_nozzle_glow.emission_enabled = true
	_nozzle_glow.emission = Color(0.38, 0.68, 1.0)
	_nozzle_glow.emission_energy_multiplier = 0.0
	_nozzle_glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_nozzle_glow.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_nozzle_glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_nozzle_glow.cull_mode = BaseMaterial3D.CULL_DISABLED
	var flame_mesh := CylinderMesh.new()
	flame_mesh.top_radius = 0.29
	flame_mesh.bottom_radius = 0.055
	flame_mesh.height = BURNER_CORE_LENGTH
	flame_mesh.radial_segments = 16
	flame_mesh.cap_top = false
	flame_mesh.cap_bottom = false
	_nozzle_flame = MeshInstance3D.new()
	_nozzle_flame.mesh = flame_mesh
	_nozzle_flame.rotation = Vector3(PI / 2.0, 0, 0)
	_nozzle_flame.position = Vector3(0, 0,
		NOZZLE_LIP_Z - BURNER_CORE_LENGTH * 0.05 * 0.5)
	_nozzle_flame.material_override = _nozzle_glow
	_nozzle_flame.scale = Vector3(1, 0.05, 1)
	body.add_child(_nozzle_flame)

	# Airbrake panel on the spine.
	_airbrake_panel = add_box(body, Vector3(0.8, 0.05, 1.1),
		Vector3(0, 0.72, -2.6), skin)

	# Landing gear: each visual wheel uses the exact raycast-wheel centre when
	# locked down. Oleo members bridge the physical attachment and centre, then
	# fold into authored bays during retraction. Smooth toroidal aircraft tires
	# replace the oversized knobby off-road wheels.
	for i in range(wheels.size()):
		var wheel := wheels[i]
		var gear_root := Node3D.new()
		gear_root.name = "NoseGear" if i == 0 else "MainGear%s" % i
		body.add_child(gear_root)
		var outer := add_cylinder(gear_root, 0.062 if i == 0 else 0.078,
			0.056 if i == 0 else 0.070, 1.0, Vector3.ZERO, dark,
			Vector3.ZERO, 12)
		var inner := add_cylinder(gear_root, 0.034 if i == 0 else 0.043,
			0.034 if i == 0 else 0.043, 1.0, Vector3.ZERO,
			chrome_material(), Vector3.ZERO, 12)
		var wheel_mount := Node3D.new()
		wheel_mount.name = "WheelMount"
		gear_root.add_child(wheel_mount)
		var wheel_visual := _build_aircraft_wheel(wheel.radius,
			0.16 if i == 0 else 0.22)
		wheel_mount.add_child(wheel_visual)
		var door_pos := Vector3(0, -0.66, 4.10) if i == 0 else Vector3(
			wheel.local_pos.x * 0.72, -0.61, -0.58)
		var door_size := Vector3(0.46, 0.035, 1.18) if i == 0 \
			else Vector3(0.58, 0.035, 1.05)
		# Door meshes are offset from an actual inboard edge hinge. Rotating a
		# centered box made each panel hang like a detached airbrake because half of
		# it crossed the bay instead of swinging cleanly away from the wheel path.
		var door_side := signf(wheel.local_pos.x)
		var door_hinge := Node3D.new()
		door_hinge.name = "NoseDoorHinge" if i == 0 else "MainDoorHinge%s" % i
		if i == 0:
			door_hinge.position = door_pos - Vector3(door_size.x * 0.5, 0, 0)
			gear_root.add_child(door_hinge)
			add_box(door_hinge, door_size,
				Vector3(door_size.x * 0.5, 0, 0), surface_skin)
		else:
			door_hinge.position = door_pos \
				- Vector3(door_side * door_size.x * 0.5, 0, 0)
			gear_root.add_child(door_hinge)
			add_box(door_hinge, door_size,
				Vector3(door_side * door_size.x * 0.5, 0, 0), surface_skin)
		add_cylinder(gear_root, 0.024, 0.024, door_size.z * 0.88,
			door_hinge.position, dark, Vector3(PI / 2.0, 0, 0), 10)
		var retracted := Vector3(0, -0.46, 3.55) if i == 0 else Vector3(
			wheel.local_pos.x * 0.34, -0.48, -0.62)
		_gear_assemblies.append({
			"wheel_index": i,
			"outer": outer,
			"inner": inner,
			"wheel_mount": wheel_mount,
			"wheel_visual": wheel_visual,
			"door_hinge": door_hinge,
			"door_open_angle": -1.12 if i == 0 else -door_side * 1.22,
			"retracted": retracted,
		})
		wheel.visual = null


func _add_wing_panel(parent: Node3D, _side: float, root: Vector3,
		tip: Vector3, root_chord: float, tip_chord: float,
		material: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	var r0 := root + Vector3(0, 0, root_chord * 0.5)
	var r1 := root + Vector3(0, 0, -root_chord * 0.5)
	var t0 := tip + Vector3(0, 0, tip_chord * 0.5)
	var t1 := tip + Vector3(0, 0, -tip_chord * 0.5)
	var down := Vector3(0, -0.08, 0)
	var up := Vector3(0, 0.08, 0)
	for p in _clockwise_quad(r0 + down, t0 + down, t1 + down,
			r1 + down, Vector3.DOWN):
		st.add_vertex(p)
	for p in _clockwise_quad(r0 + up, t0 + up, t1 + up,
			r1 + up, Vector3.UP):
		st.add_vertex(p)
	# Leading/trailing edge skins.
	for p in _clockwise_quad(r0 + down, t0 + down, t0 + up, r0 + up,
			Vector3(0, 0, 1)):
		st.add_vertex(p)
	for p in _clockwise_quad(r1 + down, t1 + down, t1 + up, r1 + up,
			Vector3(0, 0, -1)):
		st.add_vertex(p)
	# Root and tip caps stop the panels reading as open sheets at grazing angles.
	for p in _clockwise_quad(r1 + down, r0 + down, r0 + up, r1 + up,
			Vector3(-_side, 0, 0)):
		st.add_vertex(p)
	for p in _clockwise_quad(t0 + down, t1 + down, t1 + up, t0 + up,
			Vector3(_side, 0, 0)):
		st.add_vertex(p)
	st.index()
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "FlightSurface"
	mi.mesh = st.commit()
	mi.material_override = material
	parent.add_child(mi)


func _build_aircraft_wheel(radius: float, width: float) -> Node3D:
	var root := Node3D.new()
	var tire_mesh := TorusMesh.new()
	tire_mesh.outer_radius = radius
	tire_mesh.inner_radius = radius * 0.56
	tire_mesh.rings = 20
	tire_mesh.ring_segments = 8
	var tire := MeshInstance3D.new()
	tire.mesh = tire_mesh
	tire.rotation = Vector3(0, 0, PI / 2.0)
	# Torus section width follows radius; trim its wheel-axis depth to the real
	# tire width while keeping the round loaded-aircraft sidewall silhouette.
	tire.scale.y = width / maxf(radius * 0.44, 0.01)
	tire.material_override = rubber_material()
	root.add_child(tire)
	var hub_mesh := CylinderMesh.new()
	hub_mesh.top_radius = radius * 0.34
	hub_mesh.bottom_radius = radius * 0.34
	hub_mesh.height = width * 0.78
	hub_mesh.radial_segments = 14
	var hub := MeshInstance3D.new()
	hub.mesh = hub_mesh
	hub.rotation = Vector3(0, 0, PI / 2.0)
	hub.material_override = paint_material(Color(0.52, 0.54, 0.56), 0.72, 0.30)
	root.add_child(hub)
	var axle := add_cylinder(root, radius * 0.09, radius * 0.09, width * 1.06,
		Vector3.ZERO, dark_metal_material(), Vector3(0, 0, PI / 2.0), 10)
	axle.name = "Axle"
	return root


func _pose_gear_member(member: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var delta := b - a
	var length := delta.length()
	if length < 0.001:
		member.visible = false
		return
	member.visible = true
	var y_axis := delta / length
	var reference := Vector3.RIGHT
	if absf(reference.dot(y_axis)) > 0.92:
		reference = Vector3.FORWARD
	var x_axis := (reference - y_axis * reference.dot(y_axis)).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	member.transform = Transform3D(Basis(x_axis, y_axis, z_axis).scaled(
		Vector3(1.0, length, 1.0)), (a + b) * 0.5)


func _clear_gear_contacts() -> void:
	for wheel in wheels:
		wheel.in_contact = false
		wheel.load = 0.0
		wheel.slip_ratio = 0.0
		wheel.slip_angle = 0.0


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
	# Exact deployed wheel centres come from the same raycast suspension used by
	# physics. Retraction follows a short arcing path into each bay while the oleo
	# members continuously bridge the moving hinge and wheel hub.
	var deploy := smoothstep(0.0, 1.0, _gear_position)
	# Doors lead the extension and lag the retraction: wheels begin moving only
	# after the bays have opened, and are fully home before the panels close.
	var wheel_deploy := smoothstep(0.14, 1.0, deploy)
	var door_open := smoothstep(0.0, 0.24, deploy)
	for assembly in _gear_assemblies:
		var wheel_index := int(assembly["wheel_index"])
		var wheel: VehicleWheel = wheels[wheel_index]
		var wheel_mount := assembly["wheel_mount"] as Node3D
		var wheel_visual := assembly["wheel_visual"] as Node3D
		var outer := assembly["outer"] as MeshInstance3D
		var inner := assembly["inner"] as MeshInstance3D
		var door_hinge := assembly["door_hinge"] as Node3D
		var deployed_center := wheel.local_pos \
			- Vector3(0, wheel.travel - wheel.compression, 0)
		var retracted: Vector3 = assembly["retracted"]
		var wheel_center := retracted.lerp(deployed_center, wheel_deploy)
		wheel_center.y += sin(wheel_deploy * PI) * 0.18
		wheel_mount.position = wheel_center
		var side := signf(wheel.local_pos.x)
		if wheel_index == 0:
			wheel_mount.rotation = Vector3(-(1.0 - wheel_deploy) * 1.35,
				_steer_current * wheel_deploy, 0)
		else:
			wheel_mount.rotation = Vector3(0, 0,
				(1.0 - wheel_deploy) * side * 1.45)
		wheel_visual.rotation = Vector3(wheel.spin_angle, 0, 0)

		var deployed_attach := wheel.local_pos
		var bay_attach := Vector3(0, -0.48, 4.12) if wheel_index == 0 \
			else Vector3(wheel.local_pos.x * 0.44, -0.48, -0.58)
		var visual_attach := bay_attach.lerp(deployed_attach, wheel_deploy)
		var oleo_split := visual_attach.lerp(wheel_center, 0.58)
		_pose_gear_member(outer, visual_attach, oleo_split +
			(wheel_center - visual_attach).normalized() * 0.08)
		_pose_gear_member(inner, visual_attach.lerp(wheel_center, 0.42), wheel_center)

		door_hinge.rotation = Vector3(0, 0,
			float(assembly["door_open_angle"]) * door_open)
	for flap in _flap_surfaces:
		flap.rotation = Vector3(_flap_position * 0.5, 0, 0)
	if _airbrake_panel:
		_airbrake_panel.rotation = Vector3(-airbrake * 0.9, 0, 0)
	# Nozzle-core length follows spool. Its alpha deliberately remains low even
	# in afterburner; emission and the surrounding particle plume carry the heat
	# without turning it into a solid arcade-style cone.
	if _nozzle_flame:
		var burner := 1.0 if afterburner else 0.0
		var flame := clampf(spool * 0.24 + burner * 0.86, 0.0, 1.10)
		var width := lerpf(0.72, 1.0, clampf(spool + burner * 0.35, 0.0, 1.0))
		var length_scale := maxf(flame, 0.025)
		_nozzle_flame.scale = Vector3(width, length_scale, width)
		# Scaling a centred cylinder would make its forward edge wander or even
		# detach. Re-anchor that edge to the physical nozzle lip every frame.
		_nozzle_flame.position.z = NOZZLE_LIP_Z \
			- BURNER_CORE_LENGTH * length_scale * 0.5
		_nozzle_glow.emission = Color(0.38, 0.68, 1.0).lerp(
			Color(1.0, 0.56, 0.22), burner * 0.28)
		_nozzle_glow.emission_energy_multiplier = 0.45 + flame * 1.65
		_nozzle_glow.albedo_color = Color(0.50, 0.72, 1.0,
			clampf(spool * 0.025 + burner * 0.065, 0.0, 0.09))
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
