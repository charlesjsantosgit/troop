class_name MoonColonyWorld
extends Node3D
## Physical presentation of the authoritative colony. Every anchor comes from
## MoonColony's shared layout and every foundation samples the collision sphere.
## This node displays snapshots; actions and rewards remain owned by Net.

const PRESENTATION_INTERVAL := 0.2
const INTERACTION_RANGE := 4.1
const LANDMARK_NAMES := MoonColony.LANDMARK_NAMES

static var _materials: Dictionary = {}
static var _meshes: Dictionary = {}
static var _collision_vertices: Dictionary = {}

var plot_roots: Array[Node3D] = []
var facility_roots: Dictionary = {}
var landmark_roots: Array[Node3D] = []
var worker: MoonFarmWorker
var customer: Node3D
var snapshot: Dictionary = {}
var _moon: Node3D
var _plot_crops: Array[MultiMeshInstance3D] = []
var _plot_labels: Array[Label3D] = []
var _plot_lamps: Array[MeshInstance3D] = []
var _landmark_labels: Array[Label3D] = []
var _batches: Dictionary = {}
var _bodies: Dictionary = {}
var _timer := 0.0
var _aging_label: Label3D
var _aging_wheels: MultiMeshInstance3D
var _built := false
var _plot_standing_local := PackedVector3Array()
var _navigation_local: Dictionary = {}


func configure(moon: Node3D) -> void:
	_moon = moon


func _ready() -> void:
	name = "CraterAndCurdColony"
	if not is_instance_valid(_moon):
		_moon = get_parent()
	_ensure_resources()
	for id in range(6):
		_build_plot(id)
	_build_farm()
	_build_aging_cellar()
	_build_observatory()
	_build_relay()
	_build_crystal_garden()
	_build_wayfinding()
	facility_roots["market"] = _moon.get("cheese_shop")
	_flush_batches()
	_cache_navigation_points()
	worker = MoonFarmWorker.new()
	worker.configure(self, _moon)
	add_child(worker)
	_built = true
	apply_snapshot(snapshot)


func apply_snapshot(state: Dictionary) -> void:
	snapshot = state.duplicate(true)
	if not _built:
		return
	_update_presentation()
	worker.apply_snapshot(snapshot)


func set_customer(actor: Node3D) -> void:
	customer = actor if is_instance_valid(actor) else null
	if is_instance_valid(worker):
		worker.set_customer(customer)


func _process(delta: float) -> void:
	if not _built or not is_visible_in_tree() or not is_instance_valid(customer):
		return
	_timer += delta
	if _timer < PRESENTATION_INTERVAL:
		return
	_timer = 0.0
	# Geometry and crop instances change only when a new snapshot arrives.
	# Billboard visibility is cheap and does not animate unseen fixtures.
	for label in _plot_labels:
		label.visible = label.global_position.distance_squared_to(
			customer.global_position) < 35.0 * 35.0
	for label in _landmark_labels:
		label.visible = label.global_position.distance_squared_to(
			customer.global_position) < 80.0 * 80.0


func nearest_interaction(world_position: Vector3) -> Dictionary:
	if not _built or not is_visible_in_tree():
		return {}
	var nearest: Dictionary = {}
	var nearest_sq := INTERACTION_RANGE * INTERACTION_RANGE
	# A bed always wins over the communal oxygen station while within reach.
	for id in range(plot_roots.size()):
		var point := plot_roots[id].global_position
		var distance_sq := point.distance_squared_to(world_position)
		if distance_sq > nearest_sq:
			continue
		var plot := _plot_state(id)
		var action := "plant"
		var prompt := "E · Plant moon cheese"
		if not bool(plot.get("unlocked", false)):
			action = ""
			prompt = "Unlock more beds at Muenster's market"
		elif bool(plot.get("ready", false)):
			action = "harvest"
			prompt = "E · Harvest ripe moon cheese"
		elif bool(plot.get("planted", false)):
			action = "tend" if not bool(plot.get("tended", false)) else ""
			prompt = "E · Tend cheese · grow faster" if not action.is_empty() \
				else "Growing · %ds until harvest" % ceili(float(plot.get("remaining", 0.0)))
		nearest_sq = distance_sq
		nearest = {"action": action, "target": id, "title": "CURD BED %02d" % (id + 1),
			"prompt": prompt, "position": interaction_position(action, id)}
	if not nearest.is_empty():
		return nearest
	var age_position := interaction_position("age", 0)
	if age_position.distance_squared_to(world_position) <= 3.4 * 3.4:
		return {"action": "age", "target": 0, "title": "THE AGING CELLAR",
			"prompt": "E · Age fresh cheese", "position": age_position}
	for id in range(landmark_roots.size()):
		var point := interaction_position("discover", id)
		if point.distance_squared_to(world_position) > INTERACTION_RANGE * INTERACTION_RANGE:
			continue
		var discovered := _landmark_discovered(id)
		var action := "discover"
		var target := id
		var prompt := "E · Survey this landmark"
		if discovered:
			if id < 2:
				action = "refill"
				target = 2 if id == 0 else 3
				prompt = "E · Refill suit oxygen"
			else:
				action = ""
				prompt = "Crystal garden surveyed · J to view your journal"
		return {"action": action, "target": target, "title": LANDMARK_NAMES[id],
			"prompt": prompt, "position": point}
	var farm_point := interaction_position("refill", 0)
	if farm_point.distance_squared_to(world_position) <= 2.5 * 2.5:
		return {"action": "refill", "target": 0, "title": "CURD COLONY · OXYGEN",
			"prompt": "E · Refill suit oxygen", "position": farm_point}
	return {}


## Navigation destinations are walkable points beside the physical fixture.
func interaction_position(action: String, target: int = 0) -> Vector3:
	if not _built:
		return global_position
	if action in ["plant", "tend", "harvest"] or action.is_empty():
		return plot_standing_position(clampi(target, 0, 5))
	if action in ["market", "upgrade", "sell_fresh", "sell_aged", "contract"]:
		return to_global(_navigation_local["market"])
	if action == "age":
		return to_global(_navigation_local["age"])
	if action == "discover":
		return to_global(_navigation_local["discover%d" % clampi(target, 0, 2)])
	if action == "refill" and target > 0:
		if target == 1:
			return interaction_position("market", 0)
		return interaction_position("discover", 0 if target == 2 else 1)
	return to_global(_navigation_local["farm"])


func plot_standing_position(id: int) -> Vector3:
	return to_global(_plot_standing_local[clampi(id, 0, 5)])


func plot_world_position(id: int) -> Vector3:
	return plot_roots[clampi(id, 0, 5)].global_position


## The service lane goes around beds, so the farmer never walks through crops.
func worker_route(from: Vector3, plot_id: int) -> PackedVector3Array:
	var farm := facility_roots["farm"] as Node3D
	var start := farm.to_local(from)
	var finish := farm.to_local(plot_standing_position(plot_id))
	return PackedVector3Array([
		_ground(farm.to_global(Vector3(-10.2, 0, start.z))),
		_ground(farm.to_global(Vector3(-10.2, 0, finish.z))),
		plot_standing_position(plot_id)])


func worker_home_position() -> Vector3:
	return to_global(_navigation_local["worker_home"])


func _cache_navigation_points() -> void:
	# These targets are fixed to the Moon. Sample their exact support once;
	# per-frame compass/prompt updates only apply the parent world transform.
	for root in plot_roots:
		_plot_standing_local.append(to_local(_ground(root.to_global(Vector3(0, 0, -2.65)))))
	var farm := facility_roots["farm"] as Node3D
	var market := facility_roots["market"] as Node3D
	var aging := facility_roots["aging"] as Node3D
	_navigation_local["farm"] = to_local(_ground(farm.to_global(Vector3(0, 0, -1.1))))
	_navigation_local["worker_home"] = to_local(_ground(farm.to_global(Vector3(-10.2, 0, -6.5))))
	_navigation_local["market"] = to_local(_ground(market.to_global(Vector3(0, 0, -5.8))))
	_navigation_local["age"] = to_local(_ground(aging.to_global(Vector3(0, 0, -2.9))))
	for id in range(landmark_roots.size()):
		_navigation_local["discover%d" % id] = to_local(_ground(
			landmark_roots[id].to_global(Vector3(0, 0, -3.5))))


func _build_plot(id: int) -> void:
	var root := _anchor("CurdBed%02d" % (id + 1), MoonColony.plot_direction(id))
	plot_roots.append(root)
	var base := _foundation(root, Vector2(1.65, 1.8), 0.12)
	_box(root, Vector3(3.3, 0.16, 3.6), Vector3(0, base + 0.08, 0), "navy", true)
	_box(root, Vector3(2.95, 0.09, 3.22), Vector3(0, base + 0.195, 0), "soil")
	for x in [-1.56, 1.56]:
		_box(root, Vector3(0.14, 0.22, 3.6), Vector3(x, base + 0.24, 0), "cream")
	for z in [-1.72, 1.72]:
		_box(root, Vector3(3.3, 0.22, 0.14), Vector3(0, base + 0.24, z), "cream")
	_box(root, Vector3(0.1, 0.65, 0.1), Vector3(-1.45, base + 0.48, -1.7), "navy")
	_box(root, Vector3(0.6, 0.29, 0.075), Vector3(-1.45, base + 0.8, -1.7), "gold")
	var label := _label(root, "BedStatus", "%02d · AWAITING COLONY" % (id + 1),
		Vector3(0, base + 1.4, 0), 0.0036, true)
	label.visibility_range_end = 35.0
	_plot_labels.append(label)
	var crop := MultiMeshInstance3D.new()
	crop.name = "GrowingMoonCheese"
	crop.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	crop.position.y = base + 0.24
	crop.multimesh = MultiMesh.new()
	crop.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	crop.multimesh.use_colors = true
	crop.multimesh.mesh = _meshes["cheese"]
	crop.multimesh.instance_count = 9
	crop.material_override = _materials["crop"]
	crop.visibility_range_end = 100.0
	root.add_child(crop)
	_plot_crops.append(crop)
	var lamp := MeshInstance3D.new()
	lamp.name = "GrowthIndicator"
	lamp.mesh = _meshes["sphere"]
	lamp.position = Vector3(-1.45, base + 1.0, -1.7)
	lamp.scale = Vector3.ONE * 0.07
	lamp.material_override = _materials["mint"]
	lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(lamp)
	_plot_lamps.append(lamp)


func _build_farm() -> void:
	var root := _facility("farm", "CurdColonyFarm")
	var base := _foundation(root, Vector2(0.48, 0.45), 0.03)
	_box(root, Vector3(0.7, 1.25, 0.7), Vector3(0, base + 0.625, 0.35), "navy", true)
	_box(root, Vector3(0.54, 0.45, 0.04), Vector3(0, base + 0.93, -0.02), "mint")
	_label(root, "OxygenLabel", "O₂\nREFILL", Vector3(0, base + 0.94, -0.05), 0.0015)
	_beacon(root, "FARM · OXYGEN", Vector3(0, 0, 0.35), 4.0)
	# The welcome sign is on an independent terrain anchor beyond the beds.
	var direction := MoonColony.facility_direction(&"farm")
	var sign := _anchor("ColonyWelcome", direction + Vector3(-0.034, 0, -0.019))
	var sign_base := _foundation(sign, Vector2(2.5, 0.2), 0.02)
	for x in [-2.0, 2.0]:
		_box(sign, Vector3(0.13, 2.7, 0.15), Vector3(x, sign_base + 1.35, 0), "cream", true)
	_box(sign, Vector3(4.8, 1.12, 0.16), Vector3(0, sign_base + 2.2, 0), "navy", true)
	_label(sign, "ColonyBrand", "CRATER & CURD\nA LITTLE FARM. A WHOLE MOON.",
		Vector3(0, sign_base + 2.2, -0.095), 0.007)


func _build_aging_cellar() -> void:
	var root := _facility("aging", "VacuumAgingCellar")
	var base := _foundation(root, Vector2(2.1, 1.5), 0.08)
	_box(root, Vector3(4.1, 2.7, 2.9), Vector3(0, base + 1.35, 0), "navy", true)
	_box(root, Vector3(4.25, 0.24, 3.05), Vector3(0, base + 2.82, 0), "cream")
	_box(root, Vector3(2.25, 1.65, 0.09), Vector3(-0.45, base + 1.35, -1.49), "glass")
	for y in [0.77, 1.3, 1.83]:
		_box(root, Vector3(2.12, 0.05, 0.14), Vector3(-0.45, base + y, -1.58), "cream")
	_box(root, Vector3(0.65, 0.8, 0.12), Vector3(1.2, base + 1.25, -1.52), "gold")
	_aging_label = _label(root, "CellarStatus", "FRESH → AGED\nE · LOAD CELLAR",
		Vector3(0, base + 3.45, -0.6), 0.0038, true)
	_beacon(root, "AGING CELLAR", Vector3(1.6, base, 0.9), 5.2)
	_aging_wheels = MultiMeshInstance3D.new()
	_aging_wheels.name = "AgingCheeseWheels"
	_aging_wheels.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_aging_wheels.multimesh = MultiMesh.new()
	_aging_wheels.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_aging_wheels.multimesh.mesh = _meshes["cheese"]
	_aging_wheels.multimesh.instance_count = 6
	_aging_wheels.material_override = _materials["gold"]
	for id in range(6):
		_aging_wheels.multimesh.set_instance_transform(id, Transform3D(
			Basis.from_scale(Vector3(0.31, 0.26, 0.31)),
			Vector3(-0.96 + (id % 2) * 0.95, base + 0.94 + (id / 2) * 0.53, -1.6)))
	root.add_child(_aging_wheels)


func _build_observatory() -> void:
	var root := _facility("observatory", "TheLunarLookout")
	landmark_roots.append(root)
	var base := _foundation(root, Vector2(2.0, 2.0), 0.12)
	_cylinder(root, Vector3(1.95, 1.1, 1.95), Vector3(0, base + 0.55, 0), "navy")
	_solid_primitive(root, "cylinder", Vector3(0, base + 0.55, 0), Vector3(1.95, 1.1, 1.95))
	_primitive(root, "sphere", Vector3(0, base + 1.0, 0), Vector3(1.95, 1.9, 1.95), "cream")
	_solid_primitive(root, "sphere", Vector3(0, base + 1.0, 0), Vector3(1.95, 1.9, 1.95))
	_cylinder(root, Vector3(0.4, 3.3, 0.4), Vector3(0, base + 2.0, -0.85), "navy", Vector3(-0.88, 0, 0))
	_solid_primitive(root, "cylinder", Vector3(0, base + 2.0, -0.85), Vector3(0.4, 3.3, 0.4), Vector3(-0.88, 0, 0))
	_cylinder(root, Vector3(0.48, 0.25, 0.48), Vector3(0, base + 3.13, -2.13), "gold", Vector3(-0.88, 0, 0))
	_solid_primitive(root, "cylinder", Vector3(0, base + 3.13, -2.13), Vector3(0.48, 0.25, 0.48), Vector3(-0.88, 0, 0))
	_survey_terminal(root, 0, base)
	_beacon(root, "01 · " + LANDMARK_NAMES[0].to_upper(), Vector3(2.5, base, 0.6), 7.0)


func _build_relay() -> void:
	var root := _facility("relay", "SunwardRelay")
	landmark_roots.append(root)
	var base := _foundation(root, Vector2(1.1, 0.9), 0.08)
	_box(root, Vector3(1.9, 2.4, 1.6), Vector3(0, base + 1.2, 0), "cream", true)
	_box(root, Vector3(1.35, 0.55, 0.09), Vector3(0, base + 1.45, -0.86), "mint")
	for x in [-3.2, 3.2]:
		var panel_direction: Vector3 = _moon.call("radial_up_at", root.to_global(Vector3(x, 0, 0.6)))
		var panel := _anchor("RelaySolarArray", _moon.global_basis.inverse() * panel_direction)
		var foot := _foundation(panel, Vector2(0.45, 0.45), 0.03)
		_box(panel, Vector3(0.13, 1.8, 0.13), Vector3(0, foot + 0.9, 0), "cream", true)
		_primitive(panel, "box", Vector3(0, foot + 1.9, 0), Vector3(3.3, 0.15, 3.8), "navy", Vector3(-0.22, 0, 0))
		_solid_primitive(panel, "box", Vector3(0, foot + 1.9, 0), Vector3(3.3, 0.15, 3.8), Vector3(-0.22, 0, 0))
		for line in [-1.1, 0.0, 1.1]:
			_primitive(panel, "box", Vector3(line, foot + 2.02, 0), Vector3(0.045, 0.035, 3.8), "mint", Vector3(-0.22, 0, 0))
	_survey_terminal(root, 1, base)
	_beacon(root, "02 · " + LANDMARK_NAMES[1].to_upper(), Vector3(0.6, base, 0.65), 8.0)


func _build_crystal_garden() -> void:
	var root := _facility("crystal_garden", "TheCrystalGarden")
	landmark_roots.append(root)
	for id in range(11):
		var angle := float(id) * 2.399963
		var radius := 1.7 + float(id % 3) * 1.25
		var offset := Vector3(cos(angle) * radius, 0, sin(angle) * radius + 1.8)
		var world_point := root.to_global(offset)
		var direction: Vector3 = _moon.call("radial_up_at", world_point)
		var crystal := _anchor("GroundedLunarCrystal%02d" % id, _moon.global_basis.inverse() * direction)
		var height := 1.35 + float((id * 7) % 5) * 0.6
		var buried_base := -0.09
		for side in [Vector3(0.7, 0, 0), Vector3(-0.7, 0, 0), Vector3(0, 0, 0.7), Vector3(0, 0, -0.7)]:
			buried_base = minf(buried_base, crystal.to_local(_ground(crystal.to_global(side))).y - 0.09)
		_primitive(crystal, "crystal", Vector3(0, height * 0.5 + buried_base, 0),
			Vector3(0.5 + float(id % 2) * 0.15, height, 0.5), "crystal")
		_solid_primitive(crystal, "crystal", Vector3(0, height * 0.5 + buried_base, 0),
			Vector3(0.5 + float(id % 2) * 0.15, height, 0.5))
	_survey_terminal(root, 2, 0.0)
	_beacon(root, "03 · " + LANDMARK_NAMES[2].to_upper(), Vector3(-2.0, 0, -0.5), 6.5)


func _survey_terminal(root: Node3D, id: int, base: float) -> void:
	# A separately grounded console stands outside the landmark's solid body.
	var world_point := root.to_global(Vector3(0, 0, -2.4))
	var radial: Vector3 = _moon.call("radial_up_at", world_point)
	var terminal := _anchor("SurveyConsole%02d" % id, _moon.global_basis.inverse() * radial)
	var foot := _foundation(terminal, Vector2(0.4, 0.35), 0.02)
	_box(terminal, Vector3(0.65, 1.0, 0.55), Vector3(0, foot + 0.5, 0), "navy", true)
	_box(terminal, Vector3(0.75, 0.45, 0.12), Vector3(0, foot + 1.1, -0.24), "gold")
	var label := _label(root, "LandmarkStatus", LANDMARK_NAMES[id] + "\nE · SURVEY", Vector3(0, base + 4.5, -1.5), 0.004, true)
	_landmark_labels.append(label)


func _build_wayfinding() -> void:
	# Small separately grounded route posts make the farm discoverable on foot
	# without covering the spherical ground with a floating road mesh.
	var farm_direction := MoonColony.facility_direction(&"farm")
	for id in range(1, 5):
		var direction := Vector3.UP.slerp(farm_direction, float(id) / 5.0)
		var post := _anchor("LandingToFarmMarker%02d" % id, direction)
		_box(post, Vector3(0.09, 0.58, 0.09), Vector3(0, 0.24, 0), "navy")
		_box(post, Vector3(0.3, 0.12, 0.1), Vector3(0, 0.57, 0), "gold")


func _update_presentation() -> void:
	for id in range(plot_roots.size()):
		var plot := _plot_state(id)
		var unlocked := bool(plot.get("unlocked", false))
		var planted := bool(plot.get("planted", false))
		var ready := bool(plot.get("ready", false))
		var progress := clampf(float(plot.get("progress", 0.0)), 0.0, 1.0)
		if ready:
			progress = 1.0
		var size := lerpf(0.1, 0.49, progress)
		var crop := _plot_crops[id].multimesh
		crop.visible_instance_count = 9 if unlocked and planted else 0
		for plant in range(9):
			var wobble := float((id * 13 + plant * 3) % 5) * 0.025
			var plant_scale := Vector3(size, lerpf(0.1, 0.38, progress), size)
			var basis := Basis(Vector3.UP, float(plant) * 1.8).scaled(plant_scale)
			crop.set_instance_transform(plant, Transform3D(basis, Vector3(
				float(plant % 3 - 1) * 0.87, plant_scale.y * 0.5 + wobble,
				float(plant / 3 - 1) * 0.95)))
			crop.set_instance_color(plant, Color(1.0, 0.73, 0.12) if ready \
				else Color(0.58, 0.86, 0.54).lerp(Color(1.0, 0.78, 0.23), progress))
		var state := "RIPE · E TO HARVEST" if ready else "EMPTY · E TO PLANT"
		if not unlocked:
			state = "LOCKED · EXPAND AT MARKET"
		elif planted and not ready:
			state = "%ds · %s" % [ceili(float(plot.get("remaining", 0.0))),
				"TENDED" if bool(plot.get("tended", false)) else "E TO TEND"]
		_plot_labels[id].text = "BED %02d\n%s" % [id + 1, state]
		_plot_lamps[id].material_override = _materials["gold" if ready else ("mint" if unlocked else "soil")]
	var aging: Dictionary = snapshot.get("aging", {})
	var batches: Array = aging.get("batches", [])
	_aging_wheels.multimesh.visible_instance_count = mini(batches.size() * 2, 6)
	_aging_label.text = "THE AGING CELLAR\n%d batch%s · %ds" % [batches.size(),
		"" if batches.size() == 1 else "es", ceili(float(aging.get("remaining", 0.0)))] \
		if not batches.is_empty() else "THE AGING CELLAR\nE · FRESH CHEESE → AGED CHEESE"
	for id in range(_landmark_labels.size()):
		_landmark_labels[id].text = LANDMARK_NAMES[id] + ("\nSURVEYED · OXYGEN AVAILABLE" \
			if _landmark_discovered(id) and id < 2 else ("\nSURVEY COMPLETE" \
			if _landmark_discovered(id) else "\nE · SURVEY THIS LANDMARK"))


func _plot_state(id: int) -> Dictionary:
	var plots: Array = snapshot.get("plots", [])
	for plot in plots:
		if plot is Dictionary and int(plot.get("id", -1)) == id:
			return plot
	return {}


func _landmark_discovered(id: int) -> bool:
	var landmarks: Array = snapshot.get("landmarks", [])
	for landmark in landmarks:
		if landmark is Dictionary and int(landmark.get("id", -1)) == id:
			return bool(landmark.get("discovered", false))
	return false


func _facility(id: String, node_name: String) -> Node3D:
	var root := _anchor(node_name, MoonColony.facility_direction(StringName(id)))
	facility_roots[id] = root
	return root


func _anchor(node_name: String, direction: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	root.position = _moon.call("surface_position", direction.normalized())
	root.basis = MoonWorld.surface_basis(direction.normalized())
	add_child(root)
	return root


func _ground(world_point: Vector3) -> Vector3:
	return _moon.call("surface_position_at", world_point)


func _foundation(root: Node3D, half: Vector2, clearance: float) -> float:
	var bottom := -0.12
	var top := clearance
	for x in [-half.x, 0.0, half.x]:
		for z in [-half.y, 0.0, half.y]:
			var local := root.to_local(_ground(root.to_global(Vector3(x, 0, z))))
			bottom = minf(bottom, local.y - 0.12)
			top = maxf(top, local.y + clearance)
	_box(root, Vector3(half.x * 2, top - bottom, half.y * 2),
		Vector3(0, (top + bottom) * 0.5, 0), "foundation", true)
	return top


func _beacon(root: Node3D, title: String, offset: Vector3, height: float) -> void:
	var world_point := root.to_global(offset)
	var local_ground := root.to_local(_ground(world_point))
	_box(root, Vector3(0.1, height + 0.12, 0.1),
		Vector3(offset.x, local_ground.y + height * 0.5 - 0.06, offset.z), "cream", true)
	_primitive(root, "sphere", Vector3(offset.x, local_ground.y + height, offset.z),
		Vector3.ONE * 0.24, "mint")
	var label := _label(root, "WayfindingBeacon", title,
		Vector3(offset.x, local_ground.y + height + 0.6, offset.z), 0.0007, true)
	# Beacon text holds a modest screen size at range. Depth testing still
	# hides a station behind the spherical horizon instead of revealing it.
	label.fixed_size = true
	label.visibility_range_end = 180.0


func _label(root: Node3D, node_name: String, text_value: String, at: Vector3,
		pixel_scale: float, billboard := false) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = text_value
	label.position = at
	label.font_size = 36
	label.pixel_size = pixel_scale
	label.modulate = Color(1.0, 0.9, 0.61)
	label.outline_modulate = Color(0.015, 0.035, 0.06)
	label.outline_size = 8
	label.no_depth_test = false
	if billboard:
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	else:
		label.rotation.y = PI
	label.visibility_range_end = 70.0
	root.add_child(label)
	return label


func _box(root: Node3D, size: Vector3, at: Vector3, material: String,
		solid := false, render := true) -> void:
	if render:
		_primitive(root, "box", at, size, material)
	if solid:
		var body: StaticBody3D = _bodies.get(root.get_instance_id())
		if not is_instance_valid(body):
			body = StaticBody3D.new()
			body.name = "FixtureCollision"
			body.collision_layer = 1
			body.collision_mask = 1
			root.add_child(body)
			_bodies[root.get_instance_id()] = body
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = size
		shape.shape = box
		shape.position = at
		body.add_child(shape)


func _solid_primitive(root: Node3D, mesh_id: String, at: Vector3, size: Vector3,
		angles := Vector3.ZERO) -> void:
	var body: StaticBody3D = _bodies.get(root.get_instance_id())
	if not is_instance_valid(body):
		body = StaticBody3D.new()
		body.name = "FixtureCollision"
		body.collision_layer = 1
		body.collision_mask = 1
		root.add_child(body)
		_bodies[root.get_instance_id()] = body
	# Shared meshes are immutable; repeated array reads can force GPU readback.
	# Cache once per mesh and never scale the cached source in place.
	if not _collision_vertices.has(mesh_id):
		var mesh: PrimitiveMesh = _meshes[mesh_id]
		_collision_vertices[mesh_id] = mesh.get_mesh_arrays()[Mesh.ARRAY_VERTEX]
	var source_vertices: PackedVector3Array = _collision_vertices[mesh_id]
	var vertices := source_vertices.duplicate()
	for id in range(vertices.size()):
		vertices[id] *= size
	var convex := ConvexPolygonShape3D.new()
	convex.points = vertices
	var collision := CollisionShape3D.new()
	collision.shape = convex
	collision.transform = Transform3D(Basis.from_euler(angles), at)
	body.add_child(collision)


func _cylinder(root: Node3D, size: Vector3, at: Vector3, material: String,
		angles := Vector3.ZERO) -> void:
	_primitive(root, "cylinder", at, size, material, angles)


func _primitive(root: Node3D, mesh_id: String, at: Vector3, size: Vector3,
		material: String, angles := Vector3.ZERO) -> void:
	var key := "%d/%s/%s" % [root.get_instance_id(), mesh_id, material]
	if not _batches.has(key):
		_batches[key] = {"root": root, "mesh": mesh_id, "material": material, "transforms": []}
	var transforms: Array = _batches[key]["transforms"]
	transforms.append(Transform3D(Basis.from_euler(angles).scaled_local(size), at))


func _flush_batches() -> void:
	for key in _batches:
		var batch: Dictionary = _batches[key]
		var instance := MultiMeshInstance3D.new()
		instance.name = "Shared_%s_%s" % [batch["mesh"], batch["material"]]
		instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		instance.multimesh = MultiMesh.new()
		instance.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		instance.multimesh.mesh = _meshes[batch["mesh"]]
		var transforms: Array = batch["transforms"]
		instance.multimesh.instance_count = transforms.size()
		for id in range(transforms.size()):
			instance.multimesh.set_instance_transform(id, transforms[id])
		instance.material_override = _materials[batch["material"]]
		instance.visibility_range_end = 280.0
		(batch["root"] as Node3D).add_child(instance)
	_batches.clear()
	_bodies.clear()


static func _ensure_resources() -> void:
	if not _materials.is_empty():
		return
	var colors := {"navy": Color(0.045, 0.105, 0.17), "cream": Color(0.86, 0.83, 0.69),
		"gold": Color(1.0, 0.68, 0.12), "mint": Color(0.32, 0.85, 0.69),
		"soil": Color(0.18, 0.14, 0.11), "foundation": Color(0.2, 0.22, 0.23),
		"glass": Color(0.04, 0.24, 0.29), "crystal": Color(0.22, 0.71, 0.75), "crop": Color.WHITE}
	for id in colors:
		var material := StandardMaterial3D.new()
		material.albedo_color = colors[id]
		material.roughness = 0.8
		material.disable_fog = true
		if id in ["mint", "crystal"]:
			material.emission_enabled = true
			material.emission = colors[id]
			material.emission_energy_multiplier = 0.22
		if id == "crop":
			material.vertex_color_use_as_albedo = true
			# Small flat cheese tops amplify hard lunar shadow-map acne. They
			# remain sun-lit and cast contact shadows onto the bed and terrain.
			material.disable_receive_shadows = true
		_materials[id] = material
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	_meshes["box"] = box
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0
	cylinder.bottom_radius = 1.0
	cylinder.height = 1.0
	cylinder.radial_segments = 12
	_meshes["cylinder"] = cylinder
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	_meshes["sphere"] = sphere
	var cheese := CylinderMesh.new()
	cheese.top_radius = 0.86
	cheese.bottom_radius = 1.0
	cheese.height = 1.0
	cheese.radial_segments = 7
	_meshes["cheese"] = cheese
	var crystal := CylinderMesh.new()
	crystal.top_radius = 0.02
	crystal.bottom_radius = 1.0
	crystal.height = 1.0
	crystal.radial_segments = 5
	_meshes["crystal"] = crystal
