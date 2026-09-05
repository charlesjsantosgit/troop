class_name CityIncidentState
extends RefCounted
const Plan=preload("res://scripts/city_plan.gd")
const Massing=preload("res://scripts/city_massing.gd")
const MAX_INCIDENTS:=4
const DAY_SECONDS:=1200.0
static func vector(value: Array) -> Vector3:return Vector3(value[0],value[1],value[2])
static func point(value:Vector3)->Array:return [value.x,value.y,value.z]
static func find_hit(start:Vector3,finish:Vector3,radius:=0.0)->Dictionary:
	var a:=Vector2(minf(start.x,finish.x)-radius,minf(start.z,finish.z)-radius)
	var b:=Vector2(maxf(start.x,finish.x)+radius,maxf(start.z,finish.z)+radius)
	if b.x<Plan.MIN_X or a.x>Plan.MAX_X or b.y<Plan.MIN_Z or a.y>Plan.MAX_Z:return {}
	var first:=Plan.world_to_block(a.clamp(Vector2(Plan.MIN_X,Plan.MIN_Z),Vector2(Plan.MAX_X,Plan.MAX_Z)))
	var last:=Plan.world_to_block(b.clamp(Vector2(Plan.MIN_X,Plan.MIN_Z),Vector2(Plan.MAX_X,Plan.MAX_Z)))
	if first.x<0 or last.x<0:return {}
	var best:Dictionary={}
	var distance:=INF
	for z in range(first.y,last.y+1):
		for x in range(first.x,last.x+1):
			for building in Plan.block_buildings(Vector2i(x,z)):
				for section in Massing.sections(building):
					var center:Vector3=building.position+section.offset
					var bounds:=AABB(center-Vector3(section.size)*.5,section.size).grow(radius)
					var hit:Variant=bounds.intersects_segment(start,finish)
					if not hit is Vector3:continue
					var d:=start.distance_squared_to(hit)
					if d>=distance:continue
					distance=d
					var local:Vector3=hit-center
					var axis:=0
					var gaps:Vector3=(local.abs()-Vector3(section.size)*.5).abs()
					if gaps.y<gaps.x:axis=1
					if gaps.z<gaps[axis]:axis=2
					var normal:=Vector3.ZERO;normal[axis]=signf(local[axis])
					best={"building":building.id,"point":hit,"normal":normal,"distance":sqrt(d)}
	return best
static func record(building_id:String,at:Vector3,direction:Vector3,now:float,span:=9.45,height:=3.8)->Dictionary:
	return {"id":building_id,"building":building_id,"position":point(at),"direction":point(direction.normalized()),"created":now,
		"restore":(floorf(now/DAY_SECONDS)+1.0)*DAY_SECONDS+300.0,"span":clampf(span,4,30),"height":clampf(height,2,12)}
static func valid(value:Variant)->bool:
	if not value is Dictionary or value.size()>MAX_INCIDENTS:return false
	for id in value:
		var r:Variant=value[id]
		if not id is String or not r is Dictionary or r.get("id")!=id or r.get("building")!=id or Plan.building(id).is_empty():return false
		for field in ["position","direction"]:
			if not r.get(field) is Array or r[field].size()!=3:return false
			for v in r[field]:
				if not (v is float or v is int) or not is_finite(v) or absf(v)>1000000:return false
		for field in ["created","restore","span","height"]:
			if not (r.get(field) is int or r.get(field) is float) or not is_finite(r[field]):return false
		if r.created<0 or r.restore<=r.created or r.restore-r.created>1500.1 or r.span<4 or r.span>30 or r.height<2 or r.height>12:return false
		var b:=Plan.building(id)
		if not AABB(b.position-Vector3(b.size.x*.5,0,b.size.z*.5),b.size).grow(8).has_point(vector(r.position)):return false
		if absf(vector(r.direction).length()-1.0)>.02:return false
	return true
static func advance(records:Dictionary,now:float)->void:
	for id in records.keys():
		if now>=float(records[id].restore):records.erase(id)
static func phase(record:Dictionary,now:float)->String:
	var age:=now-float(record.created)
	if now>=float(record.restore):return "restored"
	if age<8:return "impact"
	if age<60:return "fire"
	if age<100:return "stabilize"
	return "rebuild"
static func progress(record:Dictionary,now:float)->float:
	return clampf((now-float(record.created)-100.0)/maxf(1.0,float(record.restore)-float(record.created)-100.0),0,1)
