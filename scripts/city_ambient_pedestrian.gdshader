shader_type spatial;
render_mode cull_disabled,depth_prepass_alpha;
uniform sampler2D canonical_atlas : source_color,filter_linear_mipmap,repeat_disable;
uniform vec3 near_focus=vec3(0.0,-10000.0,0.0);
uniform float population_time=0.0;
varying vec2 atlas_uv;
varying vec3 resident_world;
void vertex(){
	float width=INSTANCE_CUSTOM.z;
	float depth=INSTANCE_CUSTOM.w;
	float perimeter=2.0*(width+depth);
	float speed=1.05+INSTANCE_CUSTOM.y*.55;
	float along=mod(INSTANCE_CUSTOM.x*perimeter+population_time*speed,perimeter);
	vec2 location;
	float yaw;
	if(along<width){location=vec2(along,0.0);yaw=-1.570796;}
	else if(along<width+depth){location=vec2(width,along-width);yaw=3.141593;}
	else if(along<2.0*width+depth){location=vec2(2.0*width+depth-along,depth);yaw=1.570796;}
	else {location=vec2(0.0,perimeter-along);yaw=0.0;}
	float scale=COLOR.r;
	resident_world=(MODEL_MATRIX*vec4(location.x,0.0,location.y,1.0)).xyz;
	vec3 to_camera=CAMERA_POSITION_WORLD-resident_world;
	float azimuth=atan(to_camera.x,to_camera.z)-yaw;
	float direction=mod(floor(azimuth/0.785398+0.5),8.0);
	float pitch=atan(to_camera.y,length(to_camera.xz));
	float elevation=pitch>1.047198?2.0:(pitch>0.479966?1.0:0.0);
	float phase=mod(floor(population_time*speed*5.0+INSTANCE_CUSTOM.x*4.0),4.0);
	atlas_uv=(vec2(direction,phase*3.0+elevation)+clamp(UV,vec2(.005),vec2(.995)))/vec2(8.0,12.0);
	vec3 center=resident_world+vec3(0.0,.90*scale,0.0);
	vec3 camera_right=INV_VIEW_MATRIX[0].xyz;
	vec3 camera_up=INV_VIEW_MATRIX[1].xyz;
	vec3 world_vertex=center+(camera_right*VERTEX.x+camera_up*VERTEX.y)*scale;
	POSITION=PROJECTION_MATRIX*VIEW_MATRIX*vec4(world_vertex,1.0);
	NORMAL=vec3(0.0,1.0,0.0);
}
void fragment(){
	if(distance(CAMERA_POSITION_WORLD,resident_world)<100.0)discard;
	if(abs(near_focus.y-resident_world.y)<40.0&&distance(near_focus.xz,resident_world.xz)<28.0)discard;
	vec4 texel=texture(canonical_atlas,atlas_uv);
	ALBEDO=texel.rgb;
	ALPHA=texel.a;
	ALPHA_SCISSOR_THRESHOLD=.25;
	ROUGHNESS=.9;
}
