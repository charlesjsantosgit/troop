class_name SpaceVoyageVisuals
extends Node3D
## Bounded one-scene voyage backdrop: a single star MultiMesh, one line mesh
## for recognizable constellations, and a handful of shared primitive planets.
## The rocket drives normalized progress; no object is streamed during flight.

const STAR_COUNT := 480
const PLANET_COLORS := [
	Color(0.80, 0.47, 0.25), Color(0.78, 0.69, 0.47),
	Color(0.38, 0.62, 0.82), Color(0.52, 0.40, 0.69),
]

static var _star_mesh: BoxMesh
static var _space_shell_mesh: SphereMesh
static var _star_material: StandardMaterial3D
static var _space_material: StandardMaterial3D
static var _earth_material: StandardMaterial3D
static var _moon_material: StandardMaterial3D
static var _sun_material: StandardMaterial3D
static var _nebula_texture: ImageTexture
static var _galaxy_texture: ImageTexture
static var _galaxy_material: StandardMaterial3D

var earth_visual: MeshInstance3D
var moon_visual: MeshInstance3D
var sun_visual: MeshInstance3D
var star_field: MultiMeshInstance3D
var constellation_lines: MeshInstance3D
var galaxy_visual: MeshInstance3D
var nebulae: Array[MeshInstance3D] = []
var planets: Array[MeshInstance3D] = []
var cabin_key_light: OmniLight3D
var cabin_rim_light: OmniLight3D
var celestial_fill_light: DirectionalLight3D
var outbound_progress := 0.0
var current_phase := 0


func _ready() -> void:
	if get_child_count() == 0:
		_build_backdrop()
	visible = false


func begin_voyage(outbound: bool) -> void:
	visible = true
	update_voyage(0.0, 0, outbound)


func end_voyage() -> void:
	visible = false


func update_voyage(progress: float, phase: int, outbound: bool) -> void:
	outbound_progress = clampf(progress, 0.0, 1.0)
	current_phase = phase
	if not earth_visual:
		return
	# Stars emerge while the atmosphere thins, remain present through vacuum,
	# then disappear behind reentry plasma. Expensive celestial detail is not
	# drawn while the capsule is still beside the launch tower or under clouds.
	var show_stars := outbound_progress >= (24.0 / 180.0) \
		if outbound else outbound_progress < (108.0 / 120.0)
	star_field.visible = show_stars
	constellation_lines.visible = show_stars
	sun_visual.visible = show_stars
	galaxy_visual.visible = show_stars
	for cloud in nebulae:
		cloud.visible = show_stars
	for planet in planets:
		planet.visible = show_stars
	if outbound:
		var earth_scale := lerpf(5.2, 0.32, smoothstep(0.0, 0.86,
			outbound_progress))
		earth_visual.scale = Vector3.ONE * earth_scale
		earth_visual.position = Vector3(-14.0, -8.0,
			lerpf(-34.0, -142.0, outbound_progress))
		var moon_scale := lerpf(0.28, 4.3,
			smoothstep(0.55, 1.0, outbound_progress))
		moon_visual.scale = Vector3.ONE * moon_scale
		moon_visual.position = Vector3(lerpf(48.0, 7.0, outbound_progress),
			lerpf(24.0, 2.0, outbound_progress),
			lerpf(-175.0, -30.0, outbound_progress))
	else:
		var earth_scale := lerpf(0.35, 5.8,
			smoothstep(0.35, 1.0, outbound_progress))
		earth_visual.scale = Vector3.ONE * earth_scale
		earth_visual.position = Vector3(lerpf(-42.0, -8.0, outbound_progress),
			lerpf(18.0, -7.0, outbound_progress),
			lerpf(-168.0, -36.0, outbound_progress))
		var moon_scale := lerpf(4.0, 0.25, outbound_progress)
		moon_visual.scale = Vector3.ONE * moon_scale
		moon_visual.position = Vector3(lerpf(8.0, 48.0, outbound_progress),
			lerpf(2.0, 22.0, outbound_progress),
			lerpf(-32.0, -178.0, outbound_progress))
	# Slow celestial drift gives a legible sense of travel without simulating
	# hundreds of independent bodies or creating motion-sickness spin.
	star_field.rotation.y = outbound_progress * 0.20
	constellation_lines.rotation.y = star_field.rotation.y
	for index in range(planets.size()):
		planets[index].rotation.y = outbound_progress * (0.35 + index * 0.07)


func backdrop_counts() -> Dictionary:
	return {"stars": STAR_COUNT, "planets": planets.size(),
		"nebulae": nebulae.size(), "galaxies": 1 if galaxy_visual else 0,
		"constellation_segments": 15}


func earth_scale() -> float:
	return earth_visual.scale.x if earth_visual else 0.0


func moon_scale() -> float:
	return moon_visual.scale.x if moon_visual else 0.0


static func shared_earth_texture() -> Texture2D:
	_ensure_shared_resources()
	return _earth_material.albedo_texture


static func shared_galaxy_texture() -> Texture2D:
	_ensure_shared_resources()
	return _galaxy_texture


func _build_backdrop() -> void:
	_ensure_shared_resources()
	# The voyage happens inside a fog-free inward-facing shell. It hides the
	# terrestrial atmosphere without swapping the world's shared Environment,
	# and is a single cached material/primitive rather than a per-frame effect.
	var shell := MeshInstance3D.new()
	shell.name = "AirlessSpaceBackdrop"
	shell.mesh = _space_shell_mesh
	shell.material_override = _space_material
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shell)

	# Two small shadowless practical lights travel with the capsule. They keep
	# white hull panels, blue windows, and the warm mission stripe readable while
	# preserving a dark side and a convincing cool space rim.
	cabin_key_light = OmniLight3D.new()
	cabin_key_light.name = "RocketKeyLight"
	cabin_key_light.position = Vector3(6.5, 3.5, 10.5)
	cabin_key_light.light_color = Color(0.78, 0.88, 1.0)
	cabin_key_light.light_energy = 5.8
	cabin_key_light.omni_range = 28.0
	cabin_key_light.omni_attenuation = 1.15
	cabin_key_light.shadow_enabled = false
	add_child(cabin_key_light)
	cabin_rim_light = OmniLight3D.new()
	cabin_rim_light.name = "RocketWarmRimLight"
	cabin_rim_light.position = Vector3(-7.0, -1.0, -9.0)
	cabin_rim_light.light_color = Color(1.0, 0.38, 0.12)
	cabin_rim_light.light_energy = 2.7
	cabin_rim_light.omni_range = 24.0
	cabin_rim_light.omni_attenuation = 1.35
	cabin_rim_light.shadow_enabled = false
	add_child(cabin_rim_light)
	celestial_fill_light = DirectionalLight3D.new()
	celestial_fill_light.name = "CelestialFillLight"
	celestial_fill_light.light_color = Color(0.72, 0.82, 1.0)
	celestial_fill_light.light_energy = 1.15
	celestial_fill_light.rotation_degrees = Vector3(-32.0, -38.0, 0.0)
	celestial_fill_light.shadow_enabled = false
	celestial_fill_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	add_child(celestial_fill_light)

	star_field = MultiMeshInstance3D.new()
	star_field.name = "BoundedStarField"
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = _star_mesh
	multimesh.instance_count = STAR_COUNT
	for index in range(STAR_COUNT):
		var direction := _fibonacci_direction(index, STAR_COUNT)
		var radius := 95.0 + float(_hash_u32(index * 7919 + 41) & 0xffff) \
			/ 65535.0 * 85.0
		var scale_value := 0.7 + float(_hash_u32(index * 3571 + 97) & 0xff) \
			/ 255.0 * 1.8
		multimesh.set_instance_transform(index, Transform3D(
			Basis.IDENTITY.scaled(Vector3.ONE * scale_value), direction * radius))
		var warmth := float(_hash_u32(index * 1877 + 211) & 0xff) / 255.0
		multimesh.set_instance_color(index,
			Color(lerpf(0.66, 1.0, warmth), lerpf(0.78, 0.94, warmth), 1.0))
	star_field.multimesh = multimesh
	star_field.material_override = _star_material
	star_field.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(star_field)

	constellation_lines = MeshInstance3D.new()
	constellation_lines.name = "ConstellationLines"
	constellation_lines.mesh = _constellation_mesh()
	constellation_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(constellation_lines)

	# One distant billboard makes the requested galaxy legible without introducing
	# a second particle field. Its deterministic texture and material are cached
	# once for every rocket; the voyage update only toggles visibility.
	var galaxy_quad := QuadMesh.new()
	galaxy_quad.size = Vector2(58.0, 34.0)
	galaxy_visual = MeshInstance3D.new()
	galaxy_visual.name = "DistantSpiralGalaxy"
	galaxy_visual.mesh = galaxy_quad
	galaxy_visual.material_override = _galaxy_material
	galaxy_visual.position = Vector3(58.0, -32.0, -164.0)
	galaxy_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(galaxy_visual)

	earth_visual = _add_sphere("RecedingEarth", 1.0, _earth_material)
	moon_visual = _add_sphere("ApproachingMoon", 1.0, _moon_material)
	sun_visual = _add_sphere("DistantSun", 3.2, _sun_material)
	sun_visual.position = Vector3(92.0, 58.0, -155.0)
	for index in range(PLANET_COLORS.size()):
		var material := StandardMaterial3D.new()
		material.albedo_color = PLANET_COLORS[index]
		material.metallic = 0.12
		material.roughness = 0.68
		material.emission_enabled = true
		material.emission = PLANET_COLORS[index]
		material.emission_energy_multiplier = 0.24
		material.disable_fog = true
		var planet := _add_sphere("DistantPlanet%d" % index,
			1.0 + index * 0.22, material)
		planet.position = Vector3(-78.0 + index * 45.0,
			42.0 - index * 18.0, -132.0 - index * 14.0)
		planets.append(planet)
	_build_nebulae()


func _build_nebulae() -> void:
	var colors := [Color(0.42, 0.18, 0.72, 0.16),
		Color(0.12, 0.48, 0.72, 0.13), Color(0.72, 0.18, 0.42, 0.11)]
	for index in range(colors.size()):
		var quad := QuadMesh.new()
		quad.size = Vector2(38.0 + index * 9.0, 21.0 + index * 5.0)
		var material := StandardMaterial3D.new()
		material.albedo_color = colors[index]
		material.albedo_texture = _nebula_texture
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		material.no_depth_test = false
		material.disable_fog = true
		var cloud := MeshInstance3D.new()
		cloud.name = "DistantNebula%d" % index
		cloud.mesh = quad
		cloud.material_override = material
		cloud.position = Vector3(-76.0 + index * 74.0,
			-30.0 + index * 34.0, -158.0 - index * 8.0)
		cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(cloud)
		nebulae.append(cloud)


func _add_sphere(part_name: String, radius: float,
		material: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 20
	mesh.rings = 12
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance


static func _fibonacci_direction(index: int, count: int) -> Vector3:
	var y := 1.0 - (float(index) + 0.5) * 2.0 / float(count)
	var radius := sqrt(maxf(0.0, 1.0 - y * y))
	var theta := float(index) * 2.399963229728653
	return Vector3(cos(theta) * radius, y, sin(theta) * radius)


static func _constellation_mesh() -> ImmediateMesh:
	var points := [
		Vector3(-70, 45, -120), Vector3(-58, 52, -125),
		Vector3(-44, 47, -132), Vector3(-31, 54, -137),
		Vector3(-19, 48, -143), Vector3(-9, 61, -148),
		Vector3(5, 55, -151), Vector3(20, 65, -146),
		Vector3(34, 58, -140), Vector3(48, 68, -132),
	]
	var connections := [0, 1, 1, 2, 2, 3, 3, 4, 4, 5,
		5, 6, 6, 7, 7, 8, 8, 9, 1, 5, 2, 6, 3, 7, 4, 8, 0, 4, 5, 9]
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.44, 0.66, 1.0, 0.27)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.disable_fog = true
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for point_index in connections:
		mesh.surface_add_vertex(points[point_index])
	mesh.surface_end()
	return mesh


static func _hash_u32(value: int) -> int:
	var x := value & 0xffffffff
	x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xffffffff
	x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xffffffff
	return (x ^ (x >> 16)) & 0xffffffff


static func _ensure_shared_resources() -> void:
	if _star_mesh and _galaxy_material:
		return
	_star_mesh = BoxMesh.new()
	_star_mesh.size = Vector3(0.14, 0.14, 0.14)
	_space_shell_mesh = SphereMesh.new()
	_space_shell_mesh.radius = 205.0
	_space_shell_mesh.height = 410.0
	_space_shell_mesh.radial_segments = 40
	_space_shell_mesh.rings = 20
	_star_material = StandardMaterial3D.new()
	_star_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_star_material.vertex_color_use_as_albedo = true
	_star_material.albedo_color = Color.WHITE
	_star_material.emission_enabled = true
	_star_material.emission = Color(0.78, 0.86, 1.0)
	_star_material.emission_energy_multiplier = 2.4
	_star_material.disable_fog = true
	_space_material = StandardMaterial3D.new()
	_space_material.albedo_color = Color(0.00035, 0.00055, 0.0015)
	_space_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_space_material.cull_mode = BaseMaterial3D.CULL_FRONT
	_space_material.disable_receive_shadows = true
	_space_material.disable_fog = true
	_earth_material = StandardMaterial3D.new()
	_earth_material.albedo_color = Color.WHITE
	var earth_texture := _procedural_earth_texture()
	_earth_material.albedo_texture = earth_texture
	_earth_material.metallic = 0.0
	_earth_material.roughness = 0.76
	_earth_material.emission_enabled = true
	_earth_material.emission = Color.WHITE
	_earth_material.emission_texture = earth_texture
	_earth_material.emission_energy_multiplier = 0.20
	_earth_material.disable_fog = true
	_moon_material = StandardMaterial3D.new()
	_moon_material.albedo_color = Color(0.54, 0.55, 0.57)
	_moon_material.roughness = 0.95
	_moon_material.emission_enabled = true
	_moon_material.emission = Color(0.17, 0.18, 0.20)
	_moon_material.emission_energy_multiplier = 0.26
	_moon_material.disable_fog = true
	_sun_material = StandardMaterial3D.new()
	_sun_material.albedo_color = Color(1.0, 0.72, 0.22)
	_sun_material.emission_enabled = true
	_sun_material.emission = Color(1.0, 0.55, 0.12)
	_sun_material.emission_energy_multiplier = 4.0
	_sun_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_sun_material.disable_fog = true
	_nebula_texture = _procedural_nebula_texture()
	_galaxy_texture = _procedural_spiral_galaxy_texture()
	_galaxy_material = StandardMaterial3D.new()
	_galaxy_material.albedo_color = Color.WHITE
	_galaxy_material.albedo_texture = _galaxy_texture
	_galaxy_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_galaxy_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_galaxy_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_galaxy_material.disable_receive_shadows = true
	_galaxy_material.disable_fog = true


static func _procedural_earth_texture() -> ImageTexture:
	# A low-cost deterministic equirectangular Earth: several differently
	# oriented waves make continent-scale masses, with deserts, vegetation,
	# polar ice, and thin cloud streaks visible as the planet recedes.
	const WIDTH := 256
	const HEIGHT := 128
	var image := Image.create(WIDTH, HEIGHT, false, Image.FORMAT_RGBA8)
	for y in range(HEIGHT):
		var v := (float(y) + 0.5) / float(HEIGHT)
		var latitude := (0.5 - v) * PI
		for x in range(WIDTH):
			var u := (float(x) + 0.5) / float(WIDTH)
			var longitude := (u - 0.5) * TAU
			var continental := sin(longitude * 1.4 + sin(latitude * 2.7))
			continental += sin(longitude * 2.8 - latitude * 1.9) * 0.48
			continental += cos(longitude * 5.2 + latitude * 3.6) * 0.24
			continental += sin(longitude * 9.1 - latitude * 6.4) * 0.10
			continental -= absf(latitude) * 0.20
			var color: Color
			if continental > 0.37:
				var aridity := absf(sin(longitude * 2.1 + latitude * 4.0))
				color = Color(0.55, 0.43, 0.20).lerp(
					Color(0.12, 0.42, 0.20), aridity)
				if continental > 1.0:
					color = color.lerp(Color(0.38, 0.31, 0.25), 0.55)
			else:
				var ocean_depth := clampf((0.37 - continental) * 0.42, 0.0, 0.34)
				color = Color(0.035, 0.22, 0.51).darkened(ocean_depth)
			var polar := smoothstep(1.08, 1.47, absf(latitude))
			color = color.lerp(Color(0.88, 0.94, 0.98), polar)
			var clouds := sin(longitude * 7.2 + latitude * 3.1) \
				+ sin(longitude * 13.0 - latitude * 8.0) * 0.42
			if clouds > 1.05:
				color = color.lerp(Color(0.92, 0.96, 1.0),
					clampf((clouds - 1.05) * 0.48, 0.0, 0.32))
			image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)


static func _procedural_nebula_texture() -> ImageTexture:
	const WIDTH := 64
	const HEIGHT := 40
	var image := Image.create(WIDTH, HEIGHT, false, Image.FORMAT_RGBA8)
	for y in range(HEIGHT):
		for x in range(WIDTH):
			var uv := Vector2((float(x) + 0.5) / float(WIDTH),
				(float(y) + 0.5) / float(HEIGHT)) * 2.0 - Vector2.ONE
			var radial := maxf(1.0 - uv.length(), 0.0)
			var filaments := 0.72 + sin(uv.x * 13.0 + uv.y * 8.0) * 0.16 \
				+ cos(uv.x * 21.0 - uv.y * 14.0) * 0.10
			var alpha := pow(radial, 2.4) * clampf(filaments, 0.0, 1.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	return ImageTexture.create_from_image(image)


static func _procedural_spiral_galaxy_texture() -> ImageTexture:
	# A compact two-armed spiral with a warm stellar core and cool outer disc.
	# The texture is generated once during shared-resource setup, never per frame.
	const WIDTH := 128
	const HEIGHT := 80
	var image := Image.create(WIDTH, HEIGHT, false, Image.FORMAT_RGBA8)
	for y in range(HEIGHT):
		for x in range(WIDTH):
			var uv := Vector2((float(x) + 0.5) / float(WIDTH),
				(float(y) + 0.5) / float(HEIGHT)) * 2.0 - Vector2.ONE
			var disc_point := Vector2(uv.x, uv.y * 1.72)
			var radius := disc_point.length()
			if radius >= 1.0:
				image.set_pixel(x, y, Color.TRANSPARENT)
				continue
			var angle := atan2(disc_point.y, disc_point.x)
			var arm_wave := maxf(cos(angle * 2.0 - radius * 14.5), 0.0)
			var arms := pow(arm_wave, 5.0) * pow(1.0 - radius, 0.72)
			var core := exp(-radius * radius * 27.0)
			var disc := pow(1.0 - radius, 2.15)
			var dust := 0.72 + sin(uv.x * 38.0 + uv.y * 23.0) * 0.13 \
				+ cos(uv.x * 67.0 - uv.y * 41.0) * 0.08
			var alpha := clampf(core * 1.12 + arms * 0.88 + disc * dust * 0.18,
				0.0, 1.0)
			alpha *= 1.0 - smoothstep(0.72, 1.0, radius)
			var outer_color := Color(0.40, 0.52, 1.0)
			var arm_color := outer_color.lerp(Color(0.76, 0.61, 1.0), arms)
			var color := arm_color.lerp(Color(1.0, 0.82, 0.51),
				clampf(core * 1.7, 0.0, 1.0))
			image.set_pixel(x, y, Color(color.r, color.g, color.b, alpha))
	return ImageTexture.create_from_image(image)
