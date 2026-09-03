extends SceneTree
## Roster/transport departure ordering and observer-state regression:
##   godot --headless --path . --quit-after 1200 --script res://tests/netrostertest.gd
## Only the authority-path check opens a socket, on ephemeral localhost.

const SELF_ID := 101
const REMOTE_ID := 202
const OTHER_ID := 303

var net: Node
var voice: Node
var passed := 0
var total := 0
var departed: Array[int] = []
var event_order: Array[String] = []
var observed_snapshots: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, label: String) -> void:
	total += 1
	passed += int(condition)
	print("  [%s] %s" % ["ok" if condition else "FAIL", label])


func _reset_observations() -> void:
	departed.clear()
	event_order.clear()
	observed_snapshots.clear()


func _install_client_snapshot() -> void:
	net.active = true
	net.is_host = false
	net.is_dedicated = false
	net._registered = {}
	net.names = {SELF_ID: "self", REMOTE_ID: "remote"}
	net.scores = {SELF_ID: 0, REMOTE_ID: 3}
	voice._muted_peers[REMOTE_ID] = true
	_reset_observations()


func _on_departed(peer_id: int) -> void:
	departed.append(peer_id)
	event_order.append("left:%d" % peer_id)
	observed_snapshots.append({"names": net.names.duplicate(),
		"scores": net.scores.duplicate()})


func _run() -> void:
	net = root.get_node("Net")
	voice = root.get_node("Voice")
	# Authority initialization reads grant/ban files; keep them out of every
	# real installation and ignore any dedicated-production state override.
	for variable in ["TROOP_ADMIN_KEY", "TROOP_ADMIN_TOKEN", "TROOP_STATE_DIR"]:
		OS.unset_environment(variable)
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name",
		"TROOP-net-roster-" + Crypto.new().generate_random_bytes(8).hex_encode())
	var directory_error := DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	_check(directory_error == OK or directory_error == ERR_ALREADY_EXISTS,
		"authority checks use a fresh isolated user directory")
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		_finish()
		return
	net.peer_left.connect(_on_departed)
	net.roster_changed.connect(func(): event_order.append("roster"))
	net.score_changed.connect(func(): event_order.append("score"))

	for roster_first in [false, true]:
		_install_client_snapshot()
		if roster_first:
			net.cl_roster({SELF_ID: "self"}, {SELF_ID: 7})
			net._on_peer_disconnected(REMOTE_ID)
		else:
			net._on_peer_disconnected(REMOTE_ID)
			net.cl_roster({SELF_ID: "self"}, {SELF_ID: 7})
		var label := "roster-first" if roster_first else "transport-first"
		_check(departed == [REMOTE_ID], "%s departure is delivered exactly once" % label)
		_check(net.names == {SELF_ID: "self"} and net.scores == {SELF_ID: 7},
			"%s leaves the authoritative roster and scores intact" % label)
		_check(observed_snapshots.size() == 1 \
			and not observed_snapshots[0].names.has(REMOTE_ID) \
			and not observed_snapshots[0].scores.has(REMOTE_ID),
			"%s departure observer sees the departed player already removed" % label)
		_check(not voice._muted_peers.has(REMOTE_ID),
			"%s reaches real Voice departure cleanup" % label)
		net.cl_roster({SELF_ID: "self"}, {SELF_ID: 7})
		net._on_peer_disconnected(REMOTE_ID)
		_check(departed == [REMOTE_ID], "%s repeated roster/transport stays idempotent" % label)

	_install_client_snapshot()
	var replacement_names := {SELF_ID: "renamed", OTHER_ID: "new arrival"}
	var replacement_scores := {SELF_ID: 12, OTHER_ID: 2}
	net.cl_roster(replacement_names, replacement_scores)
	_check(event_order == ["roster", "score", "left:202"],
		"roster and score notifications still precede snapshot-driven departures")
	_check(observed_snapshots.size() == 1 \
		and observed_snapshots[0].names == replacement_names \
		and observed_snapshots[0].scores == replacement_scores,
		"departure callbacks see the complete newly applied names and scores")
	_check(departed == [REMOTE_ID] and net.names.has(OTHER_ID),
		"adding or renaming a peer never fabricates a departure")
	_reset_observations()
	net.cl_roster({SELF_ID: "renamed"}, {SELF_ID: 12})
	_check(departed == [OTHER_ID], "a newly introduced peer can later depart normally")

	_install_client_snapshot()
	net.names[OTHER_ID] = "other remote"
	net.scores[OTHER_ID] = 1
	net.cl_roster({SELF_ID: "self"}, {SELF_ID: 0})
	departed.sort()
	_check(departed == [REMOTE_ID, OTHER_ID], "one roster can retire multiple peers exactly once")
	_reset_observations()
	net._on_peer_disconnected(999)
	_check(departed.is_empty() and net.names == {SELF_ID: "self"},
		"an unknown transport peer does not fabricate a departure")

	# Exercise the unchanged host callback with a real localhost-only authority.
	# Port zero lets ENet bind a free socket atomically, without a port race.
	net.shutdown()
	var host_error: int = net.start_dedicated(778899, 0, "127.0.0.1")
	_check(host_error == OK, "host-path checks bind only an ephemeral loopback socket")
	if host_error == OK:
		net.names[REMOTE_ID] = "registered"
		net.scores[REMOTE_ID] = 3
		net._registered[REMOTE_ID] = true
		_reset_observations()
		net._on_peer_disconnected(REMOTE_ID)
		_check(departed == [REMOTE_ID] and not net.names.has(REMOTE_ID) \
			and not net.scores.has(REMOTE_ID) and not net._registered.has(REMOTE_ID),
			"host registered-peer departure preserves removal and one notification")
		net._on_peer_disconnected(REMOTE_ID)
		_check(departed == [REMOTE_ID], "duplicate host transport notification stays idempotent")
		_reset_observations()
		net._pending_registrations[999] = {"fixture": true}
		net._on_peer_disconnected(999)
		_check(departed.is_empty() and not net._pending_registrations.has(999),
			"host unregistered-peer cleanup remains silent and clears pending state")
	_finish()


func _finish() -> void:
	if net:
		net.shutdown()
	print("NETROSTERTEST %d/%d %s" % [passed, total, "PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)
