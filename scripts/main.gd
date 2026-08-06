extends Node
## Boot + session orchestration. CLI modes (after `--`):
##   movetest            headless movement/generation assertions
##   smoke               build world, print stats, quit
##   shot <name> <out>   spawn world and save a screenshot
##   nettest-host / nettest-join <ip>   two-instance replication check
##   server              headless dedicated authority
##   host | join <host>  local diagnostics / direct connection
##   online              join the configured public server

const MONKEY_NAMES := ["Bongo", "Mango", "Kiko", "Chimpy", "Zuzu", "Coco", "Peel", "Momo", "Banzai", "Ooki", "Jojo", "Tarz"]
const RENDER_PIXEL_BUDGET := 1440000.0
const MIN_RENDER_SCALE := 0.38
const NETTEST_CYCLE_HOUR := 7.25
const NETTEST_CYCLE_TOLERANCE_HOURS := 0.20

var world: World
var hud: HUD
var menu: Control
var pause_menu: PauseMenu
var pause_layer: CanvasLayer
var status_label: Label
var name_edit: LineEdit
var update_button: Button
var mode := "menu"
var _menu_scalars: Array[Dictionary] = []
var _perf_warmup := 0.0
var _perf_sample_t := 0.0
var _perf_low_samples := 0
var _perf_high_samples := 0
var _render_scale := 1.0
var _render_scale_ceiling := 1.0
var _display_resize_pending := false
var _camera_mode_preference := CameraRig.ViewMode.SHOULDER
var _mouse_sensitivity := 1.0
var _world_paused_by_menu := false
var _update_requires_installer := false
var _update_version := ""
var _update_restart_scheduled := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_register_inputs()
	var args := OS.get_cmdline_user_args()
	if args.is_empty() and OS.has_feature("dedicated_server"):
		args = PackedStringArray(["server"])
	# Keep test fixtures on their canonical inputs, while every player-facing
	# launch receives the bindings and look sensitivity saved in Settings.
	if args.is_empty() or args[0] in ["solo", "host", "join", "online"]:
		Settings.apply_saved_bindings()
	_mouse_sensitivity = Settings.mouse_sensitivity
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	randomize()
	Net.roster_changed.connect(_sync_puppets)
	Net.peer_state.connect(_on_peer_state)
	Net.peer_left.connect(_on_peer_left)
	Net.ook_from.connect(_on_ook)
	Net.net_error.connect(_on_net_error)
	Voice.microphone_error.connect(_on_microphone_error)
	Updater.status_changed.connect(_on_update_status_changed)
	Updater.update_available.connect(_on_update_available)
	Updater.update_staged.connect(_on_update_staged)
	Updater.installer_ready.connect(_on_installer_ready)

	if args.is_empty():
		_show_menu()
		return
	match args[0]:
		"movetest":
			mode = "movetest"
			_start_solo("TestMonkey", 1337, 2)
			var mt = load("res://tests/movetest.gd").new()
			add_child(mt)
			mt.run(self)
		"generationtest":
			mode = "generationtest"
			Gen.setup(1337)
			var gt = load("res://tests/generationtest.gd").new()
			add_child(gt)
			gt.call_deferred("run")
		"onlineperformancetest":
			mode = "onlineperformancetest"
			var online_performance_test = load(
				"res://tests/onlineperformancetest.gd").new()
			add_child(online_performance_test)
			online_performance_test.call_deferred("run")
		"seasontest":
			mode = "seasontest"
			_start_solo("SeasonTestMonkey", 2026, 1)
			var season_test = load("res://tests/seasontest.gd").new()
			add_child(season_test)
			season_test.call_deferred("run", self)
		"smoke":
			mode = "smoke"
			_start_solo("SmokeMonkey", 99, 1)
			world.set_expensive_effects(false)
			world.set_expensive_effects(true)
			print("SMOKE_OK chunks=%d vines=%d trees_c00=%d" % [world.chunks.size(), Gen.vines.size(), Gen.chunk_layout(0, 0).trees.size()])
			get_tree().quit(0)
		"shot":
			_do_shot(args)
		"perftest":
			mode = "perftest"
			_start_solo("PerfMonkey", 2026, 2)
			if args.size() > 1 and str(args[1]).to_lower() == "spring":
				world.set_season_override(SeasonalCycle.Season.SPRING)
				world.set_time_of_day_override(12.0)
			elif args.size() > 1 and str(args[1]).to_lower() == "winter":
				world.set_season_override(SeasonalCycle.Season.WINTER)
				world.set_time_of_day_override(12.0)
			elif args.size() > 1 and str(args[1]).to_lower() == "summer":
				world.set_season_override(SeasonalCycle.Season.SUMMER)
				world.set_time_of_day_override(12.0)
			var pt = load("res://tests/perftest.gd").new()
			add_child(pt)
			pt.run(self)
		"combattest":
			mode = "combattest"
			_start_solo("CombatMonkey", 2026, 2)
			var ct = load("res://tests/combattest.gd").new()
			add_child(ct)
			ct.call_deferred("run", self)
		"pausetest":
			mode = "solo"
			_start_solo("PauseMonkey", 2026, 1)
			var pause_test = load("res://tests/pausetest.gd").new()
			add_child(pause_test)
			pause_test.call_deferred("run", self)
		"animation-showcase":
			mode = "animation-showcase"
			_start_solo("ShowcaseMonkey", 2026, 3)
			var showcase = load("res://tests/animation_showcase.gd").new()
			add_child(showcase)
			showcase.call_deferred("run", self)
		"aitest":
			mode = "solo"
			_start_solo("AiTestMonkey", 2026, 2)
			var at = load("res://tests/aitest.gd").new()
			add_child(at)
			at.run(self)
		"nettest-host":
			_nettest_host()
		"nettest-join":
			_nettest_join(args[1] if args.size() > 1 else "127.0.0.1")
		"host":
			_begin_host(_rand_name())
		"join":
			_begin_join(args[1] if args.size() > 1 else "127.0.0.1",
				_rand_name(), int(args[2]) if args.size() > 2 else Net.PORT)
		"online":
			_begin_public_join(_rand_name())
		"server":
			_start_dedicated_server()
		"solo":
			mode = "solo"
			_start_solo(_rand_name(), randi() % 1000000, 2)
		_:
			_show_menu()


func _rand_name() -> String:
	return MONKEY_NAMES[randi() % MONKEY_NAMES.size()]


func _register_inputs() -> void:
	_add_key("move_fwd", KEY_W)
	_add_key("move_back", KEY_S)
	_add_key("move_left", KEY_A)
	_add_key("move_right", KEY_D)
	_add_key("jump", KEY_SPACE)
	_add_key("sprint", KEY_SHIFT)
	_add_key("crouch", KEY_CTRL)
	_add_key("grab", KEY_E)
	_add_mouse("shoot", MOUSE_BUTTON_LEFT)
	_add_mouse("aim", MOUSE_BUTTON_RIGHT)
	_add_mouse("reel_in", MOUSE_BUTTON_WHEEL_UP)
	_add_mouse("reel_out", MOUSE_BUTTON_WHEEL_DOWN)
	_add_key("reload", KEY_R)
	_add_key("use_bandage", KEY_H)
	_add_key("weapon_1", KEY_1)
	_add_key("weapon_2", KEY_2)
	_add_key("weapon_3", KEY_3)
	_add_key("weapon_4", KEY_4)
	_add_key("scope_zoom", KEY_Z)
	_add_key("melee_toggle", KEY_Q)
	_add_key("ook", KEY_V)
	_add_key("push_to_talk", KEY_T)
	_add_key("menu", KEY_ESCAPE)
	_add_key("fullscreen", KEY_F11)
	_add_key("camera_mode", KEY_C)


func _add_key(action: String, key: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	InputMap.action_add_event(action, ev)


func _add_mouse(action: String, btn: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	InputMap.action_add_event(action, ev)


# ---- session flows ---------------------------------------------------------

func _enter_world(pname: String, seed_v: int, warm_r: int) -> void:
	Gen.setup(seed_v)
	world = World.new()
	add_child(world)
	world.build()
	world.warm(warm_r)
	_finish_world_entry(pname)


func _enter_online_world(pname: String, seed_v: int) -> bool:
	Gen.setup(seed_v)
	# Keep the connection screen alive between the expensive setup phases. The
	# world itself remains paused until its center chunk and player are ready.
	await get_tree().process_frame
	if mode != "join" or not Net.active:
		return false
	world = World.new()
	world.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(world)
	world.build()
	await get_tree().process_frame
	if mode != "join" or not Net.active or not is_instance_valid(world):
		return false
	world.warm_online_entry()
	await get_tree().process_frame
	if mode != "join" or not Net.active or not is_instance_valid(world):
		return false
	_finish_world_entry(pname)
	world.process_mode = Node.PROCESS_MODE_INHERIT
	return true


func _finish_world_entry(pname: String) -> void:
	var player := world.spawn_local(Net.local_id(), pname)
	player.cam.set_view_mode(_camera_mode_preference)
	player.cam.set_sensitivity(_mouse_sensitivity)
	if mode == "solo":
		world.spawn_practice_targets()
		world.spawn_solo_ai()
	hud = HUD.new()
	hud.player = world.local_player
	add_child(hud)
	Voice.attach_world(world)
	_sync_puppets()
	_reset_adaptive_rendering()
	if DisplayServer.get_name() != "headless" and mode in ["menu", "solo", "host", "join"]:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _reset_adaptive_rendering() -> void:
	_perf_warmup = 5.0
	_perf_sample_t = 0.0
	_perf_low_samples = 0
	_perf_high_samples = 0
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_SPATIAL
	_render_scale_ceiling = _preferred_render_scale()
	_render_scale = _render_scale_ceiling
	get_viewport().scaling_3d_scale = _render_scale
	world.set_expensive_effects(false)
	world.set_fullscreen_performance(_render_scale_ceiling < 0.75)


func _preferred_render_scale() -> float:
	var size := DisplayServer.window_get_size()
	var pixels := float(maxi(size.x, 1) * maxi(size.y, 1))
	return clampf(sqrt(RENDER_PIXEL_BUDGET / pixels), MIN_RENDER_SCALE, 1.0)


func _on_viewport_size_changed() -> void:
	if not world or not is_instance_valid(world) or _display_resize_pending:
		return
	_display_resize_pending = true
	call_deferred("_apply_display_render_budget")


func _apply_display_render_budget() -> void:
	# Fullscreen/window size settles one frame after the mode change on macOS.
	await get_tree().process_frame
	_display_resize_pending = false
	if not world or not is_instance_valid(world):
		return
	_render_scale_ceiling = _preferred_render_scale()
	_render_scale = _render_scale_ceiling
	get_viewport().scaling_3d_scale = _render_scale
	world.set_fullscreen_performance(_render_scale_ceiling < 0.75)
	_perf_warmup = 2.0
	_perf_sample_t = 0.0
	_perf_low_samples = 0
	_perf_high_samples = 0


func _process(dt: float) -> void:
	if get_tree().paused or DisplayServer.get_name() == "headless" \
			or not world or not is_instance_valid(world):
		return
	if _perf_warmup > 0.0:
		_perf_warmup -= dt
		return
	_perf_sample_t += dt
	if _perf_sample_t < 1.25:
		return
	_perf_sample_t = 0.0

	var refresh := DisplayServer.screen_get_refresh_rate()
	if refresh <= 1.0:
		refresh = 60.0
	# Hold at least a 120 FPS render budget even on a 60 Hz panel for low input
	# latency, then match high-refresh displays up to the 160 FPS cap. Only the
	# 3D resolution steps down; menus and HUD remain pin-sharp.
	var target := clampf(refresh, 120.0, 160.0)
	var fps := float(Engine.get_frames_per_second())
	if fps < target * 0.92:
		_perf_low_samples += 1
		_perf_high_samples = 0
	elif fps > target * 0.97:
		_perf_high_samples += 1
		_perf_low_samples = 0
	else:
		_perf_low_samples = 0
		_perf_high_samples = 0

	if _perf_low_samples >= 2:
		_perf_low_samples = 0
		_render_scale = maxf(MIN_RENDER_SCALE, _render_scale - 0.04)
		get_viewport().scaling_3d_scale = _render_scale
	elif _perf_high_samples >= 4 and _render_scale < _render_scale_ceiling:
		_perf_high_samples = 0
		_render_scale = minf(_render_scale_ceiling, _render_scale + 0.02)
		get_viewport().scaling_3d_scale = _render_scale


func _start_solo(pname: String, seed_v: int, warm_r: int) -> void:
	Net.solo(pname, seed_v)
	_enter_world(pname, seed_v, warm_r)


func _begin_host(pname: String) -> void:
	mode = "host"
	var seed_v := randi() % 1000000
	var err := Net.host(pname, seed_v)
	if err != OK:
		_show_menu()
		if status_label:
			status_label.text = "could not host (port busy?)"
		return
	_close_menu()
	_enter_world(pname, seed_v, 2)


func _begin_public_join(pname: String) -> void:
	var address := _public_server_host()
	if address.is_empty():
		if status_label:
			status_label.text = ("Online server is not configured in this build yet. "
				+ "Publish it from GitHub after creating the managed server.")
		return
	_begin_join(address, pname, _public_server_port())


func _begin_join(address: String, pname: String, port := Net.PORT) -> void:
	mode = "join"
	var err := Net.join(address, pname, port)
	if err != OK:
		if status_label:
			status_label.text = "Could not use online server address."
		return
	if status_label:
		status_label.text = "Connecting to the worldwide canopy…"
	var ok := await _await_or_timeout(Net.world_ready, 12.0)
	if not ok:
		Net.shutdown()
		if status_label:
			status_label.text = "The online server did not answer. Try again shortly."
		return
	if status_label:
		status_label.text = "Connected — preparing your nearby jungle…"
	var entered := await _enter_online_world(pname, Net.world_seed)
	if entered:
		_close_menu()


func _public_server_host() -> String:
	var override := OS.get_environment("TROOP_SERVER_HOST").strip_edges()
	if not override.is_empty():
		return override
	return str(ProjectSettings.get_setting("network/public_server_host", "")) \
		.strip_edges()


func _public_server_port() -> int:
	var raw := OS.get_environment("TROOP_SERVER_PORT").strip_edges()
	if raw.is_valid_int():
		return clampi(raw.to_int(), 1, 65535)
	return clampi(int(ProjectSettings.get_setting("network/public_server_port",
		Net.PORT)), 1, 65535)


func _start_dedicated_server() -> void:
	mode = "server"
	var seed_v := 20260805
	var seed_text := OS.get_environment("TROOP_WORLD_SEED").strip_edges()
	if seed_text.is_valid_int():
		seed_v = seed_text.to_int()
	var port := Net.PORT
	var port_text := OS.get_environment("TROOP_SERVER_PORT").strip_edges()
	if port_text.is_valid_int():
		port = clampi(port_text.to_int(), 1, 65535)
	var max_clients := Net.MAX_CLIENTS
	var max_text := OS.get_environment("TROOP_MAX_CLIENTS").strip_edges()
	if max_text.is_valid_int():
		max_clients = clampi(max_text.to_int(), 2, 256)
	var bind_ip := OS.get_environment("TROOP_BIND_IP").strip_edges()
	if bind_ip.is_empty():
		bind_ip = "*"
	var err := Net.start_dedicated(seed_v, port, bind_ip, max_clients)
	if err != OK:
		push_error("DEDICATED_SERVER_FAIL err=%d bind=%s port=%d" % [
			err, bind_ip, port])
		get_tree().quit(1)
		return
	print("DEDICATED_SERVER_READY version=%s protocol=%d bind=%s port=%d seed=%d max=%d" % [
		Net.effective_game_version(), Net.PROTOCOL_VERSION, bind_ip, port,
		seed_v, max_clients])


func _await_or_timeout(sig: Signal, secs: float) -> bool:
	var box := [false]
	var cb := func(): box[0] = true
	sig.connect(cb, CONNECT_ONE_SHOT)
	var t := 0.0
	while not box[0] and t < secs:
		await get_tree().process_frame
		t += get_process_delta_time()
	if not box[0] and sig.is_connected(cb):
		sig.disconnect(cb)
	return box[0]


# ---- puppets ---------------------------------------------------------------

func _sync_puppets() -> void:
	if not world:
		return
	var my_id := Net.local_id()
	for id in Net.names:
		if id != my_id and not world.puppets.has(id):
			world.spawn_puppet(id, Net.names[id])
	for id in world.puppets.keys():
		if not Net.names.has(id):
			world.remove_puppet(id)


func _on_peer_state(id: int, pos: Vector3, yaw: float, vel: Vector3,
		anim: int, swinging: bool, anchor: Vector3, rope_tail: float,
		wraps: PackedVector3Array, weapon_kind: int, weapon_stowed: bool,
		melee_mode: bool, weapon_ammo: int, weapon_reloading: bool,
		healing_progress: float) -> void:
	if world and world.puppets.has(id):
		world.puppets[id].apply_state(pos, yaw, vel, anim, swinging, anchor,
			rope_tail, wraps, weapon_kind, weapon_stowed, melee_mode,
			weapon_ammo, weapon_reloading, healing_progress)


func _on_peer_left(id: int) -> void:
	if world:
		world.remove_puppet(id)


func _on_ook(_id: int, pos: Vector3) -> void:
	Sfx.play_at("ook", pos, -4)


func _on_net_error(msg: String) -> void:
	if mode in ["nettest-host", "nettest-join"]:
		print("NETTEST net_error: " + msg)
		return
	_close_pause_menu(false)
	Voice.clear_world()
	Net.shutdown()
	if world:
		world.queue_free()
		world = null
	if hud:
		hud.queue_free()
		hud = null
	_show_menu()
	if status_label:
		status_label.text = "disconnected: " + msg


func _on_microphone_error(msg: String) -> void:
	if status_label and mode == "menu":
		status_label.text = msg
	elif hud and is_instance_valid(hud) and hud.has_method("show_voice_error"):
		hud.call("show_voice_error", msg)


func _on_update_status_changed(next_status: String, next_detail: String) -> void:
	if mode == "menu" and status_label and next_status != "disabled":
		if next_status == "available" and _update_requires_installer:
			status_label.text = "TROOP %s needs the full installer before it can update." % _update_version
		else:
			status_label.text = next_detail
	_refresh_update_button()


func _on_update_available(version: String, requires_installer: bool,
		notes: String) -> void:
	_update_version = version
	_update_requires_installer = requires_installer
	if mode == "menu" and status_label:
		status_label.text = ("TROOP %s needs the full installer. %s" % [
			version, notes] if requires_installer else
			"TROOP %s is downloading automatically. %s" % [version, notes])
	_refresh_update_button()


func _on_update_staged(version: String) -> void:
	_update_version = version
	_update_requires_installer = false
	if mode == "menu":
		_schedule_staged_update_restart(version)


func _on_installer_ready(version: String, _path: String) -> void:
	_update_version = version
	_update_requires_installer = true
	if mode == "menu" and status_label:
		status_label.text = "TROOP %s is downloaded. Open the installer to finish updating." % version
	_refresh_update_button()


func _refresh_update_button() -> void:
	if not update_button or not is_instance_valid(update_button):
		return
	update_button.visible = false
	if Updater.status == "available" and _update_requires_installer:
		update_button.text = "DOWNLOAD TROOP %s UPDATE" % _update_version
		update_button.visible = true
	elif Updater.status == "installer_ready":
		update_button.text = "OPEN TROOP %s INSTALLER" % _update_version
		update_button.visible = true
	elif Updater.status == "error" and not Updater.manifest_url().is_empty():
		update_button.text = ("RETRY TROOP %s UPDATE" % _update_version
			if not Updater.available_manifest.is_empty() else "CHECK FOR UPDATES AGAIN")
		update_button.visible = true


func _on_update_button_pressed() -> void:
	if Updater.status == "installer_ready":
		if Updater.launch_downloaded_installer():
			status_label.text = "Installer opened. TROOP will stay playable until you close it."
		else:
			var retry_err := Updater.download_installer()
			status_label.text = ("Re-downloading the installer after its launch check failed…"
				if retry_err == OK else
				"Could not open or re-download the installer (%d)." % retry_err)
	elif _update_requires_installer:
		var err := Updater.download_installer()
		if err != OK and status_label:
			status_label.text = "Could not start the installer download (%d)." % err
	elif Updater.status == "error":
		var retry_err := (Updater.download_available_update()
			if not Updater.available_manifest.is_empty() else
			Updater.check_for_updates(true))
		if retry_err != OK and status_label:
			status_label.text = "Could not retry the update (%d)." % retry_err
	_refresh_update_button()


func _schedule_staged_update_restart(version: String) -> void:
	if _update_restart_scheduled or mode != "menu" \
			or not Updater.is_update_staged() \
			or Updater.staged_version() != version:
		return
	_update_restart_scheduled = true
	if status_label:
		status_label.text = "TROOP %s is ready. Restarting safely to apply it…" % version
	await get_tree().create_timer(1.25).timeout
	if mode == "menu" and Updater.is_update_staged() \
			and Updater.staged_version() == version:
		Updater.restart_to_apply()
	_update_restart_scheduled = false


# ---- menu ------------------------------------------------------------------

func _show_menu() -> void:
	_close_pause_menu(false)
	mode = "menu"
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if menu:
		menu.queue_free()
	_menu_scalars.clear()
	menu = Control.new()
	menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu.resized.connect(_refresh_menu_scale)
	var bg := MenuBackdrop.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu.add_child(bg)
	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.08, 0.06, 0.20)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu.add_child(shade)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.offset_left = 24
	center.offset_top = 24
	center.offset_right = -24
	center.offset_bottom = -24
	menu.add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _menu_panel_style())
	panel.custom_minimum_size = Vector2(570, 0)
	_menu_scale_size(panel, Vector2(570, 0))
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 13)
	panel.add_child(v)

	var eyebrow := Label.new()
	eyebrow.text = "WELCOME TO THE CANOPY"
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	eyebrow.add_theme_color_override("font_color", Color("b8e979"))
	_menu_scale_font(eyebrow, 13)
	v.add_child(eyebrow)

	var title := Label.new()
	title.text = "TROOP"
	title.add_theme_color_override("font_color", Color("f4ffd3"))
	title.add_theme_color_override("font_shadow_color", Color(0.02, 0.11, 0.06, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 4)
	title.add_theme_constant_override("shadow_offset_y", 5)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_scale_font(title, 76)
	v.add_child(title)
	var sub := Label.new()
	sub.text = "SWING · SHOOT · OOK  —  AN INFINITE JUNGLE"
	sub.add_theme_color_override("font_color", Color("b7d9b6"))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_scale_font(sub, 16)
	v.add_child(sub)

	var badges := HBoxContainer.new()
	badges.alignment = BoxContainer.ALIGNMENT_CENTER
	badges.add_theme_constant_override("separation", 8)
	for text in ["∞ JUNGLE", "MOMENTUM SWINGING", "6-SHOT BANANA GUN"]:
		var badge := Label.new()
		badge.text = text
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.add_theme_color_override("font_color", Color("d6f2bd"))
		badge.add_theme_stylebox_override("normal", _menu_badge_style())
		_menu_scale_font(badge, 11)
		badges.add_child(badge)
	v.add_child(badges)

	var divider := ColorRect.new()
	divider.color = Color(0.67, 0.90, 0.42, 0.22)
	divider.custom_minimum_size = Vector2(0, 1)
	v.add_child(divider)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 12)
	var nl := Label.new()
	nl.text = "YOUR MONKEY"
	nl.add_theme_color_override("font_color", Color("b8d0ba"))
	_menu_scale_font(nl, 12)
	name_row.add_child(nl)
	name_edit = LineEdit.new()
	name_edit.text = _rand_name()
	name_edit.placeholder_text = "Choose a name"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.add_theme_stylebox_override("normal", _menu_input_style())
	name_edit.add_theme_stylebox_override("focus", _menu_input_style(true))
	_menu_scale_font(name_edit, 17)
	name_row.add_child(name_edit)
	v.add_child(name_row)

	var camera_row := HBoxContainer.new()
	camera_row.add_theme_constant_override("separation", 12)
	var camera_label := Label.new()
	camera_label.text = "CAMERA"
	camera_label.add_theme_color_override("font_color", Color("b8d0ba"))
	_menu_scale_font(camera_label, 12)
	camera_row.add_child(camera_label)
	var camera_select := OptionButton.new()
	camera_select.add_item("RIGHT SHOULDER", 0)
	camera_select.add_item("FIRST PERSON", 1)
	camera_select.add_item("FRONT VIEW", 2)
	camera_select.selected = _camera_mode_preference
	camera_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	camera_select.custom_minimum_size = Vector2(0, 42)
	camera_select.add_theme_stylebox_override("normal", _menu_input_style())
	camera_select.add_theme_stylebox_override("hover", _menu_input_style(true))
	camera_select.add_theme_stylebox_override("focus", _menu_input_style(true))
	camera_select.add_theme_color_override("font_color", Color("e9ffd7"))
	camera_select.add_theme_color_override("font_hover_color", Color.WHITE)
	_menu_scale_font(camera_select, 15)
	_menu_scale_size(camera_select, Vector2(0, 42))
	camera_select.item_selected.connect(func(index: int):
		_camera_mode_preference = index)
	camera_row.add_child(camera_select)
	v.add_child(camera_row)

	var sensitivity_row := HBoxContainer.new()
	sensitivity_row.add_theme_constant_override("separation", 12)
	var sensitivity_label := Label.new()
	sensitivity_label.text = "LOOK SENS"
	sensitivity_label.add_theme_color_override("font_color", Color("b8d0ba"))
	_menu_scale_font(sensitivity_label, 12)
	sensitivity_row.add_child(sensitivity_label)
	var sensitivity_slider := HSlider.new()
	sensitivity_slider.min_value = 0.25
	sensitivity_slider.max_value = 2.5
	sensitivity_slider.step = 0.05
	sensitivity_slider.value = _mouse_sensitivity
	sensitivity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sensitivity_slider.custom_minimum_size = Vector2(0, 36)
	sensitivity_slider.tooltip_text = "Mouse look sensitivity"
	_menu_scale_size(sensitivity_slider, Vector2(0, 36))
	sensitivity_row.add_child(sensitivity_slider)
	var sensitivity_value := Label.new()
	sensitivity_value.text = "%.2f×" % _mouse_sensitivity
	sensitivity_value.custom_minimum_size = Vector2(58, 0)
	sensitivity_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sensitivity_value.add_theme_color_override("font_color", Color("e9ffd7"))
	_menu_scale_font(sensitivity_value, 13)
	_menu_scale_size(sensitivity_value, Vector2(58, 0))
	sensitivity_row.add_child(sensitivity_value)
	sensitivity_slider.value_changed.connect(func(value: float):
		_apply_mouse_sensitivity(value)
		Settings.set_mouse_sensitivity(value)
		sensitivity_value.text = "%.2f×" % value
	)
	sensitivity_slider.drag_ended.connect(func(changed: bool):
		if changed:
			Settings.save())
	sensitivity_slider.focus_exited.connect(func(): Settings.save())
	v.add_child(sensitivity_row)

	var solo := _menu_button("SOLO BANANA DUEL", Color("88cf3f"), Color("bdf06b"))
	solo.pressed.connect(func():
		mode = "solo"
		_close_menu()
		_start_solo(_pname(), randi() % 1000000, 2))
	name_edit.text_submitted.connect(func(_text: String): solo.emit_signal("pressed"))
	v.add_child(solo)

	var multiplayer_label := Label.new()
	multiplayer_label.text = "WORLDWIDE MULTIPLAYER"
	multiplayer_label.add_theme_color_override("font_color", Color("b8d0ba"))
	_menu_scale_font(multiplayer_label, 12)
	v.add_child(multiplayer_label)
	var online_b := _menu_button("PLAY ONLINE  ·  PUBLIC CANOPY",
		Color("257f70"), Color("39aa8f"))
	online_b.disabled = _public_server_host().is_empty()
	online_b.tooltip_text = ("Connects to the managed TROOP world. No port "
		+ "forwarding or player-hosted server required.")
	online_b.pressed.connect(func(): _begin_public_join(_pname()))
	v.add_child(online_b)
	var online_hint := Label.new()
	online_hint.text = ("MANAGED DEDICATED SERVER  ·  PUSH-TO-TALK  T  ·  NO PORT FORWARDING"
		if not online_b.disabled else
		"SERVER DEPLOYMENT PENDING  ·  CONFIGURE THROUGH GITHUB RELEASE SETUP")
	online_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	online_hint.add_theme_color_override("font_color", Color("8fb9a4"))
	_menu_scale_font(online_hint, 11)
	v.add_child(online_hint)

	status_label = Label.new()
	status_label.text = ("" if not online_b.disabled else
		"This source build is ready for a public server, but no hosted address is embedded yet.")
	status_label.add_theme_color_override("font_color", Color("ffd58a"))
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_menu_scale_font(status_label, 14)
	v.add_child(status_label)

	update_button = _menu_button("DOWNLOAD UPDATE", Color("a06628"), Color("c78331"))
	update_button.visible = false
	update_button.pressed.connect(_on_update_button_pressed)
	v.add_child(update_button)
	_refresh_update_button()

	var tip_panel := PanelContainer.new()
	tip_panel.add_theme_stylebox_override("panel", _menu_tip_style())
	v.add_child(tip_panel)
	var foot := Label.new()
	foot.text = "WASD MOVE  ·  E GRAB / OPEN CHEST  ·  LMB FIRE  ·  HOLD RMB AIM\n1–4 WEAPONS  ·  R RELOAD  ·  H BANDAGE  ·  HOLD T TO TALK  ·  C CAMERA"
	foot.add_theme_color_override("font_color", Color("a5c8a5"))
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_scale_font(foot, 12)
	tip_panel.add_child(foot)

	var fullscreen_hint := Label.new()
	fullscreen_hint.text = "F11  FULLSCREEN"
	fullscreen_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fullscreen_hint.add_theme_color_override("font_color", Color(0.62, 0.80, 0.63, 0.7))
	_menu_scale_font(fullscreen_hint, 11)
	v.add_child(fullscreen_hint)

	add_child(menu)
	call_deferred("_refresh_menu_scale")
	if not _update_version.is_empty() and Updater.is_update_staged():
		_schedule_staged_update_restart(_update_version)


func _menu_button(text: String, base: Color, hover: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 52)
	button.add_theme_color_override("font_color", Color("f6ffe7"))
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color("e2ffd0"))
	button.add_theme_stylebox_override("normal", _menu_button_style(base))
	button.add_theme_stylebox_override("hover", _menu_button_style(hover, 3))
	button.add_theme_stylebox_override("pressed", _menu_button_style(base.darkened(0.18), 1))
	button.add_theme_stylebox_override("focus", _menu_button_style(hover, 3, true))
	_menu_scale_font(button, 17)
	_menu_scale_size(button, Vector2(0, 52))
	return button


func _menu_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.11, 0.075, 0.88)
	style.border_color = Color(0.63, 0.88, 0.37, 0.36)
	style.set_border_width_all(1)
	style.set_corner_radius_all(24)
	style.shadow_color = Color(0, 0, 0, 0.42)
	style.shadow_size = 22
	style.shadow_offset = Vector2(0, 10)
	style.content_margin_left = 38
	style.content_margin_right = 38
	style.content_margin_top = 28
	style.content_margin_bottom = 26
	return style


func _menu_tip_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.18, 0.40, 0.23, 0.22)
	style.border_color = Color(0.62, 0.86, 0.4, 0.16)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style


func _menu_badge_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.46, 0.73, 0.25, 0.13)
	style.border_color = Color(0.7, 0.9, 0.4, 0.18)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 9
	style.content_margin_right = 9
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	return style


func _menu_input_style(focused := false) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.17, 0.11, 0.92)
	style.border_color = Color("9ee657") if focused else Color(0.48, 0.72, 0.47, 0.42)
	style.set_border_width_all(2 if focused else 1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style


func _menu_button_style(color: Color, border_width := 1, focused := false) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = Color("e5ff9a") if focused else color.lightened(0.22)
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(0, 0, 0, 0.26)
	style.shadow_size = 6
	style.shadow_offset = Vector2(0, 3)
	style.content_margin_left = 16
	style.content_margin_right = 16
	return style


func _menu_scale_font(node: Control, base_size: int) -> void:
	_menu_scalars.append({"node": node, "kind": "font", "base": base_size})


func _menu_scale_size(node: Control, base_size: Vector2) -> void:
	_menu_scalars.append({"node": node, "kind": "size", "base": base_size})


func _refresh_menu_scale() -> void:
	if not menu or not is_instance_valid(menu):
		return
	var viewport_size := menu.size
	var scale := clampf(minf(viewport_size.x / 1600.0, viewport_size.y / 900.0), 0.72, 1.45)
	for item in _menu_scalars:
		var node: Control = item.node
		if not is_instance_valid(node):
			continue
		if item.kind == "font":
			node.add_theme_font_size_override("font_size", maxi(10, roundi(int(item.base) * scale)))
		else:
			node.custom_minimum_size = item.base * scale


func _pname() -> String:
	var n := name_edit.text.strip_edges() if name_edit else ""
	return n if n != "" else _rand_name()


func _close_menu() -> void:
	if menu:
		menu.queue_free()
		menu = null
	update_button = null


func _open_pause_menu(open_settings := false) -> void:
	if pause_menu or menu or not world or not is_instance_valid(world):
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if world.local_player and world.local_player.cam:
		world.local_player.cam.set_aiming(false)
	pause_menu = PauseMenu.new()
	pause_menu.name = "PauseMenu"
	pause_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_layer = CanvasLayer.new()
	pause_layer.name = "PauseLayer"
	pause_layer.layer = 100
	pause_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(pause_layer)
	pause_layer.add_child(pause_menu)
	pause_menu.configure(mode in ["host", "join"] or Net.active)
	pause_menu.resume_requested.connect(_resume_from_pause)
	pause_menu.main_menu_requested.connect(_return_to_main_menu)
	pause_menu.sensitivity_changed.connect(_apply_mouse_sensitivity)
	if open_settings:
		pause_menu.open_settings()
	# A solo world can freeze completely. Multiplayer must keep receiving and
	# simulating peers, while Player's visible-cursor guard neutralizes local input.
	if mode == "solo":
		_world_paused_by_menu = true
		get_tree().paused = true


func _resume_from_pause() -> void:
	_close_pause_menu(true)


func _close_pause_menu(capture_mouse := true) -> void:
	if _world_paused_by_menu:
		get_tree().paused = false
		_world_paused_by_menu = false
	if pause_layer and is_instance_valid(pause_layer):
		pause_layer.queue_free()
	elif pause_menu and is_instance_valid(pause_menu):
		pause_menu.queue_free()
	pause_menu = null
	pause_layer = null
	if capture_mouse and world and is_instance_valid(world) and menu == null \
			and DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _apply_mouse_sensitivity(value: float) -> void:
	_mouse_sensitivity = clampf(value, 0.25, 2.5)
	if world and is_instance_valid(world) and world.local_player \
			and world.local_player.cam:
		world.local_player.cam.set_sensitivity(_mouse_sensitivity)


func _return_to_main_menu() -> void:
	_close_pause_menu(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Voice.clear_world()
	Net.shutdown()
	if world and is_instance_valid(world):
		world.process_mode = Node.PROCESS_MODE_DISABLED
		world.visible = false
		world.queue_free()
	world = null
	if hud and is_instance_valid(hud):
		hud.process_mode = Node.PROCESS_MODE_DISABLED
		hud.visible = false
		hud.queue_free()
	hud = null
	_show_menu()


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("fullscreen") and DisplayServer.get_name() != "headless":
		var next_mode := DisplayServer.WINDOW_MODE_WINDOWED if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN else DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(next_mode)
		get_viewport().set_input_as_handled()
		return
	if not pause_menu and e.is_action_pressed("camera_mode") and world and world.local_player \
			and world.local_player.cam:
		_camera_mode_preference = world.local_player.cam.toggle_view()
		if hud:
			hud.show_camera_mode(_camera_mode_preference)
		get_viewport().set_input_as_handled()
		return
	if e.is_action_pressed("menu"):
		if pause_menu:
			return
		if world and menu == null:
			_open_pause_menu()
			get_viewport().set_input_as_handled()
	elif e is InputEventMouseButton and e.pressed and world and menu == null \
			and pause_menu == null \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ---- screenshot + net test modes ------------------------------------------

func _track_diagnostic_camera(cam: Camera3D, player: MonkeyPlayer,
		pov: String) -> void:
	var travel := Vector3(player.velocity.x, 0, player.velocity.z)
	if travel.length_squared() < 0.01:
		travel = Vector3.FORWARD
	else:
		travel = travel.normalized()
	var right := travel.cross(Vector3.UP).normalized()
	var swimming := player.state == player.S.SWIM
	var focus_height := 0.18 if swimming else 0.48
	# Stay close to the waterline but high enough that a shore bank or small
	# terrain roll cannot occlude the body during the diagnostic sequence.
	var camera_height := 0.60 if swimming else 0.90
	if pov == "side":
		cam.global_position = player.global_position + right \
			* (1.8 if swimming else 2.7) \
			+ Vector3.UP * camera_height
	else:
		cam.global_position = player.global_position + travel * 3.0 \
			+ Vector3.UP * camera_height
	cam.look_at(player.global_position + Vector3.UP * focus_height, Vector3.UP)
	# These diagnostic cameras are advanced in discrete 15 fps sample steps.
	# Reset interpolation so a previous sample never ghosts or lags behind.
	cam.reset_physics_interpolation()


func _point_segment_distance(point: Vector3, start: Vector3,
		finish: Vector3) -> float:
	var span := finish - start
	if span.length_squared() < 0.000001:
		return point.distance_to(start)
	var along := clampf((point - start).dot(span) / span.length_squared(),
		0.0, 1.0)
	return point.distance_to(start + span * along)


func _point_segment_distance_2d(point: Vector2, start: Vector2,
		finish: Vector2) -> float:
	var span := finish - start
	if span.length_squared() < 0.000001:
		return point.distance_to(start)
	var along := clampf((point - start).dot(span) / span.length_squared(),
		0.0, 1.0)
	return point.distance_to(start + span * along)


func _do_shot(args: Array) -> void:
	mode = "shot"
	var what: String = args[1] if args.size() > 1 else "vista"
	var out: String = args[2] if args.size() > 2 else "user://shot.png"
	var movement_diagnostic_clip := what in [
		"clip-sprint-play", "clip-sprint-first", "clip-sprint-side", "clip-sprint-front",
		"clip-sprint-exit-side",
		"clip-swim-play", "clip-swim-first", "clip-swim-side", "clip-swim-front",
	]
	var sniper_diagnostic_clip := what in [
		"clip-sniper-scope", "clip-sniper-hip", "clip-sniper-rope-side",
		"clip-sniper-rope-front",
	]
	var reload_diagnostic := what in [
		"reload-banana", "reload-shotgun", "reload-smg", "reload-sniper",
		"reload-banana-third",
	]
	var bandage_diagnostic := what in ["bandage", "bandage-third"]
	var seasonal_diagnostic := what in [
		"season-spring", "season-summer", "season-autumn", "season-winter",
		"winter-scarf", "lighting-sunrise", "lighting-night",
	]
	var diagnostic_clip := movement_diagnostic_clip or sniper_diagnostic_clip
	if what == "menu":
		_show_menu()
		for i in range(8):
			await RenderingServer.frame_post_draw
		var menu_image := get_viewport().get_texture().get_image()
		menu_image.save_png(out)
		print("SHOT_SAVED " + out)
		get_tree().quit(0)
		return
	_start_solo("Bongo", 2026, 1 if seasonal_diagnostic else 3)
	match what:
		"season-spring":
			world.set_season_override(SeasonalCycle.Season.SPRING)
			world.set_time_of_day_override(12.0)
		"season-summer":
			world.set_season_override(SeasonalCycle.Season.SUMMER)
			world.set_time_of_day_override(12.0)
		"season-autumn":
			world.set_season_override(SeasonalCycle.Season.AUTUMN)
			world.set_time_of_day_override(12.0)
		"season-winter":
			world.set_season_override(SeasonalCycle.Season.WINTER)
			world.set_time_of_day_override(12.0)
		"winter-scarf":
			world.set_season_override(SeasonalCycle.Season.WINTER)
			world.set_time_of_day_override(12.0)
		"lighting-sunrise":
			world.set_season_override(SeasonalCycle.Season.SUMMER)
			world.set_time_of_day_override(6.35)
		"lighting-night":
			world.set_season_override(SeasonalCycle.Season.SUMMER)
			world.set_time_of_day_override(23.0)
	if what in ["pause-menu", "pause-settings", "pause-controls"]:
		await get_tree().process_frame
		_open_pause_menu(what != "pause-menu")
		if what == "pause-controls" and pause_menu:
			pause_menu.call("_show_settings_tab", 1)
		for i in range(8):
			await RenderingServer.frame_post_draw
		var pause_image := get_viewport().get_texture().get_image()
		pause_image.save_png(out)
		print("SHOT_SAVED " + out)
		get_tree().quit(0)
		return
	# Configure diagnostic clips before the first rendered frame so Movie Maker
	# does not prepend a HUD-covered setup shot to the useful footage.
	if diagnostic_clip and hud and what not in [
			"clip-sniper-scope", "clip-sniper-hip"]:
		hud.visible = false
	else:
		await get_tree().process_frame
	var sp := world.spawn_point()
	var cam := Camera3D.new()
	cam.fov = 68
	add_child(cam)
	var use_player_camera := false

	if what in [
		"thirdperson", "firstperson", "melee-firstperson", "front", "ads",
		"shotgun", "smg",
		"tracer-shotgun", "tracer-smg", "death", "headshot-death",
		"reload-banana", "reload-shotgun", "reload-smg", "reload-sniper",
		"reload-banana-third", "bandage", "bandage-third",
	]:
		var p := world.local_player
		p.test_mode = true
		var px := 0.0
		var pz := 0.0
		p.global_position = Vector3(px, Gen.height(px, pz) + 0.05, pz)
		p.velocity = Vector3.ZERO
		p.cam.yaw = 0.0
		p.cam.pitch = -0.04
		if what in ["thirdperson", "tracer-shotgun", "tracer-smg",
				"reload-banana-third", "bandage-third"]:
			p.cam.set_first_person(false)
		elif what == "front":
			p.cam.set_view_mode(CameraRig.ViewMode.FRONT)
		elif what == "ads":
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			p.cam.set_first_person(false)
			p.cam.set_aiming(true)
		else:
			p.cam.set_first_person(true)
		if what in ["shotgun", "tracer-shotgun", "reload-shotgun"]:
			p.equip_weapon(2)
			p.shotgun.recoil = 0.55
		elif what in ["smg", "tracer-smg", "reload-smg"]:
			p.equip_weapon(3)
			p.smg.recoil = 0.45
		elif what == "reload-sniper":
			p.equip_weapon(4)
		else:
			p.gun.recoil = 0.3
		# Freeze a representative airborne catch pose for visual regression
		# screenshots. Threshold-based reload events still run, so these fixtures
		# exercise the exact prop and hand path used in live play.
		if reload_diagnostic:
			if hud:
				hud.visible = false
			p.set_physics_process(false)
			var reload_weapon: Variant = p.active_weapon
			reload_weapon.ammo = 0
			reload_weapon.start_reload()
			var pose_progress := 0.39
			var pose_duration := PumpShotgun.SHELL_RELOAD_TIME \
				if reload_weapon is PumpShotgun else (
					SMG.RELOAD_TIME if reload_weapon is SMG else (
						SniperRifle.RELOAD_TIME if reload_weapon is SniperRifle \
						else BananaGun.RELOAD_TIME))
			reload_weapon.tick(pose_duration * pose_progress)
			reload_weapon._process(0.0)
		elif bandage_diagnostic:
			if hud:
				hud.visible = false
			p.state = p.S.GROUND
			p.health = 36.0
			p.bandages = 2
			p.start_bandage()
			p._update_bandage(p.BANDAGE_TIME * 0.54)
			p.set_physics_process(false)
		if what == "melee-firstperson":
			p.set_physics_process(false)
			p.set_melee_mode(true)
			p.melee_attack_combo = 0
			p.melee_attack_remaining = p.MELEE_ATTACK_DURATION * 0.60
		if not reload_diagnostic and not bandage_diagnostic:
			var rival: AiMonkey = world.spawn_solo_ai()
			rival.set_physics_process(false)
			rival.set_process(false)
			var rz := -8.0
			var rival_x := 1.8
			rival.global_position = Vector3(rival_x, Gen.height(rival_x, rz), rz)
			for i in range(24):
				await get_tree().physics_frame
		if what in ["death", "headshot-death"]:
			p.health = 10.0
			p._invulnerable_t = 0.0
			var death_impulse := Vector3(2.0, 0.35, -2.8)
			p.take_damage(20.0, null, death_impulse,
				"head" if what == "headshot-death" else "body")
			for i in range(24):
				await get_tree().physics_frame
		if what in ["tracer-shotgun", "tracer-smg"]:
			var tracer_kind := Net.WEAPON_SHOTGUN \
				if what == "tracer-shotgun" else Net.WEAPON_SMG
			var tracer_speed := PumpShotgun.MUZZLE_SPEED \
				if tracer_kind == Net.WEAPON_SHOTGUN else SMG.MUZZLE_SPEED
			var tracer_damage := PumpShotgun.PELLET_DAMAGE \
				if tracer_kind == Net.WEAPON_SHOTGUN else SMG.DAMAGE
			var tracer_start := p.global_position + Vector3(0.05, 1.14, -1.4)
			# Slight off-axis path keeps the ribbon visible in the regression
			# screenshot; in play, weapon spread/muzzle parallax supplies this.
			var tracer_finish := tracer_start + Vector3(-1.1, 0, -3.6)
			var tracer := BananaBullet.new()
			world.add_child(tracer)
			tracer.configure(p, world, tracer_finish,
				Vector3(0, 0, -tracer_speed), tracer_damage, false, tracer_kind)
			tracer.set_physics_process(false)
			tracer._draw_trail(tracer_start, tracer_finish)
		if what.ends_with("-third"):
			cam.fov = 54.0
			cam.global_position = p.global_position + Vector3(2.5, 1.45, 3.15)
			cam.look_at(p.global_position + Vector3(0.0, 0.78, 0.0))
			use_player_camera = false
		else:
			use_player_camera = true
	elif what == "swing":
		var p := world.local_player
		p.test_mode = true
		var best_id := ""
		var best_d := 1e9
		for id in Gen.vines:
			var v: Dictionary = Gen.vines[id]
			var d: float = Vector2(v.anchor.x, v.anchor.z).length()
			if d < best_d and float(v.len) > 6.0:
				best_d = d
				best_id = id
		var vn: Dictionary = Gen.vines[best_id]
		p.global_position = Vector3(vn.anchor.x + 1.2, vn.anchor.y - float(vn.len) + 1.2, vn.anchor.z + 1.5)
		p.velocity = Vector3(-2, 0, -8)
		p.state = p.S.AIR
		p.ti.grab = true
		for i in range(28):
			await get_tree().physics_frame
		cam.global_position = p.global_position + Vector3(4.2, 1.6, 4.2)
		cam.look_at(p.global_position + Vector3(0, 0.9, 0))
	elif what == "face":
		var p := world.local_player
		p.test_mode = true
		p.set_physics_process(false)
		p.set_process(false)
		var px := 0.0
		var pz := 0.0
		p.global_position = Vector3(px, Gen.height(px, pz) + 0.1, pz)
		p.velocity = Vector3.ZERO
		p.gun.visible = false
		p.shotgun.visible = false
		p.smg.visible = false
		p.rig.set_gun_aim(false, Vector3.FORWARD, 0.0)
		p.rig.set_yaw(0.0)
		for i in range(20):
			p.rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.IDLE,
				Vector3.ZERO, true, Vector3.ZERO)
		cam.global_position = p.global_position + Vector3(0, 1.19, -0.82)
		cam.look_at(p.global_position + Vector3(0, 1.17, 0))
	elif what == "gun":
		var p := world.local_player
		p.test_mode = true
		var px := 0.0
		var pz := 0.0
		p.global_position = Vector3(px, Gen.height(px, pz) + 0.1, pz)
		p.velocity = Vector3.ZERO
		p.gun.recoil = 0.38
		world.spawn_practice_targets()
		for i in range(12):
			await get_tree().physics_frame
		cam.global_position = p.global_position + Vector3(1.45, 1.15, -2.15)
		cam.look_at(p.global_position + Vector3(0, 0.72, 0))
	elif what in ["jump", "melee"]:
		var p := world.local_player
		p.test_mode = true
		p.set_physics_process(false)
		p.set_process(false)
		var px := 0.0
		var pz := 0.0
		p.global_position = Vector3(px, Gen.height(px, pz) + 1.15, pz)
		p.velocity = Vector3(0, 5.5, -7.0) if what == "jump" else Vector3.ZERO
		p.state = p.S.AIR if what == "jump" else p.S.GROUND
		if what == "melee":
			p.set_melee_mode(true)
			p.melee_attack_combo = 1
			p.melee_attack_remaining = p.MELEE_ATTACK_DURATION * 0.60
			p.rig.set_gun_aim(false, Vector3.FORWARD, 0.0)
			p.rig.set_melee_pose(true, true, 0.40, 1)
		else:
			p.rig.set_gun_aim(true, Vector3.FORWARD, 0.0)
			p.rig.set_melee_pose(false, false, 0.0, 0)
		for i in range(24):
			p.rig.update_motion(1.0 / 60.0,
				MonkeyRig.Anim.AIR if what == "jump" else MonkeyRig.Anim.IDLE,
				p.velocity, false, Vector3.ZERO)
		cam.global_position = p.global_position + Vector3(2.3, 0.75, -2.6)
		cam.look_at(p.global_position + Vector3(0, 0.75, 0))
	elif what == "aim":
		# stand the monkey ~2.3m from a low natural vine so the crosshair
		# (test-mode aim is -Z) targets it and the ring appears on the strand
		var p := world.local_player
		p.test_mode = true
		var bid := ""
		var bd := 1e9
		for id in Gen.vines:
			var v: Dictionary = Gen.vines[id]
			var gu := Gen.height(v.anchor.x, v.anchor.z)
			var lift: float = v.anchor.y - float(v.len) - gu
			var d: float = Vector2(v.anchor.x, v.anchor.z).length()
			if d > 8.0 and d < 40.0 and float(v.len) > 5.0 and lift < 2.6 and d < bd:
				bd = d
				bid = id
		if bid != "":
			var vn: Dictionary = Gen.vines[bid]
			var px: float = vn.anchor.x
			var pz: float = vn.anchor.z + 2.3
			p.global_position = Vector3(px, Gen.height(px, pz) + 0.2, pz)
			p.velocity = Vector3.ZERO
			for i in range(30):
				await get_tree().physics_frame
			cam.global_position = p.global_position + Vector3(2.2, 1.9, 3.6)
			cam.look_at(Vector3(vn.anchor.x, vn.anchor.y - float(vn.len) + 1.4, vn.anchor.z))
	elif sniper_diagnostic_clip:
		# Scope and rope-handling fixtures use the same 30-frame / 15 fps cadence
		# as locomotion captures, giving a deterministic two-second review clip.
		var p := world.local_player
		p.test_mode = true
		p.equip_weapon(4)
		if p.rig.tag:
			p.rig.tag.visible = false
		if what == "clip-sniper-scope":
			p.set_physics_process(false)
			p.global_position = Vector3(0.0, Gen.height(0.0, 0.0) + 5.0, 0.0)
			p.velocity = Vector3.ZERO
			p.state = p.S.GROUND
			p.cam.yaw = 0.0
			p.cam.pitch = 0.0
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			p.cam.set_aiming(true)
			p.cam.snap_to_target()
			p.cam._cam.current = true
			var target := world.spawn_puppet(91, "Longshot")
			target.set_process(false)
			target.global_position = p.global_position + Vector3(0.0, -0.01, -120.0)
			var base := out.trim_suffix(".png")
			for f in range(30):
				if f in [10, 20]:
					p.sniper.cycle_zoom()
					# Recenter between magnification demonstrations; each preceding
					# shot still gets six frames to show the full heavy recoil arc.
					p.cam._recoil_pitch = 0.0
					p.cam._recoil_yaw = 0.0
					p.cam._recoil_roll = 0.0
					p.cam._recoil_pitch_velocity = 0.0
					p.cam._recoil_yaw_velocity = 0.0
					p.cam._recoil_roll_velocity = 0.0
					p.cam._recoil_back = 0.0
					p.cam._recoil_shake = 0.0
				if f in [4, 14, 24]:
					p.sniper.tick(SniperRifle.FIRE_INTERVAL + 0.01)
					var shot_input: Dictionary = p._gather()
					shot_input.shoot_just = true
					p._combat(shot_input)
				for i in range(4):
					await get_tree().physics_frame
				await RenderingServer.frame_post_draw
				var frame_img := get_viewport().get_texture().get_image()
				var save_error := frame_img.save_png("%s_%02d.png" % [base, f])
				if save_error != OK:
					push_error("Sniper scope frame %d failed to save: %s" % [
						f, error_string(save_error)])
					get_tree().quit(1)
					return
			print("CLIP_SAVED %s frames=30 fps=15 seconds=2.00" % base)
			get_tree().quit(0)
			return
		if what == "clip-sniper-hip":
			p.set_physics_process(false)
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			p.global_position = Vector3(0.0, Gen.height(0.0, 0.0) + 5.0, 0.0)
			p.state = p.S.GROUND
			p.velocity = Vector3(13.0, 0.0, 0.0)
			p.cam.yaw = 0.0
			p.cam.pitch = 0.0
			p.cam.set_view_mode(CameraRig.ViewMode.FIRST_PERSON)
			p.cam.snap_to_target()
			p.cam._cam.current = true
			var target := world.spawn_puppet(92, "Range Target")
			target.set_process(false)
			target.global_position = p.global_position + Vector3(0.0, 0.0, -30.0)
			var base := out.trim_suffix(".png")
			for f in range(30):
				if f == 15:
					p.velocity = Vector3.ZERO
				if f in [5, 22]:
					p.sniper.tick(SniperRifle.FIRE_INTERVAL + 0.01)
					var shot_input: Dictionary = p._gather()
					shot_input.shoot_just = true
					p._combat(shot_input)
				for i in range(4):
					await get_tree().physics_frame
				await RenderingServer.frame_post_draw
				var frame_img := get_viewport().get_texture().get_image()
				var save_error := frame_img.save_png("%s_%02d.png" % [base, f])
				if save_error != OK:
					push_error("Sniper hip frame %d failed to save: %s" % [
						f, error_string(save_error)])
					get_tree().quit(1)
					return
			print("CLIP_SAVED %s frames=30 fps=15 seconds=2.00" % base)
			get_tree().quit(0)
			return
		var base_height := Gen.height(0.0, 0.0)
		p.global_position = Vector3(3.0, base_height + 4.2, 0.0)
		p.velocity = Vector3(0.0, 0.0, -7.5)
		p.state = p.S.SWING
		p.swing_anchor = Vector3(0.0, base_height + 10.0, 0.0)
		p.swing_len = p.hand_pos().distance_to(p.swing_anchor)
		p.swing_len_target = p.swing_len
		p.swing_vine_len = 12.0
		p.swing_max_len = 12.0
		p.ti.grab = true
		p.reset_physics_interpolation()
		p._sync_weapon_presentation(true)
		var pov := "front" if what.ends_with("front") else "side"
		cam.fov = 52.0
		cam.near = 0.05
		cam.current = true
		for i in range(18):
			await get_tree().physics_frame
		_track_diagnostic_camera(cam, p, pov)
		var base := out.trim_suffix(".png")
		for f in range(30):
			if f > 0:
				for i in range(4):
					await get_tree().physics_frame
			if p.state != p.S.SWING:
				push_error("Sniper rope fixture released at frame %d" % f)
				get_tree().quit(1)
				return
			_track_diagnostic_camera(cam, p, pov)
			await RenderingServer.frame_post_draw
			var frame_img := get_viewport().get_texture().get_image()
			var save_error := frame_img.save_png("%s_%02d.png" % [base, f])
			if save_error != OK:
				push_error("Sniper rope frame %d failed to save: %s" % [
					f, error_string(save_error)])
				get_tree().quit(1)
				return
		var rope_start := p.swing_anchor
		var rope_end := p.hand_pos()
		var tail_tip: Vector3 = p.rig.tail_segs[
			p.rig.tail_segs.size() - 1].to_global(Vector3(0.0, 0.0, 0.17))
		var tail_contact_error := _point_segment_distance(
			tail_tip, rope_start, rope_end)
		var left_foot_error := _point_segment_distance(
			p.rig.foot_l.global_position, rope_start, rope_end)
		var right_foot_error := _point_segment_distance(
			p.rig.foot_r.global_position, rope_start, rope_end)
		var support_paw := p.rig.el_l.to_global(
			Vector3(0.0, -MonkeyRig.ARM_B, 0.0))
		var support_error := support_paw.distance_to(
			p.sniper.support_grip.global_position)
		print(("SNIPER_ROPE_CONTACT tail=%.3f left_foot=%.3f " \
			+ "right_foot=%.3f support_paw=%.3f blend=%.3f aim=%s " \
			+ "weapon=%s parent=%s reach=%.3f") % [tail_contact_error,
			left_foot_error, right_foot_error, support_error,
			p.rig._sniper_rope_blend, p.rig._gun_aim_active,
			p.active_weapon.get_class() if p.active_weapon else "none",
			p.sniper.get_parent().name,
			p.rig.sh_l.global_position.distance_to(
				p.sniper.support_grip.global_position)])
		if tail_contact_error >= 0.035 or left_foot_error >= 0.10 \
				or right_foot_error >= 0.10 or support_error >= 0.07:
			push_error("Sniper rope contact diagnostic exceeded tolerance")
			get_tree().quit(1)
			return
		print("CLIP_SAVED %s frames=30 fps=15 seconds=2.00" % base)
		get_tree().quit(0)
		return
	elif movement_diagnostic_clip:
		# Two-second, 15 fps frame sequences for animation debugging:
		# clip-<subject>-<pov>. Four 60 Hz physics ticks separate each sample.
		# subject: sprint | swim   pov: play | side | front. The additional
		# sprint-exit-side fixture proves that all IK axes restore after release.
		var clip_parts := what.split("-")
		var subject: String = clip_parts[1]
		var sprint_exit := subject == "sprint" and clip_parts.size() == 4 \
			and clip_parts[2] == "exit"
		var pov: String = clip_parts[3] if sprint_exit else clip_parts[2]
		var p := world.local_player
		p.test_mode = true
		if p.rig.tag:
			p.rig.tag.visible = false
		if subject == "sprint":
			var run_direction := Vector3.FORWARD
			var run_lane_ok := false
			for heading in range(0, 360, 15):
				var direction := Vector3(cos(deg_to_rad(heading)), 0,
					sin(deg_to_rad(heading)))
				var lane_ok := true
				var previous_height := Gen.height(0.0, 0.0)
				for distance in range(0, 33, 2):
					var sample := direction * float(distance)
					var sample_height := Gen.height(sample.x, sample.z)
					if sample_height <= Gen.WATER_Y + 0.55 \
							or absf(sample_height - previous_height) > 1.15:
						lane_ok = false
						break
					previous_height = sample_height
				if not lane_ok:
					continue
				# Check the actual deterministic layout, including hero/random trunks
				# and rocks, so the review shows camera motion instead of a collision.
				var lane_start := Vector2.ZERO
				var lane_end := Vector2(direction.x, direction.z) * 32.0
				for chunk_z in [-1, 0]:
					if not lane_ok:
						break
					for chunk_x in [-1, 0]:
						var runway_layout := Gen.chunk_layout(chunk_x, chunk_z)
						for tree in runway_layout.trees:
							var tree_pos := Vector2(tree.pos.x, tree.pos.z)
							if _point_segment_distance_2d(tree_pos,
									lane_start, lane_end) < tree.trunk_r + 0.95:
								lane_ok = false
								break
						if not lane_ok:
							break
						for rock in runway_layout.rocks:
							var rock_pos := Vector2(rock.pos.x, rock.pos.z)
							if _point_segment_distance_2d(rock_pos,
									lane_start, lane_end) < rock.r + 0.65:
								lane_ok = false
								break
				if lane_ok:
					run_direction = direction
					run_lane_ok = true
					break
			if not run_lane_ok:
				push_error("Diagnostic sprint clip could not find a dry runway")
				get_tree().quit(1)
				return
			p.global_position = Vector3(0, Gen.height(0, 0) + 0.05, 0)
			p.state = p.S.GROUND
			p.ti.dir = Vector2(run_direction.x, run_direction.z)
			p.ti.sprint = true
			p.sprint_held = true
			p.quad_t = 0.5
			p.velocity = run_direction * p.SPRINT_SPEED + Vector3.DOWN * 2.0
		else:
			# Locate a deterministic broad-water runway instead of pinning this test
			# to one shoreline. The generous lead-in and side samples keep the full
			# two-second stroke in deep water even as macro-lake shaping evolves.
			var lake := Vector3.ZERO
			var swim_direction := Vector3.FORWARD
			var lake_ok := false
			for ring in range(2, 34):
				if lake_ok:
					break
				for grid_z in range(-ring, ring + 1):
					if lake_ok:
						break
					for grid_x in range(-ring, ring + 1):
						if abs(grid_x) != ring and abs(grid_z) != ring:
							continue
						var candidate := Vector3(float(grid_x) * 12.0, 0.0,
							float(grid_z) * 12.0)
						if Gen.WATER_Y - Gen.height(candidate.x, candidate.z) <= 1.8:
							continue
						for heading in range(0, 360, 15):
							var direction := Vector3(cos(deg_to_rad(heading)), 0.0,
								sin(deg_to_rad(heading)))
							var lane_right := direction.cross(Vector3.UP).normalized()
							var direction_ok := true
							for distance in range(-4, 35, 2):
								for lateral in [-2.5, 0.0, 2.5]:
									var sample := candidate \
										+ direction * float(distance) \
										+ lane_right * float(lateral)
									var required_depth := 1.55 \
										if lateral == 0.0 else 1.05
									if Gen.WATER_Y - Gen.height(sample.x, sample.z) \
											<= required_depth:
										direction_ok = false
										break
								if not direction_ok:
									break
							if direction_ok:
								lake = candidate
								swim_direction = direction
								lake_ok = true
								break
						if lake_ok:
							break
			if not lake_ok:
				push_error("Diagnostic swim clip could not find deep water")
				get_tree().quit(1)
				return
			print("DIAGNOSTIC_SWIM_LANE origin=(%.2f,%.2f) heading=(%.4f,%.4f)" % [
				lake.x, lake.z, swim_direction.x, swim_direction.z])
			p.global_position = Vector3(lake.x, Gen.WATER_Y - 0.10, lake.z)
			p.velocity = swim_direction * p.SWIM_SPEED
			p.state = p.S.SWIM
			p.in_water = true
			p.ti.dir = Vector2(swim_direction.x, swim_direction.z)
		p.reset_physics_interpolation()
		p._sync_weapon_presentation(true)
		# Settle the procedural pose without spending any recorded time in the
		# transition from the spawn stance. The clip then starts on a readable gait
		# phase while its two recorded seconds still contain live motion.
		var clip_anim := MonkeyRig.Anim.SPRINT \
			if subject == "sprint" else MonkeyRig.Anim.SWIM
		for i in range(18):
			p.rig.update_motion(1.0 / 60.0, clip_anim, p.velocity,
				subject == "sprint", Vector3.ZERO)
		if pov in ["play", "first"]:
			p.cam.set_view_mode(CameraRig.ViewMode.FIRST_PERSON \
				if pov == "first" else CameraRig.ViewMode.SHOULDER)
			p.cam.snap_to_target()
			p.cam._cam.current = true
		else:
			cam.fov = 50.0
			cam.near = 0.05
			_track_diagnostic_camera(cam, p, pov)
			cam.current = true
		# Give the camera cull mask and stowed-weapon presentation one unsaved
		# render to settle; otherwise the initial frame can briefly show a view arm.
		p.set_physics_process(false)
		await RenderingServer.frame_post_draw
		p.set_physics_process(true)
		# Hold raw frame images in memory and encode only after simulation ends.
		# Synchronous PNG compression between samples lets the engine catch up the
		# wall-clock encode time, turning a two-second review into tens of seconds.
		var clip_sim_start: float = p._now
		var base := out.trim_suffix(".png")
		var clip_images: Array[Image] = []
		for f in range(30):
			# Release during the dedicated close side-view transition fixture.
			if sprint_exit and f == 18:
				p.ti.sprint = false
				p.sprint_held = false
			# Frame zero is the configured initial pose. Later samples target their
			# exact 15 Hz simulation timestamp; render waits occasionally contribute
			# a physics tick, so a time target is more accurate than blindly waiting
			# four additional ticks every time.
			if f > 0:
				var target_sim_time := float(f) / 15.0
				var physics_guard := 0
				while p._now - clip_sim_start < target_sim_time - 1.0 / 120.0 \
						and physics_guard < 8:
					await get_tree().physics_frame
					physics_guard += 1
			if subject == "swim" and p.state != p.S.SWIM:
				push_error(("Diagnostic swim left deep water at frame %d " \
					+ "(depth %.2f, position %.2f/%.2f/%.2f, speed %.2f, " \
					+ "sim_time %.2f)") % [
						f, p._water_depth(), p.global_position.x,
						p.global_position.y, p.global_position.z,
						p.velocity.length(), p._now])
				get_tree().quit(1)
				return
			if sprint_exit and f == 29:
				var exit_twist := absf(p.rig.hip_l.rotation.y) \
					+ absf(p.rig.hip_l.rotation.z) + absf(p.rig.kn_l.rotation.y) \
					+ absf(p.rig.kn_l.rotation.z) + absf(p.rig.hip_r.rotation.y) \
					+ absf(p.rig.hip_r.rotation.z) + absf(p.rig.kn_r.rotation.y) \
					+ absf(p.rig.kn_r.rotation.z) + absf(p.rig.foot_l.rotation.y) \
					+ absf(p.rig.foot_l.rotation.z) + absf(p.rig.foot_r.rotation.y) \
					+ absf(p.rig.foot_r.rotation.z)
				if p._anim() != MonkeyRig.Anim.RUN or exit_twist > 0.04:
					push_error(("Diagnostic sprint exit retained quadruped legs " \
						+ "(anim %d, twist %.3f)") % [p._anim(), exit_twist])
					get_tree().quit(1)
					return
			if pov not in ["play", "first"]:
				_track_diagnostic_camera(cam, p, pov)
			await RenderingServer.frame_post_draw
			clip_images.append(get_viewport().get_texture().get_image())
		var simulated_seconds: float = p._now - clip_sim_start
		if simulated_seconds < 1.85 or simulated_seconds > 2.10:
			push_error("Diagnostic clip timing drifted (%.3f simulated seconds)" \
				% simulated_seconds)
			get_tree().quit(1)
			return
		p.set_physics_process(false)
		if p.cam:
			p.cam.set_process(false)
		for f in range(clip_images.size()):
			var save_error := clip_images[f].save_png(
				"%s_%02d.png" % [base, f])
			if save_error != OK:
				push_error("Diagnostic clip frame %d failed to save: %s" % [
					f, error_string(save_error)])
				get_tree().quit(1)
				return
		print("CLIP_SAVED %s frames=30 fps=15 seconds=2.00 sim=%.3f" % [
			base, simulated_seconds])
		get_tree().quit(0)
		return
	elif what in ["play-sprint", "play-strafe", "play-back"]:
		# reproduce the real third-person play view: sprint seen from the
		# player's own shoulder camera, forward / strafing / backpedaling
		var p := world.local_player
		p.test_mode = true
		p.ti.sprint = true
		p.ti.dir = Vector2(0, -1) if what == "play-sprint" \
			else (Vector2(1, 0) if what == "play-strafe" else Vector2(0, 1))
		var extra := int(args[3]) if args.size() > 3 else 0
		for i in range(70 + extra):
			await get_tree().physics_frame
		print("PLAY_DBG anim=%d yaw=%.2f want_yaw=%.2f vel=(%.1f,%.1f) stowed=%s all4=%s" % [
			p._anim(), p.rig.yaw_angle(),
			atan2(p.velocity.x, p.velocity.z) + PI,
			p.velocity.x, p.velocity.z,
			str(p.is_weapon_stowed()), str(p.is_all_fours())])
		use_player_camera = true
	elif what in ["run", "gallop", "gallop-back"]:
		var p := world.local_player
		p.test_mode = true
		p.ti.dir = Vector2(0, -1)
		if what in ["gallop", "gallop-back"]:
			p.galloping = true
			p.velocity = Vector3(0, 0, -13)
		else:
			p.velocity = Vector3(0, 0, -6)
		# optional 4th arg: extra frames, for capturing different stride phases
		var extra := int(args[3]) if args.size() > 3 else 0
		for i in range(40 + extra):
			await get_tree().physics_frame
		# capture a planted stride, not the airborne bound between them
		var ground_guard := 0
		while not p.is_on_floor() and ground_guard < 40:
			ground_guard += 1
			await get_tree().physics_frame
		cam.global_position = p.global_position + (
			Vector3(-3.0, 0.62, 0.9)
			if what == "gallop-back" else Vector3(3.0, 0.62, -0.9))
		cam.look_at(p.global_position + Vector3(0, 0.42, 0))
	elif what == "flip":
		var p := world.local_player
		p.test_mode = true
		var fg := Gen.height(0, 0)
		world.add_debug_vine(Vector3(0, fg + 16.0, 0), 10.0)
		p.global_position = Vector3(0, fg + 8.0, 6.0)
		p.velocity = Vector3(0, 0, -17)
		p.state = p.S.AIR
		p.ti.grab = true
		for i in range(30):
			await get_tree().physics_frame
		p.ti.grab = false  # fast release → mid-air tuck
		for i in range(14):
			await get_tree().physics_frame
		cam.global_position = p.global_position + Vector3(3.4, 0.7, 0.6)
		cam.look_at(p.global_position + Vector3(0, 0.55, 0))
	elif what == "swim":
		var p := world.local_player
		p.test_mode = true
		var lake := Vector3.ZERO
		var lake_ok := false
		for r in range(16, 150, 6):
			if lake_ok:
				break
			for a in range(0, 360, 15):
				var wx := cos(deg_to_rad(a)) * r
				var wz := sin(deg_to_rad(a)) * r
				if Gen.WATER_Y - Gen.height(wx, wz) > 1.4:
					lake = Vector3(wx, 0, wz)
					lake_ok = true
					break
		if lake_ok:
			p.global_position = Vector3(lake.x, Gen.WATER_Y + 2.0, lake.z)
			p.velocity = Vector3.ZERO
			p.state = p.S.AIR
			p.ti.dir = Vector2(0, -1)
			for i in range(75):
				await get_tree().physics_frame
			# front-quarter view: shows the lifted face and the surfaced back
			cam.global_position = p.global_position + Vector3(-2.1, 1.1, -2.5)
			cam.look_at(p.global_position + Vector3(0, 0.15, 0))
	elif what == "supply-hut":
		var hut_x := 0.0
		var hut_z := -6.0
		var hut_y := Gen.height(hut_x, hut_z) + 0.04
		var hut := SupplyHut.new()
		hut.configure({
			"id": "diagnostic-hut",
			"pos": Vector3(hut_x, hut_y, hut_z),
			"yaw": 0.0,
			"ammo_kind": Gen.SUPPLY_AMMO_SHOTGUN,
			"ammo_amount": 8,
			"bandages": 2,
			"biome": Gen.Biome.RAINFOREST,
		})
		world.add_child(hut)
		hut.open_chest(true)
		world.local_player.visible = false
		if hud:
			hud.visible = false
		cam.fov = 56.0
		cam.global_position = Vector3(hut_x + 5.8, hut_y + 3.15,
			hut_z - 6.5)
		cam.look_at(Vector3(hut_x, hut_y + 1.35, hut_z))
	elif what.begins_with("biome-"):
		var requested := what.trim_prefix("biome-")
		var requested_biome := Gen.Biome.RAINFOREST
		match requested:
			"bamboo":
				requested_biome = Gen.Biome.BAMBOO_GROVE
			"wetland":
				requested_biome = Gen.Biome.WETLAND
			"highland":
				requested_biome = Gen.Biome.HIGHLAND
		var vista := Vector3.ZERO
		var found := false
		var is_biome_core := func(x: float, z: float) -> bool:
			for ox in [-24.0, 0.0, 24.0]:
				for oz in [-24.0, 0.0, 24.0]:
					if Gen.biome_at(x + ox, z + oz) != requested_biome:
						return false
			return true
		# Expanding chunk rings choose the nearest reproducible representative.
		for ring in range(3, 34):
			if found:
				break
			for cx in range(-ring, ring + 1):
				if found:
					break
				for cz in [-ring, ring]:
					var x := (float(cx) + 0.5) * Gen.CHUNK
					var z := (float(cz) + 0.5) * Gen.CHUNK
					var h := Gen.height(x, z)
					var appropriate_surface := h < Gen.WATER_Y - 1.3 \
						if requested_biome == Gen.Biome.WETLAND \
						else h > Gen.WATER_Y + 1.0
					if Gen.biome_at(x, z) == requested_biome \
							and is_biome_core.call(x, z) \
							and appropriate_surface:
						vista = Vector3(x, h, z)
						found = true
						break
			if found:
				break
			for cz in range(-ring + 1, ring):
				if found:
					break
				for cx in [-ring, ring]:
					var x := (float(cx) + 0.5) * Gen.CHUNK
					var z := (float(cz) + 0.5) * Gen.CHUNK
					var h := Gen.height(x, z)
					var appropriate_surface := h < Gen.WATER_Y - 1.3 \
						if requested_biome == Gen.Biome.WETLAND \
						else h > Gen.WATER_Y + 1.0
					if Gen.biome_at(x, z) == requested_biome \
							and is_biome_core.call(x, z) \
							and appropriate_surface:
						vista = Vector3(x, h, z)
						found = true
						break
		if not found:
			push_error("Could not find biome vista for " + requested)
			get_tree().quit(1)
			return
		var p := world.local_player
		p.test_mode = true
		p.set_physics_process(false)
		p.global_position = Vector3(vista.x,
			Gen.WATER_Y + 0.4 if requested_biome == Gen.Biome.WETLAND \
			else vista.y + 0.05, vista.z)
		p.reset_physics_interpolation()
		if hud:
			hud.visible = false
		for i in range(120):
			await get_tree().process_frame
		var focus_y := Gen.WATER_Y + 7.0 \
			if requested_biome == Gen.Biome.WETLAND else vista.y + 9.0
		cam.fov = 61.0
		cam.far = 1800.0
		# Rainforest crowns can rise ~36 m over their local ground. Derive the
		# overlook from both focus and camera-site terrain so the lens never starts
		# inside a tall canopy as tree layouts change.
		var camera_x := vista.x + 56.0
		var camera_z := vista.z + 56.0
		var camera_y := maxf(focus_y + 38.0,
			Gen.height(camera_x, camera_z) + 39.0)
		cam.global_position = Vector3(camera_x, camera_y, camera_z)
		cam.look_at(Vector3(vista.x, focus_y, vista.z))
		print("BIOME_VISTA %s position=(%.1f,%.1f) horizon=%.0fm" % [
			Gen.biome_name(requested_biome), vista.x, vista.z,
			Gen.HORIZON_DISTANCE])
	else:
		var g0 := Gen.height(0, 0)
		var m1 := world.spawn_puppet(7, "Mango")
		m1.global_position = Vector3(2.5, g0, -2.0)
		var m2 := world.spawn_puppet(8, "Zuzu")
		m2.global_position = Vector3(-3.0, Gen.height(-3, 1), 1.0)
		cam.global_position = sp + Vector3(19, 13, 19)
		cam.look_at(Vector3(0, g0 + 6.0, 0))
		if seasonal_diagnostic:
			if hud:
				hud.visible = false
			cam.fov = 62.0
			if what == "winter-scarf":
				cam.fov = 52.0
				cam.global_position = world.local_player.global_position \
					+ Vector3(1.55, 1.15, -2.20)
				cam.look_at(world.local_player.global_position + Vector3.UP * 0.82)
			else:
				cam.global_position = sp + Vector3(5.8, 2.8, 5.8)
				cam.look_at(Vector3(0, g0 + 1.15, 0))

	if use_player_camera:
		world.local_player.cam._cam.current = true
	else:
		cam.current = true
	for i in range(8):
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("RENDER_STATS objects=%d primitives=%d draw_calls=%d" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
	])
	print("SHOT_SAVED " + out)
	get_tree().quit(0)


func _nettest_host() -> void:
	mode = "nettest-host"
	var err := Net.host("HostBot", 4242)
	if err != OK:
		print("NETTEST-HOST FAIL create_server err=%d" % err)
		get_tree().quit(1)
		return
	if not Net.set_authoritative_cycle_hour(NETTEST_CYCLE_HOUR):
		print("NETTEST-HOST FAIL could not set authoritative cycle phase")
		get_tree().quit(1)
		return
	_enter_world("HostBot", 4242, 1)
	if _cycle_hour_distance(world.time_of_day_hours, NETTEST_CYCLE_HOUR) \
			> NETTEST_CYCLE_TOLERANCE_HOURS:
		print("NETTEST-HOST FAIL world ignored authoritative cycle phase")
		get_tree().quit(1)
		return
	var p := world.local_player
	p.test_mode = true
	p.ti.dir = Vector2(0, -1)
	print("NETTEST-HOST listening on %d" % Net.PORT)
	var t := 0.0
	var frames := 0
	var saw_remote_shotgun := false
	var saw_remote_smg := false
	var saw_remote_sniper := false
	var saw_remote_sniper_bolt := false
	var saw_remote_melee := false
	var fired_host_sniper := false
	var saw_host_sniper_bolt := false
	var remote_sniper_packet: Array[bool] = [false, false]
	var on_sniper_packet := func(shooter_id: int, _origin: Vector3,
			velocity: Vector3, damage: float, headshot_rule: bool,
			play_fx: bool, weapon_kind: int) -> void:
		if shooter_id == p.peer_id or weapon_kind != Net.WEAPON_SNIPER:
			return
		remote_sniper_packet[0] = true
		remote_sniper_packet[1] = absf(damage - SniperRifle.DAMAGE) < 0.01 \
			and absf(velocity.length() - SniperRifle.MUZZLE_SPEED) < 0.05 \
			and headshot_rule and play_fx
	Net.bullet_fired.connect(on_sniper_packet)
	while t < 30.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		frames += 1
		if frames % 90 == 0:
			p.ti.jump_just = true
		if p.sniper and p.sniper.is_bolt_cycling() \
				and is_instance_valid(p.sniper._bolt_group):
			saw_host_sniper_bolt = saw_host_sniper_bolt \
				or absf(p.sniper._bolt_group.position.z \
				- p.sniper._bolt_base_z) > 0.005 \
				or absf(p.sniper._bolt_group.rotation.z) > 0.02
		var pups := world.puppets.values()
		if pups.size() > 0:
			var pu: Puppet = pups[0]
			# A roster entry can exist before the joining world has connected its
			# bullet listener. Received gameplay states prove that setup is complete.
			if not fired_host_sniper and frames > 15 and pu.state_count > 5:
				p.equip_weapon(4)
				p.sniper.tick(2.0)
				fired_host_sniper = p.sniper.try_fire(
					p.hand_pos() + Vector3.UP * 2.0, Vector3.UP)
			saw_remote_shotgun = saw_remote_shotgun or pu.shotgun.visible
			saw_remote_smg = saw_remote_smg or pu.smg.visible
			saw_remote_sniper = saw_remote_sniper or pu.sniper.visible
			if pu.sniper.is_bolt_cycling() \
					and is_instance_valid(pu.sniper._bolt_group):
				saw_remote_sniper_bolt = saw_remote_sniper_bolt \
					or absf(pu.sniper._bolt_group.position.z \
					- pu.sniper._bolt_base_z) > 0.005 \
					or absf(pu.sniper._bolt_group.rotation.z) > 0.02
			saw_remote_melee = saw_remote_melee or pu._state_melee_mode \
				or pu._melee_remaining > 0.0
			if pu.state_count > 30 and pu.first_pos != Vector3.INF \
					and pu._target.distance_to(pu.first_pos) > 2.0 \
					and saw_remote_shotgun and saw_remote_smg \
					and saw_remote_sniper and saw_remote_sniper_bolt \
					and remote_sniper_packet[0] and remote_sniper_packet[1] \
					and fired_host_sniper and saw_host_sniper_bolt \
					and saw_remote_melee:
				print("NETTEST-HOST PASS states=%d moved=%.1f shotgun=true smg=true sniper_packet=true sniper_visual=true sniper_bolt=true host_sniper=true melee=true" % [
					pu.state_count, pu._target.distance_to(pu.first_pos)])
				# linger so the client can finish its own count before we vanish
				var t2 := 0.0
				while t2 < 15.0 and world.puppets.size() > 0:
					await get_tree().process_frame
					t2 += get_process_delta_time()
				if Net.bullet_fired.is_connected(on_sniper_packet):
					Net.bullet_fired.disconnect(on_sniper_packet)
				get_tree().quit(0)
				return
	if Net.bullet_fired.is_connected(on_sniper_packet):
		Net.bullet_fired.disconnect(on_sniper_packet)
	print("NETTEST-HOST FAIL timeout (peers=%d shotgun=%s smg=%s sniper=%s packet=%s payload=%s remote_bolt=%s host_shot=%s host_bolt=%s melee=%s)" % [
		world.puppets.size(), saw_remote_shotgun, saw_remote_smg,
		saw_remote_sniper, remote_sniper_packet[0], remote_sniper_packet[1],
		saw_remote_sniper_bolt, fired_host_sniper, saw_host_sniper_bolt,
		saw_remote_melee])
	get_tree().quit(1)


func _nettest_join(ip: String) -> void:
	mode = "nettest-join"
	var err := Net.join(ip, "JoinBot")
	if err != OK:
		print("NETTEST-JOIN FAIL create_client err=%d" % err)
		get_tree().quit(1)
		return
	var ok := await _await_or_timeout(Net.world_ready, 12.0)
	if not ok:
		print("NETTEST-JOIN FAIL no world_ready")
		get_tree().quit(1)
		return
	var received_cycle_hour := Net.authoritative_cycle_hour()
	var cycle_synced := _cycle_hour_distance(
		received_cycle_hour, NETTEST_CYCLE_HOUR) \
		<= NETTEST_CYCLE_TOLERANCE_HOURS
	_enter_world("JoinBot", Net.world_seed, 1)
	cycle_synced = cycle_synced and _cycle_hour_distance(
		world.time_of_day_hours, Net.authoritative_cycle_hour()) \
		<= NETTEST_CYCLE_TOLERANCE_HOURS
	var p := world.local_player
	p.test_mode = true
	p.ti.dir = Vector2(0, -1)
	p.ti.sprint = true
	var t := 0.0
	var frames := 0
	var fired_network_shotgun := false
	var fired_network_smg := false
	var fired_network_sniper := false
	var sniper_fire_t := -1.0
	var saw_local_sniper_bolt := false
	var saw_remote_sniper := false
	var saw_remote_sniper_bolt := false
	var sent_network_melee := false
	var remote_sniper_packet: Array[bool] = [false, false]
	var on_sniper_packet := func(shooter_id: int, _origin: Vector3,
			velocity: Vector3, damage: float, headshot_rule: bool,
			play_fx: bool, weapon_kind: int) -> void:
		if shooter_id == p.peer_id or weapon_kind != Net.WEAPON_SNIPER:
			return
		remote_sniper_packet[0] = true
		remote_sniper_packet[1] = absf(damage - SniperRifle.DAMAGE) < 0.01 \
			and absf(velocity.length() - SniperRifle.MUZZLE_SPEED) < 0.05 \
			and headshot_rule and play_fx
	Net.bullet_fired.connect(on_sniper_packet)
	while t < 25.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		frames += 1
		if frames % 75 == 0:
			p.ti.jump_just = true
		if p.sniper and p.sniper.is_bolt_cycling() \
				and is_instance_valid(p.sniper._bolt_group):
			saw_local_sniper_bolt = saw_local_sniper_bolt \
				or absf(p.sniper._bolt_group.position.z \
				- p.sniper._bolt_base_z) > 0.005 \
				or absf(p.sniper._bolt_group.rotation.z) > 0.02
		var pups := world.puppets.values()
		if pups.size() > 0:
			var remote: Puppet = pups[0]
			saw_remote_sniper = saw_remote_sniper or remote.sniper.visible
			if remote.sniper.is_bolt_cycling() \
					and is_instance_valid(remote.sniper._bolt_group):
				saw_remote_sniper_bolt = saw_remote_sniper_bolt \
					or absf(remote.sniper._bolt_group.position.z \
					- remote.sniper._bolt_base_z) > 0.005 \
					or absf(remote.sniper._bolt_group.rotation.z) > 0.02
		if not fired_network_shotgun and pups.size() > 0 and frames > 15:
			p.equip_weapon(2)
			p.shotgun.tick(1.0)
			fired_network_shotgun = p.shotgun.try_fire(
				p.hand_pos() + Vector3.UP * 2.0, Vector3.UP)
		if fired_network_shotgun and not fired_network_smg \
				and pups.size() > 0 and frames > 25:
			p.equip_weapon(3)
			p.smg.tick(1.0)
			fired_network_smg = p.smg.try_fire(
				p.hand_pos() + Vector3.UP * 2.0, Vector3.UP)
		if fired_network_smg and not fired_network_sniper \
				and pups.size() > 0 and frames > 35:
			p.equip_weapon(4)
			p.sniper.tick(2.0)
			fired_network_sniper = p.sniper.try_fire(
				p.hand_pos() + Vector3.UP * 2.0, Vector3.UP)
			if fired_network_sniper:
				sniper_fire_t = t
		if fired_network_sniper and not sent_network_melee \
				and pups.size() > 0 and t - sniper_fire_t > 0.55:
			p.set_melee_mode(true)
			Net.melee_attack(p.global_position + Vector3.UP * 0.78,
				Vector3.FORWARD, 0)
			sent_network_melee = true
		if sent_network_melee and frames > 60:
			p.set_melee_mode(false)
		if pups.size() > 0 and pups[0].state_count > 30 \
				and fired_network_smg and fired_network_sniper \
				and saw_local_sniper_bolt and saw_remote_sniper \
				and saw_remote_sniper_bolt and remote_sniper_packet[0] \
				and remote_sniper_packet[1] and sent_network_melee \
				and cycle_synced:
			print("NETTEST-JOIN PASS states=%d shotgun=%s smg=%s sniper=true local_bolt=true remote_packet=true remote_sniper=true remote_bolt=true melee=%s cycle_synced=true phase=%.3f" % [
				pups[0].state_count, fired_network_shotgun, fired_network_smg,
				sent_network_melee, received_cycle_hour])
			# keep driving briefly so the host reaches its own count too
			var t2 := 0.0
			while t2 < 3.0:
				await get_tree().process_frame
				t2 += get_process_delta_time()
			if Net.bullet_fired.is_connected(on_sniper_packet):
				Net.bullet_fired.disconnect(on_sniper_packet)
			get_tree().quit(0)
			return
	if Net.bullet_fired.is_connected(on_sniper_packet):
		Net.bullet_fired.disconnect(on_sniper_packet)
	print("NETTEST-JOIN FAIL timeout (peers=%d shotgun=%s smg=%s sniper=%s local_bolt=%s remote_sniper=%s packet=%s payload=%s remote_bolt=%s melee=%s cycle_synced=%s phase=%.3f)" % [
		world.puppets.size(), fired_network_shotgun, fired_network_smg,
		fired_network_sniper, saw_local_sniper_bolt, saw_remote_sniper,
		remote_sniper_packet[0], remote_sniper_packet[1],
		saw_remote_sniper_bolt, sent_network_melee, cycle_synced,
		received_cycle_hour])
	get_tree().quit(1)


func _cycle_hour_distance(a: float, b: float) -> float:
	return absf(wrapf(a - b + 12.0, 0.0, 24.0) - 12.0)
