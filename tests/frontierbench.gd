extends Node
## Bounded rendered benchmark of the actual society. Saves stay disabled.

func run(main: Node) -> void:
	var controller: FrontierController = main.frontier_controller
	controller.persistence_enabled = false
	main.world.local_player.test_mode = true
	main.world.local_player._invulnerable_t = 1000.0
	for step in range(120):
		controller.simulation.tick(1.0)
	await _measure("Earth town", main)
	Net.rocket_state.phase = Net.RocketMissionPhase.MOON_READY
	main.expedition_manager._apply_authoritative_state(Net.expedition_state_snapshot())
	main.expedition_manager.admin_travel(Net.PlayerRealm.MOON)
	controller._sync_realm()
	var player: MonkeyPlayer = main.world.local_player
	player.global_position = controller.moon_site.surface_point(2, 5, 1.0)
	player.velocity = Vector3.ZERO
	await _measure("Lunar agriculture", main)
	main._return_to_main_menu()
	for frame in range(5):
		await get_tree().process_frame
	get_tree().quit()


func _measure(label: String, main: Node) -> void:
	for frame in range(180):
		await get_tree().process_frame
	var times: Array[float] = []
	var last := Time.get_ticks_usec()
	for frame in range(720):
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		times.append(float(now - last) / 1000.0)
		last = now
	var sum := 0.0
	for value in times: sum += value
	times.sort()
	print("FRONTIERBENCH %s viewport=%s scale=%.2f citizens=%d samples=%d mean_ms=%.2f p95_ms=%.2f p99_ms=%.2f worst_ms=%.2f draws=%d" % [
		label, str(get_viewport().get_visible_rect().size), get_viewport().scaling_3d_scale,
		main.frontier_controller.simulation.state.citizens.size(), times.size(), sum / times.size(),
		times[int(times.size() * 0.95)], times[int(times.size() * 0.99)], times.back(),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))])
