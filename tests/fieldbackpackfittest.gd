extends SceneTree
## Submitted tail vertices against actual pack boxes across bounded live poses.
class Wearer extends Node3D:
	var rig: Node3D
var failed:=false
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var actor:=Wearer.new()
	root.add_child(actor)
	actor.rig=load("res://scripts/monkey_rig.gd").new()
	actor.add_child(actor.rig)
	actor.rig.setup("Gear clearance",true)
	actor.rig.set_standing_height(1.8288)
	actor.rig.set_melee_pose(false,false,0,0)
	var gear=load("res://scripts/field_backpack.gd").fit_to(actor,false)
	if "baseline" in OS.get_cmdline_user_args():
		gear.get_node("Canvas").mesh.size=Vector3(0.37,0.43,0.20)
		gear.get_node("Canvas").position=Vector3(0,0.22,0.23)
		gear.get_node("Bedroll").position=Vector3(0,-0.035,0.25)
	var boxes:Array=[]
	for mesh:MeshInstance3D in gear.find_children("*","MeshInstance3D",true,false): boxes.append(mesh)
	var anatomy:Array=[]
	for mesh:MeshInstance3D in actor.rig.find_children("*","MeshInstance3D",true,false):
		if mesh.name.begins_with("Tail") or mesh.name=="HeadShell":
			anatomy.append({"mesh":mesh,"vertices":mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]})
	var report:Dictionary={}
	for mode in ["idle","walking","sliding_crouch","garden_crouch"]:
		var penetrations:=0
		var details:Dictionary={}
		var frames:int=1080 if mode=="idle" else 360
		for frame in range(frames):
			var moving:bool=mode=="walking"
			actor.rig.update_motion(1.0/60.0,1 if moving else 7 if mode=="sliding_crouch" else 0,Vector3(0,0,2 if moving else 0),true,Vector3.ZERO)
			if mode=="garden_crouch":
				actor.rig.hips.position.y=0.38
				actor.rig.torso_p.rotation.x=-0.36-sin(frame/60.0*2.3)*0.06
			if frame%6!=0: continue
			for part:Dictionary in anatomy:
				for box:MeshInstance3D in boxes:
					var transform:Transform3D=box.global_transform.affine_inverse()*part.mesh.global_transform
					var bounds:AABB=box.mesh.get_aabb().grow(0.002)
					if not bounds.intersects(transform*part.mesh.mesh.get_aabb()):continue
					for vertex:Vector3 in part.vertices:
						if bounds.has_point(transform*vertex):
							penetrations+=1
							details[str(part.mesh.name)+"/"+str(box.name)]=true
			report[mode]={"penetrating_vertices":penetrations,"pairs":details.keys()}
		failed=failed or penetrations>0
	print("FIELDBACKPACKFIT_METRICS ",JSON.stringify(report))
	print("FIELDBACKPACKFITTEST ","FAIL" if failed else "PASS")
	actor.queue_free()
	for frame in range(3):await process_frame
	quit(1 if failed else 0)
