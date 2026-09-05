extends SceneTree
## Actual render-vertex dimensions, physics and lifecycle parity. Run with:
## godot --headless --path . --script res://tests/avatarheighttest.gd
var passed := 0
var total := 0

class Site extends Node3D:
	var water_fx = null
	var local_player: Node3D
	func surface_height(_x: float, _z: float) -> float: return 0.0
	func surface_normal(_x: float, _z: float) -> Vector3: return Vector3.UP
	func radial_up_at(_point: Vector3) -> Vector3: return Vector3.UP
	func worker_home_position() -> Vector3: return Vector3.ZERO

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, text: String) -> void:
	total += 1
	if ok: passed += 1
	print("AVATARHEIGHT %s %s" % ["PASS" if ok else "FAIL",text])

func bounds(rig) -> Vector2:
	var sole := INF
	var crown := -INF
	# Transform every submitted vertex; rotating an AABB would falsely enlarge
	# the spherical head and feet, and including a helmet would measure a hat.
	for node in rig.find_children("*", "MeshInstance3D", true, false):
		if node.name != "Foot" and node.name != "HeadShell": continue
		var local: Transform3D = rig.global_transform.affine_inverse() * node.global_transform
		for vertex: Vector3 in node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			var y := (local * vertex).y
			if node.name == "Foot": sole = minf(sole,y)
			else: crown = maxf(crown,y)
	return Vector2(sole,crown)

func ragdoll_bounds(doll) -> Vector2:
	var sole := INF
	var crown := -INF
	for body: RigidBody3D in doll._bodies:
		if body.name not in ["Head","LowerLegLeft","LowerLegRight"]: continue
		for node in body.find_children("*","MeshInstance3D",true,false):
			var local: Transform3D = doll.global_transform.affine_inverse()*node.global_transform
			for vertex: Vector3 in node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
				var y := (local*vertex).y
				if body.name=="Head": crown = maxf(crown,y)
				else: sole = minf(sole,y)
	return Vector2(sole,crown)

func _canonical_parts(rig: Node3D) -> Array[MeshInstance3D]:
	var parts: Array[MeshInstance3D] = []
	for mesh: MeshInstance3D in rig.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null or mesh.mesh is ImmediateMesh: continue
		var active := true
		var ancestor: Node = mesh
		while ancestor != rig:
			if ancestor is Node3D and not ancestor.visible and mesh.name != "WinterScarf": active = false
			ancestor = ancestor.get_parent()
		if active: parts.append(mesh)
	return parts

func _same_canonical_meshes(doll: Node3D, reference: Node3D) -> bool:
	var expected := _canonical_parts(reference)
	var actual := _canonical_parts(doll)
	if actual.size() != expected.size() or actual.size() < 50:
		print("CANONICAL_PART_COUNT actual=%d expected=%d"%[actual.size(),expected.size()]); return false
	var indices: Dictionary = {}
	for mesh: MeshInstance3D in actual:
		if mesh.get_meta("canonical_model", "") != "MonkeyRig" or mesh.layers != 1: return false
		var index: int = mesh.get_meta("canonical_index", -1)
		if index < 0 or index >= expected.size() or indices.has(index): return false
		indices[index] = true
		var source: MeshInstance3D = expected[index]
		if source.mesh.get_surface_count() != mesh.mesh.get_surface_count(): return false
		var wanted: Transform3D = reference.global_transform.affine_inverse() * source.global_transform
		var submitted: Transform3D = doll.global_transform.affine_inverse() * mesh.global_transform
		for surface in range(source.mesh.get_surface_count()):
			var original: Array = source.mesh.surface_get_arrays(surface)
			var copied: Array = mesh.mesh.surface_get_arrays(surface)
			if original != copied:
				print("CANONICAL_ARRAY_MISMATCH index=%d actual=%s expected=%s"%[index,mesh.name,source.name]); return false
			for vertex: Vector3 in original[Mesh.ARRAY_VERTEX]:
				if (wanted * vertex).distance_to(submitted * vertex) > .00002:
					print("CANONICAL_TRANSFORM_MISMATCH index=%d actual=%s expected=%s distance=%f"%[index,mesh.name,source.name,(wanted * vertex).distance_to(submitted * vertex)]); return false
	return true

func _physical_defeat(site: Node3D, doll_script) -> void:
	for detached: bool in [false, true]:
		var doll = doll_script.new()
		doll.process_mode = Node.PROCESS_MODE_ALWAYS
		doll.configure("Physical canonical defeat", Vector3(0, 3, 0), .3,
			Vector3(2, 0, 0), Vector3(3, 1, 0), detached)
		site.add_child(doll)
		var before: Vector3 = doll.torso.global_position
		var meshes := _canonical_parts(doll)
		var ids: Array = meshes.map(func(part): return part.mesh.get_instance_id())
		for frame in range(12): await physics_frame
		var following := true
		for part in meshes:
			var parent: Node = part.get_parent()
			while parent != doll and not parent is RigidBody3D: parent = parent.get_parent()
			following = following and parent is RigidBody3D and part.global_transform.is_finite()
		check(doll.torso.global_position.distance_to(before) > .03 and following \
			and meshes.map(func(part): return part.mesh.get_instance_id()) == ids \
			and (doll.get_node_or_null("NeckJoint") == null) == detached,
			"physical %s defeat keeps the same canonical meshes on moving limbs and the correct neck connection" % ("headshot" if detached else "body"))
		doll.queue_free()
		for frame in range(3): await physics_frame

func _rope_contacts(player, rig_script) -> void:
	for stature: float in [1.7018,1.8288,1.8796]:
		var rig = player.rig
		rig.reset_pose_state()
		rig.set_standing_height(stature)
		player.equip_weapon(4)
		player.state = player.S.SWING
		player.velocity = Vector3(8,0,0)
		player.swing_anchor = player.hand_pos()+Vector3.UP*4.0
		player._sync_weapon_presentation(true)
		rig.set_sniper_rope_pose(true,player.sniper.support_grip)
		rig.set_rope(true,player.swing_anchor,player.hand_pos(),0.0,player.velocity)
		rig.set_gun_aim(true,Vector3.FORWARD,0.0)
		for frame in range(75):
			rig.update_motion(1.0/60.0,rig_script.Anim.SWING,player.velocity,false,player.swing_anchor)
		var tip: Vector3 = rig.tail_segs[-1].to_global(Vector3(0,0,0.17))
		var tail_error := tip.distance_to(Geometry3D.get_closest_point_to_segment(
			tip,player.swing_anchor,player.hand_pos()))
		var left_foot: Vector3 = rig.foot_l.global_position
		var right_foot: Vector3 = rig.foot_r.global_position
		var feet_error := maxf(left_foot.distance_to(Geometry3D.get_closest_point_to_segment(
			left_foot,player.swing_anchor,player.hand_pos())),right_foot.distance_to(
			Geometry3D.get_closest_point_to_segment(right_foot,player.swing_anchor,player.hand_pos())))
		var left_error: float = rig.paw_l.global_position.distance_to(player.sniper.support_grip.global_position)
		var right_error: float = rig.paw_r.global_position.distance_to(player.sniper.primary_grip.global_position)
		check(left_error<0.005 and right_error<0.005,
			"%.4f m sniper hands contact the actual modeled rifle grips (left=%.6f right=%.6f m)" % [stature,left_error,right_error])
		check(tail_error<0.035 and feet_error<0.10,
			"%.4f m sniper tail and both feet brace the real zero-tail vine (tail=%.6f feet=%.6f m)" % [stature,tail_error,feet_error])
		var factor: float = stature/rig_script.REST_HEIGHT
		check(absf(rig.sh_l.global_position.distance_to(rig.el_l.global_position)-rig_script.ARM_A*factor)<0.00001 \
			and absf(rig.el_l.global_position.distance_to(rig.paw_l.global_position)-rig_script.ARM_B*factor)<0.00001 \
			and (-player.sniper.global_basis.z).normalized().dot(Vector3.FORWARD)>0.999,
			"%.4f m two-hand rifle pose retains anatomical arm lengths and exact barrel aim" % stature)

func _run() -> void:
	var rig_script = load("res://scripts/monkey_rig.gd")
	var site := Site.new()
	site.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(site)
	var player = load("res://scripts/player.gd").new()
	player.is_local = false
	player.world = site
	site.add_child(player)
	var player_bounds := bounds(player.rig)
	check(absf(player_bounds.x)<0.00001 and absf(player_bounds.y-1.8288)<0.00001,
		"player actual straight-standing vertices: sole=%.6f crown=%.6f m" % [player_bounds.x,player_bounds.y])
	check(absf(player._collision_shape.shape.height-1.8288)<0.00001 \
		and absf(player._collision_shape.position.y-0.9144)<0.00001 \
		and player.scale.is_equal_approx(Vector3.ONE),"upright capsule is1.8288 m with grounded bottom and unscaled physics root")
	check(player.head_hitbox.global_position.distance_to(player.rig.head_p.to_global(Vector3(0,0,-0.015)))<0.00001,
		"projectile head hit zone follows the scaled anatomical head")
	var camera_script = load("res://scripts/camera_rig.gd")
	var eye_y: float = player.rig.head_p.to_global(Vector3(0,0.043,0)).y
	check(absf(camera_script.FIRST_PERSON_HEIGHT-eye_y)<0.00001,
		"first-person eye height matches rendered eye center: %.6f m" % eye_y)
	var idle_min := INF
	var idle_max := -INF
	for frame in range(360):
		player.rig.update_motion(1.0/30.0,rig_script.Anim.IDLE,Vector3.ZERO,true,Vector3.ZERO)
		var b := bounds(player.rig)
		idle_min = minf(idle_min,b.y-b.x)
		idle_max = maxf(idle_max,b.y-b.x)
	check(idle_min>1.79 and idle_max<1.852,
		"12 seconds of relaxed idle retain natural posture within %.4f–%.4f m" % [idle_min,idle_max])
	player.rig.reset_pose_state()
	check(absf(bounds(player.rig).y-1.8288)<0.00001,"pose reset retains exact player stature")
	var puppet = load("res://scripts/puppet.gd").new()
	puppet.setup(27,"Other player")
	site.add_child(puppet)
	check(absf(bounds(puppet.rig).y-1.8288)<0.00001,"remote player has identical1.8288 m rendered stature")
	for actor_script: String in ["ai_monkey", "friendly_monkey"]:
		var actor = load("res://scripts/" + actor_script + ".gd").new()
		actor.is_ai = true; actor.is_local = false; actor.display_name = actor_script; actor.world = site
		site.add_child(actor)
		var actual := bounds(actor.rig)
		check(actor.rig.get_script() == rig_script and absf(actual.y-actual.x-rig_script.npc_height(actor_script)) < .00001,
			actor_script + " inherits exact player anatomy and identity-derived adult stature")
		actor.free()
	var merchant = load("res://scripts/moon_merchant.gd").new()
	site.add_child(merchant)
	var farmer = load("res://scripts/moon_farm_worker.gd").new()
	farmer.configure(site,site)
	site.add_child(farmer)
	for resident in [merchant,farmer]:
		var actual := bounds(resident.rig)
		check(resident.rig.get_script() == rig_script and actual.y-actual.x >= 1.70179 and actual.y-actual.x <= 1.87961 \
			and absf(resident._collision.shape.height-(actual.y-actual.x)) < .00001,
			resident.name + " uses canonical adult anatomy and matching physical height under lunar workwear")
	merchant.free(); farmer.free()
	var sim = load("res://scripts/frontier_sim.gd").new()
	sim.new_game(2026)
	var minimum := INF
	var maximum := -INF
	var consistent := true
	var stable_jobs := true
	for id: String in sim.state.citizens:
		var citizen = load("res://scripts/frontier_citizen.gd").new()
		citizen.configure(id,sim,site,sim.state.citizens[id].planet)
		site.add_child(citizen)
		citizen.build()
		citizen.rig.reset_pose_state()
		var b := bounds(citizen.rig)
		var height: float = b.y-b.x
		minimum = minf(minimum,height)
		maximum = maxf(maximum,height)
		consistent = consistent and absf(height-rig_script.npc_height(id))<0.00001
		var prior_job: String = sim.state.citizens[id].job
		sim.state.citizens[id].job = "cook" if prior_job!="cook" else "mechanic"
		citizen.update_citizen(0.0,Vector3.INF)
		citizen.rig.reset_pose_state()
		var updated := bounds(citizen.rig)
		stable_jobs = stable_jobs and absf((updated.y-updated.x)-height)<0.00001
		sim.state.citizens[id].job = prior_job
		citizen.free()
	check(consistent and minimum>=1.70179 and maximum<=1.87961,
		"all%d adult residents use identity-stable mesh heights %.4f–%.4f m" % [sim.state.citizens.size(),minimum,maximum])
	check(absf(minimum-1.7018)<0.00001 and absf(maximum-1.8796)<0.00001,
		"resident distribution spans both requested adult endpoints")
	check(stable_jobs,"job changes, rebuilt workwear and lunar helmets preserve anatomical height")
	check(rig_script.npc_height("nana")<1.8288,"Nana stands slightly shorter than the player")
	# A real analytic world-space solve must reach a reachable control without
	# shrinking the upper arm back to its old authored metre length.
	var rig = player.rig
	var target: Vector3 = rig.sh_l.global_position+Vector3(-0.22,-0.43,-0.12)
	rig._ik_limb(rig.sh_l,rig.el_l,rig_script.ARM_A,rig_script.ARM_B,target,Vector3.LEFT)
	check(rig.paw_l.global_position.distance_to(target)<0.00001 \
		and absf(rig.sh_l.global_position.distance_to(rig.el_l.global_position)-rig_script.ARM_A*rig_script.PLAYER_SCALE)<0.00001,
		"world-space control IK reaches the target with correctly scaled upper and lower arms")
	for seated: int in [rig_script.Anim.RIDE,rig_script.Anim.PILOT,rig_script.Anim.CABIN]:
		rig.reset_pose_state()
		rig.set_yaw(0.37)
		# Carry actual running sway into the first seated blend; all three axes
		# must retain the authored pelvis, not only its height above the cushion.
		for frame in range(8):
			rig.update_motion(1.0/30.0,rig_script.Anim.RUN,Vector3(3,0,-5),true,Vector3.ZERO)
		rig.update_motion(1.0/30.0,seated,Vector3.ZERO,true,Vector3.ZERO)
		check(rig.to_local(rig.hips.global_position).distance_to(rig.yaw_node.transform*rig.hips.position)<0.00001,
			"seated mode%d preserves the full authored pelvis position through running sway" % seated)
	rig.reset_pose_state()
	check(absf(bounds(rig).y-1.8288)<0.00001,"leaving the seated pose restores1.8288 m standing anatomy")
	var doll_script = load("res://scripts/monkey_ragdoll.gd")
	for stature: float in [1.7018,1.8288,1.8796]:
		var doll = doll_script.new()
		# Rigid bodies must join their actual physics space before PinJoint3D
		# connects them; the presentation-only parent deliberately has no process.
		doll.process_mode = Node.PROCESS_MODE_ALWAYS
		doll.configure("Height test",Vector3.ZERO,0.37,Vector3.ZERO,Vector3.ZERO,
			false,Basis(Vector3.RIGHT,0.32),stature)
		site.add_child(doll)
		var b := ragdoll_bounds(doll)
		check(absf(b.x)<0.00001 and absf(b.y-stature)<0.00001,
			"ragdoll actual vertices retain %.4f m anatomy on a tilted surface" % stature)
		var unit_bases := true
		var shapes_match := true
		var factor: float = stature/doll_script.REST_HEIGHT
		for body: RigidBody3D in doll._bodies:
			unit_bases = unit_bases and body.global_basis.get_scale().is_equal_approx(Vector3.ONE)
			for child in body.get_children():
				if not child is CollisionShape3D: continue
				unit_bases = unit_bases and child.scale.is_equal_approx(Vector3.ONE)
				if body.name=="Torso":
					shapes_match = shapes_match and absf(child.shape.height-0.58*factor)<0.00001 \
						and absf(child.shape.radius-0.20*factor)<0.00001
				elif body.name=="Head":
					shapes_match = shapes_match and absf(child.shape.radius-0.18*factor)<0.00001
		check(unit_bases and shapes_match,
			"%.4f m ragdoll uses scaled collision dimensions and unit rigid-body bases" % stature)
		var reference = rig_script.new()
		site.add_child(reference)
		reference.setup("Height test", false)
		reference.set_standing_height(stature)
		reference.reset_pose_state()
		check(_same_canonical_meshes(doll, reference),
			"%.4f m ragdoll submits every original player-model vertex and exact rest transform, including the full furry tail" % stature)
		reference.free()
		doll.free()
	await _physical_defeat(site,doll_script)
	_rope_contacts(player,rig_script)
	site.free()
	await process_frame
	print("AVATARHEIGHTTEST %d/%d %s" % [passed,total,"PASS" if passed==total else "FAIL"])
	quit(0 if passed==total else 1)
