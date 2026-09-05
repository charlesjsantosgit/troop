extends RefCounted
## Meter-scale street dressing, shared across the streamed neighborhood.
## Terrain remains the only road collision surface. All props are batched.
const Plan = preload("res://scripts/city_plan.gd")
const Park = preload("res://scripts/city_park.gd")
static var _pavement_mesh: PlaneMesh
static var _pavement_material: ShaderMaterial
static var _trunk_mesh: CylinderMesh
static var _leaf_mesh: SphereMesh
static var _trunk_material: StandardMaterial3D
static var _leaf_material: ShaderMaterial

static func append_geometry(key: Vector2i, curbs: Array[Transform3D],
		_markings: Array[Transform3D], landscape: Array[Transform3D],
		landscape_colors: Array[Color], metal: Array[Transform3D],
		glass: Array[Transform3D], lights: Array[Transform3D], light_colors: Array[Color]) -> void:
	if Plan.is_park_block(key): return
	var half := Plan.BLOCK_EXTENTS * 0.5
	# Only perimeter streets: the broad rectangular interior is buildings/courts.
	for axis in range(2):
		for side in [-1.0, 1.0]:
			var across: float = half[axis] - Plan.MAJOR_ROAD_HALF_WIDTH - 0.18
			var length: float = Plan.BLOCK_EXTENTS[1-axis] - 2.0 * (Plan.MAJOR_ROAD_HALF_WIDTH + 1.0)
			var at := Vector3(across * side, Plan.GROUND_Y + .07, 0)
			var size := Vector3(.24, .14, length)
			if axis == 1:
				at = Vector3(0, at.y, across * side)
				size = Vector3(length, .14, .24)
			curbs.append(_box(at, size))
	for side in [-1.0, 1.0]:
		for index in range(8):
			var p := Vector3(side * (half.x - 14.4), Plan.GROUND_Y, -118.0 + index * 33.7)
			metal.append(_box(p + Vector3(0,3.6,0), Vector3(.16,7.2,.16)))
			metal.append(_box(p + Vector3(side * 1.2,7.12,0), Vector3(2.55,.14,.16)))
			lights.append(_box(p + Vector3(side * 2.25,6.91,0), Vector3(.65,.045,.32)))
			light_colors.append(Color("ffe4bc"))
			if index % 3 == 0:
				var seat := p + Vector3(0,0,6.0)
				metal.append(_box(seat + Vector3(0,.28,-.75), Vector3(.5,.56,.08)))
				metal.append(_box(seat + Vector3(0,.28,.75), Vector3(.5,.56,.08)))
				for slat in range(4):
					landscape.append(_box(seat + Vector3(-.23+slat*.15,.55,0),Vector3(.11,.08,1.8)))
					landscape_colors.append(Color("846549"))
				metal.append(_box(seat + Vector3(-side*.28,.86,0),Vector3(.1,.5,1.8)))
				metal.append(_box(p + Vector3(0,.5,-3.0),Vector3(.6,1,.6)))
	if posmod(key.x + key.y,3)==0:
		var p := Vector3(-half.x+14.0,Plan.GROUND_Y,8)
		metal.append(_box(p+Vector3(0,1.5,0),Vector3(.16,3,1.5)))
		glass.append(_box(p+Vector3(.1,1.8,0),Vector3(.05,1.9,1.2)))

static func add_surfaces(parent: Node3D, key: Vector2i) -> int:
	_resources()
	var pavement := MeshInstance3D.new()
	pavement.name = "DetailedStreetSurface"
	pavement.mesh = _pavement_mesh
	pavement.material_override = _pavement_material
	pavement.position.y = Plan.GROUND_Y + 0.025
	pavement.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(pavement)
	var trunks: Array[Transform3D] = []
	var leaves: Array[Transform3D] = []
	var colors: Array[Color] = []
	var sites := _tree_sites(key)
	for index in range(sites.size()):
		var site: Dictionary = sites[index]
		var local: Vector3 = site.position
		var height: float = site.height
		trunks.append(_box(local + Vector3(0, height * 0.5, 0), Vector3(0.40, height, 0.40)))
		for crown in range(4):
			var offset := Vector3(sin(float(index + crown) * 2.4) * 0.45, float(crown % 2) * 0.85, cos(float(index - crown) * 2.1) * 0.65)
			offset += Vector3(site.lean)
			var size := Vector3(2.3, 3.4, 2.8) * float(site.spread)
			leaves.append(_box(local + Vector3(0, height + 0.35, 0) + offset, size))
			colors.append(Color("375936").lerp(Color("829854"), float(posmod(index * 7 + crown + key.x, 6)) / 7.0))
	parent.set_meta("street_tree_count", sites.size())
	_batch(parent, "StreetTreeTrunks", _trunk_mesh, _trunk_material, trunks, [])
	_batch(parent, "StreetTreeCanopies", _leaf_mesh, _leaf_material, leaves, colors)
	return 3

static func _resources() -> void:
	if _pavement_mesh != null: return
	_pavement_mesh = PlaneMesh.new()
	_pavement_mesh.size = Plan.BLOCK_EXTENTS - Vector2.ONE * .01
	_pavement_material = ShaderMaterial.new()
	_pavement_material.shader = preload("res://scripts/city_street_surface.gdshader")
	_pavement_material.set_shader_parameter("city_origin", Vector2(Plan.MIN_X, Plan.MIN_Z))
	_pavement_material.set_shader_parameter("city_center", Plan.CENTER)
	_pavement_material.set_shader_parameter("park_center", Plan.PARK_CENTER)
	_pavement_material.set_shader_parameter("park_half_extents", Plan.PARK_HALF_EXTENTS)
	_pavement_material.set_shader_parameter("block_size", Plan.BLOCK_EXTENTS)
	_pavement_material.set_shader_parameter("lot_spacing", Plan.STREET_SPACING)
	_pavement_material.set_shader_parameter("major_half_width", Plan.MAJOR_ROAD_HALF_WIDTH)
	_pavement_material.set_shader_parameter("local_half_width", Plan.LOCAL_ROAD_HALF_WIDTH)
	_pavement_material.set_shader_parameter("plaza_extent", Plan.PLAZA_HALF_EXTENT)
	_trunk_mesh = CylinderMesh.new()
	_trunk_mesh.top_radius = 0.38
	_trunk_mesh.bottom_radius = 0.5
	_trunk_mesh.height = 1.0
	_trunk_mesh.radial_segments = 7
	_leaf_mesh = SphereMesh.new()
	_leaf_mesh.radius = 0.5
	_leaf_mesh.height = 1.0
	_leaf_mesh.radial_segments = 10
	_leaf_mesh.rings = 5
	_trunk_material = StandardMaterial3D.new()
	_trunk_material.albedo_color = Color("625346")
	_trunk_material.roughness = 0.97
	_leaf_material = ShaderMaterial.new()
	_leaf_material.shader = preload("res://scripts/city_foliage.gdshader")

static func set_night_factor(factor: float) -> void:
	if _pavement_material != null:
		_pavement_material.set_shader_parameter("night_factor", clampf(factor, 0.0, 1.0))

static func _tree_sites(key: Vector2i) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if Plan.is_park_block(key): return result
	for side in [-1.0,1.0]:
		for index in range(8):
			result.append({"position":Vector3(side*(Plan.BLOCK_EXTENTS.x*.5-14.0),Plan.GROUND_Y,-110+index*32),
				"lean":Vector3(side,0,0),"height":5.8+posmod(key.x+key.y+index,5)*.42,"spread":1.25})
	return result

static func release_resources() -> void:
	# Explicitly drop shared shader references before renderer shutdown.
	_pavement_mesh = null
	_pavement_material = null
	_trunk_mesh = null
	_leaf_mesh = null
	_trunk_material = null
	_leaf_material = null
	Park.release_resources()

static func _box(at: Vector3, size: Vector3) -> Transform3D:
	return Transform3D(Basis.from_scale(size), at)

static func _batch(parent: Node3D, label: String, mesh: Mesh, material: Material,
		transforms: Array[Transform3D], colors: Array[Color]) -> void:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = not colors.is_empty()
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for index in range(transforms.size()):
		multi.set_instance_transform(index, transforms[index])
		if not colors.is_empty(): multi.set_instance_color(index, colors[index])
	var instance := MultiMeshInstance3D.new()
	instance.name = label
	instance.multimesh = multi
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
