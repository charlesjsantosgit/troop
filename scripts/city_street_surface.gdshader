shader_type spatial;
render_mode world_vertex_coords;
uniform vec2 city_origin;
uniform vec2 city_center;
uniform vec2 park_center;
uniform vec2 park_half_extents;
uniform float night_factor = 0.0;
uniform vec2 block_size;
uniform vec2 lot_spacing;
uniform float major_half_width = 12.0;
uniform float local_half_width = 4.0;
uniform float plaza_extent = 18.0;
varying vec3 world_position;
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}
float line(float distance, float width, float aa) {
	return 1.0 - smoothstep(width - aa, width + aa, distance);
}
void vertex() { world_position = VERTEX; }
void fragment() {
	vec2 park_offset = abs(world_position.xz - park_center);
	if (park_offset.x < park_half_extents.x && park_offset.y < park_half_extents.y) { discard; }
	float park_block = 0.0;
	vec2 p = world_position.xz - city_origin;
	vec2 signed_local = mod(p + lot_spacing * 0.5, lot_spacing) - lot_spacing * 0.5;
	vec2 local = abs(signed_local);
	vec2 road_indices = floor(p / lot_spacing + 0.5);
	vec2 one_way = vec2(1.0) - step(vec2(0.1), abs(mod(road_indices, 8.0) - vec2(3.0)));
	vec2 major = abs(mod(p + block_size * 0.5, block_size) - block_size * 0.5);
	float aa = max(length(fwidth(p)) * 0.65, 0.015);
	vec2 widths = vec2(major_half_width);
	float road_x = line(local.x, widths.x, aa);
	float road_z = line(local.y, widths.y, aa);
	if (park_block > 0.5) {
		road_x *= 1.0 - step(major_half_width, major.x);
		road_z *= 1.0 - step(major_half_width, major.y);
	}
	float road = max(road_x, road_z);
	float grain = (hash21(floor(p * 16.0)) - 0.5) * 0.035 / (1.0 + aa * 3.0);
	vec3 asphalt = vec3(0.085, 0.098, 0.108) + grain;
	// Large repair patches, fine aggregate and subtle oil-darkened wheel tracks.
	asphalt *= 0.90 + 0.16 * hash21(floor(p / 6.0));
	float track = (line(abs(local.x - 2.7), 0.32, aa) * road_x + line(abs(local.y - 2.7), 0.32, aa) * road_z);
	asphalt *= 1.0 - track * 0.12;
	vec2 tile = abs(fract(p / 1.2) - 0.5) * 1.2;
	float joint = max(line(tile.x, 0.012, aa), line(tile.y, 0.012, aa));
	vec3 paving = mix(vec3(0.39, 0.385, 0.36) + grain, vec3(0.26, 0.265, 0.25), joint * 0.4);
	vec2 square = abs(world_position.xz - city_center);
	float plaza = (1.0 - step(plaza_extent, max(square.x, square.y)));
	float band = line(abs(max(square.x, square.y) - 12.0), 0.22, aa);
	paving = mix(paving, vec3(0.25, 0.28, 0.29), band * plaza);
	road *= 1.0 - plaza;
	vec3 surface = mix(paving, asphalt, road);
	// Center dashes stop before junctions. Avenue lanes keep human-scale widths.
	float dash_x = (1.0 - step(3.4, mod(p.y, 7.0))) * step(widths.y + 2.0, local.y);
	float dash_z = (1.0 - step(3.4, mod(p.x, 7.0))) * step(widths.x + 2.0, local.x);
	float center = max(line(abs(local.x - 0.15), 0.055, aa) * step(widths.y + 6.0, local.y) * (1.0 - one_way.x), line(abs(local.y - 0.15), 0.055, aa) * step(widths.x + 6.0, local.x) * (1.0 - one_way.y));
	float lane = max(line(abs(local.x - 5.7), 0.065, aa) * dash_x * step(10.0, widths.x),
		line(abs(local.y - 5.7), 0.065, aa) * dash_z * step(10.0, widths.y));
	float edge = max(line(abs(local.x - widths.x + 0.38), 0.07, aa) * step(widths.y + 2.0, local.y),
		line(abs(local.y - widths.y + 0.38), 0.07, aa) * step(widths.x + 2.0, local.x));
	// Zebra crossings and their stop bars are painted on the same road surface.
	float cross_x = line(abs(local.y - widths.y - 2.5), 1.25, aa) * step(0.65, mod(p.x, 1.4)) * road_x;
	float cross_z = line(abs(local.x - widths.x - 2.5), 1.25, aa) * step(0.65, mod(p.y, 1.4)) * road_z;
	// Stop bars precede the crosswalk by 1.4m; each covers its incoming lane.
	float incoming_half = step(0.0, signed_local.x * signed_local.y);
	vec2 one_way_sign = vec2(1.0) - mod(floor(road_indices / 8.0), 2.0) * 2.0;
	float legal_x = mix(1.0, step(0.0, -signed_local.y * one_way_sign.x), one_way.x);
	float legal_z = mix(1.0, step(0.0, -signed_local.x * one_way_sign.y), one_way.y);
	float stop_x = line(abs(local.y - widths.y - 5.15), 0.18, aa) * road_x * incoming_half * step(0.4, local.x) * legal_x;
	float stop_z = line(abs(local.x - widths.x - 5.15), 0.18, aa) * road_z * incoming_half * step(0.4, local.y) * legal_z;
	float white_paint = clamp(max(max(lane, edge), max(max(cross_x, cross_z), max(stop_x, stop_z))) * road, 0.0, 1.0);
	surface = mix(surface, vec3(0.70, 0.56, 0.25), center * road * 0.82);
	surface = mix(surface, vec3(0.78, 0.78, 0.71), white_paint * 0.88);
	// Recessed drainage grates beside curbs, repeated every half block.
	float drain = line(abs(local.x - widths.x + 0.32), 0.22, aa) * line(abs(mod(p.y, 23.0) - 17.0), 0.55, aa) * road_x;
	surface = mix(surface, vec3(0.035), drain * (0.65 + 0.35 * step(0.07, mod(p.y, 0.18))));
	vec2 block_p = mod(p, block_size);
	float lamp_x = min(abs(block_p.x - 12.2), abs(block_p.x - block_size.x * 0.5 - 4.2));
	float lamp_z = abs(mod(block_p.y - 16.0 + lot_spacing.y * 0.5, lot_spacing.y) - lot_spacing.y * 0.5);
	float lamp_pool = exp(-0.038 * (lamp_x * lamp_x + lamp_z * lamp_z));
	EMISSION = vec3(0.75, 0.54, 0.29) * (lamp_pool + 0.055 * road) * night_factor;
	ALBEDO = surface;
	ROUGHNESS = mix(0.88, 0.79, road);
	SPECULAR = 0.24;
}
