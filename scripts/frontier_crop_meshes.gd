class_name FrontierCropMeshes
extends RefCounted
## Shared botanical meshes: curved leaf blades, raised veins, segmented stems,
## blossoms and shaped fruit. One instanced draw per bed/LOD replaces hundreds
## of individual leaf nodes. No transparent billboard foliage is used.

static var _cache: Dictionary = {}
static var _materials: Dictionary = {}
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _indices := PackedInt32Array()
var _lod := 0
const GREEN := Color(0.23, 0.51, 0.12)
const VEIN := Color(0.47, 0.65, 0.22)


static func populate(root: Node3D, crop: String, growth: float, health: float) -> void:
	var tall := crop in ["banana", "plantain", "bamboo"]
	var count := 6 if tall else 12
	var size := lerpf(0.15, 1.0, clampf(growth, 0, 1))
	for lod in range(3):
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = mesh_for(crop, lod, mini(int(growth * 4.0),4))
		multi.instance_count = count
		for index in range(count):
			var xz := Vector3(-1.6 + (index % 3) * 1.6, 0.27,
				-1.45 + floorf(index / 3.0) * (2.8 if tall else 0.93))
			var turn := Basis(Vector3.UP, float(index) * 2.39996)
			multi.set_instance_transform(index, Transform3D(turn.scaled_local(Vector3.ONE * size), xz))
		var node := MultiMeshInstance3D.new()
		node.name = "BotanicalLOD%d" % lod
		node.multimesh = multi
		node.material_override = plant_material(health)
		node.visibility_range_begin = [0.0, 23.0, 65.0][lod]
		node.visibility_range_end = [23.0, 65.0, 200.0][lod]
		# Complementary visibility ranges do not accumulate opaque crop copies.
		node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if lod < 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(node)


static func plant_material(health := 1.0) -> StandardMaterial3D:
	var tier := clampi(roundi(health*4.0),0,4)
	if not _materials.has(tier):
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.vertex_color_is_srgb = true
		mat.albedo_color = Color(0.72,0.49,0.24).lerp(Color.WHITE,float(tier)/4.0)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.roughness = 0.88
		_materials[tier] = mat
	return _materials[tier]


static func mesh_for(crop: String, lod: int, development: Variant) -> ArrayMesh:
	var phase := (4 if development else 1) if development is bool else clampi(int(development),0,4)
	var key := "%s/%d/%d" % [crop,lod,phase]
	if not _cache.has(key):
		var builder := FrontierCropMeshes.new()
		builder._lod = clampi(lod, 0, 2)
		builder._plant(crop, phase)
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = builder._vertices
		arrays[Mesh.ARRAY_NORMAL] = builder._normals
		arrays[Mesh.ARRAY_COLOR] = builder._colors
		arrays[Mesh.ARRAY_INDEX] = builder._indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.set_meta("botanical_crop", crop)
		mesh.set_meta("botanical_lod", lod)
		mesh.set_meta("botanical_phase", phase)
		_cache[key] = mesh
	return _cache[key]


func _plant(crop: String, phase: int) -> void:
	var banana := crop in ["banana", "plantain"]
	var cereal := crop in ["rice", "maize", "flax", "bamboo"]
	var shrub := crop in ["tea", "coffee", "cocoa", "cotton", "tomato", "pepper", "soybean", "bean", "peanut"]
	var height := 1.9 if banana else 1.65 if crop == "bamboo" else 1.35 if cereal else 0.9 if shrub else 0.18
	var radius := 0.09 if banana else 0.035 if cereal else 0.024
	var stem: Array[Vector3] = [Vector3.ZERO, Vector3(0.02, height*0.34, 0), Vector3(-0.025,height*0.68,0.015), Vector3(0,height,0)]
	_tube(stem, radius, Color(0.43, 0.52, 0.19), 1.0, 0.52)
	var leaves := mini(2+phase*2, 8 if _lod == 0 else 6 if _lod == 1 else 4)
	for index in range(leaves):
		var angle := float(index) * 2.39996
		var row := float(index) / maxf(leaves-1, 1)
		var base := Vector3(0, height * (0.78 + row*0.2 if banana else 0.2 + row*0.72 if shrub or cereal else 0.24), 0)
		var length := 1.1 if banana else 0.75 if cereal else 0.47 if shrub else 0.51
		var width := 0.27 if banana else 0.065 if cereal else 0.16 if shrub else 0.27
		if crop in ["carrot", "radish", "flax"]:
			width *= 0.44
		if crop == "lettuce":
			length *= 0.77
			width *= 1.22
		var leaf_color := GREEN.lerp(Color(0.43, 0.63, 0.21), row * 0.35)
		_leaf(base, angle, length, width, 0.27 if banana else 0.19, 0.43 if banana else 0.10, leaf_color)
		if crop in ["carrot", "cassava"] and _lod < 2:
			for fork in [-1.0, 1.0]:
				_leaf(base + Vector3(sin(angle),0.15,cos(angle))*0.19, angle+fork*0.52, length*0.58, width*0.45,0.13,0.02,leaf_color)
	if cereal:
		for ring in range(5):
			_tube([Vector3(0,height*ring/5.0,0),Vector3(0,height*ring/5.0+0.025,0)],radius*1.21,VEIN)
	if phase==2 and crop in ["tomato","pepper","strawberry","cucumber","bean","soybean","cotton","coffee","cocoa"]:
		for flower in range(3):
			var at := Vector3(sin(flower*2.4)*0.2,height*(0.55+flower*0.1),cos(flower*2.4)*0.2)
			for petal in range(5):
				_leaf(at,petal*TAU/5.0,0.075,0.035,0.02,0.03,Color(0.97,0.87,0.39))
	if banana and phase>=2:
		_tube([Vector3(0,height,0),Vector3(0.25,1.53,0.12),Vector3(0.28,1.3,0.12)],0.025,VEIN)
		_fruit(Vector3(0.28,1.21,0.12),Vector3(0.07,0.15,0.07),Color(0.43,0.12,0.26),0.06)
	if phase<3:
		return
	if banana:
		for index in range(9 if _lod < 2 else 4):
			var a := index * 2.4
			var p := Vector3(0.2+cos(a)*0.09, 1.23+floorf(index/3.0)*0.13,sin(a)*0.09)
			_tube([p, p+Vector3(0.11,-0.05,0),p+Vector3(0.16,0.09,0)],0.041,(Color(0.91,0.77,0.14) if phase==4 else Color(0.41,0.63,0.13)),0.9,0.2)
	elif crop in ["tomato", "pepper", "strawberry", "cocoa", "coffee", "cucumber"]:
		var color := Color(0.84,0.13,0.05) if crop in ["tomato","pepper","strawberry","coffee"] else Color(0.51,0.23,0.08) if crop=="cocoa" else Color(0.15,0.39,0.08)
		if phase==3: color = GREEN.lightened(0.09)
		for index in range(5 if _lod < 2 else 3):
			var angle := index * 2.39996
			var p := Vector3(sin(angle)*0.23,height*(0.38+index*0.095),cos(angle)*0.23)
			var scale := Vector3(0.11,0.10,0.11) if crop=="tomato" else Vector3(0.075,0.17,0.075) if crop in ["pepper","cucumber","cocoa"] else Vector3(0.06,0.075,0.06)
			_fruit(p,scale,color,0.12 if crop=="pepper" else 0.04)
			_leaf(p+Vector3.UP*scale.y,angle,0.085,0.025,0.015,0.035,GREEN)
	elif cereal:
		var grain := Color(0.85,0.68,0.28)
		for index in range(7 if _lod < 2 else 3):
			var a := index * 2.4
			_fruit(Vector3(cos(a)*0.05,height+index*0.045,sin(a)*0.05),Vector3(0.036,0.056,0.025),grain)
	elif crop in ["bean","soybean"]:
		for index in range(4):
			var angle := index*2.4
			_fruit(Vector3(sin(angle)*0.18,0.43+index*0.085,cos(angle)*0.18),Vector3(0.045,0.15,0.035),Color(0.42,0.56,0.16),0.15)
	elif crop == "cotton":
		for index in range(4):
			_fruit(Vector3(sin(index*2.4)*0.22,0.5+index*0.1,cos(index*2.4)*0.22),Vector3.ONE*0.095,Color(0.97,0.94,0.81),0.1)
	elif crop in ["carrot", "radish", "taro", "sweet_potato", "cassava", "peanut"]:
		_fruit(Vector3(0,0.018,0),Vector3(0.12,0.12,0.12),Color(0.77,0.13,0.21) if crop=="radish" else Color(0.84,0.4,0.08) if crop=="carrot" else Color(0.52,0.30,0.15))
	elif crop not in ["lettuce","spinach","tea"]:
		# Small complete flowers, including a center and individually cupped petals.
		for petal in range(5):
			_leaf(Vector3(0,height+0.10,0),petal*TAU/5.0,0.07,0.032,0.035,0.025,Color(0.93,0.83,0.56))
		_fruit(Vector3(0,height+0.115,0),Vector3.ONE*0.035,Color(0.89,0.65,0.14))


func _leaf(base: Vector3, angle: float, length: float, width: float,
		rise: float, droop: float, color: Color) -> void:
	var along: int = [12,6,3][_lod]
	var across: int = [6,2,1][_lod]
	var forward := Vector3(sin(angle),0,cos(angle))
	var side := Vector3(cos(angle),0,-sin(angle))
	var offset := _vertices.size()
	for row in range(along+1):
		var u := float(row)/along
		var bulge := pow(maxf(sin(PI*u),0.001),0.68)
		for column in range(across+1):
			var v := float(column)/across*2.0-1.0
			var curl := width * (v*v*0.18 + absf(v)*0.12) * bulge
			var p := base + forward*length*u + side*width*bulge*v
			p.y += rise*sin(PI*u*0.85)-droop*u*u + curl
			var tangent := forward*length + Vector3.UP*(rise*PI*0.85*cos(PI*u*0.85)-2*droop*u)
			var normal := side.cross(tangent).normalized()
			if normal.y < 0: normal = -normal
			_vertex(p,normal,color.lightened(absf(v)*0.08+u*0.03))
	for row in range(along):
		for column in range(across):
			var i := offset+row*(across+1)+column
			_quad(i,i+1,i+across+1,i+across+2)
	if _lod == 0:
		var rib: Array[Vector3] = []
		for step in range(7):
			var u := step/6.0
			rib.append(base + forward*length*u + Vector3.UP*(rise*sin(PI*u*0.85)-droop*u*u+0.006))
		_tube(rib,0.008 if length>0.7 else 0.004,VEIN,1.0,0.18,5)
		for step in range(2,6):
			var u := step/7.0
			var center := base+forward*length*u+Vector3.UP*(rise*sin(PI*u*0.85)-droop*u*u+0.004)
			for sign_value: float in [-1.0,1.0]:
				var tip := center + side*sign_value*width*sin(PI*u)*0.85 + forward*length*0.075 + Vector3.UP*width*0.2
				_tube([center,tip],0.0025,VEIN.darkened(0.05),1.0,0.18,4)


func _tube(points: Array, radius: float, color: Color, start_scale := 1.0,
		end_scale := 1.0, sides := 0) -> void:
	var count: int = sides if sides > 0 else [12,7,5][_lod]
	var offset := _vertices.size()
	for ring in range(points.size()):
		var tangent: Vector3 = (points[mini(ring+1,points.size()-1)]-points[maxi(ring-1,0)]).normalized()
		var right := tangent.cross(Vector3.RIGHT if absf(tangent.y)>0.9 else Vector3.UP).normalized()
		var other := tangent.cross(right)
		var r := radius*lerpf(start_scale,end_scale,float(ring)/maxf(points.size()-1,1))
		for side in range(count):
			var a := side*TAU/count
			var normal := right*cos(a)+other*sin(a)
			_vertex(points[ring]+normal*r,normal,color)
	for ring in range(points.size()-1):
		for side in range(count):
			var a := offset+ring*count+side
			var b := offset+ring*count+(side+1)%count
			_quad(a,b,a+count,b+count)


func _fruit(center: Vector3, size: Vector3, color: Color, ribs := 0.0) -> void:
	var sides: int = [18,9,5][_lod]
	var rings: int = [12,6,3][_lod]
	var offset := _vertices.size()
	for ring in range(rings+1):
		var theta := PI*ring/rings
		for side in range(sides):
			var phi := TAU*side/sides
			var radial := 1.0+ribs*cos(phi*5.0)*sin(theta)
			var normal := Vector3(sin(theta)*cos(phi),cos(theta),sin(theta)*sin(phi))
			_vertex(center+normal*size*Vector3(radial,1,radial),normal,color.lightened(0.035*cos(phi)))
	for ring in range(rings):
		for side in range(sides):
			var a := offset+ring*sides+side
			var b := offset+ring*sides+(side+1)%sides
			_quad(a,b,a+sides,b+sides)


func _vertex(point: Vector3, normal: Vector3, color: Color) -> void:
	_vertices.append(point)
	_normals.append(normal)
	_colors.append(color)


func _quad(a: int, b: int, c: int, d: int) -> void:
	_triangle(a,b,c)
	_triangle(b,d,c)


func _triangle(a: int, b: int, c: int) -> void:
	var geometric := (_vertices[b]-_vertices[a]).cross(_vertices[c]-_vertices[a])
	if geometric.dot(_normals[a]+_normals[b]+_normals[c]) > 0:
		_indices.append_array(PackedInt32Array([a,c,b]))
	else:
		_indices.append_array(PackedInt32Array([a,b,c]))


static func phase_label(crop: String, phase: int) -> String:
	if phase==0: return "Seedling"
	if phase==1: return "Leaf growth"
	if phase>=4: return "Ready to harvest"
	if crop in ["lettuce","spinach","tea"]:
		return "Leaf canopy" if phase==2 else "Leaf filling"
	if crop in ["cassava","sweet_potato","taro","peanut","radish","carrot"]:
		return "Root formation" if phase==2 else "Roots filling"
	if crop=="bamboo": return "New shoots" if phase==2 else "Cane growth"
	if crop in ["rice","maize","flax"]:
		return "Flowering" if phase==2 else "Grain filling"
	return "Flowering" if phase==2 else "Fruit filling"
