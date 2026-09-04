extends SceneTree
## Compare the baked visual target against the actual resident Horizon mesh.
## godot --headless --path . --script res://tests/terrainmorphtest.gd

var failures: Array[String] = []
var checks := 0
var vertices_checked := 0
var max_height_error := 0.0
var max_color_error := 0.0
var gen: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var chunk_script: GDScript = load("res://scripts/chunk.gd")
	var horizon_script: GDScript = load("res://scripts/horizon_chunk.gd")
	gen = root.get_node("Gen")
	gen.setup(4321)
	for mode in ["ordinary", "frontier", "debug"]:
		gen.frontier_world = mode == "frontier"
		gen.debug_world = mode == "debug"
		for key in [Vector2i.ZERO, Vector2i(-2, -1), Vector2i(18, 25),
				Vector2i(-2500, 8333)]:
			_check_chunk(chunk_script, horizon_script, key, mode)
	gen.debug_world = false
	gen.frontier_world = false
	for failure in failures:
		push_error("TERRAINMORPHTEST: " + failure)
	print("TERRAINMORPHTEST %s %d/%d vertices=%d height_error=%.8f color_error=%.8f" % [
		"PASS" if failures.is_empty() else "FAIL", checks - failures.size(), checks,
		vertices_checked, max_height_error, max_color_error])
	quit(0 if failures.is_empty() else 1)


func _expect(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)


func _check_chunk(chunk_script: GDScript, horizon_script: GDScript,
		key: Vector2i, mode: String) -> void:
	var chunk = chunk_script.new()
	chunk.key = key
	chunk._build_terrain(false)
	var horizon = horizon_script.new()
	horizon.key = Vector2i(floori(float(key.x) / 4.0), floori(float(key.y) / 4.0))
	horizon._build_terrain_and_water()
	var parent_mesh: ArrayMesh = horizon.get_node("CoarseTerrain").mesh
	var parent := parent_mesh.surface_get_arrays(0)
	var fine: Array = chunk._terrain_mesh.surface_get_arrays(0)
	var points: PackedVector3Array = fine[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = fine[Mesh.ARRAY_TEX_UV]
	var uv2: PackedVector2Array = fine[Mesh.ARRAY_TEX_UV2]
	var fine_indices: PackedInt32Array = fine[Mesh.ARRAY_INDEX]
	var parent_points: PackedVector3Array = parent[Mesh.ARRAY_VERTEX]
	var parent_colors: PackedColorArray = parent[Mesh.ARRAY_COLOR]
	var parent_indices: PackedInt32Array = parent[Mesh.ARRAY_INDEX]
	var point_errors := 0
	var collision_errors := 0
	var index_errors := 0
	var height_error := 0.0
	var color_error := 0.0
	_expect(points.size() == 289 and uv.size() == points.size()
		and uv2.size() == points.size(), "%s %s has complete morph attributes" % [mode, key])
	for index in range(points.size()):
		var point := points[index]
		var source: Dictionary = gen.terrain_vertex_sample(point.x, point.z)
		point_errors += int(absf(point.y - float(source.elevation)) > 0.0002)
		var physical_index := roundi((point.z - float(key.y) * 48.0) / 3.0) * 17
		physical_index += roundi((point.x - float(key.x) * 48.0) / 3.0)
		collision_errors += int(chunk._terrain_collision_vertices[physical_index]
			!= Vector3(point.x, float(source.elevation), point.z).snappedf(0.0001))
		var local := (Vector2(point.x, point.z) - Vector2(horizon.key) * 192.0) / 12.0
		var px := mini(floori(local.x), 15)
		var pz := mini(floori(local.y), 15)
		var second := local.x - float(px) < local.y - float(pz)
		var face := (pz * 16 + px) * 6 + (3 if second else 0)
		var ia := parent_indices[face]
		var ib := parent_indices[face + 1]
		var ic := parent_indices[face + 2]
		var a := parent_points[ia]
		var b := parent_points[ib]
		var c := parent_points[ic]
		var plane := Plane(a, b, c)
		var expected_height := a.y - (plane.normal.x * (point.x - a.x)
			+ plane.normal.z * (point.z - a.z)) / plane.normal.y
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ac := Vector2(c.x - a.x, c.z - a.z)
		var ap := Vector2(point.x - a.x, point.z - a.z)
		var wb := ap.cross(ac) / ab.cross(ac)
		var wc := ab.cross(ap) / ab.cross(ac)
		var expected_color := parent_colors[ia] * (1.0 - wb - wc)
		expected_color += parent_colors[ib] * wb + parent_colors[ic] * wc
		var target_color := Vector3(uv[index].x, uv[index].y, uv2[index].y)
		height_error = maxf(height_error, absf(uv2[index].x - expected_height))
		color_error = maxf(color_error, maxf(absf(target_color.x - expected_color.r),
				maxf(absf(target_color.y - expected_color.g), absf(target_color.z - expected_color.b))))
		vertices_checked += 1
	for iz in range(16):
		for ix in range(16):
			var p00 := iz * 17 + ix
			var expected := PackedInt32Array([p00, p00 + 1, p00 + 18, p00, p00 + 18, p00 + 17])
			var offset := (iz * 16 + ix) * 6
			for corner in range(6):
				var actual_point := points[fine_indices[offset + corner]].snappedf(0.0001)
				index_errors += int(actual_point != chunk._terrain_collision_vertices[expected[corner]])
	max_height_error = maxf(max_height_error, height_error)
	max_color_error = maxf(max_color_error, color_error)
	_expect(point_errors == 0 and collision_errors == 0 and index_errors == 0,
		"%s %s preserves physical samples and winding (points=%d collision=%d faces=%d)" % [
			mode, key, point_errors, collision_errors, index_errors])
	_expect(height_error < 0.002, "%s %s targets actual parent planes: %.8f" % [mode, key, height_error])
	_expect(color_error < 0.0001, "%s %s targets actual parent tints: %.8f" % [mode, key, color_error])
	chunk._build_terrain(true)
	var coarse: Array = chunk._terrain_mesh.surface_get_arrays(0)
	var coarse_points: PackedVector3Array = coarse[Mesh.ARRAY_VERTEX]
	var coarse_uv2: PackedVector2Array = coarse[Mesh.ARRAY_TEX_UV2]
	var coarse_errors := 0
	for index in range(coarse_points.size()):
		coarse_errors += int(not is_equal_approx(coarse_points[index].y, coarse_uv2[index].x))
	_expect(coarse_points.size() == 4 and coarse_errors == 0,
		"%s %s flight quad has identity morph" % [mode, key])
	chunk.free()
	horizon.free()
