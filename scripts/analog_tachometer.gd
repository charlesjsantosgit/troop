class_name AnalogTachometer
extends Control
## Compact true-RPM dashboard tachometer. The needle is driven by the engine's
## actual crank RPM against a zero-based dial; idle therefore reads at its real
## place instead of becoming the old bar's misleading zero.

var rpm := 0.0
var redline_rpm := 6000.0
var limiter_rpm := 6300.0
var scale_max_rpm := 7000.0
var needle_fraction := 0.0
var redline_fraction := 0.0
var needle_angle_radians := 0.0

const START_ANGLE := deg_to_rad(135.0)
const SWEEP_ANGLE := deg_to_rad(270.0)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func set_reading(new_rpm: float, new_redline: float,
		new_limiter: float) -> void:
	rpm = maxf(new_rpm, 0.0)
	redline_rpm = maxf(new_redline, 1.0)
	limiter_rpm = maxf(new_limiter, redline_rpm)
	scale_max_rpm = maxf(1000.0, ceilf(limiter_rpm / 1000.0) * 1000.0)
	needle_fraction = clampf(rpm / scale_max_rpm, 0.0, 1.0)
	redline_fraction = clampf(redline_rpm / scale_max_rpm, 0.0, 1.0)
	needle_angle_radians = START_ANGLE + SWEEP_ANGLE * needle_fraction
	queue_redraw()


func _draw() -> void:
	var centre := Vector2(size.x * 0.5, size.y * 0.54)
	var radius := minf(size.x, size.y) * 0.43
	var start_angle := START_ANGLE
	var sweep := SWEEP_ANGLE
	var face := Color(0.025, 0.045, 0.03, 0.96)
	var ink := Color(0.82, 0.90, 0.78)
	var muted := Color(0.44, 0.55, 0.43)
	var red := Color(0.96, 0.22, 0.12)
	var gold := Color(0.96, 0.77, 0.24)
	draw_circle(centre, radius + 5.0, face)
	draw_arc(centre, radius + 4.0, 0.0, TAU, 48, gold, 2.0, true)
	draw_arc(centre, radius, start_angle, start_angle + sweep,
		40, muted, 2.0, true)
	var red_fraction := redline_fraction
	draw_arc(centre, radius, start_angle + sweep * red_fraction,
		start_angle + sweep, 16, red, 3.0, true)

	var thousands := maxi(1, ceili(scale_max_rpm / 1000.0))
	var subdivisions := thousands * 5
	for index in range(subdivisions + 1):
		var fraction := float(index) / float(subdivisions)
		var angle := start_angle + sweep * fraction
		var direction := Vector2(cos(angle), sin(angle))
		var major := index % 5 == 0
		var tick_length := 8.0 if major else 4.0
		var tick_color := red if fraction >= red_fraction else ink
		draw_line(centre + direction * (radius - tick_length),
			centre + direction * radius, tick_color, 2.0 if major else 1.0,
			true)
		if major:
			var label := str(floori(float(index) / 5.0))
			var font := ThemeDB.fallback_font
			var label_size := font.get_string_size(label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9)
			var label_centre := centre + direction * (radius - 17.0)
			draw_string(font,
				label_centre + Vector2(-label_size.x * 0.5, label_size.y * 0.35),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, tick_color)

	var needle_angle := needle_angle_radians
	var needle_direction := Vector2(cos(needle_angle), sin(needle_angle))
	draw_line(centre, centre + needle_direction * (radius - 12.0),
		red if rpm >= redline_rpm else gold, 3.0, true)
	draw_circle(centre, 4.0, ink)
	var reading := "%d RPM" % roundi(rpm)
	var reading_size := ThemeDB.fallback_font.get_string_size(reading,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10)
	draw_string(ThemeDB.fallback_font,
		centre + Vector2(-reading_size.x * 0.5, radius * 0.52), reading,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, ink)
