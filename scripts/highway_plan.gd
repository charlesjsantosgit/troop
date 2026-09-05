class_name HighwayPlan
extends RefCounted
## Deterministic geometry shared by terrain, the physical road, maps and police.
## Units are metres and m/s; sign faces display mph.
const City = preload("res://scripts/city_plan.gd")
const LANE := 3.66
const MEDIAN_HALF := 2.44
const INNER_SHOULDER := 1.22
const OUTER_SHOULDER := 3.05
const HALF_WIDTH := MEDIAN_HALF + INNER_SHOULDER + LANE * 2.0 + OUTER_SHOULDER
const OUTER_LANE := MEDIAN_HALF + INNER_SHOULDER + LANE * 1.5
const DECK_Y := City.GROUND_Y + 10.0
const RADIUS := 550.0
const WEST := City.MIN_X - 250.0
const EAST := City.MAX_X + 250.0
const NORTH := City.MIN_Z - 250.0
const SOUTH := City.MAX_Z + 250.0
const SPACING := 20.0
const HASH_SIZE := 128.0
static var _roads: Array[Dictionary] = []
static var _access: Array[Dictionary] = []
static var _segments: Array[Dictionary] = []
static var _hash: Dictionary = {}
static var _ready := false

static func roads() -> Array[Dictionary]:
	_ensure()
	return _roads

static func access_points() -> Array[Dictionary]:
	_ensure()
	return _access

static func _ensure() -> void:
	if _ready: return
	_ready = true
	var ring := PackedVector3Array()
	var corners := [Vector2(EAST-RADIUS,NORTH+RADIUS),Vector2(EAST-RADIUS,SOUTH-RADIUS),Vector2(WEST+RADIUS,SOUTH-RADIUS),Vector2(WEST+RADIUS,NORTH+RADIUS)]
	for c in range(4):
		var center: Vector2 = corners[c]
		var start := -PI*.5 + c*PI*.5
		for i in range(45):
			var angle := start + i*PI*.5/44.0
			var p := center + Vector2(cos(angle),sin(angle))*RADIUS
			ring.append(Vector3(p.x,DECK_Y,p.y))
	ring.append(ring[0])
	_add_road("h-1","Crownreach Beltway",ring,HALF_WIDTH,"divided",55)
	var cross_x := City.MIN_X+26.0*City.STREET_SPACING.x
	_add_interchange("1","Westgate / Settlements",Vector2(WEST,0),Vector2.UP)
	_add_interchange("2","Northlight",Vector2(cross_x,NORTH),Vector2.RIGHT)
	_add_interchange("3","East Market",Vector2(EAST,0),Vector2.DOWN)
	_add_interchange("4","South Depot",Vector2(cross_x,SOUTH),Vector2.LEFT)
	# The settlement expressway joins the surface distributor west of Exit 1.
	# Signed terminal transitions make its two ends surface-road connections;
	# there is no unsignalled intersection on its controlled-access mainline.
	var trunk := PackedVector3Array()
	var start_x := 1020.0
	var end_x := WEST-360.0
	var count := ceili((end_x-start_x)/SPACING)
	for i in range(count+1):
		var x := lerpf(start_x,end_x,float(i)/count)
		var base := access_ground(x)
		var lift := 10.0*smoothstep(start_x,start_x+620.0,x)*(1.0-smoothstep(end_x-620.0,end_x,x))
		trunk.append(Vector3(x,base+lift+.06,0))
	_add_road("h-2","Westgate Expressway",trunk,HALF_WIDTH,"divided",65)
	_access.append({"id":"settlement","name":"Village / Town / Suburbs","position":Vector3(start_x,access_ground(start_x),0),"highway":"h-2","direction":Vector2.RIGHT})
	_index()

static func access_ground(x: float) -> float:
	return lerpf(3.25,City.GROUND_Y,clampf((x-930.0)/(City.MIN_X-930.0),0,1))

static func _add_road(id: String, label: String, points: PackedVector3Array, half_width: float, kind: String, mph: int) -> void:
	# Resample long tangent links as well as bends; mesh, collision and API all
	# use these same vertices, preventing a separate analytic driving surface.
	var dense := PackedVector3Array()
	for i in range(points.size()-1):
		var n := maxi(1,ceili(points[i].distance_to(points[i+1])/SPACING))
		for j in range(n): dense.append(points[i].lerp(points[i+1],float(j)/n))
	dense.append(points[-1])
	_roads.append({"id":id,"name":label,"points":dense,"half_width":half_width,"kind":kind,"mph":mph})

static func _add_interchange(id: String, label: String, center: Vector2, tangent: Vector2) -> void:
	var normal := Vector2(-tangent.y,tangent.x)
	var road := PackedVector3Array()
	# The inside end reaches the existing boundary street; the outside end
	# forms the public distributor. Both pass UNDER the elevated beltway.
	for side in [-1.0,1.0]:
		var p: Vector2 = center+normal*430.0*side
		road.append(Vector3(p.x,City.GROUND_Y+.06,p.y))
	_add_road("access-"+id,label,road,5.16,"local",25)
	_access.append({"id":id,"name":label,"position":Vector3(center.x,City.GROUND_Y,center.y),"highway":"h-1","direction":tangent})
	for direction in [-1.0,1.0]:
		for entering in [false,true]:
			var points := PackedVector3Array()
			# A 260 m parallel speed-change lane follows a 120 m taper. The
			# remainder is a curved, graded ramp to a surface STOP junction.
			var controls := [Vector3(-700,DECK_Y,OUTER_LANE),Vector3(-580,DECK_Y,OUTER_LANE+LANE),Vector3(-320,DECK_Y,OUTER_LANE+LANE),Vector3(-100,City.GROUND_Y+1.0,98),Vector3(0,City.GROUND_Y+.06,100)]
			if entering:
				controls.reverse()
				for p in range(controls.size()): controls[p].x=-controls[p].x
			# Smooth cubic segments retain the authored parallel lane and flat
			# terminal; Catmull-Rom tangents are bounded by the sample spacing.
			for segment in range(controls.size()-1):
				var a: Vector3=controls[maxi(segment-1,0)]
				var b: Vector3=controls[segment]
				var c: Vector3=controls[segment+1]
				var d: Vector3=controls[mini(segment+2,controls.size()-1)]
				var n:=maxi(2,ceili(b.distance_to(c)/10.0))
				for step in range(n):
					var p: Vector3=b.cubic_interpolate(c,a,d,float(step)/n)
					# Clamp elevation to the two connected road elevations.
					p.y=clampf(p.y,City.GROUND_Y+.06,DECK_Y)
					var at: Vector2 =center+tangent*p.x*direction+normal*p.z*direction
					points.append(Vector3(at.x,p.y,at.y))
			var final: Vector3=controls[-1]
			var end: Vector2 =center+tangent*final.x*direction+normal*final.z*direction
			points.append(Vector3(end.x,final.y,end.y))
			_add_road("ramp-%s-%s-%s"%[id,int(direction),"on" if entering else "off"],label+ (" entrance" if entering else " exit"),points,3.0,"ramp",35)

static func _index() -> void:
	for road in _roads:
		var points: PackedVector3Array=road.points
		var along:=0.0
		for i in range(points.size()-1):
			var a: Vector3=points[i]
			var b: Vector3=points[i+1]
			var entry: Dictionary={"road":road,"a":a,"b":b,"along":along,"index":i}
			along+=a.distance_to(b)
			var index:=_segments.size()
			_segments.append(entry)
			var margin:=float(road.half_width)+40.0
			var lo:=Vector2(minf(a.x,b.x)-margin,minf(a.z,b.z)-margin)
			var hi:=Vector2(maxf(a.x,b.x)+margin,maxf(a.z,b.z)+margin)
			for x in range(floori(lo.x/HASH_SIZE),floori(hi.x/HASH_SIZE)+1):
				for z in range(floori(lo.y/HASH_SIZE),floori(hi.y/HASH_SIZE)+1):
					var key:=Vector2i(x,z)
					if not _hash.has(key): _hash[key]=[]
					_hash[key].append(index)

static func road_sample(position: Vector3) -> Dictionary:
	_ensure()
	var point:=Vector2(position.x,position.z)
	var best: Dictionary={}
	var score:=INF
	for index in _hash.get(Vector2i(floori(point.x/HASH_SIZE),floori(point.y/HASH_SIZE)),[]):
		var segment: Dictionary=_segments[index]
		var a:=Vector2(segment.a.x,segment.a.z)
		var b:=Vector2(segment.b.x,segment.b.z)
		var direction: Vector2=(b-a).normalized()
		var t:=clampf((point-a).dot(b-a)/maxf((b-a).length_squared(),.001),0,1)
		var projected: Vector3=segment.a.lerp(segment.b,t)
		var distance:=point.distance_to(a.lerp(b,t))
		var road: Dictionary=segment.road
		var edge:=maxf(0.0,distance-float(road.half_width))
		var vertical:=absf(position.y-projected.y)
		var candidate:=edge+vertical*2.0
		if candidate>=score: continue
		score=candidate
		var lateral: float=(point-a.lerp(b,t)).dot(Vector2(-direction.y,direction.x))
		var travel: Vector2=direction
		if road.kind!="ramp" and lateral<0: travel=-direction
		best={"id":road.id,"name":road.name,"kind":road.kind,"position":projected,"distance":distance,"lateral":lateral,"half_width":road.half_width,"direction":travel,"tangent":direction,"speed_mph":road.mph,"speed_mps":float(road.mph)*.44704,"along":segment.along+segment.a.distance_to(projected),"on_road":edge<.15 and vertical<3.0,"segment":index}
	return best

static func posted_speed(position: Vector3) -> float:
	var sample:=road_sample(position)
	return float(sample.speed_mps) if sample.get("on_road",false) else 0.0

static func nearest_access(position: Vector3) -> Dictionary:
	_ensure()
	var result:Dictionary={}
	var distance:=INF
	for access in _access:
		var d:float=position.distance_squared_to(access.position)
		if d<distance:
			distance=d
			result=access.duplicate()
	if not result.is_empty():result["distance_m"]=sqrt(distance)
	return result

static func ground_sample(point: Vector2) -> Dictionary:
	_ensure()
	var best:=INF
	var elevation:=0.0
	var strength:=0.0
	for index in _hash.get(Vector2i(floori(point.x/HASH_SIZE),floori(point.y/HASH_SIZE)),[]):
		var segment:Dictionary=_segments[index]
		var a:=Vector2(segment.a.x,segment.a.z)
		var b:=Vector2(segment.b.x,segment.b.z)
		var t:=clampf((point-a).dot(b-a)/maxf((b-a).length_squared(),.001),0,1)
		var edge:=point.distance_to(a.lerp(b,t))-float(segment.road.half_width)
		# Ground stays below overpasses; only the real deck colliders carry cars.
		var y:=City.GROUND_Y
		if segment.road.id=="h-2":y=access_ground(point.x)
		if edge<best:
			best=edge
			elevation=y
			strength=1.0-smoothstep(4.0,36.0,edge)
	return {"weight":strength,"height":elevation,"distance":best}

static func reserved(point: Vector2, margin:=0.0) -> bool:
	return float(ground_sample(point).distance)<margin+8.0

static func route_guidance(position: Vector3) -> String:
	var sample:=road_sample(position)
	var access:=nearest_access(position)
	if sample.get("on_road",false):
		return "%s · %d MPH · %s %.1f km"%[sample.name,sample.speed_mph,access.name,float(access.distance_m)/1000.0]
	return "Highway access: %s · %.1f km"%[access.name,float(access.distance_m)/1000.0]

static func barrier_allowed(point: Vector3) -> bool:
	for access in access_points():
		if access.highway=="h-1" and Vector2(point.x-access.position.x,point.z-access.position.z).length()<740.0:return false
	return true
