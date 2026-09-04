class_name TradeUI
extends Control
## Ookbar the Provisioner's market stall. Bananas are the currency (the same
## synced score the jungle pickups feed), and the goods flow through the exact
## supply pipeline chests use, so nothing here invents a second inventory path.
## Pure UI + local math — villagers only exist in offline sessions.

signal closed

const MenuTheme := preload("res://scripts/menu_theme.gd")

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
var _receipt: Label
var _panel: PanelContainer
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
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh()
	_receipt.text = "Choose a supply below. Purchases go straight into your carried supplies."
	_patter_label.text = "“%s”" % PATTER[_rng.randi() % PATTER.size()]


func close() -> void:
	visible = false
	closed.emit()
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _ready() -> void:
	theme = MenuTheme.build()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var scrim := ColorRect.new()
	scrim.color = Color(0.02, 0.025, 0.03, 0.16)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	_panel = PanelContainer.new()
	_panel.minimum_size_changed.connect(_resize_panel, CONNECT_DEFERRED)
	_panel.add_theme_stylebox_override("panel", MenuTheme.panel())
	add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	_panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var portrait := VillagerPortrait.new()
	portrait.custom_minimum_size = Vector2(64, 64)
	header.add_child(portrait)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 4)
	header.add_child(titles)
	titles.add_child(MenuTheme.label("OOKBAR / PROVISIONER", 12, MenuTheme.ACCENT))
	titles.add_child(MenuTheme.label("Field supplies", 28))
	_patter_label = MenuTheme.label("", 14, MenuTheme.MUTED)
	titles.add_child(_patter_label)
	_balance_label = MenuTheme.label("", 20, MenuTheme.ACCENT)
	_balance_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_balance_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_balance_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_balance_label)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.follow_focus = true
	column.add_child(scroll)
	var offers := VBoxContainer.new()
	offers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(offers)
	for index in range(OFFERS.size()):
		var offer: Dictionary = OFFERS[index]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		offers.add_child(row)
		var description := VBoxContainer.new()
		description.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		description.add_theme_constant_override("separation", 2)
		row.add_child(description)
		description.add_child(MenuTheme.label(str(offer.label), 17))
		var detail := "Random ammunition, with a chance of a bandage." if int(offer.kind) == -2 else "Added to your carried bandages." if int(offer.kind) == -1 else "Added to your weapon's reserve ammunition."
		description.add_child(MenuTheme.label(detail, 13, MenuTheme.MUTED))
		var button := Button.new()
		button.text = "Buy · %d bananas" % int(offer.cost)
		button.custom_minimum_size = Vector2(170, 46)
		MenuTheme.style_button(button)
		button.pressed.connect(func() -> void: _buy(index))
		row.add_child(button)
		_offer_buttons.append(button)
	_receipt = MenuTheme.label("Choose a supply below. Purchases go straight into your carried supplies.", 14, MenuTheme.MUTED)
	column.add_child(_receipt)
	var leave := Button.new()
	leave.text = "Done trading · Esc"
	MenuTheme.style_button(leave)
	leave.pressed.connect(close)
	column.add_child(leave)
	get_viewport().size_changed.connect(_resize_panel)
	_resize_panel()


func _resize_panel() -> void:
	if not _panel:
		return
	var screen := get_viewport_rect().size
	var wanted := Vector2(minf(560, screen.x - 80), minf(520, screen.y - 80))
	_panel.size = wanted
	_panel.position = (screen - wanted) * 0.5


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
	_balance_label.text = "%d bananas" % bananas()
	for index in range(_offer_buttons.size()):
		_offer_buttons[index].disabled = \
			bananas() < int(OFFERS[index].cost)
		_offer_buttons[index].tooltip_text = "Need %d more bananas." % maxi(int(OFFERS[index].cost) - bananas(), 0) if _offer_buttons[index].disabled else "Buy %s" % OFFERS[index].label


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
	_receipt.text = "Purchased %s for %d bananas." % [str(offer.label), cost]
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
