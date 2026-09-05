extends Node
const Plan = preload("res://scripts/city_plan.gd")
const Traffic = preload("res://scripts/city_traffic.gd")
var report: Dictionary = {}
var main: Node
var camera: Camera3D

func run(host: Node) -> void:
	main = host
	var city: Node = main.frontier_controller.city
	var player: MonkeyPlayer = main.world.local_player
	main.set_process_input(false)
	main.set_process_unhandled_input(false)
	main._close_pause_menu(false)
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.test_mode = true
	var origin := Traffic.point(Vector2i(32,26))
	var ground := Vector3(origin.x,Plan.GROUND_Y,origin.y)
	city._teleport(ground+Vector3(14,1.2,22))
	while city.arrival_pending(): await get_tree().physics_frame
	player.set_physics_process(false)
	player.visible = false
	for layer in main.find_children("*","CanvasLayer",true,false): layer.visible = false
	camera = Camera3D.new()
	camera.far = 9000
	camera.fov = 67
	main.world.add_child(camera)
	camera.position = ground+Vector3(13,2,20)
	camera.look_at(ground+Vector3(-2,4,-6))
	camera.make_current()
	main.frontier_controller.set_solar_hour(13)
	# The profiler waits for every real block and all persistent residents.
	# Extra bounded staging is confined to warmup; measured frames use the game.
	for frame in range(420):
		for block in range(6): city.city_world._stage_one_far_block()
		await get_tree().process_frame
	while not city.crowd.ambient.ready_city: await get_tree().process_frame
	for z in range(Plan.GRID_DEPTH):
		for x in range(Plan.GRID_WIDTH):
			var key := Vector2i(x,z)
			if not city.city_world._far_staged_blocks.has(key): city.city_world._stage_far_block(key)
	report.far_staged_blocks = city.city_world.far_staged_block_count()
	report.total_blocks = Plan.TOTAL_BLOCKS
	report.population = city.crowd.ambient.stats()
	report.street_full = await sample("street_full")
	report.street_cohort = cohort_stats(city.crowd,player.global_position)
	await capture("street-canonical-population")
	# Hold only the UI's focus refresher so diagnostic visibility stays changed.
	city.set_process(false)
	for actor in city.crowd.actors:
		actor.visible = false
		actor.set_physics_process(false)
	report.street_without_near_actors = await sample("without_near_actors")
	for actor in city.crowd.actors:
		actor.visible = true
		actor.set_physics_process(true)
	city.crowd.ambient.visible = false
	report.street_without_citywide = await sample("without_citywide")
	city.crowd.ambient.visible = true
	city.city_world.visible = false
	report.street_without_building_visuals = await sample("without_building_visuals")
	city.city_world.visible = true
	city.set_process(true)
	player.global_position = ground+Vector3(0,500,0)
	city.crowd.update_focus(player.global_position)
	camera.position = ground+Vector3(-450,1800,-300)
	camera.look_at(ground+Vector3(300,0,500))
	report.aerial_full = await sample("aerial_full")
	await capture("aircraft-canonical-population")
	report.population = city.crowd.ambient.stats()
	var pixels := get_viewport().get_texture().get_size()
	report.viewport_pixels = [int(pixels.x),int(pixels.y)]
	var file := FileAccess.open("res://artifacts/city-traffic/population-profile.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("CITYPOPULATIONBENCH "+JSON.stringify(report))
	call_deferred("_finish")

func sample(label: String) -> Dictionary:
	for frame in range(90): await get_tree().process_frame
	var times: Array[float] = []
	var physics: Array[float] = []
	var process: Array[float] = []
	var render_scale_min := INF
	var render_scale_max := 0.0
	for frame in range(180):
		var start := Time.get_ticks_usec()
		await get_tree().process_frame
		times.append(float(Time.get_ticks_usec()-start)/1000.0)
		physics.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000)
		process.append(Performance.get_monitor(Performance.TIME_PROCESS)*1000)
		render_scale_min = minf(render_scale_min,get_viewport().scaling_3d_scale)
		render_scale_max = maxf(render_scale_max,get_viewport().scaling_3d_scale)
	times.sort();physics.sort();process.sort()
	var result := {"p50_ms":times[90],"p95_ms":times[171],"p99_ms":times[178],"physics_p50_ms":physics[90],"process_p50_ms":process[90],"draw_calls":Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),"primitives":Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),"nodes":Performance.get_monitor(Performance.OBJECT_NODE_COUNT)}
	result["output_pixels"] = [get_viewport().get_texture().get_width(),get_viewport().get_texture().get_height()]
	result["render_scale_min"] = render_scale_min
	result["render_scale_max"] = render_scale_max
	print("CITYPOPULATION_PROFILE "+label+" "+JSON.stringify(result))
	return result

func capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var path := "res://artifacts/city-traffic/"+label+".png"
	get_viewport().get_texture().get_image().save_png(path)

func cohort_stats(crowd: Node3D, focus: Vector3) -> Dictionary:
	var result := {"physical_cars":0,"physical_pedestrians":0,"pedestrians_within_80m":0,"cars_within_120m":0,"pedestrians_in_camera_frustum":0}
	var planes := camera.get_frustum()
	for actor in crowd.actors:
		var distance: float = actor.position.distance_to(focus)
		if actor.car:
			result.physical_cars += 1
			if distance<120: result.cars_within_120m += 1
		else:
			result.physical_pedestrians += 1
			if distance<80: result.pedestrians_within_80m += 1
			var in_frame := true
			for plane in planes:
				if plane.distance_to(actor.global_position+Vector3.UP)>.9: in_frame = false
			if in_frame: result.pedestrians_in_camera_frustum += 1
	return result

func _finish() -> void:
	# Let the capture coroutine release its World/controller references before
	# the tree exits, matching the other native scene capture fixtures.
	get_tree().quit(0 if report.far_staged_blocks==Plan.TOTAL_BLOCKS else 1)
