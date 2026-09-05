extends SceneTree
## Disposable native evidence: human stature, actual garden pose and driver anchors.
var main: Node
var folder:="res://artifacts/menu-redesign/npc-workers"
var failed:=false

func _initialize() -> void:
	ProjectSettings.set_setting("application/config/use_custom_user_dir",true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name","TROOP-npc-capture-"+Crypto.new().generate_random_bytes(6).hex_encode())
	create_timer(60).timeout.connect(func():push_error("WORKER_CAPTURE deadline");quit(2))
	call_deferred("_run")

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	root.size=Vector2i(1600,900)
	root.content_scale_size=Vector2i(1600,900)
	main=load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main._start_frontier("Six-foot player",false)
	var controller:Node=main.frontier_controller
	controller.persistence_enabled=false
	controller.save_path=""
	controller.simulation_enabled=false
	main.hud.visible=false
	controller._layer.visible=false
	main.world.set_time_of_day_override(10.0)
	var player:Node3D=main.world.local_player
	player.test_mode=true
	player.set_physics_process(false)
	player.set_process(false)
	var actor:Node3D=controller.earth_settlement.citizens.mango
	var worker:Dictionary=controller.simulation.state.citizens.mango
	var plot:Dictionary={}
	for candidate:Dictionary in controller.simulation.state.plots.values():
		if candidate.planet=="earth" and str(candidate.get("crop",""))=="": plot=candidate;break
	worker.position=[float(plot.position[0]),float(plot.position[1])+2.5]
	worker.destination=worker.position.duplicate()
	worker.target=""
	worker._job={"op":"plant","label":"Planting the nursery","payload":{"plot":plot.id}}
	worker.activity="Waiting for supplies"
	worker.work_remaining=100.0
	worker.route=[]
	actor._initialized=false
	actor.update_citizen(0,Vector3.INF)
	var point:Vector3=actor.global_position
	player.global_position=controller.earth_site.surface_point(worker.position[0]+1.8,worker.position[1])
	player.rig.visible=true
	player.rig.set_yaw(0.0)
	var camera:=Camera3D.new()
	main.world.add_child(camera)
	camera.fov=55
	camera.global_position=point+Vector3(0.7,2.0,-6.0)
	camera.look_at(point+Vector3(0.7,0.85,0))
	camera.current=true
	for frame in range(90):
		player.rig.set_melee_pose(false,false,0.0,0)
		player.rig.update_motion(1.0/60.0,0,Vector3.ZERO,true,Vector3.ZERO)
		await process_frame
	await capture("player-and-grower-standing")
	worker.activity="Planting the nursery"
	for frame in range(100):
		player.rig.set_melee_pose(false,false,0.0,0)
		player.rig.update_motion(1.0/60.0,0,Vector3.ZERO,true,Vector3.ZERO)
		await process_frame
	await capture("planting-with-trowel")
	var metrics:Dictionary={"player_height":player.rig.standing_height,"grower_height":actor.rig.standing_height,"planting_pose":actor._pose_kind,"tool_visible":actor._work_tool.visible,"grower_feet":[str(actor.rig.foot_l.global_position),str(actor.rig.foot_r.global_position)]}
	worker._job={"op":"water","label":"Watering plants","payload":{"plot":plot.id}}
	worker.activity="Watering plants"
	for frame in range(90): await process_frame
	await capture("watering-with-can")
	metrics["watering_can"]=actor._watering_can.visible
	camera.global_position=point+Vector3(3.2,2.4,5.0)
	camera.look_at(player.global_position+Vector3(0,0.95,0))
	for frame in range(20): await process_frame
	await capture("player-worn-field-pack")
	var driver:Node3D=controller.earth_settlement.citizens.diesel
	var car:Node3D=driver._vehicle
	if is_instance_valid(car):
		camera.global_position=car.global_position+car.global_basis*Vector3(3.0,2.0,3.3)
		camera.look_at(car.global_position+Vector3(0,1.0,0))
		for frame in range(30): await process_frame
		await capture("driver-at-actual-controls")
		metrics["driver_pose"]=driver._pose_kind
		metrics["driver_collider_disabled"]=driver._body_shape.disabled
		metrics["left_hand_to_control"]=driver.rig.paw_l.global_position.distance_to(car.rider_render_pose().rider_target_global(&"hand_left"))
		metrics["right_hand_to_control"]=driver.rig.paw_r.global_position.distance_to(car.rider_render_pose().rider_target_global(&"hand_right"))
		failed=failed or metrics.left_hand_to_control>0.15 or metrics.right_hand_to_control>0.15
	else: failed=true
	failed=failed or absf(player.rig.standing_height-1.8288)>0.0001 or not metrics.tool_visible or not metrics.watering_can
	FileAccess.open(folder+"/metrics.json",FileAccess.WRITE).store_string(JSON.stringify(metrics,"  "))
	print("WORKER_CAPTURE ",JSON.stringify(metrics)," ","FAIL" if failed else "PASS")
	main._return_to_main_menu()
	for frame in range(5):await process_frame
	main.queue_free()
	for frame in range(3):await process_frame
	quit(1 if failed else 0)

func capture(stem:String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(folder+"/"+stem+".png")
