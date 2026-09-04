class_name FrontierController
extends Node
## Connects the persistent society to the existing planet, expedition, inputs
## and physical workplaces. Online views are supplied by the shared authority;
## existing local saves remain a separate, explicit offline career.

const SAVE_PATH := "user://frontier/roots_and_rockets.json"
const INTERACTION_RANGE := 5.2
const MANUAL_ACTIONS := ["plant", "harvest", "water", "fertilize", "repair", "clear_plot"]

var simulation: RefCounted
var owner_main: Node
var world: World
var expedition: ExpeditionManager
var earth_site: FrontierSite
var moon_site: FrontierSite
var earth_settlement: Node3D
var moon_settlement: Node3D
var ui: Control
var save_path := SAVE_PATH
var persistence_enabled := true
var simulation_enabled := true
var selected_interaction: Dictionary = {}
var waypoint: Dictionary = {}
var last_message := "Welcome to Canopy Commons. E talks and works; B opens your journal."
var _layer: CanvasLayer
var _status: Label
var _prompt: Label
var _waypoint_label: Label
var _waypoint_marker: Label
var _sky_credit: Label
var _refresh := 0.0
var _save_timer := 20.0
var _last_realm := -1
var _observation := false
var _saved_player_position: Array = []
var _online := false
var _network: Node
var _town_entries: Dictionary = {}
var _town_build_queue: Array[String] = []
var _active_town_id := "canopy_earth"
var _town_refresh := 0.0
var _offline_traffic: Node3D
var tutorial: Node
var _tutorial_save_path := ""
var _pending_actions: Dictionary = {}
var _pending_kind := ""
var _pending_town := ""
var _pending_retry_at := 0


func configure(main: Node, host: World, manager: ExpeditionManager,
		load_saved := true, custom_save_path := SAVE_PATH) -> void:
	owner_main = main
	world = host
	expedition = manager
	save_path = custom_save_path
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_online = Net.active
	_tutorial_save_path = "user://frontier/tutorial-online.cfg" if _online else custom_save_path + ".tutorial.cfg" if load_saved else ""
	if _online:
		_configure_online()
		return
	simulation = load("res://scripts/frontier_sim.gd").new()
	var loaded: bool = load_saved and simulation.load_game(save_path)
	if load_saved and not loaded and FileAccess.file_exists(save_path + ".bak") \
			and simulation.load_game(save_path + ".bak"):
		loaded = true
		var original := ProjectSettings.globalize_path(save_path)
		var preserved := original + ".unreadable-%d" % int(Time.get_unix_time_from_system())
		persistence_enabled = not FileAccess.file_exists(original) or DirAccess.copy_absolute(original, preserved) == OK
		last_message = "Recovered the preceding society checkpoint. The unreadable save was preserved." \
			if persistence_enabled else "Recovered the preceding checkpoint; saving is disabled because the unreadable file could not be preserved."
	if not loaded:
		simulation.new_game(Gen.world_seed)
		if load_saved and (FileAccess.file_exists(save_path) or FileAccess.file_exists(save_path + ".bak")):
			persistence_enabled = false
			last_message = "The previous society save could not be read. It has been preserved; this session will not overwrite it."
	world.set("frontier", self)
	_create_sites()
	_build_ui()
	# Realm state belongs to the expedition system; opening a ledger never
	# performs travel. A saved lunar career can resume at its existing lander.
	if loaded and str(simulation.state.get("planet", "earth")) == "moon" \
			and Net.player_realm() != Net.PlayerRealm.MOON:
		Net.rocket_state.phase = Net.RocketMissionPhase.MOON_READY
		expedition._apply_authoritative_state(Net.expedition_state_snapshot())
		expedition.admin_travel(Net.PlayerRealm.MOON)
	_sync_realm()
	if world.local_player:
		world.local_player.melee_mode = true
		world.local_player.rig.set_melee_pose(false, false, 0.0, 0)


func _create_sites() -> void:
	earth_site = FrontierSite.new()
	earth_site.name = "CanopyCommons"
	earth_site.world = world
	world.add_child(earth_site)
	earth_settlement = load("res://scripts/frontier_settlement.gd").new()
	earth_settlement.configure(earth_site, simulation, "earth")
	earth_site.add_child(earth_settlement)
	_offline_traffic = load("res://scripts/frontier_traffic.gd").new()
	earth_site.add_child(_offline_traffic)
	_offline_traffic.configure(simulation, earth_site, true, "offline_earth")
	_offline_traffic.build()
	earth_settlement.build()
	moon_site = FrontierSite.new()
	moon_site.name = "LunarAgricultureDistrict"
	moon_site.world = world
	moon_site.moon = expedition.moon_world
	moon_site.planet = "moon"
	expedition.moon_world.add_child(moon_site)
	var up := Vector3(-85.0, 450.0, 105.0).normalized()
	var right := Vector3.FORWARD.cross(up).normalized()
	moon_site.transform = Transform3D(Basis(right, up, right.cross(up)).orthonormalized(),
		expedition.moon_world.surface_position(up, 0.02))
	moon_settlement = load("res://scripts/frontier_settlement.gd").new()
	moon_settlement.configure(moon_site, simulation, "moon")
	moon_site.add_child(moon_settlement)
	moon_settlement.build()


func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 65
	add_child(_layer)
	ui = load("res://scripts/frontier_ui.gd").new()
	ui.configure(self)
	_layer.add_child(ui)
	_status = _overlay_label(18)
	_status.position = Vector2(18, 55)
	_status.add_theme_color_override("font_color", Color("e2edc4"))
	_layer.add_child(_status)
	_prompt = _overlay_label(19)
	_prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.offset_left = -390
	_prompt.offset_right = 390
	_prompt.offset_top = -215
	_prompt.offset_bottom = -183
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_layer.add_child(_prompt)
	_waypoint_label = _overlay_label(16)
	_waypoint_label.position = Vector2(18, 90)
	_layer.add_child(_waypoint_label)
	_waypoint_marker = _overlay_label(17)
	_waypoint_marker.add_theme_color_override("font_color", Color("f5da87"))
	_waypoint_marker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_waypoint_marker.size = Vector2(240, 55)
	_layer.add_child(_waypoint_marker)
	_sky_credit = _overlay_label(12)
	_sky_credit.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_sky_credit.offset_left = 18
	_sky_credit.offset_top = -118
	_sky_credit.offset_right = 720
	_sky_credit.offset_bottom = -96
	_sky_credit.text = "Sky photograph: ESO / S. Brunier · celestial reference: NASA / GSFC"
	_layer.add_child(_sky_credit)
	tutorial = load("res://scripts/frontier_tutorial.gd").new()
	add_child(tutorial)
	tutorial.configure(self, _layer, _tutorial_save_path)


func _overlay_label(size: int) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 2)
	return label


func _process(delta: float) -> void:
	if not simulation or not is_instance_valid(world):
		return
	if _online:
		_process_online(delta)
		return
	_sync_realm()
	_refresh -= delta
	if simulation_enabled:
		_sync_climate()
		if _refresh <= 0.0:
			_sync_obstructions()
		simulation.tick(delta)
	_save_timer -= delta
	if _refresh <= 0.0:
		_refresh = 0.35
		for vehicle: Vehicle in world.vehicles.values():
			if not vehicle.frontier_simulation:
				vehicle.configure_frontier_fuel(simulation)
		world.set_time_of_day_override(fmod(float(simulation.state.time), 1200.0) / 50.0)
		_update_sun()
		_refresh_overlays()
	if _save_timer <= 0.0:
		_save_timer = 20.0
		save_progress()


func _sync_realm() -> void:
	var realm := Net.player_realm()
	if realm == _last_realm:
		return
	_last_realm = realm
	if _online:
		if is_instance_valid(ui) and ui.visible:
			ui.close()
		selected_interaction.clear()
		waypoint.clear()
		_town_refresh = 0.0
		return
	if realm != Net.PlayerRealm.TRANSIT:
		simulation.state.planet = "moon" if realm == Net.PlayerRealm.MOON else "earth"
	if is_instance_valid(earth_site):
		earth_site.visible = realm == Net.PlayerRealm.EARTH
		earth_site.process_mode = Node.PROCESS_MODE_INHERIT if earth_site.visible else Node.PROCESS_MODE_DISABLED
	if is_instance_valid(moon_site):
		moon_site.visible = realm == Net.PlayerRealm.MOON
		moon_site.process_mode = Node.PROCESS_MODE_INHERIT if moon_site.visible else Node.PROCESS_MODE_DISABLED
	if is_instance_valid(ui) and ui.visible:
		ui.close()
	selected_interaction.clear()
	waypoint.clear()
	if realm == Net.PlayerRealm.MOON:
		for candidate: Dictionary in interactions():
			if candidate.get("id") == "lunar_greenhouse":
				waypoint = candidate.duplicate()
				break


func _update_sun() -> void:
	var moon := expedition.moon_world
	if not is_instance_valid(moon) or not is_instance_valid(moon_site) or not moon.has_method("set_lunar_sun_direction"):
		return
	var angle := float(simulation.state.get("lunar_phase", 0.0833333)) * TAU
	var solar_azimuth := Vector2(0.67, 0.74).normalized()
	var direction := moon_site.global_basis * Vector3(-cos(angle) * solar_azimuth.x, sin(angle), -cos(angle) * solar_azimuth.y)
	moon.call("set_lunar_sun_direction", direction)


func _sync_climate() -> void:
	var season_temperatures := [23.0, 28.0, 21.0, 10.0]
	var hour := fmod(float(simulation.state.time), 1200.0) / 50.0
	simulation.state.climate.temperature = season_temperatures[int(world.season)] + 3.0 * sin((hour - 8.0) * PI / 12.0)
	simulation.state.climate.rain = 1.0 if world.weather == SeasonalCycle.Weather.RAIN else 0.0


func _sync_obstructions() -> void:
	if not is_instance_valid(world.local_player):
		return
	var space := world.get_world_3d().direct_space_state
	var exclude: Array[RID] = [world.local_player.get_rid()]
	for citizen: Dictionary in simulation.state.citizens.values():
		citizen["route_blocked"] = ""
		if citizen.get("_job", {}).is_empty():
			continue
		var site := moon_site if citizen.planet == "moon" else earth_site
		var position := Vector2(float(citizen.position[0]), float(citizen.position[1]))
		var route: Array = citizen.get("route", [])
		var destination: Array = route[0] if not route.is_empty() else citizen.destination
		var target := Vector2(float(destination[0]), float(destination[1]))
		if position.distance_squared_to(target) < 0.01:
			continue
		var vehicle: bool = citizen.job in ["hauler", "tanker_driver"]
		var next := position.move_toward(target, 6.2 if vehicle else 2.8)
		var direction := (next - position).normalized()
		var sideways := Vector2(-direction.y, direction.x)
		var offsets: Array = [-0.8, 0.0, 0.8] if vehicle else [0.0]
		for offset: float in offsets:
			var start := position + sideways * offset
			var finish := next + sideways * offset
			var query := PhysicsRayQueryParameters3D.create(site.surface_point(start.x, start.y, 0.95),
				site.surface_point(finish.x, finish.y, 0.95), 1, exclude)
			if not space.intersect_ray(query).is_empty():
				citizen.route_blocked = "The service lane is obstructed. Clear the road so this delivery can continue."
				break


func _refresh_overlays() -> void:
	if not is_instance_valid(world.local_player):
		return
	var active := Net.player_realm() != Net.PlayerRealm.TRANSIT
	_status.visible = active and not ui.visible
	_prompt.visible = active and not ui.visible
	_waypoint_label.visible = false # The world-space marker already gives name and distance.
	_waypoint_marker.visible = active and not ui.visible and not waypoint.is_empty()
	_sky_credit.visible = Net.player_realm() == Net.PlayerRealm.MOON and not ui.visible
	var credits := int(simulation.state.get("accounts", {}).get("player", 0))
	_status.text = "%s  ·  %s credits  ·  B Journal" % [
		str(current_town().get("name", "Town")).to_upper(), str(credits)]
	var interaction := nearest_interaction()
	_prompt.text = interaction_prompt(interaction)
	_focus_resident(interaction if active and not ui.visible else {})
	_waypoint_label.text = ""
	if not waypoint.is_empty():
		for candidate: Dictionary in interactions():
			if not str(waypoint.get("id", "")).is_empty() and candidate.get("id") == waypoint.get("id"):
				waypoint = candidate.duplicate()
				break
		var point: Vector3 = waypoint.position
		var distance := world.local_player.global_position.distance_to(point)
		# The close target already has an E prompt (and a resident has a
		# nameplate). Keeping the navigation label here prints the same target
		# again across the resident or the service door.
		if distance <= INTERACTION_RANGE + 1.5:
			_waypoint_marker.visible = false
		_waypoint_label.text = "%s · %dm" % [str(waypoint.label), roundi(distance)]
		if distance < 5.0:
			_waypoint_label.text += " · E to interact"
		var camera := get_viewport().get_camera_3d()
		if camera:
			var bounds := get_viewport().get_visible_rect().size
			var behind := camera.is_position_behind(point)
			var screen := camera.unproject_position(point + Vector3.UP * 1.7)
			if behind:
				screen.x = 120.0 if (camera.global_basis.inverse() * (point - camera.global_position)).x < 0 else bounds.x - 120.0
				screen.y = bounds.y * 0.52
			_waypoint_marker.position = Vector2(clampf(screen.x - 120, 12, bounds.x - 252), clampf(screen.y - 25, 125, bounds.y - 220))
			_waypoint_marker.text = "%s %s\n%dm" % ["↶" if behind else "◇", str(waypoint.label), roundi(distance)]


func current_planet() -> String:
	return "moon" if Net.player_realm() == Net.PlayerRealm.MOON else "earth"


func current_settlement() -> Node3D:
	if _online:
		return _town_entries.get(_active_town_id, {}).get("settlement")
	return moon_settlement if current_planet() == "moon" else earth_settlement


func interactions() -> Array:
	var settlement := current_settlement()
	return settlement.get_interactions() if is_instance_valid(settlement) \
		and settlement.is_build_complete() else []


func nearest_interaction() -> Dictionary:
	if not is_instance_valid(world.local_player) or Net.player_realm() == Net.PlayerRealm.TRANSIT:
		return {}
	var nearest: Dictionary = {}
	var best := INTERACTION_RANGE * INTERACTION_RANGE
	var candidates := interactions()
	for candidate: Dictionary in candidates:
		var position: Vector3 = candidate.get("position", Vector3.INF)
		var distance := world.local_player.global_position.distance_squared_to(position)
		if distance < best:
			best = distance
			nearest = candidate
	# A merchant and their desk share a service point. The desk's slightly
	# lower anchor used to win every distance tie, even while facing Nana.
	# Prefer the resident at that desk, without stealing a different worksite.
	if str(nearest.get("kind", "")) in ["market", "facility", "board"]:
		var service_position: Vector3 = nearest.position
		var resident_distance := minf(INTERACTION_RANGE, sqrt(best) + 1.25)
		for candidate: Dictionary in candidates:
			if candidate.get("kind") != "citizen":
				continue
			var position: Vector3 = candidate.position
			var distance := world.local_player.global_position.distance_to(position)
			if position.distance_to(service_position) <= 2.0 and distance < resident_distance:
				resident_distance = distance
				nearest = candidate
	return nearest


func interaction_prompt(item: Dictionary) -> String:
	if item.is_empty():
		return "Talk to a resident or visit a workplace · B Journal"
	if item.get("kind") == "citizen":
		var person: Dictionary = simulation.state.get("citizens", {}).get(str(item.get("id", "")), {})
		return "E · Talk to %s" % str(person.get("name", item.get("label", "your neighbor")))
	return "E · " + str(item.get("label", "Interact"))


func _focus_resident(item: Dictionary) -> void:
	var settlement := current_settlement()
	if not is_instance_valid(settlement):
		return
	for id: String in settlement.citizens:
		var citizen: Node3D = settlement.citizens[id]
		if is_instance_valid(citizen):
			citizen.set_interaction_focus(item.get("kind") == "citizen" and item.get("id") == id)


func try_interact(player: MonkeyPlayer) -> bool:
	if player != world.local_player or player.vehicle or player.expedition_locked:
		return false
	if ui.visible:
		return true
	var item := nearest_interaction()
	if item.is_empty():
		return false
	selected_interaction = item
	ui.open(item)
	_refresh_overlays()
	if tutorial:
		tutorial.observe_interaction(str(item.get("id", "")))
	return true


func open_board() -> void:
	if Net.player_realm() == Net.PlayerRealm.TRANSIT:
		return
	selected_interaction.clear()
	ui.open({})


func open_workplace(id: String) -> bool:
	# A resident remains the default interaction at a shared service point.
	# Their explicit workplace link still enters the same physical desk context
	# used for authoritative action-source and proximity checks.
	if Net.player_realm() == Net.PlayerRealm.TRANSIT or not is_instance_valid(world.local_player):
		return false
	var player: MonkeyPlayer = world.local_player
	if player.vehicle or player.expedition_locked:
		return false
	for item: Dictionary in interactions():
		if str(item.get("id", "")) != id or str(item.get("kind", "")) not in ["facility", "board", "market"]:
			continue
		if player.global_position.distance_to(item.position) > INTERACTION_RANGE:
			return false
		selected_interaction = item.duplicate(true)
		ui.open(item)
		_refresh_overlays()
		if tutorial:
			tutorial.observe_interaction(id)
		return true
	return false


func request_action(kind: String, payload: Dictionary = {}) -> Dictionary:
	if _online:
		if not _pending_actions.is_empty():
			return _notice_result(false, "Waiting for the town to finish your previous request.")
		var town_id := str(payload.get("town_id", _active_town_id))
		if town_id != _active_town_id or selected_interaction.is_empty() \
				or not _target_in_range(str(selected_interaction.get("id", ""))):
			return _notice_result(false, "Stay beside this person or workplace to act.")
		var request := payload.duplicate(true)
		request.erase("town_id")
		request["source"] = str(selected_interaction.get("id", ""))
		var result: Dictionary = _network.request_action(town_id, kind, request)
		if result.get("pending", false):
			_pending_actions[int(result.request)] = request
			_pending_kind = kind
			_pending_town = town_id
			_pending_retry_at = Time.get_ticks_msec() + 4000
		elif tutorial:
			tutorial.observe_action(kind, request, result)
		last_message = str(result.get("message", "Waiting for the town…"))
		return result
	payload = payload.duplicate(true)
	payload.erase("town_id")
	if Net.player_realm() == Net.PlayerRealm.TRANSIT:
		return {"ok": false, "message": "Wait until your expedition lands."}
	if kind in MANUAL_ACTIONS:
		var target := str(payload.get("plot", payload.get("facility", "")))
		if not _target_in_range(target):
			return _notice_result(false, "Walk to this workplace first. Use Locate to set a waypoint.")
	if kind == "build_solar" and current_planet() != "moon":
		return _notice_result(false, "Solar installation is available at the lunar worksite.")
	var workplace := ""
	match kind:
		"buy", "sell": workplace = str(payload.get("market", ""))
		"deliver_quest":
			var quest: Dictionary = simulation.state.get("quests", {}).get(str(payload.get("id", "")), {})
			workplace = str(quest.get("destination", ""))
		"ship": workplace = "cargo" if current_planet() == "moon" else "warehouse"
		"build_solar", "upgrade_battery": workplace = "solar_array"
		"refill_habitat": workplace = "lunar_greenhouse"
		"process":
			workplace = "refinery" if str(payload.get("recipe", "")) == "refine" else "workshop"
	if not workplace.is_empty() and not _target_in_range(workplace):
		return _notice_result(false, "Bring your cargo to %s first. Use Locate to find the workplace." % workplace.replace("_", " ").capitalize())
	if kind == "refuel":
		var vehicle: Vehicle = world.vehicles.get(str(payload.get("vehicle", "")))
		var facility := str(payload.get("facility", ""))
		var position := _interaction_position(facility)
		if not is_instance_valid(vehicle) or position == Vector3.INF \
				or vehicle.global_position.distance_to(position) > 18.0 \
				or world.local_player.global_position.distance_to(position) > 18.0:
			return _notice_result(false, "Bring yourself and the vehicle to the depot's loading bay first.")
		if vehicle.linear_velocity.length() > 1.0:
			return _notice_result(false, "Park the vehicle before refueling.")
	var result: Dictionary = simulation.action(kind, payload)
	last_message = str(result.get("message", result.get("reason", "")))
	if bool(result.get("ok", false)):
		save_progress()
		if tutorial:
			tutorial.observe_action(kind, payload, result)
	return result


func _notice_result(ok: bool, message: String) -> Dictionary:
	last_message = message
	return {"ok": ok, "message": message}


func _target_in_range(target: String) -> bool:
	for candidate: Dictionary in interactions():
		if str(candidate.get("id", "")) == target:
			var position: Vector3 = candidate.position
			return world.local_player.global_position.distance_to(position) <= INTERACTION_RANGE + 1.5
	return false


func _interaction_position(target: String) -> Vector3:
	for candidate: Dictionary in interactions():
		if str(candidate.get("id", "")) == target:
			return candidate.position
	return Vector3.INF


func nearby_fuel_vehicles() -> Array:
	var result: Array = []
	if current_planet() != "earth":
		return result
	for vehicle: Vehicle in world.vehicles.values():
		if vehicle.global_position.distance_to(world.local_player.global_position) <= 24.0:
			result.append(vehicle)
	return result


func locate(target: String) -> void:
	if _online and target.begins_with("town:"):
		var town: Dictionary = _network.town_info(target.trim_prefix("town:"))
		if not town.is_empty() and town.planet == current_planet():
			var site: FrontierSite = _town_entries.get(town.id, {}).get("site")
			var frame := FrontierTownLayout.world_frame(town, expedition.moon_world)
			waypoint = {"label": town.name, "position": site.surface_point(3.8, -0.3, 0.8) \
				if is_instance_valid(site) else frame.origin}
			ui.close()
			return
	for candidate: Dictionary in interactions():
		if str(candidate.get("id", "")) == target:
			waypoint = candidate.duplicate()
			ui.close()
			return
	last_message = "That workplace is on the other world. Travel there with your expedition."


func locate_rocket() -> void:
	waypoint = {"label": "Rocket boarding hatch", "position": expedition.rocket.boarding_global_position()}
	ui.close()


func set_observation(enabled: bool) -> void:
	_observation = enabled
	if expedition.moon_world.has_method("set_observation_mode"):
		expedition.moon_world.call("set_observation_mode", enabled)


func sky_targets() -> Array:
	var sky: Variant = expedition.moon_world.get("lunar_sky")
	return sky.get_targets() if sky and sky.has_method("get_targets") else []


func look_at_sky(direction: Vector3) -> void:
	if current_planet() != "moon" or not world.local_player.cam:
		return
	var camera := world.local_player.cam
	camera.set_view_mode(CameraRig.ViewMode.FIRST_PERSON)
	var basis := world.local_player.lunar_camera_sample().frame.basis as Basis
	var local_direction := (basis.inverse() * direction).normalized()
	camera.yaw = atan2(-local_direction.x, -local_direction.z)
	camera.pitch = asin(clampf(local_direction.y, -0.999, 0.999))
	ui.close()


func save_progress() -> bool:
	if _online:
		return _network.society_ready
	if not persistence_enabled or not simulation or save_path.is_empty():
		return false
	var saved: bool = simulation.save_game(save_path)
	if not saved:
		last_message = "Could not save your society. Check available disk space."
	return saved


func _exit_tree() -> void:
	save_progress()


func _configure_online() -> void:
	persistence_enabled = false
	simulation_enabled = false
	_network = Net.frontier_network
	_network.state_changed.connect(_on_shared_state)
	_network.traffic_changed.connect(_on_shared_traffic)
	_network.action_finished.connect(_on_shared_result)
	world.frontier = self
	for town: Dictionary in _network.catalog:
		_ensure_town_entry(town)
	_activate_town("canopy_moon" if current_planet() == "moon" else "canopy_earth")
	_build_ui()
	last_message = "Shared towns · E meets one neighbor or workplace · claim an unowned town at its community board."
	_sync_realm()
	if world.local_player:
		world.local_player.melee_mode = true
		world.local_player.rig.set_melee_pose(false, false, 0.0, 0)


func _ensure_town_entry(town: Dictionary) -> void:
	if town.is_empty():
		return
	var id := str(town.id)
	if _town_entries.has(id) or not _network.views.has(id):
		return
	var model: FrontierSim = load("res://scripts/frontier_remote_view.gd").new()
	model.state = _network.views[id].duplicate(true)
	var site := FrontierSite.new()
	site.name = id
	site.town_id = id
	site.world = world
	site.planet = str(town.planet)
	site.moon = expedition.moon_world if town.planet == "moon" else null
	(world if town.planet == "earth" else expedition.moon_world).add_child(site)
	site.global_transform = FrontierTownLayout.world_frame(town, expedition.moon_world)
	site.visible = false
	site.process_mode = Node.PROCESS_MODE_DISABLED
	var driver: Node3D
	if town.planet == "earth":
		driver = load("res://scripts/frontier_traffic.gd").new()
		site.add_child(driver)
		driver.configure(model, site, false, id)
		driver.build()
		if _network.traffic_views.has(id):
			driver.apply_snapshot(_network.traffic_views[id])
	var settlement: FrontierSettlement = load("res://scripts/frontier_settlement.gd").new()
	settlement.configure(site, model, str(town.planet), town)
	site.add_child(settlement)
	_town_entries[id] = {"site": site, "settlement": settlement, "simulation": model, "traffic": driver}
	_town_build_queue.append(id)
	if id == "canopy_earth":
		earth_site = site
		earth_settlement = settlement
	elif id == "canopy_moon":
		moon_site = site
		moon_settlement = settlement


func _activate_town(town_id: String) -> void:
	if not _town_entries.has(town_id):
		return
	if _active_town_id != town_id:
		if is_instance_valid(ui) and ui.visible:
			ui.close()
		selected_interaction.clear()
		waypoint.clear()
	_active_town_id = town_id
	simulation = _town_entries[town_id].simulation
	if town_id in _town_build_queue:
		_town_build_queue.erase(town_id)
		_town_build_queue.push_front(town_id)


func is_initial_ready() -> bool:
	if not _online:
		return true
	var settlement := current_settlement()
	return is_instance_valid(settlement) and settlement.is_build_complete()


func build_entry_step() -> void:
	if _town_build_queue.is_empty():
		return
	var id: String = _town_build_queue[0]
	var entry: Dictionary = _town_entries[id]
	if entry.settlement.build_step(2.0):
		_town_build_queue.pop_front()
		entry.site.visible = entry.site.planet == current_planet()
		entry.site.process_mode = Node.PROCESS_MODE_INHERIT if entry.site.visible else Node.PROCESS_MODE_DISABLED


func _process_online(delta: float) -> void:
	if not _pending_actions.is_empty() and Time.get_ticks_msec() >= _pending_retry_at and Net.active:
		# Retry the same sequence number if the server was busy. Its idempotency
		# record returns the original result rather than charging twice.
		var serial: int = _pending_actions.keys()[0]
		_network.rpc_id(1, "sv_action", serial, _pending_town, _pending_kind, _pending_actions[serial])
		_pending_retry_at = Time.get_ticks_msec() + 4000
	_sync_realm()
	build_entry_step()
	_town_refresh -= delta
	_refresh -= delta
	if _town_refresh <= 0 and world.local_player and Net.player_realm() != Net.PlayerRealm.TRANSIT:
		_town_refresh = 1.0
		var nearest: String = _network.nearest_town(world.local_player.global_position, current_planet())
		if not nearest.is_empty():
			_activate_town(nearest)
			_network.watch_town(nearest)
		for id in _town_entries:
			var entry: Dictionary = _town_entries[id]
			var show: bool = entry.site.planet == current_planet() and entry.settlement.is_build_complete()
			entry.site.visible = show
			var close_enough := world.local_player.global_position.distance_to(entry.site.global_position) < 430.0
			entry.site.process_mode = Node.PROCESS_MODE_INHERIT if show and close_enough else Node.PROCESS_MODE_DISABLED
	if _refresh <= 0:
		_refresh = 0.25
		for vehicle: Vehicle in world.vehicles.values():
			if vehicle.frontier_simulation != simulation:
				vehicle.configure_frontier_fuel(simulation)
		_refresh_overlays()
		_update_sun()


func _on_shared_state(town_id: String) -> void:
	_ensure_town_entry(_network.town_info(town_id))
	if _town_entries.has(town_id):
		_town_entries[town_id].simulation.state = _network.views[town_id].duplicate(true)
		_town_entries[town_id].settlement.town_info = _network.town_info(town_id)
		if town_id == _active_town_id:
			simulation = _town_entries[town_id].simulation


func _on_shared_traffic(town_id: String, rows: Array) -> void:
	var driver: Node3D = _town_entries.get(town_id, {}).get("traffic")
	if is_instance_valid(driver):
		driver.apply_snapshot(rows)


func _on_shared_result(request: int, kind: String, result: Dictionary) -> void:
	last_message = str(result.get("message", "The town has responded."))
	if tutorial and _pending_actions.has(request):
		tutorial.observe_action(kind, _pending_actions[request], result)
	_pending_actions.erase(request)


func current_town() -> Dictionary:
	if _online:
		return _network.town_info(_active_town_id)
	return {"id": "offline_" + current_planet(), "name": "Crater Gardens" if current_planet() == "moon" else "Canopy Commons",
		"planet": current_planet(), "is_owner": true, "claimed": true, "owner_name": "You"}


func known_towns() -> Array:
	return _network.catalog if _online else [current_town()]
