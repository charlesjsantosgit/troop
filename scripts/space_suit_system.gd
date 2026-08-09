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


func _ready() -> void:
	name = "SpaceSuitSystem"
	if get_child_count() == 0:
		_build_suit_visuals()
	set_physics_process(true)


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
	equipped = true
	visible = true
	suit_equipped.emit(target)
	oxygen_changed.emit(oxygen_seconds, OXYGEN_CAPACITY_SECONDS)
	return true


func unequip() -> bool:
	if exposed_to_vacuum:
		return false
	equipped = false
	visible = false
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
	return _count_meshes(self)


static func _count_meshes(root: Node) -> int:
	var count := 0
	for child in root.get_children():
		if child is MeshInstance3D:
			count += 1
		count += _count_meshes(child)
	return count


func _build_suit_visuals() -> void:
	_ensure_materials()
	# White pressure torso, flexible hip ring, clear helmet, twin oxygen tanks,
	# and a compact blue life-support pack. The monkey's face remains visible.
	_add_box("PressureTorso", Vector3(0.62, 0.56, 0.32),
		Vector3(0.0, 0.80, 0.02), _white_material)
	_add_box("ControlPanel", Vector3(0.34, 0.18, 0.07),
		Vector3(0.0, 0.84, -0.19), _trim_material)
	var helmet := SphereMesh.new()
	helmet.radius = 0.40
	helmet.height = 0.80
	helmet.radial_segments = 20
	helmet.rings = 12
	_add_mesh("ClearHelmet", helmet, Vector3(0.0, 1.31, 0.0),
		_visor_material)
	_add_box("LifeSupportPack", Vector3(0.52, 0.55, 0.20),
		Vector3(0.0, 0.79, 0.24), _trim_material)
	for side in [-1.0, 1.0]:
		var tank := CylinderMesh.new()
		tank.top_radius = 0.095
		tank.bottom_radius = 0.095
		tank.height = 0.57
		tank.radial_segments = 12
		_add_mesh("OxygenTank", tank,
			Vector3(side * 0.17, 0.80, 0.38), _tank_material)
		_add_box("Boot", Vector3(0.22, 0.20, 0.32),
			Vector3(side * 0.20, 0.13, -0.04), _white_material)


func _add_box(part_name: String, size: Vector3, local_position: Vector3,
		material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_add_mesh(part_name, mesh, local_position, material)


func _add_mesh(part_name: String, mesh: PrimitiveMesh,
		local_position: Vector3, material: Material) -> void:
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.position = local_position
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(instance)


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
