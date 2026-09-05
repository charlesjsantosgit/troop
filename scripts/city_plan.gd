class_name CityPlan
extends RefCounted

## Crownreach's deterministic, allocation-free city plan.  The plan describes
## buildings as value records so gameplay systems never need the streamed
## renderer to be present.

const CENTER := Vector2(14400.0, 0.0)
# Curb-to-curb blocks follow the requested 264 x 900 feet; streets add 24m.
const GRID_WIDTH := 52
const GRID_DEPTH := 48
const GRID_SIZE := GRID_DEPTH # Legacy save identifiers retain their original range.
const BLOCK_EXTENTS := Vector2(104.4672, 298.32)
const STREET_SPACING := BLOCK_EXTENTS
const BLOCK_SIZE := 184.0 # Legacy callers must not use this for geometry.
const LOT_SPACING := 46.0 # Legacy migration only.
const TOTAL_BLOCKS := GRID_WIDTH * GRID_DEPTH
const HALF_EXTENT := 7159.68
const MIN_X := CENTER.x - 24.0 * BLOCK_EXTENTS.x
const MAX_X := MIN_X + GRID_WIDTH * BLOCK_EXTENTS.x
const MIN_Z := CENTER.y - 24.0 * BLOCK_EXTENTS.y
const MAX_Z := MIN_Z + GRID_DEPTH * BLOCK_EXTENTS.y
const MAJOR_ROAD_HALF_WIDTH := 12.0
const LOCAL_ROAD_HALF_WIDTH := 12.0
const SIDEWALK_WIDTH := 3.0
const PLAZA_HALF_EXTENT := 18.0
const GROUND_Y := 8.0
const PARK_MIN_BLOCK := Vector2i(13, 18)
const PARK_MAX_BLOCK := Vector2i(20, 30)
const PARK_BLOCK := Vector2i(17, 24)
const PARK_CENTER := Vector2(MIN_X + 17.0 * BLOCK_EXTENTS.x, MIN_Z + 24.5 * BLOCK_EXTENTS.y)
const PARK_HALF_EXTENTS := Vector2(4.0 * BLOCK_EXTENTS.x - 14.0, 6.5 * BLOCK_EXTENTS.y - 14.0)
const PARK_HALF_SIZE := 52.0 # Legacy test compatibility; use PARK_HALF_EXTENTS.
const PARK_BLOCK_COUNT := 104
const POND_CENTER := PARK_CENTER + Vector2(20.0, 300.0)
const POND_RADII := Vector2(165.0, 360.0)
const POND_DEPTH := 1.6
const POND_SURFACE_Y := GROUND_Y - 0.12
const POND_WATER_Q := 0.9245013248
const RESIDENT_TARGET := 100000
const LOTS_PER_BLOCK := 16
const RESIDENTIAL_BLOCKS := TOTAL_BLOCKS - PARK_BLOCK_COUNT
const ESTIMATED_BUILDING_COUNT := RESIDENTIAL_BLOCKS * LOTS_PER_BLOCK - 3
const SQUARE_MILES := (GRID_WIDTH * BLOCK_EXTENTS.x) * (GRID_DEPTH * BLOCK_EXTENTS.y) / (1609.344 * 1609.344)

const _DISTRICT_NAMES: Array[String] = [
	"Westgate Trades", "Orchard Ward", "Northlight Campus", "Dynamo Yards",
	"Foundry Reach", "Garden Rows", "Lantern Core", "East Market",
	"South Depot", "Brickwater Homes", "Clinic Heights", "Railworks",
]
const _DISTRICT_KINDS: Array[String] = [
	"craft", "produce", "learning", "utilities",
	"industry", "residential", "civic", "food",
	"logistics", "residential", "health", "transit",
]
const _DISTRICT_COLORS: Array[Color] = [
	Color("8f6452"), Color("789653"), Color("618ca8"), Color("a88748"),
	Color("786f6a"), Color("8c805f"), Color("c7873d"), Color("a85e51"),
	Color("6f7b83"), Color("88749a"), Color("6f9b8f"), Color("756f91"),
]

const _PURCHASABLE: Array[Dictionary] = [
	{"tier": "cottage", "building_id": "village-cottage"},
	{"tier": "town_apartment", "building_id": "town-apartments"},
	{"tier": "suburban_home", "building_id": "suburban-home"},
	{"tier": "city_apartment", "building_id": "crownreach-b24-24-l01"},
	{"tier": "penthouse", "building_id": "crownreach-b24-24-l02"},
	{"tier": "warehouse", "building_id": "crownreach-b04-08-l03"},
]

const _SERVICE_SPECS: Array[Dictionary] = [
	{"id": "courier_depot", "name": "Westgate Courier Depot", "kind": "courier_depot", "building_id": "crownreach-b00-24-l00"},
	{"id": "courier_delivery_lantern", "name": "Lantern Delivery", "kind": "courier_delivery", "building_id": "crownreach-b24-24-l01"},
	{"id": "courier_delivery_clinic", "name": "Northlight Delivery", "kind": "courier_delivery", "building_id": "crownreach-b31-08-l05"},
	{"id": "courier_delivery_rail", "name": "Railworks Delivery", "kind": "courier_delivery", "building_id": "crownreach-b40-40-l10"},
	{"id": "maintenance_depot", "name": "Westgate Maintenance Shop", "kind": "maintenance_depot", "building_id": "crownreach-b00-23-l12"},
	{"id": "maintenance_site_lantern", "name": "Lantern Lightworks", "kind": "maintenance_site", "building_id": "crownreach-b23-23-l14"},
	{"id": "maintenance_site_north", "name": "Northlight Heating Plant", "kind": "maintenance_site", "building_id": "crownreach-b18-08-l09"},
	{"id": "maintenance_site_east", "name": "East Market Waterworks", "kind": "maintenance_site", "building_id": "crownreach-b40-24-l06"},
	{"id": "produce_exchange", "name": "Lantern Produce Exchange", "kind": "produce_exchange", "building_id": "crownreach-b24-24-l00"},
	{"id": "produce_market", "name": "Garden Row Produce Market", "kind": "produce_market", "building_id": "crownreach-b12-24-l00"},
	{"id": "home_office", "name": "Cottage Home Office", "kind": "home_office", "building_id": "village-cottage"},
]

const _SERVICE_STOP_SPECS: Array[Dictionary] = [
	{"id": "westgate_jobs", "name": "Westgate Jobs", "building_id": "crownreach-b00-24-l00"},
	{"id": "lantern_east", "name": "Lantern House", "building_id": "crownreach-b24-24-l01"},
	{"id": "lantern_lightworks", "name": "Lantern Lightworks", "building_id": "crownreach-b23-23-l14"},
	{"id": "northlight_delivery", "name": "Northlight Delivery", "building_id": "crownreach-b31-08-l05"},
	{"id": "railworks_delivery", "name": "Railworks Delivery", "building_id": "crownreach-b40-40-l10"},
	{"id": "north_maintenance", "name": "North Maintenance", "building_id": "crownreach-b18-08-l09"},
	{"id": "east_maintenance", "name": "East Maintenance", "building_id": "crownreach-b40-24-l06"},
	{"id": "garden_produce", "name": "Garden Produce Market", "building_id": "crownreach-b12-24-l00"},
]


static func contains(point: Vector2) -> bool:
	# Positions are float32 Vector2 values; compare both sides in that same
	# representation so the advertised municipal corners remain inside the city.
	var lower:=Vector2(MIN_X,MIN_Z)
	var upper:=Vector2(MAX_X,MAX_Z)
	return point.x>=lower.x and point.x<=upper.x and point.y>=lower.y and point.y<=upper.y


static func valid_block(key: Vector2i) -> bool:
	return key.x >= 0 and key.y >= 0 and key.x < GRID_WIDTH and key.y < GRID_DEPTH


static func is_park_block(key: Vector2i) -> bool:
	return key.x >= PARK_MIN_BLOCK.x and key.x <= PARK_MAX_BLOCK.x and key.y >= PARK_MIN_BLOCK.y and key.y <= PARK_MAX_BLOCK.y


static func is_park(point: Vector2) -> bool:
	var delta := (point - PARK_CENTER).abs()
	return delta.x < PARK_HALF_EXTENTS.x and delta.y < PARK_HALF_EXTENTS.y


static func lot_center_offset(key: Vector2i, lot_index: int) -> Vector2:
	if not valid_block(key) or lot_index < 0 or lot_index >= LOTS_PER_BLOCK:
		return Vector2.INF
	# Two continuous street walls, each with eight varied buildings; rear courts
	# replace the previous internal road lattice. Every door faces a real street.
	return Vector2((-1.0 if lot_index % 2 == 0 else 1.0) * 21.0,
		-118.5 + float(lot_index / 2) * (237.0 / 7.0))


static func pond_q(point: Vector2) -> float:
	var offset := (point - POND_CENTER) / POND_RADII
	var angle := offset.angle()
	var shore := 1.0 + 0.10 * sin(3.0 * angle + 0.4) + 0.055 * cos(5.0 * angle - 0.6)
	return offset.length() / shore


static func pond_shore(angle: float, q: float = POND_WATER_Q) -> Vector2:
	var shore := 1.0 + 0.10 * sin(3.0 * angle + 0.4) + 0.055 * cos(5.0 * angle - 0.6)
	return POND_CENTER + Vector2(cos(angle), sin(angle)) * POND_RADII * shore * q


static func pond_depth(point: Vector2) -> float:
	var offset := (point - POND_CENTER).abs()
	if offset.x >= POND_RADII.x * 1.155 or offset.y >= POND_RADII.y * 1.155:
		return 0.0
	return POND_DEPTH * (1.0 - smoothstep(0.55, 1.0, pond_q(point)))


static func relocated_block(key: Vector2i) -> Vector2i:
	if not is_park_block(key): return key
	var index := (key.y - PARK_MIN_BLOCK.y) * 8 + key.x - PARK_MIN_BLOCK.x
	return Vector2i(48 + index % 4, index / 4)


static func address_block(physical: Vector2i) -> Vector2i:
	# Addresses displaced by the park occupy the new eastern neighborhoods.
	# Existing saved owners/storage retain their IDs and their actual front door.
	if physical.x >= 48 and physical.y < 26:
		var index := physical.y * 4 + physical.x - 48
		return Vector2i(PARK_MIN_BLOCK.x + index % 8, PARK_MIN_BLOCK.y + index / 8)
	return physical


static func block_center(key: Vector2i) -> Vector2:
	if not valid_block(key):
		return Vector2.INF
	return Vector2(
		MIN_X + (float(key.x) + 0.5) * BLOCK_EXTENTS.x,
		MIN_Z + (float(key.y) + 0.5) * BLOCK_EXTENTS.y
	)


static func world_to_block(point: Vector2) -> Vector2i:
	if not contains(point):
		return Vector2i(-1, -1)
	return Vector2i(
		clampi(floori((point.x - MIN_X) / BLOCK_EXTENTS.x), 0, GRID_WIDTH - 1),
		clampi(floori((point.y - MIN_Z) / BLOCK_EXTENTS.y), 0, GRID_DEPTH - 1)
	)


static func district_for_block(key: Vector2i) -> int:
	if not valid_block(key):
		return -1
	var column := mini(key.x / 13, 3)
	var row := mini(key.y / 16, 2)
	return row * 4 + column


static func district_catalog() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for district in range(12):
		var column := district % 4
		var row := district / 4
		var center := Vector2(
			MIN_X + (float(column * 13) + 6.5) * BLOCK_EXTENTS.x,
			MIN_Z + (float(row * 16) + 8.0) * BLOCK_EXTENTS.y
		)
		result.append({
			"id": district,
			"slug": _DISTRICT_NAMES[district].to_lower().replace(" ", "_"),
			"name": _DISTRICT_NAMES[district],
			"kind": _DISTRICT_KINDS[district],
			"center": Vector3(center.x, GROUND_Y, center.y),
			"color": _DISTRICT_COLORS[district],
		})
	return result


static func district(id: int) -> Dictionary:
	if id < 0 or id >= 12:
		return {}
	return district_catalog()[id]


static func block_population(key: Vector2i) -> int:
	if not valid_block(key) or is_park_block(key): return 0
	var index := key.y * GRID_WIDTH + key.x
	var earlier_park_rows := clampi(key.y - PARK_MIN_BLOCK.y, 0, 13)
	index -= earlier_park_rows * 8
	if key.y >= PARK_MIN_BLOCK.y and key.y <= PARK_MAX_BLOCK.y:
		index -= clampi(key.x - PARK_MIN_BLOCK.x, 0, 8)
	return RESIDENT_TARGET / RESIDENTIAL_BLOCKS + (1 if index < RESIDENT_TARGET % RESIDENTIAL_BLOCKS else 0)


static func block_buildings(key: Vector2i) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not valid_block(key) or is_park_block(key):
		return result
	var district_id := district_for_block(key)
	for lot_index in range(LOTS_PER_BLOCK):
		if _is_reserved_square_lot(key, lot_index):
			continue
		result.append(_make_building(key, lot_index, district_id))

	var housing_indices: Array[int] = []
	for index in range(result.size()):
		if not String(result[index].get("housing", "")).is_empty():
			housing_indices.append(index)
	var population := block_population(key)
	if not housing_indices.is_empty():
		var per_building := population / housing_indices.size()
		var remainder := population % housing_indices.size()
		for order in range(housing_indices.size()):
			var index := housing_indices[order]
			var residents := per_building + (1 if order < remainder else 0)
			result[index]["residents"] = residents
			result[index]["capacity"] = maxi(
				residents + 4,
				int(result[index]["floors"]) * 18
			)
	return result


static func building(id: String) -> Dictionary:
	var village := _village_building(id)
	if not village.is_empty():
		return village
	if not id.begins_with("crownreach-b"):
		return {}
	var pieces := id.trim_prefix("crownreach-b").split("-", false)
	if pieces.size() != 3 or not String(pieces[2]).begins_with("l"):
		return {}
	var x_text := String(pieces[0])
	var y_text := String(pieces[1])
	var lot_text := String(pieces[2]).trim_prefix("l")
	if not x_text.is_valid_int() or not y_text.is_valid_int() or not lot_text.is_valid_int():
		return {}
	var key := Vector2i(x_text.to_int(), y_text.to_int())
	var lot_index := lot_text.to_int()
	if not valid_block(key) or lot_index < 0 or lot_index >= LOTS_PER_BLOCK:
		return {}
	if _city_building_id(key, lot_index) != id or _is_reserved_square_lot(key, lot_index):
		return {}
	for candidate in block_buildings(relocated_block(key)):
		if candidate.id == id:
			return candidate
	return {}


static func canonical_properties() -> Array[Dictionary]:
	return [
		_village_building("village-cottage"),
		_village_building("town-apartments"),
		_village_building("suburban-home"),
	]


static func housing_catalog() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for spec in _PURCHASABLE:
		var record := building(String(spec.building_id))
		if record.is_empty():
			continue
		result.append({
			"tier": String(spec.tier),
			"building_id": String(spec.building_id),
			"name": String(record.name),
			"position": record.door,
		})
	return result


static func purchasable_housing_ids() -> Array[String]:
	var result: Array[String] = []
	for spec in _PURCHASABLE:
		result.append(String(spec.building_id))
	return result


static func housing_tier(value: String) -> String:
	match value:
		"cottage", "town_apartment", "suburban_home", "city_apartment", "penthouse", "warehouse":
			return value
		"work_live", "staff_residence":
			return "city_apartment"
		"town_house":
			return "suburban_home"
	return ""


static func services() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for spec in _SERVICE_SPECS:
		var record := building(String(spec.building_id))
		if record.is_empty():
			continue
		result.append({
			"id": String(spec.id),
			"name": String(spec.name),
			"kind": String(spec.kind),
			"building_id": String(spec.building_id),
			"position": record.door,
			"district": int(record.district),
		})
	return result


static func service(id: String) -> Dictionary:
	for spec in _SERVICE_SPECS:
		if spec.id != id:
			continue
		var record := building(String(spec.building_id))
		if record.is_empty():
			return {}
		return {
			"id": String(spec.id),
			"name": String(spec.name),
			"kind": String(spec.kind),
			"building_id": String(spec.building_id),
			"position": record.door,
			"district": int(record.district),
		}
	return {}


static func blocks_near(point: Vector3, radius_blocks: int = 2) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var radius := clampi(radius_blocks, 0, 6)
	var horizontal := Vector2(point.x, point.z)
	var clamped_point := Vector2(
		clampf(horizontal.x, MIN_X, MAX_X),
		clampf(horizontal.y, MIN_Z, MAX_Z)
	)
	if not contains(horizontal) and horizontal.distance_to(clamped_point) > float(radius + 1) * BLOCK_EXTENTS.y:
		return result
	var center_key := world_to_block(clamped_point)
	for y in range(maxi(0, center_key.y - radius), mini(GRID_DEPTH - 1, center_key.y + radius) + 1):
		for x in range(maxi(0, center_key.x - radius), mini(GRID_WIDTH - 1, center_key.x + radius) + 1):
			result.append(Vector2i(x, y))
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := block_center(a).distance_squared_to(horizontal)
		var db := block_center(b).distance_squared_to(horizontal)
		if not is_equal_approx(da, db):
			return da < db
		return a.y * GRID_WIDTH + a.x < b.y * GRID_WIDTH + b.x
	)
	return result


static func nearest_building(point: Vector3, max_range: float) -> Dictionary:
	if max_range < 0.0 or not is_finite(max_range) or max_range > 100000.0:
		return {}
	var best: Dictionary = {}
	var best_distance_squared := max_range * max_range
	for candidate in canonical_properties():
		var distance_squared := _horizontal_distance_squared(point, candidate.door)
		if distance_squared <= best_distance_squared:
			best_distance_squared = distance_squared
			best = candidate

	var low_x := floori((point.x - max_range - MIN_X) / BLOCK_EXTENTS.x)
	var high_x := floori((point.x + max_range - MIN_X) / BLOCK_EXTENTS.x)
	var low_y := floori((point.z - max_range - MIN_Z) / BLOCK_EXTENTS.y)
	var high_y := floori((point.z + max_range - MIN_Z) / BLOCK_EXTENTS.y)
	if high_x < 0 or low_x >= GRID_WIDTH or high_y < 0 or low_y >= GRID_DEPTH:
		return best
	for y in range(clampi(low_y, 0, GRID_DEPTH - 1), clampi(high_y, 0, GRID_DEPTH - 1) + 1):
		for x in range(clampi(low_x, 0, GRID_WIDTH - 1), clampi(high_x, 0, GRID_WIDTH - 1) + 1):
			for candidate in block_buildings(Vector2i(x, y)):
				var distance_squared := _horizontal_distance_squared(point, candidate.door)
				if distance_squared <= best_distance_squared:
					best_distance_squared = distance_squared
					best = candidate
	return best


static func stops() -> Array[Dictionary]:
	var result: Array[Dictionary] = [
		{
			"id": "origin_village_bus",
			"name": "Origin Villages",
			"position": Vector3(-60.0, 3.25, 55.0),
			"district": -1,
		},
		{
			"id": "lantern_square",
			"name": "Lantern Square",
			"position": Vector3(CENTER.x, GROUND_Y, CENTER.y),
			"district": 6,
		},
		{
			"id": "lantern_gardens",
			"name": "Lantern Gardens",
			"position": Vector3(PARK_CENTER.x + PARK_HALF_EXTENTS.x + 14.0, GROUND_Y, POND_CENTER.y),
			"district": district_for_block(PARK_BLOCK),
		},
	]
	for record in district_catalog():
		result.append({
			"id": "district_%02d" % int(record.id),
			"name": "%s Transit" % String(record.name),
			"position": record.center,
			"district": int(record.id),
		})
	for spec in _SERVICE_STOP_SPECS:
		var host := building(String(spec.building_id))
		var center: Vector3 = host.position
		var door: Vector3 = host.door
		# Transit arrival stays on the nearest street centerline, leaving the
		# sidewalk and front door clear. It follows the parcel when scale changes.
		var arrival := door
		if absf(door.x - center.x) > absf(door.z - center.z):
			arrival.x = MIN_X + roundf((door.x - MIN_X) / STREET_SPACING.x) * STREET_SPACING.x
		else:
			arrival.z = MIN_Z + roundf((door.z - MIN_Z) / STREET_SPACING.y) * STREET_SPACING.y
		result.append({"id": spec.id, "name": spec.name, "position": arrival, "district": host.district})
	return result


static func _make_building(key: Vector2i, lot_index: int, district_id: int) -> Dictionary:
	var id := _city_building_id(address_block(key), lot_index)
	var source_key := address_block(key)
	var profile_district := mini(source_key.y / 16,2)*4 + mini(source_key.x / 12,3)
	var profile := _profile_for(id, source_key, lot_index, profile_district)
	var offset := lot_center_offset(key, lot_index)
	var center := block_center(key) + offset
	var width := clampf(float(profile.width) * 1.24, 24.0, 32.4)
	var depth := clampf(float(profile.depth) * 1.20, 22.0, 31.0)
	var floors := int(profile.floors)
	# A taller lobby and 3.8 m structural floors give office towers believable
	# proportions while keeping the physical roof and residence in one record.
	var height := float(floors) * 3.8 + 1.8
	var position := Vector3(center.x, GROUND_Y, center.y)
	var door := _door_for(position, Vector3(width, height, depth), offset)
	var housing := housing_tier(String(profile.housing))
	var residence := Vector3.ZERO
	if not housing.is_empty():
		residence = Vector3(center.x, GROUND_Y + maxf(5.4, height - 2.2), center.y)
	return {
		"id": id,
		"name": String(profile.name),
		"kind": String(profile.kind),
		"retail_type": retail_type(id, String(profile.kind), key, lot_index),
		"position": position,
		"size": Vector3(width, height, depth),
		"door": door,
		"district": district_id,
		"service": String(profile.service),
		"housing": housing,
		"residence": residence,
		"floors": floors,
		"residents": 0,
		"capacity": 0,
		"jobs": int(profile.jobs),
		"block": key,
		"lot": lot_index,
		"purchasable": not housing.is_empty(),
		"facade_seed": _mix(key.x, key.y, lot_index),
		"skyline_zone": _skyline_weight(key),
	}


static func retail_type(id: String, kind: String, key: Vector2i, lot: int) -> String:
	if lot == 14 and posmod(key.x,13)==10 and posmod(key.y,16)==8: return "dealership"
	if id in ["crownreach-b24-24-l00","crownreach-b12-24-l00"]: return "grocer"
	if id == "crownreach-b00-23-l12": return "hardware"
	var roll := _mix(key.x,key.y,lot)
	match kind:
		"market": return ["grocer","garden","pantry"][posmod(roll,3)]
		"restaurant": return ["restaurant","cafe","bakery"][posmod(roll,3)]
		"workshop": return ["hardware","outdoors","energy","textiles"][posmod(roll,4)]
		"mixed_use": return ["textiles","outdoors","energy","pantry"][posmod(roll,4)]
	return ""


static func dealerships() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row in range(3):
		for column in range(4):
			var key := Vector2i(column*13+10,row*16+8)
			if is_park_block(key): continue
			result.append(building(_city_building_id(address_block(key),14)))
	return result


static func _profile_for(id: String, key: Vector2i, lot_index: int, district_id: int) -> Dictionary:
	var override := _special_profile(id)
	if not override.is_empty():
		return override
	var roll := _mix(key.x, key.y, lot_index)
	var kind := "mixed_use"
	var service_kind := "repair_shop"
	var housing := "city_apartment"
	var floors := 6 + posmod(roll, 8)
	var jobs := 8 + posmod(roll / 7, 24)
	match lot_index % 8:
		0:
			kind = "market"
			service_kind = "produce_market"
			housing = "work_live"
			floors = 5 + posmod(roll, 5)
		1:
			kind = "restaurant"
			service_kind = "restaurant_kitchen"
			housing = "city_apartment"
			floors = 4 + posmod(roll, 8)
		2:
			kind = "clinic" if posmod(district_id + key.x, 2) == 0 else "school"
			service_kind = "clinic" if kind == "clinic" else "school"
			housing = "staff_residence"
			floors = 5 + posmod(roll, 5)
		3:
			if _DISTRICT_KINDS[district_id] in ["industry", "logistics", "utilities", "transit"]:
				kind = ["warehouse", "depot", "utility"][posmod(roll, 3)]
				service_kind = {"warehouse": "warehouse_handler", "depot": "transit_depot", "utility": "utility_crew"}[kind]
				housing = ""
				floors = 2 + posmod(roll, 3)
			else:
				kind = "workshop"
				service_kind = "craft_workshop"
				housing = "work_live"
				floors = 4 + posmod(roll, 5)
		4, 5:
			kind = "apartment"
			service_kind = "building_maintenance"
			housing = "city_apartment"
			floors = 8 + posmod(roll, 10)
		6:
			kind = "tower"
			service_kind = "food_hall"
			housing = "city_apartment"
			floors = 14 + posmod(roll, 13)
		7:
			kind = "townhouse"
			service_kind = "parcel_room"
			housing = "town_house"
			floors = 3 + posmod(roll, 4)
	var skyline := _skyline_weight(key)
	# A street wall of older walkups and mid-rise blocks, punctuated by a few
	# commercial towers around transit/downtown. Service/property IDs do not move.
	match kind:
		"tower":
			floors = 7 + posmod(roll, 10)
			if skyline > 0.22 and posmod(roll / 17, 4) == 0:
				floors = 20 + roundi(skyline * float(20 + posmod(roll / 13, 54)))
			if skyline > 0.8 and posmod(roll / 23, 29) == 0:
				floors += 30
		"apartment":
			floors = 3 + posmod(roll, 8) + roundi(skyline * 7.0)
			if skyline > 0.5 and posmod(roll / 19, 9) == 0:
				floors += 12
		"restaurant", "mixed_use", "market", "workshop":
			floors = 2 + posmod(roll, 6) + roundi(skyline * 3.0)
		"clinic", "school":
			floors = 2 + posmod(roll, 4)
		"townhouse":
			floors = 2 + posmod(roll, 3)
	if id == "crownreach-b27-27-l06":
		floors = 170 # The true commercial landmark above the residential skyline.
	var width := 20.0 + float(posmod(roll / 11, 9))
	var depth := 20.0 + float(posmod(roll / 19, 9))
	if floors >= 30:
		width = maxf(width, 26.0)
		depth = maxf(depth, 26.0)
	var district_name := _DISTRICT_NAMES[district_id]
	return {
		"name": "Crownreach Spire" if id == "crownreach-b27-27-l06" else "%s %s %02d" % [district_name, kind.capitalize(), lot_index + 1],
		"kind": kind,
		"service": service_kind,
		"housing": housing,
		"floors": floors,
		"jobs": jobs,
		"width": width,
		"depth": depth,
	}


static func _skyline_weight(key: Vector2i) -> float:
	# A dominant downtown cluster and two secondary centers create a legible
	# silhouette rather than scattering equal-height towers over the whole city.
	var point := Vector2(key) + Vector2(0.5, 0.5)
	var downtown := 1.0 - smoothstep(1.0, 9.0, ((point - Vector2(25.0, 23.0)) * Vector2(1.0, 0.84)).length())
	var northlight := 0.64 * (1.0 - smoothstep(0.0, 7.0, (point - Vector2(31.0, 9.0)).length()))
	var railworks := 0.48 * (1.0 - smoothstep(0.0, 6.0, (point - Vector2(39.0, 38.0)).length()))
	return maxf(downtown, maxf(northlight, railworks))


static func _special_profile(id: String) -> Dictionary:
	match id:
		"crownreach-b24-24-l00":
			return {"name": "Lantern Produce Pavilion", "kind": "market", "service": "produce_exchange", "housing": "", "floors": 2, "jobs": 28, "width": 18.0, "depth": 18.0}
		"crownreach-b24-24-l01":
			return {"name": "Lantern House", "kind": "apartment", "service": "courier_delivery", "housing": "city_apartment", "floors": 34, "jobs": 18, "width": 28.0, "depth": 24.0}
		"crownreach-b24-24-l02":
			return {"name": "Crownreach Beacon", "kind": "tower", "service": "restaurant_kitchen", "housing": "penthouse", "floors": 50, "jobs": 42, "width": 28.0, "depth": 24.0}
		"crownreach-b04-08-l03":
			return {"name": "Westgate Warehouse Loft", "kind": "warehouse", "service": "warehouse_handler", "housing": "warehouse", "floors": 4, "jobs": 16, "width": 24.0, "depth": 24.0}
		"crownreach-b00-24-l00":
			return {"name": "Westgate Courier Depot", "kind": "depot", "service": "courier_depot", "housing": "", "floors": 3, "jobs": 32, "width": 24.0, "depth": 24.0}
		"crownreach-b00-23-l12":
			return {"name": "Westgate Maintenance Shop", "kind": "workshop", "service": "maintenance_depot", "housing": "work_live", "floors": 4, "jobs": 24, "width": 24.0, "depth": 24.0}
		"crownreach-b23-23-l14", "crownreach-b18-08-l09", "crownreach-b40-24-l06":
			return {"name": "Crownreach Maintenance Site", "kind": "utility", "service": "maintenance_site", "housing": "", "floors": 3, "jobs": 18, "width": 24.0, "depth": 24.0}
		"crownreach-b31-08-l05", "crownreach-b40-40-l10":
			return {"name": "Crownreach Delivery Point", "kind": "market", "service": "courier_delivery", "housing": "city_apartment", "floors": 7, "jobs": 14, "width": 26.0, "depth": 26.0}
		"crownreach-b12-24-l00":
			return {"name": "Garden Row Produce Market", "kind": "market", "service": "produce_market", "housing": "work_live", "floors": 6, "jobs": 30, "width": 24.0, "depth": 24.0}
	return {}


static func _village_building(id: String) -> Dictionary:
	var spec: Dictionary
	match id:
		"village-cottage":
			spec = {"name": "Canopy Cottage", "position": Vector3(-125.0, 3.25, 100.0), "size": Vector3(15.0, 8.0, 12.0), "housing": "cottage", "service": "home_office", "jobs": 1}
		"town-apartments":
			spec = {"name": "Harbor Town Apartments", "position": Vector3(525.0, 3.25, 65.0), "size": Vector3(28.0, 18.0, 22.0), "housing": "town_apartment", "service": "building_maintenance", "jobs": 3}
		"suburban-home":
			spec = {"name": "Ridge Suburban Home", "position": Vector3(-730.0, 3.25, -490.0), "size": Vector3(18.0, 10.0, 15.0), "housing": "suburban_home", "service": "home_workshop", "jobs": 2}
		_:
			return {}
	var position: Vector3 = spec.position
	var size: Vector3 = spec.size
	return {
		"id": id,
		"name": String(spec.name),
		"kind": "home",
		"position": position,
		"size": size,
		"door": position + Vector3(0.0, 0.0, size.z * 0.5 + 1.0),
		"district": -1,
		"service": String(spec.service),
		"housing": String(spec.housing),
		"residence": position + Vector3(0.0, size.y - 2.0, 0.0),
		"floors": maxi(2, roundi(size.y / 3.6)),
		"residents": 0,
		"capacity": 8 if id != "town-apartments" else 36,
		"jobs": int(spec.jobs),
		"block": Vector2i(-1, -1),
		"lot": -1,
		"purchasable": true,
	}


static func _door_for(position: Vector3, size: Vector3, offset: Vector2) -> Vector3:
	return position + Vector3(signf(offset.x) * (size.x * 0.5 + 1.5), 0.0, 0.0)


static func _is_reserved_square_lot(key: Vector2i, lot_index: int) -> bool:
	# Keep the exact world center open while retaining a small service pavilion in
	# the northeast quadrant so the arrival stop is immediately useful.
	return (
		(key == Vector2i(23, 23) and lot_index == 15)
		or (key == Vector2i(24, 23) and lot_index == 12)
		or (key == Vector2i(23, 24) and lot_index == 3)
	)


static func _is_purchasable(id: String) -> bool:
	for spec in _PURCHASABLE:
		if spec.building_id == id:
			return true
	return false


static func _city_building_id(key: Vector2i, lot_index: int) -> String:
	return "crownreach-b%02d-%02d-l%02d" % [key.x, key.y, lot_index]


static func _horizontal_distance_squared(a: Vector3, b: Vector3) -> float:
	var dx := a.x - b.x
	var dz := a.z - b.z
	return dx * dx + dz * dz


static func _mix(x: int, y: int, salt: int) -> int:
	var value := x * 73856093 ^ y * 19349663 ^ salt * 83492791
	value = (value ^ (value >> 13)) * 1274126177
	return absi(value ^ (value >> 16))
