class_name LunarRocket
extends RigidBody3D
## Four-seat physical lander and deterministic cinematic voyage controller.
## Parked/landed states are a real RigidBody3D; transit freezes contact physics
## and follows an exact clock so all peers can present the same one-minute
## outbound and shorter return without integrating divergent trajectories.

signal state_changed(state: int, state_name: String)
signal voyage_progress(progress: float, elapsed_seconds: float,
	remaining_seconds: float)
signal presentation_phase_changed(phase: int, outbound: bool)
signal camera_cue(cue: StringName, duration_seconds: float)
signal crew_pose_requested(peer_id: int, seat_transform: Transform3D)
signal crew_suited(peer_id: int, suit: SpaceSuitSystem,
	inventory: LunarInventory)
signal oxygen_refill_available(peer_id: int, suit: SpaceSuitSystem)
signal moon_landing_completed
signal splashdown_completed

enum State {
	EARTH_BOARDING,
	LAUNCH_ASCENT,
	ATMOSPHERE_EXIT,
	SPACE_CRUISE,
	LUNAR_APPROACH,
	LANDED_MOON,
	RETURN_ASCENT,
	RETURN_CRUISE,
	REENTRY,
	OCEAN_APPROACH,
	SPLASHDOWN,
}

const STATE_NAMES := [
	"EARTH BOARDING", "LAUNCH ASCENT", "ATMOSPHERE EXIT",
	"SPACE CRUISE", "LUNAR APPROACH", "LANDED ON MOON",
	"RETURN ASCENT", "RETURN CRUISE", "FIERY REENTRY",
	"OCEAN APPROACH", "SPLASHDOWN",
]
const MAX_CREW := 4
## The lowest landing foot is at -4.36 m in model space. A small compression
## allowance leaves the pads visibly planted instead of burying half the hull.
const ORIGIN_ABOVE_LANDING_SURFACE := 4.40
const OUTBOUND_DURATION_SECONDS := 60.0
const RETURN_DURATION_SECONDS := 45.0
const OUTBOUND_PHASE_TIMES := [10.0, 20.0, 48.0, 60.0]
const RETURN_PHASE_TIMES := [6.0, 28.0, 40.0, 45.0]
const SEAT_OFFSETS := [
	Vector3(-0.62, 1.42, -0.28), Vector3(0.62, 1.42, -0.28),
	Vector3(-0.62, 1.42, 0.72), Vector3(0.62, 1.42, 0.72),
]

static var _hull_material: StandardMaterial3D
static var _dark_material: StandardMaterial3D
static var _window_material: StandardMaterial3D
static var _heatshield_material: StandardMaterial3D
static var _accent_material: StandardMaterial3D
static var _gold_material: StandardMaterial3D
static var _flame_core_material: StandardMaterial3D
static var _flame_glow_material: StandardMaterial3D
static var _flame_mesh: SphereMesh

var state := State.EARTH_BOARDING
var voyage_elapsed := 0.0
var outbound := true
var earth_launch_transform := Transform3D.IDENTITY
var moon_landing_transform := Transform3D(Basis.IDENTITY, Vector3(0, 2, 0))
var ocean_splashdown_transform := Transform3D(Basis.IDENTITY, Vector3(0, 0, 0))
var seat_nodes: Array[Node3D] = []
var crew: Array[Dictionary] = []
var voyage_visuals: SpaceVoyageVisuals
var launch_plume: GPUParticles3D
var reentry_flames: GPUParticles3D
var exhaust_flame_core: MeshInstance3D
var exhaust_flame_glow: MeshInstance3D
var _saved_collision_layer := 1
var _saved_collision_mask := 1
var _scripted_flight := false


func _ready() -> void:
	name = "LunarRocket"
	mass = 12_600.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, -1.25, 0.0)
	continuous_cd = true
	can_sleep = true
	linear_damp = 0.08
	angular_damp = 1.4
	if get_child_count() == 0:
		_build_rocket()
	if earth_launch_transform == Transform3D.IDENTITY:
		earth_launch_transform = global_transform
	set_physics_process(true)


func configure_route(earth_launch: Transform3D, moon_landing: Transform3D,
		ocean_splashdown: Transform3D) -> void:
	earth_launch_transform = earth_launch
	moon_landing_transform = moon_landing
	ocean_splashdown_transform = ocean_splashdown
	if state == State.EARTH_BOARDING:
		global_transform = earth_launch_transform


func board_crew(peer_id: int, actor: Node3D,
		suit: SpaceSuitSystem = null,
		inventory: LunarInventory = null,
		authoritative_manifest := false) -> int:
	if peer_id <= 0 or not is_instance_valid(actor):
		return -1
	var occupied_slot := seat_for_peer(peer_id)
	if occupied_slot >= 0:
		return occupied_slot
	# Ordinary interaction can board only a parked craft. Replicated manifest
	# repair is different: a puppet may be created after a late joiner's mission
	# snapshot, so the trusted ExpeditionManager must be able to attach that
	# already-authorized passenger to a moving cabin without opening gameplay
	# boarding during transit.
	if (not authoritative_manifest and not can_board()) \
			or (authoritative_manifest and crew.size() >= MAX_CREW):
		return -1
	var slot := _first_free_seat()
	if slot < 0:
		return -1
	if not inventory:
		inventory = LunarInventory.new()
	crew.append({"peer_id": peer_id, "actor": actor, "seat": slot,
		"suit": suit, "inventory": inventory})
	crew_pose_requested.emit(peer_id, seat_global_transform(slot))
	return slot


func disembark_crew(peer_id: int) -> bool:
	if is_in_transit():
		return false
	for index in range(crew.size()):
		if int(crew[index].peer_id) == peer_id:
			crew.remove_at(index)
			return true
	return false


func can_board() -> bool:
	return state in [State.EARTH_BOARDING, State.LANDED_MOON] \
		and crew.size() < MAX_CREW


func crew_count() -> int:
	return crew.size()


func seat_for_peer(peer_id: int) -> int:
	for member in crew:
		if int(member.peer_id) == peer_id:
			return int(member.seat)
	return -1


func seat_global_transform(index: int) -> Transform3D:
	if index < 0 or index >= seat_nodes.size():
		return global_transform
	return seat_nodes[index].global_transform


func crew_equipment(peer_id: int) -> Dictionary:
	for member in crew:
		if int(member.peer_id) == peer_id:
			return {"suit": member.suit, "inventory": member.inventory}
	return {}


func launch_to_moon() -> bool:
	if state != State.EARTH_BOARDING or crew.is_empty():
		return false
	outbound = true
	voyage_elapsed = 0.0
	_set_scripted_flight(true)
	_set_state(State.LAUNCH_ASCENT)
	voyage_visuals.begin_voyage(true)
	_update_effects()
	camera_cue.emit(&"launch_shake_and_tower_pullback", 8.0)
	presentation_phase_changed.emit(state, true)
	return true


func begin_return_to_earth() -> bool:
	if state != State.LANDED_MOON or crew.is_empty():
		return false
	outbound = false
	voyage_elapsed = 0.0
	_set_scripted_flight(true)
	_set_state(State.RETURN_ASCENT)
	voyage_visuals.begin_voyage(false)
	_update_effects()
	camera_cue.emit(&"lunar_launch_pullback", 7.0)
	presentation_phase_changed.emit(state, false)
	return true


func _physics_process(delta: float) -> void:
	advance_voyage(delta)
	_emit_crew_poses()


func advance_voyage(delta: float) -> void:
	if delta <= 0.0 or not is_in_transit():
		return
	var duration := OUTBOUND_DURATION_SECONDS if outbound \
		else RETURN_DURATION_SECONDS
	var previous_elapsed := voyage_elapsed
	voyage_elapsed = minf(voyage_elapsed + delta, duration)
	_emit_crossed_phases(previous_elapsed, voyage_elapsed)
	var progress := voyage_elapsed / duration
	global_transform = _flight_transform(progress)
	voyage_visuals.update_voyage(progress, state, outbound)
	voyage_progress.emit(progress, voyage_elapsed, duration - voyage_elapsed)
	_update_effects()
	if voyage_elapsed >= duration:
		if outbound:
			_complete_moon_landing()
		else:
			_complete_splashdown()


func is_in_transit() -> bool:
	return state in [State.LAUNCH_ASCENT, State.ATMOSPHERE_EXIT,
		State.SPACE_CRUISE, State.LUNAR_APPROACH, State.RETURN_ASCENT,
		State.RETURN_CRUISE, State.REENTRY, State.OCEAN_APPROACH]


func remaining_seconds() -> float:
	if not is_in_transit():
		return 0.0
	return maxf((OUTBOUND_DURATION_SECONDS if outbound \
		else RETURN_DURATION_SECONDS) - voyage_elapsed, 0.0)


## Convert an authority-owned mission clock into the detailed presentation
## state. Net code can synchronize only direction + elapsed time and never
## duplicate the cinematic boundary policy.
static func state_for_elapsed(travel_outbound: bool,
		elapsed_seconds: float) -> int:
	if travel_outbound:
		if elapsed_seconds >= OUTBOUND_DURATION_SECONDS:
			return State.LANDED_MOON
		if elapsed_seconds >= OUTBOUND_PHASE_TIMES[2]:
			return State.LUNAR_APPROACH
		if elapsed_seconds >= OUTBOUND_PHASE_TIMES[1]:
			return State.SPACE_CRUISE
		if elapsed_seconds >= OUTBOUND_PHASE_TIMES[0]:
			return State.ATMOSPHERE_EXIT
		return State.LAUNCH_ASCENT
	if elapsed_seconds >= RETURN_DURATION_SECONDS:
		return State.SPLASHDOWN
	if elapsed_seconds >= RETURN_PHASE_TIMES[2]:
		return State.OCEAN_APPROACH
	if elapsed_seconds >= RETURN_PHASE_TIMES[1]:
		return State.REENTRY
	if elapsed_seconds >= RETURN_PHASE_TIMES[0]:
		return State.RETURN_CRUISE
	return State.RETURN_ASCENT


func atmosphere_fraction() -> float:
	if outbound:
		return clampf(1.0 - voyage_elapsed / OUTBOUND_PHASE_TIMES[1], 0.0, 1.0)
	return clampf((voyage_elapsed - RETURN_PHASE_TIMES[1]) \
		/ (RETURN_DURATION_SECONDS - RETURN_PHASE_TIMES[1]), 0.0, 1.0)


func refill_crew_oxygen() -> int:
	var refilled := 0
	for member in crew:
		var suit: SpaceSuitSystem = member.suit
		if is_instance_valid(suit):
			suit.refill_oxygen()
			oxygen_refill_available.emit(int(member.peer_id), suit)
			refilled += 1
	return refilled


func admin_send_actor_to_moon(target: Node3D, authorized: bool,
		moon_world: MoonWorld) -> bool:
	return moon_world != null \
		and moon_world.admin_teleport_actor(target, authorized)


func network_state_snapshot() -> Dictionary:
	var peer_ids: Array[int] = []
	for member in crew:
		peer_ids.append(int(member.peer_id))
	return {"state": state, "outbound": outbound, "elapsed": voyage_elapsed,
		"crew": peer_ids, "position": global_position,
		"basis": global_basis}


func apply_authoritative_clock(authoritative_state: int,
		authoritative_outbound: bool, elapsed_seconds: float) -> void:
	# The network owner sends the clock rather than frame-by-frame transforms.
	# Every peer derives the same path and effects, while small corrections do
	# not compound into an orbital drift.
	outbound = authoritative_outbound
	var next_state := clampi(authoritative_state, State.EARTH_BOARDING,
		State.SPLASHDOWN)
	if state != next_state:
		state = next_state
		state_changed.emit(state, STATE_NAMES[state])
	var duration := OUTBOUND_DURATION_SECONDS if outbound \
		else RETURN_DURATION_SECONDS
	voyage_elapsed = clampf(elapsed_seconds, 0.0, duration)
	if is_in_transit():
		_set_scripted_flight(true)
		global_transform = _flight_transform(voyage_elapsed / duration)
		if voyage_visuals:
			voyage_visuals.visible = true
			voyage_visuals.update_voyage(voyage_elapsed / duration, state, outbound)
	else:
		_set_scripted_flight(false)
		if voyage_visuals:
			voyage_visuals.end_voyage()
		match state:
			State.EARTH_BOARDING:
				global_transform = earth_launch_transform
				gravity_scale = 1.0
			State.LANDED_MOON:
				global_transform = moon_landing_transform
				gravity_scale = MoonWorld.LUNAR_GRAVITY / 9.81
				freeze = true
			State.SPLASHDOWN:
				global_transform = ocean_splashdown_transform
				gravity_scale = 1.0
				freeze = true
	_update_effects()


func flame_particle_budget() -> int:
	return (launch_plume.amount if launch_plume else 0) \
		+ (reentry_flames.amount if reentry_flames else 0)


func model_primitive_count() -> int:
	return _count_meshes(self) - _count_meshes(voyage_visuals)


func _emit_crossed_phases(previous: float, current: float) -> void:
	var boundaries := OUTBOUND_PHASE_TIMES if outbound else RETURN_PHASE_TIMES
	var phase_states := [State.ATMOSPHERE_EXIT, State.SPACE_CRUISE,
		State.LUNAR_APPROACH] if outbound else [State.RETURN_CRUISE,
		State.REENTRY, State.OCEAN_APPROACH]
	for index in range(3):
		var boundary := float(boundaries[index])
		if previous < boundary and current >= boundary:
			_set_state(phase_states[index])
			presentation_phase_changed.emit(state, outbound)
			_emit_camera_cue_for_state(state)


func _emit_camera_cue_for_state(next_state: int) -> void:
	match next_state:
		State.ATMOSPHERE_EXIT:
			camera_cue.emit(&"atmosphere_thins_to_stars", 8.0)
		State.SPACE_CRUISE:
			camera_cue.emit(&"earth_reveal_and_slow_orbit", 14.0)
		State.LUNAR_APPROACH:
			camera_cue.emit(&"pan_from_earth_to_moon", 12.0)
		State.RETURN_CRUISE:
			camera_cue.emit(&"moon_recedes_earth_grows", 12.0)
		State.REENTRY:
			camera_cue.emit(&"heatshield_reentry_shake", 18.0)
		State.OCEAN_APPROACH:
			camera_cue.emit(&"parachute_ocean_pullback", 10.0)


func _flight_transform(progress: float) -> Transform3D:
	progress = clampf(progress, 0.0, 1.0)
	if progress <= 0.0:
		return earth_launch_transform if outbound else moon_landing_transform
	if progress >= 1.0:
		return moon_landing_transform if outbound else ocean_splashdown_transform
	var origin := _flight_origin(progress)
	# Aim the rocket's long local +Y axis along the actual path tangent. A
	# centred finite difference remains stable at every cinematic phase and, in
	# particular, prevents the old yaw-only hull from travelling broadside.
	var tangent_step := 0.0005
	var before := _flight_origin(maxf(progress - tangent_step, 0.0))
	var after := _flight_origin(minf(progress + tangent_step, 1.0))
	var path_tangent := (after - before).normalized()
	if path_tangent.length_squared() < 0.5:
		path_tangent = Vector3.UP if outbound else Vector3.DOWN
	var start := earth_launch_transform if outbound else moon_landing_transform
	var finish := moon_landing_transform if outbound \
		else ocean_splashdown_transform
	var endpoint_blend := smoothstep(0.90, 1.0, progress)
	# Outbound points the nose (+Y) into the Moon-bound tangent. Return points the
	# heat shield (-Y) into the reentry tangent, matching the physical hull.
	var hull_axis := path_tangent if outbound else -path_tangent
	var flight_basis := _basis_with_up(hull_axis, start.basis.z)
	# Land on the exact authored basis so there is no visible rotation snap when
	# scripted flight hands control back to the physical craft.
	var basis_rotation := flight_basis.get_rotation_quaternion().slerp(
		finish.basis.get_rotation_quaternion(), endpoint_blend)
	return Transform3D(Basis(basis_rotation).orthonormalized(), origin)


func _flight_origin(progress: float) -> Vector3:
	progress = clampf(progress, 0.0, 1.0)
	var start := earth_launch_transform if outbound else moon_landing_transform
	var finish := moon_landing_transform if outbound \
		else ocean_splashdown_transform
	if outbound:
		# The first sixth is a genuine vertical launch: X/Z are pinned and the
		# eased altitude has positive velocity immediately. Horizontal correction
		# begins only after the runway is far below, and has zero endpoint velocity.
		var launch_fraction := OUTBOUND_PHASE_TIMES[0] \
			/ OUTBOUND_DURATION_SECONDS
		# The playable Moon normally lives in a distant realm, but standalone
		# fixtures and future realm layouts may author its landing pad below the
		# Earth pad. Liftoff is still a physical upward climb, never a signed lerp
		# toward the destination altitude.
		var launch_height := 18_000.0
		if progress <= launch_fraction:
			var launch_t := progress / launch_fraction
			var ascent := launch_height * (1.0 - pow(1.0 - launch_t, 1.65))
			return start.origin + Vector3.UP * ascent
		var lateral_t := smoothstep(launch_fraction, 1.0, progress)
		var y := lerpf(start.origin.y + launch_height, finish.origin.y,
			lateral_t)
		var horizontal := Vector2(start.origin.x, start.origin.z).lerp(
			Vector2(finish.origin.x, finish.origin.z), lateral_t)
		# A delayed, derivative-zero arc gives the cinematic a readable orbital
		# silhouette without kicking sideways at liftoff or sliding at touchdown.
		var arc := pow(sin(lateral_t * PI), 2.0) * 4_500.0
		var arc_direction := Vector2(-1.0, 0.0).rotated(
			atan2(finish.origin.z - start.origin.z,
				finish.origin.x - start.origin.x) + PI * 0.5)
		horizontal += arc_direction * arc
		return Vector3(horizontal.x, y, horizontal.y)
	# Return keeps the heat-shield path compact and faster, with no endpoint
	# lateral impulse. Unlike ascent it may travel horizontally toward the ocean.
	var travel_t := smoothstep(0.0, 1.0, progress)
	var midpoint_lift := pow(sin(progress * PI), 2.0) * 9_000.0
	return start.origin.lerp(finish.origin, travel_t) \
		+ Vector3.UP * midpoint_lift


static func _basis_with_up(up_axis: Vector3,
		preferred_forward: Vector3) -> Basis:
	var y_axis := up_axis.normalized()
	var z_axis := preferred_forward - y_axis * preferred_forward.dot(y_axis)
	if z_axis.length_squared() < 0.0001:
		var fallback := Vector3.FORWARD if absf(y_axis.dot(Vector3.FORWARD)) < 0.92 \
			else Vector3.RIGHT
		z_axis = fallback - y_axis * fallback.dot(y_axis)
	z_axis = z_axis.normalized()
	var x_axis := y_axis.cross(z_axis).normalized()
	z_axis = x_axis.cross(y_axis).normalized()
	return Basis(x_axis, y_axis, z_axis)


func _complete_moon_landing() -> void:
	global_transform = moon_landing_transform
	_set_state(State.LANDED_MOON)
	_set_scripted_flight(false)
	gravity_scale = MoonWorld.LUNAR_GRAVITY / 9.81
	freeze = true
	voyage_visuals.end_voyage()
	_update_effects()
	_equip_crew_for_moon()
	camera_cue.emit(&"lunar_touchdown_dust", 6.0)
	moon_landing_completed.emit()


func _complete_splashdown() -> void:
	global_transform = ocean_splashdown_transform
	_set_state(State.SPLASHDOWN)
	_set_scripted_flight(false)
	# Keep the capsule floating at the authored ocean pose. World integration
	# may replace this with buoyancy later without changing the voyage contract.
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	gravity_scale = 1.0
	voyage_visuals.end_voyage()
	_update_effects()
	for member in crew:
		var suit: SpaceSuitSystem = member.suit
		if is_instance_valid(suit):
			suit.set_vacuum_exposure(false)
	camera_cue.emit(&"ocean_splash_and_steam", 8.0)
	splashdown_completed.emit()


func _equip_crew_for_moon() -> void:
	for member in crew:
		var suit: SpaceSuitSystem = member.suit
		var actor: Node3D = member.actor
		var inventory: LunarInventory = member.inventory
		if not is_instance_valid(suit):
			suit = SpaceSuitSystem.new()
			member.suit = suit
		if suit.equip_for(actor, inventory):
			suit.set_vacuum_exposure(true)
			crew_suited.emit(int(member.peer_id), suit, inventory)


func _set_scripted_flight(enabled: bool) -> void:
	if enabled == _scripted_flight:
		return
	_scripted_flight = enabled
	if enabled:
		_saved_collision_layer = collision_layer
		_saved_collision_mask = collision_mask
		collision_layer = 0
		collision_mask = 0
		freeze = true
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
	else:
		collision_layer = _saved_collision_layer
		collision_mask = _saved_collision_mask
		freeze = false


func _set_state(next_state: int) -> void:
	if state == next_state:
		return
	state = next_state
	state_changed.emit(state, STATE_NAMES[state])


func _update_effects() -> void:
	if not launch_plume or not reentry_flames:
		return
	# Powered ascent uses the full exhaust field; thinner upper-atmosphere and
	# landing burns reduce density without popping the plume off between phases.
	var thrust_ratio := 0.0
	match state:
		State.LAUNCH_ASCENT, State.RETURN_ASCENT:
			thrust_ratio = 1.0
		State.ATMOSPHERE_EXIT:
			thrust_ratio = 0.72
		State.LUNAR_APPROACH:
			thrust_ratio = 0.42
		State.OCEAN_APPROACH:
			thrust_ratio = 0.30
	launch_plume.emitting = thrust_ratio > 0.0
	launch_plume.amount_ratio = thrust_ratio
	if exhaust_flame_core:
		exhaust_flame_core.visible = launch_plume.emitting
	if exhaust_flame_glow:
		exhaust_flame_glow.visible = launch_plume.emitting
	reentry_flames.emitting = state == State.REENTRY
	reentry_flames.amount_ratio = 1.0 if reentry_flames.emitting else 0.0


func _emit_crew_poses() -> void:
	for member in crew:
		crew_pose_requested.emit(int(member.peer_id),
			seat_global_transform(int(member.seat)))


func _first_free_seat() -> int:
	for seat_index in range(MAX_CREW):
		var occupied := false
		for member in crew:
			if int(member.seat) == seat_index:
				occupied = true
				break
		if not occupied:
			return seat_index
	return -1


func _build_rocket() -> void:
	_ensure_shared_resources()
	collision_layer = 1
	collision_mask = 1
	var collision := CollisionShape3D.new()
	collision.name = "PhysicalRocketHull"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 1.55
	capsule.height = 8.2
	collision.shape = capsule
	collision.position.y = 0.45
	add_child(collision)
	var body_mesh := CylinderMesh.new()
	body_mesh.top_radius = 1.50
	body_mesh.bottom_radius = 1.50
	body_mesh.height = 6.2
	body_mesh.radial_segments = 24
	_add_mesh("PressureHull", body_mesh, Vector3(0.0, 0.15, 0.0),
		_hull_material)
	var nose := CylinderMesh.new()
	nose.top_radius = 0.08
	nose.bottom_radius = 1.50
	nose.height = 2.8
	nose.radial_segments = 24
	_add_mesh("NoseCone", nose, Vector3(0.0, 4.65, 0.0), _hull_material)
	# Strong silhouette breaks, panel seams, and a warm mission stripe keep the
	# compact four-seat hull readable against both a bright forest and black
	# space. These are shared primitive/material resources and never animate.
	var nose_band := CylinderMesh.new()
	nose_band.top_radius = 1.53
	nose_band.bottom_radius = 1.53
	nose_band.height = 0.18
	nose_band.radial_segments = 24
	_add_mesh("NoseSeparationBand", nose_band, Vector3(0.0, 3.28, 0.0),
		_dark_material)
	var cabin_band := CylinderMesh.new()
	cabin_band.top_radius = 1.525
	cabin_band.bottom_radius = 1.525
	cabin_band.height = 0.20
	cabin_band.radial_segments = 24
	_add_mesh("CabinMissionBand", cabin_band, Vector3(0.0, -0.55, 0.0),
		_accent_material)
	var aft_band := CylinderMesh.new()
	aft_band.top_radius = 1.54
	aft_band.bottom_radius = 1.62
	aft_band.height = 0.34
	aft_band.radial_segments = 24
	_add_mesh("AftEquipmentBand", aft_band, Vector3(0.0, -2.72, 0.0),
		_dark_material)
	var heatshield := CylinderMesh.new()
	heatshield.top_radius = 1.52
	heatshield.bottom_radius = 1.75
	heatshield.height = 0.42
	heatshield.radial_segments = 24
	_add_mesh("HeatShield", heatshield, Vector3(0.0, -3.14, 0.0),
		_heatshield_material)
	for direction in [Vector3.RIGHT, Vector3.LEFT,
			Vector3.FORWARD, Vector3.BACK]:
		var leg_rotation := Vector3(direction.z * 0.18, 0.0,
			direction.x * -0.18)
		_add_box("LandingLeg", Vector3(0.24, 3.0, 0.24),
			direction * 1.48 + Vector3.DOWN * 3.0, _dark_material,
			leg_rotation)
		var foot_size := Vector3(1.30, 0.18, 0.74) \
			if absf(direction.x) > 0.5 else Vector3(0.74, 0.18, 1.30)
		_add_box("LandingFoot", foot_size,
			direction * 2.03 + Vector3.DOWN * 4.36, _dark_material)
	# Recessed portholes are mirrored front/back so the crew compartment reads
	# from either cinematic side. A dark outer disc gives each window a rim.
	for facing in [-1.0, 1.0]:
		for side in [-1.0, 1.0]:
			for level in [0.65, 2.15]:
				var rim_mesh := CylinderMesh.new()
				rim_mesh.top_radius = 0.39
				rim_mesh.bottom_radius = 0.39
				rim_mesh.height = 0.07
				rim_mesh.radial_segments = 16
				var rim := _add_mesh("WindowRim", rim_mesh,
					Vector3(side * 0.68, level, facing * 1.49),
					_dark_material)
				rim.rotation.x = PI * 0.5
				var window_mesh := CylinderMesh.new()
				window_mesh.top_radius = 0.30
				window_mesh.bottom_radius = 0.30
				window_mesh.height = 0.085
				window_mesh.radial_segments = 16
				var window := _add_mesh("CabinWindow", window_mesh,
					Vector3(side * 0.68, level, facing * 1.525),
					_window_material)
				window.rotation.x = PI * 0.5
	for facing in [-1.0, 1.0]:
		_add_box("VerticalMissionStripe", Vector3(0.20, 4.7, 0.055),
			Vector3(0.0, 0.95, facing * 1.505), _accent_material)
		for side in [-1.0, 1.0]:
			_add_box("GoldServicePanel", Vector3(0.34, 0.78, 0.045),
				Vector3(side * 0.92, -1.62, facing * 1.225), _gold_material)
	# Four compact engine bells sell the mass of the lander even when the flame
	# is off during cruise or after touchdown.
	for engine_offset in [Vector3(-0.55, 0.0, -0.55),
			Vector3(0.55, 0.0, -0.55), Vector3(-0.55, 0.0, 0.55),
			Vector3(0.55, 0.0, 0.55)]:
		var bell := CylinderMesh.new()
		bell.top_radius = 0.26
		bell.bottom_radius = 0.48
		bell.height = 0.66
		bell.radial_segments = 12
		_add_mesh("EngineBell", bell,
			engine_offset + Vector3.DOWN * 3.62, _heatshield_material)
	# A layered emissive core guarantees a long, directional engine flame is
	# legible at ignition; the existing particles add flicker and turbulent edges.
	var flame_core_mesh := CylinderMesh.new()
	flame_core_mesh.top_radius = 0.54
	flame_core_mesh.bottom_radius = 0.055
	flame_core_mesh.height = 4.8
	flame_core_mesh.radial_segments = 14
	exhaust_flame_core = _add_mesh("EngineFlameCore", flame_core_mesh,
		Vector3(0.0, -6.18, 0.0), _flame_core_material)
	var flame_glow_mesh := CylinderMesh.new()
	flame_glow_mesh.top_radius = 0.84
	flame_glow_mesh.bottom_radius = 0.10
	flame_glow_mesh.height = 5.9
	flame_glow_mesh.radial_segments = 14
	exhaust_flame_glow = _add_mesh("EngineFlameGlow", flame_glow_mesh,
		Vector3(0.0, -6.72, 0.0), _flame_glow_material)
	exhaust_flame_core.visible = false
	exhaust_flame_glow.visible = false
	for index in range(MAX_CREW):
		var seat := Node3D.new()
		seat.name = "CrewSeat%d" % (index + 1)
		seat.position = SEAT_OFFSETS[index]
		seat.rotation.y = PI
		add_child(seat)
		seat_nodes.append(seat)
		_add_box_to(seat, "SeatBack", Vector3(0.52, 0.72, 0.14),
			Vector3(0.0, 0.28, 0.18), _dark_material)

	launch_plume = _build_launch_plume()
	add_child(launch_plume)
	reentry_flames = _build_reentry_flames()
	add_child(reentry_flames)
	voyage_visuals = SpaceVoyageVisuals.new()
	voyage_visuals.name = "VoyagePresentation"
	add_child(voyage_visuals)


func _build_launch_plume() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "EngineFireAndExhaust"
	particles.position = Vector3(0.0, -3.42, 0.0)
	particles.amount = 88
	particles.lifetime = 1.15
	particles.randomness = 0.22
	particles.local_coords = true
	particles.fixed_fps = 30
	particles.draw_pass_1 = _flame_mesh
	particles.visibility_aabb = AABB(Vector3(-4.0, -22.0, -4.0),
		Vector3(8.0, 24.0, 8.0))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.62
	process.direction = Vector3.DOWN
	process.spread = 7.0
	process.initial_velocity_min = 18.0
	process.initial_velocity_max = 34.0
	process.gravity = Vector3(0.0, -5.0, 0.0)
	process.scale_min = 0.65
	process.scale_max = 1.7
	process.color = Color(1.0, 0.58, 0.12, 0.92)
	particles.process_material = process
	particles.emitting = false
	particles.amount_ratio = 0.0
	return particles


func _build_reentry_flames() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "ReentryPlasma"
	particles.position = Vector3(0.0, 0.5, 0.0)
	particles.amount = 72
	particles.lifetime = 0.72
	particles.randomness = 0.35
	particles.local_coords = true
	particles.fixed_fps = 30
	particles.draw_pass_1 = _flame_mesh
	particles.visibility_aabb = AABB(Vector3(-6.0, -8.0, -6.0),
		Vector3(12.0, 16.0, 12.0))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 1.72
	process.direction = Vector3.UP
	process.spread = 32.0
	process.initial_velocity_min = 8.0
	process.initial_velocity_max = 17.0
	process.gravity = Vector3(0.0, 2.0, 0.0)
	process.scale_min = 0.55
	process.scale_max = 1.45
	process.color = Color(1.0, 0.28, 0.045, 0.84)
	particles.process_material = process
	particles.emitting = false
	particles.amount_ratio = 0.0
	return particles


func _add_box(part_name: String, size: Vector3, local_position: Vector3,
		material: Material, local_rotation := Vector3.ZERO) -> MeshInstance3D:
	return _add_box_to(self, part_name, size, local_position, material,
		local_rotation)


static func _add_box_to(parent: Node3D, part_name: String, size: Vector3,
		local_position: Vector3, material: Material,
		local_rotation := Vector3.ZERO) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := _add_mesh_to(parent, part_name, mesh, local_position, material)
	instance.rotation = local_rotation
	return instance


func _add_mesh(part_name: String, mesh: PrimitiveMesh,
		local_position: Vector3, material: Material) -> MeshInstance3D:
	return _add_mesh_to(self, part_name, mesh, local_position, material)


static func _add_mesh_to(parent: Node3D, part_name: String,
		mesh: PrimitiveMesh, local_position: Vector3,
		material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.position = local_position
	instance.material_override = material
	parent.add_child(instance)
	return instance


static func _count_meshes(root: Node) -> int:
	if not is_instance_valid(root):
		return 0
	var count := 0
	for child in root.get_children():
		if child is MeshInstance3D:
			count += 1
		count += _count_meshes(child)
	return count


static func _ensure_shared_resources() -> void:
	if _hull_material:
		return
	_hull_material = StandardMaterial3D.new()
	_hull_material.albedo_color = Color(0.88, 0.90, 0.91)
	_hull_material.metallic = 0.28
	_hull_material.roughness = 0.42
	_hull_material.emission_enabled = true
	_hull_material.emission = Color(0.055, 0.065, 0.078)
	_hull_material.emission_energy_multiplier = 0.36
	_hull_material.disable_fog = true
	_dark_material = StandardMaterial3D.new()
	_dark_material.albedo_color = Color(0.035, 0.055, 0.072)
	_dark_material.metallic = 0.42
	_dark_material.roughness = 0.40
	_dark_material.emission_enabled = true
	_dark_material.emission = Color(0.008, 0.012, 0.018)
	_dark_material.emission_energy_multiplier = 0.28
	_dark_material.disable_fog = true
	_window_material = StandardMaterial3D.new()
	_window_material.albedo_color = Color(0.035, 0.29, 0.56, 0.84)
	_window_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_window_material.metallic = 0.36
	_window_material.roughness = 0.10
	_window_material.emission_enabled = true
	_window_material.emission = Color(0.025, 0.18, 0.38)
	_window_material.emission_energy_multiplier = 0.55
	_window_material.disable_fog = true
	_heatshield_material = StandardMaterial3D.new()
	_heatshield_material.albedo_color = Color(0.18, 0.11, 0.075)
	_heatshield_material.roughness = 0.92
	_heatshield_material.disable_fog = true
	_accent_material = StandardMaterial3D.new()
	_accent_material.albedo_color = Color(0.94, 0.24, 0.075)
	_accent_material.metallic = 0.22
	_accent_material.roughness = 0.45
	_accent_material.emission_enabled = true
	_accent_material.emission = Color(0.25, 0.035, 0.008)
	_accent_material.emission_energy_multiplier = 0.48
	_accent_material.disable_fog = true
	_gold_material = StandardMaterial3D.new()
	_gold_material.albedo_color = Color(0.72, 0.48, 0.12)
	_gold_material.metallic = 0.68
	_gold_material.roughness = 0.36
	_gold_material.emission_enabled = true
	_gold_material.emission = Color(0.12, 0.055, 0.008)
	_gold_material.emission_energy_multiplier = 0.34
	_gold_material.disable_fog = true
	_flame_core_material = StandardMaterial3D.new()
	_flame_core_material.albedo_color = Color(1.0, 0.90, 0.48, 0.94)
	_flame_core_material.emission_enabled = true
	_flame_core_material.emission = Color(1.0, 0.48, 0.06)
	_flame_core_material.emission_energy_multiplier = 6.5
	_flame_core_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flame_core_material.disable_fog = true
	_flame_glow_material = StandardMaterial3D.new()
	_flame_glow_material.albedo_color = Color(1.0, 0.18, 0.025, 0.20)
	_flame_glow_material.emission_enabled = true
	_flame_glow_material.emission = Color(1.0, 0.10, 0.01)
	_flame_glow_material.emission_energy_multiplier = 4.2
	_flame_glow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flame_glow_material.disable_fog = true
	_flame_mesh = SphereMesh.new()
	_flame_mesh.radius = 0.24
	_flame_mesh.height = 0.70
	_flame_mesh.radial_segments = 8
	_flame_mesh.rings = 4
	var flame_material := StandardMaterial3D.new()
	flame_material.albedo_color = Color(1.0, 0.62, 0.16, 0.76)
	flame_material.emission_enabled = true
	flame_material.emission = Color(1.0, 0.19, 0.025)
	flame_material.emission_energy_multiplier = 3.2
	flame_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flame_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	flame_material.vertex_color_use_as_albedo = true
	_flame_mesh.material = flame_material
