extends Node
## Rendered colony review and a warmed eight-second gameplay benchmark.
## Main isolates save I/O for -- mooncolonycapture.

var _output := ""


func _frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().physics_frame
	await get_tree().process_frame


func _interact_at(player: MonkeyPlayer, colony: MoonColonyWorld,
		action: String, target := 0) -> void:
	var position := colony.interaction_position(action, target)
	player.admin_teleport(position + player.lunar_world.radial_up_at(position) * 0.8)
	await _frames(95)
	player.ti.interact_just = true
	await _frames(2)


func _capture(file_name: String) -> void:
	await _frames(2)
	await RenderingServer.frame_post_draw
	var result := get_viewport().get_texture().get_image().save_png(_output.path_join(file_name))
	print("COLONYCAPTURE %s %s" % [file_name, "OK" if result == OK else "FAILED"])


func run(main: Node) -> void:
	if DisplayServer.get_name() == "headless":
		print("MOONCOLONYCAPTURE requires a rendered window; no capture or performance claim made.")
		get_tree().quit(1)
		return
	var player: MonkeyPlayer = main.world.local_player
	var manager: ExpeditionManager = main.expedition_manager
	var moon := manager.moon_world
	var colony := moon.colony_world
	# The headless Dummy renderer returns identity MultiMesh transforms. Check
	# the real submitted geometry here, with the rendered backend initialized.
	await _frames(2)
	var geometry_checks = load("res://tests/mooncolonyplaytest.gd").new()
	add_child(geometry_checks)
	geometry_checks._check_static_fixture_geometry(colony)
	var geometry_ok: bool = geometry_checks.total == 2 and geometry_checks.passed == 2
	print("COLONYGEOMETRY %d/%d %s" % [geometry_checks.passed, geometry_checks.total,
		"PASS" if geometry_ok else "FAIL"])
	geometry_checks.queue_free()
	player.test_mode = true
	player._invulnerable_t = 1000.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_output = ProjectSettings.globalize_path("res://artifacts/moon-colony")
	DirAccess.make_dir_recursive_absolute(_output)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	# Use genuine starter harvests and market controls to hire the farmhand.
	# This is a disposable demonstration colony, never the player's save.
	await _interact_at(player, colony, "harvest", 0)
	await _interact_at(player, colony, "harvest", 1)
	await _interact_at(player, colony, "market")
	manager.colony_ui._sell_fresh.pressed.emit()
	await _frames(2)
	manager.colony_ui._upgrade_buttons[3].pressed.emit()
	await _frames(2)
	manager.close_ui()
	# Advance the authoritative simulation for this review scene, preserving real
	# production helper, harvest and planting rules instead of fabricating cargo.
	for _second in range(70):
		Net._process_moon_colonies(1.0)
	var farm := colony.facility_roots["farm"] as Node3D
	var farm_stand := colony.interaction_position("farm")
	player.admin_teleport(farm_stand + moon.radial_up_at(farm_stand) * 0.3)
	await _frames(180)
	var camera := Camera3D.new()
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	main.world.add_child(camera)
	camera.far = 14000.0
	camera.environment = moon.lunar_environment
	camera.fov = 56.0
	camera.current = true
	main.hud.visible = false
	manager._ui_layer.visible = false
	main._session_ui_layer.visible = false
	camera.global_position = farm.to_global(Vector3(18.0, 12.0, -25.0))
	camera.look_at(farm.to_global(Vector3(0.0, 1.0, -9.0)), farm.global_basis.y)
	await _frames(60)
	await _capture("colony-farm-overview.png")
	var bed := colony.plot_roots[0]
	var bed_stand := colony.interaction_position("plant", 0)
	player.admin_teleport(bed_stand + moon.radial_up_at(bed_stand) * 0.2)
	await _frames(45)
	camera.global_position = bed.to_global(Vector3(5.0, 3.4, -6.8))
	camera.look_at(bed.to_global(Vector3(0.0, 1.0, -1.1)), bed.global_basis.y)
	await _capture("colony-player-bed.png")
	main.hud.visible = true
	manager._ui_layer.visible = true
	player.cam.make_current()
	await _interact_at(player, colony, "market")
	await _frames(10)
	await _capture("colony-market.png")
	manager._open_colony_journal()
	await _capture("colony-journal.png")
	manager.colony_ui._tabs.current_tab = 2
	await _capture("colony-field-guide.png")
	manager.close_ui()
	var observatory := colony.landmark_roots[0]
	var landmark_stand := colony.interaction_position("discover", 0)
	player.admin_teleport(landmark_stand + moon.radial_up_at(landmark_stand) * 0.2)
	await _frames(40)
	camera.current = true
	main.hud.visible = false
	manager._ui_layer.visible = false
	camera.fov = 53.0
	camera.global_position = observatory.to_global(Vector3(9.0, 5.0, -11.0))
	camera.look_at(observatory.to_global(Vector3(0.0, 2.0, 0.0)), observatory.global_basis.y)
	await _capture("colony-earthrise-observatory.png")
	main.hud.visible = true
	manager._ui_layer.visible = true
	player.cam.make_current()
	camera.queue_free()
	# A normal walking camera follows a selected great-circle bearing away from
	# the farm. All geometry, worker physics and UI remain live during measurement.
	var walk_start := moon.surface_position_at(farm.to_global(Vector3(10.0, 0.0, -1.0)), 0.3)
	player.admin_teleport(walk_start)
	manager._set_colony_waypoint("discover", 0, "EARTHRISE OBSERVATORY")
	var toward := (landmark_stand - walk_start).slide(moon.radial_up_at(walk_start)).normalized()
	var local_toward := player.cam._walking_reference_basis().inverse() * toward
	player.cam.yaw = atan2(-local_toward.x, -local_toward.z)
	player.cam.pitch = -0.10
	player.cam.snap_to_target()
	await get_tree().create_timer(3.0).timeout
	var samples: Array[float] = []
	var elapsed := 0.0
	var cpu := 0.0
	var gpu := 0.0
	var physics := 0.0
	var process := 0.0
	player.ti.dir = Vector2(0.0, -1.0)
	while elapsed < 8.0:
		await get_tree().process_frame
		var delta := get_process_delta_time()
		elapsed += delta
		samples.append(delta * 1000.0)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid())
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
		physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		process += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	player.ti.dir = Vector2.ZERO
	await _capture("colony-guided-travel.png")
	samples.sort()
	var fps := float(samples.size()) / elapsed
	var p95 := samples[int(samples.size() * 0.95)]
	var worst := samples[-1]
	var ok := fps >= 55.0 and p95 <= 25.0 and worst < 100.0 and geometry_ok
	print("MOONCOLONYPERF fps=%.2f p95_ms=%.2f worst_ms=%.2f scale=%.2f draws=%d nodes=%d %s" % [
		fps, p95, worst, get_viewport().scaling_3d_scale,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT), "PASS" if ok else "FAIL"])
	print("MOONCOLONYPROFILE render_cpu_ms=%.3f render_gpu_ms=%.3f physics_ms=%.3f process_ms=%.3f travel_m=%.2f" % [
		cpu / samples.size(), gpu / samples.size(), physics / samples.size(), process / samples.size(),
		player.global_position.distance_to(walk_start)])
	main._return_to_main_menu()
	await _frames(4)
	get_tree().quit(0 if ok else 1)
