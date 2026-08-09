class_name DebugWorldBuilder
extends Node3D
## Assembles the flat testing playground: a block parkour line, a rope garden,
## a regenerating robot-monkey shooting range with distance boards, an ammo
## hut, a vehicle yard, and a progressively rough suspension proving ground.
## Everything is authored at fixed coordinates on the debug plane (ground
## level y = 2.0) so screenshots and tests are stable.

const GROUND_Y := 2.0
const ROUGH_COURSE_START_Z := 34.0
const ROUGH_COURSE_LENGTH := 80.0
const ROUGH_COURSE_WIDTH := 4.6
const ROUGH_COURSE_X_SEGMENTS := 12
const ROUGH_COURSE_Z_SEGMENTS := 240
const ROUGH_COURSE_MIN_CLEARANCE := 0.03
const ROUGH_COURSE_DECK_HEIGHT := 0.30
const ROUGH_COURSE_RAMP_LENGTH := 6.0
const ROUGH_COURSE_FEATURE_START := 10.0
const ROUGH_COURSE_FEATURE_END := 66.0
## Lane one is nearest the vehicle yard; turning northwest reaches the gentle
## surface first and continuing west progresses naturally toward lane four.
const ROUGH_COURSE_LANE_CENTERS := [-21.0, -26.8, -32.6, -38.4]
const ROUGH_COURSE_NAMES := [
	"Washboard", "OffsetBumps", "CrossAxle", "RockCrawl"]
const ROUGH_COURSE_LABELS := [
	"1  ROUGH · WASHBOARD\n15–40 km/h",
	"2  ROUGHER · OFFSET BUMPS\n10–25 km/h",
	"3  VERY ROUGH · CROSS-AXLE\nUNDER 10 km/h",
	"4  EXTREME · ROCK CRAWL\nLOW RANGE",
]
const ROUGH_COURSE_COLORS := [
	Color(0.28, 0.46, 0.20), Color(0.68, 0.54, 0.16),
	Color(0.78, 0.34, 0.10), Color(0.62, 0.12, 0.08),
]

var robots: Array[RobotMonkey] = []
var rough_course: Node3D
var rough_course_lanes: Array[StaticBody3D] = []
var _rough_course_metrics: Array[Dictionary] = []
var _rough_course_material: StandardMaterial3D


func build(world: Node3D) -> void:
	_build_parkour()
	_build_range(world)
	_build_rope_garden(world)
	_build_ammo_hut(world)
	_build_vehicle_yard(world)
	_build_rough_course()
	_build_signs()


## ---- vehicle yard: every machine lined up north of spawn -------------------
func _build_vehicle_yard(world: Node3D) -> void:
	if not world.has_method("spawn_vehicle"):
		return
	# All parked facing +Z: the open plane north of the course, so a test
	# drive (or an excited monkey) has kilometres of empty ground ahead.
	world.call("spawn_vehicle", Vehicle.Kind.BIKE, "v:debug#bike",
		Vector3(-6.0, GROUND_Y, 16.0), 0.0)
	world.call("spawn_vehicle", Vehicle.Kind.JEEP, "v:debug#jeep",
		Vector3(0.0, GROUND_Y, 18.0), 0.0)
	world.call("spawn_vehicle", Vehicle.Kind.BOAT, "v:debug#boat",
		Vector3(7.0, GROUND_Y, 18.0), 0.0)
	world.call("spawn_vehicle", Vehicle.Kind.JET, "v:debug#jet",
		Vector3(24.0, GROUND_Y, 34.0), 0.0)


## ---- suspension lab: four repeatable, progressively rougher lanes ---------
func _build_rough_course() -> void:
	rough_course = Node3D.new()
	rough_course.name = "SuspensionCourse"
	add_child(rough_course)

	_rough_course_material = StandardMaterial3D.new()
	_rough_course_material.albedo_color = Color(0.48, 0.35, 0.20)
	_rough_course_material.roughness = 0.98
	_rough_course_material.vertex_color_use_as_albedo = true

	for lane_index in range(ROUGH_COURSE_LANE_CENTERS.size()):
		var lane := _make_rough_course_lane(lane_index)
		rough_course.add_child(lane)
		rough_course_lanes.append(lane)
		var sign_x: float = ROUGH_COURSE_LANE_CENTERS[lane_index] \
			- ROUGH_COURSE_WIDTH * 0.5 - 0.35
		_rough_course_sign(ROUGH_COURSE_LABELS[lane_index],
			Vector3(sign_x, GROUND_Y, ROUGH_COURSE_START_Z + 2.2),
			ROUGH_COURSE_COLORS[lane_index], 4.3)

	_rough_course_sign("SUSPENSION LAB · LANES 1–4\nROUGH TO EXTREME",
		Vector3(-17.5, GROUND_Y, ROUGH_COURSE_START_Z - 2.0),
		Color(0.14, 0.22, 0.16), 4.5)
	var bike_line := Label3D.new()
	bike_line.name = "BikeLineSign"
	bike_line.text = "BIKE LINE  →"
	bike_line.font_size = 105
	bike_line.outline_size = 14
	bike_line.pixel_size = 0.004
	bike_line.modulate = Color(1.0, 0.90, 0.52)
	bike_line.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	bike_line.position = Vector3(ROUGH_COURSE_LANE_CENTERS[3] + 1.25,
		GROUND_Y + 1.15, ROUGH_COURSE_START_Z + 18.0)
	rough_course.add_child(bike_line)

	# Low distance markers make speed/compression comparisons repeatable without
	# filling the course with collision objects that could snag a motorcycle.
	for distance in range(10, 81, 10):
		var marker := Label3D.new()
		marker.name = "DistanceMarker%02d" % distance
		marker.text = "%d m" % distance
		marker.font_size = 105
		marker.outline_size = 14
		marker.modulate = Color(0.92, 0.88, 0.68)
		marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		marker.position = Vector3(ROUGH_COURSE_LANE_CENTERS[0]
			+ ROUGH_COURSE_WIDTH * 0.5 + 0.55, GROUND_Y + 0.58,
			ROUGH_COURSE_START_Z + float(distance))
		rough_course.add_child(marker)


func _make_rough_course_lane(lane_index: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = ROUGH_COURSE_NAMES[lane_index]
	body.position = Vector3(ROUGH_COURSE_LANE_CENTERS[lane_index],
		GROUND_Y, ROUGH_COURSE_START_Z)
	body.add_to_group("debug_rough_terrain")
	body.set_meta("severity", lane_index + 1)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var x_step := ROUGH_COURSE_WIDTH / float(ROUGH_COURSE_X_SEGMENTS)
	var z_step := ROUGH_COURSE_LENGTH / float(ROUGH_COURSE_Z_SEGMENTS)
	var half_width := ROUGH_COURSE_WIDTH * 0.5
	var min_height := INF
	var max_height := -INF
	var peak_relief := 0.0
	var height_checksum := 0
	var lane_color: Color = [
		Color(0.34, 0.31, 0.18), Color(0.40, 0.31, 0.16),
		Color(0.39, 0.25, 0.12), Color(0.31, 0.20, 0.11),
	][lane_index]

	for z_index in range(ROUGH_COURSE_Z_SEGMENTS + 1):
		var lane_z := z_step * float(z_index)
		for x_index in range(ROUGH_COURSE_X_SEGMENTS + 1):
			var lane_x := -half_width + x_step * float(x_index)
			var height := rough_course_height(lane_index, lane_x, lane_z)
			vertices.append(Vector3(lane_x, height, lane_z))
			min_height = minf(min_height, height)
			max_height = maxf(max_height, height)
			peak_relief = maxf(peak_relief,
				absf(_rough_course_relief(lane_index, lane_x, lane_z)))
			height_checksum = (height_checksum * 33
				+ roundi(height * 10000.0)) & 0x7fffffff

			var left_h := rough_course_height(lane_index,
				maxf(lane_x - x_step, -half_width), lane_z)
			var right_h := rough_course_height(lane_index,
				minf(lane_x + x_step, half_width), lane_z)
			var back_h := rough_course_height(lane_index, lane_x,
				maxf(lane_z - z_step, 0.0))
			var front_h := rough_course_height(lane_index, lane_x,
				minf(lane_z + z_step, ROUGH_COURSE_LENGTH))
			var tangent_x := Vector3(2.0 * x_step, right_h - left_h, 0.0)
			var tangent_z := Vector3(0.0, front_h - back_h, 2.0 * z_step)
			normals.append(tangent_z.cross(tangent_x).normalized())
			var height_mix := clampf((height - ROUGH_COURSE_MIN_CLEARANCE)
				/ 0.60, 0.0, 1.0)
			colors.append(lane_color.lerp(Color(0.68, 0.53, 0.31),
				height_mix * 0.58))

	for z_index in range(ROUGH_COURSE_Z_SEGMENTS):
		for x_index in range(ROUGH_COURSE_X_SEGMENTS):
			var row := ROUGH_COURSE_X_SEGMENTS + 1
			var a := z_index * row + x_index
			var b := a + 1
			var c := a + row
			var d := c + 1
			# Godot's front faces are clockwise: these wind upward on an X/Z grid.
			indices.append_array(PackedInt32Array([a, b, c, b, d, c]))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _rough_course_material)
	var visual := MeshInstance3D.new()
	visual.name = "Surface"
	visual.mesh = mesh
	body.add_child(visual)
	var collision := CollisionShape3D.new()
	collision.name = "SurfaceCollision"
	collision.shape = mesh.create_trimesh_shape()
	if collision.shape is ConcavePolygonShape3D:
		(collision.shape as ConcavePolygonShape3D).backface_collision = true
	body.add_child(collision)

	var triangle_count := indices.size() / 3
	body.set_meta("height_checksum", height_checksum)
	body.set_meta("peak_relief", peak_relief)
	_rough_course_metrics.append({
		"index": lane_index,
		"name": ROUGH_COURSE_NAMES[lane_index],
		"min_height": min_height,
		"max_height": max_height,
		"peak_relief": peak_relief,
		"vertices": vertices.size(),
		"triangles": triangle_count,
		"checksum": height_checksum,
	})
	return body


## Height above GROUND_Y for one lane-local point. Visuals, collision, tests,
## and screenshot placement all consume this same deterministic source.
func rough_course_height(lane_index: int, lane_x: float, lane_z: float) -> float:
	var half_width := ROUGH_COURSE_WIDTH * 0.5
	var shoulder := smoothstep(0.0, 0.62,
		half_width - absf(lane_x))
	var deck := ROUGH_COURSE_MIN_CLEARANCE \
		+ (ROUGH_COURSE_DECK_HEIGHT - ROUGH_COURSE_MIN_CLEARANCE) \
		* _rough_course_plateau(lane_z)
	var relief := _rough_course_relief(lane_index, lane_x, lane_z)
	return maxf(ROUGH_COURSE_MIN_CLEARANCE,
		ROUGH_COURSE_MIN_CLEARANCE + shoulder
		* (deck - ROUGH_COURSE_MIN_CLEARANCE + relief))


func rough_course_world_height(lane_index: int, world_x: float,
		world_z: float) -> float:
	return GROUND_Y + rough_course_height(lane_index,
		world_x - ROUGH_COURSE_LANE_CENTERS[lane_index],
		world_z - ROUGH_COURSE_START_Z)


func rough_course_metrics() -> Array[Dictionary]:
	return _rough_course_metrics.duplicate(true)


func _rough_course_plateau(lane_z: float) -> float:
	var up := smoothstep(0.0, ROUGH_COURSE_RAMP_LENGTH, lane_z)
	var down_start := ROUGH_COURSE_LENGTH - 10.0
	var down := 1.0 - smoothstep(down_start,
		down_start + ROUGH_COURSE_RAMP_LENGTH, lane_z)
	return clampf(minf(up, down), 0.0, 1.0)


func _rough_course_relief(lane_index: int, lane_x: float,
		lane_z: float) -> float:
	if lane_z < ROUGH_COURSE_FEATURE_START \
			or lane_z > ROUGH_COURSE_FEATURE_END:
		return 0.0
	var feature_fade := smoothstep(ROUGH_COURSE_FEATURE_START,
		ROUGH_COURSE_FEATURE_START + 2.0, lane_z) \
		* (1.0 - smoothstep(ROUGH_COURSE_FEATURE_END - 2.0,
			ROUGH_COURSE_FEATURE_END, lane_z))
	var progress := clampf((lane_z - ROUGH_COURSE_FEATURE_START)
		/ (ROUGH_COURSE_FEATURE_END - ROUGH_COURSE_FEATURE_START), 0.0, 1.0)
	match lane_index:
		0:
			# A true cross-lane washboard: low rounded ripples grow from 7 cm
			# to 15 cm peak-to-trough and excite both authored wheelbases.
			var amplitude := lerpf(0.035, 0.075, progress)
			return sin(TAU * (lane_z - ROUGH_COURSE_FEATURE_START) / 1.0) \
				* amplitude * feature_fade
		1:
			# Alternating rounded humps load one wheel at a time while leaving a
			# readable weaving line for the narrower motorcycle.
			var bump_height := 0.0
			for i in range(14):
				var center_z := ROUGH_COURSE_FEATURE_START + 2.0 + i * 3.85
				var center_x := -0.95 if i % 2 == 0 else 0.95
				var height := 0.08 + 0.02 * float(i % 4)
				bump_height += height * _rounded_feature(lane_x - center_x,
					lane_z - center_z, 1.05, 1.35)
			return bump_height * feature_fade
		2:
			# Opposed bowl/mound pairs create cross-axle articulation. The raised
			# deck keeps every pothole above the immutable flat debug collider.
			var cross_height := 0.0
			for i in range(10):
				var center_z := ROUGH_COURSE_FEATURE_START + 3.0 + i * 5.25
				var side := -1.0 if i % 2 == 0 else 1.0
				var depth := 0.12 + 0.03 * float(i / 3)
				var mound := 0.10 + 0.02 * float(i % 4)
				cross_height -= depth * _rounded_feature(
					lane_x - side * 1.10, lane_z - center_z, 0.88, 1.28)
				cross_height += mound * _rounded_feature(
					lane_x + side * 1.10, lane_z - center_z, 0.92, 1.32)
			return cross_height * feature_fade
		_:
			# Deterministic overlapping rocks form a slow crawl line. Relief fades
			# toward +X to retain a marked 0.9 m motorcycle bypass.
			var rocks := 0.0
			var x_pattern := [-1.38, -0.62, 0.18, -1.02, -0.22, 0.48]
			for i in range(24):
				var center_z := ROUGH_COURSE_FEATURE_START + 1.6 + i * 2.24
				var center_x: float = x_pattern[i % x_pattern.size()]
				var height := 0.14 + 0.045 * float(i % 5)
				var radius_x := 0.54 + 0.07 * float((i * 3) % 5)
				var radius_z := 0.72 + 0.08 * float((i * 2) % 4)
				rocks += height * _rounded_feature(lane_x - center_x,
					lane_z - center_z, radius_x, radius_z)
			var bike_bypass := 1.0 - smoothstep(0.62, 1.32, lane_x)
			return minf(rocks, 0.32) * bike_bypass * feature_fade


func _rounded_feature(dx: float, dz: float, radius_x: float,
		radius_z: float) -> float:
	var distance := sqrt(dx * dx / (radius_x * radius_x)
		+ dz * dz / (radius_z * radius_z))
	if distance >= 1.0:
		return 0.0
	return 0.5 + 0.5 * cos(PI * distance)


func _rough_course_sign(text: String, at: Vector3, color: Color,
		board_width: float) -> void:
	var post := _solid_box(at + Vector3.UP,
		Vector3(0.12, 2.0, 0.12), Color(0.26, 0.20, 0.13))
	post.name = "CourseSign_" + text.get_slice("\n", 0).validate_node_name()
	var board := MeshInstance3D.new()
	var board_mesh := BoxMesh.new()
	board_mesh.size = Vector3(board_width, 1.35, 0.12)
	board.mesh = board_mesh
	board.position = Vector3(0.0, 1.40, 0.0)
	var board_material := StandardMaterial3D.new()
	board_material.albedo_color = color
	board_material.roughness = 0.9
	board.material_override = board_material
	post.add_child(board)
	var label := Label3D.new()
	label.text = text
	label.font_size = 78
	label.outline_size = 14
	label.pixel_size = 0.004
	label.modulate = Color(0.98, 0.97, 0.86)
	label.no_depth_test = true
	# Keep the text plane parallel to the physical board. A full billboard tilts
	# toward elevated cameras and lets its upper line sink behind the board.
	label.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	label.position = Vector3(0.0, 1.40, -0.08)
	post.add_child(label)


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
	# SupplyHut owns and parents its lazy collision body; the debug fixture only
	# needs to request construction. Re-adding the returned body emitted an error
	# before every vehicle test and could mask a real model/physics failure.
	hut.build_collisions()


func _build_signs() -> void:
	var titles := [
		["PARKOUR →", Vector3(7.0, GROUND_Y + 2.4, 0.0)],
		["RANGE ↓", Vector3(0.0, GROUND_Y + 2.4, -11.5)],
		["ROPES ←", Vector3(-11.0, GROUND_Y + 2.4, 6.0)],
		["SUSPENSION ↖", Vector3(-11.0, GROUND_Y + 2.4, 24.0)],
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
