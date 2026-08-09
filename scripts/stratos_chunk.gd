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


func setup(sector_key: Vector2i) -> void:
	key = sector_key
	name = "Stratos_%d_%d" % [key.x, key.y]
	position = Vector3((float(key.x) + 0.5) * SECTOR_SIZE, 0.0,
		(float(key.y) + 0.5) * SECTOR_SIZE)
	_build_terrain()


func _build_terrain() -> void:
	var step := SECTOR_SIZE / float(CELLS)
	var x0 := float(key.x) * SECTOR_SIZE
	var z0 := float(key.y) * SECTOR_SIZE
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	canopy_vertex_count = 0
	canopy_relief_max = 0.0
	for iz in range(CELLS + 1):
		for ix in range(CELLS + 1):
			var x := x0 + float(ix) * step
			var z := z0 + float(iz) * step
			var h := Gen.height(x, z)
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
				st.set_color(water_color)
				st.add_vertex(Vector3(x - position.x, Gen.WATER_Y - 0.25,
					z - position.z))
			else:
				# Tint and physically lift forested vertices. A few metres of
				# deterministic cluster relief gives the 192 m lattice a broken
				# crown line without allocating per-tree geometry across 24 km.
				var ground := Gen.ground_color(h, x, z)
				var cover := Gen.canopy_cover(h, x, z)
				var relief := Gen.stratos_canopy_relief(cover, x, z)
				if cover > 0.0:
					ground = ground.lerp(Gen.canopy_color(x, z, h),
						cover * 0.74)
					canopy_vertex_count += 1
					canopy_relief_max = maxf(canopy_relief_max, relief)
				ground.a = cover
				st.set_color(ground)
				st.add_vertex(Vector3(x - position.x, h + relief, z - position.z))
	for iz in range(CELLS):
		for ix in range(CELLS):
			var p00 := iz * (CELLS + 1) + ix
			var p10 := p00 + 1
			var p01 := p00 + (CELLS + 1)
			var p11 := p01 + 1
			st.add_index(p00)
			st.add_index(p10)
			st.add_index(p11)
			st.add_index(p00)
			st.add_index(p11)
			st.add_index(p01)
	st.generate_normals()
	terrain_vertex_count = (CELLS + 1) * (CELLS + 1)
	var mi := MeshInstance3D.new()
	mi.name = "StratosTerrain"
	mi.mesh = st.commit()
	mi.material_override = Visuals.stratos_ground_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 100.0
	mi.ignore_occlusion_culling = true
	add_child(mi)
