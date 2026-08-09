extends Node
## Focused geometry, motion, cache, and remote-replica checks for angel wings:
##   godot --headless --path . res://scenes/main.tscn --quit-after 30000 -- wingtest

var passed := 0
var total := 0


func run() -> void:
	var rig := MonkeyRig.new()
	rig.setup("WingTester", false)
	add_child(rig)
	_check(not rig.has_angel_wings_visible()
		and rig.angel_wing_articulation_nodes().left.shoulder == null,
		"wings remain unbuilt and non-rendering before fly mode")

	var build_started := Time.get_ticks_usec()
	rig.set_angel_wings(true)
	var first_build_msec := float(Time.get_ticks_usec() - build_started) / 1000.0
	var metrics: Dictionary = rig.angel_wing_detail_metrics()
	_check(metrics.feathers_per_side == 91 and metrics.total_feathers == 182,
		"anatomical layout batches 91 layered feathers per wing")
	_check(metrics.length_segments == 18 and metrics.width_segments == 8
		and metrics.triangles_per_feather == 680
		and metrics.instanced_triangles == 123760,
		"closed curved vanes provide the intended high-poly surface detail")
	_check(metrics.render_objects == 6 and first_build_msec < 100.0,
		"high-poly pair stays at six render objects and builds without a long hitch")

	var render_nodes := _wing_render_nodes(rig)
	var feather_instances := 0
	var shared_mesh: Mesh = null
	var shared_material: Material = null
	var resources_shared := render_nodes.size() == 6
	var local_layers := true
	for child in render_nodes:
		var feathers := child as MultiMeshInstance3D
		if not feathers or not feathers.multimesh:
			resources_shared = false
			continue
		feather_instances += feathers.multimesh.instance_count
		if shared_mesh == null:
			shared_mesh = feathers.multimesh.mesh
			shared_material = feathers.material_override
		else:
			resources_shared = resources_shared \
				and feathers.multimesh.mesh == shared_mesh \
				and feathers.material_override == shared_material
		local_layers = local_layers \
			and feathers.layers == MonkeyRig.LOCAL_BODY_VISUAL_LAYER
	_check(resources_shared and feather_instances == 182,
		"all feathers instance one shared mesh and material")
	_check(local_layers and shared_material is StandardMaterial3D
		and not shared_material.emission_enabled,
		"local wings obey camera layers and use natural non-glowing material")
	var mesh_arrays: Array = (shared_mesh as ArrayMesh).surface_get_arrays(0)
	var indices: PackedInt32Array = mesh_arrays[Mesh.ARRAY_INDEX]
	_check(indices.size() / 3 == metrics.triangles_per_feather,
		"runtime mesh index count matches the high-detail metric")
	var cap_directions := _feather_cap_normal_directions(mesh_arrays)
	_check(cap_directions.root < -0.90 and cap_directions.tip > 0.90,
		"closed quill and distal caps face outward instead of inside-out "
		+ "(root=%.2f tip=%.2f)" % [cap_directions.root, cap_directions.tip])

	var node_ids: Array[int] = []
	for child in render_nodes:
		node_ids.append(child.get_instance_id())
	var mesh_rid := shared_mesh.get_rid()
	for i in range(100):
		rig.set_angel_wings(i % 2 == 0)
	rig.set_angel_wings(true)
	var toggled_ids: Array[int] = []
	for child in _wing_render_nodes(rig):
		toggled_ids.append(child.get_instance_id())
	_check(node_ids == toggled_ids and shared_mesh.get_rid() == mesh_rid,
		"repeated fly toggles never duplicate wing nodes or mesh resources")

	for i in range(48):
		rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.AIR,
			Vector3(12.0, 0.0, 0.0), false, Vector3.ZERO)
	_check(rig.has_angel_wings_visible() and rig._wing_unfold >= 0.99,
		"wings fully unfold within 0.8 seconds")
	var joints: Dictionary = rig.angel_wing_articulation_nodes()
	var joints_valid: bool = joints.left.shoulder != null \
		and joints.left.elbow != null and joints.left.wrist != null \
		and joints.right.shoulder != null and joints.right.elbow != null \
		and joints.right.wrist != null
	_check(joints_valid, "both wings expose shoulder, elbow, and wrist articulation")
	var expected_left_root := Vector3(-MonkeyRig.ANGEL_WING_ROOT_OFFSET.x,
		MonkeyRig.ANGEL_WING_ROOT_OFFSET.y, MonkeyRig.ANGEL_WING_ROOT_OFFSET.z)
	var expected_right_root := Vector3(MonkeyRig.ANGEL_WING_ROOT_OFFSET.x,
		MonkeyRig.ANGEL_WING_ROOT_OFFSET.y, MonkeyRig.ANGEL_WING_ROOT_OFFSET.z)
	_check(joints.left.shoulder.get_parent() == rig.torso_p \
		and joints.right.shoulder.get_parent() == rig.torso_p \
		and joints.left.shoulder.position.distance_to(expected_left_root) < 0.0001 \
		and joints.right.shoulder.position.distance_to(expected_right_root) < 0.0001,
		"wing roots use the exact lowered mid-back anchors")
	var attachment_error: float = absf(joints.left.shoulder.position.x
		+ joints.right.shoulder.position.x) \
		+ absf(joints.left.shoulder.position.y - joints.right.shoulder.position.y) \
		+ absf(joints.left.shoulder.position.z - joints.right.shoulder.position.z)
	_check(attachment_error <= 0.003,
		"wing roots attach symmetrically to the monkey's back")

	var level_root_min := INF
	var level_root_max := -INF
	var level_tip_min := INF
	var level_tip_max := -INF
	var max_symmetry_error := 0.0
	var max_joint_difference := 0.0
	var max_frame_step := 0.0
	var previous_root_z: float = joints.left.shoulder.rotation.z
	for i in range(210):
		rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.AIR,
			Vector3(12.0, 0.0, 0.0), false, Vector3.ZERO)
		var root_z: float = joints.left.shoulder.rotation.z
		level_root_min = minf(level_root_min, root_z)
		level_root_max = maxf(level_root_max, root_z)
		max_frame_step = maxf(max_frame_step,
			absf(angle_difference(previous_root_z, root_z)))
		previous_root_z = root_z
		var left_tip := _outermost_primary_tip(joints.left.wrist)
		var right_tip := _outermost_primary_tip(joints.right.wrist)
		level_tip_min = minf(level_tip_min, left_tip.y)
		level_tip_max = maxf(level_tip_max, left_tip.y)
		max_symmetry_error = maxf(max_symmetry_error,
			absf(left_tip.x + right_tip.x) + absf(left_tip.y - right_tip.y)
			+ absf(left_tip.z - right_tip.z))
		max_joint_difference = maxf(max_joint_difference,
			absf(joints.left.shoulder.rotation.z - joints.left.elbow.rotation.z)
			+ absf(joints.left.elbow.rotation.z - joints.left.wrist.rotation.z))
	var level_sweep := level_root_max - level_root_min
	var level_tip_travel := level_tip_max - level_tip_min
	_check(level_sweep >= deg_to_rad(7.0) and level_sweep <= deg_to_rad(14.0)
		and max_frame_step <= deg_to_rad(1.5),
		"level flight flaps gently with smooth frame-to-frame motion")
	_check(level_tip_travel >= 0.10 and level_tip_travel <= 0.36,
		"visible primary tips travel through a restrained aerodynamic stroke")
	_check(max_joint_difference >= deg_to_rad(1.0),
		"elbow and wrist lag prevents rigid fan-like motion")
	_check(max_symmetry_error <= 0.025,
		"left and right feather tips remain visually mirrored")

	var climb_root_min := INF
	var climb_root_max := -INF
	for i in range(180):
		rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.AIR,
			Vector3(8.0, 12.0, 0.0), false, Vector3.ZERO)
		climb_root_min = minf(climb_root_min, joints.left.shoulder.rotation.z)
		climb_root_max = maxf(climb_root_max, joints.left.shoulder.rotation.z)
	_check(climb_root_max - climb_root_min > level_sweep * 1.18,
		"climbing produces a slightly stronger wingbeat than level flight")

	rig.set_angel_wings(false)
	for i in range(45):
		rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.IDLE,
			Vector3.ZERO, true, Vector3.ZERO)
	_check(not rig.has_angel_wings_visible()
		and not joints.left.shoulder.visible and not joints.right.shoulder.visible,
		"folding removes both high-poly wings from rendering within 0.75 seconds")

	# Puppet weapons require a World-typed parent, but this focused fixture does
	# not need to build terrain or spawn any other actors.
	var puppet_world := World.new()
	add_child(puppet_world)
	var puppet := Puppet.new()
	puppet.setup(77, "RemoteWingTester")
	puppet_world.add_child(puppet)
	await get_tree().process_frame
	_apply_puppet_flight(puppet, true)
	for i in range(45):
		puppet.rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.AIR,
			Vector3(8.0, 2.0, 0.0), false, Vector3.ZERO)
	var remote_nodes := _wing_render_nodes(puppet.rig)
	var remote_shared := remote_nodes.size() == 6
	for child in remote_nodes:
		var remote_feathers := child as MultiMeshInstance3D
		remote_shared = remote_shared and remote_feathers.multimesh.mesh == shared_mesh
	_check(puppet.rig.has_angel_wings_visible() and remote_shared,
		"replicated flying state shows the same shared detailed wings")
	var remote_joints: Dictionary = puppet.rig.angel_wing_articulation_nodes()
	_check(remote_joints.left.shoulder.get_parent() == puppet.rig.torso_p \
		and remote_joints.right.shoulder.get_parent() == puppet.rig.torso_p \
		and remote_joints.left.shoulder.position.distance_to(
			joints.left.shoulder.position) < 0.0001 \
		and remote_joints.right.shoulder.position.distance_to(
			joints.right.shoulder.position) < 0.0001,
		"replicated wings use the exact local mid-back root placement")
	var remote_phase_before: float = puppet.rig._wing_flap_phase
	var remote_ids: Array[int] = []
	for child in remote_nodes:
		remote_ids.append(child.get_instance_id())
	for i in range(12):
		_apply_puppet_flight(puppet, true)
		for frame in range(3):
			puppet.rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.AIR,
				Vector3(8.0, 2.0, 0.0), false, Vector3.ZERO)
	var remote_ids_after: Array[int] = []
	for child in _wing_render_nodes(puppet.rig):
		remote_ids_after.append(child.get_instance_id())
	_check(puppet.rig._wing_flap_phase != remote_phase_before
		and remote_ids == remote_ids_after,
		"20 Hz multiplayer state refreshes neither reset phase nor rebuild wings")
	_apply_puppet_flight(puppet, false)
	for i in range(45):
		puppet.rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.AIR,
			Vector3(8.0, 2.0, 0.0), false, Vector3.ZERO)
	_check(not puppet.rig.has_angel_wings_visible(),
		"replicated flying=false folds remote wings on every peer")

	print("WINGTEST %d/%d %s build_ms=%.2f level_sweep_deg=%.2f tip_travel=%.3f" % [
		passed, total, "PASS" if passed == total else "FAIL", first_build_msec,
		rad_to_deg(level_sweep), level_tip_travel])
	rig.queue_free()
	puppet_world.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if passed == total else 1)


func _wing_render_nodes(rig: MonkeyRig) -> Array[Node]:
	var result: Array[Node] = []
	for child in rig.find_children("*", "MultiMeshInstance3D", true, false):
		if child.name in ["SecondaryFlightFeathers", "LayeredCoverts",
				"PrimariesCovertsAndAlula"]:
			result.append(child)
	return result


func _feather_cap_normal_directions(mesh_arrays: Array) -> Dictionary:
	var vertices: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = mesh_arrays[Mesh.ARRAY_INDEX]
	var root_y := 0.0
	var tip_y := 0.0
	var root_count := 0
	var tip_count := 0
	for i in range(0, indices.size(), 3):
		var p0 := vertices[indices[i]]
		var p1 := vertices[indices[i + 1]]
		var p2 := vertices[indices[i + 2]]
		# SurfaceTool/Godot uses clockwise front faces, hence p2 cross p1.
		var front_normal := (p2 - p0).cross(p1 - p0).normalized()
		if p0.y <= 0.0001 and p1.y <= 0.0001 and p2.y <= 0.0001:
			root_y += front_normal.y
			root_count += 1
		elif p0.y >= 0.9999 and p1.y >= 0.9999 and p2.y >= 0.9999:
			tip_y += front_normal.y
			tip_count += 1
	return {
		"root": root_y / float(maxi(root_count, 1)),
		"tip": tip_y / float(maxi(tip_count, 1)),
	}


func _outermost_primary_tip(wrist: Node3D) -> Vector3:
	var feathers := wrist.get_node("PrimariesCovertsAndAlula") \
		as MultiMeshInstance3D
	var farthest := wrist.global_position
	var farthest_x := -1.0
	for index in range(feathers.multimesh.instance_count):
		var local_tip: Vector3 = feathers.multimesh.get_instance_transform(index) \
			* Vector3.UP
		var world_tip := wrist.to_global(local_tip)
		if absf(world_tip.x) > farthest_x:
			farthest_x = absf(world_tip.x)
			farthest = world_tip
	return farthest


func _apply_puppet_flight(puppet: Puppet, flying: bool) -> void:
	puppet.apply_state(Vector3(4.0, 8.0, 2.0), 0.0,
		Vector3(8.0, 2.0, 0.0), MonkeyRig.Anim.AIR, false, Vector3.ZERO,
		0.0, PackedVector3Array(), Net.WEAPON_REVOLVER, false, false, 6,
		false, 0.0, flying)


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label)
