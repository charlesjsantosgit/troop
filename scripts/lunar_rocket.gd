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
signal splashdown_completed # Legacy network terminal signal; now a dry Earth pad landing.
signal earth_landing_completed

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
	"POWERED EARTH DESCENT", "LANDED ON EARTH",
]
const MAX_CREW := 4
## A thirty-metre vehicle: native geometry, contact shapes and cabin all share
## this frame. The seated monkey is human-scale inside the seven-metre hull.
const HULL_RADIUS := 3.5
const HULL_TOP := 17.0
const HULL_BOTTOM := -9.0
const ENGINE_EXIT_Y := -10.6
const ORIGIN_ABOVE_LANDING_SURFACE := 13.0
const LANDING_STRUT_TRAVEL := 0.85
const LANDING_FOOT_RADIUS := 5.55
const LANDING_FOOT_SIZE := Vector3(2.0, 0.24, 1.5)
const LANDING_PAD_RADIUS := 7.5
const LANDING_GEAR_DEPLOY_START := 51.0
const LANDING_GEAR_DEPLOY_END := 55.0
const EARTH_GEAR_DEPLOY_START := 38.0
const EARTH_GEAR_DEPLOY_END := 41.5
const EARTH_APPROACH_HEIGHT := 350.0
const LANDING_RECOVERY_SECONDS := 3.0
const CABIN_FLOOR_Y := 4.10
const CABIN_CEILING_Y := 7.80
const CABIN_WINDOW_SILL_Y := 4.65
const CABIN_EYE_OFFSET := Vector3(0.0, 1.11, -0.11)
const BOARDING_LOCAL_POSITION := Vector3(0.0, -12.88, 7.4)
const OUTBOUND_DURATION_SECONDS := 60.0
const RETURN_DURATION_SECONDS := 45.0
## The outbound presentation keeps one continuous spatial story: fourteen
## seconds of powered climb, a map-scale Earth departure, transfer, then a
## dedicated ten-second descent over the real lunar surface.
const OUTBOUND_PHASE_TIMES := [14.0, 24.0, 50.0, 60.0]
const RETURN_PHASE_TIMES := [6.0, 28.0, 40.0, 45.0]
## The realm offset is an implementation detail, not a flight direction. These
## authored clearances make the last outbound phase a real descent from above
## the lunar pad and the first return phase a real vertical liftoff.
const EARTH_ASCENT_HEIGHT := 12_000.0
const LUNAR_APPROACH_HEIGHT := 300.0
const LUNAR_APPROACH_OFFSET := 100.0
const LUNAR_ASCENT_HEIGHT := 3_600.0
const INSERTION_LATERAL_CLEARANCE_METERS := 4_000.0
const LUNAR_DUST_CLEARANCE := 90.0
const DUST_SHEET_MIN_RADIUS := 7.0
const DUST_SHEET_MAX_RADIUS := 26.0
const DUST_SHEET_SURFACE_CLEARANCE := 0.16
const DUST_SHEET_RINGS := 6
const DUST_SHEET_SEGMENTS := 48
const LUNAR_FLIP_START_SECONDS := 46.0
const LUNAR_PREFLIP_START_SECONDS := 43.5
const MAX_CLOCK_RATE_CORRECTION := 0.08
const CLOCK_CORRECTION_GAIN := 0.8
const MAX_RENDER_CLOCK_STEP := 0.10
const ATTITUDE_SAMPLE_SECONDS := 0.125
const SEAT_OFFSETS := [
	Vector3(-1.22, 4.25, -0.94), Vector3(1.22, 4.25, -0.94),
	Vector3(-1.22, 4.25, 1.03), Vector3(1.22, 4.25, 1.03),
]

static var _hull_material: StandardMaterial3D
static var _dark_material: StandardMaterial3D
static var _window_material: StandardMaterial3D
static var _heatshield_material: StandardMaterial3D
static var _accent_material: StandardMaterial3D
static var _gold_material: StandardMaterial3D
static var _cabin_material: StandardMaterial3D
static var _seat_material: StandardMaterial3D
static var _screen_material: StandardMaterial3D
static var _cabin_light_material: StandardMaterial3D
static var _interior_materials: Dictionary = {}
static var _flame_core_material: StandardMaterial3D
static var _flame_glow_material: StandardMaterial3D
static var _flame_mesh: SphereMesh
static var _dust_mesh: QuadMesh
static var _dust_sheet_mesh: ArrayMesh
static var _dust_sheet_template_vertices := PackedVector3Array()
static var _landing_strut_mesh: CylinderMesh
static var _landing_piston_mesh: CylinderMesh
static var _batch_cpu_meshes: Dictionary = {}
static var _unit_box_arrays: Array = []

## SurfaceTool can consume Mesh's CPU virtual directly. Unlike ArrayMesh or
## PrimitiveMesh.surface_get_arrays, this adapter never reads a renderer buffer.
## Keeping SurfaceTool's native append preserves every attribute and its exact
## normal/tangent transform rules instead of reimplementing those in GDScript.
class CpuBatchMesh:
	extends Mesh
	var arrays: Array
	func _surface_get_arrays(_surface: int) -> Array:
		return arrays
	func _surface_get_primitive_type(_surface: int) -> int:
		return Mesh.PRIMITIVE_TRIANGLES

enum SetupPhase { NOT_STARTED, RESOURCES, STRUCTURE, CABIN, LADDER,
	EXTERIOR_BATCH, CABIN_BATCH, GEAR, FLAMES, LAUNCH_PLUME, REENTRY_FLAMES,
	LUNAR_DUST, VOYAGE, COMPLETE }
var _setup_phase := SetupPhase.NOT_STARTED
var _setup_exterior: Node3D
var _setup_batch_parts: Array[MeshInstance3D] = []
var _setup_batch_surfaces: Dictionary = {}
var _setup_batch_cursor := 0
var _setup_batch_commit_cursor := 0
var _setup_batch_started := false

var state := State.EARTH_BOARDING
var voyage_elapsed := 0.0
var outbound := true
var earth_launch_transform := Transform3D.IDENTITY
var moon_landing_transform := Transform3D(Basis.IDENTITY, Vector3(0, 2, 0))
var ocean_splashdown_transform := Transform3D(Basis.IDENTITY, Vector3(0, 0, 0))
var seat_nodes: Array[Node3D] = []
var crew: Array[Dictionary] = []
var _manifest_seat_slots: Dictionary = {}
var voyage_visuals: SpaceVoyageVisuals
var launch_plume: GPUParticles3D
var reentry_flames: GPUParticles3D
var lunar_dust: GPUParticles3D
var lunar_dust_sheet: MeshInstance3D
var _dust_surface: MoonWorld
var _dust_sheet_vertices := PackedVector3Array()
var _dust_sheet_vertex_bytes := PackedByteArray()
var _dust_sheet_conforming := false
var _dust_sheet_target_radius := -1.0
var _dust_sheet_target_frame := Transform3D.IDENTITY
var _dust_sheet_surface_transform := Transform3D.IDENTITY
var exhaust_flame_core: MeshInstance3D
var exhaust_flame_glow: MeshInstance3D
## Shared mechanical nodes are direct children of the replicated rocket. They
## remain visible to spectators when the passenger's space diorama is hidden.
var cabin: Node3D
var cabin_lights: Array[OmniLight3D] = []
var cabin_windows: Array[MeshInstance3D] = []
var landing_gear: Array[Dictionary] = []
## Empty compatibility handles for older debug tools. Dry landing allocates no water FX.
var ocean_floats: Array[MeshInstance3D] = []
var ocean_float_braces: Array[MeshInstance3D] = []
var ocean_splash_crown: MeshInstance3D
var ocean_splash_ring: MeshInstance3D
var landing_gear_deployment := 1.0
var landing_strut_compression := 1.0
var ocean_float_deployment := 0.0
var _saved_collision_layer := 1
var _saved_collision_mask := 1
var _scripted_flight := false
var _landing_recovery_elapsed := LANDING_RECOVERY_SECONDS
var _render_driven := false
var _authority_clock_initialized := false
var _received_authority_clock := false
var _authority_elapsed := 0.0
var _authority_age := 0.0
var _render_clock_rate := 1.0
var _saved_interpolation_mode := Node.PHYSICS_INTERPOLATION_MODE_INHERIT
var _outbound_attitude_frames: Array[Quaternion] = []
var _attitude_earth_route := Transform3D.IDENTITY
var _attitude_moon_route := Transform3D.IDENTITY


func _ready() -> void:
	name = "LunarRocket"
	mass = 68_000.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, -2.8, 0.0)
	# The propellant-filled body dominates inertia. Keep its principal axes
	# stable instead of repeatedly deriving a nearly symmetric tensor from the
	# rotating leg/window contact shapes (which can fail Basis.diagonalize).
	inertia = Vector3(4_000_000.0, 420_000.0, 4_000_000.0)
	continuous_cd = true
	can_sleep = true
	linear_damp = 0.08
	angular_damp = 1.4
	if get_child_count() == 0 and _setup_phase == SetupPhase.NOT_STARTED:
		_build_rocket()
	if earth_launch_transform == Transform3D.IDENTITY:
		earth_launch_transform = global_transform
	_update_effects()
	set_physics_process(_setup_phase in [SetupPhase.NOT_STARTED, SetupPhase.COMPLETE])


func begin_setup() -> void:
	if _setup_phase != SetupPhase.NOT_STARTED:
		return
	_setup_phase = SetupPhase.RESOURCES
	set_physics_process(false)


func is_setup_complete() -> bool:
	return _setup_phase == SetupPhase.COMPLETE


func setup_phase_name() -> String:
	if _setup_phase == SetupPhase.VOYAGE and voyage_visuals:
		return "voyage_" + voyage_visuals.setup_phase_name()
	return String(SetupPhase.keys()[_setup_phase]).to_lower()


func build_setup_step(budget_usec: int = 2000) -> bool:
	if is_queued_for_deletion():
		return false
	if _setup_phase == SetupPhase.NOT_STARTED:
		begin_setup()
	match _setup_phase:
		SetupPhase.RESOURCES:
			_ensure_shared_resources()
		SetupPhase.STRUCTURE:
			_build_structure()
		SetupPhase.CABIN:
			_build_cabin()
		SetupPhase.LADDER:
			_build_access_ladder(_setup_exterior)
		SetupPhase.EXTERIOR_BATCH, SetupPhase.CABIN_BATCH:
			var interior := _setup_phase == SetupPhase.CABIN_BATCH
			if not _build_static_batch_step(cabin if interior else _setup_exterior,
					interior, budget_usec):
				return false
		SetupPhase.GEAR:
			_build_landing_mechanisms()
		SetupPhase.FLAMES:
			_build_flame_meshes()
		SetupPhase.LAUNCH_PLUME:
			launch_plume = _build_launch_plume()
			add_child(launch_plume)
		SetupPhase.REENTRY_FLAMES:
			reentry_flames = _build_reentry_flames()
			add_child(reentry_flames)
		SetupPhase.LUNAR_DUST:
			_build_dust_effects()
		SetupPhase.VOYAGE:
			if not voyage_visuals:
				voyage_visuals = SpaceVoyageVisuals.new()
				voyage_visuals.name = "VoyagePresentation"
				voyage_visuals.begin_setup()
				add_child(voyage_visuals)
			if not voyage_visuals.build_setup_step(budget_usec):
				return false
		SetupPhase.COMPLETE:
			return true
	_setup_phase = (_setup_phase + 1) as SetupPhase
	if is_setup_complete():
		_update_effects()
		set_physics_process(true)
	return is_setup_complete()


func configure_route(earth_launch: Transform3D, moon_landing: Transform3D,
		ocean_splashdown: Transform3D, lunar_surface: MoonWorld = null) -> void:
	earth_launch_transform = earth_launch
	moon_landing_transform = moon_landing
	ocean_splashdown_transform = ocean_splashdown
	_dust_surface = lunar_surface
	_dust_sheet_target_radius = -1.0
	_outbound_attitude_frames.clear()
	_ensure_outbound_attitude_frames()
	if voyage_visuals:
		voyage_visuals.reset_route_anchors()
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
	var slot := manifest_seat_for_peer(peer_id) \
		if authoritative_manifest and not _manifest_seat_slots.is_empty() \
		else _first_free_seat()
	if slot < 0:
		return -1
	for member in crew:
		if int(member.seat) == slot:
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


## Authority order is the seat map, including actors not created on this peer
## yet. Call after removing obsolete members and before attaching new actors.
## This changes no transforms; the manager emits final crew poses only after
## realm changes and the entire manifest pass have finished.
func reconcile_manifest_seats(peer_ids: Array) -> bool:
	if peer_ids.size() > MAX_CREW:
		return false
	var next_slots: Dictionary = {}
	for index in range(peer_ids.size()):
		var peer_id: Variant = peer_ids[index]
		if not (peer_id is int) or int(peer_id) <= 0 or next_slots.has(peer_id):
			return false
		next_slots[peer_id] = index
	_manifest_seat_slots = next_slots
	for member in crew:
		if next_slots.has(int(member.peer_id)):
			member.seat = int(next_slots[int(member.peer_id)])
	return true


func manifest_seat_for_peer(peer_id: int) -> int:
	return int(_manifest_seat_slots.get(peer_id, -1))


func seat_global_transform(index: int) -> Transform3D:
	if index < 0 or index >= seat_nodes.size():
		return global_transform
	return seat_nodes[index].global_transform


## Camera and seated actor use the same hull transform at the same render time.
## -Z looks through the flight deck windows; pitch/yaw look is owned by the camera.
func cabin_eye_local_transform(seat_index: int = 0) -> Transform3D:
	return Transform3D(Basis.IDENTITY,
		SEAT_OFFSETS[clampi(seat_index, 0, MAX_CREW - 1)] + CABIN_EYE_OFFSET)


func cabin_eye_global_transform(seat_index: int = 0) -> Transform3D:
	return global_transform * cabin_eye_local_transform(seat_index)


func boarding_global_position() -> Vector3:
	return global_transform * BOARDING_LOCAL_POSITION


func disembark_local_position(slot: int = 0) -> Vector3:
	# Beside the ladder, outside the deployed feet and clear of the pressure hull.
	return BOARDING_LOCAL_POSITION + Vector3((clampi(slot, 0, MAX_CREW - 1) - 1.5) * 1.0,
		0.0, 0.25)


func disembark_global_position(slot: int = 0) -> Vector3:
	return global_transform * disembark_local_position(slot)


static func hull_bounds() -> AABB:
	return AABB(Vector3(-3.65, ENGINE_EXIT_Y, -3.65),
		Vector3(7.3, HULL_TOP - ENGINE_EXIT_Y, 7.3))


static func physical_bounds() -> AABB:
	return AABB(Vector3(-6.5, -ORIGIN_ABOVE_LANDING_SURFACE - LANDING_STRUT_TRAVEL, -6.5),
		Vector3(13.0, HULL_TOP + ORIGIN_ABOVE_LANDING_SURFACE + LANDING_STRUT_TRAVEL, 13.0))


## Fit the settled, fully compressed landing feet to the final terrain. The
## generator's authored pad height can differ after town/road grading. Sharing
## this contact frame with the authority keeps the visible hatch and its range
## check at the same position on every client.
static func grounded_landing_transform(nominal_surface: Vector3,
		heading: Basis, height_at: Callable) -> Transform3D:
	var frame := Transform3D(heading.orthonormalized(), nominal_surface
		+ heading.y.normalized() * ORIGIN_ABOVE_LANDING_SURFACE)
	var soles := landing_sole_points()
	for iteration in range(4):
		var samples: Array[Vector3] = []
		var mean := Vector3.ZERO
		for sole in soles:
			var point := frame * sole
			point.y = float(height_at.call(point.x, point.z))
			samples.append(point)
			mean += point
		mean /= float(samples.size())
		var xx := 0.0
		var xz := 0.0
		var zz := 0.0
		var xy := 0.0
		var zy := 0.0
		for point in samples:
			var offset := point - mean
			xx += offset.x * offset.x
			xz += offset.x * offset.z
			zz += offset.z * offset.z
			xy += offset.x * offset.y
			zy += offset.z * offset.y
		var determinant := xx * zz - xz * xz
		if absf(determinant) < 0.000001:
			break
		var slope_x := (xy * zz - zy * xz) / determinant
		var slope_z := (zy * xx - xy * xz) / determinant
		var up := Vector3(-slope_x, 1.0, -slope_z).normalized()
		frame.basis = _basis_with_up(up, heading.z)
		var center_height := mean.y + slope_x * (nominal_surface.x - mean.x) \
			+ slope_z * (nominal_surface.z - mean.z)
		frame.origin = Vector3(nominal_surface.x, center_height, nominal_surface.z) \
			+ up * ORIGIN_ABOVE_LANDING_SURFACE
	# Account for curvature and small grading irregularities at every actual
	# sole corner. A vertical correction preserves all sampled X/Z positions.
	var contact_lift := -INF
	for sole in soles:
		var point := frame * sole
		contact_lift = maxf(contact_lift, float(height_at.call(point.x, point.z)) - point.y)
	frame.origin.y += contact_lift
	return frame


static func landing_sole_points() -> Array[Vector3]:
	var points: Array[Vector3] = []
	for direction in _landing_directions():
		var yaw := Basis(Vector3.UP, atan2(direction.x, direction.z))
		var center := direction * LANDING_FOOT_RADIUS \
			+ Vector3.DOWN * ORIGIN_ABOVE_LANDING_SURFACE
		for x in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				points.append(center + yaw * Vector3(x * LANDING_FOOT_SIZE.x,
					0.0, z * LANDING_FOOT_SIZE.z))
	return points


static func _landing_directions() -> Array[Vector3]:
	return [Vector3(1, 0, 1).normalized(), Vector3(-1, 0, 1).normalized(),
		Vector3(1, 0, -1).normalized(), Vector3(-1, 0, -1).normalized()]


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
	_landing_recovery_elapsed = LANDING_RECOVERY_SECONDS
	_reset_authority_anchor()
	_received_authority_clock = false
	_set_scripted_flight(true)
	_set_state(State.LAUNCH_ASCENT)
	voyage_visuals.begin_voyage(true)
	_update_effects()
	camera_cue.emit(&"launch_and_tower_pullback", 8.0)
	presentation_phase_changed.emit(state, true)
	return true


func begin_return_to_earth() -> bool:
	if state != State.LANDED_MOON or crew.is_empty():
		return false
	outbound = false
	voyage_elapsed = 0.0
	_landing_recovery_elapsed = LANDING_RECOVERY_SECONDS
	_reset_authority_anchor()
	_received_authority_clock = false
	_set_scripted_flight(true)
	_set_state(State.RETURN_ASCENT)
	voyage_visuals.begin_voyage(false)
	_update_effects()
	camera_cue.emit(&"lunar_launch_pullback", 7.0)
	presentation_phase_changed.emit(state, false)
	return true


func _physics_process(delta: float) -> void:
	if not _render_driven:
		if is_in_transit():
			advance_voyage(delta)
		else:
			_emit_crew_poses()
	elif not is_in_transit():
		_emit_crew_poses()


## ExpeditionManager enables this before the first physics tick. It then owns
## one render-frame sample for the frozen hull, planets, passengers and camera.
## Explicit advance_voyage calls remain deterministic standalone/test controls.
func set_render_driven(enabled: bool = true) -> void:
	_render_driven = enabled


func _reset_authority_anchor() -> void:
	_authority_elapsed = voyage_elapsed
	_authority_age = 0.0
	_authority_clock_initialized = true
	_render_clock_rate = 1.0


func advance_render_clock(delta: float) -> void:
	_render_driven = true
	if not is_in_transit() or not is_finite(delta) or delta <= 0.0:
		return
	if not _authority_clock_initialized:
		_reset_authority_anchor()
	_authority_age += delta
	var step := minf(delta, MAX_RENDER_CLOCK_STEP)
	var expected := _authority_elapsed + _authority_age
	# Compare against the end of this frame, so an undisturbed clock runs at
	# exactly 1x at every refresh rate. Corrections alter speed by at most 8%; a
	# delayed snapshot can never reverse the craft or teleport the camera.
	var error := expected - (voyage_elapsed + step)
	var target_rate := 1.0 + clampf(error * CLOCK_CORRECTION_GAIN,
		-MAX_CLOCK_RATE_CORRECTION, MAX_CLOCK_RATE_CORRECTION)
	# Smooth the shared clock's rate as well, so a 1 Hz packet cannot introduce
	# a sudden speed change even though the hull and camera remain synchronized.
	_render_clock_rate = lerpf(_render_clock_rate, target_rate, 1.0 - exp(-step * 6.0))
	_advance_clock(step * _render_clock_rate)


func render_sample(elapsed_override: float = -1.0) -> Dictionary:
	var duration := OUTBOUND_DURATION_SECONDS if outbound else RETURN_DURATION_SECONDS
	var elapsed := clampf(elapsed_override if elapsed_override >= 0.0 else voyage_elapsed,
		0.0, duration)
	var sample_state := state_for_elapsed(outbound, elapsed) \
		if is_in_transit() or elapsed_override >= 0.0 else state
	return {"elapsed": elapsed, "progress": elapsed / duration,
		"state": sample_state, "outbound": outbound,
		"transform": _flight_transform(elapsed / duration) \
			if is_in_transit() or elapsed_override >= 0.0 else global_transform}


func present_render_sample(sample: Dictionary) -> void:
	if sample.is_empty():
		return
	var was_in_transit := is_in_transit()
	var sample_state := int(sample.state)
	var sample_in_transit := sample_state not in [State.EARTH_BOARDING,
		State.LANDED_MOON, State.SPLASHDOWN]
	global_transform = sample.transform
	if was_in_transit or sample_in_transit:
		voyage_elapsed = float(sample.elapsed)
		var duration := OUTBOUND_DURATION_SECONDS if outbound else RETURN_DURATION_SECONDS
		if voyage_elapsed >= duration:
			if outbound:
				_complete_moon_landing()
			else:
				_complete_splashdown()
		else:
			_set_scripted_flight(true)
			_set_state(sample_state)
			if voyage_visuals:
				voyage_visuals.update_voyage(float(sample.progress), state, outbound)
			_update_effects()
		voyage_progress.emit(float(sample.progress), voyage_elapsed,
			maxf(duration - voyage_elapsed, 0.0))
	_emit_crew_poses()


func advance_voyage(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta) or not is_in_transit():
		return
	_advance_clock(delta)
	present_render_sample(render_sample())


func _advance_clock(delta: float) -> void:
	var duration := OUTBOUND_DURATION_SECONDS if outbound \
		else RETURN_DURATION_SECONDS
	var previous_elapsed := voyage_elapsed
	voyage_elapsed = minf(voyage_elapsed + delta, duration)
	_emit_crossed_phases(previous_elapsed, voyage_elapsed)


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
		# Presentation owns the exponential 8.5 km density curve and exact 100 km+
		# vacuum clamp. Reuse it so gameplay/status consumers cannot report thick air
		# after the camera has visibly cleared the atmosphere.
		if voyage_visuals:
			return voyage_visuals.atmosphere_density
		return clampf(1.0 - voyage_elapsed / OUTBOUND_PHASE_TIMES[0], 0.0, 1.0)
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


## Live replication updates the target clock without replacing a displayed
## pose. Initial joins and new missions still seek immediately and exactly.
func synchronize_authoritative_clock(authoritative_state: int,
		authoritative_outbound: bool, elapsed_seconds: float) -> void:
	if not is_finite(elapsed_seconds):
		return
	var terminal := authoritative_state in [State.EARTH_BOARDING,
		State.LANDED_MOON, State.SPLASHDOWN]
	if not _received_authority_clock or not is_in_transit() \
			or authoritative_outbound != outbound or terminal:
		apply_authoritative_clock(authoritative_state, authoritative_outbound, elapsed_seconds)
		return
	var duration := OUTBOUND_DURATION_SECONDS if outbound else RETURN_DURATION_SECONDS
	_authority_elapsed = clampf(elapsed_seconds, 0.0, duration)
	_authority_age = 0.0


## Explicit deterministic seek used by standalone previews and test fixtures.
## Live packets go through synchronize_authoritative_clock instead.
func apply_authoritative_clock(authoritative_state: int,
		authoritative_outbound: bool, elapsed_seconds: float) -> void:
	if not is_finite(elapsed_seconds):
		return
	# Exact seeks are mature terminal poses until the authority explicitly
	# supplies recovery age; late snapshots see the fully settled gear.
	_landing_recovery_elapsed = LANDING_RECOVERY_SECONDS
	outbound = authoritative_outbound
	var next_state := clampi(authoritative_state, State.EARTH_BOARDING,
		State.SPLASHDOWN)
	if state != next_state:
		state = next_state
		state_changed.emit(state, STATE_NAMES[state])
	var duration := OUTBOUND_DURATION_SECONDS if outbound \
		else RETURN_DURATION_SECONDS
	voyage_elapsed = clampf(elapsed_seconds, 0.0, duration)
	_reset_authority_anchor()
	_received_authority_clock = true
	if is_in_transit():
		_set_scripted_flight(true)
		global_transform = _flight_transform(voyage_elapsed / duration)
		if voyage_visuals:
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


func lunar_dust_particle_budget() -> int:
	return lunar_dust.amount if lunar_dust else 0


func lunar_surface_clearance() -> float:
	return (global_position - moon_landing_transform.origin).dot(
		moon_landing_transform.basis.y.normalized())


## A pure mechanical pose, sampled from the same voyage clock as the hull.
## Moon contact finishes inside the 60 s route. A late MOON_READY snapshot is
## therefore already settled and never replays an ignition or touchdown burst.
func landing_presentation_sample(elapsed_override: float = -1.0,
		recovery_override: float = -1.0) -> Dictionary:
	var elapsed := voyage_elapsed if elapsed_override < 0.0 else elapsed_override
	var sample_state := state if elapsed_override < 0.0 \
		else state_for_elapsed(outbound, elapsed)
	var duration := OUTBOUND_DURATION_SECONDS if outbound else RETURN_DURATION_SECONDS
	var sample_origin := _flight_origin(clampf(elapsed / duration, 0.0, 1.0))
	var gear := 0.0
	var compression := 0.0
	var thrust_multiplier := 1.0
	var dust := 0.0
	match sample_state:
		State.EARTH_BOARDING, State.LANDED_MOON, State.SPLASHDOWN:
			gear = 1.0
			compression = 1.0
			thrust_multiplier = 0.0
		State.LAUNCH_ASCENT, State.RETURN_ASCENT:
			gear = 1.0 - _landing_ease(1.4, 6.0, elapsed)
			var departure := earth_launch_transform if outbound else moon_landing_transform
			var lift := maxf((sample_origin - departure.origin).dot(
				departure.basis.y.normalized()), 0.0)
			compression = 1.0 - clampf(lift / LANDING_STRUT_TRAVEL, 0.0, 1.0)
			dust = clampf(1.0 - lift / LUNAR_DUST_CLEARANCE, 0.0, 1.0)
		State.LUNAR_APPROACH:
			gear = _landing_ease(LANDING_GEAR_DEPLOY_START, LANDING_GEAR_DEPLOY_END, elapsed)
			var clearance := maxf((sample_origin - moon_landing_transform.origin).dot(
				moon_landing_transform.basis.y.normalized()), 0.0)
			compression = 1.0 - clampf(clearance / LANDING_STRUT_TRAVEL, 0.0, 1.0)
			thrust_multiplier = 1.0 - _landing_ease(59.82, OUTBOUND_DURATION_SECONDS, elapsed)
			dust = clampf(1.0 - clearance / LUNAR_DUST_CLEARANCE, 0.0, 1.0) \
				* (1.0 - _landing_ease(59.4, OUTBOUND_DURATION_SECONDS, elapsed))
		State.REENTRY, State.OCEAN_APPROACH:
			gear = _landing_ease(EARTH_GEAR_DEPLOY_START, EARTH_GEAR_DEPLOY_END, elapsed)
			var clearance := maxf((sample_origin - ocean_splashdown_transform.origin).dot(
				ocean_splashdown_transform.basis.y.normalized()), 0.0)
			compression = 1.0 - clampf(clearance / LANDING_STRUT_TRAVEL, 0.0, 1.0)
			thrust_multiplier = 1.0 - _landing_ease(44.82, RETURN_DURATION_SECONDS, elapsed)
			dust = clampf(1.0 - clearance / LUNAR_DUST_CLEARANCE, 0.0, 1.0) \
				* (1.0 - _landing_ease(44.4, RETURN_DURATION_SECONDS, elapsed))
	var recovery := _landing_recovery_elapsed if recovery_override < 0.0 else recovery_override
	return {"gear_deployment": gear, "strut_compression": compression,
		"float_deployment": 0.0, "thrust_multiplier": thrust_multiplier,
		"dust_strength": dust, "splash_crown": 0.0, "splash_ring": 0.0,
		"recovery_elapsed": clampf(recovery, 0.0, LANDING_RECOVERY_SECONDS)}


## Recovery is a settled dry pad pose. Contact compression and cutoff finish on
## the voyage clock, so all observers and late joins see identical mechanisms.
func present_landing_recovery(elapsed_seconds: float) -> void:
	if state == State.SPLASHDOWN and is_finite(elapsed_seconds):
		_landing_recovery_elapsed = clampf(elapsed_seconds, 0.0, LANDING_RECOVERY_SECONDS)


static func _landing_ease(start: float, finish: float, elapsed: float) -> float:
	return _quintic_time(clampf(inverse_lerp(start, finish, elapsed), 0.0, 1.0))


func _update_landing_mechanisms(pose: Dictionary) -> void:
	landing_gear_deployment = float(pose.gear_deployment)
	landing_strut_compression = float(pose.strut_compression)
	ocean_float_deployment = 0.0
	var extension := LANDING_STRUT_TRAVEL * (1.0 - landing_strut_compression)
	for leg in landing_gear:
		var direction: Vector3 = leg.direction
		var mount := direction * 3.38 + Vector3.DOWN * 6.3
		var stowed_foot := direction * 3.52 + Vector3.DOWN * 8.2
		var deployed_foot := direction * LANDING_FOOT_RADIUS \
			+ Vector3.DOWN * (ORIGIN_ABOVE_LANDING_SURFACE - LANDING_FOOT_SIZE.y * 0.5 + extension)
		var foot_position := stowed_foot.lerp(deployed_foot, landing_gear_deployment)
		var knee := mount.lerp(foot_position, 0.56)
		_pose_landing_segment(leg.arm, mount, knee)
		_pose_landing_segment(leg.piston, mount.lerp(foot_position, 0.49), foot_position)
		_pose_landing_segment(leg.brace, direction * 3.44 + Vector3.DOWN * 8.0,
			mount.lerp(foot_position, 0.75))
		var foot: MeshInstance3D = leg.foot
		var yaw := atan2(direction.x, direction.z)
		foot.transform = Transform3D(Basis(Vector3.UP, yaw)
			* Basis(Vector3.RIGHT, (1.0 - landing_gear_deployment) * PI * 0.46), foot_position)
		var contact_shape: CollisionShape3D = leg.collision
		contact_shape.transform = foot.transform


static func _pose_landing_segment(segment: MeshInstance3D,
		start: Vector3, finish: Vector3) -> void:
	var delta := finish - start
	var frame := _basis_with_up(delta.normalized(), Vector3.FORWARD)
	segment.transform = Transform3D(frame.scaled_local(
		Vector3(1.0, maxf(delta.length(), 0.001), 1.0)), (start + finish) * 0.5)


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
			camera_cue.emit(&"landing_gear_deploying", 12.0)
		State.RETURN_CRUISE:
			camera_cue.emit(&"moon_recedes_earth_grows", 12.0)
		State.REENTRY:
			camera_cue.emit(&"heatshield_reentry", 18.0)
		State.OCEAN_APPROACH:
			camera_cue.emit(&"powered_landing_legs_deploying", 5.0)


func _flight_transform(progress: float) -> Transform3D:
	progress = clampf(progress, 0.0, 1.0)
	if progress <= 0.0:
		return earth_launch_transform if outbound else moon_landing_transform
	if progress >= 1.0:
		return moon_landing_transform if outbound else ocean_splashdown_transform
	var origin := _flight_origin(progress)
	var start := earth_launch_transform if outbound else moon_landing_transform
	var finish := moon_landing_transform if outbound \
		else ocean_splashdown_transform
	var endpoint_blend := _quintic_time(inverse_lerp(0.94, 1.0, progress)) \
		if outbound else _landing_ease(32.0, 40.0, progress * RETURN_DURATION_SECONDS)
	# Powered ascent points the nose (+Y) along the climb. The outbound craft
	# becomes upright before lunar descent instead of diving nose-first into the
	# pad. On return, the heat shield (-Y) faces the Earth-bound path after the
	# six-second powered Moon ascent.
	# The authored flight attitudes use stable route directions. Differencing
	# two 48 km world positions to infer attitude amplified float quantization
	# whenever the trajectory slowed down, visibly shaking the hull at landing.
	var flight_basis := start.basis.orthonormalized()
	if outbound:
		var approach_fraction := OUTBOUND_PHASE_TIMES[2] \
			/ OUTBOUND_DURATION_SECONDS
		var launch_fraction := OUTBOUND_PHASE_TIMES[0] \
			/ OUTBOUND_DURATION_SECONDS
		if progress > launch_fraction:
			# In the map leg, face the destination rather than the insertion arc's
			# temporary velocity. This keeps the rocket visibly Moon-bound while the
			# arc carries it above the lunar limb for a safe top-down approach.
			var direction_to_moon := (finish.origin - origin).normalized()
			if direction_to_moon.length_squared() > 0.5:
				var destination_basis := _transported_outbound_attitude(
					progress * OUTBOUND_DURATION_SECONDS, direction_to_moon)
				var pitch_blend := _quintic_time(inverse_lerp(launch_fraction,
					(OUTBOUND_PHASE_TIMES[0] + 2.0) / OUTBOUND_DURATION_SECONDS, progress))
				flight_basis = Basis(start.basis.get_rotation_quaternion().slerp(
					destination_basis.get_rotation_quaternion(), pitch_blend))
		# Keep the nose on the Moon-bound tangent through the transfer. The map-to-
		# ground bridge (46-50 s) then rotates the lander upright before descent,
		# avoiding both the old broadside flight and a touchdown rotation snap.
		var flip_start_fraction := LUNAR_FLIP_START_SECONDS \
			/ OUTBOUND_DURATION_SECONDS
		var preflip_start_fraction := LUNAR_PREFLIP_START_SECONDS / OUTBOUND_DURATION_SECONDS
		var nose_down_basis := _basis_with_up(
			-finish.basis.y.normalized(), finish.basis.z.normalized())
		if progress >= flip_start_fraction:
			# At ignition the nose points at the Moon. Rotate around a horizontal
			# landing-frame axis so the midpoint is visibly broadside and the engine
			# points down at the exact start of powered descent.
			var upright_blend := _quintic_time(inverse_lerp(flip_start_fraction,
				approach_fraction, progress))
			flight_basis = Basis(nose_down_basis.get_rotation_quaternion().slerp(
				finish.basis.get_rotation_quaternion(),
				upright_blend)).orthonormalized()
		elif progress >= preflip_start_fraction:
			# Ease from the route tangent into the nose-down ignition pose before the
			# fixed Moon-frame camera begins, avoiding a hidden one-frame attitude cut.
			var preflip := _quintic_time(inverse_lerp(preflip_start_fraction,
				flip_start_fraction, progress))
			flight_basis = Basis(flight_basis.get_rotation_quaternion().slerp(
				nose_down_basis.get_rotation_quaternion(), preflip)).orthonormalized()
	else:
		var ascent_fraction := RETURN_PHASE_TIMES[0] \
			/ RETURN_DURATION_SECONDS
		if progress > ascent_fraction:
			# The shield faces the destination, including across the insertion
			# arc's apex. Negating an instantaneous velocity used to flip the
			# capsule twice as the vertical speed passed through zero.
			var away_from_earth := origin - finish.origin
			var earthbound_basis := _basis_with_up(away_from_earth, start.basis.z) \
				if away_from_earth.length_squared() > 0.000001 else finish.basis
			var return_turn := _quintic_time(inverse_lerp(ascent_fraction,
				10.0 / RETURN_DURATION_SECONDS, progress))
			flight_basis = Basis(start.basis.get_rotation_quaternion().slerp(
				earthbound_basis.get_rotation_quaternion(),
				return_turn)).orthonormalized()
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
		# The opening climb is genuinely powered: X/Z stay pinned, velocity starts
		# near zero, and each early one-second interval rises farther than the last.
		# The previous ease-out curve did the opposite and looked like a rocket
		# slowing down immediately after leaving the pad.
		var launch_fraction := OUTBOUND_PHASE_TIMES[0] \
			/ OUTBOUND_DURATION_SECONDS
		# The playable Moon normally lives in a distant realm, but standalone
		# fixtures and future realm layouts may author its landing pad below the
		# Earth pad. Liftoff is still a physical upward climb, never a signed lerp
		# toward the destination altitude.
		if progress <= launch_fraction:
			var launch_t := progress / launch_fraction
			var ascent := EARTH_ASCENT_HEIGHT * pow(launch_t, 2.35)
			return start.origin + start.basis.y.normalized() * ascent
		var approach_fraction := OUTBOUND_PHASE_TIMES[2] \
			/ OUTBOUND_DURATION_SECONDS
		var landing_up := finish.basis.y.normalized()
		var approach_start := finish.origin \
			+ landing_up * LUNAR_APPROACH_HEIGHT \
			+ finish.basis.z.normalized() * LUNAR_APPROACH_OFFSET
		if progress >= approach_fraction:
			# The final ten seconds come from above the real lunar terrain.
			# The quintic ease gives ignition and contact zero velocity and
			# acceleration, matching the cruise endpoint without a braking jolt.
			var descent_t := _quintic_time(inverse_lerp(approach_fraction, 1.0, progress))
			return approach_start.lerp(finish.origin, descent_t)
		var cruise_phase := inverse_lerp(launch_fraction, approach_fraction, progress)
		var cruise_t := _quintic_time(cruise_phase)
		var launch_up := start.basis.y.normalized()
		var launch_top := start.origin + launch_up * EARTH_ASCENT_HEIGHT
		var climb_seconds := float(OUTBOUND_PHASE_TIMES[0])
		var cruise_seconds := float(OUTBOUND_PHASE_TIMES[2] - OUTBOUND_PHASE_TIMES[0])
		var climb_speed := EARTH_ASCENT_HEIGHT * 2.35 / climb_seconds
		var climb_acceleration := EARTH_ASCENT_HEIGHT * 2.35 * 1.35 \
			/ (climb_seconds * climb_seconds)
		var cruise_position := _departure_bridge(launch_top, approach_start,
			launch_up * climb_speed, launch_up * climb_acceleration, cruise_seconds, cruise_phase)
		# The Moon realm is stacked above Earth in local coordinates. A straight
		# lerp therefore approached the landing tangent from inside/below the Moon.
		# This zero-endpoint insertion arc carries the craft around the visible limb
		# and leaves it hundreds of metres above the surface before final descent.
		var insertion_lift := sin(cruise_t * PI) * 14_000.0
		cruise_position += landing_up * insertion_lift
		# A derivative-zero lateral arc gives the cruise a readable orbital
		# silhouette without kicking sideways at liftoff or lunar descent.
		# A wider pass keeps the destination bearing from whipping around as
		# the rocket crosses the Moon's altitude. The hull can keep pointing
		# exactly at the Moon while turning at a calm, bounded angular speed.
		var arc := pow(sin(cruise_t * PI), 2.0) * INSERTION_LATERAL_CLEARANCE_METERS
		var arc_direction := Vector2(-1.0, 0.0).rotated(
			atan2(approach_start.z - launch_top.z,
				approach_start.x - launch_top.x) + PI * 0.5)
		return cruise_position + Vector3(arc_direction.x, 0.0,
			arc_direction.y) * arc
	# Return begins with a genuine six-second Moon liftoff. X/Z stay pinned while
	# the surface falls away below the upright rocket; only then does the faster
	# heat-shield-first Earth leg begin.
	var ascent_fraction := RETURN_PHASE_TIMES[0] / RETURN_DURATION_SECONDS
	var moon_up := start.basis.y.normalized()
	if progress <= ascent_fraction:
		var ascent_t := progress / ascent_fraction
		var ascent := LUNAR_ASCENT_HEIGHT * pow(ascent_t, 2.25)
		return start.origin + moon_up * ascent
	var ascent_top := start.origin + moon_up * LUNAR_ASCENT_HEIGHT
	var approach_fraction := RETURN_PHASE_TIMES[2] / RETURN_DURATION_SECONDS
	var approach_start := finish.origin + finish.basis.y.normalized() * EARTH_APPROACH_HEIGHT
	if progress >= approach_fraction:
		# Finish over the original pad: fully upright, no lateral slide, and zero
		# velocity/acceleration at ignition and touchdown. Suspension takes the
		# last 85 cm while the hull remains on this uninterrupted trajectory.
		return approach_start.lerp(finish.origin,
			_quintic_time(inverse_lerp(approach_fraction, 1.0, progress)))
	var travel_phase := inverse_lerp(ascent_fraction, approach_fraction, progress)
	var travel_t := _quintic_time(travel_phase)
	var midpoint_lift := pow(sin(travel_t * PI), 2.0) * 9_000.0
	var ascent_seconds := float(RETURN_PHASE_TIMES[0])
	var travel_seconds := float(RETURN_PHASE_TIMES[2]) - ascent_seconds
	var ascent_speed := LUNAR_ASCENT_HEIGHT * 2.25 / ascent_seconds
	var ascent_acceleration := LUNAR_ASCENT_HEIGHT * 2.25 * 1.25 \
		/ (ascent_seconds * ascent_seconds)
	return _departure_bridge(ascent_top, approach_start, moon_up * ascent_speed,
		moon_up * ascent_acceleration, travel_seconds, travel_phase) \
		+ Vector3.UP * midpoint_lift \
		+ start.basis.x.normalized() * pow(sin(travel_t * PI), 2.0) \
			* INSERTION_LATERAL_CLEARANCE_METERS


static func _quintic_time(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * t * (10.0 + t * (-15.0 + t * 6.0))


## Parallel-transport a small, deterministic frame table once per route. A
## projected global forward vector flips when the nose crosses that vector;
## a single launch-to-nose quaternion has a second singularity at its antipode.
## Adjacent route samples have small angular changes, so neither case arises.
## Interpolation keeps random-access previews identical to live rendering.
func _ensure_outbound_attitude_frames() -> void:
	if not _outbound_attitude_frames.is_empty() \
			and _attitude_earth_route == earth_launch_transform \
			and _attitude_moon_route == moon_landing_transform:
		return
	_outbound_attitude_frames.clear()
	_attitude_earth_route = earth_launch_transform
	_attitude_moon_route = moon_landing_transform
	var saved_outbound := outbound
	outbound = true
	var frame := earth_launch_transform.basis.orthonormalized()
	var start_seconds := float(OUTBOUND_PHASE_TIMES[0])
	var sample_count := roundi((LUNAR_FLIP_START_SECONDS - start_seconds) / ATTITUDE_SAMPLE_SECONDS)
	for index in range(sample_count + 1):
		var elapsed := start_seconds + index * ATTITUDE_SAMPLE_SECONDS
		var direction := (moon_landing_transform.origin \
			- _flight_origin(elapsed / OUTBOUND_DURATION_SECONDS)).normalized()
		if direction.length_squared() > 0.5:
			var swing := Quaternion(frame.y.normalized(), direction)
			frame = (Basis(swing) * frame).orthonormalized()
		_outbound_attitude_frames.append(frame.get_rotation_quaternion())
	outbound = saved_outbound


func _transported_outbound_attitude(elapsed: float, direction: Vector3) -> Basis:
	_ensure_outbound_attitude_frames()
	var cursor := clampf((elapsed - float(OUTBOUND_PHASE_TIMES[0])) \
		/ ATTITUDE_SAMPLE_SECONDS, 0.0, float(_outbound_attitude_frames.size() - 1))
	var first := floori(cursor)
	var second := mini(first + 1, _outbound_attitude_frames.size() - 1)
	var frame := Basis(_outbound_attitude_frames[first].slerp(
		_outbound_attitude_frames[second], cursor - float(first)))
	# Restore the exact analytic nose after interpolation. This swing is always
	# tiny, while the transported roll remains continuous through every heading.
	return (Basis(Quaternion(frame.y.normalized(), direction)) * frame).orthonormalized()


## Quintic Hermite bridge: preserve powered-climb velocity AND acceleration,
## then reach the next authored pose at rest. The previous smoothstep lerp
## discarded 2,014 m/s at Earth departure and 1,350 m/s at Moon departure in a
## single frame. Scalar polynomials also avoid finite-difference instability.
static func _departure_bridge(start: Vector3, finish: Vector3,
		initial_velocity: Vector3, initial_acceleration: Vector3,
		duration: float, progress: float) -> Vector3:
	var t := clampf(progress, 0.0, 1.0)
	var t2 := t * t
	var t3 := t2 * t
	var t4 := t3 * t
	var t5 := t4 * t
	var velocity_weight := t - 6.0 * t3 + 8.0 * t4 - 3.0 * t5
	var acceleration_weight := 0.5 * (t2 - 3.0 * t3 + 3.0 * t4 - t5)
	return start.lerp(finish, _quintic_time(t)) \
		+ initial_velocity * (duration * velocity_weight) \
		+ initial_acceleration * (duration * duration * acceleration_weight)


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
	_landing_recovery_elapsed = LANDING_RECOVERY_SECONDS
	global_transform = moon_landing_transform
	_set_state(State.LANDED_MOON)
	_set_scripted_flight(false)
	gravity_scale = MoonWorld.LUNAR_GRAVITY / 9.81
	freeze = true
	voyage_visuals.end_voyage()
	_update_effects()
	_equip_crew_for_moon()
	camera_cue.emit(&"lunar_touchdown", 6.0)
	moon_landing_completed.emit()


func _complete_splashdown() -> void:
	_landing_recovery_elapsed = 0.0
	global_transform = ocean_splashdown_transform
	_set_state(State.SPLASHDOWN)
	_set_scripted_flight(false)
	# The four compressed pads now support the hull at the original Earth pad.
	# There is no buoyancy, post-contact hull bob, or passenger-only splash effect.
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
	camera_cue.emit(&"earth_pad_touchdown", 5.0)
	earth_landing_completed.emit()
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
		_saved_interpolation_mode = physics_interpolation_mode
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
		physics_interpolation_mode = _saved_interpolation_mode
	reset_physics_interpolation()


func _set_state(next_state: int) -> void:
	if state == next_state:
		return
	state = next_state
	state_changed.emit(state, STATE_NAMES[state])


func _update_effects() -> void:
	if not launch_plume or not reentry_flames:
		return
	var landing_pose := landing_presentation_sample()
	_update_landing_mechanisms(landing_pose)
	var thrust_ratio := 0.0
	match state:
		State.LAUNCH_ASCENT:
			thrust_ratio = lerpf(0.38, 1.0, smoothstep(0.0, 4.0, voyage_elapsed))
		State.RETURN_ASCENT:
			thrust_ratio = lerpf(0.42, 1.0, smoothstep(0.0, 2.5, voyage_elapsed))
		State.ATMOSPHERE_EXIT:
			thrust_ratio = 0.72
		State.LUNAR_APPROACH:
			thrust_ratio = lerpf(0.34, 0.92, clampf(
				1.0 - maxf(lunar_surface_clearance(), 0.0) / LUNAR_APPROACH_HEIGHT, 0.0, 1.0))
		State.REENTRY:
			thrust_ratio = _landing_ease(38.5, 40.0, voyage_elapsed) * 0.36
		State.OCEAN_APPROACH:
			var clearance := maxf((global_position - ocean_splashdown_transform.origin).dot(
				ocean_splashdown_transform.basis.y.normalized()), 0.0)
			thrust_ratio = lerpf(0.36, 0.92, clampf(1.0 - clearance / EARTH_APPROACH_HEIGHT, 0.0, 1.0))
	thrust_ratio *= float(landing_pose.thrust_multiplier)
	launch_plume.emitting = thrust_ratio > 0.001
	launch_plume.visible = launch_plume.emitting
	launch_plume.amount_ratio = thrust_ratio
	var cutoff_scale := maxf(sqrt(float(landing_pose.thrust_multiplier)), 0.001)
	var effect_frame := _ground_effect_transform()
	var flame_limit := INF
	if state in [State.LAUNCH_ASCENT, State.RETURN_ASCENT,
			State.LUNAR_APPROACH, State.OCEAN_APPROACH]:
		var hull_clearance := (global_position - effect_frame.origin).dot(effect_frame.basis.y.normalized())
		flame_limit = maxf(hull_clearance + ORIGIN_ABOVE_LANDING_SURFACE + ENGINE_EXIT_Y - 0.08, 0.01)
	if exhaust_flame_core:
		exhaust_flame_core.visible = launch_plume.emitting
		exhaust_flame_core.scale = Vector3(lerpf(0.72, 1.08, thrust_ratio),
			lerpf(0.62, 1.18, thrust_ratio), lerpf(0.72, 1.08, thrust_ratio)) * cutoff_scale
		exhaust_flame_core.scale.y = minf(exhaust_flame_core.scale.y, flame_limit / 10.0)
		exhaust_flame_core.position.y = ENGINE_EXIT_Y - 5.0 * exhaust_flame_core.scale.y
	if exhaust_flame_glow:
		exhaust_flame_glow.visible = launch_plume.emitting
		exhaust_flame_glow.scale = Vector3(lerpf(0.70, 1.12, thrust_ratio),
			lerpf(0.58, 1.24, thrust_ratio), lerpf(0.70, 1.12, thrust_ratio)) * cutoff_scale
		exhaust_flame_glow.scale.y = minf(exhaust_flame_glow.scale.y, flame_limit / 12.8)
		exhaust_flame_glow.position.y = ENGINE_EXIT_Y - 6.4 * exhaust_flame_glow.scale.y
	var reentry_strength := _landing_ease(28.0, 30.0, voyage_elapsed) \
		* (1.0 - _landing_ease(38.0, 40.0, voyage_elapsed)) if state == State.REENTRY else 0.0
	reentry_flames.emitting = reentry_strength > 0.001
	reentry_flames.visible = reentry_flames.emitting
	reentry_flames.amount_ratio = reentry_strength
	if lunar_dust:
		lunar_dust.amount_ratio = float(landing_pose.dust_strength)
		lunar_dust.emitting = lunar_dust.amount_ratio > 0.001
		lunar_dust.visible = lunar_dust.emitting
		lunar_dust.global_transform = Transform3D(effect_frame.basis,
			effect_frame.origin - effect_frame.basis.y.normalized()
				* (ORIGIN_ABOVE_LANDING_SURFACE - 0.12))
		var cutoff_started := (state == State.LUNAR_APPROACH and voyage_elapsed >= 59.4) \
			or (state == State.OCEAN_APPROACH and voyage_elapsed >= 44.4)
		_update_lunar_dust_sheet(lunar_dust.amount_ratio, 1.0 if cutoff_started else -1.0)


func _ground_effect_transform() -> Transform3D:
	if state == State.LAUNCH_ASCENT or state == State.EARTH_BOARDING:
		return earth_launch_transform
	if state in [State.LUNAR_APPROACH, State.LANDED_MOON, State.RETURN_ASCENT]:
		return moon_landing_transform
	return ocean_splashdown_transform


func _update_lunar_dust_sheet(strength: float, radius_strength: float = -1.0) -> void:
	if not lunar_dust_sheet:
		return
	strength = clampf(strength, 0.0, 1.0)
	var visual_strength := smoothstep(0.0, 1.0, sqrt(strength))
	lunar_dust_sheet.visible = visual_strength > 0.01
	if not lunar_dust_sheet.visible:
		return
	var radius := lerpf(DUST_SHEET_MIN_RADIUS, DUST_SHEET_MAX_RADIUS,
		visual_strength if radius_strength < 0.0 else clampf(radius_strength, 0.0, 1.0))
	var radius_scale := radius / DUST_SHEET_MAX_RADIUS
	var frame := _ground_effect_transform()
	var contact := frame.origin - frame.basis.y.normalized() \
		* (ORIGIN_ABOVE_LANDING_SURFACE - DUST_SHEET_SURFACE_CLEARANCE)
	var lunar_contact := state in [State.LUNAR_APPROACH, State.RETURN_ASCENT]
	if lunar_contact and is_instance_valid(_dust_surface):
		# The crater mesh's collision facets are not an analytic sphere, even
		# near a graded pad. Project the expanding disk onto those exact facets.
		var tangent := Transform3D(frame.basis, frame.origin
			- frame.basis.y.normalized() * ORIGIN_ABOVE_LANDING_SURFACE)
		if not _dust_sheet_conforming or not is_equal_approx(radius,
				_dust_sheet_target_radius) or tangent != _dust_sheet_target_frame \
				or _dust_surface.global_transform != _dust_sheet_surface_transform:
			var inverse := tangent.affine_inverse()
			for index in range(_dust_sheet_template_vertices.size()):
				var point := _dust_sheet_template_vertices[index]
				point = tangent * Vector3(point.x * radius_scale, 0.0,
					point.z * radius_scale)
				_dust_sheet_vertices[index] = inverse * _dust_surface.surface_position_at(
					point, DUST_SHEET_SURFACE_CLEARANCE)
			_upload_dust_sheet_vertices()
			_dust_sheet_target_radius = radius
			_dust_sheet_target_frame = tangent
			_dust_sheet_surface_transform = _dust_surface.global_transform
			_dust_sheet_conforming = true
		lunar_dust_sheet.global_transform = tangent
	else:
		# Earth retains its flat landing-tangent effect. Standalone rocket
		# fixtures without a Moon surface retain the analytic spherical fallback.
		if _dust_sheet_conforming:
			for index in range(_dust_sheet_template_vertices.size()):
				_dust_sheet_vertices[index] = _dust_sheet_template_vertices[index]
			_upload_dust_sheet_vertices()
			_dust_sheet_conforming = false
		var sag_scale := radius_scale * radius_scale if lunar_contact else 0.001
		lunar_dust_sheet.global_transform = Transform3D(frame.basis.scaled_local(
			Vector3(radius_scale, sag_scale, radius_scale)), contact)
	lunar_dust_sheet.transparency = 1.0 - visual_strength * 0.86


func _upload_dust_sheet_vertices() -> void:
	# The unshaded disk has a position-only vertex stream. Its mesh, indices,
	# UVs and upload storage are allocated once; only 289*12 bytes change.
	for index in range(_dust_sheet_vertices.size()):
		var point := _dust_sheet_vertices[index]
		var offset := index * 12
		_dust_sheet_vertex_bytes.encode_float(offset, point.x)
		_dust_sheet_vertex_bytes.encode_float(offset + 4, point.y)
		_dust_sheet_vertex_bytes.encode_float(offset + 8, point.z)
	(lunar_dust_sheet.mesh as ArrayMesh).surface_update_vertex_region(0, 0,
		_dust_sheet_vertex_bytes)


func lunar_dust_sheet_vertices() -> PackedVector3Array:
	# Physics/debug consumers use the retained upload lattice, never GPU readback.
	return _dust_sheet_vertices


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
	begin_setup()
	while not is_setup_complete() and not is_queued_for_deletion():
		build_setup_step()


func _build_structure() -> void:
	collision_layer = 1
	collision_mask = 1
	var exterior := Node3D.new()
	exterior.name = "VehicleStructure"
	exterior.set_meta(&"cpu_batch_root", true)
	_setup_exterior = exterior
	add_child(exterior)
	# Solid propellant/equipment decks stop below the inhabitable pressure cabin.
	# Its floor, ceiling and ring of wall colliders leave a real empty room.
	_add_cylinder_shape("LowerPressureHull", HULL_RADIUS, 13.10, -2.45)
	_add_cylinder_shape("UpperPressureHull", HULL_RADIUS, 3.20, 9.40)
	var nose_shape := ConvexPolygonShape3D.new()
	var nose_points := PackedVector3Array([Vector3(0.0, HULL_TOP, 0.0)])
	for index in range(24):
		var angle := float(index) * TAU / 24.0
		nose_points.append(Vector3(sin(angle) * HULL_RADIUS, 11.0,
			cos(angle) * HULL_RADIUS))
	nose_shape.points = nose_points
	_add_collision_shape("NoseContactShape", nose_shape, Transform3D.IDENTITY)
	var lower_hull := _add_cylinder_to(exterior, "PressureHull", HULL_RADIUS, HULL_RADIUS,
		13.10, Vector3(0, -2.45, 0), _hull_material)
	var upper_hull := _add_cylinder_to(exterior, "UpperHull", HULL_RADIUS, HULL_RADIUS,
		3.20, Vector3(0, 9.40, 0), _hull_material)
	# The cabin's own floor and ceiling close these openings. A second set of
	# exactly coplanar cylinder caps flickered across the entire interior.
	(lower_hull.get_meta(&"cpu_batch_source") as CylinderMesh).cap_top = false
	(upper_hull.get_meta(&"cpu_batch_source") as CylinderMesh).cap_bottom = false
	_add_cylinder_to(exterior, "NoseCone", 0.06, HULL_RADIUS,
		6.0, Vector3(0, 14.0, 0), _hull_material)
	_add_cylinder_to(exterior, "NoseSeparationBand", 3.53, 3.53,
		0.24, Vector3(0, 10.96, 0), _dark_material)
	_add_cylinder_to(exterior, "CabinMissionBand", 3.53, 3.53,
		0.25, Vector3(0, 3.82, 0), _accent_material)
	_add_cylinder_to(exterior, "AftEquipmentBand", 3.54, 3.62,
		0.42, Vector3(0, -8.72, 0), _dark_material)
	_add_cylinder_to(exterior, "HeatShield", 3.48, 3.60,
		0.36, Vector3(0, -9.12, 0), _heatshield_material)
	for direction in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		var panel_rotation := Vector3(0.0, atan2(direction.x, direction.z), 0.0)
		_add_box_to(exterior, "MissionStripe", Vector3(0.20, 10.4, 0.06),
			direction * 3.505 + Vector3.DOWN * 2.10, _accent_material, panel_rotation)
		_add_box_to(exterior, "ServiceAccess", Vector3(0.90, 1.50, 0.08),
			direction * 3.505 + Vector3.DOWN * 6.85, _dark_material, panel_rotation)
		_add_box_to(exterior, "ServiceLatch", Vector3(0.12, 0.42, 0.12),
			direction * 3.58 + Vector3.DOWN * 6.85, _gold_material, panel_rotation)
	for engine_offset in [Vector3(-1.2, 0.0, -1.2), Vector3(1.2, 0.0, -1.2),
			Vector3(-1.2, 0.0, 1.2), Vector3(1.2, 0.0, 1.2)]:
		_add_cylinder_to(exterior, "EngineBell", 0.44, 0.94,
			1.4, engine_offset + Vector3.DOWN * 9.9, _heatshield_material, 16)
		_add_cylinder_to(exterior, "EngineThroat", 0.54, 0.54,
			0.16, engine_offset + Vector3.DOWN * 9.22, _gold_material, 12)


func _build_flame_meshes() -> void:
	var flame_core_mesh := CylinderMesh.new()
	flame_core_mesh.top_radius = 1.38
	flame_core_mesh.bottom_radius = 0.09
	flame_core_mesh.height = 10.0
	flame_core_mesh.radial_segments = 16
	exhaust_flame_core = _add_mesh("EngineFlameCore", flame_core_mesh,
		Vector3(0.0, ENGINE_EXIT_Y - 5.0, 0.0), _flame_core_material)
	var flame_glow_mesh := CylinderMesh.new()
	flame_glow_mesh.top_radius = 1.92
	flame_glow_mesh.bottom_radius = 0.14
	flame_glow_mesh.height = 12.8
	flame_glow_mesh.radial_segments = 16
	exhaust_flame_glow = _add_mesh("EngineFlameGlow", flame_glow_mesh,
		Vector3(0.0, ENGINE_EXIT_Y - 6.4, 0.0), _flame_glow_material)
	for flame in [exhaust_flame_core, exhaust_flame_glow]:
		flame.visible = false
		flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_dust_effects() -> void:
	lunar_dust = _build_lunar_dust()
	lunar_dust.top_level = true
	add_child(lunar_dust)
	lunar_dust_sheet = MeshInstance3D.new()
	lunar_dust_sheet.name = "LandingRadialDustSheet"
	lunar_dust_sheet.mesh = _dust_sheet_mesh.duplicate()
	_dust_sheet_vertices = _dust_sheet_template_vertices.duplicate()
	_dust_sheet_vertex_bytes.resize(_dust_sheet_vertices.size() * 12)
	# Facet relief can rise above or below the original analytic disk bounds.
	lunar_dust_sheet.custom_aabb = AABB(Vector3(-28, -32, -28), Vector3(56, 64, 56))
	lunar_dust_sheet.top_level = true
	lunar_dust_sheet.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	lunar_dust_sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	lunar_dust_sheet.visible = false
	add_child(lunar_dust_sheet)


func _build_cabin() -> void:
	cabin = Node3D.new()
	cabin.name = "CrewCabin"
	cabin.set_meta(&"cpu_batch_root", true)
	add_child(cabin)
	_add_cylinder_to(cabin, "CabinFloor", 3.47, 3.47, 0.16,
		Vector3(0, CABIN_FLOOR_Y - 0.08, 0), _dark_material)
	_add_cylinder_to(cabin, "CabinCeiling", 3.47, 3.47, 0.14,
		Vector3(0, CABIN_CEILING_Y + 0.07, 0), _cabin_material)
	_add_cylinder_shape("CabinFloorContact", 3.48, 0.16, CABIN_FLOOR_Y - 0.08)
	_add_cylinder_shape("CabinCeilingContact", 3.48, 0.14, CABIN_CEILING_Y + 0.07)
	# Twelve facets form a pressure shell with actual, empty window apertures.
	# No opaque cylinder sits behind the glass: both occupants and observers can
	# see through the room. The front windows start below a seated eye line.
	var panel_radius := HULL_RADIUS * cos(PI / 12.0)
	var panel_width := HULL_RADIUS * 2.0 * sin(PI / 12.0)
	var lower_panel_height := CABIN_WINDOW_SILL_Y - CABIN_FLOOR_Y
	var window_top := CABIN_CEILING_Y - 0.30
	for index in range(12):
		var angle := float(index) * TAU / 12.0
		var outward := Vector3(sin(angle), 0.0, cos(angle))
		var rotation := Vector3(0, angle, 0)
		_add_box_to(cabin, "LowerPressurePanel", Vector3(panel_width, lower_panel_height, 0.17),
			outward * panel_radius + Vector3.UP * (CABIN_FLOOR_Y + lower_panel_height * 0.5),
			_cabin_material, rotation)
		_add_box_to(cabin, "UpperPressurePanel", Vector3(panel_width, 0.30, 0.17),
			outward * panel_radius + Vector3.UP * 7.65, _cabin_material, rotation)
		var pillar_angle := angle + PI / 12.0
		var pillar_position := Vector3(sin(pillar_angle), 0, cos(pillar_angle)) * 3.44
		_add_box_to(cabin, "PressureRib", Vector3(0.14, 3.70, 0.20),
			pillar_position + Vector3.UP * 5.95, _hull_material,
			Vector3(0, pillar_angle, 0))
		var glass := _add_box_to(cabin, "Viewport%02d" % index,
			Vector3(panel_width - 0.09, window_top - CABIN_WINDOW_SILL_Y, 0.022),
			outward * panel_radius + Vector3.UP * (window_top + CABIN_WINDOW_SILL_Y) * 0.5,
			_window_material, rotation)
		glass.set_meta(&"keep_separate", true)
		glass.mesh = glass.get_meta(&"cpu_batch_source")
		glass.remove_meta(&"cpu_batch_source")
		glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		cabin_windows.append(glass)
		var wall_shape := BoxShape3D.new()
		wall_shape.size = Vector3(panel_width, 3.70, 0.17)
		_add_collision_shape("PressureWindowContact%02d" % index, wall_shape,
			Transform3D(Basis(Vector3.UP, angle), outward * panel_radius + Vector3.UP * 5.95))
	# A clear central aisle separates the two rows. Floor tracks and restrained
	# light strips make the room readable without an emissive wall of displays.
	_add_box_to(cabin, "AisleRunner", Vector3(0.74, 0.016, 5.8),
		Vector3(0, CABIN_FLOOR_Y + 0.01, 0), _seat_material)
	for side in [-1.0, 1.0]:
		_add_box_to(cabin, "AisleGuide", Vector3(0.035, 0.018, 5.7),
			Vector3(side * 0.42, CABIN_FLOOR_Y + 0.02, 0), _cabin_light_material)
		_add_box_to(cabin, "CeilingLight", Vector3(0.16, 0.07, 4.7),
			Vector3(side * 1.55, CABIN_CEILING_Y - 0.10, 0), _cabin_light_material)
		_add_box_to(cabin, "CeilingConduit", Vector3(0.09, 0.12, 5.5),
			Vector3(side * 1.94, CABIN_CEILING_Y - 0.09, 0), _dark_material)
		var light := OmniLight3D.new()
		light.name = "CabinLightLeft" if side < 0.0 else "CabinLightRight"
		light.position = Vector3(side * 1.25, 6.72, -0.1)
		light.light_color = Color(0.80, 0.89, 1.0)
		light.light_energy = 0.65
		light.omni_range = 4.6
		light.omni_attenuation = 1.1
		light.shadow_enabled = false
		cabin.add_child(light)
		cabin_lights.append(light)
	# Consoles remain below the viewport sill, so the pilot sees a destination
	# above working controls rather than staring at an opaque dashboard.
	_add_box_to(cabin, "FlightConsole", Vector3(4.55, 0.42, 0.60),
		Vector3(0, 4.40, -2.47), _dark_material)
	for side in [-1.0, 1.0]:
		_add_box_to(cabin, "ConsoleSupport", Vector3(0.12, 0.20, 0.16),
			Vector3(side * 1.85, 4.20, -2.50), _dark_material)
	for index in range(MAX_CREW):
		var seat := Node3D.new()
		seat.name = "CrewSeat%d" % (index + 1)
		seat.position = SEAT_OFFSETS[index]
		cabin.add_child(seat)
		seat_nodes.append(seat)
		_build_cabin_seat(seat, index)
	for side in [-1.0, 1.0]:
		var screen := _add_box_to(cabin, "NavigationDisplay", Vector3(1.10, 0.32, 0.06),
			Vector3(side * 1.12, 4.72, -2.34), _screen_material, Vector3(-0.32, 0, 0))
		for line in range(3):
			_add_box_to(cabin, "DisplayReadout", Vector3(0.72 - line * 0.16, 0.025, 0.012),
				screen.position + Vector3(0, (line - 1) * 0.075, 0.045), _cabin_light_material)
		for switch_index in range(4):
			_add_box_to(cabin, "GuardedSwitch", Vector3(0.09, 0.035, 0.08),
				Vector3(side * 1.12 + (switch_index - 1.5) * 0.18, 4.6275, -2.12),
				_accent_material if switch_index == 0 else _gold_material)
		_add_box_to(cabin, "StorageLocker", Vector3(0.76, 1.22, 0.72),
			Vector3(side * 1.92, 4.73, 2.15), _cabin_material)
		_add_box_to(cabin, "LockerDoor", Vector3(0.68, 1.10, 0.045),
			Vector3(side * 1.92, 4.74, 1.76), _dark_material)
		_add_box_to(cabin, "LockerHandle", Vector3(0.045, 0.28, 0.09),
			Vector3(side * 1.92, 4.73, 1.71), _gold_material)
		_add_box_to(cabin, "OxygenCanister", Vector3(0.30, 0.80, 0.30),
			Vector3(side * 2.87, 4.58, 0.6), _gold_material)
	# The rear pressure hatch lines up with the external ladder platform.
	_add_box_to(cabin, "AccessHatch", Vector3(1.20, 2.18, 0.10),
		Vector3(0, 5.19, 3.29), _dark_material)
	_add_box_to(cabin, "HatchViewport", Vector3(0.62, 0.55, 0.035),
		Vector3(0, 5.62, 3.225), _window_material)
	_add_box_to(cabin, "HatchRelease", Vector3(0.25, 0.045, 0.10),
		Vector3(0.39, 4.99, 3.21), _accent_material)


func _build_cabin_seat(seat: Node3D, index: int) -> void:
	_add_box_to(seat, "SeatPedestal", Vector3(0.46, 0.53, 0.48),
		Vector3(0, 0.115, 0.03), _dark_material)
	_add_box_to(seat, "SeatCushion", Vector3(0.72, 0.12, 0.72),
		Vector3(0, 0.44, -0.04), _seat_material)
	# Support the short monkey's torso/neck without placing a full-sized human
	# headrest directly behind its eyes. Turning around now reveals the other
	# occupants and aft cabin instead of filling the view with one's own chair.
	_add_box_to(seat, "SeatBack", Vector3(0.74, 0.43, 0.16),
		Vector3(0, 0.715, 0.30), _seat_material, Vector3(-0.07, 0, 0))
	_add_box_to(seat, "NeckSupport", Vector3(0.42, 0.12, 0.14),
		Vector3(0, 0.96, 0.34), _seat_material)
	for side in [-1.0, 1.0]:
		_add_box_to(seat, "SeatArmrest", Vector3(0.12, 0.10, 0.57),
			Vector3(side * 0.42, 0.68, -0.06), _dark_material)
		_add_box_to(seat, "HarnessStrap", Vector3(0.055, 0.36, 0.025),
			Vector3(side * 0.16, 0.74, 0.198), _accent_material,
			Vector3(0, 0, side * 0.14))
		_add_box_to(seat, "FootRest", Vector3(0.26, 0.065, 0.30),
			Vector3(side * 0.16, 0.12, -0.48), _dark_material)
	_add_box_to(seat, "HarnessBuckle", Vector3(0.13, 0.12, 0.05),
		Vector3(0, 0.65, 0.19), _gold_material)
	_add_box_to(seat, "ArmrestControl", Vector3(0.08, 0.15, 0.08),
		Vector3(0.42, 0.80, -0.21), _accent_material)
	# Rear occupants have their own compact seatback terminal.
	if index >= 2:
		_add_box_to(seat, "TerminalArm", Vector3(0.065, 0.065, 0.74),
			Vector3(0.38, 0.74, -0.40), _dark_material)
		_add_box_to(seat, "TerminalMount", Vector3(0.44, 0.065, 0.065),
			Vector3(0.19, 0.76, -0.74), _dark_material)
		_add_box_to(seat, "CrewTerminal", Vector3(0.60, 0.30, 0.05),
			Vector3(0, 0.90, -0.74), _screen_material)


func _build_access_ladder(exterior: Node3D) -> void:
	_add_box_to(exterior, "BoardingPlatform", Vector3(1.48, 0.16, 1.40),
		Vector3(0, CABIN_FLOOR_Y - 0.08, 4.00), _dark_material)
	for side in [-1.0, 1.0]:
		_add_box_to(exterior, "AccessLadderRail", Vector3(0.10, 17.90, 0.10),
			Vector3(side * 0.56, -4.25, 3.94), _gold_material)
		_add_box_to(exterior, "PlatformHandrail", Vector3(0.065, 0.9, 0.065),
			Vector3(side * 0.67, CABIN_FLOOR_Y + 0.44, 4.47), _gold_material)
	for rung in range(44):
		_add_box_to(exterior, "LadderRung", Vector3(1.12, 0.045, 0.14),
			Vector3(0, -12.65 + float(rung) * 0.39, 3.94), _dark_material)
	_add_box_to(exterior, "ExteriorPressureHatch", Vector3(1.20, 2.20, 0.10),
		Vector3(0, 5.20, 3.46), _dark_material)
	_add_box_to(exterior, "HatchStatusLight", Vector3(0.40, 0.07, 0.065),
		Vector3(0, 6.42, 3.52), _cabin_light_material)


func _build_landing_mechanisms() -> void:
	for direction in _landing_directions():
		var index := landing_gear.size() + 1
		var arm := _add_mesh("LandingStrut%d" % index, _landing_strut_mesh,
			Vector3.ZERO, _dark_material)
		var piston := _add_mesh("LandingPiston%d" % index, _landing_piston_mesh,
			Vector3.ZERO, _gold_material)
		var brace := _add_mesh("LandingBrace%d" % index, _landing_piston_mesh,
			Vector3.ZERO, _dark_material)
		var foot_size := LANDING_FOOT_SIZE
		var foot := _add_box("LandingFoot%d" % index, foot_size,
			Vector3.ZERO, _dark_material)
		var shape := BoxShape3D.new()
		shape.size = foot_size
		var collision := _add_collision_shape("LandingFootContact%d" % index,
			shape, Transform3D.IDENTITY)
		landing_gear.append({"direction": direction, "arm": arm,
			"piston": piston, "brace": brace, "foot": foot, "collision": collision})


func _add_collision_shape(part_name: String, shape: Shape3D,
		local_transform: Transform3D) -> CollisionShape3D:
	var collision := CollisionShape3D.new()
	collision.name = part_name
	collision.shape = shape
	collision.transform = local_transform
	add_child(collision)
	return collision


func _add_cylinder_shape(part_name: String, radius: float, height: float, y: float) -> void:
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	_add_collision_shape(part_name, shape, Transform3D(Basis.IDENTITY, Vector3(0, y, 0)))


static func _add_cylinder_to(parent: Node3D, part_name: String, top_radius: float,
		bottom_radius: float, height: float, local_position: Vector3,
		material: Material, segments: int = 24) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = segments
	return _add_mesh_to(parent, part_name, mesh, local_position, material)


func _build_static_batch_step(model_root: Node3D, interior: bool,
		budget_usec: int) -> bool:
	if not _setup_batch_started:
		_gather_static_parts(model_root, _setup_batch_parts)
		_setup_batch_started = true
	var started := Time.get_ticks_usec()
	while _setup_batch_cursor < _setup_batch_parts.size():
		var part := _setup_batch_parts[_setup_batch_cursor]
		var material: Material = part.material_override
		if interior and material is StandardMaterial3D:
			# The pressure cabin has its own two local lights. Low-bias planetary
			# contact shadows, tuned for boots/regolith 48 km above Earth, produced
			# broad self-shadow bands across its small controls. Use cached interior
			# copies so exterior hull/legs keep their real surface contact shadows.
			var source_key := material.get_instance_id()
			if not _interior_materials.has(source_key):
				var cabin_material := material.duplicate() as StandardMaterial3D
				cabin_material.disable_receive_shadows = true
				_interior_materials[source_key] = cabin_material
			material = _interior_materials[source_key]
		var key := material.get_instance_id()
		if not _setup_batch_surfaces.has(key):
			var surface := SurfaceTool.new()
			surface.begin(Mesh.PRIMITIVE_TRIANGLES)
			surface.set_material(material)
			_setup_batch_surfaces[key] = surface
		var relative := part.transform
		var ancestor := part.get_parent()
		while ancestor != model_root:
			relative = (ancestor as Node3D).transform * relative
			ancestor = ancestor.get_parent()
		var surface: SurfaceTool = _setup_batch_surfaces[key]
		var source: PrimitiveMesh = part.get_meta(&"cpu_batch_source", part.mesh)
		surface.append_from(_cpu_batch_mesh(source), 0, relative)
		_setup_batch_cursor += 1
		if Time.get_ticks_usec() - started >= maxi(budget_usec, 1):
			return false
	# The uploads are intentionally separate from CPU gathering, and only one
	# material is published per call. No frame uploads the whole craft at once.
	if _setup_batch_commit_cursor < _setup_batch_surfaces.size():
		var key: int = _setup_batch_surfaces.keys()[_setup_batch_commit_cursor]
		var surface: SurfaceTool = _setup_batch_surfaces[key]
		var batch := MeshInstance3D.new()
		batch.name = "StaticMaterial%d" % model_root.get_child_count()
		batch.mesh = surface.commit()
		model_root.add_child(batch)
		_setup_batch_commit_cursor += 1
		return false
	for part in _setup_batch_parts:
		part.free()
	_setup_batch_parts.clear()
	_setup_batch_surfaces.clear()
	_setup_batch_cursor = 0
	_setup_batch_commit_cursor = 0
	_setup_batch_started = false
	return true


static func _cpu_batch_mesh(source: PrimitiveMesh) -> CpuBatchMesh:
	var description: Array
	if source is BoxMesh:
		description = ["box", source.size, source.subdivide_width,
			source.subdivide_height, source.subdivide_depth,
			source.flip_faces, source.add_uv2, source.uv2_padding]
	elif source is CylinderMesh:
		description = ["cylinder", source.top_radius, source.bottom_radius,
			source.height, source.radial_segments, source.rings, source.cap_top,
			source.cap_bottom, source.flip_faces, source.add_uv2, source.uv2_padding]
	else:
		description = [source.get_instance_id()]
	# Binary keys preserve full float precision (Vector3 string formatting does
	# not), and include every geometry-affecting property of the authored types.
	var key := var_to_bytes(description)
	if _batch_cpu_meshes.has(key):
		return _batch_cpu_meshes[key]
	var cached := CpuBatchMesh.new()
	if source is BoxMesh and source.subdivide_width == 0 \
			and source.subdivide_height == 0 and source.subdivide_depth == 0 \
			and not source.flip_faces and not source.add_uv2:
		if _unit_box_arrays.is_empty():
			var unit := BoxMesh.new()
			unit.size = Vector3.ONE
			_unit_box_arrays = unit.get_mesh_arrays()
		cached.arrays = _unit_box_arrays.duplicate()
		var vertices: PackedVector3Array = _unit_box_arrays[Mesh.ARRAY_VERTEX].duplicate()
		for index in range(vertices.size()):
			vertices[index] *= source.size
		cached.arrays[Mesh.ARRAY_VERTEX] = vertices
	else:
		# A cylinder's taper changes normals; cache the exact engine-generated
		# arrays once per full recipe instead of approximating them by scaling.
		cached.arrays = source.get_mesh_arrays()
	_batch_cpu_meshes[key] = cached
	return cached


static func _gather_static_parts(node: Node, parts: Array[MeshInstance3D]) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and not child.get_meta(&"keep_separate", false):
			parts.append(child)
		_gather_static_parts(child, parts)


func _build_launch_plume() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "EngineFireAndExhaust"
	particles.position = Vector3(0.0, ENGINE_EXIT_Y + 0.3, 0.0)
	particles.amount = 88
	particles.lifetime = 1.15
	particles.randomness = 0.22
	particles.local_coords = true
	particles.fixed_fps = 60
	particles.draw_pass_1 = _flame_mesh
	particles.visibility_aabb = AABB(Vector3(-7.0, -58.0, -7.0),
		Vector3(14.0, 60.0, 14.0))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 1.45
	process.direction = Vector3.DOWN
	process.spread = 7.0
	process.initial_velocity_min = 30.0
	process.initial_velocity_max = 48.0
	process.gravity = Vector3(0.0, -5.0, 0.0)
	process.scale_min = 1.0
	process.scale_max = 2.6
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
	particles.fixed_fps = 60
	particles.draw_pass_1 = _flame_mesh
	particles.visibility_aabb = AABB(Vector3(-8.0, -12.0, -8.0),
		Vector3(16.0, 32.0, 16.0))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 3.6
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


func _build_lunar_dust() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "SharedLandingDust"
	particles.amount = 56
	particles.lifetime = 3.0
	particles.randomness = 0.55
	particles.local_coords = false
	particles.fixed_fps = 60
	particles.draw_pass_1 = _dust_mesh
	particles.visibility_aabb = AABB(Vector3(-42.0, -3.0, -42.0),
		Vector3(84.0, 18.0, 84.0))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(6.5, 0.10, 6.5)
	process.direction = Vector3.UP
	process.spread = 88.0
	process.initial_velocity_min = 7.0
	process.initial_velocity_max = 17.0
	process.gravity = Vector3(0.0, -0.32, 0.0)
	process.damping_min = 3.5
	process.damping_max = 5.5
	process.scale_min = 1.15
	process.scale_max = 3.6
	process.color = Color(0.52, 0.48, 0.41, 0.90)
	var dust_gradient := Gradient.new()
	dust_gradient.set_color(0, Color(0.58, 0.54, 0.47, 0.0))
	dust_gradient.add_point(0.08, Color(0.55, 0.51, 0.44, 0.90))
	dust_gradient.add_point(0.62, Color(0.44, 0.41, 0.36, 0.58))
	dust_gradient.set_color(dust_gradient.get_point_count() - 1,
		Color(0.38, 0.36, 0.33, 0.0))
	var dust_ramp := GradientTexture1D.new()
	dust_ramp.gradient = dust_gradient
	process.color_ramp = dust_ramp
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
	var ancestor: Node = parent
	var deferred_mesh := false
	while ancestor:
		if ancestor.get_meta(&"cpu_batch_root", false):
			deferred_mesh = true
			break
		ancestor = ancestor.get_parent()
	if deferred_mesh:
		# These temporary nodes supply only transforms/materials to the batcher.
		# Assigning their mesh would upload hundreds of soon-discarded primitives.
		instance.set_meta(&"cpu_batch_source", mesh)
	else:
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
	_window_material.albedo_color = Color(0.60, 0.82, 0.95, 0.10)
	_window_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_window_material.metallic = 0.0
	_window_material.roughness = 0.10
	_window_material.emission_enabled = false
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
	_landing_strut_mesh = CylinderMesh.new()
	_landing_strut_mesh.top_radius = 0.23
	_landing_strut_mesh.bottom_radius = 0.23
	_landing_strut_mesh.height = 1.0
	_landing_strut_mesh.radial_segments = 8
	_landing_piston_mesh = CylinderMesh.new()
	_landing_piston_mesh.top_radius = 0.13
	_landing_piston_mesh.bottom_radius = 0.13
	_landing_piston_mesh.height = 1.0
	_landing_piston_mesh.radial_segments = 8
	_cabin_material = StandardMaterial3D.new()
	_cabin_material.albedo_color = Color(0.62, 0.66, 0.68)
	_cabin_material.roughness = 0.76
	_cabin_material.emission_enabled = true
	_cabin_material.emission = Color(0.055, 0.064, 0.075)
	_cabin_material.emission_energy_multiplier = 0.6
	_cabin_material.disable_fog = true
	_seat_material = StandardMaterial3D.new()
	_seat_material.albedo_color = Color(0.10, 0.15, 0.21)
	_seat_material.roughness = 0.88
	_seat_material.disable_fog = true
	_screen_material = StandardMaterial3D.new()
	_screen_material.albedo_color = Color(0.035, 0.18, 0.23)
	_screen_material.roughness = 0.32
	_screen_material.emission_enabled = true
	_screen_material.emission = Color(0.025, 0.37, 0.46)
	_screen_material.emission_energy_multiplier = 0.9
	_screen_material.disable_fog = true
	_cabin_light_material = StandardMaterial3D.new()
	_cabin_light_material.albedo_color = Color(0.70, 0.88, 1.0)
	_cabin_light_material.emission_enabled = true
	_cabin_light_material.emission = Color(0.60, 0.80, 1.0)
	_cabin_light_material.emission_energy_multiplier = 1.4
	_cabin_light_material.disable_fog = true
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
	_dust_mesh = QuadMesh.new()
	_dust_mesh.size = Vector2(2.8, 1.15)
	var dust_material := StandardMaterial3D.new()
	dust_material.albedo_color = Color(0.54, 0.50, 0.43, 0.90)
	dust_material.albedo_texture = _soft_dust_texture()
	dust_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dust_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dust_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dust_material.vertex_color_use_as_albedo = true
	dust_material.emission_enabled = true
	dust_material.emission = Color(0.16, 0.145, 0.12)
	dust_material.emission_energy_multiplier = 0.28
	dust_material.disable_fog = true
	_dust_mesh.material = dust_material
	_dust_sheet_mesh = _build_curved_dust_sheet_mesh()
	var dust_sheet_material := StandardMaterial3D.new()
	dust_sheet_material.albedo_color = Color(0.40, 0.375, 0.34, 0.92)
	dust_sheet_material.albedo_texture = _radial_dust_sheet_texture()
	dust_sheet_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dust_sheet_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dust_sheet_material.emission_enabled = true
	dust_sheet_material.emission = Color(0.075, 0.068, 0.058)
	dust_sheet_material.emission_energy_multiplier = 0.16
	dust_sheet_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	dust_sheet_material.disable_receive_shadows = true
	dust_sheet_material.disable_fog = true
	_dust_sheet_mesh.surface_set_material(0, dust_sheet_material)


static func _build_curved_dust_sheet_mesh() -> ArrayMesh:
	# One cached 289-vertex disk follows the spherical landing pad. The old quad
	# hovered almost a metre above the 450 m Moon at its fully expanded rim.
	var vertices := PackedVector3Array([Vector3.ZERO])
	var uvs := PackedVector2Array([Vector2(0.5, 0.5)])
	var indices := PackedInt32Array()
	var moon_radius := MoonWorld.PLAYABLE_RADIUS_METERS
	for ring in range(1, DUST_SHEET_RINGS + 1):
		var radius := DUST_SHEET_MAX_RADIUS * float(ring) / DUST_SHEET_RINGS
		var sag := sqrt(moon_radius * moon_radius - radius * radius) - moon_radius
		for segment in range(DUST_SHEET_SEGMENTS):
			var angle := TAU * float(segment) / DUST_SHEET_SEGMENTS
			var point := Vector3(cos(angle) * radius, sag, sin(angle) * radius)
			vertices.append(point)
			uvs.append(Vector2(point.x, point.z) / (DUST_SHEET_MAX_RADIUS * 2.0)
				+ Vector2(0.5, 0.5))
	for segment in range(DUST_SHEET_SEGMENTS):
		var next := (segment + 1) % DUST_SHEET_SEGMENTS
		indices.append_array(PackedInt32Array([0, 1 + segment, 1 + next]))
		for ring in range(1, DUST_SHEET_RINGS):
			var inner := 1 + (ring - 1) * DUST_SHEET_SEGMENTS
			var outer := inner + DUST_SHEET_SEGMENTS
			indices.append_array(PackedInt32Array([
				inner + segment, outer + segment, inner + next,
				inner + next, outer + segment, outer + next]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
	_dust_sheet_template_vertices = vertices
	return mesh


static func _soft_dust_texture() -> ImageTexture:
	const SIZE := 64
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in range(SIZE):
		for x in range(SIZE):
			var uv := Vector2((float(x) + 0.5) / float(SIZE),
				(float(y) + 0.5) / float(SIZE)) * 2.0 - Vector2.ONE
			uv.y *= 1.8
			var alpha := pow(maxf(1.0 - uv.length(), 0.0), 1.7)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


static func _radial_dust_sheet_texture() -> ImageTexture:
	const SIZE := 128
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in range(SIZE):
		for x in range(SIZE):
			var uv := Vector2((float(x) + 0.5) / float(SIZE),
				(float(y) + 0.5) / float(SIZE)) * 2.0 - Vector2.ONE
			var radius := uv.length()
			var ring := exp(-pow((radius - 0.58) / 0.24, 2.0))
			var edge := smoothstep(1.0, 0.72, radius)
			var angle := atan2(uv.y, uv.x)
			var breakup := 0.54 + 0.28 * sin(angle * 7.0 + radius * 19.0) \
				+ 0.18 * sin(angle * 13.0 - radius * 31.0)
			var alpha := clampf(ring * edge * maxf(breakup, 0.08) * 0.72,
				0.0, 0.72)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)
