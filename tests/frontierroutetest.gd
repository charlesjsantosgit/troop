extends Node
## Registered real-world route regression. Main starts a disposable Frontier
## career first. Sweep the physical settlement collision shapes along every
## facility/crop service route, then sweep full tanker bounds on haul routes.
## Terrain and unrelated actors are excluded: their movement is covered by
## frontierplaytest; this gate catches authored walls across working roads.

const RoutesScript = preload("res://scripts/frontier_routes.gd")
const HAUL_LOCATIONS := ["cooperative", "earth_market", "warehouse", "refinery",
	"oil_rig", "gas_station", "airfield", "carrier", "housing"]

var _passed := 0
var _total := 0
var _point_cache: Dictionary = {}


func run(main: Node) -> void:
	var controller: FrontierController = main.frontier_controller
	_check(is_instance_valid(controller) and controller.simulation != null,
		"disposable career has an authoritative model")
	if not is_instance_valid(controller) or controller.simulation == null:
		_finish()
		return
	controller.simulation_enabled = false
	controller.persistence_enabled = false
	_check(not main._frontier_load_saved, "route test never loads or saves the production career")
	for frame in range(3):
		await get_tree().physics_frame
	for planet in ["earth", "moon"]:
		var site: FrontierSite = controller.earth_site if planet == "earth" else controller.moon_site
		var settlement: Node3D = controller.earth_settlement if planet == "earth" else controller.moon_settlement
		var excluded: Array[RID] = []
		_collect_exclusions(main, settlement, excluded)
		_point_cache.clear()
		var locations := _locations(controller.simulation.state, planet, true)
		var audit := _audit(site, locations, excluded, false)
		_check(audit.blocked == 0, "%s: %d facility/plot route segments clear the physical settlement" % [planet, audit.segments], audit.details)
		var haul := _locations(controller.simulation.state, planet, false)
		if planet == "earth":
			for id in haul.keys():
				if id not in HAUL_LOCATIONS:
					haul.erase(id)
		var clearance := _audit(site, haul, excluded, true)
		_check(clearance.blocked == 0, "%s: %d routes fit %s bounds" % [planet, clearance.segments, "the complete tanker" if planet == "earth" else "a suited worker"], clearance.details)
	# Profession and cargo changes must update the physical worker, rather
	# than leaving a farmer holding an invisible manifest of aviation fuel.
	var citizen: Node3D = controller.earth_settlement.citizens.get("wrench")
	if is_instance_valid(citizen):
		var record: Dictionary = controller.simulation.state.citizens.wrench
		var old_job: String = record.job
		var old_cargo: Dictionary = record.carrying.duplicate(true)
		record.job = "tanker_driver"
		record.carrying = {"from": "refinery", "to": "airfield", "item": "jet_fuel", "quantity": 12, "packaging": 0}
		for frame in range(4):
			await get_tree().physics_frame
			citizen.update_citizen(0.1, Vector3.INF)
		var vehicle: Vehicle = citizen.get("_vehicle")
		_check(vehicle is RigidBody3D and vehicle.npc_controlled, "reassigning a mechanic retains its real authoritative vehicle")
		var label: Label3D = citizen.get("_fuel_label")
		var manifest := str(vehicle.get("manifest_text")) if vehicle != null else ""
		_check(manifest == "Jet Fuel · 12 L" and (DisplayServer.get_name()=="headless" or (label!=null and label.text==manifest)), "the vehicle reads its real item/quantity manifest in litres")
		record.job = old_job
		record.carrying = old_cargo
		citizen.update_citizen(0.1, Vector3.INF)
	else:
		_check(false, "mechanic worker is present for profession regression")
	await get_tree().process_frame
	await get_tree().process_frame
	_finish()


func _locations(state: Dictionary, planet: String, include_plots: bool) -> Dictionary:
	var result := {}
	for id in state.locations:
		var location: Dictionary = state.locations[id]
		if location.planet == planet:
			result[id] = location.position.duplicate()
	if include_plots:
		for id in state.plots:
			var plot: Dictionary = state.plots[id]
			if plot.planet == planet:
				result[id] = [plot.position[0], float(plot.position[1]) + 2.5]
	return result


func _audit(site: FrontierSite, locations: Dictionary,
		excluded: Array[RID], sweep: bool) -> Dictionary:
	var result := {"segments": 0, "blocked": 0, "details": ""}
	var physics := site.get_world_3d().direct_space_state
	var shape := BoxShape3D.new()
	shape.size = Vector3(2.1, 2.0, 5.2) if site.planet == "earth" else Vector3(0.55, 1.3, 0.55)
	for from_id in locations:
		for to_id in locations:
			var previous: Array = locations[from_id]
			var route := RoutesScript.path(previous, locations[to_id], site.planet)
			for next in route:
				var a := _world_point(site, previous)
				var b := _world_point(site, next)
				if a.distance_squared_to(b) > 0.0001:
					result.segments += 1
					var blocked := false
					if sweep:
						var up := site.global_basis * site.surface_normal(float(previous[0]), float(previous[1]))
						var query := PhysicsShapeQueryParameters3D.new()
						query.shape = shape
						query.collision_mask = 1
						query.exclude = excluded
						query.transform = Transform3D(Basis.looking_at((b - a).normalized(), up), a + up * 0.55)
						query.motion = b - a
						var motion := physics.cast_motion(query)
						blocked = motion[0] < 0.999
					else:
						var query := PhysicsRayQueryParameters3D.create(a, b, 1, excluded)
						blocked = not physics.intersect_ray(query).is_empty()
					if blocked:
						result.blocked += 1
						if result.blocked <= 5:
							result.details += "%s->%s %s->%s; " % [from_id, to_id, str(previous), str(next)]
				previous = next
	return result


func _world_point(site: FrontierSite, coordinates: Array) -> Vector3:
	var key := "%.4f,%.4f" % [float(coordinates[0]), float(coordinates[1])]
	if not _point_cache.has(key):
		_point_cache[key] = site.surface_point(float(coordinates[0]), float(coordinates[1]), 0.95)
	return _point_cache[key]


func _collect_exclusions(node: Node, settlement: Node3D, excluded: Array[RID]) -> void:
	if node is CollisionObject3D and (not settlement.is_ancestor_of(node) or node is FrontierCitizen):
		excluded.append(node.get_rid())
	for child in node.get_children():
		_collect_exclusions(child, settlement, excluded)


func _check(condition: bool, label: String, details := "") -> void:
	_total += 1
	if condition:
		_passed += 1
	print("  %s %s%s" % ["PASS" if condition else "FAIL", label, " :: " + details if not details.is_empty() else ""])


func _finish() -> void:
	print("FRONTIERROUTETEST %d/%d %s" % [_passed, _total, "PASS" if _passed == _total else "FAIL"])
	get_tree().quit(0 if _passed == _total else 1)
