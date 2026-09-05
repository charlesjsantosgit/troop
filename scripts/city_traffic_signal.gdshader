shader_type spatial;
render_mode unshaded, cull_disabled;
uniform bool dark_lenses = false;
varying float powered;
void vertex() { powered = INSTANCE_CUSTOM.r; }
void fragment() {
	if (!dark_lenses && powered < 0.01) { discard; }
	ALBEDO = COLOR.rgb * mix(0.008, 1.0, powered);
	EMISSION = COLOR.rgb * powered * 1.8;
	ROUGHNESS = 0.4;
}
