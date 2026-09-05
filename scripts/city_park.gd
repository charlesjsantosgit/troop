extends RefCounted
## Persistent Central Park-inspired landscape: continuous lawns and winding
## routes, natural lake shoreline, woodland clusters and a real boat landing.
const Plan = preload("res://scripts/city_plan.gd")
const Layout = preload("res://scripts/city_park_layout.gd")
static var _materials: Dictionary = {}
static var _meshes: Dictionary = {}

static func build(parent: Node3D) -> Dictionary:
	var terrain := _ground(parent)
	var water := _water(parent)
	var path_count := _paths(parent)
	var trees: Array[Dictionary] = await _trees(parent)
	var props := _props(parent)
	return {"ground_vertices": terrain, "water_vertices": water, "path_segments": path_count,
		"tree_sites": trees, "prop_instances": props, "render_batches": 12}

# Compatibility with old streamed park blocks. The persistent node owns all
# park geometry now; no multi-kilometre mesh is duplicated per city block.
static func add_surfaces(_parent: Node3D) -> int: return 0
static func append_plantings(_leaves: Array[Transform3D], _colors: Array[Color]) -> void: pass

static func _ground(parent: Node3D) -> int:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cells := Vector2i(ceili(Plan.PARK_HALF_EXTENTS.x*2/12),ceili(Plan.PARK_HALF_EXTENTS.y*2/12))
	for z in range(cells.y+1):
		for x in range(cells.x+1):
			var p := -Plan.PARK_HALF_EXTENTS+Vector2(x,z)/Vector2(cells)*Plan.PARK_HALF_EXTENTS*2
			st.set_normal(Vector3.UP)
			st.set_uv(p/8)
			st.add_vertex(Vector3(p.x,Plan.GROUND_Y-Plan.pond_depth(Plan.PARK_CENTER+p)+.025,p.y))
	for z in range(cells.y):
		for x in range(cells.x):
			var a := z*(cells.x+1)+x
			for i in [a,a+1,a+cells.x+2,a,a+cells.x+2,a+cells.x+1]: st.add_index(i)
	var material := ShaderMaterial.new()
	material.shader = preload("res://scripts/city_park_ground.gdshader")
	material.set_shader_parameter("park_center",Plan.PARK_CENTER)
	material.set_shader_parameter("pond_center",Plan.POND_CENTER)
	material.set_shader_parameter("pond_radii",Plan.POND_RADII)
	_mesh(parent,"LanternGardensGround",st.commit(),material)
	return (cells.x+1)*(cells.y+1)

static func _water(parent: Node3D) -> int:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := Plan.POND_CENTER-Plan.PARK_CENTER
	st.set_normal(Vector3.UP)
	st.set_uv(Vector2(.5,.5))
	st.add_vertex(Vector3(center.x,Plan.POND_SURFACE_Y,center.y))
	for i in range(257):
		var p := Plan.pond_shore(float(i)*TAU/256)-Plan.PARK_CENTER
		st.set_normal(Vector3.UP)
		st.set_uv((p-center)/(Plan.POND_RADII*2)+Vector2.ONE*.5)
		st.add_vertex(Vector3(p.x,Plan.POND_SURFACE_Y,p.y))
	for i in range(256):
		st.add_index(0);st.add_index(i+1);st.add_index(i+2)
	var material := ShaderMaterial.new()
	material.shader = preload("res://scripts/city_pond.gdshader")
	_mesh(parent,"LanternLakeWater",st.commit(),material)
	return 258

static func _paths(parent: Node3D) -> int:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments := 0
	var routes := Layout.walking_paths_world().duplicate()
	routes.append(Layout.cycle_path_world())
	for ri in range(routes.size()):
		var route: PackedVector2Array = routes[ri]
		var half := Layout.CYCLE_WIDTH*.5 if ri == routes.size()-1 else Layout.WALK_WIDTH*.5
		var color := Color("7b8377") if ri == routes.size()-1 else Color("b8b097")
		for i in range(1,route.size()):
			var direction := (route[i]-route[i-1]).normalized()
			var side := Vector2(-direction.y,direction.x)*half
			var quad := [route[i-1]-side,route[i-1]+side,route[i]+side,route[i]-side]
			for q in [0,2,1,0,3,2]:
				var p: Vector2 = quad[q]-Plan.PARK_CENTER
				st.set_normal(Vector3.UP);st.set_color(color)
				st.add_vertex(Vector3(p.x,Plan.GROUND_Y+.055,p.y))
			segments += 1
	st.index()
	_mesh(parent,"WindingWalksAndCycleway",st.commit(),_material("paths",Color.WHITE,true))
	return segments

static func _trees(parent: Node3D) -> Array[Dictionary]:
	var trunks: Array[Transform3D] = []
	var bark: Array[Color] = []
	var crowns: Array[Transform3D] = []
	var leaves: Array[Color] = []
	var sites: Array[Dictionary] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 804314
	var rows := int(Plan.PARK_HALF_EXTENTS.y*2/27)
	var cols := int(Plan.PARK_HALF_EXTENTS.x*2/27)
	var activity_sites := Layout.activities()
	for z in range(rows):
		if z > 0 and z % 4 == 0:
			await parent.get_tree().process_frame
			if not is_instance_valid(parent) or not parent.is_inside_tree(): return sites
		for x in range(cols):
			var p := -Plan.PARK_HALF_EXTENTS+Vector2((x+.5)*27,(z+.5)*27)+Vector2(rng.randf_range(-8,8),rng.randf_range(-8,8))
			var wp := Plan.PARK_CENTER+p
			if rng.randf() > .76 or Plan.pond_q(wp) < 1.18: continue
			if ((p-Vector2(5,-900))/Vector2(230,465)).length() < 1: continue
			if ((p-Vector2(-95,1300))/Vector2(145,215)).length() < 1: continue
			if absf(p.y-300) < 70 and p.x > 170: continue
			var activity_clear := false
			for activity in activity_sites:
				if Layout.world(p).distance_to(activity.position) < 46: activity_clear = true
			if activity_clear: continue
			if Layout.near_path(wp,7.5) or Layout.near_path(wp,8.5,true): continue
			var height := rng.randf_range(10,22)
			var spread := rng.randf_range(7.5,12.5)
			var origin := Vector3(p.x,Plan.GROUND_Y,p.y)
			trunks.append(_transform(origin+Vector3.UP*height*.43,Vector3(.55,height*.86,.55)))
			bark.append(Color("64543e"))
			for c in range(3):
				var offset := Vector3(sin(c*TAU/3)*spread*.22,height*(.67+.10*c),cos(c*TAU/3)*spread*.22)
				crowns.append(_transform(origin+offset,Vector3(spread,spread*.9,spread)))
				leaves.append(Color("365b37").lerp(Color("899b4f"),rng.randf()*.72))
			sites.append({"position":Layout.world(p),"height":height,"spread":spread,"radius":.42})
	_batch(parent,"ParkTreeTrunks",_shape("cylinder"),trunks,bark)
	_batch(parent,"ParkTreeCanopies",_shape("sphere"),crowns,leaves)
	return sites

static func _props(parent: Node3D) -> int:
	var boxes: Array[Transform3D] = []
	var colors: Array[Color] = []
	# Lakeside benches face the water, with generous passing space behind them.
	for i in range(48):
		var a := float(i)*TAU/48
		var p := Plan.pond_shore(a,1.18)-Plan.PARK_CENTER
		var yaw := -a+PI*.5
		_bench(boxes,colors,Vector3(p.x,Plan.GROUND_Y,p.y),yaw)
	for site in Layout.activities():
		var p: Vector3 = site.position-Vector3(Plan.PARK_CENTER.x,0,Plan.PARK_CENTER.y)
		for side in [-1.0,1.0]: _bench(boxes,colors,p+Vector3(side*8,0,9),0)
	# Yoga mats belong to the real activity positions, not a decorative texture.
	for i in range(18):
		var p := Vector2(-80+float(i%6-2)*2.8,-910+float(i/6)*3.0)
		boxes.append(_transform(Vector3(p.x,Plan.GROUND_Y+.075,p.y),Vector3(1.1,.07,2.15)))
		colors.append([Color("677f9c"),Color("916c91"),Color("638679")][i%3])
	# Low picnic tables and seating in the social clearing.
	for i in range(6):
		var at := Vector3(110+float(i%3)*7,Plan.GROUND_Y,-625+float(i/3)*8)
		boxes.append(_transform(at+Vector3.UP*.8,Vector3(2.2,.13,1.3)));colors.append(Color("98744d"))
		for side in [-1.0,1.0]:
			boxes.append(_transform(at+Vector3(side*.78,.38,0),Vector3(.14,.76,.95)));colors.append(Color("555e52"))
			boxes.append(_transform(at+Vector3(0,.46,side*.98),Vector3(2.3,.14,.37)));colors.append(Color("806844"))
	_batch(parent,"ParkBenchesMatsAndPicnics",_shape("box"),boxes,colors)
	_build_docks(parent)
	_boathouse(parent)
	return boxes.size()

static func _build_docks(parent: Node3D) -> void:
	var boxes: Array[Transform3D] = []
	var colors: Array[Color] = []
	var bank := Plan.pond_shore(0,1.08)
	for definition in Layout.boat_definitions():
		var p: Vector3 = definition.pos
		var start := Vector3(p.x-2.8,Layout.DOCK_TOP-.12,p.z+2.9)
		var finish := Vector3(bank.x+6,Layout.DOCK_TOP-.12,p.z+2.9)
		var size := Vector3(finish.x-start.x,.24,2.0)
		var center := (start+finish)*.5
		var local := center-Vector3(Plan.PARK_CENTER.x,0,Plan.PARK_CENTER.y)
		boxes.append(_transform(local,size));colors.append(Color("94734f"))
		_collider_box(parent,"SolidBoatLanding",local,size)
		for x in range(int(start.x),int(finish.x),6):
			for side in [-1.0,1.0]:
				boxes.append(_transform(Vector3(x-Plan.PARK_CENTER.x,Plan.POND_SURFACE_Y-.1,p.z+2.9-Plan.PARK_CENTER.y+side*.82),Vector3(.22,1.8,.22)))
				colors.append(Color("65543e"))
		# A low continuous wedge joins the dock to the dry bank without a step.
		_ramp(parent,Vector3(finish.x-Plan.PARK_CENTER.x,0,p.z+2.9-Plan.PARK_CENTER.y),5.0,2.0)
	_batch(parent,"TimberBoatLandings",_shape("box"),boxes,colors)

static func _ramp(parent: Node3D, start: Vector3, length: float, width: float) -> void:
	var points := PackedVector3Array()
	for z in [-width*.5,width*.5]:
		points.append(start+Vector3(0,Plan.GROUND_Y-.1,z))
		points.append(start+Vector3(0,Layout.DOCK_TOP,z))
		points.append(start+Vector3(length,Plan.GROUND_Y+.015,z))
	var shape := ConvexPolygonShape3D.new();shape.points = points
	var body := StaticBody3D.new();body.name = "AccessibleLandingRamp"
	var node := CollisionShape3D.new();node.shape = shape
	body.add_child(node);parent.add_child(body)
	var st := SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in [1,4,5,1,5,2]: st.set_normal(Vector3.UP);st.add_vertex(points[i])
	_mesh(parent,"LandingRampSurface",st.commit(),_material("wood",Color("94734f")))

static func _boathouse(parent: Node3D) -> void:
	var at := Layout.boathouse_position()-Vector3(Plan.PARK_CENTER.x,0,Plan.PARK_CENTER.y)
	var boxes: Array[Transform3D] = []
	var colors: Array[Color] = []
	for x in [-9.0,-3.0,3.0,9.0]:
		for z in [-4.0,4.0]:
			boxes.append(_transform(at+Vector3(x,2.3,z),Vector3(.38,4.6,.38)));colors.append(Color("e0d2b3"))
	for side in [-1.0,1.0]:
		var roof := Transform3D(Basis(Vector3.RIGHT,side*.27)*Basis.from_scale(Vector3(21,.25,5.4)),at+Vector3(0,4.8,side*2.5))
		boxes.append(roof);colors.append(Color("496b58"))
	_batch(parent,"LakesideBoathouse",_shape("box"),boxes,colors)
	var label := Label3D.new();label.text = "LANTERN LAKE\nROWBOAT LANDING"
	label.position = at+Vector3(0,3.7,-4.1);label.font_size = 42;label.pixel_size = .015
	label.modulate = Color("f4e6bb");label.outline_size = 6;label.visibility_range_end = 220
	parent.add_child(label)

static func _bench(items: Array[Transform3D], colors: Array[Color], at: Vector3, yaw: float) -> void:
	var basis := Basis(Vector3.UP,yaw)
	for side in [-1.0,1.0]:
		items.append(Transform3D(basis*Basis.from_scale(Vector3(.13,.60,.65)),at+basis*Vector3(side,.3,0)));colors.append(Color("3e5145"))
	for i in range(4):
		items.append(Transform3D(basis*Basis.from_scale(Vector3(2.6,.08,.12)),at+basis*Vector3(0,.63,-.24+i*.16)));colors.append(Color("927549"))
	items.append(Transform3D(basis*Basis.from_scale(Vector3(2.6,.5,.09)),at+basis*Vector3(0,.98,.36)));colors.append(Color("7c6343"))

static func _collider_box(parent: Node3D,label: String,at: Vector3,size: Vector3) -> void:
	var body := StaticBody3D.new();body.name = label
	var collider := CollisionShape3D.new();var shape := BoxShape3D.new();shape.size = size
	collider.shape = shape;collider.position = at
	body.add_child(collider);parent.add_child(body)

static func _shape(kind: String) -> Mesh:
	if _meshes.has(kind): return _meshes[kind]
	var mesh: Mesh
	if kind == "sphere":
		var sphere := SphereMesh.new();sphere.radius = .5;sphere.height = 1;sphere.radial_segments = 10;sphere.rings = 5;mesh = sphere
	elif kind == "cylinder":
		var cylinder := CylinderMesh.new();cylinder.top_radius = .36;cylinder.bottom_radius = .5;cylinder.height = 1;cylinder.radial_segments = 7;mesh = cylinder
	else:
		var box := BoxMesh.new();box.size = Vector3.ONE;mesh = box
	_meshes[kind] = mesh
	return mesh

static func _material(id: String, color: Color, vertex_color := false) -> StandardMaterial3D:
	if _materials.has(id): return _materials[id]
	var material := StandardMaterial3D.new();material.albedo_color = color
	material.vertex_color_use_as_albedo = vertex_color;material.roughness = .93
	_materials[id] = material
	return material

static func _batch(parent: Node3D,label: String,mesh: Mesh,items: Array[Transform3D],colors: Array[Color]) -> void:
	var mm := MultiMesh.new();mm.transform_format = MultiMesh.TRANSFORM_3D;mm.use_colors = true
	mm.mesh = mesh;mm.instance_count = items.size()
	for i in range(items.size()): mm.set_instance_transform(i,items[i]);mm.set_instance_color(i,colors[i])
	var node := MultiMeshInstance3D.new();node.name = label;node.multimesh = mm
	node.material_override = _material("instance",Color.WHITE,true)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)

static func _mesh(parent: Node3D,label: String,mesh: Mesh,material: Material) -> void:
	var node := MeshInstance3D.new();node.name = label;node.mesh = mesh;node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;parent.add_child(node)

static func _transform(at: Vector3,size: Vector3) -> Transform3D: return Transform3D(Basis.from_scale(size),at)
static func release_resources() -> void: _materials.clear();_meshes.clear();Layout.clear_resources()
