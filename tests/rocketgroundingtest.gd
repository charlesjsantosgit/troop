extends Node
## Measure the real landed collision soles against terrain, including the town
## grading which previously left the entire vehicle about 1.5 m above ground.
var total := 0
var passed := 0

func _check(ok: bool, message: String) -> void:
	total += 1
	passed += int(ok)
	print("ROCKETGROUNDING %s %s" % ["PASS" if ok else "FAIL", message])

func _sole_gaps(rocket: LunarRocket, height_at: Callable) -> Vector2:
	var gaps := Vector2(INF, -INF)
	for leg in rocket.landing_gear:
		var contact: CollisionShape3D = leg.collision
		var half_size: Vector3 = (contact.shape as BoxShape3D).size * 0.5
		for x in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				var point := contact.to_global(Vector3(x * half_size.x, -half_size.y, z * half_size.z))
				var gap := point.y - float(height_at.call(point.x, point.z))
				gaps.x = minf(gaps.x, gap)
				gaps.y = maxf(gaps.y, gap)
	return gaps

func run() -> void:
	var root := get_tree().root
	var rocket := LunarRocket.new()
	rocket.freeze = true
	root.add_child(rocket)
	rocket.set_physics_process(false)
	_check(rocket.landing_gear.size() == 4, "four real landing feet are present")
	var heading := Basis(Vector3.UP, PI)
	for slope in [Vector2.ZERO, Vector2(0.06, -0.04)]:
		var height_at := func(x: float, z: float) -> float: return 3.0 + slope.x * x + slope.y * z
		var frame := LunarRocket.grounded_landing_transform(Vector3(15, 500, 25), heading, height_at)
		rocket.global_transform = frame
		var gaps := _sole_gaps(rocket, height_at)
		_check(gaps.x >= -0.0001 and gaps.y < 0.0001,
			"all physical soles contact plane %s despite incorrect authored height: %s m" % [slope, gaps])
		_check(frame.basis.y.dot(Vector3(-slope.x, 1, -slope.y).normalized()) > 0.99999,
			"landing frame follows actual plane normal")
	var gen := root.get_node("Gen")
	var net := root.get_node("Net")
	var original_seed: int = gen.world_seed
	var original_frontier: bool = gen.frontier_world
	var original_debug: bool = gen.debug_world
	gen.debug_world = false
	for frontier in [false, true]:
		gen.frontier_world = frontier
		for seed_value in [2026, 1337, 4041969, 0]:
			gen.setup(seed_value)
			var height_at := func(x: float, z: float) -> float: return gen.height(x, z)
			var frame := LunarRocket.grounded_landing_transform(gen.rocket_launch_position(), heading, height_at)
			rocket.global_transform = frame
			var gaps := _sole_gaps(rocket, height_at)
			var description := "%s seed %d" % ["Frontier" if frontier else "Earth", seed_value]
			_check(gaps.x >= -0.001 and gaps.x <= 0.001 and gaps.y < 0.03,
				"%s actual foot clearance min/max %s m" % [description, gaps])
			_check(frame.origin.is_finite() and absf(frame.basis.determinant() - 1.0) < 0.00001,
				"%s preserves rigid vehicle dimensions" % description)
			_check(frame.is_equal_approx(net._earth_rocket_transform()) \
				and rocket.boarding_global_position().distance_to(net._rocket_boarding_position(0)) < 0.001,
				"%s authority and physical boarding hatch agree" % description)
	gen.frontier_world = original_frontier
	gen.debug_world = original_debug
	gen.setup(original_seed)
	rocket.queue_free()
	for frame in range(4): await get_tree().process_frame
	print("ROCKETGROUNDINGTEST %d/%d %s" % [passed, total, "PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
