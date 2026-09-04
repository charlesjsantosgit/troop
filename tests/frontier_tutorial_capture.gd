extends SceneTree
## Capture the real first-day HUD in a disposable career, without opening menus
## or persisting tutorial/career progress. Run after the standard Godot import.
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var output := str(args[0]) if not args.is_empty() else \
		"res://artifacts/shared-societies/town/tutorial-hud.png"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output).get_base_dir())
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main._start_frontier("TownPreview",false)
	main.frontier_controller.simulation_enabled = false
	main.world.set_time_of_day_override(10.0)
	var player: Node3D = main.world.local_player
	player.test_mode = true
	player.set_physics_process(false)
	var gen: Node = root.get_node("Gen")
	var floor_y := float(gen.call("height",4,1))
	player.global_position = Vector3(4,floor_y,1)
	var camera := Camera3D.new()
	main.world.add_child(camera)
	camera.global_position = Vector3(4,floor_y+1.85,1)
	camera.look_at(Vector3(-7,floor_y+1.2,-17))
	camera.current = true
	camera.fov = 70
	for frame in range(210):
		await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png(output)
	print("TUTORIAL_CAPTURE path=%s saved=%d marker=%s guide=%s"%[
		output,result,str(main.frontier_controller.waypoint),str(main.frontier_controller.tutorial.summary())])
	main._return_to_main_menu()
	for frame in range(5): await process_frame
	main.queue_free()
	for frame in range(3): await process_frame
	quit(0 if result==OK else 1)
