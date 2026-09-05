shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
varying vec3 shop_position;
varying vec3 shop_normal;

void vertex() {
	shop_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	shop_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float horizontal = abs(shop_normal.z) > 0.5 ? shop_position.x : shop_position.z;
	float height = shop_position.y - 8.0;
	vec2 display_grid = vec2(horizontal * 2.15, height * 1.8);
	vec2 cell = fract(display_grid);
	vec2 aa = max(fwidth(display_grid), vec2(0.004));
	float item = smoothstep(0.16 - aa.x, 0.16 + aa.x, cell.x)
		* (1.0 - smoothstep(0.78 - aa.x, 0.78 + aa.x, cell.x))
		* smoothstep(0.20 - aa.y, 0.20 + aa.y, cell.y)
		* (1.0 - smoothstep(0.77 - aa.y, 0.77 + aa.y, cell.y));
	float seed = fract(sin(dot(floor(display_grid), vec2(83.12, 23.91))) * 3217.1);
	float display_zone = smoothstep(0.5, 0.8, height) * (1.0 - smoothstep(2.6, 2.9, height));
	item *= display_zone;
	vec3 merchandise = mix(vec3(0.28, 0.13, 0.045), vec3(0.31, 0.32, 0.21), seed);
	vec3 interior = mix(vec3(0.035, 0.047, 0.047), merchandise, item * 0.7);
	float shelf = 1.0 - smoothstep(0.025, 0.055 + aa.y, min(cell.y, 1.0 - cell.y));
	interior += vec3(0.09, 0.075, 0.05) * shelf * display_zone;
	ALBEDO = interior + vec3(0.055, 0.075, 0.075);
	ROUGHNESS = 0.28;
	METALLIC = 0.24;
	SPECULAR = 0.35;
	EMISSION = (interior * vec3(1.0, 0.82, 0.57) * 2.2 + vec3(0.07, 0.049, 0.025)) * night_factor;
}
