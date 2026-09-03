extends Node
## Progressive Moon construction must be byte-for-byte deterministic with the
## synchronous setup retained for tests, servers and direct Moon entry.

var passed := 0
var total := 0


func run() -> void:
	call_deferred("_run")


func _run() -> void:
	var seed_value := 741_969
	var synchronous := MoonWorld.new()
	synchronous.setup(seed_value)
	add_child(synchronous)
	_check(synchronous.is_setup_complete()
			and synchronous.setup_phase_name() == "complete",
		"synchronous setup retains its complete-on-return contract")

	var staged := MoonWorld.new()
	staged.begin_setup(seed_value)
	add_child(staged)
	_check(not staged.is_setup_complete() and staged.terrain_mesh == null
			and staged.setup_phase_name() == "material",
		"entering the tree does not auto-complete an explicitly staged build")

	var calls := 0
	var phases: Dictionary = {}
	var phase_max_ms: Dictionary = {}
	var checked_collision_batch := false
	var collision_batch_bounded := false
	while calls <= 2000:
		var phase := staged.setup_phase_name()
		var check_collision_batch := phase == "terrain_collision_faces" \
			and not checked_collision_batch
		var previous_cursor := staged._setup_cursor
		var started := Time.get_ticks_usec()
		var complete := staged.build_setup_step(1 if check_collision_batch else 250)
		var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
		if check_collision_batch:
			checked_collision_batch = true
			collision_batch_bounded = staged._setup_cursor - previous_cursor \
				== MoonWorld.SETUP_COLLISION_TRIANGLE_BATCH * 3 \
				and staged.terrain_body == null \
				and staged.setup_phase_name() == "terrain_collision_faces"
		phase_max_ms[phase] = maxf(float(phase_max_ms.get(phase, 0.0)), elapsed_ms)
		calls += 1
		phases[staged.setup_phase_name()] = true
		if complete:
			break
	print("  staged setup calls=%d phase_max_ms=%s" % [calls, phase_max_ms])
	_check(staged.is_setup_complete() and calls > 100 and calls <= 2000
			and phases.has("vertex_rows") and phases.has("face_normals")
			and phases.has("terrain_collision_faces"),
		"small steps traverse bounded row, normal and collision phases before completing",
		"calls=%d phases=%s" % [calls, phases.keys()])
	_check(checked_collision_batch and collision_batch_bounded,
		"the minimum budget expands one collision-face batch before shape publication")
	_check(staged.moon_seed == seed_value and staged.terrain_body != null
			and staged.landing_platform_body != null and staged.gravity_area != null
			and staged.cheese_shop != null and staged.colony_world != null,
		"completion publishes every required seeded world and collision feature")

	var sync_arrays := synchronous.terrain_mesh.mesh.surface_get_arrays(0)
	var staged_arrays := staged.terrain_mesh.mesh.surface_get_arrays(0)
	var arrays_equal := true
	for slot in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR,
			Mesh.ARRAY_INDEX]:
		arrays_equal = arrays_equal and sync_arrays[slot] == staged_arrays[slot]
	_check(arrays_equal
			and synchronous.terrain_vertex_count() == staged.terrain_vertex_count()
			and synchronous.terrain_triangle_count() == staged.terrain_triangle_count(),
		"staged terrain arrays exactly match synchronous vertex ordering and normals")
	var sync_shape := (synchronous.terrain_body.get_child(0) as CollisionShape3D).shape \
		as ConcavePolygonShape3D
	var staged_shape := (staged.terrain_body.get_child(0) as CollisionShape3D).shape \
		as ConcavePolygonShape3D
	_check(sync_shape.get_faces() == staged_shape.get_faces(),
		"staged and synchronous worlds publish identical terrain collision faces",
		_collision_difference(sync_shape.get_faces(), staged_shape.get_faces()))
	_check(sync_shape.backface_collision == staged_shape.backface_collision
			and synchronous.terrain_body.collision_layer == staged.terrain_body.collision_layer
			and synchronous.terrain_body.collision_mask == staged.terrain_body.collision_mask
			and staged._setup_collision_faces.is_empty(),
		"CPU collider publication preserves contact flags and releases temporary face storage")
	_check_rock_collision_cache(staged)
	_check_colony_collision_cache(staged.colony_world)

	var surface_equal := true
	for direction in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT,
			Vector3.FORWARD, Vector3.BACK, Vector3(1, 1, 1).normalized()]:
		surface_equal = surface_equal and synchronous.surface_position(direction) \
			.is_equal_approx(staged.surface_position(direction))
	_check(surface_equal
			and synchronous.landing_transform().is_equal_approx(staged.landing_transform())
			and synchronous.cheese_shop.transform.is_equal_approx(
				staged.cheese_shop.transform),
		"seeded surfaces, landing route and merchant placement retain parity")
	var finished_child_count := staged.get_child_count()
	staged.begin_setup(seed_value + 20)
	_check(staged.build_setup_step() and staged.moon_seed == seed_value
			and staged.get_child_count() == finished_child_count,
		"completion is idempotent and cannot append or reseed an already built world")
	var drained := MoonWorld.new()
	drained.begin_setup(seed_value)
	drained.build_setup_step(1)
	drained.setup(seed_value)
	_check(drained.is_setup_complete()
			and drained._sphere_vertices == synchronous._sphere_vertices
			and drained._sphere_indices == synchronous._sphere_indices,
		"synchronous setup can safely finish an already started progressive build")
	drained.free()

	var cancelled := MoonWorld.new()
	cancelled.begin_setup(seed_value + 1)
	cancelled.begin_setup(seed_value + 2)
	add_child(cancelled)
	_check(cancelled.moon_seed == seed_value + 1
			and not cancelled.surface_position(Vector3.RIGHT).is_equal_approx(
				staged.surface_position(Vector3.RIGHT)),
		"begin selects a distinct deterministic seed and cannot reseed partial terrain")
	_check(not cancelled.build_setup_step(1) and not cancelled.is_setup_complete(),
		"a partial build owns no background task and remains explicitly cancellable")
	cancelled.build_setup_step(1)
	_check(cancelled._sphere_vertices.size() > 0
			and cancelled._sphere_vertices.size() <= MoonWorld.SPHERE_FACE_SEGMENTS + 1,
		"the minimum budget advances only one vertex row, not the whole sphere")
	var partial_vertex_count := cancelled._sphere_vertices.size()
	cancelled.queue_free()
	_check(not cancelled.build_setup_step()
			and cancelled._sphere_vertices.size() == partial_vertex_count,
		"a queued-for-deletion world refuses further setup work")
	await get_tree().process_frame
	_check(not is_instance_valid(cancelled),
		"queue-free cancels a partial build without a completion callback")

	synchronous.queue_free()
	staged.queue_free()
	print("MOONSTAGEDSETUPTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	await get_tree().process_frame
	get_tree().quit(0 if passed == total else 1)


func _collision_difference(expected: PackedVector3Array, actual: PackedVector3Array) -> String:
	if expected.size() != actual.size():
		return "expected_count=%d actual_count=%d" % [expected.size(), actual.size()]
	for index in range(expected.size()):
		if expected[index] != actual[index]:
			return "first=%d expected=%s actual=%s distance=%.9f" % [index,
				expected[index], actual[index], expected[index].distance_to(actual[index])]
	return ""


func _check_rock_collision_cache(moon: MoonWorld) -> void:
	var source: PackedVector3Array = MoonWorld._lunar_rock_mesh.get_mesh_arrays()[Mesh.ARRAY_VERTEX]
	var unchanged := source == MoonWorld._lunar_rock_vertices
	var collision_index := 1
	var geometry_equal := true
	for index in range(MoonWorld.LUNAR_ROCK_COUNT):
		var hs := MoonWorld._hash_u32(moon.moon_seed + index * 6991 + 229)
		var size := lerpf(0.35, 2.6, pow(float(hs & 0xff) / 255.0, 2.2))
		if size < 1.0:
			continue
		var squash := lerpf(0.42, 0.76, float((hs >> 24) & 0xff) / 255.0)
		var expected := source.duplicate()
		for vertex in range(expected.size()):
			expected[vertex] *= Vector3(size, size * squash, size * 0.78)
		var shape := (moon.terrain_body.get_child(collision_index) as CollisionShape3D).shape \
			as ConvexPolygonShape3D
		geometry_equal = geometry_equal and shape.points == expected
		collision_index += 1
	_check(unchanged and MoonWorld._lunar_rock_vertices == source,
		"shared rock source vertices remain unscaled across multiple Moon builds")
	_check(geometry_equal and collision_index == moon.terrain_body.get_child_count()
			and collision_index > 2,
		"every cached rock collider matches independently scaled source geometry")


func _check_colony_collision_cache(colony: MoonColonyWorld) -> void:
	var fixture := Node3D.new()
	colony.add_child(fixture)
	var bases_unchanged := true
	var geometry_equal := true
	var shape_index := 0
	# Distinct non-uniform scales expose accidental mutation of shared packed
	# arrays; rotations and positions must remain on the collision node itself.
	var at := Vector3(2.0, 3.0, 4.0)
	var angles := Vector3(0.2, -0.4, 0.6)
	for mesh_id in MoonColonyWorld._meshes:
		var mesh: PrimitiveMesh = MoonColonyWorld._meshes[mesh_id]
		var source: PackedVector3Array = mesh.get_mesh_arrays()[Mesh.ARRAY_VERTEX]
		for size in [Vector3(0.5, 1.7, 2.4), Vector3(2.0, 0.6, 0.3)]:
			colony._solid_primitive(fixture, mesh_id, at, size, angles)
			var expected := source.duplicate()
			for vertex in range(expected.size()):
				expected[vertex] *= size
			var collision := fixture.get_child(0).get_child(shape_index) as CollisionShape3D
			var shape := collision.shape as ConvexPolygonShape3D
			geometry_equal = geometry_equal and shape.points == expected \
				and collision.transform == Transform3D(Basis.from_euler(angles), at)
			bases_unchanged = bases_unchanged \
				and MoonColonyWorld._collision_vertices[mesh_id] == source
			shape_index += 1
	_check(bases_unchanged and shape_index == MoonColonyWorld._meshes.size() * 2,
		"all cached colony primitive sources remain unscaled after repeated use")
	_check(geometry_equal,
		"cached colony collider geometry and node transforms preserve exact primitive semantics")
	fixture.free()


func _check(condition: bool, label: String, detail := "") -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label + (" :: " + detail if not detail.is_empty() else ""))
