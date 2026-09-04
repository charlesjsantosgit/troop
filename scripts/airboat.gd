class_name Airboat
extends Vehicle
## Flat-bottom swamp runner: five buoyancy points ride the same CPU wave
## field the water shader displaces, a caged six-blade prop pushes it (so it
## also scoots over grass and mud — airboats have no underwater running gear
## to snag), twin rudders steer with prop wash, and the hull transitions from
## displacement drag to planing as it gets on step. No reverse and no brakes
## on water except cutting the fan — authentically terrifying.

const HULL_HALF_WIDTH := 0.98
const HULL_HALF_LENGTH := 1.95
const FLOAT_AREA := 1.85            # m^2 share per buoyancy point
const WATER_DENSITY := 1000.0
const THRUST_MAX := 4200.0
const PROP_WASH_STEER := 2400.0
const SPOOL_RISE_RATE := 1.1
const SPOOL_COAST_RATE := 0.72
const SPOOL_CHOP_RATE := 2.8

var spool := 0.0
var _float_points: Array[Vector3] = [
	Vector3(0, 0, 0),
	Vector3(-HULL_HALF_WIDTH * 0.8, 0, HULL_HALF_LENGTH * 0.85),
	Vector3(HULL_HALF_WIDTH * 0.8, 0, HULL_HALF_LENGTH * 0.85),
	Vector3(-HULL_HALF_WIDTH * 0.8, 0, -HULL_HALF_LENGTH * 0.85),
	Vector3(HULL_HALF_WIDTH * 0.8, 0, -HULL_HALF_LENGTH * 0.85),
]
var _in_water := false
var _prop: Node3D
var _prop_blur: MeshInstance3D
var _rudders: Array[Node3D] = []
var _wake_timer := 0.0
var _dry_idle_t := 0.0


func _init() -> void:
	kind = Kind.BOAT
	mass = 520.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.12, -0.15)
	drag_area = 1.35
	seat_offset = Vector3(0, 1.18, -0.55)
	# Seat the pelvis on the raised bench at y=0.83. The former shared offset
	# put the monkey nearly forty centimetres above this cushion.
	rider_root_offset = Vector3(0, 0.34, -0.55)
	fp_camera_offset = Vector3(0, 1.62, -0.45)
	exit_offsets = [Vector3(-1.7, 0.4, 0.4), Vector3(1.7, 0.4, 0.4),
		Vector3(0, 0.5, 2.6)]
	camera_distance = 6.2
	camera_height = 2.7
	camera_chase_pitch = -0.22
	camera_bank_factor = 0.22
	speed_for_max_fov = 26.0
	engine_stream = "engine_prop"
	engine_pitch_base = 0.5
	engine_pitch_span = 1.35
	engine.configure({
		"torque_curve": [[0, 0.0], [100, 0.0]],
		"idle_rpm": 900.0, "redline_rpm": 3200.0, "limiter_rpm": 3400.0,
	})
	# The flat hull slides over wet grass; keep a touch of physics friction so
	# it still parks on dry ground.
	var slick := PhysicsMaterial.new()
	slick.friction = 0.13
	slick.bounce = 0.0
	physics_material_override = slick


func _ready() -> void:
	super()
	var hull_shape := CollisionShape3D.new()
	var hull_box := BoxShape3D.new()
	hull_box.size = Vector3(HULL_HALF_WIDTH * 2.0, 0.5,
		HULL_HALF_LENGTH * 2.0)
	hull_shape.shape = hull_box
	hull_shape.position = Vector3(0, 0.05, 0)
	add_child(hull_shape)
	var cage_shape := CollisionShape3D.new()
	var cage_box := BoxShape3D.new()
	cage_box.size = Vector3(1.4, 1.5, 0.6)
	cage_shape.shape = cage_box
	cage_shape.position = Vector3(0, 0.95, -1.45)
	add_child(cage_shape)
	_build_body()
	for side in [-1.0, 1.0]:
		# Side-exit dry stacks clear the prop cage instead of sending exhaust
		# through its fan/blur geometry. The outward cant keeps both banks visible
		# from the normal rear chase view and away from the seated monkey.
		add_exhaust(Vector3(side * 0.96, 0.60, -1.41),
			Vector3(side * 0.46, 0.25, -0.85),
			VehicleExhaust.Profile.AIRBOAT)


func mount_verb() -> String:
	return "BOARD"


## A hull settles onto the water surface when spawned over a lake, or its
## flat bottom when beached.
func settle_at(pos: Vector3, yaw: float) -> void:
	var ground := terrain_height_at(pos.x, pos.z)
	global_basis = Basis(Vector3.UP, yaw)
	if ground < Gen.WATER_Y - 0.25:
		global_position = Vector3(pos.x, Gen.WATER_Y + 0.14, pos.z)
	else:
		# Hull collision bottom sits 0.20 below the origin: rest it exactly
		# on the surface, never inside it.
		global_position = Vector3(pos.x, ground + 0.21, pos.z)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	reset_physics_interpolation()


func _simulate(dt: float) -> void:
	# W feeds the fan, releasing it gives a natural rundown, and S performs a
	# fast throttle chop. It is intentionally not a magic water brake or reverse:
	# the planing hull and aerodynamic drag do the actual deceleration.
	var spool_target := input_throttle if driver and has_drive_fuel() else 0.0
	var spool_rate := SPOOL_RISE_RATE if spool_target > spool \
		else SPOOL_COAST_RATE
	if driver == null or input_brake > 0.05:
		spool_target = 0.0
		spool_rate = SPOOL_CHOP_RATE
	spool = move_toward(spool, spool_target, spool_rate * dt)
	engine.rpm = lerpf(900.0, 3200.0, spool)
	_advance_steering(dt)
	_apply_buoyancy(dt)
	_apply_streaming_safe_land_support(dt)
	# Let a freshly spawned hull find the water surface before land friction can
	# classify it. Only six continuous dry seconds count as truly parked; wave
	# crests therefore cannot pin a floating boat in shallow water.
	if driver == null and not _in_water:
		_dry_idle_t += dt
		if _dry_idle_t > 6.0:
			_apply_land_parking(dt)
	else:
		_dry_idle_t = 0.0
	# Fan thrust: the real line of action sits above the CoM (bow-down), but
	# hulls counter it with planing trim — modelled as a thrust application
	# just below the CoM so power lifts the bow onto step instead of
	# plowing the nose into mud or grass.
	var thrust := THRUST_MAX * spool \
		* clampf(1.0 - forward_speed() / 55.0, 0.0, 1.0)
	if not has_drive_fuel():
		thrust = 0.0
	apply_force(global_basis.z * thrust,
		global_basis * Vector3(0, -0.16, -HULL_HALF_LENGTH))
	# Hull attitude damping runs on land too (the engine default damp is
	# replaced with zero): without it the thrust trim see-saws the flat
	# bottom on its stern edge instead of sliding.
	angular_velocity.x = lerpf(angular_velocity.x, 0.0, 2.2 * dt)
	angular_velocity.z = lerpf(angular_velocity.z, 0.0, 2.2 * dt)
	# Rudders: prop wash gives authority even at rest; hull speed adds more.
	var flow := _rudder_flow_speed()
	var wash := spool * PROP_WASH_STEER \
		+ flow * absf(flow) * (95.0 if _in_water else 20.0)
	apply_torque(Vector3.UP * _steer_current * wash * 0.55)
	apply_torque(-Vector3.UP * angular_velocity.y * mass * 1.9)
	_apply_aero(dt)
	if driver:
		_assist_recovery(dt)
	_emit_wake(dt)


func exhaust_activity(profile_kind: int) -> float:
	if remote_controlled:
		return super(profile_kind)
	return VehicleExhaust.sampled_intensity(profile_kind, driver != null,
		spool, spool)


## Signed longitudinal planar flow adds speed authority. Vertical wave motion
## and a sideways hull slide cannot make the rudders bite harder; drifting
## backward correctly reverses the hull-flow portion of their yaw moment.
func _rudder_flow_speed() -> float:
	var flat_forward := Vector3(global_basis.z.x, 0.0, global_basis.z.z)
	if flat_forward.length_squared() < 0.001:
		return 0.0
	var flat_velocity := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	return flat_velocity.dot(flat_forward.normalized())


## A beached, unoccupied hull has static friction even though it has no wheel
## brakes. Preserve free drift on water, but bleed tiny solver creep on land so
## a parked airboat does not wander away while the rest of the world streams.
func _apply_land_parking(dt: float) -> void:
	var flat := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	if flat.length() < 0.65:
		linear_velocity.x = move_toward(linear_velocity.x, 0.0, 2.4 * dt)
		linear_velocity.z = move_toward(linear_velocity.z, 0.0, 2.4 * dt)
	else:
		apply_central_force(-flat * mass * 1.8)


## Terrain collision streams with nearby chunks, but an airboat is world-level
## and may sit behind while its chunk unloads. Wheels already have analytic
## fallback suspension; give the flat hull the same guarantee on dry land so it
## cannot fall through an absent chunk and become buried before the driver
## returns. Loaded real colliders remain fully authoritative.
func _apply_streaming_safe_land_support(_dt: float,
		apply_forces := true) -> int:
	if global_basis.y.y < 0.25:
		return 0
	var centre_probe := probe_ground(global_position + global_basis.y * 0.35,
		1.6)
	if bool(centre_probe.get("real", false)):
		return 0
	var supported_points := 0
	var support_points: Array[Vector3] = [
		Vector3(-HULL_HALF_WIDTH * 0.82, -0.20, HULL_HALF_LENGTH * 0.82),
		Vector3(HULL_HALF_WIDTH * 0.82, -0.20, HULL_HALF_LENGTH * 0.82),
		Vector3(-HULL_HALF_WIDTH * 0.82, -0.20, -HULL_HALF_LENGTH * 0.82),
		Vector3(HULL_HALF_WIDTH * 0.82, -0.20, -HULL_HALF_LENGTH * 0.82),
	]
	for local_point: Vector3 in support_points:
		var world_point: Vector3 = global_position + global_basis * local_point
		var ground_y: float = terrain_height_at(world_point.x, world_point.z)
		if ground_y < Gen.WATER_Y - 0.15:
			continue
		var penetration: float = ground_y - world_point.y
		if penetration <= 0.0:
			continue
		var normal: Vector3 = terrain_normal_at(world_point.x, world_point.z)
		var point_velocity: Vector3 = linear_velocity + angular_velocity.cross(
			world_point - global_position)
		var support: float = penetration * 16000.0 \
			- point_velocity.dot(normal) * 2200.0
		if support > 0.0:
			supported_points += 1
			if apply_forces:
				apply_force(normal * minf(support, mass * 9.8 * 3.0),
					world_point - global_position)
	return supported_points


## Five-point buoyancy against the live wave surface, plus water drag that
## eases from displacement (linear, grabby) into planing (quadratic, light).
func _apply_buoyancy(dt: float) -> void:
	_in_water = false
	var planing := clampf((forward_speed() - 4.5) / 6.0, 0.0, 1.0)
	for point in _float_points:
		var world_point := global_position + global_basis * point
		var surface := Gen.WATER_Y
		if world and world.has_method("water_surface_y"):
			surface = world.water_surface_y(world_point.x, world_point.z)
		var terrain := Gen.height(world_point.x, world_point.z)
		if terrain > surface - 0.15:
			continue   # this corner is over land, not lake
		var depth: float = surface - world_point.y
		if depth <= 0.0:
			continue
		_in_water = true
		var point_velocity := linear_velocity + angular_velocity.cross(
			world_point - global_position)
		var buoyant := WATER_DENSITY * 9.8 * FLOAT_AREA \
			* minf(depth, 0.5)
		var damping := point_velocity.y * WATER_DENSITY * FLOAT_AREA * 0.55
		apply_force(Vector3.UP * maxf(buoyant - damping, 0.0),
			world_point - global_position)
	if not _in_water:
		return
	var v := linear_velocity
	var flat := Vector3(v.x, 0, v.z)
	var fwd := global_basis.z
	var v_fwd := flat.dot(Vector3(fwd.x, 0, fwd.z).normalized())
	var side := flat - Vector3(fwd.x, 0, fwd.z).normalized() * v_fwd
	# Longitudinal: displacement drag fades as the hull climbs onto plane.
	var displacement_drag := absf(v_fwd) * 300.0 * (1.0 - planing * 0.8)
	var planing_drag := v_fwd * absf(v_fwd) * 4.8
	apply_central_force(-Vector3(fwd.x, 0, fwd.z).normalized()
		* signf(v_fwd) * (displacement_drag + absf(planing_drag)))
	# A flat hull still resists sliding sideways hard.
	apply_central_force(-side * (620.0 + side.length() * 260.0))
	# The lake flattens roll/pitch quickly.
	angular_velocity.x = lerpf(angular_velocity.x, 0.0, 3.2 * dt)
	angular_velocity.z = lerpf(angular_velocity.z, 0.0, 3.2 * dt)


func _emit_wake(dt: float) -> void:
	if world == null or world.get("water_fx") == null:
		return
	var sp := speed()
	if not _in_water or sp < 3.0:
		return
	_wake_timer -= dt
	if _wake_timer > 0.0:
		return
	_wake_timer = clampf(3.6 / sp, 0.14, 0.5)
	var bow := global_position + global_basis * Vector3(0, 0.05,
		HULL_HALF_LENGTH * 0.9)
	world.water_fx.exit_splash(bow, linear_velocity,
		clampf(sp / 24.0, 0.2, 0.9))


func _build_body() -> void:
	var body := Node3D.new()
	body.name = "Body"
	add_child(body)
	var hull_mat := paint_material(Color(0.55, 0.56, 0.58), 0.75, 0.35)
	var deck := paint_material(Color(0.36, 0.30, 0.20), 0.1, 0.8)
	var cage_mat := dark_metal_material()

	# Hull: flat pan with a raked bow sheet.
	add_box(body, Vector3(HULL_HALF_WIDTH * 2.0, 0.16,
		HULL_HALF_LENGTH * 2.0), Vector3(0, -0.05, -0.12), hull_mat)
	add_box(body, Vector3(HULL_HALF_WIDTH * 2.0, 0.16, 0.9),
		Vector3(0, 0.10, HULL_HALF_LENGTH - 0.02), hull_mat,
		Vector3(-0.38, 0, 0))
	# Gunwales.
	for side in [-1.0, 1.0]:
		add_box(body, Vector3(0.07, 0.3, HULL_HALF_LENGTH * 2.0),
			Vector3(side * HULL_HALF_WIDTH, 0.18, -0.12), hull_mat)
	add_box(body, Vector3(HULL_HALF_WIDTH * 2.0, 0.3, 0.07),
		Vector3(0, 0.18, -HULL_HALF_LENGTH - 0.10), hull_mat)
	# Deck planking.
	add_box(body, Vector3(HULL_HALF_WIDTH * 1.8, 0.03,
		HULL_HALF_LENGTH * 1.7), Vector3(0, 0.05, 0.05), deck)

	# Raised driver bench on a pedestal + footrest.
	add_box(body, Vector3(0.30, 0.55, 0.30), Vector3(0, 0.42, -0.55),
		cage_mat)
	add_box(body, Vector3(0.72, 0.10, 0.52), Vector3(0, 0.78, -0.55), deck)
	add_box(body, Vector3(0.72, 0.45, 0.10), Vector3(0, 1.02, -0.80), deck)
	add_box(body, Vector3(0.5, 0.04, 0.3), Vector3(0, 0.31, -0.30), cage_mat)
	# Control stick (rudder lever on the left, like the real thing).
	add_cylinder(body, 0.02, 0.02, 0.5, Vector3(-0.34, 0.95, -0.42),
		chrome_material(), Vector3(0.35, 0, 0))
	# A short passenger-side brace gives the free paw a readable contact instead
	# of floating beside the bench while the hull skips over waves.
	add_cylinder(body, 0.018, 0.018, 0.34, Vector3(0.28, 1.02, -0.34),
		chrome_material(), Vector3(0.18, 0, 0))
	# Facing +Z makes the monkey's anatomical left +X in vehicle space.
	add_rider_target(body, &"hand_left", Vector3(0.28, 1.02, -0.34))
	add_rider_target(body, &"hand_right", Vector3(-0.28, 1.02, -0.36))
	add_rider_target(body, &"foot_left", Vector3(0.18, 0.35, -0.30))
	add_rider_target(body, &"foot_right", Vector3(-0.18, 0.35, -0.30))

	# Engine block + fuel tank ahead of the cage.
	add_box(body, Vector3(0.6, 0.42, 0.5), Vector3(0, 0.32, -1.18), cage_mat)
	# Twin dry headers rise from the engine, cross to the hull edges, and turn
	# aft outside the prop cage. Their open caps coincide with the two registered
	# particle outlets above, so no exhaust is hidden by the spinning fan.
	for side in [-1.0, 1.0]:
		add_cylinder(body, 0.034, 0.042, 0.30,
			Vector3(side * 0.34, 0.43, -1.12), cage_mat)
		add_cylinder(body, 0.034, 0.034, 0.62,
			Vector3(side * 0.65, 0.58, -1.12), cage_mat,
			Vector3(0, 0, PI / 2.0))
		add_cylinder(body, 0.038, 0.034, 0.30,
			Vector3(side * 0.96, 0.60, -1.26), cage_mat,
			Vector3(PI / 2.0, 0, 0))
	add_cylinder(body, 0.16, 0.16, 0.55, Vector3(0, 0.30, 0.85),
		paint_material(Color(0.72, 0.15, 0.1), 0.3, 0.5),
		Vector3(0, 0, PI / 2.0))

	# Prop cage: two rings, radial guard bars, and the fan itself.
	for ring_z in [-1.72, -1.20]:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.86
		torus.outer_radius = 0.92
		torus.rings = 24
		torus.ring_segments = 8
		ring.mesh = torus
		ring.rotation = Vector3(PI / 2.0, 0, 0)
		ring.position = Vector3(0, 0.95, ring_z)
		ring.material_override = cage_mat
		body.add_child(ring)
	for i in range(9):
		var angle := TAU * float(i) / 9.0
		add_cylinder(body, 0.02, 0.02, 0.52,
			Vector3(cos(angle) * 0.89, 0.95 + sin(angle) * 0.89, -1.46),
			cage_mat, Vector3(PI / 2.0, 0, 0))
	for i in range(12):
		var angle := TAU * float(i) / 12.0
		var spoke := add_cylinder(body, 0.015, 0.015, 0.86,
			Vector3(cos(angle) * 0.44, 0.95 + sin(angle) * 0.44, -1.72),
			cage_mat)
		spoke.rotation = Vector3(0, 0, angle + PI / 2.0)
	_prop = Node3D.new()
	_prop.position = Vector3(0, 0.95, -1.42)
	body.add_child(_prop)
	for i in range(6):
		var blade := add_box(_prop, Vector3(0.16, 0.78, 0.035),
			Vector3.ZERO, paint_material(Color(0.82, 0.80, 0.72), 0.4, 0.5))
		blade.position = Vector3(0, 0.39, 0).rotated(Vector3.FORWARD,
			TAU * float(i) / 6.0)
		blade.rotation = Vector3(0, 0, TAU * float(i) / 6.0)
		blade.rotate_object_local(Vector3.UP, 0.42)
	add_sphere(_prop, 0.11, Vector3.ZERO, chrome_material())
	# Motion-blur disc that fades in as the fan spins up.
	var blur := CylinderMesh.new()
	blur.top_radius = 0.84
	blur.bottom_radius = 0.84
	blur.height = 0.02
	var blur_mat := StandardMaterial3D.new()
	blur_mat.albedo_color = Color(0.85, 0.85, 0.8, 0.0)
	blur_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	blur_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_prop_blur = MeshInstance3D.new()
	_prop_blur.mesh = blur
	_prop_blur.rotation = Vector3(PI / 2.0, 0, 0)
	_prop_blur.position = Vector3(0, 0.95, -1.42)
	_prop_blur.material_override = blur_mat
	body.add_child(_prop_blur)

	# Twin rudders aft of the cage.
	for side in [-0.42, 0.42]:
		var rudder := Node3D.new()
		rudder.position = Vector3(side, 0.95, -1.95)
		body.add_child(rudder)
		add_box(rudder, Vector3(0.04, 1.35, 0.4), Vector3(0, 0, -0.16),
			paint_material(Color(0.62, 0.58, 0.30), 0.3, 0.55))
		_rudders.append(rudder)
	# Grab rail around the bow.
	add_cylinder(body, 0.025, 0.025, 1.7, Vector3(0, 0.42, 1.55), cage_mat,
		Vector3(0, 0, PI / 2.0))


func _update_extra_visuals(dt: float) -> void:
	if _prop:
		_prop.rotate_object_local(Vector3.FORWARD,
			(4.0 + spool * 90.0) * dt)
	if _prop_blur:
		var mat := _prop_blur.material_override as StandardMaterial3D
		if mat:
			mat.albedo_color.a = spool * 0.22
	for rudder in _rudders:
		rudder.rotation = Vector3(0, _steer_current * 0.9, 0)
