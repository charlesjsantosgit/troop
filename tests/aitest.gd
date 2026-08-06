extends Node
## Exercises the live solo rival rather than its deterministic helpers.


func run(main) -> void:
	var world: World = main.world
	var player := world.local_player
	var ai: AiMonkey = world.ai_opponent
	player.test_mode = true
	var start := ai.global_position
	var fired := false
	var swung := false
	var player_was_hit := false
	var landed_to_shoot := false
	var ground_frames := 0
	var swing_frames := 0
	var airborne_frames := 0
	var observed_tactics := {}
	for i in range(600):
		await get_tree().physics_frame
		var shot_decisions := 0
		for slot in ai.shots_by_slot:
			shot_decisions += int(ai.shots_by_slot[slot])
		fired = fired or shot_decisions > 0
		swung = swung or ai.state == ai.S.SWING
		landed_to_shoot = landed_to_shoot or ai.ground_shots > 0
		player_was_hit = player_was_hit or player.health < player.MAX_HEALTH
		observed_tactics[ai.tactical_state_name] = true
		if ai.state == ai.S.SWING:
			swing_frames += 1
		elif ai.is_on_floor():
			ground_frames += 1
		else:
			airborne_frames += 1
	var moved := ai.global_position.distance_to(start) > 2.0
	var used_weapons := 0
	for slot in ai.weapon_use_counts:
		used_weapons += 1 if int(ai.weapon_use_counts[slot]) > 0 else 0
	var ground_dominant := ground_frames > swing_frames * 2 \
		and ground_frames >= 180 and ai.ground_shots >= ai.swing_shots
	var tactical_ground_movement := ai.ground_repositions >= 2 \
		and observed_tactics.size() >= 3 and ai.vine_repositions <= 1
	var changed_loadout := ai.weapon_switch_count >= 1 and used_weapons >= 2
	var completed_burst_cycle := ai.bursts_completed >= 1 \
		and ai.post_burst_strafes >= 1 \
		and ai.last_burst_size >= 1 and ai.last_burst_size <= 3
	var passed := int(moved) + int(fired) + int(swung) \
		+ int(landed_to_shoot) + int(ground_dominant) \
		+ int(tactical_ground_movement) + int(changed_loadout) \
		+ int(completed_burst_cycle)
	print(("AITEST moved=%s fired=%s swung=%s grounded_shot=%s " \
		+ "ground_frames=%d swing_frames=%d air_frames=%d ground_shots=%d " \
		+ "swing_shots=%d ground_repositions=%d vine_repositions=%d " \
		+ "tactics=%s weapon_switches=%d used_weapons=%d reloads=%d " \
		+ "bursts=%d post_burst_strafes=%d last_burst=%d player_hit=%s " \
		+ "result=%d/8 %s") % [moved, fired, swung,
		landed_to_shoot, ground_frames, swing_frames, airborne_frames,
		ai.ground_shots, ai.swing_shots, ai.ground_repositions,
		ai.vine_repositions, observed_tactics.keys(), ai.weapon_switch_count,
		used_weapons, ai.reloads_started, ai.bursts_completed,
		ai.post_burst_strafes, ai.last_burst_size, player_was_hit, passed,
		"PASS" if passed == 8 else "FAIL"])
	# The live test creates physical rounds and reload debris. Retire those before
	# quitting so a successful behavior run does not mask lifecycle regressions.
	ai.set_physics_process(false)
	ai.set_process(false)
	for child in world.get_children():
		if child is BananaBullet or child is WeaponDebris:
			child.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if passed == 8 else 1)
