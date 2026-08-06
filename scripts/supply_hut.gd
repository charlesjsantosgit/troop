class_name SupplyHut
extends Node3D
## Streamed procedural jungle shelter containing one deterministic supply chest.
## World owns the persistent opened-ID set; this node owns only presentation,
## collision, interaction position, and the immutable loot payload from Gen.

const INTERACTION_RANGE := 3.6
const OPEN_ANGLE := -1.18

static var _materials: Dictionary = {}
static var _spark_mesh: SphereMesh

var hut_id := ""
var ammo_kind := Gen.SUPPLY_AMMO_REVOLVER
var ammo_amount := 0
var bandage_count := 0
var biome := Gen.Biome.RAINFOREST

var _opened := false
var _lid_pivot: Node3D
var _loot_glow: Node3D
var _loot_glow_origin := Vector3.ZERO
var _world: Node
var _collisions_built := false
var _collision_bodies: Array[StaticBody3D] = []


func configure(data: Dictionary, initially_opened := false) -> void:
	hut_id = str(data.get("id", ""))
	ammo_kind = int(data.get("ammo_kind", Gen.SUPPLY_AMMO_REVOLVER))
	ammo_amount = maxi(int(data.get("ammo_amount", 0)), 0)
	bandage_count = maxi(int(data.get("bandages", 0)), 0)
	biome = int(data.get("biome", Gen.Biome.RAINFOREST))
	position = data.get("pos", Vector3.ZERO)
	rotation.y = float(data.get("yaw", 0.0))
	_opened = initially_opened


func _ready() -> void:
	name = "SupplyHut_%s" % hut_id.replace(":", "_").replace(",", "_")
	_init_resources()
	_build_model()
	_apply_open_pose()
	var chunk := get_parent()
	_world = chunk.get_parent() if chunk else null
	if _world and _world.has_method("register_supply_hut"):
		_world.register_supply_hut(self)


func _exit_tree() -> void:
	if _world and is_instance_valid(_world) \
			and _world.has_method("unregister_supply_hut"):
		_world.unregister_supply_hut(self)


func is_opened() -> bool:
	return _opened


func chest_interaction_position() -> Vector3:
	return to_global(Vector3(0.0, 0.86, -0.48))


func interaction_range() -> float:
	return INTERACTION_RANGE


func loot_payload() -> Dictionary:
	return {
		"ammo_kind": ammo_kind,
		"ammo_amount": ammo_amount,
		"bandages": bandage_count,
	}


func set_opened(value: bool, play_effects := false) -> void:
	if value and not _opened and play_effects:
		open_chest(true)
		return
	_opened = value
	_apply_open_pose()


func open_chest(play_effects := true) -> bool:
	if _opened:
		return false
	_opened = true
	if not _lid_pivot:
		return true
	if not play_effects or not is_inside_tree():
		_apply_open_pose()
		return true

	_lid_pivot.rotation.x = 0.0
	var lid_tween := create_tween()
	lid_tween.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	lid_tween.tween_property(_lid_pivot, "rotation:x", -1.34, 0.34)
	lid_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	lid_tween.tween_property(_lid_pivot, "rotation:x", OPEN_ANGLE, 0.16)

	if _loot_glow:
		_loot_glow.visible = true
		_loot_glow.position = _loot_glow_origin
		_loot_glow.scale = Vector3.ONE * 0.38
		var loot_tween := create_tween()
		loot_tween.set_parallel(true)
		loot_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		loot_tween.tween_property(_loot_glow, "position",
			_loot_glow_origin + Vector3.UP * 0.52, 0.46)
		loot_tween.tween_property(_loot_glow, "scale", Vector3.ONE * 1.16, 0.34)
		loot_tween.chain().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		loot_tween.tween_property(_loot_glow, "scale", Vector3.ZERO, 0.23)
		loot_tween.tween_callback(_hide_loot_glow)

	_burst_open_effect()
	_play_sfx("chest_open", -3.0, 1.0, 34.0)
	_play_sfx("ammo_pickup", -7.0,
		1.0 + float(ammo_kind) * 0.035, 28.0)
	if bandage_count > 0:
		_play_sfx("bandage_pickup", -8.0, 1.0, 24.0)
	return true


## Construct collision lazily with the rest of the chunk's near-ring physics.
## Returning the bodies lets Chunk reuse its existing collision enable/disable
## path instead of leaving streamed outer huts in the broadphase.
func build_collisions() -> Array[StaticBody3D]:
	if _collisions_built:
		return _collision_bodies
	_collisions_built = true
	var body := StaticBody3D.new()
	body.name = "SupplyHutCollision"
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)
	# Raised floor, rear wall and side walls leave the front visibly open.
	_add_box_collision(body, Vector3(4.35, 0.30, 3.65), Vector3(0, 0.08, 0))
	_add_box_collision(body, Vector3(4.10, 1.70, 0.18), Vector3(0, 1.05, 1.70))
	_add_box_collision(body, Vector3(0.18, 1.70, 3.35), Vector3(-2.02, 1.05, 0.08))
	_add_box_collision(body, Vector3(0.18, 1.70, 3.35), Vector3(2.02, 1.05, 0.08))
	# The chest itself should stop feet and projectiles even after its lid opens.
	_add_box_collision(body, Vector3(1.28, 0.72, 0.76), Vector3(0, 0.57, -0.12))
	_collision_bodies.append(body)
	return _collision_bodies


func _build_model() -> void:
	var wood: Material = _materials.wood
	var wood_dark: Material = _materials.wood_dark
	var bamboo: Material = _materials.bamboo
	var thatch: Material = _materials.thatch
	var metal: Material = _materials.metal
	var cloth: Material = _materials.cloth
	var supply: Material = _supply_material()

	# Platform and framing: chunky silhouettes stay readable through jungle fog.
	_add_box(self, "Platform", Vector3(4.55, 0.25, 3.90),
		Vector3(0, 0.12, 0), wood_dark)
	for x in [-2.02, 2.02]:
		for z in [-1.66, 1.66]:
			_add_box(self, "Post", Vector3(0.24, 2.55, 0.24),
				Vector3(x, 1.34, z), bamboo)
	_add_box(self, "RearWall", Vector3(3.92, 1.55, 0.16),
		Vector3(0, 1.08, 1.66), wood)
	_add_box(self, "LeftWall", Vector3(0.16, 1.55, 3.12),
		Vector3(-2.0, 1.08, 0.12), wood)
	_add_box(self, "RightWall", Vector3(0.16, 1.55, 3.12),
		Vector3(2.0, 1.08, 0.12), wood)
	_add_box(self, "FrontBeam", Vector3(4.30, 0.22, 0.24),
		Vector3(0, 2.30, -1.67), bamboo)
	_add_box(self, "RearBeam", Vector3(4.30, 0.22, 0.24),
		Vector3(0, 2.30, 1.67), bamboo)
	# Two overlapping sloped thatch slabs form a deep ridge roof.
	_add_box(self, "RoofLeft", Vector3(2.55, 0.17, 4.25),
		Vector3(-1.02, 2.70, 0), thatch, Vector3(0, 0, -0.30))
	_add_box(self, "RoofRight", Vector3(2.55, 0.17, 4.25),
		Vector3(1.02, 2.70, 0), thatch, Vector3(0, 0, 0.30))
	_add_box(self, "Ridge", Vector3(0.28, 0.24, 4.34),
		Vector3(0, 3.04, 0), bamboo)

	# Colour-coded ammo badge makes the chest type legible before entering.
	_add_box(self, "SupplySign", Vector3(1.18, 0.52, 0.10),
		Vector3(0, 2.22, -1.82), wood_dark)
	_add_box(self, "SupplyBadge", Vector3(0.72, 0.22, 0.07),
		Vector3(0, 2.23, -1.89), supply)
	for x in [-0.24, 0.0, 0.24]:
		_add_box(self, "RoundMark", Vector3(0.09, 0.34, 0.055),
			Vector3(x, 2.23, -1.94), supply, Vector3(0, 0, -0.18))

	# Chest base and trim. The lid geometry is offset from a rear hinge pivot so
	# rotation opens it physically instead of spinning around its centre.
	_add_box(self, "ChestBase", Vector3(1.30, 0.58, 0.76),
		Vector3(0, 0.55, -0.12), wood_dark)
	_add_box(self, "ChestFront", Vector3(1.18, 0.42, 0.06),
		Vector3(0, 0.57, -0.53), wood)
	_add_box(self, "ChestBandLeft", Vector3(0.10, 0.62, 0.80),
		Vector3(-0.47, 0.58, -0.12), metal)
	_add_box(self, "ChestBandRight", Vector3(0.10, 0.62, 0.80),
		Vector3(0.47, 0.58, -0.12), metal)
	_add_box(self, "ChestLatch", Vector3(0.20, 0.25, 0.08),
		Vector3(0, 0.68, -0.58), supply)
	_lid_pivot = Node3D.new()
	_lid_pivot.name = "ChestLidHinge"
	_lid_pivot.position = Vector3(0, 0.89, 0.23)
	add_child(_lid_pivot)
	_add_box(_lid_pivot, "ChestLid", Vector3(1.36, 0.24, 0.82),
		Vector3(0, 0, -0.37), wood_dark)
	_add_box(_lid_pivot, "LidInset", Vector3(1.12, 0.11, 0.62),
		Vector3(0, 0.14, -0.37), wood)
	_add_box(_lid_pivot, "LidBandLeft", Vector3(0.10, 0.29, 0.86),
		Vector3(-0.47, 0, -0.37), metal)
	_add_box(_lid_pivot, "LidBandRight", Vector3(0.10, 0.29, 0.86),
		Vector3(0.47, 0, -0.37), metal)

	_loot_glow = Node3D.new()
	_loot_glow.name = "LootBurst"
	_loot_glow_origin = Vector3(0, 1.06, -0.18)
	_loot_glow.position = _loot_glow_origin
	add_child(_loot_glow)
	for i in range(3):
		_add_box(_loot_glow, "Ammo", Vector3(0.10, 0.30, 0.10),
			Vector3((float(i) - 1.0) * 0.17, 0, 0), supply,
			Vector3(0.0, 0.0, (float(i) - 1.0) * 0.14))
	if bandage_count > 0:
		_add_cylinder(_loot_glow, "Bandage", 0.16, 0.18, cloth,
			Vector3(0.0, 0.12, 0.16), Vector3(0, 0, PI * 0.5))


func _apply_open_pose() -> void:
	if _lid_pivot:
		_lid_pivot.rotation.x = OPEN_ANGLE if _opened else 0.0
	if _loot_glow:
		_loot_glow.visible = false
		_loot_glow.position = _loot_glow_origin
		_loot_glow.scale = Vector3.ONE


func _hide_loot_glow() -> void:
	if _loot_glow and is_instance_valid(_loot_glow):
		_loot_glow.visible = false


func _play_sfx(stream_name: String, volume_db: float, pitch: float,
		max_distance: float) -> void:
	# Resolve the autoload dynamically so this standalone procedural prop can also
	# be parsed and previewed without booting the complete game singleton graph.
	var sfx := get_node_or_null("/root/Sfx")
	if sfx and sfx.has_method("play_at"):
		sfx.call("play_at", stream_name, chest_interaction_position(), volume_db,
			pitch, max_distance)


func _burst_open_effect() -> void:
	var light := OmniLight3D.new()
	light.name = "SupplyFlash"
	light.light_color = _supply_color()
	light.light_energy = 3.2
	light.omni_range = 5.2
	light.position = Vector3(0, 1.18, -0.28)
	add_child(light)
	var light_tween := light.create_tween()
	light_tween.tween_property(light, "light_energy", 0.0, 0.46)
	light_tween.tween_callback(light.queue_free)

	for i in range(8):
		var spark := MeshInstance3D.new()
		spark.mesh = _spark_mesh
		spark.material_override = _materials.spark
		spark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		spark.position = Vector3(0, 1.06, -0.30)
		var angle := TAU * float(i) / 8.0 + float(hut_id.hash() & 31) * 0.03
		var direction := Vector3(cos(angle), 0.75 + float(i % 3) * 0.18,
			sin(angle)).normalized()
		add_child(spark)
		var spark_tween := spark.create_tween()
		spark_tween.set_parallel(true)
		spark_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		spark_tween.tween_property(spark, "position",
			spark.position + direction * (0.72 + float(i % 2) * 0.22), 0.42)
		spark_tween.tween_property(spark, "scale", Vector3.ZERO, 0.42)
		spark_tween.chain().tween_callback(spark.queue_free)


func _supply_color() -> Color:
	match ammo_kind:
		Gen.SUPPLY_AMMO_SHOTGUN:
			return Color(1.0, 0.34, 0.08)
		Gen.SUPPLY_AMMO_SMG:
			return Color(0.34, 1.0, 0.28)
		Gen.SUPPLY_AMMO_SNIPER:
			return Color(0.24, 0.72, 1.0)
	return Color(1.0, 0.76, 0.08)


func _supply_material() -> Material:
	var key := "supply_%d" % ammo_kind
	if not _materials.has(key):
		var color := _supply_color()
		_materials[key] = _make_material(color, 0.30, 0.28, color, 1.8)
	return _materials[key]


static func _init_resources() -> void:
	if not _materials.is_empty():
		return
	_materials.wood = _make_material(Color(0.39, 0.17, 0.055), 0.79, 0.01)
	_materials.wood_dark = _make_material(Color(0.20, 0.075, 0.025), 0.84, 0.01)
	_materials.bamboo = _make_material(Color(0.48, 0.56, 0.16), 0.70, 0.01)
	_materials.thatch = _make_material(Color(0.69, 0.48, 0.12), 0.94, 0.0)
	_materials.metal = _make_material(Color(0.13, 0.16, 0.14), 0.32, 0.68)
	_materials.cloth = _make_material(Color(0.93, 0.90, 0.72), 0.96, 0.0)
	_materials.spark = _make_material(Color(1.0, 0.82, 0.22), 0.20, 0.05,
		Color(1.0, 0.48, 0.04), 4.0)
	_spark_mesh = SphereMesh.new()
	_spark_mesh.radius = 0.045
	_spark_mesh.height = 0.09
	_spark_mesh.radial_segments = 5
	_spark_mesh.rings = 2


static func _make_material(color: Color, roughness: float, metallic: float,
		emission := Color(0, 0, 0, 1), emission_energy := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	if emission_energy > 0.0:
		material.emission_enabled = true
		material.emission = emission
		material.emission_energy_multiplier = emission_energy
	return material


static func _add_box(parent: Node, node_name: String, size: Vector3,
		local_position: Vector3, material: Material,
		local_rotation := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.material_override = material
	instance.position = local_position
	instance.rotation = local_rotation
	instance.visibility_range_end = 104.0
	instance.visibility_range_end_margin = 14.0
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	parent.add_child(instance)
	return instance


static func _add_cylinder(parent: Node, node_name: String, radius: float,
		height: float, material: Material, local_position: Vector3,
		local_rotation := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 8
	instance.mesh = mesh
	instance.material_override = material
	instance.position = local_position
	instance.rotation = local_rotation
	instance.visibility_range_end = 104.0
	instance.visibility_range_end_margin = 14.0
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	parent.add_child(instance)
	return instance


static func _add_box_collision(body: StaticBody3D, size: Vector3,
		local_position: Vector3, local_rotation := Vector3.ZERO) -> void:
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	collision.position = local_position
	collision.rotation = local_rotation
	body.add_child(collision)
