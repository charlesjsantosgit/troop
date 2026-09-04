class_name FieldBackpack
extends Node3D
## Articulated field gear. Attaching below the stature frame makes the pack
## follow the same anatomy and poses as its wearer without per-frame copying.
static var _canvas: StandardMaterial3D
static var _leather: StandardMaterial3D
static var _metal: StandardMaterial3D
static var _patch: StandardMaterial3D

static func fit_to(actor: Node3D, local_viewer: bool) -> Node3D:
	if not is_instance_valid(actor): return null
	var rig: MonkeyRig = actor.get("rig") as MonkeyRig
	if not rig or not rig.torso_p: return null
	var pack := rig.torso_p.get_node_or_null("FieldBackpack") as Node3D
	if not pack:
		pack = FieldBackpack.new()
		pack.name = "FieldBackpack"
		rig.torso_p.add_child(pack)
		pack._build(MonkeyRig.LOCAL_BODY_VISUAL_LAYER if local_viewer else 1)
	var suit := actor.get_node_or_null("SpaceSuitSystem") as SpaceSuitSystem
	pack.visible = not (suit and suit.equipped)
	return pack

static func _material(color: String, roughness: float, metallic := 0.0) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = Color(color)
	result.roughness = roughness
	result.metallic = metallic
	return result

func _build(layer: int) -> void:
	if not _canvas:
		_canvas = _material("8f7045", 0.95)
		_leather = _material("49362a", 0.83)
		_metal = _material("c5b48b", 0.34, 0.7)
		_patch = _material("c5cf9b", 0.9)
	# Keep the lower back open for the complete animated tail socket. The
	# bedroll sits above the compact pack, behind the head rather than the tail.
	_box("Canvas", Vector3(0.37,0.185,0.12), Vector3(0,0.2325,0.23), _canvas, layer)
	_box("TopFlap", Vector3(0.39,0.025,0.14), Vector3(0,0.3275,0.24), _leather, layer)
	_box("FrontPocket", Vector3(0.28,0.105,0.035), Vector3(0,0.25,0.31), _canvas, layer)
	_box("SocietyPatch", Vector3(0.09,0.07,0.008), Vector3(0,0.26,0.332), _patch, layer)
	for side: float in [-1.0,1.0]:
		_box("SidePocket", Vector3(0.07,0.13,0.10), Vector3(side*0.213,0.245,0.23), _canvas, layer)
		_box("ShoulderStrap", Vector3(0.038,0.46,0.035), Vector3(side*0.21,0.235,-0.16), _leather, layer)
		_box("ShoulderLoop", Vector3(0.038,0.035,0.35), Vector3(side*0.21,0.46,0.01), _leather, layer)
		_box("BedrollTie", Vector3(0.03,0.33,0.025), Vector3(side*0.16,0.46,0.16), _leather, layer)
		_box("ClosureStrap", Vector3(0.035,0.13,0.012), Vector3(side*0.115,0.2625,0.295), _leather, layer)
		_box("BrassBuckle", Vector3(0.046,0.036,0.018), Vector3(side*0.115,0.30,0.307), _metal, layer)
	var roll := CylinderMesh.new()
	roll.top_radius = 0.045
	roll.bottom_radius = 0.045
	roll.height = 0.40
	roll.radial_segments = 12
	var bedroll := MeshInstance3D.new()
	bedroll.name = "Bedroll"
	bedroll.mesh = roll
	bedroll.material_override = _patch
	bedroll.position = Vector3(0,0.62,0.25)
	bedroll.rotation.z = PI*0.5
	bedroll.layers = layer
	add_child(bedroll)

func _box(part: String, dimensions: Vector3, at: Vector3, material: Material, layer: int) -> void:
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	var visual := MeshInstance3D.new()
	visual.name = part
	visual.mesh = mesh
	visual.position = at
	visual.material_override = material
	visual.layers = layer
	add_child(visual)
