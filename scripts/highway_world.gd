class_name HighwayWorld
extends Node3D
## Real road decks with continuous triangle collision. Geometry is deterministic
## and shared by all peers; no visual-only strip or terrain teleport is involved.
const Plan = preload("res://scripts/highway_plan.gd")
const SURFACE = preload("res://scripts/highway_surface.gdshader")
const SEGMENTS_PER_TILE := 32
var configured := false
var deck_count := 0
var collision_triangles := 0
var sign_count := 0
var _materials: Dictionary = {}
var _concrete: StandardMaterial3D
var _world: Node3D

func configure(world: Node3D) -> void:
	if configured:return
	_world=world
	configured=true
	name="CrownreachHighways"
	add_to_group("highway_world")
	_concrete=StandardMaterial3D.new()
	_concrete.albedo_color=Color("969891")
	_concrete.roughness=.95
	for road in Plan.roads():
		var points:PackedVector3Array=road.points
		var along:=PackedFloat32Array([0.0])
		for i in range(1,points.size()):along.append(along[-1]+points[i-1].distance_to(points[i]))
		for first in range(0,points.size()-1,SEGMENTS_PER_TILE):
			_build_tile(road,first,mini(first+SEGMENTS_PER_TILE,points.size()-1),along)
	_build_signs()

func road_sample(position: Vector3) -> Dictionary:return Plan.road_sample(position)
func posted_speed(position: Vector3) -> float:return Plan.posted_speed(position)
func nearest_access(position: Vector3) -> Dictionary:return Plan.nearest_access(position)
func route_guidance(position: Vector3) -> String:return Plan.route_guidance(position)

func _surface_material(road: Dictionary) -> Material:
	var key:=str(road.kind)
	if _materials.has(key):return _materials[key]
	var material:=ShaderMaterial.new()
	material.shader=SURFACE
	material.set_shader_parameter("road_kind",0 if key=="divided" else 1 if key=="ramp" else 2)
	material.set_shader_parameter("half_width",float(road.half_width))
	var centers:=PackedVector2Array()
	var tangents:=PackedVector2Array()
	for access in Plan.access_points():
		if access.highway!="h-1":continue
		centers.append(Vector2(access.position.x,access.position.z))
		tangents.append(access.direction)
	material.set_shader_parameter("access_centers",centers)
	material.set_shader_parameter("access_tangents",tangents)
	_materials[key]=material
	return material

func _side(points:PackedVector3Array,index:int) -> Vector3:
	var last:=points.size()-1
	var before:=maxi(index-1,0)
	var after:=mini(index+1,last)
	if points[0].is_equal_approx(points[last]):
		if index==0:before=last-1
		if index==last:after=1
	var d:Vector3=(points[after]-points[before]).normalized()
	return Vector3(-d.z,0,d.x).normalized()

func _vertex(tool:SurfaceTool,point:Vector3,uv:Vector2) -> void:
	tool.set_normal(Vector3.UP)
	tool.set_uv(uv)
	tool.add_vertex(point)

func _quad(tool:SurfaceTool,faces:PackedVector3Array,a:Vector3,b:Vector3,c:Vector3,d:Vector3,uv_a:Vector2,uv_b:Vector2,uv_c:Vector2,uv_d:Vector2) -> void:
	for entry in [[a,uv_a],[c,uv_c],[b,uv_b],[a,uv_a],[d,uv_d],[c,uv_c]]:
		_vertex(tool,entry[0],entry[1])
		faces.append(entry[0])

func _build_tile(road:Dictionary,first:int,last:int,along:PackedFloat32Array) -> void:
	var points:PackedVector3Array=road.points
	var origin:Vector3=points[first]
	var body:=StaticBody3D.new()
	body.name=str(road.id)+"_%d"%first
	body.position=origin
	body.collision_layer=1
	body.collision_mask=1
	body.set_meta("highway_id",road.id)
	body.set_meta("speed_limit_mph",road.mph)
	add_child(body)
	var surface:=SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces:=PackedVector3Array()
	var barrier:=SurfaceTool.new()
	barrier.begin(Mesh.PRIMITIVE_TRIANGLES)
	var barrier_faces:=PackedVector3Array()
	var width:float=road.half_width
	for i in range(first,last):
		var a:Vector3=points[i]-origin
		var b:Vector3=points[i+1]-origin
		var sa:=_side(points,i)
		var sb:=_side(points,i+1)
		_quad(surface,faces,a-sa*width,b-sb*width,b+sb*width,a+sa*width,Vector2(-width,along[i]),Vector2(-width,along[i+1]),Vector2(width,along[i+1]),Vector2(width,along[i]))
		var down:=Vector3.DOWN*.3
		for side in [-1.0,1.0]:
			_quad(barrier,barrier_faces,a+sa*width*side,b+sb*width*side,b+sb*width*side+down,a+sa*width*side+down,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO)
		_quad(barrier,barrier_faces,b-sb*width+down,a-sa*width+down,a+sa*width+down,b+sb*width+down,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO)
		if road.kind=="divided":
			# Median barrier never opens across opposing high-speed traffic.
			_add_barrier(barrier,barrier_faces,a,b,.95,.34)
			if Plan.barrier_allowed(points[i]) and Plan.barrier_allowed(points[i+1]):
				for side in [-1.0,1.0]:_add_barrier(barrier,barrier_faces,a+sa*(width-.25)*side,b+sb*(width-.25)*side,.82,.18)
	var mesh:=MeshInstance3D.new()
	mesh.mesh=surface.commit()
	mesh.material_override=_surface_material(road)
	mesh.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(mesh)
	if not barrier_faces.is_empty():
		var rail:=MeshInstance3D.new()
		rail.mesh=barrier.commit()
		rail.material_override=_concrete
		body.add_child(rail)
		faces.append_array(barrier_faces)
	var shape:=ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision=true
	var collider:=CollisionShape3D.new()
	collider.shape=shape
	body.add_child(collider)
	deck_count+=1
	collision_triangles+=faces.size()/3
	# Bridge piers give elevated routes a physical structure. Place away from
	# each interchange's ground road and ramps so underpasses remain clear.
	if road.kind=="divided":
		for i in range(first,last):
			if i%4!=0:continue
			var crossing:=false
			for access in Plan.access_points():
				if access.highway=="h-1" and Vector2(points[i].x-access.position.x,points[i].z-access.position.z).length()<16.0:crossing=true
			if crossing:continue
			var ground:=Plan.access_ground(points[i].x) if road.id=="h-2" else Plan.City.GROUND_Y
			var height:=points[i].y-ground-.3
			if height<3.0:continue
			var pier:=MeshInstance3D.new()
			var box:=BoxMesh.new()
			box.size=Vector3(1.8,height,1.8)
			pier.mesh=box
			pier.material_override=_concrete
			pier.position=points[i]-origin-Vector3.UP*(height*.5+.3)
			body.add_child(pier)
			var pier_shape:=CollisionShape3D.new()
			var solid:=BoxShape3D.new()
			solid.size=box.size
			pier_shape.shape=solid
			pier_shape.position=pier.position
			body.add_child(pier_shape)

func _add_barrier(tool:SurfaceTool,faces:PackedVector3Array,a:Vector3,b:Vector3,height:float,width:float) -> void:
	var direction:Vector3=(b-a).normalized()
	var side:=Vector3(-direction.z,0,direction.x)*width*.5
	var up:=Vector3.UP*height
	_quad(tool,faces,a-side,b-side,b-side+up,a-side+up,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO)
	_quad(tool,faces,b+side,a+side,a+side+up,b+side+up,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO)
	_quad(tool,faces,a-side+up,b-side+up,b+side+up,a+side+up,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO)

func _sign(at:Vector3,direction:Vector2,message:String,kind:="guide") -> void:
	var root:=Node3D.new()
	root.position=at
	root.rotation.y=atan2(-direction.x,-direction.y)
	add_child(root)
	var board:=MeshInstance3D.new()
	var box:=BoxMesh.new()
	box.size=Vector3(4.6 if kind=="guide" else 1.5,2.0,.12)
	board.mesh=box
	board.position.y=4.4
	var material:=StandardMaterial3D.new()
	material.albedo_color=Color("176847") if kind=="guide" else Color("d7d7c6") if kind=="limit" else Color("cf302b") if kind=="stop" else Color("d7b23e")
	material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	board.material_override=material
	root.add_child(board)
	var label:=Label3D.new()
	label.position=Vector3(0,4.4,.075)
	label.text=message
	label.font_size=40
	label.pixel_size=.0065 if kind=="guide" else .007
	label.modulate=Color.WHITE if kind in ["guide","stop"] else Color("172020")
	label.outline_size=0
	label.no_depth_test=false
	label.visibility_range_end=950
	root.add_child(label)
	var pole:=MeshInstance3D.new()
	var pole_mesh:=CylinderMesh.new()
	pole_mesh.top_radius=.09
	pole_mesh.bottom_radius=.09
	pole_mesh.height=3.8
	pole.mesh=pole_mesh
	pole.position.y=1.9
	pole.material_override=_concrete
	root.add_child(pole)
	sign_count+=1

func _build_signs() -> void:
	for access in Plan.access_points():
		if access.highway!="h-1":continue
		var center:Vector3=access.position
		center.y=Plan.DECK_Y
		var tangent:Vector2=access.direction
		var normal:=Vector2(-tangent.y,tangent.x)
		for direction in [-1.0,1.0]:
			for distance in [1200.0,800.0]:
				var p: Vector3 =center-Vector3(tangent.x,0,tangent.y)*distance*direction+Vector3(normal.x,0,normal.y)*(Plan.HALF_WIDTH+2)*direction
				_sign(p,tangent*direction,"EXIT %s   %s\n%s\nRIGHT EXIT"%[access.id,"3/4 MILE" if distance>1000 else "1/2 MILE",access.name])
			var p: Vector3 =center-Vector3(tangent.x,0,tangent.y)*680*direction+Vector3(normal.x,0,normal.y)*(Plan.HALF_WIDTH+4)*direction
			_sign(p,tangent*direction,"EXIT %s  →\n%s"%[access.id,access.name])
			_sign(p+Vector3(tangent.x,0,tangent.y)*70*direction,tangent*direction,"EXIT\n35 MPH","advisory")
			var stop: Vector3 =access.position-Vector3(tangent.x,0,tangent.y)*8*direction+Vector3(normal.x,0,normal.y)*104*direction
			_sign(stop,tangent*direction,"STOP","stop")
			_sign(stop+Vector3(tangent.x,0,tangent.y)*5*direction,-tangent*direction,"DO NOT\nENTER","stop")
			_sign(stop+Vector3(tangent.x,0,tangent.y)*55*direction,tangent*direction,"SPEED\nLIMIT\n35","limit")
	for road in Plan.roads():
		if road.kind!="divided":continue
		var points:PackedVector3Array=road.points
		for i in range(30,points.size()-1,120):
			var tangent:=Vector2(points[i+1].x-points[i].x,points[i+1].z-points[i].z).normalized()
			var side:=Vector3(-tangent.y,0,tangent.x)
			for direction in [-1.0,1.0]:_sign(points[i]+side*(Plan.HALF_WIDTH+2.0)*direction,tangent*direction,"SPEED\nLIMIT\n%d"%road.mph,"limit")
		if road.id=="h-2":
			for end in [0,points.size()-1]:
				var direction:=Vector2.LEFT if end==0 else Vector2.RIGHT
				var point:Vector3=points[end]
				_sign(point+Vector3(0,0,16 if end>0 else -16),direction,"FREEWAY ENDS\nSURFACE ROAD 25 MPH","guide")
				_sign(point+Vector3(0,0,-16 if end>0 else 16),-direction,"WESTGATE EXPRESSWAY\nCROWNREACH / SETTLEMENTS","guide")

func stats() -> Dictionary:
	return {"roads":Plan.roads().size(),"accesses":Plan.access_points().size(),"decks":deck_count,"collision_triangles":collision_triangles,"signs":sign_count,"ready":configured}
