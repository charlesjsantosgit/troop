class_name TroopMenuTheme
extends RefCounted
## One quiet, readable visual language for every player menu.

const INK := Color("15181d")
const PANEL := Color("23282f")
const INSET := Color("2e353e")
const TEXT := Color("f3f0e8")
const MUTED := Color("b0b6be")
const ACCENT := Color("e9bc74")
const SECONDARY := Color("9bb8d5")
const BORDER := Color("49515c")
const DANGER := Color("efab99")

static func panel(fill: Color = PANEL, border: Color = BORDER,
		padding: int = 20, radius: int = 12) -> StyleBoxFlat:
	var result := StyleBoxFlat.new()
	result.bg_color = fill
	result.border_color = border
	result.set_border_width_all(1)
	result.set_corner_radius_all(radius)
	result.set_content_margin_all(padding)
	return result

static func label(text: String, size: int = 16, color: Color = TEXT) -> Label:
	var result := Label.new()
	result.text = text
	result.add_theme_font_size_override("font_size", size)
	result.add_theme_color_override("font_color", color)
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return result

static func style_button(button: Button, primary: bool = false) -> void:
	button.custom_minimum_size.y = maxf(button.custom_minimum_size.y, 42)
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var normal := panel(ACCENT if primary else INSET, ACCENT if primary else BORDER, 12, 8)
	normal.content_margin_top = 9
	normal.content_margin_bottom = 9
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = ACCENT.lightened(0.1) if primary else Color("3a4551")
	hover.border_color = ACCENT if primary else SECONDARY
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = ACCENT.darkened(0.12) if primary else Color("404b58")
	var focus := panel(Color(0, 0, 0, 0), ACCENT, 0, 8)
	focus.set_border_width_all(2)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color("20252c")
	disabled.border_color = Color("353d47")
	for pair in [["normal", normal], ["hover", hover], ["pressed", pressed], ["focus", focus], ["disabled", disabled]]:
		button.add_theme_stylebox_override(pair[0], pair[1])
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, INK if primary else TEXT)
	button.add_theme_color_override("font_disabled_color", Color("818994"))
	button.add_theme_font_size_override("font_size", 16)

static func build() -> Theme:
	var result := Theme.new()
	result.default_font_size = 16
	for type in ["Label", "Button", "CheckButton", "CheckBox", "OptionButton", "LineEdit", "TextEdit", "RichTextLabel", "SpinBox", "TabBar"]:
		result.set_color("font_color", type, TEXT)
		result.set_color("font_hover_color", type, TEXT)
		result.set_color("font_focus_color", type, TEXT)
		result.set_color("font_disabled_color", type, MUTED.darkened(0.25))
	result.set_constant("separation", "VBoxContainer", 12)
	result.set_constant("separation", "HBoxContainer", 12)
	result.set_constant("h_separation", "GridContainer", 12)
	result.set_constant("v_separation", "GridContainer", 12)
	result.set_stylebox("panel", "PanelContainer", panel())
	var sample := Button.new()
	style_button(sample)
	for type in ["Button", "OptionButton"]:
		for state in ["normal", "hover", "pressed", "focus", "disabled"]:
			result.set_stylebox(state, type, sample.get_theme_stylebox(state))
	sample.free()
	for type in ["LineEdit", "TextEdit"]:
		result.set_stylebox("normal", type, panel(INK, BORDER, 12, 8))
		result.set_stylebox("focus", type, panel(Color(0,0,0,0), SECONDARY, 0, 8))
		result.set_color("caret_color", type, ACCENT)
		result.set_color("font_placeholder_color", type, MUTED)
		result.set_color("selection_color", type, Color("4d6278"))
	result.set_stylebox("panel", "PopupMenu", panel(PANEL, BORDER, 8, 8))
	result.set_stylebox("hover", "PopupMenu", panel(INSET, SECONDARY, 8, 6))
	result.set_color("font_color", "PopupMenu", TEXT)
	result.set_constant("v_separation", "PopupMenu", 12)
	result.set_stylebox("panel", "TabContainer", panel(PANEL, BORDER, 16, 10))
	for type in ["TabBar", "TabContainer"]:
		result.set_stylebox("tab_selected", type, panel(INSET, SECONDARY, 12, 6))
		result.set_stylebox("tab_unselected", type, panel(INK, BORDER, 12, 6))
		result.set_stylebox("tab_hovered", type, panel(INSET, SECONDARY, 12, 6))
		result.set_color("font_selected_color", type, ACCENT)
		result.set_color("font_unselected_color", type, MUTED)
		result.set_color("font_hovered_color", type, TEXT)
	result.set_stylebox("scroll", "VScrollBar", panel(INK, INK, 3, 4))
	result.set_stylebox("grabber", "VScrollBar", panel(BORDER, BORDER, 3, 4))
	result.set_stylebox("grabber_highlight", "VScrollBar", panel(SECONDARY, SECONDARY, 3, 4))
	result.set_stylebox("grabber_pressed", "VScrollBar", panel(ACCENT, ACCENT, 3, 4))
	result.set_stylebox("slider", "HSlider", panel(INK, BORDER, 3, 3))
	result.set_stylebox("grabber_area", "HSlider", panel(SECONDARY, SECONDARY, 3, 3))
	result.set_stylebox("grabber_area_highlight", "HSlider", panel(ACCENT, ACCENT, 3, 3))
	return result
