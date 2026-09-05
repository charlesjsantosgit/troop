shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// Each instanced quad keeps its physical scale while facing the camera.
// Soft turbulent edges avoid opaque spheres and hard particle intersections.
uniform float burning : hint_range(0.0, 1.0) = 0.0;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
varying float puff_seed;
varying vec4 puff_color;

float hash_noise(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float cloud_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash_noise(i), hash_noise(i + vec2(1.0, 0.0)), f.x),
		mix(hash_noise(i + vec2(0.0, 1.0)), hash_noise(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	vec3 size = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(INV_VIEW_MATRIX[0].xyz * size.x, 0.0),
		vec4(INV_VIEW_MATRIX[1].xyz * size.y, 0.0),
		vec4(INV_VIEW_MATRIX[2].xyz * size.z, 0.0), MODEL_MATRIX[3]);
	puff_seed = float(INSTANCE_ID) * 3.713;
	puff_color = COLOR;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	vec2 flow = UV * 4.5 + vec2(puff_seed, -TIME * mix(0.28, 1.0, burning));
	float large = cloud_noise(flow);
	float detail = cloud_noise(flow * 2.13 + vec2(large, puff_seed));
	float wisps = cloud_noise(flow * 4.27);
	float density = large * 0.58 + detail * 0.29 + wisps * 0.13;
	float edge = 1.0 - smoothstep(0.20, 1.0, length(p) + (density - 0.45) * 0.42);
	float volume = edge * smoothstep(0.06, 0.77, density + edge * 0.36);
	float light_side = clamp(0.72 - p.y * 0.18 + density * 0.55, 0.45, 1.45);
	vec3 smoke = puff_color.rgb * light_side;
	float heat = clamp(volume * 0.65 + density * 0.36, 0.0, 1.0);
	vec3 flame = mix(vec3(0.28, 0.025, 0.006), vec3(1.0, 0.21, 0.025), smoothstep(0.10, 0.48, heat));
	flame = mix(flame, vec3(1.0, 0.76, 0.29), smoothstep(0.48, 0.93, heat));
	ALBEDO = mix(smoke, flame * 0.32, burning);
	EMISSION = flame * burning * (0.5 + heat * 1.8);
	ALPHA = clamp(volume * puff_color.a * opacity, 0.0, 0.92);
}
