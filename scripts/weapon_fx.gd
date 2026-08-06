class_name WeaponFX
extends RefCounted
## Shared model/debris/reload-accent helpers. Weapon scripts can use the model
## factories for both installed geometry and camera-local hand props, then
## eject an identical world-space copy through spawn_debris().

const MAX_ACTIVE_DEBRIS := 48

static var _active_debris: Array[WeakRef] = []


## Model-only factories: safe to parent directly beneath a weapon, magazine
## socket, or animated reload-hand marker.
static func make_brass_model() -> Node3D:
	return WeaponDebris.make_brass_model()


static func make_shotgun_shell_model() -> Node3D:
	return WeaponDebris.make_shotgun_shell_model()


static func make_smg_mag_model() -> Node3D:
	return WeaponDebris.make_smg_mag_model()


static func make_sniper_mag_model() -> Node3D:
	return WeaponDebris.make_sniper_mag_model()


static func make_banana_mag_model() -> Node3D:
	return WeaponDebris.make_banana_mag_model()


## Choreography-friendly aliases kept short at weapon call sites.
static func make_smg_magazine() -> Node3D:
	return make_smg_mag_model()


static func make_sniper_magazine() -> Node3D:
	return make_sniper_mag_model()


static func make_banana_magazine() -> Node3D:
	return make_banana_mag_model()


static func make_shotgun_shell() -> Node3D:
	return make_shotgun_shell_model()


static func make_brass_casing() -> Node3D:
	return make_brass_model()


static func make_model(kind: int) -> Node3D:
	return WeaponDebris.make_model(kind)


## Creates non-damaging debris in world space. `velocity` and `spin` are world
## vectors, so callers can compose actor velocity with weapon-local ejection
## impulses before passing them in.
static func spawn_debris(parent: Node, kind: int,
		world_transform: Transform3D, velocity: Vector3, spin: Vector3,
		actor: Node3D = null,
		lifetime_seconds := WeaponDebris.DEFAULT_LIFETIME) -> WeaponDebris:
	if not parent or not is_instance_valid(parent):
		return null
	_prune_debris()
	while _active_debris.size() >= MAX_ACTIVE_DEBRIS:
		var oldest_ref: WeakRef = _active_debris.pop_front()
		var oldest := oldest_ref.get_ref() as WeaponDebris
		if oldest and is_instance_valid(oldest):
			oldest.queue_free()

	var debris := WeaponDebris.new()
	debris.configure(kind, velocity, spin, actor as CollisionObject3D,
		lifetime_seconds)
	parent.add_child(debris)
	debris.global_transform = world_transform
	# Re-apply after setting the transform so a caller can spawn and inspect the
	# exact initial state in the same frame.
	debris.linear_velocity = velocity
	debris.angular_velocity = spin
	_active_debris.append(weakref(debris))
	return debris


## A brief emissive star plus peel/spark flecks for catches, insertions and bolt
## closures. It is cosmetic, self-cleaning, and intentionally has no light or
## collision node, so many clients can play it independently.
static func spawn_satisfaction_burst(parent: Node,
		world_transform: Transform3D,
		color := Color(1.0, 0.78, 0.16), intensity := 1.0) -> Node3D:
	if not parent or not is_instance_valid(parent):
		return null
	var strength := clampf(intensity, 0.25, 2.5)
	var burst := Node3D.new()
	burst.name = "ReloadSatisfactionBurst"
	parent.add_child(burst)
	burst.global_transform = world_transform
	burst.scale = Vector3.ONE * 0.18

	var glint_material := StandardMaterial3D.new()
	glint_material.albedo_color = color
	glint_material.emission_enabled = true
	glint_material.emission = color
	glint_material.emission_energy_multiplier = 3.2 * strength
	glint_material.roughness = 0.12
	glint_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var core := MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.030 * strength
	core_mesh.height = 0.060 * strength
	core_mesh.radial_segments = 8
	core_mesh.rings = 4
	core.mesh = core_mesh
	core.material_override = glint_material
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	burst.add_child(core)

	for i in range(3):
		var ray := MeshInstance3D.new()
		var ray_mesh := BoxMesh.new()
		ray_mesh.size = Vector3(0.18 * strength, 0.009, 0.009)
		ray.mesh = ray_mesh
		ray.material_override = glint_material
		ray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		match i:
			1:
				ray.rotation.z = PI * 0.5
			2:
				ray.rotation.y = PI * 0.5
		burst.add_child(ray)

	var particle_material := ParticleProcessMaterial.new()
	particle_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	particle_material.emission_sphere_radius = 0.025 * strength
	particle_material.direction = Vector3.UP
	particle_material.spread = 180.0
	particle_material.initial_velocity_min = 0.34 * strength
	particle_material.initial_velocity_max = 0.82 * strength
	particle_material.gravity = Vector3(0.0, -1.15, 0.0)
	particle_material.damping_min = 0.6
	particle_material.damping_max = 1.4
	particle_material.scale_min = 0.45
	particle_material.scale_max = 1.0
	particle_material.color = color

	var fleck_material := StandardMaterial3D.new()
	fleck_material.albedo_color = color
	fleck_material.emission_enabled = true
	fleck_material.emission = color
	fleck_material.emission_energy_multiplier = 2.4 * strength
	fleck_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fleck_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	var fleck_mesh := QuadMesh.new()
	fleck_mesh.size = Vector2(0.018, 0.055) * strength
	fleck_mesh.material = fleck_material

	var particles := GPUParticles3D.new()
	particles.amount = roundi(8.0 * strength)
	particles.lifetime = 0.30
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.randomness = 0.52
	particles.process_material = particle_material
	particles.draw_pass_1 = fleck_mesh
	particles.visibility_aabb = AABB(Vector3.ONE * -0.8, Vector3.ONE * 1.6)
	burst.add_child(particles)
	particles.emitting = true

	var tween := burst.create_tween()
	tween.set_trans(Tween.TRANS_BACK)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(burst, "scale", Vector3.ONE * 1.12, 0.075)
	tween.set_trans(Tween.TRANS_QUAD)
	tween.set_ease(Tween.EASE_IN)
	tween.tween_interval(0.105)
	tween.tween_property(burst, "scale", Vector3.ZERO, 0.13)
	tween.tween_callback(burst.queue_free)
	return burst


## Position-based convenience wrapper used by reload choreography.
static func spawn_glint(parent: Node, world_position: Vector3,
		color := Color(1.0, 0.78, 0.16), intensity := 1.0) -> Node3D:
	return spawn_satisfaction_burst(parent,
		Transform3D(Basis.IDENTITY, world_position), color, intensity)


static func _prune_debris() -> void:
	for i in range(_active_debris.size() - 1, -1, -1):
		var body: WeaponDebris = _active_debris[i].get_ref() as WeaponDebris
		if not body or not is_instance_valid(body) or body.is_queued_for_deletion():
			_active_debris.remove_at(i)
