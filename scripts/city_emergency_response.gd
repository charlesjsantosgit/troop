extends Node3D
## A bounded response team follows a real directed road edge, then works from
## the curb. Incident state/timing and street closures remain server authority.
const Plan=preload("res://scripts/city_plan.gd")
const Traffic=preload("res://scripts/city_traffic.gd")
const Actors=preload("res://scripts/park_actor_batch.gd")
const MAX_CREW:=8
const VEHICLE_SPEED:=11.0
var world:Node3D
var record:Dictionary={}
var building:Dictionary={}
var actors:Node3D
var _route:Dictionary={}
var _vehicles:Array[CharacterBody3D]=[]
var _phase:="impact"
var _age:=0.0
var _progress:=0.0
var _render_clock:=0.0
var _last_age:=-1.0
var _crew_count:=0
var _hose_count:=0
var _carry_count:=0
var _blocked_moves:=0
var _water:MultiMesh
var _water_node:MultiMeshInstance3D
var _vehicle_arrived:Array[bool]=[false,false]
var _use_curb_lane:Array[bool]=[false,false]

func configure(owner_world:Node3D,item:Dictionary)->void:
	world=owner_world;record=item.duplicate(true);building=Plan.building(str(record.building))
	name="EmergencyResponse_"+str(record.get("id",record.building))
	if building.is_empty(): return
	position=Vector3(building.position.x,0,building.position.z)
	_route=road_route(Vector2(building.position.x,building.position.z))
	actors=Actors.new();actors.name="CanonicalMonkeyResponseCrew";add_child(actors)
	for i in range(2):
		var vehicle:=CharacterBody3D.new();vehicle.name="FireEngine" if i==0 else "RepairVan"
		vehicle.collision_layer=1;vehicle.collision_mask=1
		var shape:=CollisionShape3D.new();var box:=BoxShape3D.new();box.size=Vector3(2.55,2.9,7.8);shape.shape=box;shape.position.y=1.65
		vehicle.add_child(shape);add_child(vehicle);_vehicles.append(vehicle)
		if not _route.is_empty(): vehicle.global_position=_route_point(0,i)
		vehicle.visible=false;shape.disabled=true
	var cylinder:=CylinderMesh.new();cylinder.top_radius=.5;cylinder.bottom_radius=.5;cylinder.height=1;cylinder.radial_segments=6
	_water=MultiMesh.new();_water.transform_format=MultiMesh.TRANSFORM_3D;_water.mesh=cylinder;_water.instance_count=48;_water.visible_instance_count=0
	_water_node=MultiMeshInstance3D.new();_water_node.name="PressurizedHoseWater";_water_node.multimesh=_water
	var material:=StandardMaterial3D.new();material.albedo_color=Color(.49,.78,.89,.7);material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;_water_node.material_override=material;_water_node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_water_node)

static func road_route(site:Vector2)->Dictionary:
	# Pick an actual directed edge and use its 2.7 m traffic lane. The last 18 m
	# ease toward the incident-side curb, entirely inside the 24 m carriageway.
	var center:=Traffic.grid(site);var best:Dictionary={};var best_score:=INF
	for x in range(center.x-2,center.x+3):
		for y in range(center.y-2,center.y+3):
			var a:=Vector2i(x,y)
			for direction in Traffic.DIRECTIONS:
				var b:=a+direction
				if not Traffic.edge_allowed(a,b): continue
				var start:=Traffic.point(a);var finish:=Traffic.point(b)
				var length:=start.distance_to(finish);var forward:=Vector2(direction)
				var along:=clampf((site-start).dot(forward),minf(92,length-22),length-22)
				var road_end:=start+forward*along
				var side:=1.0 if (site-road_end).dot(Traffic.right(direction))>=0 else -1.0
				var normal:=Traffic.right(direction)*side
				var parking:=road_end+normal*9.1
				if Plan.is_park(parking) or Plan.pond_depth(parking)>0: continue
				var score:=parking.distance_squared_to(site)
				if score>=best_score: continue
				best_score=score
				var distance:=minf(80,along-12)
				best={"from":a,"to":b,"direction":forward,"normal":normal,"parking":parking,
					"start":road_end-forward*distance+Traffic.right(direction)*Traffic.lane_offset(a,direction),
					"lane_end":road_end-forward*18+Traffic.right(direction)*Traffic.lane_offset(a,direction),"length":distance}
	return best

func _route_point(distance:float,index:int)->Vector3:
	if _route.is_empty(): return Vector3.ZERO
	var start:Vector2=_route.start-Vector2(_route.direction)*float(index)*12
	var lane_end:Vector2=_route.lane_end-Vector2(_route.direction)*float(index)*12
	var parking:Vector2=_route.parking-Vector2(_route.direction)*float(index)*12
	var straight:=start.distance_to(lane_end)
	var point:Vector2
	if distance<straight: point=start.lerp(lane_end,clampf(distance/straight,0,1))
	else:
		var t:=clampf((distance-straight)/lane_end.distance_to(parking),0,1)
		point=lane_end.lerp(parking,t*t*(3-2*t))
	return Vector3(point.x,Plan.GROUND_Y+.07,point.y)

func update_phase(phase:String,progress:float,time:float)->void:
	if not is_instance_valid(actors) or _route.is_empty(): return
	_phase=phase;_progress=clampf(progress,0,1);_age=maxf(0,time)
	var elapsed:=maxf(0,_age-_last_age) if _last_age>=0 else .05
	_last_age=_age
	for i in range(2):
		var deploy:=_age>=4 if i==0 else phase in ["stabilize","rebuild"]
		var vehicle:=_vehicles[i]
		vehicle.visible=deploy
		vehicle.get_child(0).disabled=not deploy
		if not deploy: continue
		var travel:=maxf(0,_age-(4 if i==0 else 56))*VEHICLE_SPEED
		var destination:=_route_point(travel,i)
		if _use_curb_lane[i]:
			var direction:Vector2=_route.direction
			var parking:Vector2=_route.parking
			var projected:=parking+direction*(Vector2(destination.x,destination.z)-parking).dot(direction)
			destination.x=projected.x;destination.z=projected.y
		var motion:=destination-vehicle.global_position
		vehicle.global_basis=Basis.looking_at(Vector3(_route.direction.x,0,_route.direction.y),Vector3.UP)
		if motion.length_squared()>.00001:
			var hit:=vehicle.move_and_collide(motion)
			if hit!=null:
				_blocked_moves+=1
				# A stopped traffic car can yield its outer lane to the emergency
				# convoy. Move physically into the clear curb strip, then continue
				# alongside the same real road edge; never pass through the car.
				if hit.get_collider() is CharacterBody3D and not _vehicles.has(hit.get_collider()):
					_use_curb_lane[i]=true
					var forward:Vector2=_route.direction
					var parked:Vector2=_route.parking
					var current:=Vector2(vehicle.global_position.x,vehicle.global_position.z)
					var side_target:=parked+forward*(current-parked).dot(forward)
					vehicle.move_and_collide(Vector3(side_target.x-current.x,0,side_target.y-current.y))
		_vehicle_arrived[i]=vehicle.global_position.distance_to(_route_point(10000,i))<.25
	_render_clock+=elapsed
	if _render_clock<.05: return
	_render_clock=0
	_draw()

func _draw()->void:
	actors.begin_frame();_crew_count=0;_hose_count=0;_carry_count=0
	for i in range(2):
		if _vehicles[i].visible:
			actors.response_vehicle(to_local(_vehicles[i].global_position),_route.direction,i==0,_age)
	if not _vehicle_arrived[0]: actors.end_frame();_water.visible_instance_count=0;return
	var normal:Vector2=_route.normal;var along:Vector2=_route.direction
	var curb:Vector2=_route.parking+normal*5.2
	var face:=Vector2(building.position.x,building.position.z)
	var facing:Vector2=(face-curb).normalized()
	var crew_phase:=_phase
	for i in range(MAX_CREW):
		var offset:=float(i%4)*2.35-3.5
		var site:=curb+along*offset+normal*float(i/4)*1.35
		var pose:="talk"
		var forward:=facing
		if crew_phase=="fire":
			pose="hose" if i<2 else "firefighter"
		elif crew_phase=="rebuild" and _vehicle_arrived[1]:
			if i<4:
				var travel:=sin(_age*.45+float(i)*PI*.5)
				site+=along*travel*4.0
				forward=along if cos(_age*.45+float(i)*PI*.5)>0 else -along
				pose="carry";_carry_count+=1
			else: pose="hammer"
		elif crew_phase=="stabilize": pose="builder"
		else: pose="firefighter"
		var world_at:=Vector3(site.x,Plan.GROUND_Y+.08,site.y)
		actors.person(to_local(world_at),forward,pose,_age+float(i)*.73,Color("c9ae43") if crew_phase in ["stabilize","rebuild"] else Color("a1935a"),i)
		_crew_count+=1
		if pose=="hose":
			var nozzle:=Actors.attachment_point(world_at,facing,"hose",_age+float(i)*.73,i,"hand_center",Vector3(0,0,-.35))
			var impact:=Vector3(float(record.position[0]),minf(float(record.position[1]),Plan.GROUND_Y+22),float(record.position[2]))
			_draw_water(nozzle,impact,i)
			var truck:=_vehicles[0].global_position+Vector3.UP*.7
			actors.segment(to_local(truck),to_local(world_at+Vector3.UP*.18),.095,Color("b99c69"))
			actors.segment(to_local(world_at+Vector3.UP*.18),to_local(nozzle),.085,Color("b99c69"))
			_hose_count+=1
	for i in range(12):
		var point:Vector2=_route.parking+along*(float(i)*2.4-13.2)-normal*2.2
		actors.cone(to_local(Vector3(point.x,Plan.GROUND_Y+.08,point.y)))
	if crew_phase in ["stabilize","rebuild"]:
		var stack:=curb-along*9+normal
		actors.material_stack(to_local(Vector3(stack.x,Plan.GROUND_Y+.08,stack.y)),along)
	_water.visible_instance_count=_hose_count*24
	actors.end_frame()

func _draw_water(start:Vector3,finish:Vector3,stream:int)->void:
	for i in range(24):
		var t0:=float(i)/24;var t1:=float(i+1)/24
		var a:=start.lerp(finish,t0)+Vector3.UP*sin(t0*PI)*2.5
		var b:=start.lerp(finish,t1)+Vector3.UP*sin(t1*PI)*2.5
		a+=Vector3(sin(_age*13+i)*.035,0,cos(_age*11+i)*.035)
		var up:Vector3=(b-a).normalized();var right:=Vector3.RIGHT.cross(up).normalized() if absf(up.x)<.9 else Vector3.FORWARD.cross(up).normalized()
		var basis:=Basis(right,up,right.cross(up))*Basis.from_scale(Vector3(.075,(b-a).length(),.075))
		_water.set_instance_transform(stream*24+i,Transform3D(basis,to_local((a+b)*.5)))

func stats()->Dictionary:
	return {"phase":_phase,"crew":_crew_count,"max_crew":MAX_CREW,"tail_carriers":_carry_count,"water_streams":_hose_count,
		"vehicles":_vehicles.size(),"arrived":_vehicle_arrived.duplicate(),"route":_route.duplicate(),"blocked_moves":_blocked_moves,
		"actor_batches":actors.stats() if is_instance_valid(actors) else {},"water_batches":1,"water_segments":_water.visible_instance_count if _water else 0}
