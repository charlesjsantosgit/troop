extends Node
## Spherical-world visual and ballistic contracts without rendering a window.

var passed := 0
var total := 0


func _check(ok: bool, label: String) -> void:
	total += 1
	passed += int(ok)
	print(("  [ok] " if ok else "  [FAIL] ") + label)


func run(_main = null) -> void:
	var tree := get_tree()
	var stage := Node3D.new()
	tree.root.add_child(stage)
	var reference := MonkeyRig.new()
	reference.setup("Surface reference", false)
	stage.add_child(reference)
	var turned := MonkeyRig.new()
	turned.setup("Surface rotated", false)
	stage.add_child(turned)
	await tree.process_frame
	var orientations := [Basis(Vector3.FORWARD, PI * 0.5),
		Basis(Vector3.RIGHT, PI), Basis(Vector3(1.0, 2.0, 3.0).normalized(), 2.1)]
	var poses_match := true
	var facing_matches := true
	for orientation: Basis in orientations:
		turned.global_basis = orientation
		for mode in range(4):
			reference.reset_pose_state(false)
			turned.reset_pose_state(false)
			turned.global_basis = orientation
			reference._phase = 0.0
			turned._phase = 0.0
			reference._t = 0.0
			turned._t = 0.0
			var aim := Vector3(0.15, 0.25, -1.0).normalized()
			reference.set_gun_aim(mode == 0, aim, 0.2)
			turned.set_gun_aim(mode == 0, orientation * aim, 0.2)
			reference.set_healing_pose(mode == 1, 0.48)
			turned.set_healing_pose(mode == 1, 0.48)
			reference.set_melee_pose(mode == 2, mode == 2, 0.42, 2)
			turned.set_melee_pose(mode == 2, mode == 2, 0.42, 2)
			var anim := MonkeyRig.Anim.SPRINT if mode == 3 else MonkeyRig.Anim.IDLE
			for frame in range(36):
				reference.update_motion(1.0 / 60.0, anim, Vector3(0, 0, -11), true, Vector3.ZERO)
				turned.update_motion(1.0 / 60.0, anim, orientation * Vector3(0, 0, -11), true, Vector3.ZERO)
			var original_contacts := reference.limb_contact_points()
			var turned_contacts := turned.limb_contact_points()
			for contact in range(4):
				poses_match = poses_match and reference.to_local(original_contacts[contact]).distance_to(
					turned.to_local(turned_contacts[contact])) < 0.004
		turned.set_yaw(0.0)
		turned.face(orientation * Vector3.RIGHT, 1.0)
		facing_matches = facing_matches and absf(angle_difference(turned.yaw_angle(), -PI * 0.5)) < 0.001
	_check(poses_match, "weapon, healing, melee and sprint poses rotate intact on side and underside hemispheres")
	_check(facing_matches, "world facing direction is converted into the radial actor frame")
	# The real Moon sits near world Y=48000. World-transform writes can appear
	# correct at the origin while rounding repeatedly moves fixed joint anchors
	# metres apart there. Exercise prolonged aiming and four-limb ground IK in
	# the actual translated frame, including each hemisphere orientation.
	var distant_anchors_stable := true
	var distant_limbs_attached := true
	var greatest_anchor_drift := 0.0
	for orientation: Basis in orientations:
		for mode in range(3):
			turned.reset_pose_state(false)
			turned.global_transform = Transform3D(orientation, Vector3(57.0, 47992.0, -39.0))
			var fixed_joints: Array[Node3D] = [turned.sh_l, turned.sh_r,
				turned.el_l, turned.el_r, turned.hip_l, turned.hip_r,
				turned.kn_l, turned.kn_r, turned.foot_l, turned.foot_r]
			var positions: Array[Vector3] = []
			for joint in fixed_joints:
				positions.append(joint.position)
			turned.set_gun_aim(mode == 0, orientation * Vector3(0.15, 0.25, -1.0).normalized(), 0.2)
			turned.set_healing_pose(mode == 1, 0.48)
			var anim := MonkeyRig.Anim.SPRINT if mode == 2 else MonkeyRig.Anim.IDLE
			for frame in range(720):
				turned.update_motion(1.0 / 60.0, anim,
					orientation * Vector3(0, 0, -11), true, Vector3.ZERO)
			for index in range(fixed_joints.size()):
				var joint := fixed_joints[index]
				greatest_anchor_drift = maxf(greatest_anchor_drift,
					joint.position.distance_to(positions[index]))
				distant_anchors_stable = distant_anchors_stable \
					and joint.position.distance_to(positions[index]) < 0.0001
				distant_limbs_attached = distant_limbs_attached \
					and joint.global_position.distance_to(turned.global_position) < 1.8
	_check(distant_anchors_stable,
		"prolonged lunar aiming, healing and sprinting preserve exact anatomical anchors (drift %.6f m)" % greatest_anchor_drift)
	_check(distant_limbs_attached,
		"hands, weapon mount and feet remain attached after long animations at the actual lunar world origin")
	var net := tree.root.get_node("Net")
	var previous_realm: Variant = net.player_realms.get(77)
	net.player_realms[77] = net.PlayerRealm.MOON
	var puppet := Puppet.new()
	puppet.setup(77, "Moon replica")
	stage.add_child(puppet)
	puppet.set_process(false)
	var bullet := BananaBullet.new()
	stage.add_child(bullet)
	bullet.set_physics_process(false)
	bullet._lunar_projectile = true
	var center := MoonWorld.PLAYABLE_CENTER + Vector3(0, net.MOON_WORLD_ORIGIN_Y, 0)
	var replica_up_ok := true
	var gravity_ok := true
	var zero_ok := true
	for radial: Vector3 in [Vector3.UP, Vector3.DOWN, Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		puppet.global_position = center + radial * MoonWorld.PLAYABLE_RADIUS_METERS
		puppet._sync_surface_basis()
		replica_up_ok = replica_up_ok and puppet.global_basis.y.dot(radial) > 0.999
		bullet.global_position = puppet.global_position
		gravity_ok = gravity_ok and bullet.projectile_gravity().distance_to(-radial * MoonWorld.LUNAR_GRAVITY) < 0.001
		var forward := -MoonWorld.surface_basis(radial).z
		var direction := SniperRifle.zeroed_direction(forward, MoonWorld.LUNAR_GRAVITY, radial)
		var time := SniperRifle.ZERO_DISTANCE / SniperRifle.MUZZLE_SPEED
		var offset := direction * SniperRifle.MUZZLE_SPEED * time - radial * 0.5 * MoonWorld.LUNAR_GRAVITY * time * time
		zero_ok = zero_ok and absf(offset.dot(radial)) < 0.002
	_check(replica_up_ok, "remote monkey roots point outward across all six globe directions")
	_check(gravity_ok, "lunar projectile acceleration points toward the center on every hemisphere")
	_check(zero_ok, "lunar sniper zero follows local up and lunar acceleration")
	var before_pole := Vector3(0, 0.001, -1).normalized()
	var after_pole := Vector3(0, -0.001, -1).normalized()
	puppet.global_position = center + before_pole * MoonWorld.PLAYABLE_RADIUS_METERS
	puppet._sync_surface_basis()
	puppet.rig.set_yaw(0.41)
	var before_facing := -puppet.rig.yaw_node.global_basis.z
	puppet.global_position = center + after_pole * MoonWorld.PLAYABLE_RADIUS_METERS
	puppet._sync_surface_basis()
	_check(before_facing.dot(-puppet.rig.yaw_node.global_basis.z) > 0.999,
		"remote heading remains continuous through the canonical tangent-frame pole seam")
	if previous_realm == null:
		net.player_realms.erase(77)
	else:
		net.player_realms[77] = previous_realm
	stage.queue_free()
	await tree.process_frame
	await tree.process_frame
	print("LUNARCOMBATPRESENTATIONTEST %d/%d %s" % [passed, total, "PASS" if passed == total else "FAIL"])
	tree.quit(0 if passed == total else 1)
