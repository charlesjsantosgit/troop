class_name FriendlyMonkey
extends MonkeyPlayer
## Peaceful admin-spawnable monkeys. Like AiMonkey they drive the shared
## MonkeyPlayer input surface (`ti`), so their movement obeys exactly the same
## physics as a human player — they just never pick up a trigger. Four brains:
## SWINGER loops on nearby vines, FOLLOWER shadows a player, STATUE poses, and
## VILLAGER stands at its post trading bananas for supplies.

enum Mode { SWINGER, FOLLOWER, STATUE, VILLAGER }

const FOLLOW_NEAR := 3.6
const FOLLOW_SPRINT := 12.0

var mode := Mode.STATUE
var follow_target: Node3D
var home := Vector3.ZERO
var _brain_t := 0.0
var _vine_point := Vector3.ZERO
var _vine_active := false
var _swing_hold_t := 0.0
var _hop_t := 5.0
var _rng := RandomNumberGenerator.new()


func configure_friendly(friend_mode: int, spawn_home: Vector3,
		target: Node3D = null) -> void:
	mode = friend_mode as Mode
	home = spawn_home
	follow_target = target
	_rng.seed = int(spawn_home.x * 31.0 + spawn_home.z * 7.0) + 977


func _ready() -> void:
	super._ready()
	test_mode = true
	melee_mode = true  # paws only; the back mount keeps weapons stowed
	if rig:
		rig.set_melee_pose(false, false, 0.0, 0)


## Friendly monkeys are protected by jungle spirits: hits flinch and ook but
## never wound, so a stray shotgun blast can't delete the villager mid-trade.
func take_damage(_amount: float, _source: Node3D, impulse: Vector3,
		_hit_zone := "body") -> void:
	velocity += impulse.limit_length(4.0)
	Sfx.play_at("ook", global_position, -8.0, _rng.randf_range(1.05, 1.3))


func _physics_process(dt: float) -> void:
	_think(dt)
	super._physics_process(dt)


func _think(dt: float) -> void:
	for key in ["jump_just", "grab", "shoot_just", "shoot_held",
			"reload_just", "crouch_just"]:
		ti[key] = false
	_brain_t -= dt
	_hop_t -= dt
	match mode:
		Mode.SWINGER:
			_think_swinger(dt)
		Mode.FOLLOWER:
			_think_follower()
		Mode.VILLAGER:
			_think_villager()
		Mode.STATUE:
			ti.dir = Vector2.ZERO


func _think_swinger(dt: float) -> void:
	if state == S.SWING:
		ti.grab = true
		ti.dir = Vector2(0, -0.7)  # pump the arc
		_swing_hold_t -= dt
		if _swing_hold_t <= 0.0:
			ti.grab = false
			ti.jump_just = true
			_vine_active = false
			_brain_t = _rng.randf_range(1.4, 3.2)
		return
	if _vine_active:
		var flat := _vine_point - global_position
		flat.y = 0.0
		ti.dir = Vector2(flat.x, flat.z).normalized() * 0.85
		ti.grab = flat.length() < 4.2
		if flat.length() < 5.0 and is_on_floor():
			ti.jump_just = true
		if state == S.SWING:
			_swing_hold_t = _rng.randf_range(1.6, 3.0)
		if _brain_t <= 0.0:
			_vine_active = false  # could not reach it; wander instead
		return
	if _brain_t > 0.0:
		# amble back toward home between swings
		var back := home - global_position
		back.y = 0.0
		ti.dir = Vector2(back.x, back.z).normalized() * 0.5 \
			if back.length() > 9.0 else Vector2.ZERO
		return
	var best := Vector3.ZERO
	var best_d := 24.0
	for id in Gen.vines:
		var vine: Dictionary = Gen.vines[id]
		if vine.get("hidden", false) or vine.get("simulated", false):
			continue
		var anchor: Vector3 = vine.anchor
		var grab := anchor + Vector3.DOWN * clampf(anchor.y
			- global_position.y - 1.2, 0.6, float(vine.len))
		var d := grab.distance_to(global_position)
		if d < best_d and grab.y > global_position.y + 1.0:
			best_d = d
			best = grab
	if best != Vector3.ZERO:
		_vine_point = best
		_vine_active = true
		_brain_t = 6.0
	else:
		_brain_t = _rng.randf_range(2.0, 4.0)


## While swinging or approaching, aim at the chosen strand so the parent's
## grab targeting works exactly like a player looking at the vine.
func _aim() -> Array:
	if mode == Mode.SWINGER and _vine_active:
		var dir := (_vine_point - hand_pos()).normalized()
		return [hand_pos(), dir]
	return super._aim()


func _think_follower() -> void:
	if not follow_target or not is_instance_valid(follow_target):
		ti.dir = Vector2.ZERO
		return
	var to_target := follow_target.global_position - global_position
	var flat := Vector2(to_target.x, to_target.z)
	if flat.length() < FOLLOW_NEAR:
		ti.dir = Vector2.ZERO
		return
	ti.dir = flat.normalized()
	ti.sprint = flat.length() > FOLLOW_SPRINT
	if (is_on_wall() or to_target.y > 2.2) and is_on_floor():
		ti.jump_just = true


func _think_villager() -> void:
	var drift := home - global_position
	drift.y = 0.0
	ti.dir = Vector2(drift.x, drift.z).normalized() * 0.6 \
		if drift.length() > 1.6 else Vector2.ZERO
	if _hop_t <= 0.0 and is_on_floor():
		ti.jump_just = true
		Sfx.play_at("ook", global_position, -12.0, 1.2)
		_hop_t = _rng.randf_range(6.0, 11.0)
