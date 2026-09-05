extends Node
const Law = preload("res://scripts/civil_law.gd")
const Life = preload("res://scripts/resident_life.gd")
const Routes = preload("res://scripts/civil_police_routes.gd")
const Authority = preload("res://scripts/civil_authority.gd")
var city: Node
var police_world: Node3D
var highway_world: Node3D
var view: Dictionary = {}
var _network: Node
var _clock := 0.0
var _hud: Label
var _bag: Node3D

func configure(owner_city: Node) -> void:
	city=owner_city
	police_world=preload("res://scripts/civil_police_world.gd").new()
	police_world.name="CivilPoliceWorld"
	city.world.add_child(police_world)
	police_world.configure(city)
	Net.bullet_fired.connect(_on_bullet)
	highway_world=preload("res://scripts/highway_world.gd").new()
	highway_world.name="RegionalHighways"
	city.world.add_child(highway_world)
	highway_world.configure(city.world)
	if city.frontier._online:
		_network=city.frontier._network.civil
		_network.updated.connect(_on_view)
		_network.finished.connect(_on_result)
		_on_view(_network.cached_view)
	var layer:=CanvasLayer.new();layer.layer=64;add_child(layer)
	_hud=Label.new();_hud.position=Vector2(20,110)
	_hud.add_theme_font_size_override("font_size",14)
	_hud.add_theme_color_override("font_color",Color("f3d9a0"))
	_hud.add_theme_constant_override("outline_size",4)
	layer.add_child(_hud)

func interactions() -> Array:
	var result: Array = []
	if not is_instance_valid(city.world.local_player) or city.is_inside(): return result
	var at: Vector3 = city.world.local_player.global_position
	var sites: Dictionary = Routes.site_positions()
	var labels: Dictionary = {"station":"Police station · services and surrender","bank_security":"Credit union · security terminal",
		"bank_vault":"Credit union · vault cash","fence":"Salvage dealer · cash bags","community_service":"Custody · community-service table","escape":"Custody · maintenance gate"}
	for key: String in labels:
		var position: Vector3 = Law.vector(sites[key])
		if at.distance_to(position)<=5:
			result.append({"city":true,"kind":"civil_"+key,"position":position,"label":labels[key],"name":labels[key]})
	return result

func request_action(kind: String, payload: Dictionary = {}) -> Dictionary:
	if is_instance_valid(_network): return _network.request(kind,payload)
	var sim=city.frontier.simulation
	var economy=sim._city()
	var before: Dictionary = sim.state.duplicate(true)
	var law=Law.new();law.state=economy.state.civil_law
	var p=city.world.local_player
	var context: Dictionary = _observation()
	var result: Dictionary = law.action("player",kind,payload,sim,p.global_position,float(sim.state.time),context)
	if result.get("ok",false):
		economy.state.civil_law=law.state;sim.state.city=economy.state
		if city.frontier.persistence_enabled and not city.frontier.save_progress():
			sim.state=before;result={"ok":false,"message":"Could not save. The action was rolled back."}
	result.view=_offline_view()
	_on_result(kind,result)
	return result

func life_context(building_id: String = "") -> Dictionary:
	var context: Dictionary = {"health":city.world.local_player.health}
	var economy=city.frontier.simulation._city()
	if city.is_inside():
		var room: Dictionary = city.Plan.building(city.interior_id)
		var ownership: Dictionary = economy.state.properties.get(city.interior_id,{})
		var points: Dictionary = city.interior.service_points()
		if points.has("bed") and not economy.state.incidents.has(city.interior_id):
			context.bed={"building":city.interior_id,"position":city.interior.to_global(points.bed.position),"owner":str(ownership.get("owner","")),"residential":true}
	elif not economy.state.incidents.has(building_id):
		var building: Dictionary = city.Plan.building(building_id)
		if building.get("kind","")=="clinic": context.clinic={"building":building_id,"position":building.door,"kind":"clinic"}
	return context

func _observation() -> Dictionary:
	var p=city.world.local_player
	var speed: float = p.vehicle.speed() if is_instance_valid(p.vehicle) else p.velocity.length()
	var reserved:=0
	for job: Dictionary in city.frontier.simulation._city().state.active_jobs.values(): reserved+=int(job.reward)
	return {"peer":1,"position":p.global_position,"speed":speed,"on_foot":not is_instance_valid(p.vehicle),"inside":city.is_inside(),"speed_limit":Authority.road_limit(p.global_position),"reserved_payroll":reserved}

func _offline_view() -> Dictionary:
	var sim=city.frontier.simulation
	var economy=sim._city()
	var law=Law.new();law.state=economy.state.civil_law
	var next: Dictionary = law.view("player",float(sim.state.time))
	var life=Life.new();life.state=economy.state.resident_life
	next.resident_life=life.view("player");next.credits=sim.balance("player")
	return next

func _process(dt: float) -> void:
	if not is_instance_valid(city) or not is_instance_valid(city.world.local_player): return
	var earth: bool = city.frontier.current_planet()=="earth"
	police_world.visible=earth
	highway_world.visible=earth
	_clock+=dt
	if _clock<.2: return
	var step: float = minf(.5,_clock);_clock=0
	if not city.frontier._online and earth:
		var sim=city.frontier.simulation
		var economy=sim._city()
		var law=Law.new();law.state=economy.state.civil_law
		var events: Dictionary = law.advance(step,float(sim.state.time),{"player":_observation()},sim)
		economy.state.civil_law=law.state
		var life=Life.new();life.state=economy.state.resident_life
		life.advance("player",step,city.world.local_player.global_position,float(sim.state.time),life_context())
		economy.state.resident_life=life.state;sim.state.city=economy.state
		_on_view(_offline_view())
		if events.has("player"): _on_result("civil_update",events.player)
	_hud.visible=earth and not city.panel.visible and not city.frontier.ui.visible
	if not _hud.visible: return
	var life: Dictionary = view.get("resident_life",{})
	var personal: Dictionary = view.get("personal",{})
	var status: String = str(personal.get("phase","clear")).replace("_"," ").capitalize()
	var text: String = "J · Resident journal   Food %d%% · Water %d%% · Rest %d%%"%[roundi(life.get("nutrition",80)),roundi(life.get("hydration",80)),roundi(life.get("rest",80))]
	if status!="Clear" or int(personal.get("cash",0))>0: text+="\n"+status+" · "+str(personal.get("notice",""))
	var robbery: Dictionary = personal.get("robbery",{})
	if not robbery.is_empty(): text+="\n"+str(robbery.stage).replace("_"," ").capitalize()+" · %.1f sec"%float(robbery.remaining)
	var p=city.world.local_player
	if is_instance_valid(p.vehicle):
		var limit: float = Authority.road_limit(p.global_position)
		if limit>0: text+="\nSpeed %d MPH · Posted %d MPH"%[roundi(p.vehicle.speed()/0.44704),roundi(limit/0.44704)]
	_hud.text=text

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or event.keycode!=KEY_J: return
	if not is_instance_valid(city) or city.frontier.ui.visible or get_tree().paused: return
	if city.panel.visible: city.close_panel()
	else: city.panel.open({"kind":"civil_journal","name":"Resident journal"})
	get_viewport().set_input_as_handled()

func _on_view(snapshot: Dictionary) -> void:
	view=snapshot.duplicate(true)
	if is_instance_valid(city.crowd):city.crowd.set_civil_incidents(view.get("robberies",[]))
	if is_instance_valid(police_world): police_world.update_snapshot(view)
	if is_instance_valid(city.world.local_player):
		city.world.local_player.resident_stamina_multiplier=float(view.get("resident_life",{}).get("stamina_multiplier",1))
		_update_bag(int(view.get("personal",{}).get("cash",0))>0)

func _on_result(kind: String, outcome: Dictionary) -> void:
	if outcome.get("view") is Dictionary: _on_view(outcome.view)
	city.last_message=str(outcome.get("message",""))
	if outcome.get("ok",false) and outcome.get("destination") is Array:
		if is_instance_valid(city.world.local_player.vehicle): city.world.local_player.exit_vehicle(true)
		city._leave_room()
		city._teleport(Law.vector(outcome.destination)+Vector3.UP*.2)
	if is_instance_valid(city.panel) and city.panel.visible: city.panel.refresh_view()

func _update_bag(carrying: bool) -> void:
	if not is_instance_valid(_bag) and carrying:
		_bag=Node3D.new();_bag.name="RobberyCashBag"
		city.world.local_player.add_child(_bag)
		var mesh:=MeshInstance3D.new();var sack:=BoxMesh.new();sack.size=Vector3(.38,.46,.22);mesh.mesh=sack
		var material:=StandardMaterial3D.new();material.albedo_color=Color("997647");mesh.material_override=material
		_bag.add_child(mesh);_bag.position=Vector3(.45,.8,.1)
	if is_instance_valid(_bag): _bag.visible=carrying

func _on_bullet(shooter: int, origin: Vector3, _velocity: Vector3, _damage: float, _headshot: bool, _fx: bool, _weapon: int) -> void:
	if city.frontier._online or shooter!=Net.local_id() or not city.Plan.contains(Vector2(origin.x,origin.z)): return
	var sim=city.frontier.simulation
	var economy=sim._city()
	var law=Law.new();law.state=economy.state.civil_law
	for unit:Dictionary in law.state.units:
		var officer:Vector3=Law.vector(unit.get("officer_position",unit.position))
		if officer.distance_to(origin)<125 and Law._visible(officer,origin):
			law.report("player","armed_threat",origin,float(sim.state.time));break
	economy.state.civil_law=law.state;sim.state.city=economy.state
