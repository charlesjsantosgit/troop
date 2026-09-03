extends SceneTree
## Lightweight real-ENet release check, without creating a rendered world.
## Run server, then receiver and sender in separate processes on a free port:
##   godot --headless --path . --script res://tests/dedicatedrelaytest.gd -- server 30627
## Optional reject-version / reject-protocol roles verify update-required errors.
## The probe role accepts an explicit third hostname argument and only joins.

const DEFAULT_PORT := 30627
const DEADLINE_SECONDS := 60.0
const STATE_PACKETS := 48
const TEST_SEED := 778899
const TEST_POSITION := Vector3(10.0, 12.0, 20.0)
const TEST_BANANA := "b:relay#1"
const TEST_CHEST := "s:relay#1"
const VOICE_ACK_PREFIX := "RELAY-VOICE-ACK:"
const VOICE_ACK_DEADLINE_SECONDS := 2.0
const VOICE_RETRY_SECONDS := 0.1
const VOICE_MAX_RETRIES := 20

var net: Node
var role := ""
var port := DEFAULT_PORT
var address := "127.0.0.1"
var ready := false
var error_message := ""
var finished := false
var peak_players := 0
var sender_id := 0
var states := 0
var saw_chat := false
var saw_bullet := false
var saw_voice := false
var saw_voice_ack := false
var voice_ack_received_msec := -1
var saw_banana := false
var saw_chest := false
var saw_sender_leave := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	net = root.get_node("Net")
	var args := OS.get_cmdline_user_args()
	role = str(args[0]) if not args.is_empty() else ""
	if args.size() > 1 and str(args[1]).is_valid_int():
		port = clampi(int(args[1]), 1, 65535)
	if args.size() > 2:
		address = str(args[2])
	if role not in ["server", "receiver", "sender", "reject-version",
			"reject-protocol", "probe"]:
		_finish(false, "unknown role")
		return
	for variable in ["TROOP_ADMIN_KEY", "TROOP_ADMIN_TOKEN", "TROOP_STATE_DIR"]:
		OS.unset_environment(variable)
	# Every process models a separate installation. Never read or overwrite the
	# player's installation identity, admin registry, updater, or colony saves.
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	var run_id := OS.get_environment("TROOP_RELAY_TEST_RUN")
	if run_id.is_empty():
		run_id = Crypto.new().generate_random_bytes(8).hex_encode()
	if not run_id.is_valid_filename() or run_id.length() > 64:
		_finish(false, "invalid isolated test run id")
		return
	ProjectSettings.set_setting("application/config/custom_user_dir_name",
		"TROOP-dedicated-relay-%d-%s-%s" % [port, role, run_id])
	var dir_error := DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	if dir_error != OK and dir_error != ERR_ALREADY_EXISTS:
		_finish(false, "isolated user directory error=%d" % dir_error)
		return
	print("DEDICATEDRELAY-USERDIR " + OS.get_user_data_dir())
	net.world_ready.connect(func(): ready = true)
	net.net_error.connect(func(message: String): error_message = message)
	net.roster_changed.connect(_on_roster)
	create_timer(DEADLINE_SECONDS).timeout.connect(func():
		_finish(false, "timeout ready=%s roster=%d error=%s" % [
			ready, net.names.size(), error_message]))
	if role == "server":
		var server_error: int = net.start_dedicated(TEST_SEED, port, "127.0.0.1")
		if server_error != OK:
			_finish(false, "listen error=%d" % server_error)
			return
		print("DEDICATEDRELAY-SERVER READY port=%d version=%s protocol=%d max=%d" % [
			port, net.effective_game_version(), net.PROTOCOL_VERSION,
			net.MAX_CLIENTS])
		return
	if role == "receiver":
		net.peer_state.connect(_on_state)
		net.bullet_fired.connect(_on_bullet)
		net.voice_packet.connect(_on_voice)
		net.banana_taken.connect(_on_banana)
		net.supply_chest_claimed.connect(_on_chest)
		net.peer_left.connect(_on_peer_left)
	if role in ["receiver", "sender"]:
		net.chat_received.connect(_on_chat)
	if role == "reject-version":
		root.get_node("Updater")._base_version = "0.0.0-fixture-incompatible"
	var join_error: int = net.join(address, "Relay-" + role, port)
	if join_error != OK:
		_finish(false, "join error=%d" % join_error)
		return
	if role == "reject-protocol":
		net.multiplayer.connected_to_server.disconnect(
			Callable(net, "_on_connected"))
		net.multiplayer.connected_to_server.connect(func():
			net.active = true
			net.rpc_id(1, "srv_begin_register", "Old-protocol-fixture",
				net.PROTOCOL_VERSION - 1, net.effective_game_version(), ""))
	while not ready and error_message.is_empty() and not finished:
		await process_frame
	if finished:
		return
	if role.begins_with("reject-"):
		var expected := "protocol mismatch" if role == "reject-protocol" \
			else "Server is running TROOP"
		await create_timer(0.4).timeout
		_finish(not ready and not net.active and error_message.contains(expected),
			"clear_error=%s message=%s" % [error_message.contains(expected),
				error_message])
		return
	if not error_message.is_empty():
		_finish(false, error_message)
		return
	if role == "probe":
		_finish(not net.names.has(1) and net.names.has(net.local_id()),
			"host=%s port=%d version=%s protocol=%d seed=%d players=%d" % [
				address, port, net.effective_game_version(), net.PROTOCOL_VERSION,
				net.world_seed, net.names.size()])
		return
	if net.world_seed != TEST_SEED or net.names.has(1) or net.is_admin:
		_finish(false, "initial dedicated snapshot or non-admin identity")
		return
	print("DEDICATEDRELAY-%s READY id=%d" % [role.to_upper(), net.local_id()])
	if role == "sender":
		await _send_checks()


func _send_checks() -> void:
	while net.names.size() < 2 and not finished:
		await process_frame
	if finished:
		return
	var pcm := PackedInt32Array()
	pcm.resize(VoiceCodec.RECOMMENDED_FRAME_SAMPLES)
	for i in range(pcm.size()):
		pcm[i] = roundi(sin(TAU * 330.0 * float(i) \
			/ float(VoiceCodec.SAMPLE_RATE_HZ)) * 12000.0)
	var packet := VoiceCodec.encode_pcm16(pcm)
	var malformed := packet.duplicate()
	malformed[0] ^= 0xff
	# State gets a head start because ENet's reliable/unreliable channels have
	# no cross-channel ordering guarantee. Combat must follow accepted position.
	for sequence in range(STATE_PACKETS):
		net.send_state(TEST_POSITION + Vector3(sequence * 0.05, 0.0, 0.0),
			0.25, Vector3(1.0, 0.0, 0.0), 0, false, Vector3.ZERO, 0.0,
			PackedVector3Array(), net.WEAPON_REVOLVER, false, false, 6,
			false, 0.0)
		if sequence == 5:
			net.send_chat("RELAY-CHECK")
			net.try_collect(TEST_BANANA)
			net.request_supply_chest(TEST_CHEST)
			net.fire_bullet(TEST_POSITION + Vector3.UP, Vector3(0.0, 0.0, 100.0))
			net.rpc_id(1, "srv_voice", 76, malformed)
		if sequence >= 6:
			net.send_voice(sequence + 71, packet)
		await create_timer(0.05).timeout
	# Unreliable voice can be dropped immediately before disconnect. Retry at a
	# bounded 10 Hz until the receiver confirms its first valid packet over the
	# existing reliable chat relay; this adds no test-only production RPC.
	var voice_sequence := STATE_PACKETS + 71
	var voice_retries := 0
	var voice_ack_deadline := Time.get_ticks_msec() \
		+ roundi(VOICE_ACK_DEADLINE_SECONDS * 1000.0)
	while not saw_voice_ack and voice_retries < VOICE_MAX_RETRIES \
			and Time.get_ticks_msec() < voice_ack_deadline:
		net.send_voice(voice_sequence, packet)
		voice_sequence += 1
		voice_retries += 1
		await create_timer(VOICE_RETRY_SECONDS).timeout
	if not saw_voice_ack or voice_ack_received_msec > voice_ack_deadline:
		_finish(false, "voice acknowledgment timeout retries=%d received=%d deadline=%d" % [
			voice_retries, voice_ack_received_msec, voice_ack_deadline])
		return
	await create_timer(0.4).timeout
	_finish(net.collected.has(TEST_BANANA) \
		and int(net.claimed_supply_chests.get(TEST_CHEST, 0)) == net.local_id(),
		"movement=%d chat=true bullet=true voice=true voice_ack=true claims_acknowledged=true" % STATE_PACKETS)


func _on_roster() -> void:
	peak_players = maxi(peak_players, net.names.size())
	if net.names.has(1):
		_finish(false, "dedicated authority appeared as a player")
	elif role == "server" and peak_players == 2 and net.names.is_empty():
		_finish(true, "two_authenticated_clients=true disconnect_cleanup=true")


func _on_state(peer_id: int, position: Vector3, _yaw: float, _velocity: Vector3,
		_anim: int, _swinging: bool, _anchor: Vector3, _rope_tail: float,
		_wraps: PackedVector3Array, _weapon_kind: int, _weapon_stowed: bool,
		_melee_mode: bool, _ammo: int, _reloading: bool, _healing: float,
		_flying: bool, _vehicle_kind: int, _vehicle_id: String,
		_vehicle_aux: Vector3) -> void:
	if peer_id != net.local_id() \
			and position.distance_to(TEST_POSITION) < STATE_PACKETS * 0.05 + 0.01:
		sender_id = peer_id
		states += 1


func _on_chat(peer_id: int, _sender_name: String, message: String,
		from_admin: bool) -> void:
	if peer_id != net.local_id() and message == "RELAY-CHECK" and not from_admin:
		saw_chat = true
	elif role == "sender" and peer_id != net.local_id() and not from_admin \
			and message == VOICE_ACK_PREFIX + str(net.local_id()):
		if not saw_voice_ack:
			saw_voice_ack = true
			voice_ack_received_msec = Time.get_ticks_msec()


func _on_bullet(peer_id: int, _origin: Vector3, _velocity: Vector3,
		damage: float, headshot: bool, _play_fx: bool, weapon_kind: int) -> void:
	if peer_id != net.local_id() and weapon_kind == net.WEAPON_REVOLVER \
			and is_equal_approx(damage, 34.0) and headshot:
		saw_bullet = true


func _on_voice(peer_id: int, sequence: int, payload: PackedByteArray) -> void:
	if sequence == 76:
		_finish(false, "malformed voice was relayed")
	elif peer_id != net.local_id() and sequence >= 77 \
			and sequence < STATE_PACKETS + 71 + VOICE_MAX_RETRIES \
			and VoiceCodec.is_valid_packet(payload):
		if not saw_voice:
			saw_voice = true
			net.send_chat(VOICE_ACK_PREFIX + str(peer_id))


func _on_banana(banana_id: String) -> void:
	saw_banana = saw_banana or banana_id == TEST_BANANA


func _on_chest(chest_id: String, claimant_id: int) -> void:
	if chest_id == TEST_CHEST and claimant_id != net.local_id():
		saw_chest = true
		# A second client cannot take a claimed chest from its original owner.
		if net.request_supply_chest(TEST_CHEST):
			_finish(false, "duplicate chest claim was admitted locally")
		# Also bypass the local cache to exercise authority arbitration itself.
		net.rpc_id(1, "srv_request_supply_chest", TEST_CHEST)


func _on_peer_left(peer_id: int) -> void:
	if peer_id == sender_id:
		saw_sender_leave = true
		_finish(states >= 5 and saw_chat and saw_bullet and saw_voice \
			and saw_banana and saw_chest and saw_sender_leave and peak_players == 2 \
			and int(net.claimed_supply_chests.get(TEST_CHEST, 0)) == sender_id,
			"states=%d chat=%s bullet=%s voice=%s malformed_filtered=true banana=%s chest=%s disconnect=%s" % [
				states, saw_chat, saw_bullet, saw_voice, saw_banana,
				saw_chest, saw_sender_leave])


func _finish(ok: bool, detail: String) -> void:
	if finished:
		return
	finished = true
	print("DEDICATEDRELAY-%s %s %s" % [role.to_upper(),
		"PASS" if ok else "FAIL", detail])
	if net:
		net.shutdown()
		# Test identities are disposable; never leave generated private keys or
		# fallback secrets behind after a successful or failed fixture run.
		if OS.get_user_data_dir().get_file().begins_with("TROOP-dedicated-relay-"):
			for filename in ["admin_identity.key", "admin_identity_secret.txt"]:
				for suffix in ["", ".tmp", ".bak"]:
					var path: String = "user://" + filename + suffix
					if FileAccess.file_exists(path):
						DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	quit(0 if ok else 1)
