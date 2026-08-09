class_name FreewayTunnel
extends Node3D
## Short deterministic cut-and-cover freeway bore. Terrain generation grades the
## road through the mountain first; this node supplies the arched enclosure,
## portal rings, warm lamps and collision without one draw call per panel.

static var _shell_material: StandardMaterial3D
static var _portal_material: StandardMaterial3D
static var _lamp_material: StandardMaterial3D

var tunnel_id := ""
var tunnel_length := 58.0
var tunnel_width := 13.6
var tunnel_height := 7.2
var _collisions_built := false
var _collision_bodies: Array[StaticBody3D] = []


func configure(data: Dictionary) -> void:
	tunnel_id = str(data.get("id", "freeway:tunnel"))
	tunnel_length = float(data.get("length", tunnel_length))
	tunnel_width = float(data.get("width", tunnel_width))
	tunnel_height = float(data.get("height", tunnel_height))
	position = data.get("pos", Vector3.ZERO)
	rotation.y = float(data.get("yaw", 0.0))


func _ready() -> void:
	name = "FreewayTunnel_%s" % tunnel_id.replace(":", "_")
	_ensure_materials()
	_build_shell()
	_build_lighting()


func light_count() -> int:
	var count := 0
	for child in get_children():
		if child is Light3D:
			count += 1
	return count


func build_collisions() -> Array[StaticBody3D]:
	if _collisions_built:
		return _collision_bodies
	_collisions_built = true
	var body := StaticBody3D.new()
	body.name = "FreewayTunnelCollision"
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)
	var half_width := tunnel_width * 0.5
	var wall_height := tunnel_height * 0.43
	_add_box_collision(body, Vector3(0.48, wall_height, tunnel_length),
		Vector3(-half_width - 0.12, wall_height * 0.5, 0.0))
	_add_box_collision(body, Vector3(0.48, wall_height, tunnel_length),
		Vector3(half_width + 0.12, wall_height * 0.5, 0.0))
	# Seven thin tangent panels approximate the elliptical crown. Their lower
	# edges stay outside the driveable envelope, while a bouncing vehicle still
	# contacts the same roof it sees.
	const ROOF_PANELS := 7
	var arch_height := tunnel_height - wall_height
	for index in range(ROOF_PANELS):
		var angle := lerpf(0.12, PI - 0.12,
			(float(index) + 0.5) / float(ROOF_PANELS))
		var next_angle := lerpf(0.12, PI - 0.12,
			(float(index) + 1.0) / float(ROOF_PANELS))
		var previous_angle := lerpf(0.12, PI - 0.12,
			float(index) / float(ROOF_PANELS))
		var panel_width := Vector2(
			half_width * (cos(next_angle) - cos(previous_angle)),
			arch_height * (sin(next_angle) - sin(previous_angle))).length()
		var center := Vector3(half_width * cos(angle),
			wall_height + arch_height * sin(angle), 0.0)
		var tangent_angle := atan2(arch_height * cos(angle),
			-half_width * sin(angle))
		_add_box_collision(body,
			Vector3(maxf(panel_width, 0.6), 0.42, tunnel_length), center,
			Vector3(0.0, 0.0, tangent_angle))
	_collision_bodies.append(body)
	return _collision_bodies


func _build_shell() -> void:
	var half_width := tunnel_width * 0.5
	var wall_height := tunnel_height * 0.43
	var arch_height := tunnel_height - wall_height
	var half_length := tunnel_length * 0.5
	var thickness := 0.42
	var shell := SurfaceTool.new()
	shell.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Vertical side walls are part of the same surface as the elliptical crown.
	_append_quad(shell,
		Vector3(-half_width, 0.0, -half_length),
		Vector3(-half_width, wall_height, -half_length),
		Vector3(-half_width, wall_height, half_length),
		Vector3(-half_width, 0.0, half_length))
	_append_quad(shell,
		Vector3(half_width, wall_height, -half_length),
		Vector3(half_width, 0.0, -half_length),
		Vector3(half_width, 0.0, half_length),
		Vector3(half_width, wall_height, half_length))
	const ARCH_SEGMENTS := 18
	for index in range(ARCH_SEGMENTS):
		var a0 := PI * float(index) / float(ARCH_SEGMENTS)
		var a1 := PI * float(index + 1) / float(ARCH_SEGMENTS)
		var inner0 := Vector2(half_width * cos(a0),
			wall_height + arch_height * sin(a0))
		var inner1 := Vector2(half_width * cos(a1),
			wall_height + arch_height * sin(a1))
		var outer0 := Vector2((half_width + thickness) * cos(a0),
			wall_height + (arch_height + thickness) * sin(a0))
		var outer1 := Vector2((half_width + thickness) * cos(a1),
			wall_height + (arch_height + thickness) * sin(a1))
		# Inward-facing liner and outward-facing rock/concrete shell.
		_append_quad(shell,
			Vector3(inner1.x, inner1.y, -half_length),
			Vector3(inner0.x, inner0.y, -half_length),
			Vector3(inner0.x, inner0.y, half_length),
			Vector3(inner1.x, inner1.y, half_length))
		_append_quad(shell,
			Vector3(outer0.x, outer0.y, -half_length),
			Vector3(outer1.x, outer1.y, -half_length),
			Vector3(outer1.x, outer1.y, half_length),
			Vector3(outer0.x, outer0.y, half_length))
	shell.generate_normals()
	_add_mesh("BatchedTunnelShell", shell.commit(), _shell_material)

	# Both thick portal rings are batched separately so their pale concrete reads
	# clearly against mountain rock from either freeway approach.
	var portals := SurfaceTool.new()
	portals.begin(Mesh.PRIMITIVE_TRIANGLES)
	for end_z in [-half_length - 0.08, half_length + 0.08]:
		for index in range(ARCH_SEGMENTS):
			var a0 := PI * float(index) / float(ARCH_SEGMENTS)
			var a1 := PI * float(index + 1) / float(ARCH_SEGMENTS)
			var inner0 := Vector2(half_width * cos(a0),
				wall_height + arch_height * sin(a0))
			var inner1 := Vector2(half_width * cos(a1),
				wall_height + arch_height * sin(a1))
			var outer0 := Vector2((half_width + 0.62) * cos(a0),
				wall_height + (arch_height + 0.62) * sin(a0))
			var outer1 := Vector2((half_width + 0.62) * cos(a1),
				wall_height + (arch_height + 0.62) * sin(a1))
			_append_quad(portals, Vector3(inner0.x, inner0.y, end_z),
				Vector3(inner1.x, inner1.y, end_z),
				Vector3(outer1.x, outer1.y, end_z),
				Vector3(outer0.x, outer0.y, end_z))
	portals.generate_normals()
	_add_mesh("BatchedPortalRings", portals.commit(), _portal_material)


func _build_lighting() -> void:
	var strips := SurfaceTool.new()
	strips.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(6):
		var z := lerpf(-tunnel_length * 0.40, tunnel_length * 0.40,
			float(index) / 5.0)
		_append_box(strips, Vector3(2.2, 0.08, 0.20),
			Vector3(0.0, tunnel_height - 0.48, z))
		var light := OmniLight3D.new()
		light.name = "WarmTunnelLamp%d" % index
		light.position = Vector3(0.0, tunnel_height - 0.64, z)
		light.light_color = Color(1.0, 0.78, 0.48)
		light.light_energy = 2.25
		light.omni_range = 13.5
		light.omni_attenuation = 1.45
		light.shadow_enabled = false
		light.distance_fade_enabled = true
		light.distance_fade_begin = 80.0
		light.distance_fade_length = 55.0
		add_child(light)
	_add_mesh("BatchedWarmLightStrips", strips.commit(), _lamp_material,
		false)


func _add_mesh(part_name: String, mesh: ArrayMesh, material: Material,
		cast_shadow := true) -> void:
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
		if cast_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_end = 950.0
	instance.visibility_range_end_margin = 80.0
	instance.visibility_range_fade_mode = \
		GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(instance)


static func _append_quad(surface: SurfaceTool, a: Vector3, b: Vector3,
		c: Vector3, d: Vector3) -> void:
	surface.add_vertex(a); surface.add_vertex(b); surface.add_vertex(c)
	surface.add_vertex(a); surface.add_vertex(c); surface.add_vertex(d)


static func _append_box(surface: SurfaceTool, size: Vector3,
		center: Vector3) -> void:
	var h := size * 0.5
	var corners := [
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
		_append_quad(surface, corners[face[0]], corners[face[1]],
			corners[face[2]], corners[face[3]])


static func _add_box_collision(body: StaticBody3D, size: Vector3,
		center: Vector3, rotation_value := Vector3.ZERO) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position = center
	collision.rotation = rotation_value
	body.add_child(collision)


static func _ensure_materials() -> void:
	if _shell_material:
		return
	_shell_material = StandardMaterial3D.new()
	_shell_material.albedo_color = Color(0.19, 0.205, 0.215)
	_shell_material.roughness = 0.91
	_shell_material.metallic = 0.03
	_portal_material = StandardMaterial3D.new()
	_portal_material.albedo_color = Color(0.47, 0.49, 0.48)
	_portal_material.roughness = 0.88
	_lamp_material = StandardMaterial3D.new()
	_lamp_material.albedo_color = Color(1.0, 0.72, 0.30)
	_lamp_material.emission_enabled = true
	_lamp_material.emission = Color(1.0, 0.48, 0.12)
	_lamp_material.emission_energy_multiplier = 4.2
	_lamp_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
