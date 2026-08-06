extends Node
## Deterministic biome, macro-lake and visual-only horizon verification.

const HorizonChunkScript = preload("res://scripts/horizon_chunk.gd")

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


func run() -> void:
	print("GENERATIONTEST begin seed=%d" % Gen.world_seed)
	var layout_a := Gen.chunk_layout(7, -4)
	var layout_b := Gen.chunk_layout(7, -4)
	_check(layout_a.biome == layout_b.biome \
		and layout_a.trees.size() == layout_b.trees.size() \
		and layout_a.foliage.size() == layout_b.foliage.size() \
		and (layout_a.foliage.is_empty() or
			layout_a.foliage[0].pos == layout_b.foliage[0].pos),
		"biome, canopy and understory layouts are deterministic")
	var structures_deterministic: bool = layout_a.structures.size() \
		== layout_b.structures.size()
	if structures_deterministic and not layout_a.structures.is_empty():
		var structure_a: Dictionary = layout_a.structures[0]
		var structure_b: Dictionary = layout_b.structures[0]
		structures_deterministic = structure_a.id == structure_b.id \
			and structure_a.pos == structure_b.pos \
			and structure_a.ammo_kind == structure_b.ammo_kind \
			and structure_a.ammo_amount == structure_b.ammo_amount \
			and structure_a.bandages == structure_b.bandages
	_check(structures_deterministic,
		"supply hut position, loot type and chest contents are deterministic")

	var arena_a: Dictionary = Gen.arena_layout()
	var arena_b: Dictionary = Gen.arena_layout()
	var arena_blueprint_ok := arena_a == arena_b \
		and str(arena_a.get("id", "")) == Gen.ARENA_ID \
		and int(arena_a.get("version", 0)) >= 2 \
		and float(arena_a.get("radius", 0.0)) == Gen.ARENA_RADIUS \
		and int(arena_a.get("gate_count", 0)) == 4 \
		and (arena_a.get("pieces", []) as Array).size() >= 12 \
		and (arena_a.get("cover_points", []) as Array).size() >= 10 \
		and (arena_a.get("flank_points", []) as Array).size() >= 6 \
		and (arena_a.get("lanes", []) as Array).size() >= 3
	_check(arena_blueprint_ok,
		"the origin duel arena has deterministic lanes, flank routes, gates, and dense authored cover")

	var arena_huts: Array = arena_a.get("supply_huts", [])
	var arena_spawns: Array = arena_a.get("spawn_points", [])
	var arena_hut_ids := {}
	var arena_ammo_kinds := {}
	var arena_huts_safe := arena_huts.size() == 4 and arena_spawns.size() == 2
	var minimum_spawn_gap := INF
	for hut_value in arena_huts:
		var hut: Dictionary = hut_value
		var hut_id := str(hut.get("id", ""))
		var hut_pos: Vector3 = hut.get("pos", Vector3.ZERO)
		var hut_radius := float(hut.get("clearance", 0.0))
		arena_huts_safe = arena_huts_safe and hut_id.begins_with("s:arena#") \
			and not arena_hut_ids.has(hut_id) \
			and bool(hut.get("arena", false)) \
			and int(hut.get("bandages", 0)) >= 1 \
			and int(hut.get("ammo_amount", 0)) > 0 \
			and hut_pos.y > Gen.WATER_Y + 0.7 \
			and Vector2(hut_pos.x, hut_pos.z).length() < Gen.ARENA_RADIUS
		arena_hut_ids[hut_id] = true
		arena_ammo_kinds[int(hut.get("ammo_kind", -1))] = true
		for spawn_value in arena_spawns:
			var spawn: Vector3 = spawn_value
			minimum_spawn_gap = minf(minimum_spawn_gap,
				Vector2(hut_pos.x, hut_pos.z).distance_to(
					Vector2(spawn.x, spawn.z)) - hut_radius)
	arena_huts_safe = arena_huts_safe and arena_hut_ids.size() == 4 \
		and arena_ammo_kinds.size() == 4 and minimum_spawn_gap > 5.0
	_check(arena_huts_safe,
		"four spawn-safe arena huts guarantee bandages and weapon-specific ammo for both duelists",
		"huts=%d ids=%d ammo_kinds=%d min_spawn_gap=%.2f" % [
			arena_huts.size(), arena_hut_ids.size(), arena_ammo_kinds.size(),
			minimum_spawn_gap])

	var origin_piece_count := 0
	var origin_hut_count := 0
	var origin_chunks_valid := true
	var arena_decorations_clear := true
	for cx in range(-1, 1):
		for cz in range(-1, 1):
			var origin_near := Gen.chunk_layout(cx, cz)
			var origin_far := Gen.chunk_layout(cx, cz, false)
			var chunk_arena := Gen.arena_chunk_layout(cx, cz)
			origin_piece_count += (origin_near.get("arena_pieces", []) as Array).size()
			for structure_value in origin_near.get("structures", []):
				var structure: Dictionary = structure_value
				if bool(structure.get("arena", false)):
					origin_hut_count += 1
			origin_chunks_valid = origin_chunks_valid \
				and str(origin_near.get("arena_id", "")) == Gen.ARENA_ID \
				and str(chunk_arena.get("id", "")) == Gen.ARENA_ID \
				and origin_near.get("structures", []) \
					== origin_far.get("structures", []) \
				and origin_near.get("arena_pieces", []) \
					== origin_far.get("arena_pieces", [])
			var clearances: Array = (origin_near.get("structures", []) as Array).duplicate()
			clearances.append_array(origin_near.get("arena_pieces", []))
			for obstacle_value in clearances:
				var obstacle: Dictionary = obstacle_value
				var obstacle_pos: Vector3 = obstacle.get("pos", Vector3.ZERO)
				var clearance := float(obstacle.get("clearance", 0.0))
				for tree in origin_near.get("trees", []):
					arena_decorations_clear = arena_decorations_clear and Vector2(
						tree.pos.x, tree.pos.z).distance_to(Vector2(
						obstacle_pos.x, obstacle_pos.z)) >= clearance
				for rock in origin_near.get("rocks", []):
					arena_decorations_clear = arena_decorations_clear and Vector2(
						rock.pos.x, rock.pos.z).distance_to(Vector2(
						obstacle_pos.x, obstacle_pos.z)) >= clearance
				for plant in origin_near.get("foliage", []):
					arena_decorations_clear = arena_decorations_clear and Vector2(
						plant.pos.x, plant.pos.z).distance_to(Vector2(
						obstacle_pos.x, obstacle_pos.z)) >= clearance
	_check(origin_chunks_valid and origin_piece_count == 12 \
		and origin_hut_count == 4 and arena_decorations_clear \
		and str(Gen.arena_chunk_layout(1, 0).get("id", "")).is_empty(),
		"arena cover and huts stream canonically in four origin chunks with clear prop footprints",
		"pieces=%d huts=%d clear=%s" % [origin_piece_count, origin_hut_count,
			arena_decorations_clear])

	var arena_min_height := INF
	var arena_max_height := -INF
	for x in range(-35, 36, 5):
		for z in range(-35, 36, 5):
			if Vector2(float(x), float(z)).length() > 35.0:
				continue
			var arena_height := Gen.height(float(x), float(z))
			arena_min_height = minf(arena_min_height, arena_height)
			arena_max_height = maxf(arena_max_height, arena_height)
	_check(arena_min_height > Gen.WATER_Y + 1.5 \
		and arena_max_height - arena_min_height < 0.35,
		"the full duel bowl is dry and gently graded for reliable combat movement",
		"height_range=%.3f min=%.3f" % [arena_max_height - arena_min_height,
			arena_min_height])

	var seen := {}
	for x in range(-1800, 1801, 120):
		for z in range(-1800, 1801, 120):
			seen[Gen.biome_at(float(x), float(z))] = true
	_check(seen.size() == Gen.Biome.size(),
		"all four macro biomes occur across a deterministic world region",
		"found=%s" % [seen.keys()])

	var biome_examples := {}
	for cx in range(-30, 31):
		for cz in range(-30, 31):
			var biome := Gen.biome_at((float(cx) + 0.5) * Gen.CHUNK,
				(float(cz) + 0.5) * Gen.CHUNK)
			if not biome_examples.has(biome):
				biome_examples[biome] = Gen.chunk_layout(cx, cz)
	var rich_examples := biome_examples.size() == Gen.Biome.size()
	for biome in biome_examples:
		var example: Dictionary = biome_examples[biome]
		rich_examples = rich_examples and example.foliage.size() >= 35
	_check(rich_examples,
		"every biome supplies a dense biome-coloured understory")

	var hut_count := 0
	var bandage_huts := 0
	var hut_ammo_kinds := {}
	var hut_layouts_valid := true
	for cx in range(-20, 21):
		for cz in range(-20, 21):
			var near_layout := Gen.chunk_layout(cx, cz)
			var far_layout := Gen.chunk_layout(cx, cz, false)
			hut_layouts_valid = hut_layouts_valid and near_layout.structures \
				== far_layout.structures
			for structure in near_layout.structures:
				hut_count += 1
				bandage_huts += 1 if int(structure.bandages) > 0 else 0
				hut_ammo_kinds[int(structure.ammo_kind)] = true
				var hut_pos: Vector3 = structure.pos
				var clearance := float(structure.clearance)
				hut_layouts_valid = hut_layouts_valid \
					and int(structure.biome) != Gen.Biome.WETLAND \
					and hut_pos.y > Gen.WATER_Y + 0.7 \
					and str(structure.id).begins_with("s:")
				for tree in near_layout.trees:
					hut_layouts_valid = hut_layouts_valid and Vector2(
						tree.pos.x, tree.pos.z).distance_to(Vector2(
						hut_pos.x, hut_pos.z)) >= clearance
				for rock in near_layout.rocks:
					hut_layouts_valid = hut_layouts_valid and Vector2(
						rock.pos.x, rock.pos.z).distance_to(Vector2(
						hut_pos.x, hut_pos.z)) >= clearance
	_check(hut_count >= 35 and bandage_huts > 0 \
		and hut_ammo_kinds.size() == 4 and hut_layouts_valid,
		"dry biomes commonly contain clear, weapon-specific supply huts with optional bandages",
		"huts=%d bandage_huts=%d ammo_kinds=%d" % [hut_count,
			bandage_huts, hut_ammo_kinds.size()])

	var bamboo_shape := false
	var highland_shape := false
	var rainforest_crown := false
	for cx in range(-20, 21):
		for cz in range(-20, 21):
			for tree in Gen.chunk_layout(cx, cz, false).trees:
				if tree.biome == Gen.Biome.BAMBOO_GROVE \
						and tree.trunk_r < 0.42:
					bamboo_shape = true
				elif tree.biome == Gen.Biome.HIGHLAND \
						and tree.trunk_r > 0.82:
					highland_shape = true
				elif tree.biome == Gen.Biome.RAINFOREST \
						and tree.blobs.size() >= 3:
					rainforest_crown = true
			if bamboo_shape and highland_shape and rainforest_crown:
				break
		if bamboo_shape and highland_shape and rainforest_crown:
			break
	_check(bamboo_shape and highland_shape and rainforest_crown,
		"biomes generate distinct bamboo, highland and rainforest tree forms")

	# Measure complete water runs over a 3.2 km square. A 12 m sampling interval
	# is conservative at shorelines; 144 m therefore proves broad macro lakes,
	# rather than the former one- or two-cell puddles.
	var max_water_span := 0.0
	var wet_samples := 0
	const SAMPLE_STEP := 12
	for z in range(-1600, 1601, SAMPLE_STEP):
		var run := 0
		for x in range(-1600, 1601, SAMPLE_STEP):
			if Gen.height(float(x), float(z)) < Gen.WATER_Y:
				run += 1
				wet_samples += 1
				max_water_span = maxf(max_water_span,
					float(run * SAMPLE_STEP))
			else:
				run = 0
	_check(max_water_span >= 144.0 and wet_samples > 1200,
		"macro carving creates lakes at least ten old pond widths across",
		"span=%.0fm wet_samples=%d" % [max_water_span, wet_samples])

	var canonical: Array = Gen.chunk_layout(7, -4, false).trees
	var distant: Array = Gen.distant_tree_layout(7, -4)
	var promotion_exact: bool = canonical.size() == distant.size()
	if promotion_exact and not canonical.is_empty():
		promotion_exact = canonical[0].pos == distant[0].pos \
			and is_equal_approx(float(canonical[0].trunk_h),
				float(distant[0].trunk_h))
	_check(promotion_exact,
		"far tree silhouettes promote into the same canonical near trees")

	var old_edge := Gen.CHUNK * (float(Gen.VIEW_R) + 0.5)
	var horizon_ratio := Gen.HORIZON_DISTANCE / old_edge
	_check(horizon_ratio >= 5.0 and horizon_ratio <= 10.0,
		"visual horizon reaches five to ten times beyond the old chunk edge",
		"ratio=%.2f distance=%.0fm" % [horizon_ratio, Gen.HORIZON_DISTANCE])

	var sector = HorizonChunkScript.new()
	add_child(sector)
	sector.setup(Vector2i(2, -1))
	var visual_only: bool = sector.terrain_vertex_count == 289 \
		and sector.tree_instance_count > 80
	for child in sector.get_children():
		visual_only = visual_only and not (child is CollisionObject3D) \
			and not (child is Banana)
	_check(visual_only,
		"coarse horizon sectors contain indexed visuals without gameplay nodes",
		"vertices=%d trees=%d children=%d" % [sector.terrain_vertex_count,
			sector.tree_instance_count, sector.get_child_count()])
	print(("GENERATION_STATS biomes=%d lake_span=%.0fm wet_samples=%d " \
		+ "horizon=%.0fm ratio=%.2fx sector_trees=%d") % [seen.size(),
		max_water_span, wet_samples, Gen.HORIZON_DISTANCE, horizon_ratio,
		sector.tree_instance_count])
	sector.queue_free()

	print("GENERATIONTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
