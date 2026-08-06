class_name SMG
extends Node3D
## Fast automatic submachine gun with one loaded 20-round magazine and three
## spares (four magazines / 80 rounds in a fresh loadout).

signal ammo_changed(ammo: int, reloading: bool)

const CAPACITY := 20
const TOTAL_MAGAZINES := 4
const FIRE_INTERVAL := 0.075
const RELOAD_TIME := 2.05
const MUZZLE_SPEED := 105.0
const DAMAGE := 9.0
const CAMERA_RECOIL := 0.48

const VIEWMODEL_POSITION := Vector3(0.28, -0.235, -0.65)
const VIEWMODEL_ROTATION := Vector3(-0.055, -0.045, 0.02)
const VIEWMODEL_SCALE := Vector3.ONE * 0.55
const AIM_VIEWMODEL_POSITION := Vector3(0.0, -0.195, -0.60)
const AIM_VIEWMODEL_ROTATION := Vector3(-0.035, 0.0, 0.0)
const SWING_VIEWMODEL_POSITION := Vector3(0.15, -0.13, -0.72)
const SWING_VIEWMODEL_ROTATION := Vector3(-0.025, -0.02, -0.045)
const RELOAD_TOSS_START := Vector3(-0.50, -0.50, 0.17)
const RELOAD_CATCH := Vector3(-0.28, -0.04, -0.04)
const RELOAD_SPIN_AXIS := Vector3(0.82, 0.0, 0.34)

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

var _third_person_parent: Node
var _third_person_transform := Transform3D.IDENTITY
var _aim_blend := 0.0
var _swing_blend := 0.0
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
	position = Vector3(0, -MonkeyRig.ARM_B, -0.02)
	rotation.x = -PI * 0.5
	scale = Vector3.ONE * 0.66

	var dark := _material(Color(0.035, 0.045, 0.05), 0.31, 0.70)
	var steel := _material(Color(0.12, 0.145, 0.15), 0.27, 0.62)
	var green := _material(Color(0.24, 0.38, 0.16), 0.64, 0.08)
	var accent := _material(Color(0.95, 0.63, 0.08), 0.34, 0.34)

	var receiver := _box(Vector3(0.18, 0.18, 0.39), steel)
	receiver.position = Vector3(0, 0.015, -0.13)
	add_child(receiver)

	var barrel := _cylinder(0.038, 0.46, 10, dark)
	barrel.rotation.x = PI * 0.5
	barrel.position = Vector3(0, 0.055, -0.54)
	add_child(barrel)

	var shroud := _cylinder(0.062, 0.30, 10, green)
	shroud.rotation.x = PI * 0.5
	shroud.position = Vector3(0, 0.045, -0.40)
	add_child(shroud)

	_magwell = Marker3D.new()
	_magwell.name = "MagazineWell"
	_magwell.position = Vector3(0, -0.22, -0.10)
	_magwell.rotation.x = -0.13
	add_child(_magwell)
	_installed_mag = WeaponFX.make_smg_magazine()
	_installed_mag.name = "InstalledMagazine"
	_installed_mag.position = _magwell.position
	_installed_mag.rotation = _magwell.rotation
	add_child(_installed_mag)

	var grip := _box(Vector3(0.115, 0.25, 0.12), green)
	grip.position = Vector3(0, -0.15, 0.10)
	grip.rotation.x = -0.25
	add_child(grip)

	var stock := _box(Vector3(0.15, 0.14, 0.30), green)
	stock.position = Vector3(0, 0.0, 0.30)
	stock.rotation.x = 0.05
	add_child(stock)

	var front_sight := _box(Vector3(0.026, 0.065, 0.035), accent)
	front_sight.position = Vector3(0, 0.13, -0.66)
	add_child(front_sight)
	var rear_sight := _box(Vector3(0.07, 0.045, 0.035), accent)
	rear_sight.position = Vector3(0, 0.13, 0.01)
	add_child(rear_sight)

	muzzle = Marker3D.new()
	muzzle.position = Vector3(0, 0.055, -0.78)
	add_child(muzzle)
	primary_grip = Marker3D.new()
	primary_grip.name = "PrimaryGrip"
	primary_grip.position = Vector3(0, -0.15, 0.10)
	add_child(primary_grip)
	support_grip = Marker3D.new()
	support_grip.name = "SupportGrip"
	support_grip.position = Vector3(-0.15, 0.015, -0.40)
	add_child(support_grip)
	_ejection_port = Marker3D.new()
	_ejection_port.name = "EjectionPort"
	_ejection_port.position = Vector3(0.105, 0.055, -0.18)
	add_child(_ejection_port)
	_reload_hand_grip = Marker3D.new()
	_reload_hand_grip.name = "ReloadHandGrip"
	add_child(_reload_hand_grip)


func tick(dt: float) -> void:
	cooldown = maxf(cooldown - dt, 0.0)
	recoil = move_toward(recoil, 0.0, dt * 12.0)
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
	Sfx.play_at("reload_done", actor.global_position, -8.0, 1.04)
	_finish_reload_visuals()


func try_fire(origin: Vector3, direction: Vector3) -> bool:
	if cooldown > 0.0 or reload_remaining > 0.0:
		return false
	if ammo <= 0:
		cooldown = 0.16
		Sfx.play_at("empty", actor.global_position, -8.0)
		return false

	ammo -= 1
	cooldown = FIRE_INTERVAL
	recoil = 1.0
	ammo_changed.emit(ammo, false)
	_spawn_casing()
	var inherited: Vector3 = actor.velocity * 0.10 \
		if actor is CharacterBody3D else Vector3.ZERO
	var shot_velocity: Vector3 = direction.normalized() * MUZZLE_SPEED + inherited
	if Net.active and actor is MonkeyPlayer and actor.is_local:
		Net.fire_bullet(origin, shot_velocity, DAMAGE, false, true, Net.WEAPON_SMG)
	else:
		if world and world.has_method("spawn_bullet"):
			world.spawn_bullet(actor, origin, shot_velocity, DAMAGE, false,
				Net.WEAPON_SMG)
		Sfx.play_at("smg", origin, -4.0)
		if world and world.has_method("spawn_muzzle_flash"):
			world.spawn_muzzle_flash(origin, direction)
	return true


func start_reload() -> bool:
	if reload_remaining > 0.0 or ammo >= CAPACITY or reserve_mags <= 0:
		return false
	reload_remaining = RELOAD_TIME
	cooldown = maxf(cooldown, 0.16)
	_begin_reload_visuals()
	ammo_changed.emit(ammo, true)
	Sfx.play_at("reload_flourish", actor.global_position, -8.0, 0.94)
	return true


func reload_progress() -> float:
	return 0.0 if reload_remaining <= 0.0 \
		else 1.0 - reload_remaining / RELOAD_TIME


func reset_cylinder() -> void:
	ammo = CAPACITY
	reserve_mags = TOTAL_MAGAZINES - 1
	cooldown = 0.0
	reload_remaining = 0.0
	recoil = 0.0
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
	var cant := SatisfyingReload.pulse(rp, 0.0, 0.18, 0.93)
	var catch_snap := SatisfyingReload.pulse(rp, 0.40, 0.48, 0.57)
	var rack := SatisfyingReload.pulse(rp, 0.79, 0.87, 0.98)
	position = base_position + Vector3(0, 0.008, recoil * 0.065) \
		+ Vector3(-0.085, -0.03, 0.125) * cant \
		+ Vector3(0.025, 0.018, -0.05) * catch_snap \
		+ Vector3(0.0, 0.0, 0.07) * rack
	rotation = base_rotation + Vector3(
		recoil * 0.075, recoil * 0.012, recoil * 0.018) \
		+ Vector3(-0.16, -0.36, 0.40) * cant \
		+ Vector3(-0.05, 0.10, -0.18) * rack


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
	_reload_mag = WeaponFX.make_smg_magazine()
	_reload_mag.name = "FlippedMagazine"
	_reload_mag.visible = false
	add_child(_reload_mag)
	_reload_hand_grip.transform = support_grip.transform
	if _installed_mag:
		_installed_mag.visible = true


func _advance_reload_events(previous: float, current: float) -> void:
	_reload_event(previous, current, 0.08, 1, func():
		if _installed_mag:
			_installed_mag.visible = false
		_spawn_mag_debris()
		Sfx.play_at("mag_release", actor.global_position, -7.0, 0.88)
	)
	_reload_event(previous, current, 0.22, 2, func():
		if _reload_mag:
			_reload_mag.visible = true
		Sfx.play_at("mag_toss", actor.global_position, -7.0, 1.02)
	)
	_reload_event(previous, current, 0.46, 4, func():
		Sfx.play_at("mag_catch", actor.global_position, -6.0, 0.92)
		if _reload_mag:
			WeaponFX.spawn_glint(get_tree().current_scene,
				_reload_mag.global_position, Color(0.62, 1.0, 0.25))
	)
	_reload_event(previous, current, 0.72, 8, func():
		if _installed_mag:
			_installed_mag.visible = true
		if _reload_mag:
			_reload_mag.visible = false
		Sfx.play_at("mag_insert", actor.global_position, -5.0, 0.92)
	)
	_reload_event(previous, current, 0.86, 16, func():
		Sfx.play_at("charging_handle", actor.global_position, -5.0, 1.06)
		WeaponFX.spawn_glint(get_tree().current_scene,
			global_position, Color(0.70, 1.0, 0.34))
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
		1.0, 1.55, RELOAD_SPIN_AXIS)
	var catch_transform := Transform3D(catch_basis, RELOAD_CATCH)
	if p < 0.22:
		_reload_mag.visible = false
		_reload_hand_grip.transform = SatisfyingReload.arc_transform(
			support_grip.transform, toss_start, 0.050,
			SatisfyingReload.phase(p, 0.0, 0.22))
		return
	if p < 0.47:
		_reload_mag.visible = true
		var toss := SatisfyingReload.phase(p, 0.22, 0.47)
		_reload_mag.position = SatisfyingReload.arc(
			RELOAD_TOSS_START, RELOAD_CATCH,
			0.34, toss)
		_reload_mag.basis = SatisfyingReload.trick_spin(toss, 1.55,
			RELOAD_SPIN_AXIS)
		_reload_hand_grip.transform = _reload_mag.transform
	elif p < 0.72:
		_reload_mag.visible = true
		var insert := SatisfyingReload.phase(p, 0.47, 0.72)
		var drive := SatisfyingReload.overshoot(insert, 0.15)
		_reload_mag.position = SatisfyingReload.arc(
			RELOAD_CATCH, _magwell.position,
			0.09, drive)
		_reload_mag.basis = SatisfyingReload.slerp_basis(
			catch_transform.basis, _magwell.transform.basis, insert)
		_reload_hand_grip.transform = _reload_mag.transform
	else:
		_reload_mag.visible = false
		_reload_hand_grip.transform = SatisfyingReload.arc_transform(
			_magwell.transform, support_grip.transform, 0.060,
			SatisfyingReload.phase(p, 0.72, 0.98))


func _spawn_casing() -> void:
	var parent: Node = world if world else get_tree().current_scene
	if not parent or not _ejection_port:
		return
	var basis := global_transform.basis.orthonormalized()
	var inherited: Vector3 = actor.velocity \
		if actor is CharacterBody3D else Vector3.ZERO
	WeaponFX.spawn_debris(parent, WeaponDebris.Kind.BRASS,
		_ejection_port.global_transform,
		inherited * 0.32 + basis.x * 2.6 + basis.y * 0.8,
		Vector3(12.0, 4.0, -8.0), actor)


func _spawn_mag_debris() -> void:
	var parent: Node = world if world else get_tree().current_scene
	if not parent or not _magwell:
		return
	var basis := global_transform.basis.orthonormalized()
	var inherited: Vector3 = actor.velocity \
		if actor is CharacterBody3D else Vector3.ZERO
	WeaponFX.spawn_debris(parent, WeaponDebris.Kind.SMG_MAG,
		_magwell.global_transform,
		inherited * 0.35 + basis.x * 0.9 + Vector3.UP * 0.35,
		Vector3(-3.0, 2.0, 5.0), actor)


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


static func _material(color: Color, roughness: float,
		metallic: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
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
