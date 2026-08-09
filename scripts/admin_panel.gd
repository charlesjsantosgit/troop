class_name AdminPanel
extends Control
## The interactive admin console (F8). Everything the slash commands can do,
## laid out as buttons: a live player table with per-row actions, monkey
## spawning, and world controls. Rebuilds its player list every time it opens
## so the roster is always current.

var controller: AdminController
var _players_box: VBoxContainer
var _ban_minutes := {}


func configure(admin_controller: AdminController) -> void:
	controller = admin_controller


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var scrim := ColorRect.new()
	scrim.color = Color(0.02, 0.05, 0.03, 0.55)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.045, 0.10, 0.06, 0.97)
	style.border_color = Color(1.0, 0.72, 0.16, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	var viewport_size := get_viewport_rect().size
	panel.custom_minimum_size = Vector2(
		minf(980.0, maxf(560.0, viewport_size.x - 64.0)),
		minf(820.0, maxf(360.0, viewport_size.y - 48.0)))
	center.add_child(panel)

	var shell := VBoxContainer.new()
	shell.add_theme_constant_override("separation", 10)
	panel.add_child(shell)
	var body_scroll := ScrollContainer.new()
	body_scroll.name = "AdminBodyScroll"
	body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	body_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	shell.add_child(body_scroll)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_scroll.add_child(column)

	column.add_child(_header("🛠 ADMIN · CANOPY CONTROL"))
	var hint := Label.new()
	hint.text = "Every button has a slash-command twin — /help in chat."
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.65, 0.78, 0.62))
	column.add_child(hint)

	column.add_child(_section("PLAYERS"))
	_players_box = VBoxContainer.new()
	_players_box.add_theme_constant_override("separation", 4)
	_players_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_players_box)

	column.add_child(_section("SPAWN A MONKEY  ·  solo / debug world"))
	var spawn_row := HBoxContainer.new()
	spawn_row.add_theme_constant_override("separation", 6)
	for entry in [["CAPTAIN PEEL", "peel"], ["SWINGER", "swinger"],
			["FOLLOWER", "follower"], ["STATUE", "statue"],
			["VILLAGER", "villager"]]:
		var b := _button(entry[0])
		b.pressed.connect(func() -> void: controller.spawn_monkey(entry[1]))
		b.disabled = not controller.can_spawn()
		spawn_row.add_child(b)
	column.add_child(spawn_row)

	column.add_child(_section("WORLD"))
	var world_row := HBoxContainer.new()
	world_row.add_theme_constant_override("separation", 6)
	var fly := _button("🪽 FLY")
	fly.pressed.connect(func() -> void: controller.toggle_fly())
	world_row.add_child(fly)
	var loadout := _button("FULL LOADOUT")
	loadout.pressed.connect(func() -> void: controller.give_all_weapons())
	world_row.add_child(loadout)
	var heal := _button("HEAL SELF")
	heal.pressed.connect(func() -> void:
		controller.heal_target(Net.local_id()))
	world_row.add_child(heal)
	column.add_child(world_row)

	var tp_row := HBoxContainer.new()
	tp_row.add_theme_constant_override("separation", 6)
	tp_row.add_child(_tag("TELEPORT:"))
	for place in ["rainforest", "bamboo", "wetland", "highland", "mountains"]:
		var b := _button(place.to_upper())
		b.pressed.connect(func() -> void: controller.teleport_to_biome(place))
		tp_row.add_child(b)
	column.add_child(tp_row)

	column.add_child(_section("VEHICLES"))
	var vehicle_row := HBoxContainer.new()
	vehicle_row.add_theme_constant_override("separation", 6)
	vehicle_row.add_child(_tag("DELIVER:"))
	for entry in [["🏍 BIKE", "bike"], ["🚙 JEEP", "jeep"],
			["🛥 AIRBOAT", "boat"], ["✈ JET", "jet"]]:
		var b := _button(entry[0])
		b.pressed.connect(func() -> void: controller.spawn_vehicle(entry[1]))
		vehicle_row.add_child(b)
	column.add_child(vehicle_row)
	var vehicle_tp_row := HBoxContainer.new()
	vehicle_tp_row.add_theme_constant_override("separation", 6)
	vehicle_tp_row.add_child(_tag("GO TO:"))
	for entry in [["🛫 AIRSTRIP", "airstrip"], ["🅿 MOTOR POOL", "pool"],
			["⚓ LAKE DOCK", "dock"], ["🔎 NEAREST WILD", "machine"]]:
		var b := _button(entry[0])
		b.pressed.connect(func() -> void:
			controller.teleport_to_vehicle_spot(entry[1]))
		vehicle_tp_row.add_child(b)
	column.add_child(vehicle_tp_row)

	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 6)
	time_row.add_child(_tag("TIME:"))
	for entry in [["DAWN", 6.2], ["NOON", 12.0], ["DUSK", 18.1],
			["MIDNIGHT", 0.0]]:
		var b := _button(entry[0])
		b.pressed.connect(func() -> void: controller.set_time(entry[1]))
		time_row.add_child(b)
	var release := _button("RELEASE")
	release.pressed.connect(func() -> void: controller.clear_time())
	time_row.add_child(release)
	column.add_child(time_row)

	var footer_row := HBoxContainer.new()
	footer_row.add_theme_constant_override("separation", 6)
	var help := _button("📜 COMMAND LIST → CHAT")
	help.pressed.connect(func() -> void:
		visible = false
		controller.run_command("/help"))
	footer_row.add_child(help)
	var close := _button("CLOSE  ·  F8")
	close.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close.pressed.connect(func() -> void: visible = false)
	footer_row.add_child(close)
	shell.add_child(footer_row)

	visibility_changed.connect(_on_visibility_changed)
	Net.admin_roster_changed.connect(_on_admin_roster_changed)
	Net.admin_changed.connect(_on_admin_changed)


func _on_visibility_changed() -> void:
	if visible:
		_rebuild_players()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif is_inside_tree() and DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_admin_roster_changed() -> void:
	if visible and is_inside_tree():
		_rebuild_players()


func _on_admin_changed(enabled: bool) -> void:
	if not enabled:
		visible = false
	elif visible and is_inside_tree():
		_rebuild_players()


func _rebuild_players() -> void:
	for child in _players_box.get_children():
		child.queue_free()
	_ban_minutes.clear()
	var ids := Net.names.keys()
	ids.sort()
	for peer_id in ids:
		_players_box.add_child(_player_row(peer_id))
	if ids.size() <= 1:
		var alone := Label.new()
		alone.text = "Only you in the canopy right now."
		alone.add_theme_font_size_override("font_size", 13)
		alone.add_theme_color_override("font_color", Color(0.6, 0.72, 0.58))
		_players_box.add_child(alone)


func _player_row(peer_id: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	var is_self := peer_id == Net.local_id()
	var is_peer_admin := Net.admin_peers.has(peer_id)
	var name_label := Label.new()
	name_label.text = "%s  ·  #%d" % [str(Net.names.get(peer_id, peer_id)),
		peer_id] \
		+ (" (you)" if is_self else "") \
		+ (" · ADMIN" if is_peer_admin else "")
	name_label.custom_minimum_size = Vector2(180, 0)
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color",
		Color(1.0, 0.9, 0.55) if is_self or is_peer_admin \
		else Color(0.92, 0.96, 0.9))
	row.add_child(name_label)

	var kill := _button("KO")
	kill.pressed.connect(func() -> void: controller.kill_target(peer_id))
	row.add_child(kill)
	var heal := _button("HEAL")
	heal.pressed.connect(func() -> void: controller.heal_target(peer_id))
	row.add_child(heal)
	var ammo := _button("AMMO")
	ammo.pressed.connect(func() -> void:
		for kind in range(4):
			controller.give_ammo(peer_id, kind, [24, 12, 60, 15][kind]))
	row.add_child(ammo)
	if not is_self:
		var admin := _button("REVOKE ADMIN" if is_peer_admin else "MAKE ADMIN")
		admin.pressed.connect(func() -> void:
			if is_peer_admin:
				controller.revoke_admin(peer_id)
			else:
				controller.grant_admin(peer_id))
		row.add_child(admin)
		var tp := _button("GO TO")
		tp.pressed.connect(func() -> void:
			controller.teleport_to_player(peer_id))
		row.add_child(tp)
		var kick := _button("KICK")
		kick.pressed.connect(func() -> void: controller.kick_player(peer_id))
		row.add_child(kick)
		var duration := OptionButton.new()
		for entry in [["15 m", 15], ["1 h", 60], ["24 h", 1440],
				["7 d", 10080]]:
			duration.add_item(entry[0])
			duration.set_item_metadata(duration.item_count - 1, entry[1])
		duration.select(1)
		_ban_minutes[peer_id] = duration
		row.add_child(duration)
		var ban := _button("BAN")
		ban.pressed.connect(func() -> void:
			var picker: OptionButton = _ban_minutes.get(peer_id)
			var minutes := 60
			if picker and picker.selected >= 0:
				minutes = int(picker.get_item_metadata(picker.selected))
			controller.ban_player(peer_id, minutes))
		row.add_child(ban)
	return row


func _header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.25))
	return label


func _section(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.55, 0.85, 0.6))
	return label


func _tag(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.7, 0.8, 0.68))
	return label


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 12)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.22, 0.13)
	style.set_corner_radius_all(7)
	style.set_content_margin_all(7)
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color(0.16, 0.34, 0.19)
	b.add_theme_stylebox_override("hover", hover)
	return b
