extends Node
## Full player/camera/realm regression against production lunar collision.
var passed := 0
var total := 0

func _check(ok: bool, label: String, detail := "") -> void:
	total += 1
	if ok:
		passed += 1
	print("[%s] %s %s" % ["PASS" if ok else "FAIL", label, detail])

func _frames(count: int) -> void:
	for frame in range(count):
		await get_tree().physics_frame

func run(main: Node) -> void:
	var manager: ExpeditionManager = main.expedition_manager
	var player: MonkeyPlayer = main.world.local_player
	var moon := manager.moon_world
	player.test_mode = true
	player._invulnerable_t = 1000.0
	_check(Net.player_realm() == Net.PlayerRealm.MOON and player.lunar_world == moon,
		"direct Moon entry equips radial player physics and life support")
	_check(manager.rocket.state == LunarRocket.State.LANDED_MOON,
		"direct expedition includes a usable landed return rocket")
	_check(not main.world._sun.visible and not main.world._moon.visible
		and main.world._lunar_shadow_quality_active,
		"Moon terrain uses lunar lighting without Earth directional light leakage")
	await _frames(180)
	_check(player.is_on_floor() and absf(moon.altitude_at(player.global_position)) < 0.20,
		"arrival lands on real lunar collision", "altitude=%.4f" % moon.altitude_at(player.global_position))
	var locations := [Vector3.UP, Vector3.RIGHT, Vector3.FORWARD,
		Vector3.DOWN, Vector3.LEFT, Vector3.BACK,
		Vector3(1.0, 1.0, 1.0).normalized()]
	for direction in locations:
		player.admin_teleport(moon.to_global(moon.surface_position(direction, 1.0)))
		await _frames(180)
		_check(player.is_on_floor() and absf(moon.altitude_at(player.global_position)) < 0.25
			and player.up_direction.dot(direction) > 0.999,
			"capsule settles upright on hemisphere %s" % direction,
			"altitude=%.4f" % moon.altitude_at(player.global_position))
		var start := player.global_position
		player.ti.dir = Vector2(0.0, -1.0)
		await _frames(60)
		player.ti.dir = Vector2.ZERO
		_check(player.global_position.distance_to(start) > 3.0
			and moon.altitude_at(player.global_position) > -0.25,
			"walking follows collision around hemisphere %s" % direction)
		await get_tree().process_frame
		_check(player.cam.global_basis.y.dot(player.up_direction) > 0.998,
			"camera horizon follows radial up on hemisphere %s" % direction)
	# The antipode used to trigger the old world-Y safety teleport.
	player.admin_teleport(moon.to_global(moon.surface_position(Vector3.DOWN, 1.0)))
	await _frames(180)
	var grounded_at := player.global_position
	player.ti.jump_just = true
	player.ti.jump_held = true
	await _frames(45)
	_check((player.global_position - grounded_at).dot(Vector3.DOWN) > 1.5
		and not player.is_on_floor(), "jump at far pole launches away from the centre")
	player.ti.jump_held = false
	await _frames(420)
	_check(player.is_on_floor() and moon.radial_up_at(player.global_position).dot(Vector3.DOWN) > 0.98,
		"low gravity returns the jumping player to the far hemisphere")
	# Shop prompt, authority-backed exchange and visible resident reactions.
	var shop := moon.cheese_shop
	player.admin_teleport(moon.surface_position_at(shop.to_global(Vector3(0.0, 0.0, -7.0)), 0.25))
	await _frames(90)
	_check(manager.try_interact(player) and manager.is_ui_open(),
		"physical merchant forecourt opens the trading UI")
	var inventory_before := manager.local_inventory.count_item(LunarInventory.ITEM_MOON_CHEESE)
	var balance_before := int(Net.scores[Net.local_id()])
	manager._request_cheese_purchase(2)
	_check(manager.local_inventory.count_item(LunarInventory.ITEM_MOON_CHEESE) == inventory_before + 2
		and int(Net.scores[Net.local_id()]) == balance_before - 6,
		"merchant exchanges six bananas for two carried cheese wedges")
	_check(shop.villager.activity == MoonMerchant.Activity.THANKING,
		"accepted purchase drives the actual merchant reaction")
	manager.close_ui()
	manager.local_suit.oxygen_seconds = 5.0
	player.admin_teleport(main.expedition_manager.rocket.boarding_global_position())
	await _frames(2)
	_check(manager.try_interact(player) and manager.local_suit.oxygen_fraction() > 0.98,
		"landed rocket refills life support")
	_check(manager.admin_travel(Net.PlayerRealm.EARTH), "admin return accepts Earth destination")
	_check(player.lunar_world == null and player.up_direction == Vector3.UP
		and player.global_basis.is_equal_approx(Basis.IDENTITY),
		"Earth return clears lunar orientation and gravity")
	_check(main.world._sun.visible and main.world._moon.visible
		and not main.world._lunar_shadow_quality_active,
		"Earth return restores the normal celestial lighting")
	print("MOONPLAYTEST %d/%d %s" % [passed, total, "PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)
