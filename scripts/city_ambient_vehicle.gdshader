shader_type spatial;
render_mode cull_back;
uniform float traffic_clock = 0.0;
varying vec4 body_color;
varying vec4 paint;
void vertex(){
	body_color=COLOR;
	paint=INSTANCE_CUSTOM;
	// CPU tick interpolation is bounded so stopped vehicles never creep over bars.
	float elapsed=clamp(TIME-INSTANCE_CUSTOM.z,0.0,INSTANCE_CUSTOM.y);
	VERTEX.z += INSTANCE_CUSTOM.x*(INSTANCE_CUSTOM.y-elapsed);
}
void fragment(){
	ALBEDO=mix(vec3(.20,.24,.27),body_color.rgb,UV2.x);
	METALLIC=mix(.05,.4,UV2.x);
	ROUGHNESS=mix(.72,.28,UV2.x);
	float hazard=step(.5,paint.a)*step(mod(traffic_clock,.8),.4)*UV2.y;
	ALBEDO=mix(ALBEDO,vec3(.23,.10,.015),UV2.y);
	EMISSION=vec3(1.0,.32,.025)*hazard*2.2;
}
