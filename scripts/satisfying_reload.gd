class_name SatisfyingReload
extends RefCounted
## Shared timing helpers for exaggerated procedural reloads. Weapons keep their
## own silhouettes and choreography, but use this vocabulary so future guns get
## crisp threshold events, toss arcs, overshoot and settle for free.


static func phase(progress: float, start: float, finish: float) -> float:
	if finish <= start:
		return 1.0 if progress >= finish else 0.0
	return smooth01((progress - start) / (finish - start))


## Quintic ease with zero velocity and acceleration at both ends. Reload props
## can hand off between authored phases without a visible hitch, even when the
## game is rendered substantially faster than its physics tick.
static func smooth01(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


static func pulse(progress: float, start: float, peak: float,
		finish: float) -> float:
	if progress <= peak:
		return phase(progress, start, peak)
	return 1.0 - phase(progress, peak, finish)


static func crossed(previous: float, current: float, threshold: float) -> bool:
	# `tick()` is intentionally allowed to advance through an entire reload in a
	# single test/server frame. Threshold events must still happen exactly once.
	return previous < threshold and current >= threshold


static func arc(from: Vector3, to: Vector3, height: float,
		progress: float) -> Vector3:
	# Keep the airborne lift bounded, but let the linear hand path travel a few
	# centimetres through the socket when `overshoot()` returns > 1.0. Clamping
	# the whole value erased the snap-and-settle that the helper promised.
	var arc_t := clampf(progress, 0.0, 1.0)
	return from.lerp(to, progress) \
		+ Vector3.UP * sin(arc_t * PI) * height


## Rotation-safe companion to arc(). `progress` is normally supplied by
## phase(), giving both the position and orientation a zero-velocity handoff.
static func arc_transform(from: Transform3D, to: Transform3D, height: float,
		progress: float) -> Transform3D:
	return Transform3D(slerp_basis(from.basis, to.basis, progress),
		arc(from.origin, to.origin, height, progress))


static func slerp_basis(from: Basis, to: Basis, progress: float) -> Basis:
	var t := clampf(progress, 0.0, 1.0)
	var from_scale := from.get_scale()
	var to_scale := to.get_scale()
	var from_rotation := from.orthonormalized().get_rotation_quaternion()
	var to_rotation := to.orthonormalized().get_rotation_quaternion()
	return Basis(from_rotation.slerp(to_rotation, t)).scaled(
		from_scale.lerp(to_scale, t))


## Pure helper used by every viewmodel and by the high-refresh regression. A
## phase reset deliberately snaps to the new phase's first pose; ordinary
## progress uses the engine's render-between-physics fraction.
static func interpolate_progress(previous: float, current: float,
		fraction: float) -> float:
	if current < previous:
		return current
	return lerpf(previous, current, clampf(fraction, 0.0, 1.0))


static func overshoot(progress: float, amount := 0.12) -> float:
	# One compact back-ease: arrives firmly past the socket, then settles exactly
	# at 1.0. It reads like a hand-driven snap rather than a linear UI tween.
	var t := clampf(progress, 0.0, 1.0) - 1.0
	# Standard back-ease strengths around 1.7 produce a visible ~10% pass-through;
	# using the raw 0.1 choreography amount as that strength made the movement
	# sub-millimetric. Map our compact authoring value into the useful range.
	var strength := 1.35 + clampf(amount, 0.0, 0.5) * 4.0
	return 1.0 + (strength + 1.0) * t * t * t + strength * t * t


static func trick_spin(progress: float, turns: float,
		axis := Vector3(0.72, 0.18, 0.67)) -> Basis:
	var safe_axis := axis.normalized() if axis.length_squared() > 0.001 \
		else Vector3.UP
	return Basis(safe_axis, clampf(progress, 0.0, 1.0) * TAU * turns)
