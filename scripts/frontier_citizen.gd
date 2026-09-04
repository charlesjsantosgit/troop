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
var _vehicle: Vehicle
var _fuel_label: Label3D
var _sampled_xz := Vector2.INF
var _sampled_height := 0.0
var _sampled_up := Vector3.UP
var _work_tool: Node3D
var _work_active := false
var _interaction_focused := false


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
	rig._t = float(absi(citizen_id.hash()) % 173)*0.137
	rig.set_melee_pose(false, false, 0.0, 0)
	rig.set_standing_height(MonkeyRig.npc_height(citizen_id))
	_clean_render(rig)
	if rig.tag:
		rig.tag.visible = false
	_name_label = Label3D.new()
	_name_label.position = Vector3(0, rig.standing_height + 0.32, 0)
	_name_label.font_size = 24
	_name_label.pixel_size = 0.006
	_name_label.visible = _interaction_focused
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
	_build_tool()
	_bind_vehicle()
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
	_bind_vehicle()
	if is_instance_valid(_vehicle):
		_update_driver(dt, camera_position, data)
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
		rig.set_yaw(lerp_angle(rig.yaw_node.rotation.y, heading, minf(dt * 8.0, 1.0)))
	var carried: Dictionary = data.get("carrying", {})
	_cargo.visible = not carried.is_empty()
	rig.update_motion(dt, MonkeyRig.Anim.RUN if moving else MonkeyRig.Anim.IDLE,
		vel, true, Vector3.ZERO)
	_apply_work_pose(dt, data, moving)
	if _planet == "moon" and _vehicle == null:
		rig.position.y = absf(sin(_time * 3.3)) * 0.1 if moving else 0.0
	var task := str(data.get("activity", data.get("task", "Enjoying the village")))
	if task != _last_task:
		_last_task = task
		_name_label.text = "%s · %s" % [str(data.get("name", citizen_id)),
			_job.replace("_", " ").capitalize()]
		_name_label.modulate = Color(1.0, 0.83, 0.45) if not str(data.get("blocker", "")).is_empty() else Color(0.83, 0.96, 0.84)


func set_interaction_focus(focused: bool) -> void:
	_interaction_focused = focused
	if is_instance_valid(_name_label):
		_name_label.visible = focused


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


func _bind_vehicle() -> void:
	var traffic: Node = _host.get_meta("frontier_traffic") if _host.has_meta("frontier_traffic") else null
	var vehicle: Vehicle = traffic.vehicle_for(citizen_id) if is_instance_valid(traffic) else null
	if vehicle == _vehicle:
		return
	_vehicle = vehicle
	if is_instance_valid(_vehicle):
		_fuel_label = _vehicle.get("cargo_label")
	else:
		_fuel_label = null
		if rig != null:
			rig.reset_pose_state()
			_name_label.position.y = rig.standing_height + 0.32


func _update_driver(dt: float, camera_position: Vector3, data: Dictionary) -> void:
	_fuel_label = _vehicle.get("cargo_label")
	# The rigid body owns its pose. Citizens never rotate or move the vehicle.
	global_position = _vehicle.get_global_transform_interpolated().origin
	_initialized = true
	var distant := camera_position != Vector3.INF and camera_position.distance_squared_to(global_position) > 130.0 * 130.0
	rig.visible = is_visible_in_tree() and not distant
	_cargo.visible = false
	_name_label.position.y = 2.8
	_name_label.text = "%s · %s" % [data.get("name", citizen_id),
		_job.replace("_", " ").capitalize()]
	if distant:
		return
	rig.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	rig.top_level = true
	rig.set_yaw(0.0)
	rig.set_vehicle_pose(_vehicle.rider_render_pose())
	rig.global_transform = _vehicle.rider_render_transform()
	rig.set_ride_lean(_vehicle.state_aux().y)
	rig.update_motion(dt, MonkeyRig.Anim.RIDE, _vehicle.linear_velocity, true, Vector3.ZERO)
	_vehicle.update_manifest(data.get("carrying", {}))


func _build_tool() -> void:
	_work_tool = Node3D.new()
	rig.paw_r.add_child(_work_tool)
	_work_tool.position = Vector3(0,-0.06,-0.04)
	_work_tool.visible = false
	var wood := Color(0.48,0.31,0.15)
	var steel := Color(0.5,0.56,0.56)
	if _job in ["grower","agronomist","farm_manager","beekeeper"]:
		_part(_work_tool,"box",Vector3(0,-0.12,0),Vector3(0.045,0.32,0.045),wood)
		_part(_work_tool,"box",Vector3(0,-0.31,0.015),Vector3(0.13,0.16,0.035),steel)
	elif _job in ["solar_technician","greenhouse_technician","water_operator"]:
		_part(_work_tool,"box",Vector3(0,-0.15,0),Vector3(0.045,0.38,0.045),steel)
		_part(_work_tool,"box",Vector3(0,-0.35,0),Vector3(0.3,0.07,0.1),Color(0.22,0.45,0.49))
	elif _job == "cook":
		_part(_work_tool,"box",Vector3(0,-0.14,0),Vector3(0.035,0.34,0.035),wood)
		_part(_work_tool,"sphere",Vector3(0,-0.33,0),Vector3(0.12,0.05,0.08),wood)
	else:
		_part(_work_tool,"box",Vector3(0,-0.11,0),Vector3(0.04,0.27,0.025),steel)
		_part(_work_tool,"box",Vector3(-0.043,-0.24,0),Vector3(0.035,0.075,0.035),steel)
		_part(_work_tool,"box",Vector3(0.043,-0.24,0),Vector3(0.035,0.075,0.035),steel)


func _apply_work_pose(dt: float, data: Dictionary, moving: bool) -> void:
	var job: Dictionary = data.get("_job",{})
	var op := str(job.get("op",""))
	# Planned work_remaining is populated before travel begins. Animating it
	# while blocked used to repeatedly ADD torso pitch after the rig's blend,
	# accumulating a backwards lean. Work now requires actual active task state;
	# every pose writes an absolute bounded joint angle.
	_work_active = not moving and not job.is_empty() and str(data.get("activity","")) == str(job.get("label","")) and float(data.get("work_remaining",0.0))>0.0 and op not in ["rest","eat","leisure"]
	_work_tool.visible = _work_active and op not in ["load_move","load_trade","unload","inspect"]
	if moving and not _cargo.visible:
		return
	var blend := 1.0-exp(-14.0*dt)
	var torso := Vector3(0.04+sin(_time*1.6)*0.008,0,0)
	var left := Vector3(0.1,0,0.1)
	var right := Vector3(0.1,0,-0.1)
	var elbow_left := 0.3
	var elbow_right := 0.3
	if _cargo.visible:
		left=Vector3(-0.7,0,0.1)
		right=Vector3(-0.7,0,-0.1)
		elbow_left=-0.35
		elbow_right=-0.35
	elif _work_active:
		var stroke := sin(_time*2.3)
		var reach := 0.5-0.5*cos(_time*2.3)
		match _job:
			"grower","agronomist","farm_manager","beekeeper":
				torso.x=0.14+reach*0.10
				right=Vector3(-0.55-reach*0.45,0.12,-0.12)
				elbow_right=-0.25-reach*0.45
				left=Vector3(-0.35,0,0.15)
			"oil_rigger","refinery_operator","mechanic","carpenter":
				torso.x=0.12
				right=Vector3(-0.92,stroke*0.15,-0.14-stroke*0.09)
				left=Vector3(-0.72,0.15,0.18)
				elbow_right=-0.58+stroke*0.22
				elbow_left=-0.5
			"solar_technician","greenhouse_technician","water_operator":
				torso.x=0.14
				right=Vector3(-0.84-reach*0.2,stroke*0.28,-0.16)
				left=Vector3(-0.4,0,0.2)
				elbow_right=-0.45-stroke*0.15
			"cook":
				torso.x=0.12
				right=Vector3(-0.84+stroke*0.12,cos(_time*2.3)*0.15,-0.15)
				elbow_right=-0.5+stroke*0.15
				left=Vector3(-0.5,0,0.14)
			"packer","warehouse_keeper","hauler","merchant":
				torso.x=0.1+reach*0.06
				left=Vector3(-0.5-reach*0.45,0,0.17)
				right=Vector3(-0.5-reach*0.45,0,-0.17)
				elbow_left=-0.4-reach*0.3
				elbow_right=elbow_left
			_:
				right=Vector3(-0.65,stroke*0.10,-0.12)
				elbow_right=-0.45+stroke*0.12
	if _work_active or _cargo.visible:
		# This rig faces local -Z: positive arm X reaches forward, while a
		# forward-leaning torso uses negative X. Keep tools in front of the
		# worker instead of animating them behind the body silhouette.
		torso.x=-torso.x
		left.x=-left.x
		right.x=-right.x
		elbow_left=-elbow_left
		elbow_right=-elbow_right
	# Calm, planted waiting replaces generic rapid scratching while blocked.
	# Keep locomotion/foot placement from MonkeyRig; only upper joints change.
	rig.torso_p.rotation=rig.torso_p.rotation.lerp(torso,blend)
	rig.sh_l.rotation=rig.sh_l.rotation.lerp(left,blend)
	rig.sh_r.rotation=rig.sh_r.rotation.lerp(right,blend)
	rig.el_l.rotation.x=lerp_angle(rig.el_l.rotation.x,elbow_left,blend)
	rig.el_r.rotation.x=lerp_angle(rig.el_r.rotation.x,elbow_right,blend)
	if not _work_active:
		rig.head_p.rotation=rig.head_p.rotation.lerp(Vector3(-0.04,sin(_time*0.35)*0.045,0),blend)


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
