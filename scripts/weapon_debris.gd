class_name WeaponDebris
extends RigidBody3D
## Lightweight, cosmetic weapon debris. It collides with level geometry only
## to sell weight and play a bounded number of impact sounds; it never deals
## damage or participates in combat hit detection.

enum Kind {
	BRASS,
	SHOTGUN_SHELL,
	SMG_MAG,
	SNIPER_MAG,
	BANANA_MAG,
}

const DEFAULT_LIFETIME := 8.0
const MAX_IMPACT_SOUNDS := 2
const IMPACT_DEBOUNCE_MSEC := 140
const MIN_IMPACT_SPEED := 0.72

static var _materials: Dictionary = {}

var debris_kind: int = Kind.BRASS
var initial_velocity := Vector3.ZERO
var initial_spin := Vector3.ZERO
var lifetime := DEFAULT_LIFETIME
var source_actor: CollisionObject3D

var _impact_sound_count := 0
var _last_impact_msec := -IMPACT_DEBOUNCE_MSEC


## Configure before add_child(). WeaponFX.spawn_debris() is the convenient
## public entry point for normal callers.
func configure(kind: int, velocity: Vector3, spin: Vector3,
		actor: CollisionObject3D = null,
		lifetime_seconds := DEFAULT_LIFETIME) -> WeaponDebris:
	debris_kind = clampi(kind, Kind.BRASS, Kind.BANANA_MAG)
	initial_velocity = velocity
	initial_spin = spin
	source_actor = actor
	lifetime = maxf(lifetime_seconds, 0.25)
	return self


func _ready() -> void:
	name = "WeaponDebris_%s" % kind_name(debris_kind)
	# Debris checks only against the normal world/body layer. It has no gameplay
	# layer of its own and no damage callback.
	collision_layer = 0
	collision_mask = 1
	mass = _mass_for_kind(debris_kind)
	gravity_scale = 1.0
	linear_damp = 0.24
	angular_damp = 0.18
	can_sleep = true
	continuous_cd = debris_kind in [Kind.BRASS, Kind.SHOTGUN_SHELL]
	contact_monitor = true
	max_contacts_reported = 4

	var physics_material := PhysicsMaterial.new()
	physics_material.friction = 0.58 if _is_magazine(debris_kind) else 0.42
	physics_material.bounce = 0.16 if _is_magazine(debris_kind) else 0.31
	physics_material_override = physics_material

	add_child(make_model(debris_kind))
	_add_collision(debris_kind)
	linear_velocity = initial_velocity
	angular_velocity = initial_spin
	if source_actor and is_instance_valid(source_actor):
		add_collision_exception_with(source_actor)
	body_entered.connect(_on_body_entered)

	var cleanup_timer := get_tree().create_timer(lifetime)
	cleanup_timer.timeout.connect(_expire)


func _on_body_entered(_body: Node) -> void:
	if _impact_sound_count >= MAX_IMPACT_SOUNDS:
		return
	var now := Time.get_ticks_msec()
	if now - _last_impact_msec < IMPACT_DEBOUNCE_MSEC:
		return
	# Include a little rotational edge speed so a slowly travelling magazine
	# can still make one convincing slap when it lands flat.
	var impact_speed := maxf(linear_velocity.length(),
		angular_velocity.length() * _impact_radius(debris_kind))
	if impact_speed < MIN_IMPACT_SPEED:
		return
	_last_impact_msec = now
	_impact_sound_count += 1
	var sound_name := _impact_sound(debris_kind)
	var volume_db := -13.0
	if _is_magazine(debris_kind):
		volume_db = -8.5
	elif debris_kind == Kind.SHOTGUN_SHELL:
		volume_db = -10.5
	var speed_weight := clampf((impact_speed - MIN_IMPACT_SPEED) / 5.0,
		0.0, 1.0)
	var sfx := get_node_or_null("/root/Sfx")
	if sfx:
		sfx.call("play_at", sound_name, global_position,
			volume_db + speed_weight * 3.0, randf_range(0.91, 1.09), 26.0)


func _expire() -> void:
	if is_instance_valid(self):
		queue_free()


## A model-only factory. Returned nodes have no collision or gameplay script,
## so the same low-poly props can be parented to a weapon or a hand marker.
static func make_model(kind: int) -> Node3D:
	match kind:
		Kind.SHOTGUN_SHELL:
			return make_shotgun_shell_model()
		Kind.SMG_MAG:
			return make_smg_mag_model()
		Kind.SNIPER_MAG:
			return make_sniper_mag_model()
		Kind.BANANA_MAG:
			return make_banana_mag_model()
		_:
			return make_brass_model()


static func make_brass_model() -> Node3D:
	var root := Node3D.new()
	root.name = "BrassModel"
	var brass := _material(&"brass", Color(0.78, 0.54, 0.13), 0.27, 0.66)
	var dark := _material(&"primer", Color(0.17, 0.12, 0.055), 0.42, 0.42)
	root.add_child(_cylinder(0.014, 0.052, 8, brass))
	var rim := _cylinder(0.017, 0.006, 8, brass)
	rim.position.y = -0.029
	root.add_child(rim)
	var primer := _cylinder(0.006, 0.0065, 8, dark)
	primer.position.y = -0.033
	root.add_child(primer)
	return root


static func make_shotgun_shell_model() -> Node3D:
	var root := Node3D.new()
	root.name = "ShotgunShellModel"
	var hull_material := _material(&"shell_red",
		Color(0.66, 0.035, 0.025), 0.50, 0.04)
	var brass := _material(&"brass", Color(0.78, 0.54, 0.13), 0.27, 0.66)
	var crimp_material := _material(&"shell_crimp",
		Color(0.34, 0.018, 0.014), 0.58, 0.02)
	var hull := _cylinder(0.019, 0.057, 10, hull_material)
	hull.position.y = 0.004
	root.add_child(hull)
	var cap := _cylinder(0.0215, 0.014, 10, brass)
	cap.position.y = -0.031
	root.add_child(cap)
	var crimp := _cylinder(0.017, 0.004, 8, crimp_material)
	crimp.position.y = 0.034
	root.add_child(crimp)
	return root


static func make_smg_mag_model() -> Node3D:
	var root := Node3D.new()
	root.name = "SMGMagazineModel"
	var dark := _material(&"smg_mag_dark",
		Color(0.028, 0.034, 0.038), 0.34, 0.68)
	var edge := _material(&"smg_mag_edge",
		Color(0.105, 0.125, 0.13), 0.28, 0.62)
	var accent := _material(&"smg_mag_accent",
		Color(0.82, 0.47, 0.055), 0.38, 0.28)

	var upper := _box(Vector3(0.105, 0.105, 0.082), dark)
	upper.position = Vector3(0.0, 0.087, -0.002)
	root.add_child(upper)
	var middle := _box(Vector3(0.100, 0.105, 0.080), dark)
	middle.position = Vector3(0.0, -0.014, 0.006)
	middle.rotation.x = -0.075
	root.add_child(middle)
	var lower := _box(Vector3(0.092, 0.100, 0.075), dark)
	lower.position = Vector3(0.0, -0.111, 0.022)
	lower.rotation.x = -0.15
	root.add_child(lower)
	var base_plate := _box(Vector3(0.108, 0.018, 0.088), edge)
	base_plate.position = Vector3(0.0, -0.168, 0.032)
	base_plate.rotation.x = -0.15
	root.add_child(base_plate)
	for side in [-1.0, 1.0]:
		var feed_lip := _box(Vector3(0.025, 0.030, 0.088), edge)
		feed_lip.position = Vector3(side * 0.034, 0.151, -0.002)
		root.add_child(feed_lip)
	var witness := _box(Vector3(0.107, 0.010, 0.006), accent)
	witness.position = Vector3(0.0, -0.035, -0.043)
	root.add_child(witness)
	return root


static func make_sniper_mag_model() -> Node3D:
	var root := Node3D.new()
	root.name = "SniperMagazineModel"
	var steel := _material(&"sniper_mag_steel",
		Color(0.075, 0.088, 0.092), 0.27, 0.72)
	var dark := _material(&"sniper_mag_dark",
		Color(0.018, 0.022, 0.024), 0.36, 0.55)
	var brass := _material(&"brass", Color(0.78, 0.54, 0.13), 0.27, 0.66)

	var upper := _box(Vector3(0.135, 0.090, 0.138), steel)
	upper.position.y = 0.060
	root.add_child(upper)
	var lower := _box(Vector3(0.118, 0.120, 0.126), steel)
	lower.position = Vector3(0.0, -0.045, 0.008)
	lower.rotation.x = -0.055
	root.add_child(lower)
	var floor_plate := _box(Vector3(0.130, 0.025, 0.140), dark)
	floor_plate.position = Vector3(0.0, -0.120, 0.012)
	floor_plate.rotation.x = -0.055
	root.add_child(floor_plate)
	for side in [-1.0, 1.0]:
		var top_round := _cylinder(0.012, 0.105, 8, brass)
		top_round.rotation.z = PI * 0.5
		top_round.position = Vector3(side * 0.030, 0.113, -0.018)
		root.add_child(top_round)
	return root


static func make_banana_mag_model() -> Node3D:
	var root := Node3D.new()
	root.name = "BananaMagazineModel"
	var peel := _material(&"banana_mag_peel",
		Color(1.0, 0.72, 0.055), 0.43, 0.06)
	var peel_light := _material(&"banana_mag_highlight",
		Color(1.0, 0.91, 0.18), 0.36, 0.04)
	var tip_material := _material(&"banana_mag_tip",
		Color(0.24, 0.105, 0.025), 0.78, 0.0)
	var feed_material := _material(&"banana_mag_feed",
		Color(0.16, 0.12, 0.035), 0.36, 0.28)

	for i in range(4):
		var segment := _capsule_mesh(0.036, 0.102, 8,
			peel_light if i == 1 else peel)
		segment.position = _banana_segment_position(i)
		segment.rotation.z = _banana_segment_rotation(i)
		root.add_child(segment)
	var feed_lip := _box(Vector3(0.075, 0.038, 0.066), feed_material)
	feed_lip.position = _banana_segment_position(0) + Vector3(0.020, 0.061, 0.0)
	feed_lip.rotation.z = _banana_segment_rotation(0)
	root.add_child(feed_lip)
	var brown_tip := _sphere(Vector3(0.025, 0.038, 0.025), tip_material)
	brown_tip.position = _banana_segment_position(3) + Vector3(0.026, -0.057, 0.0)
	root.add_child(brown_tip)
	return root


static func kind_name(kind: int) -> String:
	match kind:
		Kind.SHOTGUN_SHELL:
			return "ShotgunShell"
		Kind.SMG_MAG:
			return "SMGMag"
		Kind.SNIPER_MAG:
			return "SniperMag"
		Kind.BANANA_MAG:
			return "BananaMag"
		_:
			return "Brass"


func _add_collision(kind: int) -> void:
	match kind:
		Kind.BRASS:
			_add_cylinder_collision(0.0165, 0.058)
		Kind.SHOTGUN_SHELL:
			_add_cylinder_collision(0.022, 0.074)
		Kind.SMG_MAG:
			_add_box_collision(Vector3(0.112, 0.335, 0.098),
				Vector3(0.0, -0.008, 0.014), Vector3(-0.075, 0.0, 0.0))
		Kind.SNIPER_MAG:
			_add_box_collision(Vector3(0.142, 0.255, 0.148),
				Vector3(0.0, -0.010, 0.006), Vector3(-0.035, 0.0, 0.0))
		Kind.BANANA_MAG:
			for i in range(4):
				var shape := CapsuleShape3D.new()
				shape.radius = 0.037
				shape.height = 0.104
				var collision := CollisionShape3D.new()
				collision.shape = shape
				collision.position = _banana_segment_position(i)
				collision.rotation.z = _banana_segment_rotation(i)
				add_child(collision)


func _add_cylinder_collision(radius: float, height: float) -> void:
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var collision := CollisionShape3D.new()
	collision.shape = shape
	add_child(collision)


func _add_box_collision(size: Vector3, position: Vector3,
		rotation: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position = position
	collision.rotation = rotation
	add_child(collision)


static func _banana_segment_position(index: int) -> Vector3:
	var u := float(index) / 3.0 - 0.5
	return Vector3(0.11 * u * u - 0.0275, -u * 0.205, 0.0)


static func _banana_segment_rotation(index: int) -> float:
	var u := float(index) / 3.0 - 0.5
	return u * 0.52


static func _mass_for_kind(kind: int) -> float:
	match kind:
		Kind.BRASS:
			return 0.012
		Kind.SHOTGUN_SHELL:
			return 0.028
		Kind.BANANA_MAG:
			return 0.18
		_:
			return 0.26


static func _impact_radius(kind: int) -> float:
	return 0.16 if _is_magazine(kind) else 0.035


static func _impact_sound(kind: int) -> String:
	if kind == Kind.SHOTGUN_SHELL:
		return "shell_tink"
	if _is_magazine(kind):
		return "mag_floor"
	return "casing_tink"


static func _is_magazine(kind: int) -> bool:
	return kind in [Kind.SMG_MAG, Kind.SNIPER_MAG, Kind.BANANA_MAG]


static func _material(key: StringName, color: Color, roughness: float,
		metallic: float) -> StandardMaterial3D:
	if _materials.has(key):
		return _materials[key] as StandardMaterial3D
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	_materials[key] = material
	return material


static func _box(size: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.material_override = material
	return instance


static func _cylinder(radius: float, height: float, sides: int,
		material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = sides
	instance.mesh = mesh
	instance.material_override = material
	return instance


static func _capsule_mesh(radius: float, height: float, sides: int,
		material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = sides
	mesh.rings = 3
	instance.mesh = mesh
	instance.material_override = material
	return instance


static func _sphere(size: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 8
	mesh.rings = 4
	instance.mesh = mesh
	instance.scale = size * 2.0
	instance.material_override = material
	return instance
