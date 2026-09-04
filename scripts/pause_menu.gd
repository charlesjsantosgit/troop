class_name PauseMenu
extends Control
## Standalone pause/settings surface. Main owns pausing and scene transitions;
## this control only presents choices and emits intent.

signal resume_requested
signal main_menu_requested
signal sensitivity_changed(value: float)

const VIEW_HOME := 0
const VIEW_SETTINGS := 1
const TAB_AUDIO := 0
const TAB_CONTROLS := 1
const TAB_GRAPHICS := 2
const CUSTOM_FPS_OPTION := -1

const BINDABLE_ACTIONS := [
	{"category": "MOVEMENT", "action": "move_fwd", "label": "Move Forward"},
	{"action": "move_back", "label": "Move Back"},
	{"action": "move_left", "label": "Move Left"},
	{"action": "move_right", "label": "Move Right"},
	{"action": "jump", "label": "Jump / Double Jump"},
	{"action": "sprint", "label": "Sprint"},
	{"action": "crouch", "label": "Crouch / Slide"},
	{"category": "CANOPY", "action": "grab", "label": "Grab Vine / Interact"},
	{"action": "reel_in", "label": "Reel In"},
	{"action": "reel_out", "label": "Reel Out"},
	{"action": "ook", "label": "Ook"},
	{"category": "COMMUNICATION", "action": "push_to_talk", "label": "Push To Talk"},
	{"category": "COMBAT", "action": "shoot", "label": "Fire"},
	{"action": "aim", "label": "Aim"},
	{"action": "reload", "label": "Reload"},
	{"action": "melee_toggle", "label": "Toggle Melee"},
	{"action": "use_bandage", "label": "Use Bandage"},
	{"action": "weapon_1", "label": "Banana Gun"},
	{"action": "weapon_2", "label": "Shotgun"},
	{"action": "weapon_3", "label": "SMG"},
	{"action": "weapon_4", "label": "Sniper Rifle"},
	{"action": "scope_zoom", "label": "Scope Zoom"},
	{"category": "VEHICLES", "action": "vehicle_pitch_up", "label": "Jet Nose Up"},
	{"action": "vehicle_pitch_down", "label": "Jet Nose Down"},
	{"category": "VIEW", "action": "camera_mode", "label": "Camera Mode"},
	{"action": "fullscreen", "label": "Fullscreen"},
]

const MenuTheme := preload("res://scripts/menu_theme.gd")
const COLOR_INK := MenuTheme.INK
const COLOR_PANEL := MenuTheme.PANEL
const COLOR_LEAF := MenuTheme.TEAL
const COLOR_LEAF_BRIGHT := MenuTheme.ACCENT
const COLOR_MINT := MenuTheme.TEXT
const COLOR_MUTED := MenuTheme.MUTED
const COLOR_GOLD := MenuTheme.ACCENT

var _online := false
var _built := false
var _pending_settings_open := false
var _from_title := false
var _heading: Label
var _subtitle: Label
var _settings_back: Button
var _current_view := VIEW_HOME
var _current_tab := TAB_GRAPHICS
var _syncing := false
var _capture_action := ""
var _capture_button: Button

var _panel: PanelContainer
var _home_view: Control
var _settings_view: Control
var _graphics_view: Control
var _audio_view: Control
var _controls_view: Control
var _resume_button: Button
var _main_menu_button: Button
var _online_warning: Label
var _graphics_tab: Button
var _audio_tab: Button
var _controls_tab: Button
var _status_label: Label
var _capture_banner: Label
var _sensitivity_slider: HSlider
var _sensitivity_value: Label
var _fps_limit_select: OptionButton
var _custom_fps_row: Control
var _custom_fps_spin: SpinBox
var _fps_limit_status: Label
var _volume_sliders: Dictionary = {}
var _volume_values: Dictionary = {}
var _binding_buttons: Dictionary = {}
var _save_timer: Timer


func _ready() -> void:
	theme = MenuTheme.build()
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process_input(true)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_built = true
	resized.connect(_update_layout)
	_update_layout()
	_sync_from_settings()
	configure(_online)
	if _pending_settings_open:
		open_settings()
	else:
		_show_home()


func _exit_tree() -> void:
	_save_now()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and _built and visible:
		_sync_from_settings()
		if _current_view == VIEW_HOME:
			call_deferred("_focus_control", _resume_button)


## Update copy and leave-button treatment for a multiplayer session.
func configure(online: bool) -> void:
	_online = online
	if not _built:
		return
	_online_warning.visible = online
	_online_warning.text = ("Your online world keeps running. Return to the title screen to disconnect.") \
		if online else ""
	_main_menu_button.text = "Leave online world" if online else "Return to title"


## Public shortcut used by Main when opening directly onto pause settings.
func open_settings() -> void:
	if not _built:
		_pending_settings_open = true
		return
	_cancel_capture(false)
	_current_view = VIEW_SETTINGS
	_home_view.visible = false
	_settings_view.visible = true
	_sync_from_settings()
	_heading.text = "Settings"
	_subtitle.text = "Make TROOP comfortable for you."
	_settings_back.text = "‹  Return to title" if _from_title else "‹  Back to pause"
	_show_settings_tab(_current_tab)
	_update_layout()


## The title owns this overlay and removes it on resume_requested.
func open_settings_from_title() -> void:
	_from_title = true
	open_settings()


func _back_from_settings() -> void:
	if _from_title:
		_request_resume()
	else:
		_show_home()


## Refresh every binding label after an external reset or rebind.
func refresh_bindings() -> void:
	if not _built:
		return
	var settings := _settings()
	for action in _binding_buttons:
		var button: Button = _binding_buttons[action]
		var binding := "UNBOUND"
		if settings and settings.has_method("binding_text"):
			binding = str(settings.call("binding_text", action))
		button.text = binding.to_upper()
		button.tooltip_text = "Change %s" % action


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.minimum_size_changed.connect(_update_layout, CONNECT_DEFERRED)
	_panel.name = "PauseFrame"
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 12)
	_panel.add_child(frame)

	var header := HBoxContainer.new()
	frame.add_child(header)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 4)
	header.add_child(titles)
	titles.add_child(MenuTheme.label("TROOP / YOUR SESSION", 12, COLOR_LEAF_BRIGHT))
	_heading = MenuTheme.label("Paused", 34)
	titles.add_child(_heading)
	_subtitle = MenuTheme.label("Take a moment. Pick up where you left off.", 15, COLOR_MUTED)
	titles.add_child(_subtitle)
	var divider := ColorRect.new()
	divider.color = MenuTheme.BORDER
	divider.custom_minimum_size = Vector2(0, 1)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(divider)

	var view_host := Control.new()
	view_host.name = "ViewHost"
	view_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.add_child(view_host)

	_home_view = _build_home_view()
	view_host.add_child(_home_view)
	_home_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_view = _build_settings_view()
	view_host.add_child(_settings_view)
	_settings_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_status_label = Label.new()
	_status_label.text = "Esc · Resume playing"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(0, 22)
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", Color(COLOR_MUTED, 0.82))
	frame.add_child(_status_label)

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.30
	_save_timer.timeout.connect(_save_now)
	add_child(_save_timer)


func _build_home_view() -> Control:
	var center := CenterContainer.new()
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(340, 0)
	column.add_theme_constant_override("separation", 12)
	center.add_child(column)
	_resume_button = _action_button("Resume playing", COLOR_LEAF_BRIGHT, COLOR_LEAF_BRIGHT)
	_resume_button.pressed.connect(_request_resume)
	column.add_child(_resume_button)
	var settings_button := _action_button("Settings", MenuTheme.INSET, COLOR_LEAF)
	settings_button.pressed.connect(open_settings)
	column.add_child(settings_button)
	var settings_copy := MenuTheme.label("Graphics, sound, mouse sensitivity and key bindings.", 14, COLOR_MUTED)
	settings_copy.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(settings_copy)
	_main_menu_button = _action_button("Return to title", MenuTheme.INSET, COLOR_LEAF)
	_main_menu_button.pressed.connect(_request_main_menu)
	column.add_child(_main_menu_button)
	_online_warning = MenuTheme.label("", 14, COLOR_GOLD)
	_online_warning.visible = false
	_online_warning.add_theme_stylebox_override("normal", _notice_style())
	column.add_child(_online_warning)
	return center


func _build_settings_view() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	_settings_back = _small_button("‹  Back to pause")
	_settings_back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_settings_back.pressed.connect(_back_from_settings)
	column.add_child(_settings_back)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 24)
	column.add_child(body)
	var tabs := VBoxContainer.new()
	tabs.custom_minimum_size.x = 142
	tabs.add_theme_constant_override("separation", 8)
	body.add_child(tabs)
	_graphics_tab = _tab_button("Graphics")
	_audio_tab = _tab_button("Audio")
	_controls_tab = _tab_button("Controls")
	_graphics_tab.pressed.connect(func(): _show_settings_tab(TAB_GRAPHICS))
	_audio_tab.pressed.connect(func(): _show_settings_tab(TAB_AUDIO))
	_controls_tab.pressed.connect(func(): _show_settings_tab(TAB_CONTROLS))
	tabs.add_child(_graphics_tab)
	tabs.add_child(_audio_tab)
	tabs.add_child(_controls_tab)
	var save_note := MenuTheme.label("Changes apply immediately and save automatically.", 13, COLOR_MUTED)
	save_note.custom_minimum_size.x = 140
	tabs.add_child(save_note)
	var content := Control.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(content)
	_graphics_view = _build_graphics_view()
	content.add_child(_graphics_view)
	_graphics_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_audio_view = _build_audio_view()
	content.add_child(_audio_view)
	_audio_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_controls_view = _build_controls_view()
	content.add_child(_controls_view)
	_controls_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return column


func _build_graphics_view() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 14)
	scroll.add_child(column)

	column.add_child(_section_copy("Frame rate", "Set a limit for steadier pacing and lower power use. Choose Unlimited for the highest possible frame rate."))

	var preset_row := HBoxContainer.new()
	preset_row.custom_minimum_size = Vector2(0, 52)
	preset_row.add_theme_constant_override("separation", 12)
	var preset_label := Label.new()
	preset_label.text = "Frame limit"
	preset_label.custom_minimum_size = Vector2(118, 0)
	preset_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preset_label.add_theme_font_size_override("font_size", 14)
	preset_label.add_theme_color_override("font_color", COLOR_MUTED)
	preset_row.add_child(preset_label)
	_fps_limit_select = OptionButton.new()
	_fps_limit_select.name = "FPSLimitPreset"
	_fps_limit_select.focus_mode = Control.FOCUS_ALL
	_fps_limit_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fps_limit_select.custom_minimum_size = Vector2(140, 42)
	_fps_limit_select.tooltip_text = "Maximum rendered frames per second"
	for fps_limit in GameSettings.FPS_LIMIT_PRESETS:
		_fps_limit_select.add_item("UNLIMITED" if fps_limit == 0 \
			else "%d FPS" % fps_limit)
		var index := _fps_limit_select.item_count - 1
		_fps_limit_select.set_item_metadata(index, fps_limit)
	_fps_limit_select.add_item("CUSTOM…")
	_fps_limit_select.set_item_metadata(_fps_limit_select.item_count - 1,
		CUSTOM_FPS_OPTION)
	_fps_limit_select.item_selected.connect(_on_fps_limit_selected)
	preset_row.add_child(_fps_limit_select)
	column.add_child(preset_row)

	_custom_fps_row = HBoxContainer.new()
	_custom_fps_row.name = "CustomFPSRow"
	_custom_fps_row.custom_minimum_size = Vector2(0, 52)
	_custom_fps_row.add_theme_constant_override("separation", 12)
	var custom_label := Label.new()
	custom_label.text = "Custom limit"
	custom_label.custom_minimum_size = Vector2(118, 0)
	custom_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	custom_label.add_theme_font_size_override("font_size", 14)
	custom_label.add_theme_color_override("font_color", COLOR_MUTED)
	_custom_fps_row.add_child(custom_label)
	_custom_fps_spin = SpinBox.new()
	_custom_fps_spin.name = "CustomFPSLimit"
	_custom_fps_spin.focus_mode = Control.FOCUS_ALL
	_custom_fps_spin.min_value = GameSettings.MIN_CUSTOM_FPS_LIMIT
	_custom_fps_spin.max_value = GameSettings.MAX_CUSTOM_FPS_LIMIT
	_custom_fps_spin.step = 1.0
	_custom_fps_spin.rounded = true
	_custom_fps_spin.suffix = " FPS"
	_custom_fps_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_custom_fps_spin.custom_minimum_size = Vector2(140, 42)
	_custom_fps_spin.tooltip_text = ("Enter %d–%d FPS; use the arrows, keyboard, "
		+ "mouse wheel, or controller") % [GameSettings.MIN_CUSTOM_FPS_LIMIT,
		GameSettings.MAX_CUSTOM_FPS_LIMIT]
	_custom_fps_spin.value_changed.connect(_on_custom_fps_changed)
	_custom_fps_row.add_child(_custom_fps_spin)
	column.add_child(_custom_fps_row)

	_fps_limit_status = Label.new()
	_fps_limit_status.name = "FPSLimitStatus"
	_fps_limit_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fps_limit_status.add_theme_stylebox_override("normal", _inset_style())
	_fps_limit_status.add_theme_font_size_override("font_size", 14)
	_fps_limit_status.add_theme_color_override("font_color", COLOR_MINT)
	column.add_child(_fps_limit_status)

	var note := Label.new()
	note.text = ("Unlimited may use more power. The limiter changes immediately "
		+ "and does not affect the game's 60 Hz physics simulation.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 14)
	note.add_theme_color_override("font_color", COLOR_MUTED)
	column.add_child(note)
	return scroll


func _build_audio_view() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 12)
	scroll.add_child(column)

	var intro := _section_copy("Sound levels", "Balance effects, ambience and nearby voices. Master volume adjusts everything.")
	column.add_child(intro)
	_add_volume_row(column, "Master volume", "master_volume", "master")
	_add_volume_row(column, "Sound effects", "sfx_volume", "sfx")
	_add_volume_row(column, "Ambience", "ambience_volume", "ambience")
	_add_volume_row(column, "Voice chat", "voice_volume", "voice")

	var note := Label.new()
	note.text = "Tip: lowering ambience can make reload clicks and shell impacts easier to hear."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_stylebox_override("normal", _inset_style())
	note.add_theme_font_size_override("font_size", 14)
	note.add_theme_color_override("font_color", COLOR_MUTED)
	column.add_child(note)
	return scroll


func _add_volume_row(parent: VBoxContainer, label_text: String,
		property_name: String, channel: String) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 48)
	row.add_theme_constant_override("separation", 12)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(118, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", COLOR_MUTED)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(100, 32)
	slider.tooltip_text = label_text.capitalize()
	row.add_child(slider)
	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(54, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_label.add_theme_color_override("font_color", COLOR_MINT)
	value_label.add_theme_font_size_override("font_size", 14)
	row.add_child(value_label)
	_volume_sliders[property_name] = slider
	_volume_values[property_name] = value_label
	slider.value_changed.connect(func(value: float):
		value_label.text = "%d%%" % roundi(value * 100.0)
		if _syncing:
			return
		var settings := _settings()
		if settings and settings.has_method("set_volume"):
			settings.call("set_volume", channel, value)
		_schedule_save())
	parent.add_child(row)


func _build_controls_view() -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)

	_capture_banner = Label.new()
	_capture_banner.visible = false
	_capture_banner.text = "PRESS A KEY OR MOUSE BUTTON  ·  ESC CANCELS"
	_capture_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_capture_banner.add_theme_stylebox_override("normal", _capture_style())
	_capture_banner.add_theme_font_size_override("font_size", 14)
	_capture_banner.add_theme_color_override("font_color", COLOR_GOLD)
	outer.add_child(_capture_banner)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 7)
	scroll.add_child(column)

	column.add_child(_section_copy("Mouse & keyboard", "Choose a binding, then press its new key or mouse button. Escape cancels a change."))
	var sensitivity_row := HBoxContainer.new()
	sensitivity_row.custom_minimum_size = Vector2(0, 48)
	sensitivity_row.add_theme_constant_override("separation", 12)
	var sensitivity_label := Label.new()
	sensitivity_label.text = "Sensitivity"
	sensitivity_label.custom_minimum_size = Vector2(118, 0)
	sensitivity_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sensitivity_label.add_theme_font_size_override("font_size", 14)
	sensitivity_label.add_theme_color_override("font_color", COLOR_MUTED)
	sensitivity_row.add_child(sensitivity_label)
	_sensitivity_slider = HSlider.new()
	_sensitivity_slider.min_value = 0.25
	_sensitivity_slider.max_value = 2.5
	_sensitivity_slider.step = 0.05
	_sensitivity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sensitivity_slider.custom_minimum_size = Vector2(100, 32)
	sensitivity_row.add_child(_sensitivity_slider)
	_sensitivity_value = Label.new()
	_sensitivity_value.custom_minimum_size = Vector2(54, 0)
	_sensitivity_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_sensitivity_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_sensitivity_value.add_theme_color_override("font_color", COLOR_MINT)
	_sensitivity_value.add_theme_font_size_override("font_size", 14)
	sensitivity_row.add_child(_sensitivity_value)
	_sensitivity_slider.value_changed.connect(_on_sensitivity_changed)
	column.add_child(sensitivity_row)

	for item in BINDABLE_ACTIONS:
		if item.has("category"):
			column.add_child(_category_label(str(item.category)))
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(0, 38)
		row.add_theme_constant_override("separation", 12)
		var action_label := Label.new()
		action_label.text = str(item.label)
		action_label.custom_minimum_size = Vector2(178, 0)
		action_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		action_label.add_theme_font_size_override("font_size", 14)
		action_label.add_theme_color_override("font_color", COLOR_MUTED)
		row.add_child(action_label)
		var bind_button := _binding_button()
		var action := str(item.action)
		bind_button.pressed.connect(func(): _begin_capture(action, bind_button))
		_binding_buttons[action] = bind_button
		row.add_child(bind_button)
		column.add_child(row)

	var reset := _small_button("RESET CONTROLS TO DEFAULTS")
	reset.add_theme_color_override("font_color", COLOR_GOLD)
	reset.pressed.connect(_reset_controls)
	column.add_child(reset)
	return outer


func _show_home() -> void:
	if not _built:
		return
	_cancel_capture(false)
	_current_view = VIEW_HOME
	_heading.text = "Paused"
	_subtitle.text = "Your online world is still running." if _online else "Take a moment. Pick up where you left off."
	_home_view.visible = true
	_settings_view.visible = false
	_status_label.text = "Esc · Resume playing"
	call_deferred("_focus_control", _resume_button)
	_update_layout()


func _show_settings_tab(tab: int) -> void:
	_current_tab = tab
	_graphics_view.visible = tab == TAB_GRAPHICS
	_audio_view.visible = tab == TAB_AUDIO
	_controls_view.visible = tab == TAB_CONTROLS
	_set_tab_selected(_graphics_tab, tab == TAB_GRAPHICS)
	_set_tab_selected(_audio_tab, tab == TAB_AUDIO)
	_set_tab_selected(_controls_tab, tab == TAB_CONTROLS)
	_status_label.text = "Esc · Return to title" if _from_title else "Esc · Back to pause"
	if tab == TAB_CONTROLS:
		refresh_bindings()
	var selected_tab: Button = _graphics_tab
	if tab == TAB_AUDIO:
		selected_tab = _audio_tab
	elif tab == TAB_CONTROLS:
		selected_tab = _controls_tab
	call_deferred("_focus_control", selected_tab)


func _set_tab_selected(button: Button, selected: bool) -> void:
	button.add_theme_stylebox_override("normal", _tab_style(selected))
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, COLOR_INK if selected else COLOR_MUTED)
	button.add_theme_stylebox_override("hover", _tab_style(selected))
	button.add_theme_stylebox_override("pressed", _tab_style(selected))


func _sync_from_settings() -> void:
	if not _built:
		return
	var settings := _settings()
	_syncing = true
	for property_name in _volume_sliders:
		var fallback := 1.0
		var value := _setting_float(settings, property_name, fallback)
		var slider: HSlider = _volume_sliders[property_name]
		var label: Label = _volume_values[property_name]
		slider.value = value
		label.text = "%d%%" % roundi(value * 100.0)
	var sensitivity := _setting_float(settings, "mouse_sensitivity", 1.0)
	_sensitivity_slider.value = sensitivity
	_sensitivity_value.text = "%.2f×" % sensitivity
	var custom_limit := _setting_int(settings, "custom_fps_limit",
		GameSettings.DEFAULT_FPS_LIMIT)
	_custom_fps_spin.value = custom_limit
	var fps_limit := _setting_int(settings, "fps_limit",
		GameSettings.DEFAULT_FPS_LIMIT)
	var custom_selected := _setting_bool(settings, "fps_limit_custom", false)
	var selected_index := _find_fps_option(CUSTOM_FPS_OPTION)
	if not custom_selected:
		var preset_index := _find_fps_option(fps_limit)
		if preset_index >= 0:
			selected_index = preset_index
	_fps_limit_select.select(selected_index)
	_custom_fps_row.visible = custom_selected
	_update_fps_limit_status(fps_limit)
	_syncing = false
	refresh_bindings()


func _on_sensitivity_changed(value: float) -> void:
	_sensitivity_value.text = "%.2f×" % value
	if _syncing:
		return
	var settings := _settings()
	if settings and settings.has_method("set_mouse_sensitivity"):
		settings.call("set_mouse_sensitivity", value)
	sensitivity_changed.emit(value)
	_schedule_save()


func _on_fps_limit_selected(index: int) -> void:
	if _syncing or index < 0 or index >= _fps_limit_select.item_count:
		return
	var selected_limit := int(_fps_limit_select.get_item_metadata(index))
	var settings := _settings()
	if selected_limit == CUSTOM_FPS_OPTION:
		_custom_fps_row.visible = true
		var custom_limit := roundi(_custom_fps_spin.value)
		if settings and settings.has_method("set_custom_fps_limit"):
			settings.call("set_custom_fps_limit", custom_limit)
		_update_fps_limit_status(custom_limit)
		_custom_fps_spin.grab_focus()
	else:
		_custom_fps_row.visible = false
		if settings and settings.has_method("set_fps_limit"):
			settings.call("set_fps_limit", selected_limit)
		_update_fps_limit_status(selected_limit)
	_schedule_save()


func _on_custom_fps_changed(value: float) -> void:
	if _syncing or not _custom_fps_row.visible:
		return
	var custom_limit := roundi(value)
	var settings := _settings()
	var accepted := false
	if settings and settings.has_method("set_custom_fps_limit"):
		accepted = bool(settings.call("set_custom_fps_limit", custom_limit))
	if accepted:
		_update_fps_limit_status(custom_limit)
		_schedule_save()
	else:
		_status_label.text = ("CUSTOM FPS MUST BE BETWEEN %d AND %d" % [
			GameSettings.MIN_CUSTOM_FPS_LIMIT,
			GameSettings.MAX_CUSTOM_FPS_LIMIT])


func _update_fps_limit_status(value: int) -> void:
	if not _fps_limit_status:
		return
	_fps_limit_status.text = ("UNLIMITED  ·  No render frame cap is active."
		if value == 0 else "ACTIVE LIMIT  ·  %d FPS" % value)


func _find_fps_option(value: int) -> int:
	for index in range(_fps_limit_select.item_count):
		if int(_fps_limit_select.get_item_metadata(index)) == value:
			return index
	return -1


func _begin_capture(action: String, button: Button) -> void:
	_cancel_capture(false)
	_capture_action = action
	_capture_button = button
	button.text = "PRESS INPUT…"
	button.add_theme_stylebox_override("normal", _binding_style(true))
	_capture_banner.visible = true
	_status_label.text = "LISTENING FOR %s  ·  ESC CANCELS" % action.to_upper()


func _finish_capture(event: InputEvent) -> void:
	var action := _capture_action
	var settings := _settings()
	if settings and settings.has_method("rebind"):
		settings.call("rebind", action, event)
		if settings.has_method("save"):
			settings.call("save")
	_cancel_capture(false)
	refresh_bindings()
	_status_label.text = ("BINDING UPDATED  ·  ANY DUPLICATE WAS SWAPPED "
		+ "AUTOMATICALLY")


func _cancel_capture(show_message := true) -> void:
	if _capture_action.is_empty():
		return
	if _capture_button and is_instance_valid(_capture_button):
		_capture_button.add_theme_stylebox_override("normal",
			_binding_style(false))
	_capture_action = ""
	_capture_button = null
	if _capture_banner:
		_capture_banner.visible = false
	refresh_bindings()
	if show_message:
		_status_label.text = "REBIND CANCELLED  ·  ESC  BACK"


func _reset_controls() -> void:
	_cancel_capture(false)
	var settings := _settings()
	if settings and settings.has_method("reset_bindings"):
		settings.call("reset_bindings")
		if settings.has_method("save"):
			settings.call("save")
	refresh_bindings()
	_status_label.text = "DEFAULT CONTROLS RESTORED"


func _request_resume() -> void:
	_cancel_capture(false)
	_save_now()
	resume_requested.emit()


func _request_main_menu() -> void:
	_cancel_capture(false)
	_save_now()
	main_menu_requested.emit()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if not _capture_action.is_empty():
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_ESCAPE or event.physical_keycode == KEY_ESCAPE:
				_cancel_capture(true)
			else:
				_finish_capture(event)
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton and event.pressed:
			_finish_capture(event)
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and (event.keycode == KEY_ESCAPE \
			or event.physical_keycode == KEY_ESCAPE):
		if _current_view == VIEW_SETTINGS:
			_back_from_settings()
		else:
			_request_resume()
		get_viewport().set_input_as_handled()


func _settings() -> Node:
	return get_node_or_null("/root/Settings")


func _setting_float(settings: Node, property_name: String,
		fallback: float) -> float:
	if not settings:
		return fallback
	var value = settings.get(property_name)
	return float(value) if typeof(value) in [TYPE_FLOAT, TYPE_INT] else fallback


func _setting_int(settings: Node, property_name: String, fallback: int) -> int:
	if not settings:
		return fallback
	var value = settings.get(property_name)
	return int(value) if typeof(value) in [TYPE_FLOAT, TYPE_INT] else fallback


func _setting_bool(settings: Node, property_name: String, fallback: bool) -> bool:
	if not settings:
		return fallback
	var value = settings.get(property_name)
	return bool(value) if typeof(value) == TYPE_BOOL else fallback


func _schedule_save() -> void:
	if _save_timer:
		_save_timer.start()


func _save_now() -> void:
	if _save_timer and not _save_timer.is_stopped():
		_save_timer.stop()
	var settings := _settings()
	if settings and settings.has_method("save"):
		settings.call("save")


func _focus_control(control: Control) -> void:
	if visible and control and is_instance_valid(control):
		control.grab_focus()


func _update_layout() -> void:
	if not _panel:
		return
	var margin := 40.0 if size.x >= 720.0 and size.y >= 500.0 else 18.0
	var desired := Vector2(900, 640) if _current_view == VIEW_SETTINGS else Vector2(440, 460)
	var panel_size := Vector2(minf(desired.x, size.x - margin * 2.0),
		minf(desired.y, size.y - margin * 2.0))
	_panel.position = (size - panel_size) * 0.5
	_panel.size = panel_size
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.025, 0.045, 0.04, 0.16))


func _action_button(text_value: String, base: Color, _hover: Color) -> Button:
	var button := Button.new()
	button.text = text_value
	button.custom_minimum_size = Vector2(0, 52)
	MenuTheme.style_button(button, base == COLOR_LEAF_BRIGHT)
	return button


func _small_button(text_value: String) -> Button:
	var button := Button.new()
	button.text = text_value
	MenuTheme.style_button(button)
	return button


func _tab_button(text_value: String) -> Button:
	var button := _small_button(text_value)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	return button


func _binding_button() -> Button:
	var button := _small_button("—")
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size = Vector2(124, 42)
	return button


func _section_copy(title_text: String, body: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", COLOR_LEAF_BRIGHT)
	box.add_child(title)
	var copy := Label.new()
	copy.text = body
	copy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	copy.add_theme_font_size_override("font_size", 14)
	copy.add_theme_color_override("font_color", COLOR_MUTED)
	box.add_child(copy)
	return box


func _category_label(text_value: String) -> Label:
	var label := Label.new()
	label.text = text_value.capitalize()
	label.custom_minimum_size = Vector2(0, 30)
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", COLOR_LEAF_BRIGHT)
	return label


func _panel_style() -> StyleBoxFlat:
	return MenuTheme.panel(MenuTheme.PANEL, MenuTheme.BORDER, 24, 14)


func _tab_style(selected: bool) -> StyleBoxFlat:
	return MenuTheme.panel(COLOR_LEAF_BRIGHT if selected else MenuTheme.INSET,
		COLOR_LEAF_BRIGHT if selected else MenuTheme.BORDER, 12, 8)


func _binding_style(listening: bool) -> StyleBoxFlat:
	return MenuTheme.panel(MenuTheme.INSET, COLOR_GOLD if listening else MenuTheme.BORDER, 12, 8)


func _notice_style() -> StyleBoxFlat:
	return MenuTheme.panel(MenuTheme.INSET, MenuTheme.BORDER, 12, 8)


func _capture_style() -> StyleBoxFlat:
	return MenuTheme.panel(MenuTheme.INSET, MenuTheme.ACCENT, 12, 8)


func _inset_style() -> StyleBoxFlat:
	return MenuTheme.panel(MenuTheme.INK, MenuTheme.BORDER, 12, 8)
