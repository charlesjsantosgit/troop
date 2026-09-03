class_name SpaceVoyageVisuals
extends Node3D
## Bounded one-scene voyage backdrop: a single star MultiMesh, one line mesh
## for recognizable constellations, and a handful of shared primitive planets.
## The rocket drives normalized progress; no object is streamed during flight.

const STAR_COUNT := 480
const CELESTIAL_RADIAL_SEGMENTS := 256
const CELESTIAL_RINGS := 128
# The cinematic's physical contract is deliberately independent from Godot's
# local metre-sized gameplay chart. A floating scaled-space transform maps this
# 24,000 km globe close to the camera while preserving its radius, altitude and
# angular-size relationships. That avoids multi-million-unit float jitter.
const EARTH_AUTHORED_DIAMETER_KM := 24_000.0
const EARTH_AUTHORED_RADIUS_KM := EARTH_AUTHORED_DIAMETER_KM * 0.5
const MOON_AUTHORED_DIAMETER_KM := 3_474.8
const MOON_AUTHORED_RADIUS_KM := MOON_AUTHORED_DIAMETER_KM * 0.5
const EARTH_LOCAL_RADIUS_UNITS := EARTH_AUTHORED_RADIUS_KM * 1000.0
const MOON_LOCAL_RADIUS_UNITS := MoonWorld.PLAYABLE_RADIUS_METERS
const EARTH_ATMOSPHERE_HEIGHT_KM := 100.0
const EARTH_ATMOSPHERE_SCALE_HEIGHT_KM := 8.5
const EARTH_ATMOSPHERE_SCALE := \
	(EARTH_AUTHORED_RADIUS_KM + EARTH_ATMOSPHERE_HEIGHT_KM) \
	/ EARTH_AUTHORED_RADIUS_KM
# Begin scaled-space compression high in the atmosphere, while the curved
# streamed cap still occupies the same lower-frame silhouette. Waiting until
# the 14 s atmosphere boundary left a quarter-second frame with neither tangent
# inside the camera frustum, making the Earth appear to pop out of black space.
const EARTH_GLOBE_BLEND_START_SECONDS := 10.0
const EARTH_GLOBE_FULL_SECONDS := 18.0
# Kept as a public presentation boundary for older diagnostics. Geometry is no
# longer hidden here: cached terrain and the globe remain one opaque surface.
const EARTH_SURFACE_HIDE_SECONDS := EARTH_GLOBE_FULL_SECONDS
const TRANSFER_PAN_START_SECONDS := 28.0
const MOON_GLOBE_DOMINANT_SECONDS := 42.0
const LUNAR_MAP_REVEAL_SECONDS := 48.0
const LUNAR_REAL_SURFACE_SECONDS := 50.0
const LUNAR_DESCENT_SECONDS := 10.0
const LUNAR_FLIP_START_SECONDS := 46.0
const LUNAR_LOCAL_GEOMETRY_REVEAL_SECONDS := 48.0
const EARTH_MAP_RADIUS := 35.0
const MOON_MAP_RADIUS_START := 8.0
const MOON_MAP_RADIUS_DOMINANT := 25.0
const MOON_PROXY_RELIEF_CLEARANCE := 26.0
const MOON_PROXY_PHYSICAL_RADIUS_UNITS := MOON_LOCAL_RADIUS_UNITS \
	- MOON_PROXY_RELIEF_CLEARANCE
const EARTH_LAUNCH_ATLAS_LONGITUDE := 0.88
const CELESTIAL_FILL_ENERGY := 1.15
const EARTH_TERRAIN_CAP_RADIUS := 30_000.0
const RETURN_EARTH_GROW_START_SECONDS := 24.0
const RETURN_EARTH_ANCHOR_START_SECONDS := 30.0
const RETURN_EARTH_PHYSICAL_SECONDS := 38.0
const RETURN_TERRAIN_REVEAL_START_SECONDS := 28.0
const RETURN_TERRAIN_REVEAL_END_SECONDS := 36.0
const RETURN_TERRAIN_HANDOFF_SECONDS := 40.0
const LUNAR_ROCKET_SCRIPT_PATH := "res://scripts/lunar_rocket.gd"
const EARTH_ATLAS: Texture2D = preload(
	"res://assets/textures/pangaea_earth_4k.jpg")
const MOON_ATLAS: Texture2D = preload(
	"res://assets/textures/lunar_surface_4k.jpg")
const PLANET_MICRODETAIL: Texture2D = preload(
	"res://assets/textures/satellite_microdetail_overlay.png")

# One planet draw supplies both orbital-scale geography and close-atmosphere
# structure. At the exact 24,000 km authored diameter, a 4K atlas texel spans
# kilometres; the repeated mipmapped field restores bounded sub-atlas detail
# without geometry, decals, runtime texture uploads, or another draw call.
const EARTH_PLANET_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back;

uniform sampler2D planet_atlas : source_color,
	filter_linear_mipmap_anisotropic;
uniform sampler2D microdetail : source_color, repeat_enable,
	filter_linear_mipmap_anisotropic;
instance uniform float atlas_longitude_offset = 0.88;
varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	// Place the authored launch tangent over the supercontinent instead of the
	// empty-ocean seam. Deriving this from the world normal also matches the
	// retained terrain-cap projection and keeps the mesh's UV pole off camera.
	vec3 atlas_direction = vec3(world_normal.x, world_normal.z,
		-world_normal.y);
	vec2 atlas_uv = vec2(fract(atlas_longitude_offset + atan(atlas_direction.z,
		atlas_direction.x) / 6.28318530718),
		acos(clamp(atlas_direction.y, -1.0, 1.0)) / 3.14159265359);
	vec3 atlas = texture(planet_atlas, atlas_uv).rgb;
	// 2048x1024 repeats make the detail footprint nearly square on a sphere:
	// about 36.8 km per tile in either direction at the authored equator.
	float micro_macro = texture(microdetail,
		atlas_uv * vec2(2048.0, 1024.0)).r;
	float micro_fine = texture(microdetail,
		atlas_uv * vec2(8192.0, 4096.0) + vec2(0.37, 0.19)).r;
	float micro = micro_macro * 0.58 + micro_fine * 0.42;
	float ocean = smoothstep(0.025, 0.18,
		atlas.b - max(atlas.r, atlas.g) * 0.72);
	float land_contrast = mix(0.72, 1.28, micro);
	float ocean_contrast = mix(0.91, 1.07, micro);
	float detail_contrast = mix(land_contrast, ocean_contrast, ocean);
	vec3 sun_direction = normalize(vec3(-0.34, 0.76, 0.55));
	float daylight = mix(0.60, 1.08, smoothstep(-0.24, 0.62,
		dot(world_normal, sun_direction)));
	vec3 view_direction = normalize(CAMERA_POSITION_WORLD - world_position);
	float limb = pow(1.0 - max(dot(world_normal, view_direction), 0.0), 4.0);
	vec3 color = atlas * detail_contrast * daylight;
	color += vec3(0.045, 0.16, 0.34) * limb * 0.42;
	ALBEDO = color;
}
"""
const MOON_PLANET_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, fog_disabled;

uniform sampler2D planet_atlas : source_color,
	filter_linear_mipmap_anisotropic;

void fragment() {
	// A stable 512x256 atlas level is already denser than a map-view Moon at
	// 1600x900. Using the same level on the compressed polar cap prevents their
	// depth handoff from exposing a sharp circular mip boundary.
	ALBEDO = textureLod(planet_atlas, UV, 3.0).rgb;
}
"""
const PLANET_COLORS := [
	Color(0.80, 0.47, 0.25), Color(0.78, 0.69, 0.47),
	Color(0.38, 0.62, 0.82), Color(0.52, 0.40, 0.69),
]

static var _star_mesh: BoxMesh
static var _space_shell_mesh: SphereMesh
static var _star_material: StandardMaterial3D
static var _space_material: StandardMaterial3D
static var _earth_material: ShaderMaterial
static var _earth_atmosphere_material: StandardMaterial3D
static var _moon_material: ShaderMaterial
static var _sun_material: StandardMaterial3D
static var _nebula_texture: ImageTexture
static var _galaxy_texture: ImageTexture
static var _galaxy_material: StandardMaterial3D
static var _rocket_timing: Dictionary = {}

var earth_visual: MeshInstance3D
var earth_atmosphere_visual: MeshInstance3D
var moon_visual: MeshInstance3D
var sun_visual: MeshInstance3D
var star_field: MultiMeshInstance3D
var constellation_lines: MeshInstance3D
var galaxy_visual: MeshInstance3D
var space_shell: MeshInstance3D
var vacuum_backstop: MeshInstance3D
var nebulae: Array[MeshInstance3D] = []
var planets: Array[MeshInstance3D] = []
var cabin_key_light: OmniLight3D
var cabin_rim_light: OmniLight3D
var celestial_fill_light: DirectionalLight3D
var return_terrain_surface_anchor := Vector3.ZERO
var return_terrain_render_radius := EARTH_LOCAL_RADIUS_UNITS
var outbound_progress := 0.0
var current_phase := 0
var earth_surface_weight := 1.0
var earth_globe_weight := 0.0
var atmosphere_density := 1.0
var earth_physical_altitude_km := 0.0
var earth_render_units_per_km := 0.0
var earth_render_radius := EARTH_LOCAL_RADIUS_UNITS
var earth_surface_anchor := Vector3.ZERO
var moon_globe_weight := 0.0
var moon_surface_weight := 0.0
var moon_render_units_per_km := 0.0
var moon_render_radius := MOON_AUTHORED_RADIUS_KM
var moon_surface_anchor := Vector3.ZERO
var local_viewer_enabled := true
var cinematic_terrain_enabled := false
var _voyage_active := false
var _terrain_curvature_applied := false
enum SetupPhase { NOT_STARTED, RESOURCES, SHELLS, LIGHTS, STARS,
	CONSTELLATIONS, GALAXY, EARTH, ATMOSPHERE, MOON, SUN, PLANETS, NEBULAE,
	COMPLETE }
var _setup_phase := SetupPhase.NOT_STARTED


func _ready() -> void:
	if get_child_count() == 0 and _setup_phase == SetupPhase.NOT_STARTED:
		_build_backdrop()
	# Keep the bounded diorama centred on the craft without inheriting its roll.
	# The old child-space planets spun whenever the rocket pitched toward the Moon.
	top_level = true
	# The complete diorama is sampled with the render-driven hull. A second
	# physics interpolation pass would make the planets lag behind the camera.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_anchor_to_rocket()
	visible = false


func begin_setup() -> void:
	if _setup_phase == SetupPhase.NOT_STARTED:
		_setup_phase = SetupPhase.RESOURCES


func is_setup_complete() -> bool:
	return _setup_phase == SetupPhase.COMPLETE


func setup_phase_name() -> String:
	return String(SetupPhase.keys()[_setup_phase]).to_lower()


func build_setup_step(_budget_usec: int = 2000) -> bool:
	if is_queued_for_deletion():
		return false
	if _setup_phase == SetupPhase.NOT_STARTED:
		begin_setup()
	# Each first-use mesh/texture upload gets its own frame during online entry;
	# the same complete authored backdrop remains available before boarding.
	match _setup_phase:
		SetupPhase.RESOURCES:
			_ensure_shared_resources()
		SetupPhase.SHELLS:
			_build_shells()
		SetupPhase.LIGHTS:
			_build_lights()
		SetupPhase.STARS:
			_build_stars()
		SetupPhase.CONSTELLATIONS:
			_build_constellations()
		SetupPhase.GALAXY:
			_build_galaxy()
		SetupPhase.EARTH:
			earth_visual = _add_sphere("RecedingEarth", 1.0, _earth_material, true)
			# Keep the launch tangent away from the atlas's bright polar seam.
			earth_visual.rotation_degrees = Vector3(90.0, 0.0, 0.0)
		SetupPhase.ATMOSPHERE:
			earth_atmosphere_visual = _add_sphere("EarthAtmosphereLimb", 1.0,
				_earth_atmosphere_material, true)
			earth_atmosphere_visual.rotation = earth_visual.rotation
		SetupPhase.MOON:
			moon_visual = _add_sphere("ApproachingMoon", 1.0, _moon_material, true)
			# Keep the close landing tangent away from the sphere's UV pole fan.
			moon_visual.rotation_degrees = Vector3(90.0, 0.0, 0.0)
		SetupPhase.SUN:
			sun_visual = _add_sphere("DistantSun", 3.2, _sun_material)
			sun_visual.position = Vector3(360.0, 230.0, -610.0)
		SetupPhase.PLANETS:
			_build_planets()
		SetupPhase.NEBULAE:
			_build_nebulae()
		SetupPhase.COMPLETE:
			return true
	_setup_phase = (_setup_phase + 1) as SetupPhase
	return is_setup_complete()


func begin_voyage(outbound: bool) -> void:
	reset_route_anchors()
	update_voyage(0.0, 0, outbound)


func reset_route_anchors() -> void:
	return_terrain_surface_anchor = Vector3.ZERO
	return_terrain_render_radius = EARTH_LOCAL_RADIUS_UNITS


func end_voyage(_legacy_keep_water := false) -> void:
	_voyage_active = false
	visible = false
	set_cinematic_terrain_enabled(false)


func set_local_viewer_enabled(enabled: bool) -> void:
	local_viewer_enabled = enabled
	visible = local_viewer_enabled and _voyage_active
	if not local_viewer_enabled:
		set_cinematic_terrain_enabled(false)


func _exit_tree() -> void:
	# Shared materials must never retain a cinematic curve if a mission/session is
	# torn down before the normal landing callback.
	if _terrain_curvature_applied:
		Visuals.clear_cinematic_earth_curvature()
		_terrain_curvature_applied = false


func set_cinematic_terrain_enabled(enabled: bool) -> void:
	enabled = enabled and local_viewer_enabled
	if cinematic_terrain_enabled == enabled:
		return
	cinematic_terrain_enabled = enabled
	if not enabled and _terrain_curvature_applied:
		Visuals.clear_cinematic_earth_curvature()
		_terrain_curvature_applied = false


func update_voyage(progress: float, phase: int, outbound: bool) -> void:
	# Mission replication still advances the remote hull and crew, but only the
	# local passenger may expose this camera-centred sky and global fill light.
	_voyage_active = true
	visible = local_viewer_enabled
	outbound_progress = clampf(progress, 0.0, 1.0)
	current_phase = phase
	if not earth_visual:
		return
	_anchor_to_rocket()
	var timing := _lunar_rocket_timing()
	var duration := float(timing.outbound_duration) if outbound \
		else float(timing.return_duration)
	var elapsed := outbound_progress * duration
	if celestial_fill_light:
		# The Moon supplies its own sunlight. Fade the global voyage fill away
		# before the lit terrain takes over, then restore it as the return leg
		# compresses that terrain into the emissive map. Cabin lights stay local.
		var fill_weight := 1.0 - _quintic_blend(36.0, 44.0, elapsed) \
			if outbound else _quintic_blend(8.0, 16.0, elapsed) \
				* (1.0 - _quintic_blend(24.0, 40.0, elapsed))
		celestial_fill_light.light_energy = CELESTIAL_FILL_ENERGY * fill_weight
	var shell_opacity := 0.0
	var earth_opacity := 1.0
	var moon_opacity := 1.0
	if outbound:
		# Earth is one continuously opaque object from pad to orbit. The detailed
		# tangent terrain naturally depth-occludes it at launch; distance and camera
		# motion reveal the same sphere's limb. No planet cross-dissolve is involved.
		earth_surface_weight = 1.0
		earth_globe_weight = 1.0
		earth_physical_altitude_km = _outbound_physical_altitude_km(elapsed)
		atmosphere_density = _outbound_atmosphere_density(elapsed)
		moon_globe_weight = 1.0
		moon_surface_weight = 1.0 if elapsed \
			>= LUNAR_LOCAL_GEOMETRY_REVEAL_SECONDS else 0.0
		# Only atmospheric extinction changes the sky. The black vacuum shell grows
		# visible continuously as density falls, rather than fading to a new scene.
		shell_opacity = 1.0 - atmosphere_density
	else:
		atmosphere_density = _quintic_blend(24.0, 40.0, elapsed)
		earth_physical_altitude_km = lerpf(120.0, 0.0,
			_quintic_blend(28.0, 40.0, elapsed))
		moon_surface_weight = 1.0
		moon_globe_weight = 1.0
		earth_globe_weight = 1.0
		earth_surface_weight = 1.0
		shell_opacity = 1.0 - atmosphere_density
	_set_proxy_opacity(space_shell, shell_opacity)
	_set_proxy_opacity(earth_visual, earth_opacity)
	# The sky extinction already supplies the atmospheric climb. A second
	# transparent globe intersects the aggressive scaled-space zoom and can sort
	# as a false inner planet, so keep the bounded limb mesh retired for now.
	_set_proxy_opacity(earth_atmosphere_visual, 0.0)
	_set_proxy_opacity(moon_visual, moon_opacity)
	# Once the atmosphere is gone, retain an opaque black backstop until the real
	# Moon vacuum sky takes over. This prevents a translucent shell from revealing
	# the green terrestrial sky during the map-to-Moon pan.
	vacuum_backstop.visible = false
	var celestial_opacity := shell_opacity \
		* star_opacity_for_progress(outbound_progress, outbound)
	_set_proxy_opacity(star_field, celestial_opacity)
	_set_proxy_opacity(constellation_lines, celestial_opacity)
	_set_proxy_opacity(sun_visual, celestial_opacity)
	_set_proxy_opacity(galaxy_visual, celestial_opacity)
	for cloud in nebulae:
		_set_proxy_opacity(cloud, celestial_opacity)
	for planet in planets:
		_set_proxy_opacity(planet, celestial_opacity)
	_update_planet_diorama(elapsed, outbound)
	# Slow celestial drift gives a legible sense of travel without simulating
	# hundreds of independent bodies or creating motion-sickness spin.
	star_field.rotation.y = outbound_progress * 0.20
	constellation_lines.rotation.y = star_field.rotation.y
	for index in range(planets.size()):
		planets[index].rotation.y = outbound_progress * (0.35 + index * 0.07)


func _anchor_to_rocket() -> void:
	var rocket := get_parent() as Node3D
	if rocket:
		global_transform = Transform3D(Basis.IDENTITY, rocket.global_position)


func _set_proxy_opacity(proxy: GeometryInstance3D, opacity: float) -> void:
	if not proxy:
		return
	opacity = clampf(opacity, 0.0, 1.0)
	proxy.transparency = 1.0 - opacity
	# Toggle only after the continuous fade has become visually zero. This avoids
	# a one-frame pop at either 30 or 60 fps while still removing overdraw.
	proxy.visible = opacity > 0.001


func _outbound_atmosphere_density(elapsed: float) -> float:
	var atmosphere_exit := float(_lunar_rocket_timing().outbound_atmosphere_exit)
	if elapsed >= atmosphere_exit:
		return 0.0
	# Exponential pressure falloff uses an 8.5 km scale height. At the authored
	# 100 km atmosphere edge only a numerically negligible trace remains; the
	# phase boundary clamps that trace to exact vacuum.
	return clampf(exp(-earth_physical_altitude_km \
		/ EARTH_ATMOSPHERE_SCALE_HEIGHT_KM), 0.0, 1.0)


func _outbound_physical_altitude_km(elapsed: float) -> float:
	var atmosphere_exit := float(_lunar_rocket_timing().outbound_atmosphere_exit)
	if elapsed <= atmosphere_exit:
		return 120.0 * pow(clampf(elapsed \
			/ maxf(atmosphere_exit, 0.001), 0.0, 1.0), 2.35)
	var timing := _lunar_rocket_timing()
	var cruise_start := float(timing.outbound_cruise_start)
	if elapsed <= cruise_start:
		return lerpf(120.0, 24_000.0,
			smoothstep(atmosphere_exit, cruise_start, elapsed))
	return lerpf(24_000.0, 360_000.0, smoothstep(cruise_start,
		LUNAR_MAP_REVEAL_SECONDS, elapsed))


func _update_planet_diorama(elapsed: float, outbound: bool) -> void:
	var rocket := get_parent() as Node3D
	if not rocket:
		return
	var earth_route: Variant = rocket.get("earth_launch_transform")
	var moon_route: Variant = rocket.get("moon_landing_transform")
	if not earth_route is Transform3D or not moon_route is Transform3D:
		return
	var earth_transform := earth_route as Transform3D
	var moon_transform := moon_route as Transform3D
	var earth_up := earth_transform.basis.y.normalized()
	var moon_up := moon_transform.basis.y.normalized()
	var earth_physical_surface := earth_transform.origin \
		- earth_up * LunarRocket.ORIGIN_ABOVE_LANDING_SURFACE
	var moon_physical_surface := moon_transform.origin \
		- moon_up * LunarRocket.ORIGIN_ABOVE_LANDING_SURFACE
	var route_right := earth_transform.basis.x.normalized()

	# Keep the actual 12,000 km-radius body under the streamed launch terrain
	# through atmosphere exit. Only then does a six-second scaled-space pullback
	# move that same opaque sphere into the readable map composition. The cached
	# local patch retracts by a moving geometric edge while the atlas is exposed;
	# neither planet changes alpha and there is no scene-swap frame.
	var earth_map_blend := smoothstep(EARTH_GLOBE_BLEND_START_SECONDS,
		EARTH_GLOBE_FULL_SECONDS, elapsed) if outbound else 1.0
	# Bring the near tangent into scaled space before the radius crosses the
	# renderer's far range. Its map target stays hundreds of units from the craft,
	# so this early geometric handoff no longer balloons beside the camera.
	# Bring the tangent anchor into the rocket's floating map frame before the
	# radius finishes compressing. A slow 10-17 s linear anchor path left the
	# otherwise opaque sphere beyond the camera's far range for over a second.
	# Keeping the near surface close while its radius shrinks produces one
	# continuous horizon-to-globe silhouette.
	var earth_anchor_blend := smoothstep(EARTH_GLOBE_BLEND_START_SECONDS,
		14.0, elapsed) if outbound else 1.0
	var earth_recede := smoothstep(EARTH_GLOBE_FULL_SECONDS,
		MOON_GLOBE_DOMINANT_SECONDS, elapsed)
	var lunar_sky_handoff := smoothstep(MOON_GLOBE_DOMINANT_SECONDS,
		LUNAR_REAL_SURFACE_SECONDS, elapsed) if outbound else 1.0
	var earth_map_radius := lerpf(
		lerpf(EARTH_MAP_RADIUS, 12.0, earth_recede), 3.0,
		lunar_sky_handoff)
	var earth_map_centre := rocket.global_position \
		- route_right * lerpf(120.0, 112.0,
			maxf(earth_recede, lunar_sky_handoff)) \
		- earth_up * lerpf(160.0, 58.0,
			maxf(earth_recede, lunar_sky_handoff))
	# Once the Moon owns the composition, carry the receding Earth above the
	# landing tangent. Leaving it on the same below-rocket plane as the lunar cap
	# made the small globe read like a green prop sitting on the regolith.
	earth_map_centre += (moon_up * 140.0 + route_right * 70.0) \
		* lunar_sky_handoff
	var earth_map_surface := earth_map_centre + earth_up * earth_map_radius
	earth_render_radius = exp(lerpf(log(EARTH_LOCAL_RADIUS_UNITS),
		log(earth_map_radius), earth_map_blend))
	earth_surface_anchor = earth_physical_surface.lerp(
		earth_map_surface, earth_anchor_blend)
	if not outbound:
		_update_return_earth_anchor(elapsed, rocket, earth_up, moon_up, route_right)
	var earth_centre := earth_surface_anchor - earth_up * earth_render_radius
	earth_render_units_per_km = earth_render_radius / EARTH_AUTHORED_RADIUS_KM
	earth_visual.scale = Vector3.ONE * earth_render_radius
	earth_visual.position = earth_centre - global_position
	# Return to the same continent and actual launch terrain seen at departure.
	# Rotating to open-ocean atlas pixels implied a water landing before replacing
	# that water with the nearby lake and land in a single scene handoff.
	earth_visual.set_instance_shader_parameter("atlas_longitude_offset",
		EARTH_LAUNCH_ATLAS_LONGITUDE)
	earth_atmosphere_visual.scale = Vector3.ONE * earth_render_radius \
		* EARTH_ATMOSPHERE_SCALE
	earth_atmosphere_visual.position = earth_visual.position
	if outbound and cinematic_terrain_enabled \
			and elapsed <= EARTH_GLOBE_FULL_SECONDS:
		var terrain_retraction := smoothstep(EARTH_GLOBE_FULL_SECONDS - 1.0,
			EARTH_GLOBE_FULL_SECONDS, elapsed)
		Visuals.set_cinematic_earth_curvature(
			Vector2(earth_physical_surface.x, earth_physical_surface.z),
			earth_physical_surface.y, EARTH_LOCAL_RADIUS_UNITS, 1.0,
			lerpf(EARTH_TERRAIN_CAP_RADIUS, 0.0, terrain_retraction),
			earth_surface_anchor, earth_render_radius)
		_terrain_curvature_applied = true
	elif not outbound and cinematic_terrain_enabled \
			and elapsed >= RETURN_TERRAIN_REVEAL_START_SECONDS:
		# The same loaded terrain that the player will walk on expands over the
		# opaque atlas. There is no private water mesh or replacement lake scene.
		# Finish the world-space bridge first, then remove only the tiny local
		# curvature over two seconds so the final shader reset cannot move ground.
		Visuals.set_cinematic_earth_curvature(
			Vector2(earth_physical_surface.x, earth_physical_surface.z),
			earth_physical_surface.y, EARTH_LOCAL_RADIUS_UNITS,
			return_earth_terrain_strength(elapsed),
			EARTH_TERRAIN_CAP_RADIUS * return_earth_terrain_reveal(elapsed),
			return_terrain_surface_anchor, return_terrain_render_radius)
		_terrain_curvature_applied = true
	elif _terrain_curvature_applied:
		Visuals.clear_cinematic_earth_curvature()
		_terrain_curvature_applied = false

	# Keep the Moon near the camera while its globe grows. Moving its tangent
	# toward the distant physical landing point before the rocket finished the
	# insertion arc sent the entire Moon below the frame between 44 and 46 s.
	var moon_pan := _quintic_blend(TRANSFER_PAN_START_SECONDS,
		MOON_GLOBE_DOMINANT_SECONDS, elapsed)
	var moon_map_radius := lerpf(MOON_MAP_RADIUS_START,
		MOON_MAP_RADIUS_DOMINANT, moon_pan)
	var moon_map_centre := rocket.global_position \
		+ route_right * lerpf(180.0, 32.0, moon_pan) \
		- moon_up * lerpf(2.0, 40.0, moon_pan)
	var moon_map_surface := moon_map_centre + moon_up * moon_map_radius
	var moon_surface := moon_map_surface
	var moon_proxy_radius := moon_map_radius
	if outbound:
		# Size grows over 42-50 s, but the near tangent travels with the rocket
		# until the 46-50 s flip. Both bridges have zero velocity and acceleration
		# at their endpoints. The real terrain consumes this same radius/anchor.
		var moon_scale_bridge := lunar_arrival_scale_blend(elapsed)
		var moon_anchor_bridge := lunar_arrival_anchor_blend(elapsed)
		moon_proxy_radius = exp(lerpf(log(maxf(moon_map_radius, 0.001)),
			log(MOON_PROXY_PHYSICAL_RADIUS_UNITS), moon_scale_bridge))
		moon_render_radius = moon_proxy_radius
		# The terrain is raised above the backing sphere by this exact clearance.
		# Deduct it after the anchor blend so the carried ground never rises into
		# the nose-down hull as the terrain expands. At 50 s its tangent is exactly
		# the physical landing surface, with the opaque proxy below crater relief.
		moon_surface = moon_map_surface.lerp(moon_physical_surface,
			moon_anchor_bridge) - moon_up \
			* (MOON_PROXY_RELIEF_CLEARANCE * moon_scale_bridge)
	else:
		# The physical Moon is one stationary body throughout departure. A previous
		# 8–16 s map bridge carried it back towards the camera after it had receded,
		# making the same Moon visibly reappear. Only the ship and camera now move.
		moon_proxy_radius = MOON_PROXY_PHYSICAL_RADIUS_UNITS
		moon_render_radius = moon_proxy_radius
		moon_surface = moon_physical_surface - moon_up * MOON_PROXY_RELIEF_CLEARANCE
	moon_surface_anchor = moon_surface
	moon_render_units_per_km = moon_render_radius / MOON_AUTHORED_RADIUS_KM
	var moon_centre := moon_surface - moon_up * moon_proxy_radius
	moon_visual.scale = Vector3.ONE * moon_proxy_radius
	moon_visual.position = moon_centre - global_position


## Return uses the real launch site's resident chunks. This opaque globe is
## their backing surface; the terrain shader consumes the exact same tangent and
## radius as it expands, then returns those same vertices to ordinary gameplay.
func _update_return_earth_anchor(elapsed: float, rocket: Node3D,
		earth_up: Vector3, moon_up: Vector3, route_right: Vector3) -> void:
	var route: Variant = rocket.get("earth_launch_transform")
	if not route is Transform3D:
		return
	var physical_surface := (route as Transform3D).origin \
		- earth_up * LunarRocket.ORIGIN_ABOVE_LANDING_SURFACE
	var map_blend := _quintic_blend(8.0, 20.0, elapsed)
	var map_radius := lerpf(3.0, EARTH_MAP_RADIUS, map_blend)
	var initial_centre := rocket.global_position - route_right * 42.0 \
		- earth_up * 58.0 + moon_up * 140.0
	var approaching_centre := rocket.global_position - route_right * 32.0 \
		- earth_up * 65.0
	var map_surface := initial_centre.lerp(approaching_centre, map_blend) \
		+ earth_up * map_radius
	var growth := _quintic_blend(RETURN_EARTH_GROW_START_SECONDS,
		RETURN_EARTH_PHYSICAL_SECONDS, elapsed)
	var anchor_blend := _quintic_blend(RETURN_EARTH_ANCHOR_START_SECONDS,
		RETURN_EARTH_PHYSICAL_SECONDS, elapsed)
	earth_render_radius = exp(lerpf(log(map_radius),
		log(EARTH_LOCAL_RADIUS_UNITS), growth))
	return_terrain_surface_anchor = map_surface.lerp(physical_surface, anchor_blend)
	return_terrain_render_radius = earth_render_radius
	# Keep the backing atlas below both the landing pad and nearby real lake
	# surface; it must not fill lower terrain with an opaque continent plane.
	var relief_clearance := maxf(physical_surface.y - Gen.WATER_Y + 2.0, 2.0) * growth
	earth_surface_anchor = return_terrain_surface_anchor - earth_up * relief_clearance
	earth_render_radius -= relief_clearance


static func return_earth_terrain_reveal(elapsed: float) -> float:
	return _quintic_blend(RETURN_TERRAIN_REVEAL_START_SECONDS,
		RETURN_TERRAIN_REVEAL_END_SECONDS, elapsed)


static func return_earth_terrain_strength(elapsed: float) -> float:
	return 1.0 - _quintic_blend(RETURN_EARTH_PHYSICAL_SECONDS,
		RETURN_TERRAIN_HANDOFF_SECONDS, elapsed)


static func lunar_arrival_scale_blend(elapsed: float) -> float:
	return _quintic_blend(MOON_GLOBE_DOMINANT_SECONDS,
		LUNAR_REAL_SURFACE_SECONDS, elapsed)


static func lunar_arrival_anchor_blend(elapsed: float) -> float:
	return _quintic_blend(LUNAR_FLIP_START_SECONDS,
		LUNAR_REAL_SURFACE_SECONDS, elapsed)


static func _quintic_blend(start: float, finish: float, value: float) -> float:
	var t := clampf(inverse_lerp(start, finish, value), 0.0, 1.0)
	return t * t * t * (10.0 + t * (-15.0 + t * 6.0))


## Physical tangent sampler used by tests and by any future cap generator. The
## current floating-origin render radius may change, but the authored body is
## always exactly 12,000 km in world-metre space.
func cinematic_earth_surface_point(flat_world_position: Vector3) -> Vector3:
	var rocket := get_parent() as Node3D
	if not rocket:
		return flat_world_position
	var route: Variant = rocket.get("earth_launch_transform")
	if not route is Transform3D:
		return flat_world_position
	var tangent := (route as Transform3D).origin
	var offset := Vector2(flat_world_position.x - tangent.x,
		flat_world_position.z - tangent.z)
	var radius := EARTH_LOCAL_RADIUS_UNITS
	var radial_squared := offset.length_squared()
	var sag := radius if radial_squared >= radius * radius \
		else radius - sqrt(radius * radius - radial_squared)
	return Vector3(flat_world_position.x,
		flat_world_position.y - sag, flat_world_position.z)


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
	return EARTH_ATLAS


static func shared_moon_texture() -> Texture2D:
	_ensure_shared_resources()
	return MOON_ATLAS


static func shared_galaxy_texture() -> Texture2D:
	_ensure_shared_resources()
	return _galaxy_texture


## Rocket timing is read dynamically to avoid a compile-time LunarRocket <->
## SpaceVoyageVisuals dependency cycle. The cache is populated once, while the
## canonical phase arrays remain owned by LunarRocket.
static func stars_visible_for_progress(progress: float, outbound: bool) -> bool:
	return star_opacity_for_progress(progress, outbound) > 0.001


static func star_opacity_for_progress(progress: float, outbound: bool) -> float:
	var timing := _lunar_rocket_timing()
	var clamped_progress := clampf(progress, 0.0, 1.0)
	if outbound:
		var elapsed := clamped_progress * float(timing.outbound_duration)
		var atmosphere_exit := float(timing.outbound_atmosphere_exit)
		# The lower atmosphere hides stars; reveal them as pressure falls to
		# vacuum, then blend into the real lunar star shell during final approach.
		return smoothstep(atmosphere_exit - 4.0, atmosphere_exit, elapsed) \
			* (1.0 - smoothstep(LUNAR_MAP_REVEAL_SECONDS,
				LUNAR_REAL_SURFACE_SECONDS, elapsed))
	var return_elapsed := clamped_progress * float(timing.return_duration)
	var reentry := float(timing.return_reentry)
	return smoothstep(1.0, 3.0, return_elapsed) \
		* (1.0 - smoothstep(reentry - 4.0, reentry, return_elapsed))


static func _lunar_rocket_timing() -> Dictionary:
	if not _rocket_timing.is_empty():
		return _rocket_timing
	var outbound_duration := 60.0
	var return_duration := 45.0
	var outbound_atmosphere_exit := 10.0
	var outbound_cruise_start := 20.0
	var return_reentry := 28.0
	var rocket_script := load(LUNAR_ROCKET_SCRIPT_PATH) as Script
	if rocket_script:
		var constants := rocket_script.get_script_constant_map()
		outbound_duration = float(constants.get("OUTBOUND_DURATION_SECONDS",
			outbound_duration))
		return_duration = float(constants.get("RETURN_DURATION_SECONDS",
			return_duration))
		var outbound_times = constants.get("OUTBOUND_PHASE_TIMES", [])
		var return_times = constants.get("RETURN_PHASE_TIMES", [])
		if outbound_times is Array and outbound_times.size() > 0:
			outbound_atmosphere_exit = float(outbound_times[0])
		if outbound_times is Array and outbound_times.size() > 1:
			outbound_cruise_start = float(outbound_times[1])
		if return_times is Array and return_times.size() > 1:
			return_reentry = float(return_times[1])
	_rocket_timing = {
		"outbound_duration": outbound_duration,
		"return_duration": return_duration,
		"outbound_atmosphere_exit": outbound_atmosphere_exit,
		"outbound_cruise_start": outbound_cruise_start,
		"return_reentry": return_reentry,
	}
	return _rocket_timing


func _build_backdrop() -> void:
	begin_setup()
	while not is_setup_complete() and not is_queued_for_deletion():
		build_setup_step()


func _build_shells() -> void:
	# The voyage happens inside a fog-free inward-facing shell. It hides the
	# terrestrial atmosphere without swapping the world's shared Environment,
	# and is a single cached material/primitive rather than a per-frame effect.
	space_shell = MeshInstance3D.new()
	space_shell.name = "AirlessSpaceBackdrop"
	space_shell.mesh = _space_shell_mesh
	space_shell.material_override = _space_material
	space_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(space_shell)
	vacuum_backstop = MeshInstance3D.new()
	vacuum_backstop.name = "OpaqueVacuumBackstop"
	vacuum_backstop.mesh = _space_shell_mesh
	vacuum_backstop.material_override = _space_material
	vacuum_backstop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	vacuum_backstop.visible = false
	add_child(vacuum_backstop)


func _build_lights() -> void:
	# Two small shadowless practical lights travel with the capsule. They keep
	# white hull panels, blue windows, and the warm mission stripe readable while
	# preserving a dark side and a convincing cool space rim.
	cabin_key_light = OmniLight3D.new()
	cabin_key_light.name = "RocketKeyLight"
	cabin_key_light.position = Vector3(6.5, 3.5, 10.5)
	cabin_key_light.light_color = Color(0.78, 0.88, 1.0)
	cabin_key_light.light_energy = 7.4
	cabin_key_light.omni_range = 34.0
	cabin_key_light.omni_attenuation = 1.15
	cabin_key_light.shadow_enabled = false
	add_child(cabin_key_light)
	cabin_rim_light = OmniLight3D.new()
	cabin_rim_light.name = "RocketWarmRimLight"
	cabin_rim_light.position = Vector3(-7.0, -1.0, -9.0)
	cabin_rim_light.light_color = Color(1.0, 0.38, 0.12)
	cabin_rim_light.light_energy = 3.5
	cabin_rim_light.omni_range = 30.0
	cabin_rim_light.omni_attenuation = 1.35
	cabin_rim_light.shadow_enabled = false
	add_child(cabin_rim_light)
	celestial_fill_light = DirectionalLight3D.new()
	celestial_fill_light.name = "CelestialFillLight"
	celestial_fill_light.light_color = Color(0.72, 0.82, 1.0)
	celestial_fill_light.light_energy = CELESTIAL_FILL_ENERGY
	celestial_fill_light.rotation_degrees = Vector3(-32.0, -38.0, 0.0)
	celestial_fill_light.shadow_enabled = false
	celestial_fill_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	add_child(celestial_fill_light)


func _build_stars() -> void:
	star_field = MultiMeshInstance3D.new()
	star_field.name = "BoundedStarField"
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = _star_mesh
	multimesh.instance_count = STAR_COUNT
	for index in range(STAR_COUNT):
		var direction := _fibonacci_direction(index, STAR_COUNT)
		var radius := 460.0 + float(_hash_u32(index * 7919 + 41) & 0xffff) \
			/ 65535.0 * 270.0
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


func _build_constellations() -> void:
	constellation_lines = MeshInstance3D.new()
	constellation_lines.name = "ConstellationLines"
	constellation_lines.mesh = _constellation_mesh()
	constellation_lines.scale = Vector3.ONE * 3.8
	constellation_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(constellation_lines)


func _build_galaxy() -> void:
	# One distant billboard makes the requested galaxy legible without introducing
	# a second particle field. Its deterministic texture and material are cached
	# once for every rocket; the voyage update only toggles visibility.
	var galaxy_quad := QuadMesh.new()
	galaxy_quad.size = Vector2(58.0, 34.0)
	galaxy_visual = MeshInstance3D.new()
	galaxy_visual.name = "DistantSpiralGalaxy"
	galaxy_visual.mesh = galaxy_quad
	galaxy_visual.material_override = _galaxy_material
	galaxy_visual.position = Vector3(230.0, -126.0, -650.0)
	galaxy_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(galaxy_visual)


func _build_planets() -> void:
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
		planet.position = Vector3(-310.0 + index * 180.0,
			168.0 - index * 72.0, -525.0 - index * 56.0)
		planets.append(planet)


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
		cloud.position = Vector3(-285.0 + index * 278.0,
			-112.0 + index * 128.0, -592.0 - index * 30.0)
		cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(cloud)
		nebulae.append(cloud)


func _add_sphere(part_name: String, radius: float,
		material: Material, detailed := false) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = CELESTIAL_RADIAL_SEGMENTS if detailed else 20
	mesh.rings = CELESTIAL_RINGS if detailed else 12
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
	# The 24,000 km scaled-space Earth begins thousands of render units wide.
	# Keep this single low-poly sky surface behind the whole diorama; the old
	# 900-unit shell cut through the globe and looked like a second bright planet.
	_space_shell_mesh.radius = 50_000.0
	_space_shell_mesh.height = 100_000.0
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
	_earth_material = ShaderMaterial.new()
	_earth_material.shader = Shader.new()
	_earth_material.shader.code = EARTH_PLANET_SHADER
	_earth_material.set_shader_parameter("planet_atlas", EARTH_ATLAS)
	_earth_material.set_shader_parameter("microdetail", PLANET_MICRODETAIL)
	_earth_atmosphere_material = StandardMaterial3D.new()
	_earth_atmosphere_material.albedo_color = Color(0.10, 0.44, 1.0, 0.16)
	_earth_atmosphere_material.emission_enabled = true
	_earth_atmosphere_material.emission = Color(0.05, 0.24, 0.86)
	_earth_atmosphere_material.emission_energy_multiplier = 1.45
	_earth_atmosphere_material.transparency = \
		BaseMaterial3D.TRANSPARENCY_ALPHA
	_earth_atmosphere_material.shading_mode = \
		BaseMaterial3D.SHADING_MODE_UNSHADED
	# Render only the near side. Back-face-only transparency can expose the far
	# hemisphere through Godot's alpha sort and look like a second, smaller Earth
	# during the scale transition.
	_earth_atmosphere_material.cull_mode = BaseMaterial3D.CULL_BACK
	_earth_atmosphere_material.disable_receive_shadows = true
	_earth_atmosphere_material.disable_fog = true
	_moon_material = ShaderMaterial.new()
	_moon_material.shader = Shader.new()
	_moon_material.shader.code = MOON_PLANET_SHADER
	_moon_material.set_shader_parameter("planet_atlas", MOON_ATLAS)
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
