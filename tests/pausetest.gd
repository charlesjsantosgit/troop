extends Node
## Pause/settings lifecycle checks. This node must keep running while the solo
## SceneTree is paused so it can verify both sides of the transition.

var passed := 0
var total := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func run(main) -> void:
	var original_fps_limit := Settings.fps_limit
	var original_custom_fps_limit := Settings.custom_fps_limit
	var original_fps_limit_custom := Settings.fps_limit_custom
	var original_perf_warmup: float = main._perf_warmup
	var original_perf_sample_t: float = main._perf_sample_t
	var original_perf_low_samples: int = main._perf_low_samples
	var original_perf_high_samples: int = main._perf_high_samples
	var original_render_scale: float = main._render_scale
	var original_render_scale_ceiling: float = main._render_scale_ceiling
	var original_viewport_scale := get_viewport().scaling_3d_scale
	await get_tree().process_frame
	await _verify_offline_simulation_pause(main)
	main.hud._fps_refresh_remaining = 0.0
	main.hud._update_fps_meter(HUD.FPS_REFRESH_SECONDS)
	_check(main.hud.fps_label != null and main.hud.fps_label.visible \
		and main.hud.fps_label.text.begins_with("FPS ") \
		and main.hud.fps_label.position.x <= 20.0 \
		and main.hud.fps_label.position.y + 20.0 <= main.hud.score_label.position.y \
		and main.hud.fps_label.get_index() > main.hud.sniper_scope.get_index(),
		"accurate FPS meter occupies the top-left without covering the score")
	main._open_pause_menu()
	_check(get_tree().paused and main.pause_menu != null \
		and main.pause_layer != null,
		"solo pause freezes the world on an always-processing menu layer")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
		"pause releases the cursor")
	_check(main.pause_menu._binding_buttons.size() == 26,
		"controls page exposes every player-facing keyboard and mouse action")
	_check(AudioServer.get_bus_index(&"SFX") >= 0 \
		and AudioServer.get_bus_index(&"Ambience") >= 0 \
		and AudioServer.get_bus_index(&"Voice") >= 0,
		"separate effects, ambience, and voice buses are available")
	_check(not Settings.binding_text(&"shoot").is_empty() \
		and not Settings.binding_text(&"move_fwd").is_empty() \
		and not Settings.binding_text(&"push_to_talk").is_empty() \
		and not Settings.binding_text(&"vehicle_pitch_up").is_empty() \
		and not Settings.binding_text(&"vehicle_pitch_down").is_empty(),
		"saved key and mouse bindings have readable labels")
	_check(_has_key_binding(&"vehicle_pitch_up", KEY_UP) \
		and _has_key_binding(&"vehicle_pitch_down", KEY_DOWN),
		"jet nose controls default to the Up and Down arrow keys")

	main.pause_menu.open_settings()
	var fps_select: OptionButton = main.pause_menu._fps_limit_select
	var custom_index := fps_select.item_count - 1
	_check(main.pause_menu._current_tab == PauseMenu.TAB_GRAPHICS \
		and main.pause_menu._graphics_view.visible \
		and not main.pause_menu._audio_view.visible \
		and not main.pause_menu._controls_view.visible,
		"settings opens on a dedicated Graphics page")
	_check(fps_select.item_count >= 5 \
		and fps_select.get_item_text(0) == "UNLIMITED" \
		and int(fps_select.get_item_metadata(0)) == 0 \
		and fps_select.get_item_text(1) == "480 FPS" \
		and int(fps_select.get_item_metadata(1)) == 480 \
		and int(fps_select.get_item_metadata(2)) < 480 \
		and fps_select.get_item_text(custom_index) == "CUSTOM…" \
		and int(fps_select.get_item_metadata(custom_index)) \
			== PauseMenu.CUSTOM_FPS_OPTION,
		"FPS choices begin Unlimited, 480, descend through presets, and end Custom")
	_check(fps_select.focus_mode == Control.FOCUS_ALL \
		and main.pause_menu._custom_fps_spin.focus_mode == Control.FOCUS_ALL \
		and int(main.pause_menu._custom_fps_spin.min_value) \
			== GameSettings.MIN_CUSTOM_FPS_LIMIT \
		and int(main.pause_menu._custom_fps_spin.max_value) \
			== GameSettings.MAX_CUSTOM_FPS_LIMIT,
		"preset and validated custom controls remain keyboard/controller focusable")

	main._perf_warmup = 0.0
	main._perf_sample_t = 1.1
	main._perf_low_samples = 2
	main._perf_high_samples = 3
	main._render_scale_ceiling = 0.86
	main._render_scale = 0.42
	get_viewport().scaling_3d_scale = main._render_scale
	fps_select.select(1)
	main.pause_menu._on_fps_limit_selected(1)
	_check(Settings.fps_limit == 480 and not Settings.fps_limit_custom \
		and Engine.max_fps == 480 \
		and main.pause_menu._fps_limit_status.text.contains("480 FPS"),
		"480 FPS preset applies exactly and updates the Graphics status")
	_check(is_equal_approx(main._perf_warmup, 2.0) \
		and is_zero_approx(main._perf_sample_t) \
		and main._perf_low_samples == 0 and main._perf_high_samples == 0 \
		and is_equal_approx(main._render_scale, 0.86) \
		and is_equal_approx(get_viewport().scaling_3d_scale, 0.86),
		"changing the cap resets adaptive samples and restores full render scale")
	fps_select.select(0)
	main.pause_menu._on_fps_limit_selected(0)
	_check(Settings.fps_limit == 0 and Engine.max_fps == 0 \
		and main.pause_menu._fps_limit_status.text.begins_with("UNLIMITED"),
		"Unlimited maps to Godot's native zero frame cap")
	fps_select.select(custom_index)
	main.pause_menu._on_fps_limit_selected(custom_index)
	main.pause_menu._custom_fps_spin.value = 237.0
	main.pause_menu._on_custom_fps_changed(237.0)
	_check(main.pause_menu._custom_fps_row.visible \
		and Settings.fps_limit_custom and Settings.custom_fps_limit == 237 \
		and Settings.fps_limit == 237 and Engine.max_fps == 237,
		"Custom accepts and applies an exact integer frame cap")
	var accepted_limit := Settings.fps_limit
	_check(not Settings.set_custom_fps_limit(
		GameSettings.MAX_CUSTOM_FPS_LIMIT + 1) \
		and Settings.fps_limit == accepted_limit \
		and Engine.max_fps == accepted_limit,
		"out-of-range custom limits are rejected without changing the active cap")
	_check(not Settings.set_fps_limit(233) \
		and Settings.fps_limit == accepted_limit \
		and Engine.max_fps == accepted_limit,
		"preset API rejects arbitrary values that belong in Custom")
	Settings.save()
	var saved_settings := ConfigFile.new()
	_check(saved_settings.load(Settings.CONFIG_PATH) == OK \
		and int(saved_settings.get_value("graphics", "fps_limit", -1)) == 237 \
		and bool(saved_settings.get_value("graphics", "fps_limit_custom", false)) \
		and int(saved_settings.get_value("graphics", "custom_fps_limit", -1)) == 237,
		"the exact FPS limiter mode and value persist to settings.cfg")
	var reloaded_custom := GameSettings.new()
	_check(reloaded_custom.fps_limit_custom \
		and reloaded_custom.fps_limit == 237 \
		and reloaded_custom.custom_fps_limit == 237,
		"a saved Custom mode and exact value survive a fresh settings reload")
	reloaded_custom.free()

	saved_settings.set_value("graphics", "fps_limit", 233)
	saved_settings.set_value("graphics", "fps_limit_custom", false)
	saved_settings.set_value("graphics", "custom_fps_limit", 237)
	var normalized_saved := saved_settings.save(Settings.CONFIG_PATH) == OK
	var reloaded_non_preset := GameSettings.new()
	_check(normalized_saved and reloaded_non_preset.fps_limit_custom \
		and reloaded_non_preset.fps_limit == 233 \
		and reloaded_non_preset.custom_fps_limit == 233,
		"a persisted non-preset cap normalizes into visible Custom mode")
	reloaded_non_preset.free()

	Settings.set_custom_fps_limit(original_custom_fps_limit)
	if not original_fps_limit_custom:
		Settings.set_fps_limit(original_fps_limit)
	Settings.save()
	main._perf_warmup = original_perf_warmup
	main._perf_sample_t = original_perf_sample_t
	main._perf_low_samples = original_perf_low_samples
	main._perf_high_samples = original_perf_high_samples
	main._render_scale_ceiling = original_render_scale_ceiling
	main._render_scale = original_render_scale
	get_viewport().scaling_3d_scale = original_viewport_scale

	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	main.pause_menu._input(escape)
	_check(main.pause_menu != null \
		and main.pause_menu._current_view == PauseMenu.VIEW_HOME,
		"Escape backs out of settings before it resumes play")
	main.pause_menu._input(escape)
	await get_tree().process_frame
	_check(not get_tree().paused and main.pause_menu == null \
		and main.pause_layer == null,
		"resume removes the overlay and unfreezes solo play")

	main.mode = "host"
	main._open_pause_menu()
	_check(not get_tree().paused and main.pause_menu._online_warning.visible,
		"online pause keeps replication alive and clearly warns before leaving")
	main._close_pause_menu(false)
	await get_tree().process_frame

	main.mode = "solo"
	main._open_pause_menu()
	main._return_to_main_menu()
	await get_tree().process_frame
	_check(not get_tree().paused and main.world == null and main.hud == null \
		and main.menu != null and main.mode == "menu",
		"return-to-menu cleans up gameplay and restores the title screen")

	print("PAUSETEST %d/%d %s" % [
		passed, total, "PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)


func _verify_offline_simulation_pause(main) -> void:
	# Exercise the real gameplay hierarchy already loaded by this suite. A real
	# suit on a lightweight actor proves oxygen callbacks pause without spawning
	# another whole world or waiting through a flight.
	var original_mode: String = main.mode
	var player: MonkeyPlayer = main.world.local_player
	var original_test_mode := player.test_mode
	var original_velocity := player.velocity
	var original_toast: float = main.expedition_manager._toast_remaining
	var original_rocket_state := Net.rocket_state.duplicate(true)
	var original_rocket_started := Net._rocket_started_msec
	var actor := Node3D.new()
	actor.name = "PausedLifeSupportProbe"
	main.world.add_child(actor)
	var suit := SpaceSuitSystem.new()
	suit.equip_for(actor)
	suit.set_vacuum_exposure(true)
	player.test_mode = true
	player.velocity = Vector3(4.0, 1.0, 0.0)
	main.expedition_manager._toast_remaining = 5.0
	Net.rocket_state = {"phase": Net.RocketMissionPhase.OUTBOUND,
		"crew": [], "elapsed": 0.001, "duration": Net.ROCKET_OUTBOUND_SECONDS,
		"serial": int(original_rocket_state.get("serial", 0)) + 1}
	# Keep the real clock anchor positive even when this fixture starts less
	# than two seconds after the engine; nonpositive anchors mean no voyage.
	Net._rocket_started_msec = maxi(Time.get_ticks_msec() - 1, 1)
	main.mode = "moon"
	main._open_pause_menu()
	var paused_position := player.global_position
	var paused_actor_time := player._now
	var paused_oxygen := suit.oxygen_seconds
	var paused_toast: float = main.expedition_manager._toast_remaining
	var paused_clock := float(Net.expedition_state_snapshot().elapsed)
	_check(get_tree().paused and main._world_paused_by_menu
		and not main.pause_menu._online_warning.visible,
		"offline Moon entry uses a real pause rather than the online pause overlay")
	# A short real wall-clock gap catches the old Time.get_ticks_msec jump even
	# under --fixed-fps. Actual subsequent frames catch inherited ALWAYS modes.
	OS.delay_msec(80)
	for frame in range(8):
		await get_tree().physics_frame
		await get_tree().process_frame
	_check(player.global_position == paused_position and player._now == paused_actor_time
		and player.velocity == Vector3(4.0, 1.0, 0.0),
		"paused frames preserve actual player position, velocity and simulation time")
	_check(suit.oxygen_seconds == paused_oxygen
		and main.expedition_manager._toast_remaining == paused_toast
		and not main.world.can_process() and not main.expedition_manager.can_process(),
		"paused gameplay stops life-support oxygen and expedition timers while the menu runs")
	_check(is_equal_approx(float(Net.expedition_state_snapshot().elapsed), paused_clock),
		"offline authoritative voyage snapshots exclude real time spent paused")
	main._close_pause_menu(false)
	var resumed_clock := float(Net.expedition_state_snapshot().elapsed)
	_check(absf(resumed_clock - paused_clock) <= 0.003,
		"resuming a paused voyage preserves progress instead of skipping to arrival")
	OS.delay_msec(20)
	_check(float(Net.expedition_state_snapshot().elapsed) >= resumed_clock + 0.015,
		"the offline voyage clock advances again after resume")
	Net.rocket_state = original_rocket_state
	Net._rocket_started_msec = original_rocket_started
	for frame in range(4):
		await get_tree().physics_frame
	_check(suit.oxygen_seconds < paused_oxygen and player._now > paused_actor_time,
		"resuming reactivates real life support and player simulation")
	main.mode = "debugworld"
	main._open_pause_menu()
	_check(get_tree().paused and not main.pause_menu._online_warning.visible,
		"offline debug sessions share the same genuine pause behavior")
	main._close_pause_menu(false)
	main.mode = original_mode
	player.test_mode = original_test_mode
	player.velocity = original_velocity
	main.expedition_manager._toast_remaining = original_toast
	actor.queue_free()
	await get_tree().process_frame


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label)


func _has_key_binding(action: StringName, key: Key) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey and event.physical_keycode == key:
			return true
	return false
