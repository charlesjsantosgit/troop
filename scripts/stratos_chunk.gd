class_name StratosChunk
extends Node3D
## The fourth and farthest LOD tier: 6144 m sectors that exist only while the
## player's altitude buys a long horizon (up to 15 miles from the peaks). One
## indexed terrain draw per sector — water is baked straight into the lattice
## as flattened, depth-tinted vertices, so a sector is a single mesh with no
## physics or process cost. Its satellite-style base reads Gen.ground_color,
## then adds deterministic canopy tint and crown relief for the aircraft view.

const SECTOR_SIZE := Gen.CHUNK * Gen.STRATOS_SECTOR_CHUNKS
const CELLS := Gen.STRATOS_CELLS

var key := Vector2i.ZERO
var terrain_vertex_count := 0
var canopy_vertex_count := 0
var canopy_relief_max := 0.0
var sample_cells := CELLS
var _terrain_builder: SurfaceTool
var _terrain_step := 0.0
var _terrain_x0 := 0.0
var _terrain_z0 := 0.0
var _terrain_row_cursor := 0
var _build_complete := false


func setup(sector_key: Vector2i, requested_cells := CELLS,
		defer_build := false) -> void:
	key = sector_key
	sample_cells = clampi(requested_cells, 8, CELLS)
	name = "Stratos_%d_%d" % [key.x, key.y]
	position = Vector3((float(key.x) + 0.5) * SECTOR_SIZE, 0.0,
		(float(key.y) + 0.5) * SECTOR_SIZE)
	_begin_terrain_build()
	if not defer_build:
		while not build_terrain_step(sample_cells + 1):
			pass


func _begin_terrain_build() -> void:
	_terrain_step = SECTOR_SIZE / float(sample_cells)
	_terrain_x0 = float(key.x) * SECTOR_SIZE
	_terrain_z0 = float(key.y) * SECTOR_SIZE
	_terrain_builder = SurfaceTool.new()
	_terrain_builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	_terrain_row_cursor = 0
	_build_complete = false
	terrain_vertex_count = 0
	canopy_vertex_count = 0
	canopy_relief_max = 0.0


## Sample a bounded number of lattice rows, then commit once. Planet and road
## evaluation dominates sector construction; spreading those exact samples over
## several frames removes the old all-at-once main-thread spike without changing
## a vertex, color, index, normal, or sector boundary.
func build_terrain_step(row_budget := 4) -> bool:
	if _build_complete:
		return true
	if _terrain_builder == null:
		_begin_terrain_build()
	var row_end := mini(_terrain_row_cursor + maxi(row_budget, 1),
		sample_cells + 1)
	for iz in range(_terrain_row_cursor, row_end):
		for ix in range(sample_cells + 1):
			var x := _terrain_x0 + float(ix) * _terrain_step
			var z := _terrain_z0 + float(iz) * _terrain_step
			var visual := Gen.stratos_visual_sample(x, z)
			var h := float(visual.elevation)
			if h < Gen.WATER_Y:
				# Flatten submerged vertices to the waterline and tint them by
				# depth: at multi-kilometre range a colored plane reads exactly
				# like water while costing zero extra draws.
				var depth: float = clampf((Gen.WATER_Y - h) / 5.0, 0.0, 1.0)
				var water_color := Color(0.16, 0.42, 0.55).lerp(
					Color(0.05, 0.20, 0.33), depth)
				# Alpha is a data channel for the stratos shader: zero means water or
				# bare ground, while forest vertices carry their canopy coverage.
				water_color.a = 0.0
				_terrain_builder.set_color(water_color)
				_terrain_builder.add_vertex(Vector3(x - position.x,
					Gen.WATER_Y - 0.25,
					z - position.z))
			else:
				# Canopy relief stays a diagnostic/color input, not a height offset.
				# Every LOD tier therefore shares the exact same elevation samples at
				# its borders; the stratos shader supplies the broken crown pattern
				# without opening metre-high geometry seams during a handoff.
				var ground: Color = visual.color
				var cover := float(visual.cover)
				var relief := float(visual.relief)
				if cover > 0.0:
					canopy_vertex_count += 1
					canopy_relief_max = maxf(canopy_relief_max, relief)
				ground.a = cover
				_terrain_builder.set_color(ground)
				_terrain_builder.add_vertex(Vector3(x - position.x, h,
					z - position.z))
	_terrain_row_cursor = row_end
	if _terrain_row_cursor <= sample_cells:
		return false
	for iz in range(sample_cells):
		for ix in range(sample_cells):
			var p00 := iz * (sample_cells + 1) + ix
			var p10 := p00 + 1
			var p01 := p00 + (sample_cells + 1)
			var p11 := p01 + 1
			_terrain_builder.add_index(p00)
			_terrain_builder.add_index(p10)
			_terrain_builder.add_index(p11)
			_terrain_builder.add_index(p00)
			_terrain_builder.add_index(p11)
			_terrain_builder.add_index(p01)
	_terrain_builder.generate_normals()
	terrain_vertex_count = (sample_cells + 1) * (sample_cells + 1)
	var mi := MeshInstance3D.new()
	mi.name = "StratosTerrain"
	mi.mesh = _terrain_builder.commit()
	mi.material_override = Visuals.stratos_ground_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 100.0
	mi.ignore_occlusion_culling = true
	add_child(mi)
	_terrain_builder = null
	_build_complete = true
	return true


func is_build_complete() -> bool:
	return _build_complete
