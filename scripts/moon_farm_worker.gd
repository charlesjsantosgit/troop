class_name MoonFarmWorker
extends CharacterBody3D
## Brie is a suited farmer with real radial movement and collisions. Economy
## work is authoritative; the snapshot chooses which bed she visibly services.

enum Activity { OFF_DUTY, WALKING, TENDING, GREETING }

const SPEED := 2.1
const WAKE_DISTANCE := 110.0
const BRAIN_INTERVAL := 0.2

var rig: MonkeyRig
var suit: SpaceSuitSystem
var customer: Node3D
var activity := Activity.OFF_DUTY
var target_plot := -1
var hired := false
var work_cycles := 0
var status_label: Label3D
var _colony: Node3D
var _moon: Node3D
var _route := PackedVector3Array()
var _route_index := 0
var _requested_plot := -1
var _brain := 0.0
var _time := 0.0
var _tend_remaining := 0.0
var _animation_elapsed := 0.0
var _blocked_for := 0.0
var _collision: CollisionShape3D
var _watering_can: Node3D
var _initialized := false


func configure(colony: Node3D, moon: Node3D) -> void:
	_colony = colony
	_moon = moon


func _ready() -> void:
	name = "BrieTheMoonFarmer"
	collision_layer = 1
	collision_mask = 1
	safe_margin = 0.025
	floor_snap_length = 0.5
	floor_max_angle = deg_to_rad(50.0)
	_collision = CollisionShape3D.new()
	_collision.name = "FarmerBodyCollision"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.29
	capsule.height = MonkeyRig.npc_height("Brie")
	_collision.shape = capsule
	_collision.position.y = capsule.height * 0.5
	add_child(_collision)
	rig = MonkeyRig.new()
	rig.name = "ArticulatedFarmerMonkey"
	rig.setup("Brie", true)
	rig.set_standing_height(MonkeyRig.npc_height("Brie"))
	add_child(rig)
	MoonMerchant._clear_hostile_outlines(rig)
	rig.set_melee_pose(false, false, 0.0, 0)
	suit = SpaceSuitSystem.new()
	suit.equip_for(self)
	suit.set_vacuum_exposure(false)
	suit.set_physics_process(false)
	_build_livery()
	var home: Vector3 = _colony.call("worker_home_position")
	global_position = home + _up(home) * 0.04
	_align()
	_initialized = true
	visible = false
	_collision.set_deferred("disabled", true)


func set_customer(actor: Node3D) -> void:
	customer = actor if is_instance_valid(actor) else null


func apply_snapshot(state: Dictionary) -> void:
	var upgrades: Dictionary = state.get("upgrades", {})
	var next_hired := int(upgrades.get("helper", 0)) > 0
	if hired != next_hired:
		hired = next_hired
		visible = hired
		_collision.set_deferred("disabled", not hired)
		if not hired:
			velocity = Vector3.ZERO
			activity = Activity.OFF_DUTY
			_route.clear()
	var helper: Dictionary = state.get("helper", {})
	_requested_plot = clampi(int(helper.get("target", -1)), -1, 5)
	if _requested_plot < 0:
		# When all current work finished, patrol unlocked beds for the next crop.
		var plots: Array = state.get("plots", [])
		for plot in plots:
			if plot is Dictionary and bool(plot.get("unlocked", false)) \
					and bool(plot.get("planted", false)) and not bool(plot.get("ready", false)):
				_requested_plot = int(plot.get("id", 0))
				break


func _physics_process(delta: float) -> void:
	if not _initialized or not hired or not is_visible_in_tree() \
			or not is_instance_valid(customer):
		return
	if global_position.distance_squared_to(customer.global_position) > WAKE_DISTANCE * WAKE_DISTANCE \
			and is_on_floor():
		velocity = Vector3.ZERO
		return
	_time += delta
	_brain -= delta
	_tend_remaining = maxf(_tend_remaining - delta, 0.0)
	if _brain <= 0.0:
		_brain = BRAIN_INTERVAL
		_think()
	_align()
	var desired := Vector3.ZERO
	if activity == Activity.WALKING and _route_index < _route.size():
		var direction := (_route[_route_index] - global_position).slide(up_direction)
		if direction.length_squared() > 0.07:
			desired = direction.normalized() * SPEED
	var vertical := velocity.dot(up_direction)
	if is_on_floor() and vertical < 0.0:
		vertical = 0.0
	var gravity: Vector3 = _moon.call("gravity_at", global_position)
	velocity = velocity.slide(up_direction).move_toward(desired, 7.0 * delta) \
		+ up_direction * vertical + gravity * delta
	move_and_slide()
	if activity == Activity.WALKING and is_on_wall():
		_blocked_for += delta
		if _blocked_for > 1.5:
			# A visitor can block the service lane. Wait and choose a new route;
			# never teleport through them or force a collision through a bed.
			activity = Activity.GREETING
			_tend_remaining = 2.0
			_route.clear()
			_blocked_for = 0.0
	else:
		_blocked_for = 0.0


func _think() -> void:
	if not is_on_floor() and float(_moon.call("altitude_at", global_position)) < -2.0:
		var home: Vector3 = _colony.call("worker_home_position")
		global_position = home + _up(home) * 0.06
		velocity = Vector3.ZERO
		_route.clear()
		activity = Activity.OFF_DUTY
		reset_physics_interpolation()
	if activity == Activity.WALKING:
		if _route_index < _route.size() and global_position.distance_to(_route[_route_index]) < 0.4:
			_route_index += 1
		if _route_index >= _route.size():
			activity = Activity.TENDING
			_tend_remaining = 3.2
			work_cycles += 1
		return
	if _tend_remaining > 0.0:
		return
	var next_plot := _requested_plot
	if next_plot < 0:
		activity = Activity.GREETING if global_position.distance_to(customer.global_position) < 8.0 \
			else Activity.OFF_DUTY
		return
	if target_plot == next_plot and global_position.distance_to(
			_colony.call("plot_standing_position", next_plot)) < 0.65:
		activity = Activity.TENDING
		_tend_remaining = 3.2
		work_cycles += 1
		return
	target_plot = next_plot
	_route = _colony.call("worker_route", global_position, target_plot)
	_route_index = 0
	activity = Activity.WALKING


func _process(delta: float) -> void:
	if not _initialized or not hired or not is_visible_in_tree() or not is_instance_valid(customer):
		return
	var distance_sq := global_position.distance_squared_to(customer.global_position)
	if distance_sq > WAKE_DISTANCE * WAKE_DISTANCE:
		return
	_animation_elapsed += delta
	if distance_sq > 30.0 * 30.0 and _animation_elapsed < 1.0 / 15.0:
		return
	var dt := minf(_animation_elapsed, 0.1)
	_animation_elapsed = 0.0
	var forward := velocity.slide(up_direction)
	if activity == Activity.TENDING and target_plot >= 0:
		var point: Vector3 = _colony.call("plot_world_position", target_plot)
		forward = (point - global_position).slide(up_direction)
	elif activity == Activity.GREETING:
		forward = (customer.global_position - global_position).slide(up_direction)
	rig.face(forward, dt)
	var animation := MonkeyRig.Anim.RUN if velocity.slide(up_direction).length() > 0.35 \
		else MonkeyRig.Anim.IDLE
	if not is_on_floor():
		animation = MonkeyRig.Anim.AIR
	rig.update_motion(dt, animation, velocity, is_on_floor(), Vector3.ZERO)
	_watering_can.visible = activity == Activity.TENDING
	if activity == Activity.TENDING:
		# All gesture poses change local joint rotations, preserving exact limb
		# anchors in the Moon realm's large world coordinates.
		rig.torso_p.rotation.x = 0.16
		rig.head_p.rotation.x = 0.18
		rig.sh_r.rotation = Vector3(-0.98 + sin(_time * 3.8) * 0.16, 0, -0.25)
		rig.el_r.rotation.x = -0.55
		rig.sh_l.rotation = Vector3(-0.65, 0, 0.2)
		rig.el_l.rotation.x = -0.45
	elif activity == Activity.GREETING:
		rig.sh_l.rotation = Vector3(-1.9, 0, 0.3)
		rig.el_l.rotation.z = sin(_time * 8.0) * 0.22
	status_label.text = "BRIE · TENDING BED %02d" % (target_plot + 1) if activity == Activity.TENDING \
		else ("BRIE · ON FARM DUTY" if activity == Activity.WALKING else "BRIE · YOUR FARM HELPER")
	status_label.visible = distance_sq < 22.0 * 22.0


func _up(point: Vector3) -> Vector3:
	return _moon.call("radial_up_at", point)


func _align() -> void:
	up_direction = _up(global_position)
	var forward := (-global_basis.z).slide(up_direction).normalized()
	if forward.length_squared() < 0.01:
		forward = Vector3.FORWARD.slide(up_direction).normalized()
	if forward.length_squared() < 0.01:
		forward = Vector3.RIGHT.slide(up_direction).normalized()
	global_basis = Basis.looking_at(forward, up_direction)


func _build_livery() -> void:
	var apron_material := StandardMaterial3D.new()
	apron_material.albedo_color = Color(0.19, 0.57, 0.48)
	apron_material.roughness = 0.86
	apron_material.disable_fog = true
	var apron := BoxMesh.new()
	apron.size = Vector3(0.32, 0.38, 0.023)
	MoonMerchant._mesh(rig.torso_p, "FarmersApron", apron, Vector3(0, 0.15, -0.218), apron_material)
	var brim := CylinderMesh.new()
	brim.top_radius = 0.36
	brim.bottom_radius = 0.36
	brim.height = 0.045
	brim.radial_segments = 10
	MoonMerchant._mesh(rig.head_p, "FarmSunVisor", brim, Vector3(0, 0.22, 0), apron_material)
	_watering_can = Node3D.new()
	_watering_can.name = "NutrientApplicator"
	_watering_can.position = Vector3(0, -0.02, -0.13)
	rig.paw_r.add_child(_watering_can)
	var can := CylinderMesh.new()
	can.top_radius = 0.12
	can.bottom_radius = 0.12
	can.height = 0.21
	can.radial_segments = 8
	MoonMerchant._mesh(_watering_can, "NutrientTank", can, Vector3.ZERO, apron_material)
	var spout := BoxMesh.new()
	spout.size = Vector3(0.06, 0.07, 0.23)
	MoonMerchant._mesh(_watering_can, "ApplicatorSpout", spout, Vector3(0, 0.035, -0.17), apron_material)
	_watering_can.visible = false
	status_label = Label3D.new()
	status_label.position.y = rig.standing_height + 0.35
	status_label.font_size = 30
	status_label.pixel_size = 0.004
	status_label.modulate = Color(0.58, 1.0, 0.79)
	status_label.outline_size = 7
	status_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	status_label.no_depth_test = false
	add_child(status_label)
	if rig.tag:
		rig.tag.visible = false
