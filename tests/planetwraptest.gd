extends Node
## Live integration gate for the locally-flat spherical chart rebasing used by
## both on-foot traversal and all Vehicle subclasses.

var passed := 0
var total := 0


func _check(ok: bool, label: String, detail := "") -> void:
	total += 1
	if ok:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] %s%s" % [label,
			(" :: " + detail) if not detail.is_empty() else ""])


func run(main: Node) -> void:
	print("PLANETWRAPTEST begin")
	var world: World = main.world
	var player: MonkeyPlayer = world.local_player

	player.global_position = Vector3(Gen.PLANET_HALF_CIRCUMFERENCE + 2.0,
		120.0, 240.0)
	player.velocity = Vector3(17.0, -4.0, 8.0)
	world._wrap_local_planet_actor()
	_check(absf(player.global_position.x
		- (-Gen.PLANET_HALF_CIRCUMFERENCE + 2.0)) < 0.01
		and player.velocity.is_equal_approx(Vector3(17.0, -4.0, 8.0)),
		"longitude wrap preserves on-foot altitude and momentum")

	player.global_position = Vector3(125.0, 180.0,
		Gen.PLANET_POLE_DISTANCE + 3.0)
	player.velocity = Vector3(5.0, -7.0, 21.0)
	player.rig.set_yaw(0.24)
	player.cam.yaw = -0.41
	world._wrap_local_planet_actor()
	var expected_pole := Gen.canonical_planet_xz(Vector2(125.0,
		Gen.PLANET_POLE_DISTANCE + 3.0))
	_check(Vector2(player.global_position.x, player.global_position.z).distance_to(
		expected_pole) < 0.01
		and player.velocity.is_equal_approx(Vector3(-5.0, -7.0, -21.0))
		and absf(angle_difference(player.rig.yaw_angle(), 0.24 + PI)) < 0.001
		and absf(angle_difference(player.cam.yaw, -0.41 + PI)) < 0.001,
		"north-pole crossing rotates monkey, view and planar momentum together")

	var vehicle := Vehicle.new()
	vehicle.name = "PlanetWrapVehicleFixture"
	world.add_child(vehicle)
	vehicle.global_position = Vector3(-320.0, 900.0,
		-Gen.PLANET_POLE_DISTANCE - 4.0)
	vehicle.global_basis = Basis(Vector3.UP, 0.31)
	vehicle.linear_velocity = Vector3(-12.0, 3.0, -44.0)
	player.vehicle = vehicle
	world._wrap_local_planet_actor()
	var expected_vehicle := Gen.canonical_planet_xz(Vector2(-320.0,
		-Gen.PLANET_POLE_DISTANCE - 4.0))
	_check(Vector2(vehicle.global_position.x, vehicle.global_position.z).distance_to(
		expected_vehicle) < 0.01
		and vehicle.linear_velocity.is_equal_approx(Vector3(12.0, 3.0, 44.0))
		and absf(angle_difference(vehicle.yaw_angle(), 0.31 + PI)) < 0.001
		and player.global_position.distance_to(vehicle.seat_global()) < 0.01,
		"every driven Vehicle preserves its seated monkey and trajectory at a pole")

	var remote_canonical := Vector2(400.0,
		Gen.PLANET_POLE_DISTANCE - 2.0)
	var across_pole_reference := Vector2(
		remote_canonical.x + Gen.PLANET_HALF_CIRCUMFERENCE,
		Gen.PLANET_POLE_DISTANCE + 2.0)
	var remote_image := Gen.nearest_world_image_sample(remote_canonical,
		across_pole_reference)
	_check((remote_image.xz as Vector2).distance_to(across_pole_reference) < 0.01
		and absf(float(remote_image.yaw_delta) - PI) < 0.001,
		"multiplayer chooses the pole-mirrored nearby image with heading correction")

	player.vehicle = null
	vehicle.queue_free()
	print("PLANETWRAPTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
