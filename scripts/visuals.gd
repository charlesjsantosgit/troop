class_name Visuals
extends RefCounted
## Shared procedural shader library. Materials are cached so the streamed world
## gets richer lighting and motion without creating a shader per mesh instance.

static var _shared: Dictionary = {}
static var _foliage: Dictionary = {}
static var _fur: Dictionary = {}
static var _far_focus := Vector2(INF, INF)
static var _spring_amount := 0.0
static var _autumn_amount := 0.0
static var _snow_amount := 0.0

const GROUND_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
varying vec3 world_pos;
varying vec3 world_normal;
varying vec4 vertex_tint;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	vertex_tint = COLOR;
}

void fragment() {
	float broad = hash21(floor(world_pos.xz * 0.18));
	float fine = hash21(floor(world_pos.xz * 1.4));
	float slope = 1.0 - clamp(world_normal.y, 0.0, 1.0);
	float mottled = mix(0.82, 1.13, broad) * mix(0.93, 1.06, fine);
	vec3 earth = vec3(0.20, 0.14, 0.075);
	vec3 base = vertex_tint.rgb * mottled * 0.66;
	base = mix(base, earth, slope * 0.28);
	float damp = smoothstep(0.75, 0.2, world_pos.y);
	vec3 ground = mix(base, base * vec3(0.58, 0.72, 0.68), damp * 0.35);
	// Let soil texture and broad terrain variation remain legible below the
	// accumulation.  Fully replacing the ground with a flat near-white made
	// winter hills clip into one featureless value under the noon sun.
	// Permanent altitude snow joins seasonal snow: peaks stay white all year,
	// matching the rock/snow bands the vertex tint already carries.
	float alt_snow = smoothstep(26.0, 40.0, world_pos.y);
	float snow = max(snow_amount * smoothstep(0.28, 0.72, world_normal.y),
		alt_snow * smoothstep(0.20, 0.65, world_normal.y))
		* mix(0.70, 0.92, fine);
	vec3 snow_color = vec3(0.70, 0.77, 0.82)
		* mix(0.88, 1.08, broad) * mix(0.94, 1.03, fine);
	ALBEDO = mix(ground, snow_color, snow);
	ROUGHNESS = mix(mix(0.96, 0.72, damp), 0.62, snow);
	SPECULAR = 0.18;
	AO = 0.78 + fine * 0.18;
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
	RIM = 0.34;
	RIM_TINT = 0.58;
	EMISSION = leaf_color * pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 3.0) * 0.028;
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
	RIM = 0.32;
	RIM_TINT = 0.58;
	EMISSION = leaf_color * pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 3.0) * 0.024;
}
"""

const FAR_GROUND_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec2 focus_xz = vec2(0.0);
uniform float near_fade = 108.0;
uniform float fade_band = 18.0;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
varying vec3 world_pos;
varying vec4 vertex_tint;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vertex_tint = COLOR;
}

void fragment() {
	float distance_to_focus = distance(world_pos.xz, focus_xz);
	float coverage = smoothstep(near_fade - fade_band, near_fade + fade_band,
		distance_to_focus);
	if (hash21(floor(world_pos.xz * 0.36)) > coverage) { discard; }
	vec3 ground = vertex_tint.rgb * 0.84;
	float snow_noise = hash21(floor(world_pos.xz * 0.12));
	float alt_snow = smoothstep(26.0, 40.0, world_pos.y);
	float snow = max(snow_amount, alt_snow) * mix(0.68, 0.90, snow_noise);
	vec3 snow_color = vec3(0.68, 0.75, 0.81)
		* mix(0.90, 1.07, snow_noise);
	ALBEDO = mix(ground, snow_color, snow);
	ROUGHNESS = 0.98;
	SPECULAR = 0.10;
	AO = 0.88;
}
"""

const STRATOS_GROUND_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec2 focus_xz = vec2(0.0);
uniform float near_fade = 1700.0;
uniform float fade_band = 220.0;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
varying vec3 world_pos;
varying vec4 vertex_tint;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vertex_tint = COLOR;
}

void fragment() {
	float distance_to_focus = distance(world_pos.xz, focus_xz);
	float coverage = smoothstep(near_fade - fade_band, near_fade + fade_band,
		distance_to_focus);
	if (hash21(floor(world_pos.xz * 0.018)) > coverage) { discard; }

	// COLOR.a carries deterministic canopy coverage. Broad 64/190 m patches
	// survive at aircraft distance, unlike literal crowns that become sub-pixel.
	float canopy = clamp(vertex_tint.a, 0.0, 1.0);
	float broad = hash21(floor(world_pos.xz / 190.0));
	float crown = hash21(floor(world_pos.xz / 64.0));
	float canopy_light = mix(0.72, 1.10, broad) * mix(0.88, 1.08, crown);
	vec3 ground = vertex_tint.rgb * 0.84;
	vec3 forest = vertex_tint.rgb * canopy_light;
	vec3 shaded = mix(ground, forest, canopy * 0.82);

	float snow_noise = hash21(floor(world_pos.xz * 0.012));
	float alt_snow = smoothstep(26.0, 40.0, world_pos.y);
	float snow = max(snow_amount, alt_snow) * mix(0.68, 0.90, snow_noise);
	vec3 snow_color = vec3(0.68, 0.75, 0.81) * mix(0.90, 1.07, snow_noise);
	ALBEDO = mix(shaded, snow_color, snow);
	ROUGHNESS = mix(0.98, 0.91, canopy);
	SPECULAR = mix(0.10, 0.13, canopy);
	AO = mix(0.88, 0.78, canopy);
}
"""

const FAR_JUNGLE_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec2 focus_xz = vec2(0.0);
uniform float near_fade = 108.0;
uniform float fade_band = 18.0;
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
	float coverage = smoothstep(near_fade - fade_band, near_fade + fade_band,
		distance_to_focus);
	if (hash21(floor(world_pos.xz * 0.42)) > coverage) { discard; }
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
varying vec3 world_pos;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(41.17, 289.31))) * 43758.5453);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += sin(wp.x * 0.055 + TIME * 0.62) * 0.055;
	VERTEX.y += sin(wp.z * 0.071 - TIME * 0.47) * 0.035;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float distance_to_focus = distance(world_pos.xz, focus_xz);
	float coverage = smoothstep(near_fade - 16.0, near_fade + 16.0,
		distance_to_focus);
	if (hash21(floor(world_pos.xz * 0.25)) > coverage) { discard; }
	float ripple = sin(world_pos.x * 0.08 + world_pos.z * 0.05 + TIME) * 0.5 + 0.5;
	ALBEDO = mix(vec3(0.035, 0.24, 0.24), vec3(0.065, 0.42, 0.36), ripple * 0.18);
	ROUGHNESS = 0.48;
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
// (world x, world z, current radius, fading strength), supplied by WaterFX.
uniform vec4 ripple_data[MAX_RIPPLES];
uniform int ripple_count = 0;

varying vec3 world_pos;
varying vec3 world_normal;
varying float wave_height;
varying float ripple_crest;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(cell);
	float b = hash21(cell + vec2(1.0, 0.0));
	float c = hash21(cell + vec2(0.0, 1.0));
	float d = hash21(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
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
}

void fragment() {
	// Two crossing, scrolling detail fields break up the broad waves without an
	// imported normal texture. Transform the resulting world normal into view
	// space so highlights remain stable as the camera turns.
	vec2 detail_uv_a = world_pos.xz * 1.35 + vec2(TIME * 0.11, -TIME * 0.08);
	vec2 detail_uv_b = world_pos.zx * 2.70 + vec2(-TIME * 0.15, TIME * 0.12);
	float detail_a = value_noise(detail_uv_a);
	float detail_b = value_noise(detail_uv_b);
	float micro_x = sin(detail_uv_a.x * 2.7 + detail_b * 3.0) * 0.040;
	float micro_z = cos(detail_uv_b.y * 2.3 + detail_a * 3.4) * 0.040;
	vec3 detailed_world_normal = normalize(world_normal + vec3(micro_x, 0.0, micro_z));
	NORMAL = normalize((VIEW_MATRIX * vec4(detailed_world_normal, 0.0)).xyz);

	float raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	scene_view.xyz /= max(scene_view.w, 0.0001);
	float water_depth = max((-scene_view.z) - (-VERTEX.z), 0.0);
	float absorption = 1.0 - exp(-water_depth * 0.42);
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	vec2 refract_offset = detailed_world_normal.xz * 0.010
		* clamp(water_depth * 0.75, 0.0, 1.0);
	vec2 refract_uv = clamp(SCREEN_UV + refract_offset, vec2(0.002), vec2(0.998));
	vec3 refracted = textureLod(screen_texture, refract_uv, 0.0).rgb;
	vec3 water = mix(shallow_color, deep_color, clamp(absorption * 0.88, 0.0, 1.0));
	float texture_variation = mix(0.91, 1.08, detail_a * 0.62 + detail_b * 0.38);
	water *= texture_variation;

	float crest = smoothstep(0.52, 0.95, wave_height);
	float shore = (1.0 - smoothstep(0.06, 0.72, water_depth))
		* smoothstep(0.25, 0.72, detail_a + detail_b * 0.25);
	float foam = clamp(crest * 0.26 + shore * 0.72 + ripple_crest * 0.48, 0.0, 1.0);
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
	float alt_snow = smoothstep(26.0, 40.0, world_pos.y);
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
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	for key in params:
		material.set_shader_parameter(key, params[key])
	return material


static func ground_material() -> ShaderMaterial:
	if not _shared.has("ground"):
		_shared.ground = _material(GROUND_SHADER, {"snow_amount": _snow_amount})
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
		_shared.water = _material(WATER_SHADER)
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
				"snow_amount": _snow_amount})
	return _shared.far_ground


## Fourth-tier stratos material: a canopy-aware satellite shader with its
## handoff pushed inside the skyline ring and a wide 192 m-cell dither band.
static func stratos_ground_material() -> ShaderMaterial:
	if not _shared.has("stratos_ground"):
		_shared.stratos_ground = _material(STRATOS_GROUND_SHADER,
			{"near_fade": Gen.STRATOS_NEAR_FADE,
				"fade_band": 220.0,
				"snow_amount": _snow_amount})
	return _shared.stratos_ground


## Ultra-far skyline tier: the same shader as the horizon shell but with its
## dithered handoff pushed out to the horizon-ring edge and widened to match
## the 48 m skyline cells, so mountain silhouettes take over seamlessly.
static func skyline_ground_material() -> ShaderMaterial:
	if not _shared.has("skyline_ground"):
		_shared.skyline_ground = _material(FAR_GROUND_SHADER,
			{"near_fade": Gen.SKYLINE_NEAR_FADE,
				"fade_band": 96.0,
				"snow_amount": _snow_amount})
	return _shared.skyline_ground


static func far_jungle_material() -> ShaderMaterial:
	if not _shared.has("far_jungle"):
		_shared.far_jungle = _material(FAR_JUNGLE_SHADER,
			{"near_fade": Gen.HORIZON_NEAR_FADE,
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
			{"near_fade": Gen.HORIZON_DISTANCE - 12.0,
				"fade_band": 44.0,
				"spring_amount": _spring_amount,
				"autumn_amount": _autumn_amount,
				"snow_amount": _snow_amount})
	return _shared.skyline_jungle


static func far_water_material() -> ShaderMaterial:
	if not _shared.has("far_water"):
		_shared.far_water = _material(FAR_WATER_SHADER,
			{"near_fade": Gen.HORIZON_NEAR_FADE})
	return _shared.far_water


static func set_far_focus(position: Vector3) -> void:
	var focus := Vector2(position.x, position.z)
	# The three horizon shaders share a focus point used only for their broad
	# cross-fade. Sub-pixel player movement does not change that transition, so
	# avoid three render-server uniform updates on every 120-160 Hz frame.
	if _far_focus.distance_squared_to(focus) < 0.0625:
		return
	_far_focus = focus
	for material in [far_ground_material(), far_jungle_material(),
			far_water_material(), skyline_ground_material(),
			skyline_jungle_material(), stratos_ground_material()]:
		material.set_shader_parameter("focus_xz", focus)


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
