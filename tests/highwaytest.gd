extends Node3D
const Plan=preload("res://scripts/highway_plan.gd")
const RoadWorld=preload("res://scripts/highway_world.gd")
const Terrain=preload("res://scripts/city_terrain.gd")
const Car=preload("res://scripts/city_car.gd")
var checks:=0
var passed:=0
func check(ok:bool,label:String)->void:
	checks+=1
	if ok:passed+=1
	else:push_error("HIGHWAY FAIL "+label)
func frames(count:int)->void:
	for i in range(count):await get_tree().physics_frame
func run()->void:
	var roads:=Plan.roads()
	check(roads.size()==22,"beltway, expressway, four access streets and sixteen directional ramps")
	check(Plan.access_points().size()==5,"all four city sides and settlement access recorded")
	var max_grade:=0.0
	var ring:PackedVector3Array=roads[0].points
	check(ring[0].is_equal_approx(ring[-1]),"beltway is a physically closed loop")
	var ramps:=0
	var ramp_endpoints:=true
	for road in roads:
		var points:PackedVector3Array=road.points
		for i in range(points.size()-1):
			var horizontal:=Vector2(points[i+1].x-points[i].x,points[i+1].z-points[i].z).length()
			max_grade=maxf(max_grade,absf(points[i+1].y-points[i].y)/maxf(horizontal,.001))
		if road.kind=="ramp":
			ramps+=1
			var endpoints: Array=[points[0].y,points[-1].y]
			endpoints.sort()
			ramp_endpoints=ramp_endpoints and absf(endpoints[0]-Plan.City.GROUND_Y-.06)<.01 and absf(endpoints[1]-Plan.DECK_Y)<.01
	check(ramps==16 and ramp_endpoints,"each ramp joins the mainline and surface distributor at exact elevation")
	check(max_grade<.07,"all road and ramp grades stay below seven percent")
	var right_sample:=Plan.road_sample(Vector3(Plan.WEST-Plan.OUTER_LANE,Plan.DECK_Y,1800))
	var left_sample:=Plan.road_sample(Vector3(Plan.WEST+Plan.OUTER_LANE,Plan.DECK_Y,1800))
	check(right_sample.on_road and left_sample.on_road and right_sample.direction.dot(left_sample.direction)<-.99,"opposing carriageways have opposite legal directions")
	check(left_sample.direction.dot(Vector2.UP)>.99 and right_sample.direction.dot(Vector2.DOWN)>.99,"northbound uses the east carriageway and southbound uses the west carriageway")
	check(absf(Plan.posted_speed(Vector3(5000,Plan.access_ground(5000)+10.06,Plan.OUTER_LANE))-65*.44704)<.001,"expressway posted speed resolves in m/s")
	check(Plan.posted_speed(Vector3(0,200,0))==0,"no speed rule falsely applied outside network")
	check(Plan.nearest_access(Vector3(Plan.WEST,Plan.DECK_Y,0)).id=="1","Westgate access navigation")
	check(Plan.route_guidance(Vector3(Plan.WEST-Plan.OUTER_LANE,Plan.DECK_Y,1800)).contains("55 MPH"),"route guidance includes actual road limit")
	check(absf(Terrain.grade(Vector2(Plan.WEST,0),300)-Plan.City.GROUND_Y)<.001,"terrain cannot obstruct the physical underpass")
	var world:=RoadWorld.new()
	add_child(world)
	world.configure(self)
	await frames(3)
	check(world.deck_count>20 and world.collision_triangles>1000 and world.sign_count>30,"complete physical deck, barriers and signs instantiated")
	var space:=get_world_3d().direct_space_state
	var upper_query:=PhysicsRayQueryParameters3D.create(Vector3(Plan.WEST+Plan.OUTER_LANE,40,0),Vector3(Plan.WEST+Plan.OUTER_LANE,0,0),1)
	var upper:=space.intersect_ray(upper_query)
	check(not upper.is_empty() and absf(upper.position.y-Plan.DECK_Y)<.04,"ray hits actual overpass deck")
	var lower_query:=PhysicsRayQueryParameters3D.create(Vector3(Plan.WEST,Plan.DECK_Y-2,0),Vector3(Plan.WEST,0,0),1)
	var lower:=space.intersect_ray(lower_query)
	check(not lower.is_empty() and absf(lower.position.y-Plan.City.GROUND_Y-.06)<.04,"independent surface-road collider below overpass")
	var actual_support:=true
	for road in roads:
		if road.kind!="ramp":continue
		var points:PackedVector3Array=road.points
		for i in [1,points.size()/2,points.size()-2]:
			var point:Vector3=points[i]
			var query:=PhysicsRayQueryParameters3D.create(point+Vector3.UP*.5,point-Vector3.UP*.5,1)
			var hit:=space.intersect_ray(query)
			actual_support=actual_support and not hit.is_empty() and absf(hit.position.y-point.y)<.04
	check(actual_support,"actual collision supports the beginning middle and end of every ramp")
	# An ordinary player car accelerates on the physical elevated deck. Its
	# analytic fallback is lower, so loaded tires prove collision integration.
	var car:=Car.new()
	car.configure_model(1)
	car.vid="highway-test-car"
	car.position=Vector3(4500,Plan.access_ground(4500)+10.7,Plan.OUTER_LANE)
	car.rotation.y=PI*.5
	add_child(car)
	var driver:=Node3D.new()
	add_child(driver)
	await frames(150)
	var contacts:=0
	for wheel in car.wheels:
		if wheel.compression>.005 and wheel.compression<wheel.travel*.99:contacts+=1
	check(contacts==4 and car.position.y>Plan.access_ground(car.position.x)+10,"all four tires rest on the elevated highway")
	car.begin_drive(driver)
	car.set_inputs(1,0,0,false,false)
	await frames(240)
	check(car.position.x>4510 and car.speed()>5 and car.global_basis.y.dot(Vector3.UP)>.95,"unmodified drivetrain drives east on actual highway surface")
	car.set_inputs(0,1,0,false,false)
	var stopped:=false
	for i in range(300):
		await frames(1)
		if car.speed()<.5:
			stopped=true
			car.set_inputs(0,0,0,true,false)
	check(stopped and car.speed()<1.0 and car.position.y>Plan.access_ground(car.position.x)+10,"ordinary braking stays supported without falling through road")
	car.driver=null
	car.queue_free()
	driver.queue_free()
	print("HIGHWAYTEST grade=",max_grade," geometry=",world.stats())
	if DisplayServer.get_name()!="headless":
		await _capture(world)
	world.queue_free()
	await frames(3)
	print("HIGHWAYTEST result=%d/%d %s"%[passed,checks,"PASS" if passed==checks else "FAIL"])
	get_tree().quit(0 if passed==checks else 1)

func _capture(world:Node3D)->void:
	var sun:=DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-48,-30,0)
	sun.light_energy=1.7
	add_child(sun)
	var environment:=WorldEnvironment.new()
	var sky:=Environment.new()
	sky.background_mode=Environment.BG_COLOR
	sky.background_color=Color("819fa9")
	sky.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	sky.ambient_light_color=Color("bfced1")
	sky.ambient_light_energy=.7
	environment.environment=sky
	add_child(environment)
	var ground:=MeshInstance3D.new()
	var plane:=PlaneMesh.new()
	plane.size=Vector2(4000,4000)
	ground.mesh=plane
	ground.position=Vector3(Plan.WEST,Plan.City.GROUND_Y-.1,0)
	var mat:=StandardMaterial3D.new()
	mat.albedo_color=Color("68805b")
	ground.material_override=mat
	add_child(ground)
	var camera:=Camera3D.new()
	camera.far=20000
	camera.position=Vector3(Plan.WEST-820,900,-900)
	add_child(camera)
	camera.look_at(Vector3(Plan.WEST,Plan.DECK_Y,0))
	camera.current=true
	await frames(30)
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://artifacts/highways")
	get_viewport().get_texture().get_image().save_png("res://artifacts/highways/westgate-interchange.png")
	camera.position=Vector3(Plan.WEST+Plan.OUTER_LANE,Plan.DECK_Y+2.0,950)
	camera.look_at(camera.position+Vector3(0,-.035,-80))
	await frames(10)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://artifacts/highways/driver-view.png")
	for node in [camera,ground,sun,environment]:node.queue_free()
