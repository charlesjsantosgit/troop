class_name ExpeditionManager
extends Node
## Session bridge for the standalone rocket, lunar world, suits, inventory, UI,
## and Net's authority-owned mission clock. The physical presentation remains
## deterministic on every peer; only compact crew/phase/realm state is sent.

signal local_realm_changed(realm: int)

const MOON_WORLD_OFFSET := Vector3(0.0, Net.MOON_WORLD_ORIGIN_Y, 0.0)
const ROCKET_INTERACTION_RANGE := 9.0
const SHOP_INTERACTION_RANGE := 8.5
const ROCKET_REBOARD_COOLDOWN_SECONDS := 0.45
const ROCKET_DISEMBARK_REQUEST_TIMEOUT_SECONDS := 2.0
const ROCKET_EXIT_SIDE_CLEARANCE := 3.35
const RECOVERY_EXIT_OFFSETS := [
	Vector3(4.2, 0.8, 0.0), Vector3(-4.2, 0.8, 0.0),
	Vector3(0.0, 0.8, 4.2), Vector3(0.0, 0.8, -4.2),
]
const INVENTORY_KEY_NAME := "I"
const LAUNCH_KEY_NAME := "L"
const PENDING_CHEESE_ITEM := &"_pending_moon_cheese"

var main: Node
var world: World
var rocket: LunarRocket
var moon_world: MoonWorld
var local_inventory := LunarInventory.new()
var inventory_ui: BackpackInventoryUI
var local_suit: SpaceSuitSystem
var voyage_camera: Camera3D

var _ui_layer: CanvasLayer
var _mission_panel: PanelContainer
var _mission_label: Label
var _oxygen_panel: PanelContainer
var _oxygen_label: Label
var _toast: Label
var _toast_remaining := 0.0
var _shop_overlay: Control
var _shop_balance: Label
var _last_net_phase := Net.RocketMissionPhase.EARTH_READY
var _inventories: Dictionary = {}
var _suits: Dictionary = {}
var _manifest_sync_remaining := 0.0
var _pending_cheese_quantity := 0
var _normal_backpack_visual: Node3D
var _local_realm := -1
var _local_reboard_cooldown_remaining := 0.0
var _local_disembark_request_remaining := 0.0


func configure(owner_main: Node, owner_world: World) -> void:
	main = owner_main
	world = owner_world
	name = "ExpeditionManager"
	_inventories[Net.local_id()] = local_inventory
	_build_worlds()
	_build_ui()
	_connect_network()
	_apply_authoritative_state(Net.expedition_state_snapshot())
	_apply_local_realm(Net.player_realm())
	_sync_realm_suits()


func _exit_tree() -> void:
	if rocket and is_instance_valid(rocket):
		for member in rocket.crew:
			_set_remote_crew_control(int(member.peer_id), false)
	if Net.expedition_state_changed.is_connected(_apply_authoritative_state):
		Net.expedition_state_changed.disconnect(_apply_authoritative_state)
	if Net.player_realm_changed.is_connected(_on_player_realm_changed):
		Net.player_realm_changed.disconnect(_on_player_realm_changed)
	if Net.moon_cheese_purchase_result.is_connected(
			_on_moon_cheese_purchase_result):
		Net.moon_cheese_purchase_result.disconnect(
			_on_moon_cheese_purchase_result)


func _build_worlds() -> void:
	moon_world = MoonWorld.new()
	moon_world.name = "PlayableMoon"
	moon_world.position = MOON_WORLD_OFFSET
	# Setup before entering the tree. MoonWorld._ready builds immediately, so
	# assigning the session seed after add_child would permanently retain its
	# default seed and let different sessions share the same crater layout.
	moon_world.moon_seed = Gen.world_seed ^ 0x4d4f4f4e
	moon_world.setup(moon_world.moon_seed)
	world.add_child(moon_world)
	moon_world.visible = false

	rocket = LunarRocket.new()
	world.add_child(rocket)
	var earth_transform := Transform3D(Basis(Vector3.UP, PI),
		_earth_launch_position())
	var moon_local := moon_world.landing_transform()
	var moon_transform := Transform3D(moon_world.global_basis * moon_local.basis,
		moon_world.to_global(moon_local.origin))
	var ocean_transform := Transform3D(Basis(Vector3.UP, PI * 0.35),
		_ocean_splashdown_position())
	rocket.configure_route(earth_transform, moon_transform, ocean_transform)
	rocket.freeze = true
	rocket.crew_pose_requested.connect(_on_crew_pose_requested)
	rocket.crew_suited.connect(_on_crew_suited)
	rocket.voyage_progress.connect(_on_voyage_progress)
	rocket.camera_cue.connect(_on_camera_cue)
	rocket.moon_landing_completed.connect(_on_local_rocket_moon_landing)
	rocket.splashdown_completed.connect(_on_local_rocket_splashdown)

	voyage_camera = Camera3D.new()
	voyage_camera.name = "VoyageCamera"
	voyage_camera.fov = 72.0
	voyage_camera.near = 0.08
	voyage_camera.far = 100000.0
	voyage_camera.current = false
	world.add_child(voyage_camera)


func _connect_network() -> void:
	Net.expedition_state_changed.connect(_apply_authoritative_state)
	Net.player_realm_changed.connect(_on_player_realm_changed)
	Net.moon_cheese_purchase_result.connect(
		_on_moon_cheese_purchase_result)


func _build_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "LunarExpeditionUI"
	_ui_layer.layer = 72
	add_child(_ui_layer)

	_mission_panel = PanelContainer.new()
	_mission_panel.position = Vector2(0.0, 18.0)
	_mission_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_mission_panel.offset_left = -245.0
	_mission_panel.offset_right = 245.0
	_mission_panel.offset_top = 18.0
	_mission_panel.offset_bottom = 82.0
	_mission_panel.add_theme_stylebox_override("panel",
		_panel_style(Color(0.025, 0.045, 0.085, 0.94),
			Color(0.37, 0.76, 1.0, 0.86), 14))
	_mission_label = Label.new()
	_mission_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mission_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_mission_label.add_theme_font_size_override("font_size", 17)
	_mission_label.add_theme_color_override("font_color",
		Color(0.83, 0.94, 1.0))
	_mission_panel.add_child(_mission_label)
	_mission_panel.visible = false
	_ui_layer.add_child(_mission_panel)

	_oxygen_panel = PanelContainer.new()
	_oxygen_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_oxygen_panel.offset_left = 18.0
	_oxygen_panel.offset_right = 270.0
	_oxygen_panel.offset_top = -104.0
	_oxygen_panel.offset_bottom = -22.0
	_oxygen_panel.add_theme_stylebox_override("panel",
		_panel_style(Color(0.025, 0.07, 0.10, 0.94),
			Color(0.26, 0.87, 1.0, 0.90), 13))
	_oxygen_label = Label.new()
	_oxygen_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_oxygen_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_oxygen_label.add_theme_font_size_override("font_size", 16)
	_oxygen_panel.add_child(_oxygen_label)
	_oxygen_panel.visible = false
	_ui_layer.add_child(_oxygen_panel)

	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.offset_left = -360.0
	_toast.offset_right = 360.0
	_toast.offset_top = -124.0
	_toast.offset_bottom = -76.0
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast.add_theme_font_size_override("font_size", 17)
	_toast.add_theme_color_override("font_color", Color(1.0, 0.91, 0.48))
	_toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_toast.add_theme_constant_override("shadow_offset_x", 2)
	_toast.add_theme_constant_override("shadow_offset_y", 2)
	_toast.visible = false
	_ui_layer.add_child(_toast)

	inventory_ui = BackpackInventoryUI.new()
	inventory_ui.bind_inventory(local_inventory)
	_ui_layer.add_child(inventory_ui)
	inventory_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_cheese_shop_ui()


func _build_cheese_shop_ui() -> void:
	_shop_overlay = Control.new()
	_shop_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shop_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_shop_overlay.visible = false
	_ui_layer.add_child(_shop_overlay)
	_shop_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scrim := ColorRect.new()
	scrim.color = Color(0.015, 0.025, 0.06, 0.68)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shop_overlay.add_child(scrim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shop_overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520.0, 320.0)
	panel.add_theme_stylebox_override("panel",
		_panel_style(Color(0.08, 0.075, 0.12, 0.98),
			Color(1.0, 0.82, 0.27), 20))
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 13)
	panel.add_child(column)
	var title := Label.new()
	title.text = "🧀  CRATER & CURD  ·  MOON CHEESE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.34))
	column.add_child(title)
	var patter := Label.new()
	patter.text = "‘Vacuum-aged, Earth-monkey approved!’\nMoon cheese stacks in your space backpack."
	patter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	patter.add_theme_font_size_override("font_size", 15)
	patter.add_theme_color_override("font_color", Color(0.82, 0.86, 0.94))
	column.add_child(patter)
	_shop_balance = Label.new()
	_shop_balance.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shop_balance.add_theme_font_size_override("font_size", 20)
	column.add_child(_shop_balance)
	for quantity in [1, 4]:
		var button := Button.new()
		button.text = "BUY %d MOON CHEESE  ·  🍌 %d" % [quantity,
			quantity * MoonCheeseShop.CHEESE_PRICE_BANANAS]
		button.custom_minimum_size.y = 52.0
		button.add_theme_font_size_override("font_size", 16)
		var requested: int = int(quantity)
		button.pressed.connect(func() -> void:
			_request_cheese_purchase(requested))
		column.add_child(button)
	var leave := Button.new()
	leave.text = "THANK THE CHEESEKEEPER  ·  ESC"
	leave.custom_minimum_size.y = 42.0
	leave.pressed.connect(_close_shop)
	column.add_child(leave)


static func _panel_style(fill: Color, border: Color,
		radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(12.0)
	return style


func _process(delta: float) -> void:
	if not world or not world.local_player:
		return
	_local_reboard_cooldown_remaining = maxf(
		_local_reboard_cooldown_remaining - delta, 0.0)
	_local_disembark_request_remaining = maxf(
		_local_disembark_request_remaining - delta, 0.0)
	_toast_remaining = maxf(_toast_remaining - delta, 0.0)
	_toast.visible = _toast_remaining > 0.0
	_manifest_sync_remaining -= delta
	if _manifest_sync_remaining <= 0.0:
		_manifest_sync_remaining = 0.5
		_sync_manifest(Net.expedition_state_snapshot())
		_sync_realm_suits()
	var state := Net.expedition_state_snapshot()
	var phase := int(state.get("phase", Net.RocketMissionPhase.EARTH_READY))
	if phase in [Net.RocketMissionPhase.OUTBOUND,
			Net.RocketMissionPhase.RETURN]:
		# Every peer animates the shared rocket, but only manifested passengers
		# enter the cinematic. Spectators on Earth or the Moon keep control of
		# their own camera while a different crew is in transit.
		if _local_player_is_voyaging(state):
			_update_voyage_camera(delta, -1.0, state)
		elif voyage_camera.current:
			_restore_player_camera()
		_update_mission_label(state)
	elif phase == Net.RocketMissionPhase.SPLASHDOWN_RECOVERY:
		_update_recovery_label(state)
	else:
		_update_proximity_prompt()
	_update_oxygen_ui()


func _unhandled_input(event: InputEvent) -> void:
	if not world or not world.local_player or not (event is InputEventKey) \
			or not event.pressed or event.echo:
		return
	if _shop_overlay.visible:
		if event.keycode == KEY_ESCAPE or event.physical_keycode == KEY_ESCAPE:
			_close_shop()
			get_viewport().set_input_as_handled()
		return
	if event.physical_keycode == KEY_I:
		toggle_inventory()
		get_viewport().set_input_as_handled()
		return
	if event.physical_keycode == KEY_L:
		request_launch()
		get_viewport().set_input_as_handled()
		return
	if event.physical_keycode == KEY_E and is_local_player_aboard() \
			and not rocket.is_in_transit():
		# Arm the request before calling Net: an offline/listen-host authority emits
		# the new manifest synchronously from inside this call. _sync_manifest then
		# gets one chance to place the monkey clear of the hull and suppress this
		# same E press before Player's polled interaction path can board it again.
		_local_disembark_request_remaining = \
			ROCKET_DISEMBARK_REQUEST_TIMEOUT_SECONDS
		if not Net.request_rocket_board(false):
			_local_disembark_request_remaining = 0.0
		get_viewport().set_input_as_handled()


func is_ui_open() -> bool:
	return (_shop_overlay and _shop_overlay.visible) \
		or (inventory_ui and inventory_ui.visible)


func close_ui() -> bool:
	if _shop_overlay and _shop_overlay.visible:
		_close_shop()
		return true
	if inventory_ui and inventory_ui.visible:
		inventory_ui.close_inventory()
		return true
	return false


func toggle_inventory() -> void:
	if inventory_ui.visible:
		inventory_ui.close_inventory()
		return
	if not inventory_ui.open_inventory():
		show_notice("No backpack equipped. Lunar suits include a space backpack.")


func try_interact(player: MonkeyPlayer) -> bool:
	if player != world.local_player or rocket.is_in_transit():
		return false
	var phase := int(Net.expedition_state_snapshot().get("phase",
		Net.RocketMissionPhase.EARTH_READY))
	if phase == Net.RocketMissionPhase.SPLASHDOWN_RECOVERY \
			and player.global_position.distance_to(rocket.global_position) \
				<= ROCKET_INTERACTION_RANGE:
		show_notice("Splashdown recovery in progress · boarding is temporarily locked.")
		return true
	# Consume the original disembark tap and a very short follow-through window.
	# Without this guard Input.is_action_just_pressed("grab") can still be true
	# in Player._physics_process after _unhandled_input removed the same peer.
	if _local_reboard_cooldown_remaining > 0.0 \
			or _local_disembark_request_remaining > 0.0:
		return true
	if Net.player_realm() == Net.PlayerRealm.MOON \
			and moon_world.cheese_shop \
			and player.global_position.distance_to(
				moon_world.cheese_shop.global_position) <= SHOP_INTERACTION_RANGE:
		_open_shop()
		return true
	if player.global_position.distance_to(rocket.global_position) \
			> ROCKET_INTERACTION_RANGE:
		return false
	if local_suit and Net.player_realm() == Net.PlayerRealm.MOON \
			and local_suit.oxygen_fraction() < 0.98:
		local_suit.refill_oxygen()
		show_notice("Oxygen tanks refilled from the rocket life-support manifold.")
		return true
	if Net.request_rocket_board(true):
		show_notice("Seat requested · %s launches when any crew member presses %s." % [
			LAUNCH_KEY_NAME, LAUNCH_KEY_NAME])
	return true


func request_launch() -> bool:
	if not is_local_player_aboard():
		show_notice("Board the rocket with E before launching.")
		return false
	if rocket.is_in_transit():
		return false
	var accepted := Net.request_rocket_launch()
	if accepted:
		show_notice("Launch request sent · crew manifest locked at four seats maximum.")
	return accepted


func is_local_player_aboard() -> bool:
	var crew: Array = Net.expedition_state_snapshot().get("crew", [])
	return crew.has(Net.local_id())


func admin_travel(realm: int, target_peer := -1) -> bool:
	if not Net.is_admin or realm not in [Net.PlayerRealm.EARTH,
			Net.PlayerRealm.MOON]:
		return false
	var target := Net.local_id() if target_peer < 0 else target_peer
	if not Net.names.has(target):
		return false
	Net.admin_command("travel_realm", {"target": target, "realm": realm})
	return true


func grant_normal_backpack() -> bool:
	if local_inventory.backpack_kind >= LunarInventory.Backpack.NORMAL:
		return false
	var changed := local_inventory.equip_backpack(LunarInventory.Backpack.NORMAL)
	if changed:
		_build_normal_backpack_visual()
		show_notice("Normal backpack equipped · %d compact slots." \
			% LunarInventory.NORMAL_SLOTS)
	return changed


func show_notice(message: String, seconds := 3.6) -> void:
	_toast.text = message
	_toast_remaining = seconds
	_toast.visible = true


func _apply_authoritative_state(state: Dictionary) -> void:
	if not rocket or state.is_empty():
		return
	var phase := int(state.get("phase", Net.RocketMissionPhase.EARTH_READY))
	var recovered_peer_ids: Array[int] = []
	if phase == Net.RocketMissionPhase.EARTH_READY \
			and _last_net_phase == Net.RocketMissionPhase.SPLASHDOWN_RECOVERY:
		for member in rocket.crew:
			recovered_peer_ids.append(int(member.peer_id))
	# Ready-state first, then manifest: disembark_crew is deliberately blocked in
	# transit and must see the authoritative arrival before the crew list clears.
	if phase == Net.RocketMissionPhase.MOON_READY:
		rocket.global_transform = rocket.moon_landing_transform
		rocket.apply_authoritative_clock(LunarRocket.State.LANDED_MOON,
			true, LunarRocket.OUTBOUND_DURATION_SECONDS)
	elif phase == Net.RocketMissionPhase.SPLASHDOWN_RECOVERY:
		# Recovery is authority-owned, so this direct phase mapping also places a
		# late joiner's freshly built rocket at the ocean instead of the launch pad.
		rocket.global_transform = rocket.ocean_splashdown_transform
		rocket.apply_authoritative_clock(LunarRocket.State.SPLASHDOWN,
			false, LunarRocket.RETURN_DURATION_SECONDS)
		rocket.freeze = true
	elif phase == Net.RocketMissionPhase.EARTH_READY:
		_reset_rocket_to_launchpad()
	_sync_manifest(state)
	if not recovered_peer_ids.is_empty():
		_place_recovered_crew_at_launchpad(recovered_peer_ids)
	if phase == Net.RocketMissionPhase.OUTBOUND:
		if not rocket.is_in_transit():
			rocket.launch_to_moon()
		rocket.apply_authoritative_clock(LunarRocket.state_for_elapsed(true,
			float(state.get("elapsed", 0.0))), true,
			float(state.get("elapsed", 0.0)))
	elif phase == Net.RocketMissionPhase.RETURN:
		if not rocket.is_in_transit():
			rocket.begin_return_to_earth()
		rocket.apply_authoritative_clock(LunarRocket.state_for_elapsed(false,
			float(state.get("elapsed", 0.0))), false,
			float(state.get("elapsed", 0.0)))
	_last_net_phase = phase


func _sync_manifest(state: Dictionary) -> void:
	if not rocket or state.is_empty():
		return
	var desired: Array = state.get("crew", [])
	var existing: Array = rocket.crew.duplicate()
	for member in existing:
		var peer_id := int(member.peer_id)
		if not desired.has(peer_id):
			var removed := false
			if rocket.is_in_transit():
				# Only authority actions/disconnects can alter a locked manifest.
				# They are exceptional but immediate: retaining this presentation
				# entry would keep teleporting a removed actor back into the cabin.
				removed = _force_remove_crew(peer_id)
			else:
				removed = rocket.disembark_crew(peer_id)
			if removed:
				if peer_id == Net.local_id() \
						and _local_disembark_request_remaining > 0.0:
					_finish_local_disembark()
				_set_remote_crew_control(peer_id, false)
	for peer_value in desired:
		var peer_id := int(peer_value)
		if rocket.seat_for_peer(peer_id) >= 0:
			continue
		var actor := _actor_for_peer(peer_id)
		if not actor:
			continue
		var inventory: LunarInventory = _inventory_for_peer(peer_id)
		var suit: SpaceSuitSystem = _suits.get(peer_id)
		var phase := int(state.get("phase", Net.RocketMissionPhase.EARTH_READY))
		if phase == Net.RocketMissionPhase.RETURN:
			# A return-flight snapshot can arrive before this late joiner's puppet.
			# Recreate the visible suit when the actor appears; cabin pressure keeps
			# every owner's and observer's oxygen consumption paused.
			suit = _ensure_suit_for_peer(peer_id)
			if suit:
				suit.set_vacuum_exposure(false)
		rocket.board_crew(peer_id, actor, suit, inventory, true)
	_sync_local_lock(desired.has(Net.local_id()))


func _force_remove_crew(peer_id: int) -> bool:
	for index in range(rocket.crew.size()):
		if int(rocket.crew[index].peer_id) == peer_id:
			rocket.crew.remove_at(index)
			return true
	return false


func _actor_for_peer(peer_id: int) -> Node3D:
	if peer_id == Net.local_id():
		return world.local_player
	var actor: Variant = world.puppets.get(peer_id)
	return actor as Node3D if actor is Node3D else null


func _inventory_for_peer(peer_id: int) -> LunarInventory:
	if not _inventories.has(peer_id):
		_inventories[peer_id] = LunarInventory.new()
	return _inventories[peer_id]


func _sync_local_lock(aboard: bool) -> void:
	var player := world.local_player
	if not player:
		return
	player.set_expedition_locked(aboard)


func _finish_local_disembark() -> void:
	_local_disembark_request_remaining = 0.0
	_local_reboard_cooldown_remaining = ROCKET_REBOARD_COOLDOWN_SECONDS
	var player := world.local_player if world else null
	if not player or not rocket:
		return
	# Exit through the craft's local right side, beyond the 1.55 m capsule and
	# 2.03 m landing feet. Preserve the landed craft's orientation on Earth,
	# Moon, and splashdown, while always giving the monkey a little floor margin.
	var exit_position := rocket.to_global(Vector3(
		ROCKET_EXIT_SIDE_CLEARANCE, 0.6, 0.0))
	if Net.player_realm() == Net.PlayerRealm.MOON and moon_world:
		var moon_local := moon_world.to_local(exit_position)
		moon_local.y = moon_world.height_at(moon_local.x, moon_local.z) + 1.2
		exit_position = moon_world.to_global(moon_local)
	elif Net.player_realm() == Net.PlayerRealm.EARTH:
		exit_position.y = maxf(exit_position.y,
			Gen.height(exit_position.x, exit_position.z) + 1.2)
	player.admin_teleport(exit_position)
	show_notice("Disembarked · E can board again once clear of the hatch.", 2.4)


func _place_recovered_crew_at_launchpad(peer_ids: Array[int]) -> void:
	for index in range(peer_ids.size()):
		var actor := _actor_for_peer(peer_ids[index])
		if not actor:
			continue
		var offset: Vector3 = RECOVERY_EXIT_OFFSETS[
			index % RECOVERY_EXIT_OFFSETS.size()]
		var destination := rocket.to_global(offset)
		destination.y = maxf(destination.y,
			Gen.height(destination.x, destination.z) + 1.2)
		if actor.has_method("admin_teleport"):
			actor.call("admin_teleport", destination)
		else:
			actor.global_position = destination
			if actor is CharacterBody3D:
				(actor as CharacterBody3D).velocity = Vector3.ZERO
			actor.reset_physics_interpolation()
	if peer_ids.has(Net.local_id()):
		show_notice("CREW RECOVERED · returned safely to the launch complex", 4.0)


func _set_remote_crew_control(peer_id: int, driven: bool) -> void:
	if peer_id == Net.local_id() or not world or not is_instance_valid(world):
		return
	var actor := _actor_for_peer(peer_id)
	if actor and actor.has_method("set_externally_driven"):
		actor.call("set_externally_driven", driven)


func _on_crew_pose_requested(peer_id: int, seat_transform: Transform3D) -> void:
	var actor := _actor_for_peer(peer_id)
	if not actor:
		return
	_set_remote_crew_control(peer_id, true)
	actor.global_transform = seat_transform
	if actor is CharacterBody3D:
		(actor as CharacterBody3D).velocity = Vector3.ZERO
	actor.reset_physics_interpolation()


func _on_crew_suited(peer_id: int, suit: SpaceSuitSystem,
		inventory: LunarInventory) -> void:
	_suits[peer_id] = suit
	_inventories[peer_id] = inventory
	if peer_id == Net.local_id():
		local_suit = suit
		local_inventory = inventory
		inventory_ui.bind_inventory(local_inventory)
		_wire_local_suit()


func _ensure_local_suit() -> void:
	_ensure_suit_for_peer(Net.local_id())


func _ensure_suit_for_peer(peer_id: int) -> SpaceSuitSystem:
	var actor := _actor_for_peer(peer_id)
	if not actor:
		return null
	var suit: SpaceSuitSystem = _suits.get(peer_id)
	if not is_instance_valid(suit):
		var existing := actor.get_node_or_null("SpaceSuitSystem")
		suit = existing as SpaceSuitSystem \
			if existing is SpaceSuitSystem else SpaceSuitSystem.new()
	var inventory := _inventory_for_peer(peer_id)
	if not suit.equipped and not suit.equip_for(actor, inventory):
		return null
	# The local owner advances authoritative oxygen. Other clients create only a
	# visible suit replica and must not consume a second, divergent tank.
	suit.set_vacuum_exposure(peer_id == Net.local_id())
	_suits[peer_id] = suit
	_inventories[peer_id] = inventory
	if peer_id == Net.local_id():
		local_suit = suit
		local_inventory = inventory
		inventory_ui.bind_inventory(local_inventory)
		if _normal_backpack_visual and is_instance_valid(_normal_backpack_visual):
			_normal_backpack_visual.queue_free()
		_normal_backpack_visual = null
		_wire_local_suit()
	return suit


func _build_normal_backpack_visual() -> void:
	if _normal_backpack_visual and is_instance_valid(_normal_backpack_visual) \
			or not world or not world.local_player:
		return
	var pack := Node3D.new()
	pack.name = "NormalBackpack"
	world.local_player.add_child(pack)
	_normal_backpack_visual = pack
	var canvas := StandardMaterial3D.new()
	canvas.albedo_color = Color(0.34, 0.20, 0.095)
	canvas.roughness = 0.94
	var leather := StandardMaterial3D.new()
	leather.albedo_color = Color(0.16, 0.075, 0.035)
	leather.roughness = 0.88
	_add_backpack_box(pack, "CanvasPack", Vector3(0.50, 0.58, 0.24),
		Vector3(0.0, 0.72, 0.25), canvas)
	_add_backpack_box(pack, "Flap", Vector3(0.48, 0.19, 0.05),
		Vector3(0.0, 0.91, 0.39), leather)
	for side in [-1.0, 1.0]:
		_add_backpack_box(pack, "ShoulderStrap", Vector3(0.075, 0.58, 0.055),
			Vector3(side * 0.19, 0.73, 0.095), leather)
	var roll := CylinderMesh.new()
	roll.top_radius = 0.105
	roll.bottom_radius = 0.105
	roll.height = 0.46
	roll.radial_segments = 12
	var bedroll := MeshInstance3D.new()
	bedroll.name = "Bedroll"
	bedroll.mesh = roll
	bedroll.material_override = canvas
	bedroll.position = Vector3(0.0, 0.39, 0.29)
	bedroll.rotation.z = PI * 0.5
	pack.add_child(bedroll)


static func _add_backpack_box(parent: Node3D, part_name: String,
		size: Vector3, position: Vector3, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.position = position
	instance.material_override = material
	parent.add_child(instance)


func _sync_realm_suits() -> void:
	# A puppet can be created after the realm snapshot that placed it on the
	# Moon. The bounded roster sweep retries equipment when that actor appears,
	# instead of depending on the one-shot realm signal winning the race.
	for peer_value in Net.player_realms:
		var peer_id := int(peer_value)
		if Net.player_realm(peer_id) == Net.PlayerRealm.MOON:
			_ensure_suit_for_peer(peer_id)


func _wire_local_suit() -> void:
	if not local_suit:
		return
	if not local_suit.oxygen_warning.is_connected(_on_oxygen_warning):
		local_suit.oxygen_warning.connect(_on_oxygen_warning)
	if not local_suit.oxygen_depleted.is_connected(_on_oxygen_depleted):
		local_suit.oxygen_depleted.connect(_on_oxygen_depleted)


func _on_oxygen_warning(fraction: float) -> void:
	show_notice("LIFE SUPPORT WARNING · oxygen at %d%% · refill at the rocket" \
		% roundi(fraction * 100.0), 5.0)


func _on_oxygen_depleted() -> void:
	show_notice("OXYGEN DEPLETED", 4.0)
	if world.local_player:
		world.local_player.take_damage(MonkeyPlayer.MAX_HEALTH * 2.0, null,
			Vector3.ZERO, "body")


## World delegates the local defeat recovery here so a lunar death cannot use
## Earth terrain coordinates. The landing pad is the pressurized rescue point:
## revive there, keep lunar gravity/realm state, and issue a full replacement
## oxygen load so the player does not immediately suffocate a second time.
func respawn_local_player_after_defeat(actor: MonkeyPlayer) -> bool:
	if not world or actor != world.local_player \
			or Net.player_realm() != Net.PlayerRealm.MOON \
			or not moon_world or not is_instance_valid(moon_world):
		return false
	actor.revive_at(moon_world.to_global(moon_world.actor_landing_position()))
	if local_suit:
		local_suit.refill_oxygen()
		local_suit.set_vacuum_exposure(true)
	show_notice("LUNAR RESCUE · suit oxygen restored at the landing pad", 4.0)
	return true


func lunar_void_rescue_height(actor: MonkeyPlayer) -> float:
	if actor == world.local_player and Net.player_realm() == Net.PlayerRealm.MOON \
			and moon_world and is_instance_valid(moon_world):
		# Lowest crater bowls remain well above this line. Crossing it means the
		# monkey has left the bounded landing-zone collider, not merely jumped.
		return moon_world.global_position.y - 48.0
	return -25.0


func rescue_local_player_from_lunar_void(actor: MonkeyPlayer) -> bool:
	if actor != world.local_player or Net.player_realm() != Net.PlayerRealm.MOON \
			or not moon_world or not is_instance_valid(moon_world):
		return false
	actor.admin_teleport(moon_world.to_global(moon_world.actor_landing_position()))
	show_notice("LUNAR SAFETY RESCUE · returned to the landing pad", 3.2)
	return true


func _on_player_realm_changed(peer_id: int, realm: int) -> void:
	if peer_id == Net.local_id():
		_apply_local_realm(realm)
	elif realm == Net.PlayerRealm.MOON:
		var remote_suit := _ensure_suit_for_peer(peer_id)
		if remote_suit:
			remote_suit.set_vacuum_exposure(false)
	elif realm == Net.PlayerRealm.TRANSIT:
		# Return-flight astronauts remain visibly suited in the pressurized cabin.
		# Outbound passengers with a previously stowed suit remain stowed.
		var transit_suit: SpaceSuitSystem = _suits.get(peer_id)
		if is_instance_valid(transit_suit):
			transit_suit.set_vacuum_exposure(false)
	elif _suits.has(peer_id):
		var suit: SpaceSuitSystem = _suits[peer_id]
		if is_instance_valid(suit):
			suit.set_vacuum_exposure(false)
			suit.unequip()


func _apply_local_realm(realm: int) -> void:
	if not world or not world.local_player:
		return
	var player := world.local_player
	var previous_realm := _local_realm
	match realm:
		Net.PlayerRealm.TRANSIT:
			world.set_earth_streaming_enabled(false)
			moon_world.visible = false
			if local_suit:
				# The pressurized cabin pauses tank consumption in both directions.
				local_suit.set_vacuum_exposure(false)
			voyage_camera.current = true
			player.set_expedition_locked(true)
		Net.PlayerRealm.MOON:
			world.set_earth_streaming_enabled(false)
			moon_world.visible = true
			_ensure_local_suit()
			player.set_environment_gravity(MoonWorld.LUNAR_GRAVITY)
			player.set_expedition_locked(false)
			var landing := moon_world.to_global(moon_world.actor_landing_position())
			player.admin_teleport(landing)
			_restore_player_camera()
			show_notice("LUNAR TOUCHDOWN · 1.62 m/s² · vacuum suit active · I inventory")
		_:
			moon_world.visible = false
			if local_suit:
				local_suit.set_vacuum_exposure(false)
				# Suit presentation is a deterministic function of realm. Returning
				# astronauts keep their space-backpack inventory, but take the pressure
				# shell off in breathable air so late joiners render the same outfit.
				local_suit.unequip()
			player.reset_environment_gravity()
			player.set_expedition_locked(false)
			world.set_earth_streaming_enabled(true)
			var snapshot := Net.expedition_state_snapshot()
			var manifest: Array = snapshot.get("crew", [])
			var mission_phase := int(snapshot.get("phase",
				Net.RocketMissionPhase.EARTH_READY))
			var completing_return := previous_realm == Net.PlayerRealm.TRANSIT \
				and mission_phase in [Net.RocketMissionPhase.RETURN,
					Net.RocketMissionPhase.SPLASHDOWN_RECOVERY] \
				and manifest.has(Net.local_id())
			if completing_return:
				player.admin_teleport(rocket.ocean_splashdown_transform.origin
					+ Vector3(4.0, 1.0, 0.0))
			elif previous_realm == Net.PlayerRealm.TRANSIT \
					or player.global_position.y > Net.MOON_WORLD_ORIGIN_Y * 0.5:
				# Admin extraction is not an arrival. Never preserve a cinematic cabin
				# coordinate in the playable Earth realm, even early in ascent when it
				# remains below the broad Moon/Earth network separator.
				player.admin_teleport(world.spawn_point())
			_restore_player_camera()
	_local_realm = realm
	local_realm_changed.emit(realm)


func _restore_player_camera() -> void:
	if world.local_player and world.local_player.cam:
		world.local_player.cam.make_current()


func _on_voyage_progress(progress: float, _elapsed: float,
		_remaining: float) -> void:
	if voyage_camera.current:
		_update_voyage_camera(0.0, progress)


func _on_camera_cue(cue: StringName, _duration: float) -> void:
	if not _local_player_is_voyaging():
		return
	var readable := str(cue).replace("_", " ").capitalize()
	show_notice(readable, 3.2)


func _on_local_rocket_moon_landing() -> void:
	# Net owns realm completion; this callback is presentation-only.
	show_notice("Landing legs down · lunar dust contact", 3.0)


func _on_local_rocket_splashdown() -> void:
	show_notice("Ocean splashdown · crew recovered safely", 4.0)


func _update_voyage_camera(_delta: float, progress_override := -1.0,
		state: Dictionary = {}) -> void:
	if not rocket or not voyage_camera or not _local_player_is_voyaging(state):
		return
	var progress := progress_override
	if progress < 0.0:
		var duration := LunarRocket.OUTBOUND_DURATION_SECONDS if rocket.outbound \
			else LunarRocket.RETURN_DURATION_SECONDS
		progress = clampf(rocket.voyage_elapsed / duration, 0.0, 1.0)
	var basis := rocket.global_basis
	var distance := lerpf(18.0, 34.0, sin(progress * PI))
	var height := lerpf(7.0, 15.0, sin(progress * PI))
	var orbit := sin(progress * TAU) * 0.36
	var side := basis.x * distance * orbit
	var behind := basis.z * distance
	voyage_camera.global_position = rocket.global_position + behind + side \
		+ Vector3.UP * height
	# During reentry the camera stays readable but picks up a deterministic,
	# sub-metre heatshield vibration instead of random frame-dependent shake.
	if rocket.state == LunarRocket.State.REENTRY:
		voyage_camera.global_position += basis.x \
			* sin(rocket.voyage_elapsed * 22.0) * 0.34 \
			+ Vector3.UP * cos(rocket.voyage_elapsed * 17.0) * 0.16
	voyage_camera.look_at(voyage_camera_focus_target(), Vector3.UP)
	voyage_camera.fov = lerpf(68.0, 82.0, sin(progress * PI))
	voyage_camera.current = true


func _local_player_is_voyaging(state: Dictionary = {}) -> bool:
	var snapshot := state if not state.is_empty() \
		else Net.expedition_state_snapshot()
	var phase := int(snapshot.get("phase", Net.RocketMissionPhase.EARTH_READY))
	var crew: Array = snapshot.get("crew", [])
	return phase in [Net.RocketMissionPhase.OUTBOUND,
		Net.RocketMissionPhase.RETURN] \
		and Net.player_realm() == Net.PlayerRealm.TRANSIT \
		and crew.has(Net.local_id())


## Actual cinematic focus, derived from the authority clock so clients joining
## midway see the same shot without depending on one-shot cue delivery. Earth
## remains framed while it shrinks, then a twelve-second eased pan crosses the
## star field to the approaching Moon; the return performs the inverse reveal.
func voyage_camera_focus_target() -> Vector3:
	var rocket_focus := rocket.global_position + Vector3.UP * 0.8
	if not rocket.voyage_visuals or not rocket.voyage_visuals.earth_visual \
			or not rocket.voyage_visuals.moon_visual:
		return rocket_focus
	var earth_focus := rocket.voyage_visuals.earth_visual.global_position
	var moon_focus := rocket.voyage_visuals.moon_visual.global_position
	var elapsed := rocket.voyage_elapsed
	match rocket.state:
		LunarRocket.State.ATMOSPHERE_EXIT:
			var reveal := smoothstep(0.0, 8.0,
				elapsed - float(LunarRocket.OUTBOUND_PHASE_TIMES[0]))
			return rocket_focus.lerp(earth_focus, reveal)
		LunarRocket.State.SPACE_CRUISE:
			return earth_focus
		LunarRocket.State.LUNAR_APPROACH:
			var pan := smoothstep(0.0, 12.0,
				elapsed - float(LunarRocket.OUTBOUND_PHASE_TIMES[2]))
			return earth_focus.lerp(moon_focus, pan)
		LunarRocket.State.RETURN_CRUISE:
			var return_pan := smoothstep(0.0, 12.0,
				elapsed - float(LunarRocket.RETURN_PHASE_TIMES[0]))
			return moon_focus.lerp(earth_focus, return_pan)
	return rocket_focus


func _update_mission_label(state: Dictionary) -> void:
	var outbound := int(state.phase) == Net.RocketMissionPhase.OUTBOUND
	var elapsed := float(state.get("elapsed", 0.0))
	var duration := float(state.get("duration",
		LunarRocket.OUTBOUND_DURATION_SECONDS if outbound \
		else LunarRocket.RETURN_DURATION_SECONDS))
	var remaining := maxi(ceili(duration - elapsed), 0)
	_mission_label.text = "%s  ·  %s  ·  T−%02d:%02d\nCREW %d / %d" % [
		"MOONBOUND" if outbound else "EARTHBOUND",
		LunarRocket.STATE_NAMES[rocket.state], remaining / 60, remaining % 60,
		(state.get("crew", []) as Array).size(), LunarRocket.MAX_CREW]
	_mission_panel.visible = true


func _update_recovery_label(state: Dictionary) -> void:
	var elapsed := float(state.get("elapsed", 0.0))
	var remaining := maxi(ceili(Net.ROCKET_RECOVERY_SECONDS - elapsed), 0)
	_mission_label.text = "OCEAN SPLASHDOWN · RECOVERY %02d:%02d\nBOARDING LOCKED UNTIL PAD RESET" % [
		remaining / 60, remaining % 60]
	_mission_panel.visible = true


func _update_proximity_prompt() -> void:
	_mission_panel.visible = false
	if is_ui_open() or not world.local_player:
		return
	var player := world.local_player
	if Net.player_realm() == Net.PlayerRealm.MOON and moon_world.cheese_shop \
			and player.global_position.distance_to(
				moon_world.cheese_shop.global_position) <= SHOP_INTERACTION_RANGE:
		_mission_label.text = "🧀 CRATER & CURD · E TO TRADE MOON CHEESE"
		_mission_panel.visible = true
	elif player.global_position.distance_to(rocket.global_position) \
			<= ROCKET_INTERACTION_RANGE:
		var action := "E TO DISEMBARK" if is_local_player_aboard() \
			else "E TO BOARD"
		_mission_label.text = "LUNAR ROCKET · %s · L TO LAUNCH\n4 PRESSURIZED CREW SEATS" % action
		_mission_panel.visible = true


func _update_oxygen_ui() -> void:
	var lunar := Net.player_realm() == Net.PlayerRealm.MOON
	_oxygen_panel.visible = lunar and local_suit != null
	if not _oxygen_panel.visible:
		return
	var seconds := maxi(ceili(local_suit.oxygen_seconds), 0)
	var percent := roundi(local_suit.oxygen_fraction() * 100.0)
	_oxygen_label.text = "O₂  %d%%  ·  %02d:%02d\nE AT ROCKET TO REFILL  ·  I BACKPACK" % [
		percent, seconds / 60, seconds % 60]
	_oxygen_label.add_theme_color_override("font_color",
		Color(1.0, 0.35, 0.25) if percent <= 8 else (
			Color(1.0, 0.76, 0.28) if percent <= 20 else
			Color(0.72, 0.94, 1.0)))


func _open_shop() -> void:
	_shop_overlay.visible = true
	_refresh_shop_balance()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_shop() -> void:
	_shop_overlay.visible = false
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _refresh_shop_balance() -> void:
	_shop_balance.text = "YOUR BANANAS  🍌 %d   ·   BACKPACK SPACE %d / %d" % [
		int(Net.scores.get(Net.local_id(), 0)),
		_used_inventory_slots(), local_inventory.slot_count()]


func _used_inventory_slots() -> int:
	var used := 0
	for slot in local_inventory.slots_snapshot():
		if int(slot.get("count", 0)) > 0:
			used += 1
	return used


func _request_cheese_purchase(quantity: int) -> void:
	if _pending_cheese_quantity > 0:
		show_notice("The cheesekeeper is already wrapping that order.")
		return
	if not local_inventory.has_backpack():
		show_notice("A backpack is required for Moon Cheese.")
		return
	if not local_inventory.can_add(LunarInventory.ITEM_MOON_CHEESE,
			quantity, MoonCheeseShop.CHEESE_STACK_SIZE):
		show_notice("No room in the backpack for that cheese stack.")
		return
	# Reserve the exact capacity before the authority spends bananas. The
	# response can arrive several frames later, while pickups or another UI may
	# otherwise fill the final slot and turn paid cheese into nothing.
	var remainder := local_inventory.add_item(PENDING_CHEESE_ITEM, quantity,
		MoonCheeseShop.CHEESE_STACK_SIZE)
	if remainder != 0:
		show_notice("Could not reserve backpack space for Moon Cheese.")
		return
	_pending_cheese_quantity = quantity
	if not Net.request_moon_cheese(quantity) \
			and _pending_cheese_quantity == quantity:
		local_inventory.remove_item(PENDING_CHEESE_ITEM, quantity)
		_pending_cheese_quantity = 0


func _on_moon_cheese_purchase_result(quantity: int, accepted: bool,
		_new_balance: int, reason: String) -> void:
	if quantity != _pending_cheese_quantity or _pending_cheese_quantity <= 0:
		show_notice("Ignored an unexpected Moon Cheese delivery response.")
		_refresh_shop_balance()
		return
	local_inventory.remove_item(PENDING_CHEESE_ITEM,
		_pending_cheese_quantity)
	_pending_cheese_quantity = 0
	if not accepted:
		show_notice(reason if not reason.is_empty() else "Trade declined.")
		_refresh_shop_balance()
		return
	var remainder := local_inventory.add_item(LunarInventory.ITEM_MOON_CHEESE,
		quantity, MoonCheeseShop.CHEESE_STACK_SIZE)
	if remainder == 0:
		show_notice("Added %d Moon Cheese to the space backpack. Deliciously dubious." \
			% quantity)
	else:
		show_notice("Purchase completed, but the backpack changed before delivery.")
	_refresh_shop_balance()


func _reset_rocket_to_launchpad() -> void:
	if not rocket:
		return
	# An aborted outbound trip may arrive here directly from a manifest change,
	# without apply_authoritative_clock's normal landed-state cleanup. Restore the
	# physical hull before freezing it on the pad so it never becomes walk-through.
	rocket._set_scripted_flight(false)
	rocket.global_transform = rocket.earth_launch_transform
	rocket.state = LunarRocket.State.EARTH_BOARDING
	rocket.outbound = true
	rocket.voyage_elapsed = 0.0
	rocket.freeze = true
	rocket.linear_velocity = Vector3.ZERO
	rocket.angular_velocity = Vector3.ZERO
	rocket.voyage_visuals.end_voyage()


func _earth_launch_position() -> Vector3:
	if Gen.has_method("rocket_launch_position"):
		var generated: Variant = Gen.call("rocket_launch_position")
		if generated is Vector3:
			return generated + Vector3.UP \
				* LunarRocket.ORIGIN_ABOVE_LANDING_SURFACE
	var xz := Vector2(92.0, 76.0)
	return Vector3(xz.x, Gen.height(xz.x, xz.y) + 4.4, xz.y)


func _ocean_splashdown_position() -> Vector3:
	# Bounded deterministic ring search: the home continent is intentionally
	# broad, so begin outside it and pick the first deep-ocean cell in seed-rotated
	# angular order. This runs once per session, never in a frame loop.
	var angle_offset := float(posmod(Gen.world_seed, 360)) * PI / 180.0
	for ring in range(8, 34):
		var radius := float(ring) * 768.0
		for spoke in range(20):
			var angle := angle_offset + TAU * float(spoke) / 20.0
			var point := Vector2(cos(angle), sin(angle)) * radius
			var sample: Dictionary = Gen.planet_terrain_sample(point.x, point.y)
			if float(sample.get("ocean", 0.0)) > 0.72 \
					and Gen.height(point.x, point.y) < Gen.WATER_Y - 8.0:
				return Vector3(point.x, Gen.WATER_Y + 4.6, point.y)
	var fallback := Vector2(12000.0, -9000.0)
	return Vector3(fallback.x, Gen.WATER_Y + 4.6, fallback.y)
