extends SceneTree
## Deterministic public-relay hardening checks:
##   godot --headless --path . --script res://tests/netsecuritytest.gd

const Codec = preload("res://scripts/voice_codec.gd")

var passed := 0
var total := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var net := root.get_node("Net")
	var voice := root.get_node("Voice")

	_check(net.MAX_STATE_PACKETS_PER_SECOND == 30 \
		and net.REGISTRATION_TIMEOUT_SECONDS == 5.0,
		"public ingress uses a 30 Hz state ceiling and five-second registration deadline")
	net._rate_windows.clear()
	var admitted := true
	for _i in range(net.MAX_STATE_PACKETS_PER_SECOND):
		admitted = admitted and net._allow_rate(77, "state-test",
			net.MAX_STATE_PACKETS_PER_SECOND)
	_check(admitted and not net._allow_rate(77, "state-test",
		net.MAX_STATE_PACKETS_PER_SECOND),
		"state rate bucket rejects packet 31 in one window")

	_check(net._valid_banana_id("b:-12,34#5") \
		and net._valid_supply_chest_id("s:arena#northwest") \
		and net._valid_supply_chest_id("s:-8,19#0"),
		"canonical generated stable IDs pass strict grammar")
	_check(not net._valid_banana_id("b:no-separator") \
		and not net._valid_banana_id("b:x#1#2") \
		and not net._valid_banana_id("b:ñ#1") \
		and not net._valid_supply_chest_id("s:bad path#0") \
		and not net._valid_supply_chest_id("s:" + "x".repeat(
			net.MAX_CHEST_ID_LENGTH) + "#0"),
		"missing separators, duplicate separators, Unicode, spaces, and long IDs are rejected")
	_check(net.MAX_COLLECTED_IDS == 200000 and net.MAX_CHEST_CLAIMS == 50000,
		"authoritative persistent-ID stores have explicit snapshot-aligned ceilings")

	var pcm := PackedInt32Array()
	pcm.resize(Codec.RECOMMENDED_FRAME_SAMPLES)
	var packet: PackedByteArray = Codec.encode_pcm16(pcm)
	var malformed := packet.duplicate()
	malformed[0] ^= 0xff
	_check(net.MAX_VOICE_PACKET_BYTES == Codec.MAX_PACKET_BYTES \
		and packet.size() <= net.MAX_VOICE_PACKET_BYTES \
		and Codec.is_valid_packet(packet) and not Codec.is_valid_packet(malformed),
		"network voice ceiling exactly matches the strict codec envelope")

	var world := Node3D.new()
	root.add_child(world)
	voice.attach_world(world)
	var player := AudioStreamPlayer3D.new()
	world.add_child(player)
	var queued: Array = []
	for _i in range(voice.MAX_DECODED_QUEUE_PACKETS):
		queued.append(PackedVector2Array())
	voice._speakers[77] = {
		"player": player,
		"playback": null,
		"queue": queued,
		"started": false,
		"talking": true,
		"last_sequence": 0,
		"last_received": Time.get_ticks_msec(),
	}
	voice._on_voice_packet(77, 1, packet)
	var reset_entry: Dictionary = voice._speakers.get(77, {})
	_check(reset_entry.get("queue", []).size() == 1 \
		and not bool(reset_entry.get("started", true)) \
		and reset_entry.get("playback") == null,
		"stalled decoded queue drops stale audio and safely re-prebuffers from the current packet")
	voice.clear_world()
	world.queue_free()

	print("NETSECURITYTEST %d/%d %s" % [
		passed, total, "PASS" if passed == total else "FAIL"])
	quit(0 if passed == total else 1)


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label)
