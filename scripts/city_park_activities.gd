extends Node3D
const Plan = preload("res://scripts/city_plan.gd")
const Layout = preload("res://scripts/city_park_layout.gd")
const Batch = preload("res://scripts/park_actor_batch.gd")
const WALKERS := 56
const DOG_WALKERS := 6
const YOGA_PARTICIPANTS := 18
const CYCLISTS := 24
const SOCIALIZERS := 18
const MAX_RENDER_DISTANCE := 440.0
var park: Node3D
var batch: ParkActorBatch
var time := 0.0
var yoga_time := 0.0
var activity_clock := 0.0
var _accumulated := 0.0
var _fetch_state := 0
var _fetch_time := 0.0
var _dog_position := Vector3.ZERO
var _ball_start := Vector3.ZERO
var _ball_target := Vector3.ZERO
var _ball_position := Vector3.ZERO
var _greeting_until := 0.0
var _greeting_target := Vector3.ZERO
var _rendered_people := 0
var _dog_route := PackedVector2Array()
var _routes: Array[PackedVector2Array] = []
var _lengths: Array[float] = []

func configure(owner_park: Node3D) -> void:
	park=owner_park
	batch=Batch.new();batch.name="AnimatedParkVisitors";add_child(batch)
	_routes=Layout.walking_paths_world()
	for route in _routes: _lengths.append(Layout.route_length(route))
	_dog_route=Layout.dog_path_world()
	_dog_position=Layout.world(Vector2(-155,-1260))
	_refresh(0)

func _process(dt: float) -> void:
	time+=dt;yoga_time+=dt;activity_clock+=dt
	_accumulated+=dt
	if _accumulated < .05: return
	var elapsed:=_accumulated;_accumulated=0
	_refresh(elapsed)

func _refresh(dt: float) -> void:
	if not is_instance_valid(batch) or not is_instance_valid(park): return
	var player: Node3D=park.city.world.local_player
	if not is_instance_valid(player): return
	var focus:=player.global_position
	if focus.y < 0 or not Plan.contains(Vector2(focus.x,focus.z)):
		batch.visible=false;return
	batch.visible=true;batch.begin_frame();_rendered_people=0
	for i in range(WALKERS):
		var route_index:=i%4
		var route:=_routes[route_index]
		var state:=Layout.route_point(route,time*(1.05+float(i%5)*.08)+_lengths[route_index]*float(i)/WALKERS)
		var p:=Vector3(state.point.x,Plan.GROUND_Y,state.point.y)
		if _near(p,focus):
			batch.person(to_local(p),state.direction,"walk",time+float(i),_shirt(i),i);_rendered_people+=1
	for i in range(DOG_WALKERS):
		var state:=Layout.route_point(_dog_route,time*1.05+float(i)*Layout.route_length(_dog_route)/DOG_WALKERS)
		var p:=Vector3(state.point.x,Plan.GROUND_Y,state.point.y)
		var sideways:=Vector2(-state.direction.y,state.direction.x)
		var dog:=p+Vector3(sideways.x,0,sideways.y)*1.55+Vector3(state.direction.x,0,state.direction.y)*.55
		if i==0 and _fetch_state>0: dog=_step_fetch(dt,player)
		if not _near(p,focus): continue
		batch.person(to_local(p),state.direction,"walk",time+i,_shirt(i+8),i);_rendered_people+=1
		var dog_forward:Vector2=state.direction
		if i==0 and _fetch_state>0:
			var target:=_ball_target if _fetch_state<3 else player.global_position
			dog_forward=Vector2(target.x-dog.x,target.z-dog.z).normalized()
		batch.dog(to_local(dog),dog_forward,time+i,i)
		if i!=0 or _fetch_state==0:
			batch.leash(to_local(p+Vector3(sideways.x*.3,.75,sideways.y*.3)),to_local(dog+Vector3.UP*.7))
	for i in range(YOGA_PARTICIPANTS):
		var p:=Layout.world(Vector2(-80+float(i%6-2)*2.8,-910+float(i/6)*3))
		if _near(p,focus): batch.person(to_local(p),Vector2(0,-1),"yoga",yoga_time,_shirt(i+19),i);_rendered_people+=1
	var cycle:=Layout.cycle_path_world()
	var cycle_length:=Layout.route_length(cycle)
	for i in range(CYCLISTS):
		var state:=Layout.route_point(cycle,time*(4.0+float(i%4)*.23)+cycle_length*float(i)/CYCLISTS)
		var p:=Vector3(state.point.x,Plan.GROUND_Y,state.point.y)
		if _near(p,focus): batch.person(to_local(p),state.direction,"cycle",time+i,_shirt(i+32),i);_rendered_people+=1
	for i in range(SOCIALIZERS):
		var group:=i/3
		var angle:=float(i%3)*TAU/3+.2
		var center:=Layout.world(Vector2(110+float(group%3)*7,-625+float(group/3)*8))
		var p:=center+Vector3(cos(angle),0,sin(angle))*2.2
		var target:=_greeting_target if time<_greeting_until else center
		var forward:=Vector2(target.x-p.x,target.z-p.z).normalized()
		if _near(p,focus): batch.person(to_local(p),forward,"wave" if time<_greeting_until and i%3==0 else "talk",time+i,_shirt(i+55),i);_rendered_people+=1
	if _fetch_state>0: batch.ball(to_local(_ball_position))
	batch.end_frame()

func start_yoga() -> void: yoga_time=0
func greet(target: Vector3) -> void: _greeting_until=time+9;_greeting_target=target
func throw_ball(player: Node3D) -> void:
	_fetch_state=1;_fetch_time=0
	_ball_start=player.global_position+Vector3.UP*1.0
	_ball_target=Layout.world(Vector2(-155,-1278))+Vector3.UP*.12
	_ball_position=_ball_start
	var state:=Layout.route_point(_dog_route,time*1.05)
	_dog_position=Vector3(state.point.x,Plan.GROUND_Y,state.point.y)

func _step_fetch(dt: float,player: Node3D) -> Vector3:
	_fetch_time+=dt
	if _fetch_state==1:
		var t:=clampf(_fetch_time/1.1,0,1)
		_ball_position=_ball_start.lerp(_ball_target,t)+Vector3.UP*sin(t*PI)*2.5
		if t>=1: _fetch_state=2
	var target:=_ball_target if _fetch_state<3 else player.global_position
	target.y=Plan.GROUND_Y
	_dog_position=_dog_position.move_toward(target,dt*4.4)
	if _fetch_state==2 and _dog_position.distance_to(target)<.65: _fetch_state=3
	if _fetch_state==3:
		_ball_position=_dog_position+Vector3.UP*.63
		if _dog_position.distance_to(target)<1.3:
			_fetch_state=0
			player.supply_notice="Good dog! Press E in the dog meadow to play fetch again."
			player.supply_notice_remaining=4
	return _dog_position

func _near(at: Vector3,focus: Vector3) -> bool: return at.distance_squared_to(focus)<MAX_RENDER_DISTANCE*MAX_RENDER_DISTANCE
func _shirt(i: int) -> Color:
	return [Color("bd8667"),Color("658bb0"),Color("678c72"),Color("9e7b9c"),Color("c1ae71"),Color("566c79")][i%6]
func stats() -> Dictionary:
	var result:=batch.stats() if is_instance_valid(batch) else {}
	result.merge({"walkers":WALKERS,"dog_walkers":DOG_WALKERS,"dogs":DOG_WALKERS,"yoga":YOGA_PARTICIPANTS,"cyclists":CYCLISTS,"socializers":SOCIALIZERS,"rendered_people":_rendered_people,"fetch_state":_fetch_state,"yoga_time":yoga_time},true)
	return result
