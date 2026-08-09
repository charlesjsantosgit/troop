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
	var gen := root.get_node("Gen")

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

	# The installation proves possession of a private RSA key. The server sees
	# only its public key and a fresh context-bound signature.
	var crypto := Crypto.new()
	var key_a: CryptoKey = crypto.generate_rsa(2048)
	var key_b: CryptoKey = crypto.generate_rsa(2048)
	var identity_a: Dictionary = net._parse_public_identity(
		key_a.save_to_string(true))
	var identity_b: Dictionary = net._parse_public_identity(
		key_b.save_to_string(true))
	var fingerprint_a := str(identity_a.get("fingerprint", ""))
	var fingerprint_b := str(identity_b.get("fingerprint", ""))
	_check(not identity_a.is_empty() and not identity_b.is_empty() \
		and fingerprint_a != fingerprint_b \
		and net._valid_key_fingerprint(fingerprint_a) \
		and not net._valid_key_fingerprint(fingerprint_a.to_upper()) \
		and not key_a.save_to_string(false) in identity_a.values(),
		"registration identity canonicalizes public keys without exposing private key material")
	var nonce_a := crypto.generate_random_bytes(net.ADMIN_NONCE_BYTES)
	var nonce_b := crypto.generate_random_bytes(net.ADMIN_NONCE_BYTES)
	var context_a: PackedByteArray = net._registration_context_hash(88,
		"Target", net.PROTOCOL_VERSION, "0.3.6", fingerprint_a, nonce_a)
	var dirty_name := "  Target\t Pilot\n" + "Long".repeat(8)
	var clean_name: String = net._sanitize_name(dirty_name, 88)
	var dirty_name_context: PackedByteArray = net._registration_context_hash(88,
		dirty_name, net.PROTOCOL_VERSION, "0.3.6", fingerprint_a, nonce_a)
	var clean_name_context: PackedByteArray = net._registration_context_hash(88,
		clean_name, net.PROTOCOL_VERSION, "0.3.6", fingerprint_a, nonce_a)
	_check(clean_name.length() <= net.MAX_NAME_LENGTH \
		and not clean_name.contains("\t") and not clean_name.contains("\n") \
		and dirty_name_context == clean_name_context,
		"registration proof canonicalizes filtered and truncated player names identically")
	var changed_context: PackedByteArray = net._registration_context_hash(88,
		"Target", net.PROTOCOL_VERSION, "0.3.6", fingerprint_a, nonce_b)
	var signature_a: PackedByteArray = net._sign_registration_context(
		context_a, key_a)
	var wrong_signature: PackedByteArray = net._sign_registration_context(
		context_a, key_b)
	_check(net._verify_registration_signature(context_a, signature_a,
		identity_a.key) \
		and not net._verify_registration_signature(context_a, wrong_signature,
			identity_a.key) \
		and not net._verify_registration_signature(changed_context, signature_a,
			identity_a.key),
		"challenge proof accepts the matching private key and rejects wrong-key or changed-nonce signatures")
	var bootstrap_proof: PackedByteArray = net._bootstrap_hmac(
		"bootstrap-secret", context_a)
	var wrong_bootstrap: PackedByteArray = net._bootstrap_hmac(
		"wrong-secret", context_a)
	_check(net._verify_bootstrap_hmac(bootstrap_proof, context_a,
		"bootstrap-secret") \
		and not net._verify_bootstrap_hmac(wrong_bootstrap, context_a,
			"bootstrap-secret") \
		and bootstrap_proof.size() == net.ADMIN_BOOTSTRAP_PROOF_BYTES,
		"bootstrap admin uses a constant-time checked HMAC instead of transmitting its secret")
	_check(net._valid_admin_envelope("grant_admin", {"target": 88}) \
		and net._valid_admin_envelope("revoke_admin", {"target": 88}) \
		and net._valid_admin_envelope("set_time", {"hour": 19.75}) \
		and net._valid_admin_envelope("clear_time", {}) \
		and not net._valid_admin_envelope("grant_admin",
			{"target": 88, "fingerprint": fingerprint_b}) \
		and not net._valid_admin_envelope("grant_admin", {"target": "88"}) \
		and not net._valid_admin_envelope("set_time", {"hour": NAN}) \
		and not net._valid_admin_envelope("clear_time", {"hour": 12.0}) \
		and not net._valid_admin_envelope("announce",
			{"text": "x".repeat(net.MAX_CHAT_LENGTH + 1)}),
		"admin RPC envelope bounds identity, time, key, and text payloads")
	var had_state_dir := OS.has_environment("TROOP_STATE_DIR")
	var saved_state_dir := OS.get_environment("TROOP_STATE_DIR")
	var filesystem_root := ProjectSettings.globalize_path("res://").simplify_path()
	for _depth in range(64):
		var parent_dir := filesystem_root.get_base_dir()
		if parent_dir == filesystem_root:
			break
		filesystem_root = parent_dir
	OS.set_environment("TROOP_STATE_DIR", filesystem_root)
	var root_state_path: String = net._state_file_path("root-rejection-test.json")
	if had_state_dir:
		OS.set_environment("TROOP_STATE_DIR", saved_state_dir)
	else:
		OS.unset_environment("TROOP_STATE_DIR")
	_check(root_state_path == "user://root-rejection-test.json",
		"persistent admin state rejects a filesystem root and falls back to user storage")

	var saved_is_host: bool = net.is_host
	var saved_is_dedicated: bool = net.is_dedicated
	var saved_is_admin: bool = net.is_admin
	var saved_names: Dictionary = net.names.duplicate(true)
	var saved_registered: Dictionary = net._registered.duplicate(true)
	var saved_pending: Dictionary = net._pending_registrations.duplicate(true)
	var saved_admins: Dictionary = net._admins.duplicate(true)
	var saved_peer_fingerprints: Dictionary = net._peer_key_fingerprints.duplicate(true)
	var saved_admin_fingerprints: Dictionary = net._admin_key_fingerprints.duplicate(true)
	var saved_admin_peers: Dictionary = net.admin_peers.duplicate(true)
	var saved_vehicle_kinds: Dictionary = net._vehicle_kinds.duplicate(true)
	var saved_admin_vehicle_creators: Dictionary = \
		net._admin_vehicle_creators.duplicate(true)
	var saved_vehicle_spawn_definitions: Dictionary = \
		net.vehicle_spawn_definitions.duplicate(true)
	var saved_peer_on_foot_positions: Dictionary = \
		net._peer_on_foot_positions.duplicate(true)
	var saved_vehicle_positions: Dictionary = net._vehicle_positions.duplicate(true)
	var saved_world_seed: int = net.world_seed
	var saved_gen_seed: int = gen.world_seed
	var saved_gen_debug: bool = gen.debug_world
	var saved_cycle_hour: float = net._cycle_anchor_hour
	var saved_cycle_ticks: int = net._cycle_anchor_ticks_msec
	var saved_cycle_initialized: bool = net._cycle_initialized
	net.is_host = true
	net.is_dedicated = true
	net.is_admin = false
	net.names = {77: "Bootstrap", 88: "Target"}
	net._registered = {77: true, 88: true}
	net._admins = {77: true}
	net._peer_key_fingerprints = {77: fingerprint_b, 88: fingerprint_a}
	net._admin_key_fingerprints = {}
	net._pending_registrations = {}
	net.admin_peers = {}
	net._vehicle_kinds = {}
	net._admin_vehicle_creators = {}
	net.vehicle_spawn_definitions = {}
	net._peer_on_foot_positions = {
		77: Vector3(10.0, 2.0, 10.0),
		88: Vector3(30.0, 2.0, 30.0),
	}
	net._vehicle_positions = {}
	gen.debug_world = false
	gen.setup(1337)
	net.world_seed = 1337
	_check(net._admin_target_fingerprint(77, 88) == fingerprint_a \
		and net._admin_target_fingerprint(77, 77).is_empty() \
		and net._admin_target_fingerprint(77, 99).is_empty() \
		and net._admin_target_fingerprint(99, 88).is_empty(),
		"only an authority-recognized admin can select another connected peer's proven key")
	_check(not net._fingerprint_available(fingerprint_a) \
		and not net._fingerprint_available("not-a-key") \
		and net._fingerprint_available(net._public_key_fingerprint(
			"third-installation-public-key")),
		"registration rejects malformed and concurrently duplicated key fingerprints")
	var first_hangar: Dictionary = gen.airstrip_hangar_layout()[0]
	var first_hangar_id := str(first_hangar.jet_id)
	_check(net._canonical_vehicle_kind("v:pool#bike") == gen.VEHICLE_BIKE \
		and net._canonical_vehicle_kind(first_hangar_id) == gen.VEHICLE_JET \
		and net._canonical_vehicle_kind("v:invented#jet") == -1,
		"authority resolves seeded vehicle ids and rejects invented well-formed ids")
	var pool_position: Vector3 = net._vehicle_positions["v:pool#bike"]
	net._peer_on_foot_positions[77] = pool_position + Vector3(2.0, 0.0, 0.0)
	var near_pool_claim: bool = net._vehicle_claim_in_range(77, "v:pool#bike")
	net._peer_on_foot_positions[77] = pool_position + Vector3(40.0, 0.0, 0.0)
	_check(near_pool_claim \
		and not net._vehicle_claim_in_range(77, "v:pool#bike") \
		and not net._vehicle_claim_in_range(99, "v:pool#bike"),
		"remote seat claims require the latest on-foot position near the canonical vehicle position")
	net._peer_on_foot_positions[77] = Vector3(10.0, 2.0, 10.0)
	var admin_vehicle_id := "v:admin#77-1"
	var admin_spawn := Vector3(15.0, 2.0, 10.0)
	var registered_spawns: Array[String] = []
	var on_vehicle_spawn := func(vehicle_id: String, _vehicle_kind: int,
			_spawn_position: Vector3, _spawn_yaw: float) -> void:
		registered_spawns.append(vehicle_id)
	net.vehicle_spawn_registered.connect(on_vehicle_spawn)
	var admin_vehicle_bound: bool = net._host_register_admin_vehicle(77,
		admin_vehicle_id, gen.VEHICLE_JEEP, admin_spawn, 0.35)
	var duplicate_admin_vehicle: bool = net._host_register_admin_vehicle(77,
		admin_vehicle_id, gen.VEHICLE_JEEP, admin_spawn, 0.35)
	var kind_rebind_rejected: bool = not net._host_register_admin_vehicle(77,
		admin_vehicle_id, gen.VEHICLE_JET, admin_spawn, 0.35)
	var position_rebind_rejected: bool = not net._host_register_admin_vehicle(77,
		admin_vehicle_id, gen.VEHICLE_JEEP, admin_spawn + Vector3.RIGHT, 0.35)
	var far_spawn_rejected: bool = not net._host_register_admin_vehicle(77,
		"v:admin#77-2", gen.VEHICLE_BIKE,
		Vector3(100.0, 2.0, 10.0), 0.0)
	var creator_spoof_rejected: bool = not net._host_register_admin_vehicle(88,
		"v:admin#77-2", gen.VEHICLE_BIKE, Vector3(31.0, 2.0, 30.0), 0.0)
	var non_admin_rejected: bool = not net._host_register_admin_vehicle(88,
		"v:admin#88-1", gen.VEHICLE_BIKE, Vector3(31.0, 2.0, 30.0), 0.0)
	var unbounded_spawn_rejected: bool = not net._host_register_admin_vehicle(77,
		"v:admin#77-3", gen.VEHICLE_BIKE, admin_spawn, TAU * 2.0)
	if net.vehicle_spawn_registered.is_connected(on_vehicle_spawn):
		net.vehicle_spawn_registered.disconnect(on_vehicle_spawn)
	_check(admin_vehicle_bound \
		and net._canonical_vehicle_kind(admin_vehicle_id) == gen.VEHICLE_JEEP \
		and net.vehicle_spawn_definitions.has(admin_vehicle_id) \
		and net.vehicle_spawn_definitions[admin_vehicle_id].pos == admin_spawn \
		and duplicate_admin_vehicle and kind_rebind_rejected \
		and position_rebind_rejected and far_spawn_rejected \
		and creator_spoof_rejected and non_admin_rejected \
		and unbounded_spawn_rejected \
		and registered_spawns == [admin_vehicle_id] \
		and net.vehicle_spawn_definitions.size() == 1,
		"admin delivery binds immutable kind and spawn data near its authenticated creator")
	var observed_cycle_hours: Array[float] = []
	var on_cycle_hour := func(hour: float) -> void:
		observed_cycle_hours.append(hour)
	net.cycle_hour_changed.connect(on_cycle_hour)
	var shared_clock_applied: bool = net._set_shared_cycle_hour(29.5, false)
	if net.cycle_hour_changed.is_connected(on_cycle_hour):
		net.cycle_hour_changed.disconnect(on_cycle_hour)
	_check(shared_clock_applied and observed_cycle_hours.size() == 1 \
		and absf(observed_cycle_hours[0] - 5.5) < 0.001 \
		and absf(net.authoritative_cycle_hour() - 5.5) < 0.02,
		"server time changes re-anchor one shared cycle and emit it to every world")
	net._peer_key_fingerprints.erase(88)
	var replay_context: PackedByteArray = net._registration_context_hash(99,
		"Replay", net.PROTOCOL_VERSION, "0.3.6", fingerprint_a, nonce_a)
	var replay_signature: PackedByteArray = net._sign_registration_context(
		replay_context, key_a)
	net._pending_registrations[99] = {
		"name": "Replay", "public_key": identity_a.key,
		"fingerprint": fingerprint_a, "context_hash": replay_context,
		"issued_msec": 1000,
	}
	var first_proof: Dictionary = net._consume_registration_proof(99,
		replay_signature, PackedByteArray(), 1001)
	var replayed_proof: Dictionary = net._consume_registration_proof(99,
		replay_signature, PackedByteArray(), 1002)
	net._pending_registrations[100] = {
		"name": "Wrong", "public_key": identity_a.key,
		"fingerprint": fingerprint_a, "context_hash": replay_context,
		"issued_msec": 1000,
	}
	var failed_proof: Dictionary = net._consume_registration_proof(100,
		wrong_signature, PackedByteArray(), 1001)
	_check(not first_proof.is_empty() and replayed_proof.is_empty() \
		and failed_proof.is_empty() and not net._pending_registrations.has(100),
		"registration challenges are one-shot and failed or replayed signatures cannot be reused")
	net._peer_key_fingerprints[88] = fingerprint_a
	var unauthorized_result: int = net._apply_key_admin_request(99, 88,
		true, false, false)
	var grant_result: int = net._apply_key_admin_request(77, 88,
		true, false, false)
	_check(unauthorized_result == net.ADMIN_GRANT_UNCHANGED \
		and grant_result == net.ADMIN_GRANT_UPDATED \
		and net._admins.has(88) \
		and net._admin_key_fingerprints.has(fingerprint_a),
		"server-authoritative grant persists the registered target and rejects client self-grant")
	_check(net._registration_is_admin(fingerprint_a, false) \
		and not net._registration_is_admin(fingerprint_b, false) \
		and net._registration_is_admin(fingerprint_b, true),
		"same proven public key reconnects as admin while ungranted keys require bootstrap proof")
	var public_admins: Array = net._public_admin_peer_ids()
	var admin_panel_source := FileAccess.get_file_as_string(
		"res://scripts/admin_panel.gd")
	_check(public_admins == [77, 88] \
		and not JSON.stringify(public_admins).contains(fingerprint_a) \
		and not JSON.stringify(net.admin_peers).contains(fingerprint_a) \
		and not admin_panel_source.contains("_peer_key_fingerprints") \
		and not admin_panel_source.contains("_admin_key_fingerprints") \
		and admin_panel_source.contains("MAKE ADMIN") \
		and admin_panel_source.contains("REVOKE ADMIN") \
		and admin_panel_source.contains("AdminBodyScroll"),
		"bounded F8 UI exposes peer status and controls only, never key fingerprints")
	var revoke_result: int = net._apply_key_admin_request(77, 88,
		false, false, false)
	var duplicate_revoke: int = net._apply_key_admin_request(77, 88,
		false, false, false)
	_check(revoke_result == net.ADMIN_GRANT_UPDATED \
		and duplicate_revoke == net.ADMIN_GRANT_UNCHANGED \
		and not net._admins.has(88) \
		and not net._admin_key_fingerprints.has(fingerprint_a) \
		and not net._registration_is_admin(fingerprint_a, false),
		"revoke removes current and reconnect privileges while an unchanged revoke stays unchanged")
	net._admin_key_fingerprints = {}
	for index in range(net.MAX_ADMIN_KEYS):
		net._remember_admin_fingerprint(net._public_key_fingerprint(
			"cap-public-key-%d" % index), true)
	var capped_grant: int = net._apply_key_admin_request(77, 88,
		true, false, false)
	_check(net._admin_key_fingerprints.size() == net.MAX_ADMIN_KEYS \
		and not net._remember_admin_fingerprint(
			net._public_key_fingerprint("over-cap-public-key"), true) \
		and capped_grant == net.ADMIN_GRANT_STORAGE_ERROR \
		and not net._admins.has(88),
		"persistent admin registry ceiling rejects the grant without changing session privilege")
	var resolver = load("res://scripts/admin_controller.gd").new()
	net.names = {10: "Alice", 11: "Alina", 12: "ALICE"}
	_check(resolver._find_peer_for_admin_grant("Ali") == -1 \
		and resolver._find_peer_for_admin_grant("Alice") == -1 \
		and resolver._find_peer_for_admin_grant("Alin") == 11 \
		and resolver._find_peer_for_admin_grant("12") == 12 \
		and resolver._find_peer_for_admin_grant("Nobody") == 0,
		"admin commands reject ambiguous names and accept unique prefixes or exact peer IDs")
	resolver.free()
	net.is_host = saved_is_host
	net.is_dedicated = saved_is_dedicated
	net.is_admin = saved_is_admin
	net.names = saved_names
	net._registered = saved_registered
	net._pending_registrations = saved_pending
	net._admins = saved_admins
	net._peer_key_fingerprints = saved_peer_fingerprints
	net._admin_key_fingerprints = saved_admin_fingerprints
	net.admin_peers = saved_admin_peers
	net._vehicle_kinds = saved_vehicle_kinds
	net._admin_vehicle_creators = saved_admin_vehicle_creators
	net.vehicle_spawn_definitions = saved_vehicle_spawn_definitions
	net._peer_on_foot_positions = saved_peer_on_foot_positions
	net._vehicle_positions = saved_vehicle_positions
	net.world_seed = saved_world_seed
	gen.debug_world = saved_gen_debug
	gen.setup(saved_gen_seed)
	net._cycle_anchor_hour = saved_cycle_hour
	net._cycle_anchor_ticks_msec = saved_cycle_ticks
	net._cycle_initialized = saved_cycle_initialized

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

	var empty_wraps := PackedVector3Array()
	var fast_fall := Vector3(12.0, -800.0, 5.0)
	_check(net._valid_state(Vector3(0, 1000, 0), 0.0, fast_fall, 0,
		false, Vector3.ZERO, 0.0, empty_wraps, net.WEAPON_REVOLVER, 0,
		0.0, -1, "", Vector3.ZERO),
		"ordinary on-foot state accepts physically valid fast freefall")
	_check(not net._valid_state(Vector3(0, 1000, 0), 0.0,
		Vector3(net.MAX_PLAYER_SPEED + 1.0, -800.0, 0.0), 0, false,
		Vector3.ZERO, 0.0, empty_wraps, net.WEAPON_REVOLVER, 0, 0.0,
		-1, "", Vector3.ZERO) \
		and not net._valid_state(Vector3(0, 1000, 0), 0.0,
			Vector3(0.0, net.MAX_PLAYER_SPEED + 1.0, 0.0), 0, false,
			Vector3.ZERO, 0.0, empty_wraps, net.WEAPON_REVOLVER, 0, 0.0,
			-1, "", Vector3.ZERO),
		"freefall exception keeps strict horizontal and upward speed limits")
	_check(not net._valid_state(Vector3(0, 1000, 0), 0.0, fast_fall, 0,
		true, Vector3.ZERO, 1.0, empty_wraps, net.WEAPON_REVOLVER, 0,
		0.0, -1, "", Vector3.ZERO) \
		and not net._valid_state(Vector3(0, 1000, 0), 0.0, fast_fall, 0,
			false, Vector3.ZERO, 0.0, empty_wraps, net.WEAPON_REVOLVER, 0,
			0.0, 1, "v:security#bike", Vector3.ZERO) \
		and not net._valid_state(Vector3(0, 1000, 0), 0.0, fast_fall, 0,
			false, Vector3.ZERO, 0.0, empty_wraps, net.WEAPON_REVOLVER, 0,
			0.0, -1, "", Vector3.ZERO, true),
		"swinging, mounted, and flight states retain the total velocity envelope")
	var safe_defeat_velocity: Vector3 = net._safe_defeat_velocity(fast_fall)
	_check(net._valid_defeat(Vector3(0, 1000, 0), 0.0, fast_fall,
		Vector3.ZERO),
		"physically valid fast-fall defeat passes ingress validation")
	_check(safe_defeat_velocity.length() <= net.MAX_PLAYER_SPEED + 0.001 \
			and safe_defeat_velocity.normalized().dot(
				fast_fall.normalized()) > 0.9999,
		"fast-fall defeat is bounded before spawning replicated ragdolls",
		"raw=%s safe=%s length=%.3f" % [fast_fall, safe_defeat_velocity,
			safe_defeat_velocity.length()])
	_check(not net._valid_defeat(Vector3(0, 1000, 0), 0.0,
			Vector3(0.0, -net.MAX_ON_FOOT_FALL_REPLICATION_SPEED - 1.0, 0.0),
			Vector3.ZERO) \
		and not net._valid_vine_release("v:security#fall", Vector3.ZERO,
			fast_fall, 8.0, empty_wraps),
		"impossible defeat and fast vine-release payloads stay bounded")

	var owned_vehicle := "v:security#owned"
	var other_vehicle := "v:security#other"
	var unclaimed_vehicle := "v:security#unclaimed"
	net.claimed_vehicles.clear()
	net._vehicle_kinds = {
		owned_vehicle: gen.VEHICLE_JEEP,
		other_vehicle: gen.VEHICLE_JEEP,
		unclaimed_vehicle: gen.VEHICLE_JEEP,
	}
	_check(net._sender_owns_vehicle_state(77, -1, ""),
		"ordinary on-foot state remains authorized without a vehicle claim")
	_check(not net._sender_owns_vehicle_state(77, 1, unclaimed_vehicle),
		"unclaimed vehicle state is rejected")
	net.claimed_vehicles[owned_vehicle] = 77
	net.claimed_vehicles[other_vehicle] = 88
	net._vehicle_positions[owned_vehicle] = Vector3(20.0, 2.0, 20.0)
	var accepted_release := [Vector3(21.0, 2.0, 20.0), 0.0, 0.0, 0.0]
	_check(net._valid_vehicle_release_position(owned_vehicle,
			accepted_release[0]) \
		and not net._valid_vehicle_release_position(owned_vehicle,
			Vector3(200.0, 2.0, 20.0)),
		"release rest cannot teleport away from the last accepted vehicle state")
	net._remember_vehicle_release_handoff(77, owned_vehicle, accepted_release)
	_check(net._peer_on_foot_positions[77] == accepted_release[0] \
		and net._vehicle_claim_in_range(77, owned_vehicle),
		"accepted release anchors immediate dismount and re-entry before the next on-foot packet")
	_check(not net._sender_owns_vehicle_state(77, 1, other_vehicle),
		"spoofed vehicle state owned by another peer is rejected")
	_check(net._sender_owns_vehicle_state(77, 1, owned_vehicle),
		"vehicle state matching the sender's exact claim is accepted")
	_check(not net._sender_owns_vehicle_state(77, gen.VEHICLE_JET,
			owned_vehicle) \
		and not net._sender_owns_vehicle_state(77, gen.VEHICLE_JEEP,
			"v:security#invented") \
		and not net._sender_owns_vehicle_state(77, -1, owned_vehicle) \
		and not net._sender_owns_vehicle_state(77, 1, "v:bad path#0") \
		and not net._sender_owns_vehicle_state(77, net.MAX_VEHICLE_KIND + 1,
			owned_vehicle),
		"kind-swapped, invented, and malformed vehicle state is rejected")
	net.claimed_vehicles.clear()
	net._vehicle_kinds = saved_vehicle_kinds

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


func _check(condition: bool, label: String, info := "") -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label + ((" :: " + info) if info != "" else ""))
