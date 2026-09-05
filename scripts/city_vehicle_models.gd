class_name CityVehicleModels
extends RefCounted
## Metre-scale fictional vehicles. Reference dimensions and scope: CITY_TRAFFIC.md.
## All solid detail is merged per class; paint varies without duplicating meshes.
const Monkeys = preload("res://scripts/city_monkey_models.gd")
const PAINTS: Array[Color] = [Color("e8e8e2"),Color("222831"),Color("78828a"),Color("243c5e"),Color("9c2c30"),Color("d9d2bf"),Color("42665b"),Color("857158"),Color("e8b843"),Color("b6c4d0"),Color("724951"),Color("d57437")]
const CATALOG: Array[Dictionary] = [
	{"id":"hatchback","label":"Metro Hatch","length":4.37,"width":1.79,"height":1.45,"wheelbase":2.64,"price":18500},
	{"id":"sedan","label":"Crown Sedan","length":4.63,"width":1.78,"height":1.44,"wheelbase":2.70,"price":24500},
	{"id":"wagon","label":"Touring Estate","length":4.75,"width":1.85,"height":1.50,"wheelbase":2.78,"price":29000},
	{"id":"coupe","label":"Aurora Coupe","length":4.52,"width":1.88,"height":1.34,"wheelbase":2.72,"price":42000},
	{"id":"crossover","label":"Garden Crossover","length":4.61,"width":1.86,"height":1.68,"wheelbase":2.69,"price":32500},
	{"id":"suv","label":"Summit SUV","length":5.02,"width":2.00,"height":1.83,"wheelbase":2.90,"price":47500},
	{"id":"pickup","label":"Tradesman Pickup","length":5.88,"width":2.03,"height":1.94,"wheelbase":3.69,"price":39000},
	{"id":"delivery_van","label":"Parcel Cargo Van","length":5.93,"width":2.02,"height":2.46,"wheelbase":3.66,"price":44000},
	{"id":"taxi","label":"Crown City Taxi","length":4.83,"width":1.87,"height":1.49,"wheelbase":2.82,"price":31000},
	{"id":"shuttle","label":"Neighborhood Shuttle","length":6.30,"width":2.12,"height":2.70,"wheelbase":3.75,"price":65000},
]
static var _meshes: Dictionary = {}
static var _glass: Dictionary = {}
static var _materials: Dictionary = {}

static func catalog() -> Array[Dictionary]: return CATALOG.duplicate(true)
static func spec(index: int) -> Dictionary: return CATALOG[posmod(index,CATALOG.size())].duplicate()
static func index_for_id(id: String) -> int:
	for index in range(CATALOG.size()):
		if CATALOG[index].id == id: return index
	return -1
static func paint_for(serial: int, index: int) -> Color:
	return Color("edbd36") if index == 8 else PAINTS[posmod(serial * 7 + serial / 5, PAINTS.size())]

static func window_bounds(index: int) -> AABB:
	var s := spec(index)
	var bottom := float(s.height) * .48
	var top := float(s.height) - .105
	var front := -float(s.length) * (.30 if index >= 6 else .225)
	var back := float(s.length) * (.06 if index in [6,7] else .26)
	return AABB(Vector3(-float(s.width)*.39,bottom,front),Vector3(float(s.width)*.78,top-bottom,back-front))

static func cabin_bounds(index: int) -> AABB:
	var window := window_bounds(index)
	return AABB(Vector3(-float(spec(index).width)*.46,.07,window.position.z),Vector3(float(spec(index).width)*.92,window.end.y-.07,window.size.z))

static func driver_config(index: int) -> Dictionary:
	var c := cabin_bounds(index)
	var seat := Vector3(-float(spec(index).width)*.15,.76 if index in [5,6,7,9] else .46,c.position.z+c.size.z*.57)
	return {"id":spec(index).id,"seat":seat,"roof":c.end.y,"recline":.58 if index==3 else .20,"wheel_reach":.28 if index==3 else .46}

static func driver_model(index: int, height := MonkeyRig.NPC_MAX_HEIGHT) -> Dictionary:
	var config := driver_config(index)
	if not is_equal_approx(height,MonkeyRig.NPC_MAX_HEIGHT):
		var reference := driver_model(index,MonkeyRig.NPC_MAX_HEIGHT)
		config.seat = reference.points.pelvis
		config.targets = reference.report.targets
	return Monkeys.seated(config,height)

static func driver_bounds(index: int) -> AABB:
	return driver_model(index).report.bounds

static func _material(kind: String) -> Material:
	if _materials.has(kind): return _materials[kind]
	var result: Material
	if kind == "paint":
		var shader := Shader.new()
		shader.code = "shader_type spatial; render_mode cull_back; instance uniform vec4 paint_color : source_color = vec4(0.7,0.7,0.7,1.0); varying vec4 tint; void vertex(){tint=COLOR;} void fragment(){ ALBEDO=mix(tint.rgb,paint_color.rgb,UV2.x); METALLIC=mix(0.08,0.48,UV2.x); ROUGHNESS=mix(0.68,0.23,UV2.x); }"
		result = ShaderMaterial.new()
		result.shader = shader
	elif kind == "glass":
		var glass := StandardMaterial3D.new()
		glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glass.albedo_color = Color(.34,.49,.56,.20)
		glass.roughness = .13
		glass.metallic = .12
		glass.cull_mode = BaseMaterial3D.CULL_DISABLED
		glass.no_depth_test = false
		result = glass
	else:
		var rubber := StandardMaterial3D.new()
		rubber.vertex_color_use_as_albedo = true
		rubber.roughness = .75
		result = rubber
	_materials[kind] = result
	return result

static func build(parent: Node3D, index: int, paint: Color, detail := true, include_driver := true) -> Dictionary:
	var body := MeshInstance3D.new()
	body.name = "VehicleBody_" + str(spec(index).id)
	body.mesh = mesh(index,detail,include_driver)
	body.material_override = _material("paint")
	body.set_instance_shader_parameter("paint_color",paint)
	parent.add_child(body)
	var glazing := MeshInstance3D.new()
	glazing.name = "TransparentCabinGlazing"
	glazing.mesh = glass_mesh(index)
	glazing.material_override = _material("glass")
	parent.add_child(glazing)
	var s := spec(index)
	var wheels: Array[Node3D] = []
	for x in [-1.0,1.0]:
		for z in [-1.0,1.0]:
			var wheel := MeshInstance3D.new()
			wheel.name = "AlloyWheel"
			wheel.mesh = wheel_mesh(index)
			wheel.material_override = _material("rubber")
			wheel.position = Vector3(x * (float(s.width)*.5-.075),wheel_radius(index),z*float(s.wheelbase)*.5)
			parent.add_child(wheel)
			wheels.append(wheel)
	var brake := StandardMaterial3D.new()
	brake.albedo_color = Color("af1820")
	brake.emission_enabled = true
	brake.emission = Color("ff271b")
	var rear := MeshInstance3D.new()
	rear.mesh = _lamp_mesh(index,false)
	rear.material_override = brake
	parent.add_child(rear)
	var headlights := MeshInstance3D.new()
	headlights.mesh = _lamp_mesh(index,true)
	var head_material := StandardMaterial3D.new()
	head_material.albedo_color = Color("fff3dd")
	head_material.emission_enabled = true
	head_material.emission = Color("fff3dd")
	head_material.emission_energy_multiplier = .65
	headlights.material_override = head_material
	parent.add_child(headlights)
	var turns: Array[StandardMaterial3D] = []
	for side in [-1.0,1.0]:
		var material := StandardMaterial3D.new()
		material.albedo_color = Color("c47617")
		material.emission_enabled = true
		material.emission = Color("ff971a")
		turns.append(material)
		var turn := MeshInstance3D.new()
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for end in [-1.0,1.0]: _box(st,Vector3(.12,.09,.025),Vector3(side*float(s.width)*.41,float(s.height)*.47,end*(float(s.length)*.5+.018)),Color.WHITE)
		turn.mesh = st.commit()
		turn.material_override = material
		parent.add_child(turn)
	if include_driver and detail:
		var seated := driver_model(index,Monkeys.height_for(index*17))
		var driver := MeshInstance3D.new()
		driver.name = "CanonicalMonkeyDriver"
		driver.mesh = seated.mesh
		driver.position = seated.report.offset
		driver.set_meta("standing_height",seated.report.standing_height)
		driver.set_meta("canonical_model","MonkeyRig")
		parent.add_child(driver)
	parent.set_meta("vehicle_class",s.id)
	parent.set_meta("driver_bounds",driver_bounds(index))
	parent.set_meta("cabin_bounds",cabin_bounds(index))
	return {"wheels":wheels,"brake_material":brake,"turn_materials":turns,"driver_bounds":driver_bounds(index),"cabin_bounds":cabin_bounds(index)}

static func wheel_radius(index: int) -> float: return .38 if index >= 5 and index != 8 else .315

static func mesh(index: int, detail := true, include_driver := true) -> ArrayMesh:
	var key := str(index)+("detail" if detail else "far")+("driver" if include_driver else "empty")
	if _meshes.has(key): return _meshes[key]
	var s := spec(index)
	var w := float(s.width)
	var h := float(s.height)
	var l := float(s.length)
	var cabin := window_bounds(index)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Rounded shoulder and tapered bumpers, an open glazed cabin, and distinct
	# hood/trunk/bed silhouettes replace the old one-size opaque cuboid.
	if detail: _body_shell(st,index)
	else: _loft(st,[Vector3(-l*.5,w*.41,h*.32),Vector3(-l*.43,w*.5,h*.45),Vector3(l*.42,w*.5,h*.46),Vector3(l*.5,w*.43,h*.34)],h*.22,Color.WHITE,true)
	_box(st,Vector3(w*.86,h*.045,cabin.size.z-.50),Vector3(0,h-.03,cabin.get_center().z+.025),Color.WHITE,true)
	_box(st,Vector3(w*.87,.065,l*.80),Vector3(0,.08,0),Color("292e34"))
	# Sloped hood and aft deck keep sedan, estate, cargo and pickup profiles distinct.
	var hood_end := cabin.position.z
	_quad(st,Vector3(-w*.43,h*.44,-l*.46),Vector3(w*.43,h*.44,-l*.46),Vector3(w*.45,h*.51,hood_end),Vector3(-w*.45,h*.51,hood_end),Color.WHITE,true)
	if index in [6,7]:
		var back := cabin.end.z
		if index == 6:
			_box(st,Vector3(w*.86,.08,l*.30),Vector3(0,h*.42,l*.30),Color("282c31"))
			for side in [-1.0,1.0]: _box(st,Vector3(.13,h*.20,l*.35),Vector3(side*w*.46,h*.51,l*.29),Color.WHITE,true)
			_box(st,Vector3(w*.92,h*.2,.12),Vector3(0,h*.51,l*.47),Color.WHITE,true)
		else:
			_box(st,Vector3(w*.95,h*.65,l*.43),Vector3(0,h*.645,back+l*.215),Color.WHITE,true)
	elif index in [2,4,5,9]:
		_box(st,Vector3(w*.91,h*.06,l*.20),Vector3(0,h-.03,l*.30),Color.WHITE,true)
		_box(st,Vector3(w*.92,h*.48,.10),Vector3(0,h*.68,l*.40),Color.WHITE,true)
	else:
		_quad(st,Vector3(-w*.45,h*.51,cabin.end.z),Vector3(w*.45,h*.51,cabin.end.z),Vector3(w*.43,h*.46,l*.47),Vector3(-w*.43,h*.46,l*.47),Color.WHITE,true)
	if not detail:
		_box(st,cabin.size*.97,cabin.get_center(),Color("243541"))
		for side in [-1.0,1.0]:
			for end in [-1.0,1.0]: _box(st,Vector3(.20,wheel_radius(index)*1.6,wheel_radius(index)*1.8),Vector3(side*(w*.5-.07),wheel_radius(index),end*float(s.wheelbase)*.5),Color("20242a"))
		_far_indicators(st,index)
		_meshes[key] = st.commit()
		return _meshes[key]
	# Narrow pillars and belt rails leave the driver visible through real glass.
	for side in [-1.0,1.0]:
		for fraction in [0.0,.54,1.0]:
			var bottom := Vector3(side*w*.43,cabin.position.y,cabin.position.z+cabin.size.z*fraction)
			var top := Vector3(side*w*.395,cabin.end.y,bottom.z+(.30 if fraction==0 else -.25 if fraction==1 else 0.0))
			_beam(st,bottom,top,.06,Color.WHITE,true)
		_box(st,Vector3(.055,.06,cabin.size.z),Vector3(side*w*.425,cabin.position.y,cabin.get_center().z),Color("282d31"))
		if detail:
			_box(st,Vector3(.15,.12,.22),Vector3(side*(w*.5+.045),h*.62,cabin.position.z+.26),Color.WHITE,true)
			for z in [cabin.position.z+.65,cabin.end.z-.25]: _box(st,Vector3(.024,.045,.16),Vector3(side*w*.485,h*.48,z),Color("bbc4c9"))
	if not detail: _box(st,cabin.size*.97,cabin.get_center(),Color("243541"))
	# The cushion is below the belt line; glazing is only the upper cabin.
	var seated := driver_model(index)
	var seat: Vector3 = seated.points.pelvis
	var steering := steering_position(index)
	_box(st,Vector3(w*.72,.14,.24),Vector3(0,steering.y-.04,cabin.position.z+.22),Color("252a30"))
	for side in [-1.0,1.0]:
		var at := Vector3(side*absf(seat.x),seat.y-.075,seat.z)
		_box(st,Vector3(.43,.10,.47),at,Color("393c42"))
		_box(st,Vector3(.43,.56,.095),at+Vector3(0,.25,.20),Color("393c42"))
	# Steering rim with an open centre, facing the actual hands.
	for segment in range(16):
		var a := float(segment)*TAU/16.0
		var b := float(segment+1)*TAU/16.0
		_beam(st,steering+Vector3(cos(a)*.17,sin(a)*.17,0),steering+Vector3(cos(b)*.17,sin(b)*.17,0),.026,Color("202429"))
	if detail:
		for end in [-1.0,1.0]:
			_box(st,Vector3(w*.45,.12,.025),Vector3(0,h*.32,end*(l*.5+.012)),Color("222a30"))
			_box(st,Vector3(.44,.125,.018),Vector3(0,h*.25,end*(l*.5+.029)),Color("e0e1d1"))
			for x in [-.14,-.07,0,.07,.14]: _box(st,Vector3(.018,.046,.004),Vector3(x,h*.25,end*(l*.5+.041)),Color("354452"))
		if index == 8: _box(st,Vector3(.60,.20,.25),Vector3(0,h+.12,0),Color("ffe1a0"))
	if not detail:
		for side in [-1.0,1.0]:
			for end in [-1.0,1.0]: _box(st,Vector3(.20,wheel_radius(index)*1.6,wheel_radius(index)*1.8),Vector3(side*(w*.5-.07),wheel_radius(index),end*float(s.wheelbase)*.5),Color("20242a"))
	var result := st.commit()
	_meshes[key] = result
	return result

static func glass_mesh(index: int) -> ArrayMesh:
	if _glass.has(index): return _glass[index]
	var c := window_bounds(index)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0,1.0]:
		_quad(st,Vector3(side*(c.size.x*.5+.06),c.position.y,c.position.z),Vector3(side*(c.size.x*.5+.06),c.position.y,c.end.z),Vector3(side*c.size.x*.5,c.end.y,c.end.z-.25),Vector3(side*c.size.x*.5,c.end.y,c.position.z+.30),Color.WHITE,false,side<0)
	_quad(st,Vector3(-c.size.x*.5-.06,c.position.y,c.position.z),Vector3(c.size.x*.5+.06,c.position.y,c.position.z),Vector3(c.size.x*.5,c.end.y,c.position.z+.30),Vector3(-c.size.x*.5,c.end.y,c.position.z+.30),Color.WHITE)
	_quad(st,Vector3(c.size.x*.5+.06,c.position.y,c.end.z),Vector3(-c.size.x*.5-.06,c.position.y,c.end.z),Vector3(-c.size.x*.5,c.end.y,c.end.z-.25),Vector3(c.size.x*.5,c.end.y,c.end.z-.25),Color.WHITE)
	var result := st.commit()
	_glass[index] = result
	return result

static func wheel_mesh(index: int) -> ArrayMesh:
	var key := "wheel"+str(index)
	if _meshes.has(key): return _meshes[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var radius := wheel_radius(index)
	for ring in range(2):
		var r := radius if ring == 0 else radius*.65
		for i in range(16):
			var a := float(i)*TAU/16
			var b := float(i+1)*TAU/16
			var x := .115 if ring == 0 else .117
			for sign in [-1.0,1.0]:
				_triangle(st,Vector3(sign*x,0,0),Vector3(sign*x,cos(a)*r,sin(a)*r),Vector3(sign*x,cos(b)*r,sin(b)*r),Color("262a2e") if ring==0 else Color("a2abb2"),false,sign>0)
			if ring==0:
				_quad(st,Vector3(-x,cos(a)*r,sin(a)*r),Vector3(x,cos(a)*r,sin(a)*r),Vector3(x,cos(b)*r,sin(b)*r),Vector3(-x,cos(b)*r,sin(b)*r),Color("25292c"))
	_meshes[key] = st.commit()
	return _meshes[key]

static func _far_indicators(st: SurfaceTool, index: int) -> void:
	# Four tiny lenses join the existing class mesh: no extra population draws.
	var s := spec(index)
	for end in [-1.0,1.0]:
		for side in [-1.0,1.0]:
			var at := Vector3(side*float(s.width)*.32,float(s.height)*.28,end*(float(s.length)*.5+.018))
			var points := [at+Vector3(-.12,-.045,0),at+Vector3(.12,-.045,0),at+Vector3(.12,.045,0),at+Vector3(-.12,.045,0)]
			for i in ([0,2,1,0,3,2] if end>0 else [0,1,2,0,2,3]):
				st.set_normal(Vector3(0,0,end))
				st.set_color(Color.WHITE)
				st.set_uv2(Vector2(0,1))
				st.add_vertex(points[i])

static func _lamp_mesh(index: int, front: bool) -> ArrayMesh:
	var s := spec(index)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0,1.0]: _box(st,Vector3(float(s.width)*.20,.12,.03),Vector3(side*float(s.width)*.32,float(s.height)*.47,float(s.length)*(-.5 if front else .5)),Color.WHITE)
	return st.commit()

static func _loft(st: SurfaceTool, rings: Array, bottom: float, color: Color, paint := false) -> void:
	for i in range(rings.size()-1):
		var a: Vector3 = rings[i]
		var b: Vector3 = rings[i+1]
		_quad(st,Vector3(-a.y,a.z,a.x),Vector3(a.y,a.z,a.x),Vector3(b.y,b.z,b.x),Vector3(-b.y,b.z,b.x),color,paint)
		for side in [-1.0,1.0]: _quad(st,Vector3(side*a.y,bottom,a.x),Vector3(side*b.y,bottom,b.x),Vector3(side*b.y,b.z,b.x),Vector3(side*a.y,a.z,a.x),color,paint,side<0)
	for i in [0,rings.size()-1]:
		var r: Vector3 = rings[i]
		_quad(st,Vector3(-r.y,bottom,r.x),Vector3(r.y,bottom,r.x),Vector3(r.y,r.z,r.x),Vector3(-r.y,r.z,r.x),color,paint,i==0)

static func _box(st: SurfaceTool, size: Vector3, at: Vector3, color: Color, paint := false) -> void:
	var p := size*.5
	var v := [at+Vector3(-p.x,-p.y,-p.z),at+Vector3(p.x,-p.y,-p.z),at+Vector3(p.x,p.y,-p.z),at+Vector3(-p.x,p.y,-p.z),at+Vector3(-p.x,-p.y,p.z),at+Vector3(p.x,-p.y,p.z),at+Vector3(p.x,p.y,p.z),at+Vector3(-p.x,p.y,p.z)]
	for f in [[0,3,2,1],[5,6,7,4],[4,7,3,0],[1,2,6,5],[3,7,6,2],[4,0,1,5]]: _quad(st,v[f[0]],v[f[1]],v[f[2]],v[f[3]],color,paint,true)

static func _quad(st: SurfaceTool,a:Vector3,b:Vector3,c:Vector3,d:Vector3,color:Color,paint:=false,reverse:=false) -> void:
	_triangle(st,a,b,c,color,paint,reverse)
	_triangle(st,a,c,d,color,paint,reverse)

static func _triangle(st:SurfaceTool,a:Vector3,b:Vector3,c:Vector3,color:Color,paint:=false,reverse:=false) -> void:
	var points := [a,c,b] if reverse else [a,b,c]
	var normal: Vector3 = (points[2]-points[0]).cross(points[1]-points[0]).normalized()
	for p:Vector3 in points:
		st.set_normal(normal)
		st.set_color(color)
		st.set_uv2(Vector2(1 if paint else 0,0))
		st.add_vertex(p)

static func driver_seat(index: int) -> Vector3:
	return driver_model(index,MonkeyRig.PLAYER_HEIGHT).points.pelvis

static func steering_position(index: int) -> Vector3:
	var targets: Dictionary = driver_model(index).report.targets
	return (targets[&"hand_left"]+targets[&"hand_right"])*.5

static func _beam(st: SurfaceTool, a: Vector3, b: Vector3, width: float, color: Color, paint := false) -> void:
	var box := BoxMesh.new()
	box.size = Vector3(width,a.distance_to(b),width)
	var up := (b-a).normalized()
	var side := up.cross(Vector3.FORWARD).normalized()
	var transform := Transform3D(Basis(side,up,side.cross(up)),(a+b)*.5)
	_append_mesh(st,box,transform,color,paint)

static func _ellipsoid(st: SurfaceTool,size:Vector3,at:Vector3,color:Color) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = .5
	sphere.height = 1.0
	sphere.radial_segments = 12
	sphere.rings = 6
	_append_mesh(st,sphere,Transform3D(Basis.IDENTITY.scaled(size),at),color,false)

static func _append_mesh(st:SurfaceTool,source:Mesh,transform:Transform3D,color:Color,paint:bool) -> void:
	var arrays := source.surface_get_arrays(0)
	var vertices:PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals:PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices:PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for i in indices:
		st.set_normal((transform.basis.inverse().transposed()*normals[i]).normalized())
		st.set_color(color)
		st.set_uv2(Vector2(1 if paint else 0,0))
		st.add_vertex(transform*vertices[i])

static func _body_shell(st:SurfaceTool,index:int) -> void:
	var s := spec(index)
	var length := float(s.length)
	var width := float(s.width)
	var height := float(s.height)
	var axle := float(s.wheelbase)*.5
	var radius := wheel_radius(index)+.045
	for side in [-1.0,1.0]:
		for segment in range(64):
			var z0 := -length*.5+length*float(segment)/64.0
			var z1 := -length*.5+length*float(segment+1)/64.0
			var low: Array[float] = []
			var widths: Array[float] = []
			var tops: Array[float] = []
			for z in [z0,z1]:
				var distance := minf(absf(z-axle),absf(z+axle))
				low.append(wheel_radius(index)+sqrt(maxf(radius*radius-distance*distance,0)) if distance<radius else .22)
				widths.append(width*lerpf(.49,.40,smoothstep(length*.38,length*.5,absf(z))))
				tops.append(height*lerpf(.51,.43,smoothstep(length*.35,length*.5,absf(z))))
			var a := Vector3(side*widths[0],low[0],z0)
			var b := Vector3(side*widths[1],low[1],z1)
			var c := Vector3(side*widths[1],maxf(low[1]+.025,tops[1]-.06),z1)
			var d := Vector3(side*widths[0],maxf(low[0]+.025,tops[0]-.06),z0)
			_quad(st,a,b,c,d,Color.WHITE,true,side<0)
			_quad(st,d,c,Vector3(side*(widths[1]-.055),tops[1],z1),Vector3(side*(widths[0]-.055),tops[0],z0),Color.WHITE,true,side<0)
		for end in [-1.0,1.0]:
			for segment in range(16):
				var a := float(segment)*PI/16
				var b := float(segment+1)*PI/16
				var x: float = side*(width*.491)
				var center := Vector3(x,wheel_radius(index),end*axle)
				_quad(st,center+Vector3(0,sin(a)*radius,cos(a)*radius),center+Vector3(0,sin(b)*radius,cos(b)*radius),center+Vector3(0,sin(b)*(radius+.027),cos(b)*(radius+.027)),center+Vector3(0,sin(a)*(radius+.027),cos(a)*(radius+.027)),Color("3b4145"),false,side<0)
	for end in [-1.0,1.0]:
		_quad(st,Vector3(-width*.40,.22,end*length*.5),Vector3(width*.40,.22,end*length*.5),Vector3(width*.40,height*.43,end*length*.5),Vector3(-width*.40,height*.43,end*length*.5),Color.WHITE,true,end>0)
	_box(st,Vector3(width*.68,.10,length*.82),Vector3(0,.24,0),Color("292c2f"))
