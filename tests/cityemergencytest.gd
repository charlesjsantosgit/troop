extends Node
const Plan=preload("res://scripts/city_plan.gd")
const State=preload("res://scripts/city_incident_state.gd")
const Response=preload("res://scripts/city_emergency_response.gd")
const Massing=preload("res://scripts/city_massing.gd")
const Traffic=preload("res://scripts/city_traffic.gd")
const OUTPUT="res://artifacts/emergency-response"
var checks:=0
var failures:=0
func check(ok:bool,label:String)->void:
	checks+=1
	if not ok: failures+=1
	print("EMERGENCY %s %s"%["PASS" if ok else "FAIL",label])
func run(main:Node,capture:=false)->void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var city:Node=main.frontier_controller.city
	var player:MonkeyPlayer=main.world.local_player;player.test_mode=true
	var routes_safe:=true;var checked:=0
	for x in range(1,Plan.GRID_WIDTH-1,3):
		for y in range(1,Plan.GRID_DEPTH-1,3):
			var records:=Plan.block_buildings(Vector2i(x,y))
			if records.is_empty():continue
			var point:Vector3=records[0].position
			var route:=Response.road_route(Vector2(point.x,point.z))
			checked+=1
			routes_safe=routes_safe and not route.is_empty() and Traffic.edge_allowed(route.from,route.to)
			if route.is_empty():continue
			for t in range(21):
				var p:Vector2=route.start.lerp(route.parking,float(t)/20)
				routes_safe=routes_safe and not Plan.is_park(p) and Plan.pond_depth(p)==0
	check(routes_safe and checked>200,"response approaches across more than 200 parcels use real legal roads and avoid the entire park and lake")
	var building:=Plan.building("crownreach-b27-20-l00")
	check(not building.is_empty(),"response fixture uses an actual addressed city building")
	var route:=Response.road_route(Vector2(building.position.x,building.position.z))
	var observer:Vector2=route.parking+route.normal*5.4-route.direction*6
	city._teleport(Vector3(observer.x,Plan.GROUND_Y+.1,observer.y))
	var arrival_started:=Time.get_ticks_msec()
	var deadline:=arrival_started+90000
	while city.arrival_pending() and Time.get_ticks_msec()<deadline: await get_tree().physics_frame
	print("EMERGENCY arrival_wait_ms=%d physics_frames=%d"%[Time.get_ticks_msec()-arrival_started,city._arrival_frames])
	check(not city.arrival_pending(),"actual incident curb finishes terrain and collision streaming")
	player.admin_teleport(Vector3(observer.x,Plan.GROUND_Y+.1,observer.y));player.arrival_locked=true
	var incident:=State.record(building.id,building.position+Vector3(building.size.x*.5,12,0),Vector3.LEFT,0)
	var disasters:Node3D=main.world.city_disasters
	disasters.set_physics_process(false)
	disasters._sync_records([incident])
	check(disasters._scenes.has(building.id) and is_instance_valid(disasters._scenes[building.id].get("response")),"real disaster controller installs the response team from a canonical incident")
	if not disasters._scenes.has(building.id): _finish();return
	var stopped_car:=CharacterBody3D.new();stopped_car.name="StoppedTrafficFixture";stopped_car.collision_layer=1;stopped_car.collision_mask=1
	var car_shape:=CollisionShape3D.new();var car_box:=BoxShape3D.new();car_box.size=Vector3(2,1.5,4.2);car_shape.shape=car_box;car_shape.position.y=.9
	stopped_car.add_child(car_shape);main.world.add_child(stopped_car)
	var stopped_at:Vector2=route.start+route.direction*32
	stopped_car.global_position=Vector3(stopped_at.x,Plan.GROUND_Y,stopped_at.y)
	stopped_car.global_basis=Basis.looking_at(Vector3(route.direction.x,0,route.direction.y),Vector3.UP)
	await get_tree().physics_frame
	var entry:Dictionary=disasters._scenes[building.id]
	var response:Node3D=entry.response
	for i in range(300):
		var age:=float(i)*.1
		response.update_phase(State.phase(incident,age),State.progress(incident,age),age)
		if i%20==0: await get_tree().physics_frame
	var stats:Dictionary=response.stats()
	check(stats.blocked_moves>0 and stopped_car.global_position==Vector3(stopped_at.x,Plan.GROUND_Y,stopped_at.y),"response detects a stopped physical car and passes without moving or clipping through it")
	check(stats.arrived[0],"colliding fire engine physically follows its actual road route and reaches the curb")
	check(response._vehicles[0].find_children("*","CollisionShape3D",true,false).size()==1,"response engine has a real physical hull")
	check(stats.crew==8 and stats.crew<=stats.max_crew,"arrived fire response deploys a bounded eight-monkey crew")
	check(stats.water_streams==2 and stats.water_segments==48,"two hose operators produce bounded animated water streams")
	if DisplayServer.get_name()!="headless":
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	var first_transform:Transform3D=response._water.get_instance_transform(0)
	response.update_phase("fire",0,30.2)
	if DisplayServer.get_name()!="headless":
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	if DisplayServer.get_name()!="headless":check(not response._water.get_instance_transform(0).is_equal_approx(first_transform),"native hose stream geometry animates over time")
	if capture and DisplayServer.get_name()!="headless": await _capture(main,response,entry,incident,30,"firefighters-at-curb")
	for i in range(140):
		var age:=30.3+float(i)
		response.update_phase(State.phase(incident,age),State.progress(incident,age),age)
		if i%10==0:await get_tree().physics_frame
	stats=response.stats()
	check(stats.arrived[1],"repair van follows the same safe street approach after the fire response")
	check(stats.phase=="rebuild" and stats.tail_carriers==4 and stats.actor_batches.tail_grips==4,"rebuild phase deploys four tail-assisted material carriers")
	check(stats.actor_batches.instances>50 and stats.water_segments==0,"repair workers, tools, timber and cones replace the extinguished water jets")
	check(response.find_children("*","Light3D",true,false).is_empty(),"each incident adds no dynamic light or shadow budget")
	if capture and DisplayServer.get_name()!="headless":await _capture(main,response,entry,incident,172,"builders-tail-carry")
	var result:Dictionary=stats.duplicate(true)
	disasters._sync_records([])
	stopped_car.queue_free()
	for i in range(3):await get_tree().process_frame
	check(not is_instance_valid(response),"resolved incident frees response crews, vehicles and stream resources")
	if capture and DisplayServer.get_name()!="headless":await _capture_damage(main,disasters,city,player)
	result["checks"]=checks;result["failures"]=failures
	var file:=FileAccess.open(OUTPUT+"/validation.json",FileAccess.WRITE);file.store_string(JSON.stringify(result,"\t"))
	_finish()
func _capture(main:Node,response:Node3D,entry:Dictionary,incident:Dictionary,age:float,label:String)->void:
	var layers:Array=[]
	for layer in main.find_children("*","CanvasLayer",true,false): layers.append([layer,layer.visible]);layer.visible=false
	main.frontier_controller.set_solar_hour(13)
	entry.shell.update_incident(age);response.update_phase(State.phase(incident,age),State.progress(incident,age),age)
	var route:Dictionary=response.stats().route
	var curb:Vector2=route.parking+route.normal*5.2
	var camera:=Camera3D.new();camera.physics_interpolation_mode=Node.PHYSICS_INTERPOLATION_MODE_OFF;camera.far=15000;main.world.add_child(camera)
	var view:Vector2=curb-route.normal*10+route.direction*13
	camera.global_position=Vector3(view.x,Plan.GROUND_Y+3.4,view.y)
	camera.look_at(Vector3(curb.x,Plan.GROUND_Y+1.1,curb.y));camera.fov=64;camera.make_current()
	var player:MonkeyPlayer=main.world.local_player;var was_visible:=player.rig.visible;player.rig.visible=false
	for i in range(60):await get_tree().process_frame
	await RenderingServer.frame_post_draw
	check(main.get_viewport().get_texture().get_image().save_png(OUTPUT+"/"+label+".png")==OK,"saved native "+label)
	camera.queue_free();player.rig.visible=was_visible
	for pair in layers:if is_instance_valid(pair[0]):pair[0].visible=pair[1]
func _capture_damage(main:Node,disasters:Node3D,city:Node,player:MonkeyPlayer)->void:
	var building:=Plan.building("crownreach-b24-24-l01")
	var target_height:=clampf(float(building.size.y)*.35,18,100)
	var impact:Vector3=building.position+Vector3(0,target_height,0)
	for section in Massing.sections(building):
		var bounds:=AABB(building.position+Vector3(section.offset)-Vector3(section.size)*.5,section.size)
		if impact.y>=bounds.position.y and impact.y<=bounds.end.y:impact.x=bounds.end.x
	var incident:=State.record(building.id,impact,Vector3.LEFT,0)
	var near_camera:=impact+Vector3(27,3,7)
	city._arrival=Vector3.INF;player.admin_teleport(near_camera);player.arrival_locked=true
	main.world._reset_planet_stream_focus();city.city_world.update_focus(near_camera)
	for i in range(90):await get_tree().process_frame
	disasters._sync_records([incident])
	for i in range(3):await get_tree().physics_frame
	var entry:Dictionary=disasters._scenes[building.id]
	check(float(building.size.y)>100 and entry.shell.stats().removed_hole_cells>0,"damage capture uses a real tall property with actual aircraft-shaped missing wall cells")
	var layers:Array=[]
	for layer in main.find_children("*","CanvasLayer",true,false):layers.append([layer,layer.visible]);layer.visible=false
	var was_visible:=player.rig.visible;player.rig.visible=false
	var camera:=Camera3D.new();camera.physics_interpolation_mode=Node.PHYSICS_INTERPOLATION_MODE_OFF;camera.far=20000;main.world.add_child(camera);camera.make_current()
	main.frontier_controller.set_solar_hour(13)
	var height:float=building.size.y
	var wide:Vector3=building.position+Vector3(height*1.15,height*.96,height*.78)
	var target:Vector3=building.position+Vector3(0,height*.50,0)
	var span:=float(incident.restore)-100
	var views:Array=[
		{"label":"aircraft-shaped-wall-opening","age":1.0,"position":near_camera,"target":impact,"fov":48.0},
		{"label":"upper-building-collapse","age":8.0,"position":wide,"target":target,"fov":58.0},
		{"label":"reconstruction-scaffold-early","age":100+span*.20,"position":wide,"target":target,"fov":58.0},
		{"label":"reconstruction-scaffold-late","age":100+span*.75,"position":wide,"target":target,"fov":58.0},
		{"label":"restored-building-next-morning","age":float(incident.restore),"position":wide,"target":target,"fov":58.0}]
	for view in views:
		player.admin_teleport(view.position);player.arrival_locked=true;main.world._reset_planet_stream_focus();city.city_world.update_focus(view.position)
		if view.label=="restored-building-next-morning":
			disasters._sync_records([])
			main.frontier_controller.set_solar_hour(6.0)
		else:
			entry.shell.update_incident(view.age)
			entry.response.update_phase(State.phase(incident,view.age),State.progress(incident,view.age),view.age)
		camera.global_position=view.position;camera.look_at(view.target);camera.fov=view.fov;camera.make_current()
		for i in range(120):await get_tree().process_frame
		await RenderingServer.frame_post_draw
		check(main.get_viewport().get_texture().get_image().save_png(OUTPUT+"/"+view.label+".png")==OK,"saved native "+str(view.label))
	camera.queue_free();player.rig.visible=was_visible
	for pair in layers:if is_instance_valid(pair[0]):pair[0].visible=pair[1]

func _finish()->void:
	print("CITYEMERGENCYTEST %d/%d %s"%[checks-failures,checks,"PASS" if failures==0 else "FAIL"])
	get_tree().quit(0 if failures==0 else 1)
