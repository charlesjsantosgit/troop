extends SceneTree
## Native comparison of real player/NPC rigs and E interaction. Disposable career.
var main: Node
var folder := "res://artifacts/release-0.6.2/npcs"
var prefix := "before"

func _initialize() -> void:
	create_timer(60.0).timeout.connect(func():
		push_error("NPC capture timed out")
		quit(2))
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size()>0: prefix=str(args[0])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	main=load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main._start_frontier("NPC comparison player",false)
	var controller: Node=main.frontier_controller
	if not is_instance_valid(controller) or not is_instance_valid(controller.ui):
		push_error("NPC capture could not initialize the real Frontier UI")
		quit(2)
		return
	controller.simulation_enabled=false
	controller.persistence_enabled=false
	controller.save_path=""
	main.world.set_time_of_day_override(10.0)
	var player: Node3D=main.world.local_player
	player.test_mode=true
	player.set_physics_process(false)
	var nana: Node3D=controller.earth_settlement.citizens.nana
	var point: Vector3=nana.global_position
	player.global_position=controller.earth_site.surface_point(point.x+1.7,point.z)
	player.rig.visible=true
	player.rig.set_yaw(0.0)
	var camera := Camera3D.new()
	main.world.add_child(camera)
	camera.global_position=point+Vector3(0.9,2.2,-7)
	camera.look_at(point+Vector3(0.85,1.0,0))
	camera.fov=58
	camera.current=true
	print("NPC_CAPTURE_LOADED prefix=",prefix," career_persistence=",controller.persistence_enabled)
	for frame in range(150):
		player.rig.update_motion(1.0/60.0,0,Vector3.ZERO,true,Vector3.ZERO)
		await process_frame
	await _capture(prefix+"-nana-player.png")
	var metrics := {"nana_position":str(nana.global_position),"player_position":str(player.global_position),
		"nana_rig_scale":str(nana.rig.scale),"player_rig_scale":str(player.rig.scale),
		"nana_standing_height":nana.rig.standing_height,"player_standing_height":player.rig.standing_height,
		"nana_head":str(nana.rig.head_p.global_position),"player_head":str(player.rig.head_p.global_position),
		"nana_feet":[str(nana.rig.foot_l.global_position),str(nana.rig.foot_r.global_position)],
		"player_feet":[str(player.rig.foot_l.global_position),str(player.rig.foot_r.global_position)],
		"nana_label":str(nana._name_label.text),"nana_label_position":str(nana._name_label.global_position),
		"waypoint":str(controller.waypoint),"waypoint_marker_visible":controller._waypoint_marker.visible,
		"nearest_before_e":str(controller.nearest_interaction()),
		"camera":str(camera.global_transform),"tutorial":controller.tutorial.summary()}
	metrics["player_rendered_vertex_bounds"]=_rig_vertex_bounds(player.rig)
	metrics["nana_rendered_vertex_bounds"]=_rig_vertex_bounds(nana.rig)
	# The screenshot above preserves live idle poses. Measure the same real
	# rigs in upright rest afterward, using submitted vertices rather than
	# joint centers or rotated AABBs (which overstate a sphere's crown).
	player.rig.reset_pose_state()
	nana.rig.reset_pose_state()
	var player_bounds := _rig_vertex_bounds(player.rig)
	var nana_bounds := _rig_vertex_bounds(nana.rig)
	metrics["player_rest_vertex_height"]=player_bounds[1]-player_bounds[0]
	metrics["nana_rest_vertex_height"]=nana_bounds[1]-nana_bounds[0]
	# This is the real mapped E event, read by the player's normal input path.
	# No direct controller/UI opening substitutes for interaction behavior.
	player.test_mode=false
	player.set_physics_process(true)
	var key := InputEventKey.new()
	key.physical_keycode=KEY_E
	key.keycode=KEY_E
	key.pressed=true
	Input.parse_input_event(key)
	await physics_frame
	await process_frame
	key=InputEventKey.new()
	key.physical_keycode=KEY_E
	key.keycode=KEY_E
	key.pressed=false
	Input.parse_input_event(key)
	for frame in range(30): await process_frame
	player.set_physics_process(false)
	metrics["selected_after_e"]=str(controller.selected_interaction)
	metrics["selected_id_after_e"]=str(controller.selected_interaction.get("id",""))
	metrics["buttons_after_e"]=_buttons(root)
	metrics["labels_after_e"]=_labels(root)
	metrics["tutorial_after_e"]=controller.tutorial.summary()
	var failures: Array=[]
	if prefix.begins_with("after"):
		if absf(float(metrics.player_standing_height)-1.8288)>0.0001: failures.append("Player stature is not 1.8288 m")
		if float(metrics.nana_standing_height)<1.7017 or float(metrics.nana_standing_height)>1.8797: failures.append("Nana stature is outside the adult range")
		if absf(float(metrics.player_rest_vertex_height)-1.8288)>0.0001: failures.append("Player submitted mesh height is not 1.8288 m")
		if absf(float(metrics.nana_rest_vertex_height)-float(metrics.nana_standing_height))>0.0001: failures.append("Nana submitted mesh height disagrees with her stature")
		if metrics.selected_id_after_e!="nana": failures.append("Actual E did not select Nana")
		if metrics.labels_after_e.is_empty() or metrics.labels_after_e[0]!="Nana": failures.append("Resident panel heading is not Nana")
		if "My journal" in metrics.buttons_after_e: failures.append("Resident panel shows My journal")
		if int(metrics.tutorial_after_e.step)!=2: failures.append("Meet Nana did not advance")
		if bool(metrics.waypoint_marker_visible): failures.append("Duplicate nearby waypoint is visible")
	metrics["failures"]=failures
	await _capture(prefix+"-nana-e-menu.png")
	var file := FileAccess.open(folder+"/"+prefix+"-metrics.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics,"  "))
	file.close()
	print("NPC_CAPTURE_METRICS ",JSON.stringify(metrics))
	main._return_to_main_menu()
	for frame in range(5): await process_frame
	main.queue_free()
	for frame in range(3): await process_frame
	quit(0 if failures.is_empty() else 1)

func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png(folder+"/"+name)
	print("NPC_CAPTURE_IMAGE ",name," saved=",result)

func _buttons(node: Node) -> Array:
	var values: Array=[]
	if node is Button and node.is_visible_in_tree(): values.append(node.text)
	for child in node.get_children(): values.append_array(_buttons(child))
	return values

func _labels(node: Node) -> Array:
	var values: Array=[]
	if node is Label and node.is_visible_in_tree() and not node.text.is_empty(): values.append(node.text)
	for child in node.get_children(): values.append_array(_labels(child))
	return values

func _rig_vertex_bounds(rig: Node3D) -> Array:
	var sole := INF
	var crown := -INF
	for node: MeshInstance3D in rig.find_children("*","MeshInstance3D",true,false):
		if node.name!="Foot" and node.name!="HeadShell": continue
		var local := rig.global_transform.affine_inverse()*node.global_transform
		for vertex: Vector3 in node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			var y := (local*vertex).y
			if node.name=="Foot": sole=minf(sole,y)
			else: crown=maxf(crown,y)
	return [sole,crown]
