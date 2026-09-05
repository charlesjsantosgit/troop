extends RefCounted
## A walkable double-height residence. Furniture is merged by material; the
## collision layout remains independent of its rounded upholstered surfaces.
const Furniture = preload("res://scripts/city_furniture.gd")
const Materials = preload("res://scripts/city_penthouse_materials.gd")
const SIZE := Vector3(26.0, 8.0, 22.0)
const MEZZANINE_Y := 4.0
const STAIR_BOTTOM := Vector3(10.8, 0.0, 4.0)
const STAIR_TOP := Vector3(10.8, 4.0, -5.0)
const STAIR_STEPS := 22
const CREAM := Color("ddd6c8")
const IVORY := Color("e9e2d5")
const OLIVE := Color("687155")
const OAK := Color("b79b74")
const WALNUT := Color("66503c")
const STONE := Color("c6c0b2")
const BRONZE := Color("89734f")
const IRON := Color("333b3e")
const WARM := Color("ffe3b3")

var _room: Node3D
var _body: StaticBody3D
var _batches: Dictionary = {}
var _mats: Dictionary = {}
var _lights: Array[OmniLight3D] = []
var _base_energies: Array[float] = []
var _box_mesh: BoxMesh
var _sphere_mesh: SphereMesh
var _cylinder_mesh: CylinderMesh
var _padded_mesh: ArrayMesh
var _primitive_count := 0
var _furniture_collision_scope := ""
var _furniture_id := ""

static func dimensions() -> Vector3: return SIZE
static func spawn_point() -> Vector3: return Vector3(0, 0.06, -9.4)
static func exit_point() -> Vector3: return Vector3(0, 0.85, -12.35)

static func service_layout() -> Dictionary:
	return {
		"exit":{"position":exit_point(),"prompt":"Return outside","kind":"exit"},
		"bed":{"position":Vector3(-6.1,0.8,7),"prompt":"Make this your home","kind":"bed"},
		"storage":{"position":Vector3(-10.9,0.8,-6),"prompt":"Open penthouse storage","kind":"storage"},
		"workbench":{"position":Vector3(4.8,0.8,-8.4),"prompt":"Penthouse details and local notices","kind":"interior"},
	}

static func validation_layout() -> Dictionary:
	return {"dimensions":SIZE,"ground_y":0.0,"mezzanine_y":MEZZANINE_Y,
		"stair_bottom":STAIR_BOTTOM,"stair_top":STAIR_TOP,"stair_steps":STAIR_STEPS,
		"captures":{
			"living":{"position":Vector3(0.5,1.7,0),"target":Vector3(5.2,2.5,6.5),"fov":66.0},
			"city":{"position":Vector3(1.65,1.7,10.6),"target":Vector3(1.65,-140,200),"fov":70.0},
			"bedroom":{"position":Vector3(-3.8,1.65,4.2),"target":Vector3(-8.2,1.15,7.2)},
			"mezzanine":{"position":Vector3(5.8,5.8,-5.5),"target":Vector3(4.4,2.3,6),"fov":68.0},
		}}

func build(room: Node3D, body: StaticBody3D) -> void:
	_room = room
	_body = body
	_box_mesh = BoxMesh.new()
	_box_mesh.size = Vector3.ONE
	_sphere_mesh = SphereMesh.new()
	_sphere_mesh.radius = 0.5
	_sphere_mesh.height = 1.0
	_sphere_mesh.radial_segments = 16
	_sphere_mesh.rings = 8
	_cylinder_mesh = CylinderMesh.new()
	_cylinder_mesh.top_radius = 0.5
	_cylinder_mesh.bottom_radius = 0.5
	_cylinder_mesh.height = 1.0
	_cylinder_mesh.radial_segments = 16
	_padded_mesh = _make_padded_mesh()
	for spec in Furniture.penthouse_chairs():
		_furniture_id=spec.id
		_chair(spec.center,OLIVE if spec.olive else CREAM,float(spec.yaw),float(spec.width))
	_architecture()
	_stairs_and_mezzanine()
	_living_room()
	_kitchen_and_dining()
	_bedroom()
	_entrance_and_study()
	_lighting()
	_flush()
	_sign("HOME", Vector3(-6.1,0.43,7.868), PI)
	_sign("STORAGE", Vector3(-11.72,1.55,-6), PI * 0.5)
	_sign("RESIDENCE", Vector3(4.8,1.25,-9.44), 0.0)
	_sign("OUTSIDE", Vector3(0,2.04,-12.88), 0.0)
	_room.set_meta("penthouse_primitive_count", _primitive_count)
	_room.set_meta("penthouse_collision_shapes", _body.get_child_count())
	update_time(13.0, 1.0)

func update_time(_hour: float, daylight: float) -> void:
	for index in range(_lights.size()):
		if is_instance_valid(_lights[index]):
			_lights[index].light_energy = _base_energies[index] * lerpf(1.10, 0.82, clampf(daylight, 0, 1))

func _architecture() -> void:
	_box("oak", OAK, Vector3(26,0.28,22), Vector3(0,-0.14,0), true, "PenthouseFloor")
	_box("plaster", IVORY, Vector3(26,0.20,22), Vector3(0,8.1,0), true, "PenthouseCeiling")
	# Solid front wall is split around the real entrance. Rear and both sides
	# are actual transparent glass with thin, full-height physical barriers.
	for side in [-1.0,1.0]:
		_box("plaster", IVORY, Vector3(12.1,8,0.20), Vector3(side*6.95,4,-11), true)
		_box("walnut", WALNUT, Vector3(0.11,2.5,0.28), Vector3(side*0.94,1.25,-11))
	_box("plaster", IVORY, Vector3(1.8,5.5,0.20), Vector3(0,5.25,-11), true)
	_box("glass", Color.WHITE, Vector3(25.9,7.86,0.045), Vector3(0,3.97,11), true, "RearGlazing")
	for side in [-1.0,1.0]:
		_box("glass", Color.WHITE, Vector3(0.045,7.86,21.95), Vector3(side*13,3.97,0), true, "SideGlazing")
		for z in [-11.0,-7.35,-3.7,0.0,3.7,7.35,11.0]:
			_box("bronze", BRONZE, Vector3(0.085,8,0.075), Vector3(side*12.98,4,z))
		for y in [0.10,3.98,7.93]:
			_box("bronze", BRONZE, Vector3(0.09,0.075,22), Vector3(side*12.98,y,0))
	for x in [-13.0,-9.75,-6.5,-3.25,0.0,3.25,6.5,9.75,13.0]:
		_box("bronze", BRONZE, Vector3(0.075,8,0.085), Vector3(x,4,10.98))
	for y in [0.10,3.98,7.93]:
		_box("bronze", BRONZE, Vector3(26,0.075,0.09), Vector3(0,y,10.98))
	# Grounded, enclosed landing outside the front opening.
	_box("oak", OAK, Vector3(2.4,0.28,2.2), Vector3(0,-0.14,-12.1), true, "VestibuleFloor")
	for side in [-1.0,1.0]:
		_box("plaster", IVORY, Vector3(0.16,3,2.2), Vector3(side*1.2,1.5,-12.1), true)
	_box("walnut", WALNUT, Vector3(2.4,3,0.15), Vector3(0,1.5,-13.2), true)
	_box("plaster", IVORY, Vector3(2.4,0.15,2.2), Vector3(0,3.08,-12.1))
	_box("bronze", BRONZE, Vector3(0.055,0.35,0.09), Vector3(0.72,1.08,-13.08))
	# Ceiling recesses frame the double-height volume without a false low lid.
	_box("plaster", CREAM, Vector3(10,0.11,10), Vector3(4.8,7.92,4.5))
	for x in [-0.2,9.8]:
		_box("emissive", WARM, Vector3(0.025,0.026,9.7), Vector3(x,7.85,4.5))
	for z in [-0.5,9.5]:
		_box("emissive", WARM, Vector3(9.7,0.026,0.025), Vector3(4.8,7.85,z))
	for side in [-1.0,1.0]:
		_box("walnut", WALNUT, Vector3(0.08,0.13,21.6), Vector3(side*12.85,0.065,0))

func _stairs_and_mezzanine() -> void:
	_box("oak", OAK, Vector3(26,0.24,6), Vector3(0,3.88,-8), true, "MezzanineFloor")
	_box("walnut", WALNUT, Vector3(26,0.20,0.20), Vector3(0,3.86,-5.03))
	# A continuous 24 degree ramp supports the character. Individual timber
	# treads are purely visual, so ordinary walking needs no jump/step solver.
	var ramp := PackedVector3Array([
		Vector3(9.6,0,4),Vector3(12,0,4),Vector3(12,4,-5),
		Vector3(9.6,0,4),Vector3(12,4,-5),Vector3(9.6,4,-5)])
	_face_collision(ramp, "ContinuousStairRamp")
	for index in range(STAIR_STEPS):
		var f := float(index+1)/float(STAIR_STEPS)
		var z := 4.0-f*9.0+9.0/float(STAIR_STEPS)*0.5
		var y := f*4.0
		_box("oak", OAK, Vector3(2.4,0.105,9.0/float(STAIR_STEPS)+0.03), Vector3(10.8,y-0.052,z))
		_box("bronze", BRONZE, Vector3(2.35,0.025,0.035), Vector3(10.8,y-0.025,z+9.0/float(STAIR_STEPS)*0.48))
	var slope := atan2(4.0,9.0)
	for x in [9.53,12.07]:
		var rail_faces := PackedVector3Array([
			Vector3(x,0.12,4),Vector3(x,4.12,-5),Vector3(x,5.15,-5),
			Vector3(x,0.12,4),Vector3(x,5.15,-5),Vector3(x,1.15,4)])
		_triangles("glass",Color.WHITE,rail_faces)
		_face_collision(rail_faces,"StairGlassRail")
		_box("bronze", BRONZE, Vector3(0.055,0.055,sqrt(97.0)), Vector3(x,3.15,-0.5),false,"",Vector3(slope,0,0))
		for step in range(6):
			var f := float(step)/5.0
			_box("bronze",BRONZE,Vector3(0.035,1.16,0.035),Vector3(x,f*4+0.58,4-f*9))
	# The overlook barrier leaves the stair opening clear. Its collision is a
	# rail, not an invisible extension of the mezzanine floor.
	_box("glass",Color.WHITE,Vector3(22.5,1.12,0.055),Vector3(-1.75,4.59,-5),true,"MezzanineGlassRail")
	_box("bronze",BRONZE,Vector3(22.5,0.055,0.055),Vector3(-1.75,5.17,-5))
	for x in [-13.0,-9.25,-5.5,-1.75,2.0,5.75,9.5]:
		_box("bronze",BRONZE,Vector3(0.038,1.16,0.038),Vector3(x,4.58,-5))
	_box("glass",Color.WHITE,Vector3(0.9,1.12,0.055),Vector3(12.55,4.59,-5),true)
	_box("bronze",BRONZE,Vector3(0.9,0.055,0.055),Vector3(12.55,5.17,-5))
	# Upper study and reading corner remain away from the main overlook route.
	_box("walnut",WALNUT,Vector3(3.5,0.12,0.9),Vector3(-5,4.78,-9.25))
	for x in [-6.4,-3.6]:
		_box("bronze",BRONZE,Vector3(0.065,0.78,0.65),Vector3(x,4.39,-9.25))
	_collision(Vector3(3.5,0.12,0.9),Vector3(-5,4.78,-9.25),"StudyDeskTop")
	for x in [-6.4,-3.6]:
		_collision(Vector3(0.065,0.78,0.65),Vector3(x,4.39,-9.25),"StudyDeskLeg")
	_box("walnut",WALNUT,Vector3(3.1,2.7,0.42),Vector3(-10.5,5.35,-10.5),true)
	for y in [4.35,4.95,5.55,6.15,6.7]:
		_box("oak",OAK,Vector3(3.12,0.08,0.5),Vector3(-10.5,y,-10.26))
		for index in range(9):
			_box("fabric",OLIVE if index%3==0 else CREAM,Vector3(0.08+float(index%2)*0.035,0.32,0.24),Vector3(-11.83+index*0.28,y+0.2,-10.18),false,"",Vector3(0,0,0.08 if index%4==0 else 0.0))
	_furniture_collision_scope="MezzanineSofa"
	_furniture_id="mezzanine_sofa"
	_padded("fabric",CREAM,Vector3(2.7,0.28,1.1),Vector3(5.6,4.38,-9.55))
	_padded("fabric",CREAM,Vector3(2.7,0.70,0.32),Vector3(5.6,4.72,-10.02))
	_furniture_collision_scope=""
	_potted_plant(Vector3(11.7,4,-9.7),1.8)

func _living_room() -> void:
	_box("rug",CREAM,Vector3(7.7,0.035,6.3),Vector3(5,0.023,4.55))
	# Rounded modular seats, a deep chaise, individual back cushions and piping.
	_furniture_collision_scope="CreamSectional"
	_furniture_id="sectional"
	for index in range(5):
		var x := 2.35+float(index)*1.3
		_padded("fabric",CREAM,Vector3(1.31,0.30,1.48),Vector3(x,0.255,6.76))
		_padded("fabric",IVORY,Vector3(1.24,0.16,1.34),Vector3(x,0.45,6.68))
		_padded("fabric",CREAM,Vector3(1.3,0.71,0.36),Vector3(x,0.76,7.4))
		_padded("fabric",IVORY,Vector3(1.16,0.56,0.24),Vector3(x,0.82,7.17),Vector3(-0.12,0,0))
	_furniture_collision_scope="SectionalChaise"
	_furniture_id="chaise"
	for z in [5.45,4.23]:
		_padded("fabric",CREAM,Vector3(1.42,0.30,1.25),Vector3(7.56,0.255,z))
		_padded("fabric",IVORY,Vector3(1.31,0.16,1.18),Vector3(7.56,0.45,z))
		_padded("fabric",CREAM,Vector3(0.30,0.47,1.24),Vector3(8.17,0.64,z))
	_padded("fabric",CREAM,Vector3(0.32,0.60,1.56),Vector3(1.72,0.75,6.76))


	for p in [Vector3(2.2,0.89,7),Vector3(6.45,0.89,7)]:
		_padded("fabric",OLIVE,Vector3(0.48,0.47,0.21),p,Vector3(-0.18,0,0.13))
	_padded("fabric",Color("b09a86"),Vector3(0.52,0.43,0.20),Vector3(3.4,0.88,7),Vector3(-0.18,0,-0.16))
	_furniture_collision_scope=""
	_padded("marble",STONE,Vector3(2.65,0.22,1.4),Vector3(4.65,0.50,4.31))
	_box("walnut",WALNUT,Vector3(1.8,0.45,0.84),Vector3(4.65,0.225,4.31))
	_collision(Vector3(2.65,0.22,1.4),Vector3(4.65,0.50,4.31),"CoffeeTableTop")
	_collision(Vector3(1.8,0.45,0.84),Vector3(4.65,0.225,4.31),"CoffeeTableBase")
	_book(Vector3(4.13,0.64,4.31),Vector3(0.55,0.055,0.38),OLIVE,-0.1)
	_book(Vector3(4.18,0.70,4.30),Vector3(0.46,0.045,0.33),CREAM,0.08)
	_vase(Vector3(5.35,0.62,4.32),0.24)
	# Linear firebox in a honed stone chimney breast, with a raised hearth.
	_box("marble",STONE,Vector3(0.65,3.15,4.5),Vector3(12.55,1.575,7.45),true,"FireplaceWall")
	_box("marble",STONE,Vector3(1.15,0.16,4.8),Vector3(12.24,0.08,7.45),true)
	_box("dark_metal",IRON,Vector3(0.08,0.83,3.1),Vector3(12.17,0.8,7.45))
	for index in range(7):
		var z := 6.2+index*0.40
		_cylinder("walnut",WALNUT,Vector3(0.10,0.30,0.10),Vector3(12.08,0.48,z),Vector3(PI*0.5,0,0))
		_sphere("emissive",Color("f4aa59"),Vector3(0.10,0.22+float(index%3)*0.085,0.23),Vector3(12.04,0.66,z))
	_potted_plant(Vector3(11.2,0,9.5),2.5)
	# A thin tall bronze floor lamp frames the seating area.
	_cylinder("bronze",BRONZE,Vector3(0.035,2.2,0.035),Vector3(9.3,1.1,5.9))
	_cylinder("bronze",BRONZE,Vector3(0.48,0.045,0.48),Vector3(9.3,0.025,5.9))
	_sphere("fabric",IVORY,Vector3(0.75,0.40,0.75),Vector3(9.3,2.25,5.9))
	for pendant in [[Vector3(4.7,7.92,4.6),2.1,0.82],[Vector3(5.55,7.92,4.9),2.75,0.62],[Vector3(3.95,7.92,4.8),2.5,0.48]]:
		_pendant(pendant[0],float(pendant[1]),float(pendant[2]))

func _kitchen_and_dining() -> void:
	_box("walnut",WALNUT,Vector3(7.3,0.91,0.86),Vector3(-8.1,0.455,-9.7),true,"KitchenCabinet")
	_box("marble",STONE,Vector3(7.45,0.10,1.0),Vector3(-8.1,0.96,-9.68))
	_box("marble",STONE,Vector3(7.45,0.72,0.055),Vector3(-8.1,1.38,-10.09))
	for index in range(10):
		var x := -11.35+float(index)*0.72
		_box("oak",OAK,Vector3(0.022,0.77,0.03),Vector3(x,0.48,-9.245))
		_box("bronze",BRONZE,Vector3(0.26,0.027,0.045),Vector3(x+0.27,0.78,-9.23))
	_box("walnut",WALNUT,Vector3(1.0,2.9,3.0),Vector3(-12.25,1.45,-6.2),true,"PenthouseStorage")
	for z in [-7.25,-6.25,-5.25]:
		_box("oak",OAK,Vector3(0.025,2.7,0.026),Vector3(-11.735,1.46,z))
		_box("bronze",BRONZE,Vector3(0.045,0.43,0.035),Vector3(-11.69,1.44,z+0.37))
	_box("dark_metal",Color("70777a"),Vector3(1.05,2.3,0.93),Vector3(-3.72,1.15,-9.68),true,"Refrigerator")
	_box("dark_metal",IRON,Vector3(1.07,0.035,0.035),Vector3(-3.72,0.78,-9.19))
	_box("bronze",BRONZE,Vector3(0.032,0.68,0.065),Vector3(-3.3,1.5,-9.14))
	_box("dark_metal",IRON,Vector3(0.90,0.025,0.66),Vector3(-8.25,1.024,-9.55))
	for x in [-8.48,-8.02]:
		for z in [-9.76,-9.36]:
			_cylinder("dark_metal",Color("70777a"),Vector3(0.23,0.009,0.23),Vector3(x,1.042,z))
	_box("dark_metal",Color("70777a"),Vector3(1.02,0.024,0.56),Vector3(-10.5,1.02,-9.61))
	_box("dark_metal",IRON,Vector3(0.85,0.015,0.42),Vector3(-10.5,1.036,-9.60))
	_cylinder("bronze",BRONZE,Vector3(0.04,0.37,0.04),Vector3(-10.5,1.23,-9.89))
	_box("bronze",BRONZE,Vector3(0.04,0.04,0.29),Vector3(-10.5,1.4,-9.76))
	_box("walnut",WALNUT,Vector3(3.7,0.9,1.35),Vector3(-7.6,0.45,-6.15),true,"KitchenIsland")
	_box("marble",STONE,Vector3(3.95,0.12,1.55),Vector3(-7.6,0.96,-6.15))
	for x in [-8.7,-7.55,-6.4]:
		_pendant(Vector3(x,3.86,-6.15),1.06,0.43)
	_vase(Vector3(-8.9,1.03,-6.10),0.18)
	_box("walnut",WALNUT,Vector3(0.72,0.035,0.44),Vector3(-6.34,1.045,-6.1))
	for z in [-6.23,-5.99]:
		_sphere("plaster",IVORY,Vector3(0.12,0.1,0.12),Vector3(-6.4,1.105,z))
	# Six softly upholstered dining chairs surround a rounded solid-wood table.
	_padded("walnut",WALNUT,Vector3(3.7,0.16,1.15),Vector3(-7.7,0.83,-0.1))
	for x in [-8.8,-6.6]:
		_cylinder("walnut",WALNUT,Vector3(0.52,0.75,0.52),Vector3(x,0.375,-0.1))
	_collision(Vector3(3.7,0.16,1.15),Vector3(-7.7,0.83,-0.1),"DiningTableTop")
	for x in [-8.8,-6.6]:
		_collision(Vector3(0.52,0.75,0.52),Vector3(x,0.375,-0.1),"DiningPedestal")
	for x in [-9.1,-7.7,-6.3]:
		for z in [-0.40,0.20]:
			_cylinder("plaster",IVORY,Vector3(0.31,0.015,0.31),Vector3(x,0.928,z))
			_cylinder("glass",Color.WHITE,Vector3(0.075,0.16,0.075),Vector3(x+0.32,1.008,z))
	_vase(Vector3(-7.7,0.92,-0.1),0.22)
	_pendant(Vector3(-7.7,7.96,-0.1),3.3,1.0)

func _bedroom() -> void:
	# A low partition gives the corner bedroom privacy while the glazing keeps
	# the full city panorama. Entry is on its east side, off the central route.
	_box("plaster",CREAM,Vector3(9.1,3.1,0.15),Vector3(-8.35,1.55,3.15),true,"BedroomPartition")
	_box("walnut",WALNUT,Vector3(9.12,0.08,0.18),Vector3(-8.35,3.07,3.15))
	_box("rug",IVORY,Vector3(6.5,0.035,5.6),Vector3(-8.25,0.022,7.0))
	_furniture_collision_scope="PaddedBed"
	_furniture_id="bed_sleep"
	_padded("fabric",CREAM,Vector3(2.86,1.6,0.28),Vector3(-8.2,0.96,8.7))
	_padded("fabric",CREAM,Vector3(2.7,0.40,3.15),Vector3(-8.2,0.26,7.1))
	_padded("fabric",IVORY,Vector3(2.59,0.37,3.04),Vector3(-8.2,0.57,7.08))
	_padded("fabric",IVORY,Vector3(2.44,0.14,2.14),Vector3(-8.2,0.75,6.75))
	_draped_duvet(Vector3(-8.2,0.90,6.75))
	_padded("fabric",Color("b09a86"),Vector3(2.66,0.075,0.66),Vector3(-8.2,0.942,6.06))
	for side in [-1.0,1.0]:
		_padded("fabric",Color("b09a86"),Vector3(0.10,0.30,0.66),Vector3(-8.2+side*1.32,0.80,6.06))
	for x in [-8.87,-7.53]:
		_padded("fabric",IVORY,Vector3(1.08,0.23,0.60),Vector3(x,0.83,8.19),Vector3(-0.13,0,0))
		_padded("fabric",CREAM,Vector3(0.82,0.19,0.43),Vector3(x,0.915,7.99),Vector3(-0.08,0,0))
	_collision(Vector3(2.64,0.15,2.35),Vector3(-8.2,0.89,6.75),"Duvet")
	_furniture_collision_scope="BedroomBench"
	_furniture_id="bedroom_bench"
	_padded("fabric",CREAM,Vector3(2.28,0.20,0.74),Vector3(-8.2,0.43,5.05))
	for x in [-9.13,-7.27]:
		for z in [4.81,5.29]:
			_cylinder("walnut",WALNUT,Vector3(0.065,0.42,0.065),Vector3(x,0.21,z))
	_furniture_collision_scope=""
	for x in [-10.3,-6.1]:
		_box("walnut",WALNUT,Vector3(0.77,0.47,0.60),Vector3(x,0.35,8.19),true,"BedsideTable")
		_box("marble",STONE,Vector3(0.83,0.045,0.65),Vector3(x,0.61,8.19))
		_box("bronze",BRONZE,Vector3(0.23,0.023,0.027),Vector3(x,0.42,7.875))
		_cylinder("bronze",BRONZE,Vector3(0.045,0.35,0.045),Vector3(x,0.805,8.19))
		_sphere("fabric",IVORY,Vector3(0.45,0.26,0.45),Vector3(x,1.02,8.19))
	# Full-height drapery stacks: the curved pleats remain individual geometry,
	# merged into the same fabric material instead of hundreds of cloth nodes.
	for center_x in [-11.85,-4.5]:
		for pleat in range(8):
			_cylinder("fabric",CREAM,Vector3(0.17,7.3,0.20),Vector3(center_x+float(pleat)*0.12,3.7,10.67))
	_box("bronze",BRONZE,Vector3(8.4,0.045,0.06),Vector3(-8.0,7.46,10.66))
	_potted_plant(Vector3(-11.4,0,9.35),2.0)
	_padded("marble",STONE,Vector3(0.7,0.08,0.65),Vector3(-10.45,0.57,4.75))
	_cylinder("bronze",BRONZE,Vector3(0.10,0.55,0.10),Vector3(-10.45,0.275,4.75))

func _entrance_and_study() -> void:
	_box("rug",Color("a69b85"),Vector3(2.25,0.025,4.5),Vector3(0,0.019,-7.8))
	_box("walnut",WALNUT,Vector3(3.2,0.70,0.65),Vector3(4.8,0.35,-9.8),true,"ResidenceConsole")
	_box("marble",STONE,Vector3(3.32,0.075,0.75),Vector3(4.8,0.74,-9.8))
	_box("bronze",BRONZE,Vector3(2.65,1.38,0.075),Vector3(4.8,2.0,-10.86))
	_box("plaster",Color("b09a86"),Vector3(2.49,1.22,0.025),Vector3(4.8,2.0,-10.805))
	for index in range(7):
		_padded("plaster",CREAM if index%2==0 else OLIVE,Vector3(0.25,0.45+float(index%3)*0.18,0.022),Vector3(3.8+float(index)*0.33,2.0,-10.78),Vector3(0,0,float(index-3)*0.15))
	_vase(Vector3(5.75,0.79,-9.78),0.28)
	_book(Vector3(4.18,0.81,-9.78),Vector3(0.58,0.05,0.36),OLIVE,0.12)
	_potted_plant(Vector3(11.65,0,-9.6),2.25)

func _lighting() -> void:
	for p in [Vector3(-10,3.68,-8.3),Vector3(-5.5,3.68,-8.3),Vector3(0,3.68,-8.3),Vector3(5.5,3.68,-8.3),Vector3(10,3.68,-8.3)]:
		_cylinder("bronze",BRONZE,Vector3(0.28,0.045,0.28),p)
		_cylinder("emissive",WARM,Vector3(0.22,0.018,0.22),p-Vector3.UP*0.028)
	for spec in [
		[Vector3(4.8,4.95,4.5),1.7,13.0], [Vector3(-8.2,3.65,7),1.25,7.5],
		[Vector3(-7.5,3.0,-7),1.15,8.5], [Vector3(-7.7,4.6,-0.1),1.35,9.0],
		[Vector3(0,2.9,-8.4),0.8,7.0], [Vector3(4.5,6.7,-8),0.85,9.0],
		[Vector3(11.6,1.65,7.4),0.9,5.0]]:
		var light := OmniLight3D.new()
		light.name = "PenthouseWarmLight%d" % _lights.size()
		light.position = spec[0]
		light.light_color = Color("ffe0b7")
		light.omni_range = float(spec[2])
		light.omni_attenuation = 1.15
		light.shadow_enabled = _lights.size() < 2
		light.shadow_bias = 0.025
		light.shadow_normal_bias = 0.10
		if _lights.is_empty():
			light.light_size = 0.25
		_room.add_child(light)
		_lights.append(light)
		_base_energies.append(float(spec[1]))

func _chair(at: Vector3, color: Color, yaw: float, width := 1.0) -> void:
	var basis := Basis(Vector3.UP,yaw)
	# Slim dining silhouettes retain full adult seat/back height so the same
	# unscaled resident can sit in every chair with feet below the cushion.
	var size := Vector3(width,0.76,width)
	var center := at+Vector3(0,0.47*0.76,0)
	_furniture_collision_scope="UpholsteredChair"
	_padded("fabric",color,Vector3(0.91,0.32,0.87)*size,center,Vector3(0,yaw,0))
	_padded("fabric",color,Vector3(0.93,0.72,0.26)*size,at+basis*(Vector3(0,0.79,-0.34)*size),Vector3(-0.10,yaw,0))
	for side in [-1.0,1.0]:
		if width>=0.7:
			_padded("fabric",color,Vector3(0.17,0.31,0.81)*size,at+basis*(Vector3(side*0.42,0.66,0)*size),Vector3(0,yaw,0))
		for z in [-0.29,0.29]:
			_cylinder("walnut",WALNUT,Vector3(0.052,0.36,0.052)*size,at+basis*(Vector3(side*0.34,0.18,z)*size))
	_furniture_collision_scope=""

func _pendant(mount: Vector3, drop: float, diameter: float) -> void:
	_cylinder("bronze",BRONZE,Vector3(0.14,0.08,0.14),mount)
	_cylinder("bronze",BRONZE,Vector3(0.024,drop,0.024),mount-Vector3.UP*(drop*0.5))
	_sphere("plaster",IVORY,Vector3(diameter,diameter*0.32,diameter),mount-Vector3.UP*drop)
	_cylinder("emissive",WARM,Vector3(diameter*0.78,0.015,diameter*0.78),mount-Vector3.UP*(drop+diameter*0.11))

func _vase(at: Vector3, height: float) -> void:
	_sphere("plaster",IVORY,Vector3(height*0.62,height,height*0.62),at+Vector3.UP*height*0.45)
	_cylinder("plaster",IVORY,Vector3(height*0.25,height*0.25,height*0.25),at+Vector3.UP*height)
	for index in range(3):
		var offset := Vector3(float(index-1)*height*0.17,0,0)
		_cylinder("leaf",OLIVE,Vector3(0.012,height*1.5,0.012),at+offset+Vector3.UP*height*1.5)
		_sphere("leaf",OLIVE,Vector3(height*0.35,height*0.62,height*0.16),at+offset+Vector3.UP*height*2.15,Vector3(0,0,float(index-1)*0.4))

func _book(at: Vector3, size: Vector3, color: Color, yaw: float) -> void:
	_box("fabric",color,size,at,false,"",Vector3(0,yaw,0))
	_box("plaster",IVORY,Vector3(size.x*0.94,size.y*0.6,size.z*0.94),at+Vector3(0,0,-0.004),false,"",Vector3(0,yaw,0))

func _potted_plant(at: Vector3, height: float) -> void:
	_sphere("plaster",STONE,Vector3(0.6,0.55,0.6),at+Vector3.UP*0.27)
	_cylinder("walnut",WALNUT,Vector3(0.05,height*0.8,0.05),at+Vector3.UP*height*0.42)
	for index in range(16):
		var angle := float(index)*2.39996
		var h := height*(0.45+float(index%6)*0.085)
		var spread := 0.28+float(index%3)*0.1
		var p := at+Vector3(cos(angle)*spread,h,sin(angle)*spread)
		_sphere("leaf",OLIVE,Vector3(0.47,0.22,0.75),p,Vector3(0,angle,-0.3+float(index%3)*0.3))
	_collision(Vector3(0.6,0.65,0.6),at+Vector3.UP*0.325,"PlantPot")

func _box(kind: String, color: Color, size: Vector3, at: Vector3, solid := false, label := "", rotation := Vector3.ZERO) -> void:
	_mesh(kind,color,_box_mesh,size,at,rotation)
	if solid: _collision(size,at,label,rotation)

func _sphere(kind: String, color: Color, size: Vector3, at: Vector3, rotation := Vector3.ZERO) -> void:
	_mesh(kind,color,_sphere_mesh,size,at,rotation)

func _cylinder(kind: String, color: Color, size: Vector3, at: Vector3, rotation := Vector3.ZERO) -> void:
	_mesh(kind,color,_cylinder_mesh,size,at,rotation)

func _padded(kind: String, color: Color, size: Vector3, at: Vector3, rotation := Vector3.ZERO) -> void:
	_mesh(kind,color,_padded_mesh,size,at,rotation)
	if not _furniture_collision_scope.is_empty():
		var hull := ConvexPolygonShape3D.new()
		var vertices: PackedVector3Array = _padded_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for index in range(vertices.size()): vertices[index]*=size
		hull.points=vertices
		var collider := CollisionShape3D.new()
		collider.shape=hull
		collider.position=at
		collider.rotation=rotation
		collider.name=_furniture_collision_scope
		collider.set_meta("furnishing_label",_furniture_collision_scope)
		collider.set_meta("furniture_id",_furniture_id)
		_body.add_child(collider)

func _surface(kind: String, color: Color) -> SurfaceTool:
	var key := kind+"_"+color.to_html()
	if not _batches.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_batches[key] = st
		_mats[key] = Materials.get_material(kind,color)
	return _batches[key]

func _mesh(kind: String, color: Color, mesh: Mesh, size: Vector3, at: Vector3, rotation: Vector3) -> void:
	var transform := Transform3D(Basis.from_euler(rotation)*Basis.from_scale(size),at)
	_surface(kind,color).append_from(mesh,0,transform)
	_primitive_count += 1

func _triangles(kind: String, color: Color, vertices: PackedVector3Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(0,vertices.size(),3):
		var normal := (vertices[index+1]-vertices[index]).cross(vertices[index+2]-vertices[index]).normalized()
		for offset in range(3):
			st.set_normal(normal)
			st.set_uv(Vector2.ZERO)
			st.add_vertex(vertices[index+offset])
	st.index()
	_surface(kind,color).append_from(st.commit(),0,Transform3D.IDENTITY)
	_primitive_count += 1

func _collision(size: Vector3, at: Vector3, label := "FurnishingCollision", rotation := Vector3.ZERO) -> void:
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	collision.name = label if not label.is_empty() else "SuiteArchitectureCollision"
	collision.set_meta("furnishing_label",label)
	collision.position = at
	collision.rotation = rotation
	_body.add_child(collision)

func _face_collision(vertices: PackedVector3Array, label: String) -> void:
	var collision := CollisionShape3D.new()
	collision.name = label
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(vertices)
	shape.backface_collision = true
	collision.shape = shape
	_body.add_child(collision)

func _flush() -> void:
	_room.set_meta("penthouse_render_batches",_batches.size())
	for key in _batches:
		var mesh := MeshInstance3D.new()
		mesh.name = "PenthouseBatch_"+String(key)
		mesh.mesh = (_batches[key] as SurfaceTool).commit()
		mesh.material_override = _mats[key]
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if String(key).begins_with("glass_") else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_room.add_child(mesh)
	_batches.clear()
	_mats.clear()

func _sign(text: String, at: Vector3, yaw: float) -> void:
	var label := Label3D.new()
	label.name = "PenthouseService_"+text
	label.text = text
	label.position = at
	label.rotation.y = yaw
	label.font_size = 32
	label.pixel_size = 0.0034
	label.modulate = Color("c9b98f")
	label.outline_size = 1
	label.no_depth_test = false
	label.visibility_range_end = 10
	label.visibility_range_end_margin = 2
	_room.add_child(label)

func _make_padded_mesh() -> ArrayMesh:
	# A smooth superellipsoid retains broad flat upholstery faces and softly
	# rounded corners. Shared by every cushion, duvet, upholstered back and rug.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var slices := 16
	var rings := 12
	for row in range(rings):
		for column in range(slices):
			var u0 := float(column)/float(slices)*TAU
			var u1 := float(column+1)/float(slices)*TAU
			var v0 := -PI*0.5+float(row)/float(rings)*PI
			var v1 := -PI*0.5+float(row+1)/float(rings)*PI
			for uv in [Vector2(u0,v0),Vector2(u1,v0),Vector2(u1,v1),Vector2(u0,v0),Vector2(u1,v1),Vector2(u0,v1)]:
				var latitude := pow(maxf(0.0,cos(uv.y)),0.25)
				var point := Vector3(latitude*_signed_pow(cos(uv.x),0.25),_signed_pow(sin(uv.y),0.25),latitude*_signed_pow(sin(uv.x),0.25))*0.5
				var normal := Vector3(_signed_pow(point.x,7.0),_signed_pow(point.y,7.0),_signed_pow(point.z,7.0)).normalized()
				st.set_normal(normal)
				st.set_uv(Vector2(uv.x/TAU,uv.y/PI+0.5))
				st.add_vertex(point)
	# Native primitive meshes are indexed. Match that format before merging,
	# otherwise their index arrays leave non-indexed cushions unreferenced.
	st.index()
	return st.commit()

func _draped_duvet(at: Vector3) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := 24
	for row in range(count):
		for column in range(count):
			var x0 := -1.36+float(column)/float(count)*2.72
			var x1 := -1.36+float(column+1)/float(count)*2.72
			var z0 := -1.20+float(row)/float(count)*2.40
			var z1 := -1.20+float(row+1)/float(count)*2.40
			for point in [Vector2(x0,z0),Vector2(x1,z0),Vector2(x1,z1),Vector2(x0,z0),Vector2(x1,z1),Vector2(x0,z1)]:
				var height := _duvet_height(point.x,point.y)
				var dx := (_duvet_height(point.x+0.006,point.y)-_duvet_height(point.x-0.006,point.y))/0.012
				var dz := (_duvet_height(point.x,point.y+0.006)-_duvet_height(point.x,point.y-0.006))/0.012
				st.set_normal(Vector3(-dx,1.0,-dz).normalized())
				st.set_uv(point)
				st.add_vertex(at+Vector3(point.x,height,point.y))
	st.index()
	_surface("fabric",IVORY).append_from(st.commit(),0,Transform3D.IDENTITY)
	_primitive_count += 1

func _duvet_height(x: float, z: float) -> float:
	return 0.008*sin(z*17.0+x*1.5)+0.009*sin(x*13.0-z*3.0) \
		-0.12*smoothstep(1.10,1.36,absf(x))-0.08*smoothstep(1.01,1.20,absf(z))

func _signed_pow(value: float, power: float) -> float:
	return signf(value)*pow(absf(value),power)
