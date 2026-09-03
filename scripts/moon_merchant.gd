class_name MoonMerchant
extends CharacterBody3D
## Muenster is a physical, peaceful lunar monkey, using the same articulated
## skeleton as the debug villagers. His small patrol is grounded by the Moon's
## radial gravity; only the greeting/decision work runs at five updates/second.

signal greeted(customer: Node3D)
signal order_presented(quantity: int)

enum Activity { IDLE, PATROL, GREETING, TRADING, THANKING, FLINCH }

const DISPLAY_NAME := "Muenster"
const WALK_SPEED := 1.25
const ACCELERATION := 5.0
const GREETING_DISTANCE := 13.0
const WAKE_DISTANCE := 100.0
const BRAIN_INTERVAL := 0.2
const HOME_OFFSET := Vector3(-1.3, 0.0, -4.65)
const PATROL_OFFSETS := [Vector3(-2.0, 0.0, -4.65),
	Vector3(1.65, 0.0, -5.05), Vector3(0.3, 0.0, -6.1)]

static var _gold_material: StandardMaterial3D
static var _navy_material: StandardMaterial3D
static var _cheese_mesh: CylinderMesh

var display_name := DISPLAY_NAME
var rig: MonkeyRig
var suit: SpaceSuitSystem
var activity := Activity.IDLE
var home := Vector3.ZERO
var customer: Node3D
var status_label: Label3D
var cheese_sample: MeshInstance3D
var _shop: Node3D
var _moon: Node3D
var _brain_remaining := 0.0
var _activity_remaining := 2.4
var _greeting_cooldown := 0.0
var _reaction_remaining := 0.0
var _patrol_index := 0
var _walk_target := Vector3.ZERO
var _time := 0.0
var _animation_remaining := 0.0
var _trading := false
var _customer_was_near := false
var _collision: CollisionShape3D
var _hitbox: CombatHitbox
var _stuck_remaining := 0.0
var _initialized := false


func configure(shop: Node3D) -> void:
	_shop = shop
	_moon = shop.get_parent()


func _ready() -> void:
	name = "MuensterTheMoonMerchant"
	collision_layer = 1
	collision_mask = 1
	floor_snap_length = 0.45
	floor_max_angle = deg_to_rad(50.0)
	safe_margin = 0.025
	_collision = CollisionShape3D.new()
	_collision.name = "MerchantBodyCollision"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.29
	capsule.height = 1.3
	_collision.shape = capsule
	_collision.position.y = 0.65
	add_child(_collision)
	rig = MonkeyRig.new()
	rig.name = "ArticulatedLunarMonkey"
	rig.setup(DISPLAY_NAME, true)
	add_child(rig)
	_clear_hostile_outlines(rig)
	rig.set_melee_pose(false, false, 0.0, 0)
	# This resident's regenerative life-support pack stays full. The existing
	# suit supplies real joint-mounted sleeves, boots, visor and oxygen tanks.
	suit = SpaceSuitSystem.new()
	suit.equip_for(self)
	suit.set_vacuum_exposure(false)
	suit.set_physics_process(false)
	_build_merchant_livery()
	_hitbox = CombatHitbox.new()
	_hitbox.name = "MerchantHitbox"
	_hitbox.setup_capsule(self, "body", 0.29, 1.1)
	_hitbox.position.y = 0.65
	add_child(_hitbox)
	if is_instance_valid(_shop):
		home = _ground_point(_shop.to_global(HOME_OFFSET))
		global_position = home + _up_at(home) * 0.06
		_align_up(_up_at(global_position))
	_walk_target = home
	_initialized = true


func set_customer(actor: Node3D) -> void:
	customer = actor if is_instance_valid(actor) else null
	if customer == null:
		_trading = false


func begin_trade(actor: Node3D) -> void:
	set_customer(actor)
	_trading = true
	activity = Activity.TRADING
	_activity_remaining = 0.0
	_reaction_remaining = 0.0
	_set_status("Bring your harvest. Let's trade!")


func end_trade() -> void:
	_trading = false
	if activity == Activity.TRADING:
		activity = Activity.IDLE
		_activity_remaining = 2.0
		_set_status("")


func react_to_trade(accepted: bool, quantity: int, reason := "") -> void:
	if accepted:
		activity = Activity.THANKING
		_reaction_remaining = 2.3
		_set_status("A pleasure doing business. Safe travels!")
		order_presented.emit(quantity)
	else:
		activity = Activity.TRADING if _trading else Activity.IDLE
		_reaction_remaining = 2.6
		_set_status(reason if not reason.is_empty() else "Check your bananas and backpack.")


## A stray shot gives visible feedback but cannot remove the only merchant.
func take_damage(_amount: float, _source: Node3D, impulse: Vector3,
		_hit_zone := "body") -> void:
	velocity += impulse.limit_length(2.2)
	activity = Activity.FLINCH
	_reaction_remaining = 0.65
	_set_status("Easy! This is a cheese shop.")


func _physics_process(delta: float) -> void:
	if not _initialized or not is_visible_in_tree():
		return
	var customer_valid := is_instance_valid(customer)
	if customer_valid and global_position.distance_squared_to(
			customer.global_position) > WAKE_DISTANCE * WAKE_DISTANCE \
			and is_on_floor():
		velocity = Vector3.ZERO
		return
	_time += delta
	_brain_remaining -= delta
	_activity_remaining = maxf(_activity_remaining - delta, 0.0)
	_greeting_cooldown = maxf(_greeting_cooldown - delta, 0.0)
	_reaction_remaining = maxf(_reaction_remaining - delta, 0.0)
	if _brain_remaining <= 0.0:
		_brain_remaining = BRAIN_INTERVAL
		_think()
	var radial_up := _up_at(global_position)
	_align_up(radial_up)
	var desired := Vector3.ZERO
	if activity == Activity.PATROL:
		var toward := (_walk_target - global_position).slide(radial_up)
		if toward.length() > 0.22:
			desired = toward.normalized() * WALK_SPEED
	var vertical_speed := velocity.dot(radial_up)
	var tangent := velocity.slide(radial_up)
	tangent = tangent.move_toward(desired, ACCELERATION * delta)
	if is_on_floor() and vertical_speed < 0.0:
		vertical_speed = 0.0
	var gravity := Vector3.DOWN * 1.62
	if is_instance_valid(_moon) and _moon.has_method("gravity_at"):
		gravity = _moon.call("gravity_at", global_position)
	velocity = tangent + radial_up * vertical_speed + gravity * delta
	move_and_slide()
	if activity == Activity.PATROL and is_on_wall():
		# Patrol stays in the open forecourt. A customer/body obstructing a route
		# makes him choose the next short leg instead of pushing forever.
		_stuck_remaining += delta
		if _stuck_remaining > 1.0:
			_finish_patrol()
	else:
		_stuck_remaining = 0.0


func _think() -> void:
	# The slow brain checks recovery only while airborne. Grounded collision
	# already proves support, avoiding repeated procedural terrain samples.
	var stranded := global_position.distance_squared_to(home) > 24.0 * 24.0
	if not stranded and not is_on_floor() and is_instance_valid(_moon) \
			and _moon.has_method("altitude_at"):
		stranded = float(_moon.call("altitude_at", global_position)) < -2.0
	if stranded:
		global_position = home + _up_at(home) * 0.08
		velocity = Vector3.ZERO
		activity = Activity.IDLE
		_activity_remaining = 1.5
		reset_physics_interpolation()
	var near := is_instance_valid(customer) and global_position \
		.distance_squared_to(customer.global_position) <= GREETING_DISTANCE * GREETING_DISTANCE
	if _reaction_remaining > 0.0:
		return
	if activity == Activity.THANKING or activity == Activity.FLINCH:
		activity = Activity.TRADING if _trading else Activity.IDLE
		_activity_remaining = 2.0
		_set_status("")
	if _trading and near:
		activity = Activity.TRADING
		return
	if _trading and not near:
		end_trade()
	if near:
		if not _customer_was_near and _greeting_cooldown <= 0.0:
			activity = Activity.GREETING
			_activity_remaining = 1.8
			_greeting_cooldown = 16.0
			_set_status("Welcome, Earth monkey! E to trade.")
			greeted.emit(customer)
		elif activity != Activity.GREETING or _activity_remaining <= 0.0:
			activity = Activity.IDLE
			_set_status("E  ·  MOON CHEESE")
		_customer_was_near = true
		return
	_customer_was_near = false
	_set_status("")
	if activity == Activity.GREETING:
		activity = Activity.IDLE
		_activity_remaining = 1.0
	if activity == Activity.PATROL:
		if (_walk_target - global_position).slide(up_direction).length() < 0.3 \
				or _activity_remaining <= 0.0:
			_finish_patrol()
	elif _activity_remaining <= 0.0 and is_instance_valid(_shop):
		_walk_target = _ground_point(_shop.to_global(PATROL_OFFSETS[_patrol_index]))
		activity = Activity.PATROL
		_activity_remaining = 6.0


func _finish_patrol() -> void:
	_patrol_index = (_patrol_index + 1) % PATROL_OFFSETS.size()
	activity = Activity.IDLE
	_activity_remaining = 2.2 + float(_patrol_index) * 0.5
	_stuck_remaining = 0.0


func _process(delta: float) -> void:
	if not _initialized or not is_visible_in_tree():
		return
	var distance_sq := global_position.distance_squared_to(customer.global_position) \
		if is_instance_valid(customer) else 0.0
	if distance_sq > WAKE_DISTANCE * WAKE_DISTANCE:
		return
	_animation_remaining += delta
	# Nearby gestures are smooth; distant limbs update at a bounded 15 Hz.
	if distance_sq > 28.0 * 28.0 and _animation_remaining < 1.0 / 15.0:
		return
	var dt := minf(_animation_remaining, 0.1)
	_animation_remaining = 0.0
	var face_direction := velocity.slide(up_direction)
	if is_instance_valid(customer) and distance_sq < GREETING_DISTANCE * GREETING_DISTANCE:
		face_direction = (customer.global_position - global_position).slide(up_direction)
	rig.face(face_direction, dt)
	var animation := MonkeyRig.Anim.RUN if velocity.slide(up_direction).length() > 0.35 \
		else MonkeyRig.Anim.IDLE
	if not is_on_floor():
		animation = MonkeyRig.Anim.AIR
	rig.update_motion(dt, animation, velocity, is_on_floor(), Vector3.ZERO)
	cheese_sample.visible = activity == Activity.THANKING or activity == Activity.TRADING
	match activity:
		Activity.GREETING:
			var wave := sin(_time * 11.0) * 0.3
			rig.sh_l.rotation = Vector3(-2.05, 0.0, 0.45)
			rig.el_l.rotation = Vector3(1.1, 0.0, wave)
		Activity.TRADING, Activity.THANKING:
			rig.sh_r.rotation = Vector3(-1.0, 0.0, -0.18)
			rig.el_r.rotation = Vector3(-0.42, 0.0, 0.0)
			if activity == Activity.THANKING:
				rig.head_p.rotation.x += sin(_time * 7.0) * 0.14
		Activity.FLINCH:
			rig.torso_p.rotation.x -= sin(_reaction_remaining * PI / 0.65) * 0.28
			rig.sh_l.rotation.x = -1.1
	status_label.visible = not status_label.text.is_empty() \
		and distance_sq < 18.0 * 18.0


func _ground_point(world_point: Vector3) -> Vector3:
	if is_instance_valid(_moon) and _moon.has_method("surface_position_at"):
		return _moon.call("surface_position_at", world_point, 0.0)
	if is_instance_valid(_moon) and _moon.has_method("height_at"):
		var local := _moon.to_local(world_point)
		local.y = float(_moon.call("height_at", local.x, local.z))
		return _moon.to_global(local)
	return world_point


func _up_at(world_point: Vector3) -> Vector3:
	if is_instance_valid(_moon) and _moon.has_method("radial_up_at"):
		return _moon.call("radial_up_at", world_point)
	return Vector3.UP


func _align_up(radial_up: Vector3) -> void:
	up_direction = radial_up
	var forward := (-global_basis.z).slide(radial_up).normalized()
	if forward.length_squared() < 0.01:
		forward = Vector3.RIGHT.slide(radial_up)
		if forward.length_squared() < 0.01:
			forward = Vector3.FORWARD.slide(radial_up)
		forward = forward.normalized()
	global_basis = Basis.looking_at(forward, radial_up)


func _set_status(text: String) -> void:
	if status_label and status_label.text != text:
		status_label.text = text


static func _clear_hostile_outlines(root: Node) -> void:
	for child in root.get_children():
		if child is MeshInstance3D:
			child.material_overlay = null
		_clear_hostile_outlines(child)


func _build_merchant_livery() -> void:
	_ensure_materials()
	# The gold cloth is this merchant's own livery, never a modification of the
	# shared white player-suit material.
	var apron_mesh := BoxMesh.new()
	apron_mesh.size = Vector3(0.31, 0.37, 0.018)
	var apron := _mesh(rig.torso_p, "GoldenCheesemakerApron", apron_mesh,
		Vector3(0.0, 0.16, -0.217), _gold_material)
	apron.rotation.x = -0.05
	var badge_mesh := CylinderMesh.new()
	badge_mesh.top_radius = 0.057
	badge_mesh.bottom_radius = 0.057
	badge_mesh.height = 0.018
	badge_mesh.radial_segments = 12
	var badge := _mesh(rig.torso_p, "CraterAndCurdBadge", badge_mesh,
		Vector3(0.0, 0.27, -0.239), _navy_material)
	badge.rotation.x = PI * 0.5
	var hat := _mesh(rig.head_p, "CheeseHat", _cheese_mesh,
		Vector3(0.0, 0.255, 0.01), _gold_material)
	hat.scale = Vector3(1.65, 1.1, 1.5)
	hat.rotation.y = 0.3
	cheese_sample = _mesh(rig.paw_r, "WrappedMoonCheese", _cheese_mesh,
		Vector3(0.0, -0.04, -0.13), _gold_material)
	cheese_sample.visible = false
	status_label = Label3D.new()
	status_label.name = "MerchantDialogue"
	status_label.position.y = 1.92
	status_label.font_size = 30
	status_label.pixel_size = 0.005
	status_label.modulate = Color(1.0, 0.88, 0.48)
	status_label.outline_size = 7
	status_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	status_label.no_depth_test = false
	status_label.visible = false
	add_child(status_label)
	if rig.tag:
		rig.tag.text = "MUENSTER · CHEESEKEEPER"
		rig.tag.modulate = Color(1.0, 0.83, 0.3)
		rig.tag.no_depth_test = false
		rig.tag.visibility_range_end = 28.0


static func _mesh(parent: Node3D, part_name: String, shape: PrimitiveMesh,
		local_position: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = shape
	instance.position = local_position
	instance.material_override = material
	parent.add_child(instance)
	return instance


static func _ensure_materials() -> void:
	if _gold_material:
		return
	_gold_material = StandardMaterial3D.new()
	_gold_material.albedo_color = Color(1.0, 0.69, 0.12)
	_gold_material.roughness = 0.78
	_gold_material.disable_fog = true
	_navy_material = StandardMaterial3D.new()
	_navy_material.albedo_color = Color(0.055, 0.11, 0.17)
	_navy_material.roughness = 0.7
	_navy_material.disable_fog = true
	_cheese_mesh = CylinderMesh.new()
	_cheese_mesh.top_radius = 0.105
	_cheese_mesh.bottom_radius = 0.14
	_cheese_mesh.height = 0.1
	_cheese_mesh.radial_segments = 5
