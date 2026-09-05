extends VBoxContainer
const MenuStyle = preload("res://scripts/menu_theme.gd")
const Law = preload("res://scripts/civil_law.gd")
const Routes = preload("res://scripts/civil_police_routes.gd")
var city: Node
var subject: Dictionary
var status: Label
var _clock:=0.0

static func build(parent: Node, controller: Node, context: Dictionary):
	var card=load("res://scripts/civil_panel.gd").new()
	card.city=controller;card.subject=context
	parent.add_child(card);card._build()
	return card

func _build() -> void:
	add_theme_constant_override("separation",7)
	status=MenuStyle.label("",13);add_child(status)
	var kind: String = str(subject.get("kind",""))
	if kind=="civil_bank_security": _button("Start credit union robbery · 8 sec security bypass","civil_rob",{"id":"bank"})
	elif kind=="civil_bank_vault": _button("Collect vault cash · 18 seconds","civil_vault")
	elif kind=="civil_fence": _button("Sell carried cash bag · 70% proceeds","civil_fence")
	elif kind=="civil_community_service": _button("Sort supplies · 12 seconds for release","civil_service")
	elif kind=="civil_escape": _button("Open maintenance gate · 18 seconds","civil_escape")
	elif kind=="civil_station":
		_button("Pay outstanding traffic citation","civil_pay")
		_button("Surrender at the desk","civil_surrender")
	elif kind=="building":
		var id: String = str(subject.get("id",""))
		var law=Law.new()
		if not law.target_for(id).is_empty(): _button("Rob this shop till · 10 seconds","civil_rob",{"id":id})
	_button("Stop taking cash","civil_cancel")
	_button("Surrender to nearby officer","civil_surrender")
	if kind=="civil_journal":
		add_child(MenuStyle.label("Police give warnings before repeat speeding citations. Robberies trigger a reported incident, response and search. Break sight or surrender. Legitimate possessions remain yours after arrest.",12,MenuStyle.MUTED))
		var sites: Dictionary = Routes.site_positions()
		for pair in [["Police station","station"],["Credit union","bank"],["Salvage dealer","fence"]]:
			var button:=Button.new();button.text="Show route · "+pair[0];MenuStyle.style_button(button,false,true);add_child(button)
			button.pressed.connect(func(): city.waypoint={"position":Law.vector(sites[pair[1]]),"label":pair[0]};city.close_panel())
	_refresh()

func _button(label: String, kind: String, payload: Dictionary = {}) -> void:
	var button:=Button.new();button.text=label;MenuStyle.style_button(button,false,true);add_child(button)
	button.pressed.connect(func():city.request_action(kind,payload);_refresh())

func _process(dt: float) -> void:
	_clock+=dt
	if _clock>=.2:_clock=0;_refresh()

func _refresh() -> void:
	if not is_instance_valid(city) or not is_instance_valid(status):return
	var view: Dictionary = city.civil.view
	var record: Dictionary = view.get("personal",{})
	status.text="Police status: %s\n%s\nCash bag: %d stolen credits · Citations: %d credits"%[str(record.get("phase","clear")).replace("_"," ").capitalize(),str(record.get("notice","You are free to go about your day.")),int(record.get("cash",0)),int(record.get("fine",0))]
	var robbery: Dictionary = record.get("robbery",{})
	if not robbery.is_empty():status.text+="\n%s · %.1f seconds remaining"%[str(robbery.stage).replace("_"," "),float(robbery.remaining)]
	if record.get("phase","")=="custody":status.text+="\nAutomatic release in %d seconds"%maxi(0,ceili(float(record.get("custody_until",0))-float(view.get("time",0))))
