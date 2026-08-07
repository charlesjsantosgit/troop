class_name VehicleWheel
extends RefCounted
## One raycast wheel: long-travel spring/damper suspension plus a slip-based
## tire. The owning Vehicle calls step() once per physics tick with the chassis
## state; this object integrates its own spin (so wheelspin, lockup, and
## engine-braking fall out of the math instead of being scripted) and reports
## the suspension + tire force it wants applied at the contact patch.
##
## The tire is a simplified Pacejka "magic formula": F = mu*Fz*sin(C*atan(B*s))
## on both axes, blended through a friction ellipse for combined slip, with
## mild tire-load sensitivity. Surface grip arrives from the Vehicle each tick
## (season, water depth, and terrain all scale it).

# --- configuration (set once by the owning vehicle) -------------------------
var local_pos := Vector3.ZERO        # attachment point on the chassis
var radius := 0.34
var travel := 0.22                   # total suspension travel in metres
var spring_rate := 28000.0           # N/m at the wheel
var damp_bump := 2400.0              # N/(m/s) compressing
var damp_rebound := 4200.0           # N/(m/s) extending
var steerable := false
var driven := false
var brake_share := 0.5               # fraction of total brake torque
var handbrake := false               # locked by the handbrake input
var wheel_mass := 14.0               # for spin inertia (I = 1/2 m r^2)
var mu_long := 1.05                  # peak longitudinal friction coefficient
var mu_lat := 0.95                   # peak lateral friction coefficient
var pacejka_b_long := 11.0           # slip-ratio stiffness
var pacejka_b_lat := 8.5             # slip-angle stiffness (per radian)
var rolling_resistance := 0.015
var visual: Node3D                   # optional wheel mesh moved by the vehicle

# --- live state -------------------------------------------------------------
var compression := 0.0               # 0 = fully extended, travel = bottomed
var compression_velocity := 0.0
var spin := 0.0                      # wheel angular velocity, rad/s
var spin_angle := 0.0                # accumulated visual rotation
var steer_angle := 0.0
var in_contact := false
var contact_point := Vector3.ZERO
var contact_normal := Vector3.UP
var load := 0.0                      # current vertical tire load Fz, N
var slip_ratio := 0.0
var slip_angle := 0.0
var surface_grip := 1.0              # external scale from season/water/terrain
var drive_torque := 0.0              # set per tick by the drivetrain
var brake_torque := 0.0              # set per tick by the vehicle
var _prev_compression := 0.0

const SPIN_SUBSTEPS := 4


func configure(config: Dictionary) -> void:
	for key in config:
		set(key, config[key])


## Suspension + tire step. `body` is the owning RigidBody3D, `dt` the physics
## step. `ground_distance` is how far below the attachment point the ground
## lies along -up (INF when nothing was hit), with `ground_normal` its normal.
## Returns the force to apply at the contact patch in world space.
func step(body: RigidBody3D, dt: float, ground_distance: float,
		ground_normal: Vector3) -> Vector3:
	var up := body.global_basis.y
	var rest := radius + travel
	_prev_compression = compression
	if ground_distance >= rest:
		# Airborne: extend fully, spin down on drive/brake alone.
		in_contact = false
		load = 0.0
		compression = 0.0
		compression_velocity = (compression - _prev_compression) / dt
		slip_ratio = 0.0
		slip_angle = 0.0
		_integrate_spin_airborne(dt)
		return Vector3.ZERO

	in_contact = true
	contact_normal = ground_normal
	compression = clampf(rest - ground_distance, 0.0, travel)
	compression_velocity = (compression - _prev_compression) / dt
	var attach := body.global_position + body.global_basis * local_pos
	contact_point = attach - up * (radius + travel - compression)

	# --- suspension -------------------------------------------------------
	var spring_force := spring_rate * compression
	var damper_rate := damp_bump if compression_velocity > 0.0 else damp_rebound
	var damper_force := damper_rate * compression_velocity
	# The damper may resist motion but never yank the wheel into the ground
	# harder than the spring supports — this keeps 60 Hz integration stable
	# even with stiff rebound damping.
	damper_force = clampf(damper_force, -spring_force * 0.85,
		spring_force * 1.6)
	# Bottoming: a progressive bumpstop over the last 15% of travel. Kept
	# energy-absorbing rather than springy so a hard landing does not
	# trampoline the chassis back into the air.
	if compression > travel * 0.85:
		var over := (compression - travel * 0.85) / (travel * 0.15)
		spring_force += spring_rate * travel * over * over * 2.4
		if compression_velocity < 0.0:
			spring_force *= 0.55   # bleed rebound energy out of the stop
	load = maxf(spring_force + damper_force, 0.0)
	var suspension_force := up * load

	# --- contact patch velocity ------------------------------------------
	var patch_vel := body.linear_velocity \
		+ body.angular_velocity.cross(contact_point - body.global_position)
	var yaw_rot := Basis(up, steer_angle)
	var forward := (yaw_rot * body.global_basis.z)
	# Project onto the contact plane so slopes read correctly.
	forward = (forward - contact_normal * forward.dot(contact_normal)).normalized()
	if forward.length_squared() < 0.001:
		return suspension_force
	var side := forward.cross(contact_normal).normalized()
	var v_long := patch_vel.dot(forward)
	var v_lat := patch_vel.dot(side)

	# --- slip + tire forces, substepped with the wheel spin ---------------
	var mu_scale := surface_grip * _load_sensitivity()
	var inertia := 0.5 * wheel_mass * radius * radius
	var sub := dt / float(SPIN_SUBSTEPS)
	var force_long := 0.0
	for i in range(SPIN_SUBSTEPS):
		slip_ratio = (spin * radius - v_long) / maxf(absf(v_long), 1.4)
		var fx := mu_long * mu_scale * load \
			* sin(1.65 * atan(pacejka_b_long * slip_ratio))
		# Torque balance on the wheel: drive - brake - ground reaction.
		var reaction := fx * radius
		var braking := brake_torque
		if handbrake:
			braking = maxf(braking, 2600.0)
		var net := drive_torque - reaction
		if braking > 0.0:
			var brake_sign := -signf(spin) if absf(spin) > 0.15 \
				else -signf(net)
			var applied := braking
			# A brake can stop the wheel but never spin it backwards.
			if absf(spin) < 0.15 and absf(net) < braking:
				applied = absf(net)
			net += brake_sign * applied
		spin += net / inertia * sub
		force_long += fx / float(SPIN_SUBSTEPS)
	# Lateral slip angle (small-speed guard keeps parked cars still).
	slip_angle = atan2(-v_lat, absf(v_long) + 0.6)
	var force_lat := mu_lat * mu_scale * load \
		* sin(1.45 * atan(pacejka_b_lat * slip_angle))

	# Friction ellipse: combined demand cannot exceed the circle of grip.
	var cap := maxf(mu_long * mu_scale * load, 1.0)
	var demand := Vector2(force_long / cap,
		force_lat / maxf(mu_lat * mu_scale * load, 1.0)).length()
	if demand > 1.0:
		force_long /= demand
		force_lat /= demand

	# Rolling resistance opposes travel.
	force_long -= rolling_resistance * load * signf(v_long) \
		* clampf(absf(v_long) * 2.0, 0.0, 1.0)

	# Low-speed damping so tires do not vibrate at a standstill.
	if absf(v_long) < 0.6 and absf(spin * radius) < 0.6 and brake_torque > 1.0:
		force_lat -= v_lat * load * 0.35
		force_long -= v_long * load * 0.35

	spin_angle = fposmod(spin_angle + spin * dt, TAU)
	return suspension_force + forward * force_long + side * force_lat


func _integrate_spin_airborne(dt: float) -> void:
	var inertia := 0.5 * wheel_mass * radius * radius
	var net := drive_torque
	var braking := brake_torque + (2600.0 if handbrake else 0.0)
	if braking > 0.0:
		if absf(spin) > 0.15:
			net -= signf(spin) * braking
		else:
			spin = 0.0
	spin += net / inertia * dt
	spin -= spin * 0.18 * dt   # bearing drag
	spin_angle = fposmod(spin_angle + spin * dt, TAU)


## Tires lose a little peak grip as load rises past their design point.
func _load_sensitivity() -> float:
	var design := spring_rate * travel * 0.45
	if design <= 0.0 or load <= design:
		return 1.0
	return clampf(1.0 - 0.08 * (load / design - 1.0), 0.78, 1.0)
