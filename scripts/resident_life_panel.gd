class_name ResidentLifePanel
extends VBoxContainer

const Life = preload("res://scripts/resident_life.gd")
const MenuTheme = preload("res://scripts/menu_theme.gd")
const Plan = preload("res://scripts/city_plan.gd")

var controller: Node
var context: Dictionary = {}
var _snapshot: Dictionary = {}
var _needs: Label
var _careers: Label
var _notice: Label
var _food: HFlowContainer
var _service_buttons: Array[Button] = []
var _food_key := ""
var _refresh_time := 0.0


static func build(parent: Node, owner_controller: Node, view: Dictionary, subject: Dictionary):
	var card := ResidentLifePanel.new()
	card.controller = owner_controller
	card.context = subject.duplicate(true)
	parent.add_child(card)
	card._build(view)
	return card


func _build(snapshot: Dictionary) -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)
	add_child(MenuTheme.label("Your day in Crownreach", 16, MenuTheme.ACCENT))
	_needs = MenuTheme.label("", 13)
	add_child(_needs)
	_food = HFlowContainer.new()
	_food.add_theme_constant_override("h_separation", 6)
	_food.add_theme_constant_override("v_separation", 6)
	add_child(_food)
	var building_id := str(context.get("building", context.get("id", "")))
	if str(context.get("kind", "")) == "bed":
		_service_buttons.append(_button(self, "Rest beside your bed · 15 sec", "life_rest", {"building":building_id}))
	var building: Dictionary = Plan.building(building_id)
	if str(building.get("kind", "")) == "clinic" or str(building.get("service", "")) == "clinic":
		_service_buttons.append(_button(self, "Clinic treatment · %d credits" % Life.CLINIC_PRICE,
			"life_clinic", {"building":building_id}))
	_careers = MenuTheme.label("", 12, MenuTheme.MUTED)
	add_child(_careers)
	_notice = MenuTheme.label("Food uses one item from your backpack. Needs pause while you are away.", 12, MenuTheme.MUTED)
	add_child(_notice)
	refresh(snapshot)


func refresh(snapshot: Dictionary) -> void:
	_snapshot = snapshot
	var life: Dictionary = snapshot.get("resident_life", {})
	if life.is_empty():
		visible = false
		return
	visible = true
	_needs.text = "Food %d%%  ·  Water %d%%  ·  Rest %d%%\n%s" % [roundi(float(life.get("nutrition",80))),
		roundi(float(life.get("hydration",80))), roundi(float(life.get("rest",80))),
		"Resting beside your bed…" if bool(life.get("resting",false)) else str(life.get("condition","Ready for the day"))]
	var bag: Dictionary = snapshot.get("backpack_counts", {})
	var key := ""
	for item in Life.CONSUMABLES:
		if int(bag.get(item,0)) > 0: key += "%s:%d;" % [item, int(bag[item])]
	if key != _food_key:
		_food_key = key
		for child in _food.get_children():
			_food.remove_child(child)
			child.queue_free()
		for item in Life.CONSUMABLES:
			if int(bag.get(item,0)) <= 0: continue
			_button(_food, "%s %s · %d" % ["Drink" if item == "water" else "Eat",
				str(Life.CONSUMABLES[item].label).to_lower(), int(bag[item])], "life_consume", {"item":item})
	var pending := bool(snapshot.get("action_pending",false))
	for button in _food.get_children():
		var item := str(button.get_meta("life_item",""))
		var food: Dictionary = Life.CONSUMABLES[item]
		button.disabled = pending or ((float(food.nutrition) == 0.0 or float(life.get("nutrition",80)) >= 100.0)
			and (float(food.hydration) == 0.0 or float(life.get("hydration",80)) >= 100.0))
	for button in _service_buttons: button.disabled = pending
	var careers: Array[String] = []
	for row: Dictionary in life.get("career_rows",[]):
		var next := " · next at %d jobs" % int(row.next_at) if int(row.next_at) >= 0 else " · highest level"
		careers.append("%s level %d · %d jobs · +%d%% pay%s" % [row.label, int(row.level), int(row.completed), int(row.bonus_percent), next])
	_careers.text = "\n".join(careers) + "\nCareer bonuses use available city funds after existing job commitments."


func _process(dt: float) -> void:
	# An initially missing network snapshot hides this card, but must not prevent
	# it from appearing when the first authority view arrives.
	if not is_instance_valid(controller) or not get_parent() is CanvasItem \
			or not get_parent().is_visible_in_tree(): return
	_refresh_time += dt
	if _refresh_time < 0.5: return
	_refresh_time = 0.0
	if controller.has_method("city_view"): refresh(controller.city_view())


func _button(parent: Node, text: String, kind: String, payload: Dictionary) -> Button:
	var button := Button.new()
	button.text = text
	MenuTheme.style_button(button, false, true)
	button.set_meta("city_focus", kind + "_" + str(payload.get("item",payload.get("building",""))))
	button.set_meta("life_item", str(payload.get("item","")))
	button.pressed.connect(func():
		if not is_instance_valid(controller) or bool(_snapshot.get("action_pending",false)): return
		var result: Dictionary = controller.request_action(kind,payload)
		if is_instance_valid(_notice): _notice.text = str(result.get("message","Request sent."))
		if controller.has_method("city_view"): refresh(controller.city_view()))
	parent.add_child(button)
	return button
