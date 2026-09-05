shader_type spatial;
render_mode diffuse_burley;

uniform vec4 tint : source_color = vec4(1.0);
// 0 oak parquet, 1 walnut, 2 stone, 3 upholstery, 4 plaster,
// 5 bronze, 6 blackened steel, 7 woven rug, 8 foliage.
uniform int surface_kind = 0;
varying vec3 room_position;
varying vec3 room_normal;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float noise2(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1., 0.)), f.x),
		mix(hash21(i + vec2(0., 1.)), hash21(i + vec2(1.)), f.x), f.y);
}
void vertex() {
	room_position = VERTEX;
	room_normal = NORMAL;
}
void fragment() {
	vec3 n = abs(normalize(room_normal));
	vec2 p = n.y > 0.65 ? room_position.xz : (n.x > n.z ? room_position.zy : room_position.xy);
	vec3 color = tint.rgb;
	float rough = 0.65;
	float metal = 0.0;
	float relief = 0.0;
	float micro = noise2(p * 115.0);
	if (surface_kind == 0 || surface_kind == 1) {
		vec2 wood = p;
		float seam = 1.0;
		float board = 0.5;
		if (surface_kind == 0 && n.y > 0.65) {
			vec2 q = mat2(vec2(0.7071, -0.7071), vec2(0.7071, 0.7071)) * p / 0.18;
			float run = mod(floor(q.x) - floor(q.y), 12.0);
			bool horizontal = run < 6.0;
			float across = horizontal ? fract(q.y) : fract(q.x);
			float along = horizontal ? run + fract(q.x) : 12.0 - run - fract(q.y);
			vec2 board_id = horizontal ? vec2(floor(q.x) - run, floor(q.y)) : vec2(floor(q.x), floor(q.y) + run - 6.0);
			board = hash21(board_id);
			wood = vec2(along * 0.18, across * 0.18 + board * 8.0);
			float edge = min(min(across, 1.0 - across), min(along, 6.0 - along));
			float aa = max(fwidth(across), 0.008);
			seam = smoothstep(0.008, 0.014 + aa, edge);
		} else {
			board = hash21(vec2(floor(p.x * 2.5), 3.));
			wood = vec2(p.y, p.x);
		}
		float bend = noise2(wood * vec2(0.9, 5.0));
		float grain = noise2(wood * vec2(3., 120.) + vec2(0., bend * 5.));
		float pores = noise2(wood * vec2(28., 380.));
		color *= mix(0.90, 1.07, board) * mix(0.91, 1.04, grain) * mix(0.78, 1.0, seam);
		rough = (surface_kind == 0 ? 0.36 : 0.29) + pores * 0.09;
		relief = grain * 0.001 + seam * 0.0005;
	} else if (surface_kind == 2) {
		float cloud = noise2(p * 0.75) + noise2(p * 2.2) * 0.25;
		float phase = p.x * 1.7 + p.y * 0.8 + cloud * 3.1;
		float vein = pow(1.0 - abs(sin(phase * 3.0)), 28.0);
		float hairline = pow(1.0 - abs(sin(phase * 6.0 + 0.7)), 42.0) * 0.25;
		color *= mix(0.93, 1.04, noise2(p * 9.0));
		color = mix(color, tint.rgb * vec3(0.57, 0.55, 0.50), vein * 0.28 + hairline * 0.65);
		rough = 0.23 + micro * 0.06;
	} else if (surface_kind == 3 || surface_kind == 7) {
		float weave_scale = surface_kind == 7 ? 160.0 : 340.0;
		vec2 t = p * weave_scale;
		float filtering = 1.0 - smoothstep(0.15, 0.8, max(fwidth(t.x), fwidth(t.y)));
		float weave = sin(t.x * 6.28318) * sin(t.y * 6.28318) * filtering;
		color *= 0.95 + micro * 0.07 + weave * 0.025;
		if (surface_kind == 7) {
			float motley = noise2(p * 2.0 + noise2(p * 0.5) * 5.0);
			color *= mix(0.88, 1.04, motley);
		}
		rough = 0.94;
		relief = weave * 0.00014;
	} else if (surface_kind == 4) {
		color *= 0.975 + micro * 0.04;
		rough = 0.85;
	} else if (surface_kind == 5 || surface_kind == 6) {
		metal = surface_kind == 5 ? 0.82 : 0.68;
		rough = surface_kind == 5 ? 0.26 : 0.34;
		color *= 0.96 + noise2(p * vec2(250.0, 5.0)) * 0.08;
	} else if (surface_kind == 8) {
		color *= 0.88 + noise2(p * 16.0) * 0.22;
		rough = 0.64;
	}
	ALBEDO = color;
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = 0.45;
	if (surface_kind == 3 || surface_kind == 7) {
		RIM = 0.12;
		RIM_TINT = 0.65;
	}
	// Tiny physical relief, filtered through screen derivatives to avoid moire.
	vec3 tangent_x = normalize(dFdx(VERTEX));
	vec3 tangent_y = normalize(dFdy(VERTEX));
	NORMAL = normalize(NORMAL - tangent_x * dFdx(relief) * 10.0 - tangent_y * dFdy(relief) * 10.0);
}
