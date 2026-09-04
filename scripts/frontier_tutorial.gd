class_name FrontierTutorial
extends Node
## Optional, resumable lessons. Progress observes gameplay; it never grants
## currency, teleports a player or bypasses a workplace/ownership requirement.

const CHAPTERS := ["basics", "farming", "industry", "moon"]
const LESSONS := {
	"basics": [
		["Meet Nana", "Follow the marker to Nana, the market keeper. Walk with WASD, look with the mouse, then press E beside him.", "nana", "meet", "nana"],
		["Buy a banana", "Nana's menu belongs to Nana. At his trading desk, find Banana and buy 1. You can see your price and bag before buying.", "earth_market", "buy", "banana"],
		["Visit the community board", "Close the menu and follow the marker. Press E at the board. B opens your personal journal; it also lets you find people and places.", "town_square", "meet", "town_square"],
		["Accept a neighbor's request", "Accept 'A welcome for the neighborhood'. The request needs 8 bananas. Your starting bag and purchase cover it; accepting alone does not pay you.", "town_square", "accept_quest", "first_harvest"],
		["Give the bananas", "Visit the market desk, press E, and give the 8 bananas for your active request. The bananas leave your bag and you receive the stated reward.", "earth_market", "deliver_quest", "first_harvest"]],
	"farming": [
		["Choose a town", "Online, visit an unclaimed town's board and claim it for 750 credits. Each player can own one town. If you already own one, visit it. Visitors can always trade and do requests.", "town_square", "owner", ""],
		["Plant a growing bed", "Find an empty bed you own and press E. Choose a crop for which you have a seed or start, then Plant. You begin with a banana start on Earth and lettuce seed on the Moon.", "empty_bed", "plant", ""],
		["Water your crop", "Press E at the bed you planted and choose Water. Five units leave your bag. Water and nutrients must be available for the crop to grow.", "planted_bed", "water", ""],
		["Watch it grow", "Return to your bed as it grows through sprout, leaves, flowers and ripe produce. You can explore meanwhile. Harvest becomes useful when growth reaches 100%.", "planted_bed", "harvest", ""],
		["Sell your harvest", "Visit the market keeper and sell some of your produce. More supply changes prices. Crops, seeds, fuel and money all have real amounts.", "market", "sell", ""]],
	"industry": [
		["Get workshop supplies", "Visit the market and buy 5 bananas. The workshop can dry them into 2 dried food and 1 compost. Each recipe displays its ingredients before you start.", "market", "buy", "banana"],
		["Use the workshop", "Visit Bamboo Works, press E, and choose Dry bananas. Processing uses the ingredients now; finished goods arrive after the work timer.", "workshop", "process", "dry_banana"],
		["Meet a delivery driver", "Meet Tug when the delivery jeep is parked. Workers choose jobs, collect real cargo, drive the roads, stop at a bay and unload. A blocked truck keeps its cargo until it arrives.", "tug", "meet", "tug"]],
	"moon": [
		["Board the rocket", "Follow the rocket marker. Press E at the boarding hatch, then use the rocket's launch control. Wait through the voyage; menus cannot move cargo or players between worlds.", "rocket", "realm", "moon"],
		["Find the Moon community", "Follow the greenhouse marker to First Landing. Its beds, market, habitat, power and cargo terminal are clustered around walkable paths. Press E at the greenhouse entrance.", "lunar_greenhouse", "meet", "lunar_greenhouse"],
		["Check lunar power", "Press E at the solar array to read generation and battery storage. Darkness stops panels; the battery powers the greenhouse. A town owner can install kits and maintain equipment here.", "solar_array", "meet", "solar_array"],
		["Visit lunar trade", "Meet the lunar market. Your Moon bag is separate from your Earth bag. The cargo terminal ships owned goods for a fee and travel time; cargo arrives once, with no copying.", "moon_market", "meet", "moon_market"]]
}

var controller: Node
var chapter := "basics"
var step := 0
var active := false
var complete := false
var welcomed := false
var planted_bed := ""
var path := ""
var _panel: PanelContainer
var _title: Label
var _text: Label
var _refresh := 0.0


func configure(host: Node, canvas: CanvasLayer, save_path := "") -> void:
	controller = host
	path = save_path
	_load_progress()
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_panel.position = Vector2(18, 340)
	_panel.custom_minimum_size.x = 334
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.10, 0.08, 0.92)
	style.set_corner_radius_all(12)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	_panel.add_theme_stylebox_override("panel", style)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_panel)
	var stack := VBoxContainer.new()
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_theme_constant_override("separation", 7)
	_panel.add_child(stack)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 18)
	_title.add_theme_color_override("font_color", Color("efd395"))
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_title)
	_text = Label.new()
	_text.add_theme_font_size_override("font_size", 15)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_text)
	if not welcomed:
		start()
	_refresh_card()


func start(next_chapter := "") -> void:
	if next_chapter in CHAPTERS and next_chapter != chapter:
		chapter = next_chapter
		step = 0
		complete = false
	if complete:
		step = 0
		complete = false
	active = true
	welcomed = true
	_skip_existing_progress()
	_save_progress()
	show_target()
	_refresh_card()


func pause() -> void:
	active = false
	_save_progress()
	_refresh_card()


func restart() -> void:
	step = 0
	planted_bed = ""
	complete = false
	start()


func summary() -> Dictionary:
	var lesson: Array = LESSONS[chapter][mini(step, LESSONS[chapter].size() - 1)]
	return {"chapter": chapter, "title": "Lesson complete" if complete else lesson[0],
		"text": "You can keep exploring. Choose another lesson here, or find a person or workplace in Places. Replaying a lesson uses your current game and never resets your money or town." if complete else lesson[1],
		"step": mini(step + 1, LESSONS[chapter].size()), "total": LESSONS[chapter].size(),
		"active": active, "complete": complete}


func _process(delta: float) -> void:
	_refresh -= delta
	if _refresh > 0 or not is_instance_valid(controller):
		return
	_refresh = 0.5
	if active:
		_skip_existing_progress()
		if controller.waypoint.is_empty():
			_show_waypoint()
	_refresh_card()


func observe_interaction(id: String) -> void:
	if not active or complete:
		return
	var lesson: Array = LESSONS[chapter][step]
	if lesson[3] == "meet" and lesson[4] == id:
		_advance()


func observe_action(kind: String, payload: Dictionary, result: Dictionary) -> void:
	if not active or complete or not result.get("ok", false):
		return
	var lesson: Array = LESSONS[chapter][step]
	if kind != lesson[3]:
		return
	var expected := str(lesson[4])
	var actual := str(payload.get("id", payload.get("item", payload.get("recipe", ""))))
	if not expected.is_empty() and actual != expected:
		return
	if kind == "plant":
		planted_bed = str(payload.get("plot", ""))
	if kind in ["water", "harvest"] and not planted_bed.is_empty() \
			and str(payload.get("plot", "")) != planted_bed:
		return
	_advance()


func _advance() -> void:
	step += 1
	if step >= LESSONS[chapter].size():
		complete = true
		active = false
	else:
		_show_waypoint()
	_save_progress()
	_refresh_card()


func _skip_existing_progress() -> void:
	if complete or not controller.simulation:
		return
	var lesson: Array = LESSONS[chapter][step]
	var state: Dictionary = controller.simulation.state
	if lesson[3] == "owner" and controller.current_town().get("is_owner", false):
		_advance()
	elif lesson[3] == "realm" and controller.current_planet() == lesson[4]:
		_advance()
	elif lesson[3] in ["accept_quest", "deliver_quest"]:
		var status := str(state.get("quests", {}).get(lesson[4], {}).get("status", ""))
		if status == "complete" or (lesson[3] == "accept_quest" and status == "active"):
			_advance()


func show_target() -> void:
	_show_waypoint()
	if is_instance_valid(controller.ui):
		controller.ui.close()


func _show_waypoint() -> void:
	if not active or complete or not is_instance_valid(controller):
		return
	var target: String = LESSONS[chapter][step][2]
	if target == "market":
		target = controller.current_planet() + "_market"
	elif target == "planted_bed":
		target = planted_bed
	elif target == "empty_bed":
		for plot: Dictionary in controller.simulation.state.get("plots", {}).values():
			if plot.planet == controller.current_planet() and plot.owner == "player" and str(plot.crop).is_empty():
				target = str(plot.id)
				break
	var saved: Dictionary = controller.waypoint.duplicate(true)
	if target == "rocket":
		controller.waypoint = {"label": "Rocket boarding hatch", "position": controller.expedition.rocket.boarding_global_position()}
		return
	for item: Dictionary in controller.interactions():
		if str(item.get("id", "")) == target:
			controller.waypoint = item.duplicate(true)
			return
	controller.waypoint = saved


func _refresh_card() -> void:
	if not is_instance_valid(_panel):
		return
	_panel.visible = active and not complete and not controller.ui.visible \
		and Net.player_realm() != Net.PlayerRealm.TRANSIT
	var info := summary()
	_title.text = "%s · %d / %d\n%s" % [chapter.capitalize(), info.step, info.total, info.title]
	_text.text = str(info.text) + "\n\nB → Tutorial to pause, resume or choose a lesson."
	var screen := get_viewport().get_visible_rect().size
	# Wrapped text can initially expand the container before its width settles.
	# Reset the retained height so the card hugs its content above the health HUD.
	_panel.custom_minimum_size.x = minf(334, screen.x - 36)
	_panel.size = Vector2(_panel.custom_minimum_size.x, 0)
	_panel.position = Vector2(18, maxf(150, screen.y - 210 - _panel.size.y))
	if is_instance_valid(controller.owner_main) and is_instance_valid(controller.owner_main.chat_box):
		var chat: Control = controller.owner_main.chat_box
		if chat.is_open() or chat._feed.get_global_rect().end.y + 12 > _panel.position.y:
			_panel.visible = false


func _load_progress() -> void:
	if path.is_empty():
		return
	var file := ConfigFile.new()
	if file.load(path) != OK:
		return
	var saved_chapter := str(file.get_value("guide", "chapter", "basics"))
	if saved_chapter not in CHAPTERS:
		return
	chapter = saved_chapter
	step = clampi(int(file.get_value("guide", "step", 0)), 0, LESSONS[chapter].size())
	complete = step == LESSONS[chapter].size()
	active = bool(file.get_value("guide", "active", false)) and not complete
	welcomed = true
	planted_bed = str(file.get_value("guide", "bed", "")).left(32)


func _save_progress() -> void:
	if path.is_empty():
		return
	var file := ConfigFile.new()
	file.set_value("guide", "chapter", chapter)
	file.set_value("guide", "step", step)
	file.set_value("guide", "active", active)
	file.set_value("guide", "bed", planted_bed)
	var destination := ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(destination.get_base_dir()) != OK:
		return
	if file.save(destination + ".tmp") == OK:
		DirAccess.rename_absolute(destination + ".tmp", destination)
