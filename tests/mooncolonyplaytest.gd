extends Node
## Real player E input, visible market controls, lunar grounding and lifecycle.
## Main boots this fixture directly on the Moon with save I/O disabled.

var passed := 0
var total := 0
var _last_action := ""
var _last_reason := ""
var _last_accepted := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _check(ok: bool, label: String, detail := "") -> void:
	total += 1
	passed += int(ok)
	if not ok and not _last_accepted:
		detail += " last_action=%s reason=%s" % [_last_action, _last_reason]
	print("[%s] %s%s" % ["PASS" if ok else "FAIL", label,
		" :: " + detail if not detail.is_empty() else ""])


func _frames(count: int) -> void:
	for _frame in range(count):
		await get_tree().physics_frame
	await get_tree().process_frame


func _move_to(player: MonkeyPlayer, colony: MoonColonyWorld, action: String, target := 0) -> void:
	var position := colony.interaction_position(action, target)
	var moon := player.lunar_world
	player.admin_teleport(position + moon.radial_up_at(position) * 0.8)
	await _frames(100)
	# Fixed-FPS fixtures can teleport across the entire Moon in less than one
	# wall-clock second. Real travel naturally expires this ingress window.
	# Preserve replay and rate behavior within each location; dedicated authority
	# tests independently verify rejection of the ninth request in one window.
	Net._rate_windows.erase("%d:moon_colony" % Net.local_id())


func _remember_result(action: String, accepted: bool, reason: String) -> void:
	_last_action = action
	_last_accepted = accepted
	_last_reason = reason


func _press_e(player: MonkeyPlayer) -> void:
	player.ti.interact_just = true
	await _frames(2)


func _check_static_fixture_geometry(colony: MoonColonyWorld) -> void:
	if DisplayServer.get_name() == "headless":
		print("[SKIP] Static mesh geometry requires the rendered capture gate; headless MultiMesh transforms are placeholders.")
		return
	var instances := 0
	var largest_shear := 0.0
	var nondegenerate := true
	for node in colony.find_children("Shared_*", "MultiMeshInstance3D", true, false):
		var batch := node as MultiMeshInstance3D
		for index in range(batch.multimesh.instance_count):
			var basis := batch.multimesh.get_instance_transform(index).basis
			nondegenerate = nondegenerate and basis.is_finite() \
				and minf(basis.x.length_squared(), minf(basis.y.length_squared(),
					basis.z.length_squared())) > 0.000001
			var x := basis.x.normalized()
			var y := basis.y.normalized()
			var z := basis.z.normalized()
			largest_shear = maxf(largest_shear,
				maxf(absf(x.dot(y)), maxf(absf(y.dot(z)), absf(z.dot(x)))))
			instances += 1
	_check(instances > 20 and nondegenerate and largest_shear < 0.0001,
		"rotated static colony meshes retain perpendicular axes under nonuniform local scaling",
		"instances=%d max_axis_dot=%.7f" % [instances, largest_shear])
	var observatory := colony.facility_roots["observatory"] as Node3D
	var navy := observatory.get_node("Shared_cylinder_navy") as MultiMeshInstance3D
	var gold := observatory.get_node("Shared_cylinder_gold") as MultiMeshInstance3D
	var barrel := navy.multimesh.get_instance_transform(1)
	var cap := gold.multimesh.get_instance_transform(0)
	var barrel_mesh := navy.multimesh.mesh as CylinderMesh
	var cap_mesh := gold.multimesh.mesh as CylinderMesh
	var axis := barrel.basis.y.normalized()
	var centre_offset := cap.origin - barrel.origin
	var axial_offset := centre_offset.dot(axis)
	var radial_offset := centre_offset.slide(axis).length()
	var barrel_tip := barrel_mesh.height * barrel.basis.y.length() * 0.5
	var cap_half_length := cap_mesh.height * cap.basis.y.length() * 0.5
	var barrel_radius := maxf(barrel_mesh.top_radius, barrel_mesh.bottom_radius) \
		* maxf(barrel.basis.x.length(), barrel.basis.z.length())
	var cap_radius := maxf(cap_mesh.top_radius, cap_mesh.bottom_radius) \
		* minf(cap.basis.x.length(), cap.basis.z.length())
	_check(barrel.basis.get_scale().is_equal_approx(Vector3(0.4, 3.3, 0.4)) \
		and cap.basis.y.normalized().dot(axis) > 0.9999 \
		and axial_offset >= barrel_tip \
		and axial_offset - cap_half_length <= barrel_tip + 0.01 \
		and radial_offset + barrel_radius <= cap_radius + 0.01,
		"telescope keeps its authored tube dimensions and its aligned end cap overlaps the barrel tip",
		"cap_axial=%.4f tip=%.4f radial_offset=%.4f" % [axial_offset, barrel_tip, radial_offset])


func run(main: Node) -> void:
	print("MOON COLONY PLAY TEST")
	var manager: ExpeditionManager = main.expedition_manager
	var player: MonkeyPlayer = main.world.local_player
	var moon := manager.moon_world
	var colony := moon.colony_world
	var ui := manager.colony_ui
	Net.moon_colony_result.connect(_remember_result)
	player.test_mode = true
	player._invulnerable_t = 1000.0
	_check(Net.player_realm() == Net.PlayerRealm.MOON and colony != null \
		and not Net._moon_colony_persistence_allowed(),
		"direct Moon entry loads the colony with player saves isolated")
	await _frames(130)
	_check(colony.plot_roots.size() == 6 and colony.landmark_roots.size() == 3 \
		and colony.facility_roots.size() == 6,
		"live Moon contains six farm beds, three exploration sites and all service stations")
	var grounded := true
	var collidable := true
	var fixture_details := ""
	var roots: Array[Node3D] = []
	roots.append_array(colony.plot_roots)
	roots.append_array(colony.landmark_roots)
	for fixture in roots:
		var altitude := moon.altitude_at(fixture.global_position)
		grounded = grounded and absf(altitude) < 0.03 \
			and fixture.global_basis.y.dot(moon.radial_up_at(fixture.global_position)) > 0.999
		var body := fixture.get_node_or_null("FixtureCollision") as StaticBody3D
		collidable = collidable and body != null and body.collision_layer == 1 \
			and body.get_child_count() > 0
		if body == null or absf(altitude) >= 0.03:
			fixture_details += "%s altitude=%.4f collider=%s; " % [fixture.name, altitude, body != null]
	_check(grounded and collidable,
		"farm and landmark fixtures meet the real spherical terrain with radial bases and physical colliders",
		fixture_details)
	_check_static_fixture_geometry(colony)
	var crops := colony.plot_roots[0].get_node("GrowingMoonCheese") as MultiMeshInstance3D
	_check(crops.multimesh.visible_instance_count > 0 \
		and (colony.plot_roots[4].get_node("GrowingMoonCheese") as MultiMeshInstance3D) \
			.multimesh.visible_instance_count == 0,
		"ripe starter crops are visible and locked beds do not show free harvests")
	await _move_to(player, colony, "harvest", 0)
	var nearby := colony.nearest_interaction(player.global_position)
	var bag_before := manager.local_inventory.count_item(LunarInventory.ITEM_MOON_CHEESE)
	_check(str(nearby.get("action", "")) == "harvest" and int(nearby.get("target", -1)) == 0 \
		and player.is_on_floor(), "walking beside a ripe bed exposes its harvest interaction")
	await _press_e(player)
	_check(int(Net.moon_colony_snapshot().cargo.fresh) == 3 \
		and crops.multimesh.visible_instance_count == 0 \
		and manager.local_inventory.count_item(LunarInventory.ITEM_MOON_CHEESE) == bag_before,
		"player E harvest removes the visible crop and adds only authoritative colony cargo")
	await _press_e(player)
	await _press_e(player)
	var planted := Net.moon_colony_snapshot()
	_check(bool(planted.plots[0].planted) and bool(planted.plots[0].tended) \
		and crops.multimesh.visible_instance_count > 0 and int(planted.cargo.fresh) == 3,
		"subsequent E taps plant then tend a new visible crop without reharvesting the old one")
	var remaining_before := float(planted.plots[0].remaining)
	await _frames(90)
	_check(float(Net.moon_colony_snapshot().plots[0].remaining) < remaining_before - 0.5,
		"crop growth advances through the production session clock while playing")
	manager._open_colony_journal()
	_check(ui.visible and not ui.at_market and ui._sell_fresh.disabled \
		and ui._upgrade_buttons[0].disabled and ui._order_buttons[0].disabled,
		"field journal shows progress while remote sale and purchase controls stay disabled")
	manager._set_colony_waypoint("market", 0, "CRATER & CURD")
	_check(not manager.is_ui_open() and str(manager._colony_waypoint.action) == "market" \
		and manager._lunar_bearing(colony.interaction_position("market")).contains("m"),
		"journal navigation closes its modal and creates a distance-bearing guide on the sphere")
	await _move_to(player, colony, "market")
	await _press_e(player)
	_check(manager.is_ui_open() and ui.at_market and not ui._sell_fresh.disabled,
		"player E at the physical counter opens actionable market controls")
	var balance_before := int(Net.scores[Net.local_id()])
	ui._sell_fresh.pressed.emit()
	await _frames(2)
	_check(int(Net.moon_colony_snapshot().cargo.fresh) == 0 \
		and int(Net.scores[Net.local_id()]) == balance_before + 6 \
		and ui._sell_fresh.disabled,
		"visible sell button clears three carried wedges and pays six bananas exactly once")
	balance_before = int(Net.scores[Net.local_id()])
	ui._sell_fresh.pressed.emit()
	await _frames(2)
	_check(int(Net.scores[Net.local_id()]) == balance_before,
		"replayed market button cannot sell already-consumed cargo")
	ui._buy_buttons[0].pressed.emit()
	await _frames(2)
	_check(manager.local_inventory.count_item(LunarInventory.ITEM_MOON_CHEESE) == bag_before + 1 \
		and int(Net.moon_colony_snapshot().cargo.fresh) == 0 \
		and int(Net.scores[Net.local_id()]) == balance_before - 3,
		"bought backpack snacks remain separate from harvest cargo and cannot feed the farm-sale ledger")
	ui._upgrade_buttons[1].pressed.emit()
	await _frames(2)
	_check(int(Net.moon_colony_snapshot().upgrades.growth) == 1 \
		and int(Net.scores[Net.local_id()]) == balance_before - 13,
		"visible market upgrade applies its exact cost and accelerates the actual crop clock")
	manager.close_ui()
	for landmark_id in range(3):
		await _move_to(player, colony, "discover", landmark_id)
		balance_before = int(Net.scores[Net.local_id()])
		await _press_e(player)
		var state := Net.moon_colony_snapshot()
		_check(bool(state.landmarks[landmark_id].discovered) \
			and int(Net.scores[Net.local_id()]) == balance_before + [6, 8, 10][landmark_id] \
			and player.is_on_floor(),
			"physical survey %d grants its named landmark reward" % landmark_id)
		balance_before = int(Net.scores[Net.local_id()])
		await _press_e(player)
		_check(int(Net.scores[Net.local_id()]) == balance_before,
			"revisiting survey %d cannot duplicate its reward" % landmark_id)
	_check(bool(Net.moon_colony_snapshot().survey_perk),
		"exploring all three sites activates the shared growth perk")
	await _move_to(player, colony, "market")
	await _press_e(player)
	ui._upgrade_buttons[3].pressed.emit()
	await _frames(2)
	_check(int(Net.moon_colony_snapshot().upgrades.helper) == 1 \
		and colony.worker.hired and colony.worker.visible \
		and colony.worker is CharacterBody3D and colony.worker.rig is MonkeyRig,
		"hiring through the market reveals a real suited monkey worker with radial physics")
	manager.close_ui()
	await _move_to(player, colony, "farm")
	var worker_start := colony.worker.global_position
	await _frames(660)
	_check(colony.worker.is_on_floor() \
		and absf(moon.altitude_at(colony.worker.global_position)) < 0.25 \
		and colony.worker.up_direction.dot(moon.radial_up_at(colony.worker.global_position)) > 0.999 \
		and colony.worker.global_position.distance_to(worker_start) > 0.6 \
		and int(Net.moon_colony_snapshot().cargo.fresh) >= 3,
		"hired worker walks a physical service route while authority performs real farm work",
		"travel=%.3f altitude=%.3f" % [colony.worker.global_position.distance_to(worker_start),
			moon.altitude_at(colony.worker.global_position)])
	await _move_to(player, colony, "age")
	var fresh_before := int(Net.moon_colony_snapshot().cargo.fresh)
	await _press_e(player)
	_check(int(Net.moon_colony_snapshot().cargo.fresh) == fresh_before - 3 \
		and Net.moon_colony_snapshot().aging.batches.size() == 1,
		"player E at the cellar reserves three cargo for a timed aging batch")
	main._open_pause_menu()
	var paused_snapshot := Net.moon_colony_snapshot()
	var paused_worker := colony.worker.global_position
	var oxygen_before := manager.local_suit.oxygen_seconds
	for _frame in range(20):
		await get_tree().process_frame
	_check(get_tree().paused and main.pause_menu != null \
		and paused_snapshot == Net.moon_colony_snapshot() \
		and colony.worker.global_position.is_equal_approx(paused_worker) \
		and is_equal_approx(manager.local_suit.oxygen_seconds, oxygen_before),
		"Moon pause freezes farming, aging, worker motion and life support together")
	main._close_pause_menu(false)
	await _frames(4)
	_check(not get_tree().paused and manager.admin_travel(Net.PlayerRealm.EARTH) \
		and player.lunar_world == null and not moon.visible and not manager.is_ui_open(),
		"Earth return clears colony interaction, radial physics and lunar presentation")
	var earth_snapshot := Net.moon_colony_snapshot()
	await _frames(35)
	_check(earth_snapshot == Net.moon_colony_snapshot(),
		"Moon colony stops advancing while its owner is back on Earth")
	main._return_to_main_menu()
	await _frames(4)
	_check(main.world == null and main.expedition_manager == null and main.menu != null \
		and not get_tree().paused and Net._moon_colony_player == null,
		"return to main menu releases the colony, actor binding and paused state")
	print("MOONCOLONYPLAYTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
