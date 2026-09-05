extends Node3D
## Physical Westgate civic sites and snapshot-driven patrol presentation.
## All pursuit decisions, money, custody and robberies belong to CivilLaw.
const Routes = preload("res://scripts/civil_police_routes.gd")
const Plan = preload("res://scripts/city_plan.gd")
const Cars = preload("res://scripts/city_vehicle_models.gd")
const Monkeys = preload("res://scripts/city_monkey_models.gd")
const MAX_UNITS := 8
const SNAPSHOT_BLEND := 0.20
var controller: Node
var _units: Dictionary = {}
var _sites: Dictionary = {}
var _clock := 0.0
var _age := 0.0
var _snapshot_time := -INF
var _materials: Dictionary = {}
var _station: Node3D
var _bank: Node3D
var _fence: Node3D
var _vault_gate: AnimatableBody3D
var _vault_open := false
var _cash: Node3D
var _witnesses: Array[Node3D] = []
var _panic_until := 0.0
static var _siren_stream: AudioStreamWAV

func configure(city_controller: Node) -> void:
	controller = city_controller
	name = "CivicLifeAndPolice"
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_sites = Routes.site_positions()
	_build_sites()

func site_position(kind: String) -> Vector3:
	return Routes.vector(_sites.get(kind, []), Vector3.INF)

func get_interaction_sites() -> Array:
	var result: Array = []
	for row in [
		["station", "Police desk · surrender and case information"],
		["community_service", "Custody workshop · community service"],
		["escape", "Maintenance wall · escape custody"],
		["bank_security", "Canopy Credit Union · security terminal"],
		["bank_vault", "Credit union vault · cash reserve"],
		["fence", "Westgate salvage · sell stolen cash"],
	]:
		result.append({"id": row[0], "kind": row[0], "position": site_position(str(row[0])), "label": row[1]})
	return result

func update_snapshot(view: Dictionary) -> void:
	var time := float(view.get("time", _snapshot_time))
	if not is_finite(time) or time < _snapshot_time: return
	_snapshot_time = time
	_clock = time
	_age = 0.0
	var present: Dictionary = {}
	var rows: Variant = view.get("units", [])
	if not rows is Array: return
	for source in rows:
		if not source is Dictionary or present.size() >= MAX_UNITS: continue
		var id := str(source.get("id", ""))
		var at := Routes.vector(source.get("position", []), Vector3.INF)
		if id.is_empty() or not at.is_finite(): continue
		present[id] = true
		if not _units.has(id): _units[id] = _build_unit(id, at)
		var item: Dictionary = _units[id]
		item.from = item.body.global_position
		item.to = at
		item.from_heading = item.body.rotation.y
		item.to_heading = float(source.get("heading", 0.0))
		item.source = source.duplicate(true)
		item.officer_from = item.officer.global_position
		item.officer_to = Routes.vector(source.get("officer_position", []), at)
		if item.from.distance_squared_to(at) > 3600.0:
			# Initial visibility/reconnect correction only. Normal motion blends
			# server samples; clients never predict a fresh chase destination.
			item.from = at
			item.body.global_position = at
			item.officer_from = item.officer_to
	for id in _units.keys():
		if present.has(id): continue
		_units[id].body.queue_free()
		_units[id].officer.queue_free()
		_units.erase(id)
	var open := bool(view.get("bank_open", false))
	for robbery in view.get("robberies", []):
		if not robbery is Dictionary: continue
		var at := Routes.vector(robbery.get("position", []), Vector3.INF)
		if at.distance_to(site_position("bank")) < 50.0:
			_panic_until = _clock + 2.0
			if str(robbery.get("stage", "")) in ["vault_ready", "vault"]: open = true
	_vault_open = open
	if is_instance_valid(_vault_gate):
		_vault_gate.position.x = (10.0 if open else 0.0)
		_vault_gate.get_node("Collision").set_deferred("disabled", open)

func _physics_process(delta: float) -> void:
	_age += delta
	var t := clampf(_age / SNAPSHOT_BLEND, 0.0, 1.0)
	var time := _clock + _age
	for item: Dictionary in _units.values():
		var body: AnimatableBody3D = item.body
		body.global_position = Vector3(item.from).lerp(item.to, t)
		body.rotation.y = lerp_angle(float(item.from_heading), float(item.to_heading), t)
		var source: Dictionary = item.source
		var speed := float(source.get("speed", 0.0))
		var dismounted := bool(source.get("arrived", false)) and str(source.get("state", "patrol")) != "patrol"
		item.officer.visible = dismounted
		item.driver.visible = not dismounted
		item.officer.global_position = Vector3(item.officer_from).lerp(item.officer_to, t)
		var foot_delta: Vector3 = Vector3(item.officer_to) - Vector3(item.officer_from)
		if foot_delta.length_squared() > .015:
			item.officer.rotation.y = atan2(-foot_delta.x, -foot_delta.z)
			item.officer.get_node("CanonicalMonkey").mesh = Monkeys.pose("walk", 0, int(time * 6) % 4)
		else:
			item.officer.rotation.y = body.rotation.y
			item.officer.get_node("CanonicalMonkey").mesh = Monkeys.pose("talk")
		for wheel: Node3D in item.wheels: wheel.rotation.x -= speed * delta / Cars.wheel_radius(1)
		var emergency := bool(source.get("siren", false))
		var warning := emergency or str(source.get("state", "")) in ["traffic_stop", "arrest"]
		item.red.emission_energy_multiplier = 3.2 if warning and fposmod(time * 3, 1) < .46 else .05
		item.blue.emission_energy_multiplier = 3.2 if warning and fposmod(time * 3, 1) >= .54 else .05
		var siren: AudioStreamPlayer3D = item.siren
		if emergency and not siren.playing: siren.play()
		elif not emergency and siren.playing: siren.stop()
	for index in range(_witnesses.size()):
		var witness := _witnesses[index]
		var base: Vector3 = witness.get_meta("home")
		var panicking := time < _panic_until
		var destination := base + Vector3(0, 0, 14 if index == 0 else 11) if panicking else base
		witness.global_position = witness.global_position.move_toward(destination, delta * (2.8 if panicking else 1.0))
		witness.rotation.y = PI if panicking else 0.0
		witness.get_node("CanonicalMonkey").mesh = Monkeys.pose("walk" if panicking else "talk", 0, int(time * 6) % 4)

func _mat(id: String, color: Color, glow := false) -> StandardMaterial3D:
	if _materials.has(id): return _materials[id]
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = .78
	if glow:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = .7
	_materials[id] = material
	return material

func _box(parent: Node3D, id: String, at: Vector3, size: Vector3, material: Material, solid := false) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = id
	var shape := BoxMesh.new()
	shape.size = size
	mesh.mesh = shape
	mesh.material_override = material
	mesh.position = at
	parent.add_child(mesh)
	if solid:
		var body := StaticBody3D.new()
		body.name = id + "Collision"
		body.collision_layer = 1
		body.collision_mask = 0
		var collision := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = size
		collision.shape = box
		collision.position = at
		body.add_child(collision)
		parent.add_child(body)
	return mesh

func _label(parent: Node3D, text: String, at: Vector3, size := 50, heading := 0.0) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.position = at
	label.rotation.y = heading
	label.font_size = size
	label.pixel_size = .007
	label.modulate = Color("f4efe0")
	label.outline_size = 5
	label.no_depth_test = false
	parent.add_child(label)
	return label

func _person(parent: Node3D, at: Vector3, police := false) -> Node3D:
	var actor := Node3D.new()
	actor.name = "MonkeyOfficer" if police else "MonkeyResident"
	actor.position = at
	parent.add_child(actor)
	var mesh := MeshInstance3D.new()
	mesh.name = "CanonicalMonkey"
	mesh.mesh = Monkeys.pose("talk")
	actor.add_child(mesh)
	if police:
		var joints := Monkeys.attachment_points("talk")
		_box(actor, "PoliceCap", Vector3(joints.head) + Vector3(0, .16, 0), Vector3(.41, .11, .39), _mat("uniform", Color("243c53")))
		_box(actor, "CapVisor", Vector3(joints.head) + Vector3(0, .11, -.16), Vector3(.41, .025, .24), _mat("uniform", Color("243c53")))
		_box(actor, "UniformVest", Vector3(0, 1.04, -.145), Vector3(.35, .35, .08), _mat("uniform", Color("243c53")))
		_box(actor, "Badge", Vector3(-.09, 1.12, -.192), Vector3(.065, .07, .014), _mat("gold", Color("dabb61")))
		_box(actor, "Radio", Vector3(.16, 1.02, -.17), Vector3(.06, .13, .04), _mat("rubber", Color("252d34")))
	return actor

func _build_unit(unit_id: String, at: Vector3) -> Dictionary:
	var id := absi(unit_id.hash()) % 900
	var body := AnimatableBody3D.new()
	body.name = "PoliceCruiser_%d" % id
	body.collision_layer = 1
	body.collision_mask = 0
	body.sync_to_physics = false
	add_child(body)
	body.global_position = at
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.78, 1.42, 4.63)
	collision.shape = shape
	collision.position.y = .77
	body.add_child(collision)
	var car := Cars.build(body, 1, Color("e3e9e9"), true, true)
	var navy := _mat("police_paint", Color("19344c"))
	for side in [-1.0, 1.0]:
		_box(body, "BlueDoorPanel", Vector3(side * .893, .58, .04), Vector3(.014, .29, 1.8), navy)
		_label(body, "POLICE", Vector3(side * .909, .59, .05), 24, side * PI * .5)
	_box(body, "LightbarMount", Vector3(0, 1.52, .1), Vector3(1.2, .10, .24), navy)
	var red := _mat("unit_red_%d" % id, Color("ff343b"), true)
	var blue := _mat("unit_blue_%d" % id, Color("358cff"), true)
	_box(body, "RedEmergencyLight", Vector3(-.36, 1.62, .1), Vector3(.55, .13, .24), red)
	_box(body, "BlueEmergencyLight", Vector3(.36, 1.62, .1), Vector3(.55, .13, .24), blue)
	_label(body, str(id + 101), Vector3(0, .67, 2.335), 20)
	var driver: Node3D = body.get_node("CanonicalMonkeyDriver")
	var cap_at: Vector3 = Cars.driver_model(1).points.head
	_box(driver, "DriverPoliceCap", cap_at + Vector3(0, .1, 0), Vector3(.33, .08, .3), navy)
	var officer := _person(self, at, true)
	officer.visible = false
	var siren := AudioStreamPlayer3D.new()
	siren.name = "SpatialPoliceSiren"
	siren.stream = _siren()
	siren.unit_size = 12.0
	siren.max_distance = 180.0
	siren.volume_db = -18.0
	siren.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	body.add_child(siren)
	return {"body": body, "officer": officer, "driver": driver, "siren": siren, "wheels": car.wheels,
		"red": red, "blue": blue, "from": at, "to": at, "from_heading": 0.0, "to_heading": 0.0,
		"officer_from": at, "officer_to": at, "source": {}}

static func _siren() -> AudioStreamWAV:
	if _siren_stream != null: return _siren_stream
	const RATE := 16000
	const LENGTH := 2
	var bytes := PackedByteArray()
	bytes.resize(RATE * LENGTH * 2)
	var phase := 0.0
	for sample in range(RATE * LENGTH):
		var time := float(sample) / RATE
		var frequency := 620.0 + 380.0 * (.5 - .5 * cos(time * PI))
		phase += TAU * frequency / RATE
		var value := int((sin(phase) * .75 + sin(phase * 3) * .15) * 15000)
		bytes.encode_s16(sample * 2, value)
	_siren_stream = AudioStreamWAV.new()
	_siren_stream.format = AudioStreamWAV.FORMAT_16_BITS
	_siren_stream.mix_rate = RATE
	_siren_stream.data = bytes
	_siren_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	_siren_stream.loop_end = RATE * LENGTH
	return _siren_stream

func _build_sites() -> void:
	var stone := _mat("stone", Color("c1beb0"))
	var paving := _mat("paving", Color("7c8483"))
	var blue := _mat("civic_blue", Color("264f6b"))
	var metal := _mat("metal", Color("646f77"))
	var wood := _mat("wood", Color("8f7357"))
	for solid: Dictionary in Routes.structural_solids():
		var id := str(solid.id)
		var material := paving if id.ends_with("floor") else metal if id.begins_with("vault") or id.begins_with("custody") else stone
		_box(self, id, solid.position, solid.size, material, true)
	_station = Node3D.new()
	_station.name = "WestgatePoliceStation"
	_station.position = site_position("station_center")
	add_child(_station)
	_bank = Node3D.new()
	_bank.name = "CanopyCreditUnion"
	_bank.position = site_position("bank_center")
	add_child(_bank)
	_fence = Node3D.new()
	_fence.name = "WestgateSalvageFence"
	_fence.position = site_position("fence_center")
	add_child(_fence)
	# Walkable approach ramps join the slabs to the existing western road.
	for sign_value in [-1.0, 1.0]:
		var at := Vector3(Plan.MIN_X - 38, Plan.GROUND_Y + .3, sign_value * 20)
		var ramp := _box(self, "CivicAccessRamp", at, Vector3(8, .16, 13), paving, true)
		ramp.rotation.x = sign_value * .045
		# Align the ramp's collision as well as its visible surface.
		var ramp_body: Node3D = get_child(get_child_count() - 1)
		if ramp_body is StaticBody3D:
			ramp_body.position = at
			ramp_body.rotation.x = ramp.rotation.x
			ramp_body.get_child(0).position = Vector3.ZERO
	# A continuous footpath reaches the salvage canopy from the credit union.
	_box(self, "SalvageWalk", Vector3(Plan.MIN_X - 19, Plan.GROUND_Y + .07, -83), Vector3(4, .12, 52), paving, true)
	_box(_station, "PoliceSignBacking", Vector3(7, 3.15, -12.28), Vector3(17, .92, .12), blue)
	_label(_station, "WESTGATE POLICE  ·  COMMUNITY DESK", Vector3(7, 3.18, -12.37), 36, PI)
	_box(_station, "ReceptionCounter", Vector3(6, .48, -6), Vector3(8, .96, 1.2), wood, true)
	_person(_station, Vector3(6, 0, -3.8), true)
	_label(_station, "Report · surrender · assistance", Vector3(6, 1.34, -6.7), 27, PI)
	for z in [-5.0, -2.5, 0.0]:
		_box(_station, "WaitingBench", Vector3(14, .45, z), Vector3(1.8, .16, .55), wood, true)
		_box(_station, "BenchLeg", Vector3(13.4, .2, z), Vector3(.1, .4, .4), metal, true)
		_box(_station, "BenchLeg", Vector3(14.6, .2, z), Vector3(.1, .4, .4), metal, true)
	# A real enclosed yard, bed and workshop. A staged climb reaches the low
	# maintenance wall; escape authority checks the elevated ledge position.
	for z in [0.0, 1.5, 3.0, 4.5]:
		_box(_station, "CustodyGateBar", Vector3(-3, 1.2, z), Vector3(.13, 2.4, .10), metal, true)
	for y in [.4, 1.0, 1.7, 2.3]:
		_box(_station, "CustodyGateRail", Vector3(-3, y, 2.25), Vector3(.13, .09, 4.5), metal, true)
	var custody_gate := _box(_station, "CustodyGateHull", Vector3(-3, 1.3, 2), Vector3(.18, 2.6, 8), metal, true)
	custody_gate.visible = false
	_box(_station, "CustodyBed", Vector3(-11, .4, 0), Vector3(2.1, .3, 1), _mat("bed", Color("668777")), true)
	_box(_station, "ServiceWorkbench", Vector3(-11, .47, 15), Vector3(3, .94, 1), wood, true)
	_label(_station, "COMMUNITY WORKSHOP", Vector3(-11, 2.4, 15), 32)
	_label(_station, "Complete work to shorten custody", Vector3(-11, 1.85, 15), 24)
	for index in range(4):
		var height := .55 * (index + 1)
		_box(_station, "MaintenanceClimb_%d" % index, Vector3(-17.5 - index * 1.5, height * .5, 13), Vector3(1.6, height, 2.1), wood, true)
	_label(_station, "MAINTENANCE ACCESS", Vector3(-21, 3.1, 15.5), 23)
	_box(_bank, "CreditUnionSignBacking", Vector3(0, 3.55, 12.26), Vector3(24, 1.1, .12), _mat("bank_green", Color("336956")))
	_label(_bank, "CANOPY CREDIT UNION", Vector3(0, 3.6, 12.36), 62)
	for x in [-8.5, 8.5]:
		_box(_bank, "TellerCounter", Vector3(x, .55, 6), Vector3(7, 1.1, 1), wood, true)
		var resident := _person(_bank, Vector3(x, 0, 4))
		resident.rotation.y = PI
		resident.set_meta("home", resident.global_position)
		_witnesses.append(resident)
	_box(_bank, "SecurityTerminal", Vector3(7, .70, 3), Vector3(.9, 1.4, .7), blue, true)
	_box(_bank, "SecurityScreen", Vector3(7, 1.45, 3.13), Vector3(.72, .42, .07), _mat("screen", Color("79c9b6"), true))
	_label(_bank, "SECURITY CONTROL", Vector3(7, 2.15, 3.1), 27)
	_label(_bank, "CASH RESERVE", Vector3(0, 3.7, -1.75), 33)
	_label(_bank, "EMERGENCY EXIT", Vector3(0, 2.8, -11.73), 25)
	var glass := _mat("civic_window",Color("557b89"))
	glass.metallic = .35
	glass.roughness = .2
	for x in [-8.5,8.5]:
		_box(_bank,"StreetWindowFrame",Vector3(x,2.0,12.28),Vector3(8.2,1.7,.11),metal)
		_box(_bank,"StreetWindow",Vector3(x,2.0,12.35),Vector3(7.9,1.4,.045),glass)
		_box(_bank,"WindowMullion",Vector3(x,2.0,12.39),Vector3(.06,1.4,.04),metal)
	_box(_station,"PublicDeskWindowFrame",Vector3(11,1.9,-12.28),Vector3(7.2,1.6,.11),metal)
	_box(_station,"PublicDeskWindow",Vector3(11,1.9,-12.35),Vector3(6.9,1.3,.045),glass)
	_vault_gate = AnimatableBody3D.new()
	_vault_gate.name = "VaultSecurityGate"
	_vault_gate.collision_layer = 1
	_vault_gate.collision_mask = 0
	_vault_gate.sync_to_physics = false
	_vault_gate.position.z = -2
	_bank.add_child(_vault_gate)
	var gate_collision := CollisionShape3D.new()
	gate_collision.name = "Collision"
	var gate_shape := BoxShape3D.new()
	gate_shape.size = Vector3(5.6, 2.8, .20)
	gate_collision.shape = gate_shape
	gate_collision.position.y = 1.4
	_vault_gate.add_child(gate_collision)
	for x in range(-5, 6): _box(_vault_gate, "VaultGrille", Vector3(x * .5, 1.4, 0), Vector3(.07, 2.8, .11), metal)
	for y in [.3, 1.4, 2.6]: _box(_vault_gate, "VaultCrossbar", Vector3(0, y, 0), Vector3(5.6, .08, .11), metal)
	_cash = Node3D.new()
	_cash.name = "SecuredCashReserve"
	_cash.position = Vector3(0, 0, -8)
	_bank.add_child(_cash)
	_box(_cash, "CashTable", Vector3(0, .4, 0), Vector3(3, .8, 1.2), metal, true)
	for index in range(12):
		var at := Vector3((index % 4 - 1.5) * .55, .85 + (index / 4) * .12, 0)
		_box(_cash, "CashBundle", at, Vector3(.38, .10, .55), _mat("cash", Color("76a278")))
		_box(_cash, "CashStrap", at + Vector3(0, .056, 0), Vector3(.08, .012, .56), stone)
	_box(_fence, "SalvageCounter", Vector3(0, .5, 2), Vector3(8, 1, 1.2), wood, true)
	_person(_fence, Vector3(0, 0, -.2))
	_label(_fence, "WESTGATE SALVAGE", Vector3(0, 2.5, 2.6), 45)
	_label(_fence, "Ask about a discreet exchange", Vector3(0, 1.7, 2.65), 24)
	for index in range(5):
		_box(_fence, "SalvageCrate", Vector3(-7 + index * 3.4, .65, -3), Vector3(1.5, 1.3, 1.5), wood, true)
	# Overhead monkey routes join the social buildings without obstructing the
	# access carriageway. Their steps and rails have real collision.
	_box(self, "CanopyCivicBridge", Vector3(Plan.MIN_X - 38, Routes.SITE_Y + 5.3, 0), Vector3(3.2, .24, 66), wood, true)
	for side in [-1.0, 1.0]:
		_box(self, "CanopyBridgeRail", Vector3(Plan.MIN_X - 38 + side * 1.65, Routes.SITE_Y + 6.1, 0), Vector3(.12, .12, 66), metal, true)
	for index in range(9):
		var height := float(index + 1) * .59
		_box(self, "CanopyAccessStep", Vector3(Plan.MIN_X - 55 + index * 1.8, Routes.SITE_Y + height * .5, -28), Vector3(2, height, 2.2), wood, true)

func stats() -> Dictionary:
	var sirens := 0
	var officers := 0
	for item: Dictionary in _units.values():
		if item.siren.playing: sirens += 1
		if item.officer.visible: officers += 1
	return {"units": _units.size(), "officers_on_foot": officers, "active_sirens": sirens,
		"site_interactions": get_interaction_sites().size(), "snapshot_time": _snapshot_time,
		"vault_open": _vault_open, "physical_shapes": find_children("*", "CollisionShape3D", true, false).size()}
