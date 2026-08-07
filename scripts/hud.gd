class_name HUD
extends CanvasLayer
## Compact jungle-combat HUD with camera/weapon state, readable vitals,
## contextual actions, and weapon-accurate reticles.

enum ScopeTarget { NONE, BODY, HEAD }

const SNIPER_SCOPE_RANGE := 800.0

var player  # MonkeyPlayer
var score_label: Label
var speed_label: Label
var speed_fill: ColorRect
var health_label: Label
var health_fill: ColorRect
var ammo_label: Label
var enemy_label: Label
var headshot_label: Label
var damage_overlay: ColorRect
var hint: Label
var roster: Label
var minimap: Minimap
var crosshair: CombatCrosshair
var spread_label: Label
var camera_badge: Label
var weapon_slots: Label
var vehicle_panel: Panel
var vehicle_speed_label: Label
var vehicle_gear_label: Label
var vehicle_rpm_fill: ColorRect
var vehicle_extra_label: Label
var voice_label: Label
var sniper_scope: SniperScopeOverlay
var _help_t := 12.0
var _camera_notice_t := 0.0
var _camera_notice_mode := CameraRig.ViewMode.SHOULDER
var _sniper_scope_active := false
var _last_health := 0.0
var _voice_error := ""
var _voice_error_t := 0.0


func _ready() -> void:
	var margin := 14
	var status_panel := Panel.new()
	status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_panel.anchor_top = 1.0
	status_panel.anchor_bottom = 1.0
	status_panel.offset_left = 8
	status_panel.offset_right = 268
	status_panel.offset_top = -92
	status_panel.offset_bottom = -8
	status_panel.add_theme_stylebox_override("panel",
		_panel_style(Color(0.035, 0.075, 0.045, 0.82), Color(0.42, 0.9, 0.25, 0.7)))
	add_child(status_panel)

	var weapon_panel := Panel.new()
	weapon_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	weapon_panel.anchor_left = 1.0
	weapon_panel.anchor_right = 1.0
	weapon_panel.anchor_top = 1.0
	weapon_panel.anchor_bottom = 1.0
	weapon_panel.offset_left = -448
	weapon_panel.offset_right = -8
	weapon_panel.offset_top = -104
	weapon_panel.offset_bottom = -8
	weapon_panel.add_theme_stylebox_override("panel",
		_panel_style(Color(0.055, 0.055, 0.03, 0.86), Color(1.0, 0.68, 0.12, 0.75)))
	add_child(weapon_panel)

	score_label = _label(24)
	score_label.position = Vector2(margin, margin)
	add_child(score_label)

	minimap = Minimap.new()
	minimap.anchor_left = 1.0
	minimap.anchor_right = 1.0
	minimap.offset_left = -Minimap.SIZE_LARGE - margin
	minimap.offset_right = -margin
	minimap.position.y = margin
	if player and player.world:
		minimap.configure(player.world)
	add_child(minimap)

	roster = _label(15)
	roster.position = Vector2(0, margin)
	roster.anchor_left = 1.0
	roster.anchor_right = 1.0
	roster.offset_left = -260
	roster.offset_right = -margin
	roster.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(roster)

	var bar_bg := ColorRect.new()
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_bg.color = Color(0, 0, 0, 0.35)
	bar_bg.anchor_top = 1.0
	bar_bg.anchor_bottom = 1.0
	bar_bg.offset_left = margin
	bar_bg.offset_top = -34
	bar_bg.offset_right = margin + 190
	bar_bg.offset_bottom = -20
	add_child(bar_bg)
	speed_fill = ColorRect.new()
	speed_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	speed_fill.color = Color(0.55, 0.9, 0.3)
	bar_bg.add_child(speed_fill)
	speed_label = _label(13)
	speed_label.anchor_top = 1.0
	speed_label.anchor_bottom = 1.0
	speed_label.offset_left = margin + 198
	speed_label.offset_top = -36
	add_child(speed_label)

	var health_bg := ColorRect.new()
	health_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	health_bg.color = Color(0, 0, 0, 0.38)
	health_bg.anchor_top = 1.0
	health_bg.anchor_bottom = 1.0
	health_bg.offset_left = margin
	health_bg.offset_top = -58
	health_bg.offset_right = margin + 190
	health_bg.offset_bottom = -43
	add_child(health_bg)
	health_fill = ColorRect.new()
	health_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	health_fill.color = Color(0.34, 0.92, 0.31)
	health_bg.add_child(health_fill)
	health_label = _label(12)
	health_label.anchor_top = 1.0
	health_label.anchor_bottom = 1.0
	health_label.offset_left = margin + 198
	health_label.offset_top = -61
	add_child(health_label)

	ammo_label = _label(19)
	ammo_label.anchor_left = 1.0
	ammo_label.anchor_right = 1.0
	ammo_label.anchor_top = 1.0
	ammo_label.anchor_bottom = 1.0
	ammo_label.offset_left = -390
	ammo_label.offset_right = -28
	ammo_label.offset_top = -92
	ammo_label.offset_bottom = -18
	ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ammo_label.add_theme_color_override("font_color", Color(1.0, 0.80, 0.20))
	add_child(ammo_label)

	enemy_label = _label(15)
	enemy_label.anchor_left = 0.5
	enemy_label.anchor_right = 0.5
	enemy_label.offset_left = -240
	enemy_label.offset_right = 240
	enemy_label.offset_top = margin
	enemy_label.offset_bottom = margin + 30
	enemy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(enemy_label)

	headshot_label = _label(24)
	headshot_label.anchor_left = 0.5
	headshot_label.anchor_right = 0.5
	headshot_label.anchor_top = 0.5
	headshot_label.anchor_bottom = 0.5
	headshot_label.offset_left = -300
	headshot_label.offset_right = 300
	headshot_label.offset_top = 48
	headshot_label.offset_bottom = 84
	headshot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	headshot_label.add_theme_color_override("font_color", Color(1.0, 0.66, 0.10, 0.0))
	add_child(headshot_label)

	hint = _label(16)
	hint.anchor_left = 0.5
	hint.anchor_right = 0.5
	hint.anchor_top = 1.0
	hint.anchor_bottom = 1.0
	hint.offset_left = -400
	hint.offset_right = 400
	hint.offset_top = -70
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(hint)

	voice_label = _label(14)
	voice_label.anchor_left = 0.5
	voice_label.anchor_right = 0.5
	voice_label.anchor_top = 1.0
	voice_label.anchor_bottom = 1.0
	voice_label.offset_left = -330
	voice_label.offset_right = 330
	voice_label.offset_top = -108
	voice_label.offset_bottom = -80
	voice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	voice_label.add_theme_color_override("font_color", Color("bff58a"))
	add_child(voice_label)

	crosshair = CombatCrosshair.new()
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.anchor_left = 0.5
	crosshair.anchor_right = 0.5
	crosshair.anchor_top = 0.5
	crosshair.anchor_bottom = 0.5
	crosshair.offset_left = -110
	crosshair.offset_right = 110
	crosshair.offset_top = -110
	crosshair.offset_bottom = 110
	add_child(crosshair)

	spread_label = _label(11)
	spread_label.anchor_left = 0.5
	spread_label.anchor_right = 0.5
	spread_label.anchor_top = 0.5
	spread_label.anchor_bottom = 0.5
	spread_label.offset_left = -180
	spread_label.offset_right = 180
	spread_label.offset_top = 42
	spread_label.offset_bottom = 65
	spread_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	spread_label.add_theme_color_override("font_color", Color(0.88, 0.94, 0.78, 0.82))
	add_child(spread_label)

	camera_badge = _label(12)
	camera_badge.anchor_left = 0.5
	camera_badge.anchor_right = 0.5
	camera_badge.offset_left = -110
	camera_badge.offset_right = 110
	camera_badge.offset_top = 44
	camera_badge.offset_bottom = 68
	camera_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	camera_badge.add_theme_color_override("font_color", Color(0.78, 1.0, 0.58, 0.88))
	add_child(camera_badge)

	weapon_slots = _label(12)
	weapon_slots.anchor_left = 1.0
	weapon_slots.anchor_right = 1.0
	weapon_slots.anchor_top = 1.0
	weapon_slots.anchor_bottom = 1.0
	weapon_slots.offset_left = -438
	weapon_slots.offset_right = -18
	weapon_slots.offset_top = -30
	weapon_slots.offset_bottom = -10
	weapon_slots.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	weapon_slots.add_theme_color_override("font_color", Color(0.83, 0.88, 0.75, 0.84))
	add_child(weapon_slots)

	# Vehicle instrument cluster: big speed, gear, RPM bar, per-kind extras.
	vehicle_panel = Panel.new()
	vehicle_panel.anchor_left = 0.5
	vehicle_panel.anchor_right = 0.5
	vehicle_panel.anchor_top = 1.0
	vehicle_panel.anchor_bottom = 1.0
	vehicle_panel.offset_left = 140
	vehicle_panel.offset_right = 420
	vehicle_panel.offset_top = -118
	vehicle_panel.offset_bottom = -20
	vehicle_panel.add_theme_stylebox_override("panel",
		_panel_style(Color(0.05, 0.08, 0.05, 0.72), Color(0.95, 0.76, 0.24)))
	vehicle_panel.visible = false
	add_child(vehicle_panel)
	vehicle_speed_label = _label(30)
	vehicle_speed_label.position = Vector2(16, 8)
	vehicle_speed_label.size = Vector2(170, 40)
	vehicle_panel.add_child(vehicle_speed_label)
	vehicle_gear_label = _label(22)
	vehicle_gear_label.position = Vector2(196, 12)
	vehicle_gear_label.size = Vector2(70, 34)
	vehicle_gear_label.add_theme_color_override("font_color",
		Color(0.95, 0.86, 0.45))
	vehicle_panel.add_child(vehicle_gear_label)
	var rpm_back := ColorRect.new()
	rpm_back.color = Color(0.12, 0.16, 0.12, 0.9)
	rpm_back.position = Vector2(16, 52)
	rpm_back.size = Vector2(248, 10)
	vehicle_panel.add_child(rpm_back)
	vehicle_rpm_fill = ColorRect.new()
	vehicle_rpm_fill.color = Color(0.55, 0.88, 0.35)
	vehicle_rpm_fill.position = Vector2(16, 52)
	vehicle_rpm_fill.size = Vector2(0, 10)
	vehicle_panel.add_child(vehicle_rpm_fill)
	vehicle_extra_label = _label(13)
	vehicle_extra_label.position = Vector2(16, 66)
	vehicle_extra_label.size = Vector2(248, 26)
	vehicle_extra_label.add_theme_color_override("font_color",
		Color(0.80, 0.88, 0.80, 0.9))
	vehicle_panel.add_child(vehicle_extra_label)

	damage_overlay = ColorRect.new()
	damage_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	damage_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	damage_overlay.color = Color(0.78, 0.025, 0.01, 0.0)
	add_child(damage_overlay)

	# Keep the optical layer above the normal HUD. Damage feedback is moved back
	# to the front so taking a hit remains legible even while scoped.
	sniper_scope = SniperScopeOverlay.new()
	sniper_scope.name = "SniperScope"
	sniper_scope.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(sniper_scope)
	move_child(damage_overlay, get_child_count() - 1)
	player.health_changed.connect(_on_health_changed)
	_last_health = player.health
	if player.world is World:
		player.world.headshot_scored.connect(_on_headshot_scored)

	Net.score_changed.connect(_refresh_scores)
	Net.roster_changed.connect(_refresh_scores)
	Voice.local_talking_changed.connect(_on_local_talking_changed)
	Voice.speaker_talking_changed.connect(_on_speaker_talking_changed)
	_refresh_scores()


func _label(size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	l.add_theme_constant_override("outline_size", 6)
	return l


func _panel_style(fill: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.shadow_color = Color(0, 0, 0, 0.36)
	style.shadow_size = 6
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style


func _refresh_scores() -> void:
	var my_id := Net.local_id()
	score_label.text = "🍌 %d" % int(Net.scores.get(my_id, 0))
	var lines: Array = []
	if Net.active:
		var ids := Net.names.keys()
		ids.sort()
		for id in ids:
			var star := "  ← you" if id == my_id else ""
			var talking := "  🎙" if Voice.is_peer_talking(int(id)) else ""
			lines.append("%s  🍌%d%s%s" % [Net.names[id],
				int(Net.scores.get(id, 0)), talking, star])
	roster.text = "\n".join(lines)


func _on_local_talking_changed(_active: bool) -> void:
	_update_voice_label()


func _on_speaker_talking_changed(_peer_id: int, _active: bool) -> void:
	_refresh_scores()
	_update_voice_label()


func show_voice_error(message: String) -> void:
	_voice_error = message.left(160)
	_voice_error_t = 4.0
	_update_voice_label()


func _update_voice_label() -> void:
	if not voice_label:
		return
	if _voice_error_t > 0.0:
		voice_label.text = "MICROPHONE  ·  " + _voice_error
		voice_label.add_theme_color_override("font_color", Color("ffd58a"))
		return
	if Voice.local_talking:
		voice_label.text = "🎙  TRANSMITTING  ·  RELEASE T TO STOP"
		voice_label.add_theme_color_override("font_color", Color("bff58a"))
		return
	var speaker_names: Array[String] = []
	for peer_id in Voice.speaking_peers():
		if Net.names.has(peer_id):
			speaker_names.append(str(Net.names[peer_id]))
	voice_label.text = ("🎙  " + ", ".join(speaker_names) + " TALKING") \
		if not speaker_names.is_empty() else ("HOLD T TO TALK" if Net.active else "")
	voice_label.add_theme_color_override("font_color", Color("bff58a"))


func _on_health_changed(current: float, maximum: float) -> void:
	if is_equal_approx(current, _last_health):
		return
	var healed := current > _last_health
	_last_health = current
	if current >= maximum and not healed:
		return
	damage_overlay.color = Color(0.08, 0.82, 0.20, 0.16) if healed \
		else Color(0.82, 0.02, 0.01, 0.22)
	var tween := damage_overlay.create_tween()
	var fade_color := Color(0.08, 0.82, 0.20, 0.0) if healed \
		else Color(0.82, 0.02, 0.01, 0.0)
	tween.tween_property(damage_overlay, "color", fade_color,
		0.48 if healed else 0.32)


func _on_headshot_scored(source: Node3D, _target: Node3D, lethal: bool,
		distance: float) -> void:
	if source != player:
		return
	headshot_label.text = "HEADSHOT · INSTANT KO" if lethal \
		else "LONG-RANGE HEADSHOT · 80 DAMAGE"
	headshot_label.modulate = Color.WHITE
	headshot_label.scale = Vector2(1.2, 1.2)
	headshot_label.pivot_offset = headshot_label.size * 0.5
	var tween := headshot_label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(headshot_label, "scale", Vector2.ONE, 0.12)
	tween.tween_property(headshot_label, "modulate:a", 0.0,
		clampf(0.85 + distance * 0.003, 0.85, 1.15)).set_delay(0.32)


func show_camera_mode(mode: int) -> void:
	_camera_notice_mode = mode
	_camera_notice_t = 1.8


## Public diagnostics/test API. Normal play also drives this every frame from
## _update_sniper_scope(), keeping scope knowledge out of MonkeyPlayer.
func set_sniper_scope_state(active: bool, magnification: float, range_m: float,
		drop_m: float, target_zone := ScopeTarget.NONE) -> void:
	_sniper_scope_active = active
	if sniper_scope and is_instance_valid(sniper_scope):
		sniper_scope.set_scope_state(active, magnification, range_m, drop_m,
			target_zone)


func clear_sniper_scope() -> void:
	_sniper_scope_active = false
	if sniper_scope and is_instance_valid(sniper_scope):
		sniper_scope.clear_scope()


func _process(dt: float) -> void:
	if not player or not is_instance_valid(player):
		return
	_help_t = maxf(_help_t - dt, 0.0)
	_camera_notice_t = maxf(_camera_notice_t - dt, 0.0)
	_voice_error_t = maxf(_voice_error_t - dt, 0.0)
	_update_voice_label()
	var sp: float = player.velocity.length()
	speed_label.text = "%.0f m/s" % sp
	var frac := clampf(sp / 40.0, 0.0, 1.0)
	speed_fill.size = Vector2(190 * frac, 14)
	speed_fill.color = Color(0.55, 0.9, 0.3).lerp(Color(1.0, 0.6, 0.15), frac)
	var health_fraction := clampf(player.health / player.MAX_HEALTH, 0.0, 1.0)
	health_fill.size = Vector2(190 * health_fraction, 15)
	health_fill.color = Color(0.95, 0.16, 0.08).lerp(
		Color(0.34, 0.92, 0.31), health_fraction)
	health_label.text = "HP %d" % ceili(player.health)

	if minimap:
		minimap.visible = minimap.mode != 2 and not _sniper_scope_active
		roster.position.y = 12.0 + (minimap.size.y + 8.0 \
			if minimap.visible else 0.0)
	var weapon = player.active_weapon if player.active_weapon else player.gun
	var front_camera: bool = player.cam != null and player.cam.front_view
	_update_sniper_scope(weapon, front_camera)
	spread_label.visible = not _sniper_scope_active
	camera_badge.visible = not _sniper_scope_active
	hint.visible = not _sniper_scope_active
	voice_label.visible = not _sniper_scope_active
	enemy_label.visible = not _sniper_scope_active
	weapon_slots.visible = not _sniper_scope_active
	if player.is_healing():
		var bandage_fill := roundi(player.bandage_progress() * 8.0)
		ammo_label.text = "WRAPPING BANDAGE  +%d HP\n[%s%s]" % [
			roundi(player.BANDAGE_HEAL), "▰".repeat(bandage_fill),
			"▱".repeat(8 - bandage_fill)]
	elif player.melee_mode:
		ammo_label.text = "MELEE MODE\nLMB COMBO  ·  Q DRAW WEAPON"
	elif weapon:
		var is_shotgun := weapon is PumpShotgun
		var is_smg := weapon is SMG
		var is_sniper := weapon is SniperRifle
		var weapon_name := "PUMP SHOTGUN" if is_shotgun \
			else ("JUNGLE SMG" if is_smg \
			else ("BOLT-ACTION SNIPER" if is_sniper else "BANANA GUN"))
		var capacity := PumpShotgun.CAPACITY if is_shotgun \
			else (SMG.CAPACITY if is_smg \
			else (SniperRifle.CAPACITY if is_sniper else BananaGun.CAPACITY))
		if weapon.reload_remaining > 0.0:
			var filled := roundi(weapon.reload_progress() * 8.0)
			var reload_text := "LOADING SHELLS" if is_shotgun \
				else ("SWAPPING MAG" if is_smg \
				else ("CHANGING MAG" if is_sniper else "RELOADING"))
			var reserve_text := ""
			if is_smg or is_sniper:
				reserve_text = "  ·  %d SPARE MAGS" % weapon.reserve_mags
			elif is_shotgun:
				reserve_text = "  ·  %d RESERVE" % weapon.reserve_ammo
			else:
				reserve_text = "  ·  %d RESERVE" % weapon.reserve_ammo
			ammo_label.text = "%s  %s%s\n[%s%s]  R" % [
				weapon_name, reload_text, reserve_text,
				"▰".repeat(filled), "▱".repeat(8 - filled)]
		elif is_smg or is_sniper:
			ammo_label.text = "%s\n%d / %d ROUNDS  ·  %d SPARE MAGS" % [
				weapon_name, weapon.ammo, capacity, weapon.reserve_mags]
		elif is_shotgun:
			ammo_label.text = "%s\n%d / %d SHELLS  ·  %d RESERVE" % [
				weapon_name, weapon.ammo, capacity, weapon.reserve_ammo]
		else:
			var ammo_kind := "SHELLS" if is_shotgun else "ROUNDS"
			ammo_label.text = "%s\n%d / %d %s  ·  %d RESERVE" % [
				weapon_name, weapon.ammo, capacity, ammo_kind,
				weapon.reserve_ammo]
	if not ammo_label.text.is_empty():
		ammo_label.text += "\n[H] BANDAGE ×%d" % player.bandages

	var ai = player.world.ai_opponent if player.world is World else null
	if ai and is_instance_valid(ai):
		var my_kos := int(player.world.combat_kills.get(player.peer_id, 0))
		var ai_kos := int(player.world.combat_kills.get(ai.peer_id, 0))
		enemy_label.text = "CAPTAIN PEEL  HP %d     DUEL  %d – %d" % [
			ceili(ai.health), my_kos, ai_kos]
	else:
		enemy_label.text = ""

	var reticle_color := Color(1.0, 1.0, 0.92, 0.94)
	if not player.last_target.is_empty():
		reticle_color = Color(0.52, 1.0, 0.28, 0.98)
	if weapon and weapon.reload_remaining > 0.0:
		reticle_color = Color(1.0, 0.62, 0.12, 0.92)
	if player.is_healing():
		reticle_color = Color(0.32, 1.0, 0.42, 0.96)
	if player.melee_mode:
		reticle_color = Color(0.62, 1.0, 0.32, 0.96)
	crosshair.visible = not front_camera and not _sniper_scope_active
	if front_camera:
		spread_label.text = ""
	else:
		var aim_distance := _aim_distance(80.0)
		var viewport_height := get_viewport().get_visible_rect().size.y
		var camera_fov: float = player.cam._cam.fov if player.cam else 76.0
		var movement_spread: float = player.current_weapon_spread_degrees()
		var movement_radius_pixels: float = tan(deg_to_rad(movement_spread)) \
			/ tan(deg_to_rad(camera_fov * 0.5)) * viewport_height * 0.5
		if player.melee_mode:
			crosshair.set_state(CombatCrosshair.Mode.PLUS, 0.0,
				reticle_color, false, 0.0, 0.0)
			spread_label.text = "MELEE  •  3-HIT COMBO"
			spread_label.modulate = Color(0.65, 1.0, 0.34)
		elif weapon is PumpShotgun:
			# The shotgun pattern is centered inside the same movement/swing
			# cone as every other weapon, so add the half-angles for a truthful
			# worst-case ring.
			var total_spread: float = PumpShotgun.SPREAD_HALF_ANGLE_DEGREES \
				+ movement_spread
			var ring_radius := tan(deg_to_rad(total_spread)) \
				/ tan(deg_to_rad(camera_fov * 0.5)) * viewport_height * 0.5
			crosshair.set_state(CombatCrosshair.Mode.SHOTGUN, ring_radius,
				reticle_color, player.cam.aiming if player.cam else false,
				weapon.recoil)
			var cone_diameter := tan(deg_to_rad(total_spread)) \
				* aim_distance * 2.0
			spread_label.text = "PELLET CONE Ø %.1fm  •  %.0fm" % [
				cone_diameter, aim_distance]
			spread_label.modulate = Color(0.55, 1.0, 0.36) \
				if aim_distance <= 15.0 else (
					Color.WHITE if aim_distance <= 30.0 else Color(1.0, 0.65, 0.18))
		else:
			crosshair.set_state(CombatCrosshair.Mode.PLUS, 0.0, reticle_color,
				player.cam.aiming if player.cam else false,
				weapon.recoil if weapon else 0.0, movement_radius_pixels)
			if weapon is SniperRifle:
				spread_label.text = "HIP SPREAD  ±%.2f°" % movement_spread
				spread_label.modulate = Color(0.82, 0.96, 0.72)
			else:
				spread_label.text = ""
	camera_badge.text = "◉ FRONT VIEW" if front_camera \
		else ("◉ FIRST PERSON" if player.cam and player.cam.first_person \
		else "◉ RIGHT-SHOULDER CAMERA")
	weapon_slots.text = ("[1] BANANA  [2] SHOTGUN  [3] SMG  [4] SNIPER  [Q] MELEE" if not weapon \
		else ("1  BANANA   " if player.weapon_slot == 1 else "1  Banana   ")
		+ ("2  SHOTGUN   " if player.weapon_slot == 2 else "2  Shotgun   ")
		+ ("3  SMG   " if player.weapon_slot == 3 else "3  SMG   ")
		+ ("4  SNIPER   " if player.weapon_slot == 4 else "4  Sniper   ")
		+ ("[Q] MELEE" if player.melee_mode else "Q  Melee"))

	_update_vehicle_cluster()
	var nearby_hut: SupplyHut = player.world.nearby_supply_chest(player) \
		if player.world is World else null
	var nearby_ride: Vehicle = null
	if player.vehicle == null and player.world is World:
		nearby_ride = player.world.nearby_vehicle(player)
	if player.vehicle != null:
		hint.text = _vehicle_hint(player.vehicle)
	elif player.supply_notice_remaining > 0.0:
		hint.text = player.supply_notice
	elif player.is_healing():
		hint.text = "WRAPPING BANDAGE  ·  HOLD STEADY"
	elif nearby_hut:
		hint.text = "SUPPLY CHEST  ·  TAP E TO OPEN"
	elif nearby_ride:
		hint.text = "%s  ·  TAP E TO %s" % [nearby_ride.display_name(),
			nearby_ride.mount_verb()]
	elif _camera_notice_t > 0.0:
		if _camera_notice_mode == CameraRig.ViewMode.FRONT:
			hint.text = "FRONT VIEW  •  C TO RETURN"
		elif _camera_notice_mode == CameraRig.ViewMode.FIRST_PERSON:
			hint.text = "FIRST-PERSON CAMERA"
		else:
			hint.text = "RIGHT-SHOULDER CAMERA"
	elif front_camera:
		hint.text = "FRONT VIEW  ·  C cycle camera  ·  hold RMB to aim"
	elif player.melee_mode:
		hint.text = "MELEE MODE  ·  LMB three-hit combo  ·  Q draw weapon  ·  1/2/3/4 equip"
	elif player.state == 2:  # SWING
		hint.text = "W pump · A/D steer · scroll reel · SPACE jump off · release E · LMB fire"
	elif player.state == 4:  # SWIM
		hint.text = "swim: WASD paddle · SHIFT stroke faster · SPACE hop out"
	elif not player.last_target.is_empty():
		hint.text = "hold E to GRAB · LMB fire · hold RMB to aim"
	elif _help_t > 0.0:
		hint.text = "WASD run · E vine/chest · LMB fire · H bandage · RMB aim · C camera · 1/2/3/4 weapons · R reload"
	else:
		hint.text = ""


func _update_vehicle_cluster() -> void:
	var v: Vehicle = player.vehicle if player else null
	if v == null or not is_instance_valid(v):
		vehicle_panel.visible = false
		return
	vehicle_panel.visible = true
	vehicle_speed_label.text = "%3.0f MPH" % v.speed_mph()
	var rpm_frac: float = clampf(v.engine.rpm_fraction(), 0.0, 1.0)
	vehicle_rpm_fill.size.x = 248.0 * rpm_frac
	vehicle_rpm_fill.color = Color(0.9, 0.25, 0.2) if rpm_frac > 0.92 \
		else Color(0.55, 0.88, 0.35)
	match v.kind:
		Vehicle.Kind.JET:
			var jet := v as FighterJet
			vehicle_gear_label.text = "%d%%" % int(jet.spool * 100.0)
			var status := "GEAR %s · FLAPS %s · ALT %dm" % [
				"DN" if jet.gear_down else "UP",
				"DN" if jet.flaps_down else "UP",
				int(v.global_position.y - Gen.height(v.global_position.x,
					v.global_position.z))]
			if jet.afterburner:
				status += " · AFTERBURNER"
			if jet.stalled:
				status = "◤ STALL ◥ " + status
			vehicle_extra_label.text = status
		Vehicle.Kind.BOAT:
			vehicle_gear_label.text = "FAN"
			vehicle_extra_label.text = "W fan · S fast idle/coast · A/D rudders"
		_:
			vehicle_gear_label.text = "GEAR %s" % v.engine.gear_label()
			var extra := "W drive · S brake/reverse · SPACE handbrake"
			if v is SafariJeep and (v as SafariJeep).low_range:
				extra = "LOW RANGE · " + extra
			vehicle_extra_label.text = extra


func _vehicle_hint(v: Vehicle) -> String:
	match v.kind:
		Vehicle.Kind.JET:
			return "W/S throttle · aim to steer · SHIFT burner · G gear · F flaps · SPACE airbrake · CTRL brakes · E exit"
		Vehicle.Kind.BOAT:
			return "W fan · S fast idle/coast · A/D rudders · no reverse · E step off"
		Vehicle.Kind.BIKE:
			return "W throttle · S brakes · A/D lean · SPACE rear brake · SHIFT tuck · E dismount"
		_:
			return "W drive · S brake/reverse · A/D steer · SPACE handbrake · SHIFT low range · E exit"


func _aim_distance(maximum: float) -> float:
	if not player or not player.get_world_3d():
		return maximum
	var aim: Array = player.shot_aim()
	var start: Vector3 = aim[0]
	var finish: Vector3 = start + (aim[1] as Vector3).normalized() * maximum
	var query := PhysicsRayQueryParameters3D.create(start, finish)
	query.exclude = [player.get_rid()]
	query.collision_mask = 1 | CombatHitbox.HITBOX_LAYER
	query.collide_with_areas = true
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(query)
	return maximum if hit.is_empty() else start.distance_to(hit.position)


func _update_sniper_scope(weapon: Node, front_camera: bool) -> void:
	var sniper := weapon as SniperRifle
	var scoped: bool = not front_camera and sniper != null and player.cam != null \
		and player.cam.is_sniper_scoped()
	if not scoped:
		clear_sniper_scope()
		return
	var solution := _sniper_scope_solution(SNIPER_SCOPE_RANGE)
	var range_m: float = solution.range_m
	set_sniper_scope_state(true, sniper.magnification(), range_m,
		SniperRifle.drop_below_zero_at(range_m), int(solution.target_zone))


func _sniper_scope_solution(maximum: float) -> Dictionary:
	var solution := {
		"range_m": maximum,
		"target_zone": ScopeTarget.NONE,
	}
	if not player or not player.get_world_3d():
		return solution
	var aim: Array = player.shot_aim()
	var start: Vector3 = aim[0]
	var finish: Vector3 = start + (aim[1] as Vector3).normalized() * maximum
	var query := PhysicsRayQueryParameters3D.create(start, finish)
	var exclusions: Array[RID] = [player.get_rid()]
	if player.body_hitbox and is_instance_valid(player.body_hitbox):
		exclusions.append(player.body_hitbox.get_rid())
	if player.head_hitbox and is_instance_valid(player.head_hitbox):
		exclusions.append(player.head_hitbox.get_rid())
	query.exclude = exclusions
	query.collision_mask = 1 | CombatHitbox.HITBOX_LAYER
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return solution
	solution.range_m = start.distance_to(hit.position)
	var collider = hit.collider
	if collider is CombatHitbox:
		var hit_actor = collider.actor
		if hit_actor and hit_actor != player and hit_actor.has_method("take_damage"):
			solution.target_zone = ScopeTarget.HEAD \
				if collider.zone == "head" else ScopeTarget.BODY
	elif collider is Node3D and collider != player \
			and collider.has_method("take_damage"):
		solution.target_zone = ScopeTarget.BODY
	return solution
