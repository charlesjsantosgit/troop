extends SceneTree
## Actual high-level RPC bootstrap used by run_frontier_mtu.py's WAN relay.
## Generated municipal state only; no installation identities or public server.
const VIEW_COUNT := 12
var wire: Node
var peer: ENetMultiplayerPeer
var payloads: Array = []
var server := false
var mode := 0
var deadline := 0
var next_sample := 0
var sequence := 0
var connected := false
var snapshots: Dictionary = {}
var movements := 0
var voices := 0
var traffic_samples := 0
var mismatches := 0
var minimum_view_bytes := 2147483647
var last_rtt := 0.0
var voice_data := PackedByteArray()

class WireNode extends Node:
	var fixture: SceneTree
	@rpc("authority", "call_remote", "reliable", 0)
	func snapshot(town: String, revision: int, view: Dictionary, catalog: Array) -> void:
		fixture.received_snapshot(town, revision, view, catalog)
	@rpc("authority", "call_remote", "unreliable_ordered", 0)
	func movement(serial: int, position: Vector3, velocity: Vector3, yaw: float, anim: int) -> void:
		if serial >= 0 and position.is_finite() and velocity.is_finite() and is_finite(yaw) and anim == 0:
			fixture.movements += 1
	@rpc("authority", "call_remote", "unreliable", 1)
	func voice(serial: int, payload: PackedByteArray) -> void:
		if serial >= 0 and payload == fixture.voice_data and VoiceCodec.is_valid_packet(payload):
			fixture.voices += 1
	@rpc("authority", "call_remote", "unreliable_ordered", 1)
	func traffic(serial: int, packet: Array) -> void:
		if serial >= 0 and packet.size() == 5:
			fixture.traffic_samples += 1

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 3:
		quit(2)
		return
	server = args[0] == "server"
	mode = int(args[2])
	var domain = load("res://scripts/frontier_societies.gd").new()
	domain.new_game(2026)
	var identities := ["a".repeat(64), "b".repeat(64)]
	for identity: String in identities:
		if not domain.ensure_player(identity, "Generated WAN fixture").ok:
			quit(2)
			return
	# Exercise real bounded memories, work records, cargo and accounting fields.
	for tick in range(450):
		domain.tick(1.0)
	for identity: String in identities:
		for town: Dictionary in domain.towns(identity):
			var payload := [town.id, payloads.size(), domain.view(identity, town.id), domain.towns(identity)]
			minimum_view_bytes = mini(minimum_view_bytes, var_to_bytes(payload).size())
			payloads.append(payload)
	var pcm := PackedInt32Array()
	pcm.resize(VoiceCodec.RECOMMENDED_FRAME_SAMPLES)
	pcm.fill(0)
	voice_data = VoiceCodec.encode_pcm16(pcm)
	wire = WireNode.new()
	wire.name = "WanFixture"
	wire.fixture = self
	root.add_child(wire)
	peer = ENetMultiplayerPeer.new()
	peer.set_bind_ip("127.0.0.1")
	var error := peer.create_server(int(args[1]), 2, 2) if server else peer.create_client("127.0.0.1", int(args[1]), 2)
	if error != OK:
		quit(2)
		return
	var net := root.get_node("Net")
	# Correct bandwidth in BOTH arms so the independent Godot engine defect
	# cannot masquerade as an MTU failure. Test the real production compressor.
	if server:
		net.configure_server_transport(peer)
	if mode == 1:
		net.configure_transport(peer)
	root.multiplayer.multiplayer_peer = peer
	root.multiplayer.peer_connected.connect(_connected)
	# The authority is ready before the client advances its independent 450s
	# model fixture. Keep server lifetime outside that CPU warmup while retaining
	# a bounded four/twelve-second network phase on the receiving client.
	deadline = Time.get_ticks_msec() + (30000 if server \
		else 5000 if mode == 0 else 12000)
	print("FRONTIERMTU_READY role=%s views=%d minimum_view_bytes=%d" % [args[0], payloads.size(), minimum_view_bytes])

func _connected(id: int) -> void:
	connected = true
	if server:
		for payload: Array in payloads:
			wire.rpc_id(id, "snapshot", payload[0], payload[1], payload[2], payload[3])

func _process(_delta: float) -> bool:
	if deadline == 0:
		return false
	if server and connected and Time.get_ticks_msec() >= next_sample:
		var rows: Array = []
		for index in range(5):
			rows.append([str(index), PackedFloat32Array([float(sequence),3.9,float(index),0,0,0,1,0,1,0.2,0.1,0])])
		wire.rpc("movement", sequence, Vector3(float(sequence),3.25,0),Vector3(1,0,0),0.25,0)
		wire.rpc("voice", sequence, voice_data)
		wire.rpc("traffic", sequence, rows)
		sequence += 1
		next_sample = Time.get_ticks_msec() + 100
	if not server and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		last_rtt = peer.get_peer(1).get_statistic(ENetPacketPeer.PEER_LAST_ROUND_TRIP_TIME)
	if not server and snapshots.size() == VIEW_COUNT and movements >= 10 and voices >= 10 and traffic_samples >= 10:
		_finish(mismatches == 0 and minimum_view_bytes > 65536 and last_rtt >= 65.0)
	elif Time.get_ticks_msec() >= deadline:
		_finish(server)
	return false

func received_snapshot(town: String, revision: int, view: Dictionary, catalog: Array) -> void:
	if revision < 0 or revision >= payloads.size() or snapshots.has(revision):
		mismatches += 1
		return
	# No partially reconstructed dictionaries are published: compare the full
	# RPC value, including order, numbers and personal aliases, byte-for-byte.
	if var_to_bytes([town, revision, view, catalog]) != var_to_bytes(payloads[revision]):
		mismatches += 1
	snapshots[revision] = true

func _finish(ok: bool) -> void:
	print("FRONTIERMTU_RESULT " + JSON.stringify({"ok":ok,"server":server,"mode":mode,
		"snapshots":snapshots.size(),"expected":VIEW_COUNT,"movements":movements,
		"voices":voices,"traffic":traffic_samples,"mismatches":mismatches,
		"minimum_view_bytes":minimum_view_bytes,"last_rtt_ms":last_rtt}))
	deadline = 0
	peer.close()
	quit(0 if ok else 1)
