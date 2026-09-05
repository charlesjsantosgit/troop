shader_type spatial;
render_mode cull_disabled;
uniform int road_kind = 0; // divided, ramp, local
uniform float half_width = 14.03;
uniform vec2 access_centers[4];
uniform vec2 access_tangents[4];
varying vec3 world_point;
void vertex(){world_point=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;}
void fragment(){
	float x=UV.x; float ax=abs(x); float along=UV.y;
	float grain=fract(sin(dot(world_point.xz,vec2(12.9898,78.233)))*43758.5453);
	vec3 asphalt=vec3(.095,.108,.122)+(grain-.5)*.017;
	vec3 white=vec3(.86,.86,.79);vec3 yellow=vec3(.90,.61,.075);
	vec3 color=asphalt;
	bool parallel_lane=false;
	for(int i=0;i<4;i++){
		vec2 relative=world_point.xz-access_centers[i];
		float s=abs(dot(relative,access_tangents[i]));
		float l=abs(dot(relative,vec2(-access_tangents[i].y,access_tangents[i].x)));
		if(s>315.0 && s<705.0 && l<17.0)parallel_lane=true;
	}
	if(road_kind==0){
		if(ax<2.44)color=vec3(.24,.27,.20);
		if(abs(ax-3.66)<.09)color=yellow;
		if(abs(ax-7.32)<.09 && mod(along,12.0)<3.0)color=white;
		if(abs(ax-10.98)<.10 && (!parallel_lane || mod(along,3.0)<1.0))color=white;
	}else if(road_kind==1){
		if(abs(x-1.83)<.09)color=white;
		if(abs(x+1.83)<.09 && (!parallel_lane || mod(along,3.0)<1.0))color=parallel_lane?white:yellow;
	}else{
		if(abs(ax-.12)<.06)color=yellow;
		if(abs(ax-3.66)<.09)color=white;
	}
	ALBEDO=color;ROUGHNESS=.92;
}
