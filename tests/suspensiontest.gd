extends Node
## Focused release gate for the debug-world suspension proving ground. It
## checks deterministic mesh/collision construction, progressively increasing
## relief, the preserved northbound speed-test corridor, real wheel ray hits,
## and a controlled Jeep pass over the cross-axle lane.
##
## Run with:
##   godot --headless --path . res://scenes/main.tscn \
##     --quit-after 60000 -- suspensiontest

var fails := 0
var total := 0


func check(cname: String, ok: bool, info := "") -> void:
	total += 1
	if ok:
		print("  [ok] " + cname)
	else:
		fails += 1
		print("  [FAIL] " + cname + (("   :: " + info) if info != "" else ""))


func sim(frames: int) -> void:
	for i in range(frames):
		await get_tree().physics_frame


func run(main) -> void:
	print("SUSPENSIONTEST begin (debug world)")
	var world = main.world
	var course: DebugWorldBuilder
	for child in world.get_children():
		if child is DebugWorldBuilder:
			course = child
			break
	check("debug world exposes the suspension proving ground",
		course != null and course.rough_course != null)
	if course == null or course.rough_course == null:
		_finish(main)
		return
	await sim(3)

	var lanes := course.rough_course_lanes
	var names := PackedStringArray()
	for lane in lanes:
		names.append(lane.name)
	check("four named lanes progress from washboard to rock crawl",
		lanes.size() == 4 and names == PackedStringArray([
			"Washboard", "OffsetBumps", "CrossAxle", "RockCrawl"]),
		str(names))
	var east_edge: float = float(
		DebugWorldBuilder.ROUGH_COURSE_LANE_CENTERS.max()) \
		+ DebugWorldBuilder.ROUGH_COURSE_WIDTH * 0.5
	check("course stays clear of the canonical northbound speed-test lanes",
		east_edge <= -18.5 and DebugWorldBuilder.ROUGH_COURSE_START_Z >= 30.0,
		"east edge=%.2f" % east_edge)

	var mesh_budget_ok := true
	var collision_budget_ok := true
	var shared_material: Material
	var total_triangles := 0
	for lane_index in range(lanes.size()):
		var lane: StaticBody3D = lanes[lane_index]
		var visual := lane.get_node_or_null("Surface") as MeshInstance3D
		var collision := lane.get_node_or_null(
			"SurfaceCollision") as CollisionShape3D
		mesh_budget_ok = mesh_budget_ok and visual != null \
			and visual.mesh is ArrayMesh \
			and (visual.mesh as ArrayMesh).get_surface_count() == 1
		collision_budget_ok = collision_budget_ok and collision != null \
			and collision.shape is ConcavePolygonShape3D \
			and (collision.shape as ConcavePolygonShape3D).backface_collision
		if visual and visual.mesh:
			var material := visual.mesh.surface_get_material(0)
			if lane_index == 0:
				shared_material = material
			else:
				mesh_budget_ok = mesh_budget_ok and material == shared_material
		total_triangles += int(course.rough_course_metrics()[lane_index].triangles)
	check("each lane is one shared-material indexed draw surface", mesh_budget_ok)
	check("each lane has one matching two-sided trimesh collider",
		collision_budget_ok)
	check("the complete proving ground stays within its triangle budget",
		total_triangles <= 30000,
		"triangles=%d" % total_triangles)

	var metrics := course.rough_course_metrics()
	var progressive := metrics.size() == 4
	var bounded := true
	for lane_index in range(metrics.size()):
		var metric: Dictionary = metrics[lane_index]
		bounded = bounded \
			and float(metric.min_height) \
				>= DebugWorldBuilder.ROUGH_COURSE_MIN_CLEARANCE - 0.0001 \
			and float(metric.max_height) <= 0.65
		if lane_index > 0:
			progressive = progressive and float(metric.peak_relief) \
				> float(metrics[lane_index - 1].peak_relief) + 0.015
	check("roughness relief increases strictly from lane one through four",
		progressive,
		"peaks=%s" % str(metrics.map(
			func(metric): return snappedf(float(metric.peak_relief), 0.001))))
	check("all troughs clear the flat plane and all crests remain bounded", bounded)

	# Sample the same height source at mesh-grid spacing. This catches a sharp
	# lip that could launch a vehicle even if the overall min/max remained sane.
	var maximum_core_grade := 0.0
	var x_step := DebugWorldBuilder.ROUGH_COURSE_WIDTH \
		/ float(DebugWorldBuilder.ROUGH_COURSE_X_SEGMENTS)
	var z_step := DebugWorldBuilder.ROUGH_COURSE_LENGTH \
		/ float(DebugWorldBuilder.ROUGH_COURSE_Z_SEGMENTS)
	for lane_index in range(4):
		for z_index in range(DebugWorldBuilder.ROUGH_COURSE_Z_SEGMENTS):
			var lane_z := z_index * z_step
			for x_index in range(2,
					DebugWorldBuilder.ROUGH_COURSE_X_SEGMENTS - 1):
				var lane_x := -DebugWorldBuilder.ROUGH_COURSE_WIDTH * 0.5 \
					+ x_index * x_step
				var here := course.rough_course_height(lane_index, lane_x, lane_z)
				var forward := course.rough_course_height(lane_index, lane_x,
					lane_z + z_step)
				maximum_core_grade = maxf(maximum_core_grade,
					absf(forward - here) / z_step)
	check("rounded terrain keeps the drivable core free of vertical lips",
		maximum_core_grade <= 0.65,
		"max grade=%.3f" % maximum_core_grade)

	var space: PhysicsDirectSpaceState3D = \
		world.get_world_3d().direct_space_state
	var real_hits := true
	var height_match := true
	var upward_normals := true
	for lane_index in range(lanes.size()):
		var x: float = DebugWorldBuilder.ROUGH_COURSE_LANE_CENTERS[lane_index]
		# 23 m is exactly on this mesh's longitudinal grid.
		var z: float = DebugWorldBuilder.ROUGH_COURSE_START_Z + 23.0
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(x, DebugWorldBuilder.GROUND_Y + 3.0, z),
			Vector3(x, DebugWorldBuilder.GROUND_Y - 0.5, z))
		var hit: Dictionary = space.intersect_ray(query)
		real_hits = real_hits and not hit.is_empty() and hit.collider == lanes[lane_index]
		if not hit.is_empty():
			var expected := course.rough_course_world_height(lane_index, x, z)
			height_match = height_match \
				and absf((hit.position as Vector3).y - expected) < 0.006
			upward_normals = upward_normals \
				and (hit.normal as Vector3).y > 0.55
	check("wheel-direction rays hit every real course collider before the plane",
		real_hits)
	check("collision height matches the visible deterministic surface",
		height_match)
	check("all sampled driving faces have upward terrain normals", upward_normals)

	# Rebuild just the proving ground once to guarantee that its feature layout
	# and mesh samples never depend on the process RNG or construction order.
	var duplicate := DebugWorldBuilder.new()
	world.add_child(duplicate)
	var build_started := Time.get_ticks_usec()
	duplicate._build_rough_course()
	var build_ms := float(Time.get_ticks_usec() - build_started) / 1000.0
	var duplicate_metrics := duplicate.rough_course_metrics()
	var deterministic := duplicate_metrics.size() == metrics.size()
	for lane_index in range(mini(duplicate_metrics.size(), metrics.size())):
		deterministic = deterministic \
			and int(duplicate_metrics[lane_index].checksum) \
				== int(metrics[lane_index].checksum)
	check("course layout and mesh heights rebuild deterministically", deterministic)
	check("bounded procedural course construction remains lightweight",
		build_ms < 500.0, "%.1f ms" % build_ms)
	duplicate.queue_free()
	await sim(3)

	# Drive the actual Jeep from flat ground into the cross-axle lane. This uses
	# Player's ordinary W/S input path and the live raycast springs, not a mocked
	# suspension calculation.
	var jeep := world.vehicle_by_id("v:debug#jeep") as SafariJeep
	var player = world.local_player
	player.test_mode = true
	var cross_lane := 2
	jeep.settle_at(Vector3(
		DebugWorldBuilder.ROUGH_COURSE_LANE_CENTERS[cross_lane],
		DebugWorldBuilder.GROUND_Y,
		DebugWorldBuilder.ROUGH_COURSE_START_Z - 7.0), 0.0)
	await sim(45)
	player.enter_vehicle(jeep)
	await sim(10)
	var maximum_articulation := 0.0
	var minimum_up := 1.0
	var minimum_compression := INF
	var maximum_compression := 0.0
	var course_contact_frames := 0
	var reached_z := jeep.global_position.z
	for frame in range(900):
		var forward_speed := jeep.forward_speed()
		if forward_speed < 3.4:
			player.ti.dir = Vector2(0.0, -1.0)
		elif forward_speed > 4.8:
			player.ti.dir = Vector2(0.0, 0.65)
		else:
			player.ti.dir = Vector2.ZERO
		await get_tree().physics_frame
		reached_z = maxf(reached_z, jeep.global_position.z)
		minimum_up = minf(minimum_up, jeep.global_basis.y.y)
		if jeep.global_position.z >= DebugWorldBuilder.ROUGH_COURSE_START_Z \
				+ DebugWorldBuilder.ROUGH_COURSE_FEATURE_START:
			maximum_articulation = maxf(maximum_articulation,
				maxf(absf(jeep.wheels[0].compression - jeep.wheels[1].compression),
					absf(jeep.wheels[2].compression - jeep.wheels[3].compression)))
			for wheel in jeep.wheels:
				minimum_compression = minf(minimum_compression, wheel.compression)
				maximum_compression = maxf(maximum_compression, wheel.compression)
				if wheel.in_contact and wheel.contact_point.y \
						> DebugWorldBuilder.GROUND_Y + 0.08:
					course_contact_frames += 1
		if reached_z >= DebugWorldBuilder.ROUGH_COURSE_START_Z + 40.0:
			break
	player.ti.dir = Vector2.ZERO
	check("Jeep drives from flat ground through multiple cross-axle stations",
		reached_z >= DebugWorldBuilder.ROUGH_COURSE_START_Z + 40.0 \
			and course_contact_frames > 40,
		"z=%.1f contacts=%d" % [reached_z, course_contact_frames])
	check("cross-axle lane visibly exercises real independent wheel travel",
		maximum_articulation > 0.035 \
			and maximum_compression - minimum_compression > 0.08,
		"articulation=%.3f travel span=%.3f" % [maximum_articulation,
			maximum_compression - minimum_compression])
	check("controlled rough-terrain pass remains upright and numerically stable",
		minimum_up > 0.58 and jeep.global_position.is_finite() \
			and jeep.linear_velocity.is_finite() \
			and jeep.angular_velocity.is_finite() \
			and jeep.physics_recovery_count == 0 and player.vehicle == jeep,
		"min up=%.3f recoveries=%d" % [minimum_up,
			jeep.physics_recovery_count])

	_finish(main)


func _finish(main) -> void:
	print("SUSPENSIONTEST %d/%d %s" % [total - fails, total,
		"PASS" if fails == 0 else "FAIL"])
	await get_tree().process_frame
	main.get_tree().quit(1 if fails > 0 else 0)
