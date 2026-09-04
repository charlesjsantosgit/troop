extends Node
## Exercises the debug world end to end: flat generation, parkour collision,
## regenerating robot targets, the villager trade loop, text chat, admin
## commands (fly/give/time/kill), and the ban bookkeeping — all headless.

var total := 0
var passed := 0


func run(main) -> void:
	var world = main.world
	var p = world.local_player
	p.test_mode = true

	# 1 — flat generation under the playground
	var flat := true
	for i in range(40):
		if absf(Gen.height(i * 31.7 - 600.0, i * 17.3 - 300.0) - 2.0) > 0.001:
			flat = false
	_check(flat and Gen.debug_world, "debug world generates a flat plane")

	# 2 — player landed on real collision. The 2.5 m spawn drop takes about
	# 43 fixed 60 Hz steps at the authored 9.81 m/s^2 freefall acceleration;
	# use a one-second deadline without relaxing the exact contact assertion.
	await _frames(60)
	_check(p.is_on_floor() and absf(p.global_position.y - 2.0) < 1.0,
		"player stands on the debug plane")

	# 3 — course built: robots, parkour, ropes, ammo hut, villager
	var course: DebugWorldBuilder = null
	for child in world.get_children():
		if child is DebugWorldBuilder:
			course = child
	_check(course != null and course.robots.size() == 6,
		"course exists with six range robots")
	var movers := 0
	for robot in course.robots:
		if robot.patrol_span > 0.0:
			movers += 1
	_check(movers == 3, "three robots patrol, three hold still")
	var rope_count := 0
	for id in Gen.vines:
		rope_count += 1
	_check(rope_count >= 6, "rope garden registered grabbable strands")
	_check(world.villagers.size() == 1, "one trader villager on duty")

	# 4 — parkour block gives real footing
	p.set_physics_process(true)
	p.admin_teleport(Vector3(10.0, 4.6, 0.0))
	await _frames(50)
	_check(p.is_on_floor() and p.global_position.y > 2.6,
		"parkour block carries the player")

	# 5 — robot dies, folds, regenerates
	var robot: RobotMonkey = course.robots[0]
	robot.take_damage(250.0, null, Vector3.FORWARD, "body")
	_check(robot.destroyed and robot.kills_scored == 1,
		"robot folds when destroyed")
	var second_hit_health := robot.health
	robot.take_damage(50.0, null, Vector3.ZERO, "body")
	_check(robot.health == second_hit_health,
		"destroyed robot ignores further hits")
	robot._respawn_t = 0.0
	await _frames(4)
	_check(not robot.destroyed and robot.health == RobotMonkey.MAX_HEALTH,
		"robot reassembles with full health")

	# 6 — villager trade: bananas in, ammo out
	var villager = world.villagers[0]
	p.admin_teleport(villager.global_position + Vector3(1.5, 0.4, 0))
	await _frames(12)
	_check(world.nearby_trade_villager(p) == villager,
		"villager in interaction range")
	var opened := [false]
	world.villager_trade_requested.connect(
		func(_v, _pl): opened[0] = true)
	_check(world.try_open_villager_trade(p) and opened[0],
		"E-interaction requests a trade")
	Net.scores[Net.local_id()] = 10
	var trade: TradeUI = main.trade_ui
	trade.open_for(p)
	var reserve_before: int = p.gun.reserve_ammo
	trade._buy(0)  # 12 banana rounds for 2 bananas
	_check(p.gun.reserve_ammo == mini(reserve_before + 12,
			p.gun.MAX_RESERVE) and trade.bananas() == 8,
		"trade grants ammo and spends bananas")
	trade.close()

	# 7 — chat: local echo, sanitization, admin tag
	var heard: Array = []
	Net.chat_received.connect(
		func(_id, sender, text, admin): heard.append([sender, text, admin]))
	Net.send_chat("ook ook test")
	_check(heard.size() == 1 and heard[0][1] == "ook ook test"
			and heard[0][2] == true,
		"solo chat echoes sanitized text with the admin tag")
	_check(Net._sanitize_chat("x".repeat(500)).length() == Net.MAX_CHAT_LENGTH,
		"chat length is clamped")
	# chat feed: lines fade after expiry but survive until the FIFO cap, and
	# opening the input (ENTER) revives recent history at full strength
	var chat: ChatBox = main.chat_box
	var feed_before: int = chat._feed.get_child_count()
	Net.send_chat("history line")
	chat._process(20.0)
	var line: Label = chat._feed.get_child(chat._feed.get_child_count() - 1)
	_check(chat._feed.get_child_count() == feed_before + 1
			and line.modulate.a <= 0.01,
		"expired chat lines fade out but stay in history")
	chat.open()
	chat._process(0.05)
	_check(line.modulate.a >= 0.99, "opening chat revives faded history")
	chat.close()
	var admin_help: AdminController = main.admin_controller
	var before_help: int = chat._feed.get_child_count()
	admin_help.run_command("/help")
	_check(chat._feed.get_child_count() >= before_help + 8
			and chat._feed.get_child_count() <= chat.MAX_LINES,
		"/help prints the organized command list within the feed cap")

	# 8 — admin: solo grants it; slash commands act
	_check(Net.is_admin, "offline session grants admin")
	var admin: AdminController = main.admin_controller
	var mags_before: int = p.smg.reserve_mags
	admin.run_command("/give smg 40")
	_check(p.smg.reserve_mags == mini(mags_before + 2, 6),
		"/give smg 40 adds two magazines")
	admin.run_command("/time 6")
	_check(absf(world.time_of_day_hours - 6.0) < 0.2, "/time 6 sets the clock")
	admin.run_command("/fly")
	_check(p.fly_mode, "/fly unfurls the wings")
	p.ti.jump_held = true
	var y0: float = p.global_position.y
	await _frames(40)
	p.ti.jump_held = false
	_check(p.global_position.y > y0 + 2.0, "holding SPACE climbs while flying")
	await _frames(10)
	_check(p.rig.has_angel_wings_visible(), "angel wings are visible in flight")
	admin.run_command("/fly")
	_check(not p.fly_mode, "second /fly folds the wings")

	# 9 — kill + heal round trip
	p.admin_kill()
	_check(p.defeated, "admin KO defeats the player")
	p.defeated = false
	p.health = 30.0
	p.admin_heal()
	_check(p.health == p.MAX_HEALTH, "admin heal restores full health")

	# 10 — ban arithmetic (pure server bookkeeping, no sockets)
	Net._bans["10.0.0.9"] = {
		"until": int(Time.get_unix_time_from_system()) + 600, "name": "Zuzu"}
	_check(Net._ban_remaining_minutes("10.0.0.9") == 10,
		"ban remaining-minutes math")
	Net._bans["10.0.0.9"] = {
		"until": int(Time.get_unix_time_from_system()) - 5, "name": "Zuzu"}
	_check(Net._ban_remaining_minutes("10.0.0.9") == 0
			and not Net._bans.has("10.0.0.9"),
		"expired bans clean themselves up")

	# 11 — altitude view distance: pure curve + live stretch + stratos tier
	_check(absf(World.stream_view_distance_for_altitude(0.0)
			- Gen.VIEW_BASE_DISTANCE) < 0.01
			and absf(World.stream_view_distance_for_altitude(
				Gen.PLANET_SUMMIT_ELEVATION + 120.0)
			- Gen.VIEW_PEAK_DISTANCE) < 0.01
			and World.stream_view_distance_for_altitude(1200.0)
			> World.stream_view_distance_for_altitude(130.0) \
			and World.stream_view_distance_for_altitude(130.0)
			> World.stream_view_distance_for_altitude(20.0),
		"view distance curve: base at ground, capped at 15 miles, monotonic")
	admin.run_command("/fly")
	p.admin_teleport(Vector3(0, 130.0, 0))
	await _frames(200)
	_check(world.current_view_distance > Gen.VIEW_BASE_DISTANCE + 1000.0 \
			and world.current_view_distance \
			<= World.stream_view_distance_for_altitude(130.0) + 1.0,
		"flying high stretches the live view distance")
	_check(world.stratos_chunks.size() >= 1,
		"stratos sectors stream in at altitude")
	var window_high: float = main.hud.minimap.window_meters()
	admin.run_command("/fly")
	p.admin_teleport(Vector3(0, 3.0, 0))
	await _frames(30)
	_check(window_high > main.hud.minimap.window_meters(),
		"minimap zooms out with altitude")
	_check(main.hud.minimap._tiles[0].size()
			+ main.hud.minimap._tiles[1].size()
			+ main.hud.minimap._tiles[2].size() > 0,
		"minimap baked satellite tiles")

	# 12 — the chosen name persists to disk
	var original_name: String = Settings.player_name
	Settings.set_player_name("OokTester")
	Settings.save()
	var reread := ConfigFile.new()
	reread.load(Settings.CONFIG_PATH)
	_check(str(reread.get_value("profile", "name", "")) == "OokTester",
		"player name persists in settings.cfg")
	Settings.set_player_name(original_name)
	Settings.save()

	# 13 — a version-mismatch rejection returns to the menu. Installed builds
	# check for updates; source builds explain the mismatch without making any
	# updater requests or touching the installed game's update state.
	main._on_net_error("Server is running TROOP 9.9.9; your game is 0.0.1")
	await get_tree().process_frame
	_check(main.menu != null and main.world == null,
		"version rejection returns to the menu")
	var response_text := str(main.status_label.text).to_lower()
	var armed: bool = Updater.status in ["checking", "available",
			"downloading", "current", "error", "staged"] \
		or response_text.contains("version")
	if OS.has_feature("editor"):
		armed = Updater.status == "source" \
			and response_text.contains("version") \
			and response_text.contains("source build does not self-update") \
			and not is_instance_valid(Updater._manifest_request) \
			and not is_instance_valid(Updater._download_request)
	_check(armed, "version rejection checks updates or preserves source-build isolation")

	print("DEBUGTEST %d/%d %s" % [passed, total,
		"PASS" if passed == total else "FAIL"])
	await get_tree().process_frame
	get_tree().quit(0 if passed == total else 1)


func _frames(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label)
