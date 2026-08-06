extends Node
## Deterministic, first-person capture reel for the satisfying weapon, healing,
## and supply-chest animations. Run through Godot's Movie Maker so the same
## fixed simulation step drives animation, debris physics, particles, and audio.

const FPS := 30.0
const FRAME_DT := 1.0 / FPS

var _main: Node
var _player: MonkeyPlayer
var _fade: ColorRect
var _card: PanelContainer
var _title: Label
var _subtitle: Label
var _center_title: Label
var _center_subtitle: Label
var _hut: SupplyHut


func run(main: Node) -> void:
	_main = main
	_player = main.world.local_player
	_prepare_capture_world()
	_build_overlay()
	_prepare_showcase_hut()

	await _intro()
	await _banana_reload()
	await _shotgun_cycle_and_reload()
	await _smg_burst_and_reload()
	await _sniper_bolt_and_reload()
	await _bandage_heal()
	await _supply_chest_open()
	await _outro()

	print("ANIMATION_SHOWCASE_COMPLETE fps=30 segments=6")
	get_tree().quit(0)


func _prepare_capture_world() -> void:
	if _main.hud:
		_main.hud.visible = false
	# Avoid adaptive render-scale changes in the middle of a take.
	_main.set_process(false)
	get_viewport().scaling_3d_scale = 1.0
	_main.world.set_expensive_effects(true)

	_player.test_mode = true
	_player.ti.dir = Vector2.ZERO
	_player.velocity = Vector3.ZERO
	_player.state = MonkeyPlayer.S.GROUND
	var px := 0.0
	var pz := 0.0
	_player.global_position = Vector3(px, Gen.height(px, pz) + 0.05, pz)
	_player.reset_physics_interpolation()
	_player.cam.yaw = 0.0
	# Keep the ground in frame so dropped magazines, shells, and brass remain
	# readable without pushing the viewmodels out of the lower third.
	_player.cam.pitch = -0.10
	_player.cam.set_aiming(false)
	_player.cam.set_view_mode(CameraRig.ViewMode.FIRST_PERSON)
	_player.cam.snap_to_target()


func _build_overlay() -> void:
	var overlay := CanvasLayer.new()
	overlay.name = "ShowcaseOverlay"
	overlay.layer = 90
	add_child(overlay)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(root)

	_card = PanelContainer.new()
	_card.position = Vector2(36.0, 34.0)
	_card.size = Vector2(700.0, 92.0)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color(0.025, 0.038, 0.032, 0.88)
	card_style.border_color = Color(1.0, 0.77, 0.13, 0.95)
	card_style.set_border_width_all(2)
	card_style.set_corner_radius_all(10)
	card_style.content_margin_left = 18.0
	card_style.content_margin_right = 18.0
	card_style.content_margin_top = 11.0
	card_style.content_margin_bottom = 10.0
	_card.add_theme_stylebox_override("panel", card_style)
	root.add_child(_card)

	var card_text := VBoxContainer.new()
	card_text.add_theme_constant_override("separation", 2)
	_card.add_child(card_text)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 27)
	_title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.28))
	_title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_title.add_theme_constant_override("shadow_offset_x", 2)
	_title.add_theme_constant_override("shadow_offset_y", 2)
	card_text.add_child(_title)
	_subtitle = Label.new()
	_subtitle.add_theme_font_size_override("font_size", 16)
	_subtitle.add_theme_color_override("font_color", Color(0.90, 0.96, 0.90))
	card_text.add_child(_subtitle)

	var badge := Label.new()
	badge.text = "30 FPS  •  FIRST PERSON"
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", 15)
	badge.add_theme_color_override("font_color", Color(0.95, 1.0, 0.95))
	badge.add_theme_color_override("font_outline_color", Color(0.02, 0.04, 0.03))
	badge.add_theme_constant_override("outline_size", 6)
	badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	badge.position = Vector2(-262.0, 43.0)
	badge.size = Vector2(226.0, 34.0)
	root.add_child(badge)

	_center_title = Label.new()
	_center_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center_title.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_center_title.add_theme_font_size_override("font_size", 46)
	_center_title.add_theme_color_override("font_color", Color(1.0, 0.80, 0.16))
	_center_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_center_title.add_theme_constant_override("outline_size", 10)
	_center_title.set_anchors_preset(Control.PRESET_CENTER)
	_center_title.position = Vector2(-480.0, -68.0)
	_center_title.size = Vector2(960.0, 64.0)
	root.add_child(_center_title)

	_center_subtitle = Label.new()
	_center_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center_subtitle.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_center_subtitle.add_theme_font_size_override("font_size", 19)
	_center_subtitle.add_theme_color_override("font_color", Color(0.88, 0.96, 0.89))
	_center_subtitle.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_center_subtitle.add_theme_constant_override("outline_size", 7)
	_center_subtitle.set_anchors_preset(Control.PRESET_CENTER)
	_center_subtitle.position = Vector2(-480.0, 5.0)
	_center_subtitle.size = Vector2(960.0, 45.0)
	root.add_child(_center_subtitle)

	_fade = ColorRect.new()
	_fade.color = Color(0.008, 0.014, 0.010, 1.0)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_fade)
	# The fade covers the 3D take while cards stay readable above clean cuts.
	root.move_child(_fade, 0)


func _prepare_showcase_hut() -> void:
	_hut = SupplyHut.new()
	_hut.configure({
		"id": "animation:showcase",
		"pos": _player.global_position + Vector3(0.0, -0.05, -3.15),
		"yaw": PI,
		"ammo_kind": Gen.SUPPLY_AMMO_SHOTGUN,
		"ammo_amount": 12,
		"bandages": 2,
		"biome": Gen.Biome.RAINFOREST,
	})
	_main.world.add_child(_hut)
	_hut.visible = false


func _intro() -> void:
	_card.visible = false
	_center_title.text = "SATISFYING ANIMATION REEL"
	_center_subtitle.text = "Every new interaction • captured live in first person"
	await _hold(0.95)
	await _fade_to(0.0, 0.42)
	await _hold(0.45)
	await _fade_to(1.0, 0.20)
	_center_title.text = ""
	_center_subtitle.text = ""
	_card.visible = true


func _banana_reload() -> void:
	_set_card("01  BANANA GUN", "Banana-mag drop  •  double flip  •  catch  •  snap-in")
	_player.equip_weapon(1)
	_player.gun.reset_cylinder()
	_player.gun.ammo = 0
	_player.gun.reserve_ammo = BananaGun.CAPACITY
	await _reveal_segment()
	await _hold(0.28)
	_player.gun.start_reload()
	await _wait_for_reload(_player.gun, BananaGun.RELOAD_TIME + 0.5)
	await _hold(0.48)
	await _cover_segment()


func _shotgun_cycle_and_reload() -> void:
	_set_card("02  PUMP SHOTGUN", "Fire + spent shell  •  six hand-fed shells  •  final rack")
	_player.equip_weapon(2)
	_player.shotgun.reset_cylinder()
	_player.shotgun.ammo = 1
	_player.shotgun.reserve_ammo = PumpShotgun.CAPACITY
	await _reveal_segment()
	await _hold(0.25)
	_fire_weapon(_player.shotgun, PumpShotgun.CAMERA_RECOIL)
	await _hold(1.02)
	_player.shotgun.cooldown = 0.0
	_player.shotgun.start_reload()
	var full_reload_time := PumpShotgun.SHELL_RELOAD_TIME * PumpShotgun.CAPACITY \
		+ PumpShotgun.FINAL_PUMP_TIME
	await _wait_for_reload(_player.shotgun, full_reload_time + 0.6)
	await _hold(0.45)
	await _cover_segment()


func _smg_burst_and_reload() -> void:
	_set_card("03  SMG", "Brass shower  •  empty-mag drop  •  flip-catch  •  charge")
	_player.equip_weapon(3)
	_player.smg.reset_cylinder()
	_player.smg.ammo = 6
	_player.smg.reserve_mags = 1
	await _reveal_segment()
	await _hold(0.25)
	for shot in range(6):
		_fire_weapon(_player.smg, SMG.CAMERA_RECOIL)
		await _hold(SMG.FIRE_INTERVAL + 0.025)
	await _hold(0.42)
	_player.smg.cooldown = 0.0
	_player.smg.start_reload()
	await _wait_for_reload(_player.smg, SMG.RELOAD_TIME + 0.5)
	await _hold(0.45)
	await _cover_segment()


func _sniper_bolt_and_reload() -> void:
	_set_card("04  SNIPER RIFLE", "Shot + bolt extraction  •  casing  •  mag trick  •  bolt slam")
	_player.equip_weapon(4)
	_player.sniper.reset_cylinder()
	_player.sniper.ammo = 1
	_player.sniper.reserve_mags = 1
	await _reveal_segment()
	await _hold(0.28)
	_fire_weapon(_player.sniper, SniperRifle.CAMERA_RECOIL)
	await _hold(SniperRifle.BOLT_CYCLE_TIME + 0.28)
	_player.sniper.cooldown = 0.0
	_player.sniper.start_reload()
	await _wait_for_reload(_player.sniper, SniperRifle.RELOAD_TIME + 0.5)
	await _hold(0.48)
	await _cover_segment()


func _bandage_heal() -> void:
	_set_card("05  FIELD BANDAGE", "Unroll  •  wrap layers  •  tear  •  healing glint")
	_player.equip_weapon(1)
	_player.state = MonkeyPlayer.S.GROUND
	_player.velocity = Vector3.ZERO
	_player.health = 38.0
	_player.bandages = 1
	await _reveal_segment()
	await _hold(0.28)
	if not _player.start_bandage():
		push_error("Animation showcase could not start bandage sequence")
	await _wait_for_bandage(MonkeyPlayer.BANDAGE_TIME + 0.5)
	await _hold(0.48)
	await _cover_segment()


func _supply_chest_open() -> void:
	_set_card("06  SUPPLY HUT", "Chest kick-open  •  ammo glow  •  bandage pickup burst")
	# Put the weapon away so the chest owns the first-person silhouette.
	_player.set_physics_process(false)
	_player.state = MonkeyPlayer.S.SWIM
	_player.velocity = Vector3.ZERO
	_player._sync_weapon_presentation(true)
	_player.cam.yaw = 0.0
	_player.cam.pitch = -0.13
	_player.cam.snap_to_target()
	_hut.visible = true
	await _reveal_segment()
	await _hold(0.42)
	_hut.open_chest(true)
	await _hold(1.45)
	await _cover_segment()


func _outro() -> void:
	_card.visible = false
	_center_title.text = "FULLY RELOADED"
	_center_subtitle.text = "30 fps • first-person • in-game animation, particles, physics, and sound"
	await _hold(1.15)


func _set_card(title_text: String, subtitle_text: String) -> void:
	_title.text = title_text
	_subtitle.text = subtitle_text


func _reveal_segment() -> void:
	await _fade_to(0.0, 0.24)


func _cover_segment() -> void:
	await _fade_to(1.0, 0.18)


func _fade_to(alpha: float, duration: float) -> void:
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_fade, "color:a", alpha, duration)
	await tween.finished


func _fire_weapon(weapon: Node3D, camera_recoil: float) -> void:
	var direction := -_player.cam.cam_basis().z.normalized()
	var origin: Vector3 = weapon.muzzle.global_position
	if weapon.try_fire(origin, direction):
		_player.cam.add_weapon_recoil(camera_recoil)


func _wait_for_reload(weapon: Node3D, timeout_seconds: float) -> void:
	var remaining_frames := ceili(timeout_seconds * FPS)
	while weapon.reload_remaining > 0.0 and remaining_frames > 0:
		remaining_frames -= 1
		await get_tree().process_frame
	if weapon.reload_remaining > 0.0:
		push_error("Animation showcase reload timed out for %s" % weapon.name)


func _wait_for_bandage(timeout_seconds: float) -> void:
	var remaining_frames := ceili(timeout_seconds * FPS)
	while _player.is_healing() and remaining_frames > 0:
		remaining_frames -= 1
		await get_tree().process_frame
	if _player.is_healing():
		push_error("Animation showcase bandage timed out")


func _hold(seconds: float) -> void:
	for frame in range(maxi(ceili(seconds / FRAME_DT), 1)):
		await get_tree().process_frame
