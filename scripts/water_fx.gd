class_name WaterFX
extends Node3D
## Procedural, pooled water interaction layer. Callers provide contact points;
## this node owns expanding surface ripples, foam patches, spray particles and
## the local swimmer's subtle water bed. No imported textures or audio assets.

const MAX_SHADER_RIPPLES := 8
const RING_POOL_SIZE := 18
const FOAM_POOL_SIZE := 20
const SPRAY_POOL_SIZE := 8
const MESH_POOL_BUILD_BATCH_SIZE := 4
enum SetupStage {
	NOT_STARTED,
	WATER_MATERIAL,
	RING_RESOURCES,
	RINGS,
	FOAM_RESOURCES,
	FOAMS,
	SPRAY_RESOURCES,
	SPRAYS,
	AUDIO,
	COMPLETE,
}
const SETUP_STAGE_LABELS := [
	"not_started", "material", "ring_resources", "rings", "foam_resources",
	"foams", "spray_resources", "sprays", "audio", "complete",
]

const RING_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform vec3 tint : source_color = vec3(0.68, 0.96, 0.90);
uniform float fade : hint_range(0.0, 1.0) = 0.0;
uniform float seed = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float angle = atan(p.y, p.x);
	float radius = length(p);
	float wobble = sin(angle * 9.0 + seed * 5.7) * 0.018
		+ sin(angle * 15.0 - seed * 2.1) * 0.009;
	float ring = 1.0 - smoothstep(0.025, 0.085, abs(radius - 0.78 - wobble));
	float breakup = mix(0.52, 1.0,
		hash21(floor(UV * 34.0 + vec2(seed * 13.0, seed * 7.0))));
	float edge = 1.0 - smoothstep(0.91, 0.99, radius);
	ALBEDO = tint;
	EMISSION = tint * 0.18;
	ALPHA = ring * breakup * edge * fade;
}
"""

const FOAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform vec3 tint : source_color = vec3(0.76, 0.97, 0.89);
uniform float fade : hint_range(0.0, 1.0) = 0.0;
uniform float seed = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 19.19);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0)), f.x), f.y);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float radius = length(p);
	float broad = 1.0 - smoothstep(0.40, 1.0, radius);
	float cells = value_noise(UV * 17.0 + vec2(seed * 9.0, -seed * 5.0));
	float fine = value_noise(UV * 41.0 - vec2(seed * 3.0, seed * 11.0));
	float flecks = smoothstep(0.43, 0.72, cells * 0.72 + fine * 0.38);
	float broken_edge = smoothstep(0.16, 0.58, cells + broad * 0.34);
	ALBEDO = tint;
	EMISSION = tint * 0.12;
	ALPHA = broad * broken_edge * mix(0.24, 0.92, flecks) * fade;
}
"""

# Shader source never changes with the world or an individual splash. Keep the
# programs alive across cancel/rejoin; each pool slot still owns its uniforms.
static var _ring_shader: Shader
static var _foam_shader: Shader

var water_level := 0.55
var _rings: Array[Dictionary] = []
var _foams: Array[Dictionary] = []
var _sprays: Array[GPUParticles3D] = []
var _swimmers: Dictionary = {}
var _ring_cursor := 0
var _foam_cursor := 0
var _spray_cursor := 0
var _event_serial := 0
var _clock := 0.0
var _quality_scale := 0.72
var _water_material: ShaderMaterial
var _water_loop: AudioStreamPlayer
var _loop_target_db := -60.0
var _setup_stage := SetupStage.NOT_STARTED
var _ring_mesh: QuadMesh
var _foam_mesh: QuadMesh
var _spray_gradient: GradientTexture1D
var _spray_mesh: QuadMesh


func setup(level: float) -> void:
	water_level = level


func _ready() -> void:
	# Existing standalone callers retain fully-ready pools when add_child()
	# returns. Online World construction opts into staging before adding us.
	if _setup_stage != SetupStage.NOT_STARTED:
		return
	begin_setup(water_level)
	while not setup_step():
		pass


## Opt into staged construction before add_child(). No GPU resources are
## created here; callers advance setup_step() once per displayed loading frame.
func begin_setup(level: float) -> void:
	water_level = level
	if _setup_stage == SetupStage.NOT_STARTED:
		_setup_stage = SetupStage.WATER_MATERIAL


## One resource family, at most four mesh nodes, or one spray emitter per call.
## Full materials, pool sizes and emission settings match synchronous _ready().
func setup_step() -> bool:
	if _setup_stage == SetupStage.NOT_STARTED:
		begin_setup(water_level)
	match _setup_stage:
		SetupStage.WATER_MATERIAL:
			_water_material = Visuals.water_material()
			_setup_stage = SetupStage.RING_RESOURCES
		SetupStage.RING_RESOURCES:
			_prepare_ring_resources()
			_setup_stage = SetupStage.RINGS
		SetupStage.RINGS:
			_build_ring_pool_step()
			if _rings.size() == RING_POOL_SIZE:
				_setup_stage = SetupStage.FOAM_RESOURCES
		SetupStage.FOAM_RESOURCES:
			_prepare_foam_resources()
			_setup_stage = SetupStage.FOAMS
		SetupStage.FOAMS:
			_build_foam_pool_step()
			if _foams.size() == FOAM_POOL_SIZE:
				_setup_stage = SetupStage.SPRAY_RESOURCES
		SetupStage.SPRAY_RESOURCES:
			_prepare_spray_resources()
			_setup_stage = SetupStage.SPRAYS
		SetupStage.SPRAYS:
			_build_one_spray()
			if _sprays.size() == SPRAY_POOL_SIZE:
				_setup_stage = SetupStage.AUDIO
		SetupStage.AUDIO:
			_build_water_loop()
			_upload_shader_ripples()
			_setup_stage = SetupStage.COMPLETE
	return is_setup_complete()


func is_setup_complete() -> bool:
	return _setup_stage == SetupStage.COMPLETE


func setup_stage_name() -> String:
	return SETUP_STAGE_LABELS[_setup_stage]


func _exit_tree() -> void:
	if _water_material:
		_water_material.set_shader_parameter("ripple_count", 0)


func _process(dt: float) -> void:
	if not is_setup_complete():
		return
	_clock += dt
	_update_rings(dt)
	_update_foam(dt)
	_upload_shader_ripples()
	_update_loop(dt)
	_prune_swimmers()


## Matches World's existing two quality switches without making World a hard
## dependency. Ripples and audio remain; only particle/foam density scales.
func set_effect_quality(high_effects: bool, fullscreen_performance: bool) -> void:
	_quality_scale = 0.46 if fullscreen_performance else (1.0 if high_effects else 0.72)


## Large contact, suitable for falling into water. Intensity is normally 0..1,
## but values up to 1.5 are accepted for very fast dives.
func entry_splash(position: Vector3, velocity := Vector3.ZERO,
		intensity := 1.0) -> void:
	_emit_splash(position, velocity, intensity, "water_entry", 2.55, 1.55)


## Backward-compatible generic entry point for gameplay callers.
func splash(position: Vector3, velocity := Vector3.ZERO, intensity := 1.0) -> void:
	entry_splash(position, velocity, intensity)


## Smaller sheet of water for a surface hop or shoreline exit.
func exit_splash(position: Vector3, velocity := Vector3.ZERO,
		intensity := 0.75) -> void:
	_emit_splash(position, velocity, intensity, "water_exit", 1.85, 1.05)


## One freestyle hand catch. Pass the animated paw position when available.
## Side is -1 for left and +1 for right and only adds subtle sonic variation.
func stroke(position: Vector3, velocity := Vector3.ZERO, side := 0,
		intensity := 0.65) -> void:
	if not is_setup_complete():
		return
	var strength := clampf(intensity, 0.15, 1.25)
	var flat_velocity := Vector3(velocity.x, 0.0, velocity.z)
	_emit_spray(position, flat_velocity + Vector3.UP * 0.7, strength * 0.55)
	_emit_foam(position, flat_velocity, 0.24 + strength * 0.20,
		0.48 + strength * 0.18, 0.62)
	emit_ripple(position, 0.28 + strength * 0.22,
		0.78 + strength * 0.42, 0.92)
	var side_pitch := float(clampi(side, -1, 1)) * 0.025
	Sfx.play_at("swim_stroke", _surface_point(position), -17.0 + strength * 3.0,
		1.0 + side_pitch + randf_range(-0.035, 0.035), 30.0)


## Small, quiet disturbance for one flutter-kick crossing the surface. The
## continuous water bed carries the sound so six-beat kicks do not become noisy.
func kick(position: Vector3, velocity := Vector3.ZERO, intensity := 0.42) -> void:
	var strength := clampf(intensity, 0.10, 0.85)
	var flat_velocity := Vector3(velocity.x, 0.0, velocity.z)
	_emit_spray(position, flat_velocity + Vector3.UP * 0.35, strength * 0.30)
	_emit_foam(position, flat_velocity, 0.11 + strength * 0.10,
		0.22 + strength * 0.16, 0.46)
	emit_ripple(position, 0.10 + strength * 0.11,
		0.42 + strength * 0.24, 0.62)


## Add one expanding physical/visual ring. Active rings are also uploaded into
## the shared water shader so nearby surface vertices lift under the crest.
func emit_ripple(position: Vector3, strength := 0.55, max_radius := 2.0,
		duration := 1.35) -> void:
	if not is_setup_complete() or _rings.is_empty():
		return
	var item: Dictionary = _rings[_ring_cursor]
	_ring_cursor = (_ring_cursor + 1) % _rings.size()
	_event_serial += 1
	var node: MeshInstance3D = item["node"]
	var material: ShaderMaterial = item["material"]
	var origin := _surface_point(position)
	item["active"] = true
	item["age"] = 0.0
	item["duration"] = maxf(duration, 0.25)
	item["origin"] = origin
	item["start_radius"] = 0.16
	item["max_radius"] = maxf(max_radius, 0.3)
	item["strength"] = clampf(strength, 0.05, 1.5)
	node.global_position = origin + Vector3.UP * 0.088
	node.scale = Vector3.ONE * 0.16
	node.visible = true
	material.set_shader_parameter("seed", float(_event_serial % 97) / 97.0)
	material.set_shader_parameter("fade", 0.0)


## Feed this once per physics tick for each swimmer. It emits distance-spaced
## wake patches, so frame rate changes do not alter wake density.
func update_swimmer(actor_key: Variant, position: Vector3, velocity: Vector3,
		active: bool, intensity := 1.0) -> void:
	if not is_setup_complete():
		return
	if not active:
		_swimmers.erase(actor_key)
		return
	var state: Dictionary = _swimmers.get(actor_key, {
		"last_position": position,
		"distance": 0.0,
		"last_emit": -10.0,
		"seen": _clock,
	})
	var previous: Vector3 = state["last_position"]
	var travelled := Vector2(position.x - previous.x, position.z - previous.z).length()
	state["distance"] = float(state["distance"]) + minf(travelled, 2.0)
	state["last_position"] = position
	state["seen"] = _clock
	var flat_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var speed := flat_velocity.length()
	var spacing := lerpf(0.82, 0.46, clampf(speed / 7.0, 0.0, 1.0))
	if float(state["distance"]) >= spacing and _clock - float(state["last_emit"]) >= 0.12:
		state["distance"] = fmod(float(state["distance"]), spacing)
		state["last_emit"] = _clock
		var wake_strength := clampf(intensity, 0.2, 1.2) * clampf(speed / 5.0, 0.25, 1.15)
		_emit_foam(position, flat_velocity, 0.20 + wake_strength * 0.16,
			0.52 + wake_strength * 0.34, 0.82)
		emit_ripple(position, 0.12 + wake_strength * 0.16,
			0.62 + wake_strength * 0.40, 0.86)
	_swimmers[actor_key] = state


func remove_swimmer(actor_key: Variant) -> void:
	_swimmers.erase(actor_key)


## Controls the non-spatial water movement bed heard by the local player.
func set_listener_swimming(active: bool, speed := 0.0) -> void:
	if not is_setup_complete():
		return
	if active:
		_loop_target_db = lerpf(-30.0, -22.0, clampf(speed / 7.0, 0.0, 1.0))
		_water_loop.pitch_scale = lerpf(0.92, 1.08, clampf(speed / 7.0, 0.0, 1.0))
		if _water_loop.stream and not _water_loop.playing and Sfx.audio_enabled:
			_water_loop.play()
	else:
		_loop_target_db = -60.0


func _emit_splash(position: Vector3, velocity: Vector3, intensity: float,
		sound_name: String, ripple_radius: float, foam_size: float) -> void:
	if not is_setup_complete():
		return
	var strength := clampf(intensity, 0.2, 1.5)
	var flat_velocity := Vector3(velocity.x, 0.0, velocity.z)
	_emit_spray(position, velocity, strength)
	_emit_foam(position, flat_velocity, foam_size * (0.55 + strength * 0.45),
		foam_size * (0.48 + strength * 0.52), 1.05 + strength * 0.20)
	emit_ripple(position, 0.55 + strength * 0.35,
		ripple_radius * (0.62 + strength * 0.38), 1.35 + strength * 0.18)
	Sfx.play_at(sound_name, _surface_point(position), -10.0 + strength * 3.0,
		randf_range(0.94, 1.06), 48.0)


func _prepare_ring_resources() -> void:
	if not _ring_shader:
		_ring_shader = Shader.new()
		_ring_shader.code = RING_SHADER
	_ring_mesh = QuadMesh.new()
	_ring_mesh.size = Vector2(2.0, 2.0)
	_ring_mesh.orientation = PlaneMesh.FACE_Y


func _build_ring_pool_step() -> void:
	for i in range(mini(MESH_POOL_BUILD_BATCH_SIZE, RING_POOL_SIZE - _rings.size())):
		var material := ShaderMaterial.new()
		material.shader = _ring_shader
		material.render_priority = 2
		var node := MeshInstance3D.new()
		node.mesh = _ring_mesh
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.visibility_range_end = 72.0
		node.visibility_range_end_margin = 8.0
		node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		node.visible = false
		add_child(node)
		_rings.append({
			"node": node,
			"material": material,
			"active": false,
			"age": 0.0,
			"duration": 1.0,
			"origin": Vector3.ZERO,
			"start_radius": 0.16,
			"max_radius": 1.0,
			"strength": 0.0,
		})


func _prepare_foam_resources() -> void:
	if not _foam_shader:
		_foam_shader = Shader.new()
		_foam_shader.code = FOAM_SHADER
	_foam_mesh = QuadMesh.new()
	_foam_mesh.size = Vector2(2.0, 2.0)
	_foam_mesh.orientation = PlaneMesh.FACE_Y


func _build_foam_pool_step() -> void:
	for i in range(mini(MESH_POOL_BUILD_BATCH_SIZE, FOAM_POOL_SIZE - _foams.size())):
		var material := ShaderMaterial.new()
		material.shader = _foam_shader
		material.render_priority = 3
		var node := MeshInstance3D.new()
		node.mesh = _foam_mesh
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.visibility_range_end = 62.0
		node.visibility_range_end_margin = 7.0
		node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		node.visible = false
		add_child(node)
		_foams.append({
			"node": node,
			"material": material,
			"active": false,
			"age": 0.0,
			"duration": 1.0,
			"origin": Vector3.ZERO,
			"size": Vector2.ONE,
		})


func _prepare_spray_resources() -> void:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.58, 1.0])
	gradient.colors = PackedColorArray([
		Color(0.82, 1.0, 0.95, 0.95),
		Color(0.54, 0.92, 0.88, 0.72),
		Color(0.38, 0.78, 0.78, 0.0),
	])
	_spray_gradient = GradientTexture1D.new()
	_spray_gradient.gradient = gradient
	# A generated radial alpha mask keeps the billboard's corners transparent;
	# the non-square quad turns the soft disc into a small falling droplet.
	var mask_gradient := Gradient.new()
	mask_gradient.offsets = PackedFloat32Array([0.0, 0.58, 0.82, 1.0])
	mask_gradient.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.98),
		Color(1.0, 1.0, 1.0, 0.90),
		Color(1.0, 1.0, 1.0, 0.34),
		Color(1.0, 1.0, 1.0, 0.0),
	])
	var droplet_mask := GradientTexture2D.new()
	droplet_mask.width = 32
	droplet_mask.height = 32
	droplet_mask.fill = GradientTexture2D.FILL_RADIAL
	droplet_mask.fill_from = Vector2(0.5, 0.5)
	droplet_mask.fill_to = Vector2(1.0, 0.5)
	droplet_mask.gradient = mask_gradient
	var droplet_material := StandardMaterial3D.new()
	droplet_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	droplet_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	droplet_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	droplet_material.vertex_color_use_as_albedo = true
	droplet_material.albedo_color = Color(0.72, 0.98, 0.94, 0.9)
	droplet_material.albedo_texture = droplet_mask
	_spray_mesh = QuadMesh.new()
	_spray_mesh.size = Vector2(0.046, 0.092)
	_spray_mesh.material = droplet_material


func _build_one_spray() -> void:
	var process_material := ParticleProcessMaterial.new()
	process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process_material.emission_sphere_radius = 0.13
	process_material.direction = Vector3.UP
	process_material.spread = 48.0
	process_material.gravity = Vector3(0.0, -8.6, 0.0)
	process_material.initial_velocity_min = 1.25
	process_material.initial_velocity_max = 3.6
	process_material.scale_min = 0.48
	process_material.scale_max = 1.28
	process_material.color_ramp = _spray_gradient
	var particles := GPUParticles3D.new()
	particles.process_material = process_material
	particles.draw_pass_1 = _spray_mesh
	particles.amount = 18
	particles.lifetime = 0.72
	particles.one_shot = true
	particles.explosiveness = 0.96
	particles.randomness = 0.48
	particles.local_coords = false
	particles.fixed_fps = 30
	particles.visibility_aabb = AABB(Vector3(-5.0, -3.0, -5.0),
		Vector3(10.0, 8.0, 10.0))
	particles.emitting = false
	add_child(particles)
	_sprays.append(particles)


func _build_water_loop() -> void:
	_water_loop = AudioStreamPlayer.new()
	_water_loop.stream = Sfx.streams.get("water_loop")
	_water_loop.volume_db = -60.0
	_water_loop.bus = &"Ambience"
	add_child(_water_loop)


func _emit_spray(position: Vector3, velocity: Vector3, intensity: float) -> void:
	if not is_setup_complete() or _sprays.is_empty():
		return
	var particles: GPUParticles3D = _sprays[_spray_cursor]
	_spray_cursor = (_spray_cursor + 1) % _sprays.size()
	var process_material := particles.process_material as ParticleProcessMaterial
	var strength := clampf(intensity, 0.15, 1.5)
	var direction := Vector3(velocity.x * 0.075,
		1.0 + absf(velocity.y) * 0.035, velocity.z * 0.075).normalized()
	process_material.direction = direction
	process_material.initial_velocity_min = 0.9 + strength * 0.55
	process_material.initial_velocity_max = 2.0 + strength * 2.1
	process_material.emission_sphere_radius = 0.08 + strength * 0.09
	particles.amount = maxi(6, roundi((10.0 + strength * 15.0) * _quality_scale))
	particles.lifetime = 0.52 + strength * 0.24
	particles.global_position = _surface_point(position) + Vector3.UP * 0.06
	particles.emitting = false
	particles.restart()
	particles.emitting = true


func _emit_foam(position: Vector3, velocity: Vector3, width: float, length: float,
		duration: float) -> void:
	if not is_setup_complete() or _foams.is_empty() \
			or (_quality_scale < 0.55 and _event_serial % 2 == 1):
		return
	var item: Dictionary = _foams[_foam_cursor]
	_foam_cursor = (_foam_cursor + 1) % _foams.size()
	_event_serial += 1
	var node: MeshInstance3D = item["node"]
	var material: ShaderMaterial = item["material"]
	item["active"] = true
	item["age"] = 0.0
	item["duration"] = maxf(duration, 0.25)
	item["origin"] = position
	item["size"] = Vector2(maxf(width, 0.08), maxf(length, 0.08))
	node.global_position = _surface_point(position) + Vector3.UP * 0.094
	if velocity.length_squared() > 0.01:
		node.rotation.y = atan2(velocity.x, velocity.z)
	else:
		node.rotation.y = randf() * TAU
	node.scale = Vector3(width * 0.6, 1.0, length * 0.6)
	node.visible = true
	material.set_shader_parameter("seed", float(_event_serial % 113) / 113.0)
	material.set_shader_parameter("fade", 0.0)


func _update_rings(dt: float) -> void:
	for item in _rings:
		if not bool(item["active"]):
			continue
		item["age"] = float(item["age"]) + dt
		var progress := float(item["age"]) / float(item["duration"])
		var node: MeshInstance3D = item["node"]
		var material: ShaderMaterial = item["material"]
		if progress >= 1.0:
			item["active"] = false
			node.visible = false
			material.set_shader_parameter("fade", 0.0)
			continue
		var eased := 1.0 - pow(1.0 - progress, 1.7)
		var radius := lerpf(float(item["start_radius"]), float(item["max_radius"]), eased)
		node.scale = Vector3.ONE * radius
		var origin: Vector3 = item["origin"]
		node.global_position = _surface_point(origin) + Vector3.UP * 0.088
		var fade := sin(progress * PI) * (1.0 - progress * 0.46) \
			* clampf(float(item["strength"]), 0.0, 1.0)
		material.set_shader_parameter("fade", fade)


func _update_foam(dt: float) -> void:
	for item in _foams:
		if not bool(item["active"]):
			continue
		item["age"] = float(item["age"]) + dt
		var progress := float(item["age"]) / float(item["duration"])
		var node: MeshInstance3D = item["node"]
		var material: ShaderMaterial = item["material"]
		if progress >= 1.0:
			item["active"] = false
			node.visible = false
			material.set_shader_parameter("fade", 0.0)
			continue
		var size: Vector2 = item["size"]
		var growth := lerpf(0.62, 1.18, sqrt(progress))
		node.scale = Vector3(size.x * growth, 1.0, size.y * growth)
		var origin: Vector3 = item["origin"]
		node.global_position = _surface_point(origin) + Vector3.UP * 0.094
		var fade := smoothstep(0.0, 0.13, progress) * pow(1.0 - progress, 1.35)
		material.set_shader_parameter("fade", fade * 0.88)


func _upload_shader_ripples() -> void:
	if not _water_material:
		return
	var data := PackedVector4Array()
	var active_count := 0
	# New contacts matter most when wakes temporarily exceed the shader budget.
	# Walk backward from the next reuse slot so the eight freshest rings win.
	for offset in range(_rings.size()):
		var index := posmod(_ring_cursor - 1 - offset, _rings.size())
		var item: Dictionary = _rings[index]
		if not bool(item["active"]) or active_count >= MAX_SHADER_RIPPLES:
			continue
		var progress := clampf(float(item["age"]) / float(item["duration"]), 0.0, 1.0)
		var eased := 1.0 - pow(1.0 - progress, 1.7)
		var radius := lerpf(float(item["start_radius"]), float(item["max_radius"]), eased)
		var origin: Vector3 = item["origin"]
		var strength := float(item["strength"]) * pow(1.0 - progress, 1.2)
		data.append(Vector4(origin.x, origin.z, radius, strength))
		active_count += 1
	while data.size() < MAX_SHADER_RIPPLES:
		data.append(Vector4.ZERO)
	_water_material.set_shader_parameter("ripple_data", data)
	_water_material.set_shader_parameter("ripple_count", active_count)


func _update_loop(dt: float) -> void:
	if not _water_loop:
		return
	_water_loop.volume_db = move_toward(_water_loop.volume_db, _loop_target_db, dt * 34.0)
	if _loop_target_db <= -59.0 and _water_loop.volume_db <= -58.5 and _water_loop.playing:
		_water_loop.stop()


func _prune_swimmers() -> void:
	for actor_key in _swimmers.keys():
		var state: Dictionary = _swimmers[actor_key]
		if _clock - float(state["seen"]) > 1.0:
			_swimmers.erase(actor_key)


func _surface_point(position: Vector3) -> Vector3:
	var configured_offset := water_level - Gen.WATER_Y
	var surface_y := Visuals.water_surface_y(position.x, position.z, _clock) \
		+ configured_offset
	return Vector3(position.x, surface_y, position.z)
