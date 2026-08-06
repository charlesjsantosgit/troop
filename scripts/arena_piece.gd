class_name ArenaPiece
extends Node3D
## Lightweight authored cover used by the origin duel arena. Each piece commits
## its decorative parts into one mesh and exposes one small collision body, so
## the denser combat space stays inexpensive to stream and render.

static var _unit_box: BoxMesh
static var _unit_log: CylinderMesh
static var _unit_spike: CylinderMesh
static var _wood: StandardMaterial3D
static var _wood_dark: StandardMaterial3D
static var _accent: StandardMaterial3D

var piece_id := ""
var kind := "barricade"
var piece_size := Vector3(5.0, 1.25, 0.72)
var _collisions_built := false
var _collision_bodies: Array[StaticBody3D] = []


func configure(data: Dictionary) -> void:
	piece_id = str(data.get("id", "arena_piece"))
	kind = str(data.get("kind", "barricade"))
	piece_size = data.get("size", Vector3(5.0, 1.25, 0.72))
	position = data.get("pos", Vector3.ZERO)
	rotation.y = float(data.get("yaw", 0.0))


func _ready() -> void:
	name = "Arena_%s" % piece_id.replace(":", "_")
	_init_resources()
	match kind:
		"palisade":
			_build_palisade()
		"platform":
			_build_platform()
		_:
			_build_barricade()


## Chunk owns collision activation for every streamed prop. Keeping the body
## below this rotated node also makes a single local box accurately follow yaw.
func build_collisions() -> Array[StaticBody3D]:
	if _collisions_built:
		return _collision_bodies
	_collisions_built = true
	var body := StaticBody3D.new()
	body.name = "ArenaCollision_%s" % piece_id
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)
	match kind:
		"platform":
			_add_box_collision(body, Vector3(piece_size.x, 0.66, piece_size.z),
				Vector3(0.0, 0.33, 0.0))
			# Three broad steps make both flank decks usable from the lane without
			# requiring finicky edge jumps.
			_add_box_collision(body, Vector3(piece_size.x * 0.64, 0.18, 0.72),
				Vector3(0.0, 0.09, piece_size.z * 0.72))
			_add_box_collision(body, Vector3(piece_size.x * 0.64, 0.34, 0.68),
				Vector3(0.0, 0.17, piece_size.z * 0.52))
			_add_box_collision(body, Vector3(piece_size.x * 0.64, 0.46, 0.64),
				Vector3(0.0, 0.23, piece_size.z * 0.34))
			# Rear rail doubles as chest-high firing cover on the elevated side.
			_add_box_collision(body,
				Vector3(piece_size.x, 0.82, 0.20),
				Vector3(0.0, 0.93, -piece_size.z * 0.43))
		"palisade":
			_add_box_collision(body, piece_size,
				Vector3(0.0, piece_size.y * 0.5, 0.0))
		_:
			_add_box_collision(body, piece_size,
				Vector3(0.0, piece_size.y * 0.5, 0.0))
	_collision_bodies.append(body)
	return _collision_bodies


func _build_barricade() -> void:
	var wood := SurfaceTool.new()
	wood.begin(Mesh.PRIMITIVE_TRIANGLES)
	var radius := minf(piece_size.z * 0.39, 0.26)
	for row in range(3):
		_append_cylinder(wood, radius, piece_size.x,
			Vector3(0.0, radius + float(row) * radius * 1.62, 0.0),
			Vector3(0.0, 0.0, PI * 0.5))
	# Upright stakes and short feet give the cover a deliberately constructed,
	# arena-ready silhouette instead of reading as a random fallen tree.
	for x in [-piece_size.x * 0.43, piece_size.x * 0.43]:
		_append_cylinder(wood, radius * 0.68, piece_size.y + 0.34,
			Vector3(x, (piece_size.y + 0.34) * 0.5, 0.02))
		_append_box(wood, Vector3(0.22, 0.18, piece_size.z * 1.75),
			Vector3(x, 0.10, 0.12))
	_add_mesh("LogBarricade", wood.commit(), _wood)

	var ties := SurfaceTool.new()
	ties.begin(Mesh.PRIMITIVE_TRIANGLES)
	for x in [-piece_size.x * 0.32, piece_size.x * 0.32]:
		_append_box(ties, Vector3(0.08, piece_size.y * 0.92, piece_size.z * 1.04),
			Vector3(x, piece_size.y * 0.48, 0.0), Vector3(0.08, 0.0, 0.0))
	_add_mesh("VineTies", ties.commit(), _accent, false)


func _build_palisade() -> void:
	var wood := SurfaceTool.new()
	wood.begin(Mesh.PRIMITIVE_TRIANGLES)
	var post_count := maxi(5, roundi(piece_size.x / 0.86))
	var spacing := piece_size.x / float(post_count)
	for i in range(post_count):
		var x := -piece_size.x * 0.5 + spacing * (float(i) + 0.5)
		var height_jitter := 0.10 if i % 2 == 0 else -0.04
		var post_height := piece_size.y + height_jitter
		_append_cylinder(wood, piece_size.z * 0.42, post_height,
			Vector3(x, post_height * 0.5, 0.0))
		_append_spike(wood, piece_size.z * 0.47, 0.34,
			Vector3(x, post_height + 0.17, 0.0))
	_append_cylinder(wood, 0.10, piece_size.x * 0.96,
		Vector3(0.0, piece_size.y * 0.48, piece_size.z * 0.30),
		Vector3(0.0, 0.0, PI * 0.5))
	_add_mesh("Palisade", wood.commit(), _wood_dark)

	var marker := SurfaceTool.new()
	marker.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_box(marker, Vector3(piece_size.x * 0.34, 0.14, 0.08),
		Vector3(0.0, piece_size.y * 0.73, -piece_size.z * 0.51))
	_add_mesh("ArenaMarker", marker.commit(), _accent, false)


func _build_platform() -> void:
	var wood := SurfaceTool.new()
	wood.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_box(wood, Vector3(piece_size.x, 0.18, piece_size.z),
		Vector3(0.0, 0.57, 0.0))
	for x in [-piece_size.x * 0.43, piece_size.x * 0.43]:
		for z in [-piece_size.z * 0.38, piece_size.z * 0.38]:
			_append_cylinder(wood, 0.15, 0.58, Vector3(x, 0.29, z))
	# Wide, shallow approach steps preserve the fast movement flow.
	_append_box(wood, Vector3(piece_size.x * 0.64, 0.18, 0.72),
		Vector3(0.0, 0.09, piece_size.z * 0.72))
	_append_box(wood, Vector3(piece_size.x * 0.64, 0.18, 0.68),
		Vector3(0.0, 0.25, piece_size.z * 0.52))
	_append_box(wood, Vector3(piece_size.x * 0.64, 0.16, 0.64),
		Vector3(0.0, 0.46, piece_size.z * 0.34))
	# Rear firing rail: open sides keep this a flank position, not a bunker.
	_append_box(wood, Vector3(piece_size.x, 0.20, 0.20),
		Vector3(0.0, 1.31, -piece_size.z * 0.43))
	for x in [-piece_size.x * 0.45, piece_size.x * 0.45]:
		_append_cylinder(wood, 0.10, 0.77,
			Vector3(x, 0.95, -piece_size.z * 0.43))
	_add_mesh("FlankDeck", wood.commit(), _wood)

	var stripe := SurfaceTool.new()
	stripe.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_box(stripe, Vector3(piece_size.x * 0.55, 0.12, 0.055),
		Vector3(0.0, 1.31, -piece_size.z * 0.55))
	_add_mesh("DuelStripe", stripe.commit(), _accent, false)


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
	instance.visibility_range_end = 96.0
	instance.visibility_range_end_margin = 12.0
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(instance)


static func _append_box(surface: SurfaceTool, size: Vector3,
		local_position: Vector3, local_rotation := Vector3.ZERO) -> void:
	# Scale in mesh-local space, then rotate. Basis.scaled() applies scale in
	# parent axes, which would turn rotated horizontal logs into thin posts.
	var basis := Basis.from_euler(local_rotation) * Basis.from_scale(size)
	surface.append_from(_unit_box, 0, Transform3D(basis, local_position))


static func _append_cylinder(surface: SurfaceTool, radius: float, height: float,
		local_position: Vector3, local_rotation := Vector3.ZERO) -> void:
	var scale_v := Vector3(radius * 2.0, height, radius * 2.0)
	var basis := Basis.from_euler(local_rotation) * Basis.from_scale(scale_v)
	surface.append_from(_unit_log, 0, Transform3D(basis, local_position))


static func _append_spike(surface: SurfaceTool, radius: float, height: float,
		local_position: Vector3) -> void:
	var basis := Basis.IDENTITY.scaled(Vector3(radius * 2.0, height,
		radius * 2.0))
	surface.append_from(_unit_spike, 0, Transform3D(basis, local_position))


static func _add_box_collision(body: StaticBody3D, size: Vector3,
		local_position: Vector3) -> void:
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	collision.position = local_position
	body.add_child(collision)


static func _init_resources() -> void:
	if _unit_box:
		return
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE
	_unit_log = CylinderMesh.new()
	_unit_log.top_radius = 0.5
	_unit_log.bottom_radius = 0.5
	_unit_log.height = 1.0
	_unit_log.radial_segments = 7
	_unit_spike = CylinderMesh.new()
	_unit_spike.top_radius = 0.0
	_unit_spike.bottom_radius = 0.5
	_unit_spike.height = 1.0
	_unit_spike.radial_segments = 7
	_wood = _material(Color(0.41, 0.24, 0.085), 0.88)
	_wood_dark = _material(Color(0.23, 0.105, 0.035), 0.92)
	_accent = _material(Color(0.78, 0.88, 0.20), 0.82,
		Color(0.26, 0.42, 0.035), 0.38)


static func _material(color: Color, roughness: float,
		emission := Color.BLACK, emission_energy := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	if emission_energy > 0.0:
		material.emission_enabled = true
		material.emission = emission
		material.emission_energy_multiplier = emission_energy
	return material
