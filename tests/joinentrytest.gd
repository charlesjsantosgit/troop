extends Node
## Exercise the real menu -> network -> full rendered world entry path.
## Unlike the terrain-only entry fixture, wall-clock gaps include every setup
## phase and renderer submission. Run alone, not beside another GPU benchmark.

const JOIN_DEADLINE_SECONDS := 45.0
const SETTLE_SECONDS := 8.0
const MAX_JOIN_FRAME_MS := 250.0

var _sampling := false
var _previous_usec := 0
var _frame_ms: Array[float] = []
var _main: Node
var _previous_stage := "handshake"
var _previous_pipelines: Array[int] = [0, 0, 0, 0, 0]


func _process(_delta: float) -> void:
	if not _sampling:
		return
	_record_frame_gap()


func _record_frame_gap() -> void:
	var now := Time.get_ticks_usec()
	var pipelines: Array[int] = []
	for monitor in [Performance.PIPELINE_COMPILATIONS_CANVAS,
			Performance.PIPELINE_COMPILATIONS_MESH, Performance.PIPELINE_COMPILATIONS_SURFACE,
			Performance.PIPELINE_COMPILATIONS_DRAW, Performance.PIPELINE_COMPILATIONS_SPECIALIZATION]:
		pipelines.append(int(Performance.get_monitor(monitor)))
	if _previous_usec > 0:
		var elapsed := float(now - _previous_usec) / 1000.0
		_frame_ms.append(elapsed)
		if elapsed > 100.0:
			var compiled: Array[int] = []
			for index in range(pipelines.size()):
				compiled.append(pipelines[index] - _previous_pipelines[index])
			print("JOIN_FRAME_GAP ms=%.3f pipelines=%s after=%s" % [
				elapsed, compiled, _previous_stage])
	_previous_usec = now
	_previous_pipelines = pipelines
	_previous_stage = str(_main.status_label.text) if is_instance_valid(
		_main.status_label) else "playing"


func run(main: Node, args: PackedStringArray) -> void:
	_main = main
	for variable in ["TROOP_ADMIN_KEY", "TROOP_ADMIN_TOKEN", "TROOP_STATE_DIR"]:
		OS.unset_environment(variable)
	# The runner must configure isolation before engine initialization. Changing
	# user:// here would move the shader-cache path after RendererRD opened it,
	# causing false cache errors and distorting the exact stalls under test.
	var custom_name := str(ProjectSettings.get_setting(
		"application/config/custom_user_dir_name", ""))
	if not bool(ProjectSettings.get_setting(
			"application/config/use_custom_user_dir", false)) \
			or not custom_name.begins_with("TROOP-join-entry-"):
		push_error("JOINENTRYTEST requires runner-provided startup isolation")
		get_tree().quit(1)
		return
	OS.set_environment("TROOP_JOIN_PROFILE", "1")
	print("JOINENTRY_USERDIR " + OS.get_user_data_dir())
	var address := str(args[0]) if not args.is_empty() else "127.0.0.1"
	var port := int(args[1]) if args.size() > 1 else Net.PORT
	main._show_menu()
	# Let the native window and connection UI present before starting the clock.
	for frame in range(10):
		await get_tree().process_frame
	_sampling = true
	_previous_usec = Time.get_ticks_usec()
	var started := Time.get_ticks_msec()
	main._begin_join(address, "JoinEntryProbe", port)
	while Time.get_ticks_msec() - started < JOIN_DEADLINE_SECONDS * 1000.0:
		await get_tree().process_frame
		if is_instance_valid(main.world) and main.world.local_player:
			main.world.local_player.test_mode = true
		if _entry_committed(main):
			break
	var entered := _entry_committed(main)
	var entry_ms := Time.get_ticks_msec() - started
	# process_frame resumes this coroutine before Node._process. Record the
	# trailing gap explicitly, including a last frame that crossed the deadline.
	_record_frame_gap()
	var join_max: float = _frame_ms.max() if not _frame_ms.is_empty() else 0.0
	var scene_ready := _scene_ready(main, "entry")
	var mouse_ready := DisplayServer.get_name() == "headless" \
		or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var settled := Time.get_ticks_msec()
	while entered and Time.get_ticks_msec() - settled < SETTLE_SECONDS * 1000.0:
		await get_tree().process_frame
	_record_frame_gap()
	_sampling = false
	var settled_ready := _scene_ready(main, "settled") if entered else false
	var all_max: float = _frame_ms.max() if not _frame_ms.is_empty() else 0.0
	var passed: bool = entered and scene_ready and settled_ready and mouse_ready \
		and join_max <= MAX_JOIN_FRAME_MS \
		and all_max <= MAX_JOIN_FRAME_MS
	# Exercise the normal session teardown and flush deferred frees before the
	# renderer exits. Quitting with the complete live world still attached can
	# leave pending shader RIDs in the headless renderer's destruction queue.
	var retired_world: WeakRef = weakref(main.world) if is_instance_valid(main.world) else null
	main._return_to_main_menu()
	for frame in range(3):
		await get_tree().process_frame
	var teardown_ready := (retired_world == null or retired_world.get_ref() == null) \
		and main.world == null and main.hud == null and main.expedition_manager == null \
		and main._session_ui_layer == null and main.admin_controller == null \
		and is_instance_valid(main.menu) and not Net.active \
		and Voice._world == null and not Voice._capture_active
	print("JOIN_TEARDOWN ready=%s" % teardown_ready)
	passed = passed and teardown_ready
	print("JOINENTRYTEST %s entered=%s ready=%s mouse=%s entry_ms=%d join_max_ms=%.3f all_max_ms=%.3f frames=%d driver=%s" % [
		"PASS" if passed else "FAIL", entered, scene_ready and settled_ready, mouse_ready, entry_ms, join_max, all_max,
		_frame_ms.size(), RenderingServer.get_current_rendering_driver_name()])
	get_tree().quit(0 if passed else 1)


func _entry_committed(main: Node) -> bool:
	if not is_instance_valid(main.world) or not is_instance_valid(main.world.local_player) \
			or is_instance_valid(main.menu) or not Net.active:
		return false
	# Main clears its menu reference immediately but queues the loading camera
	# for deletion at the end of that frame. A process_frame continuation can
	# observe this intermediate state before _process and the deletion flush.
	# Wait for the actual boundary; keep sampling so the first live-world draw
	# and any delay here still count against the unchanged frame/deadline gates.
	return main.world.get_node_or_null("OnlineLoadingCamera") == null


func _scene_ready(main: Node, stage: String) -> bool:
	var world: World = main.world
	var expedition: ExpeditionManager = main.expedition_manager
	var checks := {
		"world_exists": is_instance_valid(world),
		"expedition_exists": is_instance_valid(expedition),
		"hud_exists": is_instance_valid(main.hud),
		"session_ui_exists": is_instance_valid(main._session_ui_layer),
		"admin_exists": is_instance_valid(main.admin_controller),
	}
	if checks.values().has(false):
		print("JOIN_READINESS stage=%s checks=%s" % [stage, JSON.stringify(checks)])
		return false
	checks.merge({
		"player_exists": is_instance_valid(world.local_player),
		"water_exists": is_instance_valid(world.water_fx),
		"moon_exists": is_instance_valid(expedition.moon_world),
		"rocket_exists": is_instance_valid(expedition.rocket),
		"expedition_ui_exists": is_instance_valid(expedition._ui_layer),
	})
	if checks.values().has(false):
		print("JOIN_READINESS stage=%s checks=%s" % [stage, JSON.stringify(checks)])
		return false
	checks["voyage_exists"] = is_instance_valid(expedition.rocket.voyage_visuals)
	if not checks["voyage_exists"]:
		print("JOIN_READINESS stage=%s checks=%s" % [stage, JSON.stringify(checks)])
		return false
	var camera: Camera3D = expedition.voyage_camera if expedition._local_aboard \
		else world.local_player.cam._cam
	var loading_camera := world.get_node_or_null("OnlineLoadingCamera")
	checks.merge({
		"world_complete": world.is_build_complete(),
		"world_network_effects_enabled": world._network_transient_effects_enabled,
		"water_complete": world.water_fx.is_setup_complete(),
		"expedition_complete": expedition.is_configuration_complete(),
		"expedition_activation_complete": not expedition._online_activation_pending,
		"colony_updates_connected": Net.moon_colony_changed.is_connected(
			expedition._on_colony_changed),
		"colony_results_connected": Net.moon_colony_result.is_connected(
			expedition._on_colony_result),
		"expedition_updates_connected": Net.expedition_state_changed.is_connected(
			expedition._apply_authoritative_state),
		"realm_updates_connected": Net.player_realm_changed.is_connected(
			expedition._on_player_realm_changed),
		"cheese_results_connected": Net.moon_cheese_purchase_result.is_connected(
			expedition._on_moon_cheese_purchase_result),
		"moon_complete": expedition.moon_world.is_setup_complete(),
		"rocket_complete": expedition.rocket.is_setup_complete(),
		"voyage_complete": expedition.rocket.voyage_visuals.is_setup_complete(),
		"world_processing": world.can_process(),
		"player_processing": world.local_player.can_process(),
		"expedition_processing": expedition.can_process(),
		"hud_processing": main.hud.can_process(),
		"admin_processing": main.admin_controller.can_process(),
		"hud_visible": main.hud.visible,
		"session_ui_visible": main._session_ui_layer.visible,
		"expedition_ui_visible": expedition._ui_layer.visible,
		"camera_current": get_viewport().get_camera_3d() == camera,
		"loading_camera_removed": loading_camera == null,
		"voice_world_attached": Voice._world == world,
		"voice_capture_idle": not Voice._capture_active,
	})
	print("JOIN_READINESS stage=%s checks=%s" % [stage, JSON.stringify(checks)])
	if is_instance_valid(loading_camera):
		print("JOIN_READINESS_DETAIL stage=%s loading_camera_queued=%s" % [
			stage, loading_camera.is_queued_for_deletion()])
	if not checks["camera_current"]:
		print("JOIN_READINESS_DETAIL stage=%s camera_actual=%s camera_expected=%s" % [
			stage, get_viewport().get_camera_3d(), camera])
	return not checks.values().has(false)
