extends SceneTree
## Bounded regression for authority metering, registry exhaustion and recovery.
## Does not start networking or use an existing career/save directory.
var checks := 0
var passed := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok:
		passed += 1
	print("FRONTIERRELIABILITY %s %s" % ["OK" if ok else "FAIL", label])

func _run() -> void:
	var network_script = load("res://scripts/frontier_network.gd")
	var domain_script = load("res://scripts/frontier_societies.gd")
	var net := root.get_node("Net")
	var service: Node = network_script.new()
	net.add_child(service)
	check(not net.active, "fixture leaves multiplayer and installed progress inactive")
	service.societies = domain_script.new()
	service.societies.new_game(2026)
	service.authoritative = true
	service.society_ready = true
	service.persistence_enabled = false
	var local_id: int = net.local_id()
	# Same 3-second journey: regularly spaced updates, bursty 20 Hz updates
	# between render frames, and a single delayed sample all cover equal metres.
	for profile: Array in [[1, 22.0, 0.038], [2, 18.0, 0.07], [3, 150.0, 0.64]]:
		var kind := int(profile[0])
		var speed := float(profile[1])
		var expected := float(profile[2]) * 3.0
		var whole: float = network_script.metered_fuel(kind, 3.0, speed * 3.0)
		check(absf(whole - expected) < 0.000001, "kind %d burns the calibrated idle and traction fuel" % kind)
		for cadence: Array in [[20, 1], [60, 3], [120, 6], [120, 360]]:
			var fps := int(cadence[0])
			var frames_per_packet := int(cadence[1])
			var id := "meter-%d-%d-%d" % [kind, fps, frames_per_packet]
			service.societies.register_vehicle(id, kind)
			var initial: float = service.societies.state.vehicle_fuel[id].fuel_l
			net.claimed_vehicles[id] = local_id
			net._vehicle_kinds[id] = kind
			net._vehicle_positions[id] = Vector3(0, 4, 0)
			service._vehicle_motion[id] = Vector3(0, 4, 0)
			for frame in range(1, fps * 3 + 1):
				if frame % frames_per_packet == 0:
					net._vehicle_positions[id] = Vector3(speed * float(frame) / fps, 4, 0)
				service._tick_player_fuel(1.0 / fps)
			var used: float = initial - service.societies.state.vehicle_fuel[id].fuel_l
			check(absf(used - expected) < 0.000001,
				"kind %d actual tank debit is independent of %d FPS / %d-frame packets" % [kind, fps, frames_per_packet])
			net.claimed_vehicles.erase(id)
			net._vehicle_kinds.erase(id)
			net._vehicle_positions.erase(id)
			service._vehicle_motion.erase(id)
	# A full finite registry must reject an unregistered vehicle before granting
	# the seat, while already registered vehicles retain their depleted tank.
	while service.societies.state.vehicle_fuel.size() < 256:
		service.societies.register_vehicle("capacity-%d" % service.societies.state.vehicle_fuel.size(), 1)
	var checkpoint: Dictionary = service.societies.export_state()
	var messages: Array = []
	service.action_finished.connect(func(serial, kind, result): messages.append([serial, kind, result]))
	check(not service.prepare_player_vehicle("capacity-overflow", 1, local_id), "full registry rejects a new seat preparation")
	check(service.societies.export_state() == checkpoint and not service._vehicle_motion.has("capacity-overflow"),
		"capacity failure grants neither a tank nor motion authority and preserves ledgers")
	check(messages.size() == 1 and not messages[0][2].ok and "full" in str(messages[0][2].message),
		"capacity rejection gives the local player a concrete explanation")
	var retained_id := "meter-1-20-1"
	var retained: Dictionary = service.societies.state.vehicle_fuel[retained_id].duplicate(true)
	check(service.prepare_player_vehicle(retained_id, 1, local_id)
		and service.societies.state.vehicle_fuel[retained_id] == retained,
		"a full registry still accepts an existing vehicle without reprovisioning fuel")
	service.stop()
	service.free()
	_test_backup_recovery()
	print("FRONTIERRELIABILITYTEST %d/%d %s" % [passed, checks, "PASS" if passed == checks else "FAIL"])
	quit(0 if passed == checks else 1)

func _test_backup_recovery() -> void:
	var folder := OS.get_temp_dir().path_join("troop-frontier-reliability-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	check(DirAccess.make_dir_recursive_absolute(folder) == OK, "recovery fixture creates its own temporary directory")
	var path := folder.path_join("career.json")
	var sim = load("res://scripts/frontier_sim.gd").new()
	sim.new_game(8129)
	sim.tick(17.0)
	check(sim.save_game(path + ".bak") and not FileAccess.file_exists(path), "fixture contains a valid backup with no main save")
	# JSON restores numeric types according to its parser; compare the actual
	# committed representation so this checks recovery rather than int/float tags.
	var expected: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path + ".bak"))
	var world = load("res://scripts/world.gd").new()
	var controller = load("res://tests/frontier_recovery_test_controller.gd").new()
	controller.configure(null, world, null, true, path)
	check(controller.simulation.state == expected and controller.persistence_enabled,
		"production controller recovers the preceding career when only its backup exists")
	check(controller.save_progress() and sim.load_game(path) and sim.state == expected,
		"recovered career can write a main checkpoint without resetting progress")
	controller.persistence_enabled = false
	controller.free()
	world.free()
	DirAccess.remove_absolute(path)
	var file := FileAccess.open(path + ".bak", FileAccess.WRITE)
	file.store_string("unreadable fixture backup")
	file.close()
	world = load("res://scripts/world.gd").new()
	controller = load("res://tests/frontier_recovery_test_controller.gd").new()
	controller.configure(null, world, null, true, path)
	check(not controller.persistence_enabled and not controller.save_progress(),
		"an unreadable backup-only career disables autosave")
	check(not FileAccess.file_exists(path) and FileAccess.get_file_as_string(path + ".bak") == "unreadable fixture backup",
		"failed recovery preserves the only existing evidence and creates no replacement career")
	controller.free()
	world.free()
	for name in ["career.json", "career.json.tmp", "career.json.bak", "career.json.bak.tmp"]:
		if FileAccess.file_exists(folder.path_join(name)):
			DirAccess.remove_absolute(folder.path_join(name))
	DirAccess.remove_absolute(folder)
