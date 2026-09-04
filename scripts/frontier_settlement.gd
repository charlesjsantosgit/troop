class_name FrontierSettlement
extends Node3D
## Physical Roots & Rockets settlements. Every interactive crop, citizen and
## utility reads the same finite ledger used by the market and autonomous jobs.
## The host supplies terrain in this site's local frame (including lunar curves).

const WOOD := Color(0.37, 0.22, 0.105)
const BAMBOO := Color(0.67, 0.5, 0.24)
const THATCH := Color(0.63, 0.48, 0.21)
const CREAM := Color(0.85, 0.83, 0.69)
const TEAL := Color(0.15, 0.42, 0.39)
const NAVY := Color(0.10, 0.18, 0.22)
const STEEL := Color(0.39, 0.45, 0.46)
const SAFETY := Color(0.98, 0.61, 0.13)
const LEAF := Color(0.23, 0.49, 0.19)
const EARTH_LOCATIONS := {
	"cooperative": Vector2(-35, -35), "earth_market": Vector2(0, -15),
	"water": Vector2(-18, -18), "kitchen": Vector2(18, -18),
	"warehouse": Vector2(30, -35), "workshop": Vector2(40, 15),
	"oil_rig": Vector2(120, -35), "refinery": Vector2(95, 10),
	"gas_station": Vector2(60, 35), "airfield": Vector2(100, 65),
	"carrier": Vector2(145, -80), "housing": Vector2(-32, 25),
	"town_square": Vector2(0, 4),
}
const MOON_LOCATIONS := {
	"lunar_greenhouse": Vector2(-20, -20), "moon_market": Vector2(0, -12),
	"solar": Vector2(28, -20), "habitat": Vector2(-15, 15),
	"housing": Vector2(-15, 15), "cargo": Vector2(28, 20),
	"ice_mine": Vector2(-55, -35), "water": Vector2(-55, -35),
	"town_square": Vector2(0, 4),
}

var planet := "earth"
var town_info: Dictionary = {}
var tree_positions: Array[Vector2] = []
var _collision_only := false
var _building := false
var _build_jobs: Array[Callable] = []
var _crop_jobs: Array[String] = []
var _surface_batches: Dictionary = {}
const Paving = preload("res://scripts/frontier_paving.gd")
var _paving = Paving.new()
const ServicePoints = preload("res://scripts/frontier_service_points.gd")
var citizens: Dictionary = {}
var plot_roots: Dictionary = {}
var _host: Node3D
var _simulation: RefCounted
var _props: FrontierProps
var _interactions: Array[Dictionary] = []
var _plots: Dictionary = {}
var _solar_label: Label3D
var _utility_label: Label3D
var _oil_arm: Node3D
var _oil_working := false
var _solar_panels: Array[Node3D] = []
var _timer := 0.0
var _time := 0.0
var _built := false


func configure(host: Node3D, simulation: RefCounted, realm: String,
		metadata: Dictionary = {}) -> void:
	_host = host
	_simulation = simulation
	planet = realm
	town_info = metadata.duplicate(true)


func build() -> void:
	while not build_step(1000.0):
		pass


func build_collision_only() -> void:
	if _built or _building:
		return
	_collision_only = true
	build()
	set_process(false)


func is_build_complete() -> bool:
	return _built


## Each job is one small authored worksite, bed, or citizen. Mesh submissions
## flush four materials at a time so several towns can stream over many frames.
func build_step(budget_ms := 2.0) -> bool:
	if _built:
		return true
	if _host == null or _simulation == null:
		return true
	if not _building:
		_begin_build()
	var deadline := Time.get_ticks_usec() + int(maxf(0.1, budget_ms) * 1000.0)
	while not _build_jobs.is_empty():
		var job: Callable = _build_jobs.pop_front()
		job.call()
		if Time.get_ticks_usec() >= deadline:
			return false
	while _paving.pending():
		for piece: Dictionary in _paving.next():
			_emit_paving(piece)
		if Time.get_ticks_usec() >= deadline:
			return false
	if not _surface_batches.is_empty():
		_flush_surface_step()
		return false
	if not _props.flush_step(4):
		return false
	_built = true
	_building = false
	if not _collision_only:
		_refresh_state()
	return true


func _begin_build() -> void:
	_building = true
	name = "RootsAndRockets_%s" % str(town_info.get("id", planet)).validate_node_name()
	_props = FrontierProps.new(self, not _collision_only)
	if planet == "moon":
		_build_jobs.assign([_build_moon_paths, _build_greenhouse, _build_solar,
			_build_habitat, _build_lunar_market, _build_lunar_cargo, _build_ice_plant, _build_moon_square])
	else:
		_build_jobs.assign([_build_square, _build_market, _build_housing,
			_build_well, _build_service_hut.bind("kitchen", "CANOPY KITCHEN", Color(0.72,0.31,0.18)),
			_build_service_hut.bind("warehouse", "COOPERATIVE STORE", TEAL),
			_build_service_hut.bind("workshop", "BAMBOO WORKS", Color(0.32,0.46,0.6)),
			_build_farmyard, _build_oil_rig, _build_refinery, _build_gas_station,
			_build_airfield, _build_port, _build_earth_details])
	for id in _state().get("plots", {}):
		if str(_state().plots[id].get("planet", "earth")) == planet:
			_build_jobs.append(_build_plot.bind(str(id)))
	if planet == "earth":
		_build_jobs.append(_build_roads)
		if not _collision_only:
			for segment: Dictionary in FrontierRoutes.road_segments():
				_build_jobs.append(_build_street.bind(segment["from"], segment.to, float(segment.width)))
		if not _collision_only:
			for bay_id: String in FrontierRoutes.loading_bays():
				_build_jobs.append(_build_loading_bay.bind(bay_id))
		for row in range(-7,8):
			_build_jobs.append(_build_forest_row.bind(row))
	if not _collision_only:
		for id in _state().get("citizens", {}):
			if str(_state().citizens[id].get("planet", "earth")) == planet:
				_build_jobs.append(_build_citizen.bind(str(id)))


func _state() -> Dictionary:
	return _simulation.get("state") if _simulation != null else {}


func ground_height(x: float, z: float) -> float:
	if _host.has_method("surface_height"):
		return float(_host.call("surface_height", x, z))
	if _host.has_method("height_at"):
		return float(_host.call("height_at", x, z))
	return Gen.height(x, z)


func _point(xz: Vector2, lift := 0.0) -> Vector3:
	return Vector3(xz.x, ground_height(xz.x, xz.y) + lift, xz.y)


func _set_frame(xz: Vector2) -> void:
	var orientation := Basis.IDENTITY
	if planet == "moon" and _host.has_method("surface_normal"):
		var normal: Vector3 = _host.call("surface_normal", xz.x, xz.y)
		orientation = Basis(Quaternion(Vector3.UP, normal.normalized()))
	_props.frame = Transform3D(orientation, _point(xz))


func _location(id: String) -> Vector2:
	var defaults: Dictionary = MOON_LOCATIONS if planet == "moon" else EARTH_LOCATIONS
	return defaults.get(id, Vector2.ZERO)


static func service_position(realm: String, id: String) -> Vector2:
	return ServicePoints.service_position(realm,id)


func get_interactions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry in _interactions:
		var current := entry.duplicate()
		current.position = to_global(entry.position)
		current.town_id = str(town_info.get("id", ""))
		result.append(current)
	for citizen in citizens.values():
		if is_instance_valid(citizen):
			var current: Dictionary = citizen.interaction()
			current.town_id = str(town_info.get("id", ""))
			result.append(current)
	return result


func _interact(id: String, kind: String, label: String, xz: Vector2, height := 0.9) -> void:
	var service := service_position(planet,id)
	if kind in ["facility","board","market"] and service.is_finite():
		xz = service
	_interactions.append({"id": id, "kind": kind, "label": label,
		"position": _point(xz, height)})


func _process(dt: float) -> void:
	if not _built or _collision_only or not is_visible_in_tree():
		return
	if not _crop_jobs.is_empty():
		var crop_id: String = _crop_jobs.pop_front()
		var crop_data: Dictionary = _state().plots.get(crop_id, {})
		_rebuild_crop(_plots[crop_id].root, str(crop_data.get("crop", "")), float(crop_data.get("growth", 0.0)), float(crop_data.get("health", 1.0)))
	_time += dt
	_timer += dt
	var camera := get_viewport().get_camera_3d()
	var camera_position := camera.global_position if camera else Vector3.INF
	for citizen in citizens.values():
		citizen.update_citizen(dt, camera_position)
	if _timer >= 0.5:
		_timer = 0.0
		_refresh_state()
	if _oil_arm != null:
		_oil_arm.rotation.z = sin(_time * 0.65) * 0.21 if _oil_working else 0.0


func _build_earth_details() -> void:
	for x in [-10.0, 10.0]:
		_set_frame(Vector2(x, 9))
		_bench(Vector3.ZERO)
	for z in [-8.0, 7.0, 23.0]:
		_pennant_span(Vector2(-5, z), Vector2(5, z))


func _build_roads() -> void:
	if _collision_only:
		return
	# Crop aisles are visibly narrower, without traffic lane markings.
	for route in [[Vector2(-35,-15),Vector2(-35,-23),Vector2(-39,-23),Vector2(-39,-38)],
			[Vector2(-58,-15),Vector2(-58,-38)]]:
		_path(route, 1.9)


func _build_square() -> void:
	_set_frame(_location("town_square"))
	# The plaza shares the street elevation; its footprint is trimmed around
	# roads before tessellation, so beige and asphalt never fight for a pixel.
	_build_surface_pad(_location("town_square"),8.4,Color(0.68,0.58,0.39),20,0.075)
	_build_surface_pad(_location("town_square"),2.9,Color(0.75,0.68,0.48),21,0.075)
	# A small community tree is the village's visual anchor; its base stays
	# outside the arrival square used by citizens and the player spawn.
	_props.cylinder(Vector3(0, 0.6, 4.8), 1.4, 1.2, Color(0.39, 0.37, 0.26), true)
	_props.cylinder(Vector3(0, 3.7, 4.8), 0.37, 6.7, WOOD)
	for index in range(5):
		var angle := float(index) * TAU / 5.0
		_props.piece("sphere", Vector3(cos(angle) * 1.8, 6.6, 4.8 + sin(angle) * 1.8), Vector3(4.7, 2.5, 4.3), LEAF)
	_props.text(Vector3(0, 4.5, -0.5), str(town_info.get("name", "CANOPY COMMONS")).to_upper(), Color(1.0, 0.92, 0.67), 47, 76.0)
	_set_frame(Vector2(3.8, 1.1))
	_props.box(Vector3(0, 1.2, 0), Vector3(2.8, 1.7, 0.18), WOOD, true)
	for x in [-1.23, 1.23]:
		_props.cylinder(Vector3(x, 0.9, 0), 0.09, 1.8, BAMBOO)
	for x in [-0.8, 0.0, 0.8]:
		_props.box(Vector3(x, 1.25, -0.11), Vector3(0.57, 0.75, 0.025), CREAM)
	_props.text(Vector3(0, 2.6, 0), "TOWN NOTICEBOARD\nClaim · Contracts · Neighbours", Color(0.96, 0.86, 0.57), 27)
	_interact("town_square", "board", "Community jobs & society", Vector2(3.8, -0.3))


func _build_housing() -> void:
	var homes := [Vector2(-32, 33), Vector2(-46, 29), Vector2(-49, 14), Vector2(-24, 40), Vector2(15, 38), Vector2(29, 30)]
	var names := ["Mango House", "Fern Cottage", "The Banyan Nest", "Honey Hut", "Papaya Place", "Sunbird Home"]
	for index in range(homes.size()):
		_set_frame(homes[index])
		_hut(7.6, 6.7, [TEAL, Color(0.61, 0.3, 0.18), Color(0.43, 0.46, 0.22)][index % 3])
		_props.text(Vector3(0, 3.0, -3.1), names[index], Color(0.92, 0.84, 0.63), 23, 28.0)
		_props.box(Vector3(-2.5, 0.5, 1.3), Vector3(1.5, 0.4, 2.3), BAMBOO)
		_props.box(Vector3(-2.5, 0.79, 1.3), Vector3(1.45, 0.18, 2.2), CREAM)
		_props.cylinder(Vector3(1.8, 0.66, 0.3), 0.85, 0.12, WOOD)
		_props.cylinder(Vector3(1.8, 0.33, 0.3), 0.11, 0.6, BAMBOO)
		_planter(Vector3(-3.3, 0.0, -4.2))
		_planter(Vector3(3.3, 0.0, -4.2))
		_path([homes[index] + Vector2(0, -4.5), Vector2(homes[index].x, 25 if index < 4 else 23)], 2.3)
	_interact("housing", "facility", "Monkey homes · housing & needs", _location("housing"))


func _hut(width: float, depth: float, accent: Color) -> void:
	accent = _town_accent(accent)
	_props.box(Vector3(0, 0.08, 0), Vector3(width + 0.4, 0.16, depth + 0.3), WOOD, true)
	# Front is a real open doorway; three waist-high walls and four corner
	# posts give visible interiors and shelter without a solid collision cube.
	_props.box(Vector3(0, 0.8, depth * 0.5), Vector3(width, 1.5, 0.18), BAMBOO, true)
	for x in [-width * 0.5, width * 0.5]:
		_props.box(Vector3(x, 0.8, 0), Vector3(0.18, 1.5, depth), BAMBOO, true)
		for z in [-depth * 0.5, depth * 0.5]:
			_props.cylinder(Vector3(x, 1.8, z), 0.14, 3.6, WOOD)
	for x in [-width * 0.32, width * 0.32]:
		_props.box(Vector3(x, 0.8, -depth * 0.5), Vector3(width * 0.34, 1.5, 0.18), BAMBOO, true)
		_props.box(Vector3(x, 1.5, -depth * 0.51), Vector3(width * 0.34, 0.14, 0.21), accent)
	# Layered conical thatch roof and repeated eaves have a monkey-village
	# silhouette readable above paths and across the canopy.
	for tier in range(3):
		_props.piece("cone", Vector3(0, 3.25 + tier * 0.57, 0),
			Vector3(width + 1.5 - tier * 1.7, 1.4, depth + 1.7 - tier * 1.45), THATCH)
	for index in range(16):
		var angle := TAU * float(index) / 16.0
		_props.beam(Vector3(0, 4.95, 0), Vector3(cos(angle) * (width + 1.4) * 0.5, 2.6, sin(angle) * (depth + 1.6) * 0.5), 0.08, BAMBOO)


func _build_market() -> void:
	var at := _location("earth_market")
	_set_frame(at + Vector2(0, -1))
	for index in range(3):
		var x := (index - 1) * 4.2
		var awning: Color = [TEAL, Color(0.72, 0.35, 0.2), Color(0.65, 0.54, 0.16)][index]
		_props.box(Vector3(x, 0.95, -3.0), Vector3(3.5, 0.16, 1.6), WOOD, true)
		for sx in [-1.65, 1.65]:
			_props.cylinder(Vector3(x + sx, 1.5, -3.0), 0.08, 3.0, BAMBOO)
		_props.box(Vector3(x, 3.0, -3), Vector3(3.9, 0.15, 2.8), awning, false, Vector3(-0.13, 0, 0))
		for stripe in range(4):
			_props.box(Vector3(x - 1.3 + stripe * 0.88, 3.06, -3.0), Vector3(0.4, 0.025, 2.78), CREAM, false, Vector3(-0.13, 0, 0))
		for item in range(12):
			var pos := Vector3(x - 1.2 + (item % 4) * 0.75, 1.13, -3.4 + floorf(item / 4.0) * 0.35)
			_props.piece("sphere", pos, Vector3(0.29, 0.23, 0.34), [Color(0.9, 0.74, 0.12), Color(0.73, 0.16, 0.09), LEAF][index])
	_props.text(Vector3(0, 4.1, -2), "THE CANOPY EXCHANGE\nFresh harvest · Fair trade", Color(0.95, 0.85, 0.58), 34, 60.0)
	_interact("earth_market", "market", "Earth market · buy and sell", at)


func _build_service_hut(id: String, title: String, accent: Color) -> void:
	var offset := Vector2(-8.5, 0) if id == "workshop" else Vector2(0, -7.0 if id == "warehouse" else -5.3)
	_set_frame(_location(id) + offset)
	_props.frame.basis = _props.frame.basis * Basis(Vector3.UP, -PI * 0.5 if id == "workshop" else PI)
	_hut(8.0, 7.3, accent)
	_props.text(Vector3(0, 3.3, -3.5), title, CREAM, 30)
	if id == "kitchen":
		_props.box(Vector3(-2, 0.65, 0), Vector3(2.5, 1.2, 1.4), Color(0.45, 0.36, 0.25), true)
		for x in [-2.7, -1.5]:
			_props.cylinder(Vector3(x, 1.5, 0), 0.42, 0.6, STEEL)
		_props.cylinder(Vector3(-2, 3.5, 1), 0.34, 3.4, Color(0.31, 0.3, 0.27))
		_props.box(Vector3(2.2, 0.9, 0), Vector3(2.0, 0.15, 2.0), WOOD, true)
	elif id == "warehouse":
		for x in [-2.5, 0.0, 2.5]:
			for z in [-0.8, 1.4]:
				_crate(Vector3(x, 0, z), 1.1)
		for x in [-3.2, 3.2]:
			_props.box(Vector3(x, 1.15, 0), Vector3(0.9, 0.1, 5.3), BAMBOO)
	else:
		_props.box(Vector3(0, 0.86, 0), Vector3(4.8, 0.15, 1.5), WOOD, true)
		for x in [-1.8, 1.8]:
			_props.box(Vector3(x, 0.4, 0), Vector3(0.18, 0.8, 1.2), BAMBOO)
		_props.box(Vector3(0, 2.0, 2.6), Vector3(4.0, 1.3, 0.08), NAVY)
		for x in [-1.4, -0.5, 0.4, 1.3]:
			_props.box(Vector3(x, 2.05, 2.51), Vector3(0.09, 0.65, 0.1), STEEL)
	_interact(id, "facility", title.capitalize(), _location(id))


func _build_well() -> void:
	_set_frame(_location("water") + Vector2(0, -2.8))
	for index in range(12):
		var angle := TAU * index / 12.0
		_props.box(Vector3(cos(angle) * 1.4, 0.6, sin(angle) * 1.4), Vector3(0.72, 1.2, 0.42), Color(0.45, 0.45, 0.37), true, Vector3(0, -angle, 0))
	_props.cylinder(Vector3(0, 0.5, 0), 1.15, 0.04, Color(0.14, 0.44, 0.51))
	for x in [-1.7, 1.7]:
		_props.cylinder(Vector3(x, 1.9, 0), 0.12, 3.8, WOOD)
	_props.beam(Vector3(-1.7, 3.6, 0), Vector3(1.7, 3.6, 0), 0.2, BAMBOO)
	_props.beam(Vector3.ZERO, Vector3(0, 3.6, 0), 0.035, BAMBOO)
	_props.piece("cone", Vector3(0, 4.0, 0), Vector3(4.9, 1.3, 4.2), THATCH)
	_props.text(Vector3(0, 4.9, 0), "THE VILLAGE WELL\nShared irrigation supply", CREAM, 27)
	_interact("water", "facility", "Waterworks · irrigation", _location("water"))
	_path([Vector2(-18, -18), Vector2(-18, -15)], 2.5)


func _build_farmyard() -> void:
	_set_frame(Vector2(-44, -47))
	_props.box(Vector3(0, 0.16, 0), Vector3(20, 0.3, 1), WOOD)
	for x in range(-10, 11, 2):
		_props.cylinder(Vector3(x, 0.85, 0), 0.075, 1.7, BAMBOO)
	_props.beam(Vector3(-10, 0.9, 0), Vector3(10, 0.9, 0), 0.09, BAMBOO)
	_props.text(Vector3(0, 2.5, 0), "COMMON GROUND\nYour beds + the village cooperative", CREAM, 30, 52.0)
	_set_frame(Vector2(-60, -33))
	_props.box(Vector3(0, 0.5, 0), Vector3(3.5, 1.0, 2.4), WOOD, true)
	_props.box(Vector3(0, 1.05, 0), Vector3(3.25, 0.12, 2.15), Color(0.17, 0.12, 0.07))
	_props.text(Vector3(0, 1.9, 0), "COMPOST", CREAM, 23, 26.0)
	_set_frame(Vector2(-49, -43))
	_crate(Vector3.ZERO, 1.0)
	_crate(Vector3(1.3, 0, 0), 1.0)
	_interact("cooperative", "facility", "Farm cooperative · production & crew", Vector2(-35, -23))
	_props.frame = Transform3D.IDENTITY
	_props.beam(_point(Vector2(-18, -21), 0.18), _point(Vector2(-57, -21), 0.18), 0.12, Color(0.23, 0.34, 0.38))
	for x in [-50.0, -35.0, -29.0, -23.0]:
		_props.beam(_point(Vector2(x, -21), 0.16), _point(Vector2(x, -42), 0.16), 0.075, STEEL)


func _build_oil_rig() -> void:
	_set_frame(_location("oil_rig") + Vector2(0, -11))
	_props.box(Vector3(0, 0.2, 0), Vector3(17, 0.4, 16), Color(0.31, 0.33, 0.31), true)
	for x in [-3.3, 3.3]:
		for z in [-3.3, 3.3]:
			_props.beam(Vector3(x, 0.4, z), Vector3(x * 0.28, 19, z * 0.28), 0.48, STEEL)
	for level in range(5):
		var y := 1.5 + level * 3.6
		var w := lerpf(3.2, 1.0, y / 19.0)
		for z in [-w, w]:
			_props.beam(Vector3(-w, y, z), Vector3(w, y, z), 0.17, STEEL)
			_props.beam(Vector3(-w, y, z), Vector3(w * 0.85, y + 3.5, z * 0.85), 0.12, SAFETY)
		for x in [-w, w]:
			_props.beam(Vector3(x, y, -w), Vector3(x, y, w), 0.17, STEEL)
	_props.cylinder(Vector3(0, 9.0, 0), 0.17, 17.0, NAVY)
	_props.box(Vector3(0, 19.4, 0), Vector3(3.2, 1.0, 3.2), SAFETY)
	for index in range(3):
		_props.cylinder(Vector3(6.2, 1.5, -4.0 + index * 3.3), 1.3, 2.6, Color(0.31, 0.38, 0.37), true)
	_props.box(Vector3(-6.0, 1.5, 2.8), Vector3(4.2, 2.5, 5.0), CREAM, true)
	_props.box(Vector3(-6, 2.0, 5.34), Vector3(2.8, 0.8, 0.05), Color(0.11, 0.3, 0.36))
	# A moving pumpjack beside the derrick signals extraction, and stops when
	# the authoritative facility is disabled or broken.
	_props.cylinder(Vector3(7.7, 2.0, 5.4), 0.28, 3.5, STEEL)
	if not _collision_only:
		_oil_arm = Node3D.new()
		_oil_arm.transform = _props.frame * Transform3D(Basis.IDENTITY, Vector3(7.7, 3.7, 5.4))
		add_child(_oil_arm)
		_props.dynamic_piece("box", Vector3.ZERO, Vector3(5.5, 0.36, 0.48), SAFETY, _oil_arm)
		_props.dynamic_piece("box", Vector3(2.45, -0.55, 0), Vector3(0.65, 1.3, 0.6), NAVY, _oil_arm)
	_props.text(Vector3(0, 5.8, 7), "CANOPY ENERGY\nDrilling crew · Crude dispatch", CREAM, 34, 85.0)
	_interact("oil_rig", "facility", "Oil rig · extraction and crew", _location("oil_rig"))


func _build_refinery() -> void:
	_set_frame(_location("refinery") + Vector2(0, -6))
	_queue_ground_rectangle(_location("refinery")+Vector2(0,-6),Vector2(18,12),Color(0.48,0.48,0.41),0.075)
	for index in range(3):
		var x := -5.5 + index * 5.0
		_props.cylinder(Vector3(x, 2.7, -1.2), 2.0, 5.4, STEEL, true, Vector3.ZERO, 0.4)
		_props.piece("sphere", Vector3(x, 5.4, -1.2), Vector3(4.0, 1.0, 4.0), CREAM)
		_props.cylinder(Vector3(x, 0.8, -1.2), 2.08, 0.14, SAFETY)
		_props.beam(Vector3(x, 3.5, 0.8), Vector3(x, 3.5, 4.0), 0.26, SAFETY)
	_props.beam(Vector3(-5.5, 3.5, 4.0), Vector3(4.5, 3.5, 4.0), 0.26, SAFETY)
	_props.cylinder(Vector3(8, 6.4, -4), 0.7, 12.7, Color(0.49, 0.52, 0.5))
	_props.text(Vector3(0, 6.4, 4.5), "FRACTIONATION WORKS\nCrude → diesel + aviation fuel", CREAM, 30, 70.0)
	_interact("refinery", "facility", "Refinery · fuels and maintenance", _location("refinery"))


func _build_gas_station() -> void:
	_set_frame(_location("gas_station") + Vector2(0, -6))
	_queue_ground_rectangle(_location("gas_station")+Vector2(0,-6),Vector2(19,11),Color(0.44,0.45,0.4),0.075)
	_props.box(Vector3(0, 4.7, 0), Vector3(17, 0.45, 10), CREAM)
	_props.box(Vector3(0, 4.7, 5.04), Vector3(17, 0.5, 0.12), TEAL)
	for x in [-6.7, 6.7]:
		_props.cylinder(Vector3(x, 2.25, 0), 0.17, 4.5, STEEL, true)
	for x in [-3.6, 3.6]:
		_props.box(Vector3(x, 0.85, 0), Vector3(1.2, 1.7, 0.9), CREAM, true)
		_props.box(Vector3(x, 1.25, 0.46), Vector3(0.87, 0.45, 0.035), NAVY)
		_props.box(Vector3(x, 0.48, 0.46), Vector3(1.05, 0.47, 0.04), TEAL)
		_props.beam(Vector3(x + 0.7, 1.4, 0), Vector3(x + 1.0, 0.35, 0), 0.07, NAVY)
	_props.text(Vector3(0, 5.5, 4.5), "LEAF & LITRE\nDiesel deliveries · Finite stock", CREAM, 35, 68.0)
	_interact("gas_station", "facility", "Gas station · fuel deliveries", _location("gas_station"))


func _build_airfield() -> void:
	_set_frame(_location("airfield"))
	_queue_ground_rectangle(_location("airfield")+Vector2(0,16),Vector2(24,36),Color(0.28,0.3,0.29),0.05)
	for index in range(6):
		_props.box(Vector3(0, 0.057, 3 + index * 5.7), Vector3(0.45, 0.02, 2.5), CREAM)
	for x in [-10.8, 10.8]:
		_props.box(Vector3(x, 0.055, 16), Vector3(0.18, 0.02, 32), SAFETY)
		for z in [0.0, 12.0, 25.0, 34.0]:
			_props.piece("sphere", Vector3(x, 0.28, z), Vector3(0.23, 0.2, 0.23), Color(0.31, 0.71, 0.95), Vector3.ZERO, 0, 0.4)
	_props.box(Vector3(-16, 3.2, 13), Vector3(0.25, 6.4, 17), STEEL, true)
	_props.box(Vector3(-25, 3.2, 13), Vector3(0.25, 6.4, 17), STEEL, true)
	_props.box(Vector3(-20.5, 6.5, 13), Vector3(9.5, 0.3, 18), CREAM)
	_props.box(Vector3(-20.5, 3.2, 21.5), Vector3(9.0, 6.4, 0.2), STEEL, true)
	_props.cylinder(Vector3(-16, 1.7, -1.0), 1.25, 3.4, STEEL, true)
	_props.text(Vector3(0, 4.4, -2.7), "CANOPY AIR FREIGHT\nAviation fuel receiving apron", CREAM, 31, 76.0)
	_interact("airfield", "facility", "Airfield · aviation fuel depot", _location("airfield"))


func _build_port() -> void:
	_set_frame(_location("carrier"))
	# This freight berth is a receiving depot, not a drivable imitation of the
	# existing naval vessels. A loading ramp and crane make its role explicit.
	_props.box(Vector3(0, 0.13, -15), Vector3(15, 0.26, 24), WOOD, true)
	for x in [-7.2, 7.2]:
		for z in [-20.0, -12.0, -4.0]:
			_props.cylinder(Vector3(x, 0.8, z), 0.26, 1.6, WOOD)
	_props.box(Vector3(0, 1.15, -13), Vector3(10.8, 1.8, 17), Color(0.22, 0.3, 0.33), true)
	_props.box(Vector3(0, 2.12, -13), Vector3(10.4, 0.15, 16.7), STEEL, true)
	for index in range(4):
		_crate(Vector3(-2.5 + (index % 2) * 3.0, 2.2, -13 - floorf(index / 2.0) * 3.1), 2.2)
	_props.box(Vector3(3, 4, -19), Vector3(3.4, 3.7, 4.0), CREAM, true)
	_props.box(Vector3(3, 4.7, -16.94), Vector3(2.9, 1.1, 0.05), Color(0.15, 0.36, 0.4))
	_props.beam(Vector3(-5.5, 0.4, -6), Vector3(-5.5, 11, -6), 0.5, SAFETY)
	_props.beam(Vector3(-5.5, 10.7, -6), Vector3(3.5, 10.7, -12), 0.45, SAFETY)
	_props.beam(Vector3(3.5, 10.7, -12), Vector3(3.5, 5.4, -12), 0.055, NAVY)
	_props.text(Vector3(0, 4.0, 1.5), "MERCHANT MARINE DEPOT\nCarrier fuel & cargo receiving", CREAM, 30, 75.0)
	_interact("carrier", "facility", "Marine depot · carrier deliveries", _location("carrier"))


func _build_moon_paths() -> void:
	_path([Vector2(-55, -35), Vector2(-40, -35), Vector2(-40, -10), Vector2(-23, -10), Vector2(0, -12), Vector2(28, -12), Vector2(28, -20)], 3.6)
	_path([Vector2(-15, 15), Vector2(0, 4), Vector2(0, -12)], 4.5)
	_path([Vector2(0, 4), Vector2(28, 20)], 4.0)


func _build_moon_square() -> void:
	_build_surface_pad(Vector2(0,4),6.0)
	_set_frame(Vector2(4, 4))
	_props.box(Vector3(0, 1.0, 0), Vector3(1.4, 1.7, 0.65), CREAM, true)
	_props.box(Vector3(0, 1.4, -0.34), Vector3(1.2, 0.7, 0.05), NAVY)
	_props.text(Vector3(0, 2.7, 0), str(town_info.get("name", "ROOTS & ROCKETS")).to_upper() + "\nGardens ← · Trade ↑ · Power →", Color(0.57, 0.93, 0.89), 29, 60.0)
	_interact("town_square", "board", "Lunar society · contracts & jobs", Vector2(4, 2.5))
	# Closed coolant and power lines visibly connect real facilities. They sit
	# near the ground rather than creating barriers across the EVA paths.
	_props.frame = Transform3D.IDENTITY
	for endpoint in [Vector2(-20, -20), Vector2(-15, 15), Vector2(28, 20), Vector2(-55, -35)]:
		_props.beam(_point(Vector2(28, -20), 0.16), _point(endpoint, 0.16), 0.1, SAFETY)


func _build_greenhouse() -> void:
	_set_frame(Vector2(-23, -21))
	_props.box(Vector3(0, 0.04, 0), Vector3(25, 0.08, 18), Color(0.3, 0.34, 0.35))
	for x in [-12.0, 12.0]:
		_props.box(Vector3(x, 1.0, 0), Vector3(0.6, 2.0, 18), CREAM, true)
		for z in [-8.5, -4.0, 0.5, 5.0, 8.5]:
			_props.beam(Vector3(x, 1.9, z), Vector3(x, 3.3, z), 0.19, CREAM)
			_props.beam(Vector3(x, 3.3, z), Vector3(0, 5.9, z), 0.17, CREAM)
	_props.box(Vector3(0, 1.6, -8.8), Vector3(24, 3.1, 0.3), CREAM, true)
	# Both roof halves meet at one ridge. The prior positive slopes lifted the
	# outside edges away from their supports and looked like broken wings.
	var pitch := atan2(2.6,12.0)
	for side in [-1.0,1.0]:
		_props.box(Vector3(side*6.0,4.6,0),Vector3(sqrt(150.76)+0.15,0.18,18.0),
			CREAM,false,Vector3(0,0,-pitch*side))
		for z in [-8.5,-4.0,0.5,5.0,8.5]:
			_props.beam(Vector3(side*12.0,3.35,z),Vector3(0,5.95,z),0.12,STEEL)
	_props.box(Vector3(0,5.95,0),Vector3(0.28,0.18,18.0),STEEL)
	for x in [-5.5,5.5]:
		_props.piece("box",Vector3(x,4.5,0),Vector3(0.22,0.1,16),Color(0.86,0.6,0.85),Vector3.ZERO,0,0.35)
	_props.box(Vector3(0, 2.4, 8.8), Vector3(7.5, 0.3, 0.5), SAFETY)
	_props.text(Vector3(0, 4.2, 8.7), "CRATER GARDENS\nSealed grow cells · Exterior service aisles", CREAM, 32, 70.0)
	_utility_label = _props.text(Vector3(0, 2.9, 8.7), "", Color(0.51, 0.89, 0.84), 24, 40.0)
	_interact("lunar_greenhouse", "facility", "Greenhouse · pressure, water & crops", Vector2(-23, -10.3))


func _build_solar() -> void:
	_set_frame(_location("solar"))
	for row in range(3):
		for col in range(4):
			var at := Vector3((col - 1.5) * 4.5, 0, -3.5 - row * 5.0)
			_props.cylinder(at + Vector3(0, 1.1, 0), 0.09, 2.0, STEEL)
			if _collision_only:
				continue
			var panel := Node3D.new()
			panel.transform = _props.frame * Transform3D(Basis.from_euler(Vector3(-0.32, 0, 0)), at + Vector3.UP * 2.0)
			add_child(panel)
			_solar_panels.append(panel)
			_props.dynamic_piece("box", Vector3.ZERO, Vector3(4.0, 0.11, 3.5), STEEL, panel)
			_props.dynamic_piece("box", Vector3(0, 0.065, 0), Vector3(3.85, 0.025, 3.35), Color(0.035, 0.09, 0.19), panel)
			for x in [-1.25, -0.62, 0.0, 0.62, 1.25]:
				_props.dynamic_piece("box", Vector3(x, 0.087, 0), Vector3(0.025, 0.01, 3.36), Color(0.3, 0.48, 0.6), panel)
			for z in [-0.82, 0.0, 0.82]:
				_props.dynamic_piece("box", Vector3(0, 0.087, z), Vector3(3.86, 0.01, 0.025), Color(0.3, 0.48, 0.6), panel)
	_props.box(Vector3(-6, 1.1, 2.4), Vector3(4.0, 2.2, 2.1), CREAM, true)
	_props.box(Vector3(-6, 1.35, 3.47), Vector3(2.6, 0.7, 0.04), NAVY)
	_props.text(Vector3(0, 4.3, 1.0), "SUNFLOWER POWER ARRAY", CREAM, 29, 70.0)
	_solar_label = _props.text(Vector3(0, 3.2, 1.0), "", Color(0.62, 0.96, 0.85), 25, 45.0)
	_interact("solar_array", "facility", "Solar farm · generation & batteries", _location("solar") + Vector2(0, 1.4))


func _build_habitat() -> void:
	_set_frame(_location("habitat") + Vector2(0, 5))
	_props.box(Vector3(0, 0.22, 0), Vector3(17, 0.44, 11), STEEL, true)
	for x in [-5.0, 5.0]:
		_props.cylinder(Vector3(x, 2.8, 0), 2.8, 10.0, CREAM, true, Vector3(PI * 0.5, 0, 0))
		for z in [-4.0, 0.0, 4.0]:
			_props.cylinder(Vector3(x, 2.8, z), 2.87, 0.22, STEEL, false, Vector3(PI * 0.5, 0, 0))
		_props.cylinder(Vector3(x, 2.8, -5.03), 1.2, 0.12, Color(0.13, 0.29, 0.37), false, Vector3(PI * 0.5, 0, 0))
	_props.box(Vector3(0, 1.8, 0), Vector3(5.5, 3.2, 4.3), CREAM, true)
	_props.box(Vector3(0, 1.6, -2.2), Vector3(1.5, 2.8, 0.2), NAVY)
	_props.text(Vector3(0, 5.0, -4), "FIRST LANDING HABITAT\nCrew quarters · Recreation · Meals", CREAM, 28, 65.0)
	_interact("habitat", "facility", "Lunar habitat · crew wellbeing", _location("habitat") + Vector2(0, -2))


func _build_lunar_market() -> void:
	_set_frame(_location("moon_market") + Vector2(0, -3.5))
	_props.box(Vector3(0, 1.1, 0), Vector3(7.0, 2.0, 3.6), CREAM, true)
	_props.box(Vector3(0, 2.1, 0), Vector3(7.4, 0.22, 4.1), STEEL)
	_props.box(Vector3(0, 1.3, 1.83), Vector3(4.0, 0.8, 0.06), NAVY)
	_props.text(Vector3(0, 3.6, 1.7), "EARTHRISE EXCHANGE\nLunar food & freight market", Color(0.62, 0.94, 0.87), 29, 60.0)
	_interact("moon_market", "market", "Moon market · finite food & freight", _location("moon_market"))


func _build_lunar_cargo() -> void:
	var center := _location("cargo") + Vector2(0, 7)
	_build_surface_pad(center, 10.5)
	_props.frame = Transform3D.IDENTITY
	for axis in [Vector2(1, 0), Vector2(0, 1)]:
		for index in range(12):
			_props.beam(_point(center + axis * (-3.0 + index * 0.5), 0.14), _point(center + axis * (-2.5 + index * 0.5), 0.14), 0.13, SAFETY)
	for angle in range(8):
		var a := angle * TAU / 8.0
		_props.piece("sphere", _point(center + Vector2(cos(a), sin(a)) * 10, 0.3), Vector3(0.25, 0.22, 0.25), Color(0.6, 0.91, 0.86), Vector3.ZERO, 0, 0.35)
	for x in [-6.0, -3.5, 3.5, 6.0]:
		_set_frame(center + Vector2(x, 3))
		_crate(Vector3(0, 0.13, 0), 1.8)
	_set_frame(center)
	_props.text(Vector3(0, 3.5, -7), "ORBITAL CARGO PAD\nManifested imports & exports", CREAM, 29, 70.0)
	_interact("cargo", "facility", "Lunar cargo pad · interworld freight", _location("cargo"))


func _build_ice_plant() -> void:
	_set_frame(_location("ice_mine") + Vector2(0, -4))
	_props.box(Vector3(0, 0.14, 0), Vector3(12.0, 0.28, 9.0), STEEL)
	for x in [-3.2, 3.2]:
		_props.cylinder(Vector3(x, 2.1, 0), 1.8, 4.2, CREAM, true)
		_props.cylinder(Vector3(x, 3.6, 0), 1.85, 0.3, Color(0.28, 0.51, 0.6))
	_props.beam(Vector3(-3.2, 2, 1.9), Vector3(3.2, 2, 1.9), 0.25, STEEL)
	_props.box(Vector3(0, 1, 2.7), Vector3(2.0, 1.8, 1.3), NAVY, true)
	_props.text(Vector3(0, 5.0, 0), "WATER RECOVERY WORKS\nClosed-loop irrigation · Ice supply", CREAM, 27, 60.0)
	_interact("ice_mine", "facility", "Lunar water recovery", _location("ice_mine"))


func _build_plot(id: String) -> void:
	var data: Dictionary = _state().get("plots", {}).get(id, {})
	var xz := _plot_coordinates(str(id), data)
	_set_frame(xz)
	var soil := Color(0.24, 0.15, 0.085)
	var border := CREAM if planet == "moon" else BAMBOO
	_props.box(Vector3(0, 0.12, 0), Vector3(4.7, 0.24, 4.1), soil)
	for x in [-2.35, 2.35]:
		_props.box(Vector3(x, 0.21, 0), Vector3(0.1, 0.35, 4.3), border)
	for z in [-2.1, 2.1]:
		_props.box(Vector3(0, 0.21, z), Vector3(4.8, 0.35, 0.1), border)
	for x in [-1.5, 0.0, 1.5]:
		_props.box(Vector3(x, 0.255, 0), Vector3(0.08, 0.06, 4.0), Color(0.26, 0.31, 0.3))
	if planet == "moon":
		# Each pressure-rated grow cell is closed independently. External
		# glove/service hatches let EVA workers tend and harvest from the
		# real aisle without ever opening the growing atmosphere to vacuum.
		var glass := Color(0.26, 0.59, 0.66, 0.19)
		for x in [-2.32, 2.32]:
			_props.box(Vector3(x, 1.3, 0), Vector3(0.055, 2.3, 4.1), glass, true)
			for z in [-2.0, 2.0]:
				_props.box(Vector3(x, 1.3, z), Vector3(0.09, 2.4, 0.09), CREAM)
		for z in [-2.04, 2.04]:
			_props.box(Vector3(0, 1.3, z), Vector3(4.7, 2.3, 0.055), glass, true)
		_props.box(Vector3(0, 2.5, 0), Vector3(4.8, 0.13, 4.25), CREAM, true)
		_props.box(Vector3(0, 0.73, 2.085), Vector3(1.45, 0.9, 0.08), NAVY)
		_props.box(Vector3(0, 0.73, 2.14), Vector3(1.15, 0.62, 0.06), CREAM)
		_props.box(Vector3(0.43, 0.73, 2.18), Vector3(0.065, 0.25, 0.04), SAFETY)
		for x in [-0.4, 0.4]:
			_props.cylinder(Vector3(x, 1.55, 2.09), 0.16, 0.09, NAVY, false, Vector3(PI * 0.5, 0, 0))
		_props.piece("box", Vector3(0, 2.36, 0), Vector3(0.18, 0.055, 3.7), Color(0.85, 0.55, 0.8), Vector3.ZERO, 0.0, 0.4)
	if _collision_only:
		return
	var root := Node3D.new()
	root.name = "Crop_%s" % id
	root.transform = _props.frame
	add_child(root)
	plot_roots[id] = root
	var label := _props.text(Vector3(0, 1.0, 2.5), "", CREAM, 23, 19.0)
	_plots[id] = {"root": root, "label": label, "crop": "", "stage": -1, "health": -1}
	_interact(str(id), "plot", "%s crop bed" % ("Cooperative" if bool(data.get("automatic", false)) else "Your"), xz + Vector2(0, 2.5))

func _plot_coordinates(id: String, data: Dictionary) -> Vector2:
	var coordinates: Variant = data.get("position", null)
	if coordinates is Array and coordinates.size() >= 2:
		return Vector2(float(coordinates[0]), float(coordinates[1]))
	var number := maxi(int(id.get_slice("_", id.get_slice_count("_") - 1)) - 1, 0)
	if planet == "moon":
		return Vector2(-30, -20 + number * 5) if id.begins_with("lunar_coop") else Vector2(-20 + (number % 2) * 5, -20 + (number / 2) * 5)
	return Vector2(-50 + (number % 2) * 6, -35 + (number / 2) * 6) if id.begins_with("coop") else Vector2(-35 + (number % 3) * 6, -35 + (number / 3) * 6)


func _refresh_state() -> void:
	var state := _state()
	for id in _plots:
		var data: Dictionary = state.get("plots", {}).get(id, {})
		var view: Dictionary = _plots[id]
		var crop := str(data.get("crop", ""))
		var growth := clampf(float(data.get("growth", 0.0)), 0.0, 1.0)
		var stage := int(growth * 4.0)
		var health := int(float(data.get("health", 1.0)) * 3.0)
		if crop != view.crop or stage != view.stage or health != view.health:
			view.crop = crop
			view.stage = stage
			view.health = health
			if str(id) not in _crop_jobs:
				_crop_jobs.append(str(id))
		var moisture := float(data.get("moisture", 0.0))
		var phase: String = FrontierCropMeshes.phase_label(crop,stage)
		var status := "Ready to harvest" if growth >= 1.0 else "%s · %d%%" % [phase, roundi(growth * 100)]
		if crop.is_empty():
			status = "Empty bed · choose a crop"
		elif moisture < 25.0:
			status += " · needs water"
		if not crop.is_empty() and float(data.get("health", 1.0)) <= 0.0:
			status = "Crop lost · clear and replant"
		view.label.text = "%s\n%s" % [crop.replace("_", " ").capitalize() if not crop.is_empty() else "Planting bed", status]
		view.label.modulate = Color(0.78, 1.0, 0.58) if growth >= 1.0 else CREAM
	if _oil_arm != null:
		_oil_working = false
		var oil: Dictionary = state.facilities.oil_rig
		var stock: Dictionary = state.inventories.oil_rig
		if float(oil.condition) >= 0.3 and int(oil.reserve) >= 8 and int(stock.get("diesel", 0)) > 0 and int(stock.get("water", 0)) > 0:
			for worker: Dictionary in state.citizens.values():
				if worker.get("_job", {}).get("op", "") == "extract" and worker.route.is_empty() and float(worker.work_remaining) > 0.0 and str(worker.get("route_blocked", "")).is_empty():
					_oil_working = true
					break
	if _solar_label != null:
		var facilities: Dictionary = state.get("facilities", {})
		var solar: Dictionary = facilities.get("solar_array", {})
		var moon: Dictionary = facilities.get("lunar_greenhouse", {})
		var generated := float(solar.get("power_kw", 0.0))
		var battery := float(moon.get("battery_kwh", 0.0))
		for index in range(_solar_panels.size()):
			_solar_panels[index].visible = index < int(solar.get("panels", 2))
		_solar_label.text = "%.1f kW generation · %.1f kWh stored" % [generated, battery]
		if _utility_label != null:
			_utility_label.text = "%.0f L water · %.0f kPa · %s" % [float(moon.get("water_l", 0.0)), float(moon.get("pressure", 1.0)) * 101.3, "POWERED" if bool(moon.get("powered", true)) else "POWER DEFICIT"]


func _rebuild_crop(root: Node3D, crop: String, growth: float, health: float) -> void:
	for child in root.get_children():
		root.remove_child(child)
		child.queue_free()
	if not crop.is_empty():
		FrontierCropMeshes.populate(root, crop, growth, health)


func _build_citizen(id: String) -> void:
	var citizen := FrontierCitizen.new()
	citizen.configure(id, _simulation, _host, planet)
	add_child(citizen)
	citizen.build()
	citizens[id] = citizen


func _path(points: Array, width: float) -> void:
	if _collision_only:
		return
	_props.frame = Transform3D.IDENTITY
	var road := Color(0.52, 0.43, 0.28) if planet == "earth" else Color(0.14, 0.18, 0.21)
	_build_surface_path(points, width, road, planet=="earth")


func _build_surface_path(points: Array, width: float, color: Color, footpath := false) -> void:
	if _collision_only: return
	for segment in range(points.size()-1):
		var start: Vector2 = points[segment]
		var finish: Vector2 = points[segment+1]
		var direction := (finish-start).normalized()
		var side := Vector2(direction.y,-direction.x)*width*0.5
		var steps := maxi(ceili(start.distance_to(finish)/0.8),1) if planet=="moon" else 1
		for step in range(steps):
			var a := start.lerp(finish,float(step)/steps)
			var b := start.lerp(finish,float(step+1)/steps)
			_paving.add(PackedVector2Array([a-side,a+side,b+side,b-side]),color,0.075,
				10 if footpath or planet=="moon" else 50,"footpath" if footpath else "street")
			if planet=="moon" and step%14==0:
				_props.piece("sphere",_point(a+side,0.22),Vector3(0.17,0.25,0.17),Color(0.45,0.85,0.84),Vector3.ZERO,0,0.25)


func _build_surface_pad(center: Vector2, radius: float, color := NAVY,
		priority := 25, lift := 0.09) -> void:
	if _collision_only: return
	var polygon := PackedVector2Array()
	for sector in range(48):
		var angle := sector*TAU/48.0
		polygon.append(center+Vector2(cos(angle),sin(angle))*radius)
	_paving.add(polygon,color,lift,priority,"pad")


func _queue_ground_rectangle(center: Vector2, size: Vector2, color: Color, lift: float) -> void:
	if _collision_only: return
	var half := size*0.5
	_paving.add(PackedVector2Array([center-half,center+Vector2(half.x,-half.y),
		center+half,center+Vector2(-half.x,half.y)]),color,lift,20,"forecourt")


func _emit_paving(piece: Dictionary) -> void:
	var vertices := PackedVector3Array()
	var polygon: PackedVector2Array = piece.polygon
	if planet=="moon" and polygon.size()>7:
		var center := Vector2.ZERO
		for point in polygon: center += point
		center /= polygon.size()
		for index in range(polygon.size()):
			_append_ground_triangle(vertices,center,polygon[(index+1)%polygon.size()],polygon[index],float(piece.lift))
	else:
		for index in range(1,polygon.size()-1):
			_append_ground_triangle(vertices,polygon[0],polygon[index+1],polygon[index],float(piece.lift))
	var indices := PackedInt32Array()
	for index in range(vertices.size()): indices.append(index)
	_surface_mesh("ExclusiveTownPaving",vertices,indices,piece.color)


func _append_ground_triangle(vertices: PackedVector3Array, a: Vector2, b: Vector2,
		c: Vector2, lift: float, depth := 0) -> void:
	if absf((b-a).cross(c-a))<0.00001:
		return
	# Curved lunar ground retains tessellation after clipping. Earth towns are
	# graded flat, so their exclusive polygons need no redundant interior grid.
	if planet=="moon" and depth<6 and maxf(a.distance_to(b),maxf(b.distance_to(c),c.distance_to(a)))>1.4:
		var ab := (a+b)*0.5
		var bc := (b+c)*0.5
		var ca := (c+a)*0.5
		_append_ground_triangle(vertices,a,ab,ca,lift,depth+1)
		_append_ground_triangle(vertices,ab,b,bc,lift,depth+1)
		_append_ground_triangle(vertices,ca,bc,c,lift,depth+1)
		_append_ground_triangle(vertices,ab,bc,ca,lift,depth+1)
	else:
		if (b-a).cross(c-a)>0.0:
			vertices.append_array(PackedVector3Array([_point(a,lift),_point(c,lift),_point(b,lift)]))
		else:
			vertices.append_array(PackedVector3Array([_point(a,lift),_point(b,lift),_point(c,lift)]))


func _surface_mesh(node_name: String, vertices: PackedVector3Array,
		indices: PackedInt32Array, color: Color) -> void:
	if _collision_only or indices.is_empty():
		return
	var key := color.to_html()
	if not _surface_batches.has(key):
		_surface_batches[key] = {"name":node_name,"color":color,
			"vertices":PackedVector3Array(),"indices":PackedInt32Array()}
	var batch: Dictionary = _surface_batches[key]
	var offset: int = batch.vertices.size()
	batch.vertices.append_array(vertices)
	for index in indices:
		batch.indices.append(index+offset)


func _flush_surface_step() -> void:
	var key: String = _surface_batches.keys()[0]
	var batch: Dictionary = _surface_batches[key]
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var paving_surface: bool = str(batch.name)=="ExclusiveTownPaving"
	for vertex in batch.vertices:
		if paving_surface:
			var normal := Vector3.UP
			if _host.has_method("surface_normal"):
				normal = _host.call("surface_normal",vertex.x,vertex.z)
			surface.set_normal(normal)
		surface.add_vertex(vertex)
	for index in range(0,batch.indices.size(),3):
		surface.add_index(batch.indices[index])
		surface.add_index(batch.indices[index+2])
		surface.add_index(batch.indices[index+1])
	if not paving_surface:
		surface.generate_normals()
	var node := MeshInstance3D.new()
	node.name = "%s_%s" % [str(batch.name),key]
	node.mesh = surface.commit()
	node.material_override = FrontierProps.material(batch.color)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_end = 520.0
	add_child(node)
	_surface_batches.erase(key)


func _tree(xz: Vector2) -> void:
	_set_frame(xz)
	_props.cylinder(Vector3(0, 3.5, 0), 0.29, 7.0, WOOD, true)
	for index in range(5):
		var angle := index * TAU / 5.0
		_props.beam(Vector3(0, 4.0, 0), Vector3(cos(angle) * 1.5, 6.5, sin(angle) * 1.5), 0.18, WOOD)
		_props.piece("sphere", Vector3(cos(angle) * 1.6, 7.0, sin(angle) * 1.6), Vector3(4.1, 2.8, 4.0), LEAF)


func _crate(at: Vector3, size: float) -> void:
	_props.box(at + Vector3.UP * size * 0.5, Vector3.ONE * size, BAMBOO, true)
	for x in [-0.38, 0.38]:
		_props.box(at + Vector3(x * size, size * 0.5, size * 0.51), Vector3(0.09, 0.98, 0.04) * size, WOOD)
	_props.box(at + Vector3(0, size * 0.5, size * 0.535), Vector3(0.95, 0.09, 0.04) * size, WOOD, false, Vector3(0, 0, 0.65))


func _planter(at: Vector3) -> void:
	_props.cylinder(at + Vector3.UP * 0.3, 0.38, 0.6, Color(0.63, 0.33, 0.19))
	for index in range(4):
		var angle := index * TAU / 4.0
		_props.piece("sphere", at + Vector3(cos(angle) * 0.16, 0.7, sin(angle) * 0.16), Vector3(0.5, 0.13, 0.24), LEAF, Vector3(0, angle, -0.2))


func _bench(at: Vector3) -> void:
	_props.box(at + Vector3(0, 0.5, 0), Vector3(2.6, 0.14, 0.65), WOOD, true)
	_props.box(at + Vector3(0, 0.95, 0.3), Vector3(2.6, 0.5, 0.09), BAMBOO)
	for x in [-0.95, 0.95]:
		_props.box(at + Vector3(x, 0.25, 0), Vector3(0.13, 0.5, 0.6), BAMBOO)


func _pennant_span(start: Vector2, finish: Vector2) -> void:
	_props.frame = Transform3D.IDENTITY
	var a := _point(start, 4.0)
	var b := _point(finish, 4.0)
	for end in [a, b]:
		_props.cylinder(end - Vector3.UP * 2.0, 0.07, 4.0, BAMBOO)
	for index in range(12):
		var fraction := index / 12.0
		var next_fraction := (index + 1) / 12.0
		var from := a.lerp(b, fraction) - Vector3.UP * sin(fraction * PI) * 0.8
		var to := a.lerp(b, next_fraction) - Vector3.UP * sin(next_fraction * PI) * 0.8
		_props.beam(from, to, 0.025, BAMBOO)
		_props.piece("cone", from - Vector3.UP * 0.24, Vector3(0.33, 0.5, 0.04), [TEAL, SAFETY, Color(0.7, 0.26, 0.16)][index % 3], Vector3(0, 0, PI))


func _build_street(start: Vector2, finish: Vector2, width: float) -> void:
	_props.frame = Transform3D.IDENTITY
	_build_surface_path([start, finish], width, Color(0.28,0.31,0.29))
	var direction := (finish-start).normalized()
	var side := Vector2(direction.y,-direction.x)
	var length := start.distance_to(finish)
	# Broken center lines stop before every graph junction and loading bay.
	var distance := 5.0
	while distance < length-5.0:
		var end := minf(distance+2.1,length-5.0)
		var a := start+direction*distance
		var b := start+direction*end
		_street_strip(a,b,0.13,Color(0.88,0.78,0.48),0.105)
		distance += 5.2
	# Sidewalks are interrupted around the well, homes and community tree.
	for sign_value: float in [-1.0,1.0]:
		var steps := maxi(ceili(length/1.5),1)
		for step in range(steps):
			var a := start.lerp(finish,float(step)/steps)+side*sign_value*(width*0.5+0.65)
			var b := start.lerp(finish,float(step+1)/steps)+side*sign_value*(width*0.5+0.65)
			if _props.has_ground_clearance((a+b)*0.5,0.75) and _road_distance((a+b)*0.5)>width*0.5+0.05:
				var shoulder := side*0.55
				_paving.add(PackedVector2Array([a-shoulder,a+shoulder,b+shoulder,b-shoulder]),
					Color(0.59,0.55,0.43),0.13,40,"sidewalk")


func _street_strip(start: Vector2, finish: Vector2, width: float, color: Color, lift: float) -> void:
	var direction := (finish-start).normalized()
	var side := Vector2(direction.y,-direction.x)*width*0.5
	var points := PackedVector3Array([_point(start-side,lift),_point(start+side,lift),
		_point(finish-side,lift),_point(finish+side,lift)])
	_surface_mesh("StreetMarking",points,PackedInt32Array([0,2,1,1,2,3]),color)


func _road_distance(point: Vector2) -> float:
	var nearest := INF
	for segment: Dictionary in FrontierRoutes.road_segments():
		var close := Geometry2D.get_closest_point_to_segment(point,segment["from"],segment.to)
		nearest = minf(nearest,point.distance_to(close))
	return nearest


func _build_forest_row(row: int) -> void:
	# Deterministic placement shares exactly the same trunk colliders on server
	# and clients. Roads, service aisles and interactables stay clear.
	for column in range(-8,9):
		var x := column*10.5 + sin(float(row*17+column*11))*2.5
		var z := row*10.5 + cos(float(row*23-column*7))*2.5
		var xz := Vector2(x,z)
		if xz.length()<12 or (xz.x>-63 and xz.x<-17 and xz.y>-49 and xz.y<-19):
			continue
		if _road_distance(xz)<7.2 or not _props.has_ground_clearance(xz,4.0):
			continue
		var blocked := false
		for bay: Vector2 in FrontierRoutes.loading_bays().values():
			if xz.distance_to(bay)<9.0:
				blocked = true
		for bay: Vector2 in FrontierRoutes.service_parking_bays().values():
			if xz.distance_to(bay)<5.0:
				blocked = true
		for entry in _interactions:
			if Vector2(entry.position.x,entry.position.z).distance_to(xz)<5.0:
				blocked = true
				break
		for point in tree_positions:
			if point.distance_to(xz)<7.0:
				blocked = true
		if not blocked:
			tree_positions.append(xz)
			_tree(xz)


func _build_loading_bay(id: String) -> void:
	if id in ["town_square","player_earth","cooperative","water","kitchen","earth_market"]:
		return
	var center: Vector2 = FrontierRoutes.loading_bays()[id]
	if _props.has_ground_clearance(center,7.3):
		_build_surface_pad(center,7.3,Color(0.28,0.31,0.29))
	# Actual driver's stopping area, shared with the vehicle graph. Insets
	# are painted on the graded collider instead of adding raised blockers.
	for side in [-1.6,1.6]:
		_street_strip(center+Vector2(side,-3.1),center+Vector2(side,3.1),0.1,SAFETY,0.115)
	_street_strip(center+Vector2(-1.6,-3.1),center+Vector2(1.6,-3.1),0.1,SAFETY,0.115)


func _town_accent(fallback: Color) -> Color:
	var tint: Variant = town_info.get("color",null)
	if tint is Color: return fallback.lerp(tint,0.5)
	if tint is String and Color.html_is_valid(tint): return fallback.lerp(Color(tint),0.5)
	var society := str(town_info.get("society_id",""))
	if society=="harbor": return fallback.lerp(Color(0.17,0.44,0.65),0.5)
	if society=="ridge": return fallback.lerp(Color(0.68,0.34,0.17),0.5)
	return fallback
