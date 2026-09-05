extends Node3D
## Temporary physical shell: a plane-shaped opening replaces real wall geometry.
## Collapse and repair share the canonical massing, with bounded rubble batches.
const Plan=preload("res://scripts/city_plan.gd")
const State=preload("res://scripts/city_incident_state.gd")
const Massing=preload("res://scripts/city_massing.gd")
var record:Dictionary
var building:Dictionary
var wall_root:Node3D
var upper:Node3D
var particles:Node3D
var scaffold:Node3D
var _stage:=-1
var _cut:=0.0
var _face_axis:=2
var _impact:Vector3
var _wall:Material
var _burnt:StandardMaterial3D
var _rubble:MultiMeshInstance3D
var _warm:OmniLight3D
var _body:StaticBody3D
var _batches:Dictionary={}
var _facade_color:=Color.WHITE
var _facade_custom:=Color.WHITE
var _pieces:=0
var _hole_panels:=0
func configure(item:Dictionary,source:Node3D)->void:
	record=item.duplicate(true);building=Plan.building(record.building)
	position=building.position
	_impact=State.vector(record.position)-position
	var direction:=State.vector(record.direction)
	_face_axis=0 if absf(direction.x)>absf(direction.z) else 2
	_cut=clampf(_impact.y+float(record.height)*1.1,2.0,float(building.size.y)-.5)
	_wall=source._shell_material
	_facade_color=source._building_color(building);_facade_custom=source._facade_data(building,0)
	_burnt=StandardMaterial3D.new();_burnt.albedo_color=Color("292b2c");_burnt.roughness=.97
	_build_lower(_cut,true)
	upper=Node3D.new();upper.name="CollapsingUpperFloors";add_child(upper)
	for section in Massing.sections(building):
		var bounds:=_bounds(section)
		if bounds.end.y<=_cut:continue
		var low:=maxf(_cut,bounds.position.y)
		_visual_box(upper,Vector3(bounds.get_center().x,(low+bounds.end.y)*.5,bounds.get_center().z),Vector3(bounds.size.x,bounds.end.y-low,bounds.size.z),_wall)
	_flush_meshes(upper)
	_build_rubble();_build_fire();_build_scaffold()
func _bounds(section:Dictionary)->AABB:return AABB(Vector3(section.offset)-Vector3(section.size)*.5,section.size)
static func plane_opening(u:float,v:float,span:float,height:float)->bool:
	# Front projection: fuselage, swept wings and vertical stabilizer. Broken edges
	# are actual absent cells; this is not a decal painted over a solid wall.
	var body:=Vector2(u/(span*.12),v/(height*.32)).length()<1.0
	var wing:=absf(u)<span*.56 and absf(v+absf(u)*.045)<height*.10*(1.0-absf(u)/(span*.62))+.12
	var tail:=absf(u)<span*.058 and v>-.2*height and v<height*.72
	return body or wing or tail
func _build_lower(top:float,hole:bool)->void:
	if is_instance_valid(wall_root):
		_body.collision_layer=0
		_body.collision_mask=0
		wall_root.queue_free()
	wall_root=Node3D.new();wall_root.name="DamagedBuildingShell";add_child(wall_root)
	_body=StaticBody3D.new();wall_root.add_child(_body);_body.collision_layer=1;_body.collision_mask=1
	_pieces=0;_hole_panels=0
	for section in Massing.sections(building):
		var b:=_bounds(section)
		var low:=b.position.y;var high:=minf(b.end.y,top)
		if high<=low:continue
		for axis in [0,2]:
			for sign in [-1.0,1.0]:
				var width:float=b.size.z if axis==0 else b.size.x
				var wall_at:float=b.get_center()[axis]+sign*b.size[axis]*.5
				if hole and axis==_face_axis and _impact.y+float(record.height) > low and _impact.y-float(record.height) < high:
					_wall_with_hole(axis,wall_at,width,low,high)
				else:
					var at:=Vector3(0,(low+high)*.5,0);at[axis]=wall_at
					var size:=Vector3(width,high-low,.32) if axis==2 else Vector3(.32,high-low,width)
					_panel(at,size,_wall)
		# Floor decks support actual actors, with a corresponding opening at impact.
		for y in range(ceili(low/3.8),floori(high/3.8)+1):
			var floor_y:=float(y)*3.8
			if hole and absf(floor_y-_impact.y)<float(record.height)*.7:continue
			_panel(Vector3(0,floor_y,0),Vector3(b.size.x,.22,b.size.z),_burnt)
	_flush_meshes(wall_root)
func _wall_with_hole(axis:int,wall_at:float,width:float,low:float,high:float)->void:
	var zone_low:=maxf(low,_impact.y-float(record.height))
	var zone_high:=minf(high,_impact.y+float(record.height))
	var horizontal:=2 if axis==0 else 0
	for range_y in [Vector2(low,zone_low),Vector2(zone_high,high)]:
		if range_y.y-range_y.x<.001:continue
		var at:=Vector3(0,(range_y.x+range_y.y)*.5,0);at[axis]=wall_at
		_panel(at,Vector3(width,range_y.y-range_y.x,.32) if axis==2 else Vector3(.32,range_y.y-range_y.x,width),_wall)
	var columns:=ceili(width/.6);var rows:=ceili((zone_high-zone_low)/.6)
	var cell_w:=width/columns;var cell_h:=(zone_high-zone_low)/maxi(rows,1)
	for y in range(rows):
		var v:=zone_low+(y+.5)*cell_h
		var run_start:=0;var previous:=-2
		for x in range(columns+1):
			var u:=-width*.5+(x+.5)*cell_w
			var state:=0
			if x==columns:state=-2
			elif plane_opening(u-_impact[horizontal],v-_impact.y,float(record.span),float(record.height)):state=-1;_hole_panels+=1
			elif absf(u-_impact[horizontal])<float(record.span)*.67 and absf(v-_impact.y)<float(record.height)*.9:state=1
			if state!=previous:
				if previous>=0:
					var at:=Vector3(0,v,0);at[axis]=wall_at;at[horizontal]=-width*.5+(run_start+x)*cell_w*.5
					var length:=(x-run_start)*cell_w
					_panel(at,Vector3(length,cell_h,.36) if axis==2 else Vector3(.36,cell_h,length),_burnt if previous==1 else _wall)
				run_start=x;previous=state
func _panel(at:Vector3,size:Vector3,mat:Material)->void:
	_visual_box(wall_root,at,size,mat)
	var shape:=CollisionShape3D.new();var box:=BoxShape3D.new();box.size=size
	shape.shape=box;shape.position=at;_body.add_child(shape);_pieces+=1
func _visual_box(parent:Node3D,at:Vector3,size:Vector3,mat:Material)->void:
	var key:=str(parent.get_instance_id())+":"+str(mat.get_instance_id())
	if not _batches.has(key):_batches[key]={"parent":parent,"material":mat,"transforms":[]}
	_batches[key].transforms.append(Transform3D(Basis.from_scale(size),at))
func _flush_meshes(parent:Node3D)->void:
	for key in _batches.keys():
		var row:Dictionary=_batches[key]
		if row.parent!=parent:continue
		var multi:=MultiMesh.new();multi.transform_format=MultiMesh.TRANSFORM_3D;multi.use_colors=true;multi.use_custom_data=true
		var mesh:=BoxMesh.new();mesh.size=Vector3.ONE;multi.mesh=mesh;multi.instance_count=row.transforms.size()
		for i in range(row.transforms.size()):
			multi.set_instance_transform(i,row.transforms[i]);multi.set_instance_color(i,_facade_color if row.material==_wall else Color.WHITE);multi.set_instance_custom_data(i,_facade_custom)
		var instance:=MultiMeshInstance3D.new();instance.multimesh=multi;instance.material_override=row.material;parent.add_child(instance)
		_batches.erase(key)
func _build_rubble()->void:
	_rubble=MultiMeshInstance3D.new();_rubble.name="FallingConcreteAndGlass"
	var mesh:=BoxMesh.new();mesh.size=Vector3.ONE
	var multi:=MultiMesh.new();multi.transform_format=MultiMesh.TRANSFORM_3D;multi.use_colors=true;multi.mesh=mesh;multi.instance_count=96
	var mat:=StandardMaterial3D.new();mat.vertex_color_use_as_albedo=true;mat.roughness=.9
	_rubble.multimesh=multi;_rubble.material_override=mat;add_child(_rubble)
func _build_fire()->void:
	particles=Node3D.new();particles.name="FireAndSmoke";add_child(particles)
	var shader:=Shader.new()
	shader.code="""shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform vec4 tint:source_color;
uniform float heat=1.0;
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float noise(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.0-2.0*f);return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y);}
void vertex(){vec3 s=vec3(length(MODEL_MATRIX[0].xyz),length(MODEL_MATRIX[1].xyz),length(MODEL_MATRIX[2].xyz));MODELVIEW_MATRIX=VIEW_MATRIX*mat4(vec4(INV_VIEW_MATRIX[0].xyz*s.x,0.0),vec4(INV_VIEW_MATRIX[1].xyz*s.y,0.0),vec4(INV_VIEW_MATRIX[2].xyz*s.z,0.0),MODEL_MATRIX[3]);}
void fragment(){vec2 p=UV-vec2(.5);float n=noise(UV*7.0+vec2(TIME*.5,-TIME*1.2));float d=length(p)*2.0;float a=(1.0-smoothstep(.15,.94,d+n*.24));ALBEDO=mix(tint.rgb*.55,tint.rgb,n);EMISSION=mix(tint.rgb,vec3(1,.70,.14),a*.6)*heat*3.0;ALPHA=a*tint.a;}
"""
	for i in range(24):
		var visual:=MeshInstance3D.new();var quad:=QuadMesh.new();quad.size=Vector2.ONE
		var material:=ShaderMaterial.new();material.shader=shader
		material.set_shader_parameter("tint",Color(1,.20,.015,.7) if i<12 else Color(.15,.14,.13,.6))
		material.set_shader_parameter("heat",1.0 if i<12 else 0.0)
		visual.mesh=quad;visual.material_override=material;visual.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		particles.add_child(visual)
	_warm=OmniLight3D.new();_warm.light_color=Color(1,.25,.03);_warm.omni_range=45;_warm.light_energy=15;_warm.position=_impact;add_child(_warm)
func _build_scaffold()->void:
	scaffold=Node3D.new();scaffold.name="ReconstructionScaffolding";add_child(scaffold)
	var steel:=StandardMaterial3D.new();steel.albedo_color=Color("9ca4a5");steel.metallic=.7;steel.roughness=.4
	for side in [-1.0,1.0]:
		for axis in [0,2]:
			for index in range(8):
				var at:=Vector3(0,building.size.y*.5,0);at[axis]=side*(building.size[axis]*.5+1.1);at[2 if axis==0 else 0]=lerpf(-.48,.48,index/7.0)*building.size[2 if axis==0 else 0]
				_visual_box(scaffold,at,Vector3(.12,building.size.y,.12),steel)
			for floor_index in range(1,ceili(building.size.y/7)):
				var at:=Vector3(0,floor_index*7,0);at[axis]=side*(building.size[axis]*.5+1.1)
				_visual_box(scaffold,at,Vector3(building.size.x+2,.1,.1) if axis==2 else Vector3(.1,.1,building.size.z+2),steel)
	_flush_meshes(scaffold)
	scaffold.hide()
func update_incident(now:float)->void:
	var age:=maxf(0,now-float(record.created));var phase:=State.phase(record,now)
	var progress:=State.progress(record,now)
	if is_instance_valid(upper):
		var collapse:=smoothstep(3,22,age)
		upper.rotation.z=collapse*.18
		upper.position.y=-collapse*(_cut+float(building.size.y))*.40
		upper.scale=Vector3(1,1-collapse*.7,1)
		upper.visible=age<24
	for i in range(96):
		var seed:float=float(i)*2.399963
		var origin:=_impact+Vector3(sin(seed)*3,cos(seed*1.7)*2,cos(seed)*3)
		var speed:=Vector3(sin(seed)*9,8+fmod(i*1.7,12),cos(seed)*9)
		var t:=minf(age,6.0);var at:=origin+speed*t-Vector3(0,4.9*t*t,0)
		at.y=maxf(.18+fmod(i*.131,.7),at.y)
		var basis:=Basis.from_euler(Vector3(seed+t,seed*.3,seed*.7+t)).scaled(Vector3(.15+fmod(i*.37,.8),.10+fmod(i*.23,.6),.13+fmod(i*.17,.9))*(1.0-progress))
		_rubble.multimesh.set_instance_transform(i,Transform3D(basis,at))
		_rubble.multimesh.set_instance_color(i,Color("72746f") if i%3 else Color("647c82"))
	particles.visible=age<100
	_warm.visible=age<60
	_warm.light_energy=(9+sin(age*13)*2)*(1.0-smoothstep(40,70,age))
	for i in range(particles.get_child_count()):
		var item:Node3D=particles.get_child(i);var t:=fposmod(age*(.7 if i<12 else .18)+i*.27,1.0)
		item.position=_impact+Vector3(sin(i*2.4+age)*float(record.span)*.35,t*(5 if i<12 else 40),cos(i*1.8)*2)
		item.scale=Vector3.ONE*(2+t*(4 if i<12 else 16))
	scaffold.visible=phase in ["stabilize","rebuild"]
	var stage:=floori(progress*8)
	if phase=="rebuild" and stage!=_stage:
		_stage=stage;_build_lower(lerpf(_cut,float(building.size.y),progress),progress<.45)
func stats()->Dictionary:return {"wall_colliders":_pieces,"removed_hole_cells":_hole_panels,"debris":96,"phase":_stage}
