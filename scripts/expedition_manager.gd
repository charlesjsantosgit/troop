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
var _voyage_environment: Environment
var _voyage_sky: LunarSky

var _ui_layer: CanvasLayer
var _mission_panel: PanelContainer
var _mission_label: Label
var _oxygen_panel: PanelContainer
var _oxygen_label: Label
var _astronomy_credit: Label
var _toast: Label
var _toast_remaining := 0.0
var _shop_overlay: Control
var _shop_balance: Label
var colony_ui: MoonColonyUI
var _colony_waypoint := {"action": "farm", "target": 0, "title": "CHEESE FARM"}
var _last_net_phase := Net.RocketMissionPhase.EARTH_READY
var _last_net_serial := -1
var _recovery_elapsed := 0.0
var _recovery_anchor_elapsed := 0.0
var _recovery_anchor_age := 0.0
var _recovery_clock_rate := 1.0
var _inventories: Dictionary = {}
var _suits: Dictionary = {}
var _manifest_sync_remaining := 0.0
var _pending_cheese_quantity := 0
var _normal_backpack_visual: Node3D
var _local_realm := -1
var _local_reboard_cooldown_remaining := 0.0
var _local_disembark_request_remaining := 0.0
var _local_disembark_requested := false
var _crew_interpolation_modes: Dictionary = {}
var _cabin_view := true
var _cabin_yaw := 0.0
var _cabin_pitch := 0.0
var _local_aboard := false
var _configure_phase := 0
var _configure_complete := false
var _online_activation_pending := false


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
	_configure_complete = true


## Main drives online setup while the manager/world are disabled. No partially
## built Moon is used for gameplay, and the final state comes from Net's latest
## snapshot rather than the one received before this progressive build began.
func begin_configure(owner_main: Node, owner_world: World) -> void:
	main = owner_main
	world = owner_world
	name = "ExpeditionManager"
	_inventories[Net.local_id()] = local_inventory
	_configure_phase = 0
	_configure_complete = false
	_online_activation_pending = true


func is_configuration_complete() -> bool:
	return _configure_complete


func configuration_stage_name() -> String:
	if _configure_phase == 1 and moon_world:
		return "moon_" + moon_world.setup_phase_name()
	if _configure_phase == 3 and rocket:
		return "rocket_" + rocket.setup_phase_name()
	return ["moon_shell", "moon", "rocket_shell", "rocket", "rocket_route",
		"voyage_camera", "expedition_ui", "latest_snapshot", "complete"][
		mini(_configure_phase, 8)]


func build_configuration_step() -> bool:
	if _configure_complete:
		return true
	match _configure_phase:
		0:
			_create_moon_world(true)
		1:
			if not moon_world.build_setup_step(2000):
				return false
		2:
			_create_rocket(true)
		3:
			if not rocket.build_setup_step(2000):
				return false
		4:
			_configure_rocket_route()
			rocket.visible = true
		5:
			_create_voyage_camera()
		6:
			_build_ui()
			_ui_layer.visible = false
		7:
			_apply_authoritative_state(Net.expedition_state_snapshot())
			_apply_local_realm(Net.player_realm())
			_sync_realm_suits()
			_configure_complete = true
	_configure_phase += 1
	return _configure_complete


## Subscribe only when Main is ready to reveal gameplay. Realm/crew signals can
## select cameras even while Node processing is disabled. Re-read Net's current
## state in the same non-yielding activation so packets received during the last
## UI/voice/player setup frames are neither lost nor shown prematurely.
func activate_online_session() -> void:
	if not _online_activation_pending or not _configure_complete:
		return
	_online_activation_pending = false
	_connect_network()
	_apply_authoritative_state(Net.expedition_state_snapshot())
	_apply_local_realm(Net.player_realm())
	_sync_realm_suits()


func _exit_tree() -> void:
	for peer_id in _crew_interpolation_modes.keys():
		_set_crew_render_driven(int(peer_id), false)
	Net.bind_moon_colony_player(null)
	if Net.moon_colony_changed.is_connected(_on_colony_changed):
		Net.moon_colony_changed.disconnect(_on_colony_changed)
	if Net.moon_colony_result.is_connected(_on_colony_result):
		Net.moon_colony_result.disconnect(_on_colony_result)
	if rocket and is_instance_valid(rocket) and rocket.voyage_visuals:
		rocket.voyage_visuals.set_cinematic_terrain_enabled(false)
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
	_create_moon_world(false)
	_create_rocket()
	_create_voyage_camera()


func _create_moon_world(progressive: bool) -> void:
	moon_world = MoonWorld.new()
	moon_world.name = "PlayableMoon"
	moon_world.position = MOON_WORLD_OFFSET
	# Setup before entering the tree. MoonWorld._ready builds immediately, so
	# assigning the session seed after add_child would permanently retain its
	# default seed and let different sessions share the same crater layout.
	moon_world.moon_seed = Gen.world_seed ^ 0x4d4f4f4e
	if progressive:
		moon_world.begin_setup(moon_world.moon_seed)
	else:
		moon_world.setup(moon_world.moon_seed)
	world.add_child(moon_world)
	moon_world.visible = false


func _create_rocket(progressive := false) -> void:
	rocket = LunarRocket.new()
	rocket.freeze = true
	if progressive:
		rocket.visible = false
		rocket.begin_setup()
	world.add_child(rocket)
	rocket.set_render_driven(true)
	if not progressive:
		_configure_rocket_route()
	rocket.crew_pose_requested.connect(_on_crew_pose_requested)
	rocket.crew_suited.connect(_on_crew_suited)
	rocket.voyage_progress.connect(_on_voyage_progress)
	rocket.camera_cue.connect(_on_camera_cue)
	rocket.moon_landing_completed.connect(_on_local_rocket_moon_landing)
	rocket.splashdown_completed.connect(_on_local_rocket_splashdown)


func _configure_rocket_route() -> void:
	var earth_transform := _earth_launch_transform()
	var moon_local := moon_world.landing_transform()
	var moon_transform := Transform3D(moon_world.global_basis * moon_local.basis,
		moon_world.to_global(moon_local.origin))
	# The same physical pad owns departure, return contact and disembarking.
	rocket.configure_route(earth_transform, moon_transform, earth_transform, moon_world)


func _create_voyage_camera() -> void:
	voyage_camera = Camera3D.new()
	voyage_camera.name = "VoyageCamera"
	voyage_camera.fov = 72.0
	voyage_camera.near = 0.08
	# Planet scale roots are camera-relative; their physical centres may sit far
	# beyond this plane while local tangent caps own the visible pixels. Keeping a
	# bounded far plane also avoids Forward+ light-cluster precision loss.
	voyage_camera.far = 100_000.0
	# The camera, hull, planets and seated crew use one render-clock sample.
	# Applying physics interpolation again would put them on different clocks.
	voyage_camera.physics_interpolation_mode = \
		Node.PHYSICS_INTERPOLATION_MODE_OFF
	voyage_camera.current = false
	world.add_child(voyage_camera)
	var source_environment := world._environment if world._environment \
		else moon_world.lunar_environment
	_voyage_environment = source_environment.duplicate()
	_voyage_sky = LunarSky.new()
	_voyage_sky.material.set_shader_parameter("earth_visibility", 0.0)
	var transition_sky := Sky.new()
	transition_sky.sky_material = _voyage_sky.material
	transition_sky.radiance_size = Sky.RADIANCE_SIZE_32
	_voyage_environment.background_mode = Environment.BG_SKY
	_voyage_environment.sky = transition_sky
	rocket.voyage_visuals.set_photographic_background(true)


func _connect_network() -> void:
	Net.moon_colony_changed.connect(_on_colony_changed)
	Net.moon_colony_result.connect(_on_colony_result)
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
	_oxygen_panel.offset_top = -204.0
	_oxygen_panel.offset_bottom = -116.0
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
	_astronomy_credit = Label.new()
	_astronomy_credit.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_astronomy_credit.offset_left = 18.0
	_astronomy_credit.offset_top = -96.0
	_astronomy_credit.offset_right = 750.0
	_astronomy_credit.offset_bottom = -76.0
	_astronomy_credit.text = "Sky: ESO / S. Brunier · Earth and constellation reference: NASA / GSFC"
	_astronomy_credit.add_theme_font_size_override("font_size", 12)
	_astronomy_credit.add_theme_color_override("font_shadow_color", Color.BLACK)
	_astronomy_credit.add_theme_constant_override("shadow_offset_y", 2)
	_astronomy_credit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_astronomy_credit.visible = false
	_ui_layer.add_child(_astronomy_credit)

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
	colony_ui = MoonColonyUI.new()
	_ui_layer.add_child(colony_ui)
	_shop_overlay = colony_ui
	_shop_balance = colony_ui.balance_label
	colony_ui.closed.connect(_close_shop)
	colony_ui.purchase_requested.connect(_request_cheese_purchase)
	colony_ui.action_requested.connect(_request_colony_action)
	colony_ui.waypoint_requested.connect(_set_colony_waypoint)


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
	_astronomy_credit.visible = (Net.player_realm() == Net.PlayerRealm.TRANSIT \
		 or (Net.player_realm() == Net.PlayerRealm.EARTH and world._space_sky_weight > 0.01) \
		 or (Net.player_realm() == Net.PlayerRealm.MOON \
		 and not is_instance_valid(world.get("frontier")))) and not is_ui_open()
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
		var local_voyaging := _local_player_is_voyaging(state)
		if rocket and rocket.voyage_visuals:
			rocket.voyage_visuals.set_local_viewer_enabled(local_voyaging)
			rocket.voyage_visuals.set_cinematic_terrain_enabled(local_voyaging)
		rocket.advance_render_clock(delta)
		var sample := rocket.render_sample()
		rocket.present_render_sample(sample)
		if local_voyaging:
			_update_transit_world_visibility()
			_update_voyage_camera(delta, -1.0, state, false, sample)
		elif voyage_camera.current:
			_restore_player_camera(true)
		_update_mission_label(state)
	elif phase == Net.RocketMissionPhase.SPLASHDOWN_RECOVERY:
		if rocket and rocket.voyage_visuals:
			rocket.voyage_visuals.set_cinematic_terrain_enabled(false)
		_advance_recovery_presentation(delta)
		if is_local_player_aboard():
			_update_aboard_camera()
		_update_recovery_label(state)
	else:
		if rocket and rocket.voyage_visuals:
			rocket.voyage_visuals.set_cinematic_terrain_enabled(false)
		if is_local_player_aboard():
			_update_aboard_camera()
		_update_proximity_prompt()
	_update_oxygen_ui()
	if moon_world.cheese_shop:
		moon_world.cheese_shop.update_customer(world.local_player
			if Net.player_realm() == Net.PlayerRealm.MOON else null)
		if _shop_overlay.visible and colony_ui.at_market and (Net.player_realm() != Net.PlayerRealm.MOON
				or not moon_world.cheese_shop.is_customer_in_range(world.local_player, SHOP_INTERACTION_RANGE + 1.5)):
			_close_shop()
	if moon_world.colony_world:
		moon_world.colony_world.set_customer(world.local_player
			if Net.player_realm() == Net.PlayerRealm.MOON else null)
	if _shop_overlay.visible and Net.player_realm() != Net.PlayerRealm.MOON:
		_close_shop()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _local_aboard and _cabin_view \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not _other_modal_open():
		_cabin_yaw = wrapf(_cabin_yaw - event.relative.x * CameraRig.SENS, -PI, PI)
		_cabin_pitch = clampf(_cabin_pitch - event.relative.y * CameraRig.SENS, -1.45, 1.45)
		get_viewport().set_input_as_handled()


func set_cabin_view(enabled: bool) -> void:
	_cabin_view = enabled
	if world and world.local_player:
		world.local_player.set_rocket_cabin_view(_local_aboard and enabled)
	if _local_aboard:
		_update_aboard_camera()
		show_notice("CABIN VIEW · mouse to look · C exterior" if enabled \
			else "EXTERIOR VIEW · C cabin", 2.6)


func cabin_view_active() -> bool:
	return _local_aboard and _cabin_view


func _update_aboard_camera() -> void:
	if not rocket or not voyage_camera or not _local_aboard:
		return
	if _cabin_view:
		_update_cabin_camera()
	elif _local_player_is_voyaging():
		_update_voyage_camera(0.0)
	else:
		if voyage_camera.get_parent() != world:
			voyage_camera.reparent(world, true)
		var frame := rocket.global_basis.orthonormalized()
		voyage_camera.global_position = rocket.global_position \
			+ frame * Vector3(24.0, 12.0, 44.0)
		voyage_camera.look_at(rocket.global_position + frame.y * 1.5, frame.y)
		voyage_camera.fov = 65.0
		voyage_camera.environment = moon_world.lunar_environment \
			if Net.player_realm() == Net.PlayerRealm.MOON else null
		voyage_camera.current = true


func _update_cabin_camera() -> void:
	# Keep the eye in cabin-local coordinates. Hull, windows, other seated crew
	# and camera inherit the same displayed rocket transform without chasing it.
	if voyage_camera.get_parent() != rocket:
		voyage_camera.reparent(rocket, false)
	var slot := maxi(rocket.seat_for_peer(Net.local_id()), 0)
	var eye := rocket.cabin_eye_local_transform(slot)
	eye.basis = eye.basis * Basis(Vector3.UP, _cabin_yaw) * Basis(Vector3.RIGHT, _cabin_pitch)
	voyage_camera.transform = eye
	voyage_camera.fov = 82.0
	voyage_camera.near = 0.025
	if rocket.is_in_transit():
		_update_voyage_environment(rocket.voyage_elapsed, rocket.outbound)
	else:
		voyage_camera.environment = moon_world.lunar_environment \
			if Net.player_realm() == Net.PlayerRealm.MOON else null
	voyage_camera.current = true


func _unhandled_input(event: InputEvent) -> void:
	if not world or not world.local_player or not (event is InputEventKey) \
			or not event.pressed or event.echo:
		return
	if _shop_overlay.visible:
		if event.keycode == KEY_ESCAPE or event.physical_keycode in [KEY_ESCAPE, KEY_J]:
			_close_shop()
		get_viewport().set_input_as_handled()
		return
	if _other_modal_open():
		return
	if event.physical_keycode == KEY_C and is_local_player_aboard():
		set_cabin_view(not _cabin_view)
		get_viewport().set_input_as_handled()
		return
	if event.physical_keycode == KEY_J and Net.player_realm() == Net.PlayerRealm.MOON:
		_open_colony_journal()
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
		request_disembark()
		get_viewport().set_input_as_handled()


func request_disembark() -> bool:
	if not is_local_player_aboard() or rocket.state not in [
			LunarRocket.State.EARTH_BOARDING, LunarRocket.State.LANDED_MOON]:
		return false
	_local_disembark_requested = true
	_local_disembark_request_remaining = ROCKET_DISEMBARK_REQUEST_TIMEOUT_SECONDS
	var accepted := Net.request_rocket_board(false)
	if not accepted:
		_local_disembark_requested = false
		_local_disembark_request_remaining = 0.0
	return accepted


func _other_modal_open() -> bool:
	if not is_instance_valid(main):
		return false
	if is_instance_valid(main.get("pause_menu")) or is_instance_valid(main.get("menu")):
		return true
	var frontier: Variant = main.get("frontier_controller")
	if is_instance_valid(frontier) and is_instance_valid(frontier.ui) and frontier.ui.visible:
		return true
	var hud: Variant = main.get("hud")
	if is_instance_valid(hud) and hud.world_map_is_open():
		return true
	var chat: Variant = main.get("chat_box")
	if is_instance_valid(chat) and chat.is_open():
		return true
	for key in ["admin_panel", "trade_ui"]:
		var overlay: Variant = main.get(key)
		if is_instance_valid(overlay) and overlay.visible:
			return true
	return false


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


## Candidate consumed by World's shared physical-entry selector. The real hatch
## point and this exact range are also what the rocket prompt presents.
func rocket_interaction_candidate(player: MonkeyPlayer) -> Dictionary:
	if not is_instance_valid(player) or not is_instance_valid(world) \
			or player != world.local_player or not is_instance_valid(rocket) \
			or rocket.is_in_transit() or player.vehicle or player.expedition_locked:
		return {}
	var phase := int(Net.expedition_state_snapshot().get("phase",
		Net.RocketMissionPhase.EARTH_READY))
	var realm := Net.player_realm()
	if (realm == Net.PlayerRealm.EARTH and phase not in [
			Net.RocketMissionPhase.EARTH_READY,
			Net.RocketMissionPhase.SPLASHDOWN_RECOVERY]) \
			or (realm == Net.PlayerRealm.MOON \
			and phase != Net.RocketMissionPhase.MOON_READY) \
			or realm == Net.PlayerRealm.TRANSIT:
		return {}
	var hatch := rocket.boarding_global_position()
	var distance_squared := player.global_position.distance_squared_to(hatch)
	if distance_squared > ROCKET_INTERACTION_RANGE * ROCKET_INTERACTION_RANGE:
		return {}
	return {"kind": "rocket", "target": rocket, "position": hatch,
		"distance_squared": distance_squared}


func try_rocket_interact(player: MonkeyPlayer) -> bool:
	if rocket_interaction_candidate(player).is_empty():
		return false
	var phase := int(Net.expedition_state_snapshot().get("phase",
		Net.RocketMissionPhase.EARTH_READY))
	if phase == Net.RocketMissionPhase.SPLASHDOWN_RECOVERY \
			and player.global_position.distance_to(rocket.boarding_global_position()) \
				<= ROCKET_INTERACTION_RANGE:
		show_notice("Landing engines shutting down · hatch opens in a moment.")
		return true
	# Consume the original disembark tap and a very short follow-through window.
	# Without this guard Input.is_action_just_pressed("grab") can still be true
	# in Player._physics_process after _unhandled_input removed the same peer.
	if _local_reboard_cooldown_remaining > 0.0 \
			or _local_disembark_request_remaining > 0.0:
		return true
	if local_suit and Net.player_realm() == Net.PlayerRealm.MOON \
			and local_suit.oxygen_fraction() < 0.98:
		local_suit.refill_oxygen()
		show_notice("Oxygen tanks refilled from the rocket life-support manifold.")
		return true
	if Net.request_rocket_board(true):
		show_notice("Seat requested · %s launches when any crew member presses %s." % [
			LAUNCH_KEY_NAME, LAUNCH_KEY_NAME])
	return true


func try_non_rocket_interact(player: MonkeyPlayer) -> bool:
	if player != world.local_player or rocket.is_in_transit():
		return false
	if Net.player_realm() == Net.PlayerRealm.MOON \
			and moon_world.cheese_shop \
			and moon_world.cheese_shop.is_customer_in_range(player, SHOP_INTERACTION_RANGE):
		_open_shop()
		return true
	if Net.player_realm() == Net.PlayerRealm.MOON and moon_world.colony_world:
		var interaction := moon_world.colony_world.nearest_interaction(player.global_position)
		if not interaction.is_empty():
			var action := str(interaction.get("action", ""))
			if action.is_empty():
				show_notice(str(interaction.get("prompt", "Visit Muenster to expand the farm.")))
			else:
				_request_colony_action(action, int(interaction.get("target", 0)))
			return true
	return false


## Compatibility entry point for focused expedition tests and older callers.
## Gameplay routes through World's exact physical selector first.
func try_interact(player: MonkeyPlayer) -> bool:
	return try_rocket_interact(player) or try_non_rocket_interact(player)


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
	var serial := int(state.get("serial", 0))
	var new_presentation := phase != _last_net_phase or serial != _last_net_serial
	# Gate private scenery before a packet can seek or begin a voyage. Bystanders
	# still see the shared hull, crew, landing legs and surface effects immediately.
	if rocket.voyage_visuals:
		rocket.voyage_visuals.set_local_viewer_enabled(_local_player_is_voyaging(state))
	# Ready-state first, then manifest: disembark_crew is deliberately blocked in
	# transit and must see the authoritative arrival before the crew list clears.
	if phase == Net.RocketMissionPhase.MOON_READY:
		rocket.global_transform = rocket.moon_landing_transform
		rocket.apply_authoritative_clock(LunarRocket.State.LANDED_MOON,
			true, LunarRocket.OUTBOUND_DURATION_SECONDS)
	elif phase == Net.RocketMissionPhase.SPLASHDOWN_RECOVERY:
		# The inherited phase ID now means the brief engine shutdown on the pad.
		# A late joiner reconstructs exactly the same grounded hull and cabin.
		if new_presentation or rocket.state != LunarRocket.State.SPLASHDOWN:
			rocket.apply_authoritative_clock(LunarRocket.State.SPLASHDOWN,
				false, LunarRocket.RETURN_DURATION_SECONDS)
		rocket.freeze = true
		_synchronize_recovery_presentation(float(state.get("elapsed", 0.0)),
			new_presentation)
	elif phase == Net.RocketMissionPhase.EARTH_READY:
		_reset_rocket_to_launchpad()
	_sync_manifest(state)
	if phase == Net.RocketMissionPhase.OUTBOUND:
		_local_disembark_requested = false
		if not rocket.is_in_transit():
			rocket.launch_to_moon()
		_apply_flight_clock(state, true, serial != _last_net_serial)
	elif phase == Net.RocketMissionPhase.RETURN:
		_local_disembark_requested = false
		if not rocket.is_in_transit():
			rocket.begin_return_to_earth()
		_apply_flight_clock(state, false, serial != _last_net_serial)
	_last_net_phase = phase
	_last_net_serial = serial
	# Reconcile the manifest before moving occupants. Arrival removes Moon crew;
	# return shutdown retains them, so each snapshot anchors only current seats.
	rocket._emit_crew_poses()


func _apply_flight_clock(snapshot: Dictionary, outbound: bool, new_mission: bool) -> void:
	var elapsed := float(snapshot.get("elapsed", 0.0))
	var flight_state := LunarRocket.state_for_elapsed(outbound, elapsed)
	if new_mission:
		rocket.apply_authoritative_clock(flight_state, outbound, elapsed)
	else:
		rocket.synchronize_authoritative_clock(flight_state, outbound, elapsed)


func _synchronize_recovery_presentation(elapsed: float, first_sample: bool) -> void:
	if not is_finite(elapsed):
		return
	_recovery_anchor_elapsed = clampf(elapsed, 0.0, Net.ROCKET_RECOVERY_SECONDS)
	_recovery_anchor_age = 0.0
	if first_sample:
		_recovery_elapsed = _recovery_anchor_elapsed
		_recovery_clock_rate = 1.0
		rocket.present_landing_recovery(_recovery_elapsed)


func _advance_recovery_presentation(delta: float) -> void:
	if not rocket or not is_finite(delta) or delta <= 0.0:
		return
	_recovery_anchor_age += delta
	var step := minf(delta, LunarRocket.MAX_RENDER_CLOCK_STEP)
	var expected := _recovery_anchor_elapsed + _recovery_anchor_age
	var target_rate := 1.0 + clampf((expected - (_recovery_elapsed + step))
		* LunarRocket.CLOCK_CORRECTION_GAIN, -LunarRocket.MAX_CLOCK_RATE_CORRECTION,
		LunarRocket.MAX_CLOCK_RATE_CORRECTION)
	_recovery_clock_rate = lerpf(_recovery_clock_rate, target_rate,
		1.0 - exp(-step * 6.0))
	_recovery_elapsed = minf(_recovery_elapsed + step * _recovery_clock_rate,
		Net.ROCKET_RECOVERY_SECONDS)
	rocket.present_landing_recovery(_recovery_elapsed)


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
				_set_crew_render_driven(peer_id, false)
				if peer_id == Net.local_id() \
						and (_local_disembark_requested or _local_disembark_request_remaining > 0.0):
					_finish_local_disembark(int(member.seat))
				_set_remote_crew_control(peer_id, false)
	# Reserve authority-order slots even while a late puppet is still spawning.
	rocket.reconcile_manifest_seats(desired)
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
	var was_aboard := _local_aboard
	player.set_expedition_locked(aboard)
	if is_instance_valid(local_suit):
		local_suit.set_vacuum_exposure(Net.player_realm() == Net.PlayerRealm.MOON and not aboard)
	if player.cam:
		player.cam.set_process(not aboard)
		player.cam.set_process_input(not aboard)
	if aboard and not _local_aboard:
		_cabin_view = true
		_cabin_yaw = 0.0
		_cabin_pitch = 0.0
	_local_aboard = aboard
	player.set_rocket_cabin_view(aboard and _cabin_view)
	if aboard:
		_update_aboard_camera()
	elif was_aboard:
		_restore_player_camera(true)


func _finish_local_disembark(seat_index := 0) -> void:
	_local_disembark_requested = false
	_local_disembark_request_remaining = 0.0
	_local_reboard_cooldown_remaining = ROCKET_REBOARD_COOLDOWN_SECONDS
	var player := world.local_player if world else null
	if not player or not rocket:
		return
	# The hatch exits beyond the deployed feet at the ground, never at cabin
	# height and never at a generic world spawn or aircraft carrier.
	var exit_position := rocket.disembark_global_position(seat_index)
	if Net.player_realm() == Net.PlayerRealm.MOON and moon_world:
		exit_position = moon_world.surface_position_at(exit_position, 0.25)
	elif Net.player_realm() == Net.PlayerRealm.EARTH:
		exit_position.y = Gen.height(exit_position.x, exit_position.z) + 0.25
	player.admin_teleport(exit_position)
	show_notice("Disembarked · E can board again once clear of the hatch.", 2.4)


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
	_set_crew_render_driven(peer_id, true)
	_set_remote_crew_control(peer_id, true)
	actor.global_transform = seat_transform
	if actor is CharacterBody3D:
		(actor as CharacterBody3D).velocity = Vector3.ZERO


func _set_crew_render_driven(peer_id: int, driven: bool) -> void:
	var saved: Dictionary = _crew_interpolation_modes.get(peer_id, {})
	var saved_actor: Node3D = saved.actor.get_ref() if not saved.is_empty() else null
	var actor := _actor_for_peer(peer_id) if driven else null
	if saved_actor and (not driven or saved_actor != actor):
		saved_actor.physics_interpolation_mode = int(saved.mode)
		saved_actor.reset_physics_interpolation()
	if not driven or saved_actor != actor:
		_crew_interpolation_modes.erase(peer_id)
	if not driven or not actor or _crew_interpolation_modes.has(peer_id):
		return
	_crew_interpolation_modes[peer_id] = {
		"actor": weakref(actor), "mode": actor.physics_interpolation_mode,
	}
	# Seat transforms are already sampled at the display rate. Inheriting the
	# world's fixed-step interpolation makes passengers vibrate inside the hull.
	actor.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
	var in_cabin := (Net.expedition_state_snapshot().get("crew", []) as Array).has(peer_id)
	suit.set_vacuum_exposure(peer_id == Net.local_id() \
		and Net.player_realm(peer_id) == Net.PlayerRealm.MOON and not in_cabin)
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
	actor.set_lunar_world(moon_world)
	if local_suit:
		local_suit.refill_oxygen()
		local_suit.set_vacuum_exposure(true)
	show_notice("LUNAR RESCUE · suit oxygen restored at the landing pad", 4.0)
	return true


func lunar_void_rescue_height(actor: MonkeyPlayer) -> float:
	if actor == world.local_player and Net.player_realm() == Net.PlayerRealm.MOON \
			and moon_world and is_instance_valid(moon_world):
		# Lunar movement checks radial penetration instead of world Y.
		return -INF
	return -25.0


func rescue_local_player_from_lunar_void(actor: MonkeyPlayer) -> bool:
	if actor != world.local_player or Net.player_realm() != Net.PlayerRealm.MOON \
			or not moon_world or not is_instance_valid(moon_world):
		return false
	actor.admin_teleport(moon_world.to_global(moon_world.actor_landing_position()))
	actor.set_lunar_world(moon_world)
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
	if realm != Net.PlayerRealm.MOON:
		Net.bind_moon_colony_player(null)
		if _shop_overlay.visible:
			_close_shop()
	match realm:
		Net.PlayerRealm.TRANSIT:
			# Preserve the real departure surface until the Earth has visibly fallen
			# away, and reveal the real lunar terrain before touchdown/from ignition.
			# The proxy space shell handles the dissolves between these surfaces.
			_update_transit_world_visibility()
			player.reset_environment_gravity()
			player.cam._cam.environment = null
			if local_suit:
				# The pressurized cabin pauses tank consumption in both directions.
				local_suit.set_vacuum_exposure(false)
			voyage_camera.current = true
			player.set_expedition_locked(true)
		Net.PlayerRealm.MOON:
			world.clear_expedition_stream_focus()
			world.set_earth_streaming_enabled(false)
			world.set_earth_transit_surface_visible(false)
			moon_world.visible = true
			_ensure_local_suit()
			moon_world.set_cinematic_render_radius(MoonWorld.PLAYABLE_RADIUS_METERS)
			var moon_snapshot := Net.expedition_state_snapshot()
			var moon_crew: Array = moon_snapshot.get("crew", [])
			var parked_aboard := int(moon_snapshot.get("phase", -1)) \
				== Net.RocketMissionPhase.MOON_READY and moon_crew.has(Net.local_id())
			if not parked_aboard:
				var landing := moon_world.to_global(moon_world.actor_landing_position())
				player.admin_teleport(landing)
			player.set_lunar_world(moon_world)
			Net.bind_moon_colony_player(player)
			_on_colony_changed(Net.ensure_moon_colony())
			player.cam._cam.environment = moon_world.lunar_environment
			player.cam._cam.far = 14000.0
			# Release after the final transform write. Manifest and realm packets can
			# arrive in either order, so this idempotently makes the on-foot capsule
			# authoritative at the exact touchdown location.
			if parked_aboard:
				var occupied_seat := rocket.seat_for_peer(Net.local_id())
				if occupied_seat >= 0:
					_on_crew_pose_requested(Net.local_id(), rocket.seat_global_transform(occupied_seat))
				_sync_local_lock(true)
			else:
				player.set_expedition_locked(false)
				_restore_player_camera(true)
				show_notice("WELCOME TO THE LUNAR CO-OP · E harvest / trade · J colony journal")
		_:
			world.clear_expedition_stream_focus()
			moon_world.visible = false
			if local_suit:
				local_suit.set_vacuum_exposure(false)
				# Suit presentation is a deterministic function of realm. Returning
				# astronauts keep their space-backpack inventory, but take the pressure
				# shell off in breathable air so late joiners render the same outfit.
				local_suit.unequip()
			player.reset_environment_gravity()
			player.cam._cam.environment = null
			player.set_expedition_locked(false)
			world.set_earth_streaming_enabled(true)
			world.set_earth_transit_surface_visible(true)
			var snapshot := Net.expedition_state_snapshot()
			var manifest: Array = snapshot.get("crew", [])
			var mission_phase := int(snapshot.get("phase",
				Net.RocketMissionPhase.EARTH_READY))
			var completing_return := manifest.has(Net.local_id()) \
				and mission_phase in [Net.RocketMissionPhase.RETURN,
					Net.RocketMissionPhase.SPLASHDOWN_RECOVERY,
					Net.RocketMissionPhase.EARTH_READY]
			if completing_return:
				# Preserve the occupied cabin through contact. The authoritative
				# terminal pose below puts it on the same pad seen on approach.
				player.set_expedition_locked(true)
			elif previous_realm == Net.PlayerRealm.TRANSIT \
					or player.global_position.y >= Net.MOON_REALM_MIN_Y:
				# Admin extraction is not an arrival. Never preserve a cinematic cabin
				# coordinate in the playable Earth realm, even early in ascent when it
				# remains below the broad Moon/Earth network separator.
				player.admin_teleport(world.spawn_point())
			if completing_return:
				_update_aboard_camera()
			else:
				_restore_player_camera()
	_local_realm = realm
	local_realm_changed.emit(realm)


func _restore_player_camera(capture_gameplay_input := false) -> void:
	if world.local_player and world.local_player.cam:
		world.local_player.set_rocket_cabin_view(false)
		world.local_player.cam.set_process(true)
		world.local_player.cam.set_process_input(true)
		world.local_player.cam.snap_to_target()
		world.local_player.cam.make_current()
	if capture_gameplay_input and _can_capture_gameplay_input():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _can_capture_gameplay_input() -> bool:
	if DisplayServer.get_name() == "headless" or is_ui_open() \
			or not main or not is_instance_valid(main):
		return false
	# Do not steal the cursor from a pause/settings screen that remained open
	# during a network realm update. In ordinary touchdown there is no modal UI,
	# so W/A/S/D becomes live on the exact frame the player camera returns.
	var main_menu: Variant = main.get("menu")
	var pause_menu: Variant = main.get("pause_menu")
	return not is_instance_valid(main_menu) and not is_instance_valid(pause_menu)


func _on_voyage_progress(progress: float, _elapsed: float,
		_remaining: float) -> void:
	# The render-frame process owns the single camera/visibility update. Applying
	# the same work from this physics signal caused up to four Moon/terrain uniform
	# passes per displayed frame. Keep the signal for API compatibility.
	var _authority_progress := progress


func _on_camera_cue(cue: StringName, _duration: float) -> void:
	if not _local_player_is_voyaging():
		return
	var readable := str(cue).replace("_", " ").capitalize()
	show_notice(readable, 3.2)


func _on_local_rocket_moon_landing() -> void:
	# Net owns realm completion; this callback is presentation-only.
	show_notice("Landing legs down · lunar dust contact", 3.0)


func _on_local_rocket_splashdown() -> void:
	show_notice("TOUCHDOWN · landing legs settled · engines shutting down", 3.0)


func _update_voyage_camera(_delta: float, progress_override := -1.0,
		state: Dictionary = {}, force_preview := false,
		shared_sample: Dictionary = {}) -> void:
	if not rocket or not voyage_camera \
			or (not force_preview and not _local_player_is_voyaging(state)):
		return
	var elapsed := rocket.voyage_elapsed
	if progress_override >= 0.0:
		elapsed = clampf(progress_override, 0.0, 1.0) * (
			LunarRocket.OUTBOUND_DURATION_SECONDS if rocket.outbound
			else LunarRocket.RETURN_DURATION_SECONDS)
	var sample := shared_sample if not shared_sample.is_empty() \
		else rocket.render_sample(elapsed)
	if force_preview:
		# Diagnostics seek the same presentation pipeline used by the live loop.
		rocket.voyage_visuals.set_local_viewer_enabled(true)
		rocket.voyage_visuals.set_cinematic_terrain_enabled(true)
		rocket.present_render_sample(sample)
		_update_transit_world_visibility()
	if _cabin_view and _local_aboard and not force_preview:
		_update_cabin_camera()
		return
	if voyage_camera.get_parent() != world:
		voyage_camera.reparent(world, true)
	var pose := sample_voyage_camera_pose(float(sample.elapsed),
		sample.transform, bool(sample.outbound))
	voyage_camera.global_position = pose.position
	voyage_camera.look_at(pose.focus, pose.up)
	voyage_camera.fov = float(pose.fov)
	_update_voyage_environment(float(sample.elapsed), bool(sample.outbound))
	voyage_camera.current = true


func _update_voyage_environment(elapsed: float, travel_outbound: bool) -> void:
	var vacuum_weight := _voyage_ease(10.0, 18.0, elapsed) if travel_outbound \
		else 1.0 - _voyage_ease(24.0, 40.0, elapsed)
	if vacuum_weight <= 0.0:
		voyage_camera.environment = null
		return
	var lunar := moon_world.lunar_environment
	if vacuum_weight >= 1.0:
		# Use the exact gameplay environment before the lit landing surface appears.
		# The previous Earth sky ambient/reflections washed out the lunar regolith
		# and changed its brightness again when the player camera took over.
		voyage_camera.environment = lunar
		return
	var earth := world._environment
	if not earth:
		# Standalone expedition scenes may deliberately omit the Earth sky.
		voyage_camera.environment = lunar
		return
	# Blend optical extinction in the sky itself; a finite black sphere hides
	# genuine stars and can cut through scaled planets at a different depth.
	_voyage_sky.set_sun_direction(moon_world.lunar_sun_direction())
	_voyage_sky.set_observation_mode(moon_world.lunar_sky.observation_mode)
	_voyage_sky.material.set_shader_parameter("atmosphere_strength", 1.0 - vacuum_weight)
	var earth_material := earth.sky.sky_material as ShaderMaterial if earth.sky else null
	if earth_material:
		for pair in [["atmosphere_top", "sky_top_color"], ["atmosphere_horizon", "sky_horizon_color"],
				["atmosphere_bottom", "ground_bottom_color"],
				["atmosphere_energy", "sky_energy"]]:
			var value: Variant = earth_material.get_shader_parameter(pair[1])
			if value != null: _voyage_sky.material.set_shader_parameter(pair[0], value)
	_voyage_environment.ambient_light_color = lunar.ambient_light_color
	_voyage_environment.ambient_light_energy = lerpf(earth.ambient_light_energy,
		lunar.ambient_light_energy, vacuum_weight)
	_voyage_environment.ambient_light_sky_contribution = lerpf(
		earth.ambient_light_sky_contribution, 0.0, vacuum_weight)
	_voyage_environment.tonemap_exposure = lerpf(earth.tonemap_exposure,
		lunar.tonemap_exposure, vacuum_weight)
	_voyage_environment.fog_density = earth.fog_density * (1.0 - vacuum_weight)
	_voyage_environment.fog_aerial_perspective = earth.fog_aerial_perspective \
		* (1.0 - vacuum_weight)
	_voyage_environment.volumetric_fog_enabled = false
	_voyage_environment.ssao_radius = lerpf(earth.ssao_radius, lunar.ssao_radius, vacuum_weight)
	_voyage_environment.ssao_intensity = lerpf(earth.ssao_intensity,
		lunar.ssao_intensity, vacuum_weight)
	_voyage_environment.glow_intensity = earth.glow_intensity * (1.0 - vacuum_weight)
	_voyage_environment.glow_strength = earth.glow_strength * (1.0 - vacuum_weight)
	_voyage_environment.glow_bloom = earth.glow_bloom * (1.0 - vacuum_weight)
	voyage_camera.environment = _voyage_environment


func sample_voyage_camera_pose(elapsed: float, rocket_transform: Transform3D,
		travel_outbound: bool) -> Dictionary:
	var pose := _authored_voyage_camera_pose(elapsed, rocket_transform, travel_outbound)
	# Give the thirty-metre hull and deployed feet room in close shots. The
	# smooth distance envelope leaves wide planet views unchanged and avoids a
	# framing cut as the ship crosses between a close shot and a wide shot.
	var offset: Vector3 = pose.position - rocket_transform.origin
	var expansion := 1.0 + 1.8 * (1.0 - smoothstep(20.0, 90.0, offset.length()))
	pose.position = rocket_transform.origin + offset * expansion
	return pose


func _authored_voyage_camera_pose(elapsed: float, rocket_transform: Transform3D,
		travel_outbound: bool) -> Dictionary:
	# Route axes keep the shot steady while the rocket pitches, flips or banks.
	# Every camera join uses matching endpoints and zero-acceleration easing;
	# no shake, extra interpolation, or frame-rate-dependent chase lag is added.
	var origin := rocket_transform.origin
	var earth_up := rocket.earth_launch_transform.basis.y.normalized()
	var earth_back := rocket.earth_launch_transform.basis.z.normalized()
	var earth_right := rocket.earth_launch_transform.basis.x.normalized()
	var moon_up := rocket.moon_landing_transform.basis.y.normalized()
	var moon_back := rocket.moon_landing_transform.basis.z.normalized()
	var moon_right := rocket.moon_landing_transform.basis.x.normalized()
	if travel_outbound:
		if elapsed <= SpaceVoyageVisuals.EARTH_GLOBE_FULL_SECONDS:
			return _earth_departure_camera_pose(rocket_transform, elapsed)
		var map_pose := {
			"position": origin + earth_back * 90.0 + earth_right * 4.0 + earth_up * 25.0,
			"focus": origin - earth_up * 8.0, "up": earth_up, "fov": 70.0,
		}
		if elapsed < 21.0:
			var departure := _earth_departure_camera_pose(rocket_transform,
				SpaceVoyageVisuals.EARTH_GLOBE_FULL_SECONDS)
			return _blend_voyage_camera_poses(departure, map_pose,
				_voyage_ease(18.0, 21.0, elapsed))
		if elapsed < 40.0:
			return map_pose
		if elapsed < SpaceVoyageVisuals.LUNAR_REAL_SURFACE_SECONDS:
			var prelanding_t := _voyage_ease(44.0, 50.0, elapsed)
			var moon_pose := {
				"position": origin + moon_back * lerpf(98.0, 85.0, prelanding_t)
					+ moon_right * lerpf(13.0, 8.0, prelanding_t)
					+ moon_up * lerpf(42.0, 32.0, prelanding_t),
				"focus": origin - moon_up * lerpf(15.0, 49.2, prelanding_t),
				"up": moon_up, "fov": lerpf(64.0, 68.0, prelanding_t),
			}
			return _blend_voyage_camera_poses(map_pose, moon_pose,
				_voyage_ease(40.0, 44.0, elapsed))
		var descent_t := _voyage_ease(50.0, 60.0, elapsed)
		return {
			"position": origin + moon_back * lerpf(85.0, 32.0, descent_t)
				+ moon_right * lerpf(8.0, 5.0, descent_t)
				+ moon_up * lerpf(32.0, 18.0, descent_t),
			"focus": origin - moon_up * lerpf(49.2, 2.2, descent_t),
			"up": moon_up, "fov": lerpf(68.0, 58.0, descent_t),
		}

	var ascent_t := _voyage_ease(0.0, 8.0, elapsed)
	var map_t := _voyage_ease(8.0, 16.0, elapsed)
	var departure_pose := {
		"position": origin + moon_back * lerpf(lerpf(16.0, 38.0, ascent_t), 130.0, map_t)
			+ moon_right * lerpf(lerpf(5.0, 2.0, ascent_t), 8.0, map_t)
			+ moon_up * lerpf(lerpf(8.0, -8.0, ascent_t), 60.0, map_t),
		"focus": origin + moon_up * lerpf(0.8, -40.0, map_t),
		"up": moon_up, "fov": lerpf(lerpf(59.0, 70.0, ascent_t), 68.0, map_t),
	}
	if elapsed <= 18.0:
		return departure_pose
	var touchdown_t := _voyage_ease(40.0, 45.0, elapsed)
	var earth_pose := {
		"position": origin + earth_back * lerpf(60.0, 40.0, touchdown_t)
			+ earth_right * lerpf(12.0, 8.0, touchdown_t)
			+ earth_up * lerpf(24.0, 18.0, touchdown_t),
		"focus": origin + earth_up * 0.8, "up": earth_up,
		"fov": lerpf(68.0, 60.0, touchdown_t),
	}
	return _blend_voyage_camera_poses(departure_pose, earth_pose,
		_voyage_ease(18.0, 24.0, elapsed))


static func _voyage_ease(start: float, finish: float, value: float) -> float:
	var t := clampf((value - start) / maxf(finish - start, 0.001), 0.0, 1.0)
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


static func _blend_voyage_camera_poses(first: Dictionary, second: Dictionary,
		weight: float) -> Dictionary:
	var first_position: Vector3 = first.position
	var first_focus: Vector3 = first.focus
	var first_up: Vector3 = first.up
	return {
		"position": first_position.lerp(second.position, weight),
		"focus": first_focus.lerp(second.focus, weight),
		"up": first_up.slerp(second.up, weight).normalized(),
		"fov": lerpf(float(first.fov), float(second.fov), weight),
	}


func _earth_departure_camera_pose(rocket_transform: Transform3D,
		elapsed: float) -> Dictionary:
	var launch_duration := float(LunarRocket.OUTBOUND_PHASE_TIMES[0])
	var launch_t := clampf(elapsed / maxf(launch_duration, 0.001), 0.0, 1.0)
	var launch_forward := rocket.earth_launch_transform.basis.z.normalized()
	var launch_right := rocket.earth_launch_transform.basis.x.normalized()
	var launch_up := rocket.earth_launch_transform.basis.y.normalized()
	var canopy_clear_t := smoothstep(0.0, 0.075, launch_t)
	var close_forward := lerpf(14.0,
		lerpf(24.0, 34.0, launch_t), canopy_clear_t)
	# Start high enough to read the pad, then fall slightly below the climbing
	# craft. The terrain now recedes behind the exhaust and naturally exposes the
	# curved horizon instead of filling fourteen seconds with a top-down colour.
	var close_height := lerpf(8.0,
		lerpf(4.0, -10.0, launch_t), canopy_clear_t)
	# Pull the camera back before scaled-space compression begins. This keeps the
	# ground and limb receding continuously while the same opaque sphere is
	# revealed; tying both curves to 12 s made the Earth briefly swell toward the
	# lens even though the rocket was accelerating away from it.
	var departure_pullback := smoothstep(7.5, 13.5, elapsed)
	var globe_reveal := smoothstep(10.0,
		SpaceVoyageVisuals.EARTH_GLOBE_FULL_SECONDS, elapsed)
	var globe_departure := smoothstep(
		SpaceVoyageVisuals.EARTH_GLOBE_FULL_SECONDS,
		float(LunarRocket.OUTBOUND_PHASE_TIMES[1]), elapsed)
	var forward_distance := lerpf(close_forward, 400.0, departure_pullback)
	forward_distance = lerpf(forward_distance, 280.0, globe_reveal)
	forward_distance = lerpf(forward_distance, 250.0, globe_departure)
	# Stay close to the rocket's altitude during the pullback. Rising far above it
	# made the camera look down onto an apparently growing planet—the opposite of
	# the requested departure. The increasing horizontal separation now supplies
	# the scale change while the horizon remains below the craft.
	var camera_height := lerpf(close_height, 0.0, departure_pullback)
	camera_height = lerpf(camera_height, 90.0, globe_reveal)
	camera_height = lerpf(camera_height, 90.0, globe_departure)
	# The generator keeps a 64 m safety zone around the pad, so the opening can
	# use a readable three-quarter view of the entire stationary hull instead of
	# the old top-down shot that visually compressed it into the launch deck.
	var right_distance := lerpf(4.0,
		lerpf(6.0, 2.0, launch_t), canopy_clear_t)
	right_distance = lerpf(right_distance, 2.0, globe_reveal)
	var rocket_position := rocket_transform.origin
	var camera_position := rocket_position + launch_forward * forward_distance \
		+ launch_right * right_distance + launch_up * camera_height
	var close_focus := rocket_position + rocket_transform.basis.y.normalized() * 0.8
	var earth_focus := rocket_position - launch_up * 100.0
	if rocket.voyage_visuals and rocket.voyage_visuals.earth_visual:
		# Work from the nearby surface anchor and double-precision scalar height.
		# Subtracting two float32 vectors around a 12-million-metre globe centre
		# loses the sub-metre movement needed for a steady horizon at liftoff.
		var anchor_offset := rocket.voyage_visuals.earth_surface_anchor - rocket_position
		var anchor_height := anchor_offset.dot(launch_up)
		var lateral := anchor_offset - launch_up * anchor_height
		var radius := rocket.voyage_visuals.earth_render_radius
		var center_height := anchor_height - radius
		var center_distance := sqrt(lateral.length_squared() + center_height * center_height)
		if center_distance > 0.001:
			var surface_fraction := (center_distance - radius) / center_distance
			var surface_offset := lateral * surface_fraction \
				+ launch_up * (center_height * surface_fraction)
			earth_focus = rocket_position + surface_offset.limit_length(140.0)

	var globe_focus_weight := lerpf(0.48, 0.38, globe_departure) * globe_reveal
	globe_focus_weight = lerpf(globe_focus_weight, 0.68,
		smoothstep(13.0, 16.0, elapsed))
	var focus := close_focus.lerp(earth_focus, globe_focus_weight)
	return {"position": camera_position, "focus": focus, "up": launch_up,
		"fov": lerpf(59.0, 68.0, maxf(launch_t, departure_pullback))}


func _update_transit_world_visibility() -> void:
	if not world or not moon_world or not rocket:
		return
	# The fixed flight only needs the already-loaded launch surface and its globe.
	# A seated actor has zero horizontal velocity: streaming interpreted its rapid
	# vertical ascent as stationary preflight and built costly altitude tiers,
	# causing 60–160 ms main-thread stalls throughout the opening climb.
	var stream_earth_surface := false
	if rocket.outbound:
		world.clear_expedition_stream_focus()
	else:
		var pad_ground := rocket.earth_launch_transform.origin \
			- rocket.earth_launch_transform.basis.y * LunarRocket.ORIGIN_ABOVE_LANDING_SURFACE
		world.set_expedition_stream_focus(pad_ground + Vector3.UP)
	# Pausing generation is an optimization; it must never double as a visible
	# cut. Retained chunks stay curved and tangent until realm handoff.
	var show_earth_surface := (rocket.outbound \
		and rocket.voyage_elapsed <= SpaceVoyageVisuals.EARTH_GLOBE_FULL_SECONDS) \
		or (not rocket.outbound and rocket.voyage_elapsed \
			>= SpaceVoyageVisuals.RETURN_TERRAIN_REVEAL_START_SECONDS)
	var show_moon_surface := (rocket.outbound \
		and rocket.voyage_elapsed >= 36.0) \
		or (not rocket.outbound and rocket.voyage_elapsed <= 18.0)
	if world.earth_streaming_enabled() != stream_earth_surface:
		world.set_earth_streaming_enabled(stream_earth_surface)
	var earth_light_weight := -1.0 if rocket.outbound else \
		_voyage_ease(24.0, 40.0, rocket.voyage_elapsed)
	world.set_earth_transit_surface_visible(show_earth_surface, earth_light_weight)
	moon_world.visible = show_moon_surface
	if show_moon_surface and rocket.voyage_visuals:
		if rocket.outbound:
			# Preload the real cap fully compressed just inside the opaque map Moon.
			# From 42--50 s, reverse that compression on the exact same clock that
			# moves the proxy's tangent and logarithmic radius into the physical frame.
			# Resetting to the physical cap at 36 s made the entire gray environment
			# appear in one frame while the separate map globe remained on screen.
			var arrival_blend := SpaceVoyageVisuals.lunar_arrival_scale_blend(
				rocket.voyage_elapsed)
			var moon_up := rocket.moon_landing_transform.basis.y.normalized()
			var cap_clearance := \
				SpaceVoyageVisuals.MOON_PROXY_RELIEF_CLEARANCE \
				* arrival_blend
			var arrival_surface := rocket.voyage_visuals.moon_surface_anchor \
				+ moon_up * cap_clearance
			# Raising a tangent without enlarging its radius shifts the cap centre and
			# exposes a second lunar crescent. Change both by the same clearance so
			# proxy and cap stay rigorously concentric throughout the 42--50 s bridge.
			var arrival_radius := rocket.voyage_visuals.moon_render_radius \
				+ cap_clearance
			moon_world.set_cinematic_render_transform(
				moon_world.to_local(arrival_surface), arrival_radius,
				1.0 - arrival_blend)
		else:
			# Return keeps the real Moon fixed in space. It recedes because the
			# ship travels away; no camera-following globe can reappear later.
			var cap_clearance := SpaceVoyageVisuals.MOON_PROXY_RELIEF_CLEARANCE
			var departure_surface := rocket.voyage_visuals.moon_surface_anchor \
				+ rocket.moon_landing_transform.basis.y * cap_clearance
			moon_world.set_cinematic_render_transform(
				moon_world.to_local(departure_surface),
				rocket.voyage_visuals.moon_render_radius + cap_clearance, 0.0)


func _local_player_is_voyaging(state: Dictionary = {}) -> bool:
	var snapshot := state if not state.is_empty() \
		else Net.expedition_state_snapshot()
	var phase := int(snapshot.get("phase", Net.RocketMissionPhase.EARTH_READY))
	var crew: Array = snapshot.get("crew", [])
	return phase in [Net.RocketMissionPhase.OUTBOUND,
		Net.RocketMissionPhase.RETURN] \
		and Net.player_realm() == Net.PlayerRealm.TRANSIT \
		and crew.has(Net.local_id())


## Read the same optical target used by the displayed cinematic camera.
## Presentation must already have applied the shared sample's planet anchors.
func voyage_camera_focus_target() -> Vector3:
	var sample := rocket.render_sample()
	var pose := sample_voyage_camera_pose(float(sample.elapsed),
		sample.transform, bool(sample.outbound))
	return pose.focus


func _update_mission_label(state: Dictionary) -> void:
	var outbound := int(state.phase) == Net.RocketMissionPhase.OUTBOUND
	var elapsed := float(state.get("elapsed", 0.0))
	var duration := float(state.get("duration",
		LunarRocket.OUTBOUND_DURATION_SECONDS if outbound \
		else LunarRocket.RETURN_DURATION_SECONDS))
	var remaining := maxi(ceili(duration - elapsed), 0)
	_mission_label.text = "%s  ·  %s  ·  T−%02d:%02d\nCREW %d / %d  ·  C CABIN / EXTERIOR" % [
		"MOONBOUND" if outbound else "EARTHBOUND",
		LunarRocket.STATE_NAMES[rocket.state], remaining / 60, remaining % 60,
		(state.get("crew", []) as Array).size(), LunarRocket.MAX_CREW]
	_mission_panel.visible = true


func _update_recovery_label(state: Dictionary) -> void:
	var elapsed := float(state.get("elapsed", 0.0))
	var remaining := maxi(ceili(Net.ROCKET_RECOVERY_SECONDS - elapsed), 0)
	_mission_label.text = "LANDED AT LAUNCH PAD · ENGINE SHUTDOWN %02d:%02d\nSTAY SEATED · C CABIN / EXTERIOR" % [
		remaining / 60, remaining % 60]
	_mission_panel.visible = true


func _update_proximity_prompt() -> void:
	_mission_panel.visible = false
	if is_ui_open() or not world.local_player:
		return
	var player := world.local_player
	# Seated crew do not participate in the on-foot selector, but still need the
	# complete disembark, launch and camera prompt while the parked cabin owns E.
	if is_local_player_aboard():
		_mission_label.text = "LUNAR ROCKET · E TO DISEMBARK · L TO LAUNCH\n4 PRESSURIZED CREW SEATS · C CABIN / EXTERIOR"
		_mission_panel.visible = true
		return
	var physical_interaction: Dictionary = world.nearby_physical_interaction(player) \
		if world.has_method("nearby_physical_interaction") else {}
	# The shared selector also drives Player's E action and HUD queries. A chest
	# or ordinary vehicle therefore suppresses the rocket/colony prompt rather
	# than displaying two different actions for the same key.
	if not physical_interaction.is_empty() \
			and physical_interaction.get("kind", "") != "rocket":
		return
	if physical_interaction.get("kind", "") == "rocket":
		var action := "E TO DISEMBARK" if is_local_player_aboard() \
			else "E TO BOARD"
		_mission_label.text = "LUNAR ROCKET · %s · L TO LAUNCH\n4 PRESSURIZED CREW SEATS · C CABIN / EXTERIOR" % action
		if Net.player_realm() == Net.PlayerRealm.MOON and not is_local_player_aboard():
			_mission_label.text = "LUNAR ROCKET · E BOARD / REFILL\n%s  CHEESE FARM  ·  J JOURNAL" % _lunar_bearing(moon_world.colony_world.interaction_position("farm", 0))
		_mission_panel.visible = true
	elif Net.player_realm() == Net.PlayerRealm.MOON and moon_world.cheese_shop \
			and moon_world.cheese_shop.is_customer_in_range(player, SHOP_INTERACTION_RANGE):
		_mission_label.text = "🧀 CRATER & CURD · E TO TRADE MOON CHEESE"
		_mission_panel.visible = true
	elif Net.player_realm() == Net.PlayerRealm.MOON:
		var colony := moon_world.colony_world
		var interaction := colony.nearest_interaction(player.global_position) if colony else {}
		if not interaction.is_empty():
			_mission_label.text = "%s\nJ COLONY JOURNAL" % str(interaction.get("prompt", "E TO INTERACT"))
		else:
			var destination := colony.interaction_position(str(_colony_waypoint.action), int(_colony_waypoint.target)) if colony else rocket.moon_landing_transform.origin
			_mission_label.text = "%s  %s  ·  J JOURNAL\n%s  LANDER / OXYGEN" % [
				_lunar_bearing(destination), str(_colony_waypoint.title),
				_lunar_bearing(rocket.moon_landing_transform.origin)]
		_mission_panel.visible = true



func _update_oxygen_ui() -> void:
	var lunar := Net.player_realm() == Net.PlayerRealm.MOON
	_oxygen_panel.visible = lunar and local_suit != null
	if not _oxygen_panel.visible:
		return
	var seconds := maxi(ceili(local_suit.oxygen_seconds), 0)
	var percent := roundi(local_suit.oxygen_fraction() * 100.0)
	_oxygen_label.text = "O₂  %d%%  ·  %02d:%02d\nE AT LIFE SUPPORT TO REFILL  ·  I BACKPACK" % [
		percent, seconds / 60, seconds % 60]
	_oxygen_label.add_theme_color_override("font_color",
		Color(1.0, 0.35, 0.25) if percent <= 8 else (
			Color(1.0, 0.76, 0.28) if percent <= 20 else
			Color(0.72, 0.94, 1.0)))


func _open_shop() -> void:
	inventory_ui.close_inventory()
	moon_world.cheese_shop.begin_trade(world.local_player)
	colony_ui.present(true)
	_refresh_shop_balance()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _open_colony_journal() -> void:
	inventory_ui.close_inventory()
	colony_ui.present(false)
	_refresh_shop_balance()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_shop() -> void:
	moon_world.cheese_shop.end_trade()
	_shop_overlay.visible = false
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _refresh_shop_balance() -> void:
	var snapshot := Net.moon_colony_snapshot()
	# Banana pickups and ordinary purchases also change the shared currency.
	snapshot["balance"] = int(Net.scores.get(Net.local_id(), 0))
	colony_ui.refresh(snapshot)


func _on_colony_changed(snapshot: Dictionary) -> void:
	if moon_world and moon_world.colony_world:
		moon_world.colony_world.apply_snapshot(snapshot)
	if colony_ui:
		colony_ui.refresh(snapshot)


func _request_colony_action(action: String, target := 0) -> void:
	if Net.player_realm() != Net.PlayerRealm.MOON or is_local_player_aboard() \
			or rocket.is_in_transit():
		show_notice("Step onto the Moon to use colony equipment.")
		return
	Net.request_moon_colony(action, target)


func _on_colony_result(action: String, accepted: bool, reason: String) -> void:
	if accepted and action == "refill" and local_suit:
		local_suit.refill_oxygen()
	if action in ["sell_fresh", "sell_aged", "upgrade", "contract"]:
		moon_world.cheese_shop.react_to_trade(accepted, 1, reason)
	if not reason.is_empty():
		show_notice(reason)
	if accepted and action == "harvest":
		_colony_waypoint = {"action": "market", "target": 0, "title": "CRATER & CURD"}
	elif accepted and action in ["sell_fresh", "sell_aged", "contract"]:
		_colony_waypoint = {"action": "farm", "target": 0, "title": "CHEESE FARM"}
	_refresh_shop_balance()


func _set_colony_waypoint(action: String, target: int, title: String) -> void:
	_colony_waypoint = {"action": action, "target": target, "title": title}
	_close_shop()
	show_notice("Bearing set: %s. Follow the arrow at the top of the screen." % title)


func _lunar_bearing(target: Vector3) -> String:
	var player := world.local_player
	var up := moon_world.radial_up_at(player.global_position)
	var target_up := moon_world.radial_up_at(target)
	var distance_m := acos(clampf(up.dot(target_up), -1.0, 1.0)) * MoonWorld.PLAYABLE_RADIUS_METERS
	var toward := (target_up - up * up.dot(target_up)).normalized()
	var relative := player.cam.global_basis.inverse() * toward
	var bearing := atan2(relative.x, -relative.z)
	var arrows := ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
	return "%s %d m" % [arrows[posmod(roundi(bearing / (PI / 4.0)), 8)], roundi(distance_m)]


func _used_inventory_slots() -> int:
	var used := 0
	for slot in local_inventory.slots_snapshot():
		if int(slot.get("count", 0)) > 0:
			used += 1
	return used


func _request_cheese_purchase(quantity: int) -> void:
	if quantity < 1 or quantity > Net.MAX_MOON_CHEESE_QUANTITY:
		show_notice("Choose a quantity from the shop menu.")
		return
	if Net.player_realm() != Net.PlayerRealm.MOON or not moon_world.cheese_shop.is_customer_in_range(world.local_player, SHOP_INTERACTION_RANGE):
		show_notice("Walk up to Muenster's counter to trade.")
		return
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
	moon_world.cheese_shop.react_to_trade(accepted, quantity, reason)
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
	world.clear_expedition_stream_focus()
	# Use the same complete reset for cancellation and normal recovery: collision,
	# interpolation, deployed gear and every shared effect must agree with the pad.
	rocket.apply_authoritative_clock(LunarRocket.State.EARTH_BOARDING, true, 0.0)
	rocket.freeze = true
	rocket.linear_velocity = Vector3.ZERO
	rocket.angular_velocity = Vector3.ZERO
	_recovery_elapsed = 0.0
	_recovery_anchor_elapsed = 0.0
	_recovery_anchor_age = 0.0
	_recovery_clock_rate = 1.0


func _earth_launch_position() -> Vector3:
	return _earth_launch_transform().origin


func _earth_launch_transform() -> Transform3D:
	var xz := Vector2(92.0, 76.0)
	var nominal := Vector3(xz.x, Gen.height(xz.x, xz.y), xz.y)
	if Gen.has_method("rocket_launch_position"):
		var generated: Variant = Gen.call("rocket_launch_position")
		if generated is Vector3:
			nominal = generated
	return LunarRocket.grounded_landing_transform(nominal,
		Basis(Vector3.UP, PI),
		func(x: float, z: float) -> float: return Gen.height(x, z))


func _ocean_splashdown_position() -> Vector3:
	# The debug arena has no generated water and cannot start a lunar mission.
	# Keep its inactive authored route independent from the normal-world search.
	if Gen.debug_world:
		return Vector3(12000.0, Gen.WATER_Y + 4.6, -9000.0)
	# Pangaea's real ocean may be millions of metres away, outside multiplayer
	# bounds. Lakes are valid water landings: query actual final terrain height,
	# including roads, and require a clear 60 m radius before accepting a point.
	# The old ocean-mask search always fell back to an unchecked dry-land point
	# for several ordinary seeds, hidden only by the passenger's private ocean.
	var has_water_footprint := func(point: Vector2) -> bool:
		if not point.is_finite() or absf(point.x) + 60.0 >= Net.MAX_WORLD_COORDINATE \
				or absf(point.y) + 60.0 >= Net.MAX_WORLD_COORDINATE:
			return false
		if Gen.height(point.x, point.y) > Gen.WATER_Y - 8.0:
			return false
		for z in range(-4, 5):
			for x in range(-4, 5):
				var offset := Vector2(x, z) * 15.0
				if offset.length_squared() > 60.0 * 60.0:
					continue
				var height := Gen.height(point.x + offset.x, point.y + offset.y)
				if not is_finite(height) or height > Gen.WATER_Y - 8.0:
					return false
		return true
	# Bounded, seed-ordered search in the existing 6–25 km route envelope. This
	# runs once per session; it neither streams distant terrain nor alters it.
	var angle_offset := float(posmod(Gen.world_seed, 360)) * PI / 180.0
	for ring in range(8, 34):
		var radius := float(ring) * 768.0
		for spoke in range(20):
			var angle := angle_offset + TAU * float(spoke) / 20.0
			var point := Vector2(cos(angle), sin(angle)) * radius
			if has_water_footprint.call(point):
				return Vector3(point.x, Gen.WATER_Y + 4.6, point.y)
	# PlanetTerrain guarantees a broad, ~38 m deep home basin for every normal
	# seed. Still validate its final graded terrain with the identical footprint.
	var fallback := Gen.planet_home_lake_center()
	assert(has_water_footprint.call(fallback), "Generated home lake has no safe splashdown footprint")
	return Vector3(fallback.x, Gen.WATER_Y + 4.6, fallback.y)
