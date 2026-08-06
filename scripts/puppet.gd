class_name Puppet
extends Node3D
## A remote player: no physics, just interpolation toward the last replicated
## state plus short velocity extrapolation to hide the 20 Hz tick.

var peer_id := 0
var display_name := "Monkey"
var rig: MonkeyRig
var gun: BananaGun
var shotgun: PumpShotgun
var smg: SMG
var sniper: SniperRifle
var body_hitbox: CombatHitbox
var head_hitbox: CombatHitbox
var death_ragdoll: MonkeyRagdoll
var defeated_visual := false

const MAX_HEALTH := 100.0

var _target := Vector3.ZERO
var _vel := Vector3.ZERO
var _yaw := 0.0
var _anim: int = MonkeyRig.Anim.IDLE
var _swinging := false
var _anchor := Vector3.ZERO
var _tail := 0.0
var _wraps := PackedVector3Array()
var _age := 0.0
var _got_state := false
var state_count := 0
var first_pos := Vector3.INF
var _gun_direction := Vector3(0, 0, -1)
var _gun_aim_t := 0.0
var _defeat_guard_t := 0.0
var _active_weapon_kind := Net.WEAPON_REVOLVER
var _melee_remaining := 0.0
var _melee_combo := 0
var _weapon_hand_transforms: Dictionary = {}
var _remote_weapon_stowed := false
var _state_weapon_stowed := false
var _state_melee_mode := false
var _state_healing_progress := 0.0
var _last_swim_fx_cycle := -1.0
var _last_swim_kick_bucket := -1
var _was_swimming_fx := false


func setup(id: int, pname: String) -> void:
	peer_id = id
	display_name = pname


func _ready() -> void:
	body_hitbox = CombatHitbox.new()
	body_hitbox.name = "BodyHitbox"
	body_hitbox.setup_capsule(self, "body", MonkeyPlayer.PROJECTILE_BODY_RADIUS,
		MonkeyPlayer.PROJECTILE_BODY_HEIGHT)
	body_hitbox.position = Vector3(0, MonkeyPlayer.PROJECTILE_BODY_HEIGHT * 0.5, 0)
	add_child(body_hitbox)
	head_hitbox = CombatHitbox.new()
	head_hitbox.name = "HeadHitbox"
	head_hitbox.setup(self, "head", MonkeyPlayer.PROJECTILE_HEAD_RADIUS)
	head_hitbox.position = Vector3(0, 1.17, -0.015)
	add_child(head_hitbox)

	rig = MonkeyRig.new()
	rig.setup(display_name, true)
	add_child(rig)
	# Match projectile/scope targeting to the replica's animated anatomy.
	body_hitbox.reparent(rig.torso_p, false)
	body_hitbox.position = Vector3(0.0, -0.06, 0.0)
	head_hitbox.reparent(rig.head_p, false)
	head_hitbox.position = Vector3(0.0, 0.0, -0.015)
	gun = BananaGun.new()
	gun.configure(self, get_parent())
	rig.el_r.add_child(gun)
	shotgun = PumpShotgun.new()
	shotgun.configure(self, get_parent())
	rig.el_r.add_child(shotgun)
	shotgun.visible = false
	smg = SMG.new()
	smg.configure(self, get_parent())
	rig.el_r.add_child(smg)
	smg.visible = false
	sniper = SniperRifle.new()
	sniper.configure(self, get_parent())
	rig.el_r.add_child(sniper)
	sniper.visible = false
	_weapon_hand_transforms = {
		gun: gun.transform,
		shotgun: shotgun.transform,
		smg: smg.transform,
		sniper: sniper.transform,
	}


func take_damage(_amount: float, _source: Node3D, _impulse: Vector3) -> void:
	# The same network bullet also runs on the victim's machine, where its
	# authoritative MonkeyPlayer applies health and defeat. This replica only
	# supplies hit confirmation and correct projectile occlusion.
	pass


func on_shot(direction: Vector3, weapon_kind := Net.WEAPON_REVOLVER) -> void:
	if defeated_visual:
		return
	_cancel_remote_reloads()
	_active_weapon_kind = weapon_kind
	_state_weapon_stowed = false
	_state_melee_mode = false
	_melee_remaining = 0.0
	_sync_remote_weapon_mount(false)
	_gun_direction = direction.normalized()
	_gun_aim_t = 0.22
	gun.visible = weapon_kind == Net.WEAPON_REVOLVER
	shotgun.visible = weapon_kind == Net.WEAPON_SHOTGUN
	smg.visible = weapon_kind == Net.WEAPON_SMG
	sniper.visible = weapon_kind == Net.WEAPON_SNIPER
	if weapon_kind == Net.WEAPON_SHOTGUN:
		shotgun.recoil = 1.0
	elif weapon_kind == Net.WEAPON_SMG:
		smg.recoil = 1.0
	elif weapon_kind == Net.WEAPON_SNIPER:
		sniper.play_remote_fire()
	else:
		gun.recoil = 1.0


func on_melee(direction: Vector3, combo: int) -> void:
	if defeated_visual:
		return
	_cancel_remote_reloads()
	_gun_direction = direction.normalized()
	_melee_combo = posmod(combo, 3)
	_melee_remaining = MonkeyPlayer.MELEE_ATTACK_DURATION
	_sync_remote_weapon_mount(true)


func apply_state(pos: Vector3, yaw: float, vel: Vector3, anim: int,
		swinging: bool, anchor: Vector3, tail: float,
		wraps: PackedVector3Array, weapon_kind := Net.WEAPON_REVOLVER,
		weapon_stowed := false, melee_mode := false, weapon_ammo := -1,
		weapon_reloading := false, healing_progress := 0.0) -> void:
	if defeated_visual:
		if _defeat_guard_t > 0.0:
			return
		_end_defeat()
	if not _got_state:
		global_position = pos
		first_pos = pos
		_got_state = true
	_target = pos
	_vel = vel
	_yaw = yaw
	_anim = anim
	_swinging = swinging
	_anchor = anchor
	_tail = tail
	_wraps = wraps
	if weapon_kind != _active_weapon_kind:
		var previous_weapon := _visible_weapon()
		if previous_weapon and previous_weapon.reload_remaining > 0.0:
			previous_weapon.cancel_reload()
		_sync_remote_weapon_mount(false)
		_active_weapon_kind = weapon_kind
		gun.visible = weapon_kind == Net.WEAPON_REVOLVER
		shotgun.visible = weapon_kind == Net.WEAPON_SHOTGUN
		smg.visible = weapon_kind == Net.WEAPON_SMG
		sniper.visible = weapon_kind == Net.WEAPON_SNIPER
	_state_weapon_stowed = weapon_stowed
	_state_melee_mode = melee_mode
	_state_healing_progress = clampf(healing_progress, 0.0, 1.0)
	_sync_remote_reload(weapon_reloading, weapon_ammo)
	_age = 0.0
	state_count += 1


func _process(dt: float) -> void:
	if not _got_state:
		return
	if defeated_visual:
		_defeat_guard_t = maxf(_defeat_guard_t - dt, 0.0)
		return
	gun.tick(dt)
	shotgun.tick(dt)
	smg.tick(dt)
	sniper.tick(dt)
	_gun_aim_t = maxf(_gun_aim_t - dt, 0.0)
	_melee_remaining = maxf(_melee_remaining - dt, 0.0)
	var should_stow := _state_weapon_stowed or _melee_remaining > 0.0
	_sync_remote_weapon_mount(should_stow)
	var sniper_rope_active := _swinging \
		and _active_weapon_kind == Net.WEAPON_SNIPER and not should_stow
	rig.set_sniper_rope_pose(sniper_rope_active,
		sniper.support_grip if sniper_rope_active else null)
	_age += dt
	var pred := _target + _vel * minf(_age, 0.25)
	global_position = global_position.lerp(pred, 1.0 - exp(-14.0 * dt))
	rig.set_yaw(lerp_angle(rig.yaw_angle(), _yaw, 1.0 - exp(-10.0 * dt)))
	# rope before update_motion so the swing IK sees this frame's grip point
	var pivot := _anchor
	if _wraps.size() > 0:
		pivot = _wraps[_wraps.size() - 1]
	if _swinging:
		rig.set_rope(true, _anchor, global_position + Vector3.UP * 1.05, _tail, _vel, _wraps, dt)
	else:
		rig.set_rope(false, Vector3.ZERO, Vector3.ZERO)
	var weapon_recoil := gun.recoil
	if shotgun.visible:
		weapon_recoil = shotgun.recoil
	elif smg.visible:
		weapon_recoil = smg.recoil
	elif sniper.visible:
		weapon_recoil = sniper.recoil
	var held_weapon := gun.visible or shotgun.visible or smg.visible \
		or sniper.visible
	var held_direction := _gun_direction
	if _gun_aim_t <= 0.0:
		held_direction = rig.yaw_node.global_transform.basis * Vector3.FORWARD
	var melee_active := _melee_remaining > 0.0
	rig.set_gun_aim(held_weapon and not should_stow,
		held_direction, weapon_recoil)
	var reload_weapon := _visible_weapon()
	var reload_hand_active: bool = reload_weapon != null \
		and reload_weapon.reload_remaining > 0.0 \
		and reload_weapon.has_dynamic_reload_hand() \
		and reload_weapon.get("_reload_hand_grip") is Node3D
	rig.set_reload_pose(reload_hand_active,
		reload_weapon.get("_reload_hand_grip") if reload_hand_active else null)
	var melee_progress := 1.0 - _melee_remaining \
		/ MonkeyPlayer.MELEE_ATTACK_DURATION if melee_active else 0.0
	rig.set_melee_pose(_state_melee_mode or melee_active, melee_active,
		melee_progress, _melee_combo)
	rig.set_healing_pose(_state_healing_progress > 0.0,
		_state_healing_progress)
	rig.update_motion(dt, _anim, _vel, _anim <= MonkeyRig.Anim.SPRINT, pivot)
	_update_water_effects()


func _sync_remote_reload(reloading: bool, replicated_ammo: int) -> void:
	var weapon := _visible_weapon()
	if not weapon:
		return
	if not reloading:
		if weapon.reload_remaining > 0.0:
			weapon.cancel_reload()
		return
	if weapon.reload_remaining > 0.0:
		return
	weapon.ammo = clampi(replicated_ammo, 0, int(weapon.CAPACITY)) \
		if replicated_ammo >= 0 else maxi(int(weapon.CAPACITY) - 1, 0)
	weapon.start_reload()


func _cancel_remote_reloads() -> void:
	for weapon in [gun, shotgun, smg, sniper]:
		if weapon and weapon.reload_remaining > 0.0:
			weapon.cancel_reload()


func _update_water_effects() -> void:
	var world := get_parent()
	if not world or not world.get("water_fx"):
		return
	var fx: WaterFX = world.water_fx
	var swimming := _anim == MonkeyRig.Anim.SWIM
	var speed := Vector3(_vel.x, 0, _vel.z).length()
	if swimming and not _was_swimming_fx:
		fx.entry_splash(global_position, _vel, 0.72)
	elif not swimming and _was_swimming_fx:
		fx.exit_splash(global_position, _vel, 0.56)
	fx.update_swimmer(get_instance_id(), global_position, _vel, swimming,
		clampf(speed / MonkeyPlayer.SWIM_SPEED, 0.25, 1.0))
	if swimming:
		var cycle := rig.gait_cycle()
		var contacts := rig.limb_contact_points()
		if contacts.size() == 4:
			var strength := clampf(speed / MonkeyPlayer.SWIM_SPEED, 0.32, 0.92)
			if MonkeyPlayer._cycle_crossed(_last_swim_fx_cycle, cycle, 0.0):
				fx.stroke(contacts[0], _vel, -1, strength)
			if MonkeyPlayer._cycle_crossed(_last_swim_fx_cycle, cycle, 0.5):
				fx.stroke(contacts[1], _vel, 1, strength)
			var kick_bucket := floori(cycle * 6.0) % 6
			if _last_swim_kick_bucket >= 0 and kick_bucket != _last_swim_kick_bucket \
					and fx.has_method("kick"):
				fx.kick(contacts[2 + (kick_bucket & 1)], _vel, strength * 0.4)
			_last_swim_kick_bucket = kick_bucket
		_last_swim_fx_cycle = cycle
	else:
		_last_swim_fx_cycle = -1.0
		_last_swim_kick_bucket = -1
	_was_swimming_fx = swimming


func _sync_remote_weapon_mount(stowed: bool) -> void:
	if stowed == _remote_weapon_stowed:
		return
	var weapon := _visible_weapon()
	if not weapon:
		return
	if weapon.get_parent() != rig.el_r:
		weapon.reparent(rig.el_r, false)
	if _weapon_hand_transforms.has(weapon):
		weapon.transform = _weapon_hand_transforms[weapon]
	if stowed:
		weapon.reparent(rig.weapon_back_mount, false)
		weapon.transform = _weapon_back_transform(weapon)
	_remote_weapon_stowed = stowed


func _visible_weapon() -> Node3D:
	if shotgun.visible:
		return shotgun
	if smg.visible:
		return smg
	if sniper.visible:
		return sniper
	return gun


func _weapon_back_transform(weapon: Node3D) -> Transform3D:
	var direction := Vector3(-0.58, 0.815, 0.0).normalized()
	var local_z := -direction
	var local_x := Vector3.BACK.cross(local_z).normalized()
	var local_y := local_z.cross(local_x).normalized()
	var basis := Basis(local_x, local_y, local_z)
	var hand_transform: Transform3D = _weapon_hand_transforms.get(
		weapon, Transform3D.IDENTITY)
	basis = basis.scaled(Vector3.ONE * hand_transform.basis.get_scale().x)
	var back_position := Vector3(0.0, -0.08, 0.0)
	if weapon is BananaGun:
		back_position = Vector3(0.01, -0.02, 0.0)
	elif weapon is PumpShotgun:
		back_position = Vector3(0.0, -0.14, 0.0)
	elif weapon is SniperRifle:
		back_position = Vector3(0.0, -0.20, 0.02)
	return Transform3D(basis, back_position)


func begin_defeat(pos: Vector3, yaw: float, death_velocity: Vector3,
		impulse: Vector3, headshot: bool) -> void:
	if is_instance_valid(death_ragdoll):
		death_ragdoll.queue_free()
	death_ragdoll = MonkeyRagdoll.new()
	death_ragdoll.configure(display_name, pos, yaw, death_velocity, impulse,
		headshot)
	get_parent().add_child(death_ragdoll)
	defeated_visual = true
	_defeat_guard_t = 1.75
	body_hitbox.set_active(false)
	head_hitbox.set_active(false)
	rig.set_rope(false, Vector3.ZERO, Vector3.ZERO)
	rig.visible = false
	gun.visible = false
	shotgun.visible = false
	smg.visible = false
	sniper.visible = false


func _end_defeat() -> void:
	defeated_visual = false
	if is_instance_valid(death_ragdoll):
		death_ragdoll.queue_free()
	death_ragdoll = null
	body_hitbox.set_active(true)
	head_hitbox.set_active(true)
	rig.visible = true
	gun.visible = _active_weapon_kind == Net.WEAPON_REVOLVER
	shotgun.visible = _active_weapon_kind == Net.WEAPON_SHOTGUN
	smg.visible = _active_weapon_kind == Net.WEAPON_SMG
	sniper.visible = _active_weapon_kind == Net.WEAPON_SNIPER


func _exit_tree() -> void:
	var world := get_parent()
	if world and world.get("water_fx"):
		world.water_fx.remove_swimmer(get_instance_id())
	if is_instance_valid(death_ragdoll):
		death_ragdoll.queue_free()
