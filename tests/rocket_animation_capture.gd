extends Node
## Deterministic Movie Maker driver for the two rocket proof clips:
##   rocket-capture outbound       Earth launch through lunar touchdown
##   rocket-capture moon-departure lunar ignition through the chase handoff
##
## Net's production mission clock intentionally uses wall time. Captures instead
## advance the exact same LunarRocket transforms by one 60 Hz step per rendered
## frame, so offline encoding cannot skip, duplicate, or stall animation time.

const DEFAULT_FPS := 60.0
const MOON_DEPARTURE_SECONDS := 18.0
const OUTBOUND_RENDER_SETTLE_SECONDS := 1.5

var _main: Node
var _manager: ExpeditionManager
var _rocket: LunarRocket
var _player: MonkeyPlayer
var _fade: ColorRect
var _rendered_frames := 0
var _fps := DEFAULT_FPS
var _frame_dt := 1.0 / DEFAULT_FPS


func run(main: Node, capture_args: Array) -> void:
	_main = main
	_manager = main.expedition_manager
	if not _manager or not _manager.rocket or not main.world.local_player:
		push_error("Rocket capture could not find the production expedition nodes")
		get_tree().quit(1)
		return
	_rocket = _manager.rocket
	_player = main.world.local_player
	_prepare_capture_world()
	_build_fade()
	var capture_kind := str(capture_args[0]).to_lower() \
		if not capture_args.is_empty() else "outbound"
	if capture_kind.ends_with("-window") and capture_args.size() > 3:
		_fps = clampf(float(capture_args[3]), 30.0, 60.0)
		_frame_dt = 1.0 / _fps
	elif capture_args.size() > 1:
		# Full proof clips default to 60 fps, while an explicit second argument
		# permits lightweight 30 fps review renders for either direction.
		_fps = clampf(float(capture_args[1]), 30.0, 60.0)
		_frame_dt = 1.0 / _fps
	match capture_kind:
		"outbound":
			await _capture_outbound()
		"outbound-window":
			var start_seconds := clampf(float(capture_args[1]), 0.0,
				LunarRocket.OUTBOUND_DURATION_SECONDS)
			var window_seconds := clampf(float(capture_args[2]), 0.1,
				LunarRocket.OUTBOUND_DURATION_SECONDS - start_seconds)
			await _capture_outbound_window(start_seconds, window_seconds)
		"moon-departure", "return":
			await _capture_moon_departure()
		"moon-departure-window":
			var start_seconds := clampf(float(capture_args[1]), 0.0,
				LunarRocket.RETURN_DURATION_SECONDS)
			var window_seconds := clampf(float(capture_args[2]), 0.1,
				LunarRocket.RETURN_DURATION_SECONDS - start_seconds)
			await _capture_moon_departure_window(start_seconds, window_seconds)
		_:
			push_error("Unknown rocket capture kind: %s" % capture_kind)
			get_tree().quit(2)
			return
	print("ROCKET_CAPTURE_COMPLETE kind=%s fps=%.0f frames=%d" % [
		capture_kind, _fps, _rendered_frames])
	get_tree().quit(0)


func _prepare_capture_world() -> void:
	if _main.hud:
		_main.hud.visible = false
	if _main._session_ui_layer:
		_main._session_ui_layer.visible = false
	if _manager._ui_layer:
		_manager._ui_layer.visible = false
	_main.set_process(false)
	_manager.set_process(false)
	Net.set_process(false)
	get_viewport().scaling_3d_scale = 1.0
	_main.world.set_expensive_effects(true)
	_player.test_mode = true
	_player.ti.dir = Vector2.ZERO
	_player.velocity = Vector3.ZERO
	_player.set_process(false)
	_player.set_physics_process(false)
	_player.set_expedition_locked(true)
	if _player.cam:
		_player.cam.process_mode = Node.PROCESS_MODE_DISABLED
	for weapon in [_player.gun, _player.shotgun, _player.smg, _player.sniper]:
		if weapon:
			weapon.visible = false
	_rocket.set_physics_process(false)
	_rocket.voyage_visuals.set_cinematic_terrain_enabled(true)
	_manager.voyage_camera.current = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _build_fade() -> void:
	var layer := CanvasLayer.new()
	layer.name = "RocketCaptureFade"
	layer.layer = 100
	add_child(layer)
	_fade = ColorRect.new()
	# Proof footage starts on the real launch frame. A capture-only black dissolve
	# made the corrected continuous climb look like another scene transition.
	_fade.color = Color(0.002, 0.004, 0.008, 0.0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_fade)


func _capture_outbound() -> void:
	_main.world.set_time_of_day_override(10.25)
	var launch := _rocket.earth_launch_transform
	_player.admin_teleport(launch.origin + launch.basis \
		* Vector3(4.0, 0.2, 7.0))
	_main.world.warm(2)
	_rocket.apply_authoritative_clock(LunarRocket.State.EARTH_BOARDING,
		true, 0.0)
	_rocket.board_crew(Net.local_id(), _player, _manager.local_suit,
		_manager.local_inventory)
	if not _rocket.launch_to_moon():
		push_error("Rocket capture could not start outbound voyage")
		get_tree().quit(1)
		return
	# Resetting to EARTH_BOARDING above intentionally ends any previous voyage and
	# clears the shared cinematic terrain projection. The production manager turns
	# it back on for a local passenger every render frame; Movie Maker disables that
	# manager loop, so explicitly mirror the production ownership after launch.
	_rocket.voyage_visuals.set_cinematic_terrain_enabled(true)
	_sync_capture_frame(0.0)
	# The renderer commits warmed terrain/material RIDs during its first frames.
	# Hold the exact T+0 pose while that happens; delivery transcodes trim these
	# known leading frames, preserving the complete slow launch with no fade or pop.
	for frame in range(maxi(int(ceil(OUTBOUND_RENDER_SETTLE_SECONDS * _fps)), 1)):
		_rocket.apply_authoritative_clock(LunarRocket.State.LAUNCH_ASCENT, true, 0.0)
		_sync_capture_frame(0.0)
		await _next_frame()
	await _hold(0.5)
	var mission_frames := int(LunarRocket.OUTBOUND_DURATION_SECONDS * _fps)
	for frame in range(mission_frames):
		_rocket.advance_voyage(_frame_dt)
		_sync_capture_frame(_rocket.voyage_elapsed \
			/ LunarRocket.OUTBOUND_DURATION_SECONDS)
		await _next_frame()
	await _hold(0.9)


func _capture_outbound_window(start_seconds: float,
		window_seconds: float) -> void:
	_main.world.set_time_of_day_override(10.25)
	var launch := _rocket.earth_launch_transform
	_player.admin_teleport(launch.origin + launch.basis * Vector3(4.0, 0.2, 7.0))
	_main.world.warm(2)
	_rocket.apply_authoritative_clock(LunarRocket.State.EARTH_BOARDING, true, 0.0)
	_rocket.board_crew(Net.local_id(), _player, _manager.local_suit,
		_manager.local_inventory)
	if not _rocket.launch_to_moon():
		push_error("Rocket window capture could not start outbound voyage")
		get_tree().quit(1)
		return
	_rocket.apply_authoritative_clock(
		LunarRocket.state_for_elapsed(true, start_seconds), true, start_seconds)
	_rocket.voyage_visuals.set_cinematic_terrain_enabled(true)
	# Reapply the requested time after taking local ownership so the retained
	# terrain receives the exact scaled-space curve before the first movie frame.
	_rocket.apply_authoritative_clock(
		LunarRocket.state_for_elapsed(true, start_seconds), true, start_seconds)
	var clear_color := _fade.color
	clear_color.a = 0.0
	_fade.color = clear_color
	_sync_capture_frame(start_seconds / LunarRocket.OUTBOUND_DURATION_SECONDS)
	await _next_frame()
	var window_frames := int(ceil(window_seconds * _fps))
	for frame in range(window_frames):
		var elapsed := minf(start_seconds + float(frame + 1) * _frame_dt,
			LunarRocket.OUTBOUND_DURATION_SECONDS)
		_rocket.apply_authoritative_clock(
			LunarRocket.state_for_elapsed(true, elapsed), true, elapsed)
		_sync_capture_frame(elapsed / LunarRocket.OUTBOUND_DURATION_SECONDS)
		await _next_frame()
func _capture_moon_departure() -> void:
	_main.world.set_earth_streaming_enabled(false)
	_rocket.apply_authoritative_clock(LunarRocket.State.LANDED_MOON,
		true, LunarRocket.OUTBOUND_DURATION_SECONDS)
	_rocket.board_crew(Net.local_id(), _player, _manager.local_suit,
		_manager.local_inventory)
	if not _rocket.begin_return_to_earth():
		push_error("Rocket capture could not start lunar departure")
		get_tree().quit(1)
		return
	_sync_capture_frame(0.0)
	await _hold(0.35)
	var departure_frames := int(MOON_DEPARTURE_SECONDS * _fps)
	for frame in range(departure_frames):
		_rocket.advance_voyage(_frame_dt)
		_sync_capture_frame(_rocket.voyage_elapsed \
			/ LunarRocket.RETURN_DURATION_SECONDS)
		await _next_frame()
	await _hold(0.75)


func _capture_moon_departure_window(start_seconds: float,
		window_seconds: float) -> void:
	_main.world.set_earth_streaming_enabled(false)
	_rocket.apply_authoritative_clock(LunarRocket.State.LANDED_MOON,
		true, LunarRocket.OUTBOUND_DURATION_SECONDS)
	_rocket.board_crew(Net.local_id(), _player, _manager.local_suit,
		_manager.local_inventory)
	if not _rocket.begin_return_to_earth():
		push_error("Rocket capture could not start lunar departure window")
		get_tree().quit(1)
		return
	_rocket.apply_authoritative_clock(
		LunarRocket.state_for_elapsed(false, start_seconds), false, start_seconds)
	_sync_capture_frame(start_seconds / LunarRocket.RETURN_DURATION_SECONDS)
	await _next_frame()
	var window_frames := int(ceil(window_seconds * _fps))
	for frame in range(window_frames):
		var elapsed := minf(start_seconds + float(frame + 1) * _frame_dt,
			LunarRocket.RETURN_DURATION_SECONDS)
		_rocket.apply_authoritative_clock(
			LunarRocket.state_for_elapsed(false, elapsed), false, elapsed)
		_sync_capture_frame(elapsed / LunarRocket.RETURN_DURATION_SECONDS)
		await _next_frame()


func _sync_capture_frame(progress: float) -> void:
	var seat := _rocket.seat_for_peer(Net.local_id())
	if seat >= 0:
		_player.global_transform = _rocket.seat_global_transform(seat)
		_player.reset_physics_interpolation()
	_rocket.reset_physics_interpolation()
	_manager._update_voyage_camera(0.0, progress, {}, true)


func _fade_to(alpha: float, seconds: float) -> void:
	var frames := maxi(int(ceil(seconds * _fps)), 1)
	var start_alpha := _fade.color.a
	for frame in range(frames):
		var t := smoothstep(0.0, 1.0, float(frame + 1) / float(frames))
		var color := _fade.color
		color.a = lerpf(start_alpha, alpha, t)
		_fade.color = color
		await _next_frame()


func _hold(seconds: float) -> void:
	for frame in range(maxi(int(ceil(seconds * _fps)), 1)):
		await _next_frame()


func _next_frame() -> void:
	_rendered_frames += 1
	await get_tree().process_frame
