extends Node
## Purchase and tour the actual luxury suite through the career controller.
const Plan = preload("res://scripts/city_plan.gd")
const Rooms = preload("res://scripts/city_interior.gd")
const Furniture = preload("res://scripts/city_furniture.gd")
const NetworkScript = preload("res://scripts/city_network.gd")
const Economy = preload("res://scripts/city_economy.gd")
const OUTPUT := "res://artifacts/city-penthouse"
var checks := 0
var passed := 0
var report: Dictionary = {}
var _capture_requested := false
class FurnitureNetworkFixture extends Node:
	var city: Node


func check(ok: bool, label: String) -> void:
	checks += 1
	if ok: passed += 1
	print("PENTHOUSE %s %s" % ["PASS" if ok else "FAIL", label])


func run(main: Node, capture := false) -> void:
	_capture_requested = capture
	var city: Node = main.frontier_controller.city
	var player: MonkeyPlayer = main.world.local_player
	var sim = main.frontier_controller.simulation
	player.test_mode = true
	check(not main.frontier_controller.persistence_enabled,
		"suite validation uses a fresh career without touching saved progress")
	var home := Plan.building("crownreach-b24-24-l02")
	var spec := Economy.property_spec(str(home.id))
	check(home.housing == "penthouse" and not spec.is_empty(),
		"suite belongs to a real purchasable penthouse address")
	var grant := maxi(0, int(spec.price) + 500 - sim.balance("player"))
	if grant > 0: sim._transfer("treasury", "player", grant, "Funded penthouse validation")
	city._teleport(home.door + Vector3.UP * 1.2)
	if not await _arrival(city, "penthouse building entrance"):
		_finish()
		return
	var wallet: int = sim.balance("player")
	var bought: Dictionary = city.request_action("buy_home", {"building": home.id})
	check(bought.get("ok", false) and sim.balance("player") == wallet - int(spec.price),
		"normal purchase transfers the listed penthouse price from the real wallet")
	var outdoor_environment: Environment = player.cam._cam.environment
	var outdoor_far: float = player.cam._cam.far
	city.enter_building(str(home.id))
	if not await _arrival(city, "luxury interior"):
		_finish()
		return
	var room: Node3D = city.interior
	check(city.is_inside() and is_instance_valid(room) and str(city.interior_id) == str(home.id),
		"normal controller entry visits the purchased suite")
	if not is_instance_valid(room):
		_finish()
		return
	check(room.dimensions.x >= 24.0 and room.dimensions.y >= 7.5 and room.dimensions.z >= 20.0,
		"penthouse has a broad double-height interior")
	check(room.has_method("validation_layout"), "suite exposes its physical layout and photographic viewpoints")
	if not room.has_method("validation_layout"):
		_finish()
		return
	for frame in range(35): await get_tree().physics_frame
	_check_floor(player, room, 0.0, "entry landing")
	check(is_equal_approx(main.world.void_rescue_height(player), room.global_position.y - 10.0),
		"suite uses its interior rescue floor rather than outdoor terrain height")
	check(player.cam._cam.environment == outdoor_environment,
		"rooftop suite inherits the exact live Earth camera environment")
	check(room.global_position.is_equal_approx(Vector3(home.position.x,Plan.GROUND_Y+home.size.y-8.0,home.position.z)),
		"suite occupies its actual property roof volume without scaled or lowered viewpoint")
	check(not main.world.seasonal_weather.atmosphere_enabled(),
		"outside precipitation stays out of the suite")
	_test_glass(player, room)
	if not await _test_stairs(city, player, room):
		_finish()
		return
	await _test_rail(city, player, room)
	await _test_services(main, city, player, room, str(home.id))
	_test_furniture_coverage(player,room)
	await _test_city_streaming(city)
	await _test_furniture(city,player,room)
	_test_furniture_authority(home)
	await _test_furniture_replica(city,room)
	_test_surface_integrity(room)
	_test_budgets(city, room)
	await _test_panorama_time(main, city)
	_set_hour(main, 13.0)
	if is_instance_valid(city.penthouse_view):
		await _wait_panorama_hour(city.penthouse_view, 13.0)
		report["skyline"] = city.penthouse_view.stats()
	for frame in range(45): await get_tree().process_frame
	var previous := Time.get_ticks_usec()
	var frame_times: Array[float] = []
	for frame in range(180):
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frame_times.append(float(now - previous) / 1000.0)
		previous = now
	frame_times.sort()
	report["frames"] = {"count": frame_times.size(), "p50_ms": frame_times[90],
		"p95_ms": frame_times[171], "p99_ms": frame_times[178], "max_ms": frame_times[-1]}
	report["renderer"] = DisplayServer.get_name()
	report["adapter"] = RenderingServer.get_video_adapter_name()
	report["viewport"] = str(main.get_viewport().get_visible_rect().size)
	report["render_scale"] = main._render_scale
	print("PENTHOUSE_FRAMES " + JSON.stringify(report))
	if capture and DisplayServer.get_name() != "headless":
		await _capture_views(main, city, room)
	city.exit_building()
	check(player.cam._cam.environment == outdoor_environment and is_equal_approx(player.cam._cam.far, outdoor_far),
		"leaving restores the exact saved camera environment and far clipping distance")
	if await _arrival(city, "return to city entrance"):
		check(not city.is_inside() and player.position.distance_to(home.door) < 5.0,
			"normal exit returns to the same outdoor property entrance")
		check(player.cam._cam.environment == outdoor_environment and main.world.seasonal_weather.atmosphere_enabled(),
			"exit restores the outdoor camera environment and weather")
		check(not sim.city_view().owned_properties.is_empty()
			and sim.city_view().home == str(home.id),
			"owned suite and chosen home remain valid after leaving")
	_finish()


func _arrival(city: Node, label: String) -> bool:
	var frames := 0
	while city.arrival_pending() and frames < 600:
		await get_tree().physics_frame
		frames += 1
	var ready: bool = not city.arrival_pending() and not city.world.local_player.arrival_locked
	check(ready, label + " releases after physical support is ready")
	return ready


func _check_floor(player: MonkeyPlayer, room: Node3D, local_y: float, label: String) -> void:
	var ray := PhysicsRayQueryParameters3D.create(player.position + Vector3.UP * 0.6,
		player.position - Vector3.UP * 1.5, 1, [player.get_rid()])
	var hit := player.get_world_3d().direct_space_state.intersect_ray(ray)
	check(not hit.is_empty() and (hit.get("normal", Vector3.ZERO) as Vector3).y > 0.8
		and absf((hit.get("position", Vector3.INF) as Vector3).y - room.global_position.y - local_y) < 0.15,
		label + " has a grounded physical floor")


func _test_glass(player: MonkeyPlayer, room: Node3D) -> void:
	for line in [[Vector3(0, 1.2, 10), Vector3(0, 1.2, 12)],
		[Vector3(12, 1.2, 1), Vector3(14, 1.2, 1)]]:
		var ray := PhysicsRayQueryParameters3D.create(room.to_global(line[0]),
			room.to_global(line[1]), 1, [player.get_rid()])
		var hit := player.get_world_3d().direct_space_state.intersect_ray(ray)
		check(not hit.is_empty() and absf((hit.get("normal", Vector3.UP) as Vector3).y) < 0.1,
			"panoramic glazing has a physical safety barrier")


func _test_stairs(city: Node, player: MonkeyPlayer, room: Node3D) -> bool:
	city._teleport(room.to_global(Vector3(10.8, 0.12, 4.8)))
	if not await _arrival(city, "stair approach"): return false
	player.ti.dir = Vector2(0, -1)
	var climbed := 0
	while room.to_local(player.position).z > -5.7 and climbed < 480:
		await get_tree().physics_frame
		climbed += 1
	player.ti.dir = Vector2.ZERO
	for frame in range(25): await get_tree().physics_frame
	var at := room.to_local(player.position)
	check(at.z < -5.2 and at.y >= 3.85,
		"real player walks up the full staircase to the four-metre mezzanine without jumping")
	_check_floor(player, room, 4.0, "upper stair landing")
	if at.y < 3.85: return false
	player.ti.dir = Vector2(0, 1)
	var descended := 0
	while room.to_local(player.position).z < 4.8 and descended < 480:
		await get_tree().physics_frame
		descended += 1
	player.ti.dir = Vector2.ZERO
	for frame in range(25): await get_tree().physics_frame
	at = room.to_local(player.position)
	check(at.z > 4.3 and absf(at.y) < 0.2,
		"real player walks back down the staircase onto the lower floor")
	_check_floor(player, room, 0.0, "lower stair landing")
	report["stair_physics_frames"] = {"up": climbed, "down": descended}
	return true


func _test_rail(city: Node, player: MonkeyPlayer, room: Node3D) -> void:
	var ray := PhysicsRayQueryParameters3D.create(room.to_global(Vector3(0, 4.8, -5.8)),
		room.to_global(Vector3(0, 4.8, -4.2)), 1, [player.get_rid()])
	var hit := player.get_world_3d().direct_space_state.intersect_ray(ray)
	check(not hit.is_empty() and absf((hit.get("normal", Vector3.ZERO) as Vector3).z) > 0.8,
		"mezzanine balustrade contains a physical guardrail")
	city._teleport(room.to_global(Vector3(0, 4.12, -6.3)))
	if not await _arrival(city, "mezzanine rail approach"): return
	player.ti.dir = Vector2(0, 1)
	for frame in range(90): await get_tree().physics_frame
	player.ti.dir = Vector2.ZERO
	var at := room.to_local(player.position)
	check(at.z < -5.15 and at.y >= 3.85,
		"mezzanine guardrail stops the actual player from walking into the open living space")


func _test_services(main: Node, city: Node, player: MonkeyPlayer, room: Node3D, id: String) -> void:
	var points: Dictionary = room.service_points()
	var sim = main.frontier_controller.simulation
	check(points.has("storage") and points.has("bed") and points.has("workbench") and points.has("exit"),
		"luxury layout retains the full owned-property service set")
	for key in ["storage", "bed", "workbench"]:
		var point: Vector3 = points[key].position
		city._teleport(room.to_global(point + Vector3.UP * 0.4))
		if not await _arrival(city, key + " approach"): continue
		for frame in range(20): await get_tree().physics_frame
		var opened: bool = main.frontier_controller.try_interact(player)
		check(opened and city.panel.visible and str(city.panel.context.kind) == str(points[key].kind),
			"physical " + key + " opens the matching contextual service")
		if key == "storage":
			var before: int = sim.stock("player_earth", "banana")
			var stored: Dictionary = city.request_action("store_item", {"building": id, "item": "banana", "quantity": 2})
			check(stored.get("ok", false) and sim.stock("player_earth", "banana") == before - 2,
				"luxury cupboard stores actual backpack goods at its new anchor")
			var taken: Dictionary = city.request_action("take_item", {"building": id, "item": "banana", "quantity": 1})
			check(taken.get("ok", false) and sim.stock("player_earth", "banana") == before - 1,
				"luxury cupboard returns the same stored goods")
		elif key == "bed":
			var selected: Dictionary = city.request_action("set_home", {"building": id})
			check(selected.get("ok", false) and sim.city_view().home == id,
				"new bedroom anchor selects the owned penthouse as the return home")
		city.panel.close()


func _test_surface_integrity(room: Node3D) -> void:
	var surfaces := 0
	var all_referenced := true
	var lowest_coverage := 1.0
	for instance in room.find_children("PenthouseBatch_*", "MeshInstance3D", true, false):
		if not instance.mesh is ArrayMesh: continue
		var mesh: ArrayMesh = instance.mesh
		for surface in range(mesh.get_surface_count()):
			surfaces += 1
			var arrays := mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] \
				if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if indices.is_empty():
				all_referenced = all_referenced and vertices.size() > 0 and vertices.size() % 3 == 0
				continue
			var referenced: Dictionary = {}
			var valid_indices := true
			for index in indices:
				referenced[index] = true
				valid_indices = valid_indices and index >= 0 and index < vertices.size()
			var coverage := float(referenced.size()) / maxf(1.0, float(vertices.size()))
			lowest_coverage = minf(lowest_coverage, coverage)
			all_referenced = all_referenced and valid_indices and coverage >= 0.95
			if coverage < 0.95 or not valid_indices:
				print("PENTHOUSE_MESH_GAP batch=%s surface=%d vertices=%d referenced=%d coverage=%.4f" %
					[instance.name, surface, vertices.size(), referenced.size(), coverage])
	check(surfaces >= 8 and all_referenced,
		"every furnishing surface actually draws its vertices when indexed and custom geometry share a batch")
	report["surface_integrity"] = {"surfaces": surfaces, "minimum_index_coverage": lowest_coverage}


func _test_budgets(city: Node, room: Node3D) -> void:
	var geometry := room.find_children("*", "GeometryInstance3D", true, false).size()
	var lights := room.find_children("*", "Light3D", true, false).size()
	var colliders := room.find_children("*", "CollisionShape3D", true, false).size()
	check(geometry > 8 and geometry <= 96 and lights >= 2 and lights <= 12 and colliders < 160,
		"furnished suite keeps geometry batches, local lights and collision resources bounded")
	report["suite"] = {"geometry_batches": geometry, "lights": lights, "collision_shapes": colliders}
	var view: Node = city.get("penthouse_view")
	check(is_instance_valid(view) and view.has_method("stats"),
		"suite controller binds the live city view")
	if is_instance_valid(view) and view.has_method("stats"):
		var stats: Dictionary = view.stats()
		check(view.get_child_count() == 0 and int(stats.get("render_batches",-1)) == 0
			and float(stats.get("geometry_scale",0.0)) == 1.0 and city.city_world.visible
			and view.city_world == city.city_world and view.global_position == room.global_position,
			"suite view uses actual CityWorld at unit scale and contains no duplicate skyline or sky dome")
		report["skyline"] = stats


func _test_furniture_coverage(player: MonkeyPlayer, room: Node3D) -> void:
	var layout := Rooms.furniture_layout(room.property)
	var fixtures_by_id:Dictionary={}
	var missing:Array[String]=[]
	var chairs:=0
	for collider in room.find_children("*","CollisionShape3D",true,false):
		var id:=str(collider.get_meta("furniture_id",""))
		if id.is_empty():continue
		fixtures_by_id[id]=true
		if not layout.has(id):missing.append(id)
	for spec in Furniture.penthouse_chairs():
		if fixtures_by_id.has(spec.id):chairs+=1
	var fixtures:=fixtures_by_id.size()
	check(fixtures==18 and chairs==13 and missing.is_empty(),
		"every real chair, sofa, chaise, bench and bed has exact upholstery collision and an interaction")
	var authority := NetworkScript.new()
	var clear := 0
	for id: String in layout:
		var item: Dictionary = Furniture.world_item(layout[id],room.global_position)
		var approach_clear := player.can_stand_at(item.position)
		var exits_clear: bool = not item.exits.is_empty()
		for destination: Vector3 in item.exits:
			exits_clear = exits_clear and player.can_stand_at(destination)
		authority._interiors[21] = room.property.id
		var accepted: Dictionary = authority._furniture_action(21,"use_furniture",{"id":id},item.position)
		check(approach_clear and exits_clear and accepted.get("ok",false),
			id+" has a physical standing approach, clear exits and an authority-approved seat")
		if approach_clear and exits_clear: clear += 1
		authority.unregister_peer(21)
	authority.free()
	report["furniture_coverage"] = {"catalog":layout.size(),"fixtures":fixtures,"chairs":chairs,"clear_approaches":clear,"missing":missing}


func _test_city_streaming(city: Node) -> void:
	var expected := Plan.TOTAL_BLOCKS
	var before: int = city.city_world.far_staged_block_count()
	var frames := 0
	# The normal frame budget remains one far block per process frame, even
	# indoors. A complete-city capture waits for it instead of disguising a
	# partially staged real skyline with substitute background geometry.
	while city.city_world.far_staged_block_count()<expected and frames<expected+64:
		await get_tree().process_frame
		frames += 1
	var after: int = city.city_world.far_staged_block_count()
	check(city.is_inside() and city.city_world.visible and after==expected,
		"the live city keeps streaming every municipal block while the penthouse is occupied")
	report["city_streaming"] = {"before":before,"after":after,"wait_process_frames":frames,
		"far_instances":city.city_world.far_visible_instance_count(),"complete":after==expected}


func _test_furniture(city: Node, player: MonkeyPlayer, room: Node3D) -> void:
	var layout := Rooms.furniture_layout(room.property)
	var saved_height: float = player.rig.standing_height
	for id in ["olive_west","sectional","bed_sleep","dining_chair_1_0","study_chair","mezzanine_sofa","bedroom_bench"]:
		var item: Dictionary = layout[id]
		city._teleport(room.to_global(item.position))
		if not await _arrival(city,"furniture approach "+id): return
		# Native panels animate closed; their input boundary intentionally
		# consumes E until the preceding service card has finished disappearing.
		var closing_frames := 0
		while city.panel.visible and closing_frames < 60:
			await get_tree().physics_frame
			closing_frames += 1
		check(not city.panel.visible,"preceding service panel releases input before "+id)
		var saved_view: int = player.cam.preferred_view_mode
		for frame in range(12):await get_tree().physics_frame
		player.rig.set_yaw(float(item.yaw))
		player.ti.interact_just = true
		for frame in range(600):
			await get_tree().physics_frame
			if player.furniture_active() and player._anim()!=Furniture.ENTER_SEAT:break
		check(player.furniture_active() and player._anim() == Furniture.resting_animation(item.mode),
			"physical E interaction settles into distinct "+str(item.mode)+" posture")
		if not player.furniture_active():
			print("PENTHOUSE_ENTRY_BLOCK ",id," ",city.last_message," ",player.furniture_clearance_blocker)
			continue
		print("PENTHOUSE_FURNITURE ",id," ",JSON.stringify({"root_error":player.global_position.distance_to(room.to_global(item.root)),
			"capsule_disabled":player._collision_shape.disabled,"height":player.rig.standing_height,"velocity":str(player.velocity)}))
		check(player.global_position.distance_to(room.to_global(item.root)) < 0.025
			and player._furniture_motion.shapes.size()>=16 and player._collision_shape.disabled and player.velocity == Vector3.ZERO
			and is_equal_approx(player.rig.standing_height,saved_height),
			"occupied "+id+" holds its real anchor without shrinking the monkey or fighting the standing capsule")
		if item.mode == "bed":
			check(absf(player.rig.head_p.global_position.y-player.rig.hips.global_position.y) < 0.30
				and player.rig.head_p.global_position.z > player.rig.hips.global_position.z+0.5,
				"sleeping monkey lies horizontally with its head toward the real pillows")
			check(player.rig._sleep_eye_blend>0.98,"sleep closes the monkey eyelids")
		else:
			check(player.rig.hip_l.rotation.x >= 0.69 and player.rig.kn_l.rotation.x < -0.6,
				"seated monkey bends independent hip and knee joints")
		if _capture_requested and DisplayServer.get_name() != "headless" and id in ["olive_west","sectional","bed_sleep"]:
			await _capture_furniture_pose(city,player,room,item)
		if id == "olive_west":
			var blocker := StaticBody3D.new()
			room.add_child(blocker)
			var shape_node := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(0.9,2.0,0.9)
			shape_node.shape = box
			blocker.add_child(shape_node)
			blocker.global_position = room.to_global(item.exits[0])+Vector3.UP
			for frame in range(3): await get_tree().physics_frame
			player.ti.interact_just = true
			for frame in range(6): await get_tree().physics_frame
			check(player.furniture_active() and player._anim() != Furniture.RISE,
				"blocked standing capsule cancels get-up safely instead of clipping into furniture")
			blocker.queue_free()
			for frame in range(3): await get_tree().physics_frame
		player.ti.dir = Vector2(0,-1)
		for frame in range(3): await get_tree().physics_frame
		player.ti.dir = Vector2.ZERO
		for frame in range(650):
			await get_tree().physics_frame
			if not player.furniture_active():break
		for frame in range(8):await get_tree().physics_frame
		check(not player.furniture_active() and not player._collision_shape.disabled
			and player.cam.preferred_view_mode == saved_view and player.is_on_floor(),
			"movement smoothly rises from "+id+" and restores camera, collision and grounded control")
		if item.mode=="bed":
			check(player.rig._sleep_eye_blend<0.02,"rising restores open eyes")
		var start := player.position
		player.ti.dir = Vector2(-1,0)
		for frame in range(12): await get_tree().physics_frame
		player.ti.dir = Vector2.ZERO
		check(player.position.distance_to(start) > 0.15,"normal movement resumes after "+id)


func _test_furniture_authority(home: Dictionary) -> void:
	var authority := NetworkScript.new()
	var origin := NetworkScript.interior_origin(home)
	var item: Dictionary = Furniture.world_item(Rooms.furniture_layout(home).olive_west,origin)
	check(not authority._furniture_action(21,"use_furniture",{"id":"olive_west"},item.position).get("ok",false),
		"authority rejects furniture use without an established interior session")
	authority._interiors[21] = home.id
	authority._interiors[22] = home.id
	check(not authority._furniture_action(21,"use_furniture",{"id":"olive_west"},item.position+Vector3.RIGHT*8).get("ok",false)
		and not authority._furniture_action(21,"use_furniture",{"id":"invented"},item.position).get("ok",false),
		"authority rejects remote furniture activation and invented seat IDs")
	var accepted: Dictionary = authority._furniture_action(21,"use_furniture",{"id":"olive_west"},item.position)
	check(accepted.get("ok",false) and not authority._furniture_action(22,"use_furniture",{"id":"olive_west"},item.position).get("ok",false),
		"two residents cannot occupy the same physical armchair")
	item=accepted.furniture
	check(not authority.validate_furniture_state(21,item.root,Furniture.SIT),"authority rejects skipping the approach animation")
	var route:Array=item.motion_path
	var route_total:float=preload("res://scripts/city_furniture_motion.gd").duration(route)
	authority._furniture[21].entered_msec=Time.get_ticks_msec()-roundi(route_total*1000.0)
	var route_clear:=true
	for index in range(ceili(route_total*20.0)+1):
		var frame:Dictionary=preload("res://scripts/city_furniture_motion.gd").sample(route,minf(route_total,float(index)/20.0))
		authority._furniture[21].packet_msec=Time.get_ticks_msec()-50
		route_clear=route_clear and authority.validate_furniture_state(21,frame.root,Furniture.ENTER_SEAT,frame.yaw)
	check(route_clear,"authority accepts canonical sampled approach packets")
	check(authority.validate_furniture_state(21,item.root,Furniture.SIT)
		and not authority.validate_furniture_state(22,item.root,Furniture.SIT)
		and not authority.validate_furniture_state(21,item.root,Furniture.SLEEP)
		and not authority.validate_furniture_state(21,item.root+Vector3.RIGHT*20,Furniture.SIT),
		"replicated furniture animation requires the server's matching occupant, posture and anchor")
	check(not authority.validate_furniture_state(21,item.root+Vector3.RIGHT*0.8,Furniture.SIT)
		and not authority._furniture_action(21,"leave_furniture",{"target":0},item.root+Vector3.RIGHT*10).get("ok",false),
		"authority rejects drifting resting poses and get-up requests away from the occupied furniture")
	var saved_network: Node = Net.frontier_network
	var saved_host: bool = Net.is_host
	var fixture := FurnitureNetworkFixture.new()
	fixture.city = authority
	Net.frontier_network = fixture
	Net.is_host = true
	var valid_wire := Net._valid_state_for_peer(21,item.root,float(item.yaw),Vector3.ZERO,Furniture.SIT,
		false,Vector3.ZERO,0.0,PackedVector3Array(),Net.WEAPON_REVOLVER,6,0.0)
	var spoofed_wire := Net._valid_state_for_peer(22,item.root,float(item.yaw),Vector3.ZERO,Furniture.SIT,
		false,Vector3.ZERO,0.0,PackedVector3Array(),Net.WEAPON_REVOLVER,6,0.0)
	Net.frontier_network = saved_network
	Net.is_host = saved_host
	fixture.free()
	check(valid_wire and not spoofed_wire,"actual actor packet validation accepts the occupant and rejects spoofed furniture state")
	check(not authority._furniture_action(21,"leave_furniture",{"target":99},item.root).get("ok",false),
		"authority rejects an invented get-up destination")
	var stood: Dictionary = authority._furniture_action(21,"leave_furniture",{"target":0},item.root)
	check(stood.get("ok",false) and stood.furniture_exit == item.exits[0]
		and authority.validate_furniture_state(21,item.root,Furniture.RISE),
		"authority authors the standing destination before accepting replicated rise")
	var rise_item:Dictionary=authority._furniture[21]
	var rise_total:float=preload("res://scripts/city_furniture_motion.gd").duration(rise_item.motion_path)
	rise_item.entered_msec=Time.get_ticks_msec()-roundi(rise_total*1000.0)
	for index in range(ceili(rise_total*20.0)+1):
		var frame:Dictionary=preload("res://scripts/city_furniture_motion.gd").sample(rise_item.motion_path,minf(rise_total,float(index)/20.0))
		rise_item.packet_msec=Time.get_ticks_msec()-50
		authority.validate_furniture_state(21,frame.root,Furniture.RISE,frame.yaw)
	authority.validate_furniture_state(21,item.exits[0],MonkeyRig.Anim.IDLE)
	check(authority._furniture_action(22,"use_furniture",{"id":"olive_west"},item.position).get("ok",false),
		"standing releases the shared seat for the other resident")
	authority.unregister_peer(22)
	check(authority._furniture.is_empty(),"disconnect releases occupied furniture")
	authority.free()


func _test_furniture_replica(city: Node, room: Node3D) -> void:
	var replica := Puppet.new()
	replica.setup(22,"Furniture replica validation")
	city.world.add_child(replica)
	var at := room.to_global(Vector3(3.0,0.1,-8.0))
	for animation in [Furniture.SIT,Furniture.RECLINE,Furniture.SLEEP]:
		replica.apply_state(at,0.0,Vector3.ZERO,animation,false,Vector3.ZERO,0.0,
			PackedVector3Array(),Net.WEAPON_REVOLVER,true,false,6,false,0.0)
		for frame in range(80): await get_tree().process_frame
		check(replica._anim == animation and replica.global_position.distance_to(at) < 0.05
			and replica.rig._anim_prev == animation and replica.rig.standing_height == MonkeyRig.PLAYER_HEIGHT
			and replica._remote_weapon_stowed,
			"shared actor replica renders furniture pose "+str(animation)+" at its authoritative world anchor")
	replica.queue_free()


func _capture_furniture_pose(city: Node, player: MonkeyPlayer, room: Node3D, item: Dictionary) -> void:
	var previous: Camera3D = get_viewport().get_camera_3d()
	var camera := Camera3D.new()
	city.world.add_child(camera)
	camera.environment = previous.environment
	camera.far = 12000.0
	camera.near = 0.05
	camera.fov = 58.0
	var offset := Vector3(2.1,1.65,3.0)
	if item.mode == "sofa": offset = Vector3(2.5,1.65,-2.9)
	elif item.mode == "bed": offset = Vector3(3.2,2.3,-2.0)
	camera.global_position = room.to_global(item.root+offset)
	camera.look_at(room.to_global(item.root+Vector3(0,0.7,0.2)))
	camera.make_current()
	var hidden: Array[Dictionary] = []
	for layer in get_tree().root.find_children("*","CanvasLayer",true,false):
		hidden.append({"node":layer,"visible":layer.visible})
		layer.visible = false
	for frame in range(20): await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := OUTPUT.path_join("furniture-"+str(item.mode)+".png")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	check(get_viewport().get_texture().get_image().save_png(path) == OK,"saved real monkey "+str(item.mode)+" pose")
	for entry in hidden: entry.node.visible = entry.visible
	previous.make_current()
	camera.queue_free()


func _test_panorama_time(main: Node, city: Node) -> void:
	var view: Node = city.get("penthouse_view")
	if not is_instance_valid(view): return
	_set_hour(main, 13.0)
	var day_ready := await _wait_panorama_hour(view, 13.0)
	var day: Dictionary = view.stats()
	var day_shader := float(main.world.daylight_amount)
	_set_hour(main, 23.0)
	var night_ready := await _wait_panorama_hour(view, 23.0)
	var night: Dictionary = view.stats()
	var night_shader := float(main.world.daylight_amount)
	check(day_ready and night_ready and absf(float(day.get("hour", 0.0)) - 13.0) < 0.15
		and absf(float(night.get("hour", 0.0)) - 23.0) < 0.15
		and float(day.get("daylight", 0.0)) > float(night.get("daylight", 1.0)) + 0.5
		and day_shader > night_shader + 0.5,
		"suite lighting follows the actual shared Earth daylight without a separate sky clock")


func _wait_panorama_hour(view: Node, hour: float) -> bool:
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		if absf(float(view.stats().get("hour", 0.0)) - hour) < 0.15: return true
		await get_tree().process_frame
	return false


func _capture_views(main: Node, city: Node, room: Node3D) -> void:
	var hidden: Array[Dictionary] = []
	for layer in main.find_children("*", "CanvasLayer", true, false):
		hidden.append({"node": layer, "visible": layer.visible})
		layer.visible = false
	var player: MonkeyPlayer = main.world.local_player
	var was_visible := player.visible
	player.visible = false
	var previous_camera: Camera3D = main.get_viewport().get_camera_3d()
	var camera := Camera3D.new()
	main.world.add_child(camera)
	camera.environment = previous_camera.environment
	camera.near = 0.04
	camera.far = 12000.0
	camera.make_current()
	var layout: Dictionary = room.validation_layout()
	var views: Dictionary = layout.get("captures", {})
	var fallback := {"living": {"position": Vector3(-2.4, 1.8, -3.8), "target": Vector3(2.5, 2.4, 7.0)},
		"bedroom": {"position": Vector3(-3.5, 1.8, 4.0), "target": Vector3(-8.5, 1.0, 8.0)},
		"mezzanine": {"position": Vector3(4.5, 5.7, -8.7), "target": Vector3(-3.5, 1.8, 6.0)},
		"city":{"position":Vector3(0,1.7,10.6),"target":Vector3(-80,-140,200)}}
	for shot in [{"id": "living-day", "view": "living", "hour": 13.0},
		{"id": "living-sunset", "view": "living", "hour": 17.5},
		{"id": "living-night", "view": "living", "hour": 23.0},
		{"id": "bedroom", "view": "bedroom", "hour": 17.5},
		{"id": "mezzanine", "view": "mezzanine", "hour": 17.5},
		{"id":"live-city-window","view":"city","hour":23.0}]:
		var view: Dictionary = views.get(shot.view, fallback[shot.view])
		_set_hour(main, float(shot.hour))
		check(await _wait_panorama_hour(city.penthouse_view, float(shot.hour)),
			str(shot.id) + " uses the requested live city time")
		camera.global_position = room.to_global(view.position)
		camera.look_at(room.to_global(view.target))
		camera.fov = float(view.get("fov", 70.0))
		for frame in range(45): await get_tree().process_frame
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
		var path := OUTPUT.path_join(str(shot.id) + ".png")
		var error := main.get_viewport().get_texture().get_image().save_png(path)
		check(error == OK, "saved native " + str(shot.id) + " view")
		print("PENTHOUSE_CAPTURE " + ProjectSettings.globalize_path(path))
	if is_instance_valid(previous_camera): previous_camera.make_current()
	camera.queue_free()
	player.visible = was_visible
	for layer in hidden:
		if is_instance_valid(layer.node): layer.node.visible = layer.visible


func _set_hour(main: Node, hour: float) -> void:
	main.frontier_controller.set_solar_hour(hour)


func _finish() -> void:
	report["checks"] = checks
	report["passed"] = passed
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var file := FileAccess.open(OUTPUT.path_join("validation.json"), FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(report, "\t") + "\n")
	print("CITYPENTHOUSETEST %d/%d %s" % [passed, checks, "PASS" if passed == checks else "FAIL"])
	_finish_after_cleanup.call_deferred(0 if passed == checks else 1)


func _finish_after_cleanup(code: int) -> void:
	for frame in range(3): await get_tree().process_frame
	get_tree().quit(code)
