class_name HorizonChunk
extends Node3D
## Visual-only 192 m macro sector used beyond the interactive 5x5 chunk grid.
## Terrain, water and whole-tree silhouettes are each one spatially-cullable
## draw. There are deliberately no collisions, vines, pickups, signals,
## shadows, process callbacks, detailed water refraction, or gameplay nodes.

const TERRAIN_CELLS_PER_CHUNK := 4
const SECTOR_CHUNKS := Gen.HORIZON_SECTOR_CHUNKS
const SECTOR_SIZE := Gen.CHUNK * SECTOR_CHUNKS

static var _tree_mesh: ArrayMesh

var key := Vector2i.ZERO
var terrain_vertex_count := 0
var tree_instance_count := 0
var water_cell_count := 0
var _tree_build_cursor := 0
var _tree_build_complete := false
var _tree_transforms: Array[Transform3D] = []
var _tree_colors: Array[Color] = []


func setup(sector_key: Vector2i, defer_trees := false) -> void:
	key = sector_key
	name = "Horizon_%d_%d" % [key.x, key.y]
	position = Vector3((float(key.x) + 0.5) * SECTOR_SIZE, 0.0,
		(float(key.y) + 0.5) * SECTOR_SIZE)
	if not _tree_mesh:
		_tree_mesh = _build_tree_silhouette_mesh()
	_build_terrain_and_water()
	_begin_tree_silhouettes()
	if not defer_trees:
		build_tree_step(SECTOR_CHUNKS * SECTOR_CHUNKS)


func _build_terrain_and_water() -> void:
	var cells := TERRAIN_CELLS_PER_CHUNK * SECTOR_CHUNKS
	var step := SECTOR_SIZE / float(cells)
	var x0 := float(key.x) * SECTOR_SIZE
	var z0 := float(key.y) * SECTOR_SIZE
	var heights := PackedFloat32Array()
	heights.resize((cells + 1) * (cells + 1))

	var terrain := SurfaceTool.new()
	terrain.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in range(cells + 1):
		for ix in range(cells + 1):
			var x := x0 + float(ix) * step
			var z := z0 + float(iz) * step
			var h := Gen.height(x, z)
			heights[iz * (cells + 1) + ix] = h
			terrain.set_color(Gen.ground_color(h, x, z))
			terrain.add_vertex(Vector3(x - position.x, h, z - position.z))
	for iz in range(cells):
		for ix in range(cells):
			var p00 := iz * (cells + 1) + ix
			var p10 := p00 + 1
			var p01 := p00 + (cells + 1)
			var p11 := p01 + 1
			terrain.add_index(p00)
			terrain.add_index(p10)
			terrain.add_index(p11)
			terrain.add_index(p00)
			terrain.add_index(p11)
			terrain.add_index(p01)
	terrain.generate_normals()
	var terrain_mesh := terrain.commit()
	terrain_vertex_count = (cells + 1) * (cells + 1)
	var terrain_instance := MeshInstance3D.new()
	terrain_instance.name = "CoarseTerrain"
	terrain_instance.mesh = terrain_mesh
	terrain_instance.material_override = Visuals.far_ground_material()
	terrain_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	terrain_instance.visibility_range_end = Gen.HORIZON_DISTANCE + SECTOR_SIZE
	terrain_instance.extra_cull_margin = 20.0
	add_child(terrain_instance)

	# Build only submerged coarse cells. Unlike a huge transparent plane, this
	# never spends expensive water fragments over dry hills and cannot cover the
	# terrain in an opaque rectangle.
	var water := SurfaceTool.new()
	water.begin(Mesh.PRIMITIVE_TRIANGLES)
	var has_water := false
	for iz in range(cells):
		for ix in range(cells):
			var i00 := iz * (cells + 1) + ix
			var i10 := i00 + 1
			var i01 := i00 + (cells + 1)
			var i11 := i01 + 1
			var minimum := minf(minf(heights[i00], heights[i10]),
				minf(heights[i01], heights[i11]))
			if minimum > Gen.WATER_Y + 0.12:
				continue
			has_water = true
			water_cell_count += 1
			var xa := x0 + float(ix) * step - position.x
			var za := z0 + float(iz) * step - position.z
			var xb := xa + step
			var zb := za + step
			var y := Gen.WATER_Y - 0.055
			for point in [
				Vector3(xa, y, za), Vector3(xb, y, za), Vector3(xb, y, zb),
				Vector3(xa, y, za), Vector3(xb, y, zb), Vector3(xa, y, zb),
			]:
				water.set_normal(Vector3.UP)
				water.add_vertex(point)
	if has_water:
		var water_instance := MeshInstance3D.new()
		water_instance.name = "CoarseWater"
		water_instance.mesh = water.commit()
		water_instance.material_override = Visuals.far_water_material()
		water_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		water_instance.visibility_range_end = Gen.HORIZON_DISTANCE + SECTOR_SIZE
		water_instance.extra_cull_margin = 4.0
		add_child(water_instance)


func _begin_tree_silhouettes() -> void:
	_tree_build_cursor = 0
	_tree_build_complete = false
	_tree_transforms.clear()
	_tree_colors.clear()


## Process a bounded number of source chunks, allowing World to spread far-tree
## generation over several otherwise-idle frames instead of one sector spike.
func build_tree_step(source_chunk_budget := 4) -> bool:
	if _tree_build_complete:
		return true
	var first_cx := key.x * SECTOR_CHUNKS
	var first_cz := key.y * SECTOR_CHUNKS
	var total := SECTOR_CHUNKS * SECTOR_CHUNKS
	var stop := mini(_tree_build_cursor + maxi(source_chunk_budget, 1), total)
	while _tree_build_cursor < stop:
		var dx := int(_tree_build_cursor / SECTOR_CHUNKS)
		var dz := _tree_build_cursor % SECTOR_CHUNKS
		for tree in Gen.distant_tree_layout(first_cx + dx, first_cz + dz):
			if tree.blobs.is_empty():
				continue
			var canopy_radius := 0.0
			var tint := Color.BLACK
			for blob in tree.blobs:
				canopy_radius = maxf(canopy_radius, float(blob.r))
				tint += blob.color
			tint /= float(tree.blobs.size())
			tint.a = 1.0
			var basis := Basis.from_scale(Vector3(canopy_radius,
				float(tree.trunk_h), canopy_radius))
			_tree_transforms.append(Transform3D(basis,
				tree.pos - position))
			_tree_colors.append(tint)
		_tree_build_cursor += 1
	if _tree_build_cursor < total:
		return false
	_tree_build_complete = true
	if _tree_transforms.is_empty():
		return true
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _tree_mesh
	mm.instance_count = _tree_transforms.size()
	for i in range(_tree_transforms.size()):
		mm.set_instance_transform(i, _tree_transforms[i])
		mm.set_instance_color(i, _tree_colors[i])
	tree_instance_count = _tree_transforms.size()
	var trees := MultiMeshInstance3D.new()
	trees.name = "TreeSilhouettes"
	trees.multimesh = mm
	trees.material_override = Visuals.far_jungle_material()
	trees.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	trees.visibility_range_end = Gen.HORIZON_DISTANCE + SECTOR_SIZE
	trees.extra_cull_margin = 34.0
	add_child(trees)
	_tree_transforms.clear()
	_tree_colors.clear()
	return true


static func _build_tree_silhouette_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Four-sided trunk. UV.x=0 lets the shader keep bark brown while one
	# per-instance colour controls the canopy's biome tint.
	var sides := 4
	for i in range(sides):
		var a0 := TAU * float(i) / sides
		var a1 := TAU * float(i + 1) / sides
		var p0 := Vector3(cos(a0) * 0.16, 0.0, sin(a0) * 0.16)
		var p1 := Vector3(cos(a1) * 0.16, 0.0, sin(a1) * 0.16)
		var p2 := Vector3(p1.x, 0.94, p1.z)
		var p3 := Vector3(p0.x, 0.94, p0.z)
		for p in [p0, p1, p2, p0, p2, p3]:
			st.set_uv(Vector2(0.0, 0.0))
			st.set_color(Color.WHITE)
			st.add_vertex(p)
	# Twelve-triangle faceted crown: inexpensive enough for tens of thousands
	# of instances but still reads as a canopy rather than a billboard wall.
	var top := Vector3(0, 1.20, 0)
	var bottom := Vector3(0, 0.76, 0)
	var ring: Array[Vector3] = []
	for i in range(6):
		var angle := TAU * float(i) / 6.0
		ring.append(Vector3(cos(angle), 0.98, sin(angle)))
	for i in range(6):
		var next := (i + 1) % 6
		for p in [top, ring[i], ring[next], bottom, ring[next], ring[i]]:
			st.set_uv(Vector2(1.0, 0.0))
			st.set_color(Color.WHITE)
			st.add_vertex(p)
	st.generate_normals()
	return st.commit()
