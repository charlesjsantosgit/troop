class_name Banana
extends Area3D
## Spinning collectible. Pickup is authoritative-by-consensus: the collecting
## client broadcasts, everyone hides it, collector's score increments.

var id := ""
var _t := randf() * TAU
var _base_y := 0.0
static var _shared_mesh: ArrayMesh
static var _shared_shape: SphereShape3D


func setup(bid: String, pos: Vector3) -> void:
	id = bid
	position = pos
	_base_y = pos.y


func _ready() -> void:
	var cs := CollisionShape3D.new()
	if not _shared_shape:
		_shared_shape = SphereShape3D.new()
		_shared_shape.radius = 0.9
	cs.shape = _shared_shape
	add_child(cs)

	var mat := Visuals.banana_material()
	if not _shared_mesh:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for k in range(3):
			var sm := SphereMesh.new()
			sm.radius = 0.11
			sm.height = 0.34
			sm.radial_segments = 6
			sm.rings = 4
			var a := (float(k) - 1.0) * 0.32
			var basis := Basis(Vector3.FORWARD, -a)
			var banana_pos := Vector3(sin(a) * 0.16, cos(a) * 0.05, 0)
			st.append_from(sm, 0, Transform3D(basis, banana_pos))
		_shared_mesh = st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = _shared_mesh
	mi.material_override = mat
	mi.visibility_range_end = 72.0
	mi.visibility_range_end_margin = 12.0
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mi)

	body_entered.connect(_on_body)


func _process(dt: float) -> void:
	_t += dt
	rotation.y = _t * 2.2
	position.y = _base_y + sin(_t * 2.0) * 0.18


func _on_body(body: Node3D) -> void:
	if body is MonkeyPlayer and body.is_local:
		Net.try_collect(id)
