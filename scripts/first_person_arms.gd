class_name FirstPersonArms
extends Node3D
## Camera-local two-arm rig. Each weapon gets a distinct support-hand pose,
## while recoil, pump timing, reloading, aiming, and movement keep the hands
## attached to the procedural viewmodel. On a vine, the left paw releases the
## weapon and follows the world-space rope grip while the right keeps firing.

const ARM_VISUAL_SCALE := 1.12

var actor: Node3D
var _left_upper: MeshInstance3D
var _left_fore: MeshInstance3D
var _left_paw: Node3D
var _right_upper: MeshInstance3D
var _right_fore: MeshInstance3D
var _right_paw: Node3D
var _bandage_roll: Node3D
var _bandage_strip: MeshInstance3D
var _fur_material: Material
var _skin_material: Material
var _sleeve_meshes: Array[MeshInstance3D] = []
var _glove_meshes: Array[MeshInstance3D] = []
var _space_suit_equipped := false
var _left_elbow := Vector3.ZERO
var _left_hand := Vector3.ZERO
var _right_elbow := Vector3.ZERO
var _right_hand := Vector3.ZERO
var _aim_blend := 0.0
var _t := 0.0


func configure(owner_actor: Node3D) -> void:
	actor = owner_actor


func _ready() -> void:
	var display_name: String = actor.display_name if actor else "Monkey"
	var fur_color: Color = MonkeyRig.FURS[
		absi(hash(display_name)) % MonkeyRig.FURS.size()]
	_fur_material = Visuals.fur_material(fur_color)
	_skin_material = Visuals.skin_material()
	_left_upper = _limb_mesh(0.039 * ARM_VISUAL_SCALE, _fur_material)
	_left_fore = _forearm_mesh(_fur_material)
	_left_paw = _paw_mesh(_skin_material, true)
	_right_upper = _limb_mesh(0.039 * ARM_VISUAL_SCALE, _fur_material)
	_right_fore = _forearm_mesh(_fur_material)
	_right_paw = _paw_mesh(_skin_material, false)
	_sleeve_meshes = [_left_upper, _left_fore, _right_upper, _right_fore]
	# Capture palm/thumb surfaces before bandage props are parented under the
	# right paw. Pressure gloves must never recolour the healing cloth.
	for paw in [_left_paw, _right_paw]:
		for child in paw.get_children():
			if child is MeshInstance3D:
				_glove_meshes.append(child as MeshInstance3D)
	for part in [
		_left_upper, _left_fore, _left_paw,
		_right_upper, _right_fore, _right_paw,
	]:
		add_child(part)
	_build_bandage_props()
	# In camera space a full shoulder/elbow/forearm chain creates two long,
	# overlapping sticks. The hidden upper pieces preserve the stable six-part
	# viewmodel contract while each visible tapered forearm supplies a cleaner
	# silhouette from the bottom of the frame to its grip.
	_left_upper.visible = false
	_right_upper.visible = false
	var suit := actor.get_node_or_null("SpaceSuitSystem") \
		if is_instance_valid(actor) else null
	set_space_suit_equipped(suit is SpaceSuitSystem and suit.equipped)
	visible = false


## Switches the camera-local viewmodel between bare fur/paws and the same white
## pressure sleeves plus blue gloves used by the articulated world model.
func set_space_suit_equipped(active: bool) -> void:
	_space_suit_equipped = active
	if not _fur_material or not _skin_material:
		return
	var sleeve_material := SpaceSuitSystem.pressure_sleeve_material() \
		if active else _fur_material
	var glove_material := SpaceSuitSystem.pressure_glove_material() \
		if active else _skin_material
	for sleeve in _sleeve_meshes:
		if is_instance_valid(sleeve):
			sleeve.material_override = sleeve_material
	for glove in _glove_meshes:
		if is_instance_valid(glove):
			glove.material_override = glove_material


func has_space_suit_presentation() -> bool:
	return _space_suit_equipped


func update_pose(dt: float, weapon: Node3D, aiming: bool, speed: float,
		grounded: bool) -> void:
	_set_bandage_visible(false)
	if not weapon:
		visible = false
		return
	visible = true
	_left_upper.visible = false
	_right_upper.visible = false
	_t += dt
	_aim_blend = lerpf(_aim_blend, 1.0 if aiming else 0.0,
		1.0 - exp(-14.0 * dt))

	# Keep the shoulders below the frame and at roughly the same depth as the
	# weapon. The old -0.15 Z pose put them almost against the near plane,
	# magnifying the forearms into long crossing tubes.
	var left_shoulder := Vector3(-0.33, -0.54, -0.43)
	var right_shoulder := Vector3(0.35, -0.54, -0.42)
	var left_hand_target := Vector3(0.18, -0.28, -0.60)
	var right_hand_target := Vector3(0.29, -0.28, -0.56)
	var left_grip_basis := Basis.IDENTITY
	var right_grip_basis := Basis.IDENTITY
	if weapon.has_method("first_person_grip_transforms"):
		var grips: Array[Transform3D] = weapon.first_person_grip_transforms(self)
		if grips.size() >= 2:
			right_hand_target = grips[0].origin
			left_hand_target = grips[1].origin
			right_grip_basis = grips[0].basis.orthonormalized()
			left_grip_basis = grips[1].basis.orthonormalized()

	var swinging: bool = actor is MonkeyPlayer \
		and actor.state == MonkeyPlayer.S.SWING
	if swinging:
		# The vine arm enters from the left/bottom of frame rather than crossing
		# underneath the raised weapon.
		left_shoulder = Vector3(-0.31, -0.50, -0.38)

	var left_elbow_target := left_hand_target + Vector3(-0.23, -0.15, 0.13)
	var right_elbow_target := right_hand_target + Vector3(0.13, -0.15, 0.13)
	var recoil: float = weapon.recoil
	var reload_pose := 0.0
	if weapon.reload_remaining > 0.0:
		reload_pose = sin(clampf(weapon.reload_progress(), 0.0, 1.0) * PI)
	var dynamic_reload_hand: bool = weapon.has_method("has_dynamic_reload_hand") \
		and weapon.has_dynamic_reload_hand()

	if weapon is PumpShotgun:
		left_elbow_target = left_hand_target + Vector3(-0.25, -0.16, 0.18)
		right_elbow_target = right_hand_target + Vector3(0.15, -0.16, 0.14)
		if reload_pose > 0.0 and not dynamic_reload_hand:
			left_hand_target += Vector3(-0.14, -0.14, 0.15) * reload_pose
			left_elbow_target += Vector3(-0.10, -0.08, 0.09) * reload_pose
	elif weapon is SMG:
		left_elbow_target = left_hand_target + Vector3(-0.24, -0.16, 0.17)
		right_elbow_target = right_hand_target + Vector3(0.14, -0.15, 0.13)
		if reload_pose > 0.0 and not dynamic_reload_hand:
			left_hand_target += Vector3(-0.18, -0.21, 0.18) * reload_pose
			left_elbow_target += Vector3(-0.12, -0.11, 0.10) * reload_pose
	elif weapon is SniperRifle:
		left_elbow_target = left_hand_target + Vector3(-0.27, -0.17, 0.20)
		right_elbow_target = right_hand_target + Vector3(0.16, -0.16, 0.15)
		if reload_pose > 0.0 and not dynamic_reload_hand:
			left_hand_target += Vector3(-0.20, -0.22, 0.20) * reload_pose
			left_elbow_target += Vector3(-0.14, -0.12, 0.12) * reload_pose
	else:
		# Two-paw pistol grip: the support paw cups the firing paw.
		left_elbow_target = left_hand_target + Vector3(-0.23, -0.15, 0.13)
		right_elbow_target = right_hand_target + Vector3(0.13, -0.15, 0.13)
		if reload_pose > 0.0 and not dynamic_reload_hand:
			left_hand_target += Vector3(-0.15, -0.14, 0.12) * reload_pose

	if swinging and not (weapon is SniperRifle):
		# Never let weapon-specific support/reload animation pull the vine paw
		# back onto the gun after its world-space target was selected above.
		var grip_world: Vector3 = actor.hand_pos()
		var rope_pivot: Vector3 = actor.swing_anchor
		if not actor.wraps.is_empty():
			rope_pivot = actor.wraps[actor.wraps.size() - 1]
		var rope_up := rope_pivot - grip_world
		rope_up = rope_up.normalized() \
			if rope_up.length_squared() > 0.0025 else Vector3.UP
		left_hand_target = to_local(grip_world + rope_up * 0.11)
		left_elbow_target = left_hand_target + Vector3(-0.20, -0.13, 0.09)
		left_grip_basis = _vine_grip_basis(rope_up)

	# The hands come directly from weapon-space grip markers, so recoil, ADS,
	# and the moving shotgun pump cannot separate the paws from the model. Only
	# the elbows lag behind slightly to sell the force of the kick.
	var elbow_kick := Vector3(0.0, -0.008, 0.055) * recoil
	if weapon is PumpShotgun:
		elbow_kick = Vector3(0.0, -0.012, 0.085) * recoil
	elif weapon is SniperRifle:
		elbow_kick = Vector3(0.0, -0.016, 0.11) * recoil
	left_elbow_target += elbow_kick * 0.75
	right_elbow_target += elbow_kick

	var move_weight := clampf(speed / 13.0, 0.0, 1.0)
	var bob := Vector3(
		cos(_t * 8.0) * 0.005,
		sin(_t * 16.0) * 0.004,
		0.0) * move_weight if grounded else Vector3.ZERO
	left_shoulder += bob
	right_shoulder += bob
	left_elbow_target += bob * 0.55
	right_elbow_target += bob * 0.55

	var w := 1.0 - exp(-20.0 * dt)
	if _left_hand == Vector3.ZERO:
		_left_elbow = left_elbow_target
		_right_elbow = right_elbow_target
	else:
		_left_elbow = _left_elbow.lerp(left_elbow_target, w)
		_right_elbow = _right_elbow.lerp(right_elbow_target, w)
	# Exact hand placement is more important than smoothing here: the weapon
	# itself already eases ADS and recoil, and the paws must remain attached.
	_left_hand = left_hand_target
	_right_hand = right_hand_target

	_place_segment(_left_fore, left_shoulder, _left_hand)
	_left_paw.position = _left_hand
	_left_paw.basis = left_grip_basis
	_place_segment(_right_fore, right_shoulder, _right_hand)
	_right_paw.position = _right_hand
	_right_paw.basis = right_grip_basis


func update_melee_pose(dt: float, attack_active: bool, progress: float,
		combo: int, speed: float, grounded: bool, primed := false) -> void:
	_set_bandage_visible(false)
	visible = true
	_t += dt
	var left_shoulder := Vector3(-0.32, -0.54, -0.40)
	var right_shoulder := Vector3(0.32, -0.54, -0.40)
	# Entering melee mode keeps relaxed fists low and outside the sightline. RMB
	# brings the existing guard up; attacks use that guard as their readable base
	# even when LMB began without a held prime.
	var left_relaxed := Vector3(-0.27, -0.41, -0.48)
	var right_relaxed := Vector3(0.28, -0.42, -0.47)
	var left_guard := Vector3(-0.13, -0.19, -0.48)
	var right_guard := Vector3(0.14, -0.21, -0.46)
	var guard_weight := 1.0 if primed or attack_active else 0.0
	var left_target := left_relaxed.lerp(left_guard, guard_weight)
	var right_target := right_relaxed.lerp(right_guard, guard_weight)
	if attack_active:
		var strike := _melee_pulse(progress, 0.10, 0.40, 0.80)
		match posmod(combo, 3):
			0:
				var windup := 1.0 - smoothstep(0.0, 0.18, progress)
				right_target += Vector3(0.10, -0.055, 0.09) * windup
				right_target = right_target.lerp(
					Vector3(0.045, -0.115, -0.70), strike)
			1:
				var windup := 1.0 - smoothstep(0.0, 0.22, progress)
				left_target += Vector3(-0.13, -0.03, 0.06) * windup
				left_target = left_target.lerp(
					Vector3(0.17, -0.13, -0.65), strike)
			_:
				var lift := 1.0 - smoothstep(0.25, 0.52, progress)
				var slam := _melee_pulse(progress, 0.28, 0.56, 0.92)
				var center := Vector3(0.0, 0.015, -0.46).lerp(
					Vector3(0.0, -0.18, -0.68), slam)
				left_target = left_target.lerp(
					center + Vector3(-0.055, 0.0, 0.0), maxf(lift, slam))
				right_target = right_target.lerp(
					center + Vector3(0.055, 0.0, 0.0), maxf(lift, slam))

	var move_weight := clampf(speed / 13.0, 0.0, 1.0)
	var bob := Vector3(
		cos(_t * 8.0) * 0.004,
		sin(_t * 16.0) * 0.003,
		0.0) * move_weight if grounded else Vector3.ZERO
	left_shoulder += bob
	right_shoulder += bob
	left_target += bob * 0.45
	right_target += bob * 0.45
	var transition_rate := 22.0 if attack_active else 13.0
	var w := 1.0 - exp(-transition_rate * dt)
	_left_hand = _left_hand.lerp(left_target, w)
	_right_hand = _right_hand.lerp(right_target, w)
	_left_elbow = left_shoulder.lerp(_left_hand, 0.48) \
		+ Vector3(-0.105, -0.025, 0.035)
	_right_elbow = right_shoulder.lerp(_right_hand, 0.48) \
		+ Vector3(0.105, -0.025, 0.035)
	_left_upper.visible = true
	_right_upper.visible = true
	_place_segment(_left_upper, left_shoulder, _left_elbow)
	_place_segment(_left_fore, _left_elbow, _left_hand)
	_place_segment(_right_upper, right_shoulder, _right_elbow)
	_place_segment(_right_fore, _right_elbow, _right_hand)
	_left_paw.position = _left_hand
	_right_paw.position = _right_hand
	_left_paw.basis = Basis.IDENTITY
	_right_paw.basis = Basis.IDENTITY


func update_bandage_pose(dt: float, progress: float, speed: float,
		grounded: bool) -> void:
	visible = true
	_t += dt
	var p := clampf(progress, 0.0, 1.0)
	var left_shoulder := Vector3(-0.32, -0.54, -0.40)
	var right_shoulder := Vector3(0.33, -0.54, -0.40)
	var left_target := Vector3(-0.045, -0.205, -0.50)
	var right_target := Vector3(0.25, -0.30, -0.47)
	var unwrap := SatisfyingReload.phase(p, 0.02, 0.25)
	var wrap := SatisfyingReload.phase(p, 0.24, 0.72)
	var tug := SatisfyingReload.pulse(p, 0.70, 0.82, 0.91)
	var press := SatisfyingReload.phase(p, 0.88, 0.98)

	# The right paw brings the roll up, circles the braced left wrist twice, then
	# gives the cloth a sharp outward tug before pressing the end flat.
	right_target = right_target.lerp(Vector3(0.08, -0.16, -0.53), unwrap)
	if wrap > 0.0:
		var angle := wrap * TAU * 2.15 - PI * 0.45
		var orbit := Vector3(cos(angle) * 0.105,
			sin(angle) * 0.070, -0.025 * sin(angle * 0.5))
		right_target = left_target + orbit
	right_target += Vector3(0.20, -0.02, 0.02) * tug
	right_target = right_target.lerp(left_target + Vector3(0.045, 0.025, -0.015),
		press)
	left_target += Vector3(-0.055, 0.018, 0.0) * tug

	var move_weight := clampf(speed / 13.0, 0.0, 1.0)
	var bob := Vector3(cos(_t * 8.0) * 0.003,
		sin(_t * 16.0) * 0.0025, 0.0) * move_weight \
		if grounded else Vector3.ZERO
	left_shoulder += bob
	right_shoulder += bob
	left_target += bob * 0.4
	right_target += bob * 0.4
	_left_hand = left_target
	_right_hand = right_target
	_left_elbow = left_shoulder.lerp(left_target, 0.48) \
		+ Vector3(-0.105, -0.025, 0.04)
	_right_elbow = right_shoulder.lerp(right_target, 0.48) \
		+ Vector3(0.10, -0.02, 0.04)
	_left_upper.visible = false
	_right_upper.visible = false
	_place_segment(_left_fore, left_shoulder, _left_hand)
	_place_segment(_right_fore, right_shoulder, _right_hand)
	_left_paw.position = _left_hand
	_right_paw.position = _right_hand
	_left_paw.basis = Basis.IDENTITY
	_right_paw.basis = Basis.IDENTITY

	_set_bandage_visible(p < 0.985)
	if _bandage_roll:
		_bandage_roll.global_transform = global_transform * Transform3D(
			Basis.from_euler(Vector3(p * TAU * 6.0, 0.2, PI * 0.5)),
			right_target)
		_bandage_roll.scale = Vector3.ONE * lerpf(1.0, 0.62, wrap)
	if _bandage_strip:
		# A taut strip connects the roll to the wrist during the wrap and tug.
		var strip_parent := _bandage_strip.get_parent() as Node3D
		_place_segment(_bandage_strip,
			strip_parent.to_local(to_global(
				left_target + Vector3(0.0, 0.012, 0.0))),
			strip_parent.to_local(to_global(right_target)))
		_bandage_strip.visible = p >= 0.12 and p < 0.94


func _build_bandage_props() -> void:
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color(0.96, 0.93, 0.78)
	cloth.roughness = 0.94
	var cloth_edge := StandardMaterial3D.new()
	cloth_edge.albedo_color = Color(0.72, 0.66, 0.50)
	cloth_edge.roughness = 0.98
	_bandage_roll = Node3D.new()
	_bandage_roll.name = "BandageRoll"
	var roll := MeshInstance3D.new()
	var roll_mesh := TorusMesh.new()
	roll_mesh.inner_radius = 0.018
	roll_mesh.outer_radius = 0.055
	roll_mesh.rings = 10
	roll_mesh.ring_segments = 7
	roll.mesh = roll_mesh
	roll.material_override = cloth
	roll.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bandage_roll.add_child(roll)
	var core := MeshInstance3D.new()
	var core_mesh := CylinderMesh.new()
	core_mesh.top_radius = 0.017
	core_mesh.bottom_radius = 0.017
	core_mesh.height = 0.035
	core_mesh.radial_segments = 8
	core.mesh = core_mesh
	core.material_override = cloth_edge
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bandage_roll.add_child(core)
	# Keep the camera rig's stable six direct children contract; props live under
	# the paw but are placed in world/camera space during the healing pose.
	_right_paw.add_child(_bandage_roll)
	_bandage_strip = MeshInstance3D.new()
	_bandage_strip.name = "BandageStrip"
	var strip_mesh := CylinderMesh.new()
	strip_mesh.top_radius = 0.010
	strip_mesh.bottom_radius = 0.014
	strip_mesh.height = 1.0
	strip_mesh.radial_segments = 6
	_bandage_strip.mesh = strip_mesh
	_bandage_strip.material_override = cloth
	_bandage_strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_right_paw.add_child(_bandage_strip)
	_set_bandage_visible(false)


func _set_bandage_visible(shown: bool) -> void:
	if _bandage_roll:
		_bandage_roll.visible = shown
	if _bandage_strip:
		_bandage_strip.visible = shown


static func _melee_pulse(progress: float, start: float, peak: float,
		finish: float) -> float:
	if progress <= peak:
		return smoothstep(start, peak, progress)
	return 1.0 - smoothstep(peak, finish, progress)


func _limb_mesh(radius: float, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = 1.0
	mesh.radial_segments = 10
	mesh.rings = 4
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _forearm_mesh(material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.030 * ARM_VISUAL_SCALE
	mesh.bottom_radius = 0.047 * ARM_VISUAL_SCALE
	mesh.height = 1.0
	mesh.radial_segments = 10
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _paw_mesh(material: Material, left: bool) -> Node3D:
	var root := Node3D.new()
	var palm := MeshInstance3D.new()
	var palm_mesh := SphereMesh.new()
	palm_mesh.radius = 0.036 * ARM_VISUAL_SCALE
	palm_mesh.height = 0.072 * ARM_VISUAL_SCALE
	palm_mesh.radial_segments = 10
	palm_mesh.rings = 6
	palm.mesh = palm_mesh
	palm.scale = Vector3(1.0, 0.70, 1.15)
	palm.material_override = material
	palm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(palm)
	var thumb := MeshInstance3D.new()
	var thumb_mesh := SphereMesh.new()
	thumb_mesh.radius = 0.014 * ARM_VISUAL_SCALE
	thumb_mesh.height = 0.030 * ARM_VISUAL_SCALE
	thumb_mesh.radial_segments = 7
	thumb_mesh.rings = 4
	thumb.mesh = thumb_mesh
	thumb.material_override = material
	thumb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	thumb.position = Vector3(0.033 if left else -0.033, -0.006, 0.0) \
		* ARM_VISUAL_SCALE
	root.add_child(thumb)
	return root


func _place_segment(segment: Node3D, start: Vector3, finish: Vector3) -> void:
	var delta := finish - start
	var length := delta.length()
	if length < 0.001:
		return
	var y_axis := delta / length
	var reference := Vector3.FORWARD \
		if absf(y_axis.dot(Vector3.FORWARD)) < 0.94 else Vector3.RIGHT
	var x_axis := reference.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	segment.position = (start + finish) * 0.5
	# Scale the segment's local Y axis explicitly. Basis.scaled() applies the
	# scale in parent space after rotation, which skewed diagonal forearms and
	# made them appear to continue past the paws.
	segment.basis = Basis(x_axis, y_axis * length, z_axis)


func _vine_grip_basis(rope_up_world: Vector3) -> Basis:
	var local_up := (global_transform.basis.inverse() * rope_up_world).normalized()
	var local_view := Vector3.FORWARD
	var local_x := local_view.cross(local_up)
	if local_x.length_squared() < 0.001:
		local_x = Vector3.RIGHT
	local_x = local_x.normalized()
	var local_z := local_x.cross(local_up).normalized()
	return Basis(local_x, local_up, local_z)
