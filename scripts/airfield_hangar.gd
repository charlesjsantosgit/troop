class_name AirfieldHangar
extends Node3D
## Streamed, open-front aircraft shelter for the seeded airfield. Each hangar
## batches its shell, frame, floor, and markings into four shared-material
## meshes and builds three wall colliders only while its chunk owns near-ring
## collision. Local -Z is the open door facing the runway.

static var _unit_box: BoxMesh
static var _shell_material: StandardMaterial3D
static var _frame_material: StandardMaterial3D
static var _floor_material: StandardMaterial3D
static var _marking_material: StandardMaterial3D

# The complete six-bay row spans 125 m. Keep every batched shell visible from a
# normal runway approach instead of letting the far bays vanish one by one.
const VISIBILITY_RANGE := 520.0

var hangar_id := ""
var hangar_index := 0
var hangar_size := Vector3(Gen.AIRSTRIP_HANGAR_WIDTH,
	Gen.AIRSTRIP_HANGAR_HEIGHT, Gen.AIRSTRIP_HANGAR_DEPTH)
var _collisions_built := false
var _collision_bodies: Array[StaticBody3D] = []


func configure(data: Dictionary) -> void:
	hangar_id = str(data.get("id", "h:strip#0"))
	hangar_index = int(data.get("index", 0))
	hangar_size = data.get("size", hangar_size)
	position = data.get("pos", Vector3.ZERO)
	rotation.y = float(data.get("yaw", 0.0))


func _ready() -> void:
	name = "AirfieldHangar_%d" % hangar_index
	_init_resources()
	_build_model()


## Hangar collision follows the same lazy broadphase policy as trees, supply
## huts, and arena cover. The open front remains unobstructed for taxiing.
func build_collisions() -> Array[StaticBody3D]:
	if _collisions_built:
		return _collision_bodies
	_collisions_built = true
	var body := StaticBody3D.new()
	body.name = "AirfieldHangarCollision_%d" % hangar_index
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)
	var wall_height := hangar_size.y - 1.45
	var wall_thickness := 0.34
	_add_box_collision(body,
		Vector3(wall_thickness, wall_height, hangar_size.z),
		Vector3(-hangar_size.x * 0.5, wall_height * 0.5, 0.0))
	_add_box_collision(body,
		Vector3(wall_thickness, wall_height, hangar_size.z),
		Vector3(hangar_size.x * 0.5, wall_height * 0.5, 0.0))
	_add_box_collision(body,
		Vector3(hangar_size.x, wall_height, wall_thickness),
		Vector3(0.0, wall_height * 0.5, hangar_size.z * 0.5))
	# Two thin pitched roof shapes keep an airborne or bouncing aircraft inside
	# the visible shell without putting any collider across the open threshold.
	var roof_rise := hangar_size.y - wall_height
	var half_span := hangar_size.x * 0.5
	var roof_angle := atan2(roof_rise, half_span)
	var roof_length := Vector2(half_span, roof_rise).length() + 0.45
	for side in [-1.0, 1.0]:
		_add_box_collision(body,
			Vector3(roof_length, 0.26, hangar_size.z + 0.35),
			Vector3(side * half_span * 0.5,
				wall_height + roof_rise * 0.5, 0.0),
			Vector3(0.0, 0.0, side * -roof_angle))
	_collision_bodies.append(body)
	return _collision_bodies


func _build_model() -> void:
	var wall_height := hangar_size.y - 1.45
	var wall_thickness := 0.28
	var roof_rise := hangar_size.y - wall_height
	var half_span := hangar_size.x * 0.5
	var roof_angle := atan2(roof_rise, half_span)
	var roof_length := Vector2(half_span, roof_rise).length() + 0.55

	var shell := SurfaceTool.new()
	shell.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_box(shell, Vector3(wall_thickness, wall_height, hangar_size.z),
		Vector3(-half_span, wall_height * 0.5, 0.0))
	_append_box(shell, Vector3(wall_thickness, wall_height, hangar_size.z),
		Vector3(half_span, wall_height * 0.5, 0.0))
	_append_box(shell, Vector3(hangar_size.x, wall_height, wall_thickness),
		Vector3(0.0, wall_height * 0.5, hangar_size.z * 0.5))
	for side in [-1.0, 1.0]:
		_append_box(shell,
			Vector3(roof_length, 0.24, hangar_size.z + 0.65),
			Vector3(side * half_span * 0.5,
				wall_height + roof_rise * 0.5, 0.0),
			Vector3(0.0, 0.0, side * -roof_angle))
	_add_mesh("CorrugatedShell", shell.commit(), _shell_material)

	# Front portal plus four interior ribs makes the open, shaded aircraft bay
	# readable even from the runway without adding one node per beam.
	var frame := SurfaceTool.new()
	frame.begin(Mesh.PRIMITIVE_TRIANGLES)
	for depth_fraction in [-0.49, -0.16, 0.17, 0.49]:
		var z := hangar_size.z * float(depth_fraction)
		for side in [-1.0, 1.0]:
			_append_box(frame, Vector3(0.34, wall_height, 0.34),
				Vector3(side * (half_span - 0.18), wall_height * 0.5, z))
		_append_box(frame, Vector3(hangar_size.x - 0.34, 0.30, 0.34),
			Vector3(0.0, wall_height - 0.12, z))
		for side in [-1.0, 1.0]:
			_append_box(frame,
				Vector3(roof_length - 0.20, 0.22, 0.30),
				Vector3(side * half_span * 0.5,
					wall_height + roof_rise * 0.5, z),
				Vector3(0.0, 0.0, side * -roof_angle))
	_add_mesh("StructuralFrame", frame.commit(), _frame_material)

	var floor_mesh := SurfaceTool.new()
	floor_mesh.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_box(floor_mesh,
		Vector3(hangar_size.x - 0.45, 0.10, hangar_size.z - 0.30),
		Vector3(0.0, 0.05, 0.0))
	_add_mesh("ConcreteFloor", floor_mesh.commit(), _floor_material, false)

	var markings := SurfaceTool.new()
	markings.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Taxi centreline leads the parked jet through the open door. Repeated
	# threshold bars and a bay-number tally keep all six garages distinct.
	_append_box(markings, Vector3(0.18, 0.018, hangar_size.z - 1.1),
		Vector3(0.0, 0.112, -0.25))
	for side in [-1.0, 1.0]:
		for stripe in range(4):
			_append_box(markings, Vector3(0.48, 0.025, 0.24),
				Vector3(side * (half_span - 0.60), 0.12,
					-hangar_size.z * 0.5 + 0.42 + float(stripe) * 0.48),
				Vector3(0.0, -0.42 * side, 0.0))
	for tally in range(hangar_index + 1):
		_append_box(markings, Vector3(0.20, 0.52, 0.035),
			Vector3((float(tally) - float(hangar_index) * 0.5) * 0.34,
				wall_height - 0.52, -hangar_size.z * 0.5 - 0.19))
	_add_mesh("TaxiMarkings", markings.commit(), _marking_material, false)


func _add_mesh(node_name: String, mesh: ArrayMesh, material: Material,
		cast_shadow := true) -> void:
	if not mesh:
		return
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
		if cast_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_end = VISIBILITY_RANGE
	instance.visibility_range_end_margin = 48.0
	instance.visibility_range_fade_mode = \
		GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(instance)


static func _append_box(surface: SurfaceTool, size: Vector3,
		local_position: Vector3, local_rotation := Vector3.ZERO) -> void:
	var basis := Basis.from_euler(local_rotation) * Basis.from_scale(size)
	surface.append_from(_unit_box, 0, Transform3D(basis, local_position))


static func _add_box_collision(body: StaticBody3D, size: Vector3,
		local_position: Vector3, local_rotation := Vector3.ZERO) -> void:
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	collision.position = local_position
	collision.rotation = local_rotation
	body.add_child(collision)


static func _init_resources() -> void:
	if _unit_box:
		return
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE
	_shell_material = _material(Color(0.31, 0.35, 0.37), 0.68,
		Color(0.015, 0.020, 0.022), 0.10)
	_frame_material = _material(Color(0.105, 0.125, 0.135), 0.48)
	_floor_material = _material(Color(0.30, 0.31, 0.29), 0.92)
	_marking_material = _material(Color(0.96, 0.67, 0.08), 0.62,
		Color(0.55, 0.26, 0.015), 0.34)


static func _material(color: Color, roughness: float,
		emission := Color.BLACK, emission_energy := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = 0.22
	if emission_energy > 0.0:
		material.emission_enabled = true
		material.emission = emission
		material.emission_energy_multiplier = emission_energy
	return material
