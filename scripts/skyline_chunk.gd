class_name SkylineChunk
extends Node3D
## Visual-only 768 m skyline sector: the third LOD tier, existing so mountain
## ranges — and now the jungle itself — read from kilometres away. One indexed
## terrain draw at 48 m cells, one coarse water draw where lakes extend past
## the horizon ring, and one MultiMesh of simplified whole-tree silhouettes so
## the forest no longer vanishes past the 672 m horizon ring. Like
## HorizonChunk there are deliberately no collisions, props, shadows, signals,
## or process callbacks; the silhouettes are streamed in over idle frames by
## World the same way horizon trees are.

const SECTOR_CHUNKS := Gen.SKYLINE_SECTOR_CHUNKS
const SECTOR_SIZE := Gen.CHUNK * SECTOR_CHUNKS
const CELLS := SECTOR_CHUNKS  # one 48 m cell per chunk: 17x17 vertex lattice
## How strongly the terrain lattice is tinted toward canopy color where trees
## grow. The ground between silhouettes then reads as unbroken jungle instead
## of bare dirt, and the tier hands off cleanly to the fully-tinted stratos.
const CANOPY_TINT := 0.5
## MultiMesh buffer stride: 12 floats of 3x4 transform rows + RGBA color.
const INSTANCE_FLOATS := 16

static var _tree_mesh: ArrayMesh

var key := Vector2i.ZERO
var terrain_vertex_count := 0
var water_cell_count := 0
var tree_instance_count := 0
var _tree_build_cursor := 0
var _tree_build_complete := false
var _tree_buffer := PackedFloat32Array()


func setup(sector_key: Vector2i, defer_trees := false) -> void:
	key = sector_key
	name = "Skyline_%d_%d" % [key.x, key.y]
	position = Vector3((float(key.x) + 0.5) * SECTOR_SIZE, 0.0,
		(float(key.y) + 0.5) * SECTOR_SIZE)
	if not _tree_mesh:
		_tree_mesh = _build_tree_silhouette_mesh()
	_build_terrain_and_water()
	_begin_tree_silhouettes()
	if not defer_trees:
		build_tree_step(SECTOR_CHUNKS * SECTOR_CHUNKS)


func _build_terrain_and_water() -> void:
	var step := SECTOR_SIZE / float(CELLS)
	var x0 := float(key.x) * SECTOR_SIZE
	var z0 := float(key.y) * SECTOR_SIZE
	var heights := PackedFloat32Array()
	heights.resize((CELLS + 1) * (CELLS + 1))

	var terrain := SurfaceTool.new()
	terrain.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in range(CELLS + 1):
		for ix in range(CELLS + 1):
			var x := x0 + float(ix) * step
			var z := z0 + float(iz) * step
			var visual := Gen.skyline_visual_sample(x, z)
			var h := float(visual.elevation)
			heights[iz * (CELLS + 1) + ix] = h
			terrain.set_color(visual.color)
			terrain.add_vertex(Vector3(x - position.x, h, z - position.z))
	for iz in range(CELLS):
		for ix in range(CELLS):
			var p00 := iz * (CELLS + 1) + ix
			var p10 := p00 + 1
			var p01 := p00 + (CELLS + 1)
			var p11 := p01 + 1
			terrain.add_index(p00)
			terrain.add_index(p10)
			terrain.add_index(p11)
			terrain.add_index(p00)
			terrain.add_index(p11)
			terrain.add_index(p01)
	terrain.generate_normals()
	terrain_vertex_count = (CELLS + 1) * (CELLS + 1)
	var terrain_instance := MeshInstance3D.new()
	terrain_instance.name = "SkylineTerrain"
	terrain_instance.mesh = terrain.commit()
	terrain_instance.material_override = Visuals.skyline_ground_material()
	terrain_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	terrain_instance.visibility_range_end = Gen.SKYLINE_DISTANCE + SECTOR_SIZE
	terrain_instance.extra_cull_margin = 40.0
	add_child(terrain_instance)

	# Only submerged cells get water, sitting slightly below the horizon tier's
	# plane so overlapping tiers can never z-fight.
	var water := SurfaceTool.new()
	water.begin(Mesh.PRIMITIVE_TRIANGLES)
	var has_water := false
	for iz in range(CELLS):
		for ix in range(CELLS):
			var i00 := iz * (CELLS + 1) + ix
			var i10 := i00 + 1
			var i01 := i00 + (CELLS + 1)
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
			var y := Gen.WATER_Y - 0.11
			for point in [
				Vector3(xa, y, za), Vector3(xb, y, za), Vector3(xb, y, zb),
				Vector3(xa, y, za), Vector3(xb, y, zb), Vector3(xa, y, zb),
			]:
				water.set_normal(Vector3.UP)
				water.add_vertex(point)
	if has_water:
		var water_instance := MeshInstance3D.new()
		water_instance.name = "SkylineWater"
		water_instance.mesh = water.commit()
		water_instance.material_override = Visuals.far_water_material()
		water_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		water_instance.visibility_range_end = Gen.SKYLINE_DISTANCE + SECTOR_SIZE
		water_instance.extra_cull_margin = 8.0
		add_child(water_instance)


func _begin_tree_silhouettes() -> void:
	_tree_build_cursor = 0
	_tree_build_complete = false
	_tree_buffer.clear()


## Process a bounded number of source chunks so World can spread the 256-chunk
## sweep of a skyline sector across otherwise-idle frames. Returns true once
## the sector's silhouettes are fully committed. The per-chunk sampling is
## Gen.skyline_tree_layout — a few noise reads per chunk — and instances are
## appended straight into the final MultiMesh float buffer, so each step costs
## well under a millisecond and the finished sector uploads in one assignment.
func build_tree_step(source_chunk_budget := 16) -> bool:
	if _tree_build_complete:
		return true
	var first_cx := key.x * SECTOR_CHUNKS
	var first_cz := key.y * SECTOR_CHUNKS
	var total := SECTOR_CHUNKS * SECTOR_CHUNKS
	var stop := mini(_tree_build_cursor + maxi(source_chunk_budget, 1), total)
	while _tree_build_cursor < stop:
		var dx := int(_tree_build_cursor / SECTOR_CHUNKS)
		var dz := _tree_build_cursor % SECTOR_CHUNKS
		for tree in Gen.skyline_tree_layout(first_cx + dx, first_cz + dz):
			var p: Vector3 = tree.pos - position
			var r: float = tree.crown_r
			var color: Color = tree.color
			# 3x4 affine rows for a pure scale basis diag(r, trunk_h, r).
			_tree_buffer.append_array(PackedFloat32Array([
				r, 0.0, 0.0, p.x,
				0.0, float(tree.trunk_h), 0.0, p.y,
				0.0, 0.0, r, p.z,
				color.r, color.g, color.b, 1.0,
			]))
		_tree_build_cursor += 1
	if _tree_build_cursor < total:
		return false
	_tree_build_complete = true
	tree_instance_count = _tree_buffer.size() / INSTANCE_FLOATS
	if tree_instance_count == 0:
		return true
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _tree_mesh
	mm.instance_count = tree_instance_count
	mm.buffer = _tree_buffer
	var trees := MultiMeshInstance3D.new()
	trees.name = "TreeSilhouettes"
	trees.multimesh = mm
	trees.material_override = Visuals.skyline_jungle_material()
	trees.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	trees.visibility_range_end = Gen.SKYLINE_DISTANCE + SECTOR_SIZE
	trees.extra_cull_margin = 60.0
	add_child(trees)
	_tree_buffer.clear()
	return true


## Crown-only silhouette: the horizon tier's twelve-triangle faceted canopy,
## indexed down to eight shared vertices and minus its trunk — from 660 m+ a
## 0.3 m trunk subtends nothing, so those triangles would be pure vertex cost
## across tens of thousands of instances.
static func _build_tree_silhouette_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var points: Array[Vector3] = [Vector3(0, 1.20, 0), Vector3(0, 0.72, 0)]
	for i in range(6):
		var angle := TAU * float(i) / 6.0
		points.append(Vector3(cos(angle), 0.98, sin(angle)))
	for p in points:
		st.set_uv(Vector2(1.0, 0.0))
		st.set_color(Color.WHITE)
		st.add_vertex(p)
	for i in range(6):
		var ring_a := 2 + i
		var ring_b := 2 + ((i + 1) % 6)
		st.add_index(0)
		st.add_index(ring_a)
		st.add_index(ring_b)
		st.add_index(1)
		st.add_index(ring_b)
		st.add_index(ring_a)
	st.generate_normals()
	return st.commit()
