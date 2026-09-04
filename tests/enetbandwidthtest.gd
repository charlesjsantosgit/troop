extends SceneTree
## Real ENet transport through an 80 ms RTT UDP relay. No game/server state.
## godot --headless --path . --script res://tests/enetbandwidthtest.gd
## The uncorrected engine case is diagnostic; future fixed engines may pass it.
const ONE_WAY_DELAY_MS := 40
const STREAM_MS := 6000
const PACKET_INTERVAL_MS := 20
const PACKET_SIZE := 960
var checks := 0
var passed := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("ENETBANDWIDTH %s %s" % ["OK" if ok else "FAIL",label])

func _run() -> void:
	var original := _scenario(false)
	var corrected := _scenario(true)
	print("ENETBANDWIDTH_METRICS " + JSON.stringify({"engine":Engine.get_version_info().string,
		"round_trip_delay_ms":ONE_WAY_DELAY_MS*2,"original":original,"corrected":corrected}))
	check(original.connected and corrected.connected,"both actual ENet peers complete delayed handshakes")
	check(corrected.sent >= 290 and corrected.steady_sent >= 190,"corrected stream ran six seconds beyond bandwidth recalculation")
	check(corrected.received >= corrected.sent*0.95,"corrected server receives at least 95 percent of voice-sized datagrams")
	check(corrected.steady_received >= corrected.steady_sent*0.95,"corrected server retains voice after ENet bandwidth throttling begins")
	check(corrected.minimum_throttle_limit == ENetPacketPeer.PACKET_THROTTLE_SCALE,"client retains its full outgoing packet throttle allowance throughout steady traffic")
	check(corrected.reliable_bytes == 12288,"delayed reliable snapshot arrives alongside unreliable voice traffic")
	check(corrected.measured_rtt_ms >= 65,"fixture exercises genuine nonzero transport RTT")
	var source:=FileAccess.get_file_as_string("res://scripts/net.gd")
	check(_configured_before_assignment(source,"func host(")
		and _configured_before_assignment(source,"func start_dedicated("),
		"listen and dedicated creation apply the tested correction before accepting peers")
	check(source.count("\tconfigure_transport(peer)\n\tmultiplayer.multiplayer_peer = peer")==3,
		"listen, dedicated and client configure matching compression before peer assignment")
	print("ENETBANDWIDTHTEST %d/%d %s" % [passed,checks,"PASS" if passed==checks else "FAIL"])
	quit(0 if passed==checks else 1)

func _configured_before_assignment(source: String, signature: String) -> bool:
	var start:=source.find(signature)
	var end:=source.find("\nfunc ",start+signature.length())
	var body:=source.substr(start,end-start if end>=0 else -1)
	var configure:=body.find("configure_server_transport(peer)")
	return start>=0 and configure>body.find("peer.create_server(") \
		and configure<body.find("multiplayer.multiplayer_peer = peer")

func _scenario(corrected: bool) -> Dictionary:
	var result:={"connected":false,"sent":0,"received":0,"steady_sent":0,
		"steady_received":0,"throttle_limit":0,"minimum_throttle_limit":32,
		"reliable_bytes":0,"measured_rtt_ms":0}
	var server:=ENetMultiplayerPeer.new()
	server.set_bind_ip("127.0.0.1")
	var client:=ENetMultiplayerPeer.new()
	var front:=PacketPeerUDP.new()
	var back:=PacketPeerUDP.new()
	if server.create_server(0,2,2)!=OK or front.bind(0,"127.0.0.1")!=OK or back.bind(0,"127.0.0.1")!=OK:
		return result
	if corrected: root.get_node("Net").configure_server_transport(server)
	root.get_node("Net").configure_transport(server)
	back.set_dest_address("127.0.0.1",server.get_host().get_local_port())
	if client.create_client("127.0.0.1",front.get_local_port(),2)!=OK:
		server.close()
		front.close()
		back.close()
		return result
	root.get_node("Net").configure_transport(client)
	var connected:={"server":false}
	server.peer_connected.connect(func(_id): connected.server=true)
	var relay:={"front":front,"back":back,"client_port":0,"queue":[]}
	var deadline:=Time.get_ticks_msec()+5000
	while Time.get_ticks_msec()<deadline:
		_pump(relay)
		server.poll()
		client.poll()
		if connected.server and client.get_connection_status()==MultiplayerPeer.CONNECTION_CONNECTED:
			result.connected=true
			break
		OS.delay_msec(1)
	if result.connected:
		client.set_target_peer(1)
		client.transfer_mode=MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
		client.transfer_channel=1
		server.set_target_peer(client.get_unique_id())
		server.transfer_mode=MultiplayerPeer.TRANSFER_MODE_RELIABLE
		var snapshot:=PackedByteArray()
		snapshot.resize(12288)
		snapshot.fill(29)
		server.put_packet(snapshot)
		var began:=Time.get_ticks_msec()
		var next_send:=began
		# Encoded voice is not a zero-filled compressible fixture. Keep the
		# transport load representative after enabling production compression.
		var random:=RandomNumberGenerator.new()
		random.seed=2026
		var voice:=PackedByteArray()
		voice.resize(PACKET_SIZE)
		for index in range(PACKET_SIZE): voice[index]=random.randi()%256
		while Time.get_ticks_msec()<began+STREAM_MS+300:
			_pump(relay)
			server.poll()
			client.poll()
			var now:=Time.get_ticks_msec()
			if now<began+STREAM_MS and now>=next_send:
				var data:=voice.duplicate()
				data.encode_u32(0,result.sent)
				data.encode_u32(4,now-began)
				client.put_packet(data)
				result.sent+=1
				if now-began>=2000: result.steady_sent+=1
				next_send+=PACKET_INTERVAL_MS
			while server.get_available_packet_count()>0:
				var data:=server.get_packet()
				if data.size()==PACKET_SIZE:
					result.received+=1
					if data.decode_u32(4)>=2000: result.steady_received+=1
			while client.get_available_packet_count()>0:
				result.reliable_bytes+=client.get_packet().size()
			if now-began>=2000 and now-began<STREAM_MS:
				result.minimum_throttle_limit=mini(result.minimum_throttle_limit,
					int(client.get_peer(1).get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_LIMIT)))
			OS.delay_msec(1)
		result.throttle_limit=client.get_peer(1).get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_LIMIT)
		result.measured_rtt_ms=client.get_peer(1).get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)
	server.close()
	client.close()
	front.close()
	back.close()
	return result

func _pump(relay: Dictionary) -> void:
	var now:=Time.get_ticks_msec()
	for side in ["front","back"]:
		var socket: PacketPeerUDP=relay[side]
		while socket.get_available_packet_count()>0:
			var data:=socket.get_packet()
			if side=="front": relay.client_port=socket.get_packet_port()
			relay.queue.append({"due":now+ONE_WAY_DELAY_MS,"to":"back" if side=="front" else "front","data":data})
	while not relay.queue.is_empty() and relay.queue[0].due<=now:
		var queued: Dictionary=relay.queue.pop_front()
		var socket: PacketPeerUDP=relay[queued.to]
		if queued.to=="front": socket.set_dest_address("127.0.0.1",relay.client_port)
		socket.put_packet(queued.data)
