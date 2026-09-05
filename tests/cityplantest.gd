extends Node

const Plan = preload("res://scripts/city_plan.gd")
const World = preload("res://scripts/city_world.gd")
const Routes = preload("res://scripts/frontier_routes.gd")
const TownLayout = preload("res://scripts/frontier_town_layout.gd")
const Landscape = preload("res://scripts/city_park.gd")
const ParkLayout = preload("res://scripts/city_park_layout.gd")
const Terrain = preload("res://scripts/city_terrain.gd")

var checks := 0
var passed := 0
var expected_far_sections := 0


func run() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_constants_and_districts()
	_test_complete_deterministic_census()
	_test_street_hierarchy()
	_test_park_layout_and_basin()
	_test_public_lookup_boundaries()
	_test_services_housing_and_stops()
	_test_village_property_clearance()
	_test_streaming_budget()
	print("CITYPLANTEST %d/%d PASS" % [passed, checks])
	get_tree().quit(0 if passed == checks else 1)


func _test_constants_and_districts() -> void:
	_check(Plan.CENTER == Vector2(14400.0, 0.0), "city center is exact")
	_check(Plan.GRID_WIDTH == 52 and Plan.GRID_DEPTH == 48 and (Plan.STREET_SPACING - Vector2.ONE*24).is_equal_approx(Vector2(264,900)*.3048), "52 by 48 blocks have exact 264 by 900 foot interiors and 24 metre streets")
	_check(is_equal_approx(Plan.MAX_X - Plan.MIN_X, 52*(264*.3048+24)), "east-west footprint derives from all 52 rectangular blocks")
	_check(is_equal_approx(Plan.MAX_Z - Plan.MIN_Z, 48*(900*.3048+24)), "north-south footprint derives from all 48 rectangular blocks")
	var measured_square_miles := (Plan.MAX_X - Plan.MIN_X) * (Plan.MAX_Z - Plan.MIN_Z) / pow(1609.344, 2.0)
	_check(absf(measured_square_miles - 30.0) < 0.2 and is_equal_approx(Plan.SQUARE_MILES, measured_square_miles), "geometry and displayed area agree at approximately 30 square miles")
	_check(is_equal_approx(Plan.GROUND_Y, 8.0), "city shares terrain ground height")
	_check(Plan.contains(Vector2(Plan.MIN_X, Plan.MIN_Z)), "minimum bound is included")
	_check(Plan.contains(Vector2(Plan.MAX_X, Plan.MAX_Z)), "maximum bound is included")
	_check(not Plan.contains(Vector2(Plan.MIN_X - 0.01, 0.0)), "outside point is excluded")
	_check(Plan.world_to_block(Vector2(Plan.MIN_X, Plan.MIN_Z)) == Vector2i.ZERO, "minimum maps to first block")
	_check(Plan.world_to_block(Vector2(Plan.MAX_X, Plan.MAX_Z)) == Vector2i(51, 47), "maximum maps to last block")

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
	var all_street_corridors_clear := true
	var all_door_approaches_clear := true
	var tall_towers := 0
	var tallest := 0.0
	var core_height_total := 0.0
	var core_count := 0
	var edge_height_total := 0.0
	var edge_count := 0
	var represented_kinds: Dictionary = {}
	var represented_services: Dictionary = {}
	for y in range(Plan.GRID_DEPTH):
		for x in range(Plan.GRID_WIDTH):
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
				expected_far_sections += 4 if size.y >= 36.0 else 1
				var door: Vector3 = record.door
				tallest = maxf(tallest, size.y)
				if size.y >= 250.0:
					tall_towers += 1
				if x >= 20 and x <= 29 and y >= 18 and y <= 27:
					core_height_total += size.y
					core_count += 1
				if x < 4 or y < 4 or x >= 44 or y >= 44:
					edge_height_total += size.y
					edge_count += 1
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
				var offset := Vector2(position.x, position.z) - Plan.block_center(key)
				all_lots_aligned = all_lots_aligned and offset.is_equal_approx(Plan.lot_center_offset(key,record.lot))
				var relative := Vector2(position.x - Plan.MIN_X, position.z - Plan.MIN_Z)
				for axis in range(2):
					var half_size := (size.x if axis == 0 else size.z) * 0.5
					var spacing:float=Plan.STREET_SPACING[axis]
					var clearance:=absf(fposmod(relative[axis]+spacing*.5,spacing)-spacing*.5)-half_size
					all_street_corridors_clear=all_street_corridors_clear and clearance>=Plan.MAJOR_ROAD_HALF_WIDTH+Plan.SIDEWALK_WIDTH-.01
				var door_point := Vector2(door.x, door.z)
				var approach := (door_point - Vector2(position.x, position.z)).normalized() * 1.0
				for neighbor in records:
					var neighbor_center := Vector2(neighbor.position.x, neighbor.position.z)
					var neighbor_half := Vector2(neighbor.size.x, neighbor.size.z) * 0.5
					all_door_approaches_clear = all_door_approaches_clear and _segment_rect_distance(door_point, door_point + approach, neighbor_center, neighbor_half) >= 1.49
				if not String(record.housing).is_empty():
					var residence: Vector3 = record.residence
					all_records_valid = all_records_valid and residence.y > Plan.GROUND_Y + 3.0
					all_housing_purchasable = all_housing_purchasable and bool(record.purchasable)
					all_records_valid = all_records_valid and not Plan.housing_tier(record.housing).is_empty()
			_check(block_residents == Plan.block_population(key), "block %d,%d census allocation" % [x, y])
	_check(building_total == Plan.ESTIMATED_BUILDING_COUNT, "expected conceptual building count")
	_check(ids.size() == building_total and all_ids_unique, "public building IDs are globally unique")
	_check(resident_total == Plan.RESIDENT_TARGET and resident_total == 100000, "aggregate population is exactly 100,000")
	_check(all_records_valid, "every building has a valid door and property or service role")
	_check(all_lots_aligned, "every physical parcel matches the canonical two-row rectangular block layout")
	_check(all_street_corridors_clear, "every building leaves full local and arterial carriageways and sidewalks clear")
	_check(all_door_approaches_clear, "all building doors and short approaches leave 1.5 metres of facade clearance")
	_check(tallest >= 600.0 and tallest <= 650.0 and tall_towers >= 5 and tall_towers < 100, "rare landmark towers punctuate predominantly low and mid-rise city")
	_check(core_height_total / core_count > edge_height_total / edge_count * 1.4, "downtown massing is clustered above the varied outer neighborhoods")
	print("CITY_CENSUS area_sqmi=%.3f buildings=%d residents=%d towers_250m=%d tallest_m=%.1f" % [Plan.SQUARE_MILES, building_total, resident_total, tall_towers, tallest])
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


func _test_street_hierarchy() -> void:
	var origin:=Plan.block_center(Vector2i(5,5))-Plan.STREET_SPACING*.5
	var base:=Color.WHITE
	_check(Terrain.color(origin+Vector2(11.5,25),base)==Color("343c43"),"every city street has a full 24 metre carriageway")
	_check(Terrain.color(origin+Vector2(13.5,25),base)==Color("b1ada0"),"sidewalks sit outside the real traffic lanes")
	_check(Terrain.color(origin+Plan.STREET_SPACING*.5,base)==Color("92928a"),"block interior is a rear court rather than a phantom internal street")
	_check(is_equal_approx(Terrain.grade(origin,987),Plan.GROUND_Y),"city intersections retain exact physical grade")
	_check(is_equal_approx(Terrain.grade(Vector2(Plan.MIN_X,0),-25),Plan.GROUND_Y),"western access joins the city without a height step")

func _test_park_layout_and_basin() -> void:
	var park_blocks:=0
	var relocated_ids:Dictionary={}
	var preserved:=true
	for y in range(Plan.PARK_MIN_BLOCK.y,Plan.PARK_MAX_BLOCK.y+1):
		for x in range(Plan.PARK_MIN_BLOCK.x,Plan.PARK_MAX_BLOCK.x+1):
			var key:=Vector2i(x,y);park_blocks+=1
			preserved=preserved and Plan.block_buildings(key).is_empty()
			for lot in range(16):
				var id:="crownreach-b%02d-%02d-l%02d"%[x,y,lot]
				var building:=Plan.building(id)
				preserved=preserved and not building.is_empty() and building.block==Plan.relocated_block(key) and not Plan.is_park_block(building.block)
				if not building.is_empty():preserved=preserved and not str(building.service).is_empty() and Terrain.grade(Vector2(building.position.x,building.position.z),-99)==Plan.GROUND_Y
				relocated_ids[id]=true
	_check(park_blocks==104 and Plan.is_park(Plan.PARK_CENTER),"park occupies 104 contiguous city blocks")
	_check(preserved and relocated_ids.size()==1664,"all 1664 displaced addresses retain lookup, dry foundations and service roles in the eastern neighborhoods")
	_check(Terrain.color(Plan.PARK_CENTER+Vector2(0,-900),Color.WHITE)==Color("577d43"),"Great Lawn is landscaped instead of a former street")
	var shoreline_inside:=true
	var shores_safe:=true
	var peak_slope:=0.0
	for i in range(64):
		var angle:=TAU*float(i)/64
		var previous:=Plan.POND_CENTER
		var previous_height:=Terrain.grade(previous,0)
		for step in range(1,33):
			var point:=Plan.pond_shore(angle,float(step)/32)
			var height:=Terrain.grade(point,0)
			peak_slope=maxf(peak_slope,absf(height-previous_height)/point.distance_to(previous))
			shores_safe=shores_safe and height>=previous_height-.001 and height<=Plan.GROUND_Y
			previous=point;previous_height=height
		shores_safe=shores_safe and is_equal_approx(previous_height,Plan.GROUND_Y)
		shoreline_inside=shoreline_inside and Plan.is_park(previous)
	_check(shoreline_inside,"entire irregular lake and dry bank fit within the large park")
	_check(is_equal_approx(Plan.pond_depth(Plan.POND_CENTER),1.6) and is_equal_approx(Terrain.grade(Plan.POND_CENTER,123),Plan.GROUND_Y-1.6),"all terrain levels share the exact 1.6 metre boating basin")
	_check(Plan.POND_SURFACE_Y>Plan.GROUND_Y-Plan.POND_DEPTH and Plan.POND_SURFACE_Y<Plan.GROUND_Y,"lake water remains inside its physical basin")
	_check(shores_safe and peak_slope<.23,"all irregular banks rise continuously to dry land below 23 percent grade")


func _test_public_lookup_boundaries() -> void:
	var malformed := [
		"", "crownreach-b-1-00-l00", "crownreach-b00-00-l-1",
		"crownreach-b52-00-l00", "crownreach-b00-48-l00",
		"crownreach-b00-00-l16", "crownreach-b0-00-l00",
		"crownreach-b23-23-l15", "../crownreach-b00-00-l00",
	]
	for id in malformed:
		_check(Plan.building(id).is_empty(), "malformed or reserved ID rejected: %s" % id)
	_check(Plan.block_buildings(Vector2i(-1, 0)).is_empty(), "negative block rejected")
	_check(Plan.block_buildings(Vector2i(52, 0)).is_empty(), "oversized block rejected")

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
	_check(stops.size() == 23 and stop_ids.size() == 23, "village, square, garden, district, and job stops exposed")
	_check(stops[0].position == Vector3(-60.0, 3.25, 55.0), "origin village bus anchor exact")
	_check(stops[1].position == Vector3(14400.0, 8.0, 0.0), "Lantern Square stop anchor exact")
	var garden_arrival := Vector2(Plan.PARK_CENTER.x+Plan.PARK_HALF_EXTENTS.x+14,Plan.POND_CENTER.y)
	var garden_entry := Vector2(Plan.PARK_CENTER.x+Plan.PARK_HALF_EXTENTS.x-1,Plan.POND_CENTER.y)
	_check(stops[2].id == "lantern_gardens" and Vector2(stops[2].position.x, stops[2].position.z) == garden_arrival, "Lantern Gardens is directly reachable through the transit guide")
	var garden_approach_clear := true
	for record in Plan.block_buildings(Plan.PARK_BLOCK):
		garden_approach_clear = garden_approach_clear and _segment_rect_distance(garden_arrival, garden_entry, Vector2(record.position.x, record.position.z), Vector2(record.size.x, record.size.z) * 0.5) > 3.0
	_check(garden_approach_clear, "garden transit arrival connects to the park through a clear pedestrian entrance")
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
	_check(city.render_batch_count() <= 8, "village, far buildings and full municipal streets use bounded batches")
	_check(city._far_road_surface.mesh.size.is_equal_approx(Plan.STREET_SPACING*Vector2(Plan.GRID_WIDTH,Plan.GRID_DEPTH)) and city._far_road_surface.get_child_count() == 0, "distant roads use exact municipal dimensions and add no substitute terrain collision")
	_check(city.collision_shape_count() == 3, "canonical properties use three bounded collisions")
	var initial_stats: Dictionary = city.stats()
	_check(int(initial_stats.far_lod_batches) == 1 and int(initial_stats.far_lod_instances) == 0, "far LOD allocates one empty staged batch")
	_check(int(initial_stats.far_lod_capacity) == Plan.ESTIMATED_BUILDING_COUNT * World.MAX_SECTIONS_PER_BUILDING and int(initial_stats.far_lod_colliders) == 0, "far LOD has bounded four-section capacity and no colliders")
	var far_bounds := city.far_lod_bounds()
	_check(far_bounds.position == Vector3(Plan.MIN_X, Plan.GROUND_Y, Plan.MIN_Z) and is_equal_approx(far_bounds.size.x, Plan.MAX_X-Plan.MIN_X) and is_equal_approx(far_bounds.size.z, Plan.MAX_Z-Plan.MIN_Z) and far_bounds.size.y >= 650.0, "far LOD bounds cover the complete footprint and supertall roofs")
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
	var park_root:=Node3D.new();host.add_child(park_root)
	park_root.position=Vector3(Plan.PARK_CENTER.x,0,Plan.PARK_CENTER.y)
	Landscape._ground(park_root);Landscape._water(park_root)
	var park_ground:MeshInstance3D=park_root.get_node("LanternGardensGround")
	var pond_surface:MeshInstance3D=park_root.get_node("LanternLakeWater")
	_check(park_ground.mesh!=null and pond_surface.mesh!=null,"persistent landscape helper creates one actual ground and lake mesh independent of city streaming")
	_check(is_equal_approx(park_ground.mesh.get_aabb().position.y,Plan.GROUND_Y-Plan.POND_DEPTH+.025) and is_equal_approx(pond_surface.mesh.get_aabb().position.y,Plan.POND_SURFACE_Y),"rendered natural lake and ground agree with the physical basin")
	_check(city.far_staged_block_count() == 25 and city.far_visible_instance_count() > 0 and city.far_visible_instance_count() <= 25 * Plan.LOTS_PER_BLOCK * World.MAX_SECTIONS_PER_BUILDING, "far skyline fills bounded architecture sections one block per tick outside detailed ring")
	var detailed_blocks_hidden := true
	for key in city.loaded_block_keys():
		detailed_blocks_hidden = detailed_blocks_hidden and not city.far_block_has_silhouette(key)
	_check(detailed_blocks_hidden, "far silhouettes never overlap detailed blocks")
	_check(city.collision_shape_count() <= 3 + 9 * Plan.LOTS_PER_BLOCK * World.MAX_SECTIONS_PER_BUILDING, "detailed collision stays within near-block budget")
	_check(_setback_collisions_match(city), "setback towers use inset upper colliders without invisible walls")
	_check(city.render_batch_count() <= 7 + 11 * 25 + 3, "facades and street details remain bounded with three additional park batches")
	_check(_count_nodes(city) < 1000, "streamed node count stays bounded despite multi-section towers")
	_check(_largest_horizontal_instance(city) < Plan.STREET_SPACING.y, "renderer contains no city-sized ground plane")
	var completion_ticks := 0
	var completion_incremental := true
	while city.far_staged_block_count() < Plan.TOTAL_BLOCKS and completion_ticks < Plan.TOTAL_BLOCKS:
		city._process(1.0 / 60.0)
		completion_incremental = completion_incremental and city.last_far_staged_this_tick() <= 1
		completion_ticks += 1
	_check(completion_incremental and completion_ticks <= Plan.TOTAL_BLOCKS, "full far city remains staged at one block per tick")
	_check(city.far_staged_block_count() == Plan.TOTAL_BLOCKS and city.far_visible_instance_count() == expected_far_sections, "far LOD completes all blocks with every expected low-rise and tower section")
	detailed_blocks_hidden = true
	for key in city.loaded_block_keys():
		detailed_blocks_hidden = detailed_blocks_hidden and not city.far_block_has_silhouette(key)
	_check(detailed_blocks_hidden, "completed far city keeps current detailed blocks hidden")

	city.update_focus(Vector3(Plan.MAX_X - 1.0, Plan.GROUND_Y, Plan.MAX_Z - 1.0))
	for tick in range(25):
		city._process(1.0 / 60.0)
	_check(city.visible_block_count() <= 25, "edge teleport preserves visible block cap")
	_check(city.collision_shape_count() <= 3 + 9 * Plan.LOTS_PER_BLOCK * World.MAX_SECTIONS_PER_BUILDING, "edge collision remains bounded")
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


func _setback_collisions_match(city: Node) -> bool:
	var found_tower := false
	for entry in city._loaded_blocks.values():
		var body: StaticBody3D = entry.get("collision_body")
		if not is_instance_valid(body):
			continue
		for record in entry.records:
			var sections: Array[Dictionary] = city._building_sections(record)
			var collision_prefix := "Building_%s_Section" % String(record.id).replace("-", "_")
			var last_top := 0.0
			for section_index in range(sections.size()):
				var section: Dictionary = sections[section_index]
				var child := body.get_node_or_null(NodePath(collision_prefix + str(section_index))) as CollisionShape3D
				if child == null or not child.shape is BoxShape3D:
					return false
				var size: Vector3 = child.shape.size
				if not size.is_equal_approx(section.size) or not child.global_position.is_equal_approx(record.position + section.offset):
					return false
				if size.x > record.size.x or size.z > record.size.z:
					return false
				if not is_equal_approx(section.offset.y - size.y * 0.5, last_top):
					return false
				last_top = section.offset.y + size.y * 0.5
			if not is_equal_approx(last_top, record.size.y):
				return false
			found_tower = found_tower or sections.size() == 4
	return found_tower


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
