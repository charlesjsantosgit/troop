class_name BananaGun
extends Node3D
## Six-shot banana sidearm. Its curved magazine keeps the reliable six-round
## gameplay while giving the reload a full toss/catch trick sequence.

signal ammo_changed(ammo: int, reloading: bool)

const CAPACITY := 6
const STARTING_RESERVE := 24
const MAX_RESERVE := 48
const FIRE_INTERVAL := 0.31
const RELOAD_TIME := 2.35
const MUZZLE_SPEED := 92.0
const CAMERA_RECOIL := 1.0

var actor: Node3D
var world: Node3D
var ammo := CAPACITY
var reserve_ammo := STARTING_RESERVE
var cooldown := 0.0
var reload_remaining := 0.0
var recoil := 0.0
var muzzle: Marker3D
var primary_grip: Marker3D
var support_grip: Marker3D
var first_person_view := false
var _third_person_parent: Node
var _third_person_transform := Transform3D.IDENTITY

const VIEWMODEL_POSITION := Vector3(0.27, -0.215, -0.56)
const VIEWMODEL_ROTATION := Vector3(-0.08, -0.06, 0.025)
const VIEWMODEL_SCALE := Vector3.ONE * 0.58
const AIM_VIEWMODEL_POSITION := Vector3(0.0, -0.19, -0.52)
const AIM_VIEWMODEL_ROTATION := Vector3(-0.055, 0.0, 0.0)
const SWING_VIEWMODEL_POSITION := Vector3(0.15, -0.12, -0.61)
const SWING_VIEWMODEL_ROTATION := Vector3(-0.04, -0.025, -0.055)
const RELOAD_TOSS_START := Vector3(-0.48, -0.46, 0.16)
const RELOAD_CATCH := Vector3(-0.25, -0.04, -0.01)

var _aim_blend := 0.0
var _swing_blend := 0.0
var _installed_mag: Node3D
var _reload_mag: Node3D
var _magwell: Marker3D
var _reload_hand_grip: Marker3D
var _reload_visual_progress := 0.0
var _reload_previous_progress := 0.0
var _reload_display_progress := 0.0
var _reload_event_mask := 0
var reload_sequence := 0
var reload_event_count := 0
var _reload_rounds_needed := 0


func configure(owner_actor: Node3D, owner_world: Node3D) -> void:
	actor = owner_actor
	world = owner_world


func _ready() -> void:
	# The barrel's local -Z follows the forearm toward the paw.
	position = Vector3(0, -MonkeyRig.ARM_B, 0)
	rotation.x = -PI * 0.5
	scale = Vector3.ONE * 0.72

	var yellow := _material(Color(0.96, 0.72, 0.08), 0.34, 0.12)
	var yellow_dark := _material(Color(0.58, 0.34, 0.035), 0.48, 0.06)
	var brown := _material(Color(0.24, 0.105, 0.035), 0.76, 0.0)
	var chamber := _material(Color(0.075, 0.055, 0.035), 0.38, 0.0)

	var frame := _box(Vector3(0.18, 0.12, 0.24), yellow_dark)
	frame.position = Vector3(0, 0.0, -0.11)
	add_child(frame)

	var barrel := _cylinder(0.055, 0.34, 10, yellow)
	barrel.rotation.x = PI * 0.5
	barrel.position = Vector3(0, 0.025, -0.35)
	add_child(barrel)

	# Revolver cylinder, with six visible dark chambers.
	var drum := _cylinder(0.115, 0.16, 12, yellow)
	drum.rotation.z = PI * 0.5
	drum.position = Vector3(0, 0.015, -0.12)
	add_child(drum)
	for i in range(CAPACITY):
		var angle := TAU * float(i) / CAPACITY
		var hole := _cylinder(0.019, 0.166, 7, chamber)
		hole.rotation.z = PI * 0.5
		hole.position = Vector3(0, 0.015 + cos(angle) * 0.071,
			-0.12 + sin(angle) * 0.071)
		add_child(hole)

	var grip := _box(Vector3(0.105, 0.25, 0.09), brown)
	grip.position = Vector3(0, -0.15, -0.015)
	grip.rotation.x = -0.25
	add_child(grip)

	var hammer := _box(Vector3(0.07, 0.045, 0.09), chamber)
	hammer.position = Vector3(0, 0.085, 0.015)
	hammer.rotation.x = -0.35
	add_child(hammer)

	# A small upward curl gives the silhouette a banana shape.
	var tip := _cylinder(0.06, 0.13, 9, yellow)
	tip.rotation.x = PI * 0.36
	tip.position = Vector3(0, 0.055, -0.53)
	add_child(tip)

	# Six chambers remain readable, but the oversized curved pack is the star of
	# the reload and leaves no doubt why this is called the banana gun.
	_magwell = Marker3D.new()
	_magwell.name = "BananaMagwell"
	_magwell.position = Vector3(0.0, -0.255, -0.08)
	_magwell.rotation = Vector3(-0.16, 0.0, 0.0)
	add_child(_magwell)
	_installed_mag = WeaponFX.make_banana_magazine()
	_installed_mag.name = "InstalledBananaMagazine"
	_installed_mag.position = _magwell.position
	_installed_mag.rotation = _magwell.rotation
	add_child(_installed_mag)
	_reload_hand_grip = Marker3D.new()
	_reload_hand_grip.name = "ReloadHandGrip"
	add_child(_reload_hand_grip)

	muzzle = Marker3D.new()
	muzzle.position = Vector3(0, 0.09, -0.60)
	add_child(muzzle)
	primary_grip = Marker3D.new()
	primary_grip.name = "PrimaryGrip"
	primary_grip.position = Vector3(0, -0.145, 0.015)
	add_child(primary_grip)
	support_grip = Marker3D.new()
	support_grip.name = "SupportGrip"
	support_grip.position = Vector3(-0.13, -0.125, -0.015)
	add_child(support_grip)


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
	var cant := SatisfyingReload.pulse(rp, 0.0, 0.20, 0.94)
	var catch_snap := SatisfyingReload.pulse(rp, 0.41, 0.49, 0.59)
	var finish_roll := SatisfyingReload.pulse(rp, 0.78, 0.87, 0.98)
	position = base_position + Vector3(0, 0.015, recoil * 0.075) \
		+ Vector3(-0.078, -0.025, 0.12) * cant \
		+ Vector3(0.018, 0.025, -0.035) * catch_snap
	rotation = base_rotation + Vector3(recoil * 0.11, 0, recoil * 0.025) \
		+ Vector3(-0.18, -0.41, 0.38) * cant \
		+ Vector3(0.08, -0.10, -0.42) * finish_roll


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


func tick(dt: float) -> void:
	cooldown = maxf(cooldown - dt, 0.0)
	recoil = move_toward(recoil, 0.0, dt * 7.5)
	if reload_remaining <= 0.0:
		return
	var previous := _reload_visual_progress
	_reload_previous_progress = previous
	reload_remaining = maxf(reload_remaining - dt, 0.0)
	var current := 1.0 if reload_remaining <= 0.0 \
		else 1.0 - reload_remaining / RELOAD_TIME
	_advance_reload_events(previous, current)
	_reload_visual_progress = current
	if reload_remaining <= 0.0:
		var loaded := mini(_reload_rounds_needed, reserve_ammo)
		ammo = mini(ammo + loaded, CAPACITY)
		reserve_ammo = maxi(reserve_ammo - loaded, 0)
		ammo_changed.emit(ammo, false)
		Sfx.play_at("reload_done", actor.global_position, -7.0, 1.08)
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
	var inherited := Vector3.ZERO
	if actor is CharacterBody3D:
		inherited = actor.velocity * 0.12
	var shot_velocity := direction.normalized() * MUZZLE_SPEED + inherited
	if Net.active and actor is MonkeyPlayer and actor.is_local:
		Net.fire_bullet(origin, shot_velocity, BananaBullet.DAMAGE, true, true,
			Net.WEAPON_REVOLVER)
	else:
		if world and world.has_method("spawn_bullet"):
			world.spawn_bullet(actor, origin, shot_velocity, BananaBullet.DAMAGE,
				true, Net.WEAPON_REVOLVER)
		Sfx.play_at("gunshot", origin, -2.0)
		if world and world.has_method("spawn_muzzle_flash"):
			world.spawn_muzzle_flash(origin, direction)
	return true


func start_reload() -> bool:
	if reload_remaining > 0.0 or ammo >= CAPACITY or reserve_ammo <= 0:
		return false
	_reload_rounds_needed = mini(CAPACITY - ammo, reserve_ammo)
	reload_remaining = RELOAD_TIME
	cooldown = maxf(cooldown, 0.2)
	_begin_reload_visuals()
	ammo_changed.emit(ammo, true)
	Sfx.play_at("reload_flourish", actor.global_position, -7.0, 1.08)
	return true


func reload_progress() -> float:
	return 0.0 if reload_remaining <= 0.0 else 1.0 - reload_remaining / RELOAD_TIME


func reset_cylinder() -> void:
	ammo = CAPACITY
	reserve_ammo = STARTING_RESERVE
	cooldown = 0.0
	reload_remaining = 0.0
	recoil = 0.0
	_finish_reload_visuals()
	ammo_changed.emit(ammo, false)


func cancel_reload() -> void:
	if reload_remaining <= 0.0:
		return
	reload_remaining = 0.0
	_reload_rounds_needed = 0
	_finish_reload_visuals()
	ammo_changed.emit(ammo, false)


func _begin_reload_visuals() -> void:
	reload_sequence += 1
	reload_event_count = 0
	_reload_event_mask = 0
	_reload_visual_progress = 0.0
	_reload_previous_progress = 0.0
	_reload_display_progress = 0.0
	if _reload_mag and is_instance_valid(_reload_mag):
		_reload_mag.queue_free()
	_reload_mag = WeaponFX.make_banana_magazine()
	_reload_mag.name = "TossedBananaMagazine"
	_reload_mag.visible = false
	add_child(_reload_mag)
	_reload_hand_grip.transform = support_grip.transform
	if _installed_mag:
		_installed_mag.visible = true


func add_reserve_ammo(rounds: int) -> int:
	var before := reserve_ammo
	reserve_ammo = mini(reserve_ammo + maxi(rounds, 0), MAX_RESERVE)
	return reserve_ammo - before


func _advance_reload_events(previous: float, current: float) -> void:
	_reload_event(previous, current, 0.08, 1, func():
		if _installed_mag:
			_installed_mag.visible = false
		_spawn_mag_debris()
		Sfx.play_at("mag_release", actor.global_position, -6.0, 1.16)
	)
	_reload_event(previous, current, 0.23, 2, func():
		if _reload_mag:
			_reload_mag.visible = true
		Sfx.play_at("banana_toss", actor.global_position, -6.0, 1.04)
	)
	_reload_event(previous, current, 0.46, 4, func():
		Sfx.play_at("mag_catch", actor.global_position, -5.0, 1.18)
		if _reload_mag:
			WeaponFX.spawn_glint(get_tree().current_scene,
				_reload_mag.global_position, Color(1.0, 0.86, 0.16))
	)
	_reload_event(previous, current, 0.73, 8, func():
		if _installed_mag:
			_installed_mag.visible = true
		if _reload_mag:
			_reload_mag.visible = false
		Sfx.play_at("mag_insert", actor.global_position, -4.0, 1.12)
		WeaponFX.spawn_glint(get_tree().current_scene,
			_magwell.global_position, Color(1.0, 0.70, 0.08))
	)
	_reload_event(previous, current, 0.87, 16, func():
		Sfx.play_at("reload_snap", actor.global_position, -5.0, 1.15)
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
	var catch_basis := SatisfyingReload.trick_spin(1.0, 2.15)
	var catch_transform := Transform3D(catch_basis, RELOAD_CATCH)
	if p < 0.23:
		_reload_mag.visible = false
		_reload_hand_grip.transform = SatisfyingReload.arc_transform(
			support_grip.transform, toss_start, 0.045,
			SatisfyingReload.phase(p, 0.0, 0.23))
		return
	if p < 0.47:
		_reload_mag.visible = true
		var toss := SatisfyingReload.phase(p, 0.23, 0.47)
		_reload_mag.position = SatisfyingReload.arc(
			RELOAD_TOSS_START, RELOAD_CATCH,
			0.31, toss)
		_reload_mag.basis = SatisfyingReload.trick_spin(toss, 2.15)
		_reload_hand_grip.transform = _reload_mag.transform
	elif p < 0.73:
		_reload_mag.visible = true
		var insert := SatisfyingReload.phase(p, 0.47, 0.73)
		var drive := SatisfyingReload.overshoot(insert, 0.18)
		_reload_mag.position = SatisfyingReload.arc(
			RELOAD_CATCH, _magwell.position,
			0.105, drive)
		_reload_mag.basis = SatisfyingReload.slerp_basis(
			catch_transform.basis, _magwell.transform.basis, insert)
		_reload_hand_grip.transform = _reload_mag.transform
	else:
		_reload_mag.visible = false
		_reload_hand_grip.transform = SatisfyingReload.arc_transform(
			_magwell.transform, support_grip.transform, 0.055,
			SatisfyingReload.phase(p, 0.73, 0.98))


func _spawn_mag_debris() -> void:
	var parent: Node = world if world else get_tree().current_scene
	if not parent or not _magwell:
		return
	var right := global_transform.basis.x.normalized()
	var inherited: Vector3 = actor.velocity \
		if actor is CharacterBody3D else Vector3.ZERO
	WeaponFX.spawn_debris(parent, WeaponDebris.Kind.BANANA_MAG,
		_magwell.global_transform, inherited * 0.35 + right * 1.4 + Vector3.UP * 0.8,
		Vector3(5.5, 2.0, -7.0), actor)


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


static func _material(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
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
