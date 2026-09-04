extends Node
## Exercise the actual equipped gear, I-inventory binding and finite stocks in
## a disposable career. Inventory views never manufacture a second ledger.
var passed := 0
var total := 0
func check(ok: bool, message: String) -> void:
	total += 1
	if ok: passed += 1
	print("BACKPACK %s %s" % ["PASS" if ok else "FAIL", message])

func run(main: Node) -> void:
	var controller: FrontierController = main.frontier_controller
	controller.persistence_enabled = false
	controller.simulation_enabled = false
	var manager: ExpeditionManager = main.expedition_manager
	var player: MonkeyPlayer = main.world.local_player
	player.test_mode = true
	player._invulnerable_t = 1000.0
	var ui: BackpackInventoryUI = manager.inventory_ui
	var sim = controller.simulation
	check(manager.local_inventory.has_backpack() and ui.controller == controller,
		"default field equipment binds I inventory to actual town stock")
	var pack := manager._normal_backpack_visual
	check(is_instance_valid(pack) and pack.get_parent() == player.rig.torso_p,
		"visible field pack is attached below the anatomical torso, not the physics root")
	var pack_id := pack.get_instance_id()
	manager._sync_field_backpacks()
	check(manager._normal_backpack_visual.get_instance_id() == pack_id,
		"repeated equipment synchronization reuses the fitted pack")
	var initial := pack.global_transform
	player.rig.torso_p.rotation.x += 0.25
	check(not pack.global_transform.is_equal_approx(initial) and pack.position.is_zero_approx(),
		"working torso poses carry the pack without a separate animation loop")
	player.rig.reset_pose_state()
	var local_layers := true
	for visual: MeshInstance3D in pack.find_children("*", "MeshInstance3D", true, false):
		local_layers = local_layers and visual.layers == MonkeyRig.LOCAL_BODY_VISUAL_LAYER
	check(local_layers, "local backpack uses the first-person body exclusion layer")
	var replica = load("res://scripts/puppet.gd").new()
	replica.setup(47, "Backpack neighbor")
	main.world.add_child(replica)
	var remote := FieldBackpack.fit_to(replica, false)
	var remote_layers := is_instance_valid(remote)
	for visual: MeshInstance3D in remote.find_children("*", "MeshInstance3D", true, false):
		remote_layers = remote_layers and visual.layers == 1
	check(remote_layers, "remote players wear visible field gear on the normal world layer")
	replica.queue_free()
	var suit := manager._ensure_suit_for_peer(Net.local_id())
	manager._sync_field_backpacks()
	check(suit.equipped and not pack.visible, "pressure suit replaces ordinary backpack presentation")
	suit.set_vacuum_exposure(false)
	suit.unequip()
	manager._sync_field_backpacks()
	check(pack.visible and pack.get_instance_id() == pack_id,
		"returning to breathable air restores the same field pack")
	check(ui.open_inventory() and ui.visible and ui.displayed_slot_count() == controller.backpack_items().size(),
		"I opens actual carried goods as inventory tiles")
	var expected := 0
	for count in sim.state.inventories.player_earth.values(): expected += int(count)
	check(controller.backpack_used() == expected and controller.backpack_capacity() == int(sim.state.locations.player_earth.capacity),
		"displayed contents and capacity come from the authoritative storage contract")
	var rows := controller.backpack_items()
	rows[0].count = 999999
	check(controller.backpack_used() == expected, "editing an inventory display snapshot cannot create goods")
	var before_bag: int = sim.stock("player_earth", "banana")
	var before_shop: int = sim.stock("earth_market", "banana")
	var money: int = sim.balance("player") + sim.balance("earth_market")
	var bought: Dictionary = sim.action("buy", {"item":"banana", "quantity":2, "market":"earth_market"})
	controller.backpack_changed.emit()
	var banana_tile: Button
	for tile: Button in ui._buttons:
		if tile.item_id == "banana": banana_tile = tile
	check(bought.ok and sim.stock("player_earth", "banana") == before_bag + 2 \
		and sim.stock("earth_market", "banana") == before_shop - 2 and banana_tile.count == before_bag + 2,
		"buy moves finite goods from merchant to backpack and refreshes the open tile")
	var sold: Dictionary = sim.action("sell", {"item":"banana", "quantity":1, "market":"earth_market"})
	controller.backpack_changed.emit()
	check(sold.ok and banana_tile.count == before_bag + 1 \
		and sim.stock("earth_market", "banana") == before_shop - 1 \
		and sim.balance("player") + sim.balance("earth_market") == money,
		"selling removes the same carried stock and conserves merchant/player money")
	var before_reject := JSON.stringify(sim.state.inventories)
	var denied: Dictionary = sim.action("sell", {"item":"banana", "quantity":1000, "market":"earth_market"})
	check(not denied.ok and JSON.stringify(sim.state.inventories) == before_reject,
		"attempting to sell more than the backpack owns leaves both inventories intact")
	var saved_capacity: int = sim.state.locations.player_earth.capacity
	sim.state.locations.player_earth.capacity = controller.backpack_used()
	denied = sim.action("buy", {"item":"banana", "quantity":1, "market":"earth_market"})
	check(not denied.ok and JSON.stringify(sim.state.inventories) == before_reject,
		"a full backpack rejects purchases without charging or moving stock")
	sim.state.locations.player_earth.capacity = saved_capacity
	manager.local_inventory.add_item(LunarInventory.ITEM_MOON_CHEESE, 3)
	ui._set_pockets(true)
	check(ui.displayed_slot_count() == manager.local_inventory.slot_count() \
		and manager.local_inventory.count_item(LunarInventory.ITEM_MOON_CHEESE) == 3,
		"personal expedition items remain accessible alongside town goods")
	ui._set_pockets(false)
	var copied = load("res://scripts/frontier_sim.gd").new()
	var saved := "user://backpack-fixture.json"
	var saved_ok: bool = sim.save_game(saved)
	var loaded_ok: bool = copied.load_game(saved)
	var preserved: bool = saved_ok and loaded_ok
	if preserved:
		preserved = copied.state.inventories.player_earth.size() == sim.state.inventories.player_earth.size()
		for id: String in sim.state.inventories.player_earth:
			preserved = preserved and copied.stock("player_earth", id) == sim.stock("player_earth", id)
	check(preserved,
		"save/reload preserves exact carried stock without a second bag file")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(saved))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(saved + ".bak"))
	ui.close_inventory()
	main._return_to_main_menu()
	await get_tree().process_frame
	await get_tree().process_frame
	print("BACKPACKTEST %d/%d %s" % [passed,total,"PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
