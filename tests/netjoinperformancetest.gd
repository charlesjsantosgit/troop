extends SceneTree
## Isolated connection-stage regression (no public connection or world build):
##   godot --headless --path . --script res://tests/netjoinperformancetest.gd
## Budgets detect pathological stalls across CI machines, not a 60 FPS promise.

const COLD_IDENTITY_BUDGET_MS := 2000.0
const CACHED_IDENTITY_BUDGET_MS := 250.0
const LOCAL_DNS_BUDGET_MS := 250.0
const SIGNATURE_BUDGET_MS := 250.0
const CACHED_JOIN_BUDGET_MS := 250.0
const SNAPSHOT_1000_BUDGET_MS := 100.0
const SNAPSHOT_10000_BUDGET_MS := 500.0

var passed := 0
var total := 0
var timings: Dictionary = {}
var fixture_user_dir := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var net := root.get_node("Net")
	var previous_custom: bool = ProjectSettings.get_setting(
		"application/config/use_custom_user_dir", false)
	var previous_name: String = ProjectSettings.get_setting(
		"application/config/custom_user_dir_name", "")
	var run_id := Crypto.new().generate_random_bytes(8).hex_encode()
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name",
		"TROOP-netjoin-performance-" + run_id)
	fixture_user_dir = OS.get_user_data_dir()
	var directory_error := DirAccess.make_dir_recursive_absolute(fixture_user_dir)
	_check(directory_error == OK or directory_error == ERR_ALREADY_EXISTS,
		"uses an isolated disposable identity directory")
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		_finish(net, previous_custom, previous_name)
		return

	# Keep the selected UDP port reserved by a non-ENet socket throughout the
	# test. No real dedicated server, public endpoint, or other client is touched.
	var reserved := PacketPeerUDP.new()
	var reserve_error := reserved.bind(0, "127.0.0.1")
	_check(reserve_error == OK and reserved.get_local_port() > 0,
		"reserves a private loopback UDP destination")
	if reserve_error != OK:
		_finish(net, previous_custom, previous_name)
		return

	var start := Time.get_ticks_usec()
	var resolved := IP.resolve_hostname("localhost", IP.TYPE_IPV4)
	var dns_ms := _elapsed_ms(start)
	_check(resolved == "127.0.0.1" and dns_ms <= LOCAL_DNS_BUDGET_MS,
		"localhost DNS stays bounded", dns_ms, LOCAL_DNS_BUDGET_MS)
	timings.local_dns_ms = dns_ms

	start = Time.get_ticks_usec()
	var key: CryptoKey = net._load_or_create_identity_key()
	var cold_ms := _elapsed_ms(start)
	_check(key != null and cold_ms <= COLD_IDENTITY_BUDGET_MS,
		"first installation key preparation stays bounded", cold_ms,
		COLD_IDENTITY_BUDGET_MS)
	timings.cold_identity_ms = cold_ms
	if key == null:
		reserved.close()
		_finish(net, previous_custom, previous_name)
		return

	start = Time.get_ticks_usec()
	var loaded: CryptoKey = net._load_or_create_identity_key()
	var cached_ms := _elapsed_ms(start)
	_check(loaded != null and loaded.save_to_string(true) == key.save_to_string(true)
		and cached_ms <= CACHED_IDENTITY_BUDGET_MS,
		"cached identity reload preserves its public identity without a long stall",
		cached_ms, CACHED_IDENTITY_BUDGET_MS)
	timings.cached_identity_ms = cached_ms

	start = Time.get_ticks_usec()
	var signature: PackedByteArray = net._sign_registration_context(
		"netjoin-performance-fixture".sha256_buffer(), key)
	var signature_ms := _elapsed_ms(start)
	var parsed: Dictionary = net._parse_public_identity(key.save_to_string(true))
	var verified: bool = not parsed.is_empty() \
		and net._verify_registration_signature(
			"netjoin-performance-fixture".sha256_buffer(), signature, parsed.key)
	_check(verified and signature_ms <= SIGNATURE_BUDGET_MS,
		"registration signature stays valid and bounded", signature_ms,
		SIGNATURE_BUDGET_MS)
	timings.registration_signature_ms = signature_ms

	var world_script_was_loaded := ResourceLoader.has_cached("res://scripts/world.gd")
	start = Time.get_ticks_usec()
	var join_error: int = net.join("localhost", "TimingFixture",
		reserved.get_local_port())
	var join_ms := _elapsed_ms(start)
	_check(join_error == OK and not net.active and join_ms <= CACHED_JOIN_BUDGET_MS,
		"cached local join returns promptly before network registration",
		join_ms, CACHED_JOIN_BUDGET_MS)
	timings.cached_join_ms = join_ms
	_check(ResourceLoader.has_cached("res://scripts/world.gd") == world_script_was_loaded,
		"connection-only client does not load the town rendering and terrain scene graph")
	net.shutdown()
	reserved.close()

	net.names = {1: "SnapshotFixture"}
	net.scores = {1: 0}
	for count in [1000, 10000]:
		var taken: Array = []
		for index in range(count):
			taken.append("b:fixture#%d" % index)
		start = Time.get_ticks_usec()
		net.cl_world(20260805, taken, {}, 12.0, net.effective_game_version())
		var snapshot_ms := _elapsed_ms(start)
		var budget := SNAPSHOT_1000_BUDGET_MS if count == 1000 \
			else SNAPSHOT_10000_BUDGET_MS
		_check(net.collected.size() == count and snapshot_ms <= budget,
			"%d-item snapshot retains every ID within its decode budget" % count,
			snapshot_ms, budget)
		timings["snapshot_%d_ms" % count] = snapshot_ms
	_finish(net, previous_custom, previous_name)


func _elapsed_ms(start_usec: int) -> float:
	return float(Time.get_ticks_usec() - start_usec) / 1000.0


func _check(condition: bool, label: String, elapsed := -1.0,
		budget := -1.0) -> void:
	total += 1
	if condition:
		passed += 1
	var suffix := " (%.3f ms / %.0f ms)" % [elapsed, budget] \
		if elapsed >= 0.0 else ""
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", label, suffix])


func _finish(net: Node, previous_custom: bool, previous_name: String) -> void:
	net.shutdown()
	if fixture_user_dir.get_file().begins_with("TROOP-netjoin-performance-"):
		for filename in ["admin_identity.key", "admin_identity_secret.txt"]:
			for suffix in ["", ".tmp", ".bak"]:
				var path: String = fixture_user_dir.path_join(filename + suffix)
				if FileAccess.file_exists(path):
					DirAccess.remove_absolute(path)
		_check(not FileAccess.file_exists(fixture_user_dir.path_join("admin_identity.key"))
			and not FileAccess.file_exists(fixture_user_dir.path_join("admin_identity_secret.txt")),
			"disposable private key and fallback secret are removed")
	ProjectSettings.set_setting("application/config/use_custom_user_dir", previous_custom)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", previous_name)
	print("NETJOINPERFORMANCE_TIMINGS " + JSON.stringify(timings))
	print("NETJOINPERFORMANCETEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)
