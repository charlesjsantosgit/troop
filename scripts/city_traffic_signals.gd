extends Node3D
## Nearby signs and live indications: bounded instancing, no independent timers.
const Traffic = preload("res://scripts/city_traffic.gd")
const Plan = preload("res://scripts/city_plan.gd")
const RADIUS := 4
const DIGITS := [0b1111110, 0b0110000, 0b1101101, 0b1111001, 0b0110011, 0b1011011, 0b1011111, 0b1110000, 0b1111111, 0b1111011]
var controller: RefCounted
var records: Array[Dictionary] = []
var _batches: Dictionary = {}
var _transforms: Dictionary = {}
var _colors: Dictionary = {}
var _display_cache: Dictionary = {}
var _emitted_power: Dictionary = {}
var _resources: Dictionary = {}

func _ready() -> void:
	name = "RoadSignalsAndSigns"

func rebuild(center: Vector2i) -> void:
	for child in get_children():
		child.visible = false
		child.queue_free()
	records.clear()
	_batches.clear()
	_transforms.clear()
	_colors.clear()
	_display_cache.clear()
	_emitted_power.clear()
	_resources_once()
	position = Vector3(Traffic.point(center).x, Plan.GROUND_Y, Traffic.point(center).y)
	for z in range(-RADIUS, RADIUS + 1):
		for x in range(-RADIUS, RADIUS + 1):
			var key := center + Vector2i(x, z)
			var approaches := Traffic.approaches(key)
			if approaches.is_empty(): continue
			controller.ensure(key)
			var origin := Vector3(float(x) * Plan.STREET_SPACING.x, 0, float(z) * Plan.STREET_SPACING.y)
			var record := {"key": key, "lenses": [], "hands": [], "walks": [], "digits": []}
			for direction in approaches:
				var d := Vector3(direction.x, 0, direction.y)
				var r := Vector3(-direction.y, 0, direction.x)
				var yaw := atan2(-float(direction.x), -float(direction.y))
				var pole := origin - d * (Traffic.cross_half(key, direction) + 4.75) + r * (Traffic.road_half(Traffic.road_index(key, direction)) + 2.15)
				var pole_height := 5.5 if Traffic.signalized(key) else 2.95
				_put("structure", _transform(pole + Vector3.UP * pole_height*.5, Vector3(0.14, pole_height, 0.14)), Color("626768"))
				if Traffic.signalized(key):
					_put("structure", _transform(pole - r * 1.7 + Vector3.UP * 5.45, Vector3(3.7, 0.14, 0.14), yaw), Color("626768"))
					for head in range(2):
						var at := pole - r * float(head) * 3.3 + Vector3.UP * 4.75
						_put("structure", _transform(at, Vector3(0.43, 1.28, 0.28), yaw), Color("252922"))
						for lens in range(3):
							var color: Color = [Color("ff301a"), Color("ffc226"), Color("41ff83")][lens]
							var index := _put("lamps", _transform(at + Vector3.UP * (0.38 - lens * 0.38) - d * 0.18, Vector3(0.31, 0.31, 0.09), yaw), color)
							record.lenses.append({"index": index, "direction": direction, "lens": lens})
					_sign("no_red", pole + Vector3.UP * 3.25 - d * 0.13, Vector2(0.7, 0.62), yaw)
				else:
					_put("stop_shape", _transform(pole + Vector3.UP * 2.65, Vector3(0.86, 0.86, 0.07), yaw), Color("f2efdf"))
					_put("stop_shape", _transform(pole + Vector3.UP * 2.65 - d * .012, Vector3(0.79, 0.79, 0.07), yaw), Color("c72328"))
					_put("stop", _transform(pole + Vector3.UP * 2.65 - d * 0.05, Vector3.ONE, yaw), Color.WHITE)
					_sign("all_way", pole + Vector3.UP * 2.04 - d * 0.10, Vector2(0.58, 0.24), yaw)
				if posmod(key.x + key.y, 3) == 0:
					_sign("speed25" if Traffic.speed_limit(key, direction) > 9.0 else "speed15", pole + Vector3.UP * 1.45 - d * 0.12, Vector2(0.58, 0.76), yaw)
				var one_way := Traffic.one_way_direction(key, 0 if direction.x == 0 else 1)
				if one_way != Vector2i.ZERO:
					_sign("one_way", pole + Vector3.UP * 3.8 - d * 0.15, Vector2(1.12, 0.30), atan2(-float(one_way.y), float(one_way.x)))
			# Wrong-way entrances on one-way streets carry DO NOT ENTER signs.
			for direction in Traffic.DIRECTIONS:
				if not Traffic.edge_exists(key-direction,key) or Traffic.edge_allowed(key-direction,key): continue
				var d := Vector3(direction.x,0,direction.y)
				var r := Vector3(-direction.y,0,direction.x)
				var yaw := atan2(-float(direction.x),-float(direction.y))
				var pole := origin - d * (Traffic.cross_half(key,direction)+4.75) + r*(Traffic.road_half(Traffic.road_index(key,direction))+2.15)
				_put("structure",_transform(pole+Vector3.UP*1.35,Vector3(.10,2.7,.10)),Color("626768"))
				_put("lamps",_transform(pole+Vector3.UP*2.50,Vector3(.8,.8,.06),yaw),Color("ec372b"))
				_put("structure",_transform(pole+Vector3.UP*2.50-d*.055,Vector3(.60,.12,.02),yaw),Color("eee9d9"))
				_put("no_entry",_transform(pole+Vector3.UP*2.50-d*.06,Vector3.ONE,yaw),Color("eee9d9"))
			# Pedestrian heads face both ends of each legal crosswalk.
			if Traffic.signalized(key):
				for arm in Traffic.DIRECTIONS:
					if not Traffic.edge_exists(key, key + arm): continue
					var crossing := Traffic.crossing(key, arm)
					for endpoint in range(2):
						var toward := (crossing[endpoint] - crossing[1 - endpoint]).normalized()
						var yaw := atan2(toward.x, toward.y)
						# Stand outside both the crosswalk and its sidewalk approach.
						var pole_at := pedestrian_pole(key,arm,endpoint)-Traffic.point(center)
						var at := Vector3(pole_at.x,2.0,pole_at.y)
						_put("structure", _transform(at - Vector3.UP * 0.9, Vector3(0.08, 2.2, 0.08)), Color("626768"))
						_put("structure", _transform(at, Vector3(0.95, 0.55, 0.20), yaw), Color("252922"))
						var front := Vector3(toward.x, 0, toward.y) * 0.12
						record.hands.append(_put("hand", _transform(at + front, Vector3.ONE * 0.34, yaw), Color("ff9a24")))
						record.walks.append(_put("walk", _transform(at + front, Vector3.ONE * 0.38, yaw), Color("eef8ec")))
						for digit in range(2):
							var digit_indices: Array[int] = []
							for segment in range(7):
								var offsets := [Vector2(0,.14), Vector2(.075,.07), Vector2(.075,-.07), Vector2(0,-.14), Vector2(-.075,-.07), Vector2(-.075,.07), Vector2.ZERO]
								var pos: Vector2 = offsets[segment] + Vector2(.17 + digit * .18, 0)
								var basis := Basis(Vector3.UP, yaw)
								var size := Vector3(.105,.028,.015) if segment in [0,3,6] else Vector3(.027,.104,.015)
								digit_indices.append(_put("digits", Transform3D(basis * Basis.from_scale(size), at + front + basis * Vector3(pos.x,pos.y,0)), Color("ff9a24")))
							record.digits.append({"tens": digit == 0, "indices": digit_indices})
			records.append(record)
	for label in _transforms: _build_batch(label)
	update_displays()

func update_displays() -> void:
	for record in records:
		var state: Dictionary = controller.display(record.key)
		if _display_cache.get(record.key, {}) == state: continue
		_display_cache[record.key] = state
		for lens: Dictionary in record.lenses:
			var indication: String = state.north_south if lens.direction.x == 0 else state.east_west
			_power("lamps", lens.index, (int(lens.lens) == 0 and bool(state.flash)) if indication == "flash_red" else indication == ["red", "yellow", "green"][lens.lens])
		for index: int in record.walks: _power("walk", index, state.pedestrian == "walk")
		for index: int in record.hands: _power("hand", index, state.pedestrian == "stop" or (state.pedestrian == "clearance" and state.flash))
		for digit: Dictionary in record.digits:
			var number: int = state.countdown / 10 if digit.tens else posmod(int(state.countdown), 10)
			for segment in range(7):
				_power("digits", digit.indices[segment], state.countdown >= 0 and (DIGITS[clampi(number, 0, 9)] & (1 << (6 - segment))) != 0)

func displayed_state(key: Vector2i) -> Dictionary:
	return _display_cache.get(key, {}).duplicate(true)

func emitted_lenses(key: Vector2i, direction: Vector2i) -> Array[int]:
	var result: Array[int] = []
	for record in records:
		if record.key != key: continue
		for lens in record.lenses:
			if lens.direction == direction and bool(_emitted_power.lamps[lens.index]): result.append(int(lens.lens))
	return result

func emitted_pedestrian(key: Vector2i) -> Dictionary:
	var result := {"walk":0,"hand":0}
	for record in records:
		if record.key != key: continue
		for index in record.walks:
			if bool(_emitted_power.walk[index]): result.walk += 1
		for index in record.hands:
			if bool(_emitted_power.hand[index]): result.hand += 1
	return result

func stats() -> Dictionary:
	return {"junctions": records.size(), "draw_batches": _batches.size(), "physics_bodies": 0}

func _power(label: String, index: int, active: bool) -> void:
	_emitted_power[label][index] = active
	_batches[label].multimesh.set_instance_custom_data(index, Color(1.0 if active else 0.0, 0, 0, 1))

func _put(label: String, transform: Transform3D, color: Color) -> int:
	if not _transforms.has(label):
		_transforms[label] = []
		_colors[label] = []
	var index: int = _transforms[label].size()
	_transforms[label].append(transform)
	_colors[label].append(color)
	return index

func _sign(label: String, at: Vector3, size: Vector2, yaw: float) -> void:
	var toward := Basis(Vector3.UP, yaw) * Vector3(0, 0, 0.025)
	_put("structure", _transform(at, Vector3(size.x, size.y, 0.028), yaw), Color("eee9d9"))
	_put(label, _transform(at + toward, Vector3.ONE, yaw), Color("202326"))

static func _transform(at: Vector3, size: Vector3, yaw := 0.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(size), at)

func _resources_once() -> void:
	if not _resources.is_empty(): return
	_resources.structure = BoxMesh.new()
	_resources.digits = _resources.structure
	var circle := SphereMesh.new()
	circle.radius = 0.5
	circle.height = 1.0
	circle.radial_segments = 12
	circle.rings = 6
	_resources.lamps = circle
	_resources.stop_shape = _polygon([Vector2(-.2,-.5),Vector2(.2,-.5),Vector2(.5,-.2),Vector2(.5,.2),Vector2(.2,.5),Vector2(-.2,.5),Vector2(-.5,.2),Vector2(-.5,-.2)])
	_resources.hand = _symbol(true)
	_resources.walk = _symbol(false)
	var texts := {"stop": ["STOP", 0.22], "all_way": ["ALL WAY", 0.10], "no_red": ["NO TURN\nON RED", 0.12], "speed25": ["SPEED\nLIMIT\n25", 0.15], "speed15": ["SPEED\nLIMIT\n15", 0.15], "one_way": ["ONE WAY >", 0.12], "no_entry": ["DO NOT\n\nENTER",0.10]}
	for label in texts:
		var mesh := TextMesh.new()
		mesh.text = texts[label][0]
		mesh.font_size = 48
		mesh.pixel_size = float(texts[label][1]) / 48.0
		mesh.depth = 0.001
		_resources[label] = mesh

static func _polygon(points: Array) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(1, points.size() - 1):
		for p: Vector2 in [points[0], points[index], points[index + 1]]:
			surface.set_normal(Vector3.BACK)
			surface.add_vertex(Vector3(p.x, p.y, 0))
	return surface.commit()

static func _symbol(hand: bool) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var strokes: Array = []
	if hand:
		strokes = [[Vector2(-.015,-.18),Vector2(-.015,.23),.43], [Vector2(-.18,.20),Vector2(-.18,.40),.085], [Vector2(-.065,.20),Vector2(-.065,.49),.085], [Vector2(.05,.20),Vector2(.05,.47),.085], [Vector2(.165,.20),Vector2(.165,.37),.085], [Vector2(-.20,-.04),Vector2(-.40,.17),.13]]
	else:
		strokes = [[Vector2(0,.36),Vector2(0,.47),.20], [Vector2(0,.25),Vector2(-.04,-.10),.14], [Vector2(-.02,.20),Vector2(-.27,.02),.095], [Vector2(-.01,.22),Vector2(.24,.06),.095], [Vector2(-.04,-.08),Vector2(-.27,-.43),.115], [Vector2(-.04,-.08),Vector2(.20,-.40),.115]]
	for stroke in strokes:
		var a: Vector2 = stroke[0]
		var b: Vector2 = stroke[1]
		var perpendicular := Vector2(-(b-a).y,(b-a).x).normalized() * float(stroke[2]) * .5
		var corners := [a-perpendicular,a+perpendicular,b+perpendicular,b-perpendicular]
		for index in [0,1,2,0,2,3]:
			var p: Vector2 = corners[index]
			surface.set_normal(Vector3.BACK)
			surface.add_vertex(Vector3(p.x-.12,p.y,0))
	return surface.commit()

func _build_batch(label: String) -> void:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.use_custom_data = true
	multi.mesh = _resources[label]
	multi.instance_count = _transforms[label].size()
	_emitted_power[label] = []
	_emitted_power[label].resize(multi.instance_count)
	_emitted_power[label].fill(false)
	for index in range(multi.instance_count):
		multi.set_instance_transform(index, _transforms[label][index])
		var color: Color = _colors[label][index]
		multi.set_instance_color(index, color.srgb_to_linear() if label in ["lamps","hand","walk","digits"] else color)
		multi.set_instance_custom_data(index, Color(.18,0,0,1))
	var instance := MultiMeshInstance3D.new()
	instance.name = "Traffic_" + label
	instance.multimesh = multi
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if label in ["lamps", "hand", "walk", "digits"]:
		var material := ShaderMaterial.new()
		material.shader = preload("res://scripts/city_traffic_signal.gdshader")
		material.set_shader_parameter("dark_lenses", label == "lamps")
		instance.material_override = material
	else:
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.roughness = 0.65
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		instance.material_override = material
	add_child(instance)
	_batches[label] = instance

static func pedestrian_pole(key: Vector2i, arm: Vector2i, endpoint: int) -> Vector2:
	var crossing := Traffic.crossing(key,arm)
	var outside := (crossing[endpoint]-crossing[1-endpoint]).normalized()
	return crossing[endpoint]+Vector2(arm)*.9+outside*1.1
