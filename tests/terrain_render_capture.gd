extends SceneTree
## Real renderer smoke: streamed terrain after walking across both grid signs,
## ascent, and descent. Uses a fresh unsaved session and the actual game scene.
## godot --path . --script res://tests/terrain_render_capture.gd -- town OUTPUT_DIR

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var gen: Node = root.get_node("Gen")
	var args := OS.get_cmdline_user_args()
	var realm := str(args[0]) if args.size() else "town"
	var terrain_only := args.size() > 2 and args[2] == "terrain-only"
	var output := str(args[1]) if args.size() > 1 else "res://artifacts/terrain-repair"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	if realm == "town":
		main._start_frontier("TerrainCheck", false)
		main.frontier_controller.simulation_enabled = false
		main.frontier_controller._layer.hide()
	elif realm == "debug":
		main._close_menu()
		main._start_debug_world("TerrainCheck")
	else:
		main._close_menu()
		main._start_solo("TerrainCheck", 4321 if realm == "slope" else 2026, 2)
	var world: Node3D = main.world
	world.set_time_of_day_override(12.5)
	world.set_season_override(SeasonalCycle.Season.SUMMER)
	main.hud.hide()
	main.chat_box.hide()
	main.expedition_manager._ui_layer.hide()
	var player: Node3D = world.local_player
	player.test_mode = true
	player.set_physics_process(false)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.far = 18000.0
	camera.fov = 65.0
	camera.current = true
	if terrain_only:
		camera.environment = world._environment.duplicate()
		camera.environment.fog_enabled = false
		camera.environment.volumetric_fog_enabled = false
	var frames: Array[Dictionary] = [
		{"name": "spawn", "xz": Vector2(4, 1), "alt": 1.5},
		{"name": "positive-edge", "xz": Vector2(48.1, 48.1), "alt": 1.5},
		{"name": "negative-edge", "xz": Vector2(-48.1, -0.1), "alt": 1.5},
		{"name": "town-edge", "xz": Vector2(190, -180), "alt": 1.5},
		{"name": "hills", "xz": Vector2(440, -360), "alt": 1.5},
		{"name": "flight", "xz": Vector2(540, -460), "alt": 700.0},
		{"name": "descent-loading", "xz": Vector2(-130, 65), "alt": 1.5},
		{"name": "descent-settled", "xz": Vector2(-130, 65), "alt": 1.5},
	]
	if realm == "slope":
		frames = [{"name": "overlook", "xz": Vector2(-120000, 400000), "alt": 1.5},
			{"name": "low", "xz": Vector2(-120000, 400000), "alt": 1.5}]
	for shot in frames:
		var point: Vector2 = shot.xz
		player.global_position = Vector3(point.x, float(gen.call("height", point.x, point.y))
			+ float(shot.alt), point.y)
		player.velocity = Vector3.ZERO
		camera.global_position = player.global_position + Vector3(65, 58, 80)
		if shot.name == "low":
			camera.global_position = player.global_position + Vector3(10, 3, 14)
		camera.look_at(player.global_position)
		camera.current = true
		var waits := 12 if shot.name == "descent-loading" else 180
		for frame in range(waits):
			await process_frame
		if terrain_only:
			for tier in [world.chunks, world.horizon_chunks, world.skyline_chunks]:
				for sector in tier.values():
					for child in sector.get_children():
						if child is VisualInstance3D and not str(child.name).contains("Terrain") \
								and not str(child.name).contains("Water"):
							child.hide()
			await process_frame
		await RenderingServer.frame_post_draw
		var path := output.path_join(realm + "-" + str(shot.name) + ".png")
		var err := root.get_texture().get_image().save_png(path)
		print("TERRAIN_RENDER realm=%s shot=%s near=%d horizon=%d skyline=%d stratos=%d saved=%d" % [
			realm, shot.name, world.chunks.size(), world.horizon_chunks.size(),
			world.skyline_chunks.size(), world.stratos_chunks.size(), err])
		if err != OK:
			quit(1)
			return
	main._return_to_main_menu()
	for frame in range(4):
		await process_frame
	quit(0)
