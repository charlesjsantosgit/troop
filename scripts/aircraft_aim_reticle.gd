class_name AircraftAimReticle
extends Control
## Aircraft mouse-pursuit sight. The outer ring is the maximum virtual-stick
## travel and the bright dot is the exact normalized command sent to the jet.

const RING_RADIUS := 64.0
const DOT_RADIUS := 5.0
const DOT_TRAVEL_RADIUS := 55.0

var normalized_aim := Vector2.ZERO
var dot_offset := Vector2.ZERO
var ring_color := Color(0.78, 1.0, 0.48, 0.92)


func set_aim(next_aim: Vector2) -> void:
	normalized_aim = next_aim.limit_length(1.0)
	dot_offset = normalized_aim * DOT_TRAVEL_RADIUS
	queue_redraw()


func dot_center() -> Vector2:
	return size * 0.5 + dot_offset


func _draw() -> void:
	var center := size * 0.5
	var shadow := Color(0.0, 0.0, 0.0, 0.78)
	# The heavy dark underlay keeps the boundary readable against snow, cloud,
	# jungle, and sky without turning the sight into an opaque dashboard widget.
	draw_arc(center, RING_RADIUS, 0.0, TAU, 96, shadow, 4.8, true)
	draw_arc(center, RING_RADIUS, 0.0, TAU, 96, ring_color, 1.8, true)
	for direction in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		draw_line(center + direction * (RING_RADIUS - 5.0),
			center + direction * (RING_RADIUS + 5.0), shadow, 4.0, true)
		draw_line(center + direction * (RING_RADIUS - 5.0),
			center + direction * (RING_RADIUS + 5.0), ring_color, 1.5, true)
	# A faint centre datum shows the aircraft nose while the larger solid dot
	# moves toward the requested pursuit direction.
	draw_circle(center, 2.8, shadow)
	draw_circle(center, 1.25, Color(ring_color, 0.55))
	var dot := dot_center()
	if dot_offset.length_squared() > 4.0:
		draw_line(center, dot, Color(0.0, 0.0, 0.0, 0.42), 3.0, true)
		draw_line(center, dot, Color(ring_color, 0.25), 1.0, true)
	draw_circle(dot, DOT_RADIUS + 2.4, shadow)
	draw_circle(dot, DOT_RADIUS, Color(1.0, 1.0, 0.84, 0.98))
	draw_circle(dot - Vector2(1.2, 1.2), 1.45, Color(1.0, 1.0, 1.0, 0.98))
