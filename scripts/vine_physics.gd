class_name VinePhysics
extends Node3D
## A released vine that keeps the shape and velocity it had in the monkey's
## hands. The top point stays fixed while the remaining verlet chain swings,
## damps naturally, and eventually hands rendering back to the chunk mesh.

signal finished(vine_id: String, simulation: VinePhysics)

const TARGET_SEGMENT := 0.55
const MIN_SEGMENTS := 8
const MAX_SEGMENTS := 32
const SUBSTEPS := 2
const SOLVER_PASSES := 8
const GRAVITY := Vector3(0, -20.0, 0)
const AIR_DAMPING := 0.994
const SETTLE_SPEED := 0.12
const SETTLE_DELAY := 5.0
const SETTLE_HOLD := 1.2

var vine_id := ""
var anchor := Vector3.ZERO
var vine_length := 0.0
var points := PackedVector3Array()
var previous := PackedVector3Array()
var rest_lengths := PackedFloat32Array()

var _mesh_instance: MeshInstance3D
var _mesh := ImmediateMesh.new()
var _material: Material
var _age := 0.0
var _quiet_time := 0.0
var _done := false


func setup(id: String, at: Vector3, length: float, shape: PackedVector3Array,
		release_velocity: Vector3) -> void:
	vine_id = id
	anchor = at
	vine_length = length

	_material = Visuals.vine_material(0.0)
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = _mesh
	_mesh_instance.material_override = _material
	add_child(_mesh_instance)

	var path := shape
	if path.size() < 2:
		path = PackedVector3Array([anchor, anchor + Vector3.DOWN * vine_length])
	else:
		path[0] = anchor
	var segment_count := clampi(ceili(vine_length / TARGET_SEGMENT), MIN_SEGMENTS, MAX_SEGMENTS)
	points = _resample(path, segment_count + 1)
	previous.resize(points.size())
	rest_lengths.resize(segment_count)
	for i in range(segment_count):
		rest_lengths[i] = vine_length / float(segment_count)
	for i in range(points.size()):
		# The anchor is still; velocity grows down the strand until the free end
		# carries nearly all of the monkey's release momentum.
		var influence := pow(float(i) / float(segment_count), 0.75)
		previous[i] = points[i] - release_velocity * influence / 60.0
	previous[0] = anchor
	points[0] = anchor

	Gen.start_vine_simulation(vine_id, points)
	_draw()


func cancel() -> void:
	if _done:
		return
	_done = true
	finished.emit(vine_id, self)
	queue_free()


func _physics_process(dt: float) -> void:
	if _done:
		return
	if not Gen.vines.has(vine_id):
		cancel()
		return
	var vine: Dictionary = Gen.vines[vine_id]
	if bool(vine.get("hidden", false)) or not bool(vine.get("simulated", false)):
		cancel()
		return

	var step_dt := minf(dt, 1.0 / 30.0) / float(SUBSTEPS)
	for substep in range(SUBSTEPS):
		_integrate(step_dt)
		for pass_i in range(SOLVER_PASSES):
			_solve_lengths()
	_age += dt
	Gen.update_vine_simulation(vine_id, points)
	_draw()

	var max_speed := 0.0
	for i in range(1, points.size()):
		max_speed = maxf(max_speed, points[i].distance_to(previous[i]) / maxf(step_dt, 0.0001))
	if _age >= SETTLE_DELAY and max_speed < SETTLE_SPEED:
		_quiet_time += dt
	else:
		_quiet_time = 0.0
	if _quiet_time >= SETTLE_HOLD:
		_done = true
		Gen.stop_vine_simulation(vine_id)
		finished.emit(vine_id, self)
		queue_free()


func _integrate(dt: float) -> void:
	points[0] = anchor
	previous[0] = anchor
	var accel := GRAVITY * dt * dt
	for i in range(1, points.size()):
		var current := points[i]
		var velocity := (current - previous[i]) * AIR_DAMPING
		previous[i] = current
		points[i] = current + velocity + accel


func _solve_lengths() -> void:
	points[0] = anchor
	for i in range(rest_lengths.size()):
		var delta := points[i + 1] - points[i]
		var distance := delta.length()
		if distance < 0.0001:
			continue
		var error := (distance - rest_lengths[i]) / distance
		if i == 0:
			points[i + 1] -= delta * error
		else:
			var correction := delta * error * 0.5
			points[i] += correction
			points[i + 1] -= correction
	points[0] = anchor


func _resample(path: PackedVector3Array, count: int) -> PackedVector3Array:
	var cumulative := PackedFloat32Array([0.0])
	var path_length := 0.0
	for i in range(path.size() - 1):
		path_length += path[i].distance_to(path[i + 1])
		cumulative.append(path_length)
	if path_length < 0.001:
		path = PackedVector3Array([anchor, anchor + Vector3.DOWN * vine_length])
		path_length = vine_length
		cumulative = PackedFloat32Array([0.0, path_length])

	var out := PackedVector3Array()
	for i in range(count):
		var target := path_length * float(i) / float(count - 1)
		var p := path[path.size() - 1]
		for j in range(path.size() - 1):
			if target <= cumulative[j + 1]:
				var span := maxf(cumulative[j + 1] - cumulative[j], 0.0001)
				p = path[j].lerp(path[j + 1], (target - cumulative[j]) / span)
				break
		out.append(p)
	out[0] = anchor
	return out


func _draw() -> void:
	_mesh.clear_surfaces()
	if points.size() < 2:
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _material)
	var top_color := Color(0.24, 0.32, 0.12)
	var bottom_color := Color(0.32, 0.42, 0.14)
	for i in range(points.size() - 1):
		var t0 := float(i) / float(points.size() - 1)
		var t1 := float(i + 1) / float(points.size() - 1)
		_rope_segment(points[i], points[i + 1], 0.045,
			top_color.lerp(bottom_color, t0), top_color.lerp(bottom_color, t1))
	var tip := points[points.size() - 1]
	var tip_color := Color(0.5, 0.72, 0.25)
	_rope_segment(tip + Vector3(0.14, 0.2, 0), tip + Vector3(-0.14, -0.1, 0), 0.1,
		tip_color, tip_color)
	_rope_segment(tip + Vector3(0, 0.2, 0.14), tip + Vector3(0, -0.1, -0.14), 0.1,
		tip_color, tip_color)
	_mesh.surface_end()


func _rope_segment(a: Vector3, b: Vector3, width: float, ca: Color, cb: Color) -> void:
	var direction := b - a
	if direction.length() < 0.001:
		return
	direction = direction.normalized()
	var side := direction.cross(Vector3.UP)
	if side.length() < 0.1:
		side = direction.cross(Vector3.RIGHT)
	side = side.normalized() * width
	var side2 := direction.cross(side).normalized() * width
	for offset in [side, side2]:
		_mesh.surface_set_color(ca)
		_mesh.surface_add_vertex(a - offset)
		_mesh.surface_set_color(ca)
		_mesh.surface_add_vertex(a + offset)
		_mesh.surface_set_color(cb)
		_mesh.surface_add_vertex(b + offset)
		_mesh.surface_set_color(ca)
		_mesh.surface_add_vertex(a - offset)
		_mesh.surface_set_color(cb)
		_mesh.surface_add_vertex(b + offset)
		_mesh.surface_set_color(cb)
		_mesh.surface_add_vertex(b - offset)
