class_name CelestialSky
extends RefCounted
## One deterministic, texture-backed sky material for the day/night gradient,
## stars, constellations, planets, and cratered moon. The atlas is generated once
## on startup and the shader is updated only on World's bounded sky cadence.

const ATLAS_WIDTH := 1024
const ATLAS_HEIGHT := 1024
const RANDOM_STAR_COUNT := 900
const PLANET_COUNT := 4
const MOON_DIAMETER_DEGREES := 1.1
const MOON_CRATER_COUNT := 7
const CONSTELLATION_LINE_STRENGTH := 0.16
const MAX_MOON_STRENGTH := 3.8

static var _shared_shader: Shader
static var _shared_atlas_texture: ImageTexture
static var _shared_catalog_signature := ""
static var _shared_constellation_segment_count := 0

const SKY_SHADER := """
shader_type sky;

uniform sampler2D celestial_atlas : filter_linear_mipmap, repeat_enable;
uniform vec4 sky_top_color : source_color = vec4(0.027, 0.082, 0.239, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.063, 0.169, 0.357, 1.0);
uniform vec4 ground_bottom_color : source_color = vec4(0.008, 0.025, 0.075, 1.0);
uniform vec4 ground_horizon_color : source_color = vec4(0.025, 0.080, 0.165, 1.0);
uniform float sky_energy = 0.72;
uniform float daylight_amount = 0.0;
uniform float night_visibility = 1.0;
uniform float weather_visibility = 1.0;
uniform vec2 sidereal_rotation = vec2(1.0, 0.0);
uniform vec3 moon_direction = vec3(0.0, 1.0, 0.0);
uniform float moon_visibility = 1.0;
uniform float moon_radius_sine = 0.008726535;
uniform float moon_guard_cosine = 0.999902524;
uniform vec3 sun_direction = vec3(0.0, -1.0, 0.0);

float ellipse_mask(vec2 p, vec2 center, vec2 radius, float softness) {
	float d = length((p - center) / radius);
	return 1.0 - smoothstep(1.0 - softness, 1.0, d);
}

float crater_relief(vec2 p, vec2 center, vec2 radius) {
	float d = length((p - center) / radius);
	float bowl = (1.0 - smoothstep(0.12, 0.76, d)) * -0.20;
	float rim = smoothstep(0.62, 0.79, d) * (1.0 - smoothstep(0.80, 1.0, d)) * 0.16;
	return bowl + rim;
}

void sky() {
	float vertical = clamp(abs(EYEDIR.y), 0.0, 1.0);
	float gradient = pow(vertical, 0.58);
	vec3 base_sky = EYEDIR.y >= 0.0
		? mix(sky_horizon_color.rgb, sky_top_color.rgb, gradient)
		: mix(ground_horizon_color.rgb, ground_bottom_color.rgb, gradient);
	COLOR = base_sky * sky_energy;

	// Bright point sources are excluded from radiance generation so they never
	// wash the jungle or trigger sparkling reflections on water.
	if (!AT_CUBEMAP_PASS) {
		vec3 view_dir = normalize(EYEDIR);
		if (night_visibility > 0.001 && weather_visibility > 0.001
				&& view_dir.y > -0.008) {
			// A Lambert azimuthal upper-hemisphere atlas has no
			// equirectangular pole. Its square-root radius also distributes
			// the fixed catalog evenly without per-pixel trigonometry.
			vec2 horizontal = view_dir.xz;
			vec2 azimuth_direction = horizontal
				/ max(length(horizontal), 0.00001);
			vec2 rotated_azimuth = vec2(
				azimuth_direction.x * sidereal_rotation.x
					- azimuth_direction.y * sidereal_rotation.y,
				azimuth_direction.x * sidereal_rotation.y
					+ azimuth_direction.y * sidereal_rotation.x);
			float polar_radius = sqrt(max(1.0
				- clamp(view_dir.y, 0.0, 1.0), 0.0)) * 0.488;
			vec2 atlas_uv = vec2(0.5) + rotated_azimuth * polar_radius;
			vec4 atlas = texture(celestial_atlas, atlas_uv);
			float upper_sky = smoothstep(-0.008, 0.018, view_dir.y);
			COLOR += atlas.rgb * night_visibility * weather_visibility
				* upper_sky * 1.02;
		}

		vec3 md = moon_direction;
		float moon_facing = dot(view_dir, md);
		// The expensive maria/crater field runs only for fragments within the
		// moon and its tight halo, and is skipped entirely during daylight.
		if (moon_visibility > 0.001 && moon_facing > moon_guard_cosine) {
			vec3 reference_axis = abs(md.y) > 0.92
				? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
			vec3 tangent = normalize(cross(reference_axis, md));
			vec3 bitangent = normalize(cross(md, tangent));
			vec2 moon_uv = vec2(dot(view_dir, tangent),
				dot(view_dir, bitangent)) / max(moon_radius_sine, 0.0001);
			float moon_radius = length(moon_uv);
			float disc = 1.0 - smoothstep(0.961, 1.039, moon_radius);
			float halo = (1.0 - smoothstep(1.0, 1.48, moon_radius))
				* (1.0 - disc);
			float radial = clamp(moon_radius, 0.0, 1.0);
			float limb = sqrt(max(0.0, 1.0 - radial * radial));

			float maria = 0.0;
			maria = max(maria, ellipse_mask(moon_uv, vec2(-0.23, 0.18), vec2(0.34, 0.22), 0.28));
			maria = max(maria, ellipse_mask(moon_uv, vec2(0.22, -0.05), vec2(0.25, 0.34), 0.30));
			maria = max(maria, ellipse_mask(moon_uv, vec2(-0.04, -0.36), vec2(0.30, 0.17), 0.32));
			float relief = 0.0;
			relief += crater_relief(moon_uv, vec2(-0.44, -0.12), vec2(0.16, 0.14));
			relief += crater_relief(moon_uv, vec2(-0.15, 0.39), vec2(0.13, 0.11));
			relief += crater_relief(moon_uv, vec2(0.12, 0.18), vec2(0.18, 0.15));
			relief += crater_relief(moon_uv, vec2(0.43, 0.30), vec2(0.11, 0.10));
			relief += crater_relief(moon_uv, vec2(0.36, -0.34), vec2(0.15, 0.13));
			relief += crater_relief(moon_uv, vec2(-0.25, -0.48), vec2(0.10, 0.09));
			relief += crater_relief(moon_uv, vec2(0.03, -0.02), vec2(0.09, 0.08));
			vec3 moon_color = vec3(0.66, 0.71, 0.80);
			moon_color *= mix(0.72, 1.03, limb);
			moon_color *= 1.0 - maria * 0.42;
			moon_color += relief * vec3(0.92, 0.96, 1.0);
			moon_color += vec3(0.04, 0.055, 0.09) * (1.0 - limb);
			COLOR = mix(COLOR, moon_color, disc * moon_visibility);
			COLOR += vec3(0.28, 0.38, 0.66) * halo
				* moon_visibility * 0.19;
		}

		// Keep a compact physical sun after replacing ProceduralSkyMaterial.
		if (daylight_amount > 0.001) {
			vec3 sd = sun_direction;
			float sun_facing = dot(view_dir, sd);
			float sun_disc = smoothstep(0.999980780, 0.999988480,
				sun_facing);
			float sun_halo = smoothstep(0.999550034, 0.999982000,
				sun_facing) * (1.0 - sun_disc);
			float sun_height = clamp(sd.y, 0.0, 1.0);
			vec3 sun_color = mix(vec3(1.0, 0.34, 0.09),
				vec3(1.0, 0.92, 0.72), sun_height);
			COLOR += sun_color * daylight_amount
				* (sun_disc * 1.8 + sun_halo * 0.16);
		}
	}
}
"""

var material: ShaderMaterial
var _shader: Shader
var _atlas_texture: ImageTexture
var _night_visibility := 0.0
var _weather_visibility := 1.0
var _palette := {
	"top": Color(0.027, 0.082, 0.239),
	"horizon": Color(0.063, 0.169, 0.357),
	"ground_bottom": Color(0.008, 0.025, 0.075),
	"ground_horizon": Color(0.025, 0.080, 0.165),
}
var _constellation_names := PackedStringArray([
	"Big Dipper", "Cassiopeia", "Orion",
])
var _constellation_segment_count := 0
var _catalog_signature := ""


func _init() -> void:
	if _shared_shader == null or _shared_atlas_texture == null:
		_build_catalog()
		_shader = Shader.new()
		_shader.code = SKY_SHADER
		_shared_shader = _shader
		_shared_atlas_texture = _atlas_texture
		_shared_catalog_signature = _catalog_signature
		_shared_constellation_segment_count = _constellation_segment_count
	else:
		_shader = _shared_shader
		_atlas_texture = _shared_atlas_texture
		_catalog_signature = _shared_catalog_signature
		_constellation_segment_count = _shared_constellation_segment_count
	material = ShaderMaterial.new()
	material.shader = _shader
	material.set_shader_parameter("celestial_atlas", _atlas_texture)
	var moon_radius := deg_to_rad(MOON_DIAMETER_DEGREES * 0.5)
	material.set_shader_parameter("moon_radius_sine", sin(moon_radius))
	material.set_shader_parameter("moon_guard_cosine", cos(moon_radius * 1.6))
	update_palette(_palette.top, _palette.horizon,
		_palette.ground_bottom, _palette.ground_horizon, 0.72)
	update_celestials(1.0, 1.0, Vector3.UP, 0.0, 12.0, Vector3.DOWN)


func get_material() -> ShaderMaterial:
	return material


func update_palette(top: Color, horizon: Color, ground_bottom: Color,
		ground_horizon: Color, energy: float) -> void:
	_palette = {
		"top": top,
		"horizon": horizon,
		"ground_bottom": ground_bottom,
		"ground_horizon": ground_horizon,
	}
	material.set_shader_parameter("sky_top_color", top)
	material.set_shader_parameter("sky_horizon_color", horizon)
	material.set_shader_parameter("ground_bottom_color", ground_bottom)
	material.set_shader_parameter("ground_horizon_color", ground_horizon)
	material.set_shader_parameter("sky_energy", clampf(energy, 0.0, 2.0))


func update_celestials(daylight: float, weather_visibility_v: float,
		moon_direction: Vector3, moon_strength: float, hour: float,
		sun_direction: Vector3 = Vector3.ZERO) -> void:
	var day := clampf(daylight, 0.0, 1.0)
	_night_visibility = pow(1.0 - day, 1.65)
	_weather_visibility = pow(clampf(weather_visibility_v, 0.0, 1.0), 3.0)
	var safe_moon_direction := moon_direction.normalized() \
		if moon_direction.length_squared() > 0.0001 else Vector3.UP
	# The current celestial orbit keeps the moon opposite the sun. Inferring that
	# direction preserves the five-argument API without losing the daytime disc.
	var safe_sun_direction := sun_direction.normalized() \
		if sun_direction.length_squared() > 0.0001 else -safe_moon_direction
	material.set_shader_parameter("daylight_amount", day)
	material.set_shader_parameter("night_visibility", _night_visibility)
	material.set_shader_parameter("weather_visibility", _weather_visibility)
	var sidereal_angle := wrapf(hour / 24.0 + 0.08, 0.0, 1.0) * TAU
	material.set_shader_parameter("sidereal_rotation",
		Vector2(cos(sidereal_angle), sin(sidereal_angle)))
	material.set_shader_parameter("moon_direction", safe_moon_direction)
	material.set_shader_parameter("moon_visibility",
		clampf(moon_strength / MAX_MOON_STRENGTH, 0.0, 1.0))
	material.set_shader_parameter("sun_direction", safe_sun_direction)


func star_count() -> int:
	return RANDOM_STAR_COUNT


func constellation_names() -> PackedStringArray:
	return _constellation_names.duplicate()


func constellation_segment_count() -> int:
	return _constellation_segment_count


func planet_count() -> int:
	return PLANET_COUNT


func moon_angular_diameter_degrees() -> float:
	return MOON_DIAMETER_DEGREES


func moon_crater_count() -> int:
	return MOON_CRATER_COUNT


func night_visibility() -> float:
	return _night_visibility


func weather_visibility() -> float:
	return _weather_visibility


func constellation_strength() -> float:
	return CONSTELLATION_LINE_STRENGTH


func resource_instance_ids() -> Dictionary:
	return {
		"shader": _shader.get_instance_id(),
		"material": material.get_instance_id(),
		"atlas": _atlas_texture.get_instance_id(),
	}


func catalog_signature() -> String:
	return _catalog_signature


func palette_colors() -> Dictionary:
	return _palette.duplicate()


func _build_catalog() -> void:
	_constellation_segment_count = 0
	var image := Image.create_empty(ATLAS_WIDTH, ATLAS_HEIGHT, false,
		Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5A17C0DE
	for index in range(RANDOM_STAR_COUNT):
		# Uniform directions across the upper hemisphere, projected into the
		# atlas disk. Keeping the catalog in a square texture also preserves
		# circular point shapes in every direction.
		var direction_y := rng.randf_range(0.018, 1.0)
		var polar_radius := sqrt(maxf(1.0 - direction_y, 0.0)) * 0.486
		var azimuth := rng.randf() * TAU
		var point_uv := Vector2(0.5, 0.5) + Vector2(
			cos(azimuth), sin(azimuth)) * polar_radius
		var x := roundi(point_uv.x * float(ATLAS_WIDTH - 1))
		var y := roundi(point_uv.y * float(ATLAS_HEIGHT - 1))
		var roll := rng.randf()
		var radius := 0
		if roll > 0.997:
			radius = 2
		elif roll > 0.94:
			radius = 1
		var tint_roll := rng.randf()
		var tint := Color(0.88, 0.93, 1.0)
		if tint_roll < 0.18:
			tint = Color(1.0, 0.84, 0.66)
		elif tint_roll > 0.80:
			tint = Color(0.65, 0.79, 1.0)
		_stamp_star(image, Vector2i(x, y), radius,
			tint, rng.randf_range(0.20, 0.78))

	_add_constellations(image)
	_add_planets(image)
	image.generate_mipmaps()
	_atlas_texture = ImageTexture.create_from_image(image)
	_catalog_signature = "%d:%d:%d:%d:%d" % [
		hash(image.get_data()), RANDOM_STAR_COUNT,
		_constellation_segment_count, PLANET_COUNT, MOON_CRATER_COUNT,
	]


func _add_constellations(image: Image) -> void:
	var patterns: Array[Dictionary] = [
		{
			"points": [Vector2(0.10, 0.23), Vector2(0.145, 0.20),
				Vector2(0.19, 0.23), Vector2(0.225, 0.19),
				Vector2(0.27, 0.17), Vector2(0.31, 0.20),
				Vector2(0.285, 0.25)],
			"edges": [Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3),
				Vector2i(3, 4), Vector2i(4, 5), Vector2i(5, 6),
				Vector2i(6, 3)],
		},
		{
			"points": [Vector2(0.42, 0.16), Vector2(0.46, 0.21),
				Vector2(0.50, 0.16), Vector2(0.54, 0.22),
				Vector2(0.585, 0.17)],
			"edges": [Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3),
				Vector2i(3, 4)],
		},
		{
			"points": [Vector2(0.5425, 0.437), Vector2(0.592, 0.437),
				Vector2(0.562, 0.4755), Vector2(0.57, 0.47275),
				Vector2(0.57825, 0.47), Vector2(0.5535, 0.5305),
				Vector2(0.5975, 0.525), Vector2(0.57, 0.4095),
				Vector2(0.57, 0.5085)],
			"edges": [Vector2i(0, 2), Vector2i(1, 4), Vector2i(2, 3),
				Vector2i(3, 4), Vector2i(2, 5), Vector2i(4, 6),
				Vector2i(0, 7), Vector2i(1, 7), Vector2i(3, 8)],
		},
	]
	var line_color := Color(0.24, 0.42, 0.82)
	for pattern in patterns:
		var points: Array = pattern.points
		var edges: Array = pattern.edges
		for edge in edges:
			var a := _atlas_point(points[int(edge.x)])
			var b := _atlas_point(points[int(edge.y)])
			_draw_line(image, a, b, line_color,
				CONSTELLATION_LINE_STRENGTH * 0.18)
			_constellation_segment_count += 1
		for point in points:
			_stamp_star(image, _atlas_point(point), 1,
				Color(0.78, 0.88, 1.0), 0.92)


func _add_planets(image: Image) -> void:
	var planets: Array[Dictionary] = [
		{"uv": Vector2(0.62, 0.31), "radius": 2,
			"color": Color(1.0, 0.83, 0.56)},
		{"uv": Vector2(0.85, 0.56), "radius": 2,
			"color": Color(1.0, 0.35, 0.15)},
		{"uv": Vector2(0.35, 0.42), "radius": 2,
			"color": Color(0.75, 0.88, 1.0)},
		{"uv": Vector2(0.93, 0.28), "radius": 2,
			"color": Color(0.94, 0.72, 0.42)},
	]
	for planet in planets:
		_stamp_star(image, _atlas_point(planet.uv), int(planet.radius),
			planet.color, 1.0)


func _atlas_point(uv: Vector2) -> Vector2i:
	return Vector2i(
		clampi(roundi(uv.x * float(ATLAS_WIDTH - 1)), 0, ATLAS_WIDTH - 1),
		clampi(roundi(uv.y * float(ATLAS_HEIGHT - 1)), 0, ATLAS_HEIGHT - 1))


func _draw_line(image: Image, start: Vector2i, finish: Vector2i,
		color: Color, strength: float) -> void:
	var a := Vector2(start)
	var b := Vector2(finish)
	var segment := b - a
	var length_squared := segment.length_squared()
	if length_squared <= 0.001:
		_blend_pixel(image, start.x, start.y, color, strength)
		return
	var min_x := maxi(0, floori(minf(a.x, b.x)) - 1)
	var max_x := mini(ATLAS_WIDTH - 1, ceili(maxf(a.x, b.x)) + 1)
	var min_y := maxi(0, floori(minf(a.y, b.y)) - 1)
	var max_y := mini(ATLAS_HEIGHT - 1, ceili(maxf(a.y, b.y)) + 1)
	for py in range(min_y, max_y + 1):
		for px in range(min_x, max_x + 1):
			var sample := Vector2(float(px) + 0.5, float(py) + 0.5)
			var t := clampf((sample - a).dot(segment) / length_squared,
				0.0, 1.0)
			var distance := sample.distance_to(a + segment * t)
			var coverage := 1.0 - smoothstep(0.35, 1.25, distance)
			if coverage > 0.001:
				_blend_pixel(image, px, py, color, strength * coverage)


func _stamp_star(image: Image, center: Vector2i, radius: int,
		color: Color, strength: float) -> void:
	if radius == 0:
		_blend_pixel(image, center.x, center.y, color, strength)
		return
	var spread := radius
	for oy in range(-spread, spread + 1):
		for ox in range(-spread, spread + 1):
			var distance := Vector2(float(ox), float(oy)).length()
			var falloff := 1.0 - smoothstep(0.10,
				float(radius) + 0.35, distance)
			if falloff > 0.001:
				_blend_pixel(image, center.x + ox, center.y + oy,
					color, strength * falloff)


func _blend_pixel(image: Image, x: int, y: int, color: Color,
		strength: float) -> void:
	var wrapped_x := posmod(x, ATLAS_WIDTH)
	if y < 0 or y >= ATLAS_HEIGHT:
		return
	var previous := image.get_pixel(wrapped_x, y)
	var amount := clampf(strength, 0.0, 1.0)
	var combined := Color(
		minf(previous.r + color.r * amount, 1.0),
		minf(previous.g + color.g * amount, 1.0),
		minf(previous.b + color.b * amount, 1.0),
		maxf(previous.a, amount))
	image.set_pixel(wrapped_x, y, combined)
