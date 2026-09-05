extends Node3D
## Persistent park rendering and interactions, independent of street chunks.
const Plan = preload("res://scripts/city_plan.gd")
const Layout = preload("res://scripts/city_park_layout.gd")
const Landscape = preload("res://scripts/city_park.gd")
const Activities = preload("res://scripts/city_park_activities.gd")
const BoatScript = preload("res://scripts/park_rowboat.gd")
const NEAR_TREE_LIMIT := 64
signal build_finished
var city: Node
var activity: Node3D
var boat: Vehicle
var boats: Array[Vehicle] = []
var built := false
var _landscape: Dictionary = {}
var _tree_shapes: Array[CollisionShape3D] = []
var _tree_buckets: Dictionary = {}
var _tree_shadow: MultiMesh
var _focus_clock := 0.0
var _last_cell := Vector2i(999999,999999)
var _collision_count := 0

func configure(owner_city: Node) -> void:
	city=owner_city
	position=Vector3(Plan.PARK_CENTER.x,0,Plan.PARK_CENTER.y)
	name="LanternCentralPark"
	_build.call_deferred()

func _build() -> void:
	_landscape=await Landscape.build(self)
	if not is_inside_tree(): return
	for definition in Layout.boat_definitions():
		var vessel: Vehicle=city.world.spawn_vehicle(Vehicle.Kind.BOAT,definition.id,definition.pos,definition.yaw)
		boats.append(vessel)
	boat=boats[0]
	activity=Activities.new();activity.name="ParkActivities";add_child(activity);activity.configure(self)
	_create_tree_support()
	built=true
	build_finished.emit()

func interactions(player: Variant) -> Array:
	if not built or not is_instance_valid(player): return []
	var result: Array=[]
	for entry in Layout.activities():
		if player.global_position.distance_to(entry.position)>5: continue
		var item:Dictionary=entry.duplicate();item["city"]=true;result.append(item)
	return result

func interact(context: Dictionary) -> void:
	if not built or not is_instance_valid(city.world.local_player): return
	var player:Node3D=city.world.local_player
	var message:=""
	match str(context.get("kind","")):
		"park_yoga":
			activity.start_yoga();message="Great Lawn yoga · breathe in slowly, then follow the group's tree and warrior poses."
		"park_dogs":
			activity.throw_ball(player);message="Fetch! Watch the meadow dog chase the ball and bring it back."
		"park_social":
			activity.greet(player.global_position);message="Welcome to Lantern Gardens! The neighbors wave you over."
		"park_cycle":
			message="Scenic cycle loop · cyclists follow the separate seven-metre loop. Walk on the gravel paths."
		"park_boathouse":
			message="Walk onto a timber landing and press E beside a rowboat. W/S row, A/D steer, E returns to the landing."
	player.supply_notice=message;player.supply_notice_remaining=7
	city.last_message=message

func _create_tree_support() -> void:
	for site in _landscape.get("tree_sites",[]):
		var p:Vector3=site.position
		var key:=Vector2i(floori(p.x/80),floori(p.z/80))
		if not _tree_buckets.has(key): _tree_buckets[key]=[]
		_tree_buckets[key].append(site)
	var body:=StaticBody3D.new();body.name="NearbyPhysicalParkTrees";add_child(body)
	for i in range(NEAR_TREE_LIMIT):
		var collider:=CollisionShape3D.new();var shape:=CapsuleShape3D.new()
		shape.radius=.42;shape.height=12;collider.shape=shape;collider.disabled=true
		body.add_child(collider);_tree_shapes.append(collider)
	_tree_shadow=MultiMesh.new();_tree_shadow.transform_format=MultiMesh.TRANSFORM_3D
	_tree_shadow.mesh=Landscape._shape("sphere");_tree_shadow.instance_count=NEAR_TREE_LIMIT*3;_tree_shadow.visible_instance_count=0
	var shadows:=MultiMeshInstance3D.new();shadows.name="NearParkCanopyShadows";shadows.multimesh=_tree_shadow
	shadows.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	add_child(shadows)

func _process(dt: float) -> void:
	if not built or not is_instance_valid(city.world.local_player): return
	_focus_clock-=dt
	if _focus_clock>0: return
	_focus_clock=.5
	var focus:Vector3=city.world.local_player.global_position
	var cell:=Vector2i(floori(focus.x/32),floori(focus.z/32))
	if cell==_last_cell: return
	_last_cell=cell
	var nearby:Array=[]
	if focus.y>=0 and focus.y<120 and Plan.is_park(Vector2(focus.x,focus.z)):
		var center:=Vector2i(floori(focus.x/80),floori(focus.z/80))
		for x in range(center.x-2,center.x+3):
			for z in range(center.y-2,center.y+3):
				for site in _tree_buckets.get(Vector2i(x,z),[]):
					if site.position.distance_squared_to(focus)<10000: nearby.append(site)
	nearby.sort_custom(func(a,b): return a.position.distance_squared_to(focus)<b.position.distance_squared_to(focus))
	_collision_count=mini(nearby.size(),NEAR_TREE_LIMIT)
	for i in range(NEAR_TREE_LIMIT):
		var collider:=_tree_shapes[i]
		collider.disabled=i>=_collision_count
		if i>=_collision_count: continue
		var site:Dictionary=nearby[i]
		var local:Vector3=to_local(site.position)
		collider.shape.height=site.height*.86
		collider.position=local+Vector3.UP*site.height*.43
		for c in range(3):
			var spread:float=site.spread
			var offset:=Vector3(sin(c*TAU/3)*spread*.22,site.height*(.67+.10*c),cos(c*TAU/3)*spread*.22)
			_tree_shadow.set_instance_transform(i*3+c,Transform3D(Basis.from_scale(Vector3(spread,spread*.9,spread)),local+offset))
	_tree_shadow.visible_instance_count=_collision_count*3

func is_build_complete() -> bool: return built

func stats() -> Dictionary:
	var result:=_landscape.duplicate()
	result.erase("tree_sites")
	result.merge({"ready":built,"trees":_landscape.get("tree_sites",[]).size(),"near_tree_colliders":_collision_count,
		"near_tree_limit":NEAR_TREE_LIMIT,"boat_count":boats.size(),"activities":activity.stats() if is_instance_valid(activity) else {}},true)
	return result

func _exit_tree() -> void:
	Landscape.release_resources()
