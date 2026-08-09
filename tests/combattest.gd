extends Node
## Deterministic banana-revolver and solo-rival checks.

var passed := 0
var total := 0


func run(main) -> void:
	var world: World = main.world
	var player: MonkeyPlayer = world.local_player
	player.test_mode = true
	player.set_physics_process(false)

	_check(player.gun.ammo == 6, "revolver starts with six rounds")
	var body_shape := player.body_hitbox.get_child(0).shape as CapsuleShape3D
	_check(body_shape.radius > 0.35 and
		body_shape.radius > 0.26 and
		player.head_hitbox.get_child(0).shape.radius >= 0.27 and
		BananaBullet.HIT_RADIUS >= 0.08,
		"projectiles and monkey hit zones are larger without changing movement")
	var fired := 0
	for i in range(6):
		player.gun.tick(1.0)
		if player.gun.try_fire(player.hand_pos() + Vector3.UP * 2.0,
				Vector3.UP):
			fired += 1
	_check(fired == 6 and player.gun.ammo == 0, "six rounds empty the cylinder")
	player.gun.tick(1.0)
	_check(not player.gun.try_fire(player.hand_pos(), Vector3.UP),
		"empty cylinder cannot fire")
	_check(player.gun.start_reload(), "reload must be started manually")
	player.gun.tick(BananaGun.RELOAD_TIME + 0.01)
	_check(player.gun.ammo == 6 and player.gun.reload_remaining == 0.0,
		"reload refills all six chambers")
	var banana_mag_debris := 0
	for child in world.get_children():
		if child is WeaponDebris \
				and child.debris_kind == WeaponDebris.Kind.BANANA_MAG:
			banana_mag_debris += 1
	_check(player.gun.reload_event_count == 5 and banana_mag_debris == 1 \
		and player.gun._installed_mag.visible \
		and Sfx.streams.has("banana_toss") \
		and Sfx.streams.has("mag_catch") \
		and Sfx.streams.has("mag_insert"),
		"banana reload drops a curved magazine and preserves every toss/catch/insert beat across a large tick")
	var snap_progress := SatisfyingReload.overshoot(0.90, 0.12)
	var snap_position := SatisfyingReload.arc(Vector3.ZERO, Vector3.RIGHT,
		0.2, snap_progress)
	_check(snap_progress > 1.0 and snap_position.x > 1.0,
		"shared reload paths visibly pass through the socket before settling")
	var reload_refresh_ok := true
	var reload_profiles := [
		[BananaGun.RELOAD_TIME, [0.08, 0.23, 0.46, 0.73, 0.87]],
		[PumpShotgun.SHELL_RELOAD_TIME, [0.08, 0.43, 0.82]],
		[PumpShotgun.FINAL_PUMP_TIME, [0.45, 0.82]],
		[SMG.RELOAD_TIME, [0.08, 0.22, 0.46, 0.72, 0.86]],
		[SniperRifle.RELOAD_TIME, [0.07, 0.19, 0.43, 0.68, 0.78, 0.94]],
	]
	for profile in reload_profiles:
		var previous_max_step := INF
		for fps in [30, 60, 120, 160]:
			var sample := _sample_reload_motion(fps, profile[0], profile[1])
			reload_refresh_ok = reload_refresh_ok \
				and sample.events == profile[1].size() \
				and sample.timing_ok and sample.final_error < 0.00001 \
				and sample.max_step <= previous_max_step + 0.002
			previous_max_step = sample.max_step
	_check(reload_refresh_ok,
		"reload transforms and threshold events remain smooth and invariant at 30/60/120/160 FPS")
	_check(player.shotgun.ammo == PumpShotgun.CAPACITY and
		PumpShotgun.CAPACITY == 6 and PumpShotgun.PELLETS_PER_SHOT == 6,
		"pump shotgun has six shells and fires six pellets")
	var pellet_directions := PumpShotgun.pellet_directions(Vector3.FORWARD, 1337)
	var all_pellets_in_cone := pellet_directions.size() == 6
	for pellet_direction in pellet_directions:
		all_pellets_in_cone = all_pellets_in_cone and pellet_direction.dot(
			Vector3.FORWARD) >= cos(deg_to_rad(
				PumpShotgun.SPREAD_HALF_ANGLE_DEGREES + 0.01))
	_check(all_pellets_in_cone and
		PumpShotgun.spread_radius_at(8.0) < 0.45 and
		PumpShotgun.spread_radius_at(25.0) < 1.32,
		"shotgun cone is devastating close and controlled at mid range")
	player.equip_weapon(2)
	var shotgun_fired := player.shotgun.try_fire(
		player.hand_pos() + Vector3.UP * 2.0, Vector3.UP)
	var live_pellets := 0
	var fixed_pellet_damage := true
	for child in world.get_children():
		if child is BananaBullet and child.impact_damage == PumpShotgun.PELLET_DAMAGE:
			live_pellets += 1
			fixed_pellet_damage = fixed_pellet_damage and \
				not child.uses_revolver_headshots and \
				child.weapon_kind == Net.WEAPON_SHOTGUN
	_check(shotgun_fired and player.shotgun.ammo == 5 and live_pellets == 6 and
		fixed_pellet_damage,
		"one pump shot creates six 15-damage projectiles")
	player.shotgun._spawn_spent_shell()
	var spent_shells := 0
	for child in world.get_children():
		if child is WeaponDebris \
				and child.debris_kind == WeaponDebris.Kind.SHOTGUN_SHELL:
			spent_shells += 1
	_check(spent_shells >= 1 and player.shotgun._ejection_port != null,
		"shotgun pump throws a physical spent hull from the chamber")
	player.shotgun.ammo = 0
	player.shotgun.cooldown = 0.0
	_check(player.shotgun.start_reload(), "shotgun starts a shell reload")
	player.shotgun.tick(PumpShotgun.SHELL_RELOAD_TIME + 0.01)
	_check(player.shotgun.ammo == 1 and
		player.shotgun.reload_event_count == 3,
		"pump shotgun flips, catches, and inserts one shell at a time")
	player.shotgun.cancel_reload()
	player.shotgun.ammo = 0
	player.shotgun.reserve_ammo = PumpShotgun.CAPACITY
	player.shotgun.start_reload()
	player.shotgun.tick(PumpShotgun.SHELL_RELOAD_TIME \
		* PumpShotgun.CAPACITY + PumpShotgun.FINAL_PUMP_TIME + 0.01)
	_check(player.shotgun.ammo == PumpShotgun.CAPACITY \
		and player.shotgun.reload_remaining == 0.0 \
		and not player.shotgun._reloading \
		and player.shotgun.reload_event_count == PumpShotgun.CAPACITY * 3 + 2,
		"a large frame advances every shotgun shell beat and the final pump without discarding time")
	player.shotgun.reset_cylinder()
	player.equip_weapon(1)

	_check(player.smg.ammo == SMG.CAPACITY and SMG.CAPACITY == 20 and
		SMG.TOTAL_MAGAZINES == 4 and player.smg.reserve_mags == 3 and
		SMG.FIRE_INTERVAL <= 0.08,
		"SMG starts with 20 rounds, four total magazines, and a fast fire rate")
	player.equip_weapon(3)
	var smg_shots := 0
	for i in range(SMG.CAPACITY):
		player.smg.tick(SMG.FIRE_INTERVAL + 0.001)
		if player.smg.try_fire(player.hand_pos() + Vector3.UP * 2.0,
				Vector3.UP):
			smg_shots += 1
	_check(smg_shots == 20 and player.smg.ammo == 0,
		"SMG fires all 20 rounds before the magazine is empty")
	var smg_brass := 0
	for child in world.get_children():
		if child is WeaponDebris \
				and child.debris_kind == WeaponDebris.Kind.BRASS:
			smg_brass += 1
	_check(smg_brass >= 20,
		"SMG fire ejects one capped, physical brass casing per round")
	_check(player.smg.start_reload(), "SMG can swap to a spare magazine")
	player.smg.tick(SMG.RELOAD_TIME + 0.01)
	_check(player.smg.ammo == 20 and player.smg.reserve_mags == 2,
		"SMG reload fills 20 rounds and consumes exactly one spare magazine")
	_check(player.smg.reload_event_count == 5 and
		player.smg._installed_mag.visible,
		"SMG reload drops, flips, catches, inserts, and racks on distinct animation beats")
	for i in range(2):
		player.smg.ammo = 0
		player.smg.start_reload()
		player.smg.tick(SMG.RELOAD_TIME + 0.01)
	player.smg.ammo = 0
	_check(player.smg.reserve_mags == 0 and not player.smg.start_reload(),
		"SMG loadout is limited to four magazines total")
	player.smg.reset_cylinder()
	player.ti.shoot_held = true
	for i in range(4):
		player.smg.tick(SMG.FIRE_INTERVAL + 0.001)
		player._combat(player._gather())
	player.ti.shoot_held = false
	_check(player.smg.ammo == 16,
		"holding the trigger fires the SMG automatically")
	player.smg.reset_cylinder()
	player.equip_weapon(1)

	_check(player.sniper != null and SniperRifle.CAPACITY == 5 and
		SniperRifle.TOTAL_MAGAZINES == 4 and player.sniper.reserve_mags == 3 and
		SniperRifle.DAMAGE == 85.0 and SniperRifle.MUZZLE_SPEED == 215.0 and
		SniperRifle.MUZZLE_SPEED > SMG.MUZZLE_SPEED and
		Net.WEAPON_SNIPER == 3,
		"sniper starts with five rounds, three spare magazines, and 85-damage high velocity ammunition")
	player.equip_weapon(4)
	_check(player.weapon_slot == 4 and player.active_weapon == player.sniper and
		player.sniper.visible and not player.gun.visible and
		not player.shotgun.visible and not player.smg.visible,
		"weapon slot four equips only the sniper rifle")
	player.state = MonkeyPlayer.S.GROUND
	player.velocity = Vector3.ZERO
	var sniper_hip_spread := player.current_weapon_spread_degrees()
	var unscoped_sensitivity := player.cam.effective_sensitivity()
	player.cam.set_aiming(true)
	var zoom_25 := player.sniper.magnification()
	var fov_25 := player.cam.sniper_scope_fov()
	var sensitivity_25 := player.cam.effective_sensitivity()
	var sniper_scoped_spread := player.current_weapon_spread_degrees()
	var zoom_5 := player.sniper.cycle_zoom()
	var fov_5 := player.cam.sniper_scope_fov()
	var sensitivity_5 := player.cam.effective_sensitivity()
	var zoom_10 := player.sniper.cycle_zoom()
	var fov_10 := player.cam.sniper_scope_fov()
	var sensitivity_10 := player.cam.effective_sensitivity()
	var zoom_wrapped := player.sniper.cycle_zoom()
	_check(zoom_25 == 2.5 and zoom_5 == 5.0 and zoom_10 == 10.0 and
		zoom_wrapped == 2.5,
		"Z scope adjustment cycles 2.5x, 5x, and 10x magnification")
	_check(fov_10 < fov_5 and fov_5 < fov_25 and
		fov_25 < CameraRig.FIRST_PERSON_FOV and
		sensitivity_10 < sensitivity_5 and sensitivity_5 < sensitivity_25 and
		sensitivity_25 < unscoped_sensitivity,
		"higher optical zoom narrows perspective FOV and proportionally slows aim")
	player.cam.set_aiming(false)
	_check(sniper_scoped_spread == 0.0 and
		is_equal_approx(sniper_hip_spread,
			MonkeyPlayer.SNIPER_HIP_SPREAD_HALF_ANGLE_DEGREES) and
		sniper_hip_spread > 1.0,
		"scoped sniper fire is center-dot exact while hip fire uses visible spread")
	player.sniper.ammo = SniperRifle.CAPACITY - 1
	player.cam.set_aiming(true)
	player.ti.reload_just = true
	player._combat(player._gather())
	_check(player.sniper.reload_remaining > 0.0 and not player.cam.aiming,
		"starting a sniper reload exits the optic so its magazine and bolt flourish stay visible")
	player.sniper.cancel_reload()
	player.sniper.reset_cylinder()
	var zeroed_direction := SniperRifle.zeroed_direction(Vector3.FORWARD)
	var drop_at_zero := SniperRifle.drop_below_zero_at(
		SniperRifle.ZERO_DISTANCE)
	var drop_at_100 := SniperRifle.drop_below_zero_at(100.0)
	var drop_at_200 := SniperRifle.drop_below_zero_at(200.0)
	_check(SniperRifle.BALLISTIC_GRAVITY == 9.81 and
		SniperRifle.ZERO_DISTANCE == 75.0 and zeroed_direction.y > 0.0 and
		absf(drop_at_zero) < 0.001 and drop_at_100 > 0.25 and
		drop_at_100 < 0.31 and drop_at_200 > 2.60 and drop_at_200 < 2.70,
		"sniper ballistics use physical gravity, a 75 m zero, and readable long-range drop")
	var sniper_report := Sfx.streams.get("sniper") as AudioStreamWAV
	var revolver_report := Sfx.streams.get("gunshot") as AudioStreamWAV
	_check(sniper_report != null and revolver_report != null and
		sniper_report.get_length() >= 1.34 and
		sniper_report.get_length() > revolver_report.get_length() * 5.0 and
		Sfx.streams.has("sniper_bolt") and Sfx.streams.has("sniper_reload"),
		"sniper report includes a long echo/reverb tail plus distinct bolt and reload sounds")
	player.sniper.reset_cylinder()
	var sniper_shots := 0
	for i in range(SniperRifle.CAPACITY):
		player.sniper.tick(SniperRifle.FIRE_INTERVAL + 0.001)
		if player.sniper.try_fire(player.hand_pos() + Vector3.UP * 2.0,
				Vector3.UP):
			sniper_shots += 1
	var sniper_projectiles: Array[BananaBullet] = []
	for child in world.get_children():
		if child is BananaBullet and child.weapon_kind == Net.WEAPON_SNIPER:
			sniper_projectiles.append(child)
	var sniper_projectile_profile_ok := not sniper_projectiles.is_empty()
	for projectile in sniper_projectiles:
		sniper_projectile_profile_ok = sniper_projectile_profile_ok and \
			projectile.impact_damage == SniperRifle.DAMAGE and \
			projectile.uses_revolver_headshots and \
			is_equal_approx(projectile.life, BananaBullet.SNIPER_MAX_LIFE) and \
			projectile.projectile_gravity().is_equal_approx(
				Vector3.DOWN * SniperRifle.BALLISTIC_GRAVITY)
	_check(sniper_shots == 5 and player.sniper.ammo == 0 and
		sniper_projectiles.size() == 5 and sniper_projectile_profile_ok and
		BananaBullet.SNIPER_MAX_LIFE > BananaBullet.MAX_LIFE and
		BananaBullet.TRACER_WIDTH_SNIPER < 0.008,
		"five sniper shots create long-lived, thin-tracer sniper projectiles")
	_check(player.sniper.start_reload(),
		"empty sniper magazine can begin a full magazine reload")
	player.sniper.tick(SniperRifle.RELOAD_TIME + 0.01)
	_check(player.sniper.ammo == 5 and player.sniper.reserve_mags == 2 and
		player.sniper.reload_remaining == 0.0,
		"sniper reload fills five rounds and consumes exactly one spare magazine")
	_check(player.sniper.reload_event_count == 6 and
		player.sniper._installed_mag.visible,
		"sniper reload completes its magazine trick and open/close bolt flourish")
	player.sniper._spawn_spent_casing()
	_check(player.sniper._ejection_port != null,
		"sniper bolt ejects a physical brass casing from its chamber")
	player.sniper.reset_cylinder()
	player.velocity = Vector3(28.0, 0.0, 0.0)
	player.sniper.tick(SniperRifle.FIRE_INTERVAL + 0.001)
	var precision_fired := player.sniper.try_fire(
		player.hand_pos() + Vector3.UP * 2.0, Vector3.FORWARD)
	var precision_projectile: BananaBullet
	for child in world.get_children():
		if child is BananaBullet and child.weapon_kind == Net.WEAPON_SNIPER:
			if precision_projectile == null or child.get_instance_id() > \
					precision_projectile.get_instance_id():
				precision_projectile = child
	_check(precision_fired and precision_projectile != null and
		absf(precision_projectile.velocity.x) < 0.001 and
		is_equal_approx(precision_projectile.velocity.length(),
			SniperRifle.MUZZLE_SPEED),
		"scoped ballistic centerline stays exact even while the monkey is moving")
	player.velocity = Vector3.ZERO
	player.sniper.reset_cylinder()
	player.equip_weapon(1)

	var flat := BananaBullet.ballistic_position(Vector3.ZERO,
		Vector3.FORWARD * BananaGun.MUZZLE_SPEED, 0.5)
	_check(is_equal_approx(flat.z, -BananaGun.MUZZLE_SPEED * 0.5) and
		flat.y < -0.7 and flat.y > -0.8, "projectile has slight physical drop")
	_check(BananaBullet.headshot_damage(20.0, player.MAX_HEALTH) == 100.0,
		"close headshot is an instant kill")
	_check(BananaBullet.headshot_damage(70.0, player.MAX_HEALTH) == 80.0,
		"long-range headshot removes 80 percent health")
	_check(player.head_hitbox != null and
		player.head_hitbox.collision_layer == CombatHitbox.HITBOX_LAYER and
		player.head_hitbox.get_parent() == player.rig.head_p and
		player.body_hitbox.get_parent() == player.rig.torso_p,
		"separate projectile head and body zones are attached to the animated skeleton")
	_check(player.rig.head_p.get_node_or_null("Smile") != null and
		player.rig.head_p.get_node("Smile").get_child_count() == 7,
		"animated monkey face has a rounded low-poly u smile")
	_check(player.rig.el_l.get_node_or_null("ElbowJoint") != null and
		player.rig.el_r.get_node_or_null("ElbowJoint") != null and
		player.rig.kn_l.get_node_or_null("KneeJoint") != null and
		player.rig.kn_r.get_node_or_null("KneeJoint") != null and
		player.rig.el_l.get_node_or_null("ElbowPad") != null and
		player.rig.el_r.get_node_or_null("ElbowPad") != null and
		player.rig.kn_l.get_node_or_null("Kneecap") != null and
		player.rig.kn_r.get_node_or_null("Kneecap") != null,
		"elbows and knees have visible joint geometry and anatomical caps")
	var exact_aim := MonkeyPlayer.spread_direction(Vector3.FORWARD, 0.0, 11)
	var spread_aim := MonkeyPlayer.spread_direction(Vector3.FORWARD, 4.0, 11)
	player.state = MonkeyPlayer.S.GROUND
	player.velocity = Vector3.ZERO
	var still_spread := player.current_weapon_spread_degrees()
	player.velocity = Vector3(7.0, 0.0, 0.0)
	var moving_spread := player.current_weapon_spread_degrees()
	player.state = MonkeyPlayer.S.SWING
	player.velocity = Vector3(16.0, 0.0, 0.0)
	var swing_spread := player.current_weapon_spread_degrees()
	player.state = MonkeyPlayer.S.GROUND
	player.velocity = Vector3.ZERO
	_check(exact_aim == Vector3.FORWARD and
		spread_aim.dot(Vector3.FORWARD) < 0.99999 and
		still_spread == 0.0 and moving_spread > 0.0 and
		moving_spread < 1.0 and swing_spread > moving_spread * 5.0,
		"stationary fire is exact, movement is slightly loose, and vine fire spreads")
	player.gun.ammo = BananaGun.CAPACITY - 1
	player.gun.reload_remaining = 0.0
	player.state = MonkeyPlayer.S.SWING
	player.ti.reload_just = true
	player._combat(player._gather())
	_check(player.gun.reload_remaining == 0.0,
		"swinging keeps the support paw on the rope instead of starting a detached-hand reload")
	player.gun.reset_cylinder()
	player.state = MonkeyPlayer.S.GROUND
	player.gun.ammo = BananaGun.CAPACITY - 1
	player.gun.start_reload()
	player.equip_weapon(2)
	_check(player.gun.reload_remaining == 0.0 \
		and player.gun.ammo == BananaGun.CAPACITY - 1,
		"switching weapons cancels the visible reload instead of filling a hidden gun in the background")
	player.equip_weapon(1)
	player.gun.reset_cylinder()
	_check(BananaBullet.TRACER_WIDTH_REVOLVER < 0.008 and
		BananaBullet.TRACER_WIDTH_SHOTGUN < 0.008 and
		BananaBullet.TRACER_WIDTH_SMG < 0.008 and
		BananaBullet.TRACER_WIDTH_SNIPER < 0.008,
		"all projectile tracers use the thinner combat profile")
	_check(_has_mouse_binding("shoot", MOUSE_BUTTON_LEFT) and
		not _has_mouse_binding("grab", MOUSE_BUTTON_LEFT),
		"left mouse fires and no longer grabs vines")
	_check(_has_key_binding("grab", KEY_E) and
		_has_mouse_binding("aim", MOUSE_BUTTON_RIGHT) and
		_has_key_binding("weapon_3", KEY_3) and
		_has_key_binding("weapon_4", KEY_4) and
		_has_key_binding("scope_zoom", KEY_Z) and
		_has_key_binding("melee_toggle", KEY_Q) and
		_has_key_binding("use_bandage", KEY_H),
		"E handles vines/chests, right mouse aims, 3/4 select long guns, Z adjusts zoom, Q toggles melee, and H uses bandages")

	var supply_hut := SupplyHut.new()
	var supply_hut_id := "s:test#0"
	supply_hut.configure({
		"id": supply_hut_id,
		"pos": player.global_position + Vector3(0.0, 0.0, 1.8),
		"yaw": 0.0,
		"ammo_kind": Gen.SUPPLY_AMMO_REVOLVER,
		"ammo_amount": 12,
		"bandages": 1,
		"biome": Gen.Biome.RAINFOREST,
	})
	world.add_child(supply_hut)
	world.register_supply_hut(supply_hut)
	player.gun.reserve_ammo = 0
	player.bandages = 0
	var opened_supply := world.try_open_supply_chest(player)
	var opened_twice := world.try_open_supply_chest(player)
	_check(opened_supply and not opened_twice and supply_hut.is_opened() \
		and world.is_supply_hut_opened(supply_hut_id) \
		and player.gun.reserve_ammo == 12 and player.bandages == 1,
		"openable hut chest grants its deterministic gun ammo and optional bandage exactly once")
	_check(Sfx.streams.has("chest_open") and Sfx.streams.has("ammo_pickup") \
		and Sfx.streams.has("bandage_pickup") \
		and Sfx.streams.has("bandage_unroll") \
		and Sfx.streams.has("heal_finish") \
		and Sfx.streams.has("casing_tink") \
		and WeaponFX.MAX_ACTIVE_DEBRIS <= 64,
		"chests, cloth, reloads, and bounded debris have dedicated synthesized foley")

	player.health = 50.0
	player.state = MonkeyPlayer.S.GROUND
	player.galloping = false
	var bandage_started := player.start_bandage()
	player._update_bandage(MonkeyPlayer.BANDAGE_TIME * 0.50)
	player.cam._view_arms.update_bandage_pose(0.10,
		player.bandage_progress(), 0.0, true)
	var bandage_mid_pose := player.cam._view_arms._bandage_roll.visible \
		and player.cam._view_arms._bandage_strip.visible \
		and player.cam._view_arms._left_hand.distance_to(
			player.cam._view_arms._right_hand) > 0.04
	player._update_bandage(MonkeyPlayer.BANDAGE_TIME * 0.51)
	_check(bandage_started and bandage_mid_pose and not player.is_healing() \
		and player.health == 92.0 and player.bandages == 0 \
		and player.gun.get_parent() == player.rig.el_r,
		"bandage wrap, double orbit, tear, and press animation heals late then restores the weapon")
	player.health = 50.0
	player.bandages = 1
	player._invulnerable_t = 0.0
	var interrupt_started := player.start_bandage()
	player._update_bandage(0.30)
	player.take_damage(5.0, null, Vector3.ZERO)
	_check(interrupt_started and not player.is_healing() \
		and player.health == 45.0 and player.bandages == 0,
		"taking damage interrupts an unfinished bandage without granting its heal")
	player.health = 50.0
	player.bandages = 1
	player.state = MonkeyPlayer.S.GROUND
	var traversal_interrupt_started := player.start_bandage()
	player.state = MonkeyPlayer.S.AIR
	player._update_bandage(0.05)
	_check(traversal_interrupt_started and not player.is_healing() \
		and player.health == 50.0 and player.bandages == 0,
		"jumping, swimming, swinging, or dropping to all fours interrupts a hand-occupied bandage")
	player.health = player.MAX_HEALTH
	player.state = MonkeyPlayer.S.GROUND
	player.health_changed.emit(player.health, player.MAX_HEALTH)
	world.unregister_supply_hut(supply_hut)
	supply_hut.queue_free()
	player.rig.set_gun_aim(false, Vector3.FORWARD, 0.0)
	player.rig.set_melee_pose(false, false, 0.0, 0)
	player.rig.set_yaw(0.0)
	for i in range(20):
		player.rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.AIR,
			Vector3(0, 5.0, -7.0), false, Vector3.ZERO)
	var airborne_left_paw := player.rig.el_l.to_global(
		Vector3(0, -MonkeyRig.ARM_B, 0))
	var airborne_arm_direction := (
		airborne_left_paw - player.rig.sh_l.global_position).normalized()
	_check(airborne_arm_direction.dot(Vector3.FORWARD) > 0.72,
		"third-person jump sends the free arm forward instead of backward")

	player.state = MonkeyPlayer.S.GROUND
	player.velocity = Vector3.ZERO
	player.galloping = true
	player._sync_weapon_presentation(true)
	_check(player.gun.get_parent() == player.rig.weapon_back_mount,
		"all-fours gallop mounts the equipped weapon on the monkey's back")
	player.galloping = false
	player._sync_weapon_presentation(true)
	_check(player.gun.get_parent() == player.rig.el_r,
		"weapon returns to the firing hand when the gallop ends")

	var melee_target := PracticeTarget.new()
	world.add_child(melee_target)
	melee_target.setup(player.global_position + Vector3(0, 0, -1.05),
		player.global_position)
	await get_tree().physics_frame
	player.set_melee_mode(true)
	_check(player.melee_mode and
		player.gun.get_parent() == player.rig.weapon_back_mount and
		player._start_melee_attack(),
		"Q melee mode stows the weapon and starts an unarmed combo")
	player._update_melee(
		MonkeyPlayer.MELEE_ATTACK_DURATION * MonkeyPlayer.MELEE_HIT_PROGRESS
		+ 0.01)
	_check(not melee_target._active and player._melee_hit_done,
		"melee damage lands once on the animated strike frame")
	player.melee_attack_remaining = 0.0
	var second_combo := player._start_melee_attack() \
		and player.melee_attack_combo == 1
	player.melee_attack_remaining = 0.0
	var third_combo := player._start_melee_attack() \
		and player.melee_attack_combo == 2
	_check(second_combo and third_combo,
		"repeated melee input advances through straight, hook, and hammer attacks")
	player.rig.set_gun_aim(false, Vector3.FORWARD, 0.0)
	player.rig.set_melee_pose(true, true, 0.40, player.melee_attack_combo)
	player.rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.IDLE,
		Vector3.ZERO, true, Vector3.ZERO)
	var melee_paw := player.rig.el_r.to_global(
		Vector3(0, -MonkeyRig.ARM_B, 0))
	_check((melee_paw - player.rig.sh_r.global_position).dot(Vector3.FORWARD)
		> 0.24,
		"third-person melee pose extends a paw through the strike")
	player.set_melee_mode(false)
	melee_target.queue_free()
	await get_tree().process_frame
	player.cam.set_first_person(true)
	await get_tree().process_frame
	await get_tree().process_frame
	var pistol_grips: Array[Transform3D] = \
		player.gun.first_person_grip_transforms(player.cam._view_arms)
	_check(player.cam.first_person and
		(player.cam._cam.cull_mask & MonkeyRig.LOCAL_BODY_VISUAL_LAYER) == 0 and
		player.cam._arm.spring_length < 0.05 and
		player.gun.first_person_view and player.gun.get_parent() == player.cam._cam and
		player.smg.first_person_view and player.smg.get_parent() == player.cam._cam and
		player.sniper.first_person_view and
		player.sniper.get_parent() == player.cam._cam and
		player.cam._view_arms.visible and player.cam._view_arms.get_child_count() == 6 and
		player.cam._view_arms._right_hand.distance_to(
			pistol_grips[0].origin) < 0.002 and
		player.cam._view_arms._left_hand.distance_to(
			pistol_grips[1].origin) < 0.002,
		"first-person monkey paws stay locked to the weapon's two grip markers")
	player.equip_weapon(4)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	player.cam.set_aiming(true)
	player._process(1.0 / 60.0)
	player.cam._process(1.0 / 60.0)
	_check(player.cam.is_sniper_scoped() and not player.sniper.visible and
		not player.cam._view_arms.visible,
		"sniper ADS hides the magnified viewmodel and both arms behind the optic")
	player.cam.set_aiming(false)
	player.equip_weapon(1)
	player._process(1.0 / 60.0)
	player.cam._process(1.0 / 60.0)
	_check(player.gun.visible and player.cam._view_arms.visible,
		"leaving sniper ADS restores the equipped viewmodel and first-person paws")
	player.state = MonkeyPlayer.S.GROUND
	player.galloping = true
	player._sync_weapon_presentation(true)
	player._process(1.0 / 60.0)
	player.cam._process(1.0 / 60.0)
	_check(player.is_weapon_stowed() and
		not player.is_weapon_visually_stowed() and
		player.gun.first_person_view and player.gun.visible and
		player.gun.get_parent() == player.cam._cam and
		player.cam._view_arms.visible,
		"first-person sprint keeps the gameplay-stowed gun and paws visible")
	player.galloping = false
	player._sync_weapon_presentation(true)
	player.set_melee_mode(true)
	player.melee_attack_combo = 0
	player.melee_attack_remaining = MonkeyPlayer.MELEE_ATTACK_DURATION * 0.60
	player.cam._view_arms.update_melee_pose(
		0.2, true, 0.40, 0, 0.0, true)
	_check(player.gun.get_parent() == player.rig.weapon_back_mount and
		player.cam._view_arms._right_hand.z < -0.66 and
		player.cam._view_arms.visible,
		"first-person melee hides the gun on the back and animates both fists")
	player.set_melee_mode(false)
	_check(player.gun.first_person_view and
		player.gun.get_parent() == player.cam._cam,
		"leaving melee restores the first-person weapon viewmodel")
	player.state = MonkeyPlayer.S.SWING
	player.swing_anchor = player.hand_pos() + Vector3.UP * 4.0
	player.wraps.clear()
	player.velocity = Vector3(12.0, 0.0, 0.0)
	player.gun._process(0.5)
	player.cam._view_arms.update_pose(
		0.5, player.gun, false, player.velocity.length(), false)
	var view_vine_grip := player.cam._view_arms.to_local(
		player.hand_pos() + Vector3.UP * 0.11)
	var swing_grips: Array[Transform3D] = \
		player.gun.first_person_grip_transforms(player.cam._view_arms)
	_check(player.cam._view_arms._left_hand.distance_to(view_vine_grip) < 0.01 and
		player.cam._view_arms._left_hand.distance_to(
			swing_grips[1].origin) > 0.04 and
		player.cam._view_arms._right_hand.distance_to(
			swing_grips[0].origin) < 0.002 and
		player.gun.position.y > BananaGun.VIEWMODEL_POSITION.y + 0.07,
		"first-person swing uses one paw on the vine and raises the weapon")
	player.rig.set_rope(true, player.swing_anchor, player.hand_pos(), 0.0,
		player.velocity)
	player.rig.set_gun_aim(true, Vector3.FORWARD, 0.0)
	player.rig._air_pitch = 0.0
	player.rig._air_roll = 0.0
	player.rig._air_pitch_velocity = 0.0
	player.rig._air_roll_velocity = 0.0
	for i in range(30):
		player.rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.SWING,
			player.velocity, false, player.swing_anchor)
	var third_person_vine_grip := player.hand_pos() + Vector3.UP * 0.12
	var left_paw := player.rig.el_l.to_global(
		Vector3(0, -MonkeyRig.ARM_B, 0))
	var right_paw := player.rig.el_r.to_global(
		Vector3(0, -MonkeyRig.ARM_B, 0))
	# The weapon's -90-degree local X mount maps its barrel (-Z) onto the
	# forearm's -Y axis even while the viewmodel itself is camera-parented.
	var gun_forward := (
		player.rig.el_r.global_transform.basis * Vector3.DOWN).normalized()
	_check(left_paw.distance_to(third_person_vine_grip) < 0.02 and
		right_paw.distance_to(third_person_vine_grip) > 0.16 and
		gun_forward.dot(Vector3.FORWARD) > 0.97,
		"third-person swing keeps one paw on the vine and the gun upright on aim")
	player.rig.set_rope(false, Vector3.ZERO, Vector3.ZERO)

	# A zero-tail fixture proves the extra sniper contacts use the guaranteed
	# taut rope segment rather than relying on loose vine below the grab point.
	player.cam.set_first_person(false)
	await get_tree().process_frame
	player.equip_weapon(4)
	player.state = MonkeyPlayer.S.SWING
	player.swing_anchor = player.hand_pos() + Vector3.UP * 4.0
	player.velocity = Vector3(8.0, 0.0, 0.0)
	player.wraps.clear()
	player._sync_weapon_presentation(true)
	player.rig.set_sniper_rope_pose(true, player.sniper.support_grip)
	player.rig.set_rope(true, player.swing_anchor, player.hand_pos(), 0.0,
		player.velocity)
	player.rig.set_gun_aim(true, Vector3.FORWARD, 0.0)
	for i in range(75):
		player.rig.update_motion(1.0 / 60.0, MonkeyRig.Anim.SWING,
			player.velocity, false, player.swing_anchor)
	var rope_start := player.swing_anchor
	var rope_end := player.hand_pos()
	var tail_tip: Vector3 = player.rig.tail_segs[
		player.rig.tail_segs.size() - 1].to_global(Vector3(0.0, 0.0, 0.17))
	var sniper_left_paw := player.rig.el_l.to_global(
		Vector3(0.0, -MonkeyRig.ARM_B, 0.0))
	var sniper_right_paw := player.rig.el_r.to_global(
		Vector3(0.0, -MonkeyRig.ARM_B, 0.0))
	var tail_rope_error := _distance_to_segment(tail_tip, rope_start, rope_end)
	var left_foot_rope_error := _distance_to_segment(
		player.rig.foot_l.global_position, rope_start, rope_end)
	var right_foot_rope_error := _distance_to_segment(
		player.rig.foot_r.global_position, rope_start, rope_end)
	var animated_head_error := player.head_hitbox.global_position.distance_to(
		player.rig.head_p.to_global(Vector3(0.0, 0.0, -0.015)))
	_check(player.rig._sniper_rope_blend > 0.99 and
		tail_rope_error < 0.035 and left_foot_rope_error < 0.10 and
		right_foot_rope_error < 0.10 and
		animated_head_error < 0.001 and
		sniper_left_paw.distance_to(
			player.sniper.support_grip.global_position) < 0.07 and
		sniper_right_paw.distance_to(
			player.sniper.primary_grip.global_position) < 0.11,
		"sniper rope pose keeps both paws on the rifle while tail and both feet contact even a zero-tail vine")

	# Compare one identical pendulum step: the rifle progressively damps the
	# tangential component instead of abruptly clipping an established swing.
	var pose_fixture_position := player.global_position
	player.rig.set_rope(false, Vector3.ZERO, Vector3.ZERO)
	player.rig.set_sniper_rope_pose(false)
	player.global_position = Vector3(0.0, 100.0, 0.0)
	var swing_fixture_anchor := player.hand_pos() + Vector3.UP * 4.0
	var neutral_swing_input := {
		"reel": 0.0, "reel_delta": 0.0, "dir": Vector2.ZERO, "grab": true,
	}
	player.equip_weapon(1)
	player.state = MonkeyPlayer.S.SWING
	player.swing_anchor = swing_fixture_anchor
	player.swing_len = 4.0
	player.swing_len_target = 4.0
	player.swing_max_len = 12.0
	player.wraps.clear()
	player.wrap_used = 0.0
	player.velocity = Vector3(12.0, 0.0, 0.0)
	player._st_swing(1.0 / 60.0, neutral_swing_input)
	var normal_swing_tangent := absf(player.velocity.x)
	player.equip_weapon(4)
	player.state = MonkeyPlayer.S.SWING
	player.swing_anchor = swing_fixture_anchor
	player.swing_len = 4.0
	player.swing_len_target = 4.0
	player.swing_max_len = 12.0
	player.wraps.clear()
	player.wrap_used = 0.0
	player.velocity = Vector3(12.0, 0.0, 0.0)
	player._st_swing(1.0 / 60.0, neutral_swing_input)
	var sniper_swing_tangent := absf(player.velocity.x)
	_check(sniper_swing_tangent < normal_swing_tangent - 0.04 and
		MonkeyPlayer.SNIPER_SWING_SPEED_MULTIPLIER < 1.0 and
		MonkeyPlayer.SNIPER_SWING_DRAG > 0.0,
		"carrying the sniper makes rope pumping weaker and the swing progressively slower")
	player.global_position = pose_fixture_position
	player.state = MonkeyPlayer.S.GROUND
	player.velocity = Vector3.ZERO
	player.equip_weapon(1)
	player.cam.set_first_person(true)
	await get_tree().process_frame
	player.gun._process(0.5)
	player.cam.pitch = 0.0
	player.cam.apply_look(Vector2(0, 10000))
	var full_up := player.cam.pitch
	player.cam.apply_look(Vector2(0, -10000))
	var full_down := player.cam.pitch
	_check(full_up <= -1.55 and full_down >= 1.55,
		"first-person camera can look nearly straight up and down")
	player.cam._recoil_pitch = 0.0
	player.cam._recoil_back = 0.0
	player.cam.add_weapon_recoil(BananaGun.CAMERA_RECOIL)
	_check(player.cam._recoil_pitch < 0.0 and player.cam._recoil_back > 0.0,
		"first-person camera receives animated weapon recoil")
	for i in range(90):
		player.cam._advance_recoil(1.0 / 60.0)
	_check(absf(player.cam._recoil_pitch) < 0.002 and
		player.cam._recoil_back == 0.0,
		"camera recoil springs smoothly back to its resting pose")
	player.cam.add_weapon_recoil(SniperRifle.CAMERA_RECOIL)
	player.cam._advance_recoil(1.0)
	_check(absf(player.cam._recoil_pitch) <= 0.14 and
		absf(player.cam._recoil_pitch_velocity) < 1.5 and
		absf(player.cam._recoil_yaw) <= 0.045 and
		absf(player.cam._recoil_roll) <= 0.055,
		"sniper recoil remains stable across a one-second render hitch")
	for i in range(90):
		player.cam._advance_recoil(1.0 / 60.0)

	# Movement camera layers stay readable in first person, remain within strict
	# comfort bounds, and never contaminate the sniper's ballistic center ray.
	player.state = MonkeyPlayer.S.GROUND
	player.galloping = false
	player.velocity = Vector3.ZERO
	player.cam._reset_movement_camera()
	player.velocity = Vector3(7.0, 0.0, -10.0)
	var ground_min_y := INF
	var ground_max_y := -INF
	var ground_max_roll := 0.0
	var ground_max_inertia := 0.0
	for i in range(90):
		player.cam._advance_movement_camera(1.0 / 60.0,
			player.velocity, true, player.cam.yaw)
		ground_min_y = minf(ground_min_y,
			player.cam._camera_mount.position.y)
		ground_max_y = maxf(ground_max_y,
			player.cam._camera_mount.position.y)
		ground_max_roll = maxf(ground_max_roll,
			absf(player.cam._camera_mount.rotation.z))
		ground_max_inertia = maxf(ground_max_inertia,
			player.cam._motion_position.length())
	var ground_motion_bounded := _camera_motion_in_bounds(player.cam)
	_check(ground_max_y - ground_min_y > 0.018 and
		ground_max_roll > 0.006 and ground_max_inertia > 0.001 and
		ground_motion_bounded,
		"ground movement layers bounded stride bob, weight shift, and acceleration sway")

	player.velocity = Vector3.ZERO
	player.cam._reset_movement_camera()
	player.state = MonkeyPlayer.S.AIR
	player.velocity = Vector3(6.0, -28.0, -8.0)
	for i in range(36):
		player.cam._advance_movement_camera(1.0 / 60.0,
			player.velocity, false, player.cam.yaw)
	_check(player.cam._camera_mount.position.y > 0.008 and
		absf(player.cam._camera_mount.rotation.x) > 0.008 and
		_camera_motion_in_bounds(player.cam),
		"airborne camera lags vertical travel without exceeding comfort bounds")

	player.velocity = Vector3.ZERO
	player.cam._reset_movement_camera()
	player.state = MonkeyPlayer.S.SWING
	player.velocity = Vector3(24.0, -3.0, -4.0)
	for i in range(42):
		player.cam._advance_movement_camera(1.0 / 60.0,
			player.velocity, false, player.cam.yaw)
	_check(absf(player.cam._camera_mount.position.x) > 0.025 and
		absf(player.cam._camera_mount.rotation.z) > 0.075 and
		_camera_motion_in_bounds(player.cam),
		"vine motion adds bounded pendulum lag, pitch, yaw, and banking")

	player.velocity = Vector3.ZERO
	player.cam._reset_movement_camera()
	player.state = MonkeyPlayer.S.SWIM
	player.velocity = Vector3(2.0, 0.0, -4.0)
	var swim_min_y := INF
	var swim_max_y := -INF
	var swim_min_roll := INF
	var swim_max_roll := -INF
	for i in range(90):
		player.cam._advance_movement_camera(1.0 / 60.0,
			player.velocity, false, player.cam.yaw)
		swim_min_y = minf(swim_min_y, player.cam._camera_mount.position.y)
		swim_max_y = maxf(swim_max_y, player.cam._camera_mount.position.y)
		swim_min_roll = minf(swim_min_roll, player.cam._camera_mount.rotation.z)
		swim_max_roll = maxf(swim_max_roll, player.cam._camera_mount.rotation.z)
	_check(swim_max_y - swim_min_y > 0.018 and
		swim_max_roll - swim_min_roll > 0.018 and
		_camera_motion_in_bounds(player.cam),
		"swimming has a distinct bounded stroke heave and alternating roll")

	player.state = MonkeyPlayer.S.GROUND
	player.velocity = Vector3.ZERO
	player.cam._reset_movement_camera()
	player.cam.on_land(24.0)
	var landing_min := 0.0
	var landing_peak_pitch := 0.0
	for i in range(30):
		player.cam._advance_movement_camera(1.0 / 60.0,
			Vector3.ZERO, true, player.cam.yaw)
		landing_min = minf(landing_min, player.cam._landing_offset)
		landing_peak_pitch = maxf(landing_peak_pitch,
			absf(player.cam._landing_pitch))
	for i in range(180):
		player.cam._advance_movement_camera(1.0 / 60.0,
			Vector3.ZERO, true, player.cam.yaw)
	_check(landing_min < -0.012 and landing_peak_pitch > 0.006 and
		landing_min >= -CameraRig.LANDING_POSITION_LIMIT and
		absf(player.cam._landing_offset) < 0.0002 and
		absf(player.cam._landing_pitch) < 0.0002,
		"landing adds a bounded weight dip and pitch spring that fully settles")

	player.equip_weapon(4)
	player.state = MonkeyPlayer.S.SWING
	player.velocity = Vector3(30.0, -8.0, 4.0)
	player.cam.set_aiming(true)
	var scope_zeroed_immediately := \
		player.cam._camera_mount.position == Vector3.ZERO \
		and player.cam._camera_mount.rotation == Vector3.ZERO
	player.cam._reset_movement_camera()
	player.cam._trauma = 1.0
	player.cam._hit_trauma = 0.8
	player.cam._recoil_shake = 0.7
	for i in range(30):
		player.cam._advance_movement_camera(1.0 / 60.0,
			player.velocity, false, player.cam.yaw)
		player.cam._update_camera_shake(1.0 / 60.0, true)
	_check(scope_zeroed_immediately and player.cam.is_sniper_scoped() and
		player.cam._camera_mount.position == Vector3.ZERO and
		player.cam._camera_mount.rotation == Vector3.ZERO and
		player.cam._movement_blend == 0.0 and
		player.cam._cam.h_offset == 0.0 and player.cam._cam.v_offset == 0.0,
		"sniper ADS hard-disables movement sway and projection shake for exact aim")
	player.cam.set_aiming(false)
	player.equip_weapon(1)
	player.state = MonkeyPlayer.S.GROUND
	player.velocity = Vector3.ZERO
	player.cam._trauma = 0.0
	player.cam._hit_trauma = 0.0
	player.cam._recoil_shake = 0.0
	player.cam._cam.h_offset = 0.0
	player.cam._cam.v_offset = 0.0
	player.cam._reset_movement_camera()
	player.cam.set_first_person(false)
	# Exercise the authored shoulder length in open space. The denser duel arena
	# now has intentional central cover, so leaving this camera-only fixture at an
	# arbitrary earlier combat position made spring-arm collision timing decide
	# whether the otherwise unchanged assertion passed.
	player.global_position.y = 50.0
	player.reset_physics_interpolation()
	player.cam.snap_to_target()
	# SpringArm3D resolves its shape cast on physics ticks. Two ticks retire the
	# previous arena-cover hit length after this deliberate camera-fixture move.
	await get_tree().physics_frame
	await get_tree().physics_frame
	player.cam.snap_to_target()
	var position_before_shoulder_view := player.global_position
	await get_tree().process_frame
	player.rig.set_yaw(PI)
	player.cam.yaw = 0.0
	player._process(0.5)
	var body_aim_error := absf(angle_difference(player.rig.yaw_angle(), 0.0))
	var shoulder_camera_distance := player.cam.cam_pos().distance_to(
		player.global_position)
	_check(not player.cam.first_person and
		(player.cam._cam.cull_mask & MonkeyRig.LOCAL_BODY_VISUAL_LAYER) != 0 and
		not player.gun.first_person_view and player.gun.get_parent() == player.rig.el_r and
		not player.smg.first_person_view and player.smg.get_parent() == player.rig.el_r and
		not player.sniper.first_person_view and
		player.sniper.get_parent() == player.rig.el_r and
		player.rig.sh_r.position.x > 0.0 and
		player.cam._camera_mount.get_parent() == player.cam._arm and
		player.cam._cam.get_parent() == player.cam._camera_mount and
		player.cam._arm.position.x > 0.7 and
		CameraRig.THIRD_PERSON_ARM >= 5.75 and
		player.cam._arm.spring_length >= CameraRig.THIRD_PERSON_ARM - 0.01 and
		shoulder_camera_distance >= 4.5 and
		body_aim_error < 0.08 and
		player.global_position == position_before_shoulder_view,
		"third-person weapon is right-handed and turns the full monkey into aim")
	var cycled_first := player.cam.toggle_view()
	var position_before_front_view := player.global_position
	var cycled_front := player.cam.toggle_view()
	await get_tree().process_frame
	await get_tree().process_frame
	var front_offset := player.cam.cam_pos() - player.global_position
	front_offset.y = 0.0
	var front_look := -player.cam.cam_basis().z
	front_look.y = 0.0
	var front_direction := player.cam.front_subject_direction()
	_check(cycled_first == CameraRig.ViewMode.FIRST_PERSON and
		cycled_front == CameraRig.ViewMode.FRONT and
		player.cam.view_mode == CameraRig.ViewMode.FRONT and
		player.cam.front_view and not player.cam.first_person and
		(player.cam._cam.cull_mask & MonkeyRig.LOCAL_BODY_VISUAL_LAYER) != 0 and
		not player.cam._view_arms.visible and
		absf(player.cam._arm.position.x) < 0.01 and
		front_offset.length() > 2.0 and
		front_offset.normalized().dot(front_direction) > 0.95 and
		front_look.normalized().dot(-front_direction) > 0.95 and
		player.global_position == position_before_front_view,
		"C cycles to a centered front camera that looks at the unmoved monkey")
	player.gun.tick(1.0)
	var front_view_ammo := player.gun.ammo
	player.ti.shoot_just = true
	player._combat(player._gather())
	_check(player.gun.ammo == front_view_ammo,
		"front camera cannot shoot backward through the player model")
	player.cam.set_aiming(true)
	var front_aimed_in_first_person := player.cam.first_person
	player.cam.set_aiming(false)
	_check(front_aimed_in_first_person and player.cam.front_view,
		"aiming from front view temporarily uses first person then restores front view")
	var cycled_shoulder := player.cam.toggle_view()
	_check(cycled_shoulder == CameraRig.ViewMode.SHOULDER and
		not player.cam.front_view and not player.cam.first_person,
		"camera cycle returns from front view to the right shoulder")
	player.cam._recoil_pitch = 0.0
	player.cam._recoil_back = 0.0
	player.cam.add_weapon_recoil(PumpShotgun.CAMERA_RECOIL)
	_check(player.cam._recoil_pitch < 0.0 and player.cam._recoil_back > 0.0,
		"third-person camera receives animated weapon recoil")
	player.cam._hit_trauma = 0.0
	player.cam.on_hit(BananaBullet.DAMAGE, Vector3.RIGHT)
	_check(player.cam._hit_trauma > 0.0 and
		absf(player.cam._recoil_yaw_velocity) > 0.0,
		"camera reacts directionally when the player is hit")
	player.cam._recoil_pitch = 0.0
	player.cam._recoil_back = 0.0
	player.cam.on_headshot()
	_check(player.cam._recoil_pitch < -0.15 and
		player.cam._recoil_back > 0.04 and player.cam._hit_trauma > 0.8,
		"head hits snap the camera backward with a stronger reaction")
	main.hud.crosshair.set_state(CombatCrosshair.Mode.SHOTGUN, 30.0,
		Color.WHITE, false, 0.0)
	_check(main.hud.crosshair.mode == CombatCrosshair.Mode.SHOTGUN and
		main.hud.crosshair.ring_radius > 0.0,
		"HUD supports the spread-accurate shotgun circle reticle")
	main.hud.crosshair.set_state(CombatCrosshair.Mode.PLUS, 0.0,
		Color.WHITE, false, 1.0, 96.0)
	_check(is_equal_approx(main.hud.crosshair.accuracy_radius, 96.0),
		"hip-fire crosshair uses the full ballistic spread radius without smoothing or a visual cap")
	var scope_hold_pixels := SniperScopeOverlay.hold_offset_pixels(
		400.0, 200.0, SniperRifle.drop_below_zero_at(200.0), 10.0)
	var scope_body_dot := SniperScopeOverlay.target_dot_radius(
		400.0, SniperScopeOverlay.TARGET_BODY)
	var scope_head_dot := SniperScopeOverlay.target_dot_radius(
		400.0, SniperScopeOverlay.TARGET_HEAD)
	main.hud.set_sniper_scope_state(true, 10.0, 200.0,
		SniperRifle.drop_below_zero_at(200.0), HUD.ScopeTarget.BODY)
	var scope_overlay: SniperScopeOverlay = main.hud.sniper_scope
	var scope_body_state_ok: bool = scope_overlay.visible and \
		scope_overlay._target_zone == SniperScopeOverlay.TARGET_BODY
	main.hud.set_sniper_scope_state(true, 10.0, 200.0,
		SniperRifle.drop_below_zero_at(200.0), HUD.ScopeTarget.HEAD)
	var blink_before: float = scope_overlay._blink_time
	scope_overlay._process(0.05)
	_check(scope_hold_pixels > 0.0 and scope_body_state_ok and
		scope_overlay._target_zone == SniperScopeOverlay.TARGET_HEAD and
		scope_overlay.is_processing() and
		scope_overlay._blink_time > blink_before and
		scope_head_dot < scope_body_dot,
		"scope puts positive-drop hold guidance below center and its red head dot blinks and shrinks")
	main.hud.clear_sniper_scope()
	_check(not scope_overlay.visible and not scope_overlay.is_processing(),
		"scope overlay clears completely when sniper ADS ends")
	player.cam.set_sensitivity(1.5)
	var normal_sensitivity := player.cam.effective_sensitivity()
	player.cam.set_aiming(true)
	_check(player.cam.aiming and player.cam.first_person and
		player.cam.effective_sensitivity() < normal_sensitivity and
		player.gun.first_person_view,
		"right-click aim enters first person with reduced sensitivity")
	player.cam.set_aiming(false)
	_check(not player.cam.aiming and not player.cam.first_person,
		"releasing aim restores the preferred third-person camera")
	player.cam.set_first_person(true)
	player.cam.set_aiming(true)
	player.cam.set_aiming(false)
	_check(player.cam.first_person,
		"releasing aim preserves a first-person camera preference")
	var death_position := player.global_position
	player.health = 10.0
	player._invulnerable_t = 0.0
	player.velocity = Vector3(1.5, 2.0, -0.8)
	player.take_damage(20.0, null, Vector3(0.8, 0.2, -1.2), "body")
	await get_tree().process_frame
	var body_ragdoll := player.death_ragdoll
	_check(player.defeated and body_ragdoll != null and
		not body_ragdoll.head_detached and
		body_ragdoll.get_node_or_null("NeckJoint") != null and
		player.cam._death_view and not player.cam.first_person and
		not player.rig.visible,
		"body defeat creates a connected ragdoll and forces third-person view")
	var torso_start := body_ragdoll.torso.global_position
	for i in range(8):
		await get_tree().physics_frame
	_check(body_ragdoll.torso.global_position.distance_to(torso_start) > 0.03 and
		player.cam._current_follow_target() == body_ragdoll.torso,
		"death camera follows the falling physics torso")
	player.revive_at(death_position)
	await get_tree().process_frame
	_check(not player.defeated and player.death_ragdoll == null and
		not player.cam._death_view and player.cam.first_person,
		"revival removes the ragdoll and restores the preferred camera")
	player.cam.set_first_person(false)
	var proxy := world.spawn_puppet(77, "HitboxProxy")
	await get_tree().process_frame
	_check(proxy.body_hitbox != null and proxy.head_hitbox != null and
		proxy.rig._outline_material != null,
		"remote player replicas expose body/head hit zones and a shared outline")
	var torso_outline = proxy.rig.torso_p.get_node_or_null("BodyTorso")
	var belly_patch = proxy.rig.torso_p.get_node_or_null("BellyPatch")
	var face_details_clean := true
	for visual in proxy.rig.head_p.find_children("*", "MeshInstance3D", true,
			false):
		var visual_name := str(visual.name)
		var is_face_detail := visual_name.begins_with("Face") \
			or visual_name.begins_with("Muzzle") \
			or visual_name.begins_with("InnerEar") \
			or visual_name.begins_with("Eye") \
			or visual_name.begins_with("Pupil") \
			or visual_name.begins_with("Cheek") \
			or str(visual.get_parent().name) == "Smile"
		if is_face_detail and visual.material_overlay != null:
			face_details_clean = false
	_check(torso_outline != null and torso_outline.material_overlay \
			== proxy.rig._outline_material and belly_patch != null \
			and belly_patch.material_overlay == null and face_details_clean \
			and (proxy.rig.winter_scarf == null \
				or proxy.rig.winter_scarf.material_overlay == null),
		"enemy outline follows the outer body only, never face, eyes, belly, or scarf")
	proxy.on_shot(Vector3.FORWARD, Net.WEAPON_SMG)
	_check(proxy.smg.visible and not proxy.gun.visible and
		not proxy.shotgun.visible and proxy.smg.recoil > 0.0,
		"remote replicas show SMG fire and third-person weapon recoil")
	proxy.on_shot(Vector3.FORWARD, Net.WEAPON_SNIPER)
	_check(proxy.sniper.visible and not proxy.gun.visible and
		not proxy.shotgun.visible and not proxy.smg.visible and
		proxy.sniper.recoil > 0.0,
		"remote replicas show the sniper model and its heavy recoil")
	proxy.apply_state(Vector3(3, 4, 5), 0.4, Vector3(1, 0, -2),
		MonkeyRig.Anim.RUN, false, Vector3.ZERO, 0.0,
		PackedVector3Array(), Net.WEAPON_SMG, true, true)
	await get_tree().process_frame
	_check(proxy.smg.get_parent() == proxy.rig.weapon_back_mount and
		proxy._state_melee_mode and proxy._state_weapon_stowed,
		"replicated melee state shows the remote weapon on its back")
	proxy.apply_state(Vector3(3, 4, 5), 0.4, Vector3(1, 0, -2),
		MonkeyRig.Anim.AIR, false, Vector3.ZERO, 0.0, PackedVector3Array(),
		Net.WEAPON_SMG, false, false)
	await get_tree().process_frame
	_check(proxy.smg.get_parent() == proxy.rig.el_r,
		"replicated draw state returns the remote weapon to its hand")
	proxy.apply_state(Vector3(3, 4, 5), 0.4, Vector3.ZERO,
		MonkeyRig.Anim.IDLE, false, Vector3.ZERO, 0.0,
		PackedVector3Array(), Net.WEAPON_SMG, false, false, 7, true, 0.0)
	proxy.smg.tick(SMG.RELOAD_TIME * 0.31)
	proxy._process(0.0)
	_check(proxy.smg.reload_remaining > 0.0 and proxy.smg._reload_mag.visible \
		and proxy.rig._reload_pose,
		"replicated reload state plays the remote magazine trick with support-paw tracking")
	proxy.apply_state(Vector3(3, 4, 5), 0.4, Vector3.ZERO,
		MonkeyRig.Anim.IDLE, false, Vector3.ZERO, 0.0,
		PackedVector3Array(), Net.WEAPON_SMG, true, false, 7, false, 0.55)
	proxy._process(0.0)
	_check(proxy.smg.reload_remaining == 0.0 \
		and proxy.smg.get_parent() == proxy.rig.weapon_back_mount \
		and proxy.rig._healing_pose and proxy.rig.bandage_roll.visible \
		and proxy.rig.bandage_wrist.visible and proxy.rig.bandage_strip.visible,
		"replicated healing stows the remote weapon and shows its roll, wrist wrap, and cloth strip")
	proxy.begin_defeat(Vector3(3, 4, 5), 0.4, Vector3(1, 0, -2),
		Vector3(0.5, 0.2, -1.0), true)
	_check(proxy.defeated_visual and proxy.death_ragdoll != null and
		proxy.death_ragdoll.head_detached and not proxy.rig.visible and
		proxy.body_hitbox.collision_layer == 0,
		"replicated defeat shows the same headshot ragdoll to remote players")
	proxy._defeat_guard_t = 0.0
	proxy.apply_state(Vector3(4, 4, 5), 0.4, Vector3.ZERO,
		MonkeyRig.Anim.IDLE, false, Vector3.ZERO, 0.0, PackedVector3Array())
	await get_tree().process_frame
	_check(not proxy.defeated_visual and proxy.death_ragdoll == null and
		proxy.rig.visible and proxy.body_hitbox.collision_layer != 0,
		"fresh replicated movement removes the remote ragdoll after respawn")
	world.remove_puppet(77)
	for child in world.get_children():
		if child is BananaBullet:
			child.queue_free()
	await get_tree().process_frame

	var ai: AiMonkey = world.spawn_solo_ai()
	# Let the live CharacterBody establish a real floor contact before freezing the
	# deterministic combat fixture. AI reload policy intentionally requires that
	# contact so a support-paw animation can never begin in mid-air.
	ai._shot_t = 99.0
	for i in range(40):
		await get_tree().physics_frame
	var ai_landed_for_reload := ai.is_on_floor() and ai.state == ai.S.GROUND
	ai.set_physics_process(false)
	ai.set_process(false)

	var runtime_arena_pieces := 0
	var runtime_arena_collisions_ok := true
	for chunk_value in world.chunks.values():
		var chunk := chunk_value as Chunk
		if not chunk or str(chunk.layout.get("arena_id", "")) != Gen.ARENA_ID:
			continue
		runtime_arena_pieces += chunk._arena_pieces.size()
		for piece in chunk._arena_pieces:
			runtime_arena_collisions_ok = runtime_arena_collisions_ok \
				and piece._collisions_built \
				and not piece._collision_bodies.is_empty()
	var runtime_arena_huts := 0
	var runtime_arena_huts_ok := true
	for hut_id in world.supply_huts:
		if not str(hut_id).begins_with("s:arena#"):
			continue
		var arena_hut := world.supply_huts[hut_id] as SupplyHut
		runtime_arena_huts += 1
		runtime_arena_huts_ok = runtime_arena_huts_ok and arena_hut != null \
			and arena_hut.bandage_count >= 1 and arena_hut._collisions_built \
			and not arena_hut._collision_bodies.is_empty()
	_check(runtime_arena_pieces == 12 and runtime_arena_huts == 4 \
		and runtime_arena_collisions_ok and runtime_arena_huts_ok,
		"the streamed duel arena instantiates twelve solid cover pieces and four collidable bandage huts")

	var weapon_policy_ok := AiMonkey.preferred_weapon_for_distance(6.0) \
		== AiMonkey.WEAPON_SHOTGUN \
		and AiMonkey.preferred_weapon_for_distance(18.0) == AiMonkey.WEAPON_SMG \
		and AiMonkey.preferred_weapon_for_distance(32.0) == AiMonkey.WEAPON_BANANA \
		and AiMonkey.preferred_weapon_for_distance(58.0) == AiMonkey.WEAPON_SNIPER \
		and AiMonkey.weapon_distance_score(AiMonkey.WEAPON_SHOTGUN, 6.0) \
			> AiMonkey.weapon_distance_score(AiMonkey.WEAPON_SNIPER, 6.0) \
		and AiMonkey.weapon_distance_score(AiMonkey.WEAPON_SMG, 18.0) \
			> AiMonkey.weapon_distance_score(AiMonkey.WEAPON_SHOTGUN, 18.0) \
		and AiMonkey.weapon_distance_score(AiMonkey.WEAPON_BANANA, 32.0) \
			> AiMonkey.weapon_distance_score(AiMonkey.WEAPON_SHOTGUN, 32.0) \
		and AiMonkey.weapon_distance_score(AiMonkey.WEAPON_SNIPER, 58.0) \
			> AiMonkey.weapon_distance_score(AiMonkey.WEAPON_SHOTGUN, 58.0) \
		and AiMonkey.weapon_muzzle_speed(AiMonkey.WEAPON_BANANA) \
			== BananaGun.MUZZLE_SPEED \
		and AiMonkey.weapon_muzzle_speed(AiMonkey.WEAPON_SHOTGUN) \
			== PumpShotgun.MUZZLE_SPEED \
		and AiMonkey.weapon_muzzle_speed(AiMonkey.WEAPON_SMG) == SMG.MUZZLE_SPEED \
		and AiMonkey.weapon_muzzle_speed(AiMonkey.WEAPON_SNIPER) \
			== SniperRifle.MUZZLE_SPEED
	_check(weapon_policy_ok,
		"AI range policy deliberately selects the shotgun, SMG, banana gun, and sniper with their real ballistics")
	_check(AiMonkey.burst_round_range(AiMonkey.WEAPON_BANANA) \
			== Vector2i(2, 2) \
		and AiMonkey.burst_round_range(AiMonkey.WEAPON_SMG) \
			== Vector2i(2, 3) \
		and AiMonkey.burst_round_range(AiMonkey.WEAPON_SHOTGUN) \
			== Vector2i(1, 1) \
		and AiMonkey.burst_round_range(AiMonkey.WEAPON_SNIPER) \
			== Vector2i(1, 1),
		"AI burst policy uses two banana rounds, two-to-three SMG rounds, and single shotgun/sniper shots")

	var ai_spread_order_ok := true
	for slot in range(AiMonkey.WEAPON_BANANA, AiMonkey.WEAPON_SNIPER + 1):
		var ideal_range := AiMonkey.weapon_range(slot)
		var sample_distance := (ideal_range.x + ideal_range.y) * 0.5
		var ai_planted_spread := AiMonkey.combat_spread_degrees(slot, 0, 0.0,
			0.0, 0.0, sample_distance)
		var ai_moving_spread := AiMonkey.combat_spread_degrees(slot, 1, 7.0,
			8.0, 55.0, sample_distance)
		var ai_swing_spread := AiMonkey.combat_spread_degrees(slot, 2, 16.0,
			8.0, 55.0, sample_distance)
		var ai_moving_still_target := AiMonkey.combat_spread_degrees(slot, 1, 7.0,
			0.0, 0.0, sample_distance)
		ai_spread_order_ok = ai_spread_order_ok \
			and ai_planted_spread >= 0.75 \
			and ai_planted_spread <= 2.25 \
			and ai_planted_spread < ai_moving_spread \
			and ai_moving_spread < ai_swing_spread \
			and ai_moving_spread > ai_moving_still_target
	_check(ai_spread_order_ok,
		"every AI gun keeps fair planted spread and gains error from movement and target motion, with vine shots widest")

	# Freeze a close, unobstructed firing fixture to prove movement transitions
	# cannot schedule a grounded shot or reload that begins after the parent has
	# already jumped or dropped to its sprint stance.
	var ai_fixture_position := ai.global_position
	player.global_position = ai_fixture_position + Vector3(0.0, 0.0, -4.0)
	player.health = player.MAX_HEALTH
	player.defeated = false
	ai.state = ai.S.GROUND
	ai.velocity = Vector3.ZERO
	ai.equip_weapon(AiMonkey.WEAPON_BANANA)
	ai.gun.reset_cylinder()
	ai._reset_frame_input()
	var stable_fire_available := ai._can_fire_now()
	ai.ti.jump_just = true
	var jump_blocks_fire := not ai._can_fire_now()
	ai.gun.ammo = 0
	var jump_blocks_reload := not ai._should_reload_active_weapon()
	ai.ti.jump_just = false
	ai.ti.sprint = true
	var sprint_blocks_reload := not ai._should_reload_active_weapon()
	ai._reset_frame_input()
	_check(stable_fire_available and jump_blocks_fire and jump_blocks_reload \
		and sprint_blocks_reload,
		"AI transition frames cannot fire with planted aim or begin a reload after jumping/sprinting")

	# An in-progress string owns a planted firing window. If visibility never
	# returns, its bounded commit expires into the same lateral recovery phase.
	var bursts_before_timeout := ai.bursts_completed
	ai.gun.ammo = BananaGun.CAPACITY
	ai._burst_weapon_slot = AiMonkey.WEAPON_BANANA
	ai._burst_rounds_remaining = 1
	ai._burst_rounds_queued = 1
	ai._burst_commit_t = AiMonkey.BURST_COMMIT_TIMEOUT
	ai._post_burst_strafe_t = 0.0
	ai._burst_settle_t = 0.0
	ai._set_tactic(AiMonkey.Tactic.ADVANCE, 1.0)
	ai._update_ground_navigation()
	var burst_plants: bool = ai.ti.dir.length() <= 0.01
	ai._update_burst_timers(AiMonkey.BURST_COMMIT_TIMEOUT + 0.01)
	var burst_timeout_recovers := ai._burst_rounds_remaining == 0 \
		and ai.bursts_completed == bursts_before_timeout + 1 \
		and ai._post_burst_strafe_t > 0.0
	_check(burst_plants and burst_timeout_recovers,
		"AI holds its firing platform through a burst and aborts stalled bursts into a strafe")
	ai._clear_weapon_burst()
	ai._post_burst_strafe_t = 0.0
	ai._burst_settle_t = 0.0

	# With a large vertical separation, true ballistic distance must beat the
	# misleading four-metre flat distance. One useful sniper round is a valid
	# fallback, and the switch lock prevents immediately thrashing away from it.
	ai.shotgun.reset_cylinder()
	ai.smg.reset_cylinder()
	ai.sniper.reset_cylinder()
	ai.gun.reset_cylinder()
	ai.shotgun.ammo = 0
	ai.gun.ammo = AiMonkey.burst_round_range(AiMonkey.WEAPON_BANANA).x
	ai.smg.ammo = AiMonkey.burst_round_range(AiMonkey.WEAPON_SMG).x
	ai.sniper.ammo = AiMonkey.burst_round_range(AiMonkey.WEAPON_SNIPER).x
	ai.equip_weapon(AiMonkey.WEAPON_SHOTGUN)
	player.global_position = ai_fixture_position + Vector3(0.0, 52.0, -4.0)
	ai._under_fire_t = 3.0
	ai._emergency_switch_lock_t = 0.0
	var switches_before_vertical := ai.weapon_switch_count
	ai._update_weapon_choice()
	var vertical_choice_ok := ai.weapon_slot == AiMonkey.WEAPON_SNIPER \
		and ai.weapon_switch_count == switches_before_vertical + 1 \
		and ai._weapon_ready_for_fight(AiMonkey.WEAPON_SNIPER)
	ai._update_weapon_choice()
	var switch_lock_ok := ai.weapon_slot == AiMonkey.WEAPON_SNIPER \
		and ai.weapon_switch_count == switches_before_vertical + 1 \
		and not ai._should_reload_active_weapon()
	ai.smg.ammo = AiMonkey.burst_round_range(AiMonkey.WEAPON_SMG).x - 1
	var partial_smg_rejected := not ai._weapon_ready_for_fight(
		AiMonkey.WEAPON_SMG)
	_check(vertical_choice_ok and switch_lock_ok and partial_smg_rejected,
		"AI uses true 3D range, complete-burst ammo, and switch hysteresis for emergency weapons")
	ai._under_fire_t = 0.0
	ai._emergency_switch_lock_t = 0.0
	ai._reset_frame_input()
	ai.equip_weapon(AiMonkey.WEAPON_BANANA)
	ai.gun.reset_cylinder()
	ai.shotgun.reset_cylinder()
	ai.smg.reset_cylinder()
	ai.sniper.reset_cylinder()

	var ai_reload_start_count := ai.reloads_started
	var ai_reload_visuals_ok := ai_landed_for_reload
	var strict_reload_cover_seen := false
	var reload_cover_policy_ok := true
	# Earlier ballistic fixtures temporarily lift the player. Put this cover-policy
	# target back on arena ground so the rays represent a real duel stance.
	player.global_position = Vector3(0.0, Gen.height(0.0, 0.0), 0.0)
	for slot in range(AiMonkey.WEAPON_BANANA, AiMonkey.WEAPON_SNIPER + 1):
		ai.equip_weapon(slot)
		var ai_weapon: Node3D = ai._weapon_node(slot)
		ai_weapon.reset_cylinder()
		ai_weapon.ammo = 0
		ai_weapon.cooldown = 0.0
		var strict_cover_available := ai._choose_cover_point(true,
			AiMonkey.RELOAD_COVER_MAX_DISTANCE)
		var cover_distance := ai.global_position.distance_to(ai._cover_point) \
			if strict_cover_available else 0.0
		strict_reload_cover_seen = strict_reload_cover_seen \
			or strict_cover_available
		var reload_sequence_before: int = ai_weapon.reload_sequence
		ai._update_combat(0.0)
		ai._combat(ai._gather())
		ai._process(0.0)
		if strict_cover_available:
			reload_cover_policy_ok = reload_cover_policy_ok \
				and ai._has_cover_point \
				and ai.tactical_state == AiMonkey.Tactic.COVER \
				and ai.global_position.distance_to(ai._cover_point) \
					<= AiMonkey.RELOAD_COVER_MAX_DISTANCE \
				and ai._candidate_has_cover(ai._cover_point)
			ai._update_ground_navigation()
			if cover_distance > AiMonkey.RELOAD_COVER_STOP_DISTANCE:
				reload_cover_policy_ok = reload_cover_policy_ok \
					and ai.ti.dir.length() > 0.1 \
					and not ai.ti.sprint and not ai.is_all_fours()
		ai_reload_visuals_ok = ai_reload_visuals_ok \
			and ai.active_weapon == ai_weapon \
			and ai_weapon.reload_remaining > 0.0 \
			and ai_weapon.reload_sequence == reload_sequence_before + 1 \
			and ai_weapon.has_dynamic_reload_hand() and ai.rig._reload_pose \
			and ai_weapon.visible
		ai_weapon.cancel_reload()
		ai_weapon.reset_cylinder()
		ai._process(0.0)
	_check(ai_reload_visuals_ok \
		and ai.reloads_started == ai_reload_start_count + 4,
		"AI initiates each gun's real grounded reload with visible prop and support-paw tracking")
	_check(strict_reload_cover_seen and reload_cover_policy_ok,
		"AI tactical reload uses strict cover and bipedal run input until reaching its destination")
	ai.equip_weapon(AiMonkey.WEAPON_BANANA)
	ai.gun.reset_cylinder()
	var range_test_player := Vector3(0, 50, 0)
	player.global_position = range_test_player
	ai.global_position = range_test_player + Vector3(0, 0, -35.0)
	ai.health = ai.MAX_HEALTH
	ai.defeated = false
	ai._invulnerable_t = 0.0
	await get_tree().physics_frame
	var sniper_body_origin := range_test_player + Vector3(0, 0.52, 0)
	world.spawn_bullet(player, sniper_body_origin,
		SniperRifle.zeroed_direction(Vector3.FORWARD) * SniperRifle.MUZZLE_SPEED,
		SniperRifle.DAMAGE, true, Net.WEAPON_SNIPER)
	for i in range(16):
		await get_tree().physics_frame
	_check(is_equal_approx(ai.health, 15.0) and not ai.defeated,
		"a sniper body shot removes exactly 85 percent of full health")

	# Put the head zone on the exact 160 m trajectory, slightly below its centre
	# so the enlarged swept bullet remains clear of the torso hitbox.
	var long_headshot_distance := 160.0
	var long_headshot_origin := Vector3(0, 120.0, 0)
	var long_headshot_drop := SniperRifle.drop_below_zero_at(
		long_headshot_distance)
	ai.global_position = Vector3(0,
		long_headshot_origin.y - long_headshot_drop -
		1.17 - 0.16,
		-long_headshot_distance)
	ai.health = ai.MAX_HEALTH
	ai.defeated = false
	ai._invulnerable_t = 0.0
	await get_tree().physics_frame
	world.spawn_bullet(player, long_headshot_origin,
		SniperRifle.zeroed_direction(Vector3.FORWARD) * SniperRifle.MUZZLE_SPEED,
		SniperRifle.DAMAGE, true, Net.WEAPON_SNIPER)
	for i in range(54):
		await get_tree().physics_frame
	_check(ai.defeated and ai.health == 0.0 and ai.death_ragdoll != null and
		ai.death_ragdoll.head_detached,
		"sniper headshots remain instant kills well beyond the revolver falloff range")
	ai.revive_at(range_test_player + Vector3(0, 0, -8))
	ai._invulnerable_t = 0.0
	await get_tree().process_frame

	ai.global_position = range_test_player + Vector3(0, 0, -8)
	ai.health = ai.MAX_HEALTH
	ai._invulnerable_t = 0.0
	await get_tree().physics_frame
	var hit_confirmations: Array[Vector2] = []
	player.bullet_hit_confirmed.connect(func(headshot: bool, damage: float):
		hit_confirmations.append(Vector2(1.0 if headshot else 0.0, damage)))
	var hud_hits_before_shotgun: int = main.hud.hit_marker.flash_count
	for pellet_direction in PumpShotgun.pellet_directions(Vector3(0, 0, -1), 1337):
		world.spawn_bullet(player, range_test_player + Vector3(0, 0.65, -0.6),
			pellet_direction * PumpShotgun.MUZZLE_SPEED,
			PumpShotgun.PELLET_DAMAGE, false)
	for i in range(18):
		await get_tree().physics_frame
	var close_damage := ai.MAX_HEALTH - ai.health
	var close_hit_count := hit_confirmations.size()
	var shotgun_markers_are_body_hits := close_hit_count > 0
	for confirmation in hit_confirmations:
		shotgun_markers_are_body_hits = shotgun_markers_are_body_hits \
			and confirmation.x == 0.0 \
			and confirmation.y == PumpShotgun.PELLET_DAMAGE
	_check(close_damage >= 60.0 \
		and close_hit_count == roundi(close_damage / PumpShotgun.PELLET_DAMAGE) \
		and main.hud.hit_marker.flash_count - hud_hits_before_shotgun \
			== close_hit_count and shotgun_markers_are_body_hits \
		and not main.hud.hit_marker.last_headshot,
		"close shotgun confirms every landed pellet without false headshot markers")

	ai.global_position = range_test_player + Vector3(0, 0, -25)
	ai.health = ai.MAX_HEALTH
	ai._invulnerable_t = 0.0
	await get_tree().physics_frame
	for pellet_direction in PumpShotgun.pellet_directions(Vector3(0, 0, -1), 7331):
		world.spawn_bullet(player, range_test_player + Vector3(0, 0.65, -0.6),
			pellet_direction * PumpShotgun.MUZZLE_SPEED,
			PumpShotgun.PELLET_DAMAGE, false)
	for i in range(30):
		await get_tree().physics_frame
	var mid_damage := ai.MAX_HEALTH - ai.health
	_check(mid_damage >= 15.0,
		"mid-range shotgun pattern still lands useful damage")

	var player_pos := Vector3(0, Gen.height(0, 0) + 3.0, 0)
	player.global_position = player_pos
	ai.global_position = player_pos + Vector3(0, 0, -6.0)
	ai.health = ai.MAX_HEALTH
	var body_confirmations_before := hit_confirmations.size()
	var body_hud_flashes_before: int = main.hud.hit_marker.flash_count
	world.spawn_bullet(player, player_pos + Vector3(0, 0.65, -0.6),
		Vector3(0, 0, -BananaGun.MUZZLE_SPEED))
	for i in range(12):
		await get_tree().physics_frame
	_check(ai.health == ai.MAX_HEALTH - BananaBullet.DAMAGE \
		and hit_confirmations.size() == body_confirmations_before + 1 \
		and hit_confirmations[-1].x == 0.0 \
		and hit_confirmations[-1].y == BananaBullet.DAMAGE \
		and main.hud.hit_marker.flash_count == body_hud_flashes_before + 1 \
		and main.hud.hit_marker.get_index() > main.hud.sniper_scope.get_index() \
		and main.hud.hit_marker.get_index() > main.hud.damage_overlay.get_index(),
		"swept bullet confirms one body hit through the visible HUD layer")

	ai.health = ai.MAX_HEALTH
	ai.defeated = false
	ai._invulnerable_t = 0.0
	var head_confirmations_before := hit_confirmations.size()
	var head_hud_flashes_before: int = main.hud.hit_marker.flash_count
	world.spawn_bullet(player, player_pos + Vector3(0, 1.17, -0.6),
		Vector3(0, 0, -BananaGun.MUZZLE_SPEED))
	for i in range(12):
		await get_tree().physics_frame
	_check(ai.defeated and ai.health == 0.0 and
		ai.death_ragdoll != null and ai.death_ragdoll.head_detached and
		ai.death_ragdoll.get_node_or_null("NeckJoint") == null and
		ai.death_ragdoll.head != null and
		ai.death_ragdoll.head.get_node_or_null("Smile") != null,
		"swept lethal head hit defeats the monkey and detaches its ragdoll head")
	_check(hit_confirmations.size() == head_confirmations_before + 1 \
		and hit_confirmations[-1].x == 1.0 \
		and hit_confirmations[-1].y == ai.MAX_HEALTH \
		and main.hud.hit_marker.flash_count == head_hud_flashes_before + 1 \
		and main.hud.hit_marker.last_headshot,
		"head impacts confirm once with the final applied projectile damage")
	var marker := HitMarker.new()
	marker.size = Vector2(44, 44)
	world.add_child(marker)
	marker.flash(false)
	marker._process(HitMarker.HOLD_SECONDS + HitMarker.FADE_SECONDS - 0.02)
	var nearly_expired := marker.remaining_seconds()
	marker.flash(false)
	_check(marker.visible and marker.flash_count == 2 and not marker.last_headshot \
		and marker.remaining_seconds() > nearly_expired,
		"repeated hits restart one bounded marker without allocating another HUD node")
	marker._process(HitMarker.HOLD_SECONDS + HitMarker.FADE_SECONDS + 0.01)
	_check(not marker.visible and marker.remaining_seconds() == 0.0,
		"hit marker fades completely after its bounded confirmation window")
	marker.queue_free()

	var target := PracticeTarget.new()
	world.add_child(target)
	target.setup(player_pos + Vector3(4, 0, -5), player_pos)
	var excluded_confirmations_before := hit_confirmations.size()
	var excluded_hud_flashes_before: int = main.hud.hit_marker.flash_count
	world.spawn_bullet(player, target.global_position + Vector3(0, 1.85, 2.0),
		Vector3(0, 0, -BananaGun.MUZZLE_SPEED))
	for i in range(8):
		await get_tree().physics_frame
	_check(target.collision_layer == 0 \
		and hit_confirmations.size() == excluded_confirmations_before \
		and main.hud.hit_marker.flash_count == excluded_hud_flashes_before,
		"practice targets react to bullets without producing player hit markers")
	var wall_pos := player_pos + Vector3(7, 1.0, -5)
	world.add_debug_wall(wall_pos, Vector3(1.2, 2.0, 0.4))
	world.spawn_bullet(player, wall_pos + Vector3(0, 0, 2.0),
		Vector3(0, 0, -BananaGun.MUZZLE_SPEED))
	for i in range(8):
		await get_tree().physics_frame
	_check(hit_confirmations.size() == excluded_confirmations_before \
		and main.hud.hit_marker.flash_count == excluded_hud_flashes_before,
		"world impacts never produce player hit markers")

	ai.revive_at(player_pos + Vector3(9, 0, -9))
	ai.target = player
	# The deterministic fixture freezes AI physics above while moving its target
	# through several ballistic ranges. Refresh the bot's deliberately delayed
	# observation before testing direction so this assertion measures aim policy,
	# not an intentionally stale awareness sample from the live landing phase.
	ai._observed_target_position = player.global_position
	ai._observed_target_velocity = player.velocity
	ai._aim_error = Vector2.ZERO
	var aim: Array = ai.shot_aim()
	var expected := (player.global_position + Vector3.UP * 0.78 - ai.hand_pos()).normalized()
	_check((aim[1] as Vector3).dot(expected) > 0.96,
		"AI leads and aims toward the player")
	_check(AiMonkey.aim_spread(false, 30.0) >
		AiMonkey.aim_spread(true, 30.0) * 3.0,
		"AI is much less accurate while swinging than when planted")

	print("COMBATTEST %d/%d %s" % [passed, total, "PASS" if passed == total else "FAIL"])
	get_tree().quit(0 if passed == total else 1)


func _sample_reload_motion(fps: int, duration: float,
		thresholds: Array) -> Dictionary:
	var support := Transform3D(Basis.IDENTITY, Vector3(-0.13, -0.125, -0.015))
	var toss_start := Transform3D(Basis.IDENTITY,
		Vector3(-0.48, -0.46, 0.16))
	var catch_basis := SatisfyingReload.trick_spin(1.0, 2.15)
	var catch := Transform3D(catch_basis, Vector3(-0.25, -0.04, -0.01))
	var socket := Transform3D(Basis.from_euler(Vector3(-0.16, 0.0, 0.0)),
		Vector3(0.0, -0.255, -0.08))
	var elapsed := 0.0
	var previous := 0.0
	var previous_position := support.origin
	var maximum_step := 0.0
	var event_count := 0
	var timing_ok := true
	var pose := support
	var frame_dt := 1.0 / float(fps)
	while previous < 1.0:
		elapsed = minf(elapsed + frame_dt, duration)
		var current := elapsed / duration
		for threshold in thresholds:
			if SatisfyingReload.crossed(previous, current, threshold):
				event_count += 1
				timing_ok = timing_ok \
					and current - float(threshold) <= frame_dt / duration + 0.00001
		if current < 0.23:
			pose = SatisfyingReload.arc_transform(support, toss_start, 0.045,
				SatisfyingReload.phase(current, 0.0, 0.23))
		elif current < 0.47:
			var toss := SatisfyingReload.phase(current, 0.23, 0.47)
			pose = Transform3D(SatisfyingReload.trick_spin(toss, 2.15),
				SatisfyingReload.arc(toss_start.origin, catch.origin, 0.31, toss))
		elif current < 0.73:
			var insert := SatisfyingReload.phase(current, 0.47, 0.73)
			var drive := SatisfyingReload.overshoot(insert, 0.18)
			pose = Transform3D(SatisfyingReload.slerp_basis(
				catch.basis, socket.basis, insert),
				SatisfyingReload.arc(catch.origin, socket.origin, 0.105, drive))
		else:
			pose = SatisfyingReload.arc_transform(socket, support, 0.055,
				SatisfyingReload.phase(current, 0.73, 0.98))
		maximum_step = maxf(maximum_step,
			previous_position.distance_to(pose.origin))
		previous_position = pose.origin
		previous = current
	return {
		"events": event_count,
		"timing_ok": timing_ok,
		"final_error": pose.origin.distance_to(support.origin),
		"max_step": maximum_step,
	}


func _check(condition: bool, label: String) -> void:
	total += 1
	if condition:
		passed += 1
		print("  [ok] " + label)
	else:
		print("  [FAIL] " + label)


func _camera_motion_in_bounds(camera: CameraRig) -> bool:
	var position := camera._camera_mount.position
	var rotation := camera._camera_mount.rotation
	return absf(position.x) <= CameraRig.MOVEMENT_POSITION_LIMIT.x + 0.0001 \
		and absf(position.y) <= CameraRig.MOVEMENT_POSITION_LIMIT.y + 0.0001 \
		and absf(position.z) <= CameraRig.MOVEMENT_POSITION_LIMIT.z + 0.0001 \
		and absf(rotation.x) <= CameraRig.MOVEMENT_ROTATION_LIMIT.x + 0.0001 \
		and absf(rotation.y) <= CameraRig.MOVEMENT_ROTATION_LIMIT.y + 0.0001 \
		and absf(rotation.z) <= CameraRig.MOVEMENT_ROTATION_LIMIT.z + 0.0001


func _has_mouse_binding(action: StringName, button: MouseButton) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventMouseButton and event.button_index == button:
			return true
	return false


func _has_key_binding(action: StringName, key: Key) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey and event.physical_keycode == key:
			return true
	return false


func _distance_to_segment(point: Vector3, start: Vector3, finish: Vector3) -> float:
	var span := finish - start
	if span.length_squared() < 0.000001:
		return point.distance_to(start)
	var along := clampf((point - start).dot(span) / span.length_squared(),
		0.0, 1.0)
	return point.distance_to(start + span * along)
