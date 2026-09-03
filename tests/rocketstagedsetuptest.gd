extends Node
## Independent native SurfaceTool reference checks cached CPU input attributes;
## full sync/staged crafts then verify setup, seats, colliders and cancellation.

var passed := 0
var total := 0


func run() -> void:
	call_deferred("_run")


func _run() -> void:
	var reference := SurfaceTool.new()
	reference.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cached := SurfaceTool.new()
	cached.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sources: Array[PrimitiveMesh] = []
	for size in [Vector3.ONE, Vector3(0.065, 17.90, 0.022),
			Vector3(4.55, 0.42, 0.60), Vector3(0.055, 0.36, 0.025),
			Vector3(1.48, 0.16, 1.40)]:
		var box := BoxMesh.new()
		box.size = size
		sources.append(box)
	for cap in range(4):
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.06 if cap == 0 else 3.5
		cylinder.bottom_radius = 3.5
		cylinder.height = 6.0 if cap == 0 else 13.1
		cylinder.radial_segments = 24
		cylinder.cap_top = (cap & 1) != 0
		cylinder.cap_bottom = (cap & 2) != 0
		sources.append(cylinder)
	var inputs_exact := true
	for index in range(sources.size()):
		var source := sources[index]
		var cpu := LunarRocket._cpu_batch_mesh(source)
		inputs_exact = inputs_exact and source.get_mesh_arrays() == cpu.arrays
		var transform := Transform3D(Basis.from_euler(Vector3(0.13, 0.37, -0.27)
			* index).scaled_local(Vector3(1.1, 0.9, 1.2)),
			Vector3(index * 0.39, -12.65, 3.94))
		reference.append_from(source, 0, transform)
		cached.append_from(cpu, 0, transform)
	_check(inputs_exact, "cached CPU recipes preserve all original primitive arrays")
	_check(reference.commit_to_arrays() == cached.commit_to_arrays(),
		"CPU adapter exactly preserves native transformed attributes and indices")
	var source_copy := BoxMesh.new()
	source_copy.size = (sources[1] as BoxMesh).size
	_check(LunarRocket._cpu_batch_mesh(source_copy)
			== LunarRocket._cpu_batch_mesh(sources[1]),
		"equal shape recipes reuse CPU data without renderer readback")
	# Set the close value on a fresh primitive: BoxMesh intentionally ignores
	# approximately-equal edits to an existing size before our cache sees them.
	source_copy = BoxMesh.new()
	source_copy.size = (sources[1] as BoxMesh).size + Vector3(0.000001, 0, 0)
	_check(LunarRocket._cpu_batch_mesh(source_copy)
			!= LunarRocket._cpu_batch_mesh(sources[1]),
		"cache keys retain full geometry precision")

	var synchronous := LunarRocket.new()
	synchronous.freeze = true
	add_child(synchronous)
	_check(synchronous.is_setup_complete() and synchronous.voyage_visuals.is_setup_complete(),
		"ordinary ready retains complete rocket and backdrop semantics")
	var staged := LunarRocket.new()
	staged.freeze = true
	staged.begin_setup()
	add_child(staged)
	_check(not staged.is_setup_complete() and staged.get_child_count() == 0
			and not staged.is_physics_processing(),
		"explicit begin prevents ready from draining setup or advancing flight")
	var calls := 0
	var phase_max_ms: Dictionary = {}
	while calls < 2000:
		var phase := staged.setup_phase_name()
		var start := Time.get_ticks_usec()
		var complete := staged.build_setup_step(250)
		phase_max_ms[phase] = maxf(float(phase_max_ms.get(phase, 0.0)),
			float(Time.get_ticks_usec() - start) / 1000.0)
		calls += 1
		if complete:
			break
	print("  rocket staged calls=%d phase_max_ms=%s" % [calls, phase_max_ms])
	_check(staged.is_setup_complete() and calls > 25 and calls < 2000
			and phase_max_ms.has("exterior_batch") and phase_max_ms.has("voyage_earth"),
		"bounded phases include CPU assembly, separate uploads and celestial first use")
	_check(_static_mesh_snapshot(synchronous) == _static_mesh_snapshot(staged),
		"synchronous and progressive craft meshes match every array and local transform")
	_check(_collision_snapshot(synchronous) == _collision_snapshot(staged),
		"synchronous and progressive contact shapes and transforms match exactly")
	var seats_equal := synchronous.seat_nodes.size() == LunarRocket.MAX_CREW \
		and staged.seat_nodes.size() == LunarRocket.MAX_CREW
	for index in range(mini(synchronous.seat_nodes.size(), staged.seat_nodes.size())):
		seats_equal = seats_equal and synchronous.seat_nodes[index].transform \
			== staged.seat_nodes[index].transform
	_check(seats_equal and staged.cabin_windows.size() == 12
			and staged.cabin_lights.size() == 2 and staged.landing_gear.size() == 4,
		"four seats, transparent windows, cabin lights and physical landing gear remain intact")
	_check(staged.voyage_visuals.is_setup_complete()
			and staged.voyage_visuals.star_field.multimesh.instance_count == 480
			and staged.voyage_visuals.planets.size() == 4
			and staged.voyage_visuals.nebulae.size() == 3
			and not staged.voyage_visuals.visible,
		"all voyage features are built before boarding and remain hidden at the pad")
	var child_count := staged.get_child_count()
	staged.begin_setup()
	_check(staged.build_setup_step() and staged.get_child_count() == child_count,
		"completed setup is idempotent")
	var cancelled := LunarRocket.new()
	cancelled.begin_setup()
	add_child(cancelled)
	cancelled.build_setup_step(1)
	cancelled.queue_free()
	var cancelled_phase := cancelled.setup_phase_name()
	_check(not cancelled.build_setup_step()
			and cancelled.setup_phase_name() == cancelled_phase,
		"queued rocket cancellation refuses further construction")
	var backdrop := SpaceVoyageVisuals.new()
	backdrop.begin_setup()
	add_child(backdrop)
	_check(backdrop.get_child_count() == 0 and not backdrop.is_setup_complete(),
		"backdrop ready also preserves explicitly staged setup")
	backdrop.queue_free()
	_check(not backdrop.build_setup_step(), "queued backdrop cancellation refuses work")
	await get_tree().process_frame
	_check(not is_instance_valid(cancelled) and not is_instance_valid(backdrop),
		"partial construction owns no surviving worker or delayed completion")
	synchronous.queue_free()
	staged.queue_free()
	print("ROCKETSTAGEDSETUPTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	await get_tree().process_frame
	get_tree().quit(0 if passed == total else 1)


func _static_mesh_snapshot(rocket: Node3D) -> Array:
	var snapshot: Array = []
	for path in ["VehicleStructure", "CrewCabin"]:
		var root := rocket.get_node(path)
		for mesh in root.find_children("*", "MeshInstance3D", true, false):
			var node := mesh as MeshInstance3D
			var entry: Array = [str(root.get_path_to(node)), node.transform]
			for surface in range(node.mesh.get_surface_count()):
				entry.append(node.mesh.surface_get_arrays(surface))
			snapshot.append(entry)
	return snapshot


func _collision_snapshot(rocket: Node3D) -> Array:
	var snapshot: Array = []
	for child in rocket.get_children():
		if child is CollisionShape3D:
			var shape: Shape3D = child.shape
			var dimensions: Variant
			if shape is BoxShape3D:
				dimensions = shape.size
			elif shape is CylinderShape3D:
				dimensions = Vector2(shape.radius, shape.height)
			elif shape is ConvexPolygonShape3D:
				dimensions = shape.points
			snapshot.append([str(child.name), child.transform, shape.get_class(), dimensions])
	return snapshot


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
	print("  [%s] %s" % ["ok" if condition else "FAIL", label])
