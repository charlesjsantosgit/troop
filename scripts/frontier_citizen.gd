class_name FrontierCitizen
extends Node3D
## Peaceful, economical presentation of one authoritative simulation worker.
## The simulation owns movement, cargo and arrival-gated work; this rig only
## interpolates those positions and displays actual tasks and carried goods.

var citizen_id := ""
var rig: MonkeyRig
var _simulation: RefCounted
var _host: Node3D
var _planet := "earth"
var _name_label: Label3D
var _cargo: Node3D
var _job := "citizen"
var _last_task := ""
var _time := 0.0
var _initialized := false
var _vehicle: Node3D
var _fuel_label: Label3D
var _sampled_xz := Vector2.INF
var _sampled_height := 0.0
var _sampled_up := Vector3.UP


func configure(id: String, simulation: RefCounted, host: Node3D, planet: String) -> void:
	citizen_id = id
	_simulation = simulation
	_host = host
	_planet = planet


func build() -> void:
	var data := _data()
	_job = str(data.get("job", "citizen"))
	name = "Citizen_%s" % citizen_id
	rig = MonkeyRig.new()
	rig.name = "PeacefulMonkeyRig"
	add_child(rig)
	rig.setup(str(data.get("name", citizen_id)), true)
	rig.set_melee_pose(false, false, 0.0, 0)
	rig.scale = Vector3.ONE * 1.18
	_clean_render(rig)
	if rig.tag:
		rig.tag.visible = false
	_name_label = Label3D.new()
	_name_label.position = Vector3(0, 2.0, 0)
	_name_label.font_size = 26
	_name_label.pixel_size = 0.009
	_name_label.modulate = Color(0.83, 0.96, 0.84)
	_name_label.outline_size = 6
	_name_label.outline_modulate = Color(0.05, 0.09, 0.08)
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.visibility_range_end = 22.0
	add_child(_name_label)
	_build_workwear()
	_cargo = Node3D.new()
	_cargo.position = Vector3(0, 0.36, -0.38)
	rig.torso_p.add_child(_cargo)
	_part(_cargo, "box", Vector3.ZERO, Vector3(0.49, 0.32, 0.32), Color(0.53, 0.31, 0.12))
	for sx in [-0.21, 0.21]:
		_part(_cargo, "box", Vector3(sx, 0, -0.171), Vector3(0.04, 0.33, 0.025), Color(0.77, 0.57, 0.29))
	_cargo.visible = false
	if _job in ["tanker_driver", "hauler", "freight_hauler"]:
		_build_vehicle()
	update_citizen(0.0, Vector3.INF)


func _data() -> Dictionary:
	if _simulation == null:
		return {}
	var state: Dictionary = _simulation.get("state")
	return state.get("citizens", {}).get(citizen_id, {})


func _ground(x: float, z: float) -> float:
	if _host.has_method("surface_height"):
		return float(_host.call("surface_height", x, z))
	if _host.has_method("height_at"):
		return float(_host.call("height_at", x, z))
	return Gen.height(x, z)


func update_citizen(dt: float, camera_position: Vector3) -> void:
	var data := _data()
	if data.is_empty() or rig == null:
		return
	if str(data.get("job", "citizen")) != _job:
		# Reassignment changes the visible uniform, tools and vehicle together
		# with the authoritative profession; stale livery never survives a job.
		for child in get_children():
			remove_child(child)
			child.queue_free()
		rig = null
		_vehicle = null
		_fuel_label = null
		_last_task = ""
		_initialized = false
		build()
		return
	var coordinates: Array = data.get("position", [0.0, 0.0])
	var at := Vector3(float(coordinates[0]), 0.0, float(coordinates[1]))
	var xz := Vector2(at.x, at.z)
	if xz != _sampled_xz:
		_sampled_xz = xz
		_sampled_height = _ground(at.x, at.z)
		if _planet == "moon" and _host.has_method("surface_normal"):
			_sampled_up = _host.call("surface_normal", at.x, at.z)
	at.y = _sampled_height
	var previous := position
	if not _initialized:
		position = at
		_initialized = true
	else:
		# Model updates are one second apart. Traverse each authoritative
		# segment at its real speed, instead of racing to each sample in a
		# tenth of a second and visibly stopping between every model tick.
		var speed := 6.0 if _vehicle != null else 2.6
		position = position.move_toward(at, speed * dt)
	if _planet == "moon" and _host.has_method("surface_normal"):
		basis = Basis(Quaternion(Vector3.UP, _sampled_up.normalized()))
	var vel := (position - previous) / maxf(dt, 0.001)
	vel.y = 0.0
	var distant := camera_position != Vector3.INF and camera_position.distance_squared_to(global_position) > 130.0 * 130.0
	rig.visible = not distant
	if distant:
		return
	_time += dt
	var moving := vel.length_squared() > 0.08
	if moving:
		var heading := atan2(-vel.x, -vel.z)
		if _vehicle != null:
			_vehicle.rotation.y = lerp_angle(_vehicle.rotation.y, heading, minf(dt * 5.0, 1.0))
		else:
			rig.set_yaw(lerp_angle(rig.yaw_node.rotation.y, heading, minf(dt * 8.0, 1.0)))
	var carried: Dictionary = data.get("carrying", {})
	_cargo.visible = not carried.is_empty() and _vehicle == null
	rig.update_motion(dt, MonkeyRig.Anim.RUN if moving and _vehicle == null else MonkeyRig.Anim.IDLE,
		vel, true, Vector3.ZERO)
	if _vehicle != null:
		rig.sh_l.rotation.x = -0.8
		rig.sh_r.rotation.x = -0.8
		rig.el_l.rotation.x = -0.6
		rig.el_r.rotation.x = -0.6
		if _fuel_label != null:
			var cargo_text := "Empty · collecting next load"
			if not carried.is_empty():
				var item := str(carried.get("item", carried.keys()[0]))
				var amount := str(carried.get("quantity", carried.get(item, 0)))
				cargo_text = "%s · %s %s" % [item.replace("_", " ").capitalize(), amount, "L" if item in ["diesel", "gasoline", "jet_fuel", "crude_oil"] else "kg"]
			_fuel_label.text = cargo_text
	if _cargo.visible:
		rig.sh_l.rotation.x = -0.7
		rig.sh_r.rotation.x = -0.7
		rig.el_l.rotation.x = -0.35
		rig.el_r.rotation.x = -0.35
	elif not moving and float(data.get("work_remaining", 0.0)) > 0.0:
		# Small deliberate tool strokes communicate work without combat swings.
		rig.sh_r.rotation.x = -0.5 + sin(_time * 3.8) * 0.2
		rig.el_r.rotation.x = -0.45 + sin(_time * 3.8 + 0.7) * 0.16
		rig.torso_p.rotation.x += 0.07
	if _planet == "moon" and _vehicle == null:
		rig.position.y = absf(sin(_time * 3.3)) * 0.1 if moving else 0.0
	var task := str(data.get("activity", data.get("task", "Enjoying the village")))
	if task != _last_task:
		_last_task = task
		_name_label.text = "%s · %s\n%s" % [str(data.get("name", citizen_id)),
			_job.replace("_", " ").capitalize(), task.left(46)]
		_name_label.modulate = Color(1.0, 0.83, 0.45) if not str(data.get("blocker", "")).is_empty() else Color(0.83, 0.96, 0.84)


func interaction() -> Dictionary:
	var data := _data()
	return {"id": citizen_id, "kind": "citizen",
		"label": "%s · %s" % [data.get("name", citizen_id), _job.replace("_", " ").capitalize()],
		"position": global_position + Vector3.UP}


func _build_workwear() -> void:
	var work_color := Color(0.29, 0.53, 0.36)
	if _job in ["oil_rigger", "refinery_operator", "tanker_driver", "mechanic"]:
		work_color = Color(0.95, 0.52, 0.09)
	elif _job in ["merchant", "packer", "warehouse_keeper", "farm_manager"]:
		work_color = Color(0.25, 0.48, 0.7)
	elif _job in ["cook", "beekeeper", "greenhouse_technician"]:
		work_color = Color(0.9, 0.87, 0.7)
	elif _job == "citizen":
		work_color = Color(0.64, 0.32, 0.4)
	_part(rig.torso_p, "box", Vector3(0, 0.22, -0.12), Vector3(0.31, 0.38, 0.12), work_color)
	for sx in [-0.13, 0.13]:
		_part(rig.torso_p, "box", Vector3(sx, 0.3, -0.19), Vector3(0.037, 0.34, 0.023), Color(0.88, 0.81, 0.55))
	if _job in ["oil_rigger", "refinery_operator", "mechanic", "carpenter", "solar_technician", "water_operator"]:
		_part(rig.head_p, "sphere", Vector3(0, 0.15, 0), Vector3(0.39, 0.19, 0.37), Color(1.0, 0.74, 0.12))
		_part(rig.head_p, "cylinder", Vector3(0, 0.1, -0.015), Vector3(0.45, 0.04, 0.44), Color(1.0, 0.76, 0.16))
	elif _job in ["grower", "agronomist", "farm_manager", "fisher", "beekeeper"]:
		_part(rig.head_p, "cylinder", Vector3(0, 0.17, 0), Vector3(0.34, 0.14, 0.34), Color(0.76, 0.59, 0.28))
		_part(rig.head_p, "cylinder", Vector3(0, 0.12, 0), Vector3(0.59, 0.04, 0.55), Color(0.87, 0.72, 0.4))
	elif _job == "cook":
		_part(rig.head_p, "sphere", Vector3(0, 0.21, 0), Vector3(0.37, 0.3, 0.34), Color(0.96, 0.96, 0.9))
	if _planet == "moon":
		_part(rig.torso_p, "box", Vector3(0, 0.25, 0.25), Vector3(0.4, 0.42, 0.22), Color(0.78, 0.8, 0.79))
		_part(rig.head_p, "sphere", Vector3(0, 0.035, 0.025), Vector3(0.51, 0.5, 0.49), Color(0.83, 0.85, 0.84))
		# The gold forward visor is opaque for a cheap, readable sealed EVA suit.
		_part(rig.head_p, "sphere", Vector3(0, 0.025, -0.155), Vector3(0.4, 0.34, 0.22), Color(0.72, 0.49, 0.16))
		_part(rig.torso_p, "box", Vector3(0, 0.2, -0.23), Vector3(0.22, 0.14, 0.08), Color(0.18, 0.29, 0.37))
		if rig.winter_scarf:
			rig.winter_scarf.visible = false


func _build_vehicle() -> void:
	_vehicle = Node3D.new()
	_vehicle.name = "WorkingTanker" if _job == "tanker_driver" else "ProduceHauler"
	add_child(_vehicle)
	var props := FrontierProps.new(_vehicle)
	var steel := Color(0.39, 0.44, 0.43)
	var paint := Color(0.85, 0.49, 0.15) if _job == "tanker_driver" else Color(0.23, 0.47, 0.36)
	props.box(Vector3(0, 0.68, 0), Vector3(2.15, 0.34, 5.1), steel)
	props.box(Vector3(0, 1.16, -1.9), Vector3(1.9, 0.65, 1.05), paint)
	props.box(Vector3(0, 1.05, -2.46), Vector3(1.28, 0.32, 0.035), Color(0.1, 0.15, 0.16))
	props.box(Vector3(0, 2.69, -1.32), Vector3(2.05, 0.14, 1.85), paint)
	for x in [-0.89, 0.89]:
		for z in [-2.08, -0.54]:
			props.box(Vector3(x, 2.05, z), Vector3(0.075, 1.2, 0.075), steel)
		props.box(Vector3(x, 1.5, -2.49), Vector3(0.21, 0.15, 0.04), Color(0.96, 0.89, 0.65))
	for x in [-1.05, 1.05]:
		for z in [-1.6, 1.65]:
			props.cylinder(Vector3(x, 0.49, z), 0.48, 0.27, Color(0.08, 0.1, 0.09), false, Vector3(0, 0, PI * 0.5))
			props.cylinder(Vector3(x * 1.14, 0.49, z), 0.22, 0.03, steel, false, Vector3(0, 0, PI * 0.5))
	if _job == "tanker_driver":
		props.cylinder(Vector3(0, 1.65, 0.95), 0.95, 3.0, Color(0.67, 0.7, 0.64), false, Vector3(PI * 0.5, 0, 0), 0.45)
		for z in [-0.2, 2.1]:
			props.cylinder(Vector3(0, 1.65, z), 0.98, 0.12, paint, false, Vector3(PI * 0.5, 0, 0))
		props.cylinder(Vector3(0, 2.66, 0.9), 0.23, 0.15, steel)
	else:
		props.box(Vector3(0, 1.02, 0.95), Vector3(2.0, 0.2, 3.0), Color(0.51, 0.35, 0.19))
		for x in [-0.96, 0.96]:
			props.box(Vector3(x, 1.35, 0.95), Vector3(0.1, 0.7, 3.0), paint)
		for z in [0.0, 1.1, 2.1]:
			props.box(Vector3(0, 1.4, z), Vector3(1.4, 0.65, 0.85), Color(0.6, 0.43, 0.23))
	_fuel_label = props.text(Vector3(0, 3.5, 0.8), "", Color(0.95, 0.85, 0.61), 24, 24.0)
	props.flush()
	rig.reparent(_vehicle)
	rig.position = Vector3(0, 1.1, -1.25)
	rig.scale = Vector3.ONE * 0.84
	_name_label.position.y = 4.0


func _part(owner: Node3D, shape: String, at: Vector3, size: Vector3, color: Color) -> void:
	var node := MeshInstance3D.new()
	node.mesh = FrontierProps.mesh_for(shape)
	node.material_override = FrontierProps.material(color)
	node.position = at
	node.scale = size
	node.visibility_range_end = 100.0
	owner.add_child(node)


func _clean_render(node: Node) -> void:
	if node is GeometryInstance3D:
		node.material_overlay = null
		node.visibility_range_end = 130.0
	for child in node.get_children():
		_clean_render(child)
