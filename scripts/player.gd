class_name MonkeyPlayer
extends CharacterBody3D
## The monkey. Momentum-first controller: ground run/sprint, coyote + buffered
## jumps, double jump, air dive, slope-accelerated slide, wall-slide/wall-jump,
## and the core mechanic — a verlet-constrained pendulum vine swing where
## pumping, reeling and well-timed releases build real speed.

signal landed(impact: float)
signal health_changed(current: float, maximum: float)
signal defeated_by(source: Node3D)
signal bandages_changed(count: int)
signal bullet_hit_confirmed(headshot: bool, damage: float)

enum S { GROUND, AIR, SWING, SLIDE, SWIM }

const WALK_SPEED := 7.0
const SPRINT_SPEED := 11.0
const ACCEL := 45.0
const AIR_ACCEL := 16.0
const FRICTION := 38.0
const OVERSPEED_DRAG := 5.0
# Earth gravity for unsupported player flight. Keep this separate from the
# stronger authored traversal gravity below so changing freefall does not make
# vine swings or downhill slides lose their established momentum.
const FREEFALL_ACCELERATION := 9.81
const DEFAULT_COLLISION_SAFE_MARGIN := 0.001
# TROOP keeps the Moon in a remote vertical coordinate band so Earth and lunar
# players can coexist in one physics space. Its precision-safe y=48,000 origin
# still uses ~4 mm float increments, so a two-centimetre recovery margin keeps
# low-gravity contact stable without visibly lifting the 26 cm capsule.
const LUNAR_COLLISION_SAFE_MARGIN := 0.02
const GRAVITY := 20.0
const JUMP_VEL := 8.8
const JUMP_CUT := 26.0
const DOUBLE_JUMP_VEL := 7.8
const COYOTE := 0.12
const JUMP_BUFFER := 0.14
const SLIDE_MIN_SPEED := 6.0
const SLIDE_FRICTION := 2.2
const SLIDE_BOOST := 1.12
const DIVE_FWD := 7.0
const DIVE_DOWN := 5.0
const WALL_SLIDE_V := 6.0
const WALL_JUMP_UP := 7.6
const WALL_JUMP_OUT := 7.2
const GALLOP_SPEED := 13.0    # all-fours, slightly faster than sprint
const GALLOP_ENTER := 11.5    # landing speed that drops the monkey to all fours
const GALLOP_EXIT := 10.0
const FLIP_MIN_SPEED := 13.0  # vine-release speed that starts an aerial flip
const FLIP_EXIT_SPEED := 10.5
const SWIM_SPEED := 4.8
const SWIM_DEPTH := 0.85      # chest-deep water floats the monkey into a swim
const SKID_TIME := 0.24
const SKID_DECEL := 26.0
const HAND_H := 1.05          # grip point height above the feet (arm reach)
const MIN_ROPE := 2.2
const REEL_SPEED := 5.0
const WHEEL_REEL_STEP := 0.65
const AUTO_REEL := 4.0        # hands slide to the grabbed point at this rate
const ROPE_PULL := 9.0        # max rate the rope closes overstretch (no snap)
const WRAP_MIN := 0.3
const MAX_WRAPS := 6
const PUMP_ACCEL := 9.0
const PUMP_CAP := 30.0
const STEER_ACCEL := 7.0
const SWING_MAX := 40.0
const RELEASE_BOOST := 1.12
const RELEASE_POP := 4.4
const ABS_MAX := 58.0
const MAX_HEALTH := 100.0
const PROJECTILE_BODY_RADIUS := 0.38
const PROJECTILE_BODY_HEIGHT := 1.14
const PROJECTILE_HEAD_RADIUS := 0.27
const ACCURACY_STILL_SPEED := 0.35
const MOVE_SPREAD_HALF_ANGLE_DEGREES := 0.65
const AIR_SPREAD_HALF_ANGLE_DEGREES := 1.10
const SWING_SPREAD_MIN_HALF_ANGLE_DEGREES := 3.75
const SWING_SPREAD_MAX_HALF_ANGLE_DEGREES := 5.25
const SNIPER_HIP_SPREAD_HALF_ANGLE_DEGREES := 1.35
const SNIPER_HIP_MOVE_SPREAD_HALF_ANGLE_DEGREES := 2.25
const SNIPER_AIR_SPREAD_HALF_ANGLE_DEGREES := 3.20
const SNIPER_SWING_SPREAD_HALF_ANGLE_DEGREES := 4.80
const SNIPER_SWING_SPEED_MULTIPLIER := 0.82
const SNIPER_SWING_DRAG := 0.38
const MELEE_ATTACK_DURATION := 0.62
const MELEE_HIT_PROGRESS := 0.38
const MELEE_COMBO_RESET_TIME := 0.85
const BANDAGE_TIME := 2.45
const BANDAGE_HEAL := 42.0
const MAX_BANDAGES := 5
const FLY_SPEED := 22.0
const FLY_SPRINT_SPEED := 38.0
const FLY_VERTICAL_SPEED := 15.0
const FLY_ACCEL := 42.0

var peer_id := 1
var display_name := "Monkey"
var is_local := true
var is_ai := false
var world: Node3D
var health := MAX_HEALTH
var bandages := 0
var healing_remaining := 0.0
var supply_notice := ""
var supply_notice_remaining := 0.0
var defeated := false
var defeat_sequence := 0
var _defeat_presentation_started := false

var state: int = S.AIR
var jumps_used := 0
var coyote_t := 0.0
var buffer_t := 0.0
var regrab_t := 0.0
var roll_t := 0.0
var dived := false
var wallsliding := false
var galloping := false
var sprint_held := false
var quad_t := 0.0      # keeps the all-fours pose through brief gallop bounds
var flipping := false
var flip_dir := 1
var skid_t := 0.0
var in_water := false

var swing_anchor := Vector3.ZERO
var swing_len := 5.0
var swing_len_target := 5.0
var swing_vine_len := 10.0
var swing_max_len := 20.0
var swing_vine_id := ""
var wraps: Array = []        # rope wrap pivots (vine bending around geometry)
var wrap_used := 0.0         # rope length consumed between anchor and pivot
var wrap_t := 0.0
var vine_cd: Dictionary = {}
var last_target: Dictionary = {}

var rig: MonkeyRig
var cam: CameraRig
var wind: AudioStreamPlayer
var gun: BananaGun
var shotgun: PumpShotgun
var smg: SMG
var sniper: SniperRifle
var active_weapon: Node3D
var weapon_slot := 1
var melee_mode := false
var fly_mode := false
var vehicle: Vehicle = null
var expedition_locked := false
var _vehicle_exit_cd := 0.0
var _collision_shape: CollisionShape3D
var melee_attack_remaining := 0.0
var melee_attack_combo := 0
var body_hitbox: CombatHitbox
var head_hitbox: CombatHitbox
var death_ragdoll: MonkeyRagdoll

# test-injected input (movetest drives the monkey through this)
var test_mode := false
var ti := {"dir": Vector2.ZERO, "jump_just": false, "jump_held": false, "sprint": false,
	"crouch_just": false, "crouch_held": false, "grab": false, "reel": 0.0,
	"shoot_just": false, "shoot_held": false, "reload_just": false,
	"melee_toggle_just": false, "scope_zoom_just": false,
	"interact_just": false, "use_bandage_just": false,
	"vehicle_gear_just": false, "vehicle_flaps_just": false,
	"vehicle_pitch": 0.0}

var _send_t := 0.0
var _now := 0.0
var _wheel_reel_delta := 0.0
var _invulnerable_t := 0.0
## Earth-normal unless a realm controller places this actor on the Moon. This
## is per monkey so Earth and lunar players can coexist in one multiplayer
## process without changing ProjectSettings' global gravity.
var environment_gravity_mps2 := FREEFALL_ACCELERATION
var _shot_spread_sequence := 0
var _next_melee_combo := 0
var _melee_hit_done := false
var _melee_combo_timeout := 0.0
var _weapon_hand_transforms: Dictionary = {}
var _weapon_visual_stowed := false
var _mounted_weapon: Node3D
var _first_person_weapons_requested := false
var _weapon_view_parent: Node3D
var _last_swim_fx_cycle := -1.0
var _last_swim_kick_bucket := -1
var _last_gallop_audio_cycle := -1.0
var _healing_applied := false
var _healing_event_mask := 0


func _ready() -> void:
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	# capsule bottom sits exactly at the node origin (= the rig's feet),
	# so the monkey stands flush on terrain, canopies, branches and rocks
	cap.radius = 0.26
	cap.height = 1.0
	cs.shape = cap
	cs.position = Vector3(0, 0.5, 0)
	add_child(cs)
	_collision_shape = cs
	# stick to rolling terrain at gallop speed instead of launching off
	# every knoll — jumps still clear it because move_and_slide skips the
	# snap while velocity points away from the floor
	floor_snap_length = 0.8
	safe_margin = DEFAULT_COLLISION_SAFE_MARGIN

	body_hitbox = CombatHitbox.new()
	body_hitbox.name = "BodyHitbox"
	body_hitbox.setup_capsule(self, "body", PROJECTILE_BODY_RADIUS,
		PROJECTILE_BODY_HEIGHT)
	body_hitbox.position = Vector3(0, PROJECTILE_BODY_HEIGHT * 0.5, 0)
	add_child(body_hitbox)
	head_hitbox = CombatHitbox.new()
	head_hitbox.name = "HeadHitbox"
	head_hitbox.setup(self, "head", PROJECTILE_HEAD_RADIUS)
	head_hitbox.position = Vector3(0, 1.17, -0.015)
	add_child(head_hitbox)

	rig = MonkeyRig.new()
	rig.setup(display_name, is_ai)
	add_child(rig)
	# Combat zones follow the visible skeleton. Keeping these directly under the
	# CharacterBody left an upright ghost head/torso during gallops, swimming and
	# rope poses, which made the scope's red acquisition cue visibly dishonest.
	body_hitbox.reparent(rig.torso_p, false)
	body_hitbox.position = Vector3(0.0, -0.06, 0.0)
	head_hitbox.reparent(rig.head_p, false)
	head_hitbox.position = Vector3(0.0, 0.0, -0.015)

	gun = BananaGun.new()
	gun.configure(self, world)
	rig.el_r.add_child(gun)
	shotgun = PumpShotgun.new()
	shotgun.configure(self, world)
	rig.el_r.add_child(shotgun)
	shotgun.visible = false
	smg = SMG.new()
	smg.configure(self, world)
	rig.el_r.add_child(smg)
	smg.visible = false
	sniper = SniperRifle.new()
	sniper.configure(self, world)
	rig.el_r.add_child(sniper)
	sniper.visible = false
	active_weapon = gun
	_weapon_hand_transforms = {
		gun: gun.transform,
		shotgun: shotgun.transform,
		smg: smg.transform,
		sniper: sniper.transform,
	}

	if is_local:
		cam = CameraRig.new()
		cam.target = self
		add_child(cam)
		landed.connect(cam.on_land)
		wind = AudioStreamPlayer.new()
		wind.stream = Sfx.streams.get("wind")
		wind.volume_db = -60.0
		wind.bus = &"Ambience"
		add_child(wind)
		if wind.stream:
			wind.play()


func _physics_process(dt: float) -> void:
	if not is_local and not is_ai:
		return
	if gun:
		gun.tick(dt)
	if shotgun:
		shotgun.tick(dt)
	if smg:
		smg.tick(dt)
	if sniper:
		sniper.tick(dt)
	_update_bandage(dt)
	supply_notice_remaining = maxf(supply_notice_remaining - dt, 0.0)
	_invulnerable_t = maxf(_invulnerable_t - dt, 0.0)
	if defeated:
		return
	if expedition_locked:
		velocity = Vector3.ZERO
		state = S.AIR
		_replicate_expedition_pose(dt)
		return
	_update_melee(dt)
	_now += dt
	regrab_t = maxf(regrab_t - dt, 0.0)
	buffer_t = maxf(buffer_t - dt, 0.0)
	roll_t = maxf(roll_t - dt, 0.0)

	var inp := _gather()
	if vehicle:
		_st_vehicle(dt, inp)
		return
	if inp.interact_just and state != S.SWING and is_local and world \
			and world.has_method("try_expedition_interact") \
			and world.try_expedition_interact(self):
		inp.interact_just = false
		inp.grab = false
	if inp.interact_just and state != S.SWING and is_local and world \
			and world.has_method("try_open_villager_trade") \
			and world.try_open_villager_trade(self):
		inp.interact_just = false
		inp.grab = false
	if inp.interact_just and state != S.SWING and world \
			and world.has_method("try_open_supply_chest") \
			and world.try_open_supply_chest(self):
		# E remains vine grab everywhere else; a chest in arm's reach wins only
		# for this tap so one input can stay cleanly contextual.
		inp.grab = false
	if inp.interact_just and state != S.SWING and world \
			and world.has_method("try_enter_vehicle") \
			and world.try_enter_vehicle(self):
		# Mounting wins this tap the same way a chest does.
		inp.grab = false
	if inp.jump_just:
		buffer_t = JUMP_BUFFER

	var pre_floor := is_on_floor()
	var pre_vy := velocity.y

	if fly_mode:
		_st_fly(dt, inp)
	else:
		match state:
			S.GROUND: _st_ground(dt, inp)
			S.SLIDE: _st_slide(dt, inp)
			S.AIR: _st_air(dt, inp)
			S.SWING: _st_swing(dt, inp)
			S.SWIM: _st_swim(dt, inp)

	_limit_velocity_for_state()
	move_and_slide()
	_post(dt, inp, pre_floor, pre_vy)
	_combat(inp)


## Preserve the existing safety bound for authored/powered movement, but never
## turn it into a terminal velocity for a freely falling monkey. Horizontal
## momentum remains bounded independently so a long fall cannot become a
## sideways teleport when it lands.
func _limit_velocity_for_state() -> void:
	var freefalling := state == S.AIR and not fly_mode \
		and velocity.y < 0.0 and not wallsliding
	if not freefalling:
		velocity = velocity.limit_length(ABS_MAX)
		return
	var planar := Vector3(velocity.x, 0.0, velocity.z).limit_length(ABS_MAX)
	velocity.x = planar.x
	velocity.z = planar.z


func _gather() -> Dictionary:
	if test_mode:
		var out := {
			"dir": ti.dir, "jump_just": ti.jump_just, "jump_held": ti.jump_held,
			"sprint": ti.sprint, "crouch_just": ti.crouch_just, "crouch_held": ti.crouch_held,
			"grab": ti.grab, "reel": ti.reel, "reel_delta": 0.0,
			"shoot_just": ti.shoot_just, "shoot_held": ti.shoot_held,
			"reload_just": ti.reload_just, "weapon_1_just": false,
			"weapon_2_just": false, "weapon_3_just": false,
			"weapon_4_just": false, "scope_zoom_just": ti.scope_zoom_just,
			"melee_toggle_just": ti.melee_toggle_just,
			"interact_just": ti.interact_just,
			"use_bandage_just": ti.use_bandage_just,
			"vehicle_gear_just": ti.vehicle_gear_just,
			"vehicle_flaps_just": ti.vehicle_flaps_just,
			"vehicle_pitch": ti.vehicle_pitch,
		}
		ti.jump_just = false
		ti.crouch_just = false
		ti.shoot_just = false
		ti.reload_just = false
		ti.scope_zoom_just = false
		ti.melee_toggle_just = false
		ti.interact_just = false
		ti.use_bandage_just = false
		ti.vehicle_gear_just = false
		ti.vehicle_flaps_just = false
		return out
	var wheel_delta := _wheel_reel_delta
	_wheel_reel_delta = 0.0
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	# A visible cursor means a menu owns the keyboard and mouse. Returning a
	# completely neutral frame also protects online pause/settings screens, where
	# the shared world keeps simulating even though this local player must not.
	if not captured:
		return {
			"dir": Vector2.ZERO, "jump_just": false, "jump_held": false,
			"sprint": false, "crouch_just": false, "crouch_held": false,
			"grab": false, "reel": 0.0, "reel_delta": 0.0,
			"shoot_just": false, "shoot_held": false,
			"reload_just": false, "interact_just": false,
			"use_bandage_just": false, "melee_toggle_just": false,
			"weapon_1_just": false, "weapon_2_just": false,
			"weapon_3_just": false, "weapon_4_just": false,
			"scope_zoom_just": false,
			"vehicle_gear_just": false, "vehicle_flaps_just": false,
			"vehicle_pitch": 0.0,
		}
	return {
		"dir": Input.get_vector("move_left", "move_right", "move_fwd", "move_back"),
		"jump_just": Input.is_action_just_pressed("jump"),
		"jump_held": Input.is_action_pressed("jump"),
		"sprint": Input.is_action_pressed("sprint"),
		"crouch_just": Input.is_action_just_pressed("crouch"),
		"crouch_held": Input.is_action_pressed("crouch"),
		"grab": Input.is_action_pressed("grab"),
		"reel": 0.0,
		"reel_delta": wheel_delta,
		"shoot_just": captured and Input.is_action_just_pressed("shoot"),
		"shoot_held": captured and Input.is_action_pressed("shoot"),
		"reload_just": Input.is_action_just_pressed("reload"),
		"interact_just": Input.is_action_just_pressed("grab"),
		"use_bandage_just": Input.is_action_just_pressed("use_bandage"),
		"melee_toggle_just": Input.is_action_just_pressed("melee_toggle"),
		"weapon_1_just": Input.is_action_just_pressed("weapon_1"),
		"weapon_2_just": Input.is_action_just_pressed("weapon_2"),
		"weapon_3_just": Input.is_action_just_pressed("weapon_3"),
		"weapon_4_just": Input.is_action_just_pressed("weapon_4"),
		"scope_zoom_just": Input.is_action_just_pressed("scope_zoom"),
		"vehicle_gear_just": Input.is_action_just_pressed("vehicle_gear"),
		"vehicle_flaps_just": Input.is_action_just_pressed("vehicle_flaps"),
		"vehicle_pitch": Input.get_axis("vehicle_pitch_down", "vehicle_pitch_up"),
	}


func _input(event: InputEvent) -> void:
	if not is_local or not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.is_action_pressed("reel_in"):
		_wheel_reel_delta -= WHEEL_REEL_STEP * maxf(event.factor, 0.25)
	elif event.is_action_pressed("reel_out"):
		_wheel_reel_delta += WHEEL_REEL_STEP * maxf(event.factor, 0.25)


func _wish_dir(inp: Dictionary) -> Vector3:
	var d: Vector2 = inp.dir
	if d.length() < 0.05:
		return Vector3.ZERO
	if test_mode or cam == null:
		return Vector3(d.x, 0, d.y).normalized()
	var b := Basis(Vector3.UP, cam.yaw)
	return (b * Vector3(d.x, 0, d.y)).normalized()


func _flat_facing() -> Vector3:
	if not test_mode and cam:
		var f := -cam.cam_basis().z
		f.y = 0
		if f.length() > 0.01:
			return f.normalized()
	return Vector3(0, 0, -1)


func hand_pos() -> Vector3:
	return global_position + Vector3.UP * HAND_H


## Crosshair ray for vine targeting: camera position + full 3D look direction.
func _aim() -> Array:
	if cam and cam.front_view:
		# The front camera looks back at the monkey, so its own forward ray
		# would pass through the player. Face toward the lens from the hand
		# instead, while keeping this mode a safe character-view camera.
		return [hand_pos(), cam.front_subject_direction()]
	if not test_mode and cam:
		return [cam.cam_pos(), -cam.cam_basis().z.normalized()]
	return [hand_pos(), Vector3(0, 0, -1)]


func shot_aim() -> Array:
	return _aim()


func _combat(inp: Dictionary) -> void:
	if inp.use_bandage_just:
		start_bandage()
	if is_healing():
		if state != S.GROUND or is_all_fours():
			_cancel_bandage()
		else:
			return
	if inp.melee_toggle_just:
		set_melee_mode(not melee_mode)
	if inp.weapon_1_just:
		equip_weapon(1)
	elif inp.weapon_2_just:
		equip_weapon(2)
	elif inp.weapon_3_just:
		equip_weapon(3)
	elif inp.weapon_4_just:
		equip_weapon(4)
	var weapon = active_weapon
	if not weapon:
		return
	if inp.scope_zoom_just and weapon is SniperRifle:
		weapon.cycle_zoom()
	if melee_mode:
		if cam and cam.front_view:
			return
		if inp.shoot_just:
			_start_melee_attack()
		return
	# The weapon is physically on the back during a quadruped burst (and while
	# swimming), so firing stays locked until the monkey rises onto two feet.
	if is_all_fours() or state == S.SWIM:
		return
	# Reload choreography owns the support paw. While swinging that paw is the
	# rope contact, so wait until release instead of letting a magazine or shell
	# float through an occupied hand.
	if inp.reload_just and state != S.SWING:
		if weapon.start_reload() and cam:
			# Pull out of ADS so the trick props, support paw, and sniper bolt
			# flourish cannot be hidden behind an optic overlay.
			cam.set_aiming(false)
	if cam and cam.front_view:
		return
	var wants_to_fire: bool = inp.shoot_held if weapon is SMG else inp.shoot_just
	if not wants_to_fire:
		return
	var aim := shot_aim()
	var camera_origin: Vector3 = aim[0]
	var camera_direction: Vector3 = aim[1].normalized()
	var right := camera_direction.cross(Vector3.UP)
	if right.length_squared() < 0.01:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var origin := hand_pos() + camera_direction * 0.48 + right * 0.19 + Vector3.UP * 0.05
	# Converge the hand-level muzzle onto the center-camera ray. This keeps
	# close and distant shots on the crosshair instead of travelling along a
	# parallel line several metres below the camera.
	var aim_distance := 800.0 if weapon is SniperRifle else 240.0
	var aim_point := camera_origin + camera_direction * aim_distance
	var query := PhysicsRayQueryParameters3D.create(camera_origin, aim_point)
	query.exclude = [get_rid()]
	query.collision_mask = 1
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		aim_point = hit.position
	var direction := (aim_point - origin).normalized()
	var spread_degrees := current_weapon_spread_degrees()
	if spread_degrees > 0.0:
		_shot_spread_sequence += 1
		var spread_seed := (
			_shot_spread_sequence * 104729
			+ peer_id * 8191
			+ int(_now * 1000.0)
		)
		direction = spread_direction(direction, spread_degrees, spread_seed)
	if weapon.try_fire(origin, direction) and cam:
		var camera_recoil := BananaGun.CAMERA_RECOIL
		if weapon is PumpShotgun:
			camera_recoil = PumpShotgun.CAMERA_RECOIL
		elif weapon is SMG:
			camera_recoil = SMG.CAMERA_RECOIL
		elif weapon is SniperRifle:
			camera_recoil = SniperRifle.CAMERA_RECOIL
		cam.add_weapon_recoil(camera_recoil)


func _update_melee(dt: float) -> void:
	_melee_combo_timeout = maxf(_melee_combo_timeout - dt, 0.0)
	if melee_attack_remaining <= 0.0:
		if _melee_combo_timeout <= 0.0:
			_next_melee_combo = 0
		return
	melee_attack_remaining = maxf(melee_attack_remaining - dt, 0.0)
	var progress := melee_attack_progress()
	if not _melee_hit_done and progress >= MELEE_HIT_PROGRESS:
		_melee_hit_done = true
		_perform_melee_hit()


func _start_melee_attack() -> bool:
	if not melee_mode or melee_attack_remaining > 0.0 \
			or state in [S.SWING, S.SWIM] or defeated:
		return false
	melee_attack_combo = _next_melee_combo
	_next_melee_combo = (_next_melee_combo + 1) % 3
	_melee_combo_timeout = MELEE_COMBO_RESET_TIME
	melee_attack_remaining = MELEE_ATTACK_DURATION
	_melee_hit_done = false
	Sfx.play_at("melee_swing", global_position + Vector3.UP * 0.85, -8.0)
	return true


func melee_attack_progress() -> float:
	return 0.0 if melee_attack_remaining <= 0.0 else \
		1.0 - melee_attack_remaining / MELEE_ATTACK_DURATION


func _perform_melee_hit() -> void:
	if not world:
		return
	var aim := shot_aim()
	var direction: Vector3 = aim[1]
	direction.y = clampf(direction.y, -0.35, 0.35)
	direction = direction.normalized()
	var origin := global_position + Vector3.UP * 0.78
	if Net.active and is_local:
		Net.melee_attack(origin, direction, melee_attack_combo)
	elif world.has_method("perform_melee"):
		world.perform_melee(self, origin, direction, melee_attack_combo)


## Half-angle used by both projectile direction and the HUD. A truly still
## monkey returns zero so the muzzle-to-camera convergence lands exactly at the
## center of the reticle. Ground movement adds only a small error; unsupported
## air movement is looser, and one-arm vine shooting is deliberately wild.
func current_weapon_spread_degrees() -> float:
	if is_ai:
		# AiMonkey already supplies a larger deliberate error in shot_aim().
		return 0.0
	var speed := velocity.length()
	if active_weapon is SniperRifle:
		# The optic is mechanically exact at its center; the challenge when scoped
		# is holding the moving sight steady and compensating for projectile drop.
		if cam and cam.aiming:
			return 0.0
		var sniper_speed_weight := clampf(
			(speed - ACCURACY_STILL_SPEED) /
			(SPRINT_SPEED - ACCURACY_STILL_SPEED), 0.0, 1.0)
		if state == S.SWING:
			return SNIPER_SWING_SPREAD_HALF_ANGLE_DEGREES
		if state == S.AIR:
			return SNIPER_AIR_SPREAD_HALF_ANGLE_DEGREES
		return lerpf(SNIPER_HIP_SPREAD_HALF_ANGLE_DEGREES,
			SNIPER_HIP_MOVE_SPREAD_HALF_ANGLE_DEGREES,
			sniper_speed_weight)
	if speed <= ACCURACY_STILL_SPEED and state != S.SWING:
		return 0.0
	var speed_weight := clampf(
		(speed - ACCURACY_STILL_SPEED) / (SPRINT_SPEED - ACCURACY_STILL_SPEED),
		0.0, 1.0)
	if state == S.SWING:
		var swing_weight := clampf(speed / 24.0, 0.0, 1.0)
		return lerpf(SWING_SPREAD_MIN_HALF_ANGLE_DEGREES,
			SWING_SPREAD_MAX_HALF_ANGLE_DEGREES, swing_weight)
	if state == S.AIR:
		return AIR_SPREAD_HALF_ANGLE_DEGREES * lerpf(0.55, 1.0, speed_weight)
	return MOVE_SPREAD_HALF_ANGLE_DEGREES * speed_weight


static func spread_direction(forward: Vector3, half_angle_degrees: float,
		seed_value: int) -> Vector3:
	var aim := forward.normalized()
	if half_angle_degrees <= 0.0:
		return aim
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var right := aim.cross(Vector3.UP)
	if right.length_squared() < 0.01:
		right = aim.cross(Vector3.RIGHT)
	right = right.normalized()
	var up := right.cross(aim).normalized()
	var angle := rng.randf() * TAU
	var radius := sqrt(rng.randf()) * tan(deg_to_rad(half_angle_degrees))
	return (aim + right * cos(angle) * radius
		+ up * sin(angle) * radius).normalized()


func equip_weapon(slot: int) -> void:
	if melee_mode:
		melee_mode = false
		melee_attack_remaining = 0.0
	var next_slot := clampi(slot, 1, 4)
	if weapon_slot == next_slot and active_weapon:
		_sync_weapon_presentation(true)
		return
	if active_weapon and active_weapon.reload_remaining > 0.0 \
			and active_weapon.has_method("cancel_reload"):
		# A weapon switch is a deliberate reload cancel. This prevents hidden
		# weapons from filling themselves in parallel and keeps every magazine
		# swap tied to the gun the player is actually handling.
		active_weapon.cancel_reload()
	weapon_slot = next_slot
	match weapon_slot:
		2:
			active_weapon = shotgun
		3:
			active_weapon = smg
		4:
			active_weapon = sniper
		_:
			active_weapon = gun
	if gun:
		gun.visible = not defeated and active_weapon == gun
	if shotgun:
		shotgun.visible = not defeated and active_weapon == shotgun
	if smg:
		smg.visible = not defeated and active_weapon == smg
	if sniper:
		sniper.visible = not defeated and active_weapon == sniper
	_sync_weapon_presentation(true)
	Sfx.play_at("weapon_switch", global_position + Vector3.UP, -10.0)


func set_first_person_weapons(enabled: bool, view_parent: Node3D) -> void:
	_first_person_weapons_requested = enabled
	_weapon_view_parent = view_parent
	_sync_weapon_presentation(true)


func set_melee_mode(enabled: bool) -> void:
	if melee_mode == enabled:
		return
	melee_mode = enabled
	if not enabled:
		melee_attack_remaining = 0.0
		_next_melee_combo = 0
		_melee_combo_timeout = 0.0
	_sync_weapon_presentation(true)
	Sfx.play_at("weapon_switch", global_position + Vector3.UP, -11.0)


## True whenever the monkey needs all four limbs on (or reaching for) the
## ground: every intentional sprint, an earned high-speed gallop, and the
## airborne stretch between gallop bounds.
func is_all_fours() -> bool:
	if galloping:
		return true
	var h := Vector3(velocity.x, 0, velocity.z).length()
	# Drop as soon as the sprint has visibly started. Keeping this threshold
	# close to one acceleration frame removes the old biped-to-quadruped pop.
	if state == S.GROUND and sprint_held and h > 0.6:
		return true
	return state == S.AIR and quad_t > 0.0 \
		and not dived and not wallsliding and not flipping


func is_weapon_stowed() -> bool:
	return melee_mode or is_healing() or is_all_fours() or state == S.SWIM \
		or vehicle != null or expedition_locked


## First-person sprinting keeps the viewmodel in frame even though the weapon is
## still gameplay-stowed and cannot fire. Third person retains the full
## quadruped back-stow so all four limbs remain believable in the world model.
func is_weapon_visually_stowed() -> bool:
	if _first_person_weapons_requested:
		return melee_mode or is_healing() or state == S.SWIM \
			or vehicle != null or expedition_locked
	return is_weapon_stowed()


func _sync_weapon_presentation(force := false) -> void:
	if not rig or not active_weapon:
		return
	var should_stow := is_weapon_visually_stowed()
	if not force and should_stow == _weapon_visual_stowed \
			and _mounted_weapon == active_weapon:
		return
	var weapons: Array[Node3D] = [gun, shotgun, smg, sniper]
	for weapon in weapons:
		if weapon.first_person_view:
			weapon.set_first_person_view(false, _weapon_view_parent)
		if weapon.get_parent() != rig.el_r:
			weapon.reparent(rig.el_r, false)
		if _weapon_hand_transforms.has(weapon):
			weapon.transform = _weapon_hand_transforms[weapon]

	if should_stow:
		active_weapon.reparent(rig.weapon_back_mount, false)
		active_weapon.transform = _weapon_back_transform(active_weapon)
	elif _first_person_weapons_requested and _weapon_view_parent:
		for weapon in weapons:
			weapon.set_first_person_view(true, _weapon_view_parent)

	_weapon_visual_stowed = should_stow
	_mounted_weapon = active_weapon
	gun.visible = not defeated and active_weapon == gun
	shotgun.visible = not defeated and active_weapon == shotgun
	smg.visible = not defeated and active_weapon == smg
	sniper.visible = not defeated and active_weapon == sniper


func _weapon_back_transform(weapon: Node3D) -> Transform3D:
	var direction := Vector3(-0.58, 0.815, 0.0).normalized()
	var local_z := -direction
	var local_x := Vector3.BACK.cross(local_z).normalized()
	var local_y := local_z.cross(local_x).normalized()
	var basis := Basis(local_x, local_y, local_z)
	var hand_transform: Transform3D = _weapon_hand_transforms.get(
		weapon, Transform3D.IDENTITY)
	var uniform_scale := hand_transform.basis.get_scale().x
	basis = basis.scaled(Vector3.ONE * uniform_scale)
	var back_position := Vector3(0.0, -0.08, 0.0)
	if weapon is BananaGun:
		back_position = Vector3(0.01, -0.02, 0.0)
	elif weapon is PumpShotgun:
		back_position = Vector3(0.0, -0.14, 0.0)
	elif weapon is SniperRifle:
		back_position = Vector3(0.0, -0.20, 0.02)
	return Transform3D(basis, back_position)


func receive_supply_loot(ammo_kind: int, ammo_amount: int,
		bandage_count: int) -> void:
	var accepted_ammo := 0
	match ammo_kind:
		Gen.SUPPLY_AMMO_SHOTGUN:
			accepted_ammo = shotgun.add_reserve_ammo(ammo_amount)
		Gen.SUPPLY_AMMO_SMG:
			accepted_ammo = smg.add_reserve_ammo(ammo_amount)
		Gen.SUPPLY_AMMO_SNIPER:
			accepted_ammo = sniper.add_reserve_ammo(ammo_amount)
		_:
			accepted_ammo = gun.add_reserve_ammo(ammo_amount)
	var old_bandages := bandages
	bandages = mini(bandages + maxi(bandage_count, 0), MAX_BANDAGES)
	var accepted_bandages := bandages - old_bandages
	if accepted_bandages > 0:
		bandages_changed.emit(bandages)
	var ammo_name: String = ["BANANA", "SHELL", "SMG", "SNIPER"][
		clampi(ammo_kind, 0, 3)]
	supply_notice = "+%d %s AMMO" % [accepted_ammo, ammo_name]
	if accepted_bandages > 0:
		supply_notice += "  ·  +%d BANDAGE%s" % [accepted_bandages,
			"S" if accepted_bandages != 1 else ""]
	if accepted_ammo <= 0 and accepted_bandages <= 0:
		supply_notice = "SUPPLIES FULL"
	supply_notice_remaining = 3.2


func is_healing() -> bool:
	return healing_remaining > 0.0


func bandage_progress() -> float:
	return 0.0 if healing_remaining <= 0.0 \
		else 1.0 - healing_remaining / BANDAGE_TIME


func start_bandage() -> bool:
	if is_healing() or defeated or bandages <= 0 or health >= MAX_HEALTH \
			or state != S.GROUND or is_all_fours():
		return false
	if active_weapon and active_weapon.reload_remaining > 0.0:
		return false
	bandages -= 1
	bandages_changed.emit(bandages)
	healing_remaining = BANDAGE_TIME
	_healing_applied = false
	_healing_event_mask = 0
	melee_mode = false
	melee_attack_remaining = 0.0
	_sync_weapon_presentation(true)
	Sfx.play_at("bandage_unroll", global_position + Vector3.UP * 0.85,
		-5.0, 1.0, 28.0)
	return true


func _update_bandage(dt: float) -> void:
	if healing_remaining <= 0.0:
		return
	if state != S.GROUND or is_all_fours():
		_cancel_bandage()
		return
	var previous := bandage_progress()
	healing_remaining = maxf(healing_remaining - dt, 0.0)
	var current := 1.0 if healing_remaining <= 0.0 else bandage_progress()
	_healing_event(previous, current, 0.27, 1, "bandage_wrap", 1.03)
	_healing_event(previous, current, 0.58, 2, "bandage_wrap", 1.13)
	_healing_event(previous, current, 0.78, 4, "bandage_tear", 0.98)
	if not _healing_applied and SatisfyingReload.crossed(previous, current, 0.84):
		_healing_applied = true
		heal(BANDAGE_HEAL)
		Sfx.play_at("heal_finish", global_position + Vector3.UP * 0.85,
			-3.0, 1.0, 30.0)
		WeaponFX.spawn_glint(get_tree().current_scene,
			global_position + Vector3.UP * 0.92, Color(0.34, 1.0, 0.42), 1.4)
	if healing_remaining <= 0.0:
		_healing_event_mask = 0
		_sync_weapon_presentation(true)


func _healing_event(previous: float, current: float, threshold: float,
		bit: int, sound_name: String, pitch: float) -> void:
	if (_healing_event_mask & bit) != 0 \
		or not SatisfyingReload.crossed(previous, current, threshold):
		return
	_healing_event_mask |= bit
	Sfx.play_at(sound_name, global_position + Vector3.UP * 0.85,
		-6.0, pitch, 26.0)


func heal(amount: float) -> float:
	if defeated or amount <= 0.0:
		return 0.0
	var before := health
	health = minf(health + amount, MAX_HEALTH)
	var restored := health - before
	if restored > 0.0:
		health_changed.emit(health, MAX_HEALTH)
		_update_nameplate()
	return restored


func _cancel_bandage() -> void:
	if healing_remaining <= 0.0:
		return
	healing_remaining = 0.0
	_healing_event_mask = 0
	Sfx.play_at("bandage_cancel", global_position + Vector3.UP * 0.8,
		-9.0, 0.86, 22.0)
	_sync_weapon_presentation(true)


func take_damage(amount: float, source: Node3D, impulse: Vector3,
		hit_zone := "body") -> void:
	if defeated or _invulnerable_t > 0.0:
		return
	_cancel_bandage()
	health = maxf(health - amount, 0.0)
	velocity += impulse
	if cam:
		cam.on_hit(amount, impulse)
		if hit_zone == "head":
			cam.on_headshot()
	health_changed.emit(health, MAX_HEALTH)
	_update_nameplate()
	Sfx.play_at("bullet_hit", global_position + Vector3.UP * 0.8, -5.0)
	if health <= 0.0:
		defeated = true
		defeated_by.emit(source)
		if world and world.has_method("actor_defeated"):
			world.actor_defeated(self, source, hit_zone, impulse)


func begin_defeat(hit_zone := "body", impact_impulse := Vector3.ZERO) -> void:
	if _defeat_presentation_started:
		return
	_defeat_presentation_started = true
	if vehicle:
		exit_vehicle(true)
	if rig:
		rig.reset_pose_state(true)
	defeated = true
	defeat_sequence += 1
	var death_velocity := velocity
	# Defeat freezes the controller before its ordinary timer decay. Clear every
	# buffered traversal state now so a later revive cannot resume a stale roll,
	# gallop, coyote jump, rope wrap or vehicle animation.
	coyote_t = 0.0
	buffer_t = 0.0
	regrab_t = 0.0
	roll_t = 0.0
	quad_t = 0.0
	skid_t = 0.0
	wrap_t = 0.0
	wrap_used = 0.0
	var spawn_parent: Node = world if world else get_parent()
	if spawn_parent and not death_ragdoll:
		death_ragdoll = MonkeyRagdoll.new()
		death_ragdoll.configure(display_name, global_position,
			rig.yaw_angle() if rig else rotation.y, death_velocity,
			impact_impulse, hit_zone == "head")
		spawn_parent.add_child(death_ragdoll)
		if cam:
			cam.begin_death_view(death_ragdoll.follow_target())
	if is_local:
		Net.send_defeat(global_position, rig.yaw_angle() if rig else rotation.y,
			death_velocity, impact_impulse, hit_zone == "head")
	velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	if body_hitbox:
		body_hitbox.set_active(false)
	if head_hitbox:
		head_hitbox.set_active(false)
	last_target = {}
	if rig:
		rig.visible = false
	if gun:
		gun.visible = false
	if shotgun:
		shotgun.visible = false
	if smg:
		smg.visible = false
	if sniper:
		sniper.visible = false


func revive_at(pos: Vector3) -> void:
	if cam:
		cam.end_death_view()
	if is_instance_valid(death_ragdoll):
		death_ragdoll.queue_free()
	death_ragdoll = null
	global_position = pos
	reset_physics_interpolation()
	velocity = Vector3.ZERO
	state = S.AIR
	jumps_used = 0
	coyote_t = 0.0
	buffer_t = 0.0
	regrab_t = 0.0
	roll_t = 0.0
	quad_t = 0.0
	wrap_t = 0.0
	wrap_used = 0.0
	dived = false
	wallsliding = false
	galloping = false
	melee_mode = false
	melee_attack_remaining = 0.0
	healing_remaining = 0.0
	_healing_applied = false
	_healing_event_mask = 0
	flipping = false
	skid_t = 0.0
	wraps.clear()
	swing_vine_id = ""
	health = MAX_HEALTH
	defeated = false
	_defeat_presentation_started = false
	_invulnerable_t = 1.5
	collision_layer = 1
	collision_mask = 1
	if body_hitbox:
		body_hitbox.set_active(true)
	if head_hitbox:
		head_hitbox.set_active(true)
	if rig:
		rig.reset_pose_state(false)
		rig.visible = true
	if gun:
		gun.visible = active_weapon == gun
		gun.reset_cylinder()
	if shotgun:
		shotgun.visible = active_weapon == shotgun
		shotgun.reset_cylinder()
	if smg:
		smg.visible = active_weapon == smg
		smg.reset_cylinder()
	if sniper:
		sniper.visible = active_weapon == sniper
		sniper.reset_cylinder()
	_sync_weapon_presentation(true)
	if cam:
		cam.snap_to_target()
	health_changed.emit(health, MAX_HEALTH)
	_update_nameplate()


func _update_nameplate() -> void:
	if rig and rig.tag:
		rig.tag.text = "%s  %d" % [display_name, ceili(health)]


func set_environment_gravity(acceleration_mps2: float) -> void:
	environment_gravity_mps2 = clampf(acceleration_mps2, 0.1,
		FREEFALL_ACCELERATION)
	safe_margin = LUNAR_COLLISION_SAFE_MARGIN \
		if environment_gravity_mps2 < FREEFALL_ACCELERATION * 0.5 \
		else DEFAULT_COLLISION_SAFE_MARGIN


func reset_environment_gravity() -> void:
	environment_gravity_mps2 = FREEFALL_ACCELERATION
	safe_margin = DEFAULT_COLLISION_SAFE_MARGIN


## Move this actor to the equivalent local chart image after crossing the
## longitude seam or a pole. Pole reflections rotate planar momentum and the
## view by 180°, so holding forward continues along one great-circle path.
func apply_planet_wrap(canonical_xz: Vector2, yaw_delta: float) -> void:
	if state == S.SWING:
		# A vine belongs to the old streamed chart image. Releasing avoids drawing a
		# planet-wide rope while preserving the monkey's incoming momentum.
		_release(false)
	var next_position := global_position
	next_position.x = canonical_xz.x
	next_position.z = canonical_xz.y
	if absf(yaw_delta) > 0.000001:
		var turn := Basis(Vector3.UP, yaw_delta)
		velocity = turn * velocity
		if rig:
			rig.set_yaw(wrapf(rig.yaw_angle() + yaw_delta, -PI, PI))
	global_position = next_position
	reset_physics_interpolation()
	if cam:
		cam.apply_planet_heading_delta(yaw_delta)


func set_expedition_locked(locked: bool) -> void:
	var changed := expedition_locked != locked
	if locked:
		if changed:
			if vehicle:
				exit_vehicle()
			if state == S.SWING:
				_release(false)
		velocity = Vector3.ZERO
		if _collision_shape:
			_collision_shape.set_deferred("disabled", true)
		collision_layer = 0
		collision_mask = 0
	elif not defeated and vehicle == null:
		# This write is deliberately idempotent. Realm and manifest packets are
		# separate signals, while CollisionShape changes are deferred by physics;
		# reasserting the on-foot state repairs either arrival order instead of
		# leaving an unlocked boolean with a disabled capsule on the Moon.
		if _collision_shape:
			_collision_shape.set_deferred("disabled", false)
		collision_layer = 1
		collision_mask = 1
		if changed:
			state = S.AIR
			reset_physics_interpolation()
	expedition_locked = locked
	if changed:
		_sync_weapon_presentation(true)


func _replicate_expedition_pose(dt: float) -> void:
	_send_t += dt
	if Net.active and _send_t >= 0.05:
		_send_t = 0.0
		Net.send_state(global_position, rig.yaw_angle(), Vector3.ZERO, _anim(),
			false, Vector3.ZERO, 0.0, PackedVector3Array(), weapon_slot - 1,
			true, false, int(active_weapon.ammo) if active_weapon else 0,
			false, 0.0, false)


func _environment_gravity_ratio() -> float:
	return environment_gravity_mps2 / FREEFALL_ACCELERATION


## Suit-limited takeoff scales with sqrt(g), preserving readable jump height
## while the much longer low-gravity hang time supplies the lunar feel.
func _environment_jump_velocity(earth_velocity: float) -> float:
	return earth_velocity * sqrt(_environment_gravity_ratio())


func _environment_traversal_gravity() -> float:
	return GRAVITY * _environment_gravity_ratio()


# ---- states ----------------------------------------------------------------

func _st_ground(dt: float, inp: Dictionary) -> void:
	jumps_used = 0
	coyote_t = COYOTE
	dived = false
	wallsliding = false
	flipping = false
	sprint_held = inp.sprint
	skid_t = maxf(skid_t - dt, 0.0)

	var wish := _wish_dir(inp)
	var target := SPRINT_SPEED if inp.sprint else WALK_SPEED
	if galloping:
		target = GALLOP_SPEED
	if in_water:
		target *= 0.55
	var hvel := Vector3(velocity.x, 0, velocity.z)
	if galloping and (wish.length() < 0.1 or hvel.length() < GALLOP_EXIT):
		galloping = false
		target = SPRINT_SPEED if inp.sprint else WALK_SPEED

	if roll_t > 0.0:
		hvel = hvel.move_toward(Vector3.ZERO, 2.0 * dt)
	elif wish.length() > 0.1:
		if skid_t <= 0.0 and hvel.length() > 8.0 \
				and wish.dot(hvel.normalized()) < -0.55:
			skid_t = SKID_TIME  # plant and skid before reversing at speed
			Sfx.play("roll", -16)
		if skid_t > 0.0:
			hvel = hvel.move_toward(Vector3.ZERO, SKID_DECEL * dt)
		elif hvel.length() > target + 0.5:
			# keep fling momentum: bleed gently instead of clamping
			hvel = hvel.move_toward(hvel.normalized() * target, OVERSPEED_DRAG * dt)
			hvel += wish * ACCEL * 0.2 * dt
		else:
			hvel = hvel.move_toward(wish * target, ACCEL * dt)
	else:
		hvel = hvel.move_toward(Vector3.ZERO, FRICTION * dt)

	velocity.x = hvel.x
	velocity.z = hvel.z
	velocity.y = -2.0

	if buffer_t > 0.0 and roll_t <= 0.0:
		buffer_t = 0.0
		velocity.y = _environment_jump_velocity(JUMP_VEL)
		jumps_used = 1
		state = S.AIR
		Sfx.play("jump", -8)
		return
	if inp.crouch_just and hvel.length() > SLIDE_MIN_SPEED and roll_t <= 0.0:
		if inp.sprint and hvel.length() < 14.0:
			velocity.x *= SLIDE_BOOST
			velocity.z *= SLIDE_BOOST
		state = S.SLIDE
		Sfx.play("roll", -14)
		return
	# a galloping animal stays stretched through the airborne half of each
	# bound — remember the stance briefly so small hops don't stand it up
	quad_t = 0.5 if is_all_fours() else 0.0


func _st_slide(dt: float, inp: Dictionary) -> void:
	jumps_used = 0
	coyote_t = COYOTE
	var hvel := Vector3(velocity.x, 0, velocity.z)
	hvel = hvel.move_toward(Vector3.ZERO, SLIDE_FRICTION * dt)
	# gravity pulls the slide downhill
	if is_on_floor():
		var n := get_floor_normal()
		var downhill := Vector3.DOWN - n * Vector3.DOWN.dot(n)
		hvel += Vector3(downhill.x, 0, downhill.z) * GRAVITY * 0.85 * dt
	var wish := _wish_dir(inp)
	if wish.length() > 0.1:
		hvel += wish * 3.0 * dt
	velocity.x = hvel.x
	velocity.z = hvel.z
	velocity.y = -2.0

	if buffer_t > 0.0:
		buffer_t = 0.0
		velocity.y = _environment_jump_velocity(JUMP_VEL * 0.92)
		jumps_used = 1
		state = S.AIR
		Sfx.play("jump", -8)
		return
	if not inp.crouch_held or hvel.length() < 3.2:
		state = S.GROUND


func _st_air(dt: float, inp: Dictionary) -> void:
	coyote_t = maxf(coyote_t - dt, 0.0)
	quad_t = maxf(quad_t - dt, 0.0)
	# Preserve the authored, responsive jump arc while applying physical Earth
	# gravity from the exact instant the monkey is no longer rising. Split an
	# apex-crossing tick so the descending fraction is never accelerated by the
	# stronger jump or jump-cut tuning.
	if velocity.y > 0.0:
		var ascent_acceleration := _environment_traversal_gravity() \
			+ (0.0 if inp.jump_held else JUMP_CUT \
				* _environment_gravity_ratio())
		var time_to_apex := velocity.y / ascent_acceleration
		if time_to_apex >= dt:
			velocity.y -= ascent_acceleration * dt
		else:
			velocity.y = -environment_gravity_mps2 * (dt - time_to_apex)
	else:
		velocity.y -= environment_gravity_mps2 * dt

	var wish := _wish_dir(inp)
	var hvel := Vector3(velocity.x, 0, velocity.z)
	if wish.length() > 0.1:
		var max_h := maxf(hvel.length(), WALK_SPEED)
		hvel = hvel.move_toward(wish * max_h, AIR_ACCEL * dt)
		velocity.x = hvel.x
		velocity.z = hvel.z

	wallsliding = false
	if is_on_wall_only():
		var wn := get_wall_normal()
		if wish.length() > 0.1 and wish.dot(-wn) > 0.35 and velocity.y < 0.0:
			wallsliding = true
			velocity.y = maxf(velocity.y, -WALL_SLIDE_V)
		if buffer_t > 0.0:
			buffer_t = 0.0
			var keep := Vector3(velocity.x, 0, velocity.z) * 0.35
			velocity = wn * WALL_JUMP_OUT + Vector3.UP \
				* _environment_jump_velocity(WALL_JUMP_UP) + keep
			jumps_used = 1
			Sfx.play("djump", -8)
			return

	if buffer_t > 0.0:
		if coyote_t > 0.0 and jumps_used == 0:
			buffer_t = 0.0
			velocity.y = _environment_jump_velocity(JUMP_VEL)
			jumps_used = 1
			Sfx.play("jump", -8)
		elif jumps_used <= 1:
			buffer_t = 0.0
			velocity.y = maxf(velocity.y, 0.0) * 0.3 \
				+ _environment_jump_velocity(DOUBLE_JUMP_VEL)
			jumps_used = 2
			Sfx.play("djump", -8)

	if inp.crouch_just and not dived:
		dived = true
		velocity += _flat_facing() * DIVE_FWD + Vector3.DOWN * DIVE_DOWN
		Sfx.play("whoosh", -16)

	# the tumble opens up once the flight slows or another move takes over
	if flipping and (velocity.length() < FLIP_EXIT_SPEED or wallsliding or dived):
		flipping = false


func _st_swim(dt: float, inp: Dictionary) -> void:
	galloping = false
	flipping = false
	jumps_used = 1
	coyote_t = 0.0
	var wish := _wish_dir(inp)
	var hvel := Vector3(velocity.x, 0, velocity.z)
	# Freestyle propulsion arrives in two pulses per complete arm cycle. Keep
	# enough glide between pulls for responsive controls while letting the body
	# surge subtly when either paw is in its power phase.
	var stroke_phase := rig.gait_cycle() if rig else 0.0
	var stroke_power := 0.58 + absf(sin(stroke_phase * TAU)) * 0.42
	var target := SWIM_SPEED * (1.3 if inp.sprint else 1.0) \
		* lerpf(0.90, 1.06, stroke_power)
	if wish.length() > 0.1:
		hvel = hvel.move_toward(wish * target,
			lerpf(11.0, 22.0, stroke_power) * dt)
	else:
		# Water drag coasts rather than stopping the body as abruptly as ground
		# friction, which makes stroke timing readable from the chase camera.
		hvel = hvel.move_toward(Vector3.ZERO, 6.5 * dt)
	velocity.x = hvel.x
	velocity.z = hvel.z
	# buoyancy spring keeps the whole back riding visibly on the surface
	var surface_y := float(Gen.WATER_Y)
	if world and world.has_method("water_surface_y"):
		surface_y = float(world.water_surface_y(global_position.x,
			global_position.z))
	var float_y: float = surface_y - 0.10 \
		+ sin(stroke_phase * TAU * 2.0) * 0.012
	velocity.y += ((float_y - global_position.y) * 16.0 - velocity.y * 7.0) * dt
	if buffer_t > 0.0 and global_position.y > float_y - 0.45:
		buffer_t = 0.0
		velocity.y = 7.4
		state = S.AIR
		Sfx.play("jump", -8)
		if world and world.water_fx:
			world.water_fx.exit_splash(global_position, velocity, 0.82)
		else:
			Sfx.play("water_exit", -14)
		return
	# hysteresis below the entry depth so the shoreline never flip-flops
	if _water_depth() < SWIM_DEPTH - 0.2 and is_on_floor():
		state = S.GROUND


func _water_depth() -> float:
	return Gen.WATER_Y - Gen.height(global_position.x, global_position.z)


func _enter_swim() -> void:
	state = S.SWIM
	galloping = false
	quad_t = 0.0
	dived = false
	wallsliding = false
	flipping = false
	skid_t = 0.0
	jumps_used = 1
	if world and world.water_fx:
		var impact := clampf(absf(velocity.y) / 11.0 + 0.45, 0.5, 1.45)
		world.water_fx.entry_splash(global_position, velocity, impact)
	else:
		Sfx.play("water_entry", -8)


func _st_swing(dt: float, inp: Dictionary) -> void:
	# Scroll slides the grip in discrete, useful steps; test input retains the
	# continuous reel axis so movement verification can drive it deterministically.
	var swing_weapon_scale := SNIPER_SWING_SPEED_MULTIPLIER \
		if active_weapon is SniperRifle else 1.0
	swing_len_target = clampf(swing_len_target + inp.reel * REEL_SPEED * dt
		+ inp.reel_delta, MIN_ROPE, swing_max_len)
	swing_len = move_toward(swing_len, swing_len_target, AUTO_REEL * dt)
	velocity += Vector3.DOWN * GRAVITY * dt

	wrap_t = maxf(wrap_t - dt, 0.0)
	var hand := hand_pos()
	_update_wraps(hand)
	var pivot := _active_pivot()
	var eff_len := maxf(swing_len - wrap_used, 0.6)
	var to_p := hand - pivot
	var radial := to_p.normalized() if to_p.length() > 0.01 else Vector3.DOWN
	var pump := -float(inp.dir.y)
	var steer := float(inp.dir.x)
	if velocity.length() < PUMP_CAP and absf(pump) > 0.05:
		# pump with the swing: push along the current tangent so holding W
		# always feeds energy into the arc (falls back to facing when still)
		var tang := velocity - radial * velocity.dot(radial)
		var pdir := Vector3.ZERO
		if tang.length() > 1.0:
			pdir = tang.normalized() * signf(pump)  # W feeds the arc, S brakes it
		else:
			var fwd := _flat_facing()
			var tf := fwd - radial * fwd.dot(radial)
			if tf.length() > 0.05:
				pdir = tf.normalized() * signf(pump)
		velocity += pdir * PUMP_ACCEL * swing_weapon_scale * dt
	if velocity.length() < PUMP_CAP and absf(steer) > 0.05:
		var fwd2 := _flat_facing()
		var right := -fwd2.cross(Vector3.UP)
		var t_side := right - radial * right.dot(radial)
		if t_side.length() > 0.05:
			velocity += t_side.normalized() * STEER_ACCEL * swing_weapon_scale \
				* steer * dt

	# verlet rope: only correct when taut, so slack rope = free fall.
	# Overstretch closes at ROPE_PULL m/s instead of snapping in one frame —
	# grabbing a vine from the ground reels you in smoothly, never flings.
	var pred := hand + velocity * dt
	var pd := pred - pivot
	var pl := pd.length()
	if pl > eff_len:
		var new_l := maxf(eff_len, pl - ROPE_PULL * dt)
		pred = pivot + pd / pl * new_l
		velocity = (pred - hand) / dt
	if swing_weapon_scale < 1.0:
		# The heavy rifle bleeds pendulum energy progressively. Avoid a lower hard
		# cap here: equipping it mid-arc must not erase earned momentum in one tick.
		var tangent_velocity := velocity - radial * velocity.dot(radial)
		velocity -= tangent_velocity * minf(SNIPER_SWING_DRAG * dt, 0.25)
	velocity = velocity.limit_length(SWING_MAX)

	if buffer_t > 0.0:
		buffer_t = 0.0
		_release(true)
		return
	# swinging deep into a lake lets the vine go — the monkey starts swimming
	if global_position.y < Gen.WATER_Y - 0.45 and _water_depth() > SWIM_DEPTH:
		_release(false)
		return
	if not inp.grab:
		_release(false)


func _active_pivot() -> Vector3:
	return wraps[wraps.size() - 1] if wraps.size() > 0 else swing_anchor


## Bend the rope around world geometry: when the segment pivot→hand is blocked,
## push a wrap pivot at the obstruction; when the previous segment clears again,
## unwind it. Hysteresis timer prevents wrap/unwrap flapping.
func _update_wraps(hand: Vector3) -> void:
	if wrap_t > 0.0:
		return
	var space := get_world_3d().direct_space_state
	var pivot := _active_pivot()
	var q := PhysicsRayQueryParameters3D.create(pivot, hand)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if not hit.is_empty() and hit.collider is CharacterBody3D:
		hit = {}
	if not hit.is_empty() and wraps.size() < MAX_WRAPS \
			and hit.position.distance_to(pivot) > WRAP_MIN \
			and hit.position.distance_to(hand) > WRAP_MIN:
		var wp: Vector3 = hit.position + hit.normal * 0.1
		wrap_used += wp.distance_to(pivot)
		wraps.append(wp)
		wrap_t = 0.06
		return
	if wraps.size() > 0:
		var prev: Vector3 = wraps[wraps.size() - 2] if wraps.size() >= 2 else swing_anchor
		var q2 := PhysicsRayQueryParameters3D.create(prev, hand)
		q2.exclude = [get_rid()]
		if space.intersect_ray(q2).is_empty():
			wrap_used = maxf(wrap_used - (wraps[wraps.size() - 1] as Vector3).distance_to(prev), 0.0)
			wraps.pop_back()
			wrap_t = 0.06


func _post(dt: float, inp: Dictionary, pre_floor: bool, pre_vy: float) -> void:
	# landing
	if state == S.AIR and is_on_floor():
		var impact := maxf(-pre_vy, 0.0)
		var h := Vector3(velocity.x, 0, velocity.z).length()
		if h >= GALLOP_ENTER:
			galloping = true  # hot landing off a vine → all-fours gallop
		if impact > 13.0 and h > 6.0:
			roll_t = 0.28
			Sfx.play("roll", -10)
		elif impact > 13.0:
			velocity.x *= 0.45
			velocity.z *= 0.45
			Sfx.play("thud", -6)
		elif impact > 4.0:
			Sfx.play("land", -14)
		landed.emit(impact)
		state = S.SLIDE if (dived and h > 7.0 and inp.crouch_held) else S.GROUND
		dived = false
		flipping = false
	elif state in [S.GROUND, S.SLIDE] and not is_on_floor():
		state = S.AIR
		coyote_t = COYOTE
		# Ground adhesion uses -2 m/s while supported. Do not carry that artificial
		# floor-stick impulse over a ledge; unsupported motion begins from the real
		# current vertical speed and then gains exactly 9.81 m/s each second.
		if velocity.y < 0.0:
			velocity.y = 0.0
	elif state == S.SWING and is_on_floor():
		_release(false)

	# water contact
	var was_water := in_water
	in_water = global_position.y < Gen.WATER_Y + 0.25 and is_on_floor()
	if in_water and not was_water and absf(pre_vy) > 3.0 \
			and _water_depth() <= SWIM_DEPTH:
		if world and world.water_fx:
			world.water_fx.entry_splash(global_position,
				Vector3(velocity.x, pre_vy, velocity.z),
				clampf(absf(pre_vy) / 11.0, 0.4, 1.25))
		else:
			Sfx.play("water_entry", -10)
	# deep water floats the monkey: swim instead of running on the lakebed.
	# The upward-velocity guard lets the surface hop actually clear the water.
	if state != S.SWING and state != S.SWIM and velocity.y <= 1.0 \
			and global_position.y <= Gen.WATER_Y - 0.2 and _water_depth() > SWIM_DEPTH:
		_enter_swim()

	# vine targeting (look at a vine) + grabbing
	if state != S.SWING:
		var ar := _aim()
		last_target = Gen.best_vine(ar[0], ar[1], hand_pos(), vine_cd, _now)
		if inp.grab and regrab_t <= 0.0 and not last_target.is_empty():
			var a: Vector3 = last_target.anchor
			if a.y > global_position.y + 0.5:
				_attach(last_target)
	else:
		last_target = {}

	# ook!
	if not test_mode and Input.is_action_just_pressed("ook"):
		Sfx.play("ook", -6)
		Net.send_ook(global_position)

	# fell out of the world (should never happen, but never strand the monkey)
	var void_rescue_y: float = world.void_rescue_height(self) \
		if world and world.has_method("void_rescue_height") else -25.0
	if global_position.y < void_rescue_y \
			and world and world.has_method("respawn"):
		world.respawn(self)

	# replicate
	_send_t += dt
	if Net.active and _send_t >= 0.05:
		_send_t = 0.0
		Net.send_state(global_position, rig.yaw_angle(), velocity, _anim(),
			state == S.SWING, swing_anchor, rope_tail(),
			PackedVector3Array(wraps), weapon_slot - 1,
			is_weapon_stowed(), melee_mode,
			int(active_weapon.ammo) if active_weapon else 0,
			active_weapon != null and active_weapon.reload_remaining > 0.0,
			bandage_progress(), fly_mode)

	# wind volume follows speed
	if wind:
		var sp := velocity.length()
		wind.volume_db = lerpf(-60.0, -10.0, clampf(sp / 38.0, 0.0, 1.0))
		# Presentation saturates without feeding a hidden limit back into physics.
		wind.pitch_scale = clampf(0.85 + sp / 70.0, 0.85, 2.4)


func _attach(t: Dictionary) -> void:
	state = S.SWING
	swing_anchor = t.anchor
	swing_vine_id = t.id
	if world:
		world.claim_vine(swing_vine_id)
	# the rope radius is where you grabbed the vine; the vine itself never
	# shortens — anything below the grip trails as a visible tail.
	# The rope STARTS at the current hand distance (never shorter), then the
	# hands slide to the grabbed point — so attaching can never snap-fling.
	swing_vine_len = float(t.len)
	swing_max_len = swing_vine_len
	swing_len_target = clampf(float(t.get("depth", hand_pos().distance_to(t.anchor))), MIN_ROPE, swing_vine_len)
	swing_len = maxf(swing_len_target, hand_pos().distance_to(swing_anchor))
	wraps.clear()
	wrap_used = 0.0
	wrap_t = 0.0
	dived = false
	wallsliding = false
	flipping = false
	galloping = false
	quad_t = 0.0
	jumps_used = 1
	# carry momentum through the chain: redirect full speed onto the new
	# swing tangent instead of letting the rope eat the radial component
	var radial := (hand_pos() - swing_anchor).normalized()
	var tang := velocity - radial * velocity.dot(radial)
	if velocity.length() > 6.0 and tang.length() > 2.0:
		velocity = tang.normalized() * velocity.length()
	Net.vine_state(swing_vine_id, true)
	Sfx.play("grab", -6)


func _release(pop: bool) -> void:
	var taut := hand_pos().distance_to(_active_pivot()) > (swing_len - wrap_used) * 0.9
	var released_id := swing_vine_id
	var release_hand := hand_pos()
	var vine_velocity := velocity
	var released_shape := rig.rope_snapshot()
	wraps.clear()
	wrap_used = 0.0
	state = S.AIR
	coyote_t = 0.0
	jumps_used = 1
	regrab_t = 0.22
	vine_cd[swing_vine_id] = _now + 0.6
	if taut and velocity.length() > 8.0:
		velocity *= RELEASE_BOOST
	if pop:
		velocity.y += RELEASE_POP
	# fast releases tumble: frontflip along the travel direction, backflip when
	# flying backward relative to where the monkey is looking
	var flip_h := Vector3(velocity.x, 0, velocity.z)
	if velocity.length() >= FLIP_MIN_SPEED and flip_h.length() > 4.0:
		flipping = true
		flip_dir = 1 if flip_h.normalized().dot(_flat_facing()) >= -0.25 else -1
	Net.vine_release(released_id, release_hand, vine_velocity, swing_vine_len, released_shape)
	Sfx.play("whoosh", -10)
	swing_vine_id = ""


func _anim() -> int:
	if expedition_locked:
		return MonkeyRig.Anim.CABIN
	if vehicle:
		return MonkeyRig.Anim.PILOT if vehicle.kind == Vehicle.Kind.JET \
			else MonkeyRig.Anim.RIDE
	match state:
		S.SWING:
			return MonkeyRig.Anim.SWING
		S.SLIDE:
			return MonkeyRig.Anim.SLIDE
		S.SWIM:
			return MonkeyRig.Anim.SWIM
		S.AIR:
			if dived:
				return MonkeyRig.Anim.DIVE
			if wallsliding:
				return MonkeyRig.Anim.WALLSLIDE
			if flipping:
				return MonkeyRig.Anim.FLIP_F if flip_dir > 0 else MonkeyRig.Anim.FLIP_B
			if is_all_fours():
				return MonkeyRig.Anim.SPRINT  # stretched airborne gallop bound
			return MonkeyRig.Anim.AIR
		_:
			if roll_t > 0.0:
				return MonkeyRig.Anim.ROLL
			if skid_t > 0.0:
				return MonkeyRig.Anim.SKID
			var h := Vector3(velocity.x, 0, velocity.z).length()
			if h < 0.5:
				return MonkeyRig.Anim.IDLE
			if is_all_fours() and h > 6.0:
				return MonkeyRig.Anim.SPRINT  # quadruped gallop
			return MonkeyRig.Anim.RUN  # bipedal at walking pace
	return MonkeyRig.Anim.IDLE


func rope_tail() -> float:
	return maxf(swing_vine_len - swing_len, 0.0) if state == S.SWING else 0.0


static func _cycle_crossed(previous: float, current: float,
		threshold: float) -> bool:
	if previous < 0.0:
		return false
	return (threshold > previous and threshold <= current) \
		if current >= previous else (threshold > previous or threshold <= current)


func _update_motion_effects(anim: int) -> void:
	if not world or not world.water_fx:
		return
	var cycle := rig.gait_cycle()
	var swimming := anim == MonkeyRig.Anim.SWIM
	var horizontal_speed := Vector3(velocity.x, 0, velocity.z).length()
	world.water_fx.update_swimmer(get_instance_id(), global_position, velocity,
		swimming, clampf(horizontal_speed / SWIM_SPEED, 0.25, 1.25))
	if is_local:
		world.water_fx.set_listener_swimming(swimming, horizontal_speed)
	if swimming:
		var contacts := rig.limb_contact_points()
		if contacts.size() == 4:
			var stroke_intensity := clampf(horizontal_speed / SWIM_SPEED,
				0.38, 1.15)
			if _cycle_crossed(_last_swim_fx_cycle, cycle, 0.0):
				world.water_fx.stroke(contacts[0], velocity, -1, stroke_intensity)
			if _cycle_crossed(_last_swim_fx_cycle, cycle, 0.5):
				world.water_fx.stroke(contacts[1], velocity, 1, stroke_intensity)
			var kick_bucket := floori(cycle * 6.0) % 6
			if _last_swim_kick_bucket >= 0 and kick_bucket != _last_swim_kick_bucket \
					and world.water_fx.has_method("kick"):
				var foot_index := 2 + (kick_bucket & 1)
				world.water_fx.kick(contacts[foot_index], velocity,
					stroke_intensity * 0.48)
			_last_swim_kick_bucket = kick_bucket
		_last_swim_fx_cycle = cycle
	else:
		_last_swim_fx_cycle = -1.0
		_last_swim_kick_bucket = -1

	# Two restrained contact groups per stride keep the asymmetrical gorilla
	# gallop audible without turning its four rapid contacts into a machine gun.
	if anim == MonkeyRig.Anim.SPRINT and is_on_floor():
		if _cycle_crossed(_last_gallop_audio_cycle, cycle, 0.0) \
				or _cycle_crossed(_last_gallop_audio_cycle, cycle, 0.39):
			Sfx.play_at("gallop_step", global_position, -19.0,
				randf_range(0.92, 1.06), 24.0)
		_last_gallop_audio_cycle = cycle
	else:
		_last_gallop_audio_cycle = -1.0


func _process(dt: float) -> void:
	if not is_local and not is_ai:
		return
	if defeated:
		return
	var hvel := Vector3(velocity.x, 0, velocity.z)
	var weapon_aim := shot_aim()
	var recoil: float = active_weapon.recoil if active_weapon else 0.0
	_sync_weapon_presentation()
	var weapon_stowed := is_weapon_visually_stowed()
	# A camera-parented viewmodel is magnified by the same FOV as the world. Hide
	# it behind the optical vignette so 5x/10x never turn the stock into the view.
	if sniper and active_weapon == sniper and cam:
		sniper.visible = not cam.is_sniper_scoped() and not defeated \
			and not weapon_stowed
	var sniper_rope_active := state == S.SWING \
		and active_weapon is SniperRifle and not weapon_stowed
	rig.set_sniper_rope_pose(sniper_rope_active,
		sniper.support_grip if sniper_rope_active else null)
	# Equipped weapons stay raised throughout a swing. The rig then reserves
	# the left arm for the vine and uses the right arm for the weapon.
	rig.set_gun_aim(active_weapon != null and not weapon_stowed,
		weapon_aim[1], recoil)
	var reload_hand_active: bool = active_weapon != null \
		and active_weapon.reload_remaining > 0.0 \
		and active_weapon.has_method("has_dynamic_reload_hand") \
		and active_weapon.has_dynamic_reload_hand() \
		and active_weapon.get("_reload_hand_grip") is Node3D
	rig.set_reload_pose(reload_hand_active,
		active_weapon.get("_reload_hand_grip") if reload_hand_active else null)
	var show_melee_pose := melee_mode and state != S.SWING \
		and vehicle == null
	rig.set_melee_pose(show_melee_pose, melee_attack_remaining > 0.0,
		melee_attack_progress(), melee_attack_combo)
	rig.set_healing_pose(is_healing(), bandage_progress())
	if vehicle and is_instance_valid(vehicle):
		# Seated: the whole monkey adopts the machine's attitude — the rig
		# root takes the vehicle basis (flipped to the rig's -Z facing) and
		# the pose branch handles lean/counter-lean. The rig's own yaw node
		# must sit at zero or a stale pre-mount heading skews the rider.
		# This root is authored every render frame from an already-interpolated
		# transform. Detach it from the raw physics parent and disable a second
		# interpolation pass while seated.
		rig.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		rig.top_level = true
		rig.set_yaw(0.0)
		rig.set_vehicle_pose(vehicle.rider_render_pose())
		# Each machine owns an authored rig root at its real cushion/saddle. Use
		# the render-interpolated chassis transform and contact adapter so the
		# monkey stays welded to it between physics ticks as well as through lean,
		# pitch, and inverted flight.
		rig.global_transform = vehicle.rider_render_transform()
		rig.set_ride_lean(vehicle.state_aux().y)
		rig.set_rope(false, Vector3.ZERO, Vector3.ZERO)
		rig.update_motion(dt, _anim(), velocity, true, _active_pivot())
		_update_motion_effects(_anim())
		return
	if rig.top_level \
			or rig.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF:
		# Covers an externally freed/despawned vehicle that bypassed the ordinary
		# exit path. World-space pilot IK may have moved every joint origin, so a
		# root-only detach would recreate the scattered-body session bug.
		rig.reset_pose_state(false)
	rig.set_vehicle_pose(null)
	if rig.rotation != Vector3.ZERO:
		rig.rotation = rig.rotation.lerp(Vector3.ZERO, 1.0 - exp(-10.0 * dt))
	if rig.position != Vector3.ZERO:
		rig.position = rig.position.lerp(Vector3.ZERO, 1.0 - exp(-12.0 * dt))
	if state == S.SWING:
		# A two-handed long rifle needs the chest and both shoulders behind the
		# sightline. Track the aim while tail/feet carry the rope; other swing poses
		# still weathercock naturally into their pendulum velocity.
		var swing_facing := hvel if hvel.length() > 2.0 else _flat_facing()
		if sniper_rope_active:
			var aim_facing: Vector3 = weapon_aim[1]
			aim_facing.y = 0.0
			if aim_facing.length_squared() > 0.001:
				swing_facing = aim_facing.normalized()
		rig.face(swing_facing, dt)
		rig.set_rope(true, swing_anchor, hand_pos(), rope_tail(), velocity,
			PackedVector3Array(wraps), dt)
	else:
		# In third person the entire monkey follows the crosshair, not just the
		# IK weapon arm. This gives stable forward/strafe poses and removes the
		# old half-turn where the torso lagged behind until movement reversed.
		var flat_aim := Vector3(weapon_aim[1].x, 0, weapon_aim[1].z)
		if (not weapon_stowed or melee_mode) and active_weapon \
				and flat_aim.length_squared() > 0.001:
			rig.face(flat_aim.normalized(), dt)
		elif hvel.length() > 1.0:
			rig.face(hvel, dt)
		rig.set_rope(false, Vector3.ZERO, Vector3.ZERO)
	var anim := _anim()
	rig.update_motion(dt, anim, velocity, is_on_floor(), _active_pivot())
	_update_motion_effects(anim)


# ---- admin fly mode and remote-applied admin actions -----------------------


## ---- vehicles -------------------------------------------------------------

func enter_vehicle(v: Vehicle) -> void:
	if vehicle != null or defeated or v == null or not v.can_enter(self):
		return
	if state == S.SWING:
		_release(false)
	if fly_mode:
		set_fly_mode(false)
	vehicle = v
	v.begin_drive(self)
	if not v.driver_impact.is_connected(_on_vehicle_impact):
		v.driver_impact.connect(_on_vehicle_impact)
	if not v.driver_fatal_crash.is_connected(_on_vehicle_fatal_crash):
		v.driver_fatal_crash.connect(_on_vehicle_fatal_crash)
	state = S.GROUND
	galloping = false
	dived = false
	wallsliding = false
	flipping = false
	skid_t = 0.0
	velocity = v.linear_velocity
	_collision_shape.disabled = true
	collision_layer = 0
	collision_mask = 0
	_vehicle_exit_cd = 0.4
	if cam:
		cam.begin_vehicle_view(v)
	Sfx.play_at("gear_clunk", global_position, -10.0, 1.25)
	supply_notice = "%s  ·  E TO DISMOUNT" % v.display_name()
	supply_notice_remaining = 2.4


func exit_vehicle(bail := false) -> void:
	if vehicle == null:
		return
	var v := vehicle
	vehicle = null
	if v.driver_impact.is_connected(_on_vehicle_impact):
		v.driver_impact.disconnect(_on_vehicle_impact)
	if v.driver_fatal_crash.is_connected(_on_vehicle_fatal_crash):
		v.driver_fatal_crash.disconnect(_on_vehicle_fatal_crash)
	var exit_pos := v.end_drive()
	if Net.active:
		var aux := v.state_aux()
		Net.release_vehicle(v.vid,
			[v.global_position, v.yaw_angle(), aux.x, aux.y])
	global_position = exit_pos
	velocity = v.linear_velocity * (0.85 if bail else 0.25)
	if bail:
		velocity.y = maxf(velocity.y, 2.5)
	_collision_shape.disabled = false
	collision_layer = 1
	collision_mask = 1
	state = S.AIR
	if rig:
		rig.reset_pose_state(false)
	if cam:
		cam.end_vehicle_view()
	_vehicle_exit_cd = 0.4
	reset_physics_interpolation()


func _st_vehicle(dt: float, inp: Dictionary) -> void:
	state = S.GROUND
	_vehicle_exit_cd = maxf(_vehicle_exit_cd - dt, 0.0)
	if not is_instance_valid(vehicle) or vehicle.driver != self:
		vehicle = null
		_collision_shape.disabled = false
		collision_layer = 1
		collision_mask = 1
		if rig:
			rig.reset_pose_state(false)
		if cam:
			cam.end_vehicle_view()
		return
	var throttle := maxf(-inp.dir.y, 0.0)
	var brake := maxf(inp.dir.y, 0.0)
	vehicle.set_inputs(throttle, brake, -inp.dir.x, inp.jump_held, inp.sprint)
	# Arrow pitch is an assisted attitude mode, not vertical mouse pursuit. Keep
	# that channel on the current nose so releasing an arrow cannot hand control
	# back to a stale pitch-down target, while preserving horizontal mouse aim.
	if cam and vehicle.kind == Vehicle.Kind.JET \
			and absf(float(inp.get("vehicle_pitch", 0.0))) > 0.04:
		cam.center_aircraft_pitch_aim()
	vehicle.set_driver_view(cam.vehicle_aim_direction() if cam else global_basis.z,
		inp)
	global_position = vehicle.seat_global()
	velocity = vehicle.linear_velocity
	if inp.interact_just and _vehicle_exit_cd <= 0.0 and vehicle.allows_exit():
		exit_vehicle(vehicle.speed() > 6.0)
		return
	# replicate at the normal cadence; the vehicle piggybacks on player state
	_send_t += dt
	if Net.active and _send_t >= 0.05:
		_send_t = 0.0
		Net.send_state(global_position, vehicle.yaw_angle(), velocity, _anim(),
			false, Vector3.ZERO, 0.0, PackedVector3Array(), weapon_slot - 1,
			true, false,
			int(active_weapon.ammo) if active_weapon else 0, false,
			0.0, false, vehicle.kind, vehicle.vid, vehicle.state_aux())


## Hard decelerations while driving hurt: light hits bruise, a violent crash
## throws the rider off, and hitting the jungle at jet speed is lethal.
func _on_vehicle_impact(delta_speed: float) -> void:
	if vehicle == null or _invulnerable_t > 0.0:
		return
	var damage := (delta_speed - Vehicle.IMPACT_DAMAGE_THRESHOLD) * 5.5
	if damage <= 0.0:
		return
	var eject := vehicle.ejects_rider_on_crash() \
		and delta_speed > Vehicle.IMPACT_DAMAGE_THRESHOLD + 5.0
	var impulse := -velocity.normalized() * 2.0 + Vector3.UP * 2.0
	if eject:
		exit_vehicle(true)
	take_damage(damage, null, impulse, "body")


## A true backwards motorcycle loop is a player-authored fatal crash, not an
## enemy/spawn-camping hit. Route it separately so revive protection cannot
## swallow the bike's one physical crash event and leave an inverted rider alive.
func _on_vehicle_fatal_crash() -> void:
	if vehicle == null:
		return
	var crash_velocity := velocity
	exit_vehicle(true)
	_invulnerable_t = 0.0
	var impulse := -crash_velocity.normalized() * 2.0 + Vector3.UP * 3.0
	take_damage(maxf(health + 1.0, MAX_HEALTH + 1.0), null, impulse, "body")


func set_fly_mode(active: bool) -> void:
	if fly_mode == active:
		return
	if active and state == S.SWING:
		_release(false)
	fly_mode = active
	if active:
		state = S.AIR
		velocity.y = maxf(velocity.y, 3.0)
		Sfx.play("djump", -6.0, 0.8)
	if rig:
		rig.set_angel_wings(active)


func _st_fly(dt: float, inp: Dictionary) -> void:
	state = S.AIR
	jumps_used = 1
	var wish := _wish_dir(inp)
	var target := wish * (FLY_SPRINT_SPEED if inp.sprint else FLY_SPEED)
	var vertical := 0.0
	if inp.jump_held:
		vertical += FLY_VERTICAL_SPEED
	if inp.crouch_held:
		vertical -= FLY_VERTICAL_SPEED
	target.y = vertical
	velocity = velocity.move_toward(target, FLY_ACCEL * dt)


func admin_kill() -> void:
	_invulnerable_t = 0.0
	take_damage(MAX_HEALTH * 4.0, null, Vector3.UP * 3.0, "body")


func admin_heal() -> void:
	health = MAX_HEALTH
	health_changed.emit(health, MAX_HEALTH)


func admin_teleport(destination: Vector3) -> void:
	if vehicle:
		exit_vehicle()
	if state == S.SWING:
		_release(false)
	global_position = destination
	velocity = Vector3.ZERO
	reset_physics_interpolation()
