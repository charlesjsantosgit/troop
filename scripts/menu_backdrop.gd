class_name MenuBackdrop
extends Control
## Lightweight procedural menu art. It stays crisp at any viewport size and
## gives the lobby a jungle identity without requiring texture assets.

var _time := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(dt: float) -> void:
	_time += dt
	queue_redraw()


func _draw() -> void:
	var s := size
	if s.x < 1.0 or s.y < 1.0:
		return
	# Sky and a warm canopy opening behind the title.
	draw_rect(Rect2(Vector2.ZERO, s), Color("071a16"))
	draw_circle(Vector2(s.x * 0.73, s.y * 0.27), minf(s.x, s.y) * 0.19, Color(0.95, 0.78, 0.31, 0.14))
	draw_circle(Vector2(s.x * 0.73, s.y * 0.27), minf(s.x, s.y) * 0.12, Color(1.0, 0.9, 0.55, 0.07))

	# Distant hills, then darker foreground canopy layers.
	_draw_hills(s, 0.55, Color("123f31"), 0.045)
	_draw_hills(s, 0.67, Color("0b3027"), 0.075)
	_draw_hills(s, 0.80, Color("071f1a"), 0.10)
	_draw_leaves(s)
	_draw_vines(s)
	_draw_fireflies(s)


func _draw_hills(s: Vector2, horizon: float, color: Color, wobble: float) -> void:
	var points := PackedVector2Array([Vector2(0, s.y)])
	var steps := 16
	for i in range(steps + 1):
		var x := s.x * float(i) / float(steps)
		var wave := sin(float(i) * 1.63 + _time * 0.08) * s.y * wobble
		var ridge := sin(float(i) * 0.73 + 1.2) * s.y * wobble * 0.8
		points.append(Vector2(x, s.y * horizon + wave + ridge))
	points.append(Vector2(s.x, s.y))
	draw_colored_polygon(points, color)


func _draw_leaves(s: Vector2) -> void:
	for i in range(28):
		var seed := float(i) * 1.731
		var side := -0.08 if i % 2 == 0 else 1.08
		var y := s.y * (0.03 + fmod(seed * 0.173, 0.93))
		var x := s.x * (side + sin(seed * 2.7) * 0.055)
		var leaf_size := minf(s.x, s.y) * (0.055 + fmod(seed, 0.045))
		var lean := 1.0 if side < 0.0 else -1.0
		var sway := sin(_time * 0.7 + seed) * leaf_size * 0.12
		var leaf := PackedVector2Array([
			Vector2(x, y),
			Vector2(x + lean * leaf_size * 1.25, y - leaf_size * 0.32 + sway),
			Vector2(x + lean * leaf_size * 1.55, y + leaf_size * 0.28 + sway),
			Vector2(x + lean * leaf_size * 0.32, y + leaf_size * 0.64),
		])
		var tint := Color("164f36") if i % 3 else Color("1d6340")
		draw_colored_polygon(leaf, tint)


func _draw_vines(s: Vector2) -> void:
	for i in range(7):
		var x := s.x * (0.06 + float(i) * 0.155)
		var length := s.y * (0.18 + float(i % 4) * 0.07)
		var points := PackedVector2Array()
		for j in range(12):
			var t := float(j) / 11.0
			points.append(Vector2(x + sin(t * 5.0 + _time * 0.7 + i) * s.x * 0.018, t * length))
		draw_polyline(points, Color(0.14, 0.38, 0.22, 0.55), 2.0, true)


func _draw_fireflies(s: Vector2) -> void:
	for i in range(34):
		var seed := float(i) * 2.391
		var x := s.x * fmod(seed * 0.173, 1.0) + sin(_time * 0.6 + seed) * 13.0
		var y := s.y * (0.10 + fmod(seed * 0.319, 0.82)) + cos(_time * 0.8 + seed) * 8.0
		var pulse := 0.35 + 0.25 * (sin(_time * 2.2 + seed) + 1.0)
		draw_circle(Vector2(x, y), 2.2, Color(0.88, 1.0, 0.48, pulse))
