class_name CameraRig
extends Node3D
## Switchable first-person, shoulder, and front/selfie camera with speed-driven
## FOV, layered locomotion/inertia feedback, traversal-specific motion, stable
## recoil, precision scope suppression, and collision-aware spring arms.

enum ViewMode { SHOULDER, FIRST_PERSON, FRONT }

const SENS := 0.0028
const BASE_FOV := 76.0
const MAX_FOV := 97.0
const FIRST_PERSON_FOV := 82.0
const AIM_FOV := 70.0
const AIM_SENSITIVITY_MULTIPLIER := 0.72
const THIRD_PERSON_HEIGHT := 1.42
const FIRST_PERSON_HEIGHT := 1.16
const FIRST_PERSON_ARM := 0.035
const THIRD_PERSON_ARM := 5.85
const THIRD_PERSON_SPEED_ARM := 7.10
const FRONT_VIEW_ARM := 3.35
const FRONT_VIEW_HEIGHT := 0.86
const DEATH_VIEW_ARM := 5.85
const DEATH_FOLLOW_HEIGHT := 0.48
const SHOULDER_OFFSET := Vector3(1.05, 0.10, 0.0)
const FIRST_PERSON_PITCH_MIN := -1.55334  # -89 degrees
const FIRST_PERSON_PITCH_MAX := 1.55334   #  89 degrees
const THIRD_PERSON_PITCH_MIN := -1.35
const THIRD_PERSON_PITCH_MAX := 0.75
const CAMERA_PITCH_LIMIT := 1.562
# The virtual flight cursor is radial rather than a pair of rectangular axis
# clamps. Full ring travel requests a 30-degree pursuit direction, enough to
# reach full FBW authority without allowing an accidental mouse sweep to point
# behind the aircraft.
const AIRCRAFT_AIM_CONE_RADIANS := 0.5235987756

# Procedural movement is applied to the camera mount, independently of look and
# weapon recoil. These component-wise limits are deliberately conservative:
# first person gets enough motion to communicate weight while third person is
# scaled down, and a scope can suppress the layer without changing aim input.
const MOVEMENT_POSITION_LIMIT := Vector3(0.075, 0.090, 0.055)
const MOVEMENT_ROTATION_LIMIT := Vector3(0.060, 0.035, 0.180)
const LANDING_POSITION_LIMIT := 0.075
const LANDING_PITCH_LIMIT := 0.045
const MAX_CAMERA_ACCELERATION := 85.0
# Mirrors MonkeyPlayer.S without introducing a typed dependency back into the
# camera script (MonkeyPlayer owns a CameraRig and would otherwise be cyclic).
const PLAYER_STATE_AIR := 1
const PLAYER_STATE_SWING := 2
const PLAYER_STATE_SWIM := 4

var target  # MonkeyPlayer (untyped to avoid cyclic class_name resolution)
var yaw := 0.0
var pitch := -0.16
var first_person := false
var front_view := false
var view_mode := ViewMode.SHOULDER
var preferred_view_mode := ViewMode.SHOULDER
var preferred_first_person := false
var aiming := false
var sensitivity_multiplier := 1.0
var _pitch_node: Node3D
var _arm: SpringArm3D
var _camera_mount: Node3D
var _cam: Camera3D
var _view_arms: FirstPersonArms
var _trauma := 0.0
var _shake_t := 0.0
var _bob_t := 0.0
var _recoil_pitch := 0.0
var _recoil_yaw := 0.0
var _recoil_roll := 0.0
var _recoil_pitch_velocity := 0.0
var _recoil_yaw_velocity := 0.0
var _recoil_roll_velocity := 0.0
var _recoil_back := 0.0
var _recoil_index := 0
var _recoil_shake := 0.0
var _hit_trauma := 0.0
var _motion_t := 0.0
var _motion_roll := 0.0
var _motion_pitch := 0.0
var _motion_yaw := 0.0
var _motion_position := Vector3.ZERO
var _applied_motion_position := Vector3.ZERO
var _applied_motion_rotation := Vector3.ZERO
var _movement_blend := 0.0
var _landing_offset := 0.0
var _landing_velocity := 0.0
var _landing_pitch := 0.0
var _landing_pitch_velocity := 0.0
var _last_velocity := Vector3.ZERO
var _death_view := false
var _death_follow_target: Node3D
var _vehicle_view := false
var _vehicle: Vehicle = null
var _vehicle_local_yaw := 0.0
var _aircraft_aim_world_direction := Vector3.FORWARD


func _ready() -> void:
	top_level = true
	# Weapon viewmodels update their ADS/recoil transforms at the default
	# priority. Run the camera afterward so grip-driven paws use this frame's
	# weapon pose instead of trailing it by one render frame.
	process_priority = 10
	# The camera is intentionally render-frame driven. Read the player's
	# interpolated pose below instead of interpolating this hierarchy twice.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_pitch_node = Node3D.new()
	add_child(_pitch_node)
	_arm = SpringArm3D.new()
	_arm.spring_length = THIRD_PERSON_ARM
	_arm.margin = 0.18
	var camera_shape := SphereShape3D.new()
	camera_shape.radius = 0.28
	_arm.shape = camera_shape
	_pitch_node.add_child(_arm)
	_camera_mount = Node3D.new()
	_arm.add_child(_camera_mount)
	_cam = Camera3D.new()
	_cam.fov = BASE_FOV
	_cam.near = 0.035
	_cam.position = Vector3(0, 0, 0.01)
	_camera_mount.add_child(_cam)
	_view_arms = FirstPersonArms.new()
	_view_arms.configure(target)
	_cam.add_child(_view_arms)
	if target:
		_arm.add_excluded_object(target.get_rid())
	_cam.current = true


func cam_basis() -> Basis:
	return _cam.global_transform.basis


func cam_pos() -> Vector3:
	return _cam.global_position


func snap_to_target() -> void:
	if not target:
		return
	var follow := _current_follow_target()
	var height := DEATH_FOLLOW_HEIGHT if _death_view \
		else (FIRST_PERSON_HEIGHT if first_person \
		else (FRONT_VIEW_HEIGHT if front_view else THIRD_PERSON_HEIGHT))
	global_position = follow.global_position + Vector3.UP * height
	reset_physics_interpolation()


func set_first_person(enabled: bool) -> void:
	set_view_mode(ViewMode.FIRST_PERSON if enabled else ViewMode.SHOULDER)


func set_view_mode(mode: int) -> void:
	preferred_view_mode = clampi(mode, ViewMode.SHOULDER, ViewMode.FRONT)
	preferred_first_person = preferred_view_mode == ViewMode.FIRST_PERSON
	if not aiming and not _death_view:
		_apply_view_mode(preferred_view_mode)


func _apply_first_person(enabled: bool) -> void:
	_apply_view_mode(ViewMode.FIRST_PERSON if enabled else ViewMode.SHOULDER)


func _apply_view_mode(mode: int) -> void:
	var was_cockpit := _vehicle_view and first_person \
		and is_instance_valid(_vehicle)
	var was_relative_cockpit := was_cockpit \
		and _vehicle.kind != Vehicle.Kind.JET
	var previous_look := _vehicle_relative_look_direction() \
		if was_relative_cockpit else _look_direction(false)
	view_mode = clampi(mode, ViewMode.SHOULDER, ViewMode.FRONT)
	first_person = view_mode == ViewMode.FIRST_PERSON
	front_view = view_mode == ViewMode.FRONT
	var relative_cockpit := _vehicle_view and first_person \
		and is_instance_valid(_vehicle) \
		and _vehicle.kind != Vehicle.Kind.JET
	if relative_cockpit and not was_relative_cockpit:
		_capture_vehicle_local_look(previous_look)
	elif was_relative_cockpit and not relative_cockpit:
		_set_look_direction(previous_look)
	var limits := pitch_limits()
	pitch = clampf(pitch, limits.x, limits.y)
	_arm.spring_length = FIRST_PERSON_ARM if first_person \
		else (FRONT_VIEW_ARM if front_view else THIRD_PERSON_ARM)
	if is_instance_valid(_camera_mount):
		_camera_mount.position = _mount_base_position()
	_arm.position = SHOULDER_OFFSET \
		if view_mode == ViewMode.SHOULDER else Vector3.ZERO
	if first_person:
		_cam.cull_mask &= ~MonkeyRig.LOCAL_BODY_VISUAL_LAYER
	else:
		_cam.cull_mask |= MonkeyRig.LOCAL_BODY_VISUAL_LAYER
	if target and target.has_method("set_first_person_weapons"):
		target.set_first_person_weapons(first_person, _cam)
	elif target and target.gun:
		target.gun.set_first_person_view(first_person, _cam)
	snap_to_target()
	if front_view or _death_view:
		_zero_movement_output()
	if was_cockpit and not first_person:
		# Cockpit mode writes a complete rolled/pitched root basis. Rebuild a
		# level orbit immediately so chase, front, and eventual on-foot views never
		# inherit the aircraft or bike horizon in their x/z Euler components.
		var orbit_yaw := yaw + (PI if front_view else 0.0)
		global_basis = Basis(Vector3.UP, orbit_yaw + _recoil_yaw)


func toggle_view() -> int:
	preferred_view_mode = (preferred_view_mode + 1) % 3
	preferred_first_person = preferred_view_mode == ViewMode.FIRST_PERSON
	if not aiming and not _death_view:
		_apply_view_mode(preferred_view_mode)
	return preferred_view_mode


func set_aiming(enabled: bool) -> void:
	if _death_view:
		return
	if aiming == enabled:
		return
	aiming = enabled
	_apply_view_mode(ViewMode.FIRST_PERSON if aiming else preferred_view_mode)
	# Input can fire in the physics tick before this node's next render update.
	# Clear movement immediately so the first scoped shot uses the same pristine
	# basis the player will see, not the previous frame's locomotion tilt.
	if enabled and is_sniper_scoped():
		_zero_movement_output()


## The world stretches the far plane with player altitude (up to a 15-mile
## view). Fixture cameras manage their own far settings; this only drives the
## live gameplay camera.
func set_far_distance(distance: float) -> void:
	if _cam:
		_cam.far = clampf(distance, 1200.0, 30000.0)


func set_sensitivity(multiplier: float) -> void:
	sensitivity_multiplier = clampf(multiplier, 0.25, 2.5)


func effective_sensitivity() -> float:
	var scope_scale := 1.0 / scope_magnification() \
		if is_sniper_scoped() else 1.0
	return SENS * sensitivity_multiplier * (
		AIM_SENSITIVITY_MULTIPLIER if aiming else 1.0) * scope_scale


func is_sniper_scoped() -> bool:
	return aiming and target and target.active_weapon is SniperRifle \
		and not target.is_weapon_stowed()


func scope_magnification() -> float:
	return target.sniper.magnification() \
		if is_sniper_scoped() and target.sniper else 1.0


func sniper_scope_fov() -> float:
	# Preserve the same angular relationship as an optical magnifier instead of
	# treating the three zoom settings as arbitrary FOV presets.
	var half_base := deg_to_rad(FIRST_PERSON_FOV * 0.5)
	return clampf(rad_to_deg(2.0 * atan(tan(half_base) /
		scope_magnification())), 7.5, FIRST_PERSON_FOV)


func on_land(impact: float) -> void:
	var strength := clampf((impact - 2.0) / 24.0, 0.0, 1.0)
	_trauma = maxf(_trauma, strength)
	# A short critically damped dip reads as body weight much more clearly than
	# shake alone. Accumulation is capped so repeated contacts cannot ratchet the
	# camera through the floor or make a high-magnification view uncomfortable.
	_landing_velocity = maxf(_landing_velocity - strength * 0.62, -0.85)
	_landing_pitch_velocity = minf(
		_landing_pitch_velocity + strength * 0.34, 0.48)


func on_hit(amount: float, impulse: Vector3) -> void:
	var strength := clampf(amount / 45.0, 0.22, 1.0)
	_hit_trauma = maxf(_hit_trauma, strength)
	_trauma = maxf(_trauma, strength * 0.62)
	if impulse.length_squared() > 0.01:
		var incoming := impulse.normalized()
		_recoil_yaw_velocity -= cam_basis().x.dot(incoming) * strength * 0.24
		_recoil_pitch_velocity += cam_basis().y.dot(incoming) * strength * 0.16


func on_headshot() -> void:
	# A head impact has a deliberately readable backward snap in both camera
	# modes. The same spring that handles weapon recoil brings it home smoothly.
	var view_scale := 1.0 if first_person else 0.82
	var kick := deg_to_rad(12.5) * view_scale
	_recoil_pitch = clampf(_recoil_pitch - kick, -0.34, 0.0)
	_recoil_pitch_velocity -= kick * 2.1
	_recoil_roll += deg_to_rad(2.4) * view_scale
	_recoil_back = minf(_recoil_back + 0.065 * view_scale, 0.14)
	_hit_trauma = maxf(_hit_trauma, 0.92)
	_trauma = maxf(_trauma, 0.72)


func begin_death_view(follow_target: Node3D) -> void:
	_death_view = true
	_death_follow_target = follow_target
	aiming = false
	_apply_view_mode(ViewMode.SHOULDER)
	_arm.spring_length = DEATH_VIEW_ARM
	snap_to_target()


## Chase/cockpit camera while the monkey drives. C still cycles views; the
## follow target, arm length, FOV speed scaling, and shake all come from the
## vehicle so a motorcycle feels tight and a jet reads its 700 mph.
func begin_vehicle_view(v: Vehicle) -> void:
	# ADS temporarily forces first person. Restore the player's actual preference
	# before declaring a vehicle view; otherwise releasing aim cannot undo the
	# stale temporary cockpit because aiming has already been cleared.
	aiming = false
	_apply_view_mode(preferred_view_mode)
	_vehicle = v
	_vehicle_view = true
	var vehicle_basis := v.get_global_transform_interpolated().basis
	# A jet's pursuit controller consumes the camera aim immediately. Start it
	# on the aircraft nose instead of inheriting an unrelated on-foot/selfie aim
	# that can command a violent turn during the takeoff roll.
	if v.kind == Vehicle.Kind.JET:
		_aircraft_aim_world_direction = v.global_basis.z.normalized()
		_set_look_direction(vehicle_basis.z)
	else:
		# Ground and water cockpits use vehicle-relative freelook. Center the local
		# view down the machine on entry and seed the chase orbit from its heading.
		var flat_forward := Vector3(vehicle_basis.z.x, 0.0, vehicle_basis.z.z)
		if flat_forward.length_squared() > 0.001:
			_set_look_direction(flat_forward.normalized())
		_vehicle_local_yaw = 0.0
		pitch = 0.0
	_reset_movement_camera()
	_arm.spring_length = v.camera_distance
	snap_to_target()


func end_vehicle_view() -> void:
	if not _vehicle_view:
		return
	if _is_relative_vehicle_cockpit():
		# Preserve the last local freelook as a world-space on-foot heading.
		_set_look_direction(_vehicle_relative_look_direction())
	_vehicle_view = false
	_vehicle = null
	_aircraft_aim_world_direction = Vector3.FORWARD
	_zero_movement_output()
	_apply_view_mode(preferred_view_mode)
	var orbit_yaw := yaw + (PI if front_view else 0.0)
	global_basis = Basis(Vector3.UP, orbit_yaw + _recoil_yaw)
	_last_velocity = target.velocity if target else Vector3.ZERO


## World-space direction the camera looks along (the jet's pursuit stick).
func aim_direction() -> Vector3:
	if is_instance_valid(_cam):
		return -_cam.global_transform.basis.z
	return Vector3.FORWARD


## Stable piloting aim, independent of camera-only presentation. In particular,
## FRONT adds PI to the rendered orbit but must never reverse a jet's controls.
func vehicle_aim_direction() -> Vector3:
	if not _vehicle_view:
		return aim_direction()
	if _is_aircraft_vehicle_view():
		return _aircraft_control_aim_direction()
	if _is_relative_vehicle_cockpit():
		return _vehicle_relative_look_direction()
	return _look_direction(false)


## Read-only HUD/test view of the same radial input used by flight control.
## Screen coordinates are intentional: +x is right and +y is down.
func aircraft_aim_normalized() -> Vector2:
	return _aircraft_offset_for_direction(_aircraft_aim_world_direction) \
		if _is_aircraft_vehicle_view() else Vector2.ZERO


func aircraft_aim_limit_radians() -> float:
	return AIRCRAFT_AIM_CONE_RADIANS


func center_aircraft_aim() -> void:
	if _is_aircraft_vehicle_view():
		_aircraft_aim_world_direction = _vehicle.global_basis.z.normalized()
	else:
		_aircraft_aim_world_direction = Vector3.FORWARD


## Arrow-assisted pitch owns only the vertical channel. Keep any horizontal
## mouse pursuit command so Up/Down can still be combined with a deliberate
## heading change without the dot snapping sideways to centre.
func center_aircraft_pitch_aim() -> void:
	if not _is_aircraft_vehicle_view():
		return
	var current_offset := aircraft_aim_normalized()
	_aircraft_aim_world_direction = _aircraft_direction_from_offset(
		Vector2(current_offset.x, 0.0))


func _is_aircraft_vehicle_view() -> bool:
	return _vehicle_view and is_instance_valid(_vehicle) \
		and _vehicle.kind == Vehicle.Kind.JET


func _aircraft_control_aim_direction() -> Vector3:
	if not is_instance_valid(_vehicle):
		return _look_direction(false)
	return _aircraft_direction_from_offset(
		_aircraft_offset_for_direction(_aircraft_aim_world_direction))


## Mode-matching view frame used by both flight control and the HUD dot. Chase
## view is horizon-stabilized; cockpit view uses the jet's rolled up axis so a
## screen-right dot still means screen-right while banked or inverted.
## Basis +X/+Y are screen right/up and -Z is straight through the jet's nose.
func _aircraft_control_basis() -> Basis:
	# Flight control runs in the physics tick, so use the current rigid-body basis
	# here. Render interpolation is reserved for the camera presentation below;
	# feeding its one-tick-old frame back into physics causes lag at high roll rate.
	var vehicle_basis := _vehicle.global_basis
	var forward := vehicle_basis.z.normalized()
	var reference_up := vehicle_basis.y.normalized() \
		if first_person and not front_view else Vector3.UP
	if absf(forward.dot(reference_up)) > 0.97:
		reference_up = vehicle_basis.y.normalized()
	if absf(forward.dot(reference_up)) > 0.97:
		reference_up = vehicle_basis.x.normalized()
	return Basis.looking_at(forward, reference_up)


func _aircraft_offset_for_direction(world_direction: Vector3) -> Vector2:
	if not is_instance_valid(_vehicle) \
			or world_direction.length_squared() < 0.001:
		return Vector2.ZERO
	var local_direction := (_aircraft_control_basis().inverse() \
		* world_direction.normalized()).normalized()
	var yaw_angle := atan2(local_direction.x, -local_direction.z)
	var pitch_angle := atan2(local_direction.y,
		Vector2(local_direction.x, local_direction.z).length())
	return (Vector2(yaw_angle, -pitch_angle) \
		/ AIRCRAFT_AIM_CONE_RADIANS).limit_length(1.0)


func _aircraft_direction_from_offset(next_offset: Vector2) -> Vector3:
	var offset := next_offset.limit_length(1.0)
	var yaw_angle := offset.x * AIRCRAFT_AIM_CONE_RADIANS
	var pitch_angle := -offset.y * AIRCRAFT_AIM_CONE_RADIANS
	var pitch_cosine := cos(pitch_angle)
	var camera_local_direction := Vector3(sin(yaw_angle) * pitch_cosine,
		sin(pitch_angle), -cos(yaw_angle) * pitch_cosine)
	return (_aircraft_control_basis() * camera_local_direction).normalized()


func _look_direction(include_front: bool) -> Vector3:
	var look_yaw := yaw + (PI if include_front else 0.0)
	var cp := cos(pitch)
	return Vector3(-sin(look_yaw) * cp, sin(pitch),
		-cos(look_yaw) * cp).normalized()


func _is_relative_vehicle_cockpit() -> bool:
	return _vehicle_view and first_person and is_instance_valid(_vehicle) \
		and _vehicle.kind != Vehicle.Kind.JET


func _vehicle_relative_look_direction() -> Vector3:
	if not is_instance_valid(_vehicle):
		return _look_direction(false)
	var cp := cos(pitch)
	var local_direction := Vector3(-sin(_vehicle_local_yaw) * cp,
		sin(pitch), cos(_vehicle_local_yaw) * cp)
	return (_vehicle.get_global_transform_interpolated().basis \
		* local_direction).normalized()


func _capture_vehicle_local_look(world_direction: Vector3) -> void:
	if not is_instance_valid(_vehicle) or world_direction.length_squared() < 0.001:
		return
	var vehicle_basis := _vehicle.get_global_transform_interpolated().basis
	var local_direction := (vehicle_basis.inverse() \
		* world_direction.normalized()).normalized()
	_vehicle_local_yaw = atan2(-local_direction.x, local_direction.z)
	pitch = asin(clampf(local_direction.y, -1.0, 1.0))


func _set_look_direction(direction: Vector3) -> void:
	if direction.length_squared() < 0.001:
		return
	var normalized := direction.normalized()
	yaw = atan2(-normalized.x, -normalized.z)
	var limits := pitch_limits()
	pitch = clampf(asin(clampf(normalized.y, -1.0, 1.0)), limits.x, limits.y)


func end_death_view() -> void:
	if not _death_view:
		return
	_death_view = false
	_death_follow_target = null
	_apply_view_mode(preferred_view_mode)
	_last_velocity = Vector3.ZERO


func pitch_limits() -> Vector2:
	return Vector2(FIRST_PERSON_PITCH_MIN, FIRST_PERSON_PITCH_MAX) \
		if first_person else Vector2(THIRD_PERSON_PITCH_MIN, THIRD_PERSON_PITCH_MAX)


func apply_look(relative: Vector2) -> void:
	var look_sensitivity := effective_sensitivity()
	if _is_aircraft_vehicle_view():
		# FRONT deliberately hides the flight cursor, so mouse motion there must not
		# silently change a control target the player cannot see.
		if front_view:
			return
		# Mouse travel moves a fixed world pursuit point inside the HUD circle.
		# Diagonal input shares the same radial maximum as horizontal/vertical;
		# as the jet catches the point, its displayed offset moves back to centre.
		var normalized_delta := relative * look_sensitivity \
			/ AIRCRAFT_AIM_CONE_RADIANS
		var next_offset := (aircraft_aim_normalized() \
			+ normalized_delta).limit_length(1.0)
		_aircraft_aim_world_direction = _aircraft_direction_from_offset(next_offset)
		return
	var limits := pitch_limits()
	if _is_relative_vehicle_cockpit():
		_vehicle_local_yaw = wrapf(_vehicle_local_yaw \
			- relative.x * look_sensitivity, -PI, PI)
	else:
		yaw -= relative.x * look_sensitivity
	pitch = clampf(pitch - relative.y * look_sensitivity, limits.x, limits.y)


func add_weapon_recoil(strength: float) -> void:
	var view_scale := 1.0 if first_person else 0.72
	var kick := deg_to_rad(1.35) * strength * view_scale
	_recoil_index += 1
	var side := sin(float(_recoil_index) * 2.39996)
	_recoil_pitch = clampf(_recoil_pitch - kick, -0.14, 0.0)
	_recoil_yaw = clampf(_recoil_yaw + side * kick * 0.24, -0.045, 0.045)
	_recoil_roll = clampf(_recoil_roll + side * kick * 0.30, -0.055, 0.055)
	_recoil_pitch_velocity -= kick * 2.4
	_recoil_back = minf(_recoil_back + 0.018 * strength * view_scale, 0.105)
	_recoil_shake = maxf(_recoil_shake,
		clampf(strength * 0.22 * view_scale, 0.05, 0.72))


func _input(e: InputEvent) -> void:
	# _input (not _unhandled_input): captured-mouse look must never be starved
	# by a Control that happens to sit under the centered cursor
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		apply_look(e.relative)
	elif e.is_action_pressed("aim") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		set_aiming(true)
	elif e.is_action_released("aim"):
		set_aiming(false)


func _process(dt: float) -> void:
	if not target:
		return
	if _death_view and not is_instance_valid(_death_follow_target):
		_death_follow_target = null
	if aiming and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			and not (target and target.test_mode):
		set_aiming(false)
	_advance_recoil(dt)
	if _vehicle_view and not is_instance_valid(_vehicle):
		end_vehicle_view()
	var follow := _current_follow_target()
	var target_pos: Vector3 = follow.get_global_transform_interpolated().origin
	var motion_velocity: Vector3 = target.velocity
	var grounded: bool = target.is_on_floor()
	if _death_view:
		grounded = false
		if follow is RigidBody3D:
			motion_velocity = follow.linear_velocity
	elif _vehicle_view:
		grounded = true
		motion_velocity = _vehicle.linear_velocity
	# Unlike on-foot freelook, the aircraft camera follows the airframe while
	# the bounded HUD dot owns mouse steering. The chase view is horizon-stable;
	# cockpit mode applies the jet's real roll below.
	if _is_aircraft_vehicle_view():
		var aircraft_forward := _vehicle.get_global_transform_interpolated() \
			.basis.z.normalized()
		# Retain the last heading through a vertical loop instead of letting atan2
		# flip the chase camera by 180 degrees when horizontal length approaches 0.
		if Vector2(aircraft_forward.x, aircraft_forward.z).length_squared() > 0.0004:
			yaw = atan2(-aircraft_forward.x, -aircraft_forward.z)
		pitch = clampf(asin(clampf(aircraft_forward.y, -1.0, 1.0)),
			-CAMERA_PITCH_LIMIT, CAMERA_PITCH_LIMIT)
	var sp: float = motion_velocity.length()
	var height := DEATH_FOLLOW_HEIGHT if _death_view \
		else (FIRST_PERSON_HEIGHT if first_person \
		else (FRONT_VIEW_HEIGHT if front_view else THIRD_PERSON_HEIGHT))
	var follow_rate := 30.0 if first_person else 22.0
	if _vehicle_view:
		# The vehicle supplies its own camera geometry: cockpit/helmet height
		# in first person, a taller chase pivot otherwise.
		if first_person:
			var head := follow.get_global_transform_interpolated() \
				* _vehicle.fp_camera_offset
			global_position = global_position.lerp(head,
				1.0 - exp(-34.0 * dt))
			height = 0.0
		else:
			height = _vehicle.camera_height
			global_position = global_position.lerp(
				target_pos + Vector3.UP * height,
				1.0 - exp(-follow_rate * dt))
	else:
		global_position = global_position.lerp(
			target_pos + Vector3.UP * height, 1.0 - exp(-follow_rate * dt))
	var orbit_yaw := yaw + (PI if front_view else 0.0)
	var cockpit_view := _vehicle_view and first_person \
		and is_instance_valid(_vehicle)
	if cockpit_view:
		# Jets keep a world-space pursuit sightline; ground and water vehicles use
		# the vehicle-relative freelook direction built above. Both inherit the
		# machine's up axis so chassis roll and pitch remain readable.
		var vehicle_basis := _vehicle.get_global_transform_interpolated().basis
		# The dot must roam around a fixed forward sight picture, so a jet cockpit
		# looks through the nose rather than turning the camera toward the dot.
		var look_direction := vehicle_basis.z.normalized() \
			if _is_aircraft_vehicle_view() else vehicle_aim_direction()
		var cockpit_up := vehicle_basis.y.normalized()
		if absf(look_direction.dot(cockpit_up)) > 0.97:
			cockpit_up = vehicle_basis.x.normalized()
		global_basis = Basis.looking_at(look_direction, cockpit_up)
	else:
		# Assign the whole basis, not only rotation.y: the prior cockpit frame may
		# have left full vehicle pitch/roll on this top-level camera root.
		global_basis = Basis(Vector3.UP, orbit_yaw + _recoil_yaw)
	_advance_movement_camera(dt, motion_velocity, grounded, orbit_yaw)
	_pitch_node.rotation.x = clampf(
		_recoil_pitch if cockpit_view else pitch + _recoil_pitch,
		-CAMERA_PITCH_LIMIT, CAMERA_PITCH_LIMIT)

	var fov_speed_scale := 36.0
	if _vehicle_view and is_instance_valid(_vehicle):
		fov_speed_scale = _vehicle.speed_for_max_fov
	var t := clampf(sp / fov_speed_scale, 0.0, 1.0)
	var sniper_scoped := is_sniper_scoped()
	var base_fov := sniper_scope_fov() if sniper_scoped else (
		AIM_FOV if aiming else (FIRST_PERSON_FOV if first_person else BASE_FOV))
	var speed_fov := base_fov if sniper_scoped else (
		AIM_FOV + 7.0 if aiming else MAX_FOV)
	_cam.fov = lerpf(_cam.fov, lerpf(base_fov, speed_fov, t),
		1.0 - exp(-6.0 * dt))
	var desired_arm := THIRD_PERSON_ARM
	if _death_view:
		desired_arm = DEATH_VIEW_ARM
	elif front_view:
		desired_arm = FRONT_VIEW_ARM
	elif first_person:
		desired_arm = FIRST_PERSON_ARM
	elif _vehicle_view and is_instance_valid(_vehicle):
		desired_arm = _vehicle.camera_distance * lerpf(1.0, 1.3, t)
	else:
		desired_arm = lerpf(THIRD_PERSON_ARM, THIRD_PERSON_SPEED_ARM, t)
	var arm_rate := 24.0 if first_person else 4.0
	_arm.spring_length = lerpf(_arm.spring_length, desired_arm,
		1.0 - exp(-arm_rate * dt))
	var desired_shoulder := SHOULDER_OFFSET \
		if view_mode == ViewMode.SHOULDER and not _death_view else Vector3.ZERO
	_arm.position = _arm.position.lerp(desired_shoulder,
		1.0 - exp(-12.0 * dt))

	_cam.rotation.z = lerpf(_cam.rotation.z, _recoil_roll,
		1.0 - exp(-12.0 * dt))
	_cam.position.z = 0.01 + _recoil_back

	_update_camera_shake(dt, sniper_scoped)
	if _view_arms:
		var melee_view: bool = target.melee_mode
		var healing_view: bool = target.has_method("is_healing") \
			and target.is_healing()
		var weapon_visually_stowed: bool = target.is_weapon_stowed()
		if target.has_method("is_weapon_visually_stowed"):
			weapon_visually_stowed = target.is_weapon_visually_stowed()
		var show_weapon_arms: bool = first_person and target.active_weapon \
			and not weapon_visually_stowed and not is_sniper_scoped()
		_view_arms.visible = first_person \
			and (healing_view or melee_view or show_weapon_arms)
		if first_person and healing_view:
			_view_arms.update_bandage_pose(dt, target.bandage_progress(), sp,
				grounded)
		elif first_person and melee_view:
			_view_arms.update_melee_pose(dt,
				target.melee_attack_remaining > 0.0,
				target.melee_attack_progress(), target.melee_attack_combo,
				sp, grounded)
		elif show_weapon_arms:
			_view_arms.update_pose(dt, target.active_weapon, aiming, sp, grounded)


## Compose locomotion, inertia and traversal-specific motion on the mount below
## the collision-aware spring arm. The actual look angles and weapon recoil stay
## on their existing nodes, so every layer can settle independently.
func _advance_movement_camera(dt: float, motion_velocity: Vector3,
		grounded: bool, orbit_yaw: float) -> void:
	var safe_dt := minf(maxf(dt, 0.0), 0.10)
	if safe_dt <= 0.0:
		return
	if _vehicle_view and is_instance_valid(_vehicle):
		_advance_vehicle_camera(safe_dt)
		return
	var sniper_scoped := is_sniper_scoped()
	var state: int = int(target.state) if target else 0
	var swimming := state == PLAYER_STATE_SWIM
	var swinging := state == PLAYER_STATE_SWING
	var airborne := state == PLAYER_STATE_AIR and not grounded
	var ground_motion := grounded and not swimming and not swinging
	var horizontal_speed := Vector2(motion_velocity.x,
		motion_velocity.z).length()
	var speed_weight := clampf((horizontal_speed - 0.35) / 12.65, 0.0, 1.0)
	_motion_t = fmod(_motion_t + safe_dt * lerpf(4.8, 8.6,
		clampf(horizontal_speed / 13.0, 0.0, 1.0)), TAU * 64.0)
	if ground_motion and horizontal_speed > 0.35:
		_bob_t = fmod(_bob_t + safe_dt * lerpf(7.0, 12.8,
			clampf(horizontal_speed / 13.0, 0.0, 1.0)), TAU * 64.0)

	# Derive acceleration in the yaw frame, rejecting hitches and teleport-like
	# velocity jumps before they reach the camera. The low pass then gives starts,
	# stops and direction changes a small sense of inertia without steering aim.
	var acceleration := (motion_velocity - _last_velocity) / maxf(safe_dt, 0.001)
	_last_velocity = motion_velocity
	acceleration = acceleration.limit_length(MAX_CAMERA_ACCELERATION)
	var local_basis := Basis(Vector3.UP, -orbit_yaw)
	var local_velocity := local_basis * motion_velocity
	var local_acceleration := local_basis * acceleration
	var desired_acceleration_offset := Vector3(
		clampf(-local_acceleration.x * 0.00042, -0.028, 0.028),
		clampf(-acceleration.y * 0.00016, -0.014, 0.014),
		clampf(local_acceleration.z * 0.00028, -0.022, 0.022))
	_motion_position = _motion_position.lerp(desired_acceleration_offset,
		1.0 - exp(-9.0 * safe_dt))
	_motion_roll = lerpf(_motion_roll,
		clampf(-local_velocity.x * 0.0045, -0.045, 0.045),
		1.0 - exp(-7.0 * safe_dt))
	_motion_pitch = lerpf(_motion_pitch,
		clampf(-local_acceleration.z * 0.00030, -0.026, 0.026),
		1.0 - exp(-9.0 * safe_dt))
	_motion_yaw = lerpf(_motion_yaw,
		clampf(-local_acceleration.x * 0.00016, -0.012, 0.012),
		1.0 - exp(-10.0 * safe_dt))

	var desired_position := _motion_position
	var desired_rotation := Vector3(_motion_pitch, _motion_yaw, _motion_roll)

	# Grounded view bob uses a two-step vertical rhythm and one-step lateral
	# weight shift. Galloping gains a little more weight but stays well inside the
	# same comfort envelope.
	if ground_motion:
		var gallop_scale := 1.0
		if target and target.has_method("is_all_fours") and target.is_all_fours():
			gallop_scale = 1.22
		var vertical_step := -cos(_bob_t * 2.0)
		var lateral_step := sin(_bob_t)
		desired_position += Vector3(
			lateral_step * 0.014,
			vertical_step * 0.021,
			0.0) * speed_weight * gallop_scale
		desired_rotation += Vector3(
			sin(_bob_t * 2.0 + 0.35) * 0.0065,
			lateral_step * 0.0025,
			lateral_step * 0.010) * speed_weight * gallop_scale

	# Slow breathing prevents a perfectly static camera from feeling mounted on
	# a tripod. It vanishes with the rest of the movement layer in sniper ADS.
	var idle_weight := 1.0 - speed_weight * 0.72
	desired_position.y += sin(_motion_t * 0.48) * 0.0026 * idle_weight
	desired_rotation.x += sin(_motion_t * 0.48 + 0.8) * 0.0015 * idle_weight
	desired_rotation.z += sin(_motion_t * 0.36) * 0.0012 * idle_weight

	# Rising and falling move the camera slightly opposite travel, selling mass
	# without obscuring the landing point or forcing a horizon roll.
	if airborne:
		var vertical_air := clampf(motion_velocity.y / 32.0, -1.0, 1.0)
		desired_position += Vector3(0.0, -vertical_air * 0.018,
			absf(vertical_air) * 0.010)
		desired_rotation += Vector3(-vertical_air * 0.018, 0.0,
			sin(_motion_t * 0.44) * 0.004)

	# A vine swing is a pendulum: bank into tangential travel, let the camera lag
	# laterally, and add a restrained vertical pitch. Limits remain below the old
	# one-piece bank while the combined motion reads more naturally.
	if swinging:
		var swing_roll_limit := 0.17 if first_person else 0.13
		desired_position += Vector3(
			clampf(-local_velocity.x * 0.0022, -0.055, 0.055),
			clampf(-motion_velocity.y * 0.0012, -0.030, 0.030), 0.0)
		desired_rotation += Vector3(
			clampf(motion_velocity.y * 0.0014, -0.032, 0.032),
			clampf(-local_velocity.x * 0.00065, -0.022, 0.022),
			clampf(-local_velocity.x * (0.007 if first_person else 0.005),
				-swing_roll_limit, swing_roll_limit))

	# Swimming has a slower heave and alternating stroke roll, distinct from
	# footsteps and from the faster vine pendulum.
	if swimming:
		var stroke_phase := _motion_t * 0.62
		desired_position += Vector3(cos(stroke_phase) * 0.010,
			sin(stroke_phase) * 0.018, 0.0)
		desired_rotation += Vector3(sin(stroke_phase * 2.0) * 0.008,
			cos(stroke_phase) * 0.005, sin(stroke_phase) * 0.018)

	_advance_landing_spring(safe_dt)
	desired_position.y += _landing_offset
	desired_rotation.x += _landing_pitch
	desired_position = _clamp_components(desired_position,
		MOVEMENT_POSITION_LIMIT)
	desired_rotation = _clamp_components(desired_rotation,
		MOVEMENT_ROTATION_LIMIT)

	var view_scale := 1.0 if first_person else 0.58
	if aiming:
		view_scale *= 0.30
	# Scope magnification must never amplify procedural drift. Hard-zeroing the
	# output also keeps the overlay's center dot identical to the shot ray. The
	# centered front/death cameras are composition views, so inherited gameplay
	# offsets are cleared there as well.
	if sniper_scoped or front_view or _death_view:
		_zero_movement_output()
		return
	# State-specific motion eases at the mount rather than appearing in one frame
	# when feet leave the ground, a vine is caught, or the monkey enters water.
	_applied_motion_position = _applied_motion_position.lerp(desired_position,
		1.0 - exp(-14.0 * safe_dt))
	_applied_motion_rotation = _applied_motion_rotation.lerp(desired_rotation,
		1.0 - exp(-12.0 * safe_dt))
	_movement_blend = lerpf(_movement_blend, view_scale,
		1.0 - exp(-8.0 * safe_dt))
	# SpringArm3D only places a direct Camera3D child at its collision-aware
	# endpoint. Our intermediate mount owns locomotion/recoil layers, so preserve
	# that endpoint explicitly and add the small procedural offset on top.
	_camera_mount.position = _mount_base_position() \
		+ _applied_motion_position * _movement_blend
	_camera_mount.rotation = _applied_motion_rotation * _movement_blend


func _advance_landing_spring(dt: float) -> void:
	var remaining := minf(maxf(dt, 0.0), 0.10)
	while remaining > 0.000001:
		var step := minf(remaining, 1.0 / 120.0)
		var offset_accel := -_landing_offset * 105.0 \
			- _landing_velocity * 18.5
		var pitch_accel := -_landing_pitch * 115.0 \
			- _landing_pitch_velocity * 19.5
		_landing_velocity += offset_accel * step
		_landing_pitch_velocity += pitch_accel * step
		_landing_offset = clampf(_landing_offset + _landing_velocity * step,
			-LANDING_POSITION_LIMIT, LANDING_POSITION_LIMIT)
		_landing_pitch = clampf(_landing_pitch \
			+ _landing_pitch_velocity * step,
			-LANDING_PITCH_LIMIT, LANDING_PITCH_LIMIT)
		remaining -= step
	if absf(_landing_offset) < 0.00001 \
			and absf(_landing_velocity) < 0.0001:
		_landing_offset = 0.0
		_landing_velocity = 0.0
	if absf(_landing_pitch) < 0.00001 \
			and absf(_landing_pitch_velocity) < 0.0001:
		_landing_pitch = 0.0
		_landing_pitch_velocity = 0.0


func _update_camera_shake(dt: float, sniper_scoped: bool) -> void:
	var safe_dt := minf(maxf(dt, 0.0), 0.25)
	_trauma = maxf(_trauma - safe_dt * 1.8, 0.0)
	_hit_trauma = maxf(_hit_trauma - safe_dt * 2.6, 0.0)
	_recoil_shake = maxf(_recoil_shake - safe_dt * 4.8, 0.0)
	_shake_t = fmod(_shake_t + safe_dt * 30.0, TAU * 64.0)
	# Projection offsets do not rotate the shot ray. Disable them through a
	# sniper optic so the drawn center dot cannot disagree with ballistics.
	if sniper_scoped:
		_cam.h_offset = 0.0
		_cam.v_offset = 0.0
		return
	var sh := _trauma * _trauma
	var hit_shake := _hit_trauma * _hit_trauma
	var fire_shake := _recoil_shake * _recoil_shake
	var aim_scale := 0.38 if aiming else 1.0
	_cam.h_offset = (sin(_shake_t * 1.3) * 0.25 * sh \
		+ sin(_shake_t * 2.7) * 0.10 * hit_shake \
		+ sin(_shake_t * 4.1) * 0.032 * fire_shake) * aim_scale
	_cam.v_offset = (cos(_shake_t) * 0.20 * sh \
		+ cos(_shake_t * 2.2) * 0.085 * hit_shake \
		+ cos(_shake_t * 3.7) * 0.028 * fire_shake) * aim_scale


static func _clamp_components(value: Vector3, limit: Vector3) -> Vector3:
	return Vector3(
		clampf(value.x, -limit.x, limit.x),
		clampf(value.y, -limit.y, limit.y),
		clampf(value.z, -limit.z, limit.z))


## Clears only traversal-driven motion; look direction, damage and weapon recoil
## are intentionally untouched. Besides making state changes easy to reason
## about, this gives deterministic diagnostics a clean starting pose.
## Vehicle-specific mount motion: engine rumble scaled by RPM and contact,
## banking with the machine's roll, and a small pitch under thrust/braking.
func _advance_vehicle_camera(dt: float) -> void:
	var v := _vehicle
	var rpm := v.engine.rpm_fraction()
	var aux := v.state_aux()
	_motion_t = fmod(_motion_t + dt * lerpf(6.0, 21.0, rpm), TAU * 64.0)
	var rumble := (0.0035 + rpm * 0.011) \
		* (0.4 if first_person else 1.0)
	var jitter := Vector3(
		sin(_motion_t * 5.1) * rumble,
		sin(_motion_t * 6.7 + 1.3) * rumble * 0.8,
		0.0)
	var accel := (v.linear_velocity - _last_velocity) / maxf(dt, 0.001)
	_last_velocity = v.linear_velocity
	var longitudinal := clampf(
		accel.dot(v.global_basis.z) / 45.0, -0.06, 0.06)
	# Cockpit orientation already uses the vehicle's full up axis; adding the
	# chase-camera bank again would double-roll the pilot's head.
	var bank := 0.0 if first_person else aux.y * v.camera_bank_factor
	if is_instance_valid(_camera_mount):
		_camera_mount.position = _mount_base_position() + jitter
		_camera_mount.rotation = _camera_mount.rotation.lerp(
			Vector3(longitudinal, 0.0, bank), 1.0 - exp(-8.0 * dt))
	if is_instance_valid(_cam):
		_cam.h_offset = 0.0
		_cam.v_offset = 0.0


func _reset_movement_camera() -> void:
	_motion_t = 0.0
	_bob_t = 0.0
	_motion_roll = 0.0
	_motion_pitch = 0.0
	_motion_yaw = 0.0
	_motion_position = Vector3.ZERO
	_applied_motion_position = Vector3.ZERO
	_applied_motion_rotation = Vector3.ZERO
	_movement_blend = 0.0
	_landing_offset = 0.0
	_landing_velocity = 0.0
	_landing_pitch = 0.0
	_landing_pitch_velocity = 0.0
	_last_velocity = target.velocity if target else Vector3.ZERO
	if is_instance_valid(_camera_mount):
		_camera_mount.position = _mount_base_position()
		_camera_mount.rotation = Vector3.ZERO


func _zero_movement_output() -> void:
	_movement_blend = 0.0
	_applied_motion_position = Vector3.ZERO
	_applied_motion_rotation = Vector3.ZERO
	if is_instance_valid(_camera_mount):
		_camera_mount.position = _mount_base_position()
		_camera_mount.rotation = Vector3.ZERO
	if is_instance_valid(_cam):
		_cam.h_offset = 0.0
		_cam.v_offset = 0.0


func _mount_base_position() -> Vector3:
	if first_person or not is_instance_valid(_arm):
		return Vector3.ZERO
	return Vector3(0.0, 0.0, _arm.get_hit_length())


func _advance_recoil(dt: float) -> void:
	# The recoil spring used to become unstable after a long render hitch (most
	# visibly while saving diagnostic PNGs). Advance it in fixed, bounded steps
	# so a dropped frame cannot fling the camera away from the sight picture.
	var remaining := minf(maxf(dt, 0.0), 0.25)
	while remaining > 0.000001:
		var step := minf(remaining, 1.0 / 120.0)
		var pitch_accel := -_recoil_pitch * 92.0 \
			- _recoil_pitch_velocity * 17.0
		var yaw_accel := -_recoil_yaw * 105.0 \
			- _recoil_yaw_velocity * 19.0
		var roll_accel := -_recoil_roll * 110.0 \
			- _recoil_roll_velocity * 20.0
		_recoil_pitch_velocity += pitch_accel * step
		_recoil_yaw_velocity += yaw_accel * step
		_recoil_roll_velocity += roll_accel * step
		_recoil_pitch += _recoil_pitch_velocity * step
		_recoil_yaw += _recoil_yaw_velocity * step
		_recoil_roll += _recoil_roll_velocity * step
		remaining -= step
	_recoil_back = move_toward(_recoil_back, 0.0,
		minf(maxf(dt, 0.0), 0.25) * 0.38)


func _flat_forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func front_subject_direction() -> Vector3:
	# Direction from the monkey toward the front camera. Gameplay code uses it
	# to keep the character facing the lens without aiming through itself.
	return _flat_forward()


func _current_follow_target() -> Node3D:
	if _death_view and is_instance_valid(_death_follow_target):
		return _death_follow_target
	if _vehicle_view and is_instance_valid(_vehicle):
		return _vehicle
	return target
