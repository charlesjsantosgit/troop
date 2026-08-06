class_name ChatBox
extends Control
## In-game text chat: a fading message feed plus an ENTER-to-type input line.
## Opening the input releases the mouse, which the player controller already
## treats as "produce a neutral input frame", so typing WASD never moves the
## monkey. Slash commands are routed to the admin controller instead of sent.

signal command_submitted(text: String)
signal closed

const MAX_LINES := 7
const LINE_LIFETIME := 12.0
const FADE_TIME := 1.5

var _feed: VBoxContainer
var _entry: LineEdit
var _line_ages: Dictionary = {}
var _was_captured := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed = VBoxContainer.new()
	_feed.position = Vector2(14, 96)
	_feed.custom_minimum_size = Vector2(560, 0)
	_feed.add_theme_constant_override("separation", 2)
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_feed)
	_entry = LineEdit.new()
	_entry.placeholder_text = "chat — / for admin commands · ESC closes"
	_entry.max_length = Net.MAX_CHAT_LENGTH
	_entry.position = Vector2(14, 0)
	_entry.custom_minimum_size = Vector2(460, 34)
	_entry.visible = false
	_entry.text_submitted.connect(_on_submitted)
	_entry.add_theme_color_override("font_color", Color(0.95, 0.98, 0.9))
	add_child(_entry)
	Net.chat_received.connect(_on_chat_received)
	resized.connect(_place_entry)
	_place_entry()


func _place_entry() -> void:
	_entry.position = Vector2(14, size.y - 52)


func is_open() -> bool:
	return _entry.visible


func open() -> void:
	if _entry.visible:
		return
	_was_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_entry.visible = true
	_entry.text = ""
	_entry.grab_focus()


func close() -> void:
	if not _entry.visible:
		return
	_entry.visible = false
	_entry.release_focus()
	if _was_captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	closed.emit()


func _input(event: InputEvent) -> void:
	if not _entry.visible:
		return
	if event is InputEventKey and event.pressed \
			and (event.keycode == KEY_ESCAPE
				or event.physical_keycode == KEY_ESCAPE):
		close()
		get_viewport().set_input_as_handled()


func _on_submitted(text: String) -> void:
	var clean := text.strip_edges()
	close()
	if clean.is_empty():
		return
	if clean.begins_with("/"):
		command_submitted.emit(clean)
	else:
		Net.send_chat(clean)


func _on_chat_received(_id: int, sender_name: String, text: String,
		from_admin: bool) -> void:
	var color := Color(1.0, 0.83, 0.30) if from_admin else Color(0.94, 0.97, 0.9)
	var prefix := "[ADMIN] " if from_admin else ""
	_add_line("%s%s:  %s" % [prefix, sender_name, text], color)


## Local feedback lines (command results, join notices) — never networked.
func add_system_line(text: String) -> void:
	_add_line(text, Color(0.62, 0.92, 0.66))


func _add_line(text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 5)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.add_child(label)
	_line_ages[label] = 0.0
	while _feed.get_child_count() > MAX_LINES:
		var oldest := _feed.get_child(0)
		_line_ages.erase(oldest)
		oldest.queue_free()
		_feed.remove_child(oldest)


func _process(dt: float) -> void:
	var dead: Array = []
	for label in _line_ages:
		if not is_instance_valid(label):
			dead.append(label)
			continue
		_line_ages[label] += dt
		var age: float = _line_ages[label]
		if _entry.visible:
			label.modulate.a = 1.0  # reading history while typing
		elif age > LINE_LIFETIME:
			label.modulate.a = maxf(0.0,
				1.0 - (age - LINE_LIFETIME) / FADE_TIME)
			if label.modulate.a <= 0.0:
				dead.append(label)
	for label in dead:
		_line_ages.erase(label)
		if is_instance_valid(label):
			label.queue_free()
