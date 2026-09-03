extends Node
## Landing replication uses real loopback ENet peers in separate MultiplayerAPI
## branches of one engine. Authentication/registration is a separate security
## gate; these fixture rosters isolate the real authority RPC receivers without
## writing identity keys or opening a public listener.

var passed := 0
var total := 0
var _main: Node
var _manager: ExpeditionManager
var _endpoints: Array[Dictionary] = []
var _server: Node
var _port := 0
var _saved_multiplayer_poll := true
var _passenger := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _check(ok: bool, label: String, detail := "") -> void:
	total += 1
	passed += int(ok)
	print("[%s] %s%s" % ["PASS" if ok else "FAIL", label,
		" :: " + detail if not detail.is_empty() else ""])


func run(main: Node) -> void:
	print("ROCKET LANDING REPLICATION TEST")
	_main = main
	_manager = main.expedition_manager
	main.set_process(false)
	_manager.set_process(false)
	Net.set_process(false)
	main.world.set_earth_streaming_enabled(false)
	main.world.local_player.test_mode = true
	main.world.local_player.set_physics_process(false)
	_saved_multiplayer_poll = get_tree().multiplayer_poll
	get_tree().multiplayer_poll = false
	if await _build_network():
		await _test_replicated_landings()
		_test_physical_mechanisms()
		await _test_moon_platform_contacts()
		_test_camera_mechanism_framing()
		_test_manifest_seat_order()
	await _cleanup()
	print("ROCKETLANDINGTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	main._return_to_main_menu()
	for _frame in range(4):
		await get_tree().process_frame
	get_tree().quit(0 if passed == total else 1)


func _make_endpoint(server: bool) -> Dictionary:
	var branch := Node.new()
	branch.name = "LandingServer" if server else "LandingClient%d" % _endpoints.size()
	add_child(branch)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, branch.get_path())
	var net: Node = load("res://scripts/net.gd").new()
	net.name = "Net"
	branch.add_child(net)
	net.set_process(false)
	net.set("active", true)
	net.set("is_host", server)
	net.set("is_dedicated", server)
	net.set("world_seed", Gen.world_seed)
	var peer := ENetMultiplayerPeer.new()
	var error: int
	if server:
		peer.set_bind_ip("127.0.0.1")
		error = peer.create_server(0, 4, Net.CHANNEL_COUNT)
		if error == OK:
			_port = peer.host.get_local_port()
	else:
		error = peer.create_client("127.0.0.1", _port, Net.CHANNEL_COUNT)
	api.multiplayer_peer = peer if error == OK else null
	var endpoint := {"branch": branch, "api": api, "net": net,
		"peer": peer, "error": error, "received": [], "world_ready": false,
		"rocket": null, "id": 1 if server else peer.get_unique_id()}
	var index := _endpoints.size()
	_endpoints.append(endpoint)
	if not server:
		net.connect("expedition_state_changed", _on_received.bind(index))
		net.connect("world_ready", _on_world_ready.bind(index))
		var replica := LunarRocket.new()
		branch.add_child(replica)
		replica.set_process(false)
		replica.set_physics_process(false)
		replica.freeze = true
		replica.configure_route(_manager.rocket.earth_launch_transform,
			_manager.rocket.moon_landing_transform, _manager.rocket.ocean_splashdown_transform)
		replica.voyage_visuals.set_local_viewer_enabled(false)
		endpoint.rocket = replica
	return endpoint


func _build_network() -> bool:
	var authority := _make_endpoint(true)
	_server = authority.net
	if int(authority.error) != OK:
		_check(false, "loopback authority binds an ephemeral private port", str(authority.error))
		return false
	var first := _make_endpoint(false)
	var second := _make_endpoint(false)
	if int(first.error) != OK or int(second.error) != OK:
		_check(false, "two independent ENet clients initialize")
		return false
	_passenger = int(first.id)
	var connected: bool = await _pump_until(func() -> bool:
		return (authority.api as SceneMultiplayer).get_peers().size() == 2)
	_check(connected and int(first.id) != int(second.id) \
		and int(first.id) > 1 and int(second.id) > 1,
		"one engine runs a real ENet authority and two distinct connected receivers")
	if not connected:
		return false
	_install_rosters()
	return true


func _install_rosters() -> void:
	var names := {1: "Authority"}
	var scores := {1: 0}
	var realms: Dictionary = (_server.get("player_realms") as Dictionary).duplicate()
	if not realms.has(1):
		realms[1] = Net.PlayerRealm.EARTH
	for endpoint in _endpoints.slice(1):
		var peer_id := int(endpoint.id)
		names[peer_id] = "Passenger" if peer_id == _passenger else "Observer"
		scores[peer_id] = 0
		if not realms.has(peer_id):
			realms[peer_id] = Net.PlayerRealm.TRANSIT if peer_id == _passenger else Net.PlayerRealm.MOON
	for endpoint in _endpoints:
		endpoint.net.names = names.duplicate()
		endpoint.net.scores = scores.duplicate()
		endpoint.net.player_realms = realms.duplicate()


func _pump_until(predicate: Callable, timeout_ms := 2500) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		for endpoint in _endpoints:
			if int(endpoint.error) == OK:
				(endpoint.api as SceneMultiplayer).poll()
		if bool(predicate.call()):
			return true
		await get_tree().process_frame
	return bool(predicate.call())


func _on_world_ready(index: int) -> void:
	_endpoints[index].world_ready = true


func _on_received(snapshot: Dictionary, index: int) -> void:
	_endpoints[index].received.append(snapshot.duplicate(true))
	# The real Net receiver has already validated and installed the packet. The
	# exact presentation API proves its replay is deterministic on fresh replicas;
	# Manager's smooth clock/observer glue is covered separately by integration.
	var endpoint := _endpoints[index]
	var replica: LunarRocket = endpoint.rocket
	var phase := int(snapshot.phase)
	var local_viewer: bool = snapshot.crew.has(int(endpoint.id))
	replica.voyage_visuals.set_local_viewer_enabled(local_viewer)
	match phase:
		Net.RocketMissionPhase.OUTBOUND, Net.RocketMissionPhase.RETURN:
			var outbound := phase == Net.RocketMissionPhase.OUTBOUND
			replica.apply_authoritative_clock(LunarRocket.state_for_elapsed(outbound,
				float(snapshot.elapsed)), outbound, float(snapshot.elapsed))
		Net.RocketMissionPhase.MOON_READY:
			replica.apply_authoritative_clock(LunarRocket.State.LANDED_MOON, true, 60.0)
		Net.RocketMissionPhase.SPLASHDOWN_RECOVERY:
			replica.apply_authoritative_clock(LunarRocket.State.SPLASHDOWN, false, 45.0)
			replica.present_landing_recovery(float(snapshot.elapsed))
		_:
			replica.apply_authoritative_clock(LunarRocket.State.EARTH_BOARDING, true, 0.0)


func _publish(phase: int, elapsed: float, serial: int) -> bool:
	var duration := Net.ROCKET_OUTBOUND_SECONDS if phase == Net.RocketMissionPhase.OUTBOUND \
		else Net.ROCKET_RETURN_SECONDS if phase == Net.RocketMissionPhase.RETURN \
		else Net.ROCKET_RECOVERY_SECONDS if phase == Net.RocketMissionPhase.SPLASHDOWN_RECOVERY else 0.0
	var crew: Array = [] if phase in [Net.RocketMissionPhase.MOON_READY,
		Net.RocketMissionPhase.EARTH_READY] else [_passenger]
	_server.set("rocket_state", {"phase": phase, "crew": crew, "elapsed": elapsed,
		"duration": duration, "serial": serial})
	var realms: Dictionary = _server.get("player_realms")
	realms[_passenger] = Net.PlayerRealm.TRANSIT if phase in [Net.RocketMissionPhase.OUTBOUND,
		Net.RocketMissionPhase.RETURN] else Net.PlayerRealm.MOON \
		if phase == Net.RocketMissionPhase.MOON_READY else Net.PlayerRealm.EARTH
	for endpoint in _endpoints.slice(2):
		realms[int(endpoint.id)] = Net.PlayerRealm.MOON if phase in [Net.RocketMissionPhase.OUTBOUND,
			Net.RocketMissionPhase.MOON_READY] else Net.PlayerRealm.EARTH
	_server.set("_rocket_started_msec", 0)
	_server.call("_broadcast_expedition_state")
	return await _pump_until(func() -> bool:
		for endpoint in _endpoints.slice(1):
			var received: Array = endpoint.received
			if received.is_empty() or received[-1] != _server.get("rocket_state"):
				return false
		return true)


func _shared_signature(rocket: LunarRocket) -> Dictionary:
	var result := {"hull": rocket.global_transform, "state": rocket.state}
	_collect_shared_nodes(rocket, rocket, result)
	return result


func _collect_shared_nodes(node: Node, rocket: LunarRocket, result: Dictionary,
		prefix := "") -> void:
	for index in range(node.get_child_count()):
		var child := node.get_child(index)
		if child == rocket.voyage_visuals:
			continue
		var key := prefix + "/" + str(index)
		if child is Node3D:
			var data := {"visible": (child as Node3D).visible}
			if (child as Node3D).visible:
				data.transform = (child as Node3D).transform
			if child is GPUParticles3D:
				data.emitting = child.emitting
				data.amount_ratio = child.amount_ratio
			if child is GeometryInstance3D and child.visible:
				data.transparency = child.transparency
			# Repeated mesh names receive per-instance generated suffixes. Stable
			# child order compares actual components without comparing those IDs.
			result[key] = data
		_collect_shared_nodes(child, rocket, result, key)


func _same_shared_animation() -> bool:
	var expected := _shared_signature(_endpoints[1].rocket)
	for endpoint in _endpoints.slice(2):
		if _shared_signature(endpoint.rocket) != expected:
			return false
	return true


func _visible_opaque_hull(replica: LunarRocket) -> bool:
	var exterior := replica.get_node_or_null("VehicleStructure")
	if not exterior:
		return false
	for part in exterior.get_children():
		if part is MeshInstance3D and part.is_visible_in_tree() \
				and part.mesh and part.mesh.get_surface_count() > 0:
			return true
	return false


func _send_world_to(endpoint: Dictionary) -> void:
	_server.rpc_id(int(endpoint.id), "cl_world", Gen.world_seed, [], {}, 12.0,
		_server.call("effective_game_version"), {}, {}, {}, _server.get("player_realms"),
		_server.call("expedition_state_snapshot"))


func _test_replicated_landings() -> void:
	for elapsed in [50.0, 53.0, 55.0, 58.5, 59.8]:
		var delivered: bool = await _publish(Net.RocketMissionPhase.OUTBOUND, elapsed, 11)
		var observer: LunarRocket = _endpoints[2].rocket
		_check(delivered and _same_shared_animation() \
			and _visible_opaque_hull(observer) \
			and not observer.voyage_visuals.is_visible_in_tree(),
			"actual reliable RPC gives passenger and observer identical shared lunar landing at %.1fs" % elapsed)
	_server.call("_complete_rocket_voyage", Net.RocketMissionPhase.OUTBOUND)
	var arrived: bool = await _pump_until(func() -> bool:
		return int(_endpoints[1].net.rocket_state.get("phase", -1)) == Net.RocketMissionPhase.MOON_READY \
			and int(_endpoints[2].net.rocket_state.get("phase", -1)) == Net.RocketMissionPhase.MOON_READY)
	_check(arrived and _same_shared_animation() \
		and int(_endpoints[1].net.player_realms[_passenger]) == Net.PlayerRealm.MOON \
		and int(_endpoints[2].net.player_realms[_passenger]) == Net.PlayerRealm.MOON,
		"authority completion installs the same settled Moon pose and passenger realm on every receiver")
	var late := _make_endpoint(false)
	var joined: bool = await _pump_until(func() -> bool:
		return (_endpoints[0].api as SceneMultiplayer).get_peers().size() == 3)
	if not joined:
		_check(false, "a fresh third ENet observer connects for late-join replay")
		return
	_install_rosters()
	_send_world_to(late)
	var world_received: bool = await _pump_until(func() -> bool: return bool(late.world_ready))
	_check(world_received and _same_shared_animation() \
		and int(late.net.player_realms[_passenger]) == Net.PlayerRealm.MOON \
		and not (late.rocket as LunarRocket).lunar_dust.emitting,
		"actual cl_world late join reconstructs settled lunar mechanisms without replaying a landing blast")
	for elapsed in [40.0, 42.0, 44.8]:
		var delivered: bool = await _publish(Net.RocketMissionPhase.RETURN, elapsed, 12)
		_check(delivered and _same_shared_animation(),
			"all three receivers reconstruct identical shared powered landing mechanisms at %.1fs" % elapsed)
	for age in [0.0, 0.7, 1.5, 2.5, 2.99]:
		var delivered: bool = await _publish(Net.RocketMissionPhase.SPLASHDOWN_RECOVERY, age, 12)
		_check(delivered and _same_shared_animation() \
			and not (_endpoints[2].rocket as LunarRocket).voyage_visuals.is_visible_in_tree(),
			"authority recovery age %.1fs reproduces identical settled legs for every observer" % age)
		if is_equal_approx(float(age), 1.5):
			var recovery_join := _make_endpoint(false)
			var connected: bool = await _pump_until(func() -> bool:
				return (_endpoints[0].api as SceneMultiplayer).get_peers().size() == 4)
			if connected:
				_install_rosters()
				_send_world_to(recovery_join)
			var recovered: bool = connected and await _pump_until(func() -> bool:
				return bool(recovery_join.world_ready))
			_check(recovered and _same_shared_animation(),
				"cold late join during pad shutdown reconstructs the current settled legs without replaying a landing burn")
	var landed_pose: Transform3D = (_endpoints[1].rocket as LunarRocket).global_transform
	_server.call("_complete_splashdown_recovery")
	var shutdown_complete: bool = await _pump_until(func() -> bool:
		for endpoint in _endpoints.slice(1):
			if int(endpoint.net.rocket_state.get("phase", -1)) != Net.RocketMissionPhase.EARTH_READY:
				return false
		return true)
	var crew_retained := true
	for endpoint in _endpoints.slice(1):
		crew_retained = crew_retained and (endpoint.net.rocket_state.crew as Array) == [_passenger] \
			and (endpoint.rocket as LunarRocket).global_transform.is_equal_approx(landed_pose)
	_check(shutdown_complete and crew_retained and _same_shared_animation() \
		and is_equal_approx(Net.ROCKET_RECOVERY_SECONDS, 3.0),
		"actual authority completes three-second shutdown on the same pad and retains the seated crew for manual exit")
	var reset: bool = await _publish(Net.RocketMissionPhase.EARTH_READY, 0.0, 12)
	_check(reset and _same_shared_animation() \
		and not (_endpoints[1].rocket as LunarRocket).launch_plume.emitting,
		"replicated cancellation/reset removes landing thrust and returns every hull to the same launch pad")
	var before_invalid: Array[int] = []
	for endpoint in _endpoints.slice(1):
		before_invalid.append((endpoint.received as Array).size())
	var invalid: Dictionary = (_server.get("rocket_state") as Dictionary).duplicate(true)
	invalid.elapsed = NAN
	_server.rpc("cl_expedition_state", invalid, _server.get("player_realms"))
	for _frame in range(12):
		for endpoint in _endpoints:
			(endpoint.api as SceneMultiplayer).poll()
		await get_tree().process_frame
	var rejected := true
	for index in range(1, _endpoints.size()):
		rejected = rejected and (_endpoints[index].received as Array).size() == before_invalid[index - 1]
	_check(rejected and _same_shared_animation(),
		"real RPC receivers reject a non-finite landing clock without mutating the replicated animation")


func _test_manifest_seat_order() -> void:
	var existing: LunarRocket = _endpoints[1].rocket
	var late_joiner: LunarRocket = _endpoints[2].rocket
	for replica in [existing, late_joiner]:
		replica.apply_authoritative_clock(LunarRocket.State.EARTH_BOARDING, true, 0.0)
	var actors: Dictionary = {}
	for peer_id in [101, 202, 303, 404, 505, 606]:
		var actor := Node3D.new()
		add_child(actor)
		actors[peer_id] = actor
	var reserved := existing.reconcile_manifest_seats([101, 202, 303, 404])
	var last_first := existing.board_crew(404, actors[404], null, null, true)
	var second_next := existing.board_crew(202, actors[202], null, null, true)
	_check(reserved and last_first == 3 and second_next == 1
		and existing.manifest_seat_for_peer(101) == 0
		and existing.manifest_seat_for_peer(303) == 2
		and existing.board_crew(505, actors[505], null, null, true) == -1,
		"authority order reserves missing puppets' seats before later actors arrive")
	existing.board_crew(303, actors[303], null, null, true)
	existing.board_crew(101, actors[101], null, null, true)
	var all_canonical := true
	var original_manifest := [101, 202, 303, 404]
	for index in range(original_manifest.size()):
		all_canonical = all_canonical and existing.seat_for_peer(original_manifest[index]) == index
	_check(all_canonical and existing.crew_count() == 4,
		"out-of-order actor creation produces the same four canonical cabin slots")
	existing.disembark_crew(101)
	var next_manifest := [202, 303, 404, 505]
	existing.reconcile_manifest_seats(next_manifest)
	existing.board_crew(505, actors[505], null, null, true)
	late_joiner.reconcile_manifest_seats(next_manifest)
	for peer_id in [505, 303, 202, 404]:
		late_joiner.board_crew(peer_id, actors[peer_id], null, null, true)
	var replicas_agree := true
	for index in range(next_manifest.size()):
		var peer_id: int = next_manifest[index]
		replicas_agree = replicas_agree and existing.seat_for_peer(peer_id) == index \
			and late_joiner.seat_for_peer(peer_id) == index \
			and existing.seat_global_transform(index).is_equal_approx(
				late_joiner.seat_global_transform(index))
	_check(replicas_agree,
		"a seat hole and replacement passenger reconcile identically on a late observer")
	var rejects_invalid := not existing.reconcile_manifest_seats([202, 202, 404, 505]) \
		and not existing.reconcile_manifest_seats([202, 303, 404, 505, 606]) \
		and not existing.reconcile_manifest_seats([202, -1, 404, 505])
	for index in range(next_manifest.size()):
		rejects_invalid = rejects_invalid \
			and existing.manifest_seat_for_peer(next_manifest[index]) == index \
			and existing.seat_for_peer(next_manifest[index]) == index
	_check(rejects_invalid,
		"invalid seat manifests are rejected atomically without moving an occupied passenger")
	for replica in [existing, late_joiner]:
		for member in replica.crew.duplicate():
			replica.disembark_crew(int(member.peer_id))
		replica.reconcile_manifest_seats([])
	_check(existing.manifest_seat_for_peer(202) == -1 \
		and existing.board_crew(606, actors[606]) == 0,
		"clearing the authority manifest releases every reservation for the next crew")
	existing.disembark_crew(606)
	for actor in actors.values():
		(actor as Node3D).free()


func _test_physical_mechanisms() -> void:
	var rocket: LunarRocket = _endpoints[1].rocket
	_check(rocket.landing_gear.size() == 4 \
		and not rocket.has_node("ReturnOceanSurface") \
		and rocket.find_children("OceanFloat*", "MeshInstance3D", true, false).is_empty(),
		"the actual 30 metre model has four landing legs and allocates no obsolete water-landing hardware")
	var bounds := rocket.hull_bounds()
	_check(absf(bounds.end.y - 17.0) < 0.01 and absf(bounds.position.y + 10.6) < 0.01 \
		and rocket.cabin_windows.size() == 12 \
		and rocket.find_child("CabinFloorContact", true, false) is CollisionShape3D,
		"the tall pressure hull contains twelve real windows and a physical cabin floor")
	rocket.apply_authoritative_clock(LunarRocket.State.LUNAR_APPROACH, true, 50.0)
	var stowed_foot: Vector3 = (rocket.landing_gear[0].foot as Node3D).position
	rocket.apply_authoritative_clock(LunarRocket.State.LUNAR_APPROACH, true, 53.0)
	var middle_foot: Vector3 = (rocket.landing_gear[0].foot as Node3D).position
	rocket.apply_authoritative_clock(LunarRocket.State.LUNAR_APPROACH, true, 55.0)
	var deployed_foot: Vector3 = (rocket.landing_gear[0].foot as Node3D).position
	_check(middle_foot.distance_to(stowed_foot) > 0.3 \
		and middle_foot.distance_to(deployed_foot) > 0.3 \
		and deployed_foot.y < stowed_foot.y - 1.0,
		"landing gear visibly unfolds through an intermediate pose before approaching the ground")
	for outbound in [true, false]:
		var landing := rocket.moon_landing_transform if outbound else rocket.earth_launch_transform
		var up := landing.basis.y.normalized()
		var contact := landing.origin - up * LunarRocket.ORIGIN_ABOVE_LANDING_SURFACE
		var duration := LunarRocket.OUTBOUND_DURATION_SECONDS if outbound else LunarRocket.RETURN_DURATION_SECONDS
		var max_foot_error := 0.0
		var contacts := 0
		var collision_matches := true
		for frame in range(43):
			var elapsed := duration - 0.7 + float(frame) / 60.0
			rocket.apply_authoritative_clock(LunarRocket.state_for_elapsed(outbound, elapsed), outbound, elapsed)
			var clearance := maxf((rocket.global_position - landing.origin).dot(up), 0.0)
			if clearance <= LunarRocket.LANDING_STRUT_TRAVEL + 0.001:
				for leg in rocket.landing_gear:
					var foot: MeshInstance3D = leg.foot
					var mesh := foot.mesh as BoxMesh
					var collision: CollisionShape3D = leg.collision
					collision_matches = collision_matches \
						and collision.global_transform.is_equal_approx(foot.global_transform) \
						and (collision.shape as BoxShape3D).size.is_equal_approx(mesh.size)
					var bottom := foot.to_global(Vector3.DOWN * mesh.size.y * 0.5)
					max_foot_error = maxf(max_foot_error, absf((bottom - contact).dot(up)))
					contacts += 1
		_check(contacts >= 40 and max_foot_error < 0.01 and collision_matches,
			"all four actual %s landing feet remain planted while suspension compresses" % ("Moon" if outbound else "Earth"),
			"contacts=%d max_plane_error=%.6f m" % [contacts, max_foot_error])
		rocket.apply_authoritative_clock(LunarRocket.state_for_elapsed(outbound, duration), outbound, duration)
		_check(rocket.landing_gear_deployment > 0.999 and rocket.landing_strut_compression > 0.999 \
			and not rocket.launch_plume.emitting and not rocket.lunar_dust.emitting \
			and not rocket.lunar_dust_sheet.visible,
			"the completed %s landing leaves real legs compressed and all thrust settled" % ("Moon" if outbound else "Earth"))
	rocket.apply_authoritative_clock(LunarRocket.State.SPLASHDOWN, false, 45.0)
	var hull := rocket.global_transform
	rocket.voyage_visuals.set_local_viewer_enabled(false)
	var stable_pose := _shared_signature(rocket)
	var shutdown_stable := true
	for age in [0.0, 0.3, 1.0, 2.0, 3.0]:
		rocket.present_landing_recovery(age)
		shutdown_stable = shutdown_stable and _shared_signature(rocket) == stable_pose
	_check(shutdown_stable and rocket.global_transform.is_equal_approx(rocket.earth_launch_transform) \
		and not rocket.voyage_visuals.is_visible_in_tree(),
		"observers see a steadily planted capsule for the entire three-second shutdown without private scenery or a reroute")
	rocket.present_landing_recovery(0.5)
	var valid_pose := _shared_signature(rocket)
	rocket.present_landing_recovery(NAN)
	rocket.present_landing_recovery(INF)
	_check(_shared_signature(rocket) == valid_pose,
		"invalid recovery clocks cannot corrupt the planted landing mechanisms")
	rocket.apply_authoritative_clock(LunarRocket.State.EARTH_BOARDING, true, 0.0)
	_check(rocket.global_transform.is_equal_approx(hull) \
		and is_equal_approx(rocket.landing_gear_deployment, 1.0) \
		and is_equal_approx(rocket.landing_strut_compression, 1.0),
		"ready-state reset retains the same physical pad and compressed landing legs")


func _cleanup() -> void:
	for endpoint in _endpoints:
		(endpoint.peer as ENetMultiplayerPeer).close()
		(endpoint.api as SceneMultiplayer).multiplayer_peer = null
		get_tree().set_multiplayer(null, (endpoint.branch as Node).get_path())
		(endpoint.branch as Node).queue_free()
	_endpoints.clear()
	get_tree().multiplayer_poll = _saved_multiplayer_poll
	for _frame in range(3):
		await get_tree().process_frame


func _test_moon_platform_contacts() -> void:
	var replica: LunarRocket = _endpoints[1].rocket
	replica.apply_authoritative_clock(LunarRocket.State.LANDED_MOON, true, 60.0)
	await get_tree().physics_frame
	await get_tree().process_frame
	var up := replica.moon_landing_transform.basis.y.normalized()
	var maximum_gap := 0.0
	var physical_contacts := 0
	for leg in replica.landing_gear:
		var foot: MeshInstance3D = leg.foot
		var mesh := foot.mesh as BoxMesh
		var sole := foot.to_global(Vector3.DOWN * mesh.size.y * 0.5)
		var query := PhysicsRayQueryParameters3D.create(sole + up * 0.4,
			sole - up * 0.5, 1, [replica.get_rid()])
		var hit := replica.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty() and hit.collider == _manager.moon_world.landing_platform_body:
			physical_contacts += 1
			maximum_gap = maxf(maximum_gap, (hit.position as Vector3).distance_to(sole))
	_check(physical_contacts == 4 and maximum_gap < 0.02,
		"all four deployed feet physically contact the real lunar platform without floating above spherical ground",
		"contacts=%d maximum_gap=%.6f m" % [physical_contacts, maximum_gap])


func _test_camera_mechanism_framing() -> void:
	# Use each actual articulated mesh AABB, including the newly wider feet and
	# foot pads. The original smoothness markers describe only the pressure hull.
	var rocket := _manager.rocket
	for outbound in [true, false]:
		var start := 51.0 if outbound else 40.0
		var finish := 60.0 if outbound else 45.0
		var largest_screen_extent := 0.0
		var checked_corners := 0
		var visible := true
		for frame in range(int((finish - start) * 10.0) + 1):
			var elapsed := start + float(frame) / 10.0
			rocket.voyage_visuals.set_local_viewer_enabled(true)
			rocket.apply_authoritative_clock(LunarRocket.state_for_elapsed(outbound, elapsed),
				outbound, elapsed)
			rocket.present_render_sample(rocket.render_sample(elapsed))
			var pose := _manager.sample_voyage_camera_pose(elapsed, rocket.global_transform, outbound)
			var camera := Transform3D(Basis.IDENTITY, pose.position).looking_at(pose.focus, pose.up)
			var half_y := tan(deg_to_rad(float(pose.fov)) * 0.5)
			var half_x := half_y * 1600.0 / 900.0
			if _manager.voyage_camera.keep_aspect == Camera3D.KEEP_WIDTH:
				half_x = half_y
				half_y *= 900.0 / 1600.0
			var mechanisms: Array[MeshInstance3D] = []
			for leg in rocket.landing_gear:
				for part in ["arm", "piston", "brace", "foot"]:
					mechanisms.append(leg[part])
			for mechanism in mechanisms:
				if not mechanism.visible:
					continue
				var bounds := mechanism.mesh.get_aabb()
				for corner_index in range(8):
					var point: Vector3 = camera.affine_inverse() \
						* (mechanism.global_transform * bounds.get_endpoint(corner_index))
					checked_corners += 1
					if -point.z <= _manager.voyage_camera.near:
						visible = false
						continue
					largest_screen_extent = maxf(largest_screen_extent,
						maxf(absf(point.x / (-point.z * half_x)), absf(point.y / (-point.z * half_y))))
		_check(visible and checked_corners > 1000 and largest_screen_extent < 1.0,
			"the actual %s landing camera contains every corner of its articulated legs" % \
				("Moon" if outbound else "Earth"),
			"mesh_corners=%d normalized_extent=%.4f" % [checked_corners, largest_screen_extent])
