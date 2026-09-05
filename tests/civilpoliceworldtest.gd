extends Node
const Routes = preload("res://scripts/civil_police_routes.gd")
const PoliceWorld = preload("res://scripts/civil_police_world.gd")
const Plan = preload("res://scripts/city_plan.gd")
const Traffic = preload("res://scripts/city_traffic.gd")
var checks := 0
var failures := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("CIVILPOLICE FAIL " + label)
	else: print("CIVILPOLICE PASS " + label)

func run() -> void:
	var sites := Routes.site_positions()
	for id in ["station", "custody", "release", "community_service", "escape", "bank", "bank_security", "vault", "fence"]:
		var at := Routes.vector(sites[id])
		check(at.is_finite() and at.y >= Plan.GROUND_Y and at.x < Plan.MIN_X, id + " is above ground outside occupied parcels")
	check(Routes.edge_allowed(Vector2i(-1,24),Vector2i(0,24)) and Routes.edge_allowed(Vector2i(0,24),Vector2i(1,24)), "station road joins actual west access carriageway")
	var fixture := Plan.building("crownreach-b04-24-l00")
	var center: Vector3 = fixture.position + Vector3.UP * 1.4
	check(not Routes.line_of_sight(center - Vector3(50,0,0),center + Vector3(50,0,0)), "city building occludes police sight")
	var bank := Routes.vector(sites.bank_center)
	check(not Routes.line_of_sight(bank + Vector3(-25,1.4,0), bank + Vector3(25,1.4,0)), "credit union physical walls occlude police sight")
	check(Routes.line_of_sight(Vector3(Plan.MIN_X-60,10,0),Vector3(Plan.MIN_X+25,10,0)), "clear access street preserves sight")
	var bank_from := Vector3(Plan.MIN_X-31,Routes.SURFACE_Y,-3)
	var bank_to := Routes.vector(sites.bank_security)+Vector3(0,0,2)
	var foot := Routes.pedestrian_path(bank_from,bank_to)
	var foot_safe := not foot.is_empty()
	var last := bank_from
	for step in foot:
		var at := Routes.vector(step)
		foot_safe = foot_safe and Routes._foot_clear(last,at)
		last=at
	check(foot_safe and last.distance_to(bank_to)<.1,"officer walks through credit union entrance around solid teller counters")
	check(Routes.line_of_sight(bank+Vector3(0,1,-10),bank+Vector3(0,1,-15)),"vault has a clear emergency egress even after security is restored")
	var park_road := Routes.nearest_road(Vector3(Plan.POND_CENTER.x,Plan.GROUND_Y,Plan.POND_CENTER.y))
	check(not park_road.is_empty() and not Plan.is_park(Vector2(Routes.vector(park_road.position).x,Routes.vector(park_road.position).z)), "lake target projects to an actual perimeter road")
	var a := Vector3(Plan.MIN_X - 55,Plan.GROUND_Y,0)
	var destination := Vector3(Plan.MIN_X + Plan.BLOCK_EXTENTS.x * 2.0, Plan.GROUND_Y, 70)
	var unit := Routes.make_unit("test_patrol", a)
	var original := unit.duplicate(true)
	var safe := true
	var turns := 0
	var previous := Routes.vector(unit.position)
	var total := 0.0
	for iteration in range(4000):
		unit = Routes.advance_unit(unit,.1,destination,"respond")
		var at := Routes.vector(unit.position)
		total += at.distance_to(previous)
		safe = safe and at.distance_to(previous) <= 2.0 and not Plan.is_park(Vector2(at.x,at.z))
		safe = safe and Routes.line_of_sight(previous + Vector3.UP*.75,at + Vector3.UP*.75)
		previous = at
		if float(unit.get("_wait",0)) > 0: turns += 1
		if bool(unit.arrived): break
	check(bool(unit.arrived) and total > 200 and turns > 0, "cruiser physically reaches a different road through stopped intersections")
	check(safe, "pursuit trace is bounded continuous movement and never crosses building volume")
	check(original == Routes.make_unit("test_patrol", a), "pure route advance leaves caller input unchanged")
	check(not Routes.public_unit(unit).has("_path") and Routes.public_unit(unit).has("officer_position"), "public officer snapshot excludes authority path state")
	# Reversing near the depot uses its turning circle, not a mid-block U-turn.
	var reverse_target := Vector3(Plan.MIN_X - 55,Plan.GROUND_Y,0)
	for iteration in range(7000):
		unit = Routes.advance_unit(unit,.1,reverse_target,"respond")
		if bool(unit.arrived): break
	check(bool(unit.arrived) and Routes.vector(unit.position).distance_to(reverse_target) < 35, "cruiser routes back to the west station approach")
	var world := PoliceWorld.new()
	add_child(world)
	world.configure(self)
	check(world.stats().physical_shapes > 65 and world.get_interaction_sites().size() == 6, "civic sites contain real floor wall furniture and escape-step collision")
	world.update_snapshot({"time":10.0,"units":[Routes.public_unit(unit)],"sites":sites,"robberies":[]})
	world._physics_process(.2)
	check(world.stats().units == 1 and world.stats().active_sirens == 1, "shared pursuit snapshot creates cruiser monkey and spatial siren")
	var before: Vector3 = world._units.test_patrol.body.global_position
	world.update_snapshot({"time":9.0,"units":[],"robberies":[]})
	check(world.stats().units == 1 and world._units.test_patrol.body.global_position == before, "old snapshots cannot delete or rewind patrol units")
	unit.state = "traffic_stop"
	unit.siren = false
	unit.arrived = true
	unit.speed = 0.0
	world.update_snapshot({"time":11.0,"units":[Routes.public_unit(unit)],"robberies":[{"position":sites.bank_security,"stage":"vault_ready"}]})
	world._physics_process(.2)
	check(world.stats().officers_on_foot == 1 and world.stats().active_sirens == 0, "routine traffic stop dismounts officer and silences siren")
	check(world.stats().vault_open and world._vault_gate.position.x > 5, "shared bank security stage physically opens vault grille")
	if "--police-capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		await _capture(world,unit)
	world.update_snapshot({"time":12.0,"units":[],"robberies":[]})
	await get_tree().process_frame
	check(world.stats().units == 0 and not world.stats().vault_open, "resolved snapshots remove units and secure bank")
	world.queue_free()
	await get_tree().process_frame
	print("CIVILPOLICE result=%d/%d %s" % [checks-failures,checks,"PASS" if failures==0 else "FAIL"])
	get_tree().quit(0 if failures == 0 else 1)

func _capture(world: Node3D, unit: Dictionary) -> void:
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("93b5cc")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("c1d4e0")
	settings.ambient_light_energy = .65
	environment.environment = settings
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48,-25,0)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	add_child(sun)
	var camera := Camera3D.new()
	camera.fov = 62
	camera.far = 700
	add_child(camera)
	camera.make_current()
	var ground := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(400,400)
	ground.mesh = mesh
	ground.position = Vector3(Plan.MIN_X-38,Plan.GROUND_Y-.05,-30)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("6a7e61")
	ground.material_override = material
	add_child(ground)
	var origin := Vector3(Plan.MIN_X-38,Routes.SITE_Y,0)
	var officer := Routes.vector(unit.position)
	var poses := [
		["civic-neighborhood",origin+Vector3(-115,83,85),origin+Vector3(0,0,-25)],
		["credit-union",origin+Vector3(19,6,-13),origin+Vector3(0,1.6,-43)],
		["police-traffic-stop",officer+Vector3(8,3.8,-8),officer+Vector3(0,.9,0)],
	]
	var output := "res://artifacts/civil-police"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	for pose in poses:
		camera.global_position = pose[1]
		camera.look_at(pose[2])
		for frame in range(5): await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		image.save_png(output+"/"+pose[0]+".png")
		print("CIVILPOLICE capture "+ProjectSettings.globalize_path(output+"/"+pose[0]+".png"))
