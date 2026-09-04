extends SceneTree
## Independent model separation, real collision bodies and active work poses.
var passed := 0
var total := 0

class Site extends Node3D:
	var water_fx = null
	var local_player: Node3D
	func surface_height(_x: float, _z: float) -> float: return 0.0
	func surface_normal(_x: float, _z: float) -> Vector3: return Vector3.UP

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	total += 1
	passed += int(ok)
	print("PEDESTRIAN %s %s" % ["PASS" if ok else "FAIL", message])

func _run() -> void:
	var model = load("res://scripts/frontier_sim.gd").new()
	model.new_game(2026)
	var minimum := INF
	for id in model.state.citizens:
		var a: Dictionary = model.state.citizens[id]
		for other_id in model.state.citizens:
			var b: Dictionary = model.state.citizens[other_id]
			if id != other_id and a.planet == b.planet:
				minimum = minf(minimum,Vector2(a.position[0],a.position[1]).distance_to(Vector2(b.position[0],b.position[1])))
	check(minimum >= model.PEDESTRIAN_SPACING-0.0001,"new towns have separated physical spawn locations: %.4f m"%minimum)
	var started := Time.get_ticks_usec()
	minimum = INF
	for tick in range(240):
		model.tick(1.0)
		for id in model.state.citizens:
			var a: Dictionary = model.state.citizens[id]
			for other_id in model.state.citizens:
				var b: Dictionary = model.state.citizens[other_id]
				if id != other_id and a.planet == b.planet:
					minimum=minf(minimum,Vector2(a.position[0],a.position[1]).distance_to(Vector2(b.position[0],b.position[1])))
	check(minimum >= model.PEDESTRIAN_SPACING-0.001,"24 workers keep separation across 240 seconds: %.4f m"%minimum)
	check(int(model.state.metrics.work_completed)>20,"crowd continues real jobs without a town-wide deadlock: %d completed"%int(model.state.metrics.work_completed))
	print("PEDESTRIAN_MODEL_240_SECONDS_USEC ",Time.get_ticks_usec()-started)
	model.new_game(2026)
	for id in model.state.citizens.keys():
		if id not in ["mango","fern"]: model.state.citizens.erase(id)
	var a: Dictionary=model.state.citizens.mango
	var b: Dictionary=model.state.citizens.fern
	a.position=[-4.0,0.0]
	b.position=[4.0,0.0]
	minimum=INF
	for step in range(120):
		for worker in [a,b]:
			var target:=Vector2(4,0) if worker.id=="mango" else Vector2(-4,0)
			var moved: Vector2=model.pedestrian_step(worker,Vector2(worker.position[0],worker.position[1]),target,0.1)
			worker.position=[moved.x,moved.y]
			minimum=minf(minimum,Vector2(a.position[0],a.position[1]).distance_to(Vector2(b.position[0],b.position[1])))
	check(minimum>=model.PEDESTRIAN_SPACING-0.001,"opposite walkers pass with swept minimum separation %.4f m"%minimum)
	check(float(a.position[0])>3.8 and float(b.position[0]) < -3.8,"opposite walkers both reach their destinations")
	model.set_pedestrian_obstacles([{"position":Vector2(0,0),"radius":0.42,"planet":"earth"}])
	a.position=[-3.0,0.0]
	b.position=[20.0,20.0]
	minimum=INF
	for step in range(80):
		var moved:Vector2=model.pedestrian_step(a,Vector2(a.position[0],a.position[1]),Vector2(3,0),0.1)
		a.position=[moved.x,moved.y]
		minimum=minf(minimum,moved.length())
	check(minimum>=0.878 and float(a.position[0])>2.8,"authenticated player obstacle is avoided without stopping the route: %.4f m"%minimum)
	model.set_pedestrian_obstacles([])
	a.position=[-2.0,0.0]
	b.position=[0.0,0.0]
	a._job={}
	b._job={}
	var site:=Site.new()
	root.add_child(site)
	var ground:=StaticBody3D.new()
	var shape:=CollisionShape3D.new()
	var floor_shape:=BoxShape3D.new()
	floor_shape.size=Vector3(60,0.2,60)
	shape.shape=floor_shape
	shape.position.y=-0.1
	ground.add_child(shape)
	site.add_child(ground)
	var actor=load("res://scripts/frontier_citizen.gd").new()
	actor.configure("mango",model,site,"earth")
	site.add_child(actor)
	actor.build()
	var other=load("res://scripts/frontier_citizen.gd").new()
	other.configure("fern",model,site,"earth")
	site.add_child(other)
	other.build()
	for frame in range(3): await physics_frame
	check(actor is CharacterBody3D and actor.collision_layer==1 and actor.collision_mask==1 and not actor._body_shape.disabled,
		"resident has a real active capsule on the player's physics layer")
	a.position=[2.0,0.0]
	minimum=INF
	for frame in range(120):
		# Deliberately bypass steering: the real physics capsule must stop it.
		actor.move_and_collide(Vector3(0.025,0,0))
		await physics_frame
		minimum=minf(minimum,actor.global_position.distance_to(other.global_position))
	check(minimum>=0.675 and actor.position.x<0,"real capsules stop an attempted path through another citizen: %.4f m"%minimum)
	var player=load("res://scripts/player.gd").new()
	player.is_local=false
	player.world=site
	site.add_child(player)
	player.set_physics_process(false)
	player.position=Vector3(2,0,0)
	minimum=INF
	for frame in range(120):
		player.move_and_collide(Vector3(-0.025,0,0))
		await physics_frame
		minimum=minf(minimum,player.global_position.distance_to(other.global_position))
	check(minimum>=0.595 and player.position.x>0,"actual six-foot player capsule cannot walk through an NPC: %.4f m"%minimum)
	check(absf(player._collision_shape.shape.height-1.8288)<0.00001 and actor._body_shape.shape.height>=1.7018 and actor._body_shape.shape.height<=1.8796,
		"player remains 6ft and NPC collision dimensions stay within requested adult range")
	player.queue_free()
	other.queue_free()
	await process_frame
	a.position=[actor.position.x,actor.position.z]
	# Let the last locomotion stride finish before measuring planted work.
	for frame in range(60): actor.update_citizen(1.0/60.0,Vector3.INF)
	a.target=""
	a.destination=a.position.duplicate()
	a._job={"op":"plant","label":"Planting the nursery"}
	a.activity="Planting the nursery"
	a.work_remaining=100
	a.route=[]
	var max_stroke:=0.0
	var max_foot_drift:=0.0
	var hand:Vector3=actor.rig.paw_r.global_position
	var foot:Vector3=actor.rig.foot_l.global_position
	for frame in range(240):
		actor.update_citizen(1.0/60.0,Vector3.INF)
		max_stroke=maxf(max_stroke,hand.distance_to(actor.rig.paw_r.global_position))
		max_foot_drift=maxf(max_foot_drift,foot.distance_to(actor.rig.foot_l.global_position))
	check(actor._work_active and actor._pose_kind=="plant" and actor._work_tool.visible and max_stroke>0.15,
		"gardening uses a visible hand-held trowel and a planting stroke: %.4f m"%max_stroke)
	check(max_foot_drift<0.06,"gardening bends the knees while feet stay planted: %.4f m"%max_foot_drift)
	a._job={"op":"water","label":"Watering plants"}
	a.activity="Watering plants"
	for frame in range(90): actor.update_citizen(1.0/60.0,Vector3.INF)
	check(actor._watering_can.visible and not actor._work_tool.visible and actor._pose_kind=="water","watering has its own can and pouring gesture")
	a._job={"op":"inspect","label":"Checking crops"}
	a.activity="Checking crops"
	for frame in range(90): actor.update_citizen(1.0/60.0,Vector3.INF)
	check(actor._inspection_board.visible and not actor._watering_can.visible and actor._pose_kind=="inspect","inspection switches to a held clipboard")
	a.activity="Waiting for supplies"
	for frame in range(180): actor.update_citizen(1.0/60.0,Vector3.INF)
	check(not actor._work_active and not actor._work_tool.visible and not actor._watering_can.visible and absf(actor.rig.torso_p.rotation.x)<0.15,"blocked workers settle into calm upright waiting")
	site.queue_free()
	for frame in range(4): await process_frame
	print("FRONTIERPEDESTRIANTEST %d/%d %s"%[passed,total,"PASS" if passed==total else "FAIL"])
	quit(0 if passed==total else 1)
