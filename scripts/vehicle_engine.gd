class_name VehicleEngine
extends RefCounted
## Combustion engine + gearbox simulation shared by the ground vehicles.
## Torque comes from a lerped curve, the crank has real inertia so it revs and
## falls believably, a centrifugal-style clutch slips below engagement speed
## so launches work without a clutch lever, and the box shifts itself (with a
## torque-cut) unless the rider takes over with manual shifts.

var torque_curve: Array = []         # [[rpm, Nm], ...] ascending
var idle_rpm := 900.0
var redline_rpm := 6000.0
var limiter_rpm := 6300.0
var inertia := 0.25                  # crank + flywheel, kg*m^2
var gear_ratios: Array = [3.0, 2.0, 1.4, 1.0]
var final_drive := 4.0
var driveline_efficiency := 0.88
var auto_shift := true
var shift_time := 0.24
var engine_brake_coefficient := 0.9  # Nm per rad/s of crank speed over idle
var clutch_engage_rpm := 1900.0      # fully locked above this
var clutch_capacity := 2.2           # x peak torque the clutch can pass

var rpm := 900.0
var gear := 1                        # 1-based; 0 = neutral, -1 = reverse
var reverse_ratio := 0.0             # 0 = no reverse (motorcycle)
var throttle := 0.0
var _shift_cooldown := 0.0           # torque-cut window after a shift
var _shift_lockout := 0.0            # hysteresis: no further shifts yet
var _limiter_cut := 0.0
var peak_torque := 0.0


func configure(config: Dictionary) -> void:
	for key in config:
		set(key, config[key])
	rpm = idle_rpm
	peak_torque = 0.0
	for point in torque_curve:
		peak_torque = maxf(peak_torque, float(point[1]))


func curve_torque(at_rpm: float) -> float:
	if torque_curve.is_empty():
		return 0.0
	if at_rpm <= float(torque_curve[0][0]):
		return float(torque_curve[0][1])
	for i in range(1, torque_curve.size()):
		var hi: Array = torque_curve[i]
		if at_rpm <= float(hi[0]):
			var lo: Array = torque_curve[i - 1]
			var t := (at_rpm - float(lo[0])) / (float(hi[0]) - float(lo[0]))
			return lerpf(float(lo[1]), float(hi[1]), t)
	return float(torque_curve[-1][1])


func total_ratio() -> float:
	if gear == 0:
		return 0.0
	if gear < 0:
		return -reverse_ratio * final_drive
	return float(gear_ratios[clampi(gear, 1, gear_ratios.size()) - 1]) \
		* final_drive


## Advance the engine one tick against the mean driven-wheel speed and return
## the torque delivered to the driven axle (positive = forward drive).
## `wheel_speed` is mean driven wheel angular velocity in rad/s.
func step(dt: float, input_throttle: float, wheel_speed: float,
		ground_speed: float) -> float:
	throttle = clampf(input_throttle, 0.0, 1.0)
	_shift_cooldown = maxf(0.0, _shift_cooldown - dt)
	_shift_lockout = maxf(0.0, _shift_lockout - dt)
	_limiter_cut = maxf(0.0, _limiter_cut - dt)

	var ratio := total_ratio()
	var target_rpm := absf(wheel_speed * ratio) * 60.0 / TAU

	var effective_throttle := throttle
	if _shift_cooldown > 0.0 or _limiter_cut > 0.0:
		effective_throttle = 0.0
	if rpm > limiter_rpm:
		_limiter_cut = 0.07

	var locked := ratio != 0.0 and target_rpm > clutch_engage_rpm
	var delivered := 0.0
	if ratio == 0.0:
		# Neutral: free-rev the crank against its own inertia.
		var crank_torque := curve_torque(rpm) * effective_throttle \
			- engine_brake_coefficient * maxf(rpm - idle_rpm, 0.0) \
			* TAU / 60.0 * 0.05
		rpm += crank_torque / inertia * dt * 60.0 / TAU
		rpm = clampf(rpm, idle_rpm * 0.72, limiter_rpm + 220.0)
	elif locked:
		# Clutch locked: crank speed is slaved to the wheels.
		rpm = clampf(target_rpm, idle_rpm * 0.72, limiter_rpm + 260.0)
		var crank_out := curve_torque(rpm) * effective_throttle
		if throttle < 0.06:
			crank_out -= engine_brake_coefficient \
				* maxf(rpm - idle_rpm, 0.0) * TAU / 60.0 * 0.02
		delivered = crank_out * absf(ratio) * driveline_efficiency \
			* signf(ratio)
	else:
		# Launch: the clutch slips, passing bounded torque while the crank
		# holds near its engagement speed.
		var slip_rpm := clampf(clutch_engage_rpm + throttle * 900.0,
			idle_rpm, redline_rpm * 0.6)
		rpm = lerpf(rpm, slip_rpm, clampf(6.0 * dt, 0.0, 1.0))
		var pass_torque := curve_torque(rpm) * effective_throttle
		pass_torque = minf(pass_torque, peak_torque * clutch_capacity)
		delivered = pass_torque * absf(ratio) * driveline_efficiency \
			* signf(ratio)
		if throttle < 0.04 and absf(ground_speed) < 0.7:
			delivered = 0.0

	if auto_shift and _shift_lockout <= 0.0 and gear >= 1:
		_consider_auto_shift(ground_speed)
	return delivered


## Hysteresis keeps the box from hunting: a lockout after every shift, and an
## upshift only happens when the rpm it would LAND at stays well above the
## downshift line.
func _consider_auto_shift(ground_speed: float) -> void:
	if gear < gear_ratios.size() and rpm > redline_rpm * 0.93 \
			and throttle > 0.25:
		var landing_rpm: float = rpm \
			* float(gear_ratios[gear]) / float(gear_ratios[gear - 1])
		if landing_rpm > redline_rpm * 0.42:
			shift(1)
	elif gear > 1 and rpm < redline_rpm * 0.26 \
			and absf(ground_speed) > 0.5:
		shift(-1)


func shift(direction: int) -> bool:
	var lowest := -1 if reverse_ratio > 0.0 else 1
	var next := clampi(gear + direction, lowest, gear_ratios.size())
	if next == 0 and lowest == -1:
		next = direction   # pass through neutral into reverse or first
	if next == gear:
		return false
	gear = next
	_shift_cooldown = shift_time
	_shift_lockout = 0.6
	return true


func rpm_fraction() -> float:
	return clampf((rpm - idle_rpm) / maxf(redline_rpm - idle_rpm, 1.0),
		0.0, 1.15)


func gear_label() -> String:
	if gear == 0:
		return "N"
	if gear < 0:
		return "R"
	return str(gear)
