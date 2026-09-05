extends Node3D
## Nearby census representatives, never 400,000 live rigs. These ambient actors
## do not grant goods or rewards; economic work stays in the authority model.
const Plan = preload("res://scripts/city_plan.gd")
const MAX_PEDESTRIANS := 16
const MAX_CARS := 4
const RETIRE_DISTANCE := 260.0
var focus := Vector3.INF
var _cohort := Vector2i(99999, 99999)
var _queue: Array = []
var actors: Array[CharacterBody3D] = []
var _spawn_clock := 0.0

func update_focus(point: Vector3) -> void:
	focus = point
	if not Plan.contains(Vector2(point.x, point.z)) or point.y < 0.0:
		_queue.clear()
		for actor in actors: actor.queue_free()
		actors.clear()
		_cohort = Vector2i(99999, 99999)
		return
	var cell := Vector2i(floori((point.x - Plan.MIN_X) / 120.0), floori((point.z - Plan.MIN_Z) / 120.0))
	if cell == _cohort: return
	_cohort = cell
	_queue.clear()
	for actor in actors.duplicate():
		if actor.position.distance_to(point) > RETIRE_DISTANCE:
			actors.erase(actor)
			actor.queue_free()
	for index in range(MAX_PEDESTRIANS + MAX_CARS):
		var car := index >= MAX_PEDESTRIANS
		var offset := Vector2i((index % 4) - 1, ((index / 4) % 3) - 1)
		var origin := Vector2(Plan.MIN_X, Plan.MIN_Z) + Vector2(cell + offset) * 120.0
		if not Plan.contains(origin + Vector2(60, 60)): continue
		if car and (origin + Vector2(60, 60)).distance_to(Plan.CENTER) < 180.0: continue
		_queue.append({"origin": origin, "car": car, "index": index})

func _process(delta: float) -> void:
	_spawn_clock -= delta
	if _spawn_clock > 0.0 or _queue.is_empty(): return
	_spawn_clock = 0.08
	var entry: Dictionary = _queue.pop_front()
	var count := 0
	for actor in actors:
		if actor.car == entry.car: count += 1
	if count >= (MAX_CARS if entry.car else MAX_PEDESTRIANS): return
	var actor := StreetActor.new()
	actor.car = entry.car
	actor.serial = entry.index + _cohort.x * 731 + _cohort.y * 41
	actor.path = _path(entry.origin, entry.car)
	var nearest := 0
	var distance := INF
	for index in range(actor.path.size()):
		var candidate := actor.path[index].distance_squared_to(focus)
		if candidate < distance:
			distance = candidate
			nearest = index
	actor.target = posmod(nearest + (int(entry.index) / 12) * 4, actor.path.size())
	actor.position = actor.path[actor.target]
	actor.target = (actor.target + 1) % actor.path.size()
	for existing in actors:
		if existing.position.distance_to(actor.position) < (7.0 if actor.car else 2.0):
			actor.free()
			return
	add_child(actor)
	actors.append(actor)
	actor.build()

static func _path(origin: Vector2, car: bool) -> PackedVector3Array:
	var result := PackedVector3Array()
	var inset := 3.5 if car else 12.0
	var radius := 12.0 if car else 3.0
	var a := origin + Vector2(inset, inset)
	var b := origin + Vector2(120 + inset, 120 + inset) if car else origin + Vector2(120 - inset, 120 - inset)
	var centers := [Vector2(a.x + radius, a.y + radius), Vector2(b.x - radius, a.y + radius),
		Vector2(b.x - radius, b.y - radius), Vector2(a.x + radius, b.y - radius)]
	for corner in range(4):
		for step in range(7):
			var angle := PI + corner * PI * 0.5 + (step / 6.0) * PI * 0.5
			var p: Vector2 = centers[corner] + Vector2(cos(angle), sin(angle)) * radius
			result.append(Vector3(p.x, Plan.GROUND_Y + 0.03, p.y))
	return result

class StreetActor extends CharacterBody3D:
	var car := false
	var serial := 0
	var path := PackedVector3Array()
	var target := 0
	var rig: MonkeyRig
	var speed := 0.0
	var blocked := 0.0
	var _phase := 0.0
	var _wheels: Array[Node3D] = []

	func build() -> void:
		collision_layer = 1
		collision_mask = 1
		safe_margin = 0.005
		var shape := CollisionShape3D.new()
		if car:
			var box := BoxShape3D.new()
			box.size = Vector3(1.85, 1.25, 4.1)
			shape.shape = box
			shape.position.y = 0.8
			_build_car()
		else:
			var capsule := CapsuleShape3D.new()
			capsule.radius = 0.34
			capsule.height = MonkeyRig.npc_height(str(serial))
			shape.shape = capsule
			shape.position.y = capsule.height * 0.5
		add_child(shape)
		rig = MonkeyRig.new()
		add_child(rig)
		rig.setup("Resident " + str(absi(serial)), false)
		rig.set_standing_height(MonkeyRig.npc_height(str(serial)))
		rig.set_melee_pose(false, false, 0.0, 0)
		if car: rig.position = Vector3(-0.42, 0.5, -0.3)
		_phase = float(posmod(serial, 40))

	func _physics_process(delta: float) -> void:
		if path.is_empty() or rig == null: return
		_phase += delta
		var to := path[target] - position
		to.y = 0.0
		if to.length() < (1.4 if car else 0.55):
			target = (target + 1) % path.size()
			to = path[target] - position
			to.y = 0.0
		var desired := 9.0 if car else 1.25 + float(posmod(serial, 5)) * 0.13
		var direction := to.normalized()
		# Timed stop-line pauses, braking sweeps and physical sweeps prevent cars
		# from phasing through residents or queued traffic.
		if car:
			var near_corner := target % 7 <= 2
			if near_corner and fposmod(_phase, 18.0) < 4.0: desired = 0.0
			if test_move(global_transform, direction * (2.0 + speed * 0.6)): desired = 0.0
		else:
			if fposmod(_phase, 35.0) < 1.5: desired = 0.0
		speed = move_toward(speed, desired, (6.0 if desired < speed else 2.5) * delta)
		var before := position
		var motion := direction * speed * delta
		var hit := move_and_collide(motion)
		if hit != null:
			speed = 0.0
			if not car: move_and_collide(hit.get_remainder().slide(hit.get_normal()))
		var actual := (position - before) / maxf(delta, 0.001)
		if actual.length_squared() > 0.01:
			var heading := atan2(-actual.x, -actual.z)
			if car: rotation.y = lerp_angle(rotation.y, heading, minf(4.0 * delta, 1.0))
			else: rig.set_yaw(lerp_angle(rig.yaw_node.rotation.y, heading, minf(7.0 * delta, 1.0)))
		rig.update_motion(delta, MonkeyRig.Anim.RIDE if car else MonkeyRig.Anim.RUN \
			if actual.length_squared() > 0.05 else MonkeyRig.Anim.IDLE, actual, true, Vector3.ZERO)
		for wheel in _wheels: wheel.rotate_x(speed * delta / 0.34)

	func _build_car() -> void:
		var color: Color = [Color("cf925a"), Color("59728a"), Color("ded3bb"), Color("748375")][posmod(serial, 4)]
		_part(Vector3(1.8, 0.6, 3.9), Vector3(0, 0.65, 0), color)
		_part(Vector3(1.65, 0.17, 1.9), Vector3(0, 1.7, 0.1), color)
		_part(Vector3(1.7, 0.4, 0.15), Vector3(0, 1.42, 1.0), color)
		for x in [-0.76, 0.76]:
			for z in [-0.8, 1.0]: _part(Vector3(0.09, 0.85, 0.1), Vector3(x, 1.25, z), color)
		for x in [-0.94, 0.94]:
			for z in [-1.2, 1.2]:
				var axle := Node3D.new()
				axle.position = Vector3(x, 0.38, z)
				add_child(axle)
				var tire := MeshInstance3D.new()
				var cylinder := CylinderMesh.new()
				cylinder.top_radius = 0.325
				cylinder.bottom_radius = 0.325
				cylinder.height = 0.22
				cylinder.radial_segments = 16
				tire.mesh = cylinder
				tire.rotation.z = PI * 0.5
				var rubber := StandardMaterial3D.new()
				rubber.albedo_color = Color("242930")
				tire.material_override = rubber
				axle.add_child(tire)
				_wheels.append(axle)
		for x in [-0.62, 0.62]:
			_part(Vector3(0.4, 0.15, 0.07), Vector3(x, 0.82, -1.98), Color("fff2b7"))
			_part(Vector3(0.3, 0.13, 0.07), Vector3(x, 0.82, 1.98), Color("b34d3e"))

	func _part(size: Vector3, at: Vector3, color: Color) -> MeshInstance3D:
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mesh.mesh = box
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.7
		mesh.material_override = material
		mesh.position = at
		add_child(mesh)
		return mesh
