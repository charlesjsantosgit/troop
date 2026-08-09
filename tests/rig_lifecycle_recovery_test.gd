extends SceneTree
## Focused regression for the reported vehicle/death pose corruption:
##   godot --headless --path . --script res://tests/rig_lifecycle_recovery_test.gd

var passed := 0
var total := 0


class TestWorld:
	extends Node3D
	var vehicles: Dictionary = {}
	var water_fx = null

	func vehicle_by_id(vehicle_id: String):
		return vehicles.get(vehicle_id)

	func apply_remote_vehicle_state(_peer_id: int, _vehicle_kind: int,
			_vehicle_id: String, _position: Vector3, _yaw: float,
			_aux: Vector3, _velocity: Vector3) -> void:
		pass


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String, info := "") -> void:
	total += 1
	if ok:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label + ((" :: " + info) if info != "" else ""))


func _rest_deviation_count(rig, expected_yaw := 0.0,
		preserve_yaw := false) -> int:
	var deviations := 0
	for index in range(mini(rig._pose_rest_nodes.size(),
			rig._pose_rest_transforms.size())):
		var node: Node3D = rig._pose_rest_nodes[index]
		var expected: Transform3D = rig._pose_rest_transforms[index]
		if preserve_yaw and node == rig.yaw_node:
			expected.basis = Basis(Vector3.UP, expected_yaw)
		if node.top_level or not node.transform.is_equal_approx(expected):
			deviations += 1
	return deviations


func _compact_hierarchy(rig) -> bool:
	if rig.top_level or rig.physics_interpolation_mode \
			!= Node.PHYSICS_INTERPOLATION_MODE_INHERIT:
		return false
	if not rig.transform.is_equal_approx(Transform3D.IDENTITY):
		return false
	var root_position: Vector3 = rig.global_position
	for node: Node3D in rig._pose_rest_nodes:
		if not node.global_position.is_finite() \
				or node.global_position.distance_to(root_position) > 2.1:
			return false
	var contacts: PackedVector3Array = rig.limb_contact_points()
	if contacts.size() != 4:
		return false
	for contact: Vector3 in contacts:
		if not contact.is_finite() or contact.distance_to(root_position) > 1.8:
			return false
	return true


func _corrupt_entire_pose(rig, yaw: float) -> void:
	rig.top_level = true
	rig.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	rig.global_transform = Transform3D(
		Basis(Vector3(0.33, 0.81, -0.19).normalized(), 2.17),
		rig.global_position + Vector3(130.0, 72.0, -96.0))
	for index in range(rig._pose_rest_nodes.size()):
		var node: Node3D = rig._pose_rest_nodes[index]
		node.top_level = true
		var axis := Vector3(
			0.31 + float(index % 3) * 0.17,
			0.73 - float(index % 5) * 0.08,
			-0.27 + float(index % 7) * 0.06).normalized()
		node.transform = Transform3D(Basis(axis, 1.1 + index * 0.071),
			Vector3(18.0 + index * 1.7, -13.0 + index * 0.9,
				25.0 - index * 1.3))
	# begin_defeat intentionally preserves the visible heading while clearing all
	# other vehicle/IK state, so author the expected heading after corruption.
	rig.yaw_node.top_level = false
	rig.set_yaw(yaw)
	rig._vehicle_pose = RefCounted.new()
	rig._ride_lean = 0.94
	rig._rope_active = true
	rig._gun_aim_active = true


func _script_constant(instance, constant_name: StringName):
	return instance.get_script().get_script_constant_map().get(constant_name)


func _script_enum(instance, enum_name: StringName, value_name: StringName) -> int:
	var values: Dictionary = _script_constant(instance, enum_name)
	return int(values.get(value_name, -1))


func _apply_remote_state(puppet, position: Vector3,
		anim: int, vehicle_kind := -1, vehicle_id := "") -> void:
	var net := root.get_node("Net")
	var weapon_revolver := int(_script_constant(net, &"WEAPON_REVOLVER"))
	puppet.apply_state(position, 0.42, Vector3(4.0, -1.0, 2.0), anim,
		false, Vector3.ZERO, 0.0, PackedVector3Array(),
		weapon_revolver, false, false, 6, false, 0.0, false,
		vehicle_kind, vehicle_id, Vector3.ZERO)


func _run() -> void:
	print("RIG LIFECYCLE RECOVERY TEST")
	var stage := TestWorld.new()
	stage.name = "RigLifecycleStage"
	root.add_child(stage)

	# Runtime loads are deliberate: standalone SceneTree scripts are parsed before
	# project autoload names exist. Deferring production script compilation until
	# this point matches the initialized main-scene test environment.
	var fighter_jet_script: Script = load("res://scripts/fighter_jet.gd")
	var player_script: Script = load("res://scripts/player.gd")
	var puppet_script: Script = load("res://scripts/puppet.gd")
	_check(fighter_jet_script.can_instantiate() \
			and player_script.can_instantiate() and puppet_script.can_instantiate(),
		"vehicle and actor lifecycle scripts compile after autoload initialization")
	if not fighter_jet_script.can_instantiate() \
			or not player_script.can_instantiate() or not puppet_script.can_instantiate():
		print("RIG LIFECYCLE RECOVERY TEST %d/%d FAIL" % [passed, total])
		quit(1)
		return

	var jet = fighter_jet_script.new()
	jet.name = "LifecycleJet"
	jet.freeze = true
	# The focused harness has no graphics-quality controller; a null vehicle
	# world leaves exhaust at its safe default quality while player/puppet world
	# integration still uses TestWorld below.
	jet.setup("test:lifecycle#jet", null)
	stage.vehicles[jet.vid] = jet
	stage.add_child(jet)

	var player = player_script.new()
	player.name = "LifecycleLocalPlayer"
	player.display_name = "LifecycleLocal"
	player.is_local = true
	player.test_mode = true
	player.world = stage
	stage.add_child(player)
	await physics_frame
	await process_frame
	player.set_physics_process(false)
	player.set_process(false)
	if player.cam:
		player.cam.set_process(false)

	_check(player.rig._pose_rest_nodes.size() >= 25,
		"rig captures all articulated limb, tail, and prop rest transforms",
		"captured=%d" % player.rig._pose_rest_nodes.size())
	_check(jet.rider_targets.size() == 4,
		"fighter jet exposes all four real pilot IK contacts",
		"targets=%d" % jet.rider_targets.size())

	# Exercise the same world-space rider transform and PILOT IK used during an
	# actual local flight, then leave via MonkeyPlayer.exit_vehicle.
	player.enter_vehicle(jet)
	player.rig.physics_interpolation_mode = \
		Node.PHYSICS_INTERPOLATION_MODE_OFF
	player.rig.top_level = true
	player.rig.set_yaw(0.0)
	player.rig.set_vehicle_pose(jet.rider_render_pose())
	player.rig.global_transform = jet.rider_render_transform()
	var pilot_anim := _script_enum(player.rig, &"Anim", &"PILOT")
	for _frame in range(4):
		player.rig.update_motion(1.0 / 60.0, pilot_anim,
			jet.linear_velocity, true, Vector3.ZERO)
	var piloting_deviations := _rest_deviation_count(player.rig)
	_check(player.vehicle == jet and jet.driver == player \
			and piloting_deviations >= 8,
		"real jet pilot pose writes a substantial world-space IK pose",
		"deviated joints=%d" % piloting_deviations)
	player.exit_vehicle(true)
	var exit_deviations := _rest_deviation_count(player.rig)
	_check(player.vehicle == null and jet.driver == null \
			and exit_deviations == 0 and _compact_hierarchy(player.rig) \
			and player._collision_shape.disabled == false \
			and player.collision_layer == 1 and player.collision_mask == 1,
		"aircraft exit restores every joint, root mode, and player collision",
		"remaining joint deviations=%d" % exit_deviations)

	# A lethal hit can arrive before the ordinary dismount input. That path must
	# release the aircraft and restore the exact same IK state before hiding the
	# live rig and spawning its ragdoll presentation.
	player.enter_vehicle(jet)
	player.rig.physics_interpolation_mode = \
		Node.PHYSICS_INTERPOLATION_MODE_OFF
	player.rig.top_level = true
	player.rig.set_vehicle_pose(jet.rider_render_pose())
	player.rig.global_transform = jet.rider_render_transform()
	player.rig.update_motion(1.0 / 60.0, pilot_anim,
		jet.linear_velocity, true, Vector3.ZERO)
	player.velocity = Vector3(31.0, -12.0, 8.0)
	player.begin_defeat("body", Vector3(-3.0, 2.0, 1.0))
	var mounted_death_deviations := _rest_deviation_count(
		player.rig, player.rig.yaw_angle(), true)
	var mounted_death_ok: bool = player.vehicle == null and jet.driver == null \
		and player.defeated and not player.rig.visible \
		and mounted_death_deviations == 0 and not player.rig.top_level
	player.revive_at(Vector3(2.0, 1.0, 3.0))
	mounted_death_ok = mounted_death_ok \
		and _rest_deviation_count(player.rig) == 0 \
		and _compact_hierarchy(player.rig) and player.rig.visible \
		and not player.defeated
	_check(mounted_death_ok,
		"death while piloting releases the jet and revives a complete monkey",
		"remaining joint deviations=%d" % mounted_death_deviations)

	# Repeated deaths in one session must work without the canopy reconnect that
	# previously rebuilt the rig as an accidental recovery mechanism.
	var local_cycles_ok := true
	var local_cycle_info := ""
	for cycle in range(2):
		var death_yaw := 0.37 + float(cycle) * 0.91
		_corrupt_entire_pose(player.rig, death_yaw)
		player.velocity = Vector3(18.0, -42.0, -11.0)
		player.begin_defeat("body", Vector3(1.0, 2.0, -3.0))
		var defeat_deviations := _rest_deviation_count(
			player.rig, death_yaw, true)
		var defeat_ok: bool = player.defeated and player.rig.visible == false \
			and player.death_ragdoll != null and defeat_deviations == 0 \
			and player.rig.top_level == false
		player.revive_at(Vector3(4.0 + cycle * 3.0, 1.0, -2.0))
		var revive_deviations := _rest_deviation_count(player.rig)
		var revive_ok: bool = not player.defeated \
			and not player._defeat_presentation_started \
			and player.rig.visible and player.death_ragdoll == null \
			and player.body_hitbox.collision_layer == 2 \
			and player.head_hitbox.collision_layer == 2 \
			and revive_deviations == 0 and _compact_hierarchy(player.rig)
		if not defeat_ok or not revive_ok:
			local_cycle_info += "cycle %d defeat_dev=%d revive_dev=%d; " % [
				cycle + 1, defeat_deviations, revive_deviations]
		local_cycles_ok = local_cycles_ok and defeat_ok and revive_ok
	_check(local_cycles_ok,
		"two local death/revive cycles reset every body part without reconnecting",
		local_cycle_info)

	# Remote replicas take a different lifecycle: their process loop owns
	# vehicle dismount and a fresh state packet ends the defeat presentation.
	var puppet = puppet_script.new()
	puppet.name = "LifecycleRemotePuppet"
	puppet.setup(77, "LifecycleRemote")
	stage.add_child(puppet)
	await process_frame
	puppet.set_process(false)
	var remote_pilot_anim := _script_enum(puppet.rig, &"Anim", &"PILOT")
	var remote_idle_anim := _script_enum(puppet.rig, &"Anim", &"IDLE")
	_apply_remote_state(puppet, jet.seat_global(), remote_pilot_anim,
		int(jet.kind), jet.vid)
	puppet._process(1.0 / 60.0)
	var remote_mount_deviations := _rest_deviation_count(puppet.rig)
	_check(puppet.rig.top_level \
			and puppet.rig.physics_interpolation_mode \
				== Node.PHYSICS_INTERPOLATION_MODE_OFF \
			and remote_mount_deviations >= 8,
		"remote jet state enters the real top-level pilot IK presentation",
		"deviated joints=%d" % remote_mount_deviations)
	# Add extreme stale offsets on top of the legitimate pilot pose to prove the
	# first on-foot packet cannot retain even one detached remote limb.
	_corrupt_entire_pose(puppet.rig, 1.2)
	_apply_remote_state(puppet, Vector3(16.0, 2.0, 9.0), remote_idle_anim)
	puppet._process(1.0 / 60.0)
	_check(puppet._vehicle_kind == -1 and puppet._vehicle_id.is_empty() \
			and puppet.rig._vehicle_pose == null \
			and _compact_hierarchy(puppet.rig),
		"first remote on-foot packet fully recovers a corrupted jet dismount")

	var remote_cycles_ok := true
	var remote_cycle_info := ""
	for cycle in range(2):
		var death_yaw := -0.44 + float(cycle) * 1.13
		_corrupt_entire_pose(puppet.rig, death_yaw)
		puppet.begin_defeat(puppet.global_position, death_yaw,
			Vector3(7.0, -16.0, 3.0), Vector3(-2.0, 1.0, 4.0), false)
		var defeat_deviations := _rest_deviation_count(
			puppet.rig, death_yaw, true)
		var defeat_ok: bool = puppet.defeated_visual \
			and puppet.rig.visible == false and puppet.death_ragdoll != null \
			and defeat_deviations == 0
		puppet._defeat_guard_t = 0.0
		_apply_remote_state(puppet,
			Vector3(21.0 + cycle, 2.0, -5.0), remote_idle_anim)
		var revive_deviations := _rest_deviation_count(puppet.rig)
		var revive_ok: bool = not puppet.defeated_visual and puppet.rig.visible \
			and puppet.death_ragdoll == null \
			and puppet.body_hitbox.collision_layer == 2 \
			and puppet.head_hitbox.collision_layer == 2 \
			and revive_deviations == 0 and _compact_hierarchy(puppet.rig)
		if not defeat_ok or not revive_ok:
			remote_cycle_info += "cycle %d defeat_dev=%d revive_dev=%d; " % [
				cycle + 1, defeat_deviations, revive_deviations]
		remote_cycles_ok = remote_cycles_ok and defeat_ok and revive_ok
	_check(remote_cycles_ok,
		"two remote death/state-revive cycles reset every replicated body part",
		remote_cycle_info)

	stage.queue_free()
	await process_frame
	await process_frame
	print("RIG LIFECYCLE RECOVERY TEST %d/%d %s" % [
		passed, total, "PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)
