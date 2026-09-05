class_name CityMonkeyModels
extends RefCounted
## Every cached vertex comes from the real MonkeyRig. No alternate body, face,
## limb or tail is authored here; only the rig's joint poses are changed.
const BASE_HEIGHT := MonkeyRig.NPC_MIN_HEIGHT
static var _poses: Dictionary = {}
static var _attachments: Dictionary = {}
static var _reports: Dictionary = {}

static func height_for(variation: int) -> float:
	return MonkeyRig.npc_height(str(variation))

static func pose(pose_name: String, _variation := 0, phase := 0) -> ArrayMesh:
	var name := canonical_pose(pose_name)
	var frame := posmod(phase,3 if name=="yoga" else 4)
	var key := name+":"+str(frame)
	if _poses.has(key): return _poses[key]
	var stage := Node3D.new()
	stage.name = "CanonicalMonkeyBake"
	stage.visible = false
	(Engine.get_main_loop() as SceneTree).root.add_child(stage)
	var rig := MonkeyRig.new()
	stage.add_child(rig)
	rig.setup("Crownreach resident",false)
	rig.set_standing_height(BASE_HEIGHT)
	rig.set_melee_pose(false,false,0,0)
	var anim := MonkeyRig.Anim.RUN if name in ["walk","carry"] else MonkeyRig.Anim.IDLE
	for i in range(32):
		rig._t = float(frame)*PI*.5
		rig.update_motion(.05,anim,Vector3.FORWARD*1.35 if anim==MonkeyRig.Anim.RUN else Vector3.ZERO,true,Vector3.ZERO)
	_pose_joints(rig,name,frame)
	var mesh := bake(rig)
	mesh.set_meta("canonical_model","MonkeyRig")
	mesh.set_meta("standing_height",BASE_HEIGHT)
	mesh.set_meta("pose",name)
	mesh.set_meta("phase",frame)
	_poses[key] = mesh
	_attachments[key] = _points(rig)
	_reports[key] = {"source":"MonkeyRig","height":BASE_HEIGHT,"surface_count":mesh.get_surface_count(),"vertices":_vertex_count(mesh),"body_meshes":mesh.get_meta("source_meshes",0)}
	stage.free()
	return mesh

static func canonical_pose(name: String) -> String:
	if name in ["firefighter","builder","standing","idle"]: return "talk"
	return name if name in ["walk","yoga","cycle","wave","talk","carry","hose","hammer"] else "talk"

static func attachment_points(pose_name: String, phase := 0) -> Dictionary:
	var name := canonical_pose(pose_name)
	var frame := posmod(phase,3 if name=="yoga" else 4)
	pose(name,0,frame)
	return _attachments[name+":"+str(frame)].duplicate()

static func report(pose_name: String, phase := 0) -> Dictionary:
	var name := canonical_pose(pose_name)
	var frame := posmod(phase,3 if name=="yoga" else 4)
	pose(name,0,frame)
	return _reports[name+":"+str(frame)].duplicate()

static func _pose_joints(rig: MonkeyRig, name: String, phase: int) -> void:
	var hands: Array[Vector3] = []
	if name in ["carry","hose"]:
		hands = [Vector3(-.29,1.10,-.48),Vector3(.29,1.10,-.48)]
	elif name == "wave":
		hands = [Vector3(-.60,1.68+sin(float(phase)*PI*.5)*.10,-.10),Vector3(.40,.98,0)]
	elif name == "hammer":
		hands = [Vector3(-.30,1.07,-.45),Vector3(.25,1.30+float(phase%2)*.40,-.45)]
	elif name == "cycle":
		rig.hips.position.y += .28
		rig.torso_p.rotation.x = -.28
		hands = [Vector3(-.37,1.25,-.57),Vector3(.37,1.25,-.57)]
		for side in [-1.0,1.0]:
			var angle := float(phase)*PI*.5+(PI if side>0 else 0.0)
			_leg(rig,side<0,Vector3(side*.14,.45+cos(angle)*.16,-.06+sin(angle)*.16))
	elif name == "yoga":
		if phase==0:
			hands = [Vector3(-.20,2.02,-.05),Vector3(.20,2.02,-.05)]
			_leg(rig,false,Vector3(-.08,.53,0))
		elif phase==1:
			hands = [Vector3(-.90,1.32,0),Vector3(.90,1.32,0)]
			_leg(rig,true,Vector3(-.43,.08,0))
			_leg(rig,false,Vector3(.43,.08,0))
		else:
			hands = [Vector3(-.10,1.30,-.35),Vector3(.10,1.30,-.35)]
	if hands.size()==2:
		rig._ik_limb(rig.sh_l,rig.el_l,MonkeyRig.ARM_A,MonkeyRig.ARM_B,hands[0],Vector3(-1,-.22,.62))
		rig._ik_limb(rig.sh_r,rig.el_r,MonkeyRig.ARM_A,MonkeyRig.ARM_B,hands[1],Vector3(1,-.22,.62))
	if name == "carry":
		# Existing tail joints curl out of the rump and around a real handle.
		rig.tail_segs[0].rotation = Vector3(-.50,-1.2,0)
		for i in range(1,rig.tail_segs.size()): rig.tail_segs[i].rotation.x = -.48

static func _leg(rig: MonkeyRig,left:bool,target:Vector3) -> void:
	rig._ik_limb(rig.hip_l if left else rig.hip_r,rig.kn_l if left else rig.kn_r,MonkeyRig.LEG_A,MonkeyRig.LEG_B,target,Vector3(-.72 if left else .72,-.12,-.82))

static func _points(rig: MonkeyRig) -> Dictionary:
	return {"hand_left":rig.paw_l.global_position,"hand_right":rig.paw_r.global_position,"foot_left":rig.foot_l.global_position,"foot_right":rig.foot_r.global_position,"tail_tip":rig.tail_segs[-1].global_transform*Vector3(0,0,.17),"head":rig.head_p.global_position,"pelvis":rig.hips.global_position}

static func bake(rig: MonkeyRig) -> ArrayMesh:
	var groups: Dictionary = {}
	var source_count := 0
	var stack: Array[Node] = [rig]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node != rig and node is Node3D and not node.visible: continue
		for child in node.get_children(): stack.append(child)
		if not node is MeshInstance3D or node.mesh == null: continue
		if node.mesh is ImmediateMesh or node.name=="WinterScarf": continue
		var transform: Transform3D = rig.global_transform.affine_inverse()*node.global_transform
		var normal_basis := transform.basis.inverse().transposed()
		for surface in range(node.mesh.get_surface_count()):
			var material: Material = node.material_override if node.material_override != null else node.mesh.surface_get_material(surface)
			var key := material.get_instance_id() if material != null else 0
			if not groups.has(key):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				st.set_material(material)
				groups[key] = st
			var st: SurfaceTool = groups[key]
			var arrays: Array = node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if indices.is_empty():
				for i in range(vertices.size()): indices.append(i)
			for i in indices:
				st.set_normal((normal_basis*normals[i]).normalized() if i<normals.size() else Vector3.UP)
				st.set_uv(uvs[i] if i<uvs.size() else Vector2.ZERO)
				st.set_color(colors[i] if i<colors.size() else Color.WHITE)
				st.add_vertex(transform*vertices[i])
		source_count += 1
	var result := ArrayMesh.new()
	for st: SurfaceTool in groups.values():
		st.index()
		st.commit(result)
	result.set_meta("source_meshes",source_count)
	return result

static func _vertex_count(mesh:ArrayMesh) -> int:
	var result := 0
	for i in range(mesh.get_surface_count()): result += mesh.surface_get_array_len(i)
	return result


class DriverControls extends RefCounted:
	var kind := Vehicle.Kind.JEEP
	var targets: Dictionary = {}
	func has_rider_target(key: StringName) -> bool: return targets.has(key)
	func rider_target_global(key: StringName) -> Vector3: return targets[key]

## A static seated pose retains the complete player anatomy and original
## materials. Vehicles share this exact bake instead of building a second body.
static func seated(config: Dictionary, height: float) -> Dictionary:
	var key := "driver:"+str(config.id)+":"+str(snappedf(height,.0001))
	if _poses.has(key): return {"mesh":_poses[key],"points":_attachments[key].duplicate(),"report":_reports[key].duplicate()}
	var stage := Node3D.new()
	stage.visible = false
	(Engine.get_main_loop() as SceneTree).root.add_child(stage)
	var rig := MonkeyRig.new()
	stage.add_child(rig)
	rig.setup("Crownreach driver",false)
	rig.set_standing_height(height)
	var controls := DriverControls.new()
	rig.set_vehicle_pose(controls)
	for i in range(40): rig.update_motion(.05,MonkeyRig.Anim.RIDE,Vector3.ZERO,true,Vector3.ZERO)
	# Adjust only the seat, never the model scale, to leave real head clearance.
	rig.torso_p.rotation.x = float(config.get("recline",-.15))
	rig.head_p.rotation.x = -rig.torso_p.rotation.x*.70
	var upright := bake(rig).get_aabb()
	var root_y := minf(float(config.seat.y)-.50,float(config.roof)-.045-upright.end.y)
	rig.position = Vector3(config.seat.x,root_y,config.seat.z)
	var pelvis := rig.hips.global_position
	var steering := pelvis+Vector3(0,.51,-float(config.get("wheel_reach",.51)))
	var pedals := pelvis+Vector3(0,-.40,-.48)
	pedals.y = maxf(.19,pedals.y)
	controls.targets = {&"hand_left":steering+Vector3(-.17,0,0),&"hand_right":steering+Vector3(.17,0,0),&"foot_left":pedals+Vector3(-.13,0,0),&"foot_right":pedals+Vector3(.13,0,0)}
	if config.has("targets"): controls.targets = config.targets.duplicate()
	rig._pose_vehicle_controls()
	var mesh := bake(rig)
	# bake() returns rig-local vertices; position the canonical mesh in car space.
	var points := _points(rig)
	var offset := rig.position
	mesh.set_meta("canonical_model","MonkeyRig")
	mesh.set_meta("standing_height",height)
	_poses[key] = mesh
	_attachments[key] = points
	_reports[key] = {"source":"MonkeyRig","standing_height":height,"source_meshes":mesh.get_meta("source_meshes"),"offset":offset,"bounds":AABB(mesh.get_aabb().position+offset,mesh.get_aabb().size),"pelvis":points.pelvis,"targets":controls.targets.duplicate()}
	stage.free()
	return {"mesh":mesh,"points":points.duplicate(),"report":_reports[key].duplicate()}
