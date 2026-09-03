extends Node
## Verify the physical return destination, rather than the passenger's private
## cinematic ocean. Run with -- waterlandingprobe.

const SEEDS := [1337, 0, 1, 42, 2026]
const FOOTPRINT_RADIUS := 60.0
var passed := 0
var total := 0


func _check(ok: bool, label: String) -> void:
	total += 1
	passed += int(ok)
	print("[%s] %s" % ["PASS" if ok else "FAIL", label])


func _minimum_depth(point: Vector2) -> float:
	var shallowest := INF
	for z in range(-4, 5):
		for x in range(-4, 5):
			var offset := Vector2(x, z) * (FOOTPRINT_RADIUS / 4.0)
			if offset.length_squared() > FOOTPRINT_RADIUS * FOOTPRINT_RADIUS:
				continue
			shallowest = minf(shallowest,
				Gen.WATER_Y - Gen.height(point.x + offset.x, point.y + offset.y))
	return shallowest


func _nearby_water_meshes(point: Vector2) -> bool:
	var keys: Dictionary = {}
	for z in [-30.0, 0.0, 30.0]:
		for x in [-30.0, 0.0, 30.0]:
			var sample := point + Vector2(x, z)
			keys[Vector2i(floori(sample.x / Gen.CHUNK), floori(sample.y / Gen.CHUNK))] = true
	var all_wet := true
	Chunk._init_mats()
	for key in keys:
		var chunk := Chunk.new()
		chunk.key = key
		add_child(chunk)
		chunk._build_water()
		var water := chunk._water_instance
		all_wet = all_wet and is_instance_valid(water)
		if is_instance_valid(water):
			var mesh := water.mesh as PlaneMesh
			all_wet = all_wet and mesh != null and is_equal_approx(water.global_position.y, Gen.WATER_Y) \
				and mesh.size.is_equal_approx(Vector2.ONE * Gen.CHUNK) \
				and mesh.subdivide_width == Gen.CELLS and mesh.subdivide_depth == Gen.CELLS
		chunk.free()
	return all_wet


func run() -> void:
	Gen.debug_world = false
	var manager := ExpeditionManager.new()
	for seed in SEEDS:
		Gen.setup(seed)
		var started := Time.get_ticks_usec()
		var destination := manager._ocean_splashdown_position()
		var elapsed_us := Time.get_ticks_usec() - started
		var point := Vector2(destination.x, destination.z)
		var minimum_depth := _minimum_depth(point)
		var old_fallback := Vector2(12000.0, -9000.0)
		var home := Gen.planet_home_lake_center()
		print("WATER_LANDING_SAMPLE " + JSON.stringify({"seed": seed,
			"destination": [destination.x, destination.y, destination.z],
			"center_depth": Gen.WATER_Y - Gen.height(point.x, point.y),
			"footprint_min_depth": minimum_depth, "selection_us": elapsed_us,
			"old_fallback_depth": Gen.WATER_Y - Gen.height(old_fallback.x, old_fallback.y),
			"home_lake_min_depth": _minimum_depth(home)}))
		_check(destination.is_finite() \
			and absf(destination.x) + FOOTPRINT_RADIUS < Net.MAX_WORLD_COORDINATE \
			and absf(destination.z) + FOOTPRINT_RADIUS < Net.MAX_WORLD_COORDINATE \
			and is_equal_approx(destination.y, Gen.WATER_Y + 4.6),
			"seed%d return stays inside authority bounds at the water landing height" % seed)
		_check(minimum_depth >= 8.0, "seed%d has at least8m depth across the60m landing footprint" % seed)
		_check(_nearby_water_meshes(point), "seed%d ordinary water meshes cover the nearby physical landing area" % seed)
		_check(manager._ocean_splashdown_position().is_equal_approx(destination),
			"seed%d destination is deterministic" % seed)
	manager.free()
	await get_tree().process_frame
	print("WATERLANDINGPROBETEST %d/%d %s" % [passed, total, "PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
