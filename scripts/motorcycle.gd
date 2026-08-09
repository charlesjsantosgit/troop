class_name Motorcycle
extends Vehicle
## 650-class dual-sport thumper: long-travel telescopic forks and a rear
## monoshock swingarm (both visually stroke with the suspension), a real lean
## model — the rider banks the machine to atan(v²/Rg) exactly like physical
## counter-steering resolves, camber thrust carves the corner, and pushing
## past the grip circle lowsides and throws the monkey off — plus wheelies
## under power, stoppies under the front brake, and a genuine 110 mph flat
## out in a tuck. One big single cylinder barks underneath it all.

## The motorcycle is authored at human dual-sport dimensions, then reduced to
## the monkey cast's scale as one coherent machine. Keeping the physics wheels,
## collision hull, controls, and visible model on this same factor prevents the
## rider from reading like a toy perched on an oversized motorcycle.
const MODEL_SCALE := 0.86
const AUTHORED_WHEELBASE_FRONT := 0.76
const AUTHORED_WHEELBASE_REAR := -0.73
const AUTHORED_FRONT_RADIUS := 0.34
const AUTHORED_REAR_RADIUS := 0.315
const WHEELBASE_FRONT := AUTHORED_WHEELBASE_FRONT * MODEL_SCALE
const WHEELBASE_REAR := AUTHORED_WHEELBASE_REAR * MODEL_SCALE
const FRONT_RADIUS := AUTHORED_FRONT_RADIUS * MODEL_SCALE
const REAR_RADIUS := AUTHORED_REAR_RADIUS * MODEL_SCALE
const SUSPENSION_TRAVEL := 0.224
const SUSPENSION_ATTACH_Y := -0.013
const RAKE := 0.45                    # steering-head angle, rad (~26 deg)
const MAX_LEAN := 0.83                # ~48 deg on knobbies
const LOWSIDE_LEAN_ERROR := 0.55
const WHEELIE_DURATION := 4.80
const WHEELIE_COOLDOWN := 1.25
const WHEELIE_STEER_SCALE := 0.08
const WHEELIE_MIN_SPEED := 2.5
const WHEELIE_MAX_SPEED := 38.0
const WHEELIE_LOOP_THROTTLE := 0.86
const WHEELIE_OVERPOWER_GRACE := 1.45
const WHEELIE_OVERPOWER_FULL := 2.70
const MAX_ASSISTED_LEAN := 0.66       # ~38°: quick without a snap lowside

var lean_target := 0.0
var _lean_integral := 0.0
var _tuck := 0.0                      # 0 upright .. 1 full tuck (SHIFT)
var _lowside_t := 0.0
var wheelie_remaining := 0.0
var _wheelie_elapsed := 0.0
var _wheelie_cooldown := 0.0
var _wheelie_crash_emitted := false
var _wheelie_overpower := 0.0
var _steer_head: Node3D
var _front_fork_tubes: Array[MeshInstance3D] = []
var _front_sliders: Array[MeshInstance3D] = []
var _front_wheel_visual: Node3D
var _front_fender: Node3D
var _swingarm: Node3D
var _rear_wheel_visual: Node3D
var _handlebar: Node3D
var _headlight: SpotLight3D
var _shock_spring: MeshInstance3D
var _body_visual: Node3D
var _kickstand_engaged := false


func _init() -> void:
	kind = Kind.BIKE
	mass = 170.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.02, 0.02)
	drag_area = 0.55
	max_steer_angle = 0.62
	steer_speed = 4.5
	seat_offset = Vector3(0, 0.535, -0.155)
	# The monkey itself remains full size. Lower its rig root by the model-scale
	# delta so the same 0.48 m seated pelvis rests in the resized saddle instead
	# of floating above it; retain the original root-to-head camera separation.
	rider_root_offset = Vector3(0, 0.115, -0.103)
	fp_camera_offset = Vector3(0, 0.965, -0.083)
	exit_offsets = [Vector3(-1.1, 0.3, 0), Vector3(1.1, 0.3, 0),
		Vector3(0, 0.5, -1.8)]
	camera_distance = 4.6
	camera_height = 2.0
	camera_chase_pitch = -0.23
	camera_bank_factor = 0.42
	speed_for_max_fov = 44.0
	driver_mass = 38.0
	# A tucked monkey carries most of its mass near the saddle/tank, not at the
	# upright torso height used by the enclosed vehicles.
	driver_center_offset = Vector3(0, 0.38, 0.04)
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
		# Smaller tires need a proportionally taller final ratio to preserve the
		# existing road-speed/RPM relationship and familiar 110 mph performance.
		"final_drive": 5.86 * MODEL_SCALE,
		"driveline_efficiency": 0.90,
		"shift_time": 0.16,
		# The big single still slows on a closed throttle, but not so abruptly that
		# releasing W removes the momentum (and therefore the steering/lean response)
		# in the middle of a corner.
		"engine_brake_coefficient": 0.78,
		"clutch_engage_rpm": 2200.0,
	})

	var front := VehicleWheel.new()
	front.configure({
		"local_pos": Vector3(0, SUSPENSION_ATTACH_Y, WHEELBASE_FRONT),
		"radius": FRONT_RADIUS,
		"travel": SUSPENSION_TRAVEL,
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
		"local_pos": Vector3(0, SUSPENSION_ATTACH_Y, WHEELBASE_REAR),
		"radius": REAR_RADIUS,
		"travel": SUSPENSION_TRAVEL,
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
	body_box.size = Vector3(0.42, 0.72, 1.82) * MODEL_SCALE
	body_shape.shape = body_box
	body_shape.position = Vector3(0, 0.42, 0) * MODEL_SCALE
	add_child(body_shape)
	_build_body()
	# Physical root-space outlet just beyond the scaled muffler's aft cap.
	add_exhaust(Vector3(0.14, 0.604, -0.91) * MODEL_SCALE,
		Vector3(0, 0, -1), VehicleExhaust.Profile.BIKE)


func mount_verb() -> String:
	return "RIDE"


func ejects_rider_on_crash() -> bool:
	return true


func begin_drive(player: Node3D) -> void:
	# A frozen parked body represents the three-point support of both tires and
	# the sidestand. Retract it before Vehicle applies the rider payload so the
	# chassis is fully physical again from the first driven tick.
	_kickstand_engaged = false
	_wheelie_crash_emitted = false
	super(player)


func end_drive() -> Vector3:
	# A grounded, upright rider can place the bike directly on its kickstand.
	# Requiring both wheel rays prevents Ctrl-wheelie or low-speed hop dismounts
	# from freezing a machine in midair or balanced on the rear contact alone.
	var support_up := _supported_ground_normal()
	var can_set_stand := speed() < 4.5 and _both_wheels_near_ground() \
		and global_basis.y.dot(support_up) > 0.80
	var exit_position := super()
	_reset_special_physics_state()
	if can_set_stand:
		_engage_kickstand()
	return exit_position


func apply_rest_state(pos: Vector3, yaw: float, pitch: float,
		roll: float) -> void:
	# Rest transforms are authoritative on late-joining peers. Reconstruct the
	# same physical stand state instead of letting a replicated parked bike fall
	# over as soon as its kinematic driver claim is released.
	_kickstand_engaged = false
	freeze = false
	super(pos, yaw, pitch, roll)
	var support_up := _supported_ground_normal()
	if global_basis.y.dot(support_up) > 0.88 and _both_wheels_near_ground():
		_engage_kickstand()


func _engage_kickstand() -> void:
	global_basis = kickstand_basis(global_basis.z, _supported_ground_normal())
	# Keep at least one real tire ray in contact after rotating about the chassis
	# origin. Without this small ground fit, a near-limit suspension ray can sit
	# a few millimetres high and make a parked bike visibly hover.
	var closest_clearance := INF
	for wheel in wheels:
		var attach := global_position + global_basis * wheel.local_pos
		var rest := wheel.radius + wheel.travel
		var probe: Dictionary = probe_ground(attach, rest + 0.08)
		if is_finite(float(probe.distance)):
			closest_clearance = minf(closest_clearance,
				float(probe.distance) - rest)
	if is_finite(closest_clearance):
		# Fit both hovering and shallow post-rotation penetration. Terrain-aligned
		# pitch makes the correction small; the bound prevents malformed geometry
		# from ever teleporting a parked bike vertically.
		var fit := clampf(closest_clearance + 0.004, -0.12, 0.12)
		global_position -= global_basis.y * fit
	_refresh_kickstand_contacts()
	_update_visuals(0.0)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_kickstand_engaged = true
	# The authored stand is the third support point that a two-ray motorcycle
	# cannot otherwise express. Freeze only this verified, walking-pace parked
	# state; begin_drive always retracts it before accepting controls.
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	freeze = true
	sleeping = true
	reset_physics_interpolation()


## Terrain-aligned stand frame. The forward axis is projected into the supported
## road plane, preserving hill pitch/cross-slope instead of snapping to world
## level, then the authored 0.12 rad sidestand lean is applied around that axis.
func kickstand_basis(forward_hint: Vector3, support_normal: Vector3) -> Basis:
	var up := support_normal.normalized()
	if up.length_squared() < 0.5:
		up = Vector3.UP
	var forward := forward_hint - up * forward_hint.dot(up)
	if forward.length_squared() < 0.001:
		forward = global_basis.z - up * global_basis.z.dot(up)
	if forward.length_squared() < 0.001:
		forward = Vector3.FORWARD - up * Vector3.FORWARD.dot(up)
	forward = forward.normalized()
	var right := up.cross(forward).normalized()
	var aligned := Basis(right, up, forward).orthonormalized()
	return aligned.rotated(forward, -0.12).orthonormalized()


func _supported_ground_normal() -> Vector3:
	var normal_sum := Vector3.ZERO
	var samples := 0
	for wheel in wheels:
		var attach := global_position + global_basis * wheel.local_pos
		var reach := wheel.radius + wheel.travel + 0.10
		var probe: Dictionary = probe_ground(attach, reach)
		if is_finite(float(probe.distance)):
			normal_sum += (probe.normal as Vector3).normalized()
			samples += 1
	if samples > 0 and normal_sum.length_squared() > 0.01:
		return normal_sum.normalized()
	return terrain_normal_at(global_position.x, global_position.z)


func _refresh_kickstand_contacts() -> void:
	for wheel in wheels:
		var attach := global_position + global_basis * wheel.local_pos
		var rest := wheel.radius + wheel.travel
		var probe: Dictionary = probe_ground(attach, rest + 0.02)
		wheel.in_contact = float(probe.distance) < rest
		if not wheel.in_contact:
			continue
		wheel.contact_normal = probe.normal
		wheel.compression = clampf(rest - float(probe.distance), 0.0,
			wheel.travel)
		wheel.compression_velocity = 0.0
		wheel.contact_point = attach - global_basis.y \
			* (rest - wheel.compression)
		wheel.spin = 0.0
		wheel.load = wheel.spring_rate * wheel.compression


func _both_wheels_near_ground() -> bool:
	# Suspension contact can flicker for a frame while the rider's weight is
	# removed. Probe the same physical/streaming-safe ground under both hubs and
	# allow only a small tire-reach tolerance. A raised wheelie front remains far
	# outside this envelope, so it cannot be mistaken for a parked stance.
	for wheel in wheels:
		var attach := global_position + global_basis * wheel.local_pos
		var reach := wheel.radius + wheel.travel
		var probe: Dictionary = probe_ground(attach, reach + 0.08)
		if float(probe.distance) > reach + 0.08:
			return false
	return true


func _total_brake_torque() -> float:
	return 1350.0


func set_driver_view(_aim: Vector3, inp: Dictionary) -> void:
	# Ctrl is contextual: crouch/dive on foot, jet wheel brakes in the fighter,
	# and a one-shot balance-point assist on the motorcycle.
	if bool(inp.get("crouch_just", false)) and _wheelie_cooldown <= 0.0 \
			and driver != null and forward_speed() >= WHEELIE_MIN_SPEED \
			and forward_speed() <= WHEELIE_MAX_SPEED \
			and wheels[1].in_contact \
			and global_basis.y.y > 0.75 \
			and global_basis.get_euler(EULER_ORDER_YXZ).x > -0.12:
		wheelie_remaining = WHEELIE_DURATION
		_wheelie_elapsed = 0.0
		_wheelie_overpower = 0.0
		_wheelie_cooldown = WHEELIE_COOLDOWN
		_wheelie_crash_emitted = false


func wheelie_active() -> bool:
	return wheelie_remaining > 0.0


func _reset_special_physics_state() -> void:
	wheelie_remaining = 0.0
	_wheelie_elapsed = 0.0
	_wheelie_cooldown = 0.0
	_wheelie_overpower = 0.0
	_lowside_t = 0.0
	_wheelie_crash_emitted = false
	lean_target = 0.0
	_lean_integral = 0.0


func _advance_steering(dt: float) -> void:
	# A motorcycle needs only a few degrees of bar angle once moving; the prior
	# car-oriented 9.5/v lock could rotate the bike more than 90° in one second.
	# This speed curve stays responsive while producing a readable, controllable
	# arc instead of an instant pivot.
	var v := absf(forward_speed())
	var speed_lock := clampf(1.35 / maxf(v, 2.0), 0.02, 1.0)
	_steer_target = input_steer * max_steer_angle * speed_lock
	_steer_current = move_toward(_steer_current, _steer_target,
		steer_speed * max_steer_angle * dt)
	for wheel in wheels:
		if wheel.steerable:
			wheel.steer_angle = _steer_current


func _simulate(dt: float) -> void:
	_tuck = move_toward(_tuck, 1.0 if input_aux else 0.0, 3.0 * dt)
	drag_area = lerpf(0.55, 0.40, _tuck)
	_wheelie_cooldown = maxf(_wheelie_cooldown - dt, 0.0)
	var unscaled_steer := input_steer
	if wheelie_active():
		# A raised front contact cannot generate normal steering force. Keep a small
		# amount of rider body English, but prevent sharp airborne direction changes.
		input_steer *= WHEELIE_STEER_SCALE
	# Paddle backward at a stop: no reverse gear on a bike, just monkey feet.
	if driver and input_brake > 0.4 and speed() < 0.9 \
			and _wheels_grounded() == 2:
		apply_central_force(-global_basis.z * 620.0)
	super(dt)
	input_steer = unscaled_steer
	_advance_wheelie(dt)
	_advance_lean(dt)
	_check_wheelie_crash()
	_check_lowside(dt)


func anti_loop_active() -> bool:
	# Kept as a compatibility probe for older diagnostics. Wheelies are no longer
	# protected by a hidden throttle cut: pushing beyond the balance point can now
	# loop the bike and crash the rider, as the visible physics suggests.
	return false


func _wheels_grounded() -> int:
	var n := 0
	for wheel in wheels:
		if wheel.in_contact:
			n += 1
	return n


func _near_ground_for_feet() -> bool:
	# Wheel-ray contact can flicker while the loaded suspension crosses static
	# sag. At walking pace the monkey's feet still reach the real surface below
	# the chassis, so keep balance authority through that brief gap. This affects
	# only an occupied slow bike; it never freezes or parks an airborne body.
	if _wheels_grounded() > 0:
		return true
	if _space:
		var query := PhysicsRayQueryParameters3D.create(
			global_position + Vector3.UP * 0.15,
			global_position + Vector3.DOWN * 0.95)
		query.exclude = _exclude
		if not _space.intersect_ray(query).is_empty():
			return true
	var terrain_gap := global_position.y \
		- terrain_height_at(global_position.x, global_position.z)
	return terrain_gap >= -0.1 and terrain_gap <= 0.85


## Requested nose-up angle for the live throttle. A binary keyboard W first
## reaches a high but controllable balance point; only holding maximum power well
## beyond the grace window progressively asks for a loop. Analog throttle still
## scales the safe height below that point.
func wheelie_target_nose_angle(throttle: float,
		overpower_seconds := 0.0) -> float:
	var pedal := clampf(throttle, 0.0, 1.0)
	if pedal <= 0.035:
		return 0.0
	var safe_mix := smoothstep(0.035, WHEELIE_LOOP_THROTTLE, pedal)
	var target := lerpf(0.18, 0.80, safe_mix)
	if pedal > WHEELIE_LOOP_THROTTLE:
		var full_power_mix := smoothstep(WHEELIE_LOOP_THROTTLE, 1.0, pedal)
		var sustained_mix := smoothstep(WHEELIE_OVERPOWER_GRACE,
			WHEELIE_OVERPOWER_FULL, overpower_seconds)
		target = lerpf(0.80, 1.78, full_power_mix * sustained_mix)
	return target


## A sustained PD attitude assist represents the monkey shifting rearward and
## feeding power to the balance point. Height follows actual throttle instead of
## a canned animation: rolling off asks for level immediately and keeps the
## controller alive until the front tire has settled back onto the ground.
func _advance_wheelie(dt: float) -> void:
	if not wheelie_active() or driver == null:
		wheelie_remaining = 0.0 if driver == null else wheelie_remaining
		return
	_wheelie_elapsed = minf(_wheelie_elapsed + dt, WHEELIE_DURATION)
	wheelie_remaining = maxf(WHEELIE_DURATION - _wheelie_elapsed, 0.0)
	if input_throttle > WHEELIE_LOOP_THROTTLE:
		_wheelie_overpower = minf(_wheelie_overpower + dt,
			WHEELIE_OVERPOWER_FULL + 0.5)
	else:
		_wheelie_overpower = maxf(_wheelie_overpower - dt * 2.5, 0.0)
	var target_nose_up := wheelie_target_nose_angle(input_throttle,
		_wheelie_overpower) \
		* smoothstep(0.0, 0.20, _wheelie_elapsed)
	# Once the maximum assist window expires it behaves exactly like rolling off:
	# gravity and the attitude controller place the front tire down instead of
	# abruptly abandoning a still-raised chassis.
	if _wheelie_elapsed >= WHEELIE_DURATION:
		target_nose_up = 0.0
		wheelie_remaining = 0.001
	# atan2(forward-up, chassis-up) remains continuous beyond 90 degrees. Euler X
	# wraps at the vertical and made the old controller mathematically incapable of
	# completing a genuine backwards loop even when its target was past vertical.
	var nose_angle := atan2(global_basis.z.dot(Vector3.UP),
		global_basis.y.dot(Vector3.UP))
	var nose_rate := -angular_velocity.dot(global_basis.x)
	var command := clampf((target_nose_up - nose_angle) * 26.0
		- nose_rate * 6.0, -11.0, 11.0)
	apply_torque(-global_basis.x * command * mass)
	if target_nose_up <= 0.001 and wheels[0].in_contact \
			and absf(nose_angle) < 0.13 and absf(nose_rate) < 0.7:
		wheelie_remaining = 0.0


## A crash is declared only after the chassis has physically rotated behind the
## balance point, not merely because the front tire is high. The dedicated fatal
## path then ejects and kills the rider even during revive protection, while the
## existing replicated player/vehicle release plumbing carries that state online.
func _check_wheelie_crash() -> bool:
	if not wheelie_active() or driver == null or _wheelie_crash_emitted \
			or wheels[0].in_contact:
		return false
	var nose_angle := atan2(global_basis.z.dot(Vector3.UP),
		global_basis.y.dot(Vector3.UP))
	var true_backward_loop := nose_angle > deg_to_rad(92.0) \
		and absf(global_basis.x.dot(Vector3.UP)) < 0.62
	if not true_backward_loop:
		return false
	_wheelie_crash_emitted = true
	driver_fatal_crash.emit()
	return true


## The rider's balance. A bike stays up because steering places the contact
## line back under the mass; we model the OUTCOME of that loop: a PD roll
## torque toward the physically correct lean for the current corner, plus an
## upright "feet down" stabilizer at walking pace. Pitch gets rider damping so
## power wheelies rise and settle instead of looping.
func _advance_lean(dt: float) -> void:
	var v := forward_speed()
	var grounded := _wheels_grounded() > 0
	var balance_supported := grounded \
		or (driver != null and absf(v) < 2.5 and _near_ground_for_feet())
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
	# With local +Z forward, positive steer is vehicle-left but a left bank is
	# negative Z roll. The old same-sign lean banked away from its tire path,
	# making A/D feel inverted and cancelling much of the corner force.
	var desired_lean := clampf(-atan(v * v * curvature / 9.8),
		-MAX_ASSISTED_LEAN, MAX_ASSISTED_LEAN) if absf(v) > 0.5 else 0.0
	if wheelie_active():
		desired_lean *= WHEELIE_STEER_SCALE
	# A rider first counter-steers and then settles into the bank; an immediate
	# 48-degree command made a full-speed A/D tap behave like a crash impulse.
	lean_target = move_toward(lean_target, desired_lean, 0.90 * dt)
	# At walking pace the rider simply holds it upright with their feet.
	var authority := lerpf(26.0, 15.0,
		clampf(absf(v) / 14.0, 0.0, 1.0))
	if absf(v) < 2.5:
		lean_target = 0.0
		authority = 44.0
	if not balance_supported:
		authority = 4.0   # airborne body English only
	var error := angle_difference(roll, lean_target)
	var roll_rate := angular_velocity.dot(global_basis.z)
	var roll_command := clampf(error * authority - roll_rate * authority
		* 0.32, -10.0, 10.0)
	apply_torque(global_basis.z * roll_command * mass * 0.62)
	# Camber thrust: leaned motorcycle tires push the bike around the corner
	# even before slip angles build. Both contacts, proportional to load.
	if grounded:
		for wheel in wheels:
			if not wheel.in_contact:
				continue
			# Camber thrust acts in the road plane. Using the raw rolled chassis X
			# axis injected a downward force while banked and duplicated almost a
			# full tire's grip outside the friction ellipse.
			var side := global_basis.x - wheel.contact_normal \
				* global_basis.x.dot(wheel.contact_normal)
			if side.length_squared() < 0.001:
				continue
			side = side.normalized()
			var wheelie_corner_scale := WHEELIE_STEER_SCALE \
				if wheelie_active() else 1.0
			# Bottom-out loads can spike for one integration step. Tire cornering
			# already observes that transient load; cap the authored camber assist
			# to keep a hard landing from becoming an unbounded sideways launch.
			var supported_load := minf(wheel.load, mass * 9.8 * 0.85)
			apply_force(side * -sin(roll) * supported_load * 0.20 \
				* wheelie_corner_scale,
				wheel.contact_point - global_position)
	# Rider pitch damping: soften wheelie/stoppie rotation like a real body
	# hanging off the pegs, and close the throttle past the balance point.
	var pitch_rate := angular_velocity.dot(global_basis.x)
	var pitch_damping := 0.32 if wheelie_active() else 0.85
	apply_torque(-global_basis.x * clampf(pitch_rate, -8.0, 8.0)
		* mass * pitch_damping)


## Sliding out both contact patches while leaned past recovery is a lowside:
## the machine goes down and the rider tumbles off (Vehicle.driver_impact →
## the player ejects and ragdolls the damage).
func _check_lowside(dt: float) -> void:
	if driver == null or _wheels_grounded() == 0 or speed() < 6.0:
		_lowside_t = 0.0
		return
	var roll := global_basis.get_euler(EULER_ORDER_YXZ).z
	var sliding := true
	for wheel in wheels:
		if wheel.in_contact and absf(wheel.slip_angle) < 0.34:
			sliding = false
	if sliding and absf(angle_difference(roll, lean_target)) \
			> LOWSIDE_LEAN_ERROR:
		_lowside_t += dt
	else:
		_lowside_t = maxf(_lowside_t - dt * 2.0, 0.0)
	# Require a sustained loss of both contact patches. Short slip spikes while
	# braking or initiating a turn now feel lively without unfairly ejecting the
	# rider; a committed slide still produces the physical lowside.
	if _lowside_t > 0.65:
		_lowside_t = 0.0
		driver_impact.emit(16.0)
		linear_velocity *= 0.82


func _build_body() -> void:
	_body_visual = Node3D.new()
	var body := _body_visual
	body.name = "Body"
	body.scale = Vector3.ONE * MODEL_SCALE
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
	# Stable reference for proportion/ride-height regressions. It follows the
	# same uniformly scaled model root as the actual saddle surface.
	var saddle_top := Node3D.new()
	saddle_top.name = "SaddleTop"
	saddle_top.position = Vector3(0, 0.69, -0.30)
	body.add_child(saddle_top)
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
		var tube := add_cylinder(_steer_head, 0.022, 0.022, 1.0,
			Vector3.ZERO, alloy)
		_front_fork_tubes.append(tube)
		var slider := add_cylinder(_steer_head, 0.028, 0.028, 1.0,
			Vector3.ZERO, frame_mat)
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
	# Anatomical left is +X while the monkey faces vehicle-forward (+Z). Keeping
	# these markers on the steering node makes both paws follow the real bars.
	add_rider_target(_handlebar, &"hand_left", Vector3(0.30, 0.03, -0.02))
	add_rider_target(_handlebar, &"hand_right", Vector3(-0.30, 0.03, -0.02))
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
	body.add_child(_front_fender)
	add_box(_front_fender, Vector3(0.22, 0.03, 0.55), Vector3.ZERO, paint,
		Vector3(0.1, 0, 0))
	_front_wheel_visual = build_knobby_wheel(AUTHORED_FRONT_RADIUS, 0.115, 16,
		Color(0.2, 0.2, 0.22))
	body.add_child(_front_wheel_visual)
	wheels[0].visual = null   # posed manually along the fork axis

	# Swingarm, monoshock, chain run, rear wheel.
	_swingarm = Node3D.new()
	_swingarm.position = Vector3(0, 0.30, -0.16)
	body.add_child(_swingarm)
	for side in [-0.10, 0.10]:
		add_box(_swingarm, Vector3(0.035, 0.05, 0.62),
			Vector3(side, 0, -0.28), frame_mat)
	_rear_wheel_visual = build_knobby_wheel(AUTHORED_REAR_RADIUS, 0.13, 16,
		Color(0.2, 0.2, 0.22))
	body.add_child(_rear_wheel_visual)
	add_cylinder(_swingarm, 0.055, 0.055, 0.03,
		Vector3(0.085, 0, -0.57), alloy, Vector3(0, 0, PI / 2.0))
	# Real peg geometry and matching rider contacts. Both are within 0.47 m of
	# the seated hips, leaving IK room for suspension pitch and rider lean.
	for side in [-1.0, 1.0]:
		var peg := add_cylinder(body, 0.025, 0.025, 0.18,
			Vector3(side * 0.22, 0.28, -0.02), frame_mat,
			Vector3(0, 0, PI / 2.0), 10)
		add_rider_target(peg, &"foot_left" if side > 0.0 else &"foot_right",
			Vector3.ZERO)
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
	if _steer_head == null or _body_visual == null:
		return
	_steer_head.rotation = Vector3(-RAKE, 0, 0)
	_steer_head.rotate_object_local(Vector3.UP, _steer_current)
	var front := wheels[0]
	# The visible hub now occupies the exact raycast suspension centre. Fork
	# members bridge the raked steering head to that point, so compression and
	# steering can never make the tire hover above (or tunnel through) its patch.
	var fork_extension := front.travel - front.compression
	var front_center := front.local_pos - Vector3(0, fork_extension, 0)
	_front_wheel_visual.position = _model_local(front_center)
	_front_wheel_visual.rotation = Vector3.ZERO
	_front_wheel_visual.rotate_object_local(Vector3.UP, _steer_current)
	_front_wheel_visual.rotate_object_local(Vector3.RIGHT, front.spin_angle)
	_front_fender.position = _model_local(front_center) \
		+ Vector3(0, AUTHORED_FRONT_RADIUS + 0.06, 0)
	_front_fender.rotation = Vector3(0, _steer_current, 0)
	var hub_in_head := _steer_head.to_local(to_global(front_center))
	for i in range(_front_sliders.size()):
		var side := -0.095 if i == 0 else 0.095
		var fork_top := Vector3(side, 0.10, 0)
		var fork_bottom := hub_in_head + Vector3(side, 0, 0)
		var split := fork_top.lerp(fork_bottom, 0.57)
		_pose_fork_member(_front_fork_tubes[i], fork_top,
			split + (fork_bottom - fork_top).normalized() * 0.06)
		_pose_fork_member(_front_sliders[i], fork_top.lerp(fork_bottom, 0.42),
			fork_bottom)
	var rear := wheels[1]
	var rear_center := rear.local_pos \
		- Vector3(0, rear.travel - rear.compression, 0)
	_rear_wheel_visual.position = _model_local(rear_center)
	_rear_wheel_visual.rotation = Vector3.ZERO
	_rear_wheel_visual.rotate_object_local(Vector3.RIGHT, rear.spin_angle)
	# Aim the live swingarm directly at the same physical hub and lengthen only
	# its longitudinal members to meet it. The prior positive-angle estimate put
	# the visible rear wheel roughly 0.7 m above its actual contact patch.
	var arm_delta := _model_local(rear_center) - _swingarm.position
	_swingarm.rotation = Vector3(atan2(arm_delta.y, -arm_delta.z), 0, 0)
	_swingarm.scale = Vector3(1, 1, arm_delta.length() / 0.57)
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


## Convert a physical chassis-local coordinate into the uniformly scaled
## procedural model's local space. This keeps wheel hubs and suspension members
## on the real raycast contact geometry instead of applying MODEL_SCALE twice.
func _model_local(physical_local: Vector3) -> Vector3:
	return physical_local / MODEL_SCALE


func _pose_fork_member(member: MeshInstance3D, a: Vector3, b: Vector3) -> void:
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
