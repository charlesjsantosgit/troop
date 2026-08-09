class_name SeasonalWeather
extends Node3D
## One bounded GPU particle field follows the local player. Reconfiguring that
## field per season avoids extra weather draw calls and keeps precipitation out
## of physics and gameplay simulation.

const NORMAL_COUNTS := {
	SeasonalCycle.Weather.RAIN: 420,
	SeasonalCycle.Weather.FALLING_LEAVES: 150,
	SeasonalCycle.Weather.SNOW: 340,
}
const HIGH_COUNTS := {
	SeasonalCycle.Weather.RAIN: 620,
	SeasonalCycle.Weather.FALLING_LEAVES: 230,
	SeasonalCycle.Weather.SNOW: 500,
}
const PERFORMANCE_COUNTS := {
	SeasonalCycle.Weather.RAIN: 240,
	SeasonalCycle.Weather.FALLING_LEAVES: 80,
	SeasonalCycle.Weather.SNOW: 190,
}

var target: Node3D
var particles: GPUParticles3D
var weather := SeasonalCycle.Weather.CLEAR
var _high_effects := false
var _fullscreen_performance := false
var _atmosphere_enabled := true
var _process_materials: Dictionary = {}
var _particle_meshes: Dictionary = {}


func setup(follow_target: Node3D, initial_weather: SeasonalCycle.Weather) -> void:
	target = follow_target
	particles = GPUParticles3D.new()
	particles.name = "SeasonalWeatherParticles"
	particles.local_coords = false
	particles.fixed_fps = 30
	particles.interp_to_end = 0.0
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visibility_aabb = AABB(Vector3(-32, -24, -32), Vector3(64, 48, 64))
	add_child(particles)
	set_weather(initial_weather)
	set_process(true)


func _process(_dt: float) -> void:
	if target and is_instance_valid(target):
		global_position = target.global_position + Vector3.UP * 11.0


## Transit and the lunar surface are vacuum presentation realms. Keep the same
## cached emitter/resources ready for Earth return, but stop both following and
## GPU simulation so precipitation cannot trail a rocket into space.
func set_atmosphere_enabled(enabled: bool) -> void:
	_atmosphere_enabled = enabled
	visible = enabled
	set_process(enabled)
	if not particles:
		return
	particles.emitting = enabled and weather != SeasonalCycle.Weather.CLEAR
	if particles.emitting:
		particles.restart()


func atmosphere_enabled() -> bool:
	return _atmosphere_enabled


func set_weather(next_weather: SeasonalCycle.Weather) -> void:
	weather = next_weather
	if not particles:
		return
	particles.emitting = false
	if weather == SeasonalCycle.Weather.CLEAR:
		particles.amount = 1
		return
	if not _process_materials.has(weather):
		_process_materials[weather] = _make_process_material(weather)
		_particle_meshes[weather] = _make_particle_mesh(weather)
	particles.process_material = _process_materials[weather]
	particles.draw_pass_1 = _particle_meshes[weather]
	match weather:
		SeasonalCycle.Weather.RAIN:
			particles.lifetime = 1.8
			particles.preprocess = 1.8
		SeasonalCycle.Weather.FALLING_LEAVES:
			particles.lifetime = 7.5
			particles.preprocess = 7.5
		SeasonalCycle.Weather.SNOW:
			particles.lifetime = 6.5
			particles.preprocess = 6.5
	_apply_quality()
	particles.restart()
	particles.emitting = _atmosphere_enabled


func set_quality(high_effects: bool, fullscreen_performance: bool) -> void:
	_high_effects = high_effects
	_fullscreen_performance = fullscreen_performance
	_apply_quality()


func _apply_quality() -> void:
	if not particles or weather == SeasonalCycle.Weather.CLEAR:
		return
	var counts := NORMAL_COUNTS
	if _fullscreen_performance:
		counts = PERFORMANCE_COUNTS
	elif _high_effects:
		counts = HIGH_COUNTS
	particles.amount = int(counts.get(weather, 1))


static func particle_budget(weather_kind: SeasonalCycle.Weather,
		high_effects: bool, fullscreen_performance: bool) -> int:
	if weather_kind == SeasonalCycle.Weather.CLEAR:
		return 0
	if fullscreen_performance:
		return int(PERFORMANCE_COUNTS.get(weather_kind, 0))
	if high_effects:
		return int(HIGH_COUNTS.get(weather_kind, 0))
	return int(NORMAL_COUNTS.get(weather_kind, 0))


static func _make_process_material(weather_kind: SeasonalCycle.Weather) -> ParticleProcessMaterial:
	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	material.emission_box_extents = Vector3(27.0, 10.0, 27.0)
	match weather_kind:
		SeasonalCycle.Weather.RAIN:
			material.direction = Vector3(0.10, -1.0, 0.04)
			material.spread = 3.0
			material.gravity = Vector3(0.0, -7.0, 0.0)
			material.initial_velocity_min = 17.0
			material.initial_velocity_max = 22.0
			material.scale_min = 0.75
			material.scale_max = 1.25
		SeasonalCycle.Weather.FALLING_LEAVES:
			material.direction = Vector3(0.34, -0.68, 0.16)
			material.spread = 28.0
			material.gravity = Vector3(0.45, -0.32, 0.18)
			material.initial_velocity_min = 0.55
			material.initial_velocity_max = 1.45
			material.angular_velocity_min = -150.0
			material.angular_velocity_max = 150.0
			material.scale_min = 0.65
			material.scale_max = 1.35
		SeasonalCycle.Weather.SNOW:
			material.direction = Vector3(0.12, -1.0, 0.07)
			material.spread = 22.0
			material.gravity = Vector3(0.10, -0.24, 0.04)
			material.initial_velocity_min = 0.75
			material.initial_velocity_max = 1.45
			material.angular_velocity_min = -75.0
			material.angular_velocity_max = 75.0
			material.scale_min = 0.55
			material.scale_max = 1.25
	return material


static func _make_particle_mesh(weather_kind: SeasonalCycle.Weather) -> QuadMesh:
	var mesh := QuadMesh.new()
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = false
	match weather_kind:
		SeasonalCycle.Weather.RAIN:
			mesh.size = Vector2(0.018, 0.62)
			material.albedo_color = Color(0.62, 0.79, 0.94, 0.58)
		SeasonalCycle.Weather.FALLING_LEAVES:
			mesh.size = Vector2(0.13, 0.075)
			material.albedo_color = Color(0.92, 0.35, 0.055, 0.92)
		SeasonalCycle.Weather.SNOW:
			mesh.size = Vector2(0.085, 0.085)
			material.albedo_color = Color(0.94, 0.975, 1.0, 0.88)
	mesh.material = material
	return mesh
