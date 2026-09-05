extends RefCounted
## Shared authored trajectories plus conservative envelopes of the real rig meshes.
## The same path is approved by authority and sampled by local and remote actors.
const STEP := 1.0 / 45.0
const SKIN := 0.006
var actor: CharacterBody3D
var rig: MonkeyRig
var parts: Array[Dictionary] = []
var shapes: Array[CollisionShape3D] = []
var last_blocker := ""
var samples_checked := 0
var sweeps_checked := 0

static func key(at: Vector3, yaw: float, pose: String, seconds: float) -> Dictionary:
	return {"root":at,"yaw":yaw,"pose":pose,"seconds":seconds}

static func entry(item: Dictionary, from: Vector3, yaw: float) -> Array[Dictionary]:
	var start:=from
	start.y=maxf(start.y,float(item.position.y))
	var path: Array[Dictionary] = [key(start,yaw,"stand",0.0)]
	path[0]["floor"]=float(item.position.y)-0.06
	var approach: Vector3 = item.position
	path.append(key(approach,float(item.yaw),"stand",maxf(0.35,from.distance_to(approach)/1.35)))
	if item.mode == "bed":
		# A visible, folded-leg climb clears the mattress before the body turns
		# and lies down. The reverse sequence returns through the same bed edge.
		var edge: Vector3 = item.get("mount",approach)
		var climb_height:=float(item.get("climb_height",1.45))
		path.append(key(edge,float(item.get("mount_yaw",item.yaw)),"stand",0.35))
		path.append(key(edge+Vector3.UP*climb_height,float(item.get("mount_yaw",item.yaw)),"climb",0.65))
		path.append(key(Vector3(item.root.x,edge.y+climb_height,item.root.z),float(item.yaw),"climb",0.85))
		path.append(key(item.root,float(item.yaw),"bed",1.10))
	else:
		var mount: Vector3 = item.get("mount",approach)
		path.append(key(mount,float(item.yaw),"stand",maxf(0.3,approach.distance_to(mount)/1.25)))
		path.append(key(item.root,float(item.yaw),str(item.mode),1.15))
	return path

static func duration(path: Array) -> float:
	var total := 0.0
	for index in range(1,path.size()): total += float(path[index].seconds)
	return total

static func sample(path: Array, time: float) -> Dictionary:
	if path.is_empty(): return {}
	var a: Dictionary = path[0]
	for index in range(1,path.size()):
		var b: Dictionary = path[index]
		var seconds := maxf(float(b.seconds),0.001)
		if time<=seconds or index==path.size()-1:
			var f := smoothstep(0.0,seconds,clampf(time,0.0,seconds))
			var root: Vector3 = a.root.lerp(b.root,f)
			var values := MonkeyRig.furniture_pose_values(str(a.pose),str(b.pose),f)
			if a.has("values"):
				var end := MonkeyRig.furniture_pose_values(str(b.pose),str(b.pose),1.0)
				for field in values: values[field]=lerpf(float(a.values[field]),float(end[field]),f)
			# During an ordinary sit/rise the feet stay above the actual floor,
			# rather than cutting through it as knee flexion shortens the legs.
			if a.pose != "bed" and b.pose != "bed" and a.pose != "climb" and b.pose != "climb":
				var floor_y := float(path[0].get("floor",minf(float(path[0].root.y),float(path[1].root.y))-0.06))
				root.y=maxf(root.y,floor_y+0.035-MonkeyRig.furniture_sole_height(values))
			return {"root":root,"yaw":lerp_angle(float(a.yaw),float(b.yaw),f),
				"pose_a":str(a.pose),"pose_b":str(b.pose),"blend":f,"values":values}
		time -= seconds
		a=b
	return {"root":a.root,"yaw":a.yaw,"pose_a":a.pose,"pose_b":a.pose,"blend":1.0,
		"values":MonkeyRig.furniture_pose_values(a.pose,a.pose,1.0)}

static func nearest_time(path: Array, at: Vector3) -> Dictionary:
	var total := duration(path)
	var best := INF
	var best_time := 0.0
	var samples := maxi(1,ceili(total/0.035))
	for index in range(samples+1):
		var time := total*float(index)/float(samples)
		var distance: float = sample(path,time).root.distance_to(at)
		if distance<best:
			best=distance
			best_time=time
	return {"time":best_time,"distance":best}

static func reverse(path: Array, current_time: float, destination: Vector3) -> Array[Dictionary]:
	var current := sample(path,current_time)
	# A sampled partial key preserves the actual intermediate pose on cancel.
	var result: Array[Dictionary] = [key(current.root,current.yaw,"stand",0.0)]
	result[0]["values"] = current.values
	result[0]["floor"]=float(path[0].get("floor",0.0))
	var times: Array[float] = [0.0]
	for index in range(1,path.size()): times.append(times[-1]+float(path[index].seconds))
	var previous := current_time
	for index in range(path.size()-1,-1,-1):
		if times[index]>=current_time-0.001: continue
		var point: Dictionary = path[index].duplicate(true)
		point.seconds=maxf(0.15,previous-times[index])
		result.append(point)
		previous=times[index]
	result.append(key(destination,float(path[0].yaw),"stand",maxf(0.3,destination.distance_to(path[0].root)/1.35)))
	return result

func setup(body: CharacterBody3D, visual: MonkeyRig) -> void:
	parts.clear()
	actor=body
	rig=visual
	var groups := {}
	for child in rig.find_children("*","MeshInstance3D",true,false):
		if not child.get_meta("anatomical_mesh",false) or not child.is_visible_in_tree() or child.mesh==null: continue
		var parent: Node3D = child.get_parent()
		var bounds: AABB = child.transform*child.mesh.get_aabb()
		if groups.has(parent): groups[parent]=groups[parent].merge(bounds)
		else: groups[parent]=bounds
	for parent: Node3D in groups:
		var bounds: AABB = groups[parent]
		var shape := BoxShape3D.new()
		shape.size = bounds.size*parent.global_basis.get_scale().abs()
		parts.append({"node":parent,"bounds":bounds,"shape":shape,"sweep_shape":BoxShape3D.new(),"label":str(parent.name)+" "+",".join(parent.get_children().filter(func(child):return child is MeshInstance3D).map(func(child):return str(child.name)))})

func frame_shapes(frame: Dictionary) -> Array[Transform3D]:
	rig.global_position=frame.root
	rig.apply_furniture_pose(frame)
	return transforms_now()

func transforms_now()->Array[Transform3D]:
	var result: Array[Transform3D] = []
	for part in parts:
		var node: Node3D = part.node
		result.append(Transform3D(node.global_basis.orthonormalized(),node.to_global(part.bounds.get_center())))
	return result

func clear_frame(frame: Dictionary, previous: Array[Transform3D]=[]) -> bool:
	return clear_transforms(frame_shapes(frame),previous)

func clear_transforms(transforms:Array[Transform3D],previous:Array[Transform3D]=[])->bool:
	var space := actor.get_world_3d().direct_space_state
	samples_checked += 1
	for index in range(parts.size()):
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape=parts[index].shape
		query.transform=transforms[index]
		query.collision_mask=actor.collision_mask
		query.exclude=[actor.get_rid()]
		query.margin=SKIN
		var hits := space.intersect_shape(query,1)
		if not hits.is_empty():
			var obstacle:CollisionObject3D=hits[0].collider
			var owner=obstacle.shape_owner_get_owner(obstacle.shape_find_owner(int(hits[0].shape)))
			last_blocker=parts[index].label+" / "+str(owner.name)+" "+str(owner.position)
			return false
		if not previous.is_empty():
			var rotation:Quaternion=previous[index].basis.get_rotation_quaternion().inverse()*transforms[index].basis.get_rotation_quaternion()
			var angle:=rotation.get_angle()
			if angle>PI:angle=TAU-angle
			var axis:=rotation.get_axis().normalized()
			var extent:float=parts[index].shape.size.length()*0.5*angle
			# Rotation around vertical does not expand vertically. An isotropic
			# margin falsely rejects grounded feet while a standing actor turns.
			var expansion:=Vector3(sqrt(maxf(0.0,1.0-axis.x*axis.x)),sqrt(maxf(0.0,1.0-axis.y*axis.y)),sqrt(maxf(0.0,1.0-axis.z*axis.z)))*extent
			parts[index].sweep_shape.size=parts[index].shape.size+expansion*2.0
			query.shape=parts[index].sweep_shape
			query.transform=previous[index]
			query.motion=transforms[index].origin-previous[index].origin
			query.margin=SKIN
			# cast_motion ignores starting overlaps, so explicitly inspect the
			# expanded angular envelope before sweeping its translation.
			var angular_hits:=space.intersect_shape(query,1)
			if not angular_hits.is_empty():
				var obstacle:CollisionObject3D=angular_hits[0].collider
				var owner=obstacle.shape_owner_get_owner(obstacle.shape_find_owner(int(angular_hits[0].shape)))
				last_blocker=parts[index].label+" angular sweep / "+str(owner.name)+" pos="+str(query.transform.origin)+" size="+str(query.shape.size)+" angle="+str(angle)+" axis="+str(axis)
				return false
			var fractions := space.cast_motion(query)
			sweeps_checked += 1
			if fractions.size()>=2 and fractions[0]<0.999:
				last_blocker=parts[index].label+" swept path"
				return false
	return true

func preflight(path: Array,from_current:bool=false) -> bool:
	if parts.size()<12 or path.size()<2:
		last_blocker="The complete body collision model is not ready."
		return false
	var saved := rig.global_transform
	var saved_pose := rig.furniture_pose_snapshot()
	var previous: Array[Transform3D] = []
	if from_current:
		previous=transforms_now()
		# Standing physics rests exactly on the floor. Sweep the tiny authored
		# sole-clearance lift first, then check angular motion above that contact.
		# Starting floor contact is never mistaken for furniture penetration.
		var lift:Vector3=sample(path,0.0).root-rig.global_position
		var space:=actor.get_world_3d().direct_space_state
		for index in range(parts.size()):
			var query:=PhysicsShapeQueryParameters3D.new()
			query.shape=parts[index].shape
			query.transform=previous[index]
			query.motion=lift
			query.collision_mask=actor.collision_mask
			query.exclude=[actor.get_rid()]
			query.margin=SKIN
			var fraction:=space.cast_motion(query)
			if fraction.size()>=2 and fraction[0]<0.999:
				last_blocker=parts[index].label+" standing clearance lift"
				return false
			previous[index].origin+=lift
		# Subdivide the real skeleton's initial blend. A single large angular
		# bound is needlessly broad around grounded feet and nearby desk edges.
		frame_shapes(sample(path,0.0))
		var target_pose:=rig.furniture_pose_snapshot()
		rig.global_transform=saved
		rig.global_position+=lift
		for step in range(1,17):
			var blend:Array[Transform3D]=[]
			for index in range(saved_pose.size()):blend.append(saved_pose[index].interpolate_with(target_pose[index],float(step)/16.0))
			rig.restore_furniture_pose(blend)
			var transforms:=transforms_now()
			if not clear_transforms(transforms,previous):
				rig.global_transform=saved
				rig.restore_furniture_pose(saved_pose)
				last_blocker+=" initial posture blend"
				return false
			previous=transforms

	var total := duration(path)
	var count := maxi(1,ceili(total/STEP))
	var okay := true
	for index in range(count+1):
		var frame := sample(path,total*float(index)/float(count))
		if not clear_frame(frame,previous):
			last_blocker+=" at t=%.3f"%(total*float(index)/float(count))
			okay=false
			break
		previous=frame_shapes(frame)
	rig.global_transform=saved
	rig.restore_furniture_pose(saved_pose)
	return okay

func activate(frame: Dictionary) -> void:
	var transforms := frame_shapes(frame)
	for index in range(parts.size()):
		var collision := CollisionShape3D.new()
		collision.name="FurnitureBody_"+parts[index].label
		collision.shape=parts[index].shape
		actor.add_child(collision)
		collision.global_transform=transforms[index]
		shapes.append(collision)

func update_colliders(frame: Dictionary) -> void:
	var transforms := frame_shapes(frame)
	for index in range(shapes.size()): shapes[index].global_transform=transforms[index]

func release() -> void:
	for shape in shapes:
		if is_instance_valid(shape):
			shape.disabled=true
			shape.queue_free()
	shapes.clear()

static func bake(path:Array)->Dictionary:
	var positions:=PackedVector3Array()
	var times:=PackedFloat32Array()
	var total:=duration(path)
	var count:=maxi(1,ceili(total*30.0))
	for index in range(count+1):
		var time:=total*float(index)/float(count)
		positions.append(sample(path,time).root)
		times.append(time)
	return {"positions":positions,"times":times}

static func nearest_baked(baked:Dictionary,at:Vector3,preferred_time:float=-1.0)->Dictionary:
	var positions:PackedVector3Array=baked.positions
	var times:PackedFloat32Array=baked.times
	var best:=INF
	var time:=0.0
	for index in range(positions.size()-1):
		var delta:=positions[index+1]-positions[index]
		var ratio:=clampf((at-positions[index]).dot(delta)/maxf(delta.length_squared(),0.000001),0.0,1.0)
		if delta.length_squared()<0.000001 and preferred_time>=0.0:
			ratio=clampf((preferred_time-times[index])/maxf(times[index+1]-times[index],0.000001),0.0,1.0)
		var candidate:=lerpf(times[index],times[index+1],ratio)
		var distance:=at.distance_to(positions[index].lerp(positions[index+1],ratio))
		if distance<best-0.00001 or (absf(distance-best)<=0.00001 and preferred_time>=0.0 and absf(candidate-preferred_time)<absf(time-preferred_time)):
			best=distance
			time=candidate
	return {"time":time,"distance":best}
