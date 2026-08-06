extends SceneTree
## Three-process dedicated voice relay fixture. Start server, receiver, then
## sender in separate processes with the same optional port argument.

const DEFAULT_PORT := 30626

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
	match role:
		"server":
			var err: int = net.start_dedicated(778899, port, "127.0.0.1", 8)
			if err != OK:
				print("VOICE-RELAY-SERVER FAIL err=%d" % err)
				quit(1)
				return
			print("VOICE-RELAY-SERVER READY port=%d" % port)
			await create_timer(15.0).timeout
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
			var deadline := Time.get_ticks_msec() + 10000
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
