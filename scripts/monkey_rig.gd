class_name MonkeyRig
extends Node3D
## Fully procedural monkey with jointed limbs (shoulders/elbows, hips/knees),
## animated in code. Root sits at the feet. While swinging, the support arm is
## solved onto the rope and the weapon arm stays aimed; an unarmed pose can
## still use both paws. The unused remainder of the vine trails below the grip.

enum Anim { IDLE, RUN, SPRINT, AIR, DIVE, WALLSLIDE, SWING, SLIDE, ROLL, FLIP_F, FLIP_B, SWIM, SKID, RIDE, PILOT }
# SPRINT slot = quadruped gallop (entered by landing fast off a vine).
# FLIP_F/FLIP_B = airborne tucked front/backflips after fast vine releases.

const HIP_Y := 0.58
const ARM_A := 0.26   # upper arm
const ARM_B := 0.24   # forearm
const LEG_A := 0.28   # thigh
const LEG_B := 0.26   # shin
const TAIL_SEGMENTS := 4
const TAIL_JOINT_STEP := 0.15
const TAIL_CORE_LENGTH := 0.22
const TAIL_CORE_RADIUS := 0.054
const TAIL_FUR_RADIUS := 0.060
const ROPE_TAIL_SEGMENTS := 6
const ROPE_GRAVITY := Vector3(0, -20.0, 0)
const ROPE_DAMPING := 0.992
const LOCAL_BODY_VISUAL_LAYER := 1 << 1

const FURS := [Color(0.48, 0.31, 0.17), Color(0.36, 0.23, 0.12), Color(0.54, 0.5, 0.47),
	Color(0.72, 0.54, 0.25), Color(0.23, 0.18, 0.14), Color(0.56, 0.35, 0.2)]
const SKIN := Color(0.91, 0.76, 0.6)
const SCARF_COLORS := [
	Color(0.78, 0.075, 0.065), Color(0.07, 0.30, 0.68),
	Color(0.06, 0.48, 0.29), Color(0.58, 0.13, 0.55),
]

static var _winter_scarf_mesh: ArrayMesh
static var _winter_scarf_materials: Dictionary = {}

var yaw_node: Node3D
var hips: Node3D
var torso_p: Node3D
var head_p: Node3D
var weapon_back_mount: Node3D
var sh_l: Node3D
var el_l: Node3D
var paw_l: MeshInstance3D
var sh_r: Node3D
var el_r: Node3D
var paw_r: MeshInstance3D
var hip_l: Node3D
var kn_l: Node3D
var hip_r: Node3D
var kn_r: Node3D
var foot_l: MeshInstance3D
var foot_r: MeshInstance3D
var tail_segs: Array = []
var tag: Label3D
var rope_mi: MeshInstance3D
var rope_mesh: ImmediateMesh
var rope_mat: Material

var _t := 0.0
var _phase := 0.0
var _gait_cycle := 0.0
var _anim_prev := -1
var _anim_ramp := 1.0
var _sprint_was_floor := true
var _last_gait_origin := Vector3.INF
# per-limb contact state for the gallop: [fore L, fore R, hind L, hind R]
var _plants: Array = [
	{"on": false, "pos": Vector3.ZERO, "from": Vector3.ZERO},
	{"on": false, "pos": Vector3.ZERO, "from": Vector3.ZERO},
	{"on": false, "pos": Vector3.ZERO, "from": Vector3.ZERO},
	{"on": false, "pos": Vector3.ZERO, "from": Vector3.ZERO},
]
var _roll_spin := 0.0
var _flip_spin := 0.0
var _turn_lean := 0.0
var _air_pitch := 0.0
var _air_roll := 0.0
var _air_pitch_velocity := 0.0
var _air_roll_velocity := 0.0
var _rope_active := false
var _rope_anchor := Vector3.ZERO
var _rope_pivot := Vector3.ZERO   # last wrap point (or the anchor) — the arm target
var _rope_hand := Vector3.ZERO
var _rope_tail := 0.0
var _rope_vel := Vector3.ZERO
var _rope_tail_points := PackedVector3Array()
var _rope_tail_previous := PackedVector3Array()
var _rope_render_points := PackedVector3Array()
var _gun_aim_active := false
var _gun_aim_direction := Vector3(0, 0, -1)
var _gun_recoil := 0.0
var _sniper_rope_pose := false
var _sniper_rope_blend := 0.0
var _sniper_support_grip: Node3D
var _melee_mode := false
var _ride_lean := 0.0
var _vehicle_pose = null
var _melee_attack_active := false
var _melee_attack_progress := 0.0
var _melee_combo := 0
var _healing_pose := false
var _healing_progress := 0.0
var _reload_pose := false
var _reload_support_grip: Node3D
var bandage_roll: Node3D
var bandage_wrist: MeshInstance3D
var bandage_strip: MeshInstance3D
var winter_scarf: MeshInstance3D
var _outline_material: Material
var _is_local_visual := false
var _wings_active := false
var _wing_unfold := 0.0
var _wing_l: Node3D
var _wing_r: Node3D


func setup(display_name: String, show_tag: bool) -> void:
	_is_local_visual = not show_tag
	_outline_material = Visuals.enemy_outline_material() if show_tag else null
	var fur: Color = FURS[absi(hash(display_name)) % FURS.size()]
	var fur_m: Material = Visuals.fur_material(fur)
	var skin_m: Material = Visuals.skin_material()
	var dark_m := StandardMaterial3D.new()
	dark_m.albedo_color = Color(0.13, 0.1, 0.08)
	var white_m := StandardMaterial3D.new()
	white_m.albedo_color = Color(0.96, 0.96, 0.94)
	var blush_m := StandardMaterial3D.new()
	blush_m.albedo_color = Color(1.0, 0.43, 0.48)
	blush_m.roughness = 0.72

	yaw_node = Node3D.new()
	add_child(yaw_node)
	hips = Node3D.new()
	hips.position = Vector3(0, HIP_Y, 0)
	yaw_node.add_child(hips)
	torso_p = Node3D.new()
	torso_p.position = Vector3(0, 0.05, 0)
	hips.add_child(torso_p)
	weapon_back_mount = Node3D.new()
	weapon_back_mount.name = "WeaponBackMount"
	weapon_back_mount.position = Vector3(0, 0.27, 0.205)
	torso_p.add_child(weapon_back_mount)

	var torso := _cap(0.2, 0.58, fur_m)
	torso.position = Vector3(0, 0.23, 0)
	torso_p.add_child(torso)
	var belly := _sph(0.13, skin_m)
	belly.position = Vector3(0, 0.19, -0.1)
	belly.scale = Vector3(0.9, 1.25, 0.55)
	torso_p.add_child(belly)

	head_p = Node3D.new()
	head_p.position = Vector3(0, 0.54, 0)
	torso_p.add_child(head_p)
	var head := _sph(0.18, fur_m)
	head_p.add_child(head)
	var face := _sph(0.13, skin_m)
	face.position = Vector3(0, -0.02, -0.088)
	face.scale = Vector3(1.0, 0.95, 0.6)
	head_p.add_child(face)
	var muzzle := _sph(0.072, skin_m)
	muzzle.position = Vector3(0, -0.064, -0.153)
	muzzle.scale = Vector3(1.05, 0.78, 0.42)
	head_p.add_child(muzzle)
	for sx in [-1.0, 1.0]:
		var ear := _sph(0.072, fur_m)
		ear.position = Vector3(sx * 0.175, 0.06, 0.01)
		ear.scale = Vector3(0.55, 1.0, 0.9)
		head_p.add_child(ear)
		var inner_ear := _sph(0.047, skin_m)
		inner_ear.position = Vector3(sx * 0.175, 0.06, -0.046)
		inner_ear.scale = Vector3(0.38, 0.70, 0.52)
		head_p.add_child(inner_ear)
		var eye := _sph(0.031, white_m)
		eye.position = Vector3(sx * 0.058, 0.043, -0.152)
		eye.scale = Vector3(0.90, 1.05, 0.32)
		head_p.add_child(eye)
		var pupil := _sph(0.0115, dark_m)
		pupil.position = Vector3(sx * 0.058, 0.043, -0.166)
		pupil.scale = Vector3(1.0, 1.0, 0.28)
		head_p.add_child(pupil)
		var eye_glint := _sph(0.0035, white_m)
		eye_glint.position = Vector3(sx * 0.055, 0.047, -0.170)
		eye_glint.scale = Vector3(0.8, 0.8, 0.45)
		head_p.add_child(eye_glint)
		var cheek := _sph(0.018, blush_m)
		cheek.position = Vector3(sx * 0.092, -0.033, -0.148)
		cheek.scale = Vector3(1.18, 0.60, 0.24)
		head_p.add_child(cheek)
	_add_cute_smile(head_p, dark_m)
	_build_winter_scarf(display_name)

	# arms: shoulder -> upper -> elbow -> forearm + paw
	sh_l = Node3D.new()
	sh_l.position = Vector3(-0.225, 0.44, 0)
	torso_p.add_child(sh_l)
	var left_arm := _build_arm(sh_l, fur_m, skin_m, -1.0)
	el_l = left_arm[0]
	paw_l = left_arm[1]
	sh_r = Node3D.new()
	sh_r.position = Vector3(0.225, 0.44, 0)
	torso_p.add_child(sh_r)
	var right_arm := _build_arm(sh_r, fur_m, skin_m, 1.0)
	el_r = right_arm[0]
	paw_r = right_arm[1]
	_build_bandage_props()

	# legs: hip -> thigh -> knee -> shin + foot
	hip_l = Node3D.new()
	hip_l.position = Vector3(-0.115, 0.0, 0)
	hips.add_child(hip_l)
	var left_leg := _build_leg(hip_l, fur_m, skin_m)
	kn_l = left_leg[0]
	foot_l = left_leg[1]
	hip_r = Node3D.new()
	hip_r.position = Vector3(0.115, 0.0, 0)
	hips.add_child(hip_r)
	var right_leg := _build_leg(hip_r, fur_m, skin_m)
	kn_r = right_leg[0]
	foot_r = right_leg[1]

	var tail_base := Node3D.new()
	tail_base.name = "TailRoot"
	tail_base.position = Vector3(0, 0.08, 0.13)
	hips.add_child(tail_base)
	tail_segs.append(tail_base)
	# The articulated chain used to start one segment behind this pivot. Pelvis
	# pitch could therefore reveal empty space between the body and the first
	# visible capsule. A socket plus overlapping root bridge keeps the attachment
	# buried in the rump throughout gallop, swim, flips, and ordinary locomotion.
	var tail_socket := _sph(0.078, fur_m)
	tail_socket.name = "TailSocket"
	tail_socket.position = Vector3(0, 0, 0.012)
	tail_socket.scale = Vector3(1.0, 0.90, 1.18)
	tail_base.add_child(tail_socket)
	var tail_bridge := _cap(TAIL_CORE_RADIUS + 0.003, 0.23, fur_m)
	tail_bridge.name = "TailRootBridge"
	tail_bridge.rotation.x = PI * 0.5
	tail_bridge.position = Vector3(0, 0, 0.075)
	tail_base.add_child(tail_bridge)
	for i in range(TAIL_SEGMENTS):
		var seg := Node3D.new()
		seg.name = "TailJoint%d" % i
		seg.position = Vector3(0, 0, TAIL_JOINT_STEP)
		# A constant-width core keeps the articulated tail from tapering into a
		# thin rat-like whip. Low-poly fur bulbs overlap every hinge, softening the
		# silhouette while leaving each joint free to carry the travelling wave.
		var core := _cap(TAIL_CORE_RADIUS, TAIL_CORE_LENGTH, fur_m)
		core.name = "TailCore"
		core.rotation.x = PI * 0.5
		core.position = Vector3(0, 0, TAIL_JOINT_STEP * 0.5)
		seg.add_child(core)
		var fluff := _sph(TAIL_FUR_RADIUS, fur_m)
		fluff.name = "TailFur"
		fluff.position = Vector3(0, 0, 0.025)
		fluff.scale = Vector3(1.08, 0.98, 1.22)
		seg.add_child(fluff)
		if i == TAIL_SEGMENTS - 1:
			var tip_fluff := _sph(TAIL_FUR_RADIUS * 1.08, fur_m)
			tip_fluff.name = "TailTipTuft"
			tip_fluff.position = Vector3(0, 0, 0.17)
			tip_fluff.scale = Vector3(1.10, 1.02, 1.28)
			seg.add_child(tip_fluff)
		tail_segs[tail_segs.size() - 1].add_child(seg)
		tail_segs.append(seg)

	if show_tag:
		tag = Label3D.new()
		tag.text = display_name
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.no_depth_test = true
		tag.font_size = 40
		tag.outline_size = 10
		tag.pixel_size = 0.005
		tag.position = Vector3(0, 1.55, 0)
		add_child(tag)

	rope_mesh = ImmediateMesh.new()
	rope_mi = MeshInstance3D.new()
	rope_mi.mesh = rope_mesh
	rope_mi.top_level = true
	rope_mat = Visuals.vine_material(0.0)
	add_child(rope_mi)


func _build_arm(shoulder: Node3D, fur_m: Material, skin_m: Material,
		side_sign: float) -> Array:
	var upper := _cap(0.058, ARM_A, fur_m)
	upper.name = "UpperArm"
	upper.position = Vector3(0, -ARM_A * 0.5, 0)
	shoulder.add_child(upper)
	var elbow := Node3D.new()
	elbow.name = "Elbow"
	elbow.position = Vector3(0, -ARM_A, 0)
	shoulder.add_child(elbow)
	var elbow_joint := _sph(0.066, fur_m)
	elbow_joint.name = "ElbowJoint"
	elbow.add_child(elbow_joint)
	# A small hairless outer cap makes the hinge readable from gameplay camera
	# distance and keeps the upper/forearm seam from looking like one tube.
	var elbow_pad := _sph(0.038, skin_m)
	elbow_pad.name = "ElbowPad"
	elbow_pad.position = Vector3(side_sign * 0.048, 0.006, 0.004)
	elbow_pad.scale = Vector3(0.50, 0.82, 0.88)
	elbow.add_child(elbow_pad)
	var fore := _cap(0.05, ARM_B, fur_m)
	fore.name = "Forearm"
	fore.position = Vector3(0, -ARM_B * 0.5, 0)
	elbow.add_child(fore)
	var paw := _sph(0.06, skin_m)
	paw.name = "Paw"
	paw.position = Vector3(0, -ARM_B, 0)
	elbow.add_child(paw)
	return [elbow, paw]


func _build_leg(hip: Node3D, fur_m: Material, skin_m: Material) -> Array:
	var thigh := _cap(0.068, LEG_A, fur_m)
	thigh.name = "Thigh"
	thigh.position = Vector3(0, -LEG_A * 0.5, 0)
	hip.add_child(thigh)
	var knee := Node3D.new()
	knee.name = "Knee"
	knee.position = Vector3(0, -LEG_A, 0)
	hip.add_child(knee)
	var knee_joint := _sph(0.077, fur_m)
	knee_joint.name = "KneeJoint"
	knee.add_child(knee_joint)
	var kneecap := _sph(0.043, skin_m)
	kneecap.name = "Kneecap"
	kneecap.position = Vector3(0, 0.004, -0.056)
	kneecap.scale = Vector3(0.78, 0.88, 0.48)
	knee.add_child(kneecap)
	var shin := _cap(0.056, LEG_B, fur_m)
	shin.name = "Shin"
	shin.position = Vector3(0, -LEG_B * 0.5, 0)
	knee.add_child(shin)
	var foot := _sph(0.075, skin_m)
	foot.name = "Foot"
	foot.position = Vector3(0, -LEG_B, -0.035)
	foot.scale = Vector3(0.9, 0.55, 1.35)
	knee.add_child(foot)
	return [knee, foot]


func _cap(r: float, h: float, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = maxf(h, r * 2.1)
	c.radial_segments = 10
	c.rings = 5
	mi.mesh = c
	mi.material_override = m
	if _is_local_visual:
		mi.layers = LOCAL_BODY_VISUAL_LAYER
	if _outline_material:
		mi.material_overlay = _outline_material
	return mi


func _sph(r: float, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 10
	s.rings = 6
	mi.mesh = s
	mi.material_override = m
	if _is_local_visual:
		mi.layers = LOCAL_BODY_VISUAL_LAYER
	if _outline_material:
		mi.material_overlay = _outline_material
	return mi


func _build_winter_scarf(display_name: String) -> void:
	winter_scarf = MeshInstance3D.new()
	winter_scarf.name = "WinterScarf"
	winter_scarf.mesh = shared_winter_scarf_mesh()
	winter_scarf.material_override = shared_winter_scarf_material(display_name)
	winter_scarf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	winter_scarf.visibility_range_end = 62.0
	winter_scarf.visibility_range_end_margin = 8.0
	winter_scarf.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	if _is_local_visual:
		winter_scarf.layers = LOCAL_BODY_VISUAL_LAYER
	if _outline_material:
		winter_scarf.material_overlay = _outline_material
	torso_p.add_child(winter_scarf)
	set_winter_scarf_visible(SeasonalCycle.active_season == SeasonalCycle.Season.WINTER)


func set_winter_scarf_visible(active: bool) -> void:
	if winter_scarf:
		winter_scarf.visible = active


func has_visible_winter_scarf() -> bool:
	return winter_scarf != null and winter_scarf.visible


static func shared_winter_scarf_material(display_name: String) -> StandardMaterial3D:
	var palette_index := absi(hash(display_name)) % SCARF_COLORS.size()
	if not _winter_scarf_materials.has(palette_index):
		var material := StandardMaterial3D.new()
		material.albedo_color = SCARF_COLORS[palette_index]
		material.roughness = 0.88
		material.metallic = 0.0
		material.rim_enabled = true
		material.rim = 0.16
		material.rim_tint = 0.55
		_winter_scarf_materials[palette_index] = material
	return _winter_scarf_materials[palette_index]


static func shared_winter_scarf_mesh() -> ArrayMesh:
	if _winter_scarf_mesh:
		return _winter_scarf_mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const RING_SEGMENTS := 12
	const TUBE_SEGMENTS := 4
	const RING_RADIUS := 0.164
	const TUBE_RADIUS := 0.037
	const RING_Y := 0.485
	for ring_index in range(RING_SEGMENTS):
		var next_ring := (ring_index + 1) % RING_SEGMENTS
		var u0 := TAU * float(ring_index) / float(RING_SEGMENTS)
		var u1 := TAU * float(next_ring) / float(RING_SEGMENTS)
		for tube_index in range(TUBE_SEGMENTS):
			var next_tube := (tube_index + 1) % TUBE_SEGMENTS
			var v0 := TAU * float(tube_index) / float(TUBE_SEGMENTS)
			var v1 := TAU * float(next_tube) / float(TUBE_SEGMENTS)
			var p00 := Vector3((RING_RADIUS + TUBE_RADIUS * cos(v0)) * cos(u0),
				RING_Y + TUBE_RADIUS * sin(v0),
				(RING_RADIUS + TUBE_RADIUS * cos(v0)) * sin(u0))
			var p01 := Vector3((RING_RADIUS + TUBE_RADIUS * cos(v1)) * cos(u0),
				RING_Y + TUBE_RADIUS * sin(v1),
				(RING_RADIUS + TUBE_RADIUS * cos(v1)) * sin(u0))
			var p10 := Vector3((RING_RADIUS + TUBE_RADIUS * cos(v0)) * cos(u1),
				RING_Y + TUBE_RADIUS * sin(v0),
				(RING_RADIUS + TUBE_RADIUS * cos(v0)) * sin(u1))
			var p11 := Vector3((RING_RADIUS + TUBE_RADIUS * cos(v1)) * cos(u1),
				RING_Y + TUBE_RADIUS * sin(v1),
				(RING_RADIUS + TUBE_RADIUS * cos(v1)) * sin(u1))
			for point in [p00, p11, p01, p00, p10, p11]:
				st.add_vertex(point)
	_add_scarf_octahedron(st, Vector3(0.0, 0.425, -0.205), 0.064)
	_add_scarf_box(st, Vector3(-0.043, 0.292, -0.220),
		Vector3(0.073, 0.255, 0.030), -0.15)
	_add_scarf_box(st, Vector3(0.043, 0.305, -0.224),
		Vector3(0.068, 0.225, 0.030), 0.18)
	st.generate_normals()
	_winter_scarf_mesh = st.commit()
	return _winter_scarf_mesh


static func _add_scarf_octahedron(st: SurfaceTool, center: Vector3,
		radius: float) -> void:
	var top := center + Vector3.UP * radius
	var bottom := center - Vector3.UP * radius
	var ring := [
		center + Vector3.RIGHT * radius,
		center + Vector3.FORWARD * radius,
		center + Vector3.LEFT * radius,
		center + Vector3.BACK * radius,
	]
	for index in range(4):
		var next := (index + 1) % 4
		for point in [top, ring[index], ring[next], bottom, ring[next], ring[index]]:
			st.add_vertex(point)


static func _add_scarf_box(st: SurfaceTool, center: Vector3, size: Vector3,
		rotation_z: float) -> void:
	var half := size * 0.5
	var basis := Basis(Vector3.FORWARD, rotation_z)
	var corners: Array[Vector3] = []
	for corner in [
		Vector3(-half.x, -half.y, -half.z), Vector3(half.x, -half.y, -half.z),
		Vector3(half.x, half.y, -half.z), Vector3(-half.x, half.y, -half.z),
		Vector3(-half.x, -half.y, half.z), Vector3(half.x, -half.y, half.z),
		Vector3(half.x, half.y, half.z), Vector3(-half.x, half.y, half.z),
	]:
		corners.append(center + basis * corner)
	for indices in [
		[0, 1, 2, 0, 2, 3], [4, 6, 5, 4, 7, 6],
		[0, 5, 1, 0, 4, 5], [3, 6, 7, 3, 2, 6],
		[0, 7, 4, 0, 3, 7], [1, 6, 2, 1, 5, 6],
	]:
		for index in indices:
			st.add_vertex(corners[index])


func _add_cute_smile(parent: Node3D, material: Material) -> void:
	# Seven overlapping low-poly beads form a compact rounded "u" on the muzzle.
	# The corners sit higher than the center, matching @(･u･)@ at game scale.
	var smile := Node3D.new()
	smile.name = "Smile"
	parent.add_child(smile)
	for index in range(7):
		var t := float(index) / 6.0
		var curve := sin(t * PI)
		var bead := _sph(0.0067, material)
		bead.position = Vector3(
			lerpf(-0.033, 0.033, t),
			-0.089 - curve * 0.018,
			-0.178 - curve * 0.0015)
		bead.scale = Vector3(1.04, 0.88, 0.56)
		smile.add_child(bead)


func face(dir: Vector3, dt: float) -> void:
	if dir.length() < 0.05:
		_turn_lean = lerpf(_turn_lean, 0.0, 1.0 - exp(-8.0 * dt))
		return
	var target := atan2(dir.x, dir.z) + PI
	var turn_rate := angle_difference(yaw_node.rotation.y, target) / maxf(dt, 0.001)
	_turn_lean = lerpf(_turn_lean, clampf(-turn_rate * 0.025, -0.18, 0.18),
		1.0 - exp(-10.0 * dt))
	yaw_node.rotation.y = lerp_angle(yaw_node.rotation.y, target, 1.0 - exp(-10.0 * dt))


func yaw_angle() -> float:
	return yaw_node.rotation.y


func set_yaw(a: float) -> void:
	yaw_node.rotation.y = a


func set_gun_aim(active: bool, direction: Vector3, recoil: float) -> void:
	_gun_aim_active = active
	if direction.length_squared() > 0.001:
		_gun_aim_direction = direction.normalized()
	_gun_recoil = recoil


## Enable the extra points of contact used to stabilize a heavy sniper while
## swinging. Player/Puppet may leave this set while equipped; it only affects
## an active rope swing and blends completely out everywhere else.
func set_sniper_rope_pose(active: bool, support_grip: Node3D = null) -> void:
	_sniper_rope_pose = active
	_sniper_support_grip = support_grip if active else null


## Lateral lean fed by a vehicle (motorcycle roll, airboat carve). The seated
## poses counter-lean the head so the rider keeps a level horizon, exactly the
## way a real rider's eyes stay upright through a corner.
func set_ride_lean(lean: float) -> void:
	_ride_lean = clampf(lean, -1.25, 1.25)


## The occupied machine supplies the exact cushion/root placement and moving
## control contacts. Keeping this on the rig lets local players and network
## puppets share one final-pass seated pose instead of maintaining two copies.
func set_vehicle_pose(vehicle) -> void:
	_vehicle_pose = vehicle if is_instance_valid(vehicle) else null


func set_melee_pose(active: bool, attack_active: bool, progress: float,
		combo: int) -> void:
	_melee_mode = active
	_melee_attack_active = attack_active
	_melee_attack_progress = clampf(progress, 0.0, 1.0)
	_melee_combo = posmod(combo, 3)


func set_healing_pose(active: bool, progress: float) -> void:
	_healing_pose = active
	_healing_progress = clampf(progress, 0.0, 1.0)
	_update_bandage_props()


func set_reload_pose(active: bool, support_grip: Node3D = null) -> void:
	_reload_pose = active and is_instance_valid(support_grip)
	_reload_support_grip = support_grip if _reload_pose else null


## Normalized locomotion phase shared by the procedural pose, limb IK, water
## contacts and regression captures. One full unit is one gallop stride or one
## left/right freestyle stroke pair.
func gait_cycle() -> float:
	return _gait_cycle


## World-space extremities after the current frame's FK/IK solve. Water FX use
## the real animated contacts instead of emitting generic particles at the
## character origin.
func limb_contact_points() -> PackedVector3Array:
	if not paw_l or not paw_r or not foot_l or not foot_r:
		return PackedVector3Array()
	return PackedVector3Array([
		paw_l.global_position, paw_r.global_position,
		foot_l.global_position, foot_r.global_position,
	])


func set_rope(active: bool, anchor: Vector3, hand: Vector3, tail := 0.0, vel := Vector3.ZERO,
		wrap_pts := PackedVector3Array(), dt := 1.0 / 60.0) -> void:
	_rope_active = active
	_rope_anchor = anchor
	_rope_hand = hand
	_rope_tail = tail
	_rope_vel = vel
	_rope_pivot = wrap_pts[wrap_pts.size() - 1] if wrap_pts.size() > 0 else anchor
	rope_mesh.clear_surfaces()
	if not active:
		_rope_tail_points = PackedVector3Array()
		_rope_tail_previous = PackedVector3Array()
		return
	rope_mi.global_transform = Transform3D.IDENTITY
	var dir := hand - _rope_pivot
	if dir.length() < 0.05:
		return
	dir = dir.normalized()
	rope_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, rope_mat)
	var c_hi := Color(0.24, 0.32, 0.12)
	var c_lo := Color(0.32, 0.42, 0.14)
	# polyline: anchor → wrap pivots → hand (the vine bends around geometry)
	_rope_render_points = PackedVector3Array([anchor])
	var prev_pt := anchor
	for wp in wrap_pts:
		_rope_seg(prev_pt, wp, 0.045, c_hi, c_hi)
		_rope_render_points.append(wp)
		prev_pt = wp
	_rope_seg(prev_pt, hand, 0.045, c_hi, c_lo)
	_rope_render_points.append(hand)
	# The loose remainder is a persistent verlet chain, so it lags, bends and
	# carries momentum instead of being recalculated as a rigid curve each frame.
	if tail > 0.3:
		_update_rope_tail(hand, tail, vel, dir, dt)
		for i in range(_rope_tail_points.size() - 1):
			_rope_seg(_rope_tail_points[i], _rope_tail_points[i + 1], 0.045, c_lo, c_lo)
			_rope_render_points.append(_rope_tail_points[i + 1])
		var pcur := _rope_tail_points[_rope_tail_points.size() - 1]
		var tipc := Color(0.5, 0.72, 0.25)
		_rope_seg(pcur + Vector3(0.14, 0.2, 0), pcur + Vector3(-0.14, -0.1, 0), 0.1, tipc, tipc)
		_rope_seg(pcur + Vector3(0, 0.2, 0.14), pcur + Vector3(0, -0.1, -0.14), 0.1, tipc, tipc)
	else:
		_rope_tail_points = PackedVector3Array()
		_rope_tail_previous = PackedVector3Array()
	rope_mesh.surface_end()


func rope_snapshot() -> PackedVector3Array:
	return _rope_render_points.duplicate()


func _update_rope_tail(hand: Vector3, tail: float, vel: Vector3, upper_dir: Vector3,
		dt: float) -> void:
	var count := ROPE_TAIL_SEGMENTS + 1
	var step := tail / float(ROPE_TAIL_SEGMENTS)
	var frame_dt := clampf(dt, 1.0 / 240.0, 1.0 / 30.0)
	if _rope_tail_points.size() != count:
		_rope_tail_points.resize(count)
		_rope_tail_previous.resize(count)
		var trail_dir := (Vector3.DOWN * 2.4 + upper_dir * 0.8 - vel * 0.08).normalized()
		_rope_tail_points[0] = hand
		_rope_tail_previous[0] = hand
		for i in range(1, count):
			var blend := float(i) / float(ROPE_TAIL_SEGMENTS)
			var direction := upper_dir.lerp(trail_dir, blend).normalized()
			_rope_tail_points[i] = _rope_tail_points[i - 1] + direction * step
			_rope_tail_previous[i] = _rope_tail_points[i] - vel * blend * frame_dt
	else:
		_rope_tail_points[0] = hand
		_rope_tail_previous[0] = hand
		var gravity_step := ROPE_GRAVITY * frame_dt * frame_dt
		for i in range(1, count):
			var current := _rope_tail_points[i]
			var momentum := (current - _rope_tail_previous[i]) * ROPE_DAMPING
			_rope_tail_previous[i] = current
			_rope_tail_points[i] = current + momentum + gravity_step

	for pass_i in range(7):
		_rope_tail_points[0] = hand
		for i in range(ROPE_TAIL_SEGMENTS):
			var delta := _rope_tail_points[i + 1] - _rope_tail_points[i]
			var distance := delta.length()
			if distance < 0.0001:
				continue
			var error := (distance - step) / distance
			if i == 0:
				_rope_tail_points[i + 1] -= delta * error
			else:
				var correction := delta * error * 0.5
				_rope_tail_points[i] += correction
				_rope_tail_points[i + 1] -= correction
	_rope_tail_points[0] = hand


func _rope_seg(a: Vector3, b: Vector3, w: float, ca: Color, cb: Color) -> void:
	var d := b - a
	if d.length() < 0.001:
		return
	d = d.normalized()
	var side := d.cross(Vector3.UP)
	if side.length() < 0.1:
		side = d.cross(Vector3.RIGHT)
	side = side.normalized() * w
	var side2 := d.cross(side).normalized() * w
	for s in [side, side2]:
		rope_mesh.surface_set_color(ca)
		rope_mesh.surface_add_vertex(a - s)
		rope_mesh.surface_set_color(ca)
		rope_mesh.surface_add_vertex(a + s)
		rope_mesh.surface_set_color(cb)
		rope_mesh.surface_add_vertex(b + s)
		rope_mesh.surface_set_color(ca)
		rope_mesh.surface_add_vertex(a - s)
		rope_mesh.surface_set_color(cb)
		rope_mesh.surface_add_vertex(b + s)
		rope_mesh.surface_set_color(cb)
		rope_mesh.surface_add_vertex(b - s)


## Compute a target pose for the anim state, blend toward it, then IK the
## gripping arms onto the rope when swinging.
func update_motion(dt: float, anim: int, vel: Vector3, on_floor: bool, anchor: Vector3) -> void:
	_t += dt
	_update_angel_wings(dt)
	if anim != _anim_prev:
		if anim == Anim.SPRINT or _anim_prev == Anim.SPRINT:
			_reset_gait_plants()
		if anim == Anim.SPRINT or anim == Anim.SWIM:
			_gait_cycle = 0.0
		_anim_prev = anim
		_anim_ramp = 0.0
	_anim_ramp = minf(_anim_ramp + dt / 0.2, 1.0)
	var sniper_rope_target := 1.0 \
		if (_sniper_rope_pose and anim == Anim.SWING and _rope_active) else 0.0
	_sniper_rope_blend = lerpf(_sniper_rope_blend, sniper_rope_target,
		1.0 - exp(-8.0 * dt))
	if absf(_sniper_rope_blend - sniper_rope_target) < 0.0005:
		_sniper_rope_blend = sniper_rope_target
	var h := Vector3(vel.x, 0, vel.z).length()
	var run_speed := clampf((h - 0.5) / 10.5, 0.0, 1.0)
	if anim == Anim.SPRINT:
		_gait_cycle = fposmod(_gait_cycle + _gallop_frequency(h) * dt, 1.0)
	elif anim == Anim.SWIM:
		# A relaxed crawl remains alive while treading water and rises to roughly
		# 1.25 complete stroke pairs per second at full sprint-swim speed.
		var stroke_rate := lerpf(0.34, 1.28, clampf(h / 6.25, 0.0, 1.0))
		_gait_cycle = fposmod(_gait_cycle + stroke_rate * dt, 1.0)
	var cadence := lerpf(6.8, 15.8, run_speed)
	_phase += cadence * dt if (on_floor and h > 0.5) else dt * 2.5
	if anim == Anim.ROLL:
		_roll_spin += 14.0 * dt
	else:
		_roll_spin = 0.0
	# Tucked aerial rotation: forward release speed spins the body over the top,
	# backward travel spins it the other way. Ending mid-rotation is fine — the
	# lerp_angle blend back to the pose target reads as the monkey opening up.
	if anim == Anim.FLIP_F:
		_flip_spin += 9.5 * dt
	elif anim == Anim.FLIP_B:
		_flip_spin -= 9.5 * dt
	else:
		_flip_spin = 0.0

	# A hanging body is another pendulum below the hands. Follow the rope's
	# direction, let the feet trail tangential velocity, and use a damped angular
	# spring so the monkey has rotational inertia instead of snapping upright.
	var local_velocity := yaw_node.global_transform.basis.inverse() * vel
	if anim == Anim.SWING:
		var toward_anchor := anchor - global_position
		var target_pitch := 0.0
		var target_roll := 0.0
		if toward_anchor.length() > 0.1:
			var local_rope := yaw_node.global_transform.basis.inverse() * toward_anchor.normalized()
			target_pitch = atan2(-local_rope.z, maxf(local_rope.y, 0.08))
			target_roll = atan2(local_rope.x,
				maxf(Vector2(local_rope.y, local_rope.z).length(), 0.08)) * 0.82
		var speed_weight := clampf(h / 18.0, 0.0, 1.0)
		if h > 0.2:
			target_pitch += (local_velocity.z / h) * speed_weight * 0.62
			target_roll -= (local_velocity.x / h) * speed_weight * 0.44
		_advance_air_tilt(dt, clampf(target_pitch, -1.20, 1.20),
			clampf(target_roll, -0.90, 0.90), 24.0, 6.5)
	elif anim == Anim.AIR:
		# Preserve release rotation in free flight, then slowly weathercock into
		# the ballistic arc as air resistance settles the body.
		var flight_pitch := clampf(-vel.y / 48.0, -0.22, 0.28)
		_advance_air_tilt(dt, flight_pitch, 0.0, 2.8, 1.9)
	elif anim != Anim.DIVE and anim != Anim.ROLL:
		_advance_air_tilt(dt, 0.0, 0.0, 18.0, 7.0)

	var ph := _phase
	var p := {
		"hips_x": 0.0, "hips_z": 0.0, "hips_y": 0.0, "hips_side": 0.0,
		"torso": 0.05, "torso_y": 0.0, "torso_z": 0.0,
		"head": -0.05, "head_y": 0.0, "head_z": 0.0,
		"al": Vector3(0.1, 0, 0.1), "ar": Vector3(0.1, 0, -0.1),
		"el": 0.25, "er": 0.25,
		"ll": 0.0, "lr": 0.0, "kl": -0.12, "kr": -0.12, "fl": 0.0, "fr": 0.0,
		"tail_curl": 0.45, "tail_sway": sin(_t * 2.5) * 0.15,
		"tail_root_x": 0.0, "tail_root_y": 0.0, "tail_root_z": 0.0,
	}
	match anim:
		Anim.IDLE:
			p.torso = 0.05 + sin(_t * 2.0) * 0.03
			p.el = 0.3
			p.er = 0.3
			# Idle fidgets: every six seconds the monkey looks around, scratches
			# its head (left paw — the right may be holding a gun), or glances
			# back at its own swishing tail.
			var fidget_time := fmod(_t, 6.0)
			if fidget_time > 4.4:
				var k := fidget_time - 4.4
				var ease := sin(minf(k / 1.6, 1.0) * PI)
				match int(_t / 6.0) % 3:
					0:
						p.head_y = sin(k * 3.2) * 0.55 * ease
						p.head = -0.05 + sin(k * 2.1) * 0.1 * ease
					1:
						p.al = Vector3(-2.45 * ease, 0, 0.42 * ease)
						p.el = 0.3 + (1.45 + sin(k * 11.0) * 0.22) * ease
						p.head_z = 0.18 * ease
						p.head = -0.05 - 0.14 * ease
					2:
						p.head_y = -0.62 * ease
						p.head = 0.12 * ease
						p.tail_curl = 0.45 + 0.5 * ease
						p.tail_sway = sin(k * 7.0) * 0.45 * ease
		Anim.RUN:
			# Bipedal gait with separate planted and recovery halves. The body
			# shifts over the planted foot while the opposite knee folds to clear
			# the ground; cadence and stride expand continuously with speed.
			var stride := lerpf(0.42, 0.88, run_speed)
			var arm_stride := lerpf(0.30, 0.68, run_speed)
			var left_cycle := sin(ph)
			var right_cycle := -left_cycle
			var left_recovery := pow(maxf(cos(ph), 0.0), 1.7)
			var right_recovery := pow(maxf(cos(ph + PI), 0.0), 1.7)
			var double_step := cos(ph * 2.0)
			var balance := sin(ph)

			p.hips_x = 0.04 + run_speed * 0.08
			p.hips_y = -0.018 + double_step * lerpf(0.012, 0.034, run_speed)
			p.hips_side = balance * lerpf(0.008, 0.026, run_speed)
			p.hips_z = balance * lerpf(0.025, 0.07, run_speed) + _turn_lean
			p.torso = 0.10 + run_speed * 0.18 - double_step * 0.018
			p.torso_y = -balance * lerpf(0.018, 0.065, run_speed)
			p.torso_z = -balance * lerpf(0.018, 0.055, run_speed) - _turn_lean * 0.55
			p.head = -p.torso * 0.68 + double_step * 0.012
			p.head_z = -p.hips_z * 0.42

			p.ll = left_cycle * stride - 0.04
			p.lr = right_cycle * stride - 0.04
			p.kl = -(0.10 + left_recovery * lerpf(0.72, 1.28, run_speed)
				+ maxf(-left_cycle, 0.0) * 0.12)
			p.kr = -(0.10 + right_recovery * lerpf(0.72, 1.28, run_speed)
				+ maxf(-right_cycle, 0.0) * 0.12)
			# Ankles counter-rotate the leg chain so the visible feet stay close
			# to level through contact instead of pointing like pendulums.
			p.fl = clampf(-(p.ll + p.kl) * 0.72, -0.55, 0.72)
			p.fr = clampf(-(p.lr + p.kr) * 0.72, -0.55, 0.72)

			p.al = Vector3(-0.16 - left_cycle * arm_stride,
				-left_cycle * 0.07, 0.11 + absf(left_cycle) * 0.035)
			p.ar = Vector3(-0.16 - right_cycle * arm_stride,
				-right_cycle * 0.07, -0.11 - absf(right_cycle) * 0.035)
			p.el = 0.72 + maxf(left_cycle, 0.0) * 0.28 + run_speed * 0.12
			p.er = 0.72 + maxf(right_cycle, 0.0) * 0.28 + run_speed * 0.12
			p.tail_curl = lerpf(0.38, 0.18, run_speed)
			p.tail_sway = -balance * lerpf(0.16, 0.34, run_speed) - _turn_lean * 0.7
		Anim.SPRINT:
			# Gorilla-inspired transverse gallop. The pelvis drops while the spine
			# folds into a pronograde line; the ribcage twists over each supporting
			# knuckle and the head counter-rotates to keep the gaze level. Limb
			# endpoints are solved onto their individual contacts below.
			var gallop_phase := _gait_cycle * TAU
			var gather := cos(gallop_phase)
			var reach := sin(gallop_phase)
			var weight_shift := sin(gallop_phase + 0.62)
			p.hips_x = -0.38 + reach * 0.055
			p.hips_y = -0.248 + gather * 0.024
			p.hips_side = weight_shift * 0.018
			p.hips_z = weight_shift * 0.055 + _turn_lean * 0.34
			p.torso = -1.08 - reach * 0.060
			p.torso_y = -weight_shift * 0.095
			p.torso_z = -weight_shift * 0.045 - _turn_lean * 0.48
			p.head = 1.38 + reach * 0.038
			p.head_y = weight_shift * 0.075
			p.head_z = -p.hips_z * 0.58
			# FK is a safe transition pose; planted/swinging limbs use world-space
			# two-bone IK once the body has been blended into this posture.
			p.al = Vector3(0.92 - reach * 0.20, 0, 0.16)
			p.ar = Vector3(0.82 + reach * 0.20, 0, -0.16)
			p.el = 0.34 + maxf(reach, 0.0) * 0.34
			p.er = 0.34 + maxf(-reach, 0.0) * 0.34
			p.ll = -0.25 - reach * 0.22
			p.lr = -0.25 + reach * 0.22
			p.kl = -0.58 + maxf(reach, 0.0) * 0.28
			p.kr = -0.58 + maxf(-reach, 0.0) * 0.28
			p.fl = 0.42 - p.ll * 0.22
			p.fr = 0.42 - p.lr * 0.22
			# Hold the fuller tail in a shallow muscular arc; a straighter, faster
			# whip made even thick geometry read like a bare rat tail in the gallop.
			p.tail_curl = -0.08 + gather * 0.04
			p.tail_sway = -weight_shift * 0.46 - _turn_lean * 0.8
		Anim.AIR:
			p.hips_x = _air_pitch * 0.86
			p.hips_z = _air_roll * 0.86
			p.torso = -0.12
			# Positive local X rotation sends the long arms toward the monkey's
			# forward (-Z) side. The old negative value made the free arm stream
			# backward behind every third-person jump.
			p.al = Vector3(1.55, 0, 0.30)
			p.ar = Vector3(1.55, 0, -0.30)
			p.el = 0.5
			p.er = 0.5
			p.ll = 1.15
			p.kl = -1.5
			p.lr = 0.95
			p.kr = -1.35
			p.tail_curl = 0.7
		Anim.DIVE:
			p.hips_x = 1.3
			p.al = Vector3(1.5, 0, 0.25)
			p.ar = Vector3(1.5, 0, -0.25)
			p.el = 0.12
			p.er = 0.12
			p.ll = -0.25
			p.kl = -0.12
			p.lr = -0.25
			p.kr = -0.12
			p.tail_curl = -0.2
		Anim.WALLSLIDE:
			p.torso = 0.2
			p.al = Vector3(-2.7, 0, 0.7)
			p.ar = Vector3(-2.7, 0, -0.7)
			p.el = 0.6
			p.er = 0.6
			p.ll = 0.9
			p.kl = -1.2
			p.lr = 0.7
			p.kr = -1.0
		Anim.SWING:
			p.hips_x = _air_pitch
			p.hips_z = _air_roll
			p.hips_y = -0.24  # body sags below the grip
			p.torso = clampf(-_air_pitch * 0.10, -0.12, 0.12)
			p.torso_z = clampf(-_air_roll * 0.08, -0.10, 0.10)
			p.head = 0.34 - minf(absf(_air_pitch) * 0.08, 0.08)
			p.head_z = -_air_roll * 0.16
			p.al = Vector3(-2.9, 0, 0.3)   # FK fallback; IK overrides below
			p.ar = Vector3(-2.9, 0, -0.3)
			p.ll = 0.5 + sin(_t * 2.5) * 0.3
			p.kl = -(0.5 + sin(_t * 2.5 + 0.4) * 0.25)
			p.lr = 0.35 + sin(_t * 2.5 + 0.5) * 0.3
			p.kr = -(0.42 + sin(_t * 2.5 + 0.9) * 0.25)
			p.tail_curl = 0.9
			p.tail_sway = sin(_t * 3.0) * 0.3
			if _sniper_rope_blend > 0.001:
				# Hoist the pelvis toward the tail contact so the 0.54 m legs can
				# anatomically reach the taut strand. The blend keeps equipping a
				# rifle mid-arc from snapping the body upward in one frame.
				var brace_blend := _sniper_rope_blend * 0.58
				p.hips_y = lerpf(p.hips_y, 0.06, _sniper_rope_blend)
				p.ll = lerpf(p.ll, 0.86, brace_blend)
				p.kl = lerpf(p.kl, -1.08, brace_blend)
				p.lr = lerpf(p.lr, 0.68, brace_blend)
				p.kr = lerpf(p.kr, -0.94, brace_blend)
				p.fl = lerpf(p.fl, 0.22, brace_blend)
				p.fr = lerpf(p.fr, 0.14, brace_blend)
		Anim.SLIDE:
			p.hips_x = -1.15
			p.hips_y = -0.3
			p.head = 0.6
			p.al = Vector3(-0.7, 0, 0.5)
			p.ar = Vector3(-0.7, 0, -0.5)
			p.el = 0.3
			p.er = 0.3
			p.ll = -1.3
			p.kl = -0.25
			p.lr = -1.15
			p.kr = -0.35
			p.tail_curl = 0.1
		Anim.ROLL:
			p.hips_x = _roll_spin
			p.al = Vector3(0.8, 0, 0.3)
			p.ar = Vector3(0.8, 0, -0.3)
			p.el = 1.8
			p.er = 1.8
			p.ll = 1.4
			p.kl = -2.0
			p.lr = 1.4
			p.kr = -2.0
		Anim.FLIP_F, Anim.FLIP_B:
			# tight aerial tuck; hips_x is driven directly by the flip spin below
			p.al = Vector3(1.0, 0, 0.45)
			p.ar = Vector3(1.0, 0, -0.45)
			p.el = 1.75
			p.er = 1.75
			p.ll = 1.5
			p.kl = -2.1
			p.lr = 1.45
			p.kr = -2.05
			p.head = 0.4
			p.tail_curl = 1.1
		Anim.SWIM:
			# Front crawl: a forward-facing prone spine, alternating catch/pull/
			# recovery, axial shoulder roll, a six-beat flutter kick and a small
			# breath toward the recovering arm. Arm paths are finished with IK so
			# the paws actually enter, pull below and leave the water surface.
			var swim_phase := _gait_cycle * TAU
			var shoulder_roll := sin(swim_phase) * 0.19
			var kick := swim_phase * 3.0
			p.hips_x = -1.48
			p.hips_y = -0.315 + cos(kick * 2.0) * 0.012
			p.hips_z = sin(kick) * 0.026
			p.torso = -0.035 + cos(swim_phase * 2.0) * 0.018
			p.torso_y = shoulder_roll
			p.torso_z = -sin(swim_phase) * 0.035
			# Counter-pitch the neck so the face stays forward just above the
			# surface; every third kick group adds a restrained side breath.
			var breath_gate := pow(maxf(sin(swim_phase), 0.0), 5.0)
			p.head = 1.31 + cos(swim_phase * 2.0) * 0.025
			p.head_y = -shoulder_roll * 0.56 + breath_gate * 0.40
			p.head_z = -p.hips_z * 0.55
			# FK transition values; _swim_ik supplies the exact hand paths.
			p.al = Vector3(1.34, 0, 0.16)
			p.ar = Vector3(1.34, 0, -0.16)
			p.el = 0.36
			p.er = 0.36
			p.ll = sin(kick) * 0.30
			p.kl = -(0.10 + maxf(sin(kick), 0.0) * 0.22)
			p.lr = sin(kick + PI) * 0.30
			p.kr = -(0.10 + maxf(sin(kick + PI), 0.0) * 0.22)
			# Counter the prone pelvis plus hip/knee chain so the broad feet stay
			# streamlined horizontally instead of presenting vertical discs.
			p.fl = clampf(1.48 - (p.ll + p.kl), 1.08, 1.82)
			p.fr = clampf(1.48 - (p.lr + p.kr), 1.08, 1.82)
			p.tail_curl = -1.0
			p.tail_sway = sin(kick - 0.45) * 0.22
		Anim.SKID:
			# hard stop: weight back, front leg braced, arms thrown out behind
			p.hips_x = -0.5
			p.hips_y = -0.12
			p.torso = -0.25
			p.head = 0.35
			p.al = Vector3(-1.2, 0, 0.6)
			p.ar = Vector3(-1.2, 0, -0.6)
			p.el = 0.5
			p.er = 0.5
			p.ll = -0.9
			p.kl = -0.3
			p.fl = 0.55
			p.lr = -0.3
			p.kr = -0.85
			p.fr = 0.3
			p.tail_curl = -0.3
			p.tail_sway = sin(_t * 9.0) * 0.4
		Anim.RIDE:
			var ride_kind := Vehicle.Kind.BIKE
			if is_instance_valid(_vehicle_pose):
				ride_kind = int(_vehicle_pose.kind)
			match ride_kind:
				Vehicle.Kind.JEEP:
					# Upright bucket-seat posture. Final-pass IK below plants both
					# paws on the wheel and both feet on the pedals.
					p.hips_y = -0.08
					p.torso = 0.10
					p.head = -0.06
					p.al = Vector3(0.72, 0.10, 0.18)
					p.ar = Vector3(0.72, -0.10, -0.18)
					p.el = 0.88
					p.er = 0.88
					p.ll = 0.92
					p.lr = 0.92
					p.kl = -1.30
					p.kr = -1.30
					p.fl = 0.45
					p.fr = 0.45
					# Route the tail outboard and down around the bucket instead of
					# sending its straight root through the seat back.
					p.tail_curl = 0.92
					p.tail_root_x = 0.42
					p.tail_root_y = 1.52
				Vehicle.Kind.BOAT:
					# Raised airboat bench: one paw works the tiller while the
					# other braces on the rail; knees sit naturally over the rest.
					p.hips_y = -0.08
					p.torso = 0.15
					p.head = -0.10
					p.al = Vector3(0.62, 0.16, 0.24)
					p.ar = Vector3(0.58, -0.12, -0.18)
					p.el = 0.82
					p.er = 0.90
					p.ll = 0.82
					p.lr = 0.82
					p.kl = -1.22
					p.kr = -1.22
					p.fl = 0.38
					p.fr = 0.38
					# The fan hub sits directly behind the bench at tail height. Coil
					# forward across the safe starboard quarter so no segment can enter
					# the propeller disc, even while the hull pitches over a wave.
					p.tail_curl = 1.02
					p.tail_root_x = 0.18
					p.tail_root_y = 2.12
				_:
					# Motorcycle saddle: shoulders reach forward (positive local
					# X) while thighs fold onto the pegs. The previous negative arm
					# angles pointed both paws behind the monkey.
					p.hips_y = -0.10
					p.hips_x = 0.12
					p.torso = -0.50 - absf(_ride_lean) * 0.03
					p.head = 0.40
					p.al = Vector3(1.02, 0.12, 0.28)
					p.ar = Vector3(1.02, -0.12, -0.28)
					p.el = 0.72
					p.er = 0.72
					p.ll = 1.08
					p.lr = 1.08
					p.kl = -1.48
					p.kr = -1.48
					p.fl = 0.56
					p.fr = 0.56
					p.tail_curl = 0.18
			p.torso_z = -_ride_lean * 0.22
			p.head_z = _ride_lean * 0.30
			p.hips_z = -_ride_lean * 0.10
			p.tail_sway = -_ride_lean * 0.55 + sin(_t * 2.2) * 0.06
		Anim.PILOT:
			# Reclined ejection-seat posture: legs forward to the pedals, left
			# paw on the throttle quadrant, right paw centered on the stick.
			p.hips_y = -0.08
			p.hips_x = 0.08
			p.torso = -0.08
			p.head = 0.08
			p.head_z = _ride_lean * 0.10
			p.al = Vector3(0.68, 0.18, 0.22)
			p.ar = Vector3(0.86, -0.06, -0.10)
			p.el = 0.95
			p.er = 0.72
			p.ll = 0.92
			p.lr = 0.92
			p.kl = -1.08
			p.kr = -1.08
			p.fl = 0.30
			p.fr = 0.30
			# Drop the root below the ejection-seat back, then curl it beside the
			# cushion. A straight rearward tail pierced both the seat and canopy.
			p.tail_curl = 1.08
			p.tail_root_x = 1.18
			p.tail_root_y = 0.30
			p.tail_sway = sin(_t * 1.8) * 0.05

	if _melee_mode and _melee_attack_active:
		var strike_twist := _melee_pulse(
			_melee_attack_progress, 0.10, 0.42, 0.82)
		if _melee_combo == 0:
			p.torso_y += 0.24 * strike_twist
			p.head_y -= 0.10 * strike_twist
		elif _melee_combo == 1:
			p.torso_y -= 0.30 * strike_twist
			p.head_y += 0.12 * strike_twist
		else:
			p.torso += 0.22 * strike_twist
			p.head -= 0.10 * strike_twist

	var blend_rate := 18.0 if anim in [Anim.RUN, Anim.SPRINT, Anim.SWIM] else 12.0
	var w := 1.0 - exp(-blend_rate * dt)
	if anim == Anim.ROLL:
		hips.rotation.x = _roll_spin  # continuous flip; lerp_angle would wrap backward
	elif anim == Anim.FLIP_F or anim == Anim.FLIP_B:
		hips.rotation.x = _flip_spin
	else:
		hips.rotation.x = lerp_angle(hips.rotation.x, p.hips_x, w)
	hips.rotation.z = lerp_angle(hips.rotation.z, p.hips_z, w)
	hips.position.x = lerpf(hips.position.x, p.hips_side, w)
	hips.position.y = lerpf(hips.position.y, HIP_Y + p.hips_y, w)
	torso_p.rotation.x = lerp_angle(torso_p.rotation.x, p.torso, w)
	torso_p.rotation.y = lerp_angle(torso_p.rotation.y, p.torso_y, w)
	torso_p.rotation.z = lerp_angle(torso_p.rotation.z, p.torso_z, w)
	head_p.rotation.x = lerp_angle(head_p.rotation.x, p.head, w)
	head_p.rotation.y = lerp_angle(head_p.rotation.y, p.head_y, w)
	head_p.rotation.z = lerp_angle(head_p.rotation.z, p.head_z, w)
	sh_l.rotation = sh_l.rotation.lerp(p.al, w)
	sh_r.rotation = sh_r.rotation.lerp(p.ar, w)
	_blend_hinge_pose(el_l, p.el, w)
	_blend_hinge_pose(el_r, p.er, w)
	if anim == Anim.SPRINT or anim == Anim.SWIM:
		# The smoothing lerp above is a low-pass filter: at gait frequencies it
		# eats most of the limb motion (flutter kicks all but vanish) and lets
		# planted paws drift. Gait-driven joints are applied exactly, with a
		# short ramp on entry so the transition still blends.
		var dw := _anim_ramp
		sh_l.rotation.x = lerp_angle(sh_l.rotation.x, p.al.x, dw)
		sh_r.rotation.x = lerp_angle(sh_r.rotation.x, p.ar.x, dw)
		el_l.rotation.x = lerp_angle(el_l.rotation.x, p.el, dw)
		el_r.rotation.x = lerp_angle(el_r.rotation.x, p.er, dw)
		hip_l.rotation.x = lerp_angle(hip_l.rotation.x, p.ll, dw)
		kn_l.rotation.x = lerp_angle(kn_l.rotation.x, p.kl, dw)
		hip_r.rotation.x = lerp_angle(hip_r.rotation.x, p.lr, dw)
		kn_r.rotation.x = lerp_angle(kn_r.rotation.x, p.kr, dw)
	# Gallop/swim IK writes complete global bases into these joints. Restore every
	# local axis, not only the hinge bend, so leaving all-fours cannot preserve a
	# terrain-induced hip/knee/ankle twist in the normal bipedal pose.
	_blend_hinge_pose(hip_l, p.ll, w)
	_blend_hinge_pose(kn_l, p.kl, w)
	_blend_hinge_pose(hip_r, p.lr, w)
	_blend_hinge_pose(kn_r, p.kr, w)
	_blend_hinge_pose(foot_l, p.fl, w)
	_blend_hinge_pose(foot_r, p.fr, w)
	# The tail root is mounted behind the upright pelvis. Most locomotion keeps it
	# straight, while enclosed seats author a safe first segment before the chain
	# curls. This matters because changing only tail_curl cannot move the rigid
	# bridge between the rump and the first articulated joint.
	var tail_root_x: float = p.tail_root_x
	var tail_root_y: float = p.tail_root_y
	var tail_root_z: float = p.tail_root_z
	if anim == Anim.SPRINT:
		tail_root_x = 0.34
	elif anim == Anim.SWIM:
		tail_root_x = 1.62
	var tail_root: Node3D = tail_segs[0]
	tail_root.rotation.x = lerp_angle(tail_root.rotation.x, tail_root_x, w)
	tail_root.rotation.y = lerp_angle(tail_root.rotation.y, tail_root_y, w)
	tail_root.rotation.z = lerp_angle(tail_root.rotation.z, tail_root_z, w)
	for i in range(1, tail_segs.size()):
		var seg: Node3D = tail_segs[i]
		var tail_x: float = -p.tail_curl * 0.5
		var tail_y: float = p.tail_sway * (0.4 + i * 0.3)
		if anim == Anim.SPRINT:
			# A travelling wave makes the long tail counterbalance the asymmetric
			# gallop instead of rotating as one rigid hook.
			tail_x += sin(_gait_cycle * TAU - float(i) * 0.42) * 0.030
			tail_y = sin(_gait_cycle * TAU - float(i) * 0.42 - 0.18) \
				* (0.075 + float(i) * 0.018) - _turn_lean * 0.22
		elif anim == Anim.SWIM:
			# The root above redirects the chain into the wake. Small delayed
			# undulations then follow the kick without looking motor-driven.
			tail_x = 0.015 \
				+ sin(_gait_cycle * TAU * 3.0 - float(i) * 0.58) * 0.035
			tail_y = sin(_gait_cycle * TAU * 3.0 - float(i) * 0.68) \
				* (0.07 + float(i) * 0.025)
		seg.rotation.x = lerp_angle(seg.rotation.x, tail_x, w)
		seg.rotation.y = lerpf(seg.rotation.y, tail_y, w)
		seg.rotation.z = lerp_angle(seg.rotation.z, 0.0, w)

	# Gallop paws are solved onto sampled ground contacts. At the game's arcade
	# speeds the stance sweeps within anatomical reach rather than stretching a
	# half-metre limb toward an impossible literal world lock.
	if anim == Anim.SPRINT:
		_gallop_ik(vel, on_floor, h)
	elif anim == Anim.SWIM:
		_swim_ik()

	# Paw(s) glued to the rope: exact 2-bone IK after the FK blend. A weapon
	# carrier uses only the left support arm; without a weapon pose both hands
	# can share the grip.
	if anim == Anim.SWING and _rope_active:
		var rope_up := _rope_pivot - _rope_hand
		rope_up = rope_up.normalized() if rope_up.length() > 0.05 else Vector3.UP
		var yb := yaw_node.global_transform.basis
		if not _gun_aim_active and not _sniper_rope_pose:
			_ik_limb(sh_r, el_r, ARM_A, ARM_B,
				_rope_hand + rope_up * 0.06,
				yb * Vector3(1.0, -0.1, 0.55))
		if _sniper_rope_blend <= 0.001:
			_ik_limb(sh_l, el_l, ARM_A, ARM_B,
				_rope_hand + rope_up * (0.12 if _gun_aim_active else 0.22),
				yb * Vector3(-1.0, -0.1, 0.55))
		if _sniper_rope_blend > 0.001:
			_pose_sniper_rope_support(rope_up, yb, _sniper_rope_blend)

	# The weapon arm is solved last so a swinging monkey holds the vine
	# one-handed and keeps the gun raised with the other. Its elbow bends
	# outward on the right rather than crossing the torso, while the forearm
	# roll is corrected independently to keep the weapon upright on the aim ray.
	if _gun_aim_active:
		_pose_weapon_arm(_gun_aim_direction, _gun_recoil)
		if _sniper_rope_blend > 0.001 \
				and is_instance_valid(_sniper_support_grip):
			# The tail and feet now carry the rope, freeing both hands for the long
			# rifle. Solve after the firing arm because that arm moves the marker.
			_ik_limb_weighted(sh_l, el_l, ARM_A, ARM_B,
				_sniper_support_grip.global_position,
				yaw_node.global_transform.basis * Vector3(-1.0, -0.25, 0.62),
				_sniper_rope_blend)
	if _reload_pose and not _rope_active \
			and is_instance_valid(_reload_support_grip):
		# Track the actual flipped prop, not a canned point. The same IK therefore
		# follows banana magazines, box magazines, and individual shotgun shells.
		_ik_limb(sh_l, el_l, ARM_A, ARM_B,
			_reload_support_grip.global_position,
			yaw_node.global_transform.basis * Vector3(-0.78, -0.22, 0.62))
	if _melee_mode:
		_pose_melee_arms(_melee_attack_active, _melee_attack_progress,
			_melee_combo)
	elif _healing_pose:
		_pose_healing_arms(_healing_progress)
	if anim == Anim.RIDE or anim == Anim.PILOT:
		_pose_vehicle_controls()


## Plant all four limbs onto the machine after FK blending. Targets live under
## the actual steering/control nodes, so a turning wheel or bar carries the paws
## with it and the pose remains seated through body roll and pitch.
func _pose_vehicle_controls() -> void:
	if not is_instance_valid(_vehicle_pose):
		return
	var yb := yaw_node.global_transform.basis
	var target: Vector3
	if _vehicle_pose.has_rider_target(&"hand_left"):
		target = _vehicle_pose.rider_target_global(&"hand_left")
		_ik_limb(sh_l, el_l, ARM_A, ARM_B, target,
			yb * Vector3(-1.0, -0.22, 0.62))
	if _vehicle_pose.has_rider_target(&"hand_right"):
		target = _vehicle_pose.rider_target_global(&"hand_right")
		_ik_limb(sh_r, el_r, ARM_A, ARM_B, target,
			yb * Vector3(1.0, -0.22, 0.62))
	if _vehicle_pose.has_rider_target(&"foot_left"):
		target = _vehicle_pose.rider_target_global(&"foot_left")
		_ik_limb(hip_l, kn_l, LEG_A, LEG_B, target,
			yb * Vector3(-0.72, -0.12, -0.82))
	if _vehicle_pose.has_rider_target(&"foot_right"):
		target = _vehicle_pose.rider_target_global(&"foot_right")
		_ik_limb(hip_r, kn_r, LEG_A, LEG_B, target,
			yb * Vector3(0.72, -0.12, -0.82))


## Aim the fluffy articulated tail into a broad coil below the support hand,
## then bring the feet close enough to pinch/brace the vine. All nodes retain
## their authored offsets, so the root socket stays buried in the rump and the
## overlapping tail cores cannot pull apart while the world-space bases turn.
func _pose_sniper_rope_support(rope_up: Vector3, body_basis: Basis,
		weight: float) -> void:
	var support := smoothstep(0.0, 1.0, clampf(weight, 0.0, 1.0))
	if support <= 0.001 or tail_segs.is_empty():
		return
	var axis := rope_up.normalized()
	if axis.length_squared() < 0.001:
		axis = Vector3.UP
	var tail_root: Node3D = tail_segs[0]
	# Use the taut anchor-to-hand segment, which always exists. A grab can happen
	# at the very tip of a vine (no loose rope below the nominal hand point), so
	# placing these contacts on the trailing tail would make them clutch empty air.
	var wrap_center := _rope_hand + axis * 0.10
	var radial := tail_root.global_position - wrap_center
	radial -= axis * radial.dot(axis)
	if radial.length_squared() < 0.001:
		radial = body_basis.z - axis * body_basis.z.dot(axis)
	if radial.length_squared() < 0.001:
		radial = body_basis.x - axis * body_basis.x.dot(axis)
	radial = radial.normalized()
	var tangent := axis.cross(radial).normalized()
	var coil_radius := 0.105
	var targets: Array[Vector3] = [
		wrap_center + radial * coil_radius - axis * 0.10,
		wrap_center + radial * coil_radius - axis * 0.02,
		wrap_center + tangent * coil_radius * 0.82 + axis * 0.015,
		wrap_center - radial * coil_radius * 0.72 + axis * 0.045,
		wrap_center - tangent * coil_radius * 0.38 + axis * 0.030,
	]
	for i in range(mini(tail_segs.size(), targets.size())):
		var joint: Node3D = tail_segs[i]
		var toward_target: Vector3 = targets[i] - joint.global_position
		if toward_target.length_squared() < 0.0001:
			continue
		var current := joint.global_transform
		var desired_basis := _tail_forward_basis(toward_target, axis).orthonormalized()
		var joint_weight := support * (0.84 if i == 0 else 0.92)
		joint.global_transform = Transform3D(
			current.basis.orthonormalized().slerp(desired_basis, joint_weight),
			current.origin)
	# Finish with a short weighted CCD pass. This retains the broad authored coil
	# but guarantees that the fluffy tip actually intersects the vine instead of
	# merely pointing toward it.
	_tail_ik_contact(wrap_center, support)

	# Staggered contacts read as a brace rather than two rigid feet clamped at
	# the same height. Their partial IK weights retain some pendulum motion.
	var brace_right := body_basis.x - axis * body_basis.x.dot(axis)
	if brace_right.length_squared() < 0.001:
		brace_right = tangent
	brace_right = brace_right.normalized()
	var body_forward := -body_basis.z
	var near_side := radial * 0.018
	var left_target := _rope_hand + axis * 0.005 \
		- brace_right * 0.045 + near_side
	var right_target := _rope_hand + axis * 0.045 \
		+ brace_right * 0.045 + near_side
	_ik_limb_weighted(hip_l, kn_l, LEG_A, LEG_B, left_target,
		-brace_right + body_forward * 0.22 + Vector3.DOWN * 0.16,
		support)
	_ik_limb_weighted(hip_r, kn_r, LEG_A, LEG_B, right_target,
		brace_right + body_forward * 0.18 + Vector3.DOWN * 0.14,
		support)


func _tail_ik_contact(target: Vector3, weight: float) -> void:
	if tail_segs.size() < 2:
		return
	var tip_local := Vector3(0.0, 0.0, 0.17)
	for iteration in range(4):
		for index in range(tail_segs.size() - 1, -1, -1):
			var joint: Node3D = tail_segs[index]
			var tip: Vector3 = tail_segs[tail_segs.size() - 1].to_global(
				tip_local)
			var from_tip := tip - joint.global_position
			var to_contact := target - joint.global_position
			if from_tip.length_squared() < 0.0001 \
					or to_contact.length_squared() < 0.0001:
				continue
			var arc := Quaternion(from_tip.normalized(), to_contact.normalized())
			var current := joint.global_transform
			var solved := (Basis(arc) * current.basis.orthonormalized()).orthonormalized()
			var joint_weight := clampf(weight * (0.46 if index == 0 else 0.68),
				0.0, 0.82)
			joint.global_transform = Transform3D(
				current.basis.orthonormalized().slerp(solved, joint_weight),
				current.origin)


## Tail cores and joint offsets both point down local +Z.
func _tail_forward_basis(forward: Vector3, up_hint: Vector3) -> Basis:
	var z_axis := forward.normalized()
	var x_axis := up_hint.cross(z_axis)
	if x_axis.length_squared() < 0.001:
		x_axis = Vector3.UP.cross(z_axis)
	if x_axis.length_squared() < 0.001:
		x_axis = Vector3.RIGHT
	x_axis = x_axis.normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	return Basis(x_axis, y_axis, z_axis)


func _blend_hinge_pose(joint: Node3D, target_x: float, weight: float) -> void:
	joint.rotation.x = lerp_angle(joint.rotation.x, target_x, weight)
	joint.rotation.y = lerp_angle(joint.rotation.y, 0.0, weight)
	joint.rotation.z = lerp_angle(joint.rotation.z, 0.0, weight)


func _advance_air_tilt(dt: float, target_pitch: float, target_roll: float,
		stiffness: float, damping: float) -> void:
	var pitch_accel := angle_difference(_air_pitch, target_pitch) * stiffness \
		- _air_pitch_velocity * damping
	var roll_accel := angle_difference(_air_roll, target_roll) * stiffness \
		- _air_roll_velocity * damping
	_air_pitch_velocity = clampf(_air_pitch_velocity + pitch_accel * dt, -5.5, 5.5)
	_air_roll_velocity = clampf(_air_roll_velocity + roll_accel * dt, -5.5, 5.5)
	_air_pitch += _air_pitch_velocity * dt
	_air_roll += _air_roll_velocity * dt


## Analytic 2-bone IK: aims the shoulder and bends the elbow so the paw
## (elbow-local (0,-b,0)) lands exactly on `target`, elbow toward `pole`.
func _ik_limb(shoulder: Node3D, elbow: Node3D, a: float, b: float, target: Vector3, pole: Vector3) -> void:
	var s_pos := shoulder.global_position
	var v := target - s_pos
	var dl := v.length()
	if dl < 0.02:
		return
	var vn := v / dl
	var d := clampf(dl, absf(a - b) + 0.02, a + b - 0.01)
	var axis := vn.cross(pole.normalized())
	if axis.length() < 0.02:
		axis = vn.cross(Vector3.RIGHT)
	if axis.length() < 0.02:
		axis = vn.cross(Vector3.FORWARD)
	axis = axis.normalized()
	var alpha := acos(clampf((a * a + d * d - b * b) / (2.0 * a * d), -1.0, 1.0))
	var upper_dir := vn.rotated(axis, alpha)
	var e_pos := s_pos + upper_dir * a
	var fore_dir := (target - e_pos).normalized()
	shoulder.global_transform = Transform3D(_limb_basis(upper_dir, axis), s_pos)
	elbow.global_transform = Transform3D(_limb_basis(fore_dir, axis), e_pos)


func _ik_limb_weighted(shoulder: Node3D, elbow: Node3D, a: float, b: float,
		target: Vector3, pole: Vector3, weight: float) -> void:
	var blend := clampf(weight, 0.0, 1.0)
	if blend >= 0.999:
		_ik_limb(shoulder, elbow, a, b, target, pole)
		return
	var shoulder_before := shoulder.global_transform
	var elbow_before := elbow.global_transform
	_ik_limb(shoulder, elbow, a, b, target, pole)
	var shoulder_solved := shoulder.global_transform
	var elbow_solved := elbow.global_transform
	shoulder.global_transform = shoulder_before.interpolate_with(
		shoulder_solved, blend)
	elbow.global_transform = elbow_before.interpolate_with(elbow_solved, blend)


func _limb_basis(dir: Vector3, axis: Vector3) -> Basis:
	var yv := -dir
	var zv := axis.cross(yv).normalized()
	var xv := yv.cross(zv).normalized()
	return Basis(xv, yv, zv)


## One limb's place in a repeating gait cycle. `offset` is where its ground
## contact begins in the normalized cycle, `duty` the fraction spent planted.
## Returns (x: 1 during stance else 0, y: progress 0..1 through that phase).
static func _gait_limb(cycle: float, offset: float, duty: float) -> Vector2:
	var local := fposmod(cycle - offset, 1.0)
	if local < duty:
		return Vector2(1.0, local / duty)
	return Vector2(0.0, (local - duty) / (1.0 - duty))


static func _gallop_frequency(horizontal_speed: float) -> float:
	return lerpf(1.9, 3.05,
		clampf((horizontal_speed - 5.5) / 8.0, 0.0, 1.0))


func _reset_gait_plants() -> void:
	for plant in _plants:
		plant.on = false
		plant.pos = Vector3.ZERO
		plant.from = Vector3.ZERO
	_last_gait_origin = Vector3.INF


## Raycast each prospective contact onto the actual terrain/branch under that
## limb. This keeps four-paw locomotion attached on slopes instead of solving
## every knuckle to the root's single Y coordinate.
func _ground_contact(candidate: Vector3, fallback_y: float,
		contact_offset: float) -> Dictionary:
	if not is_inside_tree() or not get_world_3d():
		return {
			"position": Vector3(candidate.x, fallback_y + contact_offset,
				candidate.z),
			"normal": Vector3.UP,
		}
	var from := Vector3(candidate.x, maxf(candidate.y, fallback_y) + 0.85,
		candidate.z)
	var to := Vector3(candidate.x, fallback_y - 1.25, candidate.z)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	var actor := get_parent()
	if actor is CollisionObject3D:
		query.exclude = [actor.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		return {
			"position": hit.position + hit.normal * contact_offset,
			"normal": hit.normal,
		}
	return {
		"position": Vector3(candidate.x, fallback_y + contact_offset,
			candidate.z),
		"normal": Vector3.UP,
	}


## Reach-bounded transverse-gallop solver. Stance paws sweep rearward along the
## sampled ground and recovery paws return through a lift arc. Airborne bounds
## stretch fore limbs forward and trail the hind pair.
func _gallop_ik(vel: Vector3, on_floor: bool, h: float) -> void:
	if _last_gait_origin != Vector3.INF \
			and global_position.distance_to(_last_gait_origin) > 2.5:
		_reset_gait_plants()
	_last_gait_origin = global_position
	var speed_weight := clampf((h - 6.0) / 7.0, 0.0, 1.0)
	var duty := lerpf(0.34, 0.27, speed_weight)
	var yb := yaw_node.global_transform.basis
	var fwd := -yb.z
	var right := yb.x
	var ground_y := global_position.y
	var shoulders := [sh_l, sh_r, hip_l, hip_r]
	var elbows := [el_l, el_r, kn_l, kn_r]
	var upper_lens := PackedFloat32Array([ARM_A, ARM_A, LEG_A, LEG_A])
	var lower_lens := PackedFloat32Array([ARM_B, ARM_B, LEG_B, LEG_B])
	# Transverse gallop: hind pair leads, then the fore pair absorbs the load,
	# followed by a real suspension interval at the fast end of the gait.
	var offsets := PackedFloat32Array([0.39, 0.52, 0.00, 0.14])
	var lateral := PackedFloat32Array([-0.045, 0.045, -0.035, 0.035])
	var lifts := PackedFloat32Array([0.13, 0.13, 0.17, 0.17])
	# elbows hinge backward like a knuckle-walker, knees tuck forward
	var poles := [
		yb * Vector3(-1.0, -0.2, 0.9), yb * Vector3(1.0, -0.2, 0.9),
		yb * Vector3(-0.8, -0.2, -0.9), yb * Vector3(0.8, -0.2, -0.9),
	]
	for i in range(4):
		var plant: Dictionary = _plants[i]
		var anchor: Node3D = shoulders[i]
		var base := Vector3(anchor.global_position.x, ground_y,
			anchor.global_position.z) + right * lateral[i]
		base += fwd * (0.025 if i < 2 else -0.018)
		var target: Vector3
		var contact_normal := Vector3.UP
		if not on_floor:
			# stretched bound: fore limbs reach for the landing, hind trail
			plant.on = false
			if i < 2:
				target = anchor.global_position + fwd * 0.38 \
					+ Vector3.DOWN * 0.24 + right * lateral[i] * 0.3
			else:
				target = anchor.global_position - fwd * 0.25 \
					+ Vector3.DOWN * 0.31 + right * lateral[i] * 0.3
		else:
			var g := _gait_limb(_gait_cycle, offsets[i], duty)
			var offset_height := 0.055 if i < 2 else 0.042
			if g.x > 0.5:
				# The controller covers many body lengths per second, so a literal
				# world-locked foot would exceed this small rig's reach. Sweep a
				# bounded contact rearward under the body: it preserves a planted
				# stance silhouette without ever saturating the two-bone solver.
				plant.on = true
				var stance_progress := smoothstep(0.0, 1.0, g.y)
				var fore_reach := 0.115 if i < 2 else 0.095
				var rear_reach := 0.105 if i < 2 else 0.125
				var candidate := base + fwd \
					* lerpf(fore_reach, -rear_reach, stance_progress)
				var contact := _ground_contact(candidate, ground_y, offset_height)
				target = contact.position
				contact_normal = contact.normal
				plant.pos = target
			else:
				plant.on = false
				var swing_progress := smoothstep(0.0, 1.0, g.y)
				var rear_reach := 0.105 if i < 2 else 0.125
				var fore_reach := 0.115 if i < 2 else 0.095
				var candidate := base + fwd \
					* lerpf(-rear_reach, fore_reach, swing_progress)
				var contact := _ground_contact(candidate, ground_y, offset_height)
				target = contact.position \
					+ contact.normal * sin(g.y * PI) * lifts[i]
				contact_normal = contact.normal
		_ik_limb_weighted(anchor, elbows[i], upper_lens[i], lower_lens[i],
			target, poles[i], smoothstep(0.08, 0.72, _anim_ramp))
		if i >= 2:
			_align_foot_to_surface(foot_l if i == 2 else foot_r,
				contact_normal, fwd)
	_sprint_was_floor = on_floor


func _align_foot_to_surface(foot: MeshInstance3D, normal: Vector3,
		forward: Vector3) -> void:
	var up := normal.normalized()
	var toe_direction := forward - up * forward.dot(up)
	if toe_direction.length_squared() < 0.001:
		toe_direction = Vector3.FORWARD
	toe_direction = toe_direction.normalized()
	# The foot mesh's toes extend along local -Z.
	var z_axis := -toe_direction
	var x_axis := up.cross(z_axis).normalized()
	z_axis = x_axis.cross(up).normalized()
	var scale := foot.global_transform.basis.get_scale()
	foot.global_transform = Transform3D(
		Basis(x_axis, up, z_axis).scaled(scale), foot.global_position)


## Piecewise paw path for a front-crawl stroke. The underwater pull uses a
## deep, long S-curve; the recovery clears the surface with a high elbow before
## extending into the next entry.
func _swim_arm_target(shoulder: Node3D, phase: float, side: float,
		forward: Vector3, right: Vector3) -> Array:
	var q := fposmod(phase, 1.0)
	var shoulder_pos := shoulder.global_position
	var surface_y := Visuals.water_surface_y(shoulder_pos.x, shoulder_pos.z, _t)
	var target: Vector3
	var pole: Vector3
	if q < 0.08:
		var u := smoothstep(0.0, 1.0, q / 0.08)
		target = shoulder_pos + forward * lerpf(0.42, 0.44, u) \
			+ right * side * 0.055
		target.y = lerpf(surface_y + 0.060, surface_y + 0.010, u)
		pole = right * side * 0.9 + Vector3.UP * 0.25 + forward * 0.25
	elif q < 0.54:
		var u := smoothstep(0.0, 1.0, (q - 0.08) / 0.46)
		var sweep := lerpf(0.43, -0.31, u)
		var depth := 0.02 + sin(u * PI) * 0.18
		var scull := sin(u * PI) * 0.055
		target = shoulder_pos + forward * sweep \
			+ right * side * (0.055 - scull)
		target.y = surface_y - depth
		pole = right * side * 0.92 + Vector3.DOWN * 0.25 - forward * 0.12
	elif q < 0.64:
		var u := smoothstep(0.0, 1.0, (q - 0.54) / 0.10)
		target = shoulder_pos - forward * lerpf(0.31, 0.37, u) \
			+ right * side * 0.07
		target.y = lerpf(surface_y - 0.020, surface_y + 0.070, u)
		pole = right * side + Vector3.UP * 0.55 - forward * 0.15
	else:
		var u := smoothstep(0.0, 1.0, (q - 0.64) / 0.36)
		var sweep := lerpf(-0.37, 0.42, u)
		var recovery_arc := sin(u * PI)
		target = shoulder_pos + forward * sweep \
			+ right * side * (0.09 + recovery_arc * 0.04)
		target.y = surface_y + 0.070 + recovery_arc * 0.16
		pole = right * side * 0.95 + Vector3.UP * 1.15 + forward * 0.12
	return [target, pole]


func _swim_ik() -> void:
	var body_basis := yaw_node.global_transform.basis
	var forward := -body_basis.z
	var right := body_basis.x
	var left_path := _swim_arm_target(sh_l, _gait_cycle, -1.0,
		forward, right)
	var right_path := _swim_arm_target(sh_r, _gait_cycle + 0.5, 1.0,
		forward, right)
	var ik_weight := smoothstep(0.08, 0.72, _anim_ramp)
	_ik_limb_weighted(sh_l, el_l, ARM_A, ARM_B, left_path[0], left_path[1],
		ik_weight)
	_ik_limb_weighted(sh_r, el_r, ARM_A, ARM_B, right_path[0], right_path[1],
		ik_weight)


## Place the elbow out and below the shoulder, then aim the entire forearm
## along the shot direction. Unlike point-target IK, this preserves barrel
## orientation instead of letting the forearm approach the aim point sideways.
func _pose_weapon_arm(direction: Vector3, recoil: float) -> void:
	var aim := direction.normalized()
	if aim.length_squared() < 0.001:
		return
	var shoulder_position := sh_r.global_position
	var body_basis := yaw_node.global_transform.basis
	# A rope sniper is supported by both hands, so bring the firing elbow inward
	# and center the receiver where the opposite 0.50 m arm can genuinely reach.
	# Ordinary one-handed weapons keep their wider, clearer elbow silhouette.
	var elbow_side := Vector3.LEFT if _sniper_rope_blend > 0.001 \
		else Vector3.RIGHT
	var elbow_hint := (
		body_basis * elbow_side * 0.72
		+ Vector3.DOWN * 0.48
		+ aim * 0.18
	)
	var bend_direction := elbow_hint - aim * elbow_hint.dot(aim)
	if bend_direction.length_squared() < 0.001:
		bend_direction = body_basis * Vector3.RIGHT
	bend_direction = bend_direction.normalized()
	var bend_angle := 0.62 + recoil * 0.12
	var upper_direction := (
		aim * cos(bend_angle) + bend_direction * sin(bend_angle)
	).normalized()
	var bend_axis := aim.cross(bend_direction).normalized()
	var elbow_position := shoulder_position + upper_direction * ARM_A
	sh_r.global_transform = Transform3D(
		_limb_basis(upper_direction, bend_axis), shoulder_position)
	el_r.global_position = elbow_position
	var preferred_up := Vector3.UP
	if absf(aim.dot(preferred_up)) > 0.94:
		preferred_up = body_basis * Vector3.FORWARD
	_orient_weapon_forearm(el_r, aim, preferred_up)


func _pose_healing_arms(progress: float) -> void:
	var p := clampf(progress, 0.0, 1.0)
	var body_basis := yaw_node.global_transform.basis
	var forward := body_basis * Vector3.FORWARD
	var right := body_basis * Vector3.RIGHT
	# Work just off the right side of the chest. From the default shoulder camera
	# this keeps the wrap, orbiting roll, and tug visible instead of hiding both
	# paws directly behind the torso silhouette.
	var center := torso_p.global_position + forward * 0.16 + right * 0.30 \
		+ Vector3.UP * 0.14
	var left_target := center - right * 0.08
	var right_target := center + right * 0.12 + Vector3.DOWN * 0.02
	var wrap := SatisfyingReload.phase(p, 0.20, 0.72)
	var tug := SatisfyingReload.pulse(p, 0.70, 0.82, 0.92)
	if wrap > 0.0:
		var angle := wrap * TAU * 2.0
		right_target = left_target + right * cos(angle) * 0.10 \
			+ Vector3.UP * sin(angle) * 0.07 + forward * 0.025
	left_target -= right * 0.06 * tug
	right_target += right * 0.17 * tug
	_ik_limb(sh_l, el_l, ARM_A, ARM_B, left_target,
		body_basis * Vector3(-0.75, -0.28, 0.58))
	_ik_limb(sh_r, el_r, ARM_A, ARM_B, right_target,
		body_basis * Vector3(0.75, -0.28, 0.58))
	_update_bandage_props()


func _build_bandage_props() -> void:
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color(0.96, 0.93, 0.78)
	cloth.roughness = 0.94
	var cloth_edge := StandardMaterial3D.new()
	cloth_edge.albedo_color = Color(0.66, 0.60, 0.46)
	cloth_edge.roughness = 0.98

	bandage_roll = Node3D.new()
	bandage_roll.name = "BandageRoll"
	bandage_roll.position = Vector3(0.0, -0.016, -0.062)
	bandage_roll.rotation.z = PI * 0.5
	paw_r.add_child(bandage_roll)
	var roll_mesh := CylinderMesh.new()
	roll_mesh.top_radius = 0.060
	roll_mesh.bottom_radius = 0.060
	roll_mesh.height = 0.070
	roll_mesh.radial_segments = 12
	var roll := MeshInstance3D.new()
	roll.mesh = roll_mesh
	roll.material_override = cloth
	bandage_roll.add_child(roll)
	var core_mesh := CylinderMesh.new()
	core_mesh.top_radius = 0.022
	core_mesh.bottom_radius = 0.022
	core_mesh.height = 0.076
	core_mesh.radial_segments = 10
	var core := MeshInstance3D.new()
	core.mesh = core_mesh
	core.material_override = cloth_edge
	bandage_roll.add_child(core)

	var wrist_mesh := CylinderMesh.new()
	wrist_mesh.top_radius = 0.067
	wrist_mesh.bottom_radius = 0.067
	wrist_mesh.height = 0.115
	wrist_mesh.radial_segments = 12
	bandage_wrist = MeshInstance3D.new()
	bandage_wrist.name = "BandageWristWrap"
	bandage_wrist.mesh = wrist_mesh
	bandage_wrist.material_override = cloth
	bandage_wrist.position = Vector3(0.0, -ARM_B + 0.040, 0.0)
	el_l.add_child(bandage_wrist)

	var strip_mesh := BoxMesh.new()
	strip_mesh.size = Vector3(0.032, 1.0, 0.010)
	bandage_strip = MeshInstance3D.new()
	bandage_strip.name = "BandageStrip"
	bandage_strip.mesh = strip_mesh
	bandage_strip.material_override = cloth
	yaw_node.add_child(bandage_strip)
	for visual in [roll, core, bandage_wrist, bandage_strip]:
		if _is_local_visual:
			visual.layers = LOCAL_BODY_VISUAL_LAYER
	bandage_roll.visible = false
	bandage_wrist.visible = false
	bandage_strip.visible = false


func _update_bandage_props() -> void:
	if not bandage_roll or not bandage_wrist or not bandage_strip:
		return
	var p := _healing_progress
	bandage_roll.visible = _healing_pose and p < 0.96
	bandage_wrist.visible = _healing_pose and p >= 0.18
	bandage_strip.visible = _healing_pose and p >= 0.10 and p < 0.93
	if not _healing_pose:
		return
	bandage_roll.scale = Vector3.ONE * lerpf(1.0, 0.60,
		SatisfyingReload.phase(p, 0.20, 0.74))
	bandage_roll.rotation.x = p * TAU * 4.0
	bandage_wrist.scale = Vector3(1.0,
		lerpf(0.24, 1.0, SatisfyingReload.phase(p, 0.18, 0.72)), 1.0)
	if not bandage_strip.visible:
		return
	var from := paw_l.global_position
	var to := paw_r.global_position
	var span := to - from
	if span.length_squared() < 0.0001:
		return
	var direction := span.normalized()
	var side := yaw_node.global_transform.basis.x
	bandage_strip.global_transform = Transform3D(
		_limb_basis(direction, side).scaled(
			Vector3(1.0, span.length(), 1.0)),
		from.lerp(to, 0.5))


func _pose_melee_arms(attack_active: bool, progress: float, combo: int) -> void:
	var body_basis := yaw_node.global_transform.basis
	var forward := body_basis * Vector3.FORWARD
	var right := body_basis * Vector3.RIGHT
	var left_guard := (
		sh_l.global_position + forward * 0.30 + Vector3.UP * 0.055
		+ right * 0.055
	)
	var right_guard := (
		sh_r.global_position + forward * 0.30 + Vector3.UP * 0.035
		- right * 0.045
	)
	var left_target := left_guard
	var right_target := right_guard
	if attack_active:
		var strike := _melee_pulse(progress, 0.10, 0.40, 0.80)
		match posmod(combo, 3):
			0:
				# Right straight: short shoulder wind-up, fast full extension,
				# then an equally controlled recovery into the guard.
				var windup := 1.0 - smoothstep(0.0, 0.18, progress)
				right_target += -forward * 0.10 * windup + right * 0.08 * windup
				right_target = right_target.lerp(
					sh_r.global_position + forward * (ARM_A + ARM_B - 0.025)
					+ Vector3.UP * 0.015, strike)
			1:
				# Left hook travels from outside the shoulder across the chest.
				var hook_target := (
					sh_l.global_position + forward * 0.40
					+ right * 0.19 + Vector3.UP * 0.025
				)
				left_target += -right * 0.13 * (
					1.0 - smoothstep(0.0, 0.24, progress))
				left_target = left_target.lerp(hook_target, strike)
			_:
				# Two-paw hammer strike rises over the brow, then drives down
				# and forward with a small amount of hand separation.
				var lift := 1.0 - smoothstep(0.24, 0.52, progress)
				var slam := _melee_pulse(progress, 0.28, 0.56, 0.92)
				var high_center := (
					(sh_l.global_position + sh_r.global_position) * 0.5
					+ Vector3.UP * 0.31 + forward * 0.12
				)
				var low_center := (
					(sh_l.global_position + sh_r.global_position) * 0.5
					+ forward * 0.43 - Vector3.UP * 0.13
				)
				var center := high_center.lerp(low_center, slam)
				left_target = left_guard.lerp(
					center - right * 0.055, maxf(lift, slam))
				right_target = right_guard.lerp(
					center + right * 0.055, maxf(lift, slam))

	_ik_limb(sh_l, el_l, ARM_A, ARM_B, left_target,
		-right * 0.85 + Vector3.DOWN * 0.35 + forward * 0.2)
	_ik_limb(sh_r, el_r, ARM_A, ARM_B, right_target,
		right * 0.85 + Vector3.DOWN * 0.35 + forward * 0.2)


static func _melee_pulse(progress: float, start: float, peak: float,
		finish: float) -> float:
	if progress <= peak:
		return smoothstep(start, peak, progress)
	return 1.0 - smoothstep(peak, finish, progress)


## Weapon models rotate their local -Z barrel onto the forearm's local -Y.
## Choosing the forearm roll here therefore keeps the barrel on the aim ray
## while mapping the weapon's local up toward world up.
func _orient_weapon_forearm(elbow: Node3D, forward: Vector3,
		preferred_up: Vector3) -> void:
	var aim := forward.normalized()
	var weapon_up := preferred_up - aim * preferred_up.dot(aim)
	if weapon_up.length_squared() < 0.001:
		weapon_up = Vector3.FORWARD - aim * Vector3.FORWARD.dot(aim)
	weapon_up = weapon_up.normalized()
	var local_y := -aim
	var local_z := -weapon_up
	var local_x := local_y.cross(local_z).normalized()
	local_z = local_x.cross(local_y).normalized()
	elbow.global_transform = Transform3D(
		Basis(local_x, local_y, local_z), elbow.global_position)


# ---- angel wings (admin fly mode) ------------------------------------------


## Grows a pair of feathered angel wings out of the back. Built lazily on the
## first request, then folded/unfolded with an eased blend so enabling fly mode
## reads as the wings sprouting rather than popping into existence.
func set_angel_wings(active: bool) -> void:
	if active and not _wing_l:
		_build_angel_wings()
	_wings_active = active


func has_angel_wings_visible() -> bool:
	return _wing_l != null and _wing_unfold > 0.05


func _build_angel_wings() -> void:
	var feather := StandardMaterial3D.new()
	feather.albedo_color = Color(0.97, 0.97, 0.99)
	feather.roughness = 0.72
	feather.emission_enabled = true
	feather.emission = Color(0.92, 0.94, 1.0)
	feather.emission_energy_multiplier = 0.14
	for side in [-1.0, 1.0]:
		var root := Node3D.new()
		root.name = "AngelWingL" if side < 0.0 else "AngelWingR"
		root.position = Vector3(0.085 * side, 0.34, 0.16)
		torso_p.add_child(root)
		# Three sweeping feather rows, each row a fan of flattened capsules.
		for row in range(3):
			var row_length: float = [0.62, 0.47, 0.33][row]
			var row_lift: float = [0.30, 0.16, 0.02][row]
			for i in range(4):
				var t := float(i) / 3.0
				var quill := MeshInstance3D.new()
				var m := CapsuleMesh.new()
				m.radius = 0.028
				m.height = row_length * lerpf(1.0, 0.55, t)
				m.radial_segments = 6
				m.rings = 2
				quill.mesh = m
				quill.material_override = feather
				quill.cast_shadow = \
					GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				if _is_local_visual:
					quill.layers = LOCAL_BODY_VISUAL_LAYER
				quill.position = Vector3(
					side * (0.10 + t * 0.30) * (1.0 - 0.18 * row),
					row_lift - t * (0.14 + 0.10 * row),
					0.035 * row)
				quill.rotation = Vector3(0.0, 0.0,
					side * (-0.55 - t * 0.85 - row * 0.10))
				quill.scale = Vector3(1.0, 1.0, 0.35)
				root.add_child(quill)
		if side < 0.0:
			_wing_l = root
		else:
			_wing_r = root
	_wing_l.scale = Vector3.ONE * 0.02
	_wing_r.scale = Vector3.ONE * 0.02


func _update_angel_wings(dt: float) -> void:
	if not _wing_l:
		return
	var target := 1.0 if _wings_active else 0.0
	_wing_unfold = move_toward(_wing_unfold, target, dt * 1.8)
	var visible_now := _wing_unfold > 0.01
	_wing_l.visible = visible_now
	_wing_r.visible = visible_now
	if not visible_now:
		return
	var grow: float = SatisfyingReload.smooth01(_wing_unfold)
	var flap := sin(_t * 3.1) * 0.30 + sin(_t * 6.2) * 0.06
	var spread := lerpf(-1.15, 0.28 + flap * 0.5, grow)
	for entry in [[_wing_l, 1.0], [_wing_r, -1.0]]:
		var wing: Node3D = entry[0]
		var side: float = entry[1]
		wing.scale = Vector3.ONE * maxf(grow, 0.02)
		wing.rotation = Vector3(0.12 - flap * 0.22, side * spread, 0.0)
