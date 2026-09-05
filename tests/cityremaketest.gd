extends Node
## End-to-end city remake coverage. Run through the main scene so terrain,
## player physics, arrival protection, and the actual renderer all participate.
const Plan = preload("res://scripts/city_plan.gd")
const ParkLayout=preload("res://scripts/city_park_layout.gd")
const City = preload("res://scripts/city_world.gd")
const OUTPUT := "res://artifacts/city-remake"
const SQUARE_METRES_PER_SQUARE_MILE := 2589988.110336

var passed := 0
var checks := 0
var _phase := ""
var _previous_usec := 0
var _samples: Dictionary = {}
var _report: Dictionary = {}
var _tallest: Dictionary = {}


func check(ok: bool, label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("CITYREMAKE %s %s" % ["PASS" if ok else "FAIL", label])


func run(main: Node, capture := false) -> void:
	var city: Node = main.frontier_controller.city
	var world: Node3D = main.world
	var player: MonkeyPlayer = world.local_player
	player.test_mode = true
	var diagnostics:=Timer.new();diagnostics.wait_time=10;diagnostics.process_mode=Node.PROCESS_MODE_ALWAYS
	add_child(diagnostics)
	diagnostics.timeout.connect(func():
		print("CITYREMAKE_PROGRESS phase=%s paused=%s far=%d queue=%d physics=%d"%[_phase,get_tree().paused,city.city_world.far_staged_block_count(),city.city_world.queued_block_count(),Engine.get_physics_frames()]))
	diagnostics.start()
	await get_tree().process_frame
	var installed := is_instance_valid(city.city_world) and is_instance_valid(city.crowd) \
		and is_instance_valid(city.panel)
	check(installed,
		"remade city is installed in the playable career scene")
	if not installed:
		_finish()
		return
	await _test_admin_clock(main)
	_test_plan(city)
	if _tallest.is_empty():
		_finish()
		return

	var origin: Dictionary = Plan.stops()[0]
	player.admin_teleport(origin.position + Vector3.UP * 0.1)
	var balance_before: int = main.frontier_controller.simulation.balance("player")
	city.travel_to_stop("lantern_square")
	check(main.frontier_controller.simulation.balance("player") == balance_before - 6,
		"village transit charges the existing six-credit fare")
	check(Vector2(player.position.x, player.position.z).distance_to(Plan.CENTER) < 0.1,
		"paid transit reaches the rebuilt city's central square")

	# Deliberately leave normal player physics running while the terrain lane is
	# stopped. This catches arrivals which appear safe only because tests freeze
	# the player or place a substitute floor under it.
	world.set_process(false)
	var arrival_y: float = player.position.y
	for frame in range(60): await get_tree().physics_frame
	check(city.arrival_pending() and player.arrival_locked
		and is_equal_approx(player.position.y, arrival_y),
		"one-second terrain stall holds the real player above unloaded ground")
	world.set_process(true)
	if not await _arrival(city, "Lantern Square"):
		_finish()
		return
	await _settle(city, 45)
	_check_floor(player, "Lantern Square")
	_check_collision_window(city.city_world)

	# The sampled outer roads are generated from the new municipal bounds.
	# Visiting both corners catches a renderer-only scale change which leaves
	# terrain or the streaming focus on the old footprint.
	for point in [
		Vector2(Plan.MIN_X + Plan.STREET_SPACING.x * 0.5, Plan.MIN_Z + Plan.STREET_SPACING.y * 0.5),
		Vector2(Plan.MAX_X - Plan.STREET_SPACING.x * 0.5, Plan.MAX_Z - Plan.STREET_SPACING.y * 0.5),
	]:
		var target := Vector3(point.x, Plan.GROUND_Y + 1.2, point.y)
		city._teleport(target)
		if not await _arrival(city, "municipal edge"):
			_finish()
			return
		await _settle(city, 40)
		_check_floor(player, "municipal edge %s" % str(point))
		_check_collision_window(city.city_world)

	city._teleport(_tallest.door + Vector3.UP * 1.2)
	if not await _arrival(city, "supertall entrance"):
		_finish()
		return
	await _settle(city, 45)
	_check_floor(player, "supertall entrance")
	_check_tower_collision(player, _tallest)
	check(Plan.nearest_building(_tallest.door, 0.1).get("id", "") == _tallest.id,
		"supertall entrance still resolves its stable property address")
	if not await _test_park(city, player):
		_finish()
		return
	if not await _test_retail(main, city, player, capture):
		_finish()
		return

	city._teleport(Vector3(Plan.CENTER.x, Plan.GROUND_Y + 1.2, Plan.CENTER.y))
	if not await _arrival(city, "return to center"):
		_finish()
		return
	_set_hour(main, 13.0)
	player.cam.yaw = -PI * 0.25
	player.cam.pitch = -0.12
	await _settle(city, 45)
	_start_sample("streaming")
	var staging_frames := 0
	var stayed_grounded := true
	var bounded_streaming := true
	while city.city_world.far_staged_block_count() < Plan.TOTAL_BLOCKS \
			and staging_frames < Plan.TOTAL_BLOCKS * 3:
		await get_tree().process_frame
		staging_frames += 1
		stayed_grounded = stayed_grounded and player.position.y >= Plan.GROUND_Y - 0.2 \
			and Plan.contains(Vector2(player.position.x, player.position.z))
		bounded_streaming = bounded_streaming \
			and city.city_world.last_built_this_tick() <= City.MAX_BLOCKS_PER_TICK \
			and city.city_world.last_far_staged_this_tick() <= City.MAX_FAR_BLOCKS_PER_TICK
	_stop_sample()
	check(city.city_world.far_staged_block_count() == Plan.TOTAL_BLOCKS,
		"all 2,496 blocks acquire a distant silhouette through normal streaming")
	check(stayed_grounded, "normal skyline streaming preserves the player's ground support")
	check(bounded_streaming, "detail and distant staging obey their per-frame budgets")
	_check_collision_window(city.city_world)
	check(city.crowd.actors.size() <= city.crowd.MAX_PEDESTRIANS + city.crowd.MAX_CARS,
		"street life remains within independent pedestrian and car caps")
	var far_bounds: AABB = city.city_world.far_lod_bounds()
	check(far_bounds.end.y >= Plan.GROUND_Y + float(_tallest.size.y),
		"distant draw bounds contain the full height of the tallest building")

	# Complete staging before this independent settled sample. Do not manually
	# prebuild far blocks or hide city geometry for either reported sample.
	for frame in range(60): await get_tree().process_frame
	_start_sample("settled")
	for frame in range(300): await get_tree().process_frame
	_stop_sample()
	_check_floor(player, "settled full city")
	_report["budget"] = city.city_world.node_budget_snapshot()
	_report["actors"] = city.crowd.actors.size()
	_report["viewport"] = str(main.get_viewport().get_visible_rect().size)
	_report["renderer"] = DisplayServer.get_name()
	_report["adapter"] = RenderingServer.get_video_adapter_name()
	_report["os"] = OS.get_name() + " " + OS.get_version()
	_report["native_rendering"] = DisplayServer.get_name() != "headless"
	_report["max_fps"] = Engine.max_fps
	_report["render_scale"] = main._render_scale
	_report["frames"] = {"streaming": _summary("streaming"), "settled": _summary("settled")}
	print("CITYREMAKE_BUDGET " + JSON.stringify(_report.budget))
	print("CITYREMAKE_ENV " + JSON.stringify({"renderer": _report.renderer,
		"adapter": _report.adapter, "os": _report.os, "viewport": _report.viewport,
		"max_fps": _report.max_fps, "render_scale": _report.render_scale}))
	print("CITYREMAKE_STREAM " + JSON.stringify(_report.frames.streaming))
	print("CITYREMAKE_FRAMES " + JSON.stringify(_report.frames.settled))
	if capture and DisplayServer.get_name() != "headless":
		await _capture_views(main, city)
	_finish()


func _test_admin_clock(main: Node) -> void:
	var frontier: Node = main.frontier_controller
	var sim: RefCounted = frontier.simulation
	var before := float(sim.state.time)
	main.admin_controller.run_command("/time 21:30")
	for frame in range(90): await get_tree().physics_frame
	check(main.world.time_of_day_hours >= 21.49 and main.world.time_of_day_hours < 21.7,
		"real /time HH:MM survives repeated Frontier updates")
	check(float(sim.state.time) >= before and float(sim.state.time) - before < 10.0,
		"changing solar time neither rewinds nor fast-forwards jobs and trade")
	main.admin_controller.run_command("/time day")
	for frame in range(45): await get_tree().physics_frame
	check(main.world.time_of_day_hours >= 12.0 and main.world.time_of_day_hours < 12.2,
		"named daylight command drives the actual live sky")
	main.admin_controller.run_command("/time clear")
	for frame in range(45): await get_tree().physics_frame
	check(absf(main.world.time_of_day_hours - fmod(float(sim.state.time),1200.0)/50.0) < 0.1,
		"clear returns to the continuously advancing society solar cycle")


func _test_plan(city: Node) -> void:
	var width := Plan.MAX_X - Plan.MIN_X
	var depth := Plan.MAX_Z - Plan.MIN_Z
	var area := width * depth / SQUARE_METRES_PER_SQUARE_MILE
	check(area > 29.5 and area < 30.5 and width > 5400.0 and depth > 14300.0,
		"physical city footprint is approximately 30 square miles")
	check(absf(area - Plan.SQUARE_MILES) < 0.01,
		"displayed city area agrees with generated municipal bounds")
	check(absf(float(city.city_view().city.area_sq_mi) - area) < 0.01,
		"career city guide reports the rebuilt physical area")
	var buildings := 0
	var tall_buildings := 0
	var tallest_height := 0.0
	for z in range(Plan.GRID_DEPTH):
		for x in range(Plan.GRID_WIDTH):
			for record in Plan.block_buildings(Vector2i(x, z)):
				buildings += 1
				var height: float = record.size.y
				if height >= 250.0: tall_buildings += 1
				if height > tallest_height:
					tallest_height = height
					_tallest = record
	check(buildings == Plan.ESTIMATED_BUILDING_COUNT,
		"remake preserves the complete deterministic building register")
	check(tall_buildings >= 5 and tall_buildings < 100 and tallest_height >= 600.0 and tallest_height <= 700.0,
		"skyline has occasional tall towers and a 600-metre landmark above varied neighborhoods")
	_report["city"] = {"width_m": width, "depth_m": depth, "area_sq_mi": area,
		"buildings": buildings, "towers_at_least_250m": tall_buildings,
		"tallest_height_m": tallest_height, "tallest_building": _tallest.get("id", "")}
	print("CITYREMAKE_PLAN " + JSON.stringify(_report.city))


func _arrival(city: Node, label: String) -> bool:
	var frames := 0
	while city.arrival_pending() and frames < 600:
		await get_tree().physics_frame
		frames += 1
	var ready: bool = not city.arrival_pending() and not city.world.local_player.arrival_locked
	check(ready, label + " releases arrival hold after collision is ready")
	return ready


func _settle(city: Node, frames: int) -> void:
	for frame in range(frames): await get_tree().physics_frame
	var remaining := 90
	while city.city_world.queued_block_count() > 0 and remaining > 0:
		await get_tree().process_frame
		remaining -= 1


func _check_floor(player: MonkeyPlayer, label: String, expected_y := Plan.GROUND_Y,
		tolerance := 0.25) -> void:
	var offsets := [Vector3.ZERO, Vector3(-0.4, 0.0, -0.4), Vector3(0.4, 0.0, -0.4),
		Vector3(-0.4, 0.0, 0.4), Vector3(0.4, 0.0, 0.4)]
	var supported := player.position.y >= expected_y - 0.2
	for offset in offsets:
		var at: Vector3 = player.position + offset
		var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 1.0,
			at - Vector3.UP * 3.0, 1, [player.get_rid()])
		var hit := player.get_world_3d().direct_space_state.intersect_ray(ray)
		supported = supported and not hit.is_empty()
		if not hit.is_empty():
			supported = supported and (hit.normal as Vector3).y > 0.8 \
				and absf((hit.position as Vector3).y - expected_y) < tolerance
	check(supported, label + " has level physical ground under the whole player footprint")


func _test_park(city: Node, player: MonkeyPlayer) -> bool:
	var land:=Plan.PARK_CENTER+Vector2(-80,-910)
	city._teleport(Vector3(land.x,Plan.GROUND_Y+1.2,land.y))
	if not await _arrival(city,"park footpath"):return false
	await _settle(city,40)
	_check_floor(player,"park footpath");_check_collision_window(city.city_world)
	var park_node:Node=city.park_world
	var deadline:=Time.get_ticks_msec()+20000
	while not park_node.is_build_complete() and Time.get_ticks_msec()<deadline:await get_tree().process_frame
	var park_stats:Dictionary=park_node.stats()
	check(park_stats.ready and park_stats.trees>1000 and park_stats.trees<4000 and park_stats.ground_vertices<30000 and park_stats.boat_count==4,
		"persistent large park, lake, woodland and four boats stay within their independent geometry budgets")
	var bottom:=Gen.height(Plan.POND_CENTER.x,Plan.POND_CENTER.y)
	check(is_equal_approx(bottom,Plan.GROUND_Y-1.6) and is_equal_approx(Plan.POND_SURFACE_Y-bottom,1.48),"boating lake shares the 1.6 metre basin and actual 1.48 metre central water depth")
	city._teleport(Vector3(Plan.POND_CENTER.x,bottom+1.2,Plan.POND_CENTER.y))
	if not await _arrival(city,"lake floor"):return false
	await _settle(city,40);_check_floor(player,"lake basin",bottom,.15)
	var bank_start:=Plan.pond_shore(-PI*.5,.90)
	city._teleport(Vector3(bank_start.x,Gen.height(bank_start.x,bank_start.y)+1.2,bank_start.y))
	if not await _arrival(city,"lake shore"):return false
	await _settle(city,40)
	var bank_supported:=true;var bank_walkable:=true
	for step in range(9):
		var point:=Plan.pond_shore(-PI*.5,.90+.14*float(step)/8)
		var height:=Gen.height(point.x,point.y)
		var ray:=PhysicsRayQueryParameters3D.create(Vector3(point.x,Plan.GROUND_Y+2,point.y),Vector3(point.x,Plan.GROUND_Y-2,point.y),1,[player.get_rid()])
		var hit:=player.get_world_3d().direct_space_state.intersect_ray(ray)
		bank_supported=bank_supported and not hit.is_empty()
		if not hit.is_empty():
			bank_supported=bank_supported and absf(hit.position.y-height)<.15
			bank_walkable=bank_walkable and hit.normal.y>=cos(deg_to_rad(20))
	check(bank_supported,"physical near-shore raycasts match the same irregular lake terrain")
	check(bank_walkable,"natural lake exit bank stays below a twenty-degree slope")
	var exit_z:=Plan.pond_shore(-PI*.5,1.015).y
	player.cam.yaw=0;player.ti.dir=Vector2(0,-1)
	var walked:=0
	while player.position.z>exit_z and walked<900:
		await get_tree().physics_frame;walked+=1
	player.ti.dir=Vector2.ZERO
	for frame in range(20):await get_tree().physics_frame
	check(player.position.z<=exit_z and player.position.y>=Plan.GROUND_Y-.15 and not player.arrival_locked,"real player walks from the shallow lake margin onto dry park land")
	_check_floor(player,"dry lake exit")
	var car_paths_clear:=true
	for actor in city.crowd.actors:
		if not actor.car:continue
		for point in actor.path:car_paths_clear=car_paths_clear and not Plan.is_park(Vector2(point.x,point.z))
	check(car_paths_clear,"nearby traffic stays outside the entire expanded pedestrian park")
	_report["park"]={"center":str(Plan.PARK_CENTER),"pond_depth_m":Plan.POND_DEPTH,"trees":park_stats.trees,"prop_instances":park_stats.prop_instances,"water_depth_m":Plan.POND_SURFACE_Y-bottom,"exit_walk_physics_frames":walked}
	return true


func _test_retail(main: Node, city: Node, player: MonkeyPlayer, capture: bool) -> bool:
	var market := Plan.building("crownreach-b24-24-l00")
	city._teleport(market.door + Vector3.UP * 1.2)
	if not await _arrival(city, "market front door"): return false
	await _settle(city, 25)
	var opened: bool = main.frontier_controller.try_interact(player)
	var right_door: bool = opened and city.panel.visible \
		and str(city.panel.context.get("id", "")) == str(market.id)
	check(right_door, "interact at the market's physical door opens its shop card")
	if not right_door: return false
	var buy: Button
	for node in city.panel.find_children("*", "Button", true, false):
		if str(node.get_meta("city_focus", "")) == "buy_store_item":
			buy = node
			break
	check(buy != null and not buy.disabled, "physical shop has an enabled Buy control")
	if buy == null or buy.disabled:
		city.panel.close()
		return false
	var sim = main.frontier_controller.simulation
	var credits_before: int = sim.balance("player")
	var bananas_before: int = sim.stock("player_earth", "banana")
	var store_before := int(sim.state.city.service_inventories.produce_market.get("banana", 0))
	buy.pressed.emit()
	await get_tree().process_frame
	check(sim.balance("player") == credits_before - 6,
		"actual shop Buy control charges exactly six credits")
	check(sim.stock("player_earth", "banana") == bananas_before + 1,
		"actual shop purchase adds one banana to the real Earth backpack")
	check(int(sim.state.city.service_inventories.produce_market.get("banana", 0)) == store_before - 1,
		"actual shop purchase removes the same banana from finite shared market stock")
	if capture and DisplayServer.get_name() != "headless":
		await _capture(main, "shop-frontdoor")
	city.panel.close()
	return true


func _check_collision_window(city_world: Node3D) -> void:
	var within_window := true
	var bodies := 0
	var shapes := 0
	var expected_shapes:=0
	var near := Plan.blocks_near(city_world._focus, City.COLLISION_RADIUS)
	for key in city_world._loaded_blocks:
		var entry: Dictionary = city_world._loaded_blocks[key]
		if near.has(key):
			for record in entry.records:
				for section in city_world._building_sections(record):
					if not section.get("disabled",false):expected_shapes+=1
		if is_instance_valid(entry.collision_body):
			bodies += 1
			shapes += int(entry.collision_shapes)
			within_window = within_window and near.has(key)
	check(city_world.visible_block_count() <= City.MAX_VISIBLE_BLOCKS \
		and bodies <= 9 and shapes == expected_shapes and within_window,
		"physical buildings stay inside the bounded neighborhood collision window")


func _check_tower_collision(player: MonkeyPlayer, record: Dictionary) -> void:
	var p: Vector3 = record.position
	var size: Vector3 = record.size
	var direction := Vector3(record.door.x - p.x, 0.0, record.door.z - p.z).normalized()
	var ray := PhysicsRayQueryParameters3D.create(record.door + direction * 2.0 + Vector3.UP * 1.0,
		p + Vector3.UP * 1.0, 1, [player.get_rid()])
	var hit := player.get_world_3d().direct_space_state.intersect_ray(ray)
	check(not hit.is_empty() and absf((hit.get("normal", Vector3.UP) as Vector3).y) < 0.2,
		"supertall podium has a physical wall behind its entrance")
	# The landmark's centerline must be solid high above street level, without
	# extending its collision invisibly beyond the published massing envelope.
	var height := size.y * 0.6
	ray = PhysicsRayQueryParameters3D.create(p + Vector3(-size.x, height, 0.0),
		p + Vector3(size.x, height, 0.0), 1, [player.get_rid()])
	hit = player.get_world_3d().direct_space_state.intersect_ray(ray)
	check(not hit.is_empty() and absf((hit.get("position", Vector3.INF) as Vector3).x - p.x) <= size.x * 0.5 + 0.1,
		"supertall upper mass has collision inside its visual envelope")


func _process(_delta: float) -> void:
	if _phase.is_empty(): return
	var now := Time.get_ticks_usec()
	if _previous_usec > 0:
		_samples[_phase].append(float(now - _previous_usec) / 1000.0)
	_previous_usec = now


func _start_sample(phase: String) -> void:
	_phase = phase
	_samples[phase] = []
	_previous_usec = 0


func _stop_sample() -> void:
	_phase = ""
	_previous_usec = 0


func _summary(phase: String) -> Dictionary:
	var values: Array = _samples.get(phase, []).duplicate()
	values.sort()
	if values.is_empty(): return {"frames": 0}
	var count := values.size()
	return {"frames": count, "p50_ms": values[mini(floori(count * 0.50), count - 1)],
		"p95_ms": values[mini(floori(count * 0.95), count - 1)],
		"p99_ms": values[mini(floori(count * 0.99), count - 1)], "max_ms": values[-1]}


func _capture_views(main: Node, city: Node) -> void:
	var hidden_layers: Array[Dictionary] = []
	for layer in main.find_children("*", "CanvasLayer", true, false):
		hidden_layers.append({"node": layer, "visible": layer.visible})
		layer.visible = false
	var player: MonkeyPlayer = main.world.local_player
	var player_was_visible := player.visible
	player.visible = false
	var previous_camera: Camera3D = main.get_viewport().get_camera_3d()
	var camera := Camera3D.new()
	main.world.add_child(camera)
	camera.far = maxf(Plan.MAX_X-Plan.MIN_X,Plan.MAX_Z-Plan.MIN_Z)*1.6
	camera.fov = 72.0
	camera.make_current()
	var center := Vector3(Plan.CENTER.x, Plan.GROUND_Y, Plan.CENTER.y)
	_set_hour(main, 13.0)
	camera.global_position = center + Vector3(-6.0, 1.8, -10.0)
	camera.look_at(center + Vector3(95.0, 55.0, 95.0))
	await _capture(main, "street-day")
	var skyline := center + Vector3(-Plan.STREET_SPACING.x*8,1.2,-Plan.STREET_SPACING.y*6)
	city._teleport(skyline)
	if await _arrival(city, "skyline capture street"):
		await _settle(city, 40)
		_set_hour(main, 17.5)
		camera.global_position = skyline + Vector3(0.0, 450.0, 0.0)
		camera.look_at(center + Vector3(0.0, 180.0, 0.0))
		camera.fov = 68.0
		await _capture(main, "skyline-dusk")
	_set_hour(main, 13.0)
	camera.global_position = center + Vector3(-2500.0, 1500.0, -3000.0)
	camera.look_at(center + Vector3.UP * 100.0)
	camera.fov = 75.0
	# The Earth streamer follows the real player, including altitude. Move and
	# hold that focus at the aerial camera so this view includes the same terrain
	# and altitude LODs that actual flight would request. The next park teleport
	# replaces this temporary hold with its normal grounded arrival handoff.
	player.admin_teleport(camera.global_position)
	player.arrival_locked = true
	main.world._reset_planet_stream_focus()
	city.city_world.update_focus(player.global_position)
	var aerial_ready_at := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < aerial_ready_at:
		await get_tree().process_frame
	await _capture(main, "city-aerial-day")
	var park_view:=ParkLayout.boathouse_position()+Vector3(22,1.2,-36)
	city._teleport(park_view)
	if await _arrival(city, "park capture footpath"):
		await _settle(city, 40)
		_set_hour(main, 13.0)
		camera.global_position = park_view + Vector3.UP * 3.3
		camera.look_at(Vector3(Plan.POND_CENTER.x, Plan.GROUND_Y + 0.4, Plan.POND_CENTER.y))
		camera.fov = 70.0
		await _capture(main, "park-pond-day")
	city._teleport(center + Vector3.UP * 1.2)
	if await _arrival(city, "night capture street"):
		await _settle(city, 40)
		_set_hour(main, 23.0)
		camera.global_position = center + Vector3(5.0, 1.8, 12.0)
		camera.look_at(center + Vector3(110.0, 32.0, -95.0))
		camera.fov = 72.0
		await _capture(main, "street-night")
	var beacon := Plan.building("crownreach-b24-24-l02")
	var roof := Vector3(beacon.position.x, Plan.GROUND_Y + beacon.size.y - 6.4, beacon.position.z)
	camera.global_position = roof + Vector3(0,0,13.0)
	camera.look_at(roof + Vector3(220,-140,330))
	camera.fov = 75.0
	await _capture(main, "rooftop-city-night")
	if is_instance_valid(previous_camera): previous_camera.make_current()
	camera.queue_free()
	player.visible = player_was_visible
	for saved in hidden_layers:
		if is_instance_valid(saved.node): saved.node.visible = saved.visible


func _set_hour(main: Node, hour: float) -> void:
	main.frontier_controller.set_solar_hour(hour)


func _capture(main: Node, name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	for frame in range(45): await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := OUTPUT.path_join(name + ".png")
	var error := main.get_viewport().get_texture().get_image().save_png(path)
	check(error == OK, "saved native " + name + " capture")
	print("CITYREMAKE_CAPTURE " + ProjectSettings.globalize_path(path))


func _finish() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	_report["checks"] = checks
	_report["passed"] = passed
	var file := FileAccess.open(OUTPUT.path_join("validation.json"), FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(_report, "\t") + "\n")
	print("CITYREMAKETEST %d/%d %s" % [passed, checks, "PASS" if passed == checks else "FAIL"])
	get_tree().quit(0 if passed == checks else 1)
