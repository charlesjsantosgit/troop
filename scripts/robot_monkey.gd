class_name RobotMonkey
extends Node3D
## Regenerating shooting-range target: a low-poly robot monkey that folds up in
## a shower of sparks when destroyed and rebuilds itself moments later. Purely
## local (debug world), damageable through the same CombatHitbox surface real
## players expose, so every weapon, headshot rule, and scope cue works on it.

const MAX_HEALTH := 100.0
const RESPAWN_SECONDS := 2.5
const PATROL_SPEED := 3.2

var health := MAX_HEALTH
var destroyed := false
var kills_scored := 0
var patrol_span := 0.0  # half-width of the ping-pong path; 0 = stationary
var _origin := Vector3.ZERO
var _patrol_t := 0.0
var _respawn_t := 0.0
var _body_root: Node3D
var _body_hitbox: CombatHitbox
var _head_hitbox: CombatHitbox
var _spark_particles: GPUParticles3D


func setup(spawn_position: Vector3, moving_span := 0.0) -> void:
	_origin = spawn_position
	patrol_span = moving_span
	position = spawn_position


func _ready() -> void:
	_build_body()
	_body_hitbox = CombatHitbox.new()
	_body_hitbox.setup_capsule(self, "body", 0.40, 1.10)
	_body_hitbox.position = Vector3(0, 0.62, 0)
	add_child(_body_hitbox)
	_head_hitbox = CombatHitbox.new()
	_head_hitbox.setup(self, "head", 0.26)
	_head_hitbox.position = Vector3(0, 1.34, 0)
	add_child(_head_hitbox)
	_spark_particles = _build_sparks()
	add_child(_spark_particles)


func _process(dt: float) -> void:
	if destroyed:
		_respawn_t -= dt
		if _respawn_t <= 0.0:
			_reassemble()
		return
	if patrol_span > 0.001:
		_patrol_t += dt * PATROL_SPEED / maxf(patrol_span, 0.001)
		position = _origin + Vector3(sin(_patrol_t) * patrol_span, 0, 0)
	# Idle servo sway so even stationary bots read as "on".
	if _body_root:
		_body_root.rotation.y = sin(Time.get_ticks_msec() / 1000.0 * 1.7
			+ _origin.x) * 0.14


func take_damage(amount: float, _source: Node3D, impulse: Vector3,
		hit_zone := "body") -> void:
	if destroyed:
		return
	health -= amount * (2.5 if hit_zone == "head" else 1.0)
	Sfx.play_at("target_hit", global_position + Vector3.UP * 1.1, -6.0,
		1.35 if hit_zone == "head" else 1.0)
	if health > 0.0:
		if _body_root:
			_body_root.position += impulse.normalized() * 0.05
			var tween := create_tween()
			tween.tween_property(_body_root, "position", Vector3.ZERO, 0.18)
		return
	kills_scored += 1
	destroyed = true
	_respawn_t = RESPAWN_SECONDS
	_body_hitbox.set_active(false)
	_head_hitbox.set_active(false)
	_spark_particles.restart()
	_spark_particles.emitting = true
	Sfx.play_at("thud", global_position, -4.0, 0.7)
	# Fold: collapse the whole robot into its base plate.
	var fold := create_tween()
	fold.tween_property(_body_root, "scale", Vector3(1.2, 0.04, 1.2), 0.22) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)


func _reassemble() -> void:
	destroyed = false
	health = MAX_HEALTH
	_body_hitbox.set_active(true)
	_head_hitbox.set_active(true)
	Sfx.play_at("reload_snap", global_position, -8.0, 0.9)
	var rebuild := create_tween()
	rebuild.tween_property(_body_root, "scale", Vector3.ONE, 0.34) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _build_body() -> void:
	_body_root = Node3D.new()
	add_child(_body_root)
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.62, 0.66, 0.70)
	steel.metallic = 0.85
	steel.roughness = 0.38
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.22, 0.24, 0.27)
	dark.metallic = 0.6
	dark.roughness = 0.5
	var visor := StandardMaterial3D.new()
	visor.albedo_color = Color(0.95, 0.25, 0.15)
	visor.emission_enabled = true
	visor.emission = Color(1.0, 0.22, 0.10)
	visor.emission_energy_multiplier = 1.8

	_part(BoxMesh.new(), Vector3(0.42, 0.16, 0.42), Vector3(0, 0.08, 0), dark)
	_part(BoxMesh.new(), Vector3(0.44, 0.62, 0.30), Vector3(0, 0.62, 0), steel)
	_part(BoxMesh.new(), Vector3(0.30, 0.10, 0.20), Vector3(0, 0.99, 0), dark)
	var head := _part(BoxMesh.new(), Vector3(0.34, 0.30, 0.30),
		Vector3(0, 1.32, 0), steel)
	_part(BoxMesh.new(), Vector3(0.24, 0.08, 0.02), Vector3(0, 0.02, -0.155),
		visor, head)
	for side in [-1.0, 1.0]:
		_part(BoxMesh.new(), Vector3(0.10, 0.16, 0.10),
			Vector3(0.24 * side, 1.44, 0), dark)  # ears
		_part(BoxMesh.new(), Vector3(0.12, 0.52, 0.14),
			Vector3(0.30 * side, 0.60, 0), dark)  # arms
	# antenna with a glowing tip
	_part(CylinderMesh.new(), Vector3(0.02, 0.22, 0.02),
		Vector3(0, 1.56, 0), dark)
	_part(SphereMesh.new(), Vector3(0.05, 0.05, 0.05),
		Vector3(0, 1.68, 0), visor)
	# curled sheet-metal tail
	_part(CylinderMesh.new(), Vector3(0.045, 0.5, 0.045),
		Vector3(0, 0.55, 0.30), steel).rotation.x = 0.9


func _part(mesh: Mesh, size: Vector3, at: Vector3, material: Material,
		parent: Node3D = null) -> MeshInstance3D:
	if mesh is BoxMesh:
		(mesh as BoxMesh).size = size
	elif mesh is CylinderMesh:
		var cyl := mesh as CylinderMesh
		cyl.top_radius = size.x
		cyl.bottom_radius = size.z
		cyl.height = size.y
		cyl.radial_segments = 8
	elif mesh is SphereMesh:
		var sph := mesh as SphereMesh
		sph.radius = size.x
		sph.height = size.x * 2.0
		sph.radial_segments = 8
		sph.rings = 4
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = at
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(parent if parent else _body_root).add_child(mi)
	return mi


func _build_sparks() -> GPUParticles3D:
	var sparks := GPUParticles3D.new()
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 70.0
	mat.initial_velocity_min = 2.5
	mat.initial_velocity_max = 6.0
	mat.gravity = Vector3(0, -9.0, 0)
	sparks.process_material = mat
	var quad := QuadMesh.new()
	quad.size = Vector2(0.06, 0.06)
	var spark_material := StandardMaterial3D.new()
	spark_material.albedo_color = Color(1.0, 0.72, 0.20)
	spark_material.emission_enabled = true
	spark_material.emission = Color(1.0, 0.6, 0.1)
	spark_material.emission_energy_multiplier = 2.4
	spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = spark_material
	sparks.draw_pass_1 = quad
	sparks.amount = 26
	sparks.lifetime = 0.55
	sparks.one_shot = true
	sparks.explosiveness = 0.95
	sparks.emitting = false
	sparks.position = Vector3(0, 1.0, 0)
	return sparks
