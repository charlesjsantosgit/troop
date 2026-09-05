shader_type spatial;
render_mode world_vertex_coords;
uniform vec2 park_center;
uniform vec2 pond_center;
uniform vec2 pond_radii;
varying vec3 world_position;
float hash21(vec2 p) { return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453); }
float noise2(vec2 p) {
 vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
 return mix(mix(hash21(i),hash21(i+vec2(1.,0.)),f.x),mix(hash21(i+vec2(0.,1.)),hash21(i+vec2(1.)),f.x),f.y);
}
void vertex() { world_position=VERTEX; }
void fragment() {
 vec2 p=world_position.xz-park_center;
 float aa=max(length(fwidth(p)),.03);
 float mottle=noise2(p*.042)*.65+noise2(p*.29)*.35;
 vec3 green=mix(vec3(.13,.23,.095),vec3(.28,.36,.15),mottle*.55);
 float lawn=1.0-smoothstep(.92,1.03,length((p-vec2(5.,-900.))/vec2(240.,480.)));
 green += sin(p.y*.24)*.011*lawn;
 green += (noise2(p*8.)-.5)*.025/(1.+aa*10.);
 vec2 q=(world_position.xz-pond_center)/pond_radii;
 float a=atan(q.y,q.x);
 float edge=length(q)/(1.+.10*sin(3.*a+.4)+.055*cos(5.*a-.6));
 float bank=1.-smoothstep(.98,1.045,edge);
 ALBEDO=mix(green,vec3(.32,.305,.22)+mottle*.035,bank);
 ROUGHNESS=.94; SPECULAR=.13;
}
