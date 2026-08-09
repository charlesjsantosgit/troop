class_name SpaceSuitSystem
extends Node3D
## Per-monkey lunar life support. The tank is measured in real seconds, is
## advanced through one deterministic method for multiplayer/replay use, and
## exposes refill/depletion hooks without deciding how the player takes damage.

signal suit_equipped(actor: Node3D)
signal oxygen_changed(seconds_remaining: float, capacity_seconds: float)
signal oxygen_warning(fraction_remaining: float)
signal oxygen_depleted
signal oxygen_refilled(seconds_remaining: float)

const OXYGEN_CAPACITY_SECONDS := 720.0
const OXYGEN_USE_PER_SECOND := 1.0
const WARNING_FRACTION := 0.20
const CRITICAL_FRACTION := 0.08

static var _white_material: StandardMaterial3D
static var _trim_material: StandardMaterial3D
static var _tank_material: StandardMaterial3D
static var _visor_material: StandardMaterial3D

var inventory := LunarInventory.new()
var oxygen_seconds := OXYGEN_CAPACITY_SECONDS
var exposed_to_vacuum := false
var equipped := false
var actor: Node3D
var _depleted_emitted := false
var _last_warning_band := 0
var _visual_roots: Array[Node3D] = []
var _visual_mesh_count := 0
var _visual_layer := 1


func _ready() -> void:
	name = "SpaceSuitSystem"
	_rebuild_suit_visuals()
	_notify_first_person_presentation()
	set_physics_process(true)


func _exit_tree() -> void:
	_clear_suit_visuals()
	# Articulated shells live under the actor's joints rather than this node. They
	# must be freed while leaving the tree, but Node._ready normally runs only
	# once. Requesting it again rebuilds the fitted shells after this suit or its
	# complete actor subtree is later re-added.
	request_ready()


func equip_for(target: Node3D, inventory_override: LunarInventory = null) -> bool:
	if not is_instance_valid(target):
		return false
	actor = target
	if inventory_override:
		inventory = inventory_override
	if not inventory.equip_backpack(LunarInventory.Backpack.SPACE):
		return false
	if get_parent() != target:
		if get_parent():
			reparent(target, false)
		else:
			target.add_child(self)
	position = Vector3.ZERO
	rotation = Vector3.ZERO
	# A newly added suit has already built its visuals in _ready(). Rebuild only
	# when an off-tree/reparent lifecycle left no attachment roots behind.
	if is_inside_tree() and _visual_roots.is_empty():
		_rebuild_suit_visuals()
	equipped = true
	visible = true
	_set_suit_visuals_visible(true)
	_notify_first_person_presentation()
	suit_equipped.emit(target)
	oxygen_changed.emit(oxygen_seconds, OXYGEN_CAPACITY_SECONDS)
	return true


func unequip() -> bool:
	if exposed_to_vacuum:
		return false
	equipped = false
	visible = false
	_set_suit_visuals_visible(false)
	_notify_first_person_presentation()
	return true


func set_vacuum_exposure(exposed: bool) -> void:
	exposed_to_vacuum = exposed
	if not exposed:
		_last_warning_band = 0


func _physics_process(delta: float) -> void:
	advance_life_support(delta)


func advance_life_support(delta: float) -> float:
	if delta <= 0.0 or not equipped or not exposed_to_vacuum:
		return oxygen_seconds
	var before := oxygen_seconds
	oxygen_seconds = maxf(oxygen_seconds - delta * OXYGEN_USE_PER_SECOND, 0.0)
	if not is_equal_approx(before, oxygen_seconds):
		oxygen_changed.emit(oxygen_seconds, OXYGEN_CAPACITY_SECONDS)
	var fraction := oxygen_fraction()
	var warning_band := 2 if fraction <= CRITICAL_FRACTION \
		else (1 if fraction <= WARNING_FRACTION else 0)
	if warning_band > _last_warning_band:
		_last_warning_band = warning_band
		oxygen_warning.emit(fraction)
	if oxygen_seconds <= 0.0 and not _depleted_emitted:
		_depleted_emitted = true
		oxygen_depleted.emit()
	return oxygen_seconds


func refill_oxygen(seconds := -1.0) -> float:
	var requested := float(seconds)
	if requested < 0.0:
		oxygen_seconds = OXYGEN_CAPACITY_SECONDS
	else:
		oxygen_seconds = minf(oxygen_seconds + requested,
			OXYGEN_CAPACITY_SECONDS)
	_depleted_emitted = false
	_last_warning_band = 0
	oxygen_refilled.emit(oxygen_seconds)
	oxygen_changed.emit(oxygen_seconds, OXYGEN_CAPACITY_SECONDS)
	return oxygen_seconds


func oxygen_fraction() -> float:
	return clampf(oxygen_seconds / OXYGEN_CAPACITY_SECONDS, 0.0, 1.0)


func has_breathable_oxygen() -> bool:
	return equipped and oxygen_seconds > 0.0


func visual_primitive_count() -> int:
	return _visual_mesh_count


## Camera-local arms use the exact pressure-garment materials so changing view
## never changes the astronaut's suit colour or surface response.
static func pressure_sleeve_material() -> Material:
	_ensure_materials()
	return _white_material


static func pressure_glove_material() -> Material:
	_ensure_materials()
	return _trim_material


static func _count_meshes(root: Node) -> int:
	var count := 0
	for child in root.get_children():
		if child is MeshInstance3D:
			count += 1
		count += _count_meshes(child)
	return count


func _rebuild_suit_visuals() -> void:
	_clear_suit_visuals()
	_ensure_materials()
	var rig := _find_monkey_rig(actor) if is_instance_valid(actor) else null
	if rig:
		_visual_layer = MonkeyRig.LOCAL_BODY_VISUAL_LAYER \
			if bool(rig.get("_is_local_visual")) else 1
		_build_articulated_suit(rig)
	else:
		_visual_layer = 1
		_build_fallback_suit()
	_set_suit_visuals_visible(equipped or actor == null)


func _build_articulated_suit(rig: MonkeyRig) -> void:
	# Every shell is parented to the joint it protects. This keeps the fitted
	# pressure garment aligned through walking, seated cabin poses and lunar
	# movement instead of dragging one rigid, box-shaped costume behind the actor.
	var torso_root := _attachment(rig.torso_p, "SpaceSuitTorso")
	_add_capsule(torso_root, "FittedPressureTorso", 0.225, 0.61,
		Vector3(0.0, 0.23, 0.01), _white_material,
		Vector3(1.06, 1.0, 0.73))
	_add_torus(torso_root, "FlexibleNeckSeal", 0.155, 0.205,
		Vector3(0.0, 0.49, 0.0), _trim_material)
	_add_capsule(torso_root, "RoundedControlPanel", 0.075, 0.27,
		Vector3(0.0, 0.27, -0.185), _trim_material,
		Vector3(1.0, 1.0, 0.34), Vector3(0.0, 0.0, PI * 0.5))
	_add_capsule(torso_root, "ContouredLifeSupportPack", 0.155, 0.48,
		Vector3(0.0, 0.22, 0.245), _trim_material,
		Vector3(1.22, 1.0, 0.58))
	for side in [-1.0, 1.0]:
		_add_capsule(torso_root, "OxygenTank", 0.058, 0.39,
			Vector3(side * 0.115, 0.22, 0.37), _tank_material)

	var head_root := _attachment(rig.head_p, "SpaceSuitHelmet")
	_add_sphere(head_root, "ClearPressureHelmet", 0.224, Vector3.ZERO,
		_visor_material, Vector3(1.06, 1.02, 1.0))
	_add_torus(head_root, "VisorSeal", 0.145, 0.194,
		Vector3(0.0, -0.006, -0.118), _trim_material,
		Vector3(1.0, 1.0, 0.72), Vector3(PI * 0.5, 0.0, 0.0))

	for limb in [[rig.sh_l, rig.el_l, rig.paw_l, "Left"],
			[rig.sh_r, rig.el_r, rig.paw_r, "Right"]]:
		var upper_root := _attachment(limb[0], "%sSuitUpperArm" % limb[3])
		_add_capsule(upper_root, "%sPressureSleeve" % limb[3], 0.071,
			MonkeyRig.ARM_A + 0.015, Vector3(0.0, -MonkeyRig.ARM_A * 0.5, 0.0),
			_white_material, Vector3(1.0, 1.0, 0.95))
		var lower_root := _attachment(limb[1], "%sSuitForearm" % limb[3])
		_add_capsule(lower_root, "%sForearmSleeve" % limb[3], 0.064,
			MonkeyRig.ARM_B + 0.012, Vector3(0.0, -MonkeyRig.ARM_B * 0.5, 0.0),
			_white_material)
		var glove_root := _attachment(limb[2], "%sSuitGlove" % limb[3])
		_add_sphere(glove_root, "%sPressureGlove" % limb[3], 0.071,
			Vector3.ZERO, _trim_material, Vector3(1.06, 0.94, 1.04))

	for limb in [[rig.hip_l, rig.kn_l, rig.foot_l, "Left"],
			[rig.hip_r, rig.kn_r, rig.foot_r, "Right"]]:
		var thigh_root := _attachment(limb[0], "%sSuitThigh" % limb[3])
		_add_capsule(thigh_root, "%sPressureTrouser" % limb[3], 0.082,
			MonkeyRig.LEG_A + 0.018, Vector3(0.0, -MonkeyRig.LEG_A * 0.5, 0.0),
			_white_material)
		var shin_root := _attachment(limb[1], "%sSuitShin" % limb[3])
		_add_capsule(shin_root, "%sLowerPressureTrouser" % limb[3], 0.069,
			MonkeyRig.LEG_B + 0.018, Vector3(0.0, -MonkeyRig.LEG_B * 0.5, 0.0),
			_white_material)
		var boot_root := _attachment(limb[2], "%sSuitBoot" % limb[3])
		_add_sphere(boot_root, "%sLunarBoot" % limb[3], 0.083,
			Vector3(0.0, -0.005, -0.014), _trim_material,
			Vector3(1.02, 0.72, 1.42))


func _build_fallback_suit() -> void:
	# Admin/test integration may equip a plain Node3D with no MonkeyRig. Retain a
	# compact proportionate fallback while real monkeys receive joint attachments.
	var root := _attachment(self, "FallbackSpaceSuitVisual")
	_add_capsule(root, "PressureTorso", 0.225, 0.61,
		Vector3(0.0, 0.81, 0.01), _white_material,
		Vector3(1.06, 1.0, 0.73))
	_add_sphere(root, "ClearPressureHelmet", 0.224,
		Vector3(0.0, 1.36, 0.0), _visor_material,
		Vector3(1.06, 1.02, 1.0))
	_add_capsule(root, "LifeSupportPack", 0.155, 0.48,
		Vector3(0.0, 0.80, 0.25), _trim_material,
		Vector3(1.22, 1.0, 0.58))
	for side in [-1.0, 1.0]:
		_add_capsule(root, "OxygenTank", 0.058, 0.39,
			Vector3(side * 0.115, 0.80, 0.37), _tank_material)
		_add_sphere(root, "Glove", 0.071,
			Vector3(side * 0.30, 0.80, -0.02), _trim_material)
		_add_sphere(root, "LunarBoot", 0.083,
			Vector3(side * 0.12, 0.10, -0.03), _trim_material,
			Vector3(1.02, 0.72, 1.42))


func _attachment(parent: Node, part_name: String) -> Node3D:
	var attachment := Node3D.new()
	attachment.name = part_name
	parent.add_child(attachment)
	_visual_roots.append(attachment)
	return attachment


func _add_capsule(parent: Node3D, part_name: String, radius: float,
		height: float, local_position: Vector3, material: Material,
		scale_value := Vector3.ONE, rotation_value := Vector3.ZERO) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = maxf(height, radius * 2.05)
	mesh.radial_segments = 24
	mesh.rings = 12
	_add_mesh(parent, part_name, mesh, local_position, material,
		scale_value, rotation_value)


func _add_sphere(parent: Node3D, part_name: String, radius: float,
		local_position: Vector3, material: Material,
		scale_value := Vector3.ONE, rotation_value := Vector3.ZERO) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 28
	mesh.rings = 16
	_add_mesh(parent, part_name, mesh, local_position, material,
		scale_value, rotation_value)


func _add_torus(parent: Node3D, part_name: String, inner_radius: float,
		outer_radius: float, local_position: Vector3, material: Material,
		scale_value := Vector3.ONE, rotation_value := Vector3.ZERO) -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner_radius
	mesh.outer_radius = outer_radius
	mesh.rings = 28
	mesh.ring_segments = 12
	_add_mesh(parent, part_name, mesh, local_position, material,
		scale_value, rotation_value)


func _add_mesh(parent: Node3D, part_name: String, mesh: PrimitiveMesh,
		local_position: Vector3, material: Material,
		scale_value := Vector3.ONE, rotation_value := Vector3.ZERO) -> void:
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.position = local_position
	instance.rotation = rotation_value
	instance.scale = scale_value
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	instance.layers = _visual_layer
	parent.add_child(instance)
	_visual_mesh_count += 1


func _clear_suit_visuals() -> void:
	for visual_root in _visual_roots:
		if is_instance_valid(visual_root):
			visual_root.free()
	_visual_roots.clear()
	_visual_mesh_count = 0


func _set_suit_visuals_visible(value: bool) -> void:
	for visual_root in _visual_roots:
		if is_instance_valid(visual_root):
			visual_root.visible = value


func _notify_first_person_presentation() -> void:
	if is_instance_valid(actor):
		_notify_suit_state_recursive(actor, equipped)


static func _notify_suit_state_recursive(root: Node, active: bool) -> void:
	if root.has_method("set_space_suit_equipped"):
		root.call("set_space_suit_equipped", active)
	for child in root.get_children():
		_notify_suit_state_recursive(child, active)


static func _find_monkey_rig(root: Node) -> MonkeyRig:
	if not is_instance_valid(root):
		return null
	if root is MonkeyRig:
		return root as MonkeyRig
	for child in root.get_children():
		var found := _find_monkey_rig(child)
		if found:
			return found
	return null


static func _ensure_materials() -> void:
	if _white_material:
		return
	_white_material = StandardMaterial3D.new()
	_white_material.albedo_color = Color(0.88, 0.91, 0.94)
	_white_material.metallic = 0.10
	_white_material.roughness = 0.42
	_trim_material = StandardMaterial3D.new()
	_trim_material.albedo_color = Color(0.08, 0.26, 0.48)
	_trim_material.metallic = 0.35
	_trim_material.roughness = 0.30
	_tank_material = StandardMaterial3D.new()
	_tank_material.albedo_color = Color(0.72, 0.76, 0.79)
	_tank_material.metallic = 0.72
	_tank_material.roughness = 0.22
	_visor_material = StandardMaterial3D.new()
	_visor_material.albedo_color = Color(0.48, 0.76, 1.0, 0.22)
	_visor_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_visor_material.metallic = 0.55
	_visor_material.roughness = 0.08
	_visor_material.cull_mode = BaseMaterial3D.CULL_DISABLED
