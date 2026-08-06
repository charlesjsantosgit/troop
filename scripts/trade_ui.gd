class_name TradeUI
extends Control
## Ookbar the Provisioner's market stall. Bananas are the currency (the same
## synced score the jungle pickups feed), and the goods flow through the exact
## supply pipeline chests use, so nothing here invents a second inventory path.
## Pure UI + local math — villagers only exist in offline sessions.

signal closed

const OFFERS := [
	{"icon": "🍌🔫", "label": "12 Banana Rounds", "cost": 2, "kind": 0, "amount": 12},
	{"icon": "🐚", "label": "8 Shotgun Shells", "cost": 3, "kind": 1, "amount": 8},
	{"icon": "🔩", "label": "40 SMG Rounds", "cost": 4, "kind": 2, "amount": 40},
	{"icon": "🎯", "label": "10 Sniper Rounds", "cost": 5, "kind": 3, "amount": 10},
	{"icon": "🩹", "label": "2 Bandages", "cost": 2, "kind": -1, "amount": 2},
	{"icon": "🎁", "label": "Ook's Mystery Bundle", "cost": 1, "kind": -2, "amount": 0},
]

var player: MonkeyPlayer
var _balance_label: Label
var _offer_buttons: Array[Button] = []
var _patter_label: Label
var _rng := RandomNumberGenerator.new()

const PATTER := [
	"Ook has everything a discerning monkey needs.",
	"Fresh from the canopy, friend. Well… fresh-ish.",
	"Bananas in, firepower out. The jungle economy.",
	"A scarf-knitter, a seer, and a shopkeeper walk into a hut…",
	"No refunds. Ook has already eaten the bananas.",
]


func open_for(customer: MonkeyPlayer) -> void:
	player = customer
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh()
	_patter_label.text = "“%s”" % PATTER[_rng.randi() % PATTER.size()]


func close() -> void:
	visible = false
	closed.emit()
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var scrim := ColorRect.new()
	scrim.color = Color(0.03, 0.05, 0.03, 0.5)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.07, 0.035, 0.97)
	style.border_color = Color(0.95, 0.78, 0.28)
	style.set_border_width_all(3)
	style.set_corner_radius_all(18)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = Vector2(520, 0)
	center.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	panel.add_child(column)

	# Header: hand-drawn villager portrait + name + banana balance
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	var portrait := VillagerPortrait.new()
	portrait.custom_minimum_size = Vector2(74, 74)
	header.add_child(portrait)
	var titles := VBoxContainer.new()
	var name_label := Label.new()
	name_label.text = "OOKBAR THE PROVISIONER"
	name_label.add_theme_font_size_override("font_size", 21)
	name_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.3))
	titles.add_child(name_label)
	_patter_label = Label.new()
	_patter_label.add_theme_font_size_override("font_size", 13)
	_patter_label.add_theme_color_override("font_color",
		Color(0.82, 0.78, 0.62))
	_patter_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_patter_label.custom_minimum_size = Vector2(280, 0)
	titles.add_child(_patter_label)
	header.add_child(titles)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_balance_label = Label.new()
	_balance_label.add_theme_font_size_override("font_size", 24)
	_balance_label.add_theme_color_override("font_color",
		Color(1.0, 0.9, 0.35))
	header.add_child(_balance_label)
	column.add_child(header)

	var rule := ColorRect.new()
	rule.color = Color(0.95, 0.78, 0.28, 0.35)
	rule.custom_minimum_size = Vector2(0, 2)
	column.add_child(rule)

	# Offer grid
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	for index in range(OFFERS.size()):
		var offer: Dictionary = OFFERS[index]
		var card := Button.new()
		card.custom_minimum_size = Vector2(232, 58)
		card.text = "%s  %s\n🍌 %d" % [offer.icon, offer.label, offer.cost]
		card.add_theme_font_size_override("font_size", 14)
		var card_style := StyleBoxFlat.new()
		card_style.bg_color = Color(0.13, 0.11, 0.05)
		card_style.border_color = Color(0.62, 0.5, 0.22)
		card_style.set_border_width_all(1)
		card_style.set_corner_radius_all(12)
		card_style.set_content_margin_all(9)
		card.add_theme_stylebox_override("normal", card_style)
		var hover := card_style.duplicate()
		hover.bg_color = Color(0.22, 0.18, 0.07)
		hover.border_color = Color(1.0, 0.84, 0.3)
		card.add_theme_stylebox_override("hover", hover)
		var offer_index := index
		card.pressed.connect(func() -> void: _buy(offer_index))
		grid.add_child(card)
		_offer_buttons.append(card)
	column.add_child(grid)

	var leave := Button.new()
	leave.text = "WAVE GOODBYE  ·  ESC"
	leave.add_theme_font_size_override("font_size", 13)
	leave.pressed.connect(close)
	column.add_child(leave)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed \
			and (event.keycode == KEY_ESCAPE
				or event.physical_keycode == KEY_ESCAPE):
		close()
		get_viewport().set_input_as_handled()


func bananas() -> int:
	return int(Net.scores.get(Net.local_id(), 0))


func _refresh() -> void:
	_balance_label.text = "🍌 %d" % bananas()
	for index in range(_offer_buttons.size()):
		_offer_buttons[index].disabled = \
			bananas() < int(OFFERS[index].cost)


func _buy(index: int) -> void:
	if not player:
		return
	var offer: Dictionary = OFFERS[index]
	var cost := int(offer.cost)
	if bananas() < cost:
		Sfx.play("empty", -6.0)
		return
	Net.scores[Net.local_id()] = bananas() - cost
	Net.score_changed.emit()
	var kind := int(offer.kind)
	if kind >= 0:
		player.receive_supply_loot(kind, int(offer.amount), 0)
	elif kind == -1:
		player.receive_supply_loot(0, 0, int(offer.amount))
	else:
		# Mystery bundle: a random modest windfall from Ook's back room.
		var lucky_kind := _rng.randi_range(0, 3)
		var lucky_amount := _rng.randi_range(6, 20)
		player.receive_supply_loot(lucky_kind, lucky_amount,
			1 if _rng.randf() < 0.3 else 0)
		_patter_label.text = "“The bundle chose %s ammo. The bundle is wise.”" \
			% ["banana", "shotgun", "SMG", "sniper"][lucky_kind]
	Sfx.play("banana", -4.0)
	Sfx.play("ammo_pickup", -8.0)
	_refresh()


## Chunky hand-drawn shopkeeper: fur disc, lighter muzzle, straw hat, and the
## same seven-bead smile the real rigs wear.
class VillagerPortrait:
	extends Control

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.42
		draw_circle(c + Vector2(-r * 0.85, -r * 0.55), r * 0.34,
			Color(0.45, 0.32, 0.2))
		draw_circle(c + Vector2(r * 0.85, -r * 0.55), r * 0.34,
			Color(0.45, 0.32, 0.2))
		draw_circle(c, r, Color(0.52, 0.38, 0.24))
		draw_circle(c + Vector2(0, r * 0.25), r * 0.62, Color(0.86, 0.74, 0.58))
		for side in [-1.0, 1.0]:
			draw_circle(c + Vector2(side * r * 0.36, -r * 0.18), r * 0.11,
				Color(0.08, 0.06, 0.05))
			draw_circle(c + Vector2(side * r * 0.36 + 2.0, -r * 0.18 - 2.0),
				r * 0.035, Color.WHITE)
		for i in range(7):
			var t := float(i) / 6.0
			var smile := c + Vector2(lerpf(-r * 0.3, r * 0.3, t),
				r * 0.42 + sin(t * PI) * r * 0.14)
			draw_circle(smile, r * 0.045, Color(0.32, 0.2, 0.12))
		# straw hat
		draw_rect(Rect2(c + Vector2(-r * 1.05, -r * 0.95),
			Vector2(r * 2.1, r * 0.28)), Color(0.85, 0.72, 0.35))
		draw_rect(Rect2(c + Vector2(-r * 0.62, -r * 1.38),
			Vector2(r * 1.24, r * 0.52)), Color(0.9, 0.78, 0.4))
		draw_rect(Rect2(c + Vector2(-r * 0.62, -r * 1.02),
			Vector2(r * 1.24, r * 0.14)), Color(0.62, 0.24, 0.2))
