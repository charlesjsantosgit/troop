extends Node
const Plan = preload("res://scripts/city_plan.gd")
var passed := 0
var checks := 0
var samples: Array[float] = []

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("CITYPLAY %s %s" % ["PASS" if ok else "FAIL", label])

func run(main: Node, capture := false) -> void:
	var city: Node = main.frontier_controller.city
	var frontier: Node = main.frontier_controller
	var player: MonkeyPlayer = main.world.local_player
	player.test_mode = true
	var sim = frontier.simulation
	var cottage := Plan.building("village-cottage")
	await get_tree().process_frame
	check(is_instance_valid(city.city_world) and is_instance_valid(city.panel), "city is installed in actual career scene")
	check(is_equal_approx(Gen.height(14400, 0), Plan.GROUND_Y) \
		and is_equal_approx(Gen.terrain_vertex_sample(15000, 1200).elevation, Plan.GROUND_Y), "terrain physics and combined visual sampler use city grade")
	check(Gen.chunk_layout(300, 0).trees.is_empty() and Gen.skyline_tree_layout(300, 0).is_empty() \
		and Gen.canopy_cover(8, 14400, 0) == 0, "all vegetation tiers reserve city streets and buildings")
	player.admin_teleport(cottage.door + Vector3(0, 0.1, 0))
	check(frontier.try_interact(player) and city.panel.visible \
		and city.panel.context.id == cottage.id, "E opens the actual cottage panel")
	var before: int = sim.balance("player")
	var buy: Button = _button(city.panel, "buy_home")
	check(buy != null and not buy.disabled, "physical cottage has affordable purchase control")
	if buy: buy.pressed.emit()
	check(sim.balance("player") == before - 450, "UI purchase transfers exactly 450 credits")
	city.enter_building(cottage.id)
	await get_tree().physics_frame
	await _arrival(city)
	while city.panel.visible: await get_tree().process_frame
	check(city.is_inside() and player.position.y < -490, "entry builds and visits physical interior")
	if not city.is_inside():
		_finish()
		return
	check(main.world.void_rescue_height(player) == -510, "room does not trigger outdoor void rescue")
	check(player.cam._cam.environment != null and not player.cam._cam.environment.fog_enabled, "indoor camera excludes outdoor height fog")
	check(not main.world.seasonal_weather.atmosphere_enabled(), "outdoor precipitation stays outside the room")
	var points: Dictionary = city.interior.service_points()
	player.admin_teleport(city.interior.to_global(points.storage.position))
	check(frontier.try_interact(player) and city.panel.context.kind == "storage", "cupboard opens two-sided inventory at physical location")
	var bananas: int = sim.stock("player_earth", "banana")
	check(city.request_action("store_item", {"building": cottage.id, "item": "banana", "quantity": 2}).ok \
		and sim.stock("player_earth", "banana") == bananas - 2, "deposit moves actual backpack goods")
	check(city.request_action("take_item", {"building": cottage.id, "item": "banana", "quantity": 1}).ok \
		and sim.stock("player_earth", "banana") == bananas - 1, "withdrawal returns actual stored goods")
	city.panel.close()
	player.admin_teleport(city.interior.to_global(points.bed.position))
	check(city.request_action("set_home", {"building": cottage.id}).ok \
		and city.home_destination() != Vector3.INF, "bed selects a persistent respawn address")
	if capture:
		player.admin_teleport(city.interior.to_global(city.interior.spawn_point()))
		player.cam.yaw = city.interior.spawn_yaw()
		player.cam.pitch = 0.0
		for i in range(90): await get_tree().process_frame
		await _capture(main, "cottage-interior")
	city.exit_building()
	await get_tree().physics_frame
	await _arrival(city)
	check(not city.is_inside() and player.position.distance_to(cottage.door) < 4.0, "exit returns to the same building door")
	check(player.cam._cam.environment == null and main.world.seasonal_weather.atmosphere_enabled(), "exit restores outdoor environment and weather")
	check(not city.request_action("store_item", {"building": cottage.id, "item": "banana", "quantity": 1}).ok, "outside storage requests are rejected")
	var stop: Dictionary = Plan.stops()[0]
	player.admin_teleport(stop.position + Vector3(0, 0.1, 0))
	check(frontier.try_interact(player) and city.panel.context.kind == "transit", "village bus stop opens transit destinations")
	before = sim.balance("player")
	city.travel_to_stop("lantern_square")
	check(sim.balance("player") == before - 6 and Vector2(player.position.x, player.position.z).distance_to(Plan.CENTER) < 1.0, "paid transit arrives in the same-world city square")
	# Reproduce a slow terrain handoff while normal player physics keeps running.
	# One second exceeds the half-second fall time from the bus landing height.
	main.world.set_process(false)
	var arrival_height: float = player.position.y
	for i in range(60): await get_tree().physics_frame
	check(city.arrival_pending() and player.arrival_locked \
		and is_equal_approx(player.position.y, arrival_height), "slow terrain streaming cannot drop an arriving player through the floor")
	main.world.set_process(true)
	await _arrival(city)
	check(not city.arrival_pending() and not player.arrival_locked,
		"arrival releases movement after the whole foot placement has collision")
	for i in range(240): await get_tree().physics_frame
	check(city.city_world.get_child_count() < 200, "stream root remains bounded for a 2304-block city")
	check(city.crowd.actors.size() <= 20, "local crowd and traffic obey independent actor caps")
	var profiling := OS.get_cmdline_user_args().has("cityprofile")
	if profiling:
		# Diagnostic only: prepare the complete skyline before A/B rendering
		# samples. This path is never used to claim streaming frame-time results.
		while city.city_world.far_staged_block_count() < Plan.GRID_SIZE * Plan.GRID_SIZE:
			city.city_world._stage_one_far_block()
		for i in range(90): await get_tree().process_frame
	if capture or OS.get_cmdline_user_args().has("citysoak"):
		var streaming_samples: Array[float] = []
		var previous_stream := Time.get_ticks_usec()
		while city.city_world.far_staged_block_count() < Plan.GRID_SIZE * Plan.GRID_SIZE:
			await get_tree().process_frame
			if streaming_samples.size() % 120 == 0 or player.position.y < 7.8:
				var ray := PhysicsRayQueryParameters3D.create(player.position + Vector3.UP * 2,
					player.position - Vector3.UP * 10, 1, [player.get_rid()])
				var hit := player.get_world_3d().direct_space_state.intersect_ray(ray)
				print("CITYPLAY_TRACE frame=%d position=%s floor=%s ground=%.2f hit=%s city_blocks=%d chunks=%d frontier=%s" % [
					streaming_samples.size(), str(player.position), player.is_on_floor(),
					Gen.height(player.position.x, player.position.z), str(hit.get("position", Vector3.INF)),
					city.city_world.visible_block_count(), main.world.chunks.size(), Gen.frontier_world])
			if not Plan.contains(Vector2(player.position.x, player.position.z)):
				check(false, "long city visit remains in the city")
				_finish()
				return
			var now_stream := Time.get_ticks_usec()
			streaming_samples.append((now_stream - previous_stream) / 1000.0)
			previous_stream = now_stream
		streaming_samples.sort()
		if not streaming_samples.is_empty():
			print("CITYPLAY_STREAM frames=%d p95_ms=%.3f p99_ms=%.3f max_ms=%.3f" % [streaming_samples.size(),
				streaming_samples[int(streaming_samples.size() * 0.95)],
				streaming_samples[int(streaming_samples.size() * 0.99)], streaming_samples[-1]])
		print("CITYPLAY_BUDGET " + JSON.stringify(city.city_world.node_budget_snapshot()))
	var started := Time.get_ticks_usec()
	var previous := started
	for i in range(300):
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		samples.append((now - previous) / 1000.0)
		previous = now
	samples.sort()
	print("CITYPLAY_FRAMES renderer=%s frames=%d p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f max_ms=%.3f nodes=%d actors=%d" % [DisplayServer.get_name(), samples.size(), samples[150], samples[285], samples[297], samples[-1], Performance.get_monitor(Performance.OBJECT_NODE_COUNT), city.crowd.actors.size()])
	if profiling:
		print("CITYPROFILE_ENV cap=%d scale=%.3f viewport=%s" % [Engine.max_fps, main._render_scale, str(main.get_viewport().get_visible_rect().size)])
		city.city_world._far_instance.visible = false
		await _profile_sample("far_hidden")
		city.city_world._far_instance.visible = true
		city.city_world._stream_root.visible = false
		await _profile_sample("near_hidden")
		city.city_world._far_instance.visible = false
		await _profile_sample("all_city_hidden")
		city.city_world._stream_root.visible = true
		city.city_world._far_instance.visible = true
	if capture:
		sim.state.time = 875.0
		main.world.set_time_of_day_override(17.5)
		await _capture(main, "lantern-square")
		var camera := Camera3D.new()
		main.world.add_child(camera)
		camera.position = Vector3(14270, 220, -200)
		camera.look_at(Vector3(14500, 25, 170))
		camera.far = 3000
		camera.make_current()
		await _capture(main, "crownreach-skyline")
		sim.state.time = 1150.0
		main.world.set_time_of_day_override(23.0)
		camera.position = Vector3(14320, 27, -65)
		camera.look_at(Vector3(14440, 12, 30))
		for i in range(90): await get_tree().process_frame
		await _capture(main, "lantern-square-night")
		camera.queue_free()
	check(main.world.local_player.position.y >= Plan.GROUND_Y - 0.15, "city arrival remains above collision terrain after streaming")
	_finish()

func _button(root: Node, key: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		if str(node.get_meta("city_focus", "")) == key: return node
	return null

func _profile_sample(label: String) -> void:
	for i in range(30): await get_tree().process_frame
	var values: Array[float] = []
	var previous := Time.get_ticks_usec()
	for i in range(180):
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		values.append((now - previous) / 1000.0)
		previous = now
	values.sort()
	print("CITYPROFILE %s p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f max_ms=%.3f" % [label, values[90], values[171], values[178], values[-1]])

func _arrival(city: Node) -> void:
	var frames := 0
	while city.arrival_pending() and frames < 480:
		await get_tree().physics_frame
		frames += 1
	if city.arrival_pending():
		check(false, "arrival releases after physical ground loads")
		_finish()

func _capture(main: Node, name: String) -> void:
	var path := "res://artifacts/crownreach"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
	for i in range(20): await get_tree().process_frame
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png(path.path_join(name + ".png"))

func _finish() -> void:
	print("CITYPLAYTEST %d/%d %s" % [passed, checks, "PASS" if passed == checks else "FAIL"])
	get_tree().quit(0 if passed == checks else 1)
