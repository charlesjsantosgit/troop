shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;

// Every pane is shaded at a physical metre scale. Instances carry a stable
// building seed, facade family and floor spacing; no window nodes/textures.
uniform float district_power[12];
varying vec3 city_position;
varying vec3 city_normal;
varying vec4 facade;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	city_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	city_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	facade = INSTANCE_CUSTOM;
}

void fragment() {
	float family = floor(facade.g * 3.0 + 0.5);
	float floor_height = max(3.2, facade.b * 8.0);
	float horizontal = abs(city_normal.z) > 0.5 ? city_position.x : city_position.z;
	float bay_width = family < 0.5 ? 2.6 : (family < 1.5 ? 1.6 : 2.0);
	vec2 grid = vec2(horizontal / bay_width, (city_position.y - 8.0) / floor_height);
	vec2 cell = fract(grid);
	vec2 aa = max(fwidth(grid), vec2(0.001));
	vec2 pane_margin = family < 0.5 ? vec2(0.19, 0.18) : vec2(0.025, 0.055);
	if (family > 1.5 && family < 2.5) { pane_margin = vec2(0.075, 0.065); }
	if (family > 2.5) { pane_margin = vec2(0.035, 0.035); }
	vec2 inset = smoothstep(pane_margin - aa, pane_margin + aa, cell)
		* (vec2(1.0) - smoothstep(vec2(1.0) - pane_margin - aa, vec2(1.0) - pane_margin + aa, cell));
	float detail_fade = 1.0 - smoothstep(0.18, 0.85, max(aa.x, aa.y));
	float window_mask = mix((1.0 - pane_margin.x * 2.0) * (1.0 - pane_margin.y * 2.0), inset.x * inset.y, detail_fade);
	float room = hash21(floor(grid) + vec2(facade.r * 173.0, facade.r * 397.0));
	float column = hash21(vec2(floor(grid.x), facade.r * 191.0));
	vec3 stone = COLOR.rgb * (0.78 + 0.13 * column);
	float joint = 1.0 - smoothstep(0.012 - aa.y, 0.022 + aa.y, min(cell.y, 1.0 - cell.y));
	stone *= 1.0 - joint * 0.14 * detail_fade;
	// Running-bond masonry appears only at a resolvable distance; other parcels
	// retain larger limestone panels and continuous curtain-wall glass.
	vec2 brick_grid = vec2(horizontal / 0.48, city_position.y / 0.24);
	brick_grid.x += mod(floor(brick_grid.y), 2.0) * 0.5;
	vec2 brick = fract(brick_grid);
	float brick_aa = max(fwidth(brick_grid.x), fwidth(brick_grid.y));
	float mortar = 1.0 - smoothstep(0.035 - brick_aa, 0.035 + brick_aa, min(brick.x,brick.y));
	float masonry = (1.0 - step(0.5,family)) * step(0.4,fract(facade.r * 31.0)) * (1.0-smoothstep(0.1,0.6,brick_aa));
	stone = mix(stone, mix(stone * 0.82, stone * 1.22, mortar), masonry * 0.45);
	float reflected_height = smoothstep(0.0, 280.0, city_position.y - 8.0);
	vec3 glass_low = vec3(0.04, 0.085, 0.13);
	vec3 glass_high = vec3(0.13, 0.22, 0.29);
	if (family > 1.5 && family < 2.5) {
		glass_low = vec3(0.075, 0.060, 0.045);
		glass_high = vec3(0.22, 0.18, 0.12);
	}
	if (family > 2.5) {
		glass_low = vec3(0.065, 0.095, 0.085);
		glass_high = vec3(0.19, 0.255, 0.225);
	}
	vec3 glass = mix(glass_low, glass_high, reflected_height);
	glass = mix(glass, COLOR.rgb * 0.5, 0.16);
	glass *= 0.73 + 0.35 * room;
	// Blinds, individual office bays and dim warm interiors break up uniformity.
	float blinds = step(0.78, room) * (0.28 + 0.22 * step(cell.y, 0.52));
	glass = mix(glass, vec3(0.34, 0.34, 0.30), blinds * detail_fade);
	// Preserve average lit-window energy when windows become sub-pixel. The
	// former multiplication by detail_fade extinguished the entire distant city.
	float lit_probability = family < 0.5 ? 0.28 : 0.46;
	float occupied = mix(lit_probability, step(1.0 - lit_probability, room), detail_fade);
	vec3 lit_room = mix(vec3(1.0, 0.57, 0.27), vec3(0.73, 0.85, 1.0), step(0.68, room));
	glass = mix(glass, lit_room * 0.34, occupied * 0.5);
	float side_face = 1.0 - step(0.5, abs(city_normal.y));
	window_mask *= side_face;
	ALBEDO = mix(stone, glass, window_mask);
	ALBEDO = mix(vec3(0.16, 0.18, 0.19), ALBEDO, side_face);
	METALLIC = mix(family < 0.5 ? 0.02 : 0.22, 0.34, window_mask);
	ROUGHNESS = mix(family < 0.5 ? 0.84 : 0.52, 0.34 + room * 0.06, window_mask);
	SPECULAR = 0.30;
	EMISSION = lit_room * occupied * window_mask * mix(0.025, 1.25, night_factor) * district_power[int(clamp(round(facade.a * 11.0), 0.0, 11.0))];
}
