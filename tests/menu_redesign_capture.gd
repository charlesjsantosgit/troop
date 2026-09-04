extends SceneTree
## Native screenshots and responsive layout checks using the actual menu.
var main: Node
var failed := false
var checks := 0

func _initialize() -> void:
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", "TROOP-menu-capture-" + Crypto.new().generate_random_bytes(6).hex_encode())
	create_timer(70).timeout.connect(func(): push_error("MENU_CAPTURE deadline"); quit(2))
	call_deferred("_run")

func _run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for dimensions in [Vector2i(1600,900), Vector2i(1280,720), Vector2i(960,540)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for frame in range(8): await process_frame
		main._select_menu_page("Play")
		await _capture("play-%dx%d" % [dimensions.x, dimensions.y])
		_check(Rect2(Vector2.ZERO,Vector2(dimensions)).encloses(main._menu_frame.get_global_rect()), "main frame fits " + str(dimensions))
		main._menu_nav_buttons["Your monkey"].pressed.emit()
		for frame in range(4): await process_frame
		_check(main.name_edit.is_visible_in_tree(), "profile remains reachable " + str(dimensions))
		_check(main.name_edit.get_global_rect().size.x >= 150, "profile has useful input width " + str(dimensions))
		var quit_button: Button = main._menu_nav.get_node("QuitGame")
		main.name_edit.grab_focus()
		for frame in range(4): await process_frame
		quit_button.grab_focus()
		for frame in range(4): await process_frame
		_check(main._menu_nav.get_parent().get_global_rect().encloses(quit_button.get_global_rect()),
			"keyboard scrolls Quit into view " + str(dimensions))
	root.size = Vector2i(1600,900)
	root.content_scale_size = Vector2i(1600,900)
	for page in ["Explore & practice", "How to play", "Your monkey"]:
		main._menu_nav_buttons[page].pressed.emit()
		await _capture(page.to_lower().replace(" ","-").replace("&", "and"))
	_check(main.world == null and not root.get_node("Net").active, "navigation never creates a world or connection")
	_check(main._menu_binding(&"society") == "B" and main._menu_binding(&"grab") == "E", "help uses actual journal and interaction bindings")
	main._open_title_settings()
	for frame in range(4): await process_frame
	_check(is_instance_valid(main._title_settings) and main._title_settings._settings_view.visible, "title Settings opens real settings")
	await _capture("settings-graphics")
	main._title_settings._show_settings_tab(PauseMenu.TAB_AUDIO)
	await _capture("settings-audio")
	main._title_settings._show_settings_tab(PauseMenu.TAB_CONTROLS)
	await _capture("settings-controls")
	var escape := InputEventKey.new()
	escape.physical_keycode = KEY_ESCAPE
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	main._title_settings._input(escape)
	for frame in range(4): await process_frame
	_check(not is_instance_valid(main._title_settings) and main.menu.visible, "Escape returns from title settings directly to title")
	_check(not paused and main.world == null, "title settings never pauses or creates gameplay")
	print("MENU_CAPTURE %d checks %s" % [checks, "FAIL" if failed else "PASS"])
	main.queue_free()
	for frame in range(4): await process_frame
	quit(1 if failed else 0)

func _capture(stem: String) -> void:
	for frame in range(8): await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://artifacts/menu-redesign/" + stem + ".png")

func _check(ok: bool, message: String) -> void:
	checks += 1
	failed = failed or not ok
	print("MENU_CAPTURE ", "PASS " if ok else "FAIL ", message)
