shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	// Instance colours also drive emission, so cool wayfinding and warm street
	// lamps retain their intended hue instead of sharing an orange glow.
	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * mix(0.14, 4.2, night_factor);
	ROUGHNESS = 0.38;
	METALLIC = 0.08;
}
