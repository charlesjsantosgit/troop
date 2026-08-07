extends Node
## Headless world-generation verification for the vehicle update: the seeded
## airstrip search, runway grading/exclusions, deterministic vehicle spawn
## definitions, and the world-level spawn plumbing. Run with:
##   godot --headless --path . res://scenes/main.tscn --quit-after 30000 -- vehicleworldtest

var fails := 0
var total := 0


func check(cname: String, ok: bool, info := "") -> void:
	total += 1
	if ok:
		print("  [ok] " + cname)
	else:
		fails += 1
		print("  [FAIL] " + cname + (("   :: " + info) if info != "" else ""))


func sim(frames: int) -> void:
	for i in range(frames):
		await get_tree().physics_frame


func run(main) -> void:
	print("VEHICLEWORLDTEST begin (seed=%d)" % Gen.world_seed)
	var w = main.world
	await sim(30)

	# --- airstrip placement determinism --------------------------------------
	check("airstrip search found a corridor", Gen.airstrip_valid)
	var first_center: Vector2 = Gen.airstrip_center
	var first_heading: float = Gen.airstrip_heading
	var first_elevation: float = Gen.airstrip_elevation
	Gen.setup(Gen.world_seed)
	check("airstrip placement is deterministic for the seed",
		Gen.airstrip_center == first_center
		and Gen.airstrip_heading == first_heading
		and absf(Gen.airstrip_elevation - first_elevation) < 0.001)

	# --- runway surface -------------------------------------------------------
	var direction := Vector2(sin(Gen.airstrip_heading),
		cos(Gen.airstrip_heading))
	var min_h := INF
	var max_h := -INF
	for s in range(-20, 21):
		var p: Vector2 = Gen.airstrip_center + direction * (float(s) * 10.0)
		var h := Gen.height(p.x, p.y)
		min_h = minf(min_h, h)
		max_h = maxf(max_h, h)
	check("runway centreline is graded flat and dry",
		max_h - min_h < 0.35 and min_h > Gen.WATER_Y + 1.5,
		"span=%.2f min=%.2f" % [max_h - min_h, min_h])
	var mid: Vector2 = Gen.airstrip_center
	var dirt := Gen.ground_color(Gen.height(mid.x, mid.y), mid.x, mid.y)
	check("runway surface bakes as packed dirt in every tier",
		dirt.r > dirt.g and dirt.r > 0.3,
		"color=%s" % dirt)
	# No trees or foliage on the strip in the chunks it crosses.
	var strip_chunk := Vector2i(floori(mid.x / Gen.CHUNK),
		floori(mid.y / Gen.CHUNK))
	var clean := true
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var layout: Dictionary = Gen.chunk_layout(strip_chunk.x + dx,
				strip_chunk.y + dz)
			for tree in layout.trees:
				if Gen.point_on_airstrip(tree.pos.x, tree.pos.z):
					clean = false
			for plant in layout.foliage:
				if Gen.point_on_airstrip(plant.pos.x, plant.pos.z):
					clean = false
	check("nothing grows through the runway", clean)

	# --- deterministic vehicle defs ------------------------------------------
	var pool: Array = Gen.vehicle_layout(0, 0)
	var pool_kinds: Array = []
	var ids_valid := true
	for def in pool:
		pool_kinds.append(int(def.kind))
		if not Net._valid_vehicle_id(str(def.id)):
			ids_valid = false
	check("origin motor pool defines a bike and a jeep",
		pool_kinds.has(Gen.VEHICLE_BIKE) and pool_kinds.has(Gen.VEHICLE_JEEP))
	check("vehicle spawn ids satisfy the network grammar", ids_valid)
	var apron: Vector2 = Gen.airstrip_apron_world()
	var apron_defs: Array = Gen.vehicle_layout(
		floori(apron.x / Gen.CHUNK), floori(apron.y / Gen.CHUNK))
	var has_jet := false
	for def in apron_defs:
		if int(def.kind) == Gen.VEHICLE_JET:
			has_jet = true
	check("the fighter jet waits on the airstrip apron", has_jet)
	var layout_twice: Array = Gen.vehicle_layout(7, -3)
	var layout_again: Array = Gen.vehicle_layout(7, -3)
	check("wilderness vehicle rolls are deterministic",
		str(layout_twice) == str(layout_again))

	# --- world spawn plumbing -------------------------------------------------
	check("streaming spawned the motor pool machines",
		w.vehicle_by_id("v:pool#bike") != null
		and w.vehicle_by_id("v:pool#jeep") != null)
	var pool_jeep = w.vehicle_by_id("v:pool#jeep")
	await sim(90)
	check("pool jeep rests settled and upright on real terrain",
		pool_jeep.global_basis.y.y > 0.9
		and pool_jeep.linear_velocity.length() < 1.0,
		"up=%.2f v=%.2f" % [pool_jeep.global_basis.y.y,
			pool_jeep.linear_velocity.length()])
	if Gen.boat_dock_valid:
		var dock_chunk := Vector2i(
			floori(Gen.boat_dock_pos.x / Gen.CHUNK),
			floori(Gen.boat_dock_pos.z / Gen.CHUNK))
		var dock_defs: Array = Gen.vehicle_layout(dock_chunk.x, dock_chunk.y)
		var has_boat := false
		for def in dock_defs:
			if int(def.kind) == Gen.VEHICLE_BOAT:
				has_boat = true
		check("an airboat waits at the nearest lake dock", has_boat)
		# Spawn it directly (its chunk may be outside the warm radius) and
		# confirm it floats on the live wave surface.
		var boat = w.spawn_vehicle(Gen.VEHICLE_BOAT, "v:test#float",
			Gen.boat_dock_pos, Gen.boat_dock_yaw)
		await sim(240)
		var surface: float = w.water_surface_y(boat.global_position.x,
			boat.global_position.z)
		check("airboat floats on the wave surface",
			absf(boat.global_position.y - surface) < 0.6
			and boat.global_basis.y.y > 0.9,
			"y=%.2f surface=%.2f" % [boat.global_position.y, surface])
		# Fan up: it should make way across the water.
		boat.driver = boat
		boat.sleeping = false
		for i in range(240):
			boat.set_inputs(1.0, 0.0, 0.0, false, false)
			await sim(1)
		check("prop thrust drives the airboat across the lake",
			boat.speed() > 6.0, "%.1f m/s" % boat.speed())
		boat.driver = null
	else:
		print("  (no lake within dock search range for this seed — float "
			+ "checks skipped)")

	print("VEHICLEWORLDTEST %d/%d %s" % [total - fails, total,
		"PASS" if fails == 0 else "FAIL"])
	main.get_tree().quit(1 if fails > 0 else 0)
