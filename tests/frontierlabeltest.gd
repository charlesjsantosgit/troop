extends SceneTree
## Native pixel assertions for town lettering, followed by actual gameplay views.
## Run with --script res://tests/frontierlabeltest.gd -- --capture for town images.
var main: Node
var failed := false
var checks := 0
var metrics: Dictionary = {}
var folder := "res://artifacts/menu-redesign/town-labels"


func _initialize() -> void:
	# Native captures configure fresh user:// before renderer initialization.
	# Changing it here would invalidate already-created shader cache paths.
	if DisplayServer.get_name() == "headless":
		ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
		ProjectSettings.set_setting("application/config/custom_user_dir_name", "TROOP-label-test-" + Crypto.new().generate_random_bytes(6).hex_encode())
	elif OS.get_environment("TROOP_LABEL_USER_DIR") != OS.get_user_data_dir():
		push_error("Use an isolated startup project for the native label capture")
		quit(2)
		return
	create_timer(150).timeout.connect(func(): push_error("FRONTIERLABELTEST deadline"); quit(2))
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var fixture := SubViewport.new()
	fixture.size = Vector2i(640, 360)
	fixture.own_world_3d = true
	fixture.transparent_bg = true
	fixture.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(fixture)
	var holder := Node3D.new()
	fixture.add_child(holder)
	var props := FrontierProps.new(holder)
	var label := props.text(Vector3.ZERO, "TOWN NOTICEBOARD\nClaim · Contracts · Neighbours", Color(1, 0.9, 0.6), 27)
	var camera := Camera3D.new()
	camera.fov = 65
	fixture.add_child(camera)
	camera.current = true
	_check(label.visibility_range_begin - label.visibility_range_begin_margin >= 6.5,
		"town lettering is completely hidden before it reaches the camera")
	_check(label.visibility_range_fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF,
		"near and far transitions fade in the renderer without script polling")
	_check(not label.no_depth_test and not label.fixed_size,
		"signs retain world depth and perspective")
	_check(label.visibility_range_end == 45 and label.visibility_range_end_margin == 4,
		"existing far visibility bounds are preserved")
	if DisplayServer.get_name() != "headless":
		for distance in [2.0, 5.5, 10.0, 52.0]:
			camera.position = Vector3(0, 0, distance)
			for frame in range(5): await process_frame
			await RenderingServer.frame_post_draw
			var picture := fixture.get_texture().get_image()
			picture.save_png(folder + "/noticeboard-%sm.png" % str(distance))
			var bounds := _letter_pixels(picture)
			metrics[str(distance)] = bounds
			if distance < 6.5 or distance > 49:
				_check(bounds.pixels == 0, "renderer hides the actual lettering at %s m" % distance)
			else:
				_check(bounds.pixels > 250 and bounds.height >= 12,
					"normal-distance lettering remains readable at %s m" % distance)
				_check(bounds.width < 640 * 0.60,
					"visible noticeboard text occupies less than 60 percent of a 16:9 view at %s m" % distance)
	fixture.queue_free()
	await process_frame
	if "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		await _capture_town()
	FileAccess.open(folder + "/metrics.json", FileAccess.WRITE).store_string(JSON.stringify(metrics, "  "))
	print("FRONTIERLABELTEST %d checks %s" % [checks, "FAIL" if failed else "PASS"])
	quit(1 if failed else 0)


func _letter_pixels(picture: Image) -> Dictionary:
	var count := 0
	var start := Vector2i(picture.get_width(), picture.get_height())
	var finish := Vector2i.ZERO
	for y in picture.get_height():
		for x in picture.get_width():
			var pixel := picture.get_pixel(x, y)
			if pixel.a < 0.08 or pixel.r < 0.2 or pixel.g < 0.15 or pixel.r < pixel.b * 1.3:
				continue
			count += 1
			start = start.min(Vector2i(x, y))
			finish = finish.max(Vector2i(x, y))
	return {"pixels":count, "width":finish.x-start.x+1 if count else 0,
		"height":finish.y-start.y+1 if count else 0}


func _capture_town() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i(1600, 900)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await main._begin_menu_offline("frontier", false)
	var controller: Node = main.frontier_controller
	controller.simulation_enabled = false
	main.world.set_time_of_day_override(10.0)
	for frame in range(8): await process_frame
	await _capture("spawn-initial")
	for frame in range(150): await process_frame
	await _capture("spawn-settled")
	var player: Node3D = main.world.local_player
	player.test_mode = true
	player.set_physics_process(false)
	var camera := Camera3D.new()
	main.world.add_child(camera)
	camera.fov = 65
	camera.current = true
	var notice: Label3D
	for node: Node in controller.earth_settlement.get_children():
		if node is Label3D and node.text.begins_with("TOWN NOTICEBOARD"):
			notice = node
	_check(is_instance_valid(notice), "actual town uses the shared noticeboard label")
	if is_instance_valid(notice):
		metrics["spawn_noticeboard_distance"] = main.world.local_player.cam._cam.global_position.distance_to(notice.global_position)
		_check(float(metrics.spawn_noticeboard_distance) < notice.visibility_range_begin - notice.visibility_range_begin_margin,
			"settled shoulder camera is inside the noticeboard's fully hidden range")
		for distance in [2.0, 10.0]:
			camera.global_position = notice.global_position + Vector3(0, 0, distance)
			camera.look_at(notice.global_position)
			await _capture("town-noticeboard-%sm" % str(distance))
	# Preserve the actual shop and its nearby sign in both menu views.
	var nana: Node3D = controller.earth_settlement.citizens.nana
	player.global_position = controller.earth_site.surface_point(nana.position.x + 1.7, nana.position.z)
	camera.global_position = nana.global_position + Vector3(0.9, 2.0, 5.0)
	camera.look_at(nana.global_position + Vector3(0, 1.0, 0))
	for frame in range(12): await process_frame
	_check(controller.nearest_interaction().get("id") == "nana", "nearby HUD interaction still selects Nana")
	_check(controller.try_interact(player), "the nearby merchant remains interactive")
	await _capture("merchant-view")
	controller.ui.close()
	main.expedition_manager.toggle_inventory()
	await _capture("backpack-view")
	_check(main.expedition_manager.inventory_ui.visible, "backpack opens in the real town")
	main.expedition_manager.inventory_ui.close_inventory()
	main._return_to_main_menu()
	for frame in range(5): await process_frame
	main.queue_free()
	for frame in range(3): await process_frame


func _capture(stem: String) -> void:
	for frame in range(8): await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png(folder + "/" + stem + ".png")
	_check(result == OK, "saved " + stem)


func _check(ok: bool, message: String) -> void:
	checks += 1
	failed = failed or not ok
	print("FRONTIERLABEL ", "PASS " if ok else "FAIL ", message)
