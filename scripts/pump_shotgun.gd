class_name PumpShotgun
extends Node3D
## Six-shell pump shotgun. Each trigger pull launches six independent
## 15-damage pellets in a uniform, realistic cone.

signal ammo_changed(ammo: int, reloading: bool)

const CAPACITY := 6
const STARTING_RESERVE := 24
const MAX_RESERVE := 48
const PELLETS_PER_SHOT := 6
const PELLET_DAMAGE := 15.0
const FIRE_INTERVAL := 0.88
const SHELL_RELOAD_TIME := 0.72
const FINAL_PUMP_TIME := 0.62
const MUZZLE_SPEED := 78.0
const SPREAD_HALF_ANGLE_DEGREES := 3.0
const CAMERA_RECOIL := 2.35

const VIEWMODEL_POSITION := Vector3(0.27, -0.265, -0.76)
const VIEWMODEL_ROTATION := Vector3(-0.035, -0.025, 0.018)
const VIEWMODEL_SCALE := Vector3.ONE * 0.49
const AIM_VIEWMODEL_POSITION := Vector3(0.0, -0.215, -0.70)
const AIM_VIEWMODEL_ROTATION := Vector3(-0.022, 0.0, 0.0)
const SWING_VIEWMODEL_POSITION := Vector3(0.145, -0.145, -0.80)
const SWING_VIEWMODEL_ROTATION := Vector3(-0.02, -0.015, -0.04)
const RELOAD_TOSS_START := Vector3(-0.48, -0.48, 0.20)
const RELOAD_CATCH := Vector3(-0.29, -0.05, -0.04)
const RELOAD_SPIN_AXIS := Vector3(0.45, 0.15, 0.88)
const RELOAD_SHELL_SCALE := 1.85

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

var _reloading := false
var _shot_index := 0
var _third_person_parent: Node
var _third_person_transform := Transform3D.IDENTITY
var _pump_mesh: MeshInstance3D
var _pump_group: Node3D
var _pump_base_z := -0.38
var _aim_blend := 0.0
var _swing_blend := 0.0
var _loading_port: Marker3D
var _ejection_port: Marker3D
var _reload_shell: Node3D
var _reload_hand_grip: Marker3D
var _reload_visual_progress := 0.0
var _reload_previous_progress := 0.0
var _reload_display_progress := 0.0
var _reload_event_mask := 0
var _finishing_pump := false
var _first_shell_cycle := false
var reload_sequence := 0
var reload_event_count := 0


func configure(owner_actor: Node3D, owner_world: Node3D) -> void:
	actor = owner_actor
	world = owner_world


func _ready() -> void:
	position = Vector3(0, -MonkeyRig.ARM_B, -0.03)
	rotation.x = -PI * 0.5
	scale = Vector3.ONE * 0.63

	var steel := _material(Color(0.09, 0.105, 0.09), 0.28, 0.62)
	var dark_steel := _material(Color(0.035, 0.045, 0.038), 0.34, 0.72)
	var wood := _material(Color(0.40, 0.17, 0.055), 0.72, 0.04)
	var wood_light := _material(Color(0.58, 0.28, 0.075), 0.64, 0.03)
	var brass := _material(Color(0.72, 0.48, 0.08), 0.30, 0.52)

	var receiver := _box(Vector3(0.17, 0.16, 0.34), steel)
	receiver.position = Vector3(0, 0.01, -0.05)
	add_child(receiver)

	var barrel := _cylinder(0.043, 0.82, 12, dark_steel)
	barrel.rotation.x = PI * 0.5
	barrel.position = Vector3(0, 0.055, -0.58)
	add_child(barrel)
	var tube := _cylinder(0.034, 0.66, 10, steel)
	tube.rotation.x = PI * 0.5
	tube.position = Vector3(0, -0.045, -0.50)
	add_child(tube)

	_pump_group = Node3D.new()
	_pump_group.name = "PumpGroup"
	_pump_group.position = Vector3(0, 0, _pump_base_z)
	add_child(_pump_group)
	_pump_mesh = _box(Vector3(0.19, 0.16, 0.25), wood_light)
	_pump_mesh.position = Vector3(0, -0.005, 0)
	_pump_group.add_child(_pump_mesh)
	for x in [-0.065, -0.022, 0.022, 0.065]:
		var groove := _box(Vector3(0.009, 0.166, 0.255), dark_steel)
		groove.position = Vector3(x, -0.003, 0)
		_pump_group.add_child(groove)

	var grip := _box(Vector3(0.13, 0.27, 0.13), wood)
	grip.position = Vector3(0, -0.15, 0.10)
	grip.rotation.x = -0.28
	add_child(grip)
	var stock := _box(Vector3(0.18, 0.19, 0.43), wood)
	stock.position = Vector3(0, -0.02, 0.32)
	stock.rotation.x = 0.08
	add_child(stock)
	var sight := _box(Vector3(0.025, 0.035, 0.035), brass)
	sight.position = Vector3(0, 0.10, -0.96)
	add_child(sight)

	muzzle = Marker3D.new()
	muzzle.position = Vector3(0, 0.055, -1.0)
	add_child(muzzle)
	primary_grip = Marker3D.new()
	primary_grip.name = "PrimaryGrip"
	primary_grip.position = Vector3(0, -0.15, 0.10)
	add_child(primary_grip)
	support_grip = Marker3D.new()
	support_grip.name = "SupportGrip"
	support_grip.position = Vector3(-0.16, -0.055, 0)
	_pump_group.add_child(support_grip)
	_loading_port = Marker3D.new()
	_loading_port.name = "LoadingPort"
	_loading_port.position = Vector3(-0.08, -0.105, -0.04)
	_loading_port.rotation = Vector3(0.0, 0.0, PI * 0.5)
	add_child(_loading_port)
	_ejection_port = Marker3D.new()
	_ejection_port.name = "EjectionPort"
	_ejection_port.position = Vector3(0.11, 0.055, -0.12)
	add_child(_ejection_port)
	_reload_hand_grip = Marker3D.new()
	_reload_hand_grip.name = "ReloadHandGrip"
	add_child(_reload_hand_grip)


func tick(dt: float) -> void:
	cooldown = maxf(cooldown - dt, 0.0)
	recoil = move_toward(recoil, 0.0, dt * 5.2)
	var remaining_dt := maxf(dt, 0.0)
	var phase_guard := 0
	# Consume hitches across every shell boundary instead of silently throwing
	# away the unused part of dt. Capacity + the finishing pump bounds this loop
	# to seven phases for a normal empty-to-full reload.
	while reload_remaining > 0.0 and remaining_dt > 0.0 \
			and phase_guard < CAPACITY + 2:
		phase_guard += 1
		var finishing_this_phase := _finishing_pump
		var duration := FINAL_PUMP_TIME \
			if finishing_this_phase else SHELL_RELOAD_TIME
		var previous := _reload_visual_progress
		_reload_previous_progress = previous
		var consumed := minf(remaining_dt, reload_remaining)
		reload_remaining = maxf(reload_remaining - consumed, 0.0)
		remaining_dt -= consumed
		var current := 1.0 if reload_remaining <= 0.0 \
			else 1.0 - reload_remaining / duration
		if finishing_this_phase:
			_advance_final_pump_events(previous, current)
			_reload_visual_progress = current
			if reload_remaining <= 0.0:
				_finishing_pump = false
				_reloading = false
				ammo_changed.emit(ammo, false)
				Sfx.play_at("reload_done", actor.global_position, -7.0, 0.92)
				_finish_reload_visuals()
			continue
		_advance_shell_events(previous, current)
		_reload_visual_progress = current
		if reload_remaining > 0.0:
			continue
		ammo = mini(ammo + 1, CAPACITY)
		reserve_ammo = maxi(reserve_ammo - 1, 0)
		ammo_changed.emit(ammo, true)
		if _reloading and ammo < CAPACITY and reserve_ammo > 0:
			_begin_shell_cycle(false)
		else:
			_begin_final_pump()


func try_fire(origin: Vector3, direction: Vector3) -> bool:
	if cooldown > 0.0:
		return false
	if _reloading:
		if ammo <= 0:
			return false
		_reloading = false
		_finishing_pump = false
		reload_remaining = 0.0
		_finish_reload_visuals()
	if ammo <= 0:
		cooldown = 0.16
		Sfx.play_at("empty", actor.global_position, -8.0)
		return false

	ammo -= 1
	cooldown = FIRE_INTERVAL
	recoil = 1.0
	ammo_changed.emit(ammo, false)
	_shot_index += 1
	var seed_value := _shot_index * 7919 + int(Time.get_ticks_msec() & 0xffff)
	var directions := pellet_directions(direction, seed_value)
	var inherited: Vector3 = actor.velocity * 0.10 \
		if actor is CharacterBody3D else Vector3.ZERO
	for i in range(directions.size()):
		var shot_velocity: Vector3 = directions[i] * MUZZLE_SPEED + inherited
		if Net.active and actor is MonkeyPlayer and actor.is_local:
			Net.fire_bullet(origin, shot_velocity, PELLET_DAMAGE, false, i == 0,
				Net.WEAPON_SHOTGUN)
		elif world and world.has_method("spawn_bullet"):
			world.spawn_bullet(actor, origin, shot_velocity, PELLET_DAMAGE, false,
				Net.WEAPON_SHOTGUN)
	if not (Net.active and actor is MonkeyPlayer and actor.is_local):
		Sfx.play_at("shotgun", origin, -1.0)
		if world and world.has_method("spawn_muzzle_flash"):
			world.spawn_muzzle_flash(origin, direction)
	_schedule_pump_sound()
	return true


func start_reload() -> bool:
	if _reloading or ammo >= CAPACITY or reserve_ammo <= 0:
		return false
	_reloading = true
	_finishing_pump = false
	_begin_shell_cycle(true)
	cooldown = maxf(cooldown, 0.18)
	ammo_changed.emit(ammo, true)
	Sfx.play_at("shotgun_reload", actor.global_position, -7.0, 1.06)
	return true


func reload_progress() -> float:
	return 0.0 if reload_remaining <= 0.0 \
		else 1.0 - reload_remaining / (
			FINAL_PUMP_TIME if _finishing_pump else SHELL_RELOAD_TIME)


func reset_cylinder() -> void:
	ammo = CAPACITY
	reserve_ammo = STARTING_RESERVE
	cooldown = 0.0
	reload_remaining = 0.0
	recoil = 0.0
	_reloading = false
	_finishing_pump = false
	_finish_reload_visuals()
	ammo_changed.emit(ammo, false)


func cancel_reload() -> void:
	if not _reloading and reload_remaining <= 0.0:
		return
	_reloading = false
	_finishing_pump = false
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
	if _pump_group:
		var pump_progress := clampf(
			(FIRE_INTERVAL - cooldown - 0.18) / 0.48, 0.0, 1.0)
		var pump_travel := sin(pump_progress * PI) * 0.18
		if _finishing_pump:
			pump_travel = maxf(pump_travel,
				SatisfyingReload.pulse(_reload_display_progress,
					0.0, 0.5, 1.0) * 0.22)
		_pump_group.position.z = _pump_base_z + pump_travel
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
	var load_pose := 0.0 if _finishing_pump \
		else SatisfyingReload.pulse(rp, 0.0, 0.24, 0.96)
	var pump_pose := SatisfyingReload.pulse(rp, 0.0, 0.5, 1.0) \
		if _finishing_pump else 0.0
	position = base_position + Vector3(0, 0.012, recoil * 0.105) \
		+ Vector3(-0.09, -0.04, 0.12) * load_pose \
		+ Vector3(0.02, 0.05, 0.13) * pump_pose
	rotation = base_rotation + Vector3(recoil * 0.14, 0, recoil * 0.02) \
		+ Vector3(-0.15, -0.30, 0.34) * load_pose \
		+ Vector3(-0.12, 0.04, -0.08) * pump_pose


func first_person_grip_transforms(view_space: Node3D) -> Array[Transform3D]:
	var to_view := view_space.global_transform.affine_inverse()
	var support := _reload_hand_grip if _reloading and not _finishing_pump \
		and _reload_shell else support_grip
	return [
		to_view * primary_grip.global_transform,
		to_view * support.global_transform,
	]


func has_dynamic_reload_hand() -> bool:
	if _finishing_pump and reload_remaining > 0.0:
		# The normal support marker is parented to the moving pump, so it is already
		# the exact dynamic hand target during the closing flourish.
		return true
	return _reloading and _reload_shell != null \
		and is_instance_valid(_reload_shell)


func add_reserve_ammo(shells: int) -> int:
	var before := reserve_ammo
	reserve_ammo = mini(reserve_ammo + maxi(shells, 0), MAX_RESERVE)
	return reserve_ammo - before


func _begin_shell_cycle(first: bool) -> void:
	if first:
		reload_sequence += 1
		reload_event_count = 0
	_reload_event_mask = 0
	_reload_visual_progress = 0.0
	_reload_previous_progress = 0.0
	_reload_display_progress = 0.0
	_first_shell_cycle = first
	reload_remaining = SHELL_RELOAD_TIME
	if _reload_shell and is_instance_valid(_reload_shell):
		_reload_shell.queue_free()
	_reload_shell = WeaponFX.make_shotgun_shell()
	_reload_shell.name = "ReloadShell"
	# The hull stays physically proportioned when it ejects into the world, but
	# the hand prop is slightly oversized so its red body and brass cap remain
	# readable against the monkey's broad first-person paw during the flip.
	_reload_shell.scale = Vector3.ONE * RELOAD_SHELL_SCALE
	_reload_shell.visible = false
	add_child(_reload_shell)
	if first:
		_reload_hand_grip.global_transform = support_grip.global_transform


func _begin_final_pump() -> void:
	if _reload_shell and is_instance_valid(_reload_shell):
		_reload_shell.queue_free()
	_reload_shell = null
	_reload_event_mask = 0
	_reload_visual_progress = 0.0
	_reload_previous_progress = 0.0
	_reload_display_progress = 0.0
	_finishing_pump = true
	reload_remaining = FINAL_PUMP_TIME
	_reload_hand_grip.global_transform = support_grip.global_transform
	Sfx.play_at("shotgun_cock", actor.global_position, -6.0, 0.94)


func _advance_shell_events(previous: float, current: float) -> void:
	_reload_event(previous, current, 0.08, 1, func():
		if _reload_shell:
			_reload_shell.visible = true
		Sfx.play_at("shell_pickup", actor.global_position, -9.0,
			randf_range(0.96, 1.06))
	)
	_reload_event(previous, current, 0.43, 2, func():
		Sfx.play_at("shell_catch", actor.global_position, -8.0,
			randf_range(0.97, 1.07))
	)
	_reload_event(previous, current, 0.82, 4, func():
		if _reload_shell:
			_reload_shell.visible = false
		Sfx.play_at("shotgun_shell", actor.global_position, -6.0,
			randf_range(0.96, 1.05))
		WeaponFX.spawn_glint(get_tree().current_scene,
			_loading_port.global_position, Color(1.0, 0.45, 0.12))
	)


func _advance_final_pump_events(previous: float, current: float) -> void:
	_reload_event(previous, current, 0.45, 8, func():
		Sfx.play_at("shotgun_pump", actor.global_position, -5.0, 0.90)
	)
	_reload_event(previous, current, 0.82, 16, func():
		Sfx.play_at("reload_snap", actor.global_position, -6.0, 0.86)
		WeaponFX.spawn_glint(get_tree().current_scene,
			global_position, Color(1.0, 0.64, 0.16))
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
	if not _reloading or _finishing_pump or not _reload_shell:
		return
	var p := _reload_display_progress
	var support_local := global_transform.affine_inverse() \
		* support_grip.global_transform
	var shell_scale := Vector3.ONE * RELOAD_SHELL_SCALE
	var toss_start := Transform3D(
		Basis.IDENTITY.scaled(shell_scale), RELOAD_TOSS_START)
	var catch_basis := SatisfyingReload.trick_spin(
		1.0, 1.35, RELOAD_SPIN_AXIS).scaled(shell_scale)
	var catch_transform := Transform3D(catch_basis, RELOAD_CATCH)
	var port_transform := Transform3D(
		_loading_port.transform.basis.scaled(shell_scale),
		_loading_port.position)
	var pickup_hand := _shell_hand_transform(toss_start)
	var port_hand := _shell_hand_transform(port_transform)
	if p < 0.08:
		_reload_shell.visible = false
		_reload_hand_grip.transform = SatisfyingReload.arc_transform(
			support_local if _first_shell_cycle else pickup_hand,
			pickup_hand, 0.035, SatisfyingReload.phase(p, 0.0, 0.08))
		return
	_reload_shell.visible = p < 0.82
	if p < 0.45:
		var toss := SatisfyingReload.phase(p, 0.08, 0.45)
		_reload_shell.position = SatisfyingReload.arc(
			RELOAD_TOSS_START, RELOAD_CATCH,
			0.27, toss)
		_reload_shell.basis = SatisfyingReload.trick_spin(toss, 1.35,
			RELOAD_SPIN_AXIS).scaled(shell_scale)
		_reload_hand_grip.transform = _shell_hand_transform(
			_reload_shell.transform)
	elif p < 0.82:
		var insert := SatisfyingReload.phase(p, 0.45, 0.82)
		var drive := SatisfyingReload.overshoot(insert, 0.10)
		_reload_shell.position = SatisfyingReload.arc(
			RELOAD_CATCH, _loading_port.position,
			0.07, drive)
		_reload_shell.basis = SatisfyingReload.slerp_basis(
			catch_transform.basis, port_transform.basis, insert)
		_reload_hand_grip.transform = _shell_hand_transform(
			_reload_shell.transform)
	else:
		var finishes_after_shell := ammo + 1 >= CAPACITY or reserve_ammo <= 1
		_reload_hand_grip.transform = SatisfyingReload.arc_transform(
			port_hand, support_local if finishes_after_shell else pickup_hand,
			0.045, SatisfyingReload.phase(p, 0.82, 1.0))


func _shell_hand_transform(shell_transform: Transform3D) -> Transform3D:
	var hand_transform := shell_transform
	# Grip the brass end instead of covering the shell's centre with the paw.
	hand_transform.origin = shell_transform * Vector3(0.0, -0.105, 0.0)
	return hand_transform


func _spawn_spent_shell(snapshot: Dictionary = {}) -> void:
	var parent: Node = world if world else get_tree().current_scene
	if not parent or not _ejection_port:
		return
	var ejection_transform: Transform3D = snapshot.get(
		"transform", _ejection_port.global_transform)
	var basis := ejection_transform.basis.orthonormalized()
	var inherited: Vector3 = snapshot.get("velocity",
		actor.velocity if actor is CharacterBody3D else Vector3.ZERO)
	WeaponFX.spawn_debris(parent, WeaponDebris.Kind.SHOTGUN_SHELL,
		ejection_transform,
		inherited * 0.34 + basis.x * 2.2 + basis.y * 1.15,
		Vector3(9.0, -5.0, 12.0), actor)


func _finish_reload_visuals() -> void:
	_reload_visual_progress = 0.0
	_reload_previous_progress = 0.0
	_reload_display_progress = 0.0
	_reload_event_mask = 0
	_first_shell_cycle = false
	if _reload_shell and is_instance_valid(_reload_shell):
		_reload_shell.queue_free()
	_reload_shell = null
	if _reload_hand_grip and support_grip:
		_reload_hand_grip.global_transform = support_grip.global_transform
	if _pump_group:
		_pump_group.position.z = _pump_base_z


func _schedule_pump_sound() -> void:
	# Snapshot the chamber at the shot. A switch or bandage during the delayed
	# pump must not teleport its hull to a backpack-mounted/invisible weapon.
	var snapshot := {
		"transform": _ejection_port.global_transform,
		"velocity": actor.velocity if actor is CharacterBody3D else Vector3.ZERO,
	}
	var timer := get_tree().create_timer(0.29)
	timer.timeout.connect(func():
		if is_instance_valid(actor):
			Sfx.play_at("shotgun_pump", actor.global_position, -6.0)
			_spawn_spent_shell(snapshot))


static func pellet_directions(forward: Vector3, seed_value: int) -> Array[Vector3]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var aim := forward.normalized()
	var right := aim.cross(Vector3.UP)
	if right.length_squared() < 0.01:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var up := right.cross(aim).normalized()
	var cone := tan(deg_to_rad(SPREAD_HALF_ANGLE_DEGREES))
	var result: Array[Vector3] = []
	for i in range(PELLETS_PER_SHOT):
		if i == 0:
			# A centered lead pellet keeps a perfectly aimed mid-range shot
			# useful; the remaining buckshot still supplies the full cone.
			result.append(aim)
			continue
		var angle := rng.randf() * TAU
		var radius := sqrt(rng.randf()) * cone
		result.append((aim + right * cos(angle) * radius
			+ up * sin(angle) * radius).normalized())
	return result


static func spread_radius_at(distance: float) -> float:
	return tan(deg_to_rad(SPREAD_HALF_ANGLE_DEGREES)) * distance


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
