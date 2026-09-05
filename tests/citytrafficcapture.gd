extends Node
const Traffic = preload("res://scripts/city_traffic.gd")
const Catalog = preload("res://scripts/vehicle_catalog_panel.gd")
const Fleet = preload("res://scripts/city_vehicle_models.gd")
const Plan = preload("res://scripts/city_plan.gd")
const OUTPUT := "res://artifacts/city-traffic"
var _main: Node
var _camera: Camera3D
var _report: Dictionary = {"captures": [], "errors": []}

func run(main: Node) -> void:
	_main = main
	var city: Node = main.frontier_controller.city
	var player: MonkeyPlayer = main.world.local_player
	player.test_mode = true
	main.set_process_input(false)
	main.set_process_unhandled_input(false)
	main._close_pause_menu(false)
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var key := Vector2i(32,26)
	var origin := Traffic.point(key)
	var ground := Vector3(origin.x,Plan.GROUND_Y,origin.y)
	city._teleport(ground + Vector3(14.0,1.2,22.0))
	var deadline := Time.get_ticks_msec() + 30000
	while city.arrival_pending() and Time.get_ticks_msec() < deadline: await get_tree().physics_frame
	if city.arrival_pending():
		push_error("Traffic capture arrival did not settle")
		get_tree().quit(1)
		return
	player.set_physics_process(false)
	for frame in range(480): await get_tree().process_frame
	while not city.crowd.ambient.ready_city: await get_tree().process_frame
	for layer in main.find_children("*","CanvasLayer",true,false): layer.visible = false
	player.visible = false
	_camera = Camera3D.new()
	main.world.add_child(_camera)
	_camera.far = 6000
	_camera.fov = 67
	_camera.make_current()
	_set_hour(13.0)
	_camera.position = ground + Vector3(13.0,2.0,20.0)
	_camera.look_at(ground + Vector3(-2.0,4.0,-6.0))
	await _capture(city,key,"intersection-day")
	# A staged request enters an all-red clearance first. Actual in-flight cars
	# finish before WALK appears; actors keep their normal physics/rules running.
	var state: Dictionary = city.crowd.traffic.ensure(key)
	state.stage = 5
	state.elapsed = 0.0
	deadline = Time.get_ticks_msec() + 30000
	while int(state.stage) != 6 and Time.get_ticks_msec() < deadline: await get_tree().physics_frame
	_camera.position = ground + Vector3(18.0,2.1,7.4)
	_camera.look_at(ground + Vector3(6.0,2.1,7.4))
	await _capture(city,key,"protected-walk")
	deadline = Time.get_ticks_msec() + 15000
	while int(state.stage) != 7 and Time.get_ticks_msec() < deadline: await get_tree().physics_frame
	await _capture(city,key,"crossing-clearance")
	_set_hour(23.0)
	_camera.position = ground + Vector3(13.0,2.0,20.0)
	_camera.look_at(ground + Vector3(-2.0,4.0,-6.0))
	await _capture(city,key,"intersection-night")
	_set_hour(13.0)
	var gallery := Node3D.new()
	gallery.name = "FleetCaptureFixture"
	main.world.add_child(gallery)
	gallery.position = ground+Vector3(0,0,60)
	for index in range(Fleet.CATALOG.size()):
		var model := Node3D.new()
		gallery.add_child(model)
		model.position = Vector3(float(index%5)*4.5-9.0,0,float(index/5)*8.0)
		Fleet.build(model,index,Fleet.paint_for(index*7,index))
	_camera.position = gallery.position+Vector3(-17,9,-17)
	_camera.look_at(gallery.position+Vector3(0,.8,3))
	await _capture(city,key,"fleet-gallery")
	_camera.position = gallery.position+Vector3(-10.5,1.36,-3.5)
	_camera.look_at(gallery.position+Vector3(-9,1.02,0))
	await _capture(city,key,"seated-driver")
	gallery.free()
	player.set_physics_process(false)
	deadline = Time.get_ticks_msec()+180000
	while city.city_world.far_staged_block_count()<Plan.TOTAL_BLOCKS and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	_report["far_staged_blocks"] = city.city_world.far_staged_block_count()
	if city.city_world.far_staged_block_count()!=Plan.TOTAL_BLOCKS: _report.errors.append("city skyline staging incomplete")
	player.global_position = ground+Vector3(0,500,0)
	city.crowd.update_focus(player.global_position)
	_camera.position = ground+Vector3(-90,320,-100)
	_camera.look_at(ground+Vector3(0,0,180))
	await _capture(city,key,"rooftop-moving-population")
	_camera.position = ground+Vector3(-450,1800,-300)
	_camera.look_at(ground+Vector3(300,0,500))
	await _capture(city,key,"aircraft-moving-population")
	var samples: Array[float] = []
	for frame in range(180):
		var start := Time.get_ticks_usec()
		await get_tree().process_frame
		samples.append(float(Time.get_ticks_usec()-start)/1000.0)
	samples.sort()
	_report["aerial_frame_ms"] = {"p50":samples[90],"p95":samples[171],"p99":samples[178],"max":samples[-1]}
	_report["population"] = city.crowd.ambient.stats()
	var layer := CanvasLayer.new()
	layer.layer = 90
	main.add_child(layer)
	var panel := Catalog.new()
	panel.configure(main.admin_controller)
	layer.add_child(panel)
	deadline = Time.get_ticks_msec()+30000
	while panel.test_report().cached_thumbnails < 15 and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	await _capture(city,key,"vehicle-catalog")
	_report["catalog"] = panel.test_report()
	if panel.test_report().cached_thumbnails != 15: _report.errors.append("catalog thumbnails incomplete")
	panel._search.text = "boat"
	panel._filter("boat")
	await _capture(city,key,"vehicle-catalog-search")
	layer.queue_free()
	_report["signal_budget"] = city.crowd.signals.stats()
	_report["cars"] = 0
	_report["pedestrians"] = 0
	for actor in city.crowd.actors:
		_report["cars" if actor.car else "pedestrians"] += 1
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var file := FileAccess.open(OUTPUT.path_join("capture-report.json"),FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(_report,"\t")+"\n")
	print("CITYTRAFFICCAPTURE %s" % JSON.stringify(_report))
	_finish_after_cleanup.call_deferred(0 if _report.errors.is_empty() else 1)

func _finish_after_cleanup(code: int) -> void:
	for frame in range(3): await get_tree().process_frame
	get_tree().quit(code)

func _set_hour(hour: float) -> void:
	_main.frontier_controller.set_solar_hour(hour)

func _capture(city: Node, key: Vector2i, label: String) -> void:
	for frame in range(30): await get_tree().process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var path := OUTPUT.path_join(label+".png")
	var error := _main.get_viewport().get_texture().get_image().save_png(path)
	var actual: Dictionary = city.crowd.traffic.display(key)
	var rendered: Dictionary = city.crowd.signals.displayed_state(key)
	if error != OK or rendered != actual: _report.errors.append(label)
	_report.captures.append({"file":path,"state":actual,"display_matches_controller":rendered==actual,"tree_paused":get_tree().paused,"world_processing":_main.world.can_process(),"crowd_processing":city.crowd.can_process(),"simulation_updates":city.crowd.ambient.update_count})
	print("CITYTRAFFIC_CAPTURE %s %s" % [ProjectSettings.globalize_path(path),JSON.stringify(actual)])
