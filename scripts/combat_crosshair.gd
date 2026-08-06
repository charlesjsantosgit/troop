class_name CombatCrosshair
extends Control
## Clean weapon-specific reticle. The shotgun ring is sized from its actual
## three-degree pellet cone and the active camera FOV.

enum Mode { PLUS, SHOTGUN }

var mode: int = Mode.PLUS
var ring_radius := 30.0
var reticle_color := Color(1.0, 1.0, 1.0, 0.92)
var aiming := false
var recoil_bloom := 0.0
var accuracy_radius := 0.0


func set_state(next_mode: int, radius: float, color: Color,
		is_aiming: bool, recoil: float, spread_radius_pixels := 0.0) -> void:
	mode = next_mode
	# These dimensions are ballistic telemetry, not decorative animation. Apply
	# them immediately so a speed/state change can never leave a stale cone.
	ring_radius = radius
	reticle_color = reticle_color.lerp(color, 0.3)
	aiming = is_aiming
	recoil_bloom = lerpf(recoil_bloom, recoil, 0.35)
	accuracy_radius = maxf(spread_radius_pixels, 0.0)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	if mode == Mode.SHOTGUN:
		# Keep geometry exact: animation never changes the real pellet cone.
		var radius := ring_radius
		draw_arc(center, radius, 0.0, TAU, 64,
			Color(0.0, 0.0, 0.0, 0.72), 4.0, true)
		draw_arc(center, radius, 0.0, TAU, 64, reticle_color, 1.6, true)
		draw_circle(center, 3.0, Color(0.0, 0.0, 0.0, 0.8))
		draw_circle(center, 1.45, reticle_color)
		for angle in [0.0, PI * 0.5, PI, PI * 1.5]:
			var direction := Vector2(cos(angle), sin(angle))
			draw_line(center + direction * (radius + 3.0),
				center + direction * (radius + 7.0),
				reticle_color, 1.5, true)
		return

	# Compact precision cross: the center dot is the exact stationary impact
	# line. Movement separates the four short arms to visualize real spread.
	var gap := maxf(2.6, accuracy_radius)
	var arm_length := 4.0 if aiming else 5.0
	var thickness := 1.35
	var shadow := Color(0.0, 0.0, 0.0, 0.78)
	for direction in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		draw_line(center + direction * gap,
			center + direction * (gap + arm_length),
			shadow, thickness + 2.4, true)
		draw_line(center + direction * gap,
			center + direction * (gap + arm_length),
			reticle_color, thickness, true)
	draw_circle(center, 2.2, shadow)
	draw_circle(center, 0.95, reticle_color)
