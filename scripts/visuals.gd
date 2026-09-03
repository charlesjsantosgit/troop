class_name Visuals
extends RefCounted
## Shared procedural shader library. Materials are cached so the streamed world
## gets richer lighting and motion without creating a shader per mesh instance.

static var _shared: Dictionary = {}
static var _foliage: Dictionary = {}
static var _fur: Dictionary = {}
## Shader source is immutable after construction. Share the program, not the
## ShaderMaterial: colors, seasons and LOD handoffs remain per-material uniforms.
## A caller that needs to edit shader code must create its own Shader instead.
static var _shaders_by_source: Dictionary = {}
static var _far_focus := Vector2(INF, INF)
static var _skyline_near_fade := Gen.SKYLINE_NEAR_FADE
static var _stratos_near_fade := Gen.STRATOS_NEAR_FADE
static var _stratos_far_fade := Gen.VIEW_BASE_DISTANCE
static var _spring_amount := 0.0
static var _autumn_amount := 0.0
static var _snow_amount := 0.0
static var _cinematic_curve_focus := Vector2.ZERO
static var _cinematic_curve_surface_y := 0.0
static var _cinematic_curve_radius := 12_000_000.0
static var _cinematic_curve_strength := 0.0
static var _cinematic_curve_cap_radius := 1_000_000_000.0
static var _cinematic_render_surface := Vector3.ZERO
static var _cinematic_render_radius := 12_000_000.0
static var _cinematic_materials: Array[ShaderMaterial] = []
# Keep the public texture names without eagerly loading them while Net's
# autoload dependencies are parsed, before the first menu can be drawn.
static var TERRAIN_MICRODETAIL: Texture2D:
	get:
		return SharedTextureCache.get_texture(SharedTextureCache.MICRODETAIL_PATH)
static var TERRAIN_FLOOR_ALBEDO: Texture2D:
	get:
		return SharedTextureCache.get_texture(SharedTextureCache.FLOOR_PATH)
static var EARTH_CINEMATIC_ATLAS: Texture2D:
	get:
		return SharedTextureCache.get_texture(SharedTextureCache.EARTH_PATH)
## A complete 5x5 fine-water grid guarantees 96 m from a player standing at
## a chunk edge. Coarse water must already own every pixel at that boundary.
const WATER_HANDOFF_BAND := 16.0
const WATER_HANDOFF_DISTANCE := Gen.CHUNK * Gen.VIEW_R - WATER_HANDOFF_BAND

const CINEMATIC_CURVE_UNIFORMS := [
	"cinematic_curve_focus_xz", "cinematic_curve_surface_y",
	"cinematic_curve_radius", "cinematic_curve_strength",
	"cinematic_curve_cap_radius", "cinematic_render_surface",
	"cinematic_render_radius",
]

const GROUND_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec2 cinematic_curve_focus_xz = vec2(0.0);
uniform float cinematic_curve_surface_y = 0.0;
uniform float cinematic_curve_radius = 12000000.0;
uniform float cinematic_curve_strength : hint_range(0.0, 1.0) = 0.0;
uniform float cinematic_curve_cap_radius = 1000000000.0;
uniform vec3 cinematic_render_surface = vec3(0.0);
uniform float cinematic_render_radius = 12000000.0;
uniform sampler2D terrain_microdetail : source_color, repeat_enable,
	filter_linear_mipmap_anisotropic;
uniform sampler2D terrain_floor_albedo : source_color, repeat_enable,
	filter_linear_mipmap_anisotropic;
varying vec3 world_pos;
varying vec3 world_normal;
varying vec4 vertex_tint;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

vec3 curved_planet_position(vec3 flat_position) {
	float physical_radius = max(cinematic_curve_radius, 1.0);
	float render_radius = max(cinematic_render_radius, 0.001);
	vec2 offset = flat_position.xz - cinematic_curve_focus_xz;
	float planar_distance = length(offset);
	vec2 direction = planar_distance > 0.0001
		? offset / planar_distance : vec2(1.0, 0.0);
	float angle = min(planar_distance / physical_radius, 3.135);
	vec3 centre = cinematic_render_surface - vec3(0.0, render_radius, 0.0);
	vec3 radial = vec3(direction.x * sin(angle), cos(angle),
		direction.y * sin(angle));
	float render_height = (flat_position.y - cinematic_curve_surface_y)
		* render_radius / physical_radius;
	vec3 curved = cinematic_render_surface + vec3(
		radial.x * (render_radius + render_height),
		-2.0 * pow(sin(angle * 0.5), 2.0) * render_radius
			+ radial.y * render_height,
		radial.z * (render_radius + render_height));
	return mix(flat_position, curved, cinematic_curve_strength);
}

void vertex() {
	vec3 flat_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos = flat_position;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	vertex_tint = COLOR;
	// POSITION is written by the cinematic branch, so the ordinary branch must
	// explicitly provide its normal clip-space position too. Leaving it unset
	// collapsed every gameplay terrain vertex and exposed the sky's cyan nadir.
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(flat_position, 1.0);
	if (cinematic_curve_strength > 0.0001) {
		// The trigonometric life-size curvature path is cinematic-only. Keeping
		// it inside this branch restores the ordinary streamed-world fast path.
		vec3 curved_position = curved_planet_position(flat_position);
		vec3 centre = cinematic_render_surface
			- vec3(0.0, cinematic_render_radius, 0.0);
		vec3 radial_normal = normalize(curved_position - centre);
		world_normal = normalize(mix(world_normal, radial_normal,
			cinematic_curve_strength));
		POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(curved_position, 1.0);
	}
}

void fragment() {
	if (cinematic_curve_strength > 0.0001) {
		if (distance(world_pos.xz, cinematic_curve_focus_xz)
				> cinematic_curve_cap_radius) { discard; }
	}
	float broad = hash21(floor(world_pos.xz * 0.18));
	float fine = hash21(floor(world_pos.xz * 1.4));
	// Preserve metre-scale breakup in gameplay, but widen the same mipmapped
	// field during the orbital shot so it remains visible across kilometres
	// instead of averaging into one beige value. No extra texture lookup.
	float detail_world_scale = mix(512.0, 16384.0,
		cinematic_curve_strength);
	float mapped_detail = texture(terrain_microdetail,
		world_pos.xz / detail_world_scale).r;
	// One shared, mipmapped albedo lookup replaces the old flat biome colour at
	// walking distance with real leaf litter, roots, pebbles and damp soil. It is
	// deliberately disabled for the orbital curvature path, whose 4K atlas owns
	// the kilometre-scale appearance. This adds no material instances or draws.
	vec3 floor_albedo = texture(terrain_floor_albedo,
		world_pos.xz / 36.0).rgb;
	float floor_luma = dot(floor_albedo, vec3(0.2126, 0.7152, 0.0722));
	float slope = 1.0 - clamp(world_normal.y, 0.0, 1.0);
	float mottled = mix(0.82, 1.13, broad) * mix(0.93, 1.06, fine)
		* mix(mix(0.88, 0.68, cinematic_curve_strength),
			mix(1.12, 1.34, cinematic_curve_strength), mapped_detail);
	vec3 earth = vec3(0.20, 0.14, 0.075);
	vec3 base = vertex_tint.rgb * mottled * 0.66;
	base = mix(base, earth, slope * 0.28);
	float damp = smoothstep(0.75, 0.2, world_pos.y);
	vec3 ground = mix(base, base * vec3(0.66, 0.72, 0.54), damp * 0.24);
	vec3 biome_material_tint = mix(vec3(0.92),
		clamp(vertex_tint.rgb * 2.7, vec3(0.42), vec3(1.18)), 0.42);
	vec3 textured_floor = floor_albedo * 1.52 * biome_material_tint;
	float floor_weight = (1.0 - cinematic_curve_strength)
		* mix(0.52, 0.30, slope);
	ground = mix(ground, textured_floor, floor_weight);
	// Let soil texture and broad terrain variation remain legible below the
	// accumulation.  Fully replacing the ground with a flat near-white made
	// winter hills clip into one featureless value under the noon sun.
	// Permanent altitude snow joins seasonal snow: peaks stay white all year,
	// matching the rock/snow bands the vertex tint already carries.
	float alt_snow = smoothstep(3000.0, 4300.0, world_pos.y);
	float snow = max(snow_amount * smoothstep(0.28, 0.72, world_normal.y),
		alt_snow * smoothstep(0.20, 0.65, world_normal.y))
		* mix(0.70, 0.92, fine);
	vec3 snow_color = vec3(0.70, 0.77, 0.82)
		* mix(0.88, 1.08, broad) * mix(0.94, 1.03, fine);
	ALBEDO = mix(ground, snow_color, snow);
	ROUGHNESS = mix(mix(0.98, 0.72, damp), 0.62, snow)
		- mapped_detail * (1.0 - snow) * 0.06
		+ (0.5 - floor_luma) * floor_weight * 0.10;
	SPECULAR = 0.18;
	AO = 0.76 + fine * 0.14 + mapped_detail * 0.08;
	RIM = 0.08;
	RIM_TINT = 0.55;
}
"""

const TRUNK_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.42, 0.29, 0.17);
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
varying vec3 local_pos;
varying vec3 world_pos;
varying vec3 world_normal;
varying vec4 vertex_tint;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(41.13, 289.97))) * 43758.5453);
}

void vertex() {
	local_pos = VERTEX;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	vertex_tint = COLOR;
}

void fragment() {
	float ridges = pow(0.5 + 0.5 * sin(local_pos.y * 7.0 + atan(local_pos.z, local_pos.x) * 3.0), 3.0);
	float grain = hash21(floor(world_pos.xz * 2.5 + world_pos.y));
	vec3 bark = base_color * vertex_tint.rgb * mix(0.70, 1.17, ridges) * mix(0.88, 1.08, grain);
	float moss = smoothstep(0.35, 0.78, world_normal.y) * smoothstep(0.58, 0.18, hash21(floor(world_pos.xz)));
	vec3 trunk = mix(bark, vec3(0.16, 0.31, 0.105), moss * 0.46);
	float snow = snow_amount * smoothstep(0.94, 0.995, world_normal.y)
		* smoothstep(0.20, 0.82, grain);
	ALBEDO = mix(trunk, vec3(0.80, 0.87, 0.92), snow);
	ROUGHNESS = 0.94;
	SPECULAR = 0.20;
	AO = 0.82;
	RIM = 0.06;
	RIM_TINT = 0.45;
}
"""

const FOLIAGE_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.20, 0.56, 0.16);
uniform float wind_strength : hint_range(0.0, 0.2) = 0.055;
uniform float spring_amount : hint_range(0.0, 1.0) = 0.0;
uniform float autumn_amount : hint_range(0.0, 1.0) = 0.0;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 object_pos;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float gust = sin(TIME * 1.25 + wp.x * 0.19 + wp.z * 0.13);
	gust += sin(TIME * 2.4 + wp.z * 0.31) * 0.35;
	float crown = clamp(0.52 + VERTEX.y * 0.16, 0.15, 1.0);
	VERTEX.x += gust * wind_strength * crown;
	VERTEX.z += cos(TIME * 0.9 + wp.x * 0.16) * wind_strength * crown * 0.55;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	object_pos = VERTEX;
}

void fragment() {
	float cluster = hash31(floor(world_pos * 0.72));
	float tiny = hash31(floor(object_pos * 3.6));
	float upper = smoothstep(-1.0, 1.8, object_pos.y);
	vec3 spring_green = base_color * vec3(0.78, 1.18, 0.72);
	vec3 autumn_a = vec3(0.92, 0.42, 0.045);
	vec3 autumn_b = vec3(0.66, 0.12, 0.035);
	vec3 autumn_c = vec3(0.96, 0.68, 0.07);
	vec3 autumn_leaf = mix(autumn_a, autumn_b, smoothstep(0.42, 0.78, cluster));
	autumn_leaf = mix(autumn_leaf, autumn_c, smoothstep(0.76, 0.96, tiny));
	vec3 leaf_color = mix(base_color, spring_green, spring_amount * 0.48);
	leaf_color = mix(leaf_color, autumn_leaf, autumn_amount * 0.94);
	vec3 shaded = leaf_color * mix(0.58, 1.02, upper) * mix(0.82, 1.08, cluster);
	shaded *= mix(0.94, 1.05, tiny);
	float snow = snow_amount * smoothstep(0.26, 0.72, world_normal.y)
		* smoothstep(0.25, 0.88, upper);
	ALBEDO = mix(shaded, vec3(0.82, 0.89, 0.94), snow);
	ROUGHNESS = 0.88;
	SPECULAR = 0.24;
	AO = mix(0.72, 1.0, upper);
	RIM = 0.12;
	RIM_TINT = 0.58;
}
"""

const FOLIAGE_LOD_SHADER := """
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform float wind_strength : hint_range(0.0, 0.2) = 0.045;
uniform float spring_amount : hint_range(0.0, 1.0) = 0.0;
uniform float autumn_amount : hint_range(0.0, 1.0) = 0.0;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 object_pos;
varying vec4 vertex_tint;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float gust = sin(TIME * 1.25 + wp.x * 0.19 + wp.z * 0.13);
	gust += sin(TIME * 2.4 + wp.z * 0.31) * 0.35;
	VERTEX.xz += vec2(gust, cos(TIME * 0.9 + wp.x * 0.16) * 0.55) * wind_strength;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	object_pos = VERTEX;
	vertex_tint = COLOR;
}

void fragment() {
	float cluster = hash31(floor(world_pos * 0.72));
	float tiny = hash31(floor(object_pos * 2.2));
	vec3 spring_leaf = vertex_tint.rgb * vec3(0.78, 1.16, 0.72);
	vec3 autumn_leaf = mix(vec3(0.94, 0.49, 0.045), vec3(0.65, 0.12, 0.03),
		smoothstep(0.38, 0.80, cluster));
	autumn_leaf = mix(autumn_leaf, vec3(0.96, 0.70, 0.08),
		smoothstep(0.78, 0.96, tiny));
	vec3 leaf_color = mix(vertex_tint.rgb, spring_leaf, spring_amount * 0.46);
	leaf_color = mix(leaf_color, autumn_leaf, autumn_amount * 0.94);
	vec3 shaded = leaf_color * mix(0.78, 1.10, cluster) * mix(0.93, 1.05, tiny);
	float snow = snow_amount * smoothstep(0.24, 0.68, world_normal.y);
	ALBEDO = mix(shaded, vec3(0.82, 0.89, 0.94), snow);
	ROUGHNESS = 0.89;
	SPECULAR = 0.22;
	AO = 0.82;
	RIM = 0.10;
	RIM_TINT = 0.58;
}
"""

const FAR_GROUND_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec2 focus_xz = vec2(0.0);
uniform float near_fade = 108.0;
uniform float fade_band = 18.0;
uniform float far_fade = 600.0;
uniform float far_fade_band = 96.0;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec2 cinematic_curve_focus_xz = vec2(0.0);
uniform float cinematic_curve_surface_y = 0.0;
uniform float cinematic_curve_radius = 12000000.0;
uniform float cinematic_curve_strength : hint_range(0.0, 1.0) = 0.0;
uniform float cinematic_curve_cap_radius = 1000000000.0;
uniform vec3 cinematic_render_surface = vec3(0.0);
uniform float cinematic_render_radius = 12000000.0;
uniform sampler2D terrain_microdetail : source_color, repeat_enable,
	filter_linear_mipmap_anisotropic;
uniform sampler2D earth_cinematic_atlas : source_color,
	filter_linear_mipmap_anisotropic;
varying vec3 world_pos;
varying vec4 vertex_tint;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

vec3 curved_planet_position(vec3 flat_position) {
	float physical_radius = max(cinematic_curve_radius, 1.0);
	float render_radius = max(cinematic_render_radius, 0.001);
	vec2 offset = flat_position.xz - cinematic_curve_focus_xz;
	float planar_distance = length(offset);
	vec2 direction = planar_distance > 0.0001
		? offset / planar_distance : vec2(1.0, 0.0);
	float angle = min(planar_distance / physical_radius, 3.135);
	vec3 centre = cinematic_render_surface - vec3(0.0, render_radius, 0.0);
	vec3 radial = vec3(direction.x * sin(angle), cos(angle),
		direction.y * sin(angle));
	float render_height = (flat_position.y - cinematic_curve_surface_y)
		* render_radius / physical_radius;
	return mix(flat_position, cinematic_render_surface + vec3(
		radial.x * (render_radius + render_height),
		-2.0 * pow(sin(angle * 0.5), 2.0) * render_radius
			+ radial.y * render_height,
		radial.z * (render_radius + render_height)),
		cinematic_curve_strength);
}

void vertex() {
	vec3 flat_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos = flat_position;
	vertex_tint = COLOR;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(flat_position, 1.0);
	if (cinematic_curve_strength > 0.0001) {
		POSITION = PROJECTION_MATRIX * VIEW_MATRIX
			* vec4(curved_planet_position(flat_position), 1.0);
	}
}

void fragment() {
	if (cinematic_curve_strength > 0.0001) {
		if (distance(world_pos.xz, cinematic_curve_focus_xz)
				> cinematic_curve_cap_radius) { discard; }
	}
	float distance_to_focus = distance(world_pos.xz, focus_xz);
	float coverage = near_fade <= 0.0 ? 1.0 : smoothstep(
		near_fade - fade_band, near_fade + fade_band, distance_to_focus);
	float cell_hash = hash21(floor(world_pos.xz * 0.36));
	if (cell_hash > coverage) { discard; }
	float outgoing = smoothstep(far_fade - far_fade_band,
		far_fade + far_fade_band, distance_to_focus);
	if (cell_hash <= outgoing) { discard; }
	float detail_world_scale = mix(1024.0, 16384.0,
		cinematic_curve_strength);
	float mapped_detail = texture(terrain_microdetail,
		world_pos.xz / detail_world_scale).r;
	vec3 ground = vertex_tint.rgb * mix(0.76, 0.92, mapped_detail);
	float snow_noise = hash21(floor(world_pos.xz * 0.12));
	float alt_snow = smoothstep(3000.0, 4300.0, world_pos.y);
	float snow = max(snow_amount, alt_snow) * mix(0.68, 0.90, snow_noise);
	vec3 snow_color = vec3(0.68, 0.75, 0.81)
		* mix(0.90, 1.07, snow_noise);
	ALBEDO = mix(ground, snow_color, snow);
	if (cinematic_curve_strength > 0.0001) {
		float physical_radius = max(cinematic_curve_radius, 1.0);
		vec2 offset = world_pos.xz - cinematic_curve_focus_xz;
		float planar_distance = length(offset);
		vec2 direction = planar_distance > 0.0001
			? offset / planar_distance : vec2(1.0, 0.0);
		float angle = min(planar_distance / physical_radius, 3.135);
		vec3 radial = vec3(direction.x * sin(angle), cos(angle),
			direction.y * sin(angle));
		vec3 atlas_direction = vec3(radial.x, radial.z, -radial.y);
		vec2 atlas_uv = vec2(fract(0.88 + atan(atlas_direction.z,
			atlas_direction.x) / 6.28318530718),
			acos(clamp(atlas_direction.y, -1.0, 1.0)) / 3.14159265359);
		vec3 atlas_colour = texture(earth_cinematic_atlas, atlas_uv).rgb;
		ALBEDO = atlas_colour * mix(0.72, 1.28, mapped_detail);
	}
	ROUGHNESS = mix(0.99, 0.91, mapped_detail);
	SPECULAR = 0.10;
	AO = mix(0.82, 0.94, mapped_detail);
}
"""

const STRATOS_GROUND_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec2 focus_xz = vec2(0.0);
uniform float near_fade = 1700.0;
uniform float fade_band = 220.0;
uniform float far_fade = 24140.0;
uniform float far_fade_band = 420.0;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec2 cinematic_curve_focus_xz = vec2(0.0);
uniform float cinematic_curve_surface_y = 0.0;
uniform float cinematic_curve_radius = 12000000.0;
uniform float cinematic_curve_strength : hint_range(0.0, 1.0) = 0.0;
uniform float cinematic_curve_cap_radius = 1000000000.0;
uniform vec3 cinematic_render_surface = vec3(0.0);
uniform float cinematic_render_radius = 12000000.0;
uniform sampler2D terrain_microdetail : source_color, repeat_enable,
	filter_linear_mipmap_anisotropic;
uniform sampler2D earth_cinematic_atlas : source_color,
	filter_linear_mipmap_anisotropic;
varying vec3 world_pos;
varying vec4 vertex_tint;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

vec3 curved_planet_position(vec3 flat_position) {
	float physical_radius = max(cinematic_curve_radius, 1.0);
	float render_radius = max(cinematic_render_radius, 0.001);
	vec2 offset = flat_position.xz - cinematic_curve_focus_xz;
	float planar_distance = length(offset);
	vec2 direction = planar_distance > 0.0001
		? offset / planar_distance : vec2(1.0, 0.0);
	float angle = min(planar_distance / physical_radius, 3.135);
	vec3 centre = cinematic_render_surface - vec3(0.0, render_radius, 0.0);
	vec3 radial = vec3(direction.x * sin(angle), cos(angle),
		direction.y * sin(angle));
	float render_height = (flat_position.y - cinematic_curve_surface_y)
		* render_radius / physical_radius;
	return mix(flat_position, cinematic_render_surface + vec3(
		radial.x * (render_radius + render_height),
		-2.0 * pow(sin(angle * 0.5), 2.0) * render_radius
			+ radial.y * render_height,
		radial.z * (render_radius + render_height)),
		cinematic_curve_strength);
}

void vertex() {
	vec3 flat_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos = flat_position;
	vertex_tint = COLOR;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(flat_position, 1.0);
	if (cinematic_curve_strength > 0.0001) {
		POSITION = PROJECTION_MATRIX * VIEW_MATRIX
			* vec4(curved_planet_position(flat_position), 1.0);
	}
}

void fragment() {
	if (cinematic_curve_strength > 0.0001) {
		if (distance(world_pos.xz, cinematic_curve_focus_xz)
				> cinematic_curve_cap_radius) { discard; }
	}
	float distance_to_focus = distance(world_pos.xz, focus_xz);
	float coverage = near_fade <= 0.0 ? 1.0 : smoothstep(
		near_fade - fade_band, near_fade + fade_band, distance_to_focus);
	float cell_hash = hash21(floor(world_pos.xz * 0.36));
	if (cell_hash > coverage) { discard; }
	// Stratos has no successor outside the requested view circle. Finish its
	// atmospheric fade at that exact radius so circular target selection never
	// needs hidden padding sectors beyond the camera's horizon.
	float outgoing = smoothstep(far_fade - far_fade_band,
		far_fade, distance_to_focus);
	if (cell_hash <= outgoing) { discard; }

	// COLOR.a carries deterministic canopy coverage. Broad 64/190 m patches
	// survive at aircraft distance, unlike literal crowns that become sub-pixel.
	float canopy = clamp(vertex_tint.a, 0.0, 1.0);
	float broad = hash21(floor(world_pos.xz / 190.0));
	float crown = hash21(floor(world_pos.xz / 64.0));
	float canopy_light = mix(0.72, 1.10, broad) * mix(0.88, 1.08, crown);
	float detail_world_scale = mix(4096.0, 16384.0,
		cinematic_curve_strength);
	float mapped_detail = texture(terrain_microdetail,
		world_pos.xz / detail_world_scale).r;
	vec3 ground = vertex_tint.rgb * mix(0.76, 0.92, mapped_detail);
	vec3 forest = vertex_tint.rgb * canopy_light;
	vec3 shaded = mix(ground, forest, canopy * 0.82);

	float snow_noise = hash21(floor(world_pos.xz * 0.012));
	float alt_snow = smoothstep(3000.0, 4300.0, world_pos.y);
	float snow = max(snow_amount, alt_snow) * mix(0.68, 0.90, snow_noise);
	vec3 snow_color = vec3(0.68, 0.75, 0.81) * mix(0.90, 1.07, snow_noise);
	ALBEDO = mix(shaded, snow_color, snow);
	if (cinematic_curve_strength > 0.0001) {
		float physical_radius = max(cinematic_curve_radius, 1.0);
		vec2 offset = world_pos.xz - cinematic_curve_focus_xz;
		float planar_distance = length(offset);
		vec2 direction = planar_distance > 0.0001
			? offset / planar_distance : vec2(1.0, 0.0);
		float angle = min(planar_distance / physical_radius, 3.135);
		vec3 radial = vec3(direction.x * sin(angle), cos(angle),
			direction.y * sin(angle));
		// Earth globe is rotated +90 degrees about X, so project the retained
		// stratos cap through the exact inverse orientation into the same atlas.
		vec3 atlas_direction = vec3(radial.x, radial.z, -radial.y);
		vec2 atlas_uv = vec2(fract(0.88 + atan(atlas_direction.z,
			atlas_direction.x) / 6.28318530718),
			acos(clamp(atlas_direction.y, -1.0, 1.0)) / 3.14159265359);
		vec3 atlas_colour = texture(earth_cinematic_atlas, atlas_uv).rgb;
		// At life-size scale the 4K atlas spans several kilometres per texel.
		// Broad mipmapped microdetail preserves continents/coastlines while giving
		// the atmosphere-exit shot readable terrain instead of solid colour bands.
		ALBEDO = atlas_colour * mix(0.72, 1.28, mapped_detail);
	}
	ROUGHNESS = mix(0.99, 0.91, canopy) - mapped_detail * 0.035;
	SPECULAR = mix(0.10, 0.13, canopy);
	AO = mix(0.88, 0.78, canopy) * mix(0.92, 1.03, mapped_detail);
}
"""

const FAR_JUNGLE_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec2 focus_xz = vec2(0.0);
uniform float near_fade = 108.0;
uniform float fade_band = 18.0;
uniform float far_fade = 600.0;
uniform float far_fade_band = 96.0;
uniform float spring_amount : hint_range(0.0, 1.0) = 0.0;
uniform float autumn_amount : hint_range(0.0, 1.0) = 0.0;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
varying vec3 world_pos;
varying vec4 instance_tint;
varying float leaf_part;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	instance_tint = COLOR;
	leaf_part = UV.x;
}

void fragment() {
	float distance_to_focus = distance(world_pos.xz, focus_xz);
	float coverage = near_fade <= 0.0 ? 1.0 : smoothstep(
		near_fade - fade_band, near_fade + fade_band, distance_to_focus);
	float cell_hash = hash21(floor(world_pos.xz * 0.42));
	if (cell_hash > coverage) { discard; }
	float outgoing = smoothstep(far_fade - far_fade_band,
		far_fade + far_fade_band, distance_to_focus);
	if (cell_hash <= outgoing) { discard; }
	vec3 bark = vec3(0.27, 0.18, 0.095);
	float variation = hash21(floor(world_pos.xz * 0.11));
	vec3 leaves = mix(instance_tint.rgb,
		instance_tint.rgb * vec3(0.78, 1.14, 0.72), spring_amount * 0.45) * 0.82;
	vec3 autumn_leaf = mix(vec3(0.90, 0.30, 0.035),
		vec3(0.96, 0.66, 0.06), variation);
	leaves = mix(leaves, autumn_leaf, autumn_amount * 0.94);
	leaves = mix(leaves, vec3(0.76, 0.84, 0.90), snow_amount * 0.82);
	bark = mix(bark, vec3(0.69, 0.76, 0.81), snow_amount * 0.20);
	ALBEDO = mix(bark, leaves, step(0.5, leaf_part));
	ROUGHNESS = 0.96;
	SPECULAR = 0.11;
	AO = mix(0.72, 0.88, leaf_part);
}
"""

const FAR_WATER_SHADER := """
shader_type spatial;
render_mode diffuse_burley, cull_disabled;

uniform vec2 focus_xz = vec2(0.0);
uniform float near_fade = 108.0;
uniform float fade_band = 16.0;
uniform float far_fade = 600.0;
uniform float far_fade_band = 96.0;
uniform vec2 cinematic_curve_focus_xz = vec2(0.0);
uniform float cinematic_curve_surface_y = 0.0;
uniform float cinematic_curve_radius = 12000000.0;
uniform float cinematic_curve_strength : hint_range(0.0, 1.0) = 0.0;
uniform float cinematic_curve_cap_radius = 1000000000.0;
uniform vec3 cinematic_render_surface = vec3(0.0);
uniform float cinematic_render_radius = 12000000.0;
uniform sampler2D water_microdetail : source_color, repeat_enable,
	filter_linear_mipmap_anisotropic;
varying vec3 world_pos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

vec3 curved_planet_position(vec3 flat_position) {
	float physical_radius = max(cinematic_curve_radius, 1.0);
	float render_radius = max(cinematic_render_radius, 0.001);
	vec2 offset = flat_position.xz - cinematic_curve_focus_xz;
	float planar_distance = length(offset);
	vec2 direction = planar_distance > 0.0001
		? offset / planar_distance : vec2(1.0, 0.0);
	float angle = min(planar_distance / physical_radius, 3.135);
	vec3 centre = cinematic_render_surface - vec3(0.0, render_radius, 0.0);
	vec3 radial = vec3(direction.x * sin(angle), cos(angle),
		direction.y * sin(angle));
	float render_height = (flat_position.y - cinematic_curve_surface_y)
		* render_radius / physical_radius;
	return mix(flat_position, cinematic_render_surface + vec3(
		radial.x * (render_radius + render_height),
		-2.0 * pow(sin(angle * 0.5), 2.0) * render_radius
			+ radial.y * render_height,
		radial.z * (render_radius + render_height)),
		cinematic_curve_strength);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += sin(wp.x * 0.055 + TIME * 0.62) * 0.055;
	VERTEX.y += sin(wp.z * 0.071 - TIME * 0.47) * 0.035;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Match the land projection only during the departure shot. The explicit
	// ordinary position preserves the existing animated-water fast path.
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
	if (cinematic_curve_strength > 0.0001) {
		POSITION = PROJECTION_MATRIX * VIEW_MATRIX
			* vec4(curved_planet_position(world_pos), 1.0);
	}
}

void fragment() {
	if (cinematic_curve_strength > 0.0001) {
		if (distance(world_pos.xz, cinematic_curve_focus_xz)
				> cinematic_curve_cap_radius) { discard; }
	}
	float distance_to_focus = distance(world_pos.xz, focus_xz);
	float coverage = near_fade <= 0.0 ? 1.0 : smoothstep(
		near_fade - fade_band, near_fade + fade_band, distance_to_focus);
	// Match the terrain/stratos hash lattice so water cells have exact ownership
	// during the skyline-to-stratos handoff as well as horizon-to-skyline.
	float cell_hash = hash21(floor(world_pos.xz * 0.36));
	if (cell_hash > coverage) { discard; }
	float outgoing = smoothstep(far_fade - far_fade_band,
		far_fade + far_fade_band, distance_to_focus);
	if (cell_hash <= outgoing) { discard; }
	float ripple = sin(world_pos.x * 0.08 + world_pos.z * 0.05 + TIME) * 0.5 + 0.5;
	// One broad, mip-filtered sample keeps the horizon alive without adding
	// geometry or the near-water shader's second crossed detail fetch.
	vec2 detail_uv = world_pos.xz * 0.006
		+ vec2(TIME * 0.003, -TIME * 0.002);
	float mapped_detail = texture(water_microdetail, detail_uv).r;
	float foam_fleck = smoothstep(0.64, 0.94, mapped_detail);
	vec3 water = mix(vec3(0.035, 0.24, 0.24),
		vec3(0.065, 0.42, 0.36), ripple * 0.18);
	ALBEDO = mix(water, vec3(0.20, 0.62, 0.53), foam_fleck * 0.07);
	ROUGHNESS = mix(0.50, 0.43, mapped_detail);
	SPECULAR = 0.62;
}
"""

const GRASS_SHADER := """
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
varying vec3 world_pos;
varying vec3 world_normal;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float tip = clamp(VERTEX.y / 0.34, 0.0, 1.0);
	float gust = sin(TIME * 2.0 + wp.x * 0.45 + wp.z * 0.31);
	gust += sin(TIME * 0.73 + wp.z * 0.18) * 0.45;
	VERTEX.x += gust * 0.085 * tip * tip;
	VERTEX.z += cos(TIME * 1.35 + wp.x * 0.28) * 0.035 * tip;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	float patch = hash21(floor(world_pos.xz * 0.45));
	float blade = hash21(floor(world_pos.xz * 4.0));
	vec3 low = vec3(0.05, 0.20, 0.035);
	vec3 high = vec3(0.16, 0.42, 0.085);
	vec3 grass = mix(low, high, 0.35 + patch * 0.5) * mix(0.88, 1.12, blade);
	float snow = snow_amount * smoothstep(0.22, 0.68, world_normal.y);
	ALBEDO = mix(grass, vec3(0.80, 0.88, 0.93), snow);
	ROUGHNESS = 0.92;
	SPECULAR = 0.18;
	RIM = 0.28;
	RIM_TINT = 0.5;
}
"""

const VINE_SHADER := """
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform float wind_strength : hint_range(0.0, 0.08) = 0.02;
varying vec4 vertex_tint;
varying vec3 world_pos;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float breeze = sin(TIME * 1.45 + wp.y * 0.31 + wp.x * 0.19);
	VERTEX.x += breeze * wind_strength;
	VERTEX.z += cos(TIME * 1.1 + wp.y * 0.27 + wp.z * 0.21) * wind_strength;
	vertex_tint = COLOR;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float fibers = 0.84 + 0.16 * sin(world_pos.y * 19.0 + world_pos.x * 5.0);
	ALBEDO = vertex_tint.rgb * fibers;
	ROUGHNESS = 0.90;
	SPECULAR = 0.22;
	RIM = 0.30;
	RIM_TINT = 0.55;
}
"""

const WATER_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled, diffuse_burley, specular_schlick_ggx;

const int MAX_RIPPLES = 8;

uniform vec3 shallow_color : source_color = vec3(0.055, 0.50, 0.46);
uniform vec3 deep_color : source_color = vec3(0.008, 0.105, 0.18);
uniform vec3 foam_color : source_color = vec3(0.72, 0.96, 0.88);
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D water_microdetail : source_color, repeat_enable,
	filter_linear_mipmap_anisotropic;
uniform vec2 cinematic_curve_focus_xz = vec2(0.0);
uniform float cinematic_curve_surface_y = 0.0;
uniform float cinematic_curve_radius = 12000000.0;
uniform float cinematic_curve_strength : hint_range(0.0, 1.0) = 0.0;
uniform float cinematic_curve_cap_radius = 1000000000.0;
uniform vec3 cinematic_render_surface = vec3(0.0);
uniform float cinematic_render_radius = 12000000.0;
// (world x, world z, current radius, fading strength), supplied by WaterFX.
uniform vec4 ripple_data[MAX_RIPPLES];
uniform int ripple_count = 0;

varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 rendered_view_position;
varying float wave_height;
varying float ripple_crest;

vec3 curved_planet_position(vec3 flat_position) {
	float physical_radius = max(cinematic_curve_radius, 1.0);
	float render_radius = max(cinematic_render_radius, 0.001);
	vec2 offset = flat_position.xz - cinematic_curve_focus_xz;
	float planar_distance = length(offset);
	vec2 direction = planar_distance > 0.0001
		? offset / planar_distance : vec2(1.0, 0.0);
	float angle = min(planar_distance / physical_radius, 3.135);
	vec3 centre = cinematic_render_surface - vec3(0.0, render_radius, 0.0);
	vec3 radial = vec3(direction.x * sin(angle), cos(angle),
		direction.y * sin(angle));
	float render_height = (flat_position.y - cinematic_curve_surface_y)
		* render_radius / physical_radius;
	return mix(flat_position, cinematic_render_surface + vec3(
		radial.x * (render_radius + render_height),
		-2.0 * pow(sin(angle * 0.5), 2.0) * render_radius
			+ radial.y * render_height,
		radial.z * (render_radius + render_height)),
		cinematic_curve_strength);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 d0 = normalize(vec2(0.86, 0.51));
	vec2 d1 = normalize(vec2(-0.37, 0.93));
	vec2 d2 = normalize(vec2(0.55, -0.84));
	vec2 d3 = normalize(vec2(-0.91, -0.42));
	float p0 = dot(wp.xz, d0) * 0.34 + TIME * 1.12;
	float p1 = dot(wp.xz, d1) * 0.49 - TIME * 1.43;
	float p2 = dot(wp.xz, d2) * 0.73 + TIME * 1.86;
	float p3 = dot(wp.xz, d3) * 1.12 - TIME * 2.30;
	float h0 = sin(p0) * 0.044;
	float h1 = sin(p1) * 0.027;
	float h2 = sin(p2) * 0.016;
	float h3 = sin(p3) * 0.008;
	float slope_x = cos(p0) * 0.044 * 0.34 * d0.x
		+ cos(p1) * 0.027 * 0.49 * d1.x
		+ cos(p2) * 0.016 * 0.73 * d2.x
		+ cos(p3) * 0.008 * 1.12 * d3.x;
	float slope_z = cos(p0) * 0.044 * 0.34 * d0.y
		+ cos(p1) * 0.027 * 0.49 * d1.y
		+ cos(p2) * 0.016 * 0.73 * d2.y
		+ cos(p3) * 0.008 * 1.12 * d3.y;

	float interaction_height = 0.0;
	float interaction_crest = 0.0;
	for (int i = 0; i < MAX_RIPPLES; i++) {
		if (i >= ripple_count) {
			break;
		}
		vec4 ripple = ripple_data[i];
		float distance_to_center = length(wp.xz - ripple.xy);
		float width = 0.12 + ripple.z * 0.045;
		float offset = (distance_to_center - ripple.z) / width;
		float ring = exp(-offset * offset) * ripple.w;
		interaction_height += ring * 0.032;
		interaction_crest = max(interaction_crest, ring);
	}

	float height = h0 + h1 + h2 + h3 + interaction_height;
	wave_height = (h0 + h1 + h2 + h3) / 0.095;
	ripple_crest = interaction_crest;
	VERTEX.y += height;
	world_pos = wp + vec3(0.0, height, 0.0);
	world_normal = normalize(vec3(-slope_x, 1.0, -slope_z));
	NORMAL = world_normal;
	// Keep source coordinates for waves/UVs, but shade at the position that is
	// actually rasterized. Overriding only POSITION left fragment VERTEX/VIEW at
	// the uncurved water plane and produced false depth/foam bands during flight.
	vec3 rendered_world_position = world_pos;
	if (cinematic_curve_strength > 0.0001) {
		rendered_world_position = curved_planet_position(world_pos);
		// POSITION alone does not update Godot's fragment VERTEX/VIEW. Keep
		// built-in fog, light attenuation and shadow coordinates on the same cap.
		VERTEX = (inverse(MODEL_MATRIX) * vec4(rendered_world_position, 1.0)).xyz;
	}
	rendered_view_position = (VIEW_MATRIX * vec4(rendered_world_position, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * vec4(rendered_view_position, 1.0);
}

void fragment() {
	if (cinematic_curve_strength > 0.0001) {
		if (distance(world_pos.xz, cinematic_curve_focus_xz)
				> cinematic_curve_cap_radius) { discard; }
	}
	// Two crossed samples reuse the shared mipmapped satellite detail as a
	// subtle moving slope field. Mip filtering keeps it quiet at grazing angles.
	vec2 detail_uv_a = world_pos.xz * 0.035
		+ vec2(TIME * 0.012, -TIME * 0.009);
	vec2 detail_uv_b = world_pos.zx * 0.070
		+ vec2(-TIME * 0.018, TIME * 0.014);
	float detail_a = texture(water_microdetail, detail_uv_a).r;
	float detail_b = texture(water_microdetail, detail_uv_b).r;
	float mapped_detail = detail_a * 0.62 + detail_b * 0.38;
	vec2 micro_slope = vec2(0.80, 0.60) * (detail_a - 0.5)
		+ vec2(-0.66, 0.75) * (detail_b - 0.5);
	vec3 detailed_world_normal = normalize(world_normal
		+ vec3(micro_slope.x, 0.0, micro_slope.y) * 0.055);
	NORMAL = normalize((VIEW_MATRIX * vec4(detailed_world_normal, 0.0)).xyz);

	float raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	// The voyage camera sees 100 km. A 1e-4 floor clipped reconstructed depth
	// at 10 km and produced a straight false-shallow-water contour in the cap.
	scene_view.xyz /= max(scene_view.w, 0.00000001);
	float water_depth = max((-scene_view.z) - (-rendered_view_position.z), 0.0);
	float absorption = 1.0 - exp(-water_depth * 0.42);
	vec3 rendered_view_direction = normalize(-rendered_view_position);
	float fresnel = pow(1.0 - clamp(dot(NORMAL, rendered_view_direction), 0.0, 1.0), 4.0);
	vec2 refract_offset = detailed_world_normal.xz * 0.010
		* clamp(water_depth * 0.75, 0.0, 1.0);
	vec2 refract_uv = clamp(SCREEN_UV + refract_offset, vec2(0.002), vec2(0.998));
	vec3 refracted = textureLod(screen_texture, refract_uv, 0.0).rgb;
	vec3 water = mix(shallow_color, deep_color, clamp(absorption * 0.88, 0.0, 1.0));
	float texture_variation = mix(0.94, 1.05, mapped_detail);
	water *= texture_variation;

	float crest = smoothstep(0.52, 0.95, wave_height);
	float shore = (1.0 - smoothstep(0.06, 0.72, water_depth))
		* smoothstep(0.42, 0.80, mapped_detail);
	float foam_breakup = mix(0.76, 1.12,
		smoothstep(0.38, 0.84, mapped_detail));
	float foam = clamp((crest * 0.26 + shore * 0.72) * foam_breakup
		+ ripple_crest * 0.48, 0.0, 1.0);
	vec3 refracted_water = mix(refracted, water, 0.32 + absorption * 0.56);
	ALBEDO = mix(refracted_water, foam_color, foam);
	ALBEDO += shallow_color * fresnel * 0.34;
	METALLIC = 0.02;
	SPECULAR = 0.96;
	ROUGHNESS = mix(0.24, 0.045, fresnel) + foam * 0.24;
	EMISSION = foam_color * foam * 0.055;
	ALPHA = clamp(0.72 + absorption * 0.23 + fresnel * 0.05, 0.72, 0.98);
}
"""

const ROCK_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 object_pos;

float hash31(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 53.539))) * 43758.5453);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	object_pos = VERTEX;
}

void fragment() {
	float grain = hash31(floor(world_pos * 2.8));
	float bands = sin((object_pos.x + object_pos.y * 0.7 + object_pos.z) * 7.0) * 0.5 + 0.5;
	vec3 stone = mix(vec3(0.32, 0.39, 0.36), vec3(0.58, 0.62, 0.55), grain * 0.65 + bands * 0.18);
	float moss = smoothstep(0.45, 0.82, world_normal.y) * hash31(floor(world_pos * 0.7));
	vec3 rock = mix(stone, vec3(0.20, 0.40, 0.13), moss * 0.52);
	float alt_snow = smoothstep(3000.0, 4300.0, world_pos.y);
	float snow = max(snow_amount, alt_snow)
		* smoothstep(0.38, 0.78, world_normal.y)
		* smoothstep(0.18, 0.90, grain);
	ALBEDO = mix(rock, vec3(0.78, 0.86, 0.92), snow);
	ROUGHNESS = 0.91;
	SPECULAR = 0.25;
	AO = 0.84;
	RIM = 0.08;
}
"""

const FUR_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.48, 0.31, 0.17);
varying vec3 object_pos;
varying vec3 world_pos;

float hash31(vec3 p) {
	return fract(sin(dot(p, vec3(17.17, 43.71, 91.13))) * 43758.5453);
}

void vertex() {
	object_pos = VERTEX;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float tuft = hash31(floor(object_pos * 34.0));
	float vertical = 0.90 + clamp(object_pos.y, -0.5, 0.5) * 0.12;
	vec3 fur = base_color * mix(0.73, 1.18, tuft) * vertical;
	ALBEDO = fur;
	ROUGHNESS = 0.86;
	SPECULAR = 0.25;
	RIM = 0.48;
	RIM_TINT = 0.68;
	EMISSION = base_color * pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 3.0) * 0.035;
}
"""

const SKIN_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.91, 0.76, 0.60);

void fragment() {
	ALBEDO = base_color;
	ROUGHNESS = 0.68;
	SPECULAR = 0.42;
	RIM = 0.24;
	RIM_TINT = 0.62;
	SSS_STRENGTH = 0.16;
	BACKLIGHT = base_color * 0.10;
}
"""

const BANANA_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

void fragment() {
	float pulse = 0.72 + sin(TIME * 3.2) * 0.18;
	ALBEDO = vec3(1.0, 0.73, 0.055);
	ROUGHNESS = 0.48;
	SPECULAR = 0.46;
	RIM = 0.58;
	RIM_TINT = 0.7;
	EMISSION = vec3(0.95, 0.46, 0.035) * pulse * 0.42;
}
"""

const ENEMY_OUTLINE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never;

uniform vec4 outline_color : source_color = vec4(1.0, 0.24, 0.055, 1.0);
uniform float outline_width : hint_range(0.0, 0.08) = 0.032;

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	EMISSION = outline_color.rgb * 1.7;
}
"""


static func _material(code: String, params := {}) -> ShaderMaterial:
	var shader: Shader = _shaders_by_source.get(code)
	if shader == null:
		shader = Shader.new()
		shader.code = code
		_shaders_by_source[code] = shader
	var material := ShaderMaterial.new()
	material.shader = shader
	for key in params:
		material.set_shader_parameter(key, params[key])
	return material


static func ground_material() -> ShaderMaterial:
	if not _shared.has("ground"):
		_shared.ground = _material(GROUND_SHADER, {
			"snow_amount": _snow_amount,
			"terrain_microdetail": TERRAIN_MICRODETAIL,
			"terrain_floor_albedo": TERRAIN_FLOOR_ALBEDO,
		})
	return _shared.ground


static func trunk_material() -> ShaderMaterial:
	if not _shared.has("trunk"):
		_shared.trunk = _material(TRUNK_SHADER, {"snow_amount": _snow_amount})
	return _shared.trunk


static func grass_material() -> ShaderMaterial:
	if not _shared.has("grass"):
		_shared.grass = _material(GRASS_SHADER, {"snow_amount": _snow_amount})
	return _shared.grass


static func water_material() -> ShaderMaterial:
	if not _shared.has("water"):
		_shared.water = _material(WATER_SHADER,
			{"water_microdetail": TERRAIN_MICRODETAIL})
	return _shared.water


## CPU twin of WATER_SHADER's four broad waves. Gameplay buoyancy can use this
## to ride the rendered surface; local WaterFX ripple displacement is omitted
## intentionally because it is short-lived visual feedback, not a force.
static func water_surface_y(x: float, z: float, time_seconds: float) -> float:
	var world_xz := Vector2(x, z)
	var d0 := Vector2(0.86, 0.51).normalized()
	var d1 := Vector2(-0.37, 0.93).normalized()
	var d2 := Vector2(0.55, -0.84).normalized()
	var d3 := Vector2(-0.91, -0.42).normalized()
	return Gen.WATER_Y \
		+ sin(world_xz.dot(d0) * 0.34 + time_seconds * 1.12) * 0.044 \
		+ sin(world_xz.dot(d1) * 0.49 - time_seconds * 1.43) * 0.027 \
		+ sin(world_xz.dot(d2) * 0.73 + time_seconds * 1.86) * 0.016 \
		+ sin(world_xz.dot(d3) * 1.12 - time_seconds * 2.30) * 0.008


static func rock_material() -> ShaderMaterial:
	if not _shared.has("rock"):
		_shared.rock = _material(ROCK_SHADER, {"snow_amount": _snow_amount})
	return _shared.rock


static func vine_material(wind_strength := 0.0) -> ShaderMaterial:
	var key := "vine_%.3f" % wind_strength
	if not _shared.has(key):
		_shared[key] = _material(VINE_SHADER, {"wind_strength": wind_strength})
	return _shared[key]


static func foliage_material(color: Color) -> ShaderMaterial:
	var quantized := Color(
		snappedf(color.r, 0.04), snappedf(color.g, 0.04), snappedf(color.b, 0.04), 1.0)
	var key := quantized.to_html(false)
	if not _foliage.has(key):
		_foliage[key] = _material(FOLIAGE_SHADER, {
			"base_color": quantized,
			"spring_amount": _spring_amount,
			"autumn_amount": _autumn_amount,
			"snow_amount": _snow_amount,
		})
	return _foliage[key]


static func foliage_lod_material() -> ShaderMaterial:
	if not _shared.has("foliage_lod"):
		_shared.foliage_lod = _material(FOLIAGE_LOD_SHADER, {
			"spring_amount": _spring_amount,
			"autumn_amount": _autumn_amount,
			"snow_amount": _snow_amount,
		})
	return _shared.foliage_lod


static func far_ground_material() -> ShaderMaterial:
	if not _shared.has("far_ground"):
		_shared.far_ground = _material(FAR_GROUND_SHADER,
			{"near_fade": Gen.HORIZON_NEAR_FADE,
				"fade_band": 18.0,
				"far_fade": _skyline_near_fade,
				"far_fade_band": 96.0,
				"snow_amount": _snow_amount,
				"terrain_microdetail": TERRAIN_MICRODETAIL,
				"earth_cinematic_atlas": EARTH_CINEMATIC_ATLAS})
	return _shared.far_ground


## Fourth-tier stratos material: a canopy-aware satellite shader with its
## handoff pushed inside the skyline ring and a wide 192 m-cell dither band.
static func stratos_ground_material() -> ShaderMaterial:
	if not _shared.has("stratos_ground"):
		_shared.stratos_ground = _material(STRATOS_GROUND_SHADER,
			{"near_fade": _stratos_near_fade,
				"fade_band": 220.0,
				"far_fade": _stratos_far_fade,
				"far_fade_band": 420.0,
				"snow_amount": _snow_amount,
				"terrain_microdetail": TERRAIN_MICRODETAIL,
				"earth_cinematic_atlas": EARTH_CINEMATIC_ATLAS})
	return _shared.stratos_ground


## Ultra-far skyline tier: the same shader as the horizon shell but with its
## dithered handoff pushed out to the horizon-ring edge and widened to match
## the 48 m skyline cells, so mountain silhouettes take over seamlessly.
static func skyline_ground_material() -> ShaderMaterial:
	if not _shared.has("skyline_ground"):
		_shared.skyline_ground = _material(FAR_GROUND_SHADER,
			{"near_fade": _skyline_near_fade,
				"fade_band": 96.0,
				"far_fade": _stratos_near_fade,
				"far_fade_band": 220.0,
				"snow_amount": _snow_amount,
				"terrain_microdetail": TERRAIN_MICRODETAIL,
				"earth_cinematic_atlas": EARTH_CINEMATIC_ATLAS})
	return _shared.skyline_ground


static func far_jungle_material() -> ShaderMaterial:
	if not _shared.has("far_jungle"):
		_shared.far_jungle = _material(FAR_JUNGLE_SHADER,
			{"near_fade": Gen.HORIZON_NEAR_FADE,
				"fade_band": 18.0,
				"far_fade": _skyline_near_fade,
				"far_fade_band": 96.0,
				"spring_amount": _spring_amount,
				"autumn_amount": _autumn_amount,
				"snow_amount": _snow_amount})
	return _shared.far_jungle


## Skyline-tier tree silhouettes: same jungle shader, but the dithered handoff
## sits at the horizon ring's guaranteed tree coverage so skyline crowns take
## over exactly where the denser horizon silhouettes are retired.
static func skyline_jungle_material() -> ShaderMaterial:
	if not _shared.has("skyline_jungle"):
		_shared.skyline_jungle = _material(FAR_JUNGLE_SHADER,
			{"near_fade": _skyline_near_fade,
				"fade_band": 96.0,
				"far_fade": _stratos_near_fade,
				"far_fade_band": 220.0,
				"spring_amount": _spring_amount,
				"autumn_amount": _autumn_amount,
				"snow_amount": _snow_amount})
	return _shared.skyline_jungle


static func far_water_material() -> ShaderMaterial:
	if not _shared.has("far_water"):
		_shared.far_water = _material(FAR_WATER_SHADER,
			{"near_fade": WATER_HANDOFF_DISTANCE,
				"fade_band": WATER_HANDOFF_BAND,
				"far_fade": _skyline_near_fade,
				"far_fade_band": 96.0,
				"water_microdetail": TERRAIN_MICRODETAIL})
	return _shared.far_water


static func skyline_water_material() -> ShaderMaterial:
	if not _shared.has("skyline_water"):
		_shared.skyline_water = _material(FAR_WATER_SHADER,
			{"near_fade": _skyline_near_fade,
				"fade_band": 96.0,
				"far_fade": _stratos_near_fade,
				"far_fade_band": 220.0,
				"water_microdetail": TERRAIN_MICRODETAIL})
	return _shared.skyline_water


## Keep adjacent terrain/water/canopy tiers mathematically complementary. At
## each boundary the incoming layer retains hash <= transition while the
## outgoing layer retains hash > transition, so there is neither a hole nor a
## double-rendered band. High-altitude callers can pass zero so the successor
## fully covers the under-aircraft view after a lower tier becomes invisible.
static func set_altitude_lod_handoffs(skyline_near: float,
		stratos_near: float) -> void:
	var next_skyline_near := maxf(skyline_near, 0.0)
	var next_stratos_near := maxf(stratos_near, 0.0)
	if is_equal_approx(next_skyline_near, _skyline_near_fade) \
			and is_equal_approx(next_stratos_near, _stratos_near_fade):
		return
	_skyline_near_fade = next_skyline_near
	_stratos_near_fade = next_stratos_near
	var skyline_band := 18.0 if _skyline_near_fade \
		<= Gen.HORIZON_NEAR_FADE + 0.5 else 96.0
	var stratos_band := 24.0 if _stratos_near_fade \
		<= Gen.HORIZON_NEAR_FADE + 0.5 else 220.0
	for material in [far_ground_material(), far_jungle_material(),
			far_water_material()]:
		material.set_shader_parameter("far_fade", _skyline_near_fade)
		material.set_shader_parameter("far_fade_band", skyline_band)
	for material in [skyline_ground_material(), skyline_jungle_material(),
			skyline_water_material()]:
		material.set_shader_parameter("near_fade", _skyline_near_fade)
		material.set_shader_parameter("fade_band", skyline_band)
		material.set_shader_parameter("far_fade", _stratos_near_fade)
		material.set_shader_parameter("far_fade_band", stratos_band)
	stratos_ground_material().set_shader_parameter("near_fade",
		_stratos_near_fade)
	stratos_ground_material().set_shader_parameter("fade_band", stratos_band)


## Circular stratos target selection is padded by whole 6.144 km sectors. Fade
## the final cells against the atmosphere at the exact requested radius so the
## padded sectors never reveal a square outer edge.
static func set_stratos_view_radius(radius: float) -> void:
	var next_radius := maxf(radius, Gen.VIEW_BASE_DISTANCE)
	if is_equal_approx(next_radius, _stratos_far_fade):
		return
	_stratos_far_fade = next_radius
	stratos_ground_material().set_shader_parameter("far_fade", next_radius)
	stratos_ground_material().set_shader_parameter("far_fade_band",
		clampf(next_radius * 0.025, 180.0, 520.0))


## CelestialSky already renders both hemispheres of its inward-facing sky. This
## palette keeps that lower hemisphere atmospheric when aircraft can see below
## the terrain horizon: the old near-black nadir became a conspicuous dark spot
## at altitude. Ground-level color remains earthy and the transition is smooth.
static func full_sphere_nadir_palette(sky_top: Color, sky_horizon: Color,
		daylight_amount: float, ground_clearance: float) -> Dictionary:
	var altitude_blend := smoothstep(180.0, 1800.0,
		maxf(ground_clearance, 0.0))
	var ground_bottom := Color(0.018, 0.050, 0.125).lerp(
		Color(0.10, 0.22, 0.16), daylight_amount)
	var ground_horizon := Color(0.038, 0.105, 0.205).lerp(
		Color(0.30, 0.48, 0.34), daylight_amount)
	# Looking through the deep atmosphere toward the planet is slightly darker
	# than the horizontal limb, but never black or green at aircraft altitude.
	var atmospheric_nadir := sky_top.lerp(sky_horizon, 0.62).darkened(
		lerpf(0.08, 0.16, daylight_amount))
	ground_bottom = ground_bottom.lerp(atmospheric_nadir,
		0.18 + altitude_blend * 0.78)
	ground_horizon = ground_horizon.lerp(sky_horizon,
		0.66 + altitude_blend * 0.31)
	return {"bottom": ground_bottom, "horizon": ground_horizon,
		"altitude_blend": altitude_blend}


static func set_far_focus(position: Vector3) -> void:
	var focus := Vector2(position.x, position.z)
	# The three horizon shaders share a focus point used only for their broad
	# cross-fade. Sub-pixel player movement does not change that transition, so
	# avoid three render-server uniform updates on every 120-160 Hz frame.
	if _far_focus.distance_squared_to(focus) < 0.0625:
		return
	_far_focus = focus
	for material in [far_ground_material(), far_jungle_material(),
			far_water_material(), skyline_ground_material(), skyline_water_material(),
			skyline_jungle_material(), stratos_ground_material()]:
		material.set_shader_parameter("focus_xz", focus)


## Render-only spherical projection used by the launch cinematic. Gameplay,
## collision and deterministic terrain sampling stay on the stable tangent
## chart; the shared terrain materials bend those same vertices around the
## continuously opaque Earth while the cached chunks remain resident.
static func set_cinematic_earth_curvature(focus_xz: Vector2,
		surface_y: float, radius: float, strength: float,
		cap_radius := 1_000_000_000.0,
		render_surface := Vector3.ZERO, render_radius := -1.0) -> void:
	var next_radius := maxf(radius, 1.0)
	var next_strength := clampf(strength, 0.0, 1.0)
	var next_cap_radius := maxf(float(cap_radius), 0.0)
	var next_render_surface := Vector3(focus_xz.x, surface_y, focus_xz.y) \
		if float(render_radius) <= 0.0 else Vector3(render_surface)
	var next_render_radius := next_radius if float(render_radius) <= 0.0 \
		else maxf(float(render_radius), 0.001)
	# Resource imports and editor reloads can recreate one of these shared
	# materials without changing the numeric cinematic pose. Reconcile live RIDs
	# before the equality early-return, then force a one-time full uniform sync if
	# any reference changed. Otherwise a warmed full flight can leave only that
	# recreated tier flat while a direct-start preview appears correct.
	var live_ground := ground_material()
	var live_far_ground := far_ground_material()
	var live_skyline_ground := skyline_ground_material()
	var live_stratos_ground := stratos_ground_material()
	var live_water := water_material()
	var live_far_water := far_water_material()
	var live_skyline_water := skyline_water_material()
	var materials_changed := _cinematic_materials.size() != 7
	if not materials_changed:
		materials_changed = _cinematic_materials[0] != live_ground \
			or _cinematic_materials[1] != live_far_ground \
			or _cinematic_materials[2] != live_skyline_ground \
			or _cinematic_materials[3] != live_stratos_ground \
			or _cinematic_materials[4] != live_water \
			or _cinematic_materials[5] != live_far_water \
			or _cinematic_materials[6] != live_skyline_water
	if materials_changed:
		# Allocate this seven-reference list only when a resource actually changes,
		# never on the ordinary per-frame cinematic update path.
		_cinematic_materials.assign([live_ground, live_far_ground,
			live_skyline_ground, live_stratos_ground, live_water,
			live_far_water, live_skyline_water])
	# The physical climb holds identical values for long stretches. Avoid a new
	# set of 49 render-server uniform writes on every identical tick.
	if not materials_changed \
			and _cinematic_curve_focus.distance_squared_to(focus_xz) < 0.000001 \
			and is_equal_approx(_cinematic_curve_surface_y, surface_y) \
			and is_equal_approx(_cinematic_curve_radius, next_radius) \
			and is_equal_approx(_cinematic_curve_strength, next_strength) \
			and is_equal_approx(_cinematic_curve_cap_radius, next_cap_radius) \
			and _cinematic_render_surface.distance_squared_to(
				next_render_surface) < 0.000001 \
			and is_equal_approx(_cinematic_render_radius, next_render_radius):
		return
	_cinematic_curve_focus = focus_xz
	_cinematic_curve_surface_y = surface_y
	_cinematic_curve_radius = next_radius
	_cinematic_curve_strength = next_strength
	_cinematic_curve_cap_radius = next_cap_radius
	_cinematic_render_surface = next_render_surface
	_cinematic_render_radius = next_render_radius
	for material in _cinematic_materials:
		material.set_shader_parameter("cinematic_curve_focus_xz", focus_xz)
		material.set_shader_parameter("cinematic_curve_surface_y", surface_y)
		material.set_shader_parameter("cinematic_curve_radius",
			_cinematic_curve_radius)
		material.set_shader_parameter("cinematic_curve_strength",
			_cinematic_curve_strength)
		material.set_shader_parameter("cinematic_curve_cap_radius",
			_cinematic_curve_cap_radius)
		material.set_shader_parameter("cinematic_render_surface",
			_cinematic_render_surface)
		material.set_shader_parameter("cinematic_render_radius",
			_cinematic_render_radius)


static func clear_cinematic_earth_curvature() -> void:
	set_cinematic_earth_curvature(_cinematic_curve_focus,
		_cinematic_curve_surface_y, _cinematic_curve_radius, 0.0,
		1_000_000_000.0)


## CPU twin for deterministic tests and camera/tangent diagnostics.
static func cinematic_earth_surface_point(flat_world_position: Vector3) -> Vector3:
	if _cinematic_curve_strength <= 0.0:
		return flat_world_position
	var offset := Vector2(flat_world_position.x,
		flat_world_position.z) - _cinematic_curve_focus
	var planar_distance := offset.length()
	var direction := offset / planar_distance if planar_distance > 0.0001 \
		else Vector2.RIGHT
	var angle := minf(planar_distance / _cinematic_curve_radius, PI - 0.006)
	var radial := Vector3(direction.x * sin(angle), cos(angle),
		direction.y * sin(angle))
	# Match the shader's scaled-space transform without subtracting two planet-
	# sized Y coordinates. Float32 loses metre-scale terrain at Earth's radius.
	var render_height := (flat_world_position.y - _cinematic_curve_surface_y) \
		* _cinematic_render_radius / _cinematic_curve_radius
	var curved := _cinematic_render_surface + Vector3(
		radial.x * (_cinematic_render_radius + render_height),
		-2.0 * pow(sin(angle * 0.5), 2.0) * _cinematic_render_radius \
			+ radial.y * render_height,
		radial.z * (_cinematic_render_radius + render_height))
	return flat_world_position.lerp(curved, _cinematic_curve_strength)


## Season changes update the small set of shared materials in place. Existing
## chunk and horizon MultiMeshes immediately pick up the new palette without
## rebuilding geometry, duplicating materials, or touching instance colours.
static func set_season(season: SeasonalCycle.Season) -> void:
	_spring_amount = 1.0 if season == SeasonalCycle.Season.SPRING else 0.0
	_autumn_amount = 1.0 if season == SeasonalCycle.Season.AUTUMN else 0.0
	_snow_amount = 1.0 if season == SeasonalCycle.Season.WINTER else 0.0

	for material in [ground_material(), trunk_material(), grass_material(),
			rock_material(), far_ground_material(), skyline_ground_material(),
			stratos_ground_material()]:
		material.set_shader_parameter("snow_amount", _snow_amount)
	for material in [foliage_lod_material(), far_jungle_material(),
			skyline_jungle_material()]:
		_apply_foliage_season(material)
	for material in _foliage.values():
		_apply_foliage_season(material)


static func season_amounts() -> Vector3:
	return Vector3(_spring_amount, _autumn_amount, _snow_amount)


static func _apply_foliage_season(material: ShaderMaterial) -> void:
	material.set_shader_parameter("spring_amount", _spring_amount)
	material.set_shader_parameter("autumn_amount", _autumn_amount)
	material.set_shader_parameter("snow_amount", _snow_amount)


static func fur_material(color: Color) -> ShaderMaterial:
	var key := color.to_html(false)
	if not _fur.has(key):
		_fur[key] = _material(FUR_SHADER, {"base_color": color})
	return _fur[key]


static func skin_material() -> ShaderMaterial:
	if not _shared.has("skin"):
		_shared.skin = _material(SKIN_SHADER, {"base_color": Color(0.91, 0.76, 0.60)})
	return _shared.skin


static func banana_material() -> ShaderMaterial:
	if not _shared.has("banana"):
		_shared.banana = _material(BANANA_SHADER)
	return _shared.banana


static func enemy_outline_material() -> ShaderMaterial:
	if not _shared.has("enemy_outline"):
		_shared.enemy_outline = _material(ENEMY_OUTLINE_SHADER)
	return _shared.enemy_outline
