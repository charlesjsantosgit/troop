extends RefCounted
const Plan=preload("res://scripts/highway_plan.gd")
const Routes=preload("res://scripts/highway_routes.gd")
static func supports(at:Vector3)->bool:
	var sample:=Plan.road_sample(at)
	return sample.get("on_road",false) or (not sample.is_empty() and at.distance_to(sample.position)<25.0)
static func make_unit(id:String,at:Vector3)->Dictionary:
	return {"id":id,"position":[at.x,at.y,at.z],"heading":0.0,"speed":0.0,"state":"patrol","siren":false,"target":[],"arrived":false,"officer_position":[at.x,at.y,at.z],"_highway":true,"_path":[],"_index":1,"_route_target":[]}
static func advance_unit(unit:Dictionary,dt:float,target:Vector3,mode:String)->Dictionary:
	var at:=Routes.position(unit.get("position",[]))
	var old_target:=Routes.position(unit.get("_route_target",[]))
	var path:PackedVector3Array=PackedVector3Array(unit.get("_path",[]))
	if path.is_empty() or old_target.distance_to(target)>90.0:
		path=Routes.route(at,target)
		unit._path=path
		unit._index=1
		unit._route_target=[target.x,target.y,target.z]
	unit.state=mode
	unit.siren=mode not in ["patrol","return","idle"]
	unit.target=[target.x,target.y,target.z]
	if path.size()<2:
		unit.speed=0.0
		unit.arrived=false
		return unit
	var index:int=clampi(int(unit.get("_index",1)),1,path.size()-1)
	var desired:=minf(26.0,maxf(8.0,Plan.posted_speed(at)))
	if path.size()-index<4:desired=minf(desired,8.0)
	unit.speed=move_toward(float(unit.get("speed",0)),desired,3.2*dt)
	var budget:float=unit.speed*dt
	while budget>0 and index<path.size():
		var delta:Vector3=path[index]-at
		if delta.length()<.03:index+=1;continue
		var move:=minf(budget,delta.length())
		at+=delta.normalized()*move
		unit.heading=atan2(delta.x,delta.z)
		budget-=move
		if move>=delta.length()-.001:index+=1
	unit._index=index
	unit.position=[at.x,at.y,at.z]
	unit.arrived=index>=path.size()
	if unit.arrived:unit.speed=0.0
	unit.officer_position=[at.x+1.7,at.y,at.z]
	return unit
