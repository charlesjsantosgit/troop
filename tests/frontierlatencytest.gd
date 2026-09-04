extends SceneTree
## One real client and dedicated authority through run_frontier_latency.py's
## delayed, lossy and bandwidth-limited UDP relay.

const ACTION_COUNT := 6
var net: Node
var service: Node
var role := ""
var port := 0
var folder := ""
var replies: Dictionary = {}
var reply_times: Dictionary = {}
var state_changes := 0
var observed_view_revisions: Dictionary = {}
var protected_water := -1
var inventory_regressed := false
var deadline := 0
var finished := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 3:
		quit(2)
		return
	role = str(args[0])
	port = int(args[1])
	folder = str(args[2])
	if role not in ["server", "client"] or not folder.is_absolute_path() \
			or not folder.get_file().begins_with("troop-frontier-latency-"):
		quit(2)
		return
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name",
		folder.get_file() + "-" + role)
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	for variable in ["TROOP_ADMIN_KEY", "TROOP_ADMIN_TOKEN", "TROOP_STATE_DIR"]:
		OS.unset_environment(variable)
	net = root.get_node("Net")
	deadline = Time.get_ticks_msec() + 45000
	if role == "server":
		OS.set_environment("TROOP_STATE_DIR", folder.path_join("state"))
		if net.start_dedicated(2026, port, "127.0.0.1") != OK:
			_finish(false, {})
			return
		service = net.frontier_network
		print("FRONTIERLATENCY_SERVER_READY")
		while not FileAccess.file_exists(folder.path_join("stop")) \
				and Time.get_ticks_msec() < deadline:
			await process_frame
		net.shutdown()
		print("FRONTIERLATENCY_SERVER PASS")
		quit(0)
		return
	if net.join("127.0.0.1", "Latency resident", port) != OK:
		_finish(false, {})
		return
	service = net.frontier_network
	service.action_finished.connect(func(serial: int, _kind: String, result: Dictionary):
		replies[serial] = result
		reply_times[serial] = Time.get_ticks_msec())
	service.state_changed.connect(_on_state_changed)
	while service.views.size() < 6 and Time.get_ticks_msec() < deadline:
		await process_frame
	if service.views.size() != 6:
		_finish(false, {"reason":"bootstrap", "views":service.views.size()})
		return
	# A watch requested before the player reaches the next town is rejected by
	# proximity. The client must retry instead of caching that unacknowledged
	# request forever.
	await _position(Vector3(0.0, 4.05, -15.0))
	service.watch_town("harbor_earth")
	await create_timer(1.1).timeout
	var watch_rejected: bool = service._client_watch == "canopy_earth" \
		and service._client_watch_requested == "harbor_earth"
	await _position(Vector3(650.0, 4.05, -15.0))
	var harbor_confirmed: bool = await _wait_watch("harbor_earth", 5000)
	await _position(Vector3(120.0, 4.05, -35.0))
	var canopy_confirmed: bool = await _wait_watch("canopy_earth", 5000)
	if not watch_rejected or not harbor_confirmed or not canopy_confirmed:
		_finish(false, {"reason":"watch retry", "rejected":watch_rejected,
			"harbor":harbor_confirmed, "canopy":canopy_confirmed})
		return
	_write_marker("stress-ready")
	await create_timer(0.2).timeout
	var action_ms: Array[int] = []
	var changes_before: int = state_changes
	for _index in range(ACTION_COUNT):
		# This is the real controller cadence that used to request a redundant
		# full view immediately before each small action.
		service.watch_town("canopy_earth")
		var began := Time.get_ticks_msec()
		var pending: Dictionary = service.request_action("canopy_earth", "inspect",
			{"target":"oil_rig", "source":"oil_rig"})
		if not pending.get("pending", false):
			_finish(false, {"reason":"request"})
			return
		var serial := int(pending.request)
		while not replies.has(serial) and Time.get_ticks_msec() < began + 8000:
			await process_frame
		if not replies.has(serial) or not bool(replies[serial].get("ok", false)):
			_finish(false, {"reason":"action", "serial":serial,
				"received":replies.has(serial), "reply":replies.get(serial, {})})
			return
		action_ms.append(int(reply_times[serial]) - began)
		await create_timer(0.35).timeout
	# A real mutating market action must acknowledge quickly and its complete
	# authoritative inventory view must follow without an unbounded queue.
	await _position(Vector3(0.0, 4.05, -15.0))
	var water_before := int(service.views.canopy_earth.inventories.player_earth.get("water", 0))
	var trade_began := Time.get_ticks_msec()
	var trade_pending: Dictionary = service.request_action("canopy_earth", "buy",
		{"market":"earth_market", "item":"water", "quantity":1,
			"source":"earth_market"})
	var trade_serial := int(trade_pending.get("request", 0))
	while not replies.has(trade_serial) and Time.get_ticks_msec() < trade_began + 8000:
		await process_frame
	var trade_result_ms := int(reply_times.get(trade_serial, 0)) - trade_began
	while int(service.views.canopy_earth.inventories.player_earth.get("water", 0)) \
			!= water_before + 1 and Time.get_ticks_msec() < trade_began + 8000:
		await process_frame
	var trade_view_ms := Time.get_ticks_msec() - trade_began
	var trade_ok := replies.has(trade_serial) \
		and bool(replies[trade_serial].get("ok", false)) \
		and int(service.views.canopy_earth.inventories.player_earth.get("water", 0)) \
			== water_before + 1
	if trade_ok:
		protected_water = water_before + 1
	# A first claim has to durably register its fuel tank. The seat reply must
	# remain responsive even while town state is flowing on the bulk lane.
	var definition: Dictionary = root.get_node("Gen").vehicle_definition_by_id("v:pool#bike")
	if definition.is_empty():
		_finish(false, {"reason":"vehicle definition"})
		return
	var vehicle_position: Vector3 = definition.pos
	await _position(vehicle_position + Vector3(1.0, 0.0, 0.0))
	var claimed := {"done":false, "at":0}
	var vehicle_results := {}
	var on_claim := func(vehicle_id: String, claimant_id: int):
		if vehicle_id == "v:pool#bike" and claimant_id == net.local_id():
			claimed.done = true
			claimed.at = Time.get_ticks_msec()
	var on_vehicle_result := func(vehicle_id: String, accepted: bool,
			reason: String, request_id: int):
		vehicle_results[request_id] = {"vehicle":vehicle_id,
			"accepted":accepted, "reason":reason, "at":Time.get_ticks_msec()}
	net.vehicle_claimed.connect(on_claim)
	net.vehicle_request_finished.connect(on_vehicle_result)
	var vehicle_began := Time.get_ticks_msec()
	var requested: bool = net.request_vehicle("v:pool#bike", 41)
	while requested and (not claimed.done or not vehicle_results.has(41)) \
			and Time.get_ticks_msec() < vehicle_began + 8000:
		await process_frame
	if net.vehicle_claimed.is_connected(on_claim):
		net.vehicle_claimed.disconnect(on_claim)
	# A second seat request while driving has no accepted on-foot position. It
	# must receive a correlated denial rather than leaving the UI pending.
	var denied_began := Time.get_ticks_msec()
	var denied_sent: bool = net.request_vehicle("v:pool#jeep", 42)
	while denied_sent and not vehicle_results.has(42) \
			and Time.get_ticks_msec() < denied_began + 5000:
		await process_frame
	if net.vehicle_request_finished.is_connected(on_vehicle_result):
		net.vehicle_request_finished.disconnect(on_vehicle_result)
	# Leave enough time for the pre-action bulk view to arrive. Its lower
	# revision must never roll the immediately patched inventory backward.
	await create_timer(2.5).timeout
	var accepted_reply: Dictionary = vehicle_results.get(41, {})
	var denied_reply: Dictionary = vehicle_results.get(42, {})
	var sorted := action_ms.duplicate()
	sorted.sort()
	var result := {
		"ok":trade_ok and not inventory_regressed and requested and claimed.done \
			and bool(accepted_reply.get("accepted", false))
			and denied_sent and not denied_reply.is_empty()
			and not bool(denied_reply.get("accepted", true))
			and int(denied_reply.get("at", 0)) >= denied_began,
		"action_ms":action_ms,
		"action_median_ms":sorted[sorted.size()/2],
		"action_max_ms":sorted[-1],
		"trade_result_ms":trade_result_ms,
		"trade_view_ms":trade_view_ms,
		"vehicle_ms":int(claimed.at)-vehicle_began if claimed.done else -1,
		"vehicle_result_ms":int(accepted_reply.get("at", 0))-vehicle_began
			if not accepted_reply.is_empty() else -1,
		"denial_ms":int(denied_reply.get("at", 0))-denied_began
			if not denied_reply.is_empty() else -1,
		"denial_reason":str(denied_reply.get("reason", "")),
		"inventory_regressed":inventory_regressed,
		"watch_retry":watch_rejected and harbor_confirmed and canopy_confirmed,
		"state_views_during":state_changes-changes_before,
		"views":service.views.size(),
	}
	_finish(bool(result.ok), result)


func _on_state_changed(town_id: String) -> void:
	# Shared wallet/bag reconciliation can notify several cached towns for one
	# received message. Count only a town revision advance, not alias fan-out.
	var revision := int(service._view_sequences.get(town_id, -1))
	if revision > int(observed_view_revisions.get(town_id, -1)):
		observed_view_revisions[town_id] = revision
		state_changes += 1
	if protected_water >= 0 and service.views.has("canopy_earth"):
		var current := int(service.views.canopy_earth.inventories.player_earth.get(
			"water", -1))
		if current != protected_water:
			inventory_regressed = true


func _wait_watch(town_id: String, timeout_msec: int) -> bool:
	var end: int = Time.get_ticks_msec() + timeout_msec
	while service._client_watch != town_id and Time.get_ticks_msec() < end:
		service.watch_town(town_id)
		await create_timer(0.2).timeout
	return service._client_watch == town_id


func _position(point: Vector3) -> void:
	for _index in range(6):
		net.send_state(point, 0.0, Vector3.ZERO, 0, false, Vector3.ZERO, 0.0,
			PackedVector3Array(), net.WEAPON_REVOLVER, false, true, 6, false, 0.0)
		await create_timer(0.06).timeout


func _write_marker(name: String) -> void:
	var file := FileAccess.open(folder.path_join(name), FileAccess.WRITE)
	file.store_string("ready\n")
	file.close()


func _finish(ok: bool, result: Dictionary) -> void:
	if finished:
		return
	finished = true
	result["ok"] = ok
	print("FRONTIERLATENCY_RESULT " + JSON.stringify(result))
	if role == "client":
		net.shutdown()
	quit(0 if ok else 1)
