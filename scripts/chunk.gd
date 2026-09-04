class_name Chunk
extends Node3D
## One 48m jungle tile: low-poly terrain, canopy trees with collision,
## hanging vines (single batched ribbon mesh), water, grass, rocks, bananas.

const SupplyHutScript = preload("res://scripts/supply_hut.gd")
const ArenaPieceScript = preload("res://scripts/arena_piece.gd")
const AirfieldHangarScript = preload("res://scripts/airfield_hangar.gd")
const FreewayTunnelScript = preload("res://scripts/freeway_tunnel.gd")
const RoadBridgeScript = preload("res://scripts/road_bridge.gd")

static var _mat_ground: Material
static var _mat_trunk: Material
static var _mat_vine: Material
static var _mat_water: Material
static var _mat_grass: Material
static var _mat_rock: Material
static var _tuft_mesh: ArrayMesh
static var _foliage_high_meshes: Array[ArrayMesh] = []
static var _foliage_low_meshes: Array[ArrayMesh] = []
static var _trunk_high_mesh: CylinderMesh
static var _trunk_low_mesh: CylinderMesh
static var _rock_mesh: SphereMesh
static var _water_mesh: PlaneMesh
static var _understory_meshes: Array[ArrayMesh] = []

var key := Vector2i.ZERO
var layout: Dictionary = {}
var _vine_mi: MeshInstance3D
var _terrain_mesh: ArrayMesh
## Retain the tiny CPU lattice until collision is requested. Reading it back
## from ArrayMesh forces the renderer to finish queued work on every new tile.
var _terrain_collision_vertices := PackedVector3Array()
var _terrain_collision_cells := 0
var _terrain_instance: MeshInstance3D
var _terrain_coarse := false
var _terrain_has_water := false
var _water_instance: MeshInstance3D
var _collision_bodies: Array[StaticBody3D] = []
var _collisions_built := false
var _collisions_active := false
var _supply_huts: Array[SupplyHut] = []
var _arena_pieces: Array[ArenaPiece] = []
var _airfield_hangars: Array[AirfieldHangar] = []
var _freeway_tunnels: Array[FreewayTunnel] = []
var _road_bridges: Array[RoadBridge] = []
var _details_pending := false
var _detail_build_stage := 0
var _pending_collected: Dictionary = {}
var _pending_build_collisions := false
var _layout_pending := false
var _vines_registered := false
var _vine_signal_connected := false
var _literal_foliage_visible := true
var _literal_foliage_nodes: Array[GeometryInstance3D] = []

const TREE_HIGH_END := 72.0
const TREE_LOW_BEGIN := 60.0
const TREE_LOD_MARGIN := 12.0
const FOLIAGE_VARIANT_COUNT := 3
const COARSE_TERRAIN_CELLS := 1
const TERRAIN_COLLISION_SNAP := 0.0001


static func _init_mats() -> void:
	if _mat_ground:
		return
	_mat_ground = Visuals.ground_material()
	_mat_trunk = Visuals.trunk_material()
	_mat_vine = Visuals.vine_material(0.022)
	_mat_water = Visuals.water_material()
	_mat_grass = Visuals.grass_material()
	_mat_rock = Visuals.rock_material()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for rot in [0.0, PI * 0.5]:
		var right := Vector3(cos(rot), 0, sin(rot)) * 0.14
		# tapered blade: wide at the roots, pointed tip
		var tip := Vector3(0, 0.34, 0)
		st.add_vertex(-right); st.add_vertex(tip); st.add_vertex(right)
		st.add_vertex(right); st.add_vertex(tip); st.add_vertex(-right)
	st.generate_normals()
	_tuft_mesh = st.commit()
	# Reuse a tiny deterministic set of faceted crown clusters. A populated
	# chunk still emits exactly one high and one low foliage MultiMesh; selecting
	# one cached variant per chunk avoids adding draw calls or per-tree resources.
	for variant in range(FOLIAGE_VARIANT_COUNT):
		_foliage_high_meshes.append(_make_foliage_cluster_mesh(variant, false))
		_foliage_low_meshes.append(_make_foliage_cluster_mesh(variant, true))
	_trunk_high_mesh = CylinderMesh.new()
	_trunk_high_mesh.bottom_radius = 1.0
	_trunk_high_mesh.top_radius = 0.7
	_trunk_high_mesh.height = 1.0
	_trunk_high_mesh.radial_segments = 7
	_trunk_low_mesh = CylinderMesh.new()
	_trunk_low_mesh.bottom_radius = 1.0
	_trunk_low_mesh.top_radius = 0.7
	_trunk_low_mesh.height = 1.0
	_trunk_low_mesh.radial_segments = 4
	_rock_mesh = SphereMesh.new()
	_rock_mesh.radius = 1.0
	_rock_mesh.height = 1.4
	_rock_mesh.radial_segments = 7
	_rock_mesh.rings = 4
	_water_mesh = PlaneMesh.new()
	_water_mesh.size = Vector2(Gen.CHUNK, Gen.CHUNK)
	_water_mesh.subdivide_width = Gen.CELLS
	_water_mesh.subdivide_depth = Gen.CELLS
	_understory_meshes = [
		_make_understory_mesh(0),
		_make_understory_mesh(1),
		_make_understory_mesh(2),
	]


## Builds overlapping asymmetric bipyramids instead of a smooth sphere. The
## high mesh is 72 opaque triangles (8 + 7 + 7 + 7 + 7 sided lobes); the low
## mesh is 20 (two 5-sided lobes), both safely inside the foliage LOD budgets.
static func _make_foliage_cluster_mesh(variant: int, low_detail: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var centers: Array[Vector3] = []
	var radii: Array[Vector3] = []
	var sides: Array[int] = []
	var phase := float(variant) * 0.67
	if low_detail:
		match variant:
			0:
				centers = [Vector3(-0.27, 0.08, -0.07),
					Vector3(0.30, -0.10, 0.09)]
				radii = [Vector3(0.70, 0.65, 0.66),
					Vector3(0.68, 0.62, 0.67)]
			1:
				centers = [Vector3(-0.18, -0.09, 0.24),
					Vector3(0.22, 0.10, -0.22)]
				radii = [Vector3(0.76, 0.61, 0.61),
					Vector3(0.68, 0.65, 0.71)]
			_:
				centers = [Vector3(-0.31, -0.05, -0.15),
					Vector3(0.25, 0.07, 0.18)]
				radii = [Vector3(0.66, 0.63, 0.72),
					Vector3(0.73, 0.64, 0.63)]
		sides = [5, 5]
	else:
		match variant:
			0:
				centers = [Vector3(0.0, 0.03, 0.0),
					Vector3(-0.45, 0.04, 0.12), Vector3(0.44, -0.07, 0.15),
					Vector3(0.08, 0.24, -0.38), Vector3(-0.07, -0.18, 0.39)]
				radii = [Vector3(0.70, 0.66, 0.68),
					Vector3(0.54, 0.48, 0.50), Vector3(0.54, 0.46, 0.49),
					Vector3(0.48, 0.52, 0.51), Vector3(0.50, 0.50, 0.51)]
			1:
				centers = [Vector3(-0.03, 0.01, 0.02),
					Vector3(-0.38, -0.10, -0.26), Vector3(0.43, 0.10, -0.12),
					Vector3(-0.18, 0.26, 0.34), Vector3(0.20, -0.19, 0.37)]
				radii = [Vector3(0.68, 0.67, 0.70),
					Vector3(0.55, 0.47, 0.48), Vector3(0.52, 0.49, 0.54),
					Vector3(0.50, 0.51, 0.49), Vector3(0.51, 0.48, 0.50)]
			_:
				centers = [Vector3(0.02, -0.02, -0.01),
					Vector3(-0.46, 0.12, -0.06), Vector3(0.40, -0.16, 0.25),
					Vector3(0.17, 0.26, -0.35), Vector3(-0.21, -0.13, 0.38)]
				radii = [Vector3(0.71, 0.64, 0.67),
					Vector3(0.50, 0.51, 0.54), Vector3(0.56, 0.47, 0.48),
					Vector3(0.50, 0.50, 0.51), Vector3(0.52, 0.49, 0.49)]
		sides = [8, 7, 7, 7, 7]
	for i in range(centers.size()):
		_add_foliage_lobe(st, centers[i], radii[i], sides[i],
			phase + float(i) * 0.91)
	st.generate_normals()
	return st.commit()


static func _add_foliage_lobe(st: SurfaceTool, center: Vector3, radii: Vector3,
		side_count: int, phase: float) -> void:
	var ring: Array[Vector3] = []
	for i in range(side_count):
		var angle := phase + TAU * float(i) / float(side_count)
		var radial_wobble := 1.0 + sin(float(i) * 2.37 + phase * 1.71) * 0.085
		var vertical_wobble := sin(float(i) * 1.79 + phase) * radii.y * 0.075
		ring.append(center + Vector3(cos(angle) * radii.x * radial_wobble,
			vertical_wobble,
			sin(angle) * radii.z * (2.0 - radial_wobble)))
	var lean := Vector3(cos(phase * 1.31), 0, sin(phase * 1.31))
	var top := center + Vector3.UP * radii.y \
		+ lean * minf(radii.x, radii.z) * 0.10
	var bottom := center - Vector3.UP * radii.y \
		- lean * minf(radii.x, radii.z) * 0.045
	for i in range(side_count):
		var next := (i + 1) % side_count
		# Clockwise from outside so generated normals keep seasonal snow on top.
		st.add_vertex(top)
		st.add_vertex(ring[next])
		st.add_vertex(ring[i])
		st.add_vertex(bottom)
		st.add_vertex(ring[i])
		st.add_vertex(ring[next])


static func _make_understory_mesh(kind: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if kind == 0:
		# Low spreading fern: eight tapered fronds, slightly lifted at the tips.
		for i in range(8):
			var angle := TAU * float(i) / 8.0
			var direction := Vector3(cos(angle), 0, sin(angle))
			var side := Vector3(-direction.z, 0, direction.x) * 0.16
			var root := Vector3(0, 0.035, 0)
			var shoulder := direction * 0.30 + Vector3.UP * 0.14
			var tip := direction * 0.72 + Vector3.UP * 0.23
			st.add_vertex(root - side * 0.35)
			st.add_vertex(shoulder + side)
			st.add_vertex(tip)
			st.add_vertex(root - side * 0.35)
			st.add_vertex(tip)
			st.add_vertex(shoulder - side)
	elif kind == 1:
		# Upright broad leaves make the mid-storey read as more than grass.
		for i in range(6):
			var angle := TAU * float(i) / 6.0
			var direction := Vector3(cos(angle), 0, sin(angle))
			var side := Vector3(-direction.z, 0, direction.x) * 0.20
			var base := direction * 0.08
			var middle := direction * 0.28 + Vector3.UP * 0.52
			var tip := direction * 0.40 + Vector3.UP * 1.03
			st.add_vertex(base - side * 0.35)
			st.add_vertex(middle + side)
			st.add_vertex(tip)
			st.add_vertex(base - side * 0.35)
			st.add_vertex(tip)
			st.add_vertex(middle - side)
	else:
		# Tall crossed reeds for broad wetland margins and shallow water.
		for rot in [0.0, PI * 0.5, PI * 0.25]:
			var side := Vector3(cos(rot), 0, sin(rot)) * 0.10
			var lean := Vector3(-sin(rot), 0, cos(rot)) * 0.12
			st.add_vertex(-side)
			st.add_vertex(lean + Vector3.UP * 1.55)
			st.add_vertex(side)
	st.generate_normals()
	return st.commit()


func setup(k: Vector2i, collected: Dictionary, build_collisions := true,
		defer_details := false, coarse_terrain := false) -> void:
	key = k
	_init_mats()
	_layout_pending = defer_details
	if defer_details:
		# Publish the terrain shell first. The complete deterministic layout moves
		# to the already bounded detail lane instead of blocking a 1000 mph shell.
		layout = {"trees": [], "bananas": [], "rocks": [], "foliage": [],
			"structures": [], "arena_pieces": [], "arena_id": "",
			"airfield_hangars": [], "freeway_tunnels": [], "road_bridges": []}
	else:
		_prepare_layout()
	_build_terrain(coarse_terrain)
	_build_water(coarse_terrain)
	_pending_collected = collected
	_pending_build_collisions = build_collisions
	_details_pending = true
	_detail_build_stage = 0
	if not defer_details:
		finish_deferred_build()


## Streaming can publish the terrain/water shell first, then finish detail and
## collision work in bounded stages. Explicit warm calls retain the immediate
## path for deterministic test and solo startup semantics.
func finish_deferred_build() -> void:
	while _details_pending:
		finish_deferred_build_step()


## Completes one bounded portion of a streamed chunk. The immediate warm path
## still calls finish_deferred_build(), while normal streaming spreads mesh and
## collision creation across frames.
func finish_deferred_build_step() -> bool:
	if not _details_pending:
		return true
	if _layout_pending:
		_prepare_layout()
		return false
	# Flight shells publish a 12 m lattice at roughly one-twelfth the generation
	# cost. Upgrade in this same bounded lane before any playable structures,
	# foliage, or collision can depend on the terrain.
	if _terrain_coarse:
		_build_terrain(false)
		_build_water(false)
		return false
	match _detail_build_stage:
		0:
			_build_arena_pieces()
		1:
			_build_airfield_hangars()
		2:
			_build_supply_huts()
			_build_freeway_tunnels()
			_build_road_bridges()
		3:
			if _pending_build_collisions:
				_build_collisions()
		4:
			_build_rocks()
		5:
			_request_vehicle_spawns()
		6:
			_build_bananas(_pending_collected)
		7:
			_build_trees()
		8:
			_build_grass()
		9:
			_build_understory()
		10:
			_build_vine_mesh()
	_detail_build_stage += 1
	if _detail_build_stage > 10:
		_details_pending = false
		_pending_collected = {}
		_pending_build_collisions = false
	return not _details_pending


func is_deferred_build_pending() -> bool:
	return _details_pending


## Literal crowns, trunks, grass, understory, and vines are useful only at
## gameplay distance. World can hide them as one bounded group during flight
## while retaining terrain, structures, pickups, vehicles, and collision.
func set_literal_foliage_visible(next_visible: bool) -> void:
	_literal_foliage_visible = next_visible
	for node in _literal_foliage_nodes:
		if is_instance_valid(node):
			node.visible = next_visible


func has_literal_foliage() -> bool:
	for node in _literal_foliage_nodes:
		if is_instance_valid(node):
			return true
	return false


func is_coarse_terrain_shell() -> bool:
	return _terrain_coarse


func _register_literal_foliage(node: GeometryInstance3D) -> void:
	node.visible = _literal_foliage_visible
	_literal_foliage_nodes.append(node)


func _exit_tree() -> void:
	if _vines_registered:
		Gen.unregister_chunk_vines(key)


func _prepare_layout() -> void:
	layout = Gen.chunk_layout(key.x, key.y)
	Gen.register_chunk_vines(key, layout)
	_vines_registered = true
	if not _vine_signal_connected:
		Gen.vine_visual_changed.connect(_on_vine_changed)
		_vine_signal_connected = true
	_layout_pending = false


func _on_vine_changed(k: Vector2i) -> void:
	if k == key:
		_build_vine_mesh()


func _build_terrain(coarse := false) -> void:
	_terrain_coarse = coarse
	var cells := COARSE_TERRAIN_CELLS if coarse else Gen.CELLS
	_terrain_collision_cells = cells
	_terrain_collision_vertices.resize((cells + 1) * (cells + 1))
	var x0 := key.x * Gen.CHUNK
	var z0 := key.y * Gen.CHUNK
	var cell := Gen.CHUNK / float(cells)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_terrain_has_water = false
	var points := PackedVector3Array()
	var colors := PackedColorArray()
	points.resize((cells + 1) * (cells + 1))
	colors.resize(points.size())
	# The fine lattice contains every 12 m Horizon corner. Retain those original
	# samples so the visual handoff needs no additional generator evaluations.
	var parent_subdivisions := Gen.CELLS / HorizonChunk.TERRAIN_CELLS_PER_CHUNK
	var parent_samples: Dictionary = {}
	# Both resolutions include their exact chunk boundaries. A coarse 2x2 flight
	# lattice therefore hands off without cracks and upgrades to the indexed 17x17
	# gameplay lattice before landing.
	for iz in range(cells + 1):
		for ix in range(cells + 1):
			var x := x0 + float(ix) * cell
			var z := z0 + float(iz) * cell
			var visual := Gen.terrain_vertex_sample(x, z)
			var h := float(visual.elevation)
			_terrain_has_water = _terrain_has_water \
				or h < Gen.WATER_Y + 0.05
			var point := Vector3(x, h, z)
			var vertex_index := iz * (cells + 1) + ix
			points[vertex_index] = point
			colors[vertex_index] = visual.color
			if not coarse and ix % parent_subdivisions == 0 \
					and iz % parent_subdivisions == 0:
				var color: Color = visual.color
				# ArrayMesh stores COLOR as UNORM8. Quantize before interpolation,
				# exactly as the parent's uploaded corner colors are quantized.
				color = _terrain_uploaded_color(color)
				parent_samples[Vector2i(ix / parent_subdivisions,
					iz / parent_subdivisions)] = Vector4(h, color.r, color.g, color.b)
			# Match TriangleMesh::create's snapping and indexed face order.
			_terrain_collision_vertices[vertex_index] = point.snappedf(
				TERRAIN_COLLISION_SNAP)
	for iz in range(cells + 1):
		for ix in range(cells + 1):
			var vertex_index := iz * (cells + 1) + ix
			var point := points[vertex_index]
			var color := colors[vertex_index]
			# Flight-only coarse quads cannot represent the finer parent lattice.
			# Their identity target prevents any unwanted vertex displacement.
			var parent: Vector4
			if coarse:
				var uploaded_color := _terrain_uploaded_color(color)
				parent = Vector4(point.y, uploaded_color.r, uploaded_color.g,
					uploaded_color.b)
			else:
				parent = _terrain_parent_sample(ix, iz, parent_subdivisions,
					parent_samples)
			st.set_color(color)
			st.set_uv(Vector2(parent.y, parent.z))
			st.set_uv2(Vector2(parent.x, parent.w))
			st.add_vertex(point)
	for iz in range(cells):
		for ix in range(cells):
			var p00 := iz * (cells + 1) + ix
			var p10 := p00 + 1
			var p01 := p00 + (cells + 1)
			var p11 := p01 + 1
			# Godot front faces wind clockwise seen from above (+Y).
			for index in [p00, p10, p11, p00, p11, p01]:
				st.add_index(index)
	st.generate_normals()
	var mesh := st.commit()
	_terrain_mesh = mesh
	if is_instance_valid(_terrain_instance):
		_terrain_instance.visible = false
		_terrain_instance.queue_free()
	_terrain_instance = MeshInstance3D.new()
	_terrain_instance.name = "TerrainShellCoarse" if coarse else "TerrainShellFine"
	_terrain_instance.mesh = mesh
	_terrain_instance.material_override = _mat_ground
	add_child(_terrain_instance)


## Parent height and tint use Horizon's p00/p10/p11, p00/p11/p01 triangles.
## Local integer coordinates avoid rounding changes at negative world tiles.
static func _terrain_parent_sample(ix: int, iz: int, subdivisions: int,
		parent_samples: Dictionary) -> Vector4:
	var parent_cells := HorizonChunk.TERRAIN_CELLS_PER_CHUNK
	var px := mini(ix / subdivisions, parent_cells - 1)
	var pz := mini(iz / subdivisions, parent_cells - 1)
	var fx := float(ix) / float(subdivisions) - float(px)
	var fz := float(iz) / float(subdivisions) - float(pz)
	var p00: Vector4 = parent_samples[Vector2i(px, pz)]
	var p11: Vector4 = parent_samples[Vector2i(px + 1, pz + 1)]
	if fx >= fz:
		var p10: Vector4 = parent_samples[Vector2i(px + 1, pz)]
		return p00 * (1.0 - fx) + p10 * (fx - fz) + p11 * fz
	var p01: Vector4 = parent_samples[Vector2i(px, pz + 1)]
	return p00 * (1.0 - fz) + p01 * (fz - fx) + p11 * fx


static func _terrain_uploaded_color(color: Color) -> Color:
	return Color(floorf(clampf(color.r, 0.0, 1.0) * 255.0) / 255.0,
		floorf(clampf(color.g, 0.0, 1.0) * 255.0) / 255.0,
		floorf(clampf(color.b, 0.0, 1.0) * 255.0) / 255.0, color.a)


func _build_water(coarse := false) -> void:
	if is_instance_valid(_water_instance):
		return
	var x0 := key.x * Gen.CHUNK
	var z0 := key.y * Gen.CHUNK
	# Coarse flight terrain already sampled every tile corner. Reuse that result
	# instead of doing 25 otherwise
	# invisible height calls per streamed tile at 1000 mph.
	var low := _terrain_has_water if coarse else false
	if not coarse:
		for i in range(5):
			for j in range(5):
				if Gen.height(x0 + i * Gen.CHUNK / 4.0,
						z0 + j * Gen.CHUNK / 4.0) < Gen.WATER_Y + 0.05:
					low = true
					break
			if low:
				break
	if not low:
		return
	# Match the terrain grid so the layered surface waves and local WaterFX
	# ripples have enough vertices to deform smoothly at gameplay distance.
	# Every wet chunk reuses the same immutable subdivided mesh resource.
	_water_instance = MeshInstance3D.new()
	_water_instance.mesh = _water_mesh
	_water_instance.material_override = _mat_water
	_water_instance.position = Vector3(x0 + Gen.CHUNK * 0.5,
		Gen.WATER_Y, z0 + Gen.CHUNK * 0.5)
	_water_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The streamer bounds this fine-water grid. Camera-to-tile-center culling
	# disagreed with the coarse shader's player-to-fragment handoff, exposing
	# holes near chunk edges and beneath elevated cameras. Keep normal frustum
	# culling; the resident-grid boundary is covered by the water-only fade.
	add_child(_water_instance)


func _build_trees() -> void:
	var center := Vector3(key.x * Gen.CHUNK + Gen.CHUNK * 0.5, 0,
		key.y * Gen.CHUNK + Gen.CHUNK * 0.5)
	var foliage_variant: int = _foliage_variant_index()
	var high_trunk_xforms: Array[Transform3D] = []
	var low_trunk_xforms: Array[Transform3D] = []
	var high_trunk_colors: Array[Color] = []
	var low_trunk_colors: Array[Color] = []
	var leaf_xforms: Array[Transform3D] = []
	var leaf_colors: Array[Color] = []

	for t in layout.trees:
		var trunk_tint := Color.WHITE
		match int(t.get("biome", Gen.Biome.RAINFOREST)):
			Gen.Biome.BAMBOO_GROVE:
				trunk_tint = Color(0.72, 1.18, 0.48)
			Gen.Biome.WETLAND:
				trunk_tint = Color(0.62, 0.70, 0.50)
			Gen.Biome.HIGHLAND:
				trunk_tint = Color(0.78, 0.88, 0.78)
		var trunk_scale := Basis.from_scale(Vector3(t.trunk_r, t.trunk_h, t.trunk_r))
		var trunk_transform := Transform3D(trunk_scale,
			t.pos - center + Vector3.UP * t.trunk_h * 0.5)
		high_trunk_xforms.append(trunk_transform)
		low_trunk_xforms.append(trunk_transform)
		high_trunk_colors.append(trunk_tint)
		low_trunk_colors.append(trunk_tint)

		for bl in t.blobs:
			var leaf_color: Color = bl.get("color",
				Color(0.93, 0.55, 0.68) if bl.flower else \
				Color.from_hsv(0.27 + bl.shade * 0.07, 0.58,
					0.42 + bl.shade * 0.3))
			var leaf_position: Vector3 = t.pos + bl.off
			var leaf_hash: int = _foliage_instance_hash(leaf_position)
			var yaw := TAU * float(_positive_mod(leaf_hash, 2048)) / 2048.0
			var x_scale := 0.94 + float(_positive_mod(leaf_hash >> 11, 7)) * 0.02
			var y_scale := 0.96 + float(_positive_mod(leaf_hash >> 17, 5)) * 0.02
			var leaf_scale: Vector3 = \
				Vector3(x_scale, y_scale, 2.0 - x_scale) * bl.r
			var leaf_basis := Basis(Vector3.UP, yaw) * Basis.from_scale(leaf_scale)
			leaf_xforms.append(Transform3D(leaf_basis, leaf_position - center))
			leaf_colors.append(leaf_color)

		for br in t.branches:
			var axis: Vector3 = Vector3.UP.cross(br.dir).normalized()
			var basis := Basis(axis, PI * 0.5)
			var branch_center: Vector3 = t.pos - center + br.dir * (br.len * 0.5) \
				+ Vector3(0, br.h, 0)
			var branch_scale := Basis.from_scale(Vector3(br.r, br.len, br.r))
			high_trunk_xforms.append(Transform3D(basis * branch_scale, branch_center))
			high_trunk_colors.append(trunk_tint)

	_add_tree_lod_multimesh(_trunk_high_mesh, high_trunk_xforms,
		high_trunk_colors, _mat_trunk, center,
		0.0, TREE_HIGH_END, true)
	_add_tree_lod_multimesh(_trunk_low_mesh, low_trunk_xforms,
		low_trunk_colors, _mat_trunk, center,
		TREE_LOW_BEGIN, 220.0, false)
	_add_foliage_lod_multimesh(_foliage_high_meshes[foliage_variant], leaf_xforms,
		leaf_colors, center, 0.0, TREE_HIGH_END, false)
	_add_foliage_lod_multimesh(_foliage_low_meshes[foliage_variant], leaf_xforms,
		leaf_colors, center, TREE_LOW_BEGIN, 220.0, false)


func _foliage_variant_index() -> int:
	var mixed := key.x * 73856093
	mixed = mixed ^ (key.y * 19349663)
	mixed = mixed ^ (int(Gen.world_seed) * 83492791)
	return _positive_mod(mixed, FOLIAGE_VARIANT_COUNT)


static func _foliage_instance_hash(position: Vector3) -> int:
	var mixed := roundi(position.x * 64.0) * 73856093
	mixed = mixed ^ (roundi(position.y * 64.0) * 19349663)
	mixed = mixed ^ (roundi(position.z * 64.0) * 83492791)
	return mixed


static func _positive_mod(value: int, divisor: int) -> int:
	return ((value % divisor) + divisor) % divisor


func _make_tree_collision(t: Dictionary) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = t.pos

	var tc := CollisionShape3D.new()
	var tshape := CylinderShape3D.new()
	tshape.radius = t.trunk_r
	tshape.height = t.trunk_h
	tc.shape = tshape
	tc.position = Vector3(0, t.trunk_h * 0.5, 0)
	body.add_child(tc)

	for bl in t.blobs:
		var cc := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = bl.r * 0.85
		cyl.height = bl.r * 1.0
		cc.shape = cyl
		# top sits slightly below the leafy dome so feet sink into the foliage
		cc.position = bl.off + Vector3(0, bl.r * 0.12, 0)
		body.add_child(cc)

	for br in t.branches:
		var axis: Vector3 = Vector3.UP.cross(br.dir).normalized()
		var basis := Basis(axis, PI * 0.5)
		var center: Vector3 = br.dir * (br.len * 0.5) + Vector3(0, br.h, 0)
		var bc := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = br.r
		cap.height = br.len + br.r * 2.0
		bc.shape = cap
		bc.transform = Transform3D(basis, center)
		body.add_child(bc)

	return body


func _add_tree_lod_multimesh(mesh: Mesh, xforms: Array[Transform3D],
		colors: Array[Color], material: Material, center: Vector3, begin_distance: float,
		end_distance: float, cast_shadows: bool) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, colors[i] if i < colors.size() else Color.WHITE)
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = mm
	instance.material_override = material
	instance.position = center
	instance.visibility_range_begin = begin_distance
	instance.visibility_range_end = end_distance
	instance.visibility_range_begin_margin = TREE_LOD_MARGIN if begin_distance > 0.0 else 0.0
	instance.visibility_range_end_margin = TREE_LOD_MARGIN
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_register_literal_foliage(instance)
	add_child(instance)


func _add_foliage_lod_multimesh(mesh: Mesh, xforms: Array[Transform3D],
		colors: Array[Color], center: Vector3, begin_distance: float,
		end_distance: float, cast_shadows: bool) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, colors[i])
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = mm
	instance.material_override = Visuals.foliage_lod_material()
	instance.position = center
	instance.visibility_range_begin = begin_distance
	instance.visibility_range_end = end_distance
	instance.visibility_range_begin_margin = TREE_LOD_MARGIN if begin_distance > 0.0 else 0.0
	instance.visibility_range_end_margin = TREE_LOD_MARGIN
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_register_literal_foliage(instance)
	add_child(instance)


func _build_rocks() -> void:
	if layout.rocks.is_empty():
		return
	var center := Vector3(key.x * Gen.CHUNK + Gen.CHUNK * 0.5, 0,
		key.y * Gen.CHUNK + Gen.CHUNK * 0.5)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _rock_mesh
	mm.instance_count = layout.rocks.size()
	for i in range(layout.rocks.size()):
		var rock: Dictionary = layout.rocks[i]
		var scale_basis := Basis.from_scale(Vector3.ONE * float(rock.r))
		mm.set_instance_transform(i, Transform3D(scale_basis,
			rock.pos - center))
	var rocks := MultiMeshInstance3D.new()
	rocks.name = "Rocks"
	rocks.multimesh = mm
	rocks.material_override = _mat_rock
	rocks.position = center
	rocks.visibility_range_end = 72.0
	rocks.visibility_range_end_margin = 12.0
	rocks.visibility_range_fade_mode = \
		GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(rocks)


func _build_grass() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = key.x * 917 + key.y * 3181 + Gen.world_seed
	var x0 := key.x * Gen.CHUNK
	var z0 := key.y * Gen.CHUNK
	var center := Vector3(x0 + Gen.CHUNK * 0.5, 0, z0 + Gen.CHUNK * 0.5)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _tuft_mesh
	var xf: Array[Transform3D] = []
	for i in range(52):
		var x := x0 + rng.randf() * Gen.CHUNK
		var z := z0 + rng.randf() * Gen.CHUNK
		var inside_structure := _inside_structure_clearance(x, z)
		var h := Gen.height(x, z)
		if h < Gen.WATER_Y + 0.15 or h > Gen.TREE_LINE:
			continue
		if Gen.point_on_road(x, z) or Gen.point_on_airstrip(x, z):
			continue
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.7, 1.5))
		if not inside_structure:
			xf.append(Transform3D(b, Vector3(x, h, z) - center))
	if xf.is_empty():
		return
	mm.instance_count = xf.size()
	for i in range(xf.size()):
		mm.set_instance_transform(i, xf[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _mat_grass
	mmi.position = center
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = 58.0
	mmi.visibility_range_end_margin = 10.0
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	_register_literal_foliage(mmi)
	add_child(mmi)


func _build_understory() -> void:
	if not layout.has("foliage") or layout.foliage.is_empty():
		return
	var x0 := key.x * Gen.CHUNK
	var z0 := key.y * Gen.CHUNK
	var center := Vector3(x0 + Gen.CHUNK * 0.5, 0,
		z0 + Gen.CHUNK * 0.5)
	var transforms: Array = [[], [], []]
	var colors: Array = [[], [], []]
	for plant in layout.foliage:
		var kind := clampi(int(plant.kind), 0, 2)
		var scale_v := float(plant.scale)
		var vertical := 1.18 if kind == 1 else (1.42 if kind == 2 else 0.92)
		var basis := Basis(Vector3.UP, float(plant.yaw)).scaled(
			Vector3(scale_v, scale_v * vertical, scale_v))
		transforms[kind].append(Transform3D(basis, plant.pos - center))
		colors[kind].append(plant.color)
	for kind in range(3):
		var xf: Array = transforms[kind]
		if xf.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _understory_meshes[kind]
		mm.instance_count = xf.size()
		for i in range(xf.size()):
			mm.set_instance_transform(i, xf[i])
			mm.set_instance_color(i, colors[kind][i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = ["Ferns", "Broadleaf", "WetlandReeds"][kind]
		mmi.multimesh = mm
		mmi.material_override = Visuals.foliage_lod_material()
		mmi.position = center
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = 72.0 if kind < 2 else 94.0
		mmi.visibility_range_end_margin = 12.0
		mmi.visibility_range_fade_mode = \
			GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		_register_literal_foliage(mmi)
		add_child(mmi)


## Deterministic vehicle spawn points stream through the chunk pipeline, but
## the spawned machines are world-level nodes with a session-wide dedupe, so a
## re-streamed chunk never duplicates a jeep someone drove away.
func _request_vehicle_spawns() -> void:
	var owner_world := get_parent()
	if owner_world and owner_world.has_method("request_vehicle_spawns"):
		owner_world.call("request_vehicle_spawns",
			Gen.vehicle_layout(key.x, key.y))


func _build_supply_huts() -> void:
	for structure in layout.get("structures", []):
		if str(structure.get("kind", "")) != "supply_hut":
			continue
		var opened := false
		var owner_world := get_parent()
		if owner_world and owner_world.has_method("is_supply_hut_opened"):
			opened = owner_world.is_supply_hut_opened(str(structure.get("id", "")))
		var hut: SupplyHut = SupplyHutScript.new()
		hut.configure(structure, opened)
		add_child(hut)
		_supply_huts.append(hut)


func _build_arena_pieces() -> void:
	for piece_data in layout.get("arena_pieces", []):
		var piece: ArenaPiece = ArenaPieceScript.new()
		piece.configure(piece_data)
		add_child(piece)
		_arena_pieces.append(piece)


func _build_airfield_hangars() -> void:
	for hangar_data in layout.get("airfield_hangars", []):
		var hangar: AirfieldHangar = AirfieldHangarScript.new()
		hangar.configure(hangar_data)
		add_child(hangar)
		_airfield_hangars.append(hangar)


func _build_freeway_tunnels() -> void:
	for tunnel_data in layout.get("freeway_tunnels", []):
		var tunnel: FreewayTunnel = FreewayTunnelScript.new()
		tunnel.configure(tunnel_data)
		add_child(tunnel)
		_freeway_tunnels.append(tunnel)


func _build_road_bridges() -> void:
	for bridge_data in layout.get("road_bridges", []):
		var bridge: RoadBridge = RoadBridgeScript.new()
		bridge.configure(bridge_data)
		add_child(bridge)
		_road_bridges.append(bridge)


func _inside_structure_clearance(x: float, z: float) -> bool:
	for structure in layout.get("structures", []):
		var structure_pos: Vector3 = structure.get("pos", Vector3.ZERO)
		var radius := float(structure.get("clearance", Gen.SUPPLY_HUT_CLEARANCE))
		if Vector2(x, z).distance_squared_to(
				Vector2(structure_pos.x, structure_pos.z)) < radius * radius:
			return true
	for piece in layout.get("arena_pieces", []):
		var piece_pos: Vector3 = piece.get("pos", Vector3.ZERO)
		var piece_radius := float(piece.get("clearance", 0.0))
		if Vector2(x, z).distance_squared_to(
				Vector2(piece_pos.x, piece_pos.z)) < piece_radius * piece_radius:
			return true
	for hangar in layout.get("airfield_hangars", []):
		var hangar_pos: Vector3 = hangar.get("pos", Vector3.ZERO)
		var hangar_radius := float(hangar.get("clearance",
			Gen.AIRSTRIP_HANGAR_CLEARANCE))
		if Vector2(x, z).distance_squared_to(
				Vector2(hangar_pos.x, hangar_pos.z)) \
				< hangar_radius * hangar_radius:
			return true
	for feature_key in ["freeway_tunnels", "road_bridges"]:
		for feature in layout.get(feature_key, []):
			var feature_pos: Vector3 = feature.get("pos", Vector3.ZERO)
			var feature_radius := float(feature.get("clearance", 0.0))
			if Vector2(x, z).distance_squared_to(
					Vector2(feature_pos.x, feature_pos.z)) \
					< feature_radius * feature_radius:
				return true
	return false


## All this chunk's vines batched into one mesh: crossed sagging ribbons with a
## bright leaf-tuft diamond at the grab-friendly bottom end.
func _build_vine_mesh() -> void:
	if _vine_mi:
		_literal_foliage_nodes.erase(_vine_mi)
		_vine_mi.queue_free()
		_vine_mi = null
	if not Gen._vines_by_chunk.has(key):
		return
	var ids: Array = Gen._vines_by_chunk[key]
	var center := Vector3(key.x * Gen.CHUNK + Gen.CHUNK * 0.5, 0,
		key.y * Gen.CHUNK + Gen.CHUNK * 0.5)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for id in ids:
		var v: Dictionary = Gen.vines.get(id, {})
		if v.is_empty() or v.hidden or bool(v.get("simulated", false)):
			continue
		any = true
		var anchor: Vector3 = v.anchor
		var vl := float(v.len)
		var phase := float(hash(id) % 628) / 100.0
		var segs := 6
		var prev := anchor
		for s in range(segs):
			var t0 := float(s) / segs
			var t1 := float(s + 1) / segs
			var sway := minf(0.4, vl * 0.045)
			var p0 := anchor + Vector3.DOWN * (vl * t0) + Vector3(sin(phase + t0 * 2.1), 0, cos(phase + t0 * 1.7)) * sway * t0
			var p1 := anchor + Vector3.DOWN * (vl * t1) + Vector3(sin(phase + t1 * 2.1), 0, cos(phase + t1 * 1.7)) * sway * t1
			# The debug playground dresses vines as workshop ropes: braided
			# tan strands, thicker, with no leaf tint.
			var low := Color(0.42, 0.30, 0.16) if Gen.debug_world \
				else Color(0.2, 0.28, 0.1)
			var high := Color(0.55, 0.42, 0.24) if Gen.debug_world \
				else Color(0.3, 0.42, 0.13)
			var c0 := low.lerp(high, t0)
			var c1 := low.lerp(high, t1)
			_ribbon(st, p0 - center, p1 - center,
				0.075 if Gen.debug_world else 0.055, c0, c1)
			prev = p1
		var tipc := Color(0.62, 0.48, 0.28) if Gen.debug_world \
			else Color(0.5, 0.72, 0.25)
		_ribbon(st, prev - center + Vector3(0.18, 0.3, 0),
			prev - center + Vector3(-0.18, -0.12, 0), 0.13, tipc, tipc)
		_ribbon(st, prev - center + Vector3(0, 0.3, 0.18),
			prev - center + Vector3(0, -0.12, -0.18), 0.13, tipc, tipc)
	if not any:
		return
	st.generate_normals()
	_vine_mi = MeshInstance3D.new()
	_vine_mi.mesh = st.commit()
	_vine_mi.material_override = _mat_vine
	_vine_mi.position = center
	_vine_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vine_mi.visibility_range_end = 108.0
	_vine_mi.visibility_range_end_margin = 14.0
	_vine_mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	_register_literal_foliage(_vine_mi)
	add_child(_vine_mi)


func has_collisions() -> bool:
	return _collisions_built


func _build_collisions() -> void:
	if _collisions_built:
		return
	_collisions_built = true
	_collisions_active = true

	var terrain_body := StaticBody3D.new()
	var terrain_cs := CollisionShape3D.new()
	var terrain_shape := ConcavePolygonShape3D.new()
	var faces := PackedVector3Array()
	var cells := _terrain_collision_cells
	faces.resize(cells * cells * 6)
	var face_index := 0
	for iz in range(cells):
		for ix in range(cells):
			var p00 := iz * (cells + 1) + ix
			var p10 := p00 + 1
			var p01 := p00 + cells + 1
			var p11 := p01 + 1
			for index in [p00, p10, p11, p00, p11, p01]:
				faces[face_index] = _terrain_collision_vertices[index]
				face_index += 1
	terrain_shape.set_faces(faces)
	terrain_shape.backface_collision = true
	_terrain_collision_vertices = PackedVector3Array()
	terrain_cs.shape = terrain_shape
	terrain_body.add_child(terrain_cs)
	add_child(terrain_body)
	_collision_bodies.append(terrain_body)

	for t in layout.trees:
		var tree_body := _make_tree_collision(t)
		add_child(tree_body)
		_collision_bodies.append(tree_body)

	for r in layout.rocks:
		var rock_body := StaticBody3D.new()
		rock_body.position = r.pos
		var rock_cs := CollisionShape3D.new()
		var rock_shape := SphereShape3D.new()
		rock_shape.radius = r.r * 0.7
		rock_cs.shape = rock_shape
		rock_body.add_child(rock_cs)
		add_child(rock_body)
		_collision_bodies.append(rock_body)

	for hut in _supply_huts:
		if not is_instance_valid(hut):
			continue
		for body in hut.build_collisions():
			_collision_bodies.append(body)

	for piece in _arena_pieces:
		if not is_instance_valid(piece):
			continue
		for body in piece.build_collisions():
			_collision_bodies.append(body)

	for hangar in _airfield_hangars:
		if not is_instance_valid(hangar):
			continue
		for body in hangar.build_collisions():
			_collision_bodies.append(body)

	for tunnel in _freeway_tunnels:
		if not is_instance_valid(tunnel):
			continue
		for body in tunnel.build_collisions():
			_collision_bodies.append(body)

	for bridge in _road_bridges:
		if not is_instance_valid(bridge):
			continue
		for body in bridge.build_collisions():
			_collision_bodies.append(body)


func set_collision_active(active: bool) -> void:
	if active and not _collisions_built:
		_build_collisions()
	if _collisions_active == active:
		return
	_collisions_active = active
	for body in _collision_bodies:
		if is_instance_valid(body):
			body.collision_layer = 1 if active else 0


static func _ribbon(st: SurfaceTool, a: Vector3, b: Vector3, w: float, ca: Color, cb: Color) -> void:
	var dir := (b - a)
	if dir.length() < 0.001:
		return
	dir = dir.normalized()
	var side := dir.cross(Vector3.UP)
	if side.length() < 0.1:
		side = dir.cross(Vector3.RIGHT)
	side = side.normalized() * w
	var side2 := dir.cross(side).normalized() * w
	for s in [side, side2]:
		st.set_color(ca); st.add_vertex(a - s)
		st.set_color(ca); st.add_vertex(a + s)
		st.set_color(cb); st.add_vertex(b + s)
		st.set_color(ca); st.add_vertex(a - s)
		st.set_color(cb); st.add_vertex(b + s)
		st.set_color(cb); st.add_vertex(b - s)


func _build_bananas(collected: Dictionary) -> void:
	var i := 0
	for pos in layout.bananas:
		var id := "b:%d,%d#%d" % [key.x, key.y, i]
		i += 1
		if collected.has(id):
			continue
		var b := Banana.new()
		b.setup(id, pos)
		add_child(b)
