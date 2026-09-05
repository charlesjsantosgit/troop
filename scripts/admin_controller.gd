class_name AdminController
extends Node
## The single place every admin verb funnels through — the F8 panel and slash
## commands both call these methods, so UI and chat can never drift apart.
## Local-target actions apply immediately; remote targets go through
## Net.admin_command, which the server re-validates against its proven-key
## admin grant list.

var main: Node
var world: Node3D
var chat: ChatBox
var _spawn_serial := 0
var _admin_vehicle_serial := 0
var vehicle_catalog: Control
var _catalog_layer: CanvasLayer
var _catalog_was_paused := false

const BIOME_BY_NAME := {
	"rainforest": Gen.Biome.RAINFOREST,
	"bamboo": Gen.Biome.BAMBOO_GROVE,
	"wetland": Gen.Biome.WETLAND,
	"highland": Gen.Biome.HIGHLAND,
	"plains": Gen.Biome.PLAINS,
	"grassland": Gen.Biome.GRASSLAND,
	"grasslands": Gen.Biome.GRASSLAND,
	"rocky": Gen.Biome.ROCKY_MOUNTAINS,
	"desert": Gen.Biome.DESERT,
	"tundra": Gen.Biome.TUNDRA,
	"ice": Gen.Biome.ICE,
	"ocean": Gen.Biome.OCEAN,
	"lake": Gen.Biome.LAKE,
}


func configure(owner_main: Node, owner_world: Node3D,
		chat_box: ChatBox) -> void:
	main = owner_main
	world = owner_world
	chat = chat_box
	Net.admin_action.connect(_on_remote_admin_action)
	Net.admin_notice.connect(feedback)


func _player() -> MonkeyPlayer:
	return world.local_player if world else null


func feedback(text: String) -> void:
	if chat:
		chat.add_system_line(text)


# ---- verbs -----------------------------------------------------------------


func kill_target(peer_id: int) -> void:
	if peer_id == Net.local_id():
		if _player():
			_player().admin_kill()
		feedback("Respawning you.")
	else:
		Net.admin_command("kill", {"target": peer_id})
		feedback("Sent KO to %s." % _peer_name(peer_id))


func heal_target(peer_id: int) -> void:
	if peer_id == Net.local_id():
		if _player():
			_player().admin_heal()
		feedback("Healed to full.")
	else:
		Net.admin_command("heal", {"target": peer_id})
		feedback("Healed %s." % _peer_name(peer_id))


func give_ammo(peer_id: int, weapon_kind: int, amount: int) -> void:
	amount = clampi(amount, 1, 500)
	weapon_kind = clampi(weapon_kind, 0, 3)
	if peer_id == Net.local_id():
		if _player():
			_player().receive_supply_loot(weapon_kind, amount, 0)
	else:
		Net.admin_command("give_ammo",
			{"target": peer_id, "kind": weapon_kind, "amount": amount})
	feedback("Gave %d %s ammo to %s." % [amount,
		["banana", "shotgun", "SMG", "sniper"][weapon_kind],
		_peer_name(peer_id)])


func give_all_weapons() -> void:
	if not _player():
		return
	for kind in range(4):
		_player().receive_supply_loot(kind, [48, 24, 120, 30][kind], 0)
	_player().receive_supply_loot(0, 0, 5)
	feedback("Full loadout: every reserve topped up plus 5 bandages.")


func toggle_fly() -> bool:
	if not _player():
		return false
	var now_flying: bool = not _player().fly_mode
	_player().set_fly_mode(now_flying)
	feedback("Angel wings %s." % ("unfurled — hold SPACE to rise, CTRL to sink"
		if now_flying else "folded away"))
	return now_flying


## Deliver any machine to the admin's position, in every session type. The id
## carries the local peer id so two admins can never mint the same vehicle;
## online, other players see it materialize through the normal driving state
## stream the first time it is ridden.
func spawn_vehicle(kind_word: String) -> bool:
	if not _player():
		return false
	var kinds := {"bike": Vehicle.Kind.BIKE, "motorcycle": Vehicle.Kind.BIKE,
		"jeep": Vehicle.Kind.JEEP, "boat": Vehicle.Kind.BOAT,
		"airboat": Vehicle.Kind.BOAT, "jet": Vehicle.Kind.JET}
	var query := kind_word.to_lower().strip_edges()
	if query.is_empty():
		open_vehicle_catalog.call_deferred()
		return true
	if query in ["park_rowboat","rowboat"]:
		var boats := preload("res://scripts/city_park_layout.gd").boat_definitions()
		if is_instance_valid(main.frontier_controller) and main.frontier_controller.current_planet()=="earth":
			main.frontier_controller.city._teleport(boats[0].exit+Vector3(0,.1,0))
			feedback("Lake rowboats are ready at the park dock. Press E beside one to board.")
			return true
		feedback("Visit Earth to use the rowboats at Lantern Central Park.")
		return false
	var model := preload("res://scripts/city_vehicle_models.gd").index_for_id(query)
	if model>=0: kinds[query]=Vehicle.Kind.JEEP
	if not kinds.has(query):
		feedback("Unknown vehicle. Use /vehicle to search the complete catalog.")
		return false
	_admin_vehicle_serial += 1
	var p: MonkeyPlayer = _player()
	var forward := Vector3(sin(p.rig.yaw_angle() + PI), 0.0,
		cos(p.rig.yaw_angle() + PI))
	var delivery_distance := 12.0 if query=="jet" else 6.5
	var spot := p.global_position + forward * delivery_distance
	var vehicle_id := "v:admin#%d-%d" % [Net.local_id(), _admin_vehicle_serial]
	if model>=0: vehicle_id += ":"+query
	var vehicle_kind := int(kinds[query])
	var spawn_yaw := atan2(forward.x, forward.z)
	if not Net.register_admin_vehicle(vehicle_id, vehicle_kind, spot, spawn_yaw):
		feedback("Vehicle delivery could not be registered with the authority.")
		return false
	# The authority's spawn signal creates the node on every peer, including this
	# one. Waiting for that signal prevents a rejected asynchronous request from
	# leaving a client-only ghost machine behind.
	feedback("%s delivery requested — it will appear in front of you." % \
		Vehicle.KIND_NAMES[vehicle_kind].capitalize())
	return true


## Teleport to the machines: the airstrip apron, the origin motor pool, the
## lake dock, or the nearest hidden wilderness vehicle.
const VEHICLE_SPOTS := {
	"airstrip": "airstrip", "strip": "airstrip", "runway": "airstrip",
	"jet": "airstrip",
	"pool": "pool", "motorpool": "pool", "garage": "pool",
	"dock": "dock", "boat": "dock", "airboat": "dock",
	"machine": "machine", "vehicle": "machine", "wild": "machine",
}


func open_vehicle_catalog() -> void:
	if not Net.is_admin or not is_instance_valid(_player()): return
	if is_instance_valid(vehicle_catalog): return
	_catalog_was_paused=get_tree().paused
	_catalog_layer=CanvasLayer.new()
	_catalog_layer.layer=100
	add_child(_catalog_layer)
	vehicle_catalog=load("res://scripts/vehicle_catalog_panel.gd").new()
	vehicle_catalog.configure(self)
	vehicle_catalog.close_requested.connect(close_vehicle_catalog)
	_catalog_layer.add_child(vehicle_catalog)
	if not Net.active: get_tree().paused=true
	Input.mouse_mode=Input.MOUSE_MODE_VISIBLE


func close_vehicle_catalog() -> void:
	if is_instance_valid(_catalog_layer): _catalog_layer.queue_free()
	vehicle_catalog=null
	_catalog_layer=null
	get_tree().paused=_catalog_was_paused
	if not get_tree().paused and DisplayServer.get_name()!="headless": Input.mouse_mode=Input.MOUSE_MODE_CAPTURED


func teleport_to_vehicle_spot(query: String) -> bool:
	var p := _player()
	if not p or not VEHICLE_SPOTS.has(query):
		return false
	if Gen.debug_world:
		p.admin_teleport(Vector3(0.0, 3.0, 12.0))
		feedback("Debug world: every machine is parked at the yard "
			+ "just north of spawn.")
		return true
	match VEHICLE_SPOTS[query]:
		"airstrip":
			if not Gen.airstrip_valid:
				feedback("This world generated without an airstrip.")
				return true
			var apron := Gen.airstrip_apron_world()
			p.admin_teleport(Vector3(apron.x + 5.0,
				Gen.airstrip_elevation + 0.6, apron.y + 5.0))
			feedback("Airstrip apron — six jets wait in the nearby hangars; the "
				+ "runway runs %d m." % int(Gen.AIRSTRIP_LENGTH))
		"pool":
			var pool_height := Gen.height(40.0, 4.0)
			p.admin_teleport(Vector3(40.0, pool_height + 0.6, 4.0))
			feedback("Origin motor pool — dual-sport and jeep, east of "
				+ "the arena.")
		"dock":
			if not Gen.boat_dock_valid:
				feedback("No lake within dock range on this seed — try "
					+ "/vehicle boat instead.")
				return true
			var shore := _shore_near_dock()
			p.admin_teleport(shore + Vector3.UP * 0.6)
			feedback("Lakeside dock — the airboat floats just offshore.")
		"machine":
			var found := _nearest_wilderness_vehicle(p.global_position)
			if found.is_empty():
				feedback("No wilderness machine within ~1.5 km — they "
					+ "average one per twenty chunks; try again elsewhere.")
				return true
			var target: Vector3 = found.pos
			p.admin_teleport(target + Vector3(3.0, 0.8, 3.0))
			feedback(("Found a hidden %s %.0f m out — it is right beside "
				+ "you.") % [Vehicle.KIND_NAMES[int(found.kind)].to_lower(),
				found.distance])
	return true


func _shore_near_dock() -> Vector3:
	var toward := -Vector2(Gen.boat_dock_pos.x, Gen.boat_dock_pos.z) \
		.normalized()
	var probe := Vector2(Gen.boat_dock_pos.x, Gen.boat_dock_pos.z)
	for step in range(14):
		probe += toward * 3.0
		var h := Gen.height(probe.x, probe.y)
		if h > Gen.WATER_Y + 0.25:
			return Vector3(probe.x, h, probe.y)
	return Vector3(Gen.boat_dock_pos.x, Gen.WATER_Y + 0.4,
		Gen.boat_dock_pos.z)


## Ring-scan chunk layouts outward from the player for deterministic
## wilderness spawn definitions (curated pool/strip/dock/admin ids excluded).
func _nearest_wilderness_vehicle(from: Vector3) -> Dictionary:
	var center := Vector2i(floori(from.x / Gen.CHUNK),
		floori(from.z / Gen.CHUNK))
	var best: Dictionary = {}
	var best_distance := INF
	for ring in range(0, 31):
		for dx in range(-ring, ring + 1):
			for dz in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dz)) != ring:
					continue
				var cx := center.x + dx
				var cz := center.y + dz
				for def in Gen.vehicle_layout(cx, cz):
					var vid := str(def.get("id", ""))
					if not vid.begins_with("v:%d," % cx):
						continue   # curated spawn, not a wilderness find
					var pos: Vector3 = def.get("pos", Vector3.ZERO)
					var distance := from.distance_to(pos)
					if distance < best_distance:
						best_distance = distance
						best = {"pos": pos, "kind": def.get("kind", 0),
							"distance": distance}
		# A hit plus one extra ring of margin beats scanning all 31 rings.
		if not best.is_empty() and ring > 2 \
				and best_distance < float(ring - 1) * Gen.CHUNK:
			break
	return best


func teleport_to_biome(biome_name: String) -> bool:
	if not _player():
		return false
	var query := biome_name.to_lower().strip_edges()
	var destination := Vector3.ZERO
	if query == "mountains" or query == "mountain":
		destination = _find_mountain()
	elif BIOME_BY_NAME.has(query):
		destination = _find_biome(BIOME_BY_NAME[query])
	else:
		feedback("Unknown place. Try rainforest, bamboo, wetland, highland, "
			+ "or mountains.")
		return false
	if destination == Vector3.ZERO:
		feedback("Could not find %s within range." % query)
		return false
	_player().admin_teleport(destination + Vector3.UP * 2.0)
	feedback("Teleported to %s." % query)
	return true


func teleport_to_player(peer_id: int) -> void:
	if not world or not _player():
		return
	var puppet: Node3D = world.puppets.get(peer_id)
	if puppet:
		_player().admin_teleport(puppet.global_position + Vector3(1.5, 1.0, 1.5))
		feedback("Teleported to %s." % _peer_name(peer_id))
	else:
		feedback("%s is not in view of this client yet." % _peer_name(peer_id))


func travel_to_realm(realm: int, peer_id := -1) -> bool:
	var target := Net.local_id() if peer_id < 0 else peer_id
	if realm not in [Net.PlayerRealm.EARTH, Net.PlayerRealm.MOON]:
		return false
	Net.admin_command("travel_realm", {"target": target, "realm": realm})
	feedback("Sending %s to %s." % [_peer_name(target),
		"the Moon" if realm == Net.PlayerRealm.MOON else "Earth"])
	return true


func kick_player(peer_id: int, reason := "Kicked by admin") -> void:
	var clean_reason: String = str(reason).left(Net.MAX_CHAT_LENGTH)
	Net.admin_command("kick", {"target": peer_id, "reason": clean_reason})
	feedback("Kicked %s." % _peer_name(peer_id))


func ban_player(peer_id: int, minutes: int) -> void:
	minutes = clampi(minutes, 1, Net.MAX_BAN_MINUTES)
	Net.admin_command("ban", {"target": peer_id, "minutes": minutes})
	feedback("Banned %s from the public canopy for %d minutes." % [
		_peer_name(peer_id), minutes])


func grant_admin(peer_id: int) -> void:
	if peer_id == Net.local_id():
		feedback("Choose another connected player to grant admin.")
		return
	Net.admin_command("grant_admin", {"target": peer_id})


func revoke_admin(peer_id: int) -> void:
	if peer_id == Net.local_id():
		feedback("You cannot revoke your own active admin session.")
		return
	Net.admin_command("revoke_admin", {"target": peer_id})


static func parse_time_value(value: String) -> float:
	var names := {"day":12.0,"noon":12.0,"night":22.0,"midnight":0.0,"dawn":6.0,"dusk":18.0,"sunset":18.0}
	if names.has(value):
		return float(names[value])
	if value.contains(":"):
		var pieces := value.split(":")
		if pieces.size() != 2 or not pieces[0].is_valid_int() or not pieces[1].is_valid_int():
			return -1.0
		var hour := int(pieces[0])
		var minute := int(pieces[1])
		return float(hour) + float(minute) / 60.0 if hour >= 0 and hour < 24 and minute >= 0 and minute < 60 else -1.0
	if value.is_valid_float() and is_finite(float(value)):
		return wrapf(float(value), 0.0, 24.0)
	return -1.0


func set_time(hour: float) -> void:
	var normalized := wrapf(hour, 0.0, 24.0)
	if Net.active:
		Net.admin_command("set_time", {"hour": normalized})
	elif world:
		if is_instance_valid(world.frontier):
			world.frontier.set_solar_hour(normalized)
		else:
			world.set_time_of_day_override(normalized)
		feedback("Time set to %02d:%02d." % [int(normalized),
			int(fmod(normalized, 1.0) * 60.0)])


func clear_time() -> void:
	if Net.active:
		Net.admin_command("clear_time", {})
	elif world:
		if is_instance_valid(world.frontier):
			world.frontier.clear_solar_hour()
		else:
			world.clear_time_of_day_override()
		feedback("Clock released back to the shared cycle.")


## Bot spawning simulates locally, so it is limited to offline sessions
## (solo and the debug world) where this machine owns every actor.
func can_spawn() -> bool:
	return not Net.active


func spawn_monkey(kind: String) -> bool:
	if not can_spawn():
		feedback("Spawning is available in solo and the debug world only.")
		return false
	if not world or not _player():
		return false
	var at: Vector3 = _player().global_position \
		+ _player().global_basis.z * -3.0 + Vector3.UP * 1.0
	match kind:
		"peel":
			if world.ai_opponent and is_instance_valid(world.ai_opponent):
				feedback("Captain Peel is already prowling.")
				return false
			world.spawn_solo_ai()
			feedback("Captain Peel joins the duel.")
		"swinger", "friendly":
			world.spawn_friendly(FriendlyMonkey.Mode.SWINGER, at)
			feedback("A carefree swinger arrives.")
		"follower":
			world.spawn_friendly(FriendlyMonkey.Mode.FOLLOWER, at, _player())
			feedback("A loyal follower falls in behind you.")
		"statue":
			world.spawn_friendly(FriendlyMonkey.Mode.STATUE, at)
			feedback("A perfectly patient monkey takes its post.")
		"villager":
			world.spawn_friendly(FriendlyMonkey.Mode.VILLAGER, at)
			feedback("A villager sets up shop. Walk up and press E to trade.")
		_:
			feedback("Unknown monkey. Try peel, swinger, follower, statue, "
				+ "or villager.")
			return false
	return true


func announce(text: String) -> void:
	Net.admin_command("announce", {"text": text.left(Net.MAX_CHAT_LENGTH)})


# ---- remote-applied actions (this client is the target) --------------------


func _on_remote_admin_action(action: String, args: Dictionary) -> void:
	var player := _player()
	if not player:
		return
	match action:
		"kill":
			player.admin_kill()
		"heal":
			player.admin_heal()
		"give_ammo":
			player.receive_supply_loot(clampi(int(args.get("kind", 0)), 0, 3),
				clampi(int(args.get("amount", 0)), 0, 500), 0)
		"teleport_to":
			var destination: Variant = args.get("position")
			if destination is Vector3 and (destination as Vector3).is_finite() \
					and (destination as Vector3).length() < 1000000.0:
				player.admin_teleport(destination)
		"travel_realm":
			var realm := int(args.get("realm", Net.PlayerRealm.EARTH))
			if main and main.expedition_manager:
				main.expedition_manager.show_notice(
					"Admin transfer authorized: %s." % (
						"Moon" if realm == Net.PlayerRealm.MOON else "Earth"))


# ---- slash commands --------------------------------------------------------


func run_command(text: String) -> void:
	if not Net.is_admin:
		feedback("Admin commands are locked on this session.")
		return
	var parts := text.trim_prefix("/").split(" ", false)
	if parts.is_empty():
		return
	var verb := parts[0].to_lower()
	match verb:
		"help":
			feedback("— ADMIN COMMANDS —")
			feedback("/kill [player] · /heal [player] — KO or restore")
			feedback("/give <banana|shotgun|smg|sniper> <rounds> [player]")
			feedback("/fly — toggle angel wings (SPACE up, CTRL down)")
			feedback("/tp <rainforest|bamboo|wetland|highland|plains|grassland"
				+ "|rocky|desert|tundra|ice|ocean|lake|mountains"
				+ "|player-name>")
			feedback("/moon [player] · /earth [player] — realm travel")
			feedback("/tp <airstrip|pool|dock|machine> — to the vehicles")
			feedback("/spawn <peel|swinger|follower|statue|villager>")
			feedback("/vehicle — search every vehicle; /vehicle <name> delivers a match")
			feedback("/time <hour|clear> — set or release the clock")
			feedback("/kick <player> · /ban <player> <minutes>")
			feedback("/admin <exact-player|peer-id> · /unadmin <exact-player|peer-id>")
			feedback("/say <text> — server-wide announcement")
			feedback("F8 opens the same commands as buttons.")
		"kill":
			kill_target(_resolve_peer(parts, 1))
		"heal":
			heal_target(_resolve_peer(parts, 1))
		"fly":
			toggle_fly()
		"vehicle", "ride":
			spawn_vehicle(parts[1] if parts.size() > 1 else "")
		"give":
			var kind := _weapon_kind(parts[1] if parts.size() > 1 else "")
			var amount := int(parts[2]) if parts.size() > 2 else 30
			give_ammo(_resolve_peer(parts, 3), kind, amount)
		"tp", "teleport":
			var where := parts[1].to_lower() if parts.size() > 1 else ""
			if where == "moon":
				travel_to_realm(Net.PlayerRealm.MOON)
			elif where == "earth":
				travel_to_realm(Net.PlayerRealm.EARTH)
			elif BIOME_BY_NAME.has(where) or where.begins_with("mountain"):
				teleport_to_biome(where)
			elif VEHICLE_SPOTS.has(where):
				teleport_to_vehicle_spot(where)
			else:
				var peer := _find_peer_by_name(where)
				if peer != 0:
					teleport_to_player(peer)
				else:
					teleport_to_biome(where)
		"spawn":
			spawn_monkey(parts[1].to_lower() if parts.size() > 1 else "")
		"moon", "tomoon":
			travel_to_realm(Net.PlayerRealm.MOON, _resolve_peer(parts, 1))
		"earth", "toearth":
			travel_to_realm(Net.PlayerRealm.EARTH, _resolve_peer(parts, 1))
		"time":
			var value := parts[1].to_lower() if parts.size() == 2 else ""
			if value == "clear":
				clear_time()
			else:
				var hour := parse_time_value(value)
				if hour >= 0.0:
					set_time(hour)
				else:
					feedback("Usage: /time 21:30, /time night, /time day, or /time clear")
		"kick":
			var target := _find_peer_by_name(parts[1] if parts.size() > 1 else "")
			if target != 0:
				kick_player(target)
			else:
				feedback("No such player.")
		"ban":
			var target := _find_peer_by_name(parts[1] if parts.size() > 1 else "")
			if target != 0:
				ban_player(target,
					int(parts[2]) if parts.size() > 2 else 60)
			else:
				feedback("No such player.")
		"admin", "grantadmin":
			var target := _find_peer_for_admin_grant(
				parts[1] if parts.size() > 1 else "")
			if target > 0:
				grant_admin(target)
			elif target < 0:
				feedback("Ambiguous player — use an exact name or peer ID from F8.")
			else:
				feedback("No such player.")
		"unadmin", "revokeadmin":
			var target := _find_peer_for_admin_grant(
				parts[1] if parts.size() > 1 else "")
			if target > 0:
				revoke_admin(target)
			elif target < 0:
				feedback("Ambiguous player — use an exact name or peer ID from F8.")
			else:
				feedback("No such player.")
		"say", "announce":
			announce(" ".join(parts.slice(1)))
		_:
			feedback("Unknown command. /help lists everything.")


func _weapon_kind(word: String) -> int:
	match word.to_lower():
		"banana", "revolver", "pistol":
			return 0
		"shotgun", "shells":
			return 1
		"smg", "auto":
			return 2
		"sniper", "rifle":
			return 3
	return 0


func _resolve_peer(parts: PackedStringArray, index: int) -> int:
	if parts.size() > index:
		var found := _find_peer_by_name(parts[index])
		if found != 0:
			return found
	return Net.local_id()


func _find_peer_by_name(query: String) -> int:
	if query.is_empty():
		return 0
	for peer_id in Net.names:
		if str(Net.names[peer_id]).to_lower().begins_with(query.to_lower()):
			return peer_id
	return 0


## Admin identity changes require an unambiguous target. A decimal peer ID is
## exact; names accept an exact case-insensitive match or one unique prefix.
## -1 means ambiguous so the command can explain how to disambiguate.
func _find_peer_for_admin_grant(query: String) -> int:
	var clean := query.strip_edges()
	if clean.is_empty():
		return 0
	if clean.is_valid_int():
		var peer_id := int(clean)
		return peer_id if Net.names.has(peer_id) else 0
	var lowered := clean.to_lower()
	var exact: Array[int] = []
	var prefixes: Array[int] = []
	for peer_id in Net.names:
		var candidate := str(Net.names[peer_id]).to_lower()
		if candidate == lowered:
			exact.append(int(peer_id))
		elif candidate.begins_with(lowered):
			prefixes.append(int(peer_id))
	if exact.size() == 1:
		return exact[0]
	if exact.size() > 1 or prefixes.size() > 1:
		return -1
	return prefixes[0] if prefixes.size() == 1 else 0


func _peer_name(peer_id: int) -> String:
	if peer_id == Net.local_id():
		return "yourself"
	return str(Net.names.get(peer_id, "Monkey-%d" % peer_id))


func _find_biome(biome: int) -> Vector3:
	for ring in range(1, 40):
		for cx in range(-ring, ring + 1):
			for cz in [-ring, ring]:
				var spot := _biome_probe(cx, cz, biome)
				if spot != Vector3.ZERO:
					return spot
		for cz in range(-ring + 1, ring):
			for cx in [-ring, ring]:
				var spot := _biome_probe(cx, cz, biome)
				if spot != Vector3.ZERO:
					return spot
	return Vector3.ZERO


func _biome_probe(cx: int, cz: int, biome: int) -> Vector3:
	var x := (float(cx) + 0.5) * Gen.CHUNK
	var z := (float(cz) + 0.5) * Gen.CHUNK
	var h := Gen.height(x, z)
	if h > Gen.WATER_Y + 1.0 and Gen.biome_at(x, z) == biome:
		return Vector3(x, h, z)
	return Vector3.ZERO


func _find_mountain() -> Vector3:
	var best := Vector3.ZERO
	for gx in range(-24, 25):
		for gz in range(-24, 25):
			var x := float(gx) * 96.0
			var z := float(gz) * 96.0
			if Gen.mountain_influence(x, z) > 0.45:
				var h := Gen.height(x, z)
				if h > best.y:
					best = Vector3(x, h, z)
	return best
