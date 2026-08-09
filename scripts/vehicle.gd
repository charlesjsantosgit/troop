class_name Vehicle
extends RigidBody3D
## Base class for every drivable machine. A real RigidBody3D chassis carries
## raycast-suspension wheels (VehicleWheel), a combustion drivetrain
## (VehicleEngine), quadratic aero drag, seasonal/water-aware tire grip, a
## generated mesh, and a synthesized engine loop. Subclasses supply geometry,
## tuning, and any extra physics (lean dynamics, aerodynamic lift, buoyancy).
##
## Ground sensing raycasts against real colliders first (props, arena pieces,
## debug blocks) and falls back to the analytic Gen.height field, so a vehicle
## can outrun chunk streaming — even at jet speeds — without ever falling
## through the world.

signal driver_impact(delta_speed: float)
## A deliberately completed backwards motorcycle loop is categorically fatal,
## unlike ordinary impacts that respect spawn/revive protection.
signal driver_fatal_crash()

enum Kind { BIKE, JEEP, BOAT, JET }
const KIND_NAMES := ["DUAL-SPORT", "SAFARI JEEP", "AIRBOAT", "FIGHTER JET"]
const ENTER_RANGE := 3.4
const IMPACT_DAMAGE_THRESHOLD := 9.0   # m/s of velocity lost in one tick
const DIRECTION_CHANGE_MAX_PLANAR_SPEED := 0.7
const DIRECTION_CHANGE_MAX_TOTAL_SPEED := 0.9
# Raycast tires can retain a small single-wheel spin mismatch while the stopped
# chassis is held on all four brakes. This still rejects meaningful driveline
# motion without deadlocking the familiar hold-S-to-reverse control.
const DIRECTION_CHANGE_MAX_WHEEL_SPEED := 2.5
# Numerical guardrails sit far outside every authored machine envelope (the
# jet tops out near 313 m/s). They catch an unstable rigid-body step before a
# squared aero term or visual transform can turn it into NaN and poison the
# complete physics world.
const MAX_SAFE_WORLD_COORDINATE := 1000000.0
const MAX_SAFE_LINEAR_SPEED := 1000.0
const MAX_SAFE_ANGULAR_SPEED := 60.0
const MAX_SAFE_WHEEL_SPIN := 2500.0


## Render-only adapter consumed by MonkeyRig. The rig expects the vehicle pose
## interface, while this adapter deliberately redirects contact reads to the
## interpolated render transforms without changing the raw physics/test API.
class RiderRenderPose:
	extends RefCounted
	var _vehicle_ref: WeakRef

	func _init(owner) -> void:
		_vehicle_ref = weakref(owner)

	var kind: int:
		get:
			var owner = _vehicle_ref.get_ref()
			return int(owner.kind) if is_instance_valid(owner) else 0

	func has_rider_target(slot: StringName) -> bool:
		var owner = _vehicle_ref.get_ref()
		return is_instance_valid(owner) and owner.has_rider_target(slot)

	func rider_target_global(slot: StringName) -> Vector3:
		var owner = _vehicle_ref.get_ref()
		return owner.rider_target_render_global(slot) \
			if is_instance_valid(owner) else Vector3.INF

var vid := ""
var kind := Kind.JEEP
var world: Node3D
var wheels: Array[VehicleWheel] = []
var engine := VehicleEngine.new()
var driver: Node3D = null              # local MonkeyPlayer while driven
var remote_controlled := false         # a network peer is driving
var occupied_by_peer := 0              # peer id holding the network claim

# Driver inputs, written each tick by the seated player.
var input_throttle := 0.0
var input_brake := 0.0
var input_steer := 0.0                 # -1 .. 1, positive steers left
var input_handbrake := false
var input_aux := false                 # SHIFT: tuck / afterburner / low range

# Tuning shared by subclasses.
var drag_area := 1.6                   # Cd * A, m^2
var steer_speed := 3.2                 # steering response, 1/s
var max_steer_angle := 0.55            # rad at standstill
var seat_offset := Vector3(0, 0.9, 0)
## Vehicle-local location of the MonkeyRig origin while occupied. This is
## authored per machine so the pelvis rests on the actual cushion/saddle; it is
## deliberately separate from seat_offset, which remains the replicated player
## anchor and interaction point.
var rider_root_offset := Vector3(0, 0.46, 0)
## Named control contacts used by the rider's final-pass IK. Values are either
## vehicle-local Vector3s or Node3Ds parented under moving controls.
var rider_targets: Dictionary = {}
var exit_offsets: Array[Vector3] = [Vector3(1.4, 0.4, 0), Vector3(-1.4, 0.4, 0),
	Vector3(0, 0.6, 2.4), Vector3(0, 0.6, -2.4)]
var camera_distance := 6.0
## World-up chase pivot. The spring arm adds more height as it tilts down, so
## this is intentionally separate from the monkey-head cockpit anchor below.
var camera_height := 2.4
## Relative chase pitch in radians. Negative looks down and raises the arm end,
## keeping the machine low in frame while showing the road ahead.
var camera_chase_pitch := -0.20
var camera_bank_factor := 0.12
var speed_for_max_fov := 38.0
var fp_camera_offset := Vector3(0, 1.25, 0)
var engine_stream := "engine_v8"
var engine_pitch_base := 0.6
var engine_pitch_span := 1.25
var driver_mass := 38.0
## Vehicle-local offset from the authored rig root to the seated driver's mass
## centre. Subclasses can lower this for a tightly crouched riding posture.
var driver_center_offset := Vector3(0, 0.62, 0)

## Anti-roll bars: [left wheel index, right wheel index, N/m of compression
## difference] — transfers load across an axle to resist body roll.
var anti_roll: Array = []
## Slip ratio past which the driver feathers the throttle (rider TC).
var traction_slip_limit := 0.30

var _steer_target := 0.0
var _steer_current := 0.0
var _reverse_hold := 0.0
var _active_brake := 1.0
var _engine_player: AudioStreamPlayer3D
var _wind_player: AudioStreamPlayer3D
var _remote_target_pos := Vector3.ZERO
var _remote_target_basis := Basis.IDENTITY
var _remote_velocity := Vector3.ZERO
var _remote_rpm := 0.0
var _remote_got_state := false
var _prev_velocity := Vector3.ZERO
var _idle_timer := 0.0
var _righting_timer := 0.0
var _space: PhysicsDirectSpaceState3D
var _exclude: Array[RID] = []
var _unladen_mass := 0.0
var _unladen_center_of_mass := Vector3.ZERO
var _driver_load_applied := false
var _rider_render_pose: RiderRenderPose
var exhaust_emitters: Array[VehicleExhaust] = []
var physics_recovery_count := 0
var _last_safe_position := Vector3.ZERO
var _last_safe_yaw := 0.0


func _ready() -> void:
	collision_layer = 1
	collision_mask = 1
	continuous_cd = true
	can_sleep = true
	contact_monitor = false
	# Every loss is modelled explicitly (tires, aero, water, rolling
	# resistance). The engine's default velocity damping would otherwise act
	# as a hidden ~0.1/s brake that caps top speeds hundreds of newtons early.
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.0
	_space = get_world_3d().direct_space_state
	_exclude = [get_rid()]
	Sfx.ensure_vehicle_sounds()
	_build_engine_audio()


func setup(vehicle_id: String, owner_world: Node3D) -> void:
	vid = vehicle_id
	world = owner_world


func display_name() -> String:
	return KIND_NAMES[kind]


## Verb shown in the HUD prompt ("RIDE", "PILOT"...).
func mount_verb() -> String:
	return "RIDE"


func seat_global() -> Vector3:
	return global_position + global_basis * seat_offset


func rider_root_global() -> Vector3:
	return global_position + global_basis * rider_root_offset


## Render-frame saddle transform. Raw rider_root_global remains authoritative
## for physics and deterministic tests; visible rigs use this interpolated pose
## so they stay welded to the chassis between physics ticks.
func rider_render_transform() -> Transform3D:
	var vehicle_transform := get_global_transform_interpolated()
	return Transform3D(vehicle_transform.basis * Basis(Vector3.UP, PI),
		vehicle_transform * rider_root_offset)


func seat_render_global() -> Vector3:
	return get_global_transform_interpolated() * seat_offset


## Register a rider contact under a moving vehicle part (steering wheel, bar,
## stick, pedal). Keeping the marker in that hierarchy makes paws and feet stay
## planted as the visible control animates.
func add_rider_target(parent: Node3D, slot: StringName,
		local_position: Vector3) -> Node3D:
	var marker := Node3D.new()
	marker.name = "RiderTarget_" + str(slot)
	marker.position = local_position
	parent.add_child(marker)
	rider_targets[slot] = marker
	return marker


func rider_target_global(slot: StringName) -> Vector3:
	var value: Variant = rider_targets.get(slot)
	if value is Node3D and is_instance_valid(value):
		return (value as Node3D).global_position
	if value is Vector3:
		return global_position + global_basis * (value as Vector3)
	return Vector3.INF


## Interpolated counterpart used only by render-driven MonkeyRig IK.
func rider_target_render_global(slot: StringName) -> Vector3:
	var value: Variant = rider_targets.get(slot)
	if value is Node3D and is_instance_valid(value):
		return (value as Node3D).get_global_transform_interpolated().origin
	if value is Vector3:
		return get_global_transform_interpolated() * (value as Vector3)
	return Vector3.INF


func rider_render_pose() -> RiderRenderPose:
	if _rider_render_pose == null:
		_rider_render_pose = RiderRenderPose.new(self)
	return _rider_render_pose


func has_rider_target(slot: StringName) -> bool:
	return rider_target_global(slot).is_finite()


## Register one exact pipe/nozzle outlet in unscaled vehicle-local space. The
## exhaust component owns only bounded presentation; it never affects physics.
func add_exhaust(outlet: Vector3, direction: Vector3,
		profile_kind: int) -> VehicleExhaust:
	var emitter := VehicleExhaust.new()
	emitter.position = outlet
	emitter.setup(profile_kind, direction)
	add_child(emitter)
	exhaust_emitters.append(emitter)
	if world:
		emitter.set_quality(bool(world.get("_high_effects")),
			bool(world.get("_fullscreen_performance")))
	return emitter


func set_effect_quality(high_effects: bool,
		fullscreen_performance: bool) -> void:
	for emitter in exhaust_emitters:
		emitter.set_quality(high_effects, fullscreen_performance)


## Ground machines derive a clean-engine vapor level from live RPM and load.
## Airboat/jet override this because their spool state replaces VehicleEngine.
func exhaust_activity(profile_kind: int) -> float:
	var running := driver != null or remote_controlled
	var rpm_fraction := _remote_rpm if remote_controlled \
		else engine.rpm_fraction()
	var load := 0.60 if remote_controlled else input_throttle
	return VehicleExhaust.sampled_intensity(profile_kind, running,
		rpm_fraction, load)


func exhaust_boost() -> float:
	return 0.0


func _update_exhaust(dt: float) -> void:
	var boost_amount := exhaust_boost()
	for emitter in exhaust_emitters:
		emitter.update_output(dt, exhaust_activity(emitter.profile), boost_amount)


func interaction_position() -> Vector3:
	return seat_global()


func can_enter(_player: Node3D) -> bool:
	return driver == null and not remote_controlled and occupied_by_peer == 0


func begin_drive(player: Node3D) -> void:
	driver = player
	sleeping = false
	freeze = false
	# Treat the monkey as real payload instead of adding weight at the chassis
	# origin. The combined CoM matters most on the light motorcycle, where a
	# rider is a meaningful fraction of the moving mass.
	if not _driver_load_applied:
		_unladen_mass = mass
		_unladen_center_of_mass = center_of_mass
		var rider_com := rider_root_offset + driver_center_offset
		var loaded_mass := _unladen_mass + driver_mass
		center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		center_of_mass = (_unladen_center_of_mass * _unladen_mass
			+ rider_com * driver_mass) / maxf(loaded_mass, 1.0)
		mass = loaded_mass
		_driver_load_applied = true
	input_throttle = 0.0
	input_brake = 0.0
	input_steer = 0.0
	input_handbrake = false
	input_aux = false
	_reverse_hold = 0.0
	_steer_target = 0.0
	_prev_velocity = linear_velocity


## Ends local driving and returns a safe world-space exit position.
func end_drive() -> Vector3:
	driver = null
	if _driver_load_applied:
		mass = maxf(_unladen_mass, 1.0)
		center_of_mass = _unladen_center_of_mass
		_driver_load_applied = false
	input_throttle = 0.0
	input_brake = 1.0
	input_steer = 0.0
	input_handbrake = true
	input_aux = false
	_reverse_hold = 0.0
	_steer_target = 0.0
	return _pick_exit_position()


func _pick_exit_position() -> Vector3:
	for offset in exit_offsets:
		var candidate := global_position + global_basis * offset
		var ground := terrain_height_at(candidate.x, candidate.z)
		if candidate.y < ground:
			candidate.y = ground + 0.35
		# Reject spots that would drop the player into deep water.
		if ground < Gen.WATER_Y - 1.1 and kind != Kind.BOAT:
			continue
		var query := PhysicsRayQueryParameters3D.create(
			seat_global(), candidate + Vector3.UP * 0.5)
		query.exclude = _exclude
		if _space and _space.intersect_ray(query).is_empty():
			return candidate + Vector3.UP * 0.15
	return global_position + Vector3.UP * (2.0 + 0.002 * absf(linear_velocity.y))


## Extra per-frame driver context: camera aim (the jet's pursuit stick) and
## the raw input frame for vehicle-specific just-pressed keys. Base ignores it.
func set_driver_view(_aim: Vector3, _inp: Dictionary) -> void:
	pass


## Dismounting is allowed when slow; subclasses can allow mid-air bail-outs.
func allows_exit() -> bool:
	return speed() < 4.5


## Whether a violent crash throws the rider off (true for the motorcycle).
func ejects_rider_on_crash() -> bool:
	return false


func set_inputs(throttle: float, brake: float, steer: float,
		handbrake_on: bool, aux: bool) -> void:
	input_throttle = clampf(throttle, 0.0, 1.0)
	input_brake = clampf(brake, 0.0, 1.0)
	input_steer = clampf(steer, -1.0, 1.0)
	input_handbrake = handbrake_on
	input_aux = aux
	if driver:
		sleeping = false


func speed() -> float:
	return linear_velocity.length()


func forward_speed() -> float:
	return linear_velocity.dot(global_basis.z)


func speed_mph() -> float:
	return speed() * 2.23694


## Pitch/roll/rpm packed for the network state message.
func state_aux() -> Vector3:
	var euler := global_basis.get_euler(EULER_ORDER_YXZ)
	return Vector3(euler.x, euler.z, engine.rpm_fraction())


func yaw_angle() -> float:
	return global_basis.get_euler(EULER_ORDER_YXZ).y


## Remote-driven vehicles are frozen kinematic and interpolate toward the
## driver's replicated state; wheel spin and audio derive from velocity.
func set_remote_controlled(active: bool, peer_id := 0) -> void:
	remote_controlled = active
	occupied_by_peer = peer_id if active else 0
	freeze = active
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	if active:
		_remote_target_pos = global_position
		_remote_target_basis = global_basis
		_remote_got_state = false
	else:
		sleeping = false


func apply_remote_state(pos: Vector3, yaw: float, aux: Vector3,
		vel: Vector3) -> void:
	_remote_target_pos = pos - Basis.from_euler(
		Vector3(aux.x, yaw, aux.y), EULER_ORDER_YXZ) * seat_offset
	_remote_target_basis = Basis.from_euler(Vector3(aux.x, yaw, aux.y),
		EULER_ORDER_YXZ)
	_remote_velocity = vel
	_remote_rpm = aux.z
	if not _remote_got_state:
		_remote_got_state = true
		global_position = _remote_target_pos
		global_basis = _remote_target_basis


## Place the machine at rest on the terrain under `pos`: wheels already
## carrying their static sag, so spawning never drops, slams a bumpstop, or
## trampolines the chassis.
func settle_at(pos: Vector3, yaw: float) -> void:
	var ground := terrain_height_at(pos.x, pos.z)
	var lowest := 0.0
	var per_wheel_load := mass * 9.8 / maxf(float(wheels.size()), 1.0)
	for wheel in wheels:
		var sag: float = clampf(per_wheel_load / wheel.spring_rate,
			0.0, wheel.travel * 0.8)
		wheel.compression = sag
		lowest = minf(lowest, wheel.local_pos.y
			- (wheel.travel - sag) - wheel.radius)
	global_basis = Basis(Vector3.UP, yaw)
	if wheels.is_empty():
		global_position = Vector3(pos.x, ground + 0.45, pos.z)
	else:
		global_position = Vector3(pos.x, ground - lowest + 0.01, pos.z)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_last_safe_position = global_position
	_last_safe_yaw = yaw
	reset_physics_interpolation()


## Host-side resting state after a driver leaves, applied on all peers.
func apply_rest_state(pos: Vector3, yaw: float, pitch: float,
		roll: float) -> void:
	global_position = pos
	global_basis = Basis.from_euler(Vector3(pitch, yaw, roll), EULER_ORDER_YXZ)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_last_safe_position = global_position
	_last_safe_yaw = yaw


func _physics_process(dt: float) -> void:
	# RigidBody integration happens before this callback. Validate immediately so
	# a single bad solver step can never reach tire probes, v^2 aero, audio, or
	# child transforms, then validate once more after subclass simulation.
	if _sanity_clamp():
		return
	if remote_controlled:
		_advance_remote(dt)
		if _sanity_clamp():
			return
		_update_visuals(dt)
		_update_audio(dt, _remote_rpm, 0.6)
		_update_exhaust(dt)
		return
	if driver == null:
		_idle_timer += dt
		# Parked: brakes on, engine off; keep simulating briefly so the
		# suspension settles, then let the body sleep.
		input_brake = 1.0
		input_throttle = 0.0
		input_steer = 0.0
		input_aux = false
		input_handbrake = true
		if sleeping:
			_update_audio(dt, 0.0, 0.0)
			_update_exhaust(dt)
			return
	else:
		_idle_timer = 0.0
	_simulate(dt)
	if _sanity_clamp():
		return
	if driver == null:
		_apply_parked_hold(dt)
	_update_visuals(dt)
	_update_audio(dt, engine.rpm_fraction(),
		input_throttle if driver else 0.0)
	_update_exhaust(dt)
	_detect_impacts()
	_try_sleep_parked()


## A real parking brake resists the whole parked chassis, not merely wheel spin.
## Add a bounded low-speed hold for ground machines so a residual sideways skid
## cannot carry an abandoned jeep away after the player has stopped and exited.
func _apply_parked_hold(_dt: float) -> void:
	if kind != Kind.BIKE and kind != Kind.JEEP:
		return
	if not _has_parked_support() \
			or (kind != Kind.BIKE and global_basis.y.y < 0.35):
		return
	var planar := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	if planar.length() < 4.0:
		apply_central_force(-planar * mass * 5.0)
		if kind == Kind.BIKE:
			# A real rider leaves the steering lock and stand supporting the light
			# one-track chassis. Dampen all rocking axes so a bike resting on its
			# chassis or stand does not endlessly teeter after the monkey leaves.
			apply_torque(-angular_velocity * mass * 2.2)
		else:
			apply_torque(-Vector3.UP * angular_velocity.y * mass * 1.2)


## Core ground-vehicle simulation; subclasses extend or replace.
func _simulate(dt: float) -> void:
	_advance_steering(dt)
	# Driver intent: holding S at a stop drops into reverse; throttle from
	# reverse brakes to a stop and re-engages first. While reversing, S is
	# the accelerator and W the brake, like every road car ever made.
	var throttle := input_throttle if driver else 0.0
	var brake := input_brake if driver else 1.0
	if engine.reverse_ratio > 0.0 and driver:
		# Direction changes are only legal at a genuine stop. Signed comparisons
		# used to select reverse while already rolling backward quickly (and first
		# while rolling forward), turning the driver's brake into acceleration.
		var stopped_for_direction_change := _direction_change_is_safe()
		if engine.gear >= 1 and input_brake > 0.4 \
				and stopped_for_direction_change:
			_reverse_hold += dt
			if _reverse_hold > 0.3:
				engine.gear = -1
		elif engine.gear == -1 and input_throttle > 0.4 \
				and stopped_for_direction_change:
			engine.gear = 1
			_reverse_hold = 0.0
		else:
			_reverse_hold = 0.0
		if engine.gear == -1:
			throttle = input_brake
			brake = input_throttle
	var driven_speed := 0.0
	var driven_count := 0
	var worst_slip := 0.0
	for wheel in wheels:
		if wheel.driven:
			driven_speed += wheel.spin
			driven_count += 1
			if wheel.in_contact:
				worst_slip = maxf(worst_slip, wheel.slip_ratio)
	if driven_count > 0:
		driven_speed /= float(driven_count)
	# Rider/driver traction control: past the tire's peak slip, more throttle
	# only digs a hole, so feather it the way a real right hand would.
	if worst_slip > traction_slip_limit:
		throttle *= clampf(1.0 - (worst_slip - traction_slip_limit) * 3.2,
			0.18, 1.0)
	var drive := engine.step(dt, throttle, driven_speed, forward_speed())
	_active_brake = brake
	_distribute_drivetrain(drive, dt)
	_step_wheels(dt)
	_apply_anti_roll()
	_apply_aero(dt)
	if driver:
		_assist_recovery(dt)


## A transmission direction change requires the chassis and driveline to be
## genuinely stopped. Longitudinal speed alone is insufficient during a side
## slide or jump, and a spinning driven wheel still carries driveline energy.
func _direction_change_is_safe() -> bool:
	var planar_speed := Vector2(linear_velocity.x, linear_velocity.z).length()
	if planar_speed >= DIRECTION_CHANGE_MAX_PLANAR_SPEED \
			or speed() >= DIRECTION_CHANGE_MAX_TOTAL_SPEED:
		return false
	var driven_contact := false
	for wheel in wheels:
		if not wheel.driven:
			continue
		driven_contact = driven_contact or wheel.in_contact
		if absf(wheel.spin * wheel.radius) >= DIRECTION_CHANGE_MAX_WHEEL_SPEED:
			return false
	return driven_contact


func _advance_steering(dt: float) -> void:
	# Grip-limited steering: at speed the front tires can only use so much
	# steering angle before saturating, so the lock winds down with speed.
	var v := absf(forward_speed())
	var grip_limit := clampf(9.5 / maxf(v, 2.0), 0.10, 1.0)
	_steer_target = input_steer * max_steer_angle * grip_limit
	_steer_current = move_toward(_steer_current, _steer_target,
		steer_speed * max_steer_angle * dt)
	for wheel in wheels:
		if wheel.steerable:
			wheel.steer_angle = _steer_current


func _distribute_drivetrain(drive_torque: float, _dt: float) -> void:
	var driven_count := 0
	for wheel in wheels:
		if wheel.driven:
			driven_count += 1
	var brake_total := _total_brake_torque() * _active_brake
	for wheel in wheels:
		wheel.drive_torque = 0.0
		if wheel.driven and driven_count > 0:
			wheel.drive_torque = drive_torque / float(driven_count)
		wheel.brake_torque = brake_total * wheel.brake_share
		wheel.handbrake = input_handbrake and not wheel.steerable


func _total_brake_torque() -> float:
	return 2600.0


func _step_wheels(dt: float) -> void:
	for wheel in wheels:
		var attach := global_position + global_basis * wheel.local_pos
		var probe := probe_ground(attach, wheel.radius + wheel.travel + 0.35)
		wheel.surface_grip = _surface_grip_at(probe.point, probe.normal)
		var force := wheel.step(self, dt, probe.distance, probe.normal)
		if force != Vector3.ZERO:
			apply_force(force, wheel.contact_point - global_position)


func _apply_anti_roll() -> void:
	var up := global_basis.y
	for bar in anti_roll:
		var left: VehicleWheel = wheels[bar[0]]
		var right: VehicleWheel = wheels[bar[1]]
		if not (left.in_contact and right.in_contact):
			continue
		var transfer: float = (left.compression - right.compression) \
			* float(bar[2])
		# The twisted bar adds support under the more-compressed corner and
		# unloads the extended one, resisting body roll.
		var left_attach := global_position + global_basis * left.local_pos
		var right_attach := global_position + global_basis * right.local_pos
		apply_force(up * transfer, left_attach - global_position)
		apply_force(-up * transfer, right_attach - global_position)


## Raycast against real colliders, falling back to the analytic terrain field
## so streaming can never drop a vehicle through the world.
func probe_ground(from: Vector3, depth: float) -> Dictionary:
	var up := global_basis.y
	if _space:
		var query := PhysicsRayQueryParameters3D.create(
			from + up * 0.3, from - up * depth)
		query.exclude = _exclude
		var hit := _space.intersect_ray(query)
		if not hit.is_empty():
			return {"distance": (from - (hit.position as Vector3)).dot(up),
				"normal": hit.normal, "point": hit.position, "real": true}
	var terrain_y := terrain_height_at(from.x, from.z)
	# Only meaningful when the body is roughly upright; when inverted the
	# analytic fallback reports no ground so the chassis box takes over.
	if up.y > 0.35:
		var dist := (from.y - terrain_y) / maxf(up.y, 0.4)
		if dist <= depth:
			return {"distance": maxf(dist, 0.0),
				"normal": terrain_normal_at(from.x, from.z),
				"point": Vector3(from.x, terrain_y, from.z), "real": false}
	return {"distance": INF, "normal": Vector3.UP, "point": from,
		"real": false}


func terrain_height_at(x: float, z: float) -> float:
	return Gen.height(x, z)


func terrain_normal_at(x: float, z: float) -> Vector3:
	var e := 0.6
	var hx := Gen.height(x + e, z) - Gen.height(x - e, z)
	var hz := Gen.height(x, z + e) - Gen.height(x, z - e)
	return Vector3(-hx, 2.0 * e, -hz).normalized()


## Seasonal + water grip for one wheel contact.
func _surface_grip_at(point: Vector3, normal: Vector3) -> float:
	var grip := 1.0
	if world and world.get("season") != null \
			and world.season == SeasonalCycle.Season.WINTER:
		grip *= 0.74
	var terrain_y := terrain_height_at(point.x, point.z)
	if terrain_y < Gen.WATER_Y - 0.12 and point.y < Gen.WATER_Y + 0.1:
		grip *= 0.55   # submerged wheel churning a lakebed
	elif normal.y < 0.82:
		grip *= 0.92   # loose steep slope
	return grip


func _apply_aero(_dt: float) -> void:
	var v := linear_velocity
	var v_len := v.length()
	if v_len < 0.5:
		return
	var drag := 0.5 * 1.225 * drag_area * v_len * v_len
	apply_central_force(-v.normalized() * drag)
	# Water fording: a hull dragging through a lake sheds speed fast.
	var depth := Gen.WATER_Y - terrain_height_at(
		global_position.x, global_position.z)
	if depth > 0.35 and global_position.y < Gen.WATER_Y + 0.4 \
			and kind != Kind.BOAT:
		apply_central_force(-Vector3(v.x, 0, v.z) * 260.0 * clampf(depth, 0.0, 2.0))


## Slow self-righting while a driver is aboard and nearly stopped — the
## monkey picks the machine up rather than being stranded under it.
func _assist_recovery(dt: float) -> void:
	if global_basis.y.y > 0.35 or speed() > 3.0:
		_righting_timer = 0.0
		return
	_righting_timer += dt
	if _righting_timer < 0.8:
		return
	var axis := global_basis.y.cross(Vector3.UP)
	if axis.length() < 0.05:
		axis = global_basis.z
	apply_torque(axis.normalized() * mass * 15.0)
	angular_velocity *= 0.92


func _advance_remote(dt: float) -> void:
	if not _remote_got_state:
		return
	var predicted := _remote_target_pos + _remote_velocity * 0.05
	global_position = global_position.lerp(predicted,
		1.0 - exp(-14.0 * dt))
	global_basis = global_basis.orthonormalized().slerp(
		_remote_target_basis, 1.0 - exp(-11.0 * dt))
	for wheel in wheels:
		wheel.spin = _remote_velocity.dot(global_basis.z) / wheel.radius
		wheel.spin_angle = fposmod(wheel.spin_angle + wheel.spin * dt, TAU)


func _detect_impacts() -> void:
	if driver == null:
		_prev_velocity = linear_velocity
		return
	var delta := (_prev_velocity - linear_velocity).length()
	_prev_velocity = linear_velocity
	if delta > IMPACT_DAMAGE_THRESHOLD:
		driver_impact.emit(delta)


## Returns true when this frame was recovered and callers must stop using the
## pre-recovery state. Normal motion is never clamped by these guardrails.
func _sanity_clamp() -> bool:
	if not _physics_state_is_safe():
		_recover_invalid_physics()
		return true
	var floor_y := terrain_height_at(global_position.x, global_position.z)
	if global_position.y < floor_y - 1.6:
		global_position.y = floor_y + 0.8
		linear_velocity.y = maxf(linear_velocity.y, -1.0)
	_last_safe_position = global_position
	_last_safe_yaw = global_basis.get_euler(EULER_ORDER_YXZ).y
	return false


func _physics_state_is_safe() -> bool:
	if not global_position.is_finite() \
			or absf(global_position.x) > MAX_SAFE_WORLD_COORDINATE \
			or absf(global_position.y) > MAX_SAFE_WORLD_COORDINATE \
			or absf(global_position.z) > MAX_SAFE_WORLD_COORDINATE:
		return false
	if not linear_velocity.is_finite() or not angular_velocity.is_finite() \
			or linear_velocity.length() > MAX_SAFE_LINEAR_SPEED \
			or angular_velocity.length() > MAX_SAFE_ANGULAR_SPEED:
		return false
	var basis := global_basis
	if not basis.x.is_finite() or not basis.y.is_finite() \
			or not basis.z.is_finite():
		return false
	for axis in [basis.x, basis.y, basis.z]:
		var axis_length: float = (axis as Vector3).length()
		if axis_length < 0.75 or axis_length > 1.25:
			return false
	var determinant := basis.determinant()
	if not is_finite(determinant) or determinant < 0.5 or determinant > 1.5:
		return false
	if not is_finite(engine.rpm) or engine.rpm < 0.0 or engine.rpm > 20000.0 \
			or not is_finite(_steer_target) or not is_finite(_steer_current) \
			or absf(_steer_target) > 10.0 or absf(_steer_current) > 10.0:
		return false
	for wheel in wheels:
		if not is_finite(wheel.spin) or absf(wheel.spin) > MAX_SAFE_WHEEL_SPIN \
				or not is_finite(wheel.spin_angle) \
				or not is_finite(wheel.steer_angle) \
				or not wheel.contact_point.is_finite() \
				or not wheel.contact_normal.is_finite() \
				or not is_finite(wheel.compression) \
				or wheel.compression < -0.01 \
				or wheel.compression > wheel.travel + 0.01 \
				or not is_finite(wheel.compression_velocity) \
				or not is_finite(wheel.load) or wheel.load < 0.0 \
				or wheel.load > maxf(mass * 9.81 * 100.0, 1000000.0):
			return false
	return true


func _recover_invalid_physics() -> void:
	physics_recovery_count += 1
	var recovery := _last_safe_position
	if not recovery.is_finite() \
			or absf(recovery.x) > MAX_SAFE_WORLD_COORDINATE \
			or absf(recovery.z) > MAX_SAFE_WORLD_COORDINATE:
		recovery = Vector3.ZERO
	settle_at(recovery, _last_safe_yaw if is_finite(_last_safe_yaw) else 0.0)
	input_throttle = 0.0
	input_brake = 1.0
	input_steer = 0.0
	input_handbrake = true
	input_aux = false
	_steer_target = 0.0
	_steer_current = 0.0
	_prev_velocity = Vector3.ZERO
	engine.rpm = engine.idle_rpm
	for wheel in wheels:
		wheel.spin = 0.0
		wheel.spin_angle = 0.0
		wheel.steer_angle = 0.0
		wheel.compression_velocity = 0.0
		wheel.load = 0.0
		wheel.slip_ratio = 0.0
		wheel.slip_angle = 0.0
		wheel.contact_point = global_position
		wheel.contact_normal = Vector3.UP
		wheel.drive_torque = 0.0
		wheel.brake_torque = 0.0
	_reset_special_physics_state()
	sleeping = driver == null and not remote_controlled
	reset_physics_interpolation()


## Subclasses clear transient assists that could immediately reapply the force
## which preceded a numerical recovery.
func _reset_special_physics_state() -> void:
	pass


func _try_sleep_parked() -> void:
	# Below these speeds the rider's parking brake/feet can settle the machine
	# more realistically than letting the rigid body accumulate tiny tire and
	# sidestand corrections forever.
	if driver != null or remote_controlled or _idle_timer < 1.25 \
			or linear_velocity.length() > 0.40 \
			or angular_velocity.length() > 0.85:
		return
	if kind == Kind.BIKE:
		var pose := global_basis.get_euler(EULER_ORDER_YXZ)
		# A motorcycle is parked only on its authored kickstand attitude. Do not
		# let generic rigid-body sleep bless a bike lying on its side.
		if absf(pose.x) > 0.25 \
				or absf(angle_difference(pose.z, -0.12)) > 0.25:
			return
	if _has_parked_support():
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		sleeping = true


## Park only on authored suspension contact. Chassis-distance or analytic
## terrain heuristics can mistake a low airborne machine (or a bridge above the
## terrain field) for support and freeze it before the wheels touch.
func _has_parked_support() -> bool:
	for wheel in wheels:
		if wheel.in_contact:
			return true
	return false


## Default wheel visual update: position follows suspension, spin + steer.
func _update_visuals(dt: float) -> void:
	for wheel in wheels:
		if wheel.visual == null:
			continue
		var wheel_pos := wheel.local_pos \
			- Vector3(0, wheel.travel - wheel.compression, 0)
		wheel.visual.position = wheel_pos
		wheel.visual.rotation = Vector3(0, wheel.steer_angle, 0)
		wheel.visual.rotate_object_local(Vector3.RIGHT, wheel.spin_angle)
	_update_extra_visuals(dt)


func _update_extra_visuals(_dt: float) -> void:
	pass


func _build_engine_audio() -> void:
	_engine_player = AudioStreamPlayer3D.new()
	_engine_player.stream = Sfx.streams.get(engine_stream)
	_engine_player.bus = &"SFX"
	_engine_player.max_distance = 130.0
	_engine_player.unit_size = 7.0
	_engine_player.volume_db = -60.0
	_engine_player.attenuation_model = \
		AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC
	add_child(_engine_player)
	if _engine_player.stream:
		_engine_player.play()
	_wind_player = AudioStreamPlayer3D.new()
	_wind_player.stream = Sfx.streams.get("wind")
	_wind_player.bus = &"Ambience"
	_wind_player.max_distance = 60.0
	_wind_player.volume_db = -60.0
	add_child(_wind_player)
	if _wind_player.stream:
		_wind_player.play()


func _update_audio(_dt: float, rpm_frac: float, load: float) -> void:
	if _engine_player == null:
		return
	var running := driver != null or remote_controlled or rpm_frac > 0.02
	if not running:
		_engine_player.volume_db = -60.0
		if _wind_player:
			_wind_player.volume_db = -60.0
		return
	_engine_player.pitch_scale = clampf(
		engine_pitch_base + rpm_frac * engine_pitch_span, 0.25, 4.0)
	_engine_player.volume_db = lerpf(-17.0, -5.0, clampf(
		load * 0.75 + rpm_frac * 0.35, 0.0, 1.0))
	if _wind_player:
		var sp := speed()
		_wind_player.volume_db = lerpf(-60.0, -14.0,
			clampf(sp / 60.0, 0.0, 1.0))
		_wind_player.pitch_scale = 0.9 + sp / 90.0


# ---- shared generated-mesh helpers ----------------------------------------

static var _material_cache: Dictionary = {}


static func paint_material(color: Color, metallic := 0.35,
		roughness := 0.5) -> StandardMaterial3D:
	var key := "%s_%.2f_%.2f" % [color.to_html(false), metallic, roughness]
	if not _material_cache.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.metallic = metallic
		m.roughness = roughness
		_material_cache[key] = m
	return _material_cache[key]


static func rubber_material() -> StandardMaterial3D:
	return paint_material(Color(0.055, 0.055, 0.06), 0.0, 0.92)


static func chrome_material() -> StandardMaterial3D:
	return paint_material(Color(0.75, 0.77, 0.8), 0.95, 0.16)


static func dark_metal_material() -> StandardMaterial3D:
	return paint_material(Color(0.16, 0.165, 0.18), 0.7, 0.42)


static func glass_material() -> StandardMaterial3D:
	var key := "glass"
	if not _material_cache.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.35, 0.46, 0.52, 0.42)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.metallic = 0.6
		m.roughness = 0.06
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_material_cache[key] = m
	return _material_cache[key]


func add_box(parent: Node3D, size: Vector3, pos: Vector3,
		material: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.rotation = rot
	mi.material_override = material
	parent.add_child(mi)
	return mi


func add_cylinder(parent: Node3D, top_r: float, bottom_r: float,
		height: float, pos: Vector3, material: Material,
		rot := Vector3.ZERO, radial_segments := 10) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_r
	mesh.bottom_radius = bottom_r
	mesh.height = height
	mesh.radial_segments = radial_segments
	mi.mesh = mesh
	mi.position = pos
	mi.rotation = rot
	mi.material_override = material
	parent.add_child(mi)
	return mi


func add_sphere(parent: Node3D, radius_v: float, pos: Vector3,
		material: Material, height_scale := 1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius_v
	mesh.height = radius_v * 2.0 * height_scale
	mesh.radial_segments = 12
	mesh.rings = 6
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = material
	parent.add_child(mi)
	return mi


## A knobby off-road wheel: tire cylinder, tread knobs, hub, and disc.
func build_knobby_wheel(tire_radius: float, tire_width: float,
		knob_count := 14, hub_color := Color(0.5, 0.5, 0.52)) -> Node3D:
	var wheel_root := Node3D.new()
	var tire := CylinderMesh.new()
	tire.top_radius = tire_radius
	tire.bottom_radius = tire_radius
	tire.height = tire_width
	tire.radial_segments = 14
	var tire_instance := MeshInstance3D.new()
	tire_instance.mesh = tire
	tire_instance.rotation = Vector3(0, 0, PI / 2.0)
	tire_instance.material_override = rubber_material()
	wheel_root.add_child(tire_instance)
	var knob := BoxMesh.new()
	knob.size = Vector3(tire_width * 1.06, tire_radius * 0.17,
		tire_radius * 0.24)
	for i in range(knob_count):
		var angle := TAU * float(i) / float(knob_count)
		var ki := MeshInstance3D.new()
		ki.mesh = knob
		ki.material_override = rubber_material()
		ki.position = Vector3(0, sin(angle), cos(angle)) \
			* (tire_radius * 0.94)
		ki.rotation = Vector3(angle, 0, 0)
		wheel_root.add_child(ki)
	var hub := CylinderMesh.new()
	hub.top_radius = tire_radius * 0.30
	hub.bottom_radius = tire_radius * 0.30
	hub.height = tire_width * 0.5
	hub.radial_segments = 8
	var hub_instance := MeshInstance3D.new()
	hub_instance.mesh = hub
	hub_instance.rotation = Vector3(0, 0, PI / 2.0)
	hub_instance.material_override = paint_material(hub_color, 0.7, 0.35)
	wheel_root.add_child(hub_instance)
	for i in range(6):
		var spoke := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(tire_width * 0.4, tire_radius * 1.3,
			tire_radius * 0.09)
		spoke.mesh = sm
		spoke.rotation = Vector3(TAU * float(i) / 6.0, 0, 0)
		spoke.material_override = paint_material(hub_color, 0.7, 0.35)
		wheel_root.add_child(spoke)
	return wheel_root
