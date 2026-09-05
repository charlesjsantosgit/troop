extends Node
## Context and authority-bound UI plus room collision. No player saves/network.
const PanelScript = preload("res://scripts/city_panel.gd")
const InteriorScript = preload("res://scripts/city_interior.gd")
const EconomyScript = preload("res://scripts/city_economy.gd")
const ControllerScript = preload("res://scripts/city_controller.gd")
var passed := 0
var total := 0
var ui: Control
var root: Window:
	get: return get_tree().root
var fake: Node
const OUTPUT := "res://artifacts/crownreach-ui/"

class FakeController extends Node:
	var view: Dictionary = {}
	var requests: Array = []
	var transitions: Array = []
	var last_message := ""
	var async_reply := false
	func city_view() -> Dictionary: return view.duplicate(true)
	func request_action(kind: String, payload: Dictionary) -> Dictionary:
		requests.append({"kind": kind, "payload": payload.duplicate(true)})
		view.action_pending = async_reply
		last_message = "Request accepted for processing."
		return {"ok": true, "pending": async_reply, "message": last_message}
	func enter_building(id: String) -> void: transitions.append(["enter", id])
	func exit_building() -> void: transitions.append(["exit"])
	func travel_to_stop(id: String) -> void: transitions.append(["travel", id])
	func navigate_to(point: Vector3) -> void: transitions.append(["navigate", point])
	func close_panel() -> void: pass

class ProjectionModel extends RefCounted:
	var state := {"accounts": {"player": 901}, "inventories": {"player_earth": {"banana": 9}}, "time": 100.0}

class ProjectionFrontier extends Node:
	signal backpack_changed
	var simulation := ProjectionModel.new()
	var realm := "earth"
	var ui: Control
	func current_planet() -> String: return realm

class ProjectionNetwork extends Node:
	var cached_view := {"credits": 50, "backpack_counts": {"banana": 1}, "time": 90.0,
		"owned_properties": [{"building": "home-a", "storage_included": false, "storage": {}}]}

class ProjectionPlayer extends Node3D:
	var vehicle: Node
	var expedition_locked := false
	var arrival_locked := false

class ProjectionWorld extends Node3D:
	var local_player: Node3D

class ProjectionPanel extends Control:
	var refreshes := 0
	func refresh_view() -> void: refreshes += 1

func run() -> void:
	call_deferred("_run")

func _run() -> void:
	fake = FakeController.new()
	fake.view = _fixture()
	root.add_child(fake)
	ui = PanelScript.new()
	ui.configure(fake)
	root.add_child(ui)
	await get_tree().process_frame
	for dimensions in [Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		ui.open({"kind": "building", "id": "home-a", "name": "Willow Cottage", "housing": "cottage", "district": "Village"})
		await _settle()
		var buy := _button("buy_home")
		print("CITY_UI_GEOMETRY viewport=%s panel=%s minimum=%s body=%s purchase=%s" % [root.get_visible_rect(), ui._panel.get_global_rect(), ui._panel.get_combined_minimum_size(), ui._body.size, buy.get_global_rect()])
		_check(ui._panel.size.x <= dimensions.x - 60 and ui._panel.size.y <= dimensions.y - 60,
			"property panel keeps the world visible at %s" % dimensions)
		_check(buy != null and not buy.disabled and buy.text.contains("450") and ui._panel.get_global_rect().encloses(buy.get_global_rect()),
			"property price and purchase remain visible at %s" % dimensions)
		_check(is_equal_approx(ui._panel.get_theme_stylebox("panel").bg_color.a, 1), "property panel is opaque at %s" % dimensions)
		await _capture("property-%dx%d" % [dimensions.x, dimensions.y])
	_check(ui._subtitle.text == "CROWNREACH · Village", "explicit district names remain readable in property subtitles")
	ui.open({"kind": "building", "id": "home-a", "name": "Willow Cottage", "housing": "cottage", "district": 6})
	await _settle()
	_check(ui._subtitle.text == "CROWNREACH · Lantern", "numeric building district resolves to its actual district name")
	ui.open({"kind": "building", "id": "home-a", "name": "Willow Cottage", "housing": "cottage", "district": -1})
	await _settle()
	_check(ui._subtitle.text == "CROWNREACH · Town housing", "outlying housing never shows a negative district number")
	var before: Dictionary = fake.view.duplicate(true)
	fake.async_reply = true
	_button("buy_home").pressed.emit()
	_button("buy_home").pressed.emit()
	_check(fake.requests.size() == 1 and fake.requests[0] == {"kind": "buy_home", "payload": {"building": "home-a"}}, "purchase sends one exact building request while confirmation is pending")
	_check(fake.view.credits == before.credits and fake.view.owned_properties.is_empty(), "UI never predicts ownership or spends authoritative credits")
	_check(not _button("close").disabled and not _button("help").disabled, "close and help remain usable during network wait")
	fake.view.action_pending = false
	fake.async_reply = false
	fake.view.credits = 100
	ui.refresh_view()
	_check(_button("buy_home").disabled and ui._wallet.text.contains("100"), "authoritative balance immediately changes price eligibility")
	fake.view.credits = 9000
	ui.open({"kind": "info", "id": "home-a", "name": "Remote guide", "housing": "cottage"})
	await _settle()
	_check(_button("buy_home") != null and _button("buy_home").disabled, "an informational property preview cannot buy remotely")
	fake.view.owned_properties = [{"building": "home-a", "tier": "cottage", "name": "Willow Cottage", "storage_capacity": 80, "storage_used": 4, "storage": {"tomato": 4}, "is_home": false}]
	fake.view.owned_properties[0].storage_included = false
	fake.view.owned_properties[0].storage = {}
	ui.open({"kind": "storage", "property": "home-a", "name": "Willow Cottage", "housing": "cottage"})
	await _settle()
	_check(_button("transfer") == null and ui._tiles.is_empty(), "a summary-only property view cannot display a false empty cupboard or transfer goods")
	fake.view.owned_properties[0].storage_included = true
	ui.refresh_view()
	await _settle()
	_check(_button("transfer") != null, "an empty but confirmed cupboard replaces the loading state without reopening")
	fake.view.owned_properties[0].storage = {"tomato": 4}
	ui.refresh_view()
	await _settle()
	_check(ui._tiles.size() == 3 and ui._tiles.all(func(tile): return tile.node.is_visible_in_tree()), "home storage and backpack show separate actual stocks")
	var transfer := _button("transfer")
	_check(transfer != null and ui._panel.get_global_rect().encloses(transfer.get_global_rect()), "storage quantity and transfer action remain visible at 960x540")
	_check(ui._tiles.all(func(tile): return is_equal_approx(tile.node.get_theme_stylebox("normal").bg_color.a, 1)), "all inventory tiles are opaque")
	await _capture("storage-960x540")
	ui._selected_item = "banana"
	ui._selected_side = "backpack"
	ui._quantity = 2
	ui._refresh_live()
	transfer.pressed.emit()
	_check(fake.requests[-1] == {"kind": "store_item", "payload": {"building": "home-a", "item": "banana", "quantity": 2}}, "storage sends exact selected item and finite quantity")
	var identity := transfer.get_instance_id()
	transfer.grab_focus()
	fake.view.backpack_counts.banana = 1
	ui.refresh_view()
	_check(_button("transfer").get_instance_id() == identity and transfer.disabled and root.gui_get_focus_owner() == transfer, "stock refresh preserves focused controls and blocks an unavailable quantity")
	fake.view.owned_properties[0].storage_used = 80
	ui._quantity = 1
	ui.refresh_view()
	_check(transfer.disabled, "full private storage blocks a deposit without changing stock")
	ui.open({"kind": "bed", "property": "home-a", "name": "Willow Cottage", "housing": "cottage"})
	await _settle()
	_check(_button("set_home") != null and not _button("set_home").disabled, "owned residential bed offers the home action")
	fake.view.active_job = {"id": "delivery-1", "label": "Lantern parcel", "destination_building": "mixed-use", "ready_at": 110.0, "reward": 90, "cargo": {"parcel": 1}, "carry_mode": "sealed_job_cargo"}
	ui.open({"kind": "building", "id": "mixed-use", "name": "Lantern Apartments", "housing": "work_live"})
	await _settle()
	_check(_button("buy_home") != null and _button("finish_job") != null, "mixed-use property door exposes its actual delivery service alongside housing")
	_check(ui._scroll.get_global_rect().encloses(_button("finish_job").get_global_rect()), "mixed-use delivery completion stays above the property information")
	_check(ui._body.find_children("*", "Label", true, false).any(func(label): return label.text.contains("separate from your backpack")), "sealed assignment cargo is explained separately from personal inventory")
	_check(_button("enter_workplace") != null, "mixed-use workplace can be visited without buying its private housing")
	_check(_button("finish_job").disabled and _button("buy_home").text.contains("1,600"), "job clock and normalized mixed-use housing tier remain separate")
	fake.view.now = 111.0
	ui.refresh_view()
	_check(not _button("finish_job").disabled, "authoritative job readiness enables finishing at the exact destination")
	_button("finish_job").pressed.emit()
	_check(fake.requests[-1] == {"kind": "finish_job", "payload": {}}, "job completion sends no client-selected reward or completion time")
	ui.open({"kind": "interior", "property": "mixed-use", "name": "Lantern Apartments", "housing": "work_live"})
	await _settle()
	_check(_button("finish_job") != null and _button("exit") != null and _button("buy_home") == null, "unowned mixed-use interior retains workplace completion and a clear exit")
	fake.view.active_job = {}
	ui.open({"kind": "building", "id": "depot", "name": "Courier Depot", "service": "courier_depot"})
	await _settle()
	_check(_button("start_courier") != null and _button("enter_public") != null and _button("buy_home") == null, "public workplace offers its actual job and interior without invented housing")
	await _capture("workplace-960x540")
	ui.open({"kind": "interior", "property": "depot", "name": "Courier Depot", "service": "courier_depot"})
	await _settle()
	_check(_button("start_courier") != null and not _button("start_courier").disabled and _button("exit") != null, "physical workplace noticeboard offers the same real job inside")
	_button("start_courier").pressed.emit()
	_check(fake.requests[-1] == {"kind": "start_job", "payload": {"job": "courier"}}, "interior job request sends its catalog ID without client authority fields")
	fake.view.job_catalog[0].available = false
	fake.view.job_catalog[0].availability = "Depot supplies are depleted"
	ui.refresh_view()
	_check(_button("start_courier").disabled and ui._body.find_children("*", "Label", true, false).any(func(label): return label.text == "Depot supplies are depleted"), "empty depot supply is visible and blocks starting an unavailable courier job")
	for id in ["courier_clinic", "courier_rail", "restock_depot_meals", "restock_depot_parts", "restock_depot_packaging"]:
		var job: Dictionary = fake.view.job_catalog[0].duplicate(true)
		var catalog: Dictionary = EconomyScript.JOBS[id]
		for field in ["id", "label", "description", "duration", "reward", "requires"]:
			job[field] = catalog[field]
		job.available = true
		job.availability = ""
		fake.view.job_catalog.append(job)
	fake.view.backpack_counts.packaging = 6
	ui.refresh_view()
	await _settle()
	_button("choose_job_restock_depot_packaging").grab_focus()
	_button("choose_job_restock_depot_packaging").pressed.emit()
	await _settle()
	_check(_button("start_restock_depot_packaging") != null and _button("start_courier") == null, "six workplace choices expose one selected job's details and action")
	_check(root.gui_get_focus_owner() == _button("choose_job_restock_depot_packaging"), "job selection preserves keyboard focus on the chosen row after its details change")
	_check(ui._scroll.get_global_rect().encloses(_button("start_restock_depot_packaging").get_global_rect()), "six-job workplace keeps the selected action visible at 960x540")
	_button("start_restock_depot_packaging").pressed.emit()
	_check(fake.requests[-1] == {"kind": "start_job", "payload": {"job": "restock_depot_packaging"}}, "selecting another assignment dispatches its exact catalog ID")
	await _capture("workplace-sixjobs-960x540")
	ui.open({"kind": "transit", "id": "village", "name": "Village Stop"})
	await _settle()
	_check(_button("travel_lantern") != null and _button("travel_lantern").text.contains("6"), "transit shows its actual fare before travel")
	fake.view.credits = 0
	ui.refresh_view()
	_check(_button("travel_lantern").disabled, "unaffordable transit cannot be clicked")
	ui.open({"kind": "info", "name": "Crownreach guide"})
	await _settle()
	var selector := _button("district_selector") as OptionButton
	_check(selector != null and selector.item_count == 2 and ui._district().food_stock == 120, "one compact district selector exposes actual economic conditions")
	selector.select(1)
	selector.item_selected.emit(1)
	_check(ui._district().name == "Canals" and ui._district().workforce == 2400, "district selection changes the food, work and service facts together")
	var selector_id := selector.get_instance_id()
	fake.view.districts[1].food_stock = 7
	ui.refresh_view()
	_check(_button("district_selector").get_instance_id() == selector_id and ui._district().food_stock == 7, "changing district stocks refreshes without rebuilding selection")
	await _capture("district-guide-960x540")
	ui.close()
	if DisplayServer.get_name() != "headless": await get_tree().create_timer(0.15).timeout
	_check(not ui.visible, "closing releases the panel")
	_check_controller_guards()
	await _check_rooms()
	print("CITYUITEST %d/%d %s" % [passed, total, "PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)

func _check_controller_guards() -> void:
	var controller := ControllerScript.new()
	controller.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(controller)
	var projection := ProjectionFrontier.new()
	var network := ProjectionNetwork.new()
	var world := ProjectionWorld.new()
	var player := ProjectionPlayer.new()
	var panel := ProjectionPanel.new()
	controller.add_child(projection)
	controller.add_child(network)
	controller.add_child(world)
	controller.add_child(panel)
	world.add_child(player)
	world.local_player = player
	projection.ui = panel
	controller.frontier = projection
	controller.world = world
	controller.panel = panel
	controller._network = network
	var shown: Dictionary = controller.city_view()
	_check(shown.credits == 901 and shown.backpack_counts == {"banana": 9} and shown.owned_properties.size() == 1,
		"city controller projects newer shared wallet/bag fields while retaining private property metadata")
	shown.backpack_counts.banana = 200
	_check(projection.simulation.state.inventories.player_earth.banana == 9, "displayed inventory cannot mutate the authoritative town projection")
	projection.realm = "moon"
	var rejection: Dictionary = controller.request_action("buy_home", {"building": "home-a"})
	_check(not rejection.ok and controller.last_message == rejection.message and panel.refreshes == 1,
		"on-foot Earth rejection persists in controller feedback and refreshes the visible panel")
	projection.realm = "earth"
	controller._pending = 22
	controller._on_result(21, "inspect", {"ok": false, "message": "An earlier inspection failed."})
	_check(controller._pending == 22, "a late unrelated result cannot clear the active city request")
	controller._on_result(22, "buy_home", {"ok": false, "message": "This property is already owned."})
	_check(controller._pending == 0 and controller.last_message == "This property is already owned.",
		"a matching denied result clears waiting and preserves the authoritative reason")
	player.arrival_locked = true
	player.expedition_locked = true
	# Keep the player alive across the controller's actual exit-tree callback.
	world.reparent(root)
	controller.free()
	_check(not player.arrival_locked and player.expedition_locked,
		"controller cleanup releases the arrival hold without changing the rocket lock")
	world.free()

func _check_rooms() -> void:
	var room := InteriorScript.new()
	root.add_child(room)
	var camera: Camera3D
	var lighting: WorldEnvironment
	if DisplayServer.get_name() != "headless":
		root.size = Vector2i(1280, 720)
		root.content_scale_size = Vector2i(1280, 720)
		lighting = WorldEnvironment.new()
		lighting.environment = Environment.new()
		lighting.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		lighting.environment.ambient_light_color = Color("c0ccd2")
		lighting.environment.ambient_light_energy = 0.25
		root.add_child(lighting)
		camera = Camera3D.new()
		camera.fov = 82
		root.add_child(camera)
		camera.make_current()
	for tier in ["cottage", "town_apartment", "suburban_home", "city_apartment", "penthouse", "warehouse", ""]:
		var data := {"id": "fixture-room", "housing": tier}
		room.build(data)
		await get_tree().physics_frame
		await get_tree().physics_frame
		_check(room.dimensions == InteriorScript.room_dimensions(data) and room.service_points() == InteriorScript.service_layout(data), "room and pure authority service layout agree for %s" % tier)
		_check(room.get_child_count() < 65 and room.dimensions.x <= 30 and room.dimensions.z <= 28, "detailed %s room stays spatially bounded with batched furnishings" % tier)
		var space := room.get_world_3d().direct_space_state
		var floor_query := PhysicsRayQueryParameters3D.create(Vector3(0, 1.9, 0), Vector3(0, -1, 0), 1)
		var floor_hit := space.intersect_ray(floor_query)
		_check(not floor_hit.is_empty() and absf(floor_hit.position.y) < 0.01, "%s interior has one grounded floor surface" % tier)
		var front := -room.dimensions.z * 0.5
		var doorway_query := PhysicsRayQueryParameters3D.create(Vector3(0, 1.1, front + 0.8), Vector3(0, 1.1, front - 0.8), 1)
		_check(space.intersect_ray(doorway_query).is_empty(), "%s doorway is visibly and physically open" % tier)
		var services: Dictionary = room.service_points()
		_check(services.has("exit") and (not services.has("bed") if tier in ["warehouse", ""] else services.has("bed")), "%s services match housing use and always provide an exit" % tier)
		_check(not room.interact("storage", Vector3(100, 100, 100)), "%s service rejects an out-of-range interaction" % tier)
		var approach_clear := true
		var approach_shape := CapsuleShape3D.new()
		approach_shape.height = 1.8288
		approach_shape.radius = 0.32
		for key: String in services:
			var point: Vector3 = services[key].position
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = approach_shape
			query.transform.origin = Vector3(point.x, 0.06 + approach_shape.height * 0.5, point.z)
			query.collision_mask = 1
			approach_clear = approach_clear and space.intersect_shape(query, 1).is_empty()
			approach_clear = approach_clear and room.interact(str(services[key].kind), Vector3(point.x, 0.06, point.z))
		_check(approach_clear, "%s service points fit a standing six-foot player and accept their canonical interaction kind" % tier)
		if camera and tier in ["cottage", "penthouse", "warehouse", ""]:
			camera.position = Vector3(-room.dimensions.x * 0.12, 1.72, -room.dimensions.z * 0.5 + 0.5)
			camera.look_at(Vector3(room.dimensions.x * 0.07, 1.25, room.dimensions.z * 0.3))
			await _settle()
			await _capture("interior-" + (tier if not tier.is_empty() else "workplace"))
	room.build({"id": "walkable", "housing": "cottage"})
	var actor := CharacterBody3D.new()
	actor.collision_layer = 1
	actor.collision_mask = 1
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.8288
	capsule.radius = 0.32
	shape.shape = capsule
	shape.position.y = capsule.height * 0.5
	actor.add_child(shape)
	root.add_child(actor)
	actor.position = room.spawn_point()
	for _frame in range(100):
		await get_tree().physics_frame
		actor.velocity = Vector3(0, -2, -2)
		actor.move_and_slide()
	_check(actor.position.z < -room.dimensions.z * 0.5 - 0.5 and actor.position.y > -0.05, "six-foot capsule walks through the doorway into a supported vestibule")
	actor.queue_free()
	room.queue_free()
	if camera: camera.queue_free()
	if lighting: lighting.queue_free()
	await get_tree().process_frame

func _fixture() -> Dictionary:
	return {"city": {"name": "Crownreach", "population": 400000, "area_sq_mi": 204.96}, "credits": 9000, "now": 100.0,
		"backpack_capacity": 350, "bus_fare": 6, "action_pending": false, "backpack_counts": {"banana": 12, "tomato": 3},
		"backpack": [{"id": "banana", "label": "Banana", "count": 12}, {"id": "tomato", "label": "Tomato", "count": 3}],
		"owned_properties": [], "unavailable_buildings": [], "active_job": {},
		"housing_catalog": [{"id": "cottage", "label": "Village cottage", "price": 450, "storage_capacity": 80, "luxury": 1, "residential": true},
			{"id": "city_apartment", "label": "Large city apartment", "price": 1600, "storage_capacity": 180, "luxury": 3, "residential": true}],
		"job_catalog": [{"id": "courier", "label": "Courier run", "description": "Take a parcel to its customer.", "start_building": "depot", "destination_building": "mixed-use", "reward": 90, "duration": 60, "requires": {}}],
		"services": {"delivery": {"building": "mixed-use", "label": "Lantern Delivery", "door": [10, 8, 20]}},
		"districts": [{"id": 6, "name": "Lantern", "kind": "civic", "population": 30000, "workforce_capacity": 15000, "workforce": 14000, "food_stock": 120, "food_demand": 20, "service_condition": 0.9, "shortages": 0},
			{"id": 1, "name": "Canals", "kind": "industrial", "population": 20000, "workforce_capacity": 10000, "workforce": 2400, "food_stock": 15, "food_demand": 18, "service_condition": 0.6, "shortages": 4}],
		"stops": [{"id": "village", "name": "Village Stop", "position": Vector3.ZERO}, {"id": "lantern", "name": "Lantern Square", "position": Vector3(14000, 8, 0)}]}

func _button(key: String) -> Button:
	for node in ui.find_children("*", "Button", true, false):
		if str(node.get_meta("city_focus", "")) == key: return node
	return null

func _settle() -> void:
	for _frame in range(8): await get_tree().process_frame
	if DisplayServer.get_name() != "headless": await get_tree().create_timer(0.22).timeout

func _capture(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUTPUT + label + ".png")

func _check(condition: bool, label: String) -> void:
	total += 1
	passed += int(condition)
	print("  [%s] %s" % ["ok" if condition else "FAIL", label])
