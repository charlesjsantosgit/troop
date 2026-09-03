extends Node
## Headless lifecycle regression: duplicate clicks and stale async continuations
## must never create two worlds or shut down a replacement connection.

signal probe_ready

var passed := 0
var total := 0


func run(main: Node) -> void:
	if DisplayServer.get_name() != "headless":
		push_error("JOINCANCELLATIONTEST must run headlessly")
		get_tree().quit(1)
		return
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name",
		"TROOP-join-cancel-" + Crypto.new().generate_random_bytes(8).hex_encode())
	main._show_menu()
	main.mode = "join"
	main._join_in_progress = true
	main._join_attempt += 1
	var attempt: int = main._join_attempt
	var epoch: int = Net._session_epoch
	main._begin_join("127.0.0.1", "DuplicateProbe", 30623)
	_check(main._join_attempt == attempt and Net._session_epoch == epoch,
		"a duplicate begin does not replace the connection or start another load")
	main._set_join_button_busy(true)
	_check(main._online_button.text == "CANCEL CONNECTION",
		"the live connection action becomes a cancel button")
	var offline_disabled := true
	for button in main._offline_buttons:
		offline_disabled = offline_disabled and button.disabled
	_check(offline_disabled, "offline actions cannot replace a half-built world")
	main.name_edit.text_submitted.emit("NoSecondWorld")
	_check(main.mode == "join" and main._join_attempt == attempt,
		"submitting the name cannot bypass disabled offline actions")
	var old_result: Array = []
	_capture_wait(main, attempt, old_result)
	var partial_world := World.new()
	partial_world.process_mode = Node.PROCESS_MODE_DISABLED
	main.add_child(partial_world)
	main.world = partial_world
	partial_world.begin_build()
	main._cancel_join()
	_check(main.world == null and partial_world.is_queued_for_deletion(),
		"cancel releases the partial world and clears the shared pointer")
	_check(not main._join_in_progress and main.mode == "menu" \
		and main._join_attempt != attempt, "cancel invalidates the old attempt")
	await get_tree().process_frame
	_check(old_result == [false], "cancel wakes the old handshake waiter")
	_check(not is_instance_valid(partial_world), "partial world is freed")

	main.mode = "join"
	main._join_in_progress = true
	main._join_attempt += 1
	var replacement_attempt: int = main._join_attempt
	var replacement_result: Array = []
	_capture_wait(main, replacement_attempt, replacement_result)
	probe_ready.emit()
	await get_tree().process_frame
	_check(replacement_result == [true], "a replacement receives its own handshake")
	_check(old_result == [false] and main._join_attempt == replacement_attempt,
		"a later handshake cannot revive the canceled continuation")
	main._cancel_join()
	# Exercise the real suspended build, not just the handshake or a manually
	# created World. The next frame must accept its previously freed reference.
	main.mode = "join"
	main._join_in_progress = true
	main._join_attempt += 1
	Net.active = true
	var entry_result: Array = []
	_capture_entry(main, main._join_attempt, entry_result)
	while not is_instance_valid(main.world):
		await get_tree().process_frame
	var canceled_entry: Variant = main.world
	main._cancel_join()
	for frame in range(3):
		await get_tree().process_frame
	_check(not is_instance_valid(canceled_entry) and entry_result == [false],
		"a canceled real entry coroutine safely rejects its freed world")
	_check(main.world == null and main.expedition_manager == null,
		"the canceled entry cannot publish a world or expedition later")
	# Repeat cancellation once each large subsystem is already being built.
	# The replacement runs in this same process, so static shader/mesh caches
	# and old signal connections are exercised too. No network port is opened.
	for phase_prefix in ["moon_vertex_rows", "rocket_exterior_batch"]:
		var late_result: Array = []
		_start_fixture_entry(main, late_result)
		var reached := false
		for frame in range(2000):
			await get_tree().process_frame
			if is_instance_valid(main.expedition_manager) \
					and main.expedition_manager.configuration_stage_name().begins_with(phase_prefix):
				reached = true
				break
			if not late_result.is_empty():
				break
		_check(reached, "entry reaches " + phase_prefix + " before cancellation")
		var late_world: Variant = main.world
		var late_expedition: Variant = main.expedition_manager
		main._cancel_join()
		for frame in range(3):
			await get_tree().process_frame
		_check(late_result == [false] and not is_instance_valid(late_world) \
			and not is_instance_valid(late_expedition) and main.hud == null,
			"cancel during " + phase_prefix + " releases every partial subsystem")
	var retry_result: Array = []
	_start_fixture_entry(main, retry_result)
	var injected_latest_state := false
	for frame in range(2000):
		await get_tree().process_frame
		if not injected_latest_state and is_instance_valid(main.expedition_manager) \
				and main.expedition_manager.is_configuration_complete():
			injected_latest_state = true
			var expedition: ExpeditionManager = main.expedition_manager
			_check(not Net.expedition_state_changed.is_connected(expedition._apply_authoritative_state) \
				and not Net.player_realm_changed.is_connected(expedition._on_player_realm_changed),
				"live expedition callbacks remain detached until final entry activation")
			Net.rocket_state.phase = Net.RocketMissionPhase.MOON_READY
			Net.rocket_state.serial = int(Net.rocket_state.serial) + 1
			Net.player_realms[Net.local_id()] = Net.PlayerRealm.MOON
			Net.expedition_state_changed.emit(Net.expedition_state_snapshot())
			Net.player_realm_changed.emit(Net.local_id(), Net.PlayerRealm.MOON)
			_check(get_viewport().get_camera_3d() == main.world.get_node("OnlineLoadingCamera"),
				"late realm and mission packets cannot steal the loading camera")
		if not retry_result.is_empty():
			break
	_check(retry_result == [true] and is_instance_valid(main.world) \
		and main.world.is_build_complete() and main.expedition_manager.is_configuration_complete(),
		"same-process retry completes after both Moon and rocket cancellations")
	_check(injected_latest_state and main.expedition_manager._local_realm == Net.PlayerRealm.MOON \
		and main.expedition_manager.rocket.state == LunarRocket.State.LANDED_MOON \
		and main.expedition_manager.moon_world.visible \
		and Net.player_realm_changed.is_connected(main.expedition_manager._on_player_realm_changed),
		"final activation adopts the latest realm and mission and enables live callbacks")
	main._cancel_join()
	for frame in range(3):
		await get_tree().process_frame
	print("JOINCANCELLATIONTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)


func _start_fixture_entry(main: Node, output: Array) -> void:
	Net.solo("CancellationFixture", 20260805)
	# The offline peer supplies a valid local identity for the online build
	# guard without opening sockets, registering remotely or writing real saves.
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	Net.active = true
	main.mode = "join"
	main._join_in_progress = true
	main._join_attempt += 1
	_capture_entry(main, main._join_attempt, output)


func _capture_wait(main: Node, attempt: int, output: Array) -> void:
	var result: bool = await main._await_join_or_timeout(probe_ready, 1.0, attempt)
	output.append(result)


func _capture_entry(main: Node, attempt: int, output: Array) -> void:
	var result: bool = await main._enter_online_world("CanceledEntry", 20260805, attempt)
	output.append(result)


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
	print("  [%s] %s" % ["ok" if condition else "FAIL", label])
