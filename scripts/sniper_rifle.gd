class_name SniperRifle
extends Node3D
## Five-round bolt-action precision rifle. It follows the same public lifecycle
## as BananaGun/PumpShotgun/SMG while exposing scope and ballistic constants for
## camera, HUD and projectile integration.

signal ammo_changed(ammo: int, reloading: bool)

const WEAPON_KIND := 3  # Must match Net.WEAPON_SNIPER when integrated.
const CAPACITY := 5
const TOTAL_MAGAZINES := 4
const DAMAGE := 85.0
const MUZZLE_SPEED := 215.0
const BALLISTIC_GRAVITY := 9.81  # Physical Earth gravity in metres per second squared.
const ZERO_DISTANCE := 75.0
const SCOPE_FOV_DEGREES := 24.0
const ZOOM_LEVELS := [2.5, 5.0, 10.0]
const FIRE_INTERVAL := 1.22
const BOLT_CYCLE_TIME := 0.82
const BOLT_SOUND_DELAY := 0.28
const RELOAD_TIME := 3.10
const CAMERA_RECOIL := 3.15

const VIEWMODEL_POSITION := Vector3(0.29, -0.27, -0.89)
const VIEWMODEL_ROTATION := Vector3(-0.025, -0.025, 0.012)
const VIEWMODEL_SCALE := Vector3.ONE * 0.44
const AIM_VIEWMODEL_POSITION := Vector3(0.0, -0.255, -0.82)
const AIM_VIEWMODEL_ROTATION := Vector3(-0.012, 0.0, 0.0)
const SWING_VIEWMODEL_POSITION := Vector3(0.155, -0.145, -0.93)
const SWING_VIEWMODEL_ROTATION := Vector3(-0.01, -0.015, -0.045)
const RELOAD_TOSS_START := Vector3(-0.52, -0.48, 0.25)
const RELOAD_CATCH := Vector3(-0.30, -0.02, -0.04)
const RELOAD_SPIN_AXIS := Vector3(0.64, 0.10, 0.76)

var actor: Node3D
var world: Node3D
var ammo := CAPACITY
var reserve_mags := TOTAL_MAGAZINES - 1
var cooldown := 0.0
var reload_remaining := 0.0
var recoil := 0.0
var muzzle: Marker3D
var primary_grip: Marker3D
var support_grip: Marker3D
var first_person_view := false
var zoom_index := 0

var _third_person_parent: Node
var _third_person_transform := Transform3D.IDENTITY
var _aim_blend := 0.0
var _swing_blend := 0.0
var _bolt_remaining := 0.0
var _bolt_group: Node3D
var _bolt_handle_grip: Marker3D
var _bolt_base_z := -0.04
var _installed_mag: Node3D
var _reload_mag: Node3D
var _magwell: Marker3D
var _ejection_port: Marker3D
var _reload_hand_grip: Marker3D
var _reload_visual_progress := 0.0
var _reload_previous_progress := 0.0
var _reload_display_progress := 0.0
var _reload_event_mask := 0
var reload_sequence := 0
var reload_event_count := 0


func configure(owner_actor: Node3D, owner_world: Node3D) -> void:
	actor = owner_actor
	world = owner_world


func _ready() -> void:
	# The long barrel's local -Z axis follows the monkey's forearm toward the paw.
	position = Vector3(0.0, -MonkeyRig.ARM_B, -0.045)
	rotation.x = -PI * 0.5
	scale = Vector3.ONE * 0.56

	var gunmetal := _material(Color(0.045, 0.055, 0.060), 0.25, 0.76)
	var steel := _material(Color(0.13, 0.15, 0.155), 0.24, 0.66)
	var black := _material(Color(0.018, 0.021, 0.024), 0.32, 0.58)
	var stock_material := _material(Color(0.18, 0.29, 0.13), 0.68, 0.05)
	var stock_light := _material(Color(0.30, 0.43, 0.20), 0.61, 0.04)
	var brass := _material(Color(0.76, 0.53, 0.12), 0.27, 0.55)
	var lens := _emissive_material(Color(0.045, 0.32, 0.39),
		Color(0.04, 0.34, 0.48), 0.55)

	var receiver := _box(Vector3(0.19, 0.17, 0.46), steel)
	receiver.position = Vector3(0.0, 0.015, -0.08)
	add_child(receiver)

	var chamber := _cylinder(0.072, 0.30, 12, gunmetal)
	chamber.rotation.x = PI * 0.5
	chamber.position = Vector3(0.0, 0.04, -0.37)
	add_child(chamber)
	var barrel := _cylinder(0.034, 1.10, 12, black)
	barrel.rotation.x = PI * 0.5
	barrel.position = Vector3(0.0, 0.045, -0.98)
	add_child(barrel)
	var barrel_band := _cylinder(0.050, 0.13, 10, gunmetal)
	barrel_band.rotation.x = PI * 0.5
	barrel_band.position = Vector3(0.0, 0.045, -0.55)
	add_child(barrel_band)

	# Compact muzzle brake with visible side ports.
	var brake := _cylinder(0.055, 0.18, 10, steel)
	brake.rotation.x = PI * 0.5
	brake.position = Vector3(0.0, 0.045, -1.61)
	add_child(brake)
	for side in [-1.0, 1.0]:
		for z_offset in [-0.045, 0.035]:
			var port := _box(Vector3(0.058, 0.034, 0.035), black)
			port.position = Vector3(side * 0.045, 0.045, -1.61 + z_offset)
			add_child(port)

	var grip := _box(Vector3(0.13, 0.29, 0.13), stock_material)
	grip.position = Vector3(0.0, -0.17, 0.12)
	grip.rotation.x = -0.24
	add_child(grip)
	var stock := _box(Vector3(0.20, 0.20, 0.58), stock_material)
	stock.position = Vector3(0.0, 0.005, 0.45)
	stock.rotation.x = 0.035
	add_child(stock)
	var cheek_rest := _box(Vector3(0.205, 0.075, 0.28), stock_light)
	cheek_rest.position = Vector3(0.0, 0.13, 0.38)
	add_child(cheek_rest)
	var butt_pad := _box(Vector3(0.22, 0.25, 0.07), black)
	butt_pad.position = Vector3(0.0, 0.005, 0.765)
	add_child(butt_pad)
	_magwell = Marker3D.new()
	_magwell.name = "MagazineWell"
	_magwell.position = Vector3(0.0, -0.16, -0.13)
	_magwell.rotation.x = -0.07
	add_child(_magwell)
	_installed_mag = WeaponFX.make_sniper_magazine()
	_installed_mag.name = "InstalledMagazine"
	_installed_mag.position = _magwell.position
	_installed_mag.rotation = _magwell.rotation
	add_child(_installed_mag)

	# Raised telescopic sight. The glowing blue glass remains readable at the
	# game's low-poly scale without pretending to be the actual scope overlay.
	var front_mount := _box(Vector3(0.075, 0.12, 0.045), gunmetal)
	front_mount.position = Vector3(0.0, 0.16, -0.31)
	add_child(front_mount)
	var rear_mount := _box(Vector3(0.075, 0.12, 0.045), gunmetal)
	rear_mount.position = Vector3(0.0, 0.16, 0.08)
	add_child(rear_mount)
	var scope_body := _cylinder(0.060, 0.62, 14, black)
	scope_body.rotation.x = PI * 0.5
	scope_body.position = Vector3(0.0, 0.245, -0.13)
	add_child(scope_body)
	var front_bell := _cylinder(0.082, 0.15, 14, gunmetal)
	front_bell.rotation.x = PI * 0.5
	front_bell.position = Vector3(0.0, 0.245, -0.505)
	add_child(front_bell)
	var rear_bell := _cylinder(0.072, 0.14, 14, gunmetal)
	rear_bell.rotation.x = PI * 0.5
	rear_bell.position = Vector3(0.0, 0.245, 0.235)
	add_child(rear_bell)
	var front_lens := _cylinder(0.068, 0.012, 14, lens)
	front_lens.rotation.x = PI * 0.5
	front_lens.position = Vector3(0.0, 0.245, -0.586)
	add_child(front_lens)
	var rear_lens := _cylinder(0.057, 0.012, 14, lens)
	rear_lens.rotation.x = PI * 0.5
	rear_lens.position = Vector3(0.0, 0.245, 0.311)
	add_child(rear_lens)
	var turret := _cylinder(0.042, 0.10, 10, brass)
	turret.position = Vector3(0.0, 0.335, -0.12)
	add_child(turret)

	# The bolt travels back and its handle lifts during the enforced fire delay.
	_bolt_group = Node3D.new()
	_bolt_group.position = Vector3(0.105, 0.07, _bolt_base_z)
	add_child(_bolt_group)
	var bolt_body := _cylinder(0.026, 0.25, 9, brass)
	bolt_body.rotation.x = PI * 0.5
	_bolt_group.add_child(bolt_body)
	var bolt_handle := _cylinder(0.020, 0.16, 8, steel)
	bolt_handle.rotation.z = PI * 0.5
	bolt_handle.position = Vector3(0.09, -0.01, 0.04)
	_bolt_group.add_child(bolt_handle)
	var bolt_knob := _sphere(0.041, black)
	bolt_knob.position = Vector3(0.18, -0.01, 0.04)
	_bolt_group.add_child(bolt_knob)
	_bolt_handle_grip = Marker3D.new()
	_bolt_handle_grip.name = "BoltReloadGrip"
	_bolt_handle_grip.position = Vector3(0.18, -0.01, 0.04)
	_bolt_handle_grip.rotation = Vector3(0.0, 0.0, -0.35)
	_bolt_group.add_child(_bolt_handle_grip)
	_ejection_port = Marker3D.new()
	_ejection_port.name = "EjectionPort"
	_ejection_port.position = Vector3(0.115, 0.095, -0.18)
	add_child(_ejection_port)

	muzzle = Marker3D.new()
	muzzle.position = Vector3(0.0, 0.045, -1.72)
	add_child(muzzle)
	primary_grip = Marker3D.new()
	primary_grip.name = "PrimaryGrip"
	primary_grip.position = Vector3(0.0, -0.17, 0.12)
	add_child(primary_grip)
	support_grip = Marker3D.new()
	support_grip.name = "SupportGrip"
	# The procedural monkey has compact 0.50 m arms. Keep the support hand on the
	# receiver/near fore-end so a two-handed pose is anatomically reachable.
	support_grip.position = Vector3(-0.30, -0.015, -0.10)
	add_child(support_grip)
	_reload_hand_grip = Marker3D.new()
	_reload_hand_grip.name = "ReloadHandGrip"
	add_child(_reload_hand_grip)


func tick(dt: float) -> void:
	cooldown = maxf(cooldown - dt, 0.0)
	_bolt_remaining = maxf(_bolt_remaining - dt, 0.0)
	recoil = move_toward(recoil, 0.0, dt * 4.6)
	if reload_remaining <= 0.0:
		return
	var previous := _reload_visual_progress
	_reload_previous_progress = previous
	reload_remaining = maxf(reload_remaining - dt, 0.0)
	var current := 1.0 if reload_remaining <= 0.0 \
		else 1.0 - reload_remaining / RELOAD_TIME
	_advance_reload_events(previous, current)
	_reload_visual_progress = current
	if reload_remaining > 0.0:
		return
	reserve_mags = maxi(reserve_mags - 1, 0)
	ammo = CAPACITY
	ammo_changed.emit(ammo, false)
	Sfx.play_at("reload_done", actor.global_position, -5.0, 0.88, 40.0)
	_finish_reload_visuals()


func try_fire(origin: Vector3, direction: Vector3) -> bool:
	if cooldown > 0.0 or reload_remaining > 0.0:
		return false
	if ammo <= 0:
		cooldown = 0.18
		Sfx.play_at("empty", actor.global_position, -6.0)
		return false

	ammo -= 1
	cooldown = FIRE_INTERVAL
	_bolt_remaining = BOLT_CYCLE_TIME
	recoil = 1.0
	ammo_changed.emit(ammo, false)
	var up := Vector3.UP
	var shot_gravity := BALLISTIC_GRAVITY
	if actor is MonkeyPlayer and is_instance_valid(actor.lunar_world):
		up = actor.up_direction
		shot_gravity = MoonWorld.LUNAR_GRAVITY
	var ballistic_direction := zeroed_direction(direction, shot_gravity, up)
	# Precision shots follow the optic's ballistic solution exactly. Inheriting
	# even a small share of rope velocity made the round drift outside the center
	# dot while the scope correctly advertised zero spread.
	var shot_velocity := ballistic_direction * MUZZLE_SPEED
	if Net.active and actor is MonkeyPlayer and actor.is_local:
		Net.fire_bullet(origin, shot_velocity, DAMAGE, true, true, WEAPON_KIND)
	else:
		if world and world.has_method("spawn_bullet"):
			world.spawn_bullet(actor, origin, shot_velocity, DAMAGE, true, WEAPON_KIND)
		Sfx.play_at("sniper", origin, 2.0, 1.0, 240.0)
		if world and world.has_method("spawn_muzzle_flash"):
			world.spawn_muzzle_flash(origin, ballistic_direction)
	_schedule_bolt_sound()
	return true


func play_remote_fire() -> void:
	# Replicas do not own ammunition, but the observed weapon still needs the
	# same recoil, bolt travel, cadence, and delayed mechanical report.
	cooldown = FIRE_INTERVAL
	_bolt_remaining = BOLT_CYCLE_TIME
	recoil = 1.0
	_schedule_bolt_sound()


func start_reload() -> bool:
	if reload_remaining > 0.0 or ammo >= CAPACITY or reserve_mags <= 0:
		return false
	reload_remaining = RELOAD_TIME
	cooldown = maxf(cooldown, 0.24)
	_bolt_remaining = 0.0
	_begin_reload_visuals()
	ammo_changed.emit(ammo, true)
	Sfx.play_at("sniper_reload", actor.global_position, -5.0, 0.96, 40.0)
	return true


func reload_progress() -> float:
	return 0.0 if reload_remaining <= 0.0 \
		else 1.0 - reload_remaining / RELOAD_TIME


func bolt_progress() -> float:
	return 1.0 if _bolt_remaining <= 0.0 \
		else 1.0 - _bolt_remaining / BOLT_CYCLE_TIME


func is_bolt_cycling() -> bool:
	return _bolt_remaining > 0.0


func magnification() -> float:
	return float(ZOOM_LEVELS[zoom_index])


## Advances 2.5x -> 5x -> 10x -> 2.5x and returns the selected value so the
## camera/HUD can apply it immediately without reading another property.
func cycle_zoom() -> float:
	zoom_index = (zoom_index + 1) % ZOOM_LEVELS.size()
	return magnification()


## Perspective-correct FOV for a requested unzoomed camera FOV.
func scope_fov(base_fov_degrees := 82.0) -> float:
	var half_angle := deg_to_rad(base_fov_degrees * 0.5)
	return rad_to_deg(2.0 * atan(tan(half_angle) / magnification()))


func reset_cylinder() -> void:
	ammo = CAPACITY
	reserve_mags = TOTAL_MAGAZINES - 1
	cooldown = 0.0
	reload_remaining = 0.0
	_bolt_remaining = 0.0
	recoil = 0.0
	zoom_index = 0
	_finish_reload_visuals()
	ammo_changed.emit(ammo, false)


func cancel_reload() -> void:
	if reload_remaining <= 0.0:
		return
	reload_remaining = 0.0
	_finish_reload_visuals()
	ammo_changed.emit(ammo, false)


func set_first_person_view(enabled: bool, view_parent: Node3D) -> void:
	if enabled == first_person_view:
		return
	first_person_view = enabled
	if enabled:
		_third_person_parent = get_parent()
		_third_person_transform = transform
		reparent(view_parent, false)
		position = VIEWMODEL_POSITION
		rotation = VIEWMODEL_ROTATION
		scale = VIEWMODEL_SCALE
	elif _third_person_parent and is_instance_valid(_third_person_parent):
		reparent(_third_person_parent, false)
		transform = _third_person_transform


func _process(dt: float) -> void:
	_reload_display_progress = _reload_visual_progress if dt <= 0.0 else \
		SatisfyingReload.interpolate_progress(_reload_previous_progress,
			_reload_visual_progress, Engine.get_physics_interpolation_fraction())
	_update_bolt_model()
	_update_reload_model()
	if not first_person_view:
		return
	var wants_aim: bool = actor is MonkeyPlayer and actor.cam and actor.cam.aiming
	_aim_blend = lerpf(_aim_blend, 1.0 if wants_aim else 0.0,
		1.0 - exp(-14.0 * dt))
	var wants_swing: bool = actor is MonkeyPlayer \
		and actor.state == MonkeyPlayer.S.SWING
	_swing_blend = lerpf(_swing_blend, 1.0 if wants_swing else 0.0,
		1.0 - exp(-11.0 * dt))
	var base_position := VIEWMODEL_POSITION.lerp(
		SWING_VIEWMODEL_POSITION, _swing_blend)
	var base_rotation := VIEWMODEL_ROTATION.lerp(
		SWING_VIEWMODEL_ROTATION, _swing_blend)
	base_position = base_position.lerp(AIM_VIEWMODEL_POSITION, _aim_blend)
	base_rotation = base_rotation.lerp(AIM_VIEWMODEL_ROTATION, _aim_blend)
	var rp := _reload_display_progress if reload_remaining > 0.0 else 0.0
	var reload_pose := SatisfyingReload.pulse(rp, 0.0, 0.21, 0.97)
	var catch_snap := SatisfyingReload.pulse(rp, 0.36, 0.45, 0.54)
	var bolt_flourish := SatisfyingReload.pulse(rp, 0.72, 0.83, 0.99)
	position = base_position + Vector3(-0.085, -0.03, 0.13) * reload_pose \
		+ Vector3(0.025, 0.025, -0.05) * catch_snap \
		+ Vector3(0.0, 0.03, 0.07) * bolt_flourish \
		+ Vector3(0.0, 0.018, recoil * 0.14)
	rotation = base_rotation + Vector3(-0.17, -0.34, 0.36) * reload_pose \
		+ Vector3(-0.09, 0.14, -0.20) * bolt_flourish \
		+ Vector3(recoil * 0.19, recoil * 0.018, recoil * 0.025)


func first_person_grip_transforms(view_space: Node3D) -> Array[Transform3D]:
	var to_view := view_space.global_transform.affine_inverse()
	var support := _reload_hand_grip if reload_remaining > 0.0 \
		and _reload_mag else support_grip
	return [
		to_view * primary_grip.global_transform,
		to_view * support.global_transform,
	]


func has_dynamic_reload_hand() -> bool:
	return reload_remaining > 0.0 and _reload_mag != null \
		and is_instance_valid(_reload_mag)


func add_reserve_ammo(rounds: int) -> int:
	var magazines := maxi(ceili(float(maxi(rounds, 0)) / CAPACITY), 0)
	var before := reserve_mags
	reserve_mags = mini(reserve_mags + magazines, 6)
	return (reserve_mags - before) * CAPACITY


func _begin_reload_visuals() -> void:
	reload_sequence += 1
	reload_event_count = 0
	_reload_event_mask = 0
	_reload_visual_progress = 0.0
	_reload_previous_progress = 0.0
	_reload_display_progress = 0.0
	if _reload_mag and is_instance_valid(_reload_mag):
		_reload_mag.queue_free()
	_reload_mag = WeaponFX.make_sniper_magazine()
	_reload_mag.name = "FlippedSniperMagazine"
	_reload_mag.visible = false
	add_child(_reload_mag)
	_reload_hand_grip.transform = support_grip.transform
	if _installed_mag:
		_installed_mag.visible = true


func _advance_reload_events(previous: float, current: float) -> void:
	_reload_event(previous, current, 0.07, 1, func():
		if _installed_mag:
			_installed_mag.visible = false
		_spawn_mag_debris()
		Sfx.play_at("mag_release", actor.global_position, -5.0, 0.78, 38.0)
	)
	_reload_event(previous, current, 0.19, 2, func():
		if _reload_mag:
			_reload_mag.visible = true
		Sfx.play_at("mag_toss", actor.global_position, -6.0, 0.84, 38.0)
	)
	_reload_event(previous, current, 0.43, 4, func():
		Sfx.play_at("mag_catch", actor.global_position, -4.0, 0.82, 38.0)
		if _reload_mag:
			WeaponFX.spawn_glint(get_tree().current_scene,
				_reload_mag.global_position, Color(0.18, 0.78, 1.0), 1.25)
	)
	_reload_event(previous, current, 0.68, 8, func():
		if _installed_mag:
			_installed_mag.visible = true
		if _reload_mag:
			_reload_mag.visible = false
		Sfx.play_at("mag_insert", actor.global_position, -3.0, 0.82, 40.0)
	)
	_reload_event(previous, current, 0.78, 16, func():
		Sfx.play_at("bolt_open", actor.global_position, -4.0, 0.82, 42.0)
	)
	_reload_event(previous, current, 0.94, 32, func():
		Sfx.play_at("bolt_close", actor.global_position, -3.0, 0.88, 42.0)
		WeaponFX.spawn_glint(get_tree().current_scene,
			_bolt_group.global_position, Color(0.12, 0.76, 1.0), 1.35)
	)


func _reload_event(previous: float, current: float, threshold: float,
		bit: int, callback: Callable) -> void:
	if (_reload_event_mask & bit) != 0 \
		or not SatisfyingReload.crossed(previous, current, threshold):
		return
	_reload_event_mask |= bit
	reload_event_count += 1
	callback.call()


func _update_reload_model() -> void:
	if reload_remaining <= 0.0 or not _reload_mag:
		return
	var p := _reload_display_progress
	var toss_start := Transform3D(Basis.IDENTITY, RELOAD_TOSS_START)
	var catch_basis := SatisfyingReload.trick_spin(
		1.0, 1.80, RELOAD_SPIN_AXIS)
	var catch_transform := Transform3D(catch_basis, RELOAD_CATCH)
	var bolt_local := global_transform.affine_inverse() \
		* _bolt_handle_grip.global_transform
	if p < 0.19:
		_reload_mag.visible = false
		_reload_hand_grip.transform = SatisfyingReload.arc_transform(
			support_grip.transform, toss_start, 0.055,
			SatisfyingReload.phase(p, 0.0, 0.19))
		return
	if p < 0.44:
		_reload_mag.visible = true
		var toss := SatisfyingReload.phase(p, 0.19, 0.44)
		_reload_mag.position = SatisfyingReload.arc(
			RELOAD_TOSS_START, RELOAD_CATCH,
			0.36, toss)
		_reload_mag.basis = SatisfyingReload.trick_spin(toss, 1.80,
			RELOAD_SPIN_AXIS)
		_reload_hand_grip.transform = _reload_mag.transform
	elif p < 0.68:
		_reload_mag.visible = true
		var insert := SatisfyingReload.phase(p, 0.44, 0.68)
		var drive := SatisfyingReload.overshoot(insert, 0.13)
		_reload_mag.position = SatisfyingReload.arc(
			RELOAD_CATCH, _magwell.position,
			0.10, drive)
		_reload_mag.basis = SatisfyingReload.slerp_basis(
			catch_transform.basis, _magwell.transform.basis, insert)
		_reload_hand_grip.transform = _reload_mag.transform
	else:
		_reload_mag.visible = false
		if p < 0.78:
			_reload_hand_grip.transform = SatisfyingReload.arc_transform(
				_magwell.transform, bolt_local, 0.060,
				SatisfyingReload.phase(p, 0.68, 0.78))
		elif p < 0.94:
			_reload_hand_grip.transform = bolt_local
		else:
			_reload_hand_grip.transform = SatisfyingReload.arc_transform(
				bolt_local, support_grip.transform, 0.045,
				SatisfyingReload.phase(p, 0.94, 1.0))


func _spawn_spent_casing(snapshot: Dictionary = {}) -> void:
	var parent: Node = world if world else get_tree().current_scene
	if not parent or not _ejection_port:
		return
	var ejection_transform: Transform3D = snapshot.get(
		"transform", _ejection_port.global_transform)
	var basis := ejection_transform.basis.orthonormalized()
	var inherited: Vector3 = snapshot.get("velocity",
		actor.velocity if actor is CharacterBody3D else Vector3.ZERO)
	WeaponFX.spawn_debris(parent, WeaponDebris.Kind.BRASS,
		ejection_transform,
		inherited * 0.28 + basis.x * 2.7 + basis.y * 1.25,
		Vector3(8.0, 13.0, -6.0), actor)


func _spawn_mag_debris() -> void:
	var parent: Node = world if world else get_tree().current_scene
	if not parent or not _magwell:
		return
	var basis := global_transform.basis.orthonormalized()
	var inherited: Vector3 = actor.velocity \
		if actor is CharacterBody3D else Vector3.ZERO
	WeaponFX.spawn_debris(parent, WeaponDebris.Kind.SNIPER_MAG,
		_magwell.global_transform,
		inherited * 0.34 + basis.x * 0.75 + Vector3.UP * 0.42,
		Vector3(-4.0, 2.0, 5.0), actor)


func _finish_reload_visuals() -> void:
	_reload_visual_progress = 0.0
	_reload_previous_progress = 0.0
	_reload_display_progress = 0.0
	_reload_event_mask = 0
	if _reload_hand_grip and support_grip:
		_reload_hand_grip.transform = support_grip.transform
	if _installed_mag:
		_installed_mag.visible = true
	if _reload_mag and is_instance_valid(_reload_mag):
		_reload_mag.queue_free()
	_reload_mag = null


## A conventional 75 m zero: the shot starts fractionally high, crosses the
## sight line at ZERO_DISTANCE, then develops readable drop at long range.
static func zeroed_direction(direction: Vector3,
		gravity_mps2: float = BALLISTIC_GRAVITY, up: Vector3 = Vector3.UP) -> Vector3:
	var aim := direction.normalized()
	var zero_time := ZERO_DISTANCE / MUZZLE_SPEED
	var lift_at_zero := 0.5 * gravity_mps2 * zero_time * zero_time
	return (aim + up.normalized() * (lift_at_zero / ZERO_DISTANCE)).normalized()


## Positive values are metres below the crosshair line; negative values are
## the small rise before the zero. Approximately 0.27 m at 100 m and 2.65 m at
## 200 m with the default 75 m zero.
static func drop_below_zero_at(distance: float,
		gravity_mps2: float = BALLISTIC_GRAVITY) -> float:
	var clamped_distance := maxf(distance, 0.0)
	var flight_time := clamped_distance / MUZZLE_SPEED
	var zero_lift_velocity := gravity_mps2 * ZERO_DISTANCE \
		/ (2.0 * MUZZLE_SPEED)
	return 0.5 * gravity_mps2 * flight_time * flight_time \
		- zero_lift_velocity * flight_time


func _update_bolt_model() -> void:
	if not _bolt_group:
		return
	if _bolt_remaining <= 0.0 and reload_remaining <= 0.0:
		_bolt_group.position.z = _bolt_base_z
		_bolt_group.rotation.z = 0.0
		return
	var lift := 0.0
	var rearward := 0.0
	if reload_remaining > 0.0:
		var reload_p := _reload_display_progress
		lift = SatisfyingReload.pulse(reload_p, 0.73, 0.79, 0.98)
		rearward = SatisfyingReload.pulse(reload_p, 0.77, 0.84, 0.95)
	else:
		var progress := bolt_progress()
		lift = smoothstep(0.02, 0.20, progress) \
			* (1.0 - smoothstep(0.72, 0.94, progress))
		rearward = smoothstep(0.17, 0.39, progress) \
			* (1.0 - smoothstep(0.58, 0.88, progress))
	_bolt_group.rotation.z = -lift * 0.72
	_bolt_group.position.z = _bolt_base_z + rearward * 0.22


func _schedule_bolt_sound() -> void:
	var snapshot := {
		"transform": _ejection_port.global_transform,
		"velocity": actor.velocity if actor is CharacterBody3D else Vector3.ZERO,
	}
	var timer := get_tree().create_timer(BOLT_SOUND_DELAY)
	timer.timeout.connect(func():
		if is_instance_valid(actor):
			Sfx.play_at("sniper_bolt", actor.global_position, -5.0, 1.0, 36.0)
			_spawn_spent_casing(snapshot))


static func _material(color: Color, roughness: float,
		metallic: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	return material


static func _emissive_material(color: Color, emission: Color,
		energy: float) -> StandardMaterial3D:
	var material := _material(color, 0.12, 0.34)
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = energy
	return material


static func _box(size: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.material_override = material
	return instance


static func _cylinder(radius: float, height: float, sides: int,
		material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = sides
	instance.mesh = mesh
	instance.material_override = material
	return instance


static func _sphere(radius: float, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	instance.mesh = mesh
	instance.material_override = material
	return instance
