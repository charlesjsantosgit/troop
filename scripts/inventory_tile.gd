class_name TroopInventoryTile
extends Button
## Opaque, keyboard-friendly inventory tile shared by trading and the backpack.
const MenuTheme := preload("res://scripts/menu_theme.gd")
var item_id := ""
var item_name := ""
var category := ""
var count := 0
var selected := false
var _name_label: Label
var _count_label: Label
var _glyph: ItemGlyph
var _motion: Tween

func _ready() -> void:
	custom_minimum_size = Vector2(106, 88)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column)
	_glyph = ItemGlyph.new()
	_glyph.custom_minimum_size.y = 22
	_glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_glyph)
	_name_label = MenuTheme.label(item_name, 12)
	_name_label.custom_minimum_size.y = 28
	_name_label.max_lines_visible = 2
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	column.add_child(_name_label)
	_count_label = MenuTheme.label("", 12, MenuTheme.MUTED)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_count_label)
	mouse_entered.connect(_animate_attention)
	mouse_exited.connect(_animate_attention)
	focus_entered.connect(_animate_attention)
	focus_exited.connect(_animate_attention)
	resized.connect(func(): pivot_offset = size * 0.5)
	pivot_offset = size * 0.5
	_refresh()

func configure(id: String, label: String, amount: int, group: String) -> void:
	item_id = id
	item_name = label
	count = amount
	category = group
	set_meta("inventory_item", id)
	_refresh()

func set_item_count(amount: int) -> void:
	if count == amount:
		return
	count = amount
	_refresh()

func set_selected(value: bool) -> void:
	if selected == value:
		return
	selected = value
	_refresh()
	_animate_attention()

func _refresh() -> void:
	if not is_node_ready():
		return
	_name_label.text = item_name
	_count_label.text = "×%d" % count
	tooltip_text = "%s · %d · %s" % [item_name, count, category]
	_glyph.item_id = item_id
	_glyph.category = category
	_glyph.queue_redraw()
	var normal := MenuTheme.panel(Color("453e32") if selected else MenuTheme.INSET,
		MenuTheme.ACCENT if selected else MenuTheme.BORDER, 0, 10)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color("504737") if selected else Color("39434f")
	hover.border_color = MenuTheme.ACCENT if selected else MenuTheme.SECONDARY
	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.bg_color = Color("5a4d37")
	var focused := MenuTheme.panel(Color(0,0,0,0), MenuTheme.ACCENT, 0, 10)
	focused.set_border_width_all(2)
	add_theme_stylebox_override("normal", normal)
	add_theme_stylebox_override("hover", hover)
	add_theme_stylebox_override("pressed", pressed)
	add_theme_stylebox_override("focus", focused)

func _animate_attention() -> void:
	if not is_node_ready() or DisplayServer.get_name() == "headless":
		return
	if _motion and _motion.is_valid():
		_motion.kill()
	_motion = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var target := Vector2.ONE * (1.025 if is_hovered() or has_focus() else 1.0)
	_motion.tween_property(self, "scale", target, 0.14)

class ItemGlyph:
	extends Control
	var item_id := ""
	var category := ""

	func _draw() -> void:
		var c := size * 0.5
		var amber := Color("e9bc74")
		var leaf := Color("a5b889")
		var blue := Color("9bb8d5")
		if item_id == "water":
			draw_colored_polygon(PackedVector2Array([c+Vector2(0,-10),c+Vector2(-7,2),c+Vector2(-5,8),c+Vector2(4,9),c+Vector2(8,3)]), blue)
			draw_line(c+Vector2(-3,2),c+Vector2(-2,5),Color.WHITE,1.5,true)
		elif item_id == "banana":
			draw_arc(c+Vector2(0,-6),12,0.2,2.7,18,amber,5,true)
			draw_line(c+Vector2(-10,-1),c+Vector2(-12,-5),Color("9d7951"),3,true)
		elif category == "Crops":
			var fruit := Color("e59d86") if item_id in ["tomato","sweet_potato","radish"] else amber if item_id in ["corn","rice","wheat"] else leaf
			draw_circle(c+Vector2(0,3),7,fruit)
			draw_line(c+Vector2(0,-3),c+Vector2(1,-10),leaf,2,true)
			draw_colored_polygon(PackedVector2Array([c+Vector2(0,-5),c+Vector2(8,-10),c+Vector2(7,-4)]),leaf)
		elif category == "Planting":
			draw_style_box(MenuTheme.panel(Color("78654b"),amber,0,2),Rect2(c-Vector2(8,8),Vector2(16,18)))
			draw_line(c+Vector2(0,6),c+Vector2(0,-3),leaf,2,true)
			draw_circle(c+Vector2(-3,-2),3,leaf)
			draw_circle(c+Vector2(3,-5),3,leaf)
		elif category == "Fuel":
			draw_style_box(MenuTheme.panel(Color("80704d"),amber,0,2),Rect2(c-Vector2(7,7),Vector2(14,16)))
			draw_line(c+Vector2(-3,-8),c+Vector2(4,-8),amber,3,true)
			draw_line(c+Vector2(5,-7),c+Vector2(10,-10),amber,3,true)
			draw_line(c+Vector2(-4,5),c+Vector2(4,-3),amber,1.5,true)
		elif category == "Food":
			draw_arc(c+Vector2(0,-2),9,0,PI,16,amber,5,true)
			draw_line(c+Vector2(-10,-2),c+Vector2(10,-2),leaf,2,true)
		else:
			draw_style_box(MenuTheme.panel(Color("586471"),blue,0,2),Rect2(c-Vector2(10,7),Vector2(20,15)))
			draw_line(c+Vector2(-3,-7),c+Vector2(-3,8),blue,2,true)
			draw_line(c+Vector2(4,-7),c+Vector2(4,8),blue,2,true)
