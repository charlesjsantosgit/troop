shader_type spatial;
varying vec3 lake_position;
void vertex() { lake_position=(MODEL_MATRIX*vec4(VERTEX,1.)).xyz; }
void fragment() {
 vec2 p=lake_position.xz;
 vec2 waves=vec2(sin(p.x*.95+TIME*.9)+sin(p.y*1.32-TIME*.6),cos(p.y*.88+TIME*.7)+cos(p.x*1.18-TIME*.5));
 float broad=sin(p.x*.08+p.y*.10+TIME*.45)*.5+.5;
 NORMAL_MAP=vec3(vec2(.5)+waves*.026,1.);
 ALBEDO=mix(vec3(.06,.20,.185),vec3(.12,.28,.25),broad*.28);
 ROUGHNESS=.15; METALLIC=.42; SPECULAR=.7;
}
