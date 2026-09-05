extends Node

const Plan = preload("res://scripts/city_plan.gd")
const World = preload("res://scripts/city_world.gd")
const Routes = preload("res://scripts/frontier_routes.gd")
const TownLayout = preload("res://scripts/frontier_town_layout.gd")

var checks := 0
var passed := 0


func run() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_constants_and_districts()
	_test_complete_deterministic_census()
	_test_public_lookup_boundaries()
	_test_services_housing_and_stops()
	_test_village_property_clearance()
	_test_streaming_budget()
	print("CITYPLANTEST %d/%d PASS" % [passed, checks])
	get_tree().quit(0 if passed == checks else 1)


func _test_constants_and_districts() -> void:
	_check(Plan.CENTER == Vector2(14400.0, 0.0), "city center is exact")
	_check(Plan.GRID_SIZE == 48 and is_equal_approx(Plan.BLOCK_SIZE, 480.0), "48 by 48 block plan")
	_check(is_equal_approx(Plan.MAX_X - Plan.MIN_X, 23040.0), "east-west footprint is 23.04 km")
	_check(is_equal_approx(Plan.MAX_Z - Plan.MIN_Z, 23040.0), "north-south footprint is 23.04 km")
	_check(absf(Plan.SQUARE_MILES - 205.0) < 0.1, "footprint is approximately 205 square miles")
	_check(is_equal_approx(Plan.GROUND_Y, 8.0), "city shares terrain ground height")
	_check(Plan.contains(Vector2(Plan.MIN_X, Plan.MIN_Z)), "minimum bound is included")
	_check(Plan.contains(Vector2(Plan.MAX_X, Plan.MAX_Z)), "maximum bound is included")
	_check(not Plan.contains(Vector2(Plan.MIN_X - 0.01, 0.0)), "outside point is excluded")
	_check(Plan.world_to_block(Vector2(Plan.MIN_X, Plan.MIN_Z)) == Vector2i.ZERO, "minimum maps to first block")
	_check(Plan.world_to_block(Vector2(Plan.MAX_X, Plan.MAX_Z)) == Vector2i(47, 47), "maximum maps to last block")

	var districts := Plan.district_catalog()
	var names: Dictionary = {}
	var kinds: Dictionary = {}
	for record in districts:
		names[record.name] = true
		kinds[record.kind] = true
		var center: Vector3 = record.center
		_check(Plan.contains(Vector2(center.x, center.z)), "district center stays in city")
	_check(districts.size() == 12 and names.size() == 12, "twelve named municipal districts")
	_check(kinds.size() >= 9, "districts have meaningful mixed purposes")
	_check(Plan.district(-1).is_empty() and Plan.district(12).is_empty(), "district lookup rejects invalid IDs")


func _test_complete_deterministic_census() -> void:
	var ids: Dictionary = {}
	var resident_total := 0
	var building_total := 0
	var all_records_valid := true
	var all_ids_unique := true
	var all_lots_aligned := true
	var all_housing_purchasable := true
	var represented_kinds: Dictionary = {}
	var represented_services: Dictionary = {}
	for y in range(Plan.GRID_SIZE):
		for x in range(Plan.GRID_SIZE):
			var key := Vector2i(x, y)
			var records := Plan.block_buildings(key)
			var block_residents := 0
			for record in records:
				building_total += 1
				block_residents += int(record.residents)
				resident_total += int(record.residents)
				represented_kinds[record.kind] = true
				represented_services[record.service] = true
				if ids.has(record.id):
					all_ids_unique = false
				ids[record.id] = true
				var position: Vector3 = record.position
				var size: Vector3 = record.size
				var door: Vector3 = record.door
				all_records_valid = all_records_valid and (
					String(record.id).begins_with("crownreach-b")
					and record.block == key
					and Plan.contains(Vector2(position.x, position.z))
					and is_equal_approx(position.y, Plan.GROUND_Y)
					and is_equal_approx(door.y, Plan.GROUND_Y)
					and size.x > 0.0 and size.y > 7.0 and size.z > 0.0
					and not String(record.service).is_empty()
					and (not String(record.housing).is_empty() or int(record.jobs) > 0)
				)
				all_lots_aligned = all_lots_aligned and (
					is_equal_approx(fposmod(position.x - Plan.MIN_X, 120.0), 60.0)
					and is_equal_approx(fposmod(position.z - Plan.MIN_Z, 120.0), 60.0)
				)
				if not String(record.housing).is_empty():
					var residence: Vector3 = record.residence
					all_records_valid = all_records_valid and residence.y > Plan.GROUND_Y + 3.0
					all_housing_purchasable = all_housing_purchasable and bool(record.purchasable)
					all_records_valid = all_records_valid and not Plan.housing_tier(record.housing).is_empty()
			_check(block_residents == Plan.block_population(key), "block %d,%d census allocation" % [x, y])
	_check(building_total == Plan.ESTIMATED_BUILDING_COUNT, "expected conceptual building count")
	_check(ids.size() == building_total and all_ids_unique, "public building IDs are globally unique")
	_check(resident_total == Plan.RESIDENT_TARGET and resident_total == 400000, "aggregate population is exactly 400,000")
	_check(all_records_valid, "every building has a valid door and property or service role")
	_check(all_lots_aligned, "lot centers align to 120 metre street cells")
	_check(all_housing_purchasable, "every valid housing record is purchasable")
	_check(represented_kinds.has("warehouse") and represented_kinds.has("restaurant") and represented_kinds.has("clinic") and represented_kinds.has("school") and represented_kinds.has("depot") and represented_kinds.has("utility"), "required physical building types are represented")
	_check(represented_services.has("produce_market") and represented_services.has("restaurant_kitchen") and represented_services.has("warehouse_handler") and represented_services.has("transit_depot") and represented_services.has("utility_crew"), "non-office work services are represented")

	var samples := [
		"crownreach-b00-00-l00", "crownreach-b24-24-l00",
		"crownreach-b24-24-l15", "crownreach-b47-47-l15",
	]
	for id in samples:
		var first := Plan.building(id)
		var second := Plan.building(id)
		_check(not first.is_empty() and first == second and first.id == id, "%s regenerates identically" % id)


func _test_public_lookup_boundaries() -> void:
	var malformed := [
		"", "crownreach-b-1-00-l00", "crownreach-b00-00-l-1",
		"crownreach-b48-00-l00", "crownreach-b00-48-l00",
		"crownreach-b00-00-l16", "crownreach-b0-00-l00",
		"crownreach-b23-23-l15", "../crownreach-b00-00-l00",
	]
	for id in malformed:
		_check(Plan.building(id).is_empty(), "malformed or reserved ID rejected: %s" % id)
	_check(Plan.block_buildings(Vector2i(-1, 0)).is_empty(), "negative block rejected")
	_check(Plan.block_buildings(Vector2i(48, 0)).is_empty(), "oversized block rejected")

	var nearby := Plan.blocks_near(Vector3(Plan.CENTER.x, Plan.GROUND_Y, Plan.CENTER.y), 2)
	var all_nearby_valid := true
	for key in nearby:
		all_nearby_valid = all_nearby_valid and Plan.valid_block(key)
	_check(nearby.size() == 25 and all_nearby_valid, "center query returns bounded 25-block window")
	_check(Plan.blocks_near(Vector3.ZERO, 2).is_empty(), "distant village does not stream city edge")
	_check(Plan.blocks_near(Vector3(Plan.MIN_X, Plan.GROUND_Y, Plan.MIN_Z), 6).size() <= 49, "edge query remains clipped and bounded")

	var pavilion := Plan.building("crownreach-b24-24-l00")
	var nearest := Plan.nearest_building(pavilion.door, 0.01)
	_check(not nearest.is_empty() and nearest.id == pavilion.id, "nearest lookup resolves exact usable door")
	_check(Plan.nearest_building(Vector3(1000000.0, 0.0, 1000000.0), 10.0).is_empty(), "nearest lookup honors range")
	_check(Plan.nearest_building(Vector3.ZERO, -1.0).is_empty(), "nearest lookup rejects negative range")
	_check(Plan.nearest_building(Vector3.ZERO, INF).is_empty(), "nearest lookup rejects unbounded range")


func _test_services_housing_and_stops() -> void:
	var required_service_kinds := {
		"courier_depot": 1,
		"courier_delivery": 3,
		"maintenance_depot": 1,
		"maintenance_site": 3,
		"produce_exchange": 1,
		"produce_market": 1,
		"home_office": 1,
	}
	var actual_counts: Dictionary = {}
	var service_ids: Dictionary = {}
	var service_records_valid := true
	for record in Plan.services():
		actual_counts[record.kind] = int(actual_counts.get(record.kind, 0)) + 1
		service_ids[record.id] = true
		var host := Plan.building(record.building_id)
		service_records_valid = service_records_valid and not host.is_empty() and record.position == host.door
		service_records_valid = service_records_valid and Plan.service(record.id) == record
	for kind in required_service_kinds:
		_check(int(actual_counts.get(kind, 0)) == int(required_service_kinds[kind]), "%s canonical service count" % kind)
	_check(service_ids.size() == Plan.services().size() and service_records_valid, "service IDs and door anchors are stable")
	_check(Plan.service("forged_service").is_empty(), "unknown service rejected")

	var expected_tiers := ["cottage", "town_apartment", "suburban_home", "city_apartment", "penthouse", "warehouse"]
	var housing := Plan.housing_catalog()
	var actual_tiers: Array[String] = []
	for record in housing:
		actual_tiers.append(record.tier)
		var host := Plan.building(record.building_id)
		_check(not host.is_empty() and host.housing == record.tier and host.purchasable, "%s canonical purchase record" % record.tier)
	_check(housing.size() == 6 and actual_tiers == expected_tiers, "six housing progression tiers are stable")
	_check(Plan.purchasable_housing_ids().size() == 6, "six canonical housing examples exposed")
	_check(Plan.housing_tier("work_live") == "city_apartment" and Plan.housing_tier("staff_residence") == "city_apartment", "legacy mixed housing normalizes")
	_check(Plan.housing_tier("town_house") == "suburban_home", "legacy town house normalizes")

	var properties := Plan.canonical_properties()
	_check(properties.size() == 3, "three village properties exposed")
	_check(properties[0].position == Vector3(-125.0, 3.25, 100.0), "cottage has clear absolute world anchor")
	_check(properties[1].position == Vector3(525.0, 3.25, 65.0), "town apartments have clear absolute world anchor")
	_check(properties[2].position == Vector3(-730.0, 3.25, -490.0), "suburban home has clear absolute world anchor")

	var stops := Plan.stops()
	var stop_ids: Dictionary = {}
	for stop in stops:
		stop_ids[stop.id] = true
	_check(stops.size() == 22 and stop_ids.size() == 22, "village, square, district, and job stops exposed")
	_check(stops[0].position == Vector3(-60.0, 3.25, 55.0), "origin village bus anchor exact")
	_check(stops[1].position == Vector3(14400.0, 8.0, 0.0), "Lantern Square stop anchor exact")
	var pavilion := Plan.building("crownreach-b24-24-l00")
	var stop_distance := Vector2(stops[1].position.x, stops[1].position.z).distance_to(Vector2(pavilion.door.x, pavilion.door.z))
	_check(stop_distance < 100.0, "Lantern arrival has service within 100 metres")
	var every_job_reachable := true
	for service_record in Plan.services():
		var nearest_stop_distance := INF
		for stop in stops:
			var service_position: Vector3 = service_record.position
			var stop_position: Vector3 = stop.position
			nearest_stop_distance = minf(nearest_stop_distance, Vector2(service_position.x, service_position.z).distance_to(Vector2(stop_position.x, stop_position.z)))
		every_job_reachable = every_job_reachable and nearest_stop_distance < 100.0
	_check(every_job_reachable, "every functional job service is within 100 metres of transit")


func _test_village_property_clearance() -> void:
	var origins := {
		"village-cottage": Vector2(0.0, 0.0),
		"town-apartments": Vector2(650.0, 0.0),
		"suburban-home": Vector2(-600.0, -400.0),
	}
	var properties := Plan.canonical_properties()
	for record in properties:
		var position: Vector3 = record.position
		var door: Vector3 = record.door
		var size: Vector3 = record.size
		var origin: Vector2 = origins[record.id]
		var local_center := Vector2(position.x, position.z) - origin
		var half_size := Vector2(size.x, size.z) * 0.5
		var local_door := Vector2(door.x, door.z) - origin
		var approach_direction := (local_door - local_center).normalized()
		var local_approach := local_door + approach_direction * 7.5
		var footprint_inside := true
		for x_sign in [-1.0, 1.0]:
			for z_sign in [-1.0, 1.0]:
				var corner := local_center + Vector2(x_sign * half_size.x, z_sign * half_size.y)
				footprint_inside = footprint_inside and corner.length() < TownLayout.TOWN_RADIUS
		_check(is_equal_approx(position.y, 3.25) and is_equal_approx(door.y, 3.25), "%s stays on exact village grade" % record.id)
		_check(footprint_inside and local_door.length() < TownLayout.TOWN_RADIUS and local_approach.length() < TownLayout.TOWN_RADIUS, "%s footprint and 7.5 metre door approach stay inside flat grade" % record.id)

		var internal_roads_clear := true
		for segment in Routes.road_segments():
			var road_from: Vector2 = segment.from
			var road_to: Vector2 = segment.to
			var road_half_width := float(segment.width) * 0.5
			internal_roads_clear = internal_roads_clear and _segment_rect_distance(road_from, road_to, local_center, half_size) > road_half_width
			internal_roads_clear = internal_roads_clear and _segment_distance(road_from, road_to, local_door, local_approach) > road_half_width
		_check(internal_roads_clear, "%s footprint and approach avoid FrontierRoutes road corridors" % record.id)

		var connecting_roads_clear := true
		var world_center := Vector2(position.x, position.z)
		var world_door := Vector2(door.x, door.z)
		var world_approach := origin + local_approach
		for road: Array in TownLayout.CONNECTING_ROADS:
			for index in range(road.size() - 1):
				var connecting_from: Vector2 = road[index]
				var connecting_to: Vector2 = road[index + 1]
				connecting_roads_clear = connecting_roads_clear and _segment_rect_distance(connecting_from, connecting_to, world_center, half_size) > TownLayout.ROAD_HALF_WIDTH
				connecting_roads_clear = connecting_roads_clear and _segment_distance(connecting_from, connecting_to, world_door, world_approach) > TownLayout.ROAD_HALF_WIDTH
		_check(connecting_roads_clear, "%s footprint and approach avoid connecting road corridors" % record.id)

	var properties_separate := true
	for first_index in range(properties.size()):
		for second_index in range(first_index + 1, properties.size()):
			var first: Dictionary = properties[first_index]
			var second: Dictionary = properties[second_index]
			properties_separate = properties_separate and (
				absf(first.position.x - second.position.x) > (first.size.x + second.size.x) * 0.5
				or absf(first.position.z - second.position.z) > (first.size.z + second.size.z) * 0.5
			)
	_check(properties_separate, "canonical village property footprints do not overlap")


func _test_streaming_budget() -> void:
	var host := Node3D.new()
	host.name = "CityPlanTestHost"
	get_tree().root.add_child(host)
	var city := World.new()
	host.add_child(city)
	city.configure(host)
	_check(city.visible_block_count() == 0, "configure does not allocate city buildings")
	_check(city.render_batch_count() <= 7, "village properties and far city use bounded batches")
	_check(city.collision_shape_count() == 3, "canonical properties use three bounded collisions")
	var initial_stats: Dictionary = city.stats()
	_check(int(initial_stats.far_lod_batches) == 1 and int(initial_stats.far_lod_instances) == 0, "far LOD allocates one empty staged batch")
	_check(int(initial_stats.far_lod_capacity) == Plan.ESTIMATED_BUILDING_COUNT and int(initial_stats.far_lod_colliders) == 0, "far LOD has exact conceptual capacity and no colliders")
	var far_bounds := city.far_lod_bounds()
	_check(far_bounds.position == Vector3(Plan.MIN_X, Plan.GROUND_Y, Plan.MIN_Z) and is_equal_approx(far_bounds.size.x, 23040.0) and is_equal_approx(far_bounds.size.z, 23040.0), "far LOD has stable full-city culling bounds")
	var shelters_clear := true
	for stop in Plan.stops():
		var shelter: Vector3 = city.shelter_position(stop.position)
		shelters_clear = shelters_clear and shelter.distance_to(stop.position) >= 17.0
		for property in Plan.canonical_properties():
			shelters_clear = shelters_clear and _shelter_clear_of(shelter, property)
		if Plan.contains(Vector2(shelter.x, shelter.z)):
			for key in Plan.blocks_near(shelter, 1):
				for building in Plan.block_buildings(key):
					shelters_clear = shelters_clear and _shelter_clear_of(shelter, building)
	_check(shelters_clear, "shelters leave arrival anchors open and avoid building footprints")

	city.update_focus(Vector3(Plan.CENTER.x, Plan.GROUND_Y, Plan.CENTER.y))
	var incremental := true
	for tick in range(25):
		var before := city.visible_block_count()
		city._process(1.0 / 60.0)
		var added := city.visible_block_count() - before
		incremental = incremental and added >= 0 and added <= 1 and city.last_built_this_tick() <= 1 and city.last_far_staged_this_tick() <= 1
	_check(incremental, "streamer creates at most one block per tick")
	_check(city.visible_block_count() == 25 and city.queued_block_count() == 0, "streamer settles at 25 visible blocks")
	_check(city.far_staged_block_count() == 25 and city.far_visible_instance_count() == 25 * Plan.LOTS_PER_BLOCK, "far skyline fills one block per tick outside detailed ring")
	var detailed_blocks_hidden := true
	for key in city.loaded_block_keys():
		detailed_blocks_hidden = detailed_blocks_hidden and not city.far_block_has_silhouette(key)
	_check(detailed_blocks_hidden, "far silhouettes never overlap detailed blocks")
	_check(city.collision_shape_count() <= 3 + 9 * Plan.LOTS_PER_BLOCK * 2, "detailed collision stays within near-block budget")
	_check(_setback_collisions_match(city), "setback towers use inset upper colliders without invisible walls")
	_check(city.render_batch_count() <= 7 + 8 * 25, "geometry remains in per-block batches")
	_check(_count_nodes(city) < 500, "streamed node count stays bounded")
	_check(_largest_horizontal_instance(city) < Plan.BLOCK_SIZE, "renderer contains no city-sized ground plane")
	var completion_ticks := 0
	var completion_incremental := true
	while city.far_staged_block_count() < Plan.GRID_SIZE * Plan.GRID_SIZE and completion_ticks < Plan.GRID_SIZE * Plan.GRID_SIZE:
		city._process(1.0 / 60.0)
		completion_incremental = completion_incremental and city.last_far_staged_this_tick() <= 1
		completion_ticks += 1
	_check(completion_incremental and completion_ticks <= Plan.GRID_SIZE * Plan.GRID_SIZE, "full far city remains staged at one block per tick")
	_check(city.far_staged_block_count() == Plan.GRID_SIZE * Plan.GRID_SIZE and city.far_visible_instance_count() == Plan.ESTIMATED_BUILDING_COUNT, "far LOD completes all blocks and exact building slots")
	detailed_blocks_hidden = true
	for key in city.loaded_block_keys():
		detailed_blocks_hidden = detailed_blocks_hidden and not city.far_block_has_silhouette(key)
	_check(detailed_blocks_hidden, "completed far city keeps current detailed blocks hidden")

	city.update_focus(Vector3(Plan.MAX_X - 1.0, Plan.GROUND_Y, Plan.MAX_Z - 1.0))
	for tick in range(25):
		city._process(1.0 / 60.0)
	_check(city.visible_block_count() <= 25, "edge teleport preserves visible block cap")
	_check(city.collision_shape_count() <= 3 + 9 * Plan.LOTS_PER_BLOCK * 2, "edge collision remains bounded")
	city.update_focus(Vector3.ZERO)
	_check(city.visible_block_count() == 0 and city.queued_block_count() == 0, "village focus releases all city blocks")
	host.free()


func _count_nodes(node: Node) -> int:
	var total := 1
	for child in node.get_children():
		total += _count_nodes(child)
	return total


func _shelter_clear_of(shelter: Vector3, building: Dictionary) -> bool:
	var position: Vector3 = building.position
	var size: Vector3 = building.size
	return not (
		absf(shelter.x - position.x) < size.x * 0.5 + 4.0
		and absf(shelter.z - position.z) < size.z * 0.5 + 2.3
	)


func _setback_collisions_match(node: Node) -> bool:
	var found_upper := false
	for body in node.find_children("*", "StaticBody3D", true, false):
		for child in body.get_children():
			if not child is CollisionShape3D or not child.name.ends_with("_Upper"):
				continue
			found_upper = true
			var podium_name := child.name.trim_suffix("_Upper") + "_Podium"
			var podium := body.get_node_or_null(NodePath(podium_name)) as CollisionShape3D
			if podium == null or not child.shape is BoxShape3D or not podium.shape is BoxShape3D:
				return false
			var upper_size: Vector3 = child.shape.size
			var podium_size: Vector3 = podium.shape.size
			if upper_size.x >= podium_size.x or upper_size.z >= podium_size.z:
				return false
	return found_upper


func _largest_horizontal_instance(node: Node) -> float:
	var largest := 0.0
	if node is MultiMeshInstance3D:
		var multimesh: MultiMesh = node.multimesh
		for index in range(multimesh.instance_count):
			var scale := multimesh.get_instance_transform(index).basis.get_scale().abs()
			largest = maxf(largest, maxf(scale.x, scale.z))
	for child in node.get_children():
		largest = maxf(largest, _largest_horizontal_instance(child))
	return largest


func _segment_rect_distance(segment_from: Vector2, segment_to: Vector2, center: Vector2, half_size: Vector2) -> float:
	if _point_rect_distance(segment_from, center, half_size) <= 0.0 or _point_rect_distance(segment_to, center, half_size) <= 0.0:
		return 0.0
	var corners := [
		center + Vector2(-half_size.x, -half_size.y),
		center + Vector2(half_size.x, -half_size.y),
		center + Vector2(half_size.x, half_size.y),
		center + Vector2(-half_size.x, half_size.y),
	]
	var closest := INF
	for index in range(corners.size()):
		var edge_from: Vector2 = corners[index]
		var edge_to: Vector2 = corners[(index + 1) % corners.size()]
		if Geometry2D.segment_intersects_segment(segment_from, segment_to, edge_from, edge_to) != null:
			return 0.0
		closest = minf(closest, Geometry2D.get_closest_point_to_segment(edge_from, segment_from, segment_to).distance_to(edge_from))
	closest = minf(closest, _point_rect_distance(segment_from, center, half_size))
	closest = minf(closest, _point_rect_distance(segment_to, center, half_size))
	return closest


func _point_rect_distance(point: Vector2, center: Vector2, half_size: Vector2) -> float:
	var offset := (point - center).abs() - half_size
	return Vector2(maxf(offset.x, 0.0), maxf(offset.y, 0.0)).length()


func _segment_distance(first_from: Vector2, first_to: Vector2, second_from: Vector2, second_to: Vector2) -> float:
	if Geometry2D.segment_intersects_segment(first_from, first_to, second_from, second_to) != null:
		return 0.0
	var closest := Geometry2D.get_closest_point_to_segment(first_from, second_from, second_to).distance_to(first_from)
	closest = minf(closest, Geometry2D.get_closest_point_to_segment(first_to, second_from, second_to).distance_to(first_to))
	closest = minf(closest, Geometry2D.get_closest_point_to_segment(second_from, first_from, first_to).distance_to(second_from))
	closest = minf(closest, Geometry2D.get_closest_point_to_segment(second_to, first_from, first_to).distance_to(second_to))
	return closest


func _check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		passed += 1
	else:
		push_error("CITYPLANTEST failed: %s" % label)
