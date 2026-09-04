extends SceneTree
## Collision presentation follows the same authority paths in a sustained crowd.
class Site extends Node3D:
	var water_fx = null
	func surface_height(_x: float,_z: float) -> float: return 0.0
	func surface_normal(_x: float,_z: float) -> Vector3: return Vector3.UP

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var model=load("res://scripts/frontier_sim.gd").new()
	model.new_game(2026)
	var actors: Array=[]
	var fixture:=Node3D.new()
	root.add_child(fixture)
	for planet in ["earth","moon"]:
		var site:=Site.new()
		fixture.add_child(site)
		if planet=="moon":
			site.position=Vector3(500,20,0)
			site.rotation.z=0.2
		var floor_body:=StaticBody3D.new()
		var shape:=CollisionShape3D.new()
		var box:=BoxShape3D.new()
		box.size=Vector3(600,0.2,600)
		shape.shape=box
		shape.position.y=-0.1
		floor_body.add_child(shape)
		site.add_child(floor_body)
		for id in model.state.citizens:
			if model.state.citizens[id].planet!=planet: continue
			var actor=load("res://scripts/frontier_citizen.gd").new()
			actor.configure(id,model,site,planet)
			site.add_child(actor)
			actor.build()
			actors.append(actor)
	for frame in range(3): await physics_frame
	var minimum:=INF
	var peak_error:=0.0
	var final_error:=0.0
	var max_error_by_id:Dictionary={}
	var worst_pair:=""
	var worst_frame:=-1
	var normal_ok:=true
	for frame in range(5400):
		model.tick(1.0/60.0)
		for actor in actors:
			actor.update_citizen(1.0/60.0,Vector3(20000,0,0))
			var p:Array=model.state.citizens[actor.citizen_id].position
			var error:float=actor.position.distance_to(Vector3(p[0],0,p[1]))
			peak_error=maxf(peak_error,error)
			max_error_by_id[actor.citizen_id]=maxf(float(max_error_by_id.get(actor.citizen_id,0)),error)
			if frame==5399: final_error=maxf(final_error,error)
			normal_ok=normal_ok and actor.global_basis.y.normalized().dot(actor.get_parent().global_basis.y.normalized())>0.9999
		for i in range(actors.size()):
			for j in range(i+1,actors.size()):
				if actors[i]._planet!=actors[j]._planet: continue
				var distance:float=actors[i].global_position.distance_to(actors[j].global_position)
				if distance<minimum:
					minimum=distance
					worst_pair=actors[i].citizen_id+"/"+actors[j].citizen_id
					worst_frame=frame

		await physics_frame
	# Freeze authority samples: presentation must catch up, not remain in a jam.
	for frame in range(120):
		for actor in actors: actor.update_citizen(1.0/60.0,Vector3(20000,0,0))
		await physics_frame
	var settled_error:=0.0
	for actor in actors:
		var p:Array=model.state.citizens[actor.citizen_id].position
		settled_error=maxf(settled_error,actor.position.distance_to(Vector3(p[0],0,p[1])))
	var completed:int=model.state.metrics.work_completed
	print("CROWD_METRICS ",JSON.stringify({"workers":actors.size(),"seconds":90,"min_capsule_distance":minimum,"worst_pair":worst_pair,"worst_frame":worst_frame,"peak_sample_error":peak_error,"final_sample_error":final_error,"settled_sample_error":settled_error,"completed_jobs":completed,"normals":normal_ok,"max_error_by_id":max_error_by_id}))
	var ok:=minimum>=0.679 and normal_ok and final_error<2.1 and settled_error<0.1 and completed>10
	print("FRONTIERCROWDTEST ","PASS" if ok else "FAIL")
	fixture.queue_free()
	for frame in range(4): await process_frame
	quit(0 if ok else 1)
