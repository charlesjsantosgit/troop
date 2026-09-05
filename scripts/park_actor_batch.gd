class_name ParkActorBatch
extends Node3D
## Reusable instanced articulated actors. Emergency crews can use person() with
## their own route/pose without creating a complete scene rig for every citizen.
const Models=preload("res://scripts/city_monkey_models.gd")
const CAPACITY := 4096
const MONKEY_CAPACITY := 160
var _monkey_batches:Dictionary={}
var _monkey_items:Dictionary={}
var _monkey_count:=0
var _carry_grips:=0
var _batches: Dictionary = {}
var _items: Dictionary = {}
var _colors: Dictionary = {}
var _basis := Basis.IDENTITY
var _origin := Vector3.ZERO

func _ready() -> void:
	physics_interpolation_mode=Node.PHYSICS_INTERPOLATION_MODE_OFF
	var sphere := SphereMesh.new();sphere.radius=.5;sphere.height=1;sphere.radial_segments=10;sphere.rings=5
	var cylinder := CylinderMesh.new();cylinder.top_radius=.5;cylinder.bottom_radius=.5;cylinder.height=1;cylinder.radial_segments=7
	var box := BoxMesh.new();box.size=Vector3.ONE
	var wheel := TorusMesh.new();wheel.inner_radius=.31;wheel.outer_radius=.39;wheel.rings=14;wheel.ring_segments=6
	var material := StandardMaterial3D.new();material.vertex_color_use_as_albedo=true;material.roughness=.85
	for kind in ["sphere","limb","box","wheel"]:
		var mm := MultiMesh.new();mm.transform_format=MultiMesh.TRANSFORM_3D;mm.use_colors=true
		mm.mesh={"sphere":sphere,"limb":cylinder,"box":box,"wheel":wheel}[kind]
		mm.instance_count=CAPACITY;mm.visible_instance_count=0
		var node := MultiMeshInstance3D.new();node.name="ParkActors_"+kind;node.multimesh=mm;node.material_override=material
		node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.custom_aabb=AABB(Vector3(-1500,-5,-4500),Vector3(3000,50,9000))
		add_child(node);_batches[kind]=mm
		_items[kind]=[];_colors[kind]=[]

func begin_frame() -> void:
	_monkey_count=0;_carry_grips=0
	for key in _monkey_items: _monkey_items[key].clear()
	for kind in _items: _items[kind].clear();_colors[kind].clear()

func end_frame() -> void:
	for key in _monkey_batches:
		var mm:MultiMesh=_monkey_batches[key]
		mm.visible_instance_count=mini(MONKEY_CAPACITY,_monkey_items[key].size())
		for i in range(mm.visible_instance_count): mm.set_instance_transform(i,_monkey_items[key][i])
	for kind in _batches:
		var mm: MultiMesh=_batches[kind]
		var count:=mini(CAPACITY,_items[kind].size())
		for i in range(count): mm.set_instance_transform(i,_items[kind][i]);mm.set_instance_color(i,_colors[kind][i])
		mm.visible_instance_count=count

func _frame(at: Vector3, forward: Vector2) -> void:
	_origin=at
	_basis=Basis.looking_at(Vector3(forward.x,0,forward.y).normalized(),Vector3.UP) if forward.length_squared()>.01 else Basis.IDENTITY

func _part(kind: String,at: Vector3,size: Vector3,color: Color,basis:=Basis.IDENTITY) -> void:
	_items[kind].append(Transform3D((_basis*basis)*Basis.from_scale(size),_origin+_basis*at));_colors[kind].append(color)

func _bone(a: Vector3,b: Vector3,width: float,color: Color) -> void:
	var delta:=b-a
	var direction:=delta.normalized()
	var x:=Vector3.RIGHT.cross(direction).normalized() if absf(direction.x)<.9 else Vector3.FORWARD.cross(direction).normalized()
	var basis:=Basis(x,direction,x.cross(direction)).orthonormalized()
	_part("limb",(a+b)*.5,Vector3(width,delta.length(),width),color,basis)

static func pose_phase(pose:String,time:float)->int:
	var canonical:String=Models.canonical_pose(pose)
	if canonical=="talk":return 0
	return int(time/8)%3 if canonical=="yoga" else posmod(int(time*(8 if pose=="cycle" else 6)),4)

static func attachment_point(at:Vector3,forward:Vector2,pose:String,time:float,variation:int,key:String,offset:=Vector3.ZERO)->Vector3:
	var joints:=Models.attachment_points(pose,pose_phase(pose,time))
	var point:Vector3=(Vector3(joints.hand_left)+Vector3(joints.hand_right))*.5 if key=="hand_center" else Vector3(joints[key])
	var basis:=Basis.looking_at(Vector3(forward.x,0,forward.y).normalized(),Vector3.UP)
	return at+basis*(point+offset)*(Models.height_for(variation)/Models.BASE_HEIGHT)

func person(at: Vector3,forward: Vector2,pose: String,time: float,shirt: Color,variation:=0) -> void:
	# Body, face, hands and tail are literally baked MonkeyRig geometry. Props
	# below attach to that rig's measured joints and use the same uniform stature.
	var canonical:String=Models.canonical_pose(pose)
	var phase:=pose_phase(pose,time)
	var key:=canonical+":"+str(phase)
	if not _monkey_batches.has(key):
		var mm:=MultiMesh.new();mm.transform_format=MultiMesh.TRANSFORM_3D;mm.mesh=Models.pose(canonical,0,phase)
		mm.instance_count=MONKEY_CAPACITY;mm.visible_instance_count=0
		var node:=MultiMeshInstance3D.new();node.name="CanonicalMonkey_"+key.replace(":","_");node.multimesh=mm
		node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(node);_monkey_batches[key]=mm;_monkey_items[key]=[]
	_frame(at,forward)
	var stature:=Models.height_for(variation)/Models.BASE_HEIGHT
	_basis=_basis*Basis.from_scale(Vector3.ONE*stature)
	_monkey_items[key].append(Transform3D(_basis,at));_monkey_count+=1
	var joints:Dictionary=Models.attachment_points(canonical,phase)
	if pose=="cycle":
		_bicycle(time,shirt)
		_part("sphere",joints.head+Vector3(0,.16,0),Vector3(.46,.21,.42),shirt)
	elif pose in ["carry","hammer","builder","firefighter","hose"]:
		var fire:=pose in ["firefighter","hose"]
		var safety:=Color("d8b647") if fire else Color("ebc357")
		_part("sphere",joints.head+Vector3(0,.17,0),Vector3(.49,.20,.46),safety)
		_part("box",joints.head+Vector3(0,.09,-.04),Vector3(.56,.035,.56),safety)
		# An open reflective vest and helmet leave the canonical fur, face and
		# limbs intact instead of replacing them with another character body.
		_part("box",Vector3(-.21,1.10,-.165),Vector3(.075,.38,.035),safety)
		_part("box",Vector3(.21,1.10,-.165),Vector3(.075,.38,.035),safety)
		if fire:
			_part("limb",Vector3(0,1.05,.25),Vector3(.23,.52,.23),Color("454e4b"))
		if pose=="carry":
			var hands:Vector3=(Vector3(joints.hand_left)+Vector3(joints.hand_right))*.5
			for n in range(3): _part("box",hands+Vector3(0,.035+n*.09,-.025),Vector3(1.65,.085,.22),Color("b29566"))
			var tip:Vector3=joints.tail_tip
			# The end of the canonical curved tail passes through the handle.
			_part("box",tip+Vector3(0,-.29,0),Vector3(.43,.34,.28),Color("465f61"))
			_bone(tip+Vector3(-.13,-.15,0),tip+Vector3(-.13,.01,0),.035,Color("b8bba7"))
			_bone(tip+Vector3(.13,-.15,0),tip+Vector3(.13,.01,0),.035,Color("b8bba7"))
			_bone(tip+Vector3(-.13,.01,0),tip+Vector3(.13,.01,0),.035,Color("b8bba7"))
			_carry_grips+=1
		elif pose=="hammer":
			var hand:Vector3=joints.hand_right
			_bone(hand,hand+Vector3(0,.33,0),.045,Color("b2986c"))
			_part("box",hand+Vector3(0,.33,0),Vector3(.29,.11,.11),Color("798782"))
		elif pose=="hose":
			var grip:Vector3=(Vector3(joints.hand_left)+Vector3(joints.hand_right))*.5
			_bone(grip,grip+Vector3(0,0,-.35),.10,Color("454d42"))

func dog(at: Vector3,forward: Vector2,time: float,variation:=0) -> void:
	_frame(at,forward)
	var fur:Color=[Color("b29368"),Color("d2c8af"),Color("625a50"),Color("9b6547")][variation%4]
	_part("sphere",Vector3(0,.55,0),Vector3(.44,.46,1.0),fur)
	_part("sphere",Vector3(0,.76,-.57),Vector3(.40,.40,.38),fur)
	_part("sphere",Vector3(0,.67,-.82),Vector3(.26,.22,.35),fur.lightened(.1))
	_part("sphere",Vector3(0,.71,-1.0),Vector3(.10,.08,.08),Color("202923"))
	for side in [-1.0,1.0]:
		_part("sphere",Vector3(side*.19,.80,-.56),Vector3(.11,.34,.20),fur.darkened(.12))
		_part("sphere",Vector3(side*.105,.82,-.731),Vector3(.038,.045,.03),Color("18211b"))
		for end in [-1.0,1.0]:
			var stride:=sin(time*7+side*end*PI*.5)
			_bone(Vector3(side*.16,.52,end*.33),Vector3(side*.18,.11,end*.35+stride*.19),.10,fur)
	_bone(Vector3(0,.61,.44),Vector3(sin(time*6)*.22,.92,.91),.12,fur)

func leash(a: Vector3,b: Vector3) -> void:
	_frame(Vector3.ZERO,Vector2(0,-1));_bone(a,b,.018,Color("b99f65"))

func ball(at: Vector3) -> void:
	_frame(at,Vector2(0,-1));_part("sphere",Vector3.ZERO,Vector3.ONE*.20,Color("d7d34d"))

func _bicycle(time: float,color: Color) -> void:
	for z in [-.72,.72]:
		_part("wheel",Vector3(0,.39,z),Vector3.ONE,Color("263530"),Basis(Vector3.FORWARD,PI*.5))
		for spoke in range(4):
			var a:=time*6+spoke*PI*.25
			_bone(Vector3(0,.39+cos(a)*.32,z+sin(a)*.32),Vector3(0,.39-cos(a)*.32,z-sin(a)*.32),.018,Color("9ca8a1"))
	var rear:=Vector3(0,.39,.72);var front:=Vector3(0,.39,-.72);var crank:=Vector3(0,.48,0);var seat:=Vector3(0,1.01,.18);var neck:=Vector3(0,1.07,-.55)
	for edge in [[rear,crank],[rear,seat],[seat,crank],[seat,neck],[neck,crank],[neck,front]]: _bone(edge[0],edge[1],.055,color)
	_part("box",Vector3(0,1.03,.18),Vector3(.32,.12,.38),Color("333f37"))
	_bone(neck,Vector3(0,1.20,-.62),.05,Color("8e9992"));_bone(Vector3(-.36,1.20,-.62),Vector3(.36,1.20,-.62),.045,Color("8e9992"))

func stats() -> Dictionary:
	var count:=0
	for mm:MultiMesh in _batches.values(): count+=mm.visible_instance_count
	var active_monkey_batches:=0
	var canonical_surfaces:=0
	for mm:MultiMesh in _monkey_batches.values():
		if mm.visible_instance_count>0: active_monkey_batches+=1;canonical_surfaces+=mm.mesh.get_surface_count()
	return {"batches":_batches.size()+active_monkey_batches,"prop_batches":_batches.size(),"instances":count+_monkey_count,
		"monkey_instances":_monkey_count,"canonical_monkey_batches":active_monkey_batches,"canonical_material_draws":canonical_surfaces,
		"canonical_pose_cache":_monkey_batches.size(),"tail_grips":_carry_grips,"capacity_per_batch":CAPACITY}

func response_vehicle(at: Vector3, forward: Vector2, fire: bool, time: float) -> void:
	_frame(at,forward)
	var paint:=Color("b53129") if fire else Color("d5b249")
	var metal:=Color("9faeae")
	_part("box",Vector3(0,.92,0),Vector3(2.35,.45,7.4),Color("263633"))
	_part("box",Vector3(0,1.85,-1.8),Vector3(2.35,1.9,2.4),paint)
	_part("box",Vector3(0,1.92,1.25),Vector3(2.35,2.02,3.7),paint)
	_part("box",Vector3(0,2.16,-3.03),Vector3(2.08,.83,.025),Color("354b55"))
	_part("box",Vector3(0,.9,-3.76),Vector3(2.48,.3,.2),metal)
	_part("box",Vector3(0,.9,3.76),Vector3(2.48,.3,.2),metal)
	for side in [-1.0,1.0]:
		_part("box",Vector3(side*1.185,2.2,-1.7),Vector3(.025,.80,1.72),Color("354b55"))
		_part("box",Vector3(side*1.19,1.39,.5),Vector3(.025,.20,5.8),Color("e6dfb6"))
		for z in [-2.30,1.7,2.85]:
			_part("wheel",Vector3(side*1.13,.57,z),Vector3(1.40,1.40,1.05),Color("26302e"),Basis(Vector3.FORWARD,PI*.5))
			_part("sphere",Vector3(side*1.20,.57,z),Vector3(.11,.40,.40),metal)
		if fire:
			for z in [-.2,.7,1.6,2.5]:
				_part("box",Vector3(side*1.20,2.03,z),Vector3(.025,1.05,.79),metal.darkened(.12))
			_part("box",Vector3(side*.72,3.05,.8),Vector3(.065,.12,4.7),metal)
		else:
			_part("box",Vector3(side*1.205,2.0,1.5),Vector3(.025,.58,1.6),Color("eee5bb"))
	if fire:
		for z in range(10): _part("box",Vector3(0,3.05,-1.25+z*.43),Vector3(1.42,.065,.055),metal)
	for x in [-.65,.65]:
		var flash:=fposmod(time*3+(0 if x<0 else .5),1)<.5
		_part("box",Vector3(x,2.91,-1.88),Vector3(.62,.16,.25),Color("ff5551") if flash else Color("631c1b"))
		_part("box",Vector3(x,.99,-3.77),Vector3(.4,.22,.025),Color("f8efcc"))

func cone(at: Vector3) -> void:
	_frame(at,Vector2(0,-1))
	_part("box",Vector3(0,.035,0),Vector3(.48,.07,.48),Color("313934"))
	_part("limb",Vector3(0,.30,0),Vector3(.22,.57,.22),Color("e77936"))
	_part("limb",Vector3(0,.37,0),Vector3(.225,.11,.225),Color("ede7d4"))

func material_stack(at: Vector3,forward: Vector2) -> void:
	_frame(at,forward)
	for y in range(4):
		for x in range(3): _part("box",Vector3((x-1)*.32,.18+y*.19,0),Vector3(.29,.17,2.5),Color("b99a70"))
	for x in [-.34,.34]: _part("box",Vector3(x,.085,0),Vector3(.22,.12,2.8),Color("7c6a50"))

func segment(a: Vector3,b: Vector3,width: float,color: Color) -> void:
	_frame(Vector3.ZERO,Vector2(0,-1));_bone(a,b,width,color)
