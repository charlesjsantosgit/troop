class_name CityCar
extends Vehicle
## Passenger and commercial cars share the measured fleet meshes and real
## suspension/tire/drivetrain solver; wheelbase, mass and steering vary by class.
const Fleet = preload("res://scripts/city_vehicle_models.gd")
var model_index := 1
var details: Dictionary = {}
var _fleet_visual: Node3D
var _brake: StandardMaterial3D
var rider_torso_recline := .20

func display_name()->String:
	return str(Fleet.spec(model_index).label)

func _total_brake_torque()->float:
	# Size the four service brakes for the loaded vehicle. The tire solver still
	# limits road force by grip, so a heavy van is not stuck with compact brakes.
	return mass*8.8*Fleet.wheel_radius(model_index)

func configure_model(index: int) -> void:
	model_index = clampi(index,0,Fleet.CATALOG.size()-1)
	var s := Fleet.spec(model_index)
	kind = Kind.JEEP
	mass = [1280.0,1430.0,1580.0,1570.0,1690.0,2260.0,2360.0,2480.0,1640.0,3180.0][model_index]
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0,.03,0)
	drag_area = float(s.width)*float(s.height)*(.34 if model_index<5 or model_index==8 else .46)
	max_steer_angle = .59
	steer_speed = 2.5
	camera_distance = float(s.length)*1.6
	camera_height = 2.3
	camera_chase_pitch = -.23
	var seat := Fleet.driver_seat(model_index)
	seat = Vector3(-seat.x,seat.y-.35,-seat.z)
	var seated:Dictionary=Fleet.driver_model(model_index,MonkeyRig.PLAYER_HEIGHT)
	var root_at:Vector3=seated.report.offset
	rider_root_offset=Vector3(-root_at.x,root_at.y-.35,-root_at.z)
	rider_torso_recline=float(Fleet.driver_config(model_index).recline)
	seat_offset = seat+Vector3(0,.1,0)
	fp_camera_offset = seat+Vector3(0,.65,.08)
	exit_offsets = [Vector3(float(s.width)*.5+.75,.45,seat.z),Vector3(-float(s.width)*.5-.75,.45,seat.z),Vector3(0,.5,-float(s.length)*.5-1)]
	speed_for_max_fov = 38
	engine_stream = "engine_i6"
	var torque: float = [175.0,215.0,255.0,410.0,280.0,420.0,510.0,430.0,250.0,520.0][model_index]
	engine.configure({"torque_curve":[[800,torque*.45],[1800,torque*.8],[3200,torque],[4800,torque*.91],[6200,torque*.70]],
		"idle_rpm":800.0,"redline_rpm":6100.0,"limiter_rpm":6500.0,"inertia":.65,
		"gear_ratios":[3.8,2.25,1.52,1.14,.87,.69],"reverse_ratio":3.3,"final_drive":3.7,
		"driveline_efficiency":.87,"auto_shift":true,"shift_time":.22,"engine_brake_coefficient":1.3,"clutch_engage_rpm":1500.0})
	wheels.clear()
	for side in [-1.0,1.0]:
		for end in [-1.0,1.0]:
			var wheel := VehicleWheel.new()
			wheel.configure({"local_pos":Vector3(side*(float(s.width)*.5-.075),Fleet.wheel_radius(model_index)-.35+.09,end*float(s.wheelbase)*.5),
				"radius":Fleet.wheel_radius(model_index),"travel":.18,"spring_rate":mass*21.0,"damp_bump":mass*1.7,"damp_rebound":mass*2.8,
				"steerable":end>0,"driven":end>0 or model_index in [4,5,6],"brake_share":.33 if end>0 else .17,"wheel_mass":22.0,
				"mu_long":1.0,"mu_lat":.96,"pacejka_b_long":10.0,"pacejka_b_lat":7.8,"rolling_resistance":.014})
			wheels.append(wheel)
	anti_roll = [[0,2,mass*7.5],[1,3,mass*6.0]]

func _ready() -> void:
	if wheels.is_empty(): configure_model(model_index)
	super()
	var s := Fleet.spec(model_index)
	_fleet_visual = Node3D.new()
	_fleet_visual.rotation.y = PI
	_fleet_visual.position.y = -.35
	add_child(_fleet_visual)
	details = Fleet.build(_fleet_visual,model_index,Fleet.paint_for(vid.hash(),model_index),true,false)
	_brake = details.brake_material
	for i in range(wheels.size()):
		var mesh: Node3D = details.wheels[i]
		mesh.reparent(self)
		wheels[i].visual = mesh
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(float(s.width),float(s.height)*.63,float(s.length))
	collision.shape = box
	collision.position.y = float(s.height)*.32-.12
	add_child(collision)
	var cabin_shape:=CollisionShape3D.new()
	var cabin_box:=BoxShape3D.new()
	var cabin:=Fleet.cabin_bounds(model_index)
	cabin_box.size=cabin.size
	cabin_shape.shape=cabin_box
	cabin_shape.position=Vector3(-cabin.get_center().x,cabin.get_center().y-.35,-cabin.get_center().z)
	add_child(cabin_shape)
	var seated:Dictionary=Fleet.driver_model(model_index,MonkeyRig.PLAYER_HEIGHT)
	for key in seated.report.targets:
		var target:Vector3=seated.report.targets[key]
		add_rider_target(self,StringName(key),Vector3(-target.x,target.y-.35,-target.z))
	add_exhaust(Vector3(-float(s.width)*.3,-.10,-float(s.length)*.49),Vector3(0,0,-1),VehicleExhaust.Profile.JEEP)

func mount_verb() -> String: return "DRIVE"
func _update_extra_visuals(_dt: float) -> void:
	if _brake: _brake.emission_energy_multiplier = 2.8 if input_brake>.1 else .35
