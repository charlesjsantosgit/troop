extends SceneTree
## Authority-to-gameplay lunar integration gate. This intentionally runs as a
## standalone process so net's real singleton, mission clock, score authority,
## ExpeditionManager, physical rocket, player gravity, suits and inventory all
## meet in one deterministic fixture.
##
## Run with:
##   godot --headless --path . -s tests/expeditionintegrationtest.gd

var passed := 0
var total := 0

const ROCKET_HULL_ANCHORS := [
	Vector3(0.0, 17.0, 0.0),
	Vector3(0.0, -13.0, 0.0),
	Vector3(6.5, -12.5, 0.0),
	Vector3(-6.5, -12.5, 0.0),
	Vector3(0.0, -12.5, 6.5),
	Vector3(0.0, -12.5, -6.5),
]
const ROCKET_HULL_ANCHOR_NAMES := [
	"nose", "feet", "+X", "-X", "+Z", "-Z",
]


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String, detail := "") -> void:
	total += 1
	if ok:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label + ((" :: " + detail)
			if not detail.is_empty() else ""))


func _rocket_hull_anchors_outside_frustum(rocket: Node3D,
		camera: Camera3D) -> Array[String]:
	var outside: Array[String] = []
	var viewport_size := camera.get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var half_fov_tangent := tan(deg_to_rad(camera.fov) * 0.5)
	for index in range(ROCKET_HULL_ANCHORS.size()):
		var world_anchor: Vector3 = rocket.to_global(ROCKET_HULL_ANCHORS[index])
		var camera_anchor := camera.global_transform.affine_inverse() * world_anchor
		var depth := -camera_anchor.z
		var half_width := depth * half_fov_tangent
		var half_height := half_width / aspect
		if camera.keep_aspect == Camera3D.KEEP_HEIGHT:
			half_height = depth * half_fov_tangent
			half_width = half_height * aspect
		if depth < camera.near or depth > camera.far \
				or absf(camera_anchor.x) > half_width \
				or absf(camera_anchor.y) > half_height:
			outside.append(ROCKET_HULL_ANCHOR_NAMES[index])
	return outside


func _sphere_vertical_view_fraction(camera: Camera3D,
		globe: MeshInstance3D) -> float:
	var sphere := globe.mesh as SphereMesh
	if not sphere:
		return 0.0
	var camera_center := camera.global_transform.affine_inverse() \
		* globe.global_position
	var depth := -camera_center.z
	if depth <= camera.near:
		return 0.0
	var viewport_size := camera.get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var half_fov_tangent := tan(deg_to_rad(camera.fov) * 0.5)
	var half_height := depth * half_fov_tangent
	if camera.keep_aspect == Camera3D.KEEP_WIDTH:
		half_height /= aspect
	var globe_scale := globe.global_basis.get_scale()
	var world_radius := sphere.radius * maxf(absf(globe_scale.x),
		maxf(absf(globe_scale.y), absf(globe_scale.z)))
	return world_radius / maxf(half_height, 0.001)


func _sphere_angular_radius(camera: Camera3D,
		globe: MeshInstance3D) -> float:
	var sphere := globe.mesh as SphereMesh
	if not sphere:
		return 0.0
	var globe_scale := globe.global_basis.get_scale()
	var world_radius := sphere.radius * maxf(absf(globe_scale.x),
		maxf(absf(globe_scale.y), absf(globe_scale.z)))
	var distance := camera.global_position.distance_to(globe.global_position)
	if distance <= world_radius:
		return PI * 0.5
	return asin(clampf(world_radius / distance, 0.0, 1.0))


func _globe_intersects_camera_frustum(camera: Camera3D, globe: MeshInstance3D) -> bool:
	var sphere := globe.mesh as SphereMesh
	if not sphere or not globe.is_visible_in_tree():
		return false
	var scale := globe.global_basis.get_scale().abs()
	var radius := sphere.radius * maxf(scale.x, maxf(scale.y, scale.z))
	var inside := camera.global_position - camera.global_basis.z * (camera.near + 1.0)
	for plane in camera.get_frustum():
		var distance := plane.distance_to(globe.global_position)
		if (plane.distance_to(inside) <= 0.0 and distance > radius) \
				or (plane.distance_to(inside) > 0.0 and distance < -radius):
			return false
	return true


func _viewport_ray_hits_sphere(camera: Camera3D,
		globe: MeshInstance3D) -> bool:
	var sphere := globe.mesh as SphereMesh
	if not sphere:
		return false
	var globe_scale := globe.global_basis.get_scale()
	var radius := sphere.radius * maxf(absf(globe_scale.x),
		maxf(absf(globe_scale.y), absf(globe_scale.z)))
	var viewport_size := camera.get_viewport().get_visible_rect().size
	# During atmospheric flight the life-size centre is correctly below/behind
	# the lens; what the player sees is its tangent horizon. Sample a few vertical
	# screen rays and solve their analytic sphere intersections instead of
	# declaring the planet absent merely because its centre is off-screen.
	for y_fraction in [0.58, 0.70, 0.82, 0.94]:
		var screen_point := Vector2(viewport_size.x * 0.5,
			viewport_size.y * float(y_fraction))
		var origin := camera.project_ray_origin(screen_point)
		var direction := camera.project_ray_normal(screen_point).normalized()
		var offset := origin - globe.global_position
		var b := offset.dot(direction)
		var c := offset.length_squared() - radius * radius
		var discriminant := b * b - c
		if discriminant >= 0.0 and -b + sqrt(discriminant) >= camera.near:
			return true
	return false


func _run() -> void:
	print("EXPEDITION INTEGRATION TEST")
	# A standalone SceneTree under the dummy display server otherwise reports a
	# square 1600x1600 viewport. Exercise the shipped camera composition at the
	# project's actual aspect, including Camera3D's real frustum-plane queries.
	var game_viewport := Vector2i(
		int(ProjectSettings.get_setting("display/window/size/viewport_width", 1600)),
		int(ProjectSettings.get_setting("display/window/size/viewport_height", 900)))
	root.size = game_viewport
	root.content_scale_size = game_viewport
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	const TEST_SEED := 904_1969
	var net: Variant = root.get_node_or_null("Net")
	if not net:
		_check(false, "project Net autoload is available to standalone integration")
		print("EXPEDITIONINTEGRATIONTEST %d/%d FAIL" % [passed, total])
		quit(1)
		return
	net.solo("LunarTester", TEST_SEED)
	var gen: Variant = root.get_node_or_null("Gen")
	if not gen:
		_check(false, "project Gen autoload is available to standalone integration")
		print("EXPEDITIONINTEGRATIONTEST %d/%d FAIL" % [passed, total])
		quit(1)
		return
	gen.setup(TEST_SEED)
	# Project autoload identifiers are registered after a custom MainLoop script
	# is compiled. Load gameplay classes now, at runtime, so this standalone gate
	# still exercises the real scripts rather than test doubles.
	var world_script: Variant = load("res://scripts/world.gd")
	var manager_script: Variant = load("res://scripts/expedition_manager.gd")
	var rocket_script: Variant = load("res://scripts/lunar_rocket.gd")
	var inventory_script: Variant = load("res://scripts/lunar_inventory.gd")
	var moon_script: Variant = load("res://scripts/moon_world.gd")
	var suit_script: Variant = load("res://scripts/space_suit_system.gd")
	var player_script: Variant = load("res://scripts/player.gd")
	var visuals_script: Variant = load("res://scripts/visuals.gd")
	# The fixture does not test ambience. Prevent Player._ready from starting the
	# synthesized looping wind stream, which otherwise leaves an AudioServer
	# playback object alive until after this standalone SceneTree reports leaks.
	var sfx: Variant = root.get_node_or_null("Sfx")
	if sfx:
		sfx.streams["wind"] = null
	# Five authority-visible peers let the real boarding code prove its cap. The
	# first four have presentation actors; the fifth exists only to overbook.
	net.names = {1: "Alpha", 2: "Bravo", 3: "Charlie", 4: "Delta", 5: "Echo"}
	net.scores = {1: 10, 2: 10, 3: 10, 4: 10, 5: 10}
	net.player_realms = {1: net.PlayerRealm.EARTH,
		2: net.PlayerRealm.EARTH, 3: net.PlayerRealm.EARTH,
		4: net.PlayerRealm.EARTH, 5: net.PlayerRealm.EARTH}

	var stage := Node3D.new()
	stage.name = "ExpeditionIntegrationStage"
	root.add_child(stage)
	var world: Variant = world_script.new()
	world.name = "IntegrationWorld"
	world.process_mode = Node.PROCESS_MODE_DISABLED
	stage.add_child(world)
	var player: Variant = world.spawn_local(1, "Alpha")
	player.test_mode = true
	player.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	var original_player_interpolation: int = player.physics_interpolation_mode
	for peer_id in range(2, 5):
		if peer_id == 2:
			world.spawn_puppet(peer_id, net.names[peer_id])
		else:
			var puppet := Node3D.new()
			puppet.name = "IntegrationPuppet%d" % peer_id
			world.add_child(puppet)
			world.puppets[peer_id] = puppet
	var original_puppet_interpolation: int = world.puppets[2].physics_interpolation_mode

	var owner_main := Node.new()
	owner_main.name = "IntegrationMain"
	stage.add_child(owner_main)
	var manager: Variant = manager_script.new()
	stage.add_child(manager)
	manager.configure(owner_main, world)
	manager.process_mode = Node.PROCESS_MODE_DISABLED
	world.expedition_manager = manager
	await process_frame

	_check(manager.moon_world.moon_seed == (TEST_SEED ^ 0x4d4f4f4e),
		"ExpeditionManager builds the Moon from the shared session seed",
		"seed=%d" % manager.moon_world.moon_seed)
	_check(manager.rocket != null and manager.rocket.seat_nodes.size() == 4 \
			and manager.moon_world.cheese_shop != null,
		"integrated world owns one four-seat rocket and one lunar cheese shop")
	var hatch_authority_matches := true
	for realm in [net.PlayerRealm.EARTH, net.PlayerRealm.MOON]:
		var expected_hatch: Vector3 = (manager.rocket.earth_launch_transform \
			if realm == net.PlayerRealm.EARTH else manager.rocket.moon_landing_transform) \
			* rocket_script.BOARDING_LOCAL_POSITION
		var authority_hatch: Vector3 = net._rocket_boarding_position(realm)
		net.player_realms[5] = realm
		net._peer_on_foot_positions[5] = expected_hatch + Vector3.RIGHT * 9.0
		hatch_authority_matches = hatch_authority_matches \
			and authority_hatch.distance_to(expected_hatch) < 0.01 \
			and net._rocket_boarding_in_range(5, realm)
		net._peer_on_foot_positions[5] = expected_hatch + Vector3.RIGHT * 11.0
		hatch_authority_matches = hatch_authority_matches \
			and not net._rocket_boarding_in_range(5, realm)
	net.player_realms[5] = net.PlayerRealm.EARTH
	net._peer_on_foot_positions.erase(5)
	_check(hatch_authority_matches,
		"Earth and Moon authority accept every hatch prompt and reject out-of-range boarding")
	_check(manager.local_inventory.has_backpack() \
			and manager.inventory_ui.open_inventory(),
		"every game starts with an equipped backpack and accessible inventory")
	manager.inventory_ui.close_inventory()
	_check(not manager.grant_normal_backpack() \
			and manager.local_inventory.backpack_kind \
				== inventory_script.Backpack.NORMAL \
			and manager.local_inventory.slot_count() == inventory_script.NORMAL_SLOTS \
			and manager._normal_backpack_visual != null,
		"initial Earth backpack has twelve pockets and a visible worn pack; repeated grants do not reset storage")

	# --- authority validation envelope ------------------------------------
	var valid_outbound := {"phase": net.RocketMissionPhase.OUTBOUND,
		"crew": [1, 2, 3, 4], "elapsed": 59.999,
		"duration": net.ROCKET_OUTBOUND_SECONDS, "serial": 1}
	var bad_outbound_duration := valid_outbound.duplicate(true)
	bad_outbound_duration.duration = net.ROCKET_RETURN_SECONDS
	var bad_return_elapsed := {"phase": net.RocketMissionPhase.RETURN,
		"crew": [1], "elapsed": net.ROCKET_RETURN_SECONDS + 0.001,
		"duration": net.ROCKET_RETURN_SECONDS, "serial": 2}
	var valid_recovery := {"phase": net.RocketMissionPhase.SPLASHDOWN_RECOVERY,
		"crew": [], "elapsed": 2.999, "duration": 3.0, "serial": 2}
	var valid_recovery_manifest := valid_recovery.duplicate(true)
	valid_recovery_manifest.crew = [1, 2, 3, 4]
	var bad_recovery_duration := valid_recovery.duplicate(true)
	bad_recovery_duration.duration = 18.0
	var bad_ready_clock := {"phase": net.RocketMissionPhase.EARTH_READY,
		"crew": [], "elapsed": 1.0, "duration": 0.0, "serial": 2}
	_check(net._valid_expedition_state(valid_outbound) \
			and net._valid_expedition_state(valid_recovery) \
			and net._valid_expedition_state(valid_recovery_manifest) \
			and not net._valid_expedition_state(bad_outbound_duration) \
			and not net._valid_expedition_state(bad_return_elapsed) \
			and not net._valid_expedition_state(bad_recovery_duration) \
			and not net._valid_expedition_state(bad_ready_clock),
		"network snapshots enforce exact phase-specific 60/45/3-second clocks")
	_check(not net._valid_expedition_state({"phase": 1, "crew": [1, 1],
			"elapsed": 0.0, "duration": net.ROCKET_OUTBOUND_SECONDS,
			"serial": 1}) \
			and not net._valid_expedition_state({"phase": 1,
				"crew": [1, 2, 3, 4, 5], "elapsed": 0.0,
				"duration": net.ROCKET_OUTBOUND_SECONDS, "serial": 1}),
		"network snapshots reject duplicate and over-capacity manifests")
	var outbound_ascent_end: float = float(rocket_script.OUTBOUND_PHASE_TIMES[0])
	var outbound_cruise_start: float = float(rocket_script.OUTBOUND_PHASE_TIMES[1])
	var outbound_descent_start: float = float(rocket_script.OUTBOUND_PHASE_TIMES[2])
	_check(rocket_script.state_for_elapsed(true, outbound_ascent_end - 0.001) \
			== rocket_script.State.LAUNCH_ASCENT \
			and rocket_script.state_for_elapsed(true, outbound_ascent_end) \
				== rocket_script.State.ATMOSPHERE_EXIT \
			and rocket_script.state_for_elapsed(true, 59.999) \
				== rocket_script.State.LUNAR_APPROACH \
			and rocket_script.state_for_elapsed(true, 60.0) \
				== rocket_script.State.LANDED_MOON \
			and rocket_script.state_for_elapsed(false, 44.999) \
				== rocket_script.State.OCEAN_APPROACH \
			and rocket_script.state_for_elapsed(false, 45.0) \
				== rocket_script.State.SPLASHDOWN,
		"presentation states share exact authority clock boundaries")

	# A global expedition is visible to everyone, but its cinematic must never
	# take control from an Earth spectator who is not on the manifest.
	var spectator_state := {"phase": net.RocketMissionPhase.OUTBOUND,
		"crew": [2], "elapsed": 8.0,
		"duration": net.ROCKET_OUTBOUND_SECONDS, "serial": 1}
	net.rocket_state = spectator_state.duplicate(true)
	net.player_realms[1] = net.PlayerRealm.EARTH
	manager.voyage_camera.current = false
	manager._update_voyage_camera(0.0, 0.1, spectator_state)
	_check(not manager.voyage_camera.current \
			and not manager._local_player_is_voyaging(spectator_state),
		"another crew's launch never hijacks a non-passenger camera")
	manager.rocket.voyage_visuals.set_local_viewer_enabled(true)
	manager._apply_authoritative_state(spectator_state)
	_check(not manager.rocket.voyage_visuals.is_visible_in_tree() \
			and not manager.rocket.voyage_visuals.local_viewer_enabled,
		"incoming spectator snapshot hides private scenery before the next process frame")
	manager.rocket.apply_authoritative_clock(rocket_script.State.LAUNCH_ASCENT, true, 8.0)
	var spectator_hull_before: Vector3 = manager.rocket.global_position
	manager._manifest_sync_remaining = 0.0
	manager._process(1.0 / 60.0)
	var spectator_slot: int = manager.rocket.seat_for_peer(2)
	var spectator_crew_visible: bool = spectator_slot >= 0 \
		and world.puppets[2].is_visible_in_tree()
	if spectator_slot >= 0:
		var expected_spectator_seat: Transform3D = manager.rocket.seat_global_transform(spectator_slot)
		spectator_crew_visible = spectator_crew_visible \
			and world.puppets[2].global_position.distance_to(expected_spectator_seat.origin) < 0.05
	# A subsequent authoritative seek/presentation must not undo viewer gating.
	manager.rocket.apply_authoritative_clock(rocket_script.State.LAUNCH_ASCENT, true, 8.25)
	manager.rocket.present_render_sample(manager.rocket.render_sample())
	_check(manager.rocket.global_position.distance_to(spectator_hull_before) > 0.1 \
			and manager.rocket.get_node("VehicleStructure").is_visible_in_tree() \
			and spectator_crew_visible \
			and not manager.rocket.voyage_visuals.is_visible_in_tree() \
			and not manager.rocket.voyage_visuals.celestial_fill_light.is_visible_in_tree() \
			and not manager.rocket.voyage_visuals.cinematic_terrain_enabled \
			and is_zero_approx(float(visuals_script._cinematic_curve_strength)),
		"spectators see the moving rocket and crew without receiving its planets, global fill or terrain projection")
	# Remaining deterministic camera seeks explicitly act as the local passenger;
	# the fixture disables the manager loop and therefore owns this preview flag.
	manager.rocket.voyage_visuals.set_local_viewer_enabled(true)
	manager.rocket._set_scripted_flight(true)
	manager.rocket.apply_authoritative_clock(rocket_script.State.LUNAR_APPROACH, true, 59.0)
	manager._reset_rocket_to_launchpad()
	_check(not manager.rocket._scripted_flight and manager.rocket.freeze \
			and manager.rocket.collision_layer == 1 \
			and manager.rocket.collision_mask == 1,
		"cancelled outbound voyage restores the launchpad rocket's physical hull")
	_check(not manager.rocket.launch_plume.emitting \
			and not manager.rocket.lunar_dust.emitting \
			and not manager.rocket.lunar_dust_sheet.visible \
			and is_equal_approx(manager.rocket.landing_gear_deployment, 1.0),
		"canonical cancellation clears landing effects and restores the parked mechanisms")
	var old_mission: Dictionary = spectator_state.duplicate(true)
	old_mission.serial = 100
	old_mission.elapsed = 55.0
	manager._apply_authoritative_state(old_mission)
	var new_mission: Dictionary = old_mission.duplicate(true)
	new_mission.serial = 101
	new_mission.elapsed = 2.0
	manager._apply_authoritative_state(new_mission)
	_check(is_equal_approx(manager.rocket.voyage_elapsed, 2.0) \
			and manager.rocket.state == rocket_script.State.LAUNCH_ASCENT,
		"a new mission serial resets an old same-phase landing clock instead of slowly correcting backward")
	net._reset_expedition_state(true)
	for peer_id in range(2, 6):
		net.player_realms[peer_id] = net.PlayerRealm.EARTH

	# Admin extraction must never preserve a cinematic cabin coordinate as an
	# Earth gameplay position, including early ascent below the realm separator.
	net.rocket_state = {"phase": net.RocketMissionPhase.RETURN,
		"crew": [1, 2], "elapsed": 8.0,
		"duration": net.ROCKET_RETURN_SECONDS, "serial": 1}
	net._rocket_started_msec = Time.get_ticks_msec() - 8_000
	net.player_realms[1] = net.PlayerRealm.TRANSIT
	manager._apply_authoritative_state(net.expedition_state_snapshot())
	manager._local_realm = net.PlayerRealm.TRANSIT
	player.admin_teleport(Vector3(140.0, 5200.0, -80.0))
	var earth_spawn: Vector3 = world.spawn_point()
	var extracted_state: Dictionary = net.rocket_state.duplicate(true)
	extracted_state.crew = [2]
	var saved_active: bool = bool(net.active)
	var saved_is_host: bool = bool(net.is_host)
	net.active = true
	net.is_host = false
	net.cl_expedition_state(extracted_state, {1: net.PlayerRealm.EARTH})
	net.active = saved_active
	net.is_host = saved_is_host
	_check(net.player_realm() == net.PlayerRealm.EARTH \
			and not (net.rocket_state.crew as Array).has(1) \
			and player.global_position.distance_to(earth_spawn) < 0.01,
		"remote admin Earth snapshot safely extracts a removed passenger instead of treating it as natural return")
	net._reset_expedition_state(true)
	manager._apply_authoritative_state(net.expedition_state_snapshot())
	for peer_id in range(2, 6):
		net.player_realms[peer_id] = net.PlayerRealm.EARTH

	# --- authoritative four-seat outbound mission -------------------------
	var earth_rocket_position: Vector3 = net._earth_rocket_position()
	for peer_id in range(2, 6):
		net._peer_on_foot_positions[peer_id] = earth_rocket_position
	var first_four_boarded := true
	for peer_id in range(1, 5):
		first_four_boarded = first_four_boarded \
			and net._host_set_rocket_board(peer_id, true)
	var fifth_rejected: bool = not net._host_set_rocket_board(5, true)
	_check(first_four_boarded and fifth_rejected \
			and (net.rocket_state.crew as Array).size() == net.MAX_ROCKET_CREW,
		"authority accepts four seats and rejects a fifth monkey")
	_check(manager.rocket.crew_count() == 4 \
			and manager.rocket.seat_for_peer(1) >= 0 \
			and manager.rocket.seat_for_peer(4) >= 0,
		"authoritative manifest creates all four physical seated presentations")
	_check(player.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF \
			and world.puppets[2].physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF,
		"seated local and remote monkeys use the same render-frame pose as their cabin")
	# The same E event reaches _unhandled_input and Player's polled action state in
	# one frame on a listen host. It must disembark once, clear the physical hull,
	# and be consumed during the short reboard guard.
	var disembark_event := InputEventKey.new()
	disembark_event.physical_keycode = KEY_E
	disembark_event.keycode = KEY_E
	disembark_event.pressed = true
	manager._unhandled_input(disembark_event)
	var safely_outside_hull: bool = player.global_position.distance_to(
		manager.rocket.global_position) > 2.6
	var consumed_same_tap: bool = manager.try_interact(player)
	_check(not (net.rocket_state.crew as Array).has(1) \
			and manager.rocket.seat_for_peer(1) == -1 \
			and not player.expedition_locked and safely_outside_hull \
			and manager._local_reboard_cooldown_remaining > 0.0 \
			and consumed_same_tap \
			and not (net.rocket_state.crew as Array).has(1),
		"one E press disembarks beside the hatch without immediately reboarding")
	_check(player.physics_interpolation_mode == original_player_interpolation \
			and not manager._crew_interpolation_modes.has(1),
		"manifest removal restores the actor's original interpolation mode")
	manager._local_reboard_cooldown_remaining = 0.0
	_check(net._host_set_rocket_board(1, true) \
			and manager.rocket.seat_for_peer(1) >= 0,
		"the hatch accepts a deliberate later reboard")
	_check(net._host_start_rocket(1) \
			and int(net.rocket_state.phase) == net.RocketMissionPhase.OUTBOUND \
			and is_equal_approx(float(net.rocket_state.duration),
				net.ROCKET_OUTBOUND_SECONDS),
		"seated crew member starts an authority-owned 60-second outbound mission")
	var all_transit := true
	for peer_id in range(1, 5):
		all_transit = all_transit \
			and net.player_realm(peer_id) == net.PlayerRealm.TRANSIT
	_check(all_transit and player.expedition_locked \
			and manager.rocket.state == rocket_script.State.LAUNCH_ASCENT,
		"launch atomically moves the crew to transit and locks local movement")
	# Reproduce the real join order: mission state reaches ExpeditionManager before
	# Main creates this remote puppet. The periodic manifest retry must attach the
	# authority-approved passenger even though the physical craft is already moving.
	manager._force_remove_crew(4)
	var old_peer_four: Node = world.puppets[4]
	world.puppets.erase(4)
	old_peer_four.free()
	manager._sync_manifest(net.expedition_state_snapshot())
	var late_peer_four := Node3D.new()
	late_peer_four.name = "LateJoinPuppet4"
	world.add_child(late_peer_four)
	world.puppets[4] = late_peer_four
	manager._sync_manifest(net.expedition_state_snapshot())
	var late_peer_four_seat: int = manager.rocket.seat_for_peer(4)
	_check(late_peer_four_seat >= 0 \
			and late_peer_four.global_position.distance_to(
				manager.rocket.seat_global_transform(late_peer_four_seat).origin) < 0.01,
		"late-created voyage puppet attaches to its authoritative moving cabin seat")
	manager.rocket.apply_authoritative_clock(
		rocket_script.State.LAUNCH_ASCENT, true, outbound_ascent_end - 0.001)
	manager._update_voyage_camera(0.0,
		(outbound_ascent_end - 0.001) / rocket_script.OUTBOUND_DURATION_SECONDS,
		net.expedition_state_snapshot())
	var ascent_camera_position: Vector3 = manager.voyage_camera.global_position
	var ascent_camera_forward: Vector3 = -manager.voyage_camera.global_basis.z
	var ascent_rocket_position: Vector3 = manager.rocket.global_position
	manager.rocket.apply_authoritative_clock(
		rocket_script.State.ATMOSPHERE_EXIT, true, outbound_ascent_end)
	manager._update_voyage_camera(0.0,
		outbound_ascent_end / rocket_script.OUTBOUND_DURATION_SECONDS,
		net.expedition_state_snapshot())
	var atmosphere_camera_position: Vector3 = manager.voyage_camera.global_position
	var atmosphere_camera_forward: Vector3 = -manager.voyage_camera.global_basis.z
	var atmosphere_rocket_position: Vector3 = manager.rocket.global_position
	_check((ascent_camera_position - ascent_rocket_position).distance_to(
			atmosphere_camera_position - atmosphere_rocket_position) < 2.0 \
			and ascent_camera_forward.dot(atmosphere_camera_forward) > 0.999,
		"vertical launch hands off to the chase camera without a position or focus snap",
		"world_move=%.4f relative_move=%.4f forward_dot=%.8f" % [
			ascent_camera_position.distance_to(atmosphere_camera_position),
			(ascent_camera_position - ascent_rocket_position).distance_to(
				atmosphere_camera_position - atmosphere_rocket_position),
			ascent_camera_forward.dot(atmosphere_camera_forward)])
	# Scripted ascent retains the already-built surface and opaque globe. It must
	# not run walking/aircraft altitude streaming jobs while the rocket climbs.
	var ground_streaming_paused := true
	var opaque_before_and_after_retire := true
	var curved_surface_never_hard_pops := true
	var globe_full_seconds := float(
		manager.rocket.voyage_visuals.get_script().get_script_constant_map().get(
			"EARTH_GLOBE_FULL_SECONDS", 12.0))
	for elapsed in [0.0, 1.0 / 60.0, 1.0, 4.0, 8.5, 14.0, globe_full_seconds]:
		manager.rocket.apply_authoritative_clock(
			rocket_script.state_for_elapsed(true, float(elapsed)), true,
			float(elapsed))
		manager._update_voyage_camera(0.0,
			float(elapsed) / rocket_script.OUTBOUND_DURATION_SECONDS, {}, true)
		ground_streaming_paused = ground_streaming_paused \
			and not world.earth_streaming_enabled()
		if float(elapsed) <= globe_full_seconds:
			curved_surface_never_hard_pops = curved_surface_never_hard_pops \
				and world.earth_transit_surface_visible()
		opaque_before_and_after_retire = opaque_before_and_after_retire \
			and manager.rocket.voyage_visuals.earth_visual.visible \
			and absf(manager.rocket.voyage_visuals.earth_visual.transparency) \
				< 0.0001
	_check(ground_streaming_paused \
			and not world.earth_streaming_enabled() \
			and curved_surface_never_hard_pops \
			and opaque_before_and_after_retire,
		"Earth streaming pauses at liftoff while retained ground stays visible through the full sphere reveal",
		"globe_full=%.3f streaming_after=%s surface_visible=%s" % [
			globe_full_seconds,
			str(world.earth_streaming_enabled()),
			str(world.earth_transit_surface_visible())])
	var earth_ascent_camera_ok := true
	var transfer_camera_ok := true
	var lunar_descent_camera_ok := true
	var lunar_approach_moon_visible := true
	var lunar_depth_handoff_ok := true
	var lunar_tangent_errors: Array[float] = []
	var camera_failures: Array[String] = []
	var departure_globe_ok := true
	var departure_earth_instance_id: int = \
		manager.rocket.voyage_visuals.earth_visual.get_instance_id()
	var departure_globe_fractions: Array[float] = []
	for elapsed in [8.501, 10.0, 12.0,
			outbound_ascent_end, outbound_cruise_start]:
		manager.rocket.apply_authoritative_clock(
			rocket_script.state_for_elapsed(true, float(elapsed)), true,
			float(elapsed))
		manager._update_voyage_camera(0.0,
			float(elapsed) / rocket_script.OUTBOUND_DURATION_SECONDS, {}, true)
		var globe_fraction := _sphere_vertical_view_fraction(
			manager.voyage_camera, manager.rocket.voyage_visuals.earth_visual)
		departure_globe_fractions.append(globe_fraction)
		var globe_opacity: float = 1.0 \
			- manager.rocket.voyage_visuals.earth_visual.transparency
		var horizon_visible := _viewport_ray_hits_sphere(manager.voyage_camera,
			manager.rocket.voyage_visuals.earth_visual)
		departure_globe_ok = departure_globe_ok \
			and not world.earth_streaming_enabled() \
			and manager.rocket.voyage_visuals.earth_visual.get_instance_id() \
				== departure_earth_instance_id \
			and manager.rocket.voyage_visuals.earth_visual.visible \
			and absf(globe_opacity - 1.0) < 0.0001 \
			and (horizon_visible or globe_fraction > 0.05)
	_check(departure_globe_ok \
			and departure_globe_fractions[-1] > 0.05 \
			and departure_globe_fractions[-1] < 0.95,
		"the tangent horizon becomes a full 3D Earth geometrically while its alpha remains exactly opaque",
		"vertical_view_fractions=%s" % [departure_globe_fractions])
	for elapsed in [0.0, 0.25, 1.0, 3.0, 6.0, 8.0, 12.0,
			outbound_ascent_end - 0.001, outbound_ascent_end]:
		manager.rocket.apply_authoritative_clock(
			rocket_script.state_for_elapsed(true, float(elapsed)), true,
			float(elapsed))
		manager._update_voyage_camera(0.0,
			float(elapsed) / rocket_script.OUTBOUND_DURATION_SECONDS, {}, true)
		var outside_earth: Array[String] = _rocket_hull_anchors_outside_frustum(
			manager.rocket, manager.voyage_camera)
		if not outside_earth.is_empty():
			earth_ascent_camera_ok = false
			camera_failures.append("Earth %.3f %s" % [float(elapsed), outside_earth])
	var transfer_alignment_ok := true
	var transfer_globe_ok := true
	var transfer_alignment_dots: Array[float] = []
	var transfer_earth_angular_radii: Array[float] = []
	var first_transfer_earth_angular_radius := -1.0
	var final_transfer_earth_angular_radius := -1.0
	var maximum_transfer_earth_angular_radius := 0.0
	for elapsed in [outbound_ascent_end, outbound_cruise_start - 2.0,
			30.0, 38.0, 44.0]:
		manager.rocket.apply_authoritative_clock(
			rocket_script.state_for_elapsed(true, float(elapsed)), true,
			float(elapsed))
		manager._update_voyage_camera(0.0,
			float(elapsed) / rocket_script.OUTBOUND_DURATION_SECONDS, {}, true)
		var outside_transfer: Array[String] = _rocket_hull_anchors_outside_frustum(
			manager.rocket, manager.voyage_camera)
		if not outside_transfer.is_empty():
			transfer_camera_ok = false
			camera_failures.append("Transfer %.3f %s" % [
				float(elapsed), outside_transfer])
		var direction_to_moon: Vector3 = (
			manager.rocket.moon_landing_transform.origin \
				- manager.rocket.global_position).normalized()
		var alignment: float = manager.rocket.global_basis.y.normalized().dot(
			direction_to_moon)
		transfer_alignment_dots.append(alignment)
		transfer_alignment_ok = transfer_alignment_ok and alignment > 0.75
		var earth_angular_radius := _sphere_angular_radius(
			manager.voyage_camera, manager.rocket.voyage_visuals.earth_visual)
		transfer_earth_angular_radii.append(earth_angular_radius)
		var earth_proxy_opacity: float = 1.0 \
			- manager.rocket.voyage_visuals.earth_visual.transparency
		if first_transfer_earth_angular_radius < 0.0:
			first_transfer_earth_angular_radius = earth_angular_radius
		final_transfer_earth_angular_radius = earth_angular_radius
		maximum_transfer_earth_angular_radius = maxf(
			maximum_transfer_earth_angular_radius, earth_angular_radius)
		transfer_globe_ok = transfer_globe_ok \
			and not world.earth_streaming_enabled() \
			and manager.rocket.voyage_visuals.earth_visual.get_instance_id() \
				== departure_earth_instance_id \
			and manager.rocket.voyage_visuals.earth_visual.visible \
			and absf(earth_proxy_opacity - 1.0) < 0.0001
	transfer_globe_ok = transfer_globe_ok \
		and final_transfer_earth_angular_radius \
			< first_transfer_earth_angular_radius * 0.5 \
		and maximum_transfer_earth_angular_radius \
			<= first_transfer_earth_angular_radius + 0.0001
	for elapsed in [outbound_descent_start, outbound_descent_start + 2.0,
			outbound_descent_start + 4.0, outbound_descent_start + 6.0,
			outbound_descent_start + 8.0, outbound_descent_start + 9.5]:
		manager.rocket.apply_authoritative_clock(
			rocket_script.state_for_elapsed(true, float(elapsed)), true,
			float(elapsed))
		manager._update_voyage_camera(0.0,
			float(elapsed) / rocket_script.OUTBOUND_DURATION_SECONDS, {}, true)
		var outside_descent: Array[String] = _rocket_hull_anchors_outside_frustum(
			manager.rocket, manager.voyage_camera)
		if not outside_descent.is_empty():
			lunar_descent_camera_ok = false
			camera_failures.append("Moon descent %.3f %s" % [
				float(elapsed), outside_descent])
		lunar_approach_moon_visible = lunar_approach_moon_visible \
			and manager.moon_world.visible \
			and manager.moon_world.is_visible_in_tree()
		var moon_proxy := manager.rocket.voyage_visuals.moon_visual \
			as MeshInstance3D
		var moon_sphere := moon_proxy.mesh as SphereMesh
		var moon_scale := moon_proxy.global_basis.get_scale()
		var moon_radius := moon_sphere.radius * maxf(absf(moon_scale.x),
			maxf(absf(moon_scale.y), absf(moon_scale.z))) \
			if moon_sphere else 0.0
		var landing_up: Vector3 = \
			manager.rocket.moon_landing_transform.basis.y.normalized()
		var proxy_tangent: Vector3 = \
			moon_proxy.global_position + landing_up * moon_radius
		var landing_xz: Vector2 = moon_script.LANDING_XZ
		var local_tangent: Vector3 = manager.moon_world.to_global(
			manager.moon_world.cinematic_surface_point(Vector3(
				landing_xz.x, 0.0, landing_xz.y)))
		var tangent_error: float = proxy_tangent.distance_to(local_tangent)
		var proxy_relief_clearance: float = float(
			manager.rocket.voyage_visuals.MOON_PROXY_RELIEF_CLEARANCE)
		lunar_tangent_errors.append(tangent_error)
		lunar_depth_handoff_ok = lunar_depth_handoff_ok \
			and moon_proxy.visible \
			and absf(moon_proxy.transparency) < 0.0001 \
			and absf(tangent_error - proxy_relief_clearance) < 1.0
	_check(earth_ascent_camera_ok and transfer_camera_ok \
			and lunar_descent_camera_ok,
		"production voyage camera keeps the complete rocket hull in-frame through Earth ascent, transfer, and lunar descent",
		"outside=%s" % [camera_failures])
	_check(transfer_globe_ok,
		"transfer keeps the same fixed-scale opaque Earth while distance makes its angular size recede",
		"angular_radii=%s" % [transfer_earth_angular_radii])
	_check(transfer_alignment_ok,
		"rocket nose remains aligned toward the Moon during the transfer leg",
		"alignment_dots=%s" % [transfer_alignment_dots])
	_check(manager.voyage_camera.physics_interpolation_mode \
			== Node.PHYSICS_INTERPOLATION_MODE_OFF,
		"voyage camera renders the tracked transform without a stale second interpolation pass")
	_check(lunar_approach_moon_visible and lunar_depth_handoff_ok,
		"opaque Moon proxy and curved MoonWorld coexist at one tangent throughout descent",
		"tangent_errors=%s" % [lunar_tangent_errors])
	var moon_lighting_matches := true
	for elapsed in [44.0, 46.0, 48.0, 50.0, 55.0]:
		manager.rocket.apply_authoritative_clock(
			rocket_script.state_for_elapsed(true, float(elapsed)), true, float(elapsed))
		manager._update_voyage_camera(0.0,
			float(elapsed) / rocket_script.OUTBOUND_DURATION_SECONDS, {}, true)
		moon_lighting_matches = moon_lighting_matches \
			and manager.voyage_camera.environment == manager.moon_world.lunar_environment \
			and is_zero_approx(manager.rocket.voyage_visuals.celestial_fill_light.light_energy)
	_check(moon_lighting_matches,
		"Moon approach uses the exact walking environment and removes global voyage fill before touchdown")
	# Inspect the production shot, not an unused Earth/Moon-centre pan helper.
	var focus_alignment := 1.0
	var largest_camera_turn := 0.0
	var previous_camera_forward := Vector3.ZERO
	var transfer_frame_failures: Array[String] = []
	for frame in range(1201):
		var elapsed := 24.0 + float(frame) / 60.0
		manager.rocket.apply_authoritative_clock(
			rocket_script.state_for_elapsed(true, elapsed), true, elapsed)
		manager._update_voyage_camera(0.0,
			elapsed / rocket_script.OUTBOUND_DURATION_SECONDS, {}, true)
		var actual_forward: Vector3 = -manager.voyage_camera.global_basis.z.normalized()
		var camera_focus: Vector3 = manager.voyage_camera_focus_target()
		var focus_direction: Vector3 = (camera_focus - manager.voyage_camera.global_position).normalized()
		focus_alignment = minf(focus_alignment, actual_forward.dot(focus_direction))
		if not previous_camera_forward.is_zero_approx():
			largest_camera_turn = maxf(largest_camera_turn,
				previous_camera_forward.angle_to(actual_forward))
		previous_camera_forward = actual_forward
		var hull_outside := _rocket_hull_anchors_outside_frustum(
			manager.rocket, manager.voyage_camera)
		var planet_visible := _globe_intersects_camera_frustum(manager.voyage_camera,
			manager.rocket.voyage_visuals.earth_visual) \
			or _globe_intersects_camera_frustum(manager.voyage_camera,
				manager.rocket.voyage_visuals.moon_visual)
		if (not hull_outside.is_empty() or not planet_visible) and transfer_frame_failures.size() < 8:
			transfer_frame_failures.append("%.3f hull=%s planet=%s" % [elapsed, hull_outside, planet_visible])
	var cabin_puppet: Variant = world.puppets[2]
	var cabin_seat: int = int(manager.rocket.seat_for_peer(2))
	cabin_puppet.apply_state(earth_rocket_position + Vector3(80.0, 0.0, 0.0),
		0.0, Vector3(0.0, 0.0, 1700.0), 0, false,
		Vector3.ZERO, 0.0, PackedVector3Array())
	manager.rocket._emit_crew_poses()
	var expected_cabin_pose: Transform3D = \
		manager.rocket.seat_global_transform(cabin_seat)
	cabin_puppet._process(0.25)
	_check(cabin_puppet.is_externally_driven() \
			and cabin_puppet.global_transform.origin.distance_to(
				expected_cabin_pose.origin) < 0.01,
		"real remote Puppet stays physically locked to its moving cabin seat")
	_check(focus_alignment > 0.9999 and largest_camera_turn < deg_to_rad(2.0) \
			and transfer_frame_failures.is_empty(),
		"live transfer camera follows its reported focus continuously while framing the complete hull and a planet",
		"viewport=%s alignment=%.6f max_turn=%.4fdeg failures=%s" % [
			manager.voyage_camera.get_viewport().get_visible_rect().size, focus_alignment,
			rad_to_deg(largest_camera_turn), transfer_frame_failures])

	net._rocket_started_msec = Time.get_ticks_msec() - 59_000
	net._rocket_sync_remaining = 0.0
	net._process(0.016)
	# The capture probes above seek nonsequential moments. A live authority
	# packet now adjusts the smooth clock's target instead of teleporting the
	# displayed hull; explicitly simulate this fixture's skipped visible time.
	manager.rocket.advance_voyage(maxf(59.0 - manager.rocket.voyage_elapsed, 0.0))
	_check(int(net.rocket_state.phase) == net.RocketMissionPhase.OUTBOUND \
			and float(net.rocket_state.elapsed) >= 59.0 \
			and manager.rocket.state == rocket_script.State.LUNAR_APPROACH,
		"authority remains outbound before 60 seconds and peers derive approach")
	net._rocket_started_msec = Time.get_ticks_msec() - 60_000
	net._process(0.016)
	_check(int(net.rocket_state.phase) == net.RocketMissionPhase.MOON_READY \
			and (net.rocket_state.crew as Array).is_empty(),
		"authority completes outbound only at the full one-minute boundary")
	var every_peer_on_moon := true
	for peer_id in range(1, 5):
		every_peer_on_moon = every_peer_on_moon \
			and net.player_realm(peer_id) == net.PlayerRealm.MOON
	_check(every_peer_on_moon and manager.rocket.state \
			== rocket_script.State.LANDED_MOON \
			and not cabin_puppet.is_externally_driven(),
		"arrival moves the complete manifest to the Moon and lands the rocket")
	_check(player.physics_interpolation_mode == original_player_interpolation \
			and cabin_puppet.physics_interpolation_mode == original_puppet_interpolation \
			and manager._crew_interpolation_modes.is_empty(),
		"arrival restores local and remote interpolation and releases all seat overrides")
	_check(manager.local_suit != null and manager.local_suit.equipped \
			and manager.local_suit.exposed_to_vacuum \
			and manager.local_inventory.backpack_kind \
				== inventory_script.Backpack.SPACE \
			and manager.local_inventory.slot_count() == inventory_script.SPACE_SLOTS,
		"local lunar arrival integrates suit, oxygen tank, and space inventory")
	_check(is_equal_approx(player.environment_gravity_mps2,
			moon_script.LUNAR_GRAVITY) and not world.earth_streaming_enabled() \
			and manager.moon_world.visible \
			and is_equal_approx(player.safe_margin,
				player.LUNAR_COLLISION_SAFE_MARGIN),
		"realm transition applies 1.62 m/s² and pauses Earth streaming")
	# A realm transition is not playable merely because gravity and presentation
	# changed. Run the real CharacterBody controller and prove ordinary W input
	# crosses solid lunar ground on foot. Enable the fixture's
	# physics subtree while keeping its deliberately incomplete streaming loop
	# stopped, so this exercises CharacterBody-to-StaticBody contact without
	# pulling unrelated world generation into the integration gate.
	world.process_mode = Node.PROCESS_MODE_ALWAYS
	world.set_process(false)
	world.set_physics_process(false)
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	await physics_frame
	var landing_surface: Vector3 = manager.moon_world.surface_position_at(
		player.global_position)
	var landing_up_direction: Vector3 = manager.moon_world.radial_up_at(
		player.global_position)
	var lunar_ground_query: PhysicsRayQueryParameters3D = \
		PhysicsRayQueryParameters3D.create(
		landing_surface + landing_up_direction * 4.0,
		landing_surface - landing_up_direction * 4.0,
		1, [player.get_rid(), manager.rocket.get_rid()])
	var lunar_ground_hit: Dictionary = player.get_world_3d().direct_space_state \
		.intersect_ray(lunar_ground_query)
	_check(not lunar_ground_hit.is_empty() \
			and lunar_ground_hit.get("collider") == manager.moon_world.terrain_body,
		"lunar landing pad exposes solid ground to character physics",
		str(lunar_ground_hit))
	var lunar_shape_probe := PhysicsShapeQueryParameters3D.new()
	lunar_shape_probe.shape = player._collision_shape.shape
	lunar_shape_probe.transform = player._collision_shape.global_transform
	lunar_shape_probe.motion = -landing_up_direction * 2.0
	lunar_shape_probe.collision_mask = 1
	lunar_shape_probe.exclude = [player.get_rid(), manager.rocket.get_rid()]
	var lunar_cast_result: PackedFloat32Array = player.get_world_3d() \
		.direct_space_state.cast_motion(lunar_shape_probe)
	var lunar_capsule_can_reach_ground := lunar_cast_result.size() == 2 \
		and lunar_cast_result[0] < 1.0
	_check(lunar_capsule_can_reach_ground,
		"lunar landing floor accepts the monkey capsule, not only ray queries",
		"cast=%s" % [lunar_cast_result])
	var lunar_walk_start := Vector2(player.global_position.x,
		player.global_position.z)
	# Cross the pad and continue onto the generated spherical terrain. This keeps
	# the regression from passing on the dedicated touchdown contact alone.
	# The monkey lands on the rocket's +X side, so continue outward instead of
	# walking back into the capsule hull and mistaking that solid obstacle for a
	# movement lock.
	player.ti.dir = Vector2(1.0, 0.0)
	var lunar_floor_frames := 0
	for frame in range(240):
		await physics_frame
		if player.is_on_floor():
			lunar_floor_frames += 1
	player.ti.dir = Vector2.ZERO
	var lunar_walk_finish := Vector2(player.global_position.x,
		player.global_position.z)
	_check(not player.expedition_locked and not player._collision_shape.disabled \
			and player.collision_layer == 1 and player.collision_mask == 1 \
			and lunar_floor_frames > 30 \
			and lunar_walk_start.distance_to(lunar_walk_finish) > 12.0,
		"touchdown releases the cabin lock and the monkey can walk on lunar ground",
		"locked=%s collider_disabled=%s layer=%d mask=%d floor_frames=%d state=%d y=%.3f ground=%.3f vy=%.3f moved=%.3f start=%s finish=%s" % [
			player.expedition_locked, player._collision_shape.disabled,
			player.collision_layer, player.collision_mask, lunar_floor_frames,
			player.state, player.global_position.y,
			manager.moon_world.surface_position_at(player.global_position).y,
			player.velocity.dot(player.up_direction),
			lunar_walk_start.distance_to(lunar_walk_finish),
			lunar_walk_start, lunar_walk_finish])
	player.process_mode = Node.PROCESS_MODE_INHERIT
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var remote_suit: Node = world.puppets[2].get_node_or_null(
		"SpaceSuitSystem")
	_check(remote_suit != null and remote_suit.get_script() == suit_script \
			and not bool(remote_suit.get("exposed_to_vacuum")),
		"remote Moon monkeys receive replicated visible life-support suits")
	var lunar_rescue_position: Vector3 = manager.moon_world.to_global(
		manager.moon_world.actor_landing_position())
	var lunar_void_y: float = world.void_rescue_height(player)
	var antipode_surface: Vector3 = manager.moon_world.to_global(
		manager.moon_world.surface_position(Vector3.DOWN, 0.1))
	# A disabled CollisionObject subtree is removed from the physics space.
	# Restore this player's real physics ticks before probing either hemisphere.
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	player.admin_teleport(antipode_surface)
	await physics_frame
	await physics_frame
	_check(is_inf(lunar_void_y) and lunar_void_y < 0.0 \
			and player.global_position.distance_to(antipode_surface) < 0.1 \
			and player.up_direction.dot(Vector3.DOWN) > 0.999,
		"healthy explorer on far lunar hemisphere is not rescued by an Earth Y threshold")
	player.admin_teleport(manager.moon_world.to_global(
		manager.moon_world.surface_position(Vector3.DOWN, -60.0)))
	await physics_frame
	await physics_frame
	_check(player.global_position.is_finite() \
			and player.global_position.distance_to(lunar_rescue_position) < 0.01 \
			and net.player_realm() == net.PlayerRealm.MOON,
		"radial penetration inside the lunar globe triggers actual controller rescue at the Moon pad")
	player.process_mode = Node.PROCESS_MODE_INHERIT

	# Oxygen failure uses the ordinary lethal-damage path, but its recovery must
	# remain in the lunar coordinate frame with a usable replacement tank.
	manager.local_suit.oxygen_seconds = 0.0
	# This integration world's physics are intentionally disabled. Detach the
	# back-reference for the one damage call so it proves lethal suit behavior
	# without constructing a physics-jointed ragdoll outside an active space; the
	# World-level delayed recovery delegates to the method tested immediately next.
	var active_world: Variant = player.world
	player.world = null
	manager._on_oxygen_depleted()
	player.world = active_world
	_check(player.defeated,
		"oxygen depletion defeats the exposed lunar monkey")
	player.global_position = Vector3(-4.0, gen.height(-4.0, 4.0) + 2.2, 4.0)
	var rescued: bool = manager.respawn_local_player_after_defeat(player)
	_check(rescued and not player.defeated \
			and player.global_position.distance_to(lunar_rescue_position) < 0.01 \
			and is_equal_approx(manager.local_suit.oxygen_seconds,
				suit_script.OXYGEN_CAPACITY_SECONDS) \
			and manager.local_suit.exposed_to_vacuum \
			and net.player_realm() == net.PlayerRealm.MOON,
		"lunar defeat respawns at the Moon pad with full oxygen, not on Earth")

	# --- oxygen station and authority-backed Moon cheese ------------------
	manager.local_suit.oxygen_seconds = 10.0
	player.admin_teleport(manager.rocket.boarding_global_position())
	_check(manager.try_interact(player) \
			and is_equal_approx(manager.local_suit.oxygen_seconds,
				suit_script.OXYGEN_CAPACITY_SECONDS),
		"Moon rocket interaction refills the integrated oxygen tank")
	player.admin_teleport(manager.moon_world.cheese_shop.to_global(
		Vector3(0.0, 0.5, -6.0)))
	net._peer_on_foot_positions[1] = player.global_position
	_check(manager.try_interact(player) and manager._shop_overlay.visible \
			and manager.moon_world.cheese_shop.villager._trading,
		"forecourt interaction opens the real trade panel and engages the lunar merchant")
	# First arrival can legitimately grant the colony's starter allowance.
	# Verify the transaction's exact debit against the actual pre-order balance.
	var trade_balance_before: int = int(net.scores[1])
	manager._request_cheese_purchase(2)
	_check(int(net.scores[1]) == trade_balance_before - 6 \
			and manager.local_inventory.count_item(
				inventory_script.ITEM_MOON_CHEESE) == 2 \
			and manager.local_inventory.count_item(
				manager_script.PENDING_CHEESE_ITEM) == 0 \
			and manager._pending_cheese_quantity == 0,
		"server spends six bananas and atomically delivers two reserved cheeses")
	manager._request_cheese_purchase(4)
	_check(int(net.scores[1]) == trade_balance_before - 6 \
			and manager.local_inventory.count_item(
				inventory_script.ITEM_MOON_CHEESE) == 2 \
			and manager._pending_cheese_quantity == 0,
		"rejected unaffordable trade releases reservation without spending bananas")
	manager._close_shop()
	net.player_realms[2] = net.PlayerRealm.MOON
	net.scores[2] = 10
	net._peer_on_foot_positions[2] = Vector3(4000.0,
		net.MOON_WORLD_ORIGIN_Y, 4000.0)
	_check(not net._host_purchase_moon_cheese(2, 1) \
			and int(net.scores[2]) == 10,
		"authority rejects remote Moon-cheese purchases away from the shop")

	# --- admin realm validation and exact faster return -------------------
	var admin_before: bool = bool(net.is_admin)
	net.is_admin = false
	_check(not manager.admin_travel(net.PlayerRealm.EARTH),
		"non-admin local caller cannot use planetary realm travel")
	net.is_admin = admin_before
	_check(not manager.admin_travel(net.PlayerRealm.TRANSIT) \
			and not manager.admin_travel(net.PlayerRealm.MOON, 99999),
		"admin travel rejects transit destinations and unknown peer targets")

	var moon_rocket_position := Vector3(-54.0,
		net.MOON_WORLD_ORIGIN_Y + 2.0, 42.0)
	for peer_id in range(2, 5):
		net.player_realms[peer_id] = net.PlayerRealm.MOON
		net._peer_on_foot_positions[peer_id] = moon_rocket_position
	var return_manifest := true
	for peer_id in range(1, 5):
		return_manifest = return_manifest \
			and net._host_set_rocket_board(peer_id, true)
	manager._sync_realm_suits()
	_check(not manager.local_suit.exposed_to_vacuum,
		"occupied Moon cabin pauses oxygen use while parked before launch")
	var parked_seat: Transform3D = player.global_transform
	manager._apply_local_realm(net.PlayerRealm.MOON)
	_check(player.expedition_locked and manager.cabin_view_active() \
			and player.global_transform.is_equal_approx(parked_seat) \
			and not manager.local_suit.exposed_to_vacuum,
		"late Moon realm snapshot preserves an occupied cabin, seat and oxygen")
	_check(return_manifest and net._host_start_rocket(1) \
			and int(net.rocket_state.phase) == net.RocketMissionPhase.RETURN \
			and is_equal_approx(float(net.rocket_state.duration),
				net.ROCKET_RETURN_SECONDS) \
			and manager.local_suit.equipped \
			and bool(remote_suit.get("equipped")),
		"Moon crew starts the suited, faster authoritative 45-second return")
	var moon_ascent_camera_ok := true
	var moon_ascent_moon_visible := true
	var moon_ascent_camera_failures: Array[String] = []
	for elapsed in [0.0, 0.25, 1.0, 2.0, 4.0, 5.9]:
		manager.rocket.apply_authoritative_clock(
			rocket_script.state_for_elapsed(false, float(elapsed)), false,
			float(elapsed))
		manager._update_voyage_camera(0.0,
			float(elapsed) / rocket_script.RETURN_DURATION_SECONDS, {}, true)
		var outside_ascent: Array[String] = _rocket_hull_anchors_outside_frustum(
			manager.rocket, manager.voyage_camera)
		if not outside_ascent.is_empty():
			moon_ascent_camera_ok = false
			moon_ascent_camera_failures.append("%.3f %s" % [
				float(elapsed), outside_ascent])
		moon_ascent_moon_visible = moon_ascent_moon_visible \
			and manager.moon_world.visible \
			and manager.moon_world.is_visible_in_tree()
	_check(moon_ascent_camera_ok,
		"production voyage camera keeps the complete rocket hull in-frame through Moon ascent",
		"outside=%s" % [moon_ascent_camera_failures])
	_check(moon_ascent_moon_visible,
		"real MoonWorld stays visible throughout the return ascent")
	var return_lighting_matches := true
	for elapsed in [0.0, 4.0, 8.0]:
		manager.rocket.apply_authoritative_clock(
			rocket_script.state_for_elapsed(false, float(elapsed)), false, float(elapsed))
		manager._update_voyage_camera(0.0,
			float(elapsed) / rocket_script.RETURN_DURATION_SECONDS, {}, true)
		return_lighting_matches = return_lighting_matches \
			and manager.voyage_camera.environment == manager.moon_world.lunar_environment \
			and is_zero_approx(manager.rocket.voyage_visuals.celestial_fill_light.light_energy)
	_check(return_lighting_matches,
		"Moon departure retains lunar ambient lighting without an added global fill through eight seconds")
	_check(manager.admin_travel(net.PlayerRealm.EARTH, 2) \
			and net.player_realm(2) == net.PlayerRealm.EARTH \
			and not (net.rocket_state.crew as Array).has(2) \
			and manager.rocket.seat_for_peer(2) == -1,
		"admin realm travel removes a passenger from authority and moving cabin")

	net._rocket_started_msec = Time.get_ticks_msec() - 44_000
	net._rocket_sync_remaining = 0.0
	net._process(0.016)
	manager.rocket.advance_voyage(maxf(44.0 - manager.rocket.voyage_elapsed, 0.0))
	_check(int(net.rocket_state.phase) == net.RocketMissionPhase.RETURN \
			and manager.rocket.state == rocket_script.State.OCEAN_APPROACH,
		"authority remains in fiery return before 45 seconds")
	net._rocket_started_msec = Time.get_ticks_msec() - 45_000
	net._process(0.016)
	_check(int(net.rocket_state.phase) \
			== net.RocketMissionPhase.SPLASHDOWN_RECOVERY \
			and is_equal_approx(float(net.rocket_state.duration), 3.0) \
			and (net.rocket_state.crew as Array) == [1, 3, 4] \
			and net.player_realm(1) == net.PlayerRealm.EARTH \
			and manager.rocket.state == rocket_script.State.SPLASHDOWN,
		"45-second authority completion begins shared landing-engine shutdown on the pad")
	_check(is_equal_approx(player.environment_gravity_mps2,
			player_script.FREEFALL_ACCELERATION) \
			and world.earth_streaming_enabled() and not manager.moon_world.visible \
			and not manager.local_suit.exposed_to_vacuum \
			and not manager.local_suit.equipped \
			and not bool(remote_suit.get("equipped")) \
			and player.expedition_locked,
		"Earth pad touchdown restores streaming, gravity and breathable-air outfits while recovery keeps crew seated")
	_check(not net._host_set_rocket_board(1, true) \
			and not net._host_start_rocket(1) \
			and not manager.rocket.can_board(),
		"authority and physical rocket keep boarding locked during the brief landing shutdown")

	# A late join has no previous RETURN phase to infer from. Recreate that local
	# presentation history and prove the replicated recovery phase alone restores
	# the exact landed pad pose without re-running descent.
	manager._reset_rocket_to_launchpad()
	manager._last_net_phase = net.RocketMissionPhase.EARTH_READY
	net._rocket_started_msec = Time.get_ticks_msec() - 1_000
	manager._apply_authoritative_state(net.expedition_state_snapshot())
	_check(manager.rocket.state == rocket_script.State.SPLASHDOWN \
			and manager.rocket.global_transform.is_equal_approx(
				manager.rocket.ocean_splashdown_transform),
		"late join snapshot places the rocket at the authoritative pad touchdown")
	_check(absf(manager._recovery_elapsed - 1.0) < 0.05 \
			and is_equal_approx(manager.rocket.landing_gear_deployment, 1.0) \
			and is_equal_approx(manager.rocket.landing_strut_compression, 1.0),
		"late join reconstructs deployed, compressed landing gear at the current shutdown age")
	var recovery_hull: Transform3D = manager.rocket.global_transform
	var recovery_before: float = manager._recovery_elapsed
	var delayed_recovery: Dictionary = net.expedition_state_snapshot()
	delayed_recovery.elapsed = 0.5
	manager._apply_authoritative_state(delayed_recovery)
	var after_recovery_packet: float = manager._recovery_elapsed
	manager._process(1.0 / 60.0)
	_check(is_equal_approx(after_recovery_packet, recovery_before) \
			and manager._recovery_elapsed > recovery_before \
			and manager._recovery_elapsed - recovery_before < 0.02 \
			and manager.rocket.global_transform.is_equal_approx(recovery_hull),
		"delayed recovery packets correct a monotonic effect clock without moving the landed capsule")
	net._rocket_started_msec = Time.get_ticks_msec() - 2_500
	net._rocket_sync_remaining = 0.0
	net._process(0.016)
	_check(int(net.rocket_state.phase) \
			== net.RocketMissionPhase.SPLASHDOWN_RECOVERY \
			and float(net.rocket_state.elapsed) >= 2.5 \
			and manager.rocket.state == rocket_script.State.SPLASHDOWN,
		"engine shutdown stays on the pad for its full authority clock")
	net._rocket_started_msec = Time.get_ticks_msec() - 3_000
	net._process(0.016)
	var recovered_remote: Node3D = world.puppets[3]
	var landed_pose: Transform3D = manager.rocket.global_transform
	_check(int(net.rocket_state.phase) == net.RocketMissionPhase.EARTH_READY \
			and is_zero_approx(float(net.rocket_state.elapsed)) \
			and is_zero_approx(float(net.rocket_state.duration)) \
			and (net.rocket_state.crew as Array) == [1, 3, 4] \
			and manager.rocket.state == rocket_script.State.EARTH_BOARDING \
			and landed_pose.is_equal_approx(manager.rocket.earth_launch_transform) \
			and manager.rocket.crew_count() == 3 and player.expedition_locked \
			and player.global_transform.is_equal_approx(manager.rocket.seat_global_transform(0)) \
			and recovered_remote.global_position.distance_to(
				manager.rocket.seat_global_transform(manager.rocket.seat_for_peer(3)).origin) < 0.01,
		"engine shutdown ends with all crew still aboard the same landed rocket")
	_check(manager.rocket.earth_launch_transform.is_equal_approx(
			manager.rocket.ocean_splashdown_transform),
		"departure and powered return share one physical launchpad transform")
	manager.set_cabin_view(true)
	_check(manager.cabin_view_active() and manager.voyage_camera.current \
			and manager.voyage_camera.get_parent() == manager.rocket \
			and manager.voyage_camera.transform.is_equal_approx(
				manager.rocket.cabin_eye_local_transform(0)),
		"first-person cabin camera uses the actual local seat eye without world-space chase")
	manager._cabin_yaw = 0.55
	manager._cabin_pitch = -0.28
	manager._update_aboard_camera()
	var eye_before_toggle: Transform3D = manager.voyage_camera.transform
	manager.set_cabin_view(false)
	_check(manager.voyage_camera.get_parent() == world \
			and manager.voyage_camera.current and not manager.cabin_view_active(),
		"C switches the occupied rocket to a complete exterior view")
	manager.set_cabin_view(true)
	_check(manager.voyage_camera.transform.is_equal_approx(eye_before_toggle),
		"returning to the cabin preserves the passenger's free-look direction")
	var stream_focus: Vector3 = manager.rocket.earth_launch_transform.origin \
		- Vector3.UP * rocket_script.ORIGIN_ABOVE_LANDING_SURFACE + Vector3.UP
	world.set_expedition_stream_focus(stream_focus)
	var distant_cabin: Vector3 = player.global_position
	player.global_position = Vector3(4000.0, 52000.0, 9000.0)
	_check(world._stream_focus_position().is_equal_approx(stream_focus) \
			and world._stream_focus_velocity() == Vector3.ZERO \
			and world.center_chunk() == Vector2i(floori(stream_focus.x / gen.CHUNK),
				floori(stream_focus.z / gen.CHUNK)),
		"return terrain prepares the pad rather than the fast-moving high-altitude cabin")
	player.global_position = distant_cabin
	world.clear_expedition_stream_focus()
	# A delayed reliable manifest can outlive the tap debounce. Preserve intent
	# until the accepted response so a passenger never unlocks inside the hull.
	manager._local_disembark_requested = true
	manager._local_disembark_request_remaining = 0.0
	_check(net._host_set_rocket_board(1, false), "landed passenger can explicitly leave after engine shutdown")
	var hatch: Vector3 = manager.rocket.disembark_global_position()
	_check(not player.expedition_locked and manager.rocket.seat_for_peer(1) == -1 \
			and Vector2(player.global_position.x, player.global_position.z).distance_to(
				Vector2(hatch.x, hatch.z)) < 0.01 \
			and absf(player.global_position.y - gen.height(hatch.x, hatch.z) - 0.25) < 0.01 \
			and manager.rocket.global_transform.is_equal_approx(landed_pose),
		"hatch exit lands beside the unchanged rocket on its pad, never at the carrier or spawn")
	_check(player.cam._cam.current and player.cam.is_processing() \
			and not manager.cabin_view_active(),
		"leaving the cabin restores the normal player camera and movement")

	# The authority must never publish an in-transit snapshot with an empty crew.
	# Simulate the final passenger disconnecting on each route and verify that the
	# craft returns to the world it departed from with a valid zeroed clock.
	var empty_routes_valid := true
	for route_phase in [net.RocketMissionPhase.OUTBOUND,
			net.RocketMissionPhase.RETURN]:
		net.rocket_state = {
			"phase": route_phase, "crew": [2], "elapsed": 15.0,
			"duration": net.ROCKET_OUTBOUND_SECONDS if route_phase \
				== net.RocketMissionPhase.OUTBOUND else net.ROCKET_RETURN_SECONDS,
			"serial": 19,
		}
		net._rocket_started_msec = Time.get_ticks_msec() - 15_000
		net._remove_peer_from_rocket(2)
		var expected_ready: int = net.RocketMissionPhase.EARTH_READY \
			if route_phase == net.RocketMissionPhase.OUTBOUND \
			else net.RocketMissionPhase.MOON_READY
		empty_routes_valid = empty_routes_valid \
			and int(net.rocket_state.phase) == expected_ready \
			and (net.rocket_state.crew as Array).is_empty() \
			and is_zero_approx(float(net.rocket_state.elapsed)) \
			and is_zero_approx(float(net.rocket_state.duration)) \
			and net._rocket_started_msec == 0 \
			and net._valid_expedition_state(net.rocket_state)
	_check(empty_routes_valid,
		"final crew disconnect safely cancels outbound and return voyages")

	# Release the unused fixture player before the standalone SceneTree exits.
	if player.wind:
		player.wind.stop()
		player.wind.stream = null
		player.wind.queue_free()
		await process_frame
	stage.queue_free()
	await process_frame
	await process_frame
	net.shutdown()
	print("EXPEDITIONINTEGRATIONTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)
