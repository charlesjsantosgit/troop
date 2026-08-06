class_name DebugWorldBuilder
extends Node3D
## Assembles the flat testing playground: a block parkour line, a rope garden,
## a regenerating robot-monkey shooting range with distance boards, an ammo
## hut, and a resident trader. Everything is authored at fixed coordinates on
## the debug plane (ground level y = 2.0) so screenshots and tests are stable.

const GROUND_Y := 2.0

var robots: Array[RobotMonkey] = []


func build(world: Node3D) -> void:
	_build_parkour()
	_build_range(world)
	_build_rope_garden(world)
	_build_ammo_hut(world)
	_build_signs()


## ---- parkour: a graded line of floating blocks heading +X ------------------
func _build_parkour() -> void:
	var palette := [Color(0.86, 0.42, 0.30), Color(0.92, 0.72, 0.25),
		Color(0.42, 0.72, 0.38), Color(0.36, 0.58, 0.82)]
	# (x, y-above-ground, z, size, color index) — gaps grow from hop to fling
	var blocks := [
		[10.0, 0.6, 0.0, 2.2, 0], [13.2, 1.2, 0.6, 2.0, 0],
		[16.6, 1.8, -0.4, 1.8, 0], [20.4, 2.2, 0.4, 1.6, 1],
		[24.8, 2.8, -0.6, 1.5, 1], [29.6, 3.2, 0.8, 1.4, 1],
		[35.0, 3.6, -0.8, 1.3, 2], [41.0, 4.2, 0.6, 1.2, 2],
		[47.4, 4.8, -0.5, 1.2, 2], [54.2, 5.6, 0.0, 1.4, 3],
	]
	for b in blocks:
		_solid_box(Vector3(b[0], GROUND_Y + b[1], b[2]),
			Vector3(b[3], 0.5, b[3]), palette[b[4]])
	# double wall-jump corridor after the last block
	_solid_box(Vector3(60.0, GROUND_Y + 3.4, -2.2), Vector3(0.5, 6.0, 6.0),
		Color(0.55, 0.50, 0.62))
	_solid_box(Vector3(63.4, GROUND_Y + 3.4, 2.2), Vector3(0.5, 6.0, 6.0),
		Color(0.55, 0.50, 0.62))
	# finish podium with a glowing banana beacon
	var podium := _solid_box(Vector3(68.5, GROUND_Y + 3.2, 0.0),
		Vector3(2.6, 0.6, 2.6), Color(1.0, 0.84, 0.20))
	var beacon := OmniLight3D.new()
	beacon.light_color = Color(1.0, 0.85, 0.3)
	beacon.omni_range = 7.0
	beacon.position = Vector3(0, 1.6, 0)
	podium.add_child(beacon)


## ---- shooting range at -Z: 6 regenerating robots, distance boards ----------
func _build_range(world: Node3D) -> void:
	var firing_line_z := -14.0
	for i in range(3):
		var still := RobotMonkey.new()
		still.setup(Vector3(-6.0 + i * 6.0, GROUND_Y, firing_line_z - 10.0))
		world.add_child(still)
		robots.append(still)
	for i in range(3):
		var mover := RobotMonkey.new()
		mover.setup(Vector3(-8.0 + i * 8.0, GROUND_Y,
			firing_line_z - [25.0, 50.0, 75.0][i]), 5.0 + i * 2.0)
		world.add_child(mover)
		robots.append(mover)
	# firing-line planks and distance boards
	_solid_box(Vector3(0.0, GROUND_Y + 0.5, firing_line_z),
		Vector3(20.0, 1.0, 0.6), Color(0.42, 0.30, 0.20))
	for distance in [10, 25, 50, 75]:
		var board := _solid_box(
			Vector3(11.5, GROUND_Y + 1.4, firing_line_z - distance),
			Vector3(0.2, 1.1, 2.2), Color(0.16, 0.18, 0.16))
		var label := Label3D.new()
		label.text = "%d m" % distance
		label.font_size = 220
		label.modulate = Color(1.0, 0.9, 0.4)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.position = Vector3(0, 1.1, 0)
		board.add_child(label)


## ---- rope garden: debug vines rendered in rope colors ----------------------
func _build_rope_garden(world: Node3D) -> void:
	# A row of anchors at climbing height plus a tall frame to hang them from.
	for i in range(6):
		var x := -14.0 - i * 4.5
		_solid_box(Vector3(x, GROUND_Y + 11.2, 8.0), Vector3(0.4, 0.4, 0.4),
			Color(0.35, 0.26, 0.18))
		world.add_debug_vine(Vector3(x, GROUND_Y + 11.0, 8.0), 8.0)
	# crossbar so the frame reads as built, not floating
	_solid_box(Vector3(-25.2, GROUND_Y + 11.6, 8.0), Vector3(24.5, 0.35, 0.35),
		Color(0.35, 0.26, 0.18))
	for x_leg in [-14.0, -36.5]:
		_solid_box(Vector3(x_leg, GROUND_Y + 5.8, 8.0),
			Vector3(0.45, 11.6, 0.45), Color(0.30, 0.22, 0.15))


func _build_ammo_hut(world: Node3D) -> void:
	var hut := SupplyHut.new()
	hut.configure({
		"id": "s:debug#range",
		"pos": Vector3(8.0, GROUND_Y, -10.0),
		"yaw": PI * 0.5,
		"ammo_kind": Gen.SUPPLY_AMMO_SMG,
		"ammo_amount": 200,
		"bandages": 5,
		"biome": Gen.Biome.RAINFOREST,
	}, false)
	world.add_child(hut)
	for body in hut.build_collisions():
		hut.add_child(body)


func _build_signs() -> void:
	var titles := [
		["PARKOUR →", Vector3(7.0, GROUND_Y + 2.4, 0.0)],
		["RANGE ↓", Vector3(0.0, GROUND_Y + 2.4, -11.5)],
		["ROPES ←", Vector3(-11.0, GROUND_Y + 2.4, 6.0)],
	]
	for entry in titles:
		var post := _solid_box(entry[1] - Vector3(0, 1.0, 0),
			Vector3(0.18, 2.0, 0.18), Color(0.34, 0.25, 0.17))
		var sign_label := Label3D.new()
		sign_label.text = entry[0]
		sign_label.font_size = 200
		sign_label.modulate = Color(0.95, 0.95, 0.85)
		sign_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sign_label.position = Vector3(0, 2.2, 0)
		post.add_child(sign_label)


func _solid_box(at: Vector3, size: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	mi.material_override = material
	body.add_child(mi)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	return body
