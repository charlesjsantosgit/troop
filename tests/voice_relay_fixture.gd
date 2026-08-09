extends SceneTree
## Three-process dedicated voice relay fixture. Start server, receiver, then
## sender in separate processes with the same optional port argument.

const DEFAULT_PORT := 30626
const SERVER_LIFETIME_SECONDS := 30.0
const RECEIVER_DEADLINE_SECONDS := 25.0
const VALID_ROLES := ["server", "receiver", "sender"]

var net: Node
var received := false
var port := DEFAULT_PORT


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	net = root.get_node("Net")
	var args := OS.get_cmdline_user_args()
	var role := str(args[0]) if not args.is_empty() else ""
	if args.size() > 1 and str(args[1]).is_valid_int():
		port = clampi(int(args[1]), 1, 65535)
	if role not in VALID_ROLES:
		print("VOICE-RELAY FAIL unknown role")
		quit(1)
		return
	# A real installation owns one persistent registration key and is correctly
	# rejected if it connects twice. This same-machine fixture represents three
	# different installations, so give each role its own test-only user:// root
	# before Net loads or creates that identity. Runtime ProjectSettings are not
	# saved and the ordinary TROOP user-data directory is never touched.
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name",
		"TROOP-voice-relay-fixture-%d-%s" % [port, role])
	var user_dir_error := DirAccess.make_dir_recursive_absolute(
		OS.get_user_data_dir())
	if user_dir_error != OK and user_dir_error != ERR_ALREADY_EXISTS:
		print("VOICE-RELAY-%s FAIL user-dir=%d" % [role.to_upper(),
			user_dir_error])
		quit(1)
		return
	match role:
		"server":
			var err: int = net.start_dedicated(778899, port, "127.0.0.1", 8)
			if err != OK:
				print("VOICE-RELAY-SERVER FAIL err=%d" % err)
				quit(1)
				return
			print("VOICE-RELAY-SERVER READY port=%d" % port)
			# First-run clients generate separate 2048-bit installation keys. That
			# can take more than 15 seconds on a busy runner, so keep the authority
			# alive long enough for both fresh identities and the receiver timeout.
			await create_timer(SERVER_LIFETIME_SECONDS).timeout
			print("VOICE-RELAY-SERVER PASS")
			quit(0)
		"receiver":
			net.voice_packet.connect(_on_voice_packet)
			var err: int = net.join("127.0.0.1", "Receiver", port)
			if err != OK:
				print("VOICE-RELAY-RECEIVER FAIL join=%d" % err)
				quit(1)
				return
			await net.world_ready
			print("VOICE-RELAY-RECEIVER READY id=%d" % net.local_id())
			var deadline := Time.get_ticks_msec() \
				+ int(RECEIVER_DEADLINE_SECONDS * 1000.0)
			while not received and Time.get_ticks_msec() < deadline:
				await process_frame
			if not received:
				print("VOICE-RELAY-RECEIVER FAIL timeout roster=%d" % net.names.size())
				quit(1)
		"sender":
			var err: int = net.join("127.0.0.1", "Sender", port)
			if err != OK:
				print("VOICE-RELAY-SENDER FAIL join=%d" % err)
				quit(1)
				return
			await net.world_ready
			await create_timer(0.5).timeout
			var pcm := PackedInt32Array()
			pcm.resize(VoiceCodec.RECOMMENDED_FRAME_SAMPLES)
			for i in range(pcm.size()):
				pcm[i] = roundi(sin(TAU * 330.0 * float(i) \
					/ float(VoiceCodec.SAMPLE_RATE_HZ)) * 12000.0)
			var packet := VoiceCodec.encode_pcm16(pcm)
			var malformed := packet.duplicate()
			malformed[0] ^= 0xff
			# Bypass the helper once to prove malformed data is not amplified.
			net.rpc_id(1, "srv_voice", 76, malformed)
			await create_timer(0.1).timeout
			for sequence in range(77, 80):
				net.send_voice(sequence, packet)
				await create_timer(0.02).timeout
			print("VOICE-RELAY-SENDER PASS id=%d bytes=%d valid=%s" % [
				net.local_id(), packet.size(),
				str(VoiceCodec.is_valid_packet(packet))])
			await create_timer(1.0).timeout
			quit(0)
		_:
			print("VOICE-RELAY FAIL unknown role")
			quit(1)


func _on_voice_packet(speaker_id: int, sequence: int,
		payload: PackedByteArray) -> void:
	var decoded := VoiceCodec.decode_pcm16(payload)
	if speaker_id == net.local_id() or sequence < 77 or sequence > 79 \
			or not bool(decoded.ok) \
			or decoded.samples.size() != VoiceCodec.RECOMMENDED_FRAME_SAMPLES:
		print("VOICE-RELAY-RECEIVER FAIL payload speaker=%d sequence=%d" % [
			speaker_id, sequence])
		quit(1)
		return
	received = true
	print("VOICE-RELAY-RECEIVER PASS speaker=%d sequence=%d bytes=%d malformed_filtered=true" % [
		speaker_id, sequence, payload.size()])
	quit(0)
