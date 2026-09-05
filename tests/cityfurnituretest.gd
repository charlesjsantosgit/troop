extends Node
const Plan=preload("res://scripts/city_plan.gd")
const Rooms=preload("res://scripts/city_interior.gd")
const Furniture=preload("res://scripts/city_furniture.gd")
const Motion=preload("res://scripts/city_furniture_motion.gd")
var checks:=0
var passed:=0
func check(ok:bool,label:String)->void:
	checks+=1
	if ok: passed+=1
	print("FURNITURE %s %s"%["PASS" if ok else "FAIL",label])
func run(main:Node)->void:
	var city:Node=main.frontier_controller.city
	var player:MonkeyPlayer=main.world.local_player
	player.test_mode=true
	var home:=Plan.building("crownreach-b24-24-l02")
	city._teleport(home.door+Vector3.UP*1.2)
	for index in range(600):
		if not city.arrival_pending():break
		await get_tree().physics_frame
	city.enter_building(home.id)
	for index in range(600):
		if not city.arrival_pending():break
		await get_tree().physics_frame
	for index in range(8):await get_tree().physics_frame
	var room:Node3D=city.interior
	check(is_instance_valid(room),"actual penthouse is loaded for collision audit")
	if not is_instance_valid(room):get_tree().quit(1);return
	var motion:=Motion.new()
	motion.setup(player,player.rig)
	print("FURNITURE_ENVELOPES ",motion.parts.size())
	var layout:=Rooms.furniture_layout(home)
	for id:String in layout:
		var item:=Furniture.world_item(layout[id],room.global_position)
		var path:=Motion.entry(item,item.position,float(item.yaw))
		var saved:=player.rig.global_transform
		var pose:=player.rig.furniture_pose_snapshot()
		var rest:Dictionary=Motion.sample(path,Motion.duration(path))
		var clear:=motion.clear_frame(rest)
		print("FURNITURE_REST ",id," root=",rest.root-room.global_position," blocker=",motion.last_blocker if not clear else "none")
		player.rig.global_transform=saved
		player.rig.restore_furniture_pose(pose)
		check(clear,id+" real rendered body and limbs clear its resting furniture")
		var safe:=motion.preflight(path)
		print("FURNITURE_PATH ",id," blocker=",motion.last_blocker if not safe else "none")
		check(safe,id+" entire entering path is swept and clear")
	await _audit_other_homes(player)
	await _authority_geometry(home,layout)
	_authority_packets(home)
	await _replica_geometry(player,room,home,layout)
	await _angular_obstruction(player,room)
	await _exit_pose_audit(city,player,room,layout)
	if not OS.get_cmdline_user_args().has("audit-only"):
		await _runtime_all_seats(city,player,room,layout)
		await _dynamic_obstructions(city,player,room,layout)
	print("CITYFURNITURETEST %d/%d %s"%[passed,checks,"PASS" if passed==checks else "FAIL"])
	get_tree().quit(0 if passed==checks else 1)

func _runtime_all_seats(city:Node,player:MonkeyPlayer,room:Node3D,layout:Dictionary)->void:
	for id:String in layout:
		var item:=Furniture.world_item(layout[id],room.global_position)
		city._teleport(item.position)
		for index in range(600):
			if not city.arrival_pending():break
			await get_tree().physics_frame
		for index in range(10):await get_tree().physics_frame
		player.rig.set_yaw(float(item.yaw))
		var result:Dictionary=city.request_action("use_furniture",{"id":id})
		check(result.get("ok",false) and player.furniture_active(),id+" starts through the real controller")
		if not player.furniture_active():
			print("FURNITURE_ENTRY_ERROR ",id," ",city.last_message," ",player.furniture_clearance_blocker)
			continue
		var frames:=0
		var clear:=true
		while player._anim()==Furniture.ENTER_SEAT and frames<720:
			await get_tree().physics_frame
			frames+=1
			clear=clear and player._furniture_motion.clear_frame(player._furniture_frame)
			clear=clear and player._furniture_motion.shapes.size()>=16
		check(frames<720 and clear and not player._furniture_path_blocked,id+" actual entry keeps all mesh envelopes clear and physical shapes active")
		if frames>=720:print("FURNITURE_RUNTIME_BLOCK ",id," ",player._furniture_motion.last_blocker)
		var exit:Dictionary=city.request_action("leave_furniture",{"target":0})
		check(exit.get("ok",false) and player._anim()==Furniture.RISE,id+" begins its checked rising route")
		frames=0
		while player.furniture_active() and frames<720:
			await get_tree().physics_frame
			frames+=1
			if player.furniture_active():clear=clear and player._furniture_motion.clear_frame(player._furniture_frame)
		check(not player.furniture_active() and clear,id+" leaves without any body/limb overlap and restores standing control")
		if not player.furniture_active():
			var standing_clear:=true
			for frame in range(15):
				await get_tree().physics_frame
				standing_clear=_standing_furniture_clear(player) and standing_clear
			check(standing_clear,id+" restored walking body and tail remain clear of furniture")
		if player.furniture_active():
			print("FURNITURE_EXIT_ERROR ",id," ",player.furniture_last_error)
			player.cancel_furniture()

func _audit_other_homes(player:MonkeyPlayer)->void:
	for housing in ["city_apartment","town_apartment","suburban_home","starter_home"]:
		var fixture:=Rooms.new()
		get_tree().root.add_child(fixture)
		fixture.position=Vector3(0,-620,0)
		fixture.build({"id":"fixture","tier":housing})
		for frame in range(3):await get_tree().physics_frame
		var motion:=Motion.new()
		motion.setup(player,player.rig)
		for id:String in Rooms.furniture_layout(fixture.property):
			var item:=Furniture.world_item(Rooms.furniture_layout(fixture.property)[id],fixture.global_position)
			var path:=Motion.entry(item,item.position,float(item.yaw))
			var clear:=motion.preflight(path)
			check(clear,housing+" "+id+" sweeps its full adult body clear of real cushions, walls and ceiling")
			if not clear:print("FURNITURE_HOME_BLOCK ",housing," ",id," ",motion.last_blocker)
		fixture.queue_free()
		for frame in range(3):await get_tree().physics_frame

func _obstacle(room:Node3D,at:Vector3)->StaticBody3D:
	var body:=StaticBody3D.new()
	body.name="MovingFurnitureObstruction"
	room.add_child(body)
	body.global_position=at
	var node:=CollisionShape3D.new()
	var box:=BoxShape3D.new()
	box.size=Vector3.ONE*0.14
	node.shape=box
	body.add_child(node)
	return body

func _frame_part(motion:RefCounted,frame:Dictionary,label:String)->Vector3:
	var saved:Transform3D=motion.rig.global_transform
	var pose:Array=motion.rig.furniture_pose_snapshot()
	var transforms:Array=motion.frame_shapes(frame)
	var result:=Vector3.ZERO
	for index in range(motion.parts.size()):
		if str(motion.parts[index].label).contains(label):result=transforms[index].origin;break
	motion.rig.global_transform=saved
	motion.rig.restore_furniture_pose(pose)
	return result

func _dynamic_obstructions(city:Node,player:MonkeyPlayer,room:Node3D,layout:Dictionary)->void:
	var item:=Furniture.world_item(layout.olive_west,room.global_position)
	city._teleport(item.position)
	for index in range(600):
		if not city.arrival_pending():break
		await get_tree().physics_frame
	for index in range(10):await get_tree().physics_frame
	var motion:=Motion.new()
	motion.setup(player,player.rig)
	var path:=Motion.entry(item,player.global_position,player.rig.rotation.y)
	var end:=Motion.sample(path,Motion.duration(path))
	var obstacle:=_obstacle(room,_frame_part(motion,end,"HeadShell"))
	for index in range(3):await get_tree().physics_frame
	var before:=player.global_position
	var rejected:Dictionary=city.request_action("use_furniture",{"id":"olive_west"})
	check(not rejected.get("ok",false) and not player.furniture_active() and player.global_position.distance_to(before)<0.02 and not player._collision_shape.disabled,
		"obstructed entry rejects before moving and retains standing collision")
	check(not player.furniture_last_error.is_empty(),"blocked entry explains how to clear the approach")
	obstacle.queue_free()
	for index in range(3):await get_tree().physics_frame
	city.request_action("use_furniture",{"id":"olive_west"})
	check(player.furniture_active(),"clear route starts after removing the obstruction")
	if not player.furniture_active():return
	obstacle=_obstacle(room,_frame_part(player._furniture_motion,end,"HeadShell"))
	for index in range(300):
		await get_tree().physics_frame
		if player._furniture_path_blocked:break
	var held:=player.global_position
	var held_time:=player._furniture_time
	var clear:bool=player._furniture_motion.clear_frame(player._furniture_frame)
	for index in range(15):await get_tree().physics_frame
	check(player._furniture_path_blocked and clear and player._furniture_motion.shapes.size()>=16 and player.global_position.is_equal_approx(held) and is_equal_approx(player._furniture_time,held_time),
		"new obstruction stops the moving head and full body at the last clear pose with active collision")
	obstacle.queue_free()
	for index in range(600):
		await get_tree().physics_frame
		if player._anim()==Furniture.SIT:break
	check(player._anim()==Furniture.SIT and not player._furniture_path_blocked,"entry resumes safely after a dynamic obstacle clears")
	var exit_path:=Motion.reverse(player._furniture_entry_path,Motion.duration(player._furniture_entry_path),item.exits[0])
	var standing:=Motion.sample(exit_path,Motion.duration(exit_path))
	obstacle=_obstacle(room,_frame_part(player._furniture_motion,standing,"HeadShell"))
	for index in range(3):await get_tree().physics_frame
	city.request_action("leave_furniture",{"target":0})
	check(player.furniture_active() and player._anim()==Furniture.SIT,"blocked exit leaves the seated player safely in place")
	obstacle.queue_free()
	for index in range(3):await get_tree().physics_frame
	city.request_action("leave_furniture",{"target":0})
	obstacle=_obstacle(room,_frame_part(player._furniture_motion,standing,"HeadShell"))
	for index in range(500):
		await get_tree().physics_frame
		if player._furniture_path_blocked:break
	check(player.furniture_active() and player._furniture_path_blocked and player._furniture_motion.clear_frame(player._furniture_frame),
		"an obstacle appearing during rising stops the body before contact")
	obstacle.queue_free()
	for index in range(600):
		await get_tree().physics_frame
		if not player.furniture_active():break
	check(not player.furniture_active() and not player._collision_shape.disabled,"cleared exit returns through checked poses and restores normal control")
	for frame in range(12):await get_tree().physics_frame
	city.request_action("use_furniture",{"id":"olive_west"})
	for frame in range(48):await get_tree().physics_frame
	var partial:bool=player.furniture_active() and player._anim()==Furniture.ENTER_SEAT
	player.ti.interact_just=true
	var partial_clear:=true
	for frame in range(600):
		await get_tree().physics_frame
		if not player.furniture_active():break
		partial_clear=player._furniture_motion.clear_frame(player._furniture_frame) and partial_clear
	check(partial and partial_clear and not player.furniture_active(),"physical E can cancel a partial entry by reversing clear joint poses to standing")
	for frame in range(12):await get_tree().physics_frame
	city.request_action("use_furniture",{"id":"olive_west"})
	for frame in range(600):
		await get_tree().physics_frame
		if player._anim()==Furniture.SIT:break
	if not player.furniture_active():check(false,"late approved-exit fixture is seated");return
	var approved:=Motion.reverse(player._furniture_entry_path,Motion.duration(player._furniture_entry_path),item.exits[0])
	obstacle=_obstacle(room,_frame_part(player._furniture_motion,Motion.sample(approved,Motion.duration(approved)),"HeadShell"))
	for frame in range(3):await get_tree().physics_frame
	var accepted:=player.rise_from_furniture(item.exits[0],approved)
	for frame in range(500):
		await get_tree().physics_frame
		if player._furniture_path_blocked:break
	check(accepted and player._anim()==Furniture.RISE and player._furniture_path_blocked and player._furniture_motion.clear_frame(player._furniture_frame),
		"obstacle arriving with a server-approved exit preserves RISE authority and holds a clear colliding pose")
	obstacle.queue_free()
	for frame in range(600):
		await get_tree().physics_frame
		if not player.furniture_active():break
	check(not player.furniture_active(),"late approved-exit obstruction clears without stranding the shared furniture state")

func _authority_geometry(home:Dictionary,layout:Dictionary)->void:
	var guard:=preload("res://scripts/city_furniture_authority.gd").new()
	add_child(guard)
	guard.prepare(home)
	for frame in range(3):await get_tree().physics_frame
	var clear:=true
	for id:String in layout:
		var item:Dictionary=layout[id]
		var path:=Motion.entry(item,item.position,float(item.yaw))
		clear=guard.check_path(home,path,Vector3.ZERO) and clear
		if not clear:print("FURNITURE_AUTH_BLOCK ",id," ",guard.fixtures.values()[0].motion.last_blocker)
	check(clear,"authority independently sweeps all19 routes against exact room geometry in a separate physics world")
	var bad:=Motion.entry(layout.olive_west,Vector3(4.65,0.06,4.31),0.0)
	check(not guard.check_path(home,bad,Vector3.ZERO),"authority rejects a forged approach starting through the real coffee table")
	var fixture:Dictionary=guard.fixtures.values()[0]
	check(fixture.motion.parts.size()==16 and fixture.room.find_children("*","CollisionShape3D",true,false).size()>80,
		"authority validation uses the complete player and real furniture shapes")
	guard.queue_free()
	for frame in range(3):await get_tree().physics_frame

func _advance_authority(authority:Node,peer:int,animation:int)->bool:
	var item:Dictionary=authority._furniture[peer]
	var total:=Motion.duration(item.motion_path)
	item.entered_msec=Time.get_ticks_msec()-roundi(total*1000.0)
	var clear:=true
	var count:=ceili(total*20.0)
	for index in range(count+1):
		var frame:=Motion.sample(item.motion_path,total*float(index)/float(count))
		item.packet_msec=Time.get_ticks_msec()-50
		clear=authority.validate_furniture_state(peer,frame.root,animation,frame.yaw) and clear
	return clear

func _authority_packets(home:Dictionary)->void:
	var authority:=preload("res://scripts/city_network.gd").new()
	var origin:Vector3=preload("res://scripts/city_network.gd").interior_origin(home)
	var item:=Furniture.world_item(Rooms.furniture_layout(home).olive_west,origin)
	check(not authority._furniture_action(21,"use_furniture",{"id":"olive_west"},item.position).ok,"a seat request requires the authority's established room")
	authority._interiors[21]=home.id
	authority._interiors[22]=home.id
	check(not authority._furniture_action(21,"use_furniture",{"id":"invented"},item.position).ok and not authority._furniture_action(21,"use_furniture",{"id":"olive_west"},item.position+Vector3.RIGHT*8).ok,
		"invented targets and remote activation are rejected")
	var accepted:Dictionary=authority._furniture_action(21,"use_furniture",{"id":"olive_west"},item.position)
	item=accepted.furniture
	check(accepted.ok and not authority._furniture_action(22,"use_furniture",{"id":"olive_west"},item.position).ok,"server claims one physical seat for one resident")
	check(not authority.validate_furniture_state(21,item.root,Furniture.SIT,item.yaw),"resting instantly cannot skip the approved entry animation")
	check(not authority.validate_furniture_state(21,item.position+Vector3.RIGHT*8,Furniture.ENTER_SEAT,item.yaw),"actor packets cannot teleport off the canonical approach")
	check(_advance_authority(authority,21,Furniture.ENTER_SEAT),"canonical sequential entry packets satisfy authority timing and path checks")
	check(authority.validate_furniture_state(21,item.root,Furniture.SIT,item.yaw) and not authority.validate_furniture_state(21,item.root,Furniture.SIT,item.yaw+PI),"resting heading is locked to the chair instead of rotating the body through its arms")
	check(not authority.validate_furniture_state(21,item.root,Furniture.SLEEP,item.yaw) and not authority.validate_furniture_state(22,item.root,Furniture.SIT,item.yaw),"wrong poses and an unclaimed peer cannot spoof occupied furniture")
	check(not authority.validate_furniture_state(21,item.position,MonkeyRig.Anim.IDLE,item.yaw),"ordinary movement cannot bypass the checked rising route")
	check(not authority._furniture_action(21,"leave_furniture",{"target":99},item.root).ok,"invented standing destinations are rejected")
	var exit:Dictionary=authority._furniture_action(21,"leave_furniture",{"target":0},item.root)
	check(exit.ok and not authority.validate_furniture_state(21,item.exits[0],MonkeyRig.Anim.IDLE,item.yaw),"an exit grant does not authorize instantaneous teleport to standing")
	check(_advance_authority(authority,21,Furniture.RISE),"canonical reverse motion remains accepted on the actor channel")
	check(authority.validate_furniture_state(21,item.exits[0],MonkeyRig.Anim.IDLE,item.yaw) and not authority._furniture.has(21),"finished physical rise releases the occupied seat")
	authority._furniture_action(22,"use_furniture",{"id":"olive_west"},item.position)
	authority.unregister_peer(22)
	check(authority._furniture.is_empty() and authority._remote_furniture.is_empty(),"disconnect removes occupation and replicated pose metadata")
	authority.free()

func _replica_geometry(player:MonkeyPlayer,room:Node3D,home:Dictionary,layout:Dictionary)->void:
	var authority:=preload("res://scripts/city_network.gd").new()
	var replica:=Puppet.new()
	replica.setup(22,"Furniture sweep replica")
	player.get_parent().add_child(replica)
	replica.set_process(false)
	check(not replica._apply_city_furniture_frame({}) and not replica.rig.visible,"replica waits for canonical pose metadata instead of drawing an unsafe fallback inside furniture")
	replica.rig.visible=true
	var motion:=Motion.new()
	motion.setup(player,replica.rig)
	var clear:=true
	var samples:=0
	for id:String in layout:
		authority._interiors[22]=home.id
		var item:=Furniture.world_item(layout[id],room.global_position)
		var result:Dictionary=authority._furniture_action(22,"use_furniture",{"id":id},item.position)
		var path:Array=result.furniture.motion_path
		var total:=Motion.duration(path)
		var count:=ceili(total*20.0)
		for index in range(count):
			var a:=Motion.sample(path,total*float(index)/float(count))
			var b:=Motion.sample(path,total*float(index+1)/float(count))
			var frame:Dictionary=authority.furniture_sample(22,a.root.lerp(b.root,0.5))
			clear=replica._apply_city_furniture_frame(frame) and clear
			clear=motion.clear_frame(frame) and clear
			samples+=1
		authority.unregister_peer(22)
	check(clear and samples>700,"actual shared Puppet projects packet interpolation onto collision-clear body poses for all19 furniture targets")
	print("FURNITURE_REPLICA_SAMPLES ",samples)
	authority.free()
	replica.queue_free()
	for frame in range(3):await get_tree().physics_frame

func _angular_obstruction(player:MonkeyPlayer,room:Node3D)->void:
	var motion:=Motion.new()
	motion.actor=player
	var shape:=BoxShape3D.new()
	shape.size=Vector3(0.80,0.10,0.10)
	motion.parts=[{"shape":shape,"sweep_shape":BoxShape3D.new(),"label":"rotation-only limb probe"}]
	var at:=room.to_global(Vector3(0,3,0))
	var before:=Transform3D(Basis.IDENTITY,at)
	var after:=Transform3D(Basis(Vector3.UP,PI*0.5),at)
	var obstacle:=_obstacle(room,at+Vector3(0.23,0,-0.23))
	for frame in range(3):await get_tree().physics_frame
	var a:Array[Transform3D]=[before]
	var b:Array[Transform3D]=[after]
	check(motion.clear_transforms(a) and motion.clear_transforms(b) and not motion.clear_transforms(b,a),
		"angular sweep rejects a thin obstacle between two clear limb endpoints even with zero root movement")
	obstacle.queue_free()
	for frame in range(3):await get_tree().physics_frame

func _standing_furniture_clear(player:MonkeyPlayer)->bool:
	var motion:=Motion.new()
	motion.setup(player,player.rig)
	var transforms:=motion.transforms_now()
	for index in range(motion.parts.size()):
		var query:=PhysicsShapeQueryParameters3D.new()
		query.shape=motion.parts[index].shape
		query.transform=transforms[index]
		query.exclude=[player.get_rid()]
		query.collision_mask=1
		query.margin=0.003
		for hit in player.get_world_3d().direct_space_state.intersect_shape(query,16):
			var body:CollisionObject3D=hit.collider
			var owner=body.shape_owner_get_owner(body.shape_find_owner(int(hit.shape)))
			if str(owner.name) in ["PenthouseFloor","MezzanineFloor"]:continue
			print("FURNITURE_STANDING_OVERLAP ",motion.parts[index].label," ",owner.name)
			return false
	return true

func _exit_pose_audit(city:Node,player:MonkeyPlayer,room:Node3D,layout:Dictionary)->void:
	for id:String in layout:
		var item:=Furniture.world_item(layout[id],room.global_position)
		city._teleport(item.exits[0])
		for frame in range(120):
			await get_tree().physics_frame
			if not city.arrival_pending():break
		player.rig.set_yaw(float(item.yaw))
		for frame in range(12):await get_tree().physics_frame
		check(_standing_furniture_clear(player),id+" ordinary walking pose fits the nominated standing exit")
