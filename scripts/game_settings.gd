class_name GameSettings
extends Node
## Persistent, presentation-agnostic game settings.
##
## Autoload this node near the application root. It loads immediately and
## applies audio values live. Main applies saved bindings after registering its
## InputMap actions so diagnostic modes can keep deterministic defaults.

signal volume_changed(channel: StringName, value: float)
signal mouse_sensitivity_changed(value: float)
signal binding_changed(action: StringName, label: String)
signal bindings_reset

const CONFIG_PATH := "user://settings.cfg"
const CONFIG_VERSION := 2
const MIN_MOUSE_SENSITIVITY := 0.25
const MAX_MOUSE_SENSITIVITY := 2.5
const MIN_AUDIBLE_LINEAR := 0.0001

const BINDING_ACTIONS: Array[StringName] = [
	&"move_fwd",
	&"move_back",
	&"move_left",
	&"move_right",
	&"jump",
	&"sprint",
	&"crouch",
	&"grab",
	&"shoot",
	&"aim",
	&"reel_in",
	&"reel_out",
	&"reload",
	&"use_bandage",
	&"weapon_1",
	&"weapon_2",
	&"weapon_3",
	&"weapon_4",
	&"scope_zoom",
	&"melee_toggle",
	&"ook",
	&"push_to_talk",
	&"menu",
	&"fullscreen",
	&"camera_mode",
]

const DEFAULT_KEYS := {
	&"move_fwd": KEY_W,
	&"move_back": KEY_S,
	&"move_left": KEY_A,
	&"move_right": KEY_D,
	&"jump": KEY_SPACE,
	&"sprint": KEY_SHIFT,
	&"crouch": KEY_CTRL,
	&"grab": KEY_E,
	&"reload": KEY_R,
	&"use_bandage": KEY_H,
	&"weapon_1": KEY_1,
	&"weapon_2": KEY_2,
	&"weapon_3": KEY_3,
	&"weapon_4": KEY_4,
	&"scope_zoom": KEY_Z,
	&"melee_toggle": KEY_Q,
	&"ook": KEY_V,
	&"push_to_talk": KEY_T,
	&"menu": KEY_ESCAPE,
	&"fullscreen": KEY_F11,
	&"camera_mode": KEY_C,
}

const DEFAULT_MOUSE_BUTTONS := {
	&"shoot": MOUSE_BUTTON_LEFT,
	&"aim": MOUSE_BUTTON_RIGHT,
	&"reel_in": MOUSE_BUTTON_WHEEL_UP,
	&"reel_out": MOUSE_BUTTON_WHEEL_DOWN,
}

var master_volume := 1.0
var sfx_volume := 1.0
var ambience_volume := 1.0
var voice_volume := 1.0
var mouse_sensitivity := 1.0
var player_name := ""
var minimap_mode := 0
var minimap_zoom := 1.0

var _bindings: Dictionary = {}


func _init() -> void:
	_restore_default_bindings()
	_load_from_disk()
	_ensure_audio_buses()
	_apply_all_volumes()


## Sets a 0..1 linear volume and applies it to its AudioServer bus immediately.
## Accepted channels are master, sfx/effects, and ambience.
func set_volume(channel: StringName, value: float) -> bool:
	if is_nan(value) or is_inf(value):
		return false
	var linear := clampf(value, 0.0, 1.0)
	var normalized := String(channel).strip_edges().to_lower()
	match normalized:
		"master":
			master_volume = linear
			_apply_bus_volume(&"Master", master_volume)
			volume_changed.emit(&"master", master_volume)
		"sfx", "effects":
			sfx_volume = linear
			_apply_bus_volume(&"SFX", sfx_volume)
			volume_changed.emit(&"sfx", sfx_volume)
		"ambience", "ambient":
			ambience_volume = linear
			_apply_bus_volume(&"Ambience", ambience_volume)
			volume_changed.emit(&"ambience", ambience_volume)
		"voice", "voice_chat":
			voice_volume = linear
			_apply_bus_volume(&"Voice", voice_volume)
			volume_changed.emit(&"voice", voice_volume)
		_:
			return false
	return true


## The chosen monkey name persists across sessions instead of re-rolling.
func set_player_name(value: String) -> void:
	player_name = value.strip_edges().left(20)


func set_minimap_prefs(mode: int, zoom: float) -> void:
	minimap_mode = clampi(mode, 0, 2)
	minimap_zoom = clampf(zoom, 0.4, 2.6)
	save()


func set_mouse_sensitivity(value: float) -> void:
	if is_nan(value) or is_inf(value):
		return
	mouse_sensitivity = clampf(value, MIN_MOUSE_SENSITIVITY, MAX_MOUSE_SENSITIVITY)
	mouse_sensitivity_changed.emit(mouse_sensitivity)


## Replaces the primary keyboard/mouse event for every registered action while
## preserving any future controller bindings attached elsewhere.
func apply_saved_bindings() -> int:
	var applied := 0
	for action in BINDING_ACTIONS:
		if not InputMap.has_action(action):
			continue
		_apply_binding_to_input_map(action)
		applied += 1
	return applied


func binding_text(action: StringName) -> String:
	var action_name := StringName(action)
	var event := _bindings.get(action_name) as InputEvent
	if event == null:
		return "Unbound"
	return _event_label(event)


## Assigns one key or mouse button. If another managed action already owns it,
## that action receives this action's previous binding instead of becoming
## silently unbound.
func rebind(action: StringName, event: InputEvent) -> bool:
	var action_name := StringName(action)
	if not _bindings.has(action_name):
		return false
	var normalized := _normalize_event(event)
	if normalized == null:
		return false
	var previous := _bindings[action_name] as InputEvent
	if _events_match(previous, normalized):
		return true

	var conflicting_action := _find_conflicting_action(action_name, normalized)
	_bindings[action_name] = normalized
	_apply_binding_to_input_map(action_name)
	binding_changed.emit(action_name, _event_label(normalized))

	if not conflicting_action.is_empty():
		_bindings[conflicting_action] = previous
		_apply_binding_to_input_map(conflicting_action)
		binding_changed.emit(conflicting_action, _event_label(previous))
	return true


func reset_bindings() -> void:
	_restore_default_bindings()
	apply_saved_bindings()
	for action in BINDING_ACTIONS:
		binding_changed.emit(action, binding_text(action))
	bindings_reset.emit()


func save() -> Error:
	var config := ConfigFile.new()
	config.set_value("meta", "version", CONFIG_VERSION)
	config.set_value("audio", "master", master_volume)
	config.set_value("audio", "sfx", sfx_volume)
	config.set_value("audio", "ambience", ambience_volume)
	config.set_value("audio", "voice", voice_volume)
	config.set_value("controls", "mouse_sensitivity", mouse_sensitivity)
	config.set_value("profile", "name", player_name)
	config.set_value("minimap", "mode", minimap_mode)
	config.set_value("minimap", "zoom", minimap_zoom)
	for action in BINDING_ACTIONS:
		var event := _bindings.get(action) as InputEvent
		if event != null:
			config.set_value("bindings", String(action), _event_to_data(event))
	return config.save(CONFIG_PATH)


func _load_from_disk() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	master_volume = _read_linear_volume(config, "master", master_volume)
	sfx_volume = _read_linear_volume(config, "sfx", sfx_volume)
	ambience_volume = _read_linear_volume(config, "ambience", ambience_volume)
	voice_volume = _read_linear_volume(config, "voice", voice_volume)
	mouse_sensitivity = clampf(
		float(config.get_value("controls", "mouse_sensitivity", mouse_sensitivity)),
		MIN_MOUSE_SENSITIVITY,
		MAX_MOUSE_SENSITIVITY)
	player_name = str(config.get_value("profile", "name", "")).strip_edges() \
		.left(20)
	minimap_mode = clampi(int(config.get_value("minimap", "mode", 0)), 0, 2)
	minimap_zoom = clampf(float(config.get_value("minimap", "zoom", 1.0)),
		0.4, 2.6)

	# Applying stored values through the same swap rule makes partially-written or
	# hand-edited config files deterministic and conflict-free.
	for action in BINDING_ACTIONS:
		if not config.has_section_key("bindings", String(action)):
			continue
		var data: Variant = config.get_value("bindings", String(action))
		var event := _event_from_data(data)
		if event != null:
			_set_binding_without_input_map(action, event)


func _read_linear_volume(config: ConfigFile, key: String, fallback: float) -> float:
	var value := float(config.get_value("audio", key, fallback))
	if is_nan(value) or is_inf(value):
		return fallback
	return clampf(value, 0.0, 1.0)


func _restore_default_bindings() -> void:
	_bindings.clear()
	for action in BINDING_ACTIONS:
		if DEFAULT_KEYS.has(action):
			var key_event := InputEventKey.new()
			key_event.physical_keycode = DEFAULT_KEYS[action]
			_bindings[action] = key_event
		elif DEFAULT_MOUSE_BUTTONS.has(action):
			var mouse_event := InputEventMouseButton.new()
			mouse_event.button_index = DEFAULT_MOUSE_BUTTONS[action]
			_bindings[action] = mouse_event


func _set_binding_without_input_map(action: StringName, event: InputEvent) -> void:
	var previous := _bindings[action] as InputEvent
	if _events_match(previous, event):
		return
	var conflicting_action := _find_conflicting_action(action, event)
	_bindings[action] = event
	if not conflicting_action.is_empty():
		_bindings[conflicting_action] = previous


func _find_conflicting_action(action: StringName, event: InputEvent) -> StringName:
	for candidate in BINDING_ACTIONS:
		if candidate == action:
			continue
		if _events_match(_bindings.get(candidate) as InputEvent, event):
			return candidate
	return &""


func _apply_binding_to_input_map(action: StringName) -> void:
	if not InputMap.has_action(action):
		return
	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey or existing is InputEventMouseButton:
			InputMap.action_erase_event(action, existing)
	var event := _bindings.get(action) as InputEvent
	if event != null:
		InputMap.action_add_event(action, event.duplicate())


func _normalize_event(event: InputEvent) -> InputEvent:
	if event is InputEventKey:
		var source := event as InputEventKey
		var key_event := InputEventKey.new()
		if source.physical_keycode != 0:
			key_event.physical_keycode = source.physical_keycode
		elif source.keycode != 0:
			key_event.keycode = source.keycode
		else:
			return null
		_copy_modifiers(source, key_event)
		_clear_self_modifier(key_event)
		return key_event
	if event is InputEventMouseButton:
		var source := event as InputEventMouseButton
		if source.button_index <= MOUSE_BUTTON_NONE:
			return null
		var mouse_event := InputEventMouseButton.new()
		mouse_event.button_index = source.button_index
		_copy_modifiers(source, mouse_event)
		return mouse_event
	return null


func _copy_modifiers(source: InputEventWithModifiers,
		destination: InputEventWithModifiers) -> void:
	destination.ctrl_pressed = source.ctrl_pressed
	destination.alt_pressed = source.alt_pressed
	destination.shift_pressed = source.shift_pressed
	destination.meta_pressed = source.meta_pressed


func _clear_self_modifier(event: InputEventKey) -> void:
	var code := event.physical_keycode if event.physical_keycode != 0 else event.keycode
	match code:
		KEY_CTRL:
			event.ctrl_pressed = false
		KEY_ALT:
			event.alt_pressed = false
		KEY_SHIFT:
			event.shift_pressed = false
		KEY_META:
			event.meta_pressed = false


func _events_match(first: InputEvent, second: InputEvent) -> bool:
	if first == null or second == null:
		return false
	if first is InputEventKey and second is InputEventKey:
		var a := first as InputEventKey
		var b := second as InputEventKey
		var a_code := a.physical_keycode if a.physical_keycode != 0 else a.keycode
		var b_code := b.physical_keycode if b.physical_keycode != 0 else b.keycode
		return a_code == b_code and _modifiers_match(a, b)
	if first is InputEventMouseButton and second is InputEventMouseButton:
		var a := first as InputEventMouseButton
		var b := second as InputEventMouseButton
		return a.button_index == b.button_index and _modifiers_match(a, b)
	return false


func _modifiers_match(first: InputEventWithModifiers,
		second: InputEventWithModifiers) -> bool:
	return first.ctrl_pressed == second.ctrl_pressed \
		and first.alt_pressed == second.alt_pressed \
		and first.shift_pressed == second.shift_pressed \
		and first.meta_pressed == second.meta_pressed


func _event_to_data(event: InputEvent) -> Dictionary:
	var data := {
		"ctrl": false,
		"alt": false,
		"shift": false,
		"meta": false,
	}
	if event is InputEventKey:
		var key_event := event as InputEventKey
		data["type"] = "key"
		data["physical_keycode"] = int(key_event.physical_keycode)
		data["keycode"] = int(key_event.keycode)
		_store_modifiers(data, key_event)
	elif event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		data["type"] = "mouse"
		data["button"] = int(mouse_event.button_index)
		_store_modifiers(data, mouse_event)
	return data


func _store_modifiers(data: Dictionary, event: InputEventWithModifiers) -> void:
	data["ctrl"] = event.ctrl_pressed
	data["alt"] = event.alt_pressed
	data["shift"] = event.shift_pressed
	data["meta"] = event.meta_pressed


func _event_from_data(data: Variant) -> InputEvent:
	if not data is Dictionary:
		return null
	var saved := data as Dictionary
	var event: InputEvent
	match String(saved.get("type", "")):
		"key":
			var key_event := InputEventKey.new()
			key_event.physical_keycode = int(saved.get("physical_keycode", 0))
			key_event.keycode = int(saved.get("keycode", 0))
			event = key_event
		"mouse":
			var mouse_event := InputEventMouseButton.new()
			mouse_event.button_index = int(saved.get("button", MOUSE_BUTTON_NONE))
			event = mouse_event
		_:
			return null
	var modified := event as InputEventWithModifiers
	modified.ctrl_pressed = bool(saved.get("ctrl", false))
	modified.alt_pressed = bool(saved.get("alt", false))
	modified.shift_pressed = bool(saved.get("shift", false))
	modified.meta_pressed = bool(saved.get("meta", false))
	return _normalize_event(event)


func _event_label(event: InputEvent) -> String:
	var parts := PackedStringArray()
	var modified := event as InputEventWithModifiers
	if modified.meta_pressed:
		parts.append("Cmd" if OS.get_name() == "macOS" else "Meta")
	if modified.ctrl_pressed:
		parts.append("Ctrl")
	if modified.alt_pressed:
		parts.append("Alt")
	if modified.shift_pressed:
		parts.append("Shift")

	if event is InputEventKey:
		var key_event := event as InputEventKey
		var code := (key_event.physical_keycode
			if key_event.physical_keycode != 0 else key_event.keycode)
		var key_label := OS.get_keycode_string(code)
		parts.append(key_label if not key_label.is_empty() else "Key %d" % code)
	elif event is InputEventMouseButton:
		parts.append(_mouse_button_label((event as InputEventMouseButton).button_index))
	return " + ".join(parts)


func _mouse_button_label(button: MouseButton) -> String:
	match button:
		MOUSE_BUTTON_LEFT:
			return "Mouse Left"
		MOUSE_BUTTON_RIGHT:
			return "Mouse Right"
		MOUSE_BUTTON_MIDDLE:
			return "Mouse Middle"
		MOUSE_BUTTON_WHEEL_UP:
			return "Wheel Up"
		MOUSE_BUTTON_WHEEL_DOWN:
			return "Wheel Down"
		MOUSE_BUTTON_WHEEL_LEFT:
			return "Wheel Left"
		MOUSE_BUTTON_WHEEL_RIGHT:
			return "Wheel Right"
		MOUSE_BUTTON_XBUTTON1:
			return "Mouse 4"
		MOUSE_BUTTON_XBUTTON2:
			return "Mouse 5"
		_:
			return "Mouse %d" % button


func _ensure_audio_buses() -> void:
	_ensure_audio_bus(&"SFX")
	_ensure_audio_bus(&"Ambience")
	_ensure_audio_bus(&"Voice")


func _ensure_audio_bus(bus_name: StringName) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	AudioServer.add_bus()
	var index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, &"Master")


func _apply_all_volumes() -> void:
	_apply_bus_volume(&"Master", master_volume)
	_apply_bus_volume(&"SFX", sfx_volume)
	_apply_bus_volume(&"Ambience", ambience_volume)
	_apply_bus_volume(&"Voice", voice_volume)


func _apply_bus_volume(bus_name: StringName, linear: float) -> void:
	_ensure_audio_buses()
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	var muted := linear <= 0.0
	AudioServer.set_bus_mute(index, muted)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(linear, MIN_AUDIBLE_LINEAR)))
