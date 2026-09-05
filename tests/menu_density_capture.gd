extends SceneTree
## Real society layout and authoritative UI refresh checks, with isolated saves.
var main: Node
var checks := 0
var failures: Array[String] = []
const OUTPUT := "res://artifacts/menu-density/"

func _initialize() -> void:
	if not str(ProjectSettings.get_setting("application/config/custom_user_dir_name", "")).begins_with("TROOP-density-capture-"):
		ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
		ProjectSettings.set_setting("application/config/custom_user_dir_name", "TROOP-density-capture-" + Crypto.new().generate_random_bytes(6).hex_encode())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://"))
	create_timer(120).timeout.connect(func(): push_error("MENU_DENSITY deadline"); quit(2))
	call_deferred("_run")

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main._start_frontier("Menu density verification", false)
	var controller: Node = main.frontier_controller
	controller.simulation_enabled = false
	controller.persistence_enabled = false
	controller.save_path = ""
	controller.set_process(false)
	main.world.set_time_of_day_override(10.0)
	var player: Node3D = main.world.local_player
	player.test_mode = true
	player.set_physics_process(false)
	var nana: Node3D = controller.earth_settlement.citizens.nana
	player.global_position = controller.earth_site.surface_point(nana.global_position.x + 1.7, nana.global_position.z)
	var camera := Camera3D.new()
	main.world.add_child(camera)
	camera.global_position = nana.global_position + Vector3(0.9, 2.2, -7)
	camera.look_at(nana.global_position + Vector3(0.85, 1.0, 0))
	camera.fov = 58
	camera.current = true
	var ui: Control = controller.ui
	ui.set_process(false)
	for dimensions in [Vector2i(1280,720), Vector2i(960,540)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		ui.open(nana.interaction())
		await _settle()
		var buy := _find_action(ui, "buy")
		_check(buy != null, "Nana has a useful Buy action %s" % dimensions)
		_check(ui._panel.size.is_equal_approx(Vector2(mini(920, dimensions.x - 80), mini(640, dimensions.y - 80))),
			"merchant panel retains useful area %s" % dimensions)
		if buy:
			_check(ui._panel.get_global_rect().encloses(buy.get_global_rect()) and ui._trade_footer.get_global_rect().encloses(buy.get_global_rect()),
				"trade action footer stays visible without scrolling %s" % dimensions)
			print("MENU_DENSITY bounds screen=%s footer=%s buy=%s" % [dimensions, ui._trade_footer.get_global_rect(), buy.get_global_rect()])
		_check(ui._trade_scrolls.size() == 2 and ui._trade_scrolls.all(func(scroll): return scroll.is_visible_in_tree() and ui._panel.get_global_rect().encloses(scroll.get_global_rect()) and scroll.size.y >= 90),
			"merchant stock and backpack are visible together %s" % dimensions)
		_check(ui._trade_tiles.has("market:banana") and ui._trade_tiles.has("backpack:banana") and ui._trade_tiles["backpack:banana"].count == int(controller.simulation.state.inventories.player_earth.banana),
			"inventory tiles show actual independent stocks %s" % dimensions)
		var tile = ui._trade_tiles["market:banana"]
		_check(is_equal_approx(tile.get_theme_stylebox("normal").bg_color.a, 1.0), "inventory tile is opaque %s" % dimensions)
		_check(ui._trade_tiles.values().all(func(item): return item.get_global_rect().encloses(item._name_label.get_global_rect()) and item.get_global_rect().encloses(item._count_label.get_global_rect())),
			"tile names and counts fit even with two-line item names %s" % dimensions)
		await _capture("nana-%dx%d" % [dimensions.x, dimensions.y])
	root.size = Vector2i(1280,720)
	root.content_scale_size = Vector2i(1280,720)
	ui.open(nana.interaction())
	await _settle()
	var buy := _find_action(ui, "buy")
	var initial_cash: int = int(controller.simulation.state.accounts.player)
	buy.grab_focus()
	var original_id := buy.get_instance_id()
	controller.simulation.state.accounts.player = 0
	controller.last_message = "Authoritative balance received."
	ui.refresh_from_state()
	_check(buy.disabled and ui._balance.text.contains("0 credits") and ui._notice.text == controller.last_message,
		"authority reply changes balance, availability and notice in the same call")
	_check(buy.get_instance_id() == original_id and root.gui_get_focus_owner() == buy,
		"live market updates preserve the focused control")
	controller.simulation.state.accounts.player = initial_cash
	ui.refresh_from_state()
	_check(not buy.disabled, "Buy becomes available immediately when authority replenishes funds")
	ui._trade_scrolls[0].scroll_vertical = 50
	var before_scroll: int = ui._trade_scrolls[0].scroll_vertical
	controller.simulation.state.citizens.nana.employer = "player"
	ui.refresh_from_state()
	await _settle()
	var refreshed_buy := _find_action(ui, "buy")
	_check(refreshed_buy != null and root.gui_get_focus_owner() == refreshed_buy,
		"structural refresh restores the matching action focus")
	_check(ui._trade_scrolls[0].scroll_vertical == before_scroll, "structural refresh preserves scroll position")
	ui._trade_tiles["backpack:banana"].pressed.emit()
	_check(ui._trade_selected_side == "backpack" and ui._trade_sell.get_meta("frontier_payload").item == "banana",
		"selecting a backpack tile binds the actual Sell action")
	var before_selection_cash: int = int(controller.simulation.state.accounts.player)
	var before_selection_bag: int = int(controller.simulation.state.inventories.player_earth.banana)
	ui._trade_search.text = "banana"
	ui._trade_search.text_changed.emit("banana")
	_check(ui._trade_tiles["market:banana"].visible and not ui._trade_tiles["market:tomato"].visible,
		"typing filters visible tiles immediately without rebuilding the footer")
	_check(int(controller.simulation.state.accounts.player) == before_selection_cash and int(controller.simulation.state.inventories.player_earth.banana) == before_selection_bag,
		"selecting and filtering tiles never transacts or predicts inventory")
	ui._trade_search.text = ""
	ui._trade_search.text_changed.emit("")
	ui._trade_tiles["market:banana"].pressed.emit()
	ui._quantity = 1
	ui._refresh_merchant()
	var before_buy_stock: int = int(controller.simulation.state.inventories.earth_market.banana)
	var buy_price: int = controller.simulation.quote("earth_market", "banana", 1, true)
	ui._trade_buy.pressed.emit()
	await _settle()
	_check(int(controller.simulation.state.inventories.player_earth.banana) == before_selection_bag + 1 and int(controller.simulation.state.inventories.earth_market.banana) == before_buy_stock - 1 and int(controller.simulation.state.accounts.player) == before_selection_cash - buy_price,
		"footer Buy transfers finite stock and exact quoted credits")
	_check(ui._trade_tiles["backpack:banana"].count == before_selection_bag + 1 and ui._trade_tiles["market:banana"].count == before_buy_stock - 1,
		"completed purchase updates both visible inventories")
	ui._trade_tiles["backpack:banana"].pressed.emit()
	var sell_price: int = controller.simulation.quote("earth_market", "banana", 1, false)
	ui._trade_sell.pressed.emit()
	await _settle()
	_check(int(controller.simulation.state.inventories.player_earth.banana) == before_selection_bag and int(controller.simulation.state.inventories.earth_market.banana) == before_buy_stock and int(controller.simulation.state.accounts.player) == before_selection_cash - buy_price + sell_price,
		"footer Sell returns one carried item for its authoritative quote")
	controller.simulation.state.inventories.player_earth.banana = 1
	ui.refresh_from_state()
	ui._trade_tiles["backpack:banana"].pressed.emit()
	ui._trade_sell.pressed.emit()
	await _settle()
	_check(not ui._trade_tiles.has("backpack:banana") and ui._trade_selected_item == "banana" and ui._trade_selected_side == "market",
		"selling the last carried item keeps the matching merchant tile selected")
	ui.open({})
	await _settle()
	_check(ui._panel.size.is_equal_approx(Vector2(760,600)), "journal retains its existing panel area")
	await _capture("journal-1280x720")
	ui.close()
	var backpack: Control = main.expedition_manager.inventory_ui
	for dimensions in [Vector2i(1280,720), Vector2i(960,540)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		var key := InputEventKey.new()
		key.physical_keycode = KEY_I
		key.keycode = KEY_I
		key.pressed = true
		Input.parse_input_event(key)
		key = key.duplicate()
		key.pressed = false
		Input.parse_input_event(key)
		await _settle()
		_check(backpack.visible and backpack.controller == controller, "I opens the real backpack with society stock %s" % dimensions)
		_check(backpack._rows == controller.backpack_items() and int(backpack._meter.value) == controller.backpack_used(),
			"backpack shows the same authoritative items and capacity as trading %s" % dimensions)
		_check(backpack._panel.get_global_rect().encloses(backpack._grid.get_global_rect()) and backpack._panel.size.x < dimensions.x and backpack._panel.size.y < dimensions.y,
			"backpack tiles fit within a panel with the world visible %s" % dimensions)
		await _capture("backpack-%dx%d" % [dimensions.x, dimensions.y])
		backpack.close_inventory()
		await _settle()
	main._return_to_main_menu()
	main.queue_free()
	await _settle()
	var result := {"checks":checks, "failures":failures, "passed":failures.is_empty(), "renderer":DisplayServer.get_name()}
	var output := FileAccess.open(OUTPUT + "result-" + DisplayServer.get_name() + ".json", FileAccess.WRITE)
	output.store_string(JSON.stringify(result, "  "))
	print("MENU_DENSITY %d checks %s" % [checks, "PASS" if failures.is_empty() else "FAIL"])
	quit(0 if failures.is_empty() else 1)

func _find_action(parent: Node, kind: String) -> Button:
	if parent is Button and parent.get_meta("frontier_action", "") == kind:
		return parent
	for child in parent.get_children():
		var button := _find_action(child, kind)
		if button: return button
	return null

func _settle() -> void:
	for frame in range(12):
		# Simulation is frozen for stock assertions; still perform the real modal
		# overlay visibility pass so stale initial labels do not cover the UI.
		if is_instance_valid(main) and is_instance_valid(main.get("frontier_controller")):
			main.frontier_controller._refresh_overlays()
		await process_frame

func _capture(stem: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUTPUT + stem + ".png")

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
	print("MENU_DENSITY ", "PASS " if ok else "FAIL ", message)
