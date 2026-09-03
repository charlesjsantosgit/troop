extends Node
## Rendered lunar gameplay benchmark and review images, with a warmed GPU.
func run(main: Node) -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	var no_ssao := OS.get_cmdline_user_args().has("no-ssao")
	var player: MonkeyPlayer = main.world.local_player
	var moon: MoonWorld = main.expedition_manager.moon_world
	if no_ssao:
		moon.lunar_environment.ssao_enabled = false
	player.test_mode = true
	player._invulnerable_t = 1000.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var ground_review := OS.get_cmdline_user_args().has("ground-review")
	var output := ProjectSettings.globalize_path(
		"res://artifacts/moon-ground" if ground_review else "res://artifacts/repair")
	if no_ssao:
		output = output.path_join("no-ssao")
	DirAccess.make_dir_recursive_absolute(output)
	var warm := 0.0
	while warm < 5.0:
		await get_tree().process_frame
		warm += get_process_delta_time()
	# A complete globe and a close NPC are captured from the live game instance.
	var camera := Camera3D.new()
	main.world.add_child(camera)
	camera.far = 14000.0
	camera.environment = moon.lunar_environment
	camera.fov = 52.0
	camera.global_position = moon.center_world_position() + Vector3(2.0, 1.3333, 1.9167) * MoonWorld.PLAYABLE_RADIUS_METERS
	camera.look_at(moon.center_world_position(), Vector3.UP)
	camera.current = true
	main.hud.visible = false
	main.expedition_manager._ui_layer.visible = false
	main._session_ui_layer.visible = false
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(output.path_join("moon-globe.png"))
	var shop := moon.cheese_shop
	camera.global_position = shop.to_global(Vector3(8.0, 4.0, -12.0))
	camera.look_at(shop.to_global(Vector3(0.0, 1.0, -2.0)), shop.global_basis.y)
	player.admin_teleport(moon.surface_position_at(shop.to_global(Vector3(0.0, 0.0, -7.5)), 0.1))
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(output.path_join("moon-merchant.png"))
	if ground_review:
		# Ground-height view: the visible horizon belongs to the physical sphere.
		var horizon_up := Vector3(30.0, MoonWorld.PLAYABLE_RADIUS_METERS, 20.0).normalized()
		var horizon_basis := MoonWorld.surface_basis(horizon_up)
		var pole_surface := moon.to_global(moon.surface_position(horizon_up))
		camera.global_position = pole_surface + horizon_up * 2.2
		camera.fov = CameraRig.BASE_FOV
		camera.look_at(camera.global_position - horizon_basis.z - horizon_up * 0.08, horizon_up)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(output.path_join("moon-ground-horizon.png"))
		# Tight side view makes boot and kiosk contact directly inspectable.
		camera.fov = 52.0
		camera.global_position = shop.to_global(Vector3(4.5, 1.15, -9.0))
		camera.look_at(shop.to_global(Vector3(-0.4, 0.6, -5.4)), shop.global_basis.y)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(output.path_join("moon-ground-contact.png"))
	main.hud.visible = true
	main.expedition_manager._ui_layer.visible = true
	player.cam.make_current()
	camera.queue_free()
	player.cam.snap_to_target()
	await get_tree().create_timer(2.0).timeout
	var samples: Array[float] = []
	var cpu_samples := 0.0
	var gpu_samples := 0.0
	var physics_samples := 0.0
	var process_samples := 0.0
	var elapsed := 0.0
	player.ti.dir = Vector2(0.0, -1.0)
	player.ti.sprint = true
	while elapsed < 8.0:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		elapsed += dt
		samples.append(dt * 1000.0)
		cpu_samples += RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid())
		gpu_samples += RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
		physics_samples += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		process_samples += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	player.ti.dir = Vector2.ZERO
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(output.path_join("moon-gameplay.png"))
	samples.sort()
	var fps := float(samples.size()) / elapsed
	var p95 := samples[int(samples.size() * 0.95)]
	var worst := samples[-1]
	var ok := fps >= 55.0 and p95 <= 25.0 and worst < 100.0
	print("MOONPERF fps=%.2f p95_ms=%.2f worst_ms=%.2f scale=%.2f draws=%d nodes=%d %s" % [fps, p95, worst,
		get_viewport().scaling_3d_scale,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT), "PASS" if ok else "FAIL"])
	print("MOONPROFILE render_cpu_ms=%.3f render_gpu_ms=%.3f physics_ms=%.3f process_ms=%.3f primitives=%d" % [
		cpu_samples / samples.size(), gpu_samples / samples.size(), physics_samples / samples.size(),
		process_samples / samples.size(), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)])
	main._return_to_main_menu()
	for frame in range(6):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(output.path_join("main-menu.png"))
	get_tree().quit(0 if ok else 1)
