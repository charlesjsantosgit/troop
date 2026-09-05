extends Node
const Effects = preload("res://scripts/vehicle_impact_effects.gd")
var passed := 0
var checks := 0
var _camera: Camera3D
var _capture_enabled := false

class CrashMachine extends Vehicle:
	func _ready() -> void:
		mass = 1500
		gravity_scale = 0
		super()
		var collider := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(1.8,1.2,4.4)
		collider.shape = box
		add_child(collider)
		var visual := Node3D.new()
		visual.position.y = -.60
		add_child(visual)
		preload("res://scripts/city_vehicle_models.gd").build(visual,1,Color("934049"),true,true)
	func _simulate(_dt: float) -> void: pass
	func _apply_parked_hold(_dt: float) -> void: pass
	func _try_sleep_parked() -> void: pass

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("VEHICLEIMPACT "+("PASS " if ok else "FAIL ")+label)

func run(capture := false) -> void:
	_capture_enabled = capture
	if capture:
		var environment := WorldEnvironment.new()
		environment.environment = Environment.new()
		environment.environment.background_mode = Environment.BG_COLOR
		environment.environment.background_color = Color("819bb2")
		environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.environment.ambient_light_energy = .65
		add_child(environment)
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-42,-25,0)
		sun.light_energy = 1.2
		add_child(sun)
		_camera = Camera3D.new()
		_camera.fov = 55
		add_child(_camera)
		_camera.make_current()
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30,30,1)
	shape.shape = box
	wall.add_child(shape)
	var face := MeshInstance3D.new()
	var face_mesh := BoxMesh.new()
	face_mesh.size = box.size
	face.mesh = face_mesh
	var concrete := StandardMaterial3D.new()
	concrete.albedo_color = Color("69757e")
	concrete.roughness = .95
	face.material_override = concrete
	wall.add_child(face)
	wall.position = Vector3(0,1000,-8)
	add_child(wall)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(400,.2,100)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	var pavement := MeshInstance3D.new()
	var paving := BoxMesh.new()
	paving.size = floor_box.size
	pavement.mesh = paving
	var asphalt := StandardMaterial3D.new()
	asphalt.albedo_color = Color("353c43")
	pavement.material_override = asphalt
	floor_body.add_child(pavement)
	floor_body.position = Vector3(80,999.2,-15)
	add_child(floor_body)
	var car := CrashMachine.new()
	car.position = Vector3(0,1000,0)
	add_child(car)
	car.linear_velocity = Vector3(0,0,-36)
	car._prev_velocity = car.linear_velocity
	var ticks := Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = 240
	for frame in range(200): await get_tree().physics_frame
	var report := car.crash_report()
	check(report.collisions>=1 and report.last.closing_speed>25,"real rigid-body wall contact measures normal closing speed")
	check(report.wrecked and report.power==0 and not car.can_enter(null),"severe chassis impact disables propulsion and boarding")
	check(car.position.z>-8 and car.linear_velocity.length()<10,"actual collision prevents tunneling and dissipates incoming motion")
	check(report.deformed_meshes>=1,"contact locally dents an independent vehicle mesh")
	if capture: await _capture(car.global_position,"vehicle-wall-impact")
	var effects := get_node_or_null("VehicleImpactEffects") as VehicleImpactEffects
	check(is_instance_valid(effects) and effects.stats().fragments==24 and effects.stats().smoke_puffs==20,"actual crash creates bounded debris and smoke")
	var count: int = report.collisions
	car.report_collision_impact(Vector3.INF,Vector3.UP,50)
	car.report_collision_impact(car.position,Vector3.ZERO,50)
	car.report_collision_impact(car.position,Vector3.UP,NAN)
	check(car.collision_count==count,"invalid collision inputs cannot damage the vehicle")
	var rolling := CrashMachine.new()
	rolling.position = Vector3(80,1000,0)
	add_child(rolling)
	rolling.set_physics_process(false)
	rolling._prev_velocity = Vector3(0,0,50)
	rolling.linear_velocity = Vector3.ZERO
	rolling._detect_impacts()
	check(rolling.collision_count==0 and rolling.crash_damage==0,"hard commanded braking without a physical contact never creates a crash")
	rolling._impact_cooldown = -1
	rolling.report_collision_impact(rolling.position,Vector3.LEFT,8)
	check(rolling.crash_damage>0 and not rolling.wrecked and rolling.drive_power_factor()>0,"moderate impact leaves a damaged but drivable machine")
	var before := rolling.collision_count
	rolling.report_collision_impact(rolling.position,Vector3.LEFT,8)
	check(rolling.collision_count==before,"a persistent contact does not spam repeated impact events")
	var jet := FighterJet.new()
	jet.position = Vector3(160,1000,0)
	jet.freeze = true
	add_child(jet)
	jet.set_physics_process(false)
	var physical_shapes := jet.find_children("*","CollisionShape3D",true,false).size()
	var pilot := MonkeyRig.new()
	pilot.setup("Crash pilot",false)
	add_child(pilot)
	pilot.global_position = jet.global_position+jet.rider_root_offset
	var pilot_meshes: Array = pilot.find_children("*","MeshInstance3D",true,false).map(func(mesh):return mesh.mesh.get_instance_id())
	jet.linear_velocity = Vector3(0,0,120)
	jet.report_collision_impact(jet.position+Vector3(0,0,7.2),Vector3.BACK* -1,120)
	check(jet.wrecked and jet.drive_power_factor()==0 and jet.linear_velocity.z<5,"continuous aircraft impact destroys propulsion and removes incoming wall speed")
	jet.throttle_setpoint = 1
	jet.afterburner = true
	jet._simulate(.016)
	check(jet.throttle_setpoint==0 and not jet.afterburner,"crashed turbine cannot restore thrust or afterburner")
	check(jet.crash_report().deformed_meshes>0,"actual aircraft fuselage geometry deforms at the impact")
	await _aircraft_breakup(jet,pilot,pilot_meshes,physical_shapes)
	for i in range(20): effects.impact(Vector3(i,1000,0),Vector3.UP,45,Vector3.ZERO,car.get_rid())
	check(effects.stats().active_bursts==Effects.MAX_BURSTS and effects.stats().draw_batches<=16,"repeated crashes remain inside the shared effect and draw budgets")
	for i in range(90): effects._process(.1)
	check(effects.stats().active_bursts==0,"debris and smoke expire completely after their bounded lifetime")
	car.queue_free();rolling.queue_free();jet.queue_free();pilot.queue_free();wall.queue_free();floor_body.queue_free();effects.queue_free()
	var aircraft_effects := get_node_or_null("AircraftBreakupEffects")
	if aircraft_effects: aircraft_effects.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	Engine.physics_ticks_per_second = ticks
	print("VEHICLEIMPACTTEST result=%d/%d %s"%[passed,checks,"PASS" if passed==checks else "FAIL"])
	call_deferred("_finish")


func _finish() -> void:
	# Release the capture coroutine's local mesh/effect references before exit.
	get_tree().quit(0 if passed==checks else 1)


func _aircraft_breakup(jet:FighterJet,pilot:MonkeyRig,pilot_meshes:Array,physical_shapes:int)->void:
	var effects := get_node_or_null("AircraftBreakupEffects") as AircraftBreakupEffects
	check(is_instance_valid(effects) and jet._breakup_started,"severe real-aircraft crash creates the aircraft-specific explosion")
	if not is_instance_valid(effects):return
	effects.set_process(false)
	var report:Dictionary=jet.crash_report().breakup_geometry
	check(report.source_meshes>40 and report.source_triangles>1000 and report.copied_triangles==report.source_triangles,
		"breakup preserves every eligible actual aircraft triangle and its material")
	check(report.chunk_names.has("left_wing") and report.chunk_names.has("right_wing") and report.chunk_names.has("nose") and report.chunk_names.has("tail") and report.chunks>=5,
		"separate real wings, nose and tail chunks replace the intact aircraft")
	check(not jet._detail_body.visible and not jet._far_silhouette.visible and is_instance_valid(jet.get_node_or_null("BrokenFuselageRemnant")),
		"intact detail and distant aircraft are hidden while a burned center remains")
	jet._update_distance_lod(FighterJet.DETAIL_LOD_DISTANCE+100)
	check(not jet._detail_body.visible and not jet._far_silhouette.visible,"changing distance cannot resurrect an intact exploded plane")
	check(jet.find_children("*","CollisionShape3D",true,false).size()==physical_shapes and jet.get_collision_layer()==1,
		"aircraft breakup preserves the authoritative rigid-body collider")
	check(pilot.visible and pilot.find_children("*","MeshInstance3D",true,false).map(func(mesh):return mesh.mesh.get_instance_id())==pilot_meshes and pilot.stature_frame.scale.is_equal_approx(Vector3.ONE*MonkeyRig.PLAYER_SCALE),
		"the full-size canonical pilot keeps every original mesh and its exact scale")
	var total:=effects.total_breakups
	jet._impact_cooldown=-100
	jet.report_collision_impact(jet.global_position,Vector3.UP,100)
	check(effects.total_breakups==total,"further severe contacts cannot explode the same wreck twice")
	for frame in range(12):effects._process(.025)
	var burst:Dictionary=effects._bursts[0]
	var spread:=0.0
	for piece:Dictionary in burst.chunks:spread=maxf(spread,piece.node.position.distance_to(piece.start))
	check(spread>1.0 and burst.fire.visible and burst.flash.light_energy>0.1,"separated real chunks move outward inside the initial lit fireball")
	print("AIRCRAFT_BREAKUP_REPORT ",JSON.stringify(report)," budget=",JSON.stringify(effects.stats()))
	if _capture_enabled:await _capture_aircraft(jet.global_position+Vector3.UP,"aircraft-breakup-fireball")
	for frame in range(48):effects._process(.1)
	check(not burst.fire.visible and burst.smoke.visible and float(burst.age)>4.5,"short flame phase transitions to persistent rising smoke")
	if _capture_enabled:await _capture_aircraft(jet.global_position+Vector3.UP*2.0,"aircraft-breakup-smoke")
	var other_jets:Array[FighterJet]=[]
	for index in range(4):
		var other:=FighterJet.new()
		other.position=Vector3(210+index*25,1000,0)
		other.freeze=true
		add_child(other)
		other.set_physics_process(false)
		other.report_collision_impact(other.position,Vector3.UP,90)
		other_jets.append(other)
	check(effects.stats().active_bursts==AircraftBreakupEffects.MAX_BURSTS and effects.stats().chunks<=AircraftBreakupEffects.MAX_CHUNKS*AircraftBreakupEffects.MAX_BURSTS and effects.stats().draw_batches<=192,
		"multiple aircraft explosions share bounded chunk, particle and draw budgets")
	for frame in range(125):effects._process(.1)
	check(effects.stats().active_bursts==0 and effects.stats().fire_puffs==0 and effects.stats().smoke_puffs==0,"aircraft chunks, lights, fire and smoke expire after twelve seconds")
	for other in other_jets:other.queue_free()
	for frame in range(3):await get_tree().process_frame
	check(effects.get_child_count()==0,"expired and evicted explosion nodes actually leave the scene tree")


func _capture_aircraft(point:Vector3,label:String)->void:
	_camera.position=point+Vector3(15,8,22)
	_camera.look_at(point)
	for frame in range(3):await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path:="res://artifacts/city-traffic/"+label+".png"
	check(get_viewport().get_texture().get_image().save_png(path)==OK,"native aircraft explosion capture "+label)


func _capture(point: Vector3, label: String) -> void:
	_camera.position = point+Vector3(9,4,11)
	_camera.look_at(point)
	for frame in range(3): await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "res://artifacts/city-traffic/"+label+".png"
	var result := get_viewport().get_texture().get_image().save_png(path)
	check(result==OK,"native impact capture "+label)
