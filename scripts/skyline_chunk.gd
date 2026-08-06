class_name SkylineChunk
extends Node3D
## Visual-only 768 m skyline sector: the third and farthest LOD tier, existing
## so mountain ranges read from kilometres away. One indexed terrain draw at
## 48 m cells plus one coarse water draw where lakes extend past the horizon
## ring. Like HorizonChunk there are deliberately no collisions, trees, props,
## shadows, signals, or process callbacks — and no per-frame cost at all: the
## sector is a static mesh from the moment it is built.

const SECTOR_CHUNKS := Gen.SKYLINE_SECTOR_CHUNKS
const SECTOR_SIZE := Gen.CHUNK * SECTOR_CHUNKS
const CELLS := SECTOR_CHUNKS  # one 48 m cell per chunk: 17x17 vertex lattice

var key := Vector2i.ZERO
var terrain_vertex_count := 0
var water_cell_count := 0


func setup(sector_key: Vector2i) -> void:
	key = sector_key
	name = "Skyline_%d_%d" % [key.x, key.y]
	position = Vector3((float(key.x) + 0.5) * SECTOR_SIZE, 0.0,
		(float(key.y) + 0.5) * SECTOR_SIZE)
	_build_terrain_and_water()


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
			var h := Gen.height(x, z)
			heights[iz * (CELLS + 1) + ix] = h
			terrain.set_color(Gen.ground_color(h, x, z))
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
