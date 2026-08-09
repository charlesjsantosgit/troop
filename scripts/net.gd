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
	healing_progress: float, flying: bool, vehicle_kind: int,
	vehicle_id: String, vehicle_aux: Vector3)
signal vehicle_claimed(vehicle_id: String, claimant_id: int)
signal vehicle_released(vehicle_id: String, rest: Array)
signal vehicle_spawn_registered(vehicle_id: String, vehicle_kind: int,
	position: Vector3, yaw: float)
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
signal admin_roster_changed
signal admin_notice(message: String)
signal admin_action(action: String, args: Dictionary)
signal cycle_hour_changed(hour: float)

const PORT := 30623
const MAX_CLIENTS := 24
const CHANNEL_COUNT := 2
const PROTOCOL_VERSION := 6
const MAX_NAME_LENGTH := 20
const REGISTRATION_TIMEOUT_SECONDS := 5.0
const MAX_STATE_PACKETS_PER_SECOND := 30
const MAX_WORLD_COORDINATE := 1000000.0
# The fighter jet tops out at ~313 m/s (700 mph); leave validation headroom.
const MAX_PLAYER_SPEED := 340.0
# This is an ingress sanity envelope, not gameplay terminal velocity. A fall
# across the complete +/-1,000,000 m world cannot physically reach 6,500 m/s
# under 9.81 m/s^2 gravity, even if it begins at MAX_PLAYER_SPEED.
const MAX_ON_FOOT_FALL_REPLICATION_SPEED := 6500.0
const MAX_WRAPS := 6
const MAX_COLLECTED_IDS := 200000
const MAX_CHEST_CLAIMS := 50000
const MAX_BANANA_ID_LENGTH := 48
const MAX_CHEST_ID_LENGTH := 64
const MAX_VEHICLE_ID_LENGTH := 48
const MAX_VEHICLE_CLAIMS := 4096
const MAX_VEHICLE_KIND := 3
const MAX_ADMIN_VEHICLE_SERIAL := 1000000000
const VEHICLE_CLAIM_DISTANCE := 7.5
const ADMIN_VEHICLE_SPAWN_DISTANCE := 12.0
const VEHICLE_RELEASE_POSITION_TOLERANCE := 64.0
const MAX_VOICE_PACKET_BYTES := VoiceCodec.MAX_PACKET_BYTES
const MAX_VOICE_SEQUENCE := 0x7fffffff
const MAX_CHAT_LENGTH := 200
const MAX_BAN_MINUTES := 40320  # 28 days
const MAX_ADMIN_KEYS := 256
const MAX_ADMIN_GRANT_FILE_BYTES := 20000
const MAX_ADMIN_PUBLIC_KEY_BYTES := 4096
const MAX_ADMIN_PRIVATE_KEY_BYTES := 10000
const MAX_ADMIN_SIGNATURE_BYTES := 512
const ADMIN_NONCE_BYTES := 32
const ADMIN_BOOTSTRAP_PROOF_BYTES := 32
const ADMIN_GRANT_UNCHANGED := 0
const ADMIN_GRANT_UPDATED := 1
const ADMIN_GRANT_STORAGE_ERROR := -1
const BAN_FILE_NAME := "bans.json"
const ADMIN_GRANT_FILE_NAME := "admin_grants.json"
const ADMIN_IDENTITY_KEY_FILE := "user://admin_identity.key"
const ADMIN_IDENTITY_SECRET_FILE := "user://admin_identity_secret.txt"
const ADMIN_KEY_FINGERPRINT_DOMAIN := "TROOP/admin-public-key/v1:"
const ADMIN_PROOF_DOMAIN := "TROOP/admin-registration-proof/v1"
const ADMIN_KEY_STORAGE_DOMAIN := "TROOP/admin-key-storage/v1:"
const PLAYER_ADMIN_ACTIONS := ["kill", "heal", "give_ammo", "teleport_to"]
const ADMIN_ACTIONS := ["kick", "ban", "kill", "heal", "give_ammo",
	"teleport_to", "announce", "grant_admin", "revoke_admin", "set_time",
	"clear_time"]
const ADMIN_ARG_KEYS := {
	"kick": ["target", "reason"],
	"ban": ["target", "minutes"],
	"kill": ["target"],
	"heal": ["target"],
	"give_ammo": ["target", "kind", "amount"],
	"teleport_to": ["target", "position"],
	"announce": ["text"],
	"grant_admin": ["target"],
	"revoke_admin": ["target"],
	"set_time": ["hour"],
	"clear_time": [],
}

const WEAPON_REVOLVER := 0
const WEAPON_SHOTGUN := 1
const WEAPON_SMG := 2
const WEAPON_SNIPER := 3

var active := false
var is_admin := false
var _admins: Dictionary = {}    # server: peer id -> true
var admin_peers: Dictionary = {} # public peer ids only; never key material
var _peer_key_fingerprints: Dictionary = {} # server: peer id -> SHA-256 id
var _admin_key_fingerprints: Dictionary = {} # server: public-key fingerprint -> true
var _pending_registrations: Dictionary = {} # server: one-time challenge context
var _client_identity_key: CryptoKey
var _client_registration_challenge_used := false
var _bans: Dictionary = {}      # server: remote address -> {until, name}
var is_host := false
var is_dedicated := false
var local_name := "Monkey"
var world_seed := 0
var names: Dictionary = {}      # peer id -> display name (server is omitted)
var scores: Dictionary = {}     # peer id -> banana count
var collected: Dictionary = {}  # stable banana id -> true
var claimed_supply_chests: Dictionary = {} # stable chest id -> winning peer id
var claimed_vehicles: Dictionary = {}   # stable vehicle id -> driving peer id
var vehicle_rests: Dictionary = {}      # vehicle id -> [pos, yaw, pitch, roll]
var vehicle_spawn_definitions: Dictionary = {} # authority-broadcast dynamic defs
var _vehicle_kinds: Dictionary = {}     # authority: trusted stable id -> kind
var _admin_vehicle_creators: Dictionary = {} # admin-delivered id -> creator peer
var _peer_on_foot_positions: Dictionary = {} # authority: peer -> latest on-foot pos
var _vehicle_positions: Dictionary = {} # authority: id -> spawn/rest/live pos

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


## Re-anchor the server-owned one-hour clock and deliver the same phase to every
## active world. This is intentionally separate from the fixture-only setter
## above: only the validated admin RPC path may move a live populated session.
func _set_shared_cycle_hour(hour: float, broadcast := true) -> bool:
	if not is_host or not is_finite(hour):
		return false
	_anchor_authoritative_cycle(hour)
	cycle_hour_changed.emit(_cycle_anchor_hour)
	if broadcast and active and multiplayer.multiplayer_peer:
		rpc("cl_cycle_hour", _cycle_anchor_hour)
	return true


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
	claimed_vehicles = {}
	vehicle_rests = {}
	vehicle_spawn_definitions = {}
	_vehicle_kinds = {}
	_admin_vehicle_creators = {}
	_peer_on_foot_positions = {}
	_vehicle_positions = {}
	_registered = {1: true}
	_pending_registrations = {}
	_rate_windows = {}
	_admins = {}
	_peer_key_fingerprints = {}
	_load_admin_grants()
	admin_peers = {1: true}
	is_admin = true  # the listen host owns the machine running the session
	admin_changed.emit(true)
	admin_roster_changed.emit()
	_initialize_cycle_from_local_calendar()
	return OK


## Headless authority. Peer 1 never appears in the player roster or world.
func start_dedicated(seed_v: int, port := PORT, bind_ip := "*",
		max_clients := MAX_CLIENTS) -> Error:
	_wire()
	_session_epoch += 1
	# A dedicated authority has no World node to stream trusted spawn definitions.
	# Prepare the same deterministic generator clients use so claims can be
	# resolved from the server's seed instead of trusting client-authored ids.
	Gen.debug_world = false
	Gen.setup(seed_v)
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
	claimed_vehicles = {}
	vehicle_rests = {}
	vehicle_spawn_definitions = {}
	_vehicle_kinds = {}
	_admin_vehicle_creators = {}
	_peer_on_foot_positions = {}
	_vehicle_positions = {}
	_registered = {}
	_pending_registrations = {}
	_rate_windows = {}
	_admins = {}
	_peer_key_fingerprints = {}
	_load_admin_grants()
	admin_peers = {}
	is_admin = false
	_load_bans()
	_initialize_cycle_from_local_calendar()
	return OK


func join(address: String, pname: String, port := PORT) -> Error:
	_wire()
	_session_epoch += 1
	var host_address := address.strip_edges()
	if host_address.is_empty():
		return ERR_INVALID_PARAMETER
	_client_identity_key = _load_or_create_identity_key()
	if not _client_identity_key:
		return ERR_CANT_CREATE
	_client_registration_challenge_used = false
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
	claimed_vehicles = {}
	vehicle_rests = {}
	vehicle_spawn_definitions = {}
	_vehicle_kinds = {}
	_admin_vehicle_creators = {}
	_peer_on_foot_positions = {}
	_vehicle_positions = {}
	_registered = {}
	_pending_registrations = {}
	_rate_windows = {}
	_admins = {}
	_peer_key_fingerprints = {}
	_admin_key_fingerprints = {}
	admin_peers = {}
	is_admin = false
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
	claimed_vehicles = {}
	vehicle_rests = {}
	vehicle_spawn_definitions = {}
	_vehicle_kinds = {}
	_admin_vehicle_creators = {}
	_peer_on_foot_positions = {}
	_vehicle_positions = {}
	_registered = {}
	_pending_registrations = {}
	_rate_windows = {}
	_admins = {}
	_peer_key_fingerprints = {}
	_admin_key_fingerprints = {}
	_client_identity_key = null
	_client_registration_challenge_used = false
	admin_peers = {1: true}
	is_admin = true  # offline sessions run on the player's own machine
	admin_changed.emit(true)
	admin_roster_changed.emit()
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
	_pending_registrations = {}
	_rate_windows = {}
	_vehicle_kinds = {}
	_admin_vehicle_creators = {}
	vehicle_spawn_definitions = {}
	_peer_on_foot_positions = {}
	_vehicle_positions = {}
	_admins = {}
	_peer_key_fingerprints = {}
	_admin_key_fingerprints = {}
	_client_identity_key = null
	_client_registration_challenge_used = false
	admin_peers = {}
	if is_admin:
		is_admin = false
		admin_changed.emit(false)
	admin_roster_changed.emit()
	_cycle_initialized = false


func _on_connected() -> void:
	active = true
	is_admin = false
	if not _client_identity_key:
		net_error.emit("Could not load this installation's admin identity.")
		call_deferred("shutdown")
		return
	var public_key_pem := _client_identity_key.save_to_string(true)
	if _parse_public_identity(public_key_pem).is_empty():
		net_error.emit("Could not prepare this installation's admin identity.")
		call_deferred("shutdown")
		return
	rpc_id(1, "srv_begin_register", local_name, PROTOCOL_VERSION,
		effective_game_version(), public_key_pem)


## The bootstrap secret is never transmitted. It is used only as the HMAC key
## for the server's fresh registration challenge.
func _client_admin_bootstrap_secret() -> String:
	return OS.get_environment("TROOP_ADMIN_KEY").strip_edges().left(128)


func _server_admin_token() -> String:
	return OS.get_environment("TROOP_ADMIN_TOKEN").strip_edges().left(128)


## A generated RSA private key stays in user:// for this installation. Only its
## public half is sent. This deliberately avoids collecting MAC addresses or
## any other hardware identifier.
func _load_or_create_identity_key() -> CryptoKey:
	var storage_password := _local_identity_storage_password()
	if storage_password.is_empty():
		return null
	if not FileAccess.file_exists(ADMIN_IDENTITY_KEY_FILE) \
			and FileAccess.file_exists(ADMIN_IDENTITY_KEY_FILE + ".bak"):
		DirAccess.rename_absolute(ProjectSettings.globalize_path(
			ADMIN_IDENTITY_KEY_FILE + ".bak"), ProjectSettings.globalize_path(
			ADMIN_IDENTITY_KEY_FILE))
	if FileAccess.file_exists(ADMIN_IDENTITY_KEY_FILE):
		var existing := FileAccess.open_encrypted_with_pass(
			ADMIN_IDENTITY_KEY_FILE, FileAccess.READ, storage_password)
		if existing and existing.get_length() <= MAX_ADMIN_PRIVATE_KEY_BYTES:
			var key_text := existing.get_as_text()
			existing = null
			var loaded := CryptoKey.new()
			if loaded.load_from_string(key_text, false) == OK \
					and not loaded.is_public_only():
				_restrict_identity_key_permissions()
				return loaded
		existing = null
	var generated := Crypto.new().generate_rsa(2048)
	if not generated:
		return null
	var private_pem := generated.save_to_string(false)
	if private_pem.is_empty() or private_pem.to_utf8_buffer().size() \
			> MAX_ADMIN_PRIVATE_KEY_BYTES \
			or not _store_encrypted_text_atomically(ADMIN_IDENTITY_KEY_FILE,
				private_pem, storage_password):
		return null
	_restrict_identity_key_permissions()
	return generated


func _local_identity_storage_password() -> String:
	var local_source := OS.get_unique_id().strip_edges()
	if local_source.is_empty():
		local_source = _load_or_create_identity_fallback_secret()
	if local_source.is_empty():
		return ""
	return (ADMIN_KEY_STORAGE_DOMAIN + local_source).sha256_text()


func _load_or_create_identity_fallback_secret() -> String:
	if FileAccess.file_exists(ADMIN_IDENTITY_SECRET_FILE):
		var existing := FileAccess.open(ADMIN_IDENTITY_SECRET_FILE, FileAccess.READ)
		if existing and existing.get_length() <= 256:
			var saved := existing.get_as_text().strip_edges()
			existing = null
			if _valid_key_fingerprint(saved):
				_restrict_private_file_permissions(ADMIN_IDENTITY_SECRET_FILE)
				return saved
		existing = null
	var generated := Crypto.new().generate_random_bytes(32).hex_encode()
	if not _valid_key_fingerprint(generated) \
			or not _store_text_atomically(ADMIN_IDENTITY_SECRET_FILE, generated,
				true):
		return ""
	_restrict_private_file_permissions(ADMIN_IDENTITY_SECRET_FILE)
	return generated


func _restrict_identity_key_permissions() -> void:
	_restrict_private_file_permissions(ADMIN_IDENTITY_KEY_FILE)


func _restrict_private_file_permissions(path: String) -> void:
	if OS.get_name() in ["macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD"]:
		FileAccess.set_unix_permissions(path,
			FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)


func _parse_public_identity(public_key_pem: String) -> Dictionary:
	var encoded_size := public_key_pem.to_utf8_buffer().size()
	if encoded_size < 128 or encoded_size > MAX_ADMIN_PUBLIC_KEY_BYTES:
		return {}
	var public_key := CryptoKey.new()
	if public_key.load_from_string(public_key_pem, true) != OK:
		return {}
	var canonical_pem := public_key.save_to_string(true)
	if canonical_pem.is_empty() or canonical_pem.to_utf8_buffer().size() \
			> MAX_ADMIN_PUBLIC_KEY_BYTES:
		return {}
	var fingerprint := _public_key_fingerprint(canonical_pem)
	if not _valid_key_fingerprint(fingerprint):
		return {}
	return {"key": public_key, "pem": canonical_pem,
		"fingerprint": fingerprint}


func _public_key_fingerprint(canonical_public_key: String) -> String:
	if canonical_public_key.is_empty():
		return ""
	return (ADMIN_KEY_FINGERPRINT_DOMAIN + canonical_public_key).sha256_text()


func _valid_key_fingerprint(fingerprint: String) -> bool:
	if fingerprint.length() != 64 or fingerprint.to_utf8_buffer().size() != 64:
		return false
	for index in range(64):
		var code := fingerprint.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 97 and code <= 102)):
			return false
	return true


func _fingerprint_available(fingerprint: String) -> bool:
	return _valid_key_fingerprint(fingerprint) \
		and not _peer_key_fingerprints.values().has(fingerprint)


func _registration_context_hash(peer_id: int, pname: String, protocol: int,
		game_version: String, fingerprint: String,
		nonce: PackedByteArray) -> PackedByteArray:
	if peer_id <= 1 or protocol <= 0 or not _valid_key_fingerprint(fingerprint) \
			or nonce.size() != ADMIN_NONCE_BYTES:
		return PackedByteArray()
	# Canonicalize inside the context builder as a defense in depth. The server
	# also returns this exact clean name with its challenge, so unusual spacing,
	# control characters, and truncation cannot make the two peers sign different
	# registration contexts.
	var clean_name := _sanitize_name(pname, peer_id)
	var context := "%s\npeer=%d\nname=%s\nprotocol=%d\nversion=%s\nkey=%s\nnonce=%s" % [
		ADMIN_PROOF_DOMAIN, peer_id, clean_name.sha256_text(), protocol,
		game_version.sha256_text(), fingerprint, nonce.hex_encode()]
	return context.sha256_buffer()


func _sign_registration_context(context_hash: PackedByteArray,
		private_key: CryptoKey) -> PackedByteArray:
	if context_hash.size() != 32 or not private_key \
			or private_key.is_public_only():
		return PackedByteArray()
	return Crypto.new().sign(HashingContext.HASH_SHA256, context_hash,
		private_key)


func _verify_registration_signature(context_hash: PackedByteArray,
		signature: PackedByteArray, public_key: CryptoKey) -> bool:
	return context_hash.size() == 32 and not signature.is_empty() \
		and signature.size() <= MAX_ADMIN_SIGNATURE_BYTES and public_key \
		and Crypto.new().verify(HashingContext.HASH_SHA256, context_hash,
			signature, public_key)


func _bootstrap_hmac(secret: String,
		context_hash: PackedByteArray) -> PackedByteArray:
	if secret.is_empty() or secret.length() > 128 or context_hash.size() != 32:
		return PackedByteArray()
	return Crypto.new().hmac_digest(HashingContext.HASH_SHA256,
		secret.to_utf8_buffer(), context_hash)


func _verify_bootstrap_hmac(proof: PackedByteArray,
		context_hash: PackedByteArray, expected_token: Variant = null) -> bool:
	if proof.size() != ADMIN_BOOTSTRAP_PROOF_BYTES:
		return false
	var token := _server_admin_token() if expected_token == null \
		else str(expected_token).strip_edges().left(128)
	var expected := _bootstrap_hmac(token, context_hash)
	return expected.size() == ADMIN_BOOTSTRAP_PROOF_BYTES \
		and Crypto.new().constant_time_compare(expected, proof)


func _state_file_path(file_name: String) -> String:
	if file_name.is_empty() or file_name.get_file() != file_name:
		return "user://state.json"
	var configured := OS.get_environment("TROOP_STATE_DIR").strip_edges()
	if configured.is_empty():
		return "user://" + file_name
	if configured.length() > 1024 or not configured.is_absolute_path():
		push_warning("Ignoring unsafe TROOP_STATE_DIR; using user:// instead.")
		return "user://" + file_name
	var directory := configured.simplify_path()
	if directory == directory.get_base_dir() \
			or (not DirAccess.dir_exists_absolute(directory) \
			and DirAccess.make_dir_recursive_absolute(directory) != OK):
		push_warning("TROOP_STATE_DIR is unavailable; using user:// instead.")
		return "user://" + file_name
	return directory.path_join(file_name)


func _load_admin_grants() -> void:
	_admin_key_fingerprints = {}
	var grant_file := _state_file_path(ADMIN_GRANT_FILE_NAME)
	var load_path := grant_file
	if not FileAccess.file_exists(load_path) \
			and FileAccess.file_exists(grant_file + ".bak"):
		load_path = grant_file + ".bak"
	if not FileAccess.file_exists(load_path):
		return
	var input := FileAccess.open(load_path, FileAccess.READ)
	if not input or input.get_length() > MAX_ADMIN_GRANT_FILE_BYTES:
		return
	var parsed: Variant = JSON.parse_string(input.get_as_text())
	if not (parsed is Dictionary) or int(parsed.get("schema", 0)) != 2:
		return
	var fingerprints: Variant = parsed.get("fingerprints", [])
	if not (fingerprints is Array):
		return
	for value in fingerprints:
		if _admin_key_fingerprints.size() >= MAX_ADMIN_KEYS:
			break
		var fingerprint := str(value)
		if _valid_key_fingerprint(fingerprint):
			_admin_key_fingerprints[fingerprint] = true


func _save_admin_grants() -> bool:
	var fingerprints := _admin_key_fingerprints.keys()
	fingerprints.sort()
	if fingerprints.size() > MAX_ADMIN_KEYS:
		fingerprints.resize(MAX_ADMIN_KEYS)
	return _store_text_atomically(_state_file_path(ADMIN_GRANT_FILE_NAME),
		JSON.stringify({"schema": 2, "fingerprints": fingerprints}))


## Write a complete temporary file, preserve the last good file as a backup,
## then replace it. A failed replacement restores the backup and is reported to
## the requesting admin rather than claiming persistence succeeded.
func _store_text_atomically(path: String, contents: String,
		owner_only := false) -> bool:
	var temp_path := path + ".tmp"
	var temp_abs := ProjectSettings.globalize_path(temp_path)
	if FileAccess.file_exists(temp_path) \
			and DirAccess.remove_absolute(temp_abs) != OK:
		return false
	var output := FileAccess.open(temp_path, FileAccess.WRITE)
	if not output:
		return false
	output.store_string(contents)
	output.flush()
	if output.get_error() != OK:
		output = null
		DirAccess.remove_absolute(temp_abs)
		return false
	output = null
	if owner_only:
		_restrict_private_file_permissions(temp_path)
	return _commit_atomic_temp(path, temp_path)


func _store_encrypted_text_atomically(path: String, contents: String,
		password: String) -> bool:
	if password.is_empty():
		return false
	var temp_path := path + ".tmp"
	var temp_abs := ProjectSettings.globalize_path(temp_path)
	if FileAccess.file_exists(temp_path) \
			and DirAccess.remove_absolute(temp_abs) != OK:
		return false
	var output := FileAccess.open_encrypted_with_pass(temp_path,
		FileAccess.WRITE, password)
	if not output:
		return false
	output.store_string(contents)
	output.flush()
	if output.get_error() != OK:
		output = null
		DirAccess.remove_absolute(temp_abs)
		return false
	output = null
	_restrict_private_file_permissions(temp_path)
	return _commit_atomic_temp(path, temp_path)


func _commit_atomic_temp(path: String, temp_path: String) -> bool:
	var backup_path := path + ".bak"
	var target_abs := ProjectSettings.globalize_path(path)
	var temp_abs := ProjectSettings.globalize_path(temp_path)
	var backup_abs := ProjectSettings.globalize_path(backup_path)
	if not FileAccess.file_exists(path) and FileAccess.file_exists(backup_path):
		if DirAccess.rename_absolute(backup_abs, target_abs) != OK:
			DirAccess.remove_absolute(temp_abs)
			return false
	elif FileAccess.file_exists(backup_path) \
			and DirAccess.remove_absolute(backup_abs) != OK:
		DirAccess.remove_absolute(temp_abs)
		return false
	var had_target := FileAccess.file_exists(path)
	if had_target and DirAccess.rename_absolute(target_abs, backup_abs) != OK:
		DirAccess.remove_absolute(temp_abs)
		return false
	if DirAccess.rename_absolute(temp_abs, target_abs) != OK:
		if had_target:
			DirAccess.rename_absolute(backup_abs, target_abs)
		DirAccess.remove_absolute(temp_abs)
		return false
	if had_target and FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_abs)
	return true


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
	_store_text_atomically(_state_file_path(BAN_FILE_NAME), JSON.stringify(_bans))


func _load_bans() -> void:
	_bans = {}
	var ban_file := _state_file_path(BAN_FILE_NAME)
	if not FileAccess.file_exists(ban_file):
		return
	var f := FileAccess.open(ban_file, FileAccess.READ)
	if not f:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		_bans = parsed


func _on_connection_failed() -> void:
	active = false
	is_admin = false
	_client_registration_challenge_used = false
	admin_peers = {}
	admin_changed.emit(false)
	admin_roster_changed.emit()
	net_error.emit("connection failed")


func _on_server_disconnected() -> void:
	active = false
	is_admin = false
	_client_registration_challenge_used = false
	admin_peers = {}
	admin_changed.emit(false)
	admin_roster_changed.emit()
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
	_release_vehicles_of_peer(id)
	_registered.erase(id)
	_pending_registrations.erase(id)
	_peer_on_foot_positions.erase(id)
	names.erase(id)
	scores.erase(id)
	_admins.erase(id)
	_peer_key_fingerprints.erase(id)
	_clear_rate_windows(id)
	if is_host:
		rpc("cl_roster", names, scores)
		_refresh_admin_roster()
	if was_registered:
		roster_changed.emit()
		peer_left.emit(id)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_begin_register(pname: String, protocol: int, game_version: String,
		public_key_pem: String) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if id <= 1 or _registered.has(id) or _pending_registrations.has(id):
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
	var identity := _parse_public_identity(public_key_pem)
	if identity.is_empty():
		_reject_peer(id, "Could not verify this game installation. Restart "
			+ "TROOP and try again.")
		return
	var fingerprint: String = identity.fingerprint
	if not _fingerprint_available(fingerprint):
		_reject_peer(id, "This game installation is already connected.")
		return
	var nonce := Crypto.new().generate_random_bytes(ADMIN_NONCE_BYTES)
	var clean_name := _sanitize_name(pname, id)
	var context_hash := _registration_context_hash(id, clean_name, protocol,
		game_version, fingerprint, nonce)
	if nonce.size() != ADMIN_NONCE_BYTES or context_hash.size() != 32:
		_reject_peer(id, "Could not start secure registration. Try again.")
		return
	_pending_registrations[id] = {
		"name": clean_name,
		"protocol": protocol,
		"game_version": game_version,
		"public_key": identity.key,
		"fingerprint": fingerprint,
		"context_hash": context_hash,
		"issued_msec": Time.get_ticks_msec(),
	}
	rpc_id(id, "cl_registration_challenge", nonce, clean_name)


@rpc("authority", "call_remote", "reliable", 0)
func cl_registration_challenge(nonce: PackedByteArray,
		server_clean_name: String) -> void:
	if not active or is_host or _client_registration_challenge_used \
			or nonce.size() != ADMIN_NONCE_BYTES or not _client_identity_key \
			or server_clean_name != _sanitize_name(server_clean_name, local_id()):
		net_error.emit("Server sent an invalid registration challenge.")
		call_deferred("shutdown")
		return
	_client_registration_challenge_used = true
	# Use the authority-returned canonical value for both the proof and the local
	# roster name. It is already bound to this one-time signed context.
	local_name = server_clean_name
	var identity := _parse_public_identity(
		_client_identity_key.save_to_string(true))
	if identity.is_empty():
		net_error.emit("Could not use this installation's admin identity.")
		call_deferred("shutdown")
		return
	var context_hash := _registration_context_hash(local_id(), server_clean_name,
		PROTOCOL_VERSION, effective_game_version(), identity.fingerprint, nonce)
	var signature := _sign_registration_context(context_hash,
		_client_identity_key)
	if signature.is_empty() or signature.size() > MAX_ADMIN_SIGNATURE_BYTES:
		net_error.emit("Could not sign the registration challenge.")
		call_deferred("shutdown")
		return
	var bootstrap_proof := _bootstrap_hmac(
		_client_admin_bootstrap_secret(), context_hash)
	rpc_id(1, "srv_complete_register", signature, bootstrap_proof)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_complete_register(signature: PackedByteArray,
		bootstrap_proof: PackedByteArray) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if id <= 1 or _registered.has(id) or not _pending_registrations.has(id):
		if id > 1 and not _registered.has(id):
			_reject_peer(id, "Registration proof was missing or already used.")
		return
	var registration := _consume_registration_proof(id, signature,
		bootstrap_proof)
	if registration.is_empty():
		_reject_peer(id, "Registration signature was invalid.")
		return
	_finish_registration(id, str(registration.name),
		str(registration.fingerprint), bool(registration.bootstrap_admin))


## Consume before verifying so the same nonce/signature pair is one-shot even
## when verification fails. The returned record contains no private material.
func _consume_registration_proof(id: int, signature: PackedByteArray,
		bootstrap_proof: PackedByteArray, now_msec := -1) -> Dictionary:
	if not _pending_registrations.has(id):
		return {}
	var pending: Dictionary = _pending_registrations[id]
	_pending_registrations.erase(id)
	var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	var age := now - int(pending.get("issued_msec", 0))
	if age < 0 or age > int(REGISTRATION_TIMEOUT_SECONDS * 1000.0) \
			or signature.is_empty() or signature.size() > MAX_ADMIN_SIGNATURE_BYTES \
			or bootstrap_proof.size() > ADMIN_BOOTSTRAP_PROOF_BYTES:
		return {}
	var public_key: CryptoKey = pending.get("public_key")
	var context_hash: PackedByteArray = pending.get("context_hash",
		PackedByteArray())
	if not _verify_registration_signature(context_hash, signature, public_key):
		return {}
	var fingerprint := str(pending.get("fingerprint", ""))
	if not _fingerprint_available(fingerprint):
		return {}
	return {
		"name": str(pending.get("name", "")),
		"fingerprint": fingerprint,
		"bootstrap_admin": _verify_bootstrap_hmac(bootstrap_proof,
			context_hash),
	}


func _finish_registration(id: int, pname: String, fingerprint: String,
		bootstrap_admin: bool) -> void:
	if not is_host or id <= 1 or _registered.has(id) \
			or not _fingerprint_available(fingerprint):
		return
	_peer_key_fingerprints[id] = fingerprint
	_registered[id] = true
	names[id] = _sanitize_name(pname, id)
	scores[id] = 0
	if _registration_is_admin(fingerprint, bootstrap_admin):
		_admins[id] = true
		rpc_id(id, "cl_admin", true)
	rpc("cl_roster", names, scores)
	_refresh_admin_roster()
	rpc_id(id, "cl_world", world_seed, collected.keys(),
		claimed_supply_chests, authoritative_cycle_hour(),
		effective_game_version(), claimed_vehicles, vehicle_rests,
		vehicle_spawn_definitions)
	roster_changed.emit()


func _registration_is_admin(fingerprint: String,
		bootstrap_admin: bool) -> bool:
	return _valid_key_fingerprint(fingerprint) \
		and (_admin_key_fingerprints.has(fingerprint) or bootstrap_admin)


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
		cycle_hour: float, _server_version: String,
		vehicle_claims := {}, vehicle_rest_states := {},
		vehicle_spawn_states := {}) -> void:
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
	claimed_vehicles = {}
	var vehicle_copied := 0
	for vid in vehicle_claims:
		if vehicle_copied >= MAX_VEHICLE_CLAIMS:
			break
		var stable_vid := str(vid)
		if _valid_vehicle_id(stable_vid):
			claimed_vehicles[stable_vid] = int(vehicle_claims[vid])
			vehicle_copied += 1
	vehicle_rests = {}
	vehicle_copied = 0
	for vid in vehicle_rest_states:
		if vehicle_copied >= MAX_VEHICLE_CLAIMS:
			break
		var stable_vid := str(vid)
		if _valid_vehicle_id(stable_vid) \
				and _valid_vehicle_rest(vehicle_rest_states[vid]):
			vehicle_rests[stable_vid] = vehicle_rest_states[vid]
			vehicle_copied += 1
	vehicle_spawn_definitions = {}
	vehicle_copied = 0
	for vid in vehicle_spawn_states:
		if vehicle_copied >= MAX_VEHICLE_CLAIMS:
			break
		var stable_vid := str(vid)
		var definition: Variant = vehicle_spawn_states[vid]
		if not (definition is Dictionary):
			continue
		var vehicle_kind := int(definition.get("kind", -1))
		var spawn_position: Variant = definition.get("pos")
		var spawn_yaw: Variant = definition.get("yaw")
		if _valid_dynamic_vehicle_spawn(stable_vid, vehicle_kind,
				spawn_position, spawn_yaw):
			vehicle_spawn_definitions[stable_vid] = {
				"kind": vehicle_kind, "pos": spawn_position,
				"yaw": float(spawn_yaw),
			}
			_vehicle_kinds[stable_vid] = vehicle_kind
			_vehicle_positions[stable_vid] = spawn_position
			vehicle_copied += 1
	world_ready.emit()


# ---- movement --------------------------------------------------------------

func send_state(pos: Vector3, yaw: float, vel: Vector3, anim: int,
		swinging: bool, anchor: Vector3, rope_tail: float,
		wraps: PackedVector3Array, weapon_kind: int, weapon_stowed: bool,
		melee_mode: bool, weapon_ammo: int, weapon_reloading: bool,
		healing_progress: float, flying := false, vehicle_kind := -1,
		vehicle_id := "", vehicle_aux := Vector3.ZERO) -> void:
	if not active:
		return
	if is_host:
		_remember_authoritative_state_position(local_id(), pos, vehicle_kind,
			vehicle_id)
		rpc("cl_state", local_id(), pos, yaw, vel, anim, swinging, anchor,
			rope_tail, wraps, weapon_kind, weapon_stowed, melee_mode,
			weapon_ammo, weapon_reloading, healing_progress, flying,
			vehicle_kind, vehicle_id, vehicle_aux)
	else:
		rpc_id(1, "srv_state", pos, yaw, vel, anim, swinging, anchor,
			rope_tail, wraps, weapon_kind, weapon_stowed, melee_mode,
			weapon_ammo, weapon_reloading, healing_progress, flying,
			vehicle_kind, vehicle_id, vehicle_aux)


@rpc("any_peer", "call_remote", "unreliable_ordered", 0)
func srv_state(pos: Vector3, yaw: float, vel: Vector3, anim: int,
		swinging: bool, anchor: Vector3, rope_tail: float,
		wraps: PackedVector3Array, weapon_kind: int, weapon_stowed: bool,
		melee_mode: bool, weapon_ammo: int, weapon_reloading: bool,
			healing_progress: float, flying := false, vehicle_kind := -1,
			vehicle_id := "", vehicle_aux := Vector3.ZERO) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_peer(sender) \
			or not _allow_rate(sender, "state", MAX_STATE_PACKETS_PER_SECOND) \
			or not _valid_state(pos, yaw, vel, anim,
			swinging, anchor, rope_tail, wraps, weapon_kind, weapon_ammo,
			healing_progress, vehicle_kind, vehicle_id, vehicle_aux, flying) \
			or not _sender_owns_vehicle_state(sender, vehicle_kind, vehicle_id):
		return
	_remember_authoritative_state_position(sender, pos, vehicle_kind, vehicle_id)
	peer_state.emit(sender, pos, yaw, vel, anim, swinging, anchor, rope_tail,
		wraps, weapon_kind, weapon_stowed, melee_mode, weapon_ammo,
		weapon_reloading, healing_progress, flying, vehicle_kind, vehicle_id,
		vehicle_aux)
	rpc("cl_state", sender, pos, yaw, vel, anim, swinging, anchor, rope_tail,
		wraps, weapon_kind, weapon_stowed, melee_mode, weapon_ammo,
		weapon_reloading, healing_progress, flying, vehicle_kind, vehicle_id,
		vehicle_aux)


@rpc("authority", "call_remote", "unreliable_ordered", 0)
func cl_state(id: int, pos: Vector3, yaw: float, vel: Vector3, anim: int,
		swinging: bool, anchor: Vector3, rope_tail: float,
		wraps: PackedVector3Array, weapon_kind: int, weapon_stowed: bool,
		melee_mode: bool, weapon_ammo: int, weapon_reloading: bool,
		healing_progress: float, flying := false, vehicle_kind := -1,
		vehicle_id := "", vehicle_aux := Vector3.ZERO) -> void:
	if id == local_id() or not names.has(id):
		return
	if not _valid_state(pos, yaw, vel, anim, swinging, anchor, rope_tail,
			wraps, weapon_kind, weapon_ammo, healing_progress, vehicle_kind,
			vehicle_id, vehicle_aux, flying):
		return
	peer_state.emit(id, pos, yaw, vel, anim, swinging, anchor, rope_tail,
		wraps, weapon_kind, weapon_stowed, melee_mode, weapon_ammo,
		weapon_reloading, healing_progress, flying, vehicle_kind, vehicle_id,
		vehicle_aux)


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


# ---- vehicles --------------------------------------------------------------
# One driver's seat per machine. The server arbitrates who holds each vehicle
# exactly like chest claims, but a claim is released again on dismount (with a
# resting transform every peer applies) or when the driver disconnects.

## Admin-delivered machines are the only legitimate dynamic vehicle ids. The
## authenticated creator registers the id and first kind before spawning it;
## the authority keeps that binding immutable so later drivers can use the same
## machine without being able to change its type.
func register_admin_vehicle(vehicle_id: String, vehicle_kind: int,
		spawn_position: Vector3, spawn_yaw: float) -> bool:
	var creator := local_id()
	if not is_admin or not _valid_admin_vehicle_id_for_creator(vehicle_id,
			creator) or not _valid_dynamic_vehicle_spawn(vehicle_id, vehicle_kind,
			spawn_position, spawn_yaw):
		return false
	if not active:
		return _bind_admin_vehicle_kind(creator, vehicle_id, vehicle_kind,
			spawn_position, spawn_yaw)
	if is_host:
		return _host_register_admin_vehicle(creator, vehicle_id, vehicle_kind,
			spawn_position, spawn_yaw)
	rpc_id(1, "srv_register_admin_vehicle", vehicle_id, vehicle_kind,
		spawn_position, spawn_yaw)
	return true


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_register_admin_vehicle(vehicle_id: String, vehicle_kind: int,
		spawn_position: Vector3, spawn_yaw: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _authorized_admin_sender(sender) \
			or not _allow_rate(sender, "admin_vehicle", 8) \
			or not _host_register_admin_vehicle(sender, vehicle_id, vehicle_kind,
			spawn_position, spawn_yaw):
		if _authorized_admin_sender(sender):
			_notify_admin_requester(sender,
				"Vehicle delivery was rejected by the server.")


func _host_register_admin_vehicle(creator: int, vehicle_id: String,
		vehicle_kind: int, spawn_position: Vector3, spawn_yaw: float) -> bool:
	if not _authorized_admin_sender(creator) \
			or not _valid_admin_vehicle_id_for_creator(vehicle_id, creator) \
			or not _valid_dynamic_vehicle_spawn(vehicle_id, vehicle_kind,
			spawn_position, spawn_yaw):
		return false
	# Remote admins must have recently replicated an on-foot position and may
	# only deliver within the same short radius used by the local command. The
	# listen host is the authority and remains exempt from network timing.
	if creator != local_id():
		if not _peer_on_foot_positions.has(creator) \
				or spawn_position.distance_to(
					_peer_on_foot_positions[creator]) > ADMIN_VEHICLE_SPAWN_DISTANCE:
			return false
	return _bind_admin_vehicle_kind(creator, vehicle_id, vehicle_kind,
		spawn_position, spawn_yaw)


func _bind_admin_vehicle_kind(creator: int, vehicle_id: String,
		vehicle_kind: int, spawn_position: Vector3, spawn_yaw: float) -> bool:
	if _vehicle_kinds.has(vehicle_id):
		var existing: Dictionary = vehicle_spawn_definitions.get(vehicle_id, {})
		var existing_position: Variant = existing.get("pos")
		return int(_vehicle_kinds[vehicle_id]) == vehicle_kind \
			and int(_admin_vehicle_creators.get(vehicle_id, 0)) == creator \
			and not existing.is_empty() \
			and existing_position is Vector3 \
			and existing_position.is_equal_approx(spawn_position) \
			and absf(angle_difference(float(existing.get("yaw", 0.0)),
				spawn_yaw)) < 0.001
	if _vehicle_kinds.size() >= MAX_VEHICLE_CLAIMS:
		return false
	_vehicle_kinds[vehicle_id] = vehicle_kind
	_admin_vehicle_creators[vehicle_id] = creator
	_vehicle_positions[vehicle_id] = spawn_position
	vehicle_spawn_definitions[vehicle_id] = {
		"kind": vehicle_kind, "pos": spawn_position, "yaw": spawn_yaw,
	}
	vehicle_spawn_registered.emit(vehicle_id, vehicle_kind, spawn_position,
		spawn_yaw)
	if active and is_host and multiplayer.multiplayer_peer:
		rpc("cl_vehicle_spawn_registered", vehicle_id, vehicle_kind,
			spawn_position, spawn_yaw)
	return true


@rpc("authority", "call_remote", "reliable", 0)
func cl_vehicle_spawn_registered(vehicle_id: String, vehicle_kind: int,
		spawn_position: Vector3, spawn_yaw: float) -> void:
	if not active or is_host or not _valid_dynamic_vehicle_spawn(vehicle_id,
			vehicle_kind, spawn_position, spawn_yaw):
		return
	if vehicle_spawn_definitions.has(vehicle_id):
		var existing: Dictionary = vehicle_spawn_definitions[vehicle_id]
		if int(existing.get("kind", -1)) != vehicle_kind \
				or not (existing.get("pos") is Vector3) \
				or not existing.pos.is_equal_approx(spawn_position) \
				or absf(angle_difference(float(existing.get("yaw", 0.0)),
					spawn_yaw)) >= 0.001:
			return
	else:
		if vehicle_spawn_definitions.size() >= MAX_VEHICLE_CLAIMS:
			return
		vehicle_spawn_definitions[vehicle_id] = {
			"kind": vehicle_kind, "pos": spawn_position, "yaw": spawn_yaw,
		}
		_vehicle_kinds[vehicle_id] = vehicle_kind
		_vehicle_positions[vehicle_id] = spawn_position
	vehicle_spawn_registered.emit(vehicle_id, vehicle_kind, spawn_position,
		spawn_yaw)


## Return the kind from the authority's immutable registry. Generated ids are
## resolved lazily from Gen's current seed, so a dedicated server does not have
## to pre-enumerate an infinite world and an invented but well-formed id is
## never enough to create a machine.
func _canonical_vehicle_kind(vehicle_id: String) -> int:
	if not _valid_vehicle_id(vehicle_id):
		return -1
	if _vehicle_kinds.has(vehicle_id):
		return int(_vehicle_kinds[vehicle_id])
	if not is_host or Gen.debug_world or Gen.world_seed != world_seed \
			or _vehicle_kinds.size() >= MAX_VEHICLE_CLAIMS:
		return -1
	var definition: Dictionary = Gen.vehicle_definition_by_id(vehicle_id)
	if definition.is_empty() or str(definition.get("id", "")) != vehicle_id:
		return -1
	var vehicle_kind := int(definition.get("kind", -1))
	var spawn_position: Variant = definition.get("pos")
	if not _valid_vehicle_kind(vehicle_kind) or not (spawn_position is Vector3) \
			or not _finite_vec(spawn_position) or _outside_world(spawn_position):
		return -1
	_vehicle_kinds[vehicle_id] = vehicle_kind
	_vehicle_positions[vehicle_id] = spawn_position
	return vehicle_kind

func request_vehicle(vehicle_id: String) -> bool:
	if not _valid_vehicle_id(vehicle_id) or claimed_vehicles.has(vehicle_id):
		return false
	if not active:
		_apply_vehicle_claim(vehicle_id, local_id())
		return true
	if is_host:
		return _host_claim_vehicle(vehicle_id, local_id())
	rpc_id(1, "srv_request_vehicle", vehicle_id)
	return true


func release_vehicle(vehicle_id: String, rest: Array) -> void:
	if not _valid_vehicle_id(vehicle_id):
		return
	if not active:
		_apply_vehicle_release(vehicle_id, rest)
	elif is_host:
		_host_release_vehicle(vehicle_id, local_id(), rest)
	else:
		rpc_id(1, "srv_release_vehicle", vehicle_id, rest)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_request_vehicle(vehicle_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if _registered_peer(sender) and _allow_rate(sender, "vehicle_claim", 8):
		_host_claim_vehicle(vehicle_id, sender)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_release_vehicle(vehicle_id: String, rest: Array) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if _registered_peer(sender) and _allow_rate(sender, "vehicle_claim", 8):
		_host_release_vehicle(vehicle_id, sender, rest)


func _host_claim_vehicle(vehicle_id: String, claimant_id: int) -> bool:
	if _canonical_vehicle_kind(vehicle_id) < 0 or not names.has(claimant_id) \
			or (claimant_id != local_id() \
			and not _vehicle_claim_in_range(claimant_id, vehicle_id)) \
			or (not claimed_vehicles.has(vehicle_id)
			and claimed_vehicles.size() >= MAX_VEHICLE_CLAIMS):
		return false
	if claimed_vehicles.has(vehicle_id):
		if claimant_id != local_id():
			rpc_id(claimant_id, "cl_vehicle_claimed", vehicle_id,
				int(claimed_vehicles[vehicle_id]))
		return false
	claimed_vehicles[vehicle_id] = claimant_id
	vehicle_rests.erase(vehicle_id)
	vehicle_claimed.emit(vehicle_id, claimant_id)
	rpc("cl_vehicle_claimed", vehicle_id, claimant_id)
	return true


func _host_release_vehicle(vehicle_id: String, releasing_id: int,
		rest: Array) -> void:
	if not _valid_vehicle_id(vehicle_id) \
			or not claimed_vehicles.has(vehicle_id) \
			or int(claimed_vehicles[vehicle_id]) != releasing_id:
		return
	if not _valid_vehicle_rest(rest):
		rest = []
	elif releasing_id != local_id() \
			and not _valid_vehicle_release_position(vehicle_id, rest[0]):
		rest = []
	claimed_vehicles.erase(vehicle_id)
	if not rest.is_empty():
		vehicle_rests[vehicle_id] = rest
		_vehicle_positions[vehicle_id] = rest[0]
	_remember_vehicle_release_handoff(releasing_id, vehicle_id, rest)
	vehicle_released.emit(vehicle_id, rest)
	rpc("cl_vehicle_released", vehicle_id, rest)


## The host clears every vehicle a disconnecting driver still held so the
## machine is not locked forever where they dropped.
func _release_vehicles_of_peer(id: int) -> void:
	if not is_host:
		return
	var held: Array = []
	for vid in claimed_vehicles:
		if int(claimed_vehicles[vid]) == id:
			held.append(vid)
	for vid in held:
		claimed_vehicles.erase(vid)
		vehicle_released.emit(vid, [])
		rpc("cl_vehicle_released", vid, [])


func _vehicle_claim_in_range(claimant_id: int, vehicle_id: String) -> bool:
	if not _peer_on_foot_positions.has(claimant_id) \
			or not _vehicle_positions.has(vehicle_id):
		return false
	var claimant_position: Variant = _peer_on_foot_positions[claimant_id]
	var vehicle_position: Variant = _vehicle_positions[vehicle_id]
	return claimant_position is Vector3 and vehicle_position is Vector3 \
		and claimant_position.distance_to(vehicle_position) \
			<= VEHICLE_CLAIM_DISTANCE


func _remember_authoritative_state_position(peer_id: int, position: Vector3,
		vehicle_kind: int, vehicle_id: String) -> void:
	if vehicle_kind == -1:
		_peer_on_foot_positions[peer_id] = position
	elif _valid_vehicle_kind(vehicle_kind) and _valid_vehicle_id(vehicle_id):
		_vehicle_positions[vehicle_id] = position


func _valid_vehicle_release_position(vehicle_id: String,
		release_position: Vector3) -> bool:
	if not _vehicle_positions.has(vehicle_id):
		return false
	var last_position: Variant = _vehicle_positions[vehicle_id]
	return last_position is Vector3 \
		and last_position.distance_to(release_position) \
			<= VEHICLE_RELEASE_POSITION_TOLERANCE


## Reliable release and a new reliable claim can arrive before the next 20 Hz
## on-foot state. Anchor the just-dismounted peer at the accepted rest (or last
## accepted live state) so an immediate E re-entry remains responsive.
func _remember_vehicle_release_handoff(peer_id: int, vehicle_id: String,
		rest: Array) -> void:
	var handoff_position: Variant = rest[0] if not rest.is_empty() \
		else _vehicle_positions.get(vehicle_id)
	if handoff_position is Vector3:
		_peer_on_foot_positions[peer_id] = handoff_position


@rpc("authority", "call_remote", "reliable", 0)
func cl_vehicle_claimed(vehicle_id: String, claimant_id: int) -> void:
	_apply_vehicle_claim(vehicle_id, claimant_id)


@rpc("authority", "call_remote", "reliable", 0)
func cl_vehicle_released(vehicle_id: String, rest: Array) -> void:
	_apply_vehicle_release(vehicle_id, rest)


func _apply_vehicle_claim(vehicle_id: String, claimant_id: int) -> void:
	if not _valid_vehicle_id(vehicle_id) \
			or claimed_vehicles.has(vehicle_id) \
			or claimed_vehicles.size() >= MAX_VEHICLE_CLAIMS:
		return
	claimed_vehicles[vehicle_id] = claimant_id
	vehicle_rests.erase(vehicle_id)
	vehicle_claimed.emit(vehicle_id, claimant_id)


func _apply_vehicle_release(vehicle_id: String, rest: Array) -> void:
	if not _valid_vehicle_id(vehicle_id):
		return
	if not _valid_vehicle_rest(rest):
		rest = []
	claimed_vehicles.erase(vehicle_id)
	if not rest.is_empty():
		vehicle_rests[vehicle_id] = rest
	vehicle_released.emit(vehicle_id, rest)


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
	var presentation_velocity := _safe_defeat_velocity(velocity)
	if is_host:
		_relay_defeat(local_id(), pos, yaw, presentation_velocity, impulse,
			headshot)
	else:
		rpc_id(1, "srv_defeat", pos, yaw, velocity, impulse, headshot)


@rpc("any_peer", "call_remote", "reliable", 0)
func srv_defeat(pos: Vector3, yaw: float, velocity: Vector3,
		impulse: Vector3, headshot: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_peer(sender) or not _allow_rate(sender, "defeat", 4) \
			or not _valid_defeat(pos, yaw, velocity, impulse):
		return
	var presentation_velocity := _safe_defeat_velocity(velocity)
	if not is_dedicated:
		peer_defeated.emit(sender, pos, yaw, presentation_velocity, impulse,
			headshot)
	_relay_defeat(sender, pos, yaw, presentation_velocity, impulse, headshot)


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
		peer_defeated.emit(defeated_id, pos, yaw,
			_safe_defeat_velocity(velocity), impulse, headshot)


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
## action directly; online only an authority-recognized admin can ask the
## server, and the server re-validates the bounded action envelope before
## touching any other peer.
func admin_command(action: String, args: Dictionary) -> void:
	if not is_admin or not _valid_admin_envelope(action, args):
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
	if not _authorized_admin_sender(sender) \
			or not _allow_rate(sender, "admin", 8) \
			or not _valid_admin_envelope(action, args):
		return
	_host_admin(sender, action, args)


func _host_admin(sender: int, action: String, args: Dictionary) -> void:
	if not _authorized_admin_sender(sender) \
			or not _valid_admin_envelope(action, args):
		return
	var target := int(args.get("target", 0))
	match action:
		"set_time":
			var hour := wrapf(float(args.get("hour", 0.0)), 0.0, 24.0)
			if _set_shared_cycle_hour(hour):
				_notify_admin_requester(sender, "Shared time set to %02d:%02d on every player." % [
					int(hour), int(fmod(hour, 1.0) * 60.0)])
		"clear_time":
			var server_hour := SeasonalCycle.local_hour_from_system()
			if _set_shared_cycle_hour(server_hour):
				_notify_admin_requester(sender,
					"Shared clock returned to the server's local cycle.")
		"grant_admin", "revoke_admin":
			var target_name := str(names.get(target, "that player"))
			var enabled := action == "grant_admin"
			var result := _apply_key_admin_request(sender, target, enabled)
			match result:
				ADMIN_GRANT_UPDATED:
					_notify_admin_requester(sender,
						("%s now has persistent installation-key admin access."
						if enabled else "Removed admin access from %s; any "
						+ "saved installation-key grant was revoked.") % target_name)
				ADMIN_GRANT_STORAGE_ERROR:
					_notify_admin_requester(sender, "Admin access was not changed: "
						+ "the server could not safely save its admin grants.")
				_:
					_notify_admin_requester(sender, "Admin access was unchanged; "
						+ "choose another connected player or current state.")
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
			if PLAYER_ADMIN_ACTIONS.has(action) and names.has(target):
				if target == local_id() and not is_dedicated:
					admin_action.emit(action, args)
				else:
					rpc_id(target, "cl_admin_apply", action, args)


func _authorized_admin_sender(sender: int) -> bool:
	if not is_host:
		return false
	if sender == 1:
		return not is_dedicated and is_admin
	return _registered_peer(sender) and _admins.has(sender)


## Grant RPCs never accept a key or fingerprint. The authority resolves the
## target peer to the public-key fingerprint proven during registration.
func _admin_target_fingerprint(sender: int, target: int) -> String:
	if not _authorized_admin_sender(sender) or target <= 1 or target == sender \
			or not _registered_peer(target):
		return ""
	var fingerprint := str(_peer_key_fingerprints.get(target, ""))
	return fingerprint if _valid_key_fingerprint(fingerprint) else ""


func _apply_key_admin_request(sender: int, target: int, enabled: bool,
		write_file := true, sync_network := true) -> int:
	var fingerprint := _admin_target_fingerprint(sender, target)
	if fingerprint.is_empty():
		return ADMIN_GRANT_UNCHANGED
	var had_persistent := _admin_key_fingerprints.has(fingerprint)
	var had_session := _admins.has(target)
	if had_persistent == enabled and had_session == enabled:
		return ADMIN_GRANT_UNCHANGED
	if had_persistent != enabled:
		if not _remember_admin_fingerprint(fingerprint, enabled):
			return ADMIN_GRANT_STORAGE_ERROR
		if write_file and not _save_admin_grants():
			_remember_admin_fingerprint(fingerprint, had_persistent)
			return ADMIN_GRANT_STORAGE_ERROR
	if enabled:
		_admins[target] = true
	else:
		_admins.erase(target)
	if sync_network:
		rpc_id(target, "cl_admin", enabled)
	_refresh_admin_roster(sync_network)
	return ADMIN_GRANT_UPDATED


func _remember_admin_fingerprint(fingerprint: String, enabled: bool) -> bool:
	if not _valid_key_fingerprint(fingerprint):
		return false
	if enabled:
		if not _admin_key_fingerprints.has(fingerprint) \
				and _admin_key_fingerprints.size() >= MAX_ADMIN_KEYS:
			return false
		_admin_key_fingerprints[fingerprint] = true
	else:
		_admin_key_fingerprints.erase(fingerprint)
	return true


func _public_admin_peer_ids() -> Array:
	var peer_ids: Array = []
	if is_host and not is_dedicated and names.has(1):
		peer_ids.append(1)
	for value in _admins:
		var peer_id := int(value)
		if peer_id > 1 and names.has(peer_id):
			peer_ids.append(peer_id)
	peer_ids.sort()
	if peer_ids.size() > MAX_CLIENTS:
		peer_ids.resize(MAX_CLIENTS)
	return peer_ids


func _refresh_admin_roster(send_network := true) -> void:
	admin_peers = {}
	var peer_ids := _public_admin_peer_ids()
	for peer_id in peer_ids:
		admin_peers[int(peer_id)] = true
	admin_roster_changed.emit()
	if not send_network or not is_host:
		return
	for peer_id in names:
		if int(peer_id) > 1:
			rpc_id(int(peer_id), "cl_admin_roster", peer_ids)


func _notify_admin_requester(sender: int, message: String) -> void:
	var clean := _sanitize_chat(message).left(180)
	if sender == 1 and not is_dedicated:
		admin_notice.emit(clean)
	elif _registered_peer(sender):
		rpc_id(sender, "cl_admin_notice", clean)


@rpc("authority", "call_remote", "reliable", 0)
func cl_admin_apply(action: String, args: Dictionary) -> void:
	if PLAYER_ADMIN_ACTIONS.has(action) and _valid_admin_envelope(action, args):
		admin_action.emit(action, args)


@rpc("authority", "call_remote", "reliable", 0)
func cl_admin(enabled: bool) -> void:
	var changed := is_admin != enabled
	is_admin = enabled
	admin_changed.emit(enabled)
	if changed:
		admin_notice.emit("Admin access granted for this installation." if enabled \
			else "Admin access for this installation was revoked.")


@rpc("authority", "call_remote", "reliable", 0)
func cl_admin_roster(peer_ids: Array) -> void:
	admin_peers = {}
	for value in peer_ids.slice(0, MAX_CLIENTS):
		if value is int and int(value) > 0 and names.has(int(value)):
			admin_peers[int(value)] = true
	admin_roster_changed.emit()


@rpc("authority", "call_remote", "reliable", 0)
func cl_admin_notice(message: String) -> void:
	var clean := _sanitize_chat(message).left(180)
	if not clean.is_empty():
		admin_notice.emit(clean)


@rpc("authority", "call_remote", "reliable", 0)
func cl_cycle_hour(hour: float) -> void:
	if not active or is_host or not is_finite(hour):
		return
	_anchor_authoritative_cycle(hour)
	cycle_hour_changed.emit(_cycle_anchor_hour)


@rpc("authority", "call_remote", "reliable", 0)
func cl_kicked(reason: String) -> void:
	net_error.emit(_sanitize_chat(reason).left(180))
	call_deferred("shutdown")


# ---- validation ------------------------------------------------------------

func _valid_admin_envelope(action: String, args: Dictionary) -> bool:
	if action.length() > 24 or action.to_utf8_buffer().size() != action.length() \
			or not ADMIN_ACTIONS.has(action):
		return false
	var allowed: Array = ADMIN_ARG_KEYS.get(action, [])
	if args.size() > allowed.size():
		return false
	for key in args:
		if not key is String or str(key).length() > 20 \
				or not allowed.has(key):
			return false
	match action:
		"set_time":
			var hour: Variant = args.get("hour")
			return args.size() == 1 and (hour is float or hour is int) \
				and is_finite(float(hour)) and absf(float(hour)) <= 1000000.0
		"clear_time":
			return args.is_empty()
		"announce":
			return args.size() == 1 and args.get("text") is String \
				and str(args.text).length() <= MAX_CHAT_LENGTH
		"kick":
			return _valid_admin_target_arg(args) \
				and (not args.has("reason") or (args.reason is String \
				and str(args.reason).length() <= MAX_CHAT_LENGTH))
		"ban":
			return _valid_admin_target_arg(args) and args.get("minutes") is int \
				and int(args.minutes) >= 1 and int(args.minutes) <= MAX_BAN_MINUTES
		"give_ammo":
			return _valid_admin_target_arg(args) and args.get("kind") is int \
				and int(args.kind) >= WEAPON_REVOLVER \
				and int(args.kind) <= WEAPON_SNIPER \
				and args.get("amount") is int and int(args.amount) >= 1 \
				and int(args.amount) <= 500
		"teleport_to":
			var position: Variant = args.get("position")
			return _valid_admin_target_arg(args) and position is Vector3 \
				and _finite_vec(position) and not _outside_world(position)
		"grant_admin", "revoke_admin", "kill", "heal":
			return args.size() == 1 and _valid_admin_target_arg(args)
	return false


func _valid_admin_target_arg(args: Dictionary) -> bool:
	return args.get("target") is int and int(args.target) > 0 \
		and int(args.target) <= 0x7fffffff


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
		healing_progress: float, vehicle_kind := -1, vehicle_id := "",
		vehicle_aux := Vector3.ZERO, flying := false) -> bool:
	if not _finite_vec(pos) or not _finite_vec(vel) or not is_finite(yaw) \
			or not is_finite(rope_tail) or not is_finite(healing_progress):
		return false
	var allow_fast_fall := vehicle_kind == -1 and not _swinging and not flying
	if _outside_world(pos) or not _valid_actor_velocity(vel, allow_fast_fall) \
			or anim < 0 \
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
	if not _finite_vec(vehicle_aux) \
			or not _valid_vehicle_state_format(vehicle_kind, vehicle_id):
		return false
	return true


func _valid_vehicle_state_format(vehicle_kind: int, vehicle_id: String) -> bool:
	if vehicle_kind == -1:
		return vehicle_id.is_empty()
	return _valid_vehicle_kind(vehicle_kind) \
		and _valid_vehicle_id(vehicle_id)


func _valid_vehicle_kind(vehicle_kind: int) -> bool:
	return vehicle_kind >= 0 and vehicle_kind <= MAX_VEHICLE_KIND


## Server-only authorization for the vehicle portion of a peer state packet.
## On-foot state needs no claim; mounted state must name the exact vehicle seat
## currently held by that sender, so another client's machine cannot be moved.
func _sender_owns_vehicle_state(sender: int, vehicle_kind: int,
		vehicle_id: String) -> bool:
	if not _valid_vehicle_state_format(vehicle_kind, vehicle_id):
		return false
	if vehicle_kind == -1:
		return true
	return claimed_vehicles.has(vehicle_id) \
		and int(claimed_vehicles[vehicle_id]) == sender \
		and _canonical_vehicle_kind(vehicle_id) == vehicle_kind


func _valid_banana_id(id: String) -> bool:
	return _valid_stable_id(id, "b:", MAX_BANANA_ID_LENGTH)


func _valid_supply_chest_id(chest_id: String) -> bool:
	return _valid_stable_id(chest_id, "s:", MAX_CHEST_ID_LENGTH)


func _valid_vehicle_id(vehicle_id: String) -> bool:
	return _valid_stable_id(vehicle_id, "v:", MAX_VEHICLE_ID_LENGTH)


func _valid_admin_vehicle_id_for_creator(vehicle_id: String,
		creator: int) -> bool:
	if creator <= 0 or not _valid_vehicle_id(vehicle_id):
		return false
	var prefix := "v:admin#%d-" % creator
	if not vehicle_id.begins_with(prefix):
		return false
	var serial_text := vehicle_id.substr(prefix.length())
	if not serial_text.is_valid_int():
		return false
	var serial := int(serial_text)
	return serial >= 1 and serial <= MAX_ADMIN_VEHICLE_SERIAL \
		and serial_text == str(serial)


func _admin_vehicle_creator_from_id(vehicle_id: String) -> int:
	const PREFIX := "v:admin#"
	if not vehicle_id.begins_with(PREFIX):
		return 0
	var payload := vehicle_id.substr(PREFIX.length())
	var separator := payload.find("-")
	if separator <= 0:
		return 0
	var creator_text := payload.substr(0, separator)
	if not creator_text.is_valid_int():
		return 0
	var creator := int(creator_text)
	return creator if creator_text == str(creator) \
		and _valid_admin_vehicle_id_for_creator(vehicle_id, creator) else 0


func _valid_dynamic_vehicle_spawn(vehicle_id: String, vehicle_kind: int,
		spawn_position, spawn_yaw) -> bool:
	return _admin_vehicle_creator_from_id(vehicle_id) > 0 \
		and _valid_vehicle_kind(vehicle_kind) \
		and spawn_position is Vector3 and _finite_vec(spawn_position) \
		and not _outside_world(spawn_position) \
		and (spawn_yaw is float or spawn_yaw is int) \
		and is_finite(float(spawn_yaw)) and absf(float(spawn_yaw)) <= TAU


## Rest payload: [pos: Vector3, yaw: float, pitch: float, roll: float].
func _valid_vehicle_rest(rest) -> bool:
	if not (rest is Array) or rest.size() != 4:
		return false
	if not (rest[0] is Vector3) or not _finite_vec(rest[0]) \
			or _outside_world(rest[0]):
		return false
	for i in range(1, 4):
		if not (rest[i] is float or rest[i] is int) \
				or not is_finite(float(rest[i])):
			return false
	return true


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
		and _valid_actor_velocity(velocity, true) and impulse.length() <= 180.0


## Live actors retain uncapped physical freefall. Once defeated, that velocity
## seeds nine separate rigid bodies, so bound only the replicated ragdoll's
## initial presentation impulse to the project's pre-existing network envelope.
## This prevents one accepted fast-fall payload from becoming a physics attack
## on every peer while preserving its direction and all ordinary momentum.
func _safe_defeat_velocity(value: Vector3) -> Vector3:
	return value.limit_length(MAX_PLAYER_SPEED)


## Vehicles, swings, ascent and planar movement keep the strict speed envelope.
## Only negative Y on an ordinary on-foot state gets the larger physically
## unreachable network allowance required to replicate uncapped freefall.
func _valid_actor_velocity(value: Vector3, allow_fast_fall: bool) -> bool:
	if not _finite_vec(value):
		return false
	if not allow_fast_fall:
		return value.length() <= MAX_PLAYER_SPEED
	return Vector2(value.x, value.z).length() <= MAX_PLAYER_SPEED \
		and value.y <= MAX_PLAYER_SPEED \
		and value.y >= -MAX_ON_FOOT_FALL_REPLICATION_SPEED


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
