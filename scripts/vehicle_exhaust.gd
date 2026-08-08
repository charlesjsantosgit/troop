class_name VehicleExhaust
extends Node3D
## One bounded, world-space GPU exhaust outlet. Every vehicle supplies an exact
## modeled pipe/nozzle position and a local direction; this component supplies
## profile-specific vapor, pulse, heat, lifetime, and adaptive particle budgets.
## Draw meshes/ramps are immutable and shared, while process materials remain
## per outlet so one vehicle's throttle can never recolor another's plume.

enum Profile { BIKE, JEEP, AIRBOAT, JET }

const NORMAL_COUNTS := {
	Profile.BIKE: 12,
	Profile.JEEP: 18,
	Profile.AIRBOAT: 14,
	Profile.JET: 32,
}
const HIGH_COUNTS := {
	Profile.BIKE: 18,
	Profile.JEEP: 26,
	Profile.AIRBOAT: 20,
	Profile.JET: 40,
}
const PERFORMANCE_COUNTS := {
	Profile.BIKE: 7,
	Profile.JEEP: 10,
	Profile.AIRBOAT: 8,
	Profile.JET: 20,
}

static var _mesh_cache: Dictionary = {}
static var _ramp_cache: Dictionary = {}
static var _scale_curve_cache: Dictionary = {}
static var _soft_particle_texture: ImageTexture

var profile := Profile.BIKE
var outlet_direction := Vector3(0, 0, -1)
var particles: GPUParticles3D
var intensity := 0.0
var boost := 0.0
var target_intensity := 0.0
var _pulse_phase := 0.0
var _process_material: ParticleProcessMaterial
var _high_effects := false
var _fullscreen_performance := false


func setup(profile_kind: int, direction: Vector3) -> void:
	profile = clampi(profile_kind, Profile.BIKE, Profile.JET)
	outlet_direction = direction.normalized() if direction.length_squared() > 0.001 \
		else Vector3(0, 0, -1)
	name = "VehicleExhaust_%s" % profile_name(profile)
	_process_material = _make_process_material(profile, outlet_direction)
	particles = GPUParticles3D.new()
	particles.name = "ExhaustParticles"
	particles.process_material = _process_material
	particles.draw_pass_1 = _particle_mesh(profile)
	particles.amount = particle_budget(profile, false, false)
	particles.amount_ratio = 0.0
	particles.lifetime = _lifetime(profile)
	particles.randomness = 0.28
	particles.local_coords = false
	particles.fixed_fps = 20
	particles.interp_to_end = 0.0
	if profile == Profile.JET:
		# Node-level alignment combines a camera-facing Z axis with velocity Y.
		# ParticleProcessMaterial's Align Y is ignored by Particle Billboard
		# materials, so the jet mesh deliberately uses this explicit transform.
		particles.transform_align = \
			GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visibility_aabb = _visibility_bounds(profile)
	particles.visibility_range_end = _visibility_range(profile)
	particles.emitting = false
	add_child(particles)


## Smooth output changes keep throttle steps from popping a whole cloud in or
## out. The small engine profiles pulse subtly; the turbine remains continuous.
func update_output(dt: float, requested_intensity: float,
		requested_boost := 0.0) -> void:
	target_intensity = clampf(requested_intensity, 0.0, 1.0)
	var response := 1.0 - exp(-maxf(dt, 0.0) * 7.0)
	intensity = lerpf(intensity, target_intensity, response)
	boost = lerpf(boost, clampf(requested_boost, 0.0, 1.0), response)
	_pulse_phase = fmod(_pulse_phase + dt * lerpf(8.0, 19.0, intensity), TAU)
	var pulse_amount := 0.0
	match profile:
		Profile.BIKE:
			pulse_amount = 0.20
		Profile.JEEP:
			pulse_amount = 0.055
		Profile.AIRBOAT:
			pulse_amount = 0.075
	var pulse := 1.0 + sin(_pulse_phase) * pulse_amount
	var visible_output := clampf(intensity * pulse, 0.0, 1.0)
	particles.amount_ratio = visible_output
	# speed_scale advances both motion and age, so it cannot physically stretch
	# a plume. Each outlet owns its process material; vary true launch velocity
	# while leaving the particle clock at real time.
	particles.speed_scale = 1.0
	_update_velocity()
	particles.emitting = visible_output > 0.012
	_update_tint()


func set_quality(high_effects: bool, fullscreen_performance: bool) -> void:
	_high_effects = high_effects
	_fullscreen_performance = fullscreen_performance
	if particles:
		particles.amount = particle_budget(profile, _high_effects,
			_fullscreen_performance)


static func sampled_intensity(profile_kind: int, running: bool, rpm_fraction: float,
		load: float, boost_amount := 0.0) -> float:
	if not running:
		return 0.0
	var rpm := clampf(rpm_fraction, 0.0, 1.0)
	var engine_load := clampf(load, 0.0, 1.0)
	var boosted := clampf(boost_amount, 0.0, 1.0)
	match profile_kind:
		Profile.BIKE:
			return clampf(0.16 + rpm * 0.44 + engine_load * 0.40, 0.0, 1.0)
		Profile.JEEP:
			return clampf(0.14 + rpm * 0.42 + engine_load * 0.44, 0.0, 1.0)
		Profile.AIRBOAT:
			return clampf(0.13 + rpm * 0.49 + engine_load * 0.38, 0.0, 1.0)
		Profile.JET:
			return clampf(0.12 + rpm * 0.64 + engine_load * 0.14
				+ boosted * 0.10, 0.0, 1.0)
	return 0.0


static func particle_budget(profile_kind: int, high_effects: bool,
		fullscreen_performance: bool) -> int:
	if fullscreen_performance:
		return int(PERFORMANCE_COUNTS.get(profile_kind, 1))
	if high_effects:
		return int(HIGH_COUNTS.get(profile_kind, 1))
	return int(NORMAL_COUNTS.get(profile_kind, 1))


static func profile_name(profile_kind: int) -> String:
	return ["Bike", "Jeep", "Airboat", "Jet"][clampi(profile_kind, 0, 3)]


func _update_tint() -> void:
	match profile:
		Profile.BIKE:
			# A healthy small gasoline engine is mostly warm translucent vapor, with
			# only a slightly darker puff when the single cylinder is loaded.
			_process_material.color = Color(0.78 - intensity * 0.12,
				0.80 - intensity * 0.13, 0.81 - intensity * 0.13,
				0.62 + intensity * 0.16)
		Profile.JEEP:
			_process_material.color = Color(0.69 - intensity * 0.18,
				0.70 - intensity * 0.18, 0.70 - intensity * 0.17,
				0.64 + intensity * 0.17)
		Profile.AIRBOAT:
			_process_material.color = Color(0.76 - intensity * 0.08,
				0.77 - intensity * 0.08, 0.78 - intensity * 0.07,
				0.62 + intensity * 0.16)
		Profile.JET:
			# A very low-opacity blue-white wisp suggests refracting turbine heat;
			# black smoke would imply a failed engine, not normal afterburner use.
			_process_material.color = Color(0.68 + boost * 0.20,
				0.78 + boost * 0.13, 1.0, 0.24 + boost * 0.08)


func _update_velocity() -> void:
	var velocity_min := 0.0
	var velocity_max := 0.0
	match profile:
		Profile.BIKE:
			velocity_min = lerpf(0.35, 0.65, intensity)
			velocity_max = lerpf(0.75, 1.25, intensity)
		Profile.JEEP:
			velocity_min = lerpf(0.45, 0.85, intensity)
			velocity_max = lerpf(0.95, 1.55, intensity)
		Profile.AIRBOAT:
			velocity_min = lerpf(0.85, 1.45, intensity)
			velocity_max = lerpf(1.55, 2.85, intensity)
		Profile.JET:
			velocity_min = lerpf(16.0, 25.0, intensity) + boost * 8.0
			velocity_max = lerpf(25.0, 36.0, intensity) + boost * 12.0
	_process_material.initial_velocity_min = velocity_min
	_process_material.initial_velocity_max = velocity_max


static func _make_process_material(profile_kind: int,
		direction: Vector3) -> ParticleProcessMaterial:
	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	material.direction = direction
	material.inherit_velocity_ratio = 1.0
	material.spread = 12.0
	material.gravity = Vector3(0, 0.34, 0)
	material.scale_min = 0.55
	material.scale_max = 1.25
	material.color_ramp = _color_ramp(profile_kind)
	material.scale_curve = _scale_curve(profile_kind)
	match profile_kind:
		Profile.BIKE:
			material.emission_sphere_radius = 0.018
			material.initial_velocity_min = 0.45
			material.initial_velocity_max = 0.95
			material.damping_min = 1.2
			material.damping_max = 2.4
			material.spread = 17.0
		Profile.JEEP:
			material.emission_sphere_radius = 0.025
			material.initial_velocity_min = 0.65
			material.initial_velocity_max = 1.30
			material.damping_min = 1.5
			material.damping_max = 3.0
			material.spread = 15.0
		Profile.AIRBOAT:
			material.emission_sphere_radius = 0.022
			material.initial_velocity_min = 1.15
			material.initial_velocity_max = 2.25
			material.damping_min = 1.8
			material.damping_max = 3.4
			material.spread = 10.0
			material.gravity = Vector3(0, 0.24, 0)
		Profile.JET:
			material.emission_sphere_radius = 0.08
			material.initial_velocity_min = 16.0
			material.initial_velocity_max = 25.0
			material.damping_min = 4.0
			material.damping_max = 7.0
			material.spread = 3.5
			material.gravity = Vector3.ZERO
			material.scale_min = 0.72
			material.scale_max = 1.35
	return material


static func _particle_mesh(profile_kind: int) -> QuadMesh:
	if _mesh_cache.has(profile_kind):
		return _mesh_cache[profile_kind]
	var mesh := QuadMesh.new()
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color.WHITE
	material.albedo_texture = _soft_exhaust_texture()
	material.no_depth_test = false
	match profile_kind:
		Profile.BIKE:
			mesh.size = Vector2(0.18, 0.18)
		Profile.JEEP:
			mesh.size = Vector2(0.28, 0.28)
		Profile.AIRBOAT:
			mesh.size = Vector2(0.23, 0.23)
		Profile.JET:
			# Node-level Z-billboard/Y-to-velocity alignment turns this narrow quad
			# into a heat wisp along the plume instead of a cotton-ball puff.
			mesh.size = Vector2(0.20, 0.68)
			material.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	mesh.material = material
	_mesh_cache[profile_kind] = mesh
	return mesh


## Tiny cached radial alpha sprite: soft vapor lobes instead of translucent
## square cards. Generated once, shared by every exhaust draw mesh.
static func _soft_exhaust_texture() -> ImageTexture:
	if _soft_particle_texture:
		return _soft_particle_texture
	const TEXTURE_SIZE := 32
	var image := Image.create(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	for y in range(TEXTURE_SIZE):
		for x in range(TEXTURE_SIZE):
			var uv := (Vector2(float(x), float(y)) + Vector2(0.5, 0.5)) \
				/ float(TEXTURE_SIZE)
			var radius := (uv - Vector2(0.5, 0.5)).length() * 2.0
			var alpha := pow(clampf(1.0 - radius, 0.0, 1.0), 1.75)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	_soft_particle_texture = ImageTexture.create_from_image(image)
	return _soft_particle_texture


static func _color_ramp(profile_kind: int) -> GradientTexture1D:
	if _ramp_cache.has(profile_kind):
		return _ramp_cache[profile_kind]
	var gradient := Gradient.new()
	match profile_kind:
		Profile.JET:
			gradient.set_color(0, Color(0.72, 0.84, 1.0, 0.00))
			gradient.add_point(0.10, Color(0.68, 0.82, 1.0, 0.38))
			gradient.add_point(0.48, Color(0.72, 0.79, 0.90, 0.16))
			gradient.set_color(gradient.get_point_count() - 1,
				Color(0.72, 0.76, 0.82, 0.0))
		_:
			gradient.set_color(0, Color(0.82, 0.84, 0.85, 0.00))
			gradient.add_point(0.10, Color(0.74, 0.76, 0.77, 0.62))
			gradient.add_point(0.45, Color(0.60, 0.62, 0.63, 0.34))
			gradient.set_color(gradient.get_point_count() - 1,
				Color(0.54, 0.56, 0.58, 0.0))
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	_ramp_cache[profile_kind] = texture
	return texture


## Shared life-cycle scale curve: combustion vapor grows as it cools, while
## the high-speed jet wisp expands only slightly before its alpha disappears.
static func _scale_curve(profile_kind: int) -> CurveTexture:
	if _scale_curve_cache.has(profile_kind):
		return _scale_curve_cache[profile_kind]
	var curve := Curve.new()
	curve.min_value = 0.0
	curve.max_value = 1.5
	if profile_kind == Profile.JET:
		curve.add_point(Vector2(0.0, 0.28))
		curve.add_point(Vector2(0.18, 0.72))
		curve.add_point(Vector2(0.65, 1.0))
		curve.add_point(Vector2(1.0, 0.82))
	else:
		curve.add_point(Vector2(0.0, 0.24))
		curve.add_point(Vector2(0.18, 0.72))
		curve.add_point(Vector2(0.58, 1.08))
		curve.add_point(Vector2(1.0, 1.38))
	var texture := CurveTexture.new()
	texture.curve = curve
	_scale_curve_cache[profile_kind] = texture
	return texture


static func _lifetime(profile_kind: int) -> float:
	return [0.90, 1.28, 0.82, 0.38][clampi(profile_kind, 0, 3)]


static func _visibility_bounds(profile_kind: int) -> AABB:
	if profile_kind == Profile.JET:
		return AABB(Vector3(-5, -5, -45), Vector3(10, 10, 50))
	if profile_kind == Profile.AIRBOAT:
		return AABB(Vector3(-4, -3, -8), Vector3(8, 7, 11))
	return AABB(Vector3(-3, -3, -6), Vector3(6, 6, 9))


static func _visibility_range(profile_kind: int) -> float:
	return 520.0 if profile_kind == Profile.JET else (110.0 \
		if profile_kind == Profile.AIRBOAT else 85.0)
