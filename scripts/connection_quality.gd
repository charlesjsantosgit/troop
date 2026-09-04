class_name ConnectionQuality
extends RefCounted
## Read existing ENet statistics; observing the connection sends no extra traffic.

static func sample(net: Node) -> Dictionary:
	if not net.active:
		return {"visible": false, "text": "", "detail": "Playing locally.", "warning": false}
	if net.is_host:
		return {"visible": false, "text": "", "detail": "Hosting locally.", "warning": false}
	var transport = net.multiplayer.multiplayer_peer
	if not transport is ENetMultiplayerPeer \
			or transport.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return {"visible": true, "text": "Connecting…", "detail": "Connecting to the shared world.", "warning": false}
	var peer: ENetPacketPeer = transport.get_peer(1)
	if peer == null or not peer.is_active():
		return {"visible": true, "text": "Connecting…", "detail": "Waiting for the server connection.", "warning": false}
	var rtt := peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)
	var variation := peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME_VARIANCE)
	# ENet updates this loss estimate only every ten seconds. Do not present the
	# initial zero as a measured loss-free connection, or as total Wi-Fi loss.
	var loss := -1.0
	if peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS_EPOCH) > 0:
		loss = 100.0 * peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) \
			/ ENetPacketPeer.PACKET_LOSS_SCALE
	return describe(rtt, variation, loss)


static func describe(rtt_ms: float, variation_ms: float, reliable_loss_percent: float = -1.0) -> Dictionary:
	if not is_finite(rtt_ms) or rtt_ms <= 0 or not is_finite(variation_ms):
		return {"visible": true, "text": "Measuring ping…", "detail": "Waiting for a connection timing sample.", "warning": false}
	var rtt := roundi(rtt_ms)
	var unstable := variation_ms >= 40.0 or (is_finite(reliable_loss_percent) and reliable_loss_percent >= 2.0)
	var slow := rtt >= 180
	var text := "Ping %d ms" % rtt
	if unstable:
		text += " · unstable"
	elif slow:
		text += " · delayed"
	var detail := "Server round trip: %d ms. Timing variation: %d ms." % [rtt, roundi(maxf(0.0, variation_ms))]
	if is_finite(reliable_loss_percent) and reliable_loss_percent >= 0:
		detail += " Reliable packet loss: %.1f%%." % clampf(reliable_loss_percent, 0.0, 100.0)
	if unstable or slow:
		detail += " Connection delays can slow shared actions. Compare another network to check the Wi-Fi."
	else:
		detail += " If movement looks choppy while ping stays low, check FPS and graphics settings."
	return {"visible": true, "text": text, "detail": detail, "warning": unstable or slow,
		"rtt_ms": rtt, "variation_ms": variation_ms, "reliable_loss_percent": reliable_loss_percent}
