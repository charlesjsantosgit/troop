class_name FrontierProps
extends RefCounted
## Settlement construction uses shared primitive meshes and batches by material.
## A village with hundreds of boards, roof ribs and crop leaves stays a small
## set of render submissions. Collision only exists on substantial structures.

static var _meshes: Dictionary = {}
static var _materials: Dictionary = {}
var parent: Node3D
var frame := Transform3D.IDENTITY
var _batches: Dictionary = {}
var _body: StaticBody3D


func _init(target: Node3D) -> void:
	parent = target
	_body = StaticBody3D.new()
	_body.name = "SettlementCollision"
	_body.collision_layer = 1
	_body.collision_mask = 0
	parent.add_child(_body)


static func material(color: Color, metal := 0.0, glow := 0.0) -> StandardMaterial3D:
	var key := "%s/%.2f/%.2f" % [color.to_html(), metal, glow]
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.83 if metal < 0.1 else 0.43
		mat.metallic = metal
		if color.a < 0.999:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.roughness = 0.25
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		if glow > 0.0:
			mat.emission_enabled = true
			mat.emission = color
			mat.emission_energy_multiplier = glow
		_materials[key] = mat
	return _materials[key]


static func mesh_for(shape: String) -> Mesh:
	if not _meshes.has(shape):
		match shape:
			"box":
				_meshes[shape] = BoxMesh.new()
			"sphere":
				var sphere := SphereMesh.new()
				sphere.radius = 0.5
				sphere.height = 1.0
				sphere.radial_segments = 10
				sphere.rings = 5
				_meshes[shape] = sphere
			_:
				var cylinder := CylinderMesh.new()
				cylinder.top_radius = 0.0 if shape == "cone" else 0.5
				cylinder.bottom_radius = 0.5
				cylinder.height = 1.0
				cylinder.radial_segments = 12
				_meshes[shape] = cylinder
	return _meshes[shape]


func piece(shape: String, at: Vector3, size: Vector3, color: Color,
		euler := Vector3.ZERO, metal := 0.0, glow := 0.0) -> void:
	var mat := material(color, metal, glow)
	var key := "%s:%s" % [shape, mat.get_instance_id()]
	if not _batches.has(key):
		_batches[key] = {"mesh": mesh_for(shape), "material": mat, "transforms": []}
	var basis := Basis.from_euler(euler).scaled_local(size)
	_batches[key].transforms.append(frame * Transform3D(basis, at))


func box(at: Vector3, size: Vector3, color: Color,
		collision := false, euler := Vector3.ZERO, metal := 0.0) -> void:
	piece("box", at, size, color, euler, metal)
	if collision:
		var shape := BoxShape3D.new()
		shape.size = size
		_collide(shape, at, euler)


func cylinder(at: Vector3, radius: float, height: float, color: Color,
		collision := false, euler := Vector3.ZERO, metal := 0.0) -> void:
	piece("cylinder", at, Vector3(radius * 2.0, height, radius * 2.0), color, euler, metal)
	if collision:
		var shape := CylinderShape3D.new()
		shape.radius = radius
		shape.height = height
		_collide(shape, at, euler)


func beam(from: Vector3, to: Vector3, width: float, color: Color) -> void:
	var delta := to - from
	if delta.length_squared() < 0.0001:
		return
	var rotation := Quaternion(Vector3.UP, delta.normalized())
	piece("cylinder", (from + to) * 0.5,
		Vector3(width, delta.length(), width), color, rotation.get_euler())


func text(at: Vector3, value: String, color := Color(0.98, 0.91, 0.72),
		size := 38, distance := 45.0) -> Label3D:
	var label := Label3D.new()
	label.text = value
	label.font_size = size
	label.pixel_size = 0.013
	label.modulate = color
	label.outline_size = 7
	label.outline_modulate = Color(0.055, 0.075, 0.075, 0.92)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = frame * at
	label.no_depth_test = false
	label.visibility_range_end = distance
	label.visibility_range_end_margin = 4.0
	parent.add_child(label)
	return label


func dynamic_piece(shape: String, at: Vector3, size: Vector3,
		color: Color, owner: Node3D = null) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh_for(shape)
	node.material_override = material(color)
	node.position = at
	node.scale = size
	node.visibility_range_end = 160.0
	(owner if owner != null else parent).add_child(node)
	return node


func flush() -> void:
	for key in _batches:
		var data: Dictionary = _batches[key]
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = data.mesh
		multi.instance_count = data.transforms.size()
		for index in range(multi.instance_count):
			multi.set_instance_transform(index, data.transforms[index])
		var node := MultiMeshInstance3D.new()
		node.name = "SettlementBatch_%s" % key.replace(":", "_")
		node.multimesh = multi
		node.material_override = data.material
		node.visibility_range_end = 520.0
		parent.add_child(node)
	_batches.clear()


func _collide(shape: Shape3D, at: Vector3, euler: Vector3) -> void:
	var node := CollisionShape3D.new()
	node.shape = shape
	node.transform = frame * Transform3D(Basis.from_euler(euler), at)
	_body.add_child(node)
