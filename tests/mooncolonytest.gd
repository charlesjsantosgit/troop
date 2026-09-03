extends Node
## Deterministic economy and authority regressions. Run after autoloads with
## -- mooncolonytest. This fixture never uses the player's colony save.

const TEST_SEED := 734_221
var passed := 0
var total := 0
var _request_serial := 0


class AuthorityActor:
	extends Node3D
	var vehicle: Node = null
	var fly_mode := false
	var health := 100.0


func run() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String, detail := "") -> void:
	total += 1
	passed += int(ok)
	print("[%s] %s%s" % ["PASS" if ok else "FAIL", label,
		" :: " + detail if not detail.is_empty() else ""])


func _fresh(balance := 12) -> Dictionary:
	return {"model": MoonColony.new(TEST_SEED), "balance": balance}


func _act(session: Dictionary, action: String, target := 0) -> Dictionary:
	var result: Dictionary = session.model.perform(action, target, int(session.balance))
	session.balance = int(result.get("balance", session.balance))
	return result


func _snapshot(session: Dictionary) -> Dictionary:
	return session.model.snapshot(int(session.balance))


func _rejected_without_change(session: Dictionary, action: String, target := 0) -> bool:
	var before: Dictionary = session.model.serialize(int(session.balance)).duplicate(true)
	var result := _act(session, action, target)
	return not bool(result.get("ok", false)) \
		and before == session.model.serialize(int(session.balance))


func _produce_fresh(session: Dictionary, minimum: int) -> bool:
	# Drive the real crop clock; never insert cargo or mark a crop ready by hand.
	for _cycle in range(30):
		var state := _snapshot(session)
		if int(state.cargo.fresh) >= minimum:
			return true
		var bed: Dictionary = state.plots[0]
		if bool(bed.ready):
			if not bool(_act(session, "harvest", 0).get("ok", false)):
				return false
		else:
			if not bool(bed.planted) \
					and not bool(_act(session, "plant", 0).get("ok", false)):
				return false
			session.model.advance(float(state.growth_seconds) + 0.001)
	return false


func _run() -> void:
	print("MOON COLONY TEST")
	_test_crops_and_sales()
	_test_aging()
	_test_upgrades_and_helper()
	_test_contracts_and_surveys()
	_test_serialization()
	await _test_authority_and_storage()
	print("MOONCOLONYTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)


func _test_crops_and_sales() -> void:
	var session := _fresh()
	var initial := _snapshot(session)
	var unlocked := 0
	var ripe := 0
	for bed in initial.plots:
		unlocked += int(bool(bed.unlocked))
		ripe += int(bool(bed.ready))
	_check(unlocked == 4 and ripe == 2 and int(initial.cargo.fresh) == 0 \
		and int(initial.cargo.aged) == 0 and int(session.balance) == 12,
		"new colony has four usable beds, two starter harvests and no fabricated cargo")
	_check(_rejected_without_change(session, "plant", 0),
		"planting over a ripe crop cannot erase or duplicate the harvest")
	var harvest := _act(session, "harvest", 0)
	_check(bool(harvest.ok) and int(_snapshot(session).cargo.fresh) == 3 \
		and int(session.balance) == 12 and not bool(_snapshot(session).plots[0].planted),
		"manual harvest moves three fresh cheese into cargo and leaves an empty bed")
	_check(_rejected_without_change(session, "harvest", 0),
		"the same ripe crop cannot be harvested twice")
	_check(bool(_act(session, "plant", 0).ok) and bool(_act(session, "tend", 0).ok) \
		and is_equal_approx(float(_snapshot(session).plots[0].remaining), 33.0) \
		and int(session.balance) == 12,
		"free planting and one tending action shorten a 45-second crop by 12 seconds")
	_check(_rejected_without_change(session, "tend", 0),
		"repeated tending cannot stack growth boosts on one crop")
	session.model.advance(32.99)
	_check(not bool(_snapshot(session).plots[0].ready) \
		and _rejected_without_change(session, "harvest", 0),
		"crop cannot be harvested just before its maturity boundary")
	session.model.advance(0.02)
	_check(bool(_snapshot(session).plots[0].ready) \
		and bool(_act(session, "harvest", 0).ok) \
		and int(_snapshot(session).cargo.fresh) == 6,
		"crop matures at the clock boundary and produces exactly one new harvest")
	_check(bool(_act(session, "sell_fresh", 2).ok) \
		and int(session.balance) == 16 and int(_snapshot(session).cargo.fresh) == 4,
		"partial fresh sale removes exactly two cargo and pays four bananas")
	_check(_rejected_without_change(session, "sell_fresh", 5),
		"overselling preserves both cargo and balance")
	_check(bool(_act(session, "sell_fresh", 0).ok) \
		and int(session.balance) == 24 and int(_snapshot(session).cargo.fresh) == 0,
		"sell-all consumes the remaining cargo and pays its exact value")
	_check(_rejected_without_change(session, "sell_fresh", 0),
		"repeating sell-all cannot pay out the same cargo twice")
	var invalid_clock_safe := true
	for delta in [-1.0, NAN, INF, -INF, 3601.0]:
		var before: Dictionary = session.model.serialize(int(session.balance)).duplicate(true)
		session.model.advance(delta)
		invalid_clock_safe = invalid_clock_safe \
			and before == session.model.serialize(int(session.balance))
	_check(invalid_clock_safe, "negative and nonfinite clock deltas cannot change colony state")
	var invalid_actions_safe := true
	for command in [["plant", -1], ["harvest", 999], ["sell_fresh", -1],
		["sell_aged", -1], ["mint", 0], ["upgrade", 99], ["discover", 99]]:
		invalid_actions_safe = _rejected_without_change(session, str(command[0]), int(command[1])) \
			and invalid_actions_safe
	_check(invalid_actions_safe, "unknown actions and invalid targets cannot mint resources or mutate plots")


func _test_aging() -> void:
	var session := _fresh()
	_check(_produce_fresh(session, 12), "aging inputs come from actual crop cycles")
	for _batch in range(3):
		_act(session, "age", 0)
	_check(int(_snapshot(session).cargo.fresh) == 3 and int(_snapshot(session).cargo.aged) == 0 \
		and int(session.balance) == 12,
		"three aging batches reserve nine fresh cheese without charging bananas or granting early output")
	_check(_rejected_without_change(session, "age", 0),
		"aging cellar rejects a fourth concurrent batch even with enough input")
	session.model.advance(49.99)
	_check(int(_snapshot(session).cargo.aged) == 0,
		"aging output cannot be claimed before its 50-second deadline")
	session.model.advance(0.02)
	_check(int(_snapshot(session).cargo.aged) == 6 and int(_snapshot(session).cargo.fresh) == 3,
		"each finished batch consumes three fresh and produces exactly two aged cheese")
	session.model.advance(100.0)
	_check(int(_snapshot(session).cargo.aged) == 6,
		"finished aging batches do not emit their output again on later ticks")
	_check(bool(_act(session, "sell_aged", 2).ok) and int(session.balance) == 24 \
		and int(_snapshot(session).cargo.aged) == 4,
		"partial aged sale pays six bananas per cheese")
	_check(bool(_act(session, "sell_aged", 0).ok) and int(session.balance) == 48 \
		and int(_snapshot(session).cargo.aged) == 0 \
		and _rejected_without_change(session, "sell_aged", 0),
		"aged sell-all consumes the rest once and cannot duplicate proceeds")
	var empty := _fresh()
	_check(_rejected_without_change(empty, "age", 0),
		"cellar without three carried fresh cheese cannot start a batch")


func _test_upgrades_and_helper() -> void:
	var poor := _fresh(0)
	_check(_rejected_without_change(poor, "upgrade", 0),
		"unaffordable upgrades preserve balance and farm capabilities")
	_check(_rejected_without_change(poor, "plant", 4),
		"locked beds cannot grow crops before their expansion is purchased")
	var session := _fresh(500)
	var maxed_once := true
	for upgrade_id in range(4):
		var levels: int = [2, 2, 2, 1][upgrade_id]
		for _level in range(levels):
			maxed_once = bool(_act(session, "upgrade", upgrade_id).ok) and maxed_once
		maxed_once = _rejected_without_change(session, "upgrade", upgrade_id) and maxed_once
	var upgraded := _snapshot(session)
	_check(maxed_once and int(session.balance) == 380 \
		and upgraded.upgrades == {"yield": 2, "growth": 2, "plots": 2, "helper": 1},
		"all seven upgrade purchases cost exactly 120 bananas and stop at their level caps")
	var all_unlocked := true
	for bed in upgraded.plots:
		all_unlocked = all_unlocked and bool(bed.unlocked)
	_check(all_unlocked and upgraded.plots.size() == 6 \
		and int(upgraded.harvest_yield) == 5 \
		and is_equal_approx(float(upgraded.growth_seconds), 31.5),
		"upgrades unlock six beds, five-wedge harvests and a bounded 30 percent growth reduction")
	session.model.advance(7.99)
	_check(int(_snapshot(session).cargo.fresh) == 0,
		"helper does not harvest before its eight-second work interval")
	session.model.advance(0.02)
	var helped := _snapshot(session)
	_check(int(helped.cargo.fresh) == 5 and bool(helped.plots[0].planted) \
		and not bool(helped.plots[0].ready) and bool(helped.helper.working),
		"helper harvests a real ripe crop and replants that same bed once")
	var coarse := _fresh(100)
	var fine := _fresh(100)
	_act(coarse, "upgrade", 3)
	_act(fine, "upgrade", 3)
	coarse.model.advance(125.5)
	for _step in range(1255):
		fine.model.advance(0.1)
	var coarse_state := _snapshot(coarse)
	var fine_state := _snapshot(fine)
	var equivalent: bool = coarse_state.cargo == fine_state.cargo \
		and coarse_state.stats == fine_state.stats \
		and coarse_state.helper == fine_state.helper
	for index in range(coarse_state.plots.size()):
		var a: Dictionary = coarse_state.plots[index]
		var b: Dictionary = fine_state.plots[index]
		equivalent = equivalent and a.planted == b.planted and a.ready == b.ready \
			and a.tended == b.tended and absf(float(a.remaining) - float(b.remaining)) < 0.001
	_check(equivalent, "helper work and crop yields are equivalent for long and frame-sized simulation steps")
	var full := _fresh()
	var full_record: Dictionary = full.model.serialize(int(full.balance))
	full_record.cargo.fresh = MoonColony.MAX_CARGO
	var full_restored: bool = full.model.restore(full_record)
	_check(full_restored and _rejected_without_change(full, "harvest", 0) \
		and bool(_snapshot(full).plots[0].ready),
		"full cargo rejects harvest without destroying the ripe crop")
	var rich := _fresh(MoonColony.MAX_BALANCE)
	_act(rich, "harvest", 0)
	_check(_rejected_without_change(rich, "sell_fresh", 0) \
		and _rejected_without_change(rich, "discover", 0),
		"balance cap rejects payouts without consuming cheese or one-time survey rewards")


func _test_contracts_and_surveys() -> void:
	var session := _fresh()
	_check(_rejected_without_change(session, "contract", 1),
		"later delivery orders stay locked until the preceding order is complete")
	_produce_fresh(session, 6)
	var before := _snapshot(session)
	_check(bool(_act(session, "contract", 0).ok) and int(session.balance) == 24 \
		and int(_snapshot(session).cargo.fresh) == int(before.cargo.fresh) - 4 \
		and bool(_snapshot(session).contracts[0].done),
		"first delivery consumes four fresh cheese and pays twelve bananas")
	_check(_rejected_without_change(session, "contract", 0) \
		and _rejected_without_change(session, "contract", 1),
		"completed or underfilled delivery requests cannot duplicate rewards")
	var second_inputs := _produce_fresh(session, 9)
	_act(session, "age", 0)
	session.model.advance(50.01)
	before = _snapshot(session)
	_check(second_inputs and bool(_act(session, "contract", 1).ok) \
		and int(session.balance) == 54 \
		and int(_snapshot(session).cargo.fresh) == int(before.cargo.fresh) - 6 \
		and int(_snapshot(session).cargo.aged) == int(before.cargo.aged) - 2,
		"second delivery consumes six fresh and two aged cheese for thirty bananas")
	var final_inputs := _produce_fresh(session, 17)
	for _batch in range(3):
		_act(session, "age", 0)
	session.model.advance(50.01)
	before = _snapshot(session)
	_check(final_inputs and bool(_act(session, "contract", 2).ok) \
		and int(session.balance) == 124 \
		and int(_snapshot(session).cargo.fresh) == int(before.cargo.fresh) - 8 \
		and int(_snapshot(session).cargo.aged) == int(before.cargo.aged) - 6 \
		and _rejected_without_change(session, "contract", 2),
		"final delivery exchanges eight fresh and six aged for seventy bananas exactly once")
	var surveys := _fresh()
	_check(_rejected_without_change(surveys, "refill", 2) \
		and _rejected_without_change(surveys, "refill", 3),
		"remote oxygen stations remain locked until their outposts are surveyed")
	var surveys_once := true
	for index in range(3):
		var balance_before := int(surveys.balance)
		surveys_once = bool(_act(surveys, "discover", index).ok) \
			and int(surveys.balance) - balance_before == [6, 8, 10][index] \
			and _rejected_without_change(surveys, "discover", index) and surveys_once
	_check(surveys_once and int(surveys.balance) == 36 \
		and bool(_snapshot(surveys).survey_perk) \
		and is_equal_approx(float(_snapshot(surveys).growth_seconds), 40.5),
		"three distinct surveys pay 6/8/10 once and unlock one permanent growth bonus")
	var survey_before: Dictionary = surveys.model.serialize(int(surveys.balance)).duplicate(true)
	_check(bool(_act(surveys, "refill", 2).ok) and bool(_act(surveys, "refill", 3).ok) \
		and survey_before == surveys.model.serialize(int(surveys.balance)),
		"discovered outpost refills do not manufacture currency or cargo")


func _test_serialization() -> void:
	var source := _fresh(100)
	_act(source, "harvest", 0)
	_act(source, "plant", 0)
	_act(source, "tend", 0)
	_act(source, "age", 0)
	_act(source, "upgrade", 1)
	_act(source, "discover", 0)
	source.model.advance(8.0)
	var saved: Dictionary = source.model.serialize(int(source.balance))
	var parsed: Variant = JSON.parse_string(JSON.stringify(saved))
	var restored := MoonColony.new(TEST_SEED)
	var restored_ok := parsed is Dictionary and restored.restore(parsed)
	_check(restored_ok and restored.restored_balance == int(source.balance) \
		and restored.serialize(restored.restored_balance) == saved,
		"JSON save roundtrip retains cargo, partial crop/aging timers, progression and balance")
	var public_copy := _snapshot(source)
	public_copy.cargo.fresh = 9999
	public_copy.plots[0].ready = true
	public_copy.upgrades.helper = 1
	_check(source.model.serialize(int(source.balance)) == saved,
		"UI snapshots are detached copies and cannot change authoritative colony state")
	var malformed: Array[Dictionary] = []
	var bad := saved.duplicate(true)
	bad.version = 999
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.seed = TEST_SEED + 1
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.balance = -1
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.cargo.fresh = MoonColony.MAX_CARGO + 1
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.cargo.aged = 0.5
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.upgrades.helper = 2
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.plots[0].grown = NAN
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.aging = [INF]
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.plots.resize(0)
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.contracts = [false, true, false]
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.discoveries = [1, false, false]
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.helper_remaining = 0.0
	malformed.append(bad)
	bad = saved.duplicate(true)
	bad.forged_reward = 1000000
	malformed.append(bad)
	var rejected_atomically := true
	for record in malformed:
		var before: Dictionary = restored.serialize(restored.restored_balance).duplicate(true)
		rejected_atomically = not restored.restore(record) \
			and before == restored.serialize(restored.restored_balance) and rejected_atomically
	_check(rejected_atomically,
		"malformed, cross-seed, nonfinite, oversized and impossible saves are rejected atomically",
		"%d malformed records" % malformed.size())
	var before_pause: Dictionary = restored.serialize(restored.restored_balance).duplicate(true)
	for _read in range(50):
		restored.snapshot(restored.restored_balance)
	_check(restored.serialize(restored.restored_balance) == before_pause,
		"reading snapshots or reloading saves does not simulate offline growth")


func _net_standing_position(action: String, target := 0) -> Vector3:
	var position := Net.colony_action_position(action, target)
	if action in ["sell_fresh", "sell_aged", "upgrade", "contract"]:
		position -= MoonWorld.surface_basis(MoonColony.action_direction(action, target)).z * 4.0
	return position


func _net_action(action: String, target := 0) -> bool:
	_request_serial += 1
	Net._rate_windows.clear()
	return Net._host_moon_colony_action(Net.local_id(), _request_serial, action, target)


func _net_rejected(action: String, target := 0) -> bool:
	var before := Net.moon_colony_snapshot()
	return not _net_action(action, target) and before == Net.moon_colony_snapshot()


func _test_authority_and_storage() -> void:
	var was_processing := Net.is_processing()
	Net.set_process(false)
	Net.solo("Colony authority fixture", TEST_SEED)
	Net.bind_moon_colony_player(null)
	_check(not Net._moon_colony_persistence_allowed(),
		"test entry disables reads and writes of the player's normal colony save")
	var peer := Net.local_id()
	Net.player_realms[peer] = Net.PlayerRealm.MOON
	var created := Net.ensure_moon_colony(peer, 999999)
	var ensured := Net.ensure_moon_colony(peer, 999999)
	_check(int(created.balance) == 12 and ensured == created,
		"authority caps starter currency and never grants it again when reopening the colony")
	Net._peer_on_foot_positions[peer] = _net_standing_position("harvest", 0)
	_check(_net_action("harvest", 0) and int(Net.moon_colony_snapshot().cargo.fresh) == 3,
		"authority accepts a valid on-foot harvest at the deterministic Moon plot")
	var handled_request := _request_serial
	var before := Net.moon_colony_snapshot()
	Net._rate_windows.clear()
	_check(not Net._host_moon_colony_action(peer, handled_request, "harvest", 1) \
		and not Net._host_moon_colony_action(peer, handled_request - 1, "harvest", 1) \
		and before == Net.moon_colony_snapshot(),
		"replayed and reordered request IDs cannot harvest another crop or duplicate cargo")
	Net.player_realms[peer] = Net.PlayerRealm.EARTH
	_check(_net_rejected("harvest", 1),
		"Earth realm cannot issue colony actions using a forged Moon position")
	Net.player_realms[peer] = Net.PlayerRealm.TRANSIT
	_check(_net_rejected("harvest", 1), "in-transit player cannot harvest or trade")
	Net.player_realms[peer] = Net.PlayerRealm.MOON
	Net._peer_on_foot_positions[peer] = _net_standing_position("harvest", 1) + Vector3(100, 0, 0)
	_check(_net_rejected("harvest", 1), "out-of-range plot request preserves cargo and crop")
	Net._peer_on_foot_positions[peer] = Vector3(NAN, Net.MOON_WORLD_ORIGIN_Y, 0)
	_check(_net_rejected("harvest", 1), "nonfinite actor coordinates cannot bypass interaction range")
	Net._peer_on_foot_positions[peer] = _net_standing_position("harvest", 1)
	Net.claimed_vehicles[881] = peer
	_check(_net_rejected("harvest", 1), "seated vehicle occupant cannot harvest remotely")
	Net.claimed_vehicles.clear()
	Net.rocket_state.crew = [peer]
	_check(_net_rejected("harvest", 1), "rocket crew cannot perform colony actions from the cabin")
	Net.rocket_state.crew = []
	var malformed_safe := true
	for request in [["mint", 0], ["sell_fresh", -4], ["age", 8], ["upgrade", 200]]:
		malformed_safe = _net_rejected(str(request[0]), int(request[1])) and malformed_safe
	_check(malformed_safe and not Net._host_moon_colony_action(99, 1, "harvest", 1),
		"forged actions, quantities, targets and unknown peers are rejected by authority")
	var actor := AuthorityActor.new()
	add_child(actor)
	actor.global_position = _net_standing_position("harvest", 1) + Vector3(30, 0, 0)
	Net.bind_moon_colony_player(actor)
	_check(_net_rejected("harvest", 1),
		"local authority refreshes the real actor position instead of trusting a stale nearby packet")
	actor.global_position = _net_standing_position("harvest", 1)
	actor.fly_mode = true
	var flight_denied := _net_rejected("harvest", 1)
	actor.fly_mode = false
	actor.health = 0.0
	var defeated_denied := _net_rejected("harvest", 1)
	actor.health = 100.0
	_check(flight_denied and defeated_denied,
		"flying and defeated local actors cannot use farm interactions")
	_check(_net_action("harvest", 1) and int(Net.moon_colony_snapshot().cargo.fresh) == 6,
		"live local actor harvest succeeds after returning to valid physical interaction range")
	actor.global_position = Net.colony_action_position("sell_fresh", 0) \
		+ MoonWorld.surface_basis(MoonColony.action_direction("sell_fresh")).z * 4.0
	_check(_net_rejected("sell_fresh", 0), "market transaction cannot pass through the shop's rear wall")
	actor.global_position = _net_standing_position("sell_fresh", 0)
	_check(_net_action("sell_fresh", 0) and int(Net.moon_colony_snapshot().balance) == 24 \
		and int(Net.moon_colony_snapshot().cargo.fresh) == 0,
		"physical market forecourt sale transfers six wedges into twelve authoritative bananas")
	_check(_net_action("upgrade", 1) and int(Net.moon_colony_snapshot().upgrades.growth) == 1 \
		and int(Net.moon_colony_snapshot().balance) == 14,
		"market upgrade buttons are authorized at the same counter where they are displayed")
	actor.global_position = _net_standing_position("plant", 0)
	_net_action("plant", 0)
	var remaining_before := float(Net.moon_colony_snapshot().plots[0].remaining)
	Net._process_moon_colonies(200.0)
	_check(is_equal_approx(remaining_before - float(Net.moon_colony_snapshot().plots[0].remaining), 1.0),
		"a long engine hitch advances colony growth by at most one simulation second")
	Net.set_offline_expedition_paused(true)
	before = Net.moon_colony_snapshot()
	Net._process_moon_colonies(1.0)
	_check(before == Net.moon_colony_snapshot() and _net_rejected("tend", 0),
		"offline pause freezes growth and rejects gameplay actions")
	Net.set_offline_expedition_paused(false)
	Net.player_realms[peer] = Net.PlayerRealm.EARTH
	before = Net.moon_colony_snapshot()
	Net._process_moon_colonies(1.0)
	_check(before == Net.moon_colony_snapshot(),
		"leaving the Moon stops that player's colony simulation")
	Net.player_realms[peer] = Net.PlayerRealm.MOON
	actor.global_position = _net_standing_position("refill", 0)
	Net._rate_windows.clear()
	var admitted := 0
	before = Net.moon_colony_snapshot()
	for _attempt in range(9):
		_request_serial += 1
		admitted += int(Net._host_moon_colony_action(peer, _request_serial, "refill", 0))
	_check(admitted == 8 and before == Net.moon_colony_snapshot(),
		"colony authority admits eight harmless requests per window and rejects the ninth")
	var test_root := "user://mooncolony_fixture_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	Net._moon_colony_storage_root = test_root
	Net._moon_colony_dirty = true
	var saved_ok := Net._save_offline_moon_colony()
	var path := Net.moon_colony_save_path()
	var loaded := MoonColony.new(TEST_SEED)
	var loaded_ok := Net._load_moon_colony(loaded)
	var expected: Dictionary = Net._moon_colonies[peer].serialize(int(Net.scores[peer]))
	_check(saved_ok and loaded_ok and loaded.serialize(loaded.restored_balance) == expected \
		and not FileAccess.file_exists(path + ".tmp"),
		"isolated disk save commits atomically and reloads the complete authoritative state")
	Net._moon_colonies.erase(peer)
	Net.scores[peer] = 7
	var returning := Net.ensure_moon_colony(peer)
	var reopened := Net.ensure_moon_colony(peer)
	_check(int(returning.balance) == int(expected.balance) + 7 \
		and returning.cargo == expected.cargo and reopened == returning,
		"first Moon visit adds new Earth earnings to saved balance exactly once without replacing saved cargo")
	var save_before: Dictionary = loaded.serialize(loaded.restored_balance).duplicate(true)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("{broken colony save")
	file.close()
	_check(not Net._load_moon_colony(loaded) \
		and loaded.serialize(loaded.restored_balance) == save_before,
		"corrupted JSON save leaves the previously loaded colony intact")
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(" ".repeat(65537))
	file.close()
	_check(not Net._load_moon_colony(loaded) \
		and loaded.serialize(loaded.restored_balance) == save_before,
		"oversized save is rejected before parsing or replacing progress")
	Net._moon_colony_storage_root = "user://moon_colonies"
	_check(not Net._moon_colony_persistence_allowed(),
		"test storage override cannot target the real player save directory")
	Net._moon_colony_storage_root = ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".tmp"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(test_root))
	Net.bind_moon_colony_player(null)
	actor.queue_free()
	Net.shutdown()
	Net.set_process(was_processing)
	await get_tree().process_frame
