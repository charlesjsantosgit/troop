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


func _run() -> void:
	print("EXPEDITION INTEGRATION TEST")
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
	for peer_id in range(2, 5):
		if peer_id == 2:
			world.spawn_puppet(peer_id, net.names[peer_id])
		else:
			var puppet := Node3D.new()
			puppet.name = "IntegrationPuppet%d" % peer_id
			world.add_child(puppet)
			world.puppets[peer_id] = puppet

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
	_check(not manager.local_inventory.has_backpack() \
			and not manager.inventory_ui.open_inventory(),
		"integrated inventory remains inaccessible before backpack equipment")
	_check(manager.grant_normal_backpack() \
			and manager.local_inventory.backpack_kind \
				== inventory_script.Backpack.NORMAL \
			and manager.local_inventory.slot_count() == inventory_script.NORMAL_SLOTS \
			and manager._normal_backpack_visual != null,
		"an Earth supply backpack enables twelve slots and a visible worn pack")

	# --- authority validation envelope ------------------------------------
	var valid_outbound := {"phase": net.RocketMissionPhase.OUTBOUND,
		"crew": [1, 2, 3, 4], "elapsed": 179.999,
		"duration": 180.0, "serial": 1}
	var bad_outbound_duration := valid_outbound.duplicate(true)
	bad_outbound_duration.duration = 120.0
	var bad_return_elapsed := {"phase": net.RocketMissionPhase.RETURN,
		"crew": [1], "elapsed": 120.001, "duration": 120.0, "serial": 2}
	var valid_recovery := {"phase": net.RocketMissionPhase.SPLASHDOWN_RECOVERY,
		"crew": [], "elapsed": 17.999, "duration": 18.0, "serial": 2}
	var valid_recovery_manifest := valid_recovery.duplicate(true)
	valid_recovery_manifest.crew = [1, 2, 3, 4]
	var bad_recovery_duration := valid_recovery.duplicate(true)
	bad_recovery_duration.duration = 17.0
	var bad_ready_clock := {"phase": net.RocketMissionPhase.EARTH_READY,
		"crew": [], "elapsed": 1.0, "duration": 0.0, "serial": 2}
	_check(net._valid_expedition_state(valid_outbound) \
			and net._valid_expedition_state(valid_recovery) \
			and net._valid_expedition_state(valid_recovery_manifest) \
			and not net._valid_expedition_state(bad_outbound_duration) \
			and not net._valid_expedition_state(bad_return_elapsed) \
			and not net._valid_expedition_state(bad_recovery_duration) \
			and not net._valid_expedition_state(bad_ready_clock),
		"network snapshots enforce exact phase-specific 180/120/18-second clocks")
	_check(not net._valid_expedition_state({"phase": 1, "crew": [1, 1],
			"elapsed": 0.0, "duration": 180.0, "serial": 1}) \
			and not net._valid_expedition_state({"phase": 1,
				"crew": [1, 2, 3, 4, 5], "elapsed": 0.0,
				"duration": 180.0, "serial": 1}),
		"network snapshots reject duplicate and over-capacity manifests")
	_check(rocket_script.state_for_elapsed(true, 27.999) \
			== rocket_script.State.LAUNCH_ASCENT \
			and rocket_script.state_for_elapsed(true, 28.0) \
				== rocket_script.State.ATMOSPHERE_EXIT \
			and rocket_script.state_for_elapsed(true, 179.999) \
				== rocket_script.State.LUNAR_APPROACH \
			and rocket_script.state_for_elapsed(true, 180.0) \
				== rocket_script.State.LANDED_MOON \
			and rocket_script.state_for_elapsed(false, 119.999) \
				== rocket_script.State.OCEAN_APPROACH \
			and rocket_script.state_for_elapsed(false, 120.0) \
				== rocket_script.State.SPLASHDOWN,
		"presentation states share exact authority clock boundaries")

	# A global expedition is visible to everyone, but its cinematic must never
	# take control from an Earth spectator who is not on the manifest.
	var spectator_state := {"phase": net.RocketMissionPhase.OUTBOUND,
		"crew": [2], "elapsed": 12.0, "duration": 180.0, "serial": 1}
	net.rocket_state = spectator_state.duplicate(true)
	net.player_realms[1] = net.PlayerRealm.EARTH
	manager.voyage_camera.current = false
	manager._update_voyage_camera(0.0, 0.1, spectator_state)
	_check(not manager.voyage_camera.current \
			and not manager._local_player_is_voyaging(spectator_state),
		"another crew's launch never hijacks a non-passenger camera")
	manager.rocket._set_scripted_flight(true)
	manager._reset_rocket_to_launchpad()
	_check(not manager.rocket._scripted_flight and manager.rocket.freeze \
			and manager.rocket.collision_layer == 1 \
			and manager.rocket.collision_mask == 1,
		"cancelled outbound voyage restores the launchpad rocket's physical hull")
	net._reset_expedition_state(true)
	for peer_id in range(2, 6):
		net.player_realms[peer_id] = net.PlayerRealm.EARTH

	# Admin extraction must never preserve a cinematic cabin coordinate as an
	# Earth gameplay position, including early ascent below the realm separator.
	net.rocket_state = {"phase": net.RocketMissionPhase.RETURN,
		"crew": [1, 2], "elapsed": 8.0, "duration": 120.0, "serial": 1}
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
	manager._local_reboard_cooldown_remaining = 0.0
	_check(net._host_set_rocket_board(1, true) \
			and manager.rocket.seat_for_peer(1) >= 0,
		"the hatch accepts a deliberate later reboard")
	_check(net._host_start_rocket(1) \
			and int(net.rocket_state.phase) == net.RocketMissionPhase.OUTBOUND \
			and is_equal_approx(float(net.rocket_state.duration), 180.0),
		"seated crew member starts an authority-owned 180-second outbound mission")
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
		rocket_script.State.LUNAR_APPROACH, true, 154.0)
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
	var pan_start: Vector3 = manager.voyage_camera_focus_target()
	var earth_focus: Vector3 = manager.rocket.voyage_visuals.earth_visual.global_position
	manager.rocket.apply_authoritative_clock(
		rocket_script.State.LUNAR_APPROACH, true, 166.0)
	var pan_finish: Vector3 = manager.voyage_camera_focus_target()
	var moon_focus: Vector3 = manager.rocket.voyage_visuals.moon_visual.global_position
	_check(pan_start.distance_to(earth_focus) < 0.01 \
			and pan_finish.distance_to(moon_focus) < 0.01 \
			and pan_start.distance_to(pan_finish) > 20.0,
		"lunar approach performs a real twelve-second Earth-to-Moon camera pan")

	net._rocket_started_msec = Time.get_ticks_msec() - 179_000
	net._rocket_sync_remaining = 0.0
	net._process(0.016)
	_check(int(net.rocket_state.phase) == net.RocketMissionPhase.OUTBOUND \
			and float(net.rocket_state.elapsed) >= 179.0 \
			and manager.rocket.state == rocket_script.State.LUNAR_APPROACH,
		"authority remains outbound before 180 seconds and peers derive approach")
	net._rocket_started_msec = Time.get_ticks_msec() - 180_000
	net._process(0.016)
	_check(int(net.rocket_state.phase) == net.RocketMissionPhase.MOON_READY \
			and (net.rocket_state.crew as Array).is_empty(),
		"authority completes outbound only at the full three-minute boundary")
	var every_peer_on_moon := true
	for peer_id in range(1, 5):
		every_peer_on_moon = every_peer_on_moon \
			and net.player_realm(peer_id) == net.PlayerRealm.MOON
	_check(every_peer_on_moon and manager.rocket.state \
			== rocket_script.State.LANDED_MOON \
			and not cabin_puppet.is_externally_driven(),
		"arrival moves the complete manifest to the Moon and lands the rocket")
	_check(manager.local_suit != null and manager.local_suit.equipped \
			and manager.local_suit.exposed_to_vacuum \
			and manager.local_inventory.backpack_kind \
				== inventory_script.Backpack.SPACE \
			and manager.local_inventory.slot_count() == inventory_script.SPACE_SLOTS,
		"local lunar arrival integrates suit, oxygen tank, and space inventory")
	_check(is_equal_approx(player.environment_gravity_mps2,
			moon_script.LUNAR_GRAVITY) and not world.earth_streaming_enabled() \
			and manager.moon_world.visible,
		"realm transition applies 1.62 m/s² and pauses Earth streaming")
	var remote_suit: Node = world.puppets[2].get_node_or_null(
		"SpaceSuitSystem")
	_check(remote_suit != null and remote_suit.get_script() == suit_script \
			and not bool(remote_suit.get("exposed_to_vacuum")),
		"remote Moon monkeys receive replicated visible life-support suits")
	var lunar_rescue_position: Vector3 = manager.moon_world.to_global(
		manager.moon_world.actor_landing_position())
	var lunar_void_y: float = world.void_rescue_height(player)
	player.global_position = Vector3(500.0, lunar_void_y - 1.0, 500.0)
	world.respawn(player)
	_check(lunar_void_y > net.MOON_WORLD_ORIGIN_Y - 60.0 \
			and player.global_position.distance_to(lunar_rescue_position) < 0.01 \
			and net.player_realm() == net.PlayerRealm.MOON,
		"falling off the lunar landing zone rescues the monkey on the Moon")

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
	player.admin_teleport(manager.rocket.global_position + Vector3(4.0, 0.5, 0.0))
	_check(manager.try_interact(player) \
			and is_equal_approx(manager.local_suit.oxygen_seconds,
				suit_script.OXYGEN_CAPACITY_SECONDS),
		"Moon rocket interaction refills the integrated oxygen tank")
	player.admin_teleport(manager.moon_world.cheese_shop.global_position \
		+ Vector3(0.0, 0.5, -3.2))
	net._peer_on_foot_positions[1] = player.global_position
	manager._request_cheese_purchase(2)
	_check(int(net.scores[1]) == 4 \
			and manager.local_inventory.count_item(
				inventory_script.ITEM_MOON_CHEESE) == 2 \
			and manager.local_inventory.count_item(
				manager_script.PENDING_CHEESE_ITEM) == 0 \
			and manager._pending_cheese_quantity == 0,
		"server spends six bananas and atomically delivers two reserved cheeses")
	manager._request_cheese_purchase(4)
	_check(int(net.scores[1]) == 4 \
			and manager.local_inventory.count_item(
				inventory_script.ITEM_MOON_CHEESE) == 2 \
			and manager._pending_cheese_quantity == 0,
		"rejected unaffordable trade releases reservation without spending bananas")
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
	_check(return_manifest and net._host_start_rocket(1) \
			and int(net.rocket_state.phase) == net.RocketMissionPhase.RETURN \
			and is_equal_approx(float(net.rocket_state.duration), 120.0) \
			and manager.local_suit.equipped \
			and bool(remote_suit.get("equipped")),
		"Moon crew starts the suited, faster authoritative 120-second return")
	_check(manager.admin_travel(net.PlayerRealm.EARTH, 2) \
			and net.player_realm(2) == net.PlayerRealm.EARTH \
			and not (net.rocket_state.crew as Array).has(2) \
			and manager.rocket.seat_for_peer(2) == -1,
		"admin realm travel removes a passenger from authority and moving cabin")

	net._rocket_started_msec = Time.get_ticks_msec() - 119_000
	net._rocket_sync_remaining = 0.0
	net._process(0.016)
	_check(int(net.rocket_state.phase) == net.RocketMissionPhase.RETURN \
			and manager.rocket.state == rocket_script.State.OCEAN_APPROACH,
		"authority remains in fiery return before 120 seconds")
	net._rocket_started_msec = Time.get_ticks_msec() - 120_000
	net._process(0.016)
	_check(int(net.rocket_state.phase) \
			== net.RocketMissionPhase.SPLASHDOWN_RECOVERY \
			and is_equal_approx(float(net.rocket_state.duration), 18.0) \
			and (net.rocket_state.crew as Array) == [1, 3, 4] \
			and net.player_realm(1) == net.PlayerRealm.EARTH \
			and manager.rocket.state == rocket_script.State.SPLASHDOWN,
		"120-second authority completion begins replicated ocean recovery")
	_check(is_equal_approx(player.environment_gravity_mps2,
			player_script.FREEFALL_ACCELERATION) \
			and world.earth_streaming_enabled() and not manager.moon_world.visible \
			and not manager.local_suit.exposed_to_vacuum \
			and not manager.local_suit.equipped \
			and not bool(remote_suit.get("equipped")) \
			and player.expedition_locked,
		"Earth splashdown restores gravity and breathable-air outfits while recovery keeps crew seated")
	_check(not net._host_set_rocket_board(1, true) \
			and not net._host_start_rocket(1) \
			and not manager.rocket.can_board(),
		"authority and physical rocket keep boarding locked during ocean recovery")

	# A late join has no previous RETURN phase to infer from. Recreate that local
	# presentation history and prove the replicated recovery phase alone restores
	# the ocean pose instead of exposing the launch pad early.
	manager._reset_rocket_to_launchpad()
	manager._last_net_phase = net.RocketMissionPhase.EARTH_READY
	manager._apply_authoritative_state(net.expedition_state_snapshot())
	_check(manager.rocket.state == rocket_script.State.SPLASHDOWN \
			and manager.rocket.global_transform.is_equal_approx(
				manager.rocket.ocean_splashdown_transform),
		"late join snapshot places the rocket at authoritative splashdown")
	net._rocket_started_msec = Time.get_ticks_msec() - 17_000
	net._rocket_sync_remaining = 0.0
	net._process(0.016)
	_check(int(net.rocket_state.phase) \
			== net.RocketMissionPhase.SPLASHDOWN_RECOVERY \
			and float(net.rocket_state.elapsed) >= 17.0 \
			and manager.rocket.state == rocket_script.State.SPLASHDOWN,
		"recovery remains at the ocean for the full authority clock")
	net._rocket_started_msec = Time.get_ticks_msec() - 18_000
	net._process(0.016)
	var recovered_remote: Node3D = world.puppets[3]
	var launch_origin: Vector3 = manager.rocket.earth_launch_transform.origin
	_check(int(net.rocket_state.phase) == net.RocketMissionPhase.EARTH_READY \
			and is_zero_approx(float(net.rocket_state.elapsed)) \
			and is_zero_approx(float(net.rocket_state.duration)) \
			and (net.rocket_state.crew as Array).is_empty() \
			and manager.rocket.state == rocket_script.State.EARTH_BOARDING \
			and manager.rocket.global_transform.is_equal_approx(
				manager.rocket.earth_launch_transform) \
			and manager.rocket.crew_count() == 0 \
			and not player.expedition_locked \
			and player.global_position.distance_to(launch_origin) < 8.0 \
			and recovered_remote.global_position.distance_to(launch_origin) < 8.0,
		"authority recovers the capsule and every remaining crew actor at the launch pad after eighteen seconds")

	# The authority must never publish an in-transit snapshot with an empty crew.
	# Simulate the final passenger disconnecting on each route and verify that the
	# craft returns to the world it departed from with a valid zeroed clock.
	var empty_routes_valid := true
	for route_phase in [net.RocketMissionPhase.OUTBOUND,
			net.RocketMissionPhase.RETURN]:
		net.rocket_state = {
			"phase": route_phase, "crew": [2], "elapsed": 15.0,
			"duration": 180.0 if route_phase \
				== net.RocketMissionPhase.OUTBOUND else 120.0,
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
