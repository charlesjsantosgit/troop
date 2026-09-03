extends Node
## External autoload: instruments an unmodified supplied app/PCK, not a test scene.
## Sample both process and post-draw clocks. In particular, _ready -> first draw
## is part of max_gap_ms; first-draw shader compilation cannot disappear.

var _ready_usec := 0
var _last_process_usec := 0
var _last_draw_usec := 0
var _first_menu_usec := 0
var _last_heartbeat_usec := 0
var _max_gap_ms := 0.0
var _process_frames := 0
var _draw_frames := 0
var _heartbeat_seconds := 8.0
var _finished := false
var _menu_lost := false
var _updater: Node


func _init() -> void:
	_emit("INIT", {"ticks_ms": float(Time.get_ticks_usec()) / 1000.0})


func _ready() -> void:
	_ready_usec = Time.get_ticks_usec()
	_last_process_usec = _ready_usec
	_last_draw_usec = _ready_usec
	var expected := OS.get_environment("TROOP_FIRST_MENU_USER_DIR")
	var native := not OS.has_feature("editor")
	var rendered := DisplayServer.get_name() != "headless"
	_emit("READY", {"ticks_ms": float(_ready_usec) / 1000.0,
		"user_dir": OS.get_user_data_dir(), "native": native, "rendered": rendered,
		"phase": OS.get_environment("TROOP_FIRST_MENU_PHASE")})
	if expected.is_empty() or OS.get_user_data_dir() != expected or not native or not rendered:
		_fail("expected native renderer and isolated startup user directory")
		return
	_heartbeat_seconds = OS.get_environment("TROOP_FIRST_MENU_HEARTBEAT_SECONDS").to_float()
	if not is_finite(_heartbeat_seconds) or _heartbeat_seconds < 5.0 or _heartbeat_seconds > 10.0:
		_fail("invalid heartbeat duration")
		return
	_updater = get_node_or_null("/root/Updater")
	if _updater == null or not str(_updater.loaded_content_version()).is_empty():
		_fail("fresh startup must use the supplied app's original content")
		return
	# Main may otherwise schedule an automatic restart. Stop before its handler's
	# delayed restart rather than benchmarking changed code or leaving a child.
	_updater.update_staged.connect(_on_update_staged)
	RenderingServer.frame_post_draw.connect(_after_draw)


func _process(_delta: float) -> void:
	if _finished or _ready_usec == 0:
		return
	var now := Time.get_ticks_usec()
	_sample_gap("process", now - _last_process_usec, now)
	_last_process_usec = now
	_process_frames += 1
	if _process_frames == 1:
		_emit("FIRST_PROCESS_FRAME", {"ticks_ms": float(now) / 1000.0})


func _after_draw() -> void:
	if _finished:
		return
	var now := Time.get_ticks_usec()
	_sample_gap("post_draw", now - _last_draw_usec, now)
	_last_draw_usec = now
	_draw_frames += 1
	if _draw_frames == 1:
		_emit("FIRST_DRAW", {"ticks_ms": float(now) / 1000.0})
	var visible := _menu_visible()
	if visible and _first_menu_usec == 0:
		_first_menu_usec = now
		_last_heartbeat_usec = now
		_emit("MENU_VISIBLE", {"ticks_ms": float(now) / 1000.0})
	if _first_menu_usec == 0:
		return
	_menu_lost = _menu_lost or not visible
	if now - _last_heartbeat_usec >= 1000000:
		_emit("HEARTBEAT", {"ticks_ms": float(now) / 1000.0,
			"menu_visible": visible, "draw_frames": _draw_frames, "max_gap_ms": _max_gap_ms})
		_last_heartbeat_usec = now
	if now - _first_menu_usec >= int(_heartbeat_seconds * 1000000.0):
		_finished = true
		var original_content := str(_updater.loaded_content_version()).is_empty()
		_emit("DONE", {"ticks_ms": float(now) / 1000.0,
			"first_menu_ms": float(_first_menu_usec) / 1000.0,
			"heartbeat_ms": float(now - _first_menu_usec) / 1000.0,
			"max_gap_ms": _max_gap_ms, "draw_frames": _draw_frames,
			"process_frames": _process_frames, "menu_visible": visible,
			"menu_stayed_visible": not _menu_lost,
			"original_content": original_content, "version": str(_updater.current_version())})
		get_tree().quit(0 if visible and not _menu_lost and original_content else 1)


func _sample_gap(clock: String, elapsed_usec: int, now: int) -> void:
	var gap := float(elapsed_usec) / 1000.0
	_max_gap_ms = maxf(_max_gap_ms, gap)
	if gap >= 50.0:
		_emit("GAP", {"clock": clock, "ms": gap, "ticks_ms": float(now) / 1000.0})


func _menu_visible() -> bool:
	var main := get_tree().current_scene
	if main == null:
		return false
	# Avoid a global Main class dependency when loading this external script.
	for property in main.get_property_list():
		if str(property.name) == "menu":
			var menu: Variant = main.get("menu")
			return is_instance_valid(menu) and menu is Control and menu.is_visible_in_tree()
	return false


func _on_update_staged(_version: String) -> void:
	_fail("an automatic update staged; supplied-app benchmark would change on restart")


func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	_emit("FAIL", {"message": message})
	get_tree().quit(1)


func _emit(event: String, fields: Dictionary) -> void:
	fields["event"] = event
	print("NATIVEFIRSTMENU " + JSON.stringify(fields))
