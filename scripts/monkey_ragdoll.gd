class_name MonkeyRagdoll
extends Node3D
## A physical articulated copy of the actual player model. Existing rigid-body
## joints own motion; visible parts are transferred directly from MonkeyRig.
## Lethal headshots omit the neck joint so the head moves independently.

const TORSO_CENTER := Vector3(0, 0.86, 0)
const HEAD_CENTER := Vector3(0, 1.18, 0)
const SHOULDER_Y := 1.06
const HIP_Y := 0.58
const REST_SOLE_Y := 0.17 - MonkeyRig.LEG_B * 0.52 - 0.075 * 0.55
const REST_HEIGHT := HEAD_CENTER.y + 0.18 - REST_SOLE_Y

var torso: RigidBody3D
var head: RigidBody3D
var winter_scarf: MeshInstance3D
var head_detached := false

var _display_name := "Monkey"
var _spawn_position := Vector3.ZERO
var _spawn_yaw := 0.0
var _surface_basis := Basis.IDENTITY
var _initial_velocity := Vector3.ZERO
var _impact_impulse := Vector3.ZERO
var _configured := false
var _bodies: Array[RigidBody3D] = []
var standing_height := MonkeyRig.PLAYER_HEIGHT


func configure(display_name: String, spawn_position: Vector3, spawn_yaw: float,
		initial_velocity: Vector3, impact_impulse: Vector3,
		detach_head: bool, surface_basis: Basis = Basis.IDENTITY,
		height_metres: float = MonkeyRig.PLAYER_HEIGHT) -> void:
	_display_name = display_name
	_spawn_position = spawn_position
	_spawn_yaw = spawn_yaw
	_surface_basis = surface_basis.orthonormalized()
	_initial_velocity = initial_velocity
	_impact_impulse = impact_impulse
	head_detached = detach_head
	standing_height = clampf(height_metres, MonkeyRig.NPC_MIN_HEIGHT, MonkeyRig.NPC_MAX_HEIGHT)
	_configured = true


func _ready() -> void:
	if not _configured:
		return
	add_to_group("monkey_ragdolls")
	global_transform = Transform3D(_surface_basis * Basis(Vector3.UP, _spawn_yaw),
		_spawn_position)
	_build()
	_apply_stature()
	_install_canonical_visuals()
	_release_bodies()


func follow_target() -> Node3D:
	return torso


func _build() -> void:
	# Keep the proven rigid-body masses, collision dimensions and joint layout.
	# No independently authored body/face/tail render geometry is created here.
	torso = _body("Torso", TORSO_CENTER, 2.2)
	_add_capsule_collision(torso, 0.20, 0.58)
	head = _body("Head", HEAD_CENTER, 0.72)
	_add_sphere_collision(head, 0.18)
	var upper_arm_left := _limb("UpperArmLeft", Vector3(0.245, 0.93, 0), 0.058, MonkeyRig.ARM_A, 0.34)
	var lower_arm_left := _limb("LowerArmLeft", Vector3(0.27, 0.68, 0), 0.052, MonkeyRig.ARM_B, 0.26)
	var upper_arm_right := _limb("UpperArmRight", Vector3(-0.245, 0.93, 0), 0.058, MonkeyRig.ARM_A, 0.34)
	var lower_arm_right := _limb("LowerArmRight", Vector3(-0.27, 0.68, 0), 0.052, MonkeyRig.ARM_B, 0.26)
	var upper_leg_left := _limb("UpperLegLeft", Vector3(0.115, 0.44, 0), 0.068, MonkeyRig.LEG_A, 0.52)
	var lower_leg_left := _limb("LowerLegLeft", Vector3(0.115, 0.17, 0), 0.058, MonkeyRig.LEG_B, 0.42)
	var upper_leg_right := _limb("UpperLegRight", Vector3(-0.115, 0.44, 0), 0.068, MonkeyRig.LEG_A, 0.52)
	var lower_leg_right := _limb("LowerLegRight", Vector3(-0.115, 0.17, 0), 0.058, MonkeyRig.LEG_B, 0.42)

	if not head_detached:
		_joint("NeckJoint", torso, head, Vector3(0, 1.08, 0))
	_joint("ShoulderLeftJoint", torso, upper_arm_left,
		Vector3(0.225, SHOULDER_Y, 0))
	_joint("ElbowLeftJoint", upper_arm_left, lower_arm_left,
		Vector3(0.26, 0.80, 0))
	_joint("ShoulderRightJoint", torso, upper_arm_right,
		Vector3(-0.225, SHOULDER_Y, 0))
	_joint("ElbowRightJoint", upper_arm_right, lower_arm_right,
		Vector3(-0.26, 0.80, 0))
	_joint("HipLeftJoint", torso, upper_leg_left, Vector3(0.115, HIP_Y, 0))
	_joint("KneeLeftJoint", upper_leg_left, lower_leg_left,
		Vector3(0.115, 0.30, 0))
	_joint("HipRightJoint", torso, upper_leg_right, Vector3(-0.115, HIP_Y, 0))
	_joint("KneeRightJoint", upper_leg_right, lower_leg_right,
		Vector3(-0.115, 0.30, 0))


func _install_canonical_visuals() -> void:
	var source := MonkeyRig.new()
	source.name = "CanonicalDeathModelSource"
	source.visible = false
	add_child(source)
	source.setup(_display_name, false)
	source.set_standing_height(standing_height)
	source.reset_pose_state()
	# The longstanding physics body names use the opposite left/right convention.
	# Associate by the actual signed anatomical side; meshes keep their complete
	# world transforms, materials and vertex data while moving to physical bodies.
	var owners: Array = [
		[source.head_p, head],
		[source.el_l, get_node("LowerArmRight")], [source.sh_l, get_node("UpperArmRight")],
		[source.el_r, get_node("LowerArmLeft")], [source.sh_r, get_node("UpperArmLeft")],
		[source.kn_l, get_node("LowerLegRight")], [source.hip_l, get_node("UpperLegRight")],
		[source.kn_r, get_node("LowerLegLeft")], [source.hip_r, get_node("UpperLegLeft")]]
	var smile := Node3D.new()
	smile.name = "Smile"
	head.add_child(smile)
	var parts: Array = []
	for mesh: MeshInstance3D in source.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null or mesh.mesh is ImmediateMesh: continue
		var scarf := mesh.name == "WinterScarf"
		var visible_part := true
		var ancestor: Node = mesh
		var is_smile := false
		while ancestor != source:
			if ancestor is Node3D and not ancestor.visible and not scarf: visible_part = false
			is_smile = is_smile or ancestor.name == "Smile"
			ancestor = ancestor.get_parent()
		if not visible_part: continue
		var owner_body: Node3D = torso
		for pair in owners:
			if pair[0].is_ancestor_of(mesh):
				owner_body = pair[1]
				break
		parts.append([mesh, smile if is_smile else owner_body, str(source.get_path_to(mesh))])
	for index in range(parts.size()):
		var part: Array = parts[index]
		var mesh: MeshInstance3D = part[0]
		mesh.reparent(part[1], true)
		mesh.layers = 1
		mesh.set_meta("canonical_model", "MonkeyRig")
		mesh.set_meta("canonical_source", part[2])
		mesh.set_meta("canonical_index", index)
		if mesh.name == "WinterScarf": winter_scarf = mesh
	set_meta("canonical_model", "MonkeyRig")
	set_meta("canonical_parts", parts.size())
	source.free()


func set_winter_scarf_visible(active: bool) -> void:
	if winter_scarf:
		winter_scarf.visible = active


func _apply_stature() -> void:
	# Physics bodies keep an orthonormal transform. Scale their actual shapes
	# and visual children instead, so defeat does not shrink the character or
	# leave small invisible collision bodies inside the taller visible limbs.
	var factor := standing_height / REST_HEIGHT
	for body: RigidBody3D in _bodies:
		body.position = (body.position - Vector3.UP * REST_SOLE_Y) * factor
		for child: Node in body.get_children():
			if not child is Node3D:
				continue
			child.position *= factor
			if child is CollisionShape3D:
				child.shape = child.shape.duplicate()
				if child.shape is CapsuleShape3D:
					child.shape.height *= factor
					child.shape.radius *= factor
				elif child.shape is SphereShape3D:
					child.shape.radius *= factor
			else:
				child.scale *= factor
	for child: Node in get_children():
		if child is Joint3D:
			child.position = (child.position - Vector3.UP * REST_SOLE_Y) * factor


func _release_bodies() -> void:
	for index in range(_bodies.size()):
		var body := _bodies[index]
		body.linear_velocity = _initial_velocity
		var side := -1.0 if index % 2 == 0 else 1.0
		body.angular_velocity = Vector3(
			0.7 + float(index % 3) * 0.18,
			side * (0.45 + float(index % 4) * 0.11),
			side * 0.55)
	if torso and _impact_impulse.length_squared() > 0.001:
		torso.apply_central_impulse(_impact_impulse * 0.55)
	if head_detached and head:
		var direction := _impact_impulse.normalized() \
			if _impact_impulse.length_squared() > 0.001 else -global_basis.z
		head.apply_central_impulse(direction * 2.8 + global_basis.y * 1.8)
		head.angular_velocity += Vector3(5.5, 2.2, -4.0)


func _body(body_name: String, local_position: Vector3,
		body_mass: float) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = body_name
	body.position = local_position
	body.mass = body_mass
	body.linear_damp = 0.28
	body.angular_damp = 0.55
	body.continuous_cd = true
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)
	_bodies.append(body)
	return body


func _limb(body_name: String, local_position: Vector3, radius: float,
		height: float, body_mass: float) -> RigidBody3D:
	var body := _body(body_name, local_position, body_mass)
	_add_capsule_collision(body, radius, height)
	return body


func _joint(joint_name: String, a: RigidBody3D, b: RigidBody3D,
		local_position: Vector3) -> void:
	var joint := PinJoint3D.new()
	joint.name = joint_name
	joint.position = local_position
	joint.exclude_nodes_from_collision = true
	add_child(joint)
	joint.node_a = joint.get_path_to(a)
	joint.node_b = joint.get_path_to(b)


func _add_capsule_collision(parent: CollisionObject3D, radius: float,
		height: float) -> void:
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = maxf(height, radius * 2.1)
	collision.shape = shape
	parent.add_child(collision)


func _add_sphere_collision(parent: CollisionObject3D, radius: float) -> void:
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = radius
	collision.shape = shape
	parent.add_child(collision)
