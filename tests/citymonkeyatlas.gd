extends Node
## Development-only capture; runtime loads the resulting canonical-model atlas.
const Models = preload("res://scripts/city_monkey_models.gd")
const OUTPUT := "res://assets/generated/city_monkey_walk.png"
const TILE := 96

func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Canonical atlas requires a native renderer")
		get_tree().quit(1)
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(TILE,TILE)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0,0,0,0)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = .75
	viewport.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50,-25,0)
	light.light_energy = .65
	viewport.add_child(light)
	var model := MeshInstance3D.new()
	viewport.add_child(model)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.4
	camera.near = .01
	viewport.add_child(camera)
	camera.make_current()
	var atlas := Image.create(TILE*8,TILE*12,false,Image.FORMAT_RGBA8)
	for frame in range(4):
		model.mesh = Models.pose("walk",0,frame)
		for elevation in range(3):
			var pitch := deg_to_rad([10.0,45.0,75.0][elevation])
			for direction in range(8):
				var angle := float(direction)*TAU/8.0
				var center := Vector3(0,.90,0)
				camera.position = center+Vector3(sin(angle)*cos(pitch),sin(pitch),cos(angle)*cos(pitch))*5.0
				camera.look_at(center)
				await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var tile := viewport.get_texture().get_image()
				atlas.blit_rect(tile,Rect2i(0,0,TILE,TILE),Vector2i(direction*TILE,(frame*3+elevation)*TILE))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT.get_base_dir()))
	var result := atlas.save_png(OUTPUT)
	var provenance := {"source":"res://scripts/monkey_rig.gd","source_sha256":FileAccess.get_sha256("res://scripts/monkey_rig.gd"),"pose_sha256":FileAccess.get_sha256("res://scripts/city_monkey_models.gd"),"standing_height":Models.BASE_HEIGHT,"directions":8,"elevations":[10,45,75],"frames":4,"tile_pixels":TILE,"model_report":Models.report("walk"),"atlas_sha256":FileAccess.get_sha256(OUTPUT)}
	var file := FileAccess.open(OUTPUT.get_basename()+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(provenance,"\t"))
	file.close()
	print("CITY_MONKEY_ATLAS result="+str(result)+" "+JSON.stringify(provenance))
	viewport.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if result==OK else 1)
