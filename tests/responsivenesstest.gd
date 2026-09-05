extends Node
## Real player/world lifecycle plus deterministic delayed-claim callbacks.
## Network timing and delivery are verified separately by the ENet relay fixture.
const Quality := preload("res://scripts/connection_quality.gd")
var passed := 0
var total := 0

func check(ok: bool, description: String) -> void:
	total += 1
	if ok: passed += 1
	print("RESPONSIVENESS %s %s" % ["PASS" if ok else "FAIL", description])

func run(main: Node) -> void:
	var world: World = main.world
	var player: MonkeyPlayer = world.local_player
	var controller: FrontierController = main.frontier_controller
	controller.persistence_enabled = false
	controller.simulation_enabled = false
	player.test_mode = true
	player._invulnerable_t = 1000.0
	check(not Net.active and controller.tutorial.path.is_empty(), "disposable offline fixture protects shared and saved careers")
	check(not Quality.sample(Net).visible, "offline play never reports fake zero-ms network quality")
	check(not Quality.describe(NAN, 0).has("rtt_ms") and not Quality.describe(0, 0).warning,
		"missing network measurements stay unavailable")
	check(Quality.describe(55, 8).text == "Ping 55 ms" and not Quality.describe(55, 8).warning,
		"healthy round trip is separate from FPS")
	check(Quality.describe(240, 8).text.contains("delayed") and Quality.describe(55, 65).text.contains("unstable"),
		"high delay and variable delivery have distinct readable states")
	check(Quality.describe(55, 8, 3).warning and not Quality.describe(55, 8, -1).detail.contains("packet loss"),
		"measured reliable loss warns while an unavailable estimate stays omitted")
	var v: Vehicle = world.spawn_vehicle(Vehicle.Kind.BIKE, "v:responsive#bike", Vector3(10, Gen.height(10, 12) + 1.5, 12), 0)
	v.freeze = true
	await get_tree().physics_frame
	player.admin_teleport(v.interaction_position())
	world._pending_vehicle_entry = v.vid
	world._pending_vehicle_entry_started_msec = Time.get_ticks_msec()
	Net.active = true
	var pending_at := world._pending_vehicle_entry_started_msec
	check(world._enter_vehicle_target(player, v) and world._pending_vehicle_entry_started_msec == pending_at \
		and player.supply_notice.contains("Waiting"), "repeated E shows immediate feedback without another seat request")
	world._pending_vehicle_entry_started_msec = Time.get_ticks_msec() - World.VEHICLE_ENTRY_TIMEOUT_MS
	world._update_pending_vehicle_entry()
	check(world._pending_vehicle_entry.is_empty() and player.supply_notice.contains("timed out"),
		"an unanswered seat request expires with an actionable retry notice")
	Net.active = false
	Net.claimed_vehicles[v.vid] = Net.local_id()
	world._on_vehicle_claimed(v.vid, Net.local_id())
	check(player.vehicle == null and not Net.claimed_vehicles.has(v.vid),
		"a late grant after timeout releases its seat instead of mounting or orphaning the claim")
	world._pending_vehicle_entry = v.vid
	world._pending_vehicle_entry_started_msec = Time.get_ticks_msec()
	Net.active = true
	player.admin_teleport(v.interaction_position() + Vector3.RIGHT * 30)
	world._update_pending_vehicle_entry()
	check(world._pending_vehicle_entry.is_empty(), "walking away cancels local seat interest")
	Net.active = false
	Net.claimed_vehicles[v.vid] = Net.local_id()
	world._on_vehicle_claimed(v.vid, Net.local_id())
	check(player.vehicle == null and not Net.claimed_vehicles.has(v.vid),
		"a late grant cannot teleport a player back to a vehicle")
	player.admin_teleport(v.interaction_position())
	world._pending_vehicle_entry = v.vid
	world._pending_vehicle_entry_started_msec = Time.get_ticks_msec()
	world._on_vehicle_claimed(v.vid, 42)
	check(world._pending_vehicle_entry.is_empty() and player.supply_notice.contains("Another player"),
		"losing a seat race clears pending state immediately")
	v.set_remote_controlled(false)
	world._pending_vehicle_entry = v.vid
	world._pending_vehicle_entry_request_id = 12
	Net.vehicle_request_finished.emit(v.vid, false, "An earlier request was rejected.", 11)
	check(world._pending_vehicle_entry == v.vid, "a delayed denial for the previous same-seat request cannot cancel a newer retry")
	Net.vehicle_request_finished.emit(v.vid, false, "Move closer to the vehicle and try again.", 12)
	check(world._pending_vehicle_entry.is_empty() and player.supply_notice.begins_with("Move closer"),
		"authority denial signal clears pending entry and explains the rejected request")
	world._pending_vehicle_entry = v.vid
	world._pending_vehicle_entry_started_msec = Time.get_ticks_msec()
	Net.claimed_vehicles[v.vid] = Net.local_id()
	world._on_vehicle_claimed(v.vid, Net.local_id())
	check(player.vehicle == v and v.driver == player and world._pending_vehicle_entry.is_empty(),
		"an on-time grant mounts the real player into the real vehicle")
	player.exit_vehicle()
	Net._apply_vehicle_release(v.vid, [])
	controller._pending_actions[123] = {"item": "banana"}
	controller._pending_started_at = Time.get_ticks_msec() - 120
	check(controller.action_pending() and controller.action_elapsed_ms() >= 120, "pending shared action exposes elapsed time without predicting a trade")
	controller._on_shared_result(123, "buy", {"ok": false, "message": "Fixture denied"})
	check(not controller.action_pending() and controller.action_elapsed_ms() == 0 and controller.last_message == "Fixture denied",
		"received action results immediately clear pending feedback")
	main._return_to_main_menu()
	await get_tree().process_frame
	await get_tree().process_frame
	print("RESPONSIVENESSTEST %d/%d %s" % [passed, total, "PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
