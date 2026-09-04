extends SceneTree
## Renderer-independent terrain ownership and physical debug-plane regression.
## Run: godot --headless --path . --script res://tests/terraincoveragetest.gd
## The shader's small ownership kernel is executed, not reimplemented: its GLSL
## statements are translated to GDScript, while texture reads use the real mask.

const GRID_SIZES := Vector4(48, 192, 768, 6144)
const STARTS := Vector3(64, 504, 1480)
const ENDS := Vector3(96, 696, 1920)
const TIER_NAMES := ["near", "horizon", "skyline", "stratos"]

var failures: Array[String] = []
var checks := 0
var materials: Array[ShaderMaterial] = []
var ownership_kernel: RefCounted
var coverage_samples := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var visuals_script: GDScript = load("res://scripts/visuals.gd")
	_expect(visuals_script != null and visuals_script.can_instantiate(),
		"Visuals must compile after the project autoloads initialize")
	if not failures.is_empty():
		_finish()
		return
	materials = [Visuals.ground_material(), Visuals.far_ground_material(),
		Visuals.skyline_ground_material(), Visuals.stratos_ground_material()]
	_test_residency_encoding()
	_test_material_contract()
	ownership_kernel = _compile_shipped_owner()
	if ownership_kernel != null:
		_test_coverage_scenarios()
		_test_transition_distribution()
	_test_debug_plane_geometry()
	_finish()


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _finish() -> void:
	for failure in failures:
		push_error("TERRAINCOVERAGETEST: " + failure)
	print("TERRAINCOVERAGETEST %s %d/%d ownership_samples=%d" % [
		"PASS" if failures.is_empty() else "FAIL", checks - failures.size(),
		checks, coverage_samples])
	quit(0 if failures.is_empty() else 1)


func _key(point: Vector2, size: float) -> Vector2i:
	return Vector2i(floori(point.x / size), floori(point.y / size))


func _square(focus: Vector2, tier: int, radius: int) -> Dictionary:
	var result: Dictionary = {}
	var center := _key(focus, GRID_SIZES[tier])
	for x in range(-radius, radius + 1):
		for z in range(-radius, radius + 1):
			result[center + Vector2i(x, z)] = true
	return result


func _publish(focus: Vector2, grids: Array) -> Dictionary:
	Visuals.set_far_focus(Vector3(focus.x, 0, focus.y))
	Visuals.set_terrain_residency(focus, grids[0], grids[1], grids[2], grids[3])
	return {"image": Visuals.terrain_residency_image(),
		"origins": Visuals.terrain_residency_origins(), "focus": focus,
		"grids": grids, "sizes": materials[0].get_shader_parameter("terrain_grid_sizes"),
		"starts": materials[0].get_shader_parameter("terrain_transition_start"),
		"ends": materials[0].get_shader_parameter("terrain_transition_end")}


func _test_residency_encoding() -> void:
	# Deliberately include every map edge, outside-map keys, holes, and values
	# other than true: the resident dictionary's keys identify complete meshes.
	for focus in [Vector2.ZERO, Vector2(-0.001, -48.001),
			Vector2(47.999, -192.001), Vector2(-6144, 12287.999)]:
		var grids: Array = [{}, {}, {}, {}]
		for tier in range(4):
			var center := _key(focus, GRID_SIZES[tier])
			for offset in [Vector2i.ZERO, Vector2i(-16, -16), Vector2i(15, 15),
					Vector2i(-16, 15), Vector2i(15, -16), Vector2i(-17, 0),
					Vector2i(16, 0), Vector2i(0, -17), Vector2i(0, 16),
					Vector2i(2, -3), Vector2i(-2, 3)]:
				grids[tier][center + offset] = false if offset == Vector2i.ZERO else true
		var original: Array = grids.duplicate(true)
		var state := _publish(focus, grids)
		var mask: Image = state.image
		var origins: PackedVector2Array = state.origins
		_expect(mask != null and mask.get_size() == Vector2i(32, 32)
			and mask.get_format() == Image.FORMAT_RGBA8 and not mask.has_mipmaps(),
			"residency atlas must be a 32x32 non-mipmapped RGBA8 mask")
		_expect(origins.size() == 4, "atlas must expose one origin per LOD tier")
		if mask == null or origins.size() != 4:
			return
		var mismatches := 0
		for tier in range(4):
			var expected_origin := _key(focus, GRID_SIZES[tier]) - Vector2i(16, 16)
			_expect(origins[tier] == Vector2(expected_origin),
				"%s origin must use floor division, including negative coordinates" % TIER_NAMES[tier])
			for y in range(32):
				for x in range(32):
					var expected: bool = grids[tier].has(expected_origin + Vector2i(x, y))
					var encoded: float = mask.get_pixel(x, y)[tier]
					if not is_equal_approx(encoded, 1.0 if expected else 0.0):
						mismatches += 1
		_expect(mismatches == 0,
			"all atlas texels must exactly encode dictionary membership without wrapping")
		_expect(grids == original, "publishing residency must not mutate world chunk dictionaries")
		# Recenter and clear all tiers: previously populated channels must vanish.
		var cleared := _publish(focus + Vector2(49, -193), [{}, {}, {}, {}])
		var bytes: PackedByteArray = cleared.image.get_data()
		var stale := 0
		for value in bytes:
			stale += int(value != 0)
		_expect(stale == 0, "recentered empty residency must clear every stale channel")
	# A worker can finish one sector while another is evicted in the same frame.
	# Equal dictionary size is not proof that residency stayed unchanged.
	var swapped: Array = [{Vector2i.ZERO: true}, {}, {}, {}]
	_publish(Vector2.ZERO, swapped)
	var texture_before: Texture2D = materials[0].get_shader_parameter("terrain_residency")
	swapped[0].erase(Vector2i.ZERO)
	swapped[0][Vector2i(1, 0)] = true
	var replaced := _publish(Vector2.ZERO, swapped)
	_expect(replaced.image.get_pixel(16, 16).r == 0.0
		and replaced.image.get_pixel(17, 16).r == 1.0,
		"same-count eviction/arrival must replace atlas membership without stale ground")
	_expect(materials[0].get_shader_parameter("terrain_residency") == texture_before,
		"atlas refreshes must update the shared texture without breaking existing material bindings")


func _test_material_contract() -> void:
	_publish(Vector2(-48.001, 191.999), [{Vector2i(-2, 3): true}, {}, {}, {}])
	var shared_texture: Texture2D = materials[0].get_shader_parameter("terrain_residency")
	_expect(shared_texture != null, "near terrain must bind the actual occupancy texture")
	for tier in range(4):
		var material := materials[tier]
		_expect(material.get_shader_parameter("terrain_residency") == shared_texture,
			"%s material must share the same live occupancy texture" % TIER_NAMES[tier])
		_expect(int(material.get_shader_parameter("terrain_tier")) == tier,
			"%s material must select its own ownership channel" % TIER_NAMES[tier])
		_expect(bool(material.get_shader_parameter("terrain_residency_enabled")),
			"%s material must enable resident ownership after publication" % TIER_NAMES[tier])
		_expect(material.get_shader_parameter("terrain_grid_sizes") == GRID_SIZES,
			"%s atlas scales must match the four actual mesh sector sizes" % TIER_NAMES[tier])
		_expect(material.get_shader_parameter("terrain_grid_origins")
			== Visuals.terrain_residency_origins(),
			"%s material origins must match the published image" % TIER_NAMES[tier])
		_expect(material.get_shader_parameter("terrain_transition_start") == STARTS
			and material.get_shader_parameter("terrain_transition_end") == ENDS,
			"%s transitions must preserve the complete lower-shell coverage limits" % TIER_NAMES[tier])
		_expect(not material.shader.code.contains("ALPHA ="),
			"%s ground must remain opaque after its one ownership selection" % TIER_NAMES[tier])
	# Altitude changes foliage policy but must not globally retire terrain while
	# only part of the next shell exists during descent.
	Visuals.set_altitude_lod_handoffs(0.0, 0.0)
	for tier in range(4):
		_expect(materials[tier].get_shader_parameter("terrain_transition_start") == STARTS
			and materials[tier].get_shader_parameter("terrain_transition_end") == ENDS,
			"altitude foliage handoffs must not alter %s resident ground ownership" % TIER_NAMES[tier])
	Visuals.set_altitude_lod_handoffs(Gen.SKYLINE_NEAR_FADE, Gen.STRATOS_NEAR_FADE)


func _compile_shipped_owner() -> RefCounted:
	var shared := Visuals.TERRAIN_OWNERSHIP_SHADER
	var lookup := _function_body(shared, "bool terrain_present(")
	var owner := _function_body(shared, "bool owns_terrain(")
	_expect(not lookup.is_empty() and not owner.is_empty(),
		"shared GLSL must expose its occupancy lookup and ownership decision")
	if lookup.is_empty() or owner.is_empty():
		return null
	var hash_body := _compact(_function_body(materials[0].shader.code, "float hash21("))
	for tier in range(4):
		var code := materials[tier].shader.code
		_expect(code.contains(shared),
			"%s must include the exact common ownership kernel" % TIER_NAMES[tier])
		_expect(_compact(_function_body(code, "float hash21(")) == hash_body,
			"%s must use the same dither hash as every overlapping tier" % TIER_NAMES[tier])
		var fragment := _compact(_function_body(code, "void fragment("))
		_expect(fragment.count("owns_terrain(") == 1
			and fragment.contains("hash21(floor(world_pos.xz*0.36))"),
			"%s fragment must perform one ownership decision using the same world hash cell" % TIER_NAMES[tier])
		if tier in [1, 2]:
			var enabled_branch := _function_body(code, "if (terrain_residency_enabled)")
			_expect(_compact(enabled_branch)
				== "if(!owns_terrain(world_pos.xz,focus_xz,cell_hash)){discard;}",
				"resident %s must bypass legacy near/far fades after selecting an owner" % TIER_NAMES[tier])
	var code := """extends RefCounted
var terrain_residency: Image
var terrain_grid_origins: PackedVector2Array
var terrain_grid_sizes: Vector4
var terrain_transition_start: Vector3
var terrain_transition_end: Vector3
var terrain_tier := 0
func _vec2(value: float) -> Vector2:
	return Vector2(value, value)
func _vec3(value: float) -> Vector3:
	return Vector3(value, value, value)
func _floor(value: Vector2) -> Vector2:
	return value.floor()
func _lessThan(a: Vector2, b: Vector2) -> Vector2i:
	return Vector2i(int(a.x < b.x), int(a.y < b.y))
func _greaterThanEqual(a: Vector2, b: Vector2) -> Vector2i:
	return Vector2i(int(a.x >= b.x), int(a.y >= b.y))
func _any(value: Vector2i) -> bool:
	return value.x != 0 or value.y != 0
func _texture(mask: Image, uv: Vector2) -> Color:
	return mask.get_pixelv(Vector2i((uv * Vector2(mask.get_size())).floor()))
func _distance(a: Vector2, b: Vector2) -> float:
	return a.distance_to(b)
func _smoothstep(a: Vector3, b: Vector3, value: Vector3) -> Vector3:
	return Vector3(smoothstep(a.x, b.x, value.x), smoothstep(a.y, b.y, value.y),
		smoothstep(a.z, b.z, value.z))
"""
	code += "\nfunc terrain_present(point: Vector2, tier: int) -> bool:\n" + _translate_statements(lookup)
	code += "\nfunc owns_terrain(point: Vector2, focus: Vector2, cell_hash: float) -> bool:\n" + _translate_statements(owner)
	var script := GDScript.new()
	script.source_code = code
	var error := script.reload()
	_expect(error == OK and script.can_instantiate(),
		"the shipped scalar/boolean ownership kernel must execute in the headless harness")
	return script.new() if error == OK else null


func _function_body(code: String, signature: String) -> String:
	var found := code.find(signature)
	if found < 0:
		return ""
	var opening := code.find("{", found)
	var depth := 1
	for index in range(opening + 1, code.length()):
		if code[index] == "{":
			depth += 1
		elif code[index] == "}":
			depth -= 1
			if depth == 0:
				return code.substr(opening + 1, index - opening - 1)
	return ""


func _compact(code: String) -> String:
	return code.replace(" ", "").replace("\t", "").replace("\n", "").replace("\r", "")


func _translate_statements(body: String) -> String:
	# Only declarations, assignments, conditionals and returns are needed by
	# this 30-line GLSL kernel. Preserve their expressions and ordering verbatim;
	# substitute language spelling and vector builtins, never policy constants.
	var declaration := RegEx.new()
	declaration.compile("^(bool|int|float|vec2|vec3) +")
	var negation := RegEx.new()
	negation.compile("!(?!=)")
	var result := ""
	var depth := 1
	var statements := body.replace("}", "\n}\n").replace("{", "{\n").replace(";", ";\n")
	for raw in statements.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty():
			continue
		if line == "}":
			depth -= 1
			continue
		var opens := line.ends_with("{")
		line = line.trim_suffix("{").trim_suffix(";").strip_edges()
		if line.begins_with("else if ("):
			line = "elif " + line.substr(9, line.length() - 10) + ":"
		elif line.begins_with("if ("):
			line = "if " + line.substr(4, line.length() - 5) + ":"
		elif line == "else":
			line = "else:"
		else:
			line = declaration.sub(line, "var ")
		line = line.replace("&&", "and").replace("||", "or")
		line = negation.sub(line, "not ", true)
		for builtin in ["vec2", "vec3", "floor", "lessThan", "greaterThanEqual",
				"any", "texture", "distance", "smoothstep"]:
			line = line.replace(builtin + "(", "_" + builtin + "(")
		result += "\t".repeat(depth) + line + "\n"
		if opens:
			depth += 1
	return result


func _test_coverage_scenarios() -> void:
	Visuals.set_stratos_view_radius(Gen.VIEW_PEAK_DISTANCE)
	for focus in [Vector2(0.001, 47.999), Vector2(-48.001, -192.001),
			Vector2(6143.999, -6144.001)]:
		var complete: Array = [_square(focus, 0, 2), _square(focus, 1, 3),
			_square(focus, 2, 3), _square(focus, 3, 4)]
		var sparse: Array = [{_key(focus, 48): true}, {}, {}, complete[3]]
		var missing_horizon: Array = [complete[0], {}, complete[2], complete[3]]
		var ascent: Array = [{}, {}, {}, complete[3]]
		var descent: Array = [complete[0].duplicate(), complete[1].duplicate(),
			complete[2].duplicate(), complete[3]]
		for tier in range(3):
			for key in descent[tier].keys():
				if posmod(key.x + key.y, 3) != 0:
					descent[tier].erase(key)
		var collision_patches: Array = [{}, {}, {}, complete[3]]
		for offset in [Vector2i(10, 0), Vector2i(-16, 0), Vector2i(16, 0),
				Vector2i(-17, 0), Vector2i(80, -50)]:
			collision_patches[0][_key(focus, 48) + offset] = true
		var cases := {"complete": complete, "sparse_online_entry": sparse,
			"missing_horizon": missing_horizon, "ascent": ascent,
			"partial_descent": descent, "far_collision_patches": collision_patches,
			"near_only": [{_key(focus, 48): true}, {}, {}, {}],
			"empty": [{}, {}, {}, {}]}
		var points: Array[Vector2] = []
		for spoke in range(24):
			var direction := Vector2.from_angle(TAU * float(spoke) / 24.0)
			for distance in [0.0, 63.999, 64.0, 80.0, 95.999, 96.0,
					503.999, 504.0, 600.0, 696.0, 1480.0, 1700.0, 1920.0,
					2200.0, 6144.0, 20000.0]:
				points.append(focus + direction * distance)
		# Check either side of exact positive/negative tile boundaries, including
		# the far fine-collision tiles whose atlas entries must not wrap around.
		for tier in range(4):
			var center := _key(focus, GRID_SIZES[tier])
			for offset in [-17, -16, -1, 0, 1, 15, 16, 80]:
				for epsilon in [-0.001, 0.0, 0.001]:
					points.append(Vector2(center + Vector2i(offset, 0))
						* GRID_SIZES[tier] + Vector2(epsilon, 0.01))
		for label in cases:
			var state := _publish(focus, cases[label])
			_configure_kernel(state)
			var mismatches := 0
			var first := ""
			for point in points:
				var bounds := _ownership_intervals(state, point)
				var hashes: Array[float] = [0.0, 0.00001, 0.125, 0.25, 0.5,
					0.75, 0.875, 0.99999]
				var distance := point.distance_to(focus)
				for transition in range(3):
					var boundary := _transition32(STARTS[transition], ENDS[transition], distance)
					if boundary < 1.0:
						hashes.append(boundary)
				for cell_hash in hashes:
					var actual_count := 0
					for tier in range(4):
						ownership_kernel.terrain_tier = tier
						var actual: bool = ownership_kernel.owns_terrain(point, focus, cell_hash)
						var interval: Dictionary = bounds[tier]
						var expected: bool = interval.present and cell_hash < interval.upper \
							and cell_hash >= interval.lower
						actual_count += int(actual)
						if actual != expected:
							mismatches += 1
							if first.is_empty():
								first = "point=%s hash=%.6f tier=%s" % [point, cell_hash, TIER_NAMES[tier]]
					var any_present := false
					for interval in bounds:
						any_present = any_present or bool(interval.present)
					if actual_count != int(any_present):
						mismatches += 1
					coverage_samples += 1
			_expect(mismatches == 0,
				"%s at focus %s must select exactly one available mesh, with no skipped intermediate-tier holes: %s" % [label, focus, first])


func _configure_kernel(state: Dictionary) -> void:
	ownership_kernel.terrain_residency = state.image
	ownership_kernel.terrain_grid_origins = state.origins
	ownership_kernel.terrain_grid_sizes = state.sizes
	ownership_kernel.terrain_transition_start = state.starts
	ownership_kernel.terrain_transition_end = state.ends


func _ownership_intervals(state: Dictionary, point: Vector2) -> Array:
	# Independent oracle: partition the unit dither interval among the available
	# meshes. Membership uses input chunk keys and analytical sector bounds,
	# never the shader's texture helper. An absent tier receives no interval.
	var result: Array = []
	var available: Array[int] = []
	for tier in range(4):
		var key := _key(point, state.sizes[tier])
		var delta := key - Vector2i(state.origins[tier])
		var present: bool = state.grids[tier].has(key) and delta.x >= 0 \
			and delta.y >= 0 and delta.x < 32 and delta.y < 32
		result.append({"present": present, "lower": 0.0, "upper": 0.0, "last": false})
		if present:
			available.append(tier)
	var upper := 1.0
	for index in range(available.size()):
		var tier := available[index]
		var last := index == available.size() - 1
		var lower := 0.0 if last else _transition32(state.starts[tier],
			state.ends[tier], point.distance_to(state.focus))
		result[tier].lower = lower
		result[tier].upper = upper
		result[tier].last = last
		upper = minf(upper, lower)
	return result


func _transition32(start: float, end: float, distance: float) -> float:
	# GLSL stores transition in vec3 (32-bit components), while GDScript scalar
	# arithmetic is 64-bit. Round the oracle boundary to the same storage format
	# before checking exact equality; near-one values otherwise disagree by ULPs.
	return Vector3(smoothstep(start, end, distance), 0, 0).x


func _test_transition_distribution() -> void:
	var focus := Vector2(-0.001, -47.999)
	var grids: Array = [_square(focus, 0, 15), _square(focus, 1, 15),
		_square(focus, 2, 15), _square(focus, 3, 4)]
	var state := _publish(focus, grids)
	_configure_kernel(state)
	for tier in range(3):
		var distance := (STARTS[tier] + ENDS[tier]) * 0.5
		var point := focus + Vector2(distance, 0)
		var counts := PackedInt32Array([0, 0, 0, 0])
		for bucket in range(256):
			var cell_hash := (float(bucket) + 0.5) / 256.0
			for candidate in range(4):
				ownership_kernel.terrain_tier = candidate
				counts[candidate] += int(ownership_kernel.owns_terrain(point, focus, cell_hash))
		_expect(counts[tier] == 128 and counts[tier + 1] == 128,
			"the %s midpoint must split 50/50 with its successor, never 25/25 from double fades" % TIER_NAMES[tier])
	for fixture in [{"distance": 32.0, "tier": 0}, {"distance": 200.0, "tier": 1},
			{"distance": 1000.0, "tier": 2}, {"distance": 3000.0, "tier": 3}]:
		var count := 0
		ownership_kernel.terrain_tier = fixture.tier
		for bucket in range(256):
			count += int(ownership_kernel.owns_terrain(focus + Vector2(fixture.distance, 0),
				focus, (float(bucket) + 0.5) / 256.0))
		_expect(count == 256, "interior of tier %d must have whole opaque coverage" % fixture.tier)


func _test_debug_plane_geometry() -> void:
	var gen: Node = root.get_node("Gen")
	var previous_debug: bool = gen.debug_world
	gen.debug_world = true
	var bad_samples := 0
	for point in [Vector2.ZERO, Vector2(47.999, -0.001), Vector2(-48, 192),
			Vector2(-768.001, -6144.001), Vector2(21500, -16000)]:
		for sample in [gen.terrain_vertex_sample(point.x, point.y),
				gen.skyline_visual_sample(point.x, point.y),
				gen.stratos_visual_sample(point.x, point.y)]:
			if not is_equal_approx(float(sample.elevation), 2.0):
				bad_samples += 1
		if not is_equal_approx(gen.height(point.x, point.y), 2.0):
			bad_samples += 1
	_expect(bad_samples == 0, "debug mode must return y=2 through every terrain sampling path")
	var scripts: Array[GDScript] = [load("res://scripts/chunk.gd"),
		load("res://scripts/horizon_chunk.gd"), load("res://scripts/skyline_chunk.gd"),
		load("res://scripts/stratos_chunk.gd")]
	for key in [Vector2i.ZERO, Vector2i(-1, -2)]:
		for tier in range(4):
			var sector: Node3D = scripts[tier].new()
			root.add_child(sector)
			if tier == 0:
				sector.setup(key, {}, true, true, false)
				sector.call("_build_collisions")
			elif tier == 3:
				sector.setup(key, 8, false)
			else:
				sector.setup(key, true)
			var meshes: Array[MeshInstance3D] = []
			_collect_meshes(sector, meshes)
			var vertex_count := 0
			var bad_vertices := 0
			for instance in meshes:
				if instance.material_override != materials[tier]:
					continue
				_expect(instance.visibility_range_end <= 0.0,
					"%s terrain must not be camera-center culled before per-fragment ownership" % TIER_NAMES[tier])
				for surface in range(instance.mesh.get_surface_count()):
					var arrays := instance.mesh.surface_get_arrays(surface)
					var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
					for vertex in vertices:
						vertex_count += 1
						if absf(instance.to_global(vertex).y - 2.0) > 0.0001:
							bad_vertices += 1
			_expect(vertex_count > 0 and bad_vertices == 0,
				"actual %s mesh vertices must lie on the debug collision plane at %s" % [TIER_NAMES[tier], key])
			if tier == 0:
				var collision_shapes: Array[ConcavePolygonShape3D] = []
				_collect_terrain_shapes(sector, collision_shapes)
				var face_count := 0
				var bad_faces := 0
				for shape in collision_shapes:
					for vertex in shape.get_faces():
						face_count += 1
						if absf(vertex.y - 2.0) > 0.0001:
							bad_faces += 1
				_expect(face_count > 0 and bad_faces == 0,
					"constructed near collision triangles must match the rendered y=2 plane")
			sector.free()
	gen.debug_world = previous_debug


func _collect_meshes(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_collect_meshes(child, result)


func _collect_terrain_shapes(node: Node, result: Array[ConcavePolygonShape3D]) -> void:
	if node is CollisionShape3D and node.shape is ConcavePolygonShape3D:
		result.append(node.shape)
	for child in node.get_children():
		_collect_terrain_shapes(child, result)
