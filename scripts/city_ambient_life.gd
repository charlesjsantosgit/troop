class_name CityAmbientLife
extends Node3D
## Citywide road users stay in a lightweight graph simulation. Nearby cars are
## promoted to collision bodies without changing their identity or route.
const Plan = preload("res://scripts/city_plan.gd")
const Traffic = preload("res://scripts/city_traffic.gd")
const Monkeys = preload("res://scripts/city_monkey_models.gd")
const WALKER_DETAIL_RADIUS := 100.0
const WALKER_DETAIL_CAP := 256
const Fleet = preload("res://scripts/city_vehicle_models.gd")
const MAX_VEHICLES := 6000
const MAX_WALKERS := 24000
const TICK := .10
const HASH_SIZE := 64.0
var manager: Node3D
var vehicles: Array = []
var batches: Array[MultiMeshInstance3D] = []
var walkers: MultiMeshInstance3D
var walker_batches: Array[MultiMeshInstance3D] = []
var walker_detail: Array[MultiMeshInstance3D] = []
var _walker_blocks: Dictionary = {}
var _detail_clock := 0.0
var _detail_count := 0
var buckets: Dictionary = {}
var _pedestrian_buckets: Dictionary = {}
var ready_city := false
var tick_clock := 0.0
var update_count := 0
var _build_index := 0
var _walk_count := 0
var _walker_transforms: Array[Transform3D] = []
var _walker_colors: Array[Color] = []
var _walker_data: Array[Color] = []
var _mesh_lists: Array = []
var _shader_material: ShaderMaterial
var _walker_material: ShaderMaterial
var _render_time := 0.0
var _cursor := 0
var _simulation_time := 0.0
var simulation_ms := 0.0
var peak_simulation_ms := 0.0

func _ready() -> void:
	name = "CitywideMovingPopulation"
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	for index in range(Fleet.CATALOG.size()): _mesh_lists.append([])
	_shader_material = ShaderMaterial.new()
	_shader_material.shader = load("res://scripts/city_ambient_vehicle.gdshader")
	_walker_material = ShaderMaterial.new()
	_walker_material.shader = load("res://scripts/city_ambient_pedestrian.gdshader")

func stage(block_budget := 24) -> void:
	if ready_city: return
	for iteration in range(block_budget):
		if _build_index >= Plan.TOTAL_BLOCKS:
			_finish_build()
			return
		# Coprime traversal distributes first-use staging throughout the city.
		var permuted := posmod(_build_index * 73,Plan.TOTAL_BLOCKS)
		var block := Vector2i(permuted % Plan.GRID_WIDTH,permuted / Plan.GRID_WIDTH)
		_build_index += 1
		if Plan.is_park_block(block): continue
		var key := block
		for direction in Traffic.DIRECTIONS:
			if not Traffic.edge_allowed(key,key+direction) or vehicles.size() >= MAX_VEHICLES: continue
			# Stable sub-sampling retains every neighborhood without allocating rigs.
			var seed := absi((block.x*19349663) ^ (block.y*73856093) ^ ((direction.x+2)*83492791) ^ ((direction.y+2)*15485863))
			if seed % 10 >= 7: continue
			var busy := busy_road(key)
			var copies := (3 if direction.y!=0 else 2) if busy else 1
			for occupant in range(copies):
				if vehicles.size()>=MAX_VEHICLES: break
				var vehicle := VehicleState.new()
				vehicle.serial = 1000000 + vehicles.size()
				vehicle.model = posmod(seed / 13+occupant*7,Fleet.CATALOG.size())
				var spec := Fleet.spec(vehicle.model)
				vehicle.vehicle_length = spec.length
				vehicle.vehicle_width = spec.width
				vehicle.road_from = key
				vehicle.road_to = key + direction
				vehicle.road_next = manager.traffic.choose_open_next(key,vehicle.road_to,vehicle.serial)
				if vehicle.road_next.x < 0: continue
				var start := Traffic.exit_point(key,direction,vehicle.vehicle_length)
				var finish := Traffic.stop_point(vehicle.road_to,direction,vehicle.vehicle_length)
				var fraction := (float(occupant)+.35+float(seed%300)/1000.0)/float(copies) if busy else .15+float(seed%700)/1000.0
				vehicle.at = start.lerp(finish,fraction)
				vehicle.yaw = atan2(-float(direction.x),-float(direction.y))
				vehicle.speed = 3.0+float(seed%30)*.1
				vehicles.append(vehicle)
				_mesh_lists[vehicle.model].append(vehicle)
		var origin := Traffic.point(block)
		var inset := Traffic.road_half(0)+1.4
		var extents := Plan.STREET_SPACING - Vector2.ONE*inset*2
		for resident in range(10):
			if _walk_count >= MAX_WALKERS: break
			var seed := block.x*157+block.y*281+resident*43
			_walker_transforms.append(Transform3D(Basis.IDENTITY,Vector3(origin.x+inset,Plan.GROUND_Y+.035,origin.y+inset)))
			_walker_colors.append(Color(Monkeys.height_for(seed)/Monkeys.BASE_HEIGHT,0,0,1))
			if not _walker_blocks.has(block): _walker_blocks[block] = []
			_walker_blocks[block].append(_walk_count)
			_walker_data.append(Color(float(resident)/10.0,float(seed%100)/100.0,extents.x,extents.y))
			_walk_count += 1

static func busy_road(key: Vector2i) -> bool:
	# Concentrate some of the same bounded persistent fleet on downtown lanes.
	# Long avenues support three safely separated cars; shorter streets two.
	var relative := (Vector2(key)-Vector2(float(Plan.GRID_WIDTH)*.5+4,float(Plan.GRID_DEPTH)*.5))/Vector2(6,5)
	return relative.length_squared()<=1.0

func _finish_build() -> void:
	for index in range(_mesh_lists.size()):
		var node := MultiMeshInstance3D.new()
		node.name = "Distant_"+str(Fleet.spec(index).id)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = Fleet.mesh(index,false,false)
		mm.instance_count = _mesh_lists[index].size()
		mm.custom_aabb = AABB(Vector3(Plan.MIN_X,Plan.GROUND_Y-2,Plan.MIN_Z),Vector3(Plan.MAX_X-Plan.MIN_X,8,Plan.MAX_Z-Plan.MIN_Z))
		node.multimesh = mm
		node.material_override = _shader_material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		batches.append(node)
	# Model-derived sprites are split into bounded spatial batches so a distant
	# camera never submits all 24,000 residents just to see one street.
	var chunks: Dictionary = {}
	for key: Vector2i in _walker_blocks:
		var chunk := Vector2i(key.x/4,key.y/4)
		if not chunks.has(chunk): chunks[chunk] = []
		chunks[chunk].append_array(_walker_blocks[key])
	var quad := QuadMesh.new()
	quad.size = Vector2(2.4,2.4)
	quad.set_meta("canonical_model","MonkeyRig")
	for key: Vector2i in chunks:
		var node := MultiMeshInstance3D.new()
		node.name = "CanonicalMonkeyImpostors_"+str(key)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = quad
		mm.instance_count = chunks[key].size()
		for i in range(chunks[key].size()):
			var source: int = chunks[key][i]
			mm.set_instance_transform(i,_walker_transforms[source])
			mm.set_instance_color(i,_walker_colors[source])
			mm.set_instance_custom_data(i,_walker_data[source])
		var origin := Traffic.point(key*4)
		mm.custom_aabb = AABB(Vector3(origin.x-2,Plan.GROUND_Y-2,origin.y-2),Vector3(Plan.STREET_SPACING.x*4+4,6,Plan.STREET_SPACING.y*4+4))
		node.multimesh = mm
		node.material_override = _walker_material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		walker_batches.append(node)
	if not walker_batches.is_empty(): walkers = walker_batches[0]
	var atlas_path := "res://assets/generated/city_monkey_walk.png"
	if ResourceLoader.exists(atlas_path):
		_walker_material.set_shader_parameter("canonical_atlas",load(atlas_path))
	for frame in range(4):
		var node := MultiMeshInstance3D.new()
		node.name = "ExactMonkeyWalkPhase"+str(frame)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = Monkeys.pose("walk",0,frame)
		mm.instance_count = WALKER_DETAIL_CAP
		mm.visible_instance_count = 0
		node.multimesh = mm
		add_child(node)
		walker_detail.append(node)
	ready_city = true
	_rebuild_buckets()
	_render()

func advance(delta: float) -> void:
	stage()
	if not ready_city: return
	var started := Time.get_ticks_usec()
	_shader_material.set_shader_parameter("traffic_clock",manager.traffic.time)
	_simulation_time += delta
	tick_clock += delta
	if tick_clock >= .25:
		tick_clock = 0.0
		_refresh_pedestrian_buckets()
	# Time-slice the citywide simulation instead of updating thousands of
	# drivers on a single frame. Physical drivers retain full physics rate.
	var count := mini(320,vehicles.size())
	for iteration in range(count):
		var vehicle: VehicleState = vehicles[_cursor]
		_cursor = (_cursor+1)%vehicles.size()
		var dt := clampf(_simulation_time-vehicle.last_update,.001,.50)
		vehicle.last_update = _simulation_time
		vehicle.render_interval = dt
		if is_instance_valid(vehicle.physical): vehicle.capture(vehicle.physical)
		else: vehicle.advance(dt,manager.traffic,neighbors(vehicle.at))
		_render_vehicle(vehicle)
		if Time.get_ticks_usec()-started > 5000: break
	_walker_material.set_shader_parameter("near_focus",manager.focus if manager.focus.is_finite() else Vector3.INF)
	_walker_material.set_shader_parameter("population_time",_simulation_time)
	_detail_clock += delta
	if _detail_clock >= .08:
		_detail_clock = 0.0
		_update_detailed_walkers()
	simulation_ms = float(Time.get_ticks_usec()-started)/1000.0
	peak_simulation_ms = maxf(peak_simulation_ms,simulation_ms)
	update_count += 1

func _rebuild_buckets() -> void:
	buckets.clear()
	for vehicle: VehicleState in vehicles:
		vehicle.bucket_key = Vector2i(2147483647,2147483647)
		_update_vehicle_bucket(vehicle)
	_refresh_pedestrian_buckets()

func _update_vehicle_bucket(vehicle: VehicleState) -> void:
	var key := Vector2i(floori(vehicle.at.x/HASH_SIZE),floori(vehicle.at.y/HASH_SIZE))
	if key==vehicle.bucket_key: return
	if buckets.has(vehicle.bucket_key):
		buckets[vehicle.bucket_key].erase(vehicle)
		if buckets[vehicle.bucket_key].is_empty(): buckets.erase(vehicle.bucket_key)
	if not buckets.has(key): buckets[key] = []
	buckets[key].append(vehicle)
	vehicle.bucket_key = key

func _refresh_pedestrian_buckets() -> void:
	_pedestrian_buckets.clear()
	if not is_instance_valid(manager): return
	for actor in manager.actors:
		if actor.car: continue
		var key := Vector2i(floori(actor.position.x/HASH_SIZE),floori(actor.position.z/HASH_SIZE))
		if not _pedestrian_buckets.has(key): _pedestrian_buckets[key] = []
		_pedestrian_buckets[key].append(actor)

func neighbors(at: Vector2) -> Array:
	var result: Array = []
	var key := Vector2i(floori(at.x/HASH_SIZE),floori(at.y/HASH_SIZE))
	for x in range(-1,2):
		for y in range(-1,2):
			var cell := key+Vector2i(x,y)
			for state: VehicleState in buckets.get(cell,[]):
				result.append(state.physical if is_instance_valid(state.physical) else state)
			for actor in _pedestrian_buckets.get(cell,[]):
				if is_instance_valid(actor) and not actor.is_queued_for_deletion(): result.append(actor)
	return result

func candidates(focus: Vector3, radius: float) -> Array:
	var result: Array = []
	for vehicle in vehicles:
		if vehicle.at.distance_squared_to(Vector2(focus.x,focus.z)) < radius*radius: result.append(vehicle)
	result.sort_custom(func(a,b): return a.at.distance_squared_to(Vector2(focus.x,focus.z)) < b.at.distance_squared_to(Vector2(focus.x,focus.z)))
	return result

func _render() -> void:
	for model in range(batches.size()):
		var index := 0
		for vehicle in _mesh_lists[model]:
			vehicle.instance_slot = index
			_render_vehicle(vehicle)
			index += 1

func _render_vehicle(vehicle: VehicleState) -> void:
	_update_vehicle_bucket(vehicle)
	var mm := batches[vehicle.model].multimesh
	var packet := vehicle_render_state(vehicle,manager.traffic.time)
	mm.set_instance_transform(vehicle.instance_slot,packet.transform)
	mm.set_instance_color(vehicle.instance_slot,Fleet.paint_for(vehicle.serial,vehicle.model))
	mm.set_instance_custom_data(vehicle.instance_slot,packet.custom)

static func vehicle_render_state(vehicle: VehicleState, traffic_time: float) -> Dictionary:
	var scale := Vector3.ZERO if is_instance_valid(vehicle.physical) else Vector3.ONE
	var at := Vector3(vehicle.at.x,Plan.GROUND_Y-.03,vehicle.at.y)
	return {"transform":Transform3D(Basis(Vector3.UP,vehicle.yaw).scaled(scale),at),"custom":Color(vehicle.velocity.length(),vehicle.render_interval,Time.get_ticks_msec()*.001,1.0 if traffic_time<vehicle.disabled_until else 0.0)}

func stats() -> Dictionary:
	var moving := 0
	var physical := 0
	for vehicle in vehicles:
		if vehicle.speed > .1: moving += 1
		if is_instance_valid(vehicle.physical): physical += 1
	return {"cars":vehicles.size(),"pedestrians":_walk_count,"moving_cars":moving,"physical_cars":physical,"draw_batches":batches.size()+walker_batches.size()+walker_detail.size(),"walker_spatial_batches":walker_batches.size(),"canonical_walkers":_detail_count,"pedestrian_model":"MonkeyRig","distant_lod":"canonical rendered atlas","ready":ready_city,"simulation_updates":update_count,"altitude_culling":false,"simulation_ms":simulation_ms,"peak_simulation_ms":peak_simulation_ms}

static func _pedestrian_mesh() -> ArrayMesh:
	return Monkeys.pose("walk",0,0)

func walker_position(index: int, time: float) -> Dictionary:
	var data := _walker_data[index]
	var width := data.b
	var depth := data.a
	var perimeter := 2.0*(width+depth)
	var speed := 1.05+data.g*.55
	var along := fposmod(data.r*perimeter+time*speed,perimeter)
	var offset := Vector2.ZERO
	var yaw := 0.0
	if along<width:
		offset = Vector2(along,0)
		yaw = -PI*.5
	elif along<width+depth:
		offset = Vector2(width,along-width)
		yaw = PI
	elif along<2*width+depth:
		offset = Vector2(2*width+depth-along,depth)
		yaw = PI*.5
	else: offset = Vector2(0,perimeter-along)
	return {"position":_walker_transforms[index].origin+Vector3(offset.x,0,offset.y),"yaw":yaw,"phase":posmod(floori(time*speed*5.0+data.r*4.0),4),"scale":_walker_colors[index].r}

func _update_detailed_walkers() -> void:
	var camera := get_viewport().get_camera_3d()
	var camera_at: Vector3 = camera.global_position if is_instance_valid(camera) else manager.focus
	var key := Traffic.grid(Vector2(camera_at.x,camera_at.z))
	var counts: Array[int] = [0,0,0,0]
	_detail_count = 0
	if absf(camera_at.y-Plan.GROUND_Y)<WALKER_DETAIL_RADIUS:
		for x in range(-2,3):
			for z in range(-1,2):
				for index: int in _walker_blocks.get(key+Vector2i(x,z),[]):
					var walker := walker_position(index,_simulation_time)
					var at: Vector3 = walker.position
					if at.distance_to(camera_at)>WALKER_DETAIL_RADIUS: continue
					if absf(manager.focus.y-at.y)<40 and Vector2(manager.focus.x-at.x,manager.focus.z-at.z).length()<28: continue
					var frame: int = walker.phase
					if counts[frame]>=WALKER_DETAIL_CAP: continue
					walker_detail[frame].multimesh.set_instance_transform(counts[frame],Transform3D(Basis(Vector3.UP,walker.yaw).scaled(Vector3.ONE*float(walker.scale)),at))
					counts[frame] += 1
					_detail_count += 1
	for frame in range(4): walker_detail[frame].multimesh.visible_instance_count = counts[frame]

class VehicleState extends RefCounted:
	var bucket_key := Vector2i(2147483647,2147483647)
	var car := true
	var serial := 0
	var model := 0
	var vehicle_length := 4.63
	var vehicle_width := 1.78
	var road_from := Vector2i.ZERO
	var road_to := Vector2i.ZERO
	var road_next := Vector2i.ZERO
	var road_curve := PackedVector2Array()
	var curve_index := 1
	var speed := 0.0
	var disabled_until := 0.0
	var crash_damage := 0.0
	var impact_local_point := Vector3.ZERO
	var impact_local_normal := Vector3.ZERO
	var impact_speed := 0.0
	var impact_count := 0
	var _last_impact_time := -1.0
	var committed := false
	var trips := 0
	var finished := false
	var waiting_to_cross := false
	var crossing_key := Vector2i(-1,-1)
	var at := Vector2.ZERO
	var velocity := Vector2.ZERO
	var yaw := 0.0
	var physical: CharacterBody3D
	var instance_slot := 0
	var last_update := 0.0
	var render_interval := .1
	func position_2d() -> Vector2: return at
	func capture(actor: CharacterBody3D) -> void:
		for key in ["road_from","road_to","road_next","road_curve","curve_index","speed","committed","trips","finished","disabled_until","crash_damage","impact_local_point","impact_local_normal","impact_speed","impact_count","_last_impact_time"]: set(key,actor.get(key))
		at = actor.position_2d()
		yaw = actor.rotation.y
		velocity = Vector2.ZERO
	func restore(actor: CharacterBody3D) -> void:
		for key in ["serial","model","vehicle_length","vehicle_width","road_from","road_to","road_next","road_curve","curve_index","speed","committed","trips","finished","disabled_until","crash_damage","impact_local_point","impact_local_normal","impact_speed","impact_count","_last_impact_time"]: actor.set(key,get(key))
		actor.position = Vector3(at.x,Plan.GROUND_Y-.03,at.y)
		actor.rotation.y = yaw
	func advance(delta: float, controller: RefCounted, others: Array) -> void:
		if finished: return
		if controller.time<disabled_until:
			speed = 0.0
			velocity = Vector2.ZERO
			return
		if disabled_until>0.0:
			disabled_until = 0.0
			crash_damage = 0.0
			impact_speed = 0.0
		var incoming := road_to-road_from
		if not committed and (road_next.x<0 or not controller.edge_open(road_to,road_next)):
			road_next = controller.choose_open_next(road_from,road_to,serial*17+trips*13)
		var target := road_curve[curve_index] if committed else Traffic.stop_point(road_to,incoming,vehicle_length)
		var remaining := target.distance_to(at)
		var direction := (target-at).normalized()
		var allowed: bool = committed or controller.may_enter(self,others)
		if remaining <= .025:
			velocity = Vector2.ZERO
			if committed:
				if curve_index < road_curve.size()-1: curve_index += 1
				else:
					controller.release_car(road_to,serial)
					committed = false
					road_from = road_to
					road_to = road_next
					trips += 1
					road_next = controller.choose_open_next(road_from,road_to,serial*17+trips*13)

			elif allowed:
				controller.reserve_car(self)
				committed = true
				road_curve = Traffic.turn_path(road_from,road_to,road_next,vehicle_length)
				curve_index = 1
			else: speed = move_toward(speed,0,Traffic.BRAKE*delta)
			return
		var limit: float = Traffic.speed_limit(road_from,incoming)*controller.mobility_factor(road_to)
		if committed: limit = minf(limit,3.4 if road_next-road_to != incoming else 7.5)
		elif road_next-road_to != incoming: limit = minf(limit,sqrt(3.4*3.4+2.0*Traffic.BRAKE*remaining))
		if not allowed: limit = minf(limit,sqrt(2.0*Traffic.BRAKE*maxf(remaining-.02,0)))
		limit = Traffic.following_speed(self,others,direction,limit)
		limit = controller.incident_speed_limit(self,direction,limit)
		speed = move_toward(speed,limit,(Traffic.BRAKE if limit<speed else Traffic.ACCELERATION)*delta)
		velocity = direction*minf(speed,remaining/maxf(delta,.001))
		at += velocity*delta
		if velocity.length_squared() > .001: yaw = atan2(-direction.x,-direction.y)
