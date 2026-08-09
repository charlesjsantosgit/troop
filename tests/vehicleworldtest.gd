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
	check("runway is exactly three times its original 420 m length",
		is_equal_approx(Gen.AIRSTRIP_LENGTH, 1260.0)
		and is_equal_approx(Gen.AIRSTRIP_LENGTH,
			Gen.AIRSTRIP_ORIGINAL_LENGTH * Gen.AIRSTRIP_SCALE))
	var direction := Vector2(sin(Gen.airstrip_heading),
		cos(Gen.airstrip_heading))
	var min_h := INF
	var max_h := -INF
	for s in range(-28, 29):
		var p: Vector2 = Gen.airstrip_center + direction \
			* (Gen.AIRSTRIP_LENGTH * 0.5 * float(s) / 28.0)
		var h := Gen.height(p.x, p.y)
		min_h = minf(min_h, h)
		max_h = maxf(max_h, h)
	check("full 1,260 m runway centreline is graded flat and dry",
		max_h - min_h < 0.35 and min_h > Gen.WATER_Y + 1.5,
		"span=%.2f min=%.2f" % [max_h - min_h, min_h])
	var mid: Vector2 = Gen.airstrip_center
	var dirt := Gen.ground_color(Gen.height(mid.x, mid.y), mid.x, mid.y)
	check("runway surface bakes as packed dirt in every tier",
		dirt.r > dirt.g and dirt.r > 0.3,
		"color=%s" % dirt)
	# Gather every chunk crossed by a 12 m grid over the full runway and blend
	# shoulders. The sub-chunk grid keeps a rotated corridor from skipping a
	# corner chunk while the dictionary prevents expensive duplicate layouts.
	var perpendicular := Vector2(direction.y, -direction.x)
	var runway_chunks := {}
	var along_extent := Gen.AIRSTRIP_LENGTH * 0.5 + Gen.AIRSTRIP_BLEND
	var across_extent := Gen.AIRSTRIP_WIDTH * 0.5 + Gen.AIRSTRIP_BLEND
	var sample_step := Gen.CHUNK * 0.25
	var along_steps := ceili(along_extent * 2.0 / sample_step)
	var across_steps := ceili(across_extent * 2.0 / sample_step)
	for along_index in range(along_steps + 1):
		var along := lerpf(-along_extent, along_extent,
			float(along_index) / float(along_steps))
		for across_index in range(across_steps + 1):
			var across := lerpf(-across_extent, across_extent,
				float(across_index) / float(across_steps))
			var sample := Gen.airstrip_center + direction * along \
				+ perpendicular * across
			runway_chunks[Vector2i(floori(sample.x / Gen.CHUNK),
				floori(sample.y / Gen.CHUNK))] = true
	var airfield_layout_cache := {}
	var clean := true
	for runway_chunk in runway_chunks:
		var layout: Dictionary = Gen.chunk_layout(runway_chunk.x,
			runway_chunk.y)
		airfield_layout_cache[runway_chunk] = layout
		for tree in layout.trees:
			if Gen.point_on_airstrip(tree.pos.x, tree.pos.z):
				clean = false
		for plant in layout.foliage:
			if Gen.point_on_airstrip(plant.pos.x, plant.pos.z):
				clean = false
	check("nothing grows through the full 1,260 m runway corridor", clean,
		"chunks=%d" % runway_chunks.size())

	# --- six streamed airplane hangars ---------------------------------------
	var hangars: Array = Gen.airstrip_hangar_layout()
	check("airfield defines exactly six deterministic airplane hangars",
		hangars.size() == Gen.AIRSTRIP_HANGAR_COUNT
		and Gen.AIRSTRIP_HANGAR_COUNT == 6
		and str(hangars) == str(Gen.airstrip_hangar_layout()))
	var hangar_ids := {}
	var hangar_chunks := {}
	var hangars_chunked_once := true
	var hangar_clear := true
	for hangar in hangars:
		hangar_ids[str(hangar.id)] = true
		var hangar_pos: Vector3 = hangar.pos
		var hangar_chunk := Vector2i(floori(hangar_pos.x / Gen.CHUNK),
			floori(hangar_pos.z / Gen.CHUNK))
		hangar_chunks[hangar_chunk] = true
		var local_hangars: Array = Gen.airstrip_hangar_chunk_layout(
			hangar_chunk.x, hangar_chunk.y)
		var appearances := 0
		for local_hangar in local_hangars:
			if str(local_hangar.id) == str(hangar.id):
				appearances += 1
		if appearances != 1:
			hangars_chunked_once = false
		# Check the hangar chunk and all footprint neighbours: neither the
		# canonical tree set nor its dense foliage set may enter a bay clearing.
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var nearby_key := hangar_chunk + Vector2i(dx, dz)
				if not airfield_layout_cache.has(nearby_key):
					airfield_layout_cache[nearby_key] = Gen.chunk_layout(
						nearby_key.x, nearby_key.y)
				var hangar_chunk_layout: Dictionary = \
					airfield_layout_cache[nearby_key]
				for tree in hangar_chunk_layout.trees:
					if Vector2(tree.pos.x, tree.pos.z).distance_to(
							Vector2(hangar_pos.x, hangar_pos.z)) \
							< Gen.AIRSTRIP_HANGAR_CLEARANCE:
						hangar_clear = false
				for plant in hangar_chunk_layout.foliage:
					if Vector2(plant.pos.x, plant.pos.z).distance_to(
							Vector2(hangar_pos.x, hangar_pos.z)) \
							< Gen.AIRSTRIP_HANGAR_CLEARANCE:
						hangar_clear = false
	check("six unique hangar ids map to exactly one streaming chunk each",
		hangar_ids.size() == 6 and hangars_chunked_once)
	check("trees and foliage stay clear under and around every hangar",
		hangar_clear)

	# Build one representative streamed model and collision shell. Four batched
	# visual layers make the shaded interior readable; five shapes provide side,
	# rear, and pitched-roof collision while deliberately leaving the door open.
	var hangar_probe := AirfieldHangar.new()
	hangar_probe.configure(hangars[0])
	main.add_child(hangar_probe)
	var collision_bodies: Array[StaticBody3D] = hangar_probe.build_collisions()
	var collision_shape_count := 0
	var front_blocked := false
	if not collision_bodies.is_empty():
		for child in collision_bodies[0].get_children():
			if child is CollisionShape3D:
				collision_shape_count += 1
				if child.position.z < -Gen.AIRSTRIP_HANGAR_DEPTH * 0.35 \
						and child.shape is BoxShape3D \
						and child.shape.size.x \
							> Gen.AIRSTRIP_HANGAR_WIDTH * 0.6:
					front_blocked = true
	check("hangar has a visible open interior and physical shell",
		hangar_probe.get_node_or_null("ConcreteFloor") != null
		and hangar_probe.get_node_or_null("CorrugatedShell") != null
		and hangar_probe.get_node_or_null("StructuralFrame") != null
		and hangar_probe.get_node_or_null("TaxiMarkings") != null
		and collision_shape_count == 5 and not front_blocked)
	hangar_probe.queue_free()

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
	check("authority resolver maps curated ids to their seeded kinds",
		int(Gen.vehicle_definition_by_id("v:pool#bike").get("kind", -1)) \
			== Gen.VEHICLE_BIKE \
		and int(Gen.vehicle_definition_by_id("v:pool#jeep").get("kind", -1)) \
			== Gen.VEHICLE_JEEP \
		and Gen.vehicle_definition_by_id("v:pool#invented").is_empty())
	var airfield_jet_defs: Array = []
	var airfield_jet_ids := {}
	var airfield_vehicle_chunks := {}
	for hangar in hangars:
		var jet_pos: Vector3 = hangar.jet_pos
		airfield_vehicle_chunks[Vector2i(floori(jet_pos.x / Gen.CHUNK),
			floori(jet_pos.z / Gen.CHUNK))] = true
	for airfield_chunk in airfield_vehicle_chunks:
		for def in Gen.vehicle_layout(airfield_chunk.x, airfield_chunk.y):
			if str(def.id).begins_with("v:strip#jet-"):
				airfield_jet_defs.append(def)
				airfield_jet_ids[str(def.id)] = true
	var every_jet_parked_inside := true
	for hangar in hangars:
		var matching_jet: Dictionary = {}
		for def in airfield_jet_defs:
			if str(def.id) == str(hangar.jet_id):
				matching_jet = def
				break
		if matching_jet.is_empty() \
				or int(matching_jet.kind) != Gen.VEHICLE_JET \
				or not Net._valid_vehicle_id(str(matching_jet.id)) \
				or int(Gen.vehicle_definition_by_id(str(matching_jet.id)).get(
					"kind", -1)) != Gen.VEHICLE_JET:
			every_jet_parked_inside = false
			continue
		var hangar_basis := Basis(Vector3.UP, float(hangar.yaw))
		var local_offset: Vector3 = hangar_basis.inverse() \
			* (matching_jet.pos - hangar.pos)
		var jet_forward := Basis(Vector3.UP, float(matching_jet.yaw)).z
		if absf(local_offset.x) > 0.05 \
				or local_offset.z > 0.0 or local_offset.z < -1.6 \
				or jet_forward.dot(-hangar_basis.z) < 0.999:
			every_jet_parked_inside = false
	check("exactly six uniquely identified fighter jets wait inside the bays",
		airfield_jet_defs.size() == 6 and airfield_jet_ids.size() == 6
		and every_jet_parked_inside)
	# Exercise the actual chunk constructor for every owning hangar and jet chunk,
	# not just the pure layouts. Far chunks omit collision until approached, but
	# they synchronously publish all visible bay models and world-level vehicles.
	var airfield_stream_chunks := hangar_chunks.duplicate()
	for airfield_chunk in airfield_vehicle_chunks:
		airfield_stream_chunks[airfield_chunk] = true
	for airfield_chunk in airfield_stream_chunks:
		if not w.chunks.has(airfield_chunk):
			w.call("_build_chunk", airfield_chunk, false)
	var streamed_hangar_count := 0
	var all_hangar_shells_approach_visible := true
	for airfield_chunk in hangar_chunks:
		var streamed_chunk: Chunk = w.chunks.get(airfield_chunk)
		if not streamed_chunk:
			continue
		for child in streamed_chunk.get_children():
			if child is AirfieldHangar:
				streamed_hangar_count += 1
				for mesh_node in child.find_children("*", "MeshInstance3D", true,
						false):
					var mesh := mesh_node as MeshInstance3D
					all_hangar_shells_approach_visible = \
						all_hangar_shells_approach_visible \
						and mesh.visibility_range_end \
						>= AirfieldHangar.VISIBILITY_RANGE
	check("owning chunks construct all six visible hangar models",
		streamed_hangar_count == 6 and all_hangar_shells_approach_visible)
	# Query every owning chunk again and feed the duplicate definitions through
	# the real world registry twice. Stable IDs must still create only six jets.
	w.request_vehicle_spawns(airfield_jet_defs)
	w.request_vehicle_spawns(airfield_jet_defs)
	var spawned_airfield_jets := 0
	for vehicle_id in w.vehicles:
		if str(vehicle_id).begins_with("v:strip#jet-"):
			spawned_airfield_jets += 1
			w.vehicles[vehicle_id].freeze = true
	check("chunk retries cannot duplicate any hangar jet",
		spawned_airfield_jets == 6)
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
			boat.speed() > 6.0,
			"speed=%.2f fwd=%.2f spool=%.2f water=%s pos=%s" % [boat.speed(),
				boat.forward_speed(), boat.spool, str(boat._in_water),
				boat.global_position])
		boat.driver = null
	else:
		print("  (no lake within dock search range for this seed — float "
			+ "checks skipped)")

	# --- admin vehicle powers: deliver anywhere, teleport to every spawn ----
	var admin = main.admin_controller
	var p = w.local_player
	p.test_mode = true
	var delivered_ok := true
	for kind_word in ["bike", "jeep", "boat", "jet"]:
		if not admin.spawn_vehicle(kind_word):
			delivered_ok = false
	await sim(30)
	var delivered := 0
	for vid in w.vehicles:
		if str(vid).begins_with("v:admin#"):
			delivered += 1
	check("admin delivers every vehicle kind on the spot",
		delivered_ok and delivered == 4 \
		and Net.vehicle_spawn_definitions.size() == 4,
		"spawned=%d authority_defs=%d" % [delivered,
			Net.vehicle_spawn_definitions.size()])
	# A joining World is constructed after cl_world has already copied the
	# authority snapshot. Exercise that fresh-world path without warming another
	# terrain stream: each dynamic definition must immediately produce one node.
	var late_world := World.new()
	late_world.process_mode = Node.PROCESS_MODE_DISABLED
	main.add_child(late_world)
	for delivered_id in Net.vehicle_spawn_definitions:
		var delivered_definition: Dictionary = \
			Net.vehicle_spawn_definitions[delivered_id]
		late_world.call("_on_vehicle_spawn_registered", str(delivered_id),
			int(delivered_definition.kind), delivered_definition.pos,
			float(delivered_definition.yaw))
	check("late-join vehicle snapshot spawns every unoccupied admin delivery",
		late_world.vehicles.size() == 4)
	late_world.queue_free()
	var ride = null
	for vid in w.vehicles:
		if str(vid).begins_with("v:admin#"):
			ride = w.vehicles[vid]
			break
	check("a delivered machine is immediately mountable",
		ride != null and ride.can_enter(p))

	admin.teleport_to_vehicle_spot("airstrip")
	await sim(5)
	var apron_spot: Vector2 = Gen.airstrip_apron_world()
	check("teleport lands on the airstrip apron",
		Vector2(p.global_position.x, p.global_position.z) \
			.distance_to(apron_spot) < 30.0)
	admin.teleport_to_vehicle_spot("pool")
	await sim(5)
	check("teleport lands at the origin motor pool",
		Vector2(p.global_position.x, p.global_position.z) \
			.distance_to(Vector2(40.0, 4.0)) < 12.0)
	if Gen.boat_dock_valid:
		admin.teleport_to_vehicle_spot("dock")
		await sim(5)
		check("teleport lands dry on the dock shore",
			Vector2(p.global_position.x, p.global_position.z).distance_to(
				Vector2(Gen.boat_dock_pos.x, Gen.boat_dock_pos.z)) < 70.0
			and Gen.height(p.global_position.x, p.global_position.z)
				> Gen.WATER_Y)
	var hidden: Dictionary = admin._nearest_wilderness_vehicle(
		p.global_position)
	check("a wilderness machine hides within scan range",
		not hidden.is_empty())
	if not hidden.is_empty():
		var hidden_pos: Vector3 = hidden.pos
		var hidden_id := "v:%d,%d#0" % [
			floori(hidden_pos.x / Gen.CHUNK), floori(hidden_pos.z / Gen.CHUNK)]
		var resolved_hidden: Dictionary = Gen.vehicle_definition_by_id(hidden_id)
		check("authority resolver verifies the exact wilderness chunk roll",
			str(resolved_hidden.get("id", "")) == hidden_id \
			and int(resolved_hidden.get("kind", -1)) == int(hidden.kind) \
			and Gen.vehicle_definition_by_id(hidden_id.replace("#0", "#1")) \
				.is_empty())
		admin.teleport_to_vehicle_spot("machine")
		await sim(5)
		check("teleport lands beside the hidden machine",
			p.global_position.distance_to(hidden.pos) < 9.0)

	print("VEHICLEWORLDTEST %d/%d %s" % [total - fails, total,
		"PASS" if fails == 0 else "FAIL"])
	main.get_tree().quit(1 if fails > 0 else 0)
