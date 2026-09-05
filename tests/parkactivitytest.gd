extends Node
const Plan=preload("res://scripts/city_plan.gd")
const Layout=preload("res://scripts/city_park_layout.gd")
const Models=preload("res://scripts/city_monkey_models.gd")
const Rowboat=preload("res://scripts/park_rowboat.gd")
const OUTPUT="res://artifacts/central-park"
var checks:=0
var failures:=0
var report:Dictionary={}
var native_metrics:Dictionary={}

func check(ok:bool,label:String)->void:
	checks+=1
	if not ok: failures+=1
	print("PARKACTIVITY %s %s"%["PASS" if ok else "FAIL",label])

func run(main:Node,capture:=false)->void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var city:Node=main.frontier_controller.city
	var player:MonkeyPlayer=main.world.local_player
	player.test_mode=true
	var park:Node3D=main.world.get_node_or_null("LanternCentralPark")
	check(is_instance_valid(park),"persistent park is installed in the real career scene")
	if not is_instance_valid(park): _finish();return
	var deadline:=Time.get_ticks_msec()+30000
	while not park.is_build_complete() and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	check(park.is_build_complete(),"staged landscape, activities and all four boats finish building")
	if not park.is_build_complete(): _finish();return
	var stats:Dictionary=park.stats()
	check(Plan.PARK_HALF_EXTENTS.x*Plan.PARK_HALF_EXTENTS.y*4>3000000,"park covers more than three square kilometres")
	var area:=0.0
	var shore_correct:=true
	for i in range(256):
		var a:=Plan.pond_shore(float(i)*TAU/256)-Plan.POND_CENTER
		var b:=Plan.pond_shore(float(i+1)*TAU/256)-Plan.POND_CENTER
		area+=a.cross(b)*.5
		shore_correct=shore_correct and absf(Plan.GROUND_Y-Plan.pond_depth(Plan.POND_CENTER+a)-Plan.POND_SURFACE_Y)<.003
	check(absf(area)>140000,"natural lake has over fourteen hectares of actual water")
	check(shore_correct,"natural shoreline meets the same physical basin at the water elevation")
	var safe_paths:=true
	var routes:Array=Layout.walking_paths_world().duplicate();routes.append(Layout.cycle_path_world())
	for route:PackedVector2Array in routes:
		for point in route:
			safe_paths=safe_paths and Plan.is_park(point) and Plan.pond_depth(point)<.005
	check(safe_paths,"walking and cycling routes remain inside the park and outside lake water")
	check(Layout.route_length(Layout.cycle_path_world())>6000,"separate cycle loop gives riders a substantial continuous route")
	check(int(stats.trees)>1000 and int(stats.trees)<4000,"batched woodland has a bounded substantial tree population")
	check(int(stats.ground_vertices)<30000 and int(stats.water_vertices)<300,"persistent park ground and lake geometry are bounded")
	check(park.find_children("LanternLakeWater","MeshInstance3D",true,false).size()==1,"one natural lake mesh replaces duplicated per-block ponds")
	var path_mesh:Mesh=park.get_node("WindingWalksAndCycleway").mesh
	var path_arrays:Array=path_mesh.surface_get_arrays(0)
	var vertices:PackedVector3Array=path_arrays[Mesh.ARRAY_VERTEX]
	var indices:PackedInt32Array=path_arrays[Mesh.ARRAY_INDEX]
	var paths_face_up:=true
	for i in range(0,indices.size(),3):
		var a:Vector3=vertices[indices[i]];var b:Vector3=vertices[indices[i+1]];var c:Vector3=vertices[indices[i+2]]
		paths_face_up=paths_face_up and (b-a).cross(c-a).y<0
	check(paths_face_up,"every walking and cycling ribbon triangle faces the overhead player camera")
	var activity:Node=park.activity
	var population:Dictionary=activity.stats()
	check(population.dogs==6 and population.yoga==18 and population.cyclists==24 and population.socializers==18,
		"dog walkers, yoga groups, cyclists and social groups are installed")
	check(int(population.prop_batches)==4,"activity props share four reusable instanced meshes")
	check(park.boats.size()==4 and park.boat is ParkRowboat,"four proper rowboats use the existing vehicle system")
	if not park.boat is ParkRowboat: _finish();return
	for definition in Layout.boat_definitions():
		var canonical:Dictionary=Gen.vehicle_definition_by_id(definition.id)
		check(not canonical.is_empty() and int(canonical.kind)==Vehicle.Kind.BOAT,"canonical vehicle authority knows "+str(definition.id))
		var floor_hit:=_floor(main,definition.exit)
		check(not floor_hit.is_empty() and absf(floor_hit.position.y-Layout.DOCK_TOP)<.015,"solid accessible landing supports "+str(definition.id))
	await _teleport(city,Layout.world(Vector2(-155,-1260))+Vector3.UP*.08)
	check(main.frontier_controller.try_interact(player),"normal E interaction reaches the dog meadow activity")
	check(activity.stats().fetch_state>0,"dog meadow E starts an actual ball chase")
	for i in range(200):
		if int(activity.stats().fetch_state)==0: break
		activity._step_fetch(.25,player)
	check(activity.stats().fetch_state==0,"fetching dog reaches the ball and returns it to the player")
	await _teleport(city,Layout.world(Vector2(-80,-910))+Vector3.UP*.08)
	activity.yoga_time=20
	check(main.frontier_controller.try_interact(player) and activity.yoga_time<1,"yoga interaction restarts the group's guided pose cycle")
	for i in range(8): await get_tree().process_frame
	check(activity.stats().monkey_instances>=18 and activity.stats().rendered_people>=18,"visible yoga participants use animated copies of the actual player monkey model")
	var canonical_models:=true
	for mm:MultiMesh in activity.batch._monkey_batches.values():
		canonical_models=canonical_models and str(mm.mesh.get_meta("canonical_model",""))=="MonkeyRig" and mm.mesh.get_surface_count()>0
	check(canonical_models and not activity.batch._monkey_batches.is_empty(),"all park person meshes are baked directly from the player MonkeyRig")
	var adult_heights:=true
	for i in range(200):
		var height:float=Models.height_for(i)
		adult_heights=adult_heights and height>=1.7018 and height<=1.8796
	check(adult_heights,"every park stature derives from the requested five-foot-seven to six-foot-two adult range")
	var boat:ParkRowboat=park.boat
	var definition:Dictionary=Layout.boat_definition(boat.vid)
	await _teleport(city,definition.exit)
	check(boat.can_enter(player),"dock boarding validates player range and the real safe exit floor")
	check(main.world._enter_vehicle_target(player,boat),"normal physical vehicle boarding accepts the rowboat")
	for i in range(3): await get_tree().physics_frame
	check(player.vehicle==boat and boat.driver==player,"player is seated through the normal vehicle camera and pose system")
	check(boat.find_children("PhysicalRowboatHull","CollisionShape3D",true,false).size()==1,"rowboat carries a real convex hull collider")
	player.ti.dir=Vector2(1,0)
	for i in range(180):await get_tree().physics_frame
	player.ti.dir=Vector2.ZERO
	check(not boat.test_move(boat.global_transform,Vector3.ZERO,null,.001,true) and Rowboat.water_safe(boat.global_position,boat.global_basis),"stationary steering keeps the rotated physical hull clear of its landing and bank")
	boat.settle_at(definition.pos,definition.yaw)
	var started:=boat.global_position
	player.ti.dir=Vector2(0,-1)
	for i in range(150): await get_tree().physics_frame
	check(boat.global_position.distance_to(started)>1.5,"held W rows the actual boat across the lake")
	check(Rowboat.water_safe(boat.global_position,boat.global_basis),"rowing keeps the complete hull in water with enough depth")
	var yaw:=boat.yaw_angle()
	player.ti.dir=Vector2(.7,-1)
	for i in range(30): await get_tree().physics_frame
	check(absf(angle_difference(yaw,boat.yaw_angle()))>.10,"steering changes the real boat heading")
	player.ti.dir=Vector2.ZERO
	check(not boat.allows_exit(),"an offshore boat cannot drop its rider into the lake")
	player.ti.interact_just=true
	for i in range(3): await get_tree().physics_frame
	check(boat.returning,"E offshore requests a safe return to the landing")
	deadline=Time.get_ticks_msec()+25000
	while not boat.at_dock() and Time.get_ticks_msec()<deadline: await get_tree().physics_frame
	check(boat.at_dock() and boat.allows_exit(),"boat returns to its own clear landing and enables safe disembarking")
	if boat.at_dock():
		player.ti.interact_just=true
		for i in range(4): await get_tree().physics_frame
		check(player.vehicle==null and player.global_position.distance_to(definition.exit)<.3,"E on the landing restores on-foot play without dropping through the dock")
	else: player.exit_vehicle()
	check(not Rowboat.water_safe(Vector3(Plan.POND_CENTER.x+Plan.POND_RADII.x*1.3,Plan.POND_SURFACE_Y,Plan.POND_CENTER.y),Basis.IDENTITY),"dry bank is rejected by the hull boundary guard")
	var collision_site:Dictionary=park._landscape.tree_sites[0]
	await _teleport(city,collision_site.position+Vector3(3,.08,0))
	for i in range(35): await get_tree().physics_frame
	check(park.stats().near_tree_colliders>0 and park.stats().near_tree_colliders<=64,"nearby trunks gain real collisions inside a bounded pool")
	if capture and DisplayServer.get_name()!="headless": await _captures(main,city,park,player)
	report=park.stats();report["native_frames"]=native_metrics;report["lake_area_m2"]=absf(area);report["checks"]=checks;report["failures"]=failures
	var native:=DisplayServer.get_name()!="headless"
	var logical_size:Vector2=main.get_viewport().get_visible_rect().size
	report["viewport_logical"]=[logical_size.x,logical_size.y]
	report["display_server"]=DisplayServer.get_name();report["adapter"]=RenderingServer.get_video_adapter_name()
	report["report_kind"]="native" if native else "headless"
	var file:=FileAccess.open(OUTPUT+("/validation-native.json" if native else "/validation-headless.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	var index:=FileAccess.open(OUTPUT+"/validation.json",FileAccess.WRITE)
	index.store_string(JSON.stringify({"native_report":"validation-native.json","headless_report":"validation-headless.json", "note":"Native capture evidence and headless checks are separate; logical viewport dimensions are not image pixel dimensions."},"\t"))
	_finish()

func _teleport(city:Node,at:Vector3)->void:
	city._teleport(at)
	var deadline:=Time.get_ticks_msec()+18000
	while city.arrival_pending() and Time.get_ticks_msec()<deadline: await get_tree().physics_frame
	for i in range(6): await get_tree().physics_frame

func _floor(main:Node,at:Vector3)->Dictionary:
	var ray:=PhysicsRayQueryParameters3D.create(at+Vector3.UP,at-Vector3.UP*2,1,[main.world.local_player.get_rid()])
	return main.world.get_world_3d().direct_space_state.intersect_ray(ray)

func _captures(main:Node,city:Node,park:Node,player:MonkeyPlayer)->void:
	main.frontier_controller.set_solar_hour(13.0)
	var layers:Array=[]
	for layer in main.find_children("*","CanvasLayer",true,false): layers.append([layer,layer.visible]);layer.visible=false
	var camera:=Camera3D.new();camera.physics_interpolation_mode=Node.PHYSICS_INTERPOLATION_MODE_OFF;camera.far=20000;main.world.add_child(camera);camera.make_current()
	var old_rig_visible:=player.rig.visible;player.rig.visible=false
	var specs:Array=[
		{"name":"central-park-aerial","at":Layout.world(Vector2(-1450,-2350),1800),"target":Layout.world(Vector2(0,0),20),"fov":68.0},
		{"name":"lake-and-boathouse","at":Layout.boathouse_position()+Vector3(22,4,-36),"target":Layout.boathouse_position()+Vector3(-20,.8,20),"fov":72.0},
		{"name":"great-lawn-yoga","at":Layout.world(Vector2(-92,-923),10.7),"target":Layout.world(Vector2(-80,-907),9.1),"fov":62.0},
		{"name":"dogs-and-walkers","at":Layout.world(Vector2(-173,-1283),11),"target":Layout.world(Vector2(-155,-1260),8.8),"fov":65.0},
		{"name":"social-terrace","at":Layout.world(Vector2(99,-641),11),"target":Layout.world(Vector2(118,-620),9),"fov":63.0}]
	for spec in specs:
		if spec.name=="dogs-and-walkers":
			var dog_state:=Layout.route_point(Layout.dog_path_world(),park.activity.time*1.05)
			var dog_point:=Vector3(dog_state.point.x,Plan.GROUND_Y,dog_state.point.y)
			var side:=Vector3(-dog_state.direction.y,0,dog_state.direction.x)
			spec.at=dog_point+side*7-Vector3(dog_state.direction.x,0,dog_state.direction.y)*6+Vector3.UP*2.5
			spec.target=dog_point+side*.6+Vector3.UP*.8
		if spec.name=="central-park-aerial":
			city._arrival=Vector3.INF
			player.admin_teleport(spec.at);player.arrival_locked=true
			main.world._reset_planet_stream_focus();city.city_world.update_focus(spec.at)
			var staging_deadline:=Time.get_ticks_msec()+90000
			while city.city_world.far_staged_block_count()<Plan.GRID_WIDTH*Plan.GRID_DEPTH and Time.get_ticks_msec()<staging_deadline:
				await get_tree().process_frame
			check(city.city_world.far_staged_block_count()==Plan.GRID_WIDTH*Plan.GRID_DEPTH,"entire municipal skyline finishes staged geometry before aerial capture")
		else:
			await _teleport(city,Vector3(spec.at.x,Gen.height(spec.at.x,spec.at.z)+.08,spec.at.z))
			player.arrival_locked=true
		camera.global_position=spec.at;camera.fov=spec.fov;camera.look_at(spec.target)
		for i in range(180): await get_tree().process_frame
		if spec.name=="great-lawn-yoga":
			var frames:Array[float]=[]
			var prior:=Time.get_ticks_usec()
			var scale_min:float=main.get_viewport().scaling_3d_scale
			var scale_max:=scale_min
			for i in range(240):
				await get_tree().process_frame
				var now:=Time.get_ticks_usec();frames.append(float(now-prior)/1000.0);prior=now
				scale_min=minf(scale_min,main.get_viewport().scaling_3d_scale);scale_max=maxf(scale_max,main.get_viewport().scaling_3d_scale)
			frames.sort();native_metrics={"samples":frames.size(),"p50_ms":frames[120],"p95_ms":frames[228],"p99_ms":frames[237],"max_ms":frames[-1]}
			native_metrics["render_scale_min"]=scale_min;native_metrics["render_scale_max"]=scale_max
		await RenderingServer.frame_post_draw
		var captured_image:=main.get_viewport().get_texture().get_image()
		if spec.name=="great-lawn-yoga":
			native_metrics["capture_pixels"]=[captured_image.get_width(),captured_image.get_height()]
			var logical:Vector2=main.get_viewport().get_visible_rect().size
			native_metrics["viewport_logical"]=[logical.x,logical.y]
			print("PARK_NATIVE_FRAMES "+JSON.stringify(native_metrics))
		check(captured_image.save_png(OUTPUT+"/"+spec.name+".png")==OK,"saved native "+str(spec.name))
		player.arrival_locked=false
	var state:=Layout.route_point(Layout.cycle_path_world(),park.activity.time*4)
	var p:=Vector3(state.point.x,Plan.GROUND_Y,state.point.y)
	await _teleport(city,p+Vector3(-9,.08,-8));player.arrival_locked=true
	camera.global_position=p+Vector3(-8,2.7,-7);camera.look_at(p+Vector3.UP)
	for i in range(15): await get_tree().process_frame
	await RenderingServer.frame_post_draw
	check(main.get_viewport().get_texture().get_image().save_png(OUTPUT+"/cycle-loop.png")==OK,"saved native cycling loop")
	player.arrival_locked=false;player.rig.visible=old_rig_visible
	var boat:ParkRowboat=park.boat;var definition:=Layout.boat_definition(boat.vid)
	await _teleport(city,definition.exit);check(main.world._enter_vehicle_target(player,boat),"native boat photo boards the actual player")
	player.ti.dir=Vector2(0,-1)
	for i in range(160): await get_tree().physics_frame
	player.ti.dir=Vector2.ZERO
	camera.global_position=boat.global_position+Vector3(6,2.6,-5);camera.look_at(boat.global_position+Vector3.UP*.9);camera.make_current()
	for i in range(12):await get_tree().process_frame
	await RenderingServer.frame_post_draw
	check(main.get_viewport().get_texture().get_image().save_png(OUTPUT+"/player-rowboat.png")==OK,"saved real player seated and rowing")
	player.exit_vehicle()
	camera.queue_free()
	for pair in layers: if is_instance_valid(pair[0]): pair[0].visible=pair[1]

func _finish()->void:
	print("PARKACTIVITYTEST %d/%d %s"%[checks-failures,checks,"PASS" if failures==0 else "FAIL"])
	get_tree().quit(0 if failures==0 else 1)
