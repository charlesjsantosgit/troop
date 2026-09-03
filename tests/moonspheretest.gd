extends Node
## Closed topology, exact render/collision agreement and radial physics checks.
## Registered by main.gd; run: godot --headless --path . -- moonspheretest

var passed := 0
var total := 0


class SurfaceProbe:
	extends CharacterBody3D
	var moon: MoonWorld

	func _physics_process(delta: float) -> void:
		up_direction = moon.radial_up_at(global_position)
		global_basis = MoonWorld.surface_basis(up_direction)
		if is_on_floor():
			velocity = up_direction * minf(velocity.dot(up_direction), 0.0)
		velocity += moon.gravity_at(global_position) * delta
		move_and_slide()


func run() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String, detail: String = "") -> void:
	total += 1
	if ok:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label + (" :: " + detail if not detail.is_empty() else ""))


func _run() -> void:
	print("MOON SPHERE TEST")
	var moon := MoonWorld.new()
	moon.position = Vector3(0.0, Net.MOON_WORLD_ORIGIN_Y, 0.0)
	moon.moon_seed = 741_969
	var build_start := Time.get_ticks_usec()
	add_child(moon)
	var build_ms := float(Time.get_ticks_usec() - build_start) / 1000.0
	print("  sphere construction: %.1f ms, one terrain draw, no terrain frame updates" % build_ms)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var arrays := moon.terrain_mesh.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	_check(vertices.size() == moon.terrain_vertex_count()
			and indices.size() == moon.terrain_triangle_count() * 3
			and vertices.size() <= 25_000 and indices.size() / 3 <= 50_000
			and moon.terrain_mesh.mesh.get_surface_count() == 1
			and moon.terrain_mesh.visible,
		"complete sphere uses one bounded indexed terrain draw",
		"vertices=%d triangles=%d build_ms=%.1f" % [vertices.size(), indices.size() / 3, build_ms])
	var edges: Dictionary = {}
	var outward := true
	var minimum_radius := INF
	var maximum_radius := -INF
	for index in range(vertices.size()):
		var radial := vertices[index] - MoonWorld.PLAYABLE_CENTER
		minimum_radius = minf(minimum_radius, radial.length())
		maximum_radius = maxf(maximum_radius, radial.length())
		outward = outward and normals[index].dot(radial.normalized()) > 0.85
	for triangle in range(0, indices.size(), 3):
		for corner in range(3):
			var a := indices[triangle + corner]
			var b := indices[triangle + (corner + 1) % 3]
			var edge := Vector2i(mini(a, b), maxi(a, b))
			edges[edge] = int(edges.get(edge, 0)) + 1
	var closed := true
	for count in edges.values():
		closed = closed and int(count) == 2
	_check(closed and vertices.size() - edges.size() + indices.size() / 3 == 2,
		"every triangle edge is welded exactly twice: no holes, face seams or pole gaps")
	_check(outward and minimum_radius > MoonWorld.PLAYABLE_RADIUS_METERS - 35.0
			and maximum_radius < MoonWorld.PLAYABLE_RADIUS_METERS + 15.0,
		"all faces point outward and bounded craters follow a sphere",
		"radius_min=%.3f radius_max=%.3f" % [minimum_radius, maximum_radius])
	var collision_node := moon.terrain_body.get_child(0) as CollisionShape3D
	var shape := collision_node.shape as ConcavePolygonShape3D
	_check(shape != null and shape.get_faces() == moon.terrain_mesh.mesh.get_faces(),
		"rendered terrain and physical terrain use identical triangle vertices")
	_check(moon.gravity_area.gravity_point
			and moon.gravity_area.gravity_point_unit_distance == 0.0
			and moon.gravity_area.position == MoonWorld.PLAYABLE_CENTER
			and (moon.gravity_area.get_child(0) as CollisionShape3D).shape is SphereShape3D,
		"rigid-body vacuum volume is spherical and applies constant radial gravity")

	var landing_surface := moon.surface_position(Vector3.UP)
	var near_horizon_ground := moon.surface_position(Vector3(30.0, MoonWorld.PLAYABLE_RADIUS_METERS, 0.0))
	var visible_sag := landing_surface.y - near_horizon_ground.y
	_check(visible_sag >= 0.90 and visible_sag <= 1.20,
		"the actual landing ground curves down about a metre within thirty metres",
		"physical_30m_sag=%.4f" % visible_sag)
	var material := moon.terrain_mesh.material_override as ShaderMaterial
	var sun := moon.get_node("HarshLunarSunlight") as DirectionalLight3D
	_check(material != null and not material.shader.code.contains("render_mode unshaded")
		and (material.get_shader_parameter("playable_center") as Vector3).is_equal_approx(MoonWorld.PLAYABLE_CENTER)
		and is_equal_approx(float(material.get_shader_parameter("playable_radius")), MoonWorld.PLAYABLE_RADIUS_METERS)
		and sun.shadow_enabled and sun.directional_shadow_max_distance <= 120.0
		and moon.terrain_mesh.extra_cull_margin == 0.0
		and moon.lunar_environment.ssao_enabled,
		"playable terrain receives bounded contact shadows with matching geometry and contact occlusion")

	var directions: Array[Vector3] = [Vector3.UP, Vector3.DOWN, Vector3.LEFT,
		Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				directions.append(Vector3(x, y, z).normalized())
	for offset in [-0.001, 0.0, 0.001]:
		directions.append(Vector3(1.0 + offset, 1.0, 0.25).normalized())
		directions.append(Vector3(-1.0, -1.0 + offset, -0.35).normalized())
	var ray_hits := 0
	var max_collision_error := 0.0
	var all_gravity := true
	var peer := MoonWorld.new()
	peer.moon_seed = moon.moon_seed
	var peer_agreement := true
	for direction in directions:
		var surface := moon.to_global(moon.surface_position(direction))
		var query := PhysicsRayQueryParameters3D.create(surface + direction * 35.0,
			surface - direction * 35.0, 1)
		var hit := moon.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty() and hit.collider == moon.terrain_body:
			ray_hits += 1
			max_collision_error = maxf(max_collision_error, (hit.position as Vector3).distance_to(surface))
		all_gravity = all_gravity and moon.gravity_at(surface).is_equal_approx(-direction * 1.62)
		peer_agreement = peer_agreement and moon.surface_position(direction).is_equal_approx(
			peer.surface_position(direction))
	_check(ray_hits == directions.size() and max_collision_error < 0.03,
		"physics rays hit exact terrain at poles, backside, corners and both sides of face seams",
		"hits=%d/%d max_error=%.6f" % [ray_hits, directions.size(), max_collision_error])
	_check(all_gravity, "character gravity points inward at every tested surface orientation")
	_check(peer_agreement and MoonWorld.shop_position_for_seed(moon.moon_seed).is_equal_approx(
		moon.cheese_shop.position), "unbuilt server sampler matches full terrain and exact shop placement")
	peer.free()

	var loop_start := moon.surface_position(Vector3.UP)
	var loop_continuous := true
	var previous := loop_start
	var max_step := 0.0
	for step in range(1, 721):
		var angle := TAU * float(step) / 720.0
		var direction := Vector3(sin(angle), cos(angle), 0.0)
		var surface := moon.surface_position(direction)
		max_step = maxf(max_step, surface.distance_to(previous))
		loop_continuous = loop_continuous and surface.is_finite()
		previous = surface
	_check(loop_continuous and previous.distance_to(loop_start) < 0.002 and max_step < 12.0,
		"a full great-circle route crosses both poles and returns continuously to its start",
		"max_0.5deg_step=%.3f" % max_step)

	var probes: Array[SurfaceProbe] = []
	for direction in directions.slice(0, 6):
		var probe := SurfaceProbe.new()
		probe.moon = moon
		probe.collision_layer = 2
		probe.collision_mask = 1
		probe.floor_snap_length = 0.4
		probe.safe_margin = MoonWorld.CHARACTER_SAFE_MARGIN
		var collider := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.35
		capsule.height = 1.6
		collider.shape = capsule
		collider.position.y = 0.8
		probe.add_child(collider)
		add_child(probe)
		probe.global_basis = MoonWorld.surface_basis(direction)
		probe.global_position = moon.to_global(moon.surface_position(direction, 4.0))
		probes.append(probe)
	var rigid_probes: Array[RigidBody3D] = []
	for direction in [Vector3.RIGHT, Vector3.DOWN, Vector3.FORWARD]:
		var body := RigidBody3D.new()
		body.collision_layer = 2
		body.collision_mask = 1
		var collider := CollisionShape3D.new()
		var ball := SphereShape3D.new()
		ball.radius = 0.3
		collider.shape = ball
		body.add_child(collider)
		add_child(body)
		body.global_position = moon.to_global(moon.surface_position(direction, 3.0))
		rigid_probes.append(body)
	for frame in range(210):
		await get_tree().physics_frame
	var settled := 0
	var max_altitude := 0.0
	for probe in probes:
		var altitude := moon.altitude_at(probe.global_position)
		max_altitude = maxf(max_altitude, absf(altitude))
		if probe.is_on_floor() and absf(altitude) < 0.35 \
				and probe.velocity.length() < 0.5:
			settled += 1
		else:
			print("  probe floor=%s wall=%s ceiling=%s altitude=%.6f velocity=%s up=%s slides=%d" % [probe.is_on_floor(), probe.is_on_wall(), probe.is_on_ceiling(), altitude, probe.velocity, probe.up_direction, probe.get_slide_collision_count()])
			for collision_index in range(probe.get_slide_collision_count()):
				var slide := probe.get_slide_collision(collision_index)
				print("    collider=%s normal=%s position=%s" % [slide.get_collider(), slide.get_normal(), slide.get_position()])
	_check(settled == probes.size(),
		"CharacterBody capsules land and remain standing on all six sides of the Moon",
		"settled=%d/%d max_altitude=%.4f" % [settled, probes.size(), max_altitude])
	var rigid_settled := 0
	for body in rigid_probes:
		var altitude := moon.altitude_at(body.global_position)
		if altitude > 0.10 and altitude < 0.55:
			rigid_settled += 1
		body.queue_free()
	_check(rigid_settled == rigid_probes.size(),
		"engine RigidBody gravity lands loose objects on the equator and southern hemisphere",
		"settled=%d/%d" % [rigid_settled, rigid_probes.size()])
	for probe in probes:
		probe.queue_free()
	moon.queue_free()
	await get_tree().process_frame
	print("MOONSPHERETEST %d/%d %s" % [passed, total, "PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
