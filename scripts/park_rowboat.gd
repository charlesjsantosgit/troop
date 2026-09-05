class_name ParkRowboat
extends Vehicle
## Human-powered lake boat. Uses the game's normal authenticated vehicle seat,
## camera, rider IK and replication, with a colliding hull and dock-only exits.
const Plan = preload("res://scripts/city_plan.gd")
const Layout = preload("res://scripts/city_park_layout.gd")
const MAX_SPEED := 4.8
const REVERSE_SPEED := 1.25
const HULL_DRAFT := .22
var definition: Dictionary = {}
var returning := false
var _return_center := false
var _speed := 0.0
var _time := 0.0
var _oars: Array[Node3D] = []
var _oar_phase := 0.0
var safe_boundary_stops := 0
var dock_returns := 0

func _init() -> void:
	kind = Kind.BOAT
	mass = 120
	seat_offset = Vector3(0, .74, -.35)
	rider_root_offset = Vector3(0, -.10, -.35)
	fp_camera_offset = Vector3(0, 1.20, -.3)
	camera_distance = 7.5
	camera_height = 2.5
	camera_chase_pitch = -.22
	speed_for_max_fov = 20.0
	camera_bank_factor = .05

func _ready() -> void:
	# This slow kinematic hull is swept before every movement, so shoreline and
	# dock collisions stay authoritative without a buoyancy solver fighting the
	# compact, separately elevated city lake water plane.
	collision_layer = 1
	collision_mask = 1
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_space = get_world_3d().direct_space_state
	_exclude = [get_rid()]
	definition = Layout.boat_definition(vid)
	_build_hull()
	var shape := CollisionShape3D.new()
	var hull := ConvexPolygonShape3D.new()
	var points := PackedVector3Array()
	for y in [-.22, .40]:
		for p in [Vector2(0,2.7),Vector2(.93,1.7),Vector2(1.0,-1.8),Vector2(0,-2.7),Vector2(-1.0,-1.8),Vector2(-.93,1.7)]:
			points.append(Vector3(p.x,y,p.y))
	hull.points = points
	shape.shape = hull
	shape.name = "PhysicalRowboatHull"
	add_child(shape)
	rider_targets[&"foot_left"] = Vector3(-.28,.04,.32)
	rider_targets[&"foot_right"] = Vector3(.28,.04,.32)

func display_name() -> String: return "LANTERN LAKE ROWBOAT"
func mount_verb() -> String: return "BOARD"
func fuel_readout() -> String: return "ROW POWER · W/S row · A/D steer · E return to landing"
func has_drive_fuel() -> bool: return true
func configure_frontier_fuel(_simulation: RefCounted) -> void: pass
func _use_frontier_fuel(_dt: float) -> void: pass

func settle_at(pos: Vector3, yaw: float) -> void:
	global_position = Vector3(pos.x, Plan.POND_SURFACE_Y + .10, pos.z)
	global_basis = Basis(Vector3.UP, yaw)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	reset_physics_interpolation()

func interaction_position() -> Vector3:
	return definition.get("exit", seat_global())

func at_dock() -> bool:
	return not definition.is_empty() and Vector2(global_position.x,global_position.z).distance_to(Vector2(definition.pos.x,definition.pos.z)) < 1.0 and absf(_speed) < .15

func can_enter(player: Node3D) -> bool:
	return super.can_enter(player) and at_dock() and is_instance_valid(player) \
		and player.global_position.distance_to(interaction_position()) <= Vehicle.ENTER_RANGE \
		and _safe_dock_exit(player)

func _safe_dock_exit(player:Node3D)->bool:
	# The occupied vehicle disables the player's own collision mask; use the
	# world's solid mask explicitly for this independent landing clearance query.
	if definition.is_empty() or not is_instance_valid(player): return false
	var destination:Vector3=definition.exit
	var floor_query:=PhysicsRayQueryParameters3D.create(destination+Vector3.UP*.15,destination-Vector3.UP*.25,1,[player.get_rid(),get_rid()])
	var hit:=get_world_3d().direct_space_state.intersect_ray(floor_query)
	if hit.is_empty() or hit.normal.y<.65: return false
	var shape_query:=PhysicsShapeQueryParameters3D.new()
	shape_query.shape=player._collision_shape.shape
	shape_query.transform=Transform3D(Basis.IDENTITY,destination+player._collision_shape.position)
	shape_query.collision_mask=1;shape_query.exclude=[player.get_rid(),get_rid()];shape_query.margin=.012
	return get_world_3d().direct_space_state.intersect_shape(shape_query,1).is_empty()

func begin_drive(player: Node3D) -> void:
	driver = player
	returning = false
	_speed = 0
	input_throttle = 0
	input_brake = 0
	input_steer = 0
	freeze = true
	player.supply_notice = "W/S row · A/D steer · E returns safely to the landing"
	player.supply_notice_remaining = 6

func allows_exit() -> bool:
	return at_dock() and is_instance_valid(driver) and _safe_dock_exit(driver)

func end_drive() -> Vector3:
	var exit: Vector3 = definition.get("exit", global_position + Vector3.UP)
	driver = null
	_speed = 0
	returning = false
	linear_velocity = Vector3.ZERO
	if not definition.is_empty(): settle_at(definition.pos, definition.yaw)
	return exit

func set_driver_view(_aim: Vector3, input: Dictionary) -> void:
	if bool(input.get("interact_just",false)) and not at_dock(): request_return()

func request_return() -> void:
	if returning: return
	returning = true
	_return_center = not _clear_water_segment(global_position,definition.pos)
	dock_returns += 1
	if is_instance_valid(driver):
		driver.supply_notice = "Returning to the landing · press E after docking to step ashore"
		driver.supply_notice_remaining = 6

func _clear_water_segment(start:Vector3,finish:Vector3)->bool:
	var direction:=Vector2(finish.x-start.x,finish.z-start.z)
	var basis:=Basis(Vector3.UP,atan2(direction.x,direction.y))
	for i in range(25):
		if not water_safe(start.lerp(finish,float(i)/24),basis): return false
	return true

func _physics_process(dt: float) -> void:
	_time += dt
	if remote_controlled:
		_advance_remote(dt)
		_animate_oars(dt, clampf(linear_velocity.length()/MAX_SPEED,0,1))
		return
	if not is_instance_valid(driver):
		linear_velocity = Vector3.ZERO
		_animate_oars(dt,0)
		return
	var old := global_position
	var heading := yaw_angle()
	if returning:
		var target: Vector2 = Plan.POND_CENTER if _return_center else Vector2(definition.pos.x,definition.pos.z)
		var point := Vector2(global_position.x,global_position.z)
		if point.distance_to(target) < 6 and _return_center:
			_return_center = false
			target = Vector2(definition.pos.x,definition.pos.z)
		if point.distance_to(target) < .65 and not _return_center:
			settle_at(definition.pos,definition.yaw)
			_speed = 0
			returning = false
			_animate_oars(dt,0)
			return
		var toward := (target-point).normalized()
		heading = lerp_angle(heading, atan2(toward.x,toward.y), minf(1,dt*2.0))
		_speed = move_toward(_speed,minf(MAX_SPEED,point.distance_to(target)*.8),dt*.9)
	else:
		var target_speed := input_throttle*MAX_SPEED-input_brake*REVERSE_SPEED
		_speed = move_toward(_speed,target_speed,dt*(1.2 if target_speed < _speed else .85))
		heading += input_steer*dt*.75
	var proposed:=Transform3D(Basis(Vector3.UP,heading),global_position)
	var motion:=proposed.basis.z*_speed*dt
	var next:=global_position+motion
	# Turning changes the complete hull even with no throttle. Validate the
	# candidate orientation before committing it, including overlap recovery.
	if not water_safe(next,proposed.basis) or test_move(proposed,motion,null,.001,true):
		safe_boundary_stops += 1
		_speed = 0
		motion = Vector3.ZERO
	else:
		global_basis = proposed.basis
	global_position += motion
	global_position.y = Plan.POND_SURFACE_Y+.10+sin(_time*1.15)*.012
	linear_velocity = (global_position-old)/maxf(dt,.001)
	_animate_oars(dt,absf(_speed)/MAX_SPEED)

static func water_safe(at: Vector3, basis: Basis) -> bool:
	for offset in [Vector3(0,0,2.7),Vector3(0,0,-2.7),Vector3(1,0,0),Vector3(-1,0,0)]:
		var point: Vector3 = at + basis*offset
		if Plan.pond_depth(Vector2(point.x,point.z)) < .52: return false
	return true

func _animate_oars(dt: float, effort: float) -> void:
	_oar_phase += dt*(1.0+effort*3.8)
	for index in range(_oars.size()):
		var side := -1.0 if index == 0 else 1.0
		_oars[index].rotation.y = side*(.16+sin(_oar_phase)*.30*effort)
		_oars[index].rotation.z = side*(.05+cos(_oar_phase)*.07*effort)

func _build_hull() -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("a17a48")
	wood.roughness = .7
	var trim := StandardMaterial3D.new()
	trim.albedo_color = Color("e4cf98")
	trim.roughness = .65
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color("234a4d")
	paint.roughness = .45
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := [Vector2(.74,-.20),Vector2(1.0,.26),Vector2(1.03,.40)]
	var segments := 24
	for ring in rings:
		for i in range(segments+1):
			var a := float(i)*TAU/segments
			var x: float = sin(a)*ring.x
			var z := cos(a)*2.7
			st.set_uv(Vector2(float(i)/segments,ring.y))
			st.add_vertex(Vector3(x,ring.y,z))
	for r in range(2):
		for i in range(segments):
			var a := r*(segments+1)+i
			for v in [a,a+1,a+segments+2,a,a+segments+2,a+segments+1]: st.add_index(v)
	st.generate_normals()
	var hull := MeshInstance3D.new()
	hull.mesh = st.commit()
	hull.material_override = paint
	paint.cull_mode = BaseMaterial3D.CULL_DISABLED
	hull.name = "PaintedTimberHull"
	add_child(hull)
	for i in range(7): _box(self,Vector3(-.72+i*.24,-.04,0),Vector3(.20,.10,4.0),wood)
	for z in [-1.45,-.35,1.25]: _box(self,Vector3(0,.39,z),Vector3(1.8,.14,.42),trim)
	for side in [-1.0,1.0]:
		var oar := Node3D.new()
		oar.position = Vector3(side*.9,.50,.05)
		add_child(oar)
		_oars.append(oar)
		_box(oar,Vector3(side*.4,0,0),Vector3(2.45,.075,.08),wood)
		_box(oar,Vector3(side*1.65,0,0),Vector3(.75,.045,.27),trim)
		add_rider_target(oar,&"hand_left" if side < 0 else &"hand_right",Vector3(-side*.43,.02,0))

func _box(parent: Node3D, at: Vector3, size: Vector3, material: Material) -> void:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = material
	node.position = at
	parent.add_child(node)
