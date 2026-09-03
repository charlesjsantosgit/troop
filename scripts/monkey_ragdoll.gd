class_name MonkeyRagdoll
extends Node3D
## A lightweight procedural physics double for a defeated monkey. Each major
## limb is a rigid body joined at the anatomical pivot. Lethal headshots omit
## the neck joint so the head becomes an independent physics body.

const TORSO_CENTER := Vector3(0, 0.86, 0)
const HEAD_CENTER := Vector3(0, 1.18, 0)
const SHOULDER_Y := 1.06
const HIP_Y := 0.58

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


func configure(display_name: String, spawn_position: Vector3, spawn_yaw: float,
		initial_velocity: Vector3, impact_impulse: Vector3,
		detach_head: bool, surface_basis: Basis = Basis.IDENTITY) -> void:
	_display_name = display_name
	_spawn_position = spawn_position
	_spawn_yaw = spawn_yaw
	_surface_basis = surface_basis.orthonormalized()
	_initial_velocity = initial_velocity
	_impact_impulse = impact_impulse
	head_detached = detach_head
	_configured = true


func _ready() -> void:
	if not _configured:
		return
	add_to_group("monkey_ragdolls")
	global_transform = Transform3D(_surface_basis * Basis(Vector3.UP, _spawn_yaw),
		_spawn_position)
	_build()
	_release_bodies()


func follow_target() -> Node3D:
	return torso


func _build() -> void:
	var fur: Color = MonkeyRig.FURS[
		absi(hash(_display_name)) % MonkeyRig.FURS.size()]
	var fur_material: Material = Visuals.fur_material(fur)
	var skin_material: Material = Visuals.skin_material()
	var dark_material := StandardMaterial3D.new()
	dark_material.albedo_color = Color(0.13, 0.1, 0.08)
	var white_material := StandardMaterial3D.new()
	white_material.albedo_color = Color(0.96, 0.96, 0.94)
	var blush_material := StandardMaterial3D.new()
	blush_material.albedo_color = Color(1.0, 0.43, 0.48)
	blush_material.roughness = 0.72

	torso = _body("Torso", TORSO_CENTER, 2.2)
	_add_capsule(torso, 0.20, 0.58, fur_material)
	var belly := _sphere(0.13, skin_material)
	belly.position = Vector3(0, 0.19, -0.10)
	belly.scale = Vector3(0.9, 1.25, 0.55)
	torso.add_child(belly)
	winter_scarf = MeshInstance3D.new()
	winter_scarf.name = "WinterScarf"
	winter_scarf.mesh = MonkeyRig.shared_winter_scarf_mesh()
	winter_scarf.material_override = MonkeyRig.shared_winter_scarf_material(_display_name)
	winter_scarf.position = Vector3(0.0, -0.25, 0.0)
	winter_scarf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	winter_scarf.visibility_range_end = 62.0
	winter_scarf.visible = SeasonalCycle.active_season == SeasonalCycle.Season.WINTER
	torso.add_child(winter_scarf)
	_add_capsule_collision(torso, 0.20, 0.58)
	_add_tail(torso, fur_material)

	head = _body("Head", HEAD_CENTER, 0.72)
	_add_sphere(head, 0.18, fur_material)
	var face := _sphere(0.13, skin_material)
	face.position = Vector3(0, -0.02, -0.088)
	face.scale = Vector3(1.0, 0.95, 0.6)
	head.add_child(face)
	var muzzle := _sphere(0.072, skin_material)
	muzzle.position = Vector3(0, -0.064, -0.153)
	muzzle.scale = Vector3(1.05, 0.78, 0.42)
	head.add_child(muzzle)
	for side in [-1.0, 1.0]:
		var ear := _sphere(0.072, fur_material)
		ear.position = Vector3(side * 0.175, 0.06, 0.01)
		ear.scale = Vector3(0.55, 1.0, 0.9)
		head.add_child(ear)
		var inner_ear := _sphere(0.047, skin_material)
		inner_ear.position = Vector3(side * 0.175, 0.06, -0.046)
		inner_ear.scale = Vector3(0.38, 0.70, 0.52)
		head.add_child(inner_ear)
		var eye := _sphere(0.031, white_material)
		eye.position = Vector3(side * 0.058, 0.043, -0.152)
		eye.scale = Vector3(0.90, 1.05, 0.32)
		head.add_child(eye)
		var pupil := _sphere(0.0115, dark_material)
		pupil.position = Vector3(side * 0.058, 0.043, -0.166)
		pupil.scale = Vector3(1.0, 1.0, 0.28)
		head.add_child(pupil)
		var eye_glint := _sphere(0.0035, white_material)
		eye_glint.position = Vector3(side * 0.055, 0.047, -0.170)
		eye_glint.scale = Vector3(0.8, 0.8, 0.45)
		head.add_child(eye_glint)
		var cheek := _sphere(0.018, blush_material)
		cheek.position = Vector3(side * 0.092, -0.033, -0.148)
		cheek.scale = Vector3(1.18, 0.60, 0.24)
		head.add_child(cheek)
	_add_cute_smile(head, dark_material)
	_add_sphere_collision(head, 0.18)

	var upper_arm_left := _limb("UpperArmLeft",
		Vector3(0.245, 0.93, 0), 0.058, MonkeyRig.ARM_A, fur_material, 0.34)
	var lower_arm_left := _limb("LowerArmLeft",
		Vector3(0.27, 0.68, 0), 0.052, MonkeyRig.ARM_B, fur_material, 0.26)
	var upper_arm_right := _limb("UpperArmRight",
		Vector3(-0.245, 0.93, 0), 0.058, MonkeyRig.ARM_A, fur_material, 0.34)
	var lower_arm_right := _limb("LowerArmRight",
		Vector3(-0.27, 0.68, 0), 0.052, MonkeyRig.ARM_B, fur_material, 0.26)
	_add_joint_cover(lower_arm_left, Vector3(0, MonkeyRig.ARM_B * 0.5, 0),
		0.061, fur_material, "ElbowJoint")
	_add_joint_cover(lower_arm_right, Vector3(0, MonkeyRig.ARM_B * 0.5, 0),
		0.061, fur_material, "ElbowJoint")
	_add_paw(lower_arm_left, skin_material)
	_add_paw(lower_arm_right, skin_material)

	var upper_leg_left := _limb("UpperLegLeft",
		Vector3(0.115, 0.44, 0), 0.068, MonkeyRig.LEG_A, fur_material, 0.52)
	var lower_leg_left := _limb("LowerLegLeft",
		Vector3(0.115, 0.17, 0), 0.058, MonkeyRig.LEG_B, fur_material, 0.42)
	var upper_leg_right := _limb("UpperLegRight",
		Vector3(-0.115, 0.44, 0), 0.068, MonkeyRig.LEG_A, fur_material, 0.52)
	var lower_leg_right := _limb("LowerLegRight",
		Vector3(-0.115, 0.17, 0), 0.058, MonkeyRig.LEG_B, fur_material, 0.42)
	_add_joint_cover(lower_leg_left, Vector3(0, MonkeyRig.LEG_B * 0.5, 0),
		0.071, fur_material, "KneeJoint")
	_add_joint_cover(lower_leg_right, Vector3(0, MonkeyRig.LEG_B * 0.5, 0),
		0.071, fur_material, "KneeJoint")
	_add_foot(lower_leg_left, skin_material)
	_add_foot(lower_leg_right, skin_material)

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


func set_winter_scarf_visible(active: bool) -> void:
	if winter_scarf:
		winter_scarf.visible = active


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
		height: float, material: Material, body_mass: float) -> RigidBody3D:
	var body := _body(body_name, local_position, body_mass)
	_add_capsule(body, radius, height, material)
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


func _add_tail(parent: Node3D, material: Material) -> void:
	var tail_root := Node3D.new()
	tail_root.position = Vector3(0, -0.22, 0.13)
	parent.add_child(tail_root)
	var previous := tail_root
	for index in range(4):
		var segment := Node3D.new()
		segment.position = Vector3(0, 0, 0.14)
		segment.rotation.x = 0.18 + float(index) * 0.08
		previous.add_child(segment)
		var mesh := _capsule(0.04 - float(index) * 0.006, 0.20, material)
		mesh.rotation.x = PI * 0.5
		mesh.position = Vector3(0, 0, 0.08)
		segment.add_child(mesh)
		previous = segment


func _add_paw(parent: Node3D, material: Material) -> void:
	var paw := _sphere(0.062, material)
	paw.position = Vector3(0, -MonkeyRig.ARM_B * 0.52, 0)
	parent.add_child(paw)


func _add_foot(parent: Node3D, material: Material) -> void:
	var foot := _sphere(0.075, material)
	foot.position = Vector3(0, -MonkeyRig.LEG_B * 0.52, -0.035)
	foot.scale = Vector3(0.9, 0.55, 1.35)
	parent.add_child(foot)


func _add_joint_cover(parent: Node3D, local_position: Vector3, radius: float,
		material: Material, joint_name: String) -> void:
	var joint := _sphere(radius, material)
	joint.name = joint_name
	joint.position = local_position
	parent.add_child(joint)


func _add_capsule(parent: Node3D, radius: float, height: float,
		material: Material) -> void:
	parent.add_child(_capsule(radius, height, material))


func _add_sphere(parent: Node3D, radius: float, material: Material) -> void:
	parent.add_child(_sphere(radius, material))


func _capsule(radius: float, height: float, material: Material) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = maxf(height, radius * 2.1)
	mesh.radial_segments = 8
	mesh.rings = 4
	mesh_instance.mesh = mesh
	mesh_instance.material_override = material
	return mesh_instance


func _sphere(radius: float, material: Material) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 5
	mesh_instance.mesh = mesh
	mesh_instance.material_override = material
	return mesh_instance


func _add_cute_smile(parent: Node3D, material: Material) -> void:
	var smile := Node3D.new()
	smile.name = "Smile"
	parent.add_child(smile)
	for index in range(7):
		var t := float(index) / 6.0
		var curve := sin(t * PI)
		var bead := _sphere(0.0067, material)
		bead.position = Vector3(
			lerpf(-0.033, 0.033, t),
			-0.089 - curve * 0.018,
			-0.178 - curve * 0.0015)
		bead.scale = Vector3(1.04, 0.88, 0.56)
		smile.add_child(bead)


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
