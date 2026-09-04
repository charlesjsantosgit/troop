extends SceneTree
## Real menu layout, keyboard return and inventory details at supported window sizes.
var failed := false
var checks := 0
var resumed := 0
var main: Node

func _initialize() -> void:
	if not str(ProjectSettings.get_setting("application/config/custom_user_dir_name", "")).begins_with("TROOP-settings-capture-"):
		ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
		ProjectSettings.set_setting("application/config/custom_user_dir_name", "TROOP-settings-capture-" + Crypto.new().generate_random_bytes(6).hex_encode())
	create_timer(120).timeout.connect(func(): push_error("SETTINGS_MENU deadline"); quit(2))
	call_deferred("_run")

func _run() -> void:
	if OS.get_cmdline_user_args().has("world"):
		main = load("res://scenes/main.tscn").instantiate()
		root.add_child(main)
		main._start_frontier("Menu verification", false)
		main.frontier_controller.simulation_enabled = false
		main.frontier_controller.persistence_enabled = false
		main.frontier_controller.save_path = ""
		main.world.set_time_of_day_override(10.0)
		var player: Node3D = main.world.local_player
		player.test_mode = true
		player.set_physics_process(false)
		var nana: Node3D = main.frontier_controller.earth_settlement.citizens.nana
		var camera := Camera3D.new()
		main.world.add_child(camera)
		camera.global_position = nana.global_position + Vector3(-18, 7, -21)
		camera.look_at(nana.global_position + Vector3(0, 1, 0))
		camera.fov = 62
		camera.current = true
		for frame in range(90): await process_frame
	var settings = load("res://scripts/pause_menu.gd").new()
	var menu_layer := CanvasLayer.new()
	menu_layer.layer = 120
	root.add_child(menu_layer)
	menu_layer.add_child(settings)
	settings.resume_requested.connect(func(): resumed += 1)
	settings.open_settings_from_title()
	for dimensions in [Vector2i(1600,900), Vector2i(1280,720), Vector2i(960,540)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for tab in [PauseMenu.TAB_GRAPHICS, PauseMenu.TAB_AUDIO, PauseMenu.TAB_CONTROLS]:
			settings._show_settings_tab(tab)
			await _settle()
			_check(_fits(settings._panel), "settings panel fits %s tab %d" % [dimensions, tab])
			var page: Control = settings._graphics_view if tab == PauseMenu.TAB_GRAPHICS else settings._audio_view if tab == PauseMenu.TAB_AUDIO else settings._controls_view
			_check(settings._panel.get_global_rect().encloses(page.get_global_rect()), "settings page stays inside panel %s tab %d" % [dimensions, tab])
			await _capture("settings-%d-%dx%d" % [tab, dimensions.x, dimensions.y])
		settings._binding_buttons["fullscreen"].grab_focus()
		await _settle()
		var scroll: ScrollContainer = settings._controls_view.get_child(1)
		_check(scroll.get_v_scroll_bar().value > 0, "keyboard reaches bottom bindings %s" % dimensions)
	_check(settings._binding_buttons.size() == 26, "all 26 key and mouse bindings remain available")
	_check(settings._controls_tab.get_theme_color("font_focus_color") == settings.COLOR_INK, "selected keyboard tab has readable focused text")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	settings._input(escape)
	_check(resumed == 1 and settings._current_view == PauseMenu.VIEW_SETTINGS, "Escape from title settings requests title return directly")
	settings._settings_back.pressed.emit()
	_check(resumed == 2, "visible Back button requests the same title return")
	settings._from_title = false
	settings._show_home()
	await _settle()
	_check(settings._panel.size.x <= 441 and _fits(settings._panel), "in-game pause is a compact panel with world around it")
	await _capture("pause-compact-960x540")
	settings.queue_free()
	await process_frame
	var inventory = load("res://scripts/lunar_inventory.gd").new()
	inventory.equip_backpack(LunarInventory.Backpack.SPACE)
	inventory.add_item(LunarInventory.ITEM_BANANA, 70)
	inventory.add_item(LunarInventory.ITEM_MOON_CHEESE, 4, 16)
	var backpack = load("res://scripts/backpack_inventory_ui.gd").new()
	menu_layer.add_child(backpack)
	backpack.bind_inventory(inventory)
	backpack.open_inventory()
	backpack._buttons[0].pressed.emit()
	_check(backpack._buttons[0].text.contains("Banana") and backpack._detail_body.text.contains("64") and backpack._capacity.text.contains("3 of 18"), "inventory shows item names, selected stack details and real capacity")
	for dimensions in [Vector2i(1280,720), Vector2i(960,540)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		await _settle()
		_check(_fits(backpack._panel) and backpack._panel.size.x <= 581, "backpack fits %s" % dimensions)
		await _capture("backpack-%dx%d" % [dimensions.x, dimensions.y])
	backpack.queue_free()
	await process_frame
	var colony = load("res://scripts/moon_colony_ui.gd").new()
	menu_layer.add_child(colony)
	colony.refresh(load("res://scripts/moon_colony.gd").new().snapshot(20))
	colony.present(false)
	_check(colony._tabs.get_tab_count() == 4 and colony._tabs.get_tab_title(2) == "Contracts", "lunar activities have four focused pages")
	_check(colony._sell_fresh.disabled and colony._buy_buttons[0].disabled and colony._market_notice.text.contains("Visit Muenster"), "remote journal explains and enforces counter-only trading")
	for dimensions in [Vector2i(1280,720), Vector2i(960,540)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for tab in range(4):
			colony._tabs.current_tab = tab
			await _settle()
			_check(_fits(colony._panel) and colony._panel.size.x <= 761, "colony fits %s tab %d" % [dimensions, tab])
			await _capture("colony-%d-%dx%d" % [tab, dimensions.x, dimensions.y])
	colony.queue_free()
	await process_frame
	var trade = load("res://scripts/trade_ui.gd").new()
	menu_layer.add_child(trade)
	trade.visible = true
	trade._refresh()
	await _settle()
	_check(_fits(trade._panel) and trade._panel.size.x <= 561 and trade._offer_buttons.size() == 6, "provisioner offers remain available in a contained menu")
	await _capture("provisioner-960x540")
	trade.queue_free()
	await _settle()
	if is_instance_valid(main):
		main._return_to_main_menu()
		main.queue_free()
	menu_layer.queue_free()
	await _settle()
	print("SETTINGS_MENU %d checks %s" % [checks, "FAIL" if failed else "PASS"])
	quit(1 if failed else 0)

func _fits(control: Control) -> bool:
	var ok := Rect2(Vector2.ZERO, Vector2(root.size)).grow(1).encloses(control.get_global_rect())
	if not ok: print("BOUNDS ", root.size, " ", control.get_global_rect(), " minimum ", control.get_combined_minimum_size())
	return ok

func _settle() -> void:
	for frame in range(8): await process_frame

func _capture(stem: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://artifacts/menu-redesign/" + stem + ".png")

func _check(ok: bool, message: String) -> void:
	checks += 1
	failed = failed or not ok
	print("SETTINGS_MENU ", "PASS " if ok else "FAIL ", message)
