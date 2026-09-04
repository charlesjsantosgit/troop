extends SceneTree
## Production flight-sky ownership and relief-height shadow regression.
var passed := 0
var total := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool,label: String) -> void:
	total+=1
	if ok: passed+=1
	print(("[PASS] " if ok else "[FAIL] ")+label)

func _run() -> void:
	root.get_node("Net").solo("SpacePhotoTester",2026)
	root.get_node("Gen").setup(2026)
	var world=load("res://scripts/world.gd").new()
	world.process_mode=Node.PROCESS_MODE_DISABLED
	root.add_child(world)
	world._environment=Environment.new()
	world._environment.background_mode=Environment.BG_SKY
	world._environment.fog_enabled=true
	world._environment.sky=Sky.new()
	var earth_sky=load("res://scripts/celestial_sky.gd").new()
	world._environment.sky.sky_material=earth_sky.get_material()
	world._sky_material=earth_sky.material
	var original_sky: Sky=world._environment.sky
	world._apply_altitude_sky(6000.0)
	check(world._environment.sky==original_sky and world._space_sky_weight==0.0,"normal mountains and aircraft retain the original Earth day/night sky")
	world._apply_altitude_sky(21000.0)
	check(world._environment.sky==world._space_sky and absf(world._space_sky_weight-0.5)<0.001,"free-flight uses the same photograph during the compact atmosphere transition")
	world._apply_altitude_sky(31000.0)
	check(world._space_sky_weight==1.0 and not world._environment.fog_enabled and float(world._photographic_space.material.get_shader_parameter("earth_visibility"))==0.0,"high free-flight has photographic vacuum without fog or a duplicate Earth disc")
	world._apply_altitude_sky(1000.0)
	check(world._environment.sky==original_sky and world._environment.fog_enabled,"descending restores the exact original Earth sky resource")
	var manager=load("res://scripts/expedition_manager.gd").new()
	manager.process_mode=Node.PROCESS_MODE_DISABLED
	world.add_child(manager)
	manager.world=world
	manager._build_worlds()
	var moon=manager.moon_world
	var backdrop=manager.rocket.voyage_visuals
	var rocket_script=load("res://scripts/lunar_rocket.gd")
	check(backdrop.photographic_background,"production expedition activates camera-owned photographic space")
	var hidden := true
	var vacuum := true
	var transition := true
	for outbound in [true,false]:
		for elapsed in ([0.0,10.0,12.0,14.0,18.0,24.0,40.0,48.0,59.0] if outbound else [0.0,8.0,20.0,26.0,32.0,39.0,40.0,44.0]):
			var duration: float=rocket_script.OUTBOUND_DURATION_SECONDS if outbound else rocket_script.RETURN_DURATION_SECONDS
			backdrop.update_voyage(float(elapsed)/duration,rocket_script.state_for_elapsed(outbound,elapsed),outbound)
			manager._update_voyage_environment(elapsed,outbound)
			hidden=hidden and not backdrop.space_shell.visible and not backdrop.vacuum_backstop.visible and not backdrop.star_field.visible and not backdrop.constellation_lines.visible and not backdrop.galaxy_visual.visible and not backdrop.sun_visual.visible
			for object in backdrop.nebulae+backdrop.planets: hidden=hidden and not object.visible
			var weight: float=manager._voyage_ease(10.0,18.0,elapsed) if outbound else 1.0-manager._voyage_ease(24.0,40.0,elapsed)
			if weight>=1.0:
				vacuum=vacuum and manager.voyage_camera.environment==moon.lunar_environment
			elif weight>0.0:
				transition=transition and manager.voyage_camera.environment==manager._voyage_environment and is_equal_approx(float(manager._voyage_sky.material.get_shader_parameter("atmosphere_strength")),1.0-weight)
			else:
				transition=transition and manager.voyage_camera.environment==null
	check(hidden,"outbound and return never cover the photograph with finite black shells or invented celestial objects")
	check(vacuum,"outbound and return vacuum share the packaged Moon photographic environment")
	check(transition,"atmospheric extinction transitions continuously to/from Earth's environment")
	var previous := 1.0
	var smooth_transition := true
	for frame in range(1,481):
		manager._update_voyage_environment(10.0+float(frame)/60.0,true)
		var amount: float=0.0 if frame==480 else manager._voyage_sky.material.get_shader_parameter("atmosphere_strength")
		smooth_transition=smooth_transition and amount<=previous+0.000001 and absf(amount-previous)<0.01
		previous=amount
	check(smooth_transition,"60 Hz ascent has no discontinuous atmospheric background step")
	check(moon._relief_texture!=null and moon._relief_texture.get_layers()==6 and moon._relief_texture.get_width()==65,"six small relief-height faces are uploaded once for bounded sunlight tracing")
	var heights_match := true
	for face in range(6):
		for coordinate in [Vector2i(0,0),Vector2i(32,16),Vector2i(64,64)]:
			var point: Vector3=moon._grid_surface_vertex(face,coordinate.x,coordinate.y)
			var stored: float=moon._relief_images[face].get_pixel(coordinate.x,coordinate.y).r
			heights_match=heights_match and absf(stored-(point-moon.PLAYABLE_CENTER).length())<0.0001
	check(heights_match,"shadow sampler heights match the actual welded collision/render vertices on all faces")
	var shadowed := 0
	var illuminated := 0
	var moved := 0
	for crater in range(8):
		var radial: Vector3=moon._crater_directions[crater]
		var tangent: Vector3=radial.cross(Vector3.FORWARD).normalized()
		var across: Vector3=tangent.cross(radial).normalized()
		var radius: float=moon._crater_radii[crater]
		var sun_a: Vector3=(tangent+radial*0.05).normalized()
		var sun_b: Vector3=(-tangent+radial*0.05).normalized()
		for x in [-0.8,-0.4,0.0,0.4,0.8]:
			for z in [-0.6,0.0,0.6]:
				var point: Vector3=moon.surface_position(radial*moon.PLAYABLE_RADIUS_METERS+tangent*x*radius+across*z*radius)
				var a: float=moon.terrain_sun_visibility(point,sun_a)
				var b: float=moon.terrain_sun_visibility(point,sun_b)
				if a<0.2: shadowed+=1
				if a>0.8: illuminated+=1
				if absf(a-b)>0.65: moved+=1
	check(shadowed>8 and illuminated>8,"low-angle sunlight produces both rim-lit ground and occluded crater interiors")
	check(moved>8,"moving the Sun to the opposite side moves terrain-cast shadows")
	var sample: Vector3=moon.surface_position(moon._crater_directions[3])
	check(moon.terrain_sun_visibility(sample,(sample-moon.PLAYABLE_CENTER).normalized())>0.99 and moon.terrain_sun_visibility(sample,-(sample-moon.PLAYABLE_CENTER).normalized())<0.01,"overhead Sun illuminates the bowl while the lunar night stays occluded")
	print("SPACEPHOTO_METRICS shadowed=%d lit=%d moving=%d"%[shadowed,illuminated,moved])
	if "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name()!="headless":
		await _capture(manager,world)
	world.queue_free()
	await process_frame
	print("SPACEPHOTOTEST %d/%d %s"%[passed,total,"PASS" if passed==total else "FAIL"])
	quit(0 if passed==total else 1)


func _capture(manager,world) -> void:
	root.size=Vector2i(1280,720)
	root.content_scale_size=Vector2i(1280,720)
	var directory := "res://artifacts/shared-societies/space"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var rocket=manager.rocket
	var moon=manager.moon_world
	for shot in [["outbound-transfer",true,28.0],["outbound-atmosphere",true,13.5],["return-transfer",false,20.0],["return-atmosphere",false,32.0]]:
		var duration: float=rocket.OUTBOUND_DURATION_SECONDS if shot[1] else rocket.RETURN_DURATION_SECONDS
		rocket.apply_authoritative_clock(rocket.state_for_elapsed(shot[1],shot[2]),shot[1],shot[2])
		manager._update_voyage_camera(0.0,shot[2]/duration,{},true)
		for frame in range(5): await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(directory+"/"+shot[0]+".png")
		print("SPACE_CAPTURE "+shot[0])
	rocket.visible=false
	rocket.voyage_visuals.visible=false
	moon.visible=true
	moon.set_cinematic_render_radius(moon.PLAYABLE_RADIUS_METERS)
	var radial: Vector3=moon._crater_directions[0]
	var tangent: Vector3=radial.cross(Vector3.FORWARD).normalized()
	var across: Vector3=tangent.cross(radial).normalized()
	var focus: Vector3=moon.surface_position(radial)
	var camera: Camera3D=manager.voyage_camera
	camera.environment=moon.lunar_environment
	camera.global_position=moon.to_global(focus+radial*70.0+across*170.0)
	camera.look_at(moon.to_global(focus),radial)
	camera.fov=64
	for direction in [1.0,-1.0]:
		moon.set_lunar_sun_direction((tangent*direction+radial*0.08).normalized())
		for frame in range(5): await process_frame
		await RenderingServer.frame_post_draw
		var label := "crater-east" if direction>0 else "crater-west"
		root.get_texture().get_image().save_png(directory+"/"+label+".png")
		print("SPACE_CAPTURE "+label)
	if "--benchmark" in OS.get_cmdline_user_args(): await _benchmark(moon)
	var ground_direction: Vector3=(radial*moon.PLAYABLE_RADIUS_METERS+across*40.0).normalized()
	camera.global_position=moon.to_global(moon.surface_position(ground_direction,2.2))
	camera.look_at(moon.to_global(focus+radial*6.0),ground_direction)
	moon.set_lunar_sun_direction((tangent+radial*0.13).normalized())
	for frame in range(5): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory+"/crater-ground.png")
	print("SPACE_CAPTURE crater-ground")
	world._apply_altitude_sky(31000.0)
	camera.environment=world._environment
	moon.visible=false
	camera.global_position=Vector3(0,31000,0)
	camera.look_at(camera.global_position+Vector3(0,0.4,-1),Vector3.UP)
	for frame in range(5): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory+"/earth-free-flight.png")
	print("SPACE_CAPTURE earth-free-flight")


func _benchmark(moon) -> void:
	var baseline_path := "res://artifacts/shared-societies/space/baseline.gdshader"
	if not FileAccess.file_exists(baseline_path):
		print("SPACE_BENCHMARK requires the git HEAD lunar shader at "+baseline_path)
		return
	var baseline := Shader.new()
	baseline.code=FileAccess.get_file_as_string(baseline_path)
	var material: ShaderMaterial=moon._horizon_material
	var current: Shader=material.shader
	var viewport := root.get_viewport_rid()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(viewport,true)
	var report := {"device":RenderingServer.get_video_adapter_name(),"resolution":[root.size.x,root.size.y],"samples_per_shader":120}
	for phase in ["baseline","terrain_rays"]:
		material.shader=baseline if phase=="baseline" else current
		for warm in range(20):
			await process_frame
			await RenderingServer.frame_post_draw
		var gpu: Array[float]=[]
		var cpu: Array[float]=[]
		var wall: Array[float]=[]
		var previous := Time.get_ticks_usec()
		for frame in range(120):
			await process_frame
			await RenderingServer.frame_post_draw
			var now := Time.get_ticks_usec()
			wall.append(float(now-previous)/1000.0)
			previous=now
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport))
			cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(viewport))
		report[phase]={"gpu":_timing(gpu),"render_cpu":_timing(cpu),"wall":_timing(wall)}
	material.shader=current
	report["gpu_timer_available"]=float(report.terrain_rays.gpu.mean_ms)>0.0
	report["measurement_note"]="Wall statistics include scheduling/compositor pacing; zero GPU timestamps mean unavailable."
	var file := FileAccess.open("res://artifacts/shared-societies/space/shadow-benchmark.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t",false,true))
	file.close()
	print("SPACE_BENCHMARK "+JSON.stringify(report))

func _timing(values: Array[float]) -> Dictionary:
	var sum := 0.0
	for value in values: sum+=value
	values.sort()
	return {"mean_ms":sum/values.size(),"p50_ms":values[int(values.size()*0.5)],"p95_ms":values[int(values.size()*0.95)],"max_ms":values[-1]}
