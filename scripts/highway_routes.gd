class_name HighwayRoutes
extends RefCounted
## Directed lane graph. Only ramps link elevated roads to their distributors.
const Plan=preload("res://scripts/highway_plan.gd")
static var graph:AStar3D
static var lanes:Dictionary={}
static var nodes:Dictionary={}

static func ensure()->void:
	if graph!=null:return
	graph=AStar3D.new()
	for road in Plan.roads():
		var directions: Array=[1] if road.kind=="ramp" else [-1,1]
		for direction in directions:
			var source:PackedVector3Array=road.points
			var points:=PackedVector3Array()
			for i in range(source.size()):
				var tangent:Vector3=(source[mini(i+1,source.size()-1)]-source[maxi(i-1,0)]).normalized()
				var offset:float=0.0 if road.kind=="ramp" else Plan.OUTER_LANE if road.kind=="divided" else Plan.LANE*.5
				points.append(source[i]+Vector3(-tangent.z,0,tangent.x)*offset*direction)
			if direction<0:points.reverse()
			var ids:=PackedInt64Array()
			var key:=str(road.id)+":"+str(direction)
			for point in points:
				var id:=graph.get_available_point_id()
				graph.add_point(id,point)
				nodes[id]={"lane":key,"road":road.id,"kind":road.kind,"mph":road.mph}
				if not ids.is_empty():graph.connect_points(ids[-1],id,false)
				ids.append(id)
			if road.id=="h-1":graph.connect_points(ids[-1],ids[0],false)
			lanes[key]={"ids":ids,"points":points,"road":road,"direction":direction}
	for road in Plan.roads():
		if road.kind!="ramp":continue
		var parts:PackedStringArray=str(road.id).split("-")
		# A negative direction has a double '-' in the stable road ID.
		var direction:=-1 if str(road.id).contains("--1-") else 1
		var access_id:=parts[1]
		var lane:Dictionary=lanes[str(road.id)+":1"]
		var entering:=str(road.id).ends_with("-on")
		var main:Dictionary=lanes["h-1:"+str(direction)]
		var main_point:int=lane.ids[-1] if entering else lane.ids[0]
		var nearest:=_nearest_in(main,graph.get_point_position(main_point))
		if entering:graph.connect_points(main_point,nearest,false)
		else:graph.connect_points(nearest,main_point,false)
		var street_point:int=lane.ids[0] if entering else lane.ids[-1]
		for local_direction in [-1,1]:
			var street:Dictionary=lanes["access-"+access_id+":"+str(local_direction)]
			var near:=_nearest_in(street,graph.get_point_position(street_point))
			if entering:graph.connect_points(near,street_point,false)
			else:graph.connect_points(street_point,near,false)
	# H-2 ends at surface level; Exit 1 is the east distributor. The village
	# terminal turnaround remains beyond the end of its continuous median.
	for direction in [-1,1]:
		var trunk:Dictionary=lanes["h-2:"+str(direction)]
		var east_id:int=trunk.ids[-1] if direction>0 else trunk.ids[0]
		for local_direction in [-1,1]:
			var street:Dictionary=lanes["access-1:"+str(local_direction)]
			var near:=_nearest_in(street,graph.get_point_position(east_id))
			if direction>0:graph.connect_points(east_id,near,false)
			else:graph.connect_points(near,east_id,false)
	var westbound:Dictionary=lanes["h-2:-1"]
	var eastbound:Dictionary=lanes["h-2:1"]
	var last:int=westbound.ids[-1]
	for z in [-Plan.OUTER_LANE,Plan.OUTER_LANE]:
		var id:=graph.get_available_point_id()
		graph.add_point(id,Vector3(995,Plan.access_ground(995)+.06,z))
		nodes[id]={"lane":"terminal","road":"terminal","kind":"local","mph":25}
		graph.connect_points(last,id,false)
		last=id
	graph.connect_points(last,eastbound.ids[0],false)

static func _nearest_in(lane:Dictionary,point:Vector3)->int:
	var result: int=lane.ids[0]
	var distance:=INF
	for id in lane.ids:
		var d:=graph.get_point_position(id).distance_squared_to(point)
		if d<distance:distance=d;result=id
	return result

static func route(from:Vector3,to:Vector3)->PackedVector3Array:
	ensure()
	var start:=graph.get_closest_point(from)
	var end:=graph.get_closest_point(to)
	var result:=PackedVector3Array()
	if start<0 or end<0:return result
	var path:=graph.get_point_path(start,end)
	if path.is_empty():return result
	result.append(from)
	for point in path:
		if result[-1].distance_to(point)>.1:result.append(point)
	if result[-1].distance_to(to)>.1:result.append(to)
	return result

static func route_with_rules(from:Vector3,to:Vector3)->Dictionary:
	ensure()
	var start:=graph.get_closest_point(from)
	var end:=graph.get_closest_point(to)
	var ids:=graph.get_id_path(start,end)
	var points:=PackedVector3Array([from])
	var stops:=PackedInt32Array()
	var previous:Dictionary={}
	for id in ids:
		var info:Dictionary=nodes[id]
		var point:=graph.get_point_position(id)
		if points[-1].distance_to(point)>.1:points.append(point)
		if previous.get("kind","")=="ramp" and str(previous.get("road","")).ends_with("-off") and info.kind=="local":stops.append(maxi(0,points.size()-2))
		previous=info
	if not ids.is_empty() and points[-1].distance_to(to)>.1:points.append(to)
	return {"points":points,"stops":stops,"connected":not ids.is_empty()}

static func position(value:Variant)->Vector3:
	if value is Vector3:return value
	if value is Array and value.size()==3:return Vector3(float(value[0]),float(value[1]),float(value[2]))
	return Vector3.ZERO
