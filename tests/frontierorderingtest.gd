extends SceneTree
## Deliberately reorder reliable bulk views and priority action-result patches.
## Pure disposable ledgers; no live server, world rendering, or career writes.
var checks := 0
var passed := 0
var incoherent_signal := false
var expected_wallet := -1
var expected_water := -1

class IdentitySource extends Node:
	var _peer_key_fingerprints: Dictionary = {}
	var names: Dictionary = {7:"Alice"}
	var active := false
	var is_host := false
	func local_id() -> int: return 7

func _initialize() -> void:
	create_timer(20).timeout.connect(func(): push_error("FRONTIERORDERING deadline"); quit(2))
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	checks += 1
	if ok: passed += 1
	print("FRONTIERORDERING ", "PASS " if ok else "FAIL ", message)

func _run() -> void:
	var network_script = load("res://scripts/frontier_network.gd")
	var domain = load("res://scripts/frontier_societies.gd").new()
	var alice := "a".repeat(64)
	var bob := "b".repeat(64)
	domain.new_game(2026)
	domain.ensure_player(alice, "Alice")
	domain.ensure_player(bob, "Bob")
	var authority: Node = network_script.new()
	var identity := IdentitySource.new()
	identity._peer_key_fingerprints[7] = alice
	root.add_child(identity)
	identity.add_child(authority)
	authority.societies = domain
	var client: Node = network_script.new()
	root.add_child(client)
	var original_towns: Array = domain.towns(alice)
	var old_canopy: Dictionary = domain.view(alice, "canopy_earth")
	var old_harbor: Dictionary = domain.view(alice, "harbor_earth")
	var old_moon: Dictionary = domain.view(alice, "canopy_moon")
	client._apply_view("canopy_earth", 10, old_canopy.duplicate(true), original_towns)
	var payload := {"market":"earth_market", "item":"water", "quantity":1}
	var result: Dictionary = domain.action(alice, "canopy_earth", "buy", payload)
	authority._sequence = 19
	var record: Dictionary = authority._action_patch(7, "canopy_earth", "buy", payload, result)
	_check(bool(result.get("ok", false)) and int(record.get("revision", -1)) == 20,
		"fixture obtains a real successful personalized buy patch")
	var current: Dictionary = domain.view(alice, "canopy_earth")
	expected_wallet = int(current.accounts.player)
	expected_water = int(current.inventories.player_earth.water)
	client.state_changed.connect(func(_town: String):
		for view: Dictionary in client.views.values():
			if int(view.accounts.player) != expected_wallet or int(view.inventories.player_earth.water) != expected_water:
				incoherent_signal = true)
	client._apply_action_patch("canopy_earth", 20, record.patch)
	_check(client.views.canopy_earth.accounts.player == expected_wallet
		and client.views.canopy_earth.inventories.player_earth.water == expected_water,
		"priority action immediately installs authoritative wallet and bag")
	client._apply_view("harbor_earth", 11, old_harbor.duplicate(true), original_towns)
	_check(client.views.has("harbor_earth") and client._view_sequences.harbor_earth == 11,
		"an older bootstrap for another town still initializes that town")
	_check(client.views.harbor_earth.accounts.player == expected_wallet
		and client.views.harbor_earth.inventories.player_earth.water == expected_water,
		"newly bootstrapped Earth town receives the newer shared wallet and bag")
	_check(client.views.harbor_earth.inventories.earth_market == old_harbor.inventories.earth_market,
		"shared reconciliation does not copy another town's municipal market stock")
	client._apply_view("canopy_moon", 12, old_moon.duplicate(true), original_towns)
	_check(client.views.canopy_moon.inventories.player_earth.water == expected_water
		and client.views.canopy_moon.inventories.player_moon == old_moon.inventories.player_moon,
		"Earth and Moon aliases stay distinct while shared copies stay current")
	client._apply_view("canopy_earth", 19, old_canopy.duplicate(true), original_towns)
	_check(client._view_sequences.canopy_earth == 20 and client.views.canopy_earth.accounts.player == expected_wallet,
		"older bulk data for the patched town cannot undo a completed action")
	_check(not incoherent_signal, "observers never see partially reconciled cached wallets or bags")
	# A newer local revision must not prevent a lower revision for a different
	# town from applying its municipal records, while preserving global aliases.
	client._apply_view("harbor_earth", 30, domain.view(alice, "harbor_earth"), domain.towns(alice))
	var earlier_patch: Dictionary = record.patch.duplicate(true)
	earlier_patch.inventories.earth_market.water = 17
	earlier_patch.accounts.player = 123
	earlier_patch.inventories.player_earth.water = 2
	client._apply_action_patch("canopy_earth", 25, earlier_patch)
	_check(client._view_sequences.canopy_earth == 25 and client.views.canopy_earth.inventories.earth_market.water == 17,
		"town revisions advance independently across channels")
	_check(client.views.canopy_earth.accounts.player == expected_wallet and client.views.canopy_earth.inventories.player_earth.water == expected_water,
		"a lower global patch cannot replace newer shared player aliases")
	# Claim changes use their own global catalog revision, rather than whichever
	# town bootstrap happens to arrive last.
	result = domain.action(alice, "canopy_earth", "claim_town", {})
	authority._sequence = 39
	record = authority._action_patch(7, "canopy_earth", "claim_town", {}, result)
	current = domain.view(alice, "canopy_earth")
	expected_wallet = int(current.accounts.player)
	client._apply_action_patch("canopy_earth", 40, record.patch)
	client._apply_view("ridge_earth", 35, domain.view(alice, "ridge_earth"), original_towns)
	_check(client.town_info("canopy_earth").is_owner and client._catalog_sequence == 40,
		"an older different-town bootstrap cannot roll back a claimed catalog")
	_check(client.views.harbor_earth.claimed_town == "canopy_earth" and not client.views.harbor_earth.permissions.claim,
		"claim status and one-town eligibility update across cached towns")
	_check(not incoherent_signal, "claim observers receive coherent wallets and claim metadata")
	var private_before: Dictionary = domain.export_state()
	client.views.harbor_earth.inventories.player_earth.water = 9999
	_check(client.views.canopy_earth.inventories.player_earth.water != 9999 and domain.export_state() == private_before,
		"cached bag copies are detached from each other and the authority")
	var serialized := JSON.stringify(record.patch)
	_check(not serialized.contains("member_") and not serialized.contains(alice) and not serialized.contains(bob),
		"action patches expose no resident identity, other wallet, or private inventory keys")
	_check(var_to_bytes(record.patch).size() <= authority.MAX_ACTION_PATCH_BYTES,
		"real personalized claim patch respects its 32 KiB budget")
	var snapshot: Dictionary = client.views.duplicate(true)
	var malformed: Dictionary = record.patch.duplicate(true)
	malformed.inventories.player_earth = 4
	client._apply_action_patch("canopy_earth", 41, malformed)
	_check(client.views == snapshot and client._view_sequences.canopy_earth == 40,
		"malformed record shape is rejected without partial mutation or revision advance")
	var oversized: Dictionary = record.patch.duplicate(true)
	oversized.extra = "x".repeat(authority.MAX_ACTION_PATCH_BYTES)
	client._apply_action_patch("canopy_earth", 42, oversized)
	_check(client.views == snapshot and client._view_sequences.canopy_earth == 40,
		"oversized patch cannot mutate stock or poison revision ordering")
	var missing: Node = network_script.new()
	root.add_child(missing)
	missing._apply_action_patch("canopy_earth", 50, record.patch)
	missing._apply_view("canopy_earth", 45, domain.view(alice, "canopy_earth"), domain.towns(alice))
	_check(missing.views.has("canopy_earth") and missing._view_sequences.canopy_earth == 45,
		"a result before the first view cannot poison its later bootstrap")
	# Local authority registration has no remote application ACK. It must
	# synchronously bootstrap every town and remain safe when registration
	# repeats in the same process after a canceled entry attempt.
	authority.authoritative = true
	authority.society_ready = true
	authority.catalog = domain.towns()
	authority.register_peer(7)
	_check(authority.views.size() == 6 and authority._view_sequences.size() == 6,
		"local authority registration synchronously creates six personalized town views")
	_check(authority._bootstrap_views.is_empty() and authority._bootstrap_control.is_empty()
		and authority._view_in_flight.is_empty() and authority._pending_views.is_empty()
		and authority._priority_views.is_empty(),
		"local bootstrap creates no remote ACK, pending, or priority queue entries")
	var before_retry: Dictionary = domain.export_state()
	var before_revisions: Dictionary = authority._view_sequences.duplicate()
	authority.register_peer(7)
	var refreshed: bool = authority.views.size() == 6
	for town_id in before_revisions:
		refreshed = refreshed and int(authority._view_sequences.get(town_id, -1)) > int(before_revisions[town_id])
	_check(refreshed and domain.export_state() == before_retry,
		"local registration retry refreshes all six views without regranting money or goods")
	_check(authority._bootstrap_views.is_empty() and authority._view_in_flight.is_empty(),
		"same-process local registration retry cannot stall behind a missing remote ACK")
	client.stop()
	_check(client._view_sequences.is_empty() and client._shared_sequences.is_empty()
		and client._shared_player.is_empty() and client._catalog_sequence == -1,
		"disconnect clears town, catalog and shared-player revision state")
	client.free()
	missing.free()
	identity.free()
	print("FRONTIERORDERINGTEST %d/%d %s" % [passed, checks, "PASS" if passed == checks else "FAIL"])
	quit(0 if passed == checks else 1)
