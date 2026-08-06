extends Node
## Internet session + replication transport.
##
## ENet always uses a server-star topology. A playable host can still be used
## for local diagnostics, while production clients connect to a headless peer 1
## hosted on the public Internet. The server owns the roster, seed, collectibles
## and chest claims, validates bounded client payloads, and explicitly relays all
## client-to-client traffic.

signal roster_changed
signal world_ready
signal net_error(msg: String)
signal peer_state(id: int, pos: Vector3, yaw: float, vel: Vector3, anim: int,
	swinging: bool, anchor: Vector3, rope_tail: float,
	wraps: PackedVector3Array, weapon_kind: int, weapon_stowed: bool,
	melee_mode: bool, weapon_ammo: int, weapon_reloading: bool,
	healing_progress: float, flying: bool)
signal score_changed
signal banana_taken(id: String)
signal supply_chest_claimed(chest_id: String, claimant_id: int)
signal ook_from(id: int, pos: Vector3)
signal peer_left(id: int)
signal vine_released(id: String, hand: Vector3, velocity: Vector3, length: float,
	shape: PackedVector3Array)
signal bullet_fired(shooter_id: int, origin: Vector3, velocity: Vector3,
	damage: float, headshot_rule: bool, play_fx: bool, weapon_kind: int)
signal melee_swung(shooter_id: int, origin: Vector3, direction: Vector3,
	combo: int)
signal peer_defeated(id: int, pos: Vector3, yaw: float, velocity: Vector3,
	impulse: Vector3, headshot: bool)
signal voice_packet(speaker_id: int, sequence: int, payload: PackedByteArray)
signal chat_received(id: int, sender_name: String, text: String, from_admin: bool)
signal admin_changed(enabled: bool)
signal admin_action(action: String, args: Dictionary)

const PORT := 30623
const MAX_CLIENTS := 24
const CHANNEL_COUNT := 2
const PROTOCOL_VERSION := 4
const MAX_NAME_LENGTH := 20
const REGISTRATION_TIMEOUT_SECONDS := 5.0
const MAX_STATE_PACKETS_PER_SECOND := 30
const MAX_WORLD_COORDINATE := 1000000.0
const MAX_PLAYER_SPEED := 260.0
const MAX_WRAPS := 6
const MAX_COLLECTED_IDS := 200000
const MAX_CHEST_CLAIMS := 50000
const MAX_BANANA_ID_LENGTH := 48
const MAX_CHEST_ID_LENGTH := 64
const MAX_VOICE_PACKET_BYTES := VoiceCodec.MAX_PACKET_BYTES
const MAX_VOICE_SEQUENCE := 0x7fffffff
const MAX_CHAT_LENGTH := 200
const MAX_BAN_MINUTES := 40320  # 28 days
const BAN_FILE := "user://bans.json"
const ADMIN_ACTIONS := ["kick", "ban", "kill", "heal", "give_ammo",
	"teleport_to", "announce"]

const WEAPON_REVOLVER := 0
const WEAPON_SHOTGUN := 1
const WEAPON_SMG := 2
const WEAPON_SNIPER := 3

var active := false
var is_admin := false
var _admins: Dictionary = {}    # server: peer id -> true
var _bans: Dictionary = {}      # server: remote address -> {until, name}
var is_host := false
var is_dedicated := false
var local_name := "Monkey"
var world_seed := 0
var names: Dictionary = {}      # peer id -> display name (server is omitted)
var scores: Dictionary = {}     # peer id -> banana count
var collected: Dictionary = {}  # stable banana id -> true
var claimed_supply_chests: Dictionary = {} # stable chest id -> winning peer id

var _wired := false
var _registered: Dictionary = {}
var _rate_windows: Dictionary = {}
var _session_epoch := 0
var _cycle_anchor_hour := 12.0
var _cycle_anchor_ticks_msec := 0
var _cycle_initialized := false


func local_id() -> int:
	return multiplayer.get_unique_id() if active else 1


## The authority anchors a one-real-hour game day to its local civil time once,
## then all peers advance that phase from monotonic ticks. This avoids system
## clock corrections and client clock skew after the session has started.
func authoritative_cycle_hour() -> float:
	if not _cycle_initialized:
		_initialize_cycle_from_local_calendar()
	var elapsed_seconds := float(Time.get_ticks_msec() \
		- _cycle_anchor_ticks_msec) / 1000.0
	return SeasonalCycle.hour_after_elapsed(_cycle_anchor_hour, elapsed_seconds)


## Deterministic session/test fixture hook. Network clients cannot replace the
## server phase, and a host cannot move it after remote peers have registered.
func set_authoritative_cycle_hour(hour: float) -> bool:
	if not is_finite(hour) or (active and not is_host):
		return false
	if active and is_host:
		for peer_id in _registered:
			if int(peer_id) != 1:
				return false
	_anchor_authoritative_cycle(hour)
	return true


func _initialize_cycle_from_local_calendar() -> void:
	_anchor_authoritative_cycle(SeasonalCycle.local_hour_from_system())


func _anchor_authoritative_cycle(hour: float) -> void:
	_cycle_anchor_hour = wrapf(hour, 0.0, 24.0)
	_cycle_anchor_ticks_msec = Time.get_ticks_msec()
	_cycle_initialized = true


func effective_game_version() -> String:
	var updater := get_node_or_null("/root/Updater")
	if updater and updater.has_method("effective_version"):
		var patched := str(updater.call("effective_version"))
		if not patched.is_empty():
			return patched
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0"))


func _wire() -> void:
	if _wired:
		return
	_wired = true
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


## Playable host retained for loopback diagnostics and offline development.
func host(pname: String, seed_v: int, port := PORT) -> Error:
	_wire()
	_session_epoch += 1
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS, CHANNEL_COUNT)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	active = true
	is_host = true
	is_dedicated = false
	local_name = _sanitize_name(pname, 1)
	world_seed = seed_v
	names = {1: local_name}
	scores = {1: 0}
	collected = {}
	claimed_supply_chests = {}
	_registered = {1: true}
	_rate_windows = {}
	_admins = {}
	is_admin = true  # the listen host owns the machine running the session
	admin_changed.emit(true)
	_initialize_cycle_from_local_calendar()
	return OK


## Headless authority. Peer 1 never appears in the player roster or world.
func start_dedicated(seed_v: int, port := PORT, bind_ip := "*",
		max_clients := MAX_CLIENTS) -> Error:
	_wire()
	_session_epoch += 1
	var peer := ENetMultiplayerPeer.new()
	var resolved_bind := bind_ip.strip_edges()
	if resolved_bind.is_empty():
		resolved_bind = "*"
	elif resolved_bind != "*" and not resolved_bind.is_valid_ip_address():
		# Fly's public UDP proxy is IPv4-only and its special bind hostname must
		# resolve to the address used for both receive and reply traffic.
		var resolved := IP.resolve_hostname(resolved_bind, IP.TYPE_IPV4)
		if resolved.is_empty():
			return ERR_CANT_RESOLVE
		resolved_bind = resolved
	peer.set_bind_ip(resolved_bind)
	var err := peer.create_server(port, clampi(max_clients, 2, 256), CHANNEL_COUNT)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	active = true
	is_host = true
	is_dedicated = true
	local_name = "Dedicated Server"
	world_seed = seed_v
	names = {}
	scores = {}
	collected = {}
	claimed_supply_chests = {}
	_registered = {}
	_rate_windows = {}
	_load_bans()
	_initialize_cycle_from_local_calendar()
	return OK


func join(address: String, pname: String, port := PORT) -> Error:
	_wire()
	_session_epoch += 1
	var host_address := address.strip_edges()
	if host_address.is_empty():
		return ERR_INVALID_PARAMETER
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host_address, port, CHANNEL_COUNT)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	local_name = _sanitize_name(pname, 0)
	is_host = false
	is_dedicated = false
	active = false
	names = {}
	scores = {}
	collected = {}
	claimed_supply_chests = {}
	_registered = {}
	_rate_windows = {}
	_cycle_initialized = false
	return OK


func solo(pname: String, seed_v: int) -> void:
	_session_epoch += 1
	active = false
	is_host = false
	is_dedicated = false
	local_name = _sanitize_name(pname, 1)
	world_seed = seed_v
	names = {1: local_name}
	scores = {1: 0}
	collected = {}
	claimed_supply_chests = {}
	_registered = {}
	_rate_windows = {}
	_admins = {}
	is_admin = true  # offline sessions run on the player's own machine
	admin_changed.emit(true)
	_initialize_cycle_from_local_calendar()


func shutdown() -> void:
	_session_epoch += 1
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	active = false
	is_host = false
	is_dedicated = false
	_registered = {}
	_rate_windows = {}
	_cycle_initialized = false


func _on_connected() -> void:
	active = true
	is_admin = false
	rpc_id(1, "srv_register", local_name, PROTOCOL_VERSION,
		effective_game_version(), _client_admin_key())


## Admin access is a shared secret, never a display name: the client offers
## TROOP_ADMIN_KEY and the server compares it to its own TROOP_ADMIN_TOKEN.
func _client_admin_key() -> String:
	return OS.get_environment("TROOP_ADMIN_KEY").strip_edges().left(128)


func _server_admin_token() -> String:
	return OS.get_environment("TROOP_ADMIN_TOKEN").strip_edges().left(128)


func _peer_address(id: int) -> String:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if not enet:
		return ""
	var peer := enet.get_peer(id)
	return peer.get_remote_address() if peer else ""


func _ban_remaining_minutes(address: String) -> int:
	if address.is_empty() or not _bans.has(address):
		return 0
	var until := int(_bans[address].get("until", 0))
	var remaining := until - int(Time.get_unix_time_from_system())
	if remaining <= 0:
		_bans.erase(address)
		_save_bans()
		return 0
	return int(ceil(remaining / 60.0))


func _save_bans() -> void:
	var f := FileAccess.open(BAN_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_bans))


func _load_bans() -> void:
	_bans = {}
	if not FileAccess.file_exists(BAN_FILE):
		return
	var f := FileAccess.open(BAN_FILE, FileAccess.READ)
	if not f:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		_bans = parsed


func _on_connection_failed() -> void:
	active = false
	net_error.emit("connection failed")


func _on_server_disconnected() -> void:
	active = false
	net_error.emit("server disconnected")


func _on_peer_connected(id: int) -> void:
	# A socket that never completes the versioned registration handshake must not
	# occupy one of the public server's finite peer slots indefinitely.
	if is_host and id > 1:
		_enforce_registration_timeout(id, _session_epoch)


func _enforce_registration_timeout(id: int, epoch: int) -> void:
	await get_tree().create_timer(REGISTRATION_TIMEOUT_SECONDS).timeout
	if epoch != _session_epoch or not is_host or not multiplayer.multiplayer_peer \
			or _registered.has(id):
		return
	if multiplayer.get_peers().has(id):
		multiplayer.multiplayer_peer.disconnect_peer(id)


func _on_peer_disconnected(id: int) -> void:
	var was_registered := _registered.has(id) or names.has(id)
	_registered.erase(id)
	names.erase(id)
	scores.erase(id)
	_admins.erase(id)
	_clear_rate_windows(id)
	if is_host:
		rpc("cl_roster", names, scores)
	if was_registered:
		roster_changed.emit()
		peer_left.emit(id)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_register(pname: String, protocol: int, game_version: String,
		admin_key := "") -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if id <= 1 or _registered.has(id):
		return
	if protocol != PROTOCOL_VERSION:
		_reject_peer(id, "Game protocol mismatch. Update TROOP and try again.")
		return
	if game_version != effective_game_version():
		_reject_peer(id, "Server is running TROOP %s; your game is %s." % [
			effective_game_version(), game_version])
		return
	var ban_minutes := _ban_remaining_minutes(_peer_address(id))
	if ban_minutes > 0:
		_reject_peer(id, ("Temporarily banned from the public canopy for "
			+ "another %d minute%s. Solo play still works.") % [
			ban_minutes, "" if ban_minutes == 1 else "s"])
		return
	_registered[id] = true
	names[id] = _sanitize_name(pname, id)
	scores[id] = 0
	var token := _server_admin_token()
	if not token.is_empty() and not admin_key.is_empty() and admin_key == token:
		_admins[id] = true
		rpc_id(id, "cl_admin", true)
	rpc("cl_roster", names, scores)
	rpc_id(id, "cl_world", world_seed, collected.keys(),
		claimed_supply_chests, authoritative_cycle_hour(),
		effective_game_version())
	roster_changed.emit()


func _reject_peer(id: int, reason: String) -> void:
	rpc_id(id, "cl_rejected", reason)
	_disconnect_rejected_peer(id)


func _disconnect_rejected_peer(id: int) -> void:
	await get_tree().create_timer(0.25).timeout
	if is_host and multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.disconnect_peer(id)


@rpc("authority", "call_remote", "reliable", 0)
func cl_rejected(reason: String) -> void:
	net_error.emit(reason.left(180))
	call_deferred("shutdown")


@rpc("authority", "call_remote", "reliable", 0)
func cl_roster(new_names: Dictionary, new_scores: Dictionary) -> void:
	names = new_names
	scores = new_scores
	roster_changed.emit()
	score_changed.emit()


@rpc("authority", "call_remote", "reliable", 0)
func cl_world(seed_v: int, taken: Array, supply_claims: Dictionary,
		cycle_hour: float, _server_version: String) -> void:
	if not is_finite(cycle_hour):
		net_error.emit("server sent invalid day-cycle state")
		call_deferred("shutdown")
		return
	_anchor_authoritative_cycle(cycle_hour)
	world_seed = seed_v
	collected = {}
	for id in taken.slice(0, MAX_COLLECTED_IDS):
		var banana_id := str(id)
		if _valid_banana_id(banana_id):
			collected[banana_id] = true
	claimed_supply_chests = {}
	var copied := 0
	for chest_id in supply_claims:
		if copied >= MAX_CHEST_CLAIMS:
			break
		var stable_id := str(chest_id)
		if _valid_supply_chest_id(stable_id):
			claimed_supply_chests[stable_id] = int(supply_claims[chest_id])
			copied += 1
	world_ready.emit()


# ---- movement --------------------------------------------------------------

func send_state(pos: Vector3, yaw: float, vel: Vector3, anim: int,
		swinging: bool, anchor: Vector3, rope_tail: float,
		wraps: PackedVector3Array, weapon_kind: int, weapon_stowed: bool,
		melee_mode: bool, weapon_ammo: int, weapon_reloading: bool,
		healing_progress: float, flying := false) -> void:
	if not active:
		return
	if is_host:
		rpc("cl_state", local_id(), pos, yaw, vel, anim, swinging, anchor,
			rope_tail, wraps, weapon_kind, weapon_stowed, melee_mode,
			weapon_ammo, weapon_reloading, healing_progress, flying)
	else:
		rpc_id(1, "srv_state", pos, yaw, vel, anim, swinging, anchor,
			rope_tail, wraps, weapon_kind, weapon_stowed, melee_mode,
			weapon_ammo, weapon_reloading, healing_progress, flying)


@rpc("any_peer", "call_remote", "unreliable_ordered", 0)
func srv_state(pos: Vector3, yaw: float, vel: Vector3, anim: int,
		swinging: bool, anchor: Vector3, rope_tail: float,
		wraps: PackedVector3Array, weapon_kind: int, weapon_stowed: bool,
		melee_mode: bool, weapon_ammo: int, weapon_reloading: bool,
			healing_progress: float, flying := false) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_peer(sender) \
			or not _allow_rate(sender, "state", MAX_STATE_PACKETS_PER_SECOND) \
			or not _valid_state(pos, yaw, vel, anim,
			swinging, anchor, rope_tail, wraps, weapon_kind, weapon_ammo,
			healing_progress):
		return
	peer_state.emit(sender, pos, yaw, vel, anim, swinging, anchor, rope_tail,
		wraps, weapon_kind, weapon_stowed, melee_mode, weapon_ammo,
		weapon_reloading, healing_progress, flying)
	rpc("cl_state", sender, pos, yaw, vel, anim, swinging, anchor, rope_tail,
		wraps, weapon_kind, weapon_stowed, melee_mode, weapon_ammo,
		weapon_reloading, healing_progress, flying)


@rpc("authority", "call_remote", "unreliable_ordered", 0)
func cl_state(id: int, pos: Vector3, yaw: float, vel: Vector3, anim: int,
		swinging: bool, anchor: Vector3, rope_tail: float,
		wraps: PackedVector3Array, weapon_kind: int, weapon_stowed: bool,
		melee_mode: bool, weapon_ammo: int, weapon_reloading: bool,
		healing_progress: float, flying := false) -> void:
	if id == local_id() or not names.has(id):
		return
	if not _valid_state(pos, yaw, vel, anim, swinging, anchor, rope_tail,
			wraps, weapon_kind, weapon_ammo, healing_progress):
		return
	peer_state.emit(id, pos, yaw, vel, anim, swinging, anchor, rope_tail,
		wraps, weapon_kind, weapon_stowed, melee_mode, weapon_ammo,
		weapon_reloading, healing_progress, flying)


# ---- collectibles and shared world state ----------------------------------

func try_collect(id: String) -> void:
	if collected.has(id) or not _valid_banana_id(id):
		return
	if not active:
		_apply_collect(id, 1)
	elif is_host:
		_host_collect(id, local_id())
	else:
		rpc_id(1, "srv_collect", id)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_collect(id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if _registered_peer(sender) and _allow_rate(sender, "collect", 12):
		_host_collect(id, sender)


func _host_collect(id: String, by: int) -> void:
	if not _valid_banana_id(id) or collected.has(id) or not names.has(by) \
			or collected.size() >= MAX_COLLECTED_IDS:
		return
	_apply_collect(id, by)
	rpc("cl_collect", id, by)


@rpc("authority", "call_remote", "reliable", 0)
func cl_collect(id: String, by: int) -> void:
	if names.has(by):
		_apply_collect(id, by)


func _apply_collect(id: String, by: int) -> void:
	if not _valid_banana_id(id) or collected.has(id) \
			or collected.size() >= MAX_COLLECTED_IDS:
		return
	collected[id] = true
	scores[by] = int(scores.get(by, 0)) + 1
	banana_taken.emit(id)
	score_changed.emit()


func request_supply_chest(chest_id: String) -> bool:
	if not _valid_supply_chest_id(chest_id) or claimed_supply_chests.has(chest_id):
		return false
	if not active:
		_apply_supply_chest_claim(chest_id, local_id())
		return true
	if is_host:
		return _host_claim_supply_chest(chest_id, local_id())
	rpc_id(1, "srv_request_supply_chest", chest_id)
	return true


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_request_supply_chest(chest_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if _registered_peer(sender) and _allow_rate(sender, "supply", 8):
		_host_claim_supply_chest(chest_id, sender)


func _host_claim_supply_chest(chest_id: String, claimant_id: int) -> bool:
	if not _valid_supply_chest_id(chest_id) or not names.has(claimant_id) \
			or (not claimed_supply_chests.has(chest_id) \
			and claimed_supply_chests.size() >= MAX_CHEST_CLAIMS):
		return false
	if claimed_supply_chests.has(chest_id):
		if claimant_id != local_id():
			rpc_id(claimant_id, "cl_supply_chest_claimed", chest_id,
				int(claimed_supply_chests[chest_id]))
		return false
	claimed_supply_chests[chest_id] = claimant_id
	supply_chest_claimed.emit(chest_id, claimant_id)
	rpc("cl_supply_chest_claimed", chest_id, claimant_id)
	return true


@rpc("authority", "call_remote", "reliable", 0)
func cl_supply_chest_claimed(chest_id: String, claimant_id: int) -> void:
	_apply_supply_chest_claim(chest_id, claimant_id)


func _apply_supply_chest_claim(chest_id: String, claimant_id: int) -> void:
	if not _valid_supply_chest_id(chest_id) \
			or claimed_supply_chests.has(chest_id) \
			or claimed_supply_chests.size() >= MAX_CHEST_CLAIMS:
		return
	claimed_supply_chests[chest_id] = claimant_id
	supply_chest_claimed.emit(chest_id, claimant_id)


# ---- vines and emotes ------------------------------------------------------

func vine_state(id: String, hidden: bool) -> void:
	if not _valid_vine_id(id):
		return
	Gen.set_vine_hidden(id, hidden)
	if not active:
		return
	if is_host:
		_relay_vine_state(local_id(), id, hidden)
	else:
		rpc_id(1, "srv_vine_state", id, hidden)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_vine_state(id: String, hidden: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if _registered_peer(sender) and _valid_vine_id(id) \
			and _allow_rate(sender, "vine", 20):
		if not is_dedicated:
			Gen.set_vine_hidden(id, hidden)
		_relay_vine_state(sender, id, hidden)


func _relay_vine_state(sender: int, id: String, hidden: bool) -> void:
	for peer_id in names:
		if peer_id != 1 and peer_id != sender:
			rpc_id(peer_id, "cl_vine_state", id, hidden)


@rpc("authority", "call_remote", "reliable", 0)
func cl_vine_state(id: String, hidden: bool) -> void:
	if _valid_vine_id(id):
		Gen.set_vine_hidden(id, hidden)


func vine_release(id: String, hand: Vector3, velocity: Vector3, length: float,
		shape: PackedVector3Array) -> void:
	if not _valid_vine_release(id, hand, velocity, length, shape):
		return
	vine_released.emit(id, hand, velocity, length, shape)
	if not active:
		return
	if is_host:
		_relay_vine_release(local_id(), id, hand, velocity, length, shape)
	else:
		rpc_id(1, "srv_vine_release", id, hand, velocity, length, shape)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_vine_release(id: String, hand: Vector3, velocity: Vector3,
		length: float, shape: PackedVector3Array) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_peer(sender) or not _allow_rate(sender, "vine_release", 8) \
			or not _valid_vine_release(id, hand, velocity, length, shape):
		return
	if not is_dedicated:
		vine_released.emit(id, hand, velocity, length, shape)
	_relay_vine_release(sender, id, hand, velocity, length, shape)


func _relay_vine_release(sender: int, id: String, hand: Vector3,
		velocity: Vector3, length: float, shape: PackedVector3Array) -> void:
	for peer_id in names:
		if peer_id != 1 and peer_id != sender:
			rpc_id(peer_id, "cl_vine_release", id, hand, velocity, length, shape)


@rpc("authority", "call_remote", "reliable", 0)
func cl_vine_release(id: String, hand: Vector3, velocity: Vector3,
		length: float, shape: PackedVector3Array) -> void:
	if _valid_vine_release(id, hand, velocity, length, shape):
		vine_released.emit(id, hand, velocity, length, shape)


func send_ook(pos: Vector3) -> void:
	if not active or not _finite_vec(pos):
		return
	if is_host:
		_relay_ook(local_id(), pos)
	else:
		rpc_id(1, "srv_ook", pos)


@rpc("any_peer", "call_remote", "unreliable", 0)
func srv_ook(pos: Vector3) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_peer(sender) or not _finite_vec(pos) \
			or not _allow_rate(sender, "ook", 4):
		return
	if not is_dedicated:
		ook_from.emit(sender, pos)
	_relay_ook(sender, pos)


func _relay_ook(sender: int, pos: Vector3) -> void:
	for peer_id in names:
		if peer_id != 1 and peer_id != sender:
			rpc_id(peer_id, "cl_ook", sender, pos)


@rpc("authority", "call_remote", "unreliable", 0)
func cl_ook(sender: int, pos: Vector3) -> void:
	if names.has(sender) and _finite_vec(pos):
		ook_from.emit(sender, pos)


# ---- combat ---------------------------------------------------------------

func fire_bullet(origin: Vector3, velocity: Vector3,
		_damage := BananaBullet.DAMAGE, _headshot_rule := true,
		play_fx := true, weapon_kind := WEAPON_REVOLVER) -> void:
	if not active or not _valid_bullet(origin, velocity, weapon_kind):
		return
	var canonical := _weapon_rules(weapon_kind)
	bullet_fired.emit(local_id(), origin, velocity, canonical.damage,
		canonical.headshot, play_fx, weapon_kind)
	if is_host:
		_relay_bullet(local_id(), origin, velocity, play_fx, weapon_kind)
	else:
		rpc_id(1, "srv_fire_bullet", origin, velocity, play_fx, weapon_kind)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_fire_bullet(origin: Vector3, velocity: Vector3, play_fx: bool,
		weapon_kind: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_peer(sender) or not _allow_rate(sender, "bullet", 80) \
			or not _valid_bullet(origin, velocity, weapon_kind):
		return
	var canonical := _weapon_rules(weapon_kind)
	if not is_dedicated:
		bullet_fired.emit(sender, origin, velocity, canonical.damage,
			canonical.headshot, play_fx, weapon_kind)
	_relay_bullet(sender, origin, velocity, play_fx, weapon_kind)


func _relay_bullet(sender: int, origin: Vector3, velocity: Vector3,
		play_fx: bool, weapon_kind: int) -> void:
	for peer_id in names:
		if peer_id != 1 and peer_id != sender:
			rpc_id(peer_id, "cl_fire_bullet", sender, origin, velocity, play_fx,
				weapon_kind)


@rpc("authority", "call_remote", "reliable", 0)
func cl_fire_bullet(shooter_id: int, origin: Vector3, velocity: Vector3,
		play_fx: bool, weapon_kind: int) -> void:
	if not names.has(shooter_id) or not _valid_bullet(origin, velocity, weapon_kind):
		return
	var canonical := _weapon_rules(weapon_kind)
	bullet_fired.emit(shooter_id, origin, velocity, canonical.damage,
		canonical.headshot, play_fx, weapon_kind)


func melee_attack(origin: Vector3, direction: Vector3, combo: int) -> void:
	if not active or not _valid_melee(origin, direction, combo):
		return
	var normalized := direction.normalized()
	melee_swung.emit(local_id(), origin, normalized, combo)
	if is_host:
		_relay_melee(local_id(), origin, normalized, combo)
	else:
		rpc_id(1, "srv_melee_attack", origin, normalized, combo)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_melee_attack(origin: Vector3, direction: Vector3, combo: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_peer(sender) or not _allow_rate(sender, "melee", 8) \
			or not _valid_melee(origin, direction, combo):
		return
	var normalized := direction.normalized()
	if not is_dedicated:
		melee_swung.emit(sender, origin, normalized, combo)
	_relay_melee(sender, origin, normalized, combo)


func _relay_melee(sender: int, origin: Vector3, direction: Vector3,
		combo: int) -> void:
	for peer_id in names:
		if peer_id != 1 and peer_id != sender:
			rpc_id(peer_id, "cl_melee_attack", sender, origin, direction, combo)


@rpc("authority", "call_remote", "reliable", 0)
func cl_melee_attack(shooter_id: int, origin: Vector3, direction: Vector3,
		combo: int) -> void:
	if names.has(shooter_id) and _valid_melee(origin, direction, combo):
		melee_swung.emit(shooter_id, origin, direction.normalized(), combo)


func send_defeat(pos: Vector3, yaw: float, velocity: Vector3,
		impulse: Vector3, headshot: bool) -> void:
	if not active or not _valid_defeat(pos, yaw, velocity, impulse):
		return
	if is_host:
		_relay_defeat(local_id(), pos, yaw, velocity, impulse, headshot)
	else:
		rpc_id(1, "srv_defeat", pos, yaw, velocity, impulse, headshot)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_defeat(pos: Vector3, yaw: float, velocity: Vector3,
		impulse: Vector3, headshot: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_peer(sender) or not _allow_rate(sender, "defeat", 4) \
			or not _valid_defeat(pos, yaw, velocity, impulse):
		return
	if not is_dedicated:
		peer_defeated.emit(sender, pos, yaw, velocity, impulse, headshot)
	_relay_defeat(sender, pos, yaw, velocity, impulse, headshot)


func _relay_defeat(sender: int, pos: Vector3, yaw: float, velocity: Vector3,
		impulse: Vector3, headshot: bool) -> void:
	for peer_id in names:
		if peer_id != 1 and peer_id != sender:
			rpc_id(peer_id, "cl_defeat", sender, pos, yaw, velocity, impulse,
				headshot)


@rpc("authority", "call_remote", "reliable", 0)
func cl_defeat(defeated_id: int, pos: Vector3, yaw: float, velocity: Vector3,
		impulse: Vector3, headshot: bool) -> void:
	if names.has(defeated_id) and _valid_defeat(pos, yaw, velocity, impulse):
		peer_defeated.emit(defeated_id, pos, yaw, velocity, impulse, headshot)


# ---- push-to-talk voice (isolated unreliable channel 1) -------------------

func send_voice(sequence: int, payload: PackedByteArray) -> void:
	if not active or sequence < 0 or sequence > MAX_VOICE_SEQUENCE \
			or payload.is_empty() or payload.size() > MAX_VOICE_PACKET_BYTES \
			or not VoiceCodec.is_valid_packet(payload):
		return
	if is_host:
		_relay_voice(local_id(), sequence, payload)
	else:
		rpc_id(1, "srv_voice", sequence, payload)


@rpc("any_peer", "call_remote", "unreliable", 1)
func srv_voice(sequence: int, payload: PackedByteArray) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_peer(sender) or sequence < 0 \
			or sequence > MAX_VOICE_SEQUENCE \
			or payload.is_empty() or payload.size() > MAX_VOICE_PACKET_BYTES \
			or not _allow_rate(sender, "voice", 60) \
			or not VoiceCodec.is_valid_packet(payload):
		return
	if not is_dedicated:
		voice_packet.emit(sender, sequence, payload)
	_relay_voice(sender, sequence, payload)


func _relay_voice(sender: int, sequence: int, payload: PackedByteArray) -> void:
	for peer_id in names:
		if peer_id != 1 and peer_id != sender:
			rpc_id(peer_id, "cl_voice", sender, sequence, payload)


@rpc("authority", "call_remote", "unreliable", 1)
func cl_voice(speaker_id: int, sequence: int, payload: PackedByteArray) -> void:
	# Voice uses a separate ENet channel, so it can legitimately arrive just
	# before the reliable roster update that introduces its registered speaker.
	# Only authority can call this RPC; the server already binds speaker_id to
	# the authenticated sender, so do not discard that cross-channel race.
	if speaker_id > 1 and speaker_id != local_id() and sequence >= 0 \
			and sequence <= MAX_VOICE_SEQUENCE and not payload.is_empty() \
			and payload.size() <= MAX_VOICE_PACKET_BYTES \
			and VoiceCodec.is_valid_packet(payload):
		voice_packet.emit(speaker_id, sequence, payload)


# ---- text chat and admin control ------------------------------------------


func send_chat(text: String) -> void:
	var clean := _sanitize_chat(text)
	if clean.is_empty():
		return
	if not active:
		chat_received.emit(local_id(), local_name, clean, is_admin)
		return
	if is_host:
		chat_received.emit(1, local_name, clean, is_admin)
		_relay_chat(1, local_name, clean, is_admin)
	else:
		# The server relays to everyone except the sender, so the sender's own
		# message must echo locally or their chat looks dead.
		chat_received.emit(local_id(), local_name, clean, is_admin)
		rpc_id(1, "srv_chat", clean)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_chat(text: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_peer(sender) or not _allow_rate(sender, "chat", 3):
		return
	var clean := _sanitize_chat(text)
	if clean.is_empty():
		return
	var sender_name: String = names.get(sender, "Monkey-%d" % sender)
	var from_admin := _admins.has(sender)
	if not is_dedicated:
		chat_received.emit(sender, sender_name, clean, from_admin)
	_relay_chat(sender, sender_name, clean, from_admin)


func _relay_chat(sender: int, sender_name: String, text: String,
		from_admin: bool) -> void:
	for peer_id in names:
		if peer_id != 1 and peer_id != sender:
			rpc_id(peer_id, "cl_chat", sender, sender_name, text, from_admin)


@rpc("authority", "call_remote", "reliable", 0)
func cl_chat(id: int, sender_name: String, text: String,
		from_admin: bool) -> void:
	var clean := _sanitize_chat(text)
	if clean.is_empty() or id == local_id():
		return
	chat_received.emit(id, _sanitize_name(sender_name, id), clean, from_admin)


func _sanitize_chat(text: String) -> String:
	var out := ""
	for character in text.left(MAX_CHAT_LENGTH):
		var code := character.unicode_at(0)
		if code >= 32 and code != 127:
			out += character
	return out.strip_edges()


## Entry point for every admin verb. Offline the machine owner applies the
## action directly; online only a token-authenticated admin can ask the server,
## and the server re-validates before touching any other peer.
func admin_command(action: String, args: Dictionary) -> void:
	if not is_admin or not ADMIN_ACTIONS.has(action):
		return
	if not active:
		admin_action.emit(action, args)
		return
	if is_host:
		_host_admin(1, action, args)
	else:
		rpc_id(1, "srv_admin", action, args)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_admin(action: String, args: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_peer(sender) or not _admins.has(sender) \
			or not _allow_rate(sender, "admin", 8):
		return
	_host_admin(sender, action, args)


func _host_admin(sender: int, action: String, args: Dictionary) -> void:
	if not ADMIN_ACTIONS.has(action):
		return
	var target := int(args.get("target", 0))
	match action:
		"kick":
			if names.has(target) and target != 1 and target != sender:
				rpc_id(target, "cl_kicked",
					_sanitize_chat(str(args.get("reason", "Kicked by admin"))))
				_disconnect_rejected_peer(target)
		"ban":
			if names.has(target) and target != 1 and target != sender:
				var minutes := clampi(int(args.get("minutes", 60)), 1,
					MAX_BAN_MINUTES)
				var address := _peer_address(target)
				if not address.is_empty():
					_bans[address] = {
						"until": int(Time.get_unix_time_from_system())
							+ minutes * 60,
						"name": names.get(target, ""),
					}
					_save_bans()
				rpc_id(target, "cl_kicked",
					"Temporarily banned from the public canopy for %d minutes. "
					% minutes + "Solo play still works.")
				_disconnect_rejected_peer(target)
		"announce":
			var text := _sanitize_chat(str(args.get("text", "")))
			if not text.is_empty():
				if not is_dedicated:
					chat_received.emit(1, "SERVER", text, true)
				_relay_chat(0, "SERVER", text, true)
		_:
			# Player-directed actions apply on the target's own authoritative
			# machine; the payload is whitelisted and bounds-checked there too.
			if names.has(target):
				if target == local_id() and not is_dedicated:
					admin_action.emit(action, args)
				else:
					rpc_id(target, "cl_admin_apply", action, args)


@rpc("authority", "call_remote", "reliable", 0)
func cl_admin_apply(action: String, args: Dictionary) -> void:
	if ADMIN_ACTIONS.has(action):
		admin_action.emit(action, args)


@rpc("authority", "call_remote", "reliable", 0)
func cl_admin(enabled: bool) -> void:
	is_admin = enabled
	admin_changed.emit(enabled)


@rpc("authority", "call_remote", "reliable", 0)
func cl_kicked(reason: String) -> void:
	net_error.emit(_sanitize_chat(reason).left(180))
	call_deferred("shutdown")


# ---- validation ------------------------------------------------------------

func _registered_peer(id: int) -> bool:
	return is_host and id > 1 and _registered.has(id) and names.has(id)


func _sanitize_name(value: String, id: int) -> String:
	var cleaned := value.strip_edges().replace("\n", " ").replace("\r", " ") \
		.replace("\t", " ")
	while cleaned.contains("  "):
		cleaned = cleaned.replace("  ", " ")
	cleaned = cleaned.substr(0, MAX_NAME_LENGTH).strip_edges()
	return cleaned if not cleaned.is_empty() else "Monkey-%d" % maxi(id, 1)


func _valid_state(pos: Vector3, yaw: float, vel: Vector3, anim: int,
		_swinging: bool, anchor: Vector3, rope_tail: float,
		wraps: PackedVector3Array, weapon_kind: int, weapon_ammo: int,
		healing_progress: float) -> bool:
	if not _finite_vec(pos) or not _finite_vec(vel) or not is_finite(yaw) \
			or not is_finite(rope_tail) or not is_finite(healing_progress):
		return false
	if _outside_world(pos) or vel.length() > MAX_PLAYER_SPEED or anim < 0 \
			or anim > 32 or weapon_kind < WEAPON_REVOLVER \
			or weapon_kind > WEAPON_SNIPER or weapon_ammo < 0 \
			or weapon_ammo > 999 or healing_progress < 0.0 \
			or healing_progress > 1.001 or rope_tail < 0.0 or rope_tail > 300.0:
		return false
	if wraps.size() > MAX_WRAPS:
		return false
	if _swinging and (not _finite_vec(anchor) or _outside_world(anchor)):
		return false
	for point in wraps:
		if not _finite_vec(point) or _outside_world(point):
			return false
	return true


func _valid_banana_id(id: String) -> bool:
	return _valid_stable_id(id, "b:", MAX_BANANA_ID_LENGTH)


func _valid_supply_chest_id(chest_id: String) -> bool:
	return _valid_stable_id(chest_id, "s:", MAX_CHEST_ID_LENGTH)


func _valid_stable_id(id: String, prefix: String, maximum_length: int) -> bool:
	var length := id.length()
	if length < 5 or length > maximum_length or not id.begins_with(prefix) \
			or id.to_utf8_buffer().size() != length:
		return false
	var separator := id.find("#", prefix.length())
	if separator <= prefix.length() or separator >= length - 1 \
			or id.find("#", separator + 1) >= 0:
		return false
	for i in range(prefix.length(), length):
		var code := id.unicode_at(i)
		var allowed := (code >= 48 and code <= 57) \
			or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) \
			or code in [35, 44, 45, 95] # # , - _
		if not allowed:
			return false
	return true


func _valid_vine_id(id: String) -> bool:
	return not id.is_empty() and id.length() <= 96 and id.contains("#")


func _valid_vine_release(id: String, hand: Vector3, velocity: Vector3,
		length: float, shape: PackedVector3Array) -> bool:
	if not _valid_vine_id(id) or not _finite_vec(hand) or not _finite_vec(velocity) \
			or not is_finite(length) or length < 0.2 or length > 160.0 \
			or shape.size() > 96 or velocity.length() > MAX_PLAYER_SPEED:
		return false
	for point in shape:
		if not _finite_vec(point) or _outside_world(point):
			return false
	return true


func _valid_bullet(origin: Vector3, velocity: Vector3, weapon_kind: int) -> bool:
	return _finite_vec(origin) and _finite_vec(velocity) \
		and not _outside_world(origin) and velocity.length() >= 10.0 \
		and velocity.length() <= 260.0 and weapon_kind >= WEAPON_REVOLVER \
		and weapon_kind <= WEAPON_SNIPER


func _weapon_rules(weapon_kind: int) -> Dictionary:
	match weapon_kind:
		WEAPON_SHOTGUN:
			return {"damage": 15.0, "headshot": false}
		WEAPON_SMG:
			return {"damage": 9.0, "headshot": false}
		WEAPON_SNIPER:
			return {"damage": 85.0, "headshot": true}
		_:
			return {"damage": 34.0, "headshot": true}


func _valid_melee(origin: Vector3, direction: Vector3, combo: int) -> bool:
	return _finite_vec(origin) and _finite_vec(direction) \
		and not _outside_world(origin) and direction.length_squared() > 0.25 \
		and direction.length_squared() < 2.25 and combo >= 0 and combo <= 2


func _valid_defeat(pos: Vector3, yaw: float, velocity: Vector3,
		impulse: Vector3) -> bool:
	return _finite_vec(pos) and _finite_vec(velocity) and _finite_vec(impulse) \
		and is_finite(yaw) and not _outside_world(pos) \
		and velocity.length() <= MAX_PLAYER_SPEED and impulse.length() <= 180.0


func _finite_vec(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _outside_world(value: Vector3) -> bool:
	return absf(value.x) > MAX_WORLD_COORDINATE \
		or absf(value.y) > MAX_WORLD_COORDINATE \
		or absf(value.z) > MAX_WORLD_COORDINATE


func _allow_rate(id: int, lane: String, limit: int,
		window_msec := 1000) -> bool:
	var now := Time.get_ticks_msec()
	var key := "%d:%s" % [id, lane]
	var bucket: Array = _rate_windows.get(key, [now, 0])
	if now - int(bucket[0]) >= window_msec:
		bucket = [now, 0]
	if int(bucket[1]) >= limit:
		_rate_windows[key] = bucket
		return false
	bucket[1] = int(bucket[1]) + 1
	_rate_windows[key] = bucket
	return true


func _clear_rate_windows(id: int) -> void:
	var prefix := "%d:" % id
	for key in _rate_windows.keys():
		if str(key).begins_with(prefix):
			_rate_windows.erase(key)
