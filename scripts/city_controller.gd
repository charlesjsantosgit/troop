extends Node
## Connects physical addresses, compact panels and authenticated city services.
const Plan = preload("res://scripts/city_plan.gd")
const NetworkScript = preload("res://scripts/city_network.gd")
const Rooms = preload("res://scripts/city_interior.gd")
const Furniture = preload("res://scripts/city_furniture.gd")
const PenthouseViewScript = preload("res://scripts/city_penthouse_view.gd")
var civil: Node
var frontier: Node
var world: Node3D
var city_world: Node3D
var crowd: Node3D
var park_world: Node3D
var panel: Control
var interior: Node3D
var penthouse_view: Node3D
var interior_id := ""
var last_message := "Visit the village transit stop to explore Crownreach."
var waypoint: Dictionary = {}
var _label: Label
var _refresh := 0.0
var _network: Node
var _pending := 0
var _pending_kind := ""
var _pending_payload: Dictionary = {}
var _retry := 0.0
var _observed_time := 0.0
var _view_clock_msec := 0
var _inspect_clock := 5.0
var _room_saved_view := -1
var _room_camera: Camera3D
var _room_saved_environment: Environment
var _room_saved_far := 0.0
var _parcel: Node3D
var _arrival := Vector3.INF
var _arrival_frames := 0
var _arrival_time := 0.0

func configure(owner_frontier: Node) -> void:
	frontier = owner_frontier
	world = frontier.world
	Visuals.set_city_enabled(true)
	city_world = load("res://scripts/city_world.gd").new()
	city_world.name = "Crownreach"
	world.add_child(city_world)
	city_world.configure(world)
	crowd = load("res://scripts/city_crowd.gd").new()
	crowd.name = "CityStreetLife"
	world.add_child(crowd)
	park_world = load("res://scripts/city_park_world.gd").new()
	park_world.name = "LanternGrandPark"
	world.add_child(park_world)
	park_world.configure(self)
	world.city_disasters=load("res://scripts/city_disasters.gd").new()
	world.city_disasters.name="CityDisasters"
	world.add_child(world.city_disasters)
	world.city_disasters.configure(self)
	var layer := CanvasLayer.new()
	layer.layer = 66
	add_child(layer)
	panel = load("res://scripts/city_panel.gd").new()
	panel.configure(self)
	layer.add_child(panel)
	_label = Label.new()
	_label.position = Vector2(18, 180)
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_color", Color("e9bc74"))
	_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_label)
	if frontier._online:
		_network = frontier._network.city
		_network.finished.connect(_on_result)
		_network.request("inspect")

	civil=preload("res://scripts/civil_controller.gd").new()
	civil.name="CivilController"
	add_child(civil)
	civil.configure(self)

func city_view() -> Dictionary:
	var view: Dictionary = _network.cached_view.duplicate(true) if is_instance_valid(_network) \
		else frontier.simulation.city_view(interior_id)
	var state: Dictionary = frontier.simulation.state
	# Town and city replies share the same monotonically revised player patch.
	# The active town projection therefore wins over an older city snapshot.
	view["credits"] = int(state.get("accounts", {}).get("player", view.get("credits", 0)))
	view["now"] = float(view.get("time", state.get("time", 0.0)))
	if is_instance_valid(_network) and _view_clock_msec > 0:
		view.now += maxf(0.0, (Time.get_ticks_msec() - _view_clock_msec) / 1000.0)
	view["backpack_capacity"] = 350
	view["bus_fare"] = NetworkScript.BUS_FARE
	view["action_pending"] = _pending != 0
	view["last_message"] = last_message
	view["stops"] = Plan.stops()
	var bag: Dictionary = state.get("inventories", {}).get("player_earth", view.get("backpack_counts", {}))
	view["backpack_counts"] = bag.duplicate(true)
	view["backpack"] = []
	for item in bag:
		view.backpack.append({"id": item, "label": str(item).replace("_", " ").capitalize(),
			"count": int(bag[item]), "quantity": int(bag[item])})
	if is_instance_valid(civil) and civil.view.get("resident_life") is Dictionary:
		view.resident_life=civil.view.resident_life
	return view

func interactions() -> Array:
	if not is_instance_valid(world.local_player) or frontier.current_planet() != "earth": return []
	var player: Vector3 = world.local_player.global_position
	var result: Array = []
	if is_instance_valid(interior):
		var building: Dictionary = Plan.building(interior_id)
		for service: Dictionary in interior.service_points().values():
			var entry := building.duplicate()
			entry["city"] = true
			entry["property"] = interior_id
			entry["kind"] = str(service.kind)
			entry["position"] = interior.to_global(service.position)
			entry["label"] = str(service.get("label", service.get("prompt", service.kind)))
			result.append(entry)
		if world.local_player.furniture_active():
			return [{"city":true,"kind":"furniture_exit","position":player,"label":"Stand up · movement also gets up"}]
		var furniture := Rooms.furniture_layout(building)
		for id: String in furniture:
			var entry: Dictionary = furniture[id].duplicate(true)
			entry["city"] = true
			entry["furniture"] = id
			entry["property"] = interior_id
			entry.position = interior.to_global(entry.position)
			result.append(entry)
		return result
	if is_instance_valid(civil): result.append_array(civil.interactions())
	if is_instance_valid(park_world): result.append_array(park_world.interactions(world.local_player))
	var nearest: Dictionary = Plan.nearest_building(player, 6.0)
	if not nearest.is_empty():
		nearest["city"] = true
		nearest["kind"] = "building"
		nearest["position"] = nearest.door
		nearest["label"] = nearest.name
		result.append(nearest)
	for stop: Dictionary in Plan.stops():
		if player.distance_squared_to(stop.position) > 36.0: continue
		var entry := stop.duplicate()
		entry["city"] = true
		entry["kind"] = "transit"
		entry["label"] = str(stop.name) + " · transit"
		result.append(entry)
	return result

func open(context: Dictionary) -> void:
	if str(context.kind).begins_with("park_") and is_instance_valid(park_world):
		park_world.interact(context)
		return
	if context.kind == "furniture":
		request_action("use_furniture",{"id":str(context.furniture)})
		return
	if context.kind == "furniture_exit":
		_request_furniture_leave()
		return
	if context.kind == "exit":
		exit_building()
		return
	frontier.ui.close()
	panel.open(context)
	if is_instance_valid(_network) and _pending == 0: _network.request("inspect")

func close_panel() -> void:
	if panel.visible:
		panel.close()
	elif DisplayServer.get_name() != "headless" and not get_tree().paused \
			and not frontier.ui.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func request_action(kind: String, payload: Dictionary = {}) -> Dictionary:
	if kind.begins_with("civil_") and is_instance_valid(civil):return civil.request_action(kind,payload)
	if _pending != 0: return _reject("Your previous request is still being confirmed.")
	if arrival_pending(): return _reject("Arriving… preparing the ground beneath you.")
	var p = world.local_player
	if not is_instance_valid(p) or p.vehicle or p.expedition_locked or frontier.current_planet() != "earth":
		return _reject("Use city services on foot on Earth.")
	if kind=="recall_vehicle":
		var recalled: Vehicle=world.vehicles.get(str(payload.get("vehicle","")))
		if is_instance_valid(recalled) and (is_instance_valid(recalled.driver) or recalled.remote_controlled):
			return _reject("Park the vehicle and step out before recalling it.")
	if kind=="use_furniture":
		if not is_inside():return _reject("Enter the room before using its furniture.")
		var layout:=Rooms.furniture_layout(Plan.building(interior_id))
		var id:=str(payload.get("id",""))
		if not layout.has(id):return _reject("This furniture is unavailable.")
		var item:=Furniture.world_item(layout[id],interior.global_position)
		if not p.furniture_can_enter(item):
			p._furniture_notice(p.furniture_last_error)
			return _reject(p.furniture_last_error)
		payload=payload.duplicate(true)
		payload["heading"]=roundi(fposmod(p.rig.yaw_angle(),TAU)*1000.0)
	if kind=="leave_furniture" and p.furniture_active():
		var index:int=int(payload.get("target",0))
		if index<0 or index>=p.furniture_data.exits.size():return _reject("Choose a standing space beside the furniture.")
		if not p.furniture_can_leave(p.furniture_data.exits[index]):
			p._furniture_notice(p.furniture_last_error)
			return _reject(p.furniture_last_error)
	if is_instance_valid(_network):
		var result: Dictionary = _network.request(kind, payload)
		if result.get("pending", false):
			_pending = int(result.request)
			_pending_kind = kind
			_pending_payload = payload.duplicate(true)
			_retry = 3.0
		return result
	if kind in ["store_item", "take_item", "set_home"] and not is_inside():
		return _reject("Enter your home and use its cupboard or bed.")
	if kind in ["store_item", "take_item", "set_home"]:
		var point_id := "bed" if kind == "set_home" else "storage"
		var points: Dictionary = interior.service_points()
		if not points.has(point_id) or p.global_position.distance_to(interior.to_global(points[point_id].position)) > 2.9:
			return _reject("Walk back to your cupboard or bed first.")
	var result: Dictionary
	var checkpoint: Dictionary = frontier.simulation.state.duplicate(true)
	if kind in ["use_furniture","leave_furniture"]:
		result = _offline_furniture(kind,payload)
	elif kind in ["enter", "exit", "transit"]:
		result = _offline_transition(kind, payload)
	else:
		var at: Vector3 = p.global_position
		if is_instance_valid(interior) and (kind in ["start_job", "finish_job"] \
				or str(payload.get("building", payload.get("property", payload.get("id", "")))) == interior_id):
			var translated := NetworkScript.room_action_position(Plan.building(interior_id), at, kind)
			if translated != Vector3.INF: at = translated
		var context:Dictionary=civil.life_context(str(payload.get("building",""))) if kind.begins_with("life_") else {}
		result = frontier.simulation.city_action(kind, payload, at,-1.0,context)
	if result.get("ok", false) and kind not in ["enter", "exit", "use_furniture", "leave_furniture"] and frontier.persistence_enabled:
		if not frontier.save_progress():
			frontier.simulation.state = checkpoint
			result = {"ok": false, "message": "Could not save. Nothing was charged or transferred."}
	_on_result(0, kind, result)
	return result

func _reject(message: String) -> Dictionary:
	last_message = message
	if is_instance_valid(panel) and panel.visible: panel.refresh_view()
	return {"ok": false, "message": message}

func enter_building(id: String) -> void:
	if is_instance_valid(world.city_disasters) and world.city_disasters.building_closed(id):
		_reject("Emergency reconstruction in progress. This building reopens tomorrow morning.")
		return
	request_action("enter", {"id": id})

func exit_building() -> void:
	request_action("exit")

func travel_to_stop(id: String) -> void:
	request_action("transit", {"id": id})

func _offline_transition(kind: String, payload: Dictionary) -> Dictionary:
	var at: Vector3 = world.local_player.global_position
	if kind == "enter":
		var building: Dictionary = Plan.building(str(payload.get("id", "")))
		if building.is_empty() or at.distance_to(building.door) > 7.5:
			return {"ok": false, "message": "Walk to the entrance first."}
		return {"ok": true, "message": "Welcome to " + str(building.name), "enter": building.id}
	if kind == "exit":
		if not is_instance_valid(interior): return {"ok": false, "message": "You are already outside."}
		return {"ok": true, "message": "Back outside.", "destination": Plan.building(interior_id).door + Vector3(0, 1.2, 2)}
	var origin: Dictionary = {}
	var destination: Dictionary = {}
	for stop: Dictionary in Plan.stops():
		if at.distance_to(stop.position) <= 7.5: origin = stop
		if stop.id == str(payload.get("id", "")): destination = stop
	if origin.is_empty() or destination.is_empty() or origin.id == destination.id:
		return {"ok": false, "message": "Visit a transit stop and choose another destination."}
	if frontier.simulation.balance("player") < NetworkScript.BUS_FARE:
		return {"ok": false, "message": "A transit ticket costs 6 credits."}
	frontier.simulation._transfer("player", "treasury", NetworkScript.BUS_FARE, "Crownreach transit ticket")
	return {"ok": true, "message": "Arrived at " + str(destination.name),
		"destination": destination.position + Vector3(0, 1.2, 0)}

func _on_result(serial: int, kind: String, result: Dictionary) -> void:
	if result.has("view"): _view_clock_msec = Time.get_ticks_msec()
	if serial == _pending: _pending = 0
	if not str(result.get("message", "")).is_empty(): last_message = str(result.message)
	if kind == "leave_furniture": world.local_player.furniture_leave_pending = false
	if result.get("ok", false):
		if result.has("heal_to"):world.local_player.heal(maxf(0,float(result.heal_to)-world.local_player.health))
		if result.get("furniture") is Dictionary:
			panel.close()
			if not world.local_player.begin_furniture(result.furniture):
				if is_instance_valid(_network):_network.request("cancel_furniture",{})
				last_message=world.local_player.furniture_last_error
		elif result.get("furniture_exit") is Vector3:
			world.local_player.rise_from_furniture(result.furniture_exit,result.get("motion_path",[]))
		elif result.has("enter"): _enter_room(str(result.enter))
		elif result.get("destination") is Vector3:
			_leave_room()
			_teleport(result.destination)
	if result.get("ok",false) and result.get("vehicle") is Dictionary and not is_instance_valid(_network):
		var delivered: Dictionary = result.vehicle
		var at := Vector3(delivered.position[0],delivered.position[1],delivered.position[2])
		var vehicle: Vehicle = world.spawn_vehicle(Vehicle.Kind.JEEP,str(delivered.id),at,float(delivered.yaw))
		vehicle.settle_at(at,float(delivered.yaw))
		waypoint = {"position":at,"label":"Your "+str(delivered.model).replace("_"," ")}
	frontier.backpack_changed.emit()
	if panel.visible: panel.refresh_view()

func _enter_room(id: String) -> void:
	var building: Dictionary = Plan.building(id)
	if building.is_empty(): return
	_leave_room()
	interior_id = id
	interior = load("res://scripts/city_interior.gd").new()
	interior.name = "BuildingInterior"
	world.add_child(interior)
	interior.build(building)
	interior.global_position = NetworkScript.interior_origin(building)
	world.local_player.rig.furnished_room=true
	if str(building.get("housing", "")) == "penthouse":
		penthouse_view = PenthouseViewScript.new()
		interior.add_child(penthouse_view)
		penthouse_view.build(building,city_world)
		city_world.set_penthouse_host(id,interior.global_position.y)
	if not world.local_player.furniture_leave_requested.is_connected(_request_furniture_leave):
		world.local_player.furniture_leave_requested.connect(_request_furniture_leave)
	if not world.local_player.furniture_blocked.is_connected(_on_furniture_blocked):
		world.local_player.furniture_blocked.connect(_on_furniture_blocked)
	if world.local_player.cam:
		_room_saved_view = world.local_player.cam.preferred_view_mode
		world.local_player.cam.set_first_person(true)
		world.local_player.cam.yaw = interior.spawn_yaw()
		world.local_player.cam.pitch = 0.0
		_room_camera = world.local_player.cam._cam
		_room_saved_environment = _room_camera.environment
		_room_saved_far = _room_camera.far
		if is_instance_valid(penthouse_view):
			# Inherit Earth's actual sky, sun, atmosphere and exposure. The view
			# contains the same CityWorld instances visible from the street.
			_room_camera.far = maxf(_room_camera.far,12000.0)
		else:
			var room_environment := Environment.new()
			room_environment.background_mode = Environment.BG_COLOR
			room_environment.background_color = Color("29282a")
			room_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			room_environment.ambient_light_color = Color("fff0d9")
			room_environment.ambient_light_energy = 0.45
			room_environment.fog_enabled = false
			room_environment.volumetric_fog_enabled = false
			_room_camera.environment = room_environment
	_update_room_lighting()
	if world.seasonal_weather: world.seasonal_weather.set_atmosphere_enabled(false)
	_teleport(interior.to_global(interior.spawn_point()))

func _leave_room() -> void:
	if is_instance_valid(world.local_player):
		world.local_player.cancel_furniture()
		if world.local_player is MonkeyPlayer:world.local_player.rig.furnished_room=false
	if is_instance_valid(city_world): city_world.set_penthouse_host("",0.0)
	if is_instance_valid(_room_camera):
		_room_camera.environment = _room_saved_environment
		if _room_saved_far > 0.0: _room_camera.far = _room_saved_far
	_room_camera = null
	_room_saved_environment = null
	_room_saved_far = 0.0
	if _room_saved_view >= 0 and is_instance_valid(world.local_player) and is_instance_valid(world.local_player.cam):
		world.local_player.cam.set_view_mode(_room_saved_view)
	_room_saved_view = -1
	if is_instance_valid(interior):
		# The departing room must disappear before its tower roof is restored.
		interior.visible = false
		interior.queue_free()
	interior = null
	penthouse_view = null
	interior_id = ""
	if is_instance_valid(world.seasonal_weather):
		world.seasonal_weather.set_atmosphere_enabled(world._earth_streaming_enabled)

func _update_room_lighting() -> void:
	if not is_instance_valid(interior): return
	var hour_value: Variant = world.get("time_of_day_hours")
	var daylight_value: Variant = world.get("daylight_amount")
	var hour := float(hour_value) if hour_value != null else 12.0
	var daylight := clampf(float(daylight_value),0.0,1.0) if daylight_value != null else 1.0
	if is_instance_valid(penthouse_view): penthouse_view.update_time(hour,daylight)
	interior.update_time(hour,daylight)

func _offline_furniture(kind: String, payload: Dictionary) -> Dictionary:
	if not is_inside(): return _reject("Enter the room before using its furniture.")
	var p: MonkeyPlayer = world.local_player
	if kind == "leave_furniture":
		if not p.furniture_active(): return _reject("You are already standing.")
		var index: int = int(payload.get("target",0))
		if index < 0 or index >= p.furniture_data.exits.size(): return _reject("Choose a clear place beside the furniture.")
		var destination: Vector3 = p.furniture_data.exits[index]
		if not p.can_stand_at(destination): return _reject("The space beside you is blocked. Try again when it is clear.")
		return {"ok":true,"message":"Standing up.","furniture_exit":destination}
	if p.furniture_active(): return _reject("Stand up before using another seat.")
	var layout := Rooms.furniture_layout(Plan.building(interior_id))
	var id := str(payload.get("id",""))
	if not layout.has(id): return _reject("This furniture is unavailable.")
	var item := Furniture.world_item(layout[id],interior.global_position)
	if p.global_position.distance_to(item.position) > Furniture.REACH: return _reject("Walk beside the chair, sofa or bed first.")
	return {"ok":true,"message":"E or movement to stand up.","furniture":item}

func _on_furniture_blocked(message:String)->void:
	last_message=message
	if panel.visible:panel.refresh_view()

func _request_furniture_leave() -> void:
	var p: MonkeyPlayer = world.local_player
	if not p.furniture_active(): return
	for index in range(p.furniture_data.exits.size()):
		if p.can_stand_at(p.furniture_data.exits[index]):
			var result := request_action("leave_furniture",{"target":index})
			if not result.get("pending",false): p.furniture_leave_pending = false
			return
	p.furniture_leave_pending = false
	_reject("The space beside you is blocked. Try again when it is clear.")

func _teleport(destination: Vector3) -> void:
	panel.close()
	world.local_player.admin_teleport(destination)
	hold_arrival(destination)
	city_world.update_focus(destination)
	crowd.update_focus(destination)
	waypoint.clear()

func hold_arrival(destination: Vector3) -> void:
	_arrival = destination
	_arrival_frames = 0
	_arrival_time = 0.0
	world.local_player.arrival_locked = true
	world._reset_planet_stream_focus()

func arrival_pending() -> bool:
	return _arrival.is_finite()

func _physics_process(delta: float) -> void:
	if not arrival_pending() or not is_instance_valid(world.local_player): return
	_arrival_frames += 1
	_arrival_time += delta
	if _arrival_frames < 2: return
	var radius := 0.45
	var required: Dictionary = {}
	if not is_inside():
		for x in [-radius, radius]:
			for z in [-radius, radius]:
				required[Vector2i(floori((_arrival.x + x) / Gen.CHUNK), floori((_arrival.z + z) / Gen.CHUNK))] = true
		for key in required:
			var chunk: Node = world.chunks.get(key)
			if not is_instance_valid(chunk) or not chunk.has_collisions() or not chunk._collisions_active:
				# The normal bounded streamer owns arrival work. A stalled lane can
				# finish one required tile per tick after three seconds, never a world.
				if _arrival_time > 3.0: world._warm_chunk(key, true)
				return
	var space := world.get_world_3d().direct_space_state
	for offset in [Vector3.ZERO, Vector3(-radius, 0, -radius), Vector3(radius, 0, -radius),
			Vector3(-radius, 0, radius), Vector3(radius, 0, radius)]:
		var ray := PhysicsRayQueryParameters3D.create(_arrival + offset + Vector3.UP * 0.25,
			_arrival + offset - Vector3.UP * 3.0, 1, [world.local_player.get_rid()])
		var hit := space.intersect_ray(ray)
		if hit.is_empty() or (hit.normal as Vector3).y < 0.6: return
	world.local_player.arrival_locked = false
	world.local_player.velocity = Vector3.ZERO
	_arrival = Vector3.INF

func navigate_to(destination: Vector3, label := "Destination") -> void:
	waypoint = {"position": destination, "label": label}
	last_message = "Follow the gold destination marker."
	panel.close()
	if frontier.ui.visible: frontier.ui.close()

func locate_transit() -> void:
	var best: Dictionary = {}
	var distance := INF
	for stop: Dictionary in Plan.stops():
		var next: float = world.local_player.global_position.distance_squared_to(stop.position)
		if next < distance:
			distance = next
			best = stop
	if not best.is_empty(): navigate_to(best.position, best.name)

func is_inside() -> bool:
	return is_instance_valid(interior) and is_instance_valid(world.local_player) \
		and world.local_player.global_position.distance_to(interior.global_position) < 60.0

func is_in_city() -> bool:
	return is_instance_valid(world) and is_instance_valid(world.local_player) \
		and frontier.current_planet() == "earth" \
		and Plan.contains(Vector2(world.local_player.position.x, world.local_player.position.z))

func _exit_tree() -> void:
	if is_instance_valid(world) and is_instance_valid(world.local_player):
		_leave_room()
		world.local_player.arrival_locked = false
	elif is_instance_valid(interior):
		interior.visible = false
		interior.queue_free()
	Visuals.set_city_enabled(false)

func _update_parcel() -> void:
	var view := city_view()
	var job: Dictionary = view.get("active_job", {})
	var carrying: bool = not job.is_empty() and not job.get("cargo", {}).is_empty()
	if not is_instance_valid(_parcel) and carrying and world.local_player.rig:
		_parcel = Node3D.new()
		_parcel.name = "SealedCityJobParcel"
		world.local_player.rig.torso_p.add_child(_parcel)
		for part in [[Vector3(0.34, 0.24, 0.18), Vector3(0, 0.26, 0.46), Color("af8356")],
				[Vector3(0.04, 0.25, 0.19), Vector3(-0.10, 0.26, 0.46), Color("e7c779")],
				[Vector3(0.04, 0.25, 0.19), Vector3(0.10, 0.26, 0.46), Color("e7c779")]]:
			var mesh := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = part[0]
			mesh.mesh = box
			mesh.position = part[1]
			mesh.layers = MonkeyRig.LOCAL_BODY_VISUAL_LAYER
			var material := StandardMaterial3D.new()
			material.albedo_color = part[2]
			mesh.material_override = material
			_parcel.add_child(mesh)
	if is_instance_valid(_parcel): _parcel.visible = carrying and not world.local_player.vehicle

func home_destination() -> Vector3:
	var view := city_view()
	var home: Variant = view.get("home", view.get("home_id", ""))
	if home is Dictionary: home = home.get("id", "")
	var building: Dictionary = Plan.building(str(home))
	return building.door + Vector3(0, 1.2, 2) if not building.is_empty() else Vector3.INF

func prepare_respawn() -> Vector3:
	var destination := home_destination()
	_leave_room()
	return destination

func _process(delta: float) -> void:
	if not is_instance_valid(world) or not is_instance_valid(world.local_player): return
	var earth: bool = frontier.current_planet() == "earth"
	city_world.visible = earth
	crowd.visible = earth
	if earth:
		city_world.update_focus(world.local_player.global_position)
		crowd.update_focus(world.local_player.global_position)
	else:
		crowd.update_focus(Vector3.INF)
	_refresh -= delta
	_retry -= delta
	_inspect_clock -= delta
	if (panel.visible or is_in_city() or is_inside()) and is_instance_valid(_network) and _pending == 0 and _inspect_clock <= 0.0:
		_network.request("inspect")
		_inspect_clock = 5.0
	if _pending != 0 and _retry <= 0.0 and Net.active:
		_network.rpc_id(1, "sv_request", _pending, _pending_kind, _pending_payload)
		_retry = 3.0
	if _refresh <= 0.0:
		_refresh = 0.5
		_update_room_lighting()
		crowd.set_district_services(city_view().get("districts",[]))
		if world.seasonal_weather:
			var weather_enabled: bool = world._earth_streaming_enabled and not is_inside()
			if world.seasonal_weather.atmosphere_enabled() != weather_enabled:
				world.seasonal_weather.set_atmosphere_enabled(weather_enabled)
		_update_parcel()
		if panel.visible: panel.refresh_view()
		_label.visible = earth and not panel.visible and not frontier.ui.visible
		_label.text = ""
		if arrival_pending():
			_label.position = Vector2(24, get_viewport().get_visible_rect().size.y - 220)
			_label.text = "Arriving… preparing the ground beneath you."
		elif is_inside() and city_world.far_staged_block_count() < Plan.TOTAL_BLOCKS:
			_label.position = Vector2(24, get_viewport().get_visible_rect().size.y - 220)
			_label.text = "Preparing the distant city view… %d%%" % roundi(100.0 * float(city_world.far_staged_block_count()) / float(Plan.TOTAL_BLOCKS))
		elif not waypoint.is_empty():
			var destination: Vector3 = waypoint.position
			var distance: float = world.local_player.global_position.distance_to(destination)
			_label.text = "◇ %s · %.0f m" % [waypoint.label, distance]
			var camera := get_viewport().get_camera_3d()
			if camera:
				var bounds := get_viewport().get_visible_rect().size
				var screen := camera.unproject_position(destination + Vector3.UP * 1.7)
				if camera.is_position_behind(destination):
					screen.x = 100 if (camera.global_basis.inverse() * (destination - camera.global_position)).x < 0 else bounds.x - 250
					screen.y = bounds.y * 0.5
				_label.position = Vector2(clampf(screen.x, 18, bounds.x - 310), clampf(screen.y, 180, bounds.y - 210))
			if distance < 4.0: waypoint.clear()
