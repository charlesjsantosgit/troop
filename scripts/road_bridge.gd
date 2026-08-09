class_name RoadBridge
extends Node3D
## Bounded streamed bridge used where an organic arterial crosses a narrow lake
## or inlet. Deck, rails, piers and markings are four batched meshes; collision
## activates only with the owning near chunk.

static var _deck_material: StandardMaterial3D
static var _rail_material: StandardMaterial3D
static var _pier_material: StandardMaterial3D
static var _marking_material: StandardMaterial3D

var bridge_id := ""
var bridge_length := 72.0
var bridge_width := 14.4
var clearance_height := 5.2
var _collisions_built := false
var _collision_bodies: Array[StaticBody3D] = []


func configure(data: Dictionary) -> void:
	bridge_id = str(data.get("id", "road:bridge"))
	bridge_length = float(data.get("length", bridge_length))
	bridge_width = float(data.get("width", bridge_width))
	clearance_height = float(data.get("clearance_height", clearance_height))
	position = data.get("pos", Vector3.ZERO)
	rotation.y = float(data.get("yaw", 0.0))


func _ready() -> void:
	name = "RoadBridge_%s" % bridge_id.replace(":", "_")
	_ensure_materials()
	_build_model()


func build_collisions() -> Array[StaticBody3D]:
	if _collisions_built:
		return _collision_bodies
	_collisions_built = true
	var body := StaticBody3D.new()
	body.name = "RoadBridgeCollision"
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)
	_add_box_collision(body, Vector3(bridge_width, 0.52, bridge_length),
		Vector3(0.0, -0.26, 0.0))
	for side in [-1.0, 1.0]:
		_add_box_collision(body, Vector3(0.24, 0.78, bridge_length),
			Vector3(side * (bridge_width * 0.5 - 0.13), 0.25, 0.0))
	_collision_bodies.append(body)
	return _collision_bodies


func _build_model() -> void:
	var half_width := bridge_width * 0.5
	var deck := SurfaceTool.new()
	deck.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_box(deck, Vector3(bridge_width, 0.52, bridge_length),
		Vector3(0.0, -0.26, 0.0))
	# Tapered approach lips hide the terrain/deck seam at both endpoints.
	for end_sign in [-1.0, 1.0]:
		_append_box(deck, Vector3(bridge_width + 1.2, 0.22, 4.0),
			Vector3(0.0, -0.18,
				end_sign * (bridge_length * 0.5 + 1.7)))
	deck.generate_normals()
	_add_mesh("BatchedBridgeDeck", deck.commit(), _deck_material)

	var rails := SurfaceTool.new()
	rails.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		_append_box(rails, Vector3(0.18, 0.18, bridge_length),
			Vector3(side * (half_width - 0.18), 0.72, 0.0))
		for z_index in range(-3, 4):
			_append_box(rails, Vector3(0.20, 0.92, 0.20),
				Vector3(side * (half_width - 0.18), 0.30,
					float(z_index) * bridge_length / 7.0))
	rails.generate_normals()
	_add_mesh("BatchedSafetyRails", rails.commit(), _rail_material)

	var piers := SurfaceTool.new()
	piers.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pier_height := maxf(clearance_height, 1.8)
	for along_value in [-0.34, 0.0, 0.34]:
		var along: float = float(along_value)
		var z: float = bridge_length * along
		_append_box(piers, Vector3(bridge_width * 0.62, pier_height, 0.68),
			Vector3(0.0, -pier_height * 0.5 - 0.48, z))
	piers.generate_normals()
	_add_mesh("BatchedBridgePiers", piers.commit(), _pier_material)

	var markings := SurfaceTool.new()
	markings.begin(Mesh.PRIMITIVE_TRIANGLES)
	for lane_side in [-1.0, 1.0]:
		_append_box(markings, Vector3(0.11, 0.025, bridge_length - 1.0),
			Vector3(lane_side * bridge_width * 0.235, 0.027, 0.0))
	# Dashed centre stripe keeps direction legible without separate instances.
	for dash_index in range(-4, 5):
		_append_box(markings, Vector3(0.13, 0.028, 3.7),
			Vector3(0.0, 0.031, float(dash_index) * 7.0))
	markings.generate_normals()
	_add_mesh("BatchedLaneMarkings", markings.commit(), _marking_material,
		false)


func _add_mesh(part_name: String, mesh: ArrayMesh, material: Material,
		cast_shadow := true) -> void:
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
		if cast_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_end = 1400.0
	instance.visibility_range_end_margin = 120.0
	instance.visibility_range_fade_mode = \
		GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(instance)


static func _append_box(surface: SurfaceTool, size: Vector3,
		center: Vector3) -> void:
	var h := size * 0.5
	var vertices := [
		center + Vector3(-h.x, -h.y, -h.z),
		center + Vector3(h.x, -h.y, -h.z),
		center + Vector3(h.x, h.y, -h.z),
		center + Vector3(-h.x, h.y, -h.z),
		center + Vector3(-h.x, -h.y, h.z),
		center + Vector3(h.x, -h.y, h.z),
		center + Vector3(h.x, h.y, h.z),
		center + Vector3(-h.x, h.y, h.z),
	]
	for face in [[0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3],
			[1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4]]:
		surface.add_vertex(vertices[face[0]])
		surface.add_vertex(vertices[face[1]])
		surface.add_vertex(vertices[face[2]])
		surface.add_vertex(vertices[face[0]])
		surface.add_vertex(vertices[face[2]])
		surface.add_vertex(vertices[face[3]])


static func _add_box_collision(body: StaticBody3D, size: Vector3,
		center: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position = center
	body.add_child(collision)


static func _ensure_materials() -> void:
	if _deck_material:
		return
	_deck_material = StandardMaterial3D.new()
	_deck_material.albedo_color = Color(0.25, 0.245, 0.225)
	_deck_material.roughness = 0.89
	_rail_material = StandardMaterial3D.new()
	_rail_material.albedo_color = Color(0.50, 0.53, 0.54)
	_rail_material.metallic = 0.62
	_rail_material.roughness = 0.36
	_pier_material = StandardMaterial3D.new()
	_pier_material.albedo_color = Color(0.40, 0.42, 0.41)
	_pier_material.roughness = 0.94
	_marking_material = StandardMaterial3D.new()
	_marking_material.albedo_color = Color(0.96, 0.78, 0.22)
	_marking_material.emission_enabled = true
	_marking_material.emission = Color(0.55, 0.32, 0.05)
	_marking_material.emission_energy_multiplier = 0.38
