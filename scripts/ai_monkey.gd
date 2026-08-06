class_name AiMonkey
extends MonkeyPlayer
## Solo rival that shares the player's movement, weapon and procedural-rig
## systems. Combat is intentionally readable: the rival moves in short bursts,
## plants before accurate shots, reloads the actual equipped weapon, and uses a
## vine as an occasional reposition instead of its default locomotion loop.

enum Tactic { HOLD, STRAFE, ADVANCE, RETREAT, FLANK, COVER, VINE_REPOSITION }

# Public tuning/state is deliberately deterministic and inspectable so combat
# regressions can validate fairness without relying on a lucky ten-second duel.
const WEAPON_BANANA := 1
const WEAPON_SHOTGUN := 2
const WEAPON_SMG := 3
const WEAPON_SNIPER := 4
const WEAPON_NAMES := ["", "Banana Gun", "Shotgun", "SMG", "Sniper Rifle"]
const WEAPON_IDEAL_RANGES := [
	Vector2.ZERO,
	Vector2(12.0, 45.0),
	Vector2(3.0, 17.0),
	Vector2(8.0, 32.0),
	Vector2(20.0, 88.0),
]
const WEAPON_SWITCH_MIN := 4.8
const WEAPON_SWITCH_MAX := 7.2
const INITIAL_WEAPON_HOLD := 3.8
const GROUND_PHASE_MIN := 5.5
const GROUND_PHASE_MAX := 8.5
const MOVE_WINDOW_MIN := 0.58
const MOVE_WINDOW_MAX := 1.05
const PLANT_WINDOW_MIN := 0.62
const PLANT_WINDOW_MAX := 1.12
const PLANTED_FIRE_SPEED := 1.65
const MOVING_FIRE_SPEED := 2.25
const MAX_COMBAT_RANGE := 92.0
const OBSERVATION_MIN := 0.18
const OBSERVATION_MAX := 0.30
const BURST_STRAFE_MIN := 0.55
const BURST_STRAFE_MAX := 0.88
const BURST_SETTLE_MIN := 0.22
const BURST_SETTLE_MAX := 0.38
const BURST_COMMIT_TIMEOUT := 1.25
const EMERGENCY_SWITCH_LOCK := 1.15
const RELOAD_COVER_MAX_DISTANCE := 16.0
const RELOAD_COVER_STOP_DISTANCE := 1.05
const FIRST_VINE_DELAY := 3.0
const VINE_COOLDOWN_MIN := 11.5
const VINE_COOLDOWN_MAX := 16.5
const VINE_ATTACH_TIMEOUT := 2.8
const VINE_RELEASE_MIN := 0.82
const VINE_RELEASE_MAX := 1.42
const SWINGS_PER_CHAIN := 1

# Half-angle in degrees before movement, target speed, turn and range penalties.
# Shotgun pellets add their own three-degree mechanical cone after this error.
const PLANTED_SPREAD_DEGREES := [0.0, 1.32, 2.00, 1.88, 0.88]
const MOVING_SPREAD_DEGREES := [0.0, 4.8, 5.8, 5.2, 6.4]
const SWING_SPREAD_DEGREES := [0.0, 9.2, 10.5, 9.8, 12.0]
const GROUND_AIM_SPREAD := 0.025
const SWING_AIM_SPREAD := 0.16

var target: MonkeyPlayer

# Inspectable live combat state.
var tactical_state: int = Tactic.HOLD
var tactical_state_name := "hold"
var weapon_switch_count := 0
var reloads_started := 0
var ground_shots := 0
var moving_shots := 0
var swing_shots := 0
var vine_repositions := 0
var ground_repositions := 0
var bursts_started := 0
var bursts_completed := 0
var post_burst_strafes := 0
var last_burst_size := 0
var reload_cover_runs := 0
var reload_hides_reached := 0
var reload_run_frames := 0
var last_spread_degrees := 0.0
var last_turn_rate_degrees := 0.0
var last_aim_height := 0.54
var last_shot_weapon_slot := WEAPON_BANANA
var shots_by_slot := {WEAPON_BANANA: 0, WEAPON_SHOTGUN: 0,
	WEAPON_SMG: 0, WEAPON_SNIPER: 0}
var weapon_use_counts := {WEAPON_BANANA: 1, WEAPON_SHOTGUN: 0,
	WEAPON_SMG: 0, WEAPON_SNIPER: 0}

var _rng := RandomNumberGenerator.new()
var _combat_age := 0.0
var _think_t := 0.0
var _shot_t := 1.15
var _jump_t := 0.55
var _weapon_t := INITIAL_WEAPON_HOLD
var _tactic_t := 0.0
var _movement_window_t := 0.0
var _plant_window_t := 0.7
var _ground_phase_t := GROUND_PHASE_MIN
var _vine_cooldown := FIRST_VINE_DELAY
var _vine_commit_t := 0.0
var _swing_t := 0.0
var _swing_release_t := 1.1
var _under_fire_t := 0.0
var _los_blocked_t := 0.0
var _stuck_sample_t := 0.0
var _stuck_t := 0.0
var _chosen_vine := ""
var _vine_aim_point := Vector3.ZERO
var _cover_point := Vector3.ZERO
var _has_cover_point := false
var _flank_point := Vector3.ZERO
var _strafe_sign := 1.0
var _seek_ground := false
var _desired_ground_direction := Vector3.ZERO
var _last_stuck_position := Vector3.ZERO
var _last_health := MAX_HEALTH
var _observed_target_position := Vector3.ZERO
var _observed_target_velocity := Vector3.ZERO
var _observation_t := 0.0
var _observation_age := 0.0
var _aim_error := Vector2.ZERO
var _last_solution_direction := Vector3.FORWARD
var _aim_solution_age := 0.25
var _queued_shot_context := Tactic.HOLD
var _burst_weapon_slot := 0
var _burst_rounds_remaining := 0
var _burst_rounds_queued := 0
var _burst_commit_t := 0.0
var _post_burst_strafe_t := 0.0
var _burst_settle_t := 0.0
var _emergency_switch_lock_t := 0.0
var _reload_cover_run_active := false
var _reload_hidden_recorded := false


func _ready() -> void:
	super._ready()
	test_mode = true
	_rng.seed = 90421 + Gen.world_seed
	_strafe_sign = -1.0 if _rng.randf() < 0.5 else 1.0
	_ground_phase_t = _rng.randf_range(GROUND_PHASE_MIN, GROUND_PHASE_MAX)
	_last_stuck_position = global_position
	_last_health = health
	if target and is_instance_valid(target):
		_observed_target_position = target.global_position
		_observed_target_velocity = target.velocity
	_observation_t = _rng.randf_range(OBSERVATION_MIN, OBSERVATION_MAX)
	_update_nameplate()


func _physics_process(dt: float) -> void:
	if not target or not is_instance_valid(target):
		return
	if not defeated:
		_think(dt)
	super._physics_process(dt)


func _think(dt: float) -> void:
	_combat_age += dt
	_think_t -= dt
	_shot_t -= dt
	_jump_t -= dt
	_weapon_t -= dt
	_tactic_t -= dt
	_ground_phase_t -= dt
	_vine_cooldown -= dt
	_vine_commit_t -= dt
	_under_fire_t = maxf(_under_fire_t - dt, 0.0)
	_emergency_switch_lock_t = maxf(_emergency_switch_lock_t - dt, 0.0)
	_aim_solution_age += dt
	_update_burst_timers(dt)
	_reset_frame_input()
	_update_awareness(dt)
	_update_reload_cover_progress()

	if target.defeated:
		_set_tactic(Tactic.HOLD, 0.6)
		ti.dir = Vector2.ZERO
		return

	if state == S.SWING:
		_update_swing(dt)
	else:
		_swing_t = 0.0
		if _seek_ground and is_on_floor():
			_finish_vine_reposition()
		if is_on_floor() and not _seek_ground:
			_update_ground_plan(dt)
		_update_ground_navigation()

	_update_weapon_choice()
	_update_combat(dt)


func _reset_frame_input() -> void:
	ti.jump_just = false
	ti.jump_held = false
	ti.crouch_just = false
	ti.crouch_held = false
	ti.grab = false
	ti.reel = 0.0
	ti.sprint = false
	ti.shoot_just = false
	ti.shoot_held = false
	ti.reload_just = false


func _update_awareness(dt: float) -> void:
	if _has_cover_point and global_position.distance_to(_cover_point) > 26.0:
		_has_cover_point = false
	if health < _last_health - 0.01:
		_under_fire_t = 3.6
		_strafe_sign *= -1.0
		_choose_cover_point()
	_last_health = health

	_observation_t -= dt
	_observation_age += dt
	if _observation_t <= 0.0:
		var previous := _observed_target_position
		_observed_target_position = target.global_position
		# Divide by the real interval between observations. The old approximation
		# made ordinary movement look like a sprint and caused exaggerated lead.
		var sample_dt := maxf(_observation_age, 0.001)
		var measured := (_observed_target_position - previous) / sample_dt
		_observed_target_velocity = _observed_target_velocity.lerp(
			measured.limit_length(SPRINT_SPEED * 1.35), 0.48)
		_observation_t = _rng.randf_range(OBSERVATION_MIN, OBSERVATION_MAX)
		_observation_age = 0.0

	var visible := _has_line_of_sight()
	_los_blocked_t = 0.0 if visible else _los_blocked_t + dt
	_stuck_sample_t += dt
	if _stuck_sample_t >= 0.75:
		var moved := global_position.distance_to(_last_stuck_position)
		if _desired_ground_direction.length_squared() > 0.1 and moved < 0.32:
			_stuck_t += _stuck_sample_t
		else:
			_stuck_t = maxf(_stuck_t - _stuck_sample_t * 1.5, 0.0)
		_last_stuck_position = global_position
		_stuck_sample_t = 0.0


func _update_burst_timers(dt: float) -> void:
	if _burst_rounds_remaining > 0:
		_burst_commit_t = maxf(_burst_commit_t - dt, 0.0)
		if _burst_commit_t <= 0.0:
			if _burst_rounds_queued > 0:
				_complete_weapon_burst()
			else:
				_clear_weapon_burst()
			# A newly scheduled recovery phase starts on the next physics tick; a
			# hitch that expires the commit must not also erase the whole strafe.
			return
	var grounded_movement := is_on_floor() and state in [S.GROUND, S.SLIDE]
	if _post_burst_strafe_t > 0.0 and grounded_movement:
		_post_burst_strafe_t = maxf(_post_burst_strafe_t - dt, 0.0)
		if _post_burst_strafe_t <= 0.0:
			_burst_settle_t = _rng.randf_range(BURST_SETTLE_MIN,
				BURST_SETTLE_MAX)
			_plant_window_t = maxf(_plant_window_t, _burst_settle_t)
	elif _burst_settle_t > 0.0 and grounded_movement:
		_burst_settle_t = maxf(_burst_settle_t - dt, 0.0)


func _update_reload_cover_progress() -> void:
	if not _is_reloading():
		_reload_cover_run_active = false
		_reload_hidden_recorded = false
		return
	if _reload_cover_run_active and not _reload_hidden_recorded \
			and not _has_line_of_sight():
		_reload_hidden_recorded = true
		reload_hides_reached += 1


func _update_ground_plan(dt: float) -> void:
	# Burst movement owns this short phase so the ordinary random windows cannot
	# immediately cancel the readable shoot -> strafe -> settle cadence.
	if _burst_rounds_remaining > 0 or _post_burst_strafe_t > 0.0 \
			or _burst_settle_t > 0.0:
		return
	if _movement_window_t > 0.0:
		_movement_window_t -= dt
		if _movement_window_t <= 0.0:
			_plant_window_t = _rng.randf_range(PLANT_WINDOW_MIN, PLANT_WINDOW_MAX)
	elif _plant_window_t > 0.0:
		_plant_window_t -= dt
		if _plant_window_t <= 0.0:
			_movement_window_t = _rng.randf_range(MOVE_WINDOW_MIN, MOVE_WINDOW_MAX)

	if _should_use_vine():
		_choose_vine()
		if _chosen_vine != "":
			_set_tactic(Tactic.VINE_REPOSITION, VINE_ATTACH_TIMEOUT)
			_vine_commit_t = VINE_ATTACH_TIMEOUT
			return

	if tactical_state == Tactic.VINE_REPOSITION:
		if _vine_commit_t <= 0.0:
			_chosen_vine = ""
			_vine_cooldown = 4.0
			_choose_ground_tactic()
		return
	if _tactic_t <= 0.0:
		_choose_ground_tactic()


func _choose_ground_tactic() -> void:
	var enemy_flat := _flat_to_target()
	var distance := enemy_flat.length()
	var ideal := weapon_range(weapon_slot)
	if _under_fire_t > 0.0 and (_has_cover_point or _choose_cover_point()):
		_set_tactic(Tactic.COVER, _rng.randf_range(1.5, 2.4))
	elif _los_blocked_t > 0.7:
		_choose_flank_point()
		_set_tactic(Tactic.FLANK, _rng.randf_range(1.6, 2.7))
	elif distance < ideal.x:
		_set_tactic(Tactic.RETREAT, _rng.randf_range(1.2, 2.0))
	elif distance > ideal.y:
		_set_tactic(Tactic.ADVANCE, _rng.randf_range(1.4, 2.4))
	elif _rng.randf() < 0.24:
		_set_tactic(Tactic.HOLD, _rng.randf_range(0.75, 1.35))
	else:
		if _rng.randf() < 0.38:
			_strafe_sign *= -1.0
		_set_tactic(Tactic.STRAFE, _rng.randf_range(1.6, 3.0))


func _set_tactic(next_tactic: int, duration: float) -> void:
	if tactical_state != next_tactic and next_tactic not in [Tactic.HOLD,
			Tactic.VINE_REPOSITION]:
		ground_repositions += 1
	tactical_state = next_tactic
	tactical_state_name = tactic_label(next_tactic)
	_tactic_t = maxf(duration, 0.05)


func _update_ground_navigation() -> void:
	var enemy_flat := _flat_to_target()
	var forward := enemy_flat.normalized() if enemy_flat.length() > 0.05 \
		else Vector3.FORWARD
	var side := forward.cross(Vector3.UP) * _strafe_sign
	var desired := Vector3.ZERO

	if _seek_ground:
		desired = -forward * 0.25 + side
	elif tactical_state == Tactic.VINE_REPOSITION and _chosen_vine != "":
		var to_vine := _vine_aim_point - global_position
		desired = Vector3(to_vine.x, 0.0, to_vine.z)
	elif _is_reloading():
		# Keep this a fast bipedal run, not an all-fours sprint: the weapon and
		# support-paw reload choreography remain visible while the rival seeks cover.
		if _has_cover_point:
			var to_cover := _cover_point - global_position
			desired = Vector3(to_cover.x, 0.0, to_cover.z)
			if desired.length() < RELOAD_COVER_STOP_DISTANCE:
				desired = Vector3.ZERO
			else:
				reload_run_frames += 1
		else:
			# No cover is guaranteed in the procedural jungle. Keep the reload
			# interruptible, but evade diagonally instead of freezing in the open.
			desired = -forward * 0.58 + side * 0.82
			reload_run_frames += 1
	elif _burst_rounds_remaining > 0:
		# Hold the firing platform through every round in the short burst.
		desired = Vector3.ZERO
	elif _post_burst_strafe_t > 0.0:
		desired = side + forward * _range_correction(enemy_flat.length(),
			weapon_range(weapon_slot))
	elif _burst_settle_t > 0.0:
		desired = Vector3.ZERO
	elif _plant_window_t > 0.0 and tactical_state in [Tactic.HOLD, Tactic.STRAFE]:
		desired = Vector3.ZERO
	else:
		match tactical_state:
			Tactic.RETREAT:
				desired = -forward + side * 0.55
			Tactic.ADVANCE:
				desired = forward + side * 0.22
			Tactic.FLANK:
				var to_flank := _flank_point - global_position
				desired = Vector3(to_flank.x, 0.0, to_flank.z)
			Tactic.COVER:
				var to_cover := _cover_point - global_position
				desired = Vector3(to_cover.x, 0.0, to_cover.z)
				if desired.length() < 1.0:
					desired = Vector3.ZERO
			Tactic.STRAFE:
				desired = side + forward * _range_correction(enemy_flat.length(),
					weapon_range(weapon_slot))
			_:
				desired = Vector3.ZERO

	desired = _arena_boundary_bias(desired)
	_desired_ground_direction = _safe_ground_direction(desired.normalized()) \
		if desired.length() > 0.05 else Vector3.ZERO
	ti.dir = Vector2(_desired_ground_direction.x, _desired_ground_direction.z)
	# Sprint only while closing a genuinely large gap. Combat strafes remain
	# bipedal, keeping the weapon visible and avoiding full-speed perfect aim.
	ti.sprint = tactical_state == Tactic.ADVANCE \
		and enemy_flat.length() > weapon_range(weapon_slot).y + 12.0 \
		and not _is_reloading() and not _active_is_low_for_reload()

	if tactical_state == Tactic.VINE_REPOSITION and _chosen_vine != "":
		var hand_distance := hand_pos().distance_to(_vine_aim_point)
		if hand_distance <= 2.9:
			ti.grab = true
		if is_on_floor() and _jump_t <= 0.0 and \
				(_vine_aim_point.y > hand_pos().y + 0.3 or hand_distance < 5.2):
			ti.jump_just = true
			ti.jump_held = true
			_jump_t = _rng.randf_range(0.75, 1.05)


static func _range_correction(distance: float, ideal: Vector2) -> float:
	if distance < ideal.x + 1.5:
		return -0.38
	if distance > ideal.y - 2.0:
		return 0.30
	return 0.0


func _arena_boundary_bias(desired: Vector3) -> Vector3:
	var bot_flat := Vector2(global_position.x, global_position.z)
	var target_flat := Vector2(target.global_position.x, target.global_position.z)
	if bot_flat.length() <= Gen.ARENA_SOFT_BOUNDARY_RADIUS \
			or target_flat.length() > Gen.ARENA_RADIUS + 4.0:
		return desired
	var inward := Vector3(-bot_flat.x, 0.0, -bot_flat.y).normalized()
	var weight := clampf((bot_flat.length() - Gen.ARENA_SOFT_BOUNDARY_RADIUS)
		/ 4.0, 0.0, 1.0)
	return desired + inward * lerpf(0.35, 1.25, weight)


func _safe_ground_direction(desired: Vector3) -> Vector3:
	if desired.length_squared() < 0.01 or not is_inside_tree():
		return Vector3.ZERO
	var direction := desired.normalized()
	var here_h := Gen.height(global_position.x, global_position.z)
	var probe := global_position + direction * 2.25
	var probe_h := Gen.height(probe.x, probe.z)
	if probe_h < here_h - 1.65 or probe_h < Gen.WATER_Y - 0.15:
		direction = direction.rotated(Vector3.UP, _strafe_sign * PI * 0.52)

	var space := get_world_3d().direct_space_state
	var low_query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * 0.28,
		global_position + Vector3.UP * 0.28 + direction * 1.25)
	low_query.exclude = _self_rids()
	low_query.collision_mask = 1
	var low_hit := space.intersect_ray(low_query)
	if low_hit.is_empty():
		return direction
	var high_query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * 1.42,
		global_position + Vector3.UP * 1.42 + direction * 1.25)
	high_query.exclude = _self_rids()
	high_query.collision_mask = 1
	var high_hit := space.intersect_ray(high_query)
	if high_hit.is_empty() and is_on_floor() and _jump_t <= 0.0 \
			and not _is_reloading() and _post_burst_strafe_t <= 0.0:
		# Vault low arena barricades instead of running against them until a vine
		# happens to become available.
		ti.jump_just = true
		ti.jump_held = true
		_jump_t = _rng.randf_range(0.72, 0.96)
		return direction
	var normal: Vector3 = low_hit.get("normal", Vector3.ZERO)
	var tangent := normal.cross(Vector3.UP)
	if tangent.length_squared() <= 0.01:
		return direction.rotated(Vector3.UP, _strafe_sign * PI * 0.5)
	tangent = tangent.normalized()
	var opposite := -tangent
	if is_equal_approx(tangent.dot(direction), opposite.dot(direction)):
		tangent *= _strafe_sign
	elif opposite.dot(direction) > tangent.dot(direction):
		tangent = opposite
	return tangent


func _update_swing(dt: float) -> void:
	_swing_t += dt
	ti.grab = true
	ti.sprint = false
	var to_enemy := target.global_position - global_position
	var enemy_flat := Vector3(to_enemy.x, 0.0, to_enemy.z)
	var velocity_flat := Vector3(velocity.x, 0.0, velocity.z)
	var steer := 0.0
	if enemy_flat.length_squared() > 0.01 and velocity_flat.length_squared() > 0.01:
		steer = clampf(enemy_flat.normalized().cross(Vector3.UP).dot(
			velocity_flat.normalized()), -1.0, 1.0)
	ti.dir = Vector2(steer * 0.48, -0.72)
	var toward_enemy := velocity_flat.normalized().dot(enemy_flat.normalized()) \
		if velocity_flat.length_squared() > 0.01 \
		and enemy_flat.length_squared() > 0.01 else 0.0
	if (_swing_t >= VINE_RELEASE_MIN and velocity.length() > 9.0 \
			and toward_enemy > -0.1) or _swing_t >= _swing_release_t:
		ti.jump_just = true
		ti.jump_held = true
		ti.grab = false
		_chosen_vine = ""
		_seek_ground = true


func _finish_vine_reposition() -> void:
	_seek_ground = false
	_chosen_vine = ""
	_vine_cooldown = _rng.randf_range(VINE_COOLDOWN_MIN, VINE_COOLDOWN_MAX)
	_ground_phase_t = _rng.randf_range(GROUND_PHASE_MIN, GROUND_PHASE_MAX)
	_plant_window_t = _rng.randf_range(0.75, 1.15)
	_movement_window_t = 0.0
	_shot_t = minf(_shot_t, 0.3)
	_choose_ground_tactic()


func _should_use_vine() -> bool:
	if _seek_ground or state == S.SWING or _chosen_vine != "" \
			or not is_on_floor() or _is_reloading() or _vine_cooldown > 0.0:
		return false
	# One early reposition demonstrates the signature movement. Thereafter vines
	# are reserved for a blocked route, a large range mismatch, or being stuck.
	if vine_repositions == 0 and _combat_age >= FIRST_VINE_DELAY:
		return true
	var distance := _flat_to_target().length()
	return _ground_phase_t <= 0.0 and (
		_los_blocked_t > 1.8 or _stuck_t > 1.25 \
		or distance > weapon_range(weapon_slot).y + 13.0)


func _choose_vine() -> void:
	var hand := hand_pos()
	var enemy := target.global_position
	var enemy_flat := _flat_to_target()
	var side := enemy_flat.normalized().cross(Vector3.UP) * _strafe_sign \
		if enemy_flat.length_squared() > 0.01 else Vector3.RIGHT
	var desired_landing := global_position + side * 10.0 \
		+ enemy_flat.normalized() * clampf((enemy_flat.length() - 24.0) * 0.25,
			-4.0, 4.0)
	var best_score := INF
	var best_id := ""
	var best_point := Vector3.ZERO
	for id in Gen.vines:
		var vine: Dictionary = Gen.vines[id]
		if vine.hidden or bool(vine.get("simulated", false)):
			continue
		var anchor: Vector3 = vine.anchor
		var length: float = vine.len
		if anchor.y < hand.y + 0.65:
			continue
		var depth := clampf(anchor.y - hand.y, 0.4, length)
		var point := anchor + Vector3.DOWN * depth
		var distance := hand.distance_to(point)
		if distance > 19.0:
			continue
		# Favour a lateral combat reposition rather than blindly chaining toward
		# the player. A small approach term still prevents fleeing across the map.
		var target_progress := point.distance_to(enemy) \
			- global_position.distance_to(enemy)
		var score := distance * 0.72 + point.distance_to(desired_landing) * 0.48 \
			+ maxf(target_progress, 0.0) * 0.18 - minf(length, 12.0) * 0.10
		if score < best_score:
			best_score = score
			best_id = id
			best_point = point
	_chosen_vine = best_id
	_vine_aim_point = best_point
	if best_id != "":
		vine_repositions += 1
		_swing_release_t = _rng.randf_range(VINE_RELEASE_MIN, VINE_RELEASE_MAX)
	else:
		_vine_cooldown = 3.0


func _update_weapon_choice() -> void:
	if not active_weapon or state == S.SWING or _is_reloading() \
			or _burst_rounds_remaining > 0:
		return
	# Weapon ballistics care about true distance; navigation still uses the flat
	# separation so a target high on a vine does not trick the bot into a shotgun.
	var distance := hand_pos().distance_to(
		target.global_position + Vector3.UP * 0.55)
	var badly_mismatched := _weapon_is_badly_mismatched(weapon_slot, distance)
	if _active_is_low_for_reload():
		# Under pressure or at a severe range mismatch, draw a loaded suitable gun
		# instead of trying to reload an empty favourite in the open.
		if (_under_fire_t > 0.0 or badly_mismatched) \
				and _emergency_switch_lock_t <= 0.0:
			var emergency_slot := _best_weapon_for_distance(distance, true,
				weapon_slot, true)
			if emergency_slot != 0:
				_equip_tactical_weapon(emergency_slot)
		return
	if _weapon_loaded(weapon_slot) and _weapon_t > 0.0 and not badly_mismatched:
		return
	var next_slot := _best_weapon_for_distance(distance, true, 0, true)
	if next_slot == 0:
		next_slot = _best_weapon_for_distance(distance, true)
	if next_slot == 0:
		next_slot = _best_weapon_for_distance(distance, false)
	if next_slot == 0:
		return
	if next_slot == weapon_slot:
		_weapon_t = _rng.randf_range(WEAPON_SWITCH_MIN, WEAPON_SWITCH_MAX)
		return
	_equip_tactical_weapon(next_slot)


func _equip_tactical_weapon(next_slot: int) -> void:
	equip_weapon(next_slot)
	weapon_switch_count += 1
	weapon_use_counts[next_slot] = int(weapon_use_counts.get(next_slot, 0)) + 1
	_weapon_t = _rng.randf_range(WEAPON_SWITCH_MIN, WEAPON_SWITCH_MAX)
	_emergency_switch_lock_t = EMERGENCY_SWITCH_LOCK
	_shot_t = maxf(_shot_t, _rng.randf_range(0.38, 0.65))
	_clear_weapon_burst()


func _best_weapon_for_distance(distance: float, require_loaded := false,
		excluded_slot := 0, require_combat_ready := false) -> int:
	var best_slot := 0
	var best_score := -INF
	for slot in range(WEAPON_BANANA, WEAPON_SNIPER + 1):
		if slot == excluded_slot:
			continue
		if not _weapon_has_ammo(slot):
			continue
		if require_loaded and not _weapon_loaded(slot):
			continue
		if require_combat_ready and not _weapon_ready_for_fight(slot):
			continue
		var score := weapon_distance_score(slot, distance)
		if slot == weapon_slot:
			# Small hysteresis prevents frantic swaps near a range boundary without
			# overriding a genuinely better gun.
			score += 0.42
		var weapon := _weapon_node(slot)
		var capacity := maxf(float(weapon_capacity(slot)), 1.0)
		score += clampf(float(weapon.ammo) / capacity, 0.0, 1.0) * 0.28
		if not _weapon_loaded(slot):
			score -= 1.4
		score += _rng.randf_range(-0.06, 0.06)
		if score > best_score:
			best_score = score
			best_slot = slot
	return best_slot


func _weapon_is_badly_mismatched(slot: int, distance: float) -> bool:
	var ideal := weapon_range(slot)
	return distance < ideal.x * 0.72 or distance > ideal.y * 1.32


func _update_combat(_dt: float) -> void:
	if not active_weapon:
		return
	if _is_reloading():
		_shot_t = maxf(_shot_t, 0.18)
		return
	if _should_reload_active_weapon():
		_start_tactical_reload()
		return
	if _post_burst_strafe_t > 0.0 or _burst_settle_t > 0.0:
		return
	if _burst_rounds_remaining > 0:
		if _burst_weapon_slot != weapon_slot:
			_clear_weapon_burst()
		elif _can_fire_now():
			_queue_burst_round()
		return
	if _shot_t > 0.0 or not _can_fire_now():
		return
	_begin_weapon_burst()
	if _burst_rounds_remaining > 0:
		_queue_burst_round()


func _begin_weapon_burst() -> void:
	var limits := burst_round_range(weapon_slot)
	var round_count := _rng.randi_range(limits.x, limits.y)
	if state == S.SWING:
		round_count = 1
	round_count = mini(round_count, int(active_weapon.ammo))
	if round_count <= 0:
		return
	_burst_weapon_slot = weapon_slot
	_burst_rounds_remaining = round_count
	_burst_rounds_queued = 0
	_burst_commit_t = BURST_COMMIT_TIMEOUT
	bursts_started += 1


func _queue_burst_round() -> void:
	if _burst_rounds_remaining <= 0 or not active_weapon:
		return

	_prepare_aim_error()
	_queued_shot_context = tactical_state
	last_shot_weapon_slot = weapon_slot
	shots_by_slot[weapon_slot] = int(shots_by_slot.get(weapon_slot, 0)) + 1
	var moving := _horizontal_speed() > PLANTED_FIRE_SPEED
	if state == S.SWING:
		swing_shots += 1
	elif moving:
		moving_shots += 1
		ground_shots += 1
	else:
		ground_shots += 1

	if weapon_slot == WEAPON_SMG:
		ti.shoot_held = true
	else:
		ti.shoot_just = true
	_burst_rounds_remaining -= 1
	_burst_rounds_queued += 1
	if _burst_rounds_remaining <= 0:
		_complete_weapon_burst()


func _complete_weapon_burst() -> void:
	bursts_completed += 1
	last_burst_size = _burst_rounds_queued
	var completed_slot := _burst_weapon_slot
	_clear_weapon_burst()
	if state == S.SWING:
		_shot_t = maxf(_shot_t, _rng.randf_range(1.05, 1.45))
		return
	var strafe_duration := _rng.randf_range(BURST_STRAFE_MIN,
		BURST_STRAFE_MAX)
	if completed_slot == WEAPON_SNIPER:
		strafe_duration += 0.24
	elif completed_slot == WEAPON_SHOTGUN:
		strafe_duration += 0.10
	if _rng.randf() < 0.46:
		_strafe_sign *= -1.0
	_post_burst_strafe_t = strafe_duration
	_burst_settle_t = 0.0
	post_burst_strafes += 1
	_set_tactic(Tactic.STRAFE, strafe_duration + BURST_SETTLE_MAX)
	_movement_window_t = 0.0
	_plant_window_t = 0.0
	# Movement and settle timers gate repeat fire. Heavy one-shot weapons retain
	# an additional readable delay so a sniper body hit never chains into an
	# unavoidable instant follow-up.
	match completed_slot:
		WEAPON_SNIPER:
			_shot_t = _rng.randf_range(1.55, 2.05)
		WEAPON_SHOTGUN:
			_shot_t = _rng.randf_range(0.95, 1.24)
		_:
			_shot_t = 0.0


func _clear_weapon_burst() -> void:
	_burst_weapon_slot = 0
	_burst_rounds_remaining = 0
	_burst_rounds_queued = 0
	_burst_commit_t = 0.0


func _start_tactical_reload() -> void:
	_clear_weapon_burst()
	var cover_is_valid := _has_cover_point \
		and global_position.distance_to(_cover_point) <= RELOAD_COVER_MAX_DISTANCE \
		and _candidate_has_cover(_cover_point)
	if not cover_is_valid:
		cover_is_valid = _choose_cover_point(true, RELOAD_COVER_MAX_DISTANCE)
	# Commit while the grounded state used by the decision is still current.
	# Parent movement runs before its input-driven combat step, so deferring this
	# call through reload_just could otherwise begin the animation after a ledge
	# step had already moved the monkey into the air.
	if not active_weapon.start_reload():
		return
	_reload_cover_run_active = cover_is_valid \
		and global_position.distance_to(_cover_point) > RELOAD_COVER_STOP_DISTANCE
	_reload_hidden_recorded = not _has_line_of_sight()
	if _reload_hidden_recorded:
		reload_hides_reached += 1
	if cover_is_valid:
		_set_tactic(Tactic.COVER, 5.5)
		if _reload_cover_run_active:
			reload_cover_runs += 1
	else:
		_set_tactic(Tactic.RETREAT, 2.6)
	reloads_started += 1
	_shot_t = maxf(_shot_t, 0.35)


func _can_fire_now() -> bool:
	if target.defeated or active_weapon.reload_remaining > 0.0 \
			or active_weapon.cooldown > 0.0 or ti.jump_just or ti.sprint \
			or (ti.grab and state != S.SWING):
		return false
	var distance := hand_pos().distance_to(target.global_position)
	if distance > MAX_COMBAT_RANGE or not _has_line_of_sight():
		return false
	if state == S.SWING:
		# Sniper rounds from a pendulum are intentionally withheld; other guns may
		# produce one wild trick shot during the whole reposition.
		return weapon_slot != WEAPON_SNIPER and _swing_t > 0.45 \
			and swing_shots < vine_repositions
	if not is_on_floor() or state not in [S.GROUND, S.SLIDE]:
		return false
	var speed := _horizontal_speed()
	if speed <= PLANTED_FIRE_SPEED:
		return true
	# Only banana/SMG suppression is allowed while moving. Shotgun and sniper
	# require the visible plant window so their burst damage stays reactable.
	return speed <= MOVING_FIRE_SPEED and weapon_slot in [WEAPON_BANANA,
		WEAPON_SMG] and tactical_state in [Tactic.ADVANCE, Tactic.RETREAT,
		Tactic.FLANK] and _rng.randf() < 0.28


func _prepare_aim_error() -> void:
	var origin := hand_pos()
	var base_point := _observed_target_position + Vector3.UP * 0.54
	var base_direction := (base_point - origin).normalized()
	last_turn_rate_degrees = rad_to_deg(_last_solution_direction.angle_to(
		base_direction)) / maxf(_aim_solution_age, 0.05)
	_last_solution_direction = base_direction
	_aim_solution_age = 0.0
	var stance := 0
	if state == S.SWING:
		stance = 2
	elif _horizontal_speed() > PLANTED_FIRE_SPEED:
		stance = 1
	last_spread_degrees = combat_spread_degrees(weapon_slot, stance,
		_horizontal_speed(), Vector3(_observed_target_velocity.x, 0.0,
		_observed_target_velocity.z).length(), last_turn_rate_degrees,
		origin.distance_to(target.global_position))
	# Short strings are controlled, not perfect: the second and third rounds gain
	# a small amount of bloom before the forced strafe fully resets accuracy.
	if _burst_rounds_queued > 0:
		last_spread_degrees += float(_burst_rounds_queued) * (
			0.24 if weapon_slot == WEAPON_SMG else 0.16)
	var tangent_radius := tan(deg_to_rad(last_spread_degrees)) \
		* sqrt(_rng.randf())
	var angle := _rng.randf() * TAU
	_aim_error.x = cos(angle) * tangent_radius
	# Running and swinging shots are biased below centre mass. This preserves
	# readable misses and prevents upward spread from manufacturing sprinting
	# headshots while still allowing a rare planted precision hit.
	var vertical := sin(angle) * tangent_radius
	if stance > 0:
		vertical = minf(vertical, tangent_radius * 0.12) \
			- tangent_radius * (0.16 if stance == 1 else 0.24)
	_aim_error.y = vertical
	last_aim_height = 0.54 if stance == 0 else (0.45 if stance == 1 else 0.38)


func _should_reload_active_weapon() -> bool:
	if not active_weapon or not _weapon_can_reload(weapon_slot):
		return false
	if state == S.SWING or not is_on_floor() or is_all_fours() \
			or state == S.SWIM or ti.jump_just or ti.grab or ti.sprint:
		return false
	var ammo: int = active_weapon.ammo
	# A freshly drawn fallback gets to spend one complete useful burst before
	# reconsidering a tactical reload; otherwise a one-round sniper would be
	# selected for long range and immediately reloaded without taking the shot.
	if ammo > 0 and _emergency_switch_lock_t > 0.0 \
			and ammo >= burst_round_range(weapon_slot).x:
		return false
	if ammo <= 0:
		return true
	if ammo > reload_threshold(weapon_slot):
		return false
	var distance := _flat_to_target().length()
	if not _has_line_of_sight():
		return true
	if _has_cover_point and _candidate_has_cover(_cover_point):
		return true
	return _under_fire_t <= 0.0 \
		and distance > weapon_range(weapon_slot).x + 4.0


func _active_is_low_for_reload() -> bool:
	return active_weapon != null and _weapon_can_reload(weapon_slot) \
		and int(active_weapon.ammo) <= reload_threshold(weapon_slot)


func _aim() -> Array:
	if _chosen_vine != "" and state != S.SWING:
		var direction := _vine_aim_point - hand_pos()
		if direction.length_squared() > 0.01:
			return [hand_pos(), direction.normalized()]
	return shot_aim()


func shot_aim() -> Array:
	if not target or not is_instance_valid(target):
		return [hand_pos(), Vector3(0.0, 0.0, -1.0)]
	var origin := hand_pos()
	var observed := _observed_target_position
	if observed == Vector3.ZERO:
		observed = target.global_position
	var target_point := observed + Vector3.UP * last_aim_height
	var distance := origin.distance_to(target_point)
	var muzzle_speed := weapon_muzzle_speed(weapon_slot)
	var flight_time := distance / maxf(muzzle_speed, 1.0)
	var lead_fraction := 0.50
	if _horizontal_speed() > PLANTED_FIRE_SPEED:
		lead_fraction = 0.28
	if state == S.SWING:
		lead_fraction = 0.12
	target_point += _observed_target_velocity * flight_time * lead_fraction
	if weapon_slot == WEAPON_SNIPER:
		target_point += Vector3.UP * SniperRifle.drop_below_zero_at(distance)
	else:
		target_point -= BananaBullet.GRAVITY * (0.5 * flight_time * flight_time)
	var direction := (target_point - origin).normalized()
	var right := direction.cross(Vector3.UP)
	if right.length_squared() < 0.01:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var up := right.cross(direction).normalized()
	direction = (direction + right * _aim_error.x + up * _aim_error.y).normalized()
	return [origin, direction]


func _has_line_of_sight() -> bool:
	if not is_inside_tree() or not target or not is_instance_valid(target):
		return false
	var end := target.global_position + Vector3.UP * 0.55
	var query := PhysicsRayQueryParameters3D.create(hand_pos(), end)
	query.exclude = _self_rids()
	query.collision_mask = 1 | CombatHitbox.HITBOX_LAYER
	query.collide_with_areas = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var collider = hit.collider
	var visible_actor = collider.actor if collider is CombatHitbox else collider
	return visible_actor == target


func _self_rids() -> Array[RID]:
	var out: Array[RID] = [get_rid()]
	if body_hitbox:
		out.append(body_hitbox.get_rid())
	if head_hitbox:
		out.append(head_hitbox.get_rid())
	return out


func _choose_cover_point(strict := false, max_distance := 22.0) -> bool:
	_has_cover_point = false
	if not is_inside_tree() or not target:
		return false
	var authored_points: Array = []
	if _in_origin_arena() and Gen.has_method("arena_cover_points"):
		authored_points = Gen.arena_cover_points()
	var best_score := INF
	# Authored points sit beside the arena barricades, not inside their collision.
	# Prefer them whenever the duel is near origin; steering below will still
	# route around the solid face rather than requiring a bespoke navmesh.
	for point_value in authored_points:
		var point: Vector3 = point_value
		var distance_to_point := global_position.distance_to(point)
		if distance_to_point > max_distance:
			continue
		var covered := _candidate_has_cover(point)
		if strict and not covered:
			continue
		var score := distance_to_point \
			+ point.distance_to(target.global_position) * 0.035
		if not covered:
			score += 5.0
		if score < best_score:
			best_score = score
			_cover_point = point
			_has_cover_point = true
	if _has_cover_point:
		return true

	var enemy_flat := _flat_to_target()
	var forward := enemy_flat.normalized() if enemy_flat.length_squared() > 0.01 \
		else Vector3.FORWARD
	for angle in [-1.9, -1.25, -0.72, 0.72, 1.25, 1.9, PI]:
		var direction := forward.rotated(Vector3.UP, float(angle))
		for radius_value in [4.0, 6.5, 8.5]:
			var radius: float = radius_value
			if radius > max_distance:
				continue
			var flat_candidate: Vector3 = global_position + direction * radius
			var candidate := Vector3(flat_candidate.x,
				Gen.height(flat_candidate.x, flat_candidate.z), flat_candidate.z)
			if candidate.y < Gen.WATER_Y - 0.1 \
					or absf(candidate.y - global_position.y) > 2.2:
				continue
			if not _path_is_open(candidate):
				continue
			if not _candidate_has_cover(candidate):
				continue
			var score := global_position.distance_to(candidate) \
				+ candidate.distance_to(target.global_position) * 0.035
			if score < best_score:
				best_score = score
				_cover_point = candidate
				_has_cover_point = true
	return _has_cover_point


func _choose_flank_point() -> void:
	var enemy_flat := _flat_to_target()
	var forward := enemy_flat.normalized() if enemy_flat.length_squared() > 0.01 \
		else Vector3.FORWARD
	if _in_origin_arena() and Gen.has_method("arena_flank_points"):
		var side := forward.cross(Vector3.UP) * _strafe_sign
		var best_score := INF
		for point_value in Gen.arena_flank_points():
			var point: Vector3 = point_value
			var distance_to_point := global_position.distance_to(point)
			if distance_to_point > 30.0:
				continue
			var lateral := point - global_position
			lateral.y = 0.0
			var wrong_side_penalty := 9.0 if lateral.dot(side) < 0.0 else 0.0
			var score := distance_to_point + wrong_side_penalty \
				+ absf(point.distance_to(target.global_position) - 21.0) * 0.18
			if score < best_score:
				best_score = score
				_flank_point = point
		if best_score < INF:
			return
	var candidate := target.global_position - forward * clampf(
		enemy_flat.length(), 10.0, 22.0) \
		+ forward.cross(Vector3.UP) * _strafe_sign * 8.0
	_flank_point = Vector3(candidate.x, Gen.height(candidate.x, candidate.z),
		candidate.z)


func _path_is_open(candidate: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * 0.72,
		candidate + Vector3.UP * 0.72)
	query.exclude = _self_rids()
	query.collision_mask = 1
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or hit.position.distance_to(candidate + Vector3.UP * 0.72) < 0.8


func _candidate_has_cover(candidate: Vector3) -> bool:
	for height in [0.62, 1.02]:
		var destination := candidate + Vector3.UP * float(height)
		var cover_query := PhysicsRayQueryParameters3D.create(
			target.global_position + Vector3.UP * float(height), destination)
		cover_query.exclude = _self_rids()
		cover_query.exclude.append(target.get_rid())
		cover_query.collision_mask = 1
		var cover_hit := get_world_3d().direct_space_state.intersect_ray(
			cover_query)
		if cover_hit.is_empty():
			return false
		var hit_position: Vector3 = cover_hit.position
		if hit_position.distance_to(destination) > 4.2:
			return false
	return true


func _in_origin_arena() -> bool:
	return Vector2(global_position.x, global_position.z).length() \
		<= Gen.ARENA_RADIUS + 3.0


func _flat_to_target() -> Vector3:
	return Vector3(target.global_position.x - global_position.x, 0.0,
		target.global_position.z - global_position.z)


func _horizontal_speed() -> float:
	return Vector3(velocity.x, 0.0, velocity.z).length()


func _is_reloading() -> bool:
	return active_weapon != null and active_weapon.reload_remaining > 0.0


func _weapon_node(slot: int) -> Node3D:
	match slot:
		WEAPON_SHOTGUN:
			return shotgun
		WEAPON_SMG:
			return smg
		WEAPON_SNIPER:
			return sniper
		_:
			return gun


func _weapon_has_ammo(slot: int) -> bool:
	var weapon := _weapon_node(slot)
	return weapon != null and (int(weapon.ammo) > 0 or _weapon_can_reload(slot))


func _weapon_loaded(slot: int) -> bool:
	var weapon := _weapon_node(slot)
	return weapon != null and int(weapon.ammo) > 0


func _weapon_ready_for_fight(slot: int) -> bool:
	var weapon := _weapon_node(slot)
	return weapon != null \
		and int(weapon.ammo) >= burst_round_range(slot).x


func _weapon_can_reload(slot: int) -> bool:
	var weapon := _weapon_node(slot)
	if not weapon:
		return false
	if slot in [WEAPON_BANANA, WEAPON_SHOTGUN]:
		return int(weapon.reserve_ammo) > 0
	return int(weapon.reserve_mags) > 0


static func weapon_range(slot: int) -> Vector2:
	return WEAPON_IDEAL_RANGES[clampi(slot, WEAPON_BANANA, WEAPON_SNIPER)]


static func weapon_capacity(slot: int) -> int:
	match slot:
		WEAPON_SHOTGUN:
			return PumpShotgun.CAPACITY
		WEAPON_SMG:
			return SMG.CAPACITY
		WEAPON_SNIPER:
			return SniperRifle.CAPACITY
		_:
			return BananaGun.CAPACITY


static func weapon_distance_score(slot: int, distance: float) -> float:
	var safe_slot := clampi(slot, WEAPON_BANANA, WEAPON_SNIPER)
	var ideal := weapon_range(safe_slot)
	var score := 0.0
	if distance < ideal.x:
		score = 1.15 - (ideal.x - distance) / maxf(ideal.x, 1.0) * 1.6
	elif distance > ideal.y:
		score = 1.15 - (distance - ideal.y) / maxf(ideal.y, 1.0) * 2.2
	else:
		var midpoint := (ideal.x + ideal.y) * 0.5
		var half_width := maxf((ideal.y - ideal.x) * 0.5, 1.0)
		score = 2.2 - absf(distance - midpoint) / half_width * 0.70
	if safe_slot == preferred_weapon_for_distance(distance):
		score += 1.25
	return score


static func preferred_weapon_for_distance(distance: float) -> int:
	if distance < 10.5:
		return WEAPON_SHOTGUN
	if distance < 25.0:
		return WEAPON_SMG
	if distance < 43.0:
		return WEAPON_BANANA
	return WEAPON_SNIPER


## Automatic weapons use short, controllable strings. The banana sidearm gets
## two paced shots; the bolt-action sniper and pump shotgun relocate after one.
static func burst_round_range(slot: int) -> Vector2i:
	match slot:
		WEAPON_BANANA:
			return Vector2i(2, 2)
		WEAPON_SMG:
			return Vector2i(2, 3)
		_:
			return Vector2i(1, 1)


static func weapon_muzzle_speed(slot: int) -> float:
	match slot:
		WEAPON_SHOTGUN:
			return PumpShotgun.MUZZLE_SPEED
		WEAPON_SMG:
			return SMG.MUZZLE_SPEED
		WEAPON_SNIPER:
			return SniperRifle.MUZZLE_SPEED
		_:
			return BananaGun.MUZZLE_SPEED


static func reload_threshold(slot: int) -> int:
	match slot:
		WEAPON_SHOTGUN:
			return 2
		WEAPON_SMG:
			return 4
		_:
			return 1


## Stance: 0 planted, 1 moving on foot, 2 swinging. All inputs are explicit so
## tests can prove that movement, hard turns and range increase the miss cone.
static func combat_spread_degrees(slot: int, stance: int, own_speed: float,
		target_speed: float, turn_rate_degrees: float, distance: float) -> float:
	var safe_slot := clampi(slot, WEAPON_BANANA, WEAPON_SNIPER)
	var base: float = PLANTED_SPREAD_DEGREES[safe_slot]
	if stance == 1:
		base = MOVING_SPREAD_DEGREES[safe_slot]
	elif stance >= 2:
		base = SWING_SPREAD_DEGREES[safe_slot]
	var own_weight := clampf(own_speed / SPRINT_SPEED, 0.0, 1.5)
	var target_weight := clampf(target_speed / SPRINT_SPEED, 0.0, 1.35)
	var turn_weight := clampf(turn_rate_degrees / 110.0, 0.0, 1.5)
	var ideal := weapon_range(safe_slot)
	var range_penalty := clampf((distance - ideal.y) / maxf(ideal.y, 1.0),
		0.0, 1.0) * 2.3
	return base + own_weight * (0.7 if stance == 0 else 2.5) \
		+ target_weight * 1.25 + turn_weight * 1.8 + range_penalty


## Backwards-compatible tangent spread helper used by the existing combat
## regression. New checks should prefer combat_spread_degrees() above.
static func aim_spread(grounded_stance: bool, distance: float) -> float:
	var degrees := 1.45 if grounded_stance else 9.2
	degrees *= lerpf(0.88, 1.25, clampf(distance / MAX_COMBAT_RANGE, 0.0, 1.0))
	return tan(deg_to_rad(degrees))


static func tactic_label(value: int) -> String:
	match value:
		Tactic.STRAFE:
			return "strafe"
		Tactic.ADVANCE:
			return "advance"
		Tactic.RETREAT:
			return "retreat"
		Tactic.FLANK:
			return "flank"
		Tactic.COVER:
			return "cover"
		Tactic.VINE_REPOSITION:
			return "vine_reposition"
		_:
			return "hold"
