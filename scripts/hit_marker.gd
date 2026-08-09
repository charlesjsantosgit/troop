class_name HitMarker
extends Control
## Brief local-only confirmation drawn when one of this player's projectiles
## intersects another player. Four small diagonal strokes stay clear of the
## weapon crosshair's exact center and fade without allocating a tween per hit.

const HOLD_SECONDS := 0.055
const FADE_SECONDS := 0.12
const STROKE_COLOR := Color(1.0, 0.97, 0.82, 0.98)
const HEADSHOT_COLOR := Color(1.0, 0.70, 0.18, 1.0)

var flash_count := 0
var last_headshot := false
var _remaining := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_process(false)


func flash(headshot := false) -> void:
	flash_count += 1
	last_headshot = headshot
	_remaining = HOLD_SECONDS + FADE_SECONDS
	modulate.a = 1.0
	visible = true
	set_process(true)
	queue_redraw()


func remaining_seconds() -> float:
	return _remaining


func _process(dt: float) -> void:
	_remaining = maxf(_remaining - dt, 0.0)
	if _remaining <= 0.0:
		visible = false
		set_process(false)
		return
	modulate.a = 1.0 if _remaining > FADE_SECONDS \
		else SatisfyingReload.smooth01(_remaining / FADE_SECONDS)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var color := HEADSHOT_COLOR if last_headshot else STROKE_COLOR
	const INNER := 6.0
	const OUTER := 11.0
	for direction in [Vector2(-1, -1), Vector2(1, -1),
			Vector2(-1, 1), Vector2(1, 1)]:
		var unit: Vector2 = direction.normalized()
		draw_line(center + unit * INNER, center + unit * OUTER,
			color, 2.2, true)
