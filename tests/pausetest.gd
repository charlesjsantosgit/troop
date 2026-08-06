extends Node
## Pause/settings lifecycle checks. This node must keep running while the solo
## SceneTree is paused so it can verify both sides of the transition.

var passed := 0
var total := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func run(main) -> void:
	await get_tree().process_frame
	main._open_pause_menu()
	_check(get_tree().paused and main.pause_menu != null \
		and main.pause_layer != null,
		"solo pause freezes the world on an always-processing menu layer")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
		"pause releases the cursor")
	_check(main.pause_menu._binding_buttons.size() == 24,
		"controls page exposes every player-facing keyboard and mouse action")
	_check(AudioServer.get_bus_index(&"SFX") >= 0 \
		and AudioServer.get_bus_index(&"Ambience") >= 0 \
		and AudioServer.get_bus_index(&"Voice") >= 0,
		"separate effects, ambience, and voice buses are available")
	_check(not Settings.binding_text(&"shoot").is_empty() \
		and not Settings.binding_text(&"move_fwd").is_empty() \
		and not Settings.binding_text(&"push_to_talk").is_empty(),
		"saved key and mouse bindings have readable labels")

	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	main.pause_menu.open_settings()
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


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label)
