shader_type spatial;
render_mode diffuse_burley;
varying vec3 tree_position;
void vertex() {
	float lobes = sin(VERTEX.x * 24.0 + VERTEX.y * 17.0) * cos(VERTEX.z * 19.0);
	VERTEX *= 1.0 + lobes * 0.15;
	tree_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec3 p = tree_position * 14.0;
	float leaf = fract(sin(dot(floor(p), vec3(12.9898, 78.233, 39.425))) * 43758.54);
	float detail = 1.0 - smoothstep(0.3, 2.0, length(fwidth(p)));
	ALBEDO = COLOR.rgb * mix(0.86, 0.62 + leaf * 0.60, detail);
	ROUGHNESS = 0.88;
	SPECULAR = 0.17;
	BACKLIGHT = COLOR.rgb * 0.16;
}
