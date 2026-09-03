class_name SniperScopeOverlay
extends Control
## Full-screen optical scope presentation. HUD owns target acquisition and feeds
## this control a simple, testable state through set_scope_state().

const TARGET_NONE := 0
const TARGET_BODY := 1
const TARGET_HEAD := 2
# Must match CameraRig.FIRST_PERSON_FOV: the hold bracket converts the physical
# ballistic angle into its correct pixel offset at every optic setting.
const BASE_CAMERA_FOV := 82.0

const RETICLE_COLOR := Color(0.72, 0.94, 0.66, 0.88)
const RETICLE_DIM := Color(0.52, 0.72, 0.48, 0.62)
const READOUT_COLOR := Color(0.80, 1.0, 0.70, 0.96)
const HOLD_COLOR := Color(1.0, 0.78, 0.20, 0.96)
const TARGET_COLOR := Color(1.0, 0.08, 0.035, 1.0)

const VIGNETTE_SHADER := """
shader_type canvas_item;
render_mode unshaded;

uniform vec2 viewport_size = vec2(1600.0, 900.0);
uniform float aperture_radius = 395.0;

void fragment() {
	vec2 pixel = (UV - vec2(0.5)) * viewport_size;
	float radial = length(pixel);
	float outside = smoothstep(aperture_radius - 1.5, aperture_radius + 1.5, radial);
	float edge = smoothstep(aperture_radius * 0.70, aperture_radius, radial)
		* (1.0 - outside) * 0.20;
	float alpha = clamp(outside + edge, 0.0, 1.0);
	COLOR = vec4(0.001, 0.004, 0.002, alpha);
}
"""

# Recreated HUDs share only immutable source, never viewport/aperture uniforms.
static var _vignette_shader: Shader

var _active := false
var _magnification := 2.5
var _range_m := 0.0
var _drop_m := 0.0
var _target_zone := TARGET_NONE
var _blink_time := 0.0
var _vignette: ColorRect
var _vignette_material: ShaderMaterial


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette = ColorRect.new()
	_vignette.name = "OpticalVignette"
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.show_behind_parent = true
	_vignette.color = Color.WHITE
	if not _vignette_shader:
		_vignette_shader = Shader.new()
		_vignette_shader.code = VIGNETTE_SHADER
	_vignette_material = ShaderMaterial.new()
	_vignette_material.shader = _vignette_shader
	_vignette.material = _vignette_material
	add_child(_vignette)
	_sync_geometry()
	visible = false
	set_process(false)


## target_zone uses TARGET_NONE/TARGET_BODY/TARGET_HEAD (mirrored by
## HUD.ScopeTarget) so diagnostics can drive the overlay without a game world.
func set_scope_state(active: bool, magnification: float, range_m: float,
		drop_m: float, target_zone := TARGET_NONE) -> void:
	_active = active
	_magnification = maxf(magnification, 1.0)
	_range_m = maxf(range_m, 0.0)
	_drop_m = drop_m
	_target_zone = clampi(target_zone, TARGET_NONE, TARGET_HEAD)
	visible = active
	set_process(active and _target_zone == TARGET_HEAD)
	queue_redraw()


func clear_scope() -> void:
	set_scope_state(false, _magnification, _range_m, _drop_m, TARGET_NONE)


func _process(dt: float) -> void:
	_blink_time = fmod(_blink_time + dt, 1.0)
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_instance_valid(_vignette_material):
		_sync_geometry()
		queue_redraw()


func _sync_geometry() -> void:
	if not is_instance_valid(_vignette_material):
		return
	var radius := minf(size.x, size.y) * 0.44
	_vignette_material.set_shader_parameter("viewport_size", size)
	_vignette_material.set_shader_parameter("aperture_radius", radius)


func _draw() -> void:
	if not _active or size.x <= 1.0 or size.y <= 1.0:
		return
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.44
	var line_width := maxf(1.0, radius / 390.0)

	# A restrained green lens cast and concentric edge reflections keep the
	# scope readable without obscuring targets in the aperture.
	draw_circle(center, radius - 1.0, Color(0.015, 0.085, 0.035, 0.055))
	draw_arc(center, radius, 0.0, TAU, 160, Color(0.02, 0.03, 0.02, 0.98), 5.0)
	draw_arc(center, radius - 3.0, 0.0, TAU, 160, RETICLE_DIM, line_width)
	draw_arc(center, radius * 0.985, 0.0, TAU, 160,
		Color(0.50, 0.86, 0.42, 0.18), line_width)

	_draw_crosshair(center, radius, line_width)
	_draw_holdover(center, radius, line_width)
	_draw_readouts(center, radius)
	_draw_target_dot(center, radius)


func _draw_crosshair(center: Vector2, radius: float, line_width: float) -> void:
	var gap := maxf(7.0, radius * 0.017)
	var extent := radius * 0.93
	draw_line(center + Vector2(-extent, 0.0), center + Vector2(-gap, 0.0),
		RETICLE_COLOR, line_width, true)
	draw_line(center + Vector2(gap, 0.0), center + Vector2(extent, 0.0),
		RETICLE_COLOR, line_width, true)
	draw_line(center + Vector2(0.0, -extent), center + Vector2(0.0, -gap),
		RETICLE_COLOR, line_width, true)
	draw_line(center + Vector2(0.0, gap), center + Vector2(0.0, extent),
		RETICLE_COLOR, line_width, true)

	# Even angular subdivisions: long marks at the major stadia and compact
	# half-marks between them. The lower tree is intentionally more prominent
	# because the ballistic readout asks the player to hold above distant shots.
	for step in range(-8, 9):
		if step == 0:
			continue
		var offset := radius * 0.09 * step
		var tick := radius * (0.031 if absi(step) % 2 == 0 else 0.018)
		draw_line(center + Vector2(offset, -tick), center + Vector2(offset, tick),
			RETICLE_DIM, line_width, true)
	for step in range(-8, 9):
		if step == 0:
			continue
		var offset := radius * 0.09 * step
		var tick := radius * (0.035 if absi(step) % 2 == 0 else 0.021)
		draw_line(center + Vector2(-tick, offset), center + Vector2(tick, offset),
			RETICLE_DIM, line_width, true)


func _draw_holdover(center: Vector2, radius: float, line_width: float) -> void:
	if _range_m < 1.0:
		return
	var hold_pixels := hold_offset_pixels(radius, _range_m, _drop_m,
		_magnification)
	# Put the target on a lower stadia mark so the central dot—and therefore the
	# barrel—is held above it by the predicted amount.
	var hold_y := center.y + clampf(hold_pixels, -radius * 0.68, radius * 0.68)
	if absf(hold_y - center.y) < 3.0:
		return
	var guide_color := Color(HOLD_COLOR.r, HOLD_COLOR.g, HOLD_COLOR.b, 0.42)
	_draw_dashed_line(Vector2(center.x, center.y), Vector2(center.x, hold_y),
		guide_color, line_width, maxf(5.0, radius * 0.018))
	var bracket_half := radius * 0.034
	draw_line(Vector2(center.x - bracket_half, hold_y),
		Vector2(center.x + bracket_half, hold_y), HOLD_COLOR,
		maxf(line_width, 1.35), true)
	draw_line(Vector2(center.x - bracket_half, hold_y - 4.0),
		Vector2(center.x - bracket_half, hold_y + 4.0), HOLD_COLOR,
		line_width, true)
	draw_line(Vector2(center.x + bracket_half, hold_y - 4.0),
		Vector2(center.x + bracket_half, hold_y + 4.0), HOLD_COLOR,
		line_width, true)


## Screen-space ballistic correction. Positive drop is deliberately positive Y:
## the target belongs below the center dot so the player holds the barrel high.
static func hold_offset_pixels(radius: float, range_m: float, drop_m: float,
		magnification: float) -> float:
	var hold_angle := atan2(drop_m, maxf(range_m, 0.1))
	var scope_half_angle := atan(tan(deg_to_rad(BASE_CAMERA_FOV * 0.5)) /
		maxf(magnification, 1.0))
	return hold_angle / maxf(scope_half_angle, 0.001) * radius


func _draw_dashed_line(from: Vector2, to: Vector2, color: Color,
		width: float, dash_length: float) -> void:
	var travel := to - from
	var distance := travel.length()
	if distance <= 0.01:
		return
	var direction := travel / distance
	var cursor := 0.0
	while cursor < distance:
		var segment_end := minf(cursor + dash_length, distance)
		draw_line(from + direction * cursor, from + direction * segment_end,
			color, width, true)
		cursor += dash_length * 2.0


func _draw_readouts(center: Vector2, radius: float) -> void:
	var font := ThemeDB.fallback_font
	var small_size := maxi(11, roundi(radius * 0.033))
	var large_size := maxi(14, roundi(radius * 0.043))
	var zoom_text := "%.1f×" % _magnification
	var zoom_width := font.get_string_size(zoom_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, large_size).x
	draw_string(font, Vector2(center.x - zoom_width * 0.5,
		center.y - radius * 0.78), zoom_text, HORIZONTAL_ALIGNMENT_LEFT,
		-1.0, large_size, READOUT_COLOR)

	var range_text := "RANGE  %03d m" % roundi(_range_m)
	var hold_mil := absf(atan2(_drop_m, maxf(_range_m, 0.1))) * 1000.0
	var correction_text := "75 m ZERO"
	if absf(_drop_m) >= 0.015:
		correction_text = "%s %.2f m  ·  HOLD %.1f MIL %s" % [
			"DROP" if _drop_m > 0.0 else "RISE", absf(_drop_m), hold_mil,
			"HIGH" if _drop_m > 0.0 else "LOW"]
	var baseline_y := center.y + radius * 0.78
	draw_string(font, Vector2(center.x - radius * 0.72, baseline_y), range_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, small_size, READOUT_COLOR)
	var correction_width := font.get_string_size(correction_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, small_size).x
	draw_string(font, Vector2(center.x + radius * 0.72 - correction_width,
		baseline_y), correction_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		small_size, HOLD_COLOR if absf(_drop_m) >= 0.015 else RETICLE_DIM)


func _draw_target_dot(center: Vector2, radius: float) -> void:
	var dot_color := RETICLE_COLOR
	var dot_radius := target_dot_radius(radius, _target_zone)
	if _target_zone == TARGET_BODY:
		dot_color = TARGET_COLOR
	elif _target_zone == TARGET_HEAD:
		# A head acquisition is smaller than the body cue and pulses quickly,
		# leaving the exact impact point visible throughout the blink.
		var pulse := 0.5 + 0.5 * sin(_blink_time * TAU * 4.0)
		dot_color = Color(TARGET_COLOR.r, TARGET_COLOR.g, TARGET_COLOR.b,
			0.28 + pulse * 0.72)
	draw_circle(center, dot_radius + 2.0,
		Color(0.0, 0.0, 0.0, 0.68 if _target_zone != TARGET_NONE else 0.42))
	draw_circle(center, dot_radius, dot_color)
	if _target_zone == TARGET_HEAD:
		draw_arc(center, dot_radius + 6.0, 0.0, TAU, 24, dot_color, 1.0)


static func target_dot_radius(radius: float, target_zone: int) -> float:
	if target_zone == TARGET_BODY:
		return maxf(4.2, radius * 0.013)
	if target_zone == TARGET_HEAD:
		return maxf(2.3, radius * 0.0075)
	return maxf(2.2, radius * 0.010)
