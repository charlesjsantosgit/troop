class_name BananaBullet
extends Node3D
## Fast ballistic projectile with swept collision. Gravity is deliberately
## lighter than the monkey's so close shots feel revolver-flat while long shots
## acquire readable drop.

const GRAVITY := Vector3(0, -6.0, 0)
const DAMAGE := 34.0
const MAX_LIFE := 2.8
const SNIPER_MAX_LIFE := 4.5
const HIT_RADIUS := 0.09
const HEADSHOT_LETHAL_RANGE := 45.0
const LONG_RANGE_HEADSHOT_FRACTION := 0.8
const TRACER_WIDTH_REVOLVER := 0.0065
const TRACER_WIDTH_SHOTGUN := 0.005
const TRACER_WIDTH_SMG := 0.007
const TRACER_WIDTH_SNIPER := 0.0045

static var _bullet_mesh: CapsuleMesh
static var _bullet_material: StandardMaterial3D
static var _trail_material: ShaderMaterial

var shooter: Node3D
var world: Node3D
var velocity := Vector3.ZERO
var impact_damage := DAMAGE
var uses_revolver_headshots := true
var weapon_kind := 0
var life := MAX_LIFE
var _exclude: Array[RID] = []
var _travelled := 0.0
var _trail_mesh: ImmediateMesh
var _trail_instance: MeshInstance3D
var _visual: MeshInstance3D


func configure(owner_actor: Node3D, owner_world: Node3D, origin: Vector3,
		initial_velocity: Vector3, projectile_damage := DAMAGE,
		headshot_rule := true, projectile_weapon_kind := 0) -> void:
	shooter = owner_actor
	world = owner_world
	global_position = origin
	velocity = initial_velocity
	impact_damage = projectile_damage
	uses_revolver_headshots = headshot_rule
	weapon_kind = projectile_weapon_kind
	if weapon_kind == Net.WEAPON_SNIPER:
		life = SNIPER_MAX_LIFE
	_apply_weapon_visual()
	if shooter is CollisionObject3D:
		_exclude.append(shooter.get_rid())
	if shooter is MonkeyPlayer and shooter.head_hitbox:
		if shooter.body_hitbox:
			_exclude.append(shooter.body_hitbox.get_rid())
		_exclude.append(shooter.head_hitbox.get_rid())
	elif shooter is Puppet:
		if shooter.body_hitbox:
			_exclude.append(shooter.body_hitbox.get_rid())
		if shooter.head_hitbox:
			_exclude.append(shooter.head_hitbox.get_rid())


func _ready() -> void:
	prepare_resources()

	_visual = MeshInstance3D.new()
	_visual.mesh = _bullet_mesh
	_visual.material_override = _bullet_material
	_visual.rotation.x = PI * 0.5
	_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_visual)
	_apply_weapon_visual()

	_trail_mesh = ImmediateMesh.new()
	_trail_instance = MeshInstance3D.new()
	_trail_instance.mesh = _trail_mesh
	_trail_instance.top_level = true
	_trail_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_trail_instance)


static func prepare_resources() -> void:
	if not _bullet_mesh:
		_bullet_mesh = CapsuleMesh.new()
		_bullet_mesh.radius = 0.032
		_bullet_mesh.height = 0.18
		_bullet_mesh.radial_segments = 6
		_bullet_mesh.rings = 2
		_bullet_material = StandardMaterial3D.new()
		_bullet_material.albedo_color = Color(1.0, 0.77, 0.08)
		_bullet_material.emission_enabled = true
		_bullet_material.emission = Color(1.0, 0.42, 0.03)
		_bullet_material.emission_energy_multiplier = 2.6
		_bullet_material.roughness = 0.38
		_trail_material = ShaderMaterial.new()
		var shader := Shader.new()
		shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
void fragment() {
	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * 2.1;
	ALPHA = COLOR.a;
}
"""
		_trail_material.shader = shader


func _apply_weapon_visual() -> void:
	if not _visual:
		return
	_visual.scale = Vector3.ONE
	if weapon_kind == Net.WEAPON_SHOTGUN:
		_visual.scale = Vector3.ONE * 0.43
	elif weapon_kind == Net.WEAPON_SMG:
		_visual.scale = Vector3.ONE * 0.56
	elif weapon_kind == Net.WEAPON_SNIPER:
		_visual.scale = Vector3.ONE * 0.36


func _physics_process(dt: float) -> void:
	life -= dt
	if life <= 0.0:
		queue_free()
		return
	var start := global_position
	var gravity := projectile_gravity()
	# Exact constant-acceleration step keeps real trajectories aligned with the
	# scope's continuous ballistic solution instead of accumulating Euler error.
	var finish := start + velocity * dt + gravity * (0.5 * dt * dt)
	velocity += gravity * dt
	var hit := _swept_intersection(start, finish)
	if not hit.is_empty():
		_travelled += start.distance_to(hit.position)
		global_position = hit.position
		var collider = hit.collider
		var hit_actor: Node3D
		var was_headshot := false
		if collider is CombatHitbox:
			hit_actor = collider.actor
			was_headshot = collider.zone == "head"
		elif collider is Node3D and collider.has_method("take_damage"):
			hit_actor = collider
		if hit_actor and hit_actor.has_method("take_damage"):
			var damage := impact_damage
			var sniper_headshot := was_headshot \
				and weapon_kind == Net.WEAPON_SNIPER
			if sniper_headshot:
				damage = hit_actor.MAX_HEALTH
			elif was_headshot and uses_revolver_headshots:
				damage = headshot_damage(_travelled, hit_actor.MAX_HEALTH)
			var impact_impulse := velocity.normalized() * (
				7.5 if weapon_kind == Net.WEAPON_SNIPER else 4.5)
			if hit_actor is MonkeyPlayer:
				hit_actor.take_damage(damage, shooter, impact_impulse,
					"head" if was_headshot else "body")
			else:
				hit_actor.take_damage(damage, shooter, impact_impulse)
			# Replicated puppets intentionally apply no health locally, but their
			# swept hitboxes are the shooter's visual hit-confirmation source. The
			# victim's own client simulates the same bullet against its authoritative
			# MonkeyPlayer. Keep this cue local-only and exclude props/practice targets.
			var other_player := hit_actor is Puppet \
				or (hit_actor is MonkeyPlayer and hit_actor != shooter)
			var scored_headshot := was_headshot \
				and (uses_revolver_headshots or sniper_headshot)
			if other_player and shooter is MonkeyPlayer and shooter.is_local:
				shooter.bullet_hit_confirmed.emit(scored_headshot, damage)
			if scored_headshot:
				Sfx.play_at("headshot", hit.position, -2.0)
				if world and world.has_method("report_headshot"):
					world.report_headshot(shooter, hit_actor,
						true if sniper_headshot else \
						_travelled <= HEADSHOT_LETHAL_RANGE, _travelled)
		if world and world.has_method("spawn_bullet_impact"):
			world.spawn_bullet_impact(hit.position, hit.normal,
				hit_actor != null)
		queue_free()
		return

	_travelled += start.distance_to(finish)
	global_position = finish
	if velocity.length_squared() > 0.01:
		var direction := velocity.normalized()
		var up := Vector3.FORWARD if absf(direction.dot(Vector3.UP)) > 0.98 \
			else Vector3.UP
		look_at(finish + direction, up)
	_draw_trail(start, finish)


func _swept_intersection(start: Vector3, finish: Vector3) -> Dictionary:
	var travel := finish - start
	if travel.length_squared() < 0.000001:
		return {}
	var forward := travel.normalized()
	var right := forward.cross(Vector3.UP)
	if right.length_squared() < 0.01:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var up := right.cross(forward).normalized()
	var offsets := [
		Vector3.ZERO,
		right * HIT_RADIUS,
		-right * HIT_RADIUS,
		up * HIT_RADIUS,
		-up * HIT_RADIUS,
	]
	var closest: Dictionary = {}
	var closest_distance := INF
	var space := get_world_3d().direct_space_state
	for offset in offsets:
		var query := PhysicsRayQueryParameters3D.create(start + offset,
			finish + offset)
		query.exclude = _exclude
		query.collision_mask = 1 | CombatHitbox.HITBOX_LAYER
		query.collide_with_areas = true
		query.collide_with_bodies = true
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		var distance: float = (hit.position - offset).distance_to(start)
		if distance < closest_distance:
			closest_distance = distance
			closest = hit
	return closest


func _draw_trail(start: Vector3, finish: Vector3) -> void:
	var travel := finish - start
	if travel.length_squared() < 0.00001:
		return
	_trail_instance.global_transform = Transform3D.IDENTITY
	_trail_mesh.clear_surfaces()
	var direction := travel.normalized()
	var tail_length := 1.15
	var width := TRACER_WIDTH_REVOLVER
	var color := Color(1.0, 0.68, 0.17, 0.72)
	if weapon_kind == Net.WEAPON_SHOTGUN:
		tail_length = 0.70
		width = TRACER_WIDTH_SHOTGUN
		color = Color(1.0, 0.58, 0.22, 0.52)
	elif weapon_kind == Net.WEAPON_SMG:
		tail_length = 2.20
		width = TRACER_WIDTH_SMG
		color = Color(1.0, 0.82, 0.46, 0.76)
	elif weapon_kind == Net.WEAPON_SNIPER:
		tail_length = 4.80
		width = TRACER_WIDTH_SNIPER
		color = Color(0.72, 0.91, 1.0, 0.88)
	var front := finish + direction * 0.04
	var back := finish - direction * tail_length
	var camera := get_viewport().get_camera_3d()
	var view_direction := (camera.global_position - finish).normalized() \
		if camera else Vector3.UP
	var side := direction.cross(view_direction)
	if side.length_squared() < 0.001:
		side = direction.cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = Vector3.RIGHT
	side = side.normalized() * width
	var front_side := side * 0.38
	var back_color := Color(color.r, color.g, color.b, 0.0)
	var front_color := Color(color.r, color.g, color.b, color.a)
	_trail_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _trail_material)
	_add_tracer_vertex(back - side, back_color)
	_add_tracer_vertex(back + side, back_color)
	_add_tracer_vertex(front + front_side, front_color)
	_add_tracer_vertex(back - side, back_color)
	_add_tracer_vertex(front + front_side, front_color)
	_add_tracer_vertex(front - front_side, front_color)
	_trail_mesh.surface_end()


func _add_tracer_vertex(point: Vector3, color: Color) -> void:
	_trail_mesh.surface_set_color(color)
	_trail_mesh.surface_add_vertex(point)


static func ballistic_position(origin: Vector3, initial_velocity: Vector3,
		time: float) -> Vector3:
	return origin + initial_velocity * time + GRAVITY * (0.5 * time * time)


func projectile_gravity() -> Vector3:
	return Vector3.DOWN * SniperRifle.BALLISTIC_GRAVITY \
		if weapon_kind == Net.WEAPON_SNIPER else GRAVITY


static func headshot_damage(distance: float, maximum_health: float) -> float:
	return maximum_health if distance <= HEADSHOT_LETHAL_RANGE \
		else maximum_health * LONG_RANGE_HEADSHOT_FRACTION
