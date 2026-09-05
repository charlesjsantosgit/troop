class_name CityInterior
extends Node3D
## One bounded, reusable room. The controller owns its world position and entry
## authorization; this node owns furniture, collision and nearby service points.
signal interaction_requested(kind: String, property_id: String)

const INTERACTION_RANGE := 2.9
const DOOR_WIDTH := 1.8
const DOOR_HEIGHT := 2.5
var property: Dictionary = {}
var dimensions := Vector3(8, 3.2, 7)
var _spawn := Vector3.ZERO
var _exit := Vector3.ZERO
var _services: Dictionary = {}
var _body: StaticBody3D
var _batches: Dictionary = {}
var _materials: Dictionary = {}

func build(data: Dictionary) -> void:
	property = data.duplicate(true)
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_batches.clear()
	_materials.clear()
	_services.clear()
	var housing := housing_type(data)
	var warehouse := housing == "warehouse"
	var premium := housing == "penthouse"
	var apartment := housing in ["town_apartment", "city_apartment", "penthouse"]
	var public_room := housing.is_empty()
	dimensions = room_dimensions(data)
	_services = service_layout(data)
	_body = StaticBody3D.new()
	_body.name = "RoomCollision"
	_body.collision_layer = 1
	_body.collision_mask = 1
	add_child(_body)
	var width := dimensions.x
	var depth := dimensions.z
	var height := dimensions.y
	# The front wall is split around a real 1.8 m opening. No collision slab
	# crosses the opening, and the floor has thickness rather than coplanar skins.
	_box("floor", Vector3(width, 0.24, depth), Vector3(0, -0.12, 0), Color("887456"), true)
	_box("rear wall", Vector3(width, height, 0.18), Vector3(0, height * 0.5, depth * 0.5), Color("d6cabb"), true)
	for sign_x in [-1.0, 1.0]:
		_box("side wall", Vector3(0.18, height, depth), Vector3(sign_x * width * 0.5, height * 0.5, 0), Color("c6b9a8"), true)
		var side_width := (width - DOOR_WIDTH) * 0.5
		_box("front wall", Vector3(side_width, height, 0.18), Vector3(sign_x * (DOOR_WIDTH + side_width) * 0.5, height * 0.5, -depth * 0.5), Color("d6cabb"), true)
		_box("door jamb", Vector3(0.12, DOOR_HEIGHT, 0.27), Vector3(sign_x * (DOOR_WIDTH * 0.5 + 0.02), DOOR_HEIGHT * 0.5, -depth * 0.5), Color("5a4332"))
	_box("door lintel", Vector3(DOOR_WIDTH, height - DOOR_HEIGHT, 0.2), Vector3(0, DOOR_HEIGHT + (height - DOOR_HEIGHT) * 0.5, -depth * 0.5), Color("c6b9a8"), true)
	_box("ceiling", Vector3(width, 0.16, depth), Vector3(0, height + 0.08, 0), Color("e8dfcc"), true)
	# A small enclosed entrance landing catches the player even before the
	# controller wires the exit. It is local to this room, never outdoor terrain.
	_box("vestibule floor", Vector3(2.2, 0.24, 2.0), Vector3(0, -0.12, -depth * 0.5 - 1.0), Color("706452"), true)
	for sign_x in [-1.0, 1.0]:
		_box("vestibule side", Vector3(0.15, height, 2.0), Vector3(sign_x * 1.1, height * 0.5, -depth * 0.5 - 1), Color("ac9c83"), true)
	_box("exit door", Vector3(2.2, height, 0.16), Vector3(0, height * 0.5, -depth * 0.5 - 2), Color("526568"), true)
	_box("vestibule ceiling", Vector3(2.2, 0.16, 2.0), Vector3(0, height + 0.08, -depth * 0.5 - 1), Color("ded2b9"))
	_box("handle", Vector3(0.08, 0.12, 0.12), Vector3(0.65, 1.05, -depth * 0.5 - 1.85), Color("d7bb71"))
	_spawn = Vector3(0, 0.06, -depth * 0.5 + 1.6)
	_exit = Vector3(0, 0.85, -depth * 0.5 - 1.35)
	_trim(width, depth, height, public_room)
	if warehouse:
		_build_warehouse(width, depth)
	elif public_room:
		_build_service(width, depth)
	else:
		_build_home(width, depth, premium, apartment)
		if not str(data.get("service", "")).is_empty():
			_box("workplace noticeboard", Vector3(0.06, 0.85, 1.2), Vector3(width * 0.5 - 0.14, 1.65, -0.65), Color("705c45"))
			for z in [-0.34, 0.34]:
				_box("posted notice", Vector3(0.025, 0.58, 0.44), Vector3(width * 0.5 - 0.185, 1.65, -0.65 + z), Color("e9dfbd"))
			_add_service_sign("workbench", "LOCAL NOTICES", Vector3(width * 0.5 - 0.21, 2.22, -0.65), -PI * 0.5)
	_add_service_sign("exit", "OUTSIDE", Vector3(0, 2.0, -depth * 0.5 - 1.88), 0.0)
	for pos in [Vector3(-width * 0.22, height - 0.35, -depth * 0.1), Vector3(width * 0.22, height - 0.35, depth * 0.25)]:
		_box("ceiling mount", Vector3(0.18, 0.06, 0.18), pos + Vector3(0, 0.31, 0), Color("514c43"))
		_box("lamp stem", Vector3(0.025, 0.17, 0.025), pos + Vector3(0, 0.22, 0), Color("514c43"))
		_sphere("lamp shade", Vector3(0.55, 0.21, 0.55), pos + Vector3(0, 0.1, 0), Color("e9e1d0"))
	_flush_meshes()
	for pos in [Vector3(-width * 0.22, height - 0.35, -depth * 0.1), Vector3(width * 0.22, height - 0.35, depth * 0.25)]:
		var lamp := OmniLight3D.new()
		lamp.name = "WarmRoomLight"
		lamp.position = pos
		lamp.light_color = Color("ffdcaa")
		lamp.light_energy = 1.1
		lamp.omni_range = maxf(width, depth) * 0.9
		lamp.shadow_enabled = false
		add_child(lamp)

static func housing_type(data: Dictionary) -> String:
	var housing := str(data.get("tier", data.get("housing", data.get("type", ""))))
	if housing in ["work_live", "staff_residence"]: return "city_apartment"
	if housing == "town_house": return "suburban_home"
	return housing

static func room_dimensions(data: Dictionary) -> Vector3:
	var size := Vector3(8, 3.2, 7)
	match housing_type(data):
		"warehouse": size = Vector3(18, 5.4, 14)
		"penthouse": size = Vector3(16, 3.6, 12)
		"city_apartment": size = Vector3(12, 3.4, 10)
		"suburban_home": size = Vector3(10, 3.2, 9)
		"town_apartment": size = Vector3(9, 3.2, 8)
		"": size = Vector3(12, 3.4, 10)
	if data.get("interior_size") is Vector3:
		var requested: Vector3 = data.interior_size
		size = Vector3(clampf(requested.x, 7, 30), clampf(requested.y, 3.0, 6.0), clampf(requested.z, 7, 28))
	return size

static func service_layout(data: Dictionary) -> Dictionary:
	var size := room_dimensions(data)
	var width := size.x
	var depth := size.z
	var housing := housing_type(data)
	var result := {"exit": {"position": Vector3(0, 0.85, -depth * 0.5 - 1.35), "prompt": "Return outside", "kind": "exit"}}
	if housing == "warehouse":
		result.storage = {"position": Vector3(width * 0.5 - 3.0, 0.8, 0), "prompt": "Open warehouse storage", "kind": "storage"}
		result.workbench = {"position": Vector3(width * 0.5 - 1.5, 0.8, -depth * 0.5 + 1.1), "prompt": "Warehouse details", "kind": "interior"}
	elif housing.is_empty():
		result.frontdesk = {"position": Vector3(-width * 0.25, 0.85, depth * 0.5 - 2.75), "prompt": "Read the local noticeboard", "kind": "interior"}
	else:
		result.bed = {"position": Vector3(-width * 0.5 + 2.45, 0.8, depth * 0.5 - 1.75), "prompt": "Make this your home", "kind": "bed"}
		result.storage = {"position": Vector3(width * 0.5 - 1.05, 0.8, depth * 0.5 - 1.85), "prompt": "Open home storage", "kind": "storage"}
		result.workbench = {"position": Vector3(width * 0.5 - 2.2, 0.8, -0.65), "prompt": "Property and local notices" if not str(data.get("service", "")).is_empty() else "Property details", "kind": "interior"}
	for point in result.values(): point["label"] = point.prompt
	return result

func spawn_point() -> Vector3:
	return _spawn

func spawn_yaw() -> float:
	return PI

func exit_point() -> Vector3:
	return _exit

func service_points() -> Dictionary:
	var result := _services.duplicate(true)
	for point in result.values(): point["label"] = point.get("prompt", point.get("kind", ""))
	return result

func nearest_interaction(world_point: Vector3, reach: float = INTERACTION_RANGE) -> Dictionary:
	var nearest: Dictionary = {}
	var distance := minf(reach, INTERACTION_RANGE)
	for kind: String in _services:
		var point: Vector3 = to_global(_services[kind].position)
		var candidate := world_point.distance_to(point)
		if candidate <= distance:
			distance = candidate
			nearest = _services[kind].duplicate(true)
			nearest["position"] = point
			nearest["property_id"] = str(property.get("id", ""))
	return nearest

func interact(kind: String, actor_world_position: Vector3) -> bool:
	for key: String in _services:
		var point: Dictionary = _services[key]
		if key != kind and str(point.kind) != kind: continue
		if actor_world_position.distance_to(to_global(point.position)) > INTERACTION_RANGE: continue
		interaction_requested.emit(str(point.kind), str(property.get("id", "")))
		return true
	return false

func _trim(width: float, depth: float, height: float, public_room := false) -> void:
	for side in [-1.0, 1.0]:
		_box("skirting", Vector3(0.1, 0.16, depth - 0.2), Vector3(side * (width * 0.5 - 0.1), 0.08, 0), Color("584b3d"))
		_box("ceiling beam", Vector3(0.16, 0.18, depth), Vector3(side * width * 0.27, height - 0.1, 0), Color("776249"))
	_box("skirting", Vector3(width - 0.2, 0.16, 0.1), Vector3(0, 0.08, depth * 0.5 - 0.1), Color("584b3d"))
	# Glazed panels sit proud of the wall so there is no z-fighting.
	# The public noticeboard occupies the left rear wall; a window there would
	# overlap its cork and paper surfaces.
	var windows := [width * 0.26] if public_room else [-width * 0.26, width * 0.26]
	for x in windows:
		_box("window surround", Vector3(1.9, 1.55, 0.12), Vector3(x, 1.85, depth * 0.5 - 0.16), Color("725c45"))
		_box("window glass", Vector3(1.66, 1.28, 0.04), Vector3(x, 1.85, depth * 0.5 - 0.24), Color("728f9c"))
		_box("window mullion", Vector3(0.07, 1.34, 0.05), Vector3(x, 1.85, depth * 0.5 - 0.275), Color("d8caa6"))
		_box("window sill", Vector3(2.0, 0.1, 0.28), Vector3(x, 1.13, depth * 0.5 - 0.25), Color("92795a"))

func _build_home(width: float, depth: float, premium: bool, apartment: bool) -> void:
	var bed := Vector3(-width * 0.5 + 1.25, 0, depth * 0.5 - 1.5)
	_box("bed frame", Vector3(1.75, 0.34, 2.4), bed + Vector3(0, 0.3, 0), Color("664832"), true)
	_box("mattress", Vector3(1.65, 0.25, 2.22), bed + Vector3(0, 0.59, 0), Color("e9e1d0"))
	_box("duvet", Vector3(1.68, 0.15, 1.7), bed + Vector3(0, 0.79, -0.24), Color("728c7c"))
	for x in [-0.42, 0.42]:
		_box("pillow", Vector3(0.65, 0.17, 0.47), bed + Vector3(x, 0.82, 0.77), Color("f4edde"))
	_box("headboard", Vector3(1.85, 0.95, 0.15), bed + Vector3(0, 0.78, 1.15), Color("664832"))
	_add_service_sign("bed", "HOME", bed + Vector3(0, 1.65, 1.1), PI)
	var storage := Vector3(width * 0.5 - 0.8, 0, depth * 0.5 - 0.85)
	_shelf(storage, 1.35, false)
	_add_service_sign("storage", "STORAGE", storage + Vector3(0, 1.95, -0.38), PI)
	var bench := Vector3(width * 0.5 - 0.85, 0, -0.65)
	_workbench(bench)
	# Kitchen and dining furniture remain against the perimeter; the central
	# 2.2 m path from entrance to the back of the room stays unobstructed.
	var kitchen := Vector3(-width * 0.5 + 0.55, 0, -0.9)
	_box("kitchen cupboard", Vector3(0.9, 0.88, 2.2), kitchen + Vector3(0, 0.44, 0), Color("a18b68"), true)
	_box("counter", Vector3(1.0, 0.09, 2.35), kitchen + Vector3(0, 0.92, 0), Color("ded5bd"))
	_box("sink", Vector3(0.65, 0.035, 0.7), kitchen + Vector3(0.05, 0.985, 0.35), Color("5a6465"))
	_box("tap", Vector3(0.045, 0.24, 0.05), kitchen + Vector3(-0.25, 1.1, 0.5), Color("b0b4af"))
	_box("cooktop", Vector3(0.64, 0.04, 0.6), kitchen + Vector3(0, 0.985, -0.6), Color("343c40"))
	for offset in [-0.15, 0.15]:
		_sphere("hotplate", Vector3(0.19, 0.015, 0.19), kitchen + Vector3(offset, 1.025, -0.6), Color("23292b"))
	_box("rug", Vector3(2.4, 0.025, 2.3), Vector3(0, 0.018, 0.4), Color("bb9b68"))
	if premium or apartment:
		var sofa := Vector3(width * 0.5 - 1.0, 0, -depth * 0.5 + 1.5)
		_box("sofa", Vector3(1.3, 0.43, 2.1), sofa + Vector3(0, 0.35, 0), Color("536e79"), true)
		_box("sofa back", Vector3(0.23, 0.65, 2.1), sofa + Vector3(0.58, 0.7, 0), Color("536e79"))
		for z in [-0.66, 0.0, 0.66]:
			_box("seat cushion", Vector3(0.97, 0.18, 0.59), sofa + Vector3(-0.08, 0.63, z), Color("69858b"))
	_plant(Vector3(-width * 0.5 + 0.55, 0, -depth * 0.5 + 0.7))
	if premium:
		_plant(Vector3(width * 0.5 - 0.7, 0, depth * 0.5 - 2.6))
		_box("art frame", Vector3(1.4, 0.9, 0.06), Vector3(0, 2.05, depth * 0.5 - 0.15), Color("695341"))
		_box("artwork", Vector3(1.22, 0.73, 0.025), Vector3(0, 2.05, depth * 0.5 - 0.195), Color("e2b575"))
		_build_premium_living(width, depth)

func _build_premium_living(width: float, depth: float) -> void:
	# Furnish the extra floor area as separate dining and sitting spaces, while
	# keeping the middle corridor and bed/cupboard approaches clear.
	var dining := Vector3(-width * 0.26, 0, -depth * 0.25)
	_box("dining table", Vector3(2.5, 0.13, 1.2), dining + Vector3(0, 0.8, 0), Color("97704a"))
	_collision(Vector3(2.5, 0.86, 1.2), dining + Vector3(0, 0.43, 0))
	for x in [-1.0, 1.0]:
		for z in [-0.4, 0.4]:
			_box("dining leg", Vector3(0.1, 0.76, 0.1), dining + Vector3(x, 0.38, z), Color("514c43"))
	for x in [-0.72, 0.72]:
		for z in [-1.05, 1.05]:
			var chair := dining + Vector3(x, 0, z)
			_box("dining chair", Vector3(0.55, 0.12, 0.55), chair + Vector3(0, 0.47, 0), Color("82988a"))
			_box("chair back", Vector3(0.55, 0.6, 0.09), chair + Vector3(0, 0.77, signf(z) * 0.25), Color("82988a"))
			_collision(Vector3(0.55, 1.07, 0.55), chair + Vector3(0, 0.535, 0))
			for leg_x in [-0.21, 0.21]:
				for leg_z in [-0.21, 0.21]:
					_box("chair leg", Vector3(0.065, 0.41, 0.065), chair + Vector3(leg_x, 0.22, leg_z), Color("514c43"))
	var lounge := Vector3(width * 0.26, 0, depth * 0.13)
	_box("lounge rug", Vector3(4.0, 0.025, 3.7), lounge + Vector3(0, 0.018, -0.8), Color("69858b"))
	_box("lounge sofa", Vector3(3.05, 0.43, 1.0), lounge + Vector3(0, 0.35, 0), Color("536e79"), true)
	_box("lounge back", Vector3(3.05, 0.65, 0.22), lounge + Vector3(0, 0.71, 0.46), Color("536e79"))
	for x in [-1.0, 0.0, 1.0]:
		_box("lounge cushion", Vector3(0.9, 0.18, 0.75), lounge + Vector3(x, 0.65, -0.08), Color("82988a"))
	for x in [-1.43, 1.43]:
		_box("sofa arm", Vector3(0.2, 0.3, 1.0), lounge + Vector3(x, 0.72, 0), Color("536e79"))
	_box("coffee table", Vector3(1.5, 0.12, 0.8), lounge + Vector3(0, 0.47, -1.45), Color("97704a"))
	_collision(Vector3(1.5, 0.53, 0.8), lounge + Vector3(0, 0.265, -1.45))
	for x in [-0.59, 0.59]:
		_box("coffee table support", Vector3(0.1, 0.42, 0.65), lounge + Vector3(x, 0.23, -1.45), Color("514c43"))
	_box("living room book", Vector3(0.35, 0.05, 0.26), lounge + Vector3(0.24, 0.56, -1.45), Color("47616d"))

func _build_service(width: float, depth: float) -> void:
	var counter := Vector3(-width * 0.25, 0, depth * 0.5 - 1.65)
	_box("reception counter", Vector3(3.1, 1.0, 0.9), counter + Vector3(0, 0.5, 0), Color("927452"), true)
	_box("countertop", Vector3(3.2, 0.09, 1.0), counter + Vector3(0, 1.045, 0), Color("d9caae"))
	_box("noticeboard", Vector3(2.5, 1.3, 0.12), Vector3(-width * 0.25, 1.95, depth * 0.5 - 0.2), Color("705c45"))
	for x in [-0.65, 0.0, 0.65]:
		_box("notice", Vector3(0.47, 0.65, 0.025), Vector3(-width * 0.25 + x, 1.95, depth * 0.5 - 0.28), Color("e9dfbd"))
	_add_service_sign("frontdesk", "LOCAL NOTICEBOARD", counter + Vector3(0, 1.6, 0.28), PI)
	for z in [-depth * 0.22, depth * 0.15]:
		var bench := Vector3(width * 0.5 - 0.8, 0, z)
		_box("waiting bench", Vector3(0.95, 0.12, 1.9), bench + Vector3(0, 0.51, 0), Color("82988a"), true)
		_box("bench back", Vector3(0.12, 0.65, 1.9), bench + Vector3(0.42, 0.83, 0), Color("82988a"))
		for offset in [-0.65, 0.65]:
			_box("bench support", Vector3(0.62, 0.43, 0.12), bench + Vector3(0, 0.23, offset), Color("69695f"))
	_plant(Vector3(-width * 0.5 + 0.7, 0, -depth * 0.5 + 0.8))
	_workbench(Vector3(-width * 0.5 + 1.0, 0, 0))


func _build_warehouse(width: float, depth: float) -> void:
	for side in [-1.0, 1.0]:
		for z in [-depth * 0.22, depth * 0.22]:
			_shelf(Vector3(side * (width * 0.5 - 1.2), 0, z), 2.2, true)
			for x in [-0.55, 0.55]:
				_box("storage crate", Vector3(0.8, 0.7, 0.8), Vector3(side * (width * 0.5 - 1.2) + x, 0.58, z), Color("a58a56"))
	var desk := Vector3(width * 0.5 - 1.0, 0, -depth * 0.5 + 2)
	_workbench(desk)
	_add_service_sign("storage", "WAREHOUSE / STORAGE", Vector3(width * 0.5 - 1.2, 2.4, -0.4), PI)
	for x in [-width * 0.25, width * 0.25]:
		_box("aisle marking", Vector3(0.07, 0.018, depth - 1), Vector3(x, 0.012, 0), Color("dfb862"))

func _shelf(at: Vector3, width: float, industrial: bool) -> void:
	var wood := Color("787c76") if industrial else Color("8f724e")
	for x in [-width * 0.5, width * 0.5]:
		_box("shelf upright", Vector3(0.08, 1.85, 0.7), at + Vector3(x, 0.95, 0), wood)
	for y in [0.18, 0.85, 1.6]:
		_box("shelf", Vector3(width + 0.08, 0.09, 0.75), at + Vector3(0, y, 0), wood)
	_collision(Vector3(width + 0.1, 1.85, 0.75), at + Vector3(0, 0.925, 0))
	if not industrial:
		for i in range(5):
			_box("book", Vector3(0.13, 0.35 + (i % 2) * 0.06, 0.32), at + Vector3(-0.45 + i * 0.16, 1.05, 0), Color("c7ad83") if i % 2 == 0 else Color("718f91"))
		_box("woven basket", Vector3(width * 0.75, 0.42, 0.54), at + Vector3(0, 0.43, 0), Color("c0a478"))

func _workbench(at: Vector3) -> void:
	_box("workbench top", Vector3(1.25, 0.1, 0.72), at + Vector3(0, 0.9, 0), Color("97704a"))
	for x in [-0.48, 0.48]:
		for z in [-0.25, 0.25]:
			_box("workbench leg", Vector3(0.1, 0.88, 0.1), at + Vector3(x, 0.44, z), Color("514c43"))
	_collision(Vector3(1.25, 0.95, 0.72), at + Vector3(0, 0.475, 0))
	_box("desk ledger", Vector3(0.4, 0.055, 0.29), at + Vector3(-0.2, 0.99, 0), Color("47616d"))
	_box("tool tray", Vector3(0.3, 0.075, 0.25), at + Vector3(0.33, 1, 0), Color("777d79"))

func _plant(at: Vector3) -> void:
	_sphere("plant pot", Vector3(0.42, 0.5, 0.42), at + Vector3(0, 0.26, 0), Color("bd7953"))
	_box("plant stem", Vector3(0.045, 0.8, 0.045), at + Vector3(0, 0.8, 0), Color("697649"))
	for i in range(7):
		var angle := float(i) * TAU / 7
		_sphere("leaf", Vector3(0.35, 0.08, 0.18), at + Vector3(cos(angle) * 0.2, 0.8 + (i % 3) * 0.15, sin(angle) * 0.2), Color("788f55"), Vector3(0.2, -angle, 0.22))

func _box(label: String, size: Vector3, at: Vector3, color: Color, collision := false) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_append(label, mesh, Transform3D(Basis.IDENTITY, at), color)
	if collision:
		_collision(size, at)

func _sphere(label: String, size: Vector3, at: Vector3, color: Color, rotation := Vector3.ZERO) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 8
	mesh.rings = 4
	_append(label, mesh, Transform3D(Basis.from_euler(rotation).scaled(size), at), color)

func _append(_label: String, mesh: Mesh, transform: Transform3D, color: Color) -> void:
	var key := color.to_html()
	if not _batches.has(key):
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		_batches[key] = surface
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.83
		_materials[key] = material
	var surface: SurfaceTool = _batches[key]
	surface.append_from(mesh, 0, transform)

func _flush_meshes() -> void:
	for key: String in _batches:
		var node := MeshInstance3D.new()
		node.name = "FurnishingBatch_" + key
		node.mesh = (_batches[key] as SurfaceTool).commit()
		node.material_override = _materials[key]
		add_child(node)
	_batches.clear()

func _collision(size: Vector3, at: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = at
	_body.add_child(collider)

func _add_service_sign(kind: String, text: String, at: Vector3, yaw: float) -> void:
	var sign := Label3D.new()
	sign.name = "ServiceSign_" + kind
	sign.text = text
	sign.font_size = 40
	sign.pixel_size = 0.0038
	sign.modulate = Color("f6dfb0")
	sign.outline_modulate = Color("3c4144")
	sign.outline_size = 5
	sign.position = at
	sign.rotation.y = yaw
	add_child(sign)
